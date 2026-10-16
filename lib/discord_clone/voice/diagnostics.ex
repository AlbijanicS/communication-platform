defmodule DiscordClone.Voice.Diagnostics do
  @moduledoc false

  @event [:discord_clone, :voice_signaling, :operation]

  @type outcome :: :accepted | :rejected | :failed

  @spec emit_ice_route(
          :disabled | :standard | :turn_only,
          :browser | :server,
          :host_direct | :reflexive_direct | :turn_relay | :unknown,
          :udp | :tcp | :tls | :unknown,
          outcome(),
          non_neg_integer(),
          keyword()
        ) :: :ok
  def emit_ice_route(
        ice_mode,
        endpoint,
        route_category,
        protocol,
        outcome,
        duration_ms,
        options \\ []
      )
      when ice_mode in [:disabled, :standard, :turn_only] and endpoint in [:browser, :server] and
             route_category in [:host_direct, :reflexive_direct, :turn_relay, :unknown] and
             protocol in [:udp, :tcp, :tls, :unknown] and
             outcome in [:accepted, :rejected, :failed] and is_integer(duration_ms) and
             duration_ms >= 0 and duration_ms <= 60_000 do
    metadata =
      %{
        operation: "ice_route",
        ice_mode: ice_mode,
        endpoint: endpoint,
        route_category: route_category,
        protocol: protocol,
        outcome: outcome
      }
      |> maybe_put(:error_code, bounded_ice_error(Keyword.get(options, :error_code)))

    :telemetry.execute(@event, %{duration_ms: duration_ms}, metadata)
  end

  @type media_counts :: %{
          inbound_packet_count: non_neg_integer(),
          forwarded_packet_count: non_neg_integer(),
          dropped_packet_count: non_neg_integer(),
          dropped_media_count: non_neg_integer()
        }

  @spec emit(String.t(), outcome(), keyword()) :: :ok
  def emit(operation, outcome, options \\ [])
      when operation in ["offer", "ice_candidate", "renew", "connection_state"] and
             outcome in [:accepted, :rejected, :failed] do
    metadata =
      %{operation: operation, outcome: outcome}
      |> maybe_put(:error_code, Keyword.get(options, :error_code))
      |> maybe_put(:decoded_request_byte_count, Keyword.get(options, :decoded_request_byte_count))
      |> maybe_put(:connection_state, Keyword.get(options, :connection_state))

    :telemetry.execute(@event, %{}, metadata)
  end

  @spec emit_media(
          :inbound_track_admitted
          | :inbound_track_muted
          | :inbound_track_ended
          | :unexpected_media_dropped
          | :rtp_received
          | :rtp_routed,
          media_counts()
        ) ::
          :ok
  def emit_media(lifecycle, counts)
      when lifecycle in [
             :inbound_track_admitted,
             :inbound_track_muted,
             :inbound_track_ended,
             :unexpected_media_dropped,
             :rtp_received,
             :rtp_routed
           ] do
    :telemetry.execute(@event, %{}, Map.put(counts, :media_lifecycle, lifecycle))
  end

  @spec emit_route(
          :rtp_forwarded | :rtp_dropped,
          %{
            forwarded_packet_count: non_neg_integer(),
            dropped_packet_count: non_neg_integer()
          }
        ) :: :ok
  def emit_route(lifecycle, counts) when lifecycle in [:rtp_forwarded, :rtp_dropped] do
    :telemetry.execute(@event, %{}, Map.put(counts, :media_lifecycle, lifecycle))
  end

  defp maybe_put(metadata, _key, nil), do: metadata
  defp maybe_put(metadata, key, value), do: Map.put(metadata, key, value)

  defp bounded_ice_error(error) when error in [:invalid_request, :stats_unavailable], do: error
  defp bounded_ice_error(_error), do: nil
end
