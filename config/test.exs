import Config

# Only in tests, remove the complexity from the password hashing algorithm
config :bcrypt_elixir, :log_rounds, 1

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :discord_clone, DiscordClone.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "communication_platform_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :discord_clone, DiscordCloneWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: String.duplicate("local-test-only-", 5),
  server: false

# In test we don't send emails
config :discord_clone, DiscordClone.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Calls tests start the rest_for_one subtree with start_supervised!/1.
config :discord_clone, :start_calls_runtime, false

# Deterministic invitation, video and pair-admission tests inject fake media.
# Real-media suites opt in; shipping-default certification removes both overrides.
config :discord_clone, :direct_call_transport, :fake
config :discord_clone, :accepted_call_runtime, DiscordClone.Calls.FakeAcceptedCallRuntime

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
