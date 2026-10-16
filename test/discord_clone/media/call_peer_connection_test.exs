defmodule DiscordClone.Media.CallPeerConnectionTest do
  use ExUnit.Case, async: false

  require DiscordCloneWeb.VoiceSignalingHelpers

  alias DiscordClone.Media.CallPeerConnection
  alias DiscordClone.Voice.ServerICEProjection
  alias ExWebRTC.{MediaStreamTrack, PeerConnection, SessionDescription}

  test "buffers bounded Call ICE and accepts only its current negotiation" do
    {_browser, offer} = call_offer()
    server = start_server()
    candidate = call_candidate("current")
    deadline = System.monotonic_time(:millisecond) + 10_000

    assert {:ok, %{negotiation_id: "current"}, server} =
             CallPeerConnection.add_ice_candidate(server, "current", candidate, deadline)

    assert {:ok, _answer, server} =
             CallPeerConnection.accept_offer(server, "current", offer, deadline)

    assert {:error, :invalid_negotiation, ^server} =
             CallPeerConnection.add_ice_candidate(
               server,
               "stale",
               call_candidate("stale"),
               deadline
             )

    assert {:error, :negotiation_already_active, ^server} =
             CallPeerConnection.accept_offer(server, "next", offer, deadline)
  end

  test "Call signaling accepts exact payload limits and rejects one extra byte" do
    alias DiscordCloneWeb.Signaling.SdpIce
    alias DiscordCloneWeb.VoiceSignalingHelpers, as: Fixtures

    {_browser, offer} = call_offer()
    padding = 64 * 1024 - byte_size(offer["sdp"]) - byte_size("a=x-padding:\r\n")

    exact_offer =
      Map.update!(
        offer,
        "sdp",
        &(&1 <> "a=x-padding:" <> String.duplicate("x", padding) <> "\r\n")
      )

    server = start_server()
    deadline = System.monotonic_time(:millisecond) + 10_000

    assert {:ok, validated} =
             SdpIce.offer(%{"negotiation_id" => "current", "description" => exact_offer})

    assert validated.byte_count == 64 * 1024

    assert {:ok, _answer, _server} =
             CallPeerConnection.accept_offer(
               server,
               validated.negotiation_id,
               validated.description,
               deadline
             )

    assert {:error, "description_too_large"} =
             SdpIce.offer(%{
               "negotiation_id" => "current",
               "description" => Map.update!(exact_offer, "sdp", &(&1 <> "x"))
             })

    pending = start_server()

    assert {:ok, candidate} =
             SdpIce.ice_candidate(%{
               "negotiation_id" => "current",
               "candidate" => Fixtures.candidate_with_encoded_size(8 * 1024)
             })

    assert {:ok, _, _pending} =
             CallPeerConnection.add_ice_candidate(pending, "current", candidate, deadline)

    assert {:error, "candidate_too_large"} =
             SdpIce.ice_candidate(%{
               "negotiation_id" => "current",
               "candidate" => Fixtures.candidate_with_encoded_size(8 * 1024 + 1)
             })
  end

  test "Call early ICE reaches sixteen candidates and 128 KiB but never exceeds them" do
    alias DiscordCloneWeb.VoiceSignalingHelpers, as: Fixtures
    server = start_server()
    deadline = System.monotonic_time(:millisecond) + 10_000

    candidate = %{
      call_candidate("current")
      | candidate: Fixtures.candidate_with_encoded_size(8 * 1024),
        byte_count: 8 * 1024
    }

    server =
      Enum.reduce(1..16, server, fn _, server ->
        assert {:ok, _, server} =
                 CallPeerConnection.add_ice_candidate(server, "current", candidate, deadline)

        server
      end)

    assert {:error, :pending_candidate_limit_reached, ^server} =
             CallPeerConnection.add_ice_candidate(
               server,
               "current",
               call_candidate("current"),
               deadline
             )

    # Preserve Voice's accounting of normalized candidates: an omitted username
    # fragment can make the validated runtime envelope larger than its wire value.
    assert {:ok, normalized} =
             DiscordCloneWeb.Signaling.SdpIce.ice_candidate(%{
               "negotiation_id" => "current",
               "candidate" => %{
                 "candidate" => String.duplicate("x", 8_130),
                 "sdpMid" => "0",
                 "sdpMLineIndex" => 0
               }
             })

    server =
      Enum.reduce(1..15, start_server(), fn _, server ->
        assert {:ok, _, server} =
                 CallPeerConnection.add_ice_candidate(server, "current", normalized, deadline)

        server
      end)

    assert {:error, :pending_candidate_limit_reached, ^server} =
             CallPeerConnection.add_ice_candidate(server, "current", normalized, deadline)
  end

  test "only matching early Call ICE consumes the sixty-four accepted candidate budget" do
    {_browser, offer} = call_offer()
    deadline = System.monotonic_time(:millisecond) + 10_000

    server =
      Enum.reduce(["stale", "current", "stale-2", "current"], start_server(), fn id, server ->
        assert {:ok, _, server} =
                 CallPeerConnection.add_ice_candidate(server, id, call_candidate(id), deadline)

        server
      end)

    assert {:ok, _, server} = CallPeerConnection.accept_offer(server, "current", offer, deadline)

    assert {:error, :invalid_negotiation, ^server} =
             CallPeerConnection.add_ice_candidate(
               server,
               "current",
               call_candidate("stale"),
               deadline
             )

    server =
      Enum.reduce(1..62, server, fn _, server ->
        assert {:ok, _, server} =
                 CallPeerConnection.add_ice_candidate(
                   server,
                   "current",
                   call_candidate("current"),
                   deadline
                 )

        server
      end)

    assert {:error, :candidate_limit_reached, ^server} =
             CallPeerConnection.add_ice_candidate(
               server,
               "current",
               call_candidate("current"),
               deadline
             )

    assert {:error, :end_of_candidates_unsupported} =
             CallPeerConnection.end_of_candidates(server, "current")

    assert {:error, :invalid_negotiation} = CallPeerConnection.end_of_candidates(server, "stale")
  end

  test "rejected Call offers release buffered work and late ICE cannot revive them" do
    {_browser, offer} = call_offer()
    server = start_server()
    pid = server.peer_connection
    monitor = Process.monitor(pid)
    deadline = System.monotonic_time(:millisecond) + 10_000

    assert {:ok, _, server} =
             CallPeerConnection.add_ice_candidate(
               server,
               "same-id",
               call_candidate("same-id"),
               deadline
             )

    invalid = Map.update!(offer, "sdp", &String.replace(&1, "opus/48000/2", "ISAC/16000"))

    assert {:error, :negotiation_failed, server} =
             CallPeerConnection.accept_offer(server, "same-id", invalid, deadline)

    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}

    assert {:error, :invalid_session, ^server} =
             CallPeerConnection.add_ice_candidate(
               server,
               "same-id",
               call_candidate("same-id"),
               deadline
             )

    assert {:error, :invalid_session, ^server} =
             CallPeerConnection.accept_offer(server, "same-id", offer, deadline)

    assert :ok = CallPeerConnection.stop(server)

    assert {:ok, _, replacement} =
             CallPeerConnection.accept_offer(start_server(), "same-id", offer, deadline)

    replacement =
      Enum.reduce(1..64, replacement, fn _, replacement ->
        assert {:ok, _, replacement} =
                 CallPeerConnection.add_ice_candidate(
                   replacement,
                   "same-id",
                   call_candidate("same-id"),
                   deadline
                 )

        replacement
      end)

    assert {:error, :candidate_limit_reached, ^replacement} =
             CallPeerConnection.add_ice_candidate(
               replacement,
               "same-id",
               call_candidate("same-id"),
               deadline
             )
  end

  @tag timeout: 20_000
  test "the Call offer reply stays within ten seconds while an unrelated peer progresses" do
    {_browser, offer} = call_offer()
    server = start_server()
    pid = server.peer_connection
    monitor = Process.monitor(pid)
    :ok = :sys.suspend(pid)
    test_process = self()
    started_at = System.monotonic_time(:millisecond)

    start_supervised!(%{
      id: make_ref(),
      start:
        {Task, :start_link,
         [
           fn ->
             result =
               CallPeerConnection.accept_offer(server, "current", offer, started_at + 60_000)

             send(
               test_process,
               {:bounded_offer, result, System.monotonic_time(:millisecond) - started_at}
             )
           end
         ]}
    })

    assert {:ok, _, _survivor} = CallPeerConnection.accept_offer(start_server(), offer)
    assert_receive {:bounded_offer, {:error, :negotiation_failed, closed}, elapsed}, 12_000
    assert elapsed < 11_000
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}

    assert {:error, :invalid_session, ^closed} =
             CallPeerConnection.add_ice_candidate(
               closed,
               "current",
               call_candidate("current"),
               started_at + 60_000
             )
  end

  test "negotiates exactly one duplex Opus position and duplex VP8 outbound identity before answer with exact MIDs" do
    {browser, offer} = call_offer()
    server = start_server()

    assert {:ok, answer, server} = CallPeerConnection.accept_offer(server, offer)

    assert :ok =
             PeerConnection.set_remote_description(browser, SessionDescription.from_json(answer))

    assert [audio, video] = PeerConnection.get_transceivers(server.peer_connection)
    assert audio.kind == :audio
    assert audio.current_direction == :sendrecv
    assert video.kind == :video
    assert video.current_direction == :sendrecv
    assert Enum.any?(audio.codecs, &(&1.mime_type == "audio/opus"))
    assert Enum.any?(video.codecs, &(&1.mime_type == "video/VP8"))
    assert audio.sender.codec.mime_type == "audio/opus"
    assert video.sender.codec.mime_type == "video/VP8"
    assert [repair] = Enum.filter(video.codecs, &(&1.mime_type == "video/rtx"))
    assert repair.sdp_fmtp_line.apt == video.sender.codec.payload_type
    assert Enum.any?(video.sender.codec.rtcp_fbs, &(&1.feedback_type == :nack))
    refute Enum.any?(video.codecs, &(&1.mime_type == "video/H264"))
    assert server.audio.mid == audio.mid
    assert server.audio.inbound_track_id == audio.receiver.track.id
    assert server.audio.outbound_track_id == audio.sender.track.id
    assert server.video.mid == video.mid
    assert server.video.inbound_track_id == video.receiver.track.id
    assert server.video.sender_id == video.sender.id
    assert video.sender.track.kind == :video
    assert server.video.outbound_track_id == video.sender.track.id
    assert [stream_id] = audio.sender.track.streams
    assert is_binary(stream_id) and stream_id != ""
    assert video.sender.track.streams == [stream_id]
    assert audio.sender.track.id != video.sender.track.id
    assert [browser_audio, browser_video] = PeerConnection.get_transceivers(browser)
    assert browser_audio.receiver.track.streams == [stream_id]
    assert browser_video.receiver.track.streams == [stream_id]
    assert browser_audio.mid == audio.mid
    assert browser_video.mid == video.mid
    assert browser_video.sender.track == nil
  end

  test "connected audio flows on the exact duplex position while both video senders stay dormant" do
    {browser, offer} = call_offer()
    server = start_server()
    server_pid = server.peer_connection

    assert {:ok, answer, server} =
             CallPeerConnection.accept_offer(
               server,
               "connected",
               offer,
               System.monotonic_time(:millisecond) + 10_000
             )

    assert :ok =
             PeerConnection.set_remote_description(browser, SessionDescription.from_json(answer))

    apply_candidates(server_pid, browser)
    assert_receive {:ex_webrtc, ^browser, {:connection_state_change, :connected}}, 5_000
    assert_receive {:ex_webrtc, ^server_pid, {:connection_state_change, :connected}}, 5_000

    [audio, video] = PeerConnection.get_transceivers(browser)
    payload = <<0xF8, 0xFF, 0xFE>>
    packet = ExRTP.Packet.new(payload, sequence_number: 10, timestamp: 960)
    assert :ok = PeerConnection.send_rtp(browser, audio.sender.track.id, packet)
    inbound_id = server.audio.inbound_track_id
    assert_receive {:ex_webrtc, ^server_pid, {:rtp, ^inbound_id, nil, received}}, 2_000
    assert received.payload == payload

    assert {{:accepted_inbound_rtp, ^inbound_id, ^received}, ^server} =
             CallPeerConnection.route_media(
               server,
               {:ex_webrtc, server_pid, {:rtp, inbound_id, nil, received}}
             )

    assert :ok = PeerConnection.send_rtp(server_pid, server.audio.outbound_track_id, packet)
    destination_id = audio.receiver.track.id

    assert_receive {:ex_webrtc, ^browser, {:rtp, ^destination_id, nil, %{payload: ^payload}}},
                   2_000

    for {peer, track_id, sender_id} <- [
          {server_pid, server.video.inbound_track_id, server.video.sender_id},
          {browser, video.receiver.track.id, video.sender.id}
        ] do
      refute_receive {:ex_webrtc, ^peer, {:rtp, ^track_id, _, _}}, 100

      assert %{type: :outbound_rtp, packets_sent: 0} =
               Map.fetch!(PeerConnection.get_stats(peer), sender_id)
    end
  end

  test "only current outbound video PLI is classified and NACK stays leg local" do
    {_browser, offer} = call_offer()
    server = start_server()
    assert {:ok, _, server} = CallPeerConnection.accept_offer(server, offer)
    pli = %ExRTCP.Packet.PayloadFeedback.PLI{sender_ssrc: 1, media_ssrc: 2}
    nack = %ExRTCP.Packet.TransportFeedback.NACK{sender_ssrc: 1, media_ssrc: 2, nacks: []}

    for {peer, track, packet} <- [
          {self(), server.video.outbound_track_id, pli},
          {server.peer_connection, server.video.inbound_track_id, pli},
          {server.peer_connection, server.audio.outbound_track_id, pli},
          {server.peer_connection, -1, pli},
          {server.peer_connection, server.video.outbound_track_id, nack}
        ] do
      assert {:ignore, ^server} =
               CallPeerConnection.route_media(
                 server,
                 {:ex_webrtc, peer, {:rtcp, [{track, packet}]}}
               )
    end

    assert {:decoder_keyframe_request, ^server} =
             CallPeerConnection.route_media(
               server,
               {:ex_webrtc, server.peer_connection,
                {:rtcp,
                 [
                   {nil, pli},
                   {server.video.outbound_track_id, nack},
                   {server.video.outbound_track_id, pli}
                 ]}}
             )
  end

  test "video, unknown tracks and another peer cannot supply accepted audio" do
    {_browser, offer} = call_offer()
    server = start_server()
    assert {:ok, _answer, server} = CallPeerConnection.accept_offer(server, offer)
    [audio, video] = PeerConnection.get_transceivers(server.peer_connection)
    packet = ExRTP.Packet.new(<<0xF8, 0xFF, 0xFE>>)

    assert {{:accepted_inbound_track, id}, ^server} =
             CallPeerConnection.route_media(
               server,
               {:ex_webrtc, server.peer_connection, {:track, audio.receiver.track}}
             )

    assert id == audio.receiver.track.id

    assert {:dropped_media, ^server} =
             CallPeerConnection.route_media(
               server,
               {:ex_webrtc, server.peer_connection, {:track, video.receiver.track}}
             )

    assert {{:accepted_inbound_video_rtp, video_id, ^packet}, ^server} =
             CallPeerConnection.route_media(
               server,
               {:ex_webrtc, server.peer_connection, {:rtp, video.receiver.track.id, nil, packet}}
             )

    assert video_id == video.receiver.track.id

    for id <- [-1] do
      assert {:dropped_rtp, ^server} =
               CallPeerConnection.route_media(
                 server,
                 {:ex_webrtc, server.peer_connection, {:rtp, id, nil, packet}}
               )
    end

    assert {:ignore, ^server} =
             CallPeerConnection.route_media(
               server,
               {:ex_webrtc, self(), {:rtp, audio.receiver.track.id, nil, packet}}
             )
  end

  for {label, old, new} <- [
        {"missing Opus", "opus/48000/2", "ISAC/16000"},
        {"wrong Opus clock", "opus/48000/2", "opus/16000/2"},
        {"wrong Opus channels", "opus/48000/2", "opus/48000/6"},
        {"missing VP8", "VP8/90000", "VP9/90000"},
        {"wrong VP8 clock", "VP8/90000", "VP8/48000"},
        {"sendonly", "a=sendrecv", "a=sendonly"},
        {"recvonly", "a=sendrecv", "a=recvonly"},
        {"inactive video", "a=sendrecv", "a=inactive"},
        {"ambiguous direction", "a=sendrecv", "a=sendrecv\r\na=recvonly"},
        {"duplicate MID", "a=mid:1", "a=mid:0"},
        {"ambiguous MID", "a=mid:1", "a=mid:1\r\na=mid:other"},
        {"missing MID", "a=mid:1\r\n", ""},
        {"rejected video", "m=video 9", "m=video 0"}
      ] do
    @old old
    @new new
    test "rejects #{label} and releases the exact server connection" do
      {_browser, offer} = call_offer()
      server = start_server()
      monitor = Process.monitor(server.peer_connection)
      invalid = Map.update!(offer, "sdp", &String.replace(&1, @old, @new))

      assert {:error, :negotiation_failed, closed} =
               CallPeerConnection.accept_offer(
                 server,
                 "invalid",
                 invalid,
                 System.monotonic_time(:millisecond) + 10_000
               )

      assert_receive {:DOWN, ^monitor, :process, _, :normal}

      assert {:error, :invalid_session, ^closed} =
               CallPeerConnection.add_ice_candidate(
                 closed,
                 "invalid",
                 call_candidate("invalid"),
                 System.monotonic_time(:millisecond) + 10_000
               )

      refute server.peer_connection in PeerConnection.get_all_running()
      assert :ok = CallPeerConnection.stop(server)
    end
  end

  test "rejects an ambiguous VP8 payload identity before provisioning an answer" do
    {_browser, offer} = call_offer()
    {:ok, sdp} = ExSDP.parse(offer["sdp"])
    [audio, video] = sdp.media
    vp8 = Enum.find(ExSDP.get_attributes(video, :rtpmap), &(&1.encoding == "VP8"))
    video = %{video | attributes: video.attributes ++ [vp8]}
    invalid = Map.put(offer, "sdp", to_string(%{sdp | media: [audio, video]}))
    server = start_server()
    monitor = Process.monitor(server.peer_connection)
    assert {:error, :negotiation_failed} = CallPeerConnection.accept_offer(server, invalid)
    assert_receive {:DOWN, ^monitor, :process, _, :normal}
  end

  test "repeated repair associations on one fmtp line cannot be hidden by the SDP parser" do
    {_browser, offer} = call_offer()

    for ending <- ["\r", "\r\n", "\n"],
        repair_pt <- ["97", "+97"],
        parameters <- [
          "apt=127;apt=96",
          "apt=96;apt=127",
          "apt=96;apt=96",
          "apt=127;\u00A0apt=96"
        ] do
      invalid =
        Map.update!(offer, "sdp", fn sdp ->
          sdp
          |> String.replace("apt=96", parameters)
          |> String.replace("a=fmtp:97 ", "a=fmtp:#{repair_pt} ")
          |> String.replace("\r\n", ending)
        end)

      server = start_server()
      monitor = Process.monitor(server.peer_connection)
      assert {:error, :negotiation_failed} = CallPeerConnection.accept_offer(server, invalid)
      assert_receive {:DOWN, ^monitor, :process, _, :normal}
    end
  end

  test "malformed codec, repair and extension envelopes fail locally while Voice still negotiates" do
    alias ExSDP.Attribute.{Extmap, FMTP, RTPMapping}
    {_browser, offer} = call_offer()
    {:ok, sdp} = ExSDP.parse(offer["sdp"])
    [audio, video] = sdp.media
    vp8 = Enum.find(ExSDP.get_attributes(video, :rtpmap), &(&1.encoding == "VP8"))
    rtx = Enum.find(ExSDP.get_attributes(video, :fmtp), &(&1.apt == vp8.payload_type))
    mid = Enum.find(ExSDP.get_attributes(video, :extmap), &String.ends_with?(&1.uri, ":mid"))

    update = fn original, replacement ->
      %{
        video
        | attributes: Enum.map(video.attributes, &if(&1 == original, do: replacement, else: &1))
      }
    end

    invalid_video = [
      %{video | fmt: video.fmt ++ [vp8.payload_type]},
      %{video | fmt: List.delete(video.fmt, vp8.payload_type)},
      %{video | fmt: video.fmt ++ [127]},
      %{video | attributes: video.attributes ++ [rtx]},
      update.(rtx, %{rtx | apt: nil}),
      update.(rtx, %{rtx | apt: 127}),
      update.(rtx, %{rtx | apt: rtx.pt}),
      %{video | attributes: video.attributes ++ [%FMTP{pt: 127, apt: vp8.payload_type}]},
      %{video | attributes: Enum.reject(video.attributes, &(&1 == rtx))},
      %{
        video
        | attributes: Enum.reject(video.attributes, &match?(%RTPMapping{encoding: "rtx"}, &1))
      },
      %{
        video
        | attributes:
            Enum.map(video.attributes, fn
              %RTPMapping{encoding: "rtx"} = codec -> %{codec | clock_rate: 48_000}
              attr -> attr
            end)
      },
      %{
        video
        | fmt: video.fmt ++ [126],
          attributes: video.attributes ++ [%{vp8 | payload_type: 126}]
      },
      %{
        video
        | fmt: video.fmt ++ [126],
          attributes: video.attributes ++ [%{vp8 | payload_type: 126, clock_rate: 48_000}]
      },
      %{video | attributes: Enum.reject(video.attributes, &match?(%{feedback_type: :nack}, &1))},
      %{video | attributes: video.attributes ++ [mid]},
      %{video | attributes: video.attributes ++ [%{mid | id: 254}]},
      %{video | attributes: Enum.reject(video.attributes, &(&1 == mid))},
      update.(mid, %{mid | id: 0}),
      update.(mid, %{mid | direction: :sendonly}),
      %{video | attributes: video.attributes ++ [%Extmap{id: mid.id, uri: "urn:foreign"}]}
    ]

    for video <- invalid_video do
      server = start_server()
      monitor = Process.monitor(server.peer_connection)
      invalid = Map.put(offer, "sdp", to_string(%{sdp | media: [audio, video]}))
      assert {:error, :negotiation_failed} = CallPeerConnection.accept_offer(server, invalid)
      assert_receive {:DOWN, ^monitor, :process, _, :normal}
    end

    # A different mapping in the other bundled position is also ambiguous.
    audio_ext =
      Enum.find(ExSDP.get_attributes(audio, :extmap), &String.contains?(&1.uri, "transport-wide"))

    audio = %{
      audio
      | attributes:
          List.replace_at(
            audio.attributes,
            Enum.find_index(audio.attributes, &(&1 == audio_ext)),
            %{audio_ext | uri: "urn:foreign"}
          )
    }

    server = start_server()
    monitor = Process.monitor(server.peer_connection)
    invalid = Map.put(offer, "sdp", to_string(%{sdp | media: [audio, video]}))
    assert {:error, :negotiation_failed} = CallPeerConnection.accept_offer(server, invalid)
    assert_receive {:DOWN, ^monitor, :process, _, :normal}

    assert {:ok, _, _} = CallPeerConnection.accept_offer(start_server(), offer)

    voice = %DiscordClone.Voice.PeerConnection{
      peer_connection:
        start_supervised!(%{
          id: make_ref(),
          restart: :temporary,
          start:
            {DiscordClone.Media.Connection, :start_link,
             [ServerICEProjection.disabled(), [controlling_process: self()]]}
        })
    }

    assert {:ok, _, _} =
             DiscordClone.Voice.PeerConnection.accept_offer(
               voice,
               DiscordCloneWeb.VoiceSignalingHelpers.browser_offer()
             )
  end

  test "the sanitized stable Chrome media envelope negotiates its real codec and repair identities" do
    # Observed browser media attributes, reconstructed on synthetic ExWebRTC
    # transport credentials. Only the browser smoke proves current delivery.
    fixture =
      File.read!("test/fixtures/chrome_media_envelope.json")
      |> Jason.decode!()

    {_browser, transport} = call_offer()
    {:ok, sdp} = ExSDP.parse(transport["sdp"])

    {:ok, observed} =
      ExSDP.parse(
        Enum.join(
          [
            "v=0",
            "o=- 1 1 IN IP4 0.0.0.0",
            "s=-",
            "t=0 0"
            | List.flatten(fixture["envelope"]["offer"])
          ],
          "\r\n"
        ) <> "\r\n"
      )

    media =
      Enum.zip_with(sdp.media, observed.media, fn transport, observed ->
        attributes =
          Enum.reject(transport.attributes, fn attribute ->
            attribute in [:sendrecv] or match?({:mid, _}, attribute) or
              match?(%ExSDP.Attribute.Extmap{}, attribute) or
              match?(%ExSDP.Attribute.RTPMapping{}, attribute) or
              match?(%ExSDP.Attribute.FMTP{}, attribute) or
              match?(%ExSDP.Attribute.RTCPFeedback{}, attribute)
          end)

        %{transport | fmt: observed.fmt, attributes: attributes ++ observed.attributes}
      end)

    offer = Map.put(transport, "sdp", to_string(%{sdp | media: media}))
    assert {:ok, answer, server} = CallPeerConnection.accept_offer(start_server(), offer)
    {:ok, answer_sdp} = ExSDP.parse(answer["sdp"])
    [audio, video] = PeerConnection.get_transceivers(server.peer_connection)
    assert audio.sender.codec.payload_type == 111
    assert video.sender.codec.payload_type == 96
    assert [repair] = Enum.filter(video.codecs, &(&1.mime_type == "video/rtx"))
    assert repair.payload_type == 97
    assert repair.sdp_fmtp_line.apt == 96
    assert Enum.all?(answer_sdp.media, &(ExWebRTC.SDPUtils.get_media_direction(&1) == :sendrecv))
    assert Enum.all?([audio, video], &(&1.sender.track != nil))
  end

  test "rejects missing, extra and Voice positions without affecting another Call peer" do
    survivor = start_server()

    for positions <- [
          [{:audio, :sendrecv}],
          [{:audio, :sendrecv}, {:video, :sendrecv}, {:audio, :recvonly}],
          [{:video, :sendrecv}, {:audio, :sendrecv}]
        ] do
      {_browser, offer} = call_offer(positions)
      server = start_server()
      monitor = Process.monitor(server.peer_connection)
      assert {:error, :negotiation_failed} = CallPeerConnection.accept_offer(server, offer)
      assert_receive {:DOWN, ^monitor, :process, _, :normal}
    end

    offer = DiscordCloneWeb.VoiceSignalingHelpers.browser_offer()
    server = start_server()
    monitor = Process.monitor(server.peer_connection)
    assert {:error, :negotiation_failed} = CallPeerConnection.accept_offer(server, offer)
    assert_receive {:DOWN, ^monitor, :process, _, :normal}
    {_browser, call_offer} = call_offer()
    assert {:ok, _answer, _survivor} = CallPeerConnection.accept_offer(survivor, call_offer)
  end

  test "a failure after layout validation and an expired command release allocations" do
    {_browser, offer} = call_offer()
    server = start_server()
    monitor = Process.monitor(server.peer_connection)
    # Keep the media layout valid but make ExWebRTC reject the remote description.
    invalid = Map.update!(offer, "sdp", &String.replace(&1, "a=rtcp-mux\r\n", ""))
    assert {:error, :negotiation_failed} = CallPeerConnection.accept_offer(server, invalid)
    assert_receive {:DOWN, ^monitor, :process, _, :normal}
    server = start_server()
    monitor = Process.monitor(server.peer_connection)
    assert {:error, :negotiation_failed} = CallPeerConnection.accept_offer(server, offer, 0)
    assert_receive {:DOWN, ^monitor, :process, _, :normal}
  end

  test "rejection releases already allocated UDP resources and preserves Voice compatibility errors" do
    {_browser, offer} = call_offer()
    server = start_server()
    server_pid = server.peer_connection
    monitor = Process.monitor(server_pid)
    assert {:ok, _answer, server} = CallPeerConnection.accept_offer(server, offer)
    assert_receive {:ex_webrtc, ^server_pid, {:ice_candidate, candidate}}, 2_000

    assert {:ok, allocation} =
             candidate.candidate
             |> String.trim_leading("candidate:")
             |> ExICE.Candidate.unmarshal()

    options =
      [active: false, ip: allocation.address] ++
        if(tuple_size(allocation.address) == 8, do: [:inet6], else: [:inet])

    assert {:error, :eaddrinuse} = :gen_udp.open(allocation.port, options)

    assert {:error, :negotiation_failed} =
             CallPeerConnection.accept_offer(server, %{"type" => "offer", "sdp" => "invalid"})

    assert_receive {:DOWN, ^monitor, :process, _, :normal}
    assert {:ok, udp} = :gen_udp.open(allocation.port, options)
    :ok = :gen_udp.close(udp)

    voice_pid =
      start_supervised!(%{
        id: make_ref(),
        restart: :temporary,
        start:
          {DiscordClone.Media.Connection, :start_link,
           [ServerICEProjection.disabled(), [controlling_process: self()]]}
      })

    voice = %DiscordClone.Voice.PeerConnection{peer_connection: voice_pid}

    assert {:error, :incompatible_audio_output_slots} =
             DiscordClone.Voice.PeerConnection.accept_offer(voice, offer)

    assert {:ok, _answer, voice} =
             DiscordClone.Voice.PeerConnection.accept_offer(
               voice,
               DiscordCloneWeb.VoiceSignalingHelpers.browser_offer()
             )

    assert map_size(voice.audio_output_slot_track_ids) == 4
  end

  defp call_candidate(negotiation_id) do
    candidate = DiscordCloneWeb.VoiceSignalingHelpers.browser_ice_candidate()

    %{
      negotiation_id: negotiation_id,
      candidate: candidate,
      byte_count: Jason.encode!(candidate) |> byte_size()
    }
  end

  defp start_server do
    pid =
      start_supervised!(%{
        id: make_ref(),
        restart: :temporary,
        start:
          {CallPeerConnection, :start_link,
           [ServerICEProjection.disabled(), [controlling_process: self()]]}
      })

    %CallPeerConnection{peer_connection: pid}
  end

  defp call_offer(positions \\ [{:audio, :sendrecv}, {:video, :sendrecv}]) do
    browser =
      start_supervised!(%{
        id: make_ref(),
        restart: :temporary,
        start: {PeerConnection, :start_link, [[ice_servers: [], controlling_process: self()]]}
      })

    for {kind, direction} <- positions do
      source =
        if kind == :audio and direction in [:sendonly, :sendrecv],
          do: MediaStreamTrack.new(:audio),
          else: kind

      assert {:ok, _} = PeerConnection.add_transceiver(browser, source, direction: direction)
    end

    assert {:ok, offer} = PeerConnection.create_offer(browser)
    assert :ok = PeerConnection.set_local_description(browser, offer)
    assert_receive {:ex_webrtc, ^browser, {:ice_gathering_state_change, :complete}}, 2_000
    {browser, browser |> PeerConnection.get_local_description() |> SessionDescription.to_json()}
  end

  defp apply_candidates(source, destination) do
    receive do
      {:ex_webrtc, ^source, {:ice_candidate, candidate}} ->
        assert :ok = PeerConnection.add_ice_candidate(destination, candidate)
        apply_candidates(source, destination)

      {:ex_webrtc, ^source, {:ice_gathering_state_change, :complete}} ->
        :ok
    after
      2_000 -> flunk("Call ICE gathering did not complete")
    end
  end
end
