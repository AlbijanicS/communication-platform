defmodule DiscordCloneWeb.CallSignaling.ReservedEventTest do
  use ExUnit.Case, async: true

  import DiscordCloneWeb.VoiceSignalingHelpers

  alias DiscordCloneWeb.CallSignaling.ReservedEvent

  @signaling_session_id Ecto.UUID.generate()
  @call_id Ecto.UUID.generate()
  @call_session_id "call-session-1"
  @negotiation_id "negotiation-1"

  test "accepts every exact well-formed reserved envelope" do
    for {event, payload} <- well_formed_envelopes() do
      byte_count = encoded_size(payload)

      assert {:ok, %{byte_count: ^byte_count}} =
               ReservedEvent.validate(event, payload, @signaling_session_id, @call_id)
    end
  end

  test "rejects non-map payloads, missing fields, extra fields, atom keys, and unencodable terms" do
    for event <- reserved_events() do
      payload = well_formed_payload(event)

      assert {:error, :invalid_request, byte_count} =
               ReservedEvent.validate(event, ["not-an-object"], @signaling_session_id, @call_id)

      assert byte_count == encoded_size(["not-an-object"])

      assert {:error, :invalid_request, _} =
               ReservedEvent.validate(event, nil, @signaling_session_id, @call_id)

      assert {:error, :invalid_request, _} =
               ReservedEvent.validate(event, "payload", @signaling_session_id, @call_id)

      assert {:error, :invalid_request, _} =
               ReservedEvent.validate(event, 1, @signaling_session_id, @call_id)

      extra = Map.put(payload, "role", "caller")

      assert {:error, :invalid_request, extra_count} =
               ReservedEvent.validate(event, extra, @signaling_session_id, @call_id)

      assert extra_count == encoded_size(extra)

      missing = payload |> Map.keys() |> List.first() |> then(&Map.delete(payload, &1))

      assert {:error, :invalid_request, _} =
               ReservedEvent.validate(event, missing, @signaling_session_id, @call_id)

      atom_keyed = Map.new(payload, fn {key, value} -> {String.to_atom(key), value} end)

      assert {:error, :invalid_request, _} =
               ReservedEvent.validate(event, atom_keyed, @signaling_session_id, @call_id)

      unencodable = Map.put(payload, hd(Map.keys(payload)), self())

      assert {:error, :invalid_request, nil} =
               ReservedEvent.validate(event, unencodable, @signaling_session_id, @call_id)
    end
  end

  test "rejects missing, forged, non-binary, empty, and over-128-byte Signaling Session IDs" do
    payload = renew_payload()
    too_long = renew_payload(%{"signaling_session_id" => String.duplicate("a", 129)})
    exact_limit = renew_payload(%{"signaling_session_id" => String.duplicate("b", 128)})

    assert {:error, :invalid_request, _} =
             ReservedEvent.validate(
               "renew",
               renew_payload(%{"signaling_session_id" => Ecto.UUID.generate()}),
               @signaling_session_id,
               @call_id
             )

    assert {:error, :invalid_request, _} =
             ReservedEvent.validate(
               "renew",
               renew_payload(%{"signaling_session_id" => "forged-signaling"}),
               @signaling_session_id,
               @call_id
             )

    assert {:error, :invalid_request, _} =
             ReservedEvent.validate(
               "renew",
               renew_payload(%{"signaling_session_id" => 123}),
               @signaling_session_id,
               @call_id
             )

    assert {:error, :invalid_request, _} =
             ReservedEvent.validate(
               "renew",
               renew_payload(%{"signaling_session_id" => ""}),
               @signaling_session_id,
               @call_id
             )

    assert {:error, :invalid_request, _} =
             ReservedEvent.validate(
               "renew",
               Map.delete(payload, "signaling_session_id"),
               @signaling_session_id,
               @call_id
             )

    assert {:error, :invalid_request, _} =
             ReservedEvent.validate("renew", too_long, @signaling_session_id, @call_id)

    assert {:ok, %{byte_count: byte_count}} =
             ReservedEvent.validate(
               "renew",
               exact_limit,
               String.duplicate("b", 128),
               @call_id
             )

    assert byte_count == encoded_size(exact_limit)
  end

  test "rejects missing, forged, empty, non-binary, and over-128-byte Call Session IDs" do
    payload = renew_payload()

    assert {:error, :invalid_request, _} =
             ReservedEvent.validate(
               "renew",
               renew_payload(%{"call_session_id" => ""}),
               @signaling_session_id,
               @call_id
             )

    assert {:error, :invalid_request, _} =
             ReservedEvent.validate(
               "renew",
               renew_payload(%{"call_session_id" => 123}),
               @signaling_session_id,
               @call_id
             )

    assert {:error, :invalid_request, _} =
             ReservedEvent.validate(
               "renew",
               Map.delete(payload, "call_session_id"),
               @signaling_session_id,
               @call_id
             )

    assert {:error, :invalid_request, _} =
             ReservedEvent.validate(
               "renew",
               renew_payload(%{"call_session_id" => String.duplicate("c", 129)}),
               @signaling_session_id,
               @call_id
             )

    exact = renew_payload(%{"call_session_id" => String.duplicate("d", 128)})

    assert {:ok, %{byte_count: byte_count}} =
             ReservedEvent.validate("renew", exact, @signaling_session_id, @call_id)

    assert byte_count == encoded_size(exact)
  end

  test "rejects missing, empty, non-binary, and over-128-byte negotiation IDs" do
    assert {:error, :invalid_request, _} =
             ReservedEvent.validate(
               "offer",
               offer_payload(%{"negotiation_id" => ""}),
               @signaling_session_id,
               @call_id
             )

    assert {:error, :invalid_request, _} =
             ReservedEvent.validate(
               "offer",
               offer_payload(%{"negotiation_id" => 123}),
               @signaling_session_id,
               @call_id
             )

    assert {:error, :invalid_request, _} =
             ReservedEvent.validate(
               "ice_candidate",
               ice_candidate_payload(%{"negotiation_id" => String.duplicate("n", 129)}),
               @signaling_session_id,
               @call_id
             )

    exact = offer_payload(%{"negotiation_id" => String.duplicate("n", 128)})

    assert {:ok, %{byte_count: byte_count}} =
             ReservedEvent.validate("offer", exact, @signaling_session_id, @call_id)

    assert byte_count == encoded_size(exact)
  end

  test "rejects a Call ID that is missing, malformed, or does not match the topic" do
    other_call_id = Ecto.UUID.generate()

    assert {:error, :invalid_request, _} =
             ReservedEvent.validate(
               "renew",
               renew_payload(%{"call_id" => other_call_id}),
               @signaling_session_id,
               @call_id
             )

    assert {:error, :invalid_request, _} =
             ReservedEvent.validate(
               "renew",
               renew_payload(%{"call_id" => "not-a-uuid"}),
               @signaling_session_id,
               @call_id
             )

    assert {:error, :invalid_request, _} =
             ReservedEvent.validate(
               "renew",
               renew_payload(%{"call_id" => 123}),
               @signaling_session_id,
               @call_id
             )

    assert {:ok, %{byte_count: _byte_count}} =
             ReservedEvent.validate(
               "renew",
               renew_payload(%{"call_id" => String.upcase(@call_id)}),
               @signaling_session_id,
               @call_id
             )
  end

  test "accepts an SDP description of exactly 64 KiB and rejects one extra byte" do
    exact =
      offer_payload(%{
        "description" => %{"type" => "offer", "sdp" => String.duplicate("a", max_sdp_bytes())}
      })

    over =
      offer_payload(%{
        "description" => %{"type" => "offer", "sdp" => String.duplicate("a", max_sdp_bytes() + 1)}
      })

    assert {:ok, %{byte_count: byte_count}} =
             ReservedEvent.validate("offer", exact, @signaling_session_id, @call_id)

    assert byte_count == encoded_size(exact)
    assert byte_count > 4 * 1024

    assert {:error, :invalid_request, over_count} =
             ReservedEvent.validate("offer", over, @signaling_session_id, @call_id)

    assert over_count == encoded_size(over)
  end

  test "accepts an encoded candidate of exactly 8 KiB and rejects one extra byte" do
    exact =
      ice_candidate_payload(%{"candidate" => candidate_with_encoded_size(max_candidate_bytes())})

    over =
      ice_candidate_payload(%{
        "candidate" => candidate_with_encoded_size(max_candidate_bytes() + 1)
      })

    assert {:ok, %{byte_count: byte_count}} =
             ReservedEvent.validate("ice_candidate", exact, @signaling_session_id, @call_id)

    assert byte_count == encoded_size(exact)

    assert {:error, :invalid_request, over_count} =
             ReservedEvent.validate("ice_candidate", over, @signaling_session_id, @call_id)

    assert over_count == encoded_size(over)
  end

  test "treats candidate and end-of-candidates shapes as mutually exclusive and exact" do
    both =
      ice_candidate_payload()
      |> Map.put("end_of_candidates", true)

    assert {:error, :invalid_request, _} =
             ReservedEvent.validate("ice_candidate", both, @signaling_session_id, @call_id)

    assert {:error, :invalid_request, _} =
             ReservedEvent.validate(
               "ice_candidate",
               end_of_candidates_payload(%{"end_of_candidates" => false}),
               @signaling_session_id,
               @call_id
             )

    assert {:error, :invalid_request, _} =
             ReservedEvent.validate(
               "ice_candidate",
               end_of_candidates_payload(%{"candidate" => browser_ice_candidate()}),
               @signaling_session_id,
               @call_id
             )

    assert {:ok, %{byte_count: _}} =
             ReservedEvent.validate(
               "ice_candidate",
               end_of_candidates_payload(),
               @signaling_session_id,
               @call_id
             )
  end

  test "rejects invalid nested description and candidate fields through the shared helper" do
    assert {:error, :invalid_request, _} =
             ReservedEvent.validate(
               "offer",
               offer_payload(%{"description" => %{"type" => "answer", "sdp" => "v=0"}}),
               @signaling_session_id,
               @call_id
             )

    assert {:error, :invalid_request, _} =
             ReservedEvent.validate(
               "offer",
               offer_payload(%{
                 "description" => %{"type" => "offer", "sdp" => "v=0", "extra" => true}
               }),
               @signaling_session_id,
               @call_id
             )

    assert {:error, :invalid_request, _} =
             ReservedEvent.validate(
               "ice_candidate",
               ice_candidate_payload(%{
                 "candidate" => Map.put(browser_ice_candidate(), "extra", true)
               }),
               @signaling_session_id,
               @call_id
             )

    assert {:error, :invalid_request, _} =
             ReservedEvent.validate(
               "ice_candidate",
               ice_candidate_payload(%{
                 "candidate" => Map.delete(browser_ice_candidate(), "sdpMid")
               }),
               @signaling_session_id,
               @call_id
             )
  end

  test "accepts ICE route enums and the 0 / 60_000 duration boundaries" do
    for route_category <- ["host_direct", "reflexive_direct", "turn_relay", "unknown"],
        protocol <- ["udp", "tcp", "tls", "unknown"] do
      payload =
        ice_route_payload(%{"route_category" => route_category, "protocol" => protocol})

      assert {:ok, %{byte_count: byte_count}} =
               ReservedEvent.validate("ice_route", payload, @signaling_session_id, @call_id)

      assert byte_count == encoded_size(payload)
    end

    for duration <- [0, 60_000] do
      payload = ice_route_payload(%{"duration_ms" => duration})

      assert {:ok, %{byte_count: _}} =
               ReservedEvent.validate("ice_route", payload, @signaling_session_id, @call_id)
    end

    assert {:error, :invalid_request, _} =
             ReservedEvent.validate(
               "ice_route",
               ice_route_payload(%{"route_category" => "direct"}),
               @signaling_session_id,
               @call_id
             )

    assert {:error, :invalid_request, _} =
             ReservedEvent.validate(
               "ice_route",
               ice_route_payload(%{"protocol" => "quic"}),
               @signaling_session_id,
               @call_id
             )

    assert {:error, :invalid_request, _} =
             ReservedEvent.validate(
               "ice_route",
               ice_route_payload(%{"duration_ms" => -1}),
               @signaling_session_id,
               @call_id
             )

    assert {:error, :invalid_request, _} =
             ReservedEvent.validate(
               "ice_route",
               ice_route_payload(%{"duration_ms" => 60_001}),
               @signaling_session_id,
               @call_id
             )

    assert {:error, :invalid_request, _} =
             ReservedEvent.validate(
               "ice_route",
               ice_route_payload(%{"duration_ms" => 1.5}),
               @signaling_session_id,
               @call_id
             )
  end

  test "accepts renewal's exact small envelope and rejects a 4 KiB extra-field control payload" do
    payload = renew_payload()
    byte_count = encoded_size(payload)

    assert {:ok, %{byte_count: ^byte_count}} =
             ReservedEvent.validate("renew", payload, @signaling_session_id, @call_id)

    exact = padded_payload(payload, 4096)
    over = padded_payload(payload, 4097)

    assert {:error, :invalid_request, 4096} =
             ReservedEvent.validate("renew", exact, @signaling_session_id, @call_id)

    assert {:error, :invalid_request, 4097} =
             ReservedEvent.validate("renew", over, @signaling_session_id, @call_id)
  end

  test "requires complete boolean media state under a safe integer version and negotiated identity" do
    zero = local_media_state_payload(%{"media_state_version" => 0, "camera_enabled" => false})

    assert {:ok, %{byte_count: byte_count}} =
             ReservedEvent.validate("local_media_state", zero, @signaling_session_id, @call_id)

    assert byte_count == encoded_size(zero)

    maximum = local_media_state_payload(%{"media_state_version" => 9_007_199_254_740_991})

    assert {:ok, _} =
             ReservedEvent.validate("local_media_state", maximum, @signaling_session_id, @call_id)

    for {field, value} <- [
          {"media_state_version", 9_007_199_254_740_992},
          {"media_state_version", "1"},
          {"microphone_muted", nil},
          {"microphone_muted", "false"},
          {"camera_enabled", nil},
          {"negotiation_id", ""},
          {"negotiation_id", String.duplicate("x", 129)}
        ] do
      assert {:error, :invalid_request, _} =
               ReservedEvent.validate(
                 "local_media_state",
                 local_media_state_payload(%{field => value}),
                 @signaling_session_id,
                 @call_id
               )
    end

    for field <- Map.keys(local_media_state_payload()) do
      assert {:error, :invalid_request, _} =
               ReservedEvent.validate(
                 "local_media_state",
                 Map.delete(local_media_state_payload(), field),
                 @signaling_session_id,
                 @call_id
               )
    end

    assert {:error, :invalid_request, _} =
             ReservedEvent.validate(
               "local_media_state",
               local_media_state_payload(%{"media_state_version" => -1}),
               @signaling_session_id,
               @call_id
             )

    assert {:error, :invalid_request, _} =
             ReservedEvent.validate(
               "local_media_state",
               local_media_state_payload(%{"media_state_version" => 1.0}),
               @signaling_session_id,
               @call_id
             )

    assert {:error, :invalid_request, _} =
             ReservedEvent.validate(
               "local_media_state",
               local_media_state_payload(%{"camera_enabled" => "true"}),
               @signaling_session_id,
               @call_id
             )

    assert {:error, :invalid_request, _} =
             ReservedEvent.validate(
               "local_media_state",
               local_media_state_payload(%{"microphone_enabled" => true}),
               @signaling_session_id,
               @call_id
             )
  end

  test "does not include raw payload values in the error" do
    assert {:error, :invalid_request, byte_count} =
             ReservedEvent.validate(
               "offer",
               offer_payload(%{"signaling_session_id" => "secret-session"}),
               @signaling_session_id,
               @call_id
             )

    inspected = inspect({:error, :invalid_request, byte_count})
    refute inspected =~ "secret-session"
    refute inspected =~ @call_id
    refute inspected =~ "v=0"
  end

  defp reserved_events do
    [
      "offer",
      "ice_candidate",
      "ice_route",
      "renew",
      "local_media_state"
    ]
  end

  defp well_formed_envelopes do
    [
      {"offer", offer_payload()},
      {"ice_candidate", ice_candidate_payload()},
      {"ice_candidate", end_of_candidates_payload()},
      {"ice_route", ice_route_payload()},
      {"renew", renew_payload()},
      {"local_media_state", local_media_state_payload()}
    ]
  end

  defp well_formed_payload("offer"), do: offer_payload()
  defp well_formed_payload("ice_candidate"), do: ice_candidate_payload()
  defp well_formed_payload("ice_route"), do: ice_route_payload()
  defp well_formed_payload("renew"), do: renew_payload()
  defp well_formed_payload("local_media_state"), do: local_media_state_payload()

  defp media_base(overrides) do
    Map.merge(
      %{
        "signaling_session_id" => @signaling_session_id,
        "call_id" => @call_id,
        "call_session_id" => @call_session_id
      },
      overrides
    )
  end

  defp offer_payload(overrides \\ %{}) do
    media_base(
      Map.merge(
        %{
          "negotiation_id" => @negotiation_id,
          "description" => %{"type" => "offer", "sdp" => "v=0"}
        },
        overrides
      )
    )
  end

  defp ice_candidate_payload(overrides \\ %{}) do
    media_base(
      Map.merge(
        %{
          "negotiation_id" => @negotiation_id,
          "candidate" => browser_ice_candidate()
        },
        overrides
      )
    )
  end

  defp end_of_candidates_payload(overrides \\ %{}) do
    media_base(
      Map.merge(
        %{
          "negotiation_id" => @negotiation_id,
          "end_of_candidates" => true
        },
        overrides
      )
    )
  end

  defp ice_route_payload(overrides \\ %{}) do
    media_base(
      Map.merge(
        %{
          "route_category" => "host_direct",
          "protocol" => "udp",
          "duration_ms" => 12
        },
        overrides
      )
    )
  end

  defp renew_payload(overrides \\ %{}) do
    media_base(overrides)
  end

  defp local_media_state_payload(overrides \\ %{}) do
    media_base(
      Map.merge(
        %{
          "media_state_version" => 1,
          "camera_enabled" => true,
          "microphone_muted" => false,
          "negotiation_id" => "opaque-negotiation"
        },
        overrides
      )
    )
  end

  defp padded_payload(payload, size) do
    probe = Map.put(payload, "pad", "")
    pad_size = size - encoded_size(probe)
    padded = Map.put(payload, "pad", String.duplicate("x", pad_size))
    assert encoded_size(padded) == size
    padded
  end
end
