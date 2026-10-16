defmodule DiscordClone.Media.DirectCallSession do
  @moduledoc false

  use GenServer, restart: :temporary

  alias DiscordClone.Media.{
    CallPeerConnection,
    CallVideoTransport,
    Diagnostics,
    PairCommitCleanup
  }

  alias DiscordClone.Voice.{Forwarder, ICEConfigurationResolver}
  alias DiscordCloneWeb.Signaling.SdpIce

  @lease_duration_ms :timer.seconds(120)
  @renewal_interval_ms :timer.seconds(30)
  @disconnect_grace_ms :timer.seconds(30)
  @keyframe_interval_ms 500
  # Leave room for transport jitter at the destination's 500ms marker limit.
  @keyframe_followup_ms 550

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def accept_offer(session, payload), do: command(session, :offer, payload)
  def add_ice_candidate(session, payload), do: command(session, :candidate, payload)

  def local_media_state(session, payload),
    do: GenServer.call(session, {:local_media_state, payload})

  def renew(session, payload), do: GenServer.call(session, {:renew, payload})

  defp command(session, type, payload) do
    deadline = System.monotonic_time(:millisecond) + 10_000
    GenServer.call(session, {type, payload, deadline}, 10_000)
  catch
    :exit, {:timeout, _} ->
      # A timed-out command cannot retain or publish this exact pair's resources.
      GenServer.cast(session, :signaling_timeout)
      {:error, :negotiation_failed}
  end

  def deliver_rtp(session, session_id, slot, packet),
    do: deliver_rtp(session, session_id, :audio, slot, packet)

  def deliver_rtp(session, session_id, kind, slot, packet),
    do: GenServer.cast(session, {:deliver_rtp, session_id, kind, slot, packet})

  def deliver_video(session, id, route_ref, credit, packets, deadline),
    do:
      GenServer.cast(session, {:deliver_video, self(), id, route_ref, credit, packets, deadline})

  def media_credentials(session, signaling_session_id \\ nil),
    do: GenServer.call(session, {:media_credentials, signaling_session_id})

  def resources(session), do: GenServer.call(session, :resources)

  @impl true
  def init(opts) do
    if Keyword.get(opts, :transport, :fake) == :real do
      Process.flag(:trap_exit, true)

      with :ok <- startup_control(opts),
           {:ok, bundle} <- ICEConfigurationResolver.resolve(link_provider?: true),
           {:ok, peer} <- CallPeerConnection.start_link(bundle.server_projection) do
        forwarder = Keyword.fetch!(opts, :forwarder)
        session_id = Keyword.fetch!(opts, :call_session_id)
        :ok = Forwarder.session_started(forwarder, session_id, self())

        {:ok,
         %{
           connection: %CallPeerConnection{peer_connection: peer},
           ice_bundle: bundle,
           session_id: session_id,
           forwarder: forwarder,
           connected?: false,
           connection_state: :new,
           microphone_muted?: false,
           camera_enabled?: false,
           camera_source_ref: nil,
           camera_version: 0,
           camera_rtp_ready?: false,
           video_route_ref: nil,
           video_presentation: %{epoch: 0, camera_version: nil, rtp_timestamp: nil},
           video_keyframe_at: nil,
           video_keyframe_count: 0,
           video_source_route_ref: nil,
           video_delivery: nil,
           video_diagnostics: %{},
           twcc_last_at: nil,
           twcc_observation: nil,
           video_ice: CallVideoTransport.ice_pid(peer),
           video_closed_relays: MapSet.new(),
           keyframe_last_at: nil,
           keyframe_pending: nil,
           keyframe_ready_source_ref: nil,
           keyframe_followups: 0,
           media_state_version: 0,
           signaling_channel: nil,
           signaling_session_id: nil,
           lease_timer: nil,
           lease_ref: nil,
           lease_deadline: nil,
           disconnect_ref: nil,
           disconnect_timer: nil,
           disconnect_deadline: nil,
           resources: PairCommitCleanup.linked_resources(self()),
           call_id: Keyword.fetch!(opts, :call_id),
           generation: Keyword.fetch!(opts, :runtime_generation),
           room_server: Keyword.fetch!(opts, :room_server),
           transport: :real
         }
         |> renew_lease()}
      else
        _ -> {:stop, :peer_connection_unavailable}
      end
    else
      {:ok, Map.new(opts)}
    end
  end

  @impl true
  def handle_call(:resources, _from, state),
    do: {:reply, Map.get(state, :resources, [self()]), state}

  def handle_call({:media_credentials, signaling_id}, {channel, _}, %{ice_bundle: bundle} = state) do
    state = bind_signaling(state, channel, signaling_id)
    credentials = %{call_session_id: state.session_id, ice_config: bundle.browser_projection}
    negotiation_id = state.connection.negotiation.negotiation_id

    credentials =
      if negotiation_id,
        do: Map.put(credentials, :negotiation_id, negotiation_id),
        else: credentials

    {:reply, {:ok, credentials}, state}
  end

  def handle_call({:media_credentials, _signaling_id}, _from, state),
    do: {:reply, {:error, :not_admitted}, state}

  def handle_call({:local_media_state, payload}, {channel, _}, %{transport: :real} = state) do
    with %{
           "call_id" => call_id,
           "call_session_id" => session_id,
           "signaling_session_id" => signaling_id,
           "negotiation_id" => negotiation_id,
           "media_state_version" => version,
           "microphone_muted" => muted,
           "camera_enabled" => camera_enabled
         }
         when is_integer(version) and version >= 0 and version <= 9_007_199_254_740_991 and
                is_boolean(muted) and is_boolean(camera_enabled) and map_size(payload) == 7 <-
           payload,
         true <- not camera_enabled or DiscordClone.Calls.camera_lifecycle_available?(),
         true <-
           call_id == state.call_id and session_id == state.session_id and
             channel == state.signaling_channel and signaling_id == state.signaling_session_id,
         true <-
           is_binary(negotiation_id) and
             negotiation_id == state.connection.negotiation.negotiation_id and
             not state.connection.negotiation.closed?,
         true <- System.monotonic_time(:millisecond) < state.lease_deadline do
      if version > state.media_state_version do
        camera_version =
          if camera_enabled and not state.camera_enabled?, do: version, else: state.camera_version

        state =
          update_camera_source(%{
            state
            | camera_enabled?: camera_enabled,
              camera_version: camera_version
          })

        {:reply,
         {:ok,
          %{media_state_version: version, microphone_muted: muted, camera_enabled: camera_enabled}},
         %{
           state
           | microphone_muted?: muted,
             camera_enabled?: camera_enabled,
             media_state_version: version
         }}
      else
        {:reply, {:error, :stale_media_state}, state}
      end
    else
      _ -> {:reply, {:error, :not_admitted}, state}
    end
  end

  def handle_call({:local_media_state, _payload}, _from, state),
    do: {:reply, {:error, :not_admitted}, state}

  def handle_call({:renew, payload}, {channel, _}, %{transport: :real} = state) do
    cond do
      System.monotonic_time(:millisecond) >= state.lease_deadline ->
        begin_terminal_cleanup(state)
        {:stop, :normal, {:error, :not_admitted}, state}

      channel == state.signaling_channel and
        payload["call_session_id"] == state.session_id and
          payload["signaling_session_id"] == state.signaling_session_id ->
        {:reply,
         {:ok,
          %{renewal_interval_ms: @renewal_interval_ms, lease_duration_ms: @lease_duration_ms}},
         renew_lease(state)}

      true ->
        {:reply, {:error, :not_admitted}, state}
    end
  end

  def handle_call({:renew, _payload}, _from, state),
    do: {:reply, {:error, :not_admitted}, state}

  def handle_call({:offer, payload, deadline}, {channel, _}, %{connection: connection} = state) do
    with {:ok, offer} <- SdpIce.offer(payload) do
      case CallPeerConnection.accept_offer(
             connection,
             offer.negotiation_id,
             offer.description,
             deadline
           ) do
        {:ok, answer, connection} ->
          state =
            bind_signaling(
              %{state | connection: connection},
              channel,
              payload["signaling_session_id"]
            )

          {:reply, {:ok, answer}, state}

        {:error, reason, connection} ->
          state = %{state | connection: connection}

          if connection.negotiation.closed? do
            begin_terminal_cleanup(state)
            {:stop, :normal, {:error, reason}, state}
          else
            {:reply, {:error, reason}, state}
          end
      end
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:candidate, payload, deadline}, _from, %{connection: connection} = state) do
    case SdpIce.ice_candidate(payload) do
      {:ok, candidate} ->
        case CallPeerConnection.add_ice_candidate(
               connection,
               candidate.negotiation_id,
               candidate,
               deadline
             ) do
          {:ok, reply, connection} ->
            {:reply, {:ok, reply}, %{state | connection: connection}}

          {:error, reason, connection} ->
            {:reply, {:error, reason}, %{state | connection: connection}}
        end

      {:end_of_candidates, candidate} ->
        {:reply, CallPeerConnection.end_of_candidates(connection, candidate.negotiation_id),
         state}

      error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_cast(:signaling_timeout, state), do: terminal_stop(state)

  def handle_cast(
        {:video_route, forwarder, id, ref},
        %{forwarder: forwarder, session_id: id} = state
      ),
      do: {:noreply, replace_video_route(state, ref)}

  def handle_cast({:video_route, _, _, _}, state), do: {:noreply, state}

  def handle_cast(
        {:video_route_status, forwarder, id, ref, status},
        %{forwarder: forwarder, session_id: id, video_route_ref: ref} = state
      )
      when is_reference(ref) and status in [:interrupted, :recovering, :active] do
    # The private route token is checked here and stays server-local. This is
    # route consumption evidence, never decoded/presented-frame readiness.
    send_signal(state, %{video_route_status: status})
    {:noreply, state}
  end

  def handle_cast({:video_route_status, _, _, _, _}, state), do: {:noreply, state}

  def handle_cast(
        {:video_source_route, forwarder, id, {source_ref, route_ref}},
        %{forwarder: forwarder, session_id: id, camera_source_ref: source_ref} = state
      )
      when is_reference(source_ref) and is_reference(route_ref) do
    state = if state.video_source_route_ref == route_ref, do: state, else: cancel_keyframe(state)
    next = %{state | video_source_route_ref: route_ref}

    # A new exact destination route is the proactive readiness/rebuild edge.
    next =
      if state.video_source_route_ref == route_ref,
        do: next,
        else: request_ready_keyframe(next)

    {:noreply, next}
  end

  def handle_cast(
        {:video_source_route, forwarder, id, nil},
        %{forwarder: forwarder, session_id: id} = state
      ),
      do: {:noreply, %{cancel_keyframe(state) | video_source_route_ref: nil}}

  def handle_cast({:video_source_route, _, _, _}, state), do: {:noreply, state}

  def handle_cast(
        {:request_keyframe, forwarder, id, track, source_ref, route_ref},
        %{
          forwarder: forwarder,
          session_id: id,
          connected?: true,
          camera_enabled?: true,
          camera_rtp_ready?: true,
          camera_source_ref: source_ref,
          video_source_route_ref: route_ref,
          connection: %{video: %{inbound_track_id: track}}
        } = state
      )
      when is_reference(source_ref) and is_reference(route_ref) do
    {:noreply, coalesce_keyframe(state, track)}
  end

  def handle_cast({:request_keyframe, _, _, _, _, _}, state), do: {:noreply, state}

  def handle_cast(
        {:deliver_video, forwarder, id, route_ref, credit, packets, deadline},
        %{forwarder: forwarder, session_id: id} = state
      ) do
    if state.connected? and state.video_route_ref == route_ref and state.video_delivery == nil and
         System.monotonic_time(:millisecond) < deadline do
      state = publish_video_keyframe(state, packets)
      Enum.each(packets, &CallPeerConnection.send_rtp(state.connection, :video, 0, &1))
      request = :gen_server.send_request(state.connection.peer_connection, :get_stats)
      delivery = %{request: request, stage: :dtls, route_ref: route_ref, credit: credit}
      {:noreply, %{state | video_delivery: delivery}}
    else
      Forwarder.video_delivered(forwarder, id, self(), route_ref, credit, :dropped)
      {:noreply, state}
    end
  end

  def handle_cast({:deliver_video, _, _, _, _, _, _}, state), do: {:noreply, state}

  def handle_cast(
        {:deliver_rtp, id, kind, slot, packet},
        %{session_id: id, connected?: true} = state
      )
      when kind == :audio do
    _ = CallPeerConnection.send_rtp(state.connection, kind, slot, packet)
    {:noreply, state}
  end

  def handle_cast({:deliver_rtp, _id, _kind, _slot, _packet}, state), do: {:noreply, state}

  @impl true
  def handle_info({:keyframe_due, ref, track}, %{keyframe_pending: %{ref: ref}} = state) do
    {:noreply, coalesce_keyframe(%{state | keyframe_pending: nil}, track)}
  end

  def handle_info({:keyframe_due, _, _}, state), do: {:noreply, state}

  def handle_info({:lease_expired, ref}, %{lease_ref: ref} = state), do: terminal_stop(state)

  def handle_info({:disconnect_expired, ref}, %{disconnect_ref: ref} = state)
      when is_reference(ref),
      do: terminal_stop(state)

  def handle_info({:EXIT, peer, _reason}, %{connection: %{peer_connection: peer}} = state),
    do: terminal_stop(state)

  def handle_info(
        {:ex_webrtc, peer, {:connection_state_change, status}},
        %{connection: %{peer_connection: peer}} = state
      )
      when status in [:failed, :closed] do
    terminal_stop(state, status)
  end

  def handle_info(
        {:ex_webrtc, peer, {:connection_state_change, :connected}},
        %{connection: %{peer_connection: peer}, disconnect_deadline: deadline} = state
      )
      when is_integer(deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      terminal_stop(state)
    else
      connection_changed(:connected, clear_disconnect(state))
    end
  end

  def handle_info(
        {:ex_webrtc, peer, {:connection_state_change, status}},
        %{connection: %{peer_connection: peer}} = state
      ) do
    connection_changed(status, state)
  end

  def handle_info(
        {:ex_webrtc, peer, {:ice_candidate, candidate}},
        %{connection: %{peer_connection: peer}} = state
      ) do
    send_signal(state, %{candidate: ExWebRTC.ICECandidate.to_json(candidate)})
    {:noreply, state}
  end

  def handle_info(
        {:ex_webrtc, peer, {:ice_gathering_state_change, :complete}},
        %{connection: %{peer_connection: peer}} = state
      ) do
    send_signal(state, %{end_of_candidates: true})
    {:noreply, state}
  end

  def handle_info(
        {:ex_webrtc, peer, {:track_ended, track}},
        %{connection: %{peer_connection: peer, audio: %{inbound_track_id: track}}} = state
      ),
      do: terminal_stop(state)

  def handle_info(
        {:ex_webrtc, peer, {:track_ended, track}},
        %{connection: %{peer_connection: peer, video: %{inbound_track_id: track}}} = state
      ) do
    {:noreply, withdraw_camera_source(state)}
  end

  def handle_info(
        {:video_consumption_retry, credit},
        %{video_delivery: %{credit: credit, stage: :suspended} = delivery} = state
      ) do
    request = CallVideoTransport.request(state.video_ice)
    {:noreply, %{state | video_delivery: %{delivery | request: request, stage: :relay}}}
  end

  def handle_info(
        {request, ice_state},
        %{video_delivery: %{request: request, stage: :relay} = delivery} = state
      ) do
    case CallVideoTransport.completion(ice_state) do
      {:consumed, closed} ->
        # Retirement may precede the first observation. Drop that credit once,
        # then permit fresh keyframes despite retained, inert closed storage.
        delivery =
          if MapSet.subset?(closed, state.video_closed_relays),
            do: delivery,
            else: Map.put(delivery, :outcome, :dropped)

        {:noreply, complete_video_delivery(%{state | video_closed_relays: closed}, delivery)}

      :pending ->
        Process.send_after(self(), {:video_consumption_retry, delivery.credit}, 100)
        delivery = Map.merge(delivery, %{request: nil, stage: :suspended, outcome: :dropped})
        {:noreply, %{state | video_delivery: delivery}}
    end
  end

  def handle_info({:twcc_observation_expired, ref}, %{twcc_observation: %{ref: ref}} = state) do
    # Abandon the native request alias/monitor even if the peer stays held.
    _ = :gen_server.receive_response(state.twcc_observation.request, 0)
    {:noreply, finish_twcc_observation(state, :unavailable, %{})}
  end

  def handle_info({:twcc_observation_expired, _}, state), do: {:noreply, state}

  def handle_info(message, %{twcc_observation: %{request: request} = observation} = state) do
    case :gen_server.check_response(message, request) do
      {:reply, log} when observation.stage == :departures ->
        counts =
          Map.merge(
            observation.counts,
            Diagnostics.departure_summary(log, observation.base, observation.count)
          )

        request = :gen_server.send_request(state.connection.peer_connection, :get_stats)

        {:noreply,
         %{
           state
           | twcc_observation: %{observation | request: request, stage: :stats, counts: counts}
         }}

      {:reply, stats} ->
        route = DiscordClone.Voice.PeerConnection.classify_ice_route(stats)

        {:noreply,
         finish_twcc_observation(
           state,
           :sampled,
           Map.put(observation.counts, :route_category, route.route_category)
         )}

      {:error, _} ->
        {:noreply, finish_twcc_observation(state, :unavailable, %{})}

      :no_reply ->
        handle_delivery_message(message, state)
    end
  end

  def handle_info(message, state), do: handle_delivery_message(message, state)

  defp handle_delivery_message(message, %{video_delivery: %{request: request} = delivery} = state)
       when request != nil and delivery.stage in [:dtls, :ice] do
    # ExWebRTC 0.17's public get_stats handler visits ICE, then DTLS. The first
    # reply follows PC RTP handling and DTLS consumption; the second visits ICE
    # after those DTLS submissions. This proves transport handling (including
    # discard), not remote reception. Never release credit merely on cast return.
    case :gen_server.check_response(message, request) do
      {:reply, _stats} when delivery.stage == :dtls ->
        request = :gen_server.send_request(state.connection.peer_connection, :get_stats)
        {:noreply, %{state | video_delivery: %{delivery | request: request, stage: :ice}}}

      {:reply, stats} ->
        # A missing viable pair means transport discard, not a permanently
        # occupied credit. Still inspect native buffers before releasing it.
        outcome = if video_transport_consumed?(stats), do: :consumed, else: :dropped
        request = CallVideoTransport.request(state.video_ice)
        delivery = Map.merge(delivery, %{request: request, stage: :relay, outcome: outcome})
        {:noreply, %{state | video_delivery: delivery}}

      {:error, _reason} ->
        terminal_stop(state)

      :no_reply ->
        handle_media_message(message, state)
    end
  end

  defp handle_delivery_message(message, state), do: handle_media_message(message, state)

  defp handle_media_message(
         {:ex_webrtc, peer, {:rtcp, packets}} = message,
         %{connection: %{peer_connection: peer}, connected?: true} = state
       ) do
    feedback =
      Enum.find_value(packets, fn
        {nil, %ExRTCP.Packet.TransportFeedback.CC{} = cc} -> cc
        _ -> nil
      end)

    now = System.monotonic_time(:millisecond)

    state =
      if feedback && state.twcc_observation == nil &&
           (state.twcc_last_at == nil || now - state.twcc_last_at >= 10_000) do
        request = :gen_server.send_request(peer, :get_twcc_departure_log)
        ref = make_ref()
        timer = Process.send_after(self(), {:twcc_observation_expired, ref}, 1_000)
        summary = Diagnostics.feedback_summary(feedback)

        observation = %{
          request: request,
          ref: ref,
          timer: timer,
          stage: :departures,
          base: summary.base,
          count: summary.count,
          counts: Map.take(summary, [:received_packets, :lost_packets])
        }

        %{state | twcc_last_at: now, twcc_observation: observation}
      else
        state
      end

    route_media_message(message, state)
  end

  defp handle_media_message(message, state), do: route_media_message(message, state)

  defp finish_twcc_observation(state, outcome, counts) do
    Process.cancel_timer(state.twcc_observation.timer)
    counts = Map.put(counts, :mailbox_len, Diagnostics.queue_snapshot(self()).mailbox_len)
    history = Diagnostics.observe_video(state.video_diagnostics, :twcc, outcome, counts)
    %{state | twcc_observation: nil, video_diagnostics: history}
  end

  defp route_media_message(message, %{connection: connection, connected?: true} = state) do
    state =
      case CallPeerConnection.route_media(connection, message) do
        {{:accepted_inbound_rtp, track, packet}, _connection} when not state.microphone_muted? ->
          :ok =
            Forwarder.forward_rtp(
              state.forwarder,
              state.session_id,
              self(),
              :audio,
              track,
              packet
            )

          state

        {{:accepted_inbound_video_rtp, track, packet}, _connection}
        when state.camera_enabled? and is_reference(state.camera_source_ref) ->
          Forwarder.forward_rtp(
            state.forwarder,
            state.session_id,
            self(),
            :video,
            track,
            state.camera_source_ref,
            packet
          )

          # ExWebRTC 0.17 learns the source SSRC from RTP, not SDP. First current
          # camera RTP is the source-ready edge, regardless of route-ready order.
          if state.camera_rtp_ready?,
            do: state,
            else: request_ready_keyframe(%{state | camera_rtp_ready?: true})

        {:decoder_keyframe_request, _connection} when is_reference(state.video_route_ref) ->
          Forwarder.request_keyframe(
            state.forwarder,
            state.session_id,
            self(),
            state.video_route_ref
          )

          state

        _ ->
          state
      end

    {:noreply, state}
  end

  defp route_media_message(_message, state), do: {:noreply, state}

  defp video_transport_consumed?(stats) do
    Enum.any?(Map.values(stats), &match?(%{type: :candidate_pair, valid: true}, &1))
  end

  defp complete_video_delivery(state, delivery) do
    Forwarder.video_delivered(
      state.forwarder,
      state.session_id,
      self(),
      delivery.route_ref,
      delivery.credit,
      Map.get(delivery, :outcome, :consumed)
    )

    %{state | video_delivery: nil}
  end

  @impl true
  def terminate(_reason, %{connection: connection} = state) do
    case state.video_delivery do
      %{stage: :relay, request: request} -> CallVideoTransport.cancel(request)
      _ -> :ok
    end

    if state.twcc_observation do
      Process.cancel_timer(state.twcc_observation.timer)
      _ = :gen_server.receive_response(state.twcc_observation.request, 0)
    end

    cancel_keyframe(state)
    Process.cancel_timer(state.lease_timer)
    if state.disconnect_timer, do: Process.cancel_timer(state.disconnect_timer)
    CallPeerConnection.stop(connection)
  end

  def terminate(_reason, _state), do: :ok

  defp connection_changed(status, state) do
    state =
      case status do
        :disconnected -> start_disconnect_grace(state)
        :connected -> clear_disconnect(state)
        _ -> state
      end

    state = %{state | connected?: status == :connected}

    state =
      if state.connected? do
        :ok = Forwarder.receive_ready(state.forwarder, state.session_id, self(), :audio, :opus)
        :ok = Forwarder.receive_ready(state.forwarder, state.session_id, self(), :video, :vp8)
        state = update_camera_source(state)

        :ok =
          Forwarder.send_ready(
            state.forwarder,
            state.session_id,
            self(),
            :audio,
            state.connection.audio.inbound_track_id,
            :opus
          )

        state
      else
        :ok = Forwarder.receive_unready(state.forwarder, state.session_id, self())

        %{
          cancel_keyframe(state)
          | camera_source_ref: nil,
            camera_rtp_ready?: false,
            video_route_ref: nil,
            video_source_route_ref: nil
        }
      end

    GenServer.cast(state.room_server, {:connection_state, state.session_id, self(), status})

    {:noreply, observe_connection_state(state, status)}
  end

  defp observe_connection_state(%{connection_state: status} = state, status), do: state

  defp observe_connection_state(state, status) do
    Diagnostics.emit_call_connection_state(status)
    %{state | connection_state: status}
  end

  defp terminal_stop(state, status \\ nil) do
    begin_terminal_cleanup(state)
    :ok = Forwarder.receive_unready(state.forwarder, state.session_id, self())
    # Start the end-to-end clock before any external telemetry handler can wait.
    state = if status, do: observe_connection_state(state, status), else: state
    {:stop, :normal, state}
  end

  defp begin_terminal_cleanup(state) do
    DiscordClone.Media.AdmissionCoordinator.begin_terminal_cleanup(
      state.call_id,
      state.generation
    )
  end

  defp withdraw_camera_source(state) do
    Forwarder.source_ended(
      state.forwarder,
      state.session_id,
      self(),
      :video,
      state.connection.video.inbound_track_id
    )

    %{
      cancel_keyframe(state)
      | camera_source_ref: nil,
        camera_rtp_ready?: false,
        video_source_route_ref: nil
    }
  end

  defp request_ready_keyframe(
         %{
           connected?: true,
           camera_enabled?: true,
           camera_rtp_ready?: true,
           camera_source_ref: source_ref,
           video_source_route_ref: route_ref
         } = state
       )
       when is_reference(source_ref) and is_reference(route_ref) do
    # A compositor can skip early decoded keyframes. Fresh capture gets one
    # spaced opportunity; a retained-camera rebuild gets three. Both use the
    # same single timer and source cooldown as decoder feedback.
    followups = if state.keyframe_ready_source_ref == source_ref, do: 3, else: 1

    coalesce_keyframe(
      %{state | keyframe_ready_source_ref: source_ref, keyframe_followups: followups},
      state.connection.video.inbound_track_id
    )
  end

  defp request_ready_keyframe(state), do: state

  defp coalesce_keyframe(state, track) do
    now = System.monotonic_time(:millisecond)

    cond do
      is_nil(state.keyframe_last_at) or now - state.keyframe_last_at >= @keyframe_interval_ms ->
        followups = state.keyframe_followups
        state = cancel_keyframe(state)
        _ = CallPeerConnection.request_keyframe(state.connection, track)
        state = %{state | keyframe_last_at: now}

        if followups > 0,
          do:
            schedule_keyframe(
              %{state | keyframe_followups: followups - 1},
              track,
              @keyframe_followup_ms
            ),
          else: state

      state.keyframe_pending ->
        state

      true ->
        schedule_keyframe(state, track, @keyframe_interval_ms - (now - state.keyframe_last_at))
    end
  end

  defp schedule_keyframe(state, track, delay) do
    ref = make_ref()
    timer = Process.send_after(self(), {:keyframe_due, ref, track}, delay)
    %{state | keyframe_pending: %{ref: ref, timer: timer}}
  end

  defp cancel_keyframe(state) do
    if state.keyframe_pending, do: Process.cancel_timer(state.keyframe_pending.timer)
    %{state | keyframe_pending: nil, keyframe_followups: 0}
  end

  defp update_camera_source(%{connected?: true, camera_enabled?: true} = state) do
    source_ref = state.camera_source_ref || make_ref()

    Forwarder.send_ready(
      state.forwarder,
      state.session_id,
      self(),
      :video,
      state.connection.video.inbound_track_id,
      :vp8,
      source_ref,
      state.camera_version
    )

    %{state | camera_source_ref: source_ref}
  end

  defp update_camera_source(state), do: withdraw_camera_source(state)

  defp bind_signaling(state, channel, signaling_id) when is_binary(signaling_id),
    do: %{state | signaling_channel: channel, signaling_session_id: signaling_id}

  defp bind_signaling(state, _channel, _signaling_id), do: state

  defp replace_video_route(state, binding) do
    {ref, version} =
      case binding do
        {ref, version} -> {ref, version}
        ref -> {ref, nil}
      end

    if state.video_route_ref == ref do
      state
    else
      presentation = %{
        epoch: state.video_presentation.epoch + 1,
        camera_version: version,
        rtp_timestamp: nil
      }

      send_signal(state, %{video_presentation: presentation})

      %{
        state
        | video_route_ref: ref,
          video_presentation: presentation,
          video_keyframe_at: nil,
          video_keyframe_count: 0
      }
    end
  end

  defp publish_video_keyframe(
         %{video_presentation: %{camera_version: version}} = state,
         [packet | _]
       )
       when is_integer(version) do
    # Delivery contains one validated, complete, munged frame. The pinned
    # sender preserves its RTP timestamp, including in destination repair.
    {:ok, descriptor} = ExWebRTC.RTP.VP8.Payload.parse(packet.payload)

    now = System.monotonic_time(:millisecond)

    if rem(:binary.first(descriptor.payload), 2) == 0 and
         (state.video_keyframe_count < 2 or now - state.video_keyframe_at >= 500) do
      presentation = %{state.video_presentation | rtp_timestamp: packet.timestamp}
      send_signal(state, %{video_presentation: presentation})

      %{
        state
        | video_presentation: presentation,
          video_keyframe_at: now,
          video_keyframe_count: min(state.video_keyframe_count + 1, 2)
      }
    else
      state
    end
  end

  defp publish_video_keyframe(state, _packets), do: state

  defp send_signal(%{signaling_channel: channel, connection: connection} = state, event)
       when is_pid(channel) do
    if negotiation_id = connection.negotiation.negotiation_id do
      send(
        channel,
        {:call_media_event, state.session_id, state.signaling_session_id, negotiation_id, event}
      )
    end
  end

  defp send_signal(_state, _event), do: :ok

  defp startup_control(opts) do
    DiscordClone.Media.DirectCallTarget.startup_control(:session_starting, Map.new(opts))
  end

  defp renew_lease(state) do
    if state.lease_timer, do: Process.cancel_timer(state.lease_timer)
    ref = make_ref()

    %{
      state
      | lease_ref: ref,
        lease_timer: Process.send_after(self(), {:lease_expired, ref}, @lease_duration_ms),
        lease_deadline: System.monotonic_time(:millisecond) + @lease_duration_ms
    }
  end

  defp start_disconnect_grace(%{disconnect_ref: ref} = state) when is_reference(ref), do: state

  defp start_disconnect_grace(state) do
    ref = make_ref()

    %{
      state
      | disconnect_ref: ref,
        disconnect_timer:
          Process.send_after(self(), {:disconnect_expired, ref}, @disconnect_grace_ms),
        disconnect_deadline: System.monotonic_time(:millisecond) + @disconnect_grace_ms
    }
  end

  defp clear_disconnect(state) do
    if state.disconnect_timer, do: Process.cancel_timer(state.disconnect_timer)
    %{state | disconnect_ref: nil, disconnect_timer: nil, disconnect_deadline: nil}
  end
end
