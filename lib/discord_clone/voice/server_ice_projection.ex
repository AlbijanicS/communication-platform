defmodule DiscordClone.Voice.ServerICEProjection do
  @moduledoc """
  Validated, provider-neutral ICE configuration for one server Voice Session.

  The projection is runtime-only. `DiscordClone.Voice.PeerConnection` owns its
  translation into ExWebRTC options.
  """

  @allowed_keys [
    :ice_mode,
    :ice_servers,
    :transport_policy,
    :host_to_srflx_ip_mapper,
    :udp_port_range
  ]

  @type ice_server :: %{
          required(:urls) => String.t() | [String.t()],
          optional(:username) => String.t(),
          optional(:credential) => String.t()
        }

  @type t :: %__MODULE__{
          ice_mode: :disabled | :standard | :turn_only,
          ice_servers: [ice_server()],
          transport_policy: :all | :relay,
          host_to_srflx_ip_mapper: (:inet.ip_address() -> :inet.ip_address() | nil) | nil,
          udp_port_range: Range.t() | nil
        }

  defstruct ice_mode: :disabled,
            ice_servers: [],
            transport_policy: :all,
            host_to_srflx_ip_mapper: nil,
            udp_port_range: nil

  @spec disabled() :: t()
  def disabled, do: %__MODULE__{}

  @spec new(keyword()) :: {:ok, t()} | {:error, :invalid_server_ice_projection}
  def new(options) when is_list(options) do
    with :ok <- validate_option_keys(options) do
      options
      |> then(&struct(__MODULE__, &1))
      |> validate()
    else
      :error -> {:error, :invalid_server_ice_projection}
    end
  rescue
    _error -> {:error, :invalid_server_ice_projection}
  end

  def new(_options), do: {:error, :invalid_server_ice_projection}

  @spec validate(term()) :: {:ok, t()} | {:error, :invalid_server_ice_projection}
  def validate(%__MODULE__{} = projection) do
    with :ok <- validate_ice_mode(projection.ice_mode),
         :ok <- validate_ice_servers(projection.ice_servers),
         :ok <- validate_transport_policy(projection.transport_policy),
         :ok <- validate_mapper(projection.host_to_srflx_ip_mapper),
         :ok <- validate_port_range(projection.udp_port_range) do
      {:ok, projection}
    else
      :error -> {:error, :invalid_server_ice_projection}
    end
  end

  def validate(_projection), do: {:error, :invalid_server_ice_projection}

  defp validate_ice_mode(mode) when mode in [:disabled, :standard, :turn_only], do: :ok
  defp validate_ice_mode(_mode), do: :error

  defp validate_option_keys(options) do
    if Keyword.keyword?(options) and
         Enum.all?(Keyword.keys(options), &(&1 in @allowed_keys)) do
      :ok
    else
      :error
    end
  end

  defp validate_ice_servers(ice_servers) when is_list(ice_servers) do
    if Enum.all?(ice_servers, &valid_ice_server?/1), do: :ok, else: :error
  end

  defp validate_ice_servers(_ice_servers), do: :error

  defp valid_ice_server?(%{} = ice_server) do
    keys = Map.keys(ice_server)

    Enum.all?(keys, &(&1 in [:urls, :username, :credential])) and
      Map.has_key?(ice_server, :urls) and
      valid_urls?(ice_server.urls) and
      valid_optional_string?(Map.get(ice_server, :username)) and
      valid_optional_string?(Map.get(ice_server, :credential)) and
      credentials_complete?(ice_server)
  end

  defp valid_ice_server?(_ice_server), do: false

  defp valid_urls?(urls) when is_binary(urls), do: valid_url?(urls)

  defp valid_urls?(urls) when is_list(urls) and urls != [],
    do: Enum.all?(urls, &valid_url?/1)

  defp valid_urls?(_urls), do: false

  defp valid_url?(url) when is_binary(url) and byte_size(url) > 0 do
    match?({:ok, _uri}, ExSTUN.URI.parse(url))
  end

  defp valid_url?(_url), do: false

  defp valid_optional_string?(nil), do: true
  defp valid_optional_string?(value), do: is_binary(value) and byte_size(value) > 0

  defp credentials_complete?(ice_server) do
    Map.has_key?(ice_server, :username) == Map.has_key?(ice_server, :credential)
  end

  defp validate_transport_policy(policy) when policy in [:all, :relay], do: :ok
  defp validate_transport_policy(_policy), do: :error

  defp validate_mapper(nil), do: :ok
  defp validate_mapper(mapper) when is_function(mapper, 1), do: :ok
  defp validate_mapper(_mapper), do: :error

  defp validate_port_range(nil), do: :ok

  defp validate_port_range(%Range{first: first, last: last, step: 1})
       when first in 1..65_535 and last in 1..65_535 and first <= last,
       do: :ok

  defp validate_port_range(_range), do: :error
end
