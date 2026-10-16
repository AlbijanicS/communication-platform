defmodule DiscordClone.Media.ConnectionLayout do
  @moduledoc "Validates the named Voice and Direct Call offer layouts before provisioning."

  alias DiscordClone.Media.Profile
  alias ExWebRTC.SDPUtils

  @mid_uri "urn:ietf:params:rtp-hdrext:sdes:mid"
  @negotiated_extensions [
    @mid_uri,
    "urn:ietf:params:rtp-hdrext:sdes:rtp-stream-id",
    "urn:ietf:params:rtp-hdrext:sdes:repaired-rtp-stream-id",
    "http://www.ietf.org/id/draft-holmer-rmcat-transport-wide-cc-extensions-01"
  ]

  @spec validate(Profile.t(), map()) :: {:ok, map()} | {:error, atom()}
  def validate(profile, %{"type" => "offer", "sdp" => raw_sdp}) when is_binary(raw_sdp) do
    with true <- unambiguous_repair_parameters?(profile, raw_sdp),
         {:ok, sdp} <- ExSDP.parse(raw_sdp) do
      validate_media(profile, sdp.media)
    else
      false -> {:error, :incompatible_media}
      {:error, _reason} = error -> error
    end
  rescue
    _error -> {:error, :incompatible_media}
  end

  def validate(_profile, _description), do: {:error, :incompatible_media}

  # The pinned parser keeps only the last apt on each FMTP line. Reject the
  # ambiguity while both declarations are still visible; never rewrite SDP.
  defp unambiguous_repair_parameters?(%Profile{kind: :direct_call}, raw_sdp) do
    raw_sdp
    |> String.split(["\r\n", "\r", "\n"])
    |> Enum.all?(fn line ->
      case String.split(line, " ", parts: 2) do
        ["a=fmtp:" <> _pt, parameters] ->
          repair_count =
            parameters
            |> String.split(";")
            |> Enum.count(&String.starts_with?(String.trim(&1), "apt="))

          repair_count <= 1

        _other ->
          true
      end
    end)
  end

  defp unambiguous_repair_parameters?(_profile, _raw_sdp), do: true

  # Preserve Voice's existing tolerance and compatibility error distinction.
  defp validate_media(%Profile{kind: :voice} = profile, media) do
    compatible_audio = Enum.filter(media, &compatible?(&1, :audio, :opus))

    sources =
      Enum.filter(compatible_audio, &(SDPUtils.get_media_direction(&1) in [:sendonly, :sendrecv]))

    outputs = Enum.filter(compatible_audio, &(SDPUtils.get_media_direction(&1) == :recvonly))

    output_count =
      Enum.count(Profile.positions(profile), fn {_, direction, _} -> direction == :recvonly end)

    case {sources, outputs} do
      {[source], outputs} when length(outputs) == output_count ->
        {:ok, %{source_mid: mid(source), output_slot_mids: Enum.map(outputs, &mid/1)}}

      {[_source], _outputs} ->
        {:error, :incompatible_audio_output_slots}

      _incompatible ->
        {:error, :incompatible_media}
    end
  end

  defp validate_media(%Profile{kind: :direct_call} = profile, media) do
    positions = Profile.positions(profile)

    with true <- length(media) == length(positions),
         true <- Enum.all?(Enum.zip(media, positions), &valid_call_position?/1),
         mids = Enum.map(media, &mid/1),
         true <- Enum.uniq(mids) == mids,
         true <- valid_bundle_extensions?(media) do
      [audio_mid, video_mid] = mids
      {:ok, %{audio_mid: audio_mid, video_mid: video_mid}}
    else
      _invalid -> {:error, :incompatible_media}
    end
  end

  defp valid_call_position?({media, {kind, direction, codec}}) do
    directions =
      Enum.filter(media.attributes, &(&1 in [:sendonly, :recvonly, :sendrecv, :inactive]))

    compatible?(media, kind, codec) and
      valid_mid?(ExSDP.get_attributes(media, :mid)) and directions == [direction] and
      valid_codecs?(media, codec) and valid_extensions?(media)
  end

  defp valid_codecs?(media, primary) do
    codecs = SDPUtils.get_rtp_codec_parameters(media)
    payloads = Enum.map(codecs, & &1.payload_type)
    fmtps = ExSDP.get_attributes(media, :fmtp)

    Enum.uniq(payloads) == payloads and Enum.uniq(media.fmt) == media.fmt and
      MapSet.new(payloads) == MapSet.new(media.fmt) and
      Enum.all?(fmtps, &(&1.pt in payloads)) and
      Enum.uniq_by(fmtps, & &1.pt) == fmtps and
      valid_primary?(codecs, primary)
  end

  defp valid_primary?(codecs, :opus) do
    case Enum.filter(codecs, &(&1.mime_type == "audio/opus")) do
      [opus] -> codec?(opus, :opus)
      _ambiguous -> false
    end
  end

  defp valid_primary?(codecs, :vp8) do
    case Enum.filter(codecs, &(&1.mime_type == "video/VP8")) do
      [vp8] ->
        repair = Enum.filter(codecs, &(&1.mime_type == "video/rtx"))

        codec?(vp8, :vp8) and Enum.all?(repair, &valid_repair?(&1, codecs)) and
          length(Enum.filter(repair, &(&1.sdp_fmtp_line.apt == vp8.payload_type))) == 1 and
          Enum.all?([:nack, :pli], fn feedback ->
            Enum.any?(vp8.rtcp_fbs, &(&1.feedback_type == feedback))
          end)

      _ambiguous ->
        false
    end
  end

  defp valid_repair?(%{clock_rate: 90_000, sdp_fmtp_line: %{apt: apt}}, codecs) do
    Enum.any?(codecs, fn codec ->
      codec.payload_type == apt and codec.mime_type != "video/rtx" and
        codec.clock_rate == 90_000
    end)
  end

  defp valid_repair?(_repair, _codecs), do: false

  defp valid_extensions?(media) do
    extensions = ExSDP.get_attributes(media, :extmap)

    Enum.uniq_by(extensions, & &1.id) == extensions and
      Enum.uniq_by(extensions, & &1.uri) == extensions and
      Enum.any?(extensions, &(&1.uri == @mid_uri)) and
      Enum.all?(extensions, fn ext ->
        ext.id in 1..255 and
          (ext.uri not in @negotiated_extensions or ext.direction in [nil, :sendrecv])
      end)
  end

  defp valid_bundle_extensions?(media) do
    extensions = Enum.flat_map(media, &ExSDP.get_attributes(&1, :extmap))

    extensions
    |> Enum.group_by(& &1.id)
    |> Enum.all?(fn {_id, values} -> length(Enum.uniq_by(values, & &1.uri)) == 1 end)
  end

  defp valid_mid?([{:mid, mid}]), do: is_binary(mid) and byte_size(mid) > 0
  defp valid_mid?(_attributes), do: false

  defp compatible?(%{type: kind, port: port} = media, kind, codec) when port != 0 do
    media |> SDPUtils.get_rtp_codec_parameters() |> Enum.any?(&codec?(&1, codec))
  end

  defp compatible?(_media, _kind, _codec), do: false

  defp codec?(%{mime_type: "audio/opus", clock_rate: 48_000, channels: channels}, :opus),
    do: channels in [1, 2]

  defp codec?(%{mime_type: "video/VP8", clock_rate: 90_000}, :vp8), do: true
  defp codec?(_parameters, _codec), do: false

  defp mid(media) do
    {:mid, mid} = ExSDP.get_attribute(media, :mid)
    mid
  end
end
