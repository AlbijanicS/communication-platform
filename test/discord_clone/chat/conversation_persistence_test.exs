defmodule DiscordClone.Chat.ConversationPersistenceTest do
  use DiscordClone.DataCase, async: false

  alias DiscordClone.Chat
  alias DiscordClone.Chat.{Conversation, Message}
  alias DiscordClone.Workspaces

  import DiscordClone.AccountsFixtures

  test "Workspace Channel creation atomically creates its Conversation identity" do
    scope = user_scope_fixture()
    {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Conversation foundation"})

    assert %Conversation{
             id: conversation_id,
             kind: :workspace_channel,
             last_message_seq: 0
           } = Repo.get(Conversation, workspace.default_channel_id)

    assert conversation_id == workspace.default_channel_id

    conversation_count = Repo.aggregate(Conversation, :count)

    assert {:error, :invalid_channel, _changeset} =
             Workspaces.create_channel(scope, workspace.id, %{name: "INVALID CHANNEL!"})

    assert Repo.aggregate(Conversation, :count) == conversation_count
  end

  test "Messages use Conversation-local sequences allocated with insertion" do
    scope = user_scope_fixture()
    {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Sequenced conversation"})

    assert {:ok, first} =
             Chat.send_message(scope, workspace.default_channel_id, %{"content" => "first"})

    assert {:ok, second} =
             Chat.send_message(scope, workspace.default_channel_id, %{"content" => "second"})

    assert %Message{channel_id: conversation_id, seq: 1} = first
    assert %Message{channel_id: ^conversation_id, seq: 2} = second

    assert %Conversation{last_message_seq: 2} = Repo.get!(Conversation, conversation_id)
  end

  test "deleting a Channel removes its Conversation-owned durable state" do
    scope = user_scope_fixture()
    {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Conversation lifecycle"})
    {:ok, channel} = Workspaces.create_channel(scope, workspace.id, %{name: "temporary"})
    {:ok, message} = Chat.send_message(scope, channel.id, %{"content" => "temporary"})

    assert {:ok, _channel} = Workspaces.delete_channel(scope, workspace.id, channel.id)

    refute Repo.get(Conversation, channel.id)
    refute Repo.get(Message, message.id)
  end

  test "the database rejects a committed bare Conversation" do
    assert_raise Postgrex.Error, ~r/conversations_require_matching_subtype/, fn ->
      Repo.transaction(fn ->
        Repo.insert!(%Conversation{kind: :workspace_channel})
        Ecto.Adapters.SQL.query!(Repo, "SET CONSTRAINTS ALL IMMEDIATE", [])
      end)
    end
  end

  test "the database rejects deleting a subtype without its Conversation parent" do
    scope = user_scope_fixture()
    {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Subtype integrity"})
    {:ok, channel} = Workspaces.create_channel(scope, workspace.id, %{name: "protected"})

    assert_raise Postgrex.Error, ~r/conversations_require_matching_subtype/, fn ->
      Repo.transaction(fn ->
        Repo.delete!(channel)
        Ecto.Adapters.SQL.query!(Repo, "SET CONSTRAINTS ALL IMMEDIATE", [])
      end)
    end

    assert Repo.get(Conversation, channel.id)
  end
end
