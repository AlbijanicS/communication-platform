defmodule DiscordCloneWeb.Signaling.SdpIceTest do
  use ExUnit.Case, async: true

  import DiscordCloneWeb.VoiceSignalingHelpers

  alias DiscordCloneWeb.Signaling.SdpIce

  describe "offer/1" do
    test "accepts SDP field validation without a Voice envelope" do
      description = %{"type" => "offer", "sdp" => "v=0"}

      assert {:ok,
              %{
                negotiation_id: "negotiation-1",
                description: ^description,
                byte_count: 3
              }} =
               SdpIce.offer(%{"negotiation_id" => "negotiation-1", "description" => description})
    end

    test "ignores extra top-level envelope fields" do
      payload = %{
        "negotiation_id" => "negotiation-1",
        "description" => %{"type" => "offer", "sdp" => "v=0"},
        "signaling_session_id" => "signaling-1",
        "extra" => true
      }

      assert {:ok, %{negotiation_id: "negotiation-1", byte_count: 3}} = SdpIce.offer(payload)
    end

    test "accepts an SDP description of exactly 64 KiB and rejects one extra byte" do
      exact = String.duplicate("a", max_sdp_bytes())
      over = String.duplicate("a", max_sdp_bytes() + 1)

      assert {:ok, %{byte_count: byte_count}} =
               SdpIce.offer(%{
                 "negotiation_id" => "negotiation-1",
                 "description" => %{"type" => "offer", "sdp" => exact}
               })

      assert byte_count == max_sdp_bytes()

      assert SdpIce.offer(%{
               "negotiation_id" => "negotiation-1",
               "description" => %{"type" => "offer", "sdp" => over}
             }) == {:error, "description_too_large"}
    end

    test "rejects unknown description fields and malformed offers" do
      assert SdpIce.offer(%{
               "negotiation_id" => "negotiation-1",
               "description" => %{"type" => "offer", "sdp" => "v=0", "extra" => true}
             }) == {:error, "invalid_payload"}

      assert SdpIce.offer(%{"description" => %{"type" => "offer", "sdp" => "v=0"}}) ==
               {:error, "invalid_negotiation"}

      assert SdpIce.offer(%{
               "negotiation_id" => "negotiation-1",
               "description" => %{"type" => "answer", "sdp" => "v=0"}
             }) == {:error, "invalid_offer"}

      assert SdpIce.offer(nil) == {:error, "invalid_offer"}
    end
  end

  describe "ice_candidate/1" do
    test "accepts a candidate object and reports the encoded byte count" do
      candidate = browser_ice_candidate()
      byte_count = encoded_size(candidate)

      assert {:ok,
              %{
                negotiation_id: "negotiation-1",
                candidate: ^candidate,
                byte_count: ^byte_count
              }} =
               SdpIce.ice_candidate(%{
                 "negotiation_id" => "negotiation-1",
                 "candidate" => candidate
               })
    end

    test "defaults a missing username fragment to nil" do
      candidate = Map.delete(browser_ice_candidate(), "usernameFragment")

      assert {:ok, %{candidate: parsed}} =
               SdpIce.ice_candidate(%{
                 "negotiation_id" => "negotiation-1",
                 "candidate" => candidate
               })

      assert parsed["usernameFragment"] == nil
    end

    test "accepts nil sdpMid and sdpMLineIndex values" do
      candidate = %{browser_ice_candidate() | "sdpMid" => nil, "sdpMLineIndex" => nil}

      assert {:ok, %{candidate: ^candidate}} =
               SdpIce.ice_candidate(%{
                 "negotiation_id" => "negotiation-1",
                 "candidate" => candidate
               })
    end

    test "ignores extra top-level envelope fields for candidates and end-of-candidates" do
      assert {:ok, %{negotiation_id: "negotiation-1"}} =
               SdpIce.ice_candidate(%{
                 "negotiation_id" => "negotiation-1",
                 "candidate" => browser_ice_candidate(),
                 "signaling_session_id" => "signaling-1",
                 "extra" => true
               })

      assert SdpIce.ice_candidate(%{
               "negotiation_id" => "negotiation-1",
               "end_of_candidates" => true,
               "extra" => true
             }) == {:end_of_candidates, %{negotiation_id: "negotiation-1", byte_count: 0}}
    end

    test "accepts an encoded candidate of exactly 8 KiB and rejects one extra byte" do
      exact = candidate_with_encoded_size(max_candidate_bytes())
      over = candidate_with_encoded_size(max_candidate_bytes() + 1)

      assert {:ok, %{byte_count: byte_count}} =
               SdpIce.ice_candidate(%{
                 "negotiation_id" => "negotiation-1",
                 "candidate" => exact
               })

      assert byte_count == max_candidate_bytes()

      assert SdpIce.ice_candidate(%{
               "negotiation_id" => "negotiation-1",
               "candidate" => over
             }) == {:error, "candidate_too_large"}
    end

    test "rejects unknown candidate-object fields and malformed ICE" do
      assert SdpIce.ice_candidate(%{
               "negotiation_id" => "negotiation-1",
               "candidate" => Map.put(browser_ice_candidate(), "extra", true)
             }) == {:error, "invalid_payload"}

      assert SdpIce.ice_candidate(%{
               "negotiation_id" => "negotiation-1",
               "candidate" => Map.delete(browser_ice_candidate(), "sdpMid")
             }) == {:error, "invalid_candidate"}

      assert SdpIce.ice_candidate(nil) == {:error, "invalid_candidate"}
    end

    test "accepts the end-of-candidates marker with a zero byte count" do
      assert SdpIce.ice_candidate(%{
               "negotiation_id" => "negotiation-1",
               "end_of_candidates" => true
             }) == {:end_of_candidates, %{negotiation_id: "negotiation-1", byte_count: 0}}
    end
  end
end
