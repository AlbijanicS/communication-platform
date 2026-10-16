defmodule DiscordClone.Activities.Topics do
  @moduledoc false

  def subscribe(user_id) do
    Phoenix.PubSub.subscribe(DiscordClone.PubSub, topic(user_id))
  end

  def broadcast_change(user_id, payload) do
    Phoenix.PubSub.broadcast(
      DiscordClone.PubSub,
      topic(user_id),
      {:activity_changed, payload}
    )
  end

  defp topic(user_id), do: "chat:user:#{user_id}:activity"
end
