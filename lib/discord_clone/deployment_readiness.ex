defmodule DiscordClone.DeploymentReadiness do
  @moduledoc """
  Reports whether the application dependencies required for deployment are ready.

  Failures are deliberately reduced to one bounded result so callers cannot
  expose database or Voice ICE configuration details.
  """

  alias DiscordClone.Repo
  alias DiscordClone.Voice.ICEConfigurationResolver

  @type result :: :ready | :unavailable

  @doc """
  Checks minimal database availability and static Voice ICE configuration.

  The static check never resolves temporary provider credentials.
  """
  @spec check() :: result()
  def check do
    checks =
      default_checks()
      |> Keyword.merge(Application.get_env(:discord_clone, __MODULE__, []))

    with :ok <- run_check(Keyword.fetch!(checks, :database_check)),
         :ok <- run_check(Keyword.fetch!(checks, :static_configuration_check)) do
      :ready
    else
      :error -> :unavailable
    end
  end

  defp default_checks do
    [
      database_check: &database_available?/0,
      static_configuration_check: &ICEConfigurationResolver.validate_static_configuration/0
    ]
  end

  defp database_available? do
    Ecto.Adapters.SQL.query(Repo, "SELECT 1", [])
  end

  defp run_check(check) when is_function(check, 0) do
    case check.() do
      :ok -> :ok
      {:ok, _result} -> :ok
      _failure -> :error
    end
  rescue
    _error -> :error
  catch
    _kind, _reason -> :error
  end

  defp run_check(_invalid_check), do: :error
end
