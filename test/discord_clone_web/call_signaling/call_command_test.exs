defmodule DiscordCloneWeb.CallSignaling.CallCommandTest do
  use ExUnit.Case, async: true

  alias DiscordCloneWeb.CallSignaling.CallCommand

  @signaling_session_id Ecto.UUID.generate()
  @call_id Ecto.UUID.generate()

  test "accepts the exact two string fields and returns normalized values plus byte count" do
    payload = valid_payload()
    byte_count = encoded_size(payload)

    assert {:ok,
            %{
              signaling_session_id: @signaling_session_id,
              call_id: @call_id,
              byte_count: ^byte_count
            }} = CallCommand.validate(payload, @signaling_session_id, @call_id)
  end

  test "rejects a non-object payload without interpreting fields" do
    assert {:error, :invalid_request, byte_count} =
             CallCommand.validate(["decline"], @signaling_session_id, @call_id)

    assert byte_count == encoded_size(["decline"])

    assert {:error, :invalid_request, _} =
             CallCommand.validate(nil, @signaling_session_id, @call_id)

    assert {:error, :invalid_request, _} =
             CallCommand.validate("payload", @signaling_session_id, @call_id)

    assert {:error, :invalid_request, _} =
             CallCommand.validate(1, @signaling_session_id, @call_id)
  end

  test "rejects extra or missing fields including User identity and role" do
    extra = valid_payload(%{"role" => "recipient"})
    missing = Map.delete(valid_payload(), "call_id")

    assert {:error, :invalid_request, byte_count} =
             CallCommand.validate(extra, @signaling_session_id, @call_id)

    assert byte_count == encoded_size(extra)

    assert {:error, :invalid_request, _} =
             CallCommand.validate(missing, @signaling_session_id, @call_id)

    assert {:error, :invalid_request, _} =
             CallCommand.validate(%{}, @signaling_session_id, @call_id)

    assert {:error, :invalid_request, _} =
             CallCommand.validate(
               valid_payload(%{"user_id" => Ecto.UUID.generate()}),
               @signaling_session_id,
               @call_id
             )

    assert {:error, :invalid_request, _} =
             CallCommand.validate(
               valid_payload(%{"direct_conversation_id" => Ecto.UUID.generate()}),
               @signaling_session_id,
               @call_id
             )
  end

  test "rejects forged, stale, missing, non-binary, and over-128-byte Signaling Session IDs" do
    stale = valid_payload(%{"signaling_session_id" => Ecto.UUID.generate()})
    forged = valid_payload(%{"signaling_session_id" => "forged-signaling"})
    too_long = valid_payload(%{"signaling_session_id" => String.duplicate("a", 129)})
    exact_limit = valid_payload(%{"signaling_session_id" => String.duplicate("b", 128)})

    assert {:error, :invalid_request, _} =
             CallCommand.validate(stale, @signaling_session_id, @call_id)

    assert {:error, :invalid_request, _} =
             CallCommand.validate(forged, @signaling_session_id, @call_id)

    assert {:error, :invalid_request, _} =
             CallCommand.validate(
               valid_payload(%{"signaling_session_id" => 123}),
               @signaling_session_id,
               @call_id
             )

    assert {:error, :invalid_request, _} =
             CallCommand.validate(
               valid_payload() |> Map.delete("signaling_session_id"),
               @signaling_session_id,
               @call_id
             )

    assert {:error, :invalid_request, _} =
             CallCommand.validate(too_long, @signaling_session_id, @call_id)

    assert {:ok, %{signaling_session_id: signaling_session_id}} =
             CallCommand.validate(exact_limit, String.duplicate("b", 128), @call_id)

    assert byte_size(signaling_session_id) == 128
  end

  test "rejects a Call ID that is missing, malformed, or does not match the topic" do
    other_call_id = Ecto.UUID.generate()

    assert {:error, :invalid_request, _} =
             CallCommand.validate(
               valid_payload(%{"call_id" => other_call_id}),
               @signaling_session_id,
               @call_id
             )

    assert {:error, :invalid_request, _} =
             CallCommand.validate(
               valid_payload(%{"call_id" => "not-a-uuid"}),
               @signaling_session_id,
               @call_id
             )

    assert {:error, :invalid_request, _} =
             CallCommand.validate(
               valid_payload(%{"call_id" => 123}),
               @signaling_session_id,
               @call_id
             )

    assert {:ok, %{call_id: @call_id}} =
             CallCommand.validate(
               valid_payload(%{"call_id" => String.upcase(@call_id)}),
               @signaling_session_id,
               @call_id
             )
  end

  test "rejects a 4096-byte extra-field payload after the size gate and a 4097-byte payload at the size gate" do
    exact = padded_payload(4096)
    over = padded_payload(4097)

    assert encoded_size(exact) == 4096
    assert encoded_size(over) == 4097

    assert {:error, :invalid_request, 4096} =
             CallCommand.validate(exact, @signaling_session_id, @call_id)

    assert {:error, :invalid_request, 4097} =
             CallCommand.validate(over, @signaling_session_id, @call_id)
  end

  test "does not include raw payload values in the error" do
    assert {:error, :invalid_request, byte_count} =
             CallCommand.validate(
               valid_payload(%{"signaling_session_id" => "secret-session"}),
               @signaling_session_id,
               @call_id
             )

    assert is_integer(byte_count)
    refute inspect({:error, :invalid_request, byte_count}) =~ "secret-session"
    refute inspect({:error, :invalid_request, byte_count}) =~ @call_id
  end

  defp valid_payload(overrides \\ %{}) do
    Map.merge(
      %{
        "signaling_session_id" => @signaling_session_id,
        "call_id" => @call_id
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
