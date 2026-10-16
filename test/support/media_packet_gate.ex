defmodule DiscordClone.MediaPacketGate do
  @moduledoc """
  Pinned ExWebRTC 0.17.0 fixture: interposes only DTLS's decrypted notification
  boundary, before PC receive history. NACK generation, RTX history, SRTP and
  UDP remain real. A single selected primary is discarded, never synthesized.
  Observations contain bounded identities, byte counts and synthetic payload
  digests, not SDP, addresses, credentials or media. No production hook exists.
  """
  use GenServer

  alias ExRTP.Packet
  alias ExRTCP.Packet.TransportFeedback.NACK

  def start_link({peer, observer, label}) do
    GenServer.start_link(__MODULE__, {peer, observer, label})
  end

  def drop_next(gate, sequence), do: GenServer.call(gate, {:drop_next, sequence})
  def hold_repair(gate, sequence), do: GenServer.call(gate, {:hold_repair, sequence})
  def release_repair(gate), do: GenServer.call(gate, :release_repair)
  def delay_video(gate, milliseconds), do: GenServer.call(gate, {:delay_video, milliseconds})
  def impair_video(gate, every, bytes), do: GenServer.call(gate, {:impair, every, bytes})
  def impairment_stats(gate), do: GenServer.call(gate, :impairment_stats)

  # Deliberate feedback uses the real encrypted leg, not a PC notification.
  def request_history(gate, ssrc, sequence) do
    GenServer.call(gate, {:request_history, ssrc, sequence})
  end

  @impl true
  def init({peer, observer, label}) do
    %{dtls_transport: dtls} = :sys.get_state(peer)
    [_audio, video] = ExWebRTC.PeerConnection.get_transceivers(peer)
    primary = Enum.find(video.codecs, &(&1.mime_type == "video/VP8"))
    repair = Enum.find(video.codecs, &(&1.mime_type == "video/rtx"))
    gate = self()
    true = :sys.get_state(dtls).owner == peer
    _ = :sys.replace_state(dtls, &%{&1 | owner: gate})

    {:ok,
     %{
       peer: peer,
       dtls: dtls,
       observer: observer,
       label: label,
       primary: primary.payload_type,
       repair: repair.payload_type,
       drop: nil,
       hold: nil,
       held: nil,
       delay_ms: 0,
       impairment: nil
     }}
  end

  @impl true
  def handle_call({:drop_next, sequence}, _from, state),
    do: {:reply, :ok, %{state | drop: sequence}}

  def handle_call({:impair, every, bytes}, _from, state)
      when every >= 0 and bytes >= 0 do
    impairment = %{every: every, budget: bytes, window: 0, used: 0, seen: 0, dropped: 0}
    {:reply, :ok, %{state | impairment: impairment}}
  end

  def handle_call(:impairment_stats, _from, state), do: {:reply, state.impairment, state}

  def handle_call({:delay_video, milliseconds}, _from, state)
      when milliseconds in 0..500,
      do: {:reply, :ok, %{state | delay_ms: milliseconds}}

  def handle_call({:hold_repair, sequence}, _from, %{held: nil} = state),
    do: {:reply, :ok, %{state | hold: sequence}}

  def handle_call(:release_repair, _from, %{held: message} = state) when not is_nil(message) do
    send(state.peer, message)
    {:reply, :ok, %{state | held: nil}}
  end

  def handle_call({:request_history, ssrc, sequence}, _from, state) do
    nack = NACK.from_sequence_numbers(1, ssrc, [sequence])
    :ok = ExWebRTC.DTLSTransport.send_rtcp(state.dtls, ExRTCP.Packet.encode(nack))
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:dtls_transport, dtls, {:rtp, data}} = message, %{dtls: dtls} = state) do
    {:ok, packet} = Packet.decode(data)

    if packet.payload_type in [state.primary, state.repair] do
      repair? = packet.payload_type == state.repair

      {sequence, payload} =
        if repair? do
          <<original::16, payload::binary>> = packet.payload
          {original, payload}
        else
          {packet.sequence_number, packet.payload}
        end

      {impaired?, state} = impair_packet(state, byte_size(data))
      dropped? = impaired? or (not repair? and state.drop == sequence)
      held? = repair? and state.hold == sequence

      observation = %{
        kind: if(repair?, do: :rtx, else: :primary),
        dropped?: dropped?,
        held?: held?,
        sequence: sequence,
        wire_sequence: packet.sequence_number,
        timestamp: packet.timestamp,
        pt: packet.payload_type,
        ssrc: packet.ssrc,
        digest: :crypto.hash(:sha256, payload),
        payload_bytes: byte_size(packet.payload),
        header_bytes: byte_size(data) - byte_size(packet.payload)
      }

      if state.impairment == nil,
        do: send(state.observer, {:media_packet, state.label, observation})

      unless dropped? or held? do
        if state.delay_ms == 0,
          do: send(state.peer, message),
          else: Process.send_after(self(), {:delayed_video, message}, state.delay_ms)
      end

      next = if dropped?, do: %{state | drop: nil}, else: state
      {:noreply, if(held?, do: %{next | hold: nil, held: message}, else: next)}
    else
      send(state.peer, message)
      {:noreply, state}
    end
  end

  def handle_info({:dtls_transport, dtls, {:rtcp, data}} = message, %{dtls: dtls} = state) do
    {:ok, packets} = ExRTCP.CompoundPacket.decode(data)

    for %NACK{} = nack <- packets do
      send(
        state.observer,
        {:media_nack, state.label, nack.media_ssrc, Enum.take(NACK.to_sequence_numbers(nack), 32)}
      )
    end

    for %ExRTCP.Packet.SenderReport{} = report <- packets do
      send(state.observer, {:media_report, state.label, report})
    end

    send(state.peer, message)
    {:noreply, state}
  end

  def handle_info({:delayed_video, message}, state) do
    send(state.peer, message)
    {:noreply, state}
  end

  def handle_info(message, state) do
    send(state.peer, message)
    {:noreply, state}
  end

  # Discard immediately at the authenticated destination boundary. The fixture
  # models a policer/loss path; it never creates a hidden transport backlog.
  defp impair_packet(%{impairment: nil} = state, _bytes), do: {false, state}

  defp impair_packet(%{impairment: load} = state, bytes) do
    window = div(System.monotonic_time(:millisecond), 1_000)
    load = if load.window == window, do: load, else: %{load | window: window, used: 0}
    seen = load.seen + 1

    dropped? =
      (load.every > 0 and rem(seen, load.every) == 0) or
        (load.budget > 0 and load.used + bytes > load.budget)

    next = %{
      load
      | seen: seen,
        used: load.used + bytes,
        dropped: load.dropped + if(dropped?, do: 1, else: 0)
    }

    {dropped?, %{state | impairment: next}}
  end
end
