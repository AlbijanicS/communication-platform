defmodule DiscordClone.Voice.Session do
  @moduledoc false

  use GenServer, restart: :temporary

  alias DiscordClone.Media.Negotiation
  alias DiscordClone.Voice.{Diagnostics, Forwarder, PeerConnection, ServerICEProjection}

  @command_timeout_ms 5_000
  @negotiation_timeout_ms 15_000
  @peer_connection_recovery_timeout_ms :timer.seconds(30)
  @test_environment Code.ensure_loaded?(Mix) and Mix.env() == :test

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @spec accept_offer(pid(), binary(), map(), integer()) ::
          {:ok, map()} | {:error, atom()}
  def accept_offer(session, negotiation_id, description) do
    accept_offer(session, negotiation_id, description, command_deadline())
  end

  def accept_offer(session, negotiation_id, description, deadline) do
    GenServer.call(
      session,
      {:accept_offer, negotiation_id, description, deadline},
      remaining_timeout(deadline)
    )
  end

  @spec add_ice_candidate(pid(), binary(), map(), integer()) ::
          {:ok, map()} | {:error, atom()}
  def add_ice_candidate(session, negotiation_id, candidate) do
    add_ice_candidate(session, negotiation_id, candidate, command_deadline())
  end

  def add_ice_candidate(session, negotiation_id, candidate, deadline) do
    GenServer.call(
      session,
      {:add_ice_candidate, negotiation_id, candidate, deadline},
      remaining_timeout(deadline)
    )
  end

  @spec end_of_candidates(pid(), binary(), integer()) :: {:error, atom()}
  def end_of_candidates(session, negotiation_id) do
    end_of_candidates(session, negotiation_id, command_deadline())
  end

  def end_of_candidates(session, negotiation_id, deadline) do
    GenServer.call(
      session,
      {:end_of_candidates, negotiation_id, deadline},
      remaining_timeout(deadline)
    )
  end

  @spec deliver_rtp(pid(), Ecto.UUID.t(), non_neg_integer(), ExRTP.Packet.t()) :: :ok
  def deliver_rtp(session, voice_session_id, audio_output_slot, packet) do
    GenServer.cast(session, {:deliver_rtp, voice_session_id, audio_output_slot, packet})
  end

  @spec crash(pid()) :: :ok
  def crash(session) do
    Process.exit(session, :kill)
    :ok
  end

  @impl true
  def init(opts) do
    signaling_channel = Keyword.fetch!(opts, :signaling_channel)

    server_ice_projection =
      Keyword.get(opts, :server_ice_projection, ServerICEProjection.disabled())

    peer_connection_opts =
      if @test_environment do
        Keyword.get(opts, :test_peer_connection_opts, [])
      else
        []
      end

    case ServerICEProjection.validate(server_ice_projection) do
      {:ok, server_ice_projection} ->
        start_peer_connection(
          opts,
          signaling_channel,
          server_ice_projection,
          peer_connection_opts
        )

      {:error, :invalid_server_ice_projection} ->
        {:stop, :peer_connection_unavailable}
    end
  end

  defp start_peer_connection(
         opts,
         signaling_channel,
         server_ice_projection,
         peer_connection_opts
       ) do
    case PeerConnection.start(server_ice_projection, peer_connection_opts) do
      {:ok, peer_connection} ->
        forwarder = Keyword.get(opts, :forwarder)
        voice_session_id = Keyword.fetch!(opts, :voice_session_id)
        :ok = Forwarder.session_started(forwarder, voice_session_id, self())

        negotiation_timer =
          Process.send_after(
            self(),
            :negotiation_timeout,
            Keyword.get(opts, :negotiation_timeout_ms, @negotiation_timeout_ms)
          )

        {:ok,
         %{
           room_server: Keyword.fetch!(opts, :room_server),
           forwarder: forwarder,
           voice_session_id: voice_session_id,
           signaling_channel: signaling_channel,
           signaling_channel_monitor: Process.monitor(signaling_channel),
           peer_connection: peer_connection,
           ice_mode: server_ice_projection.ice_mode,
           last_ice_route_category: nil,
           negotiation_timer: negotiation_timer,
           negotiation: %Negotiation{},
           peer_connection_recovery_timeout_ms:
             Keyword.get(
               opts,
               :peer_connection_recovery_timeout_ms,
               @peer_connection_recovery_timeout_ms
             ),
           peer_connection_recovery_timer: nil,
           peer_connection_recovery_ref: nil,
           media_counts: empty_media_counts()
         }}

      {:error, :peer_connection_unavailable} ->
        {:stop, :peer_connection_unavailable}
    end
  end

  @impl true
  def handle_call({:accept_offer, negotiation_id, description, deadline}, _from, state) do
    case Negotiation.accept_offer(
           state.negotiation,
           state.peer_connection,
           negotiation_id,
           description,
           deadline
         ) do
      {:ok, answer, peer_connection, negotiation} ->
        state = %{
          state
          | peer_connection: peer_connection,
            negotiation_timer: cancel_negotiation_timer(state.negotiation_timer),
            negotiation: negotiation
        }

        :ok = Forwarder.receive_ready(state.forwarder, state.voice_session_id, self(), :opus)
        {:reply, {:ok, answer}, state}

      {:error, error, negotiation} ->
        state = %{state | negotiation: negotiation}

        if negotiation.closed?,
          do: {:stop, :normal, {:error, error}, state},
          else: {:reply, {:error, error}, state}
    end
  end

  def handle_call({:add_ice_candidate, negotiation_id, candidate, deadline}, _from, state) do
    case Negotiation.add_ice_candidate(
           state.negotiation,
           state.peer_connection,
           negotiation_id,
           candidate,
           deadline
         ) do
      {:ok, negotiation} ->
        {:reply, {:ok, %{negotiation_id: negotiation_id}}, %{state | negotiation: negotiation}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:end_of_candidates, negotiation_id, _deadline}, _from, state) do
    {:reply, Negotiation.end_of_candidates(state.negotiation, negotiation_id), state}
  end

  @impl true
  def handle_cast(
        {:deliver_rtp, voice_session_id, audio_output_slot, packet},
        %{voice_session_id: voice_session_id} = state
      ) do
    case PeerConnection.send_rtp(state.peer_connection, audio_output_slot, packet) do
      :ok ->
        {:noreply,
         record_media(state, state.peer_connection, :rtp_routed, [:forwarded_packet_count])}

      {:error, :outbound_track_unavailable} ->
        {:noreply, record_dropped_rtp(state)}
    end
  end

  def handle_cast(
        {:deliver_rtp, _stale_voice_session_id, _audio_output_slot, _packet},
        state
      ) do
    {:noreply, record_dropped_rtp(state)}
  end

  @impl true
  def handle_info(:negotiation_timeout, %{negotiation: %{negotiation_id: nil}} = state),
    do: {:stop, :normal, state}

  def handle_info(
        {:peer_connection_recovery_expired, recovery_ref},
        %{peer_connection_recovery_ref: recovery_ref} = state
      ) do
    send_event(state, {:connection_state_change, :failed, state.negotiation.negotiation_id})
    {:stop, :normal, state}
  end

  def handle_info({:peer_connection_recovery_expired, _stale_recovery_ref}, state),
    do: {:noreply, state}

  def handle_info(
        {:DOWN, signaling_channel_monitor, :process, _signaling_channel, _reason},
        %{signaling_channel_monitor: signaling_channel_monitor} = state
      ) do
    GenServer.cast(state.room_server, {:signaling_channel_down, state.voice_session_id})
    {:stop, :normal, state}
  end

  def handle_info(
        {:ex_webrtc, peer_connection, _message} = message,
        %{peer_connection: %PeerConnection{peer_connection: peer_connection}} = state
      ) do
    case PeerConnection.route_media(state.peer_connection, message) do
      {:ignore, peer_connection} ->
        handle_peer_signal(peer_connection, message, state)

      {outcome, peer_connection} ->
        {:noreply, record_media_outcome(state, peer_connection, outcome)}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{peer_connection: peer_connection} = state) do
    _ = cancel_peer_connection_recovery_deadline(state.peer_connection_recovery_timer)
    _ = cancel_negotiation_timer(state.negotiation_timer)
    _ = Negotiation.stop(state.negotiation, peer_connection)
    :ok
  end

  defp handle_peer_signal(peer_connection, message, state) do
    state = %{state | peer_connection: peer_connection}

    case PeerConnection.signal(peer_connection, message) do
      {:ice_candidate, candidate} when is_binary(state.negotiation.negotiation_id) ->
        send_event(state, {:ice_candidate, state.negotiation.negotiation_id, candidate})
        {:noreply, state}

      :end_of_candidates when is_binary(state.negotiation.negotiation_id) ->
        send_event(state, {:end_of_candidates, state.negotiation.negotiation_id})
        {:noreply, state}

      {:connection_state_change, connection_state} ->
        Diagnostics.emit("connection_state", :accepted, connection_state: connection_state)

        handle_connection_state_change(connection_state, state)

      _other ->
        {:noreply, state}
    end
  end

  defp handle_connection_state_change(:connected, state) do
    state =
      state
      |> cancel_peer_connection_recovery_deadline()
      |> report_selected_ice_route()

    {:noreply, state}
  end

  defp handle_connection_state_change(:disconnected, state) do
    {:noreply, start_peer_connection_recovery_deadline(state)}
  end

  defp handle_connection_state_change(connection_state, state)
       when connection_state in [:failed, :closed] do
    send_event(
      state,
      {:connection_state_change, connection_state, state.negotiation.negotiation_id}
    )

    {:stop, :normal, state}
  end

  defp handle_connection_state_change(_connection_state, state), do: {:noreply, state}

  defp report_selected_ice_route(state) do
    route = PeerConnection.selected_ice_route(state.peer_connection)

    if route.route_category == state.last_ice_route_category do
      state
    else
      Diagnostics.emit_ice_route(
        state.ice_mode,
        :server,
        route.route_category,
        route.protocol,
        route.outcome,
        route.duration_ms,
        error_code: route.error_code
      )

      %{state | last_ice_route_category: route.route_category}
    end
  end

  defp start_peer_connection_recovery_deadline(%{peer_connection_recovery_timer: timer} = state)
       when not is_nil(timer),
       do: state

  defp start_peer_connection_recovery_deadline(state) do
    recovery_ref = make_ref()

    recovery_timer =
      Process.send_after(
        self(),
        {:peer_connection_recovery_expired, recovery_ref},
        state.peer_connection_recovery_timeout_ms
      )

    %{
      state
      | peer_connection_recovery_timer: recovery_timer,
        peer_connection_recovery_ref: recovery_ref
    }
  end

  defp cancel_peer_connection_recovery_deadline(
         %{peer_connection_recovery_timer: recovery_timer} = state
       ) do
    _ = cancel_peer_connection_recovery_deadline(recovery_timer)
    %{state | peer_connection_recovery_timer: nil, peer_connection_recovery_ref: nil}
  end

  defp cancel_peer_connection_recovery_deadline(nil), do: :ok

  defp cancel_peer_connection_recovery_deadline(recovery_timer),
    do: Process.cancel_timer(recovery_timer)

  defp remaining_timeout(deadline) do
    max(deadline - System.monotonic_time(:millisecond), 1)
  end

  defp command_deadline do
    System.monotonic_time(:millisecond) + @command_timeout_ms
  end

  defp cancel_negotiation_timer(nil), do: nil

  defp cancel_negotiation_timer(timer) do
    _ = Process.cancel_timer(timer)
    nil
  end

  defp send_event(state, event) do
    send(state.signaling_channel, {:voice_session_event, state.voice_session_id, event})
  end

  defp record_media_outcome(state, peer_connection, {:accepted_inbound_track, track_id}) do
    :ok =
      Forwarder.send_ready(state.forwarder, state.voice_session_id, self(), track_id, :opus)

    record_media(state, peer_connection, :inbound_track_admitted, [])
  end

  defp record_media_outcome(
         state,
         peer_connection,
         {:accepted_inbound_rtp, track_id, packet}
       ) do
    GenServer.cast(
      state.room_server,
      {:accepted_inbound_rtp, state.voice_session_id,
       PeerConnection.speaking_activity(peer_connection, packet)}
    )

    :ok = Forwarder.forward_rtp(state.forwarder, state.voice_session_id, track_id, packet)
    record_media(state, peer_connection, :rtp_received, [:inbound_packet_count])
  end

  defp record_media_outcome(
         state,
         peer_connection,
         {:accepted_inbound_track_muted, _track_id}
       ) do
    record_media(state, peer_connection, :inbound_track_muted, [])
  end

  defp record_media_outcome(
         state,
         peer_connection,
         {:accepted_inbound_track_ended, track_id}
       ) do
    :ok = Forwarder.source_ended(state.forwarder, state.voice_session_id, self(), track_id)
    record_media(state, peer_connection, :inbound_track_ended, [])
  end

  defp record_media_outcome(state, peer_connection, :dropped_rtp) do
    record_media(state, peer_connection, :unexpected_media_dropped, [:dropped_packet_count])
  end

  defp record_media_outcome(state, peer_connection, :dropped_media) do
    record_media(state, peer_connection, :unexpected_media_dropped, [:dropped_media_count])
  end

  defp record_dropped_rtp(state) do
    record_media(state, state.peer_connection, :unexpected_media_dropped, [
      :dropped_packet_count
    ])
  end

  defp record_media(state, peer_connection, lifecycle, count_names) do
    media_counts =
      Enum.reduce(count_names, state.media_counts, &increment_media_count(&2, &1))

    Diagnostics.emit_media(lifecycle, media_counts)

    %{state | peer_connection: peer_connection, media_counts: media_counts}
  end

  defp increment_media_count(media_counts, count_name) do
    Map.update!(media_counts, count_name, &(&1 + 1))
  end

  defp empty_media_counts do
    %{
      inbound_packet_count: 0,
      forwarded_packet_count: 0,
      dropped_packet_count: 0,
      dropped_media_count: 0
    }
  end
end
