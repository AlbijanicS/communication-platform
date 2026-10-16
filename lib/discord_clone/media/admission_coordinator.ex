defmodule DiscordClone.Media.AdmissionCoordinator do
  @moduledoc false

  use GenServer

  alias DiscordClone.Calls
  alias DiscordClone.Media.{AdmissionDiagnostics, DirectCallTarget, Profile, Target}
  alias DiscordClone.Voice
  alias DiscordClone.Voice.{DeploymentCapacity, RoomServer, ServerICEProjection}

  # The Ticket 01 recovery characterization locates this registered process by its old name.
  @server_name DiscordClone.Voice.SessionCoordinator

  @recovery_timeout_ms :timer.seconds(5)
  @reservation_ttl_ms :timer.seconds(20)
  # Each slow pair-commit step outside the mailbox is bounded by this call
  # timeout and converted to an error; see `commit_pair/2`.
  @pair_step_timeout_ms :timer.seconds(5)
  # Reverse-switch destination holds mirror the pair reservation TTL and step
  # timeout. Slow room shutdown/startup runs outside the mailbox while the
  # destination slot is held.
  @voice_switch_ttl_ms :timer.seconds(20)
  @voice_switch_step_timeout_ms :timer.seconds(5)

  @type pair_plan :: %{
          required(:call_id) => Ecto.UUID.t(),
          required(:generation) => reference(),
          required(:user_ids) => [Ecto.UUID.t()],
          required(:prior_identities) => %{Ecto.UUID.t() => map() | nil},
          required(:target_pid) => pid(),
          required(:target_runtime_generation) => reference()
        }

  # The `(call_id, generation)` pair recurs across ~10 coordinator APIs and
  # `{user_id, prior}` in `reserve_pair/3`. Keep the existing bundled
  # switch-request map pattern; type-spec only, no public struct (would leak
  # internals to Channels).
  @type voice_switch_plan :: %{
          required(:call_id) => Ecto.UUID.t(),
          required(:generation) => reference(),
          required(:user_id) => Ecto.UUID.t(),
          required(:peer_user_id) => Ecto.UUID.t(),
          required(:voice_channel_id) => Ecto.UUID.t(),
          required(:call_sessions) => %{Ecto.UUID.t() => Ecto.UUID.t()},
          required(:target_runtime_generation) => reference()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, :ok, opts)

  @doc """
  Returns the effective shared occupancy from the coordinator ledger.

  Active slots plus reserved slots minus exact replacement credits. Reads the
  same `occupied_slots` ledger the admission decision reads.
  """
  @spec effective_occupancy() :: non_neg_integer()
  def effective_occupancy do
    case try_admission_gauges() do
      %{occupancy: occupancy} -> occupancy
      _ -> 0
    end
  end

  @doc """
  Returns the active reservation count (pair reservation plus held switches).
  """
  @spec reservation_count() :: non_neg_integer()
  def reservation_count do
    case try_admission_gauges() do
      %{reservation_count: count} -> count
      _ -> 0
    end
  end

  @doc "Returns the held reverse-switch destination count."
  @spec held_switch_count() :: non_neg_integer()
  def held_switch_count do
    case try_admission_gauges() do
      %{held_switch_count: count} -> count
      _ -> 0
    end
  end

  @doc """
  Returns the coordinator mailbox length without blocking the mailbox.

  Read-only `Process.info/2` from the caller; never adds work to the mailbox.
  """
  @spec mailbox_length() :: non_neg_integer()
  def mailbox_length do
    case Process.whereis(@server_name) do
      nil ->
        0

      pid when is_pid(pid) ->
        case Process.info(pid, :message_queue_len) do
          {:message_queue_len, len} when is_integer(len) and len >= 0 -> len
          _ -> 0
        end
    end
  rescue
    _ -> 0
  catch
    _, _ -> 0
  end

  @doc """
  Returns combined admission gauges without changing admission state.
  """
  @spec admission_gauges() :: %{
          occupancy: non_neg_integer(),
          reservation_count: non_neg_integer(),
          held_switch_count: non_neg_integer(),
          mailbox_len: non_neg_integer()
        }
  def admission_gauges do
    ledger =
      try do
        GenServer.call(@server_name, :admission_gauges)
      catch
        :exit, _ -> %{occupancy: 0, reservation_count: 0, held_switch_count: 0}
      end

    Map.put(ledger, :mailbox_len, mailbox_length())
  rescue
    _ -> %{occupancy: 0, reservation_count: 0, held_switch_count: 0, mailbox_len: 0}
  catch
    _, _ -> %{occupancy: 0, reservation_count: 0, held_switch_count: 0, mailbox_len: 0}
  end

  defp try_admission_gauges do
    GenServer.call(@server_name, :admission_gauges)
  catch
    :exit, _ -> %{occupancy: 0, reservation_count: 0, held_switch_count: 0}
  end

  # Allowlisted telemetry emission from the caller process, never the mailbox.
  # Runs after the admission decision; failures never change the result.
  defp emit_admission(operation, result, started_ms) do
    duration = System.monotonic_time(:millisecond) - started_ms
    {outcome, error_code} = AdmissionDiagnostics.classify(result)
    gauges = admission_gauges()

    _ =
      try do
        AdmissionDiagnostics.emit(operation, outcome,
          duration_ms: duration,
          occupancy: Map.get(gauges, :occupancy, 0),
          reservation_count: Map.get(gauges, :reservation_count, 0),
          mailbox_len: Map.get(gauges, :mailbox_len, 0),
          error_code: error_code
        )
      rescue
        _ -> :ok
      catch
        _, _ -> :ok
      end

    :ok
  end

  @spec join(Ecto.UUID.t(), Ecto.UUID.t(), binary(), pid()) ::
          {:ok, map()} | {:error, term()}
  def join(voice_channel_id, user_id, signaling_session_id, signaling_channel) do
    join(
      voice_channel_id,
      user_id,
      signaling_session_id,
      signaling_channel,
      ServerICEProjection.disabled()
    )
  end

  @spec join(Ecto.UUID.t(), Ecto.UUID.t(), binary(), pid(), ServerICEProjection.t()) ::
          {:ok, map()} | {:error, term()}
  def join(
        voice_channel_id,
        user_id,
        signaling_session_id,
        signaling_channel,
        server_ice_projection
      ) do
    started_ms = System.monotonic_time(:millisecond)

    result =
      do_join(
        voice_channel_id,
        user_id,
        signaling_session_id,
        signaling_channel,
        server_ice_projection
      )

    _ = emit_admission("join", result, started_ms)
    result
  end

  defp do_join(
         voice_channel_id,
         user_id,
         signaling_session_id,
         signaling_channel,
         server_ice_projection
       ) do
    case begin_voice_switch(user_id, voice_channel_id) do
      {:normal} ->
        GenServer.call(
          @server_name,
          {:join, voice_channel_id, user_id, signaling_session_id, signaling_channel,
           server_ice_projection}
        )

      {:error, _reason} = error ->
        error

      {:ok, plan} ->
        run_voice_switch(%{
          plan: plan,
          voice_channel_id: voice_channel_id,
          user_id: user_id,
          signaling_session_id: signaling_session_id,
          signaling_channel: signaling_channel,
          server_ice_projection: server_ice_projection
        })
    end
  end

  @doc """
  Begins a reverse-switch destination hold for one active Call member.

  Prepares the destination in the caller, then atomically revalidates and
  reserves it in the coordinator before either Call Session can end.
  """
  @spec begin_voice_switch(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:normal} | {:ok, map()} | {:error, term()}
  def begin_voice_switch(user_id, voice_channel_id) do
    started_ms = System.monotonic_time(:millisecond)

    try do
      case GenServer.call(@server_name, {:begin_voice_switch, user_id, voice_channel_id}) do
        {:prepare, candidate} ->
          deadline = started_ms + @voice_switch_step_timeout_ms
          prepare_voice_switch(user_id, voice_channel_id, candidate, deadline)

        result ->
          result
      end
    else
      result ->
        _ = emit_admission("begin_voice_switch", result, started_ms)
        result
    catch
      :exit, reason ->
        _ = emit_admission("begin_voice_switch", {:error, :unavailable}, started_ms)
        :erlang.raise(:exit, reason, __STACKTRACE__)
    end
  end

  defp prepare_voice_switch(user_id, voice_channel_id, candidate, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining > 0 do
      case prepare_voice_switch_destination(voice_channel_id, remaining) do
        {:ok, occupancy} ->
          reserve_prepared_voice_switch(user_id, voice_channel_id, candidate, occupancy, deadline)

        {:error, _reason} ->
          {:error, :unavailable}
      end
    else
      {:error, :unavailable}
    end
  end

  # Only room preparation runs in this killable worker. It cannot reserve a
  # destination or end a Call. Its independent timer also bounds startup if
  # the caller dies while waiting in DynamicSupervisor.start_child/2.
  defp prepare_voice_switch_destination(voice_channel_id, remaining) do
    caller = self()

    {worker, monitor} =
      spawn_monitor(fn ->
        {:ok, timer} = :timer.kill_after(remaining, self())

        result =
          with :ok <- Voice.ensure_room(voice_channel_id) do
            Voice.room_occupancy(voice_channel_id)
          end

        :timer.cancel(timer)
        send(caller, {:voice_switch_prepared, self(), result})
      end)

    preparation =
      receive do
        {:voice_switch_prepared, ^worker, result} -> result
        {:DOWN, ^monitor, :process, ^worker, _reason} -> {:error, :unavailable}
      after
        remaining ->
          Process.exit(worker, :kill)

          receive do
            {:DOWN, ^monitor, :process, ^worker, _reason} -> :ok
          end

          receive do
            {:voice_switch_prepared, ^worker, _late_result} -> :ok
          after
            0 -> :ok
          end

          {:error, :unavailable}
      end

    Process.demonitor(monitor, [:flush])
    preparation
  end

  defp reserve_prepared_voice_switch(user_id, voice_channel_id, candidate, occupancy, deadline) do
    if System.monotonic_time(:millisecond) < deadline do
      case GenServer.call(
             @server_name,
             {:reserve_voice_switch, user_id, voice_channel_id, candidate, occupancy}
           ) do
        {:prepare, updated_candidate} ->
          prepare_voice_switch(user_id, voice_channel_id, updated_candidate, deadline)

        result ->
          result
      end
    else
      {:error, :unavailable}
    end
  end

  @doc """
  Publishes one held reverse-switch destination after Voice admission.

  Thin timed wrapper; emits allowlisted telemetry from the caller.
  """
  @spec publish_voice_switch(
          Ecto.UUID.t(),
          reference(),
          Ecto.UUID.t(),
          binary(),
          map(),
          pid()
        ) :: {:ok, map()} | {:error, term()}
  def publish_voice_switch(
        user_id,
        generation,
        voice_channel_id,
        signaling_session_id,
        join_result,
        room_server
      ) do
    started_ms = System.monotonic_time(:millisecond)

    try do
      GenServer.call(
        @server_name,
        {:publish_voice_switch, user_id, generation, voice_channel_id, signaling_session_id,
         join_result, room_server},
        @voice_switch_step_timeout_ms
      )
    else
      result ->
        _ = emit_admission("publish_voice_switch", result, started_ms)
        result
    catch
      :exit, reason ->
        _ = emit_admission("publish_voice_switch", {:error, :unavailable}, started_ms)
        :erlang.raise(:exit, reason, __STACKTRACE__)
    end
  end

  @doc """
  Releases one held reverse-switch destination hold.

  Best-effort and idempotent; always returns `:ok`. Caller telemetry retains
  the acknowledged result or reports unavailable when the coordinator exits.
  """
  @spec abort_voice_switch(Ecto.UUID.t(), reference()) :: :ok
  def abort_voice_switch(user_id, generation) do
    started_ms = System.monotonic_time(:millisecond)

    result =
      try do
        GenServer.call(@server_name, {:abort_voice_switch, user_id, generation})
      catch
        :exit, _unavailable -> {:error, :unavailable}
      end

    _ = emit_admission("abort_voice_switch", result, started_ms)
    :ok
  end

  # Reverse-switch orchestration runs in the caller process, never in the
  # coordinator mailbox and never while holding a DB row lock. Steps:
  # eligible durable active check → short durable `ended` commit (Ticket 08
  # funnel) → slow `join_room` under the held destination reservation →
  # single-transition publish/abort. Any failure after the Call ended never
  # recreates the Call.
  defp run_voice_switch(%{plan: plan} = request) do
    case Calls.voice_switch_eligible?(plan.call_id, request.user_id) do
      :ok ->
        end_call_then_admit(request)

      {:error, :retryable} ->
        abort_and_conflict(request)

      {:error, _reason} ->
        abort_and_fallback(request)
    end
  end

  defp end_call_then_admit(%{plan: plan} = request) do
    case Calls.end_active_call_for_voice_switch(plan.call_id, request.user_id) do
      {:ok, _projection} ->
        admit_under_switch(request)

      {:error, :retryable} ->
        abort_and_conflict(request)

      {:error, _reason} ->
        abort_and_fallback(request)
    end
  end

  defp abort_and_conflict(%{user_id: user_id, plan: %{generation: generation}}) do
    _ = abort_voice_switch(user_id, generation)
    {:error, %{reason: :reservation_conflict}}
  end

  defp abort_and_fallback(%{
         plan: plan,
         voice_channel_id: voice_channel_id,
         user_id: user_id,
         signaling_session_id: signaling_session_id,
         signaling_channel: signaling_channel,
         server_ice_projection: server_ice_projection
       }) do
    _ = abort_voice_switch(user_id, plan.generation)
    # Durable already terminal: the Call is gone, so fall back to the
    # normal Voice path without resurrecting media.
    GenServer.call(
      @server_name,
      {:join, voice_channel_id, user_id, signaling_session_id, signaling_channel,
       server_ice_projection}
    )
  end

  defp admit_under_switch(
         %{
           plan: plan,
           voice_channel_id: voice_channel_id,
           user_id: user_id,
           signaling_session_id: signaling_session_id,
           signaling_channel: signaling_channel,
           server_ice_projection: server_ice_projection
         } = request
       ) do
    if voice_switch_fault?(user_id) do
      _ = abort_voice_switch(user_id, plan.generation)
      {:error, :unavailable}
    else
      case Voice.join_room(
             voice_channel_id,
             user_id,
             signaling_session_id,
             signaling_channel,
             server_ice_projection
           ) do
        {:ok, %{voice_session_id: _voice_session_id} = join_result, room_server} ->
          publish_switch(request, join_result, room_server)

        {:error, %{reason: :room_full} = room_full} ->
          _ = abort_voice_switch(user_id, plan.generation)
          {:error, room_full}

        {:error, _reason} ->
          _ = abort_voice_switch(user_id, plan.generation)
          {:error, :unavailable}
      end
    end
  end

  # Single-transition publish with fail-closed timeout handling. A returned
  # error releases the RoomServer session and the held switch. A call
  # timeout/exit must not hold the switch to its TTL or leak the created
  # room session, so it performs the same release plus a best-effort
  # coordinator cleanup for the ambiguous timeout-after-publish case.
  defp publish_switch(
         %{plan: plan, voice_channel_id: voice_channel_id, user_id: user_id} = request,
         join_result,
         room_server
       ) do
    %{signaling_session_id: signaling_session_id} = request
    started_ms = System.monotonic_time(:millisecond)

    result =
      try do
        case GenServer.call(
               @server_name,
               {:publish_voice_switch, user_id, plan.generation, voice_channel_id,
                signaling_session_id, join_result, room_server},
               @voice_switch_step_timeout_ms
             ) do
          {:ok, _published} = ok ->
            ok

          {:error, _reason} ->
            _ = Voice.leave_room(voice_channel_id, join_result.voice_session_id)
            _ = abort_voice_switch(user_id, plan.generation)
            {:error, :unavailable}
        end
      catch
        :exit, _unavailable ->
          _ = Voice.leave_room(voice_channel_id, join_result.voice_session_id)
          _ = abort_voice_switch(user_id, plan.generation)

          _ =
            try do
              GenServer.call(@server_name, {:end_user_session, voice_channel_id, user_id})
            catch
              :exit, _ -> :ok
            end

          {:error, :unavailable}
      end

    _ = emit_admission("publish_voice_switch", result, started_ms)
    result
  end

  # Test-only deterministic fault seam for post-termination startup failure.
  # Production default is `%{}` (inert). Tests set
  # `Application.put_env(:discord_clone, :voice_switch_fault, %{admit_failures: [user_id]})`.
  defp voice_switch_fault?(user_id) do
    case Application.get_env(:discord_clone, :voice_switch_fault, %{}) do
      %{admit_failures: failures} when is_list(failures) -> user_id in failures
      _ -> false
    end
  end

  @spec leave(Ecto.UUID.t(), Ecto.UUID.t()) :: :ok
  def leave(voice_channel_id, voice_session_id) do
    GenServer.call(@server_name, {:leave, voice_channel_id, voice_session_id})
  end

  @spec end_user_session(Ecto.UUID.t(), Ecto.UUID.t()) :: :ok
  def end_user_session(voice_channel_id, user_id) do
    GenServer.call(@server_name, {:end_user_session, voice_channel_id, user_id})
  end

  @spec end_channel_sessions(Ecto.UUID.t()) :: :ok
  def end_channel_sessions(voice_channel_id) do
    GenServer.call(@server_name, {:end_channel_sessions, voice_channel_id})
  end

  @doc "Returns the exact current Media Target identity for pair preflight."
  def current_identity(user_id), do: GenServer.call(@server_name, {:current_identity, user_id})

  @doc false
  def call_media_session(call_id, user_id),
    do: GenServer.call(@server_name, {:call_media_session, call_id, user_id})

  @doc false
  def call_transport_state(call_id, generation, statuses),
    do:
      GenServer.cast(@server_name, {:call_transport_state, call_id, generation, self(), statuses})

  @doc false
  def call_activation_deadline(call_id, generation),
    do: GenServer.call(@server_name, {:call_activation_deadline, call_id, generation})

  @doc false
  def call_activated(call_id, generation),
    do: GenServer.call(@server_name, {:call_activated, call_id, generation})

  @doc """
  Reserves both Call slots for one accepted Direct Call pair.

  Authoritative preflight reads the durable Call Attempt and current Friendship
  before the coordinator verifies both expected prior identities, the ready
  Direct Call target, and both private-alpha limits. The reservation snapshots
  the verified prior identities and pins both Users without moving either one.
  """
  @spec reserve_pair(Ecto.UUID.t(), {Ecto.UUID.t(), map() | nil}, {Ecto.UUID.t(), map() | nil}) ::
          {:ok, map()} | {:error, term()}
  def reserve_pair(call_id, {first_user_id, first_prior}, {second_user_id, second_prior}) do
    started_ms = System.monotonic_time(:millisecond)

    result =
      with :ok <- Calls.pair_preflight(call_id, first_user_id, second_user_id) do
        GenServer.call(
          @server_name,
          {:reserve_pair, call_id, {first_user_id, first_prior}, {second_user_id, second_prior}}
        )
      end

    _ = emit_admission("reserve_pair", result, started_ms)
    result
  end

  @doc """
  Commits one exact pair reservation whose Call Attempt is durably connecting.

  Both exact prior Voice Sessions are retired outside the coordinator, both
  logical Call Sessions are created privately in the reserved target runtime,
  and both per-User indexes are replaced in one coordinator transition. Each
  slow room step is bounded by its runtime call timeout and converted to an
  error, and a pair result is never returned with only one Call Session.
  """
  @spec commit_pair(Ecto.UUID.t(), reference()) :: {:ok, map()} | {:error, term()}
  def commit_pair(call_id, generation) do
    started_ms = System.monotonic_time(:millisecond)
    caller = self()

    {worker, monitor} =
      spawn_monitor(fn ->
        send(caller, {:pair_commit_result, self(), do_commit_pair(call_id, generation, caller)})
      end)

    result = await_pair_commit(worker, monitor)
    _ = emit_admission("commit_pair", result, started_ms)
    result
  end

  defp await_pair_commit(worker, monitor) do
    receive do
      {:pair_commit_authorize, ^worker, plan} ->
        send(worker, {:pair_commit_authorized, ensure_durably_connecting(plan)})
        await_pair_commit(worker, monitor)

      {:pair_commit_result, ^worker, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^worker, _reason} ->
        GenServer.call(@server_name, {:pair_worker_result, worker}, :infinity)
    end
  end

  defp do_commit_pair(call_id, generation, caller) do
    begin_started_ms = System.monotonic_time(:millisecond)

    begin_result =
      try do
        GenServer.call(
          @server_name,
          {:begin_pair_commit, call_id, generation},
          @pair_step_timeout_ms
        )
      else
        result ->
          _ = emit_admission("begin_pair_commit", result, begin_started_ms)
          result
      catch
        :exit, reason ->
          _ = emit_admission("begin_pair_commit", {:error, :unavailable}, begin_started_ms)
          :erlang.raise(:exit, reason, __STACKTRACE__)
      end

    case begin_result do
      {:ok, plan} ->
        send(caller, {:pair_commit_authorize, self(), plan})

        authorized =
          receive do
            {:pair_commit_authorized, result} -> result
          end

        with :ok <- authorized,
             {:ok, sessions} <- retire_and_create_sessions(plan) do
          pair_commit_barrier(:before_publish)

          case check_publish_fault() do
            :ok ->
              publish_started_ms = System.monotonic_time(:millisecond)

              publish_result =
                try do
                  GenServer.call(
                    @server_name,
                    {:publish_pair_commit, plan.call_id, plan.generation,
                     plan.target_runtime_generation, sessions},
                    @pair_step_timeout_ms
                  )
                else
                  result ->
                    _ = emit_admission("publish_pair_commit", result, publish_started_ms)
                    result
                catch
                  :exit, reason ->
                    _ =
                      emit_admission(
                        "publish_pair_commit",
                        {:error, :unavailable},
                        publish_started_ms
                      )

                    :erlang.raise(:exit, reason, __STACKTRACE__)
                end

              case publish_result do
                {:ok, _result} = published -> published
                {:error, reason} -> abort_pair_commit(plan, sessions, reason)
              end

            {:error, reason} ->
              abort_pair_commit(plan, sessions, reason)
          end
        else
          {:error, reason} -> abort_pair_commit(plan, %{}, reason)
          {:error, reason, created} -> abort_pair_commit(plan, created, reason)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Releases an exact precommit reservation."
  def release_reservation(call_id, generation),
    do: GenServer.call(@server_name, {:release_reservation, call_id, generation})

  @doc "Marks the irreversible commit boundary; expiry can no longer undo it."
  def mark_commit_started(call_id, generation),
    do: GenServer.call(@server_name, {:mark_commit_started, call_id, generation})

  @doc "Transfers charged reservation slots to active Call accounting once prior Voice ends."
  def activate_reservation(call_id, generation),
    do: GenServer.call(@server_name, {:activate_reservation, call_id, generation})

  @doc "Releases a committed claim after failed pair setup without restoring prior Voice."
  def release_committed_reservation(call_id, generation),
    do: GenServer.call(@server_name, {:release_committed_reservation, call_id, generation})

  @doc "Releases an exact active Call's accounting after pair cleanup."
  def release_active_call(call_id, generation),
    do: GenServer.call(@server_name, {:release_active_call, call_id, generation})

  @doc """
  Returns the exact precommit reservation generation for one Call ID.

  The pair-admission accept flow reserves before the durable connecting
  commit, then the runtime adapter commits with that exact generation.
  Returns `{:ok, generation}` while the precommit reservation is held,
  otherwise `{:error, :not_found}`. Observes only; never creates state.
  """
  @spec reservation_generation(Ecto.UUID.t()) :: {:ok, reference()} | {:error, :not_found}
  def reservation_generation(call_id),
    do: GenServer.call(@server_name, {:reservation_generation, call_id})

  @doc """
  Idempotently cleans a published pair for one Call ID, if present.

  Looks up the exact active-call generation and runs the idempotent
  `cleanup_active_pair/2` path. When coherence already cleared the active
  pair (target/session failure), drops any remaining stale target claim so
  explicit terminal cleanup frees resources. Returns `:ok` when no active
  pair or stale target exists. Never restores Voice.
  """
  @spec cleanup_active_pair_for_call(Ecto.UUID.t()) :: :ok | {:error, :cleanup_failed}
  def cleanup_active_pair_for_call(call_id) do
    started_ms = System.monotonic_time(:millisecond)

    settled? =
      case call_target_snapshot(call_id) do
        %{transport: :real} -> is_nil(Calls.get_nonterminal_attempt(call_id))
        _ -> false
      end

    real_result =
      GenServer.call(@server_name, {:real_terminal_cleanup, call_id, settled?}, :infinity)

    result =
      if real_result == :not_real do
        :ok = GenServer.call(@server_name, {:settle_pair_operation, call_id}, :infinity)

        case GenServer.call(@server_name, {:active_pair_generation, call_id}) do
          {:ok, generation} -> cleanup_active_pair(call_id, generation)
          {:error, :not_found} -> cleanup_stale_target(call_id)
        end
      else
        real_result
      end

    _ = emit_admission("cleanup_active_pair_for_call", result, started_ms)
    result
  end

  # Called only after scoped authorization accepts a terminal trigger. The cast
  # stamps the clock before durable settlement and never waits inside a DB lock.
  def begin_terminal_cleanup(call_id, generation \\ nil) do
    GenServer.cast(
      @server_name,
      {:real_terminal_trigger, call_id, generation, System.monotonic_time(:millisecond)}
    )
  end

  defp cleanup_stale_target(call_id) do
    case GenServer.call(
           @server_name,
           {:begin_stale_target_cleanup, call_id},
           @pair_step_timeout_ms
         ) do
      {:ok, %{target_pid: target_pid, runtime_generation: generation}} when is_pid(target_pid) ->
        _ = DirectCallTarget.shutdown(target_pid)
        :ok = GenServer.call(@server_name, {:finish_stale_target_cleanup, call_id, generation})
        :ok

      {:ok, %{target_pid: _dead_or_nil, runtime_generation: generation}} ->
        :ok = GenServer.call(@server_name, {:finish_stale_target_cleanup, call_id, generation})
        :ok

      {:error, :no_stale_target} ->
        :ok
    end
  end

  @doc """
  Idempotently cleans a published pair after postcommit failure or terminal leave.

  Removes both exact per-User Direct Call indexes, both target Sessions, the
  target runtime claim, and the charged slots. Never restores Voice. Repeated
  calls and late cleanups for an old Call ID are harmless and return `:ok`.
  """
  @spec cleanup_active_pair(Ecto.UUID.t(), reference()) :: :ok
  def cleanup_active_pair(call_id, generation) do
    started_ms = System.monotonic_time(:millisecond)

    result =
      case call_target_snapshot(call_id) do
        %{transport: :real} ->
          case GenServer.call(@server_name, {:active_pair_generation, call_id}) do
            {:ok, ^generation} -> cleanup_active_pair_for_call(call_id)
            _ -> :ok
          end

        _ ->
          do_cleanup_active_pair(call_id, generation)
      end

    _ = emit_admission("cleanup_active_pair", result, started_ms)
    result
  end

  defp do_cleanup_active_pair(call_id, generation) do
    target_to_stop =
      case GenServer.call(
             @server_name,
             {:begin_pair_cleanup, call_id, generation},
             @pair_step_timeout_ms
           ) do
        {:ok, %{target_pid: target_pid, sessions: sessions}} ->
          %{target_pid: target_pid, sessions: sessions}

        {:error, :stale_call} ->
          nil
      end

    case target_to_stop do
      nil ->
        :ok

      %{target_pid: target_pid, sessions: sessions} when is_pid(target_pid) ->
        Enum.each(sessions, fn {session_id, user_id} ->
          _ = DirectCallTarget.remove(target_pid, user_id, session_id)
        end)

        _ = DirectCallTarget.shutdown(target_pid)
        :ok = GenServer.call(@server_name, {:finish_pair_cleanup, call_id, generation})
        :ok

      %{sessions: _sessions} ->
        :ok = GenServer.call(@server_name, {:finish_pair_cleanup, call_id, generation})
        :ok
    end
  end

  @doc false
  @spec await_ready() :: :ok | {:error, :recovery_timeout}
  def await_ready, do: GenServer.call(@server_name, :await_ready, :infinity)

  @doc false
  @spec room_server_started(Ecto.UUID.t(), pid()) :: :ok
  def room_server_started(voice_channel_id, room_server) do
    GenServer.cast(@server_name, {:room_server_started, voice_channel_id, room_server})
  end

  @doc false
  @spec forwarder_started(Ecto.UUID.t(), pid(), pid() | nil) :: :ok
  def forwarder_started(voice_channel_id, forwarder, room_server) do
    GenServer.cast(@server_name, {:forwarder_started, voice_channel_id, forwarder, room_server})
  end

  @spec session_removed(Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t(), pid()) :: :ok
  def session_removed(voice_channel_id, user_id, voice_session_id, room_server) do
    GenServer.cast(
      @server_name,
      {:session_removed, Target.voice_channel(voice_channel_id), user_id, voice_session_id,
       room_server}
    )
  end

  @doc "Returns the fake Direct Call target's exact runtime and Session report."
  def call_target_snapshot(call_id),
    do: GenServer.call(@server_name, {:call_target_snapshot, call_id})

  @doc "Returns the exact resource-root identity, retained through target loss until cleanup."
  @spec call_target_runtime_identity(Ecto.UUID.t()) ::
          map() | nil | {:error, :recovering | :recovery_timeout | :unavailable}
  def call_target_runtime_identity(call_id) do
    GenServer.call(@server_name, {:call_target_runtime_identity, call_id})
  catch
    :exit, _unavailable -> {:error, :unavailable}
  end

  @doc false
  def call_target_starting(call_id, generation),
    do: GenServer.call(@server_name, {:call_target_starting, call_id, generation})

  @doc false
  def call_target_ready(
        call_id,
        generation,
        target_pid,
        profile \\ Profile.direct_call(),
        transport \\ :fake
      ),
      do:
        GenServer.call(
          @server_name,
          {:call_target_ready, call_id, generation, target_pid, profile, transport}
        )

  @doc false
  def call_target_start_failed(call_id, generation, reason),
    do: GenServer.call(@server_name, {:call_target_start_failed, call_id, generation, reason})

  @doc false
  def claim_call_target_start(call_id, generation),
    do: GenServer.call(@server_name, {:claim_call_target_start, call_id, generation})

  @doc false
  def begin_call_target_start_cleanup(call_id, generation),
    do: GenServer.call(@server_name, {:begin_call_target_start_cleanup, call_id, generation})

  @doc false
  def call_target_start_cancelled(call_id, generation),
    do: GenServer.cast(@server_name, {:call_target_start_cancelled, call_id, generation})

  @doc false
  def call_target_failed(call_id, generation, reason),
    do: GenServer.call(@server_name, {:call_target_failed, call_id, generation, reason})

  @doc false
  def call_session_started(call_id, generation, user_id, session_id, resources \\ []),
    do:
      GenServer.call(
        @server_name,
        {:call_session_started, call_id, generation, user_id, session_id, resources}
      )

  @doc false
  def call_session_removed(call_id, generation, user_id, session_id),
    do:
      GenServer.call(
        @server_name,
        {:call_session_removed, call_id, generation, user_id, session_id}
      )

  @doc false
  def call_session_failed(call_id, generation, user_id, session_id, reason),
    do:
      GenServer.call(
        @server_name,
        {:call_session_failed, call_id, generation, user_id, session_id, reason}
      )

  @doc false
  def call_target_stopped(call_id, generation),
    do: GenServer.call(@server_name, {:call_target_stopped, call_id, generation})

  @impl true
  def init(:ok) do
    room_servers = Voice.running_room_servers()
    recovery_pending = MapSet.new(room_servers, fn {_voice_channel_id, pid} -> pid end)

    state = %{
      recovery_status: :recovering,
      active_by_user: %{},
      reservation: nil,
      real_cleanup: nil,
      pair_operation: nil,
      pair_operation_result: nil,
      active_call: nil,
      voice_switches: %{},
      call_targets: %{},
      call_target_starts: %{},
      runtimes_by_target: %{},
      monitors: %{},
      recovery_pending: recovery_pending,
      recovery_calls_pending: MapSet.new(),
      recovery_worker: nil,
      recovery_waiters: [],
      recovery_timer: recovery_timer(:recovering)
    }

    state =
      Enum.reduce(room_servers, state, fn {voice_channel_id, room_server}, state ->
        track_room_server(state, voice_channel_id, room_server)
      end)

    Enum.each(room_servers, fn {_voice_channel_id, room_server} ->
      RoomServer.shutdown(room_server)
    end)

    # Target shutdown calls back into this coordinator; teardown and durable
    # settlement must run outside its mailbox. Runtime DOWN alone cannot open
    # admission: every captured Call also needs confirmed durable settlement.
    state = state |> DiscordClone.Media.CallCleanupLedger.restore() |> start_recovery_worker()

    {:ok, state}
  end

  defp start_recovery_worker(state) do
    owner = self()
    token = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        owner_monitor = Process.monitor(owner)
        # Enumeration can also wait for a target supervisor starting a child
        # that calls us. Neither enumeration nor identity runs in our mailbox.
        targets = running_call_targets()
        {:ok, targets} = GenServer.call(owner, {:recovery_targets_discovered, token, targets})

        Enum.each(targets, fn {pid, _call_id, _generation} ->
          try_direct_call_target_shutdown(pid)
        end)

        call_ids = targets |> Enum.map(&elem(&1, 1)) |> Enum.uniq()
        settle_recovery_calls(owner, owner_monitor, token, call_ids)
      end)

    %{state | recovery_worker: %{pid: pid, monitor: monitor, token: token}}
  end

  defp settle_recovery_calls(owner, owner_monitor, token, call_ids) do
    pending =
      Enum.reject(call_ids, fn call_id ->
        if recovery_call_settled?(call_id) do
          send(owner, {:recovery_call_settled, token, call_id})
          true
        else
          false
        end
      end)

    if pending != [] do
      receive do
        {:DOWN, ^owner_monitor, :process, ^owner, _reason} -> :ok
      after
        100 -> settle_recovery_calls(owner, owner_monitor, token, pending)
      end
    end
  end

  defp recovery_call_settled?(call_id) do
    recovery_settlement_barrier(call_id)

    case Calls.interrupt_call_for_coordinator_restart(call_id) do
      {:ok, _terminal} -> true
      # A confirmed ringing or missing attempt has no accepted Call to settle.
      {:error, reason} when reason in [:stale, :not_found] -> true
      {:error, _unavailable} -> false
    end
  rescue
    _error in [Postgrex.Error, DBConnection.ConnectionError, Ecto.ConstraintError] -> false
  end

  # Inert by default. Tests control the DB-failure boundary after exact old
  # runtime teardown, outside the coordinator mailbox.
  defp recovery_settlement_barrier(call_id) do
    case Application.get_env(:discord_clone, :recovery_settlement_barrier) do
      barrier when is_function(barrier, 1) -> barrier.(call_id)
      _ -> :ok
    end
  end

  # Generalized restart reconciliation: retire surviving fake Direct Call
  # target trees under exact runtime identity before reporting ready.
  # Decision per tree: always retire (never re-adopt). The crashed epoch's
  # reservation/active/switch memory is lost, so re-adopting would guess
  # capacity from an empty map. Retiring forces fail-closed `interrupted`
  # settlement via Calls and exact slot accounting after recovery.
  defp running_call_targets do
    DiscordClone.Media.DirectCallTargetSupervisor
    |> DynamicSupervisor.which_children()
    |> Enum.flat_map(fn
      {_, pid, _, _} when is_pid(pid) -> [pid]
      _ -> []
    end)
    |> Enum.map(fn pid ->
      # A missing identity is uncertainty, even if the target subsequently
      # dies: its durable Call still needs settlement. Fail the owned worker
      # rather than treating an unknown Call as an empty successful recovery.
      case try_direct_call_target_identity(pid) do
        {:ok, %{call_id: call_id, runtime_generation: generation}}
        when is_binary(call_id) and is_reference(generation) ->
          {pid, call_id, generation}

        _unknown ->
          exit(:recovery_identity_unavailable)
      end
    end)
  end

  defp try_direct_call_target_identity(target_pid) do
    DiscordClone.Media.DirectCallTarget.identity(target_pid)
  catch
    :exit, _ -> {:error, :unavailable}
  end

  defp try_direct_call_target_shutdown(target_pid) do
    DiscordClone.Media.DirectCallTarget.shutdown(target_pid)
  catch
    :exit, _ -> :ok
  end

  defp track_recovery_call_target(state, target_pid, call_id, generation) do
    monitor = Process.monitor(target_pid)

    component = %{
      target: :recovery,
      component: :recovery_call_target,
      pid: target_pid,
      monitor: monitor,
      room_server_pid: nil,
      runtime_generation: generation,
      call_id: call_id
    }

    %{state | monitors: Map.put(state.monitors, monitor, component)}
  end

  @impl true
  def handle_call(
        {:recovery_targets_discovered, token, targets},
        {worker, _tag},
        %{recovery_status: :recovering, recovery_worker: %{pid: worker, token: token}} = state
      ) do
    # Discovery may be delayed behind startup in the target supervisor. A
    # target whose exact readiness this coordinator already owns belongs to
    # the new epoch; recovery must only retire captured older generations.
    targets =
      Enum.reject(targets, fn {pid, call_id, generation} ->
        match?(
          %{target_pid: ^pid, runtime_generation: ^generation},
          Map.get(state.call_targets, call_id)
        )
      end)

    state =
      Enum.reduce(targets, state, fn {pid, call_id, generation}, state ->
        state
        |> track_recovery_call_target(pid, call_id, generation)
        |> update_in([:recovery_pending], &MapSet.put(&1, pid))
        |> update_in([:recovery_calls_pending], &MapSet.put(&1, call_id))
      end)

    {:reply, {:ok, targets}, state}
  end

  def handle_call({:recovery_targets_discovered, _token, _targets}, _from, state),
    do: {:reply, {:error, :stale_recovery}, state}

  def handle_call(:await_ready, from, %{recovery_status: :recovering} = state) do
    {:noreply, %{state | recovery_waiters: [from | state.recovery_waiters]}}
  end

  def handle_call(:await_ready, _from, %{recovery_status: :recovery_failed} = state),
    do: {:reply, {:error, :recovery_timeout}, state}

  def handle_call(:await_ready, _from, state), do: {:reply, :ok, state}

  def handle_call(:admission_gauges, _from, state) do
    gauges = %{
      occupancy: occupied_slots(state),
      reservation_count: reservation_ledger_count(state),
      held_switch_count: map_size(state.voice_switches)
    }

    {:reply, gauges, state}
  end

  def handle_call({:current_identity, user_id}, _from, state) do
    {:reply, current_identity(state, user_id), state}
  end

  def handle_call({:call_media_session, call_id, user_id}, _from, state) do
    result =
      with nil <- state.real_cleanup,
           %{call_id: ^call_id} <- state.active_call,
           %{target: %Target{kind: :direct_call, id: ^call_id}, runtime_generation: generation} =
             identity <- current_identity(state, user_id),
           %{status: :ready, transport: :real, runtime_generation: ^generation, target_pid: pid} <-
             Map.get(state.call_targets, call_id) do
        {:ok, identity, pid}
      else
        _ -> {:error, :not_admitted}
      end

    {:reply, result, state}
  end

  def handle_call({:call_activation_deadline, call_id, generation}, _from, state) do
    result =
      case state.active_call do
        %{
          call_id: ^call_id,
          target_runtime_generation: ^generation,
          connect_deadline: deadline,
          connection_states: statuses
        }
        when is_nil(state.real_cleanup) ->
          if both_call_sides_connected?(statuses),
            do: {:ok, deadline},
            else: {:error, :stale}

        _ ->
          {:error, :stale}
      end

    {:reply, result, state}
  end

  def handle_call({:call_activated, call_id, generation}, _from, state) do
    case state.active_call do
      %{call_id: ^call_id, target_runtime_generation: ^generation} = pair
      when is_nil(state.real_cleanup) ->
        if both_call_sides_connected?(pair.connection_states) and
             System.monotonic_time(:millisecond) < pair.connect_deadline do
          if pair.connect_timer, do: Process.cancel_timer(pair.connect_timer)
          {:reply, :ok, %{state | active_call: %{pair | activated?: true, connect_timer: nil}}}
        else
          {:reply, {:error, :stale}, state}
        end

      _ ->
        {:reply, {:error, :stale}, state}
    end
  end

  def handle_call({:call_target_snapshot, call_id}, _from, state) do
    snapshot =
      case Map.get(state.call_targets, call_id) do
        nil -> nil
        target -> Map.drop(target, [:target_pid, :monitor, :resources, :runtime_identity])
      end

    {:reply, snapshot, state}
  end

  def handle_call({:call_target_runtime_identity, call_id}, _from, state) do
    result =
      with :ok <- recovery_ready?(state) do
        state.call_targets |> Map.get(call_id, %{}) |> Map.get(:runtime_identity)
      end

    # Recovery owns interrupted settlement and its fail-closed ledger. A new
    # coordinator's empty target map is not confirmation of completed cleanup.
    {:reply, result, state}
  end

  def handle_call({:claim_call_target_start, call_id, generation}, _from, state) do
    # Target lifecycle callbacks remain available during recovery. Admission
    # itself is still gated by reserve_pair/3, including replacement targets.
    case {Map.get(state.call_target_starts, call_id), Map.get(state.call_targets, call_id)} do
      {nil, %{status: :ready, target_pid: pid}} when is_pid(pid) ->
        {:reply, {:ok, pid}, state}

      {nil, nil} ->
        {:reply, :ok, put_in(state, [:call_target_starts, call_id], generation)}

      _ ->
        {:reply, {:error, :temporarily_unavailable}, state}
    end
  end

  def handle_call({:begin_call_target_start_cleanup, call_id, generation}, _from, state) do
    target = Map.get(state.call_targets, call_id)

    cond do
      call_target_start_in_use?(state, call_id, generation) ->
        {:reply, {:error, :in_use}, state}

      Map.get(state.call_target_starts, call_id) == generation or
          match?(
            %{runtime_generation: ^generation, sessions: sessions} when map_size(sessions) == 0,
            target
          ) ->
        state =
          state
          |> update_call_target(call_id, generation, &%{&1 | status: :startup_cleaning})
          |> put_in([:call_target_starts, call_id], {:cleaning, generation})

        {:reply, :ok, state}

      true ->
        {:reply, {:error, :stale_runtime}, state}
    end
  end

  def handle_call({:call_target_starting, call_id, generation}, _from, state) do
    {:reply, :ok, put_in(state, [:call_target_starts, call_id], generation)}
  end

  def handle_call(
        {:call_target_ready, call_id, generation, target_pid, profile, transport},
        _from,
        state
      ) do
    if Map.get(state.call_target_starts, call_id) == generation do
      state =
        state
        |> update_in([:call_target_starts], &Map.delete(&1, call_id))
        |> replace_call_target(call_id, generation, target_pid, profile, transport)

      {:reply, :ok, state}
    else
      {:reply, {:error, :stale_runtime}, state}
    end
  end

  def handle_call({:call_target_start_failed, call_id, generation, reason}, _from, state) do
    target = %{
      call_id: call_id,
      runtime_generation: generation,
      target_pid: nil,
      monitor: nil,
      status: :failed,
      sessions: %{},
      failure: %{kind: :startup, reason: reason}
    }

    state =
      if Map.get(state.call_target_starts, call_id) == generation do
        state
        |> update_in([:call_target_starts], &Map.delete(&1, call_id))
        |> update_in([:call_targets], &Map.put_new(&1, call_id, target))
      else
        state
      end

    {:reply, :ok, state}
  end

  def handle_call({:call_target_failed, call_id, generation, reason}, _from, state) do
    case Map.get(state.call_targets, call_id) do
      %{runtime_generation: ^generation} ->
        state =
          update_call_target(state, call_id, generation, fn target ->
            %{target | status: :failed, failure: %{kind: :target, reason: reason}}
          end)

        state = clear_active_pair_for_target(state, call_id, generation)
        _ = notify_media_failed(call_id, reason)

        {:reply, :ok, state}

      _stale_or_missing ->
        {:reply, :ok, state}
    end
  end

  def handle_call(
        {:call_session_started, call_id, generation, _user_id, _session_id, _resources},
        _from,
        %{real_cleanup: %{call_id: call_id, generation: generation}} = state
      ),
      do: {:reply, {:error, :stale_runtime}, state}

  def handle_call(
        {:call_session_started, call_id, generation, user_id, session_id, resources},
        _from,
        state
      ) do
    state =
      update_call_target(state, call_id, generation, fn target ->
        target
        |> put_in([:sessions, session_id], user_id)
        |> Map.update(:resources, resources, &Enum.uniq(&1 ++ resources))
      end)

    {:reply, :ok, state}
  end

  def handle_call({:call_session_removed, call_id, generation, user_id, session_id}, _from, state) do
    state =
      update_exact_call_session(state, call_id, generation, user_id, session_id, fn target ->
        update_in(target, [:sessions], &Map.delete(&1, session_id))
      end)

    # No media-failed notification here: explicit `DirectCallTarget.remove/3`
    # is only called from `cleanup_active_pair/2` (and tests). The durable
    # terminal is already committed by the cleanup caller; notifying would
    # race the in-progress cleanup with a spurious `failed` commit.
    state =
      if exact_published_session?(state, call_id, generation, user_id, session_id) do
        clear_active_pair_for_target(state, call_id, generation)
      else
        state
      end

    {:reply, :ok, state}
  end

  def handle_call(
        {:call_session_failed, call_id, generation, user_id, session_id, reason},
        _from,
        state
      ) do
    case Map.get(state.call_targets, call_id) do
      %{runtime_generation: ^generation, sessions: %{^session_id => ^user_id}} ->
        state =
          update_exact_call_session(state, call_id, generation, user_id, session_id, fn target ->
            target
            |> update_in([:sessions], &Map.delete(&1, session_id))
            |> Map.merge(%{
              status: :failed,
              failure: %{
                kind: :session,
                user_id: user_id,
                call_session_id: session_id,
                reason: reason
              }
            })
          end)

        state = clear_active_pair_for_target(state, call_id, generation)
        _ = notify_media_failed(call_id, reason)

        {:reply, :ok, state}

      _stale_or_missing ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:call_target_stopped, call_id, generation}, _from, state) do
    state =
      update_call_target(state, call_id, generation, fn target ->
        %{target | status: :stopped, sessions: %{}}
      end)

    state = clear_active_pair_for_target(state, call_id, generation)

    {:reply, :ok, state}
  end

  def handle_call({:reserve_pair, call_id, first, second}, _from, state) do
    with :ok <- reservation_ready?(state, call_id),
         :ok <- valid_pair?(first, second),
         {:ok, _target} <- vacant_call_target(state, call_id),
         :ok <- exact_prior?(state, first),
         :ok <- exact_prior?(state, second),
         :ok <- projected_capacity_available?(state, first, second) do
      generation = make_ref()
      expires_at = System.monotonic_time(:millisecond) + @reservation_ttl_ms

      timer =
        Process.send_after(
          self(),
          {:reservation_expired, call_id, generation},
          @reservation_ttl_ms
        )

      {first_user_id, first_prior} = first
      {second_user_id, second_prior} = second

      reservation = %{
        call_id: call_id,
        user_ids: [first_user_id, second_user_id],
        prior_identities: %{first_user_id => first_prior, second_user_id => second_prior},
        slots: 2,
        expires_at: expires_at,
        generation: generation,
        phase: :precommit,
        timer: timer
      }

      {:reply, {:ok, Map.delete(reservation, :timer)}, %{state | reservation: reservation}}
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:release_reservation, call_id, generation}, _from, state) do
    case state.reservation do
      %{call_id: ^call_id, generation: ^generation, phase: :precommit, timer: timer} ->
        Process.cancel_timer(timer)
        {:reply, :ok, %{state | reservation: nil}}

      _ ->
        {:reply, {:error, :stale_reservation}, state}
    end
  end

  def handle_call({:mark_commit_started, call_id, generation}, _from, state) do
    case state.reservation do
      %{call_id: ^call_id, generation: ^generation, phase: :precommit, timer: timer} = reservation ->
        Process.cancel_timer(timer)

        if expired_reservation?(reservation) do
          {:reply, {:error, :stale_reservation}, %{state | reservation: nil}}
        else
          {:reply, :ok, %{state | reservation: %{reservation | phase: :committing, timer: nil}}}
        end

      %{call_id: ^call_id, generation: ^generation, phase: :committing} ->
        {:reply, :ok, state}

      _ ->
        {:reply, {:error, :stale_reservation}, state}
    end
  end

  def handle_call({:begin_pair_commit, call_id, generation}, {worker, _tag}, state) do
    case state.reservation do
      %{call_id: ^call_id, generation: ^generation, phase: :precommit} = reservation ->
        if expired_reservation?(reservation) do
          {:reply, {:error, :stale_reservation}, %{state | reservation: nil}}
        else
          case begin_pair_commit_plan(state, reservation) do
            {:ok, plan} ->
              Process.cancel_timer(reservation.timer)
              reservation = %{reservation | phase: :committing, timer: nil}
              monitor = Process.monitor(worker)

              timer =
                Process.send_after(
                  self(),
                  {:pair_operation_expired, generation},
                  min(
                    pair_operation_timeout(:connect_ms, @reservation_ttl_ms),
                    max(reservation.expires_at - System.monotonic_time(:millisecond), 0)
                  )
                )

              operation = %{
                plan: plan,
                worker: worker,
                monitor: monitor,
                timer: timer,
                phase: :committing,
                waiters: [],
                result_waiters: [],
                original_worker: worker,
                started_at: System.monotonic_time(:millisecond)
              }

              {:reply, {:ok, plan},
               %{state | reservation: reservation, pair_operation: operation}}

            {:error, reason} ->
              {:reply, {:error, reason}, state}
          end
        end

      _ ->
        {:reply, {:error, :stale_reservation}, state}
    end
  end

  def handle_call(
        {:publish_pair_commit, call_id, generation, target_runtime_generation, sessions},
        _from,
        state
      ) do
    case state.reservation do
      %{call_id: ^call_id, generation: ^generation, phase: :committing} = reservation ->
        case exact_pair_target(
               state,
               call_id,
               target_runtime_generation,
               reservation.user_ids,
               sessions
             ) do
          {:ok, target} ->
            state =
              state
              |> retire_reserved_priors(reservation)
              |> put_call_sessions(call_id, target, sessions)

            active_call = %{
              call_id: call_id,
              user_ids: reservation.user_ids,
              slots: 0,
              generation: generation,
              target_runtime_generation: target.generation,
              call_sessions: sessions,
              activated?: false,
              connection_states: %{},
              connect_deadline:
                state.pair_operation.started_at +
                  pair_operation_timeout(:connect_ms, @reservation_ttl_ms),
              connect_timer: nil
            }

            result = %{
              call_id: call_id,
              generation: generation,
              user_ids: reservation.user_ids,
              call_sessions: sessions,
              target_runtime_generation: target.generation
            }

            active_call =
              if Map.get(target, :transport) == :real do
                timer =
                  Process.send_after(
                    self(),
                    {:real_connect_expired, call_id, target.generation},
                    max(active_call.connect_deadline - System.monotonic_time(:millisecond), 0)
                  )

                room =
                  GenServer.whereis(
                    Target.runtime_name(Target.direct_call(call_id), target.generation, :room)
                  )

                GenServer.cast(room, :publish_readiness)
                %{active_call | connect_timer: timer}
              else
                active_call
              end

            # Publish the exact admitted resource root, never a startup claim.
            # CallServer observes it directly; this coordinator retains all
            # capacity and teardown authority. Send before exposing the pair.
            notify_call_server(
              call_id,
              {:call_media_runtime, call_id, target.generation, target.pid}
            )

            {:reply, {:ok, result},
             %{clear_pair_operation(state) | reservation: nil, active_call: active_call}}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      _ ->
        {:reply, {:error, :stale_reservation}, state}
    end
  end

  def handle_call({:activate_reservation, call_id, generation}, _from, state) do
    case state.reservation do
      %{call_id: ^call_id, generation: ^generation, phase: :committing} = reservation ->
        if credited_slots(state, reservation) == 0 do
          active_call = Map.take(reservation, [:call_id, :user_ids, :slots, :generation])
          {:reply, :ok, %{state | reservation: nil, active_call: active_call}}
        else
          {:reply, {:error, :prior_sessions_active}, state}
        end

      _ ->
        {:reply, {:error, :stale_reservation}, state}
    end
  end

  def handle_call({:release_committed_reservation, call_id, generation}, _from, state) do
    case state.reservation do
      %{call_id: ^call_id, generation: ^generation, phase: :committing} ->
        {:reply, :ok, %{state | reservation: nil}}

      _ ->
        {:reply, {:error, :stale_reservation}, state}
    end
  end

  def handle_call({:finish_pair_abort, call_id, generation, target_generation}, _from, state) do
    case state.reservation do
      %{call_id: ^call_id, generation: ^generation, phase: :cleaning} ->
        {:reply, :ok, state}

      %{call_id: ^call_id, generation: ^generation, phase: :committing} = reservation ->
        remaining =
          case Map.get(state.call_targets, call_id) do
            %{runtime_generation: ^target_generation, sessions: sessions} -> sessions
            _stale_or_missing -> %{}
          end

        claim =
          if map_size(remaining) > 0 do
            %{
              call_id: call_id,
              generation: generation,
              user_ids: reservation.user_ids,
              target_runtime_generation: target_generation,
              call_sessions:
                Map.new(remaining, fn {session_id, user_id} -> {user_id, session_id} end),
              slots: map_size(remaining),
              cleaning?: true
            }
          end

        {:reply, :ok, %{clear_pair_operation(state) | reservation: nil, active_call: claim}}

      _stale_or_released ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:pair_worker_result, worker}, from, state) do
    case state.pair_operation do
      %{original_worker: ^worker} ->
        state = begin_operation_cleanup(state)

        if state.pair_operation do
          {:noreply, update_in(state.pair_operation.result_waiters, &[from | &1])}
        else
          {:reply, {:error, :unavailable}, state}
        end

      _ ->
        result =
          case state.pair_operation_result do
            {^worker, result} -> result
            _ -> {:error, :unavailable}
          end

        {:reply, result, state}
    end
  end

  def handle_call({:real_terminal_cleanup, call_id, settled?}, from, state) do
    state = start_real_cleanup(state, call_id, System.monotonic_time(:millisecond))

    case state.real_cleanup do
      %{call_id: ^call_id, failed?: true} ->
        {:reply, {:error, :cleanup_failed}, state}

      %{call_id: ^call_id} = cleanup ->
        cleanup = %{
          cleanup
          | settled?: cleanup.settled? or settled?,
            waiters: [from | cleanup.waiters]
        }

        {:noreply, finish_real_cleanup(%{state | real_cleanup: cleanup})}

      _ ->
        {:reply, :not_real, state}
    end
  end

  def handle_call({:settle_pair_operation, call_id}, from, state) do
    case state.pair_operation do
      %{plan: %{call_id: ^call_id}} ->
        state = begin_operation_cleanup(state)
        {:noreply, update_in(state.pair_operation.waiters, &[from | &1])}

      _ ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:release_active_call, call_id, generation}, _from, state) do
    case state.active_call do
      %{call_id: ^call_id, generation: ^generation} ->
        {:reply, :ok, %{state | active_call: nil}}

      _ ->
        {:reply, {:error, :stale_call}, state}
    end
  end

  def handle_call({:reservation_generation, call_id}, _from, state) do
    case state.reservation do
      %{call_id: ^call_id, generation: generation, phase: :precommit} ->
        {:reply, {:ok, generation}, state}

      %{call_id: ^call_id, generation: generation, phase: :committing} ->
        {:reply, {:ok, generation}, state}

      _ ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:begin_voice_switch, user_id, voice_channel_id}, _from, state) do
    case recovery_ready?(state) do
      :ok ->
        cond do
          pair_pinned?(state, user_id) ->
            {:reply, {:error, %{reason: :reservation_conflict}}, state}

          Map.has_key?(state.voice_switches, user_id) ->
            {:reply, {:error, %{reason: :reservation_conflict}}, state}

          true ->
            prepare_voice_switch_for_active_call(state, user_id, voice_channel_id)
        end

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  def handle_call(
        {:reserve_voice_switch, user_id, voice_channel_id, candidate, occupancy},
        _from,
        state
      ) do
    with :ok <- recovery_ready?(state),
         false <- pair_pinned?(state, user_id),
         true <- state.active_call == candidate.active_call do
      begin_voice_switch_with_active_call(state, user_id, voice_channel_id, candidate, occupancy)
    else
      {:error, _reason} = error -> {:reply, error, state}
      _ -> {:reply, {:error, %{reason: :reservation_conflict}}, state}
    end
  end

  def handle_call({:abort_voice_switch, user_id, generation}, _from, state) do
    case Map.get(state.voice_switches, user_id) do
      %{generation: ^generation, timer: timer} ->
        Process.cancel_timer(timer)
        {:reply, :ok, %{state | voice_switches: Map.delete(state.voice_switches, user_id)}}

      _ ->
        {:reply, :ok, state}
    end
  end

  def handle_call(
        {:publish_voice_switch, user_id, generation, voice_channel_id, signaling_session_id,
         join_result, room_server},
        _from,
        state
      ) do
    case Map.get(state.voice_switches, user_id) do
      %{generation: ^generation, voice_channel_id: ^voice_channel_id, timer: timer} ->
        case Map.get(state.active_by_user, user_id) do
          nil ->
            state =
              put_session(
                state,
                voice_channel_id,
                user_id,
                signaling_session_id,
                join_result,
                room_server
              )

            Process.cancel_timer(timer)
            state = %{state | voice_switches: Map.delete(state.voice_switches, user_id)}
            {:reply, {:ok, join_result}, state}

          _existing ->
            {:reply, {:error, :stale_switch}, state}
        end

      _ ->
        {:reply, {:error, :stale_switch}, state}
    end
  end

  def handle_call({:active_pair_generation, call_id}, _from, state) do
    case state.active_call do
      %{call_id: ^call_id, generation: generation} ->
        {:reply, {:ok, generation}, state}

      _ ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:begin_pair_cleanup, call_id, generation}, _from, state) do
    case state.active_call do
      %{
        call_id: ^call_id,
        generation: ^generation,
        target_runtime_generation: target_generation,
        call_sessions: call_sessions
      } = active_call ->
        target = Map.get(state.call_targets, call_id)

        {target_pid, sessions} =
          case target do
            %{runtime_generation: ^target_generation, target_pid: pid, sessions: target_sessions}
            when is_pid(pid) ->
              {pid, target_sessions}

            %{runtime_generation: ^target_generation, sessions: target_sessions} ->
              {nil, target_sessions}

            _stale_or_missing ->
              inverted =
                Map.new(call_sessions, fn {user_id, session_id} -> {session_id, user_id} end)

              {nil, inverted}
          end

        # Guard stays held until finish; slow target work runs outside the mailbox.
        state = %{state | active_call: Map.put(active_call, :cleaning?, true)}
        {:reply, {:ok, %{target_pid: target_pid, sessions: sessions}}, state}

      %{call_id: ^call_id, generation: ^generation} ->
        # Ticket 03 accounting seam: no target Sessions were ever published.
        {:reply, {:ok, %{target_pid: nil, sessions: %{}}}, state}

      _ ->
        {:reply, {:error, :stale_call}, state}
    end
  end

  def handle_call({:finish_pair_cleanup, call_id, generation}, _from, state) do
    case state.active_call do
      %{
        call_id: ^call_id,
        generation: ^generation,
        target_runtime_generation: target_generation,
        call_sessions: call_sessions
      } ->
        state =
          case Map.get(state.call_targets, call_id) do
            %{runtime_generation: ^target_generation, sessions: sessions}
            when map_size(sessions) == 0 ->
              state
              |> clear_published_pair(call_id, target_generation, call_sessions)
              |> drop_call_target(call_id, target_generation)
              |> Map.put(:active_call, nil)

            _unconfirmed ->
              state
          end

        {:reply, :ok, state}

      %{call_id: ^call_id, generation: ^generation} ->
        {:reply, :ok, %{state | active_call: nil}}

      _ ->
        # A late finish owns no current claim, including a replacement runtime
        # for the same Call ID.
        {:reply, :ok, state}
    end
  end

  def handle_call({:begin_stale_target_cleanup, call_id}, _from, state) do
    # The active pair already cleared (or never existed); only a leftover
    # failed/stopped target claim for this Call ID may remain. Capture its
    # generation so a late finish cannot drop a replacement runtime. If an
    # active pair exists for this Call ID, the active path owns it.
    case state.active_call do
      %{call_id: ^call_id} ->
        {:reply, {:error, :no_stale_target}, state}

      _ ->
        case Map.get(state.call_targets, call_id) do
          %{target_pid: target_pid, runtime_generation: generation} ->
            {:reply, {:ok, %{target_pid: target_pid, runtime_generation: generation}}, state}

          nil ->
            {:reply, {:error, :no_stale_target}, state}
        end
    end
  end

  def handle_call({:finish_stale_target_cleanup, call_id, generation}, _from, state),
    do: {:reply, :ok, drop_call_target(state, call_id, generation)}

  def handle_call(
        {:join, _voice_channel_id, _user_id, _signaling_session_id, _signaling_channel,
         _server_ice_projection},
        _from,
        %{recovery_status: :recovering} = state
      ) do
    {:reply, {:error, :recovering}, state}
  end

  def handle_call(
        {:join, _voice_channel_id, _user_id, _signaling_session_id, _signaling_channel,
         _server_ice_projection},
        _from,
        %{recovery_status: :recovery_failed} = state
      ) do
    {:reply, {:error, :recovery_timeout}, state}
  end

  def handle_call(
        {:join, voice_channel_id, user_id, signaling_session_id, signaling_channel,
         server_ice_projection},
        _from,
        state
      ) do
    if pinned?(state, user_id) do
      {:reply, {:error, %{reason: :reservation_conflict}}, state}
    else
      join_unpinned(
        state,
        voice_channel_id,
        user_id,
        signaling_session_id,
        signaling_channel,
        server_ice_projection
      )
    end
  end

  def handle_call({:leave, voice_channel_id, voice_session_id}, _from, state) do
    target = Target.voice_channel(voice_channel_id)

    expected =
      Enum.find_value(state.active_by_user, fn {_user_id, active} ->
        if active.target == target and active.session_id == voice_session_id, do: active
      end)

    :ok = Voice.leave_room(voice_channel_id, voice_session_id)

    {:reply, :ok, remove_exact_session(state, expected)}
  end

  def handle_call({:end_user_session, voice_channel_id, user_id}, _from, state) do
    state = end_user_session(state, voice_channel_id, user_id)
    {:reply, :ok, state}
  end

  def handle_call({:end_channel_sessions, voice_channel_id}, _from, state) do
    state = end_channel_sessions(state, voice_channel_id)
    {:reply, :ok, state}
  end

  defp join_unpinned(
         state,
         voice_channel_id,
         user_id,
         signaling_session_id,
         signaling_channel,
         server_ice_projection
       ) do
    case Map.get(state.active_by_user, user_id) do
      nil ->
        join_new_session(
          state,
          voice_channel_id,
          user_id,
          signaling_session_id,
          signaling_channel,
          server_ice_projection
        )

      %{
        target: %Target{kind: :voice_channel, id: ^voice_channel_id},
        signaling_session_id: ^signaling_session_id
      } ->
        join_existing_session(
          state,
          voice_channel_id,
          user_id,
          signaling_session_id,
          signaling_channel,
          server_ice_projection
        )

      current_session ->
        move_session(
          state,
          current_session,
          voice_channel_id,
          user_id,
          signaling_session_id,
          signaling_channel,
          server_ice_projection
        )
    end
  end

  @impl true
  def handle_cast({:call_transport_state, call_id, generation, room, statuses}, state) do
    state =
      with nil <- state.real_cleanup,
           %{call_id: ^call_id, target_runtime_generation: ^generation, call_sessions: sessions} <-
             state.active_call,
           %{status: :ready, transport: :real, runtime_generation: ^generation} <-
             Map.get(state.call_targets, call_id),
           ^room <-
             GenServer.whereis(
               Target.runtime_name(Target.direct_call(call_id), generation, :room)
             ),
           true <- Enum.sort(Map.keys(statuses)) == Enum.sort(Map.values(sessions)),
           [{server, _}] <- Registry.lookup(DiscordClone.Calls.CallRegistry, call_id) do
        send(server, {:call_transport_state, call_id, generation, statuses})
        put_in(state.active_call.connection_states, statuses)
      else
        _ -> state
      end

    {:noreply, state}
  end

  def handle_cast({:real_terminal_trigger, call_id, generation, observed_at}, state) do
    current = get_in(state.call_targets, [call_id, :runtime_generation])

    state =
      if generation == nil or generation == current,
        do: start_real_cleanup(state, call_id, observed_at),
        else: state

    {:noreply, state}
  end

  def handle_cast({:call_target_start_cancelled, call_id, generation}, state) do
    {:noreply, cancel_call_target_start(state, call_id, generation)}
  end

  def handle_cast({:room_server_started, voice_channel_id, room_server}, state) do
    if current_room_server?(voice_channel_id, room_server) do
      state = track_room_server(state, voice_channel_id, room_server)

      if state.recovery_status == :recovering do
        RoomServer.shutdown(room_server)
      end

      {:noreply, maybe_finish_recovery(state)}
    else
      {:noreply, state}
    end
  end

  def handle_cast(
        {:forwarder_started, voice_channel_id, forwarder, room_server},
        state
      ) do
    if current_room_server?(voice_channel_id, room_server) do
      state = track_forwarder(state, voice_channel_id, forwarder, room_server)
      {:noreply, maybe_finish_recovery(state)}
    else
      {:noreply, state}
    end
  end

  def handle_cast({:session_removed, target, user_id, session_id, room_server}, state) do
    generation = runtime_generation(state, target, room_server)
    {:noreply, remove_exact_session(state, user_id, target, session_id, generation)}
  end

  @impl true
  def handle_info(
        {:real_media_retired, token},
        %{real_cleanup: %{token: token} = cleanup} = state
      ) do
    {:noreply, finish_real_cleanup(%{state | real_cleanup: %{cleanup | media_gone?: true}})}
  end

  def handle_info(
        {:real_cleanup_expired, token},
        %{real_cleanup: %{token: token} = cleanup} = state
      ) do
    Enum.each(cleanup.waiters, &GenServer.reply(&1, {:error, :cleanup_failed}))
    {:noreply, %{state | real_cleanup: %{cleanup | failed?: true, waiters: []}}}
  end

  def handle_info({:real_connect_expired, call_id, generation}, state) do
    state =
      case state.active_call do
        %{call_id: ^call_id, target_runtime_generation: ^generation, activated?: false} ->
          notify_media_failed(call_id, :connect_timeout)
          start_real_cleanup(state, call_id, System.monotonic_time(:millisecond))

        _ ->
          state
      end

    {:noreply, state}
  end

  def handle_info({tag, _token}, state) when tag in [:real_media_retired, :real_cleanup_expired],
    do: {:noreply, state}

  def handle_info(:recovery_timeout, %{recovery_status: :recovering} = state) do
    {:noreply, fail_recovery(state)}
  end

  def handle_info(:recovery_timeout, state), do: {:noreply, state}

  def handle_info(
        {:recovery_call_settled, token, call_id},
        %{recovery_status: :recovering, recovery_worker: %{token: token}} = state
      ) do
    {:noreply,
     %{state | recovery_calls_pending: MapSet.delete(state.recovery_calls_pending, call_id)}}
  end

  def handle_info({:recovery_call_settled, _token, _call_id}, state), do: {:noreply, state}

  def handle_info({:pair_operation_expired, generation}, state) do
    case state.pair_operation do
      %{plan: %{generation: ^generation}, phase: :committing} ->
        {:noreply, begin_operation_cleanup(state)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:pair_operation_cleaned, generation}, state) do
    case state.pair_operation do
      %{plan: %{generation: ^generation} = plan, phase: :cleaning, waiters: waiters} = operation ->
        result = if waiters == [], do: {:error, :unavailable}, else: {:error, :terminal_cleanup}
        Enum.each(waiters, &GenServer.reply(&1, :ok))
        Enum.each(operation.result_waiters, &GenServer.reply(&1, result))

        state =
          state
          |> drop_call_target(plan.call_id, plan.target_runtime_generation)
          |> clear_pair_operation()
          |> Map.put(:reservation, nil)
          |> Map.put(:pair_operation_result, {operation.original_worker, result})

        {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:reservation_expired, call_id, generation}, state) do
    case state.reservation do
      %{call_id: ^call_id, generation: ^generation, phase: :precommit} ->
        {:noreply, %{state | reservation: nil}}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:voice_switch_expired, user_id, generation}, state) do
    case Map.get(state.voice_switches, user_id) do
      %{generation: ^generation} ->
        {:noreply, %{state | voice_switches: Map.delete(state.voice_switches, user_id)}}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(
        {:DOWN, monitor, :process, pid, reason},
        %{recovery_worker: %{pid: pid, monitor: monitor}} = state
      ) do
    state = %{state | recovery_worker: nil}

    if reason == :normal and MapSet.size(state.recovery_calls_pending) == 0 do
      {:noreply, maybe_finish_recovery(state)}
    else
      {:noreply, fail_recovery(state)}
    end
  end

  def handle_info({:DOWN, monitor, :process, _pid, reason}, state) do
    case state.pair_operation do
      %{monitor: ^monitor, phase: :committing} ->
        {:noreply, begin_operation_cleanup(state)}

      %{monitor: ^monitor, phase: :cleaning} ->
        # Cleanup crashed before confirmation. Retry under the same held claim.
        {:noreply, start_operation_cleanup(state)}

      _ ->
        case call_target_down(state, monitor, reason) do
          {:handled, state} -> {:noreply, state}
          :not_call_target -> handle_component_down(state, monitor, reason)
        end
    end
  end

  defp handle_component_down(state, monitor, reason) do
    case Map.pop(state.monitors, monitor) do
      {nil, _monitors} ->
        {:noreply, state}

      {component, monitors} ->
        state = %{state | monitors: monitors}

        state =
          if room_failure?(reason) do
            invalidate_runtime(
              state,
              component.target,
              component.room_server_pid,
              component.runtime_generation
            )
          else
            state
          end

        state = drop_component_if_current(state, component)
        state = remove_recovery_pending(state, component)

        {:noreply, maybe_finish_recovery(state)}
    end
  end

  defp replace_call_target(state, call_id, generation, target_pid, profile, transport) do
    case Map.get(state.call_targets, call_id) do
      %{monitor: old_monitor} when is_reference(old_monitor) ->
        Process.demonitor(old_monitor, [:flush])

      _ ->
        :ok
    end

    monitor = Process.monitor(target_pid)

    target = %{
      call_id: call_id,
      runtime_generation: generation,
      target_pid: target_pid,
      runtime_identity: %{
        call_id: call_id,
        runtime_generation: generation,
        target_pid: target_pid
      },
      monitor: monitor,
      profile: profile,
      transport: transport,
      resources:
        [
          target_pid,
          GenServer.whereis(
            Target.runtime_name(Target.direct_call(call_id), generation, :sessions)
          ),
          GenServer.whereis(Target.runtime_name(Target.direct_call(call_id), generation, :room))
        ]
        |> Enum.filter(&is_pid/1),
      status: :ready,
      sessions: %{},
      failure: nil
    }

    put_in(state, [:call_targets, call_id], target)
  end

  defp update_call_target(state, call_id, generation, fun) do
    case Map.get(state.call_targets, call_id) do
      %{runtime_generation: ^generation} = target ->
        put_in(state, [:call_targets, call_id], fun.(target))

      _ ->
        state
    end
  end

  defp update_exact_call_session(state, call_id, generation, user_id, session_id, fun) do
    case Map.get(state.call_targets, call_id) do
      %{runtime_generation: ^generation, sessions: %{^session_id => ^user_id}} ->
        update_call_target(state, call_id, generation, fun)

      _ ->
        state
    end
  end

  defp call_target_start_in_use?(state, call_id, generation) do
    case Map.get(state.call_targets, call_id) do
      %{runtime_generation: ^generation, sessions: sessions} ->
        map_size(sessions) > 0 or match?(%{call_id: ^call_id}, state.reservation) or
          match?(%{call_id: ^call_id, target_runtime_generation: ^generation}, state.active_call)

      _ ->
        false
    end
  end

  defp cancel_call_target_start(state, call_id, generation) do
    if call_target_start_in_use?(state, call_id, generation) do
      state
    else
      state =
        if Map.get(state.call_target_starts, call_id) in [generation, {:cleaning, generation}] do
          update_in(state, [:call_target_starts], &Map.delete(&1, call_id))
        else
          state
        end

      drop_call_target(state, call_id, generation)
    end
  end

  defp call_target_down(state, monitor, reason) do
    Enum.find_value(state.call_targets, :not_call_target, fn {call_id, target} ->
      if target[:monitor] == monitor do
        state =
          if target.status == :startup_cleaning do
            cancel_call_target_start(state, call_id, target.runtime_generation)
          else
            record_call_target_down(state, call_id, target, reason)
          end

        {:handled, state}
      end
    end)
  end

  defp record_call_target_down(state, call_id, target, reason) do
    status = if target.status == :stopped, do: :stopped, else: :failed

    failure =
      if status == :failed do
        %{kind: :target, reason: reason, sessions: target.sessions}
      end

    target = %{
      target
      | status: status,
        failure: failure,
        sessions: %{},
        target_pid: nil,
        monitor: nil
    }

    state =
      state
      |> put_in([:call_targets, call_id], target)
      |> clear_active_pair_for_target(call_id, target.runtime_generation)

    if status == :failed do
      _ = notify_media_failed(call_id, reason)
    end

    state
  end

  # Ticket 08: fake target loss must end visibly. The coordinator owns indexes
  # and capacity, Calls owns the durable outcome. Notify async via the
  # per-call server mailbox (mirrors `{:accepted_call_runtime, ...}`); never
  # do DB work here. Missing/stopped servers are tolerated because
  # leave/friendship/interrupt recovery already funnel through the same
  # idempotent pair cleanup.
  defp notify_media_failed(call_id, reason) do
    notify_call_server(call_id, {:media_target_failed, call_id, reason})
  end

  defp notify_call_server(call_id, message) do
    case Registry.lookup(DiscordClone.Calls.CallRegistry, call_id) do
      [{pid, _}] when is_pid(pid) ->
        send(pid, message)
        :ok

      [] ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  catch
    :exit, _unavailable -> :ok
  end

  defp join_existing_session(
         state,
         voice_channel_id,
         user_id,
         signaling_session_id,
         signaling_channel,
         server_ice_projection
       ) do
    case Voice.join_room(
           voice_channel_id,
           user_id,
           signaling_session_id,
           signaling_channel,
           server_ice_projection
         ) do
      {:ok, join_result, room_server} ->
        state =
          put_session(
            state,
            voice_channel_id,
            user_id,
            signaling_session_id,
            join_result,
            room_server
          )

        {:reply, {:ok, join_result}, state}

      {:error, :unavailable} ->
        current = Map.get(state.active_by_user, user_id)

        join_new_session(
          remove_exact_session(state, user_id, current),
          voice_channel_id,
          user_id,
          signaling_session_id,
          signaling_channel,
          server_ice_projection
        )

      error ->
        {:reply, error, state}
    end
  end

  defp move_session(
         state,
         %{
           target: %Target{kind: :voice_channel, id: current_voice_channel_id},
           session_id: current_voice_session_id
         } = current,
         voice_channel_id,
         user_id,
         signaling_session_id,
         signaling_channel,
         server_ice_projection
       ) do
    with :ok <- target_available?(state, voice_channel_id, current_voice_channel_id),
         :ok <- Voice.leave_room(current_voice_channel_id, current_voice_session_id) do
      join_new_session(
        remove_exact_session(state, user_id, current),
        voice_channel_id,
        user_id,
        signaling_session_id,
        signaling_channel,
        server_ice_projection
      )
    else
      {:error, %{reason: :room_full} = room_full} -> {:reply, {:error, room_full}, state}
      error -> {:reply, error, state}
    end
  end

  # New Voice slots share the destination reservation so a held reverse
  # switch blocks a stealer. When no switch targets the destination the
  # RoomServer remains the single room-cap authority (Ticket 01 unchanged).
  defp new_destination_available?(state, voice_channel_id) do
    if destination_reserved_count(state, voice_channel_id) == 0 do
      :ok
    else
      destination_capacity_available?(state, voice_channel_id)
    end
  end

  defp target_available?(_state, voice_channel_id, voice_channel_id), do: :ok

  defp target_available?(state, voice_channel_id, _current_voice_channel_id) do
    # Room moves share the destination reservation with reverse switches so a
    # held switch blocks a stealer before it can fill the last room slot.
    destination_capacity_available?(state, voice_channel_id)
  end

  # Plain Voice joins and moves retain their existing synchronous room-cap
  # check, counting held-switch reservations against the five-Session cap.
  # Reverse switches prepare and sample occupancy outside this mailbox.
  defp destination_capacity_available?(state, voice_channel_id) do
    with :ok <- Voice.ensure_room(voice_channel_id),
         {:ok, %{occupancy: occupancy, capacity: capacity}} <-
           Voice.room_occupancy(voice_channel_id) do
      reserved = destination_reserved_count(state, voice_channel_id)

      if occupancy + reserved < capacity do
        :ok
      else
        {:error, %{reason: :room_full, occupancy: occupancy, capacity: capacity}}
      end
    end
  end

  defp join_new_session(
         state,
         voice_channel_id,
         user_id,
         signaling_session_id,
         signaling_channel,
         server_ice_projection
       ) do
    with :ok <- deployment_capacity_available?(state),
         :ok <- new_destination_available?(state, voice_channel_id),
         {:ok, %{voice_session_id: _voice_session_id} = join_result, room_server} <-
           Voice.join_room(
             voice_channel_id,
             user_id,
             signaling_session_id,
             signaling_channel,
             server_ice_projection
           ) do
      state =
        put_session(
          state,
          voice_channel_id,
          user_id,
          signaling_session_id,
          join_result,
          room_server
        )

      {:reply, {:ok, join_result}, state}
    else
      error -> {:reply, error, state}
    end
  end

  defp deployment_capacity_available?(state) do
    capacity = DeploymentCapacity.max_active_sessions()
    occupancy = occupied_slots(state)

    if occupancy < capacity do
      :ok
    else
      {:error, %{reason: :deployment_full, occupancy: occupancy, capacity: capacity}}
    end
  end

  defp occupied_slots(state) do
    map_size(state.active_by_user) +
      if(state.reservation,
        do: state.reservation.slots - credited_slots(state, state.reservation),
        else: 0
      ) +
      if(state.active_call, do: state.active_call.slots, else: 0) +
      Enum.sum_by(state.voice_switches, fn {_user_id, switch} ->
        switch_slots = 1 - voice_switch_credited(state, switch)

        # A real pair retains both occupied slots until teardown and durable
        # settlement are confirmed. Reserve its replacement without lending
        # the eventual freed slot to unrelated admission while media is alive.
        case Map.get(state.call_targets, switch.call_id) do
          %{transport: :real} -> max(switch_slots, 0)
          _ -> switch_slots
        end
      end)
  end

  defp reservation_ledger_count(state) do
    pair = if state.reservation == nil, do: 0, else: 1
    pair + map_size(state.voice_switches)
  end

  defp current_identity(state, user_id) do
    case Map.get(state.active_by_user, user_id) do
      nil -> nil
      active -> Map.take(active, [:target, :session_id, :runtime_generation])
    end
  end

  defp recovery_ready?(%{recovery_status: :ready}), do: :ok
  defp recovery_ready?(%{recovery_status: :recovering}), do: {:error, :recovering}
  defp recovery_ready?(%{recovery_status: :recovery_failed}), do: {:error, :recovery_timeout}

  defp reservation_ready?(state, call_id) do
    case recovery_ready?(state) do
      :ok ->
        if state.reservation == nil and state.active_call == nil do
          :ok
        else
          # Classify against the held claim in this mailbox turn. A later
          # lookup could race release or cleanup and confuse an unrelated
          # capacity rejection with an exact same-Call acceptance retry.
          same_call? =
            match?(%{call_id: ^call_id}, state.reservation) or
              match?(%{call_id: ^call_id}, state.active_call)

          {:error, %{reason: :reservation_conflict, same_call?: same_call?}}
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp valid_pair?({first_user_id, _}, {second_user_id, _})
       when is_binary(first_user_id) and is_binary(second_user_id) and
              first_user_id != second_user_id,
       do: :ok

  defp valid_pair?(_first, _second), do: {:error, :invalid_pair}

  defp exact_prior?(state, {user_id, expected}) do
    if current_identity(state, user_id) == expected,
      do: :ok,
      else: {:error, %{reason: :stale_prior}}
  end

  defp projected_capacity_available?(state, first, second) do
    occupancy = occupied_slots(state)
    credit = Enum.count([first, second], fn {_user_id, prior} -> prior != nil end)
    projected = occupancy - credit + 2
    capacity = DeploymentCapacity.max_active_sessions()

    if projected <= capacity,
      do: :ok,
      else: {:error, %{reason: :deployment_full, occupancy: projected, capacity: capacity}}
  end

  defp credited_slots(state, reservation) do
    Enum.count(reservation.prior_identities, fn {user_id, prior} ->
      prior != nil and current_identity(state, user_id) == prior
    end)
  end

  defp pinned?(state, user_id) do
    pair_pinned?(state, user_id) or Map.has_key?(state.voice_switches, user_id) or
      case state.active_call do
        nil -> false
        claim -> user_id in claim.user_ids
      end
  end

  defp pair_pinned?(state, user_id) do
    case state.reservation do
      nil -> false
      claim -> user_id in claim.user_ids
    end
  end

  # Reverse-switch helpers. The destination slot is held as one short-lived
  # voice switch pinning only the requesting User. Shared-cap credit applies
  # only to the two exact Call Sessions being retired (User, direct-call
  # target, Session ID, runtime generation must all match).
  defp prepare_voice_switch_for_active_call(state, user_id, voice_channel_id) do
    case state.active_call do
      %{user_ids: user_ids} = active_call when is_list(user_ids) ->
        if user_id in user_ids do
          with :ok <- no_concurrent_switch_for_call(state, active_call.call_id),
               {:ok, call_id, _peer_user_id, call_sessions, target_generation} <-
                 exact_active_call_sessions(active_call, user_id),
               :ok <- exact_call_identities?(state, call_id, target_generation, call_sessions) do
            candidate = %{
              active_call: active_call,
              destination: voice_switch_destination_snapshot(state, voice_channel_id)
            }

            {:reply, {:prepare, candidate}, state}
          else
            {:error, _reason} -> {:reply, {:error, %{reason: :reservation_conflict}}, state}
          end
        else
          {:reply, {:normal}, state}
        end

      _ ->
        {:reply, {:normal}, state}
    end
  end

  defp begin_voice_switch_with_active_call(state, user_id, voice_channel_id, candidate, occupancy) do
    with {:ok, call_id, peer_user_id, call_sessions, target_generation} <-
           exact_active_call_sessions(candidate.active_call, user_id),
         :ok <- no_concurrent_switch_for_call(state, call_id),
         :ok <- exact_call_identities?(state, call_id, target_generation, call_sessions),
         :ok <- voice_switch_target_available?(state, voice_channel_id, candidate, occupancy),
         :ok <- reverse_capacity_available?(state) do
      generation = make_ref()

      timer =
        Process.send_after(
          self(),
          {:voice_switch_expired, user_id, generation},
          @voice_switch_ttl_ms
        )

      switch = %{
        call_id: call_id,
        user_id: user_id,
        peer_user_id: peer_user_id,
        voice_channel_id: voice_channel_id,
        generation: generation,
        call_sessions: call_sessions,
        target_runtime_generation: target_generation,
        timer: timer
      }

      plan = Map.delete(switch, :timer)

      {:reply, {:ok, plan},
       %{state | voice_switches: Map.put(state.voice_switches, user_id, switch)}}
    else
      {:prepare, updated_candidate} -> {:reply, {:prepare, updated_candidate}, state}
      {:error, %{reason: :room_full} = room_full} -> {:reply, {:error, room_full}, state}
      {:error, %{reason: :deployment_full} = full} -> {:reply, {:error, full}, state}
      {:error, _reason} -> {:reply, {:error, %{reason: :reservation_conflict}}, state}
    end
  end

  defp exact_active_call_sessions(
         %{call_id: call_id, user_ids: user_ids, call_sessions: call_sessions} = active_call,
         user_id
       )
       when is_binary(call_id) and is_map(call_sessions) and map_size(call_sessions) == 2 do
    target_generation = Map.get(active_call, :target_runtime_generation)

    if is_reference(target_generation) and user_id in user_ids do
      peer_user_id = Enum.find(user_ids, &(&1 != user_id))
      {:ok, call_id, peer_user_id, call_sessions, target_generation}
    else
      {:error, :stale_call}
    end
  end

  defp exact_active_call_sessions(_active_call, _user_id), do: {:error, :stale_call}

  defp exact_call_identities?(state, call_id, target_generation, call_sessions) do
    target_ref = Target.direct_call(call_id)

    exact? =
      Enum.all?(call_sessions, fn {session_user_id, session_id} ->
        case Map.get(state.active_by_user, session_user_id) do
          %{target: ^target_ref, session_id: ^session_id, runtime_generation: ^target_generation} ->
            true

          _ ->
            false
        end
      end)

    if exact?, do: :ok, else: {:error, :stale_call}
  end

  defp voice_switch_credited(state, switch) do
    target_ref = Target.direct_call(switch.call_id)
    expected_generation = switch.target_runtime_generation

    Enum.count(switch.call_sessions, fn {session_user_id, session_id} ->
      case Map.get(state.active_by_user, session_user_id) do
        %{
          target: ^target_ref,
          session_id: ^session_id,
          runtime_generation: generation
        } ->
          generation == expected_generation

        _ ->
          false
      end
    end)
  end

  defp destination_reserved_count(state, voice_channel_id) do
    Enum.count(state.voice_switches, fn {_user_id, switch} ->
      switch.voice_channel_id == voice_channel_id
    end)
  end

  # A second held switch over the same Call ID would credit the same two
  # exact Call Sessions twice (`occupied_slots` subtracts per switch), so the
  # peer must wait for the first switch to publish/abort/expire. This keeps
  # the "credits only the two exact Call Sessions" guarantee under
  # concurrent switch attempts.
  defp no_concurrent_switch_for_call(state, call_id) do
    if Enum.any?(state.voice_switches, fn {_user_id, switch} ->
         switch.call_id == call_id
       end) do
      {:error, :concurrent_switch}
    else
      :ok
    end
  end

  # Occupancy was read outside the mailbox. Any intervening admission, removal,
  # or runtime replacement invalidates that sample. Resample before granting
  # the hold; held switches are counted from the current ledger in this turn.
  defp voice_switch_target_available?(state, voice_channel_id, candidate, %{
         occupancy: occupancy,
         capacity: capacity
       }) do
    destination = voice_switch_destination_snapshot(state, voice_channel_id)

    cond do
      destination != candidate.destination ->
        {:prepare, %{candidate | destination: destination}}

      occupancy + destination_reserved_count(state, voice_channel_id) < capacity ->
        :ok

      true ->
        {:error, %{reason: :room_full, occupancy: occupancy, capacity: capacity}}
    end
  end

  defp voice_switch_destination_snapshot(state, voice_channel_id) do
    target = Target.voice_channel(voice_channel_id)

    %{
      runtime: get_in(state.runtimes_by_target, [target, :room_server]),
      sessions:
        Map.filter(state.active_by_user, fn {_user_id, active} -> active.target == target end)
    }
  end

  defp reverse_capacity_available?(state) do
    capacity = DeploymentCapacity.max_active_sessions()
    # The ledger already reserves the destination against exact Call priors.
    # Real transport keeps the occupied pair charged until confirmed cleanup;
    # fake transport retains its existing immediate projected credit. Do not
    # subtract the pair again here.
    occupied = occupied_slots(state)

    if occupied <= capacity do
      :ok
    else
      {:error, %{reason: :deployment_full, occupancy: occupied, capacity: capacity}}
    end
  end

  defp clear_pair_operation(state) do
    if state.pair_operation do
      Process.cancel_timer(state.pair_operation.timer)
      Process.demonitor(state.pair_operation.monitor, [:flush])
    end

    %{state | pair_operation: nil}
  end

  defp pair_operation_timeout(key, budget) do
    case Application.get_env(:discord_clone, :pair_operation_timeouts, %{}) do
      %{^key => milliseconds} when is_integer(milliseconds) and milliseconds > 0 ->
        min(milliseconds, budget)

      _ ->
        budget
    end
  end

  defp start_real_cleanup(%{real_cleanup: %{call_id: call_id}} = state, call_id, _observed_at),
    do: state

  defp start_real_cleanup(%{real_cleanup: cleanup} = state, _call_id, _observed_at)
       when not is_nil(cleanup), do: state

  defp start_real_cleanup(state, call_id, observed_at) do
    case Map.get(state.call_targets, call_id) do
      %{transport: :real} = target ->
        deadline = observed_at + pair_operation_timeout(:cleanup_ms, @pair_step_timeout_ms)
        token = make_ref()
        owner = self()
        operation = state.pair_operation

        if operation && operation.plan.call_id == call_id do
          Process.cancel_timer(operation.timer)
          Process.exit(operation.worker, :kill)
          Process.demonitor(operation.monitor, [:flush])
          Enum.each(operation.waiters, &GenServer.reply(&1, :ok))
          Enum.each(operation.result_waiters, &GenServer.reply(&1, {:error, :terminal_cleanup}))
        end

        timer =
          Process.send_after(
            self(),
            {:real_cleanup_expired, token},
            max(deadline - System.monotonic_time(:millisecond), 0)
          )

        cleanup = %{
          call_id: call_id,
          generation: target.runtime_generation,
          token: token,
          deadline: deadline,
          timer: timer,
          media_gone?: false,
          settled?: false,
          failed?: false,
          waiters: []
        }

        reservation =
          case state.reservation do
            %{call_id: ^call_id} = reservation -> %{reservation | phase: :cleaning}
            other -> other
          end

        state =
          if operation && operation.plan.call_id == call_id,
            do: clear_pair_operation(state),
            else: state

        state =
          %{state | real_cleanup: cleanup, reservation: reservation}
          |> DiscordClone.Media.CallCleanupLedger.retain(call_id)

        spawn(fn ->
          :ok = DirectCallTarget.startup_control(:cleanup_starting, %{call_id: call_id})

          :ok =
            DiscordClone.Media.PairCommitCleanup.retire(
              target.target_pid,
              if(operation && operation.plan.call_id == call_id,
                do: [operation.worker | target.resources],
                else: target.resources
              ),
              deadline
            )

          send(owner, {:real_media_retired, token})
        end)

        state

      _ ->
        state
    end
  end

  defp finish_real_cleanup(
         %{real_cleanup: %{failed?: false, media_gone?: true, settled?: true} = cleanup} = state
       ) do
    if System.monotonic_time(:millisecond) < cleanup.deadline do
      Process.cancel_timer(cleanup.timer)
      Enum.each(cleanup.waiters, &GenServer.reply(&1, :ok))
      :ok = DiscordClone.Media.CallCleanupLedger.clear()

      state =
        case state.active_call do
          %{call_id: call_id, call_sessions: sessions} when call_id == cleanup.call_id ->
            state
            |> clear_published_pair(call_id, cleanup.generation, sessions)
            |> Map.put(:active_call, nil)

          _ ->
            state
        end

      reservation =
        case state.reservation do
          %{call_id: call_id} when call_id == cleanup.call_id -> nil
          other -> other
        end

      state
      |> drop_call_target(cleanup.call_id, cleanup.generation)
      |> Map.put(:reservation, reservation)
      |> Map.put(:real_cleanup, nil)
    else
      state
    end
  end

  defp finish_real_cleanup(state), do: state

  defp begin_operation_cleanup(%{pair_operation: %{phase: :cleaning}} = state), do: state

  defp begin_operation_cleanup(state) do
    call_id = state.pair_operation.plan.call_id

    case Map.get(state.call_targets, call_id) do
      %{transport: :real} ->
        start_real_cleanup(state, call_id, System.monotonic_time(:millisecond))

      _ ->
        begin_fake_operation_cleanup(state)
    end
  end

  defp begin_fake_operation_cleanup(state) do
    operation = state.pair_operation
    Process.cancel_timer(operation.timer)
    Process.exit(operation.worker, :kill)
    Process.demonitor(operation.monitor, [:flush])
    plan = operation.plan

    state =
      update_call_target(
        state,
        plan.call_id,
        plan.target_runtime_generation,
        &%{&1 | status: :stopped}
      )

    state = %{state | reservation: %{state.reservation | phase: :cleaning}}
    start_operation_cleanup(state)
  end

  defp start_operation_cleanup(state) do
    coordinator = self()
    plan = state.pair_operation.plan
    retired_worker = state.pair_operation.original_worker

    deadline =
      System.monotonic_time(:millisecond) +
        pair_operation_timeout(:cleanup_ms, @pair_step_timeout_ms)

    {worker, monitor} =
      spawn_monitor(fn ->
        :ok = DiscordClone.Media.PairCommitCleanup.run(plan.target_pid, deadline, retired_worker)
        send(coordinator, {:pair_operation_cleaned, plan.generation})
      end)

    operation = %{state.pair_operation | worker: worker, monitor: monitor, phase: :cleaning}
    %{state | pair_operation: operation}
  end

  defp expired_reservation?(reservation) do
    System.monotonic_time(:millisecond) >= reservation.expires_at
  end

  defp exact_priors?(state, reservation) do
    Enum.reduce_while(reservation.prior_identities, :ok, fn {user_id, prior}, :ok ->
      case exact_prior?(state, {user_id, prior}) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp begin_pair_commit_plan(state, reservation) do
    with :ok <- exact_priors?(state, reservation),
         {:ok, target} <- vacant_call_target(state, reservation.call_id) do
      plan = %{
        call_id: reservation.call_id,
        generation: reservation.generation,
        user_ids: reservation.user_ids,
        prior_identities: reservation.prior_identities,
        target_pid: target.pid,
        target_runtime_generation: target.generation
      }

      {:ok, plan}
    end
  end

  defp vacant_call_target(state, call_id) do
    with {:ok, %{sessions: sessions} = target} <- fetch_ready_target(state, call_id, nil),
         true <- sessions == %{} do
      {:ok, target}
    else
      _unavailable_or_occupied -> target_unavailable()
    end
  end

  defp exact_pair_target(state, call_id, target_runtime_generation, user_ids, sessions) do
    with {:ok, target} <-
           fetch_ready_target(state, call_id, target_runtime_generation),
         true <- pair_sessions_match?(target.sessions, user_ids, sessions) do
      {:ok, target}
    else
      _unavailable_or_mismatched -> target_unavailable()
    end
  end

  defp fetch_ready_target(state, call_id, expected_generation) do
    case Map.get(state.call_targets, call_id) do
      %{
        status: :ready,
        target_pid: target_pid,
        runtime_generation: generation,
        profile: %Profile{capacity: capacity},
        sessions: sessions,
        transport: transport
      }
      when is_pid(target_pid) and is_reference(generation) and capacity >= 2 ->
        if expected_generation == nil or expected_generation == generation do
          {:ok,
           %{pid: target_pid, generation: generation, sessions: sessions, transport: transport}}
        else
          target_unavailable()
        end

      _missing_or_unready ->
        target_unavailable()
    end
  end

  defp target_unavailable, do: {:error, %{reason: :target_unavailable}}

  defp both_call_sides_connected?(statuses) do
    map_size(statuses) == 2 and Enum.all?(statuses, fn {_id, status} -> status == :connected end)
  end

  defp pair_sessions_match?(target_sessions, user_ids, sessions) do
    Enum.sort(Map.keys(sessions)) == Enum.sort(user_ids) and
      Enum.all?(sessions, fn {user_id, session_id} ->
        Map.get(target_sessions, session_id) == user_id
      end)
  end

  defp retire_reserved_priors(state, reservation) do
    Enum.reduce(reservation.prior_identities, state, fn
      {_user_id, nil}, state -> state
      {user_id, prior}, state -> remove_exact_session(state, user_id, prior)
    end)
  end

  defp put_call_sessions(state, call_id, target, sessions) do
    target_ref = Target.direct_call(call_id)

    Enum.reduce(sessions, state, fn {user_id, call_session_id}, state ->
      session = %{
        target: target_ref,
        session_id: call_session_id,
        runtime_generation: target.generation,
        signaling_session_id: nil,
        room_server_pid: nil
      }

      put_in(state.active_by_user[user_id], session)
    end)
  end

  defp clear_published_pair(state, call_id, target_generation, call_sessions) do
    target_ref = Target.direct_call(call_id)

    Enum.reduce(call_sessions, state, fn {user_id, session_id}, state ->
      case Map.get(state.active_by_user, user_id) do
        %{target: ^target_ref, session_id: ^session_id, runtime_generation: ^target_generation} ->
          %{state | active_by_user: Map.delete(state.active_by_user, user_id)}

        _replacement_or_missing ->
          state
      end
    end)
  end

  defp drop_call_target(state, call_id, target_generation) do
    case Map.get(state.call_targets, call_id) do
      %{runtime_generation: ^target_generation, monitor: monitor} = _target ->
        if is_reference(monitor), do: Process.demonitor(monitor, [:flush])

        %{state | call_targets: Map.delete(state.call_targets, call_id)}

      _stale_or_missing ->
        state
    end
  end

  defp clear_active_pair_for_target(state, call_id, target_generation) do
    if match?(
         %{transport: :real, runtime_generation: ^target_generation},
         Map.get(state.call_targets, call_id)
       ) do
      start_real_cleanup(state, call_id, System.monotonic_time(:millisecond))
    else
      case state.active_call do
        %{
          call_id: ^call_id,
          target_runtime_generation: ^target_generation,
          call_sessions: call_sessions
        } = active_call ->
          remaining_slots =
            case Map.get(state.call_targets, call_id) do
              %{runtime_generation: ^target_generation, sessions: sessions} -> map_size(sessions)
              _ -> 0
            end

          claim =
            if remaining_slots == 0 and not Map.get(active_call, :cleaning?, false) do
              nil
            else
              active_call
              |> Map.put(:cleaning?, true)
              |> Map.put(:slots, remaining_slots)
            end

          state
          |> clear_published_pair(call_id, target_generation, call_sessions)
          |> Map.put(:active_call, claim)

        _stale_or_unpublished ->
          state
      end
    end
  end

  defp exact_published_session?(state, call_id, target_generation, user_id, session_id) do
    case state.active_call do
      %{
        call_id: ^call_id,
        target_runtime_generation: ^target_generation,
        call_sessions: call_sessions
      } ->
        Map.get(call_sessions, user_id) == session_id

      _ ->
        false
    end
  end

  defp ensure_durably_connecting(%{
         call_id: call_id,
         user_ids: [first_user_id, second_user_id]
       }) do
    if Calls.pair_connecting?(call_id, first_user_id, second_user_id),
      do: :ok,
      else: {:error, :not_connecting}
  end

  defp retire_and_create_sessions(plan) do
    case retire_prior_sessions(plan) do
      :ok -> create_pair_sessions(plan)
      {:error, reason, created} -> {:error, reason, created}
    end
  end

  # Test-only deterministic fault seam. Production default is `%{}` (inert).
  # Tests set `Application.put_env(:discord_clone, :pair_commit_fault, faults)`
  # with optional keys `:retire_failures` (list/MapSet of User IDs),
  # `:admit_failures` (list/MapSet of User IDs), `:publish_failure` (true),
  # and `:barrier` (a stage callback outside the coordinator mailbox).
  # See `pair_admission_failure_test.exs`.
  defp commit_faults do
    Application.get_env(:discord_clone, :pair_commit_fault, %{})
  end

  defp fault_user_ids(faults, key) do
    case Map.get(faults, key) do
      nil -> MapSet.new()
      %MapSet{} = set -> set
      list when is_list(list) -> MapSet.new(list)
      user_id when is_binary(user_id) -> MapSet.new([user_id])
      _ -> MapSet.new()
    end
  end

  defp check_publish_fault do
    if Map.get(commit_faults(), :publish_failure, false) do
      {:error, %{reason: :target_unavailable}}
    else
      :ok
    end
  end

  defp pair_commit_barrier(stage) do
    case Map.get(commit_faults(), :barrier) do
      barrier when is_function(barrier, 1) -> barrier.(stage)
      _ -> :ok
    end
  end

  defp first_retirement_barrier(user_id, [first_user_id | _]) when user_id == first_user_id,
    do: pair_commit_barrier(:after_first_retirement)

  defp first_retirement_barrier(_user_id, _users), do: :ok

  defp retire_prior_sessions(plan) do
    retire_failures = fault_user_ids(commit_faults(), :retire_failures)

    Enum.reduce_while(plan.user_ids, :ok, fn user_id, :ok ->
      case Map.get(plan.prior_identities, user_id) do
        nil ->
          {:cont, :ok}

        prior ->
          if MapSet.member?(retire_failures, user_id) do
            {:halt, {:error, :unavailable, %{}}}
          else
            case Voice.retire_room_session(prior.target.id, prior.session_id) do
              :ok ->
                first_retirement_barrier(user_id, plan.user_ids)
                {:cont, :ok}

              {:error, reason} ->
                {:halt, {:error, reason, %{}}}
            end
          end
      end
    end)
  end

  defp create_pair_sessions(plan) do
    admit_failures = fault_user_ids(commit_faults(), :admit_failures)

    Enum.reduce_while(plan.user_ids, {:ok, %{}}, fn user_id, {:ok, sessions} ->
      if MapSet.member?(admit_failures, user_id) do
        {:halt, {:error, :target_unavailable, sessions}}
      else
        case DirectCallTarget.admit(plan.target_pid, user_id) do
          {:ok, %{call_session_id: call_session_id}} ->
            {:cont, {:ok, Map.put(sessions, user_id, call_session_id)}}

          {:error, _reason} ->
            {:halt, {:error, :target_unavailable, sessions}}
        end
      end
    end)
  end

  defp abort_pair_commit(plan, created_sessions, reason) do
    case call_target_snapshot(plan.call_id) do
      %{transport: :real} -> begin_terminal_cleanup(plan.call_id)
      _ -> :ok
    end

    Enum.each(created_sessions, fn {user_id, call_session_id} ->
      _ = DirectCallTarget.remove(plan.target_pid, user_id, call_session_id)
    end)

    _ =
      GenServer.call(
        @server_name,
        {:finish_pair_abort, plan.call_id, plan.generation, plan.target_runtime_generation},
        @pair_step_timeout_ms
      )

    {:error, reason}
  end

  defp put_session(
         state,
         voice_channel_id,
         user_id,
         signaling_session_id,
         %{voice_session_id: voice_session_id},
         room_server
       ) do
    target = Target.voice_channel(voice_channel_id)
    state = track_room_server(state, voice_channel_id, room_server)

    session = %{
      target: target,
      session_id: voice_session_id,
      runtime_generation: runtime_generation(state, target, room_server),
      signaling_session_id: signaling_session_id,
      room_server_pid: room_server
    }

    put_in(state.active_by_user[user_id], session)
  end

  defp end_user_session(state, voice_channel_id, user_id) do
    case Map.get(state.active_by_user, user_id) do
      %{target: %Target{kind: :voice_channel, id: ^voice_channel_id}} = active ->
        :ok = Voice.leave_room(voice_channel_id, active.session_id)
        remove_exact_session(state, user_id, active)

      _current_or_missing ->
        state
    end
  end

  defp end_channel_sessions(state, voice_channel_id) do
    Enum.reduce(state.active_by_user, state, fn
      {user_id, %{target: %Target{kind: :voice_channel, id: ^voice_channel_id}} = active},
      state ->
        :ok = Voice.leave_room(voice_channel_id, active.session_id)
        remove_exact_session(state, user_id, active)

      _current_or_missing, state ->
        state
    end)
  end

  defp remove_exact_session(state, nil), do: state

  defp remove_exact_session(state, expected) do
    Enum.reduce(state.active_by_user, state, fn {user_id, active}, state ->
      if active == expected, do: remove_exact_session(state, user_id, expected), else: state
    end)
  end

  defp remove_exact_session(state, user_id, expected) do
    if expected do
      remove_exact_session(
        state,
        user_id,
        expected.target,
        expected.session_id,
        expected.runtime_generation
      )
    else
      state
    end
  end

  defp remove_exact_session(state, _user_id, _target, _session_id, nil), do: state

  defp remove_exact_session(state, user_id, target, session_id, generation) do
    case Map.get(state.active_by_user, user_id) do
      %{target: ^target, session_id: ^session_id, runtime_generation: ^generation} ->
        %{state | active_by_user: Map.delete(state.active_by_user, user_id)}

      _replacement_or_missing ->
        state
    end
  end

  defp current_room_server?(voice_channel_id, room_server) do
    is_pid(room_server) and
      GenServer.whereis(
        Target.runtime_name(Target.voice_channel(voice_channel_id), room_server, :room)
      ) == room_server
  end

  defp track_room_server(state, voice_channel_id, room_server) do
    target = Target.voice_channel(voice_channel_id)
    existing = get_in(state.runtimes_by_target, [target, :room_server])

    if existing && existing.pid == room_server do
      state
    else
      state =
        if existing do
          state
          |> invalidate_runtime(voice_channel_id, existing.pid)
          |> remove_component(voice_channel_id, :room_server)
          |> remove_recovery_pending(existing.pid)
        else
          invalidate_other_runtime_sessions(state, voice_channel_id, room_server)
        end

      monitor = Process.monitor(room_server)

      state
      |> put_component(voice_channel_id, :room_server, room_server, monitor, room_server)
      |> add_recovery_pending(room_server)
    end
  end

  defp track_forwarder(state, voice_channel_id, forwarder, room_server) do
    target = Target.voice_channel(voice_channel_id)

    room_server =
      room_server || get_in(state.runtimes_by_target, [target, :room_server, :pid])

    state =
      if is_pid(room_server) and
           get_in(state.runtimes_by_target, [target, :room_server, :pid]) == nil do
        track_room_server(state, voice_channel_id, room_server)
      else
        state
      end

    existing = get_in(state.runtimes_by_target, [target, :forwarder])

    if existing && existing.pid == forwarder do
      state
    else
      state =
        if existing do
          state
          |> invalidate_runtime(voice_channel_id, existing.room_server_pid)
          |> remove_component(voice_channel_id, :forwarder)
        else
          invalidate_other_runtime_sessions(state, voice_channel_id, room_server)
        end

      monitor = Process.monitor(forwarder)

      state
      |> put_component(voice_channel_id, :forwarder, forwarder, monitor, room_server)
    end
  end

  defp put_component(state, voice_channel_id, component_name, pid, monitor, room_server_pid) do
    target = Target.voice_channel(voice_channel_id)

    generation =
      runtime_generation(state, target, room_server_pid) || make_ref()

    component = %{
      target: target,
      component: component_name,
      pid: pid,
      monitor: monitor,
      room_server_pid: room_server_pid,
      runtime_generation: generation
    }

    room = Map.get(state.runtimes_by_target, target, %{})

    %{
      state
      | runtimes_by_target:
          Map.put(
            state.runtimes_by_target,
            target,
            Map.put(room, component_name, %{
              pid: pid,
              monitor: monitor,
              room_server_pid: room_server_pid,
              runtime_generation: generation
            })
          ),
        monitors: Map.put(state.monitors, monitor, component)
    }
  end

  defp remove_component(state, voice_channel_id, component_name) do
    target = Target.voice_channel(voice_channel_id)

    case get_in(state.runtimes_by_target, [target, component_name]) do
      %{monitor: monitor} ->
        Process.demonitor(monitor, [:flush])

        runtimes_by_target =
          case Map.get(state.runtimes_by_target, target) |> Map.delete(component_name) do
            empty_room when map_size(empty_room) == 0 ->
              Map.delete(state.runtimes_by_target, target)

            room ->
              Map.put(state.runtimes_by_target, target, room)
          end

        state
        |> Map.put(:runtimes_by_target, runtimes_by_target)
        |> update_in([:monitors], &Map.delete(&1, monitor))

      nil ->
        state
    end
  end

  defp drop_component_if_current(state, %{target: target} = component) do
    pid = component.pid
    monitor = component.monitor

    case get_in(state.runtimes_by_target, [target, component.component]) do
      %{pid: ^pid, monitor: ^monitor} ->
        runtimes_by_target =
          case Map.get(state.runtimes_by_target, target)
               |> Map.delete(component.component) do
            empty_room when map_size(empty_room) == 0 ->
              Map.delete(state.runtimes_by_target, target)

            room ->
              Map.put(state.runtimes_by_target, target, room)
          end

        Map.put(state, :runtimes_by_target, runtimes_by_target)

      _replacement_or_missing ->
        state
    end
  end

  defp add_recovery_pending(%{recovery_status: :recovering} = state, room_server) do
    Map.update!(state, :recovery_pending, &MapSet.put(&1, room_server))
  end

  defp add_recovery_pending(state, _room_server), do: state

  defp remove_recovery_pending(state, %{component: :room_server, pid: room_server}) do
    Map.update!(state, :recovery_pending, &MapSet.delete(&1, room_server))
  end

  defp remove_recovery_pending(state, %{component: :recovery_call_target, pid: target_pid}) do
    Map.update!(state, :recovery_pending, &MapSet.delete(&1, target_pid))
  end

  defp remove_recovery_pending(state, room_server) when is_pid(room_server) do
    Map.update!(state, :recovery_pending, &MapSet.delete(&1, room_server))
  end

  defp remove_recovery_pending(state, _component), do: state

  defp invalidate_runtime(state, _voice_channel_id, nil), do: state

  defp invalidate_runtime(state, voice_channel_id, room_server) do
    target = Target.voice_channel(voice_channel_id)
    generation = runtime_generation(state, target, room_server)

    invalidate_runtime(state, target, room_server, generation)
  end

  defp invalidate_runtime(state, _target, _room_server, nil), do: state

  defp invalidate_runtime(state, target, room_server, generation) do
    Enum.reduce(state.active_by_user, state, fn {user_id, session}, state ->
      if session.target == target and session.room_server_pid == room_server and
           session.runtime_generation == generation do
        remove_exact_session(state, user_id, session)
      else
        state
      end
    end)
  end

  defp invalidate_other_runtime_sessions(state, _voice_channel_id, nil), do: state

  defp invalidate_other_runtime_sessions(state, voice_channel_id, room_server) do
    target = Target.voice_channel(voice_channel_id)

    Enum.reduce(state.active_by_user, state, fn {user_id, session}, state ->
      if session.target == target and session.room_server_pid != room_server do
        remove_exact_session(state, user_id, session)
      else
        state
      end
    end)
  end

  defp runtime_generation(state, target, room_server) do
    case get_in(state.runtimes_by_target, [target, :room_server]) do
      %{pid: ^room_server, runtime_generation: generation} -> generation
      _other_runtime -> nil
    end
  end

  defp room_failure?(:normal), do: false
  defp room_failure?(_reason), do: true

  defp recovery_timer(:recovering),
    do: Process.send_after(self(), :recovery_timeout, @recovery_timeout_ms)

  defp maybe_finish_recovery(%{recovery_status: :recovering, recovery_pending: pending} = state) do
    if MapSet.size(pending) == 0 and MapSet.size(state.recovery_calls_pending) == 0 and
         is_nil(state.recovery_worker) do
      if state.recovery_timer, do: Process.cancel_timer(state.recovery_timer)
      Enum.each(state.recovery_waiters, &GenServer.reply(&1, :ok))
      %{state | recovery_status: :ready, recovery_waiters: [], recovery_timer: nil}
    else
      state
    end
  end

  defp maybe_finish_recovery(state), do: state

  defp fail_recovery(state) do
    if state.recovery_worker do
      Process.exit(state.recovery_worker.pid, :kill)
      Process.demonitor(state.recovery_worker.monitor, [:flush])
    end

    if state.recovery_timer, do: Process.cancel_timer(state.recovery_timer)
    Enum.each(state.recovery_waiters, &GenServer.reply(&1, {:error, :recovery_timeout}))

    %{
      state
      | recovery_status: :recovery_failed,
        recovery_worker: nil,
        recovery_waiters: [],
        recovery_timer: nil
    }
  end
end
