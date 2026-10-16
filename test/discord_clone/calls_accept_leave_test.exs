defmodule DiscordClone.CallsAcceptLeaveTest do
  use DiscordClone.DataCase, async: false

  import DiscordClone.AccountsFixtures
  import DiscordClone.CallsFixtures

  alias DiscordClone.Calls
  alias DiscordClone.Calls.{CallAttempt, CallServer, ScriptedAcceptedCallRuntime}
  alias DiscordClone.Friendships
  alias DiscordClone.Repo
  alias DiscordClone.Voice

  setup do
    start_supervised!(DiscordClone.Calls.Supervisor)
    DiscordClone.Calls.CallCoordinator.begin_recovery()
    await_recovery_finished()

    on_exit(fn ->
      DiscordClone.Voice.running_room_servers()
      |> Enum.each(fn {voice_channel_id, _room_server} ->
        :ok = Voice.end_channel_sessions(voice_channel_id)
        :ok = Voice.expire_idle_room(voice_channel_id)
      end)
    end)

    :ok
  end

  describe "accept_call/3" do
    test "recipient audio acceptance commits connecting then fake active without Voice or Activity" do
      with_accepted_runtime(:ready, fn ->
        {caller_scope, recipient_scope, direct_conversation, _friendship} =
          direct_conversation_fixture("accept_audio")

        voice_channel_id = Ecto.UUID.generate()

        assert {:ok, %{voice_session_id: voice_session_id}} =
                 Voice.join(voice_channel_id, caller_scope.user.id, "caller-voice", self())

        assert :ok = Calls.subscribe(caller_scope)
        assert :ok = Calls.subscribe(recipient_scope)

        messages_before = Repo.aggregate(DiscordClone.Chat.Message, :count)

        running_peer_connections_before =
          ExWebRTC.PeerConnection.get_all_running()
          |> MapSet.new()

        assert {:ok, %{call: ringing, started?: true}} =
                 Calls.start_call(caller_scope, direct_conversation.id, :audio)

        assert_receive {:call_ringing, _}
        assert_receive {:call_ringing, _}

        assert {:ok, connecting} =
                 Calls.accept_call(recipient_scope, ringing.call_id, :audio)

        assert connecting.call_id == ringing.call_id
        assert connecting.state == :connecting
        assert connecting.media_intent == :audio
        assert is_nil(connecting.terminal_outcome)
        refute contains_pid?(connecting)

        accepted_at = Repo.get!(CallAttempt, ringing.call_id).accepted_at
        assert %DateTime{} = accepted_at

        assert_receive {:call_connecting, first_connecting}
        assert_receive {:call_connecting, second_connecting}

        assert MapSet.new([first_connecting.call_id, second_connecting.call_id]) ==
                 MapSet.new([ringing.call_id])

        flush_call_server(ringing.call_id)

        assert {:ok, active} = Calls.get_call(recipient_scope, ringing.call_id)
        assert active.state == :active
        assert active.call_id == ringing.call_id
        assert Repo.get!(CallAttempt, ringing.call_id).accepted_at == accepted_at

        assert_receive {:call_active, first_active}
        assert_receive {:call_active, second_active}
        assert first_active.state == :active
        assert second_active.state == :active

        coordinator = :sys.get_state(DiscordClone.Calls.CallCoordinator)
        assert coordinator.calls_by_id[ringing.call_id] == direct_conversation.id
        assert coordinator.calls_by_user[caller_scope.user.id] == ringing.call_id
        assert coordinator.calls_by_user[recipient_scope.user.id] == ringing.call_id

        assert {:ok, %{members: [%{user_id: caller_user_id}]}} =
                 Voice.voice_channel_roster(voice_channel_id)

        assert caller_user_id == caller_scope.user.id
        assert :ok = Voice.leave(voice_channel_id, voice_session_id)

        assert ExWebRTC.PeerConnection.get_all_running()
               |> MapSet.new()
               |> MapSet.difference(running_peer_connections_before)
               |> MapSet.size() == 0

        assert missed_call_activity_items(recipient_scope.user.id, ringing.call_id) == []
        assert Repo.aggregate(DiscordClone.Chat.Message, :count) == messages_before
      end)
    end

    test "repeated acceptance keeps accepted_at and does not schedule a second runtime" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("accept_repeat")

      with_accepted_runtime(:held, fn ->
        assert {:ok, %{call: ringing}} =
                 Calls.start_call(caller_scope, direct_conversation.id, :audio)

        assert {:ok, connecting} =
                 Calls.accept_call(recipient_scope, ringing.call_id, "audio")

        assert connecting.state == :connecting
        accepted_at = Repo.get!(CallAttempt, ringing.call_id).accepted_at
        updated_at = Repo.get!(CallAttempt, ringing.call_id).updated_at

        assert {:ok, again} = Calls.accept_call(recipient_scope, ringing.call_id, :audio)
        assert again.state == :connecting
        assert Repo.get!(CallAttempt, ringing.call_id).accepted_at == accepted_at
        assert Repo.get!(CallAttempt, ringing.call_id).updated_at == updated_at

        flush_call_server(ringing.call_id)
        assert Repo.get!(CallAttempt, ringing.call_id).state == :connecting
      end)
    end

    test "video invitation accepts video or explicit audio fallback without changing its intent" do
      for {suffix, answer_mode} <- [{"video", :video}, {"audio", :audio}] do
        {caller_scope, recipient_scope, direct_conversation, _friendship} =
          direct_conversation_fixture("accept_video_#{suffix}")

        with_accepted_runtime(:held, fn ->
          attempts_before = Repo.aggregate(CallAttempt, :count)

          assert {:ok, %{call: ringing, started?: true}} =
                   Calls.start_call(caller_scope, direct_conversation.id, :video)

          assert {:ok, connecting} =
                   Calls.accept_call(recipient_scope, ringing.call_id, answer_mode)

          assert connecting.state == :connecting
          assert connecting.media_intent == :video
          assert connecting.answer_mode == answer_mode
          assert Repo.get!(CallAttempt, ringing.call_id).media_intent == :video
          assert Repo.aggregate(CallAttempt, :count) == attempts_before + 1
          assert missed_call_activity_items(recipient_scope.user.id, ringing.call_id) == []
        end)
      end
    end

    test "first video answer mode remains stable across a conflicting duplicate" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("accept_video_stable")

      with_accepted_runtime(:held, fn ->
        assert {:ok, %{call: ringing}} =
                 Calls.start_call(caller_scope, direct_conversation.id, :video)

        assert {:ok, first} = Calls.accept_call(recipient_scope, ringing.call_id, :audio)
        accepted_at = Repo.get!(CallAttempt, ringing.call_id).accepted_at

        assert {:ok, duplicate} = Calls.accept_call(recipient_scope, ringing.call_id, :video)
        assert first.answer_mode == :audio
        assert duplicate.answer_mode == :audio
        assert Repo.get!(CallAttempt, ringing.call_id).accepted_at == accepted_at
      end)
    end

    test "an abandoned committed acceptance preserves its first mode across either handoff gap" do
      for handoff_stage <- [:after_durable_accept, :after_mode_commit] do
        suffix =
          if(handoff_stage == :after_durable_accept, do: "resume_durable", else: "resume_mode")

        {caller_scope, recipient_scope, direct_conversation, _friendship} =
          direct_conversation_fixture(suffix)

        with_accepted_runtime(:held, fn ->
          assert {:ok, %{call: ringing}} =
                   Calls.start_call(caller_scope, direct_conversation.id, :video)

          force_connecting!(ringing.call_id)
          parent = self()

          owner =
            spawn(fn ->
              {:owner, claim_ref} = CallServer.claim_answer_mode(ringing.call_id, :video)

              if handoff_stage == :after_mode_commit do
                :ok = CallServer.commit_answer_mode(ringing.call_id, claim_ref)
              end

              send(parent, {:handoff_abandoned, handoff_stage})
            end)

          owner_ref = Process.monitor(owner)
          assert_receive {:handoff_abandoned, ^handoff_stage}, 1_000
          assert_receive {:DOWN, ^owner_ref, :process, ^owner, :normal}, 1_000
          flush_call_server(ringing.call_id)

          assert {:ok, recovered} =
                   Calls.accept_call(recipient_scope, ringing.call_id, :audio)

          assert recovered.state == :connecting
          assert recovered.answer_mode == :video
          assert CallServer.answer_mode(ringing.call_id) == recovered.answer_mode
        end)
      end
    end

    test "an abandoned claim before durable acceptance lets the first committed request choose mode" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("resume_precommit")

      with_accepted_runtime(:held, fn ->
        assert {:ok, %{call: ringing}} =
                 Calls.start_call(caller_scope, direct_conversation.id, :video)

        parent = self()

        owner =
          spawn(fn ->
            assert {:owner, _claim_ref} =
                     CallServer.claim_answer_mode(ringing.call_id, :video)

            send(parent, :precommit_claim_abandoned)
          end)

        owner_ref = Process.monitor(owner)
        assert_receive :precommit_claim_abandoned, 1_000
        assert_receive {:DOWN, ^owner_ref, :process, ^owner, :normal}, 1_000
        flush_call_server(ringing.call_id)

        assert {:ok, recovered} =
                 Calls.accept_call(recipient_scope, ringing.call_id, :audio)

        assert recovered.state == :connecting
        assert recovered.answer_mode == :audio
        assert CallServer.answer_mode(ringing.call_id) == :audio
      end)
    end

    test "a second abandonment after durable acceptance preserves the reconciler's mode" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("resume_twice")

      with_accepted_runtime(:held, fn ->
        assert {:ok, %{call: ringing}} =
                 Calls.start_call(caller_scope, direct_conversation.id, :video)

        parent = self()

        first_owner =
          spawn(fn ->
            assert {:owner, _claim_ref} =
                     CallServer.claim_answer_mode(ringing.call_id, :video)

            send(parent, :first_claim_abandoned)
          end)

        first_ref = Process.monitor(first_owner)
        assert_receive :first_claim_abandoned, 1_000
        assert_receive {:DOWN, ^first_ref, :process, ^first_owner, :normal}, 1_000
        flush_call_server(ringing.call_id)

        reconciler =
          spawn(fn ->
            assert {:reconcile, claim_ref, :video} =
                     CallServer.claim_answer_mode(ringing.call_id, :audio)

            :ok = CallServer.update_answer_mode_claim(ringing.call_id, claim_ref, :audio)
            send(parent, {:reconciler_ready, self()})

            receive do
              :abandon_reconciliation -> :ok
            end
          end)

        reconciler_ref = Process.monitor(reconciler)
        assert_receive {:reconciler_ready, ^reconciler}, 1_000
        force_connecting!(ringing.call_id)
        send(reconciler, :abandon_reconciliation)
        assert_receive {:DOWN, ^reconciler_ref, :process, ^reconciler, :normal}, 1_000
        flush_call_server(ringing.call_id)

        assert {:ok, recovered} =
                 Calls.accept_call(recipient_scope, ringing.call_id, :video)

        assert recovered.state == :connecting
        assert recovered.answer_mode == :audio
        assert CallServer.answer_mode(ringing.call_id) == :audio
      end)
    end

    test "terminal duplicate acceptance never projects the transient answer mode" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("accept_terminal_mode")

      with_accepted_runtime(:held, fn ->
        assert {:ok, %{call: ringing}} =
                 Calls.start_call(caller_scope, direct_conversation.id, :video)

        assert {:ok, %{state: :connecting, answer_mode: :video}} =
                 Calls.accept_call(recipient_scope, ringing.call_id, :video)

        CallAttempt
        |> Repo.get!(ringing.call_id)
        |> CallAttempt.cancel_changeset(DateTime.utc_now(:microsecond))
        |> Repo.update!()

        assert {:ok, terminal} =
                 Calls.accept_call(recipient_scope, ringing.call_id, :audio)

        assert terminal.state == :terminal
        refute Map.has_key?(terminal, :answer_mode)
      end)
    end

    test "rejects caller, outsider, audio/video mismatch, former Friend, and invalid mode without writes" do
      with_accepted_runtime(:held, fn ->
        {caller_scope, recipient_scope, direct_conversation, friendship} =
          direct_conversation_fixture("accept_reject")

        outsider_scope = user_scope_fixture(user_fixture(username: "accept_reject_out"))

        assert {:ok, %{call: audio}} =
                 Calls.start_call(caller_scope, direct_conversation.id, :audio)

        assert {:error, :not_found} = Calls.accept_call(caller_scope, audio.call_id, :audio)
        assert {:error, :not_found} = Calls.accept_call(outsider_scope, audio.call_id, :audio)
        assert {:error, :not_found} = Calls.accept_call(recipient_scope, "not-a-uuid", :audio)
        assert {:error, :stale} = Calls.accept_call(recipient_scope, audio.call_id, :video)
        assert {:error, :stale} = Calls.accept_call(recipient_scope, audio.call_id, "VIDEO")
        assert {:error, :unauthenticated} = Calls.accept_call(nil, audio.call_id, :audio)

        reloaded = Repo.get!(CallAttempt, audio.call_id)
        assert reloaded.state == :ringing
        assert is_nil(reloaded.accepted_at)

        assert {:ok, declined} = Calls.decline_call(recipient_scope, audio.call_id)
        assert declined.terminal_outcome == :declined

        assert {:ok, %{call: video}} =
                 Calls.start_call(caller_scope, direct_conversation.id, :video)

        assert {:error, :stale} = Calls.accept_call(recipient_scope, audio.call_id, :video)
        assert {:ok, accepted_video} = Calls.accept_call(recipient_scope, video.call_id, :audio)
        assert accepted_video.media_intent == :video
        assert accepted_video.answer_mode == :audio
        assert {:ok, _} = Calls.leave_call(recipient_scope, video.call_id)

        assert {:ok, %{call: former_friend_video}} =
                 Calls.start_call(caller_scope, direct_conversation.id, :video)

        assert Repo.get!(CallAttempt, video.call_id).state == :terminal

        assert :ok = Friendships.remove_friend(recipient_scope, friendship.id)

        assert {:error, :not_found} =
                 Calls.accept_call(recipient_scope, former_friend_video.call_id, :video)

        assert Repo.get!(CallAttempt, former_friend_video.call_id).terminal_outcome ==
                 :relationship_ended
      end)
    end

    test "returns current terminal truth for the same Call ID and cannot mutate a later attempt" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("accept_stale_id")

      assert {:ok, %{call: first}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      assert {:ok, declined} = Calls.decline_call(recipient_scope, first.call_id)

      assert {:ok, again} = Calls.accept_call(recipient_scope, first.call_id, :audio)
      assert again.call_id == first.call_id
      assert again.terminal_outcome == :declined
      assert again.ended_at == declined.ended_at

      assert {:ok, %{call: later, started?: true}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      assert later.call_id != first.call_id
      later_updated_at = Repo.get!(CallAttempt, later.call_id).updated_at

      assert {:ok, still_declined} = Calls.accept_call(recipient_scope, first.call_id, :audio)
      assert still_declined.call_id == first.call_id
      assert still_declined.terminal_outcome == :declined

      reloaded_later = Repo.get!(CallAttempt, later.call_id)
      assert reloaded_later.state == :ringing
      assert reloaded_later.updated_at == later_updated_at
    end
  end

  describe "leave_call/2" do
    test "lets either participant leave connecting as cancelled and active as ended" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("leave_conn")

      messages_before = Repo.aggregate(DiscordClone.Chat.Message, :count)

      with_accepted_runtime(:held, fn ->
        assert {:ok, %{call: ringing}} =
                 Calls.start_call(caller_scope, direct_conversation.id, :audio)

        assert {:ok, connecting} =
                 Calls.accept_call(recipient_scope, ringing.call_id, :audio)

        assert connecting.state == :connecting
        assert :ok = Calls.subscribe(caller_scope)

        assert {:ok, cancelled} = Calls.leave_call(caller_scope, ringing.call_id)
        assert cancelled.state == :terminal
        assert cancelled.terminal_outcome == :cancelled
        assert missed_call_activity_items(recipient_scope.user.id, ringing.call_id) == []
        assert_receive {:call_cancelled, _}
        assert_call_server_stopped(ringing.call_id)

        coordinator = :sys.get_state(DiscordClone.Calls.CallCoordinator)
        refute Map.has_key?(coordinator.calls_by_id, ringing.call_id)
      end)

      {carol_scope, dave_scope, carol_dave, _friendship} =
        direct_conversation_fixture("leave_act")

      with_accepted_runtime(:ready, fn ->
        assert {:ok, %{call: ringing}} =
                 Calls.start_call(carol_scope, carol_dave.id, :audio)

        assert {:ok, connecting} = Calls.accept_call(dave_scope, ringing.call_id, :audio)
        assert connecting.state == :connecting
        flush_call_server(ringing.call_id)

        assert {:ok, active} = Calls.get_call(dave_scope, ringing.call_id)
        assert active.state == :active

        assert {:ok, ended} = Calls.leave_call(dave_scope, ringing.call_id)
        assert ended.state == :terminal
        assert ended.terminal_outcome == :ended
        assert missed_call_activity_items(dave_scope.user.id, ringing.call_id) == []
        assert_call_server_stopped(ringing.call_id)
        assert Repo.aggregate(DiscordClone.Chat.Message, :count) == messages_before
      end)
    end

    test "repeated leave returns durable truth and ringing leave is stale" do
      with_accepted_runtime(:ready, fn ->
        {caller_scope, recipient_scope, direct_conversation, _friendship} =
          direct_conversation_fixture("leave_repeat")

        outsider_scope = user_scope_fixture(user_fixture(username: "leave_repeat_out"))

        assert {:ok, %{call: ringing}} =
                 Calls.start_call(caller_scope, direct_conversation.id, :audio)

        assert {:error, :stale} = Calls.leave_call(caller_scope, ringing.call_id)
        assert {:error, :stale} = Calls.leave_call(recipient_scope, ringing.call_id)
        assert {:error, :not_found} = Calls.leave_call(outsider_scope, ringing.call_id)
        assert Repo.get!(CallAttempt, ringing.call_id).state == :ringing

        assert {:ok, connecting} = Calls.accept_call(recipient_scope, ringing.call_id, :audio)
        assert connecting.state == :connecting
        flush_call_server(ringing.call_id)

        assert {:ok, ended} = Calls.leave_call(caller_scope, ringing.call_id)
        assert ended.terminal_outcome == :ended
        ended_updated_at = Repo.get!(CallAttempt, ringing.call_id).updated_at

        assert {:ok, again} = Calls.leave_call(recipient_scope, ringing.call_id)
        assert again.call_id == ringing.call_id
        assert again.terminal_outcome == :ended
        assert again.ended_at == ended.ended_at
        assert Repo.get!(CallAttempt, ringing.call_id).updated_at == ended_updated_at
      end)
    end
  end

  describe "accepted runtime outcomes" do
    test "held runtime keeps the committed attempt connecting" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("runtime_held")

      with_accepted_runtime(:held, fn ->
        assert {:ok, %{call: ringing}} =
                 Calls.start_call(caller_scope, direct_conversation.id, :audio)

        assert {:ok, connecting} =
                 Calls.accept_call(recipient_scope, ringing.call_id, :audio)

        flush_call_server(ringing.call_id)
        assert connecting.state == :connecting
        assert Repo.get!(CallAttempt, ringing.call_id).state == :connecting
        assert CallServer.running?(ringing.call_id)
      end)
    end

    test "capacity and generic failures commit matching terminals without Activity" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("runtime_cap")

      with_accepted_runtime(:failed_capacity, fn ->
        assert {:ok, %{call: ringing}} =
                 Calls.start_call(caller_scope, direct_conversation.id, :audio)

        assert {:ok, connecting} =
                 Calls.accept_call(recipient_scope, ringing.call_id, :audio)

        assert connecting.state == :connecting
        flush_call_server(ringing.call_id)

        failed = Repo.get!(CallAttempt, ringing.call_id)
        assert failed.state == :terminal
        assert failed.terminal_outcome == :failed_capacity
        assert missed_call_activity_items(recipient_scope.user.id, ringing.call_id) == []
        assert_call_server_stopped(ringing.call_id)
      end)

      {carol_scope, dave_scope, carol_dave, _friendship} =
        direct_conversation_fixture("runtime_fail")

      with_accepted_runtime(:failed, fn ->
        assert {:ok, %{call: ringing}} =
                 Calls.start_call(carol_scope, carol_dave.id, :audio)

        assert {:ok, connecting} =
                 Calls.accept_call(dave_scope, ringing.call_id, :audio)

        assert connecting.state == :connecting
        flush_call_server(ringing.call_id)

        failed = Repo.get!(CallAttempt, ringing.call_id)
        assert failed.state == :terminal
        assert failed.terminal_outcome == :failed
        assert missed_call_activity_items(dave_scope.user.id, ringing.call_id) == []
        assert_call_server_stopped(ringing.call_id)
      end)
    end

    test "a CallServer crash in connecting or active fails closed as interrupted" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("runtime_crash")

      assert :ok = Calls.subscribe(caller_scope)

      with_accepted_runtime(:held, fn ->
        assert {:ok, %{call: ringing}} =
                 Calls.start_call(caller_scope, direct_conversation.id, :audio)

        assert {:ok, connecting} =
                 Calls.accept_call(recipient_scope, ringing.call_id, :audio)

        assert connecting.state == :connecting
        [{pid, _}] = Registry.lookup(DiscordClone.Calls.CallRegistry, ringing.call_id)
        ref = Process.monitor(pid)
        :ok = DynamicSupervisor.terminate_child(DiscordClone.Calls.CallSupervisor, pid)
        assert_receive {:DOWN, ^ref, :process, ^pid, _reason}

        await_interrupted(ringing.call_id)

        interrupted = Repo.get!(CallAttempt, ringing.call_id)
        assert interrupted.state == :terminal
        assert interrupted.terminal_outcome == :interrupted
        assert missed_call_activity_items(recipient_scope.user.id, ringing.call_id) == []
        assert_receive {:call_interrupted, projection}
        assert projection.call_id == ringing.call_id

        coordinator = :sys.get_state(DiscordClone.Calls.CallCoordinator)
        refute Map.has_key?(coordinator.calls_by_id, ringing.call_id)
        refute CallServer.running?(ringing.call_id)
      end)

      {carol_scope, dave_scope, carol_dave, _friendship} =
        direct_conversation_fixture("runtime_crash_active")

      with_accepted_runtime(:ready, fn ->
        assert {:ok, %{call: active_ringing}} =
                 Calls.start_call(carol_scope, carol_dave.id, :audio)

        assert {:ok, %{state: :connecting}} =
                 Calls.accept_call(dave_scope, active_ringing.call_id, :audio)

        flush_call_server(active_ringing.call_id)
        assert Repo.get!(CallAttempt, active_ringing.call_id).state == :active

        [{active_pid, _}] =
          Registry.lookup(DiscordClone.Calls.CallRegistry, active_ringing.call_id)

        active_ref = Process.monitor(active_pid)
        :ok = DynamicSupervisor.terminate_child(DiscordClone.Calls.CallSupervisor, active_pid)
        assert_receive {:DOWN, ^active_ref, :process, ^active_pid, _reason}
        await_interrupted(active_ringing.call_id)
        assert Repo.get!(CallAttempt, active_ringing.call_id).terminal_outcome == :interrupted
        assert missed_call_activity_items(dave_scope.user.id, active_ringing.call_id) == []
        refute CallServer.running?(active_ringing.call_id)
      end)
    end

    test "accepted runtime scheduling failure fails closed instead of stranding connecting" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("runtime_schedule_error")

      with_accepted_runtime(:schedule_error, fn ->
        assert {:ok, %{call: ringing}} =
                 Calls.start_call(caller_scope, direct_conversation.id, :audio)

        assert {:ok, terminal} = Calls.accept_call(recipient_scope, ringing.call_id, :audio)
        assert terminal.state == :terminal
        assert terminal.terminal_outcome == :failed
        assert Repo.get!(CallAttempt, ringing.call_id).terminal_outcome == :failed
        assert missed_call_activity_items(recipient_scope.user.id, ringing.call_id) == []
        assert_call_server_stopped(ringing.call_id)
      end)
    end
  end

  defp with_accepted_runtime(result, fun) do
    previous_runtime = Application.get_env(:discord_clone, :accepted_call_runtime)
    previous_result = Application.get_env(:discord_clone, :accepted_call_runtime_result)

    Application.put_env(:discord_clone, :accepted_call_runtime, ScriptedAcceptedCallRuntime)
    Application.put_env(:discord_clone, :accepted_call_runtime_result, result)

    try do
      fun.()
    after
      restore_env(:accepted_call_runtime, previous_runtime)
      restore_env(:accepted_call_runtime_result, previous_result)
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:discord_clone, key)
  defp restore_env(key, value), do: Application.put_env(:discord_clone, key, value)

  defp force_connecting!(call_id) do
    CallAttempt
    |> Repo.get!(call_id)
    |> CallAttempt.accept_changeset(DateTime.utc_now(:microsecond))
    |> Repo.update!()
  end

  # `flush_call_server/1` is shared via `DiscordClone.CallsFixtures`.
  defp await_interrupted(call_id) do
    deadline = System.monotonic_time(:millisecond) + 1_000
    await_interrupted(call_id, deadline)
  end

  defp await_interrupted(call_id, deadline) do
    attempt = Repo.get!(CallAttempt, call_id)
    coordinator = Process.whereis(DiscordClone.Calls.CallCoordinator)

    if coordinator do
      _ = :sys.get_state(coordinator)
    end

    cond do
      attempt.state == :terminal and attempt.terminal_outcome == :interrupted ->
        :ok

      System.monotonic_time(:millisecond) < deadline ->
        :erlang.yield()
        await_interrupted(call_id, deadline)

      true ->
        flunk("expected Call Attempt #{call_id} to become interrupted")
    end
  end

  defp assert_call_server_stopped(call_id) do
    deadline = System.monotonic_time(:millisecond) + 1_000
    assert_call_server_stopped(call_id, deadline)
  end

  defp assert_call_server_stopped(call_id, deadline) do
    _ = :sys.get_state(DiscordClone.Calls.CallRegistry)

    cond do
      Registry.lookup(DiscordClone.Calls.CallRegistry, call_id) == [] ->
        :ok

      System.monotonic_time(:millisecond) < deadline ->
        :erlang.yield()
        assert_call_server_stopped(call_id, deadline)

      true ->
        flunk("expected CallServer for #{call_id} to leave CallRegistry")
    end
  end

  defp contains_pid?(value) when is_pid(value), do: true

  defp contains_pid?(value) when is_map(value) do
    value
    |> Map.values()
    |> Enum.any?(&contains_pid?/1)
  end

  defp contains_pid?(value) when is_list(value), do: Enum.any?(value, &contains_pid?/1)
  defp contains_pid?(_value), do: false
end
