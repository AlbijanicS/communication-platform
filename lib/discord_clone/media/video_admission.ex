defmodule DiscordClone.Media.VideoAdmission do
  @moduledoc """
  Encoded VP8 admission for one exact direction, before destination munging.

  Holds one frame, at most 256 packets / 256 KiB of RTP payload and fixed
  headers, eight partition IDs, and 150 ms from its first observed fragment.
  Each payload is at most 1,500 bytes. Input extensions/CSRCs are discarded:
  the destination PC supplies its own identities. Copied payloads prevent a
  small fragment retaining a larger ingress binary. This bounds retained
  assembly, not source mailboxes or downstream cast/transport completion.
  """
  import Bitwise

  def new, do: %{frame: nil, timestamp: nil, sequence: nil, waiting?: true, requested?: false}

  def expire(state) do
    {%{state | frame: nil, waiting?: true, requested?: true}, [], not state.requested?}
  end

  # Advance the suspended direction's watermark without retaining a frame.
  # Input already rejected while busy cannot become the recovery keyframe.
  def discard(state, timestamp) do
    if state.timestamp == nil or newer?(timestamp, state.timestamp),
      do: %{state | timestamp: timestamp},
      else: state
  end

  def admit(state, packet, descriptor, now) do
    {state, _, recovery?} =
      if state.frame && now >= state.frame.deadline, do: expire(state), else: {state, [], false}

    {next, packets, request?} = accept_timestamp(state, packet, descriptor, now)
    {next, packets, recovery? or request?}
  end

  defp accept_timestamp(state, packet, descriptor, now) do
    cond do
      state.frame && state.timestamp == packet.timestamp ->
        add_packet(state, packet, descriptor)

      state.timestamp == nil or newer?(packet.timestamp, state.timestamp) ->
        {state, _, request?} = if state.frame, do: expire(state), else: {state, [], false}

        frame = %{packets: %{}, bytes: 0, deadline: now + 150}

        {next, packets, recovery?} =
          add_packet(
            %{state | timestamp: packet.timestamp, frame: frame, requested?: false},
            packet,
            descriptor
          )

        {next, packets, request? or recovery?}

      true ->
        {state, [], false}
    end
  end

  defp newer?(timestamp, previous),
    do: rem(timestamp - previous + 0x100000000, 0x100000000) in 1..0x7FFFFFFF

  defp add_packet(state, packet, descriptor) do
    frame = state.frame
    previous = Map.get(frame.packets, packet.sequence_number)

    cond do
      previous && elem(previous, 0).payload == packet.payload &&
          elem(previous, 0).marker == packet.marker ->
        {state, [], false}

      previous != nil or byte_size(packet.payload) > 1_500 or
        map_size(frame.packets) >= 256 or frame.bytes + byte_size(packet.payload) + 12 > 262_144 ->
        expire(state)

      true ->
        # Only the first codec bit and descriptor metadata are needed for admission.
        <<first, _::binary>> = descriptor.payload
        descriptor = %{descriptor | payload: <<first>>}

        packet =
          ExRTP.Packet.new(:binary.copy(packet.payload),
            sequence_number: packet.sequence_number,
            timestamp: packet.timestamp,
            marker: packet.marker,
            ssrc: packet.ssrc,
            payload_type: packet.payload_type
          )

        frame = %{
          frame
          | packets: Map.put(frame.packets, packet.sequence_number, {packet, descriptor}),
            bytes: frame.bytes + byte_size(packet.payload) + 12
        }

        complete(%{state | frame: frame})
    end
  end

  defp complete(state) do
    entries = Map.values(state.frame.packets)
    starts = Enum.filter(entries, fn {_, d} -> d.s == 1 and d.pid == 0 end)
    ends = Enum.filter(entries, fn {p, _} -> p.marker end)

    case {starts, ends} do
      {[{start, _}], [{last, _}]} ->
        count = rem(last.sequence_number - start.sequence_number + 65_536, 65_536) + 1

        ordered =
          for offset <- 0..(min(count, 256) - 1),
              do: Map.get(state.frame.packets, rem(start.sequence_number + offset, 65_536))

        cond do
          count > 256 or length(entries) > count -> expire(state)
          nil in ordered -> {state, [], false}
          valid_partitions?(ordered) -> release(state, ordered)
          true -> expire(state)
        end

      {starts, ends} when length(starts) > 1 or length(ends) > 1 ->
        expire(state)

      _ ->
        {state, [], false}
    end
  end

  defp valid_partitions?([{first, descriptor} | rest]) do
    metadata = Map.take(descriptor, [:n, :picture_id, :tl0picidx, :tid, :keyidx])

    Enum.reduce_while(rest, descriptor.pid, fn {packet, d}, previous ->
      valid? =
        packet.ssrc == first.ssrc and
          Map.take(d, [:n, :picture_id, :tl0picidx, :tid, :keyidx]) == metadata and
          ((d.pid == previous and d.s == 0) or (d.pid > previous and d.s == 1))

      if valid?, do: {:cont, d.pid}, else: {:halt, false}
    end) != false
  end

  defp release(state, [{first, descriptor} | _] = ordered) do
    keyframe? = (:binary.first(descriptor.payload) &&& 1) == 0
    gap? = state.sequence != nil and rem(state.sequence + 1, 65_536) != first.sequence_number

    if keyframe? or not (state.waiting? or gap?) do
      {last, _} = List.last(ordered)

      {%{state | frame: nil, sequence: last.sequence_number, waiting?: false, requested?: false},
       Enum.map(ordered, &elem(&1, 0)), false}
    else
      expire(state)
    end
  end
end
