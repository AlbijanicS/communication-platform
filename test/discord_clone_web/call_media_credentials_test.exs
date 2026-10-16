defmodule DiscordCloneWeb.CallMediaCredentialsTest do
  use DiscordClone.DataCase, async: false

  import DiscordClone.AccountsFixtures
  import ExUnit.CaptureLog
  import DiscordClone.CallsFixtures
  import Phoenix.ChannelTest

  alias DiscordClone.Accounts
  alias DiscordClone.Calls
  alias DiscordClone.Media.AdmissionCoordinator
  alias DiscordClone.MediaFixtures
  alias DiscordCloneWeb.{CallSignaling, CallSocket}

  @endpoint DiscordCloneWeb.Endpoint

  setup do
    start_supervised!(DiscordClone.Calls.Supervisor)
    DiscordClone.Calls.CallCoordinator.begin_recovery()
    await_recovery_finished()
    MediaFixtures.setup_coordinator_pair_state!()

    previous =
      for key <- [:accepted_call_runtime, :direct_call_transport], into: %{} do
        {key, Application.fetch_env(:discord_clone, key)}
      end

    Application.put_env(
      :discord_clone,
      :accepted_call_runtime,
      DiscordClone.Calls.PairAdmissionRuntime
    )

    Application.put_env(:discord_clone, :direct_call_transport, :real)

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

  test "only admitted owner channels discover the existing real Sessions and ICE configuration" do
    pair = start_pair("creds_owner")
    caller_sibling = join_call(connect_socket(pair.caller), pair.call_id)
    caller = join_call(pair.caller_socket, pair.call_id)
    recipient = join_call(connect_socket(pair.recipient), pair.call_id)
    sibling = join_call(connect_socket(pair.recipient), pair.call_id)

    assert_reply push(caller, "media_credentials", command(caller)), :error, %{
      reason: "not_admitted"
    }

    assert AdmissionCoordinator.current_identity(pair.caller.user.id) == nil

    accept(recipient)
    await_pair(pair)

    assert_reply push(caller, "media_credentials", command(caller)), :ok, first
    assert_reply push(recipient, "media_credentials", command(recipient)), :ok, second

    assert first.call_id == pair.call_id
    assert first.signaling_session_id == caller.assigns.signaling_session_id

    assert first.call_session_id ==
             AdmissionCoordinator.current_identity(pair.caller.user.id).session_id

    assert second.call_session_id ==
             AdmissionCoordinator.current_identity(pair.recipient.user.id).session_id

    refute first.call_session_id == second.call_session_id

    assert first.ice_config == %{
             ice_mode: "disabled",
             ice_servers: [],
             ice_transport_policy: "all"
           }

    assert Map.keys(first) |> Enum.sort() == [
             :call_id,
             :call_session_id,
             :ice_config,
             :signaling_session_id
           ]

    assert_reply push(sibling, "media_credentials", command(sibling)), :error, %{
      reason: "not_admitted"
    }

    assert_reply push(caller_sibling, "media_credentials", command(caller_sibling)), :error, %{
      reason: "not_admitted"
    }

    peers = MapSet.new(ExWebRTC.PeerConnection.get_all_running())
    assert_reply push(caller, "media_credentials", command(caller)), :ok, ^first
    assert_reply push(recipient, "media_credentials", command(recipient)), :ok, ^second
    assert MapSet.new(ExWebRTC.PeerConnection.get_all_running()) == peers
    assert AdmissionCoordinator.effective_occupancy() == 2
    assert {:ok, %{state: :connecting}} = Calls.get_call(pair.caller, pair.call_id)
  end

  test "caller fallback selects the earliest observer only after acceptance" do
    pair = start_pair("creds_fallback")
    first = join_call(connect_socket(pair.caller), pair.call_id)
    later = join_call(connect_socket(pair.caller), pair.call_id)
    recipient = join_call(connect_socket(pair.recipient), pair.call_id)

    assert_reply push(first, "media_credentials", command(first)), :error, %{
      reason: "not_admitted"
    }

    accept(recipient)
    await_pair(pair)

    assert_reply push(first, "media_credentials", command(first)), :ok, credentials

    assert_reply push(later, "media_credentials", command(later)), :error, %{
      reason: "not_admitted"
    }

    preferred = join_call(pair.caller_socket, pair.call_id)
    assert preferred.assigns.last_call.ownership == :elsewhere

    assert_reply push(preferred, "media_credentials", command(preferred)), :error, %{
      reason: "not_admitted"
    }

    assert credentials.call_session_id ==
             AdmissionCoordinator.current_identity(pair.caller.user.id).session_id
  end

  test "competing video and audio answers retain one recipient and the initiating caller" do
    enable_camera_lifecycle()
    pair = start_pair("creds_video_race", :video)
    early_caller = join_call(connect_socket(pair.caller), pair.call_id)
    caller = join_call(pair.caller_socket, pair.call_id)
    video = join_call(connect_socket(pair.recipient), pair.call_id)
    audio = join_call(connect_socket(pair.recipient), pair.call_id)

    video_ref = push(video, "accept_call", Map.put(command(video), "answer_mode", "video"))
    audio_ref = push(audio, "accept_call", Map.put(command(audio), "answer_mode", "audio"))
    assert_reply video_ref, :ok, %{call: video_result}, 2_000
    assert_reply audio_ref, :ok, %{call: audio_result}, 2_000
    await_pair(pair)

    assert video_result.answer_mode == audio_result.answer_mode
    assert video_result.media_intent == :video
    assert audio_result.media_intent == :video

    {winner, loser} =
      if video_result.answer_mode == :video, do: {video, audio}, else: {audio, video}

    assert_reply push(winner, "media_credentials", command(winner)), :ok, credentials

    assert credentials.call_session_id ==
             AdmissionCoordinator.current_identity(pair.recipient.user.id).session_id

    assert_reply push(loser, "media_credentials", command(loser)), :error, %{
      reason: "not_admitted"
    }

    assert_reply push(early_caller, "media_credentials", command(early_caller)), :error, %{
      reason: "not_admitted"
    }

    assert_reply push(caller, "media_credentials", command(caller)), :ok
    assert AdmissionCoordinator.effective_occupancy() == 2
    close_channel(loser)

    assert {:ok, %{state: :connecting, answer_mode: mode}} =
             Calls.get_call(pair.caller, pair.call_id)

    assert mode == video_result.answer_mode
    assert_reply push(winner, "media_credentials", command(winner)), :ok, ^credentials

    close_channel(winner)
    await_terminal(pair)
    rejoined = join_call(connect_socket(pair.recipient), pair.call_id)

    assert_reply push(
                   rejoined,
                   "accept_call",
                   Map.put(command(rejoined), "answer_mode", "video")
                 ),
                 :ok,
                 %{call: %{state: :terminal, terminal_outcome: :failed}}

    assert_reply push(rejoined, "media_credentials", command(rejoined)), :error, %{
      reason: "not_admitted"
    }

    assert AdmissionCoordinator.current_identity(pair.caller.user.id) == nil
    assert AdmissionCoordinator.current_identity(pair.recipient.user.id) == nil
    assert AdmissionCoordinator.effective_occupancy() == 0
  end

  test "video fallback ownership cannot extend the original connection deadline or transfer" do
    enable_camera_lifecycle()
    previous = Application.fetch_env(:discord_clone, :pair_operation_timeouts)
    Application.put_env(:discord_clone, :pair_operation_timeouts, %{connect_ms: 1_500})
    on_exit(fn -> restore_env(:pair_operation_timeouts, previous) end)
    pair = start_pair("creds_video_deadline", :video)
    selected = join_call(connect_socket(pair.caller), pair.call_id)
    observer = join_call(connect_socket(pair.caller), pair.call_id)
    recipient = join_call(connect_socket(pair.recipient), pair.call_id)
    original_budget = System.monotonic_time(:millisecond) + 2_000

    assert_reply push(
                   recipient,
                   "accept_call",
                   Map.put(command(recipient), "answer_mode", "video")
                 ),
                 :ok,
                 %{call: %{state: :connecting}},
                 2_000

    await_pair(pair)
    # Exercise the selected tab near the original 1,500 ms expiry. A reset
    # here would exceed the acceptance-time budget, rather than passing under
    # a fresh timeout measured from the last credential read.
    timer = Process.send_after(self(), :late_fallback_gesture, 1_000)
    on_exit(fn -> Process.cancel_timer(timer) end)
    assert_receive :late_fallback_gesture, 1_500
    assert_reply push(selected, "media_credentials", command(selected)), :ok

    assert_reply push(observer, "media_credentials", command(observer)), :error, %{
      reason: "not_admitted"
    }

    preferred = join_call(pair.caller_socket, pair.call_id)

    assert_reply push(preferred, "media_credentials", command(preferred)), :error, %{
      reason: "not_admitted"
    }

    # No caller offer: selection and credential reads do not reset pair setup.
    await_terminal(pair, original_budget)

    assert {:ok, %{state: :terminal, terminal_outcome: :failed}} =
             Calls.get_call(pair.caller, pair.call_id)

    assert_reply push(selected, "media_credentials", command(selected)), :error, %{
      reason: "not_admitted"
    }

    assert AdmissionCoordinator.current_identity(pair.caller.user.id) == nil
    assert AdmissionCoordinator.current_identity(pair.recipient.user.id) == nil
    assert AdmissionCoordinator.effective_occupancy() == 0
  end

  test "channel rejoin fences the old process and Signaling Session without another media allocation" do
    pair = start_pair("creds_rejoin")
    old = join_call(pair.caller_socket, pair.call_id)
    recipient = join_call(connect_socket(pair.recipient), pair.call_id)
    accept(recipient)
    await_pair(pair)
    assert_reply push(old, "media_credentials", command(old)), :ok, original
    peers = MapSet.new(ExWebRTC.PeerConnection.get_all_running())

    current = join_call(pair.caller_socket, pair.call_id)
    assert_reply push(current, "media_credentials", command(current)), :ok, rejoined
    assert rejoined.call_session_id == original.call_session_id
    refute rejoined.signaling_session_id == original.signaling_session_id

    assert_reply push(current, "media_credentials", command(old)), :error, %{
      reason: "invalid_request"
    }

    assert_reply push(old, "media_credentials", command(old)), :error, %{reason: "not_admitted"}
    close_channel(old)
    assert_reply push(current, "media_credentials", command(current)), :ok, ^rejoined
    assert MapSet.new(ExWebRTC.PeerConnection.get_all_running()) == peers

    close_channel(current)
    departed = join_call(pair.caller_socket, pair.call_id)

    assert_reply push(departed, "media_credentials", command(departed)), :error, %{
      reason: "not_admitted"
    }

    assert_reply push(recipient, "media_credentials", command(recipient)), :error, %{
      reason: "not_admitted"
    }
  end

  test "forged, wrong User, old Call and Session identities cannot discover or renew ownership" do
    pair = start_pair("creds_forged")
    caller = join_call(pair.caller_socket, pair.call_id)
    recipient = join_call(connect_socket(pair.recipient), pair.call_id)
    outsider = user_scope_fixture(user_fixture(username: "creds_outsider"))
    outsider_socket = connect_socket(outsider)

    assert {:error, %{reason: "not_found"}} =
             subscribe_and_join(outsider_socket, CallSignaling.call_topic(pair.call_id))

    accept(recipient)
    await_pair(pair)

    connection_id = pair.caller_socket.assigns.connection_id

    assert {:error, :not_admitted} =
             Calls.media_credentials(pair.caller, pair.call_id, connection_id)

    assert {:error, :not_admitted} =
             Calls.media_credentials(outsider, pair.call_id, connection_id)

    assert {:error, :unauthenticated} = Calls.media_credentials(nil, pair.call_id, connection_id)
    assert :ok = Calls.register_connection(pair.call_id, outsider.user.id, :caller, connection_id)
    assert_reply push(caller, "media_credentials", command(caller)), :ok, original

    for forged <- [
          %{"owner" => "self"},
          %{"connection_id" => connection_id},
          %{"user_id" => pair.caller.user.id},
          %{"call_session_id" => original.call_session_id},
          %{"call_id" => Ecto.UUID.generate()},
          %{"signaling_session_id" => Ecto.UUID.generate()}
        ] do
      assert_reply push(caller, "media_credentials", Map.merge(command(caller), forged)),
                   :error,
                   %{reason: "invalid_request"}
    end

    sibling = join_call(connect_socket(pair.recipient), pair.call_id)
    accept(sibling)

    assert_reply push(sibling, "media_credentials", command(sibling)), :error, %{
      reason: "not_admitted"
    }

    assert_reply push(
                   sibling,
                   "renew",
                   Map.put(command(sibling), "call_session_id", original.call_session_id)
                 ),
                 :error,
                 %{reason: "not_admitted"}

    close_channel(recipient)
    await_terminal(pair)

    assert_reply push(caller, "media_credentials", command(caller)), :error, %{
      reason: "not_admitted"
    }

    next = start_pair("creds_next")
    next_caller = join_call(next.caller_socket, next.call_id)
    next_recipient = join_call(connect_socket(next.recipient), next.call_id)
    accept(next_recipient)
    await_pair(next)

    assert_reply push(caller, "media_credentials", command(caller)), :error, %{
      reason: "not_admitted"
    }

    assert_reply push(next_caller, "media_credentials", command(next_caller)), :ok, replacement
    refute replacement.call_session_id == original.call_session_id
  end

  test "neither side receives credentials while the second real Session is still starting" do
    pair = start_pair("creds_partial")
    caller = join_call(pair.caller_socket, pair.call_id)
    recipient = join_call(connect_socket(pair.recipient), pair.call_id)
    observer = self()
    barrier = make_ref()

    Application.put_env(:discord_clone, :call_target_startup_control, %{
      barrier: fn
        :session_starting, %{user_id: user_id} when user_id == pair.recipient.user.id ->
          send(observer, {:starting_second, self(), barrier})

          receive do
            {:resume, ^barrier} -> :ok
          end

        _, _ ->
          :ok
      end
    })

    on_exit(fn -> Application.delete_env(:discord_clone, :call_target_startup_control) end)
    accept(recipient)
    assert_receive {:starting_second, worker, ^barrier}, 2_000
    on_exit(fn -> send(worker, {:resume, barrier}) end)

    assert_reply push(caller, "media_credentials", command(caller)), :error, %{
      reason: "not_admitted"
    }

    assert_reply push(recipient, "media_credentials", command(recipient)), :error, %{
      reason: "not_admitted"
    }

    send(worker, {:resume, barrier})
    await_pair(pair)
    assert_reply push(caller, "media_credentials", command(caller)), :ok, _
    assert_reply push(recipient, "media_credentials", command(recipient)), :ok, _
  end

  test "admitted TURN secrets reach owners only and stay out of inboxes, projections, logs and diagnostics" do
    credential = "sentinel-call-turn-credential"
    username = "sentinel-call-turn-user"
    provider_secret = "sentinel-call-provider-secret"
    expiry = DateTime.add(DateTime.utc_now(), 300, :second)

    DiscordClone.VoiceICEConfigurationHelpers.put_voice_ice_configuration(
      mode: :turn_only,
      stun_urls: [],
      provider: DiscordClone.Voice.FakeICEProvider,
      provider_secret: provider_secret,
      provider_options: [
        results:
          {:ok,
           %{
             urls: ["turn:127.0.0.1:3478?transport=udp"],
             username: username,
             credential: credential,
             expires_at: expiry
           }}
      ]
    )

    pair = start_pair("creds_private")
    caller = join_call(pair.caller_socket, pair.call_id)
    recipient = join_call(connect_socket(pair.recipient), pair.call_id)
    sibling = join_call(connect_socket(pair.caller), pair.call_id)

    assert {:ok, _inbox_projection, inbox} =
             subscribe_and_join(pair.caller_socket, CallSignaling.inbox_topic())

    observer = self()
    handler = "call-credentials-#{System.unique_integer()}"
    event = [:discord_clone, :call_signaling, :operation]

    :ok =
      :telemetry.attach(
        handler,
        event,
        fn _, measurements, metadata, _ ->
          send(observer, {:credential_diagnostic, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    logs =
      capture_log(fn ->
        accept(recipient)
        await_pair(pair)
        assert_reply push(caller, "media_credentials", command(caller)), :ok, credentials
        send(observer, {:owner_credentials, credentials})

        assert_reply push(sibling, "media_credentials", command(sibling)), :error, %{
          reason: "not_admitted"
        }

        assert_reply push(inbox, "media_credentials", command(caller)), :error, %{
          reason: "unsupported_event"
        }

        assert_push "call_connecting", projection
        send(observer, {:public_projection, projection})
      end)

    assert_receive {:owner_credentials, credentials}

    assert [%{urls: _, username: ^username, credential: ^credential}] =
             credentials.ice_config.ice_servers

    assert_receive {:public_projection, projection}
    assert {:ok, public_call} = Calls.get_call(pair.caller, pair.call_id)
    assert {:ok, current_call} = Calls.current_call(pair.caller)

    public =
      inspect(
        {projection, public_call, current_call, caller.assigns.last_call,
         sibling.assigns.last_call}
      )

    diagnostics = drain_diagnostics([])

    assert Enum.any?(diagnostics, fn {_, metadata} ->
             metadata.operation == "media_credentials" and metadata.outcome == :accepted
           end)

    for secret <- [
          credential,
          username,
          provider_secret,
          inspect(expiry),
          credentials.call_session_id,
          pair.caller_socket.assigns.connection_id,
          inspect(caller.channel_pid)
        ] do
      refute public =~ secret
      refute logs =~ secret
      refute inspect(diagnostics) =~ secret
    end

    for {measurements, metadata} <- diagnostics do
      assert Map.keys(measurements) -- [:duration_ms] == []

      assert Map.keys(metadata) --
               [:operation, :outcome, :error_code, :decoded_request_byte_count] == []
    end
  end

  defp close_channel(channel) do
    Process.unlink(channel.channel_pid)
    monitor = Process.monitor(channel.channel_pid)
    assert_reply leave(channel), :ok
    assert_receive {:DOWN, ^monitor, :process, _, _}
  end

  defp drain_diagnostics(acc) do
    receive do
      {:credential_diagnostic, measurements, metadata} ->
        drain_diagnostics([{measurements, metadata} | acc])
    after
      0 -> acc
    end
  end

  defp enable_camera_lifecycle do
    previous = Application.fetch_env(:discord_clone, :direct_call_camera_lifecycle_enabled)
    Application.put_env(:discord_clone, :direct_call_camera_lifecycle_enabled, true)
    on_exit(fn -> restore_env(:direct_call_camera_lifecycle_enabled, previous) end)
  end

  defp restore_env(key, {:ok, value}), do: Application.put_env(:discord_clone, key, value)
  defp restore_env(key, :error), do: Application.delete_env(:discord_clone, key)

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

  defp accept(channel) do
    assert_reply push(channel, "accept_call", Map.put(command(channel), "answer_mode", "audio")),
                 :ok,
                 %{call: %{state: :connecting}},
                 2_000
  end

  defp await_terminal(pair), do: await_terminal(pair, System.monotonic_time(:millisecond) + 2_000)

  defp await_terminal(pair, deadline) do
    case Calls.get_call(pair.caller, pair.call_id) do
      {:ok, %{state: :terminal}} ->
        :ok

      _ ->
        assert System.monotonic_time(:millisecond) < deadline
        :erlang.yield()
        await_terminal(pair, deadline)
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
