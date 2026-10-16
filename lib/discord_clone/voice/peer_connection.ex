defmodule DiscordClone.Voice.PeerConnection do
  @moduledoc false

  alias ExRTP.Packet
  alias ExRTP.Packet.Extension.AudioLevel
  alias ExWebRTC.{ICECandidate, MediaStreamTrack, PeerConnection, SessionDescription}
  alias ExWebRTC.SDPUtils
  alias DiscordClone.Media.{Connection, ConnectionLayout, Profile}
  alias DiscordClone.Voice.ServerICEProjection

  @command_timeout_ms 5_000
  @audio_level_uri "urn:ietf:params:rtp-hdrext:ssrc-audio-level"
  @mid_uri "urn:ietf:params:rtp-hdrext:sdes:mid"
  @test_environment Code.ensure_loaded?(Mix) and Mix.env() == :test

  defstruct [
    :peer_connection,
    :expected_inbound_track_id,
    :audio_level_extension_id,
    :audio_output_slot_track_ids,
    :test_candidate_observer,
    :test_rtp_observer,
    :test_stats_reader,
    remote_description?: false
  ]

  @type t :: %__MODULE__{
          peer_connection: pid(),
          expected_inbound_track_id: integer() | nil,
          audio_level_extension_id: integer() | nil,
          audio_output_slot_track_ids: %{optional(non_neg_integer()) => integer()} | nil,
          test_candidate_observer: pid() | nil,
          test_rtp_observer: pid() | nil,
          test_stats_reader: (pid() -> map()) | nil,
          remote_description?: boolean()
        }

  @spec start(ServerICEProjection.t(), keyword()) ::
          {:ok, t()} | {:error, :peer_connection_unavailable}
  def start(%ServerICEProjection{} = server_ice_projection, test_options \\ []) do
    options =
      test_options
      |> Keyword.delete(:test_stats_reader)
      |> Keyword.put_new(:rtp_header_extensions, [
        %{type: :all, uri: @mid_uri},
        %{type: :audio, uri: @audio_level_uri}
      ])
      |> Keyword.put(:controlling_process, self())

    with {:ok, peer_connection} <- Connection.start_link(server_ice_projection, options) do
      {:ok,
       %__MODULE__{
         peer_connection: peer_connection,
         audio_output_slot_track_ids: %{},
         test_candidate_observer: test_candidate_observer(test_options),
         test_rtp_observer: test_rtp_observer(test_options),
         test_stats_reader: test_stats_reader(test_options)
       }}
    end
  rescue
    _error -> {:error, :peer_connection_unavailable}
  catch
    :exit, _reason -> {:error, :peer_connection_unavailable}
  end

  @type ice_route :: %{
          route_category: :host_direct | :reflexive_direct | :turn_relay | :unknown,
          protocol: :udp | :tcp | :tls | :unknown,
          outcome: :accepted | :failed,
          error_code: :stats_unavailable | nil,
          duration_ms: non_neg_integer()
        }

  @spec get_stats(t()) :: {:ok, map()} | {:error, :stats_unavailable}
  def get_stats(%__MODULE__{} = state) do
    stats =
      case state.test_stats_reader do
        reader when is_function(reader, 1) -> reader.(state.peer_connection)
        _reader -> PeerConnection.get_stats(state.peer_connection)
      end

    if is_map(stats), do: {:ok, stats}, else: {:error, :stats_unavailable}
  rescue
    _error -> {:error, :stats_unavailable}
  catch
    :exit, _reason -> {:error, :stats_unavailable}
  end

  @spec selected_ice_route(t()) :: ice_route()
  def selected_ice_route(%__MODULE__{} = state) do
    started_at = System.monotonic_time(:millisecond)

    case get_stats(state) do
      {:ok, stats} ->
        stats
        |> classify_ice_route()
        |> Map.merge(%{
          outcome: :accepted,
          error_code: nil,
          duration_ms: bounded_duration(started_at)
        })

      {:error, :stats_unavailable} ->
        unknown_ice_route(started_at)
    end
  end

  @doc false
  def classify_ice_route(stats) when is_map(stats) do
    pairs =
      stats
      |> Map.values()
      |> Enum.filter(&selected_pair?/1)

    case pairs do
      [%{local_candidate_id: local_id, remote_candidate_id: remote_id}] ->
        classify_candidates(Map.get(stats, local_id), Map.get(stats, remote_id))

      _ambiguous ->
        %{route_category: :unknown, protocol: :unknown}
    end
  end

  def classify_ice_route(_stats), do: %{route_category: :unknown, protocol: :unknown}

  defp selected_pair?(%{type: :candidate_pair, valid: true, nominated: true, state: :succeeded}),
    do: true

  defp selected_pair?(_stats), do: false

  defp classify_candidates(
         %{type: :local_candidate, candidate_type: local_type, protocol: local_protocol},
         %{type: :remote_candidate, candidate_type: remote_type, protocol: remote_protocol}
       ) do
    %{
      route_category: route_category(local_type, remote_type),
      protocol: protocol(local_protocol, remote_protocol)
    }
  end

  defp classify_candidates(_local, _remote),
    do: %{route_category: :unknown, protocol: :unknown}

  defp route_category(local, remote) when local == :relay or remote == :relay, do: :turn_relay

  defp route_category(local, remote)
       when local in [:srflx, :prflx] or remote in [:srflx, :prflx],
       do: :reflexive_direct

  defp route_category(:host, :host), do: :host_direct
  defp route_category(_local, _remote), do: :unknown

  defp protocol(protocol, protocol) when protocol in [:udp, :tcp, :tls], do: protocol
  defp protocol(_local, _remote), do: :unknown

  defp unknown_ice_route(started_at) do
    %{
      route_category: :unknown,
      protocol: :unknown,
      outcome: :failed,
      error_code: :stats_unavailable,
      duration_ms: bounded_duration(started_at)
    }
  end

  defp bounded_duration(started_at) do
    System.monotonic_time(:millisecond)
    |> Kernel.-(started_at)
    |> max(0)
    |> min(60_000)
  end

  @spec accept_offer(t(), map(), timeout()) ::
          {:ok, map(), t()}
          | {:error, :incompatible_audio_output_slots | :negotiation_failed}
  def accept_offer(%__MODULE__{} = state, description, timeout \\ @command_timeout_ms) do
    accept_offer_until(state, description, deadline(timeout))
  end

  @doc false
  @spec validate_audio_topology(map()) :: :ok | {:error, :incompatible_audio_output_slots}
  def validate_audio_topology(description) do
    case compatible_audio_topology(description) do
      {:ok, _topology} -> :ok
      {:error, _reason} -> {:error, :incompatible_audio_output_slots}
    end
  end

  @spec accept_offer_until(t(), map(), integer()) ::
          {:ok, map(), t()}
          | {:error, :incompatible_audio_output_slots | :negotiation_failed}
  def accept_offer_until(%__MODULE__{} = state, description, deadline) do
    with {:ok, audio_topology} <- compatible_audio_topology(description),
         :ok <-
           peer_call(
             state.peer_connection,
             {:set_remote_description, SessionDescription.from_json(description)},
             deadline
           ),
         {:ok, inbound_track_id, output_slot_track_ids} <-
           provision_audio_topology(state.peer_connection, audio_topology, deadline),
         {:ok, answer} <- peer_call(state.peer_connection, :create_answer, deadline),
         :ok <-
           peer_call(
             state.peer_connection,
             {:set_local_description, answer},
             deadline
           ) do
      {:ok, SessionDescription.to_json(answer),
       %{
         state
         | expected_inbound_track_id: inbound_track_id,
           audio_level_extension_id: negotiated_audio_level_extension_id(description),
           audio_output_slot_track_ids: output_slot_track_ids,
           remote_description?: true
       }}
    else
      {:error, :incompatible_audio_output_slots} = error -> error
      {:error, _reason} -> {:error, :negotiation_failed}
    end
  rescue
    _error -> {:error, :negotiation_failed}
  end

  @spec add_ice_candidate(t(), map(), timeout()) :: :ok | {:error, :candidate_rejected}
  def add_ice_candidate(_state, _candidate, timeout \\ @command_timeout_ms)

  def add_ice_candidate(state, candidate, timeout),
    do: add_ice_candidate_until(state, candidate, deadline(timeout))

  @spec add_ice_candidate_until(t(), map(), integer()) ::
          :ok | {:error, :candidate_rejected}
  def add_ice_candidate_until(
        %__MODULE__{remote_description?: true} = state,
        candidate,
        deadline
      ) do
    case peer_call(
           state.peer_connection,
           {:add_ice_candidate, ICECandidate.from_json(candidate)},
           deadline
         ) do
      :ok ->
        notify_test_candidate_observer(state, candidate)
        :ok

      {:error, _reason} ->
        {:error, :candidate_rejected}
    end
  rescue
    _error -> {:error, :candidate_rejected}
  end

  def add_ice_candidate_until(%__MODULE__{}, _candidate, _deadline),
    do: {:error, :candidate_rejected}

  @spec route_media(t(), term()) ::
          {{:accepted_inbound_track, integer()}
           | {:accepted_inbound_rtp, integer(), ExRTP.Packet.t()}
           | {:accepted_inbound_track_muted, integer()}
           | {:accepted_inbound_track_ended, integer()}
           | :dropped_rtp
           | :dropped_media
           | :ignore, t()}
  def route_media(
        %__MODULE__{peer_connection: peer_connection} = state,
        {:ex_webrtc, peer_connection, message}
      ) do
    route_peer_media(state, message)
  end

  def route_media(%__MODULE__{} = state, _message), do: {:ignore, state}

  @spec speaking_activity(t(), ExRTP.Packet.t()) :: :speaking | :silent | :fallback
  def speaking_activity(%__MODULE__{audio_level_extension_id: nil}, _packet), do: :fallback

  def speaking_activity(%__MODULE__{audio_level_extension_id: extension_id}, packet) do
    with {:ok, extension} <- Packet.fetch_extension(packet, extension_id),
         {:ok, %AudioLevel{voice: true, level: level}} <- AudioLevel.from_raw(extension) do
      if level <= 50, do: :speaking, else: :silent
    else
      _missing_or_invalid_extension -> :silent
    end
  end

  @spec send_rtp(t(), non_neg_integer(), ExRTP.Packet.t()) ::
          :ok | {:error, :outbound_track_unavailable}
  def send_rtp(
        %__MODULE__{
          peer_connection: peer_connection,
          audio_output_slot_track_ids: audio_output_slot_track_ids
        } = state,
        audio_output_slot,
        packet
      )
      when is_map(audio_output_slot_track_ids) and is_integer(audio_output_slot) do
    case Map.fetch(audio_output_slot_track_ids, audio_output_slot) do
      {:ok, outbound_track_id} ->
        notify_test_rtp_observer(state, outbound_track_id, packet)
        PeerConnection.send_rtp(peer_connection, outbound_track_id, packet)

      :error ->
        {:error, :outbound_track_unavailable}
    end
  end

  def send_rtp(%__MODULE__{}, _audio_output_slot, _packet),
    do: {:error, :outbound_track_unavailable}

  @spec signal(t(), term()) ::
          {:ice_candidate, map()}
          | {:connection_state_change, atom()}
          | :end_of_candidates
          | :ignore
  def signal(
        %__MODULE__{peer_connection: peer_connection},
        {:ex_webrtc, peer_connection, {:ice_candidate, candidate}}
      ) do
    {:ice_candidate, ICECandidate.to_json(candidate)}
  end

  def signal(
        %__MODULE__{peer_connection: peer_connection},
        {:ex_webrtc, peer_connection, {:connection_state_change, state}}
      )
      when state in [:new, :connecting, :connected, :disconnected, :failed, :closed] do
    {:connection_state_change, state}
  end

  def signal(
        %__MODULE__{peer_connection: peer_connection},
        {:ex_webrtc, peer_connection, {:ice_gathering_state_change, :complete}}
      ) do
    :end_of_candidates
  end

  def signal(%__MODULE__{}, _message), do: :ignore

  @spec stop(t()) :: :ok
  def stop(%__MODULE__{peer_connection: peer_connection}) do
    Connection.stop(peer_connection)
  end

  defp compatible_audio_topology(%{"type" => "offer", "sdp" => raw_sdp})
       when is_binary(raw_sdp) do
    ConnectionLayout.validate(Profile.voice(), %{"type" => "offer", "sdp" => raw_sdp})
  end

  defp compatible_audio_topology(_description), do: {:error, :incompatible_media}

  defp provision_audio_topology(peer_connection, audio_topology, deadline) do
    transceivers = peer_call(peer_connection, :get_transceivers, deadline)
    transceivers_by_mid = Map.new(transceivers, &{&1.mid, &1})

    with %{receiver: %{track: %{id: inbound_track_id}}} <-
           Map.get(transceivers_by_mid, audio_topology.source_mid),
         {:ok, output_slot_track_ids} <-
           provision_audio_output_slots(
             peer_connection,
             transceivers_by_mid,
             audio_topology.output_slot_mids,
             deadline
           ) do
      {:ok, inbound_track_id, output_slot_track_ids}
    else
      _missing_transceiver -> {:error, :incompatible_media}
    end
  end

  defp provision_audio_output_slots(
         peer_connection,
         transceivers_by_mid,
         output_slot_mids,
         deadline
       ) do
    output_slot_mids
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, %{}}, fn {mid, slot}, {:ok, track_ids} ->
      with %{id: transceiver_id, sender: %{id: sender_id}} <-
             Map.get(transceivers_by_mid, mid),
           :ok <-
             peer_call(
               peer_connection,
               {:set_transceiver_direction, transceiver_id, :sendonly},
               deadline
             ),
           track = MediaStreamTrack.new(:audio),
           :ok <-
             peer_call(
               peer_connection,
               {:replace_track, sender_id, track},
               deadline
             ) do
        {:cont, {:ok, Map.put(track_ids, slot, track.id)}}
      else
        _error -> {:halt, {:error, :audio_output_slot_unavailable}}
      end
    end)
  end

  defp peer_call(peer_connection, request, :infinity),
    do: GenServer.call(peer_connection, request, :infinity)

  defp peer_call(peer_connection, request, deadline) do
    timeout = deadline - System.monotonic_time(:millisecond)

    if timeout <= 0 do
      exit({:timeout, {__MODULE__, :peer_call}})
    else
      GenServer.call(peer_connection, request, timeout)
    end
  end

  defp deadline(:infinity), do: :infinity
  defp deadline(timeout), do: System.monotonic_time(:millisecond) + timeout

  defp negotiated_audio_level_extension_id(description) do
    with %SessionDescription{sdp: sdp} <- SessionDescription.from_json(description),
         {:ok, parsed_sdp} <- ExSDP.parse(sdp),
         %{id: extension_id} <-
           Enum.find(SDPUtils.get_extensions(parsed_sdp), &(&1.uri == @audio_level_uri)) do
      extension_id
    else
      _missing_or_invalid_description -> nil
    end
  rescue
    _error -> nil
  end

  defp test_candidate_observer(options) do
    if @test_environment do
      Keyword.get(options, :test_candidate_observer)
    end
  end

  defp test_rtp_observer(options) do
    if @test_environment do
      Keyword.get(options, :test_rtp_observer)
    end
  end

  defp test_stats_reader(options) do
    if @test_environment do
      Keyword.get(options, :test_stats_reader)
    end
  end

  defp notify_test_candidate_observer(%{test_candidate_observer: observer}, candidate)
       when is_pid(observer) do
    send(observer, {:peer_connection_candidate_applied, candidate})
  end

  defp notify_test_candidate_observer(_state, _candidate), do: :ok

  defp route_peer_media(
         %__MODULE__{expected_inbound_track_id: expected_track_id} = state,
         {:track, %{id: expected_track_id, kind: :audio}}
       )
       when not is_nil(expected_track_id) do
    {{:accepted_inbound_track, expected_track_id}, state}
  end

  defp route_peer_media(
         %__MODULE__{
           expected_inbound_track_id: expected_track_id
         } = state,
         {:rtp, expected_track_id, _rid, packet}
       )
       when not is_nil(expected_track_id) do
    {{:accepted_inbound_rtp, expected_track_id, packet}, state}
  end

  defp route_peer_media(state, {:rtp, _track_id, _rid, _packet}), do: {:dropped_rtp, state}

  defp route_peer_media(
         %__MODULE__{expected_inbound_track_id: expected_track_id} = state,
         {:track_muted, expected_track_id}
       )
       when not is_nil(expected_track_id) do
    {{:accepted_inbound_track_muted, expected_track_id}, state}
  end

  defp route_peer_media(
         %__MODULE__{expected_inbound_track_id: expected_track_id} = state,
         {:track_ended, expected_track_id}
       )
       when not is_nil(expected_track_id) do
    {{:accepted_inbound_track_ended, expected_track_id},
     %{state | expected_inbound_track_id: nil}}
  end

  defp route_peer_media(state, {:track, _track}), do: {:dropped_media, state}
  defp route_peer_media(state, {:track_muted, _track_id}), do: {:dropped_media, state}
  defp route_peer_media(state, {:track_ended, _track_id}), do: {:dropped_media, state}
  defp route_peer_media(state, {:data_channel, _channel}), do: {:dropped_media, state}

  defp route_peer_media(state, {:data_channel_state_change, _channel_ref, _state}),
    do: {:dropped_media, state}

  defp route_peer_media(state, {:data, _channel_ref, _data}), do: {:dropped_media, state}
  defp route_peer_media(state, {:rtcp, _packets}), do: {:dropped_media, state}
  defp route_peer_media(state, _message), do: {:ignore, state}

  defp notify_test_rtp_observer(
         %{test_rtp_observer: observer, peer_connection: peer_connection},
         track_id,
         packet
       )
       when is_pid(observer) do
    send(observer, {:peer_connection_rtp_sent, peer_connection, track_id, packet})
  end

  defp notify_test_rtp_observer(_state, _track_id, _packet), do: :ok
end
