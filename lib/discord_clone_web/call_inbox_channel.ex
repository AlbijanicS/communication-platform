defmodule DiscordCloneWeb.CallInboxChannel do
  use Phoenix.Channel, log_join: false, log_handle_in: false

  alias DiscordClone.Calls
  alias DiscordCloneWeb.CallSignaling
  alias DiscordCloneWeb.CallSignaling.Diagnostics
  alias DiscordCloneWeb.CallSignaling.StartCall

  @inbox_topic CallSignaling.inbox_topic()
  @lifecycle_events CallSignaling.lifecycle_events()
  @terminal_events CallSignaling.terminal_events()

  @impl true
  def join(@inbox_topic, params, socket) when map_size(params) == 0 do
    started_at = System.monotonic_time(:millisecond)
    scope = socket.assigns.current_scope

    with :ok <- Calls.subscribe(scope),
         {:ok, projection} <- Calls.current_call(scope) do
      signaling_session_id = Ecto.UUID.generate()
      CallSignaling.emit_join(started_at, params, :accepted)

      projection = CallSignaling.with_ownership(projection, socket)

      {:ok, CallSignaling.envelope(signaling_session_id, projection, scope),
       socket
       |> assign(:signaling_session_id, signaling_session_id)
       |> assign(:last_call, projection)}
    else
      {:error, :temporarily_unavailable} ->
        CallSignaling.emit_join(started_at, params, :failed, :temporarily_unavailable)
        {:error, %{reason: "temporarily_unavailable"}}

      {:error, _reason} ->
        CallSignaling.emit_join(started_at, params, :rejected, :invalid_request)
        {:error, %{reason: "invalid_request"}}
    end
  end

  def join(_topic, _params, _socket) do
    Diagnostics.emit("join", :rejected, error_code: :invalid_request)
    {:error, %{reason: "invalid_request"}}
  end

  @impl true
  def handle_in("start_call", payload, socket) do
    started_at = System.monotonic_time(:millisecond)

    case StartCall.validate(payload, socket.assigns.signaling_session_id) do
      {:ok, command} ->
        start_call(command, started_at, socket)

      {:error, :invalid_request, byte_count} ->
        CallSignaling.emit_operation(
          "start_call",
          :rejected,
          started_at,
          byte_count,
          :invalid_request
        )

        {:reply, {:error, %{reason: "invalid_request"}}, socket}
    end
  end

  def handle_in(_event, payload, socket), do: CallSignaling.reject_unsupported(payload, socket)

  @impl true
  def handle_info({:call_ringing, projection}, socket) when is_map(projection) do
    if CallSignaling.participant_projection?(projection, socket) do
      deliver_ringing(socket, projection)
    else
      {:noreply, socket}
    end
  end

  def handle_info({event, projection}, socket)
      when is_map_key(@lifecycle_events, event) and is_map(projection) do
    {:noreply, deliver_lifecycle(socket, event, projection)}
  end

  def handle_info({event, projection}, socket)
      when is_map_key(@terminal_events, event) and is_map(projection) do
    {:noreply, deliver_terminal(socket, event, projection)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, socket), do: CallSignaling.terminate_joined(socket)

  defp deliver_ringing(socket, projection) do
    projection = CallSignaling.with_ownership(projection, socket)

    # A terminal last_call for this Call ID wins over delayed ringing without
    # a current_call/1 re-read, so discovery unavailability cannot stop the inbox.
    if CallSignaling.terminal_call?(socket.assigns.last_call, projection.call_id) do
      {:noreply, socket}
    else
      reconcile_current_ringing(socket, projection)
    end
  end

  defp reconcile_current_ringing(socket, projection) do
    scope = socket.assigns.current_scope

    case Calls.current_call(scope) do
      {:ok, %{call_id: call_id, state: :ringing} = current} ->
        if call_id == projection.call_id do
          push_ringing_if_new(socket, CallSignaling.with_ownership(current, socket))
        else
          {:noreply, socket}
        end

      {:ok, _other} ->
        {:noreply, socket}

      {:error, :temporarily_unavailable} ->
        Diagnostics.emit("projection", :failed, error_code: :temporarily_unavailable)
        {:stop, {:shutdown, :temporarily_unavailable}, socket}

      {:error, _reason} ->
        {:noreply, socket}
    end
  end

  defp push_ringing_if_new(socket, current) do
    if same_ringing?(socket.assigns.last_call, current) do
      {:noreply, socket}
    else
      event = CallSignaling.ringing_event(current, socket.assigns.current_scope)
      Diagnostics.emit("projection", :accepted)
      push(socket, event, CallSignaling.envelope_from_socket(socket, current))
      {:noreply, assign(socket, :last_call, current)}
    end
  end

  defp deliver_lifecycle(socket, event, projection) do
    projection = CallSignaling.with_ownership(projection, socket)
    last_call = socket.assigns.last_call

    cond do
      not CallSignaling.participant_projection?(projection, socket) ->
        socket

      is_nil(last_call) ->
        socket

      last_call.call_id != projection.call_id ->
        socket

      CallSignaling.same_lifecycle?(last_call, projection) ->
        socket

      CallSignaling.terminal_call?(last_call, projection.call_id) ->
        socket

      true ->
        wire_event = Map.fetch!(@lifecycle_events, event)
        Diagnostics.emit("projection", :accepted)
        socket = CallSignaling.push_lifecycle(socket, wire_event, projection)
        assign(socket, :last_call, projection)
    end
  end

  defp same_ringing?(
         %{call_id: call_id, state: :ringing} = last,
         %{call_id: call_id, state: :ringing} = current
       ),
       do: Map.get(last, :ownership) == Map.get(current, :ownership)

  defp same_ringing?(_last, _current), do: false

  defp deliver_terminal(socket, event, projection) do
    last_call = socket.assigns.last_call

    cond do
      not CallSignaling.participant_projection?(projection, socket) ->
        socket

      is_nil(last_call) ->
        socket

      last_call.call_id != projection.call_id ->
        socket

      CallSignaling.same_committed_terminal?(last_call, projection) ->
        socket

      true ->
        wire_event = Map.fetch!(@terminal_events, event)
        Diagnostics.emit("projection", :accepted)
        push(socket, wire_event, CallSignaling.envelope_from_socket(socket, projection))
        # Keep the delivered terminal so delayed ringing for this Call ID is ignored.
        assign(socket, :last_call, projection)
    end
  end

  defp start_call(command, started_at, socket) do
    case Calls.start_call(
           socket.assigns.current_scope,
           command.direct_conversation_id,
           command.media_intent,
           caller_connection_id: Map.get(socket.assigns, :connection_id)
         ) do
      {:ok, %{call: projection, started?: started?}} ->
        CallSignaling.emit_operation("start_call", :accepted, started_at, command.byte_count)
        projection = CallSignaling.with_ownership(projection, socket)

        {:reply,
         {:ok,
          Map.put(CallSignaling.envelope_from_socket(socket, projection), :started, started?)},
         assign(socket, :last_call, projection)}

      {:error, reason} ->
        {outcome, error_code} = start_call_failure(reason)

        CallSignaling.emit_operation(
          "start_call",
          outcome,
          started_at,
          command.byte_count,
          error_code
        )

        {:reply, {:error, %{reason: Atom.to_string(error_code)}}, socket}
    end
  end

  defp start_call_failure(:not_found), do: {:rejected, :not_found}
  defp start_call_failure(:not_friends), do: {:rejected, :not_friends}
  defp start_call_failure(:busy), do: {:rejected, :busy}
  defp start_call_failure(:rate_limited), do: {:rejected, :rate_limited}
  defp start_call_failure(:temporarily_unavailable), do: {:failed, :temporarily_unavailable}
  defp start_call_failure(:invalid_media_intent), do: {:rejected, :invalid_request}
  defp start_call_failure(:unauthenticated), do: {:rejected, :invalid_request}
  defp start_call_failure(_reason), do: {:failed, :temporarily_unavailable}
end
