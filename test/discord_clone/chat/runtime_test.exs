defmodule DiscordClone.Chat.RuntimeTest do
  use DiscordClone.DataCase, async: false

  alias DiscordClone.Chat.{
    PresenceEvents,
    Runtime
  }

  describe "workspace presence runtime supervision" do
    test "malformed identifiers do not start or subscribe runtime processes" do
      assert Runtime.ensure_workspace_presence("not-a-uuid") == {:error, :not_found}
      assert Runtime.subscribe_workspace_presence("not-a-uuid") == {:error, :not_found}

      assert Runtime.join_workspace_presence("not-a-uuid", "also-invalid", self()) ==
               {:error, :not_found}

      assert Runtime.ensure_conversation("not-a-uuid") == {:error, :not_found}
      assert Runtime.workspace_presence_pid("not-a-uuid") == nil
      assert Runtime.conversation_pid("not-a-uuid") == nil
    end

    test "starts and finds a workspace presence runtime by durable workspace ID" do
      workspace_id = Ecto.UUID.generate()

      assert {:ok, pid} = Runtime.ensure_workspace_presence(workspace_id)
      assert Runtime.online_user_ids(workspace_id) == []
      assert is_pid(pid)
    end

    test "starting the same workspace runtime twice returns the active process" do
      workspace_id = Ecto.UUID.generate()

      assert {:ok, first_pid} = Runtime.ensure_workspace_presence(workspace_id)
      assert {:ok, second_pid} = Runtime.ensure_workspace_presence(workspace_id)

      assert second_pid == first_pid
      assert Runtime.workspace_presence_pid(workspace_id) == first_pid
    end

    test "runtime online user listing does not start an absent workspace runtime" do
      workspace_id = Ecto.UUID.generate()

      assert Runtime.online_user_ids(workspace_id) == []
      assert Runtime.workspace_presence_pid(workspace_id) == nil
    end

    test "facade recovers workspace presence after runtime loss" do
      workspace_id = Ecto.UUID.generate()
      user_id = Ecto.UUID.generate()
      assert {:ok, pid} = Runtime.ensure_workspace_presence(workspace_id)

      ref = Process.monitor(pid)
      Process.exit(pid, :kill)

      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

      assert :ok = Runtime.join_workspace_presence(workspace_id, user_id, self())
      assert Runtime.online_user_ids(workspace_id) == [user_id]
    end
  end

  describe "workspace presence connections" do
    test "joining presence for a user and pid records that user as online" do
      workspace_id = Ecto.UUID.generate()
      user_id = Ecto.UUID.generate()
      live_view_pid = self()

      assert :ok = Runtime.join_workspace_presence(workspace_id, user_id, live_view_pid)
      assert Runtime.online_user_ids(workspace_id) == [user_id]
    end

    test "joining presence for the same user and same pid is idempotent" do
      workspace_id = Ecto.UUID.generate()
      user_id = Ecto.UUID.generate()
      live_view_pid = self()

      assert :ok = Runtime.join_workspace_presence(workspace_id, user_id, live_view_pid)
      assert :ok = Runtime.join_workspace_presence(workspace_id, user_id, live_view_pid)

      assert Runtime.online_user_ids(workspace_id) == [user_id]
    end

    test "joining presence for the same user from multiple pids keeps one online user id" do
      workspace_id = Ecto.UUID.generate()
      user_id = Ecto.UUID.generate()
      first_live_view_pid = self()
      second_live_view_pid = start_live_view_process()

      assert :ok = Runtime.join_workspace_presence(workspace_id, user_id, first_live_view_pid)
      assert :ok = Runtime.join_workspace_presence(workspace_id, user_id, second_live_view_pid)

      assert Runtime.online_user_ids(workspace_id) == [user_id]
    end

    test "joining presence for different users tracks each user independently" do
      workspace_id = Ecto.UUID.generate()
      first_user_id = Ecto.UUID.generate()
      second_user_id = Ecto.UUID.generate()
      first_live_view_pid = self()
      second_live_view_pid = start_live_view_process()

      assert :ok =
               Runtime.join_workspace_presence(workspace_id, second_user_id, second_live_view_pid)

      assert :ok =
               Runtime.join_workspace_presence(workspace_id, first_user_id, first_live_view_pid)

      assert Runtime.online_user_ids(workspace_id) ==
               Enum.sort([first_user_id, second_user_id])
    end

    test "when the last pid for a user exits the user is removed from online state" do
      workspace_id = Ecto.UUID.generate()
      user_id = Ecto.UUID.generate()
      live_view_pid = start_live_view_process()

      assert :ok = Runtime.subscribe_workspace_presence(workspace_id)
      assert :ok = Runtime.join_workspace_presence(workspace_id, user_id, live_view_pid)
      workspace_pid = Runtime.workspace_presence_pid(workspace_id)
      assert_receive {:workspace_user_joined, %{workspace_id: ^workspace_id, user_id: ^user_id}}
      assert Runtime.online_user_ids(workspace_id) == [user_id]

      ref = Process.monitor(live_view_pid)
      send(live_view_pid, :stop)

      assert_receive {:DOWN, ^ref, :process, ^live_view_pid, :normal}
      _ = :sys.get_state(workspace_pid)

      assert_receive {:workspace_user_left, %{workspace_id: ^workspace_id, user_id: ^user_id}},
                     6_000

      assert Runtime.online_user_ids(workspace_id) == []
    end

    test "when one of several pids for a user exits the user remains online" do
      workspace_id = Ecto.UUID.generate()
      user_id = Ecto.UUID.generate()
      first_live_view_pid = start_live_view_process()
      second_live_view_pid = start_live_view_process()

      assert :ok = Runtime.join_workspace_presence(workspace_id, user_id, first_live_view_pid)
      assert :ok = Runtime.join_workspace_presence(workspace_id, user_id, second_live_view_pid)
      workspace_pid = Runtime.workspace_presence_pid(workspace_id)
      assert Runtime.online_user_ids(workspace_id) == [user_id]

      ref = Process.monitor(first_live_view_pid)
      send(first_live_view_pid, :stop)

      assert_receive {:DOWN, ^ref, :process, ^first_live_view_pid, :normal}
      _ = :sys.get_state(workspace_pid)

      assert Runtime.online_user_ids(workspace_id) == [user_id]
    end

    test "a delayed replacement connection preserves presence and cancels the old departure" do
      workspace_id = Ecto.UUID.generate()
      user_id = Ecto.UUID.generate()
      old_connection = start_live_view_process()
      replacement = start_live_view_process()

      assert :ok = Runtime.subscribe_workspace_presence(workspace_id)
      assert :ok = Runtime.join_workspace_presence(workspace_id, user_id, old_connection)
      assert_receive {:workspace_user_joined, %{user_id: ^user_id}}
      server = Runtime.workspace_presence_pid(workspace_id)

      ref = Process.monitor(old_connection)
      send(old_connection, :stop)
      assert_receive {:DOWN, ^ref, :process, ^old_connection, :normal}
      state = :sys.get_state(server)
      {_timer, old_token} = Map.fetch!(state.pending_left_timers, user_id)

      # A normal navigation can take longer than the former 50 ms grace.
      # Assert continuity during that gap, rather than racing a fast remount.
      refute_receive {:workspace_user_left, %{user_id: ^user_id}}, 100
      assert Runtime.online_user_ids(workspace_id) == [user_id]
      assert :ok = Runtime.join_workspace_presence(workspace_id, user_id, replacement)

      # Cancellation can race an already-delivered timeout message.
      send(server, {:broadcast_user_left, user_id, old_token})
      _ = :sys.get_state(server)
      assert Runtime.online_user_ids(workspace_id) == [user_id]
      refute_received {:workspace_user_left, %{user_id: ^user_id}}
      refute_received {:workspace_user_joined, %{user_id: ^user_id}}
    end

    test "listing online user ids does not change runtime state" do
      workspace_id = Ecto.UUID.generate()
      user_id = Ecto.UUID.generate()
      live_view_pid = self()

      assert :ok = Runtime.join_workspace_presence(workspace_id, user_id, live_view_pid)

      assert Runtime.online_user_ids(workspace_id) == [user_id]
      assert Runtime.online_user_ids(workspace_id) == [user_id]
    end
  end

  describe "workspace presence broadcasts" do
    test "presence event builders expose the public event contract" do
      workspace_id = Ecto.UUID.generate()
      user_id = Ecto.UUID.generate()

      assert PresenceEvents.user_joined_event(workspace_id, user_id) ==
               {:workspace_user_joined, %{workspace_id: workspace_id, user_id: user_id}}

      assert PresenceEvents.user_left_event(workspace_id, user_id) ==
               {:workspace_user_left, %{workspace_id: workspace_id, user_id: user_id}}

      assert PresenceEvents.to_presence_event(
               PresenceEvents.user_joined_event(workspace_id, user_id)
             ) == {:ok, :user_joined, %{workspace_id: workspace_id, user_id: user_id}}

      assert PresenceEvents.to_presence_event(
               PresenceEvents.user_left_event(workspace_id, user_id)
             ) == {:ok, :user_left, %{workspace_id: workspace_id, user_id: user_id}}
    end

    test "first connection for a user broadcasts that workspace user joined" do
      workspace_id = Ecto.UUID.generate()
      user_id = Ecto.UUID.generate()
      live_view_pid = self()

      assert :ok = Runtime.subscribe_workspace_presence(workspace_id)

      assert :ok = Runtime.join_workspace_presence(workspace_id, user_id, live_view_pid)

      assert_receive {:workspace_user_joined,
                      %{workspace_id: ^workspace_id, user_id: ^user_id} = payload}

      refute Map.has_key?(payload, :user)
      refute Map.has_key?(payload, :members)
    end

    test "duplicate connection for an already-online user does not broadcast another joined event" do
      workspace_id = Ecto.UUID.generate()
      user_id = Ecto.UUID.generate()
      live_view_pid = self()

      assert :ok = Runtime.subscribe_workspace_presence(workspace_id)
      assert :ok = Runtime.join_workspace_presence(workspace_id, user_id, live_view_pid)
      assert_receive {:workspace_user_joined, %{workspace_id: ^workspace_id, user_id: ^user_id}}

      assert :ok = Runtime.join_workspace_presence(workspace_id, user_id, live_view_pid)

      refute_receive {:workspace_user_joined, _payload}, 50
    end

    test "additional connection for an already-online user does not broadcast another joined event" do
      workspace_id = Ecto.UUID.generate()
      user_id = Ecto.UUID.generate()
      first_live_view_pid = self()
      second_live_view_pid = start_live_view_process()

      assert :ok = Runtime.subscribe_workspace_presence(workspace_id)
      assert :ok = Runtime.join_workspace_presence(workspace_id, user_id, first_live_view_pid)
      assert_receive {:workspace_user_joined, %{workspace_id: ^workspace_id, user_id: ^user_id}}

      assert :ok = Runtime.join_workspace_presence(workspace_id, user_id, second_live_view_pid)

      refute_receive {:workspace_user_joined, _payload}, 50
    end

    test "last disconnect for a user broadcasts that workspace user left" do
      workspace_id = Ecto.UUID.generate()
      user_id = Ecto.UUID.generate()
      live_view_pid = start_live_view_process()

      assert :ok = Runtime.subscribe_workspace_presence(workspace_id)
      assert :ok = Runtime.join_workspace_presence(workspace_id, user_id, live_view_pid)
      workspace_pid = Runtime.workspace_presence_pid(workspace_id)
      assert_receive {:workspace_user_joined, %{workspace_id: ^workspace_id, user_id: ^user_id}}

      ref = Process.monitor(live_view_pid)
      send(live_view_pid, :stop)

      assert_receive {:DOWN, ^ref, :process, ^live_view_pid, :normal}
      _ = :sys.get_state(workspace_pid)

      assert_receive {:workspace_user_left,
                      %{workspace_id: ^workspace_id, user_id: ^user_id} = payload},
                     6_000

      refute Map.has_key?(payload, :user)
      refute Map.has_key?(payload, :members)
    end

    test "non-last disconnect for a user does not broadcast that workspace user left" do
      workspace_id = Ecto.UUID.generate()
      user_id = Ecto.UUID.generate()
      first_live_view_pid = start_live_view_process()
      second_live_view_pid = start_live_view_process()

      assert :ok = Runtime.subscribe_workspace_presence(workspace_id)
      assert :ok = Runtime.join_workspace_presence(workspace_id, user_id, first_live_view_pid)
      workspace_pid = Runtime.workspace_presence_pid(workspace_id)
      assert_receive {:workspace_user_joined, %{workspace_id: ^workspace_id, user_id: ^user_id}}
      assert :ok = Runtime.join_workspace_presence(workspace_id, user_id, second_live_view_pid)

      ref = Process.monitor(first_live_view_pid)
      send(first_live_view_pid, :stop)

      assert_receive {:DOWN, ^ref, :process, ^first_live_view_pid, :normal}
      _ = :sys.get_state(workspace_pid)

      refute_receive {:workspace_user_left, _payload}, 50
    end
  end

  defp start_live_view_process do
    start_supervised!(%{
      id: Ecto.UUID.generate(),
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
