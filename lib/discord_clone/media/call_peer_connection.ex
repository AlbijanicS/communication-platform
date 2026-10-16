defmodule DiscordClone.Media.CallPeerConnection do
  @moduledoc """
  The fixed Call transport layout. Each duplex Opus/VP8 position has exact inbound
  and outbound identities before answer in one destination stream grouping;
  camera-off sends no video packets. Capture ownership remains independent.
  This adapter does not admit Sessions or enable production Call audio.
  """

  alias DiscordClone.Media.{Connection, ConnectionLayout, Negotiation, Profile}
  alias DiscordClone.Voice.ServerICEProjection
  alias ExWebRTC.{ICECandidate, MediaStreamTrack, SessionDescription}

  defstruct [:peer_connection, :audio, :video, negotiation: %Negotiation{}]

  @type position :: %{
          mid: String.t(),
          inbound_track_id: integer(),
          outbound_track_id: integer() | nil,
          sender_id: integer()
        }
  @type t :: %__MODULE__{
          peer_connection: pid(),
          audio: position() | nil,
          video: position() | nil,
          negotiation: Negotiation.t()
        }

  @spec start_link(ServerICEProjection.t(), keyword()) ::
          {:ok, pid()} | {:error, :peer_connection_unavailable}
  def start_link(projection, options \\ []) do
    Connection.start_link(
      projection,
      Keyword.merge(options, audio_codecs: [:opus], video_codecs: [:vp8])
    )
  end

  @spec accept_offer(t(), map(), timeout()) :: {:ok, map(), t()} | {:error, :negotiation_failed}
  def accept_offer(%__MODULE__{} = state, description, timeout \\ 5_000) do
    deadline =
      if timeout == :infinity, do: :infinity, else: System.monotonic_time(:millisecond) + timeout

    case accept_offer_until(state, description, deadline) do
      {:ok, _answer, _state} = success ->
        success

      _failure ->
        stop(state)
        {:error, :negotiation_failed}
    end
  end

  @doc """
  Accept a validated offer using Session-owned state and the ten-second budget.
  The owning Session must serialize commands and retain each returned adapter;
  stopped Sessions discard the adapter rather than copying it to a replacement.
  """
  def accept_offer(state, negotiation_id, description, deadline) do
    case Negotiation.accept_offer(state.negotiation, state, negotiation_id, description, deadline) do
      {:ok, answer, state, negotiation} ->
        {:ok, answer, %{state | negotiation: negotiation}}

      {:error, reason, negotiation} ->
        {:error, reason, %{state | negotiation: negotiation}}
    end
  end

  def add_ice_candidate(state, negotiation_id, candidate, deadline) do
    case Negotiation.add_ice_candidate(
           state.negotiation,
           state,
           negotiation_id,
           candidate,
           deadline
         ) do
      {:ok, negotiation} ->
        {:ok, %{negotiation_id: negotiation_id}, %{state | negotiation: negotiation}}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  def end_of_candidates(state, negotiation_id),
    do: Negotiation.end_of_candidates(state.negotiation, negotiation_id)

  @doc false
  def accept_offer_until(state, description, deadline) do
    case negotiate(state, description, deadline) do
      {:ok, _answer, _state} = success -> success
      _failure -> {:error, :negotiation_failed}
    end
  end

  @doc false
  def add_ice_candidate_until(%__MODULE__{audio: audio} = state, candidate, deadline)
      when not is_nil(audio) do
    case call(state, {:add_ice_candidate, ICECandidate.from_json(candidate)}, deadline) do
      :ok -> :ok
      _error -> {:error, :candidate_rejected}
    end
  rescue
    _error -> {:error, :candidate_rejected}
  catch
    :exit, _reason -> {:error, :candidate_rejected}
  end

  def add_ice_candidate_until(_state, _candidate, _deadline), do: {:error, :candidate_rejected}

  defp negotiate(state, description, deadline) do
    stream_id = MediaStreamTrack.generate_stream_id()

    with {:ok, layout} <- ConnectionLayout.validate(Profile.direct_call(), description),
         :ok <-
           call(
             state,
             {:set_remote_description, SessionDescription.from_json(description)},
             deadline
           ),
         transceivers when is_list(transceivers) <- call(state, :get_transceivers, deadline),
         audio = Enum.find(transceivers, &(&1.mid == layout.audio_mid)),
         video = Enum.find(transceivers, &(&1.mid == layout.video_mid)),
         :ok <- call(state, {:set_transceiver_direction, audio.id, :sendrecv}, deadline),
         :ok <- call(state, {:set_transceiver_direction, video.id, :sendrecv}, deadline),
         :ok <-
           call(
             state,
             {:replace_track, audio.sender.id, MediaStreamTrack.new(:audio, [stream_id])},
             deadline
           ),
         :ok <-
           call(
             state,
             {:replace_track, video.sender.id, MediaStreamTrack.new(:video, [stream_id])},
             deadline
           ),
         :ok <- select_codec(state, audio, "audio/opus", deadline),
         :ok <- select_codec(state, video, "video/VP8", deadline),
         {:ok, answer} <- call(state, :create_answer, deadline),
         :ok <- call(state, {:set_local_description, answer}, deadline),
         transceivers when is_list(transceivers) <- call(state, :get_transceivers, deadline) do
      positions = Map.new(transceivers, &{&1.mid, position(&1)})

      {:ok, SessionDescription.to_json(answer),
       %{
         state
         | audio: Map.fetch!(positions, layout.audio_mid),
           video: Map.fetch!(positions, layout.video_mid)
       }}
    end
  rescue
    _error -> {:error, :negotiation_failed}
  catch
    :exit, _reason -> {:error, :negotiation_failed}
  end

  defp select_codec(state, transceiver, mime, deadline) do
    case Enum.filter(transceiver.codecs, &(&1.mime_type == mime)) do
      [codec] -> call(state, {:set_sender_codec, transceiver.sender.id, codec}, deadline)
      _invalid -> {:error, :negotiation_failed}
    end
  end

  defp position(transceiver) do
    %{
      mid: transceiver.mid,
      inbound_track_id: transceiver.receiver.track.id,
      outbound_track_id: transceiver.sender.track && transceiver.sender.track.id,
      sender_id: transceiver.sender.id
    }
  end

  @spec stop(t()) :: :ok
  def stop(%__MODULE__{peer_connection: peer}), do: Connection.stop(peer)

  @doc "Classifies only exact negotiated input identities; Session state gates sending."
  @spec route_media(t(), term()) :: {term(), t()}
  def route_media(
        %__MODULE__{peer_connection: peer, video: %{outbound_track_id: id}} = state,
        {:ex_webrtc, peer, {:rtcp, packets}}
      )
      when is_integer(id) and is_list(packets) do
    if Enum.any?(packets, &match?({^id, %ExRTCP.Packet.PayloadFeedback.PLI{}}, &1)),
      do: {:decoder_keyframe_request, state},
      else: {:ignore, state}
  end

  def route_media(
        %__MODULE__{peer_connection: peer, video: %{inbound_track_id: id}} = state,
        {:ex_webrtc, peer, {:rtp, id, nil, packet}}
      ),
      do: {{:accepted_inbound_video_rtp, id, packet}, state}

  def route_media(
        %__MODULE__{peer_connection: peer, audio: %{inbound_track_id: id}} = state,
        {:ex_webrtc, peer, {:track, %{id: id, kind: :audio}}}
      ),
      do: {{:accepted_inbound_track, id}, state}

  def route_media(
        %__MODULE__{peer_connection: peer, audio: %{inbound_track_id: id}} = state,
        {:ex_webrtc, peer, {:rtp, id, _rid, packet}}
      ),
      do: {{:accepted_inbound_rtp, id, packet}, state}

  def route_media(
        %__MODULE__{peer_connection: peer} = state,
        {:ex_webrtc, peer, {:rtp, _, _, _}}
      ),
      do: {:dropped_rtp, state}

  def route_media(%__MODULE__{peer_connection: peer} = state, {:ex_webrtc, peer, {:track, _}}),
    do: {:dropped_media, state}

  def route_media(state, _message), do: {:ignore, state}

  def send_rtp(state, :audio, slot, packet), do: send_rtp(state, slot, packet)

  def send_rtp(
        %__MODULE__{video: %{outbound_track_id: id}, peer_connection: peer},
        :video,
        0,
        packet
      )
      when not is_nil(id),
      do: ExWebRTC.PeerConnection.send_rtp(peer, id, packet)

  def send_rtp(_state, _kind, _slot, _packet), do: {:error, :outbound_track_unavailable}

  def send_rtp(%__MODULE__{audio: %{outbound_track_id: id}, peer_connection: peer}, 0, packet)
      when not is_nil(id),
      do: ExWebRTC.PeerConnection.send_rtp(peer, id, packet)

  def send_rtp(_state, _slot, _packet), do: {:error, :outbound_track_unavailable}

  def request_keyframe(
        %__MODULE__{peer_connection: peer, video: %{inbound_track_id: track}},
        track
      )
      when is_integer(track),
      do: ExWebRTC.PeerConnection.send_pli(peer, track)

  def request_keyframe(_state, _track), do: {:error, :inbound_track_unavailable}

  defp call(state, request, :infinity),
    do: GenServer.call(state.peer_connection, request, :infinity)

  defp call(state, request, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0,
      do: exit(:timeout),
      else: GenServer.call(state.peer_connection, request, remaining)
  end
end
