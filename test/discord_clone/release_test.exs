defmodule DiscordClone.ReleaseTest do
  use DiscordClone.DataCase, async: false

  import ExUnit.CaptureIO

  @environment_names [
    "DISCORD_CLONE_USER_EMAIL",
    "DISCORD_CLONE_USERNAME",
    "DISCORD_CLONE_USER_PASSWORD"
  ]

  setup do
    previous_environment = Map.new(@environment_names, &{&1, System.get_env(&1)})
    on_exit(fn -> restore_environment(previous_environment) end)
    :ok
  end

  test "provisions a confirmed account without printing its password" do
    System.put_env("DISCORD_CLONE_USER_EMAIL", "release-user@example.com")
    System.put_env("DISCORD_CLONE_USERNAME", "release_user")
    System.put_env("DISCORD_CLONE_USER_PASSWORD", "release-password-1234")

    output = capture_io(&DiscordClone.Release.provision_user/0)

    assert output =~ "release-user@example.com"
    refute output =~ "release-password-1234"

    assert DiscordClone.Accounts.get_user_by_email_and_password(
             "release-user@example.com",
             "release-password-1234"
           )
  end

  test "reports bounded validation details without echoing the password" do
    System.put_env("DISCORD_CLONE_USER_EMAIL", "invalid-release-user@example.com")
    System.put_env("DISCORD_CLONE_USERNAME", "invalid_release_user")
    System.put_env("DISCORD_CLONE_USER_PASSWORD", "short")

    error =
      assert_raise RuntimeError, ~r/password should be at least 12 character/, fn ->
        DiscordClone.Release.provision_user()
      end

    refute Exception.message(error) =~ "short"
  end

  defp restore_environment(environment) do
    Enum.each(environment, fn
      {name, nil} -> System.delete_env(name)
      {name, value} -> System.put_env(name, value)
    end)
  end
end
