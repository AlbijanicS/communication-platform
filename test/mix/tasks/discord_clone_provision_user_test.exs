defmodule Mix.Tasks.DiscordClone.ProvisionUserTest do
  use DiscordClone.DataCase, async: false

  alias DiscordClone.Accounts

  import DiscordClone.AccountsFixtures

  setup do
    previous_shell = Mix.shell()
    previous_password = System.get_env("DISCORD_CLONE_USER_PASSWORD")

    Mix.shell(Mix.Shell.Process)
    Mix.Task.reenable("discord_clone.provision_user")
    System.put_env("DISCORD_CLONE_USER_PASSWORD", valid_user_password())

    on_exit(fn ->
      Mix.shell(previous_shell)

      if previous_password do
        System.put_env("DISCORD_CLONE_USER_PASSWORD", previous_password)
      else
        System.delete_env("DISCORD_CLONE_USER_PASSWORD")
      end
    end)

    :ok
  end

  test "provisions a confirmed account without printing its password" do
    email = unique_user_email()
    username = unique_user_username()

    assert :ok = Mix.Tasks.DiscordClone.ProvisionUser.run([email, username])

    assert_received {:mix_shell, :info, [message]}
    assert message =~ email
    refute message =~ valid_user_password()
    assert Accounts.get_user_by_email_and_password(email, valid_user_password())
  end
end
