defmodule DiscordClone.Media.SessionSupervisor do
  @moduledoc false

  use DynamicSupervisor

  alias DiscordClone.Media.Target

  @spec start_link(keyword()) :: DynamicSupervisor.on_start()
  def start_link(opts) do
    target = Keyword.fetch!(opts, :target)
    generation = Keyword.fetch!(opts, :generation)

    DynamicSupervisor.start_link(__MODULE__, opts,
      name: Target.runtime_name(target, generation, :sessions)
    )
  end

  @impl true
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)
end
