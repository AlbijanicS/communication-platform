defmodule DiscordClone.Media.DirectCallTargetTest do
  use ExUnit.Case, async: false

  alias DiscordClone.Media.{AdmissionCoordinator, DirectCallTarget, Profile, Target}
  alias DiscordClone.Voice

  test "equal Voice and Call IDs have independent generation-qualified Session supervisors" do
    id = Ecto.UUID.generate()
    voice_user = Ecto.UUID.generate()
    assert {:ok, voice_session} = Voice.join(id, voice_user, "voice-owner", self())
    {^id, room} = List.keyfind(Voice.running_room_servers(), id, 0)
    tree = :sys.get_state(room).room_supervisor

    on_exit(fn ->
      Voice.end_channel_sessions(id)
      Voice.expire_idle_room(id)
    end)

    call = start_supervised!({DirectCallTarget, call_id: id})
    assert {:ok, %{runtime_generation: generation}} = DirectCallTarget.identity(call)
    assert {:ok, _} = DirectCallTarget.admit(call, Ecto.UUID.generate())
    assert {:ok, _} = DirectCallTarget.admit(call, Ecto.UUID.generate())

    voice_sessions =
      GenServer.whereis(Target.runtime_name(Target.voice_channel(id), room, :sessions))

    call_sessions =
      GenServer.whereis(Target.runtime_name(Target.direct_call(id), generation, :sessions))

    assert is_pid(voice_sessions)
    assert is_pid(call_sessions)
    refute voice_sessions == call_sessions
    assert %{active: 1} = DynamicSupervisor.count_children(voice_sessions)
    assert %{active: 2} = DynamicSupervisor.count_children(call_sessions)

    call_monitor = Process.monitor(call)
    sessions_monitor = Process.monitor(call_sessions)
    assert :ok = DirectCallTarget.shutdown(call)
    assert_receive {:DOWN, ^call_monitor, :process, ^call, :normal}
    assert_receive {:DOWN, ^sessions_monitor, :process, ^call_sessions, :shutdown}
    assert {:ok, ^voice_session} = Voice.join(id, voice_user, "voice-owner", self())
    assert %{active: 1} = DynamicSupervisor.count_children(voice_sessions)
    assert is_list(Supervisor.which_children(tree))
  end

  test "a supervised target admits two opaque Call Sessions and refuses a third" do
    call_id = Ecto.UUID.generate()
    first_user_id = Ecto.UUID.generate()
    second_user_id = Ecto.UUID.generate()
    target = start_supervised!({DirectCallTarget, call_id: call_id})

    assert {:ok, %{call_id: ^call_id, runtime_generation: generation, profile: %Profile{}}} =
             DirectCallTarget.identity(target)

    assert {:ok, first} = DirectCallTarget.admit(target, first_user_id)
    assert {:ok, second} = DirectCallTarget.admit(target, second_user_id)
    assert first.call_session_id != second.call_session_id

    for id <- [call_id, first_user_id, second_user_id] do
      refute first.call_session_id == id
      refute second.call_session_id == id
    end

    assert {:error, :full} = DirectCallTarget.admit(target, Ecto.UUID.generate())

    assert %{runtime_generation: ^generation, status: :ready, sessions: sessions} =
             AdmissionCoordinator.call_target_snapshot(call_id)

    assert Map.keys(sessions) |> Enum.sort() ==
             Enum.sort([first.call_session_id, second.call_session_id])
  end

  test "Session supervisor failure retires both Call children while Voice remains admitted" do
    voice_id = Ecto.UUID.generate()
    voice_user = Ecto.UUID.generate()
    assert {:ok, voice_session} = Voice.join(voice_id, voice_user, "retained", self())

    on_exit(fn ->
      Voice.end_channel_sessions(voice_id)
      Voice.expire_idle_room(voice_id)
    end)

    call_id = Ecto.UUID.generate()
    target = start_supervised!({DirectCallTarget, call_id: call_id})
    assert {:ok, _} = DirectCallTarget.admit(target, Ecto.UUID.generate())
    assert {:ok, _} = DirectCallTarget.admit(target, Ecto.UUID.generate())
    sessions = session_supervisor(target)
    children = DynamicSupervisor.which_children(sessions)
    assert length(children) == 2
    monitors = for {_, pid, _, _} <- children, do: {pid, Process.monitor(pid)}
    target_monitor = Process.monitor(target)

    Process.exit(sessions, :kill)
    assert_receive {:DOWN, ^target_monitor, :process, ^target, _reason}

    for {pid, monitor} <- monitors do
      assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}
    end

    assert %{status: :failed, sessions: %{}} = wait_for_status(call_id, :failed)
    assert {:ok, ^voice_session} = Voice.join(voice_id, voice_user, "retained", self())
  end

  test "startup failure reports the Call ID and failed runtime generation" do
    call_id = Ecto.UUID.generate()

    assert {:error, :invalid_profile} =
             DirectCallTarget.start_link(
               call_id: call_id,
               profile: %Profile{kind: :direct_call, capacity: 3, topology: :one_to_one}
             )

    assert %{
             call_id: ^call_id,
             runtime_generation: generation,
             status: :failed,
             sessions: %{},
             failure: %{kind: :startup, reason: :invalid_profile}
           } =
             AdmissionCoordinator.call_target_snapshot(call_id)

    assert is_reference(generation)
  end

  test "a logical Session crash reports its exact identity" do
    call_id = Ecto.UUID.generate()
    user_id = Ecto.UUID.generate()
    target = start_supervised!({DirectCallTarget, call_id: call_id})
    {:ok, %{runtime_generation: generation}} = DirectCallTarget.identity(target)
    {:ok, %{call_session_id: session_id}} = DirectCallTarget.admit(target, user_id)

    session_pid = target |> session_supervisor() |> DynamicSupervisor.which_children()
    [{_, session_pid, _, _}] = session_pid
    monitor = Process.monitor(session_pid)
    Process.exit(session_pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^session_pid, :killed}

    assert %{
             call_id: ^call_id,
             runtime_generation: ^generation,
             status: :failed,
             sessions: %{},
             failure: %{
               kind: :session,
               user_id: ^user_id,
               call_session_id: ^session_id,
               reason: :killed
             }
           } =
             wait_for_status(call_id, :failed)

    assert %{active: 0} = DynamicSupervisor.count_children(session_supervisor(target))
  end

  test "a target crash reports the Call ID, runtime generation, and surviving Session identities" do
    call_id = Ecto.UUID.generate()
    user_id = Ecto.UUID.generate()
    target = start_supervised!({DirectCallTarget, call_id: call_id})
    {:ok, %{runtime_generation: generation}} = DirectCallTarget.identity(target)
    {:ok, %{call_session_id: session_id}} = DirectCallTarget.admit(target, user_id)

    {DiscordClone.Media.DirectCallTargetServer, server, _, _} =
      target
      |> Supervisor.which_children()
      |> List.keyfind(DiscordClone.Media.DirectCallTargetServer, 0)

    monitor = Process.monitor(target)
    Process.exit(server, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^target, _reason}

    assert %{
             call_id: ^call_id,
             runtime_generation: ^generation,
             status: :failed,
             sessions: %{},
             failure: %{kind: :target, sessions: %{^session_id => ^user_id}}
           } =
             wait_for_status(call_id, :failed)
  end

  test "orderly shutdown removes both Sessions and repeated shutdown is harmless" do
    call_id = Ecto.UUID.generate()
    target = start_supervised!({DirectCallTarget, call_id: call_id})
    {:ok, first} = DirectCallTarget.admit(target, Ecto.UUID.generate())
    {:ok, second} = DirectCallTarget.admit(target, Ecto.UUID.generate())
    monitor = Process.monitor(target)

    assert :ok = DirectCallTarget.shutdown(target)
    assert_receive {:DOWN, ^monitor, :process, ^target, :normal}
    assert :ok = DirectCallTarget.shutdown(target)
    assert %{status: :stopped, sessions: %{}} = AdmissionCoordinator.call_target_snapshot(call_id)
    assert first.call_session_id != second.call_session_id
  end

  test "a replaced target ignores reports from the old runtime generation" do
    call_id = Ecto.UUID.generate()
    old_target = start_supervised!({DirectCallTarget, call_id: call_id})
    {:ok, %{runtime_generation: old_generation}} = DirectCallTarget.identity(old_target)
    user_id = Ecto.UUID.generate()
    {:ok, old_session} = DirectCallTarget.admit(old_target, user_id)
    new_target = start_supervised!({DirectCallTarget, call_id: call_id}, id: :replacement_target)
    {:ok, %{runtime_generation: new_generation}} = DirectCallTarget.identity(new_target)
    refute old_generation == new_generation
    {:ok, new_session} = DirectCallTarget.admit(new_target, user_id)
    old_name = Target.runtime_name(Target.direct_call(call_id), old_generation, :sessions)
    new_name = Target.runtime_name(Target.direct_call(call_id), new_generation, :sessions)
    old_supervisor = GenServer.whereis(old_name)
    new_supervisor = GenServer.whereis(new_name)
    assert is_pid(old_supervisor)
    assert is_pid(new_supervisor)
    refute old_supervisor == new_supervisor
    old_monitor = Process.monitor(old_supervisor)

    assert :ok = DirectCallTarget.shutdown(old_target)
    assert_receive {:DOWN, ^old_monitor, :process, ^old_supervisor, :shutdown}
    assert GenServer.whereis(old_name) == nil
    assert GenServer.whereis(new_name) == new_supervisor
    assert %{active: 1} = DynamicSupervisor.count_children(new_supervisor)

    assert :ok =
             AdmissionCoordinator.call_session_removed(
               call_id,
               old_generation,
               user_id,
               old_session.call_session_id
             )

    assert :ok =
             AdmissionCoordinator.call_session_failed(
               call_id,
               old_generation,
               user_id,
               new_session.call_session_id,
               :late
             )

    assert %{runtime_generation: ^new_generation, status: :ready, sessions: sessions} =
             AdmissionCoordinator.call_target_snapshot(call_id)

    assert Map.keys(sessions) == [new_session.call_session_id]

    assert :ok = DirectCallTarget.shutdown(new_target)
    assert :ok = AdmissionCoordinator.call_target_start_failed(call_id, old_generation, :late)

    assert %{runtime_generation: ^new_generation, status: :stopped} =
             AdmissionCoordinator.call_target_snapshot(call_id)
  end

  test "late readiness from an older start cannot replace the current runtime" do
    call_id = Ecto.UUID.generate()
    old_generation = make_ref()
    current_generation = make_ref()

    assert :ok = AdmissionCoordinator.call_target_starting(call_id, old_generation)
    assert :ok = AdmissionCoordinator.call_target_starting(call_id, current_generation)
    assert :ok = AdmissionCoordinator.call_target_ready(call_id, current_generation, self())

    assert {:error, :stale_runtime} =
             AdmissionCoordinator.call_target_ready(call_id, old_generation, self())

    assert %{runtime_generation: ^current_generation, status: :ready} =
             AdmissionCoordinator.call_target_snapshot(call_id)
  end

  defp session_supervisor(target) do
    {DynamicSupervisor, pid, _, _} =
      target |> Supervisor.which_children() |> List.keyfind(DynamicSupervisor, 0)

    pid
  end

  defp wait_for_status(call_id, status) do
    wait_for_status(call_id, status, System.monotonic_time(:millisecond) + 1_000)
  end

  defp wait_for_status(call_id, status, deadline) do
    snapshot = AdmissionCoordinator.call_target_snapshot(call_id)

    if snapshot.status == status or System.monotonic_time(:millisecond) >= deadline do
      assert snapshot.status == status
      snapshot
    else
      # The Session DOWN is handled by its target before reaching admission.
      # A coordinator round trip alone cannot synchronize that notification.
      :erlang.yield()
      wait_for_status(call_id, status, deadline)
    end
  end
end
