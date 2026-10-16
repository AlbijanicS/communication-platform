defmodule DiscordClone.Media.Connection do
  @moduledoc """
  Starts and releases one caller-owned ExWebRTC connection without choosing its
  media layout. Voice and Call adapters supply their own codec/extension options.

  The existing Voice projection struct remains the compatible runtime ICE value;
  it contains network configuration only, with no room or feature policy.
  """

  alias DiscordClone.Voice.ServerICEProjection
  alias ExWebRTC.PeerConnection

  @startup_timeout_ms 5_000
  @test_environment Code.ensure_loaded?(Mix) and Mix.env() == :test

  @spec start_link(ServerICEProjection.t(), keyword()) ::
          {:ok, pid()} | {:error, :peer_connection_unavailable}
  def start_link(projection, options \\ []) do
    with {:ok, projection} <- ServerICEProjection.validate(projection),
         {:ok, peer_connection} <-
           PeerConnection.start_link(connection_options(projection, options)) do
      case await_ready(peer_connection, options) do
        :ok ->
          {:ok, peer_connection}

        {:error, :peer_connection_unavailable} ->
          stop(peer_connection)
          {:error, :peer_connection_unavailable}
      end
    else
      _failure -> {:error, :peer_connection_unavailable}
    end
  rescue
    _error -> {:error, :peer_connection_unavailable}
  catch
    :exit, _reason -> {:error, :peer_connection_unavailable}
  end

  @spec stop(pid()) :: :ok
  def stop(peer_connection) do
    PeerConnection.stop(peer_connection)
  catch
    :exit, _reason -> :ok
  end

  defp connection_options(projection, options) do
    options
    |> Keyword.merge(
      ice_servers: projection.ice_servers,
      ice_transport_policy: projection.transport_policy
    )
    |> maybe_put_option(:host_to_srflx_ip_mapper, projection.host_to_srflx_ip_mapper)
    |> maybe_put_option(:ice_port_range, projection.udp_port_range)
    |> Keyword.put_new(:controlling_process, self())
  end

  defp maybe_put_option(options, _key, nil), do: options
  defp maybe_put_option(options, key, value), do: Keyword.put(options, key, value)

  defp await_ready(peer_connection, options) do
    :ok = await_test_readiness_gate(options)
    _ = GenServer.call(peer_connection, :get_transceivers, @startup_timeout_ms)
    :ok
  rescue
    _error -> {:error, :peer_connection_unavailable}
  catch
    :exit, _reason -> {:error, :peer_connection_unavailable}
  end

  defp await_test_readiness_gate(options) do
    if @test_environment do
      case Keyword.get(options, :test_readiness_gate) do
        {observer, reference} when is_pid(observer) and is_reference(reference) ->
          send(observer, {:peer_connection_starting, reference, self()})

          receive do
            {:release_peer_connection_start, ^reference} -> :ok
          after
            @startup_timeout_ms -> {:error, :peer_connection_unavailable}
          end

        _missing_gate ->
          :ok
      end
    else
      :ok
    end
  end
end
