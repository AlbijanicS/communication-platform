defmodule DiscordClone.MediaFixtures do
  @moduledoc """
  Test helpers for controlled durable Call Attempt states and Media pair setup.
  """

  import DiscordClone.CallsFixtures, only: [direct_conversation_fixture: 1]

  alias DiscordClone.Accounts.{Scope, User}
  alias DiscordClone.Calls.CallAttempt
  alias DiscordClone.Chat
  alias DiscordClone.Friendships
  alias DiscordClone.Media.DirectCallTarget
  alias DiscordClone.Media.Target
  alias DiscordClone.Repo

  @ringing_window_seconds 30

  def ringing_pair_fixture(suffix \\ nil) when is_binary(suffix) or is_nil(suffix) do
    suffix = suffix || "pair_#{System.unique_integer([:positive])}"

    {caller_scope, recipient_scope, direct_conversation, friendship} =
      direct_conversation_fixture(suffix)

    pair =
      build_pair(
        caller_scope.user,
        recipient_scope.user,
        direct_conversation,
        friendship
      )

    Map.merge(pair, %{caller_scope: caller_scope, recipient_scope: recipient_scope})
  end

  def ringing_pair_fixture(%User{} = first_user, %User{} = second_user) do
    first_scope = Scope.for_user(first_user)

    {:ok, %{relationship: request}} =
      Friendships.send_friend_request(first_scope, %{username: second_user.username})

    {:ok, friendship} = Friendships.accept_friend_request(Scope.for_user(second_user), request.id)

    {:ok, direct_conversation} =
      Chat.open_direct_conversation(first_scope, second_user.id)

    build_pair(first_user, second_user, direct_conversation, friendship)
  end

  defp build_pair(first_user, second_user, direct_conversation, friendship) do
    call_attempt =
      insert_attempt!(direct_conversation.id, first_user.id, second_user.id, :ringing)

    %{
      call_id: call_attempt.id,
      first_user_id: first_user.id,
      second_user_id: second_user.id,
      direct_conversation: direct_conversation,
      friendship: friendship
    }
  end

  def insert_attempt!(direct_conversation_id, caller_user_id, recipient_user_id, state) do
    now = DateTime.utc_now(:microsecond)

    %CallAttempt{}
    |> CallAttempt.create_changeset(%{
      direct_conversation_id: direct_conversation_id,
      caller_user_id: caller_user_id,
      recipient_user_id: recipient_user_id,
      media_intent: :audio,
      state: state,
      ringing_deadline_at: DateTime.add(now, @ringing_window_seconds, :second)
    })
    |> Repo.insert!()
  end

  def set_attempt_connecting!(call_id) do
    call_id
    |> then(&Repo.get!(CallAttempt, &1))
    |> CallAttempt.accept_changeset(DateTime.utc_now(:microsecond))
    |> Repo.update!()
  end

  def end_friendship!(friendship) do
    friendship
    |> Ecto.Changeset.change(status: :pending, accepted_at: nil)
    |> Repo.update!()
  end

  def start_ready_call_target(call_id, opts \\ []) do
    opts = Keyword.put_new(opts, :id, {:call_target, call_id})
    target = ExUnit.Callbacks.start_supervised!({DirectCallTarget, call_id: call_id}, opts)
    {:ok, _identity} = DirectCallTarget.identity(target)
    target
  end

  @doc "Pauses target cleanup after its first exact removal, without blocking admission."
  def pause_after_first_call_removal(target) do
    {DiscordClone.Media.DirectCallTargetServer, server, _, _} =
      target
      |> Supervisor.which_children()
      |> List.keyfind(DiscordClone.Media.DirectCallTargetServer, 0)

    parent = self()
    barrier = make_ref()

    :ok =
      :sys.install(server, {
        fn
          :armed, {:in, {:"$gen_call", _from, {:remove, _user_id, _session_id}}}, _ ->
            :removing

          :removing, {:out, :ok, _from, _state}, _ ->
            send(parent, {:first_call_session_removed, barrier})

            receive do
              {:resume_call_cleanup, ^barrier} -> :done
            end

          phase, _event, _ ->
            phase
        end,
        :armed
      })

    resume = fn -> send(server, {:resume_call_cleanup, barrier}) end
    ExUnit.Callbacks.on_exit(resume)
    {barrier, resume}
  end

  @doc "Holds stale cleanup at begin until the test suspends its caller and releases the mailbox."
  def pause_stale_target_cleanup(call_id) do
    coordinator = Process.whereis(DiscordClone.Voice.SessionCoordinator)
    parent = self()
    barrier = make_ref()

    hook = fn
      :armed, {:in, {:"$gen_call", _from, {:begin_stale_target_cleanup, ^call_id}}}, _ ->
        send(parent, {:stale_target_cleanup_begun, barrier})

        receive do
          {:resume_stale_cleanup_begin, ^barrier} -> :done
        end

      phase, _event, _ ->
        phase
    end

    :ok = :sys.install(coordinator, {hook, :armed})

    ExUnit.Callbacks.on_exit(fn ->
      try do
        :sys.remove(coordinator, hook)
      catch
        :exit, _ -> :ok
      end
    end)

    resume = fn -> send(coordinator, {:resume_stale_cleanup_begin, barrier}) end
    {barrier, resume}
  end

  @doc """
  Isolates pair-admission fault settings for a test and registers shared cleanup.

  Restores the exact prior settings after resetting media state, including
  explicitly configured nil values. Voice room cleanup remains with the caller.
  """
  def setup_coordinator_pair_state! do
    previous =
      for key <- [
            :pair_commit_fault,
            :pair_accept_between_reserve_and_commit,
            :voice_switch_fault
          ] do
        value = Application.fetch_env(:discord_clone, key)
        Application.delete_env(:discord_clone, key)
        {key, value}
      end

    ExUnit.Callbacks.on_exit(fn ->
      try do
        reset_coordinator_pair_state!()
      after
        for {key, value} <- previous do
          case value do
            {:ok, setting} -> Application.put_env(:discord_clone, key, setting)
            :error -> Application.delete_env(:discord_clone, key)
          end
        end
      end
    end)

    :ok
  end

  @doc """
  Resets global pair-admission media state between tests.

  Stops production-path Direct Call targets started via
  `DirectCallTarget.start/1` (under the application supervisor, not
  test-supervised) and clears the coordinator's reservation, active pair,
  target claims, and Direct Call indexes. Voice rooms are left to the
  caller's own cleanup.
  """
  def reset_coordinator_pair_state! do
    :ok = DiscordClone.Media.CallCleanupLedger.clear()
    Application.delete_env(:discord_clone, :pair_commit_fault)
    Application.delete_env(:discord_clone, :pair_accept_between_reserve_and_commit)
    Application.delete_env(:discord_clone, :voice_switch_fault)

    DiscordClone.Media.DirectCallTargetSupervisor
    |> DynamicSupervisor.which_children()
    |> Enum.each(fn
      {_, pid, _, _} when is_pid(pid) ->
        try do
          DynamicSupervisor.terminate_child(DiscordClone.Media.DirectCallTargetSupervisor, pid)
        catch
          :exit, _ -> :ok
        end

        :ok

      _ ->
        :ok
    end)

    coordinator = Process.whereis(DiscordClone.Voice.SessionCoordinator)

    if is_pid(coordinator) do
      :sys.replace_state(coordinator, fn state ->
        call_user_ids =
          for {user_id, %{target: %Target{kind: :direct_call}}} <- state.active_by_user,
              do: user_id

        state
        |> Map.put(:real_cleanup, nil)
        |> Map.put(:reservation, nil)
        |> Map.put(:active_call, nil)
        |> Map.put(:voice_switches, %{})
        |> Map.put(:call_targets, %{})
        |> Map.put(:call_target_starts, %{})
        |> Map.update!(:active_by_user, &Map.drop(&1, call_user_ids))
      end)
    end

    :ok
  end
end
