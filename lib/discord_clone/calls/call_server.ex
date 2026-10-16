defmodule DiscordClone.Calls.CallServer do
  @moduledoc false

  use GenServer

  alias DiscordClone.Calls
  alias DiscordClone.Calls.{CallAttempt, PairAdmissionRuntime}
  alias DiscordClone.Media.AdmissionCoordinator

  @transient_retry_ms 100
  @runtime_results [:ready, :failed_capacity, :failed]

  @type start_arg :: CallAttempt.t()
  @type connection_id :: Ecto.UUID.t()
  @type role :: :caller | :recipient
  @type ownership :: :self | :elsewhere | :unclaimed

  @spec start_link(start_arg(), connection_id() | nil) :: GenServer.on_start()
  def start_link(%CallAttempt{id: call_id} = call_attempt, caller_connection_id \\ nil) do
    GenServer.start_link(
      __MODULE__,
      {call_attempt, normalize_connection_id(caller_connection_id)},
      name: via(call_id)
    )
  end

  @spec child_spec({start_arg(), connection_id() | nil} | start_arg()) :: Supervisor.child_spec()
  def child_spec({%CallAttempt{id: call_id} = call_attempt, caller_connection_id}) do
    %{
      id: {__MODULE__, call_id},
      start: {__MODULE__, :start_link, [call_attempt, caller_connection_id]},
      restart: :temporary
    }
  end

  def child_spec(%CallAttempt{id: call_id} = call_attempt) do
    %{
      id: {__MODULE__, call_id},
      start: {__MODULE__, :start_link, [call_attempt]},
      restart: :temporary
    }
  end

  @doc """
  Observational registration of one CallSocket connection for a Call topic join.

  Registration is transient, idempotent, and never mutates the durable attempt.
  Re-registering an already-registered Call Connection keeps its original
  monitor, registration order, and registration generation, so a newer channel
  for the same connection cannot reorder fallback election. Re-registering
  after a departure starts a fresh registration generation, so a claim recorded
  before the departure can never bind that connection again, while a fresh
  acceptance does. Releasing the recorded preferred caller stays permanent for
  the attempt and is never undone by a later join. The CallServer monitors the
  registering process so a crashed or killed channel unregisters without a
  clean terminate. A missing or stopped CallServer is tolerated.
  """
  @spec register(Ecto.UUID.t(), Ecto.UUID.t(), role(), connection_id()) :: :ok
  def register(call_id, user_id, role, connection_id)
      when role in [:caller, :recipient] and is_binary(connection_id) do
    GenServer.call(via(call_id), {:register, user_id, role, connection_id})
  catch
    :exit, _unavailable -> :ok
  end

  def register(_call_id, _user_id, _role, _connection_id), do: :ok

  @doc """
  Removes one Call Connection registration owned by the calling process.

  A missing registration is a no-op, and a delayed terminate from an older
  channel for the same Call Connection is ignored so it cannot remove a newer
  live registration.
  """
  @spec unregister(Ecto.UUID.t(), connection_id()) :: :ok
  def unregister(call_id, connection_id) when is_binary(connection_id) do
    GenServer.call(via(call_id), {:unregister, connection_id, self()})
  catch
    :exit, _unavailable -> :ok
  end

  def unregister(_call_id, _connection_id), do: :ok

  @doc """
  Returns the role-relative ownership of one Call Connection.

  `nil` means the CallServer is unavailable or the Call ID is unknown. Terminal
  attempts never need ownership; callers of this function only project it for
  live ringing, connecting, and active attempts.
  """
  @spec ownership(Ecto.UUID.t(), role(), connection_id()) :: ownership() | nil
  def ownership(call_id, role, connection_id) when role in [:caller, :recipient] do
    GenServer.call(via(call_id), {:ownership, role, connection_id})
  catch
    :exit, _unavailable -> nil
  end

  def ownership(_call_id, _role, _connection_id), do: nil

  @doc false
  def authorize_media(call_id, user_id, connection_id) do
    GenServer.call(via(call_id), {:authorize_media, user_id, connection_id})
  catch
    :exit, _unavailable -> {:error, :not_admitted}
  end

  @doc false
  def leave(scope, call_id, connection_id) do
    GenServer.call(via(call_id), {:leave, scope, connection_id}, :infinity)
  catch
    :exit, _unavailable -> {:error, :stale}
  end

  @doc false
  def cancel(scope, call_id, connection_id) do
    GenServer.call(via(call_id), {:cancel, scope, connection_id}, :infinity)
  catch
    :exit, _unavailable -> {:error, :stale}
  end

  @doc false
  def publish_media_state(call_id, user_id, connection_id, authority, snapshot) do
    GenServer.call(
      via(call_id),
      {:publish_media_state, user_id, connection_id, authority, snapshot}
    )
  end

  @doc false
  def media_state(call_id) do
    GenServer.call(via(call_id), :media_state)
  catch
    :exit, _unavailable -> %{}
  end

  @spec running?(Ecto.UUID.t()) :: boolean()
  def running?(call_id) do
    match?([{_pid, _value}], Registry.lookup(DiscordClone.Calls.CallRegistry, call_id))
  catch
    :exit, _unavailable -> false
  end

  @spec await_ready(Ecto.UUID.t()) :: :ok | {:error, :not_found}
  def await_ready(call_id) do
    call_id
    |> via()
    |> GenServer.call(:await_ready)
  catch
    :exit, _unavailable -> {:error, :not_found}
  end

  @spec claim_answer_mode(Ecto.UUID.t(), :audio | :video, connection_id() | nil) ::
          {:owner, reference()}
          | {:reconcile, reference(), :audio | :video}
          | {:committed, :audio | :video}
          | :retry
          | {:error, :not_found | :temporarily_unavailable}
  def claim_answer_mode(call_id, answer_mode, connection_id \\ nil) do
    GenServer.call(
      via(call_id),
      {:claim_answer_mode, answer_mode, normalize_connection_id(connection_id)},
      :infinity
    )
  catch
    :exit, _unavailable -> {:error, :not_found}
  end

  @spec commit_answer_mode(Ecto.UUID.t(), reference()) :: :ok
  def commit_answer_mode(call_id, claim_ref) do
    GenServer.call(via(call_id), {:commit_answer_mode, claim_ref})
  catch
    :exit, _unavailable -> :ok
  end

  @spec resolve_answer_mode(Ecto.UUID.t(), reference(), :audio | :video) :: :ok
  def resolve_answer_mode(call_id, claim_ref, answer_mode) do
    GenServer.call(via(call_id), {:resolve_answer_mode, claim_ref, answer_mode})
  catch
    :exit, _unavailable -> :ok
  end

  @spec update_answer_mode_claim(
          Ecto.UUID.t(),
          reference(),
          :audio | :video,
          connection_id() | nil
        ) ::
          :ok
  def update_answer_mode_claim(call_id, claim_ref, answer_mode, connection_id \\ nil) do
    GenServer.call(
      via(call_id),
      {:update_answer_mode_claim, claim_ref, answer_mode, normalize_connection_id(connection_id)}
    )
  catch
    :exit, _unavailable -> :ok
  end

  @spec reject_answer_mode(Ecto.UUID.t(), reference()) :: :ok
  def reject_answer_mode(call_id, claim_ref) do
    GenServer.call(via(call_id), {:reject_answer_mode, claim_ref})
  catch
    :exit, _unavailable -> :ok
  end

  @spec discard_answer_mode(Ecto.UUID.t(), reference()) :: :ok
  def discard_answer_mode(call_id, claim_ref) do
    GenServer.call(via(call_id), {:discard_answer_mode, claim_ref})
  catch
    :exit, _unavailable -> :ok
  end

  @spec begin_accepted_call(CallAttempt.t(), :audio | :video) ::
          {:ok, map()} | {:error, term()}
  def begin_accepted_call(%CallAttempt{id: call_id} = call_attempt, answer_mode) do
    GenServer.call(via(call_id), {:begin_accepted_call, call_attempt, answer_mode})
  catch
    :exit, _unavailable -> {:error, :not_found}
  end

  @spec answer_mode(Ecto.UUID.t()) :: :audio | :video | nil
  def answer_mode(call_id) do
    GenServer.call(via(call_id), :answer_mode)
  catch
    :exit, _unavailable -> nil
  end

  @spec stop(Ecto.UUID.t()) :: :ok
  def stop(call_id) do
    case Registry.lookup(DiscordClone.Calls.CallRegistry, call_id) do
      [{pid, _}] ->
        # Finish an in-flight durable command before retiring the mailbox.
        # Supervisor exit signals can interrupt its database connection checkin.
        try do
          GenServer.stop(pid, :normal, 5_000)
        catch
          :exit, _ -> DynamicSupervisor.terminate_child(DiscordClone.Calls.CallSupervisor, pid)
        end

        :ok

      [] ->
        :ok
    end
  catch
    :exit, _unavailable -> :ok
  end

  @impl true
  def init({%CallAttempt{} = call_attempt, caller_connection_id}) do
    {:ok,
     %{
       call_attempt: call_attempt,
       ringing_timer_ref: arm_ringing_deadline(call_attempt),
       answer_mode: nil,
       answer_mode_claim: nil,
       answer_mode_waiters: [],
       preferred_caller_connection_id: caller_connection_id,
       preferred_caller_released: false,
       caller_winner: nil,
       caller_winner_generation: nil,
       recipient_winner: nil,
       recipient_winner_generation: nil,
       registrations: %{},
       real_media?: DiscordClone.Media.DirectCallTarget.real_transport?(),
       media_runtime: nil,
       media_states: %{},
       registration_seq: 0
     }}
  end

  @impl true
  def handle_call(:await_ready, _from, state) do
    {:reply, :ok, state}
  end

  def handle_call(:answer_mode, _from, state) do
    {:reply, state.answer_mode, state}
  end

  def handle_call(:media_state, _from, state) do
    {:reply, projected_media_state(state), state}
  end

  def handle_call(
        {:publish_media_state, user_id, connection_id, authority, snapshot},
        {pid, _tag},
        state
      ) do
    with true <- state.real_media? and state.call_attempt.state in [:connecting, :active],
         %{user_id: ^user_id, pid: ^pid, role: role, generation: generation} <-
           Map.get(state.registrations, connection_id),
         {^connection_id, ^generation} <- media_owner(state, role),
         true <- generation == authority.owner,
         {:ok, identity, target} <-
           AdmissionCoordinator.call_media_session(state.call_attempt.id, user_id),
         true <- identity == authority.identity and target == authority.target,
         %{media_state_version: version, microphone_muted: muted, camera_enabled: enabled}
         when is_integer(version) and is_boolean(muted) and is_boolean(enabled) <- snapshot,
         previous = Map.get(state.media_states, role),
         true <- is_nil(previous) or version > previous.media_state_version do
      snapshot = Map.take(snapshot, [:media_state_version, :microphone_muted, :camera_enabled])
      state = %{state | media_states: Map.put(state.media_states, role, snapshot)}
      {:reply, :ok, rebroadcast_lifecycle(state)}
    else
      _ -> {:reply, {:error, :not_admitted}, state}
    end
  end

  def handle_call(
        {:register, user_id, role, connection_id},
        from,
        %{call_attempt: attempt} = state
      )
      when (role == :caller and user_id == attempt.caller_user_id) or
             (role == :recipient and user_id == attempt.recipient_user_id) do
    pid = elem(from, 0)

    state =
      case Map.fetch(state.registrations, connection_id) do
        {:ok, %{pid: ^pid} = entry} ->
          # Idempotent re-registration from the same channel: keep the original
          # monitor and registration order so channel churn cannot reorder
          # earliest-registered fallback election.
          put_registration(state, connection_id, %{entry | user_id: user_id, role: role})

        {:ok, entry} ->
          # A newer channel for the same Call Connection takes over the monitor
          # but keeps the connection's original registration order and
          # generation.
          Process.demonitor(entry.monitor_ref, [:flush])

          put_registration(state, connection_id, %{
            user_id: user_id,
            role: role,
            monitor_ref: Process.monitor(pid),
            pid: pid,
            seq: entry.seq,
            generation: entry.generation
          })

        :error ->
          seq = state.registration_seq + 1

          state =
            put_registration(state, connection_id, %{
              user_id: user_id,
              role: role,
              monitor_ref: Process.monitor(pid),
              pid: pid,
              seq: seq,
              generation: make_ref()
            })

          %{state | registration_seq: seq}
      end

    {:reply, :ok, state}
  end

  def handle_call({:register, _user_id, _role, _connection_id}, _from, state),
    do: {:reply, :ok, state}

  def handle_call({:authorize_media, user_id, connection_id}, {pid, _tag}, state) do
    result =
      if state.real_media?,
        do: authorize_owner(state, user_id, connection_id, pid),
        else: {:error, :not_admitted}

    {:reply, result, state}
  end

  def handle_call({operation, scope, connection_id}, {pid, _tag}, state)
      when operation in [:leave, :cancel] do
    # Serialize terminal controls with registration replacement and runtime
    # completion. Never wait for this mailbox while holding a DB lock.
    result =
      cond do
        operation == :cancel and state.call_attempt.state == :ringing ->
          # Durable acceptance can commit before its mailbox notification. The
          # ringing-only transaction guard prevents this path cancelling a pair.
          Calls.cancel_ringing_call(scope, state.call_attempt.id)

        match?({:ok, _}, authorize_owner(state, scope.user.id, connection_id, pid)) ->
          case operation do
            :leave -> Calls.leave_call(scope, state.call_attempt.id)
            :cancel -> Calls.cancel_call(scope, state.call_attempt.id)
          end

        true ->
          {:error, :stale}
      end

    case result do
      {:ok, %{state: :terminal}} -> {:stop, :normal, result, state}
      error -> {:reply, error, state}
    end
  end

  def handle_call({:unregister, connection_id, pid}, _from, state) do
    case Map.fetch(state.registrations, connection_id) do
      {:ok, %{pid: ^pid} = entry} ->
        Process.demonitor(entry.monitor_ref, [:flush])

        state = %{state | registrations: Map.delete(state.registrations, connection_id)}

        {:reply, :ok, release_ownership(entry, connection_id, state)}

      _stale_or_missing ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:ownership, :caller, connection_id}, _from, state) do
    case state.call_attempt.state do
      :ringing ->
        {:reply, preferred_caller_ownership(state, connection_id), state}

      _accepted ->
        {:reply, relative_ownership(state.caller_winner, connection_id), state}
    end
  end

  def handle_call({:ownership, :recipient, connection_id}, _from, state) do
    case state.call_attempt.state do
      :ringing -> {:reply, :unclaimed, state}
      _accepted -> {:reply, relative_ownership(state.recipient_winner, connection_id), state}
    end
  end

  def handle_call(
        {:claim_answer_mode, _answer_mode, _connection_id},
        _from,
        %{answer_mode: mode} = state
      )
      when mode in [:audio, :video] do
    {:reply, {:committed, mode}, state}
  end

  def handle_call(
        {:claim_answer_mode, answer_mode, connection_id},
        from,
        %{answer_mode_claim: nil} = state
      ) do
    claim_ref = make_ref()
    owner_ref = Process.monitor(elem(from, 0))

    {:reply, {:owner, claim_ref},
     %{
       state
       | answer_mode_claim: %{
           claim_ref: claim_ref,
           answer_mode: answer_mode,
           connection_id: connection_id,
           connection_generation: registration_generation(state, connection_id),
           owner_ref: owner_ref,
           status: :claiming
         }
     }}
  end

  def handle_call(
        {:claim_answer_mode, _answer_mode, _connection_id},
        from,
        %{answer_mode_claim: %{status: :abandoned} = claim} = state
      ) do
    owner_ref = Process.monitor(elem(from, 0))

    {:reply, {:reconcile, claim.claim_ref, claim.answer_mode},
     %{state | answer_mode_claim: %{claim | owner_ref: owner_ref, status: :reconciling}}}
  end

  def handle_call({:claim_answer_mode, _answer_mode, _connection_id}, from, state) do
    {:noreply, %{state | answer_mode_waiters: [from | state.answer_mode_waiters]}}
  end

  def handle_call(
        {:commit_answer_mode, claim_ref},
        _from,
        %{answer_mode_claim: %{claim_ref: claim_ref} = claim} = state
      ) do
    {:reply, :ok, commit_mode(state, claim, claim.answer_mode)}
  end

  def handle_call({:commit_answer_mode, _claim_ref}, _from, state), do: {:reply, :ok, state}

  def handle_call(
        {:resolve_answer_mode, claim_ref, answer_mode},
        _from,
        %{answer_mode_claim: %{claim_ref: claim_ref} = claim} = state
      ) do
    {:reply, :ok, commit_mode(state, claim, answer_mode)}
  end

  def handle_call({:resolve_answer_mode, _claim_ref, _answer_mode}, _from, state),
    do: {:reply, :ok, state}

  def handle_call(
        {:update_answer_mode_claim, claim_ref, answer_mode, connection_id},
        _from,
        %{answer_mode_claim: %{claim_ref: claim_ref, status: :reconciling} = claim} = state
      ) do
    connection_id = normalize_connection_id(connection_id)

    {:reply, :ok,
     %{
       state
       | answer_mode_claim: %{
           claim
           | answer_mode: answer_mode,
             connection_id: connection_id,
             connection_generation: registration_generation(state, connection_id)
         }
     }}
  end

  def handle_call(
        {:update_answer_mode_claim, _claim_ref, _answer_mode, _connection_id},
        _from,
        state
      ),
      do: {:reply, :ok, state}

  def handle_call(
        {:reject_answer_mode, claim_ref},
        _from,
        %{answer_mode_claim: %{claim_ref: claim_ref, status: :claiming} = claim} = state
      ) do
    Process.demonitor(claim.owner_ref, [:flush])
    Enum.each(state.answer_mode_waiters, &GenServer.reply(&1, :retry))
    {:reply, :ok, %{state | answer_mode_claim: nil, answer_mode_waiters: []}}
  end

  def handle_call(
        {:reject_answer_mode, claim_ref},
        _from,
        %{answer_mode_claim: %{claim_ref: claim_ref, status: :reconciling} = claim} = state
      ) do
    Process.demonitor(claim.owner_ref, [:flush])
    {:reply, :ok, advance_abandoned_claim(state, claim)}
  end

  def handle_call({:reject_answer_mode, _claim_ref}, _from, state), do: {:reply, :ok, state}

  def handle_call(
        {:discard_answer_mode, claim_ref},
        _from,
        %{answer_mode_claim: %{claim_ref: claim_ref} = claim} = state
      ) do
    if is_reference(claim.owner_ref), do: Process.demonitor(claim.owner_ref, [:flush])
    Enum.each(state.answer_mode_waiters, &GenServer.reply(&1, :retry))
    {:reply, :ok, %{state | answer_mode_claim: nil, answer_mode_waiters: []}}
  end

  def handle_call({:discard_answer_mode, _claim_ref}, _from, state), do: {:reply, :ok, state}

  def handle_call(
        {:begin_accepted_call, %CallAttempt{id: call_id} = call_attempt, answer_mode},
        _from,
        %{call_attempt: %CallAttempt{id: call_id} = current, answer_mode: answer_mode} = state
      ) do
    cond do
      current.state in [:connecting, :active] ->
        projection = current |> Calls.to_projection() |> Calls.with_answer_mode(answer_mode)
        {:reply, {:ok, projection}, state}

      call_attempt.state != :connecting ->
        {:reply, {:error, :stale}, state}

      true ->
        begin_connecting(call_attempt, answer_mode, state)
    end
  end

  def handle_call({:begin_accepted_call, _call_attempt, _answer_mode}, _from, state) do
    {:reply, {:error, :stale}, state}
  end

  @impl true
  def handle_info(
        {:call_media_runtime, call_id, generation, target},
        %{call_attempt: %CallAttempt{id: call_id, state: phase}} = state
      )
      when phase in [:connecting, :active] and is_reference(generation) and is_pid(target) do
    if current_media_runtime?(call_id, generation, target) do
      case state.media_runtime do
        %{generation: ^generation, target: ^target} ->
          {:noreply, state}

        previous ->
          if previous, do: Process.demonitor(previous.monitor, [:flush])

          runtime = %{
            call_id: call_id,
            generation: generation,
            target: target,
            monitor: Process.monitor(target)
          }

          # Monitoring a target that died after publication immediately queues
          # DOWN. Do not probe liveness or create a replacement runtime.
          {:noreply, %{state | media_runtime: runtime}}
      end
    else
      {:noreply, state}
    end
  end

  def handle_info(
        {:accepted_call_runtime, call_id, result},
        %{call_attempt: %CallAttempt{id: call_id, state: :connecting}, real_media?: real?} = state
      )
      when result in @runtime_results and (result != :ready or not real?) do
    complete_accepted_runtime(result, state)
  end

  def handle_info({:accepted_call_runtime, _call_id, _result}, state) do
    {:noreply, state}
  end

  def handle_info(
        {:call_transport_state, call_id, generation, statuses},
        %{call_attempt: %CallAttempt{id: call_id, state: :connecting}, real_media?: true} = state
      ) do
    if map_size(statuses) == 2 and
         Enum.all?(statuses, fn {_id, status} -> status == :connected end) do
      complete_accepted_runtime({:connected, generation}, state)
    else
      {:noreply, state}
    end
  end

  def handle_info({:call_transport_state, _call_id, _generation, _statuses}, state),
    do: {:noreply, state}

  def handle_info(
        {:media_target_failed, call_id, _reason},
        %{call_attempt: %CallAttempt{id: call_id}} = state
      ) do
    fail_media_runtime(state)
  end

  def handle_info({:media_target_failed, _call_id, _reason}, state) do
    {:noreply, state}
  end

  def handle_info(
        {:DOWN, monitor, :process, target, _reason},
        %{
          call_attempt: %CallAttempt{id: call_id, state: phase},
          media_runtime: %{
            call_id: call_id,
            generation: generation,
            target: target,
            monitor: monitor
          }
        } = state
      )
      when phase in [:connecting, :active] do
    # Start the existing coordinator clock before any query or durable work.
    # Generation fencing keeps retirement of a replaced target harmless.
    AdmissionCoordinator.begin_terminal_cleanup(call_id, generation)

    if current_media_runtime?(call_id, generation, target, true) do
      fail_media_runtime(state)
    else
      {:noreply, %{state | media_runtime: nil}}
    end
  end

  def handle_info(
        {:DOWN, owner_ref, :process, _pid, _reason},
        %{answer_mode_claim: %{owner_ref: owner_ref} = claim} = state
      ) do
    {:noreply, advance_abandoned_claim(state, claim)}
  end

  def handle_info({:DOWN, monitor_ref, :process, _pid, _reason}, state) do
    case Enum.find(state.registrations, fn {_connection_id, entry} ->
           entry.monitor_ref == monitor_ref
         end) do
      nil ->
        {:noreply, state}

      {connection_id, entry} ->
        Process.demonitor(entry.monitor_ref, [:flush])

        state = %{state | registrations: Map.delete(state.registrations, connection_id)}

        {:noreply, release_ownership(entry, connection_id, state)}
    end
  end

  def handle_info(
        {:ringing_deadline, call_id, deadline},
        %{call_attempt: %CallAttempt{} = attempt} = state
      ) do
    if matching_armed_deadline?(attempt, call_id, deadline) do
      handle_armed_deadline(call_id, state)
    else
      {:noreply, state}
    end
  end

  def handle_info(_message, state) do
    {:noreply, state}
  end

  defp handle_armed_deadline(call_id, state) do
    case Calls.expire_ringing_attempt(call_id) do
      {:ok, %{state: :terminal}} ->
        {:stop, :normal, state}

      {:ok, %{state: :ringing}} ->
        {:noreply, rearm_ringing_deadline(state)}

      {:error, :temporarily_unavailable} ->
        {:noreply, rearm_ringing_deadline(state, min_delay_ms: @transient_retry_ms)}

      {:error, _reason} ->
        {:noreply, state}
    end
  end

  defp begin_connecting(%CallAttempt{} = call_attempt, answer_mode, state) do
    _ = cancel_ringing_timer(state.ringing_timer_ref)

    caller_winner = elect_caller_winner(state)

    state = %{
      state
      | call_attempt: call_attempt,
        ringing_timer_ref: nil,
        answer_mode: answer_mode,
        caller_winner: caller_winner,
        caller_winner_generation: registration_generation(state, caller_winner)
    }

    projection = call_attempt |> Calls.to_projection() |> Calls.with_answer_mode(answer_mode)
    Calls.broadcast_connecting(projection)

    case accepted_call_runtime().schedule(self(), call_attempt.id) do
      :ok ->
        {:reply, {:ok, projection}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp elect_caller_winner(state) do
    if preferred_caller_registered?(state) do
      state.preferred_caller_connection_id
    else
      state.registrations
      |> Enum.filter(fn {_connection_id, entry} -> entry.role == :caller end)
      |> Enum.min_by(fn {_connection_id, entry} -> entry.seq end, fn -> nil end)
      |> case do
        nil -> nil
        {connection_id, _entry} -> connection_id
      end
    end
  end

  defp preferred_caller_registered?(state) do
    is_binary(state.preferred_caller_connection_id) and
      not state.preferred_caller_released and
      Map.has_key?(state.registrations, state.preferred_caller_connection_id)
  end

  # The recorded start connection is self from the moment it is recorded until
  # its Call topic terminates. The Call Inbox records the preference without
  # registering a per-call connection, so the check is "has not been released",
  # not "is currently registered"; the release is permanent for the attempt, so
  # a later rejoin of the same Call Connection cannot restore or win the
  # preference back.
  defp preferred_caller_ownership(state, connection_id) do
    if is_binary(connection_id) and connection_id == state.preferred_caller_connection_id and
         not state.preferred_caller_released do
      :self
    else
      :elsewhere
    end
  end

  defp authorize_owner(state, user_id, connection_id, pid) do
    with true <- state.call_attempt.state in [:connecting, :active],
         %{user_id: ^user_id, pid: ^pid, role: role, generation: generation} <-
           Map.get(state.registrations, connection_id),
         {^connection_id, ^generation} <- media_owner(state, role) do
      {:ok, generation}
    else
      _ -> {:error, :not_admitted}
    end
  end

  defp media_owner(state, :caller),
    do: {state.caller_winner, state.caller_winner_generation}

  defp media_owner(state, :recipient),
    do: {state.recipient_winner, state.recipient_winner_generation}

  defp relative_ownership(nil, _connection_id), do: :unclaimed
  defp relative_ownership(winner, connection_id) when winner == connection_id, do: :self
  defp relative_ownership(_winner, _connection_id), do: :elsewhere

  defp release_ownership(%{role: role} = entry, connection_id, state) do
    state = maybe_release_preferred_caller(entry, connection_id, state)

    selected? =
      (role == :caller and state.caller_winner == connection_id) or
        (role == :recipient and state.recipient_winner == connection_id)

    if state.real_media? and selected? and state.call_attempt.state in [:connecting, :active] do
      DiscordClone.Media.AdmissionCoordinator.begin_terminal_cleanup(state.call_attempt.id)
      send(self(), {:media_target_failed, state.call_attempt.id, :owner_lost})
    end

    cond do
      role == :caller and state.caller_winner == connection_id ->
        rebroadcast_lifecycle(%{state | caller_winner: nil})

      role == :recipient and state.recipient_winner == connection_id ->
        rebroadcast_lifecycle(%{state | recipient_winner: nil})

      role == :caller and state.preferred_caller_connection_id == connection_id ->
        rebroadcast_ringing(state)

      true ->
        state
    end
  end

  defp maybe_release_preferred_caller(%{role: :caller}, connection_id, state) do
    if connection_id == state.preferred_caller_connection_id do
      %{state | preferred_caller_released: true}
    else
      state
    end
  end

  defp maybe_release_preferred_caller(_entry, _connection_id, state), do: state

  defp put_registration(state, connection_id, entry) do
    put_in(state, [:registrations, connection_id], entry)
  end

  defp registration_generation(state, connection_id) when is_binary(connection_id) do
    case Map.fetch(state.registrations, connection_id) do
      {:ok, entry} -> entry.generation
      :error -> nil
    end
  end

  defp registration_generation(_state, _connection_id), do: nil

  defp rebroadcast_ringing(%{call_attempt: %CallAttempt{state: :ringing}} = state) do
    state.call_attempt
    |> Calls.to_projection()
    |> Calls.broadcast_ringing()

    state
  end

  defp rebroadcast_ringing(state), do: state

  defp rebroadcast_lifecycle(%{call_attempt: %CallAttempt{state: state_name}} = state)
       when state_name in [:connecting, :active] do
    projection = lifecycle_projection(state)

    case state_name do
      :connecting -> Calls.broadcast_connecting(projection)
      :active -> Calls.broadcast_active(projection)
    end

    state
  end

  defp rebroadcast_lifecycle(state), do: state

  defp lifecycle_projection(state) do
    projection =
      state.call_attempt
      |> Calls.to_projection()
      |> Calls.with_answer_mode(state.answer_mode)

    case projected_media_state(state) do
      snapshots when map_size(snapshots) > 0 -> Map.put(projection, :media_state, snapshots)
      _ -> projection
    end
  end

  defp projected_media_state(%{call_attempt: %{state: stage}, media_states: snapshots})
       when stage in [:connecting, :active],
       do: snapshots

  defp projected_media_state(_state), do: %{}

  defp commit_mode(state, claim, answer_mode) do
    if is_reference(claim.owner_ref), do: Process.demonitor(claim.owner_ref, [:flush])
    Enum.each(state.answer_mode_waiters, &GenServer.reply(&1, {:committed, answer_mode}))

    recipient_winner = bind_recipient_winner(state, claim)

    %{
      state
      | answer_mode: answer_mode,
        answer_mode_claim: nil,
        answer_mode_waiters: [],
        recipient_winner: recipient_winner,
        recipient_winner_generation: registration_generation(state, recipient_winner)
    }
  end

  # The first valid accepting connection wins, but a claim only binds the
  # connection that recorded it under the same registration generation. A claim
  # holder that departed (for example a process that committed durably and then
  # died before committing its claim) leaves the role without a live winner, and
  # a later rejoin cannot revive the pre-departure claim because it registers a
  # new generation. A fresh acceptance registers a fresh claim and binds
  # normally, and an accept is still bound defensively when the recorded
  # connection never registered at all.
  defp bind_recipient_winner(state, claim) do
    winner = normalize_connection_id(Map.get(claim, :connection_id))

    if is_binary(winner) and
         Map.get(claim, :connection_generation) == registration_generation(state, winner) do
      winner
    else
      nil
    end
  end

  defp advance_abandoned_claim(%{answer_mode_waiters: [next | rest]} = state, claim) do
    owner_ref = Process.monitor(elem(next, 0))
    GenServer.reply(next, {:reconcile, claim.claim_ref, claim.answer_mode})

    %{
      state
      | answer_mode_claim: %{claim | owner_ref: owner_ref, status: :reconciling},
        answer_mode_waiters: rest
    }
  end

  defp advance_abandoned_claim(state, claim) do
    %{state | answer_mode_claim: %{claim | owner_ref: nil, status: :abandoned}}
  end

  defp fail_media_runtime(%{call_attempt: %{id: call_id}} = state) do
    # Both observers settle through the same durable, idempotent orchestration.
    # AdmissionCoordinator alone confirms resources and releases accounting.
    case Calls.fail_call_for_media_loss(call_id) do
      {:ok, %{} = projection} ->
        {:stop, :normal,
         %{state | call_attempt: Map.put(state.call_attempt, :state, projection.state)}}

      {:error, _reason} ->
        {:noreply, state}
    end
  end

  defp current_media_runtime?(call_id, generation, target, retired? \\ false) do
    case AdmissionCoordinator.call_target_runtime_identity(call_id) do
      %{call_id: ^call_id, runtime_generation: ^generation, target_pid: ^target} -> true
      nil -> retired?
      _replacement -> false
    end
  end

  defp complete_accepted_runtime(result, state) do
    case Calls.complete_accepted_runtime(state.call_attempt.id, result, state.answer_mode) do
      {:ok, :activated, %CallAttempt{} = call_attempt} ->
        {:noreply, %{state | call_attempt: call_attempt}}

      {:ok, :terminal} ->
        {:stop, :normal, state}

      {:error, _reason} ->
        {:noreply, state}
    end
  end

  defp accepted_call_runtime do
    Application.get_env(:discord_clone, :accepted_call_runtime, PairAdmissionRuntime)
  end

  defp matching_armed_deadline?(%CallAttempt{state: :ringing} = attempt, call_id, deadline) do
    attempt.id == call_id and DateTime.compare(attempt.ringing_deadline_at, deadline) == :eq
  end

  defp matching_armed_deadline?(_attempt, _call_id, _deadline), do: false

  defp rearm_ringing_deadline(state, opts \\ []) do
    min_delay_ms = Keyword.get(opts, :min_delay_ms, 0)
    _ = cancel_ringing_timer(state.ringing_timer_ref)

    %{
      state
      | ringing_timer_ref: arm_ringing_deadline(state.call_attempt, min_delay_ms)
    }
  end

  defp arm_ringing_deadline(call_attempt, min_delay_ms \\ 0)

  defp arm_ringing_deadline(
         %CallAttempt{state: :ringing, id: call_id, ringing_deadline_at: deadline},
         min_delay_ms
       ) do
    Process.send_after(
      self(),
      {:ringing_deadline, call_id, deadline},
      remaining_deadline_ms(deadline, min_delay_ms)
    )
  end

  defp arm_ringing_deadline(_call_attempt, _min_delay_ms), do: nil

  defp remaining_deadline_ms(%DateTime{} = deadline, min_delay_ms) do
    max(DateTime.diff(deadline, DateTime.utc_now(:millisecond), :millisecond), min_delay_ms)
  end

  defp cancel_ringing_timer(timer_ref) when is_reference(timer_ref) do
    Process.cancel_timer(timer_ref)
  end

  defp cancel_ringing_timer(_timer_ref), do: false

  defp normalize_connection_id(connection_id) when is_binary(connection_id), do: connection_id
  defp normalize_connection_id(_connection_id), do: nil

  defp via(call_id) do
    {:via, Registry, {DiscordClone.Calls.CallRegistry, call_id}}
  end
end
