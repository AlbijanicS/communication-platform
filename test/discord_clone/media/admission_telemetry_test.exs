defmodule DiscordClone.Media.AdmissionTelemetryTest do
  @moduledoc false
  use DiscordClone.DataCase, async: false

  import DiscordClone.CallsFixtures
  import ExUnit.CaptureLog

  alias DiscordClone.Calls
  alias DiscordClone.Media.{AdmissionCoordinator, AdmissionDiagnostics}
  alias DiscordClone.MediaFixtures
  alias DiscordClone.Voice
  alias DiscordClone.Voice.DeploymentCapacity

  @event [:discord_clone, :media_admission, :operation]

  @sensitive_fragments [
    "application/sdp",
    "ice-pwd",
    "ice-ufrag",
    "a=candidate",
    "credential",
    "device_id",
    "signaling_session",
    "rtpmap",
    "m=audio",
    "m=video",
    "opus",
    "vp8"
  ]

  setup do
    on_exit(fn ->
      Voice.running_room_servers()
      |> Enum.each(fn {voice_channel_id, _room_server} ->
        :ok = Voice.end_channel_sessions(voice_channel_id)
        :ok = Voice.expire_idle_room(voice_channel_id)
      end)
    end)

    on_exit(&MediaFixtures.reset_coordinator_pair_state!/0)

    :ok
  end

  describe "duration and outcome emission" do
    test "reserve_pair success emits accepted with bounded measurements" do
      pair = MediaFixtures.ringing_pair_fixture()
      MediaFixtures.start_ready_call_target(pair.call_id)
      {test_pid, handler_id} = attach_collector()

      try do
        assert {:ok, reservation} =
                 AdmissionCoordinator.reserve_pair(
                   pair.call_id,
                   {pair.first_user_id, nil},
                   {pair.second_user_id, nil}
                 )

        assert_received_telemetry(handler_id, "reserve_pair", :accepted, nil)

        assert :ok =
                 AdmissionCoordinator.release_reservation(pair.call_id, reservation.generation)

        _ = test_pid
      after
        :telemetry.detach(handler_id)
      end
    end

    test "reserve_pair capacity vs generic failures use distinct error codes" do
      pair = MediaFixtures.ringing_pair_fixture()
      MediaFixtures.start_ready_call_target(pair.call_id)
      {_, handler_id} = attach_collector()

      try do
        # Generic failure: unknown call id fails preflight before the ledger.
        assert {:error, :not_found} =
                 AdmissionCoordinator.reserve_pair(
                   Ecto.UUID.generate(),
                   {pair.first_user_id, nil},
                   {pair.second_user_id, nil}
                 )

        assert_received_telemetry(handler_id, "reserve_pair", :failed, :not_found)

        # Capacity failure: fill to 19 then reserve with no credit projects 21.
        Enum.each(1..19, fn index ->
          assert {:ok, _} =
                   Voice.join(
                     Ecto.UUID.generate(),
                     Ecto.UUID.generate(),
                     "cap-dist-#{index}",
                     self()
                   )
        end)

        assert {:error, %{reason: :deployment_full}} =
                 AdmissionCoordinator.reserve_pair(
                   pair.call_id,
                   {pair.first_user_id, nil},
                   {pair.second_user_id, nil}
                 )

        assert_received_telemetry(handler_id, "reserve_pair", :rejected, :deployment_full)
      after
        :telemetry.detach(handler_id)
      end
    end

    test "commit_pair emits begin and commit measurements" do
      pair = MediaFixtures.ringing_pair_fixture()
      MediaFixtures.start_ready_call_target(pair.call_id)
      {_, handler_id} = attach_collector()

      try do
        assert {:ok, reservation} =
                 AdmissionCoordinator.reserve_pair(
                   pair.call_id,
                   {pair.first_user_id, nil},
                   {pair.second_user_id, nil}
                 )

        MediaFixtures.set_attempt_connecting!(pair.call_id)

        assert {:ok, _} = AdmissionCoordinator.commit_pair(pair.call_id, reservation.generation)

        assert_received_telemetry(handler_id, "begin_pair_commit", :accepted, nil)
        assert_received_telemetry(handler_id, "commit_pair", :accepted, nil)

        assert :ok =
                 AdmissionCoordinator.cleanup_active_pair(pair.call_id, reservation.generation)

        assert_received_telemetry(handler_id, "cleanup_active_pair", :accepted, nil)
      after
        :telemetry.detach(handler_id)
      end
    end

    test "cleanup_active_pair_for_call emits without changing the idempotent result" do
      pair = MediaFixtures.ringing_pair_fixture()
      MediaFixtures.start_ready_call_target(pair.call_id)
      {_, handler_id} = attach_collector()

      try do
        assert {:ok, reservation} =
                 AdmissionCoordinator.reserve_pair(
                   pair.call_id,
                   {pair.first_user_id, nil},
                   {pair.second_user_id, nil}
                 )

        MediaFixtures.set_attempt_connecting!(pair.call_id)
        assert {:ok, _} = AdmissionCoordinator.commit_pair(pair.call_id, reservation.generation)
        assert :ok = AdmissionCoordinator.cleanup_active_pair_for_call(pair.call_id)

        assert_received_telemetry(
          handler_id,
          "cleanup_active_pair_for_call",
          :accepted,
          nil
        )

        # Idempotent repeat still returns :ok with telemetry.
        assert :ok = AdmissionCoordinator.cleanup_active_pair_for_call(pair.call_id)
      after
        :telemetry.detach(handler_id)
      end
    end

    test "outer join emits in both normal and switch paths" do
      {_, handler_id} = attach_collector()

      try do
        # Normal path: no active call. Begin emits first, then the outer join.
        assert {:ok, _} =
                 Voice.join(Ecto.UUID.generate(), Ecto.UUID.generate(), "join-normal", self())

        assert_received_telemetry(handler_id, "begin_voice_switch", :accepted, nil)
        assert_received_telemetry(handler_id, "join", :accepted, nil)
      after
        :telemetry.detach(handler_id)
      end
    end

    test "reverse switch emits begin, publish and join" do
      pair = MediaFixtures.ringing_pair_fixture()
      MediaFixtures.start_ready_call_target(pair.call_id)

      assert {:ok, reservation} =
               AdmissionCoordinator.reserve_pair(
                 pair.call_id,
                 {pair.first_user_id, nil},
                 {pair.second_user_id, nil}
               )

      MediaFixtures.set_attempt_connecting!(pair.call_id)
      assert {:ok, _} = AdmissionCoordinator.commit_pair(pair.call_id, reservation.generation)

      {_, handler_id} = attach_collector()

      try do
        destination = Ecto.UUID.generate()

        assert {:ok, plan} =
                 AdmissionCoordinator.begin_voice_switch(pair.first_user_id, destination)

        assert_received_telemetry(handler_id, "begin_voice_switch", :accepted, nil)

        assert :ok = AdmissionCoordinator.abort_voice_switch(pair.first_user_id, plan.generation)

        assert_received_telemetry(handler_id, "abort_voice_switch", :accepted, nil)

        # Full outer join through the held switch path is covered by the
        # switch integration suite; here we prove the begin/abort ledger.
        :ok = flush_telemetry(handler_id)
      after
        :telemetry.detach(handler_id)
        :ok = AdmissionCoordinator.cleanup_active_pair(pair.call_id, reservation.generation)
      end
    end

    test "timed-out switch abort returns ok but emits unavailable instead of accepted" do
      {_, handler_id} = attach_collector()
      tasks = start_supervised!(Task.Supervisor)
      coordinator = Process.whereis(DiscordClone.Voice.SessionCoordinator)
      user_id = Ecto.UUID.generate()
      generation = make_ref()
      :ok = :sys.suspend(coordinator)

      try do
        abort =
          Task.Supervisor.async_nolink(tasks, fn ->
            AdmissionCoordinator.abort_voice_switch(user_id, generation)
          end)

        monitor = Process.monitor(abort.pid)

        # The real abort call times out, followed by the existing best-effort
        # gauge read. No test-only timeout or coordinator callback is needed.
        assert :ok = Task.await(abort, 12_000)
        assert_receive {:DOWN, ^monitor, :process, _, :normal}

        assert_unavailable_abort_event(handler_id, user_id, generation)
      after
        :ok = :sys.resume(coordinator)
        :telemetry.detach(handler_id)
      end

      # Drain the late abort and gauge requests before the next test.
      _ = :sys.get_state(coordinator)
    end

    test "unavailable switch owner returns ok without claiming its hold was released" do
      pair = MediaFixtures.ringing_pair_fixture()
      MediaFixtures.start_ready_call_target(pair.call_id)

      assert {:ok, reservation} =
               AdmissionCoordinator.reserve_pair(
                 pair.call_id,
                 {pair.first_user_id, nil},
                 {pair.second_user_id, nil}
               )

      MediaFixtures.set_attempt_connecting!(pair.call_id)
      assert {:ok, _} = AdmissionCoordinator.commit_pair(pair.call_id, reservation.generation)

      assert {:ok, plan} =
               AdmissionCoordinator.begin_voice_switch(pair.first_user_id, Ecto.UUID.generate())

      {_, handler_id} = attach_collector()
      coordinator_name = DiscordClone.Voice.SessionCoordinator
      coordinator = Process.whereis(coordinator_name)

      try do
        # Remove API availability while preserving the real owner and hold.
        assert Process.unregister(coordinator_name)

        assert :ok = AdmissionCoordinator.abort_voice_switch(pair.first_user_id, plan.generation)

        assert_unavailable_abort_event(handler_id, pair.first_user_id, plan.generation)
      after
        Process.register(coordinator, coordinator_name)
        :telemetry.detach(handler_id)
      end

      assert AdmissionCoordinator.held_switch_count() == 1
      {_, retry_handler_id} = attach_collector()

      try do
        assert :ok = AdmissionCoordinator.abort_voice_switch(pair.first_user_id, plan.generation)
        assert_received_telemetry(retry_handler_id, "abort_voice_switch", :accepted, nil)
        assert AdmissionCoordinator.held_switch_count() == 0
      after
        :telemetry.detach(retry_handler_id)
        :ok = AdmissionCoordinator.cleanup_active_pair(pair.call_id, reservation.generation)
      end
    end

    test "full Voice join from durable active Call emits publish and join" do
      start_supervised!(DiscordClone.Calls.Supervisor)
      DiscordClone.Calls.CallCoordinator.begin_recovery()
      await_recovery_finished()

      previous_runtime = Application.get_env(:discord_clone, :accepted_call_runtime)

      Application.put_env(
        :discord_clone,
        :accepted_call_runtime,
        DiscordClone.Calls.PairAdmissionRuntime
      )

      on_exit(fn ->
        if is_nil(previous_runtime) do
          Application.delete_env(:discord_clone, :accepted_call_runtime)
        else
          Application.put_env(:discord_clone, :accepted_call_runtime, previous_runtime)
        end
      end)

      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("telemetry_pub")

      assert {:ok, %{call: ringing}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      assert {:ok, _} = Calls.accept_call(recipient_scope, ringing.call_id, :audio)
      assert eventually_active?(ringing.call_id)

      {_, handler_id} = attach_collector()

      try do
        destination = Ecto.UUID.generate()

        assert {:ok, _} =
                 Voice.join(destination, caller_scope.user.id, "telemetry-publish", self())

        assert_received_telemetry(handler_id, "begin_voice_switch", :accepted, nil)
        assert_received_telemetry(handler_id, "publish_voice_switch", :accepted, nil)
        assert_received_telemetry(handler_id, "join", :accepted, nil)
      after
        :telemetry.detach(handler_id)
      end
    end
  end

  describe "ledger-true gauges" do
    test "20-to-20 Voice-to-Call replacement reports 20, not 22" do
      pair = MediaFixtures.ringing_pair_fixture()
      MediaFixtures.start_ready_call_target(pair.call_id)

      Enum.each(1..18, fn index ->
        assert {:ok, _} =
                 Voice.join(Ecto.UUID.generate(), Ecto.UUID.generate(), "t20-#{index}", self())
      end)

      first_channel = Ecto.UUID.generate()
      second_channel = Ecto.UUID.generate()

      assert {:ok, _} = Voice.join(first_channel, pair.first_user_id, "t20-first", self())
      assert {:ok, _} = Voice.join(second_channel, pair.second_user_id, "t20-second", self())

      assert AdmissionCoordinator.effective_occupancy() == 20

      assert {:ok, reservation} =
               AdmissionCoordinator.reserve_pair(
                 pair.call_id,
                 {pair.first_user_id, AdmissionCoordinator.current_identity(pair.first_user_id)},
                 {pair.second_user_id, AdmissionCoordinator.current_identity(pair.second_user_id)}
               )

      # Two exact credits: 20 active + 2 reserved - 2 credited = 20.
      assert AdmissionCoordinator.effective_occupancy() == 20
      assert AdmissionCoordinator.reservation_count() == 1

      gauges = AdmissionCoordinator.admission_gauges()
      assert gauges.occupancy == 20
      assert gauges.reservation_count == 1
      assert is_integer(gauges.mailbox_len) and gauges.mailbox_len >= 0

      MediaFixtures.set_attempt_connecting!(pair.call_id)
      assert {:ok, _} = AdmissionCoordinator.commit_pair(pair.call_id, reservation.generation)
      assert AdmissionCoordinator.effective_occupancy() == 20

      assert :ok = AdmissionCoordinator.cleanup_active_pair(pair.call_id, reservation.generation)
    end

    test "full-node Call-to-Voice switch reports 19 while destination is reserved" do
      pair = MediaFixtures.ringing_pair_fixture()
      MediaFixtures.start_ready_call_target(pair.call_id)

      assert {:ok, reservation} =
               AdmissionCoordinator.reserve_pair(
                 pair.call_id,
                 {pair.first_user_id, nil},
                 {pair.second_user_id, nil}
               )

      MediaFixtures.set_attempt_connecting!(pair.call_id)
      assert {:ok, _} = AdmissionCoordinator.commit_pair(pair.call_id, reservation.generation)

      Enum.each(1..18, fn index ->
        assert {:ok, _} =
                 Voice.join(Ecto.UUID.generate(), Ecto.UUID.generate(), "sw19-#{index}", self())
      end)

      assert AdmissionCoordinator.effective_occupancy() == 20

      destination = Ecto.UUID.generate()

      assert {:ok, plan} =
               AdmissionCoordinator.begin_voice_switch(pair.first_user_id, destination)

      # Single-ledger math: 20 occupied - 2 exact Call Sessions + 1 held slot = 19.
      assert AdmissionCoordinator.effective_occupancy() == 19
      assert AdmissionCoordinator.reservation_count() == 1
      assert AdmissionCoordinator.held_switch_count() == 1

      gauges = AdmissionCoordinator.admission_gauges()
      assert gauges.occupancy == 19
      assert gauges.reservation_count == 1

      assert :ok = AdmissionCoordinator.abort_voice_switch(pair.first_user_id, plan.generation)
      assert AdmissionCoordinator.effective_occupancy() == 20

      assert :ok = AdmissionCoordinator.cleanup_active_pair(pair.call_id, reservation.generation)
    end

    test "mailbox length is measurable without blocking admission" do
      assert is_integer(AdmissionCoordinator.mailbox_length())
      assert AdmissionCoordinator.mailbox_length() >= 0

      gauges = AdmissionCoordinator.admission_gauges()
      assert is_integer(gauges.mailbox_len) and gauges.mailbox_len >= 0

      assert {:ok, _} =
               Voice.join(Ecto.UUID.generate(), Ecto.UUID.generate(), "mbox-join", self())

      assert is_integer(AdmissionCoordinator.mailbox_length())
    end
  end

  describe "allowlist" do
    test "telemetry never emits SDP, ICE, credentials, PIDs or raw identifiers" do
      pair = MediaFixtures.ringing_pair_fixture()
      MediaFixtures.start_ready_call_target(pair.call_id)

      sdp_sentinel = "application/sdp v=0 m=audio opus a=candidate ice-pwd-sentinel"
      ice_sentinel = "ice-ufrag-sentinel-credential-device_id-sentinel"
      raw_call_id = pair.call_id
      raw_user_id = pair.first_user_id
      test_pid = self()

      {_, handler_id} = attach_collector()

      try do
        # Perform real admission carrying the raw identifiers; telemetry must
        # not echo them.
        assert {:ok, reservation} =
                 AdmissionCoordinator.reserve_pair(
                   pair.call_id,
                   {pair.first_user_id, nil},
                   {pair.second_user_id, nil}
                 )

        MediaFixtures.set_attempt_connecting!(pair.call_id)
        assert {:ok, _} = AdmissionCoordinator.commit_pair(pair.call_id, reservation.generation)

        events = collect_events(handler_id)

        assert events != []

        for {operation, measurements, metadata} <- events do
          assert is_binary(operation)
          assert metadata.outcome in [:accepted, :rejected, :failed]

          text = inspect({operation, measurements, metadata})

          refute text =~ sdp_sentinel
          refute text =~ ice_sentinel
          refute text =~ raw_call_id
          refute text =~ raw_user_id
          refute text =~ inspect(test_pid)

          for fragment <- @sensitive_fragments do
            refute text =~ fragment
          end

          # Only allowlisted keys leave the runtime.
          assert Map.keys(metadata) -- [:operation, :outcome, :error_code] == []

          assert Map.keys(measurements) --
                   [:duration_ms, :occupancy, :reservation_count, :mailbox_len] == []

          for {_key, value} <- measurements do
            assert is_integer(value) and value >= 0
          end
        end

        assert :ok =
                 AdmissionCoordinator.cleanup_active_pair(pair.call_id, reservation.generation)
      after
        :telemetry.detach(handler_id)
      end
    end

    test "diagnostics emit drops unknown sensitive options and bounds error codes" do
      secret = "temporary-turn-credential-that-must-not-be-logged"

      logs =
        capture_log(fn ->
          AdmissionDiagnostics.emit("reserve_pair", :rejected,
            duration_ms: 12,
            occupancy: 20,
            reservation_count: 1,
            mailbox_len: 0,
            error_code: :deployment_full,
            provider_secret: secret,
            sdp: "application/sdp m=audio opus"
          )
        end)

      assert logs =~ "Media admission operation=reserve_pair"
      assert logs =~ "outcome=rejected"
      refute logs =~ secret
      refute logs =~ "application/sdp"
    end

    test "unknown operations and error codes never leak" do
      {_, handler_id} = attach_collector()

      try do
        AdmissionDiagnostics.emit("not_a_real_operation", :accepted, duration_ms: 5)
        AdmissionDiagnostics.emit("reserve_pair", :rejected, error_code: :super_secret_code)

        events = collect_events(handler_id)

        assert Enum.any?(events, fn {operation, _, _} -> operation == "unknown" end)

        for {_operation, _measurements, metadata} <- events do
          assert metadata.operation in AdmissionDiagnostics.operations()
          refute inspect(metadata) =~ "super_secret_code"
          refute inspect(metadata) =~ "not_a_real_operation"
        end
      after
        :telemetry.detach(handler_id)
      end
    end
  end

  describe "configuration agreement" do
    test "20-slot cap and UDP range stay in agreement and drift fails loudly" do
      assert DeploymentCapacity.max_active_sessions() == 20
      assert DeploymentCapacity.udp_port_range() == 50_000..50_031
      assert Range.size(DeploymentCapacity.udp_port_range()) >= 20

      assert DeploymentCapacity.valid_configuration?(
               DeploymentCapacity.udp_port_range(),
               DeploymentCapacity.max_active_sessions()
             )

      refute DeploymentCapacity.valid_configuration?(50_000..50_001, 20)
      refute DeploymentCapacity.valid_configuration?(50_000..50_031, 99)

      assert_raise ArgumentError, fn ->
        DeploymentCapacity.validate_configuration!(50_000..50_001, 20)
      end

      assert :ok = DeploymentCapacity.validate_configuration!(50_000..50_031, 20)
      assert :ok = DeploymentCapacity.validate_current_configuration()
    end
  end

  describe "no blocking work" do
    test "failing telemetry handler cannot change admission outcomes" do
      failing_id = {:admission_failing, System.unique_integer([:positive])}

      :ok =
        :telemetry.attach(failing_id, @event, fn _, _, _, _ -> raise "telemetry boom" end, nil)

      try do
        pair = MediaFixtures.ringing_pair_fixture()
        MediaFixtures.start_ready_call_target(pair.call_id)

        assert {:ok, reservation} =
                 AdmissionCoordinator.reserve_pair(
                   pair.call_id,
                   {pair.first_user_id, nil},
                   {pair.second_user_id, nil}
                 )

        MediaFixtures.set_attempt_connecting!(pair.call_id)
        assert {:ok, _} = AdmissionCoordinator.commit_pair(pair.call_id, reservation.generation)

        assert :ok =
                 AdmissionCoordinator.cleanup_active_pair(pair.call_id, reservation.generation)
      after
        :telemetry.detach(failing_id)
      end
    end

    test "slow telemetry handler never stalls the coordinator mailbox" do
      slow_id = {:admission_slow, System.unique_integer([:positive])}
      test_pid = self()

      :ok =
        :telemetry.attach(
          slow_id,
          @event,
          fn event, measurements, metadata, _ ->
            Process.sleep(50)
            send(test_pid, {:slow_seen, event, measurements, metadata})
          end,
          nil
        )

      try do
        pair = MediaFixtures.ringing_pair_fixture()
        MediaFixtures.start_ready_call_target(pair.call_id)

        commit_task =
          Task.async(fn ->
            {:ok, reservation} =
              AdmissionCoordinator.reserve_pair(
                pair.call_id,
                {pair.first_user_id, nil},
                {pair.second_user_id, nil}
              )

            MediaFixtures.set_attempt_connecting!(pair.call_id)
            {:ok, result} = AdmissionCoordinator.commit_pair(pair.call_id, reservation.generation)
            {reservation, result}
          end)

        # Unrelated Voice admission proceeds while the slow handler runs.
        assert {:ok, _} =
                 Voice.join(Ecto.UUID.generate(), Ecto.UUID.generate(), "slow-unrelated", self())

        {{reservation, _result}, _} =
          {Task.await(commit_task, 5_000), assert_received_telemetry_slow("reserve_pair")}

        assert :ok =
                 AdmissionCoordinator.cleanup_active_pair(pair.call_id, reservation.generation)
      after
        :telemetry.detach(slow_id)
      end
    end
  end

  defp assert_unavailable_abort_event(handler_id, user_id, generation) do
    assert_receive {:admission_event, ^handler_id, @event, measurements, metadata}

    assert metadata == %{
             operation: "abort_voice_switch",
             outcome: :failed,
             error_code: :unavailable
           }

    assert Map.keys(measurements) --
             [:duration_ms, :occupancy, :reservation_count, :mailbox_len] == []

    for {key, value} <- measurements do
      limit = if key == :duration_ms, do: 60_000, else: 1_000_000
      assert is_integer(value) and value >= 0 and value <= limit
    end

    refute inspect({measurements, metadata}) =~ user_id
    refute inspect({measurements, metadata}) =~ inspect(generation)
  end

  defp attach_collector do
    test_pid = self()
    handler_id = {:admission_collector, System.unique_integer([:positive])}

    :ok =
      :telemetry.attach(
        handler_id,
        @event,
        fn event, measurements, metadata, _ ->
          send(test_pid, {:admission_event, handler_id, event, measurements, metadata})
        end,
        nil
      )

    {test_pid, handler_id}
  end

  defp assert_received_telemetry(handler_id, operation, outcome, error_code) do
    deadline = System.monotonic_time(:millisecond) + 2_000
    await_telemetry(handler_id, operation, outcome, error_code, deadline)
  end

  defp await_telemetry(handler_id, operation, outcome, error_code, deadline) do
    receive do
      {:admission_event, ^handler_id, @event, measurements, metadata} ->
        if metadata.operation == operation and metadata.outcome == outcome and
             Map.get(metadata, :error_code) == error_code do
          assert is_integer(Map.get(measurements, :duration_ms, 0))
          :ok
        else
          if System.monotonic_time(:millisecond) < deadline do
            await_telemetry(handler_id, operation, outcome, error_code, deadline)
          else
            flunk(
              "missing telemetry #{operation} #{outcome} #{inspect(error_code)}, last saw #{inspect(metadata)}"
            )
          end
        end
    after
      200 ->
        if System.monotonic_time(:millisecond) < deadline do
          await_telemetry(handler_id, operation, outcome, error_code, deadline)
        else
          flunk("timed out waiting for telemetry #{operation} #{outcome}")
        end
    end
  end

  defp collect_events(handler_id) do
    collect_events(handler_id, [])
  end

  defp collect_events(handler_id, acc) do
    receive do
      {:admission_event, ^handler_id, @event, measurements, metadata} ->
        collect_events(handler_id, [{metadata.operation, measurements, metadata} | acc])
    after
      200 -> Enum.reverse(acc)
    end
  end

  defp flush_telemetry(handler_id) do
    receive do
      {:admission_event, ^handler_id, _, _, _} -> flush_telemetry(handler_id)
    after
      100 -> :ok
    end
  end

  defp assert_received_telemetry_slow(operation) do
    receive do
      {:slow_seen, @event, _measurements, %{operation: ^operation}} -> :ok
    after
      2_000 -> flunk("slow handler never saw #{operation}")
    end
  end
end
