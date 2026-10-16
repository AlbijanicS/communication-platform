import Config

# Completed video ships in every environment. Set DIRECT_CALL_CAMERA_LIFECYCLE=false
# to disable video operationally; only the literal "true" enables an explicit value.
config :discord_clone,
       :direct_call_camera_lifecycle_enabled,
       System.get_env("DIRECT_CALL_CAMERA_LIFECYCLE", "true") == "true"

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/discord_clone start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :discord_clone, DiscordCloneWeb.Endpoint, server: true
end

config :discord_clone, DiscordCloneWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() == :prod do
  required_env = fn name ->
    case System.get_env(name) do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: raise("#{name} must not be blank"), else: value

      _missing ->
        raise "environment variable #{name} is missing"
    end
  end

  bounded_integer_env = fn name, minimum, maximum ->
    value = required_env.(name)

    case Integer.parse(value) do
      {integer, ""} when integer >= minimum and integer <= maximum ->
        integer

      _invalid ->
        raise "#{name} must be between #{minimum} and #{maximum} seconds"
    end
  end

  voice_ice_mode =
    case System.get_env("VOICE_ICE_MODE") do
      "standard" -> :standard
      "turn_only" -> :turn_only
      _missing_or_invalid -> raise "VOICE_ICE_MODE must be standard or turn_only in production"
    end

  voice_stun_urls =
    case voice_ice_mode do
      :standard ->
        "VOICE_STUN_URLS"
        |> required_env.()
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      :turn_only ->
        []
    end

  voice_ice_configuration = [
    mode: voice_ice_mode,
    stun_urls: voice_stun_urls,
    provider: DiscordClone.Voice.ICEProviders.Cloudflare,
    provider_options: [
      key_id: required_env.("CLOUDFLARE_TURN_KEY_ID"),
      ttl_seconds: bounded_integer_env.("VOICE_TURN_CREDENTIAL_TTL_SECONDS", 120, 172_800)
    ],
    provider_secret: required_env.("CLOUDFLARE_TURN_API_TOKEN"),
    provider_timeout_ms: 3_000,
    minimum_credential_lifetime_seconds: 60,
    internal_ipv4: required_env.("VOICE_INTERNAL_IPV4"),
    external_ipv4: required_env.("VOICE_EXTERNAL_IPV4"),
    udp_port_range: 50_000..50_031,
    max_active_sessions: 20
  ]

  config :discord_clone,
         DiscordClone.Voice.ICEConfigurationResolver,
         voice_ice_configuration

  database_url = required_env.("DATABASE_URL")

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :discord_clone, DiscordClone.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base = required_env.("SECRET_KEY_BASE")

  host = required_env.("PHX_HOST")

  config :discord_clone, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :discord_clone, DiscordCloneWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Caddy terminates public TLS on the same VM and proxies HTTP/WebSocket
      # traffic to this private IPv4 loopback listener.
      ip: {127, 0, 0, 1}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :discord_clone, DiscordCloneWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :discord_clone, DiscordCloneWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
