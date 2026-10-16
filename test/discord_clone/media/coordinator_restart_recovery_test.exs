defmodule DiscordClone.Media.CoordinatorRestartRecoveryTest do
  @moduledoc false
  use DiscordClone.DataCase, async: false

  import DiscordClone.CallsFixtures

  alias DiscordClone.Calls
  alias DiscordClone.Calls.CallAttempt
  alias DiscordClone.Media.AdmissionCoordinator
  alias DiscordClone.Media.DirectCallTarget
  alias DiscordClone.Media.Target
  alias DiscordClone.MediaFixtures
  alias DiscordClone.Repo
  alias DiscordClone.Voice

  setup do
    start_supervised!(DiscordClone.Calls.Supervisor)
    DiscordClone.Calls.CallCoordinator.begin_recovery()
    await_recovery_finished()

    previous_runtime = Application.get_env(:discord_clone, :accepted_call_runtime)
    previous_result = Application.get_env(:discord_clone, :accepted_call_runtime_result)
    previous_startup_control = Application.get_env(:discord_clone, :call_target_startup_control)

    Application.put_env(
      :discord_clone,
      :accepted_call_runtime,
      DiscordClone.Calls.PairAdmissionRuntime
    )

    Application.delete_env(:discord_clone, :accepted_call_runtime_result)

    on_exit(fn ->
      Application.delete_env(:discord_clone, :recovery_settlement_barrier)
      Application.delete_env(:discord_clone, :pair_commit_fault)
      Application.delete_env(:discord_clone, :pair_accept_between_reserve_and_commit)
      Application.delete_env(:discord_clone, :voice_switch_fault)

      if is_nil(previous_startup_control) do
        Application.delete_env(:discord_clone, :call_target_startup_control)
      else
        Application.put_env(
          :discord_clone,
          :call_target_startup_control,
          previous_startup_control
        )
      end

      if is_nil(previous_runtime) do
        Application.delete_env(:discord_clone, :accepted_call_runtime)
      else
        Application.put_env(:discord_clone, :accepted_call_runtime, previous_runtime)
      end

      if is_nil(previous_result) do
        Application.delete_env(:discord_clone, :accepted_call_runtime_result)
      else
        Application.put_env(:discord_clone, :accepted_call_runtime_result, previous_result)
      end
    end)

    on_exit(&MediaFixtures.reset_coordinator_pair_state!/0)

    on_exit(fn ->
      Voice.running_room_servers()
      |> Enum.each(fn {voice_channel_id, _room_server} ->
        :ok = Voice.end_channel_sessions(voice_channel_id)
        :ok = Voice.expire_idle_room(voice_channel_id)
      end)
    end)

    :ok
  end

  describe "fail-closed Voice Channel restart" do
    test "idle restart rejects Voice joins, pair admissions and switch reserves until ready" do
      old_room = Ecto.UUID.generate()
      new_room = Ecto.UUID.generate()
      user_id = Ecto.UUID.generate()

      assert {:ok, %{voice_session_id: _}} =
               Voice.join(old_room, user_id, "before-restart", self())

      # Real ringing pair so `reserve_pair/3` preflight reaches the
      # coordinator (random IDs would fail preflight with `:not_found`
      # before the recovery gate).
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("restart_idle")

      assert {:ok, %{call: ringing}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      _idle_target =
        MediaFixtures.start_ready_call_target(ringing.call_id)

      {^old_room, room_server} =
        Enum.find(Voice.running_room_servers(), fn {id, _} -> id == old_room end)

      room_monitor = Process.monitor(room_server)
      coordinator = Process.whereis(DiscordClone.Voice.SessionCoordinator)
      coordinator_monitor = Process.monitor(coordinator)

      :ok = :sys.suspend(room_server)

      try do
        assert :ok = Voice.crash_session_coordinator()
        assert_receive {:DOWN, ^coordinator_monitor, :process, ^coordinator, :killed}

        # Fail closed during recovery for every admission entry.
        assert {:error, :recovering} =
                 Voice.join(new_room, Ecto.UUID.generate(), "during-recovery", self())

        assert {:error, :recovering} =
                 AdmissionCoordinator.reserve_pair(
                   ringing.call_id,
                   {caller_scope.user.id, nil},
                   {recipient_scope.user.id, nil}
                 )

        assert {:error, :recovering} =
                 GenServer.call(
                   DiscordClone.Voice.SessionCoordinator,
                   {:begin_voice_switch, Ecto.UUID.generate(), Ecto.UUID.generate()}
                 )

        assert {:error, :recovering} =
                 GenServer.call(
                   DiscordClone.Voice.SessionCoordinator,
                   {:reserve_pair, Ecto.UUID.generate(), {Ecto.UUID.generate(), nil},
                    {Ecto.UUID.generate(), nil}}
                 )

        refute Voice.room_running?(new_room)
      after
        :ok = :sys.resume(room_server)
      end

      assert_receive {:DOWN, ^room_monitor, :process, ^room_server, _reason}
      assert :ok = await_coordinator_recovery()
      refute Voice.room_running?(old_room)

      # Exact slot accounting after recovery: empty map, new joins admit.
      coordinator_state = :sys.get_state(DiscordClone.Voice.SessionCoordinator)
      assert coordinator_state.reservation == nil
      assert coordinator_state.active_call == nil
      assert coordinator_state.voice_switches == %{}
      assert coordinator_state.call_targets == %{}
      assert coordinator_state.active_by_user == %{}

      assert {:ok, %{occupancy: 1, capacity: 5}} =
               Voice.join(new_room, user_id, "after-recovery", self())
    end

    test "await_ready preserves waiter semantics across restart" do
      room = Ecto.UUID.generate()

      assert {:ok, _} = Voice.join(room, Ecto.UUID.generate(), "waiter-fill", self())

      {^room, room_server} =
        Enum.find(Voice.running_room_servers(), fn {id, _} -> id == room end)

      :ok = :sys.suspend(room_server)

      coordinator = Process.whereis(DiscordClone.Voice.SessionCoordinator)
      coordinator_monitor = Process.monitor(coordinator)
      test_pid = self()

      try do
        assert :ok = Voice.crash_session_coordinator()
        assert_receive {:DOWN, ^coordinator_monitor, :process, ^coordinator, :killed}

        # Wait for the new coordinator to register before spawning an
        # unlinked waiter; otherwise `await_ready` would exit with noproc.
        _ = await_coordinator_process()

        # Unlinked waiter so a restart race cannot take down the test via link.
        _waiter =
          spawn(fn ->
            result =
              try do
                AdmissionCoordinator.await_ready()
              catch
                :exit, reason -> {:exit, reason}
              end

            send(test_pid, {:waiter_ready, result})
          end)

        # Still recovering while the surviving room is suspended.
        assert {:error, :recovering} =
                 Voice.join(Ecto.UUID.generate(), Ecto.UUID.generate(), "waiter-check", self())

        :ok = :sys.resume(room_server)
        assert_receive {:waiter_ready, :ok}, 5_000
      after
        try do
          :ok = :sys.resume(room_server)
        catch
          :exit, _ -> :ok
        end
      end

      assert :ok = await_coordinator_recovery()
    end
  end

  describe "fail-closed Direct Call restart" do
    test "a queued target shutdown callback completes while recovery discovers its identity" do
      {caller, call_id, target} = recovery_attempt(:active)
      target_monitor = Process.monitor(target)

      {DiscordClone.Media.DirectCallTargetServer, server, _, _} =
        target
        |> Supervisor.which_children()
        |> List.keyfind(DiscordClone.Media.DirectCallTargetServer, 0)

      tasks = start_supervised!(Task.Supervisor)
      settlement_barrier()
      :ok = :sys.suspend(server)

      callback = Task.Supervisor.async_nolink(tasks, fn -> GenServer.call(server, :shutdown) end)
      await_queued_shutdown(server)

      try do
        restart_coordinator!()
        :ok = :sys.resume(server)

        # The queued shutdown calls the newly registered coordinator before
        # the target can answer discovery. It must finish before identity's
        # five-second timeout, while admission still waits for settlement.
        assert {:ok, :ok} = Task.yield(callback, 1_000)
        assert_receive {:settlement_attempt, worker, ^call_id}, 2_000
        assert_receive {:DOWN, ^target_monitor, :process, ^target, _reason}, 2_000

        assert {:error, :recovering} =
                 Voice.join(Ecto.UUID.generate(), Ecto.UUID.generate(), "discovering", self())

        assert {:ok, %{state: :active}} = Calls.get_call(caller, call_id)

        send(worker, :settle)
        assert :ok = AdmissionCoordinator.await_ready()

        assert {:ok, %{state: :terminal, terminal_outcome: :interrupted}} =
                 Calls.get_call(caller, call_id)
      after
        try do
          :sys.resume(server)
        catch
          :exit, _ -> :ok
        end

        Task.shutdown(callback, :brutal_kill)
      end
    end

    test "an unknown target identity cannot open admission even after the target is gone" do
      {caller, call_id, target} = recovery_attempt(:active)
      target_monitor = Process.monitor(target)

      {DiscordClone.Media.DirectCallTargetServer, server, _, _} =
        target
        |> Supervisor.which_children()
        |> List.keyfind(DiscordClone.Media.DirectCallTargetServer, 0)

      # Ticket 20's approved identity timeout only shortens the default budget.
      Application.put_env(:discord_clone, :call_target_startup_control, %{identity_timeout_ms: 50})

      :ok = :sys.suspend(server)

      try do
        restart_coordinator!()
        await_queued_command(server, :identity)
        Process.exit(target, :kill)
        assert_receive {:DOWN, ^target_monitor, :process, ^target, :killed}
        assert {:error, :recovery_timeout} = AdmissionCoordinator.await_ready()
      after
        try do
          :sys.resume(server)
        catch
          :exit, _ -> :ok
        end
      end

      Application.delete_env(:discord_clone, :call_target_startup_control)

      # The late identity response and exact target DOWN cannot heal unknown
      # durable settlement, even when there are no remaining target processes.
      assert {:error, :recovery_timeout} = AdmissionCoordinator.await_ready()

      assert {:error, :recovery_timeout} =
               Voice.join(Ecto.UUID.generate(), Ecto.UUID.generate(), "unknown-call", self())

      assert {:ok, %{state: :active, terminal_outcome: nil}} = Calls.get_call(caller, call_id)
    end

    test "blocked target enumeration leaves lifecycle callbacks and rejection available" do
      {caller, call_id, target} = recovery_attempt(:connecting)
      target_monitor = Process.monitor(target)
      assert {:ok, %{runtime_generation: generation}} = DirectCallTarget.identity(target)
      supervisor = DiscordClone.Media.DirectCallTargetSupervisor
      :ok = :sys.suspend(supervisor)

      try do
        restart_coordinator!()
        assert :ok = AdmissionCoordinator.call_target_stopped(call_id, generation)

        assert {:error, :recovering} =
                 Voice.join(Ecto.UUID.generate(), Ecto.UUID.generate(), "enumerating", self())

        assert {:ok, %{state: :connecting}} = Calls.get_call(caller, call_id)
      after
        :ok = :sys.resume(supervisor)
      end

      assert :ok = AdmissionCoordinator.await_ready()
      assert_receive {:DOWN, ^target_monitor, :process, ^target, _reason}

      assert {:ok, %{state: :terminal, terminal_outcome: :interrupted}} =
               Calls.get_call(caller, call_id)
    end

    test "delayed discovery preserves a replacement started by the new coordinator" do
      {caller, call_id, old_target} = recovery_attempt(:active)
      old_monitor = Process.monitor(old_target)
      supervisor = DiscordClone.Media.DirectCallTargetSupervisor
      tasks = start_supervised!(Task.Supervisor)
      settlement_barrier()
      :ok = :sys.suspend(supervisor)

      # Queue startup ahead of discovery, but let its claim/readiness callbacks
      # run against the replacement coordinator once enumeration is unblocked.
      startup = Task.Supervisor.async_nolink(tasks, fn -> DirectCallTarget.start(call_id) end)

      try do
        await_queued_command(supervisor, :start_child)
        restart_coordinator!()
        await_queued_command(supervisor, :which_children)
      after
        :ok = :sys.resume(supervisor)
      end

      assert {:ok, replacement} = Task.await(startup)
      assert_receive {:settlement_attempt, worker, ^call_id}, 2_000
      assert_receive {:DOWN, ^old_monitor, :process, ^old_target, _reason}, 2_000
      assert {:ok, identity} = DirectCallTarget.identity(replacement)
      send(worker, :settle)

      assert :ok = AdmissionCoordinator.await_ready()
      assert {:ok, ^identity} = DirectCallTarget.identity(replacement)

      assert %{runtime_generation: generation, status: :ready} =
               AdmissionCoordinator.call_target_snapshot(call_id)

      assert generation == identity.runtime_generation

      assert {:ok, %{state: :terminal, terminal_outcome: :interrupted}} =
               Calls.get_call(caller, call_id)
    end

    test "discovery expiry stays failed after a late identity response and target retirement" do
      {caller, call_id, target} = recovery_attempt(:active)
      target_monitor = Process.monitor(target)

      {DiscordClone.Media.DirectCallTargetServer, server, _, _} =
        target
        |> Supervisor.which_children()
        |> List.keyfind(DiscordClone.Media.DirectCallTargetServer, 0)

      :ok = :sys.suspend(server)

      try do
        restart_coordinator!()
        await_queued_command(server, :identity)
        assert :ok = AdmissionCoordinator.call_target_stopped(call_id, make_ref())

        assert {:error, :recovering} =
                 Voice.join(Ecto.UUID.generate(), Ecto.UUID.generate(), "discovery-wait", self())

        assert {:error, :recovery_timeout} = AdmissionCoordinator.await_ready()
      after
        :ok = :sys.resume(server)
      end

      assert {:ok, %{call_id: ^call_id}} = DirectCallTarget.identity(target)
      assert :ok = DirectCallTarget.shutdown(target)
      assert_receive {:DOWN, ^target_monitor, :process, ^target, _reason}
      assert {:error, :recovery_timeout} = AdmissionCoordinator.await_ready()
      assert {:ok, %{state: :active, terminal_outcome: nil}} = Calls.get_call(caller, call_id)
    end

    test "DB failure after teardown keeps admission closed until durable interruption succeeds" do
      {caller, call_id, target} = recovery_attempt(:active)
      target_monitor = Process.monitor(target)
      settlement_barrier()
      restart_coordinator!()

      assert_receive {:settlement_attempt, worker, ^call_id}, 2_000
      assert_receive {:DOWN, ^target_monitor, :process, ^target, _reason}, 2_000
      send(worker, :fail_settlement)
      assert_receive {:settlement_database_failure, ^worker}, 2_000

      assert {:error, reason} =
               Voice.join(Ecto.UUID.generate(), Ecto.UUID.generate(), "unsettled", self())

      assert reason in [:recovering, :recovery_timeout]
      assert {:ok, %{state: :active, terminal_outcome: nil}} = Calls.get_call(caller, call_id)

      assert_receive {:settlement_attempt, retry_worker, ^call_id}, 2_000
      send(retry_worker, :settle)
      assert :ok = AdmissionCoordinator.await_ready()

      assert {:ok, %{state: :terminal, terminal_outcome: :interrupted}} =
               Calls.get_call(caller, call_id)

      assert {:ok, _} =
               Voice.join(Ecto.UUID.generate(), Ecto.UUID.generate(), "settled", self())
    end

    test "readiness waits for every active and connecting attempt, including an existing waiter" do
      first = recovery_attempt(:active)
      second = recovery_attempt(:connecting)
      attempts = Map.new([first, second], fn {scope, id, _target} -> {id, scope} end)
      settlement_barrier()
      restart_coordinator!()

      assert_receive {:settlement_attempt, worker, first_id}, 2_000
      send(worker, :fail_settlement)
      assert_receive {:settlement_database_failure, ^worker}, 2_000
      assert_receive {:settlement_attempt, ^worker, second_id}, 2_000
      assert first_id != second_id
      send(worker, :fail_settlement)
      assert_receive {:settlement_database_failure, ^worker}, 2_000

      supervisor = start_supervised!(Task.Supervisor)
      waiter = Task.Supervisor.async_nolink(supervisor, &AdmissionCoordinator.await_ready/0)

      assert_receive {:settlement_attempt, ^worker, ^first_id}, 2_000
      send(worker, :settle)
      assert_receive {:settlement_attempt, ^worker, ^second_id}, 2_000

      assert {:ok, %{state: :terminal, terminal_outcome: :interrupted}} =
               Calls.get_call(Map.fetch!(attempts, first_id), first_id)

      assert {:ok, %{state: state, terminal_outcome: nil}} =
               Calls.get_call(Map.fetch!(attempts, second_id), second_id)

      assert state in [:active, :connecting]

      assert {:error, :recovering} =
               Voice.join(Ecto.UUID.generate(), Ecto.UUID.generate(), "partially-settled", self())

      send(worker, :settle)
      assert :ok = Task.await(waiter, 2_000)

      for {id, scope} <- attempts do
        assert {:ok, %{state: :terminal, terminal_outcome: :interrupted}} =
                 Calls.get_call(scope, id)
      end
    end

    test "settlement worker death fails closed even after every old runtime is gone" do
      {caller, call_id, target} = recovery_attempt(:connecting)
      target_monitor = Process.monitor(target)
      settlement_barrier()
      restart_coordinator!()

      assert_receive {:settlement_attempt, worker, ^call_id}, 2_000
      assert_receive {:DOWN, ^target_monitor, :process, ^target, _reason}, 2_000
      worker_monitor = Process.monitor(worker)
      Process.exit(worker, :kill)
      assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}, 2_000

      assert {:error, :recovery_timeout} = AdmissionCoordinator.await_ready()

      assert {:error, :recovery_timeout} =
               Voice.join(Ecto.UUID.generate(), Ecto.UUID.generate(), "worker-dead", self())

      assert {:ok, %{state: :connecting, terminal_outcome: nil}} = Calls.get_call(caller, call_id)

      # An empty runtime set and later runtime callbacks cannot autoheal failure.
      fresh_room = Ecto.UUID.generate()
      assert :ok = Voice.ensure_room(fresh_room)

      {^fresh_room, room_server} =
        Enum.find(Voice.running_room_servers(), fn {id, _pid} -> id == fresh_room end)

      AdmissionCoordinator.room_server_started(fresh_room, room_server)
      assert {:error, :recovery_timeout} = AdmissionCoordinator.await_ready()
    end

    test "exhausted recovery budget kills blocked settlement and latches admission closed" do
      {caller, call_id, _target} = recovery_attempt(:active)
      settlement_barrier()
      restart_coordinator!()

      assert_receive {:settlement_attempt, worker, ^call_id}, 2_000
      worker_monitor = Process.monitor(worker)
      supervisor = start_supervised!(Task.Supervisor)
      waiter = Task.Supervisor.async_nolink(supervisor, &AdmissionCoordinator.await_ready/0)

      assert {:error, :recovery_timeout} = Task.await(waiter, 6_000)
      assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}, 2_000
      assert {:ok, %{state: :active, terminal_outcome: nil}} = Calls.get_call(caller, call_id)

      assert {:error, :recovery_timeout} =
               Voice.join(Ecto.UUID.generate(), Ecto.UUID.generate(), "budget-exhausted", self())

      assert {:error, :recovery_timeout} = AdmissionCoordinator.await_ready()
    end

    test "persistent DB failures exhaust the recovery budget without admitting new media" do
      {caller, call_id, _target} = recovery_attempt(:connecting)
      settlement_barrier(:always_fail)
      restart_coordinator!()

      assert_receive {:settlement_attempt, worker, ^call_id}, 2_000
      worker_monitor = Process.monitor(worker)
      assert_receive {:settlement_database_failure, ^worker}, 2_000
      assert_receive {:settlement_database_failure, ^worker}, 2_000

      assert {:error, :recovering} =
               Voice.join(Ecto.UUID.generate(), Ecto.UUID.generate(), "db-unavailable", self())

      assert {:error, :recovery_timeout} = AdmissionCoordinator.await_ready()
      assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}, 2_000
      assert {:ok, %{state: :connecting, terminal_outcome: nil}} = Calls.get_call(caller, call_id)

      assert {:error, :recovery_timeout} =
               Voice.join(Ecto.UUID.generate(), Ecto.UUID.generate(), "db-exhausted", self())
    end

    test "settlement of an old Call does not retire a replacement target generation" do
      {caller, call_id, _target} = recovery_attempt(:active)
      settlement_barrier()
      restart_coordinator!()

      assert_receive {:settlement_attempt, worker, ^call_id}, 2_000
      replacement = start_production_target(call_id)
      assert {:ok, replacement_identity} = DirectCallTarget.identity(replacement)
      send(worker, :settle)

      assert :ok = AdmissionCoordinator.await_ready()

      assert {:ok, %{state: :terminal, terminal_outcome: :interrupted}} =
               Calls.get_call(caller, call_id)

      assert {:ok, ^replacement_identity} = DirectCallTarget.identity(replacement)

      assert %{runtime_generation: generation, status: :ready} =
               AdmissionCoordinator.call_target_snapshot(call_id)

      assert generation == replacement_identity.runtime_generation
    end

    test "terminal winners remain unchanged when delayed recovery settles and a target is replaced" do
      for {state, outcome} <- [active: :ended, connecting: :cancelled] do
        {caller, call_id, _target} = recovery_attempt(state)
        assert :ok = Calls.subscribe(caller)
        settlement_barrier()
        restart_coordinator!()
        assert_receive {:settlement_attempt, worker, ^call_id}, 2_000

        assert {:ok, %{terminal_outcome: ^outcome} = winner} = Calls.leave_call(caller, call_id)
        replacement = start_production_target(call_id)
        assert {:ok, replacement_identity} = DirectCallTarget.identity(replacement)
        send(worker, :settle)

        assert :ok = AdmissionCoordinator.await_ready()
        assert {:ok, ^winner} = Calls.get_call(caller, call_id)
        assert {:ok, ^replacement_identity} = DirectCallTarget.identity(replacement)
        refute_receive {:call_interrupted, %{call_id: ^call_id}}

        :ok = DirectCallTarget.shutdown(replacement)
      end
    end

    test "reservation held at crash cannot commit after restart and ringing is preserved" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("restart_resv")

      assert {:ok, %{call: ringing}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      call_id = ringing.call_id
      caller_id = caller_scope.user.id
      recipient_id = recipient_scope.user.id

      _target = start_production_target(call_id)
      _ = :sys.get_state(DiscordClone.Voice.SessionCoordinator)

      assert {:ok, %{generation: generation}} =
               AdmissionCoordinator.reserve_pair(call_id, {caller_id, nil}, {recipient_id, nil})

      _ = :sys.get_state(DiscordClone.Voice.SessionCoordinator)

      coordinator = Process.whereis(DiscordClone.Voice.SessionCoordinator)
      monitor = Process.monitor(coordinator)
      assert :ok = Voice.crash_session_coordinator()
      assert_receive {:DOWN, ^monitor, :process, ^coordinator, :killed}
      assert :ok = await_coordinator_recovery()

      # In-flight reservation from the crashed epoch cannot publish.
      assert {:error, :stale_reservation} =
               AdmissionCoordinator.release_reservation(call_id, generation)

      assert {:error, :not_found} = AdmissionCoordinator.reservation_generation(call_id)

      # Slots and pins released during reconciliation.
      coordinator_state = :sys.get_state(DiscordClone.Voice.SessionCoordinator)
      assert coordinator_state.reservation == nil
      assert coordinator_state.active_call == nil
      assert coordinator_state.call_targets == %{}
      assert AdmissionCoordinator.current_identity(caller_id) == nil
      assert AdmissionCoordinator.current_identity(recipient_id) == nil
      assert AdmissionCoordinator.call_target_snapshot(call_id) == nil

      # Ringing (no media yet) is preserved, never interrupted or failed.
      assert %CallAttempt{state: :ringing} = Repo.get!(CallAttempt, call_id)
      assert missed_call_activity_items(recipient_id, call_id) == []

      # Fresh reservation can proceed after recovery.
      _fresh_target = start_production_target(call_id)

      assert {:ok, _} =
               AdmissionCoordinator.reserve_pair(call_id, {caller_id, nil}, {recipient_id, nil})
    end

    test "mid-commit crash cannot publish and releases both slots" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("restart_mid")

      assert {:ok, %{call: ringing}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      call_id = ringing.call_id
      caller_id = caller_scope.user.id
      recipient_id = recipient_scope.user.id

      _target = start_production_target(call_id)

      assert {:ok, %{generation: generation}} =
               AdmissionCoordinator.reserve_pair(call_id, {caller_id, nil}, {recipient_id, nil})

      # Move to committing phase (begin_pair_commit) then crash before publish.
      assert {:ok, _plan} =
               GenServer.call(
                 DiscordClone.Voice.SessionCoordinator,
                 {:begin_pair_commit, call_id, generation}
               )

      coordinator = Process.whereis(DiscordClone.Voice.SessionCoordinator)
      monitor = Process.monitor(coordinator)
      assert :ok = Voice.crash_session_coordinator()
      assert_receive {:DOWN, ^monitor, :process, ^coordinator, :killed}
      assert :ok = await_coordinator_recovery()

      # Old generation stays stale; no half-pair exposed.
      assert {:error, :not_found} = AdmissionCoordinator.reservation_generation(call_id)
      assert AdmissionCoordinator.current_identity(caller_id) == nil
      assert AdmissionCoordinator.current_identity(recipient_id) == nil
      assert AdmissionCoordinator.call_target_snapshot(call_id) == nil

      coordinator_state = :sys.get_state(DiscordClone.Voice.SessionCoordinator)
      assert coordinator_state.reservation == nil
      assert coordinator_state.active_call == nil

      # Durable still ringing (never committed connecting without publish).
      assert %CallAttempt{state: :ringing} = Repo.get!(CallAttempt, call_id)
    end

    test "active pair restart retires surviving target and settles interrupted" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("restart_act")

      assert :ok = Calls.subscribe(caller_scope)
      assert :ok = Calls.subscribe(recipient_scope)

      assert {:ok, %{call: ringing}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      call_id = ringing.call_id
      caller_id = caller_scope.user.id
      recipient_id = recipient_scope.user.id

      assert {:ok, _} = Calls.accept_call(recipient_scope, call_id, :audio)
      assert eventually_active?(call_id)

      assert %{target: %Target{kind: :direct_call, id: ^call_id}} =
               AdmissionCoordinator.current_identity(caller_id)

      coordinator = Process.whereis(DiscordClone.Voice.SessionCoordinator)
      monitor = Process.monitor(coordinator)
      assert :ok = Voice.crash_session_coordinator()
      assert_receive {:DOWN, ^monitor, :process, ^coordinator, :killed}
      assert :ok = await_coordinator_recovery()

      # Surviving target retired under exact identity before ready.
      assert AdmissionCoordinator.call_target_snapshot(call_id) == nil
      assert AdmissionCoordinator.current_identity(caller_id) == nil
      assert AdmissionCoordinator.current_identity(recipient_id) == nil
      assert_no_call_sessions(call_id)

      coordinator_state = :sys.get_state(DiscordClone.Voice.SessionCoordinator)
      assert coordinator_state.reservation == nil
      assert coordinator_state.active_call == nil
      assert coordinator_state.voice_switches == %{}

      # Affected active Call settles interrupted (durable terminal via the
      # existing funnel which broadcasts `:call_interrupted` to both Users;
      # broadcast timing is covered by the funnel tests, here we assert the
      # durable outcome, no missed item, no resume, and exact slots).
      assert eventually_terminal?(call_id, :interrupted)

      assert %CallAttempt{state: :terminal, terminal_outcome: :interrupted} =
               Repo.get!(CallAttempt, call_id)

      assert missed_call_activity_items(recipient_id, call_id) == []

      # Exact slot accounting: new Voice joins admit after recovery.
      assert {:ok, _} =
               Voice.join(Ecto.UUID.generate(), Ecto.UUID.generate(), "after-restart", self())
    end

    test "switch reserved at crash releases hold and settles interrupted with no half-pair" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("restart_sw")

      assert {:ok, %{call: ringing}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      call_id = ringing.call_id
      caller_id = caller_scope.user.id
      recipient_id = recipient_scope.user.id
      coordinator_name = DiscordClone.Voice.SessionCoordinator
      destination = Ecto.UUID.generate()

      assert {:ok, _} = Calls.accept_call(recipient_scope, call_id, :audio)
      assert eventually_active?(call_id)

      assert {:ok, %{generation: generation}} =
               AdmissionCoordinator.begin_voice_switch(caller_id, destination)

      _ = :sys.get_state(coordinator_name)

      coordinator = Process.whereis(coordinator_name)
      monitor = Process.monitor(coordinator)
      assert :ok = Voice.crash_session_coordinator()
      assert_receive {:DOWN, ^monitor, :process, ^coordinator, :killed}
      assert :ok = await_coordinator_recovery()

      # Held switch from the crashed epoch cannot publish; slots released.
      assert {:error, :stale_switch} =
               GenServer.call(
                 coordinator_name,
                 {:publish_voice_switch, caller_id, generation, destination, "sig",
                  %{voice_session_id: Ecto.UUID.generate()}, self()}
               )

      coordinator_state = :sys.get_state(coordinator_name)
      assert coordinator_state.voice_switches == %{}
      assert coordinator_state.active_call == nil
      assert AdmissionCoordinator.current_identity(caller_id) == nil
      assert AdmissionCoordinator.current_identity(recipient_id) == nil
      assert_no_call_sessions(call_id)

      # Active Call settles interrupted, never resumed, no half-pair.
      assert eventually_terminal?(call_id, :interrupted)

      assert %CallAttempt{state: :terminal, terminal_outcome: :interrupted} =
               Repo.get!(CallAttempt, call_id)

      assert missed_call_activity_items(recipient_id, call_id) == []
    end
  end

  defp recovery_attempt(state) do
    {caller, recipient, conversation, _friendship} =
      direct_conversation_fixture("settlement_#{System.unique_integer([:positive])}")

    attempt =
      MediaFixtures.insert_attempt!(conversation.id, caller.user.id, recipient.user.id, :ringing)

    attempt = MediaFixtures.set_attempt_connecting!(attempt.id)

    attempt =
      if state == :active do
        attempt |> CallAttempt.activate_changeset() |> Repo.update!()
      else
        attempt
      end

    {caller, attempt.id, start_production_target(attempt.id)}
  end

  defp await_queued_shutdown(server), do: await_queued_command(server, :shutdown)

  defp await_queued_command(server, command, deadline \\ nil) do
    server = if is_atom(server), do: Process.whereis(server), else: server
    deadline = deadline || System.monotonic_time(:millisecond) + 2_000
    {:messages, messages} = Process.info(server, :messages)

    queued? =
      Enum.any?(messages, fn
        {:"$gen_call", _, queued} when is_tuple(queued) -> elem(queued, 0) == command
        {:"$gen_call", _, queued} -> queued == command
        _ -> false
      end)

    if queued? do
      :ok
    else
      if System.monotonic_time(:millisecond) < deadline do
        :erlang.yield()
        await_queued_command(server, command, deadline)
      else
        flunk("target command was not queued: #{command}")
      end
    end
  end

  defp settlement_barrier(mode \\ :controlled) do
    parent = self()

    Application.put_env(:discord_clone, :recovery_settlement_barrier, fn call_id ->
      send(parent, {:settlement_attempt, self(), call_id})

      action =
        if mode == :always_fail do
          :fail_settlement
        else
          receive do
            :fail_settlement -> :fail_settlement
            :settle -> :settle
          end
        end

      case action do
        :fail_settlement ->
          try do
            # A budget-expired worker may die mid-query. Keep artificial DB faults
            # on its own connection so that kill cannot discard the fixture transaction.
            Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
              Repo.query!("SELECT 1 / 0")
            end)
          rescue
            error in Postgrex.Error ->
              send(parent, {:settlement_database_failure, self()})
              reraise error, __STACKTRACE__
          end

        :settle ->
          :ok
      end
    end)
  end

  defp restart_coordinator! do
    coordinator = Process.whereis(DiscordClone.Voice.SessionCoordinator)
    monitor = Process.monitor(coordinator)
    assert :ok = Voice.crash_session_coordinator()
    assert_receive {:DOWN, ^monitor, :process, ^coordinator, :killed}
    replacement = await_coordinator_process()

    on_exit(fn ->
      Application.delete_env(:discord_clone, :recovery_settlement_barrier)
      state = :sys.get_state(DiscordClone.Voice.SessionCoordinator)

      if state.recovery_status != :ready do
        if state.recovery_worker, do: Process.exit(state.recovery_worker.pid, :kill)
        :ok = Voice.crash_session_coordinator()
        assert :ok = await_coordinator_recovery()
      end
    end)

    replacement
  end

  # Production-path fake target (under the application supervisor) so restart
  # reconciliation discovers and retires it. Test-supervised targets would
  # survive under the test supervisor and collide on a second start.
  defp start_production_target(call_id, timeout_ms \\ 2_000) do
    {:ok, pid} = DirectCallTarget.start(call_id)
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    await_target_identity(pid, deadline)
  end

  defp await_target_identity(pid, deadline) do
    case DirectCallTarget.identity(pid) do
      {:ok, _} ->
        pid

      {:error, _} ->
        if System.monotonic_time(:millisecond) < deadline do
          :erlang.yield()
          await_target_identity(pid, deadline)
        else
          flunk("production Direct Call target did not become ready")
        end
    end
  end

  defp await_coordinator_process do
    deadline = System.monotonic_time(:millisecond) + 5_000
    await_process_until(deadline)
  end

  defp await_process_until(deadline) do
    case Process.whereis(DiscordClone.Voice.SessionCoordinator) do
      nil ->
        if System.monotonic_time(:millisecond) < deadline do
          :erlang.yield()
          await_process_until(deadline)
        else
          flunk("coordinator process did not reappear after crash")
        end

      pid when is_pid(pid) ->
        pid
    end
  end

  # Supervisor restart after `:kill` is asynchronous; `await_ready` exits
  # when no process is registered yet. Poll for the new coordinator before
  # awaiting so crash tests stay deterministic without sleeps.
  defp await_coordinator_recovery(timeout_ms \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    await_coordinator_until(deadline)
  end

  defp await_coordinator_until(deadline) do
    case Process.whereis(DiscordClone.Voice.SessionCoordinator) do
      nil ->
        if System.monotonic_time(:millisecond) < deadline do
          :erlang.yield()
          await_coordinator_until(deadline)
        else
          flunk("coordinator did not restart after crash")
        end

      pid when is_pid(pid) ->
        try do
          GenServer.call(pid, :await_ready, 5_000)
        catch
          :exit, _ ->
            if System.monotonic_time(:millisecond) < deadline do
              :erlang.yield()
              await_coordinator_until(deadline)
            else
              flunk("coordinator did not become ready after restart")
            end
        end
    end
  end
end
