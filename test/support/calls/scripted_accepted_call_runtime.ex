defmodule DiscordClone.Calls.ScriptedAcceptedCallRuntime do
  @moduledoc false

  @behaviour DiscordClone.Calls.AcceptedCallRuntime

  @impl true
  def schedule(server, call_id) when is_pid(server) and is_binary(call_id) do
    case Application.get_env(:discord_clone, :accepted_call_runtime_result, :ready) do
      :held ->
        :ok

      :schedule_error ->
        {:error, :unavailable}

      result when result in [:ready, :failed_capacity, :failed] ->
        send(server, {:accepted_call_runtime, call_id, result})
        :ok
    end
  end
end
