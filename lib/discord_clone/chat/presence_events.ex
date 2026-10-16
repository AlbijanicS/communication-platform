defmodule DiscordClone.Chat.PresenceEvents do
  @moduledoc """
  Pure workspace presence event translation.

  The runtime owns broadcasting these tuples; LiveViews use this module to
  translate raw PubSub messages into presence updates they can apply.
  """

  def user_joined_event(workspace_id, user_id) do
    {:workspace_user_joined, payload(workspace_id, user_id)}
  end

  def user_left_event(workspace_id, user_id) do
    {:workspace_user_left, payload(workspace_id, user_id)}
  end

  def to_presence_event({:workspace_user_joined, payload}) do
    {:ok, :user_joined, payload}
  end

  def to_presence_event({:workspace_user_left, payload}) do
    {:ok, :user_left, payload}
  end

  def to_presence_event(_event), do: :error

  defp payload(workspace_id, user_id) do
    %{workspace_id: workspace_id, user_id: user_id}
  end
end
