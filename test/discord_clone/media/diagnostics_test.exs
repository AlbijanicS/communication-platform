defmodule DiscordClone.Media.DiagnosticsTest do
  use ExUnit.Case, async: true

  alias DiscordClone.Media.Diagnostics

  test "video diagnostics coalesce categories and discard every private or unbounded field" do
    event = [:discord_clone, :call_media, :video]
    handler = make_ref()
    parent = self()

    :ok =
      :telemetry.attach(handler, event, fn _, m, d, _ -> send(parent, {:video, m, d}) end, nil)

    on_exit(fn -> :telemetry.detach(handler) end)
    secret = "sdp-ice-credential-device-private-id"

    observations = %{
      dropped_frames: 9,
      mailbox_len: 2_000_000,
      recoveries: -1,
      departure_bytes: secret,
      sdp: secret,
      owner: self(),
      error: secret
    }

    history = Diagnostics.observe_video(%{}, :route, :interrupted, observations, 0)
    assert_receive {:video, %{dropped_frames: 9, mailbox_len: 1_000_000}, metadata}

    assert metadata == %{
             component: :forwarder,
             operation: :route,
             media_kind: :video,
             stage: :delivery,
             outcome: :interrupted
           }

    history =
      Enum.reduce(1..100, history, fn _, h ->
        Diagnostics.observe_video(h, :route, :interrupted, observations, 9_999)
      end)

    refute_receive {:video, _, _}, 0
    history = Diagnostics.observe_video(history, :route, :active, %{recoveries: 1}, 9_999)
    assert_receive {:video, %{recoveries: 1}, %{outcome: :active}}
    _ = Diagnostics.observe_video(history, :route, :interrupted, observations, 10_000)
    assert_receive {:video, _, %{outcome: :interrupted}}
    _ = Diagnostics.observe_video(history, secret, secret, observations, 20_000)
    refute_receive {:video, _, _}, 0
  end

  test "TWCC aggregates clipped feedback and wrapped departure history without packet identities" do
    alias ExRTCP.Packet.TransportFeedback.CC

    cc = %CC{
      sender_ssrc: 123,
      media_ssrc: 456,
      base_sequence_number: 65_535,
      packet_status_count: 3,
      reference_time: 99,
      fb_pkt_count: 8,
      packet_chunks: [
        %CC.RunLength{status_symbol: :not_received, run_length: 1},
        %CC.StatusVector{
          symbols: [
            :small_delta,
            :large_delta,
            :not_received,
            :not_received,
            :not_received,
            :not_received,
            :not_received
          ]
        }
      ]
    }

    assert Diagnostics.feedback_summary(cc) ==
             %{base: 65_535, count: 3, received_packets: 2, lost_packets: 1}

    assert Diagnostics.departure_summary(
             %{65_535 => {10_000, 100}, 0 => {20_000, 200}, 3 => {30_000, 300}},
             65_535,
             3
           ) == %{
             departure_packets: 3,
             departure_bytes: 600,
             departure_span_ms: 20,
             reported_packets: 3,
             matched_packets: 2
           }
  end

  test "queue observation reads counts from a suspended process without consuming private messages" do
    owner = start_supervised!({Agent, fn -> nil end})
    :ok = :sys.suspend(owner)
    secret = "raw-opus-sdp-ice-192.0.2.17-turn-credential-device-owner-message"
    Agent.cast(owner, fn _ -> {secret, self()} end)
    Agent.cast(owner, fn _ -> {secret, self()} end)

    try do
      assert Diagnostics.queue_snapshot(owner) == %{status: :available, mailbox_len: 2}
      assert Diagnostics.queue_snapshot(owner) == %{status: :available, mailbox_len: 2}
      refute inspect(Diagnostics.queue_snapshot(owner)) =~ secret
      refute inspect(Diagnostics.queue_snapshot(owner)) =~ inspect(owner)
    after
      :ok = :sys.resume(owner)
    end
  end

  test "queue observation distinguishes an empty queue from retired resources" do
    owner = start_supervised!({Agent, fn -> nil end})
    assert Diagnostics.queue_snapshot(owner) == %{status: :available, mailbox_len: 0}
    monitor = Process.monitor(owner)
    stop_supervised!(Agent)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :shutdown}
    assert Diagnostics.queue_snapshot(owner) == %{status: :unavailable}
  end
end
