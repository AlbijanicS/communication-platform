defmodule DiscordClone.CallsFixtures do
  @moduledoc """
  Test helpers for Direct Call Attempt setup and missed-call Activity lookup.
  """

  import DiscordClone.AccountsFixtures
  import Ecto.Query
  import ExUnit.Assertions, only: [assert: 1, flunk: 1]

  alias DiscordClone.Activities.ActivityItem
  alias DiscordClone.Calls.CallAttempt
  alias DiscordClone.Chat
  alias DiscordClone.Friendships
  alias DiscordClone.Media.AdmissionCoordinator
  alias DiscordClone.Repo

  def direct_conversation_fixture(suffix) do
    caller_scope = user_scope_fixture(user_fixture(username: "#{suffix}_caller"))
    recipient_scope = user_scope_fixture(user_fixture(username: "#{suffix}_recipient"))

    {:ok, %{relationship: request}} =
      Friendships.send_friend_request(caller_scope, %{username: recipient_scope.user.username})

    {:ok, friendship} = Friendships.accept_friend_request(recipient_scope, request.id)

    {:ok, direct_conversation} =
      Chat.open_direct_conversation(caller_scope, recipient_scope.user.id)

    {caller_scope, recipient_scope, direct_conversation, friendship}
  end

  def backdate_terminal_attempt!(call_id, ended_at) do
    attempt = Repo.get!(CallAttempt, call_id)
    inserted_at = DateTime.add(ended_at, -30, :second)

    accepted_at =
      if is_nil(attempt.accepted_at) do
        nil
      else
        DateTime.add(ended_at, -1, :second)
      end

    attempt
    |> Ecto.Changeset.change(%{
      inserted_at: inserted_at,
      ringing_deadline_at: DateTime.add(inserted_at, 30, :second),
      accepted_at: accepted_at,
      ended_at: ended_at,
      updated_at: ended_at
    })
    |> Repo.update!()
  end

  def run_coordinator_prune do
    pid = Process.whereis(DiscordClone.Calls.CallCoordinator)
    send(pid, :prune)
    _ = :sys.get_state(pid)
    :ok
  end

  def make_ringing_deadline_due!(call_id) do
    now = DateTime.utc_now(:microsecond)

    Repo.get!(CallAttempt, call_id)
    |> Ecto.Changeset.change(%{
      inserted_at: DateTime.add(now, -60, :second),
      ringing_deadline_at: DateTime.add(now, -1, :second),
      updated_at: now
    })
    |> Repo.update!()
  end

  def await_recovery_finished(timeout_ms \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    await_recovery_finished_until(deadline)
  end

  defp await_recovery_finished_until(deadline) do
    case Process.whereis(DiscordClone.Calls.CallCoordinator) do
      pid when is_pid(pid) ->
        case safe_coordinator_state(pid) do
          {:ok, state} ->
            cond do
              Map.get(state, :recovering, false) == false ->
                :ok

              System.monotonic_time(:millisecond) < deadline ->
                :erlang.yield()
                await_recovery_finished_until(deadline)

              true ->
                raise "expected CallCoordinator to finish recovery"
            end

          :error ->
            retry_recovery_wait(deadline)
        end

      nil ->
        retry_recovery_wait(deadline)
    end
  end

  defp retry_recovery_wait(deadline) do
    if System.monotonic_time(:millisecond) < deadline do
      :erlang.yield()
      await_recovery_finished_until(deadline)
    else
      raise "expected CallCoordinator to finish recovery"
    end
  end

  defp safe_coordinator_state(pid) do
    {:ok, :sys.get_state(pid)}
  catch
    :exit, _reason -> :error
  end

  def missed_call_activity_items(recipient_user_id, call_id) do
    Repo.all(
      from activity_item in ActivityItem,
        where:
          activity_item.recipient_user_id == ^recipient_user_id and
            activity_item.source_call_attempt_id == ^call_id and
            activity_item.kind == "missed_direct_call"
    )
  end

  @doc """
  Shared Direct Call test synchronization helpers.

  Previously copied across pair-admission and voice-switch tests; kept here
  so new coverage reuses the sleep-free polling instead of adding a fourth
  copy. `flush_call_server/1` syncs on the per-call server mailbox (if
  running) via `:sys.get_state/1`; `poll_until/3` yields until the predicate
  holds or the deadline passes.
  """
  def eventually_active?(call_id, timeout_ms \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll_until(call_id, fn -> Repo.get!(CallAttempt, call_id).state == :active end, deadline)
  end

  def eventually_terminal?(call_id, outcome, timeout_ms \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    poll_until(
      call_id,
      fn ->
        case Repo.get(CallAttempt, call_id) do
          %CallAttempt{state: :terminal, terminal_outcome: ^outcome} -> true
          _ -> false
        end
      end,
      deadline
    )
  end

  def poll_until(call_id, fun, deadline) do
    _ = flush_call_server(call_id)

    cond do
      fun.() ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("timed out waiting for durable Call Attempt transition")

      true ->
        :erlang.yield()
        poll_until(call_id, fun, deadline)
    end
  end

  def flush_call_server(call_id) do
    case Registry.lookup(DiscordClone.Calls.CallRegistry, call_id) do
      [{pid, _}] ->
        try do
          _ = :sys.get_state(pid)
          :ok
        catch
          :exit, _ -> :ok
        end

      [] ->
        :ok
    end
  end

  def assert_no_call_sessions(call_id) do
    case AdmissionCoordinator.call_target_snapshot(call_id) do
      nil -> :ok
      %{sessions: sessions} -> assert sessions == %{}
    end
  end
end
