defmodule DiscordClone.Media.PairAdmissionTest do
  use DiscordClone.DataCase, async: false

  import DiscordClone.AccountsFixtures

  alias DiscordClone.Media.{AdmissionCoordinator, DirectCallTarget, Target}
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

  test "commit_pair retires both exact prior Voice Sessions and publishes both Call Sessions" do
    pair = MediaFixtures.ringing_pair_fixture()
    MediaFixtures.start_ready_call_target(pair.call_id)
    first_channel = Ecto.UUID.generate()
    second_channel = Ecto.UUID.generate()

    assert {:ok, %{voice_session_id: first_voice_session_id}} =
             Voice.join(first_channel, pair.first_user_id, "first-prior", self())

    assert {:ok, %{voice_session_id: second_voice_session_id}} =
             Voice.join(second_channel, pair.second_user_id, "second-prior", self())

    first_prior = AdmissionCoordinator.current_identity(pair.first_user_id)
    second_prior = AdmissionCoordinator.current_identity(pair.second_user_id)

    assert {:ok, reservation} =
             AdmissionCoordinator.reserve_pair(
               pair.call_id,
               {pair.first_user_id, first_prior},
               {pair.second_user_id, second_prior}
             )

    assert reservation.prior_identities == %{
             pair.first_user_id => first_prior,
             pair.second_user_id => second_prior
           }

    assert {:ok, %{occupancy: 1}} = Voice.room_occupancy(first_channel)
    assert {:ok, %{occupancy: 1}} = Voice.room_occupancy(second_channel)

    MediaFixtures.set_attempt_connecting!(pair.call_id)

    assert {:ok, result} = AdmissionCoordinator.commit_pair(pair.call_id, reservation.generation)

    assert result.call_id == pair.call_id
    assert result.generation == reservation.generation
    assert Enum.sort(result.user_ids) == Enum.sort([pair.first_user_id, pair.second_user_id])

    first_call_session_id = result.call_sessions[pair.first_user_id]
    second_call_session_id = result.call_sessions[pair.second_user_id]
    refute first_call_session_id == second_call_session_id

    refute first_call_session_id in [
             pair.call_id,
             first_voice_session_id,
             second_voice_session_id
           ]

    assert {:ok, %{occupancy: 0, capacity: 5}} = Voice.room_occupancy(first_channel)
    assert {:ok, %{occupancy: 0, capacity: 5}} = Voice.room_occupancy(second_channel)

    assert_call_identity(pair.call_id, pair.first_user_id, result)
    assert_call_identity(pair.call_id, pair.second_user_id, result)

    target_generation = result.target_runtime_generation

    assert %{
             runtime_generation: ^target_generation,
             status: :ready,
             sessions: sessions
           } = AdmissionCoordinator.call_target_snapshot(pair.call_id)

    assert sessions == %{
             first_call_session_id => pair.first_user_id,
             second_call_session_id => pair.second_user_id
           }
  end

  test "commit_pair admits a pair with one prior Voice Session" do
    pair = MediaFixtures.ringing_pair_fixture()
    MediaFixtures.start_ready_call_target(pair.call_id)
    prior_channel = Ecto.UUID.generate()

    assert {:ok, %{voice_session_id: voice_session_id}} =
             Voice.join(prior_channel, pair.first_user_id, "one-prior", self())

    prior = AdmissionCoordinator.current_identity(pair.first_user_id)

    assert {:ok, reservation} =
             AdmissionCoordinator.reserve_pair(
               pair.call_id,
               {pair.first_user_id, prior},
               {pair.second_user_id, nil}
             )

    assert reservation.prior_identities[pair.second_user_id] == nil

    MediaFixtures.set_attempt_connecting!(pair.call_id)

    assert {:ok, result} = AdmissionCoordinator.commit_pair(pair.call_id, reservation.generation)

    assert {:ok, %{occupancy: 0, capacity: 5}} = Voice.room_occupancy(prior_channel)

    assert AdmissionCoordinator.current_identity(pair.first_user_id).session_id !=
             voice_session_id

    assert_call_identity(pair.call_id, pair.second_user_id, result)

    assert map_size(AdmissionCoordinator.call_target_snapshot(pair.call_id).sessions) == 2
  end

  test "commit_pair admits a pair when only the recipient has a prior Voice Session" do
    pair = MediaFixtures.ringing_pair_fixture()
    MediaFixtures.start_ready_call_target(pair.call_id)
    prior_channel = Ecto.UUID.generate()

    assert {:ok, %{voice_session_id: voice_session_id}} =
             Voice.join(prior_channel, pair.second_user_id, "recipient-prior", self())

    prior = AdmissionCoordinator.current_identity(pair.second_user_id)

    assert {:ok, reservation} =
             AdmissionCoordinator.reserve_pair(
               pair.call_id,
               {pair.first_user_id, nil},
               {pair.second_user_id, prior}
             )

    MediaFixtures.set_attempt_connecting!(pair.call_id)

    assert {:ok, result} = AdmissionCoordinator.commit_pair(pair.call_id, reservation.generation)

    assert {:ok, %{occupancy: 0, capacity: 5}} = Voice.room_occupancy(prior_channel)

    assert AdmissionCoordinator.current_identity(pair.second_user_id).session_id !=
             voice_session_id

    assert_call_identity(pair.call_id, pair.first_user_id, result)
    assert map_size(result.call_sessions) == 2
  end

  test "commit_pair admits a pair with no prior Voice Sessions" do
    pair = MediaFixtures.ringing_pair_fixture()
    MediaFixtures.start_ready_call_target(pair.call_id)

    assert {:ok, reservation} =
             AdmissionCoordinator.reserve_pair(
               pair.call_id,
               {pair.first_user_id, nil},
               {pair.second_user_id, nil}
             )

    assert reservation.prior_identities == %{
             pair.first_user_id => nil,
             pair.second_user_id => nil
           }

    MediaFixtures.set_attempt_connecting!(pair.call_id)

    assert {:ok, result} = AdmissionCoordinator.commit_pair(pair.call_id, reservation.generation)

    assert_call_identity(pair.call_id, pair.first_user_id, result)
    assert_call_identity(pair.call_id, pair.second_user_id, result)
    assert map_size(AdmissionCoordinator.call_target_snapshot(pair.call_id).sessions) == 2
  end

  test "converting the reservation to an active call does not double charge the two Call slots" do
    first = user_fixture()
    second = user_fixture()
    pair = MediaFixtures.ringing_pair_fixture(first, second)
    target = MediaFixtures.start_ready_call_target(pair.call_id)

    Enum.each(1..16, fn index ->
      assert {:ok, _} =
               Voice.join(
                 Ecto.UUID.generate(),
                 Ecto.UUID.generate(),
                 "occupancy-#{index}",
                 self()
               )
    end)

    first_channel = Ecto.UUID.generate()
    second_channel = Ecto.UUID.generate()

    assert {:ok, _} = Voice.join(first_channel, first.id, "occupancy-first", self())
    assert {:ok, _} = Voice.join(second_channel, second.id, "occupancy-second", self())

    assert {:ok, reservation} =
             AdmissionCoordinator.reserve_pair(
               pair.call_id,
               {first.id, AdmissionCoordinator.current_identity(first.id)},
               {second.id, AdmissionCoordinator.current_identity(second.id)}
             )

    MediaFixtures.set_attempt_connecting!(pair.call_id)

    assert {:ok, result} = AdmissionCoordinator.commit_pair(pair.call_id, reservation.generation)

    assert map_size(AdmissionCoordinator.call_target_snapshot(pair.call_id).sessions) == 2

    assert {:ok, _} =
             Voice.join(Ecto.UUID.generate(), Ecto.UUID.generate(), "after-call-one", self())

    assert {:ok, _} =
             Voice.join(Ecto.UUID.generate(), Ecto.UUID.generate(), "after-call-two", self())

    assert {:error, %{reason: :deployment_full, occupancy: 20, capacity: 20}} =
             Voice.join(Ecto.UUID.generate(), Ecto.UUID.generate(), "over-capacity", self())

    assert {:error, :full} = DirectCallTarget.admit(target, Ecto.UUID.generate())
    assert map_size(result.call_sessions) == 2
  end

  test "preflight rejects a pair before any mutation and preserves both Voice Sessions" do
    pair = MediaFixtures.ringing_pair_fixture()
    MediaFixtures.start_ready_call_target(pair.call_id)
    first_channel = Ecto.UUID.generate()
    second_channel = Ecto.UUID.generate()

    assert {:ok, _} = Voice.join(first_channel, pair.first_user_id, "preflight-first", self())
    assert {:ok, _} = Voice.join(second_channel, pair.second_user_id, "preflight-second", self())

    first_prior = AdmissionCoordinator.current_identity(pair.first_user_id)
    second_prior = AdmissionCoordinator.current_identity(pair.second_user_id)

    rejections = [
      {Ecto.UUID.generate(), {pair.first_user_id, first_prior},
       {pair.second_user_id, second_prior}, {:error, :not_found}},
      {pair.call_id, {pair.first_user_id, first_prior}, {Ecto.UUID.generate(), nil},
       {:error, :not_found}},
      {pair.call_id, {pair.first_user_id, %{first_prior | session_id: Ecto.UUID.generate()}},
       {pair.second_user_id, second_prior}, {:error, %{reason: :stale_prior}}},
      {pair.call_id, {pair.first_user_id, nil}, {pair.second_user_id, second_prior},
       {:error, %{reason: :stale_prior}}}
    ]

    Enum.each(rejections, fn {call_id, first, second, expected} ->
      assert ^expected = AdmissionCoordinator.reserve_pair(call_id, first, second)
      assert_voices_intact(pair, first_channel, second_channel, first_prior, second_prior)
    end)
  end

  test "preflight rejects an unavailable target and preserves both Voice Sessions" do
    pair = MediaFixtures.ringing_pair_fixture()
    first_channel = Ecto.UUID.generate()
    second_channel = Ecto.UUID.generate()

    assert {:ok, _} = Voice.join(first_channel, pair.first_user_id, "state-first", self())
    assert {:ok, _} = Voice.join(second_channel, pair.second_user_id, "state-second", self())

    first_prior = AdmissionCoordinator.current_identity(pair.first_user_id)
    second_prior = AdmissionCoordinator.current_identity(pair.second_user_id)

    assert {:error, %{reason: :target_unavailable}} =
             AdmissionCoordinator.reserve_pair(
               pair.call_id,
               {pair.first_user_id, first_prior},
               {pair.second_user_id, second_prior}
             )

    assert_voices_intact(pair, first_channel, second_channel, first_prior, second_prior)

    target = MediaFixtures.start_ready_call_target(pair.call_id)
    {:ok, %{runtime_generation: generation}} = DirectCallTarget.identity(target)

    assert :ok = AdmissionCoordinator.call_target_failed(pair.call_id, generation, :boom)

    assert {:error, %{reason: :target_unavailable}} =
             AdmissionCoordinator.reserve_pair(
               pair.call_id,
               {pair.first_user_id, first_prior},
               {pair.second_user_id, second_prior}
             )

    assert_voices_intact(pair, first_channel, second_channel, first_prior, second_prior)
  end

  test "preflight rejects a non-ringing attempt and a former friendship" do
    connecting_pair = MediaFixtures.ringing_pair_fixture()
    MediaFixtures.set_attempt_connecting!(connecting_pair.call_id)

    assert {:error, :stale} =
             AdmissionCoordinator.reserve_pair(
               connecting_pair.call_id,
               {connecting_pair.first_user_id, nil},
               {connecting_pair.second_user_id, nil}
             )

    former_friend_pair = MediaFixtures.ringing_pair_fixture()
    MediaFixtures.start_ready_call_target(former_friend_pair.call_id)
    MediaFixtures.end_friendship!(former_friend_pair.friendship)

    assert {:error, :not_friends} =
             AdmissionCoordinator.reserve_pair(
               former_friend_pair.call_id,
               {former_friend_pair.first_user_id, nil},
               {former_friend_pair.second_user_id, nil}
             )
  end

  test "preflight enforces the 20-slot cap with an exact replacement credit" do
    pair = MediaFixtures.ringing_pair_fixture()
    MediaFixtures.start_ready_call_target(pair.call_id)
    channel = Ecto.UUID.generate()

    assert {:ok, _} = Voice.join(channel, pair.first_user_id, "cap-prior", self())
    prior = AdmissionCoordinator.current_identity(pair.first_user_id)

    Enum.each(1..19, fn index ->
      assert {:ok, _} =
               Voice.join(Ecto.UUID.generate(), Ecto.UUID.generate(), "full-#{index}", self())
    end)

    assert {:error, %{reason: :deployment_full, occupancy: 21, capacity: 20}} =
             AdmissionCoordinator.reserve_pair(
               pair.call_id,
               {pair.first_user_id, prior},
               {pair.second_user_id, nil}
             )

    assert {:ok, %{occupancy: 1}} = Voice.room_occupancy(channel)
    assert AdmissionCoordinator.current_identity(pair.first_user_id) == prior
  end

  test "preflight enforces the one-Direct-Call limit until the reservation releases" do
    pair = MediaFixtures.ringing_pair_fixture()
    other_pair = MediaFixtures.ringing_pair_fixture()
    MediaFixtures.start_ready_call_target(pair.call_id)
    MediaFixtures.start_ready_call_target(other_pair.call_id)

    assert {:ok, reservation} =
             AdmissionCoordinator.reserve_pair(
               pair.call_id,
               {pair.first_user_id, nil},
               {pair.second_user_id, nil}
             )

    assert {:error, %{reason: :reservation_conflict}} =
             AdmissionCoordinator.reserve_pair(
               other_pair.call_id,
               {other_pair.first_user_id, nil},
               {other_pair.second_user_id, nil}
             )

    assert :ok =
             AdmissionCoordinator.release_reservation(pair.call_id, reservation.generation)

    assert {:ok, _} =
             AdmissionCoordinator.reserve_pair(
               other_pair.call_id,
               {other_pair.first_user_id, nil},
               {other_pair.second_user_id, nil}
             )
  end

  test "commit_pair refuses to retire Voice until the attempt is durably connecting" do
    pair = MediaFixtures.ringing_pair_fixture()
    MediaFixtures.start_ready_call_target(pair.call_id)
    channel = Ecto.UUID.generate()

    assert {:ok, %{voice_session_id: voice_session_id}} =
             Voice.join(channel, pair.first_user_id, "not-connecting", self())

    prior = AdmissionCoordinator.current_identity(pair.first_user_id)

    assert {:ok, reservation} =
             AdmissionCoordinator.reserve_pair(
               pair.call_id,
               {pair.first_user_id, prior},
               {pair.second_user_id, nil}
             )

    assert {:error, :not_connecting} =
             AdmissionCoordinator.commit_pair(pair.call_id, reservation.generation)

    assert {:ok, %{occupancy: 1}} = Voice.room_occupancy(channel)

    assert AdmissionCoordinator.current_identity(pair.first_user_id).session_id ==
             voice_session_id

    assert AdmissionCoordinator.current_identity(pair.second_user_id) == nil
    assert AdmissionCoordinator.call_target_snapshot(pair.call_id).sessions == %{}

    assert {:error, :stale_reservation} =
             AdmissionCoordinator.release_reservation(pair.call_id, reservation.generation)

    assert {:ok, _} =
             Voice.join(Ecto.UUID.generate(), pair.first_user_id, "unpinned-again", self())
  end

  test "commit_pair revalidates the operation generation and exact target state" do
    pair = MediaFixtures.ringing_pair_fixture()
    target = MediaFixtures.start_ready_call_target(pair.call_id)
    channel = Ecto.UUID.generate()

    assert {:ok, %{voice_session_id: voice_session_id}} =
             Voice.join(channel, pair.first_user_id, "stale-generation", self())

    prior = AdmissionCoordinator.current_identity(pair.first_user_id)

    assert {:ok, reservation} =
             AdmissionCoordinator.reserve_pair(
               pair.call_id,
               {pair.first_user_id, prior},
               {pair.second_user_id, nil}
             )

    MediaFixtures.set_attempt_connecting!(pair.call_id)

    assert {:error, :stale_reservation} =
             AdmissionCoordinator.commit_pair(pair.call_id, make_ref())

    assert {:ok, %{occupancy: 1}} = Voice.room_occupancy(channel)

    assert {:ok, _} = DirectCallTarget.admit(target, Ecto.UUID.generate())

    assert {:error, %{reason: :target_unavailable}} =
             AdmissionCoordinator.commit_pair(pair.call_id, reservation.generation)

    assert {:ok, %{occupancy: 1}} = Voice.room_occupancy(channel)

    assert AdmissionCoordinator.current_identity(pair.first_user_id).session_id ==
             voice_session_id
  end

  test "slow room work runs outside the admission mailbox while unrelated rooms proceed" do
    pair = MediaFixtures.ringing_pair_fixture()
    MediaFixtures.start_ready_call_target(pair.call_id)
    channel = Ecto.UUID.generate()

    assert {:ok, %{voice_session_id: _voice_session_id}} =
             Voice.join(channel, pair.first_user_id, "slow-room", self())

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

    task =
      Task.async(fn -> AdmissionCoordinator.commit_pair(pair.call_id, reservation.generation) end)

    assert {:ok, _} =
             Voice.join(
               Ecto.UUID.generate(),
               Ecto.UUID.generate(),
               "unrelated-while-slow",
               self()
             )

    assert AdmissionCoordinator.call_target_snapshot(pair.call_id).sessions == %{}
    assert AdmissionCoordinator.current_identity(pair.first_user_id).session_id != nil

    :ok = :sys.resume(room_server)

    assert {:ok, result} = Task.await(task, 5_000)

    assert map_size(result.call_sessions) == 2
    assert {:ok, %{occupancy: 0}} = Voice.room_occupancy(channel)
  end

  defp assert_call_identity(call_id, user_id, result) do
    identity = AdmissionCoordinator.current_identity(user_id)

    assert identity.target == Target.direct_call(call_id)
    assert identity.session_id == result.call_sessions[user_id]
    assert identity.runtime_generation == result.target_runtime_generation
  end

  defp assert_voices_intact(pair, first_channel, second_channel, first_prior, second_prior) do
    assert {:ok, %{occupancy: 1}} = Voice.room_occupancy(first_channel)
    assert {:ok, %{occupancy: 1}} = Voice.room_occupancy(second_channel)
    assert AdmissionCoordinator.current_identity(pair.first_user_id) == first_prior
    assert AdmissionCoordinator.current_identity(pair.second_user_id) == second_prior
    assert target_sessions(pair.call_id) == %{}
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
