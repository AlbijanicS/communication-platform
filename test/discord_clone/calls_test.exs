defmodule DiscordClone.CallsTest do
  use DiscordClone.DataCase, async: false

  import DiscordClone.AccountsFixtures
  import DiscordClone.CallsFixtures

  alias DiscordClone.Activities.ActivityItem
  alias DiscordClone.Calls
  alias DiscordClone.Calls.{CallAttempt, CallServer}
  alias DiscordClone.Chat
  alias DiscordClone.Friendships
  alias DiscordClone.Friendships.Relationship
  alias DiscordClone.Presence
  alias DiscordClone.Repo
  alias DiscordClone.Voice

  setup do
    start_supervised!(DiscordClone.Calls.Supervisor)
    DiscordClone.Calls.CallCoordinator.begin_recovery()
    await_recovery_finished()

    on_exit(fn ->
      DiscordClone.Voice.running_room_servers()
      |> Enum.each(fn {voice_channel_id, _room_server} ->
        :ok = Voice.end_channel_sessions(voice_channel_id)
        :ok = Voice.expire_idle_room(voice_channel_id)
      end)
    end)

    :ok
  end

  describe "start_call/3" do
    test "starts one durable ringing Call Attempt for current Friends without moving Voice or media" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("calls_start")

      voice_channel_id = Ecto.UUID.generate()

      assert {:ok, %{voice_session_id: voice_session_id}} =
               Voice.join(voice_channel_id, caller_scope.user.id, "caller-voice", self())

      assert :ok = Calls.subscribe(caller_scope)
      assert :ok = Calls.subscribe(recipient_scope)

      running_peer_connections_before =
        ExWebRTC.PeerConnection.get_all_running()
        |> MapSet.new()

      assert {:ok, %{call: call, started?: true}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      assert call.call_id
      assert call.direct_conversation_id == direct_conversation.id
      assert call.caller_user_id == caller_scope.user.id
      assert call.recipient_user_id == recipient_scope.user.id
      assert call.media_intent == :audio
      assert call.state == :ringing
      assert DateTime.diff(call.ringing_deadline_at, call.started_at, :second) == 30
      refute contains_pid?(call)
      assert_call_server_ready(call.call_id)

      assert {:ok, reloaded} = Calls.get_call(recipient_scope, call.call_id)
      assert reloaded == call

      assert_receive {:call_ringing, first_projection}
      assert_receive {:call_ringing, second_projection}

      assert MapSet.new([first_projection.call_id, second_projection.call_id]) ==
               MapSet.new([call.call_id])

      refute contains_pid?(first_projection)
      refute contains_pid?(second_projection)

      assert {:ok, %{members: [%{user_id: caller_user_id}]}} =
               Voice.voice_channel_roster(voice_channel_id)

      assert caller_user_id == caller_scope.user.id

      assert :ok = Voice.leave(voice_channel_id, voice_session_id)

      assert ExWebRTC.PeerConnection.get_all_running()
             |> MapSet.new()
             |> MapSet.difference(running_peer_connections_before)
             |> MapSet.size() == 0

      assert Repo.aggregate(from(attempt in "call_attempts"), :count) == 1
    end

    test "establishes CallServer readiness before publishing a ringing projection" do
      {caller_scope, _recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("calls_ready")

      parent = self()

      start_supervised!(
        {Task,
         fn ->
           :ok = Calls.subscribe(caller_scope)
           send(parent, :observer_subscribed)

           receive do
             {:call_ringing, projection} ->
               registry_lookup =
                 Registry.lookup(DiscordClone.Calls.CallRegistry, projection.call_id)

               ready = CallServer.await_ready(projection.call_id)

               server_state =
                 :sys.get_state(
                   {:via, Registry, {DiscordClone.Calls.CallRegistry, projection.call_id}}
                 )

               send(parent, {:ringing_at_broadcast, registry_lookup, ready, server_state})
           end
         end}
      )

      assert_receive :observer_subscribed

      assert {:ok, %{call: call}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      assert_receive {:ringing_at_broadcast, [{pid, _}], :ok, server_state}
      assert is_pid(pid)
      assert server_state.call_attempt.id == call.call_id
      assert_call_server_ready(call.call_id)
    end

    test "accepts video intent for an offline current Friend without consulting Presence" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("calls_video")

      assert :ok = Presence.subscribe_to_friend(caller_scope, recipient_scope.user.id)
      assert {:ok, :offline} = Presence.friend_status(caller_scope, recipient_scope.user.id)
      assert {:ok, []} = Presence.list_online_friend_ids(caller_scope)
      assert :ok = Calls.subscribe(recipient_scope)

      assert {:ok, %{call: call, started?: true}} =
               Calls.start_call(caller_scope, direct_conversation.id, "video")

      assert call.media_intent == :video
      assert call.state == :ringing
      assert_call_server_ready(call.call_id)

      assert_receive {:call_ringing, projection}
      assert projection.call_id == call.call_id
      assert projection.recipient_user_id == recipient_scope.user.id

      assert {:ok, :offline} = Presence.friend_status(caller_scope, recipient_scope.user.id)
      assert {:ok, []} = Presence.list_online_friend_ids(caller_scope)
      refute_received {:friend_presence_changed, _}
    end

    test "rejects unauthenticated, forged, invalid, and former-Friend starts without persistence" do
      {caller_scope, recipient_scope, direct_conversation, friendship} =
        direct_conversation_fixture("calls_rejected")

      outsider_scope = user_scope_fixture(user_fixture(username: "calls_rejected_outsider"))

      assert {:error, :unauthenticated} =
               Calls.start_call(nil, direct_conversation.id, :audio)

      assert {:error, :invalid_media_intent} =
               Calls.start_call(caller_scope, direct_conversation.id, :screen)

      assert {:error, :not_found} =
               Calls.start_call(outsider_scope, direct_conversation.id, :audio)

      assert :ok = Friendships.remove_friend(recipient_scope, friendship.id)

      assert {:error, :not_friends} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      assert Repo.aggregate(from(attempt in "call_attempts"), :count) == 0
    end

    test "fails closed when CallServer cannot become ready so a later start is not busy" do
      {caller_scope, _recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("calls_fail_closed")

      assert :ok = Calls.subscribe(caller_scope)

      assert :ok =
               Supervisor.terminate_child(
                 DiscordClone.Calls.Supervisor,
                 DiscordClone.Calls.CallSupervisor
               )

      assert {:error, :temporarily_unavailable} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      refute_received {:call_ringing, _}

      assert [%CallAttempt{state: :terminal, terminal_outcome: :failed}] =
               Repo.all(CallAttempt)

      assert {:ok, _pid} =
               Supervisor.restart_child(
                 DiscordClone.Calls.Supervisor,
                 DiscordClone.Calls.CallSupervisor
               )

      assert {:ok, %{call: call, started?: true}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      assert call.state == :ringing
      assert_call_server_ready(call.call_id)
      assert_receive {:call_ringing, %{call_id: call_id}}
      assert call_id == call.call_id
    end

    test "retries against the same ringing Direct Conversation return the existing Call ID" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("calls_converge")

      assert :ok = Calls.subscribe(caller_scope)
      assert :ok = Calls.subscribe(recipient_scope)

      attempts_before = Repo.aggregate(CallAttempt, :count)
      activity_before = Repo.aggregate(DiscordClone.Activities.ActivityItem, :count)

      assert {:ok, %{call: first, started?: true}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      assert_receive {:call_ringing, _}
      assert_receive {:call_ringing, _}

      assert {:ok, %{call: second, started?: false}} =
               Calls.start_call(caller_scope, direct_conversation.id, :video)

      assert second.call_id == first.call_id
      assert second.media_intent == :audio
      assert second.state == :ringing
      assert second.ringing_deadline_at == first.ringing_deadline_at
      assert second.caller_user_id == caller_scope.user.id
      assert second.recipient_user_id == recipient_scope.user.id

      refute_received {:call_ringing, _}
      assert Repo.aggregate(CallAttempt, :count) == attempts_before + 1
      assert Repo.aggregate(DiscordClone.Activities.ActivityItem, :count) == activity_before
      assert Registry.count(DiscordClone.Calls.CallRegistry) == 1
      assert_call_server_ready(first.call_id)
    end

    test "simultaneous opposite-direction starts converge on one ringing Call ID" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("calls_opposite")

      parent = self()
      attempts_before = Repo.aggregate(CallAttempt, :count)
      activity_before = Repo.aggregate(DiscordClone.Activities.ActivityItem, :count)

      start_supervised!(%{
        id: :opposite_start_caller,
        restart: :temporary,
        start:
          {Task, :start_link,
           [
             fn ->
               send(
                 parent,
                 {:caller_result, Calls.start_call(caller_scope, direct_conversation.id, :audio)}
               )
             end
           ]}
      })

      start_supervised!(%{
        id: :opposite_start_recipient,
        restart: :temporary,
        start:
          {Task, :start_link,
           [
             fn ->
               send(
                 parent,
                 {:recipient_result,
                  Calls.start_call(recipient_scope, direct_conversation.id, :video)}
               )
             end
           ]}
      })

      assert_receive {:caller_result, {:ok, %{call: caller_call, started?: caller_started?}}},
                     1_000

      assert_receive {:recipient_result,
                      {:ok, %{call: recipient_call, started?: recipient_started?}}},
                     1_000

      assert caller_call.call_id == recipient_call.call_id
      assert MapSet.new([caller_started?, recipient_started?]) == MapSet.new([true, false])
      assert caller_call.ringing_deadline_at == recipient_call.ringing_deadline_at
      assert caller_call.media_intent == recipient_call.media_intent
      assert Repo.aggregate(CallAttempt, :count) == attempts_before + 1
      assert Repo.aggregate(DiscordClone.Activities.ActivityItem, :count) == activity_before
      assert Registry.count(DiscordClone.Calls.CallRegistry) == 1
      assert_call_server_ready(caller_call.call_id)
    end

    test "converges on a durable ringing Call Attempt when coordinator occupancy is cold" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("calls_postgres_wins")

      assert :ok = Calls.subscribe(caller_scope)
      started_at = DateTime.utc_now(:microsecond)
      ringing_deadline_at = DateTime.add(started_at, 30, :second)
      activity_before = Repo.aggregate(DiscordClone.Activities.ActivityItem, :count)

      assert {:ok, existing} =
               %CallAttempt{}
               |> CallAttempt.create_changeset(%{
                 direct_conversation_id: direct_conversation.id,
                 caller_user_id: caller_scope.user.id,
                 recipient_user_id: recipient_scope.user.id,
                 media_intent: :audio,
                 state: :ringing,
                 ringing_deadline_at: ringing_deadline_at
               })
               |> Ecto.Changeset.put_change(:inserted_at, started_at)
               |> Ecto.Changeset.put_change(:updated_at, started_at)
               |> Repo.insert()

      assert {:ok, %{call: call, started?: false}} =
               Calls.start_call(caller_scope, direct_conversation.id, :video)

      assert call.call_id == existing.id
      assert call.media_intent == :audio
      assert call.ringing_deadline_at == ringing_deadline_at
      refute_received {:call_ringing, _}
      assert Repo.aggregate(CallAttempt, :count) == 1
      assert Repo.aggregate(DiscordClone.Activities.ActivityItem, :count) == activity_before
      assert Registry.count(DiscordClone.Calls.CallRegistry) == 0
    end

    test "returns busy when either User belongs to a different pair's nonterminal attempt" do
      {alice_scope, bob_scope, alice_bob, _friendship} =
        direct_conversation_fixture("calls_busy_ab")

      carol_scope = user_scope_fixture(user_fixture(username: "calls_busy_carol"))
      dave_scope = user_scope_fixture(user_fixture(username: "calls_busy_dave"))

      {alice_carol, _alice_carol_friendship} =
        befriend_and_open_direct_conversation(alice_scope, carol_scope)

      {bob_dave, _bob_dave_friendship} =
        befriend_and_open_direct_conversation(bob_scope, dave_scope)

      assert :ok = Calls.subscribe(alice_scope)
      assert :ok = Calls.subscribe(carol_scope)
      assert :ok = Calls.subscribe(dave_scope)

      activity_before = Repo.aggregate(DiscordClone.Activities.ActivityItem, :count)

      assert {:ok, %{call: ringing, started?: true}} =
               Calls.start_call(alice_scope, alice_bob.id, :audio)

      coordinator = :sys.get_state(DiscordClone.Calls.CallCoordinator)
      assert coordinator.calls_by_user[alice_scope.user.id] == ringing.call_id
      assert coordinator.calls_by_user[bob_scope.user.id] == ringing.call_id
      assert coordinator.calls_by_direct_conversation[alice_bob.id] == ringing.call_id

      assert_receive {:call_ringing, %{call_id: ringing_id}}
      assert ringing_id == ringing.call_id

      assert {:error, :busy} = Calls.start_call(alice_scope, alice_carol.id, :audio)
      assert {:error, :busy} = Calls.start_call(carol_scope, alice_carol.id, :audio)
      assert {:error, :busy} = Calls.start_call(bob_scope, bob_dave.id, :audio)

      refute_received {:call_ringing, _}
      assert Repo.aggregate(CallAttempt, :count) == 1
      assert Repo.aggregate(DiscordClone.Activities.ActivityItem, :count) == activity_before
      assert Registry.count(DiscordClone.Calls.CallRegistry) == 1
      assert_call_server_ready(ringing.call_id)
      assert {:ok, ^ringing} = Calls.get_call(alice_scope, ringing.call_id)
    end

    test "rate-limits the sixth persisted start by the same caller in a rolling minute" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("calls_rate_starts")

      assert :ok = Calls.subscribe(caller_scope)
      activity_before = Repo.aggregate(DiscordClone.Activities.ActivityItem, :count)
      now = DateTime.utc_now(:microsecond)

      for offset <- 0..4 do
        insert_call_attempt(caller_scope, recipient_scope, direct_conversation, %{
          inserted_at: DateTime.add(now, -offset, :second),
          accepted_at: DateTime.add(now, -offset, :second),
          terminal_outcome: :ended
        })
      end

      assert {:error, :rate_limited} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      refute_received {:call_ringing, _}
      assert Repo.aggregate(CallAttempt, :count) == 5
      assert Repo.aggregate(DiscordClone.Activities.ActivityItem, :count) == activity_before
      assert Registry.count(DiscordClone.Calls.CallRegistry) == 0
    end

    test "allows a new start once prior caller starts fall outside the rolling minute" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("calls_rate_swin")

      now = DateTime.utc_now(:microsecond)

      for offset <- 61..65 do
        insert_call_attempt(caller_scope, recipient_scope, direct_conversation, %{
          inserted_at: DateTime.add(now, -offset, :second),
          accepted_at: DateTime.add(now, -offset, :second),
          terminal_outcome: :ended
        })
      end

      assert {:ok, %{call: call, started?: true}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      assert call.state == :ringing
      assert_call_server_ready(call.call_id)
    end

    test "rate-limits a fourth unanswered caller-to-recipient attempt in five minutes" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("calls_rate_unanswered")

      assert :ok = Calls.subscribe(caller_scope)
      activity_before = Repo.aggregate(DiscordClone.Activities.ActivityItem, :count)
      now = DateTime.utc_now(:microsecond)

      for offset <- 0..2 do
        insert_call_attempt(caller_scope, recipient_scope, direct_conversation, %{
          inserted_at: DateTime.add(now, -offset, :second),
          terminal_outcome: :declined
        })
      end

      assert {:error, :rate_limited} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      refute_received {:call_ringing, _}
      assert Repo.aggregate(CallAttempt, :count) == 3
      assert Repo.aggregate(DiscordClone.Activities.ActivityItem, :count) == activity_before
      assert Registry.count(DiscordClone.Calls.CallRegistry) == 0
    end

    test "allows a new unanswered attempt once prior pair attempts fall outside five minutes" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("calls_rate_uwin")

      now = DateTime.utc_now(:microsecond)

      for offset <- 301..303 do
        insert_call_attempt(caller_scope, recipient_scope, direct_conversation, %{
          inserted_at: DateTime.add(now, -offset, :second),
          terminal_outcome: :declined
        })
      end

      assert {:ok, %{call: call, started?: true}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      assert call.state == :ringing
      assert_call_server_ready(call.call_id)
    end

    test "does not consume a rate-limit slot or reject a same-pair convergence at the start limit" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("calls_rate_converge")

      assert :ok = Calls.subscribe(caller_scope)
      now = DateTime.utc_now(:microsecond)

      for offset <- 1..4 do
        insert_call_attempt(caller_scope, recipient_scope, direct_conversation, %{
          inserted_at: DateTime.add(now, -offset, :second),
          accepted_at: DateTime.add(now, -offset, :second),
          terminal_outcome: :ended
        })
      end

      started_at = now
      ringing_deadline_at = DateTime.add(started_at, 30, :second)

      assert {:ok, existing} =
               %CallAttempt{}
               |> CallAttempt.create_changeset(%{
                 direct_conversation_id: direct_conversation.id,
                 caller_user_id: caller_scope.user.id,
                 recipient_user_id: recipient_scope.user.id,
                 media_intent: :audio,
                 state: :ringing,
                 ringing_deadline_at: ringing_deadline_at
               })
               |> Ecto.Changeset.put_change(:inserted_at, started_at)
               |> Ecto.Changeset.put_change(:updated_at, started_at)
               |> Repo.insert()

      assert {:ok, %{call: call, started?: false}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      assert call.call_id == existing.id
      refute_received {:call_ringing, _}
      assert Repo.aggregate(CallAttempt, :count) == 5
      assert Registry.count(DiscordClone.Calls.CallRegistry) == 0
    end

    test "reads caller start and unanswered pair limits from application config" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("calls_rate_config")

      carol_scope = user_scope_fixture(user_fixture(username: "calls_rate_config_carol"))

      {alice_carol, _friendship} =
        befriend_and_open_direct_conversation(caller_scope, carol_scope)

      previous = Application.get_env(:discord_clone, Calls)

      on_exit(fn ->
        if previous do
          Application.put_env(:discord_clone, Calls, previous)
        else
          Application.delete_env(:discord_clone, Calls)
        end
      end)

      now = DateTime.utc_now(:microsecond)

      insert_call_attempt(caller_scope, recipient_scope, direct_conversation, %{
        inserted_at: DateTime.add(now, -1, :second),
        accepted_at: DateTime.add(now, -1, :second),
        terminal_outcome: :ended
      })

      Application.put_env(:discord_clone, Calls,
        max_starts_per_caller_per_minute: 1,
        max_unanswered_attempts_per_pair_per_five_minutes: 3
      )

      assert {:error, :rate_limited} =
               Calls.start_call(caller_scope, alice_carol.id, :audio)

      Application.put_env(:discord_clone, Calls,
        max_starts_per_caller_per_minute: 5,
        max_unanswered_attempts_per_pair_per_five_minutes: 1
      )

      insert_call_attempt(caller_scope, recipient_scope, direct_conversation, %{
        inserted_at: DateTime.add(now, -2, :second),
        terminal_outcome: :declined
      })

      assert {:error, :rate_limited} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)
    end
  end

  describe "decline_call/2" do
    test "lets the committed recipient decline a ringing attempt without Activity or Messages" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("calls_decline")

      assert :ok = Calls.subscribe(caller_scope)
      assert :ok = Calls.subscribe(recipient_scope)

      activity_before = Repo.aggregate(DiscordClone.Activities.ActivityItem, :count)
      messages_before = Repo.aggregate(DiscordClone.Chat.Message, :count)

      assert {:ok, %{call: ringing, started?: true}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      assert_receive {:call_ringing, _}
      assert_receive {:call_ringing, _}

      assert {:ok, declined} = Calls.decline_call(recipient_scope, ringing.call_id)

      assert declined.call_id == ringing.call_id
      assert declined.state == :terminal
      assert declined.terminal_outcome == :declined
      assert %DateTime{} = declined.ended_at
      assert declined.direct_conversation_id == direct_conversation.id
      assert declined.caller_user_id == caller_scope.user.id
      assert declined.recipient_user_id == recipient_scope.user.id
      refute contains_pid?(declined)

      assert {:ok, reloaded} = Calls.get_call(recipient_scope, ringing.call_id)
      assert reloaded == declined

      assert_receive {:call_declined, first_projection}
      assert_receive {:call_declined, second_projection}

      assert MapSet.new([first_projection.call_id, second_projection.call_id]) ==
               MapSet.new([ringing.call_id])

      assert first_projection.terminal_outcome == :declined
      refute contains_pid?(first_projection)
      refute contains_pid?(second_projection)

      assert Repo.aggregate(DiscordClone.Activities.ActivityItem, :count) == activity_before
      assert Repo.aggregate(DiscordClone.Chat.Message, :count) == messages_before
    end

    test "returns the committed declined outcome on a repeated valid command without writing again" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("calls_decline_idem")

      assert :ok = Calls.subscribe(recipient_scope)

      assert {:ok, %{call: ringing}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      assert_receive {:call_ringing, _}

      assert {:ok, first} = Calls.decline_call(recipient_scope, ringing.call_id)
      assert_receive {:call_declined, _}

      %CallAttempt{updated_at: updated_at, ended_at: ended_at} =
        Repo.get!(CallAttempt, ringing.call_id)

      assert {:ok, second} = Calls.decline_call(recipient_scope, ringing.call_id)

      assert second == first
      assert second.terminal_outcome == :declined
      refute_received {:call_declined, _}

      reloaded = Repo.get!(CallAttempt, ringing.call_id)
      assert reloaded.updated_at == updated_at
      assert reloaded.ended_at == ended_at
      assert Repo.aggregate(CallAttempt, :count) == 1
    end

    test "rejects unauthenticated, wrong-role, outsider, former-Friend, and malformed declines without writes" do
      {caller_scope, recipient_scope, direct_conversation, friendship} =
        direct_conversation_fixture("calls_decline_auth")

      outsider_scope = user_scope_fixture(user_fixture(username: "calls_decline_auth_out"))

      assert {:ok, %{call: ringing}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      %CallAttempt{updated_at: updated_at, state: :ringing} =
        Repo.get!(CallAttempt, ringing.call_id)

      assert {:error, :unauthenticated} = Calls.decline_call(nil, ringing.call_id)

      assert {:error, :unauthenticated} =
               Calls.decline_call(%DiscordClone.Accounts.Scope{}, ringing.call_id)

      assert {:error, :not_found} = Calls.decline_call(caller_scope, ringing.call_id)
      assert {:error, :not_found} = Calls.decline_call(outsider_scope, ringing.call_id)
      assert {:error, :not_found} = Calls.decline_call(recipient_scope, "not-a-uuid")
      assert {:error, :not_found} = Calls.decline_call(recipient_scope, Ecto.UUID.generate())

      reloaded = Repo.get!(CallAttempt, ringing.call_id)
      assert reloaded.state == :ringing
      assert reloaded.updated_at == updated_at
      assert is_nil(reloaded.terminal_outcome)
      assert is_nil(reloaded.ended_at)

      assert :ok = Friendships.remove_friend(recipient_scope, friendship.id)

      ended = Repo.get!(CallAttempt, ringing.call_id)
      assert ended.state == :terminal
      assert ended.terminal_outcome == :relationship_ended
      assert %DateTime{} = ended.ended_at

      assert {:error, :not_found} = Calls.decline_call(recipient_scope, ringing.call_id)

      unchanged = Repo.get!(CallAttempt, ringing.call_id)
      assert unchanged.state == :terminal
      assert unchanged.terminal_outcome == :relationship_ended
      assert unchanged.ended_at == ended.ended_at
      assert unchanged.updated_at == ended.updated_at
    end

    test "releases occupancy and CallServer so a later same-pair start receives a new Call ID" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("calls_decline_free")

      assert {:ok, %{call: ringing, started?: true}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      coordinator = :sys.get_state(DiscordClone.Calls.CallCoordinator)
      assert coordinator.calls_by_user[caller_scope.user.id] == ringing.call_id
      assert coordinator.calls_by_user[recipient_scope.user.id] == ringing.call_id
      assert coordinator.calls_by_direct_conversation[direct_conversation.id] == ringing.call_id
      assert coordinator.calls_by_id[ringing.call_id] == direct_conversation.id

      [{call_server, _}] = Registry.lookup(DiscordClone.Calls.CallRegistry, ringing.call_id)
      call_server_ref = Process.monitor(call_server)

      assert {:ok, declined} = Calls.decline_call(recipient_scope, ringing.call_id)
      assert declined.call_id == ringing.call_id
      assert declined.terminal_outcome == :declined

      assert_receive {:DOWN, ^call_server_ref, :process, ^call_server, _reason}
      assert_call_server_stopped(ringing.call_id)

      coordinator = :sys.get_state(DiscordClone.Calls.CallCoordinator)
      refute Map.has_key?(coordinator.calls_by_user, caller_scope.user.id)
      refute Map.has_key?(coordinator.calls_by_user, recipient_scope.user.id)
      refute Map.has_key?(coordinator.calls_by_direct_conversation, direct_conversation.id)
      refute Map.has_key?(coordinator.calls_by_id, ringing.call_id)

      assert {:ok, %{call: later, started?: true}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      assert later.call_id != ringing.call_id
      assert later.state == :ringing
      assert_call_server_ready(later.call_id)
    end

    test "commands carrying an old Call ID cannot discover or mutate a later attempt" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("calls_decline_old")

      assert {:ok, %{call: first}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      assert {:ok, declined} = Calls.decline_call(recipient_scope, first.call_id)
      assert declined.terminal_outcome == :declined

      assert {:ok, %{call: later, started?: true}} =
               Calls.start_call(caller_scope, direct_conversation.id, :video)

      assert later.call_id != first.call_id
      assert later.state == :ringing
      assert later.media_intent == :video

      %CallAttempt{updated_at: later_updated_at} = Repo.get!(CallAttempt, later.call_id)

      assert {:ok, retry} = Calls.decline_call(recipient_scope, first.call_id)
      assert retry.call_id == first.call_id
      assert retry.terminal_outcome == :declined
      assert retry.ended_at == declined.ended_at

      assert {:ok, still_ringing} = Calls.get_call(caller_scope, later.call_id)
      assert still_ringing.call_id == later.call_id
      assert still_ringing.state == :ringing
      assert still_ringing.media_intent == :video

      reloaded_later = Repo.get!(CallAttempt, later.call_id)
      assert reloaded_later.state == :ringing
      assert reloaded_later.updated_at == later_updated_at
      assert is_nil(reloaded_later.terminal_outcome)

      coordinator = :sys.get_state(DiscordClone.Calls.CallCoordinator)
      assert coordinator.calls_by_direct_conversation[direct_conversation.id] == later.call_id
      assert coordinator.calls_by_user[caller_scope.user.id] == later.call_id
      assert coordinator.calls_by_user[recipient_scope.user.id] == later.call_id
      assert coordinator.calls_by_id[later.call_id] == direct_conversation.id
      refute Map.has_key?(coordinator.calls_by_id, first.call_id)
      assert_call_server_ready(later.call_id)
    end

    test "rejects decline of connecting or active attempts without changing durable state" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("calls_decline_stale")

      assert {:ok, %{call: ringing}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      now = DateTime.utc_now(:microsecond)

      Repo.get!(CallAttempt, ringing.call_id)
      |> Ecto.Changeset.change(%{state: :connecting, accepted_at: now})
      |> Repo.update!()

      assert {:error, :stale} = Calls.decline_call(recipient_scope, ringing.call_id)

      connecting = Repo.get!(CallAttempt, ringing.call_id)
      assert connecting.state == :connecting
      assert is_nil(connecting.terminal_outcome)
      assert is_nil(connecting.ended_at)
      assert_call_server_ready(ringing.call_id)

      coordinator = :sys.get_state(DiscordClone.Calls.CallCoordinator)
      assert coordinator.calls_by_id[ringing.call_id] == direct_conversation.id

      carol_scope = user_scope_fixture(user_fixture(username: "calls_decline_stale_carol"))
      dave_scope = user_scope_fixture(user_fixture(username: "calls_decline_stale_dave"))
      {carol_dave, _friendship} = befriend_and_open_direct_conversation(carol_scope, dave_scope)

      active =
        insert_call_attempt(carol_scope, dave_scope, carol_dave, %{
          inserted_at: now,
          accepted_at: now,
          state: :active
        })

      assert {:error, :stale} = Calls.decline_call(dave_scope, active.id)

      reloaded_active = Repo.get!(CallAttempt, active.id)
      assert reloaded_active.state == :active
      assert is_nil(reloaded_active.terminal_outcome)
      assert reloaded_active.updated_at == active.updated_at
    end

    test "returns a different committed terminal outcome without mutating that fact" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("calls_decline_term")

      now = DateTime.utc_now(:microsecond)

      failed =
        insert_call_attempt(caller_scope, recipient_scope, direct_conversation, %{
          inserted_at: now,
          terminal_outcome: :failed
        })

      assert {:ok, projection} = Calls.decline_call(recipient_scope, failed.id)
      assert projection.call_id == failed.id
      assert projection.state == :terminal
      assert projection.terminal_outcome == :failed
      assert projection.ended_at == failed.ended_at

      reloaded = Repo.get!(CallAttempt, failed.id)
      assert reloaded.terminal_outcome == :failed
      assert reloaded.updated_at == failed.updated_at
    end

    test "maps an unexpected durable update failure to a documented atom without leaking a changeset" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("calls_decline_clock")

      assert {:ok, %{call: ringing}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      future = DateTime.add(DateTime.utc_now(:microsecond), 3600, :second)

      Repo.get!(CallAttempt, ringing.call_id)
      |> Ecto.Changeset.change(%{
        inserted_at: future,
        ringing_deadline_at: DateTime.add(future, 30, :second),
        updated_at: future
      })
      |> Repo.update!()

      assert {:error, :temporarily_unavailable} =
               Calls.decline_call(recipient_scope, ringing.call_id)

      reloaded = Repo.get!(CallAttempt, ringing.call_id)
      assert reloaded.state == :ringing
      assert is_nil(reloaded.terminal_outcome)
    end

    test "returns the committed declined projection when the Calls runtime is down after commit" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("calls_decline_runtime")

      assert {:ok, %{call: ringing}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      assert :ok =
               Supervisor.terminate_child(
                 DiscordClone.Calls.Supervisor,
                 DiscordClone.Calls.CallCoordinator
               )

      assert {:ok, declined} = Calls.decline_call(recipient_scope, ringing.call_id)
      assert declined.call_id == ringing.call_id
      assert declined.state == :terminal
      assert declined.terminal_outcome == :declined

      reloaded = Repo.get!(CallAttempt, ringing.call_id)
      assert reloaded.state == :terminal
      assert reloaded.terminal_outcome == :declined
    end
  end

  describe "cancel_call/2" do
    test "lets the committed caller cancel ringing and creates exactly one missed-call Activity" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("calls_cancel")

      outsider_scope = user_scope_fixture(user_fixture(username: "calls_cancel_out"))

      assert :ok = Calls.subscribe(caller_scope)
      assert :ok = Calls.subscribe(recipient_scope)
      assert :ok = Chat.subscribe_to_activity(recipient_scope)
      assert :ok = Chat.subscribe_to_activity(caller_scope)

      {:ok, unread_before} = Chat.unread_activity_count(recipient_scope)
      messages_before = Repo.aggregate(DiscordClone.Chat.Message, :count)

      assert {:ok, %{call: ringing, started?: true}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      assert_receive {:call_ringing, _}
      assert_receive {:call_ringing, _}

      assert {:ok, cancelled} = Calls.cancel_call(caller_scope, ringing.call_id)

      assert cancelled.call_id == ringing.call_id
      assert cancelled.state == :terminal
      assert cancelled.terminal_outcome == :cancelled
      assert %DateTime{} = cancelled.ended_at
      assert cancelled.direct_conversation_id == direct_conversation.id
      assert cancelled.caller_user_id == caller_scope.user.id
      assert cancelled.recipient_user_id == recipient_scope.user.id
      refute contains_pid?(cancelled)

      assert {:ok, reloaded} = Calls.get_call(caller_scope, ringing.call_id)
      assert reloaded == cancelled

      assert_receive {:call_cancelled, first_projection}
      assert_receive {:call_cancelled, second_projection}

      assert MapSet.new([first_projection.call_id, second_projection.call_id]) ==
               MapSet.new([ringing.call_id])

      assert first_projection.terminal_outcome == :cancelled
      refute contains_pid?(first_projection)
      refute contains_pid?(second_projection)

      assert_receive {:activity_changed, activity_payload}
      assert activity_payload.action == :created
      refute contains_pid?(activity_payload)
      refute_received {:activity_changed, _}

      [item] = missed_call_activity_items(recipient_scope.user.id, ringing.call_id)
      assert item.kind == "missed_direct_call"
      assert item.actor_user_id == caller_scope.user.id
      assert item.source_conversation_id == direct_conversation.id
      assert item.source_call_attempt_id == ringing.call_id
      assert is_nil(item.source_message_id)
      assert is_nil(item.source_friend_relationship_id)
      assert is_nil(item.workspace_id)
      assert is_nil(item.read_at)
      refute contains_pid?(item)
      refute inspect(item) =~ "#PID"

      assert missed_call_activity_items(caller_scope.user.id, ringing.call_id) == []
      assert missed_call_activity_items(outsider_scope.user.id, ringing.call_id) == []
      assert Repo.aggregate(DiscordClone.Chat.Message, :count) == messages_before

      assert {:ok, %{items: recipient_feed}} = Chat.list_activity_feed(recipient_scope)
      assert Enum.any?(recipient_feed, &(&1.id == item.id))

      assert {:ok, preview} = Chat.list_activity_preview(recipient_scope)
      assert Enum.any?(preview, &(&1.id == item.id))

      {:ok, unread_after} = Chat.unread_activity_count(recipient_scope)
      assert unread_after == unread_before + 1

      assert {:ok, %{items: caller_feed}} = Chat.list_activity_feed(caller_scope)
      refute Enum.any?(caller_feed, &(&1.kind == "missed_direct_call"))

      assert {:ok, %{items: outsider_feed}} = Chat.list_activity_feed(outsider_scope)
      refute Enum.any?(outsider_feed, &(&1.kind == "missed_direct_call"))
    end

    test "returns the committed cancelled outcome on a repeated valid command without duplicating Activity" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("calls_cancel_idem")

      assert :ok = Calls.subscribe(caller_scope)
      assert :ok = Chat.subscribe_to_activity(recipient_scope)

      assert {:ok, %{call: ringing}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      assert_receive {:call_ringing, _}

      assert {:ok, first} = Calls.cancel_call(caller_scope, ringing.call_id)
      assert_receive {:call_cancelled, _}
      assert_receive {:activity_changed, _}

      %CallAttempt{updated_at: updated_at, ended_at: ended_at} =
        Repo.get!(CallAttempt, ringing.call_id)

      assert {:ok, second} = Calls.cancel_call(caller_scope, ringing.call_id)

      assert second == first
      assert second.terminal_outcome == :cancelled
      refute_received {:call_cancelled, _}
      refute_received {:activity_changed, _}

      reloaded = Repo.get!(CallAttempt, ringing.call_id)
      assert reloaded.updated_at == updated_at
      assert reloaded.ended_at == ended_at

      assert Repo.aggregate(
               from(attempt in CallAttempt,
                 where: attempt.direct_conversation_id == ^direct_conversation.id
               ),
               :count
             ) == 1

      assert length(missed_call_activity_items(recipient_scope.user.id, ringing.call_id)) == 1
    end

    test "rejects unauthenticated, wrong-role, outsider, former-Friend, and malformed cancels without writes" do
      {caller_scope, recipient_scope, direct_conversation, friendship} =
        direct_conversation_fixture("calls_cancel_auth")

      outsider_scope = user_scope_fixture(user_fixture(username: "calls_cancel_auth_out"))

      assert {:ok, %{call: ringing}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      %CallAttempt{updated_at: updated_at, state: :ringing} =
        Repo.get!(CallAttempt, ringing.call_id)

      assert {:error, :unauthenticated} = Calls.cancel_call(nil, ringing.call_id)

      assert {:error, :unauthenticated} =
               Calls.cancel_call(%DiscordClone.Accounts.Scope{}, ringing.call_id)

      assert {:error, :not_found} = Calls.cancel_call(recipient_scope, ringing.call_id)
      assert {:error, :not_found} = Calls.cancel_call(outsider_scope, ringing.call_id)
      assert {:error, :not_found} = Calls.cancel_call(caller_scope, "not-a-uuid")
      assert {:error, :not_found} = Calls.cancel_call(caller_scope, Ecto.UUID.generate())

      reloaded = Repo.get!(CallAttempt, ringing.call_id)
      assert reloaded.state == :ringing
      assert reloaded.updated_at == updated_at
      assert is_nil(reloaded.terminal_outcome)
      assert is_nil(reloaded.ended_at)
      assert missed_call_activity_items(recipient_scope.user.id, ringing.call_id) == []

      assert :ok = Friendships.remove_friend(caller_scope, friendship.id)

      ended = Repo.get!(CallAttempt, ringing.call_id)
      assert ended.state == :terminal
      assert ended.terminal_outcome == :relationship_ended
      assert %DateTime{} = ended.ended_at
      assert missed_call_activity_items(recipient_scope.user.id, ringing.call_id) == []

      assert {:error, :not_found} = Calls.cancel_call(caller_scope, ringing.call_id)

      unchanged = Repo.get!(CallAttempt, ringing.call_id)
      assert unchanged.state == :terminal
      assert unchanged.terminal_outcome == :relationship_ended
      assert unchanged.ended_at == ended.ended_at
      assert unchanged.updated_at == ended.updated_at
      assert missed_call_activity_items(recipient_scope.user.id, ringing.call_id) == []
    end

    test "releases occupancy and CallServer so a later same-pair start receives a new Call ID" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("calls_cancel_free")

      assert {:ok, %{call: ringing, started?: true}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      coordinator = :sys.get_state(DiscordClone.Calls.CallCoordinator)
      assert coordinator.calls_by_user[caller_scope.user.id] == ringing.call_id
      assert coordinator.calls_by_user[recipient_scope.user.id] == ringing.call_id
      assert coordinator.calls_by_direct_conversation[direct_conversation.id] == ringing.call_id
      assert coordinator.calls_by_id[ringing.call_id] == direct_conversation.id

      [{call_server, _}] = Registry.lookup(DiscordClone.Calls.CallRegistry, ringing.call_id)
      call_server_ref = Process.monitor(call_server)

      assert {:ok, cancelled} = Calls.cancel_call(caller_scope, ringing.call_id)
      assert cancelled.call_id == ringing.call_id
      assert cancelled.terminal_outcome == :cancelled

      assert_receive {:DOWN, ^call_server_ref, :process, ^call_server, _reason}
      assert_call_server_stopped(ringing.call_id)

      coordinator = :sys.get_state(DiscordClone.Calls.CallCoordinator)
      refute Map.has_key?(coordinator.calls_by_user, caller_scope.user.id)
      refute Map.has_key?(coordinator.calls_by_user, recipient_scope.user.id)
      refute Map.has_key?(coordinator.calls_by_direct_conversation, direct_conversation.id)
      refute Map.has_key?(coordinator.calls_by_id, ringing.call_id)

      assert {:ok, %{call: later, started?: true}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      assert later.call_id != ringing.call_id
      assert later.state == :ringing
      assert_call_server_ready(later.call_id)

      assert length(missed_call_activity_items(recipient_scope.user.id, ringing.call_id)) == 1
      assert missed_call_activity_items(recipient_scope.user.id, later.call_id) == []
    end

    test "commands carrying an old Call ID cannot discover or mutate a later attempt" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("calls_cancel_old")

      assert {:ok, %{call: first}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      assert {:ok, cancelled} = Calls.cancel_call(caller_scope, first.call_id)
      assert cancelled.terminal_outcome == :cancelled

      assert {:ok, %{call: later, started?: true}} =
               Calls.start_call(caller_scope, direct_conversation.id, :video)

      assert later.call_id != first.call_id
      assert later.state == :ringing
      assert later.media_intent == :video

      %CallAttempt{updated_at: later_updated_at} = Repo.get!(CallAttempt, later.call_id)

      assert {:ok, retry} = Calls.cancel_call(caller_scope, first.call_id)
      assert retry.call_id == first.call_id
      assert retry.terminal_outcome == :cancelled
      assert retry.ended_at == cancelled.ended_at

      assert {:ok, still_ringing} = Calls.get_call(recipient_scope, later.call_id)
      assert still_ringing.call_id == later.call_id
      assert still_ringing.state == :ringing
      assert still_ringing.media_intent == :video

      reloaded_later = Repo.get!(CallAttempt, later.call_id)
      assert reloaded_later.state == :ringing
      assert reloaded_later.updated_at == later_updated_at
      assert is_nil(reloaded_later.terminal_outcome)

      coordinator = :sys.get_state(DiscordClone.Calls.CallCoordinator)
      assert coordinator.calls_by_direct_conversation[direct_conversation.id] == later.call_id
      assert coordinator.calls_by_user[caller_scope.user.id] == later.call_id
      assert coordinator.calls_by_user[recipient_scope.user.id] == later.call_id
      assert coordinator.calls_by_id[later.call_id] == direct_conversation.id
      refute Map.has_key?(coordinator.calls_by_id, first.call_id)
      assert_call_server_ready(later.call_id)

      assert length(missed_call_activity_items(recipient_scope.user.id, first.call_id)) == 1
      assert missed_call_activity_items(recipient_scope.user.id, later.call_id) == []
    end

    test "cancels connecting without Activity and rejects active cancel as stale" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("calls_cancel_stale")

      assert {:ok, %{call: ringing}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      now = DateTime.utc_now(:microsecond)

      Repo.get!(CallAttempt, ringing.call_id)
      |> Ecto.Changeset.change(%{state: :connecting, accepted_at: now})
      |> Repo.update!()

      assert {:ok, cancelled} = Calls.cancel_call(caller_scope, ringing.call_id)
      assert cancelled.state == :terminal
      assert cancelled.terminal_outcome == :cancelled
      assert missed_call_activity_items(recipient_scope.user.id, ringing.call_id) == []

      coordinator = :sys.get_state(DiscordClone.Calls.CallCoordinator)
      refute Map.has_key?(coordinator.calls_by_id, ringing.call_id)
      assert_call_server_stopped(ringing.call_id)

      carol_scope = user_scope_fixture(user_fixture(username: "calls_cancel_stale_carol"))
      dave_scope = user_scope_fixture(user_fixture(username: "calls_cancel_stale_dave"))
      {carol_dave, _friendship} = befriend_and_open_direct_conversation(carol_scope, dave_scope)

      active =
        insert_call_attempt(carol_scope, dave_scope, carol_dave, %{
          inserted_at: now,
          accepted_at: now,
          state: :active
        })

      assert {:error, :stale} = Calls.cancel_call(carol_scope, active.id)

      reloaded_active = Repo.get!(CallAttempt, active.id)
      assert reloaded_active.state == :active
      assert is_nil(reloaded_active.terminal_outcome)
      assert reloaded_active.updated_at == active.updated_at
      assert missed_call_activity_items(dave_scope.user.id, active.id) == []
    end

    test "returns a different committed terminal outcome without mutating that fact" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("calls_cancel_term")

      now = DateTime.utc_now(:microsecond)

      declined =
        insert_call_attempt(caller_scope, recipient_scope, direct_conversation, %{
          inserted_at: now,
          terminal_outcome: :declined
        })

      assert {:ok, projection} = Calls.cancel_call(caller_scope, declined.id)
      assert projection.call_id == declined.id
      assert projection.state == :terminal
      assert projection.terminal_outcome == :declined
      assert projection.ended_at == declined.ended_at

      reloaded = Repo.get!(CallAttempt, declined.id)
      assert reloaded.terminal_outcome == :declined
      assert reloaded.updated_at == declined.updated_at
      assert missed_call_activity_items(recipient_scope.user.id, declined.id) == []
    end

    test "commits cancel when a missed-call Activity for the same Call ID already exists" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("calls_cancel_unique")

      assert {:ok, %{call: ringing}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      existing =
        %ActivityItem{}
        |> ActivityItem.create_missed_direct_call_changeset(%{
          recipient_user_id: recipient_scope.user.id,
          actor_user_id: caller_scope.user.id,
          source_conversation_id: direct_conversation.id,
          source_call_attempt_id: ringing.call_id
        })
        |> Repo.insert!()

      assert {:ok, cancelled} = Calls.cancel_call(caller_scope, ringing.call_id)
      assert cancelled.state == :terminal
      assert cancelled.terminal_outcome == :cancelled

      assert [item] = missed_call_activity_items(recipient_scope.user.id, ringing.call_id)
      assert item.id == existing.id
    end

    test "rolls back the terminal write when missed-call Activity insertion fails" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("calls_cancel_act_fail")

      assert {:ok, %{call: ringing}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      Ecto.Adapters.SQL.query!(
        Repo,
        """
        ALTER TABLE activity_items
        ADD CONSTRAINT activity_items_reject_missed_direct_call
        CHECK (kind <> 'missed_direct_call')
        """
      )

      assert {:error, :temporarily_unavailable} =
               Calls.cancel_call(caller_scope, ringing.call_id)

      reloaded = Repo.get!(CallAttempt, ringing.call_id)
      assert reloaded.state == :ringing
      assert is_nil(reloaded.terminal_outcome)
      assert missed_call_activity_items(recipient_scope.user.id, ringing.call_id) == []
      assert_call_server_ready(ringing.call_id)
    end

    test "maps an unexpected durable update failure to a documented atom without leaking a changeset" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("calls_cancel_clock")

      assert {:ok, %{call: ringing}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      future = DateTime.add(DateTime.utc_now(:microsecond), 3600, :second)

      Repo.get!(CallAttempt, ringing.call_id)
      |> Ecto.Changeset.change(%{
        inserted_at: future,
        ringing_deadline_at: DateTime.add(future, 30, :second),
        updated_at: future
      })
      |> Repo.update!()

      assert {:error, :temporarily_unavailable} =
               Calls.cancel_call(caller_scope, ringing.call_id)

      reloaded = Repo.get!(CallAttempt, ringing.call_id)
      assert reloaded.state == :ringing
      assert is_nil(reloaded.terminal_outcome)
      assert missed_call_activity_items(recipient_scope.user.id, ringing.call_id) == []
    end

    test "returns the committed cancelled projection when the Calls runtime is down after commit" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("calls_cancel_runtime")

      assert {:ok, %{call: ringing}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      assert :ok =
               Supervisor.terminate_child(
                 DiscordClone.Calls.Supervisor,
                 DiscordClone.Calls.CallCoordinator
               )

      assert {:ok, cancelled} = Calls.cancel_call(caller_scope, ringing.call_id)
      assert cancelled.call_id == ringing.call_id
      assert cancelled.state == :terminal
      assert cancelled.terminal_outcome == :cancelled

      reloaded = Repo.get!(CallAttempt, ringing.call_id)
      assert reloaded.state == :terminal
      assert reloaded.terminal_outcome == :cancelled
      assert length(missed_call_activity_items(recipient_scope.user.id, ringing.call_id)) == 1
    end

    test "opens the missed-call item to the Direct Conversation and keeps navigation after Friendship ends" do
      {caller_scope, recipient_scope, direct_conversation, friendship} =
        direct_conversation_fixture("calls_cancel_open")

      assert {:ok, %{call: ringing}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      assert {:ok, _cancelled} = Calls.cancel_call(caller_scope, ringing.call_id)

      [item] = missed_call_activity_items(recipient_scope.user.id, ringing.call_id)

      assert {:ok, destination} = Chat.open_activity_item(recipient_scope, item.id)

      assert destination == %{direct_conversation_id: direct_conversation.id}
      refute Map.has_key?(destination, :message_id)
      assert %DateTime{} = Repo.reload!(item).read_at

      outsider_scope = user_scope_fixture(user_fixture(username: "calls_cancel_open_out"))
      assert {:error, :not_found} = Chat.open_activity_item(outsider_scope, item.id)
      assert {:error, :not_found} = Chat.open_activity_item(caller_scope, item.id)

      assert :ok = Friendships.remove_friend(recipient_scope, friendship.id)

      assert {:error, :not_found} = Calls.get_call(caller_scope, ringing.call_id)
      assert {:error, :not_found} = Calls.get_call(recipient_scope, ringing.call_id)

      assert {:ok, %{direct_conversation_id: opened_id}} =
               Chat.open_activity_item(recipient_scope, item.id)

      assert opened_id == direct_conversation.id

      assert {:ok, %{items: history}} = Chat.list_activity_feed(recipient_scope)
      assert Enum.any?(history, &(&1.id == item.id))
    end

    test "keeps a cancelled unanswered attempt in the pair rate-limit window" do
      {caller_scope, _recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("calls_cancel_rate")

      previous = Application.get_env(:discord_clone, Calls)

      on_exit(fn ->
        if previous do
          Application.put_env(:discord_clone, Calls, previous)
        else
          Application.delete_env(:discord_clone, Calls)
        end
      end)

      Application.put_env(:discord_clone, Calls,
        max_starts_per_caller_per_minute: 5,
        max_unanswered_attempts_per_pair_per_five_minutes: 1
      )

      assert {:ok, %{call: ringing}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      assert {:ok, cancelled} = Calls.cancel_call(caller_scope, ringing.call_id)
      assert cancelled.terminal_outcome == :cancelled

      assert {:error, :rate_limited} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)
    end
  end

  describe "expire_ringing_attempt/1" do
    test "times out a due ringing attempt with exactly one missed-call Activity and no Message" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("calls_expire")

      outsider_scope = user_scope_fixture(user_fixture(username: "calls_expire_out"))

      assert :ok = Calls.subscribe(caller_scope)
      assert :ok = Calls.subscribe(recipient_scope)
      assert :ok = Chat.subscribe_to_activity(recipient_scope)
      assert :ok = Chat.subscribe_to_activity(caller_scope)

      {:ok, unread_before} = Chat.unread_activity_count(recipient_scope)
      messages_before = Repo.aggregate(DiscordClone.Chat.Message, :count)

      assert {:ok, %{call: ringing, started?: true}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      assert_receive {:call_ringing, _}
      assert_receive {:call_ringing, _}

      due_attempt = make_ringing_deadline_due!(ringing.call_id)

      assert {:ok, timed_out} = Calls.expire_ringing_attempt(ringing.call_id)

      assert timed_out.call_id == ringing.call_id
      assert timed_out.state == :terminal
      assert timed_out.terminal_outcome == :timed_out
      assert %DateTime{} = timed_out.ended_at
      assert timed_out.direct_conversation_id == direct_conversation.id
      assert timed_out.caller_user_id == caller_scope.user.id
      assert timed_out.recipient_user_id == recipient_scope.user.id
      assert timed_out.ringing_deadline_at == due_attempt.ringing_deadline_at
      refute contains_pid?(timed_out)

      reloaded = Repo.get!(CallAttempt, ringing.call_id)
      assert reloaded.state == :terminal
      assert reloaded.terminal_outcome == :timed_out
      assert reloaded.ringing_deadline_at == due_attempt.ringing_deadline_at

      assert {:ok, observed} = Calls.get_call(caller_scope, ringing.call_id)
      assert observed == timed_out

      assert_receive {:call_timed_out, first_projection}
      assert_receive {:call_timed_out, second_projection}

      assert MapSet.new([first_projection.call_id, second_projection.call_id]) ==
               MapSet.new([ringing.call_id])

      assert first_projection.terminal_outcome == :timed_out
      refute contains_pid?(first_projection)
      refute contains_pid?(second_projection)

      assert_receive {:activity_changed, activity_payload}
      assert activity_payload.action == :created
      refute contains_pid?(activity_payload)
      refute_received {:activity_changed, _}

      [item] = missed_call_activity_items(recipient_scope.user.id, ringing.call_id)
      assert item.kind == "missed_direct_call"
      assert item.actor_user_id == caller_scope.user.id
      assert item.source_conversation_id == direct_conversation.id
      assert item.source_call_attempt_id == ringing.call_id
      assert is_nil(item.source_message_id)
      assert is_nil(item.source_friend_relationship_id)
      assert is_nil(item.workspace_id)
      assert is_nil(item.read_at)
      refute contains_pid?(item)
      refute inspect(item) =~ "#PID"

      assert missed_call_activity_items(caller_scope.user.id, ringing.call_id) == []
      assert missed_call_activity_items(outsider_scope.user.id, ringing.call_id) == []
      assert Repo.aggregate(DiscordClone.Chat.Message, :count) == messages_before

      assert {:ok, %{items: recipient_feed}} = Chat.list_activity_feed(recipient_scope)
      assert Enum.any?(recipient_feed, &(&1.id == item.id))

      assert {:ok, preview} = Chat.list_activity_preview(recipient_scope)
      assert Enum.any?(preview, &(&1.id == item.id))

      {:ok, unread_after} = Chat.unread_activity_count(recipient_scope)
      assert unread_after == unread_before + 1

      assert {:ok, %{items: caller_feed}} = Chat.list_activity_feed(caller_scope)
      refute Enum.any?(caller_feed, &(&1.kind == "missed_direct_call"))
    end

    test "leaves an early timeout check ringing with the original deadline and no Activity" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("calls_expire_early")

      assert :ok = Calls.subscribe(caller_scope)
      assert :ok = Chat.subscribe_to_activity(recipient_scope)

      assert {:ok, %{call: ringing}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      assert_receive {:call_ringing, _}
      original_deadline = ringing.ringing_deadline_at
      %CallAttempt{updated_at: updated_at} = Repo.get!(CallAttempt, ringing.call_id)

      assert {:ok, still_ringing} = Calls.expire_ringing_attempt(ringing.call_id)

      assert still_ringing.call_id == ringing.call_id
      assert still_ringing.state == :ringing
      assert is_nil(still_ringing.terminal_outcome)
      assert is_nil(still_ringing.ended_at)
      assert still_ringing.ringing_deadline_at == original_deadline
      refute_received {:call_timed_out, _}
      refute_received {:activity_changed, _}

      reloaded = Repo.get!(CallAttempt, ringing.call_id)
      assert reloaded.state == :ringing
      assert reloaded.ringing_deadline_at == original_deadline
      assert reloaded.updated_at == updated_at
      assert is_nil(reloaded.terminal_outcome)
      assert missed_call_activity_items(recipient_scope.user.id, ringing.call_id) == []
      assert_call_server_ready(ringing.call_id)

      coordinator = :sys.get_state(DiscordClone.Calls.CallCoordinator)
      assert coordinator.calls_by_id[ringing.call_id] == direct_conversation.id
      assert coordinator.calls_by_direct_conversation[direct_conversation.id] == ringing.call_id
    end

    test "returns the committed timed_out outcome on a repeated due expire without duplicating Activity" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("calls_expire_idem")

      assert :ok = Calls.subscribe(caller_scope)
      assert :ok = Chat.subscribe_to_activity(recipient_scope)

      assert {:ok, %{call: ringing}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      assert_receive {:call_ringing, _}
      make_ringing_deadline_due!(ringing.call_id)

      assert {:ok, first} = Calls.expire_ringing_attempt(ringing.call_id)
      assert_receive {:call_timed_out, _}
      assert_receive {:activity_changed, _}

      %CallAttempt{updated_at: updated_at, ended_at: ended_at} =
        Repo.get!(CallAttempt, ringing.call_id)

      assert {:ok, second} = Calls.expire_ringing_attempt(ringing.call_id)

      assert second == first
      assert second.terminal_outcome == :timed_out
      refute_received {:call_timed_out, _}
      refute_received {:activity_changed, _}

      reloaded = Repo.get!(CallAttempt, ringing.call_id)
      assert reloaded.updated_at == updated_at
      assert reloaded.ended_at == ended_at

      assert Repo.aggregate(
               from(attempt in CallAttempt,
                 where: attempt.direct_conversation_id == ^direct_conversation.id
               ),
               :count
             ) == 1

      assert length(missed_call_activity_items(recipient_scope.user.id, ringing.call_id)) == 1
    end

    test "releases occupancy and CallServer so a later same-pair start receives a new Call ID" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("calls_expire_free")

      assert {:ok, %{call: ringing, started?: true}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      coordinator = :sys.get_state(DiscordClone.Calls.CallCoordinator)
      assert coordinator.calls_by_user[caller_scope.user.id] == ringing.call_id
      assert coordinator.calls_by_user[recipient_scope.user.id] == ringing.call_id
      assert coordinator.calls_by_direct_conversation[direct_conversation.id] == ringing.call_id
      assert coordinator.calls_by_id[ringing.call_id] == direct_conversation.id

      [{call_server, _}] = Registry.lookup(DiscordClone.Calls.CallRegistry, ringing.call_id)
      call_server_ref = Process.monitor(call_server)

      make_ringing_deadline_due!(ringing.call_id)
      assert {:ok, timed_out} = Calls.expire_ringing_attempt(ringing.call_id)
      assert timed_out.call_id == ringing.call_id
      assert timed_out.terminal_outcome == :timed_out

      assert_receive {:DOWN, ^call_server_ref, :process, ^call_server, _reason}
      assert_call_server_stopped(ringing.call_id)

      coordinator = :sys.get_state(DiscordClone.Calls.CallCoordinator)
      refute Map.has_key?(coordinator.calls_by_user, caller_scope.user.id)
      refute Map.has_key?(coordinator.calls_by_user, recipient_scope.user.id)
      refute Map.has_key?(coordinator.calls_by_direct_conversation, direct_conversation.id)
      refute Map.has_key?(coordinator.calls_by_id, ringing.call_id)

      assert {:ok, %{call: later, started?: true}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      assert later.call_id != ringing.call_id
      assert later.state == :ringing
      assert_call_server_ready(later.call_id)

      assert length(missed_call_activity_items(recipient_scope.user.id, ringing.call_id)) == 1
      assert missed_call_activity_items(recipient_scope.user.id, later.call_id) == []
    end

    test "an old Call ID cannot discover or mutate a later attempt" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("calls_expire_old")

      assert {:ok, %{call: first}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      make_ringing_deadline_due!(first.call_id)
      assert {:ok, timed_out} = Calls.expire_ringing_attempt(first.call_id)
      assert timed_out.terminal_outcome == :timed_out

      assert {:ok, %{call: later, started?: true}} =
               Calls.start_call(caller_scope, direct_conversation.id, :video)

      assert later.call_id != first.call_id
      assert later.state == :ringing
      assert later.media_intent == :video

      %CallAttempt{updated_at: later_updated_at} = Repo.get!(CallAttempt, later.call_id)

      assert {:ok, retry} = Calls.expire_ringing_attempt(first.call_id)
      assert retry.call_id == first.call_id
      assert retry.terminal_outcome == :timed_out
      assert retry.ended_at == timed_out.ended_at

      assert {:ok, still_ringing} = Calls.get_call(recipient_scope, later.call_id)
      assert still_ringing.call_id == later.call_id
      assert still_ringing.state == :ringing
      assert still_ringing.media_intent == :video

      reloaded_later = Repo.get!(CallAttempt, later.call_id)
      assert reloaded_later.state == :ringing
      assert reloaded_later.updated_at == later_updated_at
      assert is_nil(reloaded_later.terminal_outcome)

      coordinator = :sys.get_state(DiscordClone.Calls.CallCoordinator)
      assert coordinator.calls_by_direct_conversation[direct_conversation.id] == later.call_id
      assert coordinator.calls_by_user[caller_scope.user.id] == later.call_id
      assert coordinator.calls_by_user[recipient_scope.user.id] == later.call_id
      assert coordinator.calls_by_id[later.call_id] == direct_conversation.id
      refute Map.has_key?(coordinator.calls_by_id, first.call_id)
      assert_call_server_ready(later.call_id)

      assert length(missed_call_activity_items(recipient_scope.user.id, first.call_id)) == 1
      assert missed_call_activity_items(recipient_scope.user.id, later.call_id) == []
    end

    test "ignores connecting and active attempts and keeps a different committed terminal outcome" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("calls_expire_stale")

      assert {:ok, %{call: ringing}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      now = DateTime.utc_now(:microsecond)

      Repo.get!(CallAttempt, ringing.call_id)
      |> Ecto.Changeset.change(%{state: :connecting, accepted_at: now})
      |> Repo.update!()

      make_ringing_deadline_due!(ringing.call_id)
      assert {:error, :stale} = Calls.expire_ringing_attempt(ringing.call_id)

      reloaded_connecting = Repo.get!(CallAttempt, ringing.call_id)
      assert reloaded_connecting.state == :connecting
      assert is_nil(reloaded_connecting.terminal_outcome)
      assert missed_call_activity_items(recipient_scope.user.id, ringing.call_id) == []
      assert_call_server_ready(ringing.call_id)

      carol_scope = user_scope_fixture(user_fixture(username: "calls_expire_stale_carol"))
      dave_scope = user_scope_fixture(user_fixture(username: "calls_expire_stale_dave"))
      {carol_dave, _friendship} = befriend_and_open_direct_conversation(carol_scope, dave_scope)

      active =
        insert_call_attempt(carol_scope, dave_scope, carol_dave, %{
          inserted_at: now,
          accepted_at: now,
          state: :active
        })

      assert {:error, :stale} = Calls.expire_ringing_attempt(active.id)

      reloaded_active = Repo.get!(CallAttempt, active.id)
      assert reloaded_active.state == :active
      assert is_nil(reloaded_active.terminal_outcome)
      assert reloaded_active.updated_at == active.updated_at
      assert missed_call_activity_items(dave_scope.user.id, active.id) == []

      declined =
        insert_call_attempt(caller_scope, recipient_scope, direct_conversation, %{
          inserted_at: DateTime.add(now, -90, :second),
          terminal_outcome: :declined
        })

      assert {:ok, projection} = Calls.expire_ringing_attempt(declined.id)
      assert projection.call_id == declined.id
      assert projection.state == :terminal
      assert projection.terminal_outcome == :declined
      assert projection.ended_at == declined.ended_at

      reloaded_declined = Repo.get!(CallAttempt, declined.id)
      assert reloaded_declined.terminal_outcome == :declined
      assert reloaded_declined.updated_at == declined.updated_at
      assert missed_call_activity_items(recipient_scope.user.id, declined.id) == []
    end

    test "commits timeout when a missed-call Activity for the same Call ID already exists" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("calls_expire_unique")

      assert {:ok, %{call: ringing}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      existing =
        %ActivityItem{}
        |> ActivityItem.create_missed_direct_call_changeset(%{
          recipient_user_id: recipient_scope.user.id,
          actor_user_id: caller_scope.user.id,
          source_conversation_id: direct_conversation.id,
          source_call_attempt_id: ringing.call_id
        })
        |> Repo.insert!()

      make_ringing_deadline_due!(ringing.call_id)
      assert {:ok, timed_out} = Calls.expire_ringing_attempt(ringing.call_id)
      assert timed_out.state == :terminal
      assert timed_out.terminal_outcome == :timed_out

      assert [item] = missed_call_activity_items(recipient_scope.user.id, ringing.call_id)
      assert item.id == existing.id
    end

    test "rolls back the terminal write when missed-call Activity insertion fails" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("calls_expire_act_fail")

      assert {:ok, %{call: ringing}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      Ecto.Adapters.SQL.query!(
        Repo,
        """
        ALTER TABLE activity_items
        ADD CONSTRAINT activity_items_reject_missed_direct_call
        CHECK (kind <> 'missed_direct_call')
        """
      )

      make_ringing_deadline_due!(ringing.call_id)

      assert {:error, :temporarily_unavailable} =
               Calls.expire_ringing_attempt(ringing.call_id)

      reloaded = Repo.get!(CallAttempt, ringing.call_id)
      assert reloaded.state == :ringing
      assert is_nil(reloaded.terminal_outcome)
      assert missed_call_activity_items(recipient_scope.user.id, ringing.call_id) == []
      assert_call_server_ready(ringing.call_id)
    end

    test "maps an unexpected durable update failure to a documented atom without leaking a changeset" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("calls_expire_clock")

      assert {:ok, %{call: ringing}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      Ecto.Adapters.SQL.query!(
        Repo,
        """
        ALTER TABLE call_attempts
        ADD CONSTRAINT call_attempts_reject_timed_out
        CHECK (terminal_outcome IS DISTINCT FROM 'timed_out')
        """
      )

      make_ringing_deadline_due!(ringing.call_id)

      assert {:error, :temporarily_unavailable} =
               Calls.expire_ringing_attempt(ringing.call_id)

      reloaded = Repo.get!(CallAttempt, ringing.call_id)
      assert reloaded.state == :ringing
      assert is_nil(reloaded.terminal_outcome)
      assert missed_call_activity_items(recipient_scope.user.id, ringing.call_id) == []
    end

    test "returns the committed timed_out projection when the Calls runtime is down after commit" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("calls_expire_runtime")

      assert {:ok, %{call: ringing}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      assert :ok =
               Supervisor.terminate_child(
                 DiscordClone.Calls.Supervisor,
                 DiscordClone.Calls.CallCoordinator
               )

      make_ringing_deadline_due!(ringing.call_id)
      assert {:ok, timed_out} = Calls.expire_ringing_attempt(ringing.call_id)
      assert timed_out.call_id == ringing.call_id
      assert timed_out.state == :terminal
      assert timed_out.terminal_outcome == :timed_out

      reloaded = Repo.get!(CallAttempt, ringing.call_id)
      assert reloaded.state == :terminal
      assert reloaded.terminal_outcome == :timed_out
      assert length(missed_call_activity_items(recipient_scope.user.id, ringing.call_id)) == 1
    end

    test "times out an unanswered attempt for an offline recipient without consulting Presence" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("calls_expire_off")

      assert :ok = Presence.subscribe_to_friend(caller_scope, recipient_scope.user.id)
      assert {:ok, :offline} = Presence.friend_status(caller_scope, recipient_scope.user.id)
      assert {:ok, []} = Presence.list_online_friend_ids(caller_scope)
      assert :ok = Calls.subscribe(recipient_scope)
      assert :ok = Chat.subscribe_to_activity(recipient_scope)

      assert {:ok, %{call: ringing, started?: true}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      assert_receive {:call_ringing, _}
      make_ringing_deadline_due!(ringing.call_id)

      assert {:ok, timed_out} = Calls.expire_ringing_attempt(ringing.call_id)
      assert timed_out.terminal_outcome == :timed_out

      assert_receive {:call_timed_out, projection}
      assert projection.call_id == ringing.call_id
      assert_receive {:activity_changed, _}

      assert length(missed_call_activity_items(recipient_scope.user.id, ringing.call_id)) == 1
      assert {:ok, :offline} = Presence.friend_status(caller_scope, recipient_scope.user.id)
      assert {:ok, []} = Presence.list_online_friend_ids(caller_scope)
      refute_received {:friend_presence_changed, _}
    end

    test "keeps a timed-out unanswered attempt in the pair rate-limit window" do
      {caller_scope, _recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("calls_expire_rate")

      previous = Application.get_env(:discord_clone, Calls)

      on_exit(fn ->
        if previous do
          Application.put_env(:discord_clone, Calls, previous)
        else
          Application.delete_env(:discord_clone, Calls)
        end
      end)

      Application.put_env(:discord_clone, Calls,
        max_starts_per_caller_per_minute: 5,
        max_unanswered_attempts_per_pair_per_five_minutes: 1
      )

      assert {:ok, %{call: ringing}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      make_ringing_deadline_due!(ringing.call_id)
      assert {:ok, timed_out} = Calls.expire_ringing_attempt(ringing.call_id)
      assert timed_out.terminal_outcome == :timed_out

      assert {:error, :rate_limited} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)
    end

    test "rejects a malformed Call ID without writing" do
      assert {:error, :not_found} = Calls.expire_ringing_attempt("not-a-uuid")
      assert {:error, :not_found} = Calls.expire_ringing_attempt(Ecto.UUID.generate())
    end

    test "CallServer arms its timer from the stored ringing deadline rather than a fresh 30 seconds" do
      {caller_scope, _recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("calls_expire_arm")

      assert {:ok, %{call: ringing}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      [{pid, _}] = Registry.lookup(DiscordClone.Calls.CallRegistry, ringing.call_id)
      now = DateTime.utc_now(:microsecond)

      Repo.get!(CallAttempt, ringing.call_id)
      |> Ecto.Changeset.change(%{
        inserted_at: DateTime.add(now, -10, :second),
        ringing_deadline_at: DateTime.add(now, 1500, :millisecond),
        updated_at: now
      })
      |> Repo.update!()

      :ok = DynamicSupervisor.terminate_child(DiscordClone.Calls.CallSupervisor, pid)
      server = await_replaced_call_server(ringing.call_id, pid)

      assert :ok = CallServer.await_ready(ringing.call_id)
      state = :sys.get_state(server)
      assert state.call_attempt.id == ringing.call_id
      assert is_reference(state.ringing_timer_ref)

      remaining = Process.read_timer(state.ringing_timer_ref)
      assert is_integer(remaining)
      assert remaining <= 1500
      assert remaining >= 0
    end

    test "occupancy release does not terminate the CallServer" do
      {caller_scope, _recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("calls_expire_occ")

      assert {:ok, %{call: ringing}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      [{call_server, _}] = Registry.lookup(DiscordClone.Calls.CallRegistry, ringing.call_id)
      call_server_ref = Process.monitor(call_server)

      assert :ok =
               DiscordClone.Calls.CallCoordinator.release_occupancy(ringing.call_id)

      _ = :sys.get_state(call_server)
      refute_received {:DOWN, ^call_server_ref, :process, ^call_server, _}

      coordinator = :sys.get_state(DiscordClone.Calls.CallCoordinator)
      refute Map.has_key?(coordinator.calls_by_id, ringing.call_id)
      refute Map.has_key?(coordinator.calls_by_direct_conversation, direct_conversation.id)
      assert_call_server_ready(ringing.call_id)

      :ok = CallServer.stop(ringing.call_id)
      assert_receive {:DOWN, ^call_server_ref, :process, ^call_server, _reason}
    end

    test "CallServer delivers a due ringing deadline and stops after timeout" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("calls_expire_timer")

      assert :ok = Calls.subscribe(caller_scope)
      assert :ok = Chat.subscribe_to_activity(recipient_scope)

      assert {:ok, %{call: ringing}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      assert_receive {:call_ringing, _}
      [{call_server, _}] = Registry.lookup(DiscordClone.Calls.CallRegistry, ringing.call_id)
      call_server_ref = Process.monitor(call_server)
      armed_deadline = :sys.get_state(call_server).call_attempt.ringing_deadline_at
      make_ringing_deadline_due!(ringing.call_id)

      send(call_server, {:ringing_deadline, ringing.call_id, armed_deadline})

      assert_receive {:call_timed_out, projection}, 1_000
      assert projection.call_id == ringing.call_id
      assert projection.terminal_outcome == :timed_out
      assert_receive {:activity_changed, _}
      assert_receive {:DOWN, ^call_server_ref, :process, ^call_server, _reason}
      assert_call_server_stopped(ringing.call_id)
      assert length(missed_call_activity_items(recipient_scope.user.id, ringing.call_id)) == 1

      coordinator = :sys.get_state(DiscordClone.Calls.CallCoordinator)
      refute Map.has_key?(coordinator.calls_by_id, ringing.call_id)
    end

    test "CallServer ignores an early timer message and keeps the original deadline armed" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("calls_expire_early_tm")

      assert :ok = Calls.subscribe(caller_scope)
      assert :ok = Chat.subscribe_to_activity(recipient_scope)

      assert {:ok, %{call: ringing}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      assert_receive {:call_ringing, _}
      [{call_server, _}] = Registry.lookup(DiscordClone.Calls.CallRegistry, ringing.call_id)
      original_deadline = ringing.ringing_deadline_at

      send(call_server, {:ringing_deadline, ringing.call_id, original_deadline})
      _ = :sys.get_state(call_server)

      refute_received {:call_timed_out, _}
      refute_received {:activity_changed, _}
      assert_call_server_ready(ringing.call_id)

      reloaded = Repo.get!(CallAttempt, ringing.call_id)
      assert reloaded.state == :ringing
      assert reloaded.ringing_deadline_at == original_deadline
      assert missed_call_activity_items(recipient_scope.user.id, ringing.call_id) == []

      state = :sys.get_state(call_server)
      remaining = Process.read_timer(state.ringing_timer_ref)
      assert is_integer(remaining)
      assert remaining > 0
    end

    test "CallServer ignores stale, duplicate, and old-Call-ID timer messages" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("calls_expire_stale_tm")

      assert :ok = Calls.subscribe(caller_scope)
      assert :ok = Chat.subscribe_to_activity(recipient_scope)

      assert {:ok, %{call: first}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      make_ringing_deadline_due!(first.call_id)
      assert {:ok, timed_out} = Calls.expire_ringing_attempt(first.call_id)
      assert timed_out.terminal_outcome == :timed_out
      assert_receive {:call_timed_out, _}
      assert_receive {:activity_changed, _}

      assert {:ok, %{call: later}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      assert_receive {:call_ringing, _}
      [{later_server, _}] = Registry.lookup(DiscordClone.Calls.CallRegistry, later.call_id)
      later_deadline = later.ringing_deadline_at
      %CallAttempt{updated_at: later_updated_at} = Repo.get!(CallAttempt, later.call_id)

      send(later_server, {:ringing_deadline, first.call_id, first.ringing_deadline_at})
      send(later_server, {:ringing_deadline, later.call_id, first.ringing_deadline_at})
      send(later_server, {:unexpected_timer, later.call_id})
      _ = :sys.get_state(later_server)

      refute_received {:call_timed_out, _}
      refute_received {:activity_changed, _}
      assert_call_server_ready(later.call_id)

      reloaded_later = Repo.get!(CallAttempt, later.call_id)
      assert reloaded_later.state == :ringing
      assert reloaded_later.updated_at == later_updated_at
      assert reloaded_later.ringing_deadline_at == later_deadline
      assert missed_call_activity_items(recipient_scope.user.id, later.call_id) == []

      now = DateTime.utc_now(:microsecond)

      Repo.get!(CallAttempt, later.call_id)
      |> Ecto.Changeset.change(%{state: :connecting, accepted_at: now})
      |> Repo.update!()

      send(later_server, {:ringing_deadline, later.call_id, later_deadline})
      _ = :sys.get_state(later_server)

      reloaded_connecting = Repo.get!(CallAttempt, later.call_id)
      assert reloaded_connecting.state == :connecting
      assert is_nil(reloaded_connecting.terminal_outcome)
      assert missed_call_activity_items(recipient_scope.user.id, later.call_id) == []

      assert [{^later_server, _}] =
               Registry.lookup(DiscordClone.Calls.CallRegistry, later.call_id)

      _ = :sys.get_state(later_server)
    end

    test "CallServer retries a due expire after a transient durable failure" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("calls_expire_retry")

      assert :ok = Calls.subscribe(caller_scope)
      assert :ok = Chat.subscribe_to_activity(recipient_scope)

      assert {:ok, %{call: ringing}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      assert_receive {:call_ringing, _}
      [{call_server, _}] = Registry.lookup(DiscordClone.Calls.CallRegistry, ringing.call_id)
      call_server_ref = Process.monitor(call_server)
      armed_deadline = :sys.get_state(call_server).call_attempt.ringing_deadline_at

      Ecto.Adapters.SQL.query!(
        Repo,
        """
        ALTER TABLE call_attempts
        ADD CONSTRAINT call_attempts_reject_timed_out
        CHECK (terminal_outcome IS DISTINCT FROM 'timed_out')
        """
      )

      make_ringing_deadline_due!(ringing.call_id)
      send(call_server, {:ringing_deadline, ringing.call_id, armed_deadline})
      _ = :sys.get_state(call_server)

      reloaded = Repo.get!(CallAttempt, ringing.call_id)
      assert reloaded.state == :ringing
      assert is_nil(reloaded.terminal_outcome)
      assert missed_call_activity_items(recipient_scope.user.id, ringing.call_id) == []
      assert_call_server_ready(ringing.call_id)

      coordinator = :sys.get_state(DiscordClone.Calls.CallCoordinator)
      assert coordinator.calls_by_id[ringing.call_id] == direct_conversation.id

      retry_state = :sys.get_state(call_server)
      remaining = Process.read_timer(retry_state.ringing_timer_ref)
      assert is_integer(remaining)
      assert remaining >= 0

      Ecto.Adapters.SQL.query!(
        Repo,
        "ALTER TABLE call_attempts DROP CONSTRAINT call_attempts_reject_timed_out"
      )

      send(call_server, {:ringing_deadline, ringing.call_id, armed_deadline})

      assert_receive {:call_timed_out, projection}, 1_000
      assert projection.call_id == ringing.call_id
      assert projection.terminal_outcome == :timed_out
      assert_receive {:activity_changed, _}
      assert_receive {:DOWN, ^call_server_ref, :process, ^call_server, _reason}
      assert_call_server_stopped(ringing.call_id)
      assert length(missed_call_activity_items(recipient_scope.user.id, ringing.call_id)) == 1

      coordinator = :sys.get_state(DiscordClone.Calls.CallCoordinator)
      refute Map.has_key?(coordinator.calls_by_id, ringing.call_id)
    end

    test "CallServer fires immediately when the stored ringing deadline is already due" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("calls_expire_due_now")

      assert :ok = Calls.subscribe(caller_scope)
      assert :ok = Chat.subscribe_to_activity(recipient_scope)

      assert {:ok, %{call: ringing}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      assert_receive {:call_ringing, _}
      [{pid, _}] = Registry.lookup(DiscordClone.Calls.CallRegistry, ringing.call_id)

      assert :ok =
               Supervisor.terminate_child(
                 DiscordClone.Calls.Supervisor,
                 DiscordClone.Calls.CallCoordinator
               )

      :ok = DynamicSupervisor.terminate_child(DiscordClone.Calls.CallSupervisor, pid)
      due_attempt = make_ringing_deadline_due!(ringing.call_id)

      assert {:ok, server} =
               DynamicSupervisor.start_child(
                 DiscordClone.Calls.CallSupervisor,
                 {CallServer, due_attempt}
               )

      server_ref = Process.monitor(server)
      assert_receive {:call_timed_out, projection}, 1_000
      assert projection.call_id == ringing.call_id
      assert projection.terminal_outcome == :timed_out
      assert_receive {:activity_changed, _}
      assert_receive {:DOWN, ^server_ref, :process, ^server, _reason}
      assert length(missed_call_activity_items(recipient_scope.user.id, ringing.call_id)) == 1
    end
  end

  describe "Friendship removal" do
    test "ends a ringing attempt as relationship_ended without Activity or Message" do
      {caller_scope, recipient_scope, direct_conversation, friendship} =
        direct_conversation_fixture("calls_rel_ring")

      messages_before = Repo.aggregate(DiscordClone.Chat.Message, :count)

      assert :ok = Calls.subscribe(caller_scope)
      assert :ok = Calls.subscribe(recipient_scope)

      assert {:ok, %{call: ringing, started?: true}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      assert_receive {:call_ringing, _}
      assert_receive {:call_ringing, _}

      ringing_deadline_at = ringing.ringing_deadline_at
      assert_call_server_ready(ringing.call_id)

      coordinator = :sys.get_state(DiscordClone.Calls.CallCoordinator)
      assert coordinator.calls_by_id[ringing.call_id] == direct_conversation.id

      [{call_server, _}] = Registry.lookup(DiscordClone.Calls.CallRegistry, ringing.call_id)
      call_server_ref = Process.monitor(call_server)

      assert :ok = Friendships.remove_friend(recipient_scope, friendship.id)

      ended = Repo.get!(CallAttempt, ringing.call_id)
      assert ended.state == :terminal
      assert ended.terminal_outcome == :relationship_ended
      assert %DateTime{} = ended.ended_at
      assert ended.ringing_deadline_at == ringing_deadline_at
      assert is_nil(ended.accepted_at)

      assert_receive {:call_relationship_ended, first_projection}
      assert_receive {:call_relationship_ended, second_projection}

      assert MapSet.new([first_projection.call_id, second_projection.call_id]) ==
               MapSet.new([ringing.call_id])

      assert first_projection.state == :terminal
      assert first_projection.terminal_outcome == :relationship_ended
      assert first_projection.ended_at == ended.ended_at
      refute contains_pid?(first_projection)
      refute contains_pid?(second_projection)

      refute_received {:call_cancelled, _}
      refute_received {:call_timed_out, _}

      assert missed_call_activity_items(recipient_scope.user.id, ringing.call_id) == []
      assert missed_call_activity_items(caller_scope.user.id, ringing.call_id) == []
      assert Repo.aggregate(DiscordClone.Chat.Message, :count) == messages_before
      assert {:ok, []} = Chat.list_direct_messages(caller_scope, direct_conversation.id)

      assert_receive {:DOWN, ^call_server_ref, :process, ^call_server, _reason}
      assert_call_server_stopped(ringing.call_id)

      coordinator = :sys.get_state(DiscordClone.Calls.CallCoordinator)
      refute Map.has_key?(coordinator.calls_by_user, caller_scope.user.id)
      refute Map.has_key?(coordinator.calls_by_user, recipient_scope.user.id)
      refute Map.has_key?(coordinator.calls_by_direct_conversation, direct_conversation.id)
      refute Map.has_key?(coordinator.calls_by_id, ringing.call_id)

      assert {:error, :not_found} = Calls.get_call(caller_scope, ringing.call_id)
      assert {:error, :not_found} = Calls.get_call(recipient_scope, ringing.call_id)

      assert {:error, :not_friends} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      assert {:ok, opened} =
               Chat.open_direct_conversation(caller_scope, recipient_scope.user.id)

      assert opened.id == direct_conversation.id
    end

    test "ends connecting and active attempts as relationship_ended without Activity" do
      {caller_scope, recipient_scope, direct_conversation, friendship} =
        direct_conversation_fixture("calls_rel_conn")

      assert {:ok, %{call: ringing}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      now = DateTime.utc_now(:microsecond)

      Repo.get!(CallAttempt, ringing.call_id)
      |> Ecto.Changeset.change(%{state: :connecting, accepted_at: now})
      |> Repo.update!()

      assert :ok = Calls.subscribe(caller_scope)
      assert :ok = Friendships.remove_friend(caller_scope, friendship.id)

      ended = Repo.get!(CallAttempt, ringing.call_id)
      assert ended.state == :terminal
      assert ended.terminal_outcome == :relationship_ended
      assert ended.accepted_at == now
      assert missed_call_activity_items(recipient_scope.user.id, ringing.call_id) == []
      assert_receive {:call_relationship_ended, projection}
      assert projection.call_id == ringing.call_id
      assert_call_server_stopped(ringing.call_id)

      coordinator = :sys.get_state(DiscordClone.Calls.CallCoordinator)
      refute Map.has_key?(coordinator.calls_by_id, ringing.call_id)

      carol_scope = user_scope_fixture(user_fixture(username: "calls_rel_conn_carol"))
      dave_scope = user_scope_fixture(user_fixture(username: "calls_rel_conn_dave"))

      {carol_dave, carol_dave_friendship} =
        befriend_and_open_direct_conversation(carol_scope, dave_scope)

      assert {:ok, %{call: active_ringing}} =
               Calls.start_call(carol_scope, carol_dave.id, :audio)

      accepted_at = DateTime.utc_now(:microsecond)

      Repo.get!(CallAttempt, active_ringing.call_id)
      |> Ecto.Changeset.change(%{state: :active, accepted_at: accepted_at})
      |> Repo.update!()

      assert :ok = Friendships.remove_friend(dave_scope, carol_dave_friendship.id)

      ended_active = Repo.get!(CallAttempt, active_ringing.call_id)
      assert ended_active.state == :terminal
      assert ended_active.terminal_outcome == :relationship_ended
      assert missed_call_activity_items(dave_scope.user.id, active_ringing.call_id) == []
      assert_call_server_stopped(active_ringing.call_id)
    end

    test "leaves an already-terminal attempt unchanged and does not overwrite a later Call ID" do
      {caller_scope, recipient_scope, direct_conversation, friendship} =
        direct_conversation_fixture("calls_rel_term")

      assert {:ok, %{call: first}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      assert {:ok, declined} = Calls.decline_call(recipient_scope, first.call_id)
      assert declined.terminal_outcome == :declined

      assert {:ok, %{call: later, started?: true}} =
               Calls.start_call(caller_scope, direct_conversation.id, :video)

      assert later.call_id != first.call_id

      %CallAttempt{updated_at: first_updated_at, ended_at: first_ended_at} =
        Repo.get!(CallAttempt, first.call_id)

      assert :ok = Friendships.remove_friend(recipient_scope, friendship.id)

      reloaded_first = Repo.get!(CallAttempt, first.call_id)
      assert reloaded_first.terminal_outcome == :declined
      assert reloaded_first.updated_at == first_updated_at
      assert reloaded_first.ended_at == first_ended_at

      reloaded_later = Repo.get!(CallAttempt, later.call_id)
      assert reloaded_later.state == :terminal
      assert reloaded_later.terminal_outcome == :relationship_ended
      assert missed_call_activity_items(recipient_scope.user.id, first.call_id) == []
      assert missed_call_activity_items(recipient_scope.user.id, later.call_id) == []

      coordinator = :sys.get_state(DiscordClone.Calls.CallCoordinator)
      refute Map.has_key?(coordinator.calls_by_id, first.call_id)
      refute Map.has_key?(coordinator.calls_by_id, later.call_id)
      refute Map.has_key?(coordinator.calls_by_direct_conversation, direct_conversation.id)
    end

    test "rolls back the attempt write without projecting occupancy or PubSub" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("calls_rel_roll")

      assert :ok = Calls.subscribe(caller_scope)
      assert :ok = Calls.subscribe(recipient_scope)

      assert {:ok, %{call: ringing}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      assert_receive {:call_ringing, _}
      assert_receive {:call_ringing, _}
      assert_call_server_ready(ringing.call_id)

      %CallAttempt{updated_at: updated_at} = Repo.get!(CallAttempt, ringing.call_id)

      assert {:error, :leave_attempt} =
               Repo.transaction(fn ->
                 assert {:ok,
                         %CallAttempt{state: :terminal, terminal_outcome: :relationship_ended}} =
                          Calls.end_attempt_for_removed_friendship(
                            caller_scope.user.id,
                            recipient_scope.user.id
                          )

                 Repo.rollback(:leave_attempt)
               end)

      reloaded = Repo.get!(CallAttempt, ringing.call_id)
      assert reloaded.state == :ringing
      assert reloaded.updated_at == updated_at
      assert is_nil(reloaded.terminal_outcome)
      assert is_nil(reloaded.ended_at)
      assert_call_server_ready(ringing.call_id)

      coordinator = :sys.get_state(DiscordClone.Calls.CallCoordinator)
      assert coordinator.calls_by_id[ringing.call_id] == direct_conversation.id
      assert coordinator.calls_by_direct_conversation[direct_conversation.id] == ringing.call_id
      assert coordinator.calls_by_user[caller_scope.user.id] == ringing.call_id
      assert coordinator.calls_by_user[recipient_scope.user.id] == ringing.call_id

      refute_received {:call_relationship_ended, _}
      assert missed_call_activity_items(recipient_scope.user.id, ringing.call_id) == []
    end

    test "a rolled-back Friendship removal leaves the attempt, occupancy, and Friendship unchanged" do
      {caller_scope, recipient_scope, direct_conversation, friendship} =
        direct_conversation_fixture("calls_rel_rm_roll")

      assert :ok = Calls.subscribe(caller_scope)
      assert :ok = Calls.subscribe(recipient_scope)

      assert {:ok, %{call: ringing}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      assert_receive {:call_ringing, _}
      assert_receive {:call_ringing, _}
      assert_call_server_ready(ringing.call_id)

      %CallAttempt{updated_at: updated_at} = Repo.get!(CallAttempt, ringing.call_id)

      Ecto.Adapters.SQL.query!(
        Repo,
        """
        CREATE OR REPLACE FUNCTION reject_friend_relationship_delete() RETURNS trigger AS $$
        BEGIN
          RAISE EXCEPTION 'reject_friend_relationship_delete';
        END;
        $$ LANGUAGE plpgsql
        """
      )

      Ecto.Adapters.SQL.query!(
        Repo,
        "DROP TRIGGER IF EXISTS reject_friend_relationship_delete ON friend_relationships"
      )

      Ecto.Adapters.SQL.query!(
        Repo,
        """
        CREATE TRIGGER reject_friend_relationship_delete
        BEFORE DELETE ON friend_relationships
        FOR EACH ROW EXECUTE FUNCTION reject_friend_relationship_delete()
        """
      )

      assert_raise Postgrex.Error, ~r/reject_friend_relationship_delete/, fn ->
        Friendships.remove_friend(recipient_scope, friendship.id)
      end

      assert Friendships.friends?(caller_scope, recipient_scope.user.id)

      reloaded = Repo.get!(CallAttempt, ringing.call_id)
      assert reloaded.state == :ringing
      assert reloaded.updated_at == updated_at
      assert is_nil(reloaded.terminal_outcome)
      assert is_nil(reloaded.ended_at)
      assert_call_server_ready(ringing.call_id)

      coordinator = :sys.get_state(DiscordClone.Calls.CallCoordinator)
      assert coordinator.calls_by_id[ringing.call_id] == direct_conversation.id
      assert coordinator.calls_by_direct_conversation[direct_conversation.id] == ringing.call_id
      assert coordinator.calls_by_user[caller_scope.user.id] == ringing.call_id
      assert coordinator.calls_by_user[recipient_scope.user.id] == ringing.call_id

      refute_received {:call_relationship_ended, _}
      assert missed_call_activity_items(recipient_scope.user.id, ringing.call_id) == []
    end

    test "maps unexpected durable failures without leaking a changeset" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("calls_rel_clock")

      assert {:ok, %{call: ringing}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      future = DateTime.add(DateTime.utc_now(:microsecond), 3600, :second)

      Repo.get!(CallAttempt, ringing.call_id)
      |> Ecto.Changeset.change(%{
        inserted_at: future,
        ringing_deadline_at: DateTime.add(future, 30, :second),
        updated_at: future
      })
      |> Repo.update!()

      assert {:error, :temporarily_unavailable} =
               Calls.end_attempt_for_removed_friendship(
                 caller_scope.user.id,
                 recipient_scope.user.id
               )

      reloaded = Repo.get!(CallAttempt, ringing.call_id)
      assert reloaded.state == :ringing
      assert is_nil(reloaded.terminal_outcome)
    end

    test "keeps remove_friend in its documented error atoms when the call write fails" do
      {caller_scope, recipient_scope, direct_conversation, friendship} =
        direct_conversation_fixture("calls_rel_rm_clock")

      assert :ok = Calls.subscribe(caller_scope)

      assert {:ok, %{call: ringing}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      assert_receive {:call_ringing, _}
      assert_call_server_ready(ringing.call_id)

      future = DateTime.add(DateTime.utc_now(:microsecond), 3600, :second)

      Repo.get!(CallAttempt, ringing.call_id)
      |> Ecto.Changeset.change(%{
        inserted_at: future,
        ringing_deadline_at: DateTime.add(future, 30, :second),
        updated_at: future
      })
      |> Repo.update!()

      assert {:error, :stale_state} = Friendships.remove_friend(caller_scope, friendship.id)
      assert Friendships.friends?(caller_scope, recipient_scope.user.id)

      reloaded = Repo.get!(CallAttempt, ringing.call_id)
      assert reloaded.state == :ringing
      assert is_nil(reloaded.terminal_outcome)
      assert_call_server_ready(ringing.call_id)

      coordinator = :sys.get_state(DiscordClone.Calls.CallCoordinator)
      assert coordinator.calls_by_id[ringing.call_id] == direct_conversation.id
      refute_received {:call_relationship_ended, _}
    end

    test "does not let a leftover ringing timer overwrite relationship_ended" do
      {caller_scope, recipient_scope, direct_conversation, friendship} =
        direct_conversation_fixture("calls_rel_timer")

      assert {:ok, %{call: ringing}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      assert :ok = Friendships.remove_friend(caller_scope, friendship.id)

      make_ringing_deadline_due!(ringing.call_id)
      assert {:ok, projection} = Calls.expire_ringing_attempt(ringing.call_id)
      assert projection.terminal_outcome == :relationship_ended

      reloaded = Repo.get!(CallAttempt, ringing.call_id)
      assert reloaded.terminal_outcome == :relationship_ended
      assert missed_call_activity_items(recipient_scope.user.id, ringing.call_id) == []
    end
  end

  describe "recovery" do
    test "rebuilds a crashed CallServer from the committed future-deadline ringing attempt" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("calls_rec_crash")

      assert :ok = Calls.subscribe(caller_scope)
      assert :ok = Calls.subscribe(recipient_scope)

      assert {:ok, %{call: ringing, started?: true}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      assert_receive {:call_ringing, _}
      assert_receive {:call_ringing, _}

      original_deadline = ringing.ringing_deadline_at
      [{old_pid, _}] = Registry.lookup(DiscordClone.Calls.CallRegistry, ringing.call_id)
      old_ref = Process.monitor(old_pid)

      :ok = DynamicSupervisor.terminate_child(DiscordClone.Calls.CallSupervisor, old_pid)
      assert_receive {:DOWN, ^old_ref, :process, ^old_pid, _reason}

      new_pid = await_replaced_call_server(ringing.call_id, old_pid)
      assert_call_server_ready(ringing.call_id)

      assert {:ok, recovered} = Calls.get_call(caller_scope, ringing.call_id)
      assert recovered.call_id == ringing.call_id
      assert recovered.state == :ringing
      assert recovered.ringing_deadline_at == original_deadline

      reloaded = Repo.get!(CallAttempt, ringing.call_id)
      assert reloaded.state == :ringing
      assert reloaded.ringing_deadline_at == original_deadline
      assert is_nil(reloaded.terminal_outcome)

      coordinator = :sys.get_state(DiscordClone.Calls.CallCoordinator)
      assert coordinator.calls_by_id[ringing.call_id] == direct_conversation.id
      assert coordinator.calls_by_direct_conversation[direct_conversation.id] == ringing.call_id
      assert coordinator.calls_by_user[caller_scope.user.id] == ringing.call_id
      assert coordinator.calls_by_user[recipient_scope.user.id] == ringing.call_id

      assert_receive {:call_ringing, first_projection}
      assert_receive {:call_ringing, second_projection}

      assert MapSet.new([first_projection.call_id, second_projection.call_id]) ==
               MapSet.new([ringing.call_id])

      assert first_projection.ringing_deadline_at == original_deadline
      refute contains_pid?(first_projection)
      refute contains_pid?(second_projection)

      remaining = Process.read_timer(:sys.get_state(new_pid).ringing_timer_ref)
      assert is_integer(remaining)
      assert remaining >= 0
      assert remaining <= 30_000

      assert missed_call_activity_items(recipient_scope.user.id, ringing.call_id) == []
    end

    test "expires an overdue ringing attempt after runtime restart with exactly one missed-call Activity" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("calls_rec_overdue")

      assert :ok = Calls.subscribe(caller_scope)
      assert :ok = Chat.subscribe_to_activity(recipient_scope)

      assert {:ok, %{call: ringing, started?: true}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      assert_receive {:call_ringing, _}
      due_attempt = make_ringing_deadline_due!(ringing.call_id)
      restart_calls_runtime()

      assert_receive {:call_timed_out, projection}
      assert projection.call_id == ringing.call_id
      assert projection.state == :terminal
      assert projection.terminal_outcome == :timed_out
      assert_receive {:activity_changed, _}

      reloaded = Repo.get!(CallAttempt, ringing.call_id)
      assert reloaded.state == :terminal
      assert reloaded.terminal_outcome == :timed_out
      assert reloaded.ringing_deadline_at == due_attempt.ringing_deadline_at
      assert length(missed_call_activity_items(recipient_scope.user.id, ringing.call_id)) == 1
      assert_call_server_stopped(ringing.call_id)

      coordinator = :sys.get_state(DiscordClone.Calls.CallCoordinator)
      refute Map.has_key?(coordinator.calls_by_id, ringing.call_id)
      refute Map.has_key?(coordinator.calls_by_direct_conversation, direct_conversation.id)
      refute Map.has_key?(coordinator.calls_by_user, caller_scope.user.id)
      refute Map.has_key?(coordinator.calls_by_user, recipient_scope.user.id)

      refute_received {:call_ringing, _}
    end

    test "leaves a terminal attempt without a CallServer or busy index and allows a later Call ID" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("calls_rec_term")

      assert {:ok, %{call: first, started?: true}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      assert {:ok, declined} = Calls.decline_call(recipient_scope, first.call_id)
      assert declined.terminal_outcome == :declined
      assert_call_server_stopped(first.call_id)

      %CallAttempt{updated_at: first_updated_at, ended_at: first_ended_at} =
        Repo.get!(CallAttempt, first.call_id)

      restart_calls_runtime()

      reloaded = Repo.get!(CallAttempt, first.call_id)
      assert reloaded.terminal_outcome == :declined
      assert reloaded.updated_at == first_updated_at
      assert reloaded.ended_at == first_ended_at
      assert_call_server_stopped(first.call_id)
      assert missed_call_activity_items(recipient_scope.user.id, first.call_id) == []

      coordinator = :sys.get_state(DiscordClone.Calls.CallCoordinator)
      refute Map.has_key?(coordinator.calls_by_id, first.call_id)
      refute Map.has_key?(coordinator.calls_by_direct_conversation, direct_conversation.id)
      refute Map.has_key?(coordinator.calls_by_user, caller_scope.user.id)

      assert {:ok, %{call: later, started?: true}} =
               Calls.start_call(caller_scope, direct_conversation.id, :video)

      assert later.call_id != first.call_id
      assert later.state == :ringing
      assert_call_server_ready(later.call_id)

      coordinator = :sys.get_state(DiscordClone.Calls.CallCoordinator)
      assert coordinator.calls_by_id[later.call_id] == direct_conversation.id
      refute Map.has_key?(coordinator.calls_by_id, first.call_id)
    end

    test "marks connecting and active attempts interrupted after a full Calls-subtree restart" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("calls_rec_intr")

      assert :ok = Calls.subscribe(caller_scope)
      assert :ok = Calls.subscribe(recipient_scope)

      assert {:ok, %{call: connecting_ringing}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      assert_receive {:call_ringing, _}
      assert_receive {:call_ringing, _}

      now = DateTime.utc_now(:microsecond)

      Repo.get!(CallAttempt, connecting_ringing.call_id)
      |> Ecto.Changeset.change(%{state: :connecting, accepted_at: now})
      |> Repo.update!()

      carol_scope = user_scope_fixture(user_fixture(username: "calls_rec_intr_carol"))
      dave_scope = user_scope_fixture(user_fixture(username: "calls_rec_intr_dave"))
      {carol_dave, _friendship} = befriend_and_open_direct_conversation(carol_scope, dave_scope)

      assert {:ok, %{call: active_ringing}} =
               Calls.start_call(carol_scope, carol_dave.id, :audio)

      accepted_at = DateTime.utc_now(:microsecond)

      Repo.get!(CallAttempt, active_ringing.call_id)
      |> Ecto.Changeset.change(%{state: :active, accepted_at: accepted_at})
      |> Repo.update!()

      restart_calls_runtime()

      assert_receive {:call_interrupted, connecting_projection}
      assert connecting_projection.call_id == connecting_ringing.call_id
      assert connecting_projection.state == :terminal
      assert connecting_projection.terminal_outcome == :interrupted
      refute contains_pid?(connecting_projection)

      connecting = Repo.get!(CallAttempt, connecting_ringing.call_id)
      assert connecting.state == :terminal
      assert connecting.terminal_outcome == :interrupted
      assert connecting.accepted_at == now
      assert missed_call_activity_items(recipient_scope.user.id, connecting_ringing.call_id) == []
      assert_call_server_stopped(connecting_ringing.call_id)

      active = Repo.get!(CallAttempt, active_ringing.call_id)
      assert active.state == :terminal
      assert active.terminal_outcome == :interrupted
      assert active.accepted_at == accepted_at
      assert missed_call_activity_items(dave_scope.user.id, active_ringing.call_id) == []
      assert_call_server_stopped(active_ringing.call_id)

      coordinator = :sys.get_state(DiscordClone.Calls.CallCoordinator)
      refute Map.has_key?(coordinator.calls_by_id, connecting_ringing.call_id)
      refute Map.has_key?(coordinator.calls_by_id, active_ringing.call_id)

      refute_received {:call_ringing, _}
      refute_received {:call_timed_out, _}
    end

    test "ends future ringing as relationship_ended when Friendship is already gone at recovery" do
      {caller_scope, recipient_scope, direct_conversation, friendship} =
        direct_conversation_fixture("calls_rec_rel")

      assert :ok = Calls.subscribe(caller_scope)
      assert :ok = Calls.subscribe(recipient_scope)

      assert {:ok, %{call: ringing, started?: true}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      assert_receive {:call_ringing, _}
      assert_receive {:call_ringing, _}
      ringing_deadline_at = ringing.ringing_deadline_at

      Repo.delete!(Repo.get!(Relationship, friendship.id))
      restart_calls_runtime()

      assert_receive {:call_relationship_ended, first_projection}
      assert_receive {:call_relationship_ended, second_projection}

      assert MapSet.new([first_projection.call_id, second_projection.call_id]) ==
               MapSet.new([ringing.call_id])

      assert first_projection.state == :terminal
      assert first_projection.terminal_outcome == :relationship_ended
      refute contains_pid?(first_projection)

      ended = Repo.get!(CallAttempt, ringing.call_id)
      assert ended.state == :terminal
      assert ended.terminal_outcome == :relationship_ended
      assert ended.ringing_deadline_at == ringing_deadline_at
      assert missed_call_activity_items(recipient_scope.user.id, ringing.call_id) == []
      assert missed_call_activity_items(caller_scope.user.id, ringing.call_id) == []
      assert_call_server_stopped(ringing.call_id)

      coordinator = :sys.get_state(DiscordClone.Calls.CallCoordinator)
      refute Map.has_key?(coordinator.calls_by_id, ringing.call_id)

      assert {:error, :not_found} = Calls.get_call(caller_scope, ringing.call_id)
      refute_received {:call_ringing, _}
      refute_received {:call_timed_out, _}
    end

    test "fails closed when two nonterminal attempts occupy the same User" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("calls_rec_dup")

      assert {:ok, %{call: first}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      carol_scope = user_scope_fixture(user_fixture(username: "calls_rec_dup_carol"))

      {caller_carol, _friendship} =
        befriend_and_open_direct_conversation(caller_scope, carol_scope)

      second =
        insert_call_attempt(caller_scope, carol_scope, caller_carol, %{
          inserted_at: DateTime.utc_now(:microsecond),
          state: :ringing
        })

      restart_calls_runtime()

      reloaded_first = Repo.get!(CallAttempt, first.call_id)
      reloaded_second = Repo.get!(CallAttempt, second.id)
      assert reloaded_first.state == :ringing
      assert reloaded_second.state == :ringing
      assert is_nil(reloaded_first.terminal_outcome)
      assert is_nil(reloaded_second.terminal_outcome)
      assert_call_server_stopped(first.call_id)
      assert_call_server_stopped(second.id)
      assert missed_call_activity_items(recipient_scope.user.id, first.call_id) == []
      assert missed_call_activity_items(carol_scope.user.id, second.id) == []

      coordinator = :sys.get_state(DiscordClone.Calls.CallCoordinator)
      refute Map.has_key?(coordinator.calls_by_id, first.call_id)
      refute Map.has_key?(coordinator.calls_by_id, second.id)

      assert {:error, :temporarily_unavailable} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      assert Repo.get!(CallAttempt, first.call_id).state == :ringing
      assert Repo.get!(CallAttempt, second.id).state == :ringing
    end

    test "rebuilds occupancy and the CallServer after CallCoordinator restarts" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("calls_rec_coord")

      assert :ok = Calls.subscribe(caller_scope)

      assert {:ok, %{call: ringing, started?: true}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      assert_receive {:call_ringing, _}
      [{server_pid, _}] = Registry.lookup(DiscordClone.Calls.CallRegistry, ringing.call_id)
      original_deadline = ringing.ringing_deadline_at

      assert :ok =
               Supervisor.terminate_child(
                 DiscordClone.Calls.Supervisor,
                 DiscordClone.Calls.CallCoordinator
               )

      assert {:ok, _pid} =
               Supervisor.restart_child(
                 DiscordClone.Calls.Supervisor,
                 DiscordClone.Calls.CallCoordinator
               )

      DiscordClone.Calls.CallCoordinator.begin_recovery()
      await_recovery_finished()
      assert_call_server_ready(ringing.call_id)

      assert [{^server_pid, _}] =
               Registry.lookup(DiscordClone.Calls.CallRegistry, ringing.call_id)

      coordinator = :sys.get_state(DiscordClone.Calls.CallCoordinator)
      assert coordinator.calls_by_id[ringing.call_id] == direct_conversation.id
      assert coordinator.calls_by_direct_conversation[direct_conversation.id] == ringing.call_id
      assert coordinator.calls_by_user[caller_scope.user.id] == ringing.call_id
      assert coordinator.calls_by_user[recipient_scope.user.id] == ringing.call_id

      assert {:ok, recovered} = Calls.get_call(recipient_scope, ringing.call_id)
      assert recovered.call_id == ringing.call_id
      assert recovered.state == :ringing
      assert recovered.ringing_deadline_at == original_deadline

      assert_receive {:call_ringing, projection}
      assert projection.call_id == ringing.call_id
      assert projection.ringing_deadline_at == original_deadline
    end

    test "does not interrupt a connecting attempt when only CallCoordinator restarts" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("calls_rec_coord_conn")

      assert :ok = Calls.subscribe(caller_scope)

      assert {:ok, %{call: ringing}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      now = DateTime.utc_now(:microsecond)

      Repo.get!(CallAttempt, ringing.call_id)
      |> Ecto.Changeset.change(%{state: :connecting, accepted_at: now})
      |> Repo.update!()

      [{server_pid, _}] = Registry.lookup(DiscordClone.Calls.CallRegistry, ringing.call_id)

      assert :ok =
               Supervisor.terminate_child(
                 DiscordClone.Calls.Supervisor,
                 DiscordClone.Calls.CallCoordinator
               )

      assert {:ok, _pid} =
               Supervisor.restart_child(
                 DiscordClone.Calls.Supervisor,
                 DiscordClone.Calls.CallCoordinator
               )

      DiscordClone.Calls.CallCoordinator.begin_recovery()
      await_recovery_finished()

      reloaded = Repo.get!(CallAttempt, ringing.call_id)
      assert reloaded.state == :connecting
      assert is_nil(reloaded.terminal_outcome)
      assert reloaded.accepted_at == now
      assert missed_call_activity_items(recipient_scope.user.id, ringing.call_id) == []

      assert [{^server_pid, _}] =
               Registry.lookup(DiscordClone.Calls.CallRegistry, ringing.call_id)

      coordinator = :sys.get_state(DiscordClone.Calls.CallCoordinator)
      assert coordinator.calls_by_id[ringing.call_id] == direct_conversation.id
      refute_received {:call_interrupted, _}
    end

    test "fails closed after repeated CallServer crashes of the same Call ID" do
      {caller_scope, _recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("calls_rec_crash_cap")

      assert {:ok, %{call: ringing, started?: true}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      Enum.each(1..3, fn _index ->
        [{pid, _}] = Registry.lookup(DiscordClone.Calls.CallRegistry, ringing.call_id)
        ref = Process.monitor(pid)
        Process.exit(pid, :kill)
        assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
        await_replaced_call_server(ringing.call_id, pid)
      end)

      [{pid, _}] = Registry.lookup(DiscordClone.Calls.CallRegistry, ringing.call_id)
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
      _ = :sys.get_state(DiscordClone.Calls.CallCoordinator)
      assert_call_server_stopped(ringing.call_id)

      assert {:error, :temporarily_unavailable} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      reloaded = Repo.get!(CallAttempt, ringing.call_id)
      assert reloaded.state == :ringing
    end

    test "returns temporarily_unavailable when CallCoordinator is down" do
      {caller_scope, _recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("calls_rec_coord_down")

      assert :ok =
               Supervisor.terminate_child(
                 DiscordClone.Calls.Supervisor,
                 DiscordClone.Calls.CallCoordinator
               )

      assert {:error, :temporarily_unavailable} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)
    end

    test "rebuilds future ringing from Postgres after a Registry rest_for_one restart" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("calls_rec_reg")

      assert :ok = Calls.subscribe(caller_scope)

      assert {:ok, %{call: ringing, started?: true}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      assert_receive {:call_ringing, _}
      original_deadline = ringing.ringing_deadline_at
      [{old_pid, _}] = Registry.lookup(DiscordClone.Calls.CallRegistry, ringing.call_id)
      old_ref = Process.monitor(old_pid)
      old_coordinator = Process.whereis(DiscordClone.Calls.CallCoordinator)

      registry = Process.whereis(DiscordClone.Calls.CallRegistry)
      ref = Process.monitor(registry)
      Process.exit(registry, :kill)
      assert_receive {:DOWN, ^ref, :process, ^registry, :killed}

      await_replaced_named_process(DiscordClone.Calls.CallCoordinator, old_coordinator)
      DiscordClone.Calls.CallCoordinator.begin_recovery()
      await_recovery_finished()
      await_replaced_call_server(ringing.call_id, old_pid)
      assert_receive {:DOWN, ^old_ref, :process, ^old_pid, _reason}

      assert {:ok, recovered} = Calls.get_call(caller_scope, ringing.call_id)
      assert recovered.call_id == ringing.call_id
      assert recovered.state == :ringing
      assert recovered.ringing_deadline_at == original_deadline
      assert_call_server_ready(ringing.call_id)

      coordinator = :sys.get_state(DiscordClone.Calls.CallCoordinator)
      assert coordinator.calls_by_id[ringing.call_id] == direct_conversation.id
      assert coordinator.calls_by_user[recipient_scope.user.id] == ringing.call_id

      assert_receive {:call_ringing, projection}
      assert projection.call_id == ringing.call_id
    end
  end

  describe "pruning" do
    test "deletes a terminal attempt whose ended_at is at least seven days old" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("calls_prune_old")

      now = DateTime.utc_now(:microsecond)
      ended_at = DateTime.add(now, -7, :day)

      attempt =
        insert_call_attempt(caller_scope, recipient_scope, direct_conversation, %{
          inserted_at: DateTime.add(ended_at, -30, :second),
          terminal_outcome: :declined,
          ended_at: ended_at
        })

      restart_calls_runtime()

      assert is_nil(Repo.get(CallAttempt, attempt.id))
      assert missed_call_activity_items(recipient_scope.user.id, attempt.id) == []
    end

    test "retains a seven-day cancelled attempt when its missed-call Activity is missing" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("calls_prune_cxl_miss")

      now = DateTime.utc_now(:microsecond)
      ended_at = DateTime.add(now, -7, :day)

      attempt =
        insert_call_attempt(caller_scope, recipient_scope, direct_conversation, %{
          inserted_at: DateTime.add(ended_at, -30, :second),
          terminal_outcome: :cancelled,
          ended_at: ended_at
        })

      restart_calls_runtime()

      reloaded = Repo.get!(CallAttempt, attempt.id)
      assert reloaded.state == :terminal
      assert reloaded.terminal_outcome == :cancelled
      assert reloaded.ended_at == attempt.ended_at
      assert missed_call_activity_items(recipient_scope.user.id, attempt.id) == []

      assert {:ok, %{deleted: 0, retained: 1}} =
               Calls.prune_safely_materialized_terminal_attempts()
    end

    test "retains a seven-day timed_out attempt when its missed-call Activity is missing" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("calls_prune_to_miss")

      now = DateTime.utc_now(:microsecond)
      ended_at = DateTime.add(now, -7, :day)

      attempt =
        insert_call_attempt(caller_scope, recipient_scope, direct_conversation, %{
          inserted_at: DateTime.add(ended_at, -30, :second),
          terminal_outcome: :timed_out,
          ended_at: ended_at
        })

      restart_calls_runtime()

      reloaded = Repo.get!(CallAttempt, attempt.id)
      assert reloaded.state == :terminal
      assert reloaded.terminal_outcome == :timed_out
      assert missed_call_activity_items(recipient_scope.user.id, attempt.id) == []
    end

    test "deletes a seven-day cancelled attempt after its missed-call Activity exists and keeps that item" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("calls_prune_cxl_keep")

      assert {:ok, %{call: ringing}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      assert {:ok, cancelled} = Calls.cancel_call(caller_scope, ringing.call_id)
      [item] = missed_call_activity_items(recipient_scope.user.id, cancelled.call_id)
      assert item.source_call_attempt_id == cancelled.call_id
      assert item.source_conversation_id == direct_conversation.id

      backdate_terminal_attempt!(
        cancelled.call_id,
        DateTime.add(DateTime.utc_now(:microsecond), -7, :day)
      )

      run_coordinator_prune()

      assert is_nil(Repo.get(CallAttempt, cancelled.call_id))
      assert [kept] = missed_call_activity_items(recipient_scope.user.id, cancelled.call_id)
      assert kept.id == item.id
      assert kept.source_call_attempt_id == cancelled.call_id
      assert kept.source_conversation_id == direct_conversation.id
    end

    test "deletes a seven-day timed_out attempt after its missed-call Activity exists and keeps that item" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("calls_prune_to_keep")

      assert {:ok, %{call: ringing}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      make_ringing_deadline_due!(ringing.call_id)
      assert {:ok, timed_out} = Calls.expire_ringing_attempt(ringing.call_id)
      [item] = missed_call_activity_items(recipient_scope.user.id, timed_out.call_id)

      backdate_terminal_attempt!(
        timed_out.call_id,
        DateTime.add(DateTime.utc_now(:microsecond), -7, :day)
      )

      run_coordinator_prune()

      assert is_nil(Repo.get(CallAttempt, timed_out.call_id))
      assert [kept] = missed_call_activity_items(recipient_scope.user.id, timed_out.call_id)
      assert kept.id == item.id
      assert kept.source_call_attempt_id == timed_out.call_id
    end

    test "deletes seven-day terminals that never create missed-call Activity" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("calls_prune_other")

      now = DateTime.utc_now(:microsecond)
      ended_at = DateTime.add(now, -7, :day)
      inserted_at = DateTime.add(ended_at, -30, :second)

      outcomes = [
        :declined,
        :relationship_ended,
        :interrupted,
        :failed,
        :failed_capacity,
        :ended
      ]

      attempts =
        Enum.map(outcomes, fn terminal_outcome ->
          insert_call_attempt(caller_scope, recipient_scope, direct_conversation, %{
            inserted_at: inserted_at,
            accepted_at:
              if(terminal_outcome in [:interrupted, :ended],
                do: DateTime.add(ended_at, -1, :second)
              ),
            terminal_outcome: terminal_outcome,
            ended_at: ended_at
          })
        end)

      run_coordinator_prune()

      Enum.each(attempts, fn attempt ->
        assert is_nil(Repo.get(CallAttempt, attempt.id))
        assert missed_call_activity_items(recipient_scope.user.id, attempt.id) == []
      end)
    end

    test "retains nonterminal attempts and terminal attempts younger than seven days" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("calls_prune_fresh")

      assert {:ok, %{call: ringing}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      carol_scope = user_scope_fixture(user_fixture(username: "calls_prune_fresh_carol"))
      dave_scope = user_scope_fixture(user_fixture(username: "calls_prune_fresh_dave"))
      {carol_dave, _friendship} = befriend_and_open_direct_conversation(carol_scope, dave_scope)

      now = DateTime.utc_now(:microsecond)

      connecting =
        insert_call_attempt(carol_scope, dave_scope, carol_dave, %{
          inserted_at: now,
          accepted_at: now,
          state: :connecting
        })

      eve_scope = user_scope_fixture(user_fixture(username: "calls_prune_fresh_eve"))
      frank_scope = user_scope_fixture(user_fixture(username: "calls_prune_fresh_frank"))
      {eve_frank, _friendship} = befriend_and_open_direct_conversation(eve_scope, frank_scope)

      active =
        insert_call_attempt(eve_scope, frank_scope, eve_frank, %{
          inserted_at: now,
          accepted_at: now,
          state: :active
        })

      six_days_ago = DateTime.add(now, -6, :day)

      young =
        insert_call_attempt(caller_scope, recipient_scope, direct_conversation, %{
          inserted_at: DateTime.add(six_days_ago, -30, :second),
          terminal_outcome: :declined,
          ended_at: six_days_ago
        })

      just_under_ended_at = DateTime.add(DateTime.add(now, -7, :day), 1, :second)

      just_under =
        insert_call_attempt(caller_scope, recipient_scope, direct_conversation, %{
          inserted_at: DateTime.add(just_under_ended_at, -30, :second),
          terminal_outcome: :declined,
          ended_at: just_under_ended_at
        })

      run_coordinator_prune()

      assert Repo.get!(CallAttempt, ringing.call_id).state == :ringing
      assert Repo.get!(CallAttempt, connecting.id).state == :connecting
      assert Repo.get!(CallAttempt, active.id).state == :active
      assert Repo.get!(CallAttempt, young.id).state == :terminal
      assert Repo.get!(CallAttempt, young.id).terminal_outcome == :declined
      assert Repo.get!(CallAttempt, just_under.id).state == :terminal
      assert_call_server_ready(ringing.call_id)
    end

    test "a pruned Call ID is not_found and cannot mutate a later same-pair attempt" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("calls_prune_later")

      assert {:ok, %{call: ringing}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      assert {:ok, cancelled} = Calls.cancel_call(caller_scope, ringing.call_id)
      [item] = missed_call_activity_items(recipient_scope.user.id, cancelled.call_id)
      pruned_id = cancelled.call_id

      backdate_terminal_attempt!(
        pruned_id,
        DateTime.add(DateTime.utc_now(:microsecond), -7, :day)
      )

      run_coordinator_prune()

      assert is_nil(Repo.get(CallAttempt, pruned_id))
      assert {:error, :not_found} = Calls.get_call(caller_scope, pruned_id)
      assert {:error, :not_found} = Calls.decline_call(recipient_scope, pruned_id)
      assert {:error, :not_found} = Calls.cancel_call(caller_scope, pruned_id)
      assert {:error, :not_found} = Calls.expire_ringing_attempt(pruned_id)

      assert {:ok, %{call: later, started?: true}} =
               Calls.start_call(caller_scope, direct_conversation.id, :video)

      assert later.call_id != pruned_id
      assert later.state == :ringing
      assert_call_server_ready(later.call_id)

      assert {:error, :not_found} = Calls.decline_call(recipient_scope, pruned_id)
      assert {:error, :not_found} = Calls.cancel_call(caller_scope, pruned_id)

      assert {:ok, still_ringing} = Calls.get_call(caller_scope, later.call_id)
      assert still_ringing.call_id == later.call_id
      assert still_ringing.state == :ringing

      coordinator = :sys.get_state(DiscordClone.Calls.CallCoordinator)
      refute Map.has_key?(coordinator.calls_by_id, pruned_id)
      assert coordinator.calls_by_id[later.call_id] == direct_conversation.id
      assert coordinator.calls_by_direct_conversation[direct_conversation.id] == later.call_id

      assert [kept] = missed_call_activity_items(recipient_scope.user.id, pruned_id)
      assert kept.id == item.id
      assert kept.source_call_attempt_id == pruned_id
    end

    test "does not let unmaterialized ringing cancellations starve other prunable terminals" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("calls_prune_starve")

      now = DateTime.utc_now(:microsecond)
      cancelled_ended_at = DateTime.add(now, -8, :day)
      declined_ended_at = DateTime.add(now, -7, :day)

      Enum.each(1..100, fn _index ->
        insert_call_attempt(caller_scope, recipient_scope, direct_conversation, %{
          inserted_at: DateTime.add(cancelled_ended_at, -30, :second),
          terminal_outcome: :cancelled,
          ended_at: cancelled_ended_at
        })
      end)

      declined =
        insert_call_attempt(caller_scope, recipient_scope, direct_conversation, %{
          inserted_at: DateTime.add(declined_ended_at, -30, :second),
          terminal_outcome: :declined,
          ended_at: declined_ended_at
        })

      run_coordinator_prune()

      assert is_nil(Repo.get(CallAttempt, declined.id))

      retained =
        Repo.aggregate(
          from(call_attempt in CallAttempt,
            where:
              call_attempt.direct_conversation_id == ^direct_conversation.id and
                call_attempt.terminal_outcome == :cancelled
          ),
          :count
        )

      assert retained == 100
    end

    test "prunes a seven-day connecting cancellation that never creates missed-call Activity" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("calls_prune_conn_cxl")

      now = DateTime.utc_now(:microsecond)
      ended_at = DateTime.add(now, -7, :day)

      attempt =
        insert_call_attempt(caller_scope, recipient_scope, direct_conversation, %{
          inserted_at: DateTime.add(ended_at, -30, :second),
          accepted_at: DateTime.add(ended_at, -1, :second),
          terminal_outcome: :cancelled,
          ended_at: ended_at
        })

      run_coordinator_prune()

      assert is_nil(Repo.get(CallAttempt, attempt.id))
      assert missed_call_activity_items(recipient_scope.user.id, attempt.id) == []
    end

    test "repeating prune against an empty candidate set is a no-op" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("calls_prune_idem")

      now = DateTime.utc_now(:microsecond)
      ended_at = DateTime.add(now, -7, :day)

      attempt =
        insert_call_attempt(caller_scope, recipient_scope, direct_conversation, %{
          inserted_at: DateTime.add(ended_at, -30, :second),
          terminal_outcome: :declined,
          ended_at: ended_at
        })

      assert {:ok, %{deleted: 1, retained: 0}} =
               Calls.prune_safely_materialized_terminal_attempts()

      assert is_nil(Repo.get(CallAttempt, attempt.id))

      assert {:ok, %{deleted: 0, retained: 0}} =
               Calls.prune_safely_materialized_terminal_attempts()

      assert {:ok, %{deleted: 0, retained: 0}} =
               Calls.prune_safely_materialized_terminal_attempts()
    end

    test "deletes one bounded batch and drains the remainder on the next prune" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("calls_prune_batch")

      previous = Application.get_env(:discord_clone, Calls)

      on_exit(fn ->
        if previous do
          Application.put_env(:discord_clone, Calls, previous)
        else
          Application.delete_env(:discord_clone, Calls)
        end
      end)

      Application.put_env(:discord_clone, Calls, prune_batch_size: 2)

      now = DateTime.utc_now(:microsecond)
      ended_at = DateTime.add(now, -7, :day)

      attempts =
        Enum.map(1..3, fn _index ->
          insert_call_attempt(caller_scope, recipient_scope, direct_conversation, %{
            inserted_at: DateTime.add(ended_at, -30, :second),
            terminal_outcome: :declined,
            ended_at: ended_at
          })
        end)

      assert {:ok, %{deleted: 2, retained: 0}} =
               Calls.prune_safely_materialized_terminal_attempts()

      remaining =
        Enum.count(attempts, fn attempt ->
          not is_nil(Repo.get(CallAttempt, attempt.id))
        end)

      assert remaining == 1

      assert {:ok, %{deleted: 1, retained: 0}} =
               Calls.prune_safely_materialized_terminal_attempts()

      Enum.each(attempts, fn attempt ->
        assert is_nil(Repo.get(CallAttempt, attempt.id))
      end)
    end

    test "arms a rebuildable prune timer after recovery and after coordinator restart" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("calls_prune_timer")

      coordinator = :sys.get_state(DiscordClone.Calls.CallCoordinator)
      first_timer = coordinator.prune_timer_ref
      assert is_reference(first_timer)
      assert is_integer(Process.read_timer(first_timer))

      now = DateTime.utc_now(:microsecond)
      ended_at = DateTime.add(now, -7, :day)

      attempt =
        insert_call_attempt(caller_scope, recipient_scope, direct_conversation, %{
          inserted_at: DateTime.add(ended_at, -30, :second),
          terminal_outcome: :failed,
          ended_at: ended_at
        })

      run_coordinator_prune()
      assert is_nil(Repo.get(CallAttempt, attempt.id))

      coordinator = :sys.get_state(DiscordClone.Calls.CallCoordinator)
      second_timer = coordinator.prune_timer_ref
      assert is_reference(second_timer)
      assert second_timer != first_timer
      assert is_integer(Process.read_timer(second_timer))
      refute Process.read_timer(first_timer)

      assert :ok =
               Supervisor.terminate_child(
                 DiscordClone.Calls.Supervisor,
                 DiscordClone.Calls.CallCoordinator
               )

      assert {:ok, _pid} =
               Supervisor.restart_child(
                 DiscordClone.Calls.Supervisor,
                 DiscordClone.Calls.CallCoordinator
               )

      DiscordClone.Calls.CallCoordinator.begin_recovery()
      await_recovery_finished()

      coordinator = :sys.get_state(DiscordClone.Calls.CallCoordinator)
      restarted_timer = coordinator.prune_timer_ref
      assert is_reference(restarted_timer)
      assert is_integer(Process.read_timer(restarted_timer))
      refute coordinator.recovering
      assert coordinator.admit_starts?

      assert {:ok, %{call: ringing, started?: true}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      assert ringing.state == :ringing
      assert_call_server_ready(ringing.call_id)
    end

    test "recovery still rebuilds future ringing and expires overdue ringing while pruning old terminals" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("calls_prune_rec")

      assert :ok = Calls.subscribe(caller_scope)
      assert :ok = Chat.subscribe_to_activity(recipient_scope)

      carol_scope = user_scope_fixture(user_fixture(username: "calls_prune_rec_carol"))
      dave_scope = user_scope_fixture(user_fixture(username: "calls_prune_rec_dave"))
      {carol_dave, _friendship} = befriend_and_open_direct_conversation(carol_scope, dave_scope)

      now = DateTime.utc_now(:microsecond)
      ended_at = DateTime.add(now, -7, :day)

      old_terminal =
        insert_call_attempt(carol_scope, dave_scope, carol_dave, %{
          inserted_at: DateTime.add(ended_at, -30, :second),
          terminal_outcome: :declined,
          ended_at: ended_at
        })

      assert {:ok, %{call: future}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      original_deadline = future.ringing_deadline_at

      eve_scope = user_scope_fixture(user_fixture(username: "calls_prune_rec_eve"))
      frank_scope = user_scope_fixture(user_fixture(username: "calls_prune_rec_frank"))
      {eve_frank, _friendship} = befriend_and_open_direct_conversation(eve_scope, frank_scope)

      assert {:ok, %{call: overdue}} =
               Calls.start_call(eve_scope, eve_frank.id, :audio)

      make_ringing_deadline_due!(overdue.call_id)
      restart_calls_runtime()

      assert is_nil(Repo.get(CallAttempt, old_terminal.id))

      assert {:ok, recovered} = Calls.get_call(caller_scope, future.call_id)
      assert recovered.call_id == future.call_id
      assert recovered.state == :ringing
      assert recovered.ringing_deadline_at == original_deadline
      assert_call_server_ready(future.call_id)

      expired = Repo.get!(CallAttempt, overdue.call_id)
      assert expired.state == :terminal
      assert expired.terminal_outcome == :timed_out
      assert length(missed_call_activity_items(frank_scope.user.id, overdue.call_id)) == 1
      assert_call_server_stopped(overdue.call_id)

      coordinator = :sys.get_state(DiscordClone.Calls.CallCoordinator)
      assert coordinator.calls_by_id[future.call_id] == direct_conversation.id
      refute Map.has_key?(coordinator.calls_by_id, overdue.call_id)
      refute Map.has_key?(coordinator.calls_by_id, old_terminal.id)
    end

    test "admits a new start after recovery even when old terminals remain" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("calls_prune_admit")

      now = DateTime.utc_now(:microsecond)
      young_ended_at = DateTime.add(now, -1, :day)

      remaining =
        insert_call_attempt(caller_scope, recipient_scope, direct_conversation, %{
          inserted_at: DateTime.add(young_ended_at, -30, :second),
          terminal_outcome: :declined,
          ended_at: young_ended_at
        })

      restart_calls_runtime()

      assert Repo.get!(CallAttempt, remaining.id).id == remaining.id

      assert {:ok, %{call: ringing, started?: true}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      assert ringing.state == :ringing
      assert ringing.call_id != remaining.id
      assert_call_server_ready(ringing.call_id)
    end
  end

  describe "get_call/2" do
    test "returns attempts only to current Friends in the exact Direct Conversation" do
      {caller_scope, recipient_scope, direct_conversation, friendship} =
        direct_conversation_fixture("calls_observe")

      outsider_scope = user_scope_fixture(user_fixture(username: "calls_observe_outsider"))

      assert {:error, :unauthenticated} = Calls.get_call(nil, Ecto.UUID.generate())

      assert {:ok, %{call: call}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      assert {:ok, caller_view} = Calls.get_call(caller_scope, call.call_id)
      assert {:ok, recipient_view} = Calls.get_call(recipient_scope, call.call_id)
      assert caller_view == recipient_view
      assert caller_view == call

      assert {:error, :not_found} = Calls.get_call(outsider_scope, call.call_id)

      assert :ok = Friendships.remove_friend(caller_scope, friendship.id)

      assert {:error, :not_found} = Calls.get_call(caller_scope, call.call_id)
      assert {:error, :not_found} = Calls.get_call(recipient_scope, call.call_id)
    end
  end

  describe "subscribe/1" do
    test "requires an authenticated Scope" do
      assert {:error, :unauthenticated} = Calls.subscribe(nil)
      assert {:error, :unauthenticated} = Calls.subscribe(%DiscordClone.Accounts.Scope{})
    end
  end

  describe "Calls.Supervisor" do
    test "runs CallRegistry, CallSupervisor, and CallCoordinator as a rest_for_one subtree" do
      assert %{active: 3, specs: 3} =
               Supervisor.count_children(DiscordClone.Calls.Supervisor)

      _ = :sys.get_state(DiscordClone.Calls.CallRegistry)
      _ = :sys.get_state(DiscordClone.Calls.CallSupervisor)
      _ = :sys.get_state(DiscordClone.Calls.CallCoordinator)
    end
  end

  defp insert_call_attempt(caller_scope, recipient_scope, direct_conversation, attrs) do
    inserted_at = Map.fetch!(attrs, :inserted_at)
    accepted_at = Map.get(attrs, :accepted_at)
    state = Map.get(attrs, :state, :terminal)
    terminal_outcome = Map.get(attrs, :terminal_outcome)
    ended_at = Map.get(attrs, :ended_at, inserted_at)

    %CallAttempt{}
    |> Ecto.Changeset.change(%{
      direct_conversation_id: direct_conversation.id,
      caller_user_id: caller_scope.user.id,
      recipient_user_id: recipient_scope.user.id,
      media_intent: :audio,
      state: state,
      ringing_deadline_at: DateTime.add(inserted_at, 30, :second),
      accepted_at: accepted_at,
      terminal_outcome: terminal_outcome,
      ended_at: if(state == :terminal, do: ended_at),
      inserted_at: inserted_at,
      updated_at: inserted_at
    })
    |> Repo.insert!()
  end

  defp befriend_and_open_direct_conversation(scope, other_scope) do
    assert {:ok, %{relationship: request}} =
             Friendships.send_friend_request(scope, %{username: other_scope.user.username})

    assert {:ok, friendship} = Friendships.accept_friend_request(other_scope, request.id)

    assert {:ok, direct_conversation} =
             Chat.open_direct_conversation(scope, other_scope.user.id)

    {direct_conversation, friendship}
  end

  defp restart_calls_runtime do
    stop_supervised!(DiscordClone.Calls.Supervisor)
    start_supervised!(DiscordClone.Calls.Supervisor)
    DiscordClone.Calls.CallCoordinator.begin_recovery()
    await_recovery_finished()
    :ok
  end

  defp await_replaced_named_process(name, old_pid) do
    deadline = System.monotonic_time(:millisecond) + 1_000
    await_replaced_named_process(name, old_pid, deadline)
  end

  defp await_replaced_named_process(name, old_pid, deadline) do
    case Process.whereis(name) do
      pid when is_pid(pid) and pid != old_pid ->
        case safe_sys_state(pid) do
          {:ok, _state} ->
            pid

          :error ->
            retry_until(deadline, "expected #{inspect(name)} to be replaced", fn ->
              await_replaced_named_process(name, old_pid, deadline)
            end)
        end

      _missing_or_same ->
        retry_until(deadline, "expected #{inspect(name)} to be replaced", fn ->
          await_replaced_named_process(name, old_pid, deadline)
        end)
    end
  end

  defp await_replaced_call_server(call_id, old_pid) do
    deadline = System.monotonic_time(:millisecond) + 1_000
    await_replaced_call_server(call_id, old_pid, deadline)
  end

  defp await_replaced_call_server(call_id, old_pid, deadline) do
    case Process.whereis(DiscordClone.Calls.CallCoordinator) do
      pid when is_pid(pid) -> _ = safe_sys_state(pid)
      nil -> :ok
    end

    case safe_registry_lookup(call_id) do
      {:ok, [{pid, _value}]} when pid != old_pid ->
        assert :ok = CallServer.await_ready(call_id)
        pid

      _missing_or_same ->
        retry_until(deadline, "expected CallServer for #{call_id} to be rebuilt", fn ->
          await_replaced_call_server(call_id, old_pid, deadline)
        end)
    end
  end

  defp safe_sys_state(pid) do
    {:ok, :sys.get_state(pid)}
  catch
    :exit, _reason -> :error
  end

  defp safe_registry_lookup(call_id) do
    {:ok, Registry.lookup(DiscordClone.Calls.CallRegistry, call_id)}
  catch
    :exit, _reason -> :error
    :error, _reason -> :error
  end

  defp retry_until(deadline, message, fun) do
    if System.monotonic_time(:millisecond) < deadline do
      :erlang.yield()
      fun.()
    else
      flunk(message)
    end
  end

  defp assert_call_server_ready(call_id) do
    assert [{pid, _value}] = Registry.lookup(DiscordClone.Calls.CallRegistry, call_id)
    assert :ok = CallServer.await_ready(call_id)

    assert %{call_attempt: %CallAttempt{id: ^call_id}, ringing_timer_ref: timer_ref} =
             :sys.get_state(pid)

    assert is_reference(timer_ref)
  end

  defp assert_call_server_stopped(call_id) do
    deadline = System.monotonic_time(:millisecond) + 1_000
    assert_call_server_stopped(call_id, deadline)
  end

  defp assert_call_server_stopped(call_id, deadline) do
    _ = :sys.get_state(DiscordClone.Calls.CallRegistry)

    cond do
      Registry.lookup(DiscordClone.Calls.CallRegistry, call_id) == [] ->
        :ok

      System.monotonic_time(:millisecond) < deadline ->
        :erlang.yield()
        assert_call_server_stopped(call_id, deadline)

      true ->
        flunk("expected CallServer for #{call_id} to leave CallRegistry")
    end
  end

  defp contains_pid?(value) when is_pid(value), do: true

  defp contains_pid?(value) when is_map(value) do
    value
    |> Map.values()
    |> Enum.any?(&contains_pid?/1)
  end

  defp contains_pid?(value) when is_list(value), do: Enum.any?(value, &contains_pid?/1)
  defp contains_pid?(_value), do: false
end
