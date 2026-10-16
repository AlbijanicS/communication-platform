defmodule DiscordClone.Chat.ConversationServer do
  @moduledoc false

  use GenServer

  alias DiscordClone.Chat.ConversationTopics

  @inactivity_timeout_ms :timer.minutes(15)
  @typing_timeout_ms :timer.seconds(5)

  def touch(pid) when is_pid(pid), do: GenServer.call(pid, :touch)
  def list_recent_messages(pid) when is_pid(pid), do: GenServer.call(pid, :list_recent_messages)

  def put_recent_message(pid, message) when is_pid(pid),
    do: GenServer.call(pid, {:put_recent_message, message})

  def list_typing_user_ids(pid) when is_pid(pid),
    do: GenServer.call(pid, :list_typing_user_ids)

  def user_started_typing(pid, user_id) when is_pid(pid),
    do: GenServer.call(pid, {:user_started_typing, user_id})

  def user_stopped_typing(pid, user_id) when is_pid(pid),
    do: GenServer.call(pid, {:user_stopped_typing, user_id})

  def child_spec(arg) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [arg]},
      restart: :temporary
    }
  end

  @spec start_link({Ecto.UUID.t(), [term()], GenServer.name()}) :: GenServer.on_start()
  def start_link({conversation_id, recent_messages, name}) do
    GenServer.start_link(__MODULE__, {conversation_id, recent_messages}, name: name)
  end

  @impl true
  def init({conversation_id, recent_messages}) do
    # Reactions and access policy are durable context-owned state. The runtime
    # is deliberately kind-agnostic and owns only its hot cache and typing.
    {:ok,
     %{
       conversation_id: conversation_id,
       recent_messages: recent_messages,
       typing_users: %{},
       last_activity_at: now_ms()
     }
     |> schedule_idle_timeout()}
  end

  @impl true
  def handle_call(:touch, _from, state) do
    {:reply, :ok, refresh_activity(state)}
  end

  def handle_call(:list_recent_messages, _from, state) do
    {:reply, {:ok, state.recent_messages}, refresh_activity(state)}
  end

  def handle_call({:put_recent_message, message}, _from, state) do
    recent_messages =
      state.recent_messages
      |> Enum.reject(&(&1.id == message.id))
      |> Kernel.++([message])
      |> Enum.take(-50)

    state =
      state
      |> Map.put(:recent_messages, recent_messages)
      |> refresh_activity()

    {:reply, :ok, state}
  end

  def handle_call(:list_typing_user_ids, _from, state) do
    typing_user_ids = state.typing_users |> Map.keys() |> Enum.sort()

    {:reply, {:ok, typing_user_ids}, refresh_activity(state)}
  end

  def handle_call({:user_started_typing, user_id}, _from, state) do
    already_typing? = Map.has_key?(state.typing_users, user_id)
    typing_deadline = typing_deadline_ms(state, user_id)

    state =
      state
      |> put_in([:typing_users, user_id], typing_deadline)
      |> refresh_activity()

    schedule_typing_expiry(user_id, typing_deadline)

    unless already_typing? do
      broadcast_typing(
        state,
        {:typing_started, %{conversation_id: state.conversation_id, user_id: user_id}}
      )
    end

    {:reply, :ok, state}
  end

  def handle_call({:user_stopped_typing, user_id}, _from, state) do
    was_typing? = Map.has_key?(state.typing_users, user_id)

    state =
      state
      |> update_in([:typing_users], &Map.delete(&1, user_id))
      |> refresh_activity()

    if was_typing? do
      broadcast_typing(
        state,
        {:typing_stopped, %{conversation_id: state.conversation_id, user_id: user_id}}
      )
    end

    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:idle_timeout, idle_timer_ref}, %{idle_timer_ref: idle_timer_ref} = state) do
    {:stop, :normal, state}
  end

  def handle_info({:idle_timeout, _stale_timer_ref}, state), do: {:noreply, state}

  def handle_info({:typing_expired, user_id, deadline}, state) do
    case Map.fetch(state.typing_users, user_id) do
      {:ok, ^deadline} ->
        state =
          state
          |> update_in([:typing_users], &Map.delete(&1, user_id))
          |> refresh_activity()

        broadcast_typing(
          state,
          {:typing_stopped, %{conversation_id: state.conversation_id, user_id: user_id}}
        )

        {:noreply, state}

      _stale_or_missing ->
        {:noreply, state}
    end
  end

  defp broadcast_typing(state, event) do
    Phoenix.PubSub.broadcast(
      DiscordClone.PubSub,
      ConversationTopics.messages(state.conversation_id),
      event
    )
  end

  defp refresh_activity(state) do
    state
    |> Map.put(:last_activity_at, now_ms())
    |> schedule_idle_timeout()
  end

  defp schedule_idle_timeout(state) do
    if timer_ref = Map.get(state, :idle_timer) do
      Process.cancel_timer(timer_ref)
    end

    idle_timer_ref = make_ref()

    idle_timer =
      Process.send_after(self(), {:idle_timeout, idle_timer_ref}, inactivity_timeout_ms())

    state
    |> Map.put(:idle_timer_ref, idle_timer_ref)
    |> Map.put(:idle_timer, idle_timer)
  end

  defp inactivity_timeout_ms do
    Application.get_env(
      :discord_clone,
      :conversation_runtime_inactivity_timeout_ms,
      @inactivity_timeout_ms
    )
  end

  defp schedule_typing_expiry(user_id, deadline) do
    Process.send_after(
      self(),
      {:typing_expired, user_id, deadline},
      max(deadline - now_ms(), 0)
    )
  end

  defp typing_deadline_ms(state, user_id) do
    now = now_ms()
    deadline = now + typing_timeout_ms()

    state.typing_users
    |> Map.get(user_id, deadline)
    |> Kernel.+(1)
    |> max(deadline)
  end

  defp typing_timeout_ms do
    Application.get_env(
      :discord_clone,
      :conversation_runtime_typing_timeout_ms,
      @typing_timeout_ms
    )
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
