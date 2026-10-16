defmodule DiscordClone.RuntimeConfigurationTest do
  use ExUnit.Case, async: false

  @runtime_environment %{
    "CLOUDFLARE_TURN_API_TOKEN" => "durable-provider-secret",
    "CLOUDFLARE_TURN_KEY_ID" => "turn-key-id",
    "DATABASE_URL" => "ecto://placeholder:placeholder@localhost/placeholder",
    "DIRECT_CALL_CAMERA_LIFECYCLE" => nil,
    "PHX_HOST" => "alpha.example.test",
    "PORT" => "4100",
    "RESEND_API_KEY" => nil,
    "MAIL_FROM_ADDRESS" => nil,
    "SECRET_KEY_BASE" => String.duplicate("placeholder", 8),
    "VOICE_EXTERNAL_IPV4" => "34.118.200.24",
    "VOICE_ICE_MODE" => "standard",
    "VOICE_INTERNAL_IPV4" => "10.20.0.4",
    "VOICE_STUN_URLS" => "stun:stun.cloudflare.com:3478",
    "VOICE_TURN_CREDENTIAL_TTL_SECONDS" => "3600"
  }

  setup do
    previous_values =
      Map.new(@runtime_environment, fn {key, _value} -> {key, System.get_env(key)} end)

    Enum.each(@runtime_environment, fn
      {key, nil} -> System.delete_env(key)
      {key, value} -> System.put_env(key, value)
    end)

    on_exit(fn ->
      Enum.each(previous_values, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)
  end

  test "production starts without email provider configuration" do
    config = Config.Reader.read!("config/runtime.exs", env: :prod)
    refute config[:discord_clone][DiscordClone.Mailer]
    refute config[:discord_clone][:mail_from_address]
  end

  test "completed video defaults on in every runtime environment with an explicit off override" do
    for environment <- [:dev, :test, :prod],
        {value, expected} <- [
          {nil, true},
          {"true", true},
          {"false", false},
          {"1", false},
          {"", false}
        ] do
      if value,
        do: System.put_env("DIRECT_CALL_CAMERA_LIFECYCLE", value),
        else: System.delete_env("DIRECT_CALL_CAMERA_LIFECYCLE")

      config = Config.Reader.read!("config/runtime.exs", env: environment)
      assert config[:discord_clone][:direct_call_camera_lifecycle_enabled] == expected
    end
  end

  test "production runtime binds Phoenix to IPv4 loopback behind the public HTTPS endpoint" do
    runtime_config = Config.Reader.read!("config/runtime.exs", env: :prod)
    endpoint_config = runtime_config[:discord_clone][DiscordCloneWeb.Endpoint]

    assert endpoint_config[:http][:ip] == {127, 0, 0, 1}
    assert endpoint_config[:http][:port] == 4100
    assert endpoint_config[:url] == [host: "alpha.example.test", port: 443, scheme: "https"]

    assert runtime_config[:discord_clone][DiscordClone.Voice.ICEConfigurationResolver] == [
             mode: :standard,
             stun_urls: ["stun:stun.cloudflare.com:3478"],
             provider: DiscordClone.Voice.ICEProviders.Cloudflare,
             provider_options: [key_id: "turn-key-id", ttl_seconds: 3_600],
             provider_secret: "durable-provider-secret",
             provider_timeout_ms: 3_000,
             minimum_credential_lifetime_seconds: 60,
             internal_ipv4: "10.20.0.4",
             external_ipv4: "34.118.200.24",
             udp_port_range: 50_000..50_031,
             max_active_sessions: 20
           ]
  end

  test "production Voice configuration passes the startup validator" do
    runtime_config = Config.Reader.read!("config/runtime.exs", env: :prod)
    voice_config = runtime_config[:discord_clone][DiscordClone.Voice.ICEConfigurationResolver]

    previous_config =
      Application.get_env(:discord_clone, DiscordClone.Voice.ICEConfigurationResolver)

    Application.put_env(
      :discord_clone,
      DiscordClone.Voice.ICEConfigurationResolver,
      voice_config
    )

    on_exit(fn ->
      if previous_config do
        Application.put_env(
          :discord_clone,
          DiscordClone.Voice.ICEConfigurationResolver,
          previous_config
        )
      else
        Application.delete_env(:discord_clone, DiscordClone.Voice.ICEConfigurationResolver)
      end
    end)

    assert :ok = DiscordClone.Voice.ICEConfigurationResolver.validate_static_configuration()
  end

  test "TURN-only production mode does not require or expose STUN servers" do
    System.put_env("VOICE_ICE_MODE", "turn_only")
    System.delete_env("VOICE_STUN_URLS")

    runtime_config = Config.Reader.read!("config/runtime.exs", env: :prod)
    voice_config = runtime_config[:discord_clone][DiscordClone.Voice.ICEConfigurationResolver]

    assert voice_config[:mode] == :turn_only
    assert voice_config[:stun_urls] == []
  end

  test "production rejects a missing explicit hosted ICE mode" do
    System.delete_env("VOICE_ICE_MODE")

    assert_raise RuntimeError, ~r/VOICE_ICE_MODE must be standard or turn_only/, fn ->
      Config.Reader.read!("config/runtime.exs", env: :prod)
    end
  end

  test "production rejects TURN credential lifetimes without setup headroom" do
    System.put_env("VOICE_TURN_CREDENTIAL_TTL_SECONDS", "119")

    assert_raise RuntimeError,
                 ~r/VOICE_TURN_CREDENTIAL_TTL_SECONDS must be between 120 and 172800 seconds/,
                 fn ->
                   Config.Reader.read!("config/runtime.exs", env: :prod)
                 end
  end

  test "production rejects TURN credential lifetimes above Cloudflare's maximum" do
    System.put_env("VOICE_TURN_CREDENTIAL_TTL_SECONDS", "172801")

    assert_raise RuntimeError,
                 ~r/VOICE_TURN_CREDENTIAL_TTL_SECONDS must be between 120 and 172800 seconds/,
                 fn ->
                   Config.Reader.read!("config/runtime.exs", env: :prod)
                 end
  end

  test "production rejects a missing Cloudflare secret before startup" do
    System.delete_env("CLOUDFLARE_TURN_API_TOKEN")

    assert_raise RuntimeError,
                 ~r/environment variable CLOUDFLARE_TURN_API_TOKEN is missing/,
                 fn ->
                   Config.Reader.read!("config/runtime.exs", env: :prod)
                 end
  end

  test "non-production runtime does not replace the environment-specific listener binding" do
    runtime_config = Config.Reader.read!("config/runtime.exs", env: :test)
    endpoint_config = runtime_config[:discord_clone][DiscordCloneWeb.Endpoint]

    assert endpoint_config[:http] == [port: 4100]
    refute runtime_config[:discord_clone][DiscordClone.Mailer]
    refute runtime_config[:discord_clone][:mail_from_address]
  end

  test "production keeps proxy-aware SSL rewriting" do
    production_config = Config.Reader.read!("config/prod.exs", env: :prod)
    endpoint_config = production_config[:discord_clone][DiscordCloneWeb.Endpoint]

    assert endpoint_config[:force_ssl][:rewrite_on] == [:x_forwarded_proto]
    assert production_config[:discord_clone][:secure_cookies]
  end
end
