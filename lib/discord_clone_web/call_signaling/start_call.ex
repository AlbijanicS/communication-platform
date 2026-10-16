defmodule DiscordCloneWeb.CallSignaling.StartCall do
  @moduledoc false

  alias DiscordCloneWeb.CallSignaling.ControlEnvelope

  @required_fields ["direct_conversation_id", "media_intent", "signaling_session_id"]

  @spec validate(term(), String.t()) ::
          {:ok,
           %{
             signaling_session_id: String.t(),
             direct_conversation_id: Ecto.UUID.t(),
             media_intent: :audio | :video,
             byte_count: non_neg_integer()
           }}
          | {:error, :invalid_request, non_neg_integer() | nil}

  def validate(payload, expected_signaling_session_id)
      when is_binary(expected_signaling_session_id) do
    case ControlEnvelope.open(payload, expected_signaling_session_id, @required_fields) do
      {:ok, payload, byte_count} ->
        validate_fields(payload, expected_signaling_session_id, byte_count)

      {:error, :invalid_request, byte_count} ->
        {:error, :invalid_request, byte_count}
    end
  end

  def validate(_payload, _expected_signaling_session_id), do: {:error, :invalid_request, nil}

  defp validate_fields(payload, expected_signaling_session_id, byte_count) do
    with {:ok, direct_conversation_id} <- require_direct_conversation_id(payload),
         {:ok, media_intent} <- require_media_intent(payload) do
      {:ok,
       %{
         signaling_session_id: expected_signaling_session_id,
         direct_conversation_id: direct_conversation_id,
         media_intent: media_intent,
         byte_count: byte_count
       }}
    else
      :error -> {:error, :invalid_request, byte_count}
    end
  end

  defp require_direct_conversation_id(%{"direct_conversation_id" => direct_conversation_id}) do
    Ecto.UUID.cast(direct_conversation_id)
  end

  defp require_direct_conversation_id(_payload), do: :error

  defp require_media_intent(%{"media_intent" => "audio"}), do: {:ok, :audio}
  defp require_media_intent(%{"media_intent" => "video"}), do: {:ok, :video}
  defp require_media_intent(_payload), do: :error
end
