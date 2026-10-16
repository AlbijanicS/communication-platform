defmodule DiscordClone.Media.CallCleanupLedger do
  @moduledoc false

  alias DiscordClone.Media.{PairCommitCleanup, Target}

  @table __MODULE__

  # The application lifecycle owns this table, so an admission restart cannot
  # erase an unconfirmed real Call release. No database or additional process.
  def initialize do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set])
    end

    :ok
  end

  def retain(state, call_id) do
    snapshot = %{
      real_cleanup: state.real_cleanup,
      reservation: state.reservation,
      active_call: state.active_call,
      call_targets: Map.take(state.call_targets, [call_id]),
      active_by_user:
        Map.filter(state.active_by_user, fn
          {_user, %{target: %Target{kind: :direct_call, id: ^call_id}}} -> true
          _ -> false
        end)
    }

    true = :ets.insert(@table, {:held_cleanup, snapshot})
    state
  end

  def restore(state) do
    case :ets.lookup(@table, :held_cleanup) do
      [{:held_cleanup, snapshot}] ->
        cleanup = %{snapshot.real_cleanup | failed?: true, waiters: [], timer: nil}
        target = Map.fetch!(snapshot.call_targets, cleanup.call_id)

        # A restarted mailbox cannot certify the old worker's confirmations.
        # Retire captured leftovers, but never restart the accepted budget or
        # silently clear the failed accounting when they eventually disappear.
        spawn(fn ->
          PairCommitCleanup.retire(target.target_pid, target.resources, cleanup.deadline)
        end)

        Map.merge(state, %{snapshot | real_cleanup: cleanup})

      [] ->
        state
    end
  end

  def clear do
    true = :ets.delete(@table, :held_cleanup)
    :ok
  end
end
