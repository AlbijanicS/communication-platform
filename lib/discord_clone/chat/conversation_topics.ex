defmodule DiscordClone.Chat.ConversationTopics do
  @moduledoc false

  def messages(conversation_id), do: "chat:conversation:#{conversation_id}"
  def reactions(conversation_id), do: "chat:conversation:#{conversation_id}:reactions"

  def read_state(user_id, conversation_id),
    do: "chat:user:#{user_id}:conversation:#{conversation_id}:read_state"

  def direct_navigation(user_id), do: "chat:user:#{user_id}:direct_navigation"

  def broadcast_direct_navigation_change(user_id, payload) do
    Phoenix.PubSub.broadcast(
      DiscordClone.PubSub,
      direct_navigation(user_id),
      {:direct_navigation_changed, payload}
    )
  end
end
