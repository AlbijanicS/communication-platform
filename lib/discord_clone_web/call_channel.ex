defmodule DiscordCloneWeb.CallChannel do
  use Phoenix.Channel, log_join: false, log_handle_in: false

  alias DiscordClone.Calls
  alias DiscordCloneWeb.CallSignaling
  alias DiscordCloneWeb.CallSignaling.AcceptCall
  alias DiscordCloneWeb.CallSignaling.CallCommand
  alias DiscordCloneWeb.CallSignaling.Diagnostics
  alias DiscordCloneWeb.CallSignaling.ReservedEvent

  @lifecycle_events CallSignaling.lifecycle_events()
  @terminal_events CallSignaling.terminal_events()

  @impl true
  def join(topic, params, socket) when map_size(params) == 0 do
    started_at = System.monotonic_time(:millisecond)

    case CallSignaling.parse_call_topic(topic) do
      {:ok, call_id} ->
        join_authorized_call(call_id, params, started_at, socket)

      :error ->
        CallSignaling.emit_join(started_at, params, :rejected, :invalid_request)
        {:error, %{reason: "invalid_request"}}
    end
  end

  def join(_topic, params, _socket) do
    CallSignaling.emit_join(
      System.monotonic_time(:millisecond),
      params,
      :rejected,
      :invalid_request
    )

    {:error, %{reason: "invalid_request"}}
  end

  @impl true
  def handle_in("decline_call", payload, socket) do
    handle_call_command("decline_call", payload, socket, &Calls.decline_call/2)
  end

  def handle_in("cancel_call", payload, socket) do
    handle_call_command("cancel_call", payload, socket, fn _scope, call_id ->
      Calls.cancel_call(authenticated_media_scope(socket), call_id, socket.assigns.connection_id)
    end)
  end

  def handle_in("accept_call", payload, socket) do
    handle_accept_call(payload, socket)
  end

  def handle_in("leave_call", payload, socket) do
    handle_call_command("leave_call", payload, socket, fn _scope, call_id ->
      Calls.leave_call(authenticated_media_scope(socket), call_id, socket.assigns.connection_id)
    end)
  end

  def handle_in("media_credentials", payload, socket) do
    started_at = System.monotonic_time(:millisecond)

    case CallCommand.validate(
           payload,
           socket.assigns.signaling_session_id,
           socket.assigns.call_id
         ) do
      {:ok, command} ->
        result =
          Calls.media_credentials(
            authenticated_media_scope(socket),
            command.call_id,
            Map.get(socket.assigns, :connection_id),
            socket.assigns.signaling_session_id
          )

        case {result, authenticated_media_scope(socket)} do
          {{:ok, credentials}, %DiscordClone.Accounts.Scope{}} ->
            CallSignaling.emit_operation(
              "media_credentials",
              :accepted,
              started_at,
              command.byte_count
            )

            reply =
              Map.put(credentials, :signaling_session_id, socket.assigns.signaling_session_id)

            {:reply, {:ok, reply},
             assign(socket, :negotiation_id, Map.get(credentials, :negotiation_id))}

          _not_admitted ->
            CallSignaling.emit_operation(
              "media_credentials",
              :rejected,
              started_at,
              command.byte_count,
              :not_admitted
            )

            {:reply, {:error, %{reason: "not_admitted"}}, socket}
        end

      {:error, :invalid_request, byte_count} ->
        CallSignaling.emit_operation(
          "media_credentials",
          :rejected,
          started_at,
          byte_count,
          :invalid_request
        )

        {:reply, {:error, %{reason: "invalid_request"}}, socket}
    end
  end

  def handle_in("offer", payload, socket) do
    handle_media_signal("offer", :offer, payload, socket)
  end

  def handle_in("ice_candidate", payload, socket) do
    handle_media_signal("ice_candidate", :candidate, payload, socket)
  end

  def handle_in("ice_route", payload, socket) do
    reject_reserved_event("ice_route", payload, socket, :not_admitted)
  end

  def handle_in("renew", payload, socket) do
    handle_media_signal("renew", :renew, payload, socket)
  end

  def handle_in("local_media_state", payload, socket) do
    handle_media_signal("local_media_state", :local_media_state, payload, socket)
  end

  def handle_in(_event, payload, socket), do: CallSignaling.reject_unsupported(payload, socket)

  @impl true
  def handle_info({event, projection}, socket)
      when is_map_key(@lifecycle_events, event) and is_map(projection) do
    {:noreply, deliver_lifecycle(socket, event, projection)}
  end

  def handle_info({event, projection}, socket)
      when is_map_key(@terminal_events, event) and is_map(projection) do
    case deliver_terminal(socket, event, projection) do
      {:stop, reason, updated_socket} -> {:stop, reason, updated_socket}
      updated_socket -> {:noreply, updated_socket}
    end
  end

  def handle_info({:call_media_event, session_id, signaling_id, negotiation_id, event}, socket) do
    if signaling_id == socket.assigns.signaling_session_id and
         negotiation_id == socket.assigns[:negotiation_id] and
         Calls.media_event_authorized?(
           authenticated_media_scope(socket),
           socket.assigns.call_id,
           socket.assigns.connection_id,
           session_id
         ) do
      push(
        socket,
        cond do
          Map.has_key?(event, :video_presentation) -> "video_presentation"
          Map.has_key?(event, :video_route_status) -> "video_route_status"
          true -> "ice_candidate"
        end,
        Map.merge(event, %{
          call_id: socket.assigns.call_id,
          call_session_id: session_id,
          signaling_session_id: signaling_id,
          negotiation_id: negotiation_id
        })
      )
    end

    {:noreply, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, socket) do
    CallSignaling.unregister_connection(socket)
    CallSignaling.terminate_joined(socket)
  end

  defp join_authorized_call(call_id, params, started_at, socket) do
    scope = socket.assigns.current_scope

    with :ok <- Calls.subscribe(scope),
         {:ok, projection} <- Calls.get_call(scope, call_id) do
      signaling_session_id = Ecto.UUID.generate()
      CallSignaling.register_connection(socket, call_id, projection)
      CallSignaling.emit_join(started_at, params, :accepted)

      projection = CallSignaling.with_ownership(projection, socket)

      {:ok, CallSignaling.envelope(signaling_session_id, projection, scope),
       socket
       |> assign(:call_id, call_id)
       |> assign(:signaling_session_id, signaling_session_id)
       |> assign(:last_call, projection)}
    else
      {:error, :not_found} ->
        CallSignaling.emit_join(started_at, params, :rejected, :not_found)
        {:error, %{reason: "not_found"}}

      {:error, :temporarily_unavailable} ->
        CallSignaling.emit_join(started_at, params, :failed, :temporarily_unavailable)
        {:error, %{reason: "temporarily_unavailable"}}

      {:error, _reason} ->
        CallSignaling.emit_join(started_at, params, :rejected, :invalid_request)
        {:error, %{reason: "invalid_request"}}
    end
  end

  # Recheck revocation around slow media commands and before credential/event delivery.
  # The topic is server-derived at authenticated socket connection, never payload data.
  defp authenticated_media_scope(socket) do
    with "users_sessions:" <> encoded <- socket.assigns.user_session_topic,
         {:ok, token} <- Base.url_decode64(encoded),
         {%{id: user_id}, _inserted_at} <- DiscordClone.Accounts.get_user_by_session_token(token),
         true <- user_id == socket.assigns.current_scope.user.id do
      socket.assigns.current_scope
    else
      _ ->
        CallSignaling.unregister_connection(socket)
        nil
    end
  end

  defp handle_media_signal(operation, type, payload, socket) do
    started_at = System.monotonic_time(:millisecond)

    case ReservedEvent.validate(
           operation,
           payload,
           socket.assigns.signaling_session_id,
           socket.assigns.call_id
         ) do
      {:ok, %{byte_count: bytes}} ->
        result =
          Calls.signal_media(
            authenticated_media_scope(socket),
            socket.assigns.call_id,
            socket.assigns.connection_id,
            type,
            payload
          )

        result = if authenticated_media_scope(socket), do: result, else: {:error, :not_admitted}

        case result do
          {:ok, result} ->
            CallSignaling.emit_operation(operation, :accepted, started_at, bytes)

            reply = %{
              call_id: socket.assigns.call_id,
              call_session_id: payload["call_session_id"],
              signaling_session_id: socket.assigns.signaling_session_id,
              negotiation_id: payload["negotiation_id"]
            }

            reply =
              case type do
                :offer -> Map.put(reply, :description, result)
                :renew -> reply |> Map.delete(:negotiation_id) |> Map.merge(result)
                :local_media_state -> Map.merge(reply, result)
                :candidate -> reply
              end

            socket =
              if type == :offer,
                do: assign(socket, :negotiation_id, payload["negotiation_id"]),
                else: socket

            {:reply, {:ok, reply}, socket}

          {:error, reason} ->
            CallSignaling.emit_operation(operation, :rejected, started_at, bytes, reason)
            {:reply, {:error, %{reason: to_string(reason)}}, socket}
        end

      {:error, :invalid_request, bytes} ->
        CallSignaling.emit_operation(operation, :rejected, started_at, bytes, :invalid_request)
        {:reply, {:error, %{reason: "invalid_request"}}, socket}
    end
  end

  defp reject_reserved_event(operation, payload, socket, error_code) do
    started_at = System.monotonic_time(:millisecond)

    case ReservedEvent.validate(
           operation,
           payload,
           socket.assigns.signaling_session_id,
           socket.assigns.call_id
         ) do
      {:ok, %{byte_count: byte_count}} ->
        CallSignaling.emit_operation(operation, :rejected, started_at, byte_count, error_code)
        {:reply, {:error, %{reason: Atom.to_string(error_code)}}, socket}

      {:error, :invalid_request, byte_count} ->
        CallSignaling.emit_operation(
          operation,
          :rejected,
          started_at,
          byte_count,
          :invalid_request
        )

        {:reply, {:error, %{reason: "invalid_request"}}, socket}
    end
  end

  defp handle_accept_call(payload, socket) do
    started_at = System.monotonic_time(:millisecond)

    case AcceptCall.validate(
           payload,
           socket.assigns.signaling_session_id,
           socket.assigns.call_id
         ) do
      {:ok, command} ->
        case Calls.accept_call(
               socket.assigns.current_scope,
               command.call_id,
               command.answer_mode,
               Map.get(socket.assigns, :connection_id)
             ) do
          {:ok, projection} ->
            CallSignaling.emit_operation(
              "accept_call",
              :accepted,
              started_at,
              command.byte_count
            )

            projection = CallSignaling.with_ownership(projection, socket)

            {:reply, {:ok, CallSignaling.envelope_from_socket(socket, projection)},
             assign(socket, :last_call, projection)}

          {:error, reason} ->
            {outcome, error_code} = command_failure(reason)

            CallSignaling.emit_operation(
              "accept_call",
              outcome,
              started_at,
              command.byte_count,
              error_code
            )

            {:reply, {:error, %{reason: Atom.to_string(error_code)}}, socket}
        end

      {:error, :invalid_request, byte_count} ->
        CallSignaling.emit_operation(
          "accept_call",
          :rejected,
          started_at,
          byte_count,
          :invalid_request
        )

        {:reply, {:error, %{reason: "invalid_request"}}, socket}
    end
  end

  defp handle_call_command(operation, payload, socket, callback) do
    started_at = System.monotonic_time(:millisecond)

    case CallCommand.validate(
           payload,
           socket.assigns.signaling_session_id,
           socket.assigns.call_id
         ) do
      {:ok, command} ->
        dispatch_call_command(operation, command, started_at, socket, callback)

      {:error, :invalid_request, byte_count} ->
        CallSignaling.emit_operation(
          operation,
          :rejected,
          started_at,
          byte_count,
          :invalid_request
        )

        {:reply, {:error, %{reason: "invalid_request"}}, socket}
    end
  end

  defp dispatch_call_command(operation, command, started_at, socket, callback) do
    case callback.(socket.assigns.current_scope, command.call_id) do
      {:ok, projection} ->
        CallSignaling.emit_operation(operation, :accepted, started_at, command.byte_count)

        projection = CallSignaling.with_ownership(projection, socket)

        {:reply, {:ok, CallSignaling.envelope_from_socket(socket, projection)},
         assign(socket, :last_call, projection)}

      {:error, reason} ->
        {outcome, error_code} = command_failure(reason)

        CallSignaling.emit_operation(
          operation,
          outcome,
          started_at,
          command.byte_count,
          error_code
        )

        {:reply, {:error, %{reason: Atom.to_string(error_code)}}, socket}
    end
  end

  defp deliver_lifecycle(socket, event, projection) do
    projection = CallSignaling.with_ownership(projection, socket)

    cond do
      not matching_assigned_call?(projection, socket) ->
        socket

      not CallSignaling.participant_projection?(projection, socket) ->
        socket

      CallSignaling.same_lifecycle?(socket.assigns.last_call, projection) ->
        socket

      CallSignaling.terminal_call?(socket.assigns.last_call, projection.call_id) ->
        socket

      true ->
        wire_event = Map.fetch!(@lifecycle_events, event)
        Diagnostics.emit("projection", :accepted)
        socket = CallSignaling.push_lifecycle(socket, wire_event, projection)
        assign(socket, :last_call, projection)
    end
  end

  defp deliver_terminal(socket, event, projection) do
    cond do
      not matching_assigned_call?(projection, socket) ->
        socket

      not CallSignaling.participant_projection?(projection, socket) ->
        socket

      CallSignaling.same_committed_terminal?(socket.assigns.last_call, projection) ->
        socket

      true ->
        wire_event = Map.fetch!(@terminal_events, event)
        Diagnostics.emit("projection", :accepted)
        push(socket, wire_event, CallSignaling.envelope_from_socket(socket, projection))
        socket = assign(socket, :last_call, projection)
        maybe_close_after_relationship_ended(event, socket)
    end
  end

  defp matching_assigned_call?(projection, socket) do
    Map.get(projection, :call_id) == socket.assigns.call_id
  end

  defp maybe_close_after_relationship_ended(:call_relationship_ended, socket) do
    {:stop, {:shutdown, :relationship_ended}, socket}
  end

  defp maybe_close_after_relationship_ended(_event, socket), do: socket

  defp command_failure(:not_found), do: {:rejected, :not_found}
  defp command_failure(:stale), do: {:rejected, :stale}
  defp command_failure(:temporarily_unavailable), do: {:failed, :temporarily_unavailable}
  defp command_failure(:unauthenticated), do: {:rejected, :not_found}
  defp command_failure(_reason), do: {:failed, :temporarily_unavailable}
end
