defmodule DiscordCloneWeb.CallChannelTest do
  use DiscordClone.DataCase, async: false

  import DiscordClone.AccountsFixtures
  import DiscordClone.CallsFixtures
  import Ecto.Query
  import Phoenix.ChannelTest

  alias DiscordClone.Accounts
  alias DiscordClone.Activities.ActivityItem
  alias DiscordClone.Calls
  alias DiscordClone.Calls.{CallAttempt, CallServer, ScriptedAcceptedCallRuntime}
  alias DiscordClone.Chat.Message
  alias DiscordClone.Friendships
  alias DiscordClone.Repo
  alias DiscordClone.Voice
  alias DiscordCloneWeb.{CallChannel, CallSignaling, CallSocket}

  @endpoint DiscordCloneWeb.Endpoint
  @inbox_topic CallSignaling.inbox_topic()

  setup do
    start_supervised!(DiscordClone.Calls.Supervisor)
    DiscordClone.Calls.CallCoordinator.begin_recovery()
    await_recovery_finished()
    :ok
  end

  describe "join" do
    test "caller and recipient receive distinct Signaling Session IDs and role-correct projections" do
      {caller_scope, recipient_scope, started} = start_ringing_call("c04_join_roles")

      %{socket: caller_socket} = connect_calls_socket(caller_scope.user)
      %{socket: recipient_socket} = connect_calls_socket(recipient_scope.user)

      assert {:ok, caller_payload, _caller} =
               subscribe_and_join(caller_socket, call_topic(started.call_id))

      assert {:ok, recipient_payload, _recipient} =
               subscribe_and_join(recipient_socket, call_topic(started.call_id))

      assert Map.keys(caller_payload) |> Enum.sort() == [:call, :signaling_session_id]
      assert {:ok, _} = Ecto.UUID.cast(caller_payload.signaling_session_id)
      refute caller_payload.signaling_session_id == recipient_payload.signaling_session_id

      assert Map.keys(caller_payload.call) |> Enum.sort() ==
               expected_wire_call_keys(caller_payload.call)

      assert caller_payload.call.role == :caller
      assert recipient_payload.call.role == :recipient

      assert caller_payload.call.peer == %{
               id: recipient_scope.user.id,
               username: recipient_scope.user.username
             }

      assert recipient_payload.call.peer == %{
               id: caller_scope.user.id,
               username: caller_scope.user.username
             }

      assert Map.keys(caller_payload.call.peer) |> Enum.sort() == [:id, :username]
      refute Map.has_key?(caller_payload.call.peer, :email)
      assert caller_payload.call.call_id == started.call_id
      assert caller_payload.call.state == :ringing
      assert caller_payload.call.ringing_deadline_at == started.ringing_deadline_at
    end

    test "two tabs and a rejoin receive distinct Call-topic identities" do
      {caller_scope, _recipient_scope, started} = start_ringing_call("c04_join_tabs")
      topic = call_topic(started.call_id)
      %{socket: socket, token: token} = connect_calls_socket(caller_scope.user)

      assert {:ok, first, first_channel} = subscribe_and_join(socket, topic)
      Process.unlink(first_channel.channel_pid)
      ref = leave(first_channel)
      assert_reply ref, :ok

      assert {:ok, second, _second_channel} = subscribe_and_join(socket, topic)

      other_socket = connect_authenticated_socket(token)
      assert {:ok, third, _third_channel} = subscribe_and_join(other_socket, topic)

      ids = [
        first.signaling_session_id,
        second.signaling_session_id,
        third.signaling_session_id
      ]

      assert ids == Enum.uniq(ids)
    end

    test "Call-topic identity is distinct from the inbox identity" do
      {caller_scope, _recipient_scope, started} = start_ringing_call("c04_join_inbox")
      %{socket: socket} = connect_calls_socket(caller_scope.user)

      assert {:ok, inbox, _inbox_channel} = subscribe_and_join(socket, @inbox_topic)

      assert {:ok, call, _call_channel} =
               subscribe_and_join(socket, call_topic(started.call_id))

      refute inbox.signaling_session_id == call.signaling_session_id
      assert call.call.call_id == started.call_id
    end

    test "joining a terminal Call returns the committed projection and does not revive ringing" do
      {caller_scope, recipient_scope, started} = start_ringing_call("c04_join_term")
      assert {:ok, declined} = Calls.decline_call(recipient_scope, started.call_id)

      %{socket: socket} = connect_calls_socket(caller_scope.user)

      assert {:ok, payload, _channel} =
               subscribe_and_join(socket, call_topic(started.call_id))

      assert payload.call.call_id == declined.call_id
      assert payload.call.state == :terminal
      assert payload.call.terminal_outcome == :declined
      refute payload.call.state == :ringing
    end

    test "join is observational and allocates no Voice or Direct Call media" do
      {caller_scope, recipient_scope, started} = start_ringing_call("c04_join_obs")
      voice_channel_id = Ecto.UUID.generate()

      assert {:ok, %{voice_session_id: voice_session_id}} =
               Voice.join(voice_channel_id, caller_scope.user.id, "c04-join-voice", self())

      attempt_before = Repo.get!(CallAttempt, started.call_id)
      activity_before = Repo.aggregate(ActivityItem, :count)
      messages_before = Repo.aggregate(Message, :count)
      occupancy_before = Registry.count(DiscordClone.Calls.CallRegistry)
      running_before = MapSet.new(ExWebRTC.PeerConnection.get_all_running())

      %{socket: caller_socket} = connect_calls_socket(caller_scope.user)
      %{socket: recipient_socket} = connect_calls_socket(recipient_scope.user)

      assert {:ok, _caller_payload, _caller} =
               subscribe_and_join(caller_socket, call_topic(started.call_id))

      assert {:ok, _recipient_payload, _recipient} =
               subscribe_and_join(recipient_socket, call_topic(started.call_id))

      attempt_after = Repo.get!(CallAttempt, started.call_id)
      assert attempt_after.state == :ringing
      assert attempt_after.ringing_deadline_at == attempt_before.ringing_deadline_at
      assert attempt_after.updated_at == attempt_before.updated_at
      assert attempt_after.terminal_outcome == attempt_before.terminal_outcome
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

    test "rejects extra join fields, malformed topics, missing Calls, outsiders, and former Friends as safe failures" do
      {caller_scope, recipient_scope, started, friendship} =
        start_ringing_call_with_friendship("c04_join_auth")

      outsider_scope = user_scope_fixture(user_fixture(username: "c04_join_out"))
      %{socket: caller_socket} = connect_calls_socket(caller_scope.user)
      %{socket: outsider_socket} = connect_calls_socket(outsider_scope.user)
      topic = call_topic(started.call_id)

      assert {:error, %{reason: "invalid_request"}} =
               subscribe_and_join(caller_socket, topic, %{"user_id" => caller_scope.user.id})

      assert {:error, %{reason: "invalid_request"}} =
               subscribe_and_join(caller_socket, topic, %{
                 "signaling_session_id" => "forged-signaling"
               })

      assert {:error, %{reason: "invalid_request"}} =
               subscribe_and_join(caller_socket, "call:not-a-uuid")

      assert {:error, %{reason: "invalid_request"}} =
               subscribe_and_join(caller_socket, CallChannel, "call:")

      assert {:error, %{reason: "not_found"}} =
               subscribe_and_join(caller_socket, call_topic(Ecto.UUID.generate()))

      assert {:error, %{reason: "not_found"}} = subscribe_and_join(outsider_socket, topic)
      assert {:ok, still_ringing} = Calls.get_call(caller_scope, started.call_id)
      assert still_ringing.state == :ringing

      assert :ok = Friendships.remove_friend(recipient_scope, friendship.id)

      assert {:error, %{reason: "not_found"}} =
               subscribe_and_join(connect_calls_socket(caller_scope.user).socket, topic)
    end
  end

  describe "decline_call" do
    test "recipient decline returns the role-correct terminal projection and creates no Activity or Message" do
      {caller_scope, recipient_scope, started} = start_ringing_call("c04_dec_ok")
      %{socket: socket} = connect_calls_socket(recipient_scope.user)

      assert {:ok, %{signaling_session_id: signaling_session_id}, channel} =
               subscribe_and_join(socket, call_topic(started.call_id))

      activity_before = Repo.aggregate(ActivityItem, :count)
      messages_before = Repo.aggregate(Message, :count)
      running_before = MapSet.new(ExWebRTC.PeerConnection.get_all_running())

      assert_reply push(channel, "decline_call", command_payload(channel)), :ok, %{
        signaling_session_id: ^signaling_session_id,
        call: declined
      }

      assert Map.keys(declined) |> Enum.sort() == expected_wire_call_keys(declined)
      assert declined.call_id == started.call_id
      assert declined.role == :recipient
      assert declined.state == :terminal
      assert declined.terminal_outcome == :declined
      refute_push "call_declined", _payload
      assert Repo.aggregate(ActivityItem, :count) == activity_before
      assert Repo.aggregate(Message, :count) == messages_before

      assert {:ok, committed} = Calls.get_call(caller_scope, started.call_id)
      assert committed.terminal_outcome == :declined

      assert ExWebRTC.PeerConnection.get_all_running()
             |> MapSet.new()
             |> MapSet.difference(running_before)
             |> MapSet.size() == 0
    end

    test "caller and outsider decline fail as not_found without mutation" do
      {caller_scope, _recipient_scope, started} = start_ringing_call("c04_dec_auth")
      outsider_scope = user_scope_fixture(user_fixture(username: "c04_dec_out"))

      %{socket: caller_socket} = connect_calls_socket(caller_scope.user)

      assert {:ok, _payload, caller_channel} =
               subscribe_and_join(caller_socket, call_topic(started.call_id))

      assert_reply push(caller_channel, "decline_call", command_payload(caller_channel)),
                   :error,
                   %{reason: "not_found"}

      %{socket: outsider_socket} = connect_calls_socket(outsider_scope.user)

      assert {:error, %{reason: "not_found"}} =
               subscribe_and_join(outsider_socket, call_topic(started.call_id))

      assert {:ok, still_ringing} = Calls.get_call(caller_scope, started.call_id)
      assert still_ringing.state == :ringing
    end
  end

  describe "cancel_call" do
    test "caller cancel returns the committed projection and creates exactly one missed Activity Item" do
      {caller_scope, recipient_scope, started} = start_ringing_call("c04_can_ok")
      %{socket: caller_socket} = connect_calls_socket(caller_scope.user)

      assert {:ok, %{signaling_session_id: signaling_session_id}, channel} =
               subscribe_and_join(caller_socket, call_topic(started.call_id))

      activity_before = Repo.aggregate(ActivityItem, :count)
      messages_before = Repo.aggregate(Message, :count)

      assert_reply push(channel, "cancel_call", command_payload(channel)), :ok, %{
        signaling_session_id: ^signaling_session_id,
        call: cancelled
      }

      assert cancelled.role == :caller
      assert cancelled.state == :terminal
      assert cancelled.terminal_outcome == :cancelled
      refute_push "call_cancelled", _payload
      assert Repo.aggregate(ActivityItem, :count) == activity_before + 1
      assert Repo.aggregate(Message, :count) == messages_before

      activity =
        Repo.get_by!(ActivityItem,
          source_call_attempt_id: started.call_id,
          kind: ActivityItem.missed_direct_call_kind()
        )

      assert activity.recipient_user_id == recipient_scope.user.id
    end

    test "recipient and outsider cancel fail as not_found without mutation" do
      {caller_scope, recipient_scope, started} = start_ringing_call("c04_can_auth")
      outsider_scope = user_scope_fixture(user_fixture(username: "c04_can_out"))

      %{socket: recipient_socket} = connect_calls_socket(recipient_scope.user)

      assert {:ok, _payload, recipient_channel} =
               subscribe_and_join(recipient_socket, call_topic(started.call_id))

      assert_reply push(recipient_channel, "cancel_call", command_payload(recipient_channel)),
                   :error,
                   %{reason: "not_found"}

      %{socket: outsider_socket} = connect_calls_socket(outsider_scope.user)

      assert {:error, %{reason: "not_found"}} =
               subscribe_and_join(outsider_socket, call_topic(started.call_id))

      assert {:ok, still_ringing} = Calls.get_call(caller_scope, started.call_id)
      assert still_ringing.state == :ringing
      assert missed_call_count() == 0
    end
  end

  describe "command validation and durable truth" do
    test "rejects forged, missing, stale, non-binary, and over-128-byte Signaling Session IDs" do
      {_caller_scope, recipient_scope, started} = start_ringing_call("c04_val_sid")
      %{socket: socket} = connect_calls_socket(recipient_scope.user)
      assert {:ok, _payload, channel} = subscribe_and_join(socket, call_topic(started.call_id))
      attempts_before = attempt_state(started.call_id)

      payloads = [
        command_payload(channel, %{"signaling_session_id" => Ecto.UUID.generate()}),
        command_payload(channel, %{"signaling_session_id" => "forged-signaling"}),
        command_payload(channel) |> Map.delete("signaling_session_id"),
        command_payload(channel, %{"signaling_session_id" => 123}),
        command_payload(channel, %{"signaling_session_id" => String.duplicate("a", 129)})
      ]

      for payload <- payloads do
        assert_reply push(channel, "decline_call", payload), :error, %{reason: "invalid_request"}
      end

      assert attempt_state(started.call_id) == attempts_before
    end

    test "rejects missing, extra, malformed, over-limit payloads and a Call ID that does not match the topic" do
      {_caller_scope, recipient_scope, started} = start_ringing_call("c04_val_pl")
      %{socket: socket} = connect_calls_socket(recipient_scope.user)
      assert {:ok, _payload, channel} = subscribe_and_join(socket, call_topic(started.call_id))
      attempts_before = attempt_state(started.call_id)
      valid = command_payload(channel)
      exact = padded_payload(valid, 4096)
      over = padded_payload(valid, 4097)

      assert_reply push(channel, "decline_call", ["not-an-object"]), :error, %{
        reason: "invalid_request"
      }

      assert_reply push(channel, "decline_call", Map.delete(valid, "call_id")), :error, %{
        reason: "invalid_request"
      }

      assert_reply push(channel, "decline_call", Map.put(valid, "role", "recipient")), :error, %{
        reason: "invalid_request"
      }

      assert_reply push(channel, "decline_call", %{valid | "call_id" => Ecto.UUID.generate()}),
                   :error,
                   %{reason: "invalid_request"}

      assert_reply push(channel, "decline_call", %{valid | "call_id" => "not-a-uuid"}), :error, %{
        reason: "invalid_request"
      }

      assert_reply push(channel, "decline_call", exact), :error, %{reason: "invalid_request"}
      assert_reply push(channel, "decline_call", over), :error, %{reason: "invalid_request"}
      assert attempt_state(started.call_id) == attempts_before
    end

    test "a repeated decline and a later cancel return the committed declined outcome" do
      {caller_scope, recipient_scope, started} = start_ringing_call("c04_retry")
      %{socket: recipient_socket} = connect_calls_socket(recipient_scope.user)
      %{socket: caller_socket} = connect_calls_socket(caller_scope.user)

      assert {:ok, _payload, recipient_channel} =
               subscribe_and_join(recipient_socket, call_topic(started.call_id))

      assert {:ok, _payload, caller_channel} =
               subscribe_and_join(caller_socket, call_topic(started.call_id))

      assert_reply push(recipient_channel, "decline_call", command_payload(recipient_channel)),
                   :ok,
                   %{call: first}

      assert first.terminal_outcome == :declined

      assert_reply push(recipient_channel, "decline_call", command_payload(recipient_channel)),
                   :ok,
                   %{call: retry}

      assert retry.call_id == first.call_id
      assert retry.terminal_outcome == :declined
      assert retry.ended_at == first.ended_at

      assert_reply push(caller_channel, "cancel_call", command_payload(caller_channel)), :ok, %{
        call: cancelled_after
      }

      assert cancelled_after.terminal_outcome == :declined
      assert missed_call_count() == 0
      assert Repo.aggregate(CallAttempt, :count) == 1
    end

    test "sibling-tab concurrent cancels converge on one missed Activity Item" do
      {caller_scope, _recipient_scope, started} = start_ringing_call("c04_conc")
      token = Accounts.generate_user_session_token(caller_scope.user)
      start_inbox_tab(token, :observer)
      start_call_tab(token, :tab_a, started.call_id)
      start_call_tab(token, :tab_b, started.call_id)

      assert {:joined, :observer, observer_pid, _payload, _ch} = await_joined(:observer)
      assert {:joined, :tab_a, pid_a, payload_a, _ch} = await_joined(:tab_a)
      assert {:joined, :tab_b, pid_b, payload_b, _ch} = await_joined(:tab_b)

      send_command(pid_a, "cancel_call", %{
        "signaling_session_id" => payload_a.signaling_session_id,
        "call_id" => started.call_id
      })

      send_command(pid_b, "cancel_call", %{
        "signaling_session_id" => payload_b.signaling_session_id,
        "call_id" => started.call_id
      })

      replies = [await_reply(:tab_a), await_reply(:tab_b)]

      assert Enum.all?(replies, fn {status, payload} ->
               status == :ok and payload.call.terminal_outcome == :cancelled
             end)

      assert missed_call_count() == 1
      assert Repo.aggregate(CallAttempt, :count) == 1

      observer = await_tab_push(:observer, "call_cancelled")
      assert observer.call.call_id == started.call_id
      assert observer.call.terminal_outcome == :cancelled
      send(observer_pid, {:sync, self()})
      assert_receive {:sync, :observer}
      refute_received {:push, :observer, "call_cancelled", _}
    end

    test "a connecting decline is stale and an active cancel is stale" do
      {_caller_scope, recipient_scope, started} = start_ringing_call("c04_stale_dec")
      now = DateTime.utc_now(:microsecond)

      Repo.get!(CallAttempt, started.call_id)
      |> Ecto.Changeset.change(%{state: :connecting, accepted_at: now})
      |> Repo.update!()

      %{socket: recipient_socket} = connect_calls_socket(recipient_scope.user)

      assert {:ok, _payload, recipient_channel} =
               subscribe_and_join(recipient_socket, call_topic(started.call_id))

      assert_reply push(recipient_channel, "decline_call", command_payload(recipient_channel)),
                   :error,
                   %{reason: "stale"}

      {caller_scope, _recipient_scope, active} = start_ringing_call("c04_stale_can")

      Repo.get!(CallAttempt, active.call_id)
      |> Ecto.Changeset.change(%{
        state: :active,
        accepted_at: DateTime.utc_now(:microsecond)
      })
      |> Repo.update!()

      %{socket: caller_socket} = connect_calls_socket(caller_scope.user)

      assert {:ok, _payload, caller_channel} =
               subscribe_and_join(caller_socket, call_topic(active.call_id))

      assert_reply push(caller_channel, "cancel_call", command_payload(caller_channel)),
                   :error,
                   %{
                     reason: "stale"
                   }
    end

    test "a durable command failure is temporarily_unavailable without mutating the attempt" do
      {caller_scope, _recipient_scope, started} = start_ringing_call("c04_unav")
      future = DateTime.add(DateTime.utc_now(:microsecond), 3600, :second)

      Repo.get!(CallAttempt, started.call_id)
      |> Ecto.Changeset.change(%{
        inserted_at: future,
        ringing_deadline_at: DateTime.add(future, 30, :second),
        updated_at: future
      })
      |> Repo.update!()

      %{socket: socket} = connect_calls_socket(caller_scope.user)

      assert {:ok, _payload, channel} =
               subscribe_and_join(socket, call_topic(started.call_id))

      assert_reply push(channel, "cancel_call", command_payload(channel)), :error, %{
        reason: "temporarily_unavailable"
      }

      assert {:ok, still_ringing} = Calls.get_call(caller_scope, started.call_id)
      assert still_ringing.state == :ringing
      assert is_nil(still_ringing.terminal_outcome)
      assert missed_call_count() == 0
    end
  end

  describe "terminal delivery and leave" do
    test "inbox and Call-topic tabs receive the committed terminal and an unrelated User receives nothing" do
      {caller_scope, recipient_scope, started} = start_ringing_call("c04_deliv")
      outsider_scope = user_scope_fixture(user_fixture(username: "c04_deliv_out"))
      caller_token = Accounts.generate_user_session_token(caller_scope.user)
      recipient_token = Accounts.generate_user_session_token(recipient_scope.user)
      outsider_token = Accounts.generate_user_session_token(outsider_scope.user)

      start_inbox_tab(caller_token, :caller_inbox)
      start_inbox_tab(recipient_token, :recipient_inbox)
      start_inbox_tab(outsider_token, :outsider_inbox)
      start_call_tab(caller_token, :caller_call, started.call_id)
      start_call_tab(recipient_token, :recipient_call, started.call_id)

      assert {:joined, :caller_inbox, caller_inbox_pid, _payload, _ch} =
               await_joined(:caller_inbox)

      assert {:joined, :recipient_inbox, recipient_inbox_pid, _payload, _ch} =
               await_joined(:recipient_inbox)

      assert {:joined, :outsider_inbox, outsider_pid, _payload, _ch} =
               await_joined(:outsider_inbox)

      assert {:joined, :caller_call, caller_call_pid, caller_call, _ch} =
               await_joined(:caller_call)

      assert {:joined, :recipient_call, recipient_pid, recipient_join, _ch} =
               await_joined(:recipient_call)

      send_command(recipient_pid, "decline_call", %{
        "signaling_session_id" => recipient_join.signaling_session_id,
        "call_id" => started.call_id
      })

      assert {:ok, %{call: declined}} = await_reply(:recipient_call)
      assert declined.terminal_outcome == :declined
      refute_received {:push, :recipient_call, "call_declined", _}

      caller_inbox = await_tab_push(:caller_inbox, "call_declined")
      recipient_inbox = await_tab_push(:recipient_inbox, "call_declined")
      caller_call_push = await_tab_push(:caller_call, "call_declined")

      assert caller_inbox.call.role == :caller
      assert recipient_inbox.call.role == :recipient
      assert caller_call_push.call.role == :caller
      assert caller_call_push.signaling_session_id == caller_call.signaling_session_id

      assert Enum.all?(
               [caller_inbox, recipient_inbox, caller_call_push],
               &(&1.call.call_id == started.call_id)
             )

      send(outsider_pid, {:sync, self()})
      assert_receive {:sync, :outsider_inbox}
      refute_received {:push, :outsider_inbox, _event, _payload}

      for {tag, pid} <- [
            {:caller_inbox, caller_inbox_pid},
            {:recipient_inbox, recipient_inbox_pid},
            {:caller_call, caller_call_pid}
          ] do
        send(pid, {:sync, self()})
        assert_receive {:sync, ^tag}
        refute_received {:push, ^tag, "call_declined", _}
      end
    end

    test "ignores a terminal projection for a different Call ID" do
      {caller_scope, _recipient_scope, started} = start_ringing_call("c04_ignore")
      %{socket: socket} = connect_calls_socket(caller_scope.user)
      assert {:ok, payload, _channel} = subscribe_and_join(socket, call_topic(started.call_id))

      other_call = %{
        call_id: Ecto.UUID.generate(),
        direct_conversation_id: started.direct_conversation_id,
        caller_user_id: started.caller_user_id,
        recipient_user_id: started.recipient_user_id,
        media_intent: :audio,
        state: :terminal,
        ringing_deadline_at: started.ringing_deadline_at,
        started_at: started.started_at,
        terminal_outcome: :declined,
        ended_at: DateTime.utc_now(:microsecond)
      }

      :ok =
        Phoenix.PubSub.broadcast(
          DiscordClone.PubSub,
          "calls:user:#{caller_scope.user.id}",
          {:call_declined, other_call}
        )

      refute_push "call_declined", _payload
      assert payload.call.call_id == started.call_id
    end

    test "maps timeout, relationship end, and interruption through the canonical events" do
      {caller_scope, _recipient_scope, started} = start_ringing_call("c04_timeout")
      %{socket: timeout_socket} = connect_calls_socket(caller_scope.user)

      assert {:ok, _payload, _channel} =
               subscribe_and_join(timeout_socket, call_topic(started.call_id))

      make_ringing_deadline_due!(started.call_id)
      assert {:ok, _timed_out} = Calls.expire_ringing_attempt(started.call_id)
      assert_push "call_timed_out", timed_out
      assert timed_out.call.terminal_outcome == :timed_out
      assert timed_out.call.call_id == started.call_id

      {caller_scope2, _recipient_scope2, ringing2, friendship} =
        start_ringing_call_with_friendship("c04_ended")

      %{socket: ended_socket} = connect_calls_socket(caller_scope2.user)

      assert {:ok, ended_join, ended_channel} =
               subscribe_and_join(ended_socket, call_topic(ringing2.call_id))

      ended_pid = ended_channel.channel_pid
      Process.unlink(ended_pid)
      ended_ref = Process.monitor(ended_pid)

      assert :ok = Friendships.remove_friend(caller_scope2, friendship.id)
      assert_push "call_ended", ended
      assert ended.call.call_id == ringing2.call_id
      assert ended.call.terminal_outcome == :relationship_ended
      assert ended.signaling_session_id == ended_join.signaling_session_id
      refute_push "call_relationship_ended", _payload
      assert_receive {:DOWN, ^ended_ref, :process, ^ended_pid, ended_reason}
      assert ended_reason == {:shutdown, :relationship_ended}

      assert {:error, %{reason: "not_found"}} =
               subscribe_and_join(
                 connect_calls_socket(caller_scope2.user).socket,
                 call_topic(ringing2.call_id)
               )

      {caller_scope3, _recipient_scope3, ringing3} = start_ringing_call("c04_interrupt")
      %{socket: interrupt_socket} = connect_calls_socket(caller_scope3.user)

      assert {:ok, interrupt_join, _channel} =
               subscribe_and_join(interrupt_socket, call_topic(ringing3.call_id))

      now = DateTime.utc_now(:microsecond)

      Repo.get!(CallAttempt, ringing3.call_id)
      |> Ecto.Changeset.change(%{state: :connecting, accepted_at: now})
      |> Repo.update!()

      restart_calls_runtime()

      assert_push "call_ended", interrupted
      assert interrupted.call.call_id == ringing3.call_id
      assert interrupted.call.terminal_outcome == :interrupted
      assert interrupted.signaling_session_id == interrupt_join.signaling_session_id
      refute_push "call_interrupted", _payload
    end

    test "leaving inbox or Call topic and closing a Channel does not cancel a ringing attempt" do
      {caller_scope, recipient_scope, started} = start_ringing_call("c04_leave")
      voice_channel_id = Ecto.UUID.generate()

      assert {:ok, %{voice_session_id: voice_session_id}} =
               Voice.join(voice_channel_id, caller_scope.user.id, "c04-leave-voice", self())

      %{socket: caller_socket} = connect_calls_socket(caller_scope.user)
      %{socket: recipient_socket} = connect_calls_socket(recipient_scope.user)

      assert {:ok, _inbox, inbox_channel} = subscribe_and_join(caller_socket, @inbox_topic)

      assert {:ok, _call, call_channel} =
               subscribe_and_join(caller_socket, call_topic(started.call_id))

      assert {:ok, _recipient, recipient_channel} =
               subscribe_and_join(recipient_socket, call_topic(started.call_id))

      Process.unlink(inbox_channel.channel_pid)
      assert_reply leave(inbox_channel), :ok

      Process.unlink(call_channel.channel_pid)
      assert_reply leave(call_channel), :ok

      Process.unlink(recipient_channel.channel_pid)
      close(recipient_channel)

      assert {:ok, still_ringing} = Calls.get_call(caller_scope, started.call_id)
      assert still_ringing.state == :ringing
      assert still_ringing.call_id == started.call_id

      assert {:ok, %{members: [%{user_id: caller_user_id}]}} =
               Voice.voice_channel_roster(voice_channel_id)

      assert caller_user_id == caller_scope.user.id
      assert :ok = Voice.leave(voice_channel_id, voice_session_id)
    end

    test "Socket transport teardown does not cancel a ringing attempt" do
      {caller_scope, _recipient_scope, started} = start_ringing_call("c04_sock")
      token = Accounts.generate_user_session_token(caller_scope.user)
      parent = self()
      topic = call_topic(started.call_id)

      transport_pid =
        start_supervised!(%{
          id: :socket_teardown_tab,
          restart: :temporary,
          start: {
            Task,
            :start_link,
            [
              fn ->
                {:ok, socket} =
                  Phoenix.ChannelTest.__connect__(
                    DiscordCloneWeb.Endpoint,
                    CallSocket,
                    %{},
                    connect_info: %{session: %{"user_token" => token}},
                    test_process: parent
                  )

                {:ok, _inbox_payload, inbox_channel} =
                  Phoenix.ChannelTest.subscribe_and_join(socket, @inbox_topic)

                {:ok, _call_payload, call_channel} =
                  Phoenix.ChannelTest.subscribe_and_join(socket, topic)

                send(parent, {:joined, self(), inbox_channel, call_channel})

                receive do
                  :stop -> :ok
                end
              end
            ]
          }
        })

      assert_receive {:joined, ^transport_pid, inbox_channel, call_channel}
      inbox_pid = inbox_channel.channel_pid
      call_pid = call_channel.channel_pid
      inbox_ref = Process.monitor(inbox_pid)
      call_ref = Process.monitor(call_pid)

      send(transport_pid, :stop)
      assert_receive {:DOWN, ^inbox_ref, :process, ^inbox_pid, _reason}
      assert_receive {:DOWN, ^call_ref, :process, ^call_pid, _reason}

      assert {:ok, still_ringing} = Calls.get_call(caller_scope, started.call_id)
      assert still_ringing.state == :ringing
      assert still_ringing.call_id == started.call_id
    end

    test "start_call and arbitrary event names stay unsupported on the Call topic" do
      {_caller_scope, recipient_scope, started} = start_ringing_call("c04_unsup")
      %{socket: socket} = connect_calls_socket(recipient_scope.user)
      assert {:ok, _payload, channel} = subscribe_and_join(socket, call_topic(started.call_id))

      for event <- ["start_call", "SENTINEL_EVENT_NAME"] do
        assert_reply push(channel, event, %{"secret" => "nested-payload"}), :error, %{
          reason: "unsupported_event"
        }
      end

      assert {:ok, still_ringing} = Calls.get_call(recipient_scope, started.call_id)
      assert still_ringing.state == :ringing
    end
  end

  describe "accept and leave" do
    test "recipient audio accept then either participant leave projects connecting then ended" do
      {caller_scope, recipient_scope, started} = start_ringing_call("c03_accept")
      %{socket: caller_socket} = connect_calls_socket(caller_scope.user)
      %{socket: recipient_socket} = connect_calls_socket(recipient_scope.user)

      assert {:ok, _caller_payload, caller} =
               subscribe_and_join(caller_socket, call_topic(started.call_id))

      assert {:ok, _recipient_payload, recipient} =
               subscribe_and_join(recipient_socket, call_topic(started.call_id))

      assert_reply push(caller, "accept_call", accept_payload(caller)), :error, %{
        reason: "not_found"
      }

      assert_reply push(recipient, "leave_call", command_payload(recipient)), :error, %{
        reason: "stale"
      }

      assert_reply push(recipient, "accept_call", accept_payload(recipient)), :ok, %{
        call: connecting
      }

      assert connecting.state == :connecting
      assert connecting.role == :recipient
      assert connecting.peer.id == caller_scope.user.id
      _ = flush_optional_call_server(started.call_id)

      assert_reply push(caller, "leave_call", command_payload(caller)), :ok, %{call: left}
      assert left.state == :terminal
      assert left.terminal_outcome in [:cancelled, :ended]
    end

    test "video invitation accepts video or audio fallback with exact projected mode" do
      for {suffix, wire_mode, answer_mode} <- [
            {"video", "video", :video},
            {"audio", "audio", :audio}
          ] do
        {caller_scope, recipient_scope, started} =
          start_ringing_call("c04_video_#{suffix}", :video)

        %{socket: recipient_socket} = connect_calls_socket(recipient_scope.user)

        assert {:ok, _recipient_payload, recipient} =
                 subscribe_and_join(recipient_socket, call_topic(started.call_id))

        with_accepted_runtime(:held, fn ->
          assert_reply(
            push(
              recipient,
              "accept_call",
              accept_payload(recipient, %{"answer_mode" => wire_mode})
            ),
            :ok,
            %{call: connecting}
          )

          assert connecting.state == :connecting
          assert connecting.role == :recipient
          assert connecting.peer.id == caller_scope.user.id
          assert connecting.media_intent == :video
          assert connecting.answer_mode == answer_mode
          assert Repo.get!(CallAttempt, started.call_id).media_intent == :video
        end)
      end
    end

    test "participant inboxes and sibling Call topics receive connecting, active, and terminal without outsider leakage" do
      {caller_scope, recipient_scope, started} = start_ringing_call("c03_multi")
      outsider_scope = user_scope_fixture(user_fixture(username: "c03_multi_out"))
      caller_token = Accounts.generate_user_session_token(caller_scope.user)
      recipient_token = Accounts.generate_user_session_token(recipient_scope.user)
      outsider_token = Accounts.generate_user_session_token(outsider_scope.user)

      tabs = [
        {:caller_inbox, caller_token, :inbox},
        {:caller_call_one, caller_token, :call},
        {:caller_call_two, caller_token, :call},
        {:recipient_inbox, recipient_token, :inbox},
        {:recipient_call_one, recipient_token, :call},
        {:recipient_call_two, recipient_token, :call},
        {:outsider_inbox, outsider_token, :inbox}
      ]

      Enum.each(tabs, fn
        {tag, token, :inbox} -> start_inbox_tab(token, tag)
        {tag, token, :call} -> start_call_tab(token, tag, started.call_id)
      end)

      joined = Map.new(tabs, fn {tag, _token, _kind} -> {tag, await_joined(tag)} end)

      {:joined, :recipient_call_one, recipient_pid, recipient_join, _channel} =
        joined.recipient_call_one

      send_command(recipient_pid, "accept_call", %{
        "signaling_session_id" => recipient_join.signaling_session_id,
        "call_id" => started.call_id,
        "answer_mode" => "audio"
      })

      assert {:ok, %{call: %{state: :connecting}}} = await_reply(:recipient_call_one)

      for tag <- [
            :caller_inbox,
            :caller_call_one,
            :caller_call_two,
            :recipient_inbox,
            :recipient_call_two
          ] do
        assert %{call: %{state: :connecting, call_id: call_id}} =
                 await_tab_push(tag, "call_connecting")

        assert call_id == started.call_id
      end

      for tag <- [
            :caller_inbox,
            :caller_call_one,
            :caller_call_two,
            :recipient_inbox,
            :recipient_call_one,
            :recipient_call_two
          ] do
        assert %{call: %{state: :active, call_id: call_id}} = await_tab_push(tag, "call_active")
        assert call_id == started.call_id
      end

      {:joined, :caller_call_one, caller_pid, caller_join, _channel} = joined.caller_call_one

      send_command(caller_pid, "leave_call", %{
        "signaling_session_id" => caller_join.signaling_session_id,
        "call_id" => started.call_id
      })

      assert {:ok, %{call: %{state: :terminal, terminal_outcome: :ended}}} =
               await_reply(:caller_call_one)

      for tag <- [
            :caller_inbox,
            :caller_call_two,
            :recipient_inbox,
            :recipient_call_one,
            :recipient_call_two
          ] do
        assert %{call: %{state: :terminal, terminal_outcome: :ended}} =
                 await_tab_push(tag, "call_ended")
      end

      {:joined, :outsider_inbox, outsider_pid, _payload, _channel} = joined.outsider_inbox
      send(outsider_pid, {:sync, self()})
      assert_receive {:sync, :outsider_inbox}
      refute_received {:push, :outsider_inbox, _event, _payload}
    end

    test "runtime failure reaches both participant inboxes and sibling Call topics" do
      with_accepted_runtime(:failed_capacity, fn ->
        {caller_scope, recipient_scope, started} = start_ringing_call("c03_error")
        caller_token = Accounts.generate_user_session_token(caller_scope.user)
        recipient_token = Accounts.generate_user_session_token(recipient_scope.user)

        start_inbox_tab(caller_token, :error_caller_inbox)
        start_call_tab(caller_token, :error_caller_call, started.call_id)
        start_inbox_tab(recipient_token, :error_recipient_inbox)
        start_call_tab(recipient_token, :error_recipient_call, started.call_id)

        _caller_inbox = await_joined(:error_caller_inbox)
        _caller_call = await_joined(:error_caller_call)
        _recipient_inbox = await_joined(:error_recipient_inbox)

        assert {:joined, :error_recipient_call, recipient_pid, recipient_join, _channel} =
                 await_joined(:error_recipient_call)

        send_command(recipient_pid, "accept_call", %{
          "signaling_session_id" => recipient_join.signaling_session_id,
          "call_id" => started.call_id,
          "answer_mode" => "audio"
        })

        assert {:ok, %{call: %{state: :connecting}}} = await_reply(:error_recipient_call)

        for tag <- [
              :error_caller_inbox,
              :error_caller_call,
              :error_recipient_inbox,
              :error_recipient_call
            ] do
          assert %{call: %{state: :terminal, terminal_outcome: :failed_capacity}} =
                   await_tab_push(tag, "call_error")
        end
      end)
    end
  end

  describe "owner tabs" do
    test "ringing ownership projects self, elsewhere, and unclaimed for each receiving connection" do
      owned = start_ringing_call_owned("c05_ring")

      %{socket: caller_socket} = connect_calls_socket(owned.caller_scope.user)
      caller_connection_id = caller_socket.assigns.connection_id

      assert {:ok, caller_payload, _caller_channel} =
               subscribe_and_join(owned.caller_socket, call_topic(owned.started.call_id))

      assert caller_payload.call.ownership == :self
      assert caller_payload.call.role == :caller

      assert {:ok, sibling_payload, _sibling_channel} =
               subscribe_and_join(caller_socket, call_topic(owned.started.call_id))

      assert sibling_payload.call.ownership == :elsewhere
      refute Map.has_key?(sibling_payload.call, :connection_id)
      refute Map.has_key?(sibling_payload.call, :call_connection_id)
      refute inspect(sibling_payload) =~ caller_connection_id

      assert {:ok, recipient_payload, _recipient_channel} =
               subscribe_and_join(
                 connect_calls_socket(owned.recipient_scope.user).socket,
                 call_topic(owned.started.call_id)
               )

      assert recipient_payload.call.ownership == :unclaimed
      assert recipient_payload.call.state == :ringing
      refute Map.has_key?(recipient_payload.call, :connection_id)
    end

    test "joining registers the connection without accepting or mutating the attempt" do
      owned = start_ringing_call_owned("c05_join_obs")
      attempts_before = attempt_state(owned.started.call_id)

      assert {:ok, payload, _channel} =
               subscribe_and_join(owned.caller_socket, call_topic(owned.started.call_id))

      assert payload.call.ownership == :self
      assert registered_connections(owned.started.call_id) == [owned.caller_connection_id]
      assert CallServer.answer_mode(owned.started.call_id) == nil
      assert attempt_state(owned.started.call_id) == attempts_before
    end

    test "the first accepting connection wins and sibling tabs learn promptly" do
      owned = start_ringing_call_owned("c05_winner")
      recipient_token = Accounts.generate_user_session_token(owned.recipient_scope.user)

      assert {:ok, _caller_payload, _caller_channel} =
               subscribe_and_join(owned.caller_socket, call_topic(owned.started.call_id))

      start_call_tab(recipient_token, :winner_recipient, owned.started.call_id)
      start_call_tab(recipient_token, :winner_sibling, owned.started.call_id)

      {:joined, :winner_recipient, recipient_pid, recipient_join, _ch} =
        await_joined(:winner_recipient)

      {:joined, :winner_sibling, sibling_pid, _sibling_join, _ch} = await_joined(:winner_sibling)

      with_accepted_runtime(:held, fn ->
        send_command(recipient_pid, "accept_call", %{
          "signaling_session_id" => recipient_join.signaling_session_id,
          "call_id" => owned.started.call_id,
          "answer_mode" => "audio"
        })

        assert {:ok,
                %{
                  call: %{
                    state: :connecting,
                    ownership: :self,
                    answer_mode: :audio,
                    role: :recipient
                  }
                }} = await_reply(:winner_recipient)

        assert %{call: %{state: :connecting, ownership: :elsewhere}} =
                 await_tab_push(:winner_sibling, "call_connecting")

        assert %{call: %{state: :connecting, ownership: :elsewhere}} =
                 await_tab_push(:winner_sibling, "sibling_tab_owns_call")

        send(sibling_pid, {:sync, self()})
        assert_receive {:sync, :winner_sibling}

        # The winning caller tab keeps self and receives no sibling prompt.
        assert_push "call_connecting", %{call: %{state: :connecting, ownership: :self}}
        refute_push "sibling_tab_owns_call", _payload
      end)
    end

    test "a sibling accept cannot replace the winner or the committed Answer Mode" do
      owned = start_ringing_call_owned("c05_loser", :video)
      recipient_token = Accounts.generate_user_session_token(owned.recipient_scope.user)

      start_call_tab(recipient_token, :loser_recipient, owned.started.call_id)
      start_call_tab(recipient_token, :loser_sibling, owned.started.call_id)

      {:joined, :loser_recipient, recipient_pid, recipient_join, recipient_channel} =
        await_joined(:loser_recipient)

      {:joined, :loser_sibling, sibling_pid, sibling_join, _ch} = await_joined(:loser_sibling)

      with_accepted_runtime(:held, fn ->
        send_command(recipient_pid, "accept_call", %{
          "signaling_session_id" => recipient_join.signaling_session_id,
          "call_id" => owned.started.call_id,
          "answer_mode" => "video"
        })

        assert {:ok, %{call: %{state: :connecting, answer_mode: :video, ownership: :self}}} =
                 await_reply(:loser_recipient)

        _ = await_tab_push(:loser_sibling, "call_connecting")

        accepted_at = Repo.get!(CallAttempt, owned.started.call_id).accepted_at

        send_command(sibling_pid, "accept_call", %{
          "signaling_session_id" => sibling_join.signaling_session_id,
          "call_id" => owned.started.call_id,
          "answer_mode" => "audio"
        })

        assert {:ok,
                %{
                  call: %{
                    state: :connecting,
                    answer_mode: :video,
                    ownership: :elsewhere,
                    media_intent: :video
                  }
                }} = await_reply(:loser_sibling)

        assert Repo.get!(CallAttempt, owned.started.call_id).accepted_at == accepted_at
        assert CallServer.answer_mode(owned.started.call_id) == :video

        assert winner_connection_id(owned.started.call_id, :recipient) ==
                 recipient_channel.assigns.connection_id
      end)
    end

    test "a losing tab keeps its projection when the winner disconnects without takeover" do
      owned = start_ringing_call_owned("c05_disconnect")
      recipient_token = Accounts.generate_user_session_token(owned.recipient_scope.user)

      start_call_tab(recipient_token, :gone_recipient, owned.started.call_id)
      start_call_tab(recipient_token, :stayed_sibling, owned.started.call_id)

      {:joined, :gone_recipient, recipient_pid, recipient_join, recipient_channel} =
        await_joined(:gone_recipient)

      {:joined, :stayed_sibling, sibling_pid, _sibling_join, _ch} =
        await_joined(:stayed_sibling)

      with_accepted_runtime(:held, fn ->
        send_command(recipient_pid, "accept_call", %{
          "signaling_session_id" => recipient_join.signaling_session_id,
          "call_id" => owned.started.call_id,
          "answer_mode" => "audio"
        })

        assert {:ok, %{call: %{ownership: :self}}} = await_reply(:gone_recipient)

        assert %{call: %{ownership: :elsewhere}} =
                 await_tab_push(:stayed_sibling, "call_connecting")

        Process.unlink(recipient_channel.channel_pid)
        Process.exit(recipient_channel.channel_pid, :kill)

        assert %{call: %{state: :connecting, ownership: :unclaimed}} =
                 await_tab_push(:stayed_sibling, "call_connecting")

        # Ownership-only change is delivered exactly once, and a repeated
        # durable broadcast cannot revive or transfer the role.
        send(sibling_pid, {:sync, self()})
        assert_receive {:sync, :stayed_sibling}
        refute_received {:push, :stayed_sibling, "call_connecting", _payload}

        assert winner_connection_id(owned.started.call_id, :recipient) == nil

        assert {:ok, rejoin, _channel} =
                 subscribe_and_join(
                   connect_calls_socket(owned.recipient_scope.user).socket,
                   call_topic(owned.started.call_id)
                 )

        assert rejoin.call.ownership == :unclaimed
        assert rejoin.call.state == :connecting
      end)
    end

    test "a recipient Call topic that re-registers before accepting wins its fresh acceptance" do
      {_caller_scope, recipient_scope, started} = start_ringing_call("c05_recipient_rejoin")
      %{socket: socket} = connect_calls_socket(recipient_scope.user)

      assert {:ok, %{call: %{state: :ringing, ownership: :unclaimed}}, first_channel} =
               subscribe_and_join(socket, call_topic(started.call_id))

      Process.unlink(first_channel.channel_pid)
      ref = Process.monitor(first_channel.channel_pid)
      leave(first_channel)
      assert_receive {:DOWN, ^ref, :process, _pid, {:shutdown, :left}}

      assert {:ok, %{call: %{state: :ringing, ownership: :unclaimed}}, rejoined_channel} =
               subscribe_and_join(socket, call_topic(started.call_id))

      with_accepted_runtime(:held, fn ->
        assert_reply push(rejoined_channel, "accept_call", accept_payload(rejoined_channel)),
                     :ok,
                     %{call: %{state: :connecting, ownership: :self, role: :recipient}}
      end)
    end

    test "caller ownership falls back to the earliest registered caller tab" do
      owned = start_ringing_call_owned("c05_caller_fallback")
      caller_token = Accounts.generate_user_session_token(owned.caller_scope.user)
      recipient_token = Accounts.generate_user_session_token(owned.recipient_scope.user)

      start_call_tab(caller_token, :fallback_first, owned.started.call_id)
      {:joined, :fallback_first, first_pid, first_join, _ch} = await_joined(:fallback_first)

      start_call_tab(caller_token, :fallback_second, owned.started.call_id)
      assert {:joined, :fallback_second, _pid, _join, _ch} = await_joined(:fallback_second)

      start_call_tab(recipient_token, :fallback_recipient, owned.started.call_id)

      {:joined, :fallback_recipient, recipient_pid, recipient_join, _ch} =
        await_joined(:fallback_recipient)

      with_accepted_runtime(:held, fn ->
        send_command(recipient_pid, "accept_call", %{
          "signaling_session_id" => recipient_join.signaling_session_id,
          "call_id" => owned.started.call_id,
          "answer_mode" => "audio"
        })

        assert {:ok, %{call: %{ownership: :self}}} = await_reply(:fallback_recipient)
        assert %{call: %{ownership: :self}} = await_tab_push(:fallback_first, "call_connecting")

        assert %{call: %{ownership: :elsewhere}} =
                 await_tab_push(:fallback_second, "call_connecting")

        # The preferred start connection never joined, so it is not the winner.
        %{socket: preferred_socket} = connect_calls_socket(owned.caller_scope.user)

        assert {:ok, preferred, _channel} =
                 subscribe_and_join(preferred_socket, call_topic(owned.started.call_id))

        assert preferred.call.ownership == :elsewhere

        # A caller takeover attempt is a leave/cancel command, not an ownership claim.
        send_command(first_pid, "leave_call", %{
          "signaling_session_id" => first_join.signaling_session_id,
          "call_id" => owned.started.call_id
        })

        assert {:ok, %{call: %{state: :terminal}}} = await_reply(:fallback_first)
      end)
    end

    test "accept and leave reject forged owner, tab, and connection fields without mutation" do
      {_caller_scope, recipient_scope, started} = start_ringing_call("c05_forged")
      %{socket: socket} = connect_calls_socket(recipient_scope.user)

      assert {:ok, _payload, channel} = subscribe_and_join(socket, call_topic(started.call_id))
      attempts_before = attempt_state(started.call_id)

      for field <- ["owner", "tab_id", "connection_id", "call_connection_id", "role"] do
        assert_reply(
          push(channel, "accept_call", accept_payload(channel, %{field => "forged"})),
          :error,
          %{reason: "invalid_request"}
        )

        assert_reply(
          push(channel, "leave_call", command_payload(channel, %{field => "forged"})),
          :error,
          %{reason: "invalid_request"}
        )
      end

      assert attempt_state(started.call_id) == attempts_before
      assert CallServer.answer_mode(started.call_id) == nil
    end

    test "terminal projections carry no ownership field" do
      {caller_scope, recipient_scope, started} = start_ringing_call("c05_term_own")
      %{socket: caller_socket} = connect_calls_socket(caller_scope.user)

      assert {:ok, _payload, _channel} =
               subscribe_and_join(caller_socket, call_topic(started.call_id))

      assert {:ok, _} = Calls.decline_call(recipient_scope, started.call_id)
      assert_push "call_declined", %{call: declined}
      refute Map.has_key?(declined, :ownership)
    end
  end

  describe "reserved events" do
    test "malformed accept and leave envelopes are invalid without mutating ringing" do
      {caller_scope, recipient_scope, started} = start_ringing_call("c06_accept")
      %{socket: caller_socket} = connect_calls_socket(caller_scope.user)
      %{socket: recipient_socket} = connect_calls_socket(recipient_scope.user)

      assert {:ok, _caller_payload, caller} =
               subscribe_and_join(caller_socket, call_topic(started.call_id))

      assert {:ok, _recipient_payload, recipient} =
               subscribe_and_join(recipient_socket, call_topic(started.call_id))

      assert_reply push(recipient, "accept_call", reserved_control_payload(recipient)), :error, %{
        reason: "invalid_request"
      }

      assert_reply push(caller, "leave_call", reserved_control_payload(caller)), :error, %{
        reason: "stale"
      }

      assert {:ok, still_ringing} = Calls.get_call(recipient_scope, started.call_id)
      assert still_ringing.state == :ringing
    end

    test "well-formed media events receive not_admitted for arbitrary Call Session identities" do
      {_caller_scope, recipient_scope, started} = start_ringing_call("c06_media")
      %{socket: socket} = connect_calls_socket(recipient_scope.user)
      assert {:ok, _payload, channel} = subscribe_and_join(socket, call_topic(started.call_id))

      for {event, payload} <- reserved_media_payloads(channel) do
        assert_reply push(channel, event, payload), :error, %{reason: "not_admitted"}
      end
    end

    test "malformed, extra, over-limit, and forged current-identity requests receive invalid_request" do
      {_caller_scope, recipient_scope, started} = start_ringing_call("c06_invalid")
      %{socket: socket} = connect_calls_socket(recipient_scope.user)
      assert {:ok, _payload, channel} = subscribe_and_join(socket, call_topic(started.call_id))
      valid = reserved_control_payload(channel)

      assert_reply push(channel, "accept_call", %{"secret" => "nested-payload"}), :error, %{
        reason: "invalid_request"
      }

      assert_reply push(channel, "leave_call", Map.put(valid, "role", "recipient")), :error, %{
        reason: "invalid_request"
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

      assert_reply push(
                     channel,
                     "offer",
                     reserved_offer_payload(channel, %{
                       "description" => %{
                         "type" => "offer",
                         "sdp" => String.duplicate("a", 64 * 1024 + 1)
                       }
                     })
                   ),
                   :error,
                   %{reason: "invalid_request"}
    end

    test "a terminal Call topic rejects reserved events without rewriting its durable outcome" do
      {caller_scope, recipient_scope, started} = start_ringing_call("c06_term")
      assert {:ok, declined} = Calls.decline_call(recipient_scope, started.call_id)
      %{socket: socket} = connect_calls_socket(caller_scope.user)

      assert {:ok, _payload, channel} = subscribe_and_join(socket, call_topic(started.call_id))

      attempt_before = Repo.get!(CallAttempt, started.call_id)

      assert_reply push(channel, "accept_call", reserved_control_payload(channel)), :error, %{
        reason: "invalid_request"
      }

      assert_reply push(channel, "offer", reserved_offer_payload(channel)), :error, %{
        reason: "not_admitted"
      }

      attempt_after = Repo.get!(CallAttempt, started.call_id)
      assert attempt_after.state == :terminal
      assert attempt_after.terminal_outcome == :declined
      assert attempt_after.ended_at == declined.ended_at
      assert attempt_after.updated_at == attempt_before.updated_at
    end

    test "reserved events leave Call Attempt, Activity, Voice, and Channel assigns unchanged" do
      {caller_scope, recipient_scope, started} = start_ringing_call("c06_side")
      voice_channel_id = Ecto.UUID.generate()

      assert {:ok, %{voice_session_id: voice_session_id}} =
               Voice.join(voice_channel_id, caller_scope.user.id, "c06-side-voice", self())

      %{socket: socket} = connect_calls_socket(recipient_scope.user)
      assert {:ok, _payload, channel} = subscribe_and_join(socket, call_topic(started.call_id))

      attempt_before = Repo.get!(CallAttempt, started.call_id)
      activity_before = Repo.aggregate(ActivityItem, :count)
      messages_before = Repo.aggregate(Message, :count)
      occupancy_before = Registry.count(DiscordClone.Calls.CallRegistry)
      running_before = MapSet.new(ExWebRTC.PeerConnection.get_all_running())
      assigns_before = reviewed_assigns(channel)

      matrix =
        [
          {"accept_call", reserved_control_payload(channel)},
          {"leave_call", reserved_control_payload(channel)}
        ] ++
          reserved_media_payloads(channel) ++
          [
            {"offer", reserved_offer_payload(channel)},
            {"ice_candidate", reserved_ice_candidate_payload(channel)}
          ]

      for {event, payload} <- matrix do
        assert_reply push(channel, event, payload), :error, %{reason: _}
      end

      _ = :sys.get_state(channel.channel_pid)

      attempt_after = Repo.get!(CallAttempt, started.call_id)
      assert attempt_after.state == attempt_before.state
      assert attempt_after.ringing_deadline_at == attempt_before.ringing_deadline_at
      assert attempt_after.inserted_at == attempt_before.inserted_at
      assert attempt_after.updated_at == attempt_before.updated_at
      assert attempt_after.terminal_outcome == attempt_before.terminal_outcome
      assert attempt_after.ended_at == attempt_before.ended_at
      assert attempt_after.accepted_at == attempt_before.accepted_at
      assert Repo.aggregate(ActivityItem, :count) == activity_before
      assert Repo.aggregate(Message, :count) == messages_before
      assert Registry.count(DiscordClone.Calls.CallRegistry) == occupancy_before
      assert reviewed_assigns(channel) == assigns_before
      assert retained_media_assigns(channel) == %{}

      assert {:ok, %{members: [%{user_id: caller_user_id}]}} =
               Voice.voice_channel_roster(voice_channel_id)

      assert caller_user_id == caller_scope.user.id
      assert :ok = Voice.leave(voice_channel_id, voice_session_id)

      assert ExWebRTC.PeerConnection.get_all_running()
             |> MapSet.new()
             |> MapSet.difference(running_before)
             |> MapSet.size() == 0
    end

    test "the Call topic remains usable for decline after rejected reserved requests" do
      {_caller_scope, recipient_scope, started} = start_ringing_call("c06_decline")
      %{socket: socket} = connect_calls_socket(recipient_scope.user)
      assert {:ok, payload, channel} = subscribe_and_join(socket, call_topic(started.call_id))

      assert_reply push(channel, "offer", reserved_offer_payload(channel, %{"extra" => true})),
                   :error,
                   %{reason: "invalid_request"}

      assert_reply push(channel, "accept_call", reserved_control_payload(channel)), :error, %{
        reason: "invalid_request"
      }

      assert_reply push(channel, "decline_call", command_payload(channel)), :ok, %{
        signaling_session_id: signaling_session_id,
        call: declined
      }

      assert signaling_session_id == payload.signaling_session_id
      assert declined.state == :terminal
      assert declined.terminal_outcome == :declined
    end
  end

  defp start_ringing_call(suffix, media_intent \\ :audio) do
    {caller_scope, recipient_scope, started, _friendship} =
      start_ringing_call_with_friendship(suffix, media_intent)

    {caller_scope, recipient_scope, started}
  end

  defp start_ringing_call_with_friendship(suffix, media_intent \\ :audio) do
    {caller_scope, recipient_scope, direct_conversation, friendship} =
      direct_conversation_fixture(suffix)

    assert {:ok, %{call: started, started?: true}} =
             Calls.start_call(caller_scope, direct_conversation.id, media_intent)

    {caller_scope, recipient_scope, started, friendship}
  end

  defp start_ringing_call_owned(suffix, media_intent \\ :audio) do
    {caller_scope, recipient_scope, direct_conversation, _friendship} =
      direct_conversation_fixture(suffix)

    %{socket: caller_socket} = connect_calls_socket(caller_scope.user)
    caller_connection_id = caller_socket.assigns.connection_id

    assert {:ok, %{call: started, started?: true}} =
             Calls.start_call(caller_scope, direct_conversation.id, media_intent,
               caller_connection_id: caller_connection_id
             )

    %{
      caller_scope: caller_scope,
      recipient_scope: recipient_scope,
      caller_socket: caller_socket,
      caller_connection_id: caller_connection_id,
      started: started
    }
  end

  defp registered_connections(call_id) do
    call_id
    |> call_server_state()
    |> Map.fetch!(:registrations)
    |> Map.keys()
    |> Enum.sort()
  end

  defp winner_connection_id(call_id, role) do
    state = call_server_state(call_id)

    case role do
      :caller -> state.caller_winner
      :recipient -> state.recipient_winner
    end
  end

  defp call_server_state(call_id) do
    [{pid, _value}] = Registry.lookup(DiscordClone.Calls.CallRegistry, call_id)
    :sys.get_state(pid)
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
            {:ok, socket} =
              Phoenix.ChannelTest.__connect__(
                DiscordCloneWeb.Endpoint,
                CallSocket,
                %{},
                connect_info: %{session: %{"user_token" => token}},
                test_process: parent
              )

            {:ok, payload, channel} =
              Phoenix.ChannelTest.subscribe_and_join(socket, topic)

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

  defp command_payload(channel, overrides \\ %{}) do
    Map.merge(
      %{
        "signaling_session_id" => channel.assigns.signaling_session_id,
        "call_id" => channel.assigns.call_id
      },
      overrides
    )
  end

  defp accept_payload(channel, overrides \\ %{}) do
    command_payload(channel, Map.merge(%{"answer_mode" => "audio"}, overrides))
  end

  defp flush_optional_call_server(call_id) do
    case Registry.lookup(DiscordClone.Calls.CallRegistry, call_id) do
      [{pid, _}] -> _ = :sys.get_state(pid)
      [] -> :ok
    end
  catch
    :exit, _reason -> :ok
  end

  defp with_accepted_runtime(result, fun) do
    previous_runtime = Application.get_env(:discord_clone, :accepted_call_runtime)
    previous_result = Application.get_env(:discord_clone, :accepted_call_runtime_result)
    Application.put_env(:discord_clone, :accepted_call_runtime, ScriptedAcceptedCallRuntime)
    Application.put_env(:discord_clone, :accepted_call_runtime_result, result)

    try do
      fun.()
    after
      restore_env(:accepted_call_runtime, previous_runtime)
      restore_env(:accepted_call_runtime_result, previous_result)
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:discord_clone, key)
  defp restore_env(key, value), do: Application.put_env(:discord_clone, key, value)

  defp reserved_control_payload(channel, overrides \\ %{}) do
    command_payload(channel, overrides)
  end

  defp reserved_media_base(channel, overrides) do
    Map.merge(
      %{
        "signaling_session_id" => channel.assigns.signaling_session_id,
        "call_id" => channel.assigns.call_id,
        "call_session_id" => "opaque-call-session"
      },
      overrides
    )
  end

  defp reserved_offer_payload(channel, overrides \\ %{}) do
    reserved_media_base(
      channel,
      Map.merge(
        %{
          "negotiation_id" => "opaque-negotiation",
          "description" => %{"type" => "offer", "sdp" => "v=0"}
        },
        overrides
      )
    )
  end

  defp reserved_ice_candidate_payload(channel, overrides \\ %{}) do
    reserved_media_base(
      channel,
      Map.merge(
        %{
          "negotiation_id" => "opaque-negotiation",
          "candidate" => %{
            "candidate" => "candidate:1 1 udp 1 127.0.0.1 9 typ host",
            "sdpMid" => "0",
            "sdpMLineIndex" => 0,
            "usernameFragment" => nil
          }
        },
        overrides
      )
    )
  end

  defp reserved_media_payloads(channel) do
    [
      {"offer", reserved_offer_payload(channel)},
      {"ice_candidate", reserved_ice_candidate_payload(channel)},
      {"ice_candidate",
       reserved_media_base(channel, %{
         "negotiation_id" => "opaque-negotiation",
         "end_of_candidates" => true
       })},
      {"ice_route",
       reserved_media_base(channel, %{
         "route_category" => "host_direct",
         "protocol" => "udp",
         "duration_ms" => 12
       })},
      {"renew", reserved_media_base(channel, %{})},
      {"local_media_state",
       reserved_media_base(channel, %{
         "media_state_version" => 1,
         "camera_enabled" => true,
         "microphone_muted" => false,
         "negotiation_id" => "opaque-negotiation"
       })}
    ]
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

  defp padded_payload(payload, size) do
    probe = Map.put(payload, "pad", "")
    pad_size = size - byte_size(Jason.encode!(probe))
    padded = Map.put(payload, "pad", String.duplicate("x", pad_size))
    assert byte_size(Jason.encode!(padded)) == size
    padded
  end

  defp expected_wire_call_keys(call) do
    (Calls.projection_keys() ++ [:answer_mode, :ownership])
    |> Enum.filter(&Map.has_key?(call, &1))
    |> Kernel.++([:peer, :role])
    |> Enum.sort()
  end

  defp attempt_state(call_id) do
    attempt = Repo.get!(CallAttempt, call_id)
    {attempt.state, attempt.terminal_outcome, attempt.updated_at}
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
