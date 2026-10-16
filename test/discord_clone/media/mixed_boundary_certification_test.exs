defmodule DiscordClone.Media.MixedBoundaryCertificationTest do
  @moduledoc false
  use DiscordClone.DataCase, async: false

  import DiscordClone.CallsFixtures

  alias DiscordClone.Calls
  alias DiscordClone.Calls.CallAttempt
  alias DiscordClone.Friendships
  alias DiscordClone.Media.AdmissionCoordinator
  alias DiscordClone.Media.AdmissionDiagnostics
  alias DiscordClone.Media.DirectCallTarget
  alias DiscordClone.Media.Target
  alias DiscordClone.MediaFixtures
  alias DiscordClone.Repo
  alias DiscordClone.Voice
  alias DiscordClone.Voice.DeploymentCapacity

  @event [:discord_clone, :media_admission, :operation]

  setup do
    start_supervised!(DiscordClone.Calls.Supervisor)
    DiscordClone.Calls.CallCoordinator.begin_recovery()
    await_recovery_finished()

    MediaFixtures.setup_coordinator_pair_state!()

    previous_recovery_barrier =
      Application.fetch_env(:discord_clone, :recovery_settlement_barrier)

    Application.delete_env(:discord_clone, :recovery_settlement_barrier)

    previous_runtime = Application.get_env(:discord_clone, :accepted_call_runtime)
    previous_result = Application.get_env(:discord_clone, :accepted_call_runtime_result)

    Application.put_env(
      :discord_clone,
      :accepted_call_runtime,
      DiscordClone.Calls.PairAdmissionRuntime
    )

    Application.delete_env(:discord_clone, :accepted_call_runtime_result)

    on_exit(fn ->
      case previous_recovery_barrier do
        {:ok, setting} ->
          Application.put_env(:discord_clone, :recovery_settlement_barrier, setting)

        :error ->
          Application.delete_env(:discord_clone, :recovery_settlement_barrier)
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

    on_exit(fn ->
      Voice.running_room_servers()
      |> Enum.each(fn {voice_channel_id, _room_server} ->
        :ok = Voice.end_channel_sessions(voice_channel_id)
        :ok = Voice.expire_idle_room(voice_channel_id)
      end)
    end)

    :ok
  end

  describe "capacity matrix through public accept seam" do
    for {occupied, replacements, outcome, final_occupancy} <- [
          {18, 0, :active, 20},
          {18, 1, :active, 19},
          {18, 2, :active, 18},
          {19, 0, :failed_capacity, 19},
          {19, 1, :active, 20},
          {19, 2, :active, 19},
          {20, 0, :failed_capacity, 20},
          {20, 1, :failed_capacity, 20},
          {20, 2, :active, 20}
        ] do
      @occupied occupied
      @replacements replacements
      @outcome outcome
      @final_occupancy final_occupancy

      test "#{occupied} occupied with #{replacements} exact replacements settles to #{outcome} at #{final_occupancy}" do
        prefix = "c25m#{@occupied}#{@replacements}"
        {caller, recipient, conversation, _} = direct_conversation_fixture(prefix)
        unrelated = fill_unrelated_slots(@occupied - @replacements, prefix)
        users = [caller.user.id, recipient.user.id]

        priors = join_prior_voices(users, @replacements, prefix)

        expected = Map.new(users, &{&1, Map.get(priors, &1)})
        assert AdmissionCoordinator.effective_occupancy() == @occupied
        assert {:ok, %{call: ringing}} = Calls.start_call(caller, conversation.id, :audio)
        assert AdmissionCoordinator.reservation_count() == 0
        assert_identities(expected)
        assert AdmissionCoordinator.effective_occupancy() == @occupied

        if @outcome == :active do
          assert {:ok, %{state: :connecting}} =
                   Calls.accept_call(recipient, ringing.call_id, :audio)

          assert eventually_active?(ringing.call_id)
          assert_public_pair(caller, recipient, ringing.call_id)

          for {user_id, prior} <- priors do
            assert {:ok, %{occupancy: 0}} = Voice.room_occupancy(prior.target.id)
            refute AdmissionCoordinator.current_identity(user_id).session_id == prior.session_id
          end
        else
          assert {:ok, %{state: :terminal, terminal_outcome: :failed_capacity}} =
                   Calls.accept_call(recipient, ringing.call_id, :audio)

          assert_identities(expected)

          for {_user_id, prior} <- priors do
            assert {:ok, %{occupancy: 1}} = Voice.room_occupancy(prior.target.id)
          end

          assert_no_call_sessions(ringing.call_id)
        end

        assert AdmissionCoordinator.effective_occupancy() == @final_occupancy
        assert AdmissionCoordinator.reservation_count() == 0
        assert {:error, :not_found} = AdmissionCoordinator.reservation_generation(ringing.call_id)
        assert_identities(unrelated)

        if @final_occupancy == 20 do
          assert {:error, %{reason: :deployment_full, occupancy: 20, capacity: 20}} =
                   Voice.join(
                     Ecto.UUID.generate(),
                     Ecto.UUID.generate(),
                     "#{prefix}-over",
                     self()
                   )
        end
      end
    end

    test "second pair is blocked while one Direct Call is active" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("c12blk1")

      assert {:ok, %{call: ringing}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      assert {:ok, _} = Calls.accept_call(recipient_scope, ringing.call_id, :audio)
      assert eventually_active?(ringing.call_id)
      existing = AdmissionCoordinator.call_target_snapshot(ringing.call_id)

      {other_caller, other_recipient, other_conversation, _} =
        direct_conversation_fixture("c12blk2")

      assert :ok = Calls.subscribe(other_caller)
      assert :ok = Calls.subscribe(other_recipient)

      assert {:ok, %{call: other_ringing}} =
               Calls.start_call(other_caller, other_conversation.id, :audio)

      other_call_id = other_ringing.call_id
      assert_receive {:call_ringing, %{call_id: ^other_call_id}}
      assert_receive {:call_ringing, %{call_id: ^other_call_id}}

      # The one-Call support cap rejects before any connecting projection.
      assert {:ok, %{state: :terminal, terminal_outcome: :failed_capacity}} =
               Calls.accept_call(other_recipient, other_call_id, :audio)

      assert_receive {:call_failed_capacity, %{call_id: ^other_call_id}}
      assert_receive {:call_failed_capacity, %{call_id: ^other_call_id}}
      refute_received {:call_connecting, %{call_id: ^other_call_id}}
      refute_received {:call_active, %{call_id: ^other_call_id}}

      # First pair is untouched; no second Call Sessions were exposed.
      assert {:ok, %{state: :active}} = Calls.get_call(recipient_scope, ringing.call_id)
      assert AdmissionCoordinator.call_target_snapshot(ringing.call_id) == existing
      assert {:error, :not_found} = AdmissionCoordinator.reservation_generation(other_call_id)
      assert_no_call_sessions(other_call_id)
    end
  end

  describe "completion gate re-proof" do
    test "capacity rejection moves neither User and exposes no Call Session" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("c12gate1")

      first_channel = Ecto.UUID.generate()
      second_channel = Ecto.UUID.generate()

      assert {:ok, _} = Voice.join(first_channel, caller_scope.user.id, "c12g1-c", self())
      assert {:ok, _} = Voice.join(second_channel, recipient_scope.user.id, "c12g1-r", self())

      fill_unrelated_slots(18, "c12g1")

      # 20 occupied with 0 usable credit for this pair would reject, but the
      # pair itself holds 2 priors. Fill one extra slot via the pair's own
      # Voice is already counted; force rejection by filling to 19 unrelated
      # is impossible here (would exceed cap). Instead prove the preserved
      # rejection path with no priors at 19 occupied.
      :ok = Voice.end_user_session(first_channel, caller_scope.user.id)
      :ok = Voice.end_user_session(second_channel, recipient_scope.user.id)
      _ = :sys.get_state(Process.whereis(DiscordClone.Voice.SessionCoordinator))

      # Now 18 unrelated, no priors: admit would be 20. Add one more to reach
      # 19 occupied with 0 replacements -> 21 rejects.
      fill_unrelated_slots(1, "c12g1x")

      caller_prior = AdmissionCoordinator.current_identity(caller_scope.user.id)
      recipient_prior = AdmissionCoordinator.current_identity(recipient_scope.user.id)
      assert caller_prior == nil
      assert recipient_prior == nil

      assert {:ok, %{call: ringing}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      assert {:ok, terminal} = Calls.accept_call(recipient_scope, ringing.call_id, :audio)
      assert terminal.terminal_outcome == :failed_capacity

      assert AdmissionCoordinator.current_identity(caller_scope.user.id) == nil
      assert AdmissionCoordinator.current_identity(recipient_scope.user.id) == nil
      assert_no_call_sessions(ringing.call_id)
    end

    test "successful commit retires both exact priors and publishes both sides together" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("c12gate2")

      first_channel = Ecto.UUID.generate()
      second_channel = Ecto.UUID.generate()

      assert {:ok, %{voice_session_id: first_voice}} =
               Voice.join(first_channel, caller_scope.user.id, "c12g2-c", self())

      assert {:ok, %{voice_session_id: second_voice}} =
               Voice.join(second_channel, recipient_scope.user.id, "c12g2-r", self())

      assert {:ok, %{call: ringing}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      assert {:ok, _} = Calls.accept_call(recipient_scope, ringing.call_id, :audio)
      assert eventually_active?(ringing.call_id)

      assert {:ok, %{occupancy: 0}} = Voice.room_occupancy(first_channel)
      assert {:ok, %{occupancy: 0}} = Voice.room_occupancy(second_channel)

      caller_identity = AdmissionCoordinator.current_identity(caller_scope.user.id)
      recipient_identity = AdmissionCoordinator.current_identity(recipient_scope.user.id)

      assert caller_identity.target == Target.direct_call(ringing.call_id)
      assert recipient_identity.target == Target.direct_call(ringing.call_id)
      refute caller_identity.session_id == first_voice
      refute recipient_identity.session_id == second_voice
      refute caller_identity.session_id == recipient_identity.session_id

      assert %{sessions: sessions} =
               AdmissionCoordinator.call_target_snapshot(ringing.call_id)

      assert map_size(sessions) == 2
    end

    test "postcommit failure cleans both Call sides without Voice restore" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("c12gate3")

      first_channel = Ecto.UUID.generate()
      second_channel = Ecto.UUID.generate()

      assert {:ok, _} = Voice.join(first_channel, caller_scope.user.id, "c12g3-c", self())
      assert {:ok, _} = Voice.join(second_channel, recipient_scope.user.id, "c12g3-r", self())

      assert {:ok, %{call: ringing}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      Application.put_env(:discord_clone, :pair_commit_fault, %{
        admit_failures: [recipient_scope.user.id]
      })

      assert {:ok, connecting} = Calls.accept_call(recipient_scope, ringing.call_id, :audio)
      assert connecting.state == :connecting
      assert eventually_terminal?(ringing.call_id, :failed)

      assert AdmissionCoordinator.current_identity(caller_scope.user.id) == nil
      assert AdmissionCoordinator.current_identity(recipient_scope.user.id) == nil
      assert {:ok, %{occupancy: 0}} = Voice.room_occupancy(first_channel)
      assert {:ok, %{occupancy: 0}} = Voice.room_occupancy(second_channel)
      assert_no_call_sessions(ringing.call_id)
    end

    test "stale cleanup cannot remove a replacement Session" do
      pair = MediaFixtures.ringing_pair_fixture("c12stale")
      MediaFixtures.start_ready_call_target(pair.call_id)

      assert {:ok, reservation} =
               AdmissionCoordinator.reserve_pair(
                 pair.call_id,
                 {pair.first_user_id, nil},
                 {pair.second_user_id, nil}
               )

      MediaFixtures.set_attempt_connecting!(pair.call_id)

      assert {:ok, result} =
               AdmissionCoordinator.commit_pair(pair.call_id, reservation.generation)

      # Wrong generation, wrong user, and unknown session are all ignored.
      assert :ok =
               AdmissionCoordinator.call_session_removed(
                 pair.call_id,
                 make_ref(),
                 pair.first_user_id,
                 result.call_sessions[pair.first_user_id]
               )

      assert :ok =
               AdmissionCoordinator.call_session_removed(
                 pair.call_id,
                 result.target_runtime_generation,
                 pair.second_user_id,
                 result.call_sessions[pair.first_user_id]
               )

      _ = :sys.get_state(Process.whereis(DiscordClone.Voice.SessionCoordinator))

      assert AdmissionCoordinator.current_identity(pair.first_user_id).session_id ==
               result.call_sessions[pair.first_user_id]

      assert AdmissionCoordinator.current_identity(pair.second_user_id).session_id ==
               result.call_sessions[pair.second_user_id]

      assert :ok = AdmissionCoordinator.cleanup_active_pair(pair.call_id, reservation.generation)
    end

    test "unrelated rooms progress while a pair switch holds its reservation" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("c12unrel")

      voice_channel = Ecto.UUID.generate()
      assert {:ok, _} = Voice.join(voice_channel, caller_scope.user.id, "c12u-voice", self())

      assert {:ok, %{call: ringing}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      {^voice_channel, room_server} =
        Enum.find(Voice.running_room_servers(), fn {id, _} -> id == voice_channel end)

      :ok = :sys.suspend(room_server)

      try do
        assert {:ok, _} = Calls.accept_call(recipient_scope, ringing.call_id, :audio)

        # Unrelated Voice room admits while the pair commit is pinned.
        assert {:ok, _} =
                 Voice.join(Ecto.UUID.generate(), Ecto.UUID.generate(), "c12u-other", self())
      after
        :ok = :sys.resume(room_server)
      end

      assert eventually_active?(ringing.call_id)
    end
  end

  describe "controlled mixed-boundary overlap" do
    for replacements <- [0, 2] do
      @replacements replacements
      test "accept holds both Users against Voice join/move with #{@replacements} prior Sessions" do
        {caller, recipient, conversation, _} =
          direct_conversation_fixture("c25voice#{@replacements}")

        unrelated = fill_unrelated_slots(16, "c25voice#{@replacements}")
        users = [caller.user.id, recipient.user.id]

        priors = join_prior_voices(users, @replacements, "c25prior")

        expected = Map.new(users, &{&1, Map.get(priors, &1)})
        assert {:ok, %{call: ringing}} = Calls.start_call(caller, conversation.id, :audio)
        barrier = pause_accept()
        tasks = start_supervised!(Task.Supervisor)

        accept =
          Task.Supervisor.async_nolink(tasks, fn ->
            Calls.accept_call(recipient, ringing.call_id, :audio)
          end)

        try do
          assert_receive {:accept_reserved, ^barrier, owner}, 2_000
          assert owner == accept.pid
          assert {:ok, generation} = AdmissionCoordinator.reservation_generation(ringing.call_id)
          assert AdmissionCoordinator.reservation_count() == 1
          assert AdmissionCoordinator.effective_occupancy() == 18
          assert_identities(expected)
          assert_no_call_sessions(ringing.call_id)
          assert {:ok, %{state: :ringing}} = Calls.get_call(recipient, ringing.call_id)

          for user_id <- users do
            assert {:error, %{reason: :reservation_conflict}} =
                     Voice.join(Ecto.UUID.generate(), user_id, "c25pinned", self())
          end

          assert_identities(expected)
          assert {:ok, ^generation} = AdmissionCoordinator.reservation_generation(ringing.call_id)

          assert {:ok, _} =
                   Voice.join(Ecto.UUID.generate(), Ecto.UUID.generate(), "c25progress", self())

          assert AdmissionCoordinator.effective_occupancy() == 19
          assert_identities(unrelated)
        after
          send(accept.pid, {:resume_accept, barrier})
        end

        assert {:ok, %{state: :connecting}} = Task.await(accept, 5_000)
        assert eventually_active?(ringing.call_id)
        assert_public_pair(caller, recipient, ringing.call_id)
        assert AdmissionCoordinator.effective_occupancy() == 19
        assert_identities(unrelated)

        for {_user_id, prior} <- priors do
          assert {:ok, %{occupancy: 0}} = Voice.room_occupancy(prior.target.id)
        end
      end
    end

    test "cancel and Friendship removal overlap an unpublished accept and preserve one terminal winner" do
      {caller, recipient, conversation, friendship} = direct_conversation_fixture("c25terminal")
      assert :ok = Calls.subscribe(caller)
      assert :ok = Calls.subscribe(recipient)
      assert {:ok, %{call: ringing}} = Calls.start_call(caller, conversation.id, :audio)
      call_id = ringing.call_id
      barrier = pause_pair_publication()
      assert {:ok, %{state: :connecting}} = Calls.accept_call(recipient, call_id, :audio)
      assert_receive {:pair_before_publish, ^barrier, worker}, 2_000
      worker_monitor = Process.monitor(worker)
      assert {:ok, generation} = AdmissionCoordinator.reservation_generation(call_id)
      assert AdmissionCoordinator.reservation_count() == 1
      assert %{sessions: sessions} = AdmissionCoordinator.call_target_snapshot(call_id)
      assert map_size(sessions) == 2
      assert_identities(%{caller.user.id => nil, recipient.user.id => nil})

      tasks = start_supervised!(Task.Supervisor)
      parent = self()
      gate = make_ref()

      cancel =
        Task.Supervisor.async_nolink(tasks, fn ->
          command_gate(parent, gate, :cancel)
          Calls.cancel_call(caller, call_id)
        end)

      removal =
        Task.Supervisor.async_nolink(tasks, fn ->
          command_gate(parent, gate, :friendship)
          Friendships.remove_friend(recipient, friendship.id)
        end)

      assert_receive {:command_waiting, ^gate, :cancel}, 2_000
      assert_receive {:command_waiting, ^gate, :friendship}, 2_000
      cleanup_started = System.monotonic_time(:millisecond)
      send(cancel.pid, {:run_command, gate})
      send(removal.pid, {:run_command, gate})

      # Both commands compete while the accepted pair is still private.
      cancel_result = Task.await(cancel, 5_000)
      assert :ok = Task.await(removal, 5_000)
      assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}, 2_000
      assert System.monotonic_time(:millisecond) - cleanup_started < 5_000

      # Terminal projections reach both participants even though former Friends
      # can no longer read the Call. Reconnecting permits a public durable read.
      assert_receive {event, %{call_id: ^call_id, state: :terminal} = winner}
                     when event in [:call_cancelled, :call_relationship_ended],
                     2_000

      assert winner.terminal_outcome in [:cancelled, :relationship_ended]

      case cancel_result do
        {:ok, terminal} -> assert terminal.terminal_outcome == winner.terminal_outcome
        {:error, :not_found} -> assert winner.terminal_outcome == :relationship_ended
      end

      outcome = winner.terminal_outcome
      ended_at = winner.ended_at

      assert_receive {^event,
                      %{call_id: ^call_id, terminal_outcome: ^outcome, ended_at: ^ended_at}},
                     2_000

      refute_received {^event, %{call_id: ^call_id}}
      assert {:error, :not_found} = Calls.get_call(caller, call_id)
      assert {:error, :not_found} = Calls.cancel_call(caller, call_id)
      assert {:ok, :terminal} = Calls.complete_accepted_runtime(call_id, :failed, :audio)

      assert {:ok, %{relationship: request}} =
               Friendships.send_friend_request(caller, %{username: recipient.user.username})

      assert {:ok, _friendship} = Friendships.accept_friend_request(recipient, request.id)

      assert {:ok, %{state: :terminal, terminal_outcome: ^outcome, ended_at: ^ended_at}} =
               Calls.get_call(caller, call_id)

      assert {:ok, %{terminal_outcome: ^outcome, ended_at: ^ended_at}} =
               Calls.cancel_call(caller, call_id)

      assert {:error, :stale_reservation} =
               AdmissionCoordinator.release_reservation(call_id, generation)

      assert {:error, :not_found} = AdmissionCoordinator.reservation_generation(call_id)
      assert AdmissionCoordinator.reservation_count() == 0
      assert AdmissionCoordinator.effective_occupancy() == 0
      assert_identities(%{caller.user.id => nil, recipient.user.id => nil})
      assert_no_call_sessions(call_id)
      refute_received {:call_active, %{call_id: ^call_id}}
      assert missed_call_activity_items(recipient.user.id, call_id) == []

      assert {:ok, _} =
               Voice.join(Ecto.UUID.generate(), caller.user.id, "c25after-terminal", self())

      replacement = AdmissionCoordinator.current_identity(caller.user.id)
      assert :ok = AdmissionCoordinator.cleanup_active_pair_for_call(call_id)
      assert AdmissionCoordinator.current_identity(caller.user.id) == replacement
    end

    test "unrelated room failure overlaps reserved accept without removing either prior or its replacement" do
      {caller, recipient, conversation, _} = direct_conversation_fixture("c25room")
      assert {:ok, _} = Voice.join(Ecto.UUID.generate(), caller.user.id, "c25room-prior", self())
      prior = AdmissionCoordinator.current_identity(caller.user.id)
      channel = Ecto.UUID.generate()
      unrelated_user = Ecto.UUID.generate()
      assert {:ok, _} = Voice.join(channel, unrelated_user, "c25room-failed", self())
      {^channel, room} = Enum.find(Voice.running_room_servers(), fn {id, _} -> id == channel end)
      monitor = Process.monitor(room)
      assert {:ok, %{call: ringing}} = Calls.start_call(caller, conversation.id, :audio)
      barrier = pause_accept()
      tasks = start_supervised!(Task.Supervisor)

      accept =
        Task.Supervisor.async_nolink(tasks, fn ->
          Calls.accept_call(recipient, ringing.call_id, :audio)
        end)

      try do
        assert_receive {:accept_reserved, ^barrier, _owner}, 2_000
        assert {:ok, generation} = AdmissionCoordinator.reservation_generation(ringing.call_id)
        assert :ok = Voice.crash_forwarder(channel)
        assert_receive {:DOWN, ^monitor, :process, ^room, _reason}, 5_000
        _ = :sys.get_state(DiscordClone.Voice.SessionCoordinator)
        assert AdmissionCoordinator.current_identity(unrelated_user) == nil
        assert AdmissionCoordinator.current_identity(caller.user.id) == prior
        assert {:ok, ^generation} = AdmissionCoordinator.reservation_generation(ringing.call_id)
        assert_no_call_sessions(ringing.call_id)
        assert {:ok, _} = Voice.join(channel, unrelated_user, "c25room-new", self())
        assert AdmissionCoordinator.effective_occupancy() == 3
      after
        send(accept.pid, {:resume_accept, barrier})
      end

      replacement = AdmissionCoordinator.current_identity(unrelated_user)
      assert {:ok, %{state: :connecting}} = Task.await(accept, 5_000)
      assert eventually_active?(ringing.call_id)
      assert_public_pair(caller, recipient, ringing.call_id)
      assert AdmissionCoordinator.current_identity(unrelated_user) == replacement
      assert AdmissionCoordinator.effective_occupancy() == 3
      assert {:ok, %{occupancy: 0}} = Voice.room_occupancy(prior.target.id)
    end

    test "coordinator restart overlaps private pair publication and stays closed until settlement" do
      {caller, recipient, conversation, _} = direct_conversation_fixture("c25restart")
      assert :ok = Calls.subscribe(caller)
      assert :ok = Calls.subscribe(recipient)
      assert {:ok, %{call: ringing}} = Calls.start_call(caller, conversation.id, :audio)
      call_id = ringing.call_id
      barrier = pause_pair_publication()
      assert {:ok, %{state: :connecting}} = Calls.accept_call(recipient, call_id, :audio)
      assert_receive {:pair_before_publish, ^barrier, worker}, 2_000
      worker_monitor = Process.monitor(worker)
      assert {:ok, generation} = AdmissionCoordinator.reservation_generation(call_id)

      assert %{runtime_generation: target_generation, sessions: sessions} =
               AdmissionCoordinator.call_target_snapshot(call_id)

      assert {:ok, target} = DirectCallTarget.start(call_id)
      target_monitor = Process.monitor(target)
      assert map_size(sessions) == 2
      assert_identities(%{caller.user.id => nil, recipient.user.id => nil})

      # Unrelated admission progresses while acceptance is paused.
      room_id = Ecto.UUID.generate()
      assert {:ok, _} = Voice.join(room_id, Ecto.UUID.generate(), "c25restart-progress", self())
      {^room_id, room} = Enum.find(Voice.running_room_servers(), fn {id, _} -> id == room_id end)
      room_monitor = Process.monitor(room)
      parent = self()

      Application.put_env(:discord_clone, :recovery_settlement_barrier, fn ^call_id ->
        send(parent, {:recovery_settlement, self()})

        receive do
          :settle -> :ok
        end
      end)

      coordinator = Process.whereis(DiscordClone.Voice.SessionCoordinator)
      coordinator_monitor = Process.monitor(coordinator)
      assert :ok = Voice.crash_session_coordinator()
      assert_receive {:DOWN, ^coordinator_monitor, :process, ^coordinator, :killed}, 2_000
      assert_receive {:recovery_settlement, recovery_worker}, 2_000
      recovery_monitor = Process.monitor(recovery_worker)

      try do
        assert_receive {:DOWN, ^target_monitor, :process, ^target, _}, 2_000
        assert_receive {:DOWN, ^room_monitor, :process, ^room, _}, 2_000

        assert {:error, :recovering} =
                 Voice.join(Ecto.UUID.generate(), caller.user.id, "c25closed", self())

        assert {:error, :not_found} = AdmissionCoordinator.reservation_generation(call_id)
        assert AdmissionCoordinator.reservation_count() == 0
        assert_identities(%{caller.user.id => nil, recipient.user.id => nil})
        assert_no_call_sessions(call_id)
      after
        send(recovery_worker, :settle)
      end

      assert_receive {:DOWN, ^recovery_monitor, :process, ^recovery_worker, :normal}, 2_000
      assert :ok = await_cert_coordinator_recovery()
      # A late publication from the old epoch cannot match the new reservation.
      send(worker, {:resume_publication, barrier})
      assert_receive {:DOWN, ^worker_monitor, :process, ^worker, _}, 2_000

      assert {:ok, %{state: :terminal, terminal_outcome: :interrupted}} =
               Calls.get_call(recipient, call_id)

      assert_receive {:call_interrupted, %{call_id: ^call_id}}, 2_000
      assert_receive {:call_interrupted, %{call_id: ^call_id}}, 2_000
      refute_received {:call_interrupted, %{call_id: ^call_id}}

      assert {:error, :stale_reservation} =
               AdmissionCoordinator.release_reservation(call_id, generation)

      assert AdmissionCoordinator.effective_occupancy() == 0
      assert_no_call_sessions(call_id)
      refute_received {:call_active, %{call_id: ^call_id}}

      assert {:ok, _} = Voice.join(room_id, caller.user.id, "c25restart-new", self())
      replacement = AdmissionCoordinator.current_identity(caller.user.id)

      for {session_id, user_id} <- sessions do
        assert :ok =
                 AdmissionCoordinator.call_session_removed(
                   call_id,
                   target_generation,
                   user_id,
                   session_id
                 )
      end

      assert AdmissionCoordinator.current_identity(caller.user.id) == replacement
      assert AdmissionCoordinator.reservation_count() == 0
      assert AdmissionCoordinator.effective_occupancy() == 1

      assert {:ok, _} =
               Voice.join(Ecto.UUID.generate(), Ecto.UUID.generate(), "c25restart-after", self())

      assert AdmissionCoordinator.effective_occupancy() == 2
    end
  end

  describe "reverse-switch certification" do
    test "at 20 occupied the switch projects 19 with single-ledger gauges" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("c12rev1")

      fill_unrelated_slots(18, "c12rev1")

      assert {:ok, %{call: ringing}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      assert {:ok, _} = Calls.accept_call(recipient_scope, ringing.call_id, :audio)
      assert eventually_active?(ringing.call_id)

      assert AdmissionCoordinator.effective_occupancy() == 20

      destination = Ecto.UUID.generate()

      assert {:ok, %{occupancy: 1, capacity: 5}} =
               Voice.join(destination, caller_scope.user.id, "c12rev1-s", self())

      assert %CallAttempt{state: :terminal, terminal_outcome: :ended} =
               Repo.get!(CallAttempt, ringing.call_id)

      # Single-ledger projection: 20 - 2 retired Call Sessions + 1 Voice = 19.
      assert AdmissionCoordinator.effective_occupancy() == 19

      # 18 unrelated + 1 Voice = 19; one more admits to 20, next rejects.
      assert {:ok, _} =
               Voice.join(Ecto.UUID.generate(), Ecto.UUID.generate(), "c12rev1-a", self())

      assert {:error, %{reason: :deployment_full, occupancy: 20, capacity: 20}} =
               Voice.join(Ecto.UUID.generate(), Ecto.UUID.generate(), "c12rev1-o", self())
    end

    test "full-room destination preserves the active Call for both (unauthorized covered in voice-switch suite)" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("c12rev2")

      assert {:ok, %{call: ringing}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      assert {:ok, _} = Calls.accept_call(recipient_scope, ringing.call_id, :audio)
      assert eventually_active?(ringing.call_id)

      call_id = ringing.call_id
      destination = Ecto.UUID.generate()

      for number <- 1..5 do
        assert {:ok, %{occupancy: ^number}} =
                 Voice.join(destination, Ecto.UUID.generate(), "c12rev2-#{number}", self())
      end

      assert {:error, %{reason: :room_full}} =
               Voice.join(destination, caller_scope.user.id, "c12rev2-try", self())

      assert %CallAttempt{state: :active} = Repo.get!(CallAttempt, call_id)

      assert %{target: %Target{kind: :direct_call, id: ^call_id}} =
               AdmissionCoordinator.current_identity(caller_scope.user.id)

      assert %{target: %Target{kind: :direct_call, id: ^call_id}} =
               AdmissionCoordinator.current_identity(recipient_scope.user.id)
    end
  end

  describe "telemetry and configuration audit" do
    test "only allowlisted measurements and metadata leave the runtime" do
      {_, handler_id} = attach_collector()

      try do
        pair = MediaFixtures.ringing_pair_fixture("c12tel")
        MediaFixtures.start_ready_call_target(pair.call_id)

        assert {:ok, reservation} =
                 AdmissionCoordinator.reserve_pair(
                   pair.call_id,
                   {pair.first_user_id, nil},
                   {pair.second_user_id, nil}
                 )

        assert_received_telemetry(handler_id, "reserve_pair", :accepted, nil)

        MediaFixtures.set_attempt_connecting!(pair.call_id)

        assert {:ok, _} =
                 AdmissionCoordinator.commit_pair(pair.call_id, reservation.generation)

        # `commit_pair/2` emits begin and publish steps before the outer event.
        assert_received_telemetry(handler_id, "begin_pair_commit", :accepted, nil)
        assert_received_telemetry(handler_id, "publish_pair_commit", :accepted, nil)
        assert_received_telemetry(handler_id, "commit_pair", :accepted, nil)

        assert :ok =
                 AdmissionCoordinator.cleanup_active_pair(pair.call_id, reservation.generation)

        assert_received_telemetry(handler_id, "cleanup_active_pair", :accepted, nil)
      after
        :telemetry.detach(handler_id)
      end
    end

    test "20-slot cap agrees with the UDP port range and boot validation" do
      assert DeploymentCapacity.max_active_sessions() == 20
      assert DeploymentCapacity.udp_port_range() == 50_000..50_031
      assert Range.size(50_000..50_031) >= 20

      assert DeploymentCapacity.valid_configuration?(50_000..50_031, 20)
      refute DeploymentCapacity.valid_configuration?(50_000..50_005, 20)
      assert :ok = DeploymentCapacity.validate_current_configuration()

      assert :ok = DeploymentCapacity.validate_configuration!(50_000..50_031, 20)

      assert_raise ArgumentError, fn ->
        DeploymentCapacity.validate_configuration!(50_000..50_005, 20)
      end
    end
  end

  defp pause_accept do
    parent = self()
    barrier = make_ref()

    Application.put_env(:discord_clone, :pair_accept_between_reserve_and_commit, fn ->
      send(parent, {:accept_reserved, barrier, self()})

      receive do
        {:resume_accept, ^barrier} -> :ok
      end
    end)

    barrier
  end

  defp pause_pair_publication do
    parent = self()
    barrier = make_ref()

    Application.put_env(:discord_clone, :pair_commit_fault, %{
      barrier: fn
        :before_publish ->
          send(parent, {:pair_before_publish, barrier, self()})

          receive do
            {:resume_publication, ^barrier} -> :ok
          end

        _ ->
          :ok
      end
    })

    barrier
  end

  defp command_gate(parent, gate, command) do
    send(parent, {:command_waiting, gate, command})

    receive do
      {:run_command, ^gate} -> :ok
    end
  end

  defp join_prior_voices(users, replacements, prefix) do
    users
    |> Enum.take(replacements)
    |> Map.new(fn user_id ->
      assert {:ok, _} = Voice.join(Ecto.UUID.generate(), user_id, "#{prefix}-prior", self())
      {user_id, AdmissionCoordinator.current_identity(user_id)}
    end)
  end

  defp assert_identities(identities) do
    for {user_id, identity} <- identities do
      assert AdmissionCoordinator.current_identity(user_id) == identity
    end
  end

  defp assert_public_pair(caller, recipient, call_id) do
    assert {:ok, %{state: :active}} = Calls.get_call(recipient, call_id)
    assert %{sessions: sessions} = AdmissionCoordinator.call_target_snapshot(call_id)
    assert Map.values(sessions) |> Enum.sort() == Enum.sort([caller.user.id, recipient.user.id])

    first = AdmissionCoordinator.current_identity(caller.user.id)
    second = AdmissionCoordinator.current_identity(recipient.user.id)
    assert first.target == Target.direct_call(call_id)
    assert second.target == Target.direct_call(call_id)
    assert sessions[first.session_id] == caller.user.id
    assert sessions[second.session_id] == recipient.user.id
    refute first.session_id == second.session_id
    assert first.runtime_generation == second.runtime_generation
    assert AdmissionCoordinator.reservation_count() == 0
  end

  defp fill_unrelated_slots(0, _prefix), do: %{}

  defp fill_unrelated_slots(count, prefix) when count > 0 do
    Map.new(1..count, fn index ->
      user_id = Ecto.UUID.generate()

      assert {:ok, _} =
               Voice.join(Ecto.UUID.generate(), user_id, "#{prefix}-#{index}", self())

      {user_id, AdmissionCoordinator.current_identity(user_id)}
    end)
  end

  defp attach_collector do
    test_pid = self()
    handler_id = "c12-cert-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        @event,
        fn event, measurements, metadata, _ ->
          send(test_pid, {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    {test_pid, handler_id}
  end

  defp assert_received_telemetry(handler_id, operation, outcome, error_code) do
    assert_receive {:telemetry_event, @event, measurements, metadata}, 1_000

    assert metadata.operation == operation
    assert metadata.outcome == outcome

    if is_nil(error_code) do
      assert Map.get(metadata, :error_code, nil) in [nil, error_code]
    else
      assert metadata.error_code == error_code
    end

    assert Map.keys(measurements) -- [:duration_ms, :occupancy, :reservation_count, :mailbox_len] ==
             []

    assert Map.keys(metadata) -- [:operation, :outcome, :error_code] == []

    for key <- [:duration_ms, :occupancy, :reservation_count, :mailbox_len] do
      case Map.fetch(measurements, key) do
        {:ok, value} ->
          assert is_integer(value)
          assert value >= 0
          assert value <= 1_000_000

        :error ->
          :ok
      end
    end

    assert metadata.operation in AdmissionDiagnostics.operations()
    _ = handler_id
    :ok
  end

  defp await_cert_coordinator_recovery(timeout_ms \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    await_cert_coordinator_until(deadline)
  end

  defp await_cert_coordinator_until(deadline) do
    case Process.whereis(DiscordClone.Voice.SessionCoordinator) do
      nil ->
        if System.monotonic_time(:millisecond) < deadline do
          :erlang.yield()
          await_cert_coordinator_until(deadline)
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
              await_cert_coordinator_until(deadline)
            else
              flunk("coordinator did not become ready after restart")
            end
        end
    end
  end
end
