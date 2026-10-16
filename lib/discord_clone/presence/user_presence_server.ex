defmodule DiscordClone.Presence.UserPresenceServer do
  @moduledoc """
  Tracks the authenticated LiveView connections for one User.

  Durable Friendship authorization and PubSub fan-out remain in the Presence
  boundary; this process owns only ephemeral connection monitoring.
  """

  use GenServer, restart: :temporary

  alias DiscordClone.Friendships

  @type transition :: :online | :offline

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    user_id = Keyword.fetch!(opts, :user_id)
    registry = Keyword.fetch!(opts, :registry)
    GenServer.start_link(__MODULE__, opts, name: {:via, Registry, {registry, user_id}})
  end

  @spec join(GenServer.server(), pid()) :: :ok
  def join(server, connection_pid) when is_pid(connection_pid) do
    join(server, connection_pid, [])
  end

  @spec join(GenServer.server(), pid(), [Ecto.UUID.t()]) :: :ok
  def join(server, connection_pid, friend_user_ids) when is_pid(connection_pid) do
    GenServer.call(server, {:join, connection_pid, friend_user_ids})
  end

  @spec online?(GenServer.server()) :: boolean()
  def online?(server), do: GenServer.call(server, :online?)

  @impl true
  def init(opts) do
    if scope = Keyword.get(opts, :scope), do: :ok = Friendships.subscribe(scope)

    state = %{
      user_id: Keyword.fetch!(opts, :user_id),
      transition: Keyword.fetch!(opts, :transition),
      connections: initial_connections(opts),
      friend_user_ids: MapSet.new(Keyword.get(opts, :friend_user_ids, []))
    }

    if state.connections != %{}, do: transition(state, :online)
    {:ok, state}
  end

  @impl true
  def handle_call({:join, connection_pid, friend_user_ids}, _from, state) do
    state = Map.put(state, :friend_user_ids, MapSet.new(friend_user_ids))

    if Map.has_key?(state.connections, connection_pid) do
      {:reply, :ok, state}
    else
      if state.connections == %{}, do: transition(state, :online)

      connections = Map.put(state.connections, connection_pid, Process.monitor(connection_pid))
      {:reply, :ok, %{state | connections: connections}}
    end
  end

  def handle_call(:online?, _from, state), do: {:reply, state.connections != %{}, state}

  @impl true
  def handle_info({:DOWN, ref, :process, connection_pid, _reason}, state) do
    case Map.fetch(state.connections, connection_pid) do
      {:ok, ^ref} ->
        connections = Map.delete(state.connections, connection_pid)

        if connections == %{} do
          transition(state, :offline)
          {:stop, :normal, %{state | connections: connections}}
        else
          {:noreply, %{state | connections: connections}}
        end

      _missing_or_stale ->
        {:noreply, state}
    end
  end

  def handle_info(
        {:friendships_changed, %{action: action, friend_user_id: friend_user_id}},
        state
      ) do
    friend_user_ids = Map.get(state, :friend_user_ids, MapSet.new())

    friend_user_ids =
      case action do
        :accepted -> MapSet.put(friend_user_ids, friend_user_id)
        :removed -> MapSet.delete(friend_user_ids, friend_user_id)
        _other -> friend_user_ids
      end

    {:noreply, Map.put(state, :friend_user_ids, friend_user_ids)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp transition(state, presence_state) do
    friend_user_ids = Map.get(state, :friend_user_ids, MapSet.new()) |> MapSet.to_list()

    case Function.info(state.transition, :arity) do
      {:arity, 2} -> state.transition.(presence_state, friend_user_ids)
      {:arity, 1} -> state.transition.(presence_state)
    end
  end

  defp initial_connections(opts) do
    case Keyword.get(opts, :initial_connection) do
      connection_pid when is_pid(connection_pid) ->
        %{connection_pid => Process.monitor(connection_pid)}

      _missing ->
        %{}
    end
  end
end
