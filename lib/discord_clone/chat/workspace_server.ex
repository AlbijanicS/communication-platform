defmodule DiscordClone.Chat.WorkspaceServer do
  @moduledoc false

  use GenServer

  alias DiscordClone.Chat.Runtime
  alias DiscordClone.Workspaces.WorkspaceModeration

  # Live navigation replaces the monitored process and may include a network
  # round trip plus database-backed mounting. Keep presence through that handoff,
  # while still expiring a genuinely disconnected user within a bounded window.
  @disconnect_grace_ms 5_000

  def start_link({workspace_id, name}) do
    GenServer.start_link(__MODULE__, workspace_id, name: name)
  end

  def join(server, user_id, live_view_pid) when is_pid(live_view_pid) do
    GenServer.call(server, {:join, user_id, live_view_pid})
  end

  def online_user_ids(server) do
    GenServer.call(server, :online_user_ids)
  end

  def schedule_timeout_expiry(server, %WorkspaceModeration{} = moderation) do
    GenServer.call(server, {:schedule_timeout_expiry, moderation})
  end

  def cancel_timeout_expiry(server, moderation_id) do
    GenServer.call(server, {:cancel_timeout_expiry, moderation_id})
  end

  @impl true
  def init(workspace_id) do
    state = %{
      workspace_id: workspace_id,
      users: %{},
      monitors: %{},
      pending_left_timers: %{},
      timeout_timers: %{}
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:join, user_id, live_view_pid}, _from, state) do
    user_was_online? = user_online?(state, user_id)

    state =
      if tracked_pid?(state, user_id, live_view_pid) do
        state
      else
        state = cancel_pending_left(state, user_id)
        monitor_ref = Process.monitor(live_view_pid)

        users =
          Map.update(
            state.users,
            user_id,
            MapSet.new([live_view_pid]),
            &MapSet.put(&1, live_view_pid)
          )

        monitors = Map.put(state.monitors, monitor_ref, {user_id, live_view_pid})

        %{state | users: users, monitors: monitors}
      end

    if !user_was_online? and Map.has_key?(state.users, user_id) do
      :ok = Runtime.broadcast_user_joined(state.workspace_id, user_id)
    end

    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:online_user_ids, _from, state) do
    online_user_ids =
      state.users
      |> Map.keys()
      |> Enum.concat(Map.keys(state.pending_left_timers))
      |> Enum.uniq()
      |> Enum.sort()

    {:reply, online_user_ids, state}
  end

  def handle_call({:schedule_timeout_expiry, %WorkspaceModeration{} = moderation}, _from, state) do
    {:reply, :ok, put_timeout_expiry_timer(state, moderation)}
  end

  def handle_call({:cancel_timeout_expiry, moderation_id}, _from, state) do
    {:reply, :ok, drop_timeout_expiry_timer(state, moderation_id)}
  end

  @impl true
  def handle_info({:DOWN, monitor_ref, :process, _pid, _reason}, state) do
    case Map.pop(state.monitors, monitor_ref) do
      {{user_id, live_view_pid}, monitors} ->
        users = remove_user_pid(state.users, user_id, live_view_pid)
        state = %{state | users: users, monitors: monitors}

        if Map.has_key?(state.users, user_id) do
          {:noreply, state}
        else
          state = schedule_pending_left(state, user_id)
          {:noreply, state}
        end

      {nil, _monitors} ->
        {:noreply, state}
    end
  end

  def handle_info({:broadcast_user_left, user_id, token}, state) do
    case Map.get(state.pending_left_timers, user_id) do
      {_timer_ref, ^token} ->
        state = %{state | pending_left_timers: Map.delete(state.pending_left_timers, user_id)}

        if Map.has_key?(state.users, user_id) do
          {:noreply, state}
        else
          :ok = Runtime.broadcast_user_left(state.workspace_id, user_id)
          {:noreply, state}
        end

      _other_timer ->
        {:noreply, state}
    end
  end

  def handle_info({:expire_member_timeout, moderation_id, token}, state) do
    case Map.get(state.timeout_timers, moderation_id) do
      {_timer_ref, ^token} ->
        _result = DiscordClone.Workspaces.expire_member_timeout(moderation_id)
        {:noreply, %{state | timeout_timers: Map.delete(state.timeout_timers, moderation_id)}}

      _other_timer ->
        {:noreply, state}
    end
  end

  defp tracked_pid?(state, user_id, live_view_pid) do
    state.users
    |> Map.get(user_id, MapSet.new())
    |> MapSet.member?(live_view_pid)
  end

  defp user_online?(state, user_id) do
    Map.has_key?(state.users, user_id) or Map.has_key?(state.pending_left_timers, user_id)
  end

  defp schedule_pending_left(state, user_id) do
    state = cancel_pending_left(state, user_id)
    token = make_ref()

    timer_ref =
      Process.send_after(self(), {:broadcast_user_left, user_id, token}, @disconnect_grace_ms)

    %{
      state
      | pending_left_timers: Map.put(state.pending_left_timers, user_id, {timer_ref, token})
    }
  end

  defp cancel_pending_left(state, user_id) do
    case Map.pop(state.pending_left_timers, user_id) do
      {nil, _pending_left_timers} ->
        state

      {{timer_ref, _token}, pending_left_timers} ->
        Process.cancel_timer(timer_ref)
        %{state | pending_left_timers: pending_left_timers}
    end
  end

  defp put_timeout_expiry_timer(state, %WorkspaceModeration{id: moderation_id} = moderation) do
    state = drop_timeout_expiry_timer(state, moderation_id)
    token = make_ref()

    timer_ref =
      Process.send_after(
        self(),
        {:expire_member_timeout, moderation_id, token},
        timeout_delay_ms(moderation)
      )

    %{
      state
      | timeout_timers: Map.put(state.timeout_timers, moderation_id, {timer_ref, token})
    }
  end

  defp drop_timeout_expiry_timer(state, moderation_id) do
    case Map.pop(state.timeout_timers, moderation_id) do
      {nil, _timeout_timers} ->
        state

      {{timer_ref, _token}, timeout_timers} ->
        Process.cancel_timer(timer_ref)
        %{state | timeout_timers: timeout_timers}
    end
  end

  defp timeout_delay_ms(%WorkspaceModeration{expires_at: %DateTime{} = expires_at}) do
    max(DateTime.diff(expires_at, DateTime.utc_now(:millisecond), :millisecond), 0)
  end

  defp remove_user_pid(users, user_id, live_view_pid) do
    case Map.fetch(users, user_id) do
      {:ok, pids} ->
        pids = MapSet.delete(pids, live_view_pid)

        if MapSet.size(pids) == 0 do
          Map.delete(users, user_id)
        else
          Map.put(users, user_id, pids)
        end

      :error ->
        users
    end
  end
end
