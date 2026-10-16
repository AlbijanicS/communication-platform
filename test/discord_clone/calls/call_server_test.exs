defmodule DiscordClone.Calls.CallServerTest do
  use DiscordClone.DataCase, async: false

  import DiscordClone.CallsFixtures

  alias DiscordClone.Activities.ActivityItem
  alias DiscordClone.Calls
  alias DiscordClone.Calls.{CallAttempt, CallServer}
  alias DiscordClone.Chat.Message
  alias DiscordClone.Repo

  setup do
    start_supervised!(DiscordClone.Calls.Supervisor)
    DiscordClone.Calls.CallCoordinator.begin_recovery()
    await_recovery_finished()
    :ok
  end

  describe "registration" do
    test "register is idempotent, unregister is safe, and no durable row changes" do
      {caller_scope, _recipient_scope, started} = start_ringing("cs_register")
      attempt_before = Repo.get!(CallAttempt, started.call_id)
      activity_before = Repo.aggregate(ActivityItem, :count)
      messages_before = Repo.aggregate(Message, :count)

      assert :ok = CallServer.register(started.call_id, caller_scope.user.id, :caller, "conn-1")
      assert :ok = CallServer.register(started.call_id, caller_scope.user.id, :caller, "conn-1")
      assert :ok = CallServer.unregister(started.call_id, "conn-1")
      assert :ok = CallServer.unregister(started.call_id, "conn-1")
      assert :ok = CallServer.register(started.call_id, caller_scope.user.id, :caller, "conn-1")

      assert Repo.get!(CallAttempt, started.call_id) == attempt_before
      assert Repo.aggregate(ActivityItem, :count) == activity_before
      assert Repo.aggregate(Message, :count) == messages_before
      assert CallServer.answer_mode(started.call_id) == nil
    end

    test "a missing or stopped CallServer tolerates registration and ownership reads" do
      assert :ok =
               CallServer.register(Ecto.UUID.generate(), Ecto.UUID.generate(), :caller, "conn")

      assert :ok = CallServer.unregister(Ecto.UUID.generate(), "conn")
      assert CallServer.ownership(Ecto.UUID.generate(), :caller, "conn") == nil
      assert CallServer.ownership(Ecto.UUID.generate(), :recipient, "conn") == nil

      {caller_scope, _recipient_scope, started} = start_ringing("cs_missing")
      CallServer.stop(started.call_id)

      assert :ok = CallServer.register(started.call_id, caller_scope.user.id, :caller, "conn")
      assert :ok = CallServer.unregister(started.call_id, "conn")
      assert CallServer.ownership(started.call_id, :caller, "conn") == nil
    end

    test "a killed registering process unregisters through its monitor" do
      {caller_scope, _recipient_scope, started} = start_ringing("cs_monitor")
      parent = self()

      pid =
        start_supervised!(
          {Task,
           fn ->
             :ok =
               CallServer.register(
                 started.call_id,
                 caller_scope.user.id,
                 :caller,
                 "conn-monitor"
               )

             send(parent, :registered)

             receive do
               :stop -> :ok
             end
           end}
        )

      assert_receive :registered
      assert registered?(started.call_id, "conn-monitor")

      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

      assert await_registrations(started.call_id, fn registrations ->
               not Map.has_key?(registrations, "conn-monitor")
             end)

      # Rejoining with the same identity is a fresh registration, not a revival.
      assert :ok =
               CallServer.register(started.call_id, caller_scope.user.id, :caller, "conn-monitor")

      assert registered?(started.call_id, "conn-monitor")
    end

    test "re-registering the same connection from the same channel is a no-op" do
      {caller_scope, _recipient_scope, started} = start_ringing("cs_register_idempotent")

      :ok = CallServer.register(started.call_id, caller_scope.user.id, :caller, "conn-1")
      before = server_state(started.call_id)
      entry_before = before.registrations["conn-1"]

      :ok = CallServer.register(started.call_id, caller_scope.user.id, :caller, "conn-1")
      after_state = server_state(started.call_id)
      entry_after = after_state.registrations["conn-1"]

      assert entry_after.monitor_ref == entry_before.monitor_ref
      assert entry_after.seq == entry_before.seq
      assert after_state.registration_seq == before.registration_seq
    end

    test "a delayed terminate from an older channel cannot remove a newer registration" do
      {caller_scope, recipient_scope, started} = start_ringing("cs_stale_unregister")
      parent = self()

      older =
        start_supervised!(
          {Task,
           fn ->
             :ok =
               CallServer.register(
                 started.call_id,
                 caller_scope.user.id,
                 :caller,
                 "conn-shared"
               )

             send(parent, :older_registered)

             receive do
               :unregister -> CallServer.unregister(started.call_id, "conn-shared")
             end
           end}
        )

      assert_receive :older_registered
      older_seq = server_state(started.call_id).registrations["conn-shared"].seq

      # A newer channel for the same Call Connection takes over the registration.
      :ok = CallServer.register(started.call_id, caller_scope.user.id, :caller, "conn-shared")

      ref = Process.monitor(older)
      send(older, :unregister)
      assert_receive {:DOWN, ^ref, :process, ^older, :normal}

      entry = server_state(started.call_id).registrations["conn-shared"]
      assert entry.pid == self()
      assert entry.seq == older_seq

      # The connection's original registration order still wins the fallback.
      :ok = CallServer.register(started.call_id, caller_scope.user.id, :caller, "caller-later")

      assert {:ok, %{state: :connecting}} =
               Calls.accept_call(recipient_scope, started.call_id, :audio, "recipient-winner")

      assert CallServer.ownership(started.call_id, :caller, "conn-shared") == :self
      assert CallServer.ownership(started.call_id, :caller, "caller-later") == :elsewhere
    end

    test "re-registration does not reorder earliest-registered fallback election" do
      {caller_scope, recipient_scope, started} = start_ringing("cs_register_order")

      :ok = CallServer.register(started.call_id, caller_scope.user.id, :caller, "caller-first")
      :ok = CallServer.register(started.call_id, caller_scope.user.id, :caller, "caller-second")
      :ok = CallServer.register(started.call_id, caller_scope.user.id, :caller, "caller-first")

      assert {:ok, %{state: :connecting}} =
               Calls.accept_call(recipient_scope, started.call_id, :audio, "recipient-winner")

      assert CallServer.ownership(started.call_id, :caller, "caller-first") == :self
      assert CallServer.ownership(started.call_id, :caller, "caller-second") == :elsewhere
    end
  end

  describe "ringing ownership" do
    test "the recorded start connection is self, sibling callers are elsewhere, recipients are unclaimed" do
      {_caller_scope, _recipient_scope, started} =
        start_ringing("cs_ring", caller_connection_id: "caller-preferred")

      assert CallServer.ownership(started.call_id, :caller, "caller-preferred") == :self
      assert CallServer.ownership(started.call_id, :caller, "caller-sibling") == :elsewhere
      assert CallServer.ownership(started.call_id, :recipient, "recipient-any") == :unclaimed
    end

    test "a start without protocol-only owner metadata leaves every caller elsewhere" do
      {_caller_scope, _recipient_scope, started} = start_ringing("cs_ring_none")

      assert CallServer.ownership(started.call_id, :caller, "caller-any") == :elsewhere
      assert CallServer.ownership(started.call_id, :recipient, "recipient-any") == :unclaimed
    end

    test "a departed preferred caller does not revive self when its connection rejoins" do
      {caller_scope, recipient_scope, started} =
        start_ringing("cs_ring_departed", caller_connection_id: "caller-preferred")

      :ok =
        CallServer.register(started.call_id, caller_scope.user.id, :caller, "caller-preferred")

      assert CallServer.ownership(started.call_id, :caller, "caller-preferred") == :self

      :ok = CallServer.unregister(started.call_id, "caller-preferred")

      assert CallServer.ownership(started.call_id, :caller, "caller-preferred") == :elsewhere
      assert CallServer.ownership(started.call_id, :caller, "caller-sibling") == :elsewhere
      assert CallServer.ownership(started.call_id, :recipient, "recipient-any") == :unclaimed

      :ok = CallServer.register(started.call_id, caller_scope.user.id, :caller, "caller-fallback")

      # The ringing rebroadcast makes the same Call Connection rejoin from a
      # fresh channel; the new registration must not restore priority over the
      # already-registered fallback.
      :ok =
        CallServer.register(started.call_id, caller_scope.user.id, :caller, "caller-preferred")

      assert CallServer.ownership(started.call_id, :caller, "caller-preferred") == :elsewhere

      assert {:ok, %{state: :connecting}} =
               Calls.accept_call(recipient_scope, started.call_id, :audio, "recipient-winner")

      assert CallServer.ownership(started.call_id, :caller, "caller-fallback") == :self
      assert CallServer.ownership(started.call_id, :caller, "caller-preferred") == :elsewhere
    end

    test "a rejoined preferred caller can win as the only registered fallback" do
      {caller_scope, recipient_scope, started} =
        start_ringing("cs_ring_departed_only", caller_connection_id: "caller-preferred")

      :ok =
        CallServer.register(started.call_id, caller_scope.user.id, :caller, "caller-preferred")

      :ok = CallServer.unregister(started.call_id, "caller-preferred")

      :ok =
        CallServer.register(started.call_id, caller_scope.user.id, :caller, "caller-preferred")

      assert {:ok, %{state: :connecting}} =
               Calls.accept_call(recipient_scope, started.call_id, :audio, "recipient-winner")

      assert CallServer.ownership(started.call_id, :caller, "caller-preferred") == :self
      assert CallServer.ownership(started.call_id, :caller, "caller-sibling") == :elsewhere
    end

    test "a rejoined non-preferred caller stays eligible for deterministic fallback" do
      {caller_scope, recipient_scope, started} =
        start_ringing("cs_rejoin_fallback", caller_connection_id: "caller-gone")

      :ok =
        CallServer.register(started.call_id, caller_scope.user.id, :caller, "caller-rejoined")

      :ok = CallServer.unregister(started.call_id, "caller-rejoined")

      :ok =
        CallServer.register(started.call_id, caller_scope.user.id, :caller, "caller-rejoined")

      :ok = CallServer.register(started.call_id, caller_scope.user.id, :caller, "caller-late")

      assert {:ok, %{state: :connecting}} =
               Calls.accept_call(recipient_scope, started.call_id, :audio, "recipient-winner")

      assert CallServer.ownership(started.call_id, :caller, "caller-rejoined") == :self
      assert CallServer.ownership(started.call_id, :caller, "caller-late") == :elsewhere
    end
  end

  describe "accepted ownership" do
    test "the first committed recipient connection wins and later sibling accepts stay elsewhere" do
      {caller_scope, recipient_scope, started} =
        start_ringing("cs_accept", caller_connection_id: "caller-preferred")

      :ok =
        CallServer.register(
          started.call_id,
          recipient_scope.user.id,
          :recipient,
          "recipient-winner"
        )

      :ok =
        CallServer.register(started.call_id, caller_scope.user.id, :caller, "caller-preferred")

      assert {:ok, %{state: :connecting}} =
               Calls.accept_call(recipient_scope, started.call_id, :audio, "recipient-winner")

      assert CallServer.ownership(started.call_id, :recipient, "recipient-winner") == :self
      assert CallServer.ownership(started.call_id, :recipient, "recipient-sibling") == :elsewhere
      assert CallServer.ownership(started.call_id, :caller, "caller-preferred") == :self
      assert CallServer.ownership(started.call_id, :caller, "caller-sibling") == :elsewhere

      # A duplicate accept from a sibling returns committed truth without
      # replacing the winner or the committed Answer Mode.
      assert {:ok, %{state: accepted_state, answer_mode: :audio}} =
               Calls.accept_call(recipient_scope, started.call_id, :audio, "recipient-sibling")

      assert accepted_state in [:connecting, :active]
      assert CallServer.answer_mode(started.call_id) == :audio
      assert CallServer.ownership(started.call_id, :recipient, "recipient-winner") == :self
      assert CallServer.ownership(started.call_id, :recipient, "recipient-sibling") == :elsewhere
    end

    test "video invitations accept both modes with the accepting connection as winner" do
      for answer_mode <- [:video, :audio] do
        {_caller_scope, recipient_scope, started} =
          start_ringing("cs_video_#{answer_mode}",
            caller_connection_id: "caller-preferred",
            media_intent: :video
          )

        winner = "recipient-#{answer_mode}"

        assert {:ok, %{state: :connecting, answer_mode: ^answer_mode}} =
                 Calls.accept_call(recipient_scope, started.call_id, answer_mode, winner)

        assert CallServer.ownership(started.call_id, :recipient, winner) == :self
        assert CallServer.ownership(started.call_id, :recipient, "other-tab") == :elsewhere
      end
    end

    test "caller fallback elects the earliest registered caller connection" do
      {caller_scope, recipient_scope, started} = start_ringing("cs_fallback")

      :ok = CallServer.register(started.call_id, caller_scope.user.id, :caller, "caller-second")
      :ok = CallServer.register(started.call_id, caller_scope.user.id, :caller, "caller-first")
      :ok = CallServer.register(started.call_id, caller_scope.user.id, :caller, "caller-third")

      assert {:ok, %{state: :connecting}} =
               Calls.accept_call(recipient_scope, started.call_id, :audio, "recipient-winner")

      assert CallServer.ownership(started.call_id, :caller, "caller-second") == :self
      assert CallServer.ownership(started.call_id, :caller, "caller-first") == :elsewhere
      assert CallServer.ownership(started.call_id, :caller, "caller-third") == :elsewhere
    end

    test "the recorded preferred caller wins over an earlier registered sibling" do
      {caller_scope, recipient_scope, started} =
        start_ringing("cs_preferred_wins", caller_connection_id: "caller-preferred")

      :ok = CallServer.register(started.call_id, caller_scope.user.id, :caller, "caller-early")

      :ok =
        CallServer.register(started.call_id, caller_scope.user.id, :caller, "caller-preferred")

      assert {:ok, %{state: :connecting}} =
               Calls.accept_call(recipient_scope, started.call_id, :audio, "recipient-winner")

      assert CallServer.ownership(started.call_id, :caller, "caller-preferred") == :self
      assert CallServer.ownership(started.call_id, :caller, "caller-early") == :elsewhere
    end

    test "an unregistered preferred caller falls back to the earliest registered caller" do
      {caller_scope, recipient_scope, started} =
        start_ringing("cs_preferred_gone", caller_connection_id: "caller-preferred")

      :ok = CallServer.register(started.call_id, caller_scope.user.id, :caller, "caller-first")
      :ok = CallServer.register(started.call_id, caller_scope.user.id, :caller, "caller-second")

      assert {:ok, %{state: :connecting}} =
               Calls.accept_call(recipient_scope, started.call_id, :audio, "recipient-winner")

      assert CallServer.ownership(started.call_id, :caller, "caller-first") == :self
      assert CallServer.ownership(started.call_id, :caller, "caller-second") == :elsewhere
      assert CallServer.ownership(started.call_id, :caller, "caller-preferred") == :elsewhere
    end

    test "the caller side is unclaimed when no caller connection ever registered" do
      {_caller_scope, recipient_scope, started} = start_ringing("cs_no_caller")

      assert {:ok, %{state: :connecting}} =
               Calls.accept_call(recipient_scope, started.call_id, :audio, "recipient-winner")

      assert CallServer.ownership(started.call_id, :caller, "caller-any") == :unclaimed
    end

    test "a winner disconnect clears that role to unclaimed without transfer" do
      {_caller_scope, recipient_scope, started} =
        start_ringing("cs_winner_gone", caller_connection_id: "caller-winner")

      :ok =
        CallServer.register(
          started.call_id,
          recipient_scope.user.id,
          :recipient,
          "recipient-winner"
        )

      assert {:ok, %{state: :connecting}} =
               Calls.accept_call(recipient_scope, started.call_id, :audio, "recipient-winner")

      :ok = CallServer.unregister(started.call_id, "recipient-winner")

      assert CallServer.ownership(started.call_id, :recipient, "recipient-sibling") == :unclaimed
      assert CallServer.ownership(started.call_id, :recipient, "recipient-winner") == :unclaimed

      :ok = CallServer.unregister(started.call_id, "caller-winner")

      assert CallServer.ownership(started.call_id, :caller, "caller-sibling") == :unclaimed
    end

    test "a recipient connection that re-registers before accepting wins its fresh acceptance" do
      {_caller_scope, recipient_scope, started} = start_ringing("cs_recipient_rejoin")

      :ok =
        CallServer.register(
          started.call_id,
          recipient_scope.user.id,
          :recipient,
          "recipient-rejoined"
        )

      :ok = CallServer.unregister(started.call_id, "recipient-rejoined")

      :ok =
        CallServer.register(
          started.call_id,
          recipient_scope.user.id,
          :recipient,
          "recipient-rejoined"
        )

      assert {:ok, %{state: :connecting}} =
               Calls.accept_call(recipient_scope, started.call_id, :audio, "recipient-rejoined")

      assert CallServer.ownership(started.call_id, :recipient, "recipient-rejoined") == :self
      assert CallServer.ownership(started.call_id, :recipient, "recipient-sibling") == :elsewhere
    end

    test "a claimant that dies after its durable commit leaves the role unclaimed" do
      {_caller_scope, recipient_scope, started} = start_ringing("cs_dead_claimant")
      parent = self()

      pid =
        start_supervised!(
          {Task,
           fn ->
             :ok =
               CallServer.register(
                 started.call_id,
                 recipient_scope.user.id,
                 :recipient,
                 "conn-dead"
               )

             {:owner, claim_ref} =
               CallServer.claim_answer_mode(started.call_id, :audio, "conn-dead")

             send(parent, {:claimed, claim_ref})

             receive do
               :stop -> :ok
             end
           end}
        )

      assert_receive {:claimed, _claim_ref}
      assert registered?(started.call_id, "conn-dead")

      # The dead claimant's durable `ringing -> connecting` commit survives it.
      now = DateTime.utc_now(:microsecond)

      Repo.get!(CallAttempt, started.call_id)
      |> Ecto.Changeset.change(%{state: :connecting, accepted_at: now})
      |> Repo.update!()

      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

      assert await_registrations(started.call_id, fn registrations ->
               not Map.has_key?(registrations, "conn-dead")
             end)

      assert {:ok, %{state: :connecting, answer_mode: :audio}} =
               Calls.accept_call(recipient_scope, started.call_id, :audio, "conn-live")

      assert CallServer.answer_mode(started.call_id) == :audio
      assert CallServer.ownership(started.call_id, :recipient, "conn-dead") == :unclaimed
      assert CallServer.ownership(started.call_id, :recipient, "conn-live") == :unclaimed
    end

    test "an abandoned claim cannot bind a connection that departed and rejoined" do
      {_caller_scope, recipient_scope, started} = start_ringing("cs_claim_generation")
      parent = self()

      pid =
        start_supervised!(
          {Task,
           fn ->
             :ok =
               CallServer.register(
                 started.call_id,
                 recipient_scope.user.id,
                 :recipient,
                 "conn-claimed"
               )

             {:owner, claim_ref} =
               CallServer.claim_answer_mode(started.call_id, :audio, "conn-claimed")

             send(parent, {:claimed, claim_ref})

             receive do
               :stop -> :ok
             end
           end}
        )

      assert_receive {:claimed, _claim_ref}

      # The claimant's durable `ringing -> connecting` commit survives its death.
      now = DateTime.utc_now(:microsecond)

      Repo.get!(CallAttempt, started.call_id)
      |> Ecto.Changeset.change(%{state: :connecting, accepted_at: now})
      |> Repo.update!()

      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

      assert await_registrations(started.call_id, fn registrations ->
               not Map.has_key?(registrations, "conn-claimed")
             end)

      # The same Call Connection rejoins from a fresh channel before the
      # abandoned claim is reconciled. The pre-departure claim must not revive
      # it, even though the connection is live again.
      :ok =
        CallServer.register(
          started.call_id,
          recipient_scope.user.id,
          :recipient,
          "conn-claimed"
        )

      assert {:ok, %{state: :connecting, answer_mode: :audio}} =
               Calls.accept_call(recipient_scope, started.call_id, :audio, "conn-reconciler")

      assert CallServer.answer_mode(started.call_id) == :audio
      assert CallServer.ownership(started.call_id, :recipient, "conn-claimed") == :unclaimed
      assert CallServer.ownership(started.call_id, :recipient, "conn-reconciler") == :unclaimed
    end

    test "unregistering a non-winner leaves ownership untouched" do
      {caller_scope, recipient_scope, started} =
        start_ringing("cs_non_winner", caller_connection_id: "caller-winner")

      :ok =
        CallServer.register(
          started.call_id,
          recipient_scope.user.id,
          :recipient,
          "recipient-winner"
        )

      :ok =
        CallServer.register(
          started.call_id,
          recipient_scope.user.id,
          :recipient,
          "recipient-loser"
        )

      :ok = CallServer.register(started.call_id, caller_scope.user.id, :caller, "caller-winner")

      assert {:ok, %{state: :connecting}} =
               Calls.accept_call(recipient_scope, started.call_id, :audio, "recipient-winner")

      :ok = CallServer.unregister(started.call_id, "recipient-loser")

      assert CallServer.ownership(started.call_id, :recipient, "recipient-winner") == :self
      assert CallServer.ownership(started.call_id, :caller, "caller-winner") == :self
    end
  end

  describe "exact media-runtime observation" do
    setup do
      DiscordClone.MediaFixtures.setup_coordinator_pair_state!()
      on_exit(&DiscordClone.MediaFixtures.reset_coordinator_pair_state!/0)
      :ok
    end

    test "replacement flushes old DOWN and stale publication cannot displace its monitor" do
      {caller, recipient, call} = start_ringing("monitor_replace")
      call_id = call.call_id
      assert {:ok, _} = Calls.accept_call(recipient, call_id, :audio)
      assert :ok = CallServer.await_ready(call_id)
      [{server, _}] = Registry.lookup(DiscordClone.Calls.CallRegistry, call_id)

      old = DiscordClone.MediaFixtures.start_ready_call_target(call_id, id: :old_target)

      assert {:ok, %{runtime_generation: old_generation}} =
               DiscordClone.Media.DirectCallTarget.identity(old)

      # Controlled publication input tests exact observer fencing. It does
      # not introduce a production policy for restarting accepted media.
      send(server, {:call_media_runtime, call_id, old_generation, old})
      assert :ok = CallServer.await_ready(call_id)
      assert {:monitors, monitors} = Process.info(server, :monitors)
      assert {:process, old} in monitors

      replacement =
        DiscordClone.MediaFixtures.start_ready_call_target(call_id, id: :replacement_target)

      assert {:ok, %{runtime_generation: generation}} =
               DiscordClone.Media.DirectCallTarget.identity(replacement)

      :ok = :sys.suspend(server)
      old_monitor = Process.monitor(old)

      try do
        send(server, {:call_media_runtime, call_id, generation, replacement})
        Process.exit(old, :kill)
        assert_receive {:DOWN, ^old_monitor, :process, ^old, :killed}
        send(server, {:call_media_runtime, call_id, old_generation, old})
        send(server, {:call_media_runtime, call_id, generation, self()})
        send(server, {:call_media_runtime, Ecto.UUID.generate(), generation, replacement})
        send(server, {:DOWN, make_ref(), :process, replacement, :late})
      after
        :ok = :sys.resume(server)
      end

      assert :ok = CallServer.await_ready(call_id)
      assert {:monitors, monitors} = Process.info(server, :monitors)
      assert {:process, replacement} in monitors
      refute {:process, old} in monitors
      refute {:process, self()} in monitors
      assert {:ok, %{state: :active}} = Calls.get_call(caller, call_id)

      assert {:ok, %{target_pid: ^replacement, runtime_generation: ^generation}} =
               {:ok,
                DiscordClone.Media.AdmissionCoordinator.call_target_runtime_identity(call_id)}

      assert {:ok, %{terminal_outcome: :ended}} = Calls.leave_call(caller, call_id)
    end
  end

  defp start_ringing(suffix, opts \\ []) do
    {caller_scope, recipient_scope, direct_conversation, _friendship} =
      direct_conversation_fixture(suffix)

    media_intent = Keyword.get(opts, :media_intent, :audio)
    start_opts = Keyword.take(opts, [:caller_connection_id])

    assert {:ok, %{call: started, started?: true}} =
             Calls.start_call(caller_scope, direct_conversation.id, media_intent, start_opts)

    {caller_scope, recipient_scope, started}
  end

  defp registered?(call_id, connection_id) do
    call_id
    |> server_state()
    |> Map.fetch!(:registrations)
    |> Map.has_key?(connection_id)
  end

  defp await_registrations(call_id, predicate, deadline_ms \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    await_registrations_until(call_id, predicate, deadline)
  end

  defp await_registrations_until(call_id, predicate, deadline) do
    registrations = call_id |> server_state() |> Map.fetch!(:registrations)

    cond do
      predicate.(registrations) ->
        true

      System.monotonic_time(:millisecond) < deadline ->
        :erlang.yield()
        await_registrations_until(call_id, predicate, deadline)

      true ->
        false
    end
  end

  defp server_state(call_id) do
    [{pid, _value}] = Registry.lookup(DiscordClone.Calls.CallRegistry, call_id)
    :sys.get_state(pid)
  catch
    :exit, _reason -> flunk("expected a running CallServer for #{inspect(call_id)}")
  end
end
