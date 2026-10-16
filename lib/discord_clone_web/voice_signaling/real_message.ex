defmodule DiscordCloneWeb.VoiceSignaling.RealMessage do
  @moduledoc false

  alias DiscordCloneWeb.Signaling.SdpIce

  @offer_fields ["signaling_session_id", "negotiation_id", "description"]
  @candidate_fields ["signaling_session_id", "negotiation_id", "candidate"]
  @end_of_candidates_fields ["signaling_session_id", "negotiation_id", "end_of_candidates"]

  @spec offer(map()) ::
          {:ok, %{negotiation_id: String.t(), description: map(), byte_count: non_neg_integer()}}
          | {:error, String.t()}
  def offer(payload) when is_map(payload) do
    with {:ok, offer} <- SdpIce.offer(payload),
         :ok <- SdpIce.only_fields?(payload, @offer_fields) do
      {:ok, offer}
    end
  end

  def offer(payload), do: SdpIce.offer(payload)

  @spec ice_candidate(map()) ::
          {:ok, %{negotiation_id: String.t(), candidate: map(), byte_count: non_neg_integer()}}
          | {:end_of_candidates, %{negotiation_id: String.t(), byte_count: non_neg_integer()}}
          | {:error, String.t()}
  def ice_candidate(payload) when is_map(payload) do
    with {tag, result} when tag in [:ok, :end_of_candidates] <- SdpIce.ice_candidate(payload),
         :ok <- SdpIce.only_fields?(payload, ice_fields(tag)) do
      {tag, result}
    end
  end

  def ice_candidate(payload), do: SdpIce.ice_candidate(payload)

  defp ice_fields(:ok), do: @candidate_fields
  defp ice_fields(:end_of_candidates), do: @end_of_candidates_fields
end
