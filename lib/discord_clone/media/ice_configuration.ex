defmodule DiscordClone.Media.ICEConfiguration do
  @moduledoc """
  Resolves temporary provider authorization and endpoint ICE projections from
  statically validated settings. This is ordinary setup work executed by the
  admission caller, never by a shared coordinator or a packet handler.

  `Voice.ICEConfigurationResolver` retains the existing configuration key and
  static validation boundary. The Voice-named bundle/projection structs remain
  compatible runtime values for both consumers; they contain no Voice policy.
  """

  alias DiscordClone.Voice.{ServerICEProjection, SessionICEBundle}

  @authorization_keys [:credential, :expires_at, :urls, :username]
  @default_provider_timeout_ms 3_000
  @default_minimum_credential_lifetime_seconds 60

  @doc "Resolves settings that have passed static configuration validation."
  @spec resolve(keyword(), map() | nil) ::
          {:ok, SessionICEBundle.t()}
          | {:error, :invalid_provider_response | :provider_unavailable}
  def resolve(options, media_configuration, lifecycle_options \\ []) do
    case Keyword.fetch!(options, :mode) do
      :disabled ->
        disabled_bundle()

      mode when mode in [:standard, :turn_only] ->
        hosted_bundle(mode, options, media_configuration, lifecycle_options)
    end
  end

  defp disabled_bundle do
    {:ok,
     %SessionICEBundle{
       mode: :disabled,
       browser_projection: %{ice_mode: "disabled", ice_servers: [], ice_transport_policy: "all"},
       server_projection: ServerICEProjection.disabled(),
       expires_at: nil
     }}
  end

  defp hosted_bundle(mode, options, media_configuration, lifecycle_options) do
    stun_urls = Keyword.fetch!(options, :stun_urls)
    provider = Keyword.fetch!(options, :provider)
    provider_options = Keyword.get(options, :provider_options, [])
    provider_secret = Keyword.fetch!(options, :provider_secret)

    provider_timeout_ms =
      Keyword.get(options, :provider_timeout_ms) || @default_provider_timeout_ms

    minimum_lifetime_seconds =
      Keyword.get(options, :minimum_credential_lifetime_seconds) ||
        @default_minimum_credential_lifetime_seconds

    with {:ok, authorization} <-
           request_authorization(
             provider,
             Keyword.put(provider_options, :secret, provider_secret),
             provider_timeout_ms,
             lifecycle_options
           ),
         {:ok, authorization} <- validate_authorization(authorization, minimum_lifetime_seconds),
         {:ok, server_projection} <-
           server_projection(
             mode,
             stun_urls,
             authorization,
             media_configuration
           ) do
      {:ok,
       %SessionICEBundle{
         mode: mode,
         browser_projection: browser_projection(mode, stun_urls, authorization),
         server_projection: server_projection,
         expires_at: authorization.expires_at
       }}
    end
  end

  defp request_authorization(provider, provider_options, timeout_ms, lifecycle_options) do
    request_ref = make_ref()
    caller = self()

    request = fn -> send(caller, {request_ref, invoke_provider(provider, provider_options)}) end

    {provider_pid, monitor_ref} =
      if Keyword.get(lifecycle_options, :link_provider?, false) do
        # A trapping Session owns this setup worker through the same linked
        # resource tree as its transport. Retiring the Session cancels the
        # provider even while its resolver is blocked waiting for the reply.
        {:ok, pid} = Task.start_link(request)
        {pid, Process.monitor(pid)}
      else
        spawn_monitor(request)
      end

    receive do
      {^request_ref, result} ->
        Process.demonitor(monitor_ref, [:flush])
        normalize_provider_result(result)

      {:DOWN, ^monitor_ref, :process, ^provider_pid, _reason} ->
        {:error, :provider_unavailable}
    after
      timeout_ms ->
        Process.exit(provider_pid, :kill)
        Process.demonitor(monitor_ref, [:flush])
        {:error, :provider_unavailable}
    end
  end

  defp invoke_provider(provider, provider_options) do
    provider.resolve(provider_options)
  rescue
    _provider_error -> {:error, :unavailable}
  catch
    _kind, _provider_error -> {:error, :unavailable}
  end

  defp normalize_provider_result(result) do
    case result do
      {:ok, authorization} -> {:ok, authorization}
      {:error, :invalid_response} -> {:error, :invalid_provider_response}
      {:error, _bounded_or_provider_error} -> {:error, :provider_unavailable}
      _invalid_return -> {:error, :invalid_provider_response}
    end
  end

  defp validate_authorization(%{} = authorization, minimum_lifetime_seconds) do
    with true <- Enum.sort(Map.keys(authorization)) == @authorization_keys,
         urls when is_list(urls) and urls != [] <- authorization.urls,
         true <- Enum.all?(urls, &turn_url?/1),
         true <- non_blank_string?(authorization.username),
         true <- non_blank_string?(authorization.credential),
         %DateTime{} = expires_at <- authorization.expires_at,
         true <- sufficient_lifetime?(expires_at, minimum_lifetime_seconds) do
      {:ok, authorization}
    else
      _invalid_authorization -> {:error, :invalid_provider_response}
    end
  end

  defp validate_authorization(_authorization, _minimum_lifetime_seconds),
    do: {:error, :invalid_provider_response}

  defp server_projection(
         mode,
         stun_urls,
         authorization,
         media_configuration
       ) do
    udp_turn_urls = preferred_server_turn_urls(authorization.urls)

    if udp_turn_urls == [] do
      {:error, :invalid_provider_response}
    else
      ServerICEProjection.new(
        ice_mode: mode,
        ice_servers: server_ice_servers(mode, stun_urls, authorization, udp_turn_urls),
        transport_policy: server_transport_policy(mode),
        host_to_srflx_ip_mapper:
          exact_ipv4_mapper(
            media_configuration.internal_ipv4,
            media_configuration.external_ipv4
          ),
        udp_port_range: media_configuration.udp_port_range
      )
      |> case do
        {:ok, projection} -> {:ok, projection}
        {:error, :invalid_server_ice_projection} -> {:error, :invalid_provider_response}
      end
    end
  end

  defp browser_projection(mode, stun_urls, authorization) do
    %{
      ice_mode: Atom.to_string(mode),
      ice_servers: browser_ice_servers(mode, stun_urls, authorization),
      ice_transport_policy: browser_transport_policy(mode)
    }
  end

  defp browser_ice_servers(:standard, stun_urls, authorization),
    do: [%{urls: stun_urls}, turn_ice_server(authorization, authorization.urls)]

  defp browser_ice_servers(:turn_only, _stun_urls, authorization),
    do: [turn_ice_server(authorization, authorization.urls)]

  defp server_ice_servers(:standard, stun_urls, authorization, udp_turn_urls),
    do: [%{urls: stun_urls}, turn_ice_server(authorization, udp_turn_urls)]

  defp server_ice_servers(:turn_only, _stun_urls, authorization, udp_turn_urls),
    do: [turn_ice_server(authorization, udp_turn_urls)]

  defp turn_ice_server(authorization, urls) do
    %{
      urls: urls,
      username: authorization.username,
      credential: authorization.credential
    }
  end

  defp browser_transport_policy(:standard), do: "all"
  defp browser_transport_policy(:turn_only), do: "relay"

  defp server_transport_policy(:standard), do: :all
  defp server_transport_policy(:turn_only), do: :relay

  defp turn_url?(url) do
    case parse_ice_url(url) do
      {:ok, %{scheme: scheme}} when scheme in [:turn, :turns] -> true
      _invalid_url -> false
    end
  end

  defp server_turn_url?(url) do
    case parse_ice_url(url) do
      {:ok, %{scheme: :turn, transport: transport}} when transport in [nil, :udp] -> true
      _unsupported_url -> false
    end
  end

  defp preferred_server_turn_urls(urls) do
    udp_urls = Enum.filter(urls, &server_turn_url?/1)

    case Enum.find(udp_urls, &default_turn_port?/1) || List.first(udp_urls) do
      nil -> []
      url -> [url]
    end
  end

  defp default_turn_port?(url) do
    case parse_ice_url(url) do
      {:ok, %{port: 3478}} -> true
      _other_port -> false
    end
  end

  defp parse_ice_url(url) when is_binary(url) and byte_size(url) > 0,
    do: ExSTUN.URI.parse(url)

  defp parse_ice_url(_url), do: {:error, :invalid_uri}

  defp exact_ipv4_mapper(internal_ipv4, external_ipv4) do
    fn
      ^internal_ipv4 -> external_ipv4
      _other_address -> nil
    end
  end

  defp sufficient_lifetime?(expires_at, minimum_lifetime_seconds) do
    minimum_expiry = DateTime.add(DateTime.utc_now(), minimum_lifetime_seconds, :second)
    DateTime.compare(expires_at, minimum_expiry) in [:eq, :gt]
  end

  defp non_blank_string?(value),
    do: is_binary(value) and value |> String.trim() |> byte_size() > 0
end
