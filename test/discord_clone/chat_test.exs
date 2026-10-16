defmodule DiscordClone.ChatTest do
  use DiscordClone.DataCase, async: false

  alias DiscordClone.Chat
  alias DiscordClone.Accounts.User
  alias DiscordClone.Activities.ActivityItem

  alias DiscordClone.Chat.{
    ChannelReadState,
    ChannelUnreadSpan,
    Conversation,
    Message,
    MessageReaction,
    Runtime
  }

  alias DiscordClone.Workspaces
  alias DiscordClone.Workspaces.Channel
  alias DiscordClone.Workspaces.WorkspaceMembership

  import DiscordClone.AccountsFixtures

  describe "change_message/1" do
    test "returns a message changeset for composer forms" do
      changeset = Chat.change_message(%{content: "hello"})

      assert %Ecto.Changeset{} = changeset
      assert Ecto.Changeset.get_field(changeset, :content) == "hello"
    end
  end

  describe "channel read-state storage" do
    test "keeps one consistent unread summary per channel and user" do
      scope = user_scope_fixture()
      member_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      add_workspace_member!(workspace, member_scope)

      read_state =
        Repo.get_by!(ChannelReadState,
          channel_id: workspace.default_channel_id,
          user_id: scope.user.id
        )

      assert read_state.unread_count == 0
      assert is_nil(read_state.first_unread_seq)
      assert is_nil(read_state.last_unread_seq)

      duplicate_changeset =
        ChannelReadState.changeset(%ChannelReadState{}, %{
          channel_id: workspace.default_channel_id,
          user_id: scope.user.id,
          unread_count: 0
        })

      assert {:error, changeset} = Repo.insert(duplicate_changeset)
      assert %{channel_id: ["has already been taken"]} = errors_on(changeset)

      assert {:error, changeset} =
               %ChannelReadState{}
               |> ChannelReadState.changeset(%{
                 channel_id: workspace.default_channel_id,
                 user_id: member_scope.user.id,
                 unread_count: 0,
                 first_unread_seq: 1,
                 last_unread_seq: 1
               })
               |> Repo.insert()

      assert %{unread_count: ["requires nil unread bounds when zero"]} = errors_on(changeset)
    end

    test "stores non-overlapping unread spans for a channel and user" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})

      assert {:ok, _span} =
               %ChannelUnreadSpan{}
               |> ChannelUnreadSpan.changeset(%{
                 channel_id: workspace.default_channel_id,
                 user_id: scope.user.id,
                 from_seq: 2,
                 to_seq: 4
               })
               |> Repo.insert()

      assert {:ok, _span} =
               %ChannelUnreadSpan{}
               |> ChannelUnreadSpan.changeset(%{
                 channel_id: workspace.default_channel_id,
                 user_id: scope.user.id,
                 from_seq: 5,
                 to_seq: 7
               })
               |> Repo.insert()

      assert {:error, changeset} =
               %ChannelUnreadSpan{}
               |> ChannelUnreadSpan.changeset(%{
                 channel_id: workspace.default_channel_id,
                 user_id: scope.user.id,
                 from_seq: 4,
                 to_seq: 6
               })
               |> Repo.insert()

      assert %{from_seq: ["overlaps an existing unread span"]} = errors_on(changeset)

      assert {:error, changeset} =
               %ChannelUnreadSpan{}
               |> ChannelUnreadSpan.changeset(%{
                 channel_id: workspace.default_channel_id,
                 user_id: scope.user.id,
                 from_seq: 9,
                 to_seq: 8
               })
               |> Repo.insert()

      assert %{from_seq: ["must be less than or equal to to seq"]} = errors_on(changeset)
    end

    test "associates unread storage with users and channels and cleans it up" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})

      Repo.insert!(
        ChannelUnreadSpan.changeset(%ChannelUnreadSpan{}, %{
          channel_id: workspace.default_channel_id,
          user_id: scope.user.id,
          from_seq: 3,
          to_seq: 4
        })
      )

      assert :channel_read_states in Channel.__schema__(:associations)
      assert :channel_unread_spans in Channel.__schema__(:associations)
      assert :channel_read_states in User.__schema__(:associations)
      assert :channel_unread_spans in User.__schema__(:associations)

      Repo.delete!(Repo.get!(Conversation, workspace.default_channel_id))

      refute Repo.get_by(ChannelReadState, channel_id: workspace.default_channel_id)
      refute Repo.get_by(ChannelUnreadSpan, channel_id: workspace.default_channel_id)

      {:ok, channel} = Workspaces.create_channel(scope, workspace.id, %{name: "release"})
      member_scope = user_scope_fixture()
      add_workspace_member!(workspace, member_scope)

      Repo.insert!(
        ChannelReadState.changeset(%ChannelReadState{}, %{
          channel_id: channel.id,
          user_id: member_scope.user.id,
          unread_count: 1,
          first_unread_seq: 1,
          last_unread_seq: 1
        })
      )

      Repo.insert!(
        ChannelUnreadSpan.changeset(%ChannelUnreadSpan{}, %{
          channel_id: channel.id,
          user_id: member_scope.user.id,
          from_seq: 1,
          to_seq: 1
        })
      )

      Repo.delete!(Repo.get!(User, member_scope.user.id))

      refute Repo.get_by(ChannelReadState, user_id: member_scope.user.id)
      refute Repo.get_by(ChannelUnreadSpan, user_id: member_scope.user.id)
    end
  end

  describe "unread range workflows" do
    test "adds an unread range and updates the read-state summary" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})

      assert {:ok, read_state} =
               Chat.add_channel_unread_range(scope, workspace.default_channel_id, 2, 4)

      assert read_state.unread_count == 3
      assert read_state.first_unread_seq == 2
      assert read_state.last_unread_seq == 4

      assert [{2, 4}] = unread_spans(workspace.default_channel_id, scope.user.id)
    end

    test "merges adjacent and overlapping unread ranges" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})

      assert {:ok, _read_state} =
               Chat.add_channel_unread_range(scope, workspace.default_channel_id, 2, 4)

      assert {:ok, read_state} =
               Chat.add_channel_unread_range(scope, workspace.default_channel_id, 4, 7)

      assert read_state.unread_count == 6
      assert read_state.first_unread_seq == 2
      assert read_state.last_unread_seq == 7
      assert [{2, 7}] = unread_spans(workspace.default_channel_id, scope.user.id)

      assert {:ok, read_state} =
               Chat.add_channel_unread_range(scope, workspace.default_channel_id, 8, 9)

      assert read_state.unread_count == 8
      assert read_state.first_unread_seq == 2
      assert read_state.last_unread_seq == 9
      assert [{2, 9}] = unread_spans(workspace.default_channel_id, scope.user.id)
    end

    test "subtracts an exact visible-read range and clears the summary" do
      scope = user_scope_fixture()
      other_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      add_workspace_member!(workspace, other_scope)
      insert_messages!(workspace.default_channel_id, other_scope.user.id, 5)

      assert {:ok, _read_state} =
               Chat.add_channel_unread_range(scope, workspace.default_channel_id, 2, 4)

      assert {:ok, read_state} =
               Chat.subtract_visible_read_range(scope, workspace.default_channel_id, 2, 4)

      assert read_state.unread_count == 0
      assert is_nil(read_state.first_unread_seq)
      assert is_nil(read_state.last_unread_seq)
      assert [] = unread_spans(workspace.default_channel_id, scope.user.id)
    end

    test "subtracts from unread range edges and splits the middle" do
      scope = user_scope_fixture()
      other_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      add_workspace_member!(workspace, other_scope)
      insert_messages!(workspace.default_channel_id, other_scope.user.id, 10)

      assert {:ok, _read_state} =
               Chat.add_channel_unread_range(scope, workspace.default_channel_id, 2, 9)

      assert {:ok, read_state} =
               Chat.subtract_visible_read_range(scope, workspace.default_channel_id, 2, 3)

      assert read_state.unread_count == 6
      assert read_state.first_unread_seq == 4
      assert read_state.last_unread_seq == 9
      assert [{4, 9}] = unread_spans(workspace.default_channel_id, scope.user.id)

      assert {:ok, read_state} =
               Chat.subtract_visible_read_range(scope, workspace.default_channel_id, 8, 9)

      assert read_state.unread_count == 4
      assert read_state.first_unread_seq == 4
      assert read_state.last_unread_seq == 7
      assert [{4, 7}] = unread_spans(workspace.default_channel_id, scope.user.id)

      assert {:ok, read_state} =
               Chat.subtract_visible_read_range(scope, workspace.default_channel_id, 5, 6)

      assert read_state.unread_count == 2
      assert read_state.first_unread_seq == 4
      assert read_state.last_unread_seq == 7
      assert [{4, 4}, {7, 7}] = unread_spans(workspace.default_channel_id, scope.user.id)
    end

    test "marking a channel read clears all unread ranges" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})

      assert {:ok, _read_state} =
               Chat.add_channel_unread_range(scope, workspace.default_channel_id, 2, 4)

      assert {:ok, _read_state} =
               Chat.add_channel_unread_range(scope, workspace.default_channel_id, 8, 10)

      assert :ok = Chat.mark_channel_read(scope, workspace.default_channel_id)

      assert %ChannelReadState{
               unread_count: 0,
               first_unread_seq: nil,
               last_unread_seq: nil
             } =
               Repo.get_by(ChannelReadState,
                 channel_id: workspace.default_channel_id,
                 user_id: scope.user.id
               )

      assert [] = unread_spans(workspace.default_channel_id, scope.user.id)
    end

    test "marking a channel read clears unread state and publishes the read-state change" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      channel_id = workspace.default_channel_id

      assert :ok = Chat.subscribe_to_channel_read_state(scope, channel_id)
      assert {:ok, _read_state} = Chat.add_channel_unread_range(scope, channel_id, 2, 4)

      assert_receive {:channel_read_state_changed,
                      %{
                        channel_id: ^channel_id,
                        unread_count: 3,
                        first_unread_seq: 2,
                        last_unread_seq: 4
                      }}

      assert :ok = Chat.mark_channel_read(scope, channel_id)

      assert_receive {:channel_read_state_changed,
                      %{
                        workspace_id: workspace_id,
                        channel_id: ^channel_id,
                        unread_count: 0,
                        first_unread_seq: nil,
                        last_unread_seq: nil
                      }}

      assert workspace_id == workspace.id
      assert [] = unread_spans(channel_id, scope.user.id)
    end

    test "broadcasts read-state changes but not duplicate visible-read no-ops" do
      scope = user_scope_fixture()
      other_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      add_workspace_member!(workspace, other_scope)
      insert_messages!(workspace.default_channel_id, other_scope.user.id, 5)

      assert :ok = Chat.subscribe_to_channel_read_state(scope, workspace.default_channel_id)

      assert {:ok, _read_state} =
               Chat.add_channel_unread_range(scope, workspace.default_channel_id, 2, 4)

      assert_receive {:channel_read_state_changed,
                      %{
                        workspace_id: workspace_id,
                        channel_id: channel_id,
                        unread_count: 3,
                        first_unread_seq: 2,
                        last_unread_seq: 4
                      }}

      assert workspace_id == workspace.id
      assert channel_id == workspace.default_channel_id

      assert {:ok, _read_state} =
               Chat.subtract_visible_read_range(scope, workspace.default_channel_id, 2, 3)

      assert_receive {:channel_read_state_changed,
                      %{
                        workspace_id: workspace_id,
                        channel_id: channel_id,
                        unread_count: 1,
                        first_unread_seq: 4,
                        last_unread_seq: 4
                      }}

      assert workspace_id == workspace.id
      assert channel_id == workspace.default_channel_id

      [span_before_duplicate] = unread_span_records(workspace.default_channel_id, scope.user.id)

      assert {:ok, _read_state} =
               Chat.subtract_visible_read_range(scope, workspace.default_channel_id, 2, 3)

      assert [^span_before_duplicate] =
               unread_span_records(workspace.default_channel_id, scope.user.id)

      refute_receive {:channel_read_state_changed, _payload}
    end

    test "publishes read-state changes only to the changed user's private topic" do
      scope = user_scope_fixture()
      other_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      add_workspace_member!(workspace, other_scope)
      channel_id = workspace.default_channel_id

      assert :ok = Chat.subscribe_to_channel_read_state(scope, channel_id)
      assert :ok = Chat.subscribe_to_channel_read_state(other_scope, channel_id)

      assert {:ok, _read_state} = Chat.add_channel_unread_range(scope, channel_id, 2, 4)

      assert_receive {:channel_read_state_changed,
                      %{
                        workspace_id: workspace_id,
                        channel_id: ^channel_id,
                        unread_count: 3,
                        first_unread_seq: 2,
                        last_unread_seq: 4
                      }}

      assert workspace_id == workspace.id
      refute_receive {:channel_read_state_changed, _payload}
    end

    test "validates access for unread range workflows" do
      scope = user_scope_fixture()
      non_member_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})

      assert Chat.add_channel_unread_range(nil, workspace.default_channel_id, 1, 1) ==
               {:error, :unauthenticated}

      assert Chat.subtract_visible_read_range(
               %DiscordClone.Accounts.Scope{},
               workspace.default_channel_id,
               1,
               1
             ) ==
               {:error, :unauthenticated}

      assert Chat.subscribe_to_channel_read_state(nil, workspace.default_channel_id) ==
               {:error, :unauthenticated}

      assert Chat.add_channel_unread_range(non_member_scope, workspace.default_channel_id, 1, 1) ==
               {:error, :not_found}

      assert Chat.subtract_visible_read_range(
               non_member_scope,
               workspace.default_channel_id,
               1,
               1
             ) ==
               {:error, :not_found}

      assert Chat.subscribe_to_channel_read_state(non_member_scope, workspace.default_channel_id) ==
               {:error, :not_found}
    end

    test "rejects invalid visible-read ranges" do
      scope = user_scope_fixture()
      other_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      add_workspace_member!(workspace, other_scope)
      insert_messages!(workspace.default_channel_id, other_scope.user.id, 60)

      assert Chat.subtract_visible_read_range(scope, workspace.default_channel_id, 5, 4) ==
               {:error, :invalid_range}

      assert Chat.subtract_visible_read_range(scope, workspace.default_channel_id, 0, 1) ==
               {:error, :invalid_range}

      assert Chat.subtract_visible_read_range(scope, workspace.default_channel_id, 60, 61) ==
               {:error, :invalid_range}

      assert Chat.subtract_visible_read_range(scope, workspace.default_channel_id, 1, 51) ==
               {:error, :range_too_large}

      assert %ChannelReadState{unread_count: 0} =
               Repo.get_by(ChannelReadState,
                 channel_id: workspace.default_channel_id,
                 user_id: scope.user.id
               )
    end

    test "rejects invalid added unread ranges" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})

      assert Chat.add_channel_unread_range(scope, workspace.default_channel_id, 0, 1) ==
               {:error, :invalid_range}

      assert Chat.add_channel_unread_range(scope, workspace.default_channel_id, 4, 3) ==
               {:error, :invalid_range}

      assert %ChannelReadState{unread_count: 0} =
               Repo.get_by(ChannelReadState,
                 channel_id: workspace.default_channel_id,
                 user_id: scope.user.id
               )
    end

    test "creates a missing read-state row for valid no-op visible reads" do
      scope = user_scope_fixture()
      other_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      add_workspace_member!(workspace, other_scope)
      insert_messages!(workspace.default_channel_id, other_scope.user.id, 3)

      assert {:ok, read_state} =
               Chat.subtract_visible_read_range(scope, workspace.default_channel_id, 1, 1)

      assert read_state.unread_count == 0
      assert is_nil(read_state.first_unread_seq)
      assert is_nil(read_state.last_unread_seq)
      assert [] = unread_spans(workspace.default_channel_id, scope.user.id)

      assert %ChannelReadState{unread_count: 0} =
               Repo.get_by(ChannelReadState,
                 channel_id: workspace.default_channel_id,
                 user_id: scope.user.id
               )
    end
  end

  describe "initialize_workspace_reads_for_user/2" do
    test "initializes zero read states for every Channel" do
      owner_scope = user_scope_fixture()
      member_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})

      {:ok, release_channel} =
        Workspaces.create_channel(owner_scope, workspace.id, %{name: "release"})

      {:ok, empty_channel} =
        Workspaces.create_channel(owner_scope, workspace.id, %{name: "empty"})

      add_workspace_member!(workspace, member_scope)

      assert :ok = Chat.initialize_workspace_reads_for_user(member_scope.user.id, workspace.id)

      read_states =
        Repo.all(
          from read_state in ChannelReadState,
            where: read_state.user_id == ^member_scope.user.id,
            select: {read_state.channel_id, read_state.unread_count}
        )
        |> Map.new()

      assert read_states == %{
               workspace.default_channel_id => 0,
               release_channel.id => 0,
               empty_channel.id => 0
             }
    end

    test "requires an existing workspace membership" do
      owner_scope = user_scope_fixture()
      non_member_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})

      assert Chat.initialize_workspace_reads_for_user(non_member_scope.user.id, workspace.id) ==
               {:error, :not_found}

      refute Repo.get_by(ChannelReadState, user_id: non_member_scope.user.id)
    end

    test "does not reset existing unread range state" do
      owner_scope = user_scope_fixture()
      member_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})

      {:ok, release_channel} =
        Workspaces.create_channel(owner_scope, workspace.id, %{name: "release"})

      add_workspace_member!(workspace, member_scope)

      Repo.insert!(
        ChannelReadState.changeset(%ChannelReadState{}, %{
          channel_id: release_channel.id,
          user_id: member_scope.user.id,
          unread_count: 2,
          first_unread_seq: 3,
          last_unread_seq: 4,
          last_viewed_anchor_seq: 2
        })
      )

      Repo.insert!(
        ChannelUnreadSpan.changeset(%ChannelUnreadSpan{}, %{
          channel_id: release_channel.id,
          user_id: member_scope.user.id,
          from_seq: 3,
          to_seq: 4
        })
      )

      assert :ok = Chat.initialize_workspace_reads_for_user(member_scope.user.id, workspace.id)

      assert %ChannelReadState{
               unread_count: 2,
               first_unread_seq: 3,
               last_unread_seq: 4,
               last_viewed_anchor_seq: 2
             } =
               Repo.get_by(ChannelReadState,
                 channel_id: release_channel.id,
                 user_id: member_scope.user.id
               )

      assert unread_spans(release_channel.id, member_scope.user.id) == [{3, 4}]
    end

    test "removes read states when a Channel is deleted" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      {:ok, channel} = Workspaces.create_channel(scope, workspace.id, %{name: "scratch"})

      assert :ok = Chat.initialize_workspace_reads_for_user(scope.user.id, workspace.id)
      assert Repo.get_by(ChannelReadState, channel_id: channel.id, user_id: scope.user.id)

      assert {:ok, _channel} = Workspaces.delete_channel(scope, workspace.id, channel.id)

      refute Repo.get_by(ChannelReadState, channel_id: channel.id, user_id: scope.user.id)
    end

    test "removes read rows when a user is deleted" do
      owner_scope = user_scope_fixture()
      member_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, member_scope)

      assert :ok = Chat.initialize_workspace_reads_for_user(member_scope.user.id, workspace.id)
      assert Repo.get_by(ChannelReadState, user_id: member_scope.user.id)

      member = Repo.get!(User, member_scope.user.id)
      Repo.delete!(member)

      refute Repo.get_by(ChannelReadState, user_id: member_scope.user.id)
    end

    test "removes the obsolete cursor model" do
      assert %{rows: [[nil]]} =
               Ecto.Adapters.SQL.query!(Repo, "SELECT to_regclass('public.channel_reads')", [])
    end
  end

  describe "list_unread_counts/2" do
    test "lists workspace read-state summaries for the current user" do
      scope = user_scope_fixture()
      other_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      {:ok, release_channel} = Workspaces.create_channel(scope, workspace.id, %{name: "release"})
      {:ok, quiet_channel} = Workspaces.create_channel(scope, workspace.id, %{name: "quiet"})

      add_workspace_member!(workspace, other_scope)

      assert {:ok, _read_state} =
               Chat.add_channel_unread_range(scope, release_channel.id, 3, 5)

      assert {:ok, summaries} = Chat.list_channel_read_summaries(scope, workspace.id)

      assert Enum.map(summaries, & &1.channel_id) == [
               workspace.default_channel_id,
               release_channel.id,
               quiet_channel.id
             ]

      assert %{
               workspace_id: workspace_id,
               channel_id: channel_id,
               unread_count: 3,
               first_unread_seq: 3,
               last_unread_seq: 5
             } = Enum.find(summaries, &(&1.channel_id == release_channel.id))

      assert workspace_id == workspace.id
      assert channel_id == release_channel.id

      assert %{
               workspace_id: workspace.id,
               channel_id: quiet_channel.id,
               unread_count: 0,
               first_unread_seq: nil,
               last_unread_seq: nil
             } in summaries

      assert Enum.all?(summaries, &(&1.workspace_id == workspace.id))
      assert Enum.all?(summaries, &Map.has_key?(&1, :first_unread_seq))
    end

    test "sources unread badge counts from read-state summaries" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      {:ok, release_channel} = Workspaces.create_channel(scope, workspace.id, %{name: "release"})

      assert {:ok, _read_state} =
               Chat.add_channel_unread_range(scope, release_channel.id, 2, 3)

      assert {:ok, unread_counts} = Chat.list_unread_counts(scope, workspace.id)
      assert unread_counts == %{release_channel.id => 2}
      assert is_integer(Map.fetch!(unread_counts, release_channel.id))
    end

    test "rejects anonymous scopes" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})

      assert Chat.list_unread_counts(nil, workspace.id) == {:error, :unauthenticated}
      assert Chat.list_channel_read_summaries(nil, workspace.id) == {:error, :unauthenticated}

      assert Chat.list_unread_counts(%DiscordClone.Accounts.Scope{}, workspace.id) ==
               {:error, :unauthenticated}

      assert Chat.list_channel_read_summaries(%DiscordClone.Accounts.Scope{}, workspace.id) ==
               {:error, :unauthenticated}
    end

    test "rejects logged-in users who are not workspace members" do
      owner_scope = user_scope_fixture()
      non_member_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})

      insert_message!(
        workspace.default_channel_id,
        owner_scope.user.id,
        "private update",
        ~U[2026-06-19 10:00:00Z]
      )

      assert Chat.list_unread_counts(non_member_scope, workspace.id) == {:error, :not_found}

      assert Chat.list_channel_read_summaries(non_member_scope, workspace.id) ==
               {:error, :not_found}
    end

    test "counts only channels in the requested workspace" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      {:ok, other_workspace} = Workspaces.create_workspace(scope, %{name: "Library"})

      assert {:ok, _read_state} =
               Chat.add_channel_unread_range(scope, workspace.default_channel_id, 1, 1)

      assert {:ok, _read_state} =
               Chat.add_channel_unread_range(scope, other_workspace.default_channel_id, 1, 1)

      assert {:ok, unread_counts} = Chat.list_unread_counts(scope, workspace.id)
      assert unread_counts == %{workspace.default_channel_id => 1}
      refute Map.has_key?(unread_counts, other_workspace.default_channel_id)
    end
  end

  describe "open_channel/2" do
    test "validates access and records the channel open time" do
      owner_scope = user_scope_fixture()
      non_member_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      channel_id = workspace.default_channel_id

      assert Chat.open_channel(nil, channel_id) == {:error, :unauthenticated}

      assert Chat.open_channel(%DiscordClone.Accounts.Scope{}, channel_id) ==
               {:error, :unauthenticated}

      assert Chat.open_channel(non_member_scope, channel_id) == {:error, :not_found}

      before_open = DateTime.utc_now(:second)

      assert {:ok, %{channel: %Channel{id: ^channel_id}, read_state: read_state}} =
               Chat.open_channel(owner_scope, channel_id)

      assert %ChannelReadState{last_opened_at: %DateTime{} = last_opened_at} = read_state
      assert DateTime.compare(last_opened_at, before_open) in [:eq, :gt]

      assert %ChannelReadState{last_opened_at: ^last_opened_at} =
               Repo.get_by(ChannelReadState, channel_id: channel_id, user_id: owner_scope.user.id)
    end

    test "preserves unread state when opening a Channel" do
      scope = user_scope_fixture()
      other_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      channel_id = workspace.default_channel_id
      add_workspace_member!(workspace, other_scope)
      insert_messages!(channel_id, other_scope.user.id, 5)

      assert {:ok, _read_state} = Chat.add_channel_unread_range(scope, channel_id, 2, 4)

      spans_before = unread_spans(channel_id, scope.user.id)

      assert {:ok, %{read_state: read_state}} = Chat.open_channel(scope, channel_id)

      assert read_state.unread_count == 3
      assert read_state.first_unread_seq == 2
      assert read_state.last_unread_seq == 4
      assert unread_spans(channel_id, scope.user.id) == spans_before
      assert Chat.list_unread_counts(scope, workspace.id) == {:ok, %{channel_id => 3}}
    end

    test "lands at the first unread sequence for small unread backlogs" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      channel_id = workspace.default_channel_id

      assert {:ok, _read_state} = Chat.add_channel_unread_range(scope, channel_id, 3, 5)

      assert {:ok, %{landing: landing}} = Chat.open_channel(scope, channel_id)

      assert landing == %{type: :sequence, reason: :first_unread, target_seq: 3}
    end

    test "lands near recent unread messages for large unread backlogs" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      channel_id = workspace.default_channel_id

      assert {:ok, _read_state} = Chat.add_channel_unread_range(scope, channel_id, 1, 75)

      assert {:ok, %{landing: landing}} = Chat.open_channel(scope, channel_id)

      assert landing == %{type: :sequence, reason: :recent_unread, target_seq: 55}
    end

    test "lands at the last viewed anchor when there is no unread state" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      channel_id = workspace.default_channel_id

      Repo.get_by!(ChannelReadState, channel_id: channel_id, user_id: scope.user.id)
      |> ChannelReadState.changeset(%{last_viewed_anchor_seq: 12})
      |> Repo.update!()

      assert {:ok, %{landing: landing}} = Chat.open_channel(scope, channel_id)

      assert landing == %{type: :sequence, reason: :last_viewed_anchor, target_seq: 12}
    end

    test "lands at latest when there is no unread state or anchor" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})

      assert {:ok, %{landing: landing}} = Chat.open_channel(scope, workspace.default_channel_id)

      assert landing == %{type: :latest, reason: :latest}
    end

    test "uses unread landing before the last viewed anchor" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      channel_id = workspace.default_channel_id

      Repo.get_by!(ChannelReadState, channel_id: channel_id, user_id: scope.user.id)
      |> ChannelReadState.changeset(%{last_viewed_anchor_seq: 20})
      |> Repo.update!()

      assert {:ok, _read_state} = Chat.add_channel_unread_range(scope, channel_id, 4, 6)

      assert {:ok, %{landing: landing}} = Chat.open_channel(scope, channel_id)

      assert landing == %{type: :sequence, reason: :first_unread, target_seq: 4}
    end
  end

  describe "persist_channel_anchor/3" do
    test "stores a member's last viewed anchor sequence" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      messages = insert_messages!(workspace.default_channel_id, scope.user.id, 12)

      assert {:ok, %ChannelReadState{last_viewed_anchor_seq: 7}} =
               Chat.persist_channel_anchor(scope, workspace.default_channel_id, 7)

      anchored_message = Enum.at(messages, 6)

      assert %ChannelReadState{last_viewed_anchor_seq: 7} =
               Repo.get_by(ChannelReadState,
                 channel_id: workspace.default_channel_id,
                 user_id: scope.user.id
               )

      assert anchored_message.seq == 7
    end

    test "validates access and channel sequence bounds" do
      owner_scope = user_scope_fixture()
      non_member_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      insert_messages!(workspace.default_channel_id, owner_scope.user.id, 3)

      assert Chat.persist_channel_anchor(nil, workspace.default_channel_id, 1) ==
               {:error, :unauthenticated}

      assert Chat.persist_channel_anchor(
               %DiscordClone.Accounts.Scope{},
               workspace.default_channel_id,
               1
             ) == {:error, :unauthenticated}

      assert Chat.persist_channel_anchor(non_member_scope, workspace.default_channel_id, 1) ==
               {:error, :not_found}

      assert Chat.persist_channel_anchor(owner_scope, workspace.default_channel_id, 0) ==
               {:error, :invalid_sequence}

      assert Chat.persist_channel_anchor(owner_scope, workspace.default_channel_id, 4) ==
               {:error, :invalid_sequence}

      assert Chat.persist_channel_anchor(owner_scope, workspace.default_channel_id, "2") ==
               {:error, :invalid_sequence}

      assert %ChannelReadState{last_viewed_anchor_seq: nil} =
               Repo.get_by(ChannelReadState,
                 channel_id: workspace.default_channel_id,
                 user_id: owner_scope.user.id
               )
    end

    test "does not modify unread spans or unread counts" do
      scope = user_scope_fixture()
      other_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      channel_id = workspace.default_channel_id
      add_workspace_member!(workspace, other_scope)
      insert_messages!(channel_id, other_scope.user.id, 8)

      assert {:ok, _read_state} = Chat.add_channel_unread_range(scope, channel_id, 3, 5)

      spans_before = unread_spans(channel_id, scope.user.id)
      counts_before = Chat.list_unread_counts(scope, workspace.id)

      assert {:ok, %ChannelReadState{last_viewed_anchor_seq: 6}} =
               Chat.persist_channel_anchor(scope, channel_id, 6)

      assert unread_spans(channel_id, scope.user.id) == spans_before
      assert Chat.list_unread_counts(scope, workspace.id) == counts_before
    end
  end

  describe "mark_channel_read/2" do
    test "clears unread counts for a workspace member in that channel" do
      scope = user_scope_fixture()
      other_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      {:ok, release_channel} = Workspaces.create_channel(scope, workspace.id, %{name: "release"})

      add_workspace_member!(workspace, other_scope)

      _older_message =
        insert_message!(
          release_channel.id,
          other_scope.user.id,
          "already read",
          ~U[2026-06-19 10:00:00Z]
        )

      insert_message!(
        release_channel.id,
        other_scope.user.id,
        "new release update",
        ~U[2026-06-19 10:01:00Z]
      )

      assert {:ok, _read_state} = Chat.add_channel_unread_range(scope, release_channel.id, 2, 2)

      assert Chat.list_unread_counts(scope, workspace.id) == {:ok, %{release_channel.id => 1}}

      assert :ok = Chat.mark_channel_read(scope, release_channel.id)

      assert Chat.list_unread_counts(scope, workspace.id) == {:ok, %{}}
    end

    test "marks an empty Channel read" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      {:ok, empty_channel} = Workspaces.create_channel(scope, workspace.id, %{name: "empty"})

      assert :ok = Chat.mark_channel_read(scope, empty_channel.id)

      assert %ChannelReadState{unread_count: 0} =
               Repo.get_by(ChannelReadState,
                 channel_id: empty_channel.id,
                 user_id: scope.user.id
               )
    end

    test "clears unread state" do
      scope = user_scope_fixture()
      other_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      add_workspace_member!(workspace, other_scope)

      insert_message!(
        workspace.default_channel_id,
        other_scope.user.id,
        "latest update",
        ~U[2026-06-19 10:00:00Z]
      )

      assert {:ok, _read_state} =
               Chat.add_channel_unread_range(scope, workspace.default_channel_id, 1, 1)

      assert :ok = Chat.mark_channel_read(scope, workspace.default_channel_id)

      assert Chat.list_unread_counts(scope, workspace.id) == {:ok, %{}}
    end

    test "rejects anonymous scopes and logged-in users who are not workspace members" do
      owner_scope = user_scope_fixture()
      non_member_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})

      assert Chat.mark_channel_read(nil, workspace.default_channel_id) ==
               {:error, :unauthenticated}

      assert Chat.mark_channel_read(%DiscordClone.Accounts.Scope{}, workspace.default_channel_id) ==
               {:error, :unauthenticated}

      assert Chat.mark_channel_read(non_member_scope, workspace.default_channel_id) ==
               {:error, :not_found}
    end

    test "does not broadcast read-position changes" do
      scope = user_scope_fixture()
      other_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      add_workspace_member!(workspace, other_scope)

      insert_message!(
        workspace.default_channel_id,
        other_scope.user.id,
        "quietly read",
        ~U[2026-06-19 10:00:00Z]
      )

      assert :ok = Chat.subscribe_to_channel_messages(scope, workspace.default_channel_id)
      assert :ok = Chat.mark_channel_read(scope, workspace.default_channel_id)

      refute_receive {:message_created, _message}
    end

    test "keeps read state after channel runtime loss" do
      scope = user_scope_fixture()
      other_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      channel_id = workspace.default_channel_id
      add_workspace_member!(workspace, other_scope)

      insert_message!(
        channel_id,
        other_scope.user.id,
        "durable read state",
        DateTime.add(DateTime.utc_now(:second), 10, :second)
      )

      assert {:ok, _read_state} = Chat.add_channel_unread_range(scope, channel_id, 1, 1)

      assert {:ok, %{^channel_id => 1}} = Chat.list_unread_counts(scope, workspace.id)
      assert :ok = Chat.mark_channel_read(scope, channel_id)

      assert {:ok, first_pid} = Chat.ensure_channel_runtime(scope, channel_id)
      ref = Process.monitor(first_pid)
      Process.exit(first_pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^first_pid, :killed}
      _ = :sys.get_state(DiscordClone.Chat.ConversationSupervisor)

      assert Chat.list_unread_counts(scope, workspace.id) == {:ok, %{}}
      assert {:ok, second_pid} = Chat.ensure_channel_runtime(scope, channel_id)
      assert second_pid != first_pid
    end
  end

  describe "subscribe_to_channel_messages/2" do
    test "subscribed workspace members receive persisted message-created events" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})

      subscriber =
        start_subscriber(scope, workspace.default_channel_id)

      assert_receive {:subscribed, ^subscriber}

      assert {:ok, sent_message} =
               Chat.send_message(scope, workspace.default_channel_id, %{"content" => "hello live"})

      assert_receive {:subscriber_received, ^subscriber, {:message_created, received_message}}
      assert received_message.id == sent_message.id
      assert received_message.content == "hello live"
      assert received_message.channel_id == workspace.default_channel_id
      assert Ecto.assoc_loaded?(received_message.user)
      assert received_message.user.username == scope.user.username
    end

    test "rejects anonymous scopes" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})

      assert Chat.subscribe_to_channel_messages(nil, workspace.default_channel_id) ==
               {:error, :unauthenticated}

      assert Chat.subscribe_to_channel_messages(
               %DiscordClone.Accounts.Scope{},
               workspace.default_channel_id
             ) == {:error, :unauthenticated}
    end

    test "rejects logged-in users who are not workspace members" do
      owner_scope = user_scope_fixture()
      non_member_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})

      assert Chat.subscribe_to_channel_messages(non_member_scope, workspace.default_channel_id) ==
               {:error, :not_found}
    end

    test "rejects missing channels" do
      scope = user_scope_fixture()

      assert Chat.subscribe_to_channel_messages(scope, "not-a-uuid") == {:error, :not_found}

      assert Chat.initialize_channel_reads_for_workspace_members("not-a-uuid") ==
               {:error, :not_found}

      assert Chat.delete_workspace_reads_for_user("not-a-uuid", "also-invalid") == :ok
    end

    test "does not broadcast invalid message sends" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      :ok = Chat.subscribe_to_channel_messages(scope, workspace.default_channel_id)

      assert {:error, :invalid_message, _changeset} =
               Chat.send_message(scope, workspace.default_channel_id, %{"content" => "   "})

      refute_receive {:message_created, _message}
    end

    test "persists messages longer than the database string default" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      content = String.duplicate("long message ", 99) <> "long message"

      assert {:ok, message} =
               Chat.send_message(scope, workspace.default_channel_id, %{"content" => content})

      assert message.content == content
    end

    test "does not broadcast successful sends back to the sender process" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      :ok = Chat.subscribe_to_channel_messages(scope, workspace.default_channel_id)

      assert {:ok, message} =
               Chat.send_message(scope, workspace.default_channel_id, %{
                 "content" => "sender copy"
               })

      assert message.content == "sender copy"
      refute_receive {:message_created, _message}
    end

    test "does not broadcast unauthorized message sends" do
      owner_scope = user_scope_fixture()
      non_member_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      :ok = Chat.subscribe_to_channel_messages(owner_scope, workspace.default_channel_id)

      assert Chat.send_message(non_member_scope, workspace.default_channel_id, %{
               "content" => "private hello"
             }) == {:error, :not_found}

      refute_receive {:message_created, _message}
    end

    test "does not broadcast read or history-loading workflows" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})

      message =
        insert_message!(
          workspace.default_channel_id,
          scope.user.id,
          "stored",
          ~U[2026-06-19 10:00:00Z]
        )

      :ok = Chat.subscribe_to_channel_messages(scope, workspace.default_channel_id)

      assert {:ok, [_message]} = Chat.list_recent_messages(scope, workspace.default_channel_id)
      assert {:ok, []} = Chat.list_older_messages(scope, workspace.default_channel_id, message)

      refute_receive {:message_created, _message}
    end
  end

  describe "subscribe_to_workspace_messages/2" do
    test "subscribed workspace members receive compact message refresh events including sender sessions" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})

      assert :ok = Chat.subscribe_to_workspace_messages(scope, workspace.id)

      assert {:ok, sent_message} =
               Chat.send_message(scope, workspace.default_channel_id, %{
                 "content" => "refresh unread badges"
               })

      assert_receive {:workspace_message_created, payload}
      assert payload.workspace_id == workspace.id
      assert payload.channel_id == workspace.default_channel_id
      assert payload.message_id == sent_message.id
      assert payload.user_id == scope.user.id
      refute Map.has_key?(payload, :message)
    end

    test "rejects anonymous scopes and logged-in users who are not workspace members" do
      owner_scope = user_scope_fixture()
      non_member_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})

      assert Chat.subscribe_to_workspace_messages(nil, workspace.id) ==
               {:error, :unauthenticated}

      assert Chat.subscribe_to_workspace_messages(%DiscordClone.Accounts.Scope{}, workspace.id) ==
               {:error, :unauthenticated}

      assert Chat.subscribe_to_workspace_messages(non_member_scope, workspace.id) ==
               {:error, :not_found}
    end
  end

  describe "toggle_reaction/3" do
    test "allows a workspace member to add a reaction to an accessible message" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})

      message =
        insert_message!(
          workspace.default_channel_id,
          scope.user.id,
          "ship it",
          ~U[2026-06-30 10:00:00Z]
        )

      assert {:ok, reaction} = Chat.toggle_reaction(scope, message.id, " 👍 ")

      assert reaction.message_id == message.id
      assert reaction.user_id == scope.user.id
      assert reaction.emoji == "👍"
      assert Repo.get_by(MessageReaction, message_id: message.id, user_id: scope.user.id)
      assert count_reactions(message.id, scope.user.id, "👍") == 1
    end

    test "toggles the current user's existing reaction off" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      message = insert_message!(workspace.default_channel_id, scope.user.id, "done", now())

      assert {:ok, reaction} = Chat.toggle_reaction(scope, message.id, "👍")
      assert {:ok, deleted_reaction} = Chat.toggle_reaction(scope, message.id, "👍")

      assert deleted_reaction.id == reaction.id
      refute Repo.get(MessageReaction, reaction.id)
      refute Repo.get_by(MessageReaction, message_id: message.id, user_id: scope.user.id)
    end

    test "keeps different users' matching emoji reactions as separate rows" do
      owner_scope = user_scope_fixture()
      member_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, member_scope)

      message =
        insert_message!(workspace.default_channel_id, owner_scope.user.id, "ship it", now())

      assert {:ok, owner_reaction} = Chat.toggle_reaction(owner_scope, message.id, "👍")
      assert {:ok, member_reaction} = Chat.toggle_reaction(member_scope, message.id, "👍")

      assert owner_reaction.id != member_reaction.id

      reaction_users =
        MessageReaction
        |> where([reaction], reaction.message_id == ^message.id and reaction.emoji == "👍")
        |> select([reaction], reaction.user_id)
        |> Repo.all()
        |> Enum.sort()

      assert reaction_users == Enum.sort([owner_scope.user.id, member_scope.user.id])
    end

    test "allows one user to react with different emoji to the same message" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      message = insert_message!(workspace.default_channel_id, scope.user.id, "choices", now())

      assert {:ok, thumbs_up} = Chat.toggle_reaction(scope, message.id, "👍")
      assert {:ok, heart} = Chat.toggle_reaction(scope, message.id, "❤️")

      assert thumbs_up.id != heart.id

      reaction_emoji =
        MessageReaction
        |> where(
          [reaction],
          reaction.message_id == ^message.id and reaction.user_id == ^scope.user.id
        )
        |> select([reaction], reaction.emoji)
        |> Repo.all()
        |> Enum.sort()

      assert reaction_emoji == Enum.sort(["👍", "❤️"])
    end

    test "rejects anonymous scopes" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      message = insert_message!(workspace.default_channel_id, scope.user.id, "private", now())

      assert Chat.toggle_reaction(nil, message.id, "👍") == {:error, :unauthenticated}

      assert Chat.toggle_reaction(%DiscordClone.Accounts.Scope{}, message.id, "👍") ==
               {:error, :unauthenticated}

      refute Repo.get_by(MessageReaction, message_id: message.id)
    end

    test "rejects logged-in users who are not workspace members" do
      owner_scope = user_scope_fixture()
      non_member_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})

      message =
        insert_message!(workspace.default_channel_id, owner_scope.user.id, "private", now())

      assert Chat.toggle_reaction(non_member_scope, message.id, "👍") == {:error, :not_found}

      refute Repo.get_by(MessageReaction,
               message_id: message.id,
               user_id: non_member_scope.user.id
             )
    end

    test "rejects invalid emoji payloads before storing reaction state" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      message = insert_message!(workspace.default_channel_id, scope.user.id, "payloads", now())

      assert Chat.toggle_reaction(scope, message.id, "👍❤️") ==
               {:error, :invalid_emoji, :multiple_graphemes}

      assert Chat.toggle_reaction(scope, message.id, "   ") == {:error, :invalid_emoji, :blank}
      assert Chat.toggle_reaction(scope, message.id, nil) == {:error, :invalid_emoji, :invalid}

      refute Repo.get_by(MessageReaction, message_id: message.id)
    end

    test "removes related reaction rows when the message is deleted" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      message = insert_message!(workspace.default_channel_id, scope.user.id, "cleanup", now())

      assert {:ok, reaction} = Chat.toggle_reaction(scope, message.id, "👍")
      Repo.delete!(message)

      refute Repo.get(MessageReaction, reaction.id)
    end

    test "removes related reaction rows when the user is deleted" do
      owner_scope = user_scope_fixture()
      member_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, member_scope)

      message =
        insert_message!(workspace.default_channel_id, owner_scope.user.id, "cleanup", now())

      assert {:ok, reaction} = Chat.toggle_reaction(member_scope, message.id, "👍")
      Repo.delete!(member_scope.user)

      refute Repo.get(MessageReaction, reaction.id)
    end
  end

  describe "subscribe_to_channel_reactions/2" do
    test "subscribed workspace members receive compact reaction-change events" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      message = insert_message!(workspace.default_channel_id, scope.user.id, "ship it", now())

      subscriber = start_reaction_subscriber(scope, workspace.default_channel_id)
      assert_receive {:subscribed, ^subscriber}

      assert {:ok, _reaction} = Chat.toggle_reaction(scope, message.id, " 👍 ")

      assert_receive {:subscriber_received, ^subscriber, {:reaction_changed, payload}}
      assert payload.message_id == message.id
      assert payload.emoji == "👍"
      refute Map.has_key?(payload, :message)
      refute Map.has_key?(payload, :reaction)
      refute Map.has_key?(payload, :user)
    end
  end

  describe "list_reaction_summaries/2" do
    test "returns emoji counts keyed by accessible message ID" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      message = insert_message!(workspace.default_channel_id, scope.user.id, "ship it", now())

      assert {:ok, _reaction} = Chat.toggle_reaction(scope, message.id, "👍")

      assert {:ok, summaries} = Chat.list_reaction_summaries(scope, [message.id])

      assert summaries == %{
               message.id => [
                 %{emoji: "👍", count: 1, reacted?: true}
               ]
             }
    end

    test "marks reacted state for the current viewer only" do
      owner_scope = user_scope_fixture()
      member_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, member_scope)

      message =
        insert_message!(workspace.default_channel_id, owner_scope.user.id, "ship it", now())

      assert {:ok, _reaction} = Chat.toggle_reaction(owner_scope, message.id, "👍")

      assert {:ok, owner_summaries} = Chat.list_reaction_summaries(owner_scope, [message.id])
      assert {:ok, member_summaries} = Chat.list_reaction_summaries(member_scope, [message.id])

      assert owner_summaries == %{
               message.id => [
                 %{emoji: "👍", count: 1, reacted?: true}
               ]
             }

      assert member_summaries == %{
               message.id => [
                 %{emoji: "👍", count: 1, reacted?: false}
               ]
             }
    end

    test "groups counts by requested message and emoji" do
      owner_scope = user_scope_fixture()
      member_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, member_scope)

      first_message =
        insert_message!(workspace.default_channel_id, owner_scope.user.id, "first", now())

      second_message =
        insert_message!(workspace.default_channel_id, owner_scope.user.id, "second", now())

      assert {:ok, _reaction} = Chat.toggle_reaction(owner_scope, first_message.id, "👍")
      assert {:ok, _reaction} = Chat.toggle_reaction(member_scope, first_message.id, "👍")
      assert {:ok, _reaction} = Chat.toggle_reaction(member_scope, first_message.id, "❤️")
      assert {:ok, _reaction} = Chat.toggle_reaction(member_scope, second_message.id, "👀")

      assert {:ok, summaries} =
               Chat.list_reaction_summaries(owner_scope, [first_message.id, second_message.id])

      assert summaries == %{
               first_message.id => [
                 %{emoji: "❤️", count: 1, reacted?: false},
                 %{emoji: "👍", count: 2, reacted?: true}
               ],
               second_message.id => [
                 %{emoji: "👀", count: 1, reacted?: false}
               ]
             }
    end

    test "only returns summaries for the bounded message list" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})

      requested_message =
        insert_message!(workspace.default_channel_id, scope.user.id, "in", now())

      other_message = insert_message!(workspace.default_channel_id, scope.user.id, "out", now())

      assert {:ok, _reaction} = Chat.toggle_reaction(scope, requested_message.id, "👍")
      assert {:ok, _reaction} = Chat.toggle_reaction(scope, other_message.id, "❤️")

      assert {:ok, summaries} = Chat.list_reaction_summaries(scope, [requested_message.id])

      assert Map.keys(summaries) == [requested_message.id]
      assert summaries[requested_message.id] == [%{emoji: "👍", count: 1, reacted?: true}]
    end

    test "returns persisted reaction summaries after channel runtime loss" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      channel_id = workspace.default_channel_id

      message = insert_message!(channel_id, scope.user.id, "durable signal", now())
      assert {:ok, _reaction} = Chat.toggle_reaction(scope, message.id, "👍")

      assert {:ok, first_pid} = Chat.ensure_channel_runtime(scope, channel_id)
      ref = Process.monitor(first_pid)
      Process.exit(first_pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^first_pid, :killed}
      _ = :sys.get_state(DiscordClone.Chat.ConversationSupervisor)
      assert Runtime.conversation_pid(channel_id) == nil

      assert {:ok, summaries} = Chat.list_reaction_summaries(scope, [message.id])

      assert summaries == %{
               message.id => [
                 %{emoji: "👍", count: 1, reacted?: true}
               ]
             }

      assert {:ok, second_pid} = Chat.ensure_channel_runtime(scope, channel_id)
      assert second_pid != first_pid
    end

    test "does not store reaction ownership in channel runtime state" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      channel_id = workspace.default_channel_id

      message = insert_message!(channel_id, scope.user.id, "state boundary", now())
      assert {:ok, _reaction} = Chat.toggle_reaction(scope, message.id, "👍")

      assert {:ok, pid} = Chat.ensure_channel_runtime(scope, channel_id)
      state = :sys.get_state(pid)

      assert Map.take(state, [
               :reactions,
               :reaction_counts,
               :reaction_rows,
               :reaction_summaries
             ]) == %{}
    end

    test "rejects anonymous scopes and logged-in users who are not workspace members" do
      owner_scope = user_scope_fixture()
      non_member_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})

      message =
        insert_message!(workspace.default_channel_id, owner_scope.user.id, "private", now())

      assert {:ok, _reaction} = Chat.toggle_reaction(owner_scope, message.id, "👍")

      assert Chat.list_reaction_summaries(nil, [message.id]) == {:error, :unauthenticated}

      assert Chat.list_reaction_summaries(%DiscordClone.Accounts.Scope{}, [message.id]) ==
               {:error, :unauthenticated}

      assert Chat.list_reaction_summaries(non_member_scope, [message.id]) ==
               {:error, :not_found}
    end
  end

  describe "channel typing workflows" do
    test "workspace members can subscribe, start typing, and list raw typing user IDs" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      channel_id = workspace.default_channel_id

      subscriber = start_typing_subscriber(scope, channel_id)
      assert_receive {:subscribed, ^subscriber}

      assert :ok = Chat.user_started_typing(scope, channel_id)

      assert_receive {:subscriber_received, ^subscriber,
                      {:typing_started,
                       %{conversation_id: ^channel_id, user_id: user_id} = payload}}

      assert user_id == scope.user.id
      assert Map.keys(payload) |> Enum.sort() == [:conversation_id, :user_id]
      assert {:ok, [user_id]} = Chat.list_typing_user_ids(scope, channel_id)
      assert user_id == scope.user.id
    end

    test "rejects anonymous scopes and logged-in users who are not workspace members" do
      owner_scope = user_scope_fixture()
      non_member_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      channel_id = workspace.default_channel_id

      assert Chat.subscribe_to_channel_messages(nil, channel_id) == {:error, :unauthenticated}
      assert Chat.user_started_typing(nil, channel_id) == {:error, :unauthenticated}
      assert Chat.user_stopped_typing(nil, channel_id) == {:error, :unauthenticated}
      assert Chat.list_typing_user_ids(nil, channel_id) == {:error, :unauthenticated}

      assert Chat.subscribe_to_channel_messages(non_member_scope, channel_id) ==
               {:error, :not_found}

      assert Chat.user_started_typing(non_member_scope, channel_id) == {:error, :not_found}
      assert Chat.user_stopped_typing(non_member_scope, channel_id) == {:error, :not_found}
      assert Chat.list_typing_user_ids(non_member_scope, channel_id) == {:error, :not_found}
    end

    test "broadcasts typing started only when the member was not already typing" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      channel_id = workspace.default_channel_id

      assert :ok = Chat.subscribe_to_channel_messages(scope, channel_id)

      assert :ok = Chat.user_started_typing(scope, channel_id)
      assert_receive {:typing_started, %{conversation_id: ^channel_id, user_id: user_id}}
      assert user_id == scope.user.id

      assert :ok = Chat.user_started_typing(scope, channel_id)
      refute_receive {:typing_started, %{conversation_id: ^channel_id, user_id: ^user_id}}, 50
      assert {:ok, [^user_id]} = Chat.list_typing_user_ids(scope, channel_id)
    end

    test "workspace members can stop typing and subscribers receive one stopped event" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      channel_id = workspace.default_channel_id

      assert :ok = Chat.subscribe_to_channel_messages(scope, channel_id)

      assert :ok = Chat.user_started_typing(scope, channel_id)
      assert_receive {:typing_started, %{conversation_id: ^channel_id, user_id: user_id}}
      assert user_id == scope.user.id

      assert :ok = Chat.user_stopped_typing(scope, channel_id)

      assert_receive {:typing_stopped,
                      %{conversation_id: ^channel_id, user_id: ^user_id} = payload}

      assert Map.keys(payload) |> Enum.sort() == [:conversation_id, :user_id]
      assert {:ok, []} = Chat.list_typing_user_ids(scope, channel_id)

      assert :ok = Chat.user_stopped_typing(scope, channel_id)
      refute_receive {:typing_stopped, %{conversation_id: ^channel_id, user_id: ^user_id}}, 50
    end

    test "typing expires automatically and subscribers receive a stopped event" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      channel_id = workspace.default_channel_id

      put_conversation_typing_timeout(0)

      assert :ok = Chat.subscribe_to_channel_messages(scope, channel_id)

      assert :ok = Chat.user_started_typing(scope, channel_id)
      assert_receive {:typing_started, %{conversation_id: ^channel_id, user_id: user_id}}
      assert user_id == scope.user.id

      assert_receive {:typing_stopped,
                      %{conversation_id: ^channel_id, user_id: ^user_id} = payload}

      assert Map.keys(payload) |> Enum.sort() == [:conversation_id, :user_id]
      assert {:ok, []} = Chat.list_typing_user_ids(scope, channel_id)
    end

    test "typing state is temporary across channel runtime loss and works again after restart" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      channel_id = workspace.default_channel_id

      assert :ok = Chat.subscribe_to_channel_messages(scope, channel_id)
      assert :ok = Chat.user_started_typing(scope, channel_id)
      assert_receive {:typing_started, %{conversation_id: ^channel_id, user_id: user_id}}
      assert user_id == scope.user.id
      assert {:ok, [^user_id]} = Chat.list_typing_user_ids(scope, channel_id)

      first_pid = Runtime.conversation_pid(channel_id)
      ref = Process.monitor(first_pid)
      Process.exit(first_pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^first_pid, :killed}
      _ = :sys.get_state(DiscordClone.Chat.ConversationSupervisor)

      assert {:ok, []} = Chat.list_typing_user_ids(scope, channel_id)

      assert :ok = Chat.user_started_typing(scope, channel_id)
      assert_receive {:typing_started, %{conversation_id: ^channel_id, user_id: ^user_id}}
      assert {:ok, [^user_id]} = Chat.list_typing_user_ids(scope, channel_id)

      second_pid = Runtime.conversation_pid(channel_id)
      assert is_pid(second_pid)
      assert second_pid != first_pid
    end
  end

  describe "subscribe_to_workspace_presence/2" do
    test "subscribes workspace members without starting the workspace runtime" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})

      assert :ok = Chat.subscribe_to_workspace_presence(scope, workspace.id)
      assert Runtime.workspace_presence_pid(workspace.id) == nil
    end

    test "rejects anonymous scopes" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})

      assert Chat.subscribe_to_workspace_presence(nil, workspace.id) ==
               {:error, :unauthenticated}

      assert Chat.subscribe_to_workspace_presence(%DiscordClone.Accounts.Scope{}, workspace.id) ==
               {:error, :unauthenticated}
    end

    test "rejects logged-in users who are not workspace members" do
      owner_scope = user_scope_fixture()
      non_member_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})

      assert Chat.subscribe_to_workspace_presence(non_member_scope, workspace.id) ==
               {:error, :not_found}
    end
  end

  describe "list_online_workspace_user_ids/2" do
    test "returns an empty list for workspace members without starting an absent runtime" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})

      assert {:ok, []} = Chat.list_online_workspace_user_ids(scope, workspace.id)
      assert Runtime.workspace_presence_pid(workspace.id) == nil
    end

    test "rejects anonymous scopes" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})

      assert Chat.list_online_workspace_user_ids(nil, workspace.id) ==
               {:error, :unauthenticated}

      assert Chat.list_online_workspace_user_ids(%DiscordClone.Accounts.Scope{}, workspace.id) ==
               {:error, :unauthenticated}
    end

    test "rejects logged-in users who are not workspace members" do
      owner_scope = user_scope_fixture()
      non_member_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})

      assert Chat.list_online_workspace_user_ids(non_member_scope, workspace.id) ==
               {:error, :not_found}
    end
  end

  describe "join_workspace_presence/3" do
    test "starts the workspace runtime and tracks the supplied live view pid" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      live_view_pid = start_live_view_process()

      assert :ok = Chat.join_workspace_presence(scope, workspace.id, live_view_pid)

      assert is_pid(Runtime.workspace_presence_pid(workspace.id))
      assert {:ok, [user_id]} = Chat.list_online_workspace_user_ids(scope, workspace.id)
      assert user_id == scope.user.id
    end

    test "defaults to tracking the caller process" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})

      assert :ok = Chat.join_workspace_presence(scope, workspace.id)
      assert {:ok, [user_id]} = Chat.list_online_workspace_user_ids(scope, workspace.id)
      assert user_id == scope.user.id
    end

    test "broadcasts user-level presence events to public subscribers" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      live_view_pid = start_live_view_process()

      assert :ok = Chat.subscribe_to_workspace_presence(scope, workspace.id)
      assert :ok = Chat.join_workspace_presence(scope, workspace.id, live_view_pid)

      assert_receive {:workspace_user_joined,
                      %{workspace_id: workspace_id, user_id: user_id} = payload}

      assert workspace_id == workspace.id
      assert user_id == scope.user.id
      refute Map.has_key?(payload, :user)
      refute Map.has_key?(payload, :members)
    end

    test "schedules existing future timeout expiry when the workspace runtime starts" do
      owner_scope = user_scope_fixture()
      member_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, member_scope)

      assert {:ok, moderation} =
               Workspaces.timeout_member(
                 owner_scope,
                 workspace.id,
                 member_scope.user.id,
                 "5_minutes"
               )

      assert :ok =
               Chat.join_workspace_presence(owner_scope, workspace.id, start_live_view_process())

      pid = Runtime.workspace_presence_pid(workspace.id)
      state = :sys.get_state(pid)

      assert Map.has_key?(state.timeout_timers, moderation.id)
    end

    test "schedules new timeout expiry and cancels it after manual removal" do
      owner_scope = user_scope_fixture()
      member_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, member_scope)

      assert :ok =
               Chat.join_workspace_presence(owner_scope, workspace.id, start_live_view_process())

      pid = Runtime.workspace_presence_pid(workspace.id)

      assert {:ok, moderation} =
               Workspaces.timeout_member(
                 owner_scope,
                 workspace.id,
                 member_scope.user.id,
                 "5_minutes"
               )

      state = :sys.get_state(pid)
      assert Map.has_key?(state.timeout_timers, moderation.id)

      assert {:ok, _ended_moderation} =
               Workspaces.remove_member_timeout(owner_scope, workspace.id, member_scope.user.id)

      state = :sys.get_state(pid)
      refute Map.has_key?(state.timeout_timers, moderation.id)
    end

    test "rejects anonymous scopes" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})

      assert Chat.join_workspace_presence(nil, workspace.id) == {:error, :unauthenticated}

      assert Chat.join_workspace_presence(%DiscordClone.Accounts.Scope{}, workspace.id) ==
               {:error, :unauthenticated}
    end

    test "rejects logged-in users who are not workspace members without starting a runtime" do
      owner_scope = user_scope_fixture()
      non_member_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})

      assert Chat.join_workspace_presence(non_member_scope, workspace.id) == {:error, :not_found}
      assert Runtime.workspace_presence_pid(workspace.id) == nil
    end

    test "runtime crash does not interrupt persisted chat workflows or rejoining presence" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      live_view_pid = start_live_view_process()

      assert :ok = Chat.join_workspace_presence(scope, workspace.id, live_view_pid)
      workspace_pid = Runtime.workspace_presence_pid(workspace.id)
      assert is_pid(workspace_pid)

      ref = Process.monitor(workspace_pid)
      Process.exit(workspace_pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^workspace_pid, :killed}
      _ = :sys.get_state(DiscordClone.Chat.WorkspaceSupervisor)

      subscriber = start_subscriber(scope, workspace.default_channel_id)
      assert_receive {:subscribed, ^subscriber}

      assert {:ok, sent_message} =
               Chat.send_message(scope, workspace.default_channel_id, %{"content" => "still here"})

      assert_receive {:subscriber_received, ^subscriber, {:message_created, received_message}}
      assert received_message.id == sent_message.id

      assert {:ok, [loaded_message]} =
               Chat.list_recent_messages(scope, workspace.default_channel_id)

      assert loaded_message.id == sent_message.id

      recovered_live_view_pid = start_live_view_process()
      assert :ok = Chat.join_workspace_presence(scope, workspace.id, recovered_live_view_pid)
      assert {:ok, [user_id]} = Chat.list_online_workspace_user_ids(scope, workspace.id)
      assert user_id == scope.user.id
    end
  end

  describe "ensure_channel_runtime/2" do
    test "starts a channel runtime for a workspace member" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})

      assert {:ok, pid} = Chat.ensure_channel_runtime(scope, workspace.default_channel_id)
      assert is_pid(pid)
      assert Process.alive?(pid)
    end

    test "reuses the active channel runtime when ensured twice" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})

      assert {:ok, first_pid} = Chat.ensure_channel_runtime(scope, workspace.default_channel_id)
      assert {:ok, second_pid} = Chat.ensure_channel_runtime(scope, workspace.default_channel_id)

      assert second_pid == first_pid
    end

    test "rejects anonymous scopes" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})

      assert Chat.ensure_channel_runtime(nil, workspace.default_channel_id) ==
               {:error, :unauthenticated}

      assert Chat.ensure_channel_runtime(
               %DiscordClone.Accounts.Scope{},
               workspace.default_channel_id
             ) == {:error, :unauthenticated}
    end

    test "rejects logged-in users who are not workspace members" do
      owner_scope = user_scope_fixture()
      non_member_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})

      assert Chat.ensure_channel_runtime(non_member_scope, workspace.default_channel_id) ==
               {:error, :not_found}
    end

    test "rejects missing channels" do
      scope = user_scope_fixture()

      assert Chat.ensure_channel_runtime(scope, -1) == {:error, :not_found}
    end
  end

  describe "list_recent_messages/2" do
    test "jumps to the oldest unread message window without clearing unread state" do
      scope = user_scope_fixture()
      other_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      add_workspace_member!(workspace, other_scope)
      messages = insert_messages!(workspace.default_channel_id, other_scope.user.id, 80)

      assert {:ok, _read_state} =
               Chat.add_channel_unread_range(scope, workspace.default_channel_id, 30, 34)

      assert {:ok, %{messages: window_messages, meta: meta}} =
               Chat.jump_to_oldest_unread(scope, workspace.default_channel_id)

      assert Enum.map(window_messages, & &1.id) ==
               messages |> Enum.slice(14, 51) |> Enum.map(& &1.id)

      assert Enum.map(window_messages, & &1.seq) == Enum.to_list(15..65)

      assert meta == %{
               oldest_seq: 15,
               newest_seq: 65,
               latest_seq: 80,
               has_older?: true,
               has_newer?: true,
               at_latest?: false,
               at_or_near_latest?: true
             }

      assert Chat.list_unread_counts(scope, workspace.id) ==
               {:ok, %{workspace.default_channel_id => 5}}

      assert unread_spans(workspace.default_channel_id, scope.user.id) == [{30, 34}]
    end

    test "jumps to latest by clearing unread state and updating the viewed anchor" do
      scope = user_scope_fixture()
      other_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      add_workspace_member!(workspace, other_scope)
      messages = insert_messages!(workspace.default_channel_id, other_scope.user.id, 80)

      assert {:ok, _read_state} =
               Chat.add_channel_unread_range(scope, workspace.default_channel_id, 30, 34)

      assert {:ok, %{messages: window_messages, meta: meta}} =
               Chat.jump_to_latest(scope, workspace.default_channel_id)

      assert Enum.map(window_messages, & &1.id) ==
               messages |> Enum.drop(30) |> Enum.map(& &1.id)

      assert Enum.map(window_messages, & &1.seq) == Enum.to_list(31..80)

      assert meta == %{
               oldest_seq: 31,
               newest_seq: 80,
               latest_seq: 80,
               has_older?: true,
               has_newer?: false,
               at_latest?: true,
               at_or_near_latest?: true
             }

      assert Chat.list_unread_counts(scope, workspace.id) == {:ok, %{}}
      assert unread_spans(workspace.default_channel_id, scope.user.id) == []

      assert %ChannelReadState{last_viewed_anchor_seq: 80} =
               Repo.get_by(ChannelReadState,
                 channel_id: workspace.default_channel_id,
                 user_id: scope.user.id
               )
    end

    test "requires authenticated workspace membership for explicit read actions" do
      owner_scope = user_scope_fixture()
      non_member_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})

      assert Chat.jump_to_oldest_unread(nil, workspace.default_channel_id) ==
               {:error, :unauthenticated}

      assert Chat.jump_to_latest(%DiscordClone.Accounts.Scope{}, workspace.default_channel_id) ==
               {:error, :unauthenticated}

      assert Chat.jump_to_oldest_unread(non_member_scope, workspace.default_channel_id) ==
               {:error, :not_found}

      assert Chat.jump_to_latest(non_member_scope, workspace.default_channel_id) ==
               {:error, :not_found}
    end

    test "loads the latest sequence window oldest-to-newest with metadata" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      {:ok, other_channel} = Workspaces.create_channel(scope, workspace.id, %{name: "off-topic"})

      messages = insert_messages!(workspace.default_channel_id, scope.user.id, 55)

      insert_message!(
        other_channel.id,
        scope.user.id,
        "wrong channel",
        ~U[2026-06-19 11:00:00Z]
      )

      assert {:ok, %{messages: window_messages, meta: meta}} =
               Chat.load_latest_message_window(scope, workspace.default_channel_id)

      assert Enum.map(window_messages, & &1.id) ==
               messages |> Enum.drop(5) |> Enum.map(& &1.id)

      assert Enum.map(window_messages, & &1.seq) == Enum.to_list(6..55)
      assert Enum.all?(window_messages, &Ecto.assoc_loaded?(&1.user))

      assert meta == %{
               oldest_seq: 6,
               newest_seq: 55,
               latest_seq: 55,
               has_older?: true,
               has_newer?: false,
               at_latest?: true,
               at_or_near_latest?: true
             }
    end

    test "loads a targeted sequence window with a biased before and after split" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      messages = insert_messages!(workspace.default_channel_id, scope.user.id, 100)

      assert {:ok, %{messages: window_messages, meta: meta}} =
               Chat.load_message_window_around(scope, workspace.default_channel_id, 40)

      assert Enum.map(window_messages, & &1.id) ==
               messages |> Enum.slice(24, 51) |> Enum.map(& &1.id)

      assert Enum.map(window_messages, & &1.seq) == Enum.to_list(25..75)

      assert meta == %{
               oldest_seq: 25,
               newest_seq: 75,
               latest_seq: 100,
               has_older?: true,
               has_newer?: true,
               at_latest?: false,
               at_or_near_latest?: true
             }
    end

    test "loads older sequence history before the current oldest sequence" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      messages = insert_messages!(workspace.default_channel_id, scope.user.id, 80)

      assert {:ok, %{messages: window_messages, meta: meta}} =
               Chat.load_older_message_window(scope, workspace.default_channel_id, 26)

      assert Enum.map(window_messages, & &1.id) ==
               messages |> Enum.take(25) |> Enum.map(& &1.id)

      assert Enum.map(window_messages, & &1.seq) == Enum.to_list(1..25)

      assert meta == %{
               oldest_seq: 1,
               newest_seq: 25,
               latest_seq: 80,
               has_older?: false,
               has_newer?: true,
               at_latest?: false,
               at_or_near_latest?: false
             }
    end

    test "loads newer sequence history after the current newest sequence" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      messages = insert_messages!(workspace.default_channel_id, scope.user.id, 80)

      assert {:ok, %{messages: window_messages, meta: meta}} =
               Chat.load_newer_message_window(scope, workspace.default_channel_id, 25)

      assert Enum.map(window_messages, & &1.id) ==
               messages |> Enum.slice(25, 50) |> Enum.map(& &1.id)

      assert Enum.map(window_messages, & &1.seq) == Enum.to_list(26..75)

      assert meta == %{
               oldest_seq: 26,
               newest_seq: 75,
               latest_seq: 80,
               has_older?: true,
               has_newer?: true,
               at_latest?: false,
               at_or_near_latest?: true
             }
    end

    test "loads an empty latest sequence window with useful metadata" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      {:ok, empty_channel} = Workspaces.create_channel(scope, workspace.id, %{name: "empty"})

      assert {:ok, %{messages: [], meta: meta}} =
               Chat.load_latest_message_window(scope, empty_channel.id)

      assert meta == %{
               oldest_seq: nil,
               newest_seq: nil,
               latest_seq: 0,
               has_older?: false,
               has_newer?: false,
               at_latest?: true,
               at_or_near_latest?: true
             }
    end

    test "clamps targeted windows near the beginning and end of channel history" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      insert_messages!(workspace.default_channel_id, scope.user.id, 20)

      assert {:ok, %{messages: first_window, meta: first_meta}} =
               Chat.load_message_window_around(scope, workspace.default_channel_id, 2)

      assert Enum.map(first_window, & &1.seq) == Enum.to_list(1..20)

      assert first_meta == %{
               oldest_seq: 1,
               newest_seq: 20,
               latest_seq: 20,
               has_older?: false,
               has_newer?: false,
               at_latest?: true,
               at_or_near_latest?: true
             }

      assert {:ok, %{messages: last_window, meta: last_meta}} =
               Chat.load_message_window_around(scope, workspace.default_channel_id, 19)

      assert Enum.map(last_window, & &1.seq) == Enum.to_list(4..20)

      assert last_meta == %{
               oldest_seq: 4,
               newest_seq: 20,
               latest_seq: 20,
               has_older?: true,
               has_newer?: false,
               at_latest?: true,
               at_or_near_latest?: true
             }
    end

    test "requires authenticated workspace membership for sequence windows" do
      owner_scope = user_scope_fixture()
      non_member_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})

      assert Chat.load_latest_message_window(nil, workspace.default_channel_id) ==
               {:error, :unauthenticated}

      assert Chat.load_message_window_around(
               %DiscordClone.Accounts.Scope{},
               workspace.default_channel_id,
               1
             ) ==
               {:error, :unauthenticated}

      assert Chat.load_older_message_window(nil, workspace.default_channel_id, 2) ==
               {:error, :unauthenticated}

      assert Chat.load_newer_message_window(nil, workspace.default_channel_id, 1) ==
               {:error, :unauthenticated}

      assert Chat.load_latest_message_window(non_member_scope, workspace.default_channel_id) ==
               {:error, :not_found}

      assert Chat.load_message_window_around(non_member_scope, workspace.default_channel_id, 1) ==
               {:error, :not_found}

      assert Chat.load_older_message_window(non_member_scope, workspace.default_channel_id, 2) ==
               {:error, :not_found}

      assert Chat.load_newer_message_window(non_member_scope, workspace.default_channel_id, 1) ==
               {:error, :not_found}
    end

    test "loads the latest channel messages oldest-to-newest with authors preloaded" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      {:ok, other_channel} = Workspaces.create_channel(scope, workspace.id, %{name: "off-topic"})

      base_time = ~U[2026-06-19 10:00:00Z]

      messages =
        for index <- 1..55 do
          insert_message!(
            workspace.default_channel_id,
            scope.user.id,
            "message #{index}",
            DateTime.add(base_time, index, :second)
          )
        end

      insert_message!(
        other_channel.id,
        scope.user.id,
        "wrong channel",
        DateTime.add(base_time, 56, :second)
      )

      assert {:ok, recent_messages} =
               Chat.list_recent_messages(scope, workspace.default_channel_id)

      assert Enum.map(recent_messages, & &1.id) == messages |> Enum.drop(5) |> Enum.map(& &1.id)
      assert Enum.map(recent_messages, & &1.content) == Enum.map(6..55, &"message #{&1}")
      assert Enum.all?(recent_messages, &Ecto.assoc_loaded?(&1.user))
      assert Enum.all?(recent_messages, &(&1.user.username == scope.user.username))
    end

    test "reads from the active channel runtime cache" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})

      cached_message =
        insert_message!(
          workspace.default_channel_id,
          scope.user.id,
          "cached",
          ~U[2026-06-19 10:00:00Z]
        )

      assert {:ok, [loaded_message]} =
               Chat.list_recent_messages(scope, workspace.default_channel_id)

      assert loaded_message.id == cached_message.id

      uncached_message =
        insert_message!(
          workspace.default_channel_id,
          scope.user.id,
          "not in runtime cache yet",
          ~U[2026-06-19 10:01:00Z]
        )

      assert {:ok, cached_messages} =
               Chat.list_recent_messages(scope, workspace.default_channel_id)

      assert Enum.map(cached_messages, & &1.id) == [cached_message.id]
      refute uncached_message.id in Enum.map(cached_messages, & &1.id)
    end

    test "recovers persisted recent messages after channel runtime loss" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      channel_id = workspace.default_channel_id

      first_message =
        insert_message!(
          channel_id,
          scope.user.id,
          "before runtime loss",
          ~U[2026-06-19 10:00:00Z]
        )

      assert {:ok, [loaded_message]} = Chat.list_recent_messages(scope, channel_id)
      assert loaded_message.id == first_message.id

      assert {:ok, first_pid} = Chat.ensure_channel_runtime(scope, channel_id)
      ref = Process.monitor(first_pid)
      Process.exit(first_pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^first_pid, :killed}
      _ = :sys.get_state(DiscordClone.Chat.ConversationSupervisor)

      second_message =
        insert_message!(
          channel_id,
          scope.user.id,
          "after runtime loss",
          ~U[2026-06-19 10:01:00Z]
        )

      assert {:ok, recovered_messages} = Chat.list_recent_messages(scope, channel_id)
      assert Enum.map(recovered_messages, & &1.id) == [first_message.id, second_message.id]

      assert {:ok, second_pid} = Chat.ensure_channel_runtime(scope, channel_id)
      assert second_pid != first_pid
      assert Runtime.conversation_pid(channel_id) == second_pid
    end

    test "rejects anonymous scopes" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})

      assert Chat.list_recent_messages(nil, workspace.default_channel_id) ==
               {:error, :unauthenticated}

      assert Chat.list_recent_messages(
               %DiscordClone.Accounts.Scope{},
               workspace.default_channel_id
             ) ==
               {:error, :unauthenticated}
    end

    test "rejects logged-in users who are not workspace members" do
      owner_scope = user_scope_fixture()
      non_member_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})

      insert_message!(
        workspace.default_channel_id,
        owner_scope.user.id,
        "private message",
        ~U[2026-06-19 10:00:00Z]
      )

      assert Chat.list_recent_messages(non_member_scope, workspace.default_channel_id) ==
               {:error, :not_found}
    end
  end

  describe "list_older_messages/3" do
    test "loads messages older than the cursor oldest-to-newest with authors preloaded" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})

      base_time = ~U[2026-06-19 10:00:00Z]

      messages =
        for index <- 1..55 do
          insert_message!(
            workspace.default_channel_id,
            scope.user.id,
            "message #{index}",
            DateTime.add(base_time, index, :second)
          )
        end

      {:ok, recent_messages} = Chat.list_recent_messages(scope, workspace.default_channel_id)
      cursor = hd(recent_messages)

      assert {:ok, older_messages} =
               Chat.list_older_messages(scope, workspace.default_channel_id, cursor)

      assert Enum.map(older_messages, & &1.id) == messages |> Enum.take(5) |> Enum.map(& &1.id)
      assert Enum.map(older_messages, & &1.content) == Enum.map(1..5, &"message #{&1}")
      refute cursor.id in Enum.map(older_messages, & &1.id)
      assert Enum.all?(older_messages, &Ecto.assoc_loaded?(&1.user))
      assert Enum.all?(older_messages, &(&1.user.username == scope.user.username))
    end

    test "does not load older messages from another channel" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      {:ok, other_channel} = Workspaces.create_channel(scope, workspace.id, %{name: "off-topic"})

      base_time = ~U[2026-06-19 10:00:00Z]

      messages =
        for index <- 1..55 do
          insert_message!(
            workspace.default_channel_id,
            scope.user.id,
            "message #{index}",
            DateTime.add(base_time, index, :second)
          )
        end

      other_channel_message =
        insert_message!(
          other_channel.id,
          scope.user.id,
          "wrong older channel",
          DateTime.add(base_time, 3, :second)
        )

      {:ok, recent_messages} = Chat.list_recent_messages(scope, workspace.default_channel_id)
      cursor = hd(recent_messages)

      assert {:ok, older_messages} =
               Chat.list_older_messages(scope, workspace.default_channel_id, cursor)

      assert Enum.map(older_messages, & &1.id) == messages |> Enum.take(5) |> Enum.map(& &1.id)
      refute other_channel_message.id in Enum.map(older_messages, & &1.id)
    end

    test "paginates messages that share a timestamp without duplicates or skips" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      shared_time = ~U[2026-06-19 10:00:00Z]

      messages =
        for index <- 1..55 do
          insert_message!(
            workspace.default_channel_id,
            scope.user.id,
            "message #{index}",
            shared_time
          )
        end

      {:ok, recent_messages} = Chat.list_recent_messages(scope, workspace.default_channel_id)
      cursor = hd(recent_messages)

      assert {:ok, older_messages} =
               Chat.list_older_messages(scope, workspace.default_channel_id, cursor)

      assert Enum.map(recent_messages, & &1.id) == messages |> Enum.drop(5) |> Enum.map(& &1.id)
      assert Enum.map(older_messages, & &1.id) == messages |> Enum.take(5) |> Enum.map(& &1.id)

      assert MapSet.disjoint?(
               MapSet.new(recent_messages, & &1.id),
               MapSet.new(older_messages, & &1.id)
             )
    end

    test "rejects anonymous scopes" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})

      cursor =
        insert_message!(
          workspace.default_channel_id,
          scope.user.id,
          "message",
          ~U[2026-06-19 10:00:00Z]
        )

      assert Chat.list_older_messages(nil, workspace.default_channel_id, cursor) ==
               {:error, :unauthenticated}

      assert Chat.list_older_messages(
               %DiscordClone.Accounts.Scope{},
               workspace.default_channel_id,
               cursor
             ) == {:error, :unauthenticated}
    end

    test "rejects logged-in users who are not workspace members" do
      owner_scope = user_scope_fixture()
      non_member_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})

      cursor =
        insert_message!(
          workspace.default_channel_id,
          owner_scope.user.id,
          "private message",
          ~U[2026-06-19 10:00:00Z]
        )

      assert Chat.list_older_messages(non_member_scope, workspace.default_channel_id, cursor) ==
               {:error, :not_found}
    end
  end

  describe "workspace moderation enforcement" do
    test "muted members can read but cannot send messages, react, or start typing" do
      owner_scope = user_scope_fixture()
      member_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, member_scope)

      message =
        insert_message!(workspace.default_channel_id, owner_scope.user.id, "readable", now())

      assert {:ok, _channel} = Chat.open_channel(member_scope, workspace.default_channel_id)

      assert {:ok, _moderation} =
               Workspaces.mute_member(owner_scope, workspace.id, member_scope.user.id, %{})

      assert Chat.send_message(member_scope, workspace.default_channel_id, %{
               "content" => "blocked"
             }) == {:error, :muted}

      assert Chat.toggle_reaction(member_scope, message.id, "👍") == {:error, :muted}

      assert Chat.user_started_typing(member_scope, workspace.default_channel_id) ==
               {:error, :muted}
    end

    test "timed-out members can read but cannot send messages, react, or start typing" do
      owner_scope = user_scope_fixture()
      member_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, member_scope)

      message =
        insert_message!(workspace.default_channel_id, owner_scope.user.id, "readable", now())

      assert {:ok, _channel} = Chat.open_channel(member_scope, workspace.default_channel_id)

      assert {:ok, _moderation} =
               Workspaces.timeout_member(
                 owner_scope,
                 workspace.id,
                 member_scope.user.id,
                 "1_hour"
               )

      assert Chat.send_message(member_scope, workspace.default_channel_id, %{
               "content" => "blocked"
             }) == {:error, :timeout}

      assert Chat.toggle_reaction(member_scope, message.id, "👍") == {:error, :timeout}

      assert Chat.user_started_typing(member_scope, workspace.default_channel_id) ==
               {:error, :timeout}
    end
  end

  describe "delete_message/2" do
    test "allows an author to soft delete their own message without removing it from message windows" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})

      assert {:ok, message} =
               Chat.send_message(scope, workspace.default_channel_id, %{
                 "content" => "delete my draft"
               })

      assert {:ok, deleted_message} = Chat.delete_message(scope, message.id)

      assert deleted_message.id == message.id
      assert deleted_message.content == "delete my draft"
      assert deleted_message.deleted_at
      assert deleted_message.deleted_by_user_id == scope.user.id

      assert %Message{} = stored_message = Repo.get!(Message, message.id)
      assert stored_message.content == "delete my draft"
      assert stored_message.deleted_at == deleted_message.deleted_at

      assert {:ok, %{messages: [window_message]}} =
               Chat.load_latest_message_window(scope, workspace.default_channel_id)

      assert window_message.id == message.id
      assert window_message.deleted_at == deleted_message.deleted_at
      assert window_message.content == "delete my draft"

      assert {:ok, []} = Workspaces.list_audit_events(scope, workspace.id)
    end

    test "allows an owner to delete a member message and records a moderation audit event" do
      owner_scope = user_scope_fixture()
      member_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, member_scope)

      assert {:ok, message} =
               Chat.send_message(member_scope, workspace.default_channel_id, %{
                 "content" => "needs moderation"
               })

      assert {:ok, deleted_message} = Chat.delete_message(owner_scope, message.id)

      assert deleted_message.deleted_by_user_id == owner_scope.user.id

      assert {:ok, [audit_event]} = Workspaces.list_audit_events(owner_scope, workspace.id)
      assert audit_event.event_type == "moderator_message_deleted"
      assert audit_event.actor_user_id == owner_scope.user.id
      assert audit_event.target_user_id == member_scope.user.id
      assert audit_event.metadata["message_id"] == message.id
      assert audit_event.metadata["channel_id"] == workspace.default_channel_id
      assert audit_event.metadata["channel_name"] == "general"
    end

    test "enforces moderator delete boundaries by role" do
      owner_scope = user_scope_fixture()
      admin_scope = user_scope_fixture()
      member_scope = user_scope_fixture()
      other_member_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, admin_scope, "admin")
      add_workspace_member!(workspace, member_scope, "member")
      add_workspace_member!(workspace, other_member_scope, "member")

      {:ok, member_message} =
        Chat.send_message(member_scope, workspace.default_channel_id, %{
          "content" => "member message"
        })

      {:ok, admin_message} =
        Chat.send_message(admin_scope, workspace.default_channel_id, %{
          "content" => "admin message"
        })

      {:ok, owner_message} =
        Chat.send_message(owner_scope, workspace.default_channel_id, %{
          "content" => "owner message"
        })

      assert {:ok, _deleted_message} = Chat.delete_message(admin_scope, member_message.id)
      assert {:ok, _deleted_message} = Chat.delete_message(admin_scope, admin_message.id)
      assert Chat.delete_message(admin_scope, owner_message.id) == {:error, :unauthorized}
      assert Chat.delete_message(other_member_scope, owner_message.id) == {:error, :unauthorized}
    end

    test "removes existing reactions and rejects future reactions on deleted messages" do
      owner_scope = user_scope_fixture()
      member_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, member_scope)

      {:ok, message} =
        Chat.send_message(owner_scope, workspace.default_channel_id, %{
          "content" => "reaction cleanup"
        })

      assert {:ok, _reaction} = Chat.toggle_reaction(owner_scope, message.id, "👍")
      assert {:ok, _reaction} = Chat.toggle_reaction(member_scope, message.id, "❤️")

      assert {:ok, summaries} = Chat.list_reaction_summaries(owner_scope, [message.id])
      assert Map.has_key?(summaries, message.id)

      assert {:ok, _deleted_message} = Chat.delete_message(owner_scope, message.id)

      refute Repo.get_by(MessageReaction, message_id: message.id)
      assert {:ok, %{}} = Chat.list_reaction_summaries(owner_scope, [message.id])
      assert Chat.toggle_reaction(member_scope, message.id, "👍") == {:error, :message_deleted}
    end

    test "broadcasts message deletion and updates the channel runtime cache" do
      owner_scope = user_scope_fixture()
      member_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, member_scope)

      assert {:ok, message} =
               Chat.send_message(owner_scope, workspace.default_channel_id, %{
                 "content" => "live delete"
               })

      subscriber = start_subscriber(member_scope, workspace.default_channel_id)
      assert_receive {:subscribed, ^subscriber}

      assert {:ok, deleted_message} = Chat.delete_message(owner_scope, message.id)

      assert_receive {:subscriber_received, ^subscriber, {:message_deleted, payload}}
      assert payload.message_id == message.id
      assert payload.conversation_id == workspace.default_channel_id

      assert {:ok, [cached_message]} =
               Chat.list_recent_messages(owner_scope, workspace.default_channel_id)

      assert cached_message.id == message.id
      assert cached_message.deleted_at == deleted_message.deleted_at
    end
  end

  describe "can_delete_message?/3" do
    setup do
      owner_scope = user_scope_fixture()
      admin_scope = user_scope_fixture()
      member_scope = user_scope_fixture()
      other_member_scope = user_scope_fixture()
      outsider_scope = user_scope_fixture()

      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      admin_membership = add_workspace_member!(workspace, admin_scope, "admin")
      member_membership = add_workspace_member!(workspace, member_scope, "member")
      other_member_membership = add_workspace_member!(workspace, other_member_scope, "member")

      {:ok, members} = Workspaces.list_members(owner_scope, workspace.id)
      member_by_user_id = Map.new(members, &{&1.user_id, &1})

      %{
        owner_scope: owner_scope,
        admin_scope: admin_scope,
        member_scope: member_scope,
        other_member_scope: other_member_scope,
        outsider_scope: outsider_scope,
        member_by_user_id: member_by_user_id,
        admin_membership: admin_membership,
        member_membership: member_membership,
        other_member_membership: other_member_membership
      }
    end

    test "an author may delete their own message regardless of role", ctx do
      message = %Message{user_id: ctx.member_scope.user.id}
      assert Chat.can_delete_message?(ctx.member_scope, message, ctx.member_by_user_id)
    end

    test "an owner may delete admin- and member-authored messages", ctx do
      admin_message = %Message{user_id: ctx.admin_scope.user.id}
      member_message = %Message{user_id: ctx.member_scope.user.id}

      assert Chat.can_delete_message?(ctx.owner_scope, admin_message, ctx.member_by_user_id)
      assert Chat.can_delete_message?(ctx.owner_scope, member_message, ctx.member_by_user_id)
    end

    test "an admin may delete admin- and member-authored messages", ctx do
      admin_message = %Message{user_id: ctx.admin_scope.user.id}
      member_message = %Message{user_id: ctx.member_scope.user.id}

      assert Chat.can_delete_message?(ctx.admin_scope, admin_message, ctx.member_by_user_id)
      assert Chat.can_delete_message?(ctx.admin_scope, member_message, ctx.member_by_user_id)
    end

    test "a moderator may not delete an owner-authored message", ctx do
      owner_message = %Message{user_id: ctx.owner_scope.user.id}

      refute Chat.can_delete_message?(ctx.admin_scope, owner_message, ctx.member_by_user_id)
    end

    test "a member may not delete another member's message", ctx do
      member_message = %Message{user_id: ctx.member_scope.user.id}

      refute Chat.can_delete_message?(
               ctx.other_member_scope,
               member_message,
               ctx.member_by_user_id
             )
    end

    test "a user without a membership in the map may not delete another's message", ctx do
      member_message = %Message{user_id: ctx.member_scope.user.id}

      refute Chat.can_delete_message?(ctx.outsider_scope, member_message, ctx.member_by_user_id)
    end
  end

  describe "soft_delete_user_workspace_messages/4" do
    test "rolls bulk moderation back when activity cleanup fails" do
      owner_scope = user_scope_fixture(user_fixture(%{username: "bulk_rollback_owner"}))
      target_scope = user_scope_fixture(user_fixture(%{username: "bulk_rollback_target"}))
      recipient_scope = user_scope_fixture(user_fixture(%{username: "bulk_rollback_recipient"}))
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Cleanup"})
      add_workspace_member!(workspace, target_scope, "member")
      add_workspace_member!(workspace, recipient_scope, "member")

      {:ok, message} =
        Chat.send_message(target_scope, workspace.default_channel_id, %{
          content: "hello @bulk_rollback_recipient"
        })

      activity_item = Repo.get_by!(ActivityItem, source_message_id: message.id)
      install_reject_activity_cleanup_trigger!()

      assert_raise Postgrex.Error, fn ->
        Chat.soft_delete_user_workspace_messages(
          workspace.id,
          target_scope.user.id,
          owner_scope.user.id,
          :all
        )
      end

      assert is_nil(Repo.get!(Message, message.id).deleted_at)
      assert Repo.get(ActivityItem, activity_item.id)
    end

    test "removes activity for every moderated message while preserving unaffected activity" do
      owner_scope = user_scope_fixture(user_fixture(%{username: "cleanup_owner"}))
      target_scope = user_scope_fixture(user_fixture(%{username: "cleanup_target"}))
      recipient_scope = user_scope_fixture(user_fixture(%{username: "cleanup_recipient"}))
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Cleanup"})
      channel_id = workspace.default_channel_id
      add_workspace_member!(workspace, target_scope, "member")
      add_workspace_member!(workspace, recipient_scope, "member")

      {:ok, first} =
        Chat.send_message(target_scope, channel_id, %{content: "first @cleanup_recipient"})

      {:ok, second} =
        Chat.send_message(target_scope, channel_id, %{content: "second @cleanup_recipient"})

      {:ok, unaffected} =
        Chat.send_message(owner_scope, channel_id, %{content: "keep @cleanup_recipient"})

      assert {:ok, deleted_messages} =
               Chat.soft_delete_user_workspace_messages(
                 workspace.id,
                 target_scope.user.id,
                 owner_scope.user.id,
                 :all
               )

      assert Enum.map(deleted_messages, & &1.id) |> Enum.sort() ==
               Enum.sort([first.id, second.id])

      refute Repo.get_by(ActivityItem, source_message_id: first.id)
      refute Repo.get_by(ActivityItem, source_message_id: second.id)
      assert Repo.get_by(ActivityItem, source_message_id: unaffected.id)
    end

    test "soft-deletes only the target's messages inside the time window and removes their reactions" do
      owner_scope = user_scope_fixture()
      target_scope = user_scope_fixture()
      other_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Cleanup"})
      channel_id = workspace.default_channel_id
      add_workspace_member!(workspace, target_scope, "member")
      add_workspace_member!(workspace, other_scope, "member")

      {:ok, recent} = Chat.send_message(target_scope, channel_id, %{"content" => "recent"})
      {:ok, stale} = Chat.send_message(target_scope, channel_id, %{"content" => "stale"})
      {:ok, other} = Chat.send_message(other_scope, channel_id, %{"content" => "someone else"})

      backdate_message!(stale, ~U[2020-01-01 00:00:00Z])

      {:ok, _reaction} = Chat.toggle_reaction(other_scope, recent.id, "👍")

      cutoff = DateTime.add(DateTime.utc_now(:second), -1, :hour)

      assert {:ok, deleted_messages} =
               Chat.soft_delete_user_workspace_messages(
                 workspace.id,
                 target_scope.user.id,
                 owner_scope.user.id,
                 cutoff
               )

      assert Enum.map(deleted_messages, & &1.id) == [recent.id]

      assert %Message{deleted_at: %DateTime{}, deleted_by_user_id: deleter} =
               Repo.get(Message, recent.id)

      assert deleter == owner_scope.user.id
      refute Repo.get_by(MessageReaction, message_id: recent.id)

      assert is_nil(Repo.get(Message, stale.id).deleted_at)
      assert is_nil(Repo.get(Message, other.id).deleted_at)
    end

    test "with an :all bound soft-deletes every matching message regardless of age" do
      owner_scope = user_scope_fixture()
      target_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Cleanup"})
      channel_id = workspace.default_channel_id
      add_workspace_member!(workspace, target_scope, "member")

      {:ok, recent} = Chat.send_message(target_scope, channel_id, %{"content" => "recent"})
      {:ok, ancient} = Chat.send_message(target_scope, channel_id, %{"content" => "ancient"})
      backdate_message!(ancient, ~U[2000-01-01 00:00:00Z])

      assert {:ok, deleted_messages} =
               Chat.soft_delete_user_workspace_messages(
                 workspace.id,
                 target_scope.user.id,
                 owner_scope.user.id,
                 :all
               )

      assert Enum.map(deleted_messages, & &1.id) |> Enum.sort() ==
               Enum.sort([recent.id, ancient.id])

      assert Repo.get(Message, recent.id).deleted_at
      assert Repo.get(Message, ancient.id).deleted_at
    end
  end

  describe "send_message/3" do
    test "persists one Message Reply target and batch-loads its preview in message windows" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      channel_id = workspace.default_channel_id

      assert {:ok, parent} =
               Chat.send_message(scope, channel_id, %{"content" => "original message"})

      assert {:ok, first_reply} =
               Chat.send_message(scope, channel_id, %{
                 "content" => "first reply",
                 "reply_to_message_id" => parent.id
               })

      assert {:ok, nested_reply} =
               Chat.send_message(scope, channel_id, %{
                 "content" => "reply to a reply",
                 "reply_to_message_id" => first_reply.id
               })

      assert first_reply.reply_to_message_id == parent.id
      assert nested_reply.reply_to_message_id == first_reply.id
      assert Ecto.assoc_loaded?(nested_reply.reply_to_message)
      assert nested_reply.reply_to_message.id == first_reply.id
      refute Ecto.assoc_loaded?(nested_reply.reply_to_message.reply_to_message)

      assert {:ok, %{messages: messages}} = Chat.load_latest_message_window(scope, channel_id)
      loaded_nested_reply = Enum.find(messages, &(&1.id == nested_reply.id))

      assert Ecto.assoc_loaded?(loaded_nested_reply.reply_to_message)
      assert Ecto.assoc_loaded?(loaded_nested_reply.reply_to_message.user)
      assert loaded_nested_reply.reply_to_message.id == first_reply.id
      assert loaded_nested_reply.reply_to_message.user.username == scope.user.username
      refute Ecto.assoc_loaded?(loaded_nested_reply.reply_to_message.reply_to_message)

      assert {:ok, runtime_pid} = Chat.ensure_channel_runtime(scope, channel_id)
      runtime_ref = Process.monitor(runtime_pid)
      Process.exit(runtime_pid, :kill)
      assert_receive {:DOWN, ^runtime_ref, :process, ^runtime_pid, :killed}
      _ = :sys.get_state(DiscordClone.Chat.ConversationSupervisor)

      assert {:ok, recent_messages} = Chat.list_recent_messages(scope, channel_id)
      reloaded_nested_reply = Enum.find(recent_messages, &(&1.id == nested_reply.id))
      assert reloaded_nested_reply.reply_to_message.id == first_reply.id
      assert Ecto.assoc_loaded?(reloaded_nested_reply.reply_to_message.user)

      assert {:ok, unrelated_message} =
               Chat.send_message(scope, channel_id, %{"content" => "another target"})

      assert {:ok, updated_reply} =
               first_reply
               |> Message.changeset(%{
                 "content" => "edited reply body",
                 "reply_to_message_id" => unrelated_message.id
               })
               |> Repo.update()

      assert updated_reply.reply_to_message_id == parent.id
    end

    test "loads reply previews for a bounded window with a constant number of queries" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      channel_id = workspace.default_channel_id
      {:ok, parent} = Chat.send_message(scope, channel_id, %{"content" => "parent"})

      for index <- 1..20 do
        assert {:ok, _reply} =
                 Chat.send_message(scope, channel_id, %{
                   "content" => "reply #{index}",
                   "reply_to_message_id" => parent.id
                 })
      end

      test_pid = self()
      handler_id = "reply-window-query-count-#{System.unique_integer([:positive])}"

      :ok =
        :telemetry.attach(
          handler_id,
          [:discord_clone, :repo, :query],
          fn _event, _measurements, _metadata, _config ->
            if self() == test_pid, do: send(test_pid, :reply_window_query)
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert {:ok, %{messages: messages}} = Chat.load_latest_message_window(scope, channel_id)
      assert length(messages) == 21
      assert Enum.all?(Enum.drop(messages, 1), &Ecto.assoc_loaded?(&1.reply_to_message))
      assert drain_reply_window_queries() <= 6
    end

    test "rejects missing, cross-channel, future-sequence, and deleted reply targets" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      {:ok, other_channel} = Workspaces.create_channel(scope, workspace.id, %{name: "off-topic"})
      channel_id = workspace.default_channel_id

      assert_reply_target_rejected(scope, channel_id, Ecto.UUID.generate())

      assert {:ok, cross_channel_message} =
               Chat.send_message(scope, other_channel.id, %{"content" => "elsewhere"})

      assert_reply_target_rejected(scope, channel_id, cross_channel_message.id)

      future_message =
        Repo.insert!(%Message{
          channel_id: channel_id,
          user_id: scope.user.id,
          content: "out of sequence",
          seq: 10
        })

      assert_reply_target_rejected(scope, channel_id, future_message.id)

      Repo.delete!(future_message)

      assert {:ok, deleted_message} =
               Chat.send_message(scope, channel_id, %{"content" => "soon deleted"})

      assert {:ok, _deleted_message} = Chat.delete_message(scope, deleted_message.id)
      assert_reply_target_rejected(scope, channel_id, deleted_message.id)
    end

    test "persists trimmed content in the selected channel with the author preloaded" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      {:ok, other_channel} = Workspaces.create_channel(scope, workspace.id, %{name: "off-topic"})

      assert {:ok, message} =
               Chat.send_message(scope, workspace.default_channel_id, %{
                 "channel_id" => other_channel.id,
                 "content" => "  hello channel  "
               })

      assert message.content == "hello channel"
      assert message.channel_id == workspace.default_channel_id
      assert message.user_id == scope.user.id
      assert Ecto.assoc_loaded?(message.user)
      assert message.user.username == scope.user.username
      assert Repo.get!(Message, message.id).content == "hello channel"
    end

    test "assigns increasing sequence numbers in the selected channel" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      channel_id = workspace.default_channel_id

      assert {:ok, first_message} =
               Chat.send_message(scope, channel_id, %{"content" => "first sequenced"})

      assert {:ok, second_message} =
               Chat.send_message(scope, channel_id, %{"content" => "second sequenced"})

      assert first_message.seq == 1
      assert second_message.seq == 2
      assert Repo.get!(Conversation, channel_id).last_message_seq == 2
    end

    test "creates unread state for channel recipients when a message is sent" do
      sender_scope = user_scope_fixture()
      recipient_scope = user_scope_fixture()
      second_recipient_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(sender_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, recipient_scope)
      add_workspace_member!(workspace, second_recipient_scope)
      channel_id = workspace.default_channel_id

      assert {:ok, message} =
               Chat.send_message(sender_scope, channel_id, %{"content" => "hello recipient"})

      for recipient_scope <- [recipient_scope, second_recipient_scope] do
        assert %ChannelReadState{} =
                 recipient_read_state =
                 Repo.get_by(ChannelReadState,
                   channel_id: channel_id,
                   user_id: recipient_scope.user.id
                 )

        assert recipient_read_state.unread_count == 1
        assert recipient_read_state.first_unread_seq == message.seq
        assert recipient_read_state.last_unread_seq == message.seq
        assert [{message.seq, message.seq}] == unread_spans(channel_id, recipient_scope.user.id)
      end

      refute Repo.get_by(ChannelUnreadSpan, channel_id: channel_id, user_id: sender_scope.user.id)
    end

    test "does not clear the sender's older unread spans when sending" do
      sender_scope = user_scope_fixture()
      recipient_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(sender_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, recipient_scope)
      channel_id = workspace.default_channel_id

      insert_messages!(channel_id, recipient_scope.user.id, 3)
      assert {:ok, _read_state} = Chat.add_channel_unread_range(sender_scope, channel_id, 1, 3)

      assert {:ok, message} =
               Chat.send_message(sender_scope, channel_id, %{
                 "content" => "reply without clearing"
               })

      assert unread_spans(channel_id, sender_scope.user.id) == [{1, 3}]

      assert %ChannelReadState{} =
               sender_read_state =
               Repo.get_by(ChannelReadState,
                 channel_id: channel_id,
                 user_id: sender_scope.user.id
               )

      assert sender_read_state.unread_count == 3
      assert sender_read_state.first_unread_seq == 1
      assert sender_read_state.last_unread_seq == 3
      refute {message.seq, message.seq} in unread_spans(channel_id, sender_scope.user.id)
    end

    test "merges sent messages into adjacent recipient unread spans" do
      sender_scope = user_scope_fixture()
      recipient_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(sender_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, recipient_scope)
      channel_id = workspace.default_channel_id

      insert_messages!(channel_id, sender_scope.user.id, 2)
      assert {:ok, _read_state} = Chat.add_channel_unread_range(recipient_scope, channel_id, 1, 2)

      assert {:ok, message} =
               Chat.send_message(sender_scope, channel_id, %{"content" => "third unread"})

      assert message.seq == 3
      assert unread_spans(channel_id, recipient_scope.user.id) == [{1, 3}]

      assert %ChannelReadState{} =
               recipient_read_state =
               Repo.get_by(ChannelReadState,
                 channel_id: channel_id,
                 user_id: recipient_scope.user.id
               )

      assert recipient_read_state.unread_count == 3
      assert recipient_read_state.first_unread_seq == 1
      assert recipient_read_state.last_unread_seq == 3
    end

    test "broadcasts recipient read-state changes before shared message refreshes" do
      sender_scope = user_scope_fixture()
      recipient_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(sender_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, recipient_scope)
      channel_id = workspace.default_channel_id

      assert :ok = Chat.subscribe_to_channel_read_state(recipient_scope, channel_id)
      assert :ok = Chat.subscribe_to_workspace_messages(recipient_scope, workspace.id)

      assert {:ok, message} =
               Chat.send_message(sender_scope, channel_id, %{
                 "content" => "broadcast after fanout"
               })

      assert_receive {:channel_read_state_changed,
                      %{
                        workspace_id: workspace_id,
                        channel_id: ^channel_id,
                        unread_count: 1,
                        first_unread_seq: first_unread_seq,
                        last_unread_seq: last_unread_seq
                      }}

      assert workspace_id == workspace.id
      assert first_unread_seq == message.seq
      assert last_unread_seq == message.seq

      assert_receive {:workspace_message_created, payload}

      assert payload == %{
               workspace_id: workspace.id,
               channel_id: channel_id,
               message_id: message.id,
               user_id: sender_scope.user.id
             }
    end

    test "keeps sequence numbers isolated per channel" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      {:ok, release_channel} = Workspaces.create_channel(scope, workspace.id, %{name: "release"})

      assert {:ok, general_message} =
               Chat.send_message(scope, workspace.default_channel_id, %{
                 "content" => "general first"
               })

      assert {:ok, release_message} =
               Chat.send_message(scope, release_channel.id, %{"content" => "release first"})

      assert general_message.seq == 1
      assert release_message.seq == 1
      assert Repo.get!(Conversation, workspace.default_channel_id).last_message_seq == 1
      assert Repo.get!(Conversation, release_channel.id).last_message_seq == 1
    end

    test "assigns unique contiguous sequences for concurrent sends in the same channel" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      channel_id = workspace.default_channel_id

      messages =
        1..12
        |> Task.async_stream(
          fn index ->
            assert {:ok, message} =
                     Chat.send_message(scope, channel_id, %{
                       "content" => "concurrent #{index}"
                     })

            message
          end,
          max_concurrency: 12,
          timeout: :infinity
        )
        |> Enum.map(fn {:ok, message} -> message end)

      assert messages |> Enum.map(& &1.seq) |> Enum.sort() == Enum.to_list(1..12)
      assert Repo.get!(Conversation, channel_id).last_message_seq == 12

      persisted_sequences =
        Message
        |> where([message], message.channel_id == ^channel_id)
        |> order_by([message], asc: message.seq)
        |> select([message], message.seq)
        |> Repo.all()

      assert persisted_sequences == Enum.to_list(1..12)
    end

    test "rejects duplicate sequence numbers in the same channel" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      channel_id = workspace.default_channel_id

      assert {:ok, message} =
               Chat.send_message(scope, channel_id, %{"content" => "already sequenced"})

      duplicate_changeset =
        %Message{}
        |> Message.changeset(%{
          "channel_id" => channel_id,
          "user_id" => scope.user.id,
          "content" => "duplicate sequence"
        })
        |> Ecto.Changeset.put_change(:seq, message.seq)

      assert {:error, changeset} = Repo.insert(duplicate_changeset)
      assert %{seq: ["has already been taken"]} = errors_on(changeset)
    end

    test "rejects invalid sequence boundaries" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      channel_id = workspace.default_channel_id

      message_changeset =
        %Message{}
        |> Message.changeset(%{
          "channel_id" => channel_id,
          "user_id" => scope.user.id,
          "content" => "invalid sequence"
        })
        |> Ecto.Changeset.put_change(:seq, 0)

      assert {:error, changeset} = Repo.insert(message_changeset)
      assert %{seq: ["is invalid"]} = errors_on(changeset)

      conversation_changeset =
        Conversation
        |> Repo.get!(channel_id)
        |> Ecto.Changeset.change(last_message_seq: -1)
        |> Ecto.Changeset.check_constraint(:last_message_seq,
          name: :conversations_last_message_seq_non_negative
        )

      assert {:error, changeset} = Repo.update(conversation_changeset)
      assert %{last_message_seq: ["is invalid"]} = errors_on(changeset)
    end

    test "does not create self-unread counts when the sender refreshes counts" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})

      assert {:ok, _sent_message} =
               Chat.send_message(scope, workspace.default_channel_id, %{
                 "content" => "not unread for me"
               })

      assert Chat.list_unread_counts(scope, workspace.id) == {:ok, %{}}
    end

    test "updates the runtime cache before broadcasting the persisted message" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      subscriber = start_cache_reading_subscriber(scope, workspace.default_channel_id)

      assert_receive {:subscribed, ^subscriber}

      assert {:ok, sent_message} =
               Chat.send_message(scope, workspace.default_channel_id, %{
                 "content" => "cache before broadcast"
               })

      assert_receive {:subscriber_recent_messages, ^subscriber, received_message, recent_messages}

      assert received_message.id == sent_message.id
      assert Enum.map(recent_messages, & &1.id) == [sent_message.id]
      assert Ecto.assoc_loaded?(received_message.user)
      assert Ecto.assoc_loaded?(hd(recent_messages).user)
    end

    test "clears the sender's typing state when a message is sent" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      channel_id = workspace.default_channel_id

      assert :ok = Chat.subscribe_to_channel_messages(scope, channel_id)
      assert :ok = Chat.user_started_typing(scope, channel_id)
      assert_receive {:typing_started, %{conversation_id: ^channel_id, user_id: user_id}}

      assert {:ok, message} =
               Chat.send_message(scope, channel_id, %{"content" => "typing resolved"})

      assert message.content == "typing resolved"
      assert_receive {:typing_stopped, %{conversation_id: ^channel_id, user_id: ^user_id}}
      assert {:ok, []} = Chat.list_typing_user_ids(scope, channel_id)
    end

    test "restarts the runtime and caches the persisted message when sending after runtime loss" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      channel_id = workspace.default_channel_id

      stored_message =
        insert_message!(channel_id, scope.user.id, "stored", ~U[2026-06-19 10:00:00Z])

      assert {:ok, [cached_message]} = Chat.list_recent_messages(scope, channel_id)
      assert cached_message.id == stored_message.id

      assert {:ok, first_pid} = Chat.ensure_channel_runtime(scope, channel_id)
      ref = Process.monitor(first_pid)
      Process.exit(first_pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^first_pid, :killed}
      _ = :sys.get_state(DiscordClone.Chat.ConversationSupervisor)

      subscriber = start_subscriber(scope, channel_id)
      assert_receive {:subscribed, ^subscriber}

      assert {:ok, sent_message} =
               Chat.send_message(scope, channel_id, %{"content" => "after runtime loss"})

      assert_receive {:subscriber_received, ^subscriber, {:message_created, received_message}}
      assert received_message.id == sent_message.id

      assert {:ok, recent_messages} = Chat.list_recent_messages(scope, channel_id)
      assert Enum.map(recent_messages, & &1.id) == [stored_message.id, sent_message.id]

      assert {:ok, second_pid} = Chat.ensure_channel_runtime(scope, channel_id)
      assert second_pid != first_pid
    end

    test "rejects whitespace-only content with an invalid message changeset" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})

      assert {:error, :invalid_message, changeset} =
               Chat.send_message(scope, workspace.default_channel_id, %{
                 "content" => "   "
               })

      refute changeset.valid?
      assert %{content: ["can't be blank"]} = errors_on(changeset)
      assert Repo.aggregate(Message, :count) == 0
    end

    test "does not update the runtime cache or broadcast invalid message sends" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      channel_id = workspace.default_channel_id

      stored_message =
        insert_message!(channel_id, scope.user.id, "stored", ~U[2026-06-19 10:00:00Z])

      assert {:ok, [cached_message]} = Chat.list_recent_messages(scope, channel_id)
      assert cached_message.id == stored_message.id
      assert :ok = Chat.subscribe_to_channel_messages(scope, channel_id)

      assert {:error, :invalid_message, _changeset} =
               Chat.send_message(scope, channel_id, %{"content" => "   "})

      assert {:ok, cached_messages} = Chat.list_recent_messages(scope, channel_id)
      assert Enum.map(cached_messages, & &1.id) == [stored_message.id]
      refute_receive {:message_created, _message}
    end

    test "accepts atom-keyed content attributes" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})

      assert {:ok, message} =
               Chat.send_message(scope, workspace.default_channel_id, %{content: "atom attrs"})

      assert message.content == "atom attrs"
    end

    test "rejects content longer than four thousand characters" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})

      assert {:error, :invalid_message, changeset} =
               Chat.send_message(scope, workspace.default_channel_id, %{
                 "content" => String.duplicate("a", 4_001)
               })

      refute changeset.valid?
      assert %{content: ["should be at most 4000 character(s)"]} = errors_on(changeset)
      assert Repo.aggregate(Message, :count) == 0
    end

    test "rejects anonymous scopes" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})

      assert Chat.send_message(nil, workspace.default_channel_id, %{"content" => "hello"}) ==
               {:error, :unauthenticated}

      assert Chat.send_message(
               %DiscordClone.Accounts.Scope{},
               workspace.default_channel_id,
               %{"content" => "hello"}
             ) == {:error, :unauthenticated}

      assert Repo.aggregate(Message, :count) == 0
    end

    test "rejects logged-in users who are not workspace members" do
      owner_scope = user_scope_fixture()
      non_member_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})

      assert Chat.send_message(non_member_scope, workspace.default_channel_id, %{
               "content" => "private hello"
             }) == {:error, :not_found}

      assert Repo.aggregate(Message, :count) == 0
    end

    test "does not update the runtime cache or broadcast unauthorized message sends" do
      owner_scope = user_scope_fixture()
      non_member_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      channel_id = workspace.default_channel_id

      stored_message =
        insert_message!(channel_id, owner_scope.user.id, "stored", ~U[2026-06-19 10:00:00Z])

      assert {:ok, [cached_message]} = Chat.list_recent_messages(owner_scope, channel_id)
      assert cached_message.id == stored_message.id
      assert :ok = Chat.subscribe_to_channel_messages(owner_scope, channel_id)

      assert Chat.send_message(non_member_scope, channel_id, %{"content" => "private hello"}) ==
               {:error, :not_found}

      assert {:ok, cached_messages} = Chat.list_recent_messages(owner_scope, channel_id)
      assert Enum.map(cached_messages, & &1.id) == [stored_message.id]
      refute_receive {:message_created, _message}
    end
  end

  describe "navigate_to_message/3" do
    test "loads an authorized live target and hides every unavailable target as not found" do
      scope = user_scope_fixture()
      outsider_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      {:ok, other_channel} = Workspaces.create_channel(scope, workspace.id, %{name: "off-topic"})
      channel_id = workspace.default_channel_id

      messages =
        for index <- 1..60 do
          {:ok, message} =
            Chat.send_message(scope, channel_id, %{"content" => "message #{index}"})

          message
        end

      target = Enum.at(messages, 19)

      assert {:ok, %{target: resolved_target, messages: window_messages, meta: meta}} =
               Chat.navigate_to_message(scope, channel_id, target.id)

      assert resolved_target.id == target.id
      assert resolved_target.seq == target.seq
      assert Enum.any?(window_messages, &(&1.id == target.id))
      assert meta.has_older?
      assert meta.has_newer?

      {:ok, cross_channel_target} =
        Chat.send_message(scope, other_channel.id, %{"content" => "elsewhere"})

      {:ok, deleted_target} =
        Chat.send_message(scope, channel_id, %{"content" => "soon deleted"})

      {:ok, _deleted_target} = Chat.delete_message(scope, deleted_target.id)

      unavailable_target_ids = [
        "not-a-uuid",
        Ecto.UUID.generate(),
        cross_channel_target.id,
        deleted_target.id
      ]

      for target_id <- unavailable_target_ids do
        assert Chat.navigate_to_message(scope, channel_id, target_id) == {:error, :not_found}
      end

      assert Chat.navigate_to_message(outsider_scope, channel_id, target.id) ==
               {:error, :not_found}
    end
  end

  defp insert_message!(channel_id, user_id, content, inserted_at) do
    inserted_at = %{inserted_at | microsecond: {elem(inserted_at.microsecond, 0), 6}}

    {:ok, message} =
      Repo.transaction(fn ->
        conversation =
          Repo.one!(
            from conversation in Conversation,
              where: conversation.id == ^channel_id,
              lock: "FOR UPDATE"
          )

        seq = conversation.last_message_seq + 1

        message =
          Repo.insert!(%Message{
            channel_id: channel_id,
            user_id: user_id,
            content: content,
            seq: seq,
            inserted_at: inserted_at,
            updated_at: inserted_at
          })

        conversation
        |> Ecto.Changeset.change(last_message_seq: seq)
        |> Repo.update!()

        message
      end)

    message
  end

  defp insert_messages!(channel_id, user_id, count) do
    for index <- 1..count do
      insert_message!(
        channel_id,
        user_id,
        "message #{index}",
        DateTime.add(~U[2026-06-19 10:00:00Z], index, :second)
      )
    end
  end

  defp now, do: DateTime.utc_now(:second)

  defp assert_reply_target_rejected(scope, channel_id, reply_to_message_id) do
    assert {:error, :invalid_message, changeset} =
             Chat.send_message(scope, channel_id, %{
               "content" => "invalid reply",
               "reply_to_message_id" => reply_to_message_id
             })

    assert %{reply_to_message_id: ["is not an earlier message in this channel"]} =
             errors_on(changeset)
  end

  defp drain_reply_window_queries(count \\ 0) do
    receive do
      :reply_window_query -> drain_reply_window_queries(count + 1)
    after
      0 -> count
    end
  end

  defp count_reactions(message_id, user_id, emoji) do
    Repo.one(
      from reaction in MessageReaction,
        where:
          reaction.message_id == ^message_id and reaction.user_id == ^user_id and
            reaction.emoji == ^emoji,
        select: count(reaction.id)
    )
  end

  defp unread_spans(channel_id, user_id) do
    Repo.all(
      from span in ChannelUnreadSpan,
        where: span.channel_id == ^channel_id and span.user_id == ^user_id,
        order_by: [asc: span.from_seq],
        select: {span.from_seq, span.to_seq}
    )
  end

  defp unread_span_records(channel_id, user_id) do
    Repo.all(
      from span in ChannelUnreadSpan,
        where: span.channel_id == ^channel_id and span.user_id == ^user_id,
        order_by: [asc: span.from_seq]
    )
  end

  defp add_workspace_member!(workspace, scope, role \\ "member") do
    %WorkspaceMembership{}
    |> WorkspaceMembership.changeset(%{
      workspace_id: workspace.id,
      user_id: scope.user.id,
      role: role
    })
    |> Repo.insert!()
  end

  defp backdate_message!(%Message{id: id}, %DateTime{} = inserted_at) do
    {1, _} =
      Repo.update_all(
        from(message in Message, where: message.id == ^id),
        set: [inserted_at: inserted_at]
      )
  end

  defp start_subscriber(scope, channel_id) do
    parent = self()

    spawn_link(fn ->
      assert :ok = Chat.subscribe_to_channel_messages(scope, channel_id)
      send(parent, {:subscribed, self()})

      receive do
        event -> send(parent, {:subscriber_received, self(), event})
      after
        1_000 -> send(parent, {:subscriber_timeout, self()})
      end
    end)
  end

  defp start_reaction_subscriber(scope, channel_id) do
    parent = self()

    spawn_link(fn ->
      assert :ok = Chat.subscribe_to_channel_reactions(scope, channel_id)
      send(parent, {:subscribed, self()})

      receive do
        event -> send(parent, {:subscriber_received, self(), event})
      after
        1_000 -> send(parent, {:subscriber_timeout, self()})
      end
    end)
  end

  defp start_cache_reading_subscriber(scope, channel_id) do
    parent = self()

    spawn_link(fn ->
      assert :ok = Chat.subscribe_to_channel_messages(scope, channel_id)
      send(parent, {:subscribed, self()})

      receive do
        {:message_created, message} ->
          assert {:ok, recent_messages} = Chat.list_recent_messages(scope, channel_id)
          send(parent, {:subscriber_recent_messages, self(), message, recent_messages})
      after
        1_000 -> send(parent, {:subscriber_timeout, self()})
      end
    end)
  end

  defp start_typing_subscriber(scope, channel_id) do
    parent = self()

    spawn_link(fn ->
      assert :ok = Chat.subscribe_to_channel_messages(scope, channel_id)
      send(parent, {:subscribed, self()})

      receive do
        event -> send(parent, {:subscriber_received, self(), event})
      after
        1_000 -> send(parent, {:subscriber_timeout, self()})
      end
    end)
  end

  defp put_conversation_typing_timeout(timeout_ms) do
    previous = Application.get_env(:discord_clone, :conversation_runtime_typing_timeout_ms)
    Application.put_env(:discord_clone, :conversation_runtime_typing_timeout_ms, timeout_ms)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:discord_clone, :conversation_runtime_typing_timeout_ms)
      else
        Application.put_env(:discord_clone, :conversation_runtime_typing_timeout_ms, previous)
      end
    end)
  end

  defp start_live_view_process do
    start_supervised!(%{
      id: System.unique_integer([:positive]),
      start:
        {Task, :start_link,
         [
           fn ->
             receive do
               :stop -> :ok
             end
           end
         ]}
    })
  end
end
