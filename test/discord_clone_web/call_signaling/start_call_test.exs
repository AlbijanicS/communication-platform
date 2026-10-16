defmodule DiscordCloneWeb.CallSignaling.StartCallTest do
  use ExUnit.Case, async: true

  alias DiscordCloneWeb.CallSignaling.StartCall

  @signaling_session_id Ecto.UUID.generate()
  @direct_conversation_id Ecto.UUID.generate()

  test "accepts the exact three string fields and returns normalized values plus byte count" do
    payload = valid_payload()
    byte_count = encoded_size(payload)

    assert {:ok,
            %{
              signaling_session_id: @signaling_session_id,
              direct_conversation_id: @direct_conversation_id,
              media_intent: :audio,
              byte_count: ^byte_count
            }} = StartCall.validate(payload, @signaling_session_id)

    assert {:ok, %{media_intent: :video}} =
             StartCall.validate(
               valid_payload(%{"media_intent" => "video"}),
               @signaling_session_id
             )
  end

  test "rejects a non-object payload without interpreting fields" do
    assert {:error, :invalid_request, byte_count} =
             StartCall.validate(["start"], @signaling_session_id)

    assert byte_count == encoded_size(["start"])

    assert {:error, :invalid_request, _} = StartCall.validate(nil, @signaling_session_id)
    assert {:error, :invalid_request, _} = StartCall.validate("payload", @signaling_session_id)
    assert {:error, :invalid_request, _} = StartCall.validate(1, @signaling_session_id)
  end

  test "rejects extra or missing fields" do
    extra = valid_payload(%{"role" => "caller"})
    missing = Map.delete(valid_payload(), "media_intent")

    assert {:error, :invalid_request, byte_count} =
             StartCall.validate(extra, @signaling_session_id)

    assert byte_count == encoded_size(extra)
    assert {:error, :invalid_request, _} = StartCall.validate(missing, @signaling_session_id)
    assert {:error, :invalid_request, _} = StartCall.validate(%{}, @signaling_session_id)

    assert {:error, :invalid_request, _} =
             StartCall.validate(
               valid_payload(%{"user_id" => Ecto.UUID.generate()}),
               @signaling_session_id
             )
  end

  test "rejects forged, stale, missing, non-binary, and over-128-byte Signaling Session IDs" do
    stale = valid_payload(%{"signaling_session_id" => Ecto.UUID.generate()})
    forged = valid_payload(%{"signaling_session_id" => "forged-signaling"})
    too_long = valid_payload(%{"signaling_session_id" => String.duplicate("a", 129)})
    exact_limit = valid_payload(%{"signaling_session_id" => String.duplicate("b", 128)})

    assert {:error, :invalid_request, _} = StartCall.validate(stale, @signaling_session_id)
    assert {:error, :invalid_request, _} = StartCall.validate(forged, @signaling_session_id)

    assert {:error, :invalid_request, _} =
             StartCall.validate(
               valid_payload(%{"signaling_session_id" => 123}),
               @signaling_session_id
             )

    assert {:error, :invalid_request, _} =
             StartCall.validate(
               valid_payload() |> Map.delete("signaling_session_id"),
               @signaling_session_id
             )

    assert {:error, :invalid_request, _} = StartCall.validate(too_long, @signaling_session_id)

    assert {:ok, %{signaling_session_id: signaling_session_id}} =
             StartCall.validate(exact_limit, String.duplicate("b", 128))

    assert byte_size(signaling_session_id) == 128
  end

  test "rejects invalid Direct Conversation IDs without converting input to an atom" do
    assert {:error, :invalid_request, _} =
             StartCall.validate(
               valid_payload(%{"direct_conversation_id" => "not-a-uuid"}),
               @signaling_session_id
             )

    assert {:error, :invalid_request, _} =
             StartCall.validate(
               valid_payload(%{"direct_conversation_id" => 123}),
               @signaling_session_id
             )

    assert {:error, :invalid_request, _} =
             StartCall.validate(
               valid_payload(%{"direct_conversation_id" => :audio}),
               @signaling_session_id
             )
  end

  test "accepts only the JSON strings audio and video" do
    assert {:error, :invalid_request, _} =
             StartCall.validate(
               valid_payload(%{"media_intent" => "screen"}),
               @signaling_session_id
             )

    assert {:error, :invalid_request, _} =
             StartCall.validate(
               valid_payload(%{"media_intent" => "Audio"}),
               @signaling_session_id
             )

    assert {:error, :invalid_request, _} =
             StartCall.validate(valid_payload(%{"media_intent" => :audio}), @signaling_session_id)

    assert {:error, :invalid_request, _} =
             StartCall.validate(valid_payload(%{"media_intent" => 1}), @signaling_session_id)
  end

  test "rejects a 4096-byte extra-field payload after the size gate and a 4097-byte payload at the size gate" do
    exact = padded_payload(4096)
    over = padded_payload(4097)

    assert encoded_size(exact) == 4096
    assert encoded_size(over) == 4097

    assert {:error, :invalid_request, 4096} = StartCall.validate(exact, @signaling_session_id)
    assert {:error, :invalid_request, 4097} = StartCall.validate(over, @signaling_session_id)
  end

  test "does not include raw payload values in the error" do
    assert {:error, :invalid_request, byte_count} =
             StartCall.validate(
               valid_payload(%{"signaling_session_id" => "secret-session"}),
               @signaling_session_id
             )

    assert is_integer(byte_count)
    refute inspect({:error, :invalid_request, byte_count}) =~ "secret-session"
  end

  defp valid_payload(overrides \\ %{}) do
    Map.merge(
      %{
        "signaling_session_id" => @signaling_session_id,
        "direct_conversation_id" => @direct_conversation_id,
        "media_intent" => "audio"
      },
      overrides
    )
  end

  defp padded_payload(size) do
    probe = Map.put(valid_payload(), "pad", "")
    pad_size = size - encoded_size(probe)
    payload = Map.put(valid_payload(), "pad", String.duplicate("x", pad_size))
    assert encoded_size(payload) == size
    payload
  end

  defp encoded_size(payload), do: payload |> Jason.encode!() |> byte_size()
end
