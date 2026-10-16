defmodule DiscordClone.Media.CallVideoTransportTest do
  use ExUnit.Case, async: true

  alias DiscordClone.Media.CallVideoTransport

  test "only complete binding controls release relay credit, including across multiple candidates" do
    checks =
      for class <- [:request, :success_response, :error_response, :indication] do
        ExSTUN.Message.new(%ExSTUN.Message.Type{class: class, method: :binding})
        |> ExSTUN.Message.encode()
      end

    assert {:consumed, closed} = completion([relay(checks)])
    assert MapSet.size(closed) == 0

    binding = hd(checks)

    # These datagrams must keep the credit even beside valid connectivity
    # checks or on a different gathered relay than the selected media path.
    blocked = [
      <<0x80, 96, 0, 1, 0::64, 1, 2, 3>>,
      <<22, 254, 253, 0::104>>,
      <<1>>,
      binary_part(binding, 0, 19),
      binding <> <<0, 0, 0, 0>>,
      <<1::16, 4::16, 0x2112A442::32, 0::96>>,
      <<1::16, 4::16, 0x2112A442::32, 0::96, 1::16, 5::16>>,
      ExSTUN.Message.new(%ExSTUN.Message.Type{class: :indication, method: :send})
      |> ExSTUN.Message.encode()
    ]

    for packet <- blocked do
      assert :pending == completion([relay([binding, packet])])
      assert :pending == completion([relay(checks), relay([packet])])
    end
  end

  test "closed relay bytes are retired once while unknown layouts remain pending" do
    closed = %{relay([<<1>>]) | base: %{closed?: true}}
    assert {:consumed, ids} = completion([relay([]), closed])
    assert ids == MapSet.new([1])
    assert :pending == completion([%{relay([]) | buffered_packets: nil}])
    assert :pending == CallVideoTransport.completion({:ok, %{}})
  end

  defp relay(packets) do
    %ExICE.Priv.Candidate.Relay{
      base: %{closed?: false},
      client: nil,
      buffered_packets: Enum.map(packets, &{{192, 168, 1, 2}, 50_000, &1})
    }
  end

  defp completion(candidates) do
    CallVideoTransport.completion(
      {:ok,
       %{ice_agent: %{local_cands: Map.new(Enum.with_index(candidates), fn {c, i} -> {i, c} end)}}}
    )
  end
end
