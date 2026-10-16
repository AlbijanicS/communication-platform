defmodule DiscordCloneWeb.CallSignaling.AcceptCallTest do
  use ExUnit.Case, async: true

  alias DiscordCloneWeb.CallSignaling.AcceptCall

  @signaling_session_id Ecto.UUID.generate()
  @call_id Ecto.UUID.generate()

  test "accepts the exact three string fields with either answer mode" do
    for {wire_mode, parsed_mode} <- [{"audio", :audio}, {"video", :video}] do
      payload = valid_payload(%{"answer_mode" => wire_mode})
      byte_count = encoded_size(payload)

      assert {:ok,
              %{
                signaling_session_id: @signaling_session_id,
                call_id: @call_id,
                answer_mode: ^parsed_mode,
                byte_count: ^byte_count
              }} = AcceptCall.validate(payload, @signaling_session_id, @call_id)
    end
  end

  test "rejects extra, missing, non-string, and wrongly cased answer modes" do
    extra = valid_payload(%{"role" => "recipient"})
    missing = Map.delete(valid_payload(), "answer_mode")

    assert {:error, :invalid_request, byte_count} =
             AcceptCall.validate(extra, @signaling_session_id, @call_id)

    assert byte_count == encoded_size(extra)

    assert {:error, :invalid_request, _} =
             AcceptCall.validate(missing, @signaling_session_id, @call_id)

    assert {:error, :invalid_request, _} =
             AcceptCall.validate(
               valid_payload(%{"answer_mode" => "AUDIO"}),
               @signaling_session_id,
               @call_id
             )

    assert {:error, :invalid_request, _} =
             AcceptCall.validate(
               valid_payload(%{"answer_mode" => :audio}),
               @signaling_session_id,
               @call_id
             )

    assert {:error, :invalid_request, _} =
             AcceptCall.validate(
               valid_payload(%{"answer_mode" => 1}),
               @signaling_session_id,
               @call_id
             )
  end

  test "rejects a non-object payload without interpreting fields" do
    assert {:error, :invalid_request, byte_count} =
             AcceptCall.validate(["accept"], @signaling_session_id, @call_id)

    assert byte_count == encoded_size(["accept"])

    assert {:error, :invalid_request, _} =
             AcceptCall.validate(nil, @signaling_session_id, @call_id)

    assert {:error, :invalid_request, _} =
             AcceptCall.validate("payload", @signaling_session_id, @call_id)
  end

  test "rejects forged, stale, missing, and extra identity fields" do
    stale = valid_payload(%{"signaling_session_id" => Ecto.UUID.generate()})
    other_call_id = Ecto.UUID.generate()

    assert {:error, :invalid_request, _} =
             AcceptCall.validate(stale, @signaling_session_id, @call_id)

    assert {:error, :invalid_request, _} =
             AcceptCall.validate(
               valid_payload(%{"call_id" => other_call_id}),
               @signaling_session_id,
               @call_id
             )

    assert {:error, :invalid_request, _} =
             AcceptCall.validate(
               valid_payload(%{"user_id" => Ecto.UUID.generate()}),
               @signaling_session_id,
               @call_id
             )

    assert {:error, :invalid_request, _} =
             AcceptCall.validate(%{}, @signaling_session_id, @call_id)
  end

  test "does not include raw payload values in the error" do
    assert {:error, :invalid_request, byte_count} =
             AcceptCall.validate(
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
        "call_id" => @call_id,
        "answer_mode" => "audio"
      },
      overrides
    )
  end

  defp encoded_size(payload), do: payload |> Jason.encode!() |> byte_size()
end
