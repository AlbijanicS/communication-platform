defmodule DiscordCloneWeb.CallSignaling.ControlEnvelope do
  @moduledoc false

  alias DiscordCloneWeb.Signaling

  @max_payload_bytes 4 * 1024
  @max_signaling_session_id_bytes 128

  @spec open(term(), String.t(), [String.t()]) ::
          {:ok, map(), non_neg_integer()} | {:error, :invalid_request, non_neg_integer() | nil}
  def open(payload, expected_signaling_session_id, required_fields)
      when is_binary(expected_signaling_session_id) and is_list(required_fields) do
    case measured_byte_count(payload) do
      {:oversize, byte_count} ->
        {:error, :invalid_request, byte_count}

      {:ok, byte_count} ->
        finish_open(payload, expected_signaling_session_id, required_fields, byte_count)

      :error ->
        {:error, :invalid_request, nil}
    end
  end

  def open(_payload, _expected_signaling_session_id, _required_fields),
    do: {:error, :invalid_request, nil}

  @spec open_unbounded(term(), String.t(), [String.t()]) ::
          {:ok, map(), non_neg_integer()} | {:error, :invalid_request, non_neg_integer() | nil}
  def open_unbounded(payload, expected_signaling_session_id, required_fields)
      when is_binary(expected_signaling_session_id) and is_list(required_fields) do
    case Signaling.decoded_request_byte_count(payload) do
      byte_count when is_integer(byte_count) ->
        finish_open(payload, expected_signaling_session_id, required_fields, byte_count)

      nil ->
        {:error, :invalid_request, nil}
    end
  end

  def open_unbounded(_payload, _expected_signaling_session_id, _required_fields),
    do: {:error, :invalid_request, nil}

  defp finish_open(payload, expected_signaling_session_id, required_fields, byte_count) do
    with :ok <- require_object(payload),
         :ok <- require_exact_fields(payload, required_fields),
         :ok <- require_signaling_session_id(payload, expected_signaling_session_id) do
      {:ok, payload, byte_count}
    else
      :error -> {:error, :invalid_request, byte_count}
    end
  end

  defp measured_byte_count(payload) do
    case Signaling.decoded_request_byte_count(payload) do
      byte_count when is_integer(byte_count) and byte_count > @max_payload_bytes ->
        {:oversize, byte_count}

      byte_count when is_integer(byte_count) ->
        {:ok, byte_count}

      nil ->
        :error
    end
  end

  defp require_object(payload) when is_map(payload) and not is_struct(payload), do: :ok
  defp require_object(_payload), do: :error

  defp require_exact_fields(payload, required_fields) do
    if payload |> Map.keys() |> Enum.sort() == Enum.sort(required_fields), do: :ok, else: :error
  end

  defp require_signaling_session_id(
         %{"signaling_session_id" => signaling_session_id},
         expected_signaling_session_id
       )
       when is_binary(signaling_session_id) and
              byte_size(signaling_session_id) <= @max_signaling_session_id_bytes and
              signaling_session_id == expected_signaling_session_id,
       do: :ok

  defp require_signaling_session_id(_payload, _expected_signaling_session_id), do: :error
end
