defmodule DiscordClone.Voice.DeploymentCapacity do
  @moduledoc false

  @max_active_sessions 20
  @udp_port_range 50_000..50_031

  @spec max_active_sessions() :: pos_integer()
  def max_active_sessions, do: @max_active_sessions

  @spec udp_port_range() :: Range.t()
  def udp_port_range, do: @udp_port_range

  @spec valid_configuration?(term(), term()) :: boolean()
  def valid_configuration?(@udp_port_range, @max_active_sessions) do
    Range.size(@udp_port_range) >= @max_active_sessions
  end

  def valid_configuration?(_udp_port_range, _max_active_sessions), do: false

  @spec validate_configuration!(term(), term()) :: :ok
  def validate_configuration!(udp_port_range, max_active_sessions) do
    if valid_configuration?(udp_port_range, max_active_sessions) do
      :ok
    else
      raise ArgumentError,
            "invalid deployment capacity: UDP range #{inspect(udp_port_range)} " <>
              "must cover #{inspect(max_active_sessions)} slots"
    end
  end

  @spec validate_current_configuration() :: :ok | {:error, :invalid_deployment_capacity}
  def validate_current_configuration do
    if valid_configuration?(@udp_port_range, @max_active_sessions) do
      :ok
    else
      {:error, :invalid_deployment_capacity}
    end
  end
end
