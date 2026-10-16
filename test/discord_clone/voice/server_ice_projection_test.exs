defmodule DiscordClone.Voice.ServerICEProjectionTest do
  use ExUnit.Case, async: true

  alias DiscordClone.Voice.ServerICEProjection

  test "rejects malformed ICE server URLs before admission" do
    assert {:error, :invalid_server_ice_projection} =
             ServerICEProjection.new(ice_servers: [%{urls: "stun:"}])
  end

  test "validates every provider-neutral server ICE field" do
    mapper = fn _host_address -> {203, 0, 113, 10} end

    assert {:ok, projection} =
             ServerICEProjection.new(
               ice_servers: [
                 %{urls: ["stun:stun.example.test:3478"]},
                 %{
                   urls: "turn:turn.example.test:3478?transport=udp",
                   username: "temporary-user",
                   credential: "temporary-credential"
                 }
               ],
               transport_policy: :relay,
               host_to_srflx_ip_mapper: mapper,
               udp_port_range: 50_000..50_031
             )

    assert projection.ice_servers == [
             %{urls: ["stun:stun.example.test:3478"]},
             %{
               urls: "turn:turn.example.test:3478?transport=udp",
               username: "temporary-user",
               credential: "temporary-credential"
             }
           ]

    assert projection.transport_policy == :relay
    assert projection.host_to_srflx_ip_mapper == mapper
    assert projection.udp_port_range == 50_000..50_031
  end

  test "uses an explicit disabled projection for local behavior" do
    assert %ServerICEProjection{
             ice_servers: [],
             transport_policy: :all,
             host_to_srflx_ip_mapper: nil,
             udp_port_range: nil
           } = ServerICEProjection.disabled()
  end

  test "rejects unsupported or incomplete option shapes" do
    invalid_options = [
      [transport_policy: :unknown],
      [host_to_srflx_ip_mapper: :not_a_function],
      [udp_port_range: 50_031..50_000//-1],
      [udp_port_range: 0..10],
      [ice_servers: [%{urls: []}]],
      [ice_servers: [%{urls: "turn:turn.example.test", username: "missing-credential"}]],
      [provider_payload: %{vendor: "not-part-of-the-projection"}]
    ]

    for options <- invalid_options do
      assert {:error, :invalid_server_ice_projection} = ServerICEProjection.new(options)
    end
  end
end
