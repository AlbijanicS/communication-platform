defmodule DiscordClone.Calls.FakeAcceptedCallRuntime do
  @moduledoc false

  @behaviour DiscordClone.Calls.AcceptedCallRuntime

  @impl true
  def schedule(server, call_id) when is_pid(server) and is_binary(call_id) do
    send(server, {:accepted_call_runtime, call_id, :ready})
    :ok
  end
end
