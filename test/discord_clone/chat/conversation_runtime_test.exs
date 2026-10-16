defmodule DiscordClone.Chat.ConversationRuntimeTest do
  use DiscordClone.DataCase, async: false

  alias DiscordClone.Chat
  alias DiscordClone.Chat.Runtime
  alias DiscordClone.Friendships
  alias DiscordClone.Workspaces

  import DiscordClone.AccountsFixtures

  describe "Conversation runtime supervision" do
    test "starts and finds a runtime by durable Conversation ID" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      conversation_id = workspace.default_channel_id

      assert {:ok, pid} = Chat.ensure_channel_runtime(scope, conversation_id)

      assert Runtime.conversation_pid(conversation_id) == pid
      assert Chat.list_recent_messages(scope, conversation_id) == {:ok, []}
    end

    test "isolates cache and typing state by Conversation ID" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      first_conversation_id = workspace.default_channel_id

      assert {:ok, second_channel} =
               Workspaces.create_channel(scope, workspace.id, %{name: "planning"})

      second_conversation_id = second_channel.id

      assert {:ok, first_message} =
               Chat.send_message(scope, first_conversation_id, %{"content" => "first only"})

      assert {:ok, second_message} =
               Chat.send_message(scope, second_conversation_id, %{"content" => "second only"})

      assert {:ok, [^first_message]} =
               Chat.list_recent_messages(scope, first_conversation_id)

      assert {:ok, [^second_message]} =
               Chat.list_recent_messages(scope, second_conversation_id)

      assert :ok = Chat.user_started_typing(scope, first_conversation_id)
      assert {:ok, [scope.user.id]} == Chat.list_typing_user_ids(scope, first_conversation_id)
      assert {:ok, []} == Chat.list_typing_user_ids(scope, second_conversation_id)

      assert Runtime.conversation_pid(first_conversation_id) !=
               Runtime.conversation_pid(second_conversation_id)
    end

    test "isolates Workspace Channel and Direct Conversation runtime state" do
      scope = user_scope_fixture()
      friend = user_fixture(username: "runtime_kind_friend")
      friend_scope = user_scope_fixture(friend)

      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Mixed conversations"})

      assert {:ok, %{relationship: request}} =
               Friendships.send_friend_request(scope, %{username: friend.username})

      assert {:ok, _friendship} = Friendships.accept_friend_request(friend_scope, request.id)
      assert {:ok, direct_conversation} = Chat.open_direct_conversation(scope, friend.id)

      assert {:ok, channel_message} =
               Chat.send_message(scope, workspace.default_channel_id, %{content: "channel only"})

      assert {:ok, direct_message} =
               Chat.send_direct_message(scope, direct_conversation.id, %{content: "direct only"})

      assert {:ok, [^channel_message]} =
               Chat.list_recent_messages(scope, workspace.default_channel_id)

      assert {:ok, [recent_direct_message]} =
               Chat.list_recent_direct_messages(scope, direct_conversation.id)

      assert recent_direct_message.id == direct_message.id

      assert :ok = Chat.user_started_typing(scope, workspace.default_channel_id)

      assert {:ok, [scope.user.id]} ==
               Chat.list_typing_user_ids(scope, workspace.default_channel_id)

      assert {:ok, []} ==
               Chat.list_direct_typing_user_ids(friend_scope, direct_conversation.id)

      assert Runtime.conversation_pid(workspace.default_channel_id) !=
               Runtime.conversation_pid(direct_conversation.id)
    end

    test "starts with a bounded recent message cache for rendering" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})

      messages =
        for index <- 1..55 do
          {:ok, message} =
            Chat.send_message(scope, workspace.default_channel_id, %{
              "content" => "message #{index}"
            })

          message
        end

      assert {:ok, cached_messages} =
               Chat.list_recent_messages(scope, workspace.default_channel_id)

      assert Enum.map(cached_messages, & &1.id) == messages |> Enum.drop(5) |> Enum.map(& &1.id)
      assert Enum.map(cached_messages, & &1.content) == Enum.map(6..55, &"message #{&1}")
      assert Enum.all?(cached_messages, &Ecto.assoc_loaded?(&1.user))
      assert Enum.all?(cached_messages, &(&1.user.username == scope.user.username))
    end

    test "stops idle channel runtimes and removes their registration" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      channel_id = workspace.default_channel_id

      put_conversation_runtime_timeout(0)

      assert {:ok, pid} = DiscordClone.Chat.ensure_channel_runtime(scope, channel_id)
      ref = Process.monitor(pid)

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
      assert Runtime.conversation_pid(channel_id) == nil
    end

    test "restarts after idle shutdown and reloads recent persisted messages" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      channel_id = workspace.default_channel_id

      assert {:ok, first_message} =
               Chat.send_message(scope, channel_id, %{"content" => "before idle"})

      put_conversation_runtime_timeout(0)

      assert {:ok, first_pid} = DiscordClone.Chat.ensure_channel_runtime(scope, channel_id)
      ref = Process.monitor(first_pid)
      assert_receive {:DOWN, ^ref, :process, ^first_pid, :normal}
      assert Runtime.conversation_pid(channel_id) == nil

      Application.put_env(
        :discord_clone,
        :conversation_runtime_inactivity_timeout_ms,
        :timer.minutes(15)
      )

      assert {:ok, second_message} =
               Chat.send_message(scope, channel_id, %{"content" => "after idle"})

      assert {:ok, recent_messages} = DiscordClone.Chat.list_recent_messages(scope, channel_id)
      assert Enum.map(recent_messages, & &1.id) == [first_message.id, second_message.id]

      assert {:ok, second_pid} = DiscordClone.Chat.ensure_channel_runtime(scope, channel_id)
      assert second_pid != first_pid
      assert Runtime.conversation_pid(channel_id) == second_pid
    end

    test "tracks typing user IDs and broadcasts typing started" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      channel_id = workspace.default_channel_id
      user_id = scope.user.id

      assert :ok = DiscordClone.Chat.subscribe_to_channel_messages(scope, channel_id)

      assert :ok = DiscordClone.Chat.user_started_typing(scope, channel_id)
      assert {:ok, [^user_id]} = DiscordClone.Chat.list_typing_user_ids(scope, channel_id)

      assert_receive {:typing_started, %{conversation_id: ^channel_id, user_id: ^user_id}}
    end

    test "repeated typing starts keep one typing user and do not rebroadcast started" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      channel_id = workspace.default_channel_id
      user_id = scope.user.id

      put_conversation_typing_timeout(1_000)

      assert :ok = DiscordClone.Chat.subscribe_to_channel_messages(scope, channel_id)
      assert :ok = DiscordClone.Chat.user_started_typing(scope, channel_id)
      assert_receive {:typing_started, %{conversation_id: ^channel_id, user_id: ^user_id}}

      assert :ok = DiscordClone.Chat.user_started_typing(scope, channel_id)

      assert {:ok, [^user_id]} = DiscordClone.Chat.list_typing_user_ids(scope, channel_id)
      refute_receive {:typing_started, _payload}, 50
    end
  end

  defp put_conversation_runtime_timeout(timeout_ms) do
    previous = Application.get_env(:discord_clone, :conversation_runtime_inactivity_timeout_ms)
    Application.put_env(:discord_clone, :conversation_runtime_inactivity_timeout_ms, timeout_ms)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:discord_clone, :conversation_runtime_inactivity_timeout_ms)
      else
        Application.put_env(:discord_clone, :conversation_runtime_inactivity_timeout_ms, previous)
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
end
