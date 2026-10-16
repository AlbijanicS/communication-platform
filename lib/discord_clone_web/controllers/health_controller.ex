defmodule DiscordCloneWeb.HealthController do
  use DiscordCloneWeb, :controller

  alias DiscordClone.DeploymentReadiness

  def health(conn, _params) do
    json(conn, %{status: "ok"})
  end

  def ready(conn, _params) do
    case DeploymentReadiness.check() do
      :ready -> json(conn, %{status: "ok"})
      :unavailable -> conn |> put_status(:service_unavailable) |> json(%{status: "unavailable"})
    end
  end
end
