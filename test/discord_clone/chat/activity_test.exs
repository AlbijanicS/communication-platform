defmodule DiscordClone.Chat.ActivityTest do
  use DiscordClone.DataCase, async: false

  alias DiscordClone.Accounts
  alias DiscordClone.Accounts.Scope
  alias DiscordClone.Activities.ActivityItem
  alias DiscordClone.Chat
  alias DiscordClone.Chat.ChannelUnreadSpan
  alias DiscordClone.Chat.Message
  alias DiscordClone.Repo
  alias DiscordClone.Workspaces
  alias DiscordClone.Workspaces.Roles
  alias DiscordClone.Workspaces.WorkspaceMembership

  import DiscordClone.AccountsFixtures

  describe "direct mention activity through the Chat context" do
    test "creates one unread item for each current mentioned member" do
      author_scope = user_scope_fixture(user_fixture(%{username: "sender_user"}))
      target_scope = user_scope_fixture(user_fixture(%{username: "target_user"}))
      second_scope = user_scope_fixture(user_fixture(%{username: "second_user"}))
      non_member_scope = user_scope_fixture(user_fixture(%{username: "outsider_user"}))
      {:ok, workspace} = Workspaces.create_workspace(author_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, target_scope)
      add_workspace_member!(workspace, second_scope)

      content =
        "Email sender_user@example.com; hi (@TARGET_USER), @target_user! " <>
          "@second_user. Ignore @unknown_user, @outsider_user, and @sender_user."

      assert {:ok, message} =
               Chat.send_message(author_scope, workspace.default_channel_id, %{content: content})

      assert message.content == content

      assert [target_item] = activity_items_for(target_scope.user.id)
      assert target_item.recipient_user_id == target_scope.user.id
      assert target_item.actor_user_id == author_scope.user.id
      assert target_item.source_message_id == message.id
      assert target_item.source_conversation_id == workspace.default_channel_id
      assert target_item.workspace_id == workspace.id
      assert target_item.kind == "user_mention"
      assert is_nil(target_item.read_at)
      assert %DateTime{} = target_item.inserted_at

      assert [_second_item] = activity_items_for(second_scope.user.id)
      assert [] = activity_items_for(author_scope.user.id)
      assert [] = activity_items_for(non_member_scope.user.id)
      assert {:ok, 1} = Chat.unread_activity_count(target_scope)
      assert {:ok, 1} = Chat.unread_activity_count(second_scope)
      assert {:ok, 0} = Chat.unread_activity_count(author_scope)
    end

    test "keeps the original recipient when membership and usernames later change" do
      author_scope = user_scope_fixture(user_fixture(%{username: "message_author"}))
      original_scope = user_scope_fixture(user_fixture(%{username: "original_name"}))
      {:ok, workspace} = Workspaces.create_workspace(author_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, original_scope)

      assert {:ok, first_message} =
               Chat.send_message(author_scope, workspace.default_channel_id, %{
                 content: "hello @original_name"
               })

      original_membership =
        Repo.get_by!(WorkspaceMembership,
          workspace_id: workspace.id,
          user_id: original_scope.user.id
        )

      Repo.delete!(original_membership)

      assert [original_item] = activity_items_for(original_scope.user.id)
      assert original_item.source_message_id == first_message.id

      assert {:ok, renamed_user} =
               Accounts.update_user_username(original_scope, %{username: "renamed_user"})

      renamed_scope = Scope.for_user(renamed_user)
      replacement_scope = user_scope_fixture(user_fixture(%{username: "original_name"}))
      add_workspace_member!(workspace, replacement_scope)

      assert {:ok, second_message} =
               Chat.send_message(author_scope, workspace.default_channel_id, %{
                 content: "hello again @original_name"
               })

      assert [original_item] = activity_items_for(renamed_scope.user.id)
      assert original_item.source_message_id == first_message.id
      assert original_item.recipient_user_id == renamed_user.id

      assert [replacement_item] = activity_items_for(replacement_scope.user.id)
      assert replacement_item.source_message_id == second_message.id
      assert replacement_item.recipient_user_id == replacement_scope.user.id
    end

    test "rolls mention activity and sequencing back when reply validation fails" do
      author_scope = user_scope_fixture(user_fixture(%{username: "rollback_author"}))
      target_scope = user_scope_fixture(user_fixture(%{username: "rollback_target"}))
      {:ok, workspace} = Workspaces.create_workspace(author_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, target_scope)

      assert {:error, :invalid_message, changeset} =
               Chat.send_message(author_scope, workspace.default_channel_id, %{
                 content: "hello @rollback_target",
                 reply_to_message_id: Ecto.UUID.generate()
               })

      assert "is not an earlier message in this channel" in errors_on(changeset).reply_to_message_id
      assert [] = activity_items_for(target_scope.user.id)

      assert {:ok, message} =
               Chat.send_message(author_scope, workspace.default_channel_id, %{content: "first"})

      assert message.seq == 1
    end

    test "rolls message, sequence, activity, and unread fan-out back when activity insertion fails" do
      author_scope = user_scope_fixture(user_fixture(%{username: "failure_author"}))
      target_scope = user_scope_fixture(user_fixture(%{username: "failure_target"}))
      {:ok, workspace} = Workspaces.create_workspace(author_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, target_scope)

      Ecto.Adapters.SQL.query!(
        Repo,
        """
        ALTER TABLE activity_items
        ADD CONSTRAINT activity_items_test_reject_mentions
        CHECK (kind <> 'user_mention')
        """,
        []
      )

      assert_raise Postgrex.Error, ~r/activity_items_test_reject_mentions/, fn ->
        Chat.send_message(author_scope, workspace.default_channel_id, %{
          content: "hello @failure_target"
        })
      end

      assert [] = activity_items_for(target_scope.user.id)
      assert {:ok, 0} = Chat.unread_activity_count(target_scope)
      assert {:ok, %{}} = Chat.list_unread_counts(target_scope, workspace.id)

      assert {:ok, message} =
               Chat.send_message(author_scope, workspace.default_channel_id, %{content: "first"})

      assert message.seq == 1
    end

    test "rolls inserted activity and message state back when unread fan-out fails" do
      author_scope = user_scope_fixture(user_fixture(%{username: "unread_failure_author"}))
      target_scope = user_scope_fixture(user_fixture(%{username: "unread_failure_target"}))
      {:ok, workspace} = Workspaces.create_workspace(author_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, target_scope)

      Ecto.Adapters.SQL.query!(
        Repo,
        """
        ALTER TABLE conversation_read_states
        ADD CONSTRAINT conversation_read_states_test_reject_unread
        CHECK (unread_count = 0)
        """,
        []
      )

      assert_raise Ecto.ConstraintError, ~r/conversation_read_states_test_reject_unread/, fn ->
        Chat.send_message(author_scope, workspace.default_channel_id, %{
          content: "hello @unread_failure_target"
        })
      end

      assert [] = activity_items_for(target_scope.user.id)
      assert {:ok, 0} = Chat.unread_activity_count(target_scope)
      assert {:ok, %{}} = Chat.list_unread_counts(target_scope, workspace.id)

      Ecto.Adapters.SQL.query!(
        Repo,
        "ALTER TABLE conversation_read_states DROP CONSTRAINT conversation_read_states_test_reject_unread",
        []
      )

      assert {:ok, message} =
               Chat.send_message(author_scope, workspace.default_channel_id, %{content: "first"})

      assert message.seq == 1
    end

    test "rejects duplicate items for one recipient and source message" do
      author_scope = user_scope_fixture(user_fixture(%{username: "unique_author"}))
      target_scope = user_scope_fixture(user_fixture(%{username: "unique_target"}))
      {:ok, workspace} = Workspaces.create_workspace(author_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, target_scope)

      assert {:ok, message} =
               Chat.send_message(author_scope, workspace.default_channel_id, %{
                 content: "hello @unique_target"
               })

      assert {:error, changeset} =
               %ActivityItem{
                 recipient_user_id: target_scope.user.id,
                 actor_user_id: author_scope.user.id,
                 source_message_id: message.id,
                 source_conversation_id: workspace.default_channel_id,
                 workspace_id: workspace.id
               }
               |> ActivityItem.create_changeset("future_kind")
               |> Repo.insert()

      assert %{recipient_user_id: ["has already been taken"]} = errors_on(changeset)
    end

    test "rejects Friend relationship kinds on Message-backed sources" do
      author_scope = user_scope_fixture(user_fixture(%{username: "source_kind_author"}))
      target_scope = user_scope_fixture(user_fixture(%{username: "source_kind_target"}))
      {:ok, workspace} = Workspaces.create_workspace(author_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, target_scope)

      assert {:ok, message} =
               Chat.send_message(author_scope, workspace.default_channel_id, %{content: "hello"})

      assert {:error, changeset} =
               %ActivityItem{
                 recipient_user_id: target_scope.user.id,
                 actor_user_id: author_scope.user.id,
                 source_message_id: message.id,
                 source_conversation_id: workspace.default_channel_id,
                 workspace_id: workspace.id
               }
               |> ActivityItem.create_changeset(ActivityItem.friend_request_received_kind())
               |> Repo.insert()

      assert %{kind: ["is invalid"]} = errors_on(changeset)
    end

    test "requires an authenticated scope to read private activity" do
      assert Chat.unread_activity_count(nil) == {:error, :unauthenticated}
      assert Chat.unread_activity_count(%Scope{}) == {:error, :unauthenticated}
    end
  end

  describe "everyone mention activity through the Chat context" do
    test "owners create one unread item for every current member except themselves" do
      owner_scope = user_scope_fixture(user_fixture(%{username: "everyone_owner"}))
      first_scope = user_scope_fixture(user_fixture(%{username: "everyone_first"}))
      second_scope = user_scope_fixture(user_fixture(%{username: "everyone_second"}))
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, first_scope)
      add_workspace_member!(workspace, second_scope)

      assert {:ok, message} =
               Chat.send_message(owner_scope, workspace.default_channel_id, %{
                 content: "Heads up @everyone — again, @EVERYONE."
               })

      assert [first_item] = activity_items_for(first_scope.user.id)
      assert first_item.kind == ActivityItem.everyone_mention_kind()
      assert first_item.source_message_id == message.id
      assert first_item.actor_user_id == owner_scope.user.id
      assert [_second_item] = activity_items_for(second_scope.user.id)
      assert [] = activity_items_for(owner_scope.user.id)
      assert {:ok, 1} = Chat.unread_activity_count(first_scope)
      assert {:ok, 1} = Chat.unread_activity_count(second_scope)
      assert {:ok, 0} = Chat.unread_activity_count(owner_scope)
    end

    test "admins can address everyone while regular members keep the token as ordinary content" do
      owner_scope = user_scope_fixture(user_fixture(%{username: "role_owner"}))
      admin_scope = user_scope_fixture(user_fixture(%{username: "role_admin"}))
      member_scope = user_scope_fixture(user_fixture(%{username: "role_member"}))
      recipient_scope = user_scope_fixture(user_fixture(%{username: "role_recipient"}))
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, admin_scope, Roles.admin())
      add_workspace_member!(workspace, member_scope)
      add_workspace_member!(workspace, recipient_scope)

      assert {:ok, admin_message} =
               Chat.send_message(admin_scope, workspace.default_channel_id, %{
                 content: "Admin update @everyone"
               })

      assert [owner_item] = activity_items_for(owner_scope.user.id)
      assert owner_item.kind == ActivityItem.everyone_mention_kind()
      assert [_member_item] = activity_items_for(member_scope.user.id)
      assert [_recipient_item] = activity_items_for(recipient_scope.user.id)
      assert [] = activity_items_for(admin_scope.user.id)

      content = "Member update @everyone"

      assert {:ok, member_message} =
               Chat.send_message(member_scope, workspace.default_channel_id, %{content: content})

      assert member_message.content == content
      assert member_message.seq == admin_message.seq + 1
      assert [^owner_item] = activity_items_for(owner_scope.user.id)
      assert [_recipient_item] = activity_items_for(recipient_scope.user.id)
    end

    test "captures the audience at send time without adding later members" do
      owner_scope = user_scope_fixture(user_fixture(%{username: "fixed_owner"}))
      current_scope = user_scope_fixture(user_fixture(%{username: "fixed_current"}))
      later_scope = user_scope_fixture(user_fixture(%{username: "fixed_later"}))
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, current_scope)

      assert {:ok, message} =
               Chat.send_message(owner_scope, workspace.default_channel_id, %{
                 content: "Current audience @everyone"
               })

      add_workspace_member!(workspace, later_scope)

      assert [current_item] = activity_items_for(current_scope.user.id)
      assert current_item.source_message_id == message.id
      assert [] = activity_items_for(later_scope.user.id)
      assert {:ok, 0} = Chat.unread_activity_count(later_scope)
    end

    test "gives a direct user mention precedence over everyone for the same recipient" do
      owner_scope = user_scope_fixture(user_fixture(%{username: "overlap_owner"}))
      target_scope = user_scope_fixture(user_fixture(%{username: "overlap_target"}))
      other_scope = user_scope_fixture(user_fixture(%{username: "overlap_other"}))
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, target_scope)
      add_workspace_member!(workspace, other_scope)

      assert {:ok, message} =
               Chat.send_message(owner_scope, workspace.default_channel_id, %{
                 content: "@everyone @overlap_target @OVERLAP_TARGET"
               })

      assert [target_item] = activity_items_for(target_scope.user.id)
      assert target_item.kind == ActivityItem.user_mention_kind()
      assert target_item.source_message_id == message.id
      assert [other_item] = activity_items_for(other_scope.user.id)
      assert other_item.kind == ActivityItem.everyone_mention_kind()
    end

    test "rolls message, activity, sequencing, and unread effects back together" do
      owner_scope = user_scope_fixture(user_fixture(%{username: "everyone_rollback_owner"}))
      target_scope = user_scope_fixture(user_fixture(%{username: "everyone_rollback_target"}))
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, target_scope)

      Ecto.Adapters.SQL.query!(
        Repo,
        """
        ALTER TABLE activity_items
        ADD CONSTRAINT activity_items_test_reject_everyone
        CHECK (kind <> 'everyone_mention')
        """,
        []
      )

      assert_raise Postgrex.Error, ~r/activity_items_test_reject_everyone/, fn ->
        Chat.send_message(owner_scope, workspace.default_channel_id, %{
          content: "Rollback @everyone"
        })
      end

      assert [] = activity_items_for(target_scope.user.id)
      assert {:ok, 0} = Chat.unread_activity_count(target_scope)
      assert {:ok, %{}} = Chat.list_unread_counts(target_scope, workspace.id)

      assert {:ok, message} =
               Chat.send_message(owner_scope, workspace.default_channel_id, %{content: "first"})

      assert message.seq == 1
    end
  end

  describe "list_activity_feed/2" do
    test "returns only the scoped user's accessible activity newest first with display associations" do
      recipient_scope = user_scope_fixture(user_fixture(%{username: "feed_recipient"}))
      other_scope = user_scope_fixture(user_fixture(%{username: "other_recipient"}))
      first_author_scope = user_scope_fixture(user_fixture(%{username: "first_author"}))
      second_author_scope = user_scope_fixture(user_fixture(%{username: "second_author"}))

      {:ok, first_workspace} =
        Workspaces.create_workspace(first_author_scope, %{name: "First Workspace"})

      {:ok, second_workspace} =
        Workspaces.create_workspace(second_author_scope, %{name: "Second Workspace"})

      add_workspace_member!(first_workspace, recipient_scope)
      add_workspace_member!(first_workspace, other_scope)
      add_workspace_member!(second_workspace, recipient_scope)

      assert {:ok, first_message} =
               Chat.send_message(first_author_scope, first_workspace.default_channel_id, %{
                 content: "first request @feed_recipient"
               })

      assert {:ok, second_message} =
               Chat.send_message(second_author_scope, second_workspace.default_channel_id, %{
                 content: "second request @feed_recipient"
               })

      assert {:ok, _other_message} =
               Chat.send_message(first_author_scope, first_workspace.default_channel_id, %{
                 content: "private request @other_recipient"
               })

      [first_item] = activity_items_for_message(first_message.id)
      [second_item] = activity_items_for_message(second_message.id)
      shared_inserted_at = ~U[2026-07-15 10:00:00.000000Z]

      Repo.update_all(
        from(activity_item in ActivityItem,
          where: activity_item.id in ^[first_item.id, second_item.id]
        ),
        set: [inserted_at: shared_inserted_at]
      )

      expected_ids = Enum.sort([first_item.id, second_item.id], :desc)

      assert {:ok, page} = Chat.list_activity_feed(recipient_scope)
      activity_items = page.items
      assert Enum.map(activity_items, & &1.id) == expected_ids
      assert is_nil(page.next_cursor)

      assert Enum.map(activity_items, & &1.source_message.content) ==
               expected_preview_order(expected_ids, first_item, first_message, second_message)

      assert Enum.all?(activity_items, fn activity_item ->
               activity_item.recipient_user_id == recipient_scope.user.id and
                 activity_item.kind == "user_mention" and
                 Ecto.assoc_loaded?(activity_item.workspace) and
                 Ecto.assoc_loaded?(activity_item.source_channel) and
                 Ecto.assoc_loaded?(activity_item.source_message) and
                 Ecto.assoc_loaded?(activity_item.actor_user)
             end)

      assert Enum.sort(Enum.map(activity_items, & &1.workspace.name)) ==
               ["First Workspace", "Second Workspace"]

      assert Enum.sort(Enum.map(activity_items, & &1.source_channel.name)) ==
               ["general", "general"]

      assert Enum.sort(Enum.map(activity_items, & &1.actor_user.username)) ==
               ["first_author", "second_author"]

      assert {:ok, 2} = Chat.unread_activity_count(recipient_scope)

      first_membership =
        Repo.get_by!(WorkspaceMembership,
          workspace_id: first_workspace.id,
          user_id: recipient_scope.user.id
        )

      Repo.delete!(first_membership)

      assert {:ok, %{items: [remaining_item], next_cursor: nil}} =
               Chat.list_activity_feed(recipient_scope)

      assert remaining_item.workspace.id == second_workspace.id
      assert {:ok, 2} = Chat.unread_activity_count(recipient_scope)
    end

    test "paginates 50 at a time without duplicates or gaps when newer activity arrives" do
      recipient_scope = user_scope_fixture(user_fixture(%{username: "paged_recipient"}))
      author_scope = user_scope_fixture(user_fixture(%{username: "paged_author"}))
      {:ok, workspace} = Workspaces.create_workspace(author_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, recipient_scope)

      first_fifty_items =
        for index <- 1..50 do
          assert {:ok, message} =
                   Chat.send_message(author_scope, workspace.default_channel_id, %{
                     content: "request #{index} @paged_recipient"
                   })

          [activity_item] = activity_items_for_message(message.id)
          activity_item
        end

      first_fifty_ids = Enum.map(first_fifty_items, & &1.id)

      Repo.update_all(
        from(activity_item in ActivityItem, where: activity_item.id in ^first_fifty_ids),
        set: [inserted_at: ~U[2026-07-15 10:00:00.000000Z]]
      )

      assert {:ok, exact_boundary_page} = Chat.list_activity_feed(recipient_scope)
      assert length(exact_boundary_page.items) == 50
      assert is_nil(exact_boundary_page.next_cursor)

      two_older_items =
        for index <- 51..52 do
          assert {:ok, message} =
                   Chat.send_message(author_scope, workspace.default_channel_id, %{
                     content: "request #{index} @paged_recipient"
                   })

          [activity_item] = activity_items_for_message(message.id)
          activity_item
        end

      original_items = first_fifty_items ++ two_older_items
      original_ids = Enum.map(original_items, & &1.id)

      Repo.update_all(
        from(activity_item in ActivityItem, where: activity_item.id in ^original_ids),
        set: [inserted_at: ~U[2026-07-15 10:00:00.000000Z]]
      )

      assert {:ok, first_page} = Chat.list_activity_feed(recipient_scope)
      assert length(first_page.items) == 50
      assert first_page.next_cursor

      assert {:ok, concurrent_message} =
               Chat.send_message(author_scope, workspace.default_channel_id, %{
                 content: "new arrival @paged_recipient"
               })

      [concurrent_item] = activity_items_for_message(concurrent_message.id)

      assert {:ok, second_page} =
               Chat.list_activity_feed(recipient_scope, first_page.next_cursor)

      assert length(second_page.items) == 2
      assert is_nil(second_page.next_cursor)

      paged_ids = Enum.map(first_page.items ++ second_page.items, & &1.id)

      assert MapSet.new(paged_ids) == MapSet.new(original_ids)
      refute concurrent_item.id in paged_ids
    end

    test "requires an authenticated scope" do
      assert Chat.list_activity_feed(nil) == {:error, :unauthenticated}
      assert Chat.list_activity_feed(%Scope{}) == {:error, :unauthenticated}
    end
  end

  describe "mark_all_activity_read/1" do
    test "marks the current cutoff read without changing Channel Read State" do
      recipient_scope = user_scope_fixture(user_fixture(%{username: "read_recipient"}))
      author_scope = user_scope_fixture(user_fixture(%{username: "read_author"}))
      {:ok, workspace} = Workspaces.create_workspace(author_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, recipient_scope)

      assert {:ok, _first_message} =
               Chat.send_message(author_scope, workspace.default_channel_id, %{
                 content: "first @read_recipient"
               })

      assert {:ok, _second_message} =
               Chat.send_message(author_scope, workspace.default_channel_id, %{
                 content: "second @read_recipient"
               })

      assert {:ok, cutoff_race_source} =
               Chat.send_message(author_scope, workspace.default_channel_id, %{
                 content: "committed while mark-all runs"
               })

      Ecto.Adapters.SQL.query!(
        Repo,
        """
        CREATE FUNCTION insert_activity_after_mark_all_cutoff()
        RETURNS trigger AS $$
        BEGIN
          INSERT INTO activity_items (
            id,
            recipient_user_id,
            actor_user_id,
            source_message_id,
            source_conversation_id,
            workspace_id,
            kind,
            inserted_at,
            updated_at
          ) VALUES (
            gen_random_uuid(),
            '#{recipient_scope.user.id}',
            '#{author_scope.user.id}',
            '#{cutoff_race_source.id}',
            '#{workspace.default_channel_id}',
            '#{workspace.id}',
            'user_mention',
            statement_timestamp(),
            statement_timestamp()
          );

          RETURN NULL;
        END;
        $$ LANGUAGE plpgsql;

        """,
        []
      )

      Ecto.Adapters.SQL.query!(
        Repo,
        """
        CREATE TRIGGER activity_after_mark_all_cutoff
        AFTER UPDATE ON activity_items
        FOR EACH STATEMENT
        EXECUTE FUNCTION insert_activity_after_mark_all_cutoff()
        """,
        []
      )

      assert {:ok, summaries_before} =
               Chat.list_channel_read_summaries(recipient_scope, workspace.id)

      spans_before = unread_spans(workspace.default_channel_id, recipient_scope.user.id)

      assert {:ok, 2} = Chat.unread_activity_count(recipient_scope)
      assert {:ok, 2} = Chat.mark_all_activity_read(recipient_scope)
      assert {:ok, 1} = Chat.unread_activity_count(recipient_scope)

      assert {:ok, summaries_after} =
               Chat.list_channel_read_summaries(recipient_scope, workspace.id)

      assert summaries_after == summaries_before
      assert unread_spans(workspace.default_channel_id, recipient_scope.user.id) == spans_before

      assert :ok = Chat.mark_channel_read(recipient_scope, workspace.default_channel_id)
      assert {:ok, 1} = Chat.unread_activity_count(recipient_scope)

      assert {:ok, page} = Chat.list_activity_feed(recipient_scope)
      assert Enum.count(page.items, &is_nil(&1.read_at)) == 1
      assert Enum.count(page.items, &match?(%DateTime{}, &1.read_at)) == 2
    end

    test "requires an authenticated scope" do
      assert Chat.mark_all_activity_read(nil) == {:error, :unauthenticated}
      assert Chat.mark_all_activity_read(%Scope{}) == {:error, :unauthenticated}
    end
  end

  describe "open_activity_item/2" do
    test "marks only the selected recipient item read and returns its exact source" do
      recipient_scope = user_scope_fixture(user_fixture(%{username: "activity_recipient"}))
      author_scope = user_scope_fixture(user_fixture(%{username: "activity_author"}))
      {:ok, workspace} = Workspaces.create_workspace(author_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, recipient_scope)

      assert {:ok, first_message} =
               Chat.send_message(author_scope, workspace.default_channel_id, %{
                 content: "first request @activity_recipient"
               })

      assert {:ok, second_message} =
               Chat.send_message(author_scope, workspace.default_channel_id, %{
                 content: "second request @activity_recipient"
               })

      [first_item] = activity_items_for_message(first_message.id)
      [second_item] = activity_items_for_message(second_message.id)

      assert {:ok, summaries_before} =
               Chat.list_channel_read_summaries(recipient_scope, workspace.id)

      spans_before = unread_spans(workspace.default_channel_id, recipient_scope.user.id)

      assert {:ok, destination} = Chat.open_activity_item(recipient_scope, first_item.id)

      assert destination == %{
               workspace_id: workspace.id,
               channel_id: workspace.default_channel_id,
               message_id: first_message.id
             }

      assert %DateTime{} = Repo.get!(ActivityItem, first_item.id).read_at
      assert is_nil(Repo.get!(ActivityItem, second_item.id).read_at)
      assert {:ok, 1} = Chat.unread_activity_count(recipient_scope)

      assert {:ok, ^summaries_before} =
               Chat.list_channel_read_summaries(recipient_scope, workspace.id)

      assert unread_spans(workspace.default_channel_id, recipient_scope.user.id) == spans_before
    end

    test "uses one privacy-safe result without changing read state for invalid sources" do
      recipient_scope = user_scope_fixture(user_fixture(%{username: "safe_recipient"}))
      other_scope = user_scope_fixture(user_fixture(%{username: "safe_other"}))
      author_scope = user_scope_fixture(user_fixture(%{username: "safe_author"}))
      {:ok, workspace} = Workspaces.create_workspace(author_scope, %{name: "Foundry"})
      {:ok, other_workspace} = Workspaces.create_workspace(other_scope, %{name: "Private"})
      add_workspace_member!(workspace, recipient_scope)

      assert {:ok, deleted_message} =
               Chat.send_message(author_scope, workspace.default_channel_id, %{
                 content: "deleted request @safe_recipient"
               })

      [deleted_item] = activity_items_for_message(deleted_message.id)
      assert {:ok, _deleted_message} = Chat.delete_message(author_scope, deleted_message.id)
      refute Repo.get(ActivityItem, deleted_item.id)

      assert Chat.open_activity_item(recipient_scope, deleted_item.id) == {:error, :not_found}
      assert Chat.open_activity_item(other_scope, deleted_item.id) == {:error, :not_found}

      assert Chat.open_activity_item(recipient_scope, Ecto.UUID.generate()) ==
               {:error, :not_found}

      assert {:ok, wrong_channel_message} =
               Chat.send_message(author_scope, workspace.default_channel_id, %{
                 content: "wrong channel request @safe_recipient"
               })

      [wrong_channel_item] = activity_items_for_message(wrong_channel_message.id)

      Repo.update_all(
        from(activity_item in ActivityItem, where: activity_item.id == ^wrong_channel_item.id),
        set: [source_conversation_id: other_workspace.default_channel_id]
      )

      assert Chat.open_activity_item(recipient_scope, wrong_channel_item.id) ==
               {:error, :not_found}

      assert is_nil(Repo.get!(ActivityItem, wrong_channel_item.id).read_at)

      assert {:ok, inaccessible_message} =
               Chat.send_message(author_scope, workspace.default_channel_id, %{
                 content: "inaccessible request @safe_recipient"
               })

      [inaccessible_item] = activity_items_for_message(inaccessible_message.id)

      membership =
        Repo.get_by!(WorkspaceMembership,
          workspace_id: workspace.id,
          user_id: recipient_scope.user.id
        )

      Repo.delete!(membership)

      assert Chat.open_activity_item(recipient_scope, inaccessible_item.id) ==
               {:error, :not_found}

      assert is_nil(Repo.get!(ActivityItem, inaccessible_item.id).read_at)
    end

    test "requires an authenticated scope" do
      assert Chat.open_activity_item(nil, Ecto.UUID.generate()) == {:error, :unauthenticated}
      assert Chat.open_activity_item(%Scope{}, Ecto.UUID.generate()) == {:error, :unauthenticated}
    end
  end

  describe "delete_message/2 activity cleanup" do
    test "rolls message deletion back when activity cleanup fails" do
      author_scope = user_scope_fixture(user_fixture(%{username: "delete_rollback_author"}))

      recipient_scope =
        user_scope_fixture(user_fixture(%{username: "delete_rollback_recipient"}))

      {:ok, workspace} = Workspaces.create_workspace(author_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, recipient_scope)

      {:ok, message} =
        Chat.send_message(author_scope, workspace.default_channel_id, %{
          content: "hello @delete_rollback_recipient"
        })

      [activity_item] = activity_items_for_message(message.id)
      install_reject_activity_cleanup_trigger!()

      assert_raise Postgrex.Error, fn ->
        Chat.delete_message(author_scope, message.id)
      end

      assert is_nil(Repo.get!(Message, message.id).deleted_at)
      assert Repo.get(ActivityItem, activity_item.id)
    end
  end

  defp add_workspace_member!(workspace, scope, role \\ Roles.member()) do
    %WorkspaceMembership{}
    |> WorkspaceMembership.changeset(%{
      workspace_id: workspace.id,
      user_id: scope.user.id,
      role: role
    })
    |> Repo.insert!()
  end

  defp activity_items_for(user_id) do
    Repo.all(
      from activity_item in ActivityItem,
        where: activity_item.recipient_user_id == ^user_id,
        order_by: [desc: activity_item.inserted_at, desc: activity_item.id]
    )
  end

  defp activity_items_for_message(message_id) do
    Repo.all(
      from activity_item in ActivityItem, where: activity_item.source_message_id == ^message_id
    )
  end

  defp unread_spans(channel_id, user_id) do
    Repo.all(
      from span in ChannelUnreadSpan,
        where: span.channel_id == ^channel_id and span.user_id == ^user_id,
        order_by: [asc: span.from_seq, asc: span.to_seq],
        select: {span.from_seq, span.to_seq}
    )
  end

  defp expected_preview_order(expected_ids, first_item, first_message, second_message) do
    if List.first(expected_ids) == first_item.id do
      [first_message.content, second_message.content]
    else
      [second_message.content, first_message.content]
    end
  end
end
