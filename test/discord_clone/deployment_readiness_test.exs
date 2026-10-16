defmodule DiscordClone.DeploymentReadinessTest do
  use ExUnit.Case, async: false

  import DiscordClone.VoiceICEConfigurationHelpers

  alias DiscordClone.DeploymentReadiness
  alias DiscordClone.Voice.FakeICEProvider

  setup do
    previous_checks = Application.get_env(:discord_clone, DeploymentReadiness)

    on_exit(fn ->
      if previous_checks do
        Application.put_env(:discord_clone, DeploymentReadiness, previous_checks)
      else
        Application.delete_env(:discord_clone, DeploymentReadiness)
      end
    end)

    :ok = preserve_voice_ice_configuration()
  end

  test "reports ready only after the database and static ICE configuration pass" do
    parent = self()

    Application.put_env(:discord_clone, DeploymentReadiness,
      database_check: fn ->
        send(parent, :database_checked)
        :ok
      end,
      static_configuration_check: fn ->
        send(parent, :static_configuration_checked)
        :ok
      end
    )

    assert :ready = DeploymentReadiness.check()

    assert_receive :database_checked
    assert_receive :static_configuration_checked
  end

  test "normalizes database and static configuration failures" do
    failure_checks = [
      [database_check: fn -> {:error, "database-url-with-secret"} end],
      [database_check: fn -> raise "database-url-with-secret" end],
      [database_check: fn -> exit(:database_connection_failed) end],
      [static_configuration_check: fn -> {:error, :invalid_configuration} end],
      [static_configuration_check: fn -> raise "provider-secret" end],
      [static_configuration_check: fn -> exit(:invalid_static_configuration) end]
    ]

    for checks <- failure_checks do
      checks =
        Keyword.merge(
          [database_check: fn -> :ok end, static_configuration_check: fn -> :ok end],
          checks
        )

      Application.put_env(:discord_clone, DeploymentReadiness, checks)
      assert :unavailable = DeploymentReadiness.check()
    end
  end

  test "static validation never requests hosted provider credentials" do
    put_voice_ice_configuration(
      mode: :standard,
      stun_urls: ["stun:stun.example.test:3478"],
      provider: FakeICEProvider,
      provider_options: [observer: self(), results: {:error, :unavailable}],
      provider_secret: "seeded-provider-secret"
    )

    Application.put_env(:discord_clone, DeploymentReadiness, database_check: fn -> :ok end)

    assert :ready = DeploymentReadiness.check()
    refute_receive {:voice_ice_provider_requested, _options}
  end
end
