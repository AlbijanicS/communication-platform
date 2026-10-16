defmodule DiscordClone.CallsPairReleaseTest do
  @moduledoc false
  use DiscordClone.DataCase, async: false

  import DiscordClone.CallsFixtures

  alias DiscordClone.Activities.ActivityItem
  alias DiscordClone.Calls
  alias DiscordClone.Calls.CallAttempt
  alias DiscordClone.Chat.Message
  alias DiscordClone.Friendships
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

    Application.put_env(
      :discord_clone,
      :accepted_call_runtime,
      DiscordClone.Calls.PairAdmissionRuntime
    )

    Application.delete_env(:discord_clone, :accepted_call_runtime_result)

    on_exit(fn ->
      Application.delete_env(:discord_clone, :pair_commit_fault)
      Application.delete_env(:discord_clone, :pair_operation_timeouts)
      Application.delete_env(:discord_clone, :pair_accept_between_reserve_and_commit)

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

  describe "leave releases the pair" do
    test "terminal cancellation bounds stalled provisional cleanup while retaining pins and the Call guard" do
      barrier = pause_pair_commit(:before_publish)
      Application.put_env(:discord_clone, :pair_operation_timeouts, %{cleanup_ms: 300})
      {caller, recipient, conversation, _} = direct_conversation_fixture("worker_cancel_budget")
      other = MediaFixtures.ringing_pair_fixture("worker_cancel_other")
      MediaFixtures.start_ready_call_target(other.call_id)
      assert :ok = Calls.subscribe(caller)
      assert {:ok, %{call: ringing}} = Calls.start_call(caller, conversation.id, :audio)
      assert {:ok, %{state: :connecting}} = Calls.accept_call(recipient, ringing.call_id, :audio)
      assert_receive {:pair_commit_paused, ^barrier, worker}
      call_id = ringing.call_id
      target = call_target(call_id)
      monitors = monitor_target_sessions(target)

      {DiscordClone.Media.DirectCallTargetServer, server, _, _} =
        List.keyfind(
          Supervisor.which_children(target),
          DiscordClone.Media.DirectCallTargetServer,
          0
        )

      :ok = :sys.suspend(server)
      worker_monitor = Process.monitor(worker)
      tasks = start_supervised!(Task.Supervisor)
      cancel = Task.Supervisor.async_nolink(tasks, fn -> Calls.cancel_call(caller, call_id) end)

      try do
        assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}, 1_000

        assert {:error, %{reason: :reservation_conflict}} =
                 AdmissionCoordinator.reserve_pair(
                   other.call_id,
                   {other.first_user_id, nil},
                   {other.second_user_id, nil}
                 )

        assert AdmissionCoordinator.effective_occupancy() == 2

        for user <- [caller.user.id, recipient.user.id] do
          assert {:error, %{reason: :reservation_conflict}} =
                   Voice.join(Ecto.UUID.generate(), user, "cleanup-pinned", self())
        end

        unrelated_channel = Ecto.UUID.generate()

        assert {:ok, _} =
                 Voice.join(unrelated_channel, Ecto.UUID.generate(), "cleanup-responsive", self())

        assert {:ok, %{occupancy: 1}} = Voice.room_occupancy(unrelated_channel)
        assert {:ok, %{terminal_outcome: :cancelled}} = Task.await(cancel, 1_500)
        assert_target_sessions_down(monitors)
        assert_receive {:call_cancelled, %{call_id: ^call_id, terminal_outcome: :cancelled}}
        assert {:ok, :terminal} = Calls.complete_accepted_runtime(call_id, :failed, :audio)
        assert {:ok, %{terminal_outcome: :cancelled}} = Calls.get_call(caller, call_id)
        assert AdmissionCoordinator.reservation_count() == 0

        for user <- [caller.user.id, recipient.user.id] do
          assert {:ok, _} =
                   Voice.join(unrelated_channel, user, "cleanup-released-#{user}", self())
        end

        assert {:ok, reservation} =
                 AdmissionCoordinator.reserve_pair(
                   other.call_id,
                   {other.first_user_id, nil},
                   {other.second_user_id, nil}
                 )

        assert :ok =
                 AdmissionCoordinator.release_reservation(other.call_id, reservation.generation)
      after
        try do
          :sys.resume(server)
        catch
          :exit, _ -> :ok
        end
      end
    end

    test "connection deadline settles a stalled worker before retirement and preserves both exact Voices" do
      barrier = pause_pair_commit(:after_begin)
      Application.put_env(:discord_clone, :pair_operation_timeouts, %{connect_ms: 80})
      {caller, recipient, conversation, _} = direct_conversation_fixture("worker_deadline")
      channel = Ecto.UUID.generate()
      assert {:ok, _} = Voice.join(channel, caller.user.id, "deadline-caller", self())
      assert {:ok, _} = Voice.join(channel, recipient.user.id, "deadline-recipient", self())
      caller_prior = AdmissionCoordinator.current_identity(caller.user.id)
      recipient_prior = AdmissionCoordinator.current_identity(recipient.user.id)
      assert :ok = Calls.subscribe(caller)
      assert {:ok, %{call: ringing}} = Calls.start_call(caller, conversation.id, :audio)
      assert {:ok, %{state: :connecting}} = Calls.accept_call(recipient, ringing.call_id, :audio)
      assert_receive {:pair_commit_paused, ^barrier, worker}
      monitor = Process.monitor(worker)

      try do
        assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}, 800
        assert_receive {:call_failed, %{call_id: call_id, terminal_outcome: :failed}}, 1_000
        assert call_id == ringing.call_id
        assert {:ok, %{terminal_outcome: :failed}} = Calls.get_call(caller, call_id)
        assert AdmissionCoordinator.reservation_count() == 0
        assert AdmissionCoordinator.current_identity(caller.user.id) == caller_prior
        assert AdmissionCoordinator.current_identity(recipient.user.id) == recipient_prior
        assert_no_call_sessions(call_id)
      after
        Process.exit(worker, :kill)
      end
    end

    test "worker death before publication retires both provisional Sessions and cannot reopen the old Call" do
      barrier = pause_pair_commit(:before_publish)
      {caller, recipient, conversation, _} = direct_conversation_fixture("worker_provisional")
      channel = Ecto.UUID.generate()
      assert {:ok, _} = Voice.join(channel, caller.user.id, "provisional-caller", self())
      assert {:ok, _} = Voice.join(channel, recipient.user.id, "provisional-recipient", self())
      assert :ok = Calls.subscribe(caller)
      assert {:ok, %{call: ringing}} = Calls.start_call(caller, conversation.id, :audio)
      assert {:ok, %{state: :connecting}} = Calls.accept_call(recipient, ringing.call_id, :audio)
      assert_receive {:pair_commit_paused, ^barrier, worker}, 1_000
      call_id = ringing.call_id
      target = call_target(call_id)
      {:ok, %{runtime_generation: target_generation}} = DirectCallTarget.identity(target)
      %{sessions: sessions} = AdmissionCoordinator.call_target_snapshot(call_id)
      assert map_size(sessions) == 2
      assert AdmissionCoordinator.current_identity(caller.user.id) == nil
      assert AdmissionCoordinator.current_identity(recipient.user.id) == nil
      monitors = monitor_target_sessions(target)
      worker_monitor = Process.monitor(worker)
      Process.exit(worker, :kill)
      assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}
      assert_receive {:call_failed, %{call_id: ^call_id, terminal_outcome: :failed}}, 2_000
      assert_target_sessions_down(monitors)
      assert AdmissionCoordinator.reservation_count() == 0
      assert_no_call_sessions(call_id)
      Application.delete_env(:discord_clone, :pair_commit_fault)
      assert {:ok, %{call: fresh}} = Calls.start_call(caller, conversation.id, :audio)
      assert {:ok, _} = Calls.accept_call(recipient, fresh.call_id, :audio)
      assert eventually_active?(fresh.call_id)
      replacement = AdmissionCoordinator.current_identity(caller.user.id)

      for {session_id, user_id} <- sessions do
        assert :ok =
                 AdmissionCoordinator.call_session_started(
                   call_id,
                   target_generation,
                   user_id,
                   session_id
                 )

        assert :ok =
                 AdmissionCoordinator.call_session_removed(
                   call_id,
                   target_generation,
                   user_id,
                   session_id
                 )

        assert :ok =
                 AdmissionCoordinator.call_session_failed(
                   call_id,
                   target_generation,
                   user_id,
                   session_id,
                   :killed
                 )
      end

      send(worker, {:resume_pair_commit, barrier})

      assert {:error, :stale_runtime} =
               AdmissionCoordinator.call_target_ready(call_id, target_generation, target)

      assert {:ok, :terminal} = Calls.complete_accepted_runtime(call_id, :ready, :audio)
      assert :ok = AdmissionCoordinator.cleanup_active_pair_for_call(call_id)
      assert {:ok, %{terminal_outcome: :failed}} = Calls.get_call(caller, call_id)
      assert AdmissionCoordinator.current_identity(caller.user.id) == replacement
      assert {:ok, _} = Calls.leave_call(caller, fresh.call_id)
    end

    test "worker death after first retirement preserves only the unretired Voice and releases both Users" do
      barrier = pause_pair_commit(:after_first_retirement)
      {caller, recipient, conversation, _} = direct_conversation_fixture("worker_first_retire")
      channel = Ecto.UUID.generate()
      assert {:ok, _} = Voice.join(channel, caller.user.id, "first-prior", self())
      assert {:ok, _} = Voice.join(channel, recipient.user.id, "second-prior", self())
      recipient_prior = AdmissionCoordinator.current_identity(recipient.user.id)
      assert :ok = Calls.subscribe(caller)
      assert {:ok, %{call: ringing}} = Calls.start_call(caller, conversation.id, :audio)
      assert {:ok, %{state: :connecting}} = Calls.accept_call(recipient, ringing.call_id, :audio)
      assert_receive {:pair_commit_paused, ^barrier, worker}, 1_000
      assert AdmissionCoordinator.current_identity(caller.user.id) == nil
      assert AdmissionCoordinator.current_identity(recipient.user.id) == recipient_prior
      assert {:ok, _} = Voice.join(channel, Ecto.UUID.generate(), "unrelated", self())
      monitor = Process.monitor(worker)
      Process.exit(worker, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}
      assert_receive {:call_failed, %{call_id: call_id, terminal_outcome: :failed}}, 2_000
      assert call_id == ringing.call_id
      assert AdmissionCoordinator.reservation_count() == 0
      assert AdmissionCoordinator.current_identity(caller.user.id) == nil
      assert AdmissionCoordinator.current_identity(recipient.user.id) == recipient_prior
      assert_no_call_sessions(call_id)
      Application.delete_env(:discord_clone, :pair_commit_fault)
      assert {:ok, %{call: fresh}} = Calls.start_call(caller, conversation.id, :audio)
      assert {:ok, _} = Calls.accept_call(recipient, fresh.call_id, :audio)
      assert eventually_active?(fresh.call_id)
      assert {:ok, _} = Calls.leave_call(caller, fresh.call_id)
    end

    test "worker death before retirement settles failure and releases the pair without changing Voice" do
      parent = self()
      handler = {__MODULE__, make_ref()}

      :ok =
        :telemetry.attach(
          handler,
          DiscordClone.Media.AdmissionDiagnostics.event(),
          fn
            _event, _measurements, %{operation: "begin_pair_commit", outcome: :accepted}, _ ->
              send(parent, {:commit_worker, self()})

              receive do
                :continue_commit -> :ok
              end

            _, _, _, _ ->
              :ok
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler) end)
      {caller, recipient, conversation, _} = direct_conversation_fixture("worker_death_begin")
      channel = Ecto.UUID.generate()
      assert {:ok, _} = Voice.join(channel, caller.user.id, "worker-prior", self())
      prior = AdmissionCoordinator.current_identity(caller.user.id)
      assert :ok = Calls.subscribe(caller)
      assert {:ok, %{call: ringing}} = Calls.start_call(caller, conversation.id, :audio)
      assert {:ok, %{state: :connecting}} = Calls.accept_call(recipient, ringing.call_id, :audio)
      assert_receive {:commit_worker, worker}
      monitor = Process.monitor(worker)
      Process.exit(worker, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}
      assert_receive {:call_failed, %{call_id: call_id, terminal_outcome: :failed}}, 2_000
      assert call_id == ringing.call_id
      assert AdmissionCoordinator.reservation_count() == 0
      assert AdmissionCoordinator.current_identity(caller.user.id) == prior
      assert_no_call_sessions(call_id)
      assert {:ok, _} = Voice.join(channel, recipient.user.id, "worker-released", self())
      assert {:ok, %{call: fresh}} = Calls.start_call(caller, conversation.id, :audio)
      assert fresh.call_id != call_id
      :telemetry.detach(handler)
      assert {:ok, _} = Calls.accept_call(recipient, fresh.call_id, :audio)
      assert eventually_active?(fresh.call_id)
      assert {:ok, _} = Calls.leave_call(caller, fresh.call_id)
    end

    test "terminal cleanup retains the Call guard and surviving capacity until both sides are gone" do
      {caller, recipient, call_id} = active_failure_pair("rel_cleanup_guard")

      [target] =
        for {_, pid, _, _} <-
              DynamicSupervisor.which_children(DiscordClone.Media.DirectCallTargetSupervisor),
            {:ok, %{call_id: ^call_id}} <- [DirectCallTarget.identity(pid)],
            do: pid

      channels = Enum.map(1..4, fn _ -> Ecto.UUID.generate() end)
      boundary_channel = Ecto.UUID.generate()

      for index <- 1..18 do
        channel = Enum.at(channels, div(index - 1, 5))
        assert {:ok, _} = Voice.join(channel, Ecto.UUID.generate(), "cleanup-#{index}", self())
      end

      other = MediaFixtures.ringing_pair_fixture("cleanup_guard_next")
      MediaFixtures.start_ready_call_target(other.call_id)
      {barrier, resume} = MediaFixtures.pause_after_first_call_removal(target)
      tasks = start_supervised!(Task.Supervisor)
      leave = Task.Supervisor.async_nolink(tasks, fn -> Calls.leave_call(caller, call_id) end)

      try do
        assert_receive {:first_call_session_removed, ^barrier}, 2_000
        assert map_size(AdmissionCoordinator.call_target_snapshot(call_id).sessions) == 1

        assert {:error, %{reason: :reservation_conflict}} =
                 AdmissionCoordinator.reserve_pair(
                   other.call_id,
                   {other.first_user_id, nil},
                   {other.second_user_id, nil}
                 )

        assert AdmissionCoordinator.effective_occupancy() == 19

        assert {:error, %{reason: :reservation_conflict}} =
                 Voice.join(Ecto.UUID.generate(), recipient.user.id, "cleanup-pinned", self())

        assert {:ok, _} = Voice.join(boundary_channel, Ecto.UUID.generate(), "last-slot", self())
        assert AdmissionCoordinator.effective_occupancy() == 20

        assert {:error, %{reason: :deployment_full, occupancy: 20}} =
                 Voice.join(boundary_channel, Ecto.UUID.generate(), "over-cap", self())
      after
        resume.()
      end

      assert {:ok, %{state: :terminal, terminal_outcome: :ended}} = Task.await(leave)
      assert AdmissionCoordinator.effective_occupancy() == 19
      assert AdmissionCoordinator.current_identity(caller.user.id) == nil
      assert AdmissionCoordinator.current_identity(recipient.user.id) == nil
      assert_no_call_sessions(call_id)
      assert {:ok, _} = Voice.join(boundary_channel, recipient.user.id, "released-pin", self())
      assert :ok = Voice.end_channel_sessions(boundary_channel)

      assert {:ok, reservation} =
               AdmissionCoordinator.reserve_pair(
                 other.call_id,
                 {other.first_user_id, nil},
                 {other.second_user_id, nil}
               )

      assert :ok = AdmissionCoordinator.release_reservation(other.call_id, reservation.generation)
    end

    test "either participant leaving a connecting Call cancels for both and releases any pair state" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("rel_leave_conn")

      assert :ok = Calls.subscribe(caller_scope)
      assert :ok = Calls.subscribe(recipient_scope)

      assert {:ok, %{call: ringing}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      assert_receive {:call_ringing, _}
      assert_receive {:call_ringing, _}

      assert {:ok, connecting} = Calls.accept_call(recipient_scope, ringing.call_id, :audio)
      assert connecting.state == :connecting
      assert_receive {:call_connecting, _}
      assert_receive {:call_connecting, _}

      # Leave while connecting commits cancelled without Activity.
      assert {:ok, cancelled} = Calls.leave_call(recipient_scope, ringing.call_id)
      assert cancelled.state == :terminal
      assert cancelled.terminal_outcome == :cancelled

      assert_receive {:call_cancelled, first_cancelled}
      assert first_cancelled.call_id == ringing.call_id
      assert_receive {:call_cancelled, second_cancelled}
      assert second_cancelled.call_id == ringing.call_id

      assert AdmissionCoordinator.current_identity(caller_scope.user.id) == nil
      assert AdmissionCoordinator.current_identity(recipient_scope.user.id) == nil
      assert_no_call_sessions(ringing.call_id)
      assert Repo.get!(CallAttempt, ringing.call_id).terminal_outcome == :cancelled
    end

    test "either participant leaving an active Call removes both Call Sessions and ends for both" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("rel_leave")

      first_channel = Ecto.UUID.generate()
      second_channel = Ecto.UUID.generate()

      assert {:ok, _} = Voice.join(first_channel, caller_scope.user.id, "leave-caller", self())

      assert {:ok, _} =
               Voice.join(second_channel, recipient_scope.user.id, "leave-recipient", self())

      assert :ok = Calls.subscribe(caller_scope)
      assert :ok = Calls.subscribe(recipient_scope)
      messages_before = Repo.aggregate(Message, :count)
      activity_before = Repo.aggregate(ActivityItem, :count)

      assert {:ok, %{call: ringing}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      assert_receive {:call_ringing, _}
      assert_receive {:call_ringing, _}

      assert {:ok, connecting} = Calls.accept_call(recipient_scope, ringing.call_id, :audio)
      assert connecting.state == :connecting
      assert_receive {:call_connecting, _}
      assert_receive {:call_connecting, _}

      assert eventually_active?(ringing.call_id)
      assert_receive {:call_active, _}
      assert_receive {:call_active, _}

      assert AdmissionCoordinator.current_identity(caller_scope.user.id).target ==
               Target.direct_call(ringing.call_id)

      # Either participant leaves an active Call; both sides must go.
      assert {:ok, ended} = Calls.leave_call(caller_scope, ringing.call_id)
      assert ended.state == :terminal
      assert ended.terminal_outcome == :ended

      reloaded = Repo.get!(CallAttempt, ringing.call_id)
      assert reloaded.state == :terminal
      assert reloaded.terminal_outcome == :ended

      # Existing projections reach both Users exactly once.
      assert_receive {:call_completed, first_ended}
      assert first_ended.call_id == ringing.call_id
      assert_receive {:call_completed, second_ended}
      assert second_ended.call_id == ringing.call_id

      # Both exact Call Sessions removed; no Voice restore.
      assert AdmissionCoordinator.current_identity(caller_scope.user.id) == nil
      assert AdmissionCoordinator.current_identity(recipient_scope.user.id) == nil
      assert_no_call_sessions(ringing.call_id)
      assert {:ok, %{occupancy: 0}} = Voice.room_occupancy(first_channel)
      assert {:ok, %{occupancy: 0}} = Voice.room_occupancy(second_channel)

      # Silent terminal: no missed Activity or Message.
      assert Repo.aggregate(ActivityItem, :count) == activity_before
      assert Repo.aggregate(Message, :count) == messages_before

      # Slots freed: a later eligible pair can reserve.
      assert {:error, :not_found} =
               AdmissionCoordinator.reservation_generation(ringing.call_id)

      # Repeated leave returns durable truth and stays cleaned.
      assert {:ok, again} = Calls.leave_call(recipient_scope, ringing.call_id)
      assert again.terminal_outcome == :ended
      assert AdmissionCoordinator.current_identity(caller_scope.user.id) == nil
      assert AdmissionCoordinator.current_identity(recipient_scope.user.id) == nil
    end
  end

  describe "friendship removal releases the pair" do
    test "removal ends an active Call, releases both sides, and blocks new calls" do
      {caller_scope, recipient_scope, direct_conversation, friendship} =
        direct_conversation_fixture("rel_friend_active")

      assert :ok = Calls.subscribe(caller_scope)
      assert :ok = Calls.subscribe(recipient_scope)

      assert {:ok, %{call: ringing}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      assert_receive {:call_ringing, _}
      assert_receive {:call_ringing, _}

      assert {:ok, _connecting} = Calls.accept_call(recipient_scope, ringing.call_id, :audio)
      assert_receive {:call_connecting, _}
      assert_receive {:call_connecting, _}
      assert eventually_active?(ringing.call_id)
      assert_receive {:call_active, _}
      assert_receive {:call_active, _}

      assert AdmissionCoordinator.current_identity(caller_scope.user.id).target ==
               Target.direct_call(ringing.call_id)

      assert :ok = Friendships.remove_friend(recipient_scope, friendship.id)

      assert_receive {:call_relationship_ended, first_ended}
      assert first_ended.call_id == ringing.call_id
      assert_receive {:call_relationship_ended, second_ended}
      assert second_ended.call_id == ringing.call_id

      assert %CallAttempt{state: :terminal, terminal_outcome: :relationship_ended} =
               Repo.get!(CallAttempt, ringing.call_id)

      assert AdmissionCoordinator.current_identity(caller_scope.user.id) == nil
      assert AdmissionCoordinator.current_identity(recipient_scope.user.id) == nil
      assert_no_call_sessions(ringing.call_id)

      # No missed-call Activity for relationship-ended active Calls.
      assert missed_call_activity_items(recipient_scope.user.id, ringing.call_id) == []
      assert missed_call_activity_items(caller_scope.user.id, ringing.call_id) == []

      # Former-Friend conversations cannot start calls.
      assert {:error, :not_found} =
               Calls.get_call(caller_scope, ringing.call_id)

      assert {:error, _} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)
    end

    test "removal ends a ringing Call without media side effects" do
      {caller_scope, recipient_scope, direct_conversation, friendship} =
        direct_conversation_fixture("rel_friend_ring")

      assert {:ok, %{call: ringing}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      assert :ok = Friendships.remove_friend(caller_scope, friendship.id)

      assert %CallAttempt{state: :terminal, terminal_outcome: :relationship_ended} =
               Repo.get!(CallAttempt, ringing.call_id)

      assert AdmissionCoordinator.current_identity(caller_scope.user.id) == nil
      assert AdmissionCoordinator.current_identity(recipient_scope.user.id) == nil
      assert_no_call_sessions(ringing.call_id)
    end

    test "removal ends a connecting Call and releases the pair" do
      {caller_scope, recipient_scope, direct_conversation, friendship} =
        direct_conversation_fixture("rel_friend_conn")

      first_channel = Ecto.UUID.generate()

      assert {:ok, _} = Voice.join(first_channel, caller_scope.user.id, "conn-voice", self())

      assert {:ok, %{call: ringing}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      # Hold admission in-flight so the attempt is still connecting.
      {^first_channel, room_server} =
        Enum.find(Voice.running_room_servers(), fn {id, _} -> id == first_channel end)

      :ok = :sys.suspend(room_server)

      try do
        assert {:ok, _} = Calls.accept_call(recipient_scope, ringing.call_id, :audio)
        assert %CallAttempt{state: :connecting} = Repo.get!(CallAttempt, ringing.call_id)

        assert :ok = Friendships.remove_friend(caller_scope, friendship.id)
      after
        :ok = :sys.resume(room_server)
      end

      deadline = System.monotonic_time(:millisecond) + 5_000

      wait_for_pair_convergence(
        ringing.call_id,
        caller_scope.user.id,
        recipient_scope.user.id,
        deadline
      )

      assert %CallAttempt{state: :terminal, terminal_outcome: :relationship_ended} =
               Repo.get!(CallAttempt, ringing.call_id)

      assert AdmissionCoordinator.current_identity(caller_scope.user.id) == nil
      assert AdmissionCoordinator.current_identity(recipient_scope.user.id) == nil
      assert_no_call_sessions(ringing.call_id)
      assert missed_call_activity_items(recipient_scope.user.id, ringing.call_id) == []
    end
  end

  describe "runtime loss releases the pair" do
    test "CallServer termination interrupts the durable attempt and cleans both sides" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("rel_server_fail")

      assert :ok = Calls.subscribe(caller_scope)
      assert :ok = Calls.subscribe(recipient_scope)

      assert {:ok, %{call: ringing}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      assert_receive {:call_ringing, _}
      assert_receive {:call_ringing, _}

      assert {:ok, _} = Calls.accept_call(recipient_scope, ringing.call_id, :audio)
      assert_receive {:call_connecting, _}
      assert_receive {:call_connecting, _}
      assert eventually_active?(ringing.call_id)
      assert_receive {:call_active, _}
      assert_receive {:call_active, _}

      assert AdmissionCoordinator.current_identity(caller_scope.user.id).target ==
               Target.direct_call(ringing.call_id)

      [{pid, _}] = Registry.lookup(DiscordClone.Calls.CallRegistry, ringing.call_id)
      ref = Process.monitor(pid)
      :ok = DynamicSupervisor.terminate_child(DiscordClone.Calls.CallSupervisor, pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}

      assert eventually_terminal?(ringing.call_id, :interrupted)

      assert_receive {:call_interrupted, interrupted}
      assert interrupted.call_id == ringing.call_id

      assert AdmissionCoordinator.current_identity(caller_scope.user.id) == nil
      assert AdmissionCoordinator.current_identity(recipient_scope.user.id) == nil
      assert_no_call_sessions(ringing.call_id)
      assert missed_call_activity_items(recipient_scope.user.id, ringing.call_id) == []
    end

    test "CallServer termination while connecting interrupts and releases the pair" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("rel_server_conn")

      first_channel = Ecto.UUID.generate()

      assert {:ok, _} = Voice.join(first_channel, caller_scope.user.id, "srv-conn", self())

      assert {:ok, %{call: ringing}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      {^first_channel, room_server} =
        Enum.find(Voice.running_room_servers(), fn {id, _} -> id == first_channel end)

      :ok = :sys.suspend(room_server)

      try do
        assert {:ok, _} = Calls.accept_call(recipient_scope, ringing.call_id, :audio)
        assert %CallAttempt{state: :connecting} = Repo.get!(CallAttempt, ringing.call_id)

        [{pid, _}] = Registry.lookup(DiscordClone.Calls.CallRegistry, ringing.call_id)
        ref = Process.monitor(pid)
        :ok = DynamicSupervisor.terminate_child(DiscordClone.Calls.CallSupervisor, pid)
        assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
      after
        :ok = :sys.resume(room_server)
      end

      assert eventually_terminal?(ringing.call_id, :interrupted)

      deadline = System.monotonic_time(:millisecond) + 5_000

      wait_for_pair_convergence(
        ringing.call_id,
        caller_scope.user.id,
        recipient_scope.user.id,
        deadline
      )

      assert AdmissionCoordinator.current_identity(caller_scope.user.id) == nil
      assert AdmissionCoordinator.current_identity(recipient_scope.user.id) == nil
      assert_no_call_sessions(ringing.call_id)
      assert missed_call_activity_items(recipient_scope.user.id, ringing.call_id) == []
    end

    test "recovery interrupts connecting/active attempts and releases stale media" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("rel_restart")

      assert {:ok, %{call: ringing}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      assert {:ok, _} = Calls.accept_call(recipient_scope, ringing.call_id, :audio)
      assert eventually_active?(ringing.call_id)

      assert AdmissionCoordinator.current_identity(caller_scope.user.id).target ==
               Target.direct_call(ringing.call_id)

      # Simulate application restart: the Call runtime is gone, so boot
      # recovery must interrupt durable connecting/active attempts and
      # release their stale media; nothing resumes with fictitious media.
      [{pid, _}] = Registry.lookup(DiscordClone.Calls.CallRegistry, ringing.call_id)
      ref = Process.monitor(pid)
      :ok = DynamicSupervisor.terminate_child(DiscordClone.Calls.CallSupervisor, pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}

      assert eventually_terminal?(ringing.call_id, :interrupted)

      # Boot recovery after the interruption sees only terminal truth.
      recovered = Calls.recover_nonterminal_attempts()
      assert recovered.rebuild == []

      assert AdmissionCoordinator.current_identity(caller_scope.user.id) == nil
      assert AdmissionCoordinator.current_identity(recipient_scope.user.id) == nil
      assert_no_call_sessions(ringing.call_id)
      assert missed_call_activity_items(recipient_scope.user.id, ringing.call_id) == []

      # No fictitious media: the attempt stays terminal and slots are freed.
      assert %CallAttempt{state: :terminal, terminal_outcome: :interrupted} =
               Repo.get!(CallAttempt, ringing.call_id)

      assert {:error, :not_found} =
               AdmissionCoordinator.reservation_generation(ringing.call_id)
    end
  end

  describe "target failure releases the pair" do
    for {report, suffix} <- [
          {:old_target_generation, "rel_old_target"},
          {:old_session_generation, "rel_old_session"},
          {:wrong_user, "rel_wrong_user"},
          {:wrong_session, "rel_wrong_session"}
        ] do
      @report report
      @suffix suffix
      test "#{report} failure preserves the active Call and both exact Sessions" do
        {caller, recipient, call_id} = active_failure_pair(@suffix)
        caller_identity = AdmissionCoordinator.current_identity(caller.user.id)
        recipient_identity = AdmissionCoordinator.current_identity(recipient.user.id)
        target_before = AdmissionCoordinator.call_target_snapshot(call_id)
        sessions_before = live_call_sessions(call_id)

        result =
          case @report do
            :old_target_generation ->
              AdmissionCoordinator.call_target_failed(call_id, make_ref(), :late_failure)

            :old_session_generation ->
              AdmissionCoordinator.call_session_failed(
                call_id,
                make_ref(),
                caller.user.id,
                caller_identity.session_id,
                :late_failure
              )

            :wrong_user ->
              AdmissionCoordinator.call_session_failed(
                call_id,
                caller_identity.runtime_generation,
                recipient.user.id,
                caller_identity.session_id,
                :late_failure
              )

            :wrong_session ->
              AdmissionCoordinator.call_session_failed(
                call_id,
                caller_identity.runtime_generation,
                caller.user.id,
                Ecto.UUID.generate(),
                :late_failure
              )
          end

        assert result == :ok

        # The coordinator sends notifications before replying, so flushing
        # Calls makes an erroneous terminal transition observable here.
        _ = flush_call_server(call_id)
        assert Repo.get!(CallAttempt, call_id).state == :active
        assert AdmissionCoordinator.current_identity(caller.user.id) == caller_identity
        assert AdmissionCoordinator.current_identity(recipient.user.id) == recipient_identity
        assert AdmissionCoordinator.call_target_snapshot(call_id) == target_before
        assert live_call_sessions(call_id) == sessions_before
        refute_receive {:call_failed, _}
        assert {:ok, _} = Calls.leave_call(caller, call_id)
      end
    end

    test "a matching current Session failure settles the Call and cleans both sides" do
      {caller, recipient, call_id} = active_failure_pair("rel_session_fail")
      identity = AdmissionCoordinator.current_identity(caller.user.id)

      assert :ok =
               AdmissionCoordinator.call_session_failed(
                 call_id,
                 identity.runtime_generation,
                 caller.user.id,
                 identity.session_id,
                 :boom
               )

      assert eventually_terminal?(call_id, :failed)
      assert_receive {:call_failed, %{call_id: ^call_id}}
      assert_receive {:call_failed, %{call_id: ^call_id}}
      assert AdmissionCoordinator.current_identity(caller.user.id) == nil
      assert AdmissionCoordinator.current_identity(recipient.user.id) == nil
      assert_no_call_sessions(call_id)
    end

    test "fake Call target failure ends the active Call visibly and frees both sides" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("rel_target_fail")

      assert :ok = Calls.subscribe(caller_scope)
      assert :ok = Calls.subscribe(recipient_scope)
      messages_before = Repo.aggregate(Message, :count)
      activity_before = Repo.aggregate(ActivityItem, :count)

      assert {:ok, %{call: ringing}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      assert_receive {:call_ringing, _}
      assert_receive {:call_ringing, _}

      assert {:ok, _} = Calls.accept_call(recipient_scope, ringing.call_id, :audio)
      assert_receive {:call_connecting, _}
      assert_receive {:call_connecting, _}
      assert eventually_active?(ringing.call_id)
      assert_receive {:call_active, _}
      assert_receive {:call_active, _}

      assert AdmissionCoordinator.current_identity(caller_scope.user.id).target ==
               Target.direct_call(ringing.call_id)

      # Fake target runtime reports failure; the pair must end coherently
      # with a visible failed terminal, not a stranded half-call.
      %{runtime_generation: generation} =
        AdmissionCoordinator.call_target_snapshot(ringing.call_id)

      assert :ok = AdmissionCoordinator.call_target_failed(ringing.call_id, generation, :boom)

      assert eventually_terminal?(ringing.call_id, :failed)

      assert_receive {:call_failed, failed}
      assert failed.call_id == ringing.call_id

      assert AdmissionCoordinator.current_identity(caller_scope.user.id) == nil
      assert AdmissionCoordinator.current_identity(recipient_scope.user.id) == nil
      assert_no_call_sessions(ringing.call_id)

      # Postcommit failure creates no missed Activity/Message and never
      # restores Voice.
      assert Repo.aggregate(ActivityItem, :count) == activity_before
      assert Repo.aggregate(Message, :count) == messages_before

      # Guard released: a new pair can reserve immediately.
      assert {:error, :not_found} =
               AdmissionCoordinator.reservation_generation(ringing.call_id)
    end
  end

  describe "guard and idempotency" do
    test "repeated cleanup from any cause is harmless and frees the guard" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("rel_idempotent")

      assert {:ok, %{call: ringing}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      assert {:ok, _} = Calls.accept_call(recipient_scope, ringing.call_id, :audio)
      assert eventually_active?(ringing.call_id)

      assert {:ok, ended} = Calls.leave_call(caller_scope, ringing.call_id)
      assert ended.terminal_outcome == :ended

      # Repeated cleanup from any cause is harmless.
      assert :ok = AdmissionCoordinator.cleanup_active_pair_for_call(ringing.call_id)
      assert :ok = AdmissionCoordinator.cleanup_active_pair_for_call(ringing.call_id)

      assert {:ok, again} = Calls.leave_call(recipient_scope, ringing.call_id)
      assert again.terminal_outcome == :ended

      assert :ok = AdmissionCoordinator.cleanup_active_pair_for_call(ringing.call_id)

      assert AdmissionCoordinator.current_identity(caller_scope.user.id) == nil
      assert AdmissionCoordinator.current_identity(recipient_scope.user.id) == nil
      assert_no_call_sessions(ringing.call_id)
    end

    test "a new Call or Voice join after cleanup never sees a half-cleaned pair" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("rel_guard")

      assert {:ok, %{call: ringing}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      assert {:ok, _} = Calls.accept_call(recipient_scope, ringing.call_id, :audio)
      assert eventually_active?(ringing.call_id)

      assert {:ok, _ended} = Calls.leave_call(caller_scope, ringing.call_id)
      assert AdmissionCoordinator.current_identity(caller_scope.user.id) == nil
      assert AdmissionCoordinator.current_identity(recipient_scope.user.id) == nil

      # Guard released only after both sides gone: a later eligible Call
      # reserves immediately and Voice admits without stale charge.
      {caller2_scope, recipient2_scope, direct2, _} =
        direct_conversation_fixture("rel_guard2")

      assert {:ok, %{call: ringing2}} =
               Calls.start_call(caller2_scope, direct2.id, :audio)

      assert {:ok, _} = Calls.accept_call(recipient2_scope, ringing2.call_id, :audio)
      assert eventually_active?(ringing2.call_id)

      assert AdmissionCoordinator.current_identity(caller2_scope.user.id).target ==
               Target.direct_call(ringing2.call_id)

      assert {:ok, _ended2} = Calls.leave_call(caller2_scope, ringing2.call_id)

      # Voice joins proceed after pair release (no stale capacity charge).
      assert {:ok, _} =
               Voice.join(Ecto.UUID.generate(), Ecto.UUID.generate(), "guard-voice", self())
    end

    test "precommit expiry releases only the reservation and never touches durable" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("rel_expiry")

      channel = Ecto.UUID.generate()
      assert {:ok, _} = Voice.join(channel, caller_scope.user.id, "expiry-voice", self())
      prior = AdmissionCoordinator.current_identity(caller_scope.user.id)

      assert {:ok, %{call: ringing}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      # Reserve directly at the coordinator seam (precommit, no durable commit).
      assert {:ok, target} = DirectCallTarget.start(ringing.call_id)
      assert {:ok, _} = DirectCallTarget.identity(target)

      from = {caller_scope.user.id, prior}
      to = {recipient_scope.user.id, nil}
      assert {:ok, reservation} = AdmissionCoordinator.reserve_pair(ringing.call_id, from, to)

      coordinator = Process.whereis(DiscordClone.Voice.SessionCoordinator)
      send(coordinator, {:reservation_expired, ringing.call_id, reservation.generation})
      _ = :sys.get_state(coordinator)

      # Expiry drops precommit state only: no durable write owed.
      assert Repo.get!(CallAttempt, ringing.call_id).state == :ringing
      assert AdmissionCoordinator.current_identity(caller_scope.user.id) == prior
      assert {:ok, %{occupancy: 1}} = Voice.room_occupancy(channel)

      # A new pair can reserve after expiry.
      assert {:error, :not_found} =
               AdmissionCoordinator.reservation_generation(ringing.call_id)
    end
  end

  describe "terminal races converge" do
    test "concurrent leaves converge on one ended outcome with both sides cleaned" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("rel_race_leave")

      assert {:ok, %{call: ringing}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      assert {:ok, _} = Calls.accept_call(recipient_scope, ringing.call_id, :audio)
      assert eventually_active?(ringing.call_id)

      caller = caller_scope
      recipient = recipient_scope
      call_id = ringing.call_id

      leave_caller = Task.async(fn -> Calls.leave_call(caller, call_id) end)
      leave_recipient = Task.async(fn -> Calls.leave_call(recipient, call_id) end)

      assert {:ok, first} = Task.await(leave_caller, 5_000)
      assert {:ok, second} = Task.await(leave_recipient, 5_000)

      assert first.terminal_outcome == :ended
      assert second.terminal_outcome == :ended
      assert first.ended_at == second.ended_at

      assert %CallAttempt{state: :terminal, terminal_outcome: :ended} =
               Repo.get!(CallAttempt, call_id)

      assert AdmissionCoordinator.current_identity(caller_scope.user.id) == nil
      assert AdmissionCoordinator.current_identity(recipient_scope.user.id) == nil
      assert_no_call_sessions(call_id)
    end

    test "leave racing friendship removal converges with complete slot release" do
      {caller_scope, recipient_scope, direct_conversation, friendship} =
        direct_conversation_fixture("rel_race_friend")

      assert {:ok, %{call: ringing}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      assert {:ok, _} = Calls.accept_call(recipient_scope, ringing.call_id, :audio)
      assert eventually_active?(ringing.call_id)

      call_id = ringing.call_id

      leave_task = Task.async(fn -> Calls.leave_call(caller_scope, call_id) end)

      friend_task =
        Task.async(fn -> Friendships.remove_friend(recipient_scope, friendship.id) end)

      leave_result = Task.await(leave_task, 5_000)
      assert match?({:ok, _}, leave_result) or match?({:error, _}, leave_result)

      friend_result = Task.await(friend_task, 5_000)
      assert friend_result == :ok or match?({:error, _}, friend_result)

      # Exactly one durable outcome wins; the loser observes terminal truth.
      reloaded = Repo.get!(CallAttempt, call_id)
      assert reloaded.state == :terminal
      assert reloaded.terminal_outcome in [:ended, :cancelled, :relationship_ended]

      assert AdmissionCoordinator.current_identity(caller_scope.user.id) == nil
      assert AdmissionCoordinator.current_identity(recipient_scope.user.id) == nil
      assert_no_call_sessions(call_id)
      assert missed_call_activity_items(recipient_scope.user.id, call_id) == []
    end

    test "leave racing in-flight admission never strands a half-pair" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("rel_race_inflight")

      first_channel = Ecto.UUID.generate()
      second_channel = Ecto.UUID.generate()

      assert {:ok, _} = Voice.join(first_channel, caller_scope.user.id, "race-caller", self())

      assert {:ok, _} =
               Voice.join(second_channel, recipient_scope.user.id, "race-recipient", self())

      assert {:ok, %{call: ringing}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      # Stall Voice retirement so the pair commit task blocks in-flight.
      {^first_channel, room_server} =
        Enum.find(Voice.running_room_servers(), fn {id, _} -> id == first_channel end)

      :ok = :sys.suspend(room_server)

      try do
        assert {:ok, _connecting} = Calls.accept_call(recipient_scope, ringing.call_id, :audio)

        # Leave while admission is in-flight; exactly one durable outcome wins.
        assert {:ok, left} = Calls.leave_call(caller_scope, ringing.call_id)
        assert left.state == :terminal
        assert left.terminal_outcome in [:cancelled, :ended]
      after
        :ok = :sys.resume(room_server)
      end

      # Poll for convergence: leave won (cancelled) with both sides cleaned,
      # or commit won then cleaned via the already-terminal path. Never a
      # stranded half Call pair (exactly one side with a direct_call target).
      deadline = System.monotonic_time(:millisecond) + 5_000

      wait_for_pair_convergence(
        ringing.call_id,
        caller_scope.user.id,
        recipient_scope.user.id,
        deadline
      )

      reloaded = Repo.get!(CallAttempt, ringing.call_id)
      assert reloaded.state == :terminal

      caller_identity = AdmissionCoordinator.current_identity(caller_scope.user.id)
      recipient_identity = AdmissionCoordinator.current_identity(recipient_scope.user.id)

      refute half_call_pair?(caller_identity, recipient_identity, ringing.call_id)

      # If a full pair survived (commit won the durable race), release it.
      if caller_identity != nil and
           match?(%{target: %Target{kind: :direct_call}}, caller_identity) do
        assert {:ok, _} = Calls.leave_call(recipient_scope, ringing.call_id)
        assert AdmissionCoordinator.current_identity(caller_scope.user.id) == nil
        assert AdmissionCoordinator.current_identity(recipient_scope.user.id) == nil
      end

      assert_no_call_sessions(ringing.call_id)
    end
  end

  # Shared polling helpers (`eventually_active?/2`, `eventually_terminal?/3`,
  # `poll_until/3`, `flush_call_server/1`, `assert_no_call_sessions/1`) live in
  # `DiscordClone.CallsFixtures` (imported above).
  defp pause_pair_commit(stage) do
    parent = self()
    barrier = make_ref()

    if stage == :after_begin do
      handler = {__MODULE__, barrier}

      :ok =
        :telemetry.attach(
          handler,
          DiscordClone.Media.AdmissionDiagnostics.event(),
          fn
            _, _, %{operation: "begin_pair_commit", outcome: :accepted}, _ ->
              send(parent, {:pair_commit_paused, barrier, self()})

              receive do
                {:resume_pair_commit, ^barrier} -> :ok
              end

            _, _, _, _ ->
              :ok
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler) end)
    end

    Application.put_env(:discord_clone, :pair_commit_fault, %{
      barrier: fn
        ^stage ->
          send(parent, {:pair_commit_paused, barrier, self()})

          receive do
            {:resume_pair_commit, ^barrier} -> :ok
          end

        _ ->
          :ok
      end
    })

    barrier
  end

  defp call_target(call_id) do
    [target] =
      for {_, pid, _, _} <-
            DynamicSupervisor.which_children(DiscordClone.Media.DirectCallTargetSupervisor),
          {:ok, %{call_id: ^call_id}} <- [DirectCallTarget.identity(pid)],
          do: pid

    target
  end

  defp monitor_target_sessions(target) do
    {DynamicSupervisor, supervisor, _, _} =
      List.keyfind(Supervisor.which_children(target), DynamicSupervisor, 0)

    Enum.map(
      [target | Enum.map(DynamicSupervisor.which_children(supervisor), &elem(&1, 1))],
      &{&1, Process.monitor(&1)}
    )
  end

  defp assert_target_sessions_down(monitors) do
    for {pid, monitor} <- monitors do
      assert_receive {:DOWN, ^monitor, :process, ^pid, _}, 1_000
    end
  end

  defp active_failure_pair(suffix) do
    {caller, recipient, conversation, _} = direct_conversation_fixture(suffix)
    assert :ok = Calls.subscribe(caller)
    assert :ok = Calls.subscribe(recipient)
    assert {:ok, %{call: ringing}} = Calls.start_call(caller, conversation.id, :audio)
    assert_receive {:call_ringing, _}
    assert_receive {:call_ringing, _}
    assert {:ok, _} = Calls.accept_call(recipient, ringing.call_id, :audio)
    assert_receive {:call_connecting, _}
    assert_receive {:call_connecting, _}
    assert eventually_active?(ringing.call_id)
    assert_receive {:call_active, _}
    assert_receive {:call_active, _}
    {caller, recipient, ringing.call_id}
  end

  defp live_call_sessions(call_id) do
    target =
      :sys.get_state(DiscordClone.Voice.SessionCoordinator).call_targets[call_id].target_pid

    {DynamicSupervisor, supervisor, _, _} =
      List.keyfind(Supervisor.which_children(target), DynamicSupervisor, 0)

    sessions =
      for {_, pid, _, _} <- DynamicSupervisor.which_children(supervisor),
          do: {pid, :sys.get_state(pid)}

    assert length(sessions) == 2
    Map.new(sessions)
  end

  defp wait_for_pair_convergence(call_id, first_user_id, second_user_id, deadline) do
    _ = flush_call_server(call_id)
    _ = :sys.get_state(Process.whereis(DiscordClone.Voice.SessionCoordinator))

    first = AdmissionCoordinator.current_identity(first_user_id)
    second = AdmissionCoordinator.current_identity(second_user_id)
    attempt = Repo.get(CallAttempt, call_id)

    cond do
      attempt == nil ->
        flunk("expected Call Attempt to still exist")

      attempt.state == :terminal and not half_call_pair?(first, second, call_id) and
          (first == nil or match?(%{target: %Target{kind: :direct_call}}, first) or
             match?(%{target: %Target{kind: :voice_channel}}, first)) ->
        # Converged unless a full Call pair is still present without a
        # terminal cleanup having run; if both nil, done. If full pair,
        # caller will release it. Half Call pairs never converge — fail.
        if first == nil and second == nil do
          :ok
        else
          # Allow one more flush for async cleanup, then re-check.
          if System.monotonic_time(:millisecond) >= deadline do
            :ok
          else
            :erlang.yield()
            wait_for_pair_convergence(call_id, first_user_id, second_user_id, deadline)
          end
        end

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("timed out waiting for pair convergence")

      true ->
        :erlang.yield()
        wait_for_pair_convergence(call_id, first_user_id, second_user_id, deadline)
    end
  end

  defp half_call_pair?(first, second, call_id) do
    first_is_call? =
      match?(%{target: %Target{kind: :direct_call, id: ^call_id}}, first)

    second_is_call? =
      match?(%{target: %Target{kind: :direct_call, id: ^call_id}}, second)

    first_is_call? != second_is_call?
  end
end
