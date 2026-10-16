defmodule DiscordClone.Presence do
  @moduledoc """
  Owns ephemeral, global online/offline Friend Presence.

  Every public observation re-authorizes the scoped User's current Friendship.
  Presence transitions are fanned out only to private topics belonging to the
  online User's current Friends.
  """

  alias DiscordClone.Accounts.{Scope, User}
  alias DiscordClone.Friendships
  alias DiscordClone.Presence.UserPresenceServer

  @registry DiscordClone.Presence.Registry
  @supervisor DiscordClone.Presence.Supervisor

  @type state :: :online | :offline

  @doc "Registers one authenticated LiveView connection for the scoped User."
  @spec join(term(), pid()) :: :ok | {:error, :unauthenticated}
  def join(%Scope{user: %User{} = user} = scope, connection_pid) when is_pid(connection_pid) do
    {:ok, friend_user_ids} = Friendships.list_friend_user_ids(scope)
    join_connection(scope, user.id, connection_pid, friend_user_ids, 2)
  end

  def join(_scope, _connection_pid), do: {:error, :unauthenticated}

  @doc "Lists the scoped User's current Friends who are globally online."
  @spec list_online_friend_ids(term()) :: {:ok, [Ecto.UUID.t()]} | {:error, :unauthenticated}
  def list_online_friend_ids(%Scope{user: %User{}} = scope) do
    {:ok, friends} = Friendships.list_friends(scope)

    online_ids =
      friends
      |> Enum.map(& &1.user.id)
      |> Enum.filter(&online?/1)

    {:ok, online_ids}
  end

  def list_online_friend_ids(_scope), do: {:error, :unauthenticated}

  @doc "Returns a current Friend's global Presence without disclosing arbitrary Users."
  @spec friend_status(term(), term()) ::
          {:ok, state()} | {:error, :unauthenticated | :not_found}
  def friend_status(%Scope{user: %User{}} = scope, friend_user_id) do
    if Friendships.friends?(scope, friend_user_id) do
      state = if online?(friend_user_id), do: :online, else: :offline
      {:ok, state}
    else
      {:error, :not_found}
    end
  end

  def friend_status(_scope, _friend_user_id), do: {:error, :unauthenticated}

  @doc "Subscribes to private Presence facts after authorizing the requested Friend."
  @spec subscribe_to_friend(term(), term()) ::
          :ok | {:error, :unauthenticated | :not_found}
  def subscribe_to_friend(%Scope{user: %User{id: observer_id}} = scope, friend_user_id) do
    if Friendships.friends?(scope, friend_user_id) do
      Phoenix.PubSub.subscribe(DiscordClone.PubSub, observer_topic(observer_id))
    else
      {:error, :not_found}
    end
  end

  def subscribe_to_friend(_scope, _friend_user_id), do: {:error, :unauthenticated}

  @doc false
  @spec user_presence_pid(term()) :: pid() | nil
  def user_presence_pid(user_id) do
    case Registry.lookup(@registry, user_id) do
      [{pid, _value}] -> pid
      [] -> nil
    end
  end

  @doc false
  @spec broadcast_transition(Scope.t(), state(), [Ecto.UUID.t()]) :: :ok
  def broadcast_transition(
        %Scope{user: %User{id: user_id}} = scope,
        state,
        cached_friend_user_ids
      ) do
    friend_user_ids = currently_authorized_friend_ids(scope, cached_friend_user_ids)
    event = {:friend_presence_changed, %{user_id: user_id, state: state}}

    Enum.each(friend_user_ids, fn friend_user_id ->
      :ok =
        Phoenix.PubSub.broadcast(
          DiscordClone.PubSub,
          observer_topic(friend_user_id),
          event
        )
    end)

    :ok
  end

  defp join_connection(scope, user_id, connection_pid, friend_user_ids, attempts_left) do
    case user_presence_pid(user_id) do
      nil ->
        start_user_presence(scope, user_id, connection_pid, friend_user_ids)

      server ->
        UserPresenceServer.join(server, connection_pid, friend_user_ids)
    end
  catch
    :exit, _reason when attempts_left > 0 ->
      join_connection(scope, user_id, connection_pid, friend_user_ids, attempts_left - 1)
  end

  defp start_user_presence(scope, user_id, connection_pid, friend_user_ids) do
    child =
      {UserPresenceServer,
       user_id: user_id,
       scope: scope,
       registry: @registry,
       initial_connection: connection_pid,
       friend_user_ids: friend_user_ids,
       transition: &broadcast_transition(scope, &1, &2)}

    case DynamicSupervisor.start_child(@supervisor, child) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, pid}} ->
        UserPresenceServer.join(pid, connection_pid, friend_user_ids)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp online?(user_id) do
    case user_presence_pid(user_id) do
      nil -> false
      pid -> UserPresenceServer.online?(pid)
    end
  catch
    :exit, _server_stopped -> false
  end

  defp currently_authorized_friend_ids(scope, cached_friend_user_ids) do
    {:ok, friend_user_ids} = Friendships.list_friend_user_ids(scope)
    friend_user_ids
  rescue
    _ownership_or_connection_error in [
      DBConnection.OwnershipError,
      DBConnection.ConnectionError
    ] ->
      cached_friend_user_ids
  catch
    :exit, _sandbox_owner_terminated -> cached_friend_user_ids
  end

  defp observer_topic(user_id), do: "presence:observer:#{user_id}"
end
