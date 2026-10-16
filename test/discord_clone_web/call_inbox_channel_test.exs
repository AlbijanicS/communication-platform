defmodule DiscordCloneWeb.CallInboxChannelTest do
  use DiscordClone.DataCase, async: false

  import DiscordClone.AccountsFixtures
  import DiscordClone.CallsFixtures
  import Phoenix.ChannelTest

  alias DiscordClone.Accounts
  alias DiscordClone.Activities.ActivityItem
  alias DiscordClone.Calls
  alias DiscordClone.Calls.{CallAttempt, ScriptedAcceptedCallRuntime}
  alias DiscordClone.Chat
  alias DiscordClone.Friendships
  alias DiscordClone.Repo
  alias DiscordClone.Voice
  alias DiscordCloneWeb.{CallInboxChannel, CallSignaling, CallSocket}

  @endpoint DiscordCloneWeb.Endpoint
  @inbox_topic CallSignaling.inbox_topic()

  setup do
    start_supervised!(DiscordClone.Calls.Supervisor)
    DiscordClone.Calls.CallCoordinator.begin_recovery()
    await_recovery_finished()
    :ok
  end

  describe "join" do
    test "returns an empty snapshot and a fresh Signaling Session ID" do
      %{socket: socket} = connect_calls_socket()

      assert {:ok, payload, _channel} = subscribe_and_join(socket, @inbox_topic)

      assert %{signaling_session_id: signaling_session_id, call: nil} = payload
      assert {:ok, _} = Ecto.UUID.cast(signaling_session_id)
      assert Map.keys(payload) |> Enum.sort() == [:call, :signaling_session_id]
    end

    test "returns the existing ringing invitation with a role for each participant" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("inbox_join")

      assert {:ok, %{call: started, started?: true}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      %{socket: caller_socket} = connect_calls_socket(caller_scope.user)
      %{socket: recipient_socket} = connect_calls_socket(recipient_scope.user)

      assert {:ok, caller_payload, _caller_channel} =
               subscribe_and_join(caller_socket, @inbox_topic)

      assert {:ok, recipient_payload, _recipient_channel} =
               subscribe_and_join(recipient_socket, @inbox_topic)

      assert caller_payload.call.role == :caller
      assert recipient_payload.call.role == :recipient
      assert caller_payload.call.call_id == started.call_id
      assert recipient_payload.call.call_id == started.call_id
      assert caller_payload.call.state == :ringing
      assert caller_payload.call.ringing_deadline_at == started.ringing_deadline_at
      refute caller_payload.signaling_session_id == recipient_payload.signaling_session_id
    end

    test "issues a new Signaling Session ID on each tab and rejoin" do
      %{socket: socket, token: token} = connect_calls_socket()

      assert {:ok, first, first_channel} = subscribe_and_join(socket, @inbox_topic)
      Process.unlink(first_channel.channel_pid)
      ref = leave(first_channel)
      assert_reply ref, :ok

      assert {:ok, second, _second_channel} = subscribe_and_join(socket, @inbox_topic)

      other_socket = connect_authenticated_socket(token)
      assert {:ok, third, _third_channel} = subscribe_and_join(other_socket, @inbox_topic)

      ids = [
        first.signaling_session_id,
        second.signaling_session_id,
        third.signaling_session_id
      ]

      assert ids == Enum.uniq(ids)
    end

    test "fails closed when current-call discovery is unavailable" do
      stop_supervised!(DiscordClone.Calls.Supervisor)
      start_supervised!(DiscordClone.Calls.Supervisor)

      %{socket: socket} = connect_calls_socket()

      assert {:error, %{reason: "temporarily_unavailable"}} =
               subscribe_and_join(socket, @inbox_topic)
    end

    test "failed join does not emit accepted termination diagnostics" do
      test_process = self()
      handler_id = "inbox-terminate-#{System.unique_integer()}"

      :ok =
        :telemetry.attach(
          handler_id,
          [:discord_clone, :call_signaling, :operation],
          fn _event, _measurements, metadata, _config ->
            send(test_process, {:diagnostic, metadata})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      %{socket: socket, scope: scope} = connect_calls_socket()

      assert {:error, %{reason: "invalid_request"}} =
               subscribe_and_join(socket, @inbox_topic, %{"user_id" => scope.user.id})

      assert_receive {:diagnostic, %{operation: "join", outcome: :rejected}}
      refute_received {:diagnostic, %{operation: "termination"}}
    end

    test "rejects extra join fields and unknown topics" do
      %{socket: socket, scope: scope} = connect_calls_socket()

      assert {:error, %{reason: "invalid_request"}} =
               subscribe_and_join(socket, @inbox_topic, %{"user_id" => scope.user.id})

      assert {:error, %{reason: "invalid_request"}} =
               subscribe_and_join(socket, @inbox_topic, %{
                 "signaling_session_id" => "forged-signaling"
               })

      assert {:error, %{reason: "invalid_request"}} =
               subscribe_and_join(socket, CallInboxChannel, "call_inbox:#{scope.user.id}")

      assert {:error, %{reason: "invalid_request"}} =
               subscribe_and_join(socket, CallInboxChannel, "call:#{Ecto.UUID.generate()}")

      assert {:error, %{reason: "not_found"}} =
               subscribe_and_join(socket, "call:#{Ecto.UUID.generate()}")

      assert_raise RuntimeError, ~r/no channel found for topic/, fn ->
        subscribe_and_join(socket, "calls:#{Ecto.UUID.generate()}")
      end
    end
  end

  describe "live ringing delivery" do
    test "maps caller and recipient events after a start and isolates unrelated Users" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("inbox_live")

      outsider_scope = user_scope_fixture(user_fixture(username: "inbox_live_out"))
      caller_token = Accounts.generate_user_session_token(caller_scope.user)
      recipient_token = Accounts.generate_user_session_token(recipient_scope.user)
      outsider_token = Accounts.generate_user_session_token(outsider_scope.user)

      start_inbox_tab(caller_token, :caller_a)
      start_inbox_tab(caller_token, :caller_b)
      start_inbox_tab(recipient_token, :recipient_a)
      start_inbox_tab(recipient_token, :recipient_b)
      start_inbox_tab(outsider_token, :outsider)

      assert {:joined, :caller_a, _pid, %{call: nil}, _ch} = await_joined(:caller_a)
      assert {:joined, :caller_b, _pid, %{call: nil}, _ch} = await_joined(:caller_b)
      assert {:joined, :recipient_a, _pid, %{call: nil}, _ch} = await_joined(:recipient_a)
      assert {:joined, :recipient_b, _pid, %{call: nil}, _ch} = await_joined(:recipient_b)
      assert {:joined, :outsider, outsider_pid, %{call: nil}, _ch} = await_joined(:outsider)

      running_before = MapSet.new(ExWebRTC.PeerConnection.get_all_running())

      assert {:ok, %{call: started, started?: true}} =
               Calls.start_call(caller_scope, direct_conversation.id, :video)

      caller_a = await_tab_push(:caller_a, "outgoing_call_ringing")
      caller_b = await_tab_push(:caller_b, "outgoing_call_ringing")
      recipient_a = await_tab_push(:recipient_a, "incoming_call")
      recipient_b = await_tab_push(:recipient_b, "incoming_call")

      assert caller_a.call.call_id == started.call_id
      assert caller_a.call.role == :caller
      assert caller_b.call.role == :caller
      assert recipient_a.call.role == :recipient
      assert recipient_b.call.role == :recipient
      assert caller_a.call.media_intent == :video

      send(outsider_pid, {:sync, self()})
      assert_receive {:sync, :outsider}
      refute_received {:push, :outsider, _event, _payload}

      assert ExWebRTC.PeerConnection.get_all_running()
             |> MapSet.new()
             |> MapSet.difference(running_before)
             |> MapSet.size() == 0
    end

    test "does not re-push the join snapshot when the same ringing projection is republished" do
      {caller_scope, _recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("inbox_dup")

      assert {:ok, %{call: started, started?: true}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      %{socket: socket} = connect_calls_socket(caller_scope.user)
      assert {:ok, payload, _channel} = subscribe_and_join(socket, @inbox_topic)
      assert payload.call.call_id == started.call_id

      :ok = Calls.broadcast_ringing(started)
      refute_push "outgoing_call_ringing", _payload
      refute_push "incoming_call", _payload
    end
  end

  describe "terminal clearing and leave" do
    test "forwards decline, cancel, and timeout for the tracked Call ID" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("inbox_term")

      assert {:ok, %{call: started, started?: true}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      %{socket: caller_socket} = connect_calls_socket(caller_scope.user)
      %{socket: recipient_socket} = connect_calls_socket(recipient_scope.user)

      assert {:ok, _payload, caller_channel} = subscribe_and_join(caller_socket, @inbox_topic)

      assert {:ok, _payload, recipient_channel} =
               subscribe_and_join(recipient_socket, @inbox_topic)

      assert {:ok, _declined} = Calls.decline_call(recipient_scope, started.call_id)

      declined = collect_pushes("call_declined", 2)
      assert MapSet.new(Enum.map(declined, & &1.call.role)) == MapSet.new([:caller, :recipient])
      assert Enum.all?(declined, &(&1.call.call_id == started.call_id))
      assert Enum.all?(declined, &(&1.call.terminal_outcome == :declined))

      Process.unlink(caller_channel.channel_pid)
      Process.unlink(recipient_channel.channel_pid)
    end

    test "forwards cancel and timeout for the tracked Call ID" do
      {caller_scope, _recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("inbox_cancel")

      assert {:ok, %{call: started, started?: true}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      %{socket: caller_socket} = connect_calls_socket(caller_scope.user)
      assert {:ok, _payload, _channel} = subscribe_and_join(caller_socket, @inbox_topic)

      assert {:ok, _cancelled} = Calls.cancel_call(caller_scope, started.call_id)
      assert_push "call_cancelled", cancelled
      assert cancelled.call.call_id == started.call_id
      assert cancelled.call.terminal_outcome == :cancelled

      {caller_scope2, _recipient_scope2, direct_conversation2, _friendship2} =
        direct_conversation_fixture("inbox_timeout")

      assert {:ok, %{call: ringing, started?: true}} =
               Calls.start_call(caller_scope2, direct_conversation2.id, :audio)

      %{socket: timeout_socket} = connect_calls_socket(caller_scope2.user)
      assert {:ok, _payload, _channel} = subscribe_and_join(timeout_socket, @inbox_topic)

      make_ringing_deadline_due!(ringing.call_id)
      assert {:ok, _timed_out} = Calls.expire_ringing_attempt(ringing.call_id)
      assert_push "call_timed_out", timed_out
      assert timed_out.call.call_id == ringing.call_id
      assert timed_out.call.terminal_outcome == :timed_out
    end

    test "maps relationship end to call_ended and ignores a different Call ID" do
      {caller_scope, _recipient_scope, direct_conversation, friendship} =
        direct_conversation_fixture("inbox_ended")

      assert {:ok, %{call: started, started?: true}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      %{socket: socket} = connect_calls_socket(caller_scope.user)
      assert {:ok, payload, _channel} = subscribe_and_join(socket, @inbox_topic)

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

      assert :ok = Friendships.remove_friend(caller_scope, friendship.id)

      assert_push "call_ended", ended
      assert ended.call.call_id == started.call_id
      assert ended.call.terminal_outcome == :relationship_ended
      assert ended.signaling_session_id == payload.signaling_session_id
      refute_push "call_relationship_ended", _payload
    end

    test "maps interruption to call_ended for the tracked Call ID" do
      {caller_scope, _recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("inbox_interrupt")

      assert {:ok, %{call: started, started?: true}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      %{socket: socket} = connect_calls_socket(caller_scope.user)
      assert {:ok, payload, _channel} = subscribe_and_join(socket, @inbox_topic)

      now = DateTime.utc_now(:microsecond)

      Repo.get!(CallAttempt, started.call_id)
      |> Ecto.Changeset.change(%{state: :connecting, accepted_at: now})
      |> Repo.update!()

      restart_calls_runtime()

      assert_push "call_ended", ended
      assert ended.call.call_id == started.call_id
      assert ended.call.role == :caller
      assert ended.call.terminal_outcome == :interrupted
      assert ended.signaling_session_id == payload.signaling_session_id
      refute_push "call_interrupted", _payload
    end

    test "leaving the inbox does not cancel a ringing attempt" do
      {caller_scope, _recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("inbox_leave")

      voice_channel_id = Ecto.UUID.generate()

      assert {:ok, %{voice_session_id: voice_session_id}} =
               Voice.join(voice_channel_id, caller_scope.user.id, "inbox-leave-voice", self())

      assert {:ok, %{call: started, started?: true}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      %{socket: socket} = connect_calls_socket(caller_scope.user)
      assert {:ok, _payload, channel} = subscribe_and_join(socket, @inbox_topic)

      Process.unlink(channel.channel_pid)
      ref = leave(channel)
      assert_reply ref, :ok

      assert {:ok, still_ringing} = Calls.get_call(caller_scope, started.call_id)
      assert still_ringing.state == :ringing
      assert still_ringing.call_id == started.call_id

      assert {:ok, %{members: [%{user_id: caller_user_id}]}} =
               Voice.voice_channel_roster(voice_channel_id)

      assert caller_user_id == caller_scope.user.id
      assert :ok = Voice.leave(voice_channel_id, voice_session_id)
    end
  end

  describe "incoming client events" do
    test "rejects non-start_call client events as unsupported without mutating the attempt" do
      {caller_scope, _recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("inbox_unsup")

      assert {:ok, %{call: started, started?: true}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      %{socket: socket} = connect_calls_socket(caller_scope.user)
      assert {:ok, _payload, channel} = subscribe_and_join(socket, @inbox_topic)

      for event <-
            CallSignaling.call_command_events() ++
              ["SENTINEL_EVENT_NAME"] ++
              CallSignaling.reserved_media_events() do
        assert_reply push(channel, event, %{"secret" => "nested-payload"}), :error, %{
          reason: "unsupported_event"
        }
      end

      assert {:ok, still_ringing} = Calls.get_call(caller_scope, started.call_id)
      assert still_ringing.state == :ringing
    end
  end

  describe "start_call" do
    test "starts audio and video invitations and returns the allowlisted caller projection" do
      {caller_scope, _recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("inbox_start_av")

      %{socket: socket} = connect_calls_socket(caller_scope.user)

      assert {:ok, %{signaling_session_id: signaling_session_id, call: nil}, channel} =
               subscribe_and_join(socket, @inbox_topic)

      running_before = MapSet.new(ExWebRTC.PeerConnection.get_all_running())

      assert_reply push(channel, "start_call", start_payload(channel, direct_conversation.id)),
                   :ok,
                   %{
                     signaling_session_id: ^signaling_session_id,
                     started: true,
                     call: audio
                   }

      assert Map.keys(audio) |> Enum.sort() == expected_wire_call_keys()
      assert audio.role == :caller
      assert audio.state == :ringing
      assert audio.media_intent == :audio
      assert audio.direct_conversation_id == direct_conversation.id
      assert audio.caller_user_id == caller_scope.user.id
      refute_push "outgoing_call_ringing", _payload
      refute_push "incoming_call", _payload

      assert {:ok, cancelled} = Calls.cancel_call(caller_scope, audio.call_id)
      assert cancelled.state == :terminal

      {video_scope, _recipient, video_conversation, _friendship} =
        direct_conversation_fixture("inbox_start_video")

      %{socket: video_socket} = connect_calls_socket(video_scope.user)

      assert {:ok, %{signaling_session_id: video_session_id}, video_channel} =
               subscribe_and_join(video_socket, @inbox_topic)

      assert_reply push(
                     video_channel,
                     "start_call",
                     start_payload(video_channel, video_conversation.id, "video")
                   ),
                   :ok,
                   %{
                     signaling_session_id: ^video_session_id,
                     started: true,
                     call: %{role: :caller, media_intent: :video, state: :ringing}
                   }

      assert ExWebRTC.PeerConnection.get_all_running()
             |> MapSet.new()
             |> MapSet.difference(running_before)
             |> MapSet.size() == 0
    end

    test "delivers role-correct ringing to sibling tabs and nothing to an unrelated User" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("inbox_start_sib")

      outsider_scope = user_scope_fixture(user_fixture(username: "inbox_start_out"))
      caller_token = Accounts.generate_user_session_token(caller_scope.user)
      recipient_token = Accounts.generate_user_session_token(recipient_scope.user)
      outsider_token = Accounts.generate_user_session_token(outsider_scope.user)

      %{socket: initiator_socket} = connect_calls_socket(caller_scope.user)

      assert {:ok, %{signaling_session_id: signaling_session_id}, initiator} =
               subscribe_and_join(initiator_socket, @inbox_topic)

      start_inbox_tab(caller_token, :caller_b)
      start_inbox_tab(recipient_token, :recipient_a)
      start_inbox_tab(recipient_token, :recipient_b)
      start_inbox_tab(outsider_token, :outsider)

      assert {:joined, :caller_b, _pid, %{call: nil}, _ch} = await_joined(:caller_b)
      assert {:joined, :recipient_a, _pid, %{call: nil}, _ch} = await_joined(:recipient_a)
      assert {:joined, :recipient_b, _pid, %{call: nil}, _ch} = await_joined(:recipient_b)
      assert {:joined, :outsider, outsider_pid, %{call: nil}, _ch} = await_joined(:outsider)

      assert_reply push(
                     initiator,
                     "start_call",
                     start_payload(initiator, direct_conversation.id)
                   ),
                   :ok,
                   %{
                     signaling_session_id: ^signaling_session_id,
                     started: true,
                     call: %{call_id: call_id, role: :caller}
                   }

      refute_push "outgoing_call_ringing", _payload
      assert await_tab_push(:caller_b, "outgoing_call_ringing").call.call_id == call_id
      assert await_tab_push(:recipient_a, "incoming_call").call.role == :recipient
      assert await_tab_push(:recipient_b, "incoming_call").call.call_id == call_id

      send(outsider_pid, {:sync, self()})
      assert_receive {:sync, :outsider}
      refute_received {:push, :outsider, _event, _payload}
    end

    test "rejects forged, missing, stale, non-binary, and over-128-byte Signaling Session IDs" do
      {caller_scope, _recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("inbox_start_sid")

      %{socket: socket} = connect_calls_socket(caller_scope.user)
      assert {:ok, _payload, channel} = subscribe_and_join(socket, @inbox_topic)
      attempts_before = attempt_count()

      payloads = [
        start_payload(channel, direct_conversation.id, "audio", %{
          "signaling_session_id" => Ecto.UUID.generate()
        }),
        start_payload(channel, direct_conversation.id, "audio", %{
          "signaling_session_id" => "forged-signaling"
        }),
        start_payload(channel, direct_conversation.id) |> Map.delete("signaling_session_id"),
        start_payload(channel, direct_conversation.id, "audio", %{"signaling_session_id" => 123}),
        start_payload(channel, direct_conversation.id, "audio", %{
          "signaling_session_id" => String.duplicate("a", 129)
        })
      ]

      for payload <- payloads do
        assert_reply push(channel, "start_call", payload), :error, %{reason: "invalid_request"}
      end

      assert attempt_count() == attempts_before
    end

    test "rejects malformed payloads, extra fields, invalid IDs, and the 4097-byte envelope" do
      {caller_scope, _recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("inbox_start_val")

      %{socket: socket} = connect_calls_socket(caller_scope.user)
      assert {:ok, _payload, channel} = subscribe_and_join(socket, @inbox_topic)
      attempts_before = attempt_count()
      valid = start_payload(channel, direct_conversation.id)
      exact = padded_payload(valid, 4096)
      over = padded_payload(valid, 4097)

      assert_reply push(channel, "start_call", ["not-an-object"]), :error, %{
        reason: "invalid_request"
      }

      assert_reply push(channel, "start_call", Map.delete(valid, "media_intent")), :error, %{
        reason: "invalid_request"
      }

      assert_reply push(channel, "start_call", Map.put(valid, "role", "caller")), :error, %{
        reason: "invalid_request"
      }

      assert_reply push(channel, "start_call", %{valid | "direct_conversation_id" => "not-a-uuid"}),
                   :error,
                   %{reason: "invalid_request"}

      assert_reply push(channel, "start_call", %{valid | "media_intent" => "screen"}), :error, %{
        reason: "invalid_request"
      }

      assert_reply push(channel, "start_call", exact), :error, %{reason: "invalid_request"}
      assert_reply push(channel, "start_call", over), :error, %{reason: "invalid_request"}
      assert attempt_count() == attempts_before
    end

    test "returns safe errors for outsider, missing, and former-Friend starts without writing" do
      {caller_scope, recipient_scope, direct_conversation, friendship} =
        direct_conversation_fixture("inbox_start_auth")

      outsider_scope = user_scope_fixture(user_fixture(username: "inbox_start_auth_out"))
      attempts_before = attempt_count()

      %{socket: outsider_socket} = connect_calls_socket(outsider_scope.user)
      assert {:ok, _payload, outsider_channel} = subscribe_and_join(outsider_socket, @inbox_topic)

      assert_reply push(
                     outsider_channel,
                     "start_call",
                     start_payload(outsider_channel, direct_conversation.id)
                   ),
                   :error,
                   %{reason: "not_found"}

      %{socket: caller_socket} = connect_calls_socket(caller_scope.user)
      assert {:ok, _payload, caller_channel} = subscribe_and_join(caller_socket, @inbox_topic)

      assert_reply push(
                     caller_channel,
                     "start_call",
                     start_payload(caller_channel, Ecto.UUID.generate())
                   ),
                   :error,
                   %{reason: "not_found"}

      assert :ok = Friendships.remove_friend(recipient_scope, friendship.id)

      assert_reply push(
                     caller_channel,
                     "start_call",
                     start_payload(caller_channel, direct_conversation.id)
                   ),
                   :error,
                   %{reason: "not_friends"}

      assert attempt_count() == attempts_before
    end

    test "same-direction retry and opposite-direction starts converge on one attempt" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("inbox_start_conv")

      %{socket: caller_socket} = connect_calls_socket(caller_scope.user)
      %{socket: recipient_socket} = connect_calls_socket(recipient_scope.user)

      assert {:ok, _payload, caller_channel} = subscribe_and_join(caller_socket, @inbox_topic)

      assert {:ok, _payload, recipient_channel} =
               subscribe_and_join(recipient_socket, @inbox_topic)

      assert_reply push(
                     caller_channel,
                     "start_call",
                     start_payload(caller_channel, direct_conversation.id)
                   ),
                   :ok,
                   %{started: true, call: first}

      assert_reply push(
                     caller_channel,
                     "start_call",
                     start_payload(caller_channel, direct_conversation.id, "video")
                   ),
                   :ok,
                   %{started: false, call: retry}

      assert retry.call_id == first.call_id
      assert retry.media_intent == :audio
      assert retry.ringing_deadline_at == first.ringing_deadline_at
      assert retry.role == :caller
      assert retry.caller_user_id == caller_scope.user.id

      caller_ref =
        push(caller_channel, "start_call", start_payload(caller_channel, direct_conversation.id))

      recipient_ref =
        push(
          recipient_channel,
          "start_call",
          start_payload(recipient_channel, direct_conversation.id, "video")
        )

      assert_reply caller_ref, :ok, %{call: %{call_id: from_caller}}
      assert_reply recipient_ref, :ok, %{call: %{call_id: from_recipient, role: role}}
      assert from_caller == first.call_id
      assert from_recipient == first.call_id
      assert role == :recipient
      assert Repo.aggregate(CallAttempt, :count) == 1
    end

    test "passes through busy and both rate-limit results without a new attempt or projection" do
      {alice_scope, bob_scope, alice_bob, _friendship} =
        direct_conversation_fixture("inbox_start_busy")

      carol_scope = user_scope_fixture(user_fixture(username: "inbox_start_busy_carol"))
      {alice_carol, _friendship} = befriend_and_open_direct_conversation(alice_scope, carol_scope)

      %{socket: alice_socket} = connect_calls_socket(alice_scope.user)
      %{socket: carol_socket} = connect_calls_socket(carol_scope.user)
      assert {:ok, _payload, alice_channel} = subscribe_and_join(alice_socket, @inbox_topic)
      assert {:ok, _payload, carol_channel} = subscribe_and_join(carol_socket, @inbox_topic)

      assert_reply push(alice_channel, "start_call", start_payload(alice_channel, alice_bob.id)),
                   :ok,
                   %{started: true, call: ringing}

      refute_push "outgoing_call_ringing", _payload

      assert_reply push(
                     alice_channel,
                     "start_call",
                     start_payload(alice_channel, alice_carol.id)
                   ),
                   :error,
                   %{reason: "busy"}

      assert_reply push(
                     carol_channel,
                     "start_call",
                     start_payload(carol_channel, alice_carol.id)
                   ),
                   :error,
                   %{reason: "busy"}

      refute_push "incoming_call", _payload
      assert Repo.aggregate(CallAttempt, :count) == 1
      assert Registry.count(DiscordClone.Calls.CallRegistry) == 1

      assert {:ok, %{call_id: call_id, state: :ringing}} =
               Calls.get_call(alice_scope, ringing.call_id)

      assert call_id == ringing.call_id
      assert bob_scope.user.id == ringing.recipient_user_id

      {rate_scope, rate_recipient, rate_conversation, _friendship} =
        direct_conversation_fixture("inbox_start_rate")

      now = DateTime.utc_now(:microsecond)

      for offset <- 0..4 do
        insert_call_attempt(rate_scope, rate_recipient, rate_conversation, %{
          inserted_at: DateTime.add(now, -offset, :second),
          accepted_at: DateTime.add(now, -offset, :second),
          terminal_outcome: :ended
        })
      end

      %{socket: rate_socket} = connect_calls_socket(rate_scope.user)
      assert {:ok, _payload, rate_channel} = subscribe_and_join(rate_socket, @inbox_topic)
      activity_before = Repo.aggregate(ActivityItem, :count)

      assert_reply push(
                     rate_channel,
                     "start_call",
                     start_payload(rate_channel, rate_conversation.id)
                   ),
                   :error,
                   %{reason: "rate_limited"}

      for offset <- 0..2 do
        insert_call_attempt(rate_scope, rate_recipient, rate_conversation, %{
          inserted_at: DateTime.add(now, -10 - offset, :second),
          terminal_outcome: :declined
        })
      end

      assert_reply push(
                     rate_channel,
                     "start_call",
                     start_payload(rate_channel, rate_conversation.id)
                   ),
                   :error,
                   %{reason: "rate_limited"}

      assert Repo.aggregate(CallAttempt, :count) == 9
      assert Repo.aggregate(ActivityItem, :count) == activity_before
      assert Registry.count(DiscordClone.Calls.CallRegistry) == 1
    end

    test "fails closed when the Calls runtime is temporarily unavailable" do
      {caller_scope, _recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("inbox_start_unav")

      %{socket: socket} = connect_calls_socket(caller_scope.user)
      assert {:ok, _payload, channel} = subscribe_and_join(socket, @inbox_topic)

      assert :ok =
               Supervisor.terminate_child(
                 DiscordClone.Calls.Supervisor,
                 DiscordClone.Calls.CallCoordinator
               )

      assert_reply push(channel, "start_call", start_payload(channel, direct_conversation.id)),
                   :error,
                   %{reason: "temporarily_unavailable"}

      refute_push "outgoing_call_ringing", _payload
    end

    test "does not write on join, leave, or validation failure and preserves Voice" do
      {caller_scope, _recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("inbox_start_side")

      voice_channel_id = Ecto.UUID.generate()

      assert {:ok, %{voice_session_id: voice_session_id}} =
               Voice.join(voice_channel_id, caller_scope.user.id, "inbox-start-voice", self())

      attempts_before = attempt_count()
      %{socket: socket} = connect_calls_socket(caller_scope.user)
      assert {:ok, %{call: nil}, channel} = subscribe_and_join(socket, @inbox_topic)
      assert attempt_count() == attempts_before

      assert_reply push(channel, "start_call", %{"secret" => "nested-payload"}), :error, %{
        reason: "invalid_request"
      }

      assert attempt_count() == attempts_before

      running_before = MapSet.new(ExWebRTC.PeerConnection.get_all_running())

      assert_reply push(channel, "start_call", start_payload(channel, direct_conversation.id)),
                   :ok,
                   %{started: true, call: started}

      Process.unlink(channel.channel_pid)
      ref = leave(channel)
      assert_reply ref, :ok

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

  describe "owner tabs" do
    test "the initiating inbox connection is projected self and sibling inboxes elsewhere" do
      {caller_scope, _recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("inbox_owner_start")

      caller_token = Accounts.generate_user_session_token(caller_scope.user)
      %{socket: initiator_socket} = connect_calls_socket(caller_scope.user)

      assert {:ok, %{signaling_session_id: signaling_session_id, call: nil}, initiator} =
               subscribe_and_join(initiator_socket, @inbox_topic)

      start_inbox_tab(caller_token, :owner_sibling)
      assert {:joined, :owner_sibling, _pid, %{call: nil}, _ch} = await_joined(:owner_sibling)

      assert_reply push(
                     initiator,
                     "start_call",
                     start_payload(initiator, direct_conversation.id)
                   ),
                   :ok,
                   %{
                     signaling_session_id: ^signaling_session_id,
                     started: true,
                     call: %{role: :caller, state: :ringing, ownership: :self}
                   }

      assert %{call: %{role: :caller, state: :ringing, ownership: :elsewhere}} =
               await_tab_push(:owner_sibling, "outgoing_call_ringing")
    end

    test "terminating the preferred caller's Call topic releases the preference for good" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("inbox_owner_terminate")

      %{socket: socket} = connect_calls_socket(caller_scope.user)

      assert {:ok, %{call: nil}, initiator} = subscribe_and_join(socket, @inbox_topic)

      assert_reply push(
                     initiator,
                     "start_call",
                     start_payload(initiator, direct_conversation.id)
                   ),
                   :ok,
                   %{call: %{call_id: call_id, ownership: :self}}

      assert {:ok, %{call: %{ownership: :self}}, call_channel} =
               subscribe_and_join(socket, call_topic(call_id))

      %{socket: sibling_socket} = connect_calls_socket(caller_scope.user)

      assert {:ok, %{call: %{state: :ringing, ownership: :elsewhere}}, _sibling_call} =
               subscribe_and_join(sibling_socket, call_topic(call_id))

      Process.unlink(call_channel.channel_pid)
      ref = Process.monitor(call_channel.channel_pid)
      leave(call_channel)
      assert_receive {:DOWN, ^ref, :process, _pid, {:shutdown, :left}}

      assert_push "outgoing_call_ringing", %{call: %{state: :ringing, ownership: :elsewhere}}

      # The ringing push makes the browser rejoin its Call topic from the same
      # socket; the fresh snapshot must not restore the released preference.
      assert {:ok, %{call: %{state: :ringing, ownership: :elsewhere}}, _rejoined} =
               subscribe_and_join(socket, call_topic(call_id))

      %{socket: recipient_socket} = connect_calls_socket(recipient_scope.user)

      assert {:ok, %{call: %{state: :ringing, ownership: :unclaimed}}, recipient_call} =
               subscribe_and_join(recipient_socket, call_topic(call_id))

      with_accepted_runtime(:held, fn ->
        assert_reply push(recipient_call, "accept_call", accept_payload(recipient_call)), :ok, %{
          call: %{state: :connecting}
        }

        assert Calls.ownership(call_id, :caller, sibling_socket.assigns.connection_id) == :self
        assert Calls.ownership(call_id, :caller, socket.assigns.connection_id) == :elsewhere
      end)
    end

    test "recipient inboxes receive ownership and a sibling prompt while the winner keeps self" do
      {_caller_scope, recipient_scope, started} = start_ringing_call("inbox_owner_accept")

      %{socket: winner_socket} = connect_calls_socket(recipient_scope.user)

      assert {:ok, %{call: %{state: :ringing}}, _winner_inbox} =
               subscribe_and_join(winner_socket, @inbox_topic)

      assert {:ok, %{call: %{state: :ringing}}, winner_call} =
               subscribe_and_join(winner_socket, call_topic(started.call_id))

      %{socket: sibling_socket} = connect_calls_socket(recipient_scope.user)

      assert {:ok, %{call: %{state: :ringing}}, _sibling_inbox} =
               subscribe_and_join(sibling_socket, @inbox_topic)

      with_accepted_runtime(:held, fn ->
        assert_reply push(winner_call, "accept_call", accept_payload(winner_call)), :ok, %{
          call: %{state: :connecting, ownership: :self, role: :recipient}
        }

        assert_push "call_connecting", %{call: %{state: :connecting, ownership: :self}}
        assert_push "call_connecting", %{call: %{state: :connecting, ownership: :elsewhere}}
        assert_push "sibling_tab_owns_call", %{call: %{state: :connecting, ownership: :elsewhere}}
      end)
    end

    test "the inbox never registers per-call connections" do
      {caller_scope, _recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("inbox_owner_reg")

      %{socket: socket} = connect_calls_socket(caller_scope.user)

      assert {:ok, %{call: nil}, channel} = subscribe_and_join(socket, @inbox_topic)

      assert_reply push(channel, "start_call", start_payload(channel, direct_conversation.id)),
                   :ok,
                   %{call: %{call_id: call_id}}

      registrations = call_server_registrations(call_id)
      refute Map.has_key?(registrations, socket.assigns.connection_id)
    end
  end

  defp connect_calls_socket(user \\ user_fixture()) do
    token = Accounts.generate_user_session_token(user)

    %{
      socket: connect_authenticated_socket(token),
      token: token,
      scope: DiscordClone.Accounts.Scope.for_user(user)
    }
  end

  defp restart_calls_runtime do
    stop_supervised!(DiscordClone.Calls.Supervisor)
    start_supervised!(DiscordClone.Calls.Supervisor)
    DiscordClone.Calls.CallCoordinator.begin_recovery()
    await_recovery_finished()
  end

  defp connect_authenticated_socket(token) do
    assert {:ok, socket} =
             connect(CallSocket, %{}, connect_info: %{session: %{"user_token" => token}})

    socket
  end

  defp call_server_registrations(call_id) do
    [{pid, _value}] = Registry.lookup(DiscordClone.Calls.CallRegistry, call_id)
    :sys.get_state(pid).registrations
  end

  defp start_ringing_call(suffix) do
    {caller_scope, recipient_scope, direct_conversation, _friendship} =
      direct_conversation_fixture(suffix)

    assert {:ok, %{call: started, started?: true}} =
             Calls.start_call(caller_scope, direct_conversation.id, :audio)

    {caller_scope, recipient_scope, started}
  end

  defp accept_payload(channel, overrides \\ %{}) do
    Map.merge(
      %{
        "signaling_session_id" => channel.assigns.signaling_session_id,
        "call_id" => channel.assigns.call_id,
        "answer_mode" => "audio"
      },
      overrides
    )
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

  defp call_topic(call_id), do: CallSignaling.call_topic(call_id)

  defp start_inbox_tab(token, tag) do
    parent = self()

    start_supervised!(%{
      id: {:call_inbox_tab, tag},
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
              Phoenix.ChannelTest.subscribe_and_join(socket, CallInboxChannel, @inbox_topic)

            send(parent, {:joined, tag, self(), payload, channel})
            inbox_tab_loop(parent, tag)
          end
        ]
      }
    })
  end

  defp inbox_tab_loop(parent, tag) do
    receive do
      %Phoenix.Socket.Message{event: event, payload: payload} ->
        send(parent, {:push, tag, event, payload})
        inbox_tab_loop(parent, tag)

      {:sync, from} ->
        send(from, {:sync, tag})
        inbox_tab_loop(parent, tag)
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

  defp collect_pushes(event, count) do
    Enum.map(1..count, fn _index ->
      assert_receive %Phoenix.Socket.Message{event: ^event, payload: payload}
      payload
    end)
  end

  defp start_payload(channel, direct_conversation_id, media_intent \\ "audio", overrides \\ %{}) do
    Map.merge(
      %{
        "signaling_session_id" => channel.assigns.signaling_session_id,
        "direct_conversation_id" => direct_conversation_id,
        "media_intent" => media_intent
      },
      overrides
    )
  end

  defp padded_payload(payload, size) do
    probe = Map.put(payload, "pad", "")
    pad_size = size - byte_size(Jason.encode!(probe))
    padded = Map.put(payload, "pad", String.duplicate("x", pad_size))
    assert byte_size(Jason.encode!(padded)) == size
    padded
  end

  defp expected_wire_call_keys do
    (Calls.projection_keys() ++ [:ownership, :peer, :role]) |> Enum.sort()
  end

  defp attempt_count, do: Repo.aggregate(CallAttempt, :count)

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
end
