defmodule DiscordClone.Chat.DirectMessagesTest do
  use DiscordClone.DataCase, async: false

  import DiscordClone.AccountsFixtures
  import DiscordCloneWeb.WorkspaceLiveTestHelpers, only: [add_workspace_member!: 2]

  alias DiscordClone.Activities.ActivityItem
  alias DiscordClone.Chat
  alias DiscordClone.Chat.{ChannelReadState, ChannelUnreadSpan, Conversation, Message}
  alias DiscordClone.Friendships
  alias DiscordClone.Repo
  alias DiscordClone.Workspaces

  describe "send_direct_message/3" do
    test "persists an ordered Direct Message with one recipient unread state and Activity Item" do
      {sender_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture()

      assert {:ok, message} =
               Chat.send_direct_message(sender_scope, direct_conversation.id, %{
                 content: "hello @everyone and @#{recipient_scope.user.username}"
               })

      assert message.channel_id == direct_conversation.id
      assert message.user_id == sender_scope.user.id
      assert message.seq == 1
      assert message.mention_recognition == %{}

      assert %Conversation{last_message_seq: 1} =
               Repo.get!(Conversation, direct_conversation.id)

      assert %ChannelReadState{
               unread_count: 1,
               first_unread_seq: 1,
               last_unread_seq: 1
             } =
               Repo.get_by!(ChannelReadState,
                 channel_id: direct_conversation.id,
                 user_id: recipient_scope.user.id
               )

      refute Repo.get_by(ChannelReadState,
               channel_id: direct_conversation.id,
               user_id: sender_scope.user.id
             )

      assert %ChannelUnreadSpan{from_seq: 1, to_seq: 1} =
               Repo.get_by!(ChannelUnreadSpan,
                 channel_id: direct_conversation.id,
                 user_id: recipient_scope.user.id
               )

      assert %ActivityItem{
               recipient_user_id: recipient_user_id,
               actor_user_id: actor_user_id,
               source_message_id: source_message_id,
               source_conversation_id: source_conversation_id,
               workspace_id: nil,
               kind: "direct_message",
               read_at: nil
             } = Repo.get_by!(ActivityItem, source_message_id: message.id)

      assert recipient_user_id == recipient_scope.user.id
      assert actor_user_id == sender_scope.user.id
      assert source_message_id == message.id
      assert source_conversation_id == direct_conversation.id

      assert Repo.aggregate(
               from(item in ActivityItem, where: item.kind == "direct_message"),
               :count
             ) == 1
    end

    test "allocates Conversation-local sequences and lists the committed timeline for either participant" do
      {sender_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("ordered")

      assert {:ok, first} =
               Chat.send_direct_message(sender_scope, direct_conversation.id, %{content: "first"})

      assert {:ok, second} =
               Chat.send_direct_message(recipient_scope, direct_conversation.id, %{
                 content: "second"
               })

      assert [1, 2] == Enum.map([first, second], & &1.seq)

      assert {:ok, sender_messages} =
               Chat.list_direct_messages(sender_scope, direct_conversation.id)

      assert {:ok, recipient_messages} =
               Chat.list_direct_messages(recipient_scope, direct_conversation.id)

      assert Enum.map(sender_messages, &{&1.id, &1.user.username}) ==
               Enum.map(recipient_messages, &{&1.id, &1.user.username})

      assert Enum.map(sender_messages, & &1.id) == [first.id, second.id]
    end

    test "returns field errors and does not allocate a sequence for invalid content" do
      {sender_scope, _recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("invalid")

      assert {:error, :invalid_message, changeset} =
               Chat.send_direct_message(sender_scope, direct_conversation.id, %{content: "   "})

      assert "can't be blank" in errors_on(changeset).content
      assert %Conversation{last_message_seq: 0} = Repo.get!(Conversation, direct_conversation.id)
      assert {:ok, []} = Chat.list_direct_messages(sender_scope, direct_conversation.id)

      assert {:error, :invalid_message, non_map_changeset} =
               Chat.send_direct_message(sender_scope, direct_conversation.id, "forged")

      assert "can't be blank" in errors_on(non_map_changeset).content
    end

    test "publishes compact committed facts only on authorized private topics" do
      {sender_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("live")

      outsider_scope = user_scope_fixture(user_fixture(username: "live_direct_outsider"))
      assert :ok = Chat.subscribe_to_direct_messages(sender_scope, direct_conversation.id)
      assert :ok = Chat.subscribe_to_direct_read_state(recipient_scope, direct_conversation.id)
      assert :ok = Chat.subscribe_to_activity(recipient_scope)

      assert {:error, :not_found} =
               Chat.subscribe_to_direct_messages(outsider_scope, direct_conversation.id)

      assert {:error, :not_found} =
               Chat.subscribe_to_direct_read_state(outsider_scope, direct_conversation.id)

      {:ok, workspace} =
        Workspaces.create_workspace(sender_scope, %{name: "Shared but unrelated"})

      add_workspace_member!(workspace, recipient_scope)
      add_workspace_member!(workspace, outsider_scope)
      assert :ok = Chat.subscribe_to_workspace_messages(sender_scope, workspace.id)

      assert {:error, :not_found} =
               Chat.list_direct_messages(outsider_scope, direct_conversation.id)

      assert {:error, :not_found} =
               Chat.send_direct_message(outsider_scope, direct_conversation.id, %{
                 content: "Workspace membership is insufficient"
               })

      assert {:error, :not_found} =
               Chat.send_direct_message(outsider_scope, direct_conversation.id, "forged")

      assert {:ok, message} =
               Chat.send_direct_message(sender_scope, direct_conversation.id, %{
                 content: "private"
               })

      assert_receive {:conversation_read_state_changed,
                      %{
                        conversation_id: conversation_id,
                        unread_count: 1,
                        first_unread_seq: 1,
                        last_unread_seq: 1
                      }}

      assert conversation_id == direct_conversation.id

      assert_receive {:direct_message_created,
                      %{conversation_id: conversation_id, message_id: message_id, seq: 1}}

      assert conversation_id == direct_conversation.id
      assert message_id == message.id

      assert_receive {:activity_changed,
                      %{action: :created, source_message_id: source_message_id}}

      assert source_message_id == message.id
      refute_receive {:workspace_message_created, _payload}

      assert {:ok, reloaded} =
               Chat.fetch_direct_message(recipient_scope, direct_conversation.id, message.id)

      assert reloaded.id == message.id

      assert {:error, :not_found} =
               Chat.fetch_direct_message(outsider_scope, direct_conversation.id, message.id)
    end

    test "rejects forged, unauthenticated, and former-Friend sends without changing the timeline" do
      {sender_scope, recipient_scope, direct_conversation, friendship} =
        direct_conversation_fixture("rejected")

      outsider_scope = user_scope_fixture(user_fixture(username: "rejected_direct_outsider"))

      assert {:error, :unauthenticated} =
               Chat.send_direct_message(nil, direct_conversation.id, %{content: "forged"})

      assert {:error, :not_found} =
               Chat.send_direct_message(outsider_scope, direct_conversation.id, %{
                 content: "forged"
               })

      assert :ok = Friendships.remove_friend(recipient_scope, friendship.id)

      assert {:error, :not_friends} =
               Chat.send_direct_message(sender_scope, direct_conversation.id, %{content: "stale"})

      assert {:ok, []} = Chat.list_direct_messages(sender_scope, direct_conversation.id)
      assert %Conversation{last_message_seq: 0} = Repo.get!(Conversation, direct_conversation.id)
    end

    test "rolls back Message, sequence, unread state, and Activity when recipient fanout fails" do
      {sender_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("rollback")

      Ecto.Adapters.SQL.query!(
        Repo,
        """
        ALTER TABLE conversation_read_states
        ADD CONSTRAINT conversation_read_states_reject_direct_unread
        CHECK (unread_count = 0)
        """
      )

      assert_raise Ecto.ConstraintError, ~r/conversation_read_states_reject_direct_unread/, fn ->
        Chat.send_direct_message(sender_scope, direct_conversation.id, %{content: "rollback"})
      end

      assert Repo.aggregate(
               from(message in Message, where: message.channel_id == ^direct_conversation.id),
               :count
             ) == 0

      assert %Conversation{last_message_seq: 0} = Repo.get!(Conversation, direct_conversation.id)

      refute Repo.get_by(ChannelReadState,
               channel_id: direct_conversation.id,
               user_id: recipient_scope.user.id
             )

      refute Repo.get_by(ActivityItem,
               recipient_user_id: recipient_scope.user.id,
               kind: "direct_message"
             )
    end

    test "rolls back recipient unread state when Direct Message Activity insertion fails" do
      {sender_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("act_rb")

      Ecto.Adapters.SQL.query!(
        Repo,
        """
        ALTER TABLE activity_items
        ADD CONSTRAINT activity_items_reject_direct_message
        CHECK (kind <> 'direct_message')
        """
      )

      assert_raise Ecto.ConstraintError, ~r/activity_items_reject_direct_message/, fn ->
        Chat.send_direct_message(sender_scope, direct_conversation.id, %{content: "rollback"})
      end

      assert {:ok, []} = Chat.list_direct_messages(sender_scope, direct_conversation.id)
      assert %Conversation{last_message_seq: 0} = Repo.get!(Conversation, direct_conversation.id)

      refute Repo.get_by(ChannelReadState,
               channel_id: direct_conversation.id,
               user_id: recipient_scope.user.id
             )

      refute Repo.get_by(ChannelUnreadSpan,
               channel_id: direct_conversation.id,
               user_id: recipient_scope.user.id
             )
    end

    test "surfaces private Direct Message Activity only to its recipient" do
      {sender_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("activity")

      outsider_scope = user_scope_fixture(user_fixture(username: "activity_direct_outsider"))

      assert {:ok, message} =
               Chat.send_direct_message(sender_scope, direct_conversation.id, %{
                 content: "private"
               })

      assert {:ok, %{items: recipient_items}} = Chat.list_activity_feed(recipient_scope)
      assert [item] = Enum.filter(recipient_items, &(&1.kind == "direct_message"))
      assert item.source_message.id == message.id
      assert item.source_direct_conversation.id == direct_conversation.id
      assert item.actor_user.id == sender_scope.user.id

      assert {:ok, %{items: sender_items}} = Chat.list_activity_feed(sender_scope)
      refute Enum.any?(sender_items, &(&1.kind == "direct_message"))

      assert {:ok, destination} = Chat.open_activity_item(recipient_scope, item.id)

      assert destination == %{
               direct_conversation_id: direct_conversation.id,
               message_id: message.id
             }

      assert is_nil(Repo.reload!(item).read_at)

      assert {:error, :not_found} = Chat.open_activity_item(outsider_scope, item.id)
    end
  end

  describe "Direct Message interactions" do
    test "current Friends reply to an earlier message and invalid targets are non-disclosing" do
      {sender_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("reply")

      assert {:ok, parent} =
               Chat.send_direct_message(sender_scope, direct_conversation.id, %{content: "parent"})

      assert {:ok, reply} =
               Chat.send_direct_message(recipient_scope, direct_conversation.id, %{
                 content: "flat reply",
                 reply_to_message_id: parent.id
               })

      assert reply.reply_to_message_id == parent.id
      assert reply.reply_to_message.id == parent.id

      assert {:error, :invalid_message, future_changeset} =
               Chat.send_direct_message(sender_scope, direct_conversation.id, %{
                 content: "future",
                 reply_to_message_id: Ecto.UUID.generate()
               })

      assert "is not an earlier message in this conversation" in errors_on(future_changeset).reply_to_message_id

      {other_scope, _other_recipient_scope, other_conversation, _friendship} =
        direct_conversation_fixture("cross_reply")

      assert {:ok, other_message} =
               Chat.send_direct_message(other_scope, other_conversation.id, %{content: "private"})

      assert {:error, :invalid_message, cross_changeset} =
               Chat.send_direct_message(sender_scope, direct_conversation.id, %{
                 content: "cross",
                 reply_to_message_id: other_message.id
               })

      assert errors_on(cross_changeset).reply_to_message_id ==
               errors_on(future_changeset).reply_to_message_id

      assert reply.seq == 2
    end

    test "participants toggle reactions live and former Friends may only remove their own" do
      {sender_scope, recipient_scope, direct_conversation, friendship} =
        direct_conversation_fixture("reaction")

      assert {:ok, message} =
               Chat.send_direct_message(sender_scope, direct_conversation.id, %{content: "react"})

      outsider_scope = user_scope_fixture(user_fixture(username: "reaction_direct_outsider"))
      assert :ok = Chat.subscribe_to_direct_reactions(recipient_scope, direct_conversation.id)

      assert {:error, :not_found} =
               Chat.subscribe_to_direct_reactions(outsider_scope, direct_conversation.id)

      assert {:error, :not_found} = Chat.toggle_reaction(outsider_scope, message.id, "👍")
      assert {:error, :not_found} = Chat.delete_message(outsider_scope, message.id)

      assert {:error, :not_found} =
               Chat.list_reaction_summaries(outsider_scope, [message.id])

      assert {:ok, _reaction} = Chat.toggle_reaction(sender_scope, message.id, "👍")

      assert {:ok, summaries} = Chat.list_reaction_summaries(recipient_scope, [message.id])
      assert [summary] = Map.fetch!(summaries, message.id)

      assert summary == %{emoji: "👍", count: 1, reacted?: false}
      assert :ok = Friendships.remove_friend(recipient_scope, friendship.id)

      assert {:error, :not_friends} = Chat.toggle_reaction(recipient_scope, message.id, "❤️")
      assert {:ok, _deleted_reaction} = Chat.toggle_reaction(sender_scope, message.id, "👍")
      assert {:ok, %{}} = Chat.list_reaction_summaries(sender_scope, [message.id])
    end

    test "only authors soft-delete Direct Messages and deleted reply previews preserve structure" do
      {sender_scope, recipient_scope, direct_conversation, friendship} =
        direct_conversation_fixture("delete")

      assert {:ok, parent} =
               Chat.send_direct_message(sender_scope, direct_conversation.id, %{content: "secret"})

      assert {:ok, reply} =
               Chat.send_direct_message(recipient_scope, direct_conversation.id, %{
                 content: "reply",
                 reply_to_message_id: parent.id
               })

      assert {:error, :unauthorized} = Chat.delete_message(recipient_scope, parent.id)
      assert {:ok, deleted} = Chat.delete_message(sender_scope, parent.id)
      assert deleted.deleted_at

      assert {:error, :invalid_message, deleted_target_changeset} =
               Chat.send_direct_message(recipient_scope, direct_conversation.id, %{
                 content: "stale reply",
                 reply_to_message_id: parent.id
               })

      assert "is not an earlier message in this conversation" in errors_on(
               deleted_target_changeset
             ).reply_to_message_id

      assert {:ok, cleanup_message} =
               Chat.send_direct_message(sender_scope, direct_conversation.id, %{
                 content: "former Friend cleanup"
               })

      assert :ok = Friendships.remove_friend(recipient_scope, friendship.id)
      assert {:ok, _deleted_cleanup} = Chat.delete_message(sender_scope, cleanup_message.id)

      assert {:ok, [deleted_parent, persisted_reply, deleted_cleanup]} =
               Chat.list_direct_messages(recipient_scope, direct_conversation.id)

      assert is_nil(deleted_parent.content)
      assert deleted_parent.deleted_at
      assert persisted_reply.id == reply.id
      assert persisted_reply.reply_to_message_id == parent.id
      assert persisted_reply.reply_to_message.deleted_at
      assert is_nil(persisted_reply.reply_to_message.content)
      assert deleted_cleanup.id == cleanup_message.id
      assert deleted_cleanup.deleted_at
      assert is_nil(deleted_cleanup.content)

      assert {:error, :message_deleted} = Chat.delete_message(sender_scope, cleanup_message.id)

      assert {:error, :not_friends} =
               Chat.send_direct_message(recipient_scope, direct_conversation.id, %{
                 content: "former Friend reply",
                 reply_to_message_id: parent.id
               })
    end

    test "keeps Workspace Channel reply, reaction, and deletion behavior unchanged" do
      author_scope = user_scope_fixture(user_fixture(username: "channel_parity_author"))
      member_scope = user_scope_fixture(user_fixture(username: "channel_parity_member"))
      outsider_scope = user_scope_fixture(user_fixture(username: "channel_parity_outsider"))

      assert {:ok, workspace} = Workspaces.create_workspace(author_scope, %{name: "Parity"})
      add_workspace_member!(workspace, member_scope)

      assert {:ok, parent} =
               Chat.send_message(author_scope, workspace.default_channel_id, %{content: "parent"})

      assert {:ok, reply} =
               Chat.send_message(member_scope, workspace.default_channel_id, %{
                 content: "reply",
                 reply_to_message_id: parent.id
               })

      assert reply.reply_to_message_id == parent.id
      assert {:ok, _reaction} = Chat.toggle_reaction(member_scope, parent.id, "👍")
      assert {:ok, summaries} = Chat.list_reaction_summaries(author_scope, [parent.id])
      assert [%{emoji: "👍", count: 1, reacted?: false}] = Map.fetch!(summaries, parent.id)
      assert {:error, :not_found} = Chat.toggle_reaction(outsider_scope, parent.id, "❤️")
      assert {:error, :unauthorized} = Chat.delete_message(member_scope, parent.id)
      assert {:ok, deleted_parent} = Chat.delete_message(author_scope, parent.id)
      assert deleted_parent.deleted_at
      assert deleted_parent.content == "parent"
    end
  end

  defp direct_conversation_fixture(suffix \\ "durable") do
    sender_scope = user_scope_fixture(user_fixture(username: "#{suffix}_direct_sender"))
    recipient_scope = user_scope_fixture(user_fixture(username: "#{suffix}_direct_recipient"))

    assert {:ok, %{relationship: request}} =
             Friendships.send_friend_request(sender_scope, %{
               username: recipient_scope.user.username
             })

    assert {:ok, friendship} =
             Friendships.accept_friend_request(recipient_scope, request.id)

    assert {:ok, direct_conversation} =
             Chat.open_direct_conversation(sender_scope, recipient_scope.user.id)

    {sender_scope, recipient_scope, direct_conversation, friendship}
  end
end
