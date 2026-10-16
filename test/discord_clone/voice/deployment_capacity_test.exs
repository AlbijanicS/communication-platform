defmodule DiscordClone.Voice.DeploymentCapacityTest do
  use ExUnit.Case, async: false

  alias DiscordClone.Voice

  @capacity 20

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

  test "serializes the deployment-wide cap before PeerConnection startup across Voice Channels" do
    voice_channel_ids = Enum.map(1..5, fn _number -> Ecto.UUID.generate() end)
    signaling_channel = self()

    results =
      1..25
      |> Task.async_stream(
        fn number ->
          voice_channel_id = Enum.at(voice_channel_ids, rem(number - 1, 5))
          user_id = Ecto.UUID.generate()
          signaling_session_id = "concurrent-capacity-#{number}"

          result =
            Voice.join(
              voice_channel_id,
              user_id,
              signaling_session_id,
              signaling_channel
            )

          {voice_channel_id, user_id, signaling_session_id, result}
        end,
        max_concurrency: 25,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, result} -> result end)

    {admitted, rejected} =
      Enum.split_with(results, fn {_voice_channel_id, _user_id, _signaling_session_id, result} ->
        match?({:ok, %{voice_session_id: _voice_session_id}}, result)
      end)

    assert length(admitted) == @capacity

    assert Enum.all?(rejected, fn {_voice_channel_id, _user_id, _signaling_session_id, result} ->
             result ==
               {:error, %{reason: :deployment_full, occupancy: @capacity, capacity: @capacity}}
           end)

    assert Enum.sum(
             Enum.map(voice_channel_ids, fn voice_channel_id ->
               {:ok, %{occupancy: occupancy, capacity: 5}} =
                 Voice.room_occupancy(voice_channel_id)

               occupancy
             end)
           ) == @capacity

    {rejoined_voice_channel_id, rejoined_user_id, rejoined_signaling_session_id,
     {:ok, original_join_result}} = hd(admitted)

    original_voice_session_id = original_join_result.voice_session_id

    assert {:ok, %{voice_session_id: ^original_voice_session_id}} =
             Voice.join(
               rejoined_voice_channel_id,
               rejoined_user_id,
               rejoined_signaling_session_id,
               signaling_channel
             )

    assert total_occupancy(voice_channel_ids) == @capacity

    rejected_voice_channel_id = Ecto.UUID.generate()

    assert {:error, %{reason: :deployment_full}} =
             Voice.join(
               rejected_voice_channel_id,
               Ecto.UUID.generate(),
               "twenty-first-session",
               self()
             )

    refute Voice.room_running?(rejected_voice_channel_id)
    assert {:ok, %{members: []}} = Voice.voice_channel_roster(rejected_voice_channel_id)

    assert {:ok, %{voice_session_id: ^original_voice_session_id}} =
             Voice.join(
               rejoined_voice_channel_id,
               rejoined_user_id,
               rejoined_signaling_session_id,
               signaling_channel
             )

    assert total_occupancy(voice_channel_ids) == @capacity
  end

  test "canonical lifecycle cleanup releases capacity for later eligible admissions" do
    authentication_channel = start_signaling_channel(:authentication_cleanup)
    full_move_target_id = Ecto.UUID.generate()

    sessions =
      [
        {:leave, Ecto.UUID.generate(), self()},
        {:terminal_failure, Ecto.UUID.generate(), self()},
        {:authentication_cleanup, Ecto.UUID.generate(), authentication_channel},
        {:room_runtime_failure, Ecto.UUID.generate(), self()}
      ] ++
        Enum.map(1..5, fn number ->
          {{:full_move_target, number}, full_move_target_id, self()}
        end) ++
        Enum.map(1..11, fn number ->
          {{:retained, number}, Ecto.UUID.generate(), self()}
        end)

    admitted =
      for {{label, voice_channel_id, signaling_channel}, number} <-
            Enum.with_index(sessions, 1) do
        user_id = Ecto.UUID.generate()

        assert {:ok, %{voice_session_id: voice_session_id}} =
                 Voice.join(
                   voice_channel_id,
                   user_id,
                   "capacity-cleanup-#{number}",
                   signaling_channel
                 )

        %{
          label: label,
          user_id: user_id,
          voice_channel_id: voice_channel_id,
          voice_session_id: voice_session_id
        }
      end

    assert {:error, %{reason: :deployment_full}} = join_later_session("before-cleanup")

    leave_session = session_for(admitted, :leave)

    assert {:error, %{reason: :room_full, occupancy: 5, capacity: 5}} =
             Voice.join(
               full_move_target_id,
               leave_session.user_id,
               "move-rejected-at-deployment-capacity",
               self()
             )

    assert {:ok, %{occupancy: 1, capacity: 5}} =
             Voice.room_occupancy(leave_session.voice_channel_id)

    moved_session = session_for(admitted, {:retained, 1})
    available_move_target_id = Ecto.UUID.generate()

    assert {:ok, %{voice_session_id: moved_voice_session_id}} =
             Voice.join(
               available_move_target_id,
               moved_session.user_id,
               "move-accepted-at-deployment-capacity",
               self()
             )

    refute moved_voice_session_id == moved_session.voice_session_id

    assert {:ok, %{occupancy: 0, capacity: 5}} =
             Voice.room_occupancy(moved_session.voice_channel_id)

    assert {:ok, %{occupancy: 1, capacity: 5}} =
             Voice.room_occupancy(available_move_target_id)

    capacity_room_ids =
      [available_move_target_id | Enum.map(admitted, & &1.voice_channel_id)]
      |> Enum.uniq()

    assert total_occupancy(capacity_room_ids) == @capacity

    assert :ok = Voice.leave(leave_session.voice_channel_id, leave_session.voice_session_id)
    assert {:ok, _join_result} = join_later_session("after-leave")

    terminal_session = session_for(admitted, :terminal_failure)

    assert :ok =
             Voice.crash_session(
               terminal_session.voice_channel_id,
               terminal_session.voice_session_id
             )

    assert {:ok, _join_result} = eventually_join_later_session("after-terminal-failure")

    authentication_session = session_for(admitted, :authentication_cleanup)
    Process.exit(authentication_channel, :shutdown)
    assert :ok = Voice.await_empty_room(authentication_session.voice_channel_id)
    assert {:ok, _join_result} = join_later_session("after-authentication-cleanup")

    failed_room_session = session_for(admitted, :room_runtime_failure)
    assert :ok = Voice.crash_forwarder(failed_room_session.voice_channel_id)
    assert {:ok, _join_result} = eventually_join_later_session("after-room-runtime-failure")
  end

  defp join_later_session(label) do
    Voice.join(
      Ecto.UUID.generate(),
      Ecto.UUID.generate(),
      label,
      self()
    )
  end

  defp eventually_join_later_session(label, attempts_left \\ 10)

  defp eventually_join_later_session(label, attempts_left) when attempts_left > 0 do
    case join_later_session(label) do
      {:error, %{reason: :deployment_full}} ->
        eventually_join_later_session(label, attempts_left - 1)

      result ->
        result
    end
  end

  defp eventually_join_later_session(_label, 0), do: {:error, :cleanup_not_observed}

  defp session_for(sessions, label), do: Enum.find(sessions, &(&1.label == label))

  defp total_occupancy(voice_channel_ids) do
    Enum.reduce(voice_channel_ids, 0, fn voice_channel_id, total ->
      case Voice.room_occupancy(voice_channel_id) do
        {:ok, %{occupancy: occupancy}} -> total + occupancy
        {:error, :not_found} -> total
      end
    end)
  end

  defp start_signaling_channel(id) do
    start_supervised!(%{
      id: {:deployment_capacity_signaling_channel, id},
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
