defmodule DiscordClone.Voice.ICEProviders.Cloudflare do
  @moduledoc """
  Exchanges a server-side Cloudflare Realtime TURN key for short-lived ICE credentials.

  Provider responses are immediately reduced to the provider-neutral
  authorization shape. Durable secrets and raw response bodies never leave
  this module.
  """

  @behaviour DiscordClone.Voice.ICEProvider

  @endpoint_prefix "https://rtc.live.cloudflare.com/v1/turn/keys/"
  @maximum_ttl_seconds :timer.hours(48) |> div(1_000)

  @impl true
  def resolve(options) when is_list(options) do
    with {:ok, key_id} <- required_string(options, :key_id),
         {:ok, secret} <- required_string(options, :secret),
         {:ok, ttl_seconds} <- ttl_seconds(options),
         {:ok, request_options} <- request_options(options),
         requested_at = DateTime.utc_now(:second),
         {:ok, response} <- request(key_id, secret, ttl_seconds, request_options) do
      authorization(response, requested_at, ttl_seconds)
    end
  end

  def resolve(_invalid_options), do: {:error, :invalid_response}

  defp request(key_id, secret, ttl_seconds, request_options) do
    options =
      Keyword.merge(request_options,
        method: :post,
        url:
          @endpoint_prefix <> URI.encode_www_form(key_id) <> "/credentials/generate-ice-servers",
        auth: {:bearer, secret},
        json: %{ttl: ttl_seconds},
        retry: false
      )

    case Req.request(options) do
      {:ok, %Req.Response{status: 201, body: body}} -> {:ok, body}
      {:ok, %Req.Response{}} -> {:error, :unsuccessful_status}
      {:error, %Req.TransportError{reason: :timeout}} -> {:error, :timeout}
      {:error, _transport_error} -> {:error, :transport_error}
    end
  rescue
    _request_error -> {:error, :transport_error}
  end

  defp authorization(%{"iceServers" => ice_servers}, requested_at, ttl_seconds)
       when is_list(ice_servers) do
    with %{"urls" => urls, "username" => username, "credential" => credential}
         when is_list(urls) <- Enum.find(ice_servers, &credentialed_server?/1),
         true <- urls != [] and Enum.all?(urls, &non_blank_string?/1),
         true <- non_blank_string?(username),
         true <- non_blank_string?(credential) do
      {:ok,
       %{
         urls: urls,
         username: username,
         credential: credential,
         expires_at: DateTime.add(requested_at, ttl_seconds, :second)
       }}
    else
      _invalid_response -> {:error, :invalid_response}
    end
  end

  defp authorization(_invalid_body, _requested_at, _ttl_seconds), do: {:error, :invalid_response}

  defp credentialed_server?(%{
         "urls" => urls,
         "username" => username,
         "credential" => credential
       }) do
    is_list(urls) and non_blank_string?(username) and non_blank_string?(credential)
  end

  defp credentialed_server?(_server), do: false

  defp required_string(options, key) do
    case Keyword.get(options, key) do
      value when is_binary(value) ->
        if non_blank_string?(value), do: {:ok, value}, else: {:error, :invalid_response}

      _missing_or_invalid ->
        {:error, :invalid_response}
    end
  end

  defp ttl_seconds(options) do
    case Keyword.get(options, :ttl_seconds) do
      ttl_seconds when is_integer(ttl_seconds) and ttl_seconds in 60..@maximum_ttl_seconds ->
        {:ok, ttl_seconds}

      _missing_or_invalid ->
        {:error, :invalid_response}
    end
  end

  defp request_options(options) do
    case Keyword.get(options, :req_options, []) do
      request_options when is_list(request_options) ->
        if Keyword.keyword?(request_options),
          do: {:ok, request_options},
          else: {:error, :invalid_response}

      _invalid_options ->
        {:error, :invalid_response}
    end
  end

  defp non_blank_string?(value),
    do: is_binary(value) and value |> String.trim() |> byte_size() > 0
end
