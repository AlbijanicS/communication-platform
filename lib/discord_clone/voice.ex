defmodule DiscordClone.Voice do
  @moduledoc """
  Starts and observes ephemeral Voice Channel room runtimes.

  Durable authorization remains the responsibility of `DiscordClone.Workspaces`.
  This boundary owns only the lifecycle of a room keyed by an already-authorized
  Voice Channel ID.
  """

  alias DiscordClone.Media.AdmissionCoordinator
  alias DiscordClone.Accounts.Scope
  alias DiscordClone.UUIDIdentifier

  alias DiscordClone.Voice.{
    ICEConfigurationResolver,
    RoomRegistry,
    RoomServer,
    RoomSupervisor,
    ServerICEProjection,
    SessionICEBundle
  }

  @command_timeout_ms 5_000

  @doc """
  Returns the safe current Voice Channel Roster snapshot for a Voice Channel.

  This runtime projection contains User IDs and effective shared Voice states
  in Voice Session admission order. Workspace-facing code is responsible for
  authorization and resolving those IDs to display identities.
  """
  @spec voice_channel_roster(term()) ::
          {:ok,
           %{
             voice_channel_id: Ecto.UUID.t(),
             members: [
               %{
                 user_id: Ecto.UUID.t(),
                 muted: boolean(),
                 deafened: boolean(),
                 speaking: boolean()
               }
             ]
           }}
          | {:error, :not_found}
  def voice_channel_roster(voice_channel_id) do
    UUIDIdentifier.cast_or(voice_channel_id, {:error, :not_found}, fn voice_channel_id ->
      case room_server(voice_channel_id) do
        nil -> {:ok, empty_roster(voice_channel_id)}
        room_server -> safe_voice_channel_roster(room_server, voice_channel_id)
      end
    end)
  end

  @doc false
  @spec subscribe_to_voice_channel_roster(term()) :: :ok | {:error, :not_found}
  def subscribe_to_voice_channel_roster(voice_channel_id) do
    UUIDIdentifier.cast_or(voice_channel_id, {:error, :not_found}, fn voice_channel_id ->
      topic = voice_channel_roster_topic(voice_channel_id)

      if topic in Registry.keys(DiscordClone.PubSub, self()) do
        :ok
      else
        Phoenix.PubSub.subscribe(DiscordClone.PubSub, topic)
      end
    end)
  end

  @doc false
  @spec publish_voice_channel_roster(%{
          voice_channel_id: Ecto.UUID.t(),
          members: [
            %{user_id: Ecto.UUID.t(), muted: boolean(), deafened: boolean(), speaking: boolean()}
          ]
        }) :: :ok
  def publish_voice_channel_roster(%{voice_channel_id: voice_channel_id} = snapshot) do
    Phoenix.PubSub.broadcast(
      DiscordClone.PubSub,
      voice_channel_roster_topic(voice_channel_id),
      {:voice_channel_roster_changed, snapshot}
    )
  end

  @spec ensure_room(term()) :: :ok | {:error, :not_found | term()}
  def ensure_room(voice_channel_id) do
    UUIDIdentifier.cast_or(voice_channel_id, {:error, :not_found}, &ensure_room_id/1)
  end

  @spec room_running?(term()) :: boolean()
  def room_running?(voice_channel_id) do
    UUIDIdentifier.cast_or(voice_channel_id, false, &room_running/1)
  end

  @spec join(term(), term(), binary(), pid()) :: {:ok, map()} | {:error, term()}
  def join(voice_channel_id, user_id, signaling_session_id, signaling_channel)
      when is_binary(signaling_session_id) and is_pid(signaling_channel) do
    join(
      voice_channel_id,
      user_id,
      signaling_session_id,
      signaling_channel,
      ServerICEProjection.disabled()
    )
  end

  def join(_voice_channel_id, _user_id, _signaling_session_id, _signaling_channel),
    do: {:error, :invalid_admission}

  @doc """
  Resolves one session ICE bundle and admits the matching Voice Session.

  The caller receives only the browser projection alongside the normal runtime
  admission result. The server projection is consumed while starting the owned
  ExWebRTC PeerConnection.
  """
  @spec join_with_ice_configuration(Scope.t(), term(), binary(), pid()) ::
          {:ok, map(), SessionICEBundle.browser_projection()} | {:error, term()}
  def join_with_ice_configuration(
        %Scope{user: %{id: user_id}},
        voice_channel_id,
        signaling_session_id,
        signaling_channel
      )
      when is_binary(signaling_session_id) and is_pid(signaling_channel) do
    with true <- Process.alive?(signaling_channel),
         {:ok, [voice_channel_id, user_id]} <-
           UUIDIdentifier.cast_all([voice_channel_id, user_id]),
         {:ok, ice_bundle} <- ICEConfigurationResolver.resolve(),
         {:ok, join_result} <-
           safe_join(
             voice_channel_id,
             user_id,
             signaling_session_id,
             signaling_channel,
             ice_bundle.server_projection
           ) do
      {:ok, join_result, ice_bundle.browser_projection}
    else
      false ->
        {:error, :invalid_admission}

      :error ->
        {:error, :not_found}

      {:error, reason}
      when reason in [:invalid_configuration, :invalid_provider_response, :provider_unavailable] ->
        {:error, :unavailable}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def join_with_ice_configuration(
        _current_scope,
        _voice_channel_id,
        _signaling_session_id,
        _signaling_channel
      ),
      do: {:error, :invalid_admission}

  @spec join(term(), term(), binary(), pid(), ServerICEProjection.t()) ::
          {:ok, map()} | {:error, term()}
  def join(
        voice_channel_id,
        user_id,
        signaling_session_id,
        signaling_channel,
        server_ice_projection
      )
      when is_binary(signaling_session_id) and is_pid(signaling_channel) do
    with true <- Process.alive?(signaling_channel),
         {:ok, server_ice_projection} <- ServerICEProjection.validate(server_ice_projection),
         {:ok, [voice_channel_id, user_id]} <-
           UUIDIdentifier.cast_all([voice_channel_id, user_id]) do
      safe_join(
        voice_channel_id,
        user_id,
        signaling_session_id,
        signaling_channel,
        server_ice_projection
      )
    else
      false -> {:error, :invalid_admission}
      {:error, :invalid_server_ice_projection} -> {:error, :unavailable}
      :error -> {:error, :not_found}
    end
  end

  def join(
        _voice_channel_id,
        _user_id,
        _signaling_session_id,
        _signaling_channel,
        _server_ice_projection
      ),
      do: {:error, :invalid_admission}

  @spec leave(term(), term()) :: :ok | {:error, :not_found | term()}
  def leave(voice_channel_id, voice_session_id) do
    with {:ok, [voice_channel_id, voice_session_id]} <-
           UUIDIdentifier.cast_all([voice_channel_id, voice_session_id]) do
      safe_leave(voice_channel_id, voice_session_id)
    else
      :error -> {:error, :not_found}
    end
  end

  @doc """
  Renews the current authenticated Voice Session's runtime-only liveness lease.

  The caller's User identity and exact Voice Session ID must still match the
  canonical RoomServer membership.
  """
  @spec renew_session(Scope.t(), term(), term(), binary()) ::
          :ok | {:error, :invalid_session | :unavailable}
  def renew_session(
        %Scope{user: %{id: user_id}},
        voice_channel_id,
        voice_session_id,
        signaling_session_id
      )
      when is_binary(user_id) and is_binary(signaling_session_id) do
    with {:ok, [voice_channel_id, voice_session_id]} <-
           UUIDIdentifier.cast_all([voice_channel_id, voice_session_id]),
         room_server when is_pid(room_server) <- room_server(voice_channel_id) do
      safe_renew_session(room_server, user_id, voice_session_id, signaling_session_id)
    else
      nil -> {:error, :unavailable}
      :error -> {:error, :invalid_session}
    end
  end

  def renew_session(_scope, _voice_channel_id, _voice_session_id, _signaling_session_id),
    do: {:error, :invalid_session}

  @doc """
  Updates the browser-originated shared Voice state for the caller's active
  Voice Session.

  Local Deafen always enables Local Mute. The state is runtime-only and is
  cleared when the Voice Session ends.
  """
  @spec update_local_voice_state(Scope.t(), term(), term(), map()) :: :ok | {:error, atom()}
  def update_local_voice_state(
        %Scope{user: %{id: user_id}},
        voice_channel_id,
        voice_session_id,
        %{muted: muted, deafened: deafened}
      )
      when is_binary(user_id) and is_boolean(muted) and is_boolean(deafened) do
    with {:ok, [voice_channel_id, voice_session_id]} <-
           UUIDIdentifier.cast_all([voice_channel_id, voice_session_id]),
         room_server when is_pid(room_server) <- room_server(voice_channel_id) do
      safe_update_local_voice_state(
        room_server,
        user_id,
        voice_session_id,
        muted,
        deafened
      )
    else
      nil -> {:error, :unavailable}
      :error -> {:error, :invalid_session}
    end
  end

  def update_local_voice_state(_scope, _voice_channel_id, _voice_session_id, _state),
    do: {:error, :invalid_session}

  @doc """
  Applies a durable Workspace Mute to the matching active Voice Session.

  Workspaces owns the moderation decision; Voice applies only its runtime
  routing and safe roster consequences.
  """
  @spec set_workspace_muted(term(), term(), boolean()) :: :ok | {:error, :not_found}
  def set_workspace_muted(voice_channel_id, user_id, muted) when is_boolean(muted) do
    with {:ok, [voice_channel_id, user_id]} <-
           UUIDIdentifier.cast_all([voice_channel_id, user_id]) do
      case room_server(voice_channel_id) do
        nil -> :ok
        room_server -> RoomServer.set_workspace_muted(room_server, user_id, muted)
      end
    else
      :error -> {:error, :not_found}
    end
  end

  def set_workspace_muted(_voice_channel_id, _user_id, _muted), do: {:error, :not_found}

  @spec accept_offer(Scope.t(), term(), term(), binary(), map()) ::
          {:ok, map()} | {:error, atom()}
  def accept_offer(
        %Scope{user: %{id: user_id}},
        voice_channel_id,
        voice_session_id,
        negotiation_id,
        description
      )
      when is_binary(user_id) and is_binary(negotiation_id) and is_map(description) do
    deadline = command_deadline()

    with {:ok, [voice_channel_id, voice_session_id]} <-
           UUIDIdentifier.cast_all([voice_channel_id, voice_session_id]),
         room_server when is_pid(room_server) <- room_server(voice_channel_id) do
      safe_accept_offer(
        room_server,
        user_id,
        voice_session_id,
        negotiation_id,
        description,
        deadline
      )
    else
      nil -> {:error, :unavailable}
      :error -> {:error, :invalid_session}
    end
  end

  def accept_offer(
        _current_scope,
        _voice_channel_id,
        _voice_session_id,
        _negotiation_id,
        _description
      ),
      do: {:error, :invalid_session}

  @spec add_ice_candidate(Scope.t(), term(), term(), binary(), map()) ::
          {:ok, map()} | {:error, atom()}
  def add_ice_candidate(
        %Scope{user: %{id: user_id}},
        voice_channel_id,
        voice_session_id,
        negotiation_id,
        candidate
      )
      when is_binary(user_id) and is_binary(negotiation_id) and is_map(candidate) do
    deadline = command_deadline()

    with {:ok, [voice_channel_id, voice_session_id]} <-
           UUIDIdentifier.cast_all([voice_channel_id, voice_session_id]),
         room_server when is_pid(room_server) <- room_server(voice_channel_id) do
      safe_add_ice_candidate(
        room_server,
        user_id,
        voice_session_id,
        negotiation_id,
        candidate,
        deadline
      )
    else
      nil -> {:error, :unavailable}
      :error -> {:error, :invalid_session}
    end
  end

  def add_ice_candidate(
        _current_scope,
        _voice_channel_id,
        _voice_session_id,
        _negotiation_id,
        _candidate
      ),
      do: {:error, :invalid_session}

  @spec end_of_candidates(Scope.t(), term(), term(), binary()) :: {:error, atom()}
  def end_of_candidates(
        %Scope{user: %{id: user_id}},
        voice_channel_id,
        voice_session_id,
        negotiation_id
      )
      when is_binary(user_id) and is_binary(negotiation_id) do
    deadline = command_deadline()

    with {:ok, [voice_channel_id, voice_session_id]} <-
           UUIDIdentifier.cast_all([voice_channel_id, voice_session_id]),
         room_server when is_pid(room_server) <- room_server(voice_channel_id) do
      safe_end_of_candidates(
        room_server,
        user_id,
        voice_session_id,
        negotiation_id,
        deadline
      )
    else
      nil -> {:error, :unavailable}
      :error -> {:error, :invalid_session}
    end
  end

  def end_of_candidates(_current_scope, _voice_channel_id, _voice_session_id, _negotiation_id),
    do: {:error, :invalid_session}

  @doc """
  Ends the current Voice Session for a User when it belongs to the given Voice Channel.

  This is a lifecycle notification seam for durable access changes. A missing or
  already-ended matching session is treated as a successful no-op.
  """
  @spec end_user_session(term(), term()) :: :ok | {:error, :not_found | term()}
  def end_user_session(voice_channel_id, user_id) do
    with {:ok, [voice_channel_id, user_id]} <-
           UUIDIdentifier.cast_all([voice_channel_id, user_id]) do
      safe_end_user_session(voice_channel_id, user_id)
    else
      :error -> {:error, :not_found}
    end
  end

  @doc """
  Ends every current Voice Session in a Voice Channel.

  A missing or already-empty runtime is treated as a successful no-op.
  """
  @spec end_channel_sessions(term()) :: :ok | {:error, :not_found | term()}
  def end_channel_sessions(voice_channel_id) do
    UUIDIdentifier.cast_or(voice_channel_id, {:error, :not_found}, fn voice_channel_id ->
      safe_end_channel_sessions(voice_channel_id)
    end)
  end

  @spec room_occupancy(term()) ::
          {:ok, %{occupancy: non_neg_integer(), capacity: pos_integer()}} | {:error, :not_found}
  def room_occupancy(voice_channel_id) do
    UUIDIdentifier.cast_or(voice_channel_id, {:error, :not_found}, fn voice_channel_id ->
      case room_server(voice_channel_id) do
        nil -> {:error, :not_found}
        room_server -> safe_room_occupancy(room_server)
      end
    end)
  end

  @doc false
  @spec crash_session(term(), term()) :: :ok | {:error, :not_found}
  def crash_session(voice_channel_id, voice_session_id) do
    with {:ok, [voice_channel_id, voice_session_id]} <-
           UUIDIdentifier.cast_all([voice_channel_id, voice_session_id]) do
      case room_server(voice_channel_id) do
        nil -> :ok
        room_server -> RoomServer.crash_session(room_server, voice_session_id)
      end
    else
      :error -> {:error, :not_found}
    end
  end

  @doc false
  @spec dispatch_test_ex_webrtc(term(), term(), term()) :: :ok | {:error, :not_found}
  def dispatch_test_ex_webrtc(voice_channel_id, voice_session_id, message) do
    with {:ok, [voice_channel_id, voice_session_id]} <-
           UUIDIdentifier.cast_all([voice_channel_id, voice_session_id]),
         room_server when is_pid(room_server) <- room_server(voice_channel_id) do
      safe_dispatch_test_ex_webrtc(room_server, voice_session_id, message)
    else
      nil -> {:error, :not_found}
      :error -> {:error, :not_found}
    end
  end

  @doc false
  @spec await_empty_room(term()) :: :ok | {:error, :not_found}
  def await_empty_room(voice_channel_id) do
    UUIDIdentifier.cast_or(voice_channel_id, {:error, :not_found}, fn voice_channel_id ->
      case room_server(voice_channel_id) do
        nil -> :ok
        room_server -> RoomServer.await_empty(room_server)
      end
    end)
  end

  @doc false
  @spec expire_idle_room(term()) :: :ok | {:error, :not_found}
  def expire_idle_room(voice_channel_id) do
    UUIDIdentifier.cast_or(voice_channel_id, {:error, :not_found}, fn voice_channel_id ->
      case room_server(voice_channel_id) do
        nil -> :ok
        room_server -> await_room_shutdown(room_server)
      end
    end)
  end

  @doc false
  @spec crash_session_coordinator() :: :ok | {:error, :not_running}
  def crash_session_coordinator do
    case Process.whereis(DiscordClone.Voice.SessionCoordinator) do
      session_coordinator when is_pid(session_coordinator) ->
        Process.exit(session_coordinator, :kill)
        :ok

      nil ->
        {:error, :not_running}
    end
  end

  @doc false
  @spec crash_forwarder(term()) :: :ok | {:error, :not_found}
  def crash_forwarder(voice_channel_id) do
    UUIDIdentifier.cast_or(voice_channel_id, {:error, :not_found}, fn voice_channel_id ->
      case Registry.lookup(RoomRegistry, {:forwarder, voice_channel_id}) do
        [{forwarder, _value}] when is_pid(forwarder) ->
          monitor = Process.monitor(forwarder)
          Process.exit(forwarder, :kill)

          receive do
            {:DOWN, ^monitor, :process, ^forwarder, _reason} -> :ok
          end

        _missing_or_stopped ->
          :ok
      end
    end)
  end

  @doc false
  @spec await_session_coordinator_recovery() :: :ok | {:error, :recovery_timeout}
  def await_session_coordinator_recovery, do: AdmissionCoordinator.await_ready()

  @doc false
  @spec mark_room_in_use(term()) :: :ok | {:error, :not_found | :not_running | term()}
  def mark_room_in_use(voice_channel_id) do
    case UUIDIdentifier.cast(voice_channel_id) do
      {:ok, voice_channel_id} -> mark_room_in_use(voice_channel_id, 2)
      :error -> {:error, :not_found}
    end
  end

  @doc false
  @spec mark_room_empty(term(), keyword()) :: :ok | {:error, :not_found | term()}
  def mark_room_empty(voice_channel_id, opts \\ []) do
    UUIDIdentifier.cast_or(voice_channel_id, {:error, :not_found}, fn voice_channel_id ->
      case room_server(voice_channel_id) do
        nil -> :ok
        room_server -> RoomServer.mark_empty(room_server, opts)
      end
    end)
  end

  @doc false
  @spec join_room(Ecto.UUID.t(), Ecto.UUID.t(), binary(), pid(), ServerICEProjection.t()) ::
          {:ok, map(), pid()} | {:error, term()}
  def join_room(
        voice_channel_id,
        user_id,
        signaling_session_id,
        signaling_channel,
        server_ice_projection
      ) do
    join_room(
      voice_channel_id,
      user_id,
      signaling_session_id,
      signaling_channel,
      server_ice_projection,
      2
    )
  end

  @doc false
  @spec leave_room(Ecto.UUID.t(), Ecto.UUID.t()) :: :ok
  def leave_room(voice_channel_id, voice_session_id) do
    case room_server(voice_channel_id) do
      nil -> :ok
      room_server -> safe_room_leave(room_server, voice_session_id)
    end
  end

  @doc false
  @spec retire_room_session(Ecto.UUID.t(), Ecto.UUID.t()) :: :ok | {:error, :unavailable}
  def retire_room_session(voice_channel_id, voice_session_id) do
    case room_server(voice_channel_id) do
      nil -> :ok
      room_server -> safe_retire_room_session(room_server, voice_session_id)
    end
  end

  defp safe_retire_room_session(room_server, voice_session_id) do
    RoomServer.leave(room_server, voice_session_id)
  catch
    :exit, {:timeout, _call} -> {:error, :unavailable}
    :exit, _room_unavailable -> :ok
  end

  @doc false
  @spec running_room_servers() :: [{Ecto.UUID.t(), pid()}]
  def running_room_servers do
    Registry.select(RoomRegistry, [
      {{{:room, :"$1"}, :"$2", :_}, [], [{{:"$1", :"$2"}}]}
    ])
  end

  defp ensure_room_id(voice_channel_id) do
    if room_running(voice_channel_id) do
      :ok
    else
      case DynamicSupervisor.start_child(RoomSupervisor, {RoomSupervisor, voice_channel_id}) do
        {:ok, _room_supervisor} ->
          :ok

        {:error, {:already_started, _room_supervisor}} ->
          :ok

        {:error, reason} ->
          if room_running(voice_channel_id), do: :ok, else: {:error, reason}
      end
    end
  end

  defp mark_room_in_use(voice_channel_id, attempts_left) do
    with :ok <- ensure_room_id(voice_channel_id),
         room_server when is_pid(room_server) <- room_server(voice_channel_id) do
      RoomServer.mark_in_use(room_server)
    else
      nil when attempts_left > 0 -> mark_room_in_use(voice_channel_id, attempts_left - 1)
      nil -> {:error, :not_running}
      error -> error
    end
  catch
    :exit, _room_stopped when attempts_left > 0 ->
      mark_room_in_use(voice_channel_id, attempts_left - 1)

    :exit, _room_stopped ->
      {:error, :not_running}
  end

  defp join_room(
         voice_channel_id,
         user_id,
         signaling_session_id,
         signaling_channel,
         server_ice_projection,
         attempts_left
       ) do
    with :ok <- ensure_room_id(voice_channel_id),
         room_server when is_pid(room_server) <- room_server(voice_channel_id) do
      case RoomServer.join(
             room_server,
             user_id,
             signaling_session_id,
             signaling_channel,
             server_ice_projection
           ) do
        {:ok, join_result} ->
          {:ok, join_result, room_server}

        {:error, :unavailable} when attempts_left > 0 ->
          join_room(
            voice_channel_id,
            user_id,
            signaling_session_id,
            signaling_channel,
            server_ice_projection,
            attempts_left - 1
          )

        result ->
          result
      end
    else
      nil when attempts_left > 0 ->
        join_room(
          voice_channel_id,
          user_id,
          signaling_session_id,
          signaling_channel,
          server_ice_projection,
          attempts_left - 1
        )

      nil ->
        {:error, :not_found}

      {:error, _room_starting} when attempts_left > 0 ->
        join_room(
          voice_channel_id,
          user_id,
          signaling_session_id,
          signaling_channel,
          server_ice_projection,
          attempts_left - 1
        )

      error ->
        error
    end
  catch
    :exit, _room_stopped when attempts_left > 0 ->
      join_room(
        voice_channel_id,
        user_id,
        signaling_session_id,
        signaling_channel,
        server_ice_projection,
        attempts_left - 1
      )

    :exit, _room_stopped ->
      {:error, :not_found}
  end

  defp room_running(voice_channel_id) do
    is_pid(room_server(voice_channel_id))
  end

  defp room_server(voice_channel_id) do
    case Registry.lookup(RoomRegistry, {:room, voice_channel_id}) do
      [{pid, _value}] when is_pid(pid) -> if(Process.alive?(pid), do: pid)
      _missing_or_stopped -> nil
    end
  end

  defp safe_room_leave(room_server, voice_session_id) do
    RoomServer.leave(room_server, voice_session_id)
  catch
    :exit, _room_stopped -> :ok
  end

  defp safe_renew_session(room_server, user_id, voice_session_id, signaling_session_id) do
    RoomServer.renew_session(room_server, user_id, voice_session_id, signaling_session_id)
  catch
    :exit, _room_stopped -> {:error, :unavailable}
  end

  defp safe_join(
         voice_channel_id,
         user_id,
         signaling_session_id,
         signaling_channel,
         server_ice_projection
       ) do
    AdmissionCoordinator.join(
      voice_channel_id,
      user_id,
      signaling_session_id,
      signaling_channel,
      server_ice_projection
    )
  catch
    :exit, _session_coordinator_unavailable -> {:error, :recovering}
  end

  defp safe_leave(voice_channel_id, voice_session_id) do
    AdmissionCoordinator.leave(voice_channel_id, voice_session_id)
  catch
    :exit, _session_coordinator_unavailable -> :ok
  end

  defp safe_dispatch_test_ex_webrtc(room_server, voice_session_id, message) do
    RoomServer.dispatch_test_ex_webrtc(room_server, voice_session_id, message)
  catch
    :exit, _room_stopped -> {:error, :not_found}
  end

  defp safe_accept_offer(
         room_server,
         user_id,
         voice_session_id,
         negotiation_id,
         description,
         deadline
       ) do
    RoomServer.accept_offer(
      room_server,
      user_id,
      voice_session_id,
      negotiation_id,
      description,
      deadline
    )
  catch
    :exit, _room_stopped -> {:error, :unavailable}
  end

  defp safe_add_ice_candidate(
         room_server,
         user_id,
         voice_session_id,
         negotiation_id,
         candidate,
         deadline
       ) do
    RoomServer.add_ice_candidate(
      room_server,
      user_id,
      voice_session_id,
      negotiation_id,
      candidate,
      deadline
    )
  catch
    :exit, _room_stopped -> {:error, :unavailable}
  end

  defp safe_end_of_candidates(room_server, user_id, voice_session_id, negotiation_id, deadline) do
    RoomServer.end_of_candidates(
      room_server,
      user_id,
      voice_session_id,
      negotiation_id,
      deadline
    )
  catch
    :exit, _room_stopped -> {:error, :unavailable}
  end

  defp command_deadline do
    System.monotonic_time(:millisecond) + @command_timeout_ms
  end

  defp safe_end_user_session(voice_channel_id, user_id) do
    AdmissionCoordinator.end_user_session(voice_channel_id, user_id)
  catch
    :exit, _session_coordinator_unavailable -> :ok
  end

  defp safe_end_channel_sessions(voice_channel_id) do
    AdmissionCoordinator.end_channel_sessions(voice_channel_id)
  catch
    :exit, _session_coordinator_unavailable -> :ok
  end

  defp safe_room_occupancy(room_server) do
    RoomServer.occupancy(room_server)
  catch
    :exit, _room_stopped -> {:error, :not_found}
  end

  defp safe_update_local_voice_state(room_server, user_id, voice_session_id, muted, deafened) do
    RoomServer.update_local_voice_state(room_server, user_id, voice_session_id, muted, deafened)
  catch
    :exit, _room_stopped -> {:error, :unavailable}
  end

  defp safe_voice_channel_roster(room_server, voice_channel_id) do
    {:ok, RoomServer.roster(room_server)}
  catch
    :exit, _room_stopped -> {:ok, empty_roster(voice_channel_id)}
  end

  defp empty_roster(voice_channel_id), do: %{voice_channel_id: voice_channel_id, members: []}

  defp voice_channel_roster_topic(voice_channel_id),
    do: "voice_channel_roster:#{voice_channel_id}"

  defp await_room_shutdown(room_server) do
    room_monitor = Process.monitor(room_server)

    try do
      :ok = RoomServer.mark_empty(room_server, idle_timeout: 0)
    catch
      :exit, _room_already_stopped -> :ok
    end

    receive do
      {:DOWN, ^room_monitor, :process, ^room_server, reason}
      when reason in [:normal, :shutdown, :noproc] ->
        :ok

      {:DOWN, ^room_monitor, :process, ^room_server, reason} ->
        {:error, {:room_shutdown_failed, reason}}
    after
      @command_timeout_ms -> {:error, :room_shutdown_timeout}
    end
  end
end
