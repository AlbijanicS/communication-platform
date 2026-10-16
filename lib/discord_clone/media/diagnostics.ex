defmodule DiscordClone.Media.Diagnostics do
  @moduledoc """
  Lightweight media observations. These functions run in the calling process;
  they do not start a sampler. Optional Call TWCC snapshots use bounded
  asynchronous native requests at most once per ten seconds.
  """

  @connection_event [:discord_clone, :call_media, :connection_state]

  @video_event [:discord_clone, :call_media, :video]
  @video_operations %{route: {:forwarder, :delivery}, twcc: {:session, :transport}}
  @video_outcomes [:active, :recovering, :interrupted, :sampled, :unavailable]
  @video_counts [
    :interruptions,
    :recoveries,
    :dropped_frames,
    :discarded_packets,
    :mailbox_len,
    :received_packets,
    :lost_packets,
    :reported_packets,
    :matched_packets,
    :departure_packets,
    :departure_bytes,
    :departure_span_ms
  ]

  # Caller-owned, fixed-category history; no identities, global cache or timer.
  # Each category emits at most once per ten seconds, including route rebuilds.
  def observe_video(
        history,
        operation,
        outcome,
        observations,
        now \\ System.monotonic_time(:millisecond)
      ) do
    key = {operation, outcome}

    if Map.has_key?(@video_operations, operation) and outcome in @video_outcomes and
         (not Map.has_key?(history, key) or now - history[key] >= 10_000) do
      observations = if is_function(observations, 0), do: observations.(), else: observations

      case safe_video(operation, outcome, observations) do
        {measurements, metadata} ->
          :telemetry.execute(@video_event, measurements, metadata)
          Map.put(history, key, now)

        nil ->
          history
      end
    else
      history
    end
  end

  # Reused by the attached logger: even forged telemetry cannot bypass this boundary.
  def safe_video(operation, outcome, observations)
      when is_map_key(@video_operations, operation) and outcome in @video_outcomes and
             is_map(observations) do
    {component, stage} = Map.fetch!(@video_operations, operation)

    counts =
      Enum.reduce(@video_counts, %{}, fn key, acc ->
        case Map.get(observations, key) do
          count when is_integer(count) and count >= 0 -> Map.put(acc, key, min(count, 1_000_000))
          _ -> acc
        end
      end)

    metadata = %{
      component: component,
      operation: operation,
      media_kind: :video,
      stage: stage,
      outcome: outcome
    }

    metadata =
      if operation == :twcc, do: Map.put(metadata, :media_kind, :audio_video), else: metadata

    category = Map.get(observations, :route_category)

    metadata =
      if category in [:host_direct, :reflexive_direct, :turn_relay, :unknown],
        do: Map.put(metadata, :route_category, category),
        else: metadata

    {counts, metadata}
  end

  def safe_video(_, _, _), do: nil

  def feedback_summary(%ExRTCP.Packet.TransportFeedback.CC{} = cc) do
    {_, received} =
      Enum.reduce(cc.packet_chunks, {cc.packet_status_count, 0}, fn chunk,
                                                                    {remaining, received} ->
        {count, received_count} =
          case chunk do
            %ExRTCP.Packet.TransportFeedback.CC.RunLength{status_symbol: symbol, run_length: len} ->
              count = min(remaining, len)
              {count, if(symbol == :not_received, do: 0, else: count)}

            %ExRTCP.Packet.TransportFeedback.CC.StatusVector{symbols: symbols} ->
              symbols = Enum.take(symbols, remaining)
              {length(symbols), Enum.count(symbols, &(&1 != :not_received))}
          end

        {remaining - count, received + received_count}
      end)

    %{
      base: cc.base_sequence_number,
      count: cc.packet_status_count,
      received_packets: received,
      lost_packets: cc.packet_status_count - received
    }
  end

  @doc """
  Pinned departure history includes both kinds, retransmissions and RTP headers.
  This snapshot is neither primary payload bitrate, wire overhead, pacing nor
  remote delivery evidence. Sequence/timestamp identities never escape.
  """
  def departure_summary(log, base, count) when is_map(log) do
    {bytes, first, last, matched} =
      Enum.reduce(log, {0, nil, nil, 0}, fn {sequence, {time, size}},
                                            {bytes, first, last, matched} ->
        match_count = if rem(sequence - base + 65_536, 65_536) < count, do: 1, else: 0

        {bytes + size, if(first, do: min(first, time), else: time),
         if(last, do: max(last, time), else: time), matched + match_count}
      end)

    %{
      departure_packets: map_size(log),
      departure_bytes: bytes,
      departure_span_ms: if(first, do: div(last - first, 1_000), else: 0),
      matched_packets: matched,
      reported_packets: count
    }
  end

  @spec emit_call_connection_state(atom()) :: :ok
  def emit_call_connection_state(state)
      when state in [:new, :connecting, :connected, :disconnected, :failed, :closed] do
    :telemetry.execute(@connection_event, %{}, %{connection_state: state})
  end

  def emit_call_connection_state(_unknown_state), do: :ok

  @doc """
  Observes one local process on demand using only `message_queue_len`.

  Use infrequently during audio checks. This neither bounds the RTP mailbox
  nor supplies backpressure. An unavailable process is distinct from an empty
  queue. The caller retains its PID separately; observations contain no identity.
  """
  @spec queue_snapshot(pid()) ::
          %{status: :available, mailbox_len: non_neg_integer()} | %{status: :unavailable}
  def queue_snapshot(pid) when is_pid(pid) and node(pid) == node() do
    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, count} -> %{status: :available, mailbox_len: count}
      nil -> %{status: :unavailable}
    end
  end
end
