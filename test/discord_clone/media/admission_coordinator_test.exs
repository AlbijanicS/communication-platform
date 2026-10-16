defmodule DiscordClone.Media.AdmissionCoordinatorTest do
  use DiscordClone.DataCase, async: false

  import DiscordClone.AccountsFixtures

  alias DiscordClone.Media.AdmissionCoordinator
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

    :ok
  end

  test "a delayed Voice Session removal keeps a replacement in the same runtime" do
    voice_channel_id = Ecto.UUID.generate()
    user_id = Ecto.UUID.generate()

    assert {:ok, %{voice_session_id: old_session_id}} =
             Voice.join(voice_channel_id, user_id, "old-connection", self())

    {^voice_channel_id, room_server} =
      Enum.find(Voice.running_room_servers(), fn {id, _pid} -> id == voice_channel_id end)

    assert {:ok, %{voice_session_id: new_session_id} = joined} =
             Voice.join(voice_channel_id, user_id, "new-connection", self())

    refute new_session_id == old_session_id

    :ok =
      AdmissionCoordinator.session_removed(voice_channel_id, user_id, old_session_id, room_server)

    _ = :sys.get_state(DiscordClone.Voice.SessionCoordinator)

    assert {:ok, ^joined} = Voice.join(voice_channel_id, user_id, "new-connection", self())
    assert {:ok, %{occupancy: 1, capacity: 5}} = Voice.room_occupancy(voice_channel_id)
  end

  test "a removal from a retired Voice runtime keeps the current Session" do
    voice_channel_id = Ecto.UUID.generate()
    user_id = Ecto.UUID.generate()

    assert {:ok, %{voice_session_id: old_session_id}} =
             Voice.join(voice_channel_id, user_id, "old-runtime", self())

    {^voice_channel_id, old_room_server} =
      Enum.find(Voice.running_room_servers(), fn {id, _pid} -> id == voice_channel_id end)

    old_forwarder = :sys.get_state(old_room_server).forwarder
    old_tree = :sys.get_state(old_room_server).room_supervisor
    tree_monitor = Process.monitor(old_tree)
    assert :ok = Voice.leave(voice_channel_id, old_session_id)
    old_monitor = Process.monitor(old_room_server)
    assert :ok = Voice.expire_idle_room(voice_channel_id)
    assert_receive {:DOWN, ^old_monitor, :process, ^old_room_server, _reason}
    assert_receive {:DOWN, ^tree_monitor, :process, ^old_tree, _reason}

    assert {:ok, %{voice_session_id: new_session_id} = joined} =
             Voice.join(voice_channel_id, user_id, "new-runtime", self())

    :ok =
      AdmissionCoordinator.session_removed(
        voice_channel_id,
        user_id,
        new_session_id,
        old_room_server
      )

    _ = :sys.get_state(DiscordClone.Voice.SessionCoordinator)

    assert %{session_id: ^new_session_id} =
             current_identity = AdmissionCoordinator.current_identity(user_id)

    AdmissionCoordinator.room_server_started(voice_channel_id, old_room_server)
    AdmissionCoordinator.forwarder_started(voice_channel_id, old_forwarder, old_room_server)
    assert AdmissionCoordinator.current_identity(user_id) == current_identity

    assert {:ok, ^joined} = Voice.join(voice_channel_id, user_id, "new-runtime", self())
    assert {:ok, %{occupancy: 1, capacity: 5}} = Voice.room_occupancy(voice_channel_id)
  end

  test "a pair reservation charges two slots while preserving an exact prior Voice Session" do
    pair = MediaFixtures.ringing_pair_fixture()
    MediaFixtures.start_ready_call_target(pair.call_id)
    user_id = pair.first_user_id
    other_user_id = pair.second_user_id
    voice_channel_id = Ecto.UUID.generate()

    assert {:ok, %{voice_session_id: session_id}} =
             Voice.join(voice_channel_id, user_id, "prior", self())

    prior = AdmissionCoordinator.current_identity(user_id)
    assert prior.session_id == session_id

    assert {:ok, reservation} =
             AdmissionCoordinator.reserve_pair(
               pair.call_id,
               {user_id, prior},
               {other_user_id, nil}
             )

    assert reservation.call_id == pair.call_id
    assert reservation.user_ids == [user_id, other_user_id]
    assert reservation.prior_identities == %{user_id => prior, other_user_id => nil}
    assert reservation.slots == 2
    assert is_reference(reservation.generation)
    assert {:ok, %{occupancy: 1}} = Voice.room_occupancy(voice_channel_id)

    assert {:error, %{reason: :reservation_conflict}} =
             Voice.join(Ecto.UUID.generate(), user_id, "move", self())

    assert :ok = AdmissionCoordinator.release_reservation(pair.call_id, reservation.generation)
  end

  test "projected capacity credits only exact Voice Sessions across the 20-slot matrix" do
    channels = Enum.map(1..4, fn _ -> Ecto.UUID.generate() end)

    first = user_fixture()
    second = user_fixture()
    outsider = user_fixture()
    none_user = user_fixture()

    none_pair = MediaFixtures.ringing_pair_fixture(none_user, outsider)
    one_pair = MediaFixtures.ringing_pair_fixture(first, outsider)
    two_pair = MediaFixtures.ringing_pair_fixture(first, second)
    Enum.each([none_pair, one_pair, two_pair], &MediaFixtures.start_ready_call_target(&1.call_id))

    users = [first.id, second.id] ++ Enum.map(1..16, fn _ -> Ecto.UUID.generate() end)

    Enum.each(0..17, fn index ->
      assert {:ok, _} =
               Voice.join(
                 Enum.at(channels, div(index, 5)),
                 Enum.at(users, index),
                 "matrix-#{index}",
                 self()
               )
    end)

    none = {none_user.id, nil}

    assert {:ok, at_eighteen} =
             AdmissionCoordinator.reserve_pair(none_pair.call_id, none, {outsider.id, nil})

    assert :ok =
             AdmissionCoordinator.release_reservation(at_eighteen.call_id, at_eighteen.generation)

    assert {:ok, _} =
             Voice.join(Enum.at(channels, 3), Ecto.UUID.generate(), "matrix-18", self())

    assert {:error, %{reason: :deployment_full, occupancy: 21}} =
             AdmissionCoordinator.reserve_pair(none_pair.call_id, none, {outsider.id, nil})

    assert {:ok, one_credit} =
             AdmissionCoordinator.reserve_pair(
               one_pair.call_id,
               {first.id, AdmissionCoordinator.current_identity(first.id)},
               {outsider.id, nil}
             )

    assert :ok =
             AdmissionCoordinator.release_reservation(one_credit.call_id, one_credit.generation)

    assert {:ok, _} =
             Voice.join(Enum.at(channels, 3), Ecto.UUID.generate(), "matrix-19", self())

    assert {:error, %{reason: :deployment_full, occupancy: 21}} =
             AdmissionCoordinator.reserve_pair(
               one_pair.call_id,
               {first.id, AdmissionCoordinator.current_identity(first.id)},
               {outsider.id, nil}
             )

    assert {:ok, two_credits} =
             AdmissionCoordinator.reserve_pair(
               two_pair.call_id,
               {first.id, AdmissionCoordinator.current_identity(first.id)},
               {second.id, AdmissionCoordinator.current_identity(second.id)}
             )

    assert {:error, %{reason: :reservation_conflict}} =
             AdmissionCoordinator.reserve_pair(none_pair.call_id, none, {outsider.id, nil})

    assert {:error, %{reason: :deployment_full}} =
             Voice.join(Ecto.UUID.generate(), outsider.id, "over-capacity", self())

    assert :ok =
             AdmissionCoordinator.mark_commit_started(two_credits.call_id, two_credits.generation)

    assert :ok =
             Voice.leave(
               Enum.at(channels, 0),
               AdmissionCoordinator.current_identity(first.id).session_id
             )

    assert :ok =
             Voice.leave(
               Enum.at(channels, 0),
               AdmissionCoordinator.current_identity(second.id).session_id
             )

    assert :ok =
             AdmissionCoordinator.activate_reservation(
               two_credits.call_id,
               two_credits.generation
             )

    assert {:error, %{reason: :deployment_full}} =
             Voice.join(Ecto.UUID.generate(), outsider.id, "active-over-capacity", self())

    assert :ok =
             AdmissionCoordinator.release_active_call(two_credits.call_id, two_credits.generation)

    assert {:ok, _} =
             Voice.join(Ecto.UUID.generate(), outsider.id, "after-call-release", self())
  end

  test "stale prior identities cannot earn credit or pin Users" do
    pair = MediaFixtures.ringing_pair_fixture()
    MediaFixtures.start_ready_call_target(pair.call_id)
    user_id = pair.first_user_id
    other_user_id = pair.second_user_id
    voice_channel_id = Ecto.UUID.generate()
    assert {:ok, _} = Voice.join(voice_channel_id, user_id, "stale-one", self())
    stale = AdmissionCoordinator.current_identity(user_id)
    assert {:ok, _} = Voice.join(voice_channel_id, user_id, "stale-two", self())

    assert {:error, %{reason: :stale_prior}} =
             AdmissionCoordinator.reserve_pair(
               pair.call_id,
               {user_id, stale},
               {other_user_id, nil}
             )

    current = AdmissionCoordinator.current_identity(user_id)

    for mismatched <- [
          %{current | target: DiscordClone.Media.Target.voice_channel(Ecto.UUID.generate())},
          %{current | session_id: Ecto.UUID.generate()},
          %{current | runtime_generation: make_ref()}
        ] do
      assert {:error, %{reason: :stale_prior}} =
               AdmissionCoordinator.reserve_pair(
                 pair.call_id,
                 {user_id, mismatched},
                 {other_user_id, nil}
               )
    end

    assert {:ok, _} = Voice.join(Ecto.UUID.generate(), other_user_id, "un-pinned", self())
  end

  test "expiry releases precommit pins, while commit keeps charged slots and rejects stale expiry" do
    pair = MediaFixtures.ringing_pair_fixture()
    MediaFixtures.start_ready_call_target(pair.call_id)
    user_id = pair.first_user_id
    other_user_id = pair.second_user_id
    call_id = pair.call_id
    prior_channel_id = Ecto.UUID.generate()

    assert {:ok, %{voice_session_id: prior_session_id}} =
             Voice.join(prior_channel_id, user_id, "prior", self())

    prior = AdmissionCoordinator.current_identity(user_id)

    assert {:ok, reservation} =
             AdmissionCoordinator.reserve_pair(call_id, {user_id, prior}, {other_user_id, nil})

    send(
      Process.whereis(DiscordClone.Voice.SessionCoordinator),
      {:reservation_expired, call_id, reservation.generation}
    )

    _ = :sys.get_state(DiscordClone.Voice.SessionCoordinator)
    assert {:ok, _} = Voice.join(Ecto.UUID.generate(), other_user_id, "after-expiry", self())
    assert {:ok, %{occupancy: 1}} = Voice.room_occupancy(prior_channel_id)

    other_prior = AdmissionCoordinator.current_identity(other_user_id)

    assert {:ok, committed} =
             AdmissionCoordinator.reserve_pair(
               call_id,
               {user_id, prior},
               {other_user_id, other_prior}
             )

    assert :ok = AdmissionCoordinator.mark_commit_started(call_id, committed.generation)

    assert {:error, :stale_reservation} =
             AdmissionCoordinator.release_committed_reservation(call_id, reservation.generation)

    send(
      Process.whereis(DiscordClone.Voice.SessionCoordinator),
      {:reservation_expired, call_id, committed.generation}
    )

    _ = :sys.get_state(DiscordClone.Voice.SessionCoordinator)

    assert {:error, %{reason: :reservation_conflict}} =
             Voice.join(Ecto.UUID.generate(), user_id, "pinned", self())

    assert {:error, :stale_reservation} =
             AdmissionCoordinator.release_reservation(call_id, committed.generation)

    assert {:error, :prior_sessions_active} =
             AdmissionCoordinator.activate_reservation(call_id, committed.generation)

    assert :ok = Voice.leave(prior_channel_id, prior_session_id)
    assert :ok = Voice.end_user_session(other_prior.target.id, other_user_id)
    assert :ok = AdmissionCoordinator.activate_reservation(call_id, committed.generation)

    guard_pair = MediaFixtures.ringing_pair_fixture()
    MediaFixtures.start_ready_call_target(guard_pair.call_id)

    assert {:error, %{reason: :reservation_conflict}} =
             AdmissionCoordinator.reserve_pair(
               guard_pair.call_id,
               {guard_pair.first_user_id, nil},
               {guard_pair.second_user_id, nil}
             )

    assert {:error, %{reason: :reservation_conflict}} =
             Voice.join(Ecto.UUID.generate(), user_id, "active-pin", self())

    assert :ok = AdmissionCoordinator.release_active_call(call_id, committed.generation)
  end

  test "failed committed setup releases its exact claim without restoring prior Voice" do
    pair = MediaFixtures.ringing_pair_fixture()
    MediaFixtures.start_ready_call_target(pair.call_id)
    user_id = pair.first_user_id
    other_user_id = pair.second_user_id
    voice_channel_id = Ecto.UUID.generate()

    assert {:ok, %{voice_session_id: session_id}} =
             Voice.join(voice_channel_id, user_id, "before-failure", self())

    prior = AdmissionCoordinator.current_identity(user_id)
    call_id = pair.call_id

    assert {:ok, reservation} =
             AdmissionCoordinator.reserve_pair(call_id, {user_id, prior}, {other_user_id, nil})

    assert :ok = AdmissionCoordinator.mark_commit_started(call_id, reservation.generation)
    assert :ok = Voice.leave(voice_channel_id, session_id)

    assert :ok =
             AdmissionCoordinator.release_committed_reservation(call_id, reservation.generation)

    assert AdmissionCoordinator.current_identity(user_id) == nil

    assert {:error, :stale_reservation} =
             AdmissionCoordinator.activate_reservation(call_id, reservation.generation)

    assert {:ok, _} = Voice.join(Ecto.UUID.generate(), other_user_id, "after-failure", self())
  end

  test "simultaneous pair attempts serialize and an unrelated Voice Channel progresses" do
    pairs = Enum.map(1..8, fn _ -> MediaFixtures.ringing_pair_fixture() end)
    Enum.each(pairs, &MediaFixtures.start_ready_call_target(&1.call_id))

    results =
      pairs
      |> Task.async_stream(
        fn pair ->
          AdmissionCoordinator.reserve_pair(
            pair.call_id,
            {pair.first_user_id, nil},
            {pair.second_user_id, nil}
          )
        end,
        max_concurrency: 8,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert [{:ok, reservation}] = Enum.filter(results, &match?({:ok, _}, &1))
    assert Enum.count(results, &match?({:error, %{reason: :reservation_conflict}}, &1)) == 7

    unrelated_channel_id = Ecto.UUID.generate()
    assert {:ok, _} = Voice.join(unrelated_channel_id, Ecto.UUID.generate(), "unrelated", self())

    pinned_user_id = hd(reservation.user_ids)

    assert {:error, %{reason: :reservation_conflict}} =
             Voice.join(Ecto.UUID.generate(), pinned_user_id, "pinned", self())

    assert :ok =
             AdmissionCoordinator.release_reservation(reservation.call_id, reservation.generation)

    assert {:ok, _} = Voice.join(Ecto.UUID.generate(), pinned_user_id, "after-release", self())
  end

  test "reservation expiry races pair admission and Voice joins without exceeding capacity or leaking pins" do
    channels = Enum.map(1..4, fn _ -> Ecto.UUID.generate() end)

    Enum.each(0..17, fn index ->
      assert {:ok, _} =
               Voice.join(
                 Enum.at(channels, div(index, 5)),
                 Ecto.UUID.generate(),
                 "race-background-#{index}",
                 self()
               )
    end)

    pair = MediaFixtures.ringing_pair_fixture()
    MediaFixtures.start_ready_call_target(pair.call_id)
    first = pair.first_user_id
    second = pair.second_user_id
    unrelated = Ecto.UUID.generate()
    call_id = pair.call_id
    next_call_id = call_id

    assert {:ok, reservation} =
             AdmissionCoordinator.reserve_pair(call_id, {first, nil}, {second, nil})

    parent = self()
    supervisor = start_supervised!({Task.Supervisor, name: :reservation_race_tasks})
    coordinator = Process.whereis(DiscordClone.Voice.SessionCoordinator)

    actions = [
      fn ->
        send(coordinator, {:reservation_expired, call_id, reservation.generation})
        _ = :sys.get_state(coordinator)
        :expired
      end,
      fn -> AdmissionCoordinator.reserve_pair(next_call_id, {first, nil}, {second, nil}) end,
      fn -> Voice.join(Ecto.UUID.generate(), first, "racing-pinned-join", parent) end,
      fn -> Voice.join(Ecto.UUID.generate(), unrelated, "racing-unrelated-join", parent) end
    ]

    tasks =
      Enum.map(actions, fn action ->
        Task.Supervisor.async_nolink(supervisor, fn ->
          send(parent, {:race_ready, self()})

          receive do
            :race_go -> action.()
          end
        end)
      end)

    task_pids =
      Enum.map(1..4, fn _ ->
        assert_receive {:race_ready, pid}
        pid
      end)

    Enum.each(task_pids, &send(&1, :race_go))

    [expiry_result, pair_result, pinned_join_result, unrelated_join_result] =
      Enum.map(tasks, &Task.await(&1, 10_000))

    assert expiry_result == :expired

    assert pair_result == {:error, %{reason: :reservation_conflict}} or
             pair_result == {:error, %{reason: :stale_prior}} or
             match?({:error, %{reason: :deployment_full}}, pair_result) or
             match?({:ok, _}, pair_result)

    if match?({:ok, _}, pair_result) do
      {:ok, next_reservation} = pair_result

      assert :ok =
               AdmissionCoordinator.release_reservation(next_call_id, next_reservation.generation)
    end

    assert match?({:ok, _}, pinned_join_result) or
             match?({:error, %{reason: :reservation_conflict}}, pinned_join_result) or
             match?({:error, %{reason: :deployment_full}}, pinned_join_result)

    assert match?({:ok, _}, unrelated_join_result) or
             match?({:error, %{reason: :deployment_full}}, unrelated_join_result)

    assert {:ok, _} = Voice.join(Ecto.UUID.generate(), first, "after-race-cleanup", self())

    unless match?({:ok, _}, unrelated_join_result) do
      assert {:ok, _} = Voice.join(Ecto.UUID.generate(), unrelated, "after-race-capacity", self())
    end

    assert {:error, %{reason: :deployment_full, occupancy: 20, capacity: 20}} =
             Voice.join(Ecto.UUID.generate(), Ecto.UUID.generate(), "race-over-capacity", self())
  end
end
