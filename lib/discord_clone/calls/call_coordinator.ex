defmodule DiscordClone.Calls.CallCoordinator do
  @moduledoc false

  use GenServer

  require Logger

  alias DiscordClone.Calls
  alias DiscordClone.Calls.{CallAttempt, CallServer}

  @ready_key {__MODULE__, :ready}
  @recovery_retry_ms 1_000
  @max_runtime_rebuilds 3

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, :ok, opts)

  @doc false
  @spec begin_recovery() :: :ok
  def begin_recovery do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) ->
        send(pid, :recover)
        :ok

      nil ->
        :ok
    end
  end

  @spec start_call(
          DiscordClone.Accounts.Scope.t(),
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          atom(),
          String.t() | nil
        ) ::
          {:ok, %{call: map(), started?: boolean()}} | {:error, atom()}
  def start_call(
        scope,
        direct_conversation_id,
        recipient_user_id,
        media_intent,
        caller_connection_id \\ nil
      )

  def start_call(
        scope,
        direct_conversation_id,
        recipient_user_id,
        media_intent,
        caller_connection_id
      ) do
    if ready?() do
      GenServer.call(
        __MODULE__,
        {:start_call, scope, direct_conversation_id, recipient_user_id, media_intent,
         caller_connection_id}
      )
    else
      {:error, :temporarily_unavailable}
    end
  catch
    :exit, _unavailable -> {:error, :temporarily_unavailable}
  end

  @doc false
  @spec current_call_id(Ecto.UUID.t()) ::
          {:ok, Ecto.UUID.t() | nil} | {:error, :temporarily_unavailable}
  def current_call_id(user_id) when is_binary(user_id) do
    if ready?() do
      GenServer.call(__MODULE__, {:current_call_id, user_id})
    else
      {:error, :temporarily_unavailable}
    end
  catch
    :exit, _unavailable -> {:error, :temporarily_unavailable}
  end

  @spec release_occupancy(Ecto.UUID.t()) :: :ok
  def release_occupancy(call_id) do
    pid = Process.whereis(__MODULE__)

    cond do
      pid == self() ->
        send(self(), {:release_occupancy, call_id})
        :ok

      is_pid(pid) ->
        GenServer.call(pid, {:release_occupancy, call_id})

      true ->
        :ok
    end
  catch
    :exit, _unavailable -> :ok
  end

  @impl true
  def init(:ok) do
    mark_not_ready()

    if Application.get_env(:discord_clone, :start_calls_runtime, true) do
      send(self(), :recover)
    end

    {:ok, empty_state()}
  end

  @impl true
  def terminate(_reason, _state) do
    mark_not_ready()
    :ok
  end

  @impl true
  def handle_call(
        {:start_call, scope, direct_conversation_id, recipient_user_id, media_intent,
         caller_connection_id},
        _from,
        state
      ) do
    if admit_starts?(state) do
      start_or_converge_call(
        scope,
        direct_conversation_id,
        recipient_user_id,
        media_intent,
        caller_connection_id,
        state
      )
    else
      {:reply, {:error, :temporarily_unavailable}, state}
    end
  end

  @impl true
  def handle_call({:current_call_id, user_id}, _from, state) do
    # The occupancy index is only a reliable hint after the same recovery gate
    # that admits starts. A read during recovery would guess from a partial map.
    if admit_starts?(state) do
      {:reply, {:ok, Map.get(state.calls_by_user, user_id)}, state}
    else
      {:reply, {:error, :temporarily_unavailable}, state}
    end
  end

  @impl true
  def handle_call({:release_occupancy, call_id}, _from, state) do
    # Occupancy is canonical here. Do not stop the CallServer from this call:
    # a timer-driven expire is still on the CallServer stack and must publish
    # after commit, then stop itself with {:stop, :normal, state}.
    {:reply, :ok, drop_occupancy(state, call_id)}
  end

  @impl true
  def handle_info(:recover, %{recovering: true} = state) do
    run_recovery(state)
  end

  def handle_info(:recover, %{admit_starts?: false} = state) do
    mark_not_ready()
    run_recovery(%{empty_state() | prune_timer_ref: state.prune_timer_ref})
  end

  def handle_info({:release_occupancy, call_id}, state) do
    {:noreply, drop_occupancy(state, call_id)}
  end

  def handle_info(:prune, %{recovering: true} = state) do
    {:noreply, arm_prune_timer(state)}
  end

  def handle_info(:prune, state) do
    {:noreply, run_prune_batch(state)}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.monitors, ref) do
      {nil, _monitors} ->
        {:noreply, state}

      {call_id, monitors} ->
        # Retire media from the observed runtime loss before any durable read
        # or settlement can block. Admission owns the original cleanup budget.
        :ok = DiscordClone.Media.AdmissionCoordinator.begin_terminal_cleanup(call_id)
        {:noreply, recover_downed_call(call_id, %{state | monitors: monitors})}
    end
  end

  def handle_info(_message, state) do
    {:noreply, state}
  end

  defp empty_state do
    %{
      recovering: true,
      admit_starts?: true,
      prune_timer_ref: nil,
      monitors: %{},
      runtime_rebuilds: %{},
      calls_by_id: %{},
      calls_by_direct_conversation: %{},
      calls_by_user: %{}
    }
  end

  defp run_recovery(state) do
    result = Calls.recover_nonterminal_attempts()
    Enum.each(result.fail_closed, &CallServer.stop(&1.id))
    recovered = Enum.reduce(result.rebuild, state, &rebuild_runtime/2)
    admit_starts? = result.admit_starts? and recovered.admit_starts?

    Logger.info(
      "calls recovery finished rebuild=#{length(result.rebuild)} fail_closed=#{length(result.fail_closed)} admit_starts=#{admit_starts?}"
    )

    if admit_starts? do
      mark_ready()
    else
      mark_not_ready()
    end

    recovered =
      recovered
      |> Map.put(:recovering, false)
      |> Map.put(:admit_starts?, admit_starts?)
      |> run_prune_batch()

    {:noreply, recovered}
  rescue
    exception ->
      retry_recovery(state, exception)
  catch
    :exit, reason ->
      retry_recovery(state, {:exit, reason})
  end

  defp retry_recovery(state, reason) do
    Logger.error("calls recovery failed reason=#{inspect(reason)}")
    mark_not_ready()
    _ = Process.send_after(self(), :recover, @recovery_retry_ms)
    {:noreply, %{state | recovering: true, admit_starts?: false}}
  end

  defp run_prune_batch(state) do
    case Calls.prune_safely_materialized_terminal_attempts() do
      {:ok, %{deleted: deleted, retained: retained}} ->
        if deleted > 0 or retained > 0 do
          Logger.info("calls prune finished deleted=#{deleted} retained=#{retained}")
        end

        if deleted >= Calls.prune_batch_size() do
          send(self(), :prune)
        end

        :ok

      {:error, reason} ->
        Logger.error("calls prune failed reason=#{inspect(reason)}")
    end

    arm_prune_timer(state)
  rescue
    exception ->
      Logger.error("calls prune failed reason=#{inspect(exception)}")
      arm_prune_timer(state)
  catch
    :exit, reason ->
      Logger.error("calls prune failed reason=#{inspect({:exit, reason})}")
      arm_prune_timer(state)
  end

  defp arm_prune_timer(state) do
    if timer_ref = state.prune_timer_ref do
      _ = Process.cancel_timer(timer_ref)
    end

    %{state | prune_timer_ref: Process.send_after(self(), :prune, Calls.prune_interval_ms())}
  end

  defp ready? do
    :persistent_term.get(@ready_key, false)
  end

  defp mark_ready, do: :persistent_term.put(@ready_key, true)
  defp mark_not_ready, do: :persistent_term.put(@ready_key, false)

  defp admit_starts?(%{recovering: true}), do: false
  defp admit_starts?(%{admit_starts?: false}), do: false
  defp admit_starts?(_state), do: true

  defp start_or_converge_call(
         scope,
         direct_conversation_id,
         recipient_user_id,
         media_intent,
         caller_connection_id,
         state
       ) do
    caller_user_id = scope.user.id

    case resolve_live_occupancy(
           state,
           direct_conversation_id,
           caller_user_id,
           recipient_user_id
         ) do
      {:converge, projection, state} ->
        {:reply, {:ok, %{call: projection, started?: false}}, state}

      {:busy, state} ->
        {:reply, {:error, :busy}, state}

      {:miss, state} ->
        start_new_call(
          scope,
          direct_conversation_id,
          recipient_user_id,
          media_intent,
          caller_connection_id,
          state
        )
    end
  end

  defp start_new_call(
         scope,
         direct_conversation_id,
         recipient_user_id,
         media_intent,
         caller_connection_id,
         state
       ) do
    case Calls.commit_ringing_attempt(
           scope,
           direct_conversation_id,
           recipient_user_id,
           media_intent
         ) do
      {:ok, :started, %CallAttempt{} = call_attempt} ->
        case ensure_call_server_ready(call_attempt, caller_connection_id) do
          {:ok, pid} ->
            projection = Calls.to_projection(call_attempt)
            :ok = Calls.broadcast_ringing(projection)

            {:reply, {:ok, %{call: projection, started?: true}},
             state
             |> put_occupancy(call_attempt)
             |> monitor_call_server(call_attempt.id, pid)}

          {:error, _reason} ->
            _ = Calls.fail_closed_ringing_attempt(call_attempt)
            {:reply, {:error, :temporarily_unavailable}, state}
        end

      {:ok, :converged, %CallAttempt{} = call_attempt} ->
        projection = Calls.to_projection(call_attempt)
        {:reply, {:ok, %{call: projection, started?: false}}, put_occupancy(state, call_attempt)}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp rebuild_runtime(%CallAttempt{} = call_attempt, state) do
    case ensure_call_server_ready(call_attempt) do
      {:ok, pid} ->
        occupy_rebuilt_runtime(call_attempt, pid, state)

      {:error, _reason} ->
        %{state | admit_starts?: false}
    end
  end

  defp occupy_rebuilt_runtime(%CallAttempt{id: call_id}, pid, state) do
    case Calls.get_nonterminal_attempt(call_id) do
      %CallAttempt{state: :ringing} = current ->
        :ok = Calls.broadcast_ringing(Calls.to_projection(current))

        state
        |> put_occupancy(current)
        |> monitor_call_server(current.id, pid)

      %CallAttempt{} = current ->
        state
        |> put_occupancy(current)
        |> monitor_call_server(current.id, pid)

      nil ->
        _ = CallServer.stop(call_id)
        drop_occupancy(state, call_id)
    end
  end

  defp recover_downed_call(call_id, state) do
    state = drop_occupancy(state, call_id)
    rebuilds = Map.get(state.runtime_rebuilds, call_id, 0)

    if rebuilds >= @max_runtime_rebuilds do
      Logger.error("calls runtime rebuild cap exceeded call_id=#{call_id}")
      mark_not_ready()
      %{state | admit_starts?: false}
    else
      state = %{
        state
        | runtime_rebuilds: Map.put(state.runtime_rebuilds, call_id, rebuilds + 1)
      }

      # Existing deterministic durable-recovery seam; never runs in admission.
      case Application.get_env(:discord_clone, :recovery_settlement_barrier) do
        barrier when is_function(barrier, 1) -> barrier.(call_id)
        _ -> :ok
      end

      case Calls.reload_attempt_for_runtime(call_id) do
        {:rebuild, %CallAttempt{} = call_attempt} ->
          rebuild_runtime(call_attempt, state)

        :released ->
          %{state | runtime_rebuilds: Map.delete(state.runtime_rebuilds, call_id)}

        :blocked ->
          mark_not_ready()
          %{state | admit_starts?: false}
      end
    end
  end

  defp resolve_live_occupancy(
         state,
         direct_conversation_id,
         caller_user_id,
         recipient_user_id
       ) do
    call_ids =
      [
        Map.get(state.calls_by_direct_conversation, direct_conversation_id),
        Map.get(state.calls_by_user, caller_user_id),
        Map.get(state.calls_by_user, recipient_user_id)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    Enum.reduce_while(call_ids, {:miss, state}, fn call_id, {:miss, state} ->
      case Calls.get_nonterminal_attempt(call_id) do
        %CallAttempt{direct_conversation_id: ^direct_conversation_id, state: :ringing} =
            call_attempt ->
          {:halt, {:converge, Calls.to_projection(call_attempt), state}}

        %CallAttempt{} ->
          {:halt, {:busy, state}}

        nil ->
          {:cont, {:miss, drop_occupancy(state, call_id)}}
      end
    end)
  end

  defp put_occupancy(state, %CallAttempt{} = call_attempt) do
    state
    |> put_in([:calls_by_id, call_attempt.id], call_attempt.direct_conversation_id)
    |> put_in(
      [:calls_by_direct_conversation, call_attempt.direct_conversation_id],
      call_attempt.id
    )
    |> put_in([:calls_by_user, call_attempt.caller_user_id], call_attempt.id)
    |> put_in([:calls_by_user, call_attempt.recipient_user_id], call_attempt.id)
  end

  defp drop_occupancy(state, call_id) do
    {direct_conversation_id, calls_by_id} = Map.pop(state.calls_by_id, call_id)

    calls_by_direct_conversation =
      case {direct_conversation_id,
            Map.get(state.calls_by_direct_conversation, direct_conversation_id)} do
        {nil, _current} ->
          state.calls_by_direct_conversation

        {_direct_conversation_id, ^call_id} ->
          Map.delete(state.calls_by_direct_conversation, direct_conversation_id)

        {_direct_conversation_id, _other_call_id} ->
          state.calls_by_direct_conversation
      end

    %{
      state
      | calls_by_id: calls_by_id,
        calls_by_direct_conversation: calls_by_direct_conversation,
        calls_by_user:
          Map.reject(state.calls_by_user, fn {_user_id, occupied_call_id} ->
            occupied_call_id == call_id
          end)
    }
  end

  defp monitor_call_server(state, call_id, pid) do
    ref = Process.monitor(pid)
    put_in(state, [:monitors, ref], call_id)
  end

  defp ensure_call_server_ready(%CallAttempt{} = call_attempt, caller_connection_id \\ nil) do
    case start_call_server(call_attempt, caller_connection_id) do
      {:ok, pid} ->
        await_started_call_server(call_attempt.id, pid)

      {:error, {:already_started, pid}} ->
        {:ok, pid}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp await_started_call_server(call_id, pid) do
    case CallServer.await_ready(call_id) do
      :ok ->
        {:ok, pid}

      {:error, reason} ->
        _ = CallServer.stop(call_id)
        {:error, reason}
    end
  end

  defp start_call_server(%CallAttempt{} = call_attempt, caller_connection_id) do
    DynamicSupervisor.start_child(
      DiscordClone.Calls.CallSupervisor,
      {CallServer, {call_attempt, caller_connection_id}}
    )
  catch
    :exit, reason -> {:error, reason}
  end
end
