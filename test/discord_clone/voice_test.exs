defmodule DiscordClone.VoiceTest do
  use DiscordClone.DataCase, async: false

  import DiscordClone.AccountsFixtures
  import DiscordClone.VoiceICEConfigurationHelpers
  import DiscordCloneWeb.VoiceSignalingHelpers

  alias DiscordClone.Accounts.Scope
  alias DiscordClone.Voice

  alias DiscordClone.Voice.{
    FakeICEProvider,
    Forwarder,
    ICEConfigurationResolver,
    RoomServer,
    ServerICEProjection,
    SessionSupervisor
  }

  setup do
    on_exit(fn ->
      DiscordClone.Voice.running_room_servers()
      |> Enum.each(fn {voice_channel_id, _room_server} ->
        :ok = Voice.end_channel_sessions(voice_channel_id)
        :ok = Voice.expire_idle_room(voice_channel_id)
      end)
    end)

    :ok
  end

  describe "room runtime lifecycle" do
    test "normalizes hosted provider failures before any Voice runtime starts" do
      :ok = preserve_voice_ice_configuration()

      Application.put_env(:discord_clone, ICEConfigurationResolver,
        mode: :standard,
        stun_urls: ["stun:stun.example.test:3478"],
        provider: FakeICEProvider,
        provider_secret: "forbidden-durable-provider-secret",
        internal_ipv4: "10.20.0.4",
        external_ipv4: "34.118.200.24",
        udp_port_range: 50_000..50_031,
        max_active_sessions: 20,
        provider_options: [
          observer: self(),
          results:
            {:ok,
             %{
               urls: ["turn:turn.example.test:3478?transport=udp"],
               username: "temporary-user",
               credential: "temporary-credential",
               expires_at: DateTime.add(DateTime.utc_now(), 30, :second)
             }}
        ]
      )

      voice_channel_id = Ecto.UUID.generate()
      user = user_fixture()

      assert {:error, :unavailable} =
               Voice.join_with_ice_configuration(
                 Scope.for_user(user),
                 voice_channel_id,
                 "provider-failure-session",
                 self()
               )

      assert_receive {:voice_ice_provider_requested, _options}
      refute Voice.room_running?(voice_channel_id)
      assert {:ok, %{members: []}} = Voice.voice_channel_roster(voice_channel_id)
    end

    test "negotiates and cleans up a standard bundle resolved through the provider boundary" do
      :ok = preserve_voice_ice_configuration()

      stun_url = start_test_stun_server({192, 0, 2, 88})

      Application.put_env(:discord_clone, ICEConfigurationResolver,
        mode: :standard,
        stun_urls: [stun_url],
        provider: FakeICEProvider,
        provider_secret: "durable-provider-secret",
        internal_ipv4: "10.20.0.4",
        external_ipv4: "34.118.200.24",
        udp_port_range: 50_000..50_031,
        max_active_sessions: 20,
        provider_options: [
          observer: self(),
          results:
            {:ok,
             %{
               urls: ["turn:127.0.0.1:9?transport=udp"],
               username: "temporary-user",
               credential: "temporary-credential",
               expires_at: DateTime.add(DateTime.utc_now(), 120, :second)
             }}
        ]
      )

      voice_channel_id = Ecto.UUID.generate()
      user = user_fixture()

      assert {:ok, %{voice_session_id: voice_session_id}, browser_projection} =
               Voice.join_with_ice_configuration(
                 Scope.for_user(user),
                 voice_channel_id,
                 "standard-ice-session",
                 self()
               )

      assert_receive {:voice_ice_provider_requested, _options}
      assert browser_projection.ice_transport_policy == "all"
      assert Enum.count(browser_projection.ice_servers) == 2

      assert [peer_connection] = ExWebRTC.PeerConnection.get_all_running()
      configuration = ExWebRTC.PeerConnection.get_configuration(peer_connection)
      assert configuration.ice_port_range == 50_000..50_031
      assert configuration.host_to_srflx_ip_mapper.({10, 20, 0, 4}) == {34, 118, 200, 24}
      assert configuration.host_to_srflx_ip_mapper.({127, 0, 0, 1}) == nil
      assert configuration.host_to_srflx_ip_mapper.({172, 17, 0, 1}) == nil
      assert configuration.host_to_srflx_ip_mapper.({10, 20, 0, 5}) == nil

      assert {:ok, %{"type" => "answer"}} =
               Voice.accept_offer(
                 Scope.for_user(user),
                 voice_channel_id,
                 voice_session_id,
                 "standard-ice-negotiation",
                 browser_offer()
               )

      stun_candidate =
        await_server_ice_candidate(
          voice_session_id,
          "standard-ice-negotiation",
          &String.contains?(&1["candidate"], " 192.0.2.88 ")
        )

      assert stun_candidate["candidate"] =~ " typ srflx "
      assert :ok = Voice.leave(voice_channel_id, voice_session_id)
      assert :ok = Voice.await_empty_room(voice_channel_id)
      assert {:ok, %{occupancy: 0, capacity: 5}} = Voice.room_occupancy(voice_channel_id)
    end

    test "threads TURN-only relay policy through public admission to the owned ExWebRTC peer" do
      :ok = preserve_voice_ice_configuration()

      Application.put_env(:discord_clone, ICEConfigurationResolver,
        mode: :turn_only,
        stun_urls: [],
        provider: FakeICEProvider,
        provider_secret: "durable-provider-secret",
        internal_ipv4: "10.20.0.4",
        external_ipv4: "34.118.200.24",
        udp_port_range: 50_000..50_031,
        max_active_sessions: 20,
        provider_options: [
          observer: self(),
          results:
            {:ok,
             %{
               urls: [
                 "turn:turn.example.test:3478?transport=udp",
                 "turn:turn.example.test:3478?transport=tcp",
                 "turns:turn.example.test:5349?transport=tcp"
               ],
               username: "temporary-user",
               credential: "temporary-credential",
               expires_at: DateTime.add(DateTime.utc_now(), 120, :second)
             }}
        ]
      )

      voice_channel_id = Ecto.UUID.generate()
      user = user_fixture()
      running_before = MapSet.new(ExWebRTC.PeerConnection.get_all_running())

      assert {:ok, %{voice_session_id: voice_session_id}, browser_projection} =
               Voice.join_with_ice_configuration(
                 Scope.for_user(user),
                 voice_channel_id,
                 "turn-only-session",
                 self()
               )

      assert browser_projection.ice_transport_policy == "relay"

      refute Enum.any?(browser_projection.ice_servers, fn server ->
               Enum.any?(List.wrap(server.urls), &String.starts_with?(&1, "stun:"))
             end)

      assert [peer_connection] =
               ExWebRTC.PeerConnection.get_all_running()
               |> Enum.reject(&MapSet.member?(running_before, &1))

      configuration = ExWebRTC.PeerConnection.get_configuration(peer_connection)
      assert configuration.ice_transport_policy == :relay

      assert [server] = configuration.ice_servers
      assert server.urls == ["turn:turn.example.test:3478?transport=udp"]

      peer_monitor = Process.monitor(peer_connection)
      assert :ok = Voice.leave(voice_channel_id, voice_session_id)
      assert_receive {:DOWN, ^peer_monitor, :process, ^peer_connection, _reason}
      assert :ok = Voice.await_empty_room(voice_channel_id)
    end

    test "threads one server ICE projection through public admission to ExWebRTC" do
      voice_channel_id = Ecto.UUID.generate()
      user = user_fixture()
      stun_url = start_test_stun_server({192, 0, 2, 77})

      assert {:ok, server_ice_projection} =
               ServerICEProjection.new(
                 ice_servers: [%{urls: stun_url}],
                 transport_policy: :all,
                 host_to_srflx_ip_mapper: fn _host_address -> {203, 0, 113, 10} end,
                 udp_port_range: 50_000..50_031
               )

      assert {:ok, %{voice_session_id: voice_session_id}} =
               Voice.join(
                 voice_channel_id,
                 user.id,
                 "configured-ice-session",
                 self(),
                 server_ice_projection
               )

      assert {:ok, %{"type" => "answer"}} =
               Voice.accept_offer(
                 Scope.for_user(user),
                 voice_channel_id,
                 voice_session_id,
                 "configured-ice-negotiation",
                 browser_offer()
               )

      candidate =
        await_server_ice_candidate(
          voice_session_id,
          "configured-ice-negotiation",
          &String.contains?(&1["candidate"], " 203.0.113.10 ")
        )

      assert candidate["candidate"] =~ " 203.0.113.10 "

      assert [port] =
               Regex.run(~r/ 203\.0\.113\.10 (\d+) typ srflx/, candidate["candidate"],
                 capture: :all_but_first
               )

      assert String.to_integer(port) in 50_000..50_031

      stun_candidate =
        await_server_ice_candidate(
          voice_session_id,
          "configured-ice-negotiation",
          &String.contains?(&1["candidate"], " 192.0.2.77 ")
        )

      assert stun_candidate["candidate"] =~ " 192.0.2.77 "
      assert stun_candidate["candidate"] =~ " typ srflx "
    end

    test "preserves disabled all-candidate negotiation and applies relay-only policy" do
      disabled_voice_channel_id = Ecto.UUID.generate()
      disabled_user = user_fixture()

      assert {:ok, %{voice_session_id: disabled_voice_session_id}} =
               Voice.join(
                 disabled_voice_channel_id,
                 disabled_user.id,
                 "disabled-ice-session",
                 self()
               )

      assert {:ok, %{"type" => "answer"}} =
               Voice.accept_offer(
                 Scope.for_user(disabled_user),
                 disabled_voice_channel_id,
                 disabled_voice_session_id,
                 "disabled-ice-negotiation",
                 browser_offer()
               )

      disabled_candidates =
        collect_server_ice_candidates(
          disabled_voice_session_id,
          "disabled-ice-negotiation"
        )

      assert disabled_candidates != []

      assert Enum.all?(disabled_candidates, fn candidate ->
               candidate["candidate"] =~ " typ host"
             end)

      relay_voice_channel_id = Ecto.UUID.generate()
      relay_user = user_fixture()

      assert {:ok, relay_projection} =
               ServerICEProjection.new(transport_policy: :relay)

      assert {:ok, %{voice_session_id: relay_voice_session_id}} =
               Voice.join(
                 relay_voice_channel_id,
                 relay_user.id,
                 "relay-only-session",
                 self(),
                 relay_projection
               )

      assert {:ok, %{"type" => "answer"}} =
               Voice.accept_offer(
                 Scope.for_user(relay_user),
                 relay_voice_channel_id,
                 relay_voice_session_id,
                 "relay-only-negotiation",
                 browser_offer()
               )

      assert [] =
               collect_server_ice_candidates(
                 relay_voice_session_id,
                 "relay-only-negotiation"
               )
    end

    test "keeps ICE configuration scoped to the Voice Session that actually starts" do
      voice_channel_id = Ecto.UUID.generate()
      user = user_fixture()

      assert {:ok, first_projection} =
               ServerICEProjection.new(
                 host_to_srflx_ip_mapper: fn _host_address -> {203, 0, 113, 11} end,
                 udp_port_range: 50_000..50_015
               )

      assert {:ok, later_projection} =
               ServerICEProjection.new(
                 host_to_srflx_ip_mapper: fn _host_address -> {198, 51, 100, 22} end,
                 udp_port_range: 50_016..50_031
               )

      assert {:ok, %{voice_session_id: first_voice_session_id}} =
               Voice.join(
                 voice_channel_id,
                 user.id,
                 "same-signaling-session",
                 self(),
                 first_projection
               )

      assert {:ok, %{voice_session_id: ^first_voice_session_id}} =
               Voice.join(
                 voice_channel_id,
                 user.id,
                 "same-signaling-session",
                 self(),
                 later_projection
               )

      assert {:ok, %{"type" => "answer"}} =
               Voice.accept_offer(
                 Scope.for_user(user),
                 voice_channel_id,
                 first_voice_session_id,
                 "first-negotiation",
                 browser_offer()
               )

      first_candidate =
        await_server_ice_candidate(
          first_voice_session_id,
          "first-negotiation",
          &String.contains?(&1["candidate"], " 203.0.113.11 ")
        )

      refute first_candidate["candidate"] =~ " 198.51.100.22 "
      assert :ok = Voice.leave(voice_channel_id, first_voice_session_id)

      assert {:ok, %{voice_session_id: later_voice_session_id}} =
               Voice.join(
                 voice_channel_id,
                 user.id,
                 "later-signaling-session",
                 self(),
                 later_projection
               )

      refute later_voice_session_id == first_voice_session_id

      assert {:ok, %{"type" => "answer"}} =
               Voice.accept_offer(
                 Scope.for_user(user),
                 voice_channel_id,
                 later_voice_session_id,
                 "later-negotiation",
                 browser_offer()
               )

      later_candidate =
        await_server_ice_candidate(
          later_voice_session_id,
          "later-negotiation",
          &String.contains?(&1["candidate"], " 198.51.100.22 ")
        )

      refute later_candidate["candidate"] =~ " 203.0.113.11 "
    end

    test "rejects an invalid projection without leaving runtime ownership" do
      voice_channel_id = Ecto.UUID.generate()
      user_id = Ecto.UUID.generate()
      running_before = MapSet.new(ExWebRTC.PeerConnection.get_all_running())
      invalid_projection = %{ServerICEProjection.disabled() | transport_policy: :invalid}

      assert {:error, :unavailable} =
               Voice.join(
                 voice_channel_id,
                 user_id,
                 "invalid-ice-session",
                 self(),
                 invalid_projection
               )

      refute Voice.room_running?(voice_channel_id)
      assert {:ok, %{members: []}} = Voice.voice_channel_roster(voice_channel_id)
      assert MapSet.new(ExWebRTC.PeerConnection.get_all_running()) == running_before

      assert {:ok, %{occupancy: 1}} =
               Voice.join(
                 Ecto.UUID.generate(),
                 user_id,
                 "healthy-session-after-invalid-ice",
                 self()
               )
    end

    test "PeerConnection startup failure leaves no membership, route, roster, or coordinator residue" do
      failed_voice_channel_id = Ecto.UUID.generate()
      user_id = Ecto.UUID.generate()
      running_before = MapSet.new(ExWebRTC.PeerConnection.get_all_running())

      failed_room =
        start_room_server(failed_voice_channel_id,
          test_peer_connection_opts: [audio_codecs: [:invalid]]
        )

      assert {:error, :unavailable} =
               Voice.join(
                 failed_voice_channel_id,
                 user_id,
                 "failed-peer-connection-session",
                 self(),
                 ServerICEProjection.disabled()
               )

      assert {:ok, %{occupancy: 0, capacity: 5}} = RoomServer.occupancy(failed_room)
      assert %{members: []} = RoomServer.roster(failed_room)
      assert MapSet.new(ExWebRTC.PeerConnection.get_all_running()) == running_before

      assert {:ok, %{occupancy: 1}} =
               Voice.join(
                 Ecto.UUID.generate(),
                 user_id,
                 "healthy-session-after-startup-failure",
                 self()
               )
    end

    test "expires an unrenewed Voice Session without affecting another room" do
      expired_voice_channel_id = Ecto.UUID.generate()
      healthy_voice_channel_id = Ecto.UUID.generate()
      expired_user_id = Ecto.UUID.generate()
      healthy_user_id = Ecto.UUID.generate()
      running_before = ExWebRTC.PeerConnection.get_all_running()

      expired_room =
        start_room_server(expired_voice_channel_id, voice_session_lease_timeout_ms: 0)

      healthy_room =
        start_room_server(healthy_voice_channel_id,
          voice_session_lease_timeout_ms: :timer.minutes(1)
        )

      assert {:ok, %{voice_session_id: expired_voice_session_id}} =
               RoomServer.join(expired_room, expired_user_id, "expired-session", self())

      assert {:ok, %{voice_session_id: healthy_voice_session_id}} =
               RoomServer.join(healthy_room, healthy_user_id, "healthy-session", self())

      assert_receive {:voice_session_ended, ^expired_voice_session_id, "expired-session"}
      assert :ok = RoomServer.await_empty(expired_room)
      assert %{members: []} = RoomServer.roster(expired_room)
      assert {:ok, %{occupancy: 1, capacity: 5}} = RoomServer.occupancy(healthy_room)
      assert %{members: [%{user_id: ^healthy_user_id}]} = RoomServer.roster(healthy_room)
      assert length(ExWebRTC.PeerConnection.get_all_running()) == length(running_before) + 1

      assert :ok = RoomServer.leave(healthy_room, healthy_voice_session_id)
      assert :ok = RoomServer.await_empty(healthy_room)

      assert {:error, :not_found} =
               Voice.dispatch_test_ex_webrtc(
                 expired_voice_channel_id,
                 expired_voice_session_id,
                 :late_message
               )
    end

    test "expires only an unrecovered disconnected PeerConnection through canonical cleanup" do
      voice_channel_id = Ecto.UUID.generate()
      assert :ok = Voice.subscribe_to_voice_channel_roster(voice_channel_id)
      room_server = start_room_server(voice_channel_id, peer_connection_recovery_timeout_ms: 0)

      [disconnected_session, healthy_session] =
        negotiate_room_sessions(room_server, 2, "peer-connection-recovery")

      disconnected_peer_monitor = Process.monitor(disconnected_session.peer_connection)
      healthy_peer_monitor = Process.monitor(healthy_session.peer_connection)
      disconnected_peer_connection = disconnected_session.peer_connection
      healthy_peer_connection = healthy_session.peer_connection
      healthy_user_id = healthy_session.user_id

      assert :ok =
               RoomServer.dispatch_test_ex_webrtc(
                 room_server,
                 disconnected_session.voice_session_id,
                 {:ex_webrtc, disconnected_session.peer_connection,
                  {:connection_state_change, :disconnected}}
               )

      assert_receive {:DOWN, ^disconnected_peer_monitor, :process, ^disconnected_peer_connection,
                      _reason}

      assert_receive {:voice_channel_roster_changed,
                      %{
                        voice_channel_id: ^voice_channel_id,
                        members: [%{user_id: ^healthy_user_id}]
                      }},
                     1_000

      assert {:ok, %{occupancy: 1, capacity: 5}} = Voice.room_occupancy(voice_channel_id)

      assert {:ok, %{members: [%{user_id: ^healthy_user_id}]}} =
               Voice.voice_channel_roster(voice_channel_id)

      assert {:error, :not_found} =
               Voice.dispatch_test_ex_webrtc(
                 voice_channel_id,
                 disconnected_session.voice_session_id,
                 :late_rtp
               )

      refute_receive {:DOWN, ^healthy_peer_monitor, :process, ^healthy_peer_connection, _reason},
                     0

      assert :ok = RoomServer.leave(room_server, healthy_session.voice_session_id)
      assert :ok = RoomServer.await_empty(room_server)
    end

    test "keeps a PeerConnection that recovers from disconnected in its Voice Session" do
      voice_channel_id = Ecto.UUID.generate()
      room_server = start_room_server(voice_channel_id, peer_connection_recovery_timeout_ms: 0)
      [session] = negotiate_room_sessions(room_server, 1, "peer-connection-recovery")
      user_id = session.user_id

      assert :ok =
               RoomServer.dispatch_test_ex_webrtc(
                 room_server,
                 session.voice_session_id,
                 {:ex_webrtc, session.peer_connection, {:connection_state_change, :disconnected}}
               )

      assert :ok =
               RoomServer.dispatch_test_ex_webrtc(
                 room_server,
                 session.voice_session_id,
                 {:ex_webrtc, session.peer_connection, {:connection_state_change, :connected}}
               )

      assert :ok = RoomServer.sync_test_media(room_server)
      assert {:ok, %{occupancy: 1, capacity: 5}} = Voice.room_occupancy(voice_channel_id)

      assert {:ok, %{members: [%{user_id: ^user_id}]}} =
               Voice.voice_channel_roster(voice_channel_id)

      assert :ok = RoomServer.leave(room_server, session.voice_session_id)
      assert :ok = RoomServer.await_empty(room_server)
    end

    test "renews only the matching authenticated Voice Session" do
      voice_channel_id = Ecto.UUID.generate()
      user = user_fixture()

      assert {:ok, %{voice_session_id: voice_session_id}} =
               Voice.join(voice_channel_id, user.id, "current-signaling-session", self())

      assert :ok =
               Voice.renew_session(
                 Scope.for_user(user),
                 voice_channel_id,
                 voice_session_id,
                 "current-signaling-session"
               )

      assert {:error, :invalid_session} =
               Voice.renew_session(
                 Scope.for_user(user),
                 voice_channel_id,
                 Ecto.UUID.generate(),
                 "current-signaling-session"
               )

      assert {:error, :invalid_session} =
               Voice.renew_session(
                 Scope.for_user(user_fixture()),
                 voice_channel_id,
                 voice_session_id,
                 "current-signaling-session"
               )

      assert {:error, :invalid_session} =
               Voice.renew_session(
                 Scope.for_user(user),
                 voice_channel_id,
                 voice_session_id,
                 "stale-signaling-session"
               )
    end

    test "starts a room for a durable Voice Channel ID without exposing its process" do
      voice_channel_id = Ecto.UUID.generate()

      assert :ok = Voice.ensure_room(voice_channel_id)
      assert Voice.room_running?(voice_channel_id)
    end

    test "reuses one running room when the same Voice Channel is requested concurrently" do
      voice_channel_id = Ecto.UUID.generate()

      results =
        1..8
        |> Task.async_stream(fn _ -> Voice.ensure_room(voice_channel_id) end,
          max_concurrency: 8,
          timeout: :infinity
        )
        |> Enum.to_list()

      assert Enum.all?(results, &(&1 == {:ok, :ok}))
      assert Voice.room_running?(voice_channel_id)
    end

    test "retires an empty room after its idle grace" do
      voice_channel_id = Ecto.UUID.generate()

      assert :ok = Voice.ensure_room(voice_channel_id)
      room_server = room_server(voice_channel_id)
      ref = Process.monitor(room_server)
      %{room_supervisor: room_supervisor} = :sys.get_state(room_server)
      supervisor_ref = Process.monitor(room_supervisor)

      assert :ok = Voice.mark_room_empty(voice_channel_id, idle_timeout: 0)
      assert_receive {:DOWN, ^ref, :process, ^room_server, :normal}, 1_000
      assert_receive {:DOWN, ^supervisor_ref, :process, ^room_supervisor, :shutdown}, 1_000
      refute Voice.room_running?(voice_channel_id)
    end

    test "new room use cancels a pending idle shutdown" do
      voice_channel_id = Ecto.UUID.generate()

      assert :ok = Voice.ensure_room(voice_channel_id)
      room_server = room_server(voice_channel_id)
      ref = Process.monitor(room_server)

      assert :ok = Voice.mark_room_empty(voice_channel_id, idle_timeout: 25)
      assert :ok = Voice.mark_room_in_use(voice_channel_id)
      _ = :sys.get_state(room_server)

      refute_receive {:DOWN, ^ref, :process, ^room_server, _reason}, 50
      assert Voice.room_running?(voice_channel_id)

      assert :ok = Voice.mark_room_empty(voice_channel_id, idle_timeout: 0)
      assert_receive {:DOWN, ^ref, :process, ^room_server, :normal}
    end

    test "malformed IDs do not start rooms" do
      assert Voice.ensure_room("not-a-uuid") == {:error, :not_found}
      refute Voice.room_running?("not-a-uuid")
      assert Voice.mark_room_in_use("not-a-uuid") == {:error, :not_found}
      assert Voice.mark_room_empty("not-a-uuid") == {:error, :not_found}
    end

    test "retries safely after a room process dies during lookup" do
      voice_channel_id = Ecto.UUID.generate()

      assert :ok = Voice.ensure_room(voice_channel_id)
      room_server = room_server(voice_channel_id)
      ref = Process.monitor(room_server)
      Process.exit(room_server, :kill)

      assert_receive {:DOWN, ^ref, :process, ^room_server, :killed}
      assert :ok = Voice.ensure_room(voice_channel_id)
      assert Voice.room_running?(voice_channel_id)
    end

    test "a RoomServer failure clears its room and preserves an unrelated room" do
      affected_voice_channel_id = Ecto.UUID.generate()
      unaffected_voice_channel_id = Ecto.UUID.generate()
      affected_user_ids = Enum.map(1..2, fn _ -> Ecto.UUID.generate() end)

      for {user_id, number} <- Enum.with_index(affected_user_ids, 1) do
        assert {:ok, %{occupancy: ^number}} =
                 Voice.join(
                   affected_voice_channel_id,
                   user_id,
                   "affected-connection-#{number}",
                   self()
                 )
      end

      assert {:ok, %{occupancy: 1}} =
               Voice.join(
                 unaffected_voice_channel_id,
                 Ecto.UUID.generate(),
                 "unaffected-connection-1",
                 self()
               )

      room_server = room_server(affected_voice_channel_id)
      room_ref = Process.monitor(room_server)
      Process.exit(room_server, :kill)

      assert_receive {:DOWN, ^room_ref, :process, ^room_server, :killed}

      for {user_id, number} <- Enum.with_index(affected_user_ids, 1) do
        assert {:ok, %{occupancy: ^number}} =
                 Voice.join(
                   affected_voice_channel_id,
                   user_id,
                   "rejoin-after-room-failure-#{number}",
                   self()
                 )
      end

      assert {:ok, %{occupancy: 1, capacity: 5}} =
               Voice.room_occupancy(unaffected_voice_channel_id)
    end

    test "a Forwarder failure clears its room and preserves an unrelated room" do
      affected_voice_channel_id = Ecto.UUID.generate()
      unaffected_voice_channel_id = Ecto.UUID.generate()
      affected_user_id = Ecto.UUID.generate()

      assert {:ok, %{voice_session_id: old_voice_session_id, occupancy: 1}} =
               Voice.join(
                 affected_voice_channel_id,
                 affected_user_id,
                 "affected-connection-1",
                 self()
               )

      assert {:ok, %{occupancy: 1}} =
               Voice.join(
                 unaffected_voice_channel_id,
                 Ecto.UUID.generate(),
                 "unaffected-connection-1",
                 self()
               )

      affected_room_server = room_server(affected_voice_channel_id)
      unaffected_room_server = room_server(unaffected_voice_channel_id)
      affected_room_monitor = Process.monitor(affected_room_server)
      unaffected_room_monitor = Process.monitor(unaffected_room_server)

      assert :ok = Voice.crash_forwarder(affected_voice_channel_id)

      assert_receive {:DOWN, ^affected_room_monitor, :process, ^affected_room_server, _reason}

      refute_receive {:DOWN, ^unaffected_room_monitor, :process, ^unaffected_room_server,
                      _reason},
                     0

      assert {:ok, %{voice_session_id: new_voice_session_id, occupancy: 1}} =
               Voice.join(
                 affected_voice_channel_id,
                 affected_user_id,
                 "rejoin-after-forwarder-failure",
                 self()
               )

      refute new_voice_session_id == old_voice_session_id
      assert :ok = Voice.leave(affected_voice_channel_id, old_voice_session_id)

      assert {:ok, %{occupancy: 1, capacity: 5}} =
               Voice.room_occupancy(affected_voice_channel_id)

      assert {:ok, %{occupancy: 1, capacity: 5}} =
               Voice.room_occupancy(unaffected_voice_channel_id)
    end

    test "late cleanup for a failed room cannot clear a rejoined Voice Session" do
      voice_channel_id = Ecto.UUID.generate()
      replacement_voice_channel_id = Ecto.UUID.generate()
      user_id = Ecto.UUID.generate()

      assert {:ok, %{voice_session_id: old_voice_session_id}} =
               Voice.join(voice_channel_id, user_id, "same-signaling-session", self())

      room_server = room_server(voice_channel_id)
      room_ref = Process.monitor(room_server)
      Process.exit(room_server, :kill)

      assert_receive {:DOWN, ^room_ref, :process, ^room_server, :killed}

      assert {:ok, %{voice_session_id: new_voice_session_id, occupancy: 1}} =
               Voice.join(voice_channel_id, user_id, "same-signaling-session", self())

      refute new_voice_session_id == old_voice_session_id
      assert :ok = Voice.leave(voice_channel_id, old_voice_session_id)

      assert {:ok, _join_result} =
               Voice.join(replacement_voice_channel_id, user_id, "replacement-session", self())

      assert {:ok, %{occupancy: 0, capacity: 5}} = Voice.room_occupancy(voice_channel_id)

      assert {:ok, %{occupancy: 1, capacity: 5}} =
               Voice.room_occupancy(replacement_voice_channel_id)
    end

    test "a RoomServer loss destroys its old lease without disturbing fresh or unrelated Sessions" do
      affected_voice_channel_id = Ecto.UUID.generate()
      unaffected_voice_channel_id = Ecto.UUID.generate()
      user = user_fixture()

      assert {:ok, %{voice_session_id: retired_voice_session_id}} =
               Voice.join(
                 affected_voice_channel_id,
                 user.id,
                 "retired-signaling-session",
                 self()
               )

      assert {:ok, %{occupancy: 1}} =
               Voice.join(
                 unaffected_voice_channel_id,
                 Ecto.UUID.generate(),
                 "unaffected-signaling-session",
                 self()
               )

      room_server = room_server(affected_voice_channel_id)
      room_ref = Process.monitor(room_server)
      Process.exit(room_server, :kill)

      assert_receive {:DOWN, ^room_ref, :process, ^room_server, :killed}

      assert {:error, renewal_result} =
               Voice.renew_session(
                 Scope.for_user(user),
                 affected_voice_channel_id,
                 retired_voice_session_id,
                 "retired-signaling-session"
               )

      assert renewal_result in [:invalid_session, :unavailable]

      assert {:ok, %{voice_session_id: fresh_voice_session_id, occupancy: 1}} =
               Voice.join(
                 affected_voice_channel_id,
                 user.id,
                 "fresh-signaling-session",
                 self()
               )

      refute fresh_voice_session_id == retired_voice_session_id

      assert {:error, :invalid_session} =
               Voice.renew_session(
                 Scope.for_user(user),
                 affected_voice_channel_id,
                 retired_voice_session_id,
                 "retired-signaling-session"
               )

      assert :ok =
               Voice.renew_session(
                 Scope.for_user(user),
                 affected_voice_channel_id,
                 fresh_voice_session_id,
                 "fresh-signaling-session"
               )

      assert {:ok, %{occupancy: 1, capacity: 5}} =
               Voice.room_occupancy(unaffected_voice_channel_id)
    end

    test "SessionCoordinator restart retires old rooms before accepting fresh joins" do
      voice_channel_id = Ecto.UUID.generate()
      user_id = Ecto.UUID.generate()

      assert {:ok, %{voice_session_id: old_voice_session_id}} =
               Voice.join(voice_channel_id, user_id, "before-coordinator-restart", self())

      room_server = room_server(voice_channel_id)
      room_ref = Process.monitor(room_server)
      session_coordinator = Process.whereis(DiscordClone.Voice.SessionCoordinator)
      coordinator_ref = Process.monitor(session_coordinator)

      assert :ok = Voice.crash_session_coordinator()
      assert_receive {:DOWN, ^coordinator_ref, :process, ^session_coordinator, :killed}
      assert_receive {:DOWN, ^room_ref, :process, ^room_server, _reason}
      assert :ok = Voice.await_session_coordinator_recovery()
      refute Voice.room_running?(voice_channel_id)

      assert {:ok, %{voice_session_id: new_voice_session_id, occupancy: 1}} =
               Voice.join(voice_channel_id, user_id, "after-coordinator-restart", self())

      refute new_voice_session_id == old_voice_session_id
    end
  end

  describe "room-local Voice Sessions" do
    test "routes accepted RTP only to the other ready Session's real outbound track" do
      voice_channel_id = Ecto.UUID.generate()
      room_supervisor = start_signaling_channel(:routing_room_supervisor)

      room_server =
        start_supervised!(
          {RoomServer,
           voice_channel_id: voice_channel_id,
           room_supervisor: room_supervisor,
           test_peer_connection_opts: [test_rtp_observer: self()]}
        )

      _session_supervisor =
        start_supervised!({SessionSupervisor, voice_channel_id: voice_channel_id})

      _forwarder = start_supervised!({Forwarder, voice_channel_id: voice_channel_id})

      first_user_id = Ecto.UUID.generate()
      second_user_id = Ecto.UUID.generate()

      assert {:ok, %{voice_session_id: first_voice_session_id}} =
               RoomServer.join(room_server, first_user_id, "connection-1", self())

      assert {:ok, %{voice_session_id: second_voice_session_id}} =
               RoomServer.join(room_server, second_user_id, "connection-2", self())

      assert {:ok, _answer} =
               RoomServer.accept_offer(
                 room_server,
                 first_user_id,
                 first_voice_session_id,
                 "negotiation-1",
                 browser_offer(),
                 command_deadline()
               )

      first_peer_connection = negotiated_server_peer_connection([])

      assert {:ok, _answer} =
               RoomServer.accept_offer(
                 room_server,
                 second_user_id,
                 second_voice_session_id,
                 "negotiation-2",
                 browser_offer(),
                 command_deadline()
               )

      second_peer_connection = negotiated_server_peer_connection([first_peer_connection])

      first_transceiver = inbound_audio_transceiver(first_peer_connection)
      second_transceiver = inbound_audio_transceiver(second_peer_connection)
      first_output_transceiver = first_audio_output_transceiver(first_peer_connection)
      second_output_transceiver = first_audio_output_transceiver(second_peer_connection)

      assert :ok =
               RoomServer.dispatch_test_ex_webrtc(
                 room_server,
                 first_voice_session_id,
                 {:ex_webrtc, first_peer_connection, {:track, first_transceiver.receiver.track}}
               )

      assert :ok =
               RoomServer.dispatch_test_ex_webrtc(
                 room_server,
                 second_voice_session_id,
                 {:ex_webrtc, second_peer_connection, {:track, second_transceiver.receiver.track}}
               )

      assert :ok = RoomServer.sync_test_media(room_server)

      first_packet =
        ExRTP.Packet.new(<<1>>, payload_type: 111, sequence_number: 1, timestamp: 1, ssrc: 1)

      second_packet =
        ExRTP.Packet.new(<<2>>, payload_type: 111, sequence_number: 2, timestamp: 2, ssrc: 2)

      assert :ok =
               RoomServer.dispatch_test_ex_webrtc(
                 room_server,
                 first_voice_session_id,
                 {:ex_webrtc, first_peer_connection,
                  {:rtp, first_transceiver.receiver.track.id, nil, first_packet}}
               )

      assert_receive {:peer_connection_rtp_sent, ^second_peer_connection,
                      second_outbound_track_id, ^first_packet}

      assert second_outbound_track_id == second_output_transceiver.sender.track.id
      refute_receive {:peer_connection_rtp_sent, ^first_peer_connection, _, ^first_packet}, 0

      assert :ok =
               RoomServer.dispatch_test_ex_webrtc(
                 room_server,
                 second_voice_session_id,
                 {:ex_webrtc, second_peer_connection,
                  {:rtp, second_transceiver.receiver.track.id, nil, second_packet}}
               )

      assert_receive {:peer_connection_rtp_sent, ^first_peer_connection, first_outbound_track_id,
                      ^second_packet}

      assert first_outbound_track_id == first_output_transceiver.sender.track.id
      refute_receive {:peer_connection_rtp_sent, ^second_peer_connection, _, ^second_packet}, 0

      assert :ok =
               RoomServer.dispatch_test_ex_webrtc(
                 room_server,
                 first_voice_session_id,
                 {:ex_webrtc, first_peer_connection, {:connection_state_change, :disconnected}}
               )

      assert :ok = RoomServer.sync_test_media(room_server)

      disconnected_source_packet =
        ExRTP.Packet.new(<<3>>, payload_type: 111, sequence_number: 3, timestamp: 3, ssrc: 3)

      assert :ok =
               RoomServer.dispatch_test_ex_webrtc(
                 room_server,
                 first_voice_session_id,
                 {:ex_webrtc, first_peer_connection,
                  {:rtp, first_transceiver.receiver.track.id, nil, disconnected_source_packet}}
               )

      assert_receive {:peer_connection_rtp_sent, ^second_peer_connection, _,
                      ^disconnected_source_packet}

      assert :ok =
               RoomServer.dispatch_test_ex_webrtc(
                 room_server,
                 first_voice_session_id,
                 {:ex_webrtc, first_peer_connection,
                  {:track_muted, first_transceiver.receiver.track.id}}
               )

      muted_source_packet =
        ExRTP.Packet.new(<<4>>, payload_type: 111, sequence_number: 4, timestamp: 4, ssrc: 4)

      assert :ok =
               RoomServer.dispatch_test_ex_webrtc(
                 room_server,
                 first_voice_session_id,
                 {:ex_webrtc, first_peer_connection,
                  {:rtp, first_transceiver.receiver.track.id, nil, muted_source_packet}}
               )

      assert_receive {:peer_connection_rtp_sent, ^second_peer_connection, _, ^muted_source_packet}

      assert :ok =
               RoomServer.dispatch_test_ex_webrtc(
                 room_server,
                 first_voice_session_id,
                 {:ex_webrtc, first_peer_connection,
                  {:track_ended, first_transceiver.receiver.track.id}}
               )

      assert :ok = RoomServer.sync_test_media(room_server)

      ended_source_packet =
        ExRTP.Packet.new(<<5>>, payload_type: 111, sequence_number: 5, timestamp: 5, ssrc: 5)

      assert :ok =
               RoomServer.dispatch_test_ex_webrtc(
                 room_server,
                 first_voice_session_id,
                 {:ex_webrtc, first_peer_connection,
                  {:rtp, first_transceiver.receiver.track.id, nil, ended_source_packet}}
               )

      assert :ok = RoomServer.sync_test_media(room_server)
      refute_receive {:peer_connection_rtp_sent, _, _, ^ended_source_packet}, 0
    end

    test "routes both directions when the second Session completes its offer first" do
      voice_channel_id = Ecto.UUID.generate()
      room_supervisor = start_signaling_channel(:reverse_offer_routing_room_supervisor)

      room_server =
        start_supervised!(
          {RoomServer,
           voice_channel_id: voice_channel_id,
           room_supervisor: room_supervisor,
           test_peer_connection_opts: [test_rtp_observer: self()]}
        )

      _session_supervisor =
        start_supervised!({SessionSupervisor, voice_channel_id: voice_channel_id})

      _forwarder = start_supervised!({Forwarder, voice_channel_id: voice_channel_id})
      first_user_id = Ecto.UUID.generate()
      second_user_id = Ecto.UUID.generate()

      assert {:ok, %{voice_session_id: first_voice_session_id}} =
               RoomServer.join(room_server, first_user_id, "reverse-connection-1", self())

      assert {:ok, %{voice_session_id: second_voice_session_id}} =
               RoomServer.join(room_server, second_user_id, "reverse-connection-2", self())

      assert {:ok, _answer} =
               RoomServer.accept_offer(
                 room_server,
                 second_user_id,
                 second_voice_session_id,
                 "reverse-negotiation-2",
                 browser_offer(),
                 command_deadline()
               )

      second_peer_connection = negotiated_server_peer_connection([])

      assert {:ok, _answer} =
               RoomServer.accept_offer(
                 room_server,
                 first_user_id,
                 first_voice_session_id,
                 "reverse-negotiation-1",
                 browser_offer(),
                 command_deadline()
               )

      first_peer_connection = negotiated_server_peer_connection([second_peer_connection])
      first_transceiver = inbound_audio_transceiver(first_peer_connection)
      second_transceiver = inbound_audio_transceiver(second_peer_connection)

      for {voice_session_id, peer_connection, track} <- [
            {second_voice_session_id, second_peer_connection, second_transceiver.receiver.track},
            {first_voice_session_id, first_peer_connection, first_transceiver.receiver.track}
          ] do
        assert :ok =
                 RoomServer.dispatch_test_ex_webrtc(
                   room_server,
                   voice_session_id,
                   {:ex_webrtc, peer_connection, {:track, track}}
                 )
      end

      assert :ok = RoomServer.sync_test_media(room_server)

      first_packet =
        ExRTP.Packet.new(<<10>>, payload_type: 111, sequence_number: 10, timestamp: 10, ssrc: 10)

      second_packet =
        ExRTP.Packet.new(<<11>>, payload_type: 111, sequence_number: 11, timestamp: 11, ssrc: 11)

      assert :ok =
               RoomServer.dispatch_test_ex_webrtc(
                 room_server,
                 first_voice_session_id,
                 {:ex_webrtc, first_peer_connection,
                  {:rtp, first_transceiver.receiver.track.id, nil, first_packet}}
               )

      assert_receive {:peer_connection_rtp_sent, ^second_peer_connection, _, ^first_packet}
      refute_receive {:peer_connection_rtp_sent, ^first_peer_connection, _, ^first_packet}, 0

      assert :ok =
               RoomServer.dispatch_test_ex_webrtc(
                 room_server,
                 second_voice_session_id,
                 {:ex_webrtc, second_peer_connection,
                  {:rtp, second_transceiver.receiver.track.id, nil, second_packet}}
               )

      assert_receive {:peer_connection_rtp_sent, ^first_peer_connection, _, ^second_packet}
      refute_receive {:peer_connection_rtp_sent, ^second_peer_connection, _, ^second_packet}, 0
    end

    test "routes the real three-Session matrix across different negotiation and source orders" do
      voice_channel_id = Ecto.UUID.generate()
      room_supervisor = start_signaling_channel(:three_session_routing_room_supervisor)

      room_server =
        start_supervised!(
          {RoomServer,
           voice_channel_id: voice_channel_id,
           room_supervisor: room_supervisor,
           test_peer_connection_opts: [test_rtp_observer: self()]}
        )

      _session_supervisor =
        start_supervised!({SessionSupervisor, voice_channel_id: voice_channel_id})

      _forwarder = start_supervised!({Forwarder, voice_channel_id: voice_channel_id})

      sessions =
        Enum.map(1..3, fn number ->
          user_id = Ecto.UUID.generate()

          assert {:ok, %{voice_session_id: voice_session_id}} =
                   RoomServer.join(
                     room_server,
                     user_id,
                     "three-session-connection-#{number}",
                     self()
                   )

          %{number: number, user_id: user_id, voice_session_id: voice_session_id}
        end)

      {sessions_by_id, _peer_connections} =
        sessions
        |> Enum.reverse()
        |> Enum.reduce({%{}, []}, fn session, {sessions_by_id, peer_connections} ->
          assert {:ok, _answer} =
                   RoomServer.accept_offer(
                     room_server,
                     session.user_id,
                     session.voice_session_id,
                     "three-session-negotiation-#{session.number}",
                     browser_offer(),
                     command_deadline()
                   )

          peer_connection = negotiated_server_peer_connection(peer_connections)

          session =
            Map.put(session, :peer_connection, peer_connection)
            |> Map.put(:inbound_track, inbound_audio_transceiver(peer_connection).receiver.track)

          {Map.put(sessions_by_id, session.voice_session_id, session),
           [
             peer_connection | peer_connections
           ]}
        end)

      sessions_by_id
      |> Map.values()
      |> Enum.sort_by(& &1.number)
      |> Enum.each(fn session ->
        assert :ok =
                 RoomServer.dispatch_test_ex_webrtc(
                   room_server,
                   session.voice_session_id,
                   {:ex_webrtc, session.peer_connection, {:track, session.inbound_track}}
                 )
      end)

      assert :ok = RoomServer.sync_test_media(room_server)

      destination_ids_by_peer =
        Map.new(sessions_by_id, fn {voice_session_id, session} ->
          {session.peer_connection, voice_session_id}
        end)

      deliveries =
        sessions_by_id
        |> Map.values()
        |> Enum.sort_by(& &1.number, :desc)
        |> Enum.flat_map(fn session ->
          packet =
            ExRTP.Packet.new(<<session.number>>,
              payload_type: 111,
              sequence_number: session.number,
              timestamp: session.number,
              ssrc: session.number
            )

          assert :ok =
                   RoomServer.dispatch_test_ex_webrtc(
                     room_server,
                     session.voice_session_id,
                     {:ex_webrtc, session.peer_connection,
                      {:rtp, session.inbound_track.id, nil, packet}}
                   )

          Enum.map(1..2, fn _ ->
            assert_receive {:peer_connection_rtp_sent, destination_peer_connection,
                            output_track_id, ^packet}

            {session.voice_session_id,
             Map.fetch!(destination_ids_by_peer, destination_peer_connection), output_track_id}
          end)
        end)

      assert Enum.all?(deliveries, fn {source_id, destination_id, output_track_id} ->
               source_id != destination_id and
                 output_track_id in audio_output_track_ids(
                   Map.fetch!(sessions_by_id, destination_id).peer_connection
                 )
             end)

      for destination_id <- Map.keys(sessions_by_id) do
        destination_track_ids =
          for {_source_id, ^destination_id, output_track_id} <- deliveries,
              do: output_track_id

        assert destination_track_ids |> Enum.uniq() |> length() == 2
      end
    end

    test "measures the complete real five-Session ExWebRTC matrix" do
      voice_channel_id = Ecto.UUID.generate()
      room_supervisor = start_signaling_channel(:five_session_measurement_room_supervisor)

      room_server =
        start_supervised!(
          {RoomServer,
           voice_channel_id: voice_channel_id,
           room_supervisor: room_supervisor,
           test_peer_connection_opts: [test_rtp_observer: self()]}
        )

      _session_supervisor =
        start_supervised!({SessionSupervisor, voice_channel_id: voice_channel_id})

      forwarder = start_supervised!({Forwarder, voice_channel_id: voice_channel_id})
      sessions = negotiate_room_sessions(room_server, 5, "five-session")
      destination_ids_by_peer = Map.new(sessions, &{&1.peer_connection, &1.voice_session_id})
      packets_per_source = 50
      expected_route_count = 5 * 4
      expected_forwarded_packets = expected_route_count * packets_per_source
      attach_five_session_diagnostics(expected_forwarded_packets)

      _previous_runtime = :erlang.statistics(:runtime)
      started_at = System.monotonic_time(:microsecond)

      for session <- sessions, packet_number <- 1..packets_per_source do
        packet =
          ExRTP.Packet.new(:binary.copy(<<session.number>>, 80),
            payload_type: 111,
            sequence_number: packet_number,
            timestamp: packet_number * 960,
            ssrc: session.number
          )

        assert :ok =
                 RoomServer.dispatch_test_ex_webrtc(
                   room_server,
                   session.voice_session_id,
                   {:ex_webrtc, session.peer_connection,
                    {:rtp, session.inbound_track.id, nil, packet}}
                 )

        destination_ids =
          for _destination <- 1..4 do
            assert_receive {:peer_connection_rtp_sent, destination_peer_connection,
                            output_track_id, ^packet}

            destination_id = Map.fetch!(destination_ids_by_peer, destination_peer_connection)
            refute destination_id == session.voice_session_id

            assert output_track_id in audio_output_track_ids(destination_peer_connection)
            destination_id
          end

        assert MapSet.new(destination_ids) ==
                 sessions
                 |> Enum.reject(&(&1.voice_session_id == session.voice_session_id))
                 |> MapSet.new(& &1.voice_session_id)
      end

      elapsed_microseconds = System.monotonic_time(:microsecond) - started_at
      {_total_runtime, scheduler_runtime_milliseconds} = :erlang.statistics(:runtime)
      assert :ok = RoomServer.sync_test_media(room_server)

      outbound_stats =
        sessions
        |> Enum.flat_map(fn session ->
          session.peer_connection
          |> ExWebRTC.PeerConnection.get_stats()
          |> Map.values()
          |> Enum.filter(&(&1.type == :outbound_rtp and &1.packets_sent > 0))
        end)

      forwarded_packets = Enum.sum(Enum.map(outbound_stats, & &1.packets_sent))
      serialized_rtp_bytes = Enum.sum(Enum.map(outbound_stats, & &1.bytes_sent))
      stale_packet = ExRTP.Packet.new(<<0>>, sequence_number: 0, timestamp: 0, ssrc: 0)
      assert :ok = Forwarder.forward_rtp(forwarder, Ecto.UUID.generate(), 0, stale_packet)
      assert :ok = Forwarder.sync(forwarder)
      media_interval_milliseconds = packets_per_source * 20

      measurement = %{
        route_count: expected_route_count,
        forwarded_packet_count: forwarded_packets,
        dropped_packet_count: 1,
        elapsed_microseconds: elapsed_microseconds,
        scheduler_runtime_milliseconds: scheduler_runtime_milliseconds,
        serialized_rtp_bytes: serialized_rtp_bytes,
        modeled_serialized_rtp_bits_per_second:
          div(serialized_rtp_bytes * 8 * 1_000, media_interval_milliseconds),
        burst_serialized_rtp_bits_per_second:
          div(serialized_rtp_bytes * 8 * 1_000_000, elapsed_microseconds)
      }

      assert measurement.route_count == 20
      assert measurement.forwarded_packet_count == expected_forwarded_packets
      assert measurement.elapsed_microseconds > 0
      assert measurement.scheduler_runtime_milliseconds >= 0
      assert measurement.serialized_rtp_bytes > expected_forwarded_packets * 80
      assert measurement.modeled_serialized_rtp_bits_per_second > 0
      assert measurement.burst_serialized_rtp_bits_per_second > 0

      assert_receive {:five_session_route_diagnostic,
                      %{media_lifecycle: :rtp_forwarded} = forwarded_metadata}

      assert forwarded_metadata == %{
               media_lifecycle: :rtp_forwarded,
               forwarded_packet_count: expected_forwarded_packets,
               dropped_packet_count: 0
             }

      assert_receive {:five_session_route_diagnostic,
                      %{media_lifecycle: :rtp_dropped} = dropped_metadata}

      assert dropped_metadata == %{
               media_lifecycle: :rtp_dropped,
               forwarded_packet_count: expected_forwarded_packets,
               dropped_packet_count: 1
             }
    end

    test "canonical removal withdraws exact routes and protects a healthy replacement pair" do
      voice_channel_id = Ecto.UUID.generate()
      room_supervisor = start_signaling_channel(:cleanup_routing_room_supervisor)

      room_server =
        start_supervised!(
          {RoomServer,
           voice_channel_id: voice_channel_id,
           room_supervisor: room_supervisor,
           test_peer_connection_opts: [test_rtp_observer: self()]}
        )

      _session_supervisor =
        start_supervised!({SessionSupervisor, voice_channel_id: voice_channel_id})

      forwarder = start_supervised!({Forwarder, voice_channel_id: voice_channel_id})
      departing_user_id = Ecto.UUID.generate()
      healthy_user_id = Ecto.UUID.generate()

      assert {:ok, %{voice_session_id: departing_voice_session_id}} =
               RoomServer.join(room_server, departing_user_id, "departing-connection", self())

      assert {:ok, %{voice_session_id: healthy_voice_session_id}} =
               RoomServer.join(room_server, healthy_user_id, "healthy-connection", self())

      assert {:ok, _answer} =
               RoomServer.accept_offer(
                 room_server,
                 departing_user_id,
                 departing_voice_session_id,
                 "departing-negotiation",
                 browser_offer(),
                 command_deadline()
               )

      departing_peer_connection = negotiated_server_peer_connection([])

      assert {:ok, _answer} =
               RoomServer.accept_offer(
                 room_server,
                 healthy_user_id,
                 healthy_voice_session_id,
                 "healthy-negotiation",
                 browser_offer(),
                 command_deadline()
               )

      healthy_peer_connection = negotiated_server_peer_connection([departing_peer_connection])

      departing_transceiver = inbound_audio_transceiver(departing_peer_connection)
      healthy_transceiver = inbound_audio_transceiver(healthy_peer_connection)

      for {voice_session_id, peer_connection, track} <- [
            {departing_voice_session_id, departing_peer_connection,
             departing_transceiver.receiver.track},
            {healthy_voice_session_id, healthy_peer_connection,
             healthy_transceiver.receiver.track}
          ] do
        assert :ok =
                 RoomServer.dispatch_test_ex_webrtc(
                   room_server,
                   voice_session_id,
                   {:ex_webrtc, peer_connection, {:track, track}}
                 )
      end

      assert :ok = RoomServer.sync_test_media(room_server)
      departing_monitor = Process.monitor(departing_peer_connection)
      healthy_monitor = Process.monitor(healthy_peer_connection)

      assert :ok = RoomServer.leave(room_server, departing_voice_session_id)
      assert_receive {:DOWN, ^departing_monitor, :process, ^departing_peer_connection, _reason}
      refute_receive {:DOWN, ^healthy_monitor, :process, ^healthy_peer_connection, _reason}, 0

      removed_destination_packet =
        ExRTP.Packet.new(<<6>>, payload_type: 111, sequence_number: 6, timestamp: 6, ssrc: 6)

      assert :ok =
               Forwarder.forward_rtp(
                 forwarder,
                 healthy_voice_session_id,
                 healthy_transceiver.receiver.track.id,
                 removed_destination_packet
               )

      assert :ok = Forwarder.sync(forwarder)
      refute_receive {:peer_connection_rtp_sent, _, _, ^removed_destination_packet}, 0

      assert {:ok, %{voice_session_id: replacement_voice_session_id}} =
               RoomServer.join(room_server, departing_user_id, "replacement-connection", self())

      refute replacement_voice_session_id == departing_voice_session_id

      assert {:ok, _answer} =
               RoomServer.accept_offer(
                 room_server,
                 departing_user_id,
                 replacement_voice_session_id,
                 "replacement-negotiation",
                 browser_offer(),
                 command_deadline()
               )

      replacement_peer_connection =
        negotiated_server_peer_connection([healthy_peer_connection])

      replacement_transceiver = inbound_audio_transceiver(replacement_peer_connection)

      assert :ok =
               RoomServer.dispatch_test_ex_webrtc(
                 room_server,
                 replacement_voice_session_id,
                 {:ex_webrtc, replacement_peer_connection,
                  {:track, replacement_transceiver.receiver.track}}
               )

      assert :ok = RoomServer.sync_test_media(room_server)

      late_old_source_packet =
        ExRTP.Packet.new(<<7>>, payload_type: 111, sequence_number: 7, timestamp: 7, ssrc: 7)

      assert :ok =
               Forwarder.forward_rtp(
                 forwarder,
                 departing_voice_session_id,
                 departing_transceiver.receiver.track.id,
                 late_old_source_packet
               )

      assert :ok = Forwarder.sync(forwarder)
      refute_receive {:peer_connection_rtp_sent, _, _, ^late_old_source_packet}, 0

      restored_route_packet =
        ExRTP.Packet.new(<<8>>, payload_type: 111, sequence_number: 8, timestamp: 8, ssrc: 8)

      assert :ok =
               Forwarder.forward_rtp(
                 forwarder,
                 healthy_voice_session_id,
                 healthy_transceiver.receiver.track.id,
                 restored_route_packet
               )

      assert_receive {:peer_connection_rtp_sent, ^replacement_peer_connection, _,
                      ^restored_route_packet}

      replacement_monitor = Process.monitor(replacement_peer_connection)
      assert :ok = RoomServer.crash_session(room_server, replacement_voice_session_id)

      assert_receive {:DOWN, ^replacement_monitor, :process, ^replacement_peer_connection,
                      _reason}

      refute_receive {:DOWN, ^healthy_monitor, :process, ^healthy_peer_connection, _reason}, 0

      post_crash_packet =
        ExRTP.Packet.new(<<9>>, payload_type: 111, sequence_number: 9, timestamp: 9, ssrc: 9)

      assert :ok =
               Forwarder.forward_rtp(
                 forwarder,
                 healthy_voice_session_id,
                 healthy_transceiver.receiver.track.id,
                 post_crash_packet
               )

      assert :ok = Forwarder.sync(forwarder)
      refute_receive {:peer_connection_rtp_sent, _, _, ^post_crash_packet}, 0
    end

    test "does not commit membership when Session PeerConnection startup fails" do
      voice_channel_id = Ecto.UUID.generate()
      room_supervisor = start_signaling_channel(:failed_room_supervisor)

      room_server =
        start_supervised!(
          {RoomServer,
           voice_channel_id: voice_channel_id,
           room_supervisor: room_supervisor,
           test_peer_connection_opts: [audio_codecs: [:invalid]]}
        )

      _session_supervisor =
        start_supervised!({SessionSupervisor, voice_channel_id: voice_channel_id})

      _forwarder = start_supervised!({Forwarder, voice_channel_id: voice_channel_id})

      running_before = MapSet.new(ExWebRTC.PeerConnection.get_all_running())

      assert {:error, :unavailable} =
               RoomServer.join(room_server, Ecto.UUID.generate(), "connection-1", self())

      assert {:ok, %{occupancy: 0, capacity: 5}} = RoomServer.occupancy(room_server)
      assert MapSet.new(ExWebRTC.PeerConnection.get_all_running()) == running_before
    end

    test "does not commit membership until the Session-owned PeerConnection is ready" do
      voice_channel_id = Ecto.UUID.generate()
      room_supervisor = start_signaling_channel(:readiness_room_supervisor)
      readiness_reference = make_ref()

      room_server =
        start_supervised!(
          {RoomServer,
           voice_channel_id: voice_channel_id,
           room_supervisor: room_supervisor,
           test_admission_observer: self(),
           test_peer_connection_opts: [
             test_readiness_gate: {self(), readiness_reference}
           ]}
        )

      _session_supervisor =
        start_supervised!({SessionSupervisor, voice_channel_id: voice_channel_id})

      _forwarder = start_supervised!({Forwarder, voice_channel_id: voice_channel_id})

      test_pid = self()

      _join_task =
        start_supervised!(
          {Task,
           fn ->
             result =
               RoomServer.join(room_server, Ecto.UUID.generate(), "connection-1", test_pid)

             send(test_pid, {:voice_session_join_result, result})
           end}
        )

      assert_receive {:peer_connection_starting, ^readiness_reference, session_pid}
      refute_receive {:voice_session_membership_committed, _voice_session_id}, 0

      send(session_pid, {:release_peer_connection_start, readiness_reference})

      assert_receive {:voice_session_join_result, {:ok, %{voice_session_id: voice_session_id}}},
                     1_000

      assert_receive {:voice_session_membership_committed, ^voice_session_id}, 1_000
      assert {:ok, %{occupancy: 1, capacity: 5}} = RoomServer.occupancy(room_server)

      assert [peer_connection] = ExWebRTC.PeerConnection.get_all_running()
      peer_connection_monitor = Process.monitor(peer_connection)
      assert :ok = RoomServer.leave(room_server, voice_session_id)
      assert_receive {:DOWN, ^peer_connection_monitor, :process, ^peer_connection, _reason}
    end

    test "applies buffered client ICE to the PeerConnection in arrival order" do
      voice_channel_id = Ecto.UUID.generate()
      user_id = Ecto.UUID.generate()
      room_supervisor = start_signaling_channel(:candidate_order_room_supervisor)

      room_server =
        start_supervised!(
          {RoomServer,
           voice_channel_id: voice_channel_id,
           room_supervisor: room_supervisor,
           test_peer_connection_opts: [test_candidate_observer: self()]}
        )

      _session_supervisor =
        start_supervised!({SessionSupervisor, voice_channel_id: voice_channel_id})

      _forwarder = start_supervised!({Forwarder, voice_channel_id: voice_channel_id})

      assert {:ok, %{voice_session_id: voice_session_id}} =
               RoomServer.join(room_server, user_id, "connection-1", self())

      negotiation_id = "current-negotiation"
      first_candidate = runtime_candidate(1)
      stale_negotiation_id = "stale-negotiation"
      stale_candidate = %{runtime_candidate(99) | negotiation_id: stale_negotiation_id}
      second_candidate = runtime_candidate(2)

      assert {:ok, %{negotiation_id: ^stale_negotiation_id}} =
               RoomServer.add_ice_candidate(
                 room_server,
                 user_id,
                 voice_session_id,
                 stale_negotiation_id,
                 stale_candidate,
                 command_deadline()
               )

      assert {:ok, %{negotiation_id: ^negotiation_id}} =
               RoomServer.add_ice_candidate(
                 room_server,
                 user_id,
                 voice_session_id,
                 negotiation_id,
                 first_candidate,
                 command_deadline()
               )

      assert {:ok, %{negotiation_id: ^negotiation_id}} =
               RoomServer.add_ice_candidate(
                 room_server,
                 user_id,
                 voice_session_id,
                 negotiation_id,
                 second_candidate,
                 command_deadline()
               )

      assert {:ok, %{"type" => "answer"}} =
               RoomServer.accept_offer(
                 room_server,
                 user_id,
                 voice_session_id,
                 negotiation_id,
                 browser_offer(),
                 command_deadline()
               )

      first_candidate_value = first_candidate.candidate
      stale_candidate_value = stale_candidate.candidate
      second_candidate_value = second_candidate.candidate

      assert_receive {:peer_connection_candidate_applied, ^first_candidate_value}
      assert_receive {:peer_connection_candidate_applied, ^second_candidate_value}
      refute_receive {:peer_connection_candidate_applied, ^stale_candidate_value}, 0
    end

    test "admits a Voice Session only after its Session-owned PeerConnection is ready" do
      voice_channel_id = Ecto.UUID.generate()

      assert {:ok, %{voice_session_id: voice_session_id, occupancy: 1}} =
               Voice.join(voice_channel_id, Ecto.UUID.generate(), "connection-1", self())

      assert [peer_connection] = ExWebRTC.PeerConnection.get_all_running()
      assert ExWebRTC.PeerConnection.get_transceivers(peer_connection) == []
      peer_connection_monitor = Process.monitor(peer_connection)

      assert :ok = Voice.leave(voice_channel_id, voice_session_id)
      assert_receive {:DOWN, ^peer_connection_monitor, :process, ^peer_connection, _reason}

      assert :ok = Voice.leave(voice_channel_id, voice_session_id)
      refute_receive {:DOWN, ^peer_connection_monitor, :process, ^peer_connection, _reason}, 0
      assert {:ok, %{occupancy: 0, capacity: 5}} = Voice.room_occupancy(voice_channel_id)
    end

    test "a crashed Voice Session takes its linked PeerConnection down" do
      voice_channel_id = Ecto.UUID.generate()

      assert {:ok, %{voice_session_id: voice_session_id}} =
               Voice.join(voice_channel_id, Ecto.UUID.generate(), "connection-1", self())

      assert [peer_connection] = ExWebRTC.PeerConnection.get_all_running()
      peer_connection_monitor = Process.monitor(peer_connection)

      assert :ok = Voice.crash_session(voice_channel_id, voice_session_id)
      assert_receive {:DOWN, ^peer_connection_monitor, :process, ^peer_connection, _reason}
    end

    test "an active room shutdown stops every Session-owned PeerConnection" do
      voice_channel_id = Ecto.UUID.generate()

      assert {:ok, %{voice_session_id: _voice_session_id}} =
               Voice.join(voice_channel_id, Ecto.UUID.generate(), "connection-1", self())

      room_server = room_server(voice_channel_id)
      assert [peer_connection] = ExWebRTC.PeerConnection.get_all_running()
      peer_connection_monitor = Process.monitor(peer_connection)

      assert :ok = RoomServer.shutdown(room_server)
      assert_receive {:DOWN, ^peer_connection_monitor, :process, ^peer_connection, _reason}
      assert :ok = Voice.await_empty_room(voice_channel_id)
      assert :ok = Voice.expire_idle_room(voice_channel_id)
      refute Voice.room_running?(voice_channel_id)
    end

    test "a crashed PeerConnection removes its Voice Session without affecting another room" do
      affected_voice_channel_id = Ecto.UUID.generate()
      healthy_voice_channel_id = Ecto.UUID.generate()

      assert {:ok, %{voice_session_id: _affected_voice_session_id}} =
               Voice.join(
                 affected_voice_channel_id,
                 Ecto.UUID.generate(),
                 "affected-connection",
                 self()
               )

      [affected_peer_connection] = ExWebRTC.PeerConnection.get_all_running()

      assert {:ok, %{voice_session_id: _healthy_voice_session_id}} =
               Voice.join(
                 healthy_voice_channel_id,
                 Ecto.UUID.generate(),
                 "healthy-connection",
                 self()
               )

      [healthy_peer_connection] =
        ExWebRTC.PeerConnection.get_all_running() -- [affected_peer_connection]

      affected_peer_monitor = Process.monitor(affected_peer_connection)
      healthy_peer_monitor = Process.monitor(healthy_peer_connection)
      Process.exit(affected_peer_connection, :kill)

      assert_receive {:DOWN, ^affected_peer_monitor, :process, ^affected_peer_connection, :killed}
      assert :ok = Voice.await_empty_room(affected_voice_channel_id)

      assert {:ok, %{occupancy: 0, capacity: 5}} =
               Voice.room_occupancy(affected_voice_channel_id)

      assert {:ok, %{occupancy: 1, capacity: 5}} =
               Voice.room_occupancy(healthy_voice_channel_id)

      refute_receive {:DOWN, ^healthy_peer_monitor, :process, ^healthy_peer_connection, _reason},
                     0
    end

    test "a terminal peer state removes only its Session from a shared room" do
      voice_channel_id = Ecto.UUID.generate()

      assert {:ok, %{voice_session_id: failed_voice_session_id}} =
               Voice.join(voice_channel_id, Ecto.UUID.generate(), "failed-connection", self())

      [failed_peer_connection] = ExWebRTC.PeerConnection.get_all_running()

      assert {:ok, %{voice_session_id: healthy_voice_session_id}} =
               Voice.join(voice_channel_id, Ecto.UUID.generate(), "healthy-connection", self())

      [healthy_peer_connection] =
        ExWebRTC.PeerConnection.get_all_running() -- [failed_peer_connection]

      %{memberships: memberships} = :sys.get_state(room_server(voice_channel_id))
      failed_session = memberships[failed_voice_session_id].session_pid
      failed_session_monitor = Process.monitor(failed_session)
      failed_monitor = Process.monitor(failed_peer_connection)
      healthy_monitor = Process.monitor(healthy_peer_connection)

      assert :ok =
               Voice.dispatch_test_ex_webrtc(
                 voice_channel_id,
                 failed_voice_session_id,
                 {:ex_webrtc, failed_peer_connection, {:connection_state_change, :failed}}
               )

      assert_receive {:voice_session_event, ^failed_voice_session_id,
                      {:connection_state_change, :failed, nil}}

      assert_receive {:DOWN, ^failed_monitor, :process, ^failed_peer_connection, _reason}
      assert_receive {:DOWN, ^failed_session_monitor, :process, ^failed_session, :normal}
      refute_receive {:DOWN, ^healthy_monitor, :process, ^healthy_peer_connection, _reason}, 0
      assert {:ok, %{occupancy: 1, capacity: 5}} = Voice.room_occupancy(voice_channel_id)

      assert :ok = Voice.leave(voice_channel_id, healthy_voice_session_id)
      assert_receive {:DOWN, ^healthy_monitor, :process, ^healthy_peer_connection, _reason}
    end

    test "an expired runtime command retires the Voice Session and its PeerConnection" do
      voice_channel_id = Ecto.UUID.generate()
      user_id = Ecto.UUID.generate()

      assert {:ok, %{voice_session_id: voice_session_id}} =
               Voice.join(voice_channel_id, user_id, "connection-1", self())

      room_server = room_server(voice_channel_id)
      assert [peer_connection] = ExWebRTC.PeerConnection.get_all_running()
      peer_connection_monitor = Process.monitor(peer_connection)

      assert {:error, :invalid_session} =
               RoomServer.accept_offer(
                 room_server,
                 Ecto.UUID.generate(),
                 voice_session_id,
                 "other-user-negotiation",
                 %{},
                 System.monotonic_time(:millisecond) + 5_000
               )

      assert {:ok, %{occupancy: 1, capacity: 5}} = RoomServer.occupancy(room_server)
      expired_deadline = System.monotonic_time(:millisecond) - 1

      assert {:error, :unavailable} =
               RoomServer.accept_offer(
                 room_server,
                 user_id,
                 voice_session_id,
                 "expired-negotiation",
                 %{},
                 expired_deadline
               )

      assert_receive {:DOWN, ^peer_connection_monitor, :process, ^peer_connection, _reason}
      assert {:ok, %{occupancy: 0, capacity: 5}} = RoomServer.occupancy(room_server)
    end

    test "joins a Voice Session with a fresh opaque ID" do
      voice_channel_id = Ecto.UUID.generate()
      user_id = Ecto.UUID.generate()

      assert {:ok, join_result} =
               Voice.join(voice_channel_id, user_id, "signaling-connection-1", self())

      assert %{voice_session_id: voice_session_id, occupancy: 1, capacity: 5} = join_result
      assert {:ok, ^voice_session_id} = Ecto.UUID.cast(voice_session_id)
      refute voice_session_id in [voice_channel_id, user_id, "signaling-connection-1"]
      refute inspect(join_result) =~ "#PID"
    end

    test "reuses the existing Voice Session for the same signaling connection" do
      voice_channel_id = Ecto.UUID.generate()
      user_id = Ecto.UUID.generate()

      assert {:ok, first} = Voice.join(voice_channel_id, user_id, "connection-1", self())
      assert {:ok, repeated} = Voice.join(voice_channel_id, user_id, "connection-1", self())

      assert repeated == first
      assert {:ok, %{occupancy: 1, capacity: 5}} = Voice.room_occupancy(voice_channel_id)
    end

    test "atomically caps a room at five concurrent Voice Sessions" do
      voice_channel_id = Ecto.UUID.generate()

      signaling_channels = Enum.map(1..6, &start_signaling_channel/1)

      results =
        1..6
        |> Task.async_stream(
          fn number ->
            Voice.join(
              voice_channel_id,
              Ecto.UUID.generate(),
              "connection-#{number}",
              Enum.at(signaling_channels, number - 1)
            )
          end,
          max_concurrency: 6,
          timeout: :infinity
        )
        |> Enum.map(fn {:ok, result} -> result end)

      {admitted, rejected} =
        Enum.split_with(results, &match?({:ok, %{capacity: 5}}, &1))

      assert length(admitted) == 5

      assert [{:error, %{reason: :room_full, occupancy: 5, capacity: 5} = room_full}] =
               rejected

      assert Map.keys(room_full) |> Enum.sort() == [:capacity, :occupancy, :reason]
      assert {:ok, %{occupancy: 5, capacity: 5}} = Voice.room_occupancy(voice_channel_id)
    end

    test "leave is idempotent and the final leave begins empty-room cleanup" do
      voice_channel_id = Ecto.UUID.generate()
      user_id = Ecto.UUID.generate()

      assert {:ok, %{voice_session_id: voice_session_id}} =
               Voice.join(voice_channel_id, user_id, "connection-1", self())

      assert :ok = Voice.leave(voice_channel_id, voice_session_id)
      assert :ok = Voice.leave(voice_channel_id, voice_session_id)
      assert {:ok, %{occupancy: 0, capacity: 5}} = Voice.room_occupancy(voice_channel_id)

      assert :ok = Voice.expire_idle_room(voice_channel_id)
      refute Voice.room_running?(voice_channel_id)
    end

    test "a crashed temporary Session removes only its own membership" do
      voice_channel_id = Ecto.UUID.generate()

      assert {:ok, %{voice_session_id: crashed_session_id}} =
               Voice.join(voice_channel_id, Ecto.UUID.generate(), "connection-1", self())

      assert {:ok, %{voice_session_id: healthy_session_id}} =
               Voice.join(voice_channel_id, Ecto.UUID.generate(), "connection-2", self())

      assert :ok = Voice.crash_session(voice_channel_id, crashed_session_id)

      assert {:ok, %{occupancy: 1, capacity: 5}} = Voice.room_occupancy(voice_channel_id)

      assert {:ok, %{voice_session_id: replacement_session_id}} =
               Voice.join(voice_channel_id, Ecto.UUID.generate(), "connection-1", self())

      refute replacement_session_id == crashed_session_id

      assert :ok = Voice.leave(voice_channel_id, replacement_session_id)
      assert :ok = Voice.leave(voice_channel_id, healthy_session_id)
      assert {:ok, %{occupancy: 0, capacity: 5}} = Voice.room_occupancy(voice_channel_id)
    end

    test "a signaling channel death removes only its Voice Session" do
      voice_channel_id = Ecto.UUID.generate()

      signaling_channel = start_signaling_channel(:connection_death)
      healthy_signaling_channel = start_signaling_channel(:healthy_connection)

      assert {:ok, %{voice_session_id: _departing_voice_session_id}} =
               Voice.join(
                 voice_channel_id,
                 Ecto.UUID.generate(),
                 "connection-1",
                 signaling_channel
               )

      [departing_peer_connection] = ExWebRTC.PeerConnection.get_all_running()

      assert {:ok, %{voice_session_id: healthy_voice_session_id}} =
               Voice.join(
                 voice_channel_id,
                 Ecto.UUID.generate(),
                 "connection-2",
                 healthy_signaling_channel
               )

      [healthy_peer_connection] =
        ExWebRTC.PeerConnection.get_all_running() -- [departing_peer_connection]

      departing_monitor = Process.monitor(departing_peer_connection)
      healthy_monitor = Process.monitor(healthy_peer_connection)
      Process.exit(signaling_channel, :shutdown)

      assert_receive {:DOWN, ^departing_monitor, :process, ^departing_peer_connection, _reason}
      refute_receive {:DOWN, ^healthy_monitor, :process, ^healthy_peer_connection, _reason}, 0
      assert {:ok, %{occupancy: 1, capacity: 5}} = Voice.room_occupancy(voice_channel_id)

      assert :ok = Voice.leave(voice_channel_id, healthy_voice_session_id)
      assert_receive {:DOWN, ^healthy_monitor, :process, ^healthy_peer_connection, _reason}
    end
  end

  describe "Voice Session offer negotiation" do
    test "leave rejects late offer, ICE, and media work for the retired Voice Session" do
      user = user_fixture()
      current_scope = Scope.for_user(user)
      voice_channel_id = Ecto.UUID.generate()

      assert {:ok, %{voice_session_id: retired_voice_session_id}} =
               Voice.join(voice_channel_id, user.id, "retired-connection", self())

      [retired_peer_connection] = ExWebRTC.PeerConnection.get_all_running()
      retired_monitor = Process.monitor(retired_peer_connection)

      assert :ok = Voice.leave(voice_channel_id, retired_voice_session_id)
      assert_receive {:DOWN, ^retired_monitor, :process, ^retired_peer_connection, _reason}

      assert {:error, :invalid_session} =
               Voice.accept_offer(
                 current_scope,
                 voice_channel_id,
                 retired_voice_session_id,
                 "late-negotiation",
                 browser_offer()
               )

      assert {:error, :invalid_session} =
               Voice.add_ice_candidate(
                 current_scope,
                 voice_channel_id,
                 retired_voice_session_id,
                 "late-negotiation",
                 runtime_candidate(1)
               )

      assert {:error, :not_found} =
               Voice.dispatch_test_ex_webrtc(
                 voice_channel_id,
                 retired_voice_session_id,
                 {:ex_webrtc, retired_peer_connection, {:connection_state_change, :connected}}
               )

      assert {:ok, %{occupancy: 0, capacity: 5}} = Voice.room_occupancy(voice_channel_id)
    end

    test "routes an offer through the public Voice boundary to its admitted Voice Session" do
      user = user_fixture()
      current_scope = Scope.for_user(user)
      voice_channel_id = Ecto.UUID.generate()

      assert {:ok, %{voice_session_id: voice_session_id}} =
               Voice.join(voice_channel_id, user.id, "connection-1", self())

      negotiation_id = "first-negotiation"

      assert {:ok, %{"type" => "answer", "sdp" => answer_sdp}} =
               Voice.accept_offer(
                 current_scope,
                 voice_channel_id,
                 voice_session_id,
                 negotiation_id,
                 browser_offer()
               )

      assert is_binary(answer_sdp)
      assert byte_size(answer_sdp) > 0

      assert {:error, :negotiation_already_active} =
               Voice.accept_offer(
                 current_scope,
                 voice_channel_id,
                 voice_session_id,
                 "duplicate-negotiation",
                 browser_offer()
               )
    end

    test "rejects another User, Voice Channel, or stale Voice Session without mutation" do
      user = user_fixture()
      other_user = user_fixture()
      current_scope = Scope.for_user(user)
      other_scope = Scope.for_user(other_user)
      voice_channel_id = Ecto.UUID.generate()
      other_voice_channel_id = Ecto.UUID.generate()

      assert {:ok, %{voice_session_id: voice_session_id}} =
               Voice.join(voice_channel_id, user.id, "connection-1", self())

      assert {:ok, %{voice_session_id: _other_voice_session_id}} =
               Voice.join(other_voice_channel_id, other_user.id, "connection-2", self())

      offer = browser_offer()

      assert {:error, :invalid_session} =
               Voice.accept_offer(
                 other_scope,
                 voice_channel_id,
                 voice_session_id,
                 "other-user",
                 offer
               )

      assert {:error, :invalid_session} =
               Voice.accept_offer(
                 current_scope,
                 other_voice_channel_id,
                 voice_session_id,
                 "other-channel",
                 offer
               )

      assert {:error, :invalid_session} =
               Voice.accept_offer(
                 current_scope,
                 voice_channel_id,
                 Ecto.UUID.generate(),
                 "stale-session",
                 offer
               )

      assert {:ok, %{"type" => "answer"}} =
               Voice.accept_offer(
                 current_scope,
                 voice_channel_id,
                 voice_session_id,
                 "current-session",
                 offer
               )
    end

    test "routes early and current client ICE through the owning Voice Session" do
      user = user_fixture()
      current_scope = Scope.for_user(user)
      voice_channel_id = Ecto.UUID.generate()
      negotiation_id = "current-negotiation"

      assert {:ok, %{voice_session_id: voice_session_id}} =
               Voice.join(voice_channel_id, user.id, "connection-1", self())

      assert {:ok, %{negotiation_id: ^negotiation_id}} =
               Voice.add_ice_candidate(
                 current_scope,
                 voice_channel_id,
                 voice_session_id,
                 negotiation_id,
                 runtime_candidate(1)
               )

      assert {:ok, %{"type" => "answer"}} =
               Voice.accept_offer(
                 current_scope,
                 voice_channel_id,
                 voice_session_id,
                 negotiation_id,
                 browser_offer()
               )

      assert {:ok, %{negotiation_id: ^negotiation_id}} =
               Voice.add_ice_candidate(
                 current_scope,
                 voice_channel_id,
                 voice_session_id,
                 negotiation_id,
                 runtime_candidate(3)
               )
    end

    test "rejects client ICE for a stale runtime Negotiation" do
      user = user_fixture()
      current_scope = Scope.for_user(user)
      voice_channel_id = Ecto.UUID.generate()
      negotiation_id = "current-negotiation"

      assert {:ok, %{voice_session_id: voice_session_id}} =
               Voice.join(voice_channel_id, user.id, "connection-1", self())

      assert {:ok, %{"type" => "answer"}} =
               Voice.accept_offer(
                 current_scope,
                 voice_channel_id,
                 voice_session_id,
                 negotiation_id,
                 browser_offer()
               )

      assert {:error, :invalid_negotiation} =
               Voice.add_ice_candidate(
                 current_scope,
                 voice_channel_id,
                 voice_session_id,
                 "stale-negotiation",
                 runtime_candidate(2)
               )
    end

    test "retains the unsupported browser end-marker runtime contract" do
      user = user_fixture()
      current_scope = Scope.for_user(user)
      voice_channel_id = Ecto.UUID.generate()
      negotiation_id = "current-negotiation"

      assert {:ok, %{voice_session_id: voice_session_id}} =
               Voice.join(voice_channel_id, user.id, "connection-1", self())

      assert {:ok, %{"type" => "answer"}} =
               Voice.accept_offer(
                 current_scope,
                 voice_channel_id,
                 voice_session_id,
                 negotiation_id,
                 browser_offer()
               )

      assert {:error, :end_of_candidates_unsupported} =
               Voice.end_of_candidates(
                 current_scope,
                 voice_channel_id,
                 voice_session_id,
                 negotiation_id
               )
    end

    test "rejects ICE commands for mismatched runtime membership" do
      user = user_fixture()
      other_user = user_fixture()
      current_scope = Scope.for_user(user)
      other_scope = Scope.for_user(other_user)
      voice_channel_id = Ecto.UUID.generate()
      other_voice_channel_id = Ecto.UUID.generate()
      negotiation_id = "current-negotiation"

      assert {:ok, %{voice_session_id: voice_session_id}} =
               Voice.join(voice_channel_id, user.id, "connection-1", self())

      assert {:ok, %{voice_session_id: _other_voice_session_id}} =
               Voice.join(
                 other_voice_channel_id,
                 other_user.id,
                 "connection-2",
                 self()
               )

      candidate = runtime_candidate(1)

      assert {:error, :invalid_session} =
               Voice.add_ice_candidate(
                 other_scope,
                 voice_channel_id,
                 voice_session_id,
                 negotiation_id,
                 candidate
               )

      assert {:error, :invalid_session} =
               Voice.add_ice_candidate(
                 current_scope,
                 other_voice_channel_id,
                 voice_session_id,
                 negotiation_id,
                 candidate
               )

      assert {:error, :invalid_session} =
               Voice.add_ice_candidate(
                 current_scope,
                 voice_channel_id,
                 Ecto.UUID.generate(),
                 negotiation_id,
                 candidate
               )

      assert {:error, :invalid_session} =
               Voice.end_of_candidates(
                 current_scope,
                 other_voice_channel_id,
                 voice_session_id,
                 negotiation_id
               )
    end
  end

  describe "cross-room Voice Sessions" do
    test "serializes concurrent join requests for one User into one active Voice Session" do
      user_id = Ecto.UUID.generate()
      voice_channel_ids = [Ecto.UUID.generate(), Ecto.UUID.generate()]
      signaling_channels = Enum.map(1..8, &start_signaling_channel/1)

      results =
        0..7
        |> Task.async_stream(
          fn number ->
            Voice.join(
              Enum.at(voice_channel_ids, rem(number, 2)),
              user_id,
              "connection-#{number}",
              Enum.at(signaling_channels, number)
            )
          end,
          max_concurrency: 8,
          timeout: :infinity
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.all?(results, &match?({:ok, %{voice_session_id: _}}, &1))

      total_occupancy =
        Enum.reduce(voice_channel_ids, 0, fn voice_channel_id, total ->
          case Voice.room_occupancy(voice_channel_id) do
            {:ok, %{occupancy: occupancy}} -> total + occupancy
            {:error, :not_found} -> total
          end
        end)

      assert total_occupancy == 1
    end

    test "moves a User to an available Voice Channel and retires the old Voice Session" do
      first_voice_channel_id = Ecto.UUID.generate()
      second_voice_channel_id = Ecto.UUID.generate()
      third_voice_channel_id = Ecto.UUID.generate()
      user_id = Ecto.UUID.generate()

      assert {:ok, %{voice_session_id: first_voice_session_id}} =
               Voice.join(first_voice_channel_id, user_id, "connection-1", self())

      assert {:ok, %{voice_session_id: second_voice_session_id}} =
               Voice.join(second_voice_channel_id, user_id, "connection-2", self())

      refute second_voice_session_id == first_voice_session_id
      assert {:ok, %{occupancy: 0, capacity: 5}} = Voice.room_occupancy(first_voice_channel_id)
      assert {:ok, %{occupancy: 1, capacity: 5}} = Voice.room_occupancy(second_voice_channel_id)
      assert :ok = Voice.leave(first_voice_channel_id, first_voice_session_id)

      assert {:ok, %{voice_session_id: third_voice_session_id}} =
               Voice.join(third_voice_channel_id, user_id, "connection-3", self())

      refute third_voice_session_id == second_voice_session_id
      assert {:ok, %{occupancy: 0, capacity: 5}} = Voice.room_occupancy(second_voice_channel_id)
      assert {:ok, %{occupancy: 1, capacity: 5}} = Voice.room_occupancy(third_voice_channel_id)
    end

    test "clears an explicitly left Voice Session from global coordination" do
      first_voice_channel_id = Ecto.UUID.generate()
      second_voice_channel_id = Ecto.UUID.generate()
      user_id = Ecto.UUID.generate()

      assert {:ok, %{voice_session_id: voice_session_id}} =
               Voice.join(first_voice_channel_id, user_id, "connection-1", self())

      assert :ok = Voice.leave(first_voice_channel_id, voice_session_id)

      assert {:ok, _join_result} =
               Voice.join(second_voice_channel_id, user_id, "connection-2", self())

      assert {:ok, %{occupancy: 0, capacity: 5}} = Voice.room_occupancy(first_voice_channel_id)
      assert {:ok, %{occupancy: 1, capacity: 5}} = Voice.room_occupancy(second_voice_channel_id)
    end

    test "ignores a leave with the wrong Voice Channel ID" do
      first_voice_channel_id = Ecto.UUID.generate()
      wrong_voice_channel_id = Ecto.UUID.generate()
      second_voice_channel_id = Ecto.UUID.generate()
      user_id = Ecto.UUID.generate()

      assert {:ok, %{voice_session_id: voice_session_id}} =
               Voice.join(first_voice_channel_id, user_id, "connection-1", self())

      assert :ok = Voice.leave(wrong_voice_channel_id, voice_session_id)

      assert {:ok, _join_result} =
               Voice.join(second_voice_channel_id, user_id, "connection-2", self())

      assert {:ok, %{occupancy: 0, capacity: 5}} = Voice.room_occupancy(first_voice_channel_id)
      assert {:ok, %{occupancy: 1, capacity: 5}} = Voice.room_occupancy(second_voice_channel_id)
    end

    test "preserves the current Voice Session when a move target is full" do
      first_voice_channel_id = Ecto.UUID.generate()
      full_voice_channel_id = Ecto.UUID.generate()
      user_id = Ecto.UUID.generate()

      assert {:ok, %{voice_session_id: current_voice_session_id}} =
               Voice.join(first_voice_channel_id, user_id, "connection-1", self())

      full_signaling_channels = Enum.map(1..5, &start_signaling_channel/1)

      for number <- 1..5 do
        assert {:ok, _join_result} =
                 Voice.join(
                   full_voice_channel_id,
                   Ecto.UUID.generate(),
                   "full-connection-#{number}",
                   Enum.at(full_signaling_channels, number - 1)
                 )
      end

      assert {:error, %{reason: :room_full, occupancy: 5, capacity: 5}} =
               Voice.join(full_voice_channel_id, user_id, "connection-2", self())

      assert {:ok, %{occupancy: 1, capacity: 5}} = Voice.room_occupancy(first_voice_channel_id)
      assert {:ok, %{occupancy: 5, capacity: 5}} = Voice.room_occupancy(full_voice_channel_id)
      assert :ok = Voice.leave(first_voice_channel_id, current_voice_session_id)
    end

    test "clears a failed Voice Session from global coordination before a replacement join" do
      first_voice_channel_id = Ecto.UUID.generate()
      second_voice_channel_id = Ecto.UUID.generate()
      user_id = Ecto.UUID.generate()

      assert {:ok, %{voice_session_id: crashed_voice_session_id}} =
               Voice.join(first_voice_channel_id, user_id, "connection-1", self())

      assert :ok = Voice.crash_session(first_voice_channel_id, crashed_voice_session_id)

      assert {:ok, %{voice_session_id: replacement_voice_session_id}} =
               Voice.join(second_voice_channel_id, user_id, "connection-2", self())

      refute replacement_voice_session_id == crashed_voice_session_id
      assert {:ok, %{occupancy: 0, capacity: 5}} = Voice.room_occupancy(first_voice_channel_id)
      assert {:ok, %{occupancy: 1, capacity: 5}} = Voice.room_occupancy(second_voice_channel_id)
    end
  end

  describe "Voice Channel Roster snapshots" do
    test "publishes Speaking Indicator state from negotiated RTP audio-level metadata" do
      voice_channel_id = Ecto.UUID.generate()
      user_id = Ecto.UUID.generate()

      assert :ok = Voice.subscribe_to_voice_channel_roster(voice_channel_id)

      assert {:ok, %{voice_session_id: voice_session_id}} =
               Voice.join(voice_channel_id, user_id, "speaking-level-session", self())

      assert_receive {:voice_channel_roster_changed, _initial_snapshot}

      assert {:ok, _answer} =
               RoomServer.accept_offer(
                 room_server(voice_channel_id),
                 user_id,
                 voice_session_id,
                 "speaking-level-negotiation",
                 browser_offer_with_audio_level(),
                 command_deadline()
               )

      peer_connection = peer_connection_for_session(voice_channel_id, voice_session_id)
      inbound_track = inbound_audio_transceiver(peer_connection).receiver.track

      assert :ok =
               Voice.dispatch_test_ex_webrtc(
                 voice_channel_id,
                 voice_session_id,
                 {:ex_webrtc, peer_connection, {:track, inbound_track}}
               )

      quiet_packet =
        ExRTP.Packet.new(<<0>>, payload_type: 111, sequence_number: 0, timestamp: 0, ssrc: 1)
        |> ExRTP.Packet.add_extension(
          ExRTP.Packet.Extension.AudioLevel.new(true, 90)
          |> ExRTP.Packet.Extension.AudioLevel.to_raw(2)
        )

      assert :ok =
               Voice.dispatch_test_ex_webrtc(
                 voice_channel_id,
                 voice_session_id,
                 {:ex_webrtc, peer_connection, {:rtp, inbound_track.id, nil, quiet_packet}}
               )

      assert {:ok, %{members: [%{speaking: false}]}} =
               Voice.voice_channel_roster(voice_channel_id)

      packet =
        ExRTP.Packet.new(<<1>>, payload_type: 111, sequence_number: 1, timestamp: 1, ssrc: 1)
        |> ExRTP.Packet.add_extension(
          ExRTP.Packet.Extension.AudioLevel.new(true, 20)
          |> ExRTP.Packet.Extension.AudioLevel.to_raw(2)
        )

      assert :ok =
               Voice.dispatch_test_ex_webrtc(
                 voice_channel_id,
                 voice_session_id,
                 {:ex_webrtc, peer_connection, {:rtp, inbound_track.id, nil, packet}}
               )

      assert_receive {:voice_channel_roster_changed,
                      %{
                        voice_channel_id: ^voice_channel_id,
                        members: [%{user_id: ^user_id, speaking: true}]
                      }}

      refute_receive {:voice_channel_roster_changed,
                      %{members: [%{user_id: ^user_id, speaking: false}]}},
                     550

      assert_receive {:voice_channel_roster_changed,
                      %{members: [%{user_id: ^user_id, speaking: false}]}},
                     200
    end

    test "falls back to accepted RTP and clears the Speaking Indicator when the Session ends" do
      voice_channel_id = Ecto.UUID.generate()
      user_id = Ecto.UUID.generate()

      assert :ok = Voice.subscribe_to_voice_channel_roster(voice_channel_id)

      assert {:ok, %{voice_session_id: voice_session_id}} =
               Voice.join(voice_channel_id, user_id, "speaking-fallback-session", self())

      assert_receive {:voice_channel_roster_changed, _initial_snapshot}

      assert {:ok, _answer} =
               RoomServer.accept_offer(
                 room_server(voice_channel_id),
                 user_id,
                 voice_session_id,
                 "speaking-fallback-negotiation",
                 browser_offer(),
                 command_deadline()
               )

      peer_connection = peer_connection_for_session(voice_channel_id, voice_session_id)
      inbound_track = inbound_audio_transceiver(peer_connection).receiver.track

      assert :ok =
               Voice.dispatch_test_ex_webrtc(
                 voice_channel_id,
                 voice_session_id,
                 {:ex_webrtc, peer_connection, {:track, inbound_track}}
               )

      fallback_packet =
        ExRTP.Packet.new(<<1>>, payload_type: 111, sequence_number: 1, timestamp: 1, ssrc: 1)

      assert :ok =
               Voice.dispatch_test_ex_webrtc(
                 voice_channel_id,
                 voice_session_id,
                 {:ex_webrtc, peer_connection, {:rtp, inbound_track.id, nil, fallback_packet}}
               )

      assert_receive {:voice_channel_roster_changed,
                      %{members: [%{user_id: ^user_id, speaking: true}]}}

      assert :ok = Voice.leave(voice_channel_id, voice_session_id)
      assert_receive {:voice_channel_roster_changed, %{members: []}}
    end

    test "does not use the Speaking Indicator to authorize RTP forwarding" do
      voice_channel_id = Ecto.UUID.generate()
      source_user_id = Ecto.UUID.generate()
      listener_user_id = Ecto.UUID.generate()

      assert :ok = Voice.subscribe_to_voice_channel_roster(voice_channel_id)

      assert {:ok, %{voice_session_id: source_session_id}} =
               Voice.join(voice_channel_id, source_user_id, "speaking-source-session", self())

      assert {:ok, %{voice_session_id: listener_session_id}} =
               Voice.join(voice_channel_id, listener_user_id, "speaking-listener-session", self())

      assert {:ok, _answer} =
               RoomServer.accept_offer(
                 room_server(voice_channel_id),
                 source_user_id,
                 source_session_id,
                 "speaking-source-negotiation",
                 browser_offer_with_audio_level(),
                 command_deadline()
               )

      assert {:ok, _answer} =
               RoomServer.accept_offer(
                 room_server(voice_channel_id),
                 listener_user_id,
                 listener_session_id,
                 "speaking-listener-negotiation",
                 browser_offer(),
                 command_deadline()
               )

      source_peer_connection = peer_connection_for_session(voice_channel_id, source_session_id)

      listener_peer_connection =
        peer_connection_for_session(voice_channel_id, listener_session_id)

      source_inbound_track = inbound_audio_transceiver(source_peer_connection).receiver.track
      forwarded_packets_before = outbound_packet_count(listener_peer_connection)

      packet =
        ExRTP.Packet.new(<<1>>, payload_type: 111, sequence_number: 1, timestamp: 1, ssrc: 1)
        |> ExRTP.Packet.add_extension(
          ExRTP.Packet.Extension.AudioLevel.new(true, 90)
          |> ExRTP.Packet.Extension.AudioLevel.to_raw(2)
        )

      assert :ok =
               Voice.dispatch_test_ex_webrtc(
                 voice_channel_id,
                 source_session_id,
                 {:ex_webrtc, source_peer_connection,
                  {:rtp, source_inbound_track.id, nil, packet}}
               )

      assert :ok = RoomServer.sync_test_media(room_server(voice_channel_id))

      assert {:ok, %{members: [%{user_id: ^source_user_id, speaking: false}, _listener]}} =
               Voice.voice_channel_roster(voice_channel_id)

      assert outbound_packet_count(listener_peer_connection) == forwarded_packets_before + 1
    end

    test "publishes effective Local Mute and Local Deafen state for an active Voice Session" do
      voice_channel_id = Ecto.UUID.generate()
      scope = user_scope_fixture()

      assert :ok = Voice.subscribe_to_voice_channel_roster(voice_channel_id)

      assert {:ok, %{voice_session_id: voice_session_id}} =
               Voice.join(voice_channel_id, scope.user.id, "local-state-session", self())

      assert_receive {:voice_channel_roster_changed, _initial_snapshot}

      assert :ok =
               Voice.update_local_voice_state(scope, voice_channel_id, voice_session_id, %{
                 muted: true,
                 deafened: true
               })

      assert_receive {:voice_channel_roster_changed,
                      %{
                        voice_channel_id: ^voice_channel_id,
                        members: [
                          %{user_id: user_id, muted: true, deafened: true}
                        ]
                      }}

      assert user_id == scope.user.id

      assert :ok = Voice.leave(voice_channel_id, voice_session_id)

      assert_receive {:voice_channel_roster_changed,
                      %{voice_channel_id: ^voice_channel_id, members: []}}
    end

    test "publishes admission-ordered safe snapshots through leave, terminal cleanup, and replacement" do
      first_voice_channel_id = Ecto.UUID.generate()
      second_voice_channel_id = Ecto.UUID.generate()
      first_user_id = Ecto.UUID.generate()
      second_user_id = Ecto.UUID.generate()

      assert :ok = Voice.subscribe_to_voice_channel_roster(first_voice_channel_id)
      assert :ok = Voice.subscribe_to_voice_channel_roster(second_voice_channel_id)

      assert {:ok, %{voice_session_id: first_voice_session_id}} =
               Voice.join(first_voice_channel_id, first_user_id, "first-connection", self())

      assert_receive {:voice_channel_roster_changed,
                      %{
                        voice_channel_id: ^first_voice_channel_id,
                        members: [%{user_id: ^first_user_id}]
                      }}

      assert {:ok, %{voice_session_id: second_voice_session_id}} =
               Voice.join(first_voice_channel_id, second_user_id, "second-connection", self())

      assert_receive {:voice_channel_roster_changed,
                      %{
                        voice_channel_id: ^first_voice_channel_id,
                        members: [%{user_id: ^first_user_id}, %{user_id: ^second_user_id}]
                      }}

      assert :ok = Voice.leave(first_voice_channel_id, first_voice_session_id)

      assert_receive {:voice_channel_roster_changed,
                      %{
                        voice_channel_id: ^first_voice_channel_id,
                        members: [%{user_id: ^second_user_id}]
                      }}

      assert :ok = Voice.crash_session(first_voice_channel_id, second_voice_session_id)

      assert_receive {:voice_channel_roster_changed,
                      %{voice_channel_id: ^first_voice_channel_id, members: []}}

      assert {:ok, _join_result} =
               Voice.join(first_voice_channel_id, first_user_id, "replacement-old", self())

      assert_receive {:voice_channel_roster_changed,
                      %{
                        voice_channel_id: ^first_voice_channel_id,
                        members: [%{user_id: ^first_user_id}]
                      }}

      assert {:ok, _join_result} =
               Voice.join(second_voice_channel_id, first_user_id, "replacement-new", self())

      assert_receive {:voice_channel_roster_changed,
                      %{voice_channel_id: ^first_voice_channel_id, members: []}}

      assert_receive {:voice_channel_roster_changed,
                      %{
                        voice_channel_id: ^second_voice_channel_id,
                        members: [%{user_id: ^first_user_id}]
                      }}

      assert {:ok, %{voice_channel_id: ^second_voice_channel_id, members: roster_members}} =
               Voice.voice_channel_roster(second_voice_channel_id)

      assert roster_members == [
               %{user_id: first_user_id, muted: false, deafened: false, speaking: false}
             ]

      refute Enum.any?(roster_members, fn member ->
               Map.has_key?(member, :pid) or Map.has_key?(member, :session_pid) or
                 Map.has_key?(member, :voice_session_id) or Map.has_key?(member, :sdp) or
                 Map.has_key?(member, :ice)
             end)
    end
  end

  describe "durable Voice lifecycle notifications" do
    test "ends only the matching user's Voice Session in a Voice Channel" do
      voice_channel_id = Ecto.UUID.generate()
      target_user = user_fixture()
      retained_user = user_fixture()
      third_user = user_fixture()

      assert {:ok, %{voice_session_id: target_session_id}} =
               Voice.join(voice_channel_id, target_user.id, "target-connection", self())

      assert {:ok, %{voice_session_id: retained_session_id}} =
               Voice.join(voice_channel_id, retained_user.id, "retained-connection", self())

      assert {:ok, %{voice_session_id: third_session_id}} =
               Voice.join(voice_channel_id, third_user.id, "third-connection", self())

      negotiated =
        for {user, session_id, number} <- [
              {target_user, target_session_id, 1},
              {retained_user, retained_session_id, 2},
              {third_user, third_session_id, 3}
            ],
            reduce: [] do
          peer_connections ->
            assert {:ok, _answer} =
                     Voice.accept_offer(
                       Scope.for_user(user),
                       voice_channel_id,
                       session_id,
                       "durable-negotiation-#{number}",
                       browser_offer()
                     )

            peer_connection =
              peer_connection_for_session(voice_channel_id, session_id)

            inbound_track = inbound_audio_transceiver(peer_connection).receiver.track

            assert :ok =
                     Voice.dispatch_test_ex_webrtc(
                       voice_channel_id,
                       session_id,
                       {:ex_webrtc, peer_connection, {:track, inbound_track}}
                     )

            [
              %{session_id: session_id, peer_connection: peer_connection, track: inbound_track}
              | peer_connections
            ]
        end

      assert :ok = RoomServer.sync_test_media(room_server(voice_channel_id))
      target = Enum.find(negotiated, &(&1.session_id == target_session_id))
      retained = Enum.find(negotiated, &(&1.session_id == retained_session_id))
      third = Enum.find(negotiated, &(&1.session_id == third_session_id))
      target_monitor = Process.monitor(target.peer_connection)
      third_packets_before = outbound_packet_count(third.peer_connection)

      assert :ok = Voice.end_user_session(voice_channel_id, target_user.id)
      assert_receive {:DOWN, ^target_monitor, :process, _, _reason}
      assert {:ok, %{occupancy: 2, capacity: 5}} = Voice.room_occupancy(voice_channel_id)

      assert {:error, :not_found} =
               Voice.dispatch_test_ex_webrtc(
                 voice_channel_id,
                 target_session_id,
                 {:ex_webrtc, target.peer_connection, {:track, target.track}}
               )

      retained_packet =
        ExRTP.Packet.new(<<10>>, payload_type: 111, sequence_number: 10, timestamp: 10, ssrc: 10)

      assert :ok =
               Voice.dispatch_test_ex_webrtc(
                 voice_channel_id,
                 retained_session_id,
                 {:ex_webrtc, retained.peer_connection,
                  {:rtp, retained.track.id, nil, retained_packet}}
               )

      assert :ok = RoomServer.sync_test_media(room_server(voice_channel_id))
      assert outbound_packet_count(third.peer_connection) == third_packets_before + 1

      assert :ok = Voice.end_user_session(voice_channel_id, target_user.id)
      assert {:ok, %{occupancy: 2, capacity: 5}} = Voice.room_occupancy(voice_channel_id)
    end

    test "does not let a late notification for an old room end a moved Voice Session" do
      old_voice_channel_id = Ecto.UUID.generate()
      current_voice_channel_id = Ecto.UUID.generate()
      user_id = Ecto.UUID.generate()

      assert {:ok, _old_join} =
               Voice.join(old_voice_channel_id, user_id, "old-connection", self())

      assert {:ok, _current_join} =
               Voice.join(current_voice_channel_id, user_id, "current-connection", self())

      assert :ok = Voice.end_user_session(old_voice_channel_id, user_id)

      assert {:ok, %{occupancy: 0, capacity: 5}} = Voice.room_occupancy(old_voice_channel_id)
      assert {:ok, %{occupancy: 1, capacity: 5}} = Voice.room_occupancy(current_voice_channel_id)
    end

    test "ends every Voice Session in one channel and retires only that empty room" do
      ended_voice_channel_id = Ecto.UUID.generate()
      unrelated_voice_channel_id = Ecto.UUID.generate()

      ended_sessions =
        for number <- 1..2 do
          user = user_fixture()

          assert {:ok, %{voice_session_id: voice_session_id, occupancy: ^number}} =
                   Voice.join(
                     ended_voice_channel_id,
                     user.id,
                     "ended-connection-#{number}",
                     self()
                   )

          %{number: number, user: user, voice_session_id: voice_session_id}
        end

      ended_sessions =
        Enum.reduce(ended_sessions, [], fn session, negotiated ->
          assert {:ok, _answer} =
                   Voice.accept_offer(
                     Scope.for_user(session.user),
                     ended_voice_channel_id,
                     session.voice_session_id,
                     "ended-negotiation-#{session.number}",
                     browser_offer()
                   )

          peer_connection =
            peer_connection_for_session(ended_voice_channel_id, session.voice_session_id)

          inbound_track = inbound_audio_transceiver(peer_connection).receiver.track

          assert :ok =
                   Voice.dispatch_test_ex_webrtc(
                     ended_voice_channel_id,
                     session.voice_session_id,
                     {:ex_webrtc, peer_connection, {:track, inbound_track}}
                   )

          [Map.put(session, :peer_connection, peer_connection) | negotiated]
        end)

      assert :ok = RoomServer.sync_test_media(room_server(ended_voice_channel_id))

      assert {:ok, %{occupancy: 1}} =
               Voice.join(
                 unrelated_voice_channel_id,
                 Ecto.UUID.generate(),
                 "unrelated-connection",
                 self()
               )

      ended_monitors =
        Enum.map(ended_sessions, fn session ->
          {session.peer_connection, Process.monitor(session.peer_connection)}
        end)

      [unrelated_peer_connection] =
        ExWebRTC.PeerConnection.get_all_running() --
          Enum.map(ended_sessions, & &1.peer_connection)

      unrelated_monitor = Process.monitor(unrelated_peer_connection)
      assert :ok = Voice.end_channel_sessions(ended_voice_channel_id)
      assert :ok = Voice.await_empty_room(ended_voice_channel_id)

      for {peer_connection, monitor} <- ended_monitors do
        assert_receive {:DOWN, ^monitor, :process, ^peer_connection, _reason}
      end

      refute_receive {:DOWN, ^unrelated_monitor, :process, ^unrelated_peer_connection, _reason}, 0

      for session <- ended_sessions do
        assert {:error, :not_found} =
                 Voice.dispatch_test_ex_webrtc(
                   ended_voice_channel_id,
                   session.voice_session_id,
                   {:ex_webrtc, session.peer_connection, {:connection_state_change, :connected}}
                 )
      end

      assert {:ok, %{occupancy: 0, capacity: 5}} =
               Voice.room_occupancy(ended_voice_channel_id)

      assert {:ok, %{occupancy: 1, capacity: 5}} =
               Voice.room_occupancy(unrelated_voice_channel_id)

      assert :ok = Voice.expire_idle_room(ended_voice_channel_id)
      refute Voice.room_running?(ended_voice_channel_id)
    end

    test "treats missing and malformed durable cleanup notifications safely" do
      voice_channel_id = Ecto.UUID.generate()
      user_id = Ecto.UUID.generate()

      assert :ok = Voice.end_user_session(voice_channel_id, user_id)
      assert :ok = Voice.end_channel_sessions(voice_channel_id)
      assert Voice.end_user_session("not-a-uuid", user_id) == {:error, :not_found}
      assert Voice.end_channel_sessions("not-a-uuid") == {:error, :not_found}
    end
  end

  defp room_server(voice_channel_id) do
    {:via, Registry, {DiscordClone.Voice.RoomRegistry, {:room, voice_channel_id}}}
    |> GenServer.whereis()
  end

  defp await_server_ice_candidate(voice_session_id, negotiation_id, predicate, attempts \\ 10)

  defp await_server_ice_candidate(_voice_session_id, _negotiation_id, _predicate, 0) do
    flunk("expected a matching server ICE candidate")
  end

  defp await_server_ice_candidate(voice_session_id, negotiation_id, predicate, attempts) do
    receive do
      {:voice_session_event, ^voice_session_id, {:ice_candidate, ^negotiation_id, candidate}} ->
        if predicate.(candidate) do
          candidate
        else
          await_server_ice_candidate(
            voice_session_id,
            negotiation_id,
            predicate,
            attempts - 1
          )
        end
    after
      1_000 -> flunk("expected a server ICE candidate")
    end
  end

  defp collect_server_ice_candidates(voice_session_id, negotiation_id, candidates \\ []) do
    receive do
      {:voice_session_event, ^voice_session_id, {:ice_candidate, ^negotiation_id, candidate}} ->
        collect_server_ice_candidates(voice_session_id, negotiation_id, [candidate | candidates])

      {:voice_session_event, ^voice_session_id, {:end_of_candidates, ^negotiation_id}} ->
        Enum.reverse(candidates)
    after
      1_000 -> flunk("expected server ICE gathering to complete")
    end
  end

  defp start_test_stun_server(mapped_address) do
    test_pid = self()
    server_ref = make_ref()

    _server =
      start_supervised!(%{
        id: server_ref,
        start:
          {Task, :start_link,
           [
             fn ->
               {:ok, socket} =
                 :gen_udp.open(0, [:binary, active: false, ip: {127, 0, 0, 1}])

               {:ok, {_address, port}} = :inet.sockname(socket)
               send(test_pid, {:test_stun_server_ready, server_ref, port})
               serve_test_stun(socket, mapped_address)
             end
           ]}
      })

    assert_receive {:test_stun_server_ready, ^server_ref, port}
    "stun:127.0.0.1:#{port}"
  end

  defp serve_test_stun(socket, mapped_address) do
    case :gen_udp.recv(socket, 0) do
      {:ok, {client_address, client_port, raw_request}} ->
        {:ok, request} = ExSTUN.Message.decode(raw_request)

        response =
          ExSTUN.Message.new(
            request.transaction_id,
            %ExSTUN.Message.Type{class: :success_response, method: :binding},
            [
              %ExSTUN.Message.Attribute.XORMappedAddress{
                address: mapped_address,
                port: client_port
              }
            ]
          )
          |> ExSTUN.Message.encode()

        :ok = :gen_udp.send(socket, client_address, client_port, response)
        serve_test_stun(socket, mapped_address)

      {:error, :closed} ->
        :ok
    end
  end

  defp browser_offer_with_audio_level do
    peer_connection =
      start_supervised!(%{
        id: make_ref(),
        restart: :temporary,
        start:
          {ExWebRTC.PeerConnection, :start_link,
           [
             [
               ice_servers: [],
               controlling_process: self(),
               rtp_header_extensions: [
                 %{type: :all, uri: "urn:ietf:params:rtp-hdrext:sdes:mid"},
                 %{type: :audio, uri: "urn:ietf:params:rtp-hdrext:ssrc-audio-level"}
               ]
             ]
           ]}
      })

    assert {:ok, _microphone_transceiver} =
             ExWebRTC.PeerConnection.add_transceiver(
               peer_connection,
               ExWebRTC.MediaStreamTrack.new(:audio),
               direction: :sendonly
             )

    Enum.each(List.duplicate(:audio_output_slot, 4), fn _slot ->
      assert {:ok, _audio_output_transceiver} =
               ExWebRTC.PeerConnection.add_transceiver(peer_connection, :audio,
                 direction: :recvonly
               )
    end)

    assert {:ok, description} = ExWebRTC.PeerConnection.create_offer(peer_connection)
    assert :ok = ExWebRTC.PeerConnection.set_local_description(peer_connection, description)
    serialized_description = ExWebRTC.SessionDescription.to_json(description)
    :ok = ExWebRTC.PeerConnection.stop(peer_connection)
    serialized_description
  end

  defp runtime_candidate(number, options \\ []) do
    address = Keyword.get(options, :address, "127.0.0.1")
    priority = Keyword.get(options, :priority, 1)
    port = Keyword.get(options, :port, 10_000 + number)

    candidate = %{
      "candidate" => "candidate:#{number} 1 udp #{priority} #{address} #{port} typ host",
      "sdpMid" => "0",
      "sdpMLineIndex" => 0,
      "usernameFragment" => nil
    }

    %{
      negotiation_id: "current-negotiation",
      candidate: candidate,
      byte_count: byte_size(Jason.encode!(candidate))
    }
  end

  defp command_deadline, do: System.monotonic_time(:millisecond) + 5_000

  defp negotiated_server_peer_connection(excluded) do
    ExWebRTC.PeerConnection.get_all_running()
    |> Enum.reject(&(&1 in excluded))
    |> Enum.find(fn peer_connection ->
      peer_connection
      |> ExWebRTC.PeerConnection.get_transceivers()
      |> Enum.count(&(&1.current_direction == :sendonly))
      |> Kernel.==(4)
    end)
  end

  defp inbound_audio_transceiver(peer_connection) do
    peer_connection
    |> ExWebRTC.PeerConnection.get_transceivers()
    |> Enum.find(&(&1.current_direction == :recvonly))
  end

  defp first_audio_output_transceiver(peer_connection) do
    peer_connection
    |> ExWebRTC.PeerConnection.get_transceivers()
    |> Enum.find(&(&1.current_direction == :sendonly))
  end

  defp audio_output_track_ids(peer_connection) do
    peer_connection
    |> ExWebRTC.PeerConnection.get_transceivers()
    |> Enum.filter(&(&1.current_direction == :sendonly))
    |> Enum.map(& &1.sender.track.id)
  end

  defp outbound_packet_count(peer_connection) do
    peer_connection
    |> ExWebRTC.PeerConnection.get_stats()
    |> Map.values()
    |> Enum.filter(&(&1.type == :outbound_rtp))
    |> Enum.map(& &1.packets_sent)
    |> Enum.sum()
  end

  defp peer_connection_for_session(voice_channel_id, voice_session_id) do
    %{memberships: memberships} = :sys.get_state(room_server(voice_channel_id))
    session = :sys.get_state(memberships[voice_session_id].session_pid)
    session.peer_connection.peer_connection
  end

  defp start_room_server(voice_channel_id, opts) do
    room_server =
      start_supervised!(%{
        id: {:voice_lease_room_server, voice_channel_id},
        start:
          {RoomServer, :start_link,
           [
             [
               voice_channel_id: voice_channel_id,
               room_supervisor:
                 start_signaling_channel({:lease_room_supervisor, voice_channel_id})
             ] ++ opts
           ]}
      })

    _session_supervisor =
      start_supervised!(%{
        id: {:voice_lease_session_supervisor, voice_channel_id},
        start: {SessionSupervisor, :start_link, [[voice_channel_id: voice_channel_id]]}
      })

    _forwarder =
      start_supervised!(%{
        id: {:voice_lease_forwarder, voice_channel_id},
        start: {Forwarder, :start_link, [[voice_channel_id: voice_channel_id]]}
      })

    room_server
  end

  defp negotiate_room_sessions(room_server, session_count, label) do
    running_before = ExWebRTC.PeerConnection.get_all_running()

    1..session_count
    |> Enum.map(fn number ->
      user_id = Ecto.UUID.generate()

      assert {:ok, %{voice_session_id: voice_session_id}} =
               RoomServer.join(room_server, user_id, "#{label}-connection-#{number}", self())

      %{number: number, user_id: user_id, voice_session_id: voice_session_id}
    end)
    |> Enum.reduce({[], running_before}, fn session, {sessions, excluded_peer_connections} ->
      assert {:ok, _answer} =
               RoomServer.accept_offer(
                 room_server,
                 session.user_id,
                 session.voice_session_id,
                 "#{label}-negotiation-#{session.number}",
                 browser_offer(),
                 command_deadline()
               )

      peer_connection = negotiated_server_peer_connection(excluded_peer_connections)
      inbound_track = inbound_audio_transceiver(peer_connection).receiver.track

      assert :ok =
               RoomServer.dispatch_test_ex_webrtc(
                 room_server,
                 session.voice_session_id,
                 {:ex_webrtc, peer_connection, {:track, inbound_track}}
               )

      session =
        session
        |> Map.put(:peer_connection, peer_connection)
        |> Map.put(:inbound_track, inbound_track)

      {[session | sessions], [peer_connection | excluded_peer_connections]}
    end)
    |> then(fn {sessions, _peer_connections} ->
      assert :ok = RoomServer.sync_test_media(room_server)
      Enum.reverse(sessions)
    end)
  end

  defp attach_five_session_diagnostics(expected_forwarded_packets) do
    handler_id = "five-session-routes-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:discord_clone, :voice_signaling, :operation],
        fn _, _, metadata, _ ->
          if metadata[:media_lifecycle] == :rtp_dropped or
               metadata[:forwarded_packet_count] == expected_forwarded_packets do
            send(test_pid, {:five_session_route_diagnostic, metadata})
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp start_signaling_channel(id) do
    start_supervised!(%{
      id: {:voice_signaling_channel, id},
      start:
        {Task, :start_link,
         [
           fn ->
             receive do
               :stop -> :ok
             end
           end
         ]}
    })
  end
end
