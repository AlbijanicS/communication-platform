defmodule DiscordClone.Voice.RoomServer do
  @moduledoc false

  use GenServer

  @idle_timeout_ms :timer.seconds(30)
  @voice_session_lease_timeout_ms :timer.seconds(120)
  @peer_connection_recovery_timeout_ms :timer.seconds(30)
  @speaking_decay_ms 600

  alias DiscordClone.Media.{AdmissionCoordinator, Target}

  alias DiscordClone.Voice.{
    Forwarder,
    RoomRegistry,
    Session,
    ServerICEProjection
  }

  alias DiscordClone.Voice

  @capacity 5
  @test_environment Code.ensure_loaded?(Mix) and Mix.env() == :test

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    voice_channel_id = Keyword.fetch!(opts, :voice_channel_id)

    GenServer.start_link(__MODULE__, opts,
      name: {:via, Registry, {RoomRegistry, {:room, voice_channel_id}}}
    )
  end

  @spec mark_in_use(GenServer.server()) :: :ok
  def mark_in_use(server), do: GenServer.call(server, :mark_in_use)

  @doc false
  @spec shutdown(GenServer.server()) :: :ok
  def shutdown(server), do: GenServer.cast(server, :shutdown_runtime)

  @spec mark_empty(GenServer.server(), keyword()) :: :ok
  def mark_empty(server, opts \\ []), do: GenServer.call(server, {:mark_empty, opts})

  @spec join(GenServer.server(), Ecto.UUID.t(), binary(), pid()) ::
          {:ok, map()} | {:error, map() | :unavailable}
  def join(server, user_id, signaling_session_id, signaling_channel) do
    join(
      server,
      user_id,
      signaling_session_id,
      signaling_channel,
      ServerICEProjection.disabled()
    )
  end

  @spec join(GenServer.server(), Ecto.UUID.t(), binary(), pid(), ServerICEProjection.t()) ::
          {:ok, map()} | {:error, map() | :unavailable}
  def join(server, user_id, signaling_session_id, signaling_channel, server_ice_projection) do
    GenServer.call(
      server,
      {:join, user_id, signaling_session_id, signaling_channel, server_ice_projection}
    )
  end

  @spec leave(GenServer.server(), Ecto.UUID.t()) :: :ok
  def leave(server, voice_session_id), do: GenServer.call(server, {:leave, voice_session_id})

  @spec renew_session(GenServer.server(), Ecto.UUID.t(), Ecto.UUID.t(), binary()) ::
          :ok | {:error, :invalid_session}
  def renew_session(server, user_id, voice_session_id, signaling_session_id) do
    GenServer.call(server, {:renew_session, user_id, voice_session_id, signaling_session_id})
  end

  @spec update_local_voice_state(
          GenServer.server(),
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          boolean(),
          boolean()
        ) :: :ok | {:error, :invalid_session}
  def update_local_voice_state(server, user_id, voice_session_id, muted, deafened) do
    GenServer.call(
      server,
      {:update_local_voice_state, user_id, voice_session_id, muted, deafened}
    )
  end

  @spec set_workspace_muted(GenServer.server(), Ecto.UUID.t(), boolean()) :: :ok
  def set_workspace_muted(server, user_id, muted) when is_boolean(muted) do
    GenServer.call(server, {:set_workspace_muted, user_id, muted})
  end

  @spec accept_offer(
          GenServer.server(),
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          binary(),
          map(),
          integer()
        ) ::
          {:ok, map()} | {:error, atom()}
  def accept_offer(
        server,
        user_id,
        voice_session_id,
        negotiation_id,
        description,
        deadline
      ) do
    GenServer.call(
      server,
      {:accept_offer, user_id, voice_session_id, negotiation_id, description, deadline},
      remaining_timeout(deadline)
    )
  end

  @spec add_ice_candidate(
          GenServer.server(),
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          binary(),
          map(),
          integer()
        ) ::
          {:ok, map()} | {:error, atom()}
  def add_ice_candidate(
        server,
        user_id,
        voice_session_id,
        negotiation_id,
        candidate,
        deadline
      ) do
    GenServer.call(
      server,
      {:add_ice_candidate, user_id, voice_session_id, negotiation_id, candidate, deadline},
      remaining_timeout(deadline)
    )
  end

  @spec end_of_candidates(
          GenServer.server(),
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          binary(),
          integer()
        ) ::
          {:error, atom()}
  def end_of_candidates(server, user_id, voice_session_id, negotiation_id, deadline) do
    GenServer.call(
      server,
      {:end_of_candidates, user_id, voice_session_id, negotiation_id, deadline},
      remaining_timeout(deadline)
    )
  end

  @spec occupancy(GenServer.server()) ::
          {:ok, %{occupancy: non_neg_integer(), capacity: pos_integer()}}
  def occupancy(server), do: GenServer.call(server, :occupancy)

  @spec roster(GenServer.server()) ::
          %{voice_channel_id: Ecto.UUID.t(), members: [%{user_id: Ecto.UUID.t()}]}
  def roster(server), do: GenServer.call(server, :roster)

  @spec await_empty(GenServer.server()) :: :ok
  def await_empty(server), do: GenServer.call(server, :await_empty)

  @spec crash_session(GenServer.server(), Ecto.UUID.t()) :: :ok
  def crash_session(server, voice_session_id),
    do: GenServer.call(server, {:crash_session, voice_session_id})

  @doc false
  @spec dispatch_test_ex_webrtc(GenServer.server(), Ecto.UUID.t(), term()) ::
          :ok | {:error, :not_found | :unavailable}
  def dispatch_test_ex_webrtc(server, voice_session_id, message),
    do: GenServer.call(server, {:dispatch_test_ex_webrtc, voice_session_id, message})

  @doc false
  @spec sync_test_media(GenServer.server()) :: :ok | {:error, :unavailable}
  def sync_test_media(server), do: GenServer.call(server, :sync_test_media)

  @impl true
  def init(opts) do
    voice_channel_id = Keyword.fetch!(opts, :voice_channel_id)
    {:ok, _} = Target.register_runtime(Target.voice_channel(voice_channel_id), self(), :room)
    AdmissionCoordinator.room_server_started(voice_channel_id, self())

    {:ok,
     %{
       room_supervisor: Keyword.fetch!(opts, :room_supervisor),
       voice_channel_id: voice_channel_id,
       idle_timer: schedule_idle_shutdown(),
       memberships: %{},
       session_by_signaling: %{},
       session_by_monitor: %{},
       session_supervisor: nil,
       forwarder: nil,
       voice_session_lease_timeout_ms: voice_session_lease_timeout(opts),
       peer_connection_recovery_timeout_ms: peer_connection_recovery_timeout(opts),
       next_admission_order: 0,
       test_admission_observer: test_admission_observer(opts),
       test_peer_connection_opts: test_peer_connection_opts(opts),
       pending_joins: [],
       empty_waiters: []
     }}
  end

  @impl true
  def handle_call(:mark_in_use, _from, state) do
    {:reply, :ok, %{state | idle_timer: cancel_idle_shutdown(state.idle_timer)}}
  end

  def handle_call({:mark_empty, opts}, _from, state) do
    if map_size(state.memberships) == 0 do
      idle_timeout = Keyword.get(opts, :idle_timeout, @idle_timeout_ms)
      _ = cancel_idle_shutdown(state.idle_timer)

      {:reply, :ok, %{state | idle_timer: schedule_idle_shutdown(idle_timeout)}}
    else
      {:reply, :ok, state}
    end
  end

  def handle_call(
        {:join, user_id, signaling_session_id, signaling_channel, server_ice_projection},
        from,
        state
      ) do
    if session_supervisor_ready?(state) do
      join_request(
        state,
        user_id,
        signaling_session_id,
        signaling_channel,
        server_ice_projection
      )
    else
      {:noreply,
       %{
         state
         | pending_joins: [
             {from, user_id, signaling_session_id, signaling_channel, server_ice_projection}
             | state.pending_joins
           ]
       }}
    end
  end

  def handle_call({:leave, voice_session_id}, _from, state) do
    {:reply, :ok, remove_membership(state, voice_session_id)}
  end

  def handle_call({:renew_session, user_id, voice_session_id, signaling_session_id}, _from, state) do
    case Map.get(state.memberships, voice_session_id) do
      %{user_id: ^user_id, signaling_session_id: ^signaling_session_id} = membership ->
        membership = renew_lease(membership, state.voice_session_lease_timeout_ms)

        {:reply, :ok, put_in(state, [:memberships, voice_session_id], membership)}

      _missing_or_mismatched_session ->
        {:reply, {:error, :invalid_session}, state}
    end
  end

  def handle_call(
        {:update_local_voice_state, user_id, voice_session_id, muted, deafened},
        _from,
        state
      ) do
    case Map.get(state.memberships, voice_session_id) do
      %{user_id: ^user_id} = membership ->
        local_state = %{local_muted: muted or deafened, local_deafened: deafened}

        if Map.take(membership, Map.keys(local_state)) == local_state do
          {:reply, :ok, state}
        else
          state =
            put_in(state, [:memberships, voice_session_id], Map.merge(membership, local_state))

          :ok = Voice.publish_voice_channel_roster(roster_snapshot(state))
          {:reply, :ok, state}
        end

      _missing_or_mismatched_session ->
        {:reply, {:error, :invalid_session}, state}
    end
  end

  def handle_call(
        {:accept_offer, user_id, voice_session_id, negotiation_id, description, deadline},
        _from,
        state
      ) do
    route_session_command(
      state,
      user_id,
      voice_session_id,
      {:accept_offer, negotiation_id, description},
      deadline
    )
  end

  def handle_call({:set_workspace_muted, user_id, muted}, _from, state) do
    {memberships, changed?} =
      Enum.reduce(state.memberships, {%{}, false}, fn {voice_session_id, membership},
                                                      {memberships, changed?} ->
        if membership.user_id == user_id do
          :ok = Forwarder.set_source_muted(state.forwarder, voice_session_id, muted)
          membership = %{membership | workspace_muted: muted}
          {Map.put(memberships, voice_session_id, membership), true}
        else
          {Map.put(memberships, voice_session_id, membership), changed?}
        end
      end)

    state = %{state | memberships: memberships}
    if changed?, do: :ok = Voice.publish_voice_channel_roster(roster_snapshot(state))
    {:reply, :ok, state}
  end

  def handle_call(
        {:add_ice_candidate, user_id, voice_session_id, negotiation_id, candidate, deadline},
        _from,
        state
      ) do
    route_session_command(
      state,
      user_id,
      voice_session_id,
      {:add_ice_candidate, negotiation_id, candidate},
      deadline
    )
  end

  def handle_call(
        {:end_of_candidates, user_id, voice_session_id, negotiation_id, deadline},
        _from,
        state
      ) do
    route_session_command(
      state,
      user_id,
      voice_session_id,
      {:end_of_candidates, negotiation_id},
      deadline
    )
  end

  def handle_call(:occupancy, _from, state),
    do: {:reply, {:ok, membership_occupancy(state)}, state}

  def handle_call(:roster, _from, state), do: {:reply, roster_snapshot(state), state}

  def handle_call(:await_empty, from, state) do
    if map_size(state.memberships) == 0 do
      {:reply, :ok, state}
    else
      {:noreply, %{state | empty_waiters: [from | state.empty_waiters]}}
    end
  end

  def handle_call({:crash_session, voice_session_id}, _from, state) do
    case state.memberships do
      %{^voice_session_id => %{session_pid: session_pid}} -> Session.crash(session_pid)
      _missing -> :ok
    end

    session_monitor =
      case state.memberships do
        %{^voice_session_id => %{session_monitor: session_monitor}} -> session_monitor
        _missing -> nil
      end

    state = wait_for_session_crash(state, session_monitor)

    {:reply, :ok,
     remove_membership(state, voice_session_id,
       notify_ended?: false,
       terminate_session?: false
     )}
  end

  def handle_call({:dispatch_test_ex_webrtc, voice_session_id, message}, _from, state) do
    if @test_environment do
      case state.memberships do
        %{^voice_session_id => %{session_pid: session_pid}} when is_pid(session_pid) ->
          send(session_pid, message)
          {:reply, :ok, state}

        _missing_session ->
          {:reply, {:error, :not_found}, state}
      end
    else
      {:reply, {:error, :unavailable}, state}
    end
  end

  def handle_call(:sync_test_media, _from, state) do
    if @test_environment do
      Enum.each(state.memberships, fn {_voice_session_id, membership} ->
        _ = :sys.get_state(membership.session_pid)
      end)

      reply = sync_forwarder(state.forwarder)

      {:reply, reply, state}
    else
      {:reply, {:error, :unavailable}, state}
    end
  end

  @impl true
  def handle_info({:session_supervisor_started, room, session_supervisor}, state)
      when room == self() do
    {:noreply, maybe_start_pending_joins(%{state | session_supervisor: session_supervisor})}
  end

  def handle_info({:session_supervisor_started, _old_room, _supervisor}, state),
    do: {:noreply, state}

  def handle_info({:forwarder_started, room, forwarder}, state) when room == self() do
    {:noreply, maybe_start_pending_joins(%{state | forwarder: forwarder})}
  end

  def handle_info({:forwarder_started, _old_room, _forwarder}, state), do: {:noreply, state}

  def handle_info({:idle_shutdown, idle_timer}, %{idle_timer: {_timer_ref, idle_timer}} = state) do
    stop_room_supervisor(state.room_supervisor)
    {:stop, :normal, state}
  end

  def handle_info({:idle_shutdown, _stale_idle_timer}, state), do: {:noreply, state}

  def handle_info({:DOWN, session_monitor, :process, _session, _reason}, state) do
    case Map.pop(state.session_by_monitor, session_monitor) do
      {nil, _session_by_monitor} ->
        {:noreply, state}

      {voice_session_id, _session_by_monitor} ->
        {:noreply,
         remove_membership(state, voice_session_id,
           notify_ended?: false,
           terminate_session?: false
         )}
    end
  end

  def handle_info({:speaking_decay, voice_session_id, decay_ref}, state) do
    case Map.get(state.memberships, voice_session_id) do
      %{speaking: true, speaking_decay_ref: ^decay_ref} = membership ->
        membership = %{
          membership
          | speaking: false,
            speaking_decay_timer: nil,
            speaking_decay_ref: nil
        }

        state = put_in(state, [:memberships, voice_session_id], membership)
        :ok = Voice.publish_voice_channel_roster(roster_snapshot(state))
        {:noreply, state}

      _stale_decay ->
        {:noreply, state}
    end
  end

  def handle_info({:voice_session_lease_expired, voice_session_id, lease_ref}, state) do
    case Map.get(state.memberships, voice_session_id) do
      %{lease_ref: ^lease_ref} ->
        {:noreply, remove_membership(state, voice_session_id)}

      _stale_or_removed_session ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:signaling_channel_down, voice_session_id}, state) do
    {:noreply, remove_membership(state, voice_session_id, notify_ended?: false)}
  end

  def handle_cast({:accepted_inbound_rtp, voice_session_id, activity}, state) do
    {:noreply, record_speaking_activity(state, voice_session_id, activity)}
  end

  def handle_cast(:shutdown_runtime, state) do
    state = remove_all_memberships(state)
    stop_room_supervisor(state.room_supervisor)
    {:noreply, state}
  end

  defp stop_room_supervisor(supervisor) do
    # A parent traps its child's exit signals as child failures; stopping it
    # synchronously here would deadlock while it waits for this child to exit.
    Task.start(fn -> Supervisor.stop(supervisor, :shutdown) end)
  end

  defp maybe_start_pending_joins(state) do
    if runtime_components_ready?(state) do
      start_pending_joins(state)
    else
      state
    end
  end

  defp sync_forwarder(forwarder) when is_pid(forwarder) do
    Forwarder.sync(forwarder)
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  defp sync_forwarder(_missing_forwarder), do: {:error, :unavailable}

  defp start_pending_joins(state) do
    pending_joins = Enum.reverse(state.pending_joins)

    state =
      Enum.reduce(pending_joins, state, fn {from, user_id, signaling_session_id,
                                            signaling_channel, server_ice_projection},
                                           state ->
        {:reply, reply, state} =
          join_request(
            state,
            user_id,
            signaling_session_id,
            signaling_channel,
            server_ice_projection
          )

        GenServer.reply(from, reply)
        state
      end)

    %{state | pending_joins: []}
  end

  defp join_request(
         state,
         user_id,
         signaling_session_id,
         signaling_channel,
         server_ice_projection
       ) do
    case Map.fetch(state.session_by_signaling, signaling_session_id) do
      {:ok, voice_session_id} ->
        {:reply, {:ok, session_details(state.memberships[voice_session_id], state)}, state}

      :error when map_size(state.memberships) >= @capacity ->
        {:reply, {:error, room_full(state)}, state}

      :error ->
        join_new_session(
          state,
          user_id,
          signaling_session_id,
          signaling_channel,
          server_ice_projection
        )
    end
  end

  defp session_supervisor_ready?(state), do: runtime_components_ready?(state)

  defp runtime_components_ready?(state) do
    is_pid(state.session_supervisor) and Process.alive?(state.session_supervisor) and
      is_pid(state.forwarder) and Process.alive?(state.forwarder)
  end

  defp schedule_idle_shutdown(timeout \\ @idle_timeout_ms)
       when is_integer(timeout) and timeout >= 0 do
    idle_timer = make_ref()
    timer_ref = Process.send_after(self(), {:idle_shutdown, idle_timer}, timeout)
    {timer_ref, idle_timer}
  end

  defp cancel_idle_shutdown(nil), do: nil

  defp cancel_idle_shutdown({timer_ref, _idle_timer}) do
    _ = Process.cancel_timer(timer_ref)
    nil
  end

  defp join_new_session(
         state,
         user_id,
         signaling_session_id,
         signaling_channel,
         server_ice_projection
       ) do
    voice_session_id = Ecto.UUID.generate()

    with {:ok, session_pid} <-
           start_session(
             state,
             voice_session_id,
             signaling_channel,
             server_ice_projection
           ) do
      session_monitor = Process.monitor(session_pid)

      membership = %{
        voice_session_id: voice_session_id,
        user_id: user_id,
        local_muted: false,
        local_deafened: false,
        workspace_muted: false,
        speaking: false,
        speaking_decay_timer: nil,
        speaking_decay_ref: nil,
        admission_order: state.next_admission_order,
        signaling_session_id: signaling_session_id,
        signaling_channel: signaling_channel,
        session_pid: session_pid,
        session_monitor: session_monitor,
        lease_timer: nil,
        lease_ref: nil
      }

      membership = renew_lease(membership, state.voice_session_lease_timeout_ms)

      state =
        state
        |> put_in([:memberships, voice_session_id], membership)
        |> put_in([:session_by_signaling, signaling_session_id], voice_session_id)
        |> put_in([:session_by_monitor, session_monitor], voice_session_id)
        |> Map.update!(:next_admission_order, &(&1 + 1))
        |> Map.put(:idle_timer, cancel_idle_shutdown(state.idle_timer))

      notify_test_admission(state, voice_session_id)
      :ok = Voice.publish_voice_channel_roster(roster_snapshot(state))
      {:reply, {:ok, session_details(membership, state)}, state}
    else
      {:error, _reason} -> {:reply, {:error, :unavailable}, state}
    end
  end

  defp route_session_command(state, user_id, voice_session_id, command, deadline) do
    case Map.get(state.memberships, voice_session_id) do
      nil ->
        {:reply, {:error, :invalid_session}, state}

      %{user_id: ^user_id, session_pid: session_pid} ->
        if deadline_expired?(deadline) do
          {:reply, {:error, :unavailable}, remove_membership(state, voice_session_id)}
        else
          session_timeout = remaining_timeout(deadline)

          result =
            call_session(
              session_pid,
              add_command_timeout(command, deadline),
              session_timeout
            )

          if deadline_expired?(deadline) do
            {:reply, {:error, :unavailable}, remove_membership(state, voice_session_id)}
          else
            case result do
              {:ok, {:error, :negotiation_failed} = error} ->
                {:reply, error, remove_membership(state, voice_session_id)}

              {:ok, reply} ->
                {:reply, reply, state}

              {:error, :unavailable} = error ->
                {:reply, error, remove_membership(state, voice_session_id)}
            end
          end
        end

      _mismatched_user ->
        {:reply, {:error, :invalid_session}, state}
    end
  end

  defp call_session(session_pid, command, timeout) do
    {:ok, GenServer.call(session_pid, command, timeout)}
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  defp add_command_timeout({:accept_offer, negotiation_id, description}, deadline),
    do: {:accept_offer, negotiation_id, description, deadline}

  defp add_command_timeout({:add_ice_candidate, negotiation_id, candidate}, deadline),
    do: {:add_ice_candidate, negotiation_id, candidate, deadline}

  defp add_command_timeout({:end_of_candidates, negotiation_id}, deadline),
    do: {:end_of_candidates, negotiation_id, deadline}

  defp remaining_timeout(deadline) do
    max(deadline - System.monotonic_time(:millisecond), 1)
  end

  defp deadline_expired?(deadline) do
    deadline <= System.monotonic_time(:millisecond)
  end

  defp remove_membership(state, voice_session_id, opts \\ []) do
    case Map.pop(state.memberships, voice_session_id) do
      {nil, _memberships} ->
        state

      {%{
         session_pid: session_pid,
         session_monitor: session_monitor,
         signaling_session_id: signaling_session_id,
         signaling_channel: signaling_channel,
         user_id: user_id,
         speaking_decay_timer: speaking_decay_timer,
         lease_timer: lease_timer
       }, memberships} ->
        if Keyword.get(opts, :notify_ended?, true) do
          send(
            signaling_channel,
            {:voice_session_ended, voice_session_id, signaling_session_id}
          )
        end

        :ok = Forwarder.session_removed(state.forwarder, voice_session_id)

        if Keyword.get(opts, :terminate_session?, true) and Process.alive?(session_pid) do
          _ =
            DynamicSupervisor.terminate_child(
              state.session_supervisor,
              session_pid
            )
        end

        _ = Process.demonitor(session_monitor, [:flush])
        _ = cancel_speaking_decay(speaking_decay_timer)
        _ = cancel_lease_expiry(lease_timer)

        state = %{
          state
          | memberships: memberships,
            session_by_signaling: Map.delete(state.session_by_signaling, signaling_session_id),
            session_by_monitor: Map.delete(state.session_by_monitor, session_monitor)
        }

        :ok =
          AdmissionCoordinator.session_removed(
            state.voice_channel_id,
            user_id,
            voice_session_id,
            self()
          )

        :ok = Voice.publish_voice_channel_roster(roster_snapshot(state))

        if map_size(memberships) == 0 do
          state =
            if Keyword.get(opts, :schedule_idle?, true) do
              %{state | idle_timer: schedule_idle_shutdown()}
            else
              state
            end

          reply_empty_waiters(state)
        else
          state
        end
    end
  end

  defp start_session(state, voice_session_id, signaling_channel, server_ice_projection) do
    session_supervisor = state.session_supervisor

    if is_pid(GenServer.whereis(session_supervisor)) do
      try do
        DynamicSupervisor.start_child(
          session_supervisor,
          {Session,
           room_server: self(),
           forwarder: state.forwarder,
           voice_session_id: voice_session_id,
           signaling_channel: signaling_channel,
           server_ice_projection: server_ice_projection,
           peer_connection_recovery_timeout_ms: state.peer_connection_recovery_timeout_ms,
           test_peer_connection_opts: state.test_peer_connection_opts}
        )
      catch
        :exit, _session_supervisor_stopped -> {:error, :unavailable}
      end
    else
      {:error, :unavailable}
    end
  end

  defp test_peer_connection_opts(opts) do
    if @test_environment do
      Keyword.get(opts, :test_peer_connection_opts, [])
    else
      []
    end
  end

  defp voice_session_lease_timeout(opts) do
    if @test_environment do
      Keyword.get(opts, :voice_session_lease_timeout_ms, @voice_session_lease_timeout_ms)
    else
      @voice_session_lease_timeout_ms
    end
  end

  defp peer_connection_recovery_timeout(opts) do
    if @test_environment do
      Keyword.get(
        opts,
        :peer_connection_recovery_timeout_ms,
        @peer_connection_recovery_timeout_ms
      )
    else
      @peer_connection_recovery_timeout_ms
    end
  end

  defp test_admission_observer(opts) do
    if @test_environment do
      Keyword.get(opts, :test_admission_observer)
    end
  end

  defp notify_test_admission(%{test_admission_observer: observer}, voice_session_id)
       when is_pid(observer) do
    send(observer, {:voice_session_membership_committed, voice_session_id})
  end

  defp notify_test_admission(_state, _voice_session_id), do: :ok

  defp wait_for_session_crash(state, nil), do: state

  defp wait_for_session_crash(state, session_monitor) do
    receive do
      {:DOWN, ^session_monitor, :process, _session, _reason} ->
        %{state | session_by_monitor: Map.delete(state.session_by_monitor, session_monitor)}
    end
  end

  defp remove_all_memberships(state) do
    Enum.reduce(Map.keys(state.memberships), state, fn voice_session_id, state ->
      remove_membership(state, voice_session_id, schedule_idle?: false)
    end)
  end

  defp reply_empty_waiters(state) do
    Enum.each(state.empty_waiters, &GenServer.reply(&1, :ok))
    %{state | empty_waiters: []}
  end

  defp session_details(%{voice_session_id: voice_session_id}, state) do
    %{voice_session_id: voice_session_id} |> Map.merge(membership_occupancy(state))
  end

  defp membership_occupancy(state),
    do: %{occupancy: map_size(state.memberships), capacity: @capacity}

  defp roster_snapshot(state) do
    members =
      state.memberships
      |> Map.values()
      |> Enum.sort_by(& &1.admission_order)
      |> Enum.map(
        &%{
          user_id: &1.user_id,
          muted: &1.local_muted or &1.workspace_muted,
          deafened: &1.local_deafened,
          speaking: &1.speaking
        }
      )

    %{voice_channel_id: state.voice_channel_id, members: members}
  end

  defp room_full(state), do: %{reason: :room_full} |> Map.merge(membership_occupancy(state))

  defp record_speaking_activity(state, voice_session_id, activity)
       when activity in [:speaking, :fallback] do
    case Map.get(state.memberships, voice_session_id) do
      nil ->
        state

      %{speaking: was_speaking} = membership ->
        _ = cancel_speaking_decay(membership.speaking_decay_timer)
        decay_ref = make_ref()

        decay_timer =
          Process.send_after(
            self(),
            {:speaking_decay, voice_session_id, decay_ref},
            @speaking_decay_ms
          )

        membership = %{
          membership
          | speaking: true,
            speaking_decay_timer: decay_timer,
            speaking_decay_ref: decay_ref
        }

        state = put_in(state, [:memberships, voice_session_id], membership)

        if not was_speaking do
          :ok = Voice.publish_voice_channel_roster(roster_snapshot(state))
        end

        state
    end
  end

  defp record_speaking_activity(state, _voice_session_id, :silent), do: state

  defp cancel_speaking_decay(nil), do: :ok
  defp cancel_speaking_decay(timer), do: Process.cancel_timer(timer)

  defp renew_lease(membership, timeout) do
    _ = cancel_lease_expiry(membership.lease_timer)
    lease_ref = make_ref()

    lease_timer =
      Process.send_after(
        self(),
        {:voice_session_lease_expired, membership.voice_session_id, lease_ref},
        timeout
      )

    %{membership | lease_timer: lease_timer, lease_ref: lease_ref}
  end

  defp cancel_lease_expiry(nil), do: :ok
  defp cancel_lease_expiry(timer), do: Process.cancel_timer(timer)
end
