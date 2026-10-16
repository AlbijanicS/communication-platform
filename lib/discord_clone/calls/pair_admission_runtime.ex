defmodule DiscordClone.Calls.PairAdmissionRuntime do
  @moduledoc false

  @behaviour DiscordClone.Calls.AcceptedCallRuntime

  alias DiscordClone.Media.AdmissionCoordinator

  @impl true
  def schedule(server, call_id) when is_pid(server) and is_binary(call_id) do
    # `begin_accepted_call` holds the CallServer mailbox while scheduling.
    # Slow Voice retirement and Call Session creation must run outside both
    # that mailbox and any database row lock. The detached result-delivery
    # task delegates to the coordinator's monitored commit operation.
    {:ok, _pid} =
      Task.start(fn ->
        run_pair_commit(server, call_id, DiscordClone.Media.DirectCallTarget.real_transport?())
      end)

    :ok
  end

  defp run_pair_commit(server, call_id, real?) do
    result =
      case AdmissionCoordinator.reservation_generation(call_id) do
        {:ok, generation} ->
          case AdmissionCoordinator.commit_pair(call_id, generation) do
            {:ok, _published} ->
              if real?,
                do: :admitted,
                else: :ready

            {:error, %{reason: :deployment_full}} ->
              :failed_capacity

            {:error, :terminal_cleanup} ->
              :terminal_cleanup

            {:error, _reason} ->
              :failed
          end

        {:error, :not_found} ->
          # No precommit reservation (released, expired, or never created).
          # Fail closed; `complete_accepted_runtime` will ignore stale results
          # for non-connecting attempts.
          :failed
      end

    if result not in [:terminal_cleanup, :admitted] and (real? or connecting?(call_id)) do
      send(server, {:accepted_call_runtime, call_id, result})
    end
  end

  defp connecting?(call_id) do
    case DiscordClone.Calls.get_nonterminal_attempt(call_id) do
      %{state: :connecting} -> true
      _ -> false
    end
  end
end
