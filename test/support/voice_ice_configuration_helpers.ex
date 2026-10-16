defmodule DiscordClone.VoiceICEConfigurationHelpers do
  @moduledoc false

  alias DiscordClone.Voice.ICEConfigurationResolver

  def preserve_voice_ice_configuration do
    previous = Application.get_env(:discord_clone, ICEConfigurationResolver)

    ExUnit.Callbacks.on_exit(fn ->
      if previous do
        Application.put_env(:discord_clone, ICEConfigurationResolver, previous)
      else
        Application.delete_env(:discord_clone, ICEConfigurationResolver)
      end
    end)

    :ok
  end

  def put_voice_ice_configuration(options) do
    :ok = preserve_voice_ice_configuration()

    options =
      if Keyword.get(options, :mode) in [:standard, :turn_only] do
        Keyword.merge(hosted_cloud_defaults(), options)
      else
        options
      end

    Application.put_env(:discord_clone, ICEConfigurationResolver, options)
  end

  defp hosted_cloud_defaults do
    [
      internal_ipv4: "10.20.0.4",
      external_ipv4: "34.118.200.24",
      udp_port_range: 50_000..50_031,
      max_active_sessions: 20
    ]
  end
end
