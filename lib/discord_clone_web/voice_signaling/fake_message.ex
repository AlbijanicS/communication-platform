defmodule DiscordCloneWeb.VoiceSignaling.FakeMessage do
  @moduledoc false

  @max_payload_bytes 4 * 1024
  @max_text_length 256
  @allowed_fields MapSet.new(["signaling_session_id", "label", "sequence"])

  @spec validate(map()) ::
          {:ok, %{label: String.t(), sequence: non_neg_integer()}} | {:error, map()}
  def validate(payload) when is_map(payload) do
    with :ok <- validate_payload_size(payload),
         :ok <- validate_allowed_fields(payload),
         {:ok, label} <- validate_label(payload),
         {:ok, sequence} <- validate_sequence(payload) do
      {:ok, %{label: label, sequence: sequence}}
    else
      {:error, field, message} -> {:error, %{field => message}}
    end
  end

  def validate(_payload), do: {:error, %{"payload" => "must be an object"}}

  defp validate_payload_size(payload) do
    if payload |> Jason.encode!() |> byte_size() <= @max_payload_bytes do
      :ok
    else
      {:error, "payload", "must be at most #{@max_payload_bytes} bytes"}
    end
  end

  defp validate_allowed_fields(payload) do
    if payload |> Map.keys() |> MapSet.new() |> MapSet.subset?(@allowed_fields) do
      :ok
    else
      {:error, "payload", "contains unsupported fields"}
    end
  end

  defp validate_label(%{"label" => label}) when is_binary(label) do
    if String.length(label) <= @max_text_length do
      {:ok, label}
    else
      {:error, "label", "must be at most #{@max_text_length} characters"}
    end
  end

  defp validate_label(%{"label" => _label}), do: {:error, "label", "must be a string"}
  defp validate_label(_payload), do: {:error, "label", "is required"}

  defp validate_sequence(%{"sequence" => sequence}) when is_integer(sequence) and sequence >= 0,
    do: {:ok, sequence}

  defp validate_sequence(%{"sequence" => _sequence}),
    do: {:error, "sequence", "must be a non-negative integer"}

  defp validate_sequence(_payload), do: {:error, "sequence", "is required"}
end
