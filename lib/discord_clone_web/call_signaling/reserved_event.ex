defmodule DiscordCloneWeb.CallSignaling.ReservedEvent do
  @moduledoc false

  alias DiscordCloneWeb.CallSignaling.ControlEnvelope
  alias DiscordCloneWeb.Signaling.SdpIce

  @max_opaque_id_bytes 128
  @renew_fields ["call_id", "call_session_id", "signaling_session_id"]
  @offer_fields [
    "call_id",
    "call_session_id",
    "description",
    "negotiation_id",
    "signaling_session_id"
  ]
  @candidate_fields [
    "call_id",
    "call_session_id",
    "candidate",
    "negotiation_id",
    "signaling_session_id"
  ]
  @end_of_candidates_fields [
    "call_id",
    "call_session_id",
    "end_of_candidates",
    "negotiation_id",
    "signaling_session_id"
  ]
  @ice_route_fields [
    "call_id",
    "call_session_id",
    "duration_ms",
    "protocol",
    "route_category",
    "signaling_session_id"
  ]
  @local_media_state_fields [
    "call_id",
    "call_session_id",
    "signaling_session_id",
    "negotiation_id",
    "media_state_version",
    "microphone_muted",
    "camera_enabled"
  ]
  @route_categories ~w(host_direct reflexive_direct turn_relay unknown)
  @route_protocols ~w(udp tcp tls unknown)

  @spec validate(String.t(), term(), String.t(), String.t()) ::
          {:ok, %{byte_count: non_neg_integer()}}
          | {:error, :invalid_request, non_neg_integer() | nil}
  def validate(event, payload, expected_signaling_session_id, expected_call_id)
      when is_binary(event) and is_binary(expected_signaling_session_id) and
             is_binary(expected_call_id) do
    case event do
      "offer" ->
        validate_offer(payload, expected_signaling_session_id, expected_call_id)

      "ice_candidate" ->
        validate_ice_candidate(payload, expected_signaling_session_id, expected_call_id)

      "ice_route" ->
        validate_ice_route(payload, expected_signaling_session_id, expected_call_id)

      "renew" ->
        validate_renew(payload, expected_signaling_session_id, expected_call_id)

      "local_media_state" ->
        validate_local_media_state(payload, expected_signaling_session_id, expected_call_id)

      _other ->
        {:error, :invalid_request, decoded_byte_count(payload)}
    end
  end

  def validate(_event, payload, _expected_signaling_session_id, _expected_call_id),
    do: {:error, :invalid_request, decoded_byte_count(payload)}

  defp validate_renew(payload, expected_signaling_session_id, expected_call_id) do
    finish_bounded(
      payload,
      expected_signaling_session_id,
      expected_call_id,
      @renew_fields,
      fn _payload -> :ok end
    )
  end

  defp validate_ice_route(payload, expected_signaling_session_id, expected_call_id) do
    finish_bounded(
      payload,
      expected_signaling_session_id,
      expected_call_id,
      @ice_route_fields,
      &require_ice_route_fields/1
    )
  end

  defp validate_local_media_state(payload, expected_signaling_session_id, expected_call_id) do
    finish_bounded(
      payload,
      expected_signaling_session_id,
      expected_call_id,
      @local_media_state_fields,
      &require_local_media_state_fields/1
    )
  end

  defp validate_offer(payload, expected_signaling_session_id, expected_call_id) do
    finish_unbounded(
      payload,
      expected_signaling_session_id,
      expected_call_id,
      @offer_fields,
      &require_offer_content/1
    )
  end

  defp validate_ice_candidate(payload, expected_signaling_session_id, expected_call_id) do
    finish_unbounded(
      payload,
      expected_signaling_session_id,
      expected_call_id,
      ice_candidate_fields(payload),
      &require_ice_content/1
    )
  end

  defp finish_bounded(
         payload,
         expected_signaling_session_id,
         expected_call_id,
         fields,
         extra_check
       ) do
    finish_open(
      ControlEnvelope.open(payload, expected_signaling_session_id, fields),
      expected_call_id,
      extra_check
    )
  end

  defp finish_unbounded(
         payload,
         expected_signaling_session_id,
         expected_call_id,
         fields,
         extra_check
       ) do
    finish_open(
      ControlEnvelope.open_unbounded(payload, expected_signaling_session_id, fields),
      expected_call_id,
      extra_check
    )
  end

  defp finish_open({:ok, payload, byte_count}, expected_call_id, extra_check) do
    with :ok <- require_media_identities(payload, expected_call_id),
         :ok <- extra_check.(payload) do
      {:ok, %{byte_count: byte_count}}
    else
      :error -> {:error, :invalid_request, byte_count}
    end
  end

  defp finish_open({:error, :invalid_request, byte_count}, _expected_call_id, _extra_check),
    do: {:error, :invalid_request, byte_count}

  defp require_media_identities(payload, expected_call_id) do
    with :ok <- require_matching_call_id(payload, expected_call_id) do
      require_optional_call_session_id(payload)
    end
  end

  defp require_matching_call_id(%{"call_id" => call_id}, expected_call_id) do
    case Ecto.UUID.cast(call_id) do
      {:ok, ^expected_call_id} -> :ok
      _other -> :error
    end
  end

  defp require_matching_call_id(_payload, _expected_call_id), do: :error

  defp require_optional_call_session_id(%{"call_session_id" => call_session_id}),
    do: require_opaque_id(call_session_id)

  defp require_optional_call_session_id(_payload), do: :ok

  defp require_opaque_id(value)
       when is_binary(value) and byte_size(value) > 0 and byte_size(value) <= @max_opaque_id_bytes,
       do: :ok

  defp require_opaque_id(_value), do: :error

  defp require_offer_content(payload) do
    case SdpIce.offer(payload) do
      {:ok, offer} -> require_opaque_id(offer.negotiation_id)
      {:error, _reason} -> :error
    end
  end

  defp require_ice_content(payload) do
    case {ice_candidate_fields(payload), SdpIce.ice_candidate(payload)} do
      {@candidate_fields, {:ok, ice}} ->
        require_opaque_id(ice.negotiation_id)

      {@end_of_candidates_fields, {:end_of_candidates, marker}} ->
        require_opaque_id(marker.negotiation_id)

      {_fields, _result} ->
        :error
    end
  end

  defp ice_candidate_fields(payload) when is_map(payload) do
    keys = payload |> Map.keys() |> Enum.sort()

    cond do
      keys == Enum.sort(@candidate_fields) -> @candidate_fields
      keys == Enum.sort(@end_of_candidates_fields) -> @end_of_candidates_fields
      true -> @candidate_fields
    end
  end

  defp ice_candidate_fields(_payload), do: @candidate_fields

  defp require_ice_route_fields(%{
         "route_category" => route_category,
         "protocol" => protocol,
         "duration_ms" => duration_ms
       })
       when route_category in @route_categories and protocol in @route_protocols and
              is_integer(duration_ms) and duration_ms >= 0 and duration_ms <= 60_000,
       do: :ok

  defp require_ice_route_fields(_payload), do: :error

  defp require_local_media_state_fields(%{
         "media_state_version" => version,
         "microphone_muted" => muted,
         "camera_enabled" => camera_enabled,
         "negotiation_id" => negotiation_id,
         "call_session_id" => session_id
       })
       when is_integer(version) and version >= 0 and version <= 9_007_199_254_740_991 and
              is_boolean(muted) and is_boolean(camera_enabled) do
    with :ok <- require_opaque_id(negotiation_id), do: require_opaque_id(session_id)
  end

  defp require_local_media_state_fields(_payload), do: :error

  defp decoded_byte_count(payload) do
    DiscordCloneWeb.Signaling.decoded_request_byte_count(payload)
  end
end
