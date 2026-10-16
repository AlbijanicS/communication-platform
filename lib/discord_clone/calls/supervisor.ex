defmodule DiscordClone.Calls.Supervisor do
  @moduledoc false

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))
  end

  @impl true
  def init(:ok) do
    children = [
      {Registry, keys: :unique, name: DiscordClone.Calls.CallRegistry},
      %{
        id: DiscordClone.Calls.CallSupervisor,
        start:
          {DynamicSupervisor, :start_link,
           [[strategy: :one_for_one, name: DiscordClone.Calls.CallSupervisor]]},
        type: :supervisor
      },
      {DiscordClone.Calls.CallCoordinator, name: DiscordClone.Calls.CallCoordinator}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
