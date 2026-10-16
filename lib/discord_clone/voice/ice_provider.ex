defmodule DiscordClone.Voice.ICEProvider do
  @moduledoc """
  Provider-neutral boundary for temporary hosted ICE authorization.

  Implementations translate vendor responses into this allowlisted shape. Voice
  code never receives vendor SDK values, response bodies, or provider-specific
  errors.
  """

  @type authorization :: %{
          required(:urls) => [String.t()],
          required(:username) => String.t(),
          required(:credential) => String.t(),
          required(:expires_at) => DateTime.t()
        }

  @type error_reason ::
          :invalid_response | :timeout | :transport_error | :unsuccessful_status | :unavailable

  @callback resolve(keyword()) ::
              {:ok, authorization()} | {:error, error_reason()}
end
