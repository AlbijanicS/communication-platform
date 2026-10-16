defmodule DiscordClone.Voice.ICEConfigurationResolver do
  @moduledoc """
  Resolves one provider-neutral ICE bundle for each Voice admission attempt.

  Development and tests remain deterministic when no configuration is present:
  the resolver uses disabled mode and never invokes a hosted provider.
  """

  alias DiscordClone.Media.ICEConfiguration
  alias DiscordClone.Voice.{DeploymentCapacity, SessionICEBundle}

  @application :discord_clone
  @maximum_provider_timeout_ms 3_000
  @hosted_configuration_keys [
    :external_ipv4,
    :internal_ipv4,
    :max_active_sessions,
    :minimum_credential_lifetime_seconds,
    :mode,
    :provider,
    :provider_options,
    :provider_secret,
    :provider_timeout_ms,
    :stun_urls,
    :udp_port_range
  ]

  @doc """
  Validates only static Voice ICE configuration.

  This startup-safe check deliberately never invokes the hosted provider.
  """
  @spec validate_static_configuration() :: :ok | {:error, :invalid_configuration}
  def validate_static_configuration do
    configured_options()
    |> validate_static_configuration()
  end

  @spec resolve() ::
          {:ok, SessionICEBundle.t()}
          | {:error, :invalid_configuration | :invalid_provider_response | :provider_unavailable}
  def resolve(lifecycle_options \\ []) do
    options = configured_options()

    with :ok <- validate_static_configuration(options) do
      resolve_config(options, lifecycle_options)
    end
  end

  defp validate_static_configuration(options) when is_list(options) do
    if Keyword.keyword?(options) and unique_configuration_keys?(options) do
      case Keyword.fetch(options, :mode) do
        {:ok, :disabled} ->
          :ok

        {:ok, mode} when mode in [:standard, :turn_only] ->
          validate_hosted_configuration(options)

        :error ->
          {:error, :invalid_configuration}

        {:ok, _unsupported_mode} ->
          {:error, :invalid_configuration}
      end
    else
      {:error, :invalid_configuration}
    end
  end

  defp validate_static_configuration(_options), do: {:error, :invalid_configuration}

  defp resolve_config(options, lifecycle_options) do
    media_configuration =
      case Keyword.fetch!(options, :mode) do
        :disabled ->
          nil

        _hosted_mode ->
          {:ok, configuration} = hosted_media_configuration(options)
          configuration
      end

    ICEConfiguration.resolve(options, media_configuration, lifecycle_options)
  end

  defp validate_hosted_configuration(options) do
    with true <- Keyword.keyword?(options),
         true <- Enum.all?(Keyword.keys(options), &(&1 in @hosted_configuration_keys)),
         {:ok, _stun_urls} <-
           validate_stun_urls(Keyword.get(options, :mode), Keyword.get(options, :stun_urls)),
         {:ok, _provider, _provider_options} <- provider_config(options),
         true <- non_blank_string?(Keyword.get(options, :provider_secret)),
         true <- valid_provider_timeout?(Keyword.get(options, :provider_timeout_ms)),
         true <-
           valid_minimum_lifetime?(Keyword.get(options, :minimum_credential_lifetime_seconds)),
         {:ok, _media_configuration} <- hosted_media_configuration(options) do
      :ok
    else
      _invalid_configuration -> {:error, :invalid_configuration}
    end
  end

  defp validate_stun_urls(:standard, urls) when is_list(urls) and urls != [] do
    if Enum.all?(urls, &stun_url?/1),
      do: {:ok, urls},
      else: {:error, :invalid_configuration}
  end

  defp validate_stun_urls(:turn_only, []), do: {:ok, []}
  defp validate_stun_urls(_mode, _urls), do: {:error, :invalid_configuration}

  defp provider_config(options) do
    provider = Keyword.get(options, :provider)
    provider_options = Keyword.get(options, :provider_options, [])

    if is_atom(provider) and Code.ensure_loaded?(provider) and
         function_exported?(provider, :resolve, 1) and
         is_list(provider_options) and Keyword.keyword?(provider_options) and
         not Keyword.has_key?(provider_options, :secret) do
      {:ok, provider, provider_options}
    else
      {:error, :invalid_configuration}
    end
  end

  defp stun_url?(url) do
    case parse_ice_url(url) do
      {:ok, %{scheme: :stun}} -> true
      _invalid_url -> false
    end
  end

  defp parse_ice_url(url) when is_binary(url) and byte_size(url) > 0,
    do: ExSTUN.URI.parse(url)

  defp parse_ice_url(_url), do: {:error, :invalid_uri}

  defp non_blank_string?(value),
    do: is_binary(value) and value |> String.trim() |> byte_size() > 0

  defp hosted_media_configuration(options) do
    udp_port_range = Keyword.get(options, :udp_port_range)
    max_active_sessions = Keyword.get(options, :max_active_sessions)

    with {:ok, internal_ipv4} <- validate_internal_ipv4(Keyword.get(options, :internal_ipv4)),
         {:ok, external_ipv4} <- validate_external_ipv4(Keyword.get(options, :external_ipv4)),
         true <-
           DeploymentCapacity.valid_configuration?(udp_port_range, max_active_sessions) do
      {:ok,
       %{
         internal_ipv4: internal_ipv4,
         external_ipv4: external_ipv4,
         udp_port_range: udp_port_range
       }}
    else
      _invalid_configuration -> {:error, :invalid_configuration}
    end
  end

  defp validate_internal_ipv4(value) do
    with {:ok, address} <- parse_ipv4(value),
         true <- private_ipv4?(address) do
      {:ok, address}
    else
      _invalid_address -> {:error, :invalid_configuration}
    end
  end

  defp validate_external_ipv4(value) do
    with {:ok, address} <- parse_ipv4(value),
         true <- public_unicast_ipv4?(address) do
      {:ok, address}
    else
      _invalid_address -> {:error, :invalid_configuration}
    end
  end

  defp parse_ipv4(value) when is_binary(value) do
    value
    |> String.to_charlist()
    |> :inet.parse_ipv4_address()
  end

  defp parse_ipv4(_value), do: {:error, :einval}

  defp private_ipv4?({10, _b, _c, _d}), do: true
  defp private_ipv4?({172, b, _c, _d}) when b in 16..31, do: true
  defp private_ipv4?({192, 168, _c, _d}), do: true
  defp private_ipv4?(_address), do: false

  defp public_unicast_ipv4?({first, _b, _c, _d}) when first in [0, 10, 127] or first >= 224,
    do: false

  defp public_unicast_ipv4?({100, b, _c, _d}) when b in 64..127, do: false
  defp public_unicast_ipv4?({169, 254, _c, _d}), do: false
  defp public_unicast_ipv4?({172, b, _c, _d}) when b in 16..31, do: false
  defp public_unicast_ipv4?({192, 0, _c, _d}), do: false
  defp public_unicast_ipv4?({192, 168, _c, _d}), do: false
  defp public_unicast_ipv4?({198, b, _c, _d}) when b in 18..19 or b == 51, do: false
  defp public_unicast_ipv4?({203, 0, 113, _d}), do: false
  defp public_unicast_ipv4?({_first, _b, _c, _d}), do: true

  defp valid_provider_timeout?(nil), do: true

  defp valid_provider_timeout?(timeout_ms),
    do: is_integer(timeout_ms) and timeout_ms in 1..@maximum_provider_timeout_ms

  defp valid_minimum_lifetime?(nil), do: true

  defp valid_minimum_lifetime?(seconds),
    do: is_integer(seconds) and seconds > 0

  defp unique_configuration_keys?(options) do
    keys = Keyword.keys(options)
    Enum.uniq(keys) == keys
  end

  defp configured_options do
    Application.get_env(@application, __MODULE__) || [mode: :disabled]
  end
end
