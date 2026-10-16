defmodule Mix.Tasks.DiscordClone.ProvisionUser do
  @shortdoc "Provisions one confirmed password account"

  @moduledoc """
  Provisions one confirmed account for an operator-managed deployment.

      export DISCORD_CLONE_USER_PASSWORD='a password with at least 12 characters'
      mix discord_clone.provision_user person@example.com person_name
      unset DISCORD_CLONE_USER_PASSWORD

  The password is read from the environment so it is not printed or included
  in the command arguments.
  """

  use Mix.Task

  alias DiscordClone.Accounts

  @password_env "DISCORD_CLONE_USER_PASSWORD"

  @impl Mix.Task
  def run([email, username]) do
    password =
      System.get_env(@password_env) ||
        Mix.raise("#{@password_env} must be set before provisioning an account")

    Mix.Task.run("app.start")

    case Accounts.provision_user(%{email: email, username: username, password: password}) do
      {:ok, user} ->
        Mix.shell().info("Provisioned confirmed account #{user.email} (#{user.username}).")
        :ok

      {:error, changeset} ->
        Mix.raise(
          "Could not provision account: #{DiscordClone.ChangesetErrors.format(changeset)}"
        )
    end
  end

  def run(_invalid_arguments) do
    Mix.raise("usage: mix discord_clone.provision_user EMAIL USERNAME")
  end
end
