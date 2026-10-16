defmodule DiscordClone.CallsTargetStartupTest do
  use DiscordClone.DataCase, async: false

  import DiscordClone.CallsFixtures

  alias DiscordClone.Calls
  alias DiscordClone.Media.{AdmissionCoordinator, DirectCallTarget}
  alias DiscordClone.MediaFixtures
  alias DiscordClone.Voice

  setup do
    start_supervised!(DiscordClone.Calls.Supervisor)
    DiscordClone.Calls.CallCoordinator.begin_recovery()
    await_recovery_finished()

    previous_runtime = Application.get_env(:discord_clone, :accepted_call_runtime)

    Application.put_env(
      :discord_clone,
      :accepted_call_runtime,
      DiscordClone.Calls.PairAdmissionRuntime
    )

    on_exit(fn ->
      Application.delete_env(:discord_clone, :call_target_startup_control)

      if previous_runtime do
        Application.put_env(:discord_clone, :accepted_call_runtime, previous_runtime)
      else
        Application.delete_env(:discord_clone, :accepted_call_runtime)
      end

      MediaFixtures.reset_coordinator_pair_state!()

      for {channel, _pid} <- Voice.running_room_servers() do
        :ok = Voice.end_channel_sessions(channel)
        :ok = Voice.expire_idle_room(channel)
      end
    end)

    :ok
  end

  for form <- [:returned_error, :exit] do
    @form form
    test "#{form} coordinator uncertainty preserves ringing and both Voices, then accepts a retry" do
      pair = ringing_pair_in_voice("startup_#{@form}")

      Application.put_env(:discord_clone, :call_target_startup_control, %{
        barrier: fn :before_start, _context ->
          case @form do
            :returned_error ->
              {:error, :recovering}

            :exit ->
              exit(
                {:noproc, {GenServer, :call, [DiscordClone.Voice.SessionCoordinator, :startup]}}
              )
          end
        end
      })

      assert {:error, :temporarily_unavailable} =
               Calls.accept_call(pair.recipient, pair.call_id, :audio)

      assert_ringing_and_voices(pair)

      Application.delete_env(:discord_clone, :call_target_startup_control)

      assert {:ok, %{state: :connecting}} =
               Calls.accept_call(pair.recipient, pair.call_id, :audio)

      assert eventually_active?(pair.call_id)
      assert {:ok, %{state: :active}} = Calls.get_call(pair.recipient, pair.call_id)

      assert %{status: :ready, sessions: sessions} =
               AdmissionCoordinator.call_target_snapshot(pair.call_id)

      assert map_size(sessions) == 2
      assert length(running_targets()) == 1
    end
  end

  for form <- [:returned_error, :exit] do
    @form form
    test "#{form} uncertainty after claiming startup releases only that claim" do
      pair = ringing_pair_in_voice("claimed_#{@form}")
      parent = self()

      Application.put_env(:discord_clone, :call_target_startup_control, %{
        barrier: fn
          :claimed, %{generation: generation} ->
            send(parent, {:startup_claim, generation})

            case @form do
              :returned_error ->
                {:error,
                 {:shutdown,
                  {:failed_to_start_child, DiscordClone.Media.DirectCallTargetServer,
                   {:noproc,
                    {GenServer, :call, [DiscordClone.Voice.SessionCoordinator, :startup]}}}}}

              :exit ->
                exit(
                  {:timeout,
                   {GenServer, :call, [DiscordClone.Voice.SessionCoordinator, :startup]}}
                )
            end

          _stage, _context ->
            :ok
        end
      })

      assert {:error, :temporarily_unavailable} =
               Calls.accept_call(pair.recipient, pair.call_id, :audio)

      assert_ringing_and_voices(pair)
      assert_receive {:startup_claim, old_generation}

      assert {:error, :stale_runtime} =
               AdmissionCoordinator.call_target_ready(pair.call_id, old_generation, self())

      Application.delete_env(:discord_clone, :call_target_startup_control)

      assert {:ok, %{state: :connecting}} =
               Calls.accept_call(pair.recipient, pair.call_id, :audio)

      assert eventually_active?(pair.call_id)
      current = AdmissionCoordinator.call_target_snapshot(pair.call_id)

      assert :ok =
               AdmissionCoordinator.call_target_start_failed(pair.call_id, old_generation, :late)

      assert {:error, :stale_runtime} =
               AdmissionCoordinator.call_target_ready(pair.call_id, old_generation, self())

      assert AdmissionCoordinator.call_target_snapshot(pair.call_id) == current
      assert length(running_targets()) == 1
    end
  end

  test "startup identity timeout preserves Voices and retires its exact target before retry" do
    pair = ringing_pair_in_voice("identity_timeout")
    parent = self()

    Application.put_env(:discord_clone, :call_target_startup_control, %{
      identity_timeout_ms: 25,
      barrier: fn
        :started, %{target: target} ->
          {DiscordClone.Media.DirectCallTargetServer, server, _, _} =
            target
            |> Supervisor.which_children()
            |> List.keyfind(DiscordClone.Media.DirectCallTargetServer, 0)

          :ok = :sys.suspend(server)
          send(parent, {:suspended_identity, target, server})
          :ok

        _stage, _context ->
          :ok
      end
    })

    try do
      assert {:error, :temporarily_unavailable} =
               Calls.accept_call(pair.recipient, pair.call_id, :audio)

      assert_ringing_and_voices(pair)
    after
      assert_receive {:suspended_identity, _target, server}

      try do
        :sys.resume(server)
      catch
        :exit, _ -> :ok
      end
    end

    Application.delete_env(:discord_clone, :call_target_startup_control)
    assert {:ok, %{state: :connecting}} = Calls.accept_call(pair.recipient, pair.call_id, :audio)
    assert eventually_active?(pair.call_id)
    assert length(running_targets()) == 1
  end

  test "coordinator restart during target startup keeps the Call retryable" do
    {caller, recipient, conversation, _} = direct_conversation_fixture("startup_restart")
    assert {:ok, %{call: ringing}} = Calls.start_call(caller, conversation.id, :audio)

    Application.put_env(:discord_clone, :call_target_startup_control, %{
      barrier: fn
        :before_start, _context ->
          coordinator = Process.whereis(DiscordClone.Voice.SessionCoordinator)
          monitor = Process.monitor(coordinator)
          assert :ok = Voice.crash_session_coordinator()
          assert_receive {:DOWN, ^monitor, :process, ^coordinator, :killed}

          assert poll_until(
                   ringing.call_id,
                   fn -> is_pid(Process.whereis(DiscordClone.Voice.SessionCoordinator)) end,
                   System.monotonic_time(:millisecond) + 2_000
                 )

          assert :ok = AdmissionCoordinator.await_ready()
          exit({:noproc, {GenServer, :call, [coordinator, :startup]}})

        _stage, _context ->
          :ok
      end
    })

    assert {:error, :temporarily_unavailable} =
             Calls.accept_call(recipient, ringing.call_id, :audio)

    assert {:ok, %{state: :ringing}} = Calls.get_call(recipient, ringing.call_id)
    assert AdmissionCoordinator.call_target_snapshot(ringing.call_id) == nil
    assert running_targets() == []

    Application.delete_env(:discord_clone, :call_target_startup_control)
    assert {:ok, %{state: :connecting}} = Calls.accept_call(recipient, ringing.call_id, :audio)
    assert eventually_active?(ringing.call_id)
    assert length(running_targets()) == 1
  end

  test "definite target startup failure remains terminal and cleans its failed record" do
    pair = ringing_pair_in_voice("definite_start")

    Application.put_env(:discord_clone, :call_target_startup_control, %{
      barrier: fn
        :claimed, _context ->
          {:error,
           {:shutdown,
            {:failed_to_start_child, DiscordClone.Media.DirectCallTargetServer, :invalid_profile}}}

        _stage, _context ->
          :ok
      end
    })

    call_id = pair.call_id

    assert {:ok, %{state: :terminal, terminal_outcome: :failed}} =
             Calls.accept_call(pair.recipient, call_id, :audio)

    assert_receive {:call_failed, %{call_id: ^call_id}}
    assert_receive {:call_failed, %{call_id: ^call_id}}
    refute_received {:call_connecting, %{call_id: ^call_id}}
    assert AdmissionCoordinator.current_identity(pair.caller.user.id) == pair.caller_prior
    assert AdmissionCoordinator.current_identity(pair.recipient.user.id) == pair.recipient_prior
    assert AdmissionCoordinator.call_target_snapshot(call_id) == nil
    assert running_targets() == []
    assert :ok = AdmissionCoordinator.cleanup_active_pair_for_call(call_id)
  end

  test "one startup owns the claim and its stale completion cannot remove a replacement" do
    call_id = Ecto.UUID.generate()
    parent = self()
    barrier = make_ref()

    Application.put_env(:discord_clone, :call_target_startup_control, %{
      barrier: fn
        :claimed, %{generation: generation} ->
          send(parent, {:claimed_startup, barrier, generation, self()})

          receive do
            {:resume_startup, ^barrier} -> :ok
          end

        _stage, _context ->
          :ok
      end
    })

    tasks = start_supervised!(Task.Supervisor)
    old_start = Task.Supervisor.async_nolink(tasks, fn -> DirectCallTarget.start(call_id) end)

    assert_receive {:claimed_startup, ^barrier, old_generation, starter}

    {replacement, snapshot} =
      try do
        assert {:error, :temporarily_unavailable} =
                 AdmissionCoordinator.claim_call_target_start(call_id, make_ref())

        assert :ok = AdmissionCoordinator.call_target_start_cancelled(call_id, old_generation)

        assert {:error, :stale_runtime} =
                 AdmissionCoordinator.call_target_ready(call_id, old_generation, self())

        Application.delete_env(:discord_clone, :call_target_startup_control)
        replacement = MediaFixtures.start_ready_call_target(call_id, restart: :temporary)
        {replacement, AdmissionCoordinator.call_target_snapshot(call_id)}
      after
        send(starter, {:resume_startup, barrier})
      end

    assert {:error, :temporarily_unavailable} = Task.await(old_start)
    assert AdmissionCoordinator.call_target_snapshot(call_id) == snapshot
    assert running_targets() == []
    assert {:ok, ^replacement} = DirectCallTarget.start(call_id)

    assert {:error, :stale_runtime} =
             AdmissionCoordinator.call_target_ready(call_id, old_generation, self())

    assert :ok = AdmissionCoordinator.call_target_start_failed(call_id, old_generation, :late)
    assert AdmissionCoordinator.call_target_snapshot(call_id) == snapshot
  end

  test "late startup identity cannot take or leak ownership of a reserved replacement" do
    pair = MediaFixtures.ringing_pair_fixture("late_start")
    parent = self()
    barrier = make_ref()

    Application.put_env(:discord_clone, :call_target_startup_control, %{
      barrier: fn
        :started, %{target: target} ->
          send(parent, {:target_started, barrier, target})

          receive do
            {:resume_identity, ^barrier} -> :ok
          end

        _stage, _context ->
          :ok
      end
    })

    tasks = start_supervised!(Task.Supervisor)
    startup = Task.Supervisor.async_nolink(tasks, fn -> DirectCallTarget.start(pair.call_id) end)

    try do
      assert_receive {:target_started, ^barrier, old_target}
      monitor = Process.monitor(old_target)
      Application.delete_env(:discord_clone, :call_target_startup_control)
      replacement = MediaFixtures.start_ready_call_target(pair.call_id, restart: :temporary)

      assert {:ok, reservation} =
               AdmissionCoordinator.reserve_pair(
                 pair.call_id,
                 {pair.first_user_id, nil},
                 {pair.second_user_id, nil}
               )

      snapshot = AdmissionCoordinator.call_target_snapshot(pair.call_id)
      send(startup.pid, {:resume_identity, barrier})

      assert {:error, :temporarily_unavailable} = Task.await(startup)
      assert_receive {:DOWN, ^monitor, :process, ^old_target, _reason}
      assert running_targets() == []
      assert AdmissionCoordinator.call_target_snapshot(pair.call_id) == snapshot
      assert {:ok, generation} = AdmissionCoordinator.reservation_generation(pair.call_id)
      assert generation == reservation.generation
      assert {:ok, ^replacement} = DirectCallTarget.start(pair.call_id)
      assert :ok = AdmissionCoordinator.release_reservation(pair.call_id, generation)
    after
      send(startup.pid, {:resume_identity, barrier})
    end
  end

  test "a caller dying after the startup claim does not strand it or duplicate retry targets" do
    call_id = Ecto.UUID.generate()
    parent = self()
    barrier = make_ref()

    Application.put_env(:discord_clone, :call_target_startup_control, %{
      barrier: fn
        :claimed, %{generation: generation} ->
          send(parent, {:supervisor_claim, barrier, generation, self()})

          receive do
            {:resume_startup, ^barrier} -> :ok
          end

        _stage, _context ->
          :ok
      end
    })

    tasks = start_supervised!(Task.Supervisor)
    caller = Task.Supervisor.async_nolink(tasks, fn -> DirectCallTarget.start(call_id) end)
    assert_receive {:supervisor_claim, ^barrier, generation, starter}
    monitor = Process.monitor(caller.pid)

    try do
      Process.exit(caller.pid, :kill)
      assert_receive {:DOWN, ^monitor, :process, _pid, :killed}
      Application.delete_env(:discord_clone, :call_target_startup_control)
    after
      send(starter, {:resume_startup, barrier})
    end

    assert {:ok, target} = DirectCallTarget.start(call_id)
    assert {:ok, ^target} = DirectCallTarget.start(call_id)

    assert %{runtime_generation: ^generation, status: :ready} =
             AdmissionCoordinator.call_target_snapshot(call_id)

    assert running_targets() == [target]
  end

  test "unconfirmed startup cleanup preserves a winning same-generation reservation" do
    pair = MediaFixtures.ringing_pair_fixture("cleanup_winner")
    coordinator_name = DiscordClone.Voice.SessionCoordinator
    coordinator = Process.whereis(coordinator_name)
    parent = self()

    Application.put_env(:discord_clone, :call_target_startup_control, %{
      barrier: fn
        :started, %{target: target} ->
          assert {:ok, reservation} =
                   AdmissionCoordinator.reserve_pair(
                     pair.call_id,
                     {pair.first_user_id, nil},
                     {pair.second_user_id, nil}
                   )

          send(parent, {:winning_startup, target, reservation.generation})
          assert Process.unregister(coordinator_name)
          {:error, :unavailable}

        _stage, _context ->
          :ok
      end
    })

    try do
      assert {:error, :temporarily_unavailable} = DirectCallTarget.start(pair.call_id)
    after
      if is_nil(Process.whereis(coordinator_name)),
        do: Process.register(coordinator, coordinator_name)
    end

    assert_receive {:winning_startup, target, generation}

    assert {:ok, %{call_id: call_id, runtime_generation: runtime_generation}} =
             DirectCallTarget.identity(target)

    assert call_id == pair.call_id

    assert {:error, :in_use} =
             AdmissionCoordinator.begin_call_target_start_cleanup(call_id, runtime_generation)

    assert :ok = AdmissionCoordinator.call_target_start_cancelled(call_id, runtime_generation)
    assert %{status: :ready} = AdmissionCoordinator.call_target_snapshot(call_id)
    assert {:ok, ^generation} = AdmissionCoordinator.reservation_generation(call_id)
    assert :ok = AdmissionCoordinator.release_reservation(call_id, generation)
  end

  test "startup retirement is bounded and retains ownership while its supervisor is blocked" do
    pair = ringing_pair_in_voice("cleanup_budget")
    parent = self()
    supervisor = DiscordClone.Media.DirectCallTargetSupervisor

    Application.put_env(:discord_clone, :call_target_startup_control, %{
      barrier: fn
        :started, %{target: target} ->
          :ok = :sys.suspend(supervisor)
          send(parent, {:blocked_retirement, target})
          {:error, :unavailable}

        _stage, _context ->
          :ok
      end
    })

    tasks = start_supervised!(Task.Supervisor)

    accept =
      Task.Supervisor.async_nolink(tasks, fn ->
        Calls.accept_call(pair.recipient, pair.call_id, :audio)
      end)

    assert_receive {:blocked_retirement, target}
    monitor = Process.monitor(target)

    try do
      assert {:ok, {:error, :temporarily_unavailable}} = Task.yield(accept, 7_000)
      assert {:ok, %{state: :ringing}} = Calls.get_call(pair.recipient, pair.call_id)

      assert %{status: :startup_cleaning} =
               AdmissionCoordinator.call_target_snapshot(pair.call_id)

      assert {:error, :temporarily_unavailable} =
               Calls.accept_call(pair.recipient, pair.call_id, :audio)

      assert AdmissionCoordinator.current_identity(pair.caller.user.id) == pair.caller_prior
      assert AdmissionCoordinator.current_identity(pair.recipient.user.id) == pair.recipient_prior
    after
      :ok = :sys.resume(supervisor)
      Task.shutdown(accept, :brutal_kill)
    end

    assert_receive {:DOWN, ^monitor, :process, ^target, _reason}, 2_000
    Application.delete_env(:discord_clone, :call_target_startup_control)
    assert_ringing_and_voices(pair)
    assert {:ok, %{state: :connecting}} = Calls.accept_call(pair.recipient, pair.call_id, :audio)
    assert eventually_active?(pair.call_id)
    assert length(running_targets()) == 1
  end

  defp ringing_pair_in_voice(suffix) do
    {caller, recipient, conversation, _friendship} = direct_conversation_fixture(suffix)

    for scope <- [caller, recipient] do
      assert {:ok, _} = Voice.join(Ecto.UUID.generate(), scope.user.id, suffix, self())
      assert :ok = Calls.subscribe(scope)
    end

    assert {:ok, %{call: ringing}} = Calls.start_call(caller, conversation.id, :audio)
    call_id = ringing.call_id
    assert_receive {:call_ringing, %{call_id: ^call_id}}
    assert_receive {:call_ringing, %{call_id: ^call_id}}

    %{
      caller: caller,
      recipient: recipient,
      call_id: call_id,
      caller_prior: AdmissionCoordinator.current_identity(caller.user.id),
      recipient_prior: AdmissionCoordinator.current_identity(recipient.user.id)
    }
  end

  defp assert_ringing_and_voices(pair) do
    call_id = pair.call_id
    assert {:ok, %{state: :ringing}} = Calls.get_call(pair.recipient, call_id)
    refute_received {:call_connecting, %{call_id: ^call_id}}
    refute_received {:call_failed, %{call_id: ^call_id}}
    assert AdmissionCoordinator.current_identity(pair.caller.user.id) == pair.caller_prior
    assert AdmissionCoordinator.current_identity(pair.recipient.user.id) == pair.recipient_prior
    assert {:error, :not_found} = AdmissionCoordinator.reservation_generation(call_id)
    assert AdmissionCoordinator.call_target_snapshot(call_id) == nil
    assert running_targets() == []
  end

  defp running_targets do
    DiscordClone.Media.DirectCallTargetSupervisor
    |> DynamicSupervisor.which_children()
    |> Enum.map(fn {_, pid, _, _} -> pid end)
  end
end
