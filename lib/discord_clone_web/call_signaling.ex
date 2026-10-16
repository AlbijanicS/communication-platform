defmodule DiscordCloneWeb.CallSignaling do
  @moduledoc false

  alias DiscordClone.Accounts.Scope
  alias DiscordClone.Calls
  alias DiscordCloneWeb.CallSignaling.Diagnostics
  alias DiscordCloneWeb.Signaling

  @inbox_topic "call_inbox:current-user"
  @call_topic_prefix "call:"
  @call_command_events ["decline_call", "cancel_call", "accept_call", "leave_call"]
  @reserved_control_events []
  @reserved_media_events [
    "offer",
    "ice_candidate",
    "ice_route",
    "renew",
    "local_media_state"
  ]

  @lifecycle_events %{
    call_connecting: "call_connecting",
    call_active: "call_active"
  }

  @sibling_owns_event "sibling_tab_owns_call"

  @terminal_events %{
    call_declined: "call_declined",
    call_cancelled: "call_cancelled",
    call_timed_out: "call_timed_out",
    call_relationship_ended: "call_ended",
    call_interrupted: "call_ended",
    call_completed: "call_ended",
    call_failed_capacity: "call_error",
    call_failed: "call_error"
  }

  @spec inbox_topic() :: String.t()
  def inbox_topic, do: @inbox_topic

  @spec call_topic_prefix() :: String.t()
  def call_topic_prefix, do: @call_topic_prefix

  @spec call_command_events() :: [String.t()]
  def call_command_events, do: @call_command_events

  @spec reserved_control_events() :: [String.t()]
  def reserved_control_events, do: @reserved_control_events

  @spec reserved_media_events() :: [String.t()]
  def reserved_media_events, do: @reserved_media_events

  @spec call_topic(Ecto.UUID.t()) :: String.t()
  def call_topic(call_id) when is_binary(call_id), do: @call_topic_prefix <> call_id

  @spec parse_call_topic(String.t()) :: {:ok, Ecto.UUID.t()} | :error
  def parse_call_topic(@call_topic_prefix <> call_id), do: Ecto.UUID.cast(call_id)
  def parse_call_topic(_topic), do: :error

  @spec terminal_events() :: %{atom() => String.t()}
  def terminal_events, do: @terminal_events

  @spec lifecycle_events() :: %{atom() => String.t()}
  def lifecycle_events, do: @lifecycle_events

  @doc "Wire events that prompt a losing sibling that another connection owns the call."
  @spec sibling_events() :: [String.t()]
  def sibling_events, do: [@sibling_owns_event]

  @spec sibling_owns_event() :: String.t()
  def sibling_owns_event, do: @sibling_owns_event

  @spec wire_call(map() | nil, Scope.t()) :: map() | nil
  def wire_call(nil, _scope), do: nil

  def wire_call(projection, %Scope{user: %{id: user_id}} = scope) when is_map(projection) do
    {:ok, peer} = Calls.peer_identity(scope, projection)

    projection
    |> Map.take(Calls.projection_keys() ++ [:answer_mode, :ownership, :media_state])
    |> Map.put(:role, role_for(projection, user_id))
    |> Map.put(:peer, peer)
  end

  @doc """
  Adds current ownership and accepted media state to a live projection.

  `self`, `elsewhere`, and `unclaimed` are computed per receiving connection at
  delivery time from transient CallServer state. Terminal projections carry no
  ownership or media state. Accepted snapshots are read at delivery time so
  delayed lifecycle broadcasts cannot roll back either media field. The raw
  Call Connection ID never enters the returned map.
  """
  @spec with_ownership(map() | nil, Scope.t(), Ecto.UUID.t() | nil) :: map() | nil
  def with_ownership(projection, scope, connection_id)

  def with_ownership(%{ownership: _ownership} = projection, _scope, _connection_id),
    do: projection

  def with_ownership(projection, scope, connection_id) do
    projection
    |> owner_projection(scope, connection_id)
    |> then(fn
      nil -> nil
      projection -> Calls.with_media_state(projection)
    end)
  end

  defp owner_projection(nil, _scope, _connection_id), do: nil

  defp owner_projection(%{state: state} = projection, %Scope{user: %{id: user_id}}, connection_id)
       when state in [:ringing, :connecting, :active] and is_binary(connection_id) do
    case Calls.ownership(projection.call_id, role_for(projection, user_id), connection_id) do
      ownership when ownership in [:self, :elsewhere, :unclaimed] ->
        Map.put(projection, :ownership, ownership)

      _unavailable ->
        projection
    end
  end

  defp owner_projection(projection, _scope, _connection_id), do: projection

  @spec with_ownership(map() | nil, Phoenix.Socket.t()) :: map() | nil
  def with_ownership(projection, socket) do
    with_ownership(
      projection,
      socket.assigns.current_scope,
      Map.get(socket.assigns, :connection_id)
    )
  end

  @spec envelope(String.t(), map() | nil, Scope.t()) :: %{
          signaling_session_id: String.t(),
          call: map() | nil
        }
  def envelope(signaling_session_id, projection, scope) when is_binary(signaling_session_id) do
    %{
      signaling_session_id: signaling_session_id,
      call: wire_call(projection, scope)
    }
  end

  @spec envelope(String.t(), map() | nil, Scope.t(), Ecto.UUID.t() | nil) :: %{
          signaling_session_id: String.t(),
          call: map() | nil
        }
  def envelope(signaling_session_id, projection, scope, connection_id)
      when is_binary(signaling_session_id) do
    %{
      signaling_session_id: signaling_session_id,
      call: wire_call(with_ownership(projection, scope, connection_id), scope)
    }
  end

  @spec role_for(map(), Ecto.UUID.t()) :: :caller | :recipient
  def role_for(%{caller_user_id: user_id}, user_id), do: :caller
  def role_for(%{recipient_user_id: user_id}, user_id), do: :recipient

  @spec ringing_event(map(), Scope.t()) :: String.t()
  def ringing_event(projection, %Scope{user: %{id: user_id}}) do
    case role_for(projection, user_id) do
      :caller -> "outgoing_call_ringing"
      :recipient -> "incoming_call"
    end
  end

  @spec envelope_from_socket(Phoenix.Socket.t(), map() | nil) :: %{
          signaling_session_id: String.t(),
          call: map() | nil
        }
  def envelope_from_socket(socket, projection) do
    envelope(
      socket.assigns.signaling_session_id,
      projection,
      socket.assigns.current_scope,
      Map.get(socket.assigns, :connection_id)
    )
  end

  @doc """
  Pushes a lifecycle event and, when a sibling owns the call, the sibling prompt.

  The Call Inbox and Call topic share this delivery rule so a losing tab learns
  about the winner promptly on either topic without revealing which tab won.
  """
  @spec push_lifecycle(Phoenix.Socket.t(), String.t(), map()) :: Phoenix.Socket.t()
  def push_lifecycle(socket, wire_event, projection) do
    envelope = envelope_from_socket(socket, projection)
    :ok = Phoenix.Channel.push(socket, wire_event, envelope)

    if Map.get(projection, :ownership) == :elsewhere do
      :ok = Phoenix.Channel.push(socket, @sibling_owns_event, envelope)
    end

    socket
  end

  @spec participant_projection?(map(), Phoenix.Socket.t()) :: boolean()
  def participant_projection?(projection, socket) do
    Calls.participant_projection?(projection, socket.assigns.current_scope.user.id)
  end

  @spec same_committed_terminal?(map() | nil, map()) :: boolean()
  def same_committed_terminal?(
        %{call_id: call_id, state: :terminal, terminal_outcome: outcome},
        %{call_id: call_id, state: :terminal, terminal_outcome: outcome}
      ),
      do: true

  def same_committed_terminal?(_last, _current), do: false

  @spec same_lifecycle?(map() | nil, map()) :: boolean()
  def same_lifecycle?(
        %{call_id: call_id, state: state} = last,
        %{call_id: call_id, state: state} = current
      ) do
    Map.get(last, :answer_mode) == Map.get(current, :answer_mode) and
      Map.get(last, :ownership) == Map.get(current, :ownership) and
      Map.get(last, :media_state) == Map.get(current, :media_state)
  end

  def same_lifecycle?(_last, _current), do: false

  @spec terminal_call?(map() | nil, Ecto.UUID.t()) :: boolean()
  def terminal_call?(%{call_id: call_id, state: :terminal}, call_id), do: true
  def terminal_call?(_projection, _call_id), do: false

  @spec reject_unsupported(term(), Phoenix.Socket.t()) ::
          {:reply, {:error, %{reason: String.t()}}, Phoenix.Socket.t()}
  def reject_unsupported(payload, socket) do
    Diagnostics.emit("unsupported_request", :rejected,
      error_code: :unsupported_event,
      decoded_request_byte_count: Signaling.decoded_request_byte_count(payload)
    )

    {:reply, {:error, %{reason: "unsupported_event"}}, socket}
  end

  @spec terminate_joined(Phoenix.Socket.t()) :: :ok
  def terminate_joined(socket) do
    if Map.has_key?(socket.assigns, :signaling_session_id) do
      Diagnostics.emit("termination", :accepted)
    end

    :ok
  end

  @doc """
  Registers the socket's server-derived Call Connection for a Call topic join.

  The connection identity comes only from socket assigns. Registration is
  observational and ordered before any command this channel can process.
  """
  @spec register_connection(Phoenix.Socket.t(), Ecto.UUID.t(), map()) :: :ok
  def register_connection(socket, call_id, projection) do
    with connection_id when is_binary(connection_id) <-
           Map.get(socket.assigns, :connection_id),
         user_id when is_binary(user_id) <- socket.assigns.current_scope.user.id do
      Calls.register_connection(call_id, user_id, role_for(projection, user_id), connection_id)
    else
      _missing_identity -> :ok
    end
  end

  @doc "Unregisters the socket's Call Connection for its joined Call topic."
  @spec unregister_connection(Phoenix.Socket.t()) :: :ok
  def unregister_connection(socket) do
    with call_id when is_binary(call_id) <- Map.get(socket.assigns, :call_id),
         connection_id when is_binary(connection_id) <-
           Map.get(socket.assigns, :connection_id) do
      Calls.unregister_connection(call_id, connection_id)
    else
      _missing_identity -> :ok
    end
  end

  @spec emit_join(integer(), term(), :accepted | :rejected | :failed, atom() | nil) :: :ok
  def emit_join(started_at, params, outcome, error_code \\ nil) do
    emit_operation(
      "join",
      outcome,
      started_at,
      Signaling.decoded_request_byte_count(params),
      error_code
    )
  end

  @spec emit_operation(
          String.t(),
          :accepted | :rejected | :failed,
          integer(),
          non_neg_integer() | nil,
          atom() | nil
        ) :: :ok
  def emit_operation(operation, outcome, started_at, byte_count, error_code \\ nil) do
    Diagnostics.emit(operation, outcome,
      error_code: error_code,
      duration_ms: max(System.monotonic_time(:millisecond) - started_at, 0),
      decoded_request_byte_count: byte_count
    )
  end
end
