defmodule DiscordClone.Chat.Runtime do
  @moduledoc false

  import Ecto.Query

  alias DiscordClone.Chat.{
    ConversationRegistry,
    ConversationServer,
    ConversationSupervisor,
    Conversation,
    Message,
    PresenceEvents,
    WorkspaceRegistry,
    WorkspaceServer,
    WorkspaceSupervisor
  }

  alias DiscordClone.{Repo, UUIDIdentifier}
  alias DiscordClone.Workspaces.WorkspaceModeration

  @recent_message_limit 50

  def workspace_presence_pid(workspace_id) do
    UUIDIdentifier.cast_or(workspace_id, nil, fn workspace_id ->
      case Registry.lookup(WorkspaceRegistry, workspace_id) do
        [{pid, _value}] -> if Process.alive?(pid), do: pid
        [] -> nil
      end
    end)
  end

  def ensure_workspace_presence(workspace_id) do
    UUIDIdentifier.cast_or(workspace_id, {:error, :not_found}, fn workspace_id ->
      case DynamicSupervisor.start_child(
             WorkspaceSupervisor,
             {WorkspaceServer, {workspace_id, workspace_via_tuple(workspace_id)}}
           ) do
        {:ok, pid} -> {:ok, pid}
        {:error, {:already_started, pid}} -> {:ok, pid}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  def online_user_ids(workspace_id) do
    case workspace_presence_pid(workspace_id) do
      nil -> []
      pid -> WorkspaceServer.online_user_ids(pid)
    end
  end

  def subscribe_workspace_presence(workspace_id) do
    UUIDIdentifier.cast_or(workspace_id, {:error, :not_found}, fn workspace_id ->
      Phoenix.PubSub.subscribe(DiscordClone.PubSub, workspace_presence_topic(workspace_id))
    end)
  end

  def join_workspace_presence(workspace_id, user_id, live_view_pid) when is_pid(live_view_pid) do
    with {:ok, user_id} <- UUIDIdentifier.cast(user_id),
         {:ok, workspace_pid} <- ensure_workspace_presence(workspace_id),
         :ok <- WorkspaceServer.join(workspace_pid, user_id, live_view_pid) do
      schedule_existing_timeout_expiries(workspace_id)
    else
      :error -> {:error, :not_found}
      error -> error
    end
  end

  def stop_workspace_presence(workspace_id) do
    case workspace_presence_pid(workspace_id) do
      nil -> :ok
      pid -> DynamicSupervisor.terminate_child(WorkspaceSupervisor, pid)
    end
  end

  def broadcast_user_joined(workspace_id, user_id) do
    broadcast_workspace_presence(
      workspace_id,
      PresenceEvents.user_joined_event(workspace_id, user_id)
    )
  end

  def broadcast_user_left(workspace_id, user_id) do
    broadcast_workspace_presence(
      workspace_id,
      PresenceEvents.user_left_event(workspace_id, user_id)
    )
  end

  def schedule_timeout_expiry(%WorkspaceModeration{workspace_id: workspace_id} = moderation) do
    case workspace_presence_pid(workspace_id) do
      pid when is_pid(pid) -> WorkspaceServer.schedule_timeout_expiry(pid, moderation)
      nil -> :ok
    end
  end

  def cancel_timeout_expiry(%WorkspaceModeration{workspace_id: workspace_id, id: moderation_id}) do
    case workspace_presence_pid(workspace_id) do
      pid when is_pid(pid) -> WorkspaceServer.cancel_timeout_expiry(pid, moderation_id)
      nil -> :ok
    end
  end

  def schedule_existing_timeout_expiries(workspace_id) do
    workspace_id
    |> DiscordClone.Workspaces.list_active_future_timeouts()
    |> Enum.each(&schedule_timeout_expiry/1)

    :ok
  end

  def conversation_pid(conversation_id) do
    UUIDIdentifier.cast_or(conversation_id, nil, fn conversation_id ->
      case Registry.lookup(ConversationRegistry, conversation_id) do
        [{pid, _value}] -> if Process.alive?(pid), do: pid
        [] -> nil
      end
    end)
  end

  def ensure_conversation(conversation_id) do
    UUIDIdentifier.cast_or(conversation_id, {:error, :not_found}, fn conversation_id ->
      do_ensure_conversation(conversation_id)
    end)
  end

  defp do_ensure_conversation(conversation_id) do
    case conversation_pid(conversation_id) do
      pid when is_pid(pid) ->
        :ok = ConversationServer.touch(pid)
        {:ok, pid}

      nil ->
        if Repo.exists?(
             from conversation in Conversation, where: conversation.id == ^conversation_id
           ) do
          recent_messages = load_recent_messages(conversation_id)

          case DynamicSupervisor.start_child(
                 ConversationSupervisor,
                 {ConversationServer,
                  {conversation_id, recent_messages, conversation_via_tuple(conversation_id)}}
               ) do
            {:ok, pid} -> {:ok, pid}
            {:error, {:already_started, pid}} -> {:ok, pid}
            {:error, reason} -> {:error, reason}
          end
        else
          {:error, :not_found}
        end
    end
  end

  def list_recent_messages(conversation_id) do
    with {:ok, pid} <- ensure_conversation(conversation_id) do
      ConversationServer.list_recent_messages(pid)
    end
  end

  def put_recent_message(%Message{} = message) do
    with {:ok, pid} <- ensure_conversation(message.channel_id) do
      ConversationServer.put_recent_message(pid, message)
    end
  end

  def list_typing_user_ids(conversation_id) do
    with {:ok, pid} <- ensure_conversation(conversation_id) do
      ConversationServer.list_typing_user_ids(pid)
    end
  end

  def user_started_typing(conversation_id, user_id) do
    with {:ok, pid} <- ensure_conversation(conversation_id) do
      ConversationServer.user_started_typing(pid, user_id)
    end
  end

  def user_stopped_typing(conversation_id, user_id) do
    with {:ok, pid} <- ensure_conversation(conversation_id) do
      ConversationServer.user_stopped_typing(pid, user_id)
    end
  end

  def user_stopped_typing_if_running(conversation_id, user_id) do
    case conversation_pid(conversation_id) do
      pid when is_pid(pid) -> ConversationServer.user_stopped_typing(pid, user_id)
      nil -> :ok
    end
  end

  defp broadcast_workspace_presence(workspace_id, event) do
    Phoenix.PubSub.broadcast(DiscordClone.PubSub, workspace_presence_topic(workspace_id), event)
  end

  defp load_recent_messages(conversation_id) do
    Message
    |> where([message], message.channel_id == ^conversation_id)
    |> order_by([message], desc: message.seq)
    |> limit(^@recent_message_limit)
    |> preload(^Message.display_preloads())
    |> Repo.all()
    |> Enum.reverse()
  end

  defp workspace_via_tuple(workspace_id) do
    {:via, Registry, {WorkspaceRegistry, workspace_id}}
  end

  defp conversation_via_tuple(conversation_id) do
    {:via, Registry, {ConversationRegistry, conversation_id}}
  end

  defp workspace_presence_topic(workspace_id), do: "chat:workspace_presence:#{workspace_id}"
end
