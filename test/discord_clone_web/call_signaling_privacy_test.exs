defmodule DiscordCloneWeb.CallSignalingPrivacyTest do
  use DiscordClone.DataCase, async: false

  import DiscordClone.CallsFixtures
  import ExUnit.CaptureLog
  import Phoenix.ChannelTest

  alias DiscordClone.Accounts
  alias DiscordClone.Calls
  alias DiscordClone.Friendships
  alias DiscordCloneWeb.CallSignaling
  alias DiscordCloneWeb.CallSocket

  @endpoint DiscordCloneWeb.Endpoint
  @inbox_topic CallSignaling.inbox_topic()
  @telemetry_event [:discord_clone, :call_signaling, :operation]
  @allowed_metadata_keys MapSet.new([
                           :operation,
                           :outcome,
                           :error_code,
                           :decoded_request_byte_count
                         ])
  @allowed_measurement_keys MapSet.new([:duration_ms])
  @allowed_operations MapSet.new(
                        ~w(connect join projection start_call decline_call cancel_call accept_call leave_call media_credentials offer ice_candidate ice_route renew local_media_state unsupported_request termination)
                      )

  setup do
    start_supervised!(DiscordClone.Calls.Supervisor)
    DiscordClone.Calls.CallCoordinator.begin_recovery()
    await_recovery_finished()
    :ok
  end

  test "application diagnostics and logs omit identities, topics, and payloads" do
    {caller_scope, recipient_scope, direct_conversation, _friendship} =
      direct_conversation_fixture("privacy")

    token = Accounts.generate_user_session_token(caller_scope.user)
    test_process = self()
    handler_id = "call-signaling-privacy-#{System.unique_integer()}"

    :ok =
      :telemetry.attach(
        handler_id,
        @telemetry_event,
        fn event, measurements, metadata, _config ->
          send(test_process, {:diagnostic, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    normal_logs =
      capture_log(fn -> run_inbox_traffic(token, caller_scope, direct_conversation) end)

    {started, join_payload, socket, call_signaling_session_id, call_connection_id} =
      assert_receive_traffic()

    assert {:ok, _uuid} = Ecto.UUID.cast(call_connection_id)
    refute call_connection_id == join_payload.signaling_session_id
    refute call_connection_id == call_signaling_session_id
    refute call_connection_id == socket.id

    previous_level = Logger.level()
    Logger.configure(level: :debug)

    debug_logs =
      try do
        capture_log(fn -> run_inbox_traffic(token, caller_scope, direct_conversation) end)
      after
        Logger.configure(level: previous_level)
      end

    # Logger.configure is required: process level cannot lower the global :warning bar,
    # so an empty capture would make the debug refutes pass vacuously.
    assert debug_logs =~ "SELECT "

    diagnostics = drain_diagnostics([])
    assert diagnostics != []

    operations =
      MapSet.new(
        Enum.map(diagnostics, fn {_event, _measurements, metadata} -> metadata.operation end)
      )

    for {_event, measurements, metadata} <- diagnostics do
      assert MapSet.subset?(MapSet.new(Map.keys(metadata)), @allowed_metadata_keys)
      assert MapSet.subset?(MapSet.new(Map.keys(measurements)), @allowed_measurement_keys)
      assert metadata.operation in @allowed_operations
      refute metadata.operation == "SENTINEL_EVENT_NAME"
    end

    assert "start_call" in operations
    assert "decline_call" in operations
    assert "cancel_call" in operations
    assert "accept_call" in operations
    assert "leave_call" in operations
    assert "offer" in operations
    assert "ice_candidate" in operations
    assert "ice_route" in operations
    assert "renew" in operations
    assert "local_media_state" in operations
    assert "unsupported_request" in operations

    signaling_secrets = [
      join_payload.signaling_session_id,
      inspect(token),
      Base.url_encode64(token),
      socket.id,
      @inbox_topic,
      CallSignaling.call_topic(started.call_id),
      call_signaling_session_id,
      "SENTINEL_EVENT_NAME",
      "SENTINEL_CALL_EVENT",
      "sentinel-turn-credential",
      "sentinel-sdp",
      "sentinel-direct-conversation",
      "sentinel-call-session",
      "sentinel-negotiation",
      "sentinel-ice-ufrag",
      "users_sessions:"
    ]

    identity_secrets =
      signaling_secrets ++
        [
          caller_scope.user.id,
          recipient_scope.user.id,
          started.call_id,
          started.direct_conversation_id
        ]

    connection_secrets = [
      call_connection_id,
      inspect(call_connection_id),
      Base.url_encode64(call_connection_id)
    ]

    refute_secrets(inspect(diagnostics), identity_secrets ++ connection_secrets)
    refute_secrets(normal_logs, identity_secrets ++ connection_secrets)
    refute_secrets(application_debug_logs(debug_logs), signaling_secrets ++ connection_secrets)
    refute inspect(started) =~ call_connection_id
    refute application_debug_logs(debug_logs) =~ "JOINED"
    refute application_debug_logs(debug_logs) =~ "INCOMING"
  end

  test "Friendship-removal Call-topic close emits allowlisted termination without identities" do
    {caller_scope, _recipient_scope, direct_conversation, friendship} =
      direct_conversation_fixture("privacy_rm")

    token = Accounts.generate_user_session_token(caller_scope.user)
    test_process = self()
    handler_id = "call-signaling-privacy-rm-#{System.unique_integer()}"

    :ok =
      :telemetry.attach(
        handler_id,
        @telemetry_event,
        fn event, measurements, metadata, _config ->
          send(test_process, {:diagnostic, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:ok, socket} =
             connect(CallSocket, %{}, connect_info: %{session: %{"user_token" => token}})

    assert {:ok, _inbox, _inbox_channel} = subscribe_and_join(socket, @inbox_topic)

    assert {:ok, %{call: started}} =
             Calls.start_call(caller_scope, direct_conversation.id, :audio)

    assert {:ok, _call_join, call_channel} =
             subscribe_and_join(socket, CallSignaling.call_topic(started.call_id))

    Process.unlink(call_channel.channel_pid)
    ref = Process.monitor(call_channel.channel_pid)

    logs =
      capture_log(fn ->
        assert :ok = Friendships.remove_friend(caller_scope, friendship.id)
        assert_push "call_ended", ended
        assert ended.call.terminal_outcome == :relationship_ended
        assert_receive {:DOWN, ^ref, :process, _pid, {:shutdown, :relationship_ended}}
      end)

    diagnostics = drain_diagnostics([])
    assert diagnostics != []

    operations =
      MapSet.new(
        Enum.map(diagnostics, fn {_event, _measurements, metadata} -> metadata.operation end)
      )

    assert "termination" in operations
    assert "projection" in operations

    for {_event, measurements, metadata} <- diagnostics do
      assert MapSet.subset?(MapSet.new(Map.keys(metadata)), @allowed_metadata_keys)
      assert MapSet.subset?(MapSet.new(Map.keys(measurements)), @allowed_measurement_keys)
      assert metadata.operation in @allowed_operations
    end

    secrets = [
      started.call_id,
      CallSignaling.call_topic(started.call_id),
      @inbox_topic,
      caller_scope.user.id,
      inspect(token),
      "relationship_ended",
      "call_ended"
    ]

    refute_secrets(inspect(diagnostics), secrets)
    refute_secrets(logs, secrets)
  end

  defp run_inbox_traffic(token, caller_scope, direct_conversation) do
    assert {:ok, socket} =
             connect(CallSocket, %{"user_id" => caller_scope.user.id},
               connect_info: %{session: %{"user_token" => token}}
             )

    assert {:ok, join_payload, channel} = subscribe_and_join(socket, @inbox_topic)

    assert_reply push(channel, "SENTINEL_EVENT_NAME", %{
                   "credential" => "sentinel-turn-credential",
                   "nested" => %{"sdp" => "v=0 sentinel-sdp"}
                 }),
                 :error,
                 %{reason: "unsupported_event"}

    assert_reply push(channel, "start_call", %{
                   "signaling_session_id" => "forged-#{join_payload.signaling_session_id}",
                   "direct_conversation_id" => "sentinel-direct-conversation",
                   "media_intent" => "audio",
                   "nested" => %{"sdp" => "v=0 sentinel-sdp"}
                 }),
                 :error,
                 %{reason: "invalid_request"}

    assert_reply push(channel, "start_call", %{
                   "signaling_session_id" => join_payload.signaling_session_id,
                   "direct_conversation_id" => direct_conversation.id,
                   "media_intent" => "audio"
                 }),
                 :ok,
                 %{call: started}

    assert {:ok, call_join, call_channel} =
             subscribe_and_join(socket, CallSignaling.call_topic(started.call_id))

    assert_reply push(call_channel, "SENTINEL_CALL_EVENT", %{
                   "credential" => "sentinel-turn-credential",
                   "signaling_session_id" => "sentinel-call-session"
                 }),
                 :error,
                 %{reason: "unsupported_event"}

    assert_reply push(call_channel, "accept_call", %{
                   "signaling_session_id" => call_join.signaling_session_id,
                   "call_id" => started.call_id
                 }),
                 :error,
                 %{reason: "invalid_request"}

    assert_reply push(call_channel, "leave_call", %{
                   "signaling_session_id" => call_join.signaling_session_id,
                   "call_id" => started.call_id
                 }),
                 :error,
                 %{reason: "stale"}

    assert_reply push(call_channel, "offer", %{
                   "signaling_session_id" => call_join.signaling_session_id,
                   "call_id" => started.call_id,
                   "call_session_id" => "sentinel-call-session",
                   "negotiation_id" => "sentinel-negotiation",
                   "description" => %{"type" => "offer", "sdp" => "v=0 sentinel-sdp"}
                 }),
                 :error,
                 %{reason: "not_admitted"}

    assert_reply push(call_channel, "ice_candidate", %{
                   "signaling_session_id" => call_join.signaling_session_id,
                   "call_id" => started.call_id,
                   "call_session_id" => "sentinel-call-session",
                   "negotiation_id" => "sentinel-negotiation",
                   "candidate" => %{
                     "candidate" => "candidate:1 1 udp 1 127.0.0.1 9 typ host",
                     "sdpMid" => "0",
                     "sdpMLineIndex" => 0,
                     "usernameFragment" => "sentinel-ice-ufrag"
                   }
                 }),
                 :error,
                 %{reason: "not_admitted"}

    assert_reply push(call_channel, "ice_route", %{
                   "signaling_session_id" => call_join.signaling_session_id,
                   "call_id" => started.call_id,
                   "call_session_id" => "sentinel-call-session",
                   "route_category" => "turn_relay",
                   "protocol" => "udp",
                   "duration_ms" => 12
                 }),
                 :error,
                 %{reason: "not_admitted"}

    assert_reply push(call_channel, "renew", %{
                   "signaling_session_id" => call_join.signaling_session_id,
                   "call_id" => started.call_id,
                   "call_session_id" => "sentinel-call-session"
                 }),
                 :error,
                 %{reason: "not_admitted"}

    assert_reply push(call_channel, "local_media_state", %{
                   "signaling_session_id" => call_join.signaling_session_id,
                   "call_id" => started.call_id,
                   "call_session_id" => "sentinel-call-session",
                   "media_state_version" => 1,
                   "camera_enabled" => true,
                   "microphone_muted" => false,
                   "negotiation_id" => "opaque-negotiation"
                 }),
                 :error,
                 %{reason: "not_admitted"}

    assert_reply push(call_channel, "offer", %{
                   "signaling_session_id" => "sentinel-call-session",
                   "call_id" => started.call_id,
                   "call_session_id" => "sentinel-call-session",
                   "negotiation_id" => "sentinel-negotiation",
                   "description" => %{"type" => "offer", "sdp" => "v=0 sentinel-sdp"},
                   "credential" => "sentinel-turn-credential"
                 }),
                 :error,
                 %{reason: "invalid_request"}

    assert_reply push(call_channel, "cancel_call", %{
                   "signaling_session_id" => "sentinel-call-session",
                   "call_id" => started.call_id
                 }),
                 :error,
                 %{reason: "invalid_request"}

    assert_reply push(call_channel, "decline_call", %{
                   "signaling_session_id" => call_join.signaling_session_id,
                   "call_id" => started.call_id,
                   "nested" => %{"sdp" => "v=0 sentinel-sdp"}
                 }),
                 :error,
                 %{reason: "invalid_request"}

    send(self(), {:traffic, started, join_payload, socket, call_join.signaling_session_id})
  end

  defp assert_receive_traffic do
    assert_receive {:traffic, started, join_payload, socket, call_signaling_session_id}
    {started, join_payload, socket, call_signaling_session_id, socket.assigns.connection_id}
  end

  defp application_debug_logs(logs) do
    logs
    |> String.split("\n")
    |> Enum.reject(fn line ->
      String.contains?(line, "QUERY OK") or
        String.contains?(line, "SELECT ") or
        String.contains?(line, "INSERT ") or
        String.contains?(line, "begin []")
    end)
    |> Enum.join("\n")
  end

  defp refute_secrets(text, secrets) do
    for fragment <- secrets do
      refute text =~ fragment
    end
  end

  defp drain_diagnostics(acc) do
    receive do
      {:diagnostic, event, measurements, metadata} ->
        drain_diagnostics([{event, measurements, metadata} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
