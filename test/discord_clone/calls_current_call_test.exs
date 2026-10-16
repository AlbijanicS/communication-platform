defmodule DiscordClone.CallsCurrentCallTest do
  use DiscordClone.DataCase, async: false

  import DiscordClone.AccountsFixtures
  import DiscordClone.CallsFixtures

  alias DiscordClone.Accounts.Scope
  alias DiscordClone.Activities.ActivityItem
  alias DiscordClone.Calls
  alias DiscordClone.Calls.CallAttempt
  alias DiscordClone.Friendships
  alias DiscordClone.Repo

  setup do
    start_supervised!(DiscordClone.Calls.Supervisor)
    DiscordClone.Calls.CallCoordinator.begin_recovery()
    await_recovery_finished()
    :ok
  end

  describe "current_call/1" do
    test "rejects absent and empty Scopes" do
      assert {:error, :unauthenticated} = Calls.current_call(nil)
      assert {:error, :unauthenticated} = Calls.current_call(%Scope{})
    end

    test "returns nil when the User has no active attempt" do
      scope = user_scope_fixture(user_fixture(username: "cc_none"))

      assert {:ok, nil} = Calls.current_call(scope)
    end

    test "returns the same ready ringing projection to caller and recipient" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("cc_ready")

      assert {:ok, %{call: started, started?: true}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      assert {:ok, caller_view} = Calls.current_call(caller_scope)
      assert {:ok, recipient_view} = Calls.current_call(recipient_scope)

      assert caller_view == started
      assert recipient_view == started
      assert MapSet.new(Map.keys(caller_view)) == MapSet.new(Calls.projection_keys())
      assert caller_view.state == :ringing
      refute Map.has_key?(caller_view, :role)
      refute Map.has_key?(caller_view, :signaling_session_id)
    end

    test "returns nil for an unrelated User" do
      {caller_scope, _recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("cc_unrelated")

      outsider_scope = user_scope_fixture(user_fixture(username: "cc_unrelated_out"))

      assert {:ok, %{call: _started, started?: true}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      assert {:ok, nil} = Calls.current_call(outsider_scope)
    end

    test "returns nil for a terminal attempt" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("cc_terminal")

      assert {:ok, %{call: started, started?: true}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      assert {:ok, _declined} = Calls.decline_call(recipient_scope, started.call_id)

      assert {:ok, nil} = Calls.current_call(caller_scope)
      assert {:ok, nil} = Calls.current_call(recipient_scope)
    end

    test "returns nil after Friendship ends" do
      {caller_scope, recipient_scope, direct_conversation, friendship} =
        direct_conversation_fixture("cc_unfriend")

      assert {:ok, %{call: _started, started?: true}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      assert :ok = Friendships.remove_friend(caller_scope, friendship.id)

      assert {:ok, nil} = Calls.current_call(caller_scope)
      assert {:ok, nil} = Calls.current_call(recipient_scope)
    end

    test "preserves the original deadline and writes no side effects" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("cc_side")

      assert {:ok, %{call: started, started?: true}} =
               Calls.start_call(caller_scope, direct_conversation.id, :video)

      attempt_count = Repo.aggregate(CallAttempt, :count)
      original_deadline = started.ringing_deadline_at

      assert {:ok, discovered} = Calls.current_call(caller_scope)
      assert {:ok, recipient_view} = Calls.current_call(recipient_scope)

      assert discovered.ringing_deadline_at == original_deadline
      assert recipient_view.ringing_deadline_at == original_deadline
      assert {:ok, ^discovered} = Calls.get_call(caller_scope, started.call_id)
      assert Repo.aggregate(CallAttempt, :count) == attempt_count

      assert Repo.aggregate(
               from(activity_item in ActivityItem,
                 where: activity_item.source_call_attempt_id == ^started.call_id
               ),
               :count
             ) == 0
    end

    test "suppresses an overdue ringing projection without extending or timing it out" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("cc_overdue")

      assert {:ok, %{call: started, started?: true}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      make_ringing_deadline_due!(started.call_id)
      overdue = Repo.get!(CallAttempt, started.call_id)

      assert {:ok, nil} = Calls.current_call(caller_scope)
      assert {:ok, nil} = Calls.current_call(recipient_scope)

      still_ringing = Repo.get!(CallAttempt, started.call_id)
      assert still_ringing.state == :ringing
      assert still_ringing.terminal_outcome == nil
      assert still_ringing.ringing_deadline_at == overdue.ringing_deadline_at

      assert {:ok, visible} = Calls.get_call(caller_scope, started.call_id)
      assert visible.state == :ringing
      assert visible.ringing_deadline_at == overdue.ringing_deadline_at

      assert missed_call_activity_items(recipient_scope.user.id, started.call_id) == []
    end

    test "reports temporary unavailability when the Calls runtime is not ready" do
      stop_supervised!(DiscordClone.Calls.Supervisor)
      start_supervised!(DiscordClone.Calls.Supervisor)

      scope = user_scope_fixture(user_fixture(username: "cc_unavail"))

      assert {:error, :temporarily_unavailable} = Calls.current_call(scope)
    end
  end
end
