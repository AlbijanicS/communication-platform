defmodule DiscordClone.Voice.ICEConfigurationResolverTest do
  use ExUnit.Case, async: false

  import DiscordClone.VoiceICEConfigurationHelpers
  import ExUnit.CaptureLog

  alias DiscordClone.Voice.{
    FakeICEProvider,
    ICEConfigurationResolver,
    ServerICEProjection,
    SessionICEBundle
  }

  setup do
    :ok = preserve_voice_ice_configuration()
  end

  test "disabled mode returns local projections without invoking a provider" do
    Application.put_env(:discord_clone, ICEConfigurationResolver,
      mode: :disabled,
      provider: FakeICEProvider,
      provider_options: [observer: self(), results: {:error, :unavailable}]
    )

    assert {:ok,
            %SessionICEBundle{
              mode: :disabled,
              browser_projection: %{ice_servers: [], ice_transport_policy: "all"},
              server_projection: %ServerICEProjection{
                ice_servers: [],
                transport_policy: :all
              },
              expires_at: nil
            }} = ICEConfigurationResolver.resolve()

    refute_receive {:voice_ice_provider_requested, _options}
  end

  test "static validation accepts disabled mode without contacting a provider" do
    Application.put_env(:discord_clone, ICEConfigurationResolver,
      mode: :disabled,
      provider: FakeICEProvider,
      provider_options: [observer: self(), results: {:error, :unavailable}]
    )

    assert :ok = ICEConfigurationResolver.validate_static_configuration()
    refute_receive {:voice_ice_provider_requested, _options}
  end

  test "static validation rejects incomplete hosted configuration without contacting a provider" do
    invalid_configurations = [
      [:invalid],
      [stun_urls: ["stun:stun.example.test:3478"], provider: FakeICEProvider],
      [mode: :unknown],
      [mode: :standard, mode: :disabled],
      [mode: :standard],
      [
        mode: :standard,
        stun_urls: ["https://stun.example.test"],
        provider: FakeICEProvider,
        provider_secret: "durable-secret"
      ],
      [
        mode: :standard,
        stun_urls: ["stun:stun.example.test:3478"],
        provider: String,
        provider_secret: "durable-secret"
      ],
      [
        mode: :standard,
        stun_urls: ["stun:stun.example.test:3478"],
        provider: FakeICEProvider,
        provider_secret: ""
      ],
      [
        mode: :standard,
        stun_urls: ["stun:stun.example.test:3478"],
        provider: FakeICEProvider,
        provider_secret: "durable-secret",
        provider_timeout_ms: 3_001
      ],
      [
        mode: :standard,
        stun_urls: ["stun:stun.example.test:3478"],
        provider: FakeICEProvider,
        provider_secret: "durable-secret",
        minimum_credential_lifetime_seconds: 0
      ],
      hosted_configuration(internal_ipv4: "not-an-ipv4"),
      hosted_configuration(internal_ipv4: "2001:db8::10"),
      hosted_configuration(internal_ipv4: "127.0.0.1"),
      hosted_configuration(external_ipv4: "999.51.100.24"),
      hosted_configuration(external_ipv4: "2001:db8::24"),
      hosted_configuration(external_ipv4: "10.20.0.24"),
      hosted_configuration(external_ipv4: "127.0.0.1"),
      hosted_configuration(external_ipv4: "224.0.0.1"),
      hosted_configuration(external_ipv4: "198.51.100.24"),
      hosted_configuration(udp_port_range: nil),
      hosted_configuration(udp_port_range: 50_031..50_000//-1),
      hosted_configuration(udp_port_range: 0..31),
      hosted_configuration(udp_port_range: 65_520..65_551),
      hosted_configuration(udp_port_range: 50_000..50_018),
      hosted_configuration(udp_port_range: 40_000..40_031),
      hosted_configuration(max_active_sessions: 0)
    ]

    for configuration <- invalid_configurations do
      Application.put_env(:discord_clone, ICEConfigurationResolver, configuration)

      assert {:error, :invalid_configuration} =
               ICEConfigurationResolver.validate_static_configuration()
    end

    refute_receive {:voice_ice_provider_requested, _options}
  end

  test "hosted modes project one exact IPv4 mapping and the configured UDP range" do
    for mode <- [:standard, :turn_only] do
      configure_hosted(
        mode,
        {:ok,
         standard_authorization(
           "temporary-user",
           "temporary-credential",
           future_expiry()
         )},
        stun_urls: if(mode == :turn_only, do: [], else: ["stun:stun.example.test:3478"])
      )

      assert :ok = ICEConfigurationResolver.validate_static_configuration()
      assert {:ok, %{server_projection: server_projection}} = ICEConfigurationResolver.resolve()

      assert server_projection.udp_port_range == 50_000..50_031

      mapper = server_projection.host_to_srflx_ip_mapper
      assert mapper.({10, 20, 0, 4}) == {34, 118, 200, 24}
      assert mapper.({127, 0, 0, 1}) == nil
      assert mapper.({172, 17, 0, 1}) == nil
      assert mapper.({10, 20, 0, 5}) == nil
      assert mapper.({8193, 3512, 0, 0, 0, 0, 0, 1}) == nil
    end
  end

  test "application startup rejects invalid static config without contacting the provider" do
    Application.put_env(:discord_clone, ICEConfigurationResolver,
      mode: :standard,
      stun_urls: ["stun:stun.example.test:3478"],
      provider: FakeICEProvider,
      provider_options: [observer: self(), results: {:error, :unavailable}]
    )

    assert {:error, {:invalid_voice_ice_configuration, :invalid_configuration}} =
             DiscordClone.Application.start(:normal, [])

    refute_receive {:voice_ice_provider_requested, _options}
  end

  test "application startup validation does not turn a provider outage into an app outage" do
    configure_standard({:error, :unavailable})

    assert {:error, {:already_started, supervisor}} =
             DiscordClone.Application.start(:normal, [])

    assert is_pid(supervisor)
    refute_receive {:voice_ice_provider_requested, _options}
  end

  test "standard mode creates browser and ExWebRTC projections from one provider authorization" do
    expires_at = future_expiry()

    configure_standard(
      {:ok,
       %{
         urls: [
           "turn:turn.example.test:53?transport=udp",
           "turn:turn.example.test:3478?transport=udp",
           "turn:turn.example.test:3478?transport=tcp",
           "turns:turn.example.test:5349?transport=tcp"
         ],
         username: "temporary-user",
         credential: "temporary-credential",
         expires_at: expires_at
       }}
    )

    assert {:ok,
            %SessionICEBundle{
              mode: :standard,
              browser_projection: browser_projection,
              server_projection: server_projection,
              expires_at: ^expires_at
            }} = ICEConfigurationResolver.resolve()

    assert_receive {:voice_ice_provider_requested, provider_options}
    assert provider_options[:secret] == "durable-provider-secret"
    refute_receive {:voice_ice_provider_requested, _options}

    assert browser_projection == %{
             ice_mode: "standard",
             ice_servers: [
               %{urls: ["stun:stun.example.test:3478"]},
               %{
                 urls: [
                   "turn:turn.example.test:53?transport=udp",
                   "turn:turn.example.test:3478?transport=udp",
                   "turn:turn.example.test:3478?transport=tcp",
                   "turns:turn.example.test:5349?transport=tcp"
                 ],
                 username: "temporary-user",
                 credential: "temporary-credential"
               }
             ],
             ice_transport_policy: "all"
           }

    assert %ServerICEProjection{
             ice_servers: [
               %{urls: ["stun:stun.example.test:3478"]},
               %{
                 urls: ["turn:turn.example.test:3478?transport=udp"],
                 username: "temporary-user",
                 credential: "temporary-credential"
               }
             ],
             transport_policy: :all
           } = server_projection
  end

  test "turn-only mode creates relay-only browser and UDP-only ExWebRTC projections" do
    expires_at = future_expiry()

    configure_hosted(
      :turn_only,
      {:ok,
       %{
         urls: [
           "turn:turn.example.test:3478?transport=udp",
           "turn:turn.example.test:3478?transport=tcp",
           "turns:turn.example.test:5349?transport=tcp"
         ],
         username: "temporary-user",
         credential: "temporary-credential",
         expires_at: expires_at
       }}
    )

    assert :ok = ICEConfigurationResolver.validate_static_configuration()

    assert {:ok,
            %SessionICEBundle{
              mode: :turn_only,
              browser_projection: browser_projection,
              server_projection: server_projection,
              expires_at: ^expires_at
            }} = ICEConfigurationResolver.resolve()

    assert browser_projection == %{
             ice_mode: "turn_only",
             ice_servers: [
               %{
                 urls: [
                   "turn:turn.example.test:3478?transport=udp",
                   "turn:turn.example.test:3478?transport=tcp",
                   "turns:turn.example.test:5349?transport=tcp"
                 ],
                 username: "temporary-user",
                 credential: "temporary-credential"
               }
             ],
             ice_transport_policy: "relay"
           }

    assert %ServerICEProjection{
             ice_servers: [
               %{
                 urls: ["turn:turn.example.test:3478?transport=udp"],
                 username: "temporary-user",
                 credential: "temporary-credential"
               }
             ],
             transport_policy: :relay
           } = server_projection
  end

  test "turn-only failures never fall back to another ICE mode" do
    for provider_result <- [
          {:error, :unavailable},
          {:ok, standard_authorization_with_urls([], "user", "credential")},
          {:ok,
           standard_authorization(
             "user",
             "credential",
             DateTime.utc_now()
           )}
        ] do
      configure_hosted(:turn_only, provider_result)

      assert {:error, reason} = ICEConfigurationResolver.resolve()
      assert reason in [:invalid_provider_response, :provider_unavailable]
    end
  end

  test "each standard resolution requests and returns fresh temporary authorization" do
    first =
      standard_authorization(
        "first-user",
        "first-credential",
        future_expiry(300)
      )

    second =
      standard_authorization(
        "second-user",
        "second-credential",
        future_expiry(600)
      )

    results = start_supervised!({Agent, fn -> [{:ok, first}, {:ok, second}] end})
    configure_standard(results)

    assert {:ok, first_bundle} = ICEConfigurationResolver.resolve()
    assert {:ok, second_bundle} = ICEConfigurationResolver.resolve()

    assert_receive {:voice_ice_provider_requested, _options}
    assert_receive {:voice_ice_provider_requested, _options}
    refute first_bundle.browser_projection == second_bundle.browser_projection
    assert first_bundle.expires_at == first.expires_at
    assert second_bundle.expires_at == second.expires_at
  end

  test "each turn-only resolution requests fresh temporary authorization" do
    first = standard_authorization("first-user", "first-credential", future_expiry(300))
    second = standard_authorization("second-user", "second-credential", future_expiry(600))

    results = start_supervised!({Agent, fn -> [{:ok, first}, {:ok, second}] end})
    configure_hosted(:turn_only, results)

    assert {:ok, first_bundle} = ICEConfigurationResolver.resolve()
    assert {:ok, second_bundle} = ICEConfigurationResolver.resolve()

    assert_receive {:voice_ice_provider_requested, _options}
    assert_receive {:voice_ice_provider_requested, _options}
    refute first_bundle.browser_projection == second_bundle.browser_projection
    assert first_bundle.mode == :turn_only
    assert second_bundle.mode == :turn_only
  end

  test "standard mode requires valid STUN and TURN services and bounds provider errors" do
    Application.put_env(:discord_clone, ICEConfigurationResolver,
      mode: :standard,
      stun_urls: [],
      provider: FakeICEProvider,
      provider_options: [observer: self(), results: {:error, :unavailable}]
    )

    assert {:error, :invalid_configuration} = ICEConfigurationResolver.resolve()
    refute_receive {:voice_ice_provider_requested, _options}

    configure_standard({:ok, standard_authorization_with_urls([], "user", "credential")})
    assert {:error, :invalid_provider_response} = ICEConfigurationResolver.resolve()

    for provider_error <- [:timeout, :transport_error, :unsuccessful_status, :unavailable] do
      configure_standard({:error, provider_error})
      assert {:error, :provider_unavailable} = ICEConfigurationResolver.resolve()
    end

    configure_standard({:error, :vendor_specific_failure})
    assert {:error, :provider_unavailable} = ICEConfigurationResolver.resolve()
  end

  test "standard mode rejects unexpected fields and credentials without enough remaining lifetime" do
    authorization =
      standard_authorization("temporary-user", "temporary-credential", future_expiry())

    configure_standard({:ok, Map.put(authorization, :provider_account_id, "forbidden-id")})
    assert {:error, :invalid_provider_response} = ICEConfigurationResolver.resolve()

    configure_standard({:ok, %{authorization | expires_at: DateTime.utc_now()}})
    assert {:error, :invalid_provider_response} = ICEConfigurationResolver.resolve()

    configure_standard({:ok, %{authorization | expires_at: future_expiry(30)}})
    assert {:error, :invalid_provider_response} = ICEConfigurationResolver.resolve()
  end

  test "standard mode permits one bounded provider attempt with no retry" do
    configure_standard(:wait_forever, provider_timeout_ms: 10)

    assert {:error, :provider_unavailable} = ICEConfigurationResolver.resolve()
    assert_receive {:voice_ice_provider_requested, _options}
    refute_receive {:voice_ice_provider_requested, _options}
  end

  test "provider failures expose neither durable nor temporary secrets in results or logs" do
    durable_secret = "forbidden-durable-provider-secret"
    temporary_username = "forbidden-temporary-username"
    temporary_credential = "forbidden-temporary-credential"
    provider_body = "forbidden-provider-response-body"

    Application.put_env(:discord_clone, ICEConfigurationResolver,
      mode: :standard,
      stun_urls: ["stun:stun.example.test:3478"],
      provider: FakeICEProvider,
      provider_secret: durable_secret,
      internal_ipv4: "10.20.0.4",
      external_ipv4: "34.118.200.24",
      udp_port_range: 50_000..50_031,
      max_active_sessions: 20,
      provider_options: [
        observer: self(),
        results:
          {:raise,
           Enum.join(
             [durable_secret, temporary_username, temporary_credential, provider_body],
             ":"
           )}
      ]
    )

    captured_logs =
      capture_log(fn ->
        assert {:error, :provider_unavailable} = ICEConfigurationResolver.resolve()
      end)

    refute captured_logs =~ durable_secret
    refute captured_logs =~ temporary_username
    refute captured_logs =~ temporary_credential
    refute captured_logs =~ provider_body
  end

  defp configure_standard(result_or_results, overrides \\ []) do
    configure_hosted(:standard, result_or_results, overrides)
  end

  defp configure_hosted(mode, result_or_results, overrides \\ []) do
    Application.put_env(
      :discord_clone,
      ICEConfigurationResolver,
      Keyword.merge(
        [
          mode: mode,
          stun_urls: if(mode == :turn_only, do: [], else: ["stun:stun.example.test:3478"]),
          provider: FakeICEProvider,
          provider_secret: "durable-provider-secret",
          provider_options: [observer: self(), results: result_or_results],
          internal_ipv4: "10.20.0.4",
          external_ipv4: "34.118.200.24",
          udp_port_range: 50_000..50_031,
          max_active_sessions: 20
        ],
        overrides
      )
    )
  end

  defp hosted_configuration(overrides) do
    Keyword.merge(
      [
        mode: :standard,
        stun_urls: ["stun:stun.example.test:3478"],
        provider: FakeICEProvider,
        provider_secret: "durable-secret",
        internal_ipv4: "10.20.0.4",
        external_ipv4: "34.118.200.24",
        udp_port_range: 50_000..50_031,
        max_active_sessions: 20
      ],
      overrides
    )
  end

  defp standard_authorization(
         username,
         credential,
         expires_at
       ) do
    standard_authorization_with_urls(
      ["turn:turn.example.test:3478?transport=udp"],
      username,
      credential,
      expires_at
    )
  end

  defp standard_authorization_with_urls(
         urls,
         username,
         credential,
         expires_at \\ future_expiry()
       ) do
    %{
      urls: urls,
      username: username,
      credential: credential,
      expires_at: expires_at
    }
  end

  defp future_expiry(seconds \\ 120), do: DateTime.add(DateTime.utc_now(), seconds, :second)
end
