defmodule DiscordClone.Calls.AcceptedCallRuntime do
  @moduledoc false

  @callback schedule(pid(), Ecto.UUID.t()) :: :ok | {:error, term()}
end
