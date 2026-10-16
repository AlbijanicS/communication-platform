defmodule DiscordClone.Media.DirectCallTargetServer do
  @moduledoc false

  use GenServer

  alias DiscordClone.Media.{AdmissionCoordinator, DirectCallSession, Target}
  alias DiscordClone.Voice.Forwarder

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    target = Target.direct_call(Keyword.fetch!(opts, :call_id))
    generation = Keyword.fetch!(opts, :generation)
    {:ok, _} = Target.register_runtime(target, generation, :room)

    state = %{
      call_id: Keyword.fetch!(opts, :call_id),
      generation: Keyword.fetch!(opts, :generation),
      profile: Keyword.fetch!(opts, :profile),
      target: Keyword.fetch!(opts, :target),
      session_supervisor: GenServer.whereis(Target.runtime_name(target, generation, :sessions)),
      forwarder: GenServer.whereis(Target.runtime_name(target, generation, :forwarder)),
      sessions: %{},
      monitors: %{},
      transport:
        if(DiscordClone.Media.DirectCallTarget.real_transport?(), do: :real, else: :fake),
      closing?: false
    }

    {:ok, state, {:continue, :ready}}
  end

  @impl true
  def handle_continue(:ready, state) do
    case AdmissionCoordinator.call_target_ready(
           state.call_id,
           state.generation,
           state.target,
           state.profile,
           state.transport
         ) do
      :ok -> {:noreply, state}
      {:error, :stale_runtime} -> {:stop, :normal, state}
    end
  end

  @impl true
  def handle_call(:identity, _from, state) do
    {:reply,
     {:ok,
      %{
        call_id: state.call_id,
        runtime_generation: state.generation,
        profile: state.profile
      }}, state}
  end

  def handle_call({:admit, _user_id}, _from, %{closing?: true} = state),
    do: {:reply, {:error, :unavailable}, state}

  def handle_call({:admit, user_id}, _from, state) do
    cond do
      Enum.any?(state.sessions, fn {_id, session} -> session.user_id == user_id end) ->
        {:reply, {:error, :already_admitted}, state}

      map_size(state.sessions) >= state.profile.capacity ->
        {:reply, {:error, :full}, state}

      true ->
        admit_session(state, user_id)
    end
  end

  def handle_call({:session, user_id, id}, _from, state) do
    result =
      case Map.get(state.sessions, id) do
        %{user_id: ^user_id, pid: pid} -> {:ok, pid}
        _ -> {:error, :invalid_session}
      end

    {:reply, result, state}
  end

  def handle_call({:remove, user_id, call_session_id}, _from, state) do
    case Map.get(state.sessions, call_session_id) do
      %{user_id: ^user_id} -> {:reply, :ok, remove_session(state, call_session_id)}
      _ -> {:reply, {:error, :invalid_session}, state}
    end
  end

  def handle_call(:shutdown, _from, state) do
    state = %{state | closing?: true}
    state = Enum.reduce(Map.keys(state.sessions), state, &remove_session(&2, &1))
    :ok = AdmissionCoordinator.call_target_stopped(state.call_id, state.generation)
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:connection_state, id, pid, status}, state) do
    case Map.get(state.sessions, id) do
      %{pid: ^pid} = session when not state.closing? ->
        state = put_in(state.sessions[id], Map.put(session, :connection_state, status))
        publish_readiness(state)
        {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  def handle_cast(:publish_readiness, state) do
    publish_readiness(state)
    {:noreply, state}
  end

  defp publish_readiness(state) do
    if state.transport == :real and not state.closing? do
      statuses = Map.new(state.sessions, fn {id, session} -> {id, session.connection_state} end)
      AdmissionCoordinator.call_transport_state(state.call_id, state.generation, statuses)
    end
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, _pid, reason}, state) do
    case Map.pop(state.monitors, monitor) do
      {nil, _} ->
        {:noreply, state}

      {call_session_id, monitors} ->
        session = Map.fetch!(state.sessions, call_session_id)
        :ok = Forwarder.session_removed(state.forwarder, call_session_id, session.pid)

        :ok =
          AdmissionCoordinator.call_session_failed(
            state.call_id,
            state.generation,
            session.user_id,
            call_session_id,
            reason
          )

        {:noreply,
         %{state | monitors: monitors, sessions: Map.delete(state.sessions, call_session_id)}}
    end
  end

  defp admit_session(state, user_id) do
    call_session_id = Ecto.UUID.generate()

    case DynamicSupervisor.start_child(
           state.session_supervisor,
           {DirectCallSession,
            call_id: state.call_id,
            user_id: user_id,
            call_session_id: call_session_id,
            forwarder: state.forwarder,
            room_server: self(),
            transport: state.transport,
            runtime_generation: state.generation}
         ) do
      {:ok, session_pid} ->
        monitor = Process.monitor(session_pid)
        session = %{user_id: user_id, pid: session_pid, monitor: monitor, connection_state: :new}

        :ok =
          AdmissionCoordinator.call_session_started(
            state.call_id,
            state.generation,
            user_id,
            call_session_id,
            DirectCallSession.resources(session_pid)
          )

        :ok =
          DiscordClone.Media.DirectCallTarget.startup_control(
            :session_started,
            %{user_id: user_id, session: session_pid, call_session_id: call_session_id}
          )

        state = %{
          state
          | sessions: Map.put(state.sessions, call_session_id, session),
            monitors: Map.put(state.monitors, monitor, call_session_id)
        }

        {:reply, {:ok, %{call_session_id: call_session_id}}, state}

      {:error, reason} ->
        :ok = AdmissionCoordinator.call_target_failed(state.call_id, state.generation, reason)
        {:reply, {:error, :unavailable}, state}
    end
  end

  defp remove_session(state, call_session_id) do
    {session, sessions} = Map.pop!(state.sessions, call_session_id)
    :ok = Forwarder.session_removed(state.forwarder, call_session_id, session.pid)
    Process.demonitor(session.monitor, [:flush])
    _ = DynamicSupervisor.terminate_child(state.session_supervisor, session.pid)

    :ok =
      AdmissionCoordinator.call_session_removed(
        state.call_id,
        state.generation,
        session.user_id,
        call_session_id
      )

    %{
      state
      | sessions: sessions,
        monitors: Map.delete(state.monitors, session.monitor)
    }
  end
end
