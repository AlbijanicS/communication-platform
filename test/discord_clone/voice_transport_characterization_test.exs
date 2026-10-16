defmodule DiscordClone.VoiceTransportCharacterizationTest do
  use DiscordClone.DataCase, async: false

  import DiscordClone.AccountsFixtures

  alias DiscordClone.Voice
  alias DiscordClone.{Repo, Workspaces}
  alias DiscordClone.Workspaces.WorkspaceMembership
  alias ExWebRTC.{ICECandidate, MediaStreamTrack, PeerConnection, SessionDescription}

  setup do
    on_exit(fn ->
      for {room_id, _pid} <- Voice.running_room_servers() do
        :ok = Voice.end_channel_sessions(room_id)
        :ok = Voice.expire_idle_room(room_id)
      end
    end)

    :ok
  end

  test "five connected Voice peers keep four stable receiving slots across source replacement" do
    room_id = Ecto.UUID.generate()
    sessions = Enum.map(1..5, fn _ -> connect_voice_peer(room_id) end)
    assert {:ok, %{occupancy: 5, capacity: 5}} = Voice.room_occupancy(room_id)

    assert {:error, %{reason: :room_full, occupancy: 5, capacity: 5}} =
             Voice.join(room_id, Ecto.UUID.generate(), "sixth-peer", self())

    assert {:ok, %{members: members}} = Voice.voice_channel_roster(room_id)
    assert Enum.map(members, & &1.user_id) == Enum.map(sessions, & &1.scope.user.id)

    initial_deliveries = deliver_matrix(sessions, 8_003, 2_920)

    for {_pair, {_track_id, packet}} <- initial_deliveries do
      assert packet.sequence_number == 8_003
      assert packet.timestamp == 2_920
    end

    for destination <- sessions do
      track_ids =
        for {{_source_id, destination_id}, {track_id, _packet}} <- initial_deliveries,
            destination_id == destination.session_id,
            do: track_id

      assert MapSet.new(track_ids) == MapSet.new(destination.receiving_tracks)
    end

    [first, second, third, fourth, removed] = sessions
    removed_monitor = Process.monitor(removed.server_peer)
    assert :ok = Voice.leave(room_id, removed.session_id)
    assert_receive {:DOWN, ^removed_monitor, :process, _, _reason}
    replacement = connect_voice_peer(room_id)
    retained = [first, second, third, fourth]

    retained_deliveries = deliver_matrix(retained, 8_004, 3_880)

    for {pair, {track_id, packet}} <- retained_deliveries do
      {initial_track_id, _initial_packet} = Map.fetch!(initial_deliveries, pair)
      assert track_id == initial_track_id
      assert packet.sequence_number == 8_004
      assert packet.timestamp == 3_880
    end

    send_audio(replacement, opus_payload(6), 47_120, 918_273)

    for destination <- retained do
      {track_id, packet} = receive_audio(destination, opus_payload(6))

      {released_track_id, previous_packet} =
        Map.fetch!(initial_deliveries, {removed.session_id, destination.session_id})

      assert track_id == released_track_id
      assert packet.ssrc == previous_packet.ssrc
      assert packet.sequence_number == 8_004
      assert packet.timestamp > previous_packet.timestamp
      refute packet.timestamp == 918_273
    end

    # Retained sources still reach the newly admitted destination.
    for {source, number} <- Enum.with_index(retained, 1) do
      {track_id, packet} = receive_audio(replacement, opus_payload(number))
      assert track_id in replacement.receiving_tracks
      assert packet.sequence_number == 8_004
      assert packet.timestamp == 3_880
      refute source.session_id == replacement.session_id
    end

    # No duplicate, self, or retired-destination packet remains after all 20 routes.
    refute_receive {:ex_webrtc, _, {:rtp, _, _, _}}, 100
  end

  test "Workspace Mute blocks real outbound audio while preserving listening and exact transport" do
    owner = user_scope_fixture()
    member = user_scope_fixture()
    assert {:ok, workspace} = Workspaces.create_workspace(owner, %{name: "Transport moderation"})

    %WorkspaceMembership{}
    |> WorkspaceMembership.changeset(%{
      workspace_id: workspace.id,
      user_id: member.user.id,
      role: "member"
    })
    |> Repo.insert!()

    assert {:ok, channel} =
             Workspaces.create_voice_channel(owner, workspace.id, %{name: "audio"})

    listener = connect_voice_peer(channel.id, owner)
    source = connect_voice_peer(channel.id, member)
    send_audio(source, opus_payload(1), 100, 960)
    {source_slot, _packet} = receive_audio(listener, opus_payload(1))

    assert {:ok, _moderation} = Workspaces.mute_member(owner, workspace.id, member.user.id, %{})

    assert :ok =
             Voice.update_local_voice_state(member, channel.id, source.session_id, %{
               muted: false,
               deafened: false
             })

    blocked_payload = opus_payload(2)
    send_audio(source, blocked_payload, 101, 1_920)
    send_audio(listener, opus_payload(3), 200, 9_600)
    receive_audio(source, opus_payload(3))
    refute_receive {:ex_webrtc, _, {:rtp, _, _, %{payload: ^blocked_payload}}}, 100

    assert {:ok, %{occupancy: 2, capacity: 5}} = Voice.room_occupancy(channel.id)

    assert {:ok, %{members: [_listener, %{muted: true, deafened: false}]}} =
             Voice.voice_channel_roster(channel.id)

    assert {:ok, _moderation} = Workspaces.unmute_member(owner, workspace.id, member.user.id)
    send_audio(source, opus_payload(4), 102, 2_880)
    {restored_slot, packet} = receive_audio(listener, opus_payload(4))
    assert restored_slot == source_slot
    assert packet.sequence_number == 102

    source_monitor = Process.monitor(source.server_peer)

    assert :ok =
             Workspaces.voice_disconnect_member(owner, workspace.id, channel.id, member.user.id)

    assert_receive {:DOWN, ^source_monitor, :process, _, _reason}
    assert {:ok, %{occupancy: 1, capacity: 5}} = Voice.room_occupancy(channel.id)

    replacement = connect_voice_peer(channel.id, member)
    refute replacement.session_id == source.session_id
    assert :ok = Voice.leave(channel.id, source.session_id)
    send_audio(listener, opus_payload(5), 201, 10_560)
    receive_audio(replacement, opus_payload(5))
    refute_receive {:ex_webrtc, _, {:rtp, _, _, _}}, 100
  end

  test "room failure retires its real transports while an unrelated pair continues delivering" do
    failed_room = Ecto.UUID.generate()
    healthy_room = Ecto.UUID.generate()
    failed_first = connect_voice_peer(failed_room)
    failed_second = connect_voice_peer(failed_room)
    healthy_first = connect_voice_peer(healthy_room)
    healthy_second = connect_voice_peer(healthy_room)

    send_audio(failed_first, opus_payload(1), 10, 960)
    receive_audio(failed_second, opus_payload(1))
    send_audio(healthy_first, opus_payload(2), 20, 1_920)
    receive_audio(healthy_second, opus_payload(2))

    monitors = Enum.map([failed_first, failed_second], &Process.monitor(&1.server_peer))
    assert :ok = Voice.crash_forwarder(failed_room)

    for monitor <- monitors do
      assert_receive {:DOWN, ^monitor, :process, _, _reason}
    end

    assert {:ok, %{members: []}} = Voice.voice_channel_roster(failed_room)

    send_audio(healthy_first, opus_payload(3), 21, 2_880)
    receive_audio(healthy_second, opus_payload(3))
    send_audio(healthy_second, opus_payload(4), 30, 3_840)
    receive_audio(healthy_first, opus_payload(4))
    assert {:ok, %{occupancy: 2, capacity: 5}} = Voice.room_occupancy(healthy_room)

    replacement = connect_voice_peer(failed_room, failed_first.scope)
    replacement_listener = connect_voice_peer(failed_room, failed_second.scope)
    assert :ok = Voice.leave(failed_room, failed_first.session_id)
    assert :ok = Voice.leave(failed_room, failed_second.session_id)
    send_audio(replacement, opus_payload(5), 40, 4_800)
    receive_audio(replacement_listener, opus_payload(5))
    refute_receive {:ex_webrtc, _, {:rtp, _, _, _}}, 100
  end

  defp connect_voice_peer(room_id, scope \\ user_scope_fixture()) do
    peer =
      start_supervised!(%{
        id: make_ref(),
        restart: :temporary,
        start: {PeerConnection, :start_link, [[ice_servers: [], controlling_process: self()]]}
      })

    microphone = MediaStreamTrack.new(:audio)

    assert {:ok, _transceiver} =
             PeerConnection.add_transceiver(peer, microphone, direction: :sendonly)

    for _slot <- 1..4 do
      assert {:ok, _transceiver} =
               PeerConnection.add_transceiver(peer, :audio, direction: :recvonly)
    end

    assert {:ok, offer} = PeerConnection.create_offer(peer)
    assert :ok = PeerConnection.set_local_description(peer, offer)
    assert_receive {:ex_webrtc, ^peer, {:ice_gathering_state_change, :complete}}, 2_000
    offer = peer |> PeerConnection.get_local_description() |> SessionDescription.to_json()

    signaling_id = Ecto.UUID.generate()
    negotiation_id = Ecto.UUID.generate()
    peers_before = MapSet.new(PeerConnection.get_all_running())

    assert {:ok, %{voice_session_id: session_id}} =
             Voice.join(room_id, scope.user.id, signaling_id, self())

    [server_peer] =
      PeerConnection.get_all_running()
      |> MapSet.new()
      |> MapSet.difference(peers_before)
      |> MapSet.to_list()

    assert {:ok, answer} =
             Voice.accept_offer(scope, room_id, session_id, negotiation_id, offer)

    assert :ok =
             PeerConnection.set_remote_description(peer, SessionDescription.from_json(answer))

    apply_server_candidates(peer, session_id, negotiation_id)
    assert_receive {:ex_webrtc, ^peer, {:connection_state_change, :connected}}, 5_000

    receiving_tracks =
      peer
      |> PeerConnection.get_transceivers()
      |> Enum.filter(&(&1.current_direction == :recvonly))
      |> Enum.map(& &1.receiver.track.id)

    assert length(receiving_tracks) == 4

    %{
      peer: peer,
      server_peer: server_peer,
      microphone: microphone,
      receiving_tracks: receiving_tracks,
      scope: scope,
      room_id: room_id,
      session_id: session_id
    }
  end

  defp apply_server_candidates(peer, session_id, negotiation_id) do
    receive do
      {:voice_session_event, ^session_id, {:ice_candidate, ^negotiation_id, candidate}} ->
        assert :ok = PeerConnection.add_ice_candidate(peer, ICECandidate.from_json(candidate))
        apply_server_candidates(peer, session_id, negotiation_id)

      {:voice_session_event, ^session_id, {:end_of_candidates, ^negotiation_id}} ->
        :ok
    after
      2_000 -> flunk("Voice server ICE gathering did not complete")
    end
  end

  defp send_audio(session, payload, sequence_number, timestamp) do
    packet = ExRTP.Packet.new(payload, sequence_number: sequence_number, timestamp: timestamp)
    assert :ok = PeerConnection.send_rtp(session.peer, session.microphone.id, packet)
  end

  defp receive_audio(session, payload) do
    peer = session.peer

    assert_receive {:ex_webrtc, ^peer, {:rtp, track_id, nil, %{payload: ^payload} = packet}},
                   2_000

    assert track_id in session.receiving_tracks
    {track_id, packet}
  end

  defp deliver_matrix(sessions, sequence_number, timestamp) do
    sessions
    |> Enum.with_index(1)
    |> Enum.reduce(%{}, fn {source, number}, deliveries ->
      payload = opus_payload(number)
      send_audio(source, payload, sequence_number, timestamp)

      Enum.reduce(sessions, deliveries, fn destination, deliveries ->
        if source.session_id == destination.session_id do
          deliveries
        else
          Map.put(
            deliveries,
            {source.session_id, destination.session_id},
            receive_audio(destination, payload)
          )
        end
      end)
    end)
  end

  # Opus code-3 CBR packets containing 1–6 copies of a 20 ms silence frame.
  defp opus_payload(frame_count) do
    <<0xFB, frame_count>> <> :binary.copy(<<0xFF, 0xFE>>, frame_count)
  end
end
