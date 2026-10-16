defmodule DiscordCloneWeb.VoiceSignaling.RealMessageTest do
  use ExUnit.Case, async: true

  import DiscordCloneWeb.VoiceSignalingHelpers

  alias DiscordCloneWeb.VoiceSignaling.RealMessage

  describe "offer/1" do
    test "accepts a Voice-shaped offer" do
      description = %{"type" => "offer", "sdp" => "v=0"}

      assert {:ok,
              %{
                negotiation_id: "negotiation-1",
                description: ^description,
                byte_count: 3
              }} = RealMessage.offer(offer_payload(description: description))
    end

    test "allows a missing signaling session id at the field-validation boundary" do
      payload = Map.delete(offer_payload(), "signaling_session_id")

      assert {:ok, %{negotiation_id: "negotiation-1"}} = RealMessage.offer(payload)
    end

    test "rejects unknown top-level offer fields" do
      assert RealMessage.offer(Map.put(offer_payload(), "extra", true)) ==
               {:error, "invalid_payload"}
    end

    test "rejects a malformed offer before unknown top-level fields" do
      payload =
        offer_payload()
        |> Map.put("extra", true)
        |> Map.delete("negotiation_id")

      assert RealMessage.offer(payload) == {:error, "invalid_negotiation"}

      assert RealMessage.offer(Map.put(offer_payload(description: %{}), "extra", true)) ==
               {:error, "invalid_offer"}
    end
  end

  describe "ice_candidate/1" do
    test "accepts a Voice-shaped candidate" do
      candidate = browser_ice_candidate()
      byte_count = encoded_size(candidate)

      assert {:ok,
              %{
                negotiation_id: "negotiation-1",
                candidate: ^candidate,
                byte_count: ^byte_count
              }} = RealMessage.ice_candidate(candidate_payload(candidate: candidate))
    end

    test "rejects unknown top-level candidate fields" do
      assert RealMessage.ice_candidate(Map.put(candidate_payload(), "extra", true)) ==
               {:error, "invalid_payload"}
    end

    test "rejects a missing negotiation id before unknown fields" do
      payload =
        candidate_payload()
        |> Map.put("extra", true)
        |> Map.delete("negotiation_id")

      assert RealMessage.ice_candidate(payload) == {:error, "invalid_negotiation"}
    end

    test "rejects unknown fields on an end-of-candidates payload" do
      assert RealMessage.ice_candidate(Map.put(end_of_candidates_payload(), "extra", true)) ==
               {:error, "invalid_payload"}
    end

    test "treats end_of_candidates true as a marker even when a candidate is also present" do
      payload = Map.put(end_of_candidates_payload(), "candidate", browser_ice_candidate())

      assert RealMessage.ice_candidate(payload) == {:error, "invalid_payload"}
    end
  end

  defp offer_payload(opts \\ []) do
    %{
      "signaling_session_id" => Keyword.get(opts, :signaling_session_id, "signaling-1"),
      "negotiation_id" => Keyword.get(opts, :negotiation_id, "negotiation-1"),
      "description" => Keyword.get(opts, :description, %{"type" => "offer", "sdp" => "v=0"})
    }
  end

  defp candidate_payload(opts \\ []) do
    %{
      "signaling_session_id" => Keyword.get(opts, :signaling_session_id, "signaling-1"),
      "negotiation_id" => Keyword.get(opts, :negotiation_id, "negotiation-1"),
      "candidate" => Keyword.get(opts, :candidate, browser_ice_candidate())
    }
  end

  defp end_of_candidates_payload do
    %{
      "signaling_session_id" => "signaling-1",
      "negotiation_id" => "negotiation-1",
      "end_of_candidates" => true
    }
  end
end
