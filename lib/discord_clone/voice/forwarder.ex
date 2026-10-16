defmodule DiscordClone.Voice.Forwarder do
  @moduledoc false

  use GenServer

  alias DiscordClone.Media.{AdmissionCoordinator, DirectCallSession, Target, VideoAdmission}
  alias DiscordClone.Voice.{Diagnostics, RoomRegistry, Session}
  alias ExWebRTC.RTP.Munger

  @opus_clock_rate 48_000

  @type voice_session_id :: Ecto.UUID.t()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    voice_channel_id = Keyword.fetch!(opts, :voice_channel_id)

    GenServer.start_link(__MODULE__, opts,
      name: {:via, Registry, {RoomRegistry, {:forwarder, voice_channel_id}}}
    )
  end

  # Calls reuse the room-local forwarding machinery with their own identity,
  # media-kind readiness and delivery adapter. Voice's public API stays intact.
  def start_call_link(call_id, generation) do
    GenServer.start_link(__MODULE__, {:call, call_id, generation},
      name: Target.runtime_name(Target.direct_call(call_id), generation, :forwarder)
    )
  end

  @spec session_started(pid() | nil, voice_session_id(), pid()) :: :ok | {:error, :full}
  def session_started(forwarder, voice_session_id, session) when is_pid(forwarder) do
    GenServer.call(forwarder, {:session_started, voice_session_id, session})
  end

  def session_started(_missing_forwarder, _voice_session_id, _session), do: :ok

  @spec receive_ready(pid() | nil, voice_session_id(), pid(), :opus) :: :ok
  def receive_ready(forwarder, voice_session_id, session, :opus) when is_pid(forwarder) do
    receive_ready(forwarder, voice_session_id, session, :audio, :opus)
  end

  def receive_ready(_missing_forwarder, _voice_session_id, _session, :opus), do: :ok

  @spec send_ready(pid() | nil, voice_session_id(), pid(), integer(), :opus) :: :ok
  def send_ready(forwarder, voice_session_id, session, inbound_track_id, :opus)
      when is_pid(forwarder) do
    send_ready(forwarder, voice_session_id, session, :audio, inbound_track_id, :opus)
  end

  def send_ready(_missing_forwarder, _voice_session_id, _session, _inbound_track_id, :opus),
    do: :ok

  @spec source_ended(pid() | nil, voice_session_id(), pid(), integer()) :: :ok
  def source_ended(forwarder, voice_session_id, session, inbound_track_id)
      when is_pid(forwarder) do
    source_ended(forwarder, voice_session_id, session, :audio, inbound_track_id)
  end

  def source_ended(_missing_forwarder, _voice_session_id, _session, _inbound_track_id), do: :ok

  @spec session_removed(pid() | nil, voice_session_id()) :: :ok
  def session_removed(forwarder, voice_session_id) when is_pid(forwarder) do
    GenServer.call(forwarder, {:session_removed, voice_session_id})
  end

  def session_removed(_missing_forwarder, _voice_session_id), do: :ok

  @spec set_source_muted(pid() | nil, voice_session_id(), boolean()) :: :ok
  def set_source_muted(forwarder, voice_session_id, muted)
      when is_pid(forwarder) and is_boolean(muted) do
    GenServer.call(forwarder, {:set_source_muted, voice_session_id, muted})
  end

  def set_source_muted(_missing_forwarder, _voice_session_id, _muted), do: :ok

  @spec forward_rtp(pid() | nil, voice_session_id(), integer(), ExRTP.Packet.t()) :: :ok
  def forward_rtp(forwarder, voice_session_id, inbound_track_id, packet)
      when is_pid(forwarder) do
    GenServer.cast(forwarder, {:forward_rtp, voice_session_id, inbound_track_id, packet})
  end

  def forward_rtp(_missing_forwarder, _voice_session_id, _inbound_track_id, _packet), do: :ok

  def forward_rtp(forwarder, session_id, session, track_id, packet),
    do: forward_rtp(forwarder, session_id, session, :audio, track_id, packet)

  # Qualified transitions are used by Calls; legacy Voice commands remain audio-only.
  def receive_ready(forwarder, id, session, kind, codec),
    do: GenServer.cast(forwarder, {:receive_ready, id, session, kind, codec})

  def send_ready(forwarder, id, session, kind, track, codec),
    do: send_ready(forwarder, id, session, kind, track, codec, nil)

  def send_ready(forwarder, id, session, kind, track, codec, source_ref),
    do: send_ready(forwarder, id, session, kind, track, codec, source_ref, nil)

  def send_ready(forwarder, id, session, kind, track, codec, source_ref, camera_version),
    do:
      GenServer.cast(
        forwarder,
        {:send_ready, id, session, kind, track, codec, source_ref, camera_version}
      )

  # Decoder and future proactive causes share this exact current route boundary.
  def request_keyframe(forwarder, id, session, route_ref),
    do: GenServer.cast(forwarder, {:request_keyframe, id, session, route_ref})

  def source_ended(forwarder, id, session, kind, track),
    do: GenServer.cast(forwarder, {:source_ended, id, session, kind, track})

  def receive_unready(forwarder, id, session, kind),
    do: GenServer.cast(forwarder, {:receive_unready, id, session, kind})

  def forward_rtp(forwarder, id, session, :video, track, packet),
    do: submit_video(forwarder, {:forward_rtp, id, session, :video, track, packet})

  def forward_rtp(forwarder, id, session, kind, track, packet),
    do: GenServer.cast(forwarder, {:forward_rtp, id, session, kind, track, packet})

  def forward_rtp(forwarder, id, session, :video, track, source_ref, packet),
    do: submit_video(forwarder, {:forward_video, id, session, track, source_ref, packet})

  def video_delivered(forwarder, id, session, route_ref, credit, outcome \\ :consumed),
    do: GenServer.cast(forwarder, {:video_delivered, id, session, route_ref, credit, outcome})

  # On-demand, bounded observations for the exact retained receiver. No private
  # route/Session identity or packet data escapes this boundary.
  def video_route_status(forwarder, id, session),
    do: GenServer.call(forwarder, {:video_route_status, id, session})

  # Two local Call sources may race this observation. Each stops adding video
  # at 256 queued messages; audio/control are not subject to this video gate.
  defp submit_video(forwarder, message) do
    case Process.info(forwarder, :message_queue_len) do
      {:message_queue_len, count} when count < 256 -> GenServer.cast(forwarder, message)
      _ -> :ok
    end
  end

  def session_removed(forwarder, session_id, session) do
    GenServer.call(forwarder, {:session_removed, session_id, session})
  end

  def receive_unready(forwarder, session_id, session) do
    GenServer.cast(forwarder, {:receive_unready, session_id, session})
  end

  @doc false
  @spec sync(pid()) :: :ok
  def sync(forwarder), do: GenServer.call(forwarder, :sync)

  @impl true
  def init({:call, call_id, _generation}) do
    {:ok,
     initial_state(%{
       call_id: call_id,
       delivery_module: DirectCallSession,
       audio_output_slots: [0],
       capacity: 2
     })}
  end

  def init(opts) do
    voice_channel_id = Keyword.fetch!(opts, :voice_channel_id)
    room_server = room_server(voice_channel_id)

    AdmissionCoordinator.forwarder_started(voice_channel_id, self(), room_server)

    if is_pid(room_server) do
      send(room_server, {:forwarder_started, room_server, self()})
    end

    {:ok,
     initial_state(%{
       voice_channel_id: voice_channel_id,
       room_server: room_server,
       delivery_module: Session,
       audio_output_slots: 0..3,
       capacity: 5
     })}
  end

  defp initial_state(identity) do
    Map.merge(identity, %{
      sessions: %{},
      next_session_order: 0,
      slot_assignments: %{},
      slot_mungers: %{},
      video_timelines: %{},
      video_credits: %{},
      video_drain: nil,
      video_diagnostics: %{},
      routes: %{},
      forwarded_packet_count: 0,
      dropped_packet_count: 0
    })
  end

  @impl true
  def handle_call({:session_started, id, _session}, _from, state)
      when not is_map_key(state.sessions, id) and map_size(state.sessions) >= state.capacity,
      do: {:reply, {:error, :full}, state}

  def handle_call({:session_started, voice_session_id, session}, _from, state) do
    {session_state, next_session_order} =
      case Map.get(state.sessions, voice_session_id) do
        %{session: ^session} = current ->
          {current, state.next_session_order}

        %{started_order: started_order} ->
          {%{
             session: session,
             media: empty_media(),
             muted: false,
             started_order: started_order
           }, state.next_session_order}

        nil ->
          {%{
             session: session,
             media: empty_media(),
             muted: false,
             started_order: state.next_session_order
           }, state.next_session_order + 1}
      end

    state = retire_replaced_session(state, voice_session_id, session)
    session_state = monitor_call_session(state, session_state)

    state =
      state
      |> put_in([:sessions, voice_session_id], session_state)
      |> Map.put(:next_session_order, next_session_order)
      |> rebuild_routes()

    {:reply, :ok, state}
  end

  def handle_call({:session_removed, id, session}, from, state) do
    case Map.get(state.sessions, id) do
      %{session: ^session} -> handle_call({:session_removed, id}, from, state)
      _ -> {:reply, :ok, state}
    end
  end

  def handle_call({:session_removed, voice_session_id}, _from, state) do
    demonitor_session(Map.get(state.sessions, voice_session_id))

    state =
      state
      |> update_in([:sessions], &Map.delete(&1, voice_session_id))
      |> rebuild_routes()

    {:reply, :ok, state}
  end

  def handle_call({:set_source_muted, voice_session_id, muted}, _from, state) do
    state =
      case Map.get(state.sessions, voice_session_id) do
        nil ->
          state

        session_state ->
          state
          |> put_in([:sessions, voice_session_id], %{session_state | muted: muted})
          |> rebuild_routes()
      end

    {:reply, :ok, state}
  end

  def handle_call(:sync, _from, state), do: {:reply, :ok, state}

  def handle_call({:video_route_status, id, session}, _from, state) do
    reply =
      case current_video_route(state.routes, id, session) do
        {_, route} -> {:ok, route.status}
        nil -> {:error, :not_ready}
      end

    {:reply, reply, state}
  end

  @impl true
  # Shared transport loss withdraws every kind. Video-only loss must be qualified.
  def handle_cast({:receive_unready, id, session}, state) do
    {:noreply, update_session(state, id, session, &%{&1 | media: empty_media()})}
  end

  def handle_cast({:video_delivered, id, session, route_ref, credit, outcome}, state) do
    case Map.get(state.video_credits, id) do
      %{session: ^session, route_ref: ^route_ref, credit: ^credit, pending: nil} = delivery ->
        cancel_video_expiry(delivery.timer)

        state =
          case {outcome, video_route(state.routes, id, session, route_ref)} do
            {:dropped, {source, route}} -> drop_video_frame(state, source, id, route)
            _ -> state
          end

        state =
          case current_video_route(state.routes, id, session) do
            {source, %{status: %{state: :interrupted}} = route} ->
              # A consumed old credit may free the retained PC, but cannot
              # revive its retired source. Only the current route requests PLI.
              request_video_recovery(source, route, true)
              set_video_status(state, source, id, route, :recovering)

            {source, %{ref: ^route_ref} = route} when outcome == :dropped ->
              set_video_status(state, source, id, route, :recovering)

            {source, %{ref: ^route_ref, admission: %{waiting?: false}} = route}
            when outcome == :consumed ->
              set_video_status(state, source, id, route, :active)

            _ ->
              state
          end

        {:noreply, update_in(state.video_credits, &Map.delete(&1, id))}

      _ ->
        {:noreply, state}
    end
  end

  def handle_cast({:receive_unready, id, session, kind}, state) do
    {:noreply, update_media(state, id, session, kind, fn _ -> empty_readiness() end)}
  end

  def handle_cast({:receive_ready, id, session, kind, codec}, state) do
    state =
      if supported_media?(state, kind, codec) do
        update_media(state, id, session, kind, &%{&1 | receive_codec: codec})
      else
        state
      end

    {:noreply, state}
  end

  def handle_cast(
        {:send_ready, id, session, kind, track, codec, source_ref, camera_version},
        state
      ) do
    state =
      if supported_media?(state, kind, codec) and is_integer(track) do
        update_media(
          state,
          id,
          session,
          kind,
          &%{
            &1
            | source: %{
                track_id: track,
                codec: codec,
                ref: source_ref,
                camera_version: camera_version
              }
          }
        )
      else
        state
      end

    {:noreply, state}
  end

  def handle_cast({:source_ended, id, session, kind, track}, state) do
    {:noreply,
     update_media(state, id, session, kind, fn
       %{source: %{track_id: ^track}} = media -> %{media | source: nil}
       media -> media
     end)}
  end

  def handle_cast({:request_keyframe, id, session, ref}, state) do
    case video_route(state.routes, id, session, ref) do
      {{:video, source_id, track}, %{identity: {source_session, _, source_ref}, ref: ref}} ->
        GenServer.cast(
          source_session,
          {:request_keyframe, self(), source_id, track, source_ref, ref}
        )

        {:noreply, state}

      nil ->
        {:noreply, state}
    end
  end

  def handle_cast({:forward_rtp, id, session, kind, track_id, packet}, state) do
    case Map.get(state.sessions, id) do
      %{session: ^session} -> forward_packet(state, kind, id, track_id, packet)
      _ -> {:noreply, record_drop(state)}
    end
  end

  def handle_cast({:forward_video, id, session, track, ref, packet}, state) do
    case Map.get(state.sessions, id) do
      %{session: ^session, media: %{video: %{source: %{track_id: ^track, ref: ^ref}}}} ->
        forward_packet(state, :video, id, track, packet)

      _ ->
        {:noreply, record_drop(state)}
    end
  end

  # The legacy Voice command is never admissible to a Call target.
  def handle_cast({:forward_rtp, id, track_id, packet}, %{delivery_module: Session} = state),
    do: forward_packet(state, :audio, id, track_id, packet)

  def handle_cast({:forward_rtp, _id, _track_id, _packet}, state),
    do: {:noreply, record_drop(state)}

  @impl true
  def handle_info({:drain_video, ref}, %{video_drain: ref} = state) do
    state = %{state | video_drain: nil}

    {:noreply,
     Enum.reduce(state.video_credits, state, fn
       {id, %{pending: {source, packets, deadline}} = delivery}, state ->
         case get_in(state.routes, [source, id]) do
           %{ref: route_ref, session: session} = route
           when route_ref == delivery.route_ref and session == delivery.session ->
             if System.monotonic_time(:millisecond) < deadline do
               drain_video(state, source, id, route, delivery, packets, deadline)
             else
               state
               |> drop_video_frame(source, id, route)
               |> update_in([:video_credits], &Map.delete(&1, id))
             end

           _ ->
             update_in(state.video_credits, &Map.delete(&1, id))
         end

       _, state ->
         state
     end)}
  end

  def handle_info({:drain_video, _}, state), do: {:noreply, state}

  def handle_info({:video_delivery_due, id, session, credit}, state) do
    state =
      case Map.get(state.video_credits, id) do
        %{session: ^session, credit: ^credit} ->
          case current_video_route(state.routes, id, session) do
            {source, route} -> interrupt_video(state, source, id, route)
            nil -> state
          end

        _ ->
          state
      end

    {:noreply, state}
  end

  def handle_info({:expire_video, ref, timestamp}, state) do
    state =
      Enum.reduce(state.routes, state, fn {source, routes}, state ->
        Enum.reduce(routes, state, fn
          {id, %{ref: ^ref, admission: %{timestamp: ^timestamp, frame: frame}} = route}, state
          when frame != nil ->
            {admission, [], request?} = VideoAdmission.expire(route.admission)
            request_video_recovery(source, route, request?)
            put_in(state, [:routes, source, id], %{route | admission: admission, expiry: nil})

          _, state ->
            state
        end)
      end)

    {:noreply, state}
  end

  def handle_info({:DOWN, monitor, :process, session, _reason}, state) do
    sessions =
      Map.reject(state.sessions, fn {_id, current} ->
        current.session == session and Map.get(current, :monitor) == monitor
      end)

    {:noreply, rebuild_routes(%{state | sessions: sessions})}
  end

  defp retire_replaced_session(state, id, session) do
    case Map.get(state.sessions, id) do
      %{session: old} = current when old != session ->
        demonitor_session(current)
        update_in(state.slot_mungers, &Map.delete(&1, id))

      _ ->
        state
    end
  end

  defp demonitor_session(%{monitor: monitor}), do: Process.demonitor(monitor, [:flush])
  defp demonitor_session(_session), do: :ok

  defp monitor_call_session(%{delivery_module: DirectCallSession}, session_state) do
    if Map.has_key?(session_state, :monitor),
      do: session_state,
      else: Map.put(session_state, :monitor, Process.monitor(session_state.session))
  end

  defp monitor_call_session(_state, session_state), do: session_state

  defp forward_packet(state, kind, voice_session_id, inbound_track_id, packet) do
    source = {kind, voice_session_id, inbound_track_id}

    case Map.get(state.routes, source) do
      routes when is_map(routes) and map_size(routes) > 0 ->
        {:noreply, Enum.reduce(routes, state, &deliver_route(&1, source, packet, &2))}

      _missing_routes ->
        {:noreply, record_drop(state)}
    end
  end

  defp empty_readiness, do: %{receive_codec: nil, source: nil}
  defp empty_media, do: %{audio: empty_readiness(), video: empty_readiness()}

  defp supported_media?(_state, :audio, :opus), do: true
  defp supported_media?(%{delivery_module: DirectCallSession}, :video, :vp8), do: true
  defp supported_media?(_state, _kind, _codec), do: false

  defp update_media(state, id, session, kind, update) when kind in [:audio, :video] do
    if kind == :audio or state.delivery_module == DirectCallSession do
      update_session(state, id, session, fn current ->
        update_in(current, [:media, kind], update)
      end)
    else
      state
    end
  end

  defp update_media(state, _id, _session, _kind, _update), do: state

  defp update_session(state, voice_session_id, session, update) do
    case Map.get(state.sessions, voice_session_id) do
      %{session: ^session} = session_state ->
        state
        |> put_in([:sessions, voice_session_id], update.(session_state))
        |> rebuild_routes()

      _missing_or_replaced ->
        state
    end
  end

  defp rebuild_routes(state) do
    slot_assignments =
      rebuild_slot_assignments(state.sessions, state.slot_assignments, state.audio_output_slots)

    routes = build_routes(state.sessions, slot_assignments) |> build_video_routes(state)

    slot_mungers =
      rebuild_slot_mungers(state.slot_mungers, slot_assignments, state.sessions)
      |> retain_call_timelines(state)

    # A retained receiver keeps its output timeline, but never an obsolete source
    # identity. Removed/replaced receivers must start their own timeline.
    video_timelines =
      Map.filter(state.video_timelines, fn {id, %{session: session}} ->
        match?(%{session: ^session}, Map.get(state.sessions, id))
      end)

    next = %{
      state
      | routes: routes,
        slot_assignments: slot_assignments,
        slot_mungers: slot_mungers,
        video_timelines: video_timelines,
        video_credits:
          Map.filter(state.video_credits, fn {id, %{session: session}} ->
            match?(%{session: ^session}, Map.get(state.sessions, id))
          end)
    }

    publish_video_routes(state, next)

    for {id, delivery} <- state.video_credits,
        not Map.has_key?(next.video_credits, id),
        do: cancel_video_expiry(delivery.timer)

    for {source, routes} <- state.routes,
        {id, %{kind: :video} = route} <- routes,
        get_in(next.routes, [source, id, :ref]) != route.ref,
        do: cancel_video_expiry(route.expiry)

    next
  end

  defp retain_call_timelines(mungers, %{delivery_module: DirectCallSession} = state) do
    state.slot_mungers
    |> Map.take(Map.keys(state.sessions))
    |> Map.merge(mungers)
  end

  defp retain_call_timelines(mungers, _voice_state), do: mungers

  defp rebuild_slot_mungers(current_mungers, slot_assignments, sessions) do
    Enum.reduce(slot_assignments, %{}, fn {destination_id, source_slots}, mungers ->
      destination_mungers = Map.get(current_mungers, destination_id, %{})

      slot_mungers =
        Enum.reduce(source_slots, destination_mungers, fn {source_id, slot}, slot_mungers ->
          source = source_identity(sessions, source_id)

          case Map.get(slot_mungers, slot) do
            %{source: ^source} ->
              slot_mungers

            %{munger: munger} ->
              Map.put(slot_mungers, slot, %{source: source, munger: Munger.update(munger)})

            nil ->
              Map.put(slot_mungers, slot, %{
                source: source,
                munger: Munger.new(:opus, @opus_clock_rate)
              })
          end
        end)

      if Map.has_key?(sessions, destination_id) do
        Map.put(mungers, destination_id, slot_mungers)
      else
        mungers
      end
    end)
  end

  defp source_identity(sessions, source_id) do
    %{session: session, media: %{audio: %{source: %{track_id: track_id}}}} =
      Map.fetch!(sessions, source_id)

    {source_id, session, track_id}
  end

  defp rebuild_slot_assignments(sessions, current_assignments, output_slots) do
    sessions
    |> sessions_in_started_order()
    |> Enum.reduce(%{}, fn {destination_id, destination}, assignments ->
      if receive_ready?(destination) do
        source_ids =
          sessions
          |> sessions_in_started_order()
          |> Enum.filter(fn {source_id, source} ->
            source_id != destination_id and source_ready?(source)
          end)
          |> Enum.map(&elem(&1, 0))

        current_destination_assignments = Map.get(current_assignments, destination_id, %{})

        Map.put(
          assignments,
          destination_id,
          assign_destination_slots(current_destination_assignments, source_ids, output_slots)
        )
      else
        assignments
      end
    end)
  end

  defp assign_destination_slots(current_assignments, source_ids, output_slots) do
    source_id_set = MapSet.new(source_ids)

    preserved_assignments =
      Map.filter(current_assignments, fn {source_id, slot} ->
        MapSet.member?(source_id_set, source_id) and slot in output_slots
      end)

    free_slots = Enum.reject(output_slots, &(&1 in Map.values(preserved_assignments)))

    source_ids
    |> Enum.reject(&Map.has_key?(preserved_assignments, &1))
    |> Enum.zip(free_slots)
    |> Enum.reduce(preserved_assignments, fn {source_id, slot}, assignments ->
      Map.put(assignments, source_id, slot)
    end)
  end

  defp build_routes(sessions, slot_assignments) do
    Enum.reduce(slot_assignments, %{}, fn {destination_id, source_slots}, routes ->
      destination = Map.fetch!(sessions, destination_id)

      Enum.reduce(source_slots, routes, fn {source_id, audio_output_slot}, routes ->
        put_route(
          routes,
          source_id,
          Map.fetch!(sessions, source_id),
          destination_id,
          destination,
          audio_output_slot
        )
      end)
    end)
  end

  defp build_video_routes(routes, %{delivery_module: DirectCallSession} = state) do
    Enum.reduce(state.sessions, routes, fn
      {source_id,
       %{
         session: source_pid,
         media: %{video: %{source: %{track_id: track, codec: :vp8} = source}}
       }},
      routes ->
        key = {:video, source_id, track}

        Enum.reduce(state.sessions, routes, fn
          {destination_id, %{session: destination_pid, media: %{video: %{receive_codec: :vp8}}}},
          routes
          when destination_id != source_id ->
            identity = {source_pid, destination_pid, source.ref}
            previous = get_in(state.routes, [key, destination_id])

            timeline =
              if previous && previous.identity == identity,
                do: Map.take(previous, [:munger, :pending_fields, :admission, :expiry, :status]),
                else:
                  Map.merge(
                    resume_video_timeline(state, destination_id, destination_pid),
                    %{
                      admission: VideoAdmission.new(),
                      expiry: nil,
                      status: %{
                        state: :recovering,
                        interruptions: 0,
                        recoveries: 0,
                        dropped_frames: 0,
                        discarded_packets: 0
                      }
                    }
                  )

            route =
              Map.merge(timeline, %{
                kind: :video,
                camera_version: source.camera_version,
                identity: identity,
                session: destination_pid,
                ref:
                  if(previous && previous.identity == identity,
                    do: previous.ref,
                    else: make_ref()
                  )
              })

            Map.update(
              routes,
              key,
              %{destination_id => route},
              &Map.put(&1, destination_id, route)
            )

          _, routes ->
            routes
        end)

      _, routes ->
        routes
    end)
  end

  defp build_video_routes(routes, _voice_state), do: routes

  defp video_route(routes, destination_id, session, ref) when is_reference(ref) do
    Enum.find_value(routes, fn
      {{:video, _, _} = source, destinations} ->
        case Map.get(destinations, destination_id) do
          %{session: ^session, ref: ^ref} = route -> {source, route}
          _ -> nil
        end

      _ ->
        nil
    end)
  end

  defp video_route(_routes, _id, _session, _ref), do: nil

  defp current_video_route(routes, id, session) do
    Enum.find_value(routes, fn
      {{:video, _, _} = source, destinations} ->
        case Map.get(destinations, id) do
          %{session: ^session} = route -> {source, route}
          _ -> nil
        end

      _ ->
        nil
    end)
  end

  defp video_route_bindings(routes) do
    Enum.reduce(routes, %{}, fn
      {{:video, source_id, _}, destinations}, bindings ->
        Enum.reduce(destinations, bindings, fn
          {id, %{identity: {source, destination, source_ref}, ref: ref} = route}, bindings ->
            bindings
            |> put_video_binding({source_id, source}, :video_source_route, {source_ref, ref})
            |> put_video_binding(
              {id, destination},
              :video_route,
              if(route.camera_version == nil, do: ref, else: {ref, route.camera_version})
            )
        end)

      _, bindings ->
        bindings
    end)
  end

  defp put_video_binding(bindings, identity, command, value) do
    empty = %{video_source_route: nil, video_route: nil}
    Map.update(bindings, identity, Map.put(empty, command, value), &Map.put(&1, command, value))
  end

  defp publish_video_routes(old, %{delivery_module: DirectCallSession} = next) do
    old_bindings = video_route_bindings(old.routes)
    next_bindings = video_route_bindings(next.routes)
    empty = %{video_source_route: nil, video_route: nil}

    for {id, session} = identity <- Enum.uniq(Map.keys(old_bindings) ++ Map.keys(next_bindings)),
        command <- [:video_route, :video_source_route] do
      previous = Map.get(old_bindings, identity, empty)[command]
      current = Map.get(next_bindings, identity, empty)[command]
      if current != previous, do: GenServer.cast(session, {command, self(), id, current})
    end
  end

  defp publish_video_routes(_old, _next), do: :ok

  defp resume_video_timeline(state, destination_id, destination_pid) do
    case Map.get(state.video_timelines, destination_id) do
      %{session: ^destination_pid, munger: munger} ->
        %{munger: Munger.update(munger), pending_fields: [:picture_id, :tl0picidx, :keyidx]}

      _ ->
        %{munger: Munger.new(:vp8, 90_000), pending_fields: []}
    end
  end

  defp source_ready?(%{media: %{audio: %{source: %{codec: :opus}}}, muted: false}), do: true
  defp source_ready?(_session), do: false

  defp receive_ready?(%{media: %{audio: %{receive_codec: :opus}}}), do: true
  defp receive_ready?(_session), do: false

  defp sessions_in_started_order(sessions) do
    Enum.sort_by(sessions, fn {_voice_session_id, session} -> session.started_order end)
  end

  defp put_route(
         routes,
         source_voice_session_id,
         %{media: %{audio: %{source: %{track_id: track_id, codec: :opus}}}},
         destination_voice_session_id,
         %{media: %{audio: %{receive_codec: :opus}}, session: destination_session},
         audio_output_slot
       ) do
    route = %{
      destination_voice_session_id: destination_voice_session_id,
      audio_output_slot: audio_output_slot,
      session: destination_session
    }

    Map.update(
      routes,
      {:audio, source_voice_session_id, track_id},
      %{destination_voice_session_id => route},
      &Map.put(&1, destination_voice_session_id, route)
    )
  end

  defp deliver_route(
         {destination_id, %{kind: :video, session: session} = route},
         source,
         packet,
         state
       ) do
    case Map.get(state.sessions, destination_id) do
      %{session: ^session} ->
        deliver_video_packet(state, source, destination_id, route, packet)

      _stale_destination ->
        record_drop(state)
    end
  end

  defp deliver_route(
         {_destination_id,
          %{
            destination_voice_session_id: destination_voice_session_id,
            audio_output_slot: audio_output_slot,
            session: session
          }},
         _source,
         packet,
         state
       ) do
    case Map.get(state.sessions, destination_voice_session_id) do
      %{session: ^session} ->
        {packet, state} =
          munge_packet(state, destination_voice_session_id, audio_output_slot, packet)

        :ok =
          deliver_audio(
            state.delivery_module,
            session,
            destination_voice_session_id,
            audio_output_slot,
            packet
          )

        record_forward(state)

      _stale_destination ->
        record_drop(state)
    end
  end

  defp deliver_video_packet(state, source, id, %{status: %{state: :interrupted}} = route, packet) do
    # Do not assemble, munge, or repeatedly request PLI while transport is busy.
    admission =
      case parse_video_packet(packet) do
        {:ok, _} -> VideoAdmission.discard(route.admission, packet.timestamp)
        _ -> route.admission
      end

    route = %{route | admission: admission}

    state
    |> put_in([:routes, source, id], update_in(route.status.discarded_packets, &(&1 + 1)))
    |> record_drop()
  end

  defp deliver_video_packet(state, source, destination_id, route, packet) do
    case parse_video_packet(packet) do
      {:ok, descriptor} ->
        {admission, packets, request?} =
          VideoAdmission.admit(
            route.admission,
            packet,
            descriptor,
            System.monotonic_time(:millisecond)
          )

        request_video_recovery(source, route, request?)
        route = update_video_expiry(route, admission)
        state = put_in(state, [:routes, source, destination_id], route)

        queue_video_frame(state, source, destination_id, route, packets)

      {:error, :invalid_packet} ->
        {admission, [], request?} = VideoAdmission.expire(route.admission)
        request_video_recovery(source, route, request?)

        state
        |> put_in([:routes, source, destination_id], update_video_expiry(route, admission))
        |> record_drop()
    end
  end

  defp queue_video_frame(state, _source, _id, _route, []), do: state

  defp queue_video_frame(state, source, id, route, packets) do
    if Map.has_key?(state.video_credits, id) do
      drop_video_frame(state, source, id, route)
    else
      ref = state.video_drain || make_ref()
      if state.video_drain == nil, do: send(self(), {:drain_video, ref})

      delivery = %{
        session: route.session,
        route_ref: route.ref,
        credit: make_ref(),
        pending: {source, packets, System.monotonic_time(:millisecond) + 150},
        timer: nil
      }

      %{state | video_drain: ref, video_credits: Map.put(state.video_credits, id, delivery)}
    end
  end

  defp drop_video_frame(state, source, id, route) do
    {admission, [], request?} = VideoAdmission.expire(route.admission)
    request_video_recovery(source, route, request?)

    state
    |> put_in([:routes, source, id], update_video_expiry(route, admission))
    |> update_in([:routes, source, id, :status, :dropped_frames], &(&1 + 1))
    |> record_drop()
  end

  defp interrupt_video(state, _source, _id, %{status: %{state: :interrupted}}), do: state

  defp interrupt_video(state, source, id, route) do
    {admission, [], _} = VideoAdmission.expire(route.admission)
    route = update_video_expiry(route, admission)
    state = put_in(state, [:routes, source, id], route)
    set_video_status(state, source, id, route, :interrupted)
  end

  defp set_video_status(state, source, id, route, status) do
    if route.status.state == status do
      state
    else
      GenServer.cast(route.session, {:video_route_status, self(), id, route.ref, status})

      counts =
        case status do
          :interrupted ->
            Map.update!(route.status, :interruptions, &(&1 + 1))

          :active ->
            Map.update!(route.status, :recoveries, fn count ->
              if route.status.interruptions > count, do: count + 1, else: count
            end)

          :recovering ->
            route.status
        end

      observations = fn ->
        Map.put(
          counts,
          :mailbox_len,
          DiscordClone.Media.Diagnostics.queue_snapshot(self()).mailbox_len
        )
      end

      history =
        DiscordClone.Media.Diagnostics.observe_video(
          state.video_diagnostics,
          :route,
          status,
          observations
        )

      state
      |> Map.put(:video_diagnostics, history)
      |> put_in([:routes, source, id, :status], %{counts | state: status})
    end
  end

  defp drain_video(state, source, id, route, delivery, packets, deadline) do
    {packets, route} =
      Enum.map_reduce(packets, route, fn packet, route ->
        {:ok, descriptor} = parse_video_packet(packet)
        {packet, timeline} = munge_video(route, packet, descriptor)
        {packet, Map.merge(route, timeline)}
      end)

    DirectCallSession.deliver_video(
      route.session,
      id,
      route.ref,
      delivery.credit,
      packets,
      deadline
    )

    timer =
      Process.send_after(
        self(),
        {:video_delivery_due, id, route.session, delivery.credit},
        max(deadline - System.monotonic_time(:millisecond), 0)
      )

    state
    |> put_in([:routes, source, id], route)
    |> put_in([:video_credits, id], %{delivery | pending: nil, timer: timer})
    |> put_in([:video_timelines, id], Map.take(route, [:session, :munger, :pending_fields]))
    |> Map.update!(:forwarded_packet_count, &(&1 + length(packets)))
  end

  defp request_video_recovery({:video, id, track}, route, true) do
    {session, _, source_ref} = route.identity
    GenServer.cast(session, {:request_keyframe, self(), id, track, source_ref, route.ref})
  end

  defp request_video_recovery(_source, _route, false), do: :ok

  defp update_video_expiry(route, admission) do
    expiry =
      cond do
        admission.frame == nil ->
          cancel_video_expiry(route.expiry)
          nil

        route.expiry != nil and route.admission.timestamp == admission.timestamp ->
          route.expiry

        true ->
          cancel_video_expiry(route.expiry)

          Process.send_after(
            self(),
            {:expire_video, route.ref, admission.timestamp},
            max(admission.frame.deadline - System.monotonic_time(:millisecond), 0)
          )
      end

    %{route | admission: admission, expiry: expiry}
  end

  defp cancel_video_expiry(nil), do: :ok
  defp cancel_video_expiry(timer), do: Process.cancel_timer(timer)

  # RFC 7741 section 4.2 requires T whenever L is present. The pinned
  # parser accepts L without T, so reject it before initializing/updating any
  # destination counters. All optional octets and nonempty codec payload are
  # validated by that parser; unsupported reserved shapes return an error.
  # No rescue wraps delivery or trusted munger state: unexpected runtime faults
  # must retain the existing terminal policy.
  defp parse_video_packet(%ExRTP.Packet{
         payload: payload,
         sequence_number: sequence,
         timestamp: timestamp,
         marker: marker
       })
       when is_binary(payload) and is_integer(sequence) and sequence in 0..65_535 and
              is_integer(timestamp) and timestamp in 0..4_294_967_295 and is_boolean(marker) do
    case payload do
      <<1::1, _::7, _i::1, 1::1, 0::1, _::5, _::binary>> ->
        {:error, :invalid_packet}

      _ ->
        ExWebRTC.RTP.VP8.Payload.parse(payload)
    end
  end

  defp parse_video_packet(_packet), do: {:error, :invalid_packet}

  # The pinned VP8 munger assumes previously used optional fields are present
  # on a stream switch. Valid fresh capture may omit them. Retain each output
  # counter while absent, and only ask the pinned boundary to offset present fields.
  defp munge_video(%{munger: munger, pending_fields: pending}, packet, descriptor) do
    fields = [
      {:picture_id, :pic_id_used, :last_pic_id, :pic_id_offset},
      {:tl0picidx, :tl0picidx_used, :last_tl0picidx, :tl0picidx_offset},
      {:keyidx, :keyidx_used, :last_keyidx, :keyidx_offset}
    ]

    previous = munger.vp8_munger

    prepared =
      Enum.reduce(fields, previous, fn {field, used, last, offset}, vp8 ->
        value = Map.fetch!(descriptor, field)
        used? = Map.fetch!(previous, used)
        vp8 = Map.put(vp8, used, used? and value != nil)

        if used? and value != nil and field in pending do
          Map.put(vp8, offset, value - Map.fetch!(previous, last) - 1)
        else
          vp8
        end
      end)

    {packet, munger} = Munger.munge(%{munger | vp8_munger: prepared}, packet)

    vp8 =
      Enum.reduce(fields, munger.vp8_munger, fn {field, used, last, _offset}, vp8 ->
        if Map.fetch!(descriptor, field) == nil do
          vp8
          |> Map.put(used, Map.fetch!(previous, used))
          |> Map.put(last, Map.fetch!(previous, last))
        else
          Map.put(vp8, used, true)
        end
      end)

    pending = Enum.filter(pending, &(Map.fetch!(descriptor, &1) == nil))
    {packet, %{munger: %{munger | vp8_munger: vp8}, pending_fields: pending}}
  end

  defp deliver_audio(DirectCallSession, session, id, slot, packet),
    do: DirectCallSession.deliver_rtp(session, id, :audio, slot, packet)

  defp deliver_audio(Session, session, id, slot, packet),
    do: Session.deliver_rtp(session, id, slot, packet)

  defp munge_packet(state, destination_voice_session_id, audio_output_slot, packet) do
    destination_mungers = Map.fetch!(state.slot_mungers, destination_voice_session_id)
    %{munger: munger} = slot_munger = Map.fetch!(destination_mungers, audio_output_slot)
    {packet, munger} = Munger.munge(munger, packet)

    slot_mungers =
      Map.put(destination_mungers, audio_output_slot, %{slot_munger | munger: munger})

    {packet, put_in(state, [:slot_mungers, destination_voice_session_id], slot_mungers)}
  end

  defp record_forward(state) do
    state = Map.update!(state, :forwarded_packet_count, &(&1 + 1))
    emit_route(state, :rtp_forwarded)
    state
  end

  defp record_drop(state) do
    state = Map.update!(state, :dropped_packet_count, &(&1 + 1))
    emit_route(state, :rtp_dropped)
    state
  end

  defp emit_route(%{delivery_module: Session} = state, event),
    do: Diagnostics.emit_route(event, route_counts(state))

  defp emit_route(_call_state, _event), do: :ok

  defp route_counts(state) do
    Map.take(state, [:forwarded_packet_count, :dropped_packet_count])
  end

  defp room_server(voice_channel_id) do
    case Registry.lookup(RoomRegistry, {:room, voice_channel_id}) do
      [{pid, _value}] when is_pid(pid) -> pid
      _missing_or_stopped -> nil
    end
  end
end
