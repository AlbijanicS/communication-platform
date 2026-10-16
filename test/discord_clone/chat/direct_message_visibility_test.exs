defmodule DiscordClone.Chat.DirectMessageVisibilityTest do
  use DiscordClone.DataCase, async: false

  import DiscordClone.AccountsFixtures
  import DiscordCloneWeb.WorkspaceLiveTestHelpers, only: [add_workspace_member!: 2]

  alias DiscordClone.Activities.ActivityItem
  alias DiscordClone.{Chat, Friendships, Repo, Workspaces}

  test "visible received Direct Messages atomically synchronize unread state and Activity history" do
    {sender_scope, recipient_scope, direct_conversation} = direct_conversation_fixture("sync")

    assert {:ok, first_message} =
             Chat.send_direct_message(sender_scope, direct_conversation.id, %{content: "first"})

    assert {:ok, own_message} =
             Chat.send_direct_message(recipient_scope, direct_conversation.id, %{content: "own"})

    assert {:ok, last_message} =
             Chat.send_direct_message(sender_scope, direct_conversation.id, %{content: "last"})

    assert :ok = Chat.subscribe_to_direct_read_state(recipient_scope, direct_conversation.id)
    assert :ok = Chat.subscribe_to_activity(recipient_scope)

    assert direct_unread_count(recipient_scope, direct_conversation.id) == 2
    assert {:ok, 2} = Chat.unread_activity_count(recipient_scope)
    assert {:ok, 1} = Chat.unread_activity_count(sender_scope)

    assert {:ok, read_state} =
             Chat.mark_direct_messages_visible(
               recipient_scope,
               direct_conversation.id,
               first_message.seq,
               last_message.seq
             )

    assert read_state.unread_count == 0
    assert is_nil(read_state.first_unread_seq)
    assert is_nil(read_state.last_unread_seq)
    assert_receive {:conversation_read_state_changed, %{unread_count: 0}}
    assert_receive {:activity_changed, %{action: :read}}

    assert {:ok, 0} = Chat.unread_activity_count(recipient_scope)
    assert {:ok, 1} = Chat.unread_activity_count(sender_scope)

    assert {:ok, %{items: recipient_history}} = Chat.list_activity_feed(recipient_scope)
    recipient_history = Enum.filter(recipient_history, &(&1.kind == "direct_message"))

    assert MapSet.new(recipient_history, & &1.source_message_id) ==
             MapSet.new([first_message.id, last_message.id])

    assert Enum.all?(recipient_history, &match?(%DateTime{}, &1.read_at))

    assert {:ok, %{items: sender_history}} = Chat.list_activity_feed(sender_scope)
    sender_history = Enum.filter(sender_history, &(&1.kind == "direct_message"))
    assert [%ActivityItem{source_message_id: source_message_id, read_at: nil}] = sender_history
    assert source_message_id == own_message.id
  end

  test "overlapping, stale, retried, and invalid visibility reports are idempotent" do
    {sender_scope, recipient_scope, direct_conversation} = direct_conversation_fixture("retry")

    messages =
      for index <- 1..3 do
        assert {:ok, message} =
                 Chat.send_direct_message(sender_scope, direct_conversation.id, %{
                   content: "message #{index}"
                 })

        message
      end

    assert {:ok, read_state} =
             Chat.mark_direct_messages_visible(recipient_scope, direct_conversation.id, 1, 2)

    assert read_state.unread_count == 1

    assert {:ok, read_state} =
             Chat.mark_direct_messages_visible(recipient_scope, direct_conversation.id, 2, 3)

    assert read_state.unread_count == 0
    assert :ok = Chat.subscribe_to_direct_read_state(recipient_scope, direct_conversation.id)
    assert :ok = Chat.subscribe_to_activity(recipient_scope)

    assert {:ok, retried_state} =
             Chat.mark_direct_messages_visible(recipient_scope, direct_conversation.id, 1, 3)

    assert retried_state.unread_count == 0
    refute_receive {:conversation_read_state_changed, _payload}
    refute_receive {:activity_changed, _payload}

    outsider_scope = user_scope_fixture()

    assert {:error, :not_found} =
             Chat.mark_direct_messages_visible(outsider_scope, direct_conversation.id, 1, 1)

    assert {:error, :invalid_range} =
             Chat.mark_direct_messages_visible(recipient_scope, direct_conversation.id, 0, 1)

    assert {:error, :range_too_large} =
             Chat.mark_direct_messages_visible(recipient_scope, direct_conversation.id, 1, 51)

    assert {:error, :invalid_range} =
             Chat.mark_direct_messages_visible(
               recipient_scope,
               direct_conversation.id,
               1,
               List.last(messages).seq + 1
             )
  end

  test "a failed Activity update rolls back Direct Conversation unread state" do
    {sender_scope, recipient_scope, direct_conversation} = direct_conversation_fixture("rollback")

    assert {:ok, message} =
             Chat.send_direct_message(sender_scope, direct_conversation.id, %{content: "rollback"})

    install_reject_direct_activity_update_trigger!()

    assert_raise Postgrex.Error, fn ->
      Chat.mark_direct_messages_visible(
        recipient_scope,
        direct_conversation.id,
        message.seq,
        message.seq
      )
    end

    assert direct_unread_count(recipient_scope, direct_conversation.id) == 1
    assert {:ok, 1} = Chat.unread_activity_count(recipient_scope)
  end

  test "Direct Message visibility does not mark mention Activity read" do
    {sender_scope, recipient_scope, direct_conversation} = direct_conversation_fixture("mention")
    {:ok, workspace} = Workspaces.create_workspace(sender_scope, %{name: "Mentions"})
    add_workspace_member!(workspace, recipient_scope)

    assert {:ok, _mention_message} =
             Chat.send_message(sender_scope, workspace.default_channel_id, %{
               content: "hello @#{recipient_scope.user.username}"
             })

    assert {:ok, direct_message} =
             Chat.send_direct_message(sender_scope, direct_conversation.id, %{content: "direct"})

    assert {:ok, _read_state} =
             Chat.mark_direct_messages_visible(
               recipient_scope,
               direct_conversation.id,
               direct_message.seq,
               direct_message.seq
             )

    assert {:ok, 1} = Chat.unread_activity_count(recipient_scope)
    assert {:ok, %{items: history}} = Chat.list_activity_feed(recipient_scope)
    assert Enum.find(history, &(&1.kind == ActivityItem.user_mention_kind())).read_at == nil
  end

  defp direct_conversation_fixture(prefix) do
    sender_scope = user_scope_fixture(user_fixture(%{username: "#{prefix}_sender"}))
    recipient_scope = user_scope_fixture(user_fixture(%{username: "#{prefix}_recipient"}))

    assert {:ok, %{relationship: request}} =
             Friendships.send_friend_request(sender_scope, %{
               username: recipient_scope.user.username
             })

    assert {:ok, _friendship} =
             Friendships.accept_friend_request(recipient_scope, request.id)

    assert {:ok, direct_conversation} =
             Chat.open_direct_conversation(sender_scope, recipient_scope.user.id)

    assert {:ok, _updated_count} = Chat.mark_all_activity_read(sender_scope)
    assert {:ok, _updated_count} = Chat.mark_all_activity_read(recipient_scope)

    {sender_scope, recipient_scope, direct_conversation}
  end

  defp direct_unread_count(scope, direct_conversation_id) do
    assert {:ok, destinations} = Chat.list_direct_conversation_destinations(scope)

    destinations
    |> Enum.find(&(&1.direct_conversation.id == direct_conversation_id))
    |> Map.fetch!(:unread_count)
  end

  defp install_reject_direct_activity_update_trigger! do
    Ecto.Adapters.SQL.query!(
      Repo,
      """
      CREATE FUNCTION reject_direct_activity_update() RETURNS trigger AS $$
      BEGIN
        IF OLD.kind = 'direct_message' THEN
          RAISE EXCEPTION 'direct activity update rejected';
        END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql
      """
    )

    Ecto.Adapters.SQL.query!(
      Repo,
      """
      CREATE TRIGGER reject_direct_activity_update
      BEFORE UPDATE ON activity_items
      FOR EACH ROW EXECUTE FUNCTION reject_direct_activity_update()
      """
    )
  end
end
