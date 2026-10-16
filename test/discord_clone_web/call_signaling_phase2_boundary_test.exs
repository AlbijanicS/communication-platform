defmodule DiscordCloneWeb.CallSignalingPhase2BoundaryTest do
  @moduledoc """
  Phase 2 Completion Gate certification.

  Tickets 01–06 own the focused lifecycle rows. This module is the auditor
  surface at the authenticated CallSocket boundary: private delivery, reconnect
  and exactly-once settlement, Friendship-removal close, and reserved-event
  resource absence. It does not clone those focused suites.
  """

  use DiscordClone.DataCase, async: false

  import DiscordClone.AccountsFixtures
  import DiscordClone.CallsFixtures
  import Phoenix.ChannelTest

  alias DiscordClone.Accounts
  alias DiscordClone.Activities.ActivityItem
  alias DiscordClone.Calls
  alias DiscordClone.Calls.CallAttempt
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

  describe "integrated matrix A: private discovery and terminal delivery" do
    test "caller, recipient, sibling tabs, and unrelated Users receive private role-correct outcomes" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("p2b_disc")

      outsider_scope = user_scope_fixture(user_fixture(username: "p2b_disc_out"))
      caller_token = Accounts.generate_user_session_token(caller_scope.user)
      recipient_token = Accounts.generate_user_session_token(recipient_scope.user)
      outsider_token = Accounts.generate_user_session_token(outsider_scope.user)
      missing_id = Ecto.UUID.generate()

      start_inbox_tab(caller_token, :caller_inbox_a)
      start_inbox_tab(caller_token, :caller_inbox_b)
      start_inbox_tab(recipient_token, :recipient_inbox_a)
      start_inbox_tab(recipient_token, :recipient_inbox_b)
      start_inbox_tab(outsider_token, :outsider_inbox)

      assert {:joined, :caller_inbox_a, caller_inbox_a_pid, caller_a_join, _ch} =
               await_joined(:caller_inbox_a)

      assert {:joined, :caller_inbox_b, caller_inbox_b_pid, %{call: nil}, _ch} =
               await_joined(:caller_inbox_b)

      assert {:joined, :recipient_inbox_a, recipient_inbox_a_pid, %{call: nil}, _ch} =
               await_joined(:recipient_inbox_a)

      assert {:joined, :recipient_inbox_b, recipient_inbox_b_pid, %{call: nil}, _ch} =
               await_joined(:recipient_inbox_b)

      assert {:joined, :outsider_inbox, outsider_pid, %{call: nil}, _ch} =
               await_joined(:outsider_inbox)

      activity_before = Repo.aggregate(ActivityItem, :count)
      messages_before = Repo.aggregate(Message, :count)
      running_before = MapSet.new(ExWebRTC.PeerConnection.get_all_running())

      send_command(caller_inbox_a_pid, "start_call", %{
        "signaling_session_id" => caller_a_join.signaling_session_id,
        "direct_conversation_id" => direct_conversation.id,
        "media_intent" => "audio"
      })

      assert {:ok, started_reply} = await_reply(:caller_inbox_a)
      assert started_reply.started == true
      assert started_reply.call.role == :caller
      assert started_reply.call.state == :ringing
      assert Map.keys(started_reply.call) |> Enum.sort() == expected_wire_call_keys()
      call_id = started_reply.call.call_id
      deadline = started_reply.call.ringing_deadline_at

      caller_b = await_tab_push(:caller_inbox_b, "outgoing_call_ringing")
      recipient_a = await_tab_push(:recipient_inbox_a, "incoming_call")
      recipient_b = await_tab_push(:recipient_inbox_b, "incoming_call")

      assert caller_b.call.call_id == call_id
      assert caller_b.call.role == :caller
      assert caller_b.call.ringing_deadline_at == deadline
      assert recipient_a.call.call_id == call_id
      assert recipient_a.call.role == :recipient
      assert recipient_a.call.ringing_deadline_at == deadline
      assert recipient_b.call.call_id == call_id
      assert recipient_b.call.role == :recipient
      assert recipient_b.call.ringing_deadline_at == deadline

      send(caller_inbox_a_pid, {:sync, self()})
      assert_receive {:sync, :caller_inbox_a}
      refute_received {:push, :caller_inbox_a, "outgoing_call_ringing", _}
      refute_received {:push, :caller_inbox_a, "incoming_call", _}

      send(outsider_pid, {:sync, self()})
      assert_receive {:sync, :outsider_inbox}
      refute_received {:push, :outsider_inbox, _event, _payload}

      %{socket: outsider_socket} = connect_calls_socket(outsider_scope.user)

      assert {:error, %{reason: "not_found"}} =
               subscribe_and_join(outsider_socket, call_topic(call_id))

      assert {:error, %{reason: "not_found"}} =
               subscribe_and_join(outsider_socket, call_topic(missing_id))

      start_call_tab(caller_token, :caller_call, call_id)
      start_call_tab(recipient_token, :recipient_call_a, call_id)
      start_call_tab(recipient_token, :recipient_call_b, call_id)

      assert {:joined, :caller_call, caller_call_pid, caller_call_join, _ch} =
               await_joined(:caller_call)

      assert {:joined, :recipient_call_a, recipient_call_a_pid, recipient_call_a_join, _ch} =
               await_joined(:recipient_call_a)

      assert {:joined, :recipient_call_b, recipient_call_b_pid, recipient_call_b_join, _ch} =
               await_joined(:recipient_call_b)

      assert caller_call_join.call.role == :caller
      assert caller_call_join.call.call_id == call_id
      assert caller_call_join.call.ringing_deadline_at == deadline
      assert recipient_call_a_join.call.role == :recipient
      assert recipient_call_a_join.call.call_id == call_id
      assert recipient_call_a_join.call.ringing_deadline_at == deadline
      assert recipient_call_b_join.call.role == :recipient
      assert recipient_call_b_join.call.call_id == call_id
      assert recipient_call_b_join.call.ringing_deadline_at == deadline

      send_command(recipient_call_a_pid, "decline_call", %{
        "signaling_session_id" => recipient_call_a_join.signaling_session_id,
        "call_id" => call_id
      })

      assert {:ok, declined_reply} = await_reply(:recipient_call_a)
      assert declined_reply.call.role == :recipient
      assert declined_reply.call.state == :terminal
      assert declined_reply.call.terminal_outcome == :declined
      assert declined_reply.call.call_id == call_id

      for {tag, role} <- [
            {:caller_inbox_a, :caller},
            {:caller_inbox_b, :caller},
            {:recipient_inbox_a, :recipient},
            {:recipient_inbox_b, :recipient},
            {:caller_call, :caller},
            {:recipient_call_b, :recipient}
          ] do
        payload = await_tab_push(tag, "call_declined")
        assert payload.call.call_id == call_id
        assert payload.call.role == role
        assert payload.call.terminal_outcome == :declined
        assert payload.call.state == :terminal
      end

      send(recipient_call_a_pid, {:sync, self()})
      assert_receive {:sync, :recipient_call_a}
      refute_received {:push, :recipient_call_a, "call_declined", _}

      send(outsider_pid, {:sync, self()})
      assert_receive {:sync, :outsider_inbox}
      refute_received {:push, :outsider_inbox, _event, _payload}

      send_command(recipient_call_b_pid, "decline_call", %{
        "signaling_session_id" => recipient_call_b_join.signaling_session_id,
        "call_id" => call_id
      })

      assert {:ok, retry} = await_reply(:recipient_call_b)
      assert retry.call.call_id == call_id
      assert retry.call.terminal_outcome == :declined
      assert retry.call.ended_at == declined_reply.call.ended_at

      send_command(caller_call_pid, "cancel_call", %{
        "signaling_session_id" => caller_call_join.signaling_session_id,
        "call_id" => call_id
      })

      assert {:ok, cancelled_after} = await_reply(:caller_call)
      assert cancelled_after.call.terminal_outcome == :declined
      assert cancelled_after.call.ended_at == declined_reply.call.ended_at

      for {tag, pid} <- [
            {:caller_inbox_a, caller_inbox_a_pid},
            {:caller_inbox_b, caller_inbox_b_pid},
            {:recipient_inbox_a, recipient_inbox_a_pid},
            {:recipient_inbox_b, recipient_inbox_b_pid},
            {:caller_call, caller_call_pid},
            {:recipient_call_a, recipient_call_a_pid},
            {:recipient_call_b, recipient_call_b_pid}
          ] do
        send(pid, {:sync, self()})
        assert_receive {:sync, ^tag}
        refute_received {:push, ^tag, "call_declined", _}
        refute_received {:push, ^tag, "call_cancelled", _}
      end

      assert {:ok, committed} = Calls.get_call(caller_scope, call_id)
      assert committed.terminal_outcome == :declined
      assert committed.ended_at == declined_reply.call.ended_at
      assert Repo.aggregate(CallAttempt, :count) == 1
      assert Repo.aggregate(ActivityItem, :count) == activity_before
      assert Repo.aggregate(Message, :count) == messages_before
      assert missed_call_count() == 0

      assert ExWebRTC.PeerConnection.get_all_running()
             |> MapSet.new()
             |> MapSet.difference(running_before)
             |> MapSet.size() == 0
    end
  end

  describe "integrated matrix B: reconnect, deadline, stale identity, and exactly once" do
    test "rejoins keep the original deadline, ignore retired identities, and settle timeout versus cancel once" do
      {caller_scope, recipient_scope, started} = start_ringing_call("p2b_rejoin")
      attempt_before = Repo.get!(CallAttempt, started.call_id)

      %{socket: inbox_socket} = connect_calls_socket(caller_scope.user)
      %{socket: call_socket} = connect_calls_socket(caller_scope.user)

      assert {:ok, first_inbox, first_inbox_channel} =
               subscribe_and_join(inbox_socket, @inbox_topic)

      assert {:ok, first_call, first_call_channel} =
               subscribe_and_join(call_socket, call_topic(started.call_id))

      assert first_inbox.call.call_id == started.call_id
      assert first_inbox.call.ringing_deadline_at == started.ringing_deadline_at
      assert first_call.call.call_id == started.call_id
      assert first_call.call.ringing_deadline_at == started.ringing_deadline_at
      refute first_inbox.signaling_session_id == first_call.signaling_session_id

      Process.unlink(first_inbox_channel.channel_pid)
      Process.unlink(first_call_channel.channel_pid)
      assert_reply leave(first_inbox_channel), :ok
      assert_reply leave(first_call_channel), :ok

      assert {:ok, second_inbox, second_inbox_channel} =
               subscribe_and_join(inbox_socket, @inbox_topic)

      assert {:ok, second_call, second_call_channel} =
               subscribe_and_join(call_socket, call_topic(started.call_id))

      refute second_inbox.signaling_session_id == first_inbox.signaling_session_id
      refute second_call.signaling_session_id == first_call.signaling_session_id
      refute second_inbox.signaling_session_id == second_call.signaling_session_id
      assert second_inbox.call.call_id == started.call_id
      assert second_call.call.call_id == started.call_id
      assert second_inbox.call.ringing_deadline_at == started.ringing_deadline_at
      assert second_call.call.ringing_deadline_at == started.ringing_deadline_at
      assert second_inbox.call.role == :caller

      attempt_after_rejoin = Repo.get!(CallAttempt, started.call_id)
      assert attempt_after_rejoin.state == :ringing
      assert attempt_after_rejoin.ringing_deadline_at == attempt_before.ringing_deadline_at
      assert attempt_after_rejoin.updated_at == attempt_before.updated_at

      assert_reply push(second_call_channel, "decline_call", %{
                     "signaling_session_id" => first_call.signaling_session_id,
                     "call_id" => started.call_id
                   }),
                   :error,
                   %{reason: "invalid_request"}

      assert {:ok, still_ringing} = Calls.get_call(caller_scope, started.call_id)
      assert still_ringing.state == :ringing

      attempt_after_stale = Repo.get!(CallAttempt, started.call_id)
      assert attempt_after_stale.updated_at == attempt_before.updated_at

      Process.unlink(second_call_channel.channel_pid)
      assert_reply leave(second_call_channel), :ok

      assert {:ok, declined} = Calls.decline_call(recipient_scope, started.call_id)
      assert declined.terminal_outcome == :declined
      assert_push "call_declined", declined_push
      assert declined_push.call.call_id == started.call_id

      :ok = Calls.broadcast_ringing(started)
      refute_push "outgoing_call_ringing", _payload
      refute_push "incoming_call", _payload
      send_queued_ringing(inbox_socket, started)
      refute_push "outgoing_call_ringing", _payload
      refute_push "incoming_call", _payload

      assert {:ok, %{call: later, started?: true}} =
               Calls.start_call(caller_scope, started.direct_conversation_id, :audio)

      refute later.call_id == started.call_id
      assert_push "outgoing_call_ringing", newer
      assert newer.call.call_id == later.call_id
      assert newer.call.state == :ringing

      old_terminal = %{
        call_id: started.call_id,
        direct_conversation_id: started.direct_conversation_id,
        caller_user_id: started.caller_user_id,
        recipient_user_id: started.recipient_user_id,
        media_intent: :audio,
        state: :terminal,
        ringing_deadline_at: started.ringing_deadline_at,
        started_at: started.started_at,
        terminal_outcome: :declined,
        ended_at: declined.ended_at
      }

      :ok =
        Phoenix.PubSub.broadcast(
          DiscordClone.PubSub,
          "calls:user:#{caller_scope.user.id}",
          {:call_declined, old_terminal}
        )

      refute_push "call_declined", _payload
      assert {:ok, current} = Calls.current_call(caller_scope)
      assert current.call_id == later.call_id
      assert current.state == :ringing

      Process.unlink(second_inbox_channel.channel_pid)

      caller_token = Accounts.generate_user_session_token(caller_scope.user)
      recipient_token = Accounts.generate_user_session_token(recipient_scope.user)
      start_inbox_tab(caller_token, :caller_inbox)
      start_inbox_tab(recipient_token, :recipient_inbox)
      start_call_tab(caller_token, :caller_call, later.call_id)
      start_call_tab(recipient_token, :recipient_call, later.call_id)

      assert {:joined, :caller_inbox, caller_inbox_pid, _p, _ch} = await_joined(:caller_inbox)

      assert {:joined, :recipient_inbox, recipient_inbox_pid, _p, _ch} =
               await_joined(:recipient_inbox)

      assert {:joined, :caller_call, caller_call_pid, _p, _ch} = await_joined(:caller_call)

      assert {:joined, :recipient_call, recipient_call_pid, _p, _ch} =
               await_joined(:recipient_call)

      make_ringing_deadline_due!(later.call_id)
      expire_task = Task.async(fn -> Calls.expire_ringing_attempt(later.call_id) end)
      cancel_task = Task.async(fn -> Calls.cancel_call(caller_scope, later.call_id) end)
      assert {:ok, first_terminal} = Task.await(expire_task)
      assert {:ok, second_terminal} = Task.await(cancel_task)
      assert first_terminal.terminal_outcome == second_terminal.terminal_outcome
      assert first_terminal.terminal_outcome in [:timed_out, :cancelled]
      assert first_terminal.ended_at == second_terminal.ended_at

      wire_event =
        case first_terminal.terminal_outcome do
          :timed_out -> "call_timed_out"
          :cancelled -> "call_cancelled"
        end

      for tag <- [:caller_inbox, :recipient_inbox, :caller_call, :recipient_call] do
        payload = await_tab_push(tag, wire_event)
        assert payload.call.call_id == later.call_id
        assert payload.call.terminal_outcome == first_terminal.terminal_outcome
      end

      assert length(missed_call_activity_items(recipient_scope.user.id, later.call_id)) == 1
      assert missed_call_activity_items(recipient_scope.user.id, started.call_id) == []
      assert Repo.aggregate(CallAttempt, :count) == 2

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
  end

  describe "integrated matrix C: Friendship removal and former-Friend privacy" do
    test "relationship end delivers once, closes Call topics, and leaves inboxes joined" do
      {caller_scope, recipient_scope, started, friendship} =
        start_ringing_call_with_friendship("p2b_rm")

      outsider_scope = user_scope_fixture(user_fixture(username: "p2b_rm_out"))
      caller_token = Accounts.generate_user_session_token(caller_scope.user)
      recipient_token = Accounts.generate_user_session_token(recipient_scope.user)
      outsider_token = Accounts.generate_user_session_token(outsider_scope.user)
      voice_channel_id = Ecto.UUID.generate()

      assert {:ok, %{voice_session_id: voice_session_id}} =
               Voice.join(voice_channel_id, caller_scope.user.id, "p2b-rm-voice", self())

      messages_before = Repo.aggregate(Message, :count)
      occupancy_before = Registry.count(DiscordClone.Calls.CallRegistry)
      running_before = MapSet.new(ExWebRTC.PeerConnection.get_all_running())

      start_inbox_tab(caller_token, :caller_inbox)
      start_inbox_tab(recipient_token, :recipient_inbox)
      start_inbox_tab(outsider_token, :outsider_inbox)
      start_call_tab(caller_token, :caller_call, started.call_id)
      start_call_tab(recipient_token, :recipient_call, started.call_id)

      assert {:joined, :caller_inbox, caller_inbox_pid, _p, caller_inbox} =
               await_joined(:caller_inbox)

      assert {:joined, :recipient_inbox, recipient_inbox_pid, _p, recipient_inbox} =
               await_joined(:recipient_inbox)

      assert {:joined, :outsider_inbox, outsider_pid, _p, _ch} = await_joined(:outsider_inbox)

      assert {:joined, :caller_call, _pid, caller_join, caller_call} = await_joined(:caller_call)

      assert {:joined, :recipient_call, _pid, recipient_join, recipient_call} =
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
      assert caller_inbox_ended.call.terminal_outcome == :relationship_ended
      assert recipient_inbox_ended.call.terminal_outcome == :relationship_ended
      assert caller_call_ended.call.terminal_outcome == :relationship_ended
      assert recipient_call_ended.call.terminal_outcome == :relationship_ended
      assert caller_call_ended.signaling_session_id == caller_join.signaling_session_id
      assert recipient_call_ended.signaling_session_id == recipient_join.signaling_session_id

      assert_receive {:DOWN, ^caller_ref, :process, ^caller_call_pid, caller_reason}
      assert_receive {:DOWN, ^recipient_ref, :process, ^recipient_call_pid, recipient_reason}
      assert shutdown_reason?(caller_reason)
      assert shutdown_reason?(recipient_reason)
      refute match?({:crash, _}, caller_reason)
      refute match?({:crash, _}, recipient_reason)

      send(outsider_pid, {:sync, self()})
      assert_receive {:sync, :outsider_inbox}
      refute_received {:push, :outsider_inbox, _event, _payload}

      send(caller_inbox_pid, {:sync, self()})
      assert_receive {:sync, :caller_inbox}
      refute_received {:push, :caller_inbox, "call_ended", _}

      send(recipient_inbox_pid, {:sync, self()})
      assert_receive {:sync, :recipient_inbox}
      refute_received {:push, :recipient_inbox, "call_ended", _}

      refute_stopped(caller_inbox)
      refute_stopped(recipient_inbox)

      %{socket: caller_inbox_rejoin} = connect_calls_socket(caller_scope.user)
      %{socket: recipient_inbox_rejoin} = connect_calls_socket(recipient_scope.user)

      assert {:ok, caller_snapshot, _ch} =
               subscribe_and_join(caller_inbox_rejoin, @inbox_topic)

      assert {:ok, recipient_snapshot, _ch} =
               subscribe_and_join(recipient_inbox_rejoin, @inbox_topic)

      assert caller_snapshot.call == nil
      assert recipient_snapshot.call == nil
      assert {:ok, nil} = Calls.current_call(caller_scope)
      assert {:ok, nil} = Calls.current_call(recipient_scope)

      assert {:error, :not_found} = Calls.get_call(caller_scope, started.call_id)
      assert {:error, :not_found} = Calls.get_call(recipient_scope, started.call_id)
      assert {:error, :not_found} = Calls.get_call(outsider_scope, started.call_id)
      assert {:error, :not_found} = Calls.decline_call(recipient_scope, started.call_id)
      assert {:error, :not_found} = Calls.cancel_call(caller_scope, started.call_id)

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
                 connect_calls_socket(outsider_scope.user).socket,
                 call_topic(Ecto.UUID.generate())
               )

      assert missed_call_activity_items(recipient_scope.user.id, started.call_id) == []
      assert Repo.aggregate(Message, :count) == messages_before
      assert Registry.count(DiscordClone.Calls.CallRegistry) <= occupancy_before

      assert {:ok, %{members: [%{user_id: caller_user_id}]}} =
               Voice.voice_channel_roster(voice_channel_id)

      assert caller_user_id == caller_scope.user.id
      assert :ok = Voice.leave(voice_channel_id, voice_session_id)

      assert ExWebRTC.PeerConnection.get_all_running()
             |> MapSet.new()
             |> MapSet.difference(running_before)
             |> MapSet.size() == 0
    end
  end

  describe "integrated matrix D: reserved boundary and resource absence" do
    test "well-formed reserved events reject without mutating the attempt or allocating media" do
      {caller_scope, recipient_scope, started} = start_ringing_call("p2b_rsv")
      voice_channel_id = Ecto.UUID.generate()

      assert {:ok, %{voice_session_id: voice_session_id}} =
               Voice.join(voice_channel_id, caller_scope.user.id, "p2b-rsv-voice", self())

      %{socket: socket} = connect_calls_socket(recipient_scope.user)
      assert {:ok, _payload, channel} = subscribe_and_join(socket, call_topic(started.call_id))

      attempt_before = Repo.get!(CallAttempt, started.call_id)
      activity_before = Repo.aggregate(ActivityItem, :count)
      messages_before = Repo.aggregate(Message, :count)
      occupancy_before = Registry.count(DiscordClone.Calls.CallRegistry)
      running_before = MapSet.new(ExWebRTC.PeerConnection.get_all_running())
      assigns_before = reviewed_assigns(channel)

      assert_reply push(channel, "accept_call", reserved_control_payload(channel)), :error, %{
        reason: "invalid_request"
      }

      assert_reply push(channel, "leave_call", reserved_control_payload(channel)), :error, %{
        reason: "stale"
      }

      assert_reply push(channel, "offer", reserved_offer_payload(channel)), :error, %{
        reason: "not_admitted"
      }

      assert_reply push(
                     channel,
                     "accept_call",
                     reserved_control_payload(channel, %{
                       "signaling_session_id" => "forged-signaling"
                     })
                   ),
                   :error,
                   %{reason: "invalid_request"}

      assert_reply push(channel, "offer", reserved_offer_payload(channel, %{"extra" => true})),
                   :error,
                   %{reason: "invalid_request"}

      _ = :sys.get_state(channel.channel_pid)

      attempt_after = Repo.get!(CallAttempt, started.call_id)
      assert attempt_after.state == attempt_before.state
      assert attempt_after.ringing_deadline_at == attempt_before.ringing_deadline_at
      assert attempt_after.inserted_at == attempt_before.inserted_at
      assert attempt_after.updated_at == attempt_before.updated_at
      assert attempt_after.terminal_outcome == attempt_before.terminal_outcome
      assert attempt_after.ended_at == attempt_before.ended_at
      assert Repo.aggregate(ActivityItem, :count) == activity_before
      assert Repo.aggregate(Message, :count) == messages_before
      assert Registry.count(DiscordClone.Calls.CallRegistry) == occupancy_before
      assert reviewed_assigns(channel) == assigns_before
      assert retained_media_assigns(channel) == %{}

      assert {:ok, still_ringing} = Calls.get_call(caller_scope, started.call_id)
      assert still_ringing.state == :ringing

      assert {:ok, %{members: [%{user_id: caller_user_id}]}} =
               Voice.voice_channel_roster(voice_channel_id)

      assert caller_user_id == caller_scope.user.id
      assert :ok = Voice.leave(voice_channel_id, voice_session_id)

      assert ExWebRTC.PeerConnection.get_all_running()
             |> MapSet.new()
             |> MapSet.difference(running_before)
             |> MapSet.size() == 0
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

      {:push_command, event, payload} ->
        _ref = Phoenix.ChannelTest.push(channel, event, payload)
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

  defp send_command(pid, event, payload) when is_pid(pid) do
    send(pid, {:push_command, event, payload})
  end

  defp await_tab_push(tag, event) do
    assert_receive {:push, ^tag, ^event, payload}
    payload
  end

  defp await_reply(tag) do
    assert_receive {:reply, ^tag, status, payload}
    {status, payload}
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

  defp reserved_control_payload(channel, overrides \\ %{}) do
    Map.merge(
      %{
        "signaling_session_id" => channel.assigns.signaling_session_id,
        "call_id" => channel.assigns.call_id
      },
      overrides
    )
  end

  defp reserved_offer_payload(channel, overrides \\ %{}) do
    Map.merge(
      %{
        "signaling_session_id" => channel.assigns.signaling_session_id,
        "call_id" => channel.assigns.call_id,
        "call_session_id" => "opaque-call-session",
        "negotiation_id" => "opaque-negotiation",
        "description" => %{"type" => "offer", "sdp" => "v=0"}
      },
      overrides
    )
  end

  defp reviewed_assigns(channel) do
    Map.take(:sys.get_state(channel.channel_pid).assigns, [
      :call_id,
      :signaling_session_id,
      :last_call
    ])
  end

  defp retained_media_assigns(channel) do
    Map.take(:sys.get_state(channel.channel_pid).assigns, [
      :call_session_id,
      :negotiation_id,
      :candidates,
      :candidate_queue,
      :ice_route,
      :media_state_version,
      :camera_enabled,
      :renewal
    ])
  end

  defp expected_wire_call_keys do
    (Calls.projection_keys() ++ [:ownership, :peer, :role]) |> Enum.sort()
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
end
