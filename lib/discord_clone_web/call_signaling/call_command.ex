defmodule DiscordCloneWeb.CallSignaling.CallCommand do
  @moduledoc false

  alias DiscordCloneWeb.CallSignaling.ControlEnvelope

  @required_fields ["call_id", "signaling_session_id"]

  @spec validate(term(), String.t(), String.t()) ::
          {:ok,
           %{
             signaling_session_id: String.t(),
             call_id: Ecto.UUID.t(),
             byte_count: non_neg_integer()
           }}
          | {:error, :invalid_request, non_neg_integer() | nil}
  def validate(payload, expected_signaling_session_id, expected_call_id)
      when is_binary(expected_signaling_session_id) and is_binary(expected_call_id) do
    case ControlEnvelope.open(payload, expected_signaling_session_id, @required_fields) do
      {:ok, payload, byte_count} ->
        validate_fields(payload, expected_signaling_session_id, expected_call_id, byte_count)

      {:error, :invalid_request, byte_count} ->
        {:error, :invalid_request, byte_count}
    end
  end

  def validate(_payload, _expected_signaling_session_id, _expected_call_id),
    do: {:error, :invalid_request, nil}

  defp validate_fields(payload, expected_signaling_session_id, expected_call_id, byte_count) do
    case require_matching_call_id(payload, expected_call_id) do
      {:ok, call_id} ->
        {:ok,
         %{
           signaling_session_id: expected_signaling_session_id,
           call_id: call_id,
           byte_count: byte_count
         }}

      :error ->
        {:error, :invalid_request, byte_count}
    end
  end

  defp require_matching_call_id(%{"call_id" => call_id}, expected_call_id) do
    case Ecto.UUID.cast(call_id) do
      {:ok, ^expected_call_id} -> {:ok, expected_call_id}
      _other -> :error
    end
  end

  defp require_matching_call_id(_payload, _expected_call_id), do: :error
end
