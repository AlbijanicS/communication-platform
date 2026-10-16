defmodule DiscordClone.Media.PairAdmissionFailureTest do
  use DiscordClone.DataCase, async: false

  alias DiscordClone.Media.{AdmissionCoordinator, DirectCallTarget, Profile, Target}
  alias DiscordClone.MediaFixtures
  alias DiscordClone.Voice

  setup do
    on_exit(fn ->
      Voice.running_room_servers()
      |> Enum.each(fn {voice_channel_id, _room_server} ->
        :ok = Voice.end_channel_sessions(voice_channel_id)
        :ok = Voice.expire_idle_room(voice_channel_id)
      end)
    end)

    MediaFixtures.setup_coordinator_pair_state!()

    :ok
  end

  test "a failed-start callback can be cleaned repeatedly without a target process" do
    call_id = Ecto.UUID.generate()
    generation = make_ref()

    assert :ok = AdmissionCoordinator.call_target_starting(call_id, generation)
    assert :ok = AdmissionCoordinator.call_target_start_failed(call_id, generation, :unavailable)

    assert %{runtime_generation: ^generation, status: :failed, sessions: %{}} =
             AdmissionCoordinator.call_target_snapshot(call_id)

    assert :ok = AdmissionCoordinator.cleanup_active_pair_for_call(call_id)
    assert AdmissionCoordinator.call_target_snapshot(call_id) == nil
    assert :ok = AdmissionCoordinator.cleanup_active_pair_for_call(call_id)
    assert AdmissionCoordinator.call_target_snapshot(call_id) == nil
  end

  test "a target can restart over a failed-start claim without prior cleanup" do
    call_id = Ecto.UUID.generate()
    failed_generation = make_ref()
    assert :ok = AdmissionCoordinator.call_target_starting(call_id, failed_generation)

    assert :ok =
             AdmissionCoordinator.call_target_start_failed(
               call_id,
               failed_generation,
               :unavailable
             )

    target = MediaFixtures.start_ready_call_target(call_id)

    assert {:ok, %{runtime_generation: replacement_generation}} =
             DirectCallTarget.identity(target)

    refute replacement_generation == failed_generation

    assert %{runtime_generation: ^replacement_generation, status: :ready} =
             AdmissionCoordinator.call_target_snapshot(call_id)
  end

  test "late failed-start cleanup preserves a replacement runtime and its failure monitor" do
    call_id = Ecto.UUID.generate()

    assert {:error, :invalid_profile} =
             DirectCallTarget.start_link(
               call_id: call_id,
               profile: %Profile{kind: :direct_call, capacity: 3, topology: :one_to_one}
             )

    assert %{status: :failed, failure: %{kind: :startup, reason: :invalid_profile}} =
             AdmissionCoordinator.call_target_snapshot(call_id)

    {barrier, resume_begin} = MediaFixtures.pause_stale_target_cleanup(call_id)
    tasks = start_supervised!(Task.Supervisor)

    cleanup =
      Task.Supervisor.async_nolink(tasks, fn ->
        AdmissionCoordinator.cleanup_active_pair_for_call(call_id)
      end)

    try do
      assert_receive {:stale_target_cleanup_begun, ^barrier}, 2_000
      true = :erlang.suspend_process(cleanup.pid)
    after
      resume_begin.()
    end

    try do
      replacement = MediaFixtures.start_ready_call_target(call_id, restart: :temporary)
      assert {:ok, %{runtime_generation: generation}} = DirectCallTarget.identity(replacement)
      snapshot = AdmissionCoordinator.call_target_snapshot(call_id)

      true = :erlang.resume_process(cleanup.pid)
      assert :ok = Task.await(cleanup)
      assert AdmissionCoordinator.call_target_snapshot(call_id) == snapshot

      # A real DOWN must still reach the replacement's monitor after old cleanup.
      monitor = Process.monitor(replacement)
      Process.exit(replacement, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^replacement, :killed}
      _ = :sys.get_state(DiscordClone.Voice.SessionCoordinator)

      assert %{runtime_generation: ^generation, status: :failed, failure: %{kind: :target}} =
               AdmissionCoordinator.call_target_snapshot(call_id)

      assert :ok = AdmissionCoordinator.cleanup_active_pair_for_call(call_id)
      assert :ok = AdmissionCoordinator.cleanup_active_pair_for_call(call_id)
      assert AdmissionCoordinator.call_target_snapshot(call_id) == nil

      assert {:ok, _} =
               Voice.join(
                 Ecto.UUID.generate(),
                 Ecto.UUID.generate(),
                 "after-start-failure",
                 self()
               )
    after
      try do
        :erlang.resume_process(cleanup.pid)
      rescue
        ArgumentError -> :ok
      end
    end
  end

  test "failure before reservation mutates nothing" do
    pair = MediaFixtures.ringing_pair_fixture()
    MediaFixtures.start_ready_call_target(pair.call_id)
    first_channel = Ecto.UUID.generate()
    second_channel = Ecto.UUID.generate()

    assert {:ok, _} = Voice.join(first_channel, pair.first_user_id, "before-first", self())
    assert {:ok, _} = Voice.join(second_channel, pair.second_user_id, "before-second", self())

    first_prior = AdmissionCoordinator.current_identity(pair.first_user_id)
    second_prior = AdmissionCoordinator.current_identity(pair.second_user_id)

    assert {:error, :not_found} =
             AdmissionCoordinator.reserve_pair(
               Ecto.UUID.generate(),
               {pair.first_user_id, first_prior},
               {pair.second_user_id, second_prior}
             )

    assert {:ok, %{occupancy: 1}} = Voice.room_occupancy(first_channel)
    assert {:ok, %{occupancy: 1}} = Voice.room_occupancy(second_channel)
    assert AdmissionCoordinator.current_identity(pair.first_user_id) == first_prior
    assert AdmissionCoordinator.current_identity(pair.second_user_id) == second_prior
    assert target_sessions(pair.call_id) == %{}

    # No reservation leaked: a valid reservation still succeeds.
    assert {:ok, reservation} =
             AdmissionCoordinator.reserve_pair(
               pair.call_id,
               {pair.first_user_id, first_prior},
               {pair.second_user_id, second_prior}
             )

    assert :ok = AdmissionCoordinator.release_reservation(pair.call_id, reservation.generation)
  end

  test "failure after reservation but before retirement preserves Voices and releases slots" do
    pair = MediaFixtures.ringing_pair_fixture()
    MediaFixtures.start_ready_call_target(pair.call_id)
    first_channel = Ecto.UUID.generate()
    second_channel = Ecto.UUID.generate()

    assert {:ok, _} = Voice.join(first_channel, pair.first_user_id, "pre-first", self())
    assert {:ok, _} = Voice.join(second_channel, pair.second_user_id, "pre-second", self())

    first_prior = AdmissionCoordinator.current_identity(pair.first_user_id)
    second_prior = AdmissionCoordinator.current_identity(pair.second_user_id)

    assert {:ok, reservation} =
             AdmissionCoordinator.reserve_pair(
               pair.call_id,
               {pair.first_user_id, first_prior},
               {pair.second_user_id, second_prior}
             )

    # Durably still ringing, not connecting: commit must refuse before retirement.
    assert {:error, :not_connecting} =
             AdmissionCoordinator.commit_pair(pair.call_id, reservation.generation)

    assert {:ok, %{occupancy: 1}} = Voice.room_occupancy(first_channel)
    assert {:ok, %{occupancy: 1}} = Voice.room_occupancy(second_channel)
    assert AdmissionCoordinator.current_identity(pair.first_user_id) == first_prior
    assert AdmissionCoordinator.current_identity(pair.second_user_id) == second_prior
    assert target_sessions(pair.call_id) == %{}

    # Claim released: the committed generation is stale and a new pair can reserve.
    assert {:error, :stale_reservation} =
             AdmissionCoordinator.release_reservation(pair.call_id, reservation.generation)

    other = MediaFixtures.ringing_pair_fixture()
    MediaFixtures.start_ready_call_target(other.call_id)

    assert {:ok, other_reservation} =
             AdmissionCoordinator.reserve_pair(
               other.call_id,
               {other.first_user_id, nil},
               {other.second_user_id, nil}
             )

    assert :ok =
             AdmissionCoordinator.release_reservation(other.call_id, other_reservation.generation)
  end

  test "failure during first Voice retirement exposes no Call Session and releases the claim" do
    pair = MediaFixtures.ringing_pair_fixture()
    MediaFixtures.start_ready_call_target(pair.call_id)
    first_channel = Ecto.UUID.generate()
    second_channel = Ecto.UUID.generate()

    assert {:ok, _} = Voice.join(first_channel, pair.first_user_id, "retire-first", self())
    assert {:ok, _} = Voice.join(second_channel, pair.second_user_id, "retire-second", self())

    first_prior = AdmissionCoordinator.current_identity(pair.first_user_id)
    second_prior = AdmissionCoordinator.current_identity(pair.second_user_id)

    assert {:ok, reservation} =
             AdmissionCoordinator.reserve_pair(
               pair.call_id,
               {pair.first_user_id, first_prior},
               {pair.second_user_id, second_prior}
             )

    MediaFixtures.set_attempt_connecting!(pair.call_id)
    put_fault(%{retire_failures: [pair.first_user_id]})

    assert {:error, :unavailable} =
             AdmissionCoordinator.commit_pair(pair.call_id, reservation.generation)

    _ = :sys.get_state(Process.whereis(DiscordClone.Voice.SessionCoordinator))

    # Fault short-circuits before the real room call: both Voices survive.
    assert {:ok, %{occupancy: 1}} = Voice.room_occupancy(first_channel)
    assert {:ok, %{occupancy: 1}} = Voice.room_occupancy(second_channel)
    assert AdmissionCoordinator.current_identity(pair.first_user_id) == first_prior
    assert AdmissionCoordinator.current_identity(pair.second_user_id) == second_prior
    assert target_sessions(pair.call_id) == %{}

    other = MediaFixtures.ringing_pair_fixture()
    MediaFixtures.start_ready_call_target(other.call_id)

    assert {:ok, other_reservation} =
             AdmissionCoordinator.reserve_pair(
               other.call_id,
               {other.first_user_id, nil},
               {other.second_user_id, nil}
             )

    assert :ok =
             AdmissionCoordinator.release_reservation(other.call_id, other_reservation.generation)
  end

  test "failure during second Voice retirement never restores the first Voice Session" do
    pair = MediaFixtures.ringing_pair_fixture()
    MediaFixtures.start_ready_call_target(pair.call_id)
    first_channel = Ecto.UUID.generate()
    second_channel = Ecto.UUID.generate()

    assert {:ok, _} = Voice.join(first_channel, pair.first_user_id, "second-fail-first", self())

    assert {:ok, _} =
             Voice.join(second_channel, pair.second_user_id, "second-fail-second", self())

    second_prior = AdmissionCoordinator.current_identity(pair.second_user_id)

    assert {:ok, reservation} =
             AdmissionCoordinator.reserve_pair(
               pair.call_id,
               {pair.first_user_id, AdmissionCoordinator.current_identity(pair.first_user_id)},
               {pair.second_user_id, second_prior}
             )

    MediaFixtures.set_attempt_connecting!(pair.call_id)
    put_fault(%{retire_failures: [pair.second_user_id]})

    assert {:error, :unavailable} =
             AdmissionCoordinator.commit_pair(pair.call_id, reservation.generation)

    _ = :sys.get_state(Process.whereis(DiscordClone.Voice.SessionCoordinator))

    # First Voice was really retired and is never restored; second survives.
    assert {:ok, %{occupancy: 0}} = Voice.room_occupancy(first_channel)
    assert {:ok, %{occupancy: 1}} = Voice.room_occupancy(second_channel)
    assert AdmissionCoordinator.current_identity(pair.second_user_id) == second_prior

    refute match?(
             %{target: %Target{kind: :voice_channel}},
             AdmissionCoordinator.current_identity(pair.first_user_id)
           )

    assert target_sessions(pair.call_id) == %{}

    # First user is unpinned and can join again; nothing was auto-restored.
    assert {:ok, _} =
             Voice.join(Ecto.UUID.generate(), pair.first_user_id, "rejoin-after-fail", self())
  end

  test "failure between Call Session creations removes the created Session and releases the claim" do
    pair = MediaFixtures.ringing_pair_fixture()
    target = MediaFixtures.start_ready_call_target(pair.call_id)

    assert {:ok, reservation} =
             AdmissionCoordinator.reserve_pair(
               pair.call_id,
               {pair.first_user_id, nil},
               {pair.second_user_id, nil}
             )

    MediaFixtures.set_attempt_connecting!(pair.call_id)
    put_fault(%{admit_failures: [pair.second_user_id]})

    assert {:error, :target_unavailable} =
             AdmissionCoordinator.commit_pair(pair.call_id, reservation.generation)

    _ = :sys.get_state(Process.whereis(DiscordClone.Voice.SessionCoordinator))

    # The first created Session was removed; no per-User index ever became a Call.
    assert AdmissionCoordinator.current_identity(pair.first_user_id) == nil
    assert AdmissionCoordinator.current_identity(pair.second_user_id) == nil
    assert target_sessions(pair.call_id) == %{}
    assert {:ok, %{profile: _}} = DirectCallTarget.identity(target)

    other = MediaFixtures.ringing_pair_fixture()
    MediaFixtures.start_ready_call_target(other.call_id)

    assert {:ok, other_reservation} =
             AdmissionCoordinator.reserve_pair(
               other.call_id,
               {other.first_user_id, nil},
               {other.second_user_id, nil}
             )

    assert :ok =
             AdmissionCoordinator.release_reservation(other.call_id, other_reservation.generation)
  end

  test "a rogue occupant forces a begin revalidation abort without a fault seam" do
    pair = MediaFixtures.ringing_pair_fixture()
    target = MediaFixtures.start_ready_call_target(pair.call_id)

    assert {:ok, reservation} =
             AdmissionCoordinator.reserve_pair(
               pair.call_id,
               {pair.first_user_id, nil},
               {pair.second_user_id, nil}
             )

    # Occupant arrives after reservation but before commit: begin revalidates
    # a vacant target and aborts precommit with no Call Session exposed.
    assert {:ok, _} = DirectCallTarget.admit(target, Ecto.UUID.generate())
    MediaFixtures.set_attempt_connecting!(pair.call_id)

    assert {:error, %{reason: :target_unavailable}} =
             AdmissionCoordinator.commit_pair(pair.call_id, reservation.generation)

    _ = :sys.get_state(Process.whereis(DiscordClone.Voice.SessionCoordinator))
    assert AdmissionCoordinator.current_identity(pair.first_user_id) == nil
    assert AdmissionCoordinator.current_identity(pair.second_user_id) == nil
  end

  test "failure after both creations but before publication exposes no index" do
    pair = MediaFixtures.ringing_pair_fixture()
    MediaFixtures.start_ready_call_target(pair.call_id)

    assert {:ok, reservation} =
             AdmissionCoordinator.reserve_pair(
               pair.call_id,
               {pair.first_user_id, nil},
               {pair.second_user_id, nil}
             )

    MediaFixtures.set_attempt_connecting!(pair.call_id)
    put_fault(%{publish_failure: true})

    assert {:error, %{reason: :target_unavailable}} =
             AdmissionCoordinator.commit_pair(pair.call_id, reservation.generation)

    _ = :sys.get_state(Process.whereis(DiscordClone.Voice.SessionCoordinator))

    assert AdmissionCoordinator.current_identity(pair.first_user_id) == nil
    assert AdmissionCoordinator.current_identity(pair.second_user_id) == nil
    assert target_sessions(pair.call_id) == %{}

    other = MediaFixtures.ringing_pair_fixture()
    MediaFixtures.start_ready_call_target(other.call_id)

    assert {:ok, other_reservation} =
             AdmissionCoordinator.reserve_pair(
               other.call_id,
               {other.first_user_id, nil},
               {other.second_user_id, nil}
             )

    assert :ok =
             AdmissionCoordinator.release_reservation(other.call_id, other_reservation.generation)
  end

  test "cleanup after publication removes both sides, the runtime claim, and charged slots" do
    pair = MediaFixtures.ringing_pair_fixture()
    MediaFixtures.start_ready_call_target(pair.call_id)

    assert {:ok, reservation} =
             AdmissionCoordinator.reserve_pair(
               pair.call_id,
               {pair.first_user_id, nil},
               {pair.second_user_id, nil}
             )

    MediaFixtures.set_attempt_connecting!(pair.call_id)
    assert {:ok, result} = AdmissionCoordinator.commit_pair(pair.call_id, reservation.generation)
    assert map_size(result.call_sessions) == 2

    assert %Target{kind: :direct_call} =
             AdmissionCoordinator.current_identity(pair.first_user_id).target

    assert :ok = AdmissionCoordinator.cleanup_active_pair(pair.call_id, reservation.generation)
    _ = :sys.get_state(Process.whereis(DiscordClone.Voice.SessionCoordinator))

    assert AdmissionCoordinator.current_identity(pair.first_user_id) == nil
    assert AdmissionCoordinator.current_identity(pair.second_user_id) == nil
    assert AdmissionCoordinator.call_target_snapshot(pair.call_id) == nil

    # Slots freed: a new pair reserves and Voice admits up to capacity.
    other = MediaFixtures.ringing_pair_fixture()
    MediaFixtures.start_ready_call_target(other.call_id)

    assert {:ok, other_reservation} =
             AdmissionCoordinator.reserve_pair(
               other.call_id,
               {other.first_user_id, nil},
               {other.second_user_id, nil}
             )

    MediaFixtures.set_attempt_connecting!(other.call_id)

    assert {:ok, _} =
             AdmissionCoordinator.commit_pair(other.call_id, other_reservation.generation)

    assert :ok =
             AdmissionCoordinator.cleanup_active_pair(other.call_id, other_reservation.generation)

    assert {:ok, _} =
             Voice.join(Ecto.UUID.generate(), Ecto.UUID.generate(), "after-cleanup", self())
  end

  test "repeated cleanup and old Call IDs are harmless after a new target is admitted" do
    first = MediaFixtures.ringing_pair_fixture()
    MediaFixtures.start_ready_call_target(first.call_id)

    assert {:ok, first_reservation} =
             AdmissionCoordinator.reserve_pair(
               first.call_id,
               {first.first_user_id, nil},
               {first.second_user_id, nil}
             )

    MediaFixtures.set_attempt_connecting!(first.call_id)

    assert {:ok, _} =
             AdmissionCoordinator.commit_pair(first.call_id, first_reservation.generation)

    assert :ok =
             AdmissionCoordinator.cleanup_active_pair(first.call_id, first_reservation.generation)

    assert :ok =
             AdmissionCoordinator.cleanup_active_pair(first.call_id, first_reservation.generation)

    second = MediaFixtures.ringing_pair_fixture()
    MediaFixtures.start_ready_call_target(second.call_id)

    assert {:ok, second_reservation} =
             AdmissionCoordinator.reserve_pair(
               second.call_id,
               {second.first_user_id, nil},
               {second.second_user_id, nil}
             )

    MediaFixtures.set_attempt_connecting!(second.call_id)

    assert {:ok, second_result} =
             AdmissionCoordinator.commit_pair(second.call_id, second_reservation.generation)

    # Late and repeated cleanups for the old Call ID cannot touch the current target.
    assert :ok =
             AdmissionCoordinator.cleanup_active_pair(first.call_id, first_reservation.generation)

    assert {:error, :stale_call} =
             AdmissionCoordinator.release_active_call(first.call_id, first_reservation.generation)

    assert :ok =
             AdmissionCoordinator.call_session_removed(
               first.call_id,
               second_result.target_runtime_generation,
               first.first_user_id,
               Ecto.UUID.generate()
             )

    _ = :sys.get_state(Process.whereis(DiscordClone.Voice.SessionCoordinator))

    assert AdmissionCoordinator.current_identity(second.first_user_id).session_id ==
             second_result.call_sessions[second.first_user_id]

    assert AdmissionCoordinator.current_identity(second.second_user_id).session_id ==
             second_result.call_sessions[second.second_user_id]

    assert map_size(AdmissionCoordinator.call_target_snapshot(second.call_id).sessions) == 2

    assert :ok =
             AdmissionCoordinator.cleanup_active_pair(
               second.call_id,
               second_reservation.generation
             )
  end

  test "a stale Call Session removal cannot clear the published pair" do
    pair = MediaFixtures.ringing_pair_fixture()
    MediaFixtures.start_ready_call_target(pair.call_id)

    assert {:ok, reservation} =
             AdmissionCoordinator.reserve_pair(
               pair.call_id,
               {pair.first_user_id, nil},
               {pair.second_user_id, nil}
             )

    MediaFixtures.set_attempt_connecting!(pair.call_id)
    assert {:ok, result} = AdmissionCoordinator.commit_pair(pair.call_id, reservation.generation)

    # Wrong generation, wrong user, and unknown session are all ignored.
    assert :ok =
             AdmissionCoordinator.call_session_removed(
               pair.call_id,
               make_ref(),
               pair.first_user_id,
               result.call_sessions[pair.first_user_id]
             )

    assert :ok =
             AdmissionCoordinator.call_session_removed(
               pair.call_id,
               result.target_runtime_generation,
               pair.second_user_id,
               result.call_sessions[pair.first_user_id]
             )

    assert :ok =
             AdmissionCoordinator.call_session_removed(
               pair.call_id,
               result.target_runtime_generation,
               pair.first_user_id,
               Ecto.UUID.generate()
             )

    _ = :sys.get_state(Process.whereis(DiscordClone.Voice.SessionCoordinator))

    assert AdmissionCoordinator.current_identity(pair.first_user_id).session_id ==
             result.call_sessions[pair.first_user_id]

    assert AdmissionCoordinator.current_identity(pair.second_user_id).session_id ==
             result.call_sessions[pair.second_user_id]

    assert :ok = AdmissionCoordinator.cleanup_active_pair(pair.call_id, reservation.generation)
  end

  test "late failures from a replaced runtime cannot affect its replacement pair" do
    pair = MediaFixtures.ringing_pair_fixture()
    first_target = MediaFixtures.start_ready_call_target(pair.call_id, restart: :temporary)
    assert {:ok, %{runtime_generation: old_generation}} = DirectCallTarget.identity(first_target)

    assert {:ok, %{call_session_id: old_session}} =
             DirectCallTarget.admit(first_target, pair.first_user_id)

    assert :ok = DirectCallTarget.shutdown(first_target)
    assert :ok = AdmissionCoordinator.cleanup_active_pair_for_call(pair.call_id)

    MediaFixtures.start_ready_call_target(pair.call_id, id: {:replacement_target, pair.call_id})

    assert {:ok, replacement_reservation} =
             AdmissionCoordinator.reserve_pair(
               pair.call_id,
               {pair.first_user_id, nil},
               {pair.second_user_id, nil}
             )

    MediaFixtures.set_attempt_connecting!(pair.call_id)

    assert {:ok, replacement_result} =
             AdmissionCoordinator.commit_pair(pair.call_id, replacement_reservation.generation)

    refute old_generation == replacement_result.target_runtime_generation
    first_identity = AdmissionCoordinator.current_identity(pair.first_user_id)
    second_identity = AdmissionCoordinator.current_identity(pair.second_user_id)
    snapshot = AdmissionCoordinator.call_target_snapshot(pair.call_id)

    assert :ok =
             AdmissionCoordinator.call_target_failed(
               pair.call_id,
               old_generation,
               :late_old_target
             )

    assert :ok =
             AdmissionCoordinator.call_session_failed(
               pair.call_id,
               old_generation,
               pair.first_user_id,
               old_session,
               :late_old_session
             )

    assert AdmissionCoordinator.current_identity(pair.first_user_id) == first_identity
    assert AdmissionCoordinator.current_identity(pair.second_user_id) == second_identity
    assert AdmissionCoordinator.call_target_snapshot(pair.call_id) == snapshot

    assert :ok =
             AdmissionCoordinator.cleanup_active_pair(
               pair.call_id,
               replacement_reservation.generation
             )
  end

  test "a newer reservation survives a late expiry for the previous generation" do
    pair = MediaFixtures.ringing_pair_fixture()
    MediaFixtures.start_ready_call_target(pair.call_id)
    coordinator = Process.whereis(DiscordClone.Voice.SessionCoordinator)

    assert {:ok, first} =
             AdmissionCoordinator.reserve_pair(
               pair.call_id,
               {pair.first_user_id, nil},
               {pair.second_user_id, nil}
             )

    send(coordinator, {:reservation_expired, pair.call_id, first.generation})
    _ = :sys.get_state(coordinator)

    assert {:ok, second} =
             AdmissionCoordinator.reserve_pair(
               pair.call_id,
               {pair.first_user_id, nil},
               {pair.second_user_id, nil}
             )

    # Late redelivery of the old expiry cannot clear the newer reservation.
    send(coordinator, {:reservation_expired, pair.call_id, first.generation})
    _ = :sys.get_state(coordinator)

    assert {:error, %{reason: :reservation_conflict}} =
             Voice.join(Ecto.UUID.generate(), pair.first_user_id, "still-pinned", self())

    assert :ok = AdmissionCoordinator.release_reservation(pair.call_id, second.generation)
  end

  test "a late Voice leave cannot clear an active Direct Call" do
    pair = MediaFixtures.ringing_pair_fixture()
    MediaFixtures.start_ready_call_target(pair.call_id)
    channel = Ecto.UUID.generate()

    assert {:ok, %{voice_session_id: old_voice_session_id}} =
             Voice.join(channel, pair.first_user_id, "old-voice", self())

    prior = AdmissionCoordinator.current_identity(pair.first_user_id)

    assert {:ok, reservation} =
             AdmissionCoordinator.reserve_pair(
               pair.call_id,
               {pair.first_user_id, prior},
               {pair.second_user_id, nil}
             )

    MediaFixtures.set_attempt_connecting!(pair.call_id)
    assert {:ok, result} = AdmissionCoordinator.commit_pair(pair.call_id, reservation.generation)

    assert :ok = AdmissionCoordinator.leave(channel, old_voice_session_id)
    _ = :sys.get_state(Process.whereis(DiscordClone.Voice.SessionCoordinator))

    assert AdmissionCoordinator.current_identity(pair.first_user_id).session_id ==
             result.call_sessions[pair.first_user_id]

    assert :ok = AdmissionCoordinator.cleanup_active_pair(pair.call_id, reservation.generation)
  end

  test "Voice Channel failure invalidates only that exact runtime" do
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

    first_channel = Ecto.UUID.generate()
    second_channel = Ecto.UUID.generate()

    assert {:ok, %{voice_session_id: first_session_id}} =
             Voice.join(first_channel, Ecto.UUID.generate(), "room-a", self())

    assert {:ok, %{voice_session_id: _}} =
             Voice.join(second_channel, Ecto.UUID.generate(), "room-b", self())

    {^first_channel, room_server} =
      Enum.find(Voice.running_room_servers(), fn {id, _} -> id == first_channel end)

    monitor = Process.monitor(room_server)
    Process.exit(room_server, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^room_server, _}
    _ = :sys.get_state(Process.whereis(DiscordClone.Voice.SessionCoordinator))
    _ = :sys.get_state(Process.whereis(DiscordClone.Voice.SessionCoordinator))

    # Killed room is gone; the other room and the Direct Call continue.
    assert Voice.room_occupancy(first_channel) in [
             {:ok, %{occupancy: 0, capacity: 5}},
             {:error, :not_found}
           ]

    assert {:ok, %{occupancy: 1}} = Voice.room_occupancy(second_channel)

    # Direct Call continues with both indexes intact.
    assert %Target{kind: :direct_call} =
             AdmissionCoordinator.current_identity(pair.first_user_id).target

    assert %Target{kind: :direct_call} =
             AdmissionCoordinator.current_identity(pair.second_user_id).target

    assert first_session_id != nil

    assert :ok = AdmissionCoordinator.cleanup_active_pair(pair.call_id, reservation.generation)
  end

  test "target failure ends the published pair coherently" do
    pair = MediaFixtures.ringing_pair_fixture()
    target = MediaFixtures.start_ready_call_target(pair.call_id)

    assert {:ok, reservation} =
             AdmissionCoordinator.reserve_pair(
               pair.call_id,
               {pair.first_user_id, nil},
               {pair.second_user_id, nil}
             )

    MediaFixtures.set_attempt_connecting!(pair.call_id)
    assert {:ok, result} = AdmissionCoordinator.commit_pair(pair.call_id, reservation.generation)

    {:ok, %{runtime_generation: generation}} = DirectCallTarget.identity(target)
    assert generation == result.target_runtime_generation

    assert :ok = AdmissionCoordinator.call_target_failed(pair.call_id, generation, :boom)
    _ = :sys.get_state(Process.whereis(DiscordClone.Voice.SessionCoordinator))

    assert AdmissionCoordinator.current_identity(pair.first_user_id) == nil
    assert AdmissionCoordinator.current_identity(pair.second_user_id) == nil

    # Failure hides both active projections, but retains ownership of live Sessions.
    other = MediaFixtures.ringing_pair_fixture()
    MediaFixtures.start_ready_call_target(other.call_id)

    assert {:error, %{reason: :reservation_conflict}} =
             AdmissionCoordinator.reserve_pair(
               other.call_id,
               {other.first_user_id, nil},
               {other.second_user_id, nil}
             )

    assert AdmissionCoordinator.effective_occupancy() == 2
    assert :ok = AdmissionCoordinator.cleanup_active_pair(pair.call_id, reservation.generation)

    assert {:ok, other_reservation} =
             AdmissionCoordinator.reserve_pair(
               other.call_id,
               {other.first_user_id, nil},
               {other.second_user_id, nil}
             )

    assert :ok =
             AdmissionCoordinator.release_reservation(other.call_id, other_reservation.generation)
  end

  test "removing one Call Session ends both indexes without restoring Voice" do
    pair = MediaFixtures.ringing_pair_fixture()
    target = MediaFixtures.start_ready_call_target(pair.call_id)

    assert {:ok, reservation} =
             AdmissionCoordinator.reserve_pair(
               pair.call_id,
               {pair.first_user_id, nil},
               {pair.second_user_id, nil}
             )

    MediaFixtures.set_attempt_connecting!(pair.call_id)
    assert {:ok, result} = AdmissionCoordinator.commit_pair(pair.call_id, reservation.generation)

    first_session = result.call_sessions[pair.first_user_id]
    assert :ok = DirectCallTarget.remove(target, pair.first_user_id, first_session)
    _ = :sys.get_state(Process.whereis(DiscordClone.Voice.SessionCoordinator))
    _ = :sys.get_state(Process.whereis(DiscordClone.Voice.SessionCoordinator))

    assert AdmissionCoordinator.current_identity(pair.first_user_id) == nil
    assert AdmissionCoordinator.current_identity(pair.second_user_id) == nil
  end

  test "pair commit races Voice joins without a half-pair or over-capacity" do
    pair = MediaFixtures.ringing_pair_fixture()
    MediaFixtures.start_ready_call_target(pair.call_id)
    channel = Ecto.UUID.generate()

    assert {:ok, _} = Voice.join(channel, pair.first_user_id, "race-prior", self())

    prior = AdmissionCoordinator.current_identity(pair.first_user_id)

    assert {:ok, reservation} =
             AdmissionCoordinator.reserve_pair(
               pair.call_id,
               {pair.first_user_id, prior},
               {pair.second_user_id, nil}
             )

    MediaFixtures.set_attempt_connecting!(pair.call_id)
    room_server = room_server(channel)
    :ok = :sys.suspend(room_server)
    parent = self()
    coordinator = Process.whereis(DiscordClone.Voice.SessionCoordinator)
    _ = coordinator

    commit_task =
      Task.async(fn -> AdmissionCoordinator.commit_pair(pair.call_id, reservation.generation) end)

    join_task =
      Task.async(fn ->
        Voice.join(Ecto.UUID.generate(), pair.first_user_id, "racing-pinned", parent)
      end)

    unrelated_task =
      Task.async(fn ->
        Voice.join(Ecto.UUID.generate(), Ecto.UUID.generate(), "racing-unrelated", parent)
      end)

    assert {:error, %{reason: :reservation_conflict}} = Task.await(join_task, 10_000)
    assert {:ok, _} = Task.await(unrelated_task, 10_000)

    :ok = :sys.resume(room_server)
    assert {:ok, result} = Task.await(commit_task, 10_000)
    assert map_size(result.call_sessions) == 2

    assert AdmissionCoordinator.current_identity(pair.first_user_id).session_id ==
             result.call_sessions[pair.first_user_id]

    assert AdmissionCoordinator.current_identity(pair.second_user_id).session_id ==
             result.call_sessions[pair.second_user_id]

    assert :ok = AdmissionCoordinator.cleanup_active_pair(pair.call_id, reservation.generation)
  end

  test "failed commit cleanup retains surviving Sessions and the guard after a removal timeout at capacity" do
    pair = MediaFixtures.ringing_pair_fixture()
    target = MediaFixtures.start_ready_call_target(pair.call_id)
    channels = Enum.map(1..4, fn _ -> Ecto.UUID.generate() end)
    first_channel = Ecto.UUID.generate()
    second_channel = Ecto.UUID.generate()
    assert {:ok, _} = Voice.join(first_channel, pair.first_user_id, "abort-first", self())
    assert {:ok, _} = Voice.join(second_channel, pair.second_user_id, "abort-second", self())

    for index <- 1..18 do
      assert {:ok, _} =
               Voice.join(
                 Enum.at(channels, div(index - 1, 5)),
                 Ecto.UUID.generate(),
                 "abort-#{index}",
                 self()
               )
    end

    assert {:ok, reservation} =
             AdmissionCoordinator.reserve_pair(
               pair.call_id,
               {pair.first_user_id, AdmissionCoordinator.current_identity(pair.first_user_id)},
               {pair.second_user_id, AdmissionCoordinator.current_identity(pair.second_user_id)}
             )

    other = MediaFixtures.ringing_pair_fixture()
    MediaFixtures.start_ready_call_target(other.call_id)
    MediaFixtures.set_attempt_connecting!(pair.call_id)
    put_fault(%{publish_failure: true})
    {barrier, resume} = MediaFixtures.pause_after_first_call_removal(target)
    tasks = start_supervised!(Task.Supervisor)

    commit =
      Task.Supervisor.async_nolink(tasks, fn ->
        AdmissionCoordinator.commit_pair(pair.call_id, reservation.generation)
      end)

    try do
      assert_receive {:first_call_session_removed, ^barrier}, 2_000
      assert map_size(AdmissionCoordinator.call_target_snapshot(pair.call_id).sessions) == 1
      assert AdmissionCoordinator.effective_occupancy() == 20

      assert {:error, %{reason: :deployment_full, occupancy: 20}} =
               Voice.join(Ecto.UUID.generate(), Ecto.UUID.generate(), "abort-full", self())

      assert {:error, %{reason: :reservation_conflict}} =
               AdmissionCoordinator.reserve_pair(
                 other.call_id,
                 {other.first_user_id, nil},
                 {other.second_user_id, nil}
               )

      assert {:error, %{reason: :target_unavailable}} = Task.await(commit, 15_000)

      assert {:error, %{reason: :reservation_conflict}} =
               AdmissionCoordinator.reserve_pair(
                 other.call_id,
                 {other.first_user_id, nil},
                 {other.second_user_id, nil}
               )

      assert AdmissionCoordinator.effective_occupancy() == 19

      assert {:error, %{reason: :reservation_conflict}} =
               Voice.join(Ecto.UUID.generate(), pair.first_user_id, "abort-pinned", self())

      assert {:ok, %{occupancy: 0}} = Voice.room_occupancy(first_channel)
      assert {:ok, %{occupancy: 0}} = Voice.room_occupancy(second_channel)
    after
      resume.()
    end

    assert :ok = AdmissionCoordinator.cleanup_active_pair_for_call(pair.call_id)
    assert AdmissionCoordinator.effective_occupancy() == 18

    assert {:ok, next} =
             AdmissionCoordinator.reserve_pair(
               other.call_id,
               {other.first_user_id, nil},
               {other.second_user_id, nil}
             )

    assert :ok = AdmissionCoordinator.release_reservation(other.call_id, next.generation)
  end

  test "a timed out terminal cleanup retains ownership until the surviving Session is confirmed gone" do
    pair = MediaFixtures.ringing_pair_fixture()
    target = MediaFixtures.start_ready_call_target(pair.call_id)

    assert {:ok, reservation} =
             AdmissionCoordinator.reserve_pair(
               pair.call_id,
               {pair.first_user_id, nil},
               {pair.second_user_id, nil}
             )

    MediaFixtures.set_attempt_connecting!(pair.call_id)
    assert {:ok, _} = AdmissionCoordinator.commit_pair(pair.call_id, reservation.generation)
    other = MediaFixtures.ringing_pair_fixture()
    MediaFixtures.start_ready_call_target(other.call_id)
    {barrier, resume} = MediaFixtures.pause_after_first_call_removal(target)
    tasks = start_supervised!(Task.Supervisor)

    cleanup =
      Task.Supervisor.async_nolink(tasks, fn ->
        AdmissionCoordinator.cleanup_active_pair(pair.call_id, reservation.generation)
      end)

    try do
      assert_receive {:first_call_session_removed, ^barrier}, 2_000
      assert :ok = Task.await(cleanup, 15_000)

      assert {:error, %{reason: :reservation_conflict}} =
               AdmissionCoordinator.reserve_pair(
                 other.call_id,
                 {other.first_user_id, nil},
                 {other.second_user_id, nil}
               )

      assert map_size(AdmissionCoordinator.call_target_snapshot(pair.call_id).sessions) == 1
      assert AdmissionCoordinator.effective_occupancy() == 1
    after
      resume.()
    end

    assert :ok = AdmissionCoordinator.cleanup_active_pair(pair.call_id, reservation.generation)
    assert :ok = AdmissionCoordinator.cleanup_active_pair(pair.call_id, reservation.generation)
    assert AdmissionCoordinator.call_target_snapshot(pair.call_id) == nil

    assert {:ok, next} =
             AdmissionCoordinator.reserve_pair(
               other.call_id,
               {other.first_user_id, nil},
               {other.second_user_id, nil}
             )

    assert :ok = AdmissionCoordinator.release_reservation(other.call_id, next.generation)
  end

  test "an old cleanup finishing after runtime replacement cannot drop the new pair claim" do
    pair = MediaFixtures.ringing_pair_fixture()
    target = MediaFixtures.start_ready_call_target(pair.call_id, restart: :temporary)

    assert {:ok, reservation} =
             AdmissionCoordinator.reserve_pair(
               pair.call_id,
               {pair.first_user_id, nil},
               {pair.second_user_id, nil}
             )

    MediaFixtures.set_attempt_connecting!(pair.call_id)

    assert {:ok, old_pair} =
             AdmissionCoordinator.commit_pair(pair.call_id, reservation.generation)

    {barrier, resume_target} = MediaFixtures.pause_after_first_call_removal(target)
    tasks = start_supervised!(Task.Supervisor)

    cleanup =
      Task.Supervisor.async_nolink(tasks, fn ->
        AdmissionCoordinator.cleanup_active_pair(pair.call_id, reservation.generation)
      end)

    assert_receive {:first_call_session_removed, ^barrier}, 2_000
    true = :erlang.suspend_process(cleanup.pid)

    try do
      monitor = Process.monitor(target)
      Process.exit(target, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^target, _}
      assert :ok = AdmissionCoordinator.cleanup_active_pair(pair.call_id, reservation.generation)

      # Recreate the fixture's ringing boundary for another runtime generation.
      pair.call_id
      |> then(&Repo.get!(DiscordClone.Calls.CallAttempt, &1))
      |> Ecto.Changeset.change(state: :ringing, accepted_at: nil)
      |> Repo.update!()

      MediaFixtures.start_ready_call_target(pair.call_id, id: {:replacement_target, pair.call_id})

      assert {:ok, replacement} =
               AdmissionCoordinator.reserve_pair(
                 pair.call_id,
                 {pair.first_user_id, nil},
                 {pair.second_user_id, nil}
               )

      MediaFixtures.set_attempt_connecting!(pair.call_id)

      assert {:ok, result} =
               AdmissionCoordinator.commit_pair(pair.call_id, replacement.generation)

      snapshot = AdmissionCoordinator.call_target_snapshot(pair.call_id)

      assert :ok =
               AdmissionCoordinator.call_session_removed(
                 pair.call_id,
                 old_pair.target_runtime_generation,
                 pair.second_user_id,
                 old_pair.call_sessions[pair.second_user_id]
               )

      assert :ok =
               AdmissionCoordinator.call_target_stopped(
                 pair.call_id,
                 old_pair.target_runtime_generation
               )

      assert :ok = AdmissionCoordinator.cleanup_active_pair(pair.call_id, reservation.generation)
      assert AdmissionCoordinator.call_target_snapshot(pair.call_id) == snapshot

      true = :erlang.resume_process(cleanup.pid)
      assert :ok = Task.await(cleanup)
      assert AdmissionCoordinator.call_target_snapshot(pair.call_id) == snapshot

      assert AdmissionCoordinator.current_identity(pair.first_user_id).session_id ==
               result.call_sessions[pair.first_user_id]

      assert AdmissionCoordinator.current_identity(pair.second_user_id).session_id ==
               result.call_sessions[pair.second_user_id]

      assert :ok = AdmissionCoordinator.cleanup_active_pair(pair.call_id, replacement.generation)
    after
      resume_target.()

      try do
        :erlang.resume_process(cleanup.pid)
      rescue
        ArgumentError -> :ok
      end
    end
  end

  defp put_fault(faults) do
    Application.put_env(:discord_clone, :pair_commit_fault, faults)
  end

  defp target_sessions(call_id) do
    case AdmissionCoordinator.call_target_snapshot(call_id) do
      nil -> %{}
      snapshot -> snapshot.sessions
    end
  end

  defp room_server(voice_channel_id) do
    {^voice_channel_id, room_server} =
      Enum.find(Voice.running_room_servers(), fn {id, _pid} -> id == voice_channel_id end)

    room_server
  end
end
