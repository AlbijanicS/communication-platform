defmodule DiscordClone.Voice.SessionTest do
  use ExUnit.Case, async: false

  import DiscordCloneWeb.VoiceSignalingHelpers

  alias DiscordClone.Voice.Session

  test "a destination Session validates its identity and outbound readiness before sending RTP" do
    voice_session_id = Ecto.UUID.generate()
    session = start_session(voice_session_id)

    packet =
      ExRTP.Packet.new(<<1, 2, 3>>, payload_type: 111, sequence_number: 1, timestamp: 1, ssrc: 1)

    assert :ok = Session.deliver_rtp(session, voice_session_id, 0, packet)
    _ = :sys.get_state(session)
    refute_receive {:peer_connection_rtp_sent, _, _, _}, 0

    assert {:ok, _answer} = Session.accept_offer(session, "negotiation-1", browser_offer())

    assert :ok = Session.deliver_rtp(session, Ecto.UUID.generate(), 0, packet)
    _ = :sys.get_state(session)
    refute_receive {:peer_connection_rtp_sent, _, _, _}, 0

    assert :ok = Session.deliver_rtp(session, voice_session_id, 4, packet)
    _ = :sys.get_state(session)
    refute_receive {:peer_connection_rtp_sent, _, _, _}, 0

    assert :ok = Session.deliver_rtp(session, voice_session_id, 2, packet)

    assert_receive {:peer_connection_rtp_sent, peer_connection, outbound_track_id, ^packet}
    assert is_pid(peer_connection)

    expected_track_id =
      peer_connection
      |> ExWebRTC.PeerConnection.get_transceivers()
      |> Enum.filter(&(&1.current_direction == :sendonly))
      |> Enum.at(2)
      |> then(& &1.sender.track.id)

    assert outbound_track_id == expected_track_id
  end

  test "accepted inbound RTP from a lone Session is not echoed" do
    voice_session_id = Ecto.UUID.generate()
    session = start_session(voice_session_id)

    assert {:ok, _answer} = Session.accept_offer(session, "negotiation-1", browser_offer())

    [peer_connection] =
      Enum.filter(ExWebRTC.PeerConnection.get_all_running(), fn peer_connection ->
        peer_connection
        |> ExWebRTC.PeerConnection.get_transceivers()
        |> Enum.count(&(&1.current_direction == :sendonly))
        |> Kernel.==(4)
      end)

    transceiver =
      peer_connection
      |> ExWebRTC.PeerConnection.get_transceivers()
      |> Enum.find(&(&1.current_direction == :recvonly))

    inbound_track = transceiver.receiver.track

    send(session, {:ex_webrtc, peer_connection, {:track, inbound_track}})

    packet =
      ExRTP.Packet.new(<<4, 5, 6>>, payload_type: 111, sequence_number: 2, timestamp: 2, ssrc: 2)

    send(session, {:ex_webrtc, peer_connection, {:rtp, inbound_track.id, nil, packet}})
    _ = :sys.get_state(session)

    refute_receive {:peer_connection_rtp_sent, _, _, _}, 0
  end

  test "stops when the first offer does not arrive before negotiation starts" do
    session = start_session(Ecto.UUID.generate(), negotiation_timeout_ms: 10)
    ref = Process.monitor(session)

    assert_receive {:DOWN, ^ref, :process, ^session, :normal}
  end

  test "concurrent Voice offers admit one negotiation and reject the other" do
    session = start_session(Ecto.UUID.generate())
    offer = browser_offer()
    test_process = self()

    for negotiation_id <- ["first", "second"] do
      start_supervised!(%{
        id: make_ref(),
        start:
          {Task, :start_link,
           [
             fn ->
               send(
                 test_process,
                 {:offer_reply, Session.accept_offer(session, negotiation_id, offer)}
               )
             end
           ]}
      })
    end

    assert_receive {:offer_reply, {:ok, %{"type" => "answer"}}}
    assert_receive {:offer_reply, {:error, :negotiation_already_active}}
  end

  test "an offer deadline retires its exact Voice peer and buffered candidates" do
    before = MapSet.new(ExWebRTC.PeerConnection.get_all_running())
    session = start_session(Ecto.UUID.generate())
    [peer] = Enum.reject(ExWebRTC.PeerConnection.get_all_running(), &MapSet.member?(before, &1))
    peer_monitor = Process.monitor(peer)
    session_monitor = Process.monitor(session)
    candidate = runtime_candidate()
    assert {:ok, _} = Session.add_ice_candidate(session, "same-id", candidate)
    offer = browser_offer()
    :ok = :sys.suspend(peer)
    deadline = System.monotonic_time(:millisecond) + 20

    # The caller and peer use the same deadline; either can observe expiry first.
    result =
      try do
        Session.accept_offer(session, "same-id", offer, deadline)
      catch
        :exit, {:timeout, _} -> :caller_timeout
      end

    assert result in [:caller_timeout, {:error, :negotiation_failed}]
    assert_receive {:DOWN, ^session_monitor, :process, ^session, :normal}, 2_000
    assert_receive {:DOWN, ^peer_monitor, :process, ^peer, :normal}, 2_000
    refute peer in ExWebRTC.PeerConnection.get_all_running()

    replacement = start_session(Ecto.UUID.generate())
    assert {:ok, _} = Session.accept_offer(replacement, "same-id", offer)

    for _ <- 1..64 do
      assert {:ok, _} = Session.add_ice_candidate(replacement, "same-id", candidate)
    end

    assert {:error, :candidate_limit_reached} =
             Session.add_ice_candidate(replacement, "same-id", candidate)
  end

  test "signaling-channel loss retires a Voice Session with pending ICE" do
    signaling_channel =
      start_supervised!(%{id: make_ref(), start: {Agent, :start_link, [fn -> nil end]}})

    before = MapSet.new(ExWebRTC.PeerConnection.get_all_running())
    session = start_session(Ecto.UUID.generate(), signaling_channel: signaling_channel)
    [peer] = Enum.reject(ExWebRTC.PeerConnection.get_all_running(), &MapSet.member?(before, &1))
    peer_monitor = Process.monitor(peer)
    session_monitor = Process.monitor(session)
    assert {:ok, _} = Session.add_ice_candidate(session, "same-id", runtime_candidate())
    assert :ok = GenServer.stop(signaling_channel)
    assert_receive {:DOWN, ^session_monitor, :process, ^session, :normal}
    assert_receive {:DOWN, ^peer_monitor, :process, ^peer, :normal}
  end

  test "unknown selected-route evidence is diagnostic and does not terminate Voice" do
    test_process = self()
    handler_id = "ticket-07-server-unknown-#{System.unique_integer()}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:discord_clone, :voice_signaling, :operation],
        fn _event, measurements, metadata, _config ->
          if Map.get(metadata, :operation) == "ice_route" do
            send(test_process, {:server_route_diagnostic, measurements, metadata})
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    running_before = MapSet.new(ExWebRTC.PeerConnection.get_all_running())

    session =
      start_session(Ecto.UUID.generate(),
        test_peer_connection_opts: [
          test_stats_reader: fn _pid -> raise "forbidden raw stats exception" end
        ]
      )

    [peer_connection] =
      ExWebRTC.PeerConnection.get_all_running()
      |> Enum.reject(&MapSet.member?(running_before, &1))

    send(session, {:ex_webrtc, peer_connection, {:connection_state_change, :connected}})
    _ = :sys.get_state(session)

    assert_receive {:server_route_diagnostic, %{duration_ms: duration_ms}, metadata}
    assert duration_ms in 0..60_000

    assert metadata == %{
             endpoint: :server,
             error_code: :stats_unavailable,
             ice_mode: :disabled,
             operation: "ice_route",
             outcome: :failed,
             protocol: :unknown,
             route_category: :unknown
           }

    refute inspect(metadata) =~ "forbidden raw stats exception"
  end

  test "server selected-route telemetry redacts raw stats and deduplicates unchanged categories" do
    test_process = self()
    handler_id = "ticket-07-server-routes-#{System.unique_integer()}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:discord_clone, :voice_signaling, :operation],
        fn _event, measurements, metadata, _config ->
          if Map.get(metadata, :operation) == "ice_route" do
            send(test_process, {:server_route_diagnostic, measurements, metadata})
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    stats_agent =
      start_supervised!(%{
        id: make_ref(),
        start:
          {Agent, :start_link,
           [
             fn ->
               [server_ice_stats(:host), server_ice_stats(:host), server_ice_stats(:relay)]
             end
           ]}
      })

    stats_reader = fn _peer_connection ->
      Agent.get_and_update(stats_agent, fn [stats | remaining] -> {stats, remaining} end)
    end

    running_before = MapSet.new(ExWebRTC.PeerConnection.get_all_running())

    session =
      start_session(Ecto.UUID.generate(),
        test_peer_connection_opts: [test_stats_reader: stats_reader]
      )

    [peer_connection] =
      ExWebRTC.PeerConnection.get_all_running()
      |> Enum.reject(&MapSet.member?(running_before, &1))

    for _connection_event <- 1..3 do
      send(session, {:ex_webrtc, peer_connection, {:connection_state_change, :connected}})
      _ = :sys.get_state(session)
    end

    assert_receive {:server_route_diagnostic, %{duration_ms: host_duration}, host_metadata}
    assert_receive {:server_route_diagnostic, %{duration_ms: relay_duration}, relay_metadata}
    refute_receive {:server_route_diagnostic, _, _}, 0

    assert host_duration in 0..60_000
    assert relay_duration in 0..60_000
    assert host_metadata.route_category == :host_direct
    assert relay_metadata.route_category == :turn_relay

    captured = inspect([host_metadata, relay_metadata])

    for forbidden <- [
          "forbidden-local-id",
          "forbidden-remote-id",
          "forbidden-address",
          "forbidden-port",
          "forbidden-foundation",
          "forbidden-related-address",
          "forbidden-url",
          "forbidden-credential",
          "forbidden-user-id",
          "forbidden-voice-session-id"
        ] do
      refute captured =~ forbidden
    end
  end

  defp start_session(voice_session_id, opts \\ []) do
    session_opts =
      Keyword.merge(
        [
          room_server: self(),
          voice_session_id: voice_session_id,
          signaling_channel: self(),
          test_peer_connection_opts: [test_rtp_observer: self()]
        ],
        opts
      )

    start_supervised!({Session, session_opts}, id: make_ref())
  end

  defp runtime_candidate do
    candidate = browser_ice_candidate()
    %{negotiation_id: "same-id", candidate: candidate, byte_count: encoded_size(candidate)}
  end

  defp server_ice_stats(remote_type) do
    %{
      "selected" => %{
        type: :candidate_pair,
        valid: true,
        nominated: true,
        state: :succeeded,
        local_candidate_id: "local",
        remote_candidate_id: "remote",
        url: "forbidden-url"
      },
      "local" => %{
        id: "forbidden-local-id",
        type: :local_candidate,
        candidate_type: :host,
        protocol: :udp,
        address: "forbidden-address",
        port: "forbidden-port",
        foundation: "forbidden-foundation",
        credential: "forbidden-credential"
      },
      "remote" => %{
        id: "forbidden-remote-id",
        type: :remote_candidate,
        candidate_type: remote_type,
        protocol: :udp,
        related_address: "forbidden-related-address",
        user_id: "forbidden-user-id",
        voice_session_id: "forbidden-voice-session-id"
      }
    }
  end
end
