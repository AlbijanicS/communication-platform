defmodule DiscordClone.Voice.SessionICEBundle do
  @moduledoc """
  One canonical, runtime-only ICE configuration for a Voice admission.

  Endpoint projections deliberately differ where browser and ExWebRTC
  capabilities differ. Temporary expiry metadata remains internal.
  """

  alias DiscordClone.Voice.ServerICEProjection

  @type browser_ice_server :: %{
          required(:urls) => String.t() | [String.t()],
          optional(:username) => String.t(),
          optional(:credential) => String.t()
        }

  @type browser_projection :: %{
          required(:ice_mode) => String.t(),
          required(:ice_servers) => [browser_ice_server()],
          required(:ice_transport_policy) => String.t()
        }

  @type t :: %__MODULE__{
          mode: :disabled | :standard | :turn_only,
          browser_projection: browser_projection(),
          server_projection: ServerICEProjection.t(),
          expires_at: DateTime.t() | nil
        }

  @enforce_keys [:mode, :browser_projection, :server_projection, :expires_at]
  defstruct [:mode, :browser_projection, :server_projection, :expires_at]
end
