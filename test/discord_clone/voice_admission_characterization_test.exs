defmodule DiscordClone.VoiceAdmissionCharacterizationTest do
  use DiscordClone.DataCase, async: false

  alias DiscordClone.Voice

  setup do
    on_exit(fn ->
      Voice.running_room_servers()
      |> Enum.each(fn {voice_channel_id, _room_server} ->
        :ok = Voice.end_channel_sessions(voice_channel_id)
        :ok = Voice.expire_idle_room(voice_channel_id)
      end)
    end)

    :ok
  end

  test "a repeated join retains its exact Session and a full destination preserves it" do
    current_room = Ecto.UUID.generate()
    full_room = Ecto.UUID.generate()
    user_id = Ecto.UUID.generate()

    assert {:ok, %{voice_session_id: current_session_id, occupancy: 1, capacity: 5} = joined} =
             Voice.join(current_room, user_id, "owner-connection", self())

    assert {:ok, ^joined} = Voice.join(current_room, user_id, "owner-connection", self())

    for number <- 1..5 do
      assert {:ok, %{occupancy: ^number, capacity: 5}} =
               Voice.join(full_room, Ecto.UUID.generate(), "filler-#{number}", self())
    end

    assert {:error, %{reason: :room_full, occupancy: 5, capacity: 5}} =
             Voice.join(full_room, user_id, "new-connection", self())

    assert {:ok, ^joined} = Voice.join(current_room, user_id, "owner-connection", self())
    assert {:ok, %{occupancy: 1, capacity: 5}} = Voice.room_occupancy(current_room)
    assert {:ok, %{members: [%{user_id: ^user_id}]}} = Voice.voice_channel_roster(current_room)

    assert :ok = Voice.leave(current_room, current_session_id)
    assert {:ok, %{members: []}} = Voice.voice_channel_roster(current_room)
    assert {:ok, %{occupancy: 5, capacity: 5}} = Voice.room_occupancy(full_room)
  end

  test "cross-room movement retires the old exact Session and leaves unrelated Sessions alone" do
    source_room = Ecto.UUID.generate()
    destination_room = Ecto.UUID.generate()
    mover = Ecto.UUID.generate()
    retained = Ecto.UUID.generate()

    assert {:ok, %{voice_session_id: old_session_id}} =
             Voice.join(source_room, mover, "mover-old", self())

    assert {:ok, %{voice_session_id: retained_session_id}} =
             Voice.join(source_room, retained, "retained", self())

    assert :ok = Voice.subscribe_to_voice_channel_roster(source_room)
    assert :ok = Voice.subscribe_to_voice_channel_roster(destination_room)

    assert {:ok, %{voice_session_id: new_session_id, occupancy: 1, capacity: 5}} =
             Voice.join(destination_room, mover, "mover-new", self())

    refute new_session_id == old_session_id

    assert_receive {:voice_channel_roster_changed, first_move_snapshot}

    assert %{voice_channel_id: ^source_room, members: [%{user_id: ^retained}]} =
             first_move_snapshot

    assert_receive {:voice_channel_roster_changed, second_move_snapshot}

    assert %{voice_channel_id: ^destination_room, members: [%{user_id: ^mover}]} =
             second_move_snapshot

    assert {:ok, %{members: [%{user_id: ^retained}]}} = Voice.voice_channel_roster(source_room)
    assert {:ok, %{members: [%{user_id: ^mover}]}} = Voice.voice_channel_roster(destination_room)

    assert :ok = Voice.leave(source_room, old_session_id)
    assert {:ok, %{occupancy: 1, capacity: 5}} = Voice.room_occupancy(destination_room)
    assert :ok = Voice.leave(source_room, retained_session_id)
    assert {:ok, %{members: []}} = Voice.voice_channel_roster(source_room)
    assert {:ok, %{members: [%{user_id: ^mover}]}} = Voice.voice_channel_roster(destination_room)
  end

  test "Session death and room failure remove only their exact memberships" do
    affected_room = Ecto.UUID.generate()
    retained_room = Ecto.UUID.generate()
    failed_user = Ecto.UUID.generate()
    sibling_user = Ecto.UUID.generate()
    retained_user = Ecto.UUID.generate()
    assert :ok = Voice.subscribe_to_voice_channel_roster(affected_room)

    assert {:ok, %{voice_session_id: failed_session_id}} =
             Voice.join(affected_room, failed_user, "failed", self())

    assert {:ok, %{voice_session_id: sibling_session_id}} =
             Voice.join(affected_room, sibling_user, "sibling", self())

    assert {:ok, %{voice_session_id: retained_session_id}} =
             Voice.join(retained_room, retained_user, "retained", self())

    assert :ok = Voice.crash_session(affected_room, failed_session_id)

    assert_receive {:voice_channel_roster_changed,
                    %{voice_channel_id: ^affected_room, members: [%{user_id: ^sibling_user}]}}

    assert {:ok, %{members: [%{user_id: ^sibling_user}]}} =
             Voice.voice_channel_roster(affected_room)

    assert {:ok, %{members: [%{user_id: ^retained_user}]}} =
             Voice.voice_channel_roster(retained_room)

    {^affected_room, affected_room_server} =
      Enum.find(Voice.running_room_servers(), fn {room_id, _pid} -> room_id == affected_room end)

    room_monitor = Process.monitor(affected_room_server)
    assert :ok = Voice.crash_forwarder(affected_room)
    assert_receive {:DOWN, ^room_monitor, :process, ^affected_room_server, _reason}
    assert {:ok, %{members: []}} = Voice.voice_channel_roster(affected_room)

    assert {:ok, %{members: [%{user_id: ^retained_user}]}} =
             Voice.voice_channel_roster(retained_room)

    assert :ok = Voice.leave(affected_room, sibling_session_id)
    assert :ok = Voice.leave(retained_room, retained_session_id)
  end

  test "coordinator restart rejects admission until surviving rooms retire" do
    old_room = Ecto.UUID.generate()
    new_room = Ecto.UUID.generate()
    user_id = Ecto.UUID.generate()

    assert {:ok, %{voice_session_id: old_session_id}} =
             Voice.join(old_room, user_id, "before-restart", self())

    {^old_room, room_server} =
      Enum.find(Voice.running_room_servers(), fn {room_id, _pid} -> room_id == old_room end)

    room_supervisor = :sys.get_state(room_server).room_supervisor
    tree_monitor = Process.monitor(room_supervisor)
    room_monitor = Process.monitor(room_server)
    coordinator = Process.whereis(DiscordClone.Voice.SessionCoordinator)
    coordinator_monitor = Process.monitor(coordinator)

    :ok = :sys.suspend(room_server)

    try do
      assert :ok = Voice.crash_session_coordinator()
      assert_receive {:DOWN, ^coordinator_monitor, :process, ^coordinator, :killed}

      assert {:error, :recovering} =
               Voice.join(new_room, Ecto.UUID.generate(), "during-recovery", self())

      refute Voice.room_running?(new_room)
    after
      :sys.resume(room_server)
    end

    assert_receive {:DOWN, ^room_monitor, :process, ^room_server, _reason}
    assert_receive {:DOWN, ^tree_monitor, :process, ^room_supervisor, _reason}, 1_000
    assert :ok = Voice.await_session_coordinator_recovery()
    refute Voice.room_running?(old_room)

    assert {:ok, %{voice_session_id: fresh_session_id, occupancy: 1, capacity: 5}} =
             Voice.join(new_room, user_id, "after-recovery", self())

    refute fresh_session_id == old_session_id
  end

  test "explicit runtime shutdown retires the whole tree without restarting an empty room" do
    room_id = Ecto.UUID.generate()
    assert {:ok, _} = Voice.join(room_id, Ecto.UUID.generate(), "owner", self())
    {^room_id, room} = List.keyfind(Voice.running_room_servers(), room_id, 0)
    supervisor = :sys.get_state(room).room_supervisor
    monitor = Process.monitor(supervisor)

    assert :ok = DiscordClone.Voice.RoomServer.shutdown(room)
    assert_receive {:DOWN, ^monitor, :process, ^supervisor, :shutdown}, 1_000
    refute Voice.room_running?(room_id)
  end

  test "a rebuilt room ignores retired component identities and admits fresh Sessions" do
    room_id = Ecto.UUID.generate()
    assert {:ok, _} = Voice.join(room_id, Ecto.UUID.generate(), "old", self())
    {^room_id, old_room} = List.keyfind(Voice.running_room_servers(), room_id, 0)
    old_state = :sys.get_state(old_room)
    old_name = DiscordClone.Voice.SessionSupervisor.name(room_id)
    old_monitor = Process.monitor(old_room)
    sessions_monitor = Process.monitor(old_state.session_supervisor)

    assert :ok = Voice.crash_forwarder(room_id)
    assert_receive {:DOWN, ^old_monitor, :process, ^old_room, _reason}
    assert_receive {:DOWN, ^sessions_monitor, :process, _, _reason}
    assert {:ok, %{occupancy: 1}} = Voice.join(room_id, Ecto.UUID.generate(), "fresh", self())
    {^room_id, fresh_room} = List.keyfind(Voice.running_room_servers(), room_id, 0)
    refute fresh_room == old_room
    assert GenServer.whereis(old_name) == nil

    send(fresh_room, {:session_supervisor_started, old_room, old_state.session_supervisor})
    send(fresh_room, {:forwarder_started, old_room, old_state.forwarder})
    _ = :sys.get_state(fresh_room)

    assert {:ok, %{occupancy: 2}} = Voice.join(room_id, Ecto.UUID.generate(), "second", self())

    assert %{active: 2} =
             DynamicSupervisor.count_children(DiscordClone.Voice.SessionSupervisor.name(room_id))
  end
end
