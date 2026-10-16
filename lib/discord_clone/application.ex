defmodule DiscordClone.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  alias DiscordClone.Voice.ICEConfigurationResolver

  @impl true
  def start(_type, _args) do
    with :ok <- ICEConfigurationResolver.validate_static_configuration(),
         :ok <- DiscordClone.Voice.DeploymentCapacity.validate_current_configuration() do
      start_supervisor()
    else
      {:error, :invalid_configuration} ->
        {:error, {:invalid_voice_ice_configuration, :invalid_configuration}}

      {:error, :invalid_deployment_capacity} ->
        {:error, {:invalid_deployment_capacity, :invalid_deployment_capacity}}
    end
  end

  defp start_supervisor do
    :ok = DiscordClone.Media.CallCleanupLedger.initialize()

    children =
      [
        DiscordCloneWeb.Telemetry,
        DiscordClone.Repo,
        {DNSCluster, query: Application.get_env(:discord_clone, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: DiscordClone.PubSub}
      ] ++
        calls_runtime_children() ++
        [
          {Registry, keys: :unique, name: DiscordClone.Chat.WorkspaceRegistry},
          {DynamicSupervisor,
           strategy: :one_for_one, name: DiscordClone.Chat.WorkspaceSupervisor},
          {Registry, keys: :unique, name: DiscordClone.Chat.ConversationRegistry},
          {DynamicSupervisor,
           strategy: :one_for_one, name: DiscordClone.Chat.ConversationSupervisor},
          {Registry, keys: :unique, name: DiscordClone.Presence.Registry},
          {DynamicSupervisor, strategy: :one_for_one, name: DiscordClone.Presence.Supervisor},
          {Registry, keys: :unique, name: DiscordClone.Voice.RoomRegistry},
          {DynamicSupervisor, strategy: :one_for_one, name: DiscordClone.Voice.RoomSupervisor},
          {DynamicSupervisor,
           strategy: :one_for_one, name: DiscordClone.Media.DirectCallTargetSupervisor},
          {DiscordClone.Media.AdmissionCoordinator, name: DiscordClone.Voice.SessionCoordinator},
          DiscordCloneWeb.Endpoint
        ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options. High restart intensity:
    # coordinator crash tests (Ticket 10) kill the global admission
    # coordinator at each boundary in quick succession; fail-closed recovery
    # must restart every time rather than taking down the node.
    opts = [
      strategy: :one_for_one,
      name: DiscordClone.Supervisor,
      max_restarts: 50,
      max_seconds: 60
    ]

    Supervisor.start_link(children, opts)
  end

  defp calls_runtime_children do
    if Application.get_env(:discord_clone, :start_calls_runtime, true) do
      [DiscordClone.Calls.Supervisor]
    else
      []
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    DiscordCloneWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
