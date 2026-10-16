defmodule DiscordCloneWeb.CallMediaSignalingTest do
  use DiscordClone.DataCase, async: false

  import ExUnit.CaptureLog
  import DiscordClone.CallsFixtures
  import Phoenix.ChannelTest

  alias DiscordClone.Accounts
  alias DiscordClone.Calls
  alias DiscordClone.Media.{AdmissionCoordinator, DirectCallSession, DirectCallTarget}
  alias DiscordClone.MediaFixtures
  alias DiscordCloneWeb.{CallSignaling, CallSocket}
  alias ExWebRTC.{ICECandidate, MediaStreamTrack, PeerConnection, SessionDescription}

  @endpoint DiscordCloneWeb.Endpoint

  setup context do
    start_supervised!(DiscordClone.Calls.Supervisor)
    DiscordClone.Calls.CallCoordinator.begin_recovery()
    await_recovery_finished()
    MediaFixtures.setup_coordinator_pair_state!()

    previous =
      for key <- [
            :accepted_call_runtime,
            :direct_call_transport,
            :direct_call_camera_lifecycle_enabled
          ],
          into: %{} do
        {key, Application.fetch_env(:discord_clone, key)}
      end

    if context[:shipping_defaults] do
      Application.delete_env(:discord_clone, :accepted_call_runtime)
      Application.delete_env(:discord_clone, :direct_call_transport)
    else
      Application.put_env(
        :discord_clone,
        :accepted_call_runtime,
        DiscordClone.Calls.PairAdmissionRuntime
      )

      transport = if context[:fake_transport], do: :fake, else: :real
      Application.put_env(:discord_clone, :direct_call_transport, transport)
    end

    unless context[:shipping_defaults] && !context[:video_off] do
      Application.put_env(
        :discord_clone,
        :direct_call_camera_lifecycle_enabled,
        context[:controlled_camera] == true
      )
    end

    on_exit(fn ->
      MediaFixtures.reset_coordinator_pair_state!()

      for {key, value} <- previous do
        case value do
          {:ok, value} -> Application.put_env(:discord_clone, key, value)
          :error -> Application.delete_env(:discord_clone, key)
        end
      end
    end)

    :ok
  end

  @tag :shipping_defaults
  @tag :video_off
  test "operational video off preserves authenticated audio, owner rejoin and retirement" do
    {caller_scope, recipient_scope, conversation, _} = direct_conversation_fixture("shipping")
    socket = connect_socket(caller_scope)
    assert {:ok, _, inbox} = subscribe_and_join(socket, CallSignaling.inbox_topic())

    start = %{
      "signaling_session_id" => inbox.assigns.signaling_session_id,
      "direct_conversation_id" => conversation.id,
      "media_intent" => "video"
    }

    running = MapSet.new(PeerConnection.get_all_running())

    for field <- ["video_available", "camera_lifecycle_enabled", "device_adapter", "ownership"] do
      assert_reply push(inbox, "start_call", Map.put(start, field, true)), :error, %{
        reason: "invalid_request"
      }
    end

    assert_reply push(inbox, "start_call", start), :error, %{reason: "temporarily_unavailable"}
    assert {:ok, nil} = Calls.current_call(caller_scope)
    assert AdmissionCoordinator.effective_occupancy() == 0

    assert_reply push(inbox, "start_call", Map.put(start, "media_intent", "audio")),
                 :ok,
                 %{call: %{call_id: call_id, state: :ringing}}

    pair = %{caller: caller_scope, recipient: recipient_scope, call_id: call_id}
    caller = join_call(socket, call_id)
    recipient = join_call(connect_socket(recipient_scope), call_id)
    sibling = join_call(connect_socket(caller_scope), call_id)
    assert MapSet.new(PeerConnection.get_all_running()) == running
    assert AdmissionCoordinator.reservation_count() == 0
    assert_reply push(caller, "media_credentials", command(caller)), :error, _
    accept(recipient)
    await_pair(pair)
    monitors = resource_monitors(pair)

    assert_reply push(sibling, "media_credentials", command(sibling)), :error, %{
      reason: "not_admitted"
    }

    assert_reply push(caller, "media_credentials", command(caller)), :ok, first_credentials
    first = connect_peer(caller, first_credentials, "shipping-first")
    assert {:ok, %{state: :connecting}} = Calls.get_call(caller_scope, call_id)
    refute_push "call_active", _, 0
    assert_reply push(recipient, "media_credentials", command(recipient)), :ok, second_credentials
    second = connect_peer(recipient, second_credentials, "shipping-second")
    assert_push "call_active", %{call: %{state: :active}}, 2_000
    send_audio(first, <<0xF8, 0xFF, 0xFE>>, 1)
    assert_audio(second, <<0xF8, 0xFF, 0xFE>>)
    send_audio(second, <<0xF9, 0xFF, 0xFE, 0xFF, 0xFE>>, 1)
    assert_audio(first, <<0xF9, 0xFF, 0xFE, 0xFF, 0xFE>>)
    refute_receive {:ex_webrtc, _, {:rtp, _, _, _}}, 100

    # Same live owner connection, new topic join: discover, never renegotiate.
    rejoined = join_call(socket, call_id)
    assert_reply push(rejoined, "media_credentials", command(rejoined)), :ok, discovered
    assert discovered.call_session_id == first_credentials.call_session_id
    assert discovered.negotiation_id == "shipping-first"
    old_renewal = Map.put(command(caller), "call_session_id", first_credentials.call_session_id)

    assert_reply push(caller, "renew", old_renewal),
                 :error,
                 _

    media = media_command(rejoined, discovered, "shipping-first")

    old_state =
      media_command(caller, first_credentials, "shipping-first")
      |> Map.merge(%{
        "media_state_version" => 10,
        "microphone_muted" => true,
        "camera_enabled" => false
      })

    assert_reply push(caller, "local_media_state", old_state), :error, %{reason: "not_admitted"}

    assert_reply push(rejoined, "local_media_state", old_state), :error, %{
      reason: "invalid_request"
    }

    renewal = Map.put(command(rejoined), "call_session_id", discovered.call_session_id)
    assert_reply push(rejoined, "renew", renewal), :ok, %{call_session_id: session_id}
    assert session_id == first_credentials.call_session_id

    for {muted, version} <- [{true, 1}, {false, 2}] do
      control =
        Map.merge(media, %{
          "media_state_version" => version,
          "microphone_muted" => muted,
          "camera_enabled" => false
        })

      assert_reply push(rejoined, "local_media_state", control), :ok, _
      send_audio(first, <<0xF8, 0xFF, 0xFE>>, version + 1)

      if muted do
        remote = second.browser
        refute_receive {:ex_webrtc, ^remote, {:rtp, _, _, _}}, 150
      else
        assert_audio(second, <<0xF8, 0xFF, 0xFE>>)
      end

      send_audio(second, <<0xF9, 0xFF, 0xFE, 0xFF, 0xFE>>, version + 1)
      assert_audio(first, <<0xF9, 0xFF, 0xFE, 0xFF, 0xFE>>)
    end

    started = System.monotonic_time(:millisecond)
    assert_reply push(recipient, "leave_call", command(recipient)), :ok, _
    assert_retired(monitors, started)
    await_terminal(pair)
    assert AdmissionCoordinator.call_target_snapshot(call_id) == nil
    assert AdmissionCoordinator.current_identity(caller_scope.user.id) == nil
    assert AdmissionCoordinator.current_identity(recipient_scope.user.id) == nil
    assert_reply push(rejoined, "renew", renewal), :error, %{reason: "not_admitted"}
  end

  test "admitted owner negotiates a real peer using only authenticated channel signaling" do
    pair = start_pair("signal_real")
    caller = join_call(pair.caller_socket, pair.call_id)
    recipient = join_call(connect_socket(pair.recipient), pair.call_id)
    accept(recipient)
    await_pair(pair)
    assert_reply push(caller, "media_credentials", command(caller)), :ok, credentials

    logs =
      capture_log(fn ->
        first = connect_peer(caller, credentials, "one")
        assert {:ok, %{state: :connecting}} = Calls.get_call(pair.caller, pair.call_id)
        refute_push "call_active", _, 0
        assert_reply push(recipient, "media_credentials", command(recipient)), :ok, other
        second = connect_peer(recipient, other, "two")
        assert_push "call_active", %{call: %{state: :active}}, 2_000
        assert_push "call_active", %{call: %{state: :active}}, 2_000
        first_payload = <<0xF8, 0xFF, 0xFE>>
        second_payload = <<0xF9, 0xFF, 0xFE, 0xFF, 0xFE>>
        send_audio(first, first_payload)
        send_audio(second, second_payload)
        assert_audio(second, first_payload)
        assert_audio(first, second_payload)
        refute_receive {:ex_webrtc, _, {:rtp, _, _, _}}, 100
        assert {:ok, %{state: :active}} = Calls.get_call(pair.caller, pair.call_id)
      end)

    for secret <- [
          "candidate:",
          "a=ice-pwd",
          "a=fingerprint",
          credentials.call_session_id,
          caller.assigns.signaling_session_id
        ] do
      refute logs =~ secret
    end

    close_channel(caller)
    await_terminal(pair)
  end

  @tag :shipping_defaults
  test "default video start and answer retain participant and selected-owner rules" do
    {caller_scope, recipient_scope, conversation, friendship} =
      direct_conversation_fixture("camera_commands")

    socket = connect_socket(caller_scope)
    assert {:ok, _, inbox} = subscribe_and_join(socket, CallSignaling.inbox_topic())

    assert_reply push(inbox, "start_call", %{
                   "signaling_session_id" => inbox.assigns.signaling_session_id,
                   "direct_conversation_id" => conversation.id,
                   "media_intent" => "video"
                 }),
                 :ok,
                 %{call: %{call_id: call_id, media_intent: :video, state: :ringing}}

    pair = %{caller: caller_scope, recipient: recipient_scope, call_id: call_id}
    assert AdmissionCoordinator.effective_occupancy() == 0
    caller = join_call(socket, call_id)
    recipient = join_call(connect_socket(recipient_scope), call_id)
    sibling = join_call(connect_socket(caller_scope), call_id)
    outsider = DiscordClone.AccountsFixtures.user_scope_fixture()

    assert {:error, %{reason: "not_found"}} =
             subscribe_and_join(connect_socket(outsider), CallSignaling.call_topic(call_id))

    assert {:error, :not_found} = Calls.accept_call(outsider, call_id, :video)

    assert_reply push(caller, "accept_call", Map.put(command(caller), "answer_mode", "video")),
                 :error,
                 %{reason: "not_found"}

    assert_reply push(
                   recipient,
                   "accept_call",
                   Map.put(command(recipient), "answer_mode", "video")
                 ),
                 :ok,
                 %{call: %{state: :connecting, media_intent: :video, answer_mode: :video}},
                 2_000

    await_pair(pair)
    assert AdmissionCoordinator.effective_occupancy() == 2

    assert_reply push(sibling, "media_credentials", command(sibling)), :error, %{
      reason: "not_admitted"
    }

    assert_reply push(recipient, "leave_call", command(recipient)), :ok, _
    await_terminal(pair)
    assert :ok = DiscordClone.Friendships.remove_friend(recipient_scope, friendship.id)
    assert {:error, :not_friends} = Calls.start_call(caller_scope, conversation.id, :video)
  end

  @tag :shipping_defaults
  test "operational off rejects a video answer without silently changing the invitation" do
    pair = start_pair("off_before_answer", :video)
    caller = join_call(pair.caller_socket, pair.call_id)
    recipient = join_call(connect_socket(pair.recipient), pair.call_id)
    Application.put_env(:discord_clone, :direct_call_camera_lifecycle_enabled, false)

    answer = Map.put(command(recipient), "answer_mode", "video")

    for field <- [nil, "video_available", "camera_lifecycle_enabled", "ownership"] do
      payload = if field, do: Map.put(answer, field, true), else: answer
      reason = if field, do: "invalid_request", else: "temporarily_unavailable"
      assert_reply push(recipient, "accept_call", payload), :error, %{reason: ^reason}
    end

    assert {:ok, %{state: :ringing, media_intent: :video}} =
             Calls.get_call(pair.recipient, pair.call_id)

    assert AdmissionCoordinator.effective_occupancy() == 0
    assert AdmissionCoordinator.reservation_count() == 0

    accept(recipient, :audio)
    await_pair(pair)

    assert {:ok, %{media_intent: :video, answer_mode: :audio}} =
             Calls.get_call(pair.caller, pair.call_id)

    connect_audio_pair(caller, recipient)
    assert_reply push(recipient, "leave_call", command(recipient)), :ok, _
    await_terminal(pair)
  end

  for answer_mode <- [:audio, :video] do
    @tag :controlled_camera
    @tag :ticket30_lifecycle
    test "recipient #{answer_mode} choice commits on the same video invitation with original deadlines" do
      {caller_scope, recipient_scope, conversation, _} =
        direct_conversation_fixture("recipient_#{unquote(answer_mode)}")

      socket = connect_socket(caller_scope)
      assert {:ok, _, inbox} = subscribe_and_join(socket, CallSignaling.inbox_topic())

      assert_reply push(inbox, "start_call", %{
                     "signaling_session_id" => inbox.assigns.signaling_session_id,
                     "direct_conversation_id" => conversation.id,
                     "media_intent" => "video"
                   }),
                   :ok,
                   %{call: %{call_id: call_id}}

      pair = %{caller: caller_scope, recipient: recipient_scope, call_id: call_id}
      _caller = join_call(socket, call_id)
      recipient = join_call(connect_socket(recipient_scope), call_id)
      sibling = join_call(connect_socket(recipient_scope), call_id)
      assert {:ok, invitation} = Calls.get_call(recipient_scope, call_id)
      assert invitation.state == :ringing
      assert AdmissionCoordinator.effective_occupancy() == 0

      assert_reply push(
                     recipient,
                     "accept_call",
                     Map.put(
                       command(recipient),
                       "answer_mode",
                       Atom.to_string(unquote(answer_mode))
                     )
                   ),
                   :ok,
                   %{
                     call: %{
                       state: :connecting,
                       ownership: :self,
                       media_intent: :video,
                       answer_mode: unquote(answer_mode)
                     }
                   },
                   2_000

      await_pair(pair)

      original =
        :sys.get_state(DiscordClone.Voice.SessionCoordinator).active_call.connect_deadline

      opposite = if unquote(answer_mode) == :audio, do: "video", else: "audio"

      assert_reply push(
                     sibling,
                     "accept_call",
                     Map.put(command(sibling), "answer_mode", opposite)
                   ),
                   :ok,
                   %{call: %{ownership: :elsewhere, answer_mode: unquote(answer_mode)}}

      assert {:ok, committed} = Calls.get_call(recipient_scope, call_id)
      assert committed.call_id == call_id
      assert committed.media_intent == :video
      assert committed.answer_mode == unquote(answer_mode)
      assert committed.ringing_deadline_at == invitation.ringing_deadline_at

      assert :sys.get_state(DiscordClone.Voice.SessionCoordinator).active_call.connect_deadline ==
               original

      assert AdmissionCoordinator.effective_occupancy() == 2

      assert_reply push(sibling, "media_credentials", command(sibling)), :error, %{
        reason: "not_admitted"
      }

      assert_reply push(recipient, "leave_call", command(recipient)), :ok, _
      await_terminal(pair)
    end

    @tag :controlled_camera
    test "original ringing expiry rejects recipient #{answer_mode} choice without pair admission" do
      {caller, recipient, conversation, _} =
        direct_conversation_fixture("expired_video_#{unquote(answer_mode)}")

      assert {:ok, %{call: invitation}} = Calls.start_call(caller, conversation.id, :video)
      make_ringing_deadline_due!(invitation.call_id)

      assert {:error, :stale} =
               Calls.accept_call(recipient, invitation.call_id, unquote(answer_mode))

      assert {:ok, %{state: :terminal, terminal_outcome: :timed_out}} =
               Calls.expire_ringing_attempt(invitation.call_id)

      assert {:ok, %{state: :terminal, media_intent: :video} = terminal} =
               Calls.get_call(recipient, invitation.call_id)

      refute Map.has_key?(terminal, :answer_mode)
      assert AdmissionCoordinator.effective_occupancy() == 0
      assert AdmissionCoordinator.reservation_count() == 0
    end
  end

  @tag :controlled_camera
  test "recipient expiry during pair reservation cannot commit a video answer" do
    {caller, recipient, conversation, _} = direct_conversation_fixture("video_commit_expiry")
    assert {:ok, %{call: invitation}} = Calls.start_call(caller, conversation.id, :video)

    Application.put_env(:discord_clone, :pair_accept_between_reserve_and_commit, fn ->
      make_ringing_deadline_due!(invitation.call_id)
    end)

    on_exit(fn ->
      Application.delete_env(:discord_clone, :pair_accept_between_reserve_and_commit)
    end)

    assert {:error, :stale} = Calls.accept_call(recipient, invitation.call_id, :video)
    assert AdmissionCoordinator.effective_occupancy() == 0
    assert AdmissionCoordinator.reservation_count() == 0

    assert {:ok, %{state: :terminal, terminal_outcome: :timed_out}} =
             Calls.expire_ringing_attempt(invitation.call_id)
  end

  @tag :shipping_defaults
  test "default camera state preserves exact owner authorization and audio under operational off" do
    pair = start_pair("camera_state")
    caller = join_call(pair.caller_socket, pair.call_id)
    recipient = join_call(connect_socket(pair.recipient), pair.call_id)
    sibling_socket = connect_socket(pair.caller)

    assert {:ok, ringing, sibling_inbox} =
             subscribe_and_join(sibling_socket, CallSignaling.inbox_topic())

    refute Map.has_key?(ringing.call, :media_state)
    sibling = join_call(sibling_socket, pair.call_id)
    accept(recipient)
    await_pair(pair)
    assert_reply push(caller, "media_credentials", command(caller)), :ok, credentials
    first = connect_peer(caller, credentials, "controlled-camera")
    assert_reply push(recipient, "media_credentials", command(recipient)), :ok, other_credentials
    second = connect_peer(recipient, other_credentials, "controlled-recipient")
    assert_push "call_active", %{call: %{state: :active}}, 2_000

    payload =
      Map.merge(command(caller), %{
        "call_session_id" => credentials.call_session_id,
        "negotiation_id" => "controlled-camera",
        "media_state_version" => 1,
        "microphone_muted" => false,
        "camera_enabled" => true
      })

    forged = Map.put(payload, "signaling_session_id", sibling.assigns.signaling_session_id)
    assert_reply push(sibling, "local_media_state", forged), :error, %{reason: "not_admitted"}

    assert_reply push(
                   caller,
                   "local_media_state",
                   Map.put(payload, "negotiation_id", "obsolete")
                 ),
                 :error,
                 %{reason: "not_admitted"}

    assert_reply push(caller, "local_media_state", payload), :ok, %{
      media_state_version: 1,
      microphone_muted: false,
      camera_enabled: true
    }

    expected = %{caller: %{media_state_version: 1, microphone_muted: false, camera_enabled: true}}
    assert {:ok, %{media_state: ^expected}} = Calls.get_call(pair.recipient, pair.call_id)
    sibling_id = sibling.assigns.signaling_session_id

    assert_push "call_active",
                %{
                  signaling_session_id: ^sibling_id,
                  call: %{ownership: :elsewhere, media_state: ^expected}
                },
                2_000

    recipient_id = recipient.assigns.signaling_session_id

    assert_push "call_active",
                %{
                  signaling_session_id: ^recipient_id,
                  call: %{ownership: :self, media_state: ^expected}
                },
                2_000

    inbox_id = sibling_inbox.assigns.signaling_session_id

    assert_push "call_active",
                %{
                  signaling_session_id: ^inbox_id,
                  call: %{ownership: :elsewhere, media_state: ^expected} = wire
                },
                2_000

    assert Enum.sort(Map.keys(wire)) ==
             Enum.sort(
               Calls.projection_keys() ++ [:role, :peer, :ownership, :answer_mode, :media_state]
             )

    assert Enum.sort(Map.keys(wire.media_state.caller)) ==
             [:camera_enabled, :media_state_version, :microphone_muted]

    opus = <<0xF8, 0xFF, 0xFE>>
    remote_opus = <<0xF9, 0xFF, 0xFE, 0xFF, 0xFE>>
    send_audio(first, opus)
    assert_audio(second, opus)
    assert AdmissionCoordinator.effective_occupancy() == 2

    other =
      media_command(recipient, other_credentials, "controlled-recipient")
      |> Map.merge(%{
        "media_state_version" => 1,
        "microphone_muted" => false,
        "camera_enabled" => false
      })

    assert_reply push(recipient, "local_media_state", other), :ok, _
    muted = Map.merge(payload, %{"media_state_version" => 2, "microphone_muted" => true})
    assert_reply push(caller, "local_media_state", muted), :ok, _

    expected = %{
      caller: %{media_state_version: 2, microphone_muted: true, camera_enabled: true},
      recipient: %{media_state_version: 1, microphone_muted: false, camera_enabled: false}
    }

    assert {:ok, %{media_state: ^expected}} = Calls.get_call(pair.caller, pair.call_id)
    send_audio(first, opus, 2)
    remote = second.browser
    refute_receive {:ex_webrtc, ^remote, {:rtp, _, _, _}}, 150
    send_audio(second, remote_opus, 2)
    assert_audio(first, remote_opus)

    for invalid <- [
          payload,
          Map.put(muted, "negotiation_id", "obsolete"),
          Map.put(muted, "call_session_id", other_credentials.call_session_id),
          Map.put(muted, "device_label", "PRIVATE_DEVICE")
        ] do
      assert_reply push(caller, "local_media_state", invalid), :error, _
      assert {:ok, %{media_state: ^expected}} = Calls.get_call(pair.recipient, pair.call_id)
    end

    assert_reply push(sibling, "media_credentials", command(sibling)), :error, %{
      reason: "not_admitted"
    }

    assert {:ok, late_snapshot, late_inbox} =
             subscribe_and_join(connect_socket(pair.caller), CallSignaling.inbox_topic())

    assert late_snapshot.call.ownership == :elsewhere
    assert late_snapshot.call.media_state == expected
    close_channel(late_inbox)

    Application.put_env(:discord_clone, :direct_call_camera_lifecycle_enabled, false)
    next = Map.put(payload, "media_state_version", 3)
    assert_reply push(caller, "local_media_state", next), :error, %{reason: "not_admitted"}
    assert {:ok, %{media_state: ^expected}} = Calls.get_call(pair.recipient, pair.call_id)

    assert_reply push(caller, "local_media_state", Map.put(next, "camera_enabled", false)),
                 :ok,
                 %{media_state_version: 3, microphone_muted: false, camera_enabled: false}

    assert {:ok,
            %{
              media_state: %{
                caller: %{media_state_version: 3, microphone_muted: false, camera_enabled: false}
              }
            }} = Calls.get_call(pair.recipient, pair.call_id)

    send_audio(first, opus, 3)
    assert_audio(second, opus)
    assert_reply push(recipient, "leave_call", command(recipient)), :ok, _
    await_terminal(pair)
    assert {:ok, terminal} = Calls.get_call(pair.caller, pair.call_id)
    refute Map.has_key?(terminal, :media_state)
  end

  for ending <- [:owner_loss, :friendship, :logout, :revocation] do
    @ending ending
    @tag :controlled_camera
    @tag :ticket28_privacy
    @tag :ticket30_lifecycle
    test "video-present owner privacy survives #{@ending} without accepted transfer" do
      pair = start_pair("video_privacy", :video)
      caller = join_call(pair.caller_socket, pair.call_id)
      recipient = join_call(connect_socket(pair.recipient), pair.call_id)

      siblings =
        for scope <- [pair.caller, pair.recipient] do
          socket = connect_socket(scope)
          assert {:ok, _, inbox} = subscribe_and_join(socket, CallSignaling.inbox_topic())
          {join_call(socket, pair.call_id), inbox}
        end

      foreign = DiscordClone.AccountsFixtures.user_scope_fixture()

      assert {:error, %{reason: "not_found"}} =
               subscribe_and_join(connect_socket(foreign), CallSignaling.call_topic(pair.call_id))

      assert {:error, :not_admitted} =
               Calls.media_credentials(foreign, pair.call_id, caller.assigns.connection_id)

      accept(recipient, :video)
      await_pair(pair)

      for {sibling, _inbox} <- siblings do
        assert_reply push(sibling, "cancel_call", command(sibling)), :error, _
      end

      assert {:ok, %{state: :connecting}} = Calls.get_call(pair.caller, pair.call_id)
      assert_reply push(caller, "media_credentials", command(caller)), :ok, credentials
      assert_reply push(recipient, "media_credentials", command(recipient)), :ok, other
      first = connect_peer(caller, credentials, "privacy-first", true)
      second = connect_peer(recipient, other, "privacy-second", true)
      assert_push "call_active", %{call: %{state: :active}}, 2_000

      camera =
        media_command(caller, credentials, "privacy-first")
        |> Map.merge(%{
          "media_state_version" => 1,
          "microphone_muted" => false,
          "camera_enabled" => true
        })

      remote_camera =
        media_command(recipient, other, "privacy-second")
        |> Map.merge(%{
          "media_state_version" => 1,
          "microphone_muted" => false,
          "camera_enabled" => true
        })

      assert_reply push(caller, "local_media_state", camera), :ok, _
      assert_reply push(recipient, "local_media_state", remote_camera), :ok, _
      assert {:ok, %{media_state: accepted}} = Calls.get_call(pair.caller, pair.call_id)
      assert_private_video_pair(first, second, 10)

      owner_id = recipient.assigns.signaling_session_id

      assert_push "video_presentation",
                  %{
                    signaling_session_id: ^owner_id,
                    call_session_id: session_id,
                    video_presentation: %{epoch: epoch, camera_version: 1}
                  },
                  2_000

      assert session_id == other.call_session_id
      assert is_integer(epoch)

      for {sibling, inbox} <- siblings do
        for channel <- [sibling, inbox] do
          id = channel.assigns.signaling_session_id

          assert_push "call_active",
                      %{
                        signaling_session_id: ^id,
                        call: %{ownership: :elsewhere, media_state: ^accepted} = projection
                      },
                      2_000

          assert Enum.sort(Map.keys(projection)) ==
                   Enum.sort(
                     Calls.projection_keys() ++
                       [:role, :peer, :ownership, :answer_mode, :media_state]
                   )

          refute_push "video_presentation", %{signaling_session_id: ^id}, 0
          refute_push "video_route_status", %{signaling_session_id: ^id}, 0
        end

        forged = Map.put(camera, "signaling_session_id", sibling.assigns.signaling_session_id)

        for {event, payload} <- [
              {"media_credentials", command(sibling)},
              {"local_media_state", forged},
              {"renew", Map.take(forged, ~w(call_id signaling_session_id call_session_id))},
              {"offer",
               Map.merge(
                 Map.take(
                   forged,
                   ~w(call_id signaling_session_id call_session_id negotiation_id)
                 ),
                 %{
                   "description" =>
                     SessionDescription.to_json(
                       PeerConnection.get_local_description(first.browser)
                     )
                 }
               )},
              {"ice_candidate",
               Map.merge(
                 Map.take(
                   forged,
                   ~w(call_id signaling_session_id call_session_id negotiation_id)
                 ),
                 %{
                   "candidate" => %{
                     "candidate" => "candidate:1 1 udp 1 127.0.0.1 9 typ host",
                     "sdpMid" => "0",
                     "sdpMLineIndex" => 0
                   }
                 }
               )},
              {"leave_call", command(sibling)}
            ] do
          assert_reply push(sibling, event, payload), :error, _
        end

        send(
          sibling.channel_pid,
          {:call_media_event, credentials.call_session_id, sibling.assigns.signaling_session_id,
           nil, %{video_presentation: %{epoch: 99, camera_version: 1, rtp_timestamp: 90_000}}}
        )

        _ = :sys.get_state(sibling.channel_pid)
        id = sibling.assigns.signaling_session_id
        refute_push "video_presentation", %{signaling_session_id: ^id}, 0
      end

      for invalid <- [
            Map.put(camera, "call_id", Ecto.UUID.generate()),
            Map.put(camera, "signaling_session_id", "retired"),
            Map.put(camera, "call_session_id", other.call_session_id),
            Map.put(camera, "negotiation_id", "retired"),
            Map.put(camera, "owner_connection_id", caller.assigns.connection_id)
          ] do
        assert_reply push(
                       caller,
                       "local_media_state",
                       Map.put(invalid, "media_state_version", 2)
                     ),
                     :error,
                     _
      end

      assert {:error, :not_admitted} =
               Calls.signal_media(
                 foreign,
                 pair.call_id,
                 caller.assigns.connection_id,
                 :local_media_state,
                 camera
               )

      assert {:ok, %{state: :active, media_state: ^accepted}} =
               Calls.get_call(pair.caller, pair.call_id)

      assert AdmissionCoordinator.effective_occupancy() == 2
      sessions = Enum.map([pair.caller, pair.recipient], &admitted_session(pair, &1))
      leases = Enum.map(sessions, &:sys.get_state/1)
      assert_private_video_pair(first, second, 20)

      for {session, lease} <- Enum.zip(sessions, leases) do
        current = :sys.get_state(session)
        assert current.lease_ref == lease.lease_ref
        assert current.lease_deadline == lease.lease_deadline
      end

      monitors = resource_monitors(pair)

      channels = [
        caller,
        recipient | Enum.flat_map(siblings, fn {channel, inbox} -> [channel, inbox] end)
      ]

      for channel <- channels, do: Process.unlink(channel.channel_pid)
      recipient_monitor = Process.monitor(recipient.channel_pid)
      started = System.monotonic_time(:millisecond)
      end_video_owner(pair, caller, camera, @ending)
      assert_retired(monitors, started)

      if @ending == :friendship do
        assert_receive {:DOWN, ^recipient_monitor, :process, _, {:shutdown, :relationship_ended}}
        await_released(System.monotonic_time(:millisecond) + 2_000)
      else
        await_terminal(pair)
      end

      if @ending == :friendship do
        assert {:error, %{reason: "not_found"}} =
                 subscribe_and_join(
                   connect_socket(pair.caller),
                   CallSignaling.call_topic(pair.call_id)
                 )
      else
        reconnected = join_call(connect_socket(pair.caller), pair.call_id)

        assert_reply push(reconnected, "media_credentials", command(reconnected)), :error, %{
          reason: "not_admitted"
        }
      end

      if @ending != :friendship do
        assert_reply push(
                       recipient,
                       "local_media_state",
                       Map.put(remote_camera, "media_state_version", 2)
                     ),
                     :error,
                     _
      end

      assert AdmissionCoordinator.effective_occupancy() == 0

      if @ending == :friendship do
        assert {:error, :not_found} = Calls.get_call(pair.caller, pair.call_id)
      else
        assert {:ok, %{state: :terminal, terminal_outcome: :failed} = terminal} =
                 Calls.get_call(pair.caller, pair.call_id)

        assert {:ok, %{state: :terminal, terminal_outcome: :failed}} =
                 Calls.get_call(pair.recipient, pair.call_id)

        refute Map.has_key?(terminal, :media_state)
      end
    end
  end

  @tag :fake_transport
  @tag :ticket28_privacy
  test "owner Leave queued behind activation completes without a database/mailbox lock cycle" do
    pair = start_pair("owner_leave_race")
    caller = join_call(pair.caller_socket, pair.call_id)
    recipient = join_call(connect_socket(pair.recipient), pair.call_id)
    accept(recipient)
    await_pair(pair)
    [{server, _}] = Registry.lookup(DiscordClone.Calls.CallRegistry, pair.call_id)
    :ok = :sys.suspend(server)
    send(server, {:accepted_call_runtime, pair.call_id, :ready})
    reply = push(caller, "leave_call", command(caller))
    await_held_owner_leave(server, System.monotonic_time(:millisecond) + 2_000)
    :ok = :sys.resume(server)
    assert_reply reply, :ok, %{call: %{state: :terminal}}, 2_000
    await_terminal(pair)
  end

  @tag :fake_transport
  test "fake admission retains its explicit boundary and cannot bypass the complete state contract" do
    pair = start_pair("fake_complete_state")
    owner = join_call(pair.caller_socket, pair.call_id)
    recipient = join_call(connect_socket(pair.recipient), pair.call_id)
    accept(recipient)
    await_pair(pair)
    identity = AdmissionCoordinator.current_identity(pair.caller.user.id)
    assert identity.target.id == pair.call_id

    legacy =
      Map.merge(command(owner), %{
        "call_session_id" => identity.session_id,
        "media_state_version" => 1,
        "camera_enabled" => true
      })

    assert_reply push(owner, "local_media_state", legacy), :error, %{reason: "invalid_request"}

    complete = Map.merge(legacy, %{"microphone_muted" => false, "negotiation_id" => "fake"})
    assert_reply push(owner, "local_media_state", complete), :error, %{reason: "not_admitted"}

    assert_reply push(owner, "local_media_state", Map.put(complete, "camera_enabled", false)),
                 :error,
                 %{reason: "not_admitted"}

    assert {:ok, %{state: state}} = Calls.get_call(pair.caller, pair.call_id)
    assert state in [:connecting, :active]
    assert_reply push(recipient, "leave_call", command(recipient)), :ok, _
    await_terminal(pair)
    assert AdmissionCoordinator.current_identity(pair.caller.user.id) == nil
    assert AdmissionCoordinator.current_identity(pair.recipient.user.id) == nil
  end

  test "owner complete snapshots suppress real Opus without renegotiation and stale updates cannot unmute" do
    pair = start_pair("mute_real")
    caller = join_call(pair.caller_socket, pair.call_id)
    recipient = join_call(connect_socket(pair.recipient), pair.call_id)
    sibling = join_call(connect_socket(pair.caller), pair.call_id)
    accept(recipient)
    await_pair(pair)
    assert_reply push(caller, "media_credentials", command(caller)), :ok, credentials
    first = connect_peer(caller, credentials, "mute")
    assert_reply push(recipient, "media_credentials", command(recipient)), :ok, other
    second = connect_peer(recipient, other, "other")
    assert_push "call_active", _, 2_000

    payload =
      media_command(caller, credentials, "mute")
      |> Map.merge(%{
        "media_state_version" => 1,
        "microphone_muted" => true,
        "camera_enabled" => false
      })

    send_audio(first, <<1>>, 1)
    assert_audio(second, <<1>>)

    assert_reply push(caller, "local_media_state", payload), :ok, %{
      media_state_version: 1,
      microphone_muted: true,
      camera_enabled: false,
      negotiation_id: "mute"
    }

    for forged <- [
          Map.put(payload, "call_id", Ecto.UUID.generate()),
          Map.put(payload, "call_session_id", "stale"),
          Map.put(payload, "negotiation_id", "stale"),
          Map.put(payload, "signaling_session_id", "stale")
        ] do
      assert_reply push(caller, "local_media_state", forged), :error, _
    end

    assert_reply push(
                   sibling,
                   "local_media_state",
                   Map.put(payload, "signaling_session_id", sibling.assigns.signaling_session_id)
                 ),
                 :error,
                 %{reason: "not_admitted"}

    for invalid <- [
          Map.put(payload, "microphone_muted", nil),
          Map.put(payload, "microphone_muted", "false"),
          Map.put(payload, "camera_enabled", "false"),
          Map.put(payload, "camera_enabled", nil),
          Map.put(payload, "media_state_version", nil),
          Map.put(payload, "media_state_version", -1),
          Map.put(payload, "media_state_version", 1.5),
          Map.put(payload, "media_state_version", 9_007_199_254_740_992),
          Map.put(payload, "user_id", pair.caller.user.id),
          Map.put(payload, "owner_connection_id", caller.assigns.connection_id)
        ] do
      assert_reply push(caller, "local_media_state", invalid), :error, %{
        reason: "invalid_request"
      }
    end

    for field <- Map.keys(payload) do
      assert_reply push(caller, "local_media_state", Map.delete(payload, field)), :error, %{
        reason: "invalid_request"
      }
    end

    # A forged camera-on claim cannot consume the version or unmute audio.
    camera_on =
      Map.merge(payload, %{
        "media_state_version" => 9_007_199_254_740_991,
        "microphone_muted" => false,
        "camera_enabled" => true
      })

    assert_reply push(caller, "local_media_state", camera_on), :error, %{reason: "not_admitted"}

    stale = Map.put(payload, "microphone_muted", false)
    assert_reply push(caller, "local_media_state", stale), :error, %{reason: "stale_media_state"}

    assert_reply push(caller, "local_media_state", Map.put(stale, "media_state_version", 0)),
                 :error,
                 %{reason: "stale_media_state"}

    send_audio(first, <<2>>, 2)
    remote = second.browser
    refute_receive {:ex_webrtc, ^remote, {:rtp, _, _, _}}, 150
    send_audio(second, <<3>>)
    assert_audio(first, <<3>>)

    assert_reply push(caller, "local_media_state", Map.put(stale, "media_state_version", 2)),
                 :ok,
                 %{media_state_version: 2, microphone_muted: false, camera_enabled: false}

    send_audio(first, <<4>>, 3)
    assert_audio(second, <<4>>)

    maximum = Map.put(stale, "media_state_version", 9_007_199_254_740_991)

    assert_reply push(caller, "local_media_state", maximum), :ok, %{
      media_state_version: 9_007_199_254_740_991,
      microphone_muted: false,
      camera_enabled: false
    }

    assert_reply push(caller, "local_media_state", Map.put(maximum, "microphone_muted", true)),
                 :error,
                 %{reason: "stale_media_state"}

    send_audio(first, <<5>>, 4)
    assert_audio(second, <<5>>)
    assert_reply push(caller, "media_credentials", command(caller)), :ok, recovered
    assert recovered.call_session_id == credentials.call_session_id
    assert recovered.negotiation_id == "mute"
    assert {:ok, %{state: :active} = projection} = Calls.get_call(pair.caller, pair.call_id)
    refute Map.has_key?(projection, :microphone_muted)
    refute Map.has_key?(projection, :media_state_version)
    monitors = resource_monitors(pair)
    assert_reply push(recipient, "leave_call", command(recipient)), :ok, _

    assert_reply push(caller, "local_media_state", Map.put(payload, "media_state_version", 3)),
                 :error,
                 %{reason: "not_admitted"}

    assert_retired(monitors, System.monotonic_time(:millisecond))
    await_terminal(pair)
  end

  for {preference, effective_states} <- [
        {:unmuted, [true, true, false]},
        {:muted, [true, true, true, false]}
      ] do
    @preference preference
    @effective_states effective_states
    test "deafen and undeafen with #{@preference} preference retain real transport and suppress outgoing Opus" do
      pair = start_pair("deafen_#{@preference}")
      caller = join_call(pair.caller_socket, pair.call_id)
      recipient = join_call(connect_socket(pair.recipient), pair.call_id)
      accept(recipient)
      await_pair(pair)
      assert_reply push(caller, "media_credentials", command(caller)), :ok, credentials
      first = connect_peer(caller, credentials, "deafen")
      assert_reply push(recipient, "media_credentials", command(recipient)), :ok, other
      second = connect_peer(recipient, other, "remote")
      assert_push "call_active", _, 2_000
      remote = second.browser

      # The browser composition tests prove the independent local choices.
      # This boundary proves their effective mute trace on real negotiated RTP.
      for {muted, version} <- Enum.with_index(@effective_states, 1) do
        payload =
          media_command(caller, credentials, "deafen")
          |> Map.merge(%{
            "media_state_version" => version,
            "microphone_muted" => muted,
            "camera_enabled" => false
          })

        assert_reply push(caller, "local_media_state", payload), :ok, %{
          media_state_version: ^version,
          microphone_muted: ^muted,
          camera_enabled: false
        }

        audio = <<version>>
        send_audio(first, audio, version)

        if muted do
          refute_receive {:ex_webrtc, ^remote, {:rtp, _, _, _}}, 150
        else
          assert_audio(second, audio)
        end

        send_audio(second, <<version + 10>>, version)
        assert_audio(first, <<version + 10>>)
      end

      assert_reply push(caller, "media_credentials", command(caller)), :ok, recovered
      assert recovered.call_session_id == credentials.call_session_id
      assert recovered.negotiation_id == "deafen"
      assert {:ok, %{state: :active} = projection} = Calls.get_call(pair.caller, pair.call_id)

      for field <- [:workspace_muted, :moderation_muted, :local_deafened, :microphone_muted] do
        refute Map.has_key?(projection, field)
      end

      monitors = resource_monitors(pair)
      assert_reply push(recipient, "leave_call", command(recipient)), :ok, _
      assert_retired(monitors, System.monotonic_time(:millisecond))
      await_terminal(pair)
    end
  end

  test "a queued mute update cannot outlive terminal cleanup or affect a replacement" do
    {pair, owner, credentials} = admitted_caller("mute_terminal_race")
    _first = connect_peer(owner, credentials, "mute_race")
    session = admitted_session(pair, pair.caller)
    monitors = resource_monitors(pair)
    :ok = :sys.suspend(session)

    payload =
      media_command(owner, credentials, "mute_race")
      |> Map.merge(%{
        "media_state_version" => 1,
        "microphone_muted" => true,
        "camera_enabled" => false
      })

    update = push(owner, "local_media_state", payload)
    await_held_command(session, :local_media_state, System.monotonic_time(:millisecond) + 2_000)
    started = System.monotonic_time(:millisecond)
    assert {:ok, %{state: :terminal}} = Calls.leave_call(pair.recipient, pair.call_id)
    assert_reply update, :error, %{reason: "not_admitted"}, 2_000
    assert_retired(monitors, started)
    await_terminal(pair)
    {next, current, next_credentials} = admitted_caller("mute_replacement")
    _replacement = connect_peer(current, next_credentials, "replacement")
    assert_reply push(current, "local_media_state", payload), :error, %{reason: "invalid_request"}

    valid =
      media_command(current, next_credentials, "replacement")
      |> Map.merge(%{
        "media_state_version" => 1,
        "microphone_muted" => false,
        "camera_enabled" => false
      })

    assert_reply push(current, "local_media_state", valid), :ok, %{media_state_version: 1}
    close_channel(current)
    await_terminal(next)
  end

  for departing_role <- [:caller, :recipient] do
    @departing_role departing_role
    test "authenticated audio start, answer, packets and #{@departing_role} leave end both sides" do
      {caller_scope, recipient_scope, conversation, _friendship} =
        direct_conversation_fixture("audio_flow_#{@departing_role}")

      caller_socket = connect_socket(caller_scope)
      assert {:ok, _, inbox} = subscribe_and_join(caller_socket, CallSignaling.inbox_topic())

      assert_reply push(inbox, "start_call", %{
                     "signaling_session_id" => inbox.assigns.signaling_session_id,
                     "direct_conversation_id" => conversation.id,
                     "media_intent" => "audio"
                   }),
                   :ok,
                   %{call: %{call_id: call_id, state: :ringing}}

      pair = %{caller: caller_scope, recipient: recipient_scope, call_id: call_id}
      caller = join_call(caller_socket, call_id)
      recipient = join_call(connect_socket(recipient_scope), call_id)
      sibling = join_call(connect_socket(caller_scope), call_id)
      accept(recipient)
      await_pair(pair)

      assert_reply push(sibling, "media_credentials", command(sibling)), :error, %{
        reason: "not_admitted"
      }

      assert_reply push(caller, "media_credentials", command(caller)), :ok, first_credentials
      first = connect_peer(caller, first_credentials, "first")
      assert {:ok, %{state: :connecting}} = Calls.get_call(caller_scope, call_id)

      assert_reply push(recipient, "media_credentials", command(recipient)),
                   :ok,
                   second_credentials

      second = connect_peer(recipient, second_credentials, "second")
      assert_push "call_active", %{call: %{state: :active}}, 2_000
      assert {:ok, %{state: :active}} = Calls.get_call(caller_scope, call_id)
      send_audio(first, <<0xF8, 0xFF, 0xFE>>)
      assert_audio(second, <<0xF8, 0xFF, 0xFE>>)
      send_audio(second, <<0xF9, 0xFF, 0xFE, 0xFF, 0xFE>>)
      assert_audio(first, <<0xF9, 0xFF, 0xFE, 0xFF, 0xFE>>)

      monitors = resource_monitors(pair)
      started = System.monotonic_time(:millisecond)
      departing = if @departing_role == :caller, do: caller, else: recipient

      assert_reply push(departing, "leave_call", command(departing)), :ok, %{
        call: %{state: :terminal, terminal_outcome: :ended}
      }

      assert_retired(monitors, started)
      await_terminal(pair)

      for scope <- [caller_scope, recipient_scope] do
        assert AdmissionCoordinator.current_identity(scope.user.id) == nil

        assert {:ok, %{state: :terminal, terminal_outcome: :ended}} =
                 Calls.get_call(scope, call_id)
      end

      assert_reply push(caller, "media_credentials", command(caller)), :error, %{
        reason: "not_admitted"
      }
    end
  end

  test "selected fallback without a microphone gesture expires on the original pair deadline" do
    Application.put_env(:discord_clone, :pair_operation_timeouts, %{connect_ms: 800})
    on_exit(fn -> Application.delete_env(:discord_clone, :pair_operation_timeouts) end)
    pair = start_pair("fallback_no_gesture")
    preferred = join_call(pair.caller_socket, pair.call_id)
    fallback = join_call(connect_socket(pair.caller), pair.call_id)
    close_channel(preferred)
    recipient = join_call(connect_socket(pair.recipient), pair.call_id)
    accept(recipient)
    await_pair(pair)
    original = :sys.get_state(DiscordClone.Voice.SessionCoordinator).active_call.connect_deadline
    assert_reply push(fallback, "media_credentials", command(fallback)), :ok, credentials
    refute Map.has_key?(credentials, :negotiation_id)

    assert :sys.get_state(DiscordClone.Voice.SessionCoordinator).active_call.connect_deadline ==
             original

    monitors = resource_monitors(pair)
    assert_push "call_error", %{call: %{terminal_outcome: :failed}}, 2_000
    assert_retired(monitors, original)
    await_terminal(pair)

    assert {:ok, %{state: :terminal, terminal_outcome: :failed}} =
             Calls.get_call(pair.recipient, pair.call_id)
  end

  test "concurrent recipient accepts publish one real pair and only the winner receives credentials" do
    pair = start_pair("real_accept_tabs")
    preferred = join_call(pair.caller_socket, pair.call_id)
    caller_observer = join_call(connect_socket(pair.caller), pair.call_id)
    recipients = for _ <- 1..2, do: join_call(connect_socket(pair.recipient), pair.call_id)

    refs =
      for channel <- recipients do
        {push(channel, "accept_call", Map.put(command(channel), "answer_mode", "audio")), channel}
      end

    replies =
      for {ref, channel} <- refs do
        assert_reply ref, :ok, %{call: projection}, 2_000
        {projection.ownership, channel}
      end

    assert Enum.sort(Enum.map(replies, &elem(&1, 0))) == [:elsewhere, :self]
    {:self, winner} = List.keyfind(replies, :self, 0)
    {:elsewhere, loser} = List.keyfind(replies, :elsewhere, 0)
    await_pair(pair)
    assert AdmissionCoordinator.effective_occupancy() == 2

    for observer <- [caller_observer, loser] do
      assert_reply push(observer, "media_credentials", command(observer)), :error, %{
        reason: "not_admitted"
      }
    end

    connect_audio_pair(preferred, winner)

    peers = MapSet.new(PeerConnection.get_all_running())
    close_channel(loser)
    assert MapSet.new(PeerConnection.get_all_running()) == peers
    assert {:ok, %{state: :active}} = Calls.get_call(pair.caller, pair.call_id)
    monitors = resource_monitors(pair)
    started = System.monotonic_time(:millisecond)
    close_channel(winner)
    assert_retired(monitors, started)
    await_terminal(pair)

    assert {:ok, %{call: %{state: :terminal}}, rejoined} =
             subscribe_and_join(
               connect_socket(pair.recipient),
               CallSignaling.call_topic(pair.call_id)
             )

    assert_reply push(rejoined, "media_credentials", command(rejoined)), :error, %{
      reason: "not_admitted"
    }

    assert AdmissionCoordinator.effective_occupancy() == 0
  end

  test "selected fallback loss retires the connected recipient without promoting a later caller" do
    pair = start_pair("fallback_owner_exit")
    preferred = join_call(pair.caller_socket, pair.call_id)
    fallback = join_call(connect_socket(pair.caller), pair.call_id)
    observer = join_call(connect_socket(pair.caller), pair.call_id)
    close_channel(preferred)
    recipient = join_call(connect_socket(pair.recipient), pair.call_id)
    accept(recipient)
    await_pair(pair)
    assert_reply push(fallback, "media_credentials", command(fallback)), :ok, _
    assert_reply push(recipient, "media_credentials", command(recipient)), :ok, credentials
    _connected = connect_peer(recipient, credentials, "waiting_for_fallback")
    assert {:ok, %{state: :connecting}} = Calls.get_call(pair.recipient, pair.call_id)
    monitors = resource_monitors(pair)
    started = System.monotonic_time(:millisecond)
    close_channel(fallback)
    assert_retired(monitors, started)
    await_terminal(pair)

    assert_reply push(observer, "media_credentials", command(observer)), :error, %{
      reason: "not_admitted"
    }

    assert {:ok, %{call: %{state: :terminal}}, returning} =
             subscribe_and_join(pair.caller_socket, CallSignaling.call_topic(pair.call_id))

    assert_reply push(returning, "media_credentials", command(returning)), :error, %{
      reason: "not_admitted"
    }

    assert AdmissionCoordinator.current_identity(pair.recipient.user.id) == nil
  end

  test "renewal belongs to the exact admitted owner and current channel join" do
    {pair, owner, credentials} = admitted_caller("renew_owner")
    payload = Map.put(command(owner), "call_session_id", credentials.call_session_id)

    assert_reply push(owner, "renew", payload), :ok, %{
      call_session_id: id,
      renewal_interval_ms: 30_000,
      lease_duration_ms: 120_000
    }

    assert id == credentials.call_session_id

    sibling = join_call(connect_socket(pair.caller), pair.call_id)

    sibling_payload =
      Map.put(payload, "signaling_session_id", sibling.assigns.signaling_session_id)

    assert_reply push(sibling, "renew", sibling_payload), :error, %{reason: "not_admitted"}

    assert_reply push(owner, "renew", Map.put(payload, "call_session_id", "stale")), :error, %{
      reason: "not_admitted"
    }

    current = join_call(pair.caller_socket, pair.call_id)
    assert_reply push(current, "media_credentials", command(current)), :ok, recovered
    assert recovered.call_session_id == credentials.call_session_id
    assert_reply push(owner, "renew", payload), :error, %{reason: "not_admitted"}
    assert_reply push(current, "renew", payload), :error, %{reason: "invalid_request"}

    current_payload =
      Map.put(payload, "signaling_session_id", current.assigns.signaling_session_id)

    assert_reply push(current, "renew", current_payload), :ok, _
    close_channel(owner)
    assert_reply push(current, "renew", current_payload), :ok, _
    close_channel(current)
    await_terminal(pair)
  end

  test "renewal extends only its Session; discovery and stale timers do not refresh leases" do
    {pair, owner, credentials} = admitted_caller("renew_exact_lease")
    session = admitted_session(pair, pair.caller)
    other = admitted_session(pair, pair.recipient)
    original = :sys.get_state(session)
    other_lease = :sys.get_state(other).lease_ref
    remaining = Process.read_timer(original.lease_timer)
    assert remaining > 119_000 and remaining <= 120_000
    assert_reply push(owner, "media_credentials", command(owner)), :ok, ^credentials
    assert :sys.get_state(session).lease_ref == original.lease_ref
    payload = Map.put(command(owner), "call_session_id", credentials.call_session_id)
    assert_reply push(owner, "renew", payload), :ok, _
    renewed = :sys.get_state(session)
    refute renewed.lease_ref == original.lease_ref
    assert renewed.lease_deadline >= original.lease_deadline
    assert :sys.get_state(other).lease_ref == other_lease
    send(session, {:lease_expired, original.lease_ref})
    _ = :sys.get_state(session)

    assert_reply push(owner, "renew", Map.put(payload, "call_session_id", "retired")), :error, %{
      reason: "not_admitted"
    }

    assert :sys.get_state(session).lease_ref == renewed.lease_ref

    monitors = resource_monitors(pair)
    started = System.monotonic_time(:millisecond)
    send(session, {:lease_expired, renewed.lease_ref})
    assert_reply push(owner, "renew", payload), :error, %{reason: "not_admitted"}
    assert_retired(monitors, started)
    await_terminal(pair)
  end

  test "an expired lease cannot be renewed before its delayed expiry callback is handled" do
    {pair, owner, credentials} = admitted_caller("renew_expired")
    monitors = resource_monitors(pair)
    session = admitted_session(pair, pair.caller)

    :sys.replace_state(session, fn state ->
      %{state | lease_deadline: System.monotonic_time(:millisecond) - 1}
    end)

    started = System.monotonic_time(:millisecond)
    payload = Map.put(command(owner), "call_session_id", credentials.call_session_id)
    assert_reply push(owner, "renew", payload), :error, %{reason: "not_admitted"}
    assert_retired(monitors, started)
    await_terminal(pair)
  end

  test "renewals cannot extend disconnect grace or the original connecting deadline" do
    {pair, owner, credentials} = admitted_caller("renew_grace")
    session = admitted_session(pair, pair.caller)
    peer = :sys.get_state(session).connection.peer_connection
    original = :sys.get_state(DiscordClone.Voice.SessionCoordinator).active_call.connect_deadline
    send(session, {:ex_webrtc, peer, {:connection_state_change, :disconnected}})
    grace = :sys.get_state(session)
    payload = Map.put(command(owner), "call_session_id", credentials.call_session_id)
    assert_reply push(owner, "renew", payload), :ok, _
    renewed = :sys.get_state(session)
    assert renewed.disconnect_ref == grace.disconnect_ref
    assert renewed.disconnect_deadline == grace.disconnect_deadline

    assert :sys.get_state(DiscordClone.Voice.SessionCoordinator).active_call.connect_deadline ==
             original

    monitors = resource_monitors(pair)
    started = System.monotonic_time(:millisecond)
    send(session, {:disconnect_expired, grace.disconnect_ref})
    assert_retired(monitors, started)
    await_terminal(pair)
  end

  test "a renewal held across terminal leave cannot retain or revive either Session" do
    {pair, owner, credentials} = admitted_caller("renew_terminal_race")
    session = admitted_session(pair, pair.caller)
    monitors = resource_monitors(pair)
    :ok = :sys.suspend(session)
    payload = Map.put(command(owner), "call_session_id", credentials.call_session_id)
    renewal = push(owner, "renew", payload)
    await_held_command(session, :renew, System.monotonic_time(:millisecond) + 2_000)
    started = System.monotonic_time(:millisecond)
    assert {:ok, %{state: :terminal}} = Calls.leave_call(pair.recipient, pair.call_id)
    assert_reply renewal, :error, %{reason: "not_admitted"}, 2_000
    assert_retired(monitors, started)
    await_terminal(pair)
  end

  test "owner Channel death cleans abandoned setup without electing an observational sibling" do
    {pair, owner, credentials} = admitted_caller("renew_channel_loss")
    sibling = join_call(connect_socket(pair.caller), pair.call_id)
    monitors = resource_monitors(pair)
    started = System.monotonic_time(:millisecond)
    Process.unlink(owner.channel_pid)
    monitor = Process.monitor(owner.channel_pid)
    Process.exit(owner.channel_pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, _, :killed}
    assert_retired(monitors, started)
    await_terminal(pair)
    payload = Map.put(command(sibling), "call_session_id", credentials.call_session_id)
    assert_reply push(sibling, "renew", payload), :error, %{reason: "not_admitted"}

    {next, next_owner, next_credentials} = admitted_caller("renew_replacement")
    stale = Map.put(command(next_owner), "call_session_id", credentials.call_session_id)
    assert_reply push(next_owner, "renew", stale), :error, %{reason: "not_admitted"}
    current = Map.put(command(next_owner), "call_session_id", next_credentials.call_session_id)
    assert_reply push(next_owner, "renew", current), :ok, _
    close_channel(next_owner)
    await_terminal(next)
  end

  test "forged identities and sibling/inbox senders cannot mutate an admitted negotiation" do
    pair = start_pair("signal_denied")
    caller = join_call(pair.caller_socket, pair.call_id)
    recipient = join_call(connect_socket(pair.recipient), pair.call_id)
    sibling = join_call(connect_socket(pair.caller), pair.call_id)
    accept(recipient)
    await_pair(pair)
    assert_reply push(caller, "media_credentials", command(caller)), :ok, credentials
    offer = browser_offer(browser_peer())
    payload = media_command(caller, credentials, "one") |> Map.put("description", offer)

    for forged <- [
          %{"call_id" => Ecto.UUID.generate()},
          %{"signaling_session_id" => Ecto.UUID.generate()},
          %{"user_id" => pair.caller.user.id},
          %{"tab_id" => pair.caller_socket.assigns.connection_id},
          %{"negotiation_id" => String.duplicate("x", 129)},
          %{"description" => %{"type" => "offer", "sdp" => String.duplicate("x", 65_537)}}
        ] do
      assert_reply push(caller, "offer", Map.merge(payload, forged)), :error, %{
        reason: "invalid_request"
      }
    end

    for session_id <- [
          "forged",
          AdmissionCoordinator.current_identity(pair.recipient.user.id).session_id
        ] do
      forged = Map.put(payload, "call_session_id", session_id)

      assert_reply push(caller, "offer", forged), :error, %{reason: "not_admitted"}
    end

    sibling_payload =
      Map.put(payload, "signaling_session_id", sibling.assigns.signaling_session_id)

    assert_reply push(sibling, "offer", sibling_payload), :error, %{reason: "not_admitted"}

    assert {:ok, _, inbox} =
             subscribe_and_join(connect_socket(pair.caller), CallSignaling.inbox_topic())

    assert_reply push(inbox, "offer", payload), :error, %{reason: "unsupported_event"}
    assert_reply push(caller, "offer", payload), :ok, %{negotiation_id: "one"}

    assert_reply push(caller, "offer", Map.put(payload, "negotiation_id", "two")), :error, %{
      reason: "negotiation_already_active"
    }

    close_channel(caller)
    await_terminal(pair)
  end

  test "candidate queues and accepted counts stay bounded and stale negotiations are rejected" do
    {pair, caller, credentials} = admitted_caller("signal_limits")
    browser = browser_peer()
    offer = browser_offer(browser)
    assert_receive {:ex_webrtc, ^browser, {:ice_candidate, candidate}}
    candidate = ICECandidate.to_json(candidate)
    base = media_command(caller, credentials, "one")
    payload = Map.put(base, "candidate", candidate)

    for _ <- 1..16 do
      assert_reply push(caller, "ice_candidate", payload), :ok, %{negotiation_id: "one"}
    end

    assert_reply push(caller, "ice_candidate", payload), :error, %{
      reason: "pending_candidate_limit_reached"
    }

    assert_reply push(
                   caller,
                   "ice_candidate",
                   put_in(payload, ["candidate", "candidate"], String.duplicate("x", 8_193))
                 ),
                 :error,
                 %{reason: "invalid_request"}

    assert_reply push(caller, "offer", Map.put(base, "description", offer)), :ok, _

    for _ <- 1..48 do
      assert_reply push(caller, "ice_candidate", payload), :ok, _
    end

    assert_reply push(caller, "ice_candidate", payload), :error, %{
      reason: "candidate_limit_reached"
    }

    assert_reply push(caller, "ice_candidate", Map.put(payload, "negotiation_id", "stale")),
                 :error,
                 %{reason: "invalid_negotiation"}

    assert_reply push(caller, "ice_candidate", Map.put(base, "end_of_candidates", true)),
                 :error,
                 %{reason: "end_of_candidates_unsupported"}

    close_channel(caller)
    await_terminal(pair)
  end

  for action <- [:logout, :revocation] do
    @action action
    for intent <- [:audio, :video] do
      @intent intent
      @tag controlled_camera: intent == :video
      test "#{action} after #{intent} preserves independent authentication and unrelated Voice without browser cleanup acknowledgement" do
        pair = start_pair("#{@intent}_exit_#{@action}", @intent)
        owner = join_call(pair.caller_socket, pair.call_id)
        independent_socket = connect_socket(pair.caller)
        independent = join_call(independent_socket, pair.call_id)

        assert {:ok, _, independent_inbox} =
                 subscribe_and_join(independent_socket, CallSignaling.inbox_topic())

        recipient = join_call(connect_socket(pair.recipient), pair.call_id)
        accept(recipient, @intent)
        await_pair(pair)
        first_credentials = connect_audio_pair(owner, recipient)

        if @intent == :video do
          payload =
            media_command(owner, first_credentials, "first")
            |> Map.merge(%{
              "media_state_version" => 1,
              "microphone_muted" => false,
              "camera_enabled" => true
            })

          assert_reply push(owner, "local_media_state", payload), :ok, %{camera_enabled: true}

          assert {:ok, %{media_state: %{caller: %{camera_enabled: true}}}} =
                   Calls.get_call(pair.caller, pair.call_id)
        end

        voice_scope = DiscordClone.AccountsFixtures.user_scope_fixture()
        voice_channel = Ecto.UUID.generate()
        voice_signaling = Ecto.UUID.generate()

        assert {:ok, %{voice_session_id: voice_id}} =
                 DiscordClone.Voice.join(
                   voice_channel,
                   voice_scope.user.id,
                   voice_signaling,
                   self()
                 )

        voice_identity = AdmissionCoordinator.current_identity(voice_scope.user.id)
        on_exit(fn -> DiscordClone.Voice.end_channel_sessions(voice_channel) end)
        "users_sessions:" <> encoded = owner.assigns.user_session_topic
        {:ok, token} = Base.url_decode64(encoded)
        DiscordCloneWeb.Endpoint.subscribe(owner.assigns.user_session_topic)
        DiscordCloneWeb.Endpoint.subscribe(independent.assigns.user_session_topic)
        monitors = resource_monitors(pair)
        started = System.monotonic_time(:millisecond)

        case @action do
          :revocation ->
            assert :ok = Accounts.delete_user_session_token(token)
            DiscordCloneWeb.UserAuth.disconnect_sessions([%{token: token}])

          :logout ->
            Phoenix.ConnTest.build_conn()
            |> Plug.Test.init_test_session(%{
              user_token: token,
              live_socket_id: owner.assigns.user_session_topic
            })
            |> DiscordCloneWeb.UserAuth.log_out_user()
        end

        topic = owner.assigns.user_session_topic
        independent_topic = independent.assigns.user_session_topic
        assert_receive %Phoenix.Socket.Broadcast{event: "disconnect", topic: ^topic}

        refute_receive %Phoenix.Socket.Broadcast{event: "disconnect", topic: ^independent_topic},
                       0

        renewal = Map.put(command(owner), "call_session_id", first_credentials.call_session_id)
        assert_reply push(owner, "renew", renewal), :error, %{reason: "not_admitted"}
        assert_retired(monitors, started)
        assert AdmissionCoordinator.current_identity(voice_scope.user.id) == voice_identity

        assert :ok =
                 DiscordClone.Voice.renew_session(
                   voice_scope,
                   voice_channel,
                   voice_id,
                   voice_signaling
                 )

        assert :ok = DiscordClone.Voice.leave(voice_channel, voice_id)
        await_terminal(pair)

        assert_reply push(independent_inbox, "start_call", %{
                       "signaling_session_id" => independent_inbox.assigns.signaling_session_id,
                       "direct_conversation_id" => pair.conversation_id,
                       "media_intent" => "audio"
                     }),
                     :ok,
                     %{call: %{call_id: new_id, state: :ringing}}

        refute new_id == pair.call_id
        assert {:ok, %{state: :ringing}} = Calls.get_call(pair.caller, new_id)
        assert {:ok, _} = Calls.cancel_call(pair.caller, new_id)
      end
    end

    test "#{action} denies signaling on a still-running owner channel and retires both peers" do
      {pair, caller, credentials} = admitted_caller("signal_#{@action}")
      renewal = Map.put(command(caller), "call_session_id", credentials.call_session_id)
      assert_reply push(caller, "renew", renewal), :ok, _
      monitors = resource_monitors(pair)
      offer = browser_offer(browser_peer())
      "users_sessions:" <> encoded = caller.assigns.user_session_topic
      {:ok, token} = Base.url_decode64(encoded)

      case @action do
        :revocation ->
          assert :ok = Accounts.delete_user_session_token(token)

        :logout ->
          Phoenix.ConnTest.build_conn()
          |> Plug.Test.init_test_session(%{
            user_token: token,
            live_socket_id: caller.assigns.user_session_topic
          })
          |> DiscordCloneWeb.UserAuth.log_out_user()
      end

      payload = media_command(caller, credentials, "one") |> Map.put("description", offer)
      assert_reply push(caller, "renew", renewal), :error, %{reason: "not_admitted"}
      assert_reply push(caller, "offer", payload), :error, %{reason: "not_admitted"}
      assert_retired(monitors)
      await_terminal(pair)
      assert :error = connect(CallSocket, %{}, connect_info: %{session: %{"user_token" => token}})
    end
  end

  test "rejoin discovers an existing negotiation and fences the old channel and late server events" do
    {pair, old, credentials} = admitted_caller("signal_rejoin")

    original_deadline =
      :sys.get_state(DiscordClone.Voice.SessionCoordinator).active_call.connect_deadline

    offer = browser_offer(browser_peer())
    payload = media_command(old, credentials, "one") |> Map.put("description", offer)
    assert_reply push(old, "offer", payload), :ok, _
    current = join_call(pair.caller_socket, pair.call_id)
    peers = MapSet.new(PeerConnection.get_all_running())
    assert_reply push(current, "media_credentials", command(current)), :ok, recovered
    assert recovered.call_session_id == credentials.call_session_id
    assert recovered.negotiation_id == "one"
    assert MapSet.new(PeerConnection.get_all_running()) == peers

    assert :sys.get_state(DiscordClone.Voice.SessionCoordinator).active_call.connect_deadline ==
             original_deadline

    assert_reply push(old, "offer", payload), :error, %{reason: "not_admitted"}
    assert_reply push(old, "leave_call", command(old)), :error, %{reason: "stale"}
    assert {:ok, %{state: :connecting}} = Calls.get_call(pair.caller, pair.call_id)
    assert_reply push(current, "offer", payload), :error, %{reason: "invalid_request"}
    # Drain actual events issued to the old join before testing late-event rejection.
    drain_ice_events()

    stale =
      {:call_media_event, credentials.call_session_id, old.assigns.signaling_session_id, "one",
       %{candidate: %{"candidate" => "sentinel-stale"}}}

    send(current.channel_pid, stale)

    send(
      current.channel_pid,
      {:call_media_event, credentials.call_session_id, current.assigns.signaling_session_id,
       "stale", %{end_of_candidates: true}}
    )

    _ = :sys.get_state(current.channel_pid)
    refute_push "ice_candidate", %{candidate: %{"candidate" => "sentinel-stale"}}, 0
    refute_push "ice_candidate", %{negotiation_id: "stale"}, 0

    for {signaling_id, negotiation} <-
          [
            {old.assigns.signaling_session_id, "one"},
            {current.assigns.signaling_session_id, "stale"}
          ] do
      send(
        current.channel_pid,
        {:call_media_event, credentials.call_session_id, signaling_id, negotiation,
         %{video_route_status: :interrupted}}
      )
    end

    _ = :sys.get_state(current.channel_pid)
    refute_push "video_route_status", _, 0

    send(
      current.channel_pid,
      {:call_media_event, credentials.call_session_id, current.assigns.signaling_session_id,
       "one", %{video_route_status: :interrupted}}
    )

    assert_push "video_route_status", %{
      video_route_status: :interrupted,
      call_session_id: session_id,
      negotiation_id: "one"
    }

    for negotiation <- ["stale", "one"] do
      send(
        current.channel_pid,
        {:call_media_event, credentials.call_session_id, current.assigns.signaling_session_id,
         negotiation,
         %{video_presentation: %{epoch: 3, camera_version: 5, rtp_timestamp: 90_000}}}
      )

      _ = :sys.get_state(current.channel_pid)
      if negotiation == "stale", do: refute_push("video_presentation", _, 0)
    end

    assert_push "video_presentation", %{
      video_presentation: %{epoch: 3, camera_version: 5, rtp_timestamp: 90_000},
      call_session_id: ^session_id,
      negotiation_id: "one"
    }

    assert session_id == credentials.call_session_id
    close_channel(current)
    await_terminal(pair)
  end

  test "an offer held across channel replacement cannot reply or leave a stranded negotiation" do
    {pair, old, credentials} = admitted_caller("signal_held_rejoin")
    monitors = resource_monitors(pair)
    peer = server_peer(pair)
    :ok = :sys.suspend(peer)
    offer = browser_offer(browser_peer())
    payload = media_command(old, credentials, "one") |> Map.put("description", offer)
    ref = push(old, "offer", payload)
    await_held_offer(peer, System.monotonic_time(:millisecond) + 2_000)
    # Re-register the still-live socket connection while its old channel is blocked.
    current = join_call(pair.caller_socket, pair.call_id)
    :ok = :sys.resume(peer)
    assert_reply ref, :error, %{reason: "not_admitted"}, 2_000
    assert_retired(monitors)
    await_terminal(pair)

    assert_reply push(current, "media_credentials", command(current)), :error, %{
      reason: "not_admitted"
    }

    refute_reply ref, :ok, _, 0
  end

  @tag timeout: 25_000
  test "a held offer times out and releases both exact Sessions without a late answer" do
    {pair, caller, credentials} = admitted_caller("signal_timeout")
    monitors = resource_monitors(pair)
    peer = server_peer(pair)
    :ok = :sys.suspend(peer)
    offer = browser_offer(browser_peer())
    payload = media_command(caller, credentials, "one") |> Map.put("description", offer)
    started = System.monotonic_time(:millisecond)
    ref = push(caller, "offer", payload)
    assert_reply ref, :error, %{reason: "not_admitted"}, 11_000
    assert System.monotonic_time(:millisecond) - started < 11_000
    assert_retired(monitors)
    await_terminal(pair)
    refute_reply ref, :ok, _, 0
  end

  test "an incompatible offer retires the pair and cannot signal a later Call" do
    {pair, caller, credentials} = admitted_caller("signal_bad_layout")
    monitors = resource_monitors(pair)
    browser = browser_peer()
    assert {:ok, _} = PeerConnection.add_transceiver(browser, MediaStreamTrack.new(:audio))
    assert {:ok, offer} = PeerConnection.create_offer(browser)

    payload =
      media_command(caller, credentials, "one")
      |> Map.put("description", SessionDescription.to_json(offer))

    assert_reply push(caller, "offer", payload), :error, %{reason: "not_admitted"}, 2_000
    assert_retired(monitors)
    await_terminal(pair)
    {next, owner, next_credentials} = admitted_caller("signal_after_failure")

    assert_reply push(
                   owner,
                   "offer",
                   Map.put(payload, "signaling_session_id", owner.assigns.signaling_session_id)
                 ),
                 :error,
                 %{reason: "invalid_request"}

    assert_reply push(owner, "media_credentials", command(owner)), :ok, ^next_credentials
    close_channel(owner)
    await_terminal(next)
  end

  defp drain_ice_events do
    receive do
      %Phoenix.Socket.Message{event: "ice_candidate"} -> drain_ice_events()
    after
      0 -> :ok
    end
  end

  defp resource_monitors(pair) do
    for scope <- [pair.caller, pair.recipient],
        {:ok, identity, target} =
          AdmissionCoordinator.call_media_session(pair.call_id, scope.user.id),
        {:ok, session} =
          DiscordClone.Media.DirectCallTarget.session(target, scope.user.id, identity.session_id),
        resource <- DirectCallSession.resources(session),
        do: {resource, Process.monitor(resource)}
  end

  defp await_held_offer(peer, deadline) do
    {:messages, messages} = Process.info(peer, :messages)

    unless Enum.any?(messages, fn
             {:"$gen_call", _from, {:set_remote_description, _}} -> true
             _ -> false
           end) do
      assert System.monotonic_time(:millisecond) < deadline
      :erlang.yield()
      await_held_offer(peer, deadline)
    end
  end

  defp await_held_owner_leave(server, deadline) do
    {:messages, messages} = Process.info(server, :messages)

    unless Enum.any?(messages, fn
             {:"$gen_call", _, _request} ->
               true

             _ ->
               false
           end) do
      assert System.monotonic_time(:millisecond) < deadline
      :erlang.yield()
      await_held_owner_leave(server, deadline)
    end
  end

  defp await_held_command(session, operation, deadline) do
    {:messages, messages} = Process.info(session, :messages)

    unless Enum.any?(messages, fn
             {:"$gen_call", _from, {^operation, _}} -> true
             _ -> false
           end) do
      assert System.monotonic_time(:millisecond) < deadline
      :erlang.yield()
      await_held_command(session, operation, deadline)
    end
  end

  defp server_peer(pair) do
    {peer, _} =
      Enum.find(resource_monitors(pair), fn {pid, _} ->
        Registry.lookup(ExWebRTC.Registry, pid) != []
      end)

    peer
  end

  defp assert_retired(monitors, started \\ System.monotonic_time(:millisecond)) do
    deadline = started + 5_000

    for {pid, monitor} <- monitors do
      assert_receive {:DOWN, ^monitor, :process, ^pid, _},
                     max(deadline - System.monotonic_time(:millisecond), 0)
    end
  end

  defp admitted_session(pair, scope) do
    assert {:ok, identity, target} =
             AdmissionCoordinator.call_media_session(pair.call_id, scope.user.id)

    assert {:ok, session} = DirectCallTarget.session(target, scope.user.id, identity.session_id)
    session
  end

  defp admitted_caller(suffix) do
    pair = start_pair(suffix)
    caller = join_call(pair.caller_socket, pair.call_id)
    recipient = join_call(connect_socket(pair.recipient), pair.call_id)
    accept(recipient)
    await_pair(pair)
    assert_reply push(caller, "media_credentials", command(caller)), :ok, credentials
    {pair, caller, credentials}
  end

  defp connect_audio_pair(caller, recipient) do
    assert_reply push(caller, "media_credentials", command(caller)), :ok, first_credentials
    assert_reply push(recipient, "media_credentials", command(recipient)), :ok, second_credentials
    first = connect_peer(caller, first_credentials, "first")
    second = connect_peer(recipient, second_credentials, "second")
    assert_push "call_active", %{call: %{state: :active}}, 2_000
    send_audio(first, <<0xF8, 0xFF, 0xFE>>)
    assert_audio(second, <<0xF8, 0xFF, 0xFE>>)
    send_audio(second, <<0xF9, 0xFF, 0xFE, 0xFF, 0xFE>>)
    assert_audio(first, <<0xF9, 0xFF, 0xFE, 0xFF, 0xFE>>)
    first_credentials
  end

  defp connect_peer(channel, credentials, negotiation, camera? \\ false) do
    browser = browser_peer()
    offer = browser_offer(browser, camera?)
    assert_receive {:ex_webrtc, ^browser, {:ice_candidate, candidate}}
    payload = media_command(channel, credentials, negotiation)

    assert_reply push(
                   channel,
                   "ice_candidate",
                   Map.put(payload, "candidate", ICECandidate.to_json(candidate))
                 ),
                 :ok,
                 _

    assert_reply push(channel, "offer", Map.put(payload, "description", offer)),
                 :ok,
                 answer,
                 2_000

    assert answer.call_id == channel.assigns.call_id
    assert answer.call_session_id == credentials.call_session_id
    assert answer.signaling_session_id == channel.assigns.signaling_session_id
    assert answer.negotiation_id == negotiation

    assert :ok =
             PeerConnection.set_remote_description(
               browser,
               SessionDescription.from_json(answer.description)
             )

    apply_server_candidates(browser, channel, credentials, negotiation)
    assert_receive {:ex_webrtc, ^browser, {:connection_state_change, :connected}}, 5_000
    [audio, video] = PeerConnection.get_transceivers(browser)
    if camera?, do: assert(video.sender.track != nil), else: assert(video.sender.track == nil)

    %{
      browser: browser,
      source: audio.sender.track.id,
      destination: audio.receiver.track.id,
      video_source: video.sender.track && video.sender.track.id,
      video_destination: video.receiver.track.id
    }
  end

  defp end_video_owner(pair, caller, camera, ending) do
    case ending do
      :owner_loss ->
        close_channel(caller)

      :friendship ->
        assert :ok = DiscordClone.Friendships.remove_friend(pair.caller, pair.friendship.id)

      action ->
        "users_sessions:" <> encoded = caller.assigns.user_session_topic
        {:ok, token} = Base.url_decode64(encoded)

        if action == :revocation do
          assert :ok = Accounts.delete_user_session_token(token)
        else
          Phoenix.ConnTest.build_conn()
          |> Plug.Test.init_test_session(%{
            user_token: token,
            live_socket_id: caller.assigns.user_session_topic
          })
          |> DiscordCloneWeb.UserAuth.log_out_user()
        end

        assert_reply push(
                       caller,
                       "renew",
                       Map.take(camera, ~w(call_id signaling_session_id call_session_id))
                     ),
                     :error,
                     %{reason: "not_admitted"}
    end
  end

  defp assert_private_video_pair(first, second, sequence) do
    for {source, destination, tag} <- [{first, second, 1}, {second, first, 2}] do
      payload = <<0x10, 0, tag>>

      assert :ok =
               PeerConnection.send_rtp(
                 source.browser,
                 source.video_source,
                 ExRTP.Packet.new(payload,
                   sequence_number: sequence,
                   timestamp: sequence * 90_000,
                   marker: true
                 )
               )

      browser = destination.browser
      track = destination.video_destination
      assert_receive {:ex_webrtc, ^browser, {:rtp, ^track, nil, packet}}, 2_000
      assert packet.payload == payload
      own_browser = source.browser
      own_track = source.video_destination
      refute_receive {:ex_webrtc, ^own_browser, {:rtp, ^own_track, nil, %{payload: ^payload}}}, 0
      opus = <<0xF8, 0xFF, 0xFE, tag>>
      send_audio(source, opus, sequence)
      assert_audio(destination, opus)
    end
  end

  defp send_audio(endpoint, payload, sequence \\ 10) do
    assert :ok =
             PeerConnection.send_rtp(
               endpoint.browser,
               endpoint.source,
               ExRTP.Packet.new(payload, sequence_number: sequence, timestamp: sequence * 960)
             )
  end

  defp assert_audio(%{browser: browser, destination: track}, expected) do
    assert_receive {:ex_webrtc, ^browser, {:rtp, ^track, nil, packet}}, 2_000
    assert packet.payload == expected
  end

  defp browser_peer do
    start_supervised!(%{
      id: make_ref(),
      restart: :temporary,
      start: {PeerConnection, :start_link, [[ice_servers: [], controlling_process: self()]]}
    })
  end

  defp browser_offer(browser, camera? \\ false) do
    assert {:ok, _} =
             PeerConnection.add_transceiver(browser, MediaStreamTrack.new(:audio),
               direction: :sendrecv
             )

    video = if camera?, do: MediaStreamTrack.new(:video), else: :video
    assert {:ok, _} = PeerConnection.add_transceiver(browser, video, direction: :sendrecv)
    assert {:ok, offer} = PeerConnection.create_offer(browser)
    assert :ok = PeerConnection.set_local_description(browser, offer)
    assert_receive {:ex_webrtc, ^browser, {:ice_gathering_state_change, :complete}}, 2_000
    browser |> PeerConnection.get_local_description() |> SessionDescription.to_json()
  end

  defp media_command(channel, credentials, negotiation) do
    Map.merge(command(channel), %{
      "call_session_id" => credentials.call_session_id,
      "negotiation_id" => negotiation
    })
  end

  defp apply_server_candidates(browser, channel, credentials, negotiation) do
    assert_push "ice_candidate", event, 2_000
    assert event.call_id == channel.assigns.call_id
    assert event.call_session_id == credentials.call_session_id
    assert event.signaling_session_id == channel.assigns.signaling_session_id
    assert event.negotiation_id == negotiation

    case event do
      %{candidate: candidate} ->
        assert :ok = PeerConnection.add_ice_candidate(browser, ICECandidate.from_json(candidate))
        apply_server_candidates(browser, channel, credentials, negotiation)

      %{end_of_candidates: true} ->
        :ok
    end
  end

  defp close_channel(channel) do
    Process.unlink(channel.channel_pid)
    monitor = Process.monitor(channel.channel_pid)
    assert_reply leave(channel), :ok
    assert_receive {:DOWN, ^monitor, :process, _, _}
  end

  defp start_pair(suffix, intent \\ :audio) do
    {caller, recipient, conversation, friendship} = direct_conversation_fixture(suffix)
    caller_socket = connect_socket(caller)

    assert {:ok, %{call: call}} =
             Calls.start_call(caller, conversation.id, intent,
               caller_connection_id: caller_socket.assigns.connection_id
             )

    %{
      caller: caller,
      recipient: recipient,
      caller_socket: caller_socket,
      call_id: call.call_id,
      conversation_id: conversation.id,
      friendship: friendship
    }
  end

  defp connect_socket(scope) do
    token = Accounts.generate_user_session_token(scope.user)

    assert {:ok, socket} =
             connect(CallSocket, %{}, connect_info: %{session: %{"user_token" => token}})

    socket
  end

  defp join_call(socket, call_id) do
    assert {:ok, _projection, channel} =
             subscribe_and_join(socket, CallSignaling.call_topic(call_id))

    channel
  end

  defp command(channel) do
    %{
      "call_id" => channel.assigns.call_id,
      "signaling_session_id" => channel.assigns.signaling_session_id
    }
  end

  defp accept(channel, answer_mode \\ :audio) do
    assert_reply push(
                   channel,
                   "accept_call",
                   Map.put(command(channel), "answer_mode", Atom.to_string(answer_mode))
                 ),
                 :ok,
                 %{call: %{state: :connecting}},
                 2_000
  end

  defp await_terminal(pair), do: await_terminal(pair, System.monotonic_time(:millisecond) + 2_000)

  defp await_terminal(pair, deadline) do
    case Calls.get_call(pair.caller, pair.call_id) do
      {:ok, %{state: :terminal}} ->
        await_released(deadline)

      _ ->
        assert System.monotonic_time(:millisecond) < deadline
        :erlang.yield()
        await_terminal(pair, deadline)
    end
  end

  defp await_released(deadline) do
    if AdmissionCoordinator.effective_occupancy() != 0 do
      assert System.monotonic_time(:millisecond) < deadline
      :erlang.yield()
      await_released(deadline)
    end
  end

  defp await_pair(pair) do
    await_pair(pair, System.monotonic_time(:millisecond) + 2_000)
  end

  defp await_pair(pair, deadline) do
    if AdmissionCoordinator.current_identity(pair.caller.user.id) &&
         AdmissionCoordinator.current_identity(pair.recipient.user.id) do
      :ok
    else
      assert System.monotonic_time(:millisecond) < deadline
      :erlang.yield()
      await_pair(pair, deadline)
    end
  end
end
