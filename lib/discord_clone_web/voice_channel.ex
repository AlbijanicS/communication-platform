defmodule DiscordCloneWeb.VoiceChannel do
  use DiscordCloneWeb, :channel

  @test_environment Code.ensure_loaded?(Mix) and Mix.env() == :test

  alias DiscordClone.{Voice, Workspaces}
  alias DiscordClone.Voice.Diagnostics
  alias DiscordCloneWeb.Signaling
  alias DiscordCloneWeb.VoiceSignaling.RealMessage

  @impl true
  def join("voice:" <> voice_channel_id, _params, socket) do
    case Workspaces.authorize_voice_channel_for_signaling(
           socket.assigns.current_scope,
           voice_channel_id
         ) do
      {:ok, _voice_channel} ->
        join_voice_channel(voice_channel_id, socket)

      {:error, :not_found} ->
        {:error, %{reason: "not_found"}}
    end
  end

  def join(_topic, _params, _socket), do: {:error, %{reason: "not_found"}}

  @impl true
  def handle_in("offer", params, socket) do
    with :ok <- validate_signaling_session_id(params, socket),
         {:ok, offer} <- RealMessage.offer(params),
         {:ok, answer} <-
           Voice.accept_offer(
             socket.assigns.current_scope,
             socket.assigns.voice_channel_id,
             socket.assigns.voice_session_id,
             offer.negotiation_id,
             offer.description
           ) do
      Diagnostics.emit("offer", :accepted, decoded_request_byte_count: offer.byte_count)

      {:reply,
       {:ok,
        %{
          signaling_session_id: socket.assigns.signaling_session_id,
          negotiation_id: offer.negotiation_id,
          description: answer
        }}, assign(socket, :negotiation_id, offer.negotiation_id)}
    else
      :invalid_session ->
        reject("offer", "invalid_request", decoded_request_byte_count(params), socket)

      {:error, :negotiation_failed} ->
        reject_terminal_offer("negotiation_failed", decoded_request_byte_count(params), socket)

      {:error, :incompatible_audio_output_slots} ->
        reject_terminal_offer(
          "incompatible_audio_output_slots",
          decoded_request_byte_count(params),
          socket
        )

      {:error, error_code} ->
        reject("offer", error_code, decoded_request_byte_count(params), socket)
    end
  end

  def handle_in("ice_candidate", params, socket) do
    case {validate_signaling_session_id(params, socket), RealMessage.ice_candidate(params)} do
      {:ok, {:end_of_candidates, marker}} ->
        case Voice.end_of_candidates(
               socket.assigns.current_scope,
               socket.assigns.voice_channel_id,
               socket.assigns.voice_session_id,
               marker.negotiation_id
             ) do
          {:error, :end_of_candidates_unsupported} ->
            reject("ice_candidate", "end_of_candidates_unsupported", marker.byte_count, socket)

          {:error, error_code} ->
            reject("ice_candidate", error_code, marker.byte_count, socket)
        end

      {:ok, {:ok, ice}} ->
        case Voice.add_ice_candidate(
               socket.assigns.current_scope,
               socket.assigns.voice_channel_id,
               socket.assigns.voice_session_id,
               ice.negotiation_id,
               ice
             ) do
          {:ok, reply} ->
            Diagnostics.emit("ice_candidate", :accepted,
              decoded_request_byte_count: ice.byte_count
            )

            {:reply, {:ok, reply}, socket}

          {:error, error_code} ->
            reject("ice_candidate", error_code, ice.byte_count, socket)
        end

      {:invalid_session, _message} ->
        reject("ice_candidate", "invalid_request", decoded_request_byte_count(params), socket)

      {:ok, {:error, error_code}} ->
        reject("ice_candidate", error_code, decoded_request_byte_count(params), socket)
    end
  end

  def handle_in("ice_route", params, socket) do
    case browser_ice_route(params, socket) do
      {:ok, route_category, protocol, duration_ms} ->
        Diagnostics.emit_ice_route(
          socket.assigns.ice_mode,
          :browser,
          route_category,
          protocol,
          :accepted,
          duration_ms
        )

        {:reply, :ok, socket}

      :error ->
        Diagnostics.emit_ice_route(
          socket.assigns.ice_mode,
          :browser,
          :unknown,
          :unknown,
          :rejected,
          0,
          error_code: :invalid_request
        )

        {:reply, {:error, %{reason: "invalid_request"}}, socket}
    end
  end

  def handle_in("renew", params, socket) do
    byte_count = decoded_request_byte_count(params)

    with :ok <- validate_signaling_session_id(params, socket),
         :ok <-
           Voice.renew_session(
             socket.assigns.current_scope,
             socket.assigns.voice_channel_id,
             socket.assigns.voice_session_id,
             socket.assigns.signaling_session_id
           ) do
      Diagnostics.emit("renew", :accepted, decoded_request_byte_count: byte_count)

      {:reply, {:ok, %{signaling_session_id: socket.assigns.signaling_session_id}}, socket}
    else
      :invalid_session -> reject("renew", "invalid_request", byte_count, socket)
      {:error, _reason} -> reject("renew", "invalid_session", byte_count, socket)
    end
  end

  def handle_in(
        "local_voice_state",
        %{"muted" => muted, "deafened" => deafened},
        socket
      )
      when is_boolean(muted) and is_boolean(deafened) do
    case Voice.update_local_voice_state(
           socket.assigns.current_scope,
           socket.assigns.voice_channel_id,
           socket.assigns.voice_session_id,
           %{muted: muted, deafened: deafened}
         ) do
      :ok -> {:reply, :ok, socket}
      {:error, _reason} -> {:reply, {:error, %{reason: "invalid_session"}}, socket}
    end
  end

  def handle_in(_event, _params, socket),
    do: {:reply, {:error, %{reason: "unsupported_event"}}, socket}

  @impl true
  def handle_info({:voice_session_event, voice_session_id, event}, socket) do
    if voice_session_id == socket.assigns[:voice_session_id] do
      handle_voice_session_event(event, socket)
    else
      {:noreply, socket}
    end
  end

  def handle_info(
        {:voice_session_ended, voice_session_id, signaling_session_id},
        %{
          assigns: %{
            voice_session_id: voice_session_id,
            signaling_session_id: signaling_session_id
          }
        } =
          socket
      ) do
    push(socket, "voice_session_ended", %{signaling_session_id: signaling_session_id})
    {:noreply, socket}
  end

  def handle_info(
        {:voice_channel_roster_changed, %{voice_channel_id: voice_channel_id, members: members}},
        %{assigns: %{voice_channel_id: voice_channel_id}} = socket
      ) do
    current_member_ids = socket.assigns.voice_roster_member_ids || MapSet.new()
    member_ids = MapSet.new(members, & &1.user_id)
    current_user_id = socket.assigns.current_scope.user.id

    cue =
      cond do
        MapSet.size(MapSet.delete(member_ids, current_user_id)) >
            MapSet.size(MapSet.delete(current_member_ids, current_user_id)) ->
          "join"

        MapSet.size(MapSet.delete(member_ids, current_user_id)) <
            MapSet.size(MapSet.delete(current_member_ids, current_user_id)) ->
          "leave"

        true ->
          nil
      end

    if cue, do: push(socket, "voice_roster_cue", %{channel_id: voice_channel_id, cue: cue})
    {:noreply, assign(socket, :voice_roster_member_ids, member_ids)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, socket) do
    leave_voice_session(socket)
    :ok
  end

  defp handle_voice_session_event(
         {:ice_candidate, negotiation_id, candidate},
         %{assigns: %{negotiation_id: negotiation_id}} = socket
       ) do
    push(socket, "ice_candidate", %{
      signaling_session_id: socket.assigns.signaling_session_id,
      negotiation_id: negotiation_id,
      candidate: candidate
    })

    {:noreply, socket}
  end

  defp handle_voice_session_event(
         {:end_of_candidates, negotiation_id},
         %{assigns: %{negotiation_id: negotiation_id}} = socket
       ) do
    push(socket, "ice_candidate", %{
      signaling_session_id: socket.assigns.signaling_session_id,
      negotiation_id: negotiation_id,
      end_of_candidates: true
    })

    Diagnostics.emit("ice_candidate", :accepted, decoded_request_byte_count: 0)
    {:noreply, socket}
  end

  defp handle_voice_session_event({:ice_candidate, _negotiation_id, _candidate}, socket),
    do: {:noreply, socket}

  defp handle_voice_session_event({:end_of_candidates, _negotiation_id}, socket),
    do: {:noreply, socket}

  defp handle_voice_session_event(
         {:connection_state_change, connection_state, negotiation_id},
         %{assigns: %{negotiation_id: negotiation_id}} = socket
       )
       when connection_state in [:failed, :closed] do
    {:stop, :normal, socket}
  end

  defp handle_voice_session_event(
         {:connection_state_change, _connection_state, _negotiation_id},
         socket
       ),
       do: {:noreply, socket}

  defp leave_voice_session(socket) do
    case {socket.assigns[:voice_channel_id], socket.assigns[:voice_session_id]} do
      {voice_channel_id, voice_session_id}
      when is_binary(voice_channel_id) and is_binary(voice_session_id) ->
        Voice.leave(voice_channel_id, voice_session_id)

      _missing_join ->
        :ok
    end
  end

  defp reject(operation, error_code, byte_count, socket) do
    error_code = normalize_error_code(error_code)

    Diagnostics.emit(operation, :rejected,
      error_code: error_code,
      decoded_request_byte_count: byte_count
    )

    {:reply, {:error, %{reason: error_code}}, socket}
  end

  defp reject_terminal_offer(error_code, byte_count, socket) do
    Diagnostics.emit("offer", :rejected,
      error_code: error_code,
      decoded_request_byte_count: byte_count
    )

    {:stop, :normal, {:error, %{reason: error_code}}, socket}
  end

  defp decoded_request_byte_count(params), do: Signaling.decoded_request_byte_count(params)

  defp validate_signaling_session_id(%{"signaling_session_id" => signaling_session_id}, socket)
       when is_binary(signaling_session_id) do
    if signaling_session_id == socket.assigns.signaling_session_id,
      do: :ok,
      else: :invalid_session
  end

  defp validate_signaling_session_id(_params, _socket), do: :invalid_session

  defp new_signaling_session_id do
    32
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp join_voice_channel(voice_channel_id, socket) do
    signaling_session_id = new_signaling_session_id()

    case Voice.join_with_ice_configuration(
           socket.assigns.current_scope,
           voice_channel_id,
           signaling_session_id,
           self()
         ) do
      {:ok, join_result, browser_ice_projection} ->
        browser_ice_projection =
          maybe_invalidate_browser_projection(browser_ice_projection, socket)

        case join_payload(join_result, signaling_session_id, browser_ice_projection) do
          {:ok, voice_session_id, payload} ->
            finalize_voice_admission(
              voice_channel_id,
              voice_session_id,
              payload,
              signaling_session_id,
              socket
            )

          :error ->
            rollback_voice_join(voice_channel_id, join_result)
            {:error, %{reason: "unavailable"}}
        end

      {:error, reason} ->
        normalize_join_error(reason)
    end
  end

  defp join_payload(
         %{voice_session_id: voice_session_id, occupancy: occupancy, capacity: capacity},
         signaling_session_id,
         browser_ice_projection
       )
       when is_binary(voice_session_id) and is_binary(signaling_session_id) and
              is_integer(occupancy) and occupancy >= 0 and is_integer(capacity) and capacity > 0 and
              occupancy <= capacity and is_map(browser_ice_projection) do
    {:ok, voice_session_id,
     %{
       signaling_session_id: signaling_session_id,
       occupancy: occupancy,
       capacity: capacity,
       ice_config: browser_ice_projection
     }}
  end

  defp join_payload(_join_result, _signaling_session_id, _browser_ice_projection), do: :error

  defp rollback_voice_join(voice_channel_id, %{voice_session_id: voice_session_id})
       when is_binary(voice_session_id) do
    Voice.leave(voice_channel_id, voice_session_id)
  end

  defp rollback_voice_join(_voice_channel_id, _join_result), do: :ok

  defp finalize_voice_admission(
         voice_channel_id,
         voice_session_id,
         payload,
         signaling_session_id,
         socket
       ) do
    current_scope = socket.assigns.current_scope

    case Workspaces.authorize_voice_channel_for_signaling(current_scope, voice_channel_id) do
      {:ok, voice_channel} ->
        :ok =
          Voice.set_workspace_muted(
            voice_channel_id,
            current_scope.user.id,
            Workspaces.workspace_mute_active?(voice_channel.workspace_id, current_scope.user.id)
          )

        with {:ok, %{members: members}} <- admission_roster(voice_channel_id, socket),
             :ok <- subscribe_to_admission_roster(voice_channel_id, socket) do
          {:ok, payload,
           socket
           |> assign(:voice_channel_id, voice_channel_id)
           |> assign(:signaling_session_id, signaling_session_id)
           |> assign(:voice_session_id, voice_session_id)
           |> assign(:ice_mode, ice_mode(payload.ice_config.ice_mode))
           |> assign(:negotiation_id, nil)
           |> assign(:voice_roster_member_ids, MapSet.new(members, & &1.user_id))}
        else
          _unavailable_roster ->
            :ok = Voice.leave(voice_channel_id, voice_session_id)
            {:error, %{reason: "unavailable"}}
        end

      {:error, :not_found} ->
        :ok = Voice.leave(voice_channel_id, voice_session_id)
        {:error, %{reason: "not_found"}}
    end
  end

  defp normalize_join_error(%{reason: :room_full, occupancy: occupancy, capacity: capacity})
       when is_integer(occupancy) and occupancy >= 0 and is_integer(capacity) and capacity > 0 and
              occupancy <= capacity do
    {:error, %{reason: "room_full", occupancy: occupancy, capacity: capacity}}
  end

  defp normalize_join_error(:not_found), do: {:error, %{reason: "not_found"}}
  defp normalize_join_error(:recovering), do: {:error, %{reason: "recovering"}}

  defp normalize_join_error(:recovery_timeout),
    do: {:error, %{reason: "recovery_timeout"}}

  defp normalize_join_error(_reason), do: {:error, %{reason: "unavailable"}}

  defp browser_ice_route(
         %{
           "signaling_session_id" => signaling_session_id,
           "route_category" => route_category,
           "protocol" => protocol,
           "duration_ms" => duration_ms
         } = params,
         socket
       )
       when map_size(params) == 4 and is_binary(signaling_session_id) and
              route_category in ["host_direct", "reflexive_direct", "turn_relay", "unknown"] and
              protocol in ["udp", "tcp", "tls", "unknown"] and is_integer(duration_ms) and
              duration_ms >= 0 and duration_ms <= 60_000 do
    if signaling_session_id == socket.assigns.signaling_session_id do
      {:ok, route_category(route_category), protocol(protocol), duration_ms}
    else
      :error
    end
  end

  defp browser_ice_route(_params, _socket), do: :error

  defp ice_mode("disabled"), do: :disabled
  defp ice_mode("standard"), do: :standard
  defp ice_mode("turn_only"), do: :turn_only

  defp route_category("host_direct"), do: :host_direct
  defp route_category("reflexive_direct"), do: :reflexive_direct
  defp route_category("turn_relay"), do: :turn_relay
  defp route_category("unknown"), do: :unknown

  defp protocol("udp"), do: :udp
  defp protocol("tcp"), do: :tcp
  defp protocol("tls"), do: :tls
  defp protocol("unknown"), do: :unknown

  defp maybe_invalidate_browser_projection(browser_ice_projection, socket) do
    if admission_failure_stage?(socket, :join_payload),
      do: :invalid,
      else: browser_ice_projection
  end

  defp admission_roster(voice_channel_id, socket) do
    if admission_failure_stage?(socket, :roster_lookup),
      do: {:error, :unavailable},
      else: Voice.voice_channel_roster(voice_channel_id)
  end

  defp subscribe_to_admission_roster(voice_channel_id, socket) do
    if admission_failure_stage?(socket, :roster_subscription),
      do: {:error, :unavailable},
      else: Voice.subscribe_to_voice_channel_roster(voice_channel_id)
  end

  defp admission_failure_stage?(socket, stage) do
    @test_environment and socket.assigns[:voice_admission_failure] == stage
  end

  defp normalize_error_code(error_code) when is_binary(error_code), do: error_code
  defp normalize_error_code(error_code) when is_atom(error_code), do: Atom.to_string(error_code)
  defp normalize_error_code(_error_code), do: "unavailable"
end
