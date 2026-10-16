defmodule DiscordClone.CallsRealRuntimeTest do
  use DiscordClone.DataCase, async: false

  import DiscordClone.CallsFixtures
  import DiscordClone.AccountsFixtures
  import Phoenix.ChannelTest

  alias DiscordClone.Calls
  alias DiscordClone.Media.{AdmissionCoordinator, DirectCallSession, DirectCallTarget, Target}
  alias DiscordClone.MediaFixtures
  alias DiscordClone.Voice
  alias ExWebRTC.{ICECandidate, MediaStreamTrack, PeerConnection, SessionDescription}

  @endpoint DiscordCloneWeb.Endpoint

  setup context do
    start_supervised!(DiscordClone.Calls.Supervisor)
    DiscordClone.Calls.CallCoordinator.begin_recovery()
    await_recovery_finished()
    MediaFixtures.setup_coordinator_pair_state!()
    previous_runtime = Application.fetch_env(:discord_clone, :accepted_call_runtime)

    Application.put_env(
      :discord_clone,
      :accepted_call_runtime,
      DiscordClone.Calls.PairAdmissionRuntime
    )

    previous = Application.fetch_env(:discord_clone, :direct_call_transport)
    Application.put_env(:discord_clone, :direct_call_transport, :real)
    previous_camera = Application.fetch_env(:discord_clone, :direct_call_camera_lifecycle_enabled)

    Application.put_env(
      :discord_clone,
      :direct_call_camera_lifecycle_enabled,
      context[:controlled_camera] == true
    )

    on_exit(fn ->
      Application.delete_env(:discord_clone, :call_target_startup_control)
      MediaFixtures.reset_coordinator_pair_state!()

      case previous_runtime do
        {:ok, value} -> Application.put_env(:discord_clone, :accepted_call_runtime, value)
        :error -> Application.delete_env(:discord_clone, :accepted_call_runtime)
      end

      case previous do
        {:ok, value} -> Application.put_env(:discord_clone, :direct_call_transport, value)
        :error -> Application.delete_env(:discord_clone, :direct_call_transport)
      end

      case previous_camera do
        {:ok, value} ->
          Application.put_env(:discord_clone, :direct_call_camera_lifecycle_enabled, value)

        :error ->
          Application.delete_env(:discord_clone, :direct_call_camera_lifecycle_enabled)
      end

      for {channel, _} <- Voice.running_room_servers() do
        :ok = Voice.end_channel_sessions(channel)
        :ok = Voice.expire_idle_room(channel)
      end
    end)

    :ok
  end

  test "controlled camera capability permits real video intent and answer with only the existing pair" do
    previous = Application.fetch_env(:discord_clone, :direct_call_camera_lifecycle_enabled)
    Application.put_env(:discord_clone, :direct_call_camera_lifecycle_enabled, true)

    on_exit(fn ->
      case previous do
        {:ok, value} ->
          Application.put_env(:discord_clone, :direct_call_camera_lifecycle_enabled, value)

        :error ->
          Application.delete_env(:discord_clone, :direct_call_camera_lifecycle_enabled)
      end
    end)

    {caller, recipient, conversation, _} = direct_conversation_fixture("controlled_video")

    assert Calls.browser_media_capabilities(caller) == %{
             device_adapter: :real,
             video_available?: true
           }

    assert {:ok, %{call: call}} = Calls.start_call(caller, conversation.id, :video)
    assert call.media_intent == :video
    assert call.state == :ringing
    assert AdmissionCoordinator.effective_occupancy() == 0
    assert AdmissionCoordinator.call_target_snapshot(call.call_id) == nil

    assert {:ok, %{state: :connecting, media_intent: :video, answer_mode: :video}} =
             Calls.accept_call(recipient, call.call_id, :video)

    assert length(await_sessions(call.call_id)) == 2
    assert AdmissionCoordinator.effective_occupancy() == 2
    assert {:ok, %{state: :terminal}} = Calls.leave_call(recipient, call.call_id)
  end

  test "real video commands preserve prior Voice and reserve nothing" do
    {caller, recipient, conversation, _} = direct_conversation_fixture("real_video_unavailable")
    assert {:error, :temporarily_unavailable} = Calls.start_call(caller, conversation.id, :video)
    assert {:ok, nil} = Calls.current_call(caller)
    assert {:ok, nil} = Calls.current_call(recipient)
    assert {:ok, %{call: call}} = Calls.start_call(caller, conversation.id, :audio)

    pair = %{
      caller: caller,
      recipient: recipient,
      call_id: call.call_id,
      conversation_id: conversation.id
    }

    channel = Ecto.UUID.generate()

    assert {:ok, %{voice_session_id: voice_id}} =
             Voice.join(channel, pair.caller.user.id, "video-guard", self())

    assert {:error, :temporarily_unavailable} =
             Calls.start_call(pair.caller, pair.conversation_id, :video)

    assert {:error, :stale} = Calls.accept_call(pair.recipient, pair.call_id, :video)
    assert {:ok, %{state: :ringing} = before} = Calls.get_call(pair.caller, pair.call_id)
    assert AdmissionCoordinator.reservation_count() == 0
    assert AdmissionCoordinator.call_target_snapshot(pair.call_id) == nil
    assert {:ok, %{members: [%{user_id: user_id}]}} = Voice.voice_channel_roster(channel)
    assert user_id == pair.caller.user.id
    assert {:ok, %{terminal_outcome: :cancelled}} = Calls.cancel_call(pair.caller, pair.call_id)
    assert before.media_intent == :audio
    assert :ok = Voice.leave(channel, voice_id)
  end

  test "recovered video rejects video answer but explicitly accepts audio without changing intent" do
    Application.put_env(:discord_clone, :direct_call_transport, :fake)
    {caller, recipient, conversation, _} = direct_conversation_fixture("recovered_video")
    assert {:ok, %{call: call}} = Calls.start_call(caller, conversation.id, :video)
    Application.put_env(:discord_clone, :direct_call_transport, :real)
    pair = %{caller: caller, recipient: recipient, call_id: call.call_id}

    assert {:ok, before} = Calls.get_call(pair.recipient, pair.call_id)

    assert {:error, :temporarily_unavailable} =
             Calls.accept_call(pair.recipient, pair.call_id, :video)

    assert {:ok, after_rejection} = Calls.get_call(pair.recipient, pair.call_id)
    assert after_rejection.state == :ringing
    assert after_rejection.ringing_deadline_at == before.ringing_deadline_at
    assert AdmissionCoordinator.reservation_count() == 0
    assert AdmissionCoordinator.call_target_snapshot(pair.call_id) == nil

    assert {:ok, %{state: :connecting, media_intent: :video, answer_mode: :audio}} =
             Calls.accept_call(pair.recipient, pair.call_id, :audio)

    assert length(await_sessions(pair.call_id)) == 2
    assert {:ok, %{state: :terminal}} = Calls.leave_call(pair.recipient, pair.call_id)
  end

  test "ringing allocates nothing; admission owns two real peers and leave releases both" do
    pair = start_pair("real_pair")
    assert AdmissionCoordinator.call_target_snapshot(pair.call_id) == nil
    assert AdmissionCoordinator.reservation_count() == 0

    assert {:ok, %{state: :connecting}} = Calls.accept_call(pair.recipient, pair.call_id, :audio)
    sessions = await_sessions(pair.call_id)
    assert length(sessions) == 2
    resources = Enum.flat_map(sessions, &DirectCallSession.resources/1)
    peers = Enum.filter(resources, &(Registry.lookup(ExWebRTC.Registry, &1) != []))
    assert length(peers) == 2
    monitors = Enum.map(resources, &{&1, Process.monitor(&1)})
    assert {:ok, %{state: :connecting}} = Calls.get_call(pair.caller, pair.call_id)
    assert AdmissionCoordinator.effective_occupancy() == 2

    started = System.monotonic_time(:millisecond)
    assert {:ok, %{state: :terminal}} = Calls.leave_call(pair.caller, pair.call_id)
    assert_retired(monitors, started)
    assert AdmissionCoordinator.effective_occupancy() == 0
    assert AdmissionCoordinator.current_identity(pair.recipient.user.id) == nil
    assert :ok = AdmissionCoordinator.cleanup_active_pair_for_call(pair.call_id)
  end

  @tag :controlled_camera
  test "CallServer directly observes the published target and its loss retires both sides with camera present" do
    pair = start_pair("direct_observer", :video)
    assert {:ok, _} = Calls.accept_call(pair.recipient, pair.call_id, :video)
    sessions = await_sessions(pair.call_id)
    endpoints = Enum.map(sessions, &connect_call_peer/1)
    Enum.each(endpoints, &attach_call_camera(&1, pair))
    flush_readiness(pair)
    assert {:ok, %{state: :active}} = Calls.get_call(pair.caller, pair.call_id)
    assert {:ok, target} = DirectCallTarget.start(pair.call_id)
    [{server, _}] = Registry.lookup(DiscordClone.Calls.CallRegistry, pair.call_id)
    assert :ok = DiscordClone.Calls.CallServer.await_ready(pair.call_id)
    assert {:monitors, monitors} = Process.info(server, :monitors)
    assert {:process, target} in monitors

    resources = monitor_resources(sessions)
    target_monitor = Process.monitor(target)
    started = System.monotonic_time(:millisecond)
    Process.exit(target, :kill)
    assert_receive {:DOWN, ^target_monitor, :process, ^target, :killed}
    assert_retired(resources, started)
    assert_receive {:call_failed, %{call_id: call_id}}, 2_000
    assert call_id == pair.call_id
    assert_receive {:call_failed, %{call_id: ^call_id}}, 2_000
    refute_received {:call_failed, %{call_id: ^call_id}}
    assert {:ok, %{terminal_outcome: :failed}} = Calls.get_call(pair.caller, call_id)
    assert AdmissionCoordinator.effective_occupancy() == 0
    assert_no_call_history(pair)
  end

  test "already-dead publication ends both sides without admission notification delivery" do
    pair = start_pair("dead_publication")
    [{server, _}] = Registry.lookup(DiscordClone.Calls.CallRegistry, pair.call_id)
    parent = self()
    call_id = pair.call_id

    # Hold only the runtime publication delivery. Removing its Registry route
    # prevents admission's separate observer from notifying this CallServer;
    # the already-enqueued publication still has its exact recipient.
    :ok =
      :sys.install(server, {
        fn
          :armed, {:in, {:call_media_runtime, ^call_id, _generation, target}}, _ ->
            Registry.unregister(DiscordClone.Calls.CallRegistry, call_id)
            send(parent, {:held_publication, target})
            await_test_release(parent, :release_publication)
            :done

          phase, _event, _ ->
            phase
        end,
        :armed
      })

    assert {:ok, _} = Calls.accept_call(pair.recipient, call_id, :audio)
    sessions = await_sessions(call_id)
    resources = monitor_resources(sessions)
    assert_receive {:held_publication, target}
    target_monitor = Process.monitor(target)
    started = System.monotonic_time(:millisecond)

    try do
      Process.exit(target, :kill)
      assert_receive {:DOWN, ^target_monitor, :process, ^target, :killed}
      assert %{status: :failed} = AdmissionCoordinator.call_target_snapshot(call_id)
      refute_received {:call_failed, %{call_id: ^call_id}}
      send(server, :release_publication)
      assert_receive {:call_failed, %{call_id: ^call_id}}, 2_000
      assert_receive {:call_failed, %{call_id: ^call_id}}, 2_000
      refute_received {:call_failed, %{call_id: ^call_id}}
      assert_retired(resources, started)
      assert {:ok, %{terminal_outcome: :failed}} = Calls.get_call(pair.caller, call_id)
      assert AdmissionCoordinator.effective_occupancy() == 0
      assert_no_call_history(pair)
    after
      send(server, :release_publication)
    end
  end

  for phase <- [:connecting, :active] do
    @observer_phase phase
    @tag :controlled_camera
    test "#{phase} target DOWN races admission, owner loss and leave with one terminal outcome with camera present" do
      pair = start_pair("obs_#{@observer_phase}", :video)
      connection_id = Ecto.UUID.generate()
      tasks = start_supervised!(Task.Supervisor)
      parent = self()
      release = make_ref()

      owner =
        Task.Supervisor.async_nolink(tasks, fn ->
          :ok =
            Calls.register_connection(pair.call_id, pair.caller.user.id, :caller, connection_id)

          send(parent, {:observer_owner_ready, self()})
          await_test_release(parent, release)
          Calls.unregister_connection(pair.call_id, connection_id)
        end)

      assert_receive {:observer_owner_ready, pid} when pid == owner.pid
      assert {:ok, _} = Calls.accept_call(pair.recipient, pair.call_id, :video)
      sessions = await_sessions(pair.call_id)

      if @observer_phase == :active do
        Enum.each(sessions, &attach_call_camera(connect_call_peer(&1), pair))
        flush_readiness(pair)
      else
        attach_call_camera(connect_call_peer(hd(sessions)), pair)
        flush_readiness(pair)
      end

      assert {:ok, %{state: phase}} = Calls.get_call(pair.caller, pair.call_id)
      assert phase == @observer_phase
      assert {:ok, target} = DirectCallTarget.start(pair.call_id)
      resources = monitor_resources(sessions)

      commands = [
        fn -> Process.exit(target, :kill) end,
        fn -> Calls.leave_call(pair.recipient, pair.call_id) end
      ]

      workers =
        Enum.map(commands, fn command ->
          Task.Supervisor.async_nolink(tasks, fn ->
            send(parent, {:observer_race_ready, self()})
            await_test_release(parent, release)
            command.()
          end)
        end)

      for worker <- workers,
          do: assert_receive({:observer_race_ready, pid} when pid == worker.pid)

      started = System.monotonic_time(:millisecond)
      for worker <- workers, do: send(worker.pid, release)
      send(owner.pid, release)
      [true, {:ok, reply}] = Enum.map(workers, &Task.await(&1, 5_000))
      assert :ok = Task.await(owner, 5_000)
      assert reply.state == :terminal
      assert_retired(resources, started)
      call_id = pair.call_id

      assert_receive {event, %{call_id: ^call_id, state: :terminal, terminal_outcome: outcome}},
                     2_000

      assert {event, outcome} in [
               {:call_failed, :failed},
               {:call_completed, :ended},
               {:call_cancelled, :cancelled}
             ]

      assert_receive {^event, %{call_id: ^call_id, terminal_outcome: ^outcome}}, 2_000
      refute_received {:call_failed, %{call_id: ^call_id}}
      refute_received {:call_completed, %{call_id: ^call_id}}
      refute_received {:call_cancelled, %{call_id: ^call_id}}
      assert {:ok, %{terminal_outcome: ^outcome}} = Calls.get_call(pair.caller, call_id)
      assert AdmissionCoordinator.effective_occupancy() == 0
      assert AdmissionCoordinator.current_identity(pair.caller.user.id) == nil
      assert AdmissionCoordinator.current_identity(pair.recipient.user.id) == nil
      assert :ok = AdmissionCoordinator.cleanup_active_pair_for_call(call_id)
      assert_no_call_history(pair)
    end
  end

  test "each admitted Session serializes validated Call negotiation without Voice slots" do
    pair = start_pair("real_negotiation")
    assert {:ok, _} = Calls.accept_call(pair.recipient, pair.call_id, :audio)
    [first, second] = await_sessions(pair.call_id)

    browser =
      start_supervised!(%{
        id: :browser,
        start: {PeerConnection, :start_link, [[controlling_process: self()]]}
      })

    assert {:ok, _} = PeerConnection.add_transceiver(browser, MediaStreamTrack.new(:audio))
    assert {:ok, _} = PeerConnection.add_transceiver(browser, :video)
    assert {:ok, offer} = PeerConnection.create_offer(browser)
    payload = %{"negotiation_id" => "one", "description" => SessionDescription.to_json(offer)}
    assert {:ok, %{"type" => "answer"}} = DirectCallSession.accept_offer(first, payload)
    assert {:error, :negotiation_already_active} = DirectCallSession.accept_offer(first, payload)

    assert {:error, "description_too_large"} =
             DirectCallSession.accept_offer(
               second,
               put_in(payload, ["description", "sdp"], String.duplicate("x", 65_537))
             )

    assert {:ok, %{"type" => "answer"}} = DirectCallSession.accept_offer(second, payload)

    for session <- [first, second] do
      [peer] =
        Enum.filter(
          DirectCallSession.resources(session),
          &(Registry.lookup(ExWebRTC.Registry, &1) != [])
        )

      assert [audio, video] = PeerConnection.get_transceivers(peer)
      assert audio.kind == :audio
      assert video.kind == :video
      assert video.sender.track.kind == :video
    end

    assert {:ok, %{state: :terminal}} = Calls.leave_call(pair.caller, pair.call_id)
  end

  test "readiness is withdrawn before the second side connects and recovery activates once" do
    pair = start_pair("real_readiness")
    assert {:ok, _} = Calls.accept_call(pair.recipient, pair.call_id, :audio)
    [first_session, second_session] = await_sessions(pair.call_id)
    first = connect_call_peer(first_session)
    flush_readiness(pair)
    assert {:ok, %{state: :connecting}} = Calls.get_call(pair.caller, pair.call_id)

    report_connection(first, :disconnected)
    second = connect_call_peer(second_session)
    flush_readiness(pair)
    assert {:ok, %{state: :connecting}} = Calls.get_call(pair.caller, pair.call_id)
    refute_receive {:call_active, _}, 0

    report_connection(first, :connected)
    flush_readiness(pair)
    assert {:ok, %{state: :active}} = Calls.get_call(pair.caller, pair.call_id)
    assert_receive {:call_active, %{state: :active}}
    assert_receive {:call_active, %{state: :active}}

    for endpoint <- [first, second], do: report_connection(endpoint, :connected)
    flush_readiness(pair)
    refute_receive {:call_active, _}, 0
    assert {:ok, %{terminal_outcome: :ended}} = Calls.leave_call(pair.recipient, pair.call_id)
    assert_no_call_history(pair)
  end

  test "real Call peers receive only the opposite encoded Opus on their single audio position" do
    pair = start_pair("real_forwarding")
    assert {:ok, _} = Calls.accept_call(pair.recipient, pair.call_id, :audio)
    [first, second] = Enum.map(await_sessions(pair.call_id), &connect_call_peer/1)
    first_payload = <<0xF8, 0xFF, 0xFE>>
    second_payload = <<0xF9, 0xFF, 0xFE, 0xFF, 0xFE>>

    send_audio(first, first_payload, 10, 960)
    send_audio(second, second_payload, 50, 4_800)
    assert_call_audio(second, first_payload)
    assert_call_audio(first, second_payload)
    refute_receive {:ex_webrtc, _, {:rtp, _, _, _}}, 100

    for endpoint <- [first, second] do
      [audio, video] = PeerConnection.get_transceivers(endpoint.server)
      assert audio.sender.track != nil
      assert video.sender.track.kind == :video

      assert %{packets_sent: 0} =
               Map.fetch!(PeerConnection.get_stats(endpoint.server), video.sender.id)
    end

    flush_readiness(pair)
    assert {:ok, %{state: :active}} = Calls.get_call(pair.caller, pair.call_id)
    assert {:ok, %{state: :terminal}} = Calls.leave_call(pair.caller, pair.call_id)
  end

  @tag :controlled_camera
  test "unaccepted camera RTP is discarded while both encoded audio routes keep delivering" do
    pair = start_pair("camera_discard", :video)
    assert {:ok, _} = Calls.accept_call(pair.recipient, pair.call_id, :video)
    [first, second] = Enum.map(await_sessions(pair.call_id), &connect_call_peer/1)

    for endpoint <- [first, second] do
      [_audio, video] = PeerConnection.get_transceivers(endpoint.browser)
      assert video.sender.track == nil
      camera = MediaStreamTrack.new(:video)
      assert :ok = PeerConnection.replace_track(endpoint.browser, video.sender.id, camera)

      assert :ok =
               PeerConnection.send_rtp(
                 endpoint.browser,
                 camera.id,
                 ExRTP.Packet.new(<<0x10, 0x00, 0x01>>,
                   sequence_number: 1,
                   timestamp: 90_000,
                   marker: true
                 )
               )
    end

    send_audio(first, <<0xF8, 0xFF, 0xFE>>, 10, 960)
    send_audio(second, <<0xF9, 0xFF, 0xFE>>, 50, 4_800)
    assert_call_audio(second, <<0xF8, 0xFF, 0xFE>>)
    assert_call_audio(first, <<0xF9, 0xFF, 0xFE>>)
    refute_receive {:ex_webrtc, _, {:rtp, _, _, _}}, 100

    for endpoint <- [first, second] do
      [audio, video] = PeerConnection.get_transceivers(endpoint.server)
      assert audio.sender.track != nil
      assert video.sender.track.kind == :video
      stats = PeerConnection.get_stats(endpoint.server)
      assert Map.fetch!(stats, video.receiver.track.id).packets_received > 0
      assert Map.fetch!(stats, video.sender.id).packets_sent == 0
      assert length(PeerConnection.get_transceivers(endpoint.browser)) == 2
    end

    flush_readiness(pair)

    assert {:ok, %{state: :active, media_intent: :video, answer_mode: :video}} =
             Calls.get_call(pair.caller, pair.call_id)

    assert AdmissionCoordinator.effective_occupancy() == 2
    assert {:ok, %{state: :terminal}} = Calls.leave_call(pair.caller, pair.call_id)
  end

  @tag :controlled_camera
  test "video start with audio answer delivers exact opposite VP8 destination alongside Opus" do
    pair = start_pair("first_remote_video", :video)
    assert {:ok, _} = Calls.accept_call(pair.recipient, pair.call_id, :audio)
    [source, destination] = Enum.map(await_sessions(pair.call_id), &connect_call_peer/1)
    attach_call_camera(source, pair)
    [_audio, receiver] = PeerConnection.get_transceivers(destination.browser)
    [_audio, sender] = PeerConnection.get_transceivers(destination.server)
    browser = destination.browser
    track = receiver.receiver.track.id
    assert_receive {:ex_webrtc, ^browser, {:rtp, ^track, nil, packet}}, 2_000
    assert packet.payload == <<0x10, 0, 1>>
    assert packet.payload_type == hd(receiver.codecs).payload_type

    assert packet.ssrc ==
             Map.fetch!(PeerConnection.get_stats(destination.server), sender.sender.id).ssrc

    refute_receive {:ex_webrtc, _, {:rtp, _, _, _}}, 0
    send_audio(source, <<0xF8, 0xFF, 0xFE>>, 10, 960)
    send_audio(destination, <<0xF9, 0xFF, 0xFE>>, 50, 4_800)
    assert_call_audio(destination, <<0xF8, 0xFF, 0xFE>>)
    assert_call_audio(source, <<0xF9, 0xFF, 0xFE>>)
    assert AdmissionCoordinator.effective_occupancy() == 2
    assert {:ok, %{state: :terminal}} = Calls.leave_call(pair.caller, pair.call_id)
  end

  @tag :controlled_camera
  @tag :ticket13_admission
  test "bounded frame loss recovers through real source PLI while opposite video and Opus survive" do
    pair = start_pair("frame_admission", :video)
    assert {:ok, _} = Calls.accept_call(pair.recipient, pair.call_id, :video)
    [source, destination] = Enum.map(await_sessions(pair.call_id), &connect_call_peer/1)
    camera = attach_call_camera(source, pair)
    assert_call_video(destination, <<0x10, 0, 1>>)
    reverse = attach_call_camera(destination, pair)
    assert_call_video(source, <<0x10, 0, 1>>)
    assert_camera_pli(source, camera)
    assert_camera_pli(destination, reverse)

    for {payload, sequence} <- [{<<0x10, 1, 99>>, 2}, {<<0, 98>>, 4}] do
      assert :ok =
               PeerConnection.send_rtp(
                 source.browser,
                 camera,
                 ExRTP.Packet.new(payload,
                   sequence_number: sequence,
                   timestamp: 93_750,
                   marker: sequence == 4
                 )
               )
    end

    assert_camera_pli(source, camera)
    refute_video(destination, <<0x10, 1, 99>>)
    send_video(source, camera, <<0x10, 1, 97>>, 5, 97_500)
    refute_video(destination, <<0x10, 1, 97>>)
    # A burst exceeding the per-frame packet count stays entirely unforwarded.
    for sequence <- 6..262 do
      assert :ok =
               PeerConnection.send_rtp(
                 source.browser,
                 camera,
                 ExRTP.Packet.new(<<if(sequence == 6, do: 0x10, else: 0), 0, 96>>,
                   sequence_number: sequence,
                   timestamp: 101_250
                 )
               )
    end

    assert_camera_pli(source, camera)

    send_video(destination, reverse, <<0x10, 0, 9>>, 2, 93_750)
    assert_call_video(source, <<0x10, 0, 9>>)
    send_audio(source, <<0xF8, 0xFF, 0xFE>>, 10, 960)
    send_audio(destination, <<0xF9, 0xFF, 0xFE>>, 20, 1_920)
    assert_call_audio(destination, <<0xF8, 0xFF, 0xFE>>)
    assert_call_audio(source, <<0xF9, 0xFF, 0xFE>>)
    send_video(source, camera, <<0x10, 0, 95>>, 263, 105_000)
    assert_call_video(destination, <<0x10, 0, 95>>)
    send_video(source, camera, <<0x10, 1, 94>>, 264, 108_750)
    assert_call_video(destination, <<0x10, 1, 94>>)
    assert {:ok, %{state: :active}} = Calls.get_call(pair.caller, pair.call_id)
    assert AdmissionCoordinator.effective_occupancy() == 2
    assert {:ok, %{state: :terminal}} = Calls.leave_call(pair.caller, pair.call_id)
    assert AdmissionCoordinator.effective_occupancy() == 0
  end

  @tag :controlled_camera
  @tag :ticket14_delivery
  @tag :ticket16_workload
  test "relay connectivity checks permit video while media buffers retain credit and recover" do
    pair = start_pair("relay_credit", :video)
    assert {:ok, _} = Calls.accept_call(pair.recipient, pair.call_id, :video)
    [source, destination] = Enum.map(await_sessions(pair.call_id), &connect_call_peer/1)
    ice = :sys.get_state(destination.server).ice_pid

    # TURN permission failures can retain ICE checks for private candidates on
    # an unused relay even while encrypted video uses the selected host path.
    connectivity_check =
      ExSTUN.Message.new(%ExSTUN.Message.Type{class: :request, method: :binding})
      |> ExSTUN.Message.encode()

    :sys.replace_state(ice, fn state ->
      candidate = state.ice_agent.local_cands |> Map.values() |> hd()

      relay = %ExICE.Priv.Candidate.Relay{
        base: %{candidate.base | id: -1, type: :relay, socket: nil},
        client: nil,
        buffered_packets: [{{192, 168, 1, 2}, 50_000, connectivity_check}]
      }

      %{
        state
        | ice_agent: %{
            state.ice_agent
            | local_cands: Map.put(state.ice_agent.local_cands, -1, relay)
          }
      }
    end)

    try do
      camera = attach_call_camera(source, pair)
      assert_call_video(destination, <<0x10, 0, 1>>)
      await_video_transport_idle(destination.session)

      forwarder = call_forwarder(pair)
      assert {:ok, credentials} = DirectCallSession.media_credentials(destination.session)
      id = credentials.call_session_id
      await_video_route_state(forwarder, id, destination.session, :active)
      send_video(source, camera, <<0x10, 0, 88>>, 2, 97_500)
      assert_call_video(destination, <<0x10, 0, 88>>)
      await_video_route_state(forwarder, id, destination.session, :active)

      await_video_transport_idle(destination.session)

      # Pinned native relay storage, not a fabricated sent-packet counter.
      # The unused relay keeps the selected encrypted host path/audio viable.
      :sys.replace_state(ice, fn state ->
        update_in(state.ice_agent.local_cands[-1].buffered_packets, fn _ ->
          [{{127, 0, 0, 1}, 9, <<1>>}]
        end)
      end)

      send_video(source, camera, <<0x10, 0, 89>>, 3, 101_250)
      assert_call_video(destination, <<0x10, 0, 89>>)
      await_video_route_state(forwarder, id, destination.session, :interrupted)
      send_video(source, camera, <<0x10, 0, 90>>, 4, 105_000)
      refute_video(destination, <<0x10, 0, 90>>)
      reverse = attach_call_camera(destination, pair)
      assert_call_video(source, <<0x10, 0, 1>>)
      send_audio(source, <<0xF8, 0xFF, 0xFE>>, 10, 960)
      send_audio(destination, <<0xF9, 0xFF, 0xFE>>, 20, 1_920)
      assert_call_audio(destination, <<0xF8, 0xFF, 0xFE>>)
      assert_call_audio(source, <<0xF9, 0xFF, 0xFE>>)
      send_video(destination, reverse, <<0x10, 0, 9>>, 2, 93_750)
      assert_call_video(source, <<0x10, 0, 9>>)

      :sys.replace_state(ice, fn state ->
        # Native close retains old bytes but can never send/drain them again.
        update_in(state.ice_agent.local_cands[-1].base.closed?, fn _ -> true end)
      end)

      await_video_route_state(forwarder, id, destination.session, :recovering)
      assert_camera_pli(source, camera)
      send_video(source, camera, <<0x10, 1, 91>>, 5, 108_750)
      refute_video(destination, <<0x10, 1, 91>>)
      send_video(source, camera, <<0x10, 0, 92>>, 6, 112_500)
      assert_call_video(destination, <<0x10, 0, 92>>)
      await_video_route_state(forwarder, id, destination.session, :active)
    after
      :sys.replace_state(
        ice,
        &update_in(&1.ice_agent.local_cands, fn candidates -> Map.delete(candidates, -1) end)
      )
    end

    assert {:ok, %{state: :terminal}} = Calls.leave_call(pair.caller, pair.call_id)
  end

  @tag :controlled_camera
  @tag :ticket16_workload
  test "first observation of closed buffered relay gates one retirement before fresh video" do
    pair = start_pair("closed_relay_first", :video)
    assert {:ok, _} = Calls.accept_call(pair.recipient, pair.call_id, :video)
    [source, destination] = Enum.map(await_sessions(pair.call_id), &connect_call_peer/1)
    camera = attach_call_camera(source, pair)
    assert_call_video(destination, <<0x10, 0, 1>>)
    await_video_transport_idle(destination.session)
    forwarder = call_forwarder(pair)
    assert {:ok, credentials} = DirectCallSession.media_credentials(destination.session)
    id = credentials.call_session_id
    ice = :sys.get_state(destination.server).ice_pid

    :sys.replace_state(ice, fn state ->
      candidate = state.ice_agent.local_cands |> Map.values() |> hd()

      relay = %ExICE.Priv.Candidate.Relay{
        base: %{candidate.base | id: -1, type: :relay, socket: nil, closed?: true},
        client: nil,
        buffered_packets: [{{127, 0, 0, 1}, 9, <<1>>}]
      }

      put_in(state.ice_agent.local_cands[-1], relay)
    end)

    try do
      send_video(source, camera, <<0x10, 0, 89>>, 2, 93_750)
      assert_call_video(destination, <<0x10, 0, 89>>)
      await_video_route_state(forwarder, id, destination.session, :recovering)
      send_video(source, camera, <<0x10, 1, 90>>, 3, 97_500)
      refute_video(destination, <<0x10, 1, 90>>)
      send_video(source, camera, <<0x10, 0, 91>>, 4, 101_250)
      assert_call_video(destination, <<0x10, 0, 91>>)
      await_video_route_state(forwarder, id, destination.session, :active)
    after
      :sys.replace_state(
        ice,
        &update_in(&1.ice_agent.local_cands, fn candidates -> Map.delete(candidates, -1) end)
      )
    end

    assert {:ok, %{state: :terminal}} = Calls.leave_call(pair.caller, pair.call_id)
  end

  @tag :controlled_camera
  @tag :ticket16_workload
  @tag timeout: 90_000
  test "sustained asymmetric video load preserves Call and Voice with bounded queues" do
    pair = start_pair("sustained_workload", :video)
    assert {:ok, _} = Calls.accept_call(pair.recipient, pair.call_id, :video)
    [source, destination] = Enum.map(await_sessions(pair.call_id), &connect_call_peer/1)
    camera = attach_call_camera(source, pair)
    assert_call_video(destination, <<0x10, 0, 1>>)
    reverse = attach_call_camera(destination, pair)
    assert_call_video(source, <<0x10, 0, 1>>)
    channel = Ecto.UUID.generate()
    voices = [connect_voice_peer(channel), connect_voice_peer(channel)]
    [voice_a, voice_b] = voices
    assert AdmissionCoordinator.effective_occupancy() == 4
    other_pair = start_pair("workload_one_call")

    assert {:ok, %{terminal_outcome: :failed_capacity}} =
             Calls.accept_call(other_pair.recipient, other_pair.call_id, :audio)

    assert AdmissionCoordinator.effective_occupancy() == 4
    assert {:ok, %{members: members}} = Voice.voice_channel_roster(channel)
    assert length(members) == 2
    gate = packet_gate(destination.browser, :workload)
    forwarder = call_forwarder(pair)
    assert {:ok, credentials} = DirectCallSession.media_credentials(destination.session)
    id = credentials.call_session_id
    source_state = :sys.get_state(source.server)
    destination_state = :sys.get_state(destination.server)

    processes =
      [
        source.session,
        forwarder,
        destination.session,
        source.server,
        source_state.dtls_transport,
        source_state.ice_pid,
        destination.server,
        destination_state.dtls_transport,
        destination_state.ice_pid
      ] ++
        Enum.uniq(Enum.flat_map(voices, & &1.resources))

    started = System.monotonic_time(:millisecond)
    cpu_started = elem(:erlang.statistics(:runtime), 0)
    utc_started = DateTime.utc_now()

    cells =
      for {mode, cell} <- Enum.with_index([:loss, :bandwidth, :cpu_burst]) do
        # 25% deterministic primary/RTX loss; or 4,800 RTP bytes/s destination
        # policer versus up to 25 x 1,000-byte primary payloads/s (plus real repair).
        {every, budget} =
          case mode do
            :loss -> {4, 0}
            :bandwidth -> {0, 4_800}
            :cpu_burst -> {0, 0}
          end

        :ok = DiscordClone.MediaPacketGate.impair_video(gate, every, budget)

        competitors =
          if mode == :cpu_burst do
            for _ <- 1..2 do
              pid =
                start_supervised!(%{
                  id: make_ref(),
                  start:
                    {Task, :start_link,
                     [
                       fn ->
                         delivery_cpu_pressure(System.monotonic_time(:millisecond) + 12_000)
                       end
                     ]}
                })

              {pid, Process.monitor(pid)}
            end
          else
            []
          end

        samples =
          for tick <- 1..300 do
            sequence =
              cell * 10_000 + tick + 2 +
                if(mode == :cpu_burst, do: 24 * div(tick - 1, 25), else: 0)

            payload = <<0x10, 0, rem(tick, 256)>> <> :binary.copy(<<7>>, 997)
            send_video(source, camera, payload, sequence, 90_000 + sequence * 3_750)

            if mode == :cpu_burst and rem(tick, 25) == 0 do
              # Twenty-four additional complete frames, immediately admitted/dropped.
              for offset <- 1..24 do
                send_video(
                  source,
                  camera,
                  payload,
                  sequence + offset,
                  90_000 + (sequence + offset) * 3_750
                )
              end
            end

            send_audio(source, <<0xF8, 0xFF, 0xFE>>, sequence, tick * 960)
            send_audio(destination, <<0xF9, 0xFF, 0xFE>>, sequence, tick * 960)
            send_audio(voice_a, <<0xF8, 0xFF, 0xFE, 1>>, sequence, tick * 960)
            send_audio(voice_b, <<0xF9, 0xFF, 0xFE, 2>>, sequence, tick * 960)
            assert_call_audio(destination, <<0xF8, 0xFF, 0xFE>>)
            assert_call_audio(source, <<0xF9, 0xFF, 0xFE>>)
            assert_voice_audio(voice_b, <<0xF8, 0xFF, 0xFE, 1>>)
            assert_voice_audio(voice_a, <<0xF9, 0xFF, 0xFE, 2>>)

            if rem(tick, 5) == 0 do
              reverse_sequence = cell * 60 + div(tick, 5) + 1

              send_video(
                destination,
                reverse,
                <<0x10, 0, 9>>,
                reverse_sequence,
                90_000 + reverse_sequence * 3_750
              )

              assert_call_video(source, <<0x10, 0, 9>>)
            end

            # A timer schedules the declared ingress cadence, never a sleep used to
            # guess completion. Audio outcomes above require actual encrypted delivery.
            timer = make_ref()
            Process.send_after(self(), {:workload_tick, timer}, 40)
            assert_receive {:workload_tick, ^timer}, 1_000
            if rem(tick, 25) == 0, do: workload_snapshot(processes)
          end
          |> Enum.reject(&is_nil/1)

        for {pid, monitor} <- competitors,
            do: assert_receive({:DOWN, ^monitor, :process, ^pid, :normal}, 2_000)

        load = DiscordClone.MediaPacketGate.impairment_stats(gate)
        assert load.seen > 100
        if mode != :cpu_burst, do: assert(load.dropped > 0)
        assert load.seen > load.dropped
        assert_workload_bounds(samples)
        # Restore the viable direction and require distinct current encoded media.
        :ok = DiscordClone.MediaPacketGate.impair_video(gate, 0, 0)
        await_video_transport_idle(destination.session)
        sequence = cell * 10_000 + 9_900
        send_video(source, camera, <<0x10, 0, 99>>, sequence, 90_000 + sequence * 3_750)
        receive_video(destination, <<0x10, 0, 99>>)
        await_video_route_state(forwarder, id, destination.session, :active)
        assert {:ok, %{state: :active}} = Calls.get_call(pair.caller, pair.call_id)
        assert AdmissionCoordinator.effective_occupancy() == 4
        %{mode: mode, samples: samples, impairment: load}
      end

    # Admission caps coexist with a video Call; occupied dormant Voice Sessions
    # below are accounting coverage, not a twenty-Session measured-load claim.
    extra_rooms = for _ <- 1..3, do: Ecto.UUID.generate()

    extras =
      for index <- 0..15 do
        room = if index < 3, do: channel, else: Enum.at(extra_rooms, div(index - 3, 5))

        assert {:ok, %{voice_session_id: session}} =
                 Voice.join(room, Ecto.UUID.generate(), Ecto.UUID.generate(), self())

        if index == 2 do
          assert {:ok, %{occupancy: 5}} = Voice.room_occupancy(channel)

          assert {:error, %{reason: :room_full}} =
                   Voice.join(channel, Ecto.UUID.generate(), Ecto.UUID.generate(), self())
        end

        {room, session}
      end

    assert AdmissionCoordinator.effective_occupancy() == 20

    assert {:error, %{reason: :deployment_full}} =
             Voice.join(Ecto.UUID.generate(), Ecto.UUID.generate(), Ecto.UUID.generate(), self())

    another = start_pair("workload_capacity")

    assert {:ok, %{terminal_outcome: :failed_capacity}} =
             Calls.accept_call(another.recipient, another.call_id, :audio)

    assert AdmissionCoordinator.effective_occupancy() == 20

    record = %{
      utc_start: utc_started,
      utc_end: DateTime.utc_now(),
      elapsed_ms: System.monotonic_time(:millisecond) - started,
      vm_cpu_ms: elem(:erlang.statistics(:runtime), 0) - cpu_started,
      schedulers: :erlang.system_info(:schedulers_online),
      otp: to_string(:erlang.system_info(:otp_release)),
      elixir: System.version(),
      architecture: to_string(:erlang.system_info(:system_architecture)),
      cells: cells
    }

    assert record.elapsed_ms >= 36_000

    File.write!(
      Path.join(System.tmp_dir!(), "communication-platform-workload.log"),
      Jason.encode!(record, pretty: true)
    )

    for {room, session} <- extras, do: assert(:ok = Voice.leave(room, session))
    assert {:ok, %{state: :terminal}} = Calls.leave_call(pair.caller, pair.call_id)
    assert AdmissionCoordinator.effective_occupancy() == 2
    for voice <- voices, do: assert(:ok = Voice.leave(channel, voice.session_id))
    assert AdmissionCoordinator.effective_occupancy() == 0
  end

  defp workload_snapshot(processes) do
    observations =
      Enum.map(processes, fn pid ->
        info = Process.info(pid, [:message_queue_len, :memory, :reductions])
        %{queue: info[:message_queue_len], memory: info[:memory], reductions: info[:reductions]}
      end)

    assert Enum.all?(observations, &(&1.queue <= 258))
    %{processes: observations, vm_memory: :erlang.memory(:total)}
  end

  defp assert_workload_bounds(samples) do
    for index <- 0..(length(hd(samples).processes) - 1) do
      first =
        samples |> Enum.take(4) |> Enum.map(&Enum.at(&1.processes, index).queue) |> Enum.max()

      last =
        samples |> Enum.take(-4) |> Enum.map(&Enum.at(&1.processes, index).queue) |> Enum.max()

      assert last <= first + 8
    end
  end

  @tag :controlled_camera
  @tag :ticket14_delivery
  @tag :ticket15_recovery
  @tag :ticket31_diagnostics
  test "slow destination transport retains one video credit through consumption" do
    attach_video_diagnostics()
    pair = start_pair("transport_credit", :video)
    assert {:ok, _} = Calls.accept_call(pair.recipient, pair.call_id, :video)
    [source, destination] = Enum.map(await_sessions(pair.call_id), &connect_call_peer/1)
    camera = attach_call_camera(source, pair)
    assert_call_video(destination, <<0x10, 0, 1>>)
    reverse = attach_call_camera(destination, pair)
    assert_call_video(source, <<0x10, 0, 1>>)
    forwarder = :sys.get_state(source.session).forwarder
    assert {:ok, credentials} = DirectCallSession.media_credentials(destination.session)
    destination_id = credentials.call_session_id
    await_video_route_state(forwarder, destination_id, destination.session, :active)
    source_state = :sys.get_state(source.server)
    destination_state = :sys.get_state(destination.server)

    processes = [
      source.session,
      forwarder,
      destination.session,
      source.server,
      source_state.dtls_transport,
      source_state.ice_pid,
      destination.server,
      destination_state.dtls_transport,
      destination_state.ice_pid
    ]

    labels =
      ~w(source forwarder destination source_pc source_dtls source_ice destination_pc destination_dtls destination_ice)a

    started = System.monotonic_time(:millisecond)

    pressure =
      start_supervised!(%{
        id: :delivery_cpu,
        start:
          {Task, :start_link,
           [
             fn ->
               delivery_cpu_pressure(started + 4_000)
             end
           ]}
      })

    monitor = Process.monitor(pressure)

    samples =
      for {held, cycle} <-
            Enum.with_index(
              List.duplicate(
                [
                  destination.session,
                  destination.server,
                  destination_state.dtls_transport,
                  destination_state.ice_pid
                ],
                3
              )
              |> List.flatten()
            ) do
        :sys.suspend(held)

        try do
          # One keyframe and 119 dependent frames/cycle, plus two-way Opus.
          for offset <- 1..60 do
            sequence = 2 + cycle * 130 + offset
            payload = if offset == 1, do: <<0x10, 0, 7>>, else: <<0x10, 1, 7>>
            send_video(source, camera, payload, sequence, 90_000 + sequence * 3_750)
          end

          send_audio(source, <<0xF8, 0xFF, 0xFE>>, cycle + 10, (cycle + 1) * 960)
          send_audio(destination, <<0xF9, 0xFF, 0xFE>>, cycle + 20, (cycle + 1) * 960)
          tick = make_ref()
          Process.send_after(self(), {:delivery_sample, tick}, 180)
          assert_receive {:delivery_sample, ^tick}, 1_000

          assert {:ok, %{state: :interrupted}} =
                   DiscordClone.Voice.Forwarder.video_route_status(
                     forwarder,
                     destination_id,
                     destination.session
                   )

          for offset <- 61..120 do
            sequence = 2 + cycle * 130 + offset
            send_video(source, camera, <<0x10, 1, 8>>, sequence, 90_000 + sequence * 3_750)
          end

          snapshot =
            Map.new(Enum.zip(labels, processes), fn {label, pid} ->
              %{mailbox_len: count} = DiscordClone.Media.Diagnostics.queue_snapshot(pid)
              {label, count}
            end)

          assert Enum.all?(Map.values(snapshot), &(&1 <= 258))
          snapshot
        after
          safely_resume(held)
        end
        |> then(fn snapshot ->
          # Shared-runtime stalls temporarily hold audio too; viable intervals
          # must deliver both Opus directions and the unaffected video direction.
          assert_call_audio(destination, <<0xF8, 0xFF, 0xFE>>)
          assert_call_audio(source, <<0xF9, 0xFF, 0xFE>>)
          await_video_route_state(forwarder, destination_id, destination.session, :recovering)
          assert_camera_pli(source, camera)
          sequence = 124 + cycle * 130
          send_video(source, camera, <<0x10, 1, 66>>, sequence, 90_000 + sequence * 3_750)
          refute_video(destination, <<0x10, 1, 66>>)
          send_video(source, camera, <<0x10, 0, 99>>, sequence + 1, 93_750 + sequence * 3_750)

          assert_receive {:ex_webrtc, destination_browser,
                          {:rtp, _, nil, %{payload: <<0x10, 0, 99>>}}},
                         2_000

          assert destination_browser == destination.browser
          await_video_route_state(forwarder, destination_id, destination.session, :active)
          send_video(destination, reverse, <<0x10, 0, 9>>, cycle + 2, 93_750 + cycle * 3_750)
          assert_call_video(source, <<0x10, 0, 9>>)
          snapshot
        end)
      end

    assert System.monotonic_time(:millisecond) - started >= 2_160

    for label <- labels do
      first = samples |> Enum.take(4) |> Enum.map(&Map.fetch!(&1, label)) |> Enum.max()
      last = samples |> Enum.take(-4) |> Enum.map(&Map.fetch!(&1, label)) |> Enum.max()
      assert last <= first + 8
    end

    assert_receive {:video_diagnostic, %{interruptions: 1, mailbox_len: queue},
                    %{operation: :route, outcome: :interrupted}}

    assert queue >= 0
    assert_receive {:video_diagnostic, _, %{operation: :route, outcome: :recovering}}
    assert_receive {:video_diagnostic, _, %{operation: :route, outcome: :active}}
    refute_receive {:video_diagnostic, _, %{operation: :route, outcome: :interrupted}}, 0

    assert {:ok, %{interruptions: 12, recoveries: 12} = recovery} =
             DiscordClone.Voice.Forwarder.video_route_status(
               forwarder,
               destination_id,
               destination.session
             )

    assert recovery.discarded_packets > 0

    File.write!(
      Path.join(System.tmp_dir!(), "communication-platform-queues.log"),
      inspect(%{queues: samples, recovery: recovery}, limit: :infinity)
    )

    assert_receive {:DOWN, ^monitor, :process, ^pressure, :normal}, 5_000
    assert {:ok, %{state: :terminal}} = Calls.leave_call(pair.caller, pair.call_id)
  end

  @tag :controlled_camera
  @tag :ticket15_recovery
  test "off and source loss retire overloaded real drains before camera replacement" do
    pair = start_pair("overload_retirement", :video)
    assert {:ok, _} = Calls.accept_call(pair.recipient, pair.call_id, :video)
    [source, destination] = Enum.map(await_sessions(pair.call_id), &connect_call_peer/1)
    camera = attach_call_camera(source, pair)
    assert_call_video(destination, <<0x10, 0, 1>>)
    reverse = attach_call_camera(destination, pair)
    assert_call_video(source, <<0x10, 0, 1>>)
    forwarder = call_forwarder(pair)
    assert {:ok, credentials} = DirectCallSession.media_credentials(destination.session)
    id = credentials.call_session_id
    await_video_route_state(forwarder, id, destination.session, :active)
    peers = MapSet.new(PeerConnection.get_all_running())

    for {retirement, cycle} <- Enum.with_index([:off, :source_ended]) do
      :sys.suspend(destination.session)

      try do
        sequence = cycle * 10 + 2
        send_video(source, camera, <<0x10, 0, 71>>, sequence, 90_000 + sequence * 3_750)
        await_video_route_state(forwarder, id, destination.session, :interrupted)

        case retirement do
          :off ->
            repair_camera_state(source, pair, 2, false)

          :source_ended ->
            [_audio, video] = PeerConnection.get_transceivers(source.server)

            send(
              source.session,
              {:ex_webrtc, source.server, {:track_ended, video.receiver.track.id}}
            )

            _ = :sys.get_state(source.session)
            repair_camera_state(source, pair, 4, false)
        end

        DiscordClone.Voice.Forwarder.sync(forwarder)

        assert {:error, :not_ready} =
                 DiscordClone.Voice.Forwarder.video_route_status(
                   forwarder,
                   id,
                   destination.session
                 )

        repair_camera_state(source, pair, cycle * 2 + 3, true)
        send_video(source, camera, <<0x10, 0, 72>>, sequence + 1, 93_750 + sequence * 3_750)
        # Source readiness establishes the replacement while old transport credit
        # remains occupied; the old completion must not activate this keyframe.
        await_video_route_state(forwarder, id, destination.session, :recovering)
        await_busy_frame_drop(forwarder, id, destination.session)
      after
        safely_resume(destination.session)
      end

      refute_video(destination, <<0x10, 0, 71>>)
      refute_video(destination, <<0x10, 0, 72>>)
      sequence = cycle * 10 + 5
      send_video(source, camera, <<0x10, 1, 73>>, sequence, 90_000 + sequence * 3_750)
      refute_video(destination, <<0x10, 1, 73>>)
      send_video(source, camera, <<0x10, 0, 74>>, sequence + 1, 93_750 + sequence * 3_750)
      receive_video(destination, <<0x10, 0, 74>>)
      await_video_route_state(forwarder, id, destination.session, :active)
      send_video(destination, reverse, <<0x10, 0, 75>>, cycle + 2, 93_750 + cycle * 3_750)
      assert_call_video(source, <<0x10, 0, 75>>)
      send_audio(source, <<0xF8, 0xFF, 0xFE>>, cycle + 10, (cycle + 1) * 960)
      send_audio(destination, <<0xF9, 0xFF, 0xFE>>, cycle + 20, (cycle + 1) * 960)
      assert_call_audio(destination, <<0xF8, 0xFF, 0xFE>>)
      assert_call_audio(source, <<0xF9, 0xFF, 0xFE>>)
      assert MapSet.new(PeerConnection.get_all_running()) == peers
    end

    monitors =
      Enum.map(
        DirectCallSession.resources(source.session) ++
          DirectCallSession.resources(destination.session),
        &Process.monitor/1
      )

    assert {:ok, %{state: :terminal}} = Calls.leave_call(pair.caller, pair.call_id)
    for monitor <- monitors, do: assert_receive({:DOWN, ^monitor, :process, _, _}, 2_000)
  end

  for exit <- [:leave, :closed, :microphone_ended, :pc_crash, :forwarder_crash] do
    @tag :controlled_camera
    @tag :ticket29_cleanup
    @video_exit exit
    test "ticket29 #{@video_exit} retires video work within the server clock and preserves a replacement" do
      pair = start_pair("video_cleanup", :video)
      assert {:ok, _} = Calls.accept_call(pair.recipient, pair.call_id, :video)
      sessions = await_sessions(pair.call_id)
      [source, destination] = Enum.map(sessions, &connect_call_peer/1)
      camera = attach_call_camera(source, pair)
      assert_call_video(destination, <<0x10, 0, 1>>)
      attach_call_camera(destination, pair)
      assert_call_video(source, <<0x10, 0, 1>>)
      send_audio(source, <<0xF8, 0xFF, 0xFE>>, 10, 960)
      send_audio(destination, <<0xF9, 0xFF, 0xFE>>, 10, 960)
      assert_call_audio(destination, <<0xF8, 0xFF, 0xFE>>)
      assert_call_audio(source, <<0xF9, 0xFF, 0xFE>>)
      forwarder = call_forwarder(pair)
      assert {:ok, credentials} = DirectCallSession.media_credentials(destination.session)
      id = credentials.call_session_id
      await_video_route_state(forwarder, id, destination.session, :active)
      old = AdmissionCoordinator.call_target_snapshot(pair.call_id)
      monitors = monitor_resources(sessions) ++ [{forwarder, Process.monitor(forwarder)}]
      # Hold consumption after actual encrypted media worked. Leave/failure must
      # retire the queued frame without waiting for an obsolete completion.
      :sys.suspend(destination.session)

      retired_delivery =
        try do
          send_video(source, camera, <<0x10, 0, 71>>, 2, 97_500)
          await_video_route_state(forwarder, id, destination.session, :interrupted)
          {:messages, messages} = Process.info(destination.session, :messages)

          delivery =
            Enum.find_value(messages, fn
              {:"$gen_cast",
               {:deliver_video, ^forwarder, ^id, route, credit, _packets, _deadline}} ->
                %{route_ref: route, credit: credit}

              _ ->
                nil
            end)

          assert delivery != nil
          started = System.monotonic_time(:millisecond)

          case @video_exit do
            :leave ->
              assert {:ok, %{state: :terminal}} = Calls.leave_call(pair.recipient, pair.call_id)

            :closed ->
              send(
                source.session,
                {:ex_webrtc, source.server, {:connection_state_change, :closed}}
              )

            :microphone_ended ->
              [audio, _video] = PeerConnection.get_transceivers(source.server)

              send(
                source.session,
                {:ex_webrtc, source.server, {:track_ended, audio.receiver.track.id}}
              )

            :pc_crash ->
              Process.exit(source.server, :kill)

            :forwarder_crash ->
              Process.exit(forwarder, :kill)
          end

          assert_retired(monitors, started)

          if @video_exit != :leave do
            call_id = pair.call_id
            assert_receive {:call_failed, %{call_id: ^call_id}}, 2_000
          end

          assert {:ok, %{state: :terminal}} = Calls.get_call(pair.caller, pair.call_id)
          assert AdmissionCoordinator.effective_occupancy() == 0
          delivery
        after
          safely_resume(destination.session)
        end

      assert :ok = AdmissionCoordinator.cleanup_active_pair_for_call(pair.call_id)
      assert :ok = AdmissionCoordinator.cleanup_active_pair_for_call(pair.call_id)

      assert {:ok, %{call: next_call}} =
               Calls.start_call(pair.caller, pair.conversation_id, :video)

      next = %{pair | call_id: next_call.call_id}
      assert {:ok, _} = Calls.accept_call(next.recipient, next.call_id, :video)
      [first, second] = Enum.map(await_sessions(next.call_id), &connect_call_peer/1)
      fresh_camera = attach_call_camera(first, next)
      attach_call_camera(second, next)
      Enum.each([first, second], &assert_call_video(&1, <<0x10, 0, 1>>))
      current_forwarder = call_forwarder(next)
      # Replay an obsolete completion against the replacement's public seam.
      DiscordClone.Voice.Forwarder.video_delivered(
        current_forwarder,
        id,
        destination.session,
        retired_delivery.route_ref,
        retired_delivery.credit
      )

      assert :ok = AdmissionCoordinator.call_target_stopped(pair.call_id, old.runtime_generation)
      assert :ok = AdmissionCoordinator.cleanup_active_pair_for_call(pair.call_id)
      send_video(first, fresh_camera, <<0x10, 0, 99>>, 2, 97_500)
      assert_call_video(second, <<0x10, 0, 99>>)
      send_audio(first, <<0xF8, 0xFF, 0xFE>>, 20, 1_920)
      send_audio(second, <<0xF9, 0xFF, 0xFE>>, 20, 1_920)
      assert_call_audio(second, <<0xF8, 0xFF, 0xFE>>)
      assert_call_audio(first, <<0xF9, 0xFF, 0xFE>>)
      assert {:ok, %{state: :active}} = Calls.get_call(next.caller, next.call_id)
      assert {:ok, %{state: :terminal}} = Calls.leave_call(next.caller, next.call_id)
    end
  end

  @tag :controlled_camera
  test "malformed and foreign video preserve real reverse VP8, two-way Opus and later valid input" do
    pair = start_pair("invalid_video", :video)
    assert {:ok, _} = Calls.accept_call(pair.recipient, pair.call_id, :video)
    [first, second] = Enum.map(await_sessions(pair.call_id), &connect_call_peer/1)
    camera = attach_call_camera(first, pair)
    assert_call_video(second, <<0x10, 0, 1>>)
    reverse = attach_call_camera(second, pair)
    assert_call_video(first, <<0x10, 0, 1>>)
    [_audio, video] = PeerConnection.get_transceivers(first.server)
    [_audio, destination] = PeerConnection.get_transceivers(second.browser)
    browser = second.browser
    receiver = destination.receiver.track.id
    snapshot = AdmissionCoordinator.call_target_snapshot(pair.call_id)

    assert {:ok, credentials} =
             DirectCallSession.media_credentials(first.session, Ecto.UUID.generate())

    forwarder =
      GenServer.whereis(
        Target.runtime_name(
          Target.direct_call(pair.call_id),
          snapshot.runtime_generation,
          :forwarder
        )
      )

    # These traverse real encrypted/negotiated PC legs, including a parser-
    # accepted L-without-T descriptor and every truncated optional field.
    for {payload, sequence} <-
          Enum.with_index(
            [
              <<>>,
              <<0x90>>,
              <<0x90, 0x80>>,
              <<0x90, 0x80, 0x80>>,
              <<0x90, 0x40>>,
              <<0x90, 0x20>>,
              <<0x90, 0x10>>,
              <<0x90, 0x40, 200, 0>>,
              <<0x50, 0>>,
              <<0x90, 1, 0>>
            ],
            2
          ) do
      assert :ok =
               PeerConnection.send_rtp(
                 first.browser,
                 camera,
                 ExRTP.Packet.new(payload, sequence_number: sequence, timestamp: 180_000)
               )
    end

    # Wrong PC, inbound track and unsupported RID must be rejected by the
    # Session adapter; wrong Session/process/retired route at the Forwarder.
    poison =
      ExRTP.Packet.new(<<0x10, 0, 9>>,
        sequence_number: 30_000,
        timestamp: 3_000_000,
        marker: true
      )

    for {peer, track, rid} <- [
          {second.server, video.receiver.track.id, nil},
          {first.server, -1, nil},
          {first.server, video.receiver.track.id, "foreign"}
        ] do
      send(first.session, {:ex_webrtc, peer, {:rtp, track, rid, poison}})
    end

    for {id, process, track} <- [
          {Ecto.UUID.generate(), first.session, video.receiver.track.id},
          {credentials.call_session_id, second.session, video.receiver.track.id},
          {credentials.call_session_id, first.session, -1}
        ] do
      DiscordClone.Voice.Forwarder.forward_rtp(forwarder, id, process, :video, track, poison)
    end

    _ = :sys.get_state(first.session)
    DiscordClone.Voice.Forwarder.sync(forwarder)

    assert :ok =
             PeerConnection.send_rtp(
               first.browser,
               camera,
               ExRTP.Packet.new(<<0x10, 0, 2>>,
                 sequence_number: 20,
                 timestamp: 183_750,
                 marker: true
               )
             )

    assert_receive {:ex_webrtc, ^browser, {:rtp, ^receiver, nil, recovered}}, 2_000
    assert recovered.payload == <<0x10, 0, 2>>
    assert recovered.sequence_number == 20
    assert recovered.timestamp == 183_750

    assert :ok =
             PeerConnection.send_rtp(
               second.browser,
               reverse,
               ExRTP.Packet.new(<<0x10, 0, 3>>,
                 sequence_number: 2,
                 timestamp: 93_750,
                 marker: true
               )
             )

    assert_call_video(first, <<0x10, 0, 3>>)
    send_audio(first, <<0xF8, 0xFF, 0xFE>>, 10, 960)
    send_audio(second, <<0xF9, 0xFF, 0xFE>>, 20, 1_920)
    assert_call_audio(second, <<0xF8, 0xFF, 0xFE>>)
    assert_call_audio(first, <<0xF9, 0xFF, 0xFE>>)
    refute_receive {:ex_webrtc, _, {:rtp, _, _, _}}, 100
    assert {:ok, %{state: :active}} = Calls.get_call(pair.caller, pair.call_id)
    assert AdmissionCoordinator.effective_occupancy() == 2
    assert {:ok, %{state: :terminal}} = Calls.leave_call(pair.caller, pair.call_id)
  end

  @tag :controlled_camera
  @tag :ticket11_alignment
  test "initial opposite audio/video reports describe their actual destination timelines" do
    pair = start_pair("alignment", :video)
    assert {:ok, _} = Calls.accept_call(pair.recipient, pair.call_id, :video)
    [first, second] = Enum.map(await_sessions(pair.call_id), &connect_call_peer/1)

    for {source, destination} <- [{first, second}, {second, first}] do
      camera = attach_call_camera(source, pair)
      assert_call_video(destination, <<0x10, 0, 1>>)
      [audio, video] = PeerConnection.get_transceivers(destination.server)
      assert [stream] = audio.sender.track.streams
      assert video.sender.track.streams == [stream]

      # Bracket the actual send, forwarding and receive. Reports are inspected
      # on the encrypted destination leg, not manufactured from recorder state.
      earliest = System.os_time(:microsecond)
      send_audio(source, <<0xF8, 0xFF, 0xFE>>, 10, 48_000)
      send_video(source, camera, <<0x10, 0, 2>>, 2, 93_750)
      audio_packet = assert_call_audio(destination, <<0xF8, 0xFF, 0xFE>>)
      video_packet = receive_video(destination, <<0x10, 0, 2>>)
      latest = System.os_time(:microsecond)

      for {position, packet, rate} <- [
            {audio, audio_packet, 48_000},
            {video, video_packet, 90_000}
          ] do
        assert_report_time(destination, position, packet, rate, earliest, latest)
      end
    end

    assert {:ok, %{state: :terminal}} = Calls.leave_call(pair.caller, pair.call_id)
  end

  @tag :controlled_camera
  @tag :ticket12_alignment
  test "fresh camera timing and encrypted reports survive unequal video-only leg delays in both directions" do
    pair = start_pair("recovery_alignment", :video)
    assert {:ok, _} = Calls.accept_call(pair.recipient, pair.call_id, :video)
    [first, second] = Enum.map(await_sessions(pair.call_id), &connect_call_peer/1)

    for {{source, destination}, index} <- Enum.with_index([{first, second}, {second, first}]) do
      old_camera = attach_call_camera(source, pair)
      before = receive_video(destination, <<0x10, 0, 1>>)
      source_gate = packet_gate(source.server, :alignment_source)
      destination_gate = packet_gate(destination.browser, :alignment_destination)
      assert :ok = DiscordClone.MediaPacketGate.delay_video(source_gate, 80)
      assert :ok = DiscordClone.MediaPacketGate.delay_video(destination_gate, 120)
      signaling = Ecto.UUID.generate()
      assert {:ok, credentials} = DirectCallSession.media_credentials(source.session, signaling)

      off = %{
        "call_id" => pair.call_id,
        "call_session_id" => credentials.call_session_id,
        "signaling_session_id" => signaling,
        "negotiation_id" => "audio",
        "media_state_version" => 2,
        "microphone_muted" => false,
        "camera_enabled" => false
      }

      assert {:ok, %{camera_enabled: false}} =
               DirectCallSession.local_media_state(source.session, off)

      send_audio(source, <<0xF8, 0xFF, 0xFE>>, 10 + index * 20, 48_000)
      assert_call_audio(destination, <<0xF8, 0xFF, 0xFE>>)
      send_audio(destination, <<0xF9, 0xFF, 0xFE>>, 10 + index * 20, 48_000)
      assert_call_audio(source, <<0xF9, 0xFF, 0xFE>>)
      [_audio, sender] = PeerConnection.get_transceivers(source.browser)
      fresh = MediaStreamTrack.new(:video)
      assert fresh.id != old_camera
      assert :ok = PeerConnection.replace_track(source.browser, sender.sender.id, fresh)

      assert {:ok, %{camera_enabled: true}} =
               DirectCallSession.local_media_state(source.session, %{
                 off
                 | "camera_enabled" => true,
                   "media_state_version" => 3
               })

      DiscordClone.Voice.Forwarder.sync(call_forwarder(pair))

      # Explicitly new source epoch; never compare against the retired camera's SR.
      earliest = System.os_time(:microsecond)
      monotonic = System.monotonic_time(:millisecond)
      send_video(source, fresh.id, <<0x10, 0, 12>>, 500, 900_000)
      send_audio(source, <<0xF8, 0xFF, 0xFD>>, 11 + index * 20, 48_960)
      audio_packet = assert_call_audio(destination, <<0xF8, 0xFF, 0xFD>>)
      audio_received = System.os_time(:microsecond)
      source_sent = System.os_time(:microsecond)
      expected_source_ssrc = source_ssrc(source)
      returned = receive_video(destination, <<0x10, 0, 12>>)
      latest = System.os_time(:microsecond)
      elapsed = System.monotonic_time(:millisecond) - monotonic
      [_audio, source_video] = PeerConnection.get_transceivers(source.browser)
      send(source.browser, {:send_reports, source_video.id})

      assert_receive {:media_report, :alignment_source,
                      %ExRTCP.Packet.SenderReport{
                        packet_count: count,
                        ssrc: ^expected_source_ssrc
                      } = source_report}
                     when count >= 2,
                     2_000

      assert elapsed >= 200
      assert returned.sequence_number == before.sequence_number + 1
      assert returned.timestamp > before.timestamp and returned.timestamp != 900_000
      assert returned.ssrc == before.ssrc
      assert returned.payload_type == before.payload_type

      assert_receive {:media_packet, :alignment_source,
                      %{timestamp: 900_000, digest: digest, ssrc: ^expected_source_ssrc}}

      assert digest == :crypto.hash(:sha256, <<0x10, 0, 12>>)

      assert_receive {:media_packet, :alignment_destination,
                      %{timestamp: timestamp, digest: ^digest}}

      assert timestamp == returned.timestamp
      [audio, video] = PeerConnection.get_transceivers(destination.server)

      audio_time =
        assert_report_time(
          destination,
          audio,
          audio_packet,
          48_000,
          earliest,
          audio_received,
          1 + index * 2
        )

      video_time =
        assert_report_time(
          destination,
          video,
          returned,
          90_000,
          earliest + 80_000,
          latest - 120_000
        )

      source_time = report_packet_time(source_report, 900_000, 90_000)
      assert source_time >= earliest - (1_000_000 / 90_000 + 1)
      assert source_time <= source_sent + (1_000_000 / 90_000 + 1)
      assert source_report.ssrc != returned.ssrc
      assert video_time - source_time >= 80_000 - (1_000_000 / 90_000 + 1)
      # The pinned SR anchors at destination send, excluding the downstream hold.
      # This exposes the source-leg video delay; it does not claim capture sync.
      assert video_time - audio_time >= 80_000 - (1_000_000 / 90_000 + 1)
      send_video(source, fresh.id, <<0x10, 0, 13>>, 501, 903_750)
      next = receive_video(destination, <<0x10, 0, 13>>)
      assert next.timestamp - returned.timestamp == 3_750
      assert {:ok, %{state: :active}} = Calls.get_call(pair.caller, pair.call_id)
    end

    assert {:ok, %{state: :terminal}} = Calls.leave_call(pair.caller, pair.call_id)
  end

  for direction <- [:first, :second], leg <- [:source, :destination] do
    @repair_direction direction
    @repair_leg leg
    @tag :controlled_camera
    @tag :ticket10_repair
    test "#{@repair_direction} video repairs #{@repair_leg} leg history through wrap, return and rebuild" do
      pair = start_pair("repair", :video)
      assert {:ok, _} = Calls.accept_call(pair.recipient, pair.call_id, :video)
      [first, second] = Enum.map(await_sessions(pair.call_id), &connect_call_peer/1)

      {source, destination} =
        if @repair_direction == :first, do: {first, second}, else: {second, first}

      source_gate = packet_gate(source.server, :source_receiver)
      packet_gate(source.browser, :source_sender)
      destination_gate = packet_gate(destination.browser, :destination_receiver)
      packet_gate(destination.server, :destination_sender)
      camera = attach_call_camera(source, pair, 65_533)
      before = receive_video(destination, <<0x10, 0, 1>>)
      reverse = attach_call_camera(destination, pair)
      assert_call_video(source, <<0x10, 0, 1>>)
      assert_camera_pli(source, camera)
      assert_camera_pli(destination, reverse)
      flush_packet_observations()

      gate = if @repair_leg == :source, do: source_gate, else: destination_gate
      repaired = repair_video(source, destination, camera, gate, @repair_leg, 65_534, 65_534, 2)
      assert repaired.ssrc == before.ssrc
      assert repaired.payload_type == before.payload_type
      flush_packet_observations()
      wrapped = repair_video(source, destination, camera, gate, @repair_leg, 0, 0, 4)
      assert wrapped.sequence_number == 0

      # Obtain old repair while the newest primary is definitely in the native
      # cache. Hold exactly one authenticated RTX notification across retirement;
      # random RTX sequence numbers may otherwise evict old modulo-cache slots.
      send_video(source, camera, <<0x10, 0, 6>>, 2, 112_500)
      old_primary = receive_video(destination, <<0x10, 0, 6>>)
      assert :ok = DiscordClone.MediaPacketGate.hold_repair(destination_gate, 2)
      assert :ok = DiscordClone.MediaPacketGate.request_history(destination_gate, before.ssrc, 2)

      assert_receive {:media_packet, :destination_receiver,
                      %{kind: :rtx, sequence: 2, held?: true} = obsolete},
                     2_000

      assert obsolete.digest == :crypto.hash(:sha256, <<0x10, 0, 6>>)

      # Retained sender counters cross replaceTrack. Off-only input advances
      # source history, not destination, and its native repair stays local.
      off = repair_camera_state(source, pair, 2, false)
      send_video(source, camera, <<0x10, 0, 7>>, 3, 116_250)
      assert_receive {:media_packet, :source_receiver, %{sequence: 3}}, 2_000
      _ = :sys.get_state(source.server)
      _ = :sys.get_state(source.session)
      refute_video(destination, <<0x10, 0, 7>>)
      flush_packet_observations()

      assert :ok =
               DiscordClone.MediaPacketGate.request_history(source_gate, source_ssrc(source), 3)

      assert_receive {:media_packet, :source_receiver, %{kind: :rtx, sequence: 3}}, 2_000
      refute_video(destination, <<0x10, 0, 7>>)

      [_audio, source_video] = PeerConnection.get_transceivers(source.browser)
      fresh = MediaStreamTrack.new(:video)
      assert :ok = PeerConnection.replace_track(source.browser, source_video.sender.id, fresh)

      assert {:ok, %{camera_enabled: true}} =
               DirectCallSession.local_media_state(
                 source.session,
                 %{off | "camera_enabled" => true, "media_state_version" => 3}
               )

      send_video(source, fresh.id, <<0x10, 0, 8>>, 4, 120_000)
      returned = receive_video(destination, <<0x10, 0, 8>>)
      assert returned.sequence_number == 3
      assert returned.timestamp > old_primary.timestamp
      assert returned.ssrc == before.ssrc
      assert_camera_pli(source, fresh.id)
      flush_packet_observations()
      repair_video(source, destination, fresh.id, gate, @repair_leg, 5, 4, 9)

      # Rebuild the exact route on the retained receiver; the source's missing
      # numbers and the rewritten destination history now differ by two.
      assert {:ok, credentials} = DirectCallSession.media_credentials(destination.session)
      forwarder = call_forwarder(pair)

      DiscordClone.Voice.Forwarder.receive_unready(
        forwarder,
        credentials.call_session_id,
        destination.session,
        :video
      )

      DiscordClone.Voice.Forwarder.sync(forwarder)
      send_video(source, fresh.id, <<0x10, 0, 11>>, 7, 131_250)
      assert_receive {:media_packet, :source_receiver, %{sequence: 7}}, 2_000
      _ = :sys.get_state(source.server)
      _ = :sys.get_state(source.session)
      DiscordClone.Voice.Forwarder.sync(forwarder)
      refute_video(destination, <<0x10, 0, 11>>)
      report_connection(destination, :connected)
      DiscordClone.Voice.Forwarder.sync(forwarder)
      send_video(source, fresh.id, <<0x10, 0, 12>>, 8, 135_000)
      rebuilt = receive_video(destination, <<0x10, 0, 12>>)
      assert rebuilt.sequence_number == 6
      assert rebuilt.ssrc == before.ssrc
      assert_camera_pli(source, fresh.id)
      flush_packet_observations()
      current = repair_video(source, destination, fresh.id, gate, @repair_leg, 9, 7, 13)

      # Release the actual OLD repair after current-camera repair. Its original
      # sequence/time/content is obsolete evidence, never fresh-camera content.
      assert :ok = DiscordClone.MediaPacketGate.release_repair(destination_gate)
      old = receive_video(destination, <<0x10, 0, 6>>)
      assert old.timestamp == old_primary.timestamp
      assert old.sequence_number == old_primary.sequence_number
      assert old.timestamp < current.timestamp
      refute_receive {:media_nack, :source_sender, _, _}, 150

      [_audio, receiving] = PeerConnection.get_transceivers(destination.browser)
      assert :ok = PeerConnection.send_pli(destination.browser, receiving.receiver.track.id)
      assert_camera_pli(source, fresh.id)
      source_browser = source.browser

      refute_receive {:ex_webrtc, ^source_browser,
                      {:rtcp, [{^camera, %ExRTCP.Packet.PayloadFeedback.PLI{}}]}},
                     0

      send_video(source, fresh.id, <<0x10, 0, 15>>, 11, 146_250)
      assert receive_video(destination, <<0x10, 0, 15>>).sequence_number == 9
      send_video(destination, reverse, <<0x10, 0, 15>>, 2, 93_750)
      assert_call_video(source, <<0x10, 0, 15>>)
      send_audio(source, <<0xF8, 0xFF, 0xFE>>, 10, 960)
      send_audio(destination, <<0xF9, 0xFF, 0xFE>>, 20, 1_920)
      assert_call_audio(destination, <<0xF8, 0xFF, 0xFE>>)
      assert_call_audio(source, <<0xF9, 0xFF, 0xFE>>)
      assert {:ok, %{state: :active}} = Calls.get_call(pair.caller, pair.call_id)
      assert AdmissionCoordinator.effective_occupancy() == 2
      assert {:ok, %{state: :terminal}} = Calls.leave_call(pair.caller, pair.call_id)
    end
  end

  @tag :controlled_camera
  @tag :ticket10_repair
  test "source loss remains missing when negotiated sender repair is disabled" do
    pair = start_pair("no_repair", :video)
    assert {:ok, _} = Calls.accept_call(pair.recipient, pair.call_id, :video)
    [first, second] = await_sessions(pair.call_id)
    source = connect_call_peer(first, features: [:twcc, :inbound_rtx, :rtcp_reports])
    destination = connect_call_peer(second)
    gate = packet_gate(source.server, :source_receiver)
    packet_gate(source.browser, :source_sender)
    camera = attach_call_camera(source, pair)
    assert_call_video(destination, <<0x10, 0, 1>>)
    assert_camera_pli(source, camera)
    flush_packet_observations()
    assert :ok = DiscordClone.MediaPacketGate.drop_next(gate, 2)
    send_video(source, camera, <<0x10, 0, 2>>, 2, 93_750)
    assert_receive {:media_packet, :source_receiver, %{dropped?: true, sequence: 2}}, 2_000
    send_video(source, camera, <<0x10, 0, 3>>, 3, 97_500)
    assert_call_video(destination, <<0x10, 0, 3>>)
    assert_receive {:media_nack, :source_sender, _, [2]}, 2_000
    refute_receive {:media_packet, :source_receiver, %{kind: :rtx}}, 400
    refute_video(destination, <<0x10, 0, 2>>)
    send_audio(source, <<0xF8, 0xFF, 0xFE>>, 10, 960)
    send_audio(destination, <<0xF9, 0xFF, 0xFE>>, 20, 1_920)
    assert_call_audio(destination, <<0xF8, 0xFF, 0xFE>>)
    assert_call_audio(source, <<0xF9, 0xFF, 0xFE>>)
    assert {:ok, %{state: :terminal}} = Calls.leave_call(pair.caller, pair.call_id)
  end

  for direction <- [:first, :second], order <- [:source_first, :destination_first] do
    @proactive_direction direction
    @readiness_order order
    @tag :controlled_camera
    @tag :ticket09_proactive
    test "proactive keyframe reaches #{@proactive_direction} camera with #{@readiness_order} readiness" do
      pair = start_pair("proactive", :video)
      assert {:ok, _} = Calls.accept_call(pair.recipient, pair.call_id, :audio)
      [first, second] = await_sessions(pair.call_id)

      {source_session, destination_session} =
        if @proactive_direction == :first, do: {first, second}, else: {second, first}

      source = connect_call_peer(source_session)

      destination =
        if @readiness_order == :destination_first, do: connect_call_peer(destination_session)

      camera = attach_call_camera(source, pair)
      browser = source.browser

      destination =
        if @readiness_order == :source_first do
          refute_receive {:ex_webrtc, ^browser,
                          {:rtcp, [{^camera, %ExRTCP.Packet.PayloadFeedback.PLI{}}]}},
                         100

          connect_call_peer(destination_session)
        else
          destination
        end

      # No decoder feedback has been sent on either real encrypted leg.
      assert_receive {:ex_webrtc, ^browser,
                      {:rtcp, [{^camera, %ExRTCP.Packet.PayloadFeedback.PLI{}}]}},
                     2_000

      assert_camera_pli(source, camera)
      refute_receive {:ex_webrtc, _, {:rtcp, [{_, %ExRTCP.Packet.PayloadFeedback.PLI{}}]}}, 550
      send_audio(source, <<0xF8, 0xFF, 0xFE>>, 10, 960)
      send_audio(destination, <<0xF9, 0xFF, 0xFE>>, 20, 1_920)
      assert_call_audio(destination, <<0xF8, 0xFF, 0xFE>>)
      assert_call_audio(source, <<0xF9, 0xFF, 0xFE>>)
      assert AdmissionCoordinator.effective_occupancy() == 2
      assert {:ok, %{state: :terminal}} = Calls.leave_call(pair.caller, pair.call_id)
    end
  end

  @tag :controlled_camera
  @tag :ticket09_proactive
  @tag :ticket33_rebuild
  test "retained-camera rebuild has bounded spaced keyframe opportunities and retires pending work" do
    pair = start_pair("rebuild_presentation", :video)
    assert {:ok, _} = Calls.accept_call(pair.recipient, pair.call_id, :audio)
    [first, second] = Enum.map(await_sessions(pair.call_id), &connect_call_peer/1)
    camera = attach_call_camera(first, pair)
    assert_call_video(second, <<0x10, 0, 1>>)
    assert_camera_pli(first, camera)
    # Fresh capture's early encoded/proactive keyframes can both miss presentation.
    assert_camera_pli(first, camera)
    browser = first.browser

    refute_receive {:ex_webrtc, ^browser,
                    {:rtcp, [{^camera, %ExRTCP.Packet.PayloadFeedback.PLI{}}]}},
                   600

    forwarder = call_forwarder(pair)
    assert {:ok, credentials} = DirectCallSession.media_credentials(second.session)
    destination_id = credentials.call_session_id

    DiscordClone.Voice.Forwarder.receive_unready(
      forwarder,
      destination_id,
      second.session,
      :video
    )

    report_connection(second, :connected)
    assert_camera_pli(first, camera)
    browser = first.browser

    for _ <- 1..3 do
      started = System.monotonic_time(:millisecond)

      refute_receive {:ex_webrtc, ^browser,
                      {:rtcp, [{^camera, %ExRTCP.Packet.PayloadFeedback.PLI{}}]}},
                     400

      assert_camera_pli(first, camera)
      assert System.monotonic_time(:millisecond) - started >= 400
    end

    refute_receive {:ex_webrtc, ^browser,
                    {:rtcp, [{^camera, %ExRTCP.Packet.PayloadFeedback.PLI{}}]}},
                   550

    DiscordClone.Voice.Forwarder.receive_unready(
      forwarder,
      destination_id,
      second.session,
      :video
    )

    report_connection(second, :connected)
    assert_camera_pli(first, camera)
    monitors = monitor_resources([first.session, second.session])
    started = System.monotonic_time(:millisecond)
    assert {:ok, %{state: :terminal}} = Calls.leave_call(pair.caller, pair.call_id)
    assert_retired(monitors, started)

    refute_receive {:ex_webrtc, ^browser,
                    {:rtcp, [{^camera, %ExRTCP.Packet.PayloadFeedback.PLI{}}]}},
                   600
  end

  @tag :controlled_camera
  @tag :ticket09_proactive
  test "rapid video rebuild shares decoder cooldown and cancels retired route work" do
    pair = start_pair("rebuild_pli", :video)
    assert {:ok, _} = Calls.accept_call(pair.recipient, pair.call_id, :video)
    [first, second] = Enum.map(await_sessions(pair.call_id), &connect_call_peer/1)
    camera = attach_call_camera(first, pair)
    assert_call_video(second, <<0x10, 0, 1>>)
    reverse = attach_call_camera(second, pair)
    assert_call_video(first, <<0x10, 0, 1>>)
    assert_camera_pli(first, camera)
    assert_camera_pli(second, reverse)
    assert_camera_pli(first, camera)
    assert_camera_pli(second, reverse)
    forwarder = call_forwarder(pair)
    assert {:ok, credentials} = DirectCallSession.media_credentials(first.session)
    id = credentials.call_session_id
    assert {:ok, destination_credentials} = DirectCallSession.media_credentials(second.session)
    destination_id = destination_credentials.call_session_id
    [_audio, source_video] = PeerConnection.get_transceivers(first.server)
    track = source_video.receiver.track.id
    browser = first.browser

    # Repeated unchanged readiness is not a new route and schedules no work.
    for _ <- 1..20, do: report_connection(second, :connected)
    DiscordClone.Voice.Forwarder.sync(forwarder)

    refute_receive {:ex_webrtc, ^browser,
                    {:rtcp, [{^camera, %ExRTCP.Packet.PayloadFeedback.PLI{}}]}},
                   550

    # Multiple ready edges held at the source share decoder pacing at emission.
    :ok = :sys.suspend(first.session)

    try do
      for _ <- 1..3 do
        DiscordClone.Voice.Forwarder.receive_unready(
          forwarder,
          destination_id,
          second.session,
          :video
        )

        report_connection(second, :connected)
      end

      queue_decoder_pli(second, pair)
    after
      :ok = :sys.resume(first.session)
    end

    assert_camera_pli(first, camera)
    started = System.monotonic_time(:millisecond)

    refute_receive {:ex_webrtc, ^browser,
                    {:rtcp, [{^camera, %ExRTCP.Packet.PayloadFeedback.PLI{}}]}},
                   400

    assert_camera_pli(first, camera)
    assert System.monotonic_time(:millisecond) - started >= 400

    # The current retained-camera route gets only three further opportunities,
    # sharing this decoder cooldown rather than creating another timer.
    assert_camera_pli(first, camera)
    assert_camera_pli(first, camera)
    assert_camera_pli(first, camera)

    refute_receive {:ex_webrtc, ^browser,
                    {:rtcp, [{^camera, %ExRTCP.Packet.PayloadFeedback.PLI{}}]}},
                   550

    # Removing a route cancels its pending request, even after immediate rebuild.
    queue_decoder_pli(second, pair)
    assert_camera_pli(first, camera)
    DiscordClone.Voice.Forwarder.source_ended(forwarder, id, first.session, :video, track)
    report_connection(first, :connected)
    DiscordClone.Voice.Forwarder.source_ended(forwarder, id, first.session, :video, track)
    DiscordClone.Voice.Forwarder.sync(forwarder)
    _ = :sys.get_state(first.session)

    refute_receive {:ex_webrtc, ^browser,
                    {:rtcp, [{^camera, %ExRTCP.Packet.PayloadFeedback.PLI{}}]}},
                   600

    assert :ok =
             PeerConnection.send_rtp(
               second.browser,
               reverse,
               ExRTP.Packet.new(<<0x10, 0, 2>>,
                 sequence_number: 2,
                 timestamp: 93_750,
                 marker: true
               )
             )

    assert_call_video(first, <<0x10, 0, 2>>)
    send_audio(first, <<0xF8, 0xFF, 0xFE>>, 10, 960)
    send_audio(second, <<0xF9, 0xFF, 0xFE>>, 20, 1_920)
    assert_call_audio(second, <<0xF8, 0xFF, 0xFE>>)
    assert_call_audio(first, <<0xF9, 0xFF, 0xFE>>)

    report_connection(first, :connected)
    assert_camera_pli(first, camera)
    queue_decoder_pli(second, pair)
    monitors = monitor_resources([first.session, second.session])
    started = System.monotonic_time(:millisecond)
    assert {:ok, %{state: :terminal}} = Calls.leave_call(pair.caller, pair.call_id)
    assert_retired(monitors, started)

    refute_receive {:ex_webrtc, ^browser,
                    {:rtcp, [{^camera, %ExRTCP.Packet.PayloadFeedback.PLI{}}]}},
                   600
  end

  @tag :controlled_camera
  @tag :ticket08_feedback
  test "decoder PLI reaches only the opposite real camera and bursts coalesce" do
    pair = start_pair("mapped_pli", :video)
    assert {:ok, _} = Calls.accept_call(pair.recipient, pair.call_id, :video)
    [first, second] = Enum.map(await_sessions(pair.call_id), &connect_call_peer/1)
    first_camera = attach_call_camera(first, pair)
    assert_call_video(second, <<0x10, 0, 1>>)
    second_camera = attach_call_camera(second, pair)
    assert_call_video(first, <<0x10, 0, 1>>)
    assert_camera_pli(first, first_camera)
    assert_camera_pli(second, second_camera)
    assert_camera_pli(first, first_camera)
    assert_camera_pli(second, second_camera)

    for {source, camera, destination} <- [
          {first, first_camera, second},
          {second, second_camera, first}
        ] do
      [_audio, video] = PeerConnection.get_transceivers(destination.browser)
      browser = source.browser
      assert :ok = PeerConnection.send_pli(destination.browser, video.receiver.track.id)

      assert_receive {:ex_webrtc, ^browser,
                      {:rtcp, [{^camera, %ExRTCP.Packet.PayloadFeedback.PLI{}}]}},
                     2_000

      started = System.monotonic_time(:millisecond)

      for _ <- 1..20 do
        assert :ok = PeerConnection.send_pli(destination.browser, video.receiver.track.id)
      end

      refute_receive {:ex_webrtc, ^browser,
                      {:rtcp, [{^camera, %ExRTCP.Packet.PayloadFeedback.PLI{}}]}},
                     400

      assert_receive {:ex_webrtc, ^browser,
                      {:rtcp, [{^camera, %ExRTCP.Packet.PayloadFeedback.PLI{}}]}},
                     1_000

      assert System.monotonic_time(:millisecond) - started >= 400

      refute_receive {:ex_webrtc, ^browser,
                      {:rtcp, [{^camera, %ExRTCP.Packet.PayloadFeedback.PLI{}}]}},
                     550

      # Hold the real source consumer: spacing must govern actual PC requests,
      # not merely when the Forwarder queued them for a busy Session.
      :ok = :sys.suspend(source.session)

      try do
        queue_decoder_pli(destination, pair)

        refute_receive {:ex_webrtc, ^browser,
                        {:rtcp, [{^camera, %ExRTCP.Packet.PayloadFeedback.PLI{}}]}},
                       600

        queue_decoder_pli(destination, pair)
      after
        :ok = :sys.resume(source.session)
      end

      assert_receive {:ex_webrtc, ^browser,
                      {:rtcp, [{^camera, %ExRTCP.Packet.PayloadFeedback.PLI{}}]}},
                     1_000

      refute_receive {:ex_webrtc, ^browser,
                      {:rtcp, [{^camera, %ExRTCP.Packet.PayloadFeedback.PLI{}}]}},
                     400

      assert_receive {:ex_webrtc, ^browser,
                      {:rtcp, [{^camera, %ExRTCP.Packet.PayloadFeedback.PLI{}}]}},
                     1_000
    end

    send_audio(first, <<0xF8, 0xFF, 0xFE>>, 10, 960)
    send_audio(second, <<0xF9, 0xFF, 0xFE>>, 20, 1_920)
    assert_call_audio(second, <<0xF8, 0xFF, 0xFE>>)
    assert_call_audio(first, <<0xF9, 0xFF, 0xFE>>)
    assert {:ok, %{state: :terminal}} = Calls.leave_call(pair.caller, pair.call_id)
  end

  for interruption <- [:camera_off, :source_ended] do
    @tag :controlled_camera
    @camera_interruption interruption
    @tag :ticket08_feedback
    test "two real cameras route opposite feeds while #{@camera_interruption} preserves reverse video and Opus" do
      pair = start_pair("two_#{@camera_interruption}", :video)
      assert {:ok, _} = Calls.accept_call(pair.recipient, pair.call_id, :video)
      [first, second] = Enum.map(await_sessions(pair.call_id), &connect_call_peer/1)
      first_camera = attach_call_camera(first, pair)
      assert_call_video(second, <<0x10, 0, 1>>)
      second_camera = attach_call_camera(second, pair)
      assert_call_video(first, <<0x10, 0, 1>>)
      assert_camera_pli(first, first_camera)
      assert_camera_pli(second, second_camera)

      for {source, camera, destination, payload} <- [
            {first, first_camera, second, <<0x10, 0, 2>>},
            {second, second_camera, first, <<0x10, 0, 3>>}
          ] do
        assert :ok =
                 PeerConnection.send_rtp(
                   source.browser,
                   camera,
                   ExRTP.Packet.new(payload, sequence_number: 2, timestamp: 93_750, marker: true)
                 )

        assert_call_video(destination, payload)
      end

      [_audio, destination_video] = PeerConnection.get_transceivers(second.browser)
      first_browser = first.browser
      :ok = PeerConnection.send_pli(second.browser, destination_video.receiver.track.id)

      assert_receive {:ex_webrtc, ^first_browser,
                      {:rtcp, [{^first_camera, %ExRTCP.Packet.PayloadFeedback.PLI{}}]}},
                     2_000

      queue_decoder_pli(second, pair)
      _ = :sys.get_state(first.session)

      case @camera_interruption do
        :camera_off ->
          signaling_id = Ecto.UUID.generate()

          assert {:ok, credentials} =
                   DirectCallSession.media_credentials(first.session, signaling_id)

          assert {:ok, %{camera_enabled: false}} =
                   DirectCallSession.local_media_state(first.session, %{
                     "call_id" => pair.call_id,
                     "call_session_id" => credentials.call_session_id,
                     "signaling_session_id" => signaling_id,
                     "negotiation_id" => "audio",
                     "media_state_version" => 2,
                     "microphone_muted" => false,
                     "camera_enabled" => false
                   })

        :source_ended ->
          [_audio, video] = PeerConnection.get_transceivers(first.server)
          send(first.session, {:ex_webrtc, first.server, {:track_ended, video.receiver.track.id}})
          _ = :sys.get_state(first.session)
      end

      refute_receive {:ex_webrtc, ^first_browser,
                      {:rtcp, [{^first_camera, %ExRTCP.Packet.PayloadFeedback.PLI{}}]}},
                     600

      assert :ok =
               PeerConnection.send_rtp(
                 first.browser,
                 first_camera,
                 ExRTP.Packet.new(<<0x10, 0, 4>>,
                   sequence_number: 3,
                   timestamp: 97_500,
                   marker: true
                 )
               )

      assert :ok =
               PeerConnection.send_rtp(
                 second.browser,
                 second_camera,
                 ExRTP.Packet.new(<<0x10, 0, 5>>,
                   sequence_number: 3,
                   timestamp: 97_500,
                   marker: true
                 )
               )

      assert_call_video(first, <<0x10, 0, 5>>)
      send_audio(first, <<0xF8, 0xFF, 0xFE>>, 10, 960)
      send_audio(second, <<0xF9, 0xFF, 0xFE>>, 50, 4_800)
      assert_call_audio(second, <<0xF8, 0xFF, 0xFE>>)
      assert_call_audio(first, <<0xF9, 0xFF, 0xFE>>)
      refute_receive {:ex_webrtc, _, {:rtp, _, _, _}}, 100

      assert {:ok, %{state: :active, media_intent: :video, answer_mode: :video}} =
               Calls.get_call(pair.caller, pair.call_id)

      assert AdmissionCoordinator.effective_occupancy() == 2
      assert {:ok, %{state: :terminal}} = Calls.leave_call(pair.caller, pair.call_id)
    end
  end

  for interruption <- [:camera_off, :source_ended] do
    @return_interruption interruption
    @tag :ticket18_presentation
    @tag :ticket08_feedback
    @tag :ticket09_proactive
    @tag :controlled_camera
    test "fresh camera after #{@return_interruption} continues real destination RTP on the retained receiver" do
      pair = start_pair("return_#{@return_interruption}", :video)
      assert {:ok, _} = Calls.accept_call(pair.recipient, pair.call_id, :audio)
      [first, second] = Enum.map(await_sessions(pair.call_id), &connect_call_peer/1)
      assert {:ok, _} = DirectCallSession.media_credentials(second.session, Ecto.UUID.generate())
      old_camera = attach_call_camera(first, pair)
      [_audio, destination] = PeerConnection.get_transceivers(second.browser)
      receiver = destination.receiver.track.id
      browser = second.browser
      assert_receive {:ex_webrtc, ^browser, {:rtp, ^receiver, nil, before}}, 2_000
      destination_session = :sys.get_state(second.session).session_id
      timestamp = before.timestamp

      assert_receive {:call_media_event, ^destination_session, _, "audio",
                      %{
                        video_presentation: %{
                          epoch: initial_epoch,
                          camera_version: 1,
                          rtp_timestamp: ^timestamp
                        }
                      }},
                     2_000

      assert before.sequence_number == 1
      flush_readiness(pair)
      assert_camera_pli(first, old_camera)

      source_browser = first.browser
      :ok = PeerConnection.send_pli(second.browser, receiver)

      assert_receive {:ex_webrtc, ^source_browser,
                      {:rtcp, [{^old_camera, %ExRTCP.Packet.PayloadFeedback.PLI{}}]}},
                     2_000

      queue_decoder_pli(second, pair)
      _ = :sys.get_state(first.session)

      signaling_id = Ecto.UUID.generate()
      assert {:ok, credentials} = DirectCallSession.media_credentials(first.session, signaling_id)

      off = %{
        "call_id" => pair.call_id,
        "call_session_id" => credentials.call_session_id,
        "signaling_session_id" => signaling_id,
        "negotiation_id" => "audio",
        "media_state_version" => 2,
        "microphone_muted" => false,
        "camera_enabled" => false
      }

      case @return_interruption do
        :camera_off ->
          assert {:ok, %{camera_enabled: false}} =
                   DirectCallSession.local_media_state(first.session, off)

        :source_ended ->
          [_audio, video] = PeerConnection.get_transceivers(first.server)
          send(first.session, {:ex_webrtc, first.server, {:track_ended, video.receiver.track.id}})
          _ = :sys.get_state(first.session)
      end

      assert_receive {:call_media_event, ^destination_session, _, "audio",
                      %{
                        video_presentation: %{
                          epoch: retired_epoch,
                          camera_version: nil,
                          rtp_timestamp: nil
                        }
                      }},
                     2_000

      assert retired_epoch > initial_epoch
      # A queued packet after retirement cannot establish return readiness.
      [_audio, retired_source] = PeerConnection.get_transceivers(first.server)

      send(
        first.session,
        {:ex_webrtc, first.server,
         {:rtp, retired_source.receiver.track.id, nil,
          ExRTP.Packet.new(<<0x10, 0, 2>>, sequence_number: 2, timestamp: 93_750, marker: true)}}
      )

      _ = :sys.get_state(first.session)

      assert :ok =
               PeerConnection.send_rtp(
                 first.browser,
                 old_camera,
                 ExRTP.Packet.new(<<0x10, 0, 2>>,
                   sequence_number: 2,
                   timestamp: 93_750,
                   marker: true
                 )
               )

      send_audio(first, <<0xF8, 0xFF, 0xFE>>, 10, 960)
      assert_call_audio(second, <<0xF8, 0xFF, 0xFE>>)
      refute_receive {:ex_webrtc, ^browser, {:rtp, ^receiver, nil, _}}, 100

      [_audio, source] = PeerConnection.get_transceivers(first.browser)
      fresh = MediaStreamTrack.new(:video)
      assert :ok = PeerConnection.replace_track(first.browser, source.sender.id, fresh)

      assert {:ok, %{camera_enabled: true}} =
               DirectCallSession.local_media_state(
                 first.session,
                 %{off | "camera_enabled" => true, "media_state_version" => 3}
               )

      DiscordClone.Voice.Forwarder.sync(call_forwarder(pair))
      _ = :sys.get_state(first.session)

      refute_receive {:ex_webrtc, ^source_browser,
                      {:rtcp, [{_, %ExRTCP.Packet.PayloadFeedback.PLI{}}]}},
                     550

      assert :ok =
               PeerConnection.send_rtp(
                 first.browser,
                 fresh.id,
                 ExRTP.Packet.new(<<0x10, 0, 3>>,
                   sequence_number: 500,
                   timestamp: 900_000,
                   marker: true
                 )
               )

      assert_receive {:ex_webrtc, ^browser, {:rtp, ^receiver, nil, returned}}, 2_000
      timestamp = returned.timestamp

      assert_receive {:call_media_event, ^destination_session, _, "audio",
                      %{
                        video_presentation: %{
                          epoch: returned_epoch,
                          camera_version: version,
                          rtp_timestamp: ^timestamp
                        }
                      }},
                     2_000

      assert returned_epoch > retired_epoch
      assert version in [1, 3]
      assert timestamp == returned.timestamp
      assert returned.sequence_number == 2
      assert returned.timestamp > before.timestamp
      refute returned.timestamp == 900_000
      assert returned.payload == <<0x10, 0, 3>>
      assert returned.ssrc == before.ssrc
      assert returned.payload_type == before.payload_type

      forwarder = call_forwarder(pair)
      source = :sys.get_state(first.session)

      DiscordClone.Voice.Forwarder.source_ended(
        forwarder,
        source.session_id,
        first.session,
        :video,
        source.connection.video.inbound_track_id
      )

      DiscordClone.Voice.Forwarder.sync(forwarder)

      DiscordClone.Voice.Forwarder.send_ready(
        forwarder,
        source.session_id,
        first.session,
        :video,
        source.connection.video.inbound_track_id,
        :vp8,
        source.camera_source_ref,
        source.camera_version
      )

      DiscordClone.Voice.Forwarder.sync(forwarder)

      assert :ok =
               PeerConnection.send_rtp(
                 first.browser,
                 fresh.id,
                 ExRTP.Packet.new(<<0x10, 0, 4>>,
                   sequence_number: 501,
                   timestamp: 903_750,
                   marker: true
                 )
               )

      assert_receive {:ex_webrtc, ^browser, {:rtp, ^receiver, nil, rebuilt}}, 2_000
      timestamp = rebuilt.timestamp

      assert_receive {:call_media_event, ^destination_session, _, "audio",
                      %{video_presentation: %{epoch: rebuilt_epoch, rtp_timestamp: ^timestamp}}},
                     2_000

      assert rebuilt_epoch > returned_epoch
      assert timestamp == rebuilt.timestamp
      assert timestamp > returned.timestamp

      # Return must proactively request the fresh camera without decoder PLI.
      assert_camera_pli(first, fresh.id)

      refute_receive {:ex_webrtc, ^source_browser,
                      {:rtcp, [{^old_camera, %ExRTCP.Packet.PayloadFeedback.PLI{}}]}},
                     600

      :ok = PeerConnection.send_pli(second.browser, receiver)
      fresh_id = fresh.id

      assert_receive {:ex_webrtc, ^source_browser,
                      {:rtcp, [{^fresh_id, %ExRTCP.Packet.PayloadFeedback.PLI{}}]}},
                     2_000

      refute_receive {:ex_webrtc, ^source_browser,
                      {:rtcp, [{^old_camera, %ExRTCP.Packet.PayloadFeedback.PLI{}}]}},
                     0

      assert [_audio, %{receiver: %{track: %{id: ^receiver}}}] =
               PeerConnection.get_transceivers(second.browser)

      send_audio(second, <<0xF9, 0xFF, 0xFE>>, 20, 1_920)
      assert_call_audio(first, <<0xF9, 0xFF, 0xFE>>)

      assert {:ok, %{state: :active, media_intent: :video, answer_mode: :audio}} =
               Calls.get_call(pair.caller, pair.call_id)

      assert AdmissionCoordinator.effective_occupancy() == 2
      assert {:ok, _} = Calls.leave_call(pair.caller, pair.call_id)
    end
  end

  @tag :controlled_camera
  test "camera off, source loss and video-only readiness failures preserve real Opus and unrelated Voice" do
    voice_channel = Ecto.UUID.generate()
    voice_source = connect_voice_peer(voice_channel)
    voice_destination = connect_voice_peer(voice_channel)
    pair = start_pair("kind_readiness", :video)
    assert {:ok, _} = Calls.accept_call(pair.recipient, pair.call_id, :audio)
    sessions = await_sessions(pair.call_id)
    [first, second] = Enum.map(sessions, &connect_call_peer/1)
    attach_call_camera(first, pair)
    flush_readiness(pair)
    %{runtime_generation: generation} = AdmissionCoordinator.call_target_snapshot(pair.call_id)

    forwarder =
      GenServer.whereis(
        Target.runtime_name(Target.direct_call(pair.call_id), generation, :forwarder)
      )

    signaling_id = Ecto.UUID.generate()
    assert {:ok, credentials} = DirectCallSession.media_credentials(first.session, signaling_id)

    off = %{
      "call_id" => pair.call_id,
      "call_session_id" => credentials.call_session_id,
      "signaling_session_id" => signaling_id,
      "negotiation_id" => "audio",
      "media_state_version" => 2,
      "microphone_muted" => false,
      "camera_enabled" => false
    }

    assert {:ok, %{camera_enabled: false, microphone_muted: false}} =
             DirectCallSession.local_media_state(first.session, off)

    assert {:error, :stale_media_state} = DirectCallSession.local_media_state(first.session, off)

    [audio, video] = PeerConnection.get_transceivers(first.server)

    for _ <- 1..2 do
      send(first.session, {:ex_webrtc, first.server, {:track_ended, video.receiver.track.id}})
      send(first.session, {:ex_webrtc, second.server, {:track_ended, audio.receiver.track.id}})

      DiscordClone.Voice.Forwarder.receive_unready(
        forwarder,
        credentials.call_session_id,
        first.session,
        :video
      )

      # The current track number cannot authorize a foreign Session process.
      DiscordClone.Voice.Forwarder.receive_unready(
        forwarder,
        credentials.call_session_id,
        second.session,
        :audio
      )
    end

    _ = :sys.get_state(first.session)
    DiscordClone.Voice.Forwarder.sync(forwarder)

    first_payload = <<0xF8, 0xFF, 0xFE>>
    second_payload = <<0xF9, 0xFF, 0xFE>>
    send_audio(first, first_payload, 10, 960)
    send_audio(second, second_payload, 20, 1_920)
    assert_call_audio(second, first_payload)
    assert_call_audio(first, second_payload)
    send_audio(voice_source, first_payload, 30, 2_880)
    assert_voice_audio(voice_destination, first_payload)
    assert {:ok, %{state: :active}} = Calls.get_call(pair.caller, pair.call_id)
    assert length(PeerConnection.get_transceivers(first.server)) == 2

    monitors = monitor_resources(sessions)
    started = System.monotonic_time(:millisecond)
    assert {:ok, %{state: :terminal}} = Calls.leave_call(pair.caller, pair.call_id)
    assert_retired(monitors, started)
    send_audio(voice_source, first_payload, 31, 3_840)
    assert_voice_audio(voice_destination, first_payload)
  end

  @tag :controlled_camera
  @tag :ticket31_diagnostics
  test "negotiated TWCC observes departure aggregates without adapting camera or leaking identities" do
    attach_video_diagnostics()
    pair = start_pair("twcc_diagnostics", :video)
    assert {:ok, _} = Calls.accept_call(pair.recipient, pair.call_id, :video)
    [first, second] = Enum.map(await_sessions(pair.call_id), &connect_call_peer/1)
    camera = attach_call_camera(first, pair)
    assert_call_video(second, <<0x10, 0, 1>>)
    attach_call_camera(second, pair)
    assert_call_video(first, <<0x10, 0, 1>>)

    assert_receive {:video_diagnostic,
                    %{
                      departure_packets: packets,
                      departure_bytes: bytes,
                      matched_packets: matched,
                      reported_packets: reported
                    } = counts,
                    %{operation: :twcc, outcome: :sampled, route_category: category} = metadata},
                   2_000

    assert category in [:host_direct, :unknown]
    assert packets > 0 and bytes > 0 and matched > 0 and reported >= matched

    assert Map.keys(counts) |> Enum.sort() ==
             Enum.sort([
               :departure_packets,
               :departure_bytes,
               :departure_span_ms,
               :matched_packets,
               :reported_packets,
               :mailbox_len,
               :received_packets,
               :lost_packets
             ])

    refute inspect({counts, metadata}) =~ pair.call_id
    refute inspect({counts, metadata}) =~ inspect(second.server)

    for sequence <- 2..20 do
      send_video(first, camera, <<0x10, 0, 77>>, sequence, 90_000 + sequence * 3_750)
    end

    assert_call_video(second, <<0x10, 0, 77>>)
    send_audio(first, <<0xF8, 0xFF, 0xFE>>, 1, 960)
    assert_call_audio(second, <<0xF8, 0xFF, 0xFE>>)
    send_audio(second, <<0xF9, 0xFF, 0xFE>>, 1, 960)
    assert_call_audio(first, <<0xF9, 0xFF, 0xFE>>)
    assert_receive {:video_diagnostic, _, %{operation: :twcc, outcome: :sampled}}, 2_000
    refute_receive {:video_diagnostic, _, %{operation: :twcc}}, 150
    # Replay a native, negotiated feedback notification while its peer API is
    # held. Optional observation must abandon its alias at the deadline.
    first_browser = first.browser

    assert_receive {:ex_webrtc, ^first_browser,
                    {:rtcp, [{nil, %ExRTCP.Packet.TransportFeedback.CC{} = feedback}]}},
                   2_000

    :sys.replace_state(second.session, fn state ->
      %{state | twcc_last_at: System.monotonic_time(:millisecond) - 10_000}
    end)

    before_monitors = Process.info(second.session, :monitors)
    :sys.suspend(second.server)

    try do
      send(second.session, {:ex_webrtc, second.server, {:rtcp, [{nil, feedback}]}})
      _ = :sys.get_state(second.session)

      assert_receive {:video_diagnostic, %{mailbox_len: _},
                      %{operation: :twcc, outcome: :unavailable}},
                     1_500

      _ = :sys.get_state(second.session)
      assert Process.info(second.session, :monitors) == before_monitors
    after
      safely_resume(second.server)
    end

    send_audio(first, <<0xF8, 0xFF, 0xFE>>, 2, 1_920)
    assert_call_audio(second, <<0xF8, 0xFF, 0xFE>>)
    assert {:ok, %{state: :active}} = Calls.get_call(pair.caller, pair.call_id)
    assert {:ok, _} = Calls.leave_call(pair.caller, pair.call_id)
  end

  defp attach_video_diagnostics do
    handler = make_ref()
    parent = self()

    :ok =
      :telemetry.attach(
        handler,
        [:discord_clone, :call_media, :video],
        fn _, m, d, _ -> send(parent, {:video_diagnostic, m, d}) end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  @tag :controlled_camera
  test "real Call diagnostics report connection transitions without packet events or private identities with camera present" do
    event = [:discord_clone, :call_media, :connection_state]
    handler = make_ref()
    parent = self()

    :ok =
      :telemetry.attach(
        handler,
        event,
        fn _, measurements, metadata, _ ->
          send(parent, {:call_diagnostic, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    pair = start_pair("safe_diagnostics", :video)
    assert {:ok, _} = Calls.accept_call(pair.recipient, pair.call_id, :video)
    [first, second] = Enum.map(await_sessions(pair.call_id), &connect_call_peer/1)
    Enum.each([first, second], &attach_call_camera(&1, pair))
    flush_readiness(pair)

    for _ <- 1..2 do
      assert_receive {:call_diagnostic, %{}, %{connection_state: :connecting}}
      assert_receive {:call_diagnostic, %{}, %{connection_state: :connected}}
    end

    # A duplicate readiness report is not a new lifecycle transition.
    report_connection(first, :connected)
    payload = "raw-media-sentinel-private-message-turn-credential"
    send_audio(first, payload, 10, 960)
    assert_call_audio(second, payload)
    refute_receive {:call_diagnostic, _, _}, 0

    report_connection(first, :disconnected)

    assert_receive {:call_diagnostic, %{}, metadata}
    assert metadata == %{connection_state: :disconnected}
    refute inspect(metadata) =~ pair.call_id
    refute inspect(metadata) =~ pair.caller.user.id
    refute inspect(metadata) =~ inspect(first.session)
    refute inspect(metadata) =~ payload

    report_connection(first, :connected)
    assert_receive {:call_diagnostic, %{}, %{connection_state: :connected}}
    hold_terminal_cleanup()
    send(first.session, {:ex_webrtc, first.server, {:connection_state_change, :failed}})
    assert_receive {:terminal_cleanup_started, cleanup_worker}, 1_000

    try do
      assert_receive {:call_diagnostic, %{}, %{connection_state: :failed}}
    after
      send(cleanup_worker, :release_cleanup)
    end

    assert_receive {:call_failed, _}, 2_000
    assert_no_call_history(pair)
  end

  test "encoded Call packets bypass suspended admission and Call lifecycle mailboxes" do
    pair = start_pair("packet_path_audit")
    assert {:ok, _} = Calls.accept_call(pair.recipient, pair.call_id, :audio)
    [first, second] = Enum.map(await_sessions(pair.call_id), &connect_call_peer/1)
    flush_readiness(pair)
    assert {:ok, %{state: :active}} = Calls.get_call(pair.caller, pair.call_id)
    [{server, _}] = Registry.lookup(DiscordClone.Calls.CallRegistry, pair.call_id)
    %{runtime_generation: generation} = AdmissionCoordinator.call_target_snapshot(pair.call_id)

    forwarder =
      GenServer.whereis(
        Target.runtime_name(Target.direct_call(pair.call_id), generation, :forwarder)
      )

    controls = [
      Process.whereis(DiscordClone.Voice.SessionCoordinator),
      Process.whereis(DiscordClone.Calls.CallCoordinator),
      server
    ]

    Enum.each(controls, &:sys.suspend/1)

    try do
      before = Enum.map(controls, &DiscordClone.Media.Diagnostics.queue_snapshot/1)
      payloads = [<<0xF8, 0xFF, 0xFE>>, <<0xF9, 0xFF, 0xFE, 0xFF, 0xFE>>]
      [first_payload, second_payload] = payloads
      send_audio(first, first_payload, 10, 960)
      send_audio(second, second_payload, 50, 4_800)
      assert_call_audio(second, first_payload)
      assert_call_audio(first, second_payload)
      assert Enum.map(controls, &DiscordClone.Media.Diagnostics.queue_snapshot/1) == before

      # Sample just the exact live application media processes, once each.
      for process <- [first.session, second.session, first.server, second.server, forwarder] do
        assert %{status: :available, mailbox_len: count} =
                 DiscordClone.Media.Diagnostics.queue_snapshot(process)

        assert is_integer(count) and count >= 0
      end
    after
      Enum.each(controls, &:sys.resume/1)
    end

    assert {:ok, %{terminal_outcome: :ended}} = Calls.leave_call(pair.caller, pair.call_id)
  end

  test "a held terminal diagnostic cannot postpone starting the shared cleanup clock" do
    pair = start_pair("held_diag")
    assert {:ok, _} = Calls.accept_call(pair.recipient, pair.call_id, :audio)
    [first, _second] = Enum.map(await_sessions(pair.call_id), &connect_call_peer/1)
    flush_readiness(pair)
    parent = self()
    handler = make_ref()

    hold_terminal_cleanup()

    :ok =
      :telemetry.attach(
        handler,
        [:discord_clone, :call_media, :connection_state],
        fn
          _, _, %{connection_state: :failed}, _ ->
            send(parent, :diagnostic_held)
            await_test_release(parent, :release_diagnostic)

          _, _, _, _ ->
            :ok
        end,
        nil
      )

    on_exit(fn ->
      :telemetry.detach(handler)
      send(first.session, :release_diagnostic)
    end)

    send(first.session, {:ex_webrtc, first.server, {:connection_state_change, :failed}})
    assert_receive {:terminal_cleanup_started, cleanup_worker}, 1_000

    try do
      assert_receive :diagnostic_held
    after
      send(first.session, :release_diagnostic)
      send(cleanup_worker, :release_cleanup)
    end

    assert_receive {:call_failed, _}, 2_000
    assert_no_call_history(pair)
  end

  @tag :controlled_camera
  @tag :ticket30_lifecycle
  test "active disconnection recovers without ICE restart and ignores the old grace callback with camera present" do
    pair = start_pair("real_grace_recovery", :video)
    assert {:ok, _} = Calls.accept_call(pair.recipient, pair.call_id, :video)
    [first, second] = Enum.map(await_sessions(pair.call_id), &connect_call_peer/1)
    cameras = Enum.map([first, second], &attach_call_camera(&1, pair))
    Enum.each([first, second], &assert_call_video(&1, <<0x10, 0, 1>>))
    flush_readiness(pair)
    assert {:ok, %{state: :active}} = Calls.get_call(pair.caller, pair.call_id)
    peers = MapSet.new(PeerConnection.get_all_running())

    report_connection(first, :disconnected)
    state = :sys.get_state(first.session)
    assert is_reference(state.disconnect_ref)
    remaining = Process.read_timer(state.disconnect_timer)
    assert remaining > 29_000 and remaining <= 30_000
    report_connection(first, :disconnected)
    assert :sys.get_state(first.session).disconnect_ref == state.disconnect_ref
    renew_call_peer(first)
    repair_camera_state(first, pair, 2, false)
    repair_camera_state(first, pair, 3, true)
    queue_decoder_pli(second, pair)
    renewed = :sys.get_state(first.session)
    assert renewed.disconnect_ref == state.disconnect_ref
    assert renewed.disconnect_deadline == state.disconnect_deadline
    report_connection(first, :connected)
    send(first.session, {:disconnect_expired, state.disconnect_ref})
    _ = :sys.get_state(first.session)
    flush_readiness(pair)
    assert {:ok, %{state: :active}} = Calls.get_call(pair.caller, pair.call_id)
    assert MapSet.new(PeerConnection.get_all_running()) == peers

    for {source, destination, camera} <- [
          {first, second, Enum.at(cameras, 0)},
          {second, first, Enum.at(cameras, 1)}
        ] do
      send_video(source, camera, <<0x10, 0, 31>>, 2, 97_500)
      assert_call_video(destination, <<0x10, 0, 31>>)
    end

    payload = <<0xF8, 0xFF, 0xFE>>
    send_audio(first, payload, 12, 1_920)
    assert_call_audio(second, payload)
    assert {:ok, _} = Calls.leave_call(pair.caller, pair.call_id)
    assert_no_call_history(pair)
  end

  for intent <- [:audio, :video], trigger <- [:lease, :disconnect_grace, :failed, :closed] do
    @intent intent
    @trigger trigger
    @tag controlled_camera: intent == :video
    @tag ticket30_lifecycle: intent == :video
    test "#{intent} #{trigger} ends both exact Call transports while unrelated Voice still carries packets" do
      voice_channel = Ecto.UUID.generate()
      [voice_first, voice_second] = Enum.map(1..2, fn _ -> connect_voice_peer(voice_channel) end)
      voice_identity = AdmissionCoordinator.current_identity(voice_first.scope.user.id)
      pair = start_pair("l_#{@trigger}", @intent)
      assert {:ok, _} = Calls.accept_call(pair.recipient, pair.call_id, @intent)
      sessions = await_sessions(pair.call_id)
      [first, second] = Enum.map(sessions, &connect_call_peer/1)

      if @intent == :video do
        Enum.each([first, second], &attach_call_camera(&1, pair))
        Enum.each([first, second], &assert_call_video(&1, <<0x10, 0, 1>>))
      end

      flush_readiness(pair)
      monitors = monitor_resources(sessions)
      payload = <<0xF8, 0xFF, 0xFE>>
      send_audio(first, payload, 10, 960)
      assert_call_audio(second, payload)

      # Only the currently owned peer can change this Session's readiness.
      send(first.session, {:ex_webrtc, second.server, {:connection_state_change, :failed}})
      _ = :sys.get_state(first.session)
      assert {:ok, %{state: :active}} = Calls.get_call(pair.caller, pair.call_id)

      if @trigger == :disconnect_grace, do: report_connection(first, :disconnected)
      state = :sys.get_state(first.session)
      remaining = Process.read_timer(state.lease_timer)
      assert remaining > 115_000 and remaining <= 120_000

      if @trigger == :disconnect_grace do
        grace_remaining = Process.read_timer(state.disconnect_timer)
        assert grace_remaining > 29_000 and grace_remaining <= 30_000
      end

      # Deliver the original expiry after renewal: scoped terminal/resource
      # outcomes prove renewal cannot replace or extend this grace.
      if @trigger == :disconnect_grace, do: renew_call_peer(first)
      started = System.monotonic_time(:millisecond)

      case @trigger do
        :lease ->
          send(first.session, {:lease_expired, state.lease_ref})

        :disconnect_grace ->
          send(first.session, {:disconnect_expired, state.disconnect_ref})

        status ->
          send(first.session, {:ex_webrtc, first.server, {:connection_state_change, status}})
      end

      assert_receive {:call_failed, %{call_id: call_id}}, 2_000
      assert call_id == pair.call_id
      assert_retired(monitors, started)

      assert {:ok, %{state: :terminal, terminal_outcome: :failed}} =
               Calls.get_call(pair.caller, pair.call_id)

      assert AdmissionCoordinator.effective_occupancy() == 2
      assert AdmissionCoordinator.current_identity(pair.caller.user.id) == nil
      assert AdmissionCoordinator.current_identity(pair.recipient.user.id) == nil
      assert AdmissionCoordinator.current_identity(voice_first.scope.user.id) == voice_identity
      send_audio(voice_first, payload, 20, 1_920)
      assert_voice_audio(voice_second, payload)
      send_audio(voice_second, payload, 30, 2_880)
      assert_voice_audio(voice_first, payload)
      assert_no_call_history(pair)
    end
  end

  test "recovery clears only its grace and an expired second grace cannot resurrect active" do
    pair = start_pair("real_second_grace")
    assert {:ok, _} = Calls.accept_call(pair.recipient, pair.call_id, :audio)
    sessions = await_sessions(pair.call_id)
    [first, _second] = Enum.map(sessions, &connect_call_peer/1)
    flush_readiness(pair)
    report_connection(first, :disconnected)
    old = :sys.get_state(first.session).disconnect_ref
    report_connection(first, :connected)
    report_connection(first, :disconnected)
    current = :sys.get_state(first.session).disconnect_ref
    refute old == current
    send(first.session, {:disconnect_expired, old})
    _ = :sys.get_state(first.session)
    assert {:ok, %{state: :active}} = Calls.get_call(pair.caller, pair.call_id)

    monitors = monitor_resources(sessions)

    :sys.replace_state(first.session, fn state ->
      %{state | disconnect_deadline: System.monotonic_time(:millisecond) - 1}
    end)

    started = System.monotonic_time(:millisecond)
    send(first.session, {:ex_webrtc, first.server, {:connection_state_change, :connected}})
    assert_receive {:call_failed, %{call_id: call_id}}, 2_000
    assert call_id == pair.call_id
    assert_retired(monitors, started)
    assert_no_call_history(pair)
  end

  test "lease expiry starts the shared cleanup budget even when forwarding is stalled" do
    pair = start_pair("expiry_stalled_route")
    assert {:ok, _} = Calls.accept_call(pair.recipient, pair.call_id, :audio)
    sessions = await_sessions(pair.call_id)
    [first, _] = sessions
    state = :sys.get_state(first)
    monitors = monitor_resources(sessions)
    parent = self()

    Application.put_env(:discord_clone, :call_target_startup_control, %{
      barrier: fn
        :cleanup_starting, _ ->
          send(parent, :terminal_cleanup_started)
          :ok

        _, _ ->
          :ok
      end
    })

    :ok = :sys.suspend(state.forwarder)
    on_exit(fn -> safely_resume(state.forwarder) end)
    started = System.monotonic_time(:millisecond)
    send(first, {:lease_expired, state.lease_ref})
    assert_receive :terminal_cleanup_started, 1_000
    assert_retired(monitors, started)
    assert_receive {:call_failed, _}, 2_000
    assert :ok = AdmissionCoordinator.cleanup_active_pair_for_call(pair.call_id)
    assert AdmissionCoordinator.effective_occupancy() == 0
  end

  @tag :controlled_camera
  @tag :ticket30_lifecycle
  test "withdrawn readiness expires both sides on the original pair deadline with camera present" do
    Application.put_env(:discord_clone, :pair_operation_timeouts, %{connect_ms: 1_500})
    on_exit(fn -> Application.delete_env(:discord_clone, :pair_operation_timeouts) end)
    pair = start_pair("real_connect_deadline", :video)
    assert {:ok, _} = Calls.accept_call(pair.recipient, pair.call_id, :video)
    [first_session, second_session] = await_sessions(pair.call_id)
    resources = monitor_resources([first_session, second_session])
    original = :sys.get_state(DiscordClone.Voice.SessionCoordinator).active_call.connect_deadline
    first = connect_call_peer(first_session)
    attach_call_camera(first, pair)
    report_connection(first, :disconnected)
    renew_call_peer(first)
    _second = connect_call_peer(second_session)
    flush_readiness(pair)

    assert :sys.get_state(DiscordClone.Voice.SessionCoordinator).active_call.connect_deadline ==
             original

    assert {:ok, %{state: :connecting}} = Calls.get_call(pair.caller, pair.call_id)
    assert_receive {:call_failed, %{terminal_outcome: :failed}}, 2_000
    assert_retired(resources, original)

    assert {:ok, %{state: :terminal, terminal_outcome: :failed}} =
             Calls.get_call(pair.caller, pair.call_id)

    assert AdmissionCoordinator.effective_occupancy() == 0
    refute_receive {:call_active, _}, 0
    assert_no_call_history(pair)
  end

  test "activation rechecks withdrawn readiness after obtaining the durable row lock" do
    pair = start_pair("real_locked_ready")
    assert {:ok, _} = Calls.accept_call(pair.recipient, pair.call_id, :audio)
    [first_session, second_session] = await_sessions(pair.call_id)
    first = connect_call_peer(first_session)
    flush_readiness(pair)
    [{server, _}] = Registry.lookup(DiscordClone.Calls.CallRegistry, pair.call_id)
    barrier = make_ref()

    :ok =
      :telemetry.attach(
        barrier,
        [:discord_clone, :repo, :query],
        &__MODULE__.hold_activation_lock/4,
        %{server: server, parent: self(), query_part: "FOR UPDATE"}
      )

    on_exit(fn ->
      :telemetry.detach(barrier)
      send(server, :resume_activation)
    end)

    _ = connect_call_peer(second_session)
    assert_receive :activation_locked, 2_000
    report_connection(first, :disconnected)
    %{runtime_generation: generation} = AdmissionCoordinator.call_target_snapshot(pair.call_id)

    room =
      GenServer.whereis(Target.runtime_name(Target.direct_call(pair.call_id), generation, :room))

    _ = :sys.get_state(room)
    _ = :sys.get_state(DiscordClone.Voice.SessionCoordinator)
    :telemetry.detach(barrier)
    send(server, :resume_activation)
    flush_readiness(pair)
    assert {:ok, %{state: :connecting}} = Calls.get_call(pair.caller, pair.call_id)
    refute_receive {:call_active, _}, 0

    report_connection(first, :connected)
    flush_readiness(pair)
    assert {:ok, %{state: :active}} = Calls.get_call(pair.caller, pair.call_id)
    assert {:ok, _} = Calls.leave_call(pair.caller, pair.call_id)
    assert_no_call_history(pair)
  end

  @doc false
  def hold_activation_lock(_event, _measurements, %{query: query}, context) do
    if self() == context.server and String.contains?(query, context.query_part) do
      send(context.parent, :activation_locked)

      receive do
        :resume_activation -> :ok
      after
        5_000 -> raise "activation barrier was not released"
      end
    end
  end

  for change <- [:withdrawal, :expiry, :committed_withdrawal] do
    @change change
    test "#{change} at the durable activation boundary cannot project active" do
      if @change == :expiry do
        Application.put_env(:discord_clone, :pair_operation_timeouts, %{connect_ms: 1_500})
        on_exit(fn -> Application.delete_env(:discord_clone, :pair_operation_timeouts) end)
      end

      suffix = if @change == :committed_withdrawal, do: "update_commit", else: "update_#{@change}"
      pair = start_pair(suffix)
      assert {:ok, _} = Calls.accept_call(pair.recipient, pair.call_id, :audio)
      [first_session, second_session] = await_sessions(pair.call_id)
      resources = monitor_resources([first_session, second_session])
      first = connect_call_peer(first_session)
      flush_readiness(pair)
      [{server, _}] = Registry.lookup(DiscordClone.Calls.CallRegistry, pair.call_id)
      barrier = make_ref()

      :ok =
        :telemetry.attach(
          barrier,
          [:discord_clone, :repo, :query],
          &__MODULE__.hold_activation_lock/4,
          %{
            server: server,
            parent: self(),
            query_part:
              if(@change == :committed_withdrawal, do: "commit", else: "UPDATE \"call_attempts\"")
          }
        )

      on_exit(fn ->
        :telemetry.detach(barrier)
        send(server, :resume_activation)
      end)

      _ = connect_call_peer(second_session)
      assert_receive :activation_locked, 2_000

      case @change do
        change when change in [:withdrawal, :committed_withdrawal] ->
          report_connection(first, :disconnected)

          %{runtime_generation: generation} =
            AdmissionCoordinator.call_target_snapshot(pair.call_id)

          room =
            GenServer.whereis(
              Target.runtime_name(Target.direct_call(pair.call_id), generation, :room)
            )

          _ = :sys.get_state(room)
          _ = :sys.get_state(DiscordClone.Voice.SessionCoordinator)

        :expiry ->
          assert_retired(resources, System.monotonic_time(:millisecond))
      end

      :telemetry.detach(barrier)
      send(server, :resume_activation)

      case @change do
        :withdrawal ->
          flush_readiness(pair)
          assert {:ok, %{state: :connecting}} = Calls.get_call(pair.caller, pair.call_id)
          refute_receive {:call_active, _}, 0
          report_connection(first, :connected)
          flush_readiness(pair)
          assert {:ok, %{state: :active}} = Calls.get_call(pair.caller, pair.call_id)
          assert {:ok, _} = Calls.leave_call(pair.caller, pair.call_id)

        change when change in [:expiry, :committed_withdrawal] ->
          assert_receive {:call_failed, %{state: :terminal}}, 2_000

          if @change == :committed_withdrawal,
            do: assert_retired(resources, System.monotonic_time(:millisecond))

          assert {:ok, %{state: :terminal}} = Calls.get_call(pair.caller, pair.call_id)
          refute_receive {:call_active, _}, 0
          assert AdmissionCoordinator.effective_occupancy() == 0
      end

      assert_no_call_history(pair)
    end
  end

  test "foreign identities, old runtime reports and fake readiness cannot activate a real pair" do
    pair = start_pair("real_stale_ready")
    assert {:ok, _} = Calls.accept_call(pair.recipient, pair.call_id, :audio)
    [first_session, second_session] = await_sessions(pair.call_id)
    first = connect_call_peer(first_session)
    flush_readiness(pair)

    %{runtime_generation: generation, sessions: sessions} =
      AdmissionCoordinator.call_target_snapshot(pair.call_id)

    room =
      GenServer.whereis(Target.runtime_name(Target.direct_call(pair.call_id), generation, :room))

    [{server, _}] = Registry.lookup(DiscordClone.Calls.CallRegistry, pair.call_id)
    statuses = Map.new(sessions, fn {id, _} -> {id, :connected} end)

    # Session and room reports must retain exact PeerConnection/Session/runtime identity.
    send(first.session, {:ex_webrtc, self(), {:connection_state_change, :disconnected}})

    for {id, _} <- sessions do
      GenServer.cast(room, {:connection_state, id, self(), :connected})
    end

    GenServer.cast(room, {:connection_state, "retired-session", first.session, :connected})
    AdmissionCoordinator.call_transport_state(pair.call_id, generation, statuses)
    send(server, {:call_transport_state, pair.call_id, make_ref(), statuses})
    send(server, {:accepted_call_runtime, pair.call_id, :ready})
    flush_readiness(pair)
    assert {:ok, %{state: :connecting}} = Calls.get_call(pair.caller, pair.call_id)
    refute_receive {:call_active, _}, 0

    _ = connect_call_peer(second_session)
    flush_readiness(pair)
    assert_receive {:call_active, _}
    assert_receive {:call_active, _}
    timer_state = :sys.get_state(DiscordClone.Voice.SessionCoordinator).active_call
    assert timer_state.connect_timer == nil
    send(DiscordClone.Voice.SessionCoordinator, {:real_connect_expired, pair.call_id, generation})
    flush_readiness(pair)
    assert {:ok, %{state: :active}} = Calls.get_call(pair.caller, pair.call_id)
    refute_receive {:call_active, _}, 0
    assert {:ok, _} = Calls.leave_call(pair.caller, pair.call_id)
    assert_no_call_history(pair)
  end

  for status <- [:failed, :closed] do
    @status status
    test "second-side #{@status} ends the connecting pair without call history" do
      pair = start_pair("real_second_#{@status}")
      assert {:ok, _} = Calls.accept_call(pair.recipient, pair.call_id, :audio)
      [first_session, second_session] = await_sessions(pair.call_id)
      resources = monitor_resources([first_session, second_session])
      _ = connect_call_peer(first_session)

      [peer] =
        Enum.filter(
          DirectCallSession.resources(second_session),
          &(Registry.lookup(ExWebRTC.Registry, &1) != [])
        )

      started = System.monotonic_time(:millisecond)
      send(second_session, {:ex_webrtc, peer, {:connection_state_change, @status}})
      assert_retired(resources, started)
      assert_receive {:call_failed, %{terminal_outcome: :failed}}, 2_000
      assert {:ok, %{state: :terminal}} = Calls.get_call(pair.caller, pair.call_id)
      assert AdmissionCoordinator.effective_occupancy() == 0
      refute_receive {:call_active, _}, 0
      assert_no_call_history(pair)
    end
  end

  for terminal <- [:leave, :friendship] do
    @terminal terminal
    @tag :controlled_camera
    test "#{terminal} wins against queued readiness and late activation with camera present" do
      pair = start_pair("real_race_#{@terminal}", :video)
      assert {:ok, _} = Calls.accept_call(pair.recipient, pair.call_id, :video)
      [first_session, second_session] = await_sessions(pair.call_id)
      resources = monitor_resources([first_session, second_session])
      attach_call_camera(connect_call_peer(first_session), pair)
      flush_readiness(pair)
      [{server, _}] = Registry.lookup(DiscordClone.Calls.CallRegistry, pair.call_id)
      %{runtime_generation: generation} = AdmissionCoordinator.call_target_snapshot(pair.call_id)
      :ok = :sys.suspend(server)
      on_exit(fn -> safely_resume(server) end)
      attach_call_camera(connect_call_peer(second_session), pair)
      _ = :sys.get_state(DiscordClone.Voice.SessionCoordinator)
      parent = self()
      started = System.monotonic_time(:millisecond)

      start_supervised!(
        {Task,
         fn ->
           result =
             case @terminal do
               :leave ->
                 Calls.leave_call(pair.recipient, pair.call_id)

               :friendship ->
                 DiscordClone.Friendships.remove_friend(pair.caller, pair.friendship.id)
             end

           send(parent, {:terminal_result, result})
         end}
      )

      assert_retired(resources, started)

      case @terminal do
        :leave -> assert {:ok, %{state: :terminal}} = Calls.get_call(pair.caller, pair.call_id)
        :friendship -> assert {:error, :not_found} = Calls.get_call(pair.caller, pair.call_id)
      end

      safely_resume(server)
      assert_receive {:terminal_result, result}, 2_000
      assert result == :ok or match?({:ok, %{state: :terminal}}, result)

      if @terminal == :friendship,
        do: assert_receive({:call_relationship_ended, %{state: :terminal}})

      assert {:ok, :terminal} =
               Calls.complete_accepted_runtime(pair.call_id, {:connected, generation}, :video)

      refute_receive {:call_active, _}, 0
      assert_no_call_history(pair)
    end
  end

  test "camera, unknown and foreign-peer RTP cannot become Call audio" do
    pair = start_pair("real_filtering")
    assert {:ok, _} = Calls.accept_call(pair.recipient, pair.call_id, :audio)
    [first, second] = Enum.map(await_sessions(pair.call_id), &connect_call_peer/1)
    [audio, video] = PeerConnection.get_transceivers(first.server)
    forbidden = ExRTP.Packet.new(<<0xFB, 3, 0xFF, 0xFE, 0xFF, 0xFE, 0xFF, 0xFE>>)

    for {peer, track} <- [
          {first.server, video.receiver.track.id},
          {first.server, -1},
          {second.server, audio.receiver.track.id}
        ] do
      send(first.session, {:ex_webrtc, peer, {:rtp, track, nil, forbidden}})
    end

    _ = :sys.get_state(first.session)
    payload = <<0xF8, 0xFF, 0xFE>>
    send_audio(first, payload, 10, 960)
    assert_call_audio(second, payload)
    refute_receive {:ex_webrtc, _, {:rtp, _, _, _}}, 100
    assert {:ok, %{state: :terminal}} = Calls.leave_call(pair.caller, pair.call_id)
  end

  test "ending the exact Call audio input retires both routes and resources" do
    pair = start_pair("real_source_ended")
    assert {:ok, _} = Calls.accept_call(pair.recipient, pair.call_id, :audio)
    sessions = await_sessions(pair.call_id)
    [first, second] = Enum.map(sessions, &connect_call_peer/1)
    payload = <<0xF8, 0xFF, 0xFE>>
    send_audio(first, payload, 10, 960)
    assert_call_audio(second, payload)

    monitors =
      for session <- sessions,
          resource <- DirectCallSession.resources(session),
          do: {resource, Process.monitor(resource)}

    [audio, video] = PeerConnection.get_transceivers(first.server)
    send(first.session, {:ex_webrtc, first.server, {:track_ended, video.receiver.track.id}})
    send(first.session, {:ex_webrtc, second.server, {:track_ended, audio.receiver.track.id}})
    _ = :sys.get_state(first.session)
    send_audio(first, payload, 11, 1_920)
    assert_call_audio(second, payload)

    started = System.monotonic_time(:millisecond)
    send(first.session, {:ex_webrtc, first.server, {:track_ended, audio.receiver.track.id}})
    assert_receive {:call_failed, %{call_id: call_id}}, 2_000
    assert call_id == pair.call_id
    assert_retired(monitors, started)
    assert AdmissionCoordinator.effective_occupancy() == 0
    send_audio(first, payload, 12, 2_880)
    refute_receive {:ex_webrtc, _, {:rtp, _, _, _}}, 100
  end

  for failed_side <- [:first, :second] do
    @failed_side failed_side
    test "#{failed_side} real startup failure cleans partial transport without restoring Voice" do
      pair = start_pair("real_failure_#{@failed_side}")
      channel = Ecto.UUID.generate()
      priors = Enum.map([pair.caller, pair.recipient], &connect_voice_peer(channel, &1))

      prior_monitors =
        for prior <- priors,
            resource <- prior.resources,
            do: {resource, Process.monitor(resource)}

      parent = self()

      Application.put_env(:discord_clone, :call_target_startup_control, %{
        barrier: fn
          :session_starting, %{user_id: user} ->
            fail? =
              if @failed_side == :first,
                do: user == pair.caller.user.id,
                else: user == pair.recipient.user.id

            if fail?, do: {:error, :device_unavailable}, else: :ok

          :session_started, %{session: session} ->
            send(parent, {:partial_resources, DirectCallSession.resources(session)})
            :ok

          _, _ ->
            :ok
        end
      })

      started = System.monotonic_time(:millisecond)

      assert {:ok, %{state: :connecting}} =
               Calls.accept_call(pair.recipient, pair.call_id, :audio)

      assert_receive {:call_failed, %{call_id: call_id}}, 2_000
      assert call_id == pair.call_id

      assert {:ok, %{state: :terminal, terminal_outcome: :failed}} =
               Calls.get_call(pair.caller, call_id)

      assert_retired(prior_monitors, started)

      if @failed_side == :second do
        assert_receive {:partial_resources, resources}, 2_000
        assert_retired(Enum.map(resources, &{&1, Process.monitor(&1)}), started)
      end

      assert AdmissionCoordinator.current_identity(pair.caller.user.id) == nil
      assert AdmissionCoordinator.current_identity(pair.recipient.user.id) == nil
      assert AdmissionCoordinator.effective_occupancy() == 0
      assert {:ok, %{occupancy: 0}} = Voice.room_occupancy(channel)
    end
  end

  for trigger <- [:leave, :target_crash] do
    @trigger trigger
    test "#{trigger} during second startup cancels setup and cannot publish a late pair" do
      pair = start_pair("real_abandoned")
      parent = self()

      Application.put_env(:discord_clone, :call_target_startup_control, %{
        barrier: fn
          :started, %{target: target} ->
            send(parent, {:started_target, target})
            :ok

          :session_started, %{session: session} ->
            send(parent, {:partial_resources, DirectCallSession.resources(session)})
            :ok

          :session_starting, %{user_id: user} when user == pair.recipient.user.id ->
            send(parent, {:pending_session, self()})

            receive do
              :continue_startup -> :ok
            end

          _, _ ->
            :ok
        end
      })

      assert {:ok, %{state: :connecting}} =
               Calls.accept_call(pair.recipient, pair.call_id, :audio)

      assert_receive {:started_target, target}
      assert_receive {:partial_resources, resources}, 2_000
      assert_receive {:pending_session, pending}, 2_000
      monitors = Enum.map([pending | resources], &{&1, Process.monitor(&1)})
      started = System.monotonic_time(:millisecond)

      case @trigger do
        :leave ->
          assert {:ok, %{state: :terminal}} = Calls.leave_call(pair.caller, pair.call_id)

        :target_crash ->
          Process.exit(target, :kill)
          assert_receive {:call_failed, %{call_id: call_id}}, 2_000
          assert call_id == pair.call_id
      end

      assert_retired(monitors, started)
      send(pending, :continue_startup)
      assert AdmissionCoordinator.call_target_snapshot(pair.call_id) == nil
      assert AdmissionCoordinator.effective_occupancy() == 0
    end
  end

  test "real Session failure retires both ready Call routes while unrelated Voice keeps forwarding" do
    channel = Ecto.UUID.generate()
    [voice_first, voice_second] = Enum.map(1..2, fn _ -> connect_voice_peer(channel) end)
    user = voice_first.scope.user.id
    identity = AdmissionCoordinator.current_identity(user)
    payload = <<0xF8, 0xFF, 0xFE>>
    send_audio(voice_first, payload, 10, 960)
    assert_voice_audio(voice_second, payload)
    pair = start_pair("real_crash")
    assert {:ok, _} = Calls.accept_call(pair.recipient, pair.call_id, :audio)
    [first, second] = sessions = await_sessions(pair.call_id)
    [call_first, call_second] = Enum.map(sessions, &connect_call_peer/1)
    send_audio(call_first, payload, 10, 960)
    assert_call_audio(call_second, payload)

    assert {:ok, target} = DirectCallTarget.start(pair.call_id)
    assert {:ok, %{runtime_generation: generation}} = DirectCallTarget.identity(target)

    forwarder =
      GenServer.whereis(
        Target.runtime_name(Target.direct_call(pair.call_id), generation, :forwarder)
      )

    forwarder_monitor = Process.monitor(forwarder)

    monitors =
      [first, second]
      |> Enum.flat_map(&DirectCallSession.resources/1)
      |> Enum.map(&{&1, Process.monitor(&1)})

    started = System.monotonic_time(:millisecond)
    Process.exit(first, :kill)
    assert_receive {:call_failed, %{call_id: call_id}}, 2_000
    assert call_id == pair.call_id
    assert_retired([{forwarder, forwarder_monitor} | monitors], started)
    assert AdmissionCoordinator.current_identity(user) == identity
    assert {:ok, %{occupancy: 2}} = Voice.room_occupancy(channel)
    assert AdmissionCoordinator.effective_occupancy() == 2
    send_audio(voice_first, payload, 11, 1_920)
    assert_voice_audio(voice_second, payload)
    send_audio(voice_second, payload, 20, 2_880)
    assert_voice_audio(voice_first, payload)
    send_audio(call_first, payload, 11, 1_920)
    refute_receive {:ex_webrtc, _, {:rtp, _, _, _}}, 100
  end

  for intent <- [:audio, :video],
      phase <- [:connecting, :active],
      fault <- [:call_server, :target, :session, :peer, :admission] do
    @intent intent
    @tag controlled_camera: intent == :video
    @phase phase
    @fault fault
    @isolated_fault fault != :admission
    @crash_event if(fault in [:call_server, :admission],
                   do: :call_interrupted,
                   else: :call_failed
                 )
    test "#{fault} crash during real #{intent} #{phase} retires both sides and fences replacement Voice" do
      unrelated =
        if @isolated_fault do
          room = Ecto.UUID.generate()
          [first, second] = Enum.map(1..2, fn _ -> connect_voice_peer(room) end)
          send_audio(first, <<0xF8, 0xFF, 0xFE>>, 10, 960)
          assert_voice_audio(second, <<0xF8, 0xFF, 0xFE>>)
          {first, second, AdmissionCoordinator.current_identity(first.scope.user.id)}
        end

      pair = start_pair("c19_#{@intent}_#{@fault}", @intent)
      assert {:ok, _} = Calls.accept_call(pair.recipient, pair.call_id, @intent)
      sessions = await_sessions(pair.call_id)
      old = AdmissionCoordinator.call_target_snapshot(pair.call_id)
      assert {:ok, target} = DirectCallTarget.start(pair.call_id)
      resources = DiscordClone.Media.PairCommitCleanup.linked_resources(target)
      monitors = Enum.map(resources, &{&1, Process.monitor(&1)})

      if @phase == :active do
        [first, second] = Enum.map(sessions, &connect_call_peer/1)
        if @intent == :video, do: Enum.each([first, second], &attach_call_camera(&1, pair))
        flush_readiness(pair)
        assert {:ok, %{state: :active}} = Calls.get_call(pair.caller, pair.call_id)
        send_audio(first, <<0xF8, 0xFF, 0xFE>>, 10, 960)
        assert_call_audio(second, <<0xF8, 0xFF, 0xFE>>)
        send_audio(second, <<0xF9, 0xFF, 0xFE>>, 20, 1_920)
        assert_call_audio(first, <<0xF9, 0xFF, 0xFE>>)
      else
        if @intent == :video do
          first = connect_call_peer(hd(sessions))
          attach_call_camera(first, pair)
          flush_readiness(pair)
          assert {:ok, %{state: :connecting}} = Calls.get_call(pair.caller, pair.call_id)
        end
      end

      failed =
        case @fault do
          :call_server ->
            [{server, _}] = Registry.lookup(DiscordClone.Calls.CallRegistry, pair.call_id)
            server

          :target ->
            target

          :session ->
            hd(sessions)

          :peer ->
            Enum.find(DirectCallSession.resources(hd(sessions)), fn pid ->
              Registry.lookup(ExWebRTC.Registry, pid) != []
            end)

          :admission ->
            Process.whereis(DiscordClone.Voice.SessionCoordinator)
        end

      started = System.monotonic_time(:millisecond)
      Process.exit(failed, :kill)
      event = @crash_event
      call_id = pair.call_id
      assert_receive {^event, %{call_id: ^call_id, terminal_outcome: outcome}}, 5_000
      assert_retired(monitors, started)
      assert_receive {^event, %{call_id: ^call_id, terminal_outcome: ^outcome}}, 2_000
      refute_received {^event, %{call_id: ^call_id}}

      if @fault == :admission do
        await_admission_restart(failed, started + 5_000)
        assert :ok = AdmissionCoordinator.await_ready()
      end

      assert :ok = AdmissionCoordinator.cleanup_active_pair_for_call(call_id)

      if unrelated do
        {first, second, identity} = unrelated
        assert AdmissionCoordinator.current_identity(first.scope.user.id) == identity
        send_audio(first, <<0xF8, 0xFF, 0xFE>>, 11, 1_920)
        assert_voice_audio(second, <<0xF8, 0xFF, 0xFE>>)
      end

      assert AdmissionCoordinator.effective_occupancy() == if(unrelated, do: 2, else: 0)
      assert AdmissionCoordinator.current_identity(pair.caller.user.id) == nil
      assert AdmissionCoordinator.current_identity(pair.recipient.user.id) == nil
      assert {:ok, %{state: :terminal}} = Calls.get_call(pair.caller, call_id)
      assert_no_call_history(pair)

      room = Ecto.UUID.generate()
      replacement = connect_voice_peer(room, pair.caller)
      listener = connect_voice_peer(room)
      identity = AdmissionCoordinator.current_identity(pair.caller.user.id)

      # Replay captured reports and cleanup against the retired runtime after
      # the same User has deliberately acquired a replacement media target.
      for {session_id, user_id} <- old.sessions do
        assert :ok =
                 AdmissionCoordinator.call_session_started(
                   call_id,
                   old.runtime_generation,
                   user_id,
                   session_id,
                   resources
                 )

        assert :ok =
                 AdmissionCoordinator.call_session_failed(
                   call_id,
                   old.runtime_generation,
                   user_id,
                   session_id,
                   :late_failure
                 )

        assert :ok =
                 AdmissionCoordinator.call_session_removed(
                   call_id,
                   old.runtime_generation,
                   user_id,
                   session_id
                 )
      end

      assert :ok =
               AdmissionCoordinator.call_target_failed(
                 call_id,
                 old.runtime_generation,
                 :late_failure
               )

      assert :ok = AdmissionCoordinator.call_target_stopped(call_id, old.runtime_generation)
      assert :ok = AdmissionCoordinator.begin_terminal_cleanup(call_id, old.runtime_generation)
      assert :ok = AdmissionCoordinator.cleanup_active_pair(call_id, make_ref())

      assert {:error, :stale_runtime} =
               AdmissionCoordinator.call_target_ready(call_id, old.runtime_generation, target)

      assert AdmissionCoordinator.current_identity(pair.caller.user.id) == identity
      assert AdmissionCoordinator.call_target_snapshot(call_id) == nil
      send_audio(replacement, <<0xF8, 0xFF, 0xFE>>, 30, 2_880)
      assert_voice_audio(listener, <<0xF8, 0xFF, 0xFE>>)
      assert AdmissionCoordinator.effective_occupancy() == if(unrelated, do: 4, else: 2)
    end
  end

  test "actual admission restart retires stalled real transport before durable recovery becomes ready" do
    pair = start_pair("c19_stalled")
    assert {:ok, _} = Calls.accept_call(pair.recipient, pair.call_id, :audio)
    sessions = await_sessions(pair.call_id)
    [first, second] = Enum.map(sessions, &connect_call_peer/1)
    flush_readiness(pair)
    send_audio(first, <<0xF8, 0xFF, 0xFE>>, 10, 960)
    assert_call_audio(second, <<0xF8, 0xFF, 0xFE>>)
    assert {:ok, target} = DirectCallTarget.start(pair.call_id)

    monitors =
      target
      |> DiscordClone.Media.PairCommitCleanup.linked_resources()
      |> Enum.map(&{&1, Process.monitor(&1)})

    :ok = :sys.suspend(first.server)
    on_exit(fn -> safely_resume(first.server) end)
    parent = self()
    call_id = pair.call_id

    Application.put_env(:discord_clone, :recovery_settlement_barrier, fn ^call_id ->
      send(parent, {:real_recovery_settlement, self()})
      receive do: (:settle -> :ok)
    end)

    on_exit(fn -> Application.delete_env(:discord_clone, :recovery_settlement_barrier) end)

    old = Process.whereis(DiscordClone.Voice.SessionCoordinator)
    started = System.monotonic_time(:millisecond)
    Process.exit(old, :kill)
    assert_retired(monitors, started)
    assert_receive {:real_recovery_settlement, worker}, 1_000
    on_exit(fn -> send(worker, :settle) end)

    assert {:error, :recovering} =
             Voice.join(Ecto.UUID.generate(), pair.caller.user.id, "c19-blocked", self())

    assert {:ok, %{state: :active}} = Calls.get_call(pair.caller, call_id)
    send(worker, :settle)
    assert :ok = AdmissionCoordinator.await_ready()
    assert {:ok, %{terminal_outcome: :interrupted}} = Calls.get_call(pair.caller, call_id)
    assert AdmissionCoordinator.effective_occupancy() == 0
    assert_no_call_history(pair)
    assert {:ok, _} = Voice.join(Ecto.UUID.generate(), pair.caller.user.id, "c19-ready", self())
  end

  for failure <- [:database_retry, :worker_death] do
    @settlement_failure failure
    test "real recovery #{@settlement_failure} cannot admit media on transport teardown alone" do
      pair = start_pair("c19_settlement")
      assert {:ok, _} = Calls.accept_call(pair.recipient, pair.call_id, :audio)
      sessions = await_sessions(pair.call_id)
      monitors = monitor_resources(sessions)
      parent = self()
      call_id = pair.call_id

      Application.put_env(:discord_clone, :recovery_settlement_barrier, fn ^call_id ->
        send(parent, {:settlement_attempt, self()})

        receive do
          :database_failure ->
            Ecto.Adapters.SQL.Sandbox.unboxed_run(DiscordClone.Repo, fn ->
              DiscordClone.Repo.query!("SELECT 1 / 0")
            end)

          :settle ->
            :ok
        end
      end)

      on_exit(fn -> Application.delete_env(:discord_clone, :recovery_settlement_barrier) end)
      old = Process.whereis(DiscordClone.Voice.SessionCoordinator)
      started = System.monotonic_time(:millisecond)
      Process.exit(old, :kill)
      assert_receive {:settlement_attempt, worker}, 2_000
      on_exit(fn -> send(worker, :settle) end)
      assert_retired(monitors, started)
      worker_monitor = Process.monitor(worker)

      assert {:error, :recovering} =
               Voice.join(Ecto.UUID.generate(), pair.caller.user.id, "c19-unsettled", self())

      case @settlement_failure do
        :database_retry ->
          send(worker, :database_failure)
          assert_receive {:settlement_attempt, ^worker}, 2_000

          assert {:error, :recovering} =
                   Voice.join(Ecto.UUID.generate(), pair.caller.user.id, "c19-db-retry", self())

          assert {:ok, %{state: :connecting}} = Calls.get_call(pair.caller, call_id)
          send(worker, :settle)
          assert :ok = AdmissionCoordinator.await_ready()
          assert {:ok, %{terminal_outcome: :interrupted}} = Calls.get_call(pair.caller, call_id)

          assert {:ok, _} =
                   Voice.join(Ecto.UUID.generate(), pair.caller.user.id, "c19-settled", self())

        :worker_death ->
          Process.exit(worker, :kill)
          assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}, 1_000
          assert {:error, :recovery_timeout} = AdmissionCoordinator.await_ready()

          on_exit(fn ->
            coordinator = Process.whereis(DiscordClone.Voice.SessionCoordinator)
            Process.exit(coordinator, :kill)
            await_admission_restart(coordinator, System.monotonic_time(:millisecond) + 2_000)
            assert :ok = AdmissionCoordinator.await_ready()
          end)

          send(worker, :settle)

          assert {:error, :recovery_timeout} =
                   Voice.join(Ecto.UUID.generate(), pair.caller.user.id, "c19-latched", self())

          assert {:ok, %{state: :connecting}} = Calls.get_call(pair.caller, call_id)
      end

      assert_no_call_history(pair)
    end
  end

  for intent <- [:audio, :video], phase <- [:connecting, :active] do
    @intent intent
    @tag controlled_camera: intent == :video
    @restart_phase phase
    test "full Calls subtree restart interrupts real #{intent} #{phase} without resuming media or Voice" do
      pair = start_pair("c19_full_#{@intent}", @intent)
      assert {:ok, _} = Calls.accept_call(pair.recipient, pair.call_id, @intent)
      sessions = await_sessions(pair.call_id)
      monitors = monitor_resources(sessions)

      if @restart_phase == :active do
        [first, second] = Enum.map(sessions, &connect_call_peer/1)
        if @intent == :video, do: Enum.each([first, second], &attach_call_camera(&1, pair))
        flush_readiness(pair)
        assert {:ok, %{state: :active}} = Calls.get_call(pair.caller, pair.call_id)
        send_audio(first, <<0xF8, 0xFF, 0xFE>>, 10, 960)
        assert_call_audio(second, <<0xF8, 0xFF, 0xFE>>)
      end

      if @restart_phase == :connecting and @intent == :video do
        attach_call_camera(connect_call_peer(hd(sessions)), pair)
        flush_readiness(pair)
        assert {:ok, %{state: :connecting}} = Calls.get_call(pair.caller, pair.call_id)
      end

      started = System.monotonic_time(:millisecond)
      stop_supervised!(DiscordClone.Calls.Supervisor)
      start_supervised!(DiscordClone.Calls.Supervisor)
      DiscordClone.Calls.CallCoordinator.begin_recovery()
      await_recovery_finished()
      assert_retired(monitors, started)
      assert :ok = AdmissionCoordinator.cleanup_active_pair_for_call(pair.call_id)
      assert {:ok, %{terminal_outcome: :interrupted}} = Calls.get_call(pair.caller, pair.call_id)
      assert {:ok, nil} = Calls.current_call(pair.caller)
      assert AdmissionCoordinator.current_identity(pair.caller.user.id) == nil
      assert AdmissionCoordinator.current_identity(pair.recipient.user.id) == nil
      assert AdmissionCoordinator.effective_occupancy() == 0

      assert {:ok, %{state: :terminal, terminal_outcome: :interrupted}} =
               Calls.accept_call(pair.recipient, pair.call_id, @intent)

      assert AdmissionCoordinator.effective_occupancy() == 0
      assert_no_call_history(pair)
    end
  end

  @tag :controlled_camera
  test "controlled real restart preserves ringing deadline and materializes overdue Activity exactly once with camera present" do
    pair = start_pair("c19_ring_restart", :video)
    assert {:ok, before} = Calls.get_call(pair.caller, pair.call_id)
    stop_supervised!(DiscordClone.Calls.Supervisor)
    start_supervised!(DiscordClone.Calls.Supervisor)
    DiscordClone.Calls.CallCoordinator.begin_recovery()
    await_recovery_finished()
    assert {:ok, recovered} = Calls.get_call(pair.caller, pair.call_id)
    assert recovered.state == :ringing
    assert recovered.ringing_deadline_at == before.ringing_deadline_at
    assert AdmissionCoordinator.call_target_snapshot(pair.call_id) == nil
    assert AdmissionCoordinator.reservation_count() == 0

    # The existing durable fixture seam models downtime crossing the original
    # deadline without a sleep or adding a separate clock to invitation policy.
    stop_supervised!(DiscordClone.Calls.Supervisor)
    attempt = DiscordClone.Repo.get!(DiscordClone.Calls.CallAttempt, pair.call_id)
    started = DateTime.add(DateTime.utc_now(:microsecond), -31, :second)
    deadline = DateTime.add(started, 30, :second)

    attempt
    |> Ecto.Changeset.change(inserted_at: started, ringing_deadline_at: deadline)
    |> DiscordClone.Repo.update!()

    start_supervised!(DiscordClone.Calls.Supervisor)
    DiscordClone.Calls.CallCoordinator.begin_recovery()
    await_recovery_finished()

    assert {:ok, %{terminal_outcome: :timed_out, ringing_deadline_at: ^deadline}} =
             Calls.get_call(pair.caller, pair.call_id)

    assert {:ok, %{items: items}} = DiscordClone.Chat.list_activity_feed(pair.recipient)
    assert [missed] = Enum.filter(items, &(&1.kind == "missed_direct_call"))
    stop_supervised!(DiscordClone.Calls.Supervisor)
    start_supervised!(DiscordClone.Calls.Supervisor)
    DiscordClone.Calls.CallCoordinator.begin_recovery()
    await_recovery_finished()
    assert {:ok, %{items: items}} = DiscordClone.Chat.list_activity_feed(pair.recipient)
    assert [^missed] = Enum.filter(items, &(&1.kind == "missed_direct_call"))
    assert {:ok, []} = DiscordClone.Chat.list_direct_messages(pair.caller, pair.conversation_id)
    assert AdmissionCoordinator.effective_occupancy() == 0
  end

  for winner <- [:concurrent, :leave, :friendship] do
    @winner winner
    test "#{winner} terminal winner releases real media without half-call or Activity" do
      pair = start_pair("c19_friend_leave")
      assert {:ok, _} = Calls.accept_call(pair.recipient, pair.call_id, :audio)
      sessions = await_sessions(pair.call_id)
      [first, second] = Enum.map(sessions, &connect_call_peer/1)
      flush_readiness(pair)
      send_audio(first, <<0xF8, 0xFF, 0xFE>>, 10, 960)
      assert_call_audio(second, <<0xF8, 0xFF, 0xFE>>)
      monitors = monitor_resources(sessions)
      tasks = start_supervised!(Task.Supervisor)
      parent = self()

      commands = [
        fn -> DiscordClone.Friendships.remove_friend(pair.caller, pair.friendship.id) end,
        fn -> Calls.leave_call(pair.caller, pair.call_id) end,
        fn -> Calls.leave_call(pair.recipient, pair.call_id) end
      ]

      workers =
        Enum.map(commands, fn command ->
          Task.Supervisor.async_nolink(tasks, fn ->
            send(parent, {:terminal_command_ready, self()})
            receive do: (:run -> command.())
          end)
        end)

      for task <- workers, do: assert_receive({:terminal_command_ready, pid} when pid == task.pid)
      started = System.monotonic_time(:millisecond)
      [removal, caller_leave, recipient_leave] = workers

      results =
        case @winner do
          :concurrent ->
            for task <- workers, do: send(task.pid, :run)
            Enum.map(workers, &Task.await(&1, 5_000))

          :leave ->
            send(caller_leave.pid, :run)
            completed = Task.await(caller_leave, 5_000)
            send(removal.pid, :run)
            send(recipient_leave.pid, :run)
            [Task.await(removal, 5_000), completed, Task.await(recipient_leave, 5_000)]

          :friendship ->
            send(removal.pid, :run)
            removed = Task.await(removal, 5_000)
            send(caller_leave.pid, :run)
            send(recipient_leave.pid, :run)
            [removed, Task.await(caller_leave, 5_000), Task.await(recipient_leave, 5_000)]
        end

      assert [:ok | replies] = results

      for reply <- replies do
        assert match?({:ok, %{state: :terminal}}, reply) or reply == {:error, :not_found}
      end

      assert_retired(monitors, started)
      assert :ok = AdmissionCoordinator.cleanup_active_pair_for_call(pair.call_id)
      call_id = pair.call_id

      assert_receive {event, %{call_id: ^call_id, state: :terminal, terminal_outcome: outcome}},
                     1_000

      assert {event, outcome} in [
               {:call_completed, :ended},
               {:call_relationship_ended, :relationship_ended}
             ]

      assert {:error, :not_found} = Calls.get_call(pair.caller, call_id)
      assert AdmissionCoordinator.effective_occupancy() == 0
      assert AdmissionCoordinator.current_identity(pair.caller.user.id) == nil
      assert AdmissionCoordinator.current_identity(pair.recipient.user.id) == nil
      assert_no_call_history(pair)
    end
  end

  test "CallServer loss retires both real peers before blocked durable recovery" do
    pair = start_pair("real_server_loss")
    assert {:ok, _} = Calls.accept_call(pair.recipient, pair.call_id, :audio)
    sessions = await_sessions(pair.call_id)

    monitors =
      sessions
      |> Enum.flat_map(&DirectCallSession.resources/1)
      |> Enum.map(&{&1, Process.monitor(&1)})

    parent = self()

    Application.put_env(:discord_clone, :recovery_settlement_barrier, fn call_id ->
      send(parent, {:settlement_blocked, call_id, self()})

      receive do
        :resume_settlement -> :ok
      end
    end)

    coordinator = Process.whereis(DiscordClone.Calls.CallCoordinator)

    on_exit(fn ->
      Application.delete_env(:discord_clone, :recovery_settlement_barrier)
      send(coordinator, :resume_settlement)
    end)

    [{server, _}] = Registry.lookup(DiscordClone.Calls.CallRegistry, pair.call_id)
    started = System.monotonic_time(:millisecond)
    Process.exit(server, :kill)
    assert_receive {:settlement_blocked, call_id, ^coordinator}, 2_000
    assert call_id == pair.call_id
    assert_retired(monitors, started)
    assert AdmissionCoordinator.effective_occupancy() == 2
    assert AdmissionCoordinator.current_identity(pair.caller.user.id) != nil
    send(coordinator, :resume_settlement)
    assert_receive {:call_interrupted, %{call_id: ^call_id}}, 2_000
    assert :ok = AdmissionCoordinator.cleanup_active_pair_for_call(pair.call_id)
    assert AdmissionCoordinator.effective_occupancy() == 0
  end

  @tag :controlled_camera
  @tag :ticket16_workload
  @tag :ticket30_lifecycle
  test "unconfirmed durable settlement retains both pins and latches cleanup failure with camera present" do
    pair = start_pair("real_unsettled", :video)
    assert {:ok, _} = Calls.accept_call(pair.recipient, pair.call_id, :video)
    sessions = await_sessions(pair.call_id)
    endpoints = Enum.map(sessions, &connect_call_peer/1)
    Enum.each(endpoints, &attach_call_camera(&1, pair))
    Enum.each(endpoints, &assert_call_video(&1, <<0x10, 0, 1>>))
    [first, second] = endpoints
    send_audio(first, <<0xF8, 0xFF, 0xFE>>, 10, 960)
    send_audio(second, <<0xF9, 0xFF, 0xFE>>, 10, 960)
    assert_call_audio(second, <<0xF8, 0xFF, 0xFE>>)
    assert_call_audio(first, <<0xF9, 0xFF, 0xFE>>)
    flush_readiness(pair)
    assert {:ok, %{state: :active}} = Calls.get_call(pair.caller, pair.call_id)

    monitors =
      sessions
      |> Enum.flat_map(&DirectCallSession.resources/1)
      |> Enum.map(&{&1, Process.monitor(&1)})

    Application.put_env(:discord_clone, :pair_operation_timeouts, %{cleanup_ms: 100})
    [{server, _}] = Registry.lookup(DiscordClone.Calls.CallRegistry, pair.call_id)
    :ok = :sys.suspend(server)

    on_exit(fn ->
      Application.delete_env(:discord_clone, :pair_operation_timeouts)

      try do
        :sys.resume(server)
      catch
        :exit, _ -> :ok
      end
    end)

    started = System.monotonic_time(:millisecond)
    :ok = AdmissionCoordinator.begin_terminal_cleanup(pair.call_id)
    assert_retired(monitors, started)
    assert AdmissionCoordinator.effective_occupancy() == 2

    assert {:error, :cleanup_failed} =
             AdmissionCoordinator.cleanup_active_pair_for_call(pair.call_id)

    coordinator = Process.whereis(DiscordClone.Voice.SessionCoordinator)
    coordinator_monitor = Process.monitor(coordinator)
    Process.exit(coordinator, :kill)
    assert_receive {:DOWN, ^coordinator_monitor, :process, ^coordinator, :killed}
    await_admission_restart(coordinator, System.monotonic_time(:millisecond) + 2_000)
    assert :ok = AdmissionCoordinator.await_ready()
    assert AdmissionCoordinator.effective_occupancy() == 2
    assert AdmissionCoordinator.current_identity(pair.caller.user.id) != nil
    assert AdmissionCoordinator.current_identity(pair.recipient.user.id) != nil

    assert {:error, :cleanup_failed} =
             AdmissionCoordinator.cleanup_active_pair_for_call(pair.call_id)

    :ok = :sys.resume(server)
    assert_receive {:call_failed, %{call_id: call_id}}, 2_000
    assert call_id == pair.call_id
    assert {:ok, %{state: :terminal}} = Calls.leave_call(pair.caller, pair.call_id)
    assert AdmissionCoordinator.effective_occupancy() == 2

    assert {:error, :cleanup_failed} =
             AdmissionCoordinator.cleanup_active_pair_for_call(pair.call_id)

    assert AdmissionCoordinator.current_identity(pair.caller.user.id) != nil

    assert {:error, %{reason: :reservation_conflict}} =
             Voice.join(Ecto.UUID.generate(), pair.caller.user.id, "c19-held", self())

    another = start_pair("c19_failed_guard")

    assert {:ok, %{terminal_outcome: :failed_capacity}} =
             Calls.accept_call(another.recipient, another.call_id, :audio)

    assert AdmissionCoordinator.effective_occupancy() == 2
  end

  @tag :controlled_camera
  @tag :ticket30_lifecycle
  test "selected owner loss ends both real Sessions and stale reports preserve a new Call with camera present" do
    pair = start_pair("real_owner", :video)
    connection_id = Ecto.UUID.generate()

    assert :ok =
             Calls.register_connection(pair.call_id, pair.caller.user.id, :caller, connection_id)

    assert {:ok, _} = Calls.accept_call(pair.recipient, pair.call_id, :video)
    sessions = await_sessions(pair.call_id)
    endpoints = Enum.map(sessions, &connect_call_peer/1)
    Enum.each(endpoints, &attach_call_camera(&1, pair))
    Enum.each(endpoints, &assert_call_video(&1, <<0x10, 0, 1>>))
    flush_readiness(pair)
    assert {:ok, %{state: :active}} = Calls.get_call(pair.caller, pair.call_id)
    old = AdmissionCoordinator.call_target_snapshot(pair.call_id)

    monitors =
      sessions
      |> Enum.flat_map(&DirectCallSession.resources/1)
      |> Enum.map(&{&1, Process.monitor(&1)})

    started = System.monotonic_time(:millisecond)
    assert :ok = Calls.unregister_connection(pair.call_id, connection_id)
    assert_receive {:call_failed, %{call_id: call_id}}, 2_000
    assert call_id == pair.call_id
    assert_retired(monitors, started)
    assert AdmissionCoordinator.effective_occupancy() == 0

    assert {:ok, %{call: new_call}} =
             Calls.start_call(pair.caller, pair.conversation_id, :video)

    refute new_call.call_id == pair.call_id
    next = %{pair | call_id: new_call.call_id}
    assert {:ok, _} = Calls.accept_call(next.recipient, next.call_id, :video)
    [first, second] = Enum.map(await_sessions(next.call_id), &connect_call_peer/1)
    Enum.each([first, second], &attach_call_camera(&1, next))
    Enum.each([first, second], &assert_call_video(&1, <<0x10, 0, 1>>))
    flush_readiness(next)
    current = AdmissionCoordinator.call_target_snapshot(next.call_id)
    assert :ok = AdmissionCoordinator.call_target_stopped(pair.call_id, old.runtime_generation)
    assert :ok = AdmissionCoordinator.begin_terminal_cleanup(next.call_id, old.runtime_generation)
    assert :ok = AdmissionCoordinator.cleanup_active_pair(next.call_id, make_ref())
    assert AdmissionCoordinator.call_target_snapshot(next.call_id) == current

    for {source, destination} <- [{first, second}, {second, first}] do
      [_audio, video] = PeerConnection.get_transceivers(source.browser)
      send_video(source, video.sender.track.id, <<0x10, 0, 55>>, 2, 97_500)
      assert_call_video(destination, <<0x10, 0, 55>>)
    end

    assert {:ok, %{state: :active}} = Calls.get_call(next.caller, next.call_id)
    send_audio(first, <<0xF8, 0xFF, 0xFE>>, 10, 960)
    assert_call_audio(second, <<0xF8, 0xFF, 0xFE>>)
    assert_no_call_history(pair)
    assert {:ok, %{state: :terminal}} = Calls.leave_call(next.caller, next.call_id)
  end

  test "ringing resolves no hosted ICE; leaving slow setup cancels its provider worker" do
    DiscordClone.VoiceICEConfigurationHelpers.put_voice_ice_configuration(
      mode: :standard,
      stun_urls: ["stun:stun.example.test:3478"],
      provider: DiscordClone.Voice.FakeICEProvider,
      provider_secret: "test-secret",
      provider_options: [pid_observer: self(), results: :wait_forever]
    )

    pair = start_pair("real_slow_ice")
    refute_received {:ice_provider_worker, _}
    assert {:ok, _} = Calls.accept_call(pair.recipient, pair.call_id, :audio)
    assert_receive {:ice_provider_worker, provider}, 2_000
    monitor = Process.monitor(provider)
    channel = Ecto.UUID.generate()
    assert {:ok, _} = Voice.join(channel, Ecto.UUID.generate(), "while_slow", self())
    started = System.monotonic_time(:millisecond)
    assert {:ok, %{state: :terminal}} = Calls.leave_call(pair.caller, pair.call_id)
    assert_retired([{provider, monitor}], started)
    assert {:ok, %{occupancy: 1}} = Voice.room_occupancy(channel)
    assert AdmissionCoordinator.effective_occupancy() == 1
  end

  @tag :controlled_camera
  @tag :ticket30_lifecycle
  test "unconfirmed teardown retains accounting even after late resource retirement with camera present" do
    pair = start_pair("real_slow_cleanup", :video)
    assert {:ok, _} = Calls.accept_call(pair.recipient, pair.call_id, :video)
    sessions = await_sessions(pair.call_id)
    endpoints = Enum.map(sessions, &connect_call_peer/1)
    Enum.each(endpoints, &attach_call_camera(&1, pair))
    Enum.each(endpoints, &assert_call_video(&1, <<0x10, 0, 1>>))
    [first, second] = endpoints
    send_audio(first, <<0xF8, 0xFF, 0xFE>>, 10, 960)
    send_audio(second, <<0xF9, 0xFF, 0xFE>>, 10, 960)
    assert_call_audio(second, <<0xF8, 0xFF, 0xFE>>)
    assert_call_audio(first, <<0xF9, 0xFF, 0xFE>>)
    flush_readiness(pair)
    assert {:ok, %{state: :active}} = Calls.get_call(pair.caller, pair.call_id)

    monitors =
      sessions
      |> Enum.flat_map(&DirectCallSession.resources/1)
      |> Enum.map(&{&1, Process.monitor(&1)})

    parent = self()
    Application.put_env(:discord_clone, :pair_operation_timeouts, %{cleanup_ms: 100})

    Application.put_env(:discord_clone, :call_target_startup_control, %{
      barrier: fn
        :cleanup_starting, _ ->
          send(parent, {:cleanup_worker, self()})

          receive do
            :resume_cleanup -> :ok
          end

        _, _ ->
          :ok
      end
    })

    on_exit(fn -> Application.delete_env(:discord_clone, :pair_operation_timeouts) end)
    assert {:ok, %{state: :terminal}} = Calls.leave_call(pair.caller, pair.call_id)
    assert_receive {:cleanup_worker, worker}
    on_exit(fn -> send(worker, :resume_cleanup) end)
    assert AdmissionCoordinator.effective_occupancy() == 2

    assert {:error, :cleanup_failed} =
             AdmissionCoordinator.cleanup_active_pair_for_call(pair.call_id)

    send(worker, :resume_cleanup)
    assert_retired(monitors, System.monotonic_time(:millisecond))

    assert {:error, :cleanup_failed} =
             AdmissionCoordinator.cleanup_active_pair_for_call(pair.call_id)

    assert AdmissionCoordinator.effective_occupancy() == 2

    assert {:error, %{reason: :reservation_conflict}} =
             Voice.join(Ecto.UUID.generate(), pair.recipient.user.id, "c19-expired", self())

    another = start_pair("c19_expired_guard")

    assert {:ok, %{terminal_outcome: :failed_capacity}} =
             Calls.accept_call(another.recipient, another.call_id, :audio)

    assert AdmissionCoordinator.effective_occupancy() == 2
  end

  for {occupied, priors, admitted, final_occupancy} <- [
        {18, 0, true, 20},
        {18, 1, true, 19},
        {18, 2, true, 18},
        {19, 0, false, 19},
        {19, 1, true, 20},
        {19, 2, true, 19},
        {20, 0, false, 20},
        {20, 1, false, 20},
        {20, 2, true, 20}
      ] do
    @occupied occupied
    @priors priors
    @admitted admitted
    @final_occupancy final_occupancy
    test "public real acceptance at #{occupied} slots with #{priors} exact priors" do
      pair = start_pair("matrix_#{@occupied}_#{@priors}")
      channel = Ecto.UUID.generate()
      prior_scopes = Enum.take([pair.caller, pair.recipient], @priors)
      priors = Enum.map(prior_scopes, &connect_voice_peer(channel, &1))
      listener = if @priors > 0, do: connect_voice_peer(channel)

      identities =
        Map.new(prior_scopes, &{&1.user.id, AdmissionCoordinator.current_identity(&1.user.id)})

      monitors =
        for prior <- priors,
            resource <- prior.resources,
            do: {resource, Process.monitor(resource)}

      for _ <- 1..(@occupied - @priors - if(listener, do: 1, else: 0)) do
        assert {:ok, _} =
                 Voice.join(Ecto.UUID.generate(), Ecto.UUID.generate(), "matrix_fill", self())
      end

      assert AdmissionCoordinator.effective_occupancy() == @occupied
      assert AdmissionCoordinator.reservation_count() == 0
      assert AdmissionCoordinator.call_target_snapshot(pair.call_id) == nil
      assert {:ok, %{state: :ringing}} = Calls.get_call(pair.caller, pair.call_id)
      peers = MapSet.new(PeerConnection.get_all_running())
      started = System.monotonic_time(:millisecond)

      if @admitted do
        assert {:ok, %{state: :connecting}} =
                 Calls.accept_call(pair.recipient, pair.call_id, :audio)

        sessions = await_sessions(pair.call_id)
        assert_retired(monitors, started)
        assert {:ok, %{state: :connecting}} = Calls.get_call(pair.caller, pair.call_id)

        for scope <- [pair.caller, pair.recipient] do
          assert AdmissionCoordinator.current_identity(scope.user.id).target ==
                   Target.direct_call(pair.call_id)
        end

        [first, second] = Enum.map(sessions, &connect_call_peer/1)
        flush_readiness(pair)
        assert {:ok, %{state: :active}} = Calls.get_call(pair.caller, pair.call_id)
        send_audio(first, <<0xF8, 0xFF, 0xFE>>, 10, 960)
        assert_call_audio(second, <<0xF8, 0xFF, 0xFE>>)
        send_audio(second, <<0xF9, 0xFF, 0xFE, 0xFF, 0xFE>>, 20, 1_920)
        assert_call_audio(first, <<0xF9, 0xFF, 0xFE, 0xFF, 0xFE>>)
        assert AdmissionCoordinator.effective_occupancy() == @final_occupancy
        assert {:ok, _} = Calls.leave_call(pair.caller, pair.call_id)

        for prior <- priors do
          replacement = connect_voice_peer(channel, prior.scope)
          identity = AdmissionCoordinator.current_identity(prior.scope.user.id)
          assert :ok = Voice.leave(channel, prior.session_id)
          assert AdmissionCoordinator.current_identity(prior.scope.user.id) == identity
          send_audio(replacement, <<0xF8, 0xFF, 0xFE>>, 30, 2_880)
          assert_voice_audio(listener, <<0xF8, 0xFF, 0xFE>>)
        end
      else
        assert {:ok, %{state: :terminal, terminal_outcome: :failed_capacity}} =
                 Calls.accept_call(pair.recipient, pair.call_id, :audio)

        assert MapSet.new(PeerConnection.get_all_running()) == peers
        assert AdmissionCoordinator.call_target_snapshot(pair.call_id) == nil
        assert AdmissionCoordinator.reservation_count() == 0
        assert AdmissionCoordinator.effective_occupancy() == @final_occupancy

        for {user, identity} <- identities do
          assert AdmissionCoordinator.current_identity(user) == identity
        end

        for prior <- priors do
          send_audio(prior, <<0xF8, 0xFF, 0xFE>>, 10, 960)
          assert_voice_audio(listener, <<0xF8, 0xFF, 0xFE>>)
        end

        for {pid, monitor} <- monitors, do: refute_received({:DOWN, ^monitor, :process, ^pid, _})
      end

      assert_no_call_history(pair)
    end
  end

  test "real pair reservation and exact prior retirement precede logical publication" do
    pair = start_pair("switch_order")
    channel = Ecto.UUID.generate()
    [first, second] = Enum.map([pair.caller, pair.recipient], &connect_voice_peer(channel, &1))
    first_monitors = Enum.map(first.resources, &{&1, Process.monitor(&1)})
    second_monitors = Enum.map(second.resources, &{&1, Process.monitor(&1)})
    parent = self()

    before =
      Map.new(
        [pair.caller, pair.recipient],
        &{&1.user.id, AdmissionCoordinator.current_identity(&1.user.id)}
      )

    Application.put_env(:discord_clone, :pair_accept_between_reserve_and_commit, fn ->
      assert {:ok, %{state: :ringing}} = Calls.get_call(pair.caller, pair.call_id)
      assert {:ok, _} = AdmissionCoordinator.reservation_generation(pair.call_id)
      assert AdmissionCoordinator.call_target_snapshot(pair.call_id).sessions == %{}
    end)

    Application.put_env(:discord_clone, :pair_commit_fault, %{
      barrier: fn stage ->
        send(parent, {:retirement_stage, stage, self()})
        receive do: ({:resume_retirement, ^stage} -> :ok)
      end
    })

    started = System.monotonic_time(:millisecond)
    assert {:ok, %{state: :connecting}} = Calls.accept_call(pair.recipient, pair.call_id, :audio)
    assert_receive {:retirement_stage, :after_first_retirement, worker}, 2_000

    on_exit(fn ->
      send(worker, {:resume_retirement, :after_first_retirement})
      send(worker, {:resume_retirement, :before_publish})
    end)

    assert_retired(first_monitors, started)
    for {pid, ref} <- second_monitors, do: refute_received({:DOWN, ^ref, :process, ^pid, _})

    for {user, identity} <- before,
        do: assert(AdmissionCoordinator.current_identity(user) in [nil, identity])

    assert AdmissionCoordinator.call_target_snapshot(pair.call_id).sessions == %{}
    send(worker, {:resume_retirement, :after_first_retirement})
    assert_receive {:retirement_stage, :before_publish, ^worker}, 2_000
    assert_retired(second_monitors, started)

    for {user, identity} <- before,
        do: assert(AdmissionCoordinator.current_identity(user) in [nil, identity])

    assert {:ok, %{state: :connecting}} = Calls.get_call(pair.caller, pair.call_id)
    send(worker, {:resume_retirement, :before_publish})
    sessions = await_sessions(pair.call_id)
    assert {:ok, %{state: :connecting}} = Calls.get_call(pair.caller, pair.call_id)
    Enum.each(sessions, &connect_call_peer/1)
    flush_readiness(pair)
    assert {:ok, %{state: :active}} = Calls.get_call(pair.caller, pair.call_id)
    assert {:ok, _} = Calls.leave_call(pair.caller, pair.call_id)
  end

  test "unauthorized acceptance leaves both real prior Voice connections delivering audio" do
    pair = start_pair("switch_unauth")
    channel = Ecto.UUID.generate()
    [first, second] = Enum.map([pair.caller, pair.recipient], &connect_voice_peer(channel, &1))

    identities =
      Enum.map([pair.caller, pair.recipient], &AdmissionCoordinator.current_identity(&1.user.id))

    peers = MapSet.new(PeerConnection.get_all_running())
    assert {:error, :not_found} = Calls.accept_call(user_scope_fixture(), pair.call_id, :audio)
    assert {:ok, %{state: :ringing}} = Calls.get_call(pair.caller, pair.call_id)

    assert Enum.map(
             [pair.caller, pair.recipient],
             &AdmissionCoordinator.current_identity(&1.user.id)
           ) == identities

    assert MapSet.new(PeerConnection.get_all_running()) == peers
    assert AdmissionCoordinator.reservation_count() == 0
    assert AdmissionCoordinator.call_target_snapshot(pair.call_id) == nil
    send_audio(first, <<0xF8, 0xFF, 0xFE>>, 10, 960)
    assert_voice_audio(second, <<0xF8, 0xFF, 0xFE>>)
    send_audio(second, <<0xF9, 0xFF, 0xFE, 0xFF, 0xFE>>, 20, 1_920)
    assert_voice_audio(first, <<0xF9, 0xFF, 0xFE, 0xFF, 0xFE>>)
    assert {:ok, _} = Calls.decline_call(pair.recipient, pair.call_id)
  end

  test "full and unauthorized Voice destinations preserve the real active pair" do
    pair = start_pair("switch_reject")
    assert {:ok, _} = Calls.accept_call(pair.recipient, pair.call_id, :audio)
    [first, second] = Enum.map(await_sessions(pair.call_id), &connect_call_peer/1)
    flush_readiness(pair)

    identities =
      Enum.map([pair.caller, pair.recipient], &AdmissionCoordinator.current_identity(&1.user.id))

    peers = MapSet.new(PeerConnection.get_all_running())
    full = Ecto.UUID.generate()

    for _ <- 1..5,
        do:
          assert({:ok, _} = Voice.join(full, Ecto.UUID.generate(), Ecto.UUID.generate(), self()))

    assert {:error, %{reason: :room_full}} =
             Voice.join(full, pair.caller.user.id, "reject", self())

    owner = user_scope_fixture()
    assert {:ok, workspace} = DiscordClone.Workspaces.create_workspace(owner, %{name: "Private"})

    assert {:ok, destination} =
             DiscordClone.Workspaces.create_voice_channel(owner, workspace.id, %{name: "Private"})

    token = DiscordClone.Accounts.generate_user_session_token(pair.caller.user)

    assert {:ok, socket} =
             connect(DiscordCloneWeb.VoiceSocket, %{},
               connect_info: %{session: %{"user_token" => token}}
             )

    assert {:error, %{reason: "not_found"}} =
             subscribe_and_join(
               socket,
               DiscordCloneWeb.VoiceChannel,
               "voice:#{destination.id}",
               %{}
             )

    refute Voice.room_running?(destination.id)
    assert {:ok, %{state: :active}} = Calls.get_call(pair.caller, pair.call_id)

    assert Enum.map(
             [pair.caller, pair.recipient],
             &AdmissionCoordinator.current_identity(&1.user.id)
           ) == identities

    assert MapSet.subset?(peers, MapSet.new(PeerConnection.get_all_running()))
    assert AdmissionCoordinator.held_switch_count() == 0
    send_audio(first, <<0xF8, 0xFF, 0xFE>>, 10, 960)
    assert_call_audio(second, <<0xF8, 0xFF, 0xFE>>)
    send_audio(second, <<0xF9, 0xFF, 0xFE, 0xFF, 0xFE>>, 20, 1_920)
    assert_call_audio(first, <<0xF9, 0xFF, 0xFE, 0xFF, 0xFE>>)
    assert {:ok, _} = Calls.leave_call(pair.caller, pair.call_id)
    assert_no_call_history(pair)
  end

  test "held real pair startup permits unrelated Voice without exposing half a pair" do
    pair = start_pair("switch_startup")
    channel = Ecto.UUID.generate()
    priors = Enum.map([pair.caller, pair.recipient], &connect_voice_peer(channel, &1))

    monitors =
      for prior <- priors, resource <- prior.resources, do: {resource, Process.monitor(resource)}

    parent = self()

    Application.put_env(:discord_clone, :call_target_startup_control, %{
      barrier: fn
        :session_starting, %{user_id: user} when user == pair.recipient.user.id ->
          send(parent, {:held_pair_startup, self()})
          receive do: (:resume_startup -> :ok)

        _, _ ->
          :ok
      end
    })

    started = System.monotonic_time(:millisecond)
    assert {:ok, %{state: :connecting}} = Calls.accept_call(pair.recipient, pair.call_id, :audio)
    assert_receive {:held_pair_startup, worker}, 2_000
    on_exit(fn -> send(worker, :resume_startup) end)
    assert_retired(monitors, started)
    assert {:ok, %{occupancy: 0}} = Voice.room_occupancy(channel)

    for scope <- [pair.caller, pair.recipient] do
      refute match?(
               %{target: %Target{kind: :direct_call}},
               AdmissionCoordinator.current_identity(scope.user.id)
             )

      assert {:error, :not_admitted} =
               AdmissionCoordinator.call_media_session(pair.call_id, scope.user.id)
    end

    unrelated = Ecto.UUID.generate()
    [source, destination] = Enum.map(1..2, fn _ -> connect_voice_peer(unrelated) end)
    send_audio(source, <<0xF8, 0xFF, 0xFE>>, 10, 960)
    assert_voice_audio(destination, <<0xF8, 0xFF, 0xFE>>)
    started = System.monotonic_time(:millisecond)
    assert {:ok, %{state: :terminal}} = Calls.leave_call(pair.caller, pair.call_id)
    ref = Process.monitor(worker)
    assert_retired([{worker, ref}], started)
    send(worker, :resume_startup)

    for scope <- [pair.caller, pair.recipient],
        do: assert(AdmissionCoordinator.current_identity(scope.user.id) == nil)

    assert AdmissionCoordinator.call_target_snapshot(pair.call_id) == nil
    send_audio(source, <<0xF8, 0xFF, 0xFE>>, 11, 1_920)
    assert_voice_audio(destination, <<0xF8, 0xFF, 0xFE>>)
    assert_no_call_history(pair)
  end

  for occupied <- [2, 20] do
    @occupied occupied
    test "reverse switch at #{occupied} slots retains real occupancy until both transports retire" do
      if @occupied == 20 do
        for _ <- 1..18 do
          assert {:ok, _} = Voice.join(Ecto.UUID.generate(), Ecto.UUID.generate(), "fill", self())
        end
      end

      pair = start_pair("switch_cleaning")
      assert {:ok, _} = Calls.accept_call(pair.recipient, pair.call_id, :audio)
      sessions = await_sessions(pair.call_id)
      Enum.each(sessions, &connect_call_peer/1)
      flush_readiness(pair)
      monitors = monitor_resources(sessions)
      old = AdmissionCoordinator.current_identity(pair.caller.user.id)
      parent = self()
      destination = Ecto.UUID.generate()

      Application.put_env(:discord_clone, :call_target_startup_control, %{
        barrier: fn
          :cleanup_starting, _ ->
            send(parent, {:switch_cleanup, self()})
            receive do: (:resume_cleanup -> :ok)

          _, _ ->
            :ok
        end
      })

      tasks = start_supervised!(Task.Supervisor)
      started = System.monotonic_time(:millisecond)

      switch =
        Task.Supervisor.async_nolink(tasks, fn ->
          Voice.join(destination, pair.caller.user.id, "reverse", parent)
        end)

      assert_receive {:switch_cleanup, worker}, 2_000
      on_exit(fn -> send(worker, :resume_cleanup) end)

      try do
        assert AdmissionCoordinator.held_switch_count() == 1
        assert AdmissionCoordinator.effective_occupancy() == @occupied

        assert {:error, %{reason: :reservation_conflict}} =
                 Voice.join(Ecto.UUID.generate(), pair.recipient.user.id, "pinned", self())

        another = start_pair("switch_second")

        assert {:ok, %{terminal_outcome: :failed_capacity}} =
                 Calls.accept_call(another.recipient, another.call_id, :audio)

        if @occupied == 20 do
          assert {:error, %{reason: :deployment_full}} =
                   Voice.join(Ecto.UUID.generate(), Ecto.UUID.generate(), "overflow", self())
        else
          assert {:ok, _} =
                   Voice.join(Ecto.UUID.generate(), Ecto.UUID.generate(), "unrelated", self())
        end
      after
        send(worker, :resume_cleanup)
      end

      assert {:ok, %{occupancy: 1}} = Task.await(switch)
      assert_retired(monitors, started)
      assert {:ok, %{terminal_outcome: :ended}} = Calls.get_call(pair.caller, pair.call_id)

      assert AdmissionCoordinator.current_identity(pair.caller.user.id).target ==
               Target.voice_channel(destination)

      assert AdmissionCoordinator.current_identity(pair.recipient.user.id) == nil
      assert AdmissionCoordinator.effective_occupancy() == if(@occupied == 20, do: 19, else: 2)
      replacement = AdmissionCoordinator.current_identity(pair.caller.user.id)

      assert :ok =
               AdmissionCoordinator.call_session_removed(
                 pair.call_id,
                 old.runtime_generation,
                 pair.caller.user.id,
                 old.session_id
               )

      assert :ok =
               AdmissionCoordinator.call_target_failed(
                 pair.call_id,
                 old.runtime_generation,
                 :late
               )

      assert :ok =
               AdmissionCoordinator.begin_terminal_cleanup(pair.call_id, old.runtime_generation)

      assert :ok = AdmissionCoordinator.cleanup_active_pair_for_call(pair.call_id)
      assert AdmissionCoordinator.current_identity(pair.caller.user.id) == replacement
      assert {:ok, %{occupancy: 1}} = Voice.room_occupancy(destination)
      assert_no_call_history(pair)
    end
  end

  defp connect_voice_peer(channel, scope \\ user_scope_fixture()) do
    browser =
      start_supervised!(%{
        id: make_ref(),
        restart: :temporary,
        start: {PeerConnection, :start_link, [[ice_servers: [], controlling_process: self()]]}
      })

    microphone = MediaStreamTrack.new(:audio)
    assert {:ok, _} = PeerConnection.add_transceiver(browser, microphone, direction: :sendonly)

    for _ <- 1..4 do
      assert {:ok, _} = PeerConnection.add_transceiver(browser, :audio, direction: :recvonly)
    end

    assert {:ok, offer} = PeerConnection.create_offer(browser)
    assert :ok = PeerConnection.set_local_description(browser, offer)
    assert_receive {:ex_webrtc, ^browser, {:ice_gathering_state_change, :complete}}, 2_000
    offer = browser |> PeerConnection.get_local_description() |> SessionDescription.to_json()

    peers_before = MapSet.new(PeerConnection.get_all_running())

    assert {:ok, %{voice_session_id: id}} =
             Voice.join(channel, scope.user.id, Ecto.UUID.generate(), self())

    [server] =
      MapSet.difference(MapSet.new(PeerConnection.get_all_running()), peers_before)
      |> MapSet.to_list()

    resources = DiscordClone.Media.PairCommitCleanup.linked_resources(server)

    negotiation = Ecto.UUID.generate()
    assert {:ok, answer} = Voice.accept_offer(scope, channel, id, negotiation, offer)

    assert :ok =
             PeerConnection.set_remote_description(browser, SessionDescription.from_json(answer))

    apply_voice_candidates(browser, id, negotiation)
    assert_receive {:ex_webrtc, ^browser, {:connection_state_change, :connected}}, 5_000
    await_peer_state(server, :connection, :connected, System.monotonic_time(:millisecond) + 2_000)

    receiving =
      browser
      |> PeerConnection.get_transceivers()
      |> Enum.filter(&(&1.current_direction == :recvonly))
      |> Enum.map(& &1.receiver.track.id)

    %{
      browser: browser,
      source: microphone.id,
      receiving: receiving,
      scope: scope,
      session_id: id,
      channel: channel,
      resources: resources
    }
  end

  defp apply_voice_candidates(browser, id, negotiation) do
    receive do
      {:voice_session_event, ^id, {:ice_candidate, ^negotiation, candidate}} ->
        assert :ok = PeerConnection.add_ice_candidate(browser, ICECandidate.from_json(candidate))
        apply_voice_candidates(browser, id, negotiation)

      {:voice_session_event, ^id, {:end_of_candidates, ^negotiation}} ->
        :ok
    after
      2_000 -> flunk("Voice ICE gathering did not complete")
    end
  end

  defp assert_voice_audio(%{browser: browser, receiving: receiving}, payload) do
    assert_receive {:ex_webrtc, ^browser, {:rtp, track, nil, packet}}, 2_000
    assert track in receiving
    assert packet.payload == payload
  end

  defp connect_call_peer(session, options \\ []) do
    browser =
      start_supervised!(%{
        id: make_ref(),
        restart: :temporary,
        start:
          {PeerConnection, :start_link,
           [Keyword.merge([ice_servers: [], controlling_process: self()], options)]}
      })

    assert {:ok, _} =
             PeerConnection.add_transceiver(browser, MediaStreamTrack.new(:audio),
               direction: :sendrecv
             )

    assert {:ok, _} = PeerConnection.add_transceiver(browser, :video, direction: :sendrecv)
    assert {:ok, offer} = PeerConnection.create_offer(browser)
    assert :ok = PeerConnection.set_local_description(browser, offer)
    assert_receive {:ex_webrtc, ^browser, {:ice_gathering_state_change, :complete}}, 2_000
    offer = browser |> PeerConnection.get_local_description() |> SessionDescription.to_json()

    assert {:ok, _answer} =
             DirectCallSession.accept_offer(session, %{
               "negotiation_id" => "audio",
               "description" => offer
             })

    [server] =
      Enum.filter(
        DirectCallSession.resources(session),
        &(Registry.lookup(ExWebRTC.Registry, &1) != [])
      )

    await_peer_state(server, :gathering, :complete, System.monotonic_time(:millisecond) + 2_000)
    answer = PeerConnection.get_local_description(server)
    assert :ok = PeerConnection.set_remote_description(browser, answer)
    assert_receive {:ex_webrtc, ^browser, {:connection_state_change, :connected}}, 5_000
    await_peer_state(server, :connection, :connected, System.monotonic_time(:millisecond) + 2_000)
    _ = :sys.get_state(session)
    [audio, _video] = PeerConnection.get_transceivers(browser)

    %{
      browser: browser,
      server: server,
      session: session,
      source: audio.sender.track.id,
      destination: audio.receiver.track.id
    }
  end

  defp await_peer_state(peer, kind, expected, deadline) do
    actual =
      if kind == :gathering,
        do: PeerConnection.get_ice_gathering_state(peer),
        else: PeerConnection.get_connection_state(peer)

    if actual != expected do
      assert System.monotonic_time(:millisecond) < deadline

      receive do
      after
        1 -> await_peer_state(peer, kind, expected, deadline)
      end
    end
  end

  defp send_audio(endpoint, payload, sequence_number, timestamp) do
    assert :ok =
             PeerConnection.send_rtp(
               endpoint.browser,
               endpoint.source,
               ExRTP.Packet.new(payload, sequence_number: sequence_number, timestamp: timestamp)
             )
  end

  defp assert_call_audio(%{browser: browser, destination: track}, payload) do
    assert_receive {:ex_webrtc, ^browser, {:rtp, ^track, nil, packet}}, 2_000
    assert packet.payload == payload
    packet
  end

  defp queue_decoder_pli(destination, pair) do
    [_audio, video] = PeerConnection.get_transceivers(destination.server)
    forwarder = call_forwarder(pair)
    pli = %ExRTCP.Packet.PayloadFeedback.PLI{sender_ssrc: 1, media_ssrc: 2}

    send(
      destination.session,
      {:ex_webrtc, destination.server, {:rtcp, [{video.sender.track.id, pli}]}}
    )

    _ = :sys.get_state(destination.session)
    DiscordClone.Voice.Forwarder.sync(forwarder)
  end

  defp assert_camera_pli(%{browser: browser}, camera) do
    assert_receive {:ex_webrtc, ^browser,
                    {:rtcp, [{^camera, %ExRTCP.Packet.PayloadFeedback.PLI{}}]}},
                   2_000
  end

  defp call_forwarder(pair) do
    snapshot = AdmissionCoordinator.call_target_snapshot(pair.call_id)

    GenServer.whereis(
      Target.runtime_name(
        Target.direct_call(pair.call_id),
        snapshot.runtime_generation,
        :forwarder
      )
    )
  end

  defp assert_call_video(%{browser: browser}, payload) do
    [_audio, video] = PeerConnection.get_transceivers(browser)
    track = video.receiver.track.id
    assert_receive {:ex_webrtc, ^browser, {:rtp, ^track, nil, packet}}, 2_000
    assert packet.payload == payload
  end

  defp start_pair(suffix, intent \\ :audio) do
    {caller, recipient, conversation, friendship} = direct_conversation_fixture(suffix)
    :ok = Calls.subscribe(caller)
    :ok = Calls.subscribe(recipient)
    assert {:ok, %{call: call}} = Calls.start_call(caller, conversation.id, intent)

    %{
      caller: caller,
      recipient: recipient,
      call_id: call.call_id,
      conversation_id: conversation.id,
      friendship: friendship
    }
  end

  defp attach_call_camera(endpoint, pair, sequence \\ 1) do
    [_audio, video] = PeerConnection.get_transceivers(endpoint.browser)
    camera = MediaStreamTrack.new(:video)
    assert :ok = PeerConnection.replace_track(endpoint.browser, video.sender.id, camera)
    signaling_id = Ecto.UUID.generate()

    assert {:ok, credentials} =
             DirectCallSession.media_credentials(endpoint.session, signaling_id)

    assert {:ok, %{camera_enabled: true, microphone_muted: false}} =
             DirectCallSession.local_media_state(endpoint.session, %{
               "call_id" => pair.call_id,
               "call_session_id" => credentials.call_session_id,
               "signaling_session_id" => signaling_id,
               "negotiation_id" => "audio",
               "media_state_version" => 1,
               "microphone_muted" => false,
               "camera_enabled" => true
             })

    assert :ok =
             PeerConnection.send_rtp(
               endpoint.browser,
               camera.id,
               ExRTP.Packet.new(<<0x10, 0x00, 0x01>>,
                 sequence_number: sequence,
                 marker: true,
                 timestamp: 90_000
               )
             )

    camera.id
  end

  defp packet_gate(peer, label) do
    start_supervised!(%{
      id: make_ref(),
      restart: :temporary,
      start: {DiscordClone.MediaPacketGate, :start_link, [{peer, self(), label}]}
    })
  end

  defp assert_report_time(
         destination,
         position,
         packet,
         rate,
         earliest,
         latest,
         minimum_packets \\ nil
       ) do
    send(destination.server, {:send_reports, position.id})

    track =
      destination.browser
      |> PeerConnection.get_transceivers()
      |> Enum.find(&(&1.kind == position.kind))
      |> then(& &1.receiver.track.id)

    minimum_packets = minimum_packets || if(position.kind == :video, do: 2, else: 1)
    browser = destination.browser

    assert_receive {:ex_webrtc, ^browser,
                    {:rtcp, [{^track, %ExRTCP.Packet.SenderReport{packet_count: count} = report}]}}
                   when count >= minimum_packets,
                   2_000

    assert report.ssrc == packet.ssrc
    assert report.packet_count > 0 and report.octet_count > 0
    packet_time = report_packet_time(report, packet.timestamp, rate)
    # NTP serialization and RTP rounding contribute at most one RTP tick
    # plus one microsecond; the observed bracket supplies all other bounds.
    precision = 1_000_000 / rate + 1
    assert packet_time >= earliest - precision
    assert packet_time <= latest + precision
    packet_time
  end

  defp report_packet_time(report, timestamp, rate) do
    seconds = Bitwise.bsr(report.ntp_timestamp, 32) - 2_208_988_800
    fraction = Bitwise.band(report.ntp_timestamp, 0xFFFFFFFF) / 4_294_967_296
    ticks = Bitwise.band(report.rtp_timestamp - timestamp, 0xFFFFFFFF)
    (seconds + fraction - ticks / rate) * 1_000_000
  end

  defp receive_video(%{browser: browser}, payload) do
    [_audio, video] = PeerConnection.get_transceivers(browser)
    receiver = video.receiver.track.id

    assert_receive {:ex_webrtc, ^browser, {:rtp, ^receiver, nil, %{payload: ^payload} = packet}},
                   2_000

    packet
  end

  defp repair_video(source, destination, camera, gate, leg, input_seq, output_seq, marker) do
    lost_seq = if leg == :source, do: input_seq, else: output_seq
    receiver_label = if leg == :source, do: :source_receiver, else: :destination_receiver
    sender_label = if leg == :source, do: :source_sender, else: :destination_sender
    assert :ok = DiscordClone.MediaPacketGate.drop_next(gate, lost_seq)
    sender_peer = if leg == :source, do: source.browser, else: destination.server
    [_audio, sending] = PeerConnection.get_transceivers(sender_peer)
    before_stats = Map.fetch!(PeerConnection.get_stats(sender_peer), sending.sender.id)
    lost = <<0x10, 0, marker>>
    following = <<if(leg == :source, do: 0, else: 0x10), 0, marker + 1>>
    timestamp = 90_000 + marker * 3_750

    assert :ok =
             PeerConnection.send_rtp(
               source.browser,
               camera,
               ExRTP.Packet.new(lost,
                 sequence_number: input_seq,
                 timestamp: timestamp,
                 marker: leg == :destination
               )
             )

    assert_receive {:media_packet, ^receiver_label, %{dropped?: true} = original}, 2_000
    assert original.sequence == lost_seq
    assert original.kind == :primary
    primary = sending.sender.codec
    repair_codec = Enum.find(sending.codecs, &(&1.mime_type == "video/rtx"))
    assert primary.mime_type == "video/VP8"
    assert repair_codec.mime_type == "video/rtx"
    assert repair_codec.sdp_fmtp_line.apt == primary.payload_type
    assert original.pt == primary.payload_type

    assert original.ssrc ==
             Map.fetch!(PeerConnection.get_stats(sender_peer), sending.sender.id).ssrc

    next_timestamp = if leg == :source, do: timestamp, else: timestamp + 3_750
    send_video(source, camera, following, rem(input_seq + 1, 65_536), next_timestamp)

    assert_receive {:media_nack, ^sender_label, ssrc, sequences}, 2_000
    assert ssrc == original.ssrc
    assert lost_seq in sequences
    assert_receive {:media_packet, ^receiver_label, %{kind: :rtx} = repair}, 2_000
    assert repair.sequence == lost_seq
    assert repair.ssrc != original.ssrc
    assert repair.pt != original.pt
    assert repair.pt == repair_codec.payload_type
    assert repair.ssrc == repair_ssrc(sender_peer, original.ssrc)
    assert repair.digest == original.digest
    assert repair.payload_bytes == original.payload_bytes + 2
    assert repair.timestamp == original.timestamp
    assert repair.header_bytes >= 12
    assert original.payload_bytes == 3
    assert original.digest == :crypto.hash(:sha256, lost)

    # Source repair completes one frame before admission; destination repair
    # still arrives after the following already-admitted frame on that leg.
    {received, after_gap} =
      if leg == :source do
        {receive_video(destination, lost), receive_video(destination, following)}
      else
        after_gap = receive_video(destination, following)
        {receive_video(destination, lost), after_gap}
      end

    assert after_gap.sequence_number == rem(output_seq + 1, 65_536)
    assert received.sequence_number == output_seq
    assert after_gap.timestamp - received.timestamp == if(leg == :source, do: 0, else: 3_750)
    assert received.ssrc == after_gap.ssrc
    assert received.payload_type == after_gap.payload_type
    after_stats = Map.fetch!(PeerConnection.get_stats(sender_peer), sending.sender.id)

    assert after_stats.packets_sent - before_stats.packets_sent -
             (after_stats.retransmitted_packets_sent - before_stats.retransmitted_packets_sent) ==
             2

    assert after_stats.retransmitted_packets_sent > before_stats.retransmitted_packets_sent
    # Pinned native bytes include RTP headers. They are not browser payload-byte
    # counters and do not measure SRTP/UDP/TURN overhead or an encoding rate.
    assert after_stats.retransmitted_bytes_sent - before_stats.retransmitted_bytes_sent >=
             repair.payload_bytes + repair.header_bytes

    # Admission contains source-side holes before the destination; destination
    # loss never asks the source's different sequence space for repair.
    if leg == :destination, do: refute_receive({:media_nack, :source_sender, _, _}, 150)
    flush_packet_observations()
    received
  end

  defp source_ssrc(source) do
    [_audio, video] = PeerConnection.get_transceivers(source.browser)
    Map.fetch!(PeerConnection.get_stats(source.browser), video.sender.id).ssrc
  end

  defp repair_ssrc(peer, primary_ssrc) do
    sdp = ExSDP.parse!(PeerConnection.get_local_description(peer).sdp)
    video = Enum.find(sdp.media, &(&1.type == :video))
    group = Enum.find(video.attributes, &match?(%ExSDP.Attribute.SSRCGroup{}, &1))
    assert group.semantics == "FID"
    [^primary_ssrc, rtx_ssrc] = group.ssrcs
    rtx_ssrc
  end

  defp repair_camera_state(source, pair, version, enabled) do
    signaling = Ecto.UUID.generate()
    assert {:ok, credentials} = DirectCallSession.media_credentials(source.session, signaling)

    params = %{
      "call_id" => pair.call_id,
      "call_session_id" => credentials.call_session_id,
      "signaling_session_id" => signaling,
      "negotiation_id" => "audio",
      "media_state_version" => version,
      "microphone_muted" => false,
      "camera_enabled" => enabled
    }

    assert {:ok, %{camera_enabled: ^enabled}} =
             DirectCallSession.local_media_state(source.session, params)

    params
  end

  defp refute_video(%{browser: browser}, payload) do
    refute_receive {:ex_webrtc, ^browser, {:rtp, _, nil, %{payload: ^payload}}}, 100
  end

  defp send_video(source, camera, payload, sequence, timestamp) do
    assert :ok =
             PeerConnection.send_rtp(
               source.browser,
               camera,
               ExRTP.Packet.new(payload,
                 sequence_number: sequence,
                 timestamp: timestamp,
                 marker: true
               )
             )
  end

  defp flush_packet_observations do
    receive do
      {:media_packet, _, _} -> flush_packet_observations()
      {:media_nack, _, _, _} -> flush_packet_observations()
    after
      0 -> :ok
    end
  end

  defp renew_call_peer(endpoint) do
    signaling_id = Ecto.UUID.generate()

    assert {:ok, credentials} =
             DirectCallSession.media_credentials(endpoint.session, signaling_id)

    assert {:ok, %{renewal_interval_ms: 30_000, lease_duration_ms: 120_000}} =
             DirectCallSession.renew(endpoint.session, %{
               "call_session_id" => credentials.call_session_id,
               "signaling_session_id" => signaling_id
             })
  end

  # Transport events are a controlled external boundary; outcomes use scoped Calls.
  defp report_connection(endpoint, status) do
    send(endpoint.session, {:ex_webrtc, endpoint.server, {:connection_state_change, status}})
    _ = :sys.get_state(endpoint.session)
  end

  defp flush_readiness(pair) do
    %{runtime_generation: generation} = AdmissionCoordinator.call_target_snapshot(pair.call_id)

    room =
      GenServer.whereis(Target.runtime_name(Target.direct_call(pair.call_id), generation, :room))

    _ = :sys.get_state(room)
    _ = :sys.get_state(DiscordClone.Voice.SessionCoordinator)
    _ = DiscordClone.Calls.CallServer.answer_mode(pair.call_id)
    :ok
  end

  defp assert_no_call_history(pair) do
    assert {:ok, []} = DiscordClone.Chat.list_direct_messages(pair.caller, pair.conversation_id)
    assert {:ok, %{items: items}} = DiscordClone.Chat.list_activity_feed(pair.recipient)
    refute Enum.any?(items, &(&1.kind == "missed_direct_call"))
  end

  defp delivery_cpu_pressure(deadline) do
    if System.monotonic_time(:millisecond) < deadline do
      :crypto.hash(:sha256, :binary.copy(<<0>>, 65_536))
      delivery_cpu_pressure(deadline)
    end
  end

  defp await_video_transport_idle(session, attempts \\ 2_000) do
    if :sys.get_state(session).video_delivery == nil do
      :ok
    else
      assert attempts > 0, "video credit did not drain"

      receive do
      after
        1 -> await_video_transport_idle(session, attempts - 1)
      end
    end
  end

  defp await_video_route_state(forwarder, id, session, expected, attempts \\ 2_000) do
    case DiscordClone.Voice.Forwarder.video_route_status(forwarder, id, session) do
      {:ok, %{state: ^expected}} ->
        :ok

      other ->
        assert attempts > 0, "video route did not reach #{expected}: #{inspect(other)}"

        receive do
        after
          1 -> await_video_route_state(forwarder, id, session, expected, attempts - 1)
        end
    end
  end

  defp await_busy_frame_drop(forwarder, id, session, attempts \\ 2_000) do
    case DiscordClone.Voice.Forwarder.video_route_status(forwarder, id, session) do
      {:ok, %{dropped_frames: count}} when count > 0 ->
        :ok

      _ ->
        assert attempts > 0, "replacement frame did not reach occupied transport credit"

        receive do
        after
          1 -> await_busy_frame_drop(forwarder, id, session, attempts - 1)
        end
    end
  end

  defp monitor_resources(sessions) do
    for session <- sessions,
        resource <- DirectCallSession.resources(session),
        do: {resource, Process.monitor(resource)}
  end

  defp safely_resume(pid) do
    :sys.resume(pid)
  catch
    :exit, _ -> :ok
  end

  defp await_test_release(parent, release) do
    monitor = Process.monitor(parent)

    try do
      receive do
        ^release -> :ok
        {:DOWN, ^monitor, :process, ^parent, _reason} -> :ok
      end
    after
      Process.demonitor(monitor, [:flush])
    end
  end

  defp hold_terminal_cleanup do
    parent = self()

    Application.put_env(:discord_clone, :call_target_startup_control, %{
      barrier: fn
        :cleanup_starting, _ ->
          send(parent, {:terminal_cleanup_started, self()})
          await_test_release(parent, :release_cleanup)

        _, _ ->
          :ok
      end
    })
  end

  defp await_sessions(call_id, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 2_000

    case AdmissionCoordinator.call_target_snapshot(call_id) do
      %{sessions: sessions} when map_size(sessions) == 2 ->
        published? =
          Enum.all?(sessions, fn {id, user} ->
            match?(%{session_id: ^id}, AdmissionCoordinator.current_identity(user))
          end)

        if published? do
          assert {:ok, target} = DirectCallTarget.start(call_id)

          Enum.map(sessions, fn {id, user} ->
            assert {:ok, session} = DirectCallTarget.session(target, user, id)
            session
          end)
        else
          retry_sessions(call_id, deadline)
        end

      _ ->
        assert System.monotonic_time(:millisecond) < deadline

        receive do
        after
          1 -> await_sessions(call_id, deadline)
        end
    end
  end

  defp retry_sessions(call_id, deadline) do
    assert System.monotonic_time(:millisecond) < deadline

    receive do
    after
      1 -> await_sessions(call_id, deadline)
    end
  end

  defp await_admission_restart(previous, deadline) do
    case Process.whereis(DiscordClone.Voice.SessionCoordinator) do
      pid when is_pid(pid) and pid != previous ->
        :ok

      _ ->
        assert System.monotonic_time(:millisecond) < deadline

        receive do
        after
          1 -> await_admission_restart(previous, deadline)
        end
    end
  end

  defp assert_retired(monitors, started) do
    for {pid, monitor} <- monitors do
      remaining = max(5_000 - (System.monotonic_time(:millisecond) - started), 0)
      assert_receive {:DOWN, ^monitor, :process, ^pid, _}, remaining
    end

    assert System.monotonic_time(:millisecond) - started < 5_000
  end
end
