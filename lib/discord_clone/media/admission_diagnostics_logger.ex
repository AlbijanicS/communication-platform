defmodule DiscordClone.Media.AdmissionDiagnosticsLogger do
  @moduledoc false

  use GenServer

  require Logger

  @event [:discord_clone, :media_admission, :operation]
  @handler_id {__MODULE__, :admission_diagnostics}

  def start_link(_options), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    case :telemetry.attach(@handler_id, @event, &__MODULE__.handle_event/4, nil) do
      :ok -> {:ok, nil}
      {:error, :already_exists} -> {:ok, nil}
    end
  end

  @impl true
  def terminate(_reason, _state) do
    :telemetry.detach(@handler_id)
    :ok
  end

  @doc false
  def handle_event(
        @event,
        measurements,
        %{operation: operation, outcome: outcome} = metadata,
        _config
      )
      when is_binary(operation) and outcome in [:accepted, :rejected, :failed] do
    duration = Map.get(measurements, :duration_ms)
    occupancy = Map.get(measurements, :occupancy)
    reservation_count = Map.get(measurements, :reservation_count)
    mailbox_len = Map.get(measurements, :mailbox_len)
    error_code = Map.get(metadata, :error_code)

    if allowlisted?(operation, duration, occupancy, reservation_count, mailbox_len, error_code) do
      Logger.log(outcome_level(outcome), fn ->
        "Media admission operation=#{operation} outcome=#{outcome}" <>
          maybe_part("error_code", error_code) <>
          maybe_part("duration_ms", duration) <>
          maybe_part("occupancy", occupancy) <>
          maybe_part("reservation_count", reservation_count) <>
          maybe_part("mailbox_len", mailbox_len)
      end)
    else
      :ok
    end
  end

  def handle_event(@event, _measurements, _metadata, _config), do: :ok

  defp allowlisted?(operation, duration, occupancy, reservation_count, mailbox_len, error_code) do
    operation in DiscordClone.Media.AdmissionDiagnostics.operations() and
      optional_bounded(duration, 60_000) and
      optional_bounded(occupancy, 1_000_000) and
      optional_bounded(reservation_count, 1_000_000) and
      optional_bounded(mailbox_len, 1_000_000) and
      (is_nil(error_code) or
         DiscordClone.Media.AdmissionDiagnostics.bound_error(error_code) == error_code)
  end

  defp optional_bounded(nil, _max), do: true

  defp optional_bounded(value, max) when is_integer(value) and value >= 0 and value <= max,
    do: true

  defp optional_bounded(_, _), do: false

  defp outcome_level(outcome) when outcome in [:rejected, :failed], do: :warning
  defp outcome_level(:accepted), do: :info

  defp maybe_part(_key, nil), do: ""
  defp maybe_part(key, value), do: " #{key}=#{value}"
end
