defmodule DiscordClone.Voice.DiagnosticsLoggerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias DiscordClone.Voice.Diagnostics

  test "logs bounded Voice failures without caller-supplied secrets" do
    secret = "temporary-turn-credential-that-must-not-be-logged"

    logs =
      capture_log(fn ->
        Diagnostics.emit("connection_state", :accepted,
          connection_state: :failed,
          provider_secret: secret
        )
      end)

    assert logs =~ "Voice diagnostic operation=connection_state"
    assert logs =~ "connection_state=failed"
    refute logs =~ secret
  end

  test "restarts after an abnormal exit leaves the telemetry handler attached" do
    original_pid = Process.whereis(DiscordClone.Voice.DiagnosticsLogger)
    monitor_ref = Process.monitor(original_pid)

    Process.exit(original_pid, :kill)

    assert_receive {:DOWN, ^monitor_ref, :process, ^original_pid, :killed}
    _ = :sys.get_state(DiscordCloneWeb.Telemetry)

    restarted_pid = Process.whereis(DiscordClone.Voice.DiagnosticsLogger)
    assert is_pid(restarted_pid)
    assert restarted_pid != original_pid

    logs =
      capture_log(fn ->
        DiscordClone.Media.Diagnostics.emit_call_connection_state(:failed)
      end)

    assert logs =~ "Call diagnostic operation=connection_state connection_state=failed"
  end

  test "Call lifecycle logs exclude media, credentials, messages and private identities" do
    secret = "raw-opus-sdp-ice-192.0.2.17-turn-credential-device-owner-message"
    event = [:discord_clone, :call_media, :connection_state]

    logs =
      capture_log(fn ->
        DiscordClone.Media.Diagnostics.emit_call_connection_state(:disconnected)
        DiscordClone.Media.Diagnostics.emit_call_connection_state(secret)

        :telemetry.execute(event, %{raw_media: secret}, %{
          connection_state: :closed,
          call_id: secret,
          signaling_session_id: secret,
          owner: self(),
          sdp: secret,
          ice: secret,
          device: secret,
          message: secret
        })

        :telemetry.execute(event, %{}, %{connection_state: secret})
      end)

    assert logs =~ "Call diagnostic operation=connection_state connection_state=disconnected"
    assert logs =~ "Call diagnostic operation=connection_state connection_state=closed"
    refute logs =~ secret
    refute logs =~ inspect(self())
    assert length(String.split(logs, "Call diagnostic")) == 3
  end

  test "video logger revalidates forged measurements and metadata before logging" do
    secret = "sdp-ice-credential-private-device"

    logs =
      capture_log(fn ->
        :telemetry.execute(
          [:discord_clone, :call_media, :video],
          %{dropped_frames: 8, mailbox_len: 2_000_000, raw_media: secret},
          %{
            operation: :route,
            outcome: :interrupted,
            component: secret,
            stage: secret,
            route_category: secret,
            call_id: secret,
            error_code: secret
          }
        )
      end)

    assert logs =~ "component=forwarder"
    assert logs =~ "stage=delivery"
    assert logs =~ "dropped_frames=8"
    assert logs =~ "mailbox_len=1000000"
    refute logs =~ secret
  end

  test "the attached logger does no packet logging for existing Voice media counters" do
    counts = %{
      inbound_packet_count: 1,
      forwarded_packet_count: 1,
      dropped_packet_count: 0,
      dropped_media_count: 0
    }

    assert capture_log(fn ->
             Diagnostics.emit_media(:rtp_received, counts)

             Diagnostics.emit_route(
               :rtp_forwarded,
               Map.take(counts, [:forwarded_packet_count, :dropped_packet_count])
             )
           end) == ""
  end
end
