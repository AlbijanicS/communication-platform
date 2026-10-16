defmodule DiscordCloneWeb.CallSignaling.Diagnostics do
  @moduledoc false

  @event [:discord_clone, :call_signaling, :operation]
  @operations MapSet.new(
                ~w(connect join projection start_call decline_call cancel_call accept_call leave_call media_credentials offer ice_candidate ice_route renew local_media_state unsupported_request termination)
              )
  @error_codes MapSet.new([
                 :unauthenticated,
                 :invalid_request,
                 :temporarily_unavailable,
                 :unsupported_event,
                 :not_found,
                 :not_friends,
                 :busy,
                 :rate_limited,
                 :stale,
                 :not_available,
                 :not_admitted,
                 :negotiation_failed,
                 :negotiation_already_active,
                 :invalid_negotiation,
                 :pending_candidate_limit_reached,
                 :candidate_limit_reached,
                 :candidate_rejected,
                 :end_of_candidates_unsupported,
                 :invalid_session
               ])

  @spec emit(String.t(), :accepted | :rejected | :failed, keyword()) :: :ok
  def emit(operation, outcome, opts \\ [])
      when is_binary(operation) and outcome in [:accepted, :rejected, :failed] do
    metadata =
      %{operation: normalize_operation(operation), outcome: outcome}
      |> maybe_put(:error_code, normalize_error(Keyword.get(opts, :error_code)))
      |> maybe_put(
        :decoded_request_byte_count,
        bounded_count(Keyword.get(opts, :decoded_request_byte_count))
      )

    measurements =
      maybe_put(%{}, :duration_ms, bounded_duration(Keyword.get(opts, :duration_ms)))

    :telemetry.execute(@event, measurements, metadata)
    :ok
  end

  defp normalize_operation(operation) do
    if MapSet.member?(@operations, operation), do: operation, else: "unsupported_request"
  end

  defp normalize_error(nil), do: nil

  defp normalize_error(error_code) do
    if MapSet.member?(@error_codes, error_code), do: error_code
  end

  defp bounded_count(count) when is_integer(count) and count >= 0, do: min(count, 65_536)
  defp bounded_count(_count), do: nil

  defp bounded_duration(duration) when is_integer(duration) and duration >= 0,
    do: min(duration, 60_000)

  defp bounded_duration(_duration), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
