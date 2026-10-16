defmodule DiscordCloneWeb.CallSignalingReconnectTest do
  use DiscordClone.DataCase, async: false

  import DiscordClone.AccountsFixtures
  import DiscordClone.CallsFixtures
  import Phoenix.ChannelTest

  alias DiscordClone.Accounts
  alias DiscordClone.Activities.ActivityItem
  alias DiscordClone.Calls
  alias DiscordClone.Calls.{CallAttempt, CallServer, ScriptedAcceptedCallRuntime}
  alias DiscordClone.Chat.Message
  alias DiscordClone.Friendships
  alias DiscordClone.Repo
  alias DiscordClone.Voice
  alias DiscordCloneWeb.{CallSignaling, CallSocket}

  @endpoint DiscordCloneWeb.Endpoint
  @inbox_topic CallSignaling.inbox_topic()

  setup do
    start_supervised!(DiscordClone.Calls.Supervisor)
    DiscordClone.Calls.CallCoordinator.begin_recovery()
    await_recovery_finished()
    :ok
  end

  describe "rejoin snapshots and original deadlines" do
    test "inbox rejoin while ringing returns a fresh identity, the same Call ID, and the original deadline" do
      {caller_scope, recipient_scope, started} = start_ringing_call("c05_rejoin_ring")
      voice_channel_id = Ecto.UUID.generate()

      assert {:ok, %{voice_session_id: voice_session_id}} =
               Voice.join(voice_channel_id, caller_scope.user.id, "c05-rejoin-voice", self())

      attempt_before = Repo.get!(CallAttempt, started.call_id)
      activity_before = Repo.aggregate(ActivityItem, :count)
      messages_before = Repo.aggregate(Message, :count)
      occupancy_before = Registry.count(DiscordClone.Calls.CallRegistry)
      running_before = MapSet.new(ExWebRTC.PeerConnection.get_all_running())

      %{socket: caller_socket} = connect_calls_socket(caller_scope.user)
      %{socket: recipient_socket} = connect_calls_socket(recipient_scope.user)

      assert {:ok, first, first_channel} = subscribe_and_join(caller_socket, @inbox_topic)
      assert first.call.call_id == started.call_id
      assert first.call.ringing_deadline_at == started.ringing_deadline_at
      assert first.call.state == :ringing

      Process.unlink(first_channel.channel_pid)
      assert_reply leave(first_channel), :ok

      assert {:ok, second, _second_channel} = subscribe_and_join(caller_socket, @inbox_topic)
      refute second.signaling_session_id == first.signaling_session_id
      assert second.call.call_id == started.call_id
      assert second.call.ringing_deadline_at == started.ringing_deadline_at
      assert second.call.role == :caller

      assert {:ok, recipient_join, _recipient_channel} =
               subscribe_and_join(recipient_socket, @inbox_topic)

      assert recipient_join.call.call_id == started.call_id
      assert recipient_join.call.ringing_deadline_at == started.ringing_deadline_at
      assert recipient_join.call.role == :recipient
      refute recipient_join.signaling_session_id == second.signaling_session_id

      attempt_after = Repo.get!(CallAttempt, started.call_id)
      assert attempt_after.state == :ringing
      assert attempt_after.ringing_deadline_at == attempt_before.ringing_deadline_at
      assert attempt_after.updated_at == attempt_before.updated_at
      assert Repo.aggregate(ActivityItem, :count) == activity_before
      assert Repo.aggregate(Message, :count) == messages_before
      assert Registry.count(DiscordClone.Calls.CallRegistry) == occupancy_before

      assert {:ok, %{members: [%{user_id: caller_user_id}]}} =
               Voice.voice_channel_roster(voice_channel_id)

      assert caller_user_id == caller_scope.user.id
      assert :ok = Voice.leave(voice_channel_id, voice_session_id)

      assert ExWebRTC.PeerConnection.get_all_running()
             |> MapSet.new()
             |> MapSet.difference(running_before)
             |> MapSet.size() == 0
    end

    test "an offline recipient discovers the still-ringing invitation with the original deadline" do
      {caller_scope, recipient_scope, started} = start_ringing_call("c05_offline")
      %{socket: recipient_socket} = connect_calls_socket(recipient_scope.user)

      assert {:ok, payload, _channel} = subscribe_and_join(recipient_socket, @inbox_topic)
      assert payload.call.call_id == started.call_id
      assert payload.call.role == :recipient
      assert payload.call.state == :ringing
      assert payload.call.ringing_deadline_at == started.ringing_deadline_at

      assert {:ok, current} = Calls.current_call(caller_scope)
      assert current.call_id == started.call_id
      assert current.ringing_deadline_at == started.ringing_deadline_at
    end

    test "inbox rejoin after timeout is empty and missed Activity stays exactly one" do
      {caller_scope, recipient_scope, started} = start_ringing_call("c05_rejoin_to")
      %{socket: socket} = connect_calls_socket(caller_scope.user)

      assert {:ok, _payload, channel} = subscribe_and_join(socket, @inbox_topic)
      make_ringing_deadline_due!(started.call_id)
      assert {:ok, timed_out} = Calls.expire_ringing_attempt(started.call_id)
      assert timed_out.terminal_outcome == :timed_out
      assert_push "call_timed_out", _payload
      assert length(missed_call_activity_items(recipient_scope.user.id, started.call_id)) == 1

      Process.unlink(channel.channel_pid)
      assert_reply leave(channel), :ok

      assert {:ok, rejoin, _rejoined} = subscribe_and_join(socket, @inbox_topic)
      assert rejoin.call == nil
      assert {:ok, _} = Ecto.UUID.cast(rejoin.signaling_session_id)
      assert length(missed_call_activity_items(recipient_scope.user.id, started.call_id)) == 1
    end

    test "inbox rejoin after Friendship removal is empty" do
      {caller_scope, _recipient_scope, started, friendship} =
        start_ringing_call_with_friendship("c05_rejoin_rm")

      %{socket: socket} = connect_calls_socket(caller_scope.user)
      assert {:ok, first, channel} = subscribe_and_join(socket, @inbox_topic)
      assert first.call.call_id == started.call_id

      assert :ok = Friendships.remove_friend(caller_scope, friendship.id)
      assert_push "call_ended", ended
      assert ended.call.terminal_outcome == :relationship_ended

      Process.unlink(channel.channel_pid)
      assert_reply leave(channel), :ok

      assert {:ok, rejoin, _rejoined} = subscribe_and_join(socket, @inbox_topic)
      assert rejoin.call == nil
      refute rejoin.signaling_session_id == first.signaling_session_id
      assert {:ok, nil} = Calls.current_call(caller_scope)
    end

    test "overdue ringing omitted by current_call is not revived or expired by inbox join" do
      {caller_scope, _recipient_scope, started} = start_ringing_call("c05_overdue")
      make_ringing_deadline_due!(started.call_id)
      deadline = Repo.get!(CallAttempt, started.call_id).ringing_deadline_at
      updated_at = Repo.get!(CallAttempt, started.call_id).updated_at

      assert {:ok, nil} = Calls.current_call(caller_scope)
      assert {:ok, readable} = Calls.get_call(caller_scope, started.call_id)
      assert readable.state == :ringing
      assert readable.ringing_deadline_at == deadline

      %{socket: socket} = connect_calls_socket(caller_scope.user)
      assert {:ok, payload, _channel} = subscribe_and_join(socket, @inbox_topic)
      assert payload.call == nil

      attempt = Repo.get!(CallAttempt, started.call_id)
      assert attempt.state == :ringing
      assert attempt.ringing_deadline_at == deadline
      assert attempt.updated_at == updated_at
      assert is_nil(attempt.terminal_outcome)
      assert missed_call_count() == 0
    end
  end

  describe "subscribe, snapshot, and queued-notification races" do
    test "delayed ringing after a terminal inbox snapshot does not revive that Call ID" do
      {caller_scope, recipient_scope, started} = start_ringing_call("c05_delay_ring")
      %{socket: socket} = connect_calls_socket(caller_scope.user)
      assert {:ok, payload, _channel} = subscribe_and_join(socket, @inbox_topic)
      assert payload.call.state == :ringing

      assert {:ok, declined} = Calls.decline_call(recipient_scope, started.call_id)
      assert_push "call_declined", declined_push
      assert declined_push.call.call_id == started.call_id
      assert declined.terminal_outcome == :declined

      :ok = Calls.broadcast_ringing(started)
      refute_push "outgoing_call_ringing", _payload
      refute_push "incoming_call", _payload

      send_queued_ringing(socket, started)
      refute_push "outgoing_call_ringing", _payload
      refute_push "incoming_call", _payload
    end

    test "delayed ringing after a terminal last_call does not stop the inbox when discovery is unavailable" do
      {caller_scope, recipient_scope, started} = start_ringing_call("c05_term_guard")
      %{socket: socket} = connect_calls_socket(caller_scope.user)
      assert {:ok, payload, channel} = subscribe_and_join(socket, @inbox_topic)
      assert payload.call.state == :ringing

      assert {:ok, declined} = Calls.decline_call(recipient_scope, started.call_id)
      assert_push "call_declined", declined_push
      assert declined_push.call.call_id == started.call_id
      assert declined.terminal_outcome == :declined

      channel_pid = channel.channel_pid
      Process.unlink(channel_pid)
      ref = Process.monitor(channel_pid)

      assert :ok =
               Supervisor.terminate_child(
                 DiscordClone.Calls.Supervisor,
                 DiscordClone.Calls.CallCoordinator
               )

      :ok = Calls.broadcast_ringing(started)
      refute_push "outgoing_call_ringing", _payload
      refute_push "incoming_call", _payload

      send_queued_ringing(socket, started)
      refute_push "outgoing_call_ringing", _payload
      refute_push "incoming_call", _payload
      refute_receive {:DOWN, ^ref, :process, ^channel_pid, _reason}, 100
    end

    test "a Call-topic ringing join followed by decline does not later become ringing" do
      {caller_scope, recipient_scope, started} = start_ringing_call("c05_join_dec")
      %{socket: socket} = connect_calls_socket(caller_scope.user)

      assert {:ok, payload, channel} =
               subscribe_and_join(socket, call_topic(started.call_id))

      assert payload.call.state == :ringing

      call_pid = channel.channel_pid
      call_ref = Process.monitor(call_pid)

      assert {:ok, declined} = Calls.decline_call(recipient_scope, started.call_id)
      assert declined.terminal_outcome == :declined
      assert_push "call_declined", declined_push
      assert declined_push.call.state == :terminal

      send(call_pid, {:call_ringing, started})
      refute_push "outgoing_call_ringing", _payload
      refute_push "incoming_call", _payload
      refute_push "call_declined", _payload

      assert {:ok, committed} = Calls.get_call(caller_scope, started.call_id)
      assert committed.state == :terminal
      assert committed.terminal_outcome == :declined
      refute_receive {:DOWN, ^call_ref, :process, ^call_pid, _reason}, 0
    end

    test "concurrent decline during Call-topic join settles on the declined projection" do
      {caller_scope, recipient_scope, started} = start_ringing_call("c05_race_join")
      caller_token = Accounts.generate_user_session_token(caller_scope.user)
      recipient_token = Accounts.generate_user_session_token(recipient_scope.user)

      start_inbox_tab(caller_token, :caller_inbox)
      start_call_tab(caller_token, :caller_call, started.call_id)
      start_inbox_tab(recipient_token, :recipient_inbox)

      assert {:joined, :caller_inbox, caller_inbox_pid, _payload, _ch} =
               await_joined(:caller_inbox)

      assert {:joined, :caller_call, caller_call_pid, _payload, _ch} =
               await_joined(:caller_call)

      assert {:joined, :recipient_inbox, recipient_inbox_pid, _payload, _ch} =
               await_joined(:recipient_inbox)

      parent = self()

      joiner =
        Task.async(fn ->
          {:ok, socket} =
            Phoenix.ChannelTest.__connect__(
              DiscordCloneWeb.Endpoint,
              CallSocket,
              %{},
              connect_info: %{session: %{"user_token" => recipient_token}},
              test_process: parent
            )

          Phoenix.ChannelTest.subscribe_and_join(socket, call_topic(started.call_id))
        end)

      decliner =
        Task.async(fn ->
          Calls.decline_call(recipient_scope, started.call_id)
        end)

      join_result = Task.await(joiner)
      decline_result = Task.await(decliner)

      assert {:ok, declined} = decline_result
      assert declined.terminal_outcome == :declined
      assert {:ok, join_payload, join_channel} = join_result
      assert join_payload.call.call_id == started.call_id
      assert join_payload.call.state in [:ringing, :terminal]

      if join_payload.call.state == :ringing do
        assert_push "call_declined", terminal
        assert terminal.call.terminal_outcome == :declined
      else
        assert join_payload.call.terminal_outcome == :declined
      end

      caller_inbox = await_tab_push(:caller_inbox, "call_declined")
      recipient_inbox = await_tab_push(:recipient_inbox, "call_declined")
      caller_call = await_tab_push(:caller_call, "call_declined")

      assert Enum.all?(
               [caller_inbox, recipient_inbox, caller_call],
               &(&1.call.call_id == started.call_id and &1.call.terminal_outcome == :declined)
             )

      send(join_channel.channel_pid, {:call_ringing, started})
      refute_push "incoming_call", _payload
      refute_push "outgoing_call_ringing", _payload

      for {tag, pid} <- [
            {:caller_inbox, caller_inbox_pid},
            {:recipient_inbox, recipient_inbox_pid},
            {:caller_call, caller_call_pid}
          ] do
        send(pid, {:sync, self()})
        assert_receive {:sync, ^tag}
        refute_received {:push, ^tag, "incoming_call", _}
        refute_received {:push, ^tag, "outgoing_call_ringing", _}
      end

      assert {:ok, committed} = Calls.get_call(caller_scope, started.call_id)
      assert committed.state == :terminal
      assert committed.terminal_outcome == :declined
    end

    test "a terminal for an old Call ID does not clear a newer ringing invitation" do
      {caller_scope, _recipient_scope, first} = start_ringing_call("c05_old_term")
      %{socket: inbox_socket} = connect_calls_socket(caller_scope.user)
      %{socket: call_socket} = connect_calls_socket(caller_scope.user)

      assert {:ok, _first_join, _inbox} = subscribe_and_join(inbox_socket, @inbox_topic)
      assert {:ok, _cancelled} = Calls.cancel_call(caller_scope, first.call_id)
      assert_push "call_cancelled", _cancelled_push

      assert {:ok, %{call: second, started?: true}} =
               Calls.start_call(caller_scope, first.direct_conversation_id, :audio)

      refute second.call_id == first.call_id
      assert_push "outgoing_call_ringing", newer
      assert newer.call.call_id == second.call_id

      assert {:ok, second_join, _call_channel} =
               subscribe_and_join(call_socket, call_topic(second.call_id))

      assert second_join.call.call_id == second.call_id
      assert second_join.call.state == :ringing

      old_terminal = %{
        call_id: first.call_id,
        direct_conversation_id: first.direct_conversation_id,
        caller_user_id: first.caller_user_id,
        recipient_user_id: first.recipient_user_id,
        media_intent: :audio,
        state: :terminal,
        ringing_deadline_at: first.ringing_deadline_at,
        started_at: first.started_at,
        terminal_outcome: :cancelled,
        ended_at: DateTime.utc_now(:microsecond)
      }

      :ok =
        Phoenix.PubSub.broadcast(
          DiscordClone.PubSub,
          "calls:user:#{caller_scope.user.id}",
          {:call_cancelled, old_terminal}
        )

      refute_push "call_cancelled", _payload
      assert {:ok, current} = Calls.current_call(caller_scope)
      assert current.call_id == second.call_id
      assert current.state == :ringing
    end

    test "overlapping timeout and ringing cancel produce one outcome, one Activity, and one observer event" do
      {caller_scope, recipient_scope, started} = start_ringing_call("c05_overlap")
      caller_token = Accounts.generate_user_session_token(caller_scope.user)
      recipient_token = Accounts.generate_user_session_token(recipient_scope.user)

      start_inbox_tab(caller_token, :caller_inbox)
      start_inbox_tab(recipient_token, :recipient_inbox)
      start_call_tab(caller_token, :caller_call, started.call_id)
      start_call_tab(recipient_token, :recipient_call, started.call_id)

      assert {:joined, :caller_inbox, caller_inbox_pid, _p, _ch} = await_joined(:caller_inbox)

      assert {:joined, :recipient_inbox, recipient_inbox_pid, _p, _ch} =
               await_joined(:recipient_inbox)

      assert {:joined, :caller_call, caller_call_pid, _p, _ch} = await_joined(:caller_call)

      assert {:joined, :recipient_call, recipient_call_pid, _p, _ch} =
               await_joined(:recipient_call)

      make_ringing_deadline_due!(started.call_id)

      expire_task = Task.async(fn -> Calls.expire_ringing_attempt(started.call_id) end)
      cancel_task = Task.async(fn -> Calls.cancel_call(caller_scope, started.call_id) end)

      assert {:ok, first} = Task.await(expire_task)
      assert {:ok, second} = Task.await(cancel_task)
      assert first.terminal_outcome == second.terminal_outcome
      assert first.terminal_outcome in [:timed_out, :cancelled]
      assert first.ended_at == second.ended_at

      wire_event =
        case first.terminal_outcome do
          :timed_out -> "call_timed_out"
          :cancelled -> "call_cancelled"
        end

      for tag <- [:caller_inbox, :recipient_inbox, :caller_call, :recipient_call] do
        payload = await_tab_push(tag, wire_event)
        assert payload.call.call_id == started.call_id
        assert payload.call.terminal_outcome == first.terminal_outcome
      end

      assert length(missed_call_activity_items(recipient_scope.user.id, started.call_id)) == 1
      assert Repo.aggregate(CallAttempt, :count) == 1

      for {tag, pid} <- [
            {:caller_inbox, caller_inbox_pid},
            {:recipient_inbox, recipient_inbox_pid},
            {:caller_call, caller_call_pid},
            {:recipient_call, recipient_call_pid}
          ] do
        send(pid, {:sync, self()})
        assert_receive {:sync, ^tag}
        refute_received {:push, ^tag, ^wire_event, _}
      end
    end

    test "temporarily_unavailable during inbox ringing reconciliation stops that Channel without cancelling" do
      {caller_scope, _recipient_scope, started} = start_ringing_call("c05_unav")
      %{socket: socket} = connect_calls_socket(caller_scope.user)
      assert {:ok, _payload, channel} = subscribe_and_join(socket, @inbox_topic)

      channel_pid = channel.channel_pid
      Process.unlink(channel_pid)
      ref = Process.monitor(channel_pid)

      assert :ok =
               Supervisor.terminate_child(
                 DiscordClone.Calls.Supervisor,
                 DiscordClone.Calls.CallCoordinator
               )

      :ok = Calls.broadcast_ringing(started)

      assert_receive {:DOWN, ^ref, :process, ^channel_pid, reason}
      assert shutdown_reason?(reason)

      assert {:ok, still_ringing} = Calls.get_call(caller_scope, started.call_id)
      assert still_ringing.state == :ringing
      assert is_nil(still_ringing.terminal_outcome)
      assert missed_call_count() == 0
    end
  end

  describe "Friendship-removal delivery and Call-topic close" do
    test "existing subscribers receive relationship_ended, Call topics stop, and the inbox stays joined" do
      {caller_scope, recipient_scope, started, friendship} =
        start_ringing_call_with_friendship("c05_rm")

      outsider_scope = user_scope_fixture(user_fixture(username: "c05_rm_out"))
      caller_token = Accounts.generate_user_session_token(caller_scope.user)
      recipient_token = Accounts.generate_user_session_token(recipient_scope.user)
      outsider_token = Accounts.generate_user_session_token(outsider_scope.user)
      messages_before = Repo.aggregate(Message, :count)
      running_before = MapSet.new(ExWebRTC.PeerConnection.get_all_running())

      start_inbox_tab(caller_token, :caller_inbox)
      start_inbox_tab(recipient_token, :recipient_inbox)
      start_inbox_tab(outsider_token, :outsider_inbox)
      start_call_tab(caller_token, :caller_call, started.call_id)
      start_call_tab(recipient_token, :recipient_call, started.call_id)

      assert {:joined, :caller_inbox, caller_inbox_pid, _p, _caller_inbox} =
               await_joined(:caller_inbox)

      assert {:joined, :recipient_inbox, recipient_inbox_pid, _p, _recipient_inbox} =
               await_joined(:recipient_inbox)

      assert {:joined, :outsider_inbox, outsider_pid, _p, _ch} = await_joined(:outsider_inbox)

      assert {:joined, :caller_call, _caller_call_pid, caller_join, caller_call} =
               await_joined(:caller_call)

      assert {:joined, :recipient_call, _recipient_call_pid, recipient_join, recipient_call} =
               await_joined(:recipient_call)

      caller_call_pid = caller_call.channel_pid
      recipient_call_pid = recipient_call.channel_pid
      Process.unlink(caller_call_pid)
      Process.unlink(recipient_call_pid)
      caller_ref = Process.monitor(caller_call_pid)
      recipient_ref = Process.monitor(recipient_call_pid)

      assert :ok = Friendships.remove_friend(caller_scope, friendship.id)

      caller_inbox_ended = await_tab_push(:caller_inbox, "call_ended")
      recipient_inbox_ended = await_tab_push(:recipient_inbox, "call_ended")
      caller_call_ended = await_tab_push(:caller_call, "call_ended")
      recipient_call_ended = await_tab_push(:recipient_call, "call_ended")

      assert caller_inbox_ended.call.role == :caller
      assert recipient_inbox_ended.call.role == :recipient
      assert caller_call_ended.call.terminal_outcome == :relationship_ended
      assert recipient_call_ended.call.terminal_outcome == :relationship_ended
      assert caller_call_ended.signaling_session_id == caller_join.signaling_session_id
      assert recipient_call_ended.signaling_session_id == recipient_join.signaling_session_id

      assert_receive {:DOWN, ^caller_ref, :process, ^caller_call_pid, caller_reason}
      assert_receive {:DOWN, ^recipient_ref, :process, ^recipient_call_pid, recipient_reason}
      assert shutdown_reason?(caller_reason)
      assert shutdown_reason?(recipient_reason)
      refute match?({:crash, _}, caller_reason)

      send(outsider_pid, {:sync, self()})
      assert_receive {:sync, :outsider_inbox}
      refute_received {:push, :outsider_inbox, _event, _payload}

      send(caller_inbox_pid, {:sync, self()})
      assert_receive {:sync, :caller_inbox}
      refute_received {:push, :caller_inbox, "call_ended", _}

      send(recipient_inbox_pid, {:sync, self()})
      assert_receive {:sync, :recipient_inbox}
      refute_received {:push, :recipient_inbox, "call_ended", _}

      assert {:error, :not_found} = Calls.get_call(caller_scope, started.call_id)
      assert {:error, :not_found} = Calls.get_call(recipient_scope, started.call_id)
      assert {:ok, nil} = Calls.current_call(caller_scope)

      assert {:error, %{reason: "not_found"}} =
               subscribe_and_join(
                 connect_calls_socket(caller_scope.user).socket,
                 call_topic(started.call_id)
               )

      assert {:error, %{reason: "not_found"}} =
               subscribe_and_join(
                 connect_calls_socket(recipient_scope.user).socket,
                 call_topic(started.call_id)
               )

      assert {:error, %{reason: "not_found"}} =
               subscribe_and_join(
                 connect_calls_socket(outsider_scope.user).socket,
                 call_topic(started.call_id)
               )

      assert {:error, %{reason: "not_found"}} =
               subscribe_and_join(
                 connect_calls_socket(caller_scope.user).socket,
                 call_topic(Ecto.UUID.generate())
               )

      assert missed_call_activity_items(recipient_scope.user.id, started.call_id) == []
      assert Repo.aggregate(Message, :count) == messages_before

      assert ExWebRTC.PeerConnection.get_all_running()
             |> MapSet.new()
             |> MapSet.difference(running_before)
             |> MapSet.size() == 0
    end

    test "former Friends cannot decline or cancel the ended Call ID" do
      {caller_scope, recipient_scope, started, friendship} =
        start_ringing_call_with_friendship("c05_rm_cmd")

      %{socket: caller_socket} = connect_calls_socket(caller_scope.user)
      %{socket: recipient_socket} = connect_calls_socket(recipient_scope.user)

      assert {:ok, _caller_join, caller_channel} =
               subscribe_and_join(caller_socket, call_topic(started.call_id))

      assert {:ok, _recipient_join, recipient_channel} =
               subscribe_and_join(recipient_socket, call_topic(started.call_id))

      Process.unlink(caller_channel.channel_pid)
      Process.unlink(recipient_channel.channel_pid)
      caller_ref = Process.monitor(caller_channel.channel_pid)
      recipient_ref = Process.monitor(recipient_channel.channel_pid)

      assert :ok = Friendships.remove_friend(recipient_scope, friendship.id)
      assert_receive {:DOWN, ^caller_ref, :process, _pid, caller_reason}
      assert_receive {:DOWN, ^recipient_ref, :process, _pid, recipient_reason}
      assert shutdown_reason?(caller_reason)
      assert shutdown_reason?(recipient_reason)

      assert {:error, :not_found} = Calls.decline_call(recipient_scope, started.call_id)
      assert {:error, :not_found} = Calls.cancel_call(caller_scope, started.call_id)
      assert missed_call_count() == 0
    end

    test "decline, cancel, timeout, and interruption leave the Call topic joinable" do
      {caller_scope, recipient_scope, declined_call} = start_ringing_call("c05_keep_dec")
      %{socket: declined_socket} = connect_calls_socket(caller_scope.user)

      assert {:ok, _payload, declined_channel} =
               subscribe_and_join(declined_socket, call_topic(declined_call.call_id))

      assert {:ok, _} = Calls.decline_call(recipient_scope, declined_call.call_id)
      assert_push "call_declined", _declined
      refute_stopped(declined_channel)

      assert {:ok, declined_rejoin, _ch} =
               subscribe_and_join(
                 connect_calls_socket(caller_scope.user).socket,
                 call_topic(declined_call.call_id)
               )

      assert declined_rejoin.call.terminal_outcome == :declined

      {caller_scope2, _recipient_scope2, cancelled_call} = start_ringing_call("c05_keep_can")
      %{socket: cancelled_socket} = connect_calls_socket(caller_scope2.user)

      assert {:ok, _payload, cancelled_channel} =
               subscribe_and_join(cancelled_socket, call_topic(cancelled_call.call_id))

      assert {:ok, _} = Calls.cancel_call(caller_scope2, cancelled_call.call_id)
      assert_push "call_cancelled", _cancelled
      refute_stopped(cancelled_channel)

      {caller_scope3, _recipient_scope3, timed_out_call} = start_ringing_call("c05_keep_to")
      %{socket: timeout_socket} = connect_calls_socket(caller_scope3.user)

      assert {:ok, _payload, timeout_channel} =
               subscribe_and_join(timeout_socket, call_topic(timed_out_call.call_id))

      make_ringing_deadline_due!(timed_out_call.call_id)
      assert {:ok, _} = Calls.expire_ringing_attempt(timed_out_call.call_id)
      assert_push "call_timed_out", _timed_out
      refute_stopped(timeout_channel)

      {caller_scope4, _recipient_scope4, interrupted_call} = start_ringing_call("c05_keep_int")
      %{socket: interrupt_socket} = connect_calls_socket(caller_scope4.user)

      assert {:ok, _payload, interrupt_channel} =
               subscribe_and_join(interrupt_socket, call_topic(interrupted_call.call_id))

      now = DateTime.utc_now(:microsecond)

      Repo.get!(CallAttempt, interrupted_call.call_id)
      |> Ecto.Changeset.change(%{state: :connecting, accepted_at: now})
      |> Repo.update!()

      restart_calls_runtime()
      assert_push "call_ended", interrupted
      assert interrupted.call.terminal_outcome == :interrupted
      refute_stopped(interrupt_channel)
    end
  end

  describe "timeout recovery and non-cancellation" do
    test "timeout reaches inbox and Call-topic observers once and reconnect does not add Activity" do
      {caller_scope, recipient_scope, started} = start_ringing_call("c05_timeout")
      caller_token = Accounts.generate_user_session_token(caller_scope.user)
      recipient_token = Accounts.generate_user_session_token(recipient_scope.user)

      start_inbox_tab(caller_token, :caller_inbox)
      start_inbox_tab(recipient_token, :recipient_inbox)
      start_call_tab(caller_token, :caller_call, started.call_id)
      start_call_tab(recipient_token, :recipient_call, started.call_id)

      assert {:joined, :caller_inbox, caller_inbox_pid, _p, _ch} = await_joined(:caller_inbox)

      assert {:joined, :recipient_inbox, recipient_inbox_pid, _p, _ch} =
               await_joined(:recipient_inbox)

      assert {:joined, :caller_call, caller_call_pid, _p, _ch} = await_joined(:caller_call)

      assert {:joined, :recipient_call, recipient_call_pid, _p, _ch} =
               await_joined(:recipient_call)

      make_ringing_deadline_due!(started.call_id)
      assert {:ok, timed_out} = Calls.expire_ringing_attempt(started.call_id)
      assert timed_out.terminal_outcome == :timed_out

      for tag <- [:caller_inbox, :recipient_inbox, :caller_call, :recipient_call] do
        payload = await_tab_push(tag, "call_timed_out")
        assert payload.call.call_id == started.call_id
        assert payload.call.terminal_outcome == :timed_out
      end

      assert length(missed_call_activity_items(recipient_scope.user.id, started.call_id)) == 1

      for {tag, pid} <- [
            {:caller_inbox, caller_inbox_pid},
            {:recipient_inbox, recipient_inbox_pid},
            {:caller_call, caller_call_pid},
            {:recipient_call, recipient_call_pid}
          ] do
        send(pid, {:sync, self()})
        assert_receive {:sync, ^tag}
        refute_received {:push, ^tag, "call_timed_out", _}
      end

      %{socket: reconnect} = connect_calls_socket(recipient_scope.user)
      assert {:ok, snapshot, _channel} = subscribe_and_join(reconnect, @inbox_topic)
      assert snapshot.call == nil
      assert length(missed_call_activity_items(recipient_scope.user.id, started.call_id)) == 1
    end

    test "leaving inbox and Call topic still does not cancel" do
      {caller_scope, _recipient_scope, started} = start_ringing_call("c05_leave")
      %{socket: socket} = connect_calls_socket(caller_scope.user)

      assert {:ok, _inbox, inbox_channel} = subscribe_and_join(socket, @inbox_topic)

      assert {:ok, _call, call_channel} =
               subscribe_and_join(socket, call_topic(started.call_id))

      Process.unlink(inbox_channel.channel_pid)
      Process.unlink(call_channel.channel_pid)
      assert_reply leave(inbox_channel), :ok
      assert_reply leave(call_channel), :ok

      assert {:ok, still_ringing} = Calls.get_call(caller_scope, started.call_id)
      assert still_ringing.state == :ringing
      assert missed_call_count() == 0
    end
  end

  describe "ownership across restart and reconnect" do
    test "ringing recovery holds no stale caller ownership" do
      {caller_scope, _recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("c05_own_recover")

      %{socket: preferred_socket} = connect_calls_socket(caller_scope.user)
      preferred_connection_id = preferred_socket.assigns.connection_id

      assert {:ok, %{call: started, started?: true}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio,
                 caller_connection_id: preferred_connection_id
               )

      assert {:ok, %{call: %{ownership: :self}}, _channel} =
               subscribe_and_join(preferred_socket, call_topic(started.call_id))

      restart_calls_runtime()

      assert CallServer.ownership(started.call_id, :caller, preferred_connection_id) == :elsewhere

      %{socket: rejoined} = connect_calls_socket(caller_scope.user)

      assert {:ok, snapshot, _channel} = subscribe_and_join(rejoined, call_topic(started.call_id))

      assert snapshot.call.state == :ringing
      assert snapshot.call.ownership == :elsewhere
    end

    test "connecting restart still fails closed as interrupted and clears ownership" do
      previous_runtime = Application.get_env(:discord_clone, :accepted_call_runtime)
      previous_result = Application.get_env(:discord_clone, :accepted_call_runtime_result)
      Application.put_env(:discord_clone, :accepted_call_runtime, ScriptedAcceptedCallRuntime)
      Application.put_env(:discord_clone, :accepted_call_runtime_result, :held)

      try do
        {_caller_scope, recipient_scope, started} = start_ringing_call("c05_own_int")
        %{socket: socket} = connect_calls_socket(recipient_scope.user)

        assert {:ok, _payload, channel} =
                 subscribe_and_join(socket, call_topic(started.call_id))

        assert CallServer.ownership(started.call_id, :recipient, socket.assigns.connection_id) ==
                 :unclaimed

        assert_reply push(channel, "accept_call", %{
                       "signaling_session_id" => channel.assigns.signaling_session_id,
                       "call_id" => started.call_id,
                       "answer_mode" => "audio"
                     }),
                     :ok,
                     %{call: %{state: :connecting, ownership: :self}}

        restart_calls_runtime()

        assert_push "call_ended", interrupted
        assert interrupted.call.terminal_outcome == :interrupted

        %{socket: reconnected} = connect_calls_socket(recipient_scope.user)

        assert {:ok, snapshot, _channel} =
                 subscribe_and_join(reconnected, call_topic(started.call_id))

        assert snapshot.call.state == :terminal
        refute Map.has_key?(snapshot.call, :ownership)
      after
        restore_env(:accepted_call_runtime, previous_runtime)
        restore_env(:accepted_call_runtime_result, previous_result)
      end
    end
  end

  defp start_ringing_call(suffix) do
    {caller_scope, recipient_scope, started, _friendship} =
      start_ringing_call_with_friendship(suffix)

    {caller_scope, recipient_scope, started}
  end

  defp start_ringing_call_with_friendship(suffix) do
    {caller_scope, recipient_scope, direct_conversation, friendship} =
      direct_conversation_fixture(suffix)

    assert {:ok, %{call: started, started?: true}} =
             Calls.start_call(caller_scope, direct_conversation.id, :audio)

    {caller_scope, recipient_scope, started, friendship}
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

  defp restart_calls_runtime do
    stop_supervised!(DiscordClone.Calls.Supervisor)
    start_supervised!(DiscordClone.Calls.Supervisor)
    DiscordClone.Calls.CallCoordinator.begin_recovery()
    await_recovery_finished()
  end

  defp start_inbox_tab(token, tag) do
    start_topic_tab(token, tag, @inbox_topic)
  end

  defp start_call_tab(token, tag, call_id) do
    start_topic_tab(token, tag, call_topic(call_id))
  end

  defp start_topic_tab(token, tag, topic) do
    parent = self()

    start_supervised!(%{
      id: {:call_tab, tag},
      start: {
        Task,
        :start_link,
        [
          fn ->
            Process.flag(:trap_exit, true)

            {:ok, socket} =
              Phoenix.ChannelTest.__connect__(
                DiscordCloneWeb.Endpoint,
                CallSocket,
                %{},
                connect_info: %{session: %{"user_token" => token}},
                test_process: parent
              )

            {:ok, payload, channel} = Phoenix.ChannelTest.subscribe_and_join(socket, topic)
            send(parent, {:joined, tag, self(), payload, channel})
            tab_loop(parent, tag, channel)
          end
        ]
      }
    })
  end

  defp tab_loop(parent, tag, channel) do
    receive do
      %Phoenix.Socket.Message{event: event, payload: payload} ->
        send(parent, {:push, tag, event, payload})
        tab_loop(parent, tag, channel)

      %Phoenix.Socket.Reply{status: status, payload: payload} ->
        send(parent, {:reply, tag, status, payload})
        tab_loop(parent, tag, channel)

      {:EXIT, _pid, _reason} ->
        tab_loop(parent, tag, channel)

      {:sync, from} ->
        send(from, {:sync, tag})
        tab_loop(parent, tag, channel)
    end
  end

  defp await_joined(tag) do
    assert_receive {:joined, ^tag, _pid, _payload, _channel} = joined
    joined
  end

  defp await_tab_push(tag, event) do
    assert_receive {:push, ^tag, ^event, payload}
    payload
  end

  defp send_queued_ringing(socket, projection) do
    :ok =
      Phoenix.PubSub.broadcast(
        DiscordClone.PubSub,
        "calls:user:#{socket.assigns.current_scope.user.id}",
        {:call_ringing, projection}
      )
  end

  defp shutdown_reason?(:shutdown), do: true
  defp shutdown_reason?({:shutdown, _reason}), do: true
  defp shutdown_reason?(_reason), do: false

  defp refute_stopped(channel) do
    pid = channel.channel_pid
    ref = Process.monitor(pid)
    refute_receive {:DOWN, ^ref, :process, ^pid, _reason}, 0
  end

  defp missed_call_count do
    Repo.aggregate(
      from(activity in ActivityItem,
        where: activity.kind == ^ActivityItem.missed_direct_call_kind()
      ),
      :count
    )
  end

  defp call_topic(call_id), do: CallSignaling.call_topic(call_id)

  defp restore_env(key, nil), do: Application.delete_env(:discord_clone, key)
  defp restore_env(key, value), do: Application.put_env(:discord_clone, key, value)
end
