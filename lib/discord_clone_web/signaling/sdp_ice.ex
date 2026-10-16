defmodule DiscordCloneWeb.Signaling.SdpIce do
  @moduledoc false

  @max_sdp_bytes 64 * 1024
  @max_candidate_bytes 8 * 1024

  @spec offer(map()) ::
          {:ok, %{negotiation_id: String.t(), description: map(), byte_count: non_neg_integer()}}
          | {:error, String.t()}
  def offer(payload) when is_map(payload) do
    with {:ok, negotiation_id} <- negotiation_id(payload),
         {:ok, description} <- description(payload) do
      {:ok,
       %{
         negotiation_id: negotiation_id,
         description: description,
         byte_count: byte_size(description["sdp"])
       }}
    end
  end

  def offer(_payload), do: {:error, "invalid_offer"}

  @spec ice_candidate(map()) ::
          {:ok, %{negotiation_id: String.t(), candidate: map(), byte_count: non_neg_integer()}}
          | {:end_of_candidates, %{negotiation_id: String.t(), byte_count: non_neg_integer()}}
          | {:error, String.t()}
  def ice_candidate(payload) when is_map(payload) do
    with {:ok, negotiation_id} <- negotiation_id(payload) do
      case payload do
        %{"end_of_candidates" => true} ->
          {:end_of_candidates, %{negotiation_id: negotiation_id, byte_count: 0}}

        _other ->
          with {:ok, candidate} <- candidate(Map.get(payload, "candidate")) do
            {:ok,
             %{
               negotiation_id: negotiation_id,
               candidate: candidate,
               byte_count: Jason.encode!(candidate) |> byte_size()
             }}
          end
      end
    end
  end

  def ice_candidate(_payload), do: {:error, "invalid_candidate"}

  @spec only_fields?(map(), [String.t()]) :: :ok | {:error, String.t()}
  def only_fields?(payload, fields) when is_map(payload) and is_list(fields) do
    if Map.keys(payload) |> MapSet.new() |> MapSet.subset?(MapSet.new(fields)),
      do: :ok,
      else: {:error, "invalid_payload"}
  end

  defp negotiation_id(%{"negotiation_id" => negotiation_id})
       when is_binary(negotiation_id) and byte_size(negotiation_id) > 0,
       do: {:ok, negotiation_id}

  defp negotiation_id(_payload), do: {:error, "invalid_negotiation"}

  defp description(%{"description" => %{"type" => "offer", "sdp" => sdp} = description})
       when is_binary(sdp) do
    with :ok <- only_fields?(description, ["type", "sdp"]),
         :ok <- maximum_size?(byte_size(sdp), @max_sdp_bytes, "description_too_large") do
      {:ok, description}
    end
  end

  defp description(_payload), do: {:error, "invalid_offer"}

  defp candidate(%{"candidate" => candidate_value} = candidate) when is_binary(candidate_value) do
    with :ok <-
           only_fields?(candidate, ["candidate", "sdpMid", "sdpMLineIndex", "usernameFragment"]),
         :ok <- candidate_fields?(candidate),
         :ok <-
           maximum_size?(
             candidate |> Jason.encode!() |> byte_size(),
             @max_candidate_bytes,
             "candidate_too_large"
           ) do
      {:ok, Map.put_new(candidate, "usernameFragment", nil)}
    end
  end

  defp candidate(_payload), do: {:error, "invalid_candidate"}

  defp candidate_fields?(%{"sdpMid" => sdp_mid, "sdpMLineIndex" => index} = candidate)
       when (is_binary(sdp_mid) or is_nil(sdp_mid)) and
              ((is_integer(index) and index >= 0) or is_nil(index)) do
    case Map.get(candidate, "usernameFragment") do
      value when is_binary(value) or is_nil(value) -> :ok
      _value -> {:error, "invalid_candidate"}
    end
  end

  defp candidate_fields?(_candidate), do: {:error, "invalid_candidate"}

  defp maximum_size?(size, maximum, _error_code) when size <= maximum, do: :ok
  defp maximum_size?(_size, _maximum, error_code), do: {:error, error_code}
end
