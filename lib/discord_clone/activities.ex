defmodule DiscordClone.Activities do
  @moduledoc """
  Owns private delivery of committed Activity Feed changes.
  """

  alias DiscordClone.Accounts.{Scope, User}
  alias DiscordClone.Activities.Topics

  @doc "Subscribes the scoped User to their private Activity change facts."
  @spec subscribe(term()) :: :ok | {:error, :unauthenticated}
  def subscribe(%Scope{user: %User{id: user_id}}) do
    Topics.subscribe(user_id)
  end

  def subscribe(_scope), do: {:error, :unauthenticated}
end
