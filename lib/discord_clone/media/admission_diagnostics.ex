defmodule DiscordClone.Media.AdmissionDiagnostics do
  @moduledoc false

  @event [:discord_clone, :media_admission, :operation]

  @operations MapSet.new(
                ~w(reserve_pair commit_pair begin_pair_commit publish_pair_commit cleanup_active_pair cleanup_active_pair_for_call begin_voice_switch publish_voice_switch abort_voice_switch join unknown)
              )

  @error_codes MapSet.new([
                 :deployment_full,
                 :failed_capacity,
                 :room_full,
                 :reservation_conflict,
                 :target_unavailable,
                 :stale_prior,
                 :stale_reservation,
                 :stale_call,
                 :stale_switch,
                 :invalid_pair,
                 :recovering,
                 :recovery_timeout,
                 :not_connecting,
                 :not_found,
                 :stale,
                 :not_friends,
                 :concurrent_switch,
                 :unavailable
               ])

  @spec event() :: [atom()]
  def event, do: @event

  @spec operations() :: [String.t()]
  def operations, do: MapSet.to_list(@operations)

  @spec emit(String.t(), :accepted | :rejected | :failed, keyword()) :: :ok
  def emit(operation, outcome, opts \\ [])
      when is_binary(operation) and outcome in [:accepted, :rejected, :failed] do
    metadata =
      %{operation: normalize_operation(operation), outcome: outcome}
      |> maybe_put(:error_code, normalize_error(Keyword.get(opts, :error_code)))

    measurements =
      %{}
      |> maybe_put(:duration_ms, bounded_duration(Keyword.get(opts, :duration_ms)))
      |> maybe_put(:occupancy, bounded_count(Keyword.get(opts, :occupancy)))
      |> maybe_put(:reservation_count, bounded_count(Keyword.get(opts, :reservation_count)))
      |> maybe_put(:mailbox_len, bounded_count(Keyword.get(opts, :mailbox_len)))

    :telemetry.execute(@event, measurements, metadata)
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  @spec classify(term()) :: {:accepted | :rejected | :failed, atom() | nil}
  def classify({:ok, _}), do: {:accepted, nil}
  def classify(:ok), do: {:accepted, nil}
  def classify({:normal}), do: {:accepted, nil}
  def classify(:normal), do: {:accepted, nil}

  def classify({:error, %{reason: :deployment_full}}), do: {:rejected, :deployment_full}
  def classify({:error, %{reason: :failed_capacity}}), do: {:rejected, :failed_capacity}
  def classify({:error, :failed_capacity}), do: {:rejected, :failed_capacity}
  def classify({:error, %{reason: :room_full}}), do: {:rejected, :room_full}
  def classify({:error, %{reason: :reservation_conflict}}), do: {:rejected, :reservation_conflict}
  def classify({:error, :recovering}), do: {:rejected, :recovering}
  def classify({:error, :recovery_timeout}), do: {:rejected, :recovery_timeout}

  def classify({:error, %{reason: reason}}) when is_atom(reason),
    do: {:failed, bound_error(reason)}

  def classify({:error, reason}) when is_atom(reason), do: {:failed, bound_error(reason)}
  def classify(_), do: {:failed, nil}

  @spec bound_error(atom() | term()) :: atom() | nil
  def bound_error(error) when is_atom(error) do
    if MapSet.member?(@error_codes, error), do: error
  end

  def bound_error(_), do: nil

  defp normalize_operation(operation) do
    if MapSet.member?(@operations, operation), do: operation, else: "unknown"
  end

  defp normalize_error(nil), do: nil

  defp normalize_error(error) when is_atom(error) do
    if MapSet.member?(@error_codes, error), do: error
  end

  defp normalize_error(_), do: nil

  defp bounded_count(count) when is_integer(count) and count >= 0, do: min(count, 1_000_000)
  defp bounded_count(_), do: nil

  defp bounded_duration(duration) when is_integer(duration) and duration >= 0,
    do: min(duration, 60_000)

  defp bounded_duration(_), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
