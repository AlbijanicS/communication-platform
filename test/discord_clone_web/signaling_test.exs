defmodule DiscordCloneWeb.SignalingTest do
  use ExUnit.Case, async: true

  alias DiscordCloneWeb.Signaling

  test "counts encoded JSON bytes and returns nil when encoding fails" do
    assert Signaling.decoded_request_byte_count(%{}) == 2
    assert Signaling.decoded_request_byte_count(%{"a" => 1}) == byte_size(~s({"a":1}))
    assert Signaling.decoded_request_byte_count(self()) == nil
  end
end
