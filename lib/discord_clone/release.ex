defmodule DiscordClone.Release do
  @moduledoc """
  Runs database and operator tasks from a production release without Mix.
  """

  @app :discord_clone

  @spec provision_user() :: :ok
  def provision_user do
    load_app()

    if Process.whereis(DiscordClone.Repo) do
      provision_user_with_repo()
    else
      {:ok, result, _apps} =
        Ecto.Migrator.with_repo(DiscordClone.Repo, fn _repo -> provision_user_with_repo() end)

      result
    end
  end

  @spec migrate() :: [term()]
  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, migrated, _apps} =
        Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))

      migrated
    end
  end

  defp provision_user_with_repo do
    attributes = %{
      email: System.fetch_env!("DISCORD_CLONE_USER_EMAIL"),
      username: System.fetch_env!("DISCORD_CLONE_USERNAME"),
      password: System.fetch_env!("DISCORD_CLONE_USER_PASSWORD")
    }

    case DiscordClone.Accounts.provision_user(attributes) do
      {:ok, user} ->
        IO.puts("Provisioned confirmed account #{user.email} (#{user.username}).")
        :ok

      {:error, changeset} ->
        raise "Could not provision account: #{DiscordClone.ChangesetErrors.format(changeset)}"
    end
  end

  defp repos, do: Application.fetch_env!(@app, :ecto_repos)

  defp load_app do
    {:ok, _apps} = Application.ensure_all_started(:ssl)
    :ok = Application.ensure_loaded(@app)
  end
end
