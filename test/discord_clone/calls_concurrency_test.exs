defmodule DiscordClone.CallsConcurrencyTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import DiscordClone.AccountsFixtures
  import DiscordClone.CallsFixtures

  alias DiscordClone.Activities.ActivityItem
  alias DiscordClone.Calls
  alias DiscordClone.Calls.{CallAttempt, CallServer, ScriptedAcceptedCallRuntime}
  alias DiscordClone.Chat
  alias DiscordClone.Chat.{Conversation, DirectConversation}
  alias DiscordClone.Friendships
  alias DiscordClone.Friendships.Relationship
  alias DiscordClone.Repo
  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    start_supervised!(DiscordClone.Calls.Supervisor)

    coordinator_owner =
      start_supervised!(%{
        id: :call_coordinator_repo_owner,
        start:
          {Agent, :start_link,
           [
             fn ->
               :ok = Sandbox.checkout(Repo, sandbox: false)
             end
           ]}
      })

    :ok =
      Sandbox.allow(
        Repo,
        coordinator_owner,
        Process.whereis(DiscordClone.Calls.CallCoordinator)
      )

    DiscordClone.Calls.CallCoordinator.begin_recovery()
    await_recovery_finished()
    on_exit(fn -> Sandbox.checkin(Repo) end)
    %{coordinator_owner: coordinator_owner}
  end

  test "concurrent declines of the same ringing Call ID serialize on the attempt row" do
    {caller_scope, recipient_scope, direct_conversation, friendship} =
      unique_direct_conversation_fixture("dl")

    try do
      assert {:ok, %{call: ringing}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      {first, second} =
        overlapping_commands(ringing.call_id, fn ->
          Calls.decline_call(recipient_scope, ringing.call_id)
        end)

      assert {:ok, first_projection} = first
      assert {:ok, second_projection} = second
      assert first_projection.call_id == ringing.call_id
      assert second_projection.call_id == ringing.call_id
      assert first_projection.terminal_outcome == :declined
      assert second_projection.terminal_outcome == :declined
      assert first_projection.ended_at == second_projection.ended_at

      reloaded = Repo.get!(CallAttempt, ringing.call_id)
      assert reloaded.state == :terminal
      assert reloaded.terminal_outcome == :declined
      assert reloaded.ended_at == first_projection.ended_at
      assert missed_call_activity_items(recipient_scope.user.id, ringing.call_id) == []
    after
      cleanup!(caller_scope, recipient_scope, direct_conversation, friendship)
    end
  end

  test "concurrent cancels of the same ringing Call ID serialize on the attempt row" do
    {caller_scope, recipient_scope, direct_conversation, friendship} =
      unique_direct_conversation_fixture("cl")

    try do
      assert {:ok, %{call: ringing}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      {first, second} =
        overlapping_commands(ringing.call_id, fn ->
          Calls.cancel_call(caller_scope, ringing.call_id)
        end)

      assert {:ok, first_projection} = first
      assert {:ok, second_projection} = second
      assert first_projection.call_id == ringing.call_id
      assert second_projection.call_id == ringing.call_id
      assert first_projection.terminal_outcome == :cancelled
      assert second_projection.terminal_outcome == :cancelled
      assert first_projection.ended_at == second_projection.ended_at

      reloaded = Repo.get!(CallAttempt, ringing.call_id)
      assert reloaded.state == :terminal
      assert reloaded.terminal_outcome == :cancelled
      assert reloaded.ended_at == first_projection.ended_at
      assert length(missed_call_activity_items(recipient_scope.user.id, ringing.call_id)) == 1
    after
      cleanup!(caller_scope, recipient_scope, direct_conversation, friendship)
    end
  end

  test "concurrent timeouts of the same due ringing Call ID serialize on the attempt row" do
    {caller_scope, recipient_scope, direct_conversation, friendship} =
      unique_direct_conversation_fixture("to")

    try do
      assert {:ok, %{call: ringing}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      make_ringing_deadline_due!(ringing.call_id)

      {first, second} =
        overlapping_commands(ringing.call_id, fn ->
          Calls.expire_ringing_attempt(ringing.call_id)
        end)

      assert {:ok, first_projection} = first
      assert {:ok, second_projection} = second
      assert first_projection.call_id == ringing.call_id
      assert second_projection.call_id == ringing.call_id
      assert first_projection.terminal_outcome == :timed_out
      assert second_projection.terminal_outcome == :timed_out
      assert first_projection.ended_at == second_projection.ended_at

      reloaded = Repo.get!(CallAttempt, ringing.call_id)
      assert reloaded.state == :terminal
      assert reloaded.terminal_outcome == :timed_out
      assert reloaded.ended_at == first_projection.ended_at
      assert length(missed_call_activity_items(recipient_scope.user.id, ringing.call_id)) == 1
    after
      cleanup!(caller_scope, recipient_scope, direct_conversation, friendship)
    end
  end

  test "accept serializes with timeout, decline, caller cancel, and Friendship removal" do
    previous_runtime = Application.get_env(:discord_clone, :accepted_call_runtime)
    previous_result = Application.get_env(:discord_clone, :accepted_call_runtime_result)
    Application.put_env(:discord_clone, :accepted_call_runtime, ScriptedAcceptedCallRuntime)
    Application.put_env(:discord_clone, :accepted_call_runtime_result, :held)

    try do
      assert_accept_race("at", fn _caller_scope, _recipient_scope, ringing, _friendship ->
        make_ringing_deadline_due!(ringing.call_id)
        Calls.expire_ringing_attempt(ringing.call_id)
      end)

      assert_accept_race("ad", fn _caller_scope, recipient_scope, ringing, _friendship ->
        Calls.decline_call(recipient_scope, ringing.call_id)
      end)

      assert_accept_race("ac", fn caller_scope, _recipient_scope, ringing, _friendship ->
        Calls.cancel_call(caller_scope, ringing.call_id)
      end)

      assert_accept_race("af", fn _caller_scope, recipient_scope, _ringing, friendship ->
        Friendships.remove_friend(recipient_scope, friendship.id)
      end)
    after
      restore_env(:accepted_call_runtime, previous_runtime)
      restore_env(:accepted_call_runtime_result, previous_result)
    end
  end

  test "opposite video answer modes converge on the first committed live mode" do
    previous_runtime = Application.get_env(:discord_clone, :accepted_call_runtime)
    previous_result = Application.get_env(:discord_clone, :accepted_call_runtime_result)
    Application.put_env(:discord_clone, :accepted_call_runtime, ScriptedAcceptedCallRuntime)
    Application.put_env(:discord_clone, :accepted_call_runtime_result, :held)

    {caller_scope, recipient_scope, direct_conversation, friendship} =
      unique_direct_conversation_fixture("vm")

    try do
      assert {:ok, %{call: ringing}} =
               Calls.start_call(caller_scope, direct_conversation.id, :video)

      parent = self()

      start_database_task(:video_accept, fn ->
        send(parent, {:video_accept, Calls.accept_call(recipient_scope, ringing.call_id, :video)})
      end)

      start_database_task(:audio_accept, fn ->
        send(parent, {:audio_accept, Calls.accept_call(recipient_scope, ringing.call_id, :audio)})
      end)

      assert_receive {:video_accept, first}, 1_000
      assert_receive {:audio_accept, second}, 1_000

      assert {:ok, first_projection} = first
      assert {:ok, second_projection} = second
      assert first_projection.answer_mode in [:audio, :video]
      assert second_projection.answer_mode == first_projection.answer_mode
      assert first_projection.media_intent == :video
      assert second_projection.media_intent == :video
      assert Repo.get!(CallAttempt, ringing.call_id).media_intent == :video
      assert Repo.get!(CallAttempt, ringing.call_id).state == :connecting
    after
      restore_env(:accepted_call_runtime, previous_runtime)
      restore_env(:accepted_call_runtime_result, previous_result)
      cleanup!(caller_scope, recipient_scope, direct_conversation, friendship)
    end
  end

  test "concurrent accepts from two recipient connections yield one winner and one mode" do
    previous_runtime = Application.get_env(:discord_clone, :accepted_call_runtime)
    previous_result = Application.get_env(:discord_clone, :accepted_call_runtime_result)
    Application.put_env(:discord_clone, :accepted_call_runtime, ScriptedAcceptedCallRuntime)
    Application.put_env(:discord_clone, :accepted_call_runtime_result, :held)

    {caller_scope, recipient_scope, direct_conversation, friendship} =
      unique_direct_conversation_fixture("cw")

    try do
      assert {:ok, %{call: ringing}} =
               Calls.start_call(caller_scope, direct_conversation.id, :video)

      accepted_at_before = Repo.get!(CallAttempt, ringing.call_id).accepted_at
      parent = self()

      start_database_task(:first_accept, fn ->
        send(
          parent,
          {:first_accept, Calls.accept_call(recipient_scope, ringing.call_id, :video, "conn-one")}
        )
      end)

      start_database_task(:second_accept, fn ->
        send(
          parent,
          {:second_accept,
           Calls.accept_call(recipient_scope, ringing.call_id, :audio, "conn-two")}
        )
      end)

      assert_receive {:first_accept, first}, 1_000
      assert_receive {:second_accept, second}, 1_000

      assert {:ok, first_projection} = first
      assert {:ok, second_projection} = second
      assert first_projection.answer_mode == second_projection.answer_mode
      assert first_projection.media_intent == :video
      assert second_projection.media_intent == :video
      assert first_projection.state in [:connecting, :active]
      assert second_projection.state in [:connecting, :active]

      committed_mode = CallServer.answer_mode(ringing.call_id)
      assert committed_mode == first_projection.answer_mode

      winner = if committed_mode == :video, do: "conn-one", else: "conn-two"
      loser = if winner == "conn-one", do: "conn-two", else: "conn-one"

      assert CallServer.ownership(ringing.call_id, :recipient, winner) == :self
      assert CallServer.ownership(ringing.call_id, :recipient, loser) == :elsewhere

      attempt = Repo.get!(CallAttempt, ringing.call_id)
      assert attempt.state in [:connecting, :active]
      assert attempt.accepted_at != accepted_at_before
    after
      restore_env(:accepted_call_runtime, previous_runtime)
      restore_env(:accepted_call_runtime_result, previous_result)
      cleanup!(caller_scope, recipient_scope, direct_conversation, friendship)
    end
  end

  test "opposite audio accepts from two recipient connections keep one winner" do
    previous_runtime = Application.get_env(:discord_clone, :accepted_call_runtime)
    previous_result = Application.get_env(:discord_clone, :accepted_call_runtime_result)
    Application.put_env(:discord_clone, :accepted_call_runtime, ScriptedAcceptedCallRuntime)
    Application.put_env(:discord_clone, :accepted_call_runtime_result, :held)

    {caller_scope, recipient_scope, direct_conversation, friendship} =
      unique_direct_conversation_fixture("ca")

    try do
      assert {:ok, %{call: ringing}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      parent = self()

      start_database_task(:audio_accept_one, fn ->
        send(
          parent,
          {:audio_accept_one,
           Calls.accept_call(recipient_scope, ringing.call_id, :audio, "conn-a")}
        )
      end)

      start_database_task(:audio_accept_two, fn ->
        send(
          parent,
          {:audio_accept_two,
           Calls.accept_call(recipient_scope, ringing.call_id, :audio, "conn-b")}
        )
      end)

      assert_receive {:audio_accept_one, first}, 1_000
      assert_receive {:audio_accept_two, second}, 1_000
      assert {:ok, %{answer_mode: :audio}} = first
      assert {:ok, %{answer_mode: :audio}} = second
      assert CallServer.answer_mode(ringing.call_id) == :audio

      ownerships =
        [
          CallServer.ownership(ringing.call_id, :recipient, "conn-a"),
          CallServer.ownership(ringing.call_id, :recipient, "conn-b")
        ]
        |> Enum.sort()

      assert ownerships == [:elsewhere, :self]
    after
      restore_env(:accepted_call_runtime, previous_runtime)
      restore_env(:accepted_call_runtime_result, previous_result)
      cleanup!(caller_scope, recipient_scope, direct_conversation, friendship)
    end
  end

  test "start that wins the Friendship lock is ended as relationship_ended by removal" do
    {caller_scope, recipient_scope, direct_conversation, friendship} =
      unique_direct_conversation_fixture("sf")

    parent = self()

    try do
      assert :ok = Calls.subscribe(caller_scope)

      {blocker, holder_pid} = start_direct_conversation_blocker(direct_conversation.id)

      start_database_task(:starter, fn ->
        send(
          parent,
          {:start_result, Calls.start_call(caller_scope, direct_conversation.id, :audio)}
        )
      end)

      assert_blocked_by(holder_pid)

      remover_name = "calls_rm_#{System.unique_integer([:positive])}"

      start_database_task(:remover, fn ->
        set_application_name(remover_name)
        send(parent, {:remove_result, Friendships.remove_friend(recipient_scope, friendship.id)})
      end)

      assert_waiting_on_lock(remover_name)
      refute_receive {:start_result, _result}, 100
      refute_receive {:remove_result, _result}, 100

      send(blocker, {:release_conversation, parent})

      assert_receive {:start_result, {:ok, %{call: ringing, started?: true}}}, 1_000
      assert_receive {:remove_result, :ok}, 1_000

      assert ringing.state == :ringing
      reloaded = Repo.get!(CallAttempt, ringing.call_id)
      assert reloaded.state == :terminal
      assert reloaded.terminal_outcome == :relationship_ended
      assert missed_call_activity_items(recipient_scope.user.id, ringing.call_id) == []
      assert_receive {:call_relationship_ended, projection}
      assert projection.call_id == ringing.call_id

      coordinator = :sys.get_state(DiscordClone.Calls.CallCoordinator)
      refute Map.has_key?(coordinator.calls_by_id, ringing.call_id)
      refute Map.has_key?(coordinator.calls_by_direct_conversation, direct_conversation.id)
      assert Registry.lookup(DiscordClone.Calls.CallRegistry, ringing.call_id) == []
    after
      cleanup!(caller_scope, recipient_scope, direct_conversation, friendship)
    end
  end

  test "removal that wins the Friendship lock makes start return not_friends without a row" do
    {caller_scope, recipient_scope, direct_conversation, friendship} =
      unique_direct_conversation_fixture("rf")

    parent = self()
    remover_name = "calls_rm_#{System.unique_integer([:positive])}"

    try do
      pair_attempts = fn ->
        Repo.aggregate(
          from(call_attempt in CallAttempt,
            where: call_attempt.direct_conversation_id == ^direct_conversation.id
          ),
          :count
        )
      end

      assert pair_attempts.() == 0

      {blocker, _holder_pid} = start_direct_conversation_blocker(direct_conversation.id)

      start_database_task(:remover, fn ->
        set_application_name(remover_name)
        send(parent, {:remove_result, Friendships.remove_friend(recipient_scope, friendship.id)})
      end)

      assert_waiting_on_lock(remover_name)

      %{rows: [[remover_pid]]} =
        SQL.query!(
          Repo,
          "SELECT pid FROM pg_stat_activity WHERE application_name = $1 AND state = 'active'",
          [remover_name]
        )

      start_database_task(:starter, fn ->
        send(
          parent,
          {:start_result, Calls.start_call(caller_scope, direct_conversation.id, :audio)}
        )
      end)

      assert_blocked_by(remover_pid)
      refute_receive {:start_result, _result}, 100
      refute_receive {:remove_result, _result}, 100

      send(blocker, {:release_conversation, parent})

      assert_receive {:remove_result, :ok}, 1_000
      assert_receive {:start_result, {:error, :not_friends}}, 1_000

      assert pair_attempts.() == 0

      assert Repo.all(
               from activity_item in ActivityItem,
                 where:
                   activity_item.recipient_user_id == ^recipient_scope.user.id and
                     activity_item.kind == "missed_direct_call"
             ) == []

      assert Registry.count(DiscordClone.Calls.CallRegistry) == 0

      coordinator = :sys.get_state(DiscordClone.Calls.CallCoordinator)
      assert coordinator.calls_by_id == %{}
      assert coordinator.calls_by_direct_conversation == %{}
    after
      cleanup!(caller_scope, recipient_scope, direct_conversation, friendship)
    end
  end

  test "occupancy stays until the Friendship removal transaction commits" do
    {caller_scope, recipient_scope, direct_conversation, friendship} =
      unique_direct_conversation_fixture("oc")

    parent = self()
    remover_name = "calls_rm_#{System.unique_integer([:positive])}"

    try do
      assert :ok = Calls.subscribe(caller_scope)

      assert {:ok, %{call: ringing}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      assert_receive {:call_ringing, _}
      assert_call_occupancy(ringing.call_id, direct_conversation.id)

      {blocker, _holder_pid} = start_direct_conversation_blocker(direct_conversation.id)

      start_database_task(:remover, fn ->
        set_application_name(remover_name)
        send(parent, {:remove_result, Friendships.remove_friend(recipient_scope, friendship.id)})
      end)

      assert_waiting_on_lock(remover_name)
      refute_receive {:remove_result, _result}, 100
      refute_received {:call_relationship_ended, _}

      still_ringing = Repo.get!(CallAttempt, ringing.call_id)
      assert still_ringing.state == :ringing
      assert is_nil(still_ringing.terminal_outcome)
      assert_call_occupancy(ringing.call_id, direct_conversation.id)
      assert_call_server_ready(ringing.call_id)

      send(blocker, {:release_conversation, parent})

      assert_receive {:remove_result, :ok}, 1_000
      assert_receive {:call_relationship_ended, projection}
      assert projection.call_id == ringing.call_id

      ended = Repo.get!(CallAttempt, ringing.call_id)
      assert ended.state == :terminal
      assert ended.terminal_outcome == :relationship_ended
      assert missed_call_activity_items(recipient_scope.user.id, ringing.call_id) == []

      coordinator = :sys.get_state(DiscordClone.Calls.CallCoordinator)
      refute Map.has_key?(coordinator.calls_by_id, ringing.call_id)
      assert Registry.lookup(DiscordClone.Calls.CallRegistry, ringing.call_id) == []
    after
      cleanup!(caller_scope, recipient_scope, direct_conversation, friendship)
    end
  end

  test "overlapping timeout and cancel serialize on one terminal fact and one missed-call Activity" do
    {caller_scope, recipient_scope, direct_conversation, friendship} =
      unique_direct_conversation_fixture("tc")

    try do
      assert {:ok, %{call: ringing}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      make_ringing_deadline_due!(ringing.call_id)

      {first, second} =
        overlapping_distinct_commands(
          ringing.call_id,
          fn ->
            Calls.expire_ringing_attempt(ringing.call_id)
          end,
          fn ->
            Calls.cancel_call(caller_scope, ringing.call_id)
          end
        )

      assert {:ok, first_projection} = first
      assert {:ok, second_projection} = second
      assert first_projection.call_id == ringing.call_id
      assert second_projection.call_id == ringing.call_id
      assert first_projection.terminal_outcome == second_projection.terminal_outcome
      assert first_projection.terminal_outcome in [:timed_out, :cancelled]
      assert first_projection.ended_at == second_projection.ended_at

      reloaded = Repo.get!(CallAttempt, ringing.call_id)
      assert reloaded.state == :terminal
      assert reloaded.terminal_outcome == first_projection.terminal_outcome
      assert reloaded.ended_at == first_projection.ended_at
      assert length(missed_call_activity_items(recipient_scope.user.id, ringing.call_id)) == 1
    after
      cleanup!(caller_scope, recipient_scope, direct_conversation, friendship)
    end
  end

  test "rejects start_call until durable recovery finishes without writing a second ringing row",
       %{coordinator_owner: coordinator_owner} do
    {caller_scope, recipient_scope, direct_conversation, friendship} =
      unique_direct_conversation_fixture("rg")

    carol_scope = user_scope_fixture(user_fixture(username: unique_username("rgc2")))
    dave_scope = user_scope_fixture(user_fixture(username: unique_username("rgd2")))

    try do
      assert {:ok, %{relationship: request}} =
               Friendships.send_friend_request(carol_scope, %{username: dave_scope.user.username})

      assert {:ok, carol_dave_friendship} =
               Friendships.accept_friend_request(dave_scope, request.id)

      assert {:ok, carol_dave} =
               Chat.open_direct_conversation(carol_scope, dave_scope.user.id)

      assert {:ok, %{call: ringing}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      now = DateTime.utc_now(:microsecond)

      Repo.get!(CallAttempt, ringing.call_id)
      |> Ecto.Changeset.change(%{state: :connecting, accepted_at: now})
      |> Repo.update!()

      count_before = Repo.aggregate(CallAttempt, :count)
      {blocker, holder_pid} = start_call_attempt_blocker(ringing.call_id)

      stop_supervised!(DiscordClone.Calls.Supervisor)
      start_supervised!(DiscordClone.Calls.Supervisor)

      :ok =
        Sandbox.allow(
          Repo,
          coordinator_owner,
          Process.whereis(DiscordClone.Calls.CallCoordinator)
        )

      DiscordClone.Calls.CallCoordinator.begin_recovery()
      assert_blocked_by(holder_pid)

      assert {:error, :temporarily_unavailable} =
               Calls.start_call(carol_scope, carol_dave.id, :audio)

      assert Repo.aggregate(CallAttempt, :count) == count_before
      assert Repo.get!(CallAttempt, ringing.call_id).state == :connecting

      send(blocker, {:release_attempt, self()})
      await_recovery_finished()

      interrupted = Repo.get!(CallAttempt, ringing.call_id)
      assert interrupted.state == :terminal
      assert interrupted.terminal_outcome == :interrupted

      assert {:ok, %{call: started, started?: true}} =
               Calls.start_call(carol_scope, carol_dave.id, :audio)

      assert started.state == :ringing
      assert started.direct_conversation_id == carol_dave.id
      assert_call_server_ready(started.call_id)

      cleanup!(carol_scope, dave_scope, carol_dave, carol_dave_friendship)
    after
      cleanup!(caller_scope, recipient_scope, direct_conversation, friendship)
    end
  end

  test "prune returns without waiting on a locked terminal candidate" do
    {caller_scope, recipient_scope, direct_conversation, friendship} =
      unique_direct_conversation_fixture("pr")

    carol_scope = user_scope_fixture(user_fixture(username: unique_username("prc")))
    dave_scope = user_scope_fixture(user_fixture(username: unique_username("prd")))

    try do
      assert {:ok, %{relationship: request}} =
               Friendships.send_friend_request(carol_scope, %{username: dave_scope.user.username})

      assert {:ok, carol_dave_friendship} =
               Friendships.accept_friend_request(dave_scope, request.id)

      assert {:ok, carol_dave} =
               Chat.open_direct_conversation(carol_scope, dave_scope.user.id)

      ended_at = DateTime.add(DateTime.utc_now(:microsecond), -7, :day)

      old =
        insert_old_terminal_attempt!(caller_scope, recipient_scope, direct_conversation, ended_at)

      assert {:ok, %{call: ringing}} =
               Calls.start_call(carol_scope, carol_dave.id, :audio)

      {blocker, _holder_pid} = start_call_attempt_blocker(old.id)
      blocker_ref = Process.monitor(blocker)

      run_coordinator_prune()

      assert {:ok, cancelled} = Calls.cancel_call(carol_scope, ringing.call_id)
      assert cancelled.call_id == ringing.call_id
      assert cancelled.terminal_outcome == :cancelled
      assert Repo.get!(CallAttempt, old.id).id == old.id
      assert length(missed_call_activity_items(dave_scope.user.id, ringing.call_id)) == 1
      assert missed_call_activity_items(recipient_scope.user.id, old.id) == []

      send(blocker, {:release_attempt, self()})
      assert_receive {:DOWN, ^blocker_ref, :process, ^blocker, _reason}
      run_coordinator_prune()

      assert is_nil(Repo.get(CallAttempt, old.id))
      assert length(missed_call_activity_items(dave_scope.user.id, ringing.call_id)) == 1

      cleanup!(carol_scope, dave_scope, carol_dave, carol_dave_friendship)
    after
      cleanup!(caller_scope, recipient_scope, direct_conversation, friendship)
    end
  end

  defp insert_old_terminal_attempt!(
         caller_scope,
         recipient_scope,
         direct_conversation,
         ended_at
       ) do
    inserted_at = DateTime.add(ended_at, -30, :second)

    %CallAttempt{}
    |> Ecto.Changeset.change(%{
      direct_conversation_id: direct_conversation.id,
      caller_user_id: caller_scope.user.id,
      recipient_user_id: recipient_scope.user.id,
      media_intent: :audio,
      state: :terminal,
      ringing_deadline_at: DateTime.add(inserted_at, 30, :second),
      terminal_outcome: :declined,
      ended_at: ended_at,
      inserted_at: inserted_at,
      updated_at: ended_at
    })
    |> Repo.insert!()
  end

  defp overlapping_commands(call_id, fun) do
    overlapping_distinct_commands(call_id, fun, fun)
  end

  defp assert_accept_race(prefix, competing_command) do
    {caller_scope, recipient_scope, direct_conversation, friendship} =
      unique_direct_conversation_fixture(prefix)

    try do
      assert {:ok, %{call: ringing}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      {accept_result, competing_result} =
        overlapping_distinct_commands(
          ringing.call_id,
          fn -> Calls.accept_call(recipient_scope, ringing.call_id, :audio) end,
          fn -> competing_command.(caller_scope, recipient_scope, ringing, friendship) end
        )

      assert match?({:ok, _projection}, accept_result) or
               accept_result == {:error, :not_found}

      assert(
        match?({:ok, _projection}, competing_result) or competing_result == :ok or
          competing_result == {:error, :stale},
        "unexpected competing result: #{inspect(competing_result)}"
      )

      attempt = Repo.get!(CallAttempt, ringing.call_id)
      assert attempt.state in [:connecting, :terminal]
      assert attempt.state == :terminal or not is_nil(attempt.accepted_at)
    after
      cleanup!(caller_scope, recipient_scope, direct_conversation, friendship)
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:discord_clone, key)
  defp restore_env(key, value), do: Application.put_env(:discord_clone, key, value)

  defp overlapping_distinct_commands(call_id, fun_one, fun_two) do
    parent = self()
    suffix = System.unique_integer([:positive])
    name_one = "calls_one_#{suffix}"
    name_two = "calls_two_#{suffix}"

    blocker =
      start_database_task(:blocker, fn ->
        Repo.transaction(fn ->
          Repo.one!(
            from call_attempt in CallAttempt,
              where: call_attempt.id == ^call_id,
              lock: "FOR UPDATE"
          )

          send(parent, {:attempt_locked, self()})

          receive do
            {:release_attempt, ^parent} -> :ok
          end
        end)
      end)

    assert_receive {:attempt_locked, ^blocker}, 1_000

    start_database_task(:one, fn ->
      set_application_name(name_one)
      send(parent, {:one, fun_one.()})
    end)

    assert_waiting_on_lock(name_one)

    start_database_task(:two, fn ->
      set_application_name(name_two)
      send(parent, {:two, fun_two.()})
    end)

    assert_waiting_on_lock(name_two)

    refute_receive {:one, _result}, 100
    refute_receive {:two, _result}, 100

    send(blocker, {:release_attempt, parent})

    assert_receive {:one, first}, 1_000
    assert_receive {:two, second}, 1_000
    {first, second}
  end

  defp start_call_attempt_blocker(call_id) do
    parent = self()

    blocker =
      start_database_task(:recovery_attempt_blocker, fn ->
        Repo.transaction(fn ->
          Repo.one!(
            from call_attempt in CallAttempt,
              where: call_attempt.id == ^call_id,
              lock: "FOR UPDATE"
          )

          %{rows: [[backend_pid]]} = SQL.query!(Repo, "SELECT pg_backend_pid()", [])
          send(parent, {:attempt_locked, self(), backend_pid})

          receive do
            {:release_attempt, ^parent} -> :ok
          end
        end)
      end)

    assert_receive {:attempt_locked, ^blocker, holder_pid}, 1_000
    {blocker, holder_pid}
  end

  defp start_direct_conversation_blocker(direct_conversation_id) do
    parent = self()

    blocker =
      start_database_task(:conversation_blocker, fn ->
        Repo.transaction(fn ->
          Repo.one!(
            from direct_conversation in DirectConversation,
              where: direct_conversation.id == ^direct_conversation_id,
              lock: "FOR UPDATE"
          )

          %{rows: [[backend_pid]]} = SQL.query!(Repo, "SELECT pg_backend_pid()", [])
          send(parent, {:conversation_locked, self(), backend_pid})

          receive do
            {:release_conversation, ^parent} -> :ok
          end
        end)
      end)

    assert_receive {:conversation_locked, ^blocker, holder_pid}, 1_000
    {blocker, holder_pid}
  end

  defp start_database_task(id, fun) do
    start_supervised!(%{
      id: {__MODULE__, id},
      restart: :temporary,
      start:
        {Task, :start_link,
         [
           fn ->
             :ok = Sandbox.checkout(Repo, sandbox: false)

             try do
               fun.()
             after
               :ok = Sandbox.checkin(Repo)
             end
           end
         ]}
    })
  end

  defp set_application_name(application_name) do
    SQL.query!(Repo, "SELECT set_config('application_name', $1, false)", [application_name])
  end

  defp assert_blocked_by(holder_pid) do
    deadline = System.monotonic_time(:millisecond) + 3_000
    assert_blocked_by(holder_pid, deadline)
  end

  defp assert_blocked_by(holder_pid, deadline) do
    waiting? =
      SQL.query!(
        Repo,
        """
        SELECT EXISTS (
          SELECT 1
          FROM pg_stat_activity
          WHERE $1 = ANY (pg_blocking_pids(pid))
        )
        """,
        [holder_pid]
      ).rows == [[true]]

    cond do
      waiting? ->
        :ok

      System.monotonic_time(:millisecond) < deadline ->
        :erlang.yield()
        assert_blocked_by(holder_pid, deadline)

      true ->
        flunk("expected a backend to wait on lock holder #{holder_pid}")
    end
  end

  defp assert_call_occupancy(call_id, direct_conversation_id) do
    coordinator = :sys.get_state(DiscordClone.Calls.CallCoordinator)
    assert coordinator.calls_by_id[call_id] == direct_conversation_id
    assert coordinator.calls_by_direct_conversation[direct_conversation_id] == call_id
  end

  defp assert_call_server_ready(call_id) do
    assert [{_pid, _value}] = Registry.lookup(DiscordClone.Calls.CallRegistry, call_id)
    assert :ok = DiscordClone.Calls.CallServer.await_ready(call_id)
  end

  defp assert_waiting_on_lock(application_name) do
    deadline = System.monotonic_time(:millisecond) + 3_000
    assert_waiting_on_lock(application_name, deadline)
  end

  defp assert_waiting_on_lock(application_name, deadline) do
    waiting? =
      SQL.query!(
        Repo,
        """
        SELECT EXISTS (
          SELECT 1
          FROM pg_stat_activity
          WHERE application_name = $1
            AND state = 'active'
            AND wait_event_type = 'Lock'
        )
        """,
        [application_name]
      ).rows == [[true]]

    cond do
      waiting? ->
        :ok

      System.monotonic_time(:millisecond) < deadline ->
        :erlang.yield()
        assert_waiting_on_lock(application_name, deadline)

      true ->
        flunk("expected #{application_name} to block on the Call Attempt row lock")
    end
  end

  defp unique_direct_conversation_fixture(prefix) do
    caller_scope = user_scope_fixture(user_fixture(username: unique_username("#{prefix}c")))
    recipient_scope = user_scope_fixture(user_fixture(username: unique_username("#{prefix}r")))

    assert {:ok, %{relationship: request}} =
             Friendships.send_friend_request(caller_scope, %{
               username: recipient_scope.user.username
             })

    assert {:ok, friendship} = Friendships.accept_friend_request(recipient_scope, request.id)

    assert {:ok, direct_conversation} =
             Chat.open_direct_conversation(caller_scope, recipient_scope.user.id)

    {caller_scope, recipient_scope, direct_conversation, friendship}
  end

  defp cleanup!(caller_scope, recipient_scope, direct_conversation, friendship) do
    user_ids = [caller_scope.user.id, recipient_scope.user.id]

    Repo.delete_all(
      from call_attempt in CallAttempt,
        where: call_attempt.direct_conversation_id == ^direct_conversation.id
    )

    Repo.delete_all(
      from activity_item in ActivityItem, where: activity_item.recipient_user_id in ^user_ids
    )

    case Repo.get(Relationship, friendship.id) do
      %Relationship{} = relationship -> Repo.delete!(relationship)
      nil -> :ok
    end

    case Repo.get(Conversation, direct_conversation.id) do
      %Conversation{} = conversation -> Repo.delete!(conversation)
      nil -> :ok
    end

    Enum.each([caller_scope.user, recipient_scope.user], fn user ->
      case Repo.get(DiscordClone.Accounts.User, user.id) do
        %DiscordClone.Accounts.User{} = persisted -> Repo.delete!(persisted)
        nil -> :ok
      end
    end)
  end

  defp unique_username(prefix) do
    String.slice("#{prefix}#{System.unique_integer([:positive])}", 0, 32)
  end
end
