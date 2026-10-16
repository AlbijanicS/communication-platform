defmodule DiscordCloneWeb.VoiceSignalingHelpers do
  import ExUnit.Assertions

  def max_sdp_bytes, do: 64 * 1024
  def max_candidate_bytes, do: 8 * 1024

  def browser_ice_candidate do
    %{
      "candidate" => "candidate:1 1 udp 1 127.0.0.1 9 typ host",
      "sdpMid" => "0",
      "sdpMLineIndex" => 0,
      "usernameFragment" => nil
    }
  end

  def candidate_with_encoded_size(size) do
    seed = %{
      "candidate" => "",
      "sdpMid" => "0",
      "sdpMLineIndex" => 0,
      "usernameFragment" => nil
    }

    padding = size - encoded_size(seed)
    candidate = %{seed | "candidate" => String.duplicate("a", padding)}
    assert encoded_size(candidate) == size
    candidate
  end

  def encoded_size(value), do: value |> Jason.encode!() |> byte_size()

  defmacro browser_offer(output_slot_count \\ 4) do
    quote do
      peer_connection =
        start_supervised!(%{
          id: make_ref(),
          restart: :temporary,
          start:
            {ExWebRTC.PeerConnection, :start_link,
             [[ice_servers: [], controlling_process: self()]]}
        })

      assert {:ok, _microphone_transceiver} =
               ExWebRTC.PeerConnection.add_transceiver(
                 peer_connection,
                 ExWebRTC.MediaStreamTrack.new(:audio),
                 direction: :sendonly
               )

      Enum.each(List.duplicate(:audio_output_slot, unquote(output_slot_count)), fn _slot ->
        assert {:ok, _audio_output_transceiver} =
                 ExWebRTC.PeerConnection.add_transceiver(
                   peer_connection,
                   :audio,
                   direction: :recvonly
                 )
      end)

      assert {:ok, description} = ExWebRTC.PeerConnection.create_offer(peer_connection)
      assert :ok = ExWebRTC.PeerConnection.set_local_description(peer_connection, description)
      serialized_description = ExWebRTC.SessionDescription.to_json(description)
      :ok = ExWebRTC.PeerConnection.stop(peer_connection)
      serialized_description
    end
  end
end
