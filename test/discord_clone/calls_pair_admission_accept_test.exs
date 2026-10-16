defmodule DiscordClone.CallsPairAdmissionAcceptTest do
  @moduledoc false
  use DiscordClone.DataCase, async: false

  import DiscordClone.CallsFixtures
  import Phoenix.ChannelTest

  alias DiscordClone.Accounts
  alias DiscordClone.Activities.ActivityItem
  alias DiscordClone.Calls
  alias DiscordClone.Calls.CallAttempt
  alias DiscordClone.Chat.Message
  alias DiscordClone.Friendships
  alias DiscordClone.Media.{AdmissionCoordinator, Target}
  alias DiscordClone.MediaFixtures
  alias DiscordClone.Repo
  alias DiscordClone.Voice
  alias DiscordCloneWeb.{CallSignaling, CallSocket}

  @endpoint DiscordCloneWeb.Endpoint

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

  describe "pair admission accept flow" do
    test "expired acceptance reservation returns the winning cancellation and preserves Voices" do
      pair = ringing_pair_in_voice("expired_accept_cancel")

      Application.put_env(:discord_clone, :pair_accept_between_reserve_and_commit, fn ->
        expire_accept_reservation(pair.call_id)

        assert {:ok, %{terminal_outcome: :cancelled}} =
                 Calls.cancel_call(pair.caller, pair.call_id)
      end)

      assert {:ok, %{state: :terminal, terminal_outcome: :cancelled} = terminal} =
               Calls.accept_call(pair.recipient, pair.call_id, :audio)

      assert {:ok, ^terminal} = Calls.get_call(pair.recipient, pair.call_id)
      assert_no_call_sessions(pair.call_id)
      assert AdmissionCoordinator.current_identity(pair.caller.user.id) == pair.caller_prior
      assert AdmissionCoordinator.current_identity(pair.recipient.user.id) == pair.recipient_prior
      assert {:error, :not_found} = AdmissionCoordinator.reservation_generation(pair.call_id)
    end

    test "reconciled acceptance returns the winning decline without releasing a newer reservation" do
      pair = ringing_pair_in_voice("reconcile_decline")
      abandon_accept_before_commit(pair)
      parent = self()

      Application.put_env(:discord_clone, :pair_accept_between_reserve_and_commit, fn ->
        expired_generation = expire_accept_reservation(pair.call_id)

        assert {:ok, reservation} =
                 AdmissionCoordinator.reserve_pair(
                   pair.call_id,
                   {pair.caller.user.id, pair.caller_prior},
                   {pair.recipient.user.id, pair.recipient_prior}
                 )

        assert {:ok, %{terminal_outcome: :declined}} =
                 Calls.decline_call(pair.recipient, pair.call_id)

        send(parent, {:replacement_reservation, expired_generation, reservation.generation})
      end)

      assert {:ok, %{state: :terminal, terminal_outcome: :declined} = terminal} =
               Calls.accept_call(pair.recipient, pair.call_id, :audio)

      assert {:ok, ^terminal} = Calls.get_call(pair.recipient, pair.call_id)
      assert_receive {:replacement_reservation, expired_generation, generation}
      refute expired_generation == generation
      assert {:ok, ^generation} = AdmissionCoordinator.reservation_generation(pair.call_id)
      assert_no_call_sessions(pair.call_id)
      assert AdmissionCoordinator.current_identity(pair.caller.user.id) == pair.caller_prior
      assert AdmissionCoordinator.current_identity(pair.recipient.user.id) == pair.recipient_prior
      assert :ok = AdmissionCoordinator.release_reservation(pair.call_id, generation)
    end

    for {path, outcome} <- [
          owner: :declined,
          owner: :timed_out,
          reconcile: :cancelled,
          reconcile: :timed_out
        ] do
      @path path
      @outcome outcome
      test "#{path} acceptance preserves the winning #{outcome} after reservation expiry" do
        pair = ringing_pair_in_voice("#{@path}_#{@outcome}")
        if @path == :reconcile, do: abandon_accept_before_commit(pair)

        Application.put_env(:discord_clone, :pair_accept_between_reserve_and_commit, fn ->
          expire_accept_reservation(pair.call_id)

          case @outcome do
            :declined ->
              assert {:ok, _} = Calls.decline_call(pair.recipient, pair.call_id)

            :cancelled ->
              assert {:ok, _} = Calls.cancel_call(pair.caller, pair.call_id)

            :timed_out ->
              make_ringing_deadline_due!(pair.call_id)
              assert {:ok, _} = Calls.expire_ringing_attempt(pair.call_id)
          end
        end)

        assert {:ok, %{state: :terminal, terminal_outcome: @outcome} = terminal} =
                 Calls.accept_call(pair.recipient, pair.call_id, :audio)

        assert {:ok, ^terminal} = Calls.get_call(pair.recipient, pair.call_id)
        assert_no_call_sessions(pair.call_id)
        assert AdmissionCoordinator.current_identity(pair.caller.user.id) == pair.caller_prior

        assert AdmissionCoordinator.current_identity(pair.recipient.user.id) ==
                 pair.recipient_prior

        assert {:error, :not_found} = AdmissionCoordinator.reservation_generation(pair.call_id)
      end
    end

    for path <- [:owner, :reconcile] do
      @path path
      test "#{path} acceptance fails closed when reservation cleanup is unavailable" do
        pair = ringing_pair_in_voice("unavailable_#{@path}")
        if @path == :reconcile, do: abandon_accept_before_commit(pair)
        coordinator_name = DiscordClone.Voice.SessionCoordinator
        coordinator = Process.whereis(coordinator_name)

        Application.put_env(:discord_clone, :pair_accept_between_reserve_and_commit, fn ->
          assert {:ok, %{terminal_outcome: :cancelled}} =
                   Calls.cancel_call(pair.caller, pair.call_id)

          # Remove only API availability; preserve the real coordinator and its identities.
          assert Process.unregister(coordinator_name)
        end)

        try do
          assert {:error, :temporarily_unavailable} =
                   Calls.accept_call(pair.recipient, pair.call_id, :audio)
        after
          if is_nil(Process.whereis(coordinator_name)),
            do: Process.register(coordinator, coordinator_name)
        end

        assert {:ok, %{state: :terminal, terminal_outcome: :cancelled}} =
                 Calls.get_call(pair.recipient, pair.call_id)

        assert_no_call_sessions(pair.call_id)
        assert AdmissionCoordinator.current_identity(pair.caller.user.id) == pair.caller_prior

        assert AdmissionCoordinator.current_identity(pair.recipient.user.id) ==
                 pair.recipient_prior

        assert {:ok, generation} = AdmissionCoordinator.reservation_generation(pair.call_id)
        assert :ok = AdmissionCoordinator.release_reservation(pair.call_id, generation)
      end
    end

    test "acceptance fails closed when a lost authorization race cannot release its reservation" do
      pair = ringing_pair_in_voice("release_auth_error")
      coordinator_name = DiscordClone.Voice.SessionCoordinator
      coordinator = Process.whereis(coordinator_name)

      Application.put_env(:discord_clone, :pair_accept_between_reserve_and_commit, fn ->
        assert :ok = Friendships.remove_friend(pair.recipient, pair.friendship.id)
        assert Process.unregister(coordinator_name)
      end)

      try do
        assert {:error, :temporarily_unavailable} =
                 Calls.accept_call(pair.recipient, pair.call_id, :audio)
      after
        if is_nil(Process.whereis(coordinator_name)),
          do: Process.register(coordinator, coordinator_name)
      end

      call_id = pair.call_id

      assert_receive {:call_relationship_ended,
                      %{call_id: ^call_id, terminal_outcome: :relationship_ended}}

      assert_receive {:call_relationship_ended,
                      %{call_id: ^call_id, terminal_outcome: :relationship_ended}}

      assert {:error, :not_found} = Calls.get_call(pair.recipient, pair.call_id)

      assert_no_call_sessions(pair.call_id)
      assert AdmissionCoordinator.current_identity(pair.caller.user.id) == pair.caller_prior
      assert AdmissionCoordinator.current_identity(pair.recipient.user.id) == pair.recipient_prior
      assert {:ok, generation} = AdmissionCoordinator.reservation_generation(pair.call_id)
      assert :ok = AdmissionCoordinator.release_reservation(pair.call_id, generation)
    end

    test "another active Call rejects acceptance directly and preserves both exact Voices" do
      {caller, recipient, call_id} = active_pair("accept_active_guard")
      existing = AdmissionCoordinator.call_target_snapshot(call_id)
      caller_identity = AdmissionCoordinator.current_identity(caller.user.id)
      recipient_identity = AdmissionCoordinator.current_identity(recipient.user.id)
      rejected = ringing_pair_in_voice("accept_active_reject")

      assert_capacity_rejection_preserves_voice(rejected)

      assert {:ok, %{state: :active}} = Calls.get_call(recipient, call_id)
      assert AdmissionCoordinator.call_target_snapshot(call_id) == existing
      assert AdmissionCoordinator.current_identity(caller.user.id) == caller_identity
      assert AdmissionCoordinator.current_identity(recipient.user.id) == recipient_identity
    end

    test "another reserved Call rejects acceptance directly without changing the held pair" do
      {caller, recipient, conversation, _} = direct_conversation_fixture("accept_reserved_guard")
      assert {:ok, %{call: ringing}} = Calls.start_call(caller, conversation.id, :audio)
      rejected = ringing_pair_in_voice("accept_reserved_reject")
      parent = self()
      barrier = make_ref()

      Application.put_env(:discord_clone, :pair_accept_between_reserve_and_commit, fn ->
        send(parent, {:accept_reserved, barrier, self()})

        receive do
          {:resume_accept, ^barrier} -> :ok
        end
      end)

      tasks = start_supervised!(Task.Supervisor)

      accept =
        Task.Supervisor.async_nolink(tasks, fn ->
          Calls.accept_call(recipient, ringing.call_id, :audio)
        end)

      on_exit(fn -> send(accept.pid, {:resume_accept, barrier}) end)

      try do
        assert_receive {:accept_reserved, ^barrier, _}, 2_000
        assert {:ok, generation} = AdmissionCoordinator.reservation_generation(ringing.call_id)
        existing = AdmissionCoordinator.call_target_snapshot(ringing.call_id)

        assert_capacity_rejection_preserves_voice(rejected)

        assert {:ok, ^generation} = AdmissionCoordinator.reservation_generation(ringing.call_id)
        assert AdmissionCoordinator.call_target_snapshot(ringing.call_id) == existing
        assert {:ok, %{state: :ringing}} = Calls.get_call(recipient, ringing.call_id)
        assert AdmissionCoordinator.current_identity(caller.user.id) == nil
        assert AdmissionCoordinator.current_identity(recipient.user.id) == nil
      after
        send(accept.pid, {:resume_accept, barrier})
      end

      assert {:ok, %{state: :connecting}} = Task.await(accept)
      assert eventually_active?(ringing.call_id)
    end

    test "another cleaning Call rejects acceptance directly while its peer Session survives" do
      {caller, recipient, call_id} = active_pair("accept_cleaning_guard")
      rejected = ringing_pair_in_voice("accept_cleaning_reject")

      [target] =
        for {_, pid, _, _} <-
              DynamicSupervisor.which_children(DiscordClone.Media.DirectCallTargetSupervisor),
            {:ok, %{call_id: ^call_id}} <- [DiscordClone.Media.DirectCallTarget.identity(pid)],
            do: pid

      {barrier, resume} = MediaFixtures.pause_after_first_call_removal(target)
      tasks = start_supervised!(Task.Supervisor)
      leave = Task.Supervisor.async_nolink(tasks, fn -> Calls.leave_call(caller, call_id) end)

      try do
        assert_receive {:first_call_session_removed, ^barrier}, 2_000
        existing = AdmissionCoordinator.call_target_snapshot(call_id)
        assert map_size(existing.sessions) == 1
        assert AdmissionCoordinator.effective_occupancy() == 3

        assert_capacity_rejection_preserves_voice(rejected)

        assert AdmissionCoordinator.call_target_snapshot(call_id) == existing
        assert AdmissionCoordinator.current_identity(caller.user.id) == nil
        assert AdmissionCoordinator.current_identity(recipient.user.id) == nil
      after
        resume.()
      end

      assert {:ok, %{state: :terminal, terminal_outcome: :ended}} = Task.await(leave)
      assert AdmissionCoordinator.effective_occupancy() == 2
      assert_no_call_sessions(call_id)
    end

    test "concurrent and repeated public acceptance of the same Call keeps one pair" do
      {caller, recipient, conversation, _} = direct_conversation_fixture("accept_same_call")
      assert {:ok, %{call: ringing}} = Calls.start_call(caller, conversation.id, :audio)
      call_id = ringing.call_id
      parent = self()
      barrier = make_ref()

      Application.put_env(:discord_clone, :pair_accept_between_reserve_and_commit, fn ->
        send(parent, {:accept_reserved, barrier})

        receive do
          {:resume_accept, ^barrier} -> :ok
        end
      end)

      tasks = start_supervised!(Task.Supervisor)

      first =
        Task.Supervisor.async_nolink(tasks, fn ->
          Calls.accept_call(recipient, call_id, :audio)
        end)

      on_exit(fn -> send(first.pid, {:resume_accept, barrier}) end)

      second =
        try do
          assert_receive {:accept_reserved, ^barrier}, 2_000
          assert {:ok, generation} = AdmissionCoordinator.reservation_generation(call_id)
          [{server, _}] = Registry.lookup(DiscordClone.Calls.CallRegistry, call_id)

          # Observe arrival only to hold the concurrency window deterministically.
          :ok =
            :sys.install(server, {
              fn
                state, {:in, {:"$gen_call", _, {:claim_answer_mode, _, _}}}, _ ->
                  send(parent, {:same_call_retry, barrier})
                  state

                state, _event, _ ->
                  state
              end,
              nil
            })

          retry =
            Task.Supervisor.async_nolink(tasks, fn ->
              Calls.accept_call(recipient, call_id, :audio)
            end)

          assert_receive {:same_call_retry, ^barrier}, 2_000
          assert {:ok, ^generation} = AdmissionCoordinator.reservation_generation(call_id)
          assert_no_call_sessions(call_id)
          assert {:ok, %{state: :ringing}} = Calls.get_call(recipient, call_id)
          retry
        after
          send(first.pid, {:resume_accept, barrier})
        end

      assert {:ok, %{state: :connecting, call_id: ^call_id}} = Task.await(first)
      assert {:ok, %{state: state, call_id: ^call_id}} = Task.await(second)
      assert state in [:connecting, :active]
      assert eventually_active?(call_id)
      assert {:ok, active} = Calls.get_call(recipient, call_id)
      existing = AdmissionCoordinator.call_target_snapshot(call_id)
      assert map_size(existing.sessions) == 2

      assert {:ok, ^active} = Calls.accept_call(recipient, call_id, :audio)
      assert AdmissionCoordinator.call_target_snapshot(call_id) == existing
      assert AdmissionCoordinator.effective_occupancy() == 2

      assert AdmissionCoordinator.current_identity(caller.user.id).target ==
               Target.direct_call(call_id)

      assert AdmissionCoordinator.current_identity(recipient.user.id).target ==
               Target.direct_call(call_id)
    end

    test "accept reserves before connecting, retires exact Voice, and publishes both Call Sessions" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("pair_accept_happy")

      first_channel = Ecto.UUID.generate()
      second_channel = Ecto.UUID.generate()

      assert {:ok, %{voice_session_id: first_voice_id}} =
               Voice.join(first_channel, caller_scope.user.id, "happy-caller", self())

      assert {:ok, %{voice_session_id: second_voice_id}} =
               Voice.join(second_channel, recipient_scope.user.id, "happy-recipient", self())

      first_prior = AdmissionCoordinator.current_identity(caller_scope.user.id)
      second_prior = AdmissionCoordinator.current_identity(recipient_scope.user.id)

      assert :ok = Calls.subscribe(caller_scope)
      assert :ok = Calls.subscribe(recipient_scope)
      messages_before = Repo.aggregate(Message, :count)
      activity_before = Repo.aggregate(ActivityItem, :count)

      assert {:ok, %{call: ringing}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      # Ringing creates no reservation and leaves Voice unchanged.
      assert {:error, :not_found} =
               AdmissionCoordinator.reservation_generation(ringing.call_id)

      assert {:ok, %{occupancy: 1}} = Voice.room_occupancy(first_channel)
      assert {:ok, %{occupancy: 1}} = Voice.room_occupancy(second_channel)

      assert_receive {:call_ringing, _}
      assert_receive {:call_ringing, _}

      assert {:ok, connecting} = Calls.accept_call(recipient_scope, ringing.call_id, :audio)
      assert connecting.state == :connecting
      assert connecting.call_id == ringing.call_id

      accepted_at = Repo.get!(CallAttempt, ringing.call_id).accepted_at
      assert %DateTime{} = accepted_at

      # Connecting is published only after the exact pair is reserved.
      assert_receive {:call_connecting, first_connecting}
      assert_receive {:call_connecting, second_connecting}
      assert first_connecting.call_id == ringing.call_id
      assert second_connecting.call_id == ringing.call_id

      # Voice retirement begins only after the durable connecting commit;
      # wait for the runtime adapter to finish the pair commit.
      assert eventually_active?(ringing.call_id)

      assert {:ok, active} = Calls.get_call(recipient_scope, ringing.call_id)
      assert active.state == :active
      assert Repo.get!(CallAttempt, ringing.call_id).accepted_at == accepted_at

      assert_receive {:call_active, first_active}
      assert_receive {:call_active, second_active}
      assert first_active.state == :active
      assert second_active.state == :active

      # Both exact prior Voice Sessions retired; both Call Sessions published together.
      assert {:ok, %{occupancy: 0}} = Voice.room_occupancy(first_channel)
      assert {:ok, %{occupancy: 0}} = Voice.room_occupancy(second_channel)

      caller_identity = AdmissionCoordinator.current_identity(caller_scope.user.id)
      recipient_identity = AdmissionCoordinator.current_identity(recipient_scope.user.id)

      assert caller_identity.target == Target.direct_call(ringing.call_id)
      assert recipient_identity.target == Target.direct_call(ringing.call_id)
      refute caller_identity.session_id in [first_voice_id, second_voice_id, ringing.call_id]
      refute recipient_identity.session_id in [first_voice_id, second_voice_id, ringing.call_id]
      refute caller_identity.session_id == recipient_identity.session_id

      assert %{sessions: sessions} =
               AdmissionCoordinator.call_target_snapshot(ringing.call_id)

      assert map_size(sessions) == 2

      # No missed Activity or Message for a successful pair.
      assert Repo.aggregate(ActivityItem, :count) == activity_before
      assert Repo.aggregate(Message, :count) == messages_before

      # Prior identities are gone; a second pair is blocked by the one-call guard.
      assert AdmissionCoordinator.current_identity(caller_scope.user.id) != first_prior
      assert AdmissionCoordinator.current_identity(recipient_scope.user.id) != second_prior
    end

    test "capacity rejection commits failed_capacity directly with no connecting event" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("pair_accept_cap")

      # 19 unrelated slots; the pair has no prior Voice credit (19 - 0 + 2 = 21).
      Enum.each(1..19, fn index ->
        assert {:ok, _} =
                 Voice.join(
                   Ecto.UUID.generate(),
                   Ecto.UUID.generate(),
                   "cap-fill-#{index}",
                   self()
                 )
      end)

      assert :ok = Calls.subscribe(caller_scope)
      assert :ok = Calls.subscribe(recipient_scope)
      messages_before = Repo.aggregate(Message, :count)
      activity_before = Repo.aggregate(ActivityItem, :count)

      assert {:ok, %{call: ringing}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      assert_receive {:call_ringing, _}
      assert_receive {:call_ringing, _}

      assert {:ok, terminal} = Calls.accept_call(recipient_scope, ringing.call_id, :audio)
      assert terminal.state == :terminal
      assert terminal.terminal_outcome == :failed_capacity

      reloaded = Repo.get!(CallAttempt, ringing.call_id)
      assert reloaded.state == :terminal
      assert reloaded.terminal_outcome == :failed_capacity
      assert %DateTime{} = reloaded.accepted_at
      assert %DateTime{} = reloaded.ended_at
      assert DateTime.compare(reloaded.ended_at, reloaded.accepted_at) != :lt

      # Direct projection with no intermediate connecting event.
      assert_receive {:call_failed_capacity, failed}
      assert failed.call_id == ringing.call_id
      assert failed.terminal_outcome == :failed_capacity
      refute_received {:call_connecting, _}
      refute_received {:call_active, _}

      # Both sides see the terminal; no Call Session is exposed.
      assert AdmissionCoordinator.current_identity(caller_scope.user.id) == nil
      assert AdmissionCoordinator.current_identity(recipient_scope.user.id) == nil
      assert_no_call_sessions(ringing.call_id)

      # Silent failure: no missed Activity or Message, existing dock copy preserved.
      assert Repo.aggregate(ActivityItem, :count) == activity_before
      assert Repo.aggregate(Message, :count) == messages_before

      # Capacity released: a later eligible pair can still reserve after cleanup.
      assert {:error, :not_found} =
               AdmissionCoordinator.reservation_generation(ringing.call_id)
    end

    test "lost durable race to decline releases the exact reservation" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("pair_accept_race")

      channel = Ecto.UUID.generate()

      assert {:ok, _} =
               Voice.join(channel, caller_scope.user.id, "race-caller", self())

      prior = AdmissionCoordinator.current_identity(caller_scope.user.id)

      assert {:ok, %{call: ringing}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      Application.put_env(
        :discord_clone,
        :pair_accept_between_reserve_and_commit,
        fn -> {:ok, _} = Calls.decline_call(recipient_scope, ringing.call_id) end
      )

      assert {:ok, terminal} = Calls.accept_call(recipient_scope, ringing.call_id, :audio)
      assert terminal.state == :terminal
      assert terminal.terminal_outcome == :declined

      # Exact reservation released; no Call Session exposed.
      assert {:error, :not_found} =
               AdmissionCoordinator.reservation_generation(ringing.call_id)

      assert_no_call_sessions(ringing.call_id)

      # Loser's Voice is untouched (decline is Voice-neutral).
      assert AdmissionCoordinator.current_identity(caller_scope.user.id) == prior
      assert {:ok, %{occupancy: 1}} = Voice.room_occupancy(channel)

      # A new pair can reserve after the release.
      other = MediaFixtures.ringing_pair_fixture()
      MediaFixtures.start_ready_call_target(other.call_id)

      assert {:ok, reservation} =
               AdmissionCoordinator.reserve_pair(
                 other.call_id,
                 {other.first_user_id, nil},
                 {other.second_user_id, nil}
               )

      assert :ok = AdmissionCoordinator.release_reservation(other.call_id, reservation.generation)
    end

    test "lost durable race to cancel releases the exact reservation" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("race_cancel")

      channel = Ecto.UUID.generate()

      assert {:ok, _} =
               Voice.join(channel, caller_scope.user.id, "race-cancel-caller", self())

      prior = AdmissionCoordinator.current_identity(caller_scope.user.id)

      assert {:ok, %{call: ringing}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      Application.put_env(
        :discord_clone,
        :pair_accept_between_reserve_and_commit,
        fn -> {:ok, _} = Calls.cancel_call(caller_scope, ringing.call_id) end
      )

      assert {:ok, terminal} = Calls.accept_call(recipient_scope, ringing.call_id, :audio)
      assert terminal.state == :terminal
      assert terminal.terminal_outcome == :cancelled

      assert {:error, :not_found} =
               AdmissionCoordinator.reservation_generation(ringing.call_id)

      assert_no_call_sessions(ringing.call_id)
      assert AdmissionCoordinator.current_identity(caller_scope.user.id) == prior
      assert {:ok, %{occupancy: 1}} = Voice.room_occupancy(channel)
    end

    test "lost durable race to timeout releases the exact reservation" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("race_timeout")

      channel = Ecto.UUID.generate()

      assert {:ok, _} =
               Voice.join(channel, caller_scope.user.id, "race-timeout-caller", self())

      prior = AdmissionCoordinator.current_identity(caller_scope.user.id)

      assert {:ok, %{call: ringing}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      Application.put_env(
        :discord_clone,
        :pair_accept_between_reserve_and_commit,
        fn ->
          make_ringing_deadline_due!(ringing.call_id)
          {:ok, _} = Calls.expire_ringing_attempt(ringing.call_id)
        end
      )

      assert {:ok, terminal} = Calls.accept_call(recipient_scope, ringing.call_id, :audio)
      assert terminal.state == :terminal
      assert terminal.terminal_outcome == :timed_out

      assert {:error, :not_found} =
               AdmissionCoordinator.reservation_generation(ringing.call_id)

      assert_no_call_sessions(ringing.call_id)
      assert AdmissionCoordinator.current_identity(caller_scope.user.id) == prior
      assert {:ok, %{occupancy: 1}} = Voice.room_occupancy(channel)
    end

    test "lost durable race to friendship removal releases the exact reservation" do
      {caller_scope, recipient_scope, direct_conversation, friendship} =
        direct_conversation_fixture("race_friend")

      channel = Ecto.UUID.generate()

      assert {:ok, _} =
               Voice.join(channel, caller_scope.user.id, "race-friend-caller", self())

      prior = AdmissionCoordinator.current_identity(caller_scope.user.id)

      assert {:ok, %{call: ringing}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      Application.put_env(
        :discord_clone,
        :pair_accept_between_reserve_and_commit,
        fn -> :ok = Friendships.remove_friend(recipient_scope, friendship.id) end
      )

      # Former-friend accepts return not_found per existing authorization
      # convention; the committed relationship_ended outcome is durable truth.
      assert {:error, :not_found} = Calls.accept_call(recipient_scope, ringing.call_id, :audio)

      assert %CallAttempt{state: :terminal, terminal_outcome: :relationship_ended} =
               Repo.get!(CallAttempt, ringing.call_id)

      assert {:error, :not_found} =
               AdmissionCoordinator.reservation_generation(ringing.call_id)

      assert_no_call_sessions(ringing.call_id)
      assert AdmissionCoordinator.current_identity(caller_scope.user.id) == prior
      assert {:ok, %{occupancy: 1}} = Voice.room_occupancy(channel)
    end

    test "generic postcommit failure commits failed and cleans both sides without Voice restore" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("pair_accept_fail")

      first_channel = Ecto.UUID.generate()
      second_channel = Ecto.UUID.generate()

      assert {:ok, _} = Voice.join(first_channel, caller_scope.user.id, "fail-caller", self())

      assert {:ok, _} =
               Voice.join(second_channel, recipient_scope.user.id, "fail-recipient", self())

      assert :ok = Calls.subscribe(caller_scope)
      assert :ok = Calls.subscribe(recipient_scope)
      messages_before = Repo.aggregate(Message, :count)
      activity_before = Repo.aggregate(ActivityItem, :count)

      assert {:ok, %{call: ringing}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      assert_receive {:call_ringing, _}
      assert_receive {:call_ringing, _}

      Application.put_env(:discord_clone, :pair_commit_fault, %{
        admit_failures: [recipient_scope.user.id]
      })

      assert {:ok, connecting} = Calls.accept_call(recipient_scope, ringing.call_id, :audio)
      assert connecting.state == :connecting
      assert_receive {:call_connecting, _}
      assert_receive {:call_connecting, _}

      assert eventually_terminal?(ringing.call_id, :failed)

      failed = Repo.get!(CallAttempt, ringing.call_id)
      assert failed.state == :terminal
      assert failed.terminal_outcome == :failed

      assert_receive {:call_failed, payload}
      assert payload.call_id == ringing.call_id

      # Both Call sides cleaned; Voice is never restored automatically.
      assert AdmissionCoordinator.current_identity(caller_scope.user.id) == nil
      assert AdmissionCoordinator.current_identity(recipient_scope.user.id) == nil
      assert {:ok, %{occupancy: 0}} = Voice.room_occupancy(first_channel)
      assert {:ok, %{occupancy: 0}} = Voice.room_occupancy(second_channel)

      snapshot = AdmissionCoordinator.call_target_snapshot(ringing.call_id)
      assert snapshot == nil or snapshot.sessions == %{}

      assert Repo.aggregate(ActivityItem, :count) == activity_before
      assert Repo.aggregate(Message, :count) == messages_before
    end

    test "repeated acceptance returns current result without a second switch" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("pair_accept_repeat")

      assert {:ok, %{call: ringing}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      assert {:ok, connecting} = Calls.accept_call(recipient_scope, ringing.call_id, :audio)
      assert connecting.state == :connecting
      accepted_at = Repo.get!(CallAttempt, ringing.call_id).accepted_at

      assert {:ok, again} = Calls.accept_call(recipient_scope, ringing.call_id, :audio)
      assert again.state in [:connecting, :active]
      assert again.call_id == ringing.call_id
      assert Repo.get!(CallAttempt, ringing.call_id).accepted_at == accepted_at

      assert eventually_active?(ringing.call_id)

      snapshot_before = AdmissionCoordinator.call_target_snapshot(ringing.call_id)
      assert map_size(snapshot_before.sessions) == 2

      assert {:ok, active_again} = Calls.accept_call(recipient_scope, ringing.call_id, :audio)
      assert active_again.state == :active
      assert Repo.get!(CallAttempt, ringing.call_id).accepted_at == accepted_at

      snapshot_after = AdmissionCoordinator.call_target_snapshot(ringing.call_id)
      assert snapshot_after.sessions == snapshot_before.sessions
      assert snapshot_after.runtime_generation == snapshot_before.runtime_generation
    end

    test "ringing creates no reservation and decline stays Voice-neutral" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("pair_accept_ring")

      channel = Ecto.UUID.generate()

      assert {:ok, _} = Voice.join(channel, caller_scope.user.id, "ring-voice", self())
      prior = AdmissionCoordinator.current_identity(caller_scope.user.id)

      assert {:ok, %{call: ringing}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      assert {:error, :not_found} =
               AdmissionCoordinator.reservation_generation(ringing.call_id)

      assert AdmissionCoordinator.current_identity(caller_scope.user.id) == prior
      assert {:ok, %{occupancy: 1}} = Voice.room_occupancy(channel)

      assert {:ok, declined} = Calls.decline_call(recipient_scope, ringing.call_id)
      assert declined.terminal_outcome == :declined

      assert AdmissionCoordinator.current_identity(caller_scope.user.id) == prior
      assert {:ok, %{occupancy: 1}} = Voice.room_occupancy(channel)

      assert {:error, :not_found} =
               AdmissionCoordinator.reservation_generation(ringing.call_id)
    end
  end

  describe "call channel pair admission" do
    test "both users and sibling tabs observe connecting then active with exact media" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("pair_chan_happy")

      first_channel = Ecto.UUID.generate()
      second_channel = Ecto.UUID.generate()

      assert {:ok, _} = Voice.join(first_channel, caller_scope.user.id, "chan-caller", self())

      assert {:ok, _} =
               Voice.join(second_channel, recipient_scope.user.id, "chan-recipient", self())

      assert {:ok, %{call: ringing}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      %{socket: caller_socket} = connect_calls_socket(caller_scope.user)

      %{socket: recipient_socket, token: recipient_token} =
        connect_calls_socket(recipient_scope.user)

      topic = CallSignaling.call_topic(ringing.call_id)

      assert {:ok, _caller_payload, _caller_channel} =
               subscribe_and_join(caller_socket, topic)

      assert {:ok, _recipient_payload, recipient_channel} =
               subscribe_and_join(recipient_socket, topic)

      # Sibling tab for the recipient.
      sibling_socket = connect_authenticated_socket(recipient_token)

      assert {:ok, _sibling_payload, _sibling_channel} =
               subscribe_and_join(sibling_socket, topic)

      ref =
        push(recipient_channel, "accept_call", %{
          "signaling_session_id" => recipient_channel.assigns.signaling_session_id,
          "call_id" => ringing.call_id,
          "answer_mode" => "audio"
        })

      assert_reply ref, :ok, %{call: connecting}
      assert connecting.state == :connecting

      assert_push "call_connecting", %{call: %{call_id: call_id}}
      assert call_id == ringing.call_id

      assert eventually_active?(ringing.call_id)
      assert_push "call_active", %{call: %{call_id: active_id, state: :active}}
      assert active_id == ringing.call_id

      assert AdmissionCoordinator.current_identity(caller_scope.user.id).target ==
               Target.direct_call(ringing.call_id)

      assert AdmissionCoordinator.current_identity(recipient_scope.user.id).target ==
               Target.direct_call(ringing.call_id)

      assert {:ok, %{occupancy: 0}} = Voice.room_occupancy(first_channel)
      assert {:ok, %{occupancy: 0}} = Voice.room_occupancy(second_channel)
    end

    test "capacity rejection projects failed_capacity directly to both users and sibling tabs" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("pair_chan_cap")

      Enum.each(1..19, fn index ->
        assert {:ok, _} =
                 Voice.join(
                   Ecto.UUID.generate(),
                   Ecto.UUID.generate(),
                   "chan-cap-#{index}",
                   self()
                 )
      end)

      assert {:ok, %{call: ringing}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      %{socket: caller_socket} = connect_calls_socket(caller_scope.user)

      %{socket: recipient_socket, token: recipient_token} =
        connect_calls_socket(recipient_scope.user)

      topic = CallSignaling.call_topic(ringing.call_id)

      assert {:ok, _caller_payload, _caller_channel} =
               subscribe_and_join(caller_socket, topic)

      assert {:ok, _recipient_payload, recipient_channel} =
               subscribe_and_join(recipient_socket, topic)

      sibling_socket = connect_authenticated_socket(recipient_token)

      assert {:ok, _sibling_payload, _sibling_channel} =
               subscribe_and_join(sibling_socket, topic)

      ref =
        push(recipient_channel, "accept_call", %{
          "signaling_session_id" => recipient_channel.assigns.signaling_session_id,
          "call_id" => ringing.call_id,
          "answer_mode" => "audio"
        })

      assert_reply ref, :ok, %{call: terminal}
      assert terminal.state == :terminal
      assert terminal.terminal_outcome == :failed_capacity

      # Direct terminal projection with no intermediate connecting event.
      assert_push "call_error", %{call: %{terminal_outcome: :failed_capacity}}
      refute_push "call_connecting", _
      refute_push "call_active", _

      reloaded = Repo.get!(CallAttempt, ringing.call_id)
      assert reloaded.terminal_outcome == :failed_capacity
      assert %DateTime{} = reloaded.accepted_at
    end

    test "concurrent reserve race never commits terminal failed and winner can still proceed" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("pair_conc_race")

      assert {:ok, %{call: ringing}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      call_id = ringing.call_id
      caller_id = caller_scope.user.id
      recipient_id = recipient_scope.user.id
      coordinator = DiscordClone.Voice.SessionCoordinator

      _target = MediaFixtures.start_ready_call_target(call_id)
      _ = :sys.get_state(coordinator)

      # First holder wins the reservation directly.
      assert {:ok, %{generation: _generation}} =
               AdmissionCoordinator.reserve_pair(call_id, {caller_id, nil}, {recipient_id, nil})

      _ = :sys.get_state(coordinator)

      # Second concurrent accept while ringing+reserved must not commit
      # durable `failed`. It falls through to durable truth and never kills
      # the winner; the held reservation lets the pair still proceed to
      # active.
      assert {:ok, %{state: :connecting}} = Calls.accept_call(recipient_scope, call_id, :audio)
      _ = :sys.get_state(coordinator)

      reloaded = Repo.get!(CallAttempt, call_id)
      refute reloaded.state == :terminal and reloaded.terminal_outcome == :failed

      assert eventually_active?(call_id)

      reloaded_active = Repo.get!(CallAttempt, call_id)
      assert reloaded_active.state == :active
      assert reloaded_active.terminal_outcome == nil

      existing = AdmissionCoordinator.call_target_snapshot(call_id)
      assert map_size(existing.sessions) == 2
      assert {:ok, %{state: :active}} = Calls.accept_call(recipient_scope, call_id, :audio)
      assert AdmissionCoordinator.call_target_snapshot(call_id) == existing
      assert AdmissionCoordinator.effective_occupancy() == 2
    end
  end

  # Shared polling helpers (`eventually_active?/2`, `eventually_terminal?/3`,
  # `poll_until/3`, `flush_call_server/1`, `assert_no_call_sessions/1`) live in
  # `DiscordClone.CallsFixtures` (imported above). Socket helpers stay
  # per-file for the ChannelTest `connect/3` context.
  defp active_pair(suffix) do
    {caller, recipient, conversation, _} = direct_conversation_fixture(suffix)
    assert {:ok, %{call: ringing}} = Calls.start_call(caller, conversation.id, :audio)
    assert {:ok, %{state: :connecting}} = Calls.accept_call(recipient, ringing.call_id, :audio)
    assert eventually_active?(ringing.call_id)
    {caller, recipient, ringing.call_id}
  end

  defp expire_accept_reservation(call_id) do
    assert {:ok, generation} = AdmissionCoordinator.reservation_generation(call_id)

    send(
      Process.whereis(DiscordClone.Voice.SessionCoordinator),
      {:reservation_expired, call_id, generation}
    )

    assert {:error, :not_found} = AdmissionCoordinator.reservation_generation(call_id)
    generation
  end

  defp abandon_accept_before_commit(pair) do
    parent = self()
    barrier = make_ref()

    Application.put_env(:discord_clone, :pair_accept_between_reserve_and_commit, fn ->
      send(parent, {:abandon_accept, barrier})

      receive do
        {:resume_accept, ^barrier} -> :ok
      end
    end)

    tasks = start_supervised!(Task.Supervisor)

    owner =
      Task.Supervisor.async_nolink(tasks, fn ->
        Calls.accept_call(pair.recipient, pair.call_id, :audio)
      end)

    try do
      assert_receive {:abandon_accept, ^barrier}, 2_000
      expire_accept_reservation(pair.call_id)
    after
      Task.shutdown(owner, :brutal_kill)
    end

    flush_call_server(pair.call_id)
    assert {:ok, %{state: :ringing}} = Calls.get_call(pair.recipient, pair.call_id)
  end

  defp ringing_pair_in_voice(suffix) do
    {caller, recipient, conversation, friendship} = direct_conversation_fixture(suffix)
    channels = [Ecto.UUID.generate(), Ecto.UUID.generate()]

    for {scope, channel} <- Enum.zip([caller, recipient], channels) do
      assert {:ok, _} = Voice.join(channel, scope.user.id, suffix, self())
      assert :ok = Calls.subscribe(scope)
    end

    assert {:ok, %{call: ringing}} = Calls.start_call(caller, conversation.id, :audio)
    call_id = ringing.call_id
    assert_receive {:call_ringing, %{call_id: ^call_id}}
    assert_receive {:call_ringing, %{call_id: ^call_id}}

    %{
      caller: caller,
      recipient: recipient,
      friendship: friendship,
      call_id: call_id,
      channels: channels,
      caller_prior: AdmissionCoordinator.current_identity(caller.user.id),
      recipient_prior: AdmissionCoordinator.current_identity(recipient.user.id)
    }
  end

  defp assert_capacity_rejection_preserves_voice(pair) do
    call_id = pair.call_id
    occupancy = AdmissionCoordinator.effective_occupancy()

    assert {:ok, %{state: :terminal, terminal_outcome: :failed_capacity} = terminal} =
             Calls.accept_call(pair.recipient, call_id, :audio)

    assert {:ok, ^terminal} = Calls.get_call(pair.recipient, call_id)
    assert_receive {:call_failed_capacity, %{call_id: ^call_id}}
    assert_receive {:call_failed_capacity, %{call_id: ^call_id}}
    refute_received {:call_connecting, %{call_id: ^call_id}}
    refute_received {:call_active, %{call_id: ^call_id}}

    assert {:error, :not_found} = AdmissionCoordinator.reservation_generation(call_id)
    assert_no_call_sessions(call_id)
    assert AdmissionCoordinator.current_identity(pair.caller.user.id) == pair.caller_prior
    assert AdmissionCoordinator.current_identity(pair.recipient.user.id) == pair.recipient_prior
    assert AdmissionCoordinator.effective_occupancy() == occupancy

    for channel <- pair.channels do
      assert {:ok, %{occupancy: 1}} = Voice.room_occupancy(channel)
    end
  end

  defp connect_calls_socket(user) do
    token = Accounts.generate_user_session_token(user)

    %{
      socket: connect_authenticated_socket(token),
      token: token,
      scope: DiscordClone.Accounts.Scope.for_user(user)
    }
  end

  defp connect_authenticated_socket(token) do
    assert {:ok, socket} =
             connect(CallSocket, %{}, connect_info: %{session: %{"user_token" => token}})

    socket
  end
end
