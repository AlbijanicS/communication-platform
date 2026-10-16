defmodule DiscordClone.Voice.PeerConnectionTest do
  use ExUnit.Case, async: false

  alias DiscordClone.Voice.{PeerConnection, ServerICEProjection}
  alias DiscordCloneWeb.VoiceSignaling.RealMessage
  import DiscordCloneWeb.VoiceSignalingHelpers

  test "creates a serialized answer for a browser-shaped offer" do
    offer = browser_offer()
    peer_connection = start_supervised_peer_connection()

    assert {:ok, answer, peer_connection} = PeerConnection.accept_offer(peer_connection, offer)
    assert %{"type" => "answer", "sdp" => sdp} = answer
    assert is_binary(sdp)
    assert byte_size(sdp) > 0

    transceivers =
      ExWebRTC.PeerConnection.get_transceivers(peer_connection.peer_connection)

    assert Enum.count(transceivers, &(&1.current_direction == :recvonly)) == 1
    assert Enum.count(transceivers, &(&1.current_direction == :sendonly)) == 4

    outbound_track_ids =
      transceivers
      |> Enum.filter(&(&1.current_direction == :sendonly))
      |> Enum.map(& &1.sender.track.id)

    assert outbound_track_ids ==
             Enum.map(0..3, &Map.fetch!(peer_connection.audio_output_slot_track_ids, &1))
  end

  test "rejects an offer that cannot provide all four Audio Output Slots" do
    peer_connection = start_supervised_peer_connection()

    assert {:error, :incompatible_audio_output_slots} =
             PeerConnection.accept_offer(peer_connection, browser_offer(3))
  end

  test "rejects startup failure without leaving a PeerConnection process behind" do
    running_before = MapSet.new(ExWebRTC.PeerConnection.get_all_running())

    assert {:error, :peer_connection_unavailable} =
             PeerConnection.start(ServerICEProjection.disabled(), audio_codecs: [:invalid])

    assert MapSet.new(ExWebRTC.PeerConnection.get_all_running()) == running_before
  end

  test "rejects an invalid projection before allocating a PeerConnection or logging its values" do
    running_before = MapSet.new(ExWebRTC.PeerConnection.get_all_running())

    on_exit(fn ->
      ExWebRTC.PeerConnection.get_all_running()
      |> Enum.reject(&MapSet.member?(running_before, &1))
      |> Enum.each(&ExWebRTC.PeerConnection.stop/1)
    end)

    projection = %ServerICEProjection{
      ice_mode: :unsupported,
      ice_servers: [%{urls: "stun:sensitive-network.example.test:3478"}]
    }

    logs =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, :peer_connection_unavailable} = PeerConnection.start(projection)
      end)

    refute logs =~ "sensitive-network.example.test"
    assert MapSet.new(ExWebRTC.PeerConnection.get_all_running()) == running_before
  end

  test "exposes ExWebRTC statistics through the public application wrapper" do
    peer_connection = start_supervised_peer_connection()

    assert {:ok, stats} = PeerConnection.get_stats(peer_connection)
    assert is_map(stats)
  end

  test "repeated stop releases only the exact peer while another can still negotiate" do
    retired = start_supervised_peer_connection()
    survivor = start_supervised_peer_connection()
    retired_monitor = Process.monitor(retired.peer_connection)

    assert {:ok, _answer, retired} = PeerConnection.accept_offer(retired, browser_offer())
    retired_pid = retired.peer_connection
    assert_receive {:ex_webrtc, ^retired_pid, {:ice_candidate, candidate}}

    assert {:ok, allocation} =
             candidate.candidate
             |> String.trim_leading("candidate:")
             |> ExICE.Candidate.unmarshal()

    socket_options =
      [active: false, ip: allocation.address] ++
        if(tuple_size(allocation.address) == 8, do: [:inet6], else: [:inet])

    assert {:error, :eaddrinuse} = :gen_udp.open(allocation.port, socket_options)

    assert :ok = PeerConnection.stop(retired)
    assert_receive {:DOWN, ^retired_monitor, :process, _, :normal}
    assert :ok = PeerConnection.stop(retired)
    assert {:ok, socket} = :gen_udp.open(allocation.port, socket_options)
    :ok = :gen_udp.close(socket)

    assert {:ok, _answer, survivor} = PeerConnection.accept_offer(survivor, browser_offer())
    assert {:ok, stats} = PeerConnection.get_stats(survivor)
    assert is_map(stats)
    refute retired.peer_connection in ExWebRTC.PeerConnection.get_all_running()
  end

  test "a peer lost during startup does not leak or stop an unrelated connection" do
    survivor = start_supervised_peer_connection()
    running_before = MapSet.new(ExWebRTC.PeerConnection.get_all_running())
    observer = self()
    reference = make_ref()

    starter =
      start_supervised!(
        {Task,
         fn ->
           result =
             PeerConnection.start(ServerICEProjection.disabled(),
               test_readiness_gate: {observer, reference}
             )

           send(observer, {:startup_result, reference, result})
         end}
      )

    assert_receive {:peer_connection_starting, ^reference, ^starter}

    [starting_peer] =
      Enum.reject(ExWebRTC.PeerConnection.get_all_running(), &MapSet.member?(running_before, &1))

    starting_monitor = Process.monitor(starting_peer)
    assert :ok = ExWebRTC.PeerConnection.stop(starting_peer)
    assert_receive {:DOWN, ^starting_monitor, :process, ^starting_peer, :normal}
    send(starter, {:release_peer_connection_start, reference})

    assert_receive {:startup_result, ^reference, {:error, :peer_connection_unavailable}}
    assert MapSet.new(ExWebRTC.PeerConnection.get_all_running()) == running_before
    assert {:ok, _answer, _survivor} = PeerConnection.accept_offer(survivor, browser_offer())
  end

  test "classifies only one complete valid nominated succeeded ICE pair" do
    stats = %{
      "selected" => %{
        type: :candidate_pair,
        valid: true,
        nominated: true,
        state: :succeeded,
        local_candidate_id: "local-forbidden-id",
        remote_candidate_id: "remote-forbidden-id"
      },
      "local-forbidden-id" => %{
        type: :local_candidate,
        candidate_type: :host,
        protocol: :udp,
        address: "192.0.2.10",
        port: 50_000
      },
      "remote-forbidden-id" => %{
        type: :remote_candidate,
        candidate_type: :relay,
        protocol: :udp,
        address: "198.51.100.20",
        port: 34_789
      }
    }

    peer_connection = start_supervised_peer_connection(test_stats_reader: fn _pid -> stats end)

    assert %{route_category: :turn_relay, protocol: :udp, outcome: :accepted} =
             PeerConnection.selected_ice_route(peer_connection)
  end

  test "classifies all safe server categories and rejects ambiguous or incomplete evidence" do
    peer_connection =
      start_supervised_peer_connection(test_stats_reader: fn _pid -> Process.get(:ice_stats) end)

    for {local_type, remote_type, expected} <- [
          {:host, :host, :host_direct},
          {:host, :srflx, :reflexive_direct},
          {:prflx, :relay, :turn_relay}
        ] do
      Process.put(:ice_stats, server_ice_stats(local_type, remote_type))

      assert %{route_category: ^expected, protocol: :udp, outcome: :accepted} =
               PeerConnection.selected_ice_route(peer_connection)
    end

    for stats <- [
          %{},
          Map.delete(server_ice_stats(:host, :host), "remote"),
          server_ice_stats(:host, :unsupported),
          Map.put(
            server_ice_stats(:host, :host),
            "second",
            Map.put(server_ice_stats(:host, :host)["selected"], :id, "second")
          )
        ] do
      Process.put(:ice_stats, stats)

      assert %{route_category: :unknown, protocol: protocol, outcome: :accepted} =
               PeerConnection.selected_ice_route(peer_connection)

      assert protocol in [:udp, :unknown]
    end
  end

  test "reduces stats failure to bounded unknown evidence" do
    peer_connection =
      start_supervised_peer_connection(
        test_stats_reader: fn _pid -> raise "forbidden raw exception and credential" end
      )

    assert %{
             route_category: :unknown,
             protocol: :unknown,
             outcome: :failed,
             error_code: :stats_unavailable,
             duration_ms: duration_ms
           } = PeerConnection.selected_ice_route(peer_connection)

    assert duration_ms in 0..60_000
  end

  test "returns accepted source media without echoing and sends through its destination track" do
    peer_connection =
      start_supervised_peer_connection()
      |> Map.put(:test_rtp_observer, self())

    assert {:ok, _answer, peer_connection} =
             PeerConnection.accept_offer(peer_connection, browser_offer())

    transceivers = ExWebRTC.PeerConnection.get_transceivers(peer_connection.peer_connection)
    transceiver = Enum.find(transceivers, &(&1.current_direction == :recvonly))
    first_output_slot = Enum.find(transceivers, &(&1.current_direction == :sendonly))

    assert transceiver.kind == :audio

    assert first_output_slot.sender.track.id ==
             Map.fetch!(peer_connection.audio_output_slot_track_ids, 0)

    assert Enum.any?(transceiver.codecs, &(&1.mime_type == "audio/opus"))

    inbound_track = transceiver.receiver.track

    assert {{:accepted_inbound_track, inbound_track_id}, peer_connection} =
             PeerConnection.route_media(peer_connection, {
               :ex_webrtc,
               peer_connection.peer_connection,
               {:track, inbound_track}
             })

    assert inbound_track_id == inbound_track.id

    packet =
      ExRTP.Packet.new(<<1, 2, 3>>, payload_type: 111, sequence_number: 1, timestamp: 1, ssrc: 1)

    assert {{:accepted_inbound_rtp, ^inbound_track_id, ^packet}, ^peer_connection} =
             PeerConnection.route_media(peer_connection, {
               :ex_webrtc,
               peer_connection.peer_connection,
               {:rtp, inbound_track.id, nil, packet}
             })

    refute_receive {:peer_connection_rtp_sent, _, _, _}, 0

    assert :ok = PeerConnection.send_rtp(peer_connection, 0, packet)

    peer_connection_pid = peer_connection.peer_connection
    outbound_track_id = Map.fetch!(peer_connection.audio_output_slot_track_ids, 0)

    assert_receive {:peer_connection_rtp_sent, ^peer_connection_pid, ^outbound_track_id, ^packet}

    assert :ok = PeerConnection.send_rtp(peer_connection, 2, packet)
    slot_two_track_id = Map.fetch!(peer_connection.audio_output_slot_track_ids, 2)

    assert_receive {:peer_connection_rtp_sent, ^peer_connection_pid, ^slot_two_track_id, ^packet}

    assert {:error, :outbound_track_unavailable} =
             PeerConnection.send_rtp(peer_connection, 4, packet)

    _ = :sys.get_state(peer_connection.peer_connection)

    assert %{packets_sent: 1, bytes_sent: bytes_sent} =
             peer_connection.peer_connection
             |> ExWebRTC.PeerConnection.get_stats()
             |> Map.values()
             |> Enum.find(fn stats ->
               stats.type == :outbound_rtp and
                 stats.track_identifier ==
                   Map.fetch!(peer_connection.audio_output_slot_track_ids, 0)
             end)

    assert bytes_sent > byte_size(packet.payload)

    assert {:dropped_rtp, ^peer_connection} =
             PeerConnection.route_media(peer_connection, {
               :ex_webrtc,
               peer_connection.peer_connection,
               {:rtp, inbound_track.id + 1, nil, packet}
             })

    assert {{:accepted_inbound_track_muted, ^inbound_track_id}, ^peer_connection} =
             PeerConnection.route_media(peer_connection, {
               :ex_webrtc,
               peer_connection.peer_connection,
               {:track_muted, inbound_track.id}
             })

    assert {{:accepted_inbound_track_ended, ^inbound_track_id}, ended_peer_connection} =
             PeerConnection.route_media(peer_connection, {
               :ex_webrtc,
               peer_connection.peer_connection,
               {:track_ended, inbound_track.id}
             })

    assert {:dropped_rtp, ^ended_peer_connection} =
             PeerConnection.route_media(ended_peer_connection, {
               :ex_webrtc,
               peer_connection.peer_connection,
               {:rtp, inbound_track.id, nil, packet}
             })
  end

  test "drops unsupported media and ignores RTP from another PeerConnection" do
    peer_connection = start_supervised_peer_connection()

    packet =
      ExRTP.Packet.new(<<1, 2, 3>>, payload_type: 111, sequence_number: 1, timestamp: 1, ssrc: 1)

    for message <- [
          {:track, %ExWebRTC.MediaStreamTrack{id: 1, kind: :video}},
          {:track_muted, 1},
          {:track_ended, 1},
          {:data_channel, %{}},
          {:data_channel_state_change, make_ref(), :open},
          {:data, make_ref(), "unsupported"},
          {:rtcp, []}
        ] do
      assert {:dropped_media, ^peer_connection} =
               PeerConnection.route_media(peer_connection, {
                 :ex_webrtc,
                 peer_connection.peer_connection,
                 message
               })
    end

    assert {:dropped_rtp, ^peer_connection} =
             PeerConnection.route_media(peer_connection, {
               :ex_webrtc,
               peer_connection.peer_connection,
               {:rtp, 1, nil, packet}
             })

    assert {:ignore, ^peer_connection} =
             PeerConnection.route_media(peer_connection, {
               :ex_webrtc,
               self(),
               {:rtp, 1, nil, packet}
             })
  end

  test "rejects an offer without a compatible Opus audio source" do
    peer_connection = start_supervised_peer_connection()
    offer = browser_offer()

    incompatible_offer =
      Map.update!(offer, "sdp", &String.replace(&1, "opus/48000/2", "ISAC/16000"))

    assert {:error, :negotiation_failed} =
             PeerConnection.accept_offer(peer_connection, incompatible_offer)
  end

  test "serializes server ICE messages and stops its linked peer process" do
    peer_connection = start_supervised_peer_connection()
    monitor_ref = Process.monitor(peer_connection.peer_connection)

    candidate = %ExWebRTC.ICECandidate{
      candidate: "candidate:1 1 udp 1 127.0.0.1 9 typ host",
      sdp_mid: "0",
      sdp_m_line_index: 0
    }

    assert {:ice_candidate, %{"candidate" => "candidate:1 1 udp 1 127.0.0.1 9 typ host"}} =
             PeerConnection.signal(peer_connection, {
               :ex_webrtc,
               peer_connection.peer_connection,
               {:ice_candidate, candidate}
             })

    assert :ok = PeerConnection.stop(peer_connection)
    assert_receive {:DOWN, ^monitor_ref, :process, _, :normal}
  end

  test "accepts a browser-shaped ICE candidate without a username fragment" do
    payload = %{
      "signaling_session_id" => "current-session",
      "negotiation_id" => "current-negotiation",
      "candidate" => %{
        "candidate" => "candidate:1 1 udp 1 127.0.0.1 9 typ host",
        "sdpMid" => "0",
        "sdpMLineIndex" => 0
      }
    }

    assert {:ok, %{negotiation_id: "current-negotiation", candidate: candidate}} =
             RealMessage.ice_candidate(payload)

    assert candidate["usernameFragment"] == nil
  end

  test "ExWebRTC 0.17.0 marks remote ICE gathering complete with an empty candidate" do
    peer_connection = start_supervised_peer_connection()

    assert {:ok, _answer, peer_connection} =
             PeerConnection.accept_offer(peer_connection, browser_offer())

    peer_connection_pid = peer_connection.peer_connection

    assert_receive {
      :ex_webrtc,
      ^peer_connection_pid,
      {:ice_gathering_state_change, :complete}
    }

    end_of_candidates = %ExWebRTC.ICECandidate{
      candidate: "",
      sdp_mid: "0",
      sdp_m_line_index: 0
    }

    assert :ok =
             ExWebRTC.PeerConnection.add_ice_candidate(
               peer_connection.peer_connection,
               end_of_candidates
             )

    assert :ok = PeerConnection.stop(peer_connection)
  end

  test "serializes the server gathering-complete notification as an end marker" do
    peer_connection = start_supervised_peer_connection()

    assert :end_of_candidates =
             PeerConnection.signal(peer_connection, {
               :ex_webrtc,
               peer_connection.peer_connection,
               {:ice_gathering_state_change, :complete}
             })

    assert :ok = PeerConnection.stop(peer_connection)
  end

  defp start_supervised_peer_connection(options \\ []) do
    peer_connection =
      start_supervised!(%{
        id: make_ref(),
        restart: :temporary,
        start:
          {DiscordClone.Media.Connection, :start_link,
           [ServerICEProjection.disabled(), [controlling_process: self()]]}
      })

    %PeerConnection{
      peer_connection: peer_connection,
      test_stats_reader: Keyword.get(options, :test_stats_reader)
    }
  end

  defp server_ice_stats(local_type, remote_type) do
    %{
      "selected" => %{
        id: "selected",
        type: :candidate_pair,
        valid: true,
        nominated: true,
        state: :succeeded,
        local_candidate_id: "local",
        remote_candidate_id: "remote"
      },
      "local" => %{
        id: "local",
        type: :local_candidate,
        candidate_type: local_type,
        protocol: :udp,
        address: "forbidden-local-address",
        port: 50_000,
        foundation: "forbidden-foundation"
      },
      "remote" => %{
        id: "remote",
        type: :remote_candidate,
        candidate_type: remote_type,
        protocol: :udp,
        address: "forbidden-remote-address",
        port: 34_789,
        related_address: "forbidden-related-address"
      }
    }
  end
end
