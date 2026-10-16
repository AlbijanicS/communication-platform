defmodule DiscordClone.Calls do
  @moduledoc """
  Public boundary for Direct Call invitation workflows.

  Phase 1 starts with durable ringing attempts only. This context exposes safe
  participant projections and keeps runtime identity private.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias DiscordClone.Accounts.{Scope, User}
  alias DiscordClone.Activities.ActivityItem
  alias DiscordClone.Activities.Topics, as: ActivityTopics
  alias DiscordClone.Calls.{CallAttempt, CallCoordinator, CallServer}
  alias DiscordClone.Chat
  alias DiscordClone.Chat.DirectConversation
  alias DiscordClone.Friendships
  alias DiscordClone.Media.AdmissionCoordinator
  alias DiscordClone.Media.{DirectCallSession, DirectCallTarget}
  alias DiscordClone.Repo

  @ringing_seconds 30
  @caller_start_window_seconds 60
  @unanswered_pair_window_seconds 300
  @terminal_retention_days 7
  @prune_batch_size 100
  @default_max_starts_per_caller_per_minute 5
  @default_max_unanswered_attempts_per_pair_per_five_minutes 3
  @projection_source [
    call_id: :id,
    direct_conversation_id: :direct_conversation_id,
    caller_user_id: :caller_user_id,
    recipient_user_id: :recipient_user_id,
    media_intent: :media_intent,
    state: :state,
    ringing_deadline_at: :ringing_deadline_at,
    started_at: :inserted_at,
    terminal_outcome: :terminal_outcome,
    ended_at: :ended_at
  ]
  @projection_keys Keyword.keys(@projection_source)

  @type start_error ::
          :unauthenticated
          | :not_found
          | :not_friends
          | :invalid_media_intent
          | :busy
          | :rate_limited
          | :temporarily_unavailable

  @type decline_error :: :unauthenticated | :not_found | :stale | :temporarily_unavailable
  @type cancel_error :: decline_error
  @type accept_error :: decline_error
  @type leave_error :: decline_error

  @doc "Returns browser device selection and video availability for Direct Calls."
  @spec browser_media_capabilities(term()) :: %{
          device_adapter: :real | :fake,
          video_available?: boolean()
        }
  def browser_media_capabilities(_scope) do
    adapter = if DirectCallTarget.real_transport?(), do: :real, else: :fake
    %{device_adapter: adapter, video_available?: camera_lifecycle_available?()}
  end

  # Server-controlled policy; availability grants no participant or owner authority.
  @doc false
  @spec camera_lifecycle_available?() :: boolean()
  def camera_lifecycle_available? do
    not DirectCallTarget.real_transport?() or
      Application.get_env(:discord_clone, :direct_call_camera_lifecycle_enabled, false) == true
  end

  @doc "Subscribes the authenticated User to private call projections."
  @spec subscribe(term()) :: :ok | {:error, :unauthenticated}
  def subscribe(%Scope{user: %User{id: user_id}}) do
    Phoenix.PubSub.subscribe(DiscordClone.PubSub, user_topic(user_id))
  end

  def subscribe(_scope), do: {:error, :unauthenticated}

  @doc """
  Starts one durable ringing Call Attempt from a Direct Conversation.

  A new start commits the Call Attempt, crosses the CallServer readiness
  barrier, and publishes the ringing projection. A retry against the same
  ringing Direct Conversation returns that Call ID with `started?: false`.
  """
  @spec start_call(term(), term(), term()) ::
          {:ok, %{call: map(), started?: boolean()}} | {:error, start_error()}
  def start_call(scope, direct_conversation_id, media_intent) do
    start_call(scope, direct_conversation_id, media_intent, [])
  end

  @doc false
  @spec start_call(term(), term(), term(), keyword()) ::
          {:ok, %{call: map(), started?: boolean()}} | {:error, start_error()}
  def start_call(%Scope{user: %User{}} = scope, direct_conversation_id, media_intent, opts) do
    with {:ok, media_intent} <- normalize_media_intent(media_intent),
         {:ok, %{direct_conversation: direct_conversation, other_participant: recipient}} <-
           Chat.get_direct_conversation(scope, direct_conversation_id),
         :ok <- available_media_intent(media_intent) do
      CallCoordinator.start_call(
        scope,
        direct_conversation.id,
        recipient.id,
        media_intent,
        Keyword.get(opts, :caller_connection_id)
      )
    else
      {:error, :invalid_media_intent} -> {:error, :invalid_media_intent}
      {:error, :not_found} -> {:error, :not_found}
      {:error, :unauthenticated} -> {:error, :unauthenticated}
      {:error, :temporarily_unavailable} -> {:error, :temporarily_unavailable}
    end
  end

  def start_call(_scope, _direct_conversation_id, _media_intent, _opts),
    do: {:error, :unauthenticated}

  @doc "Returns a sanitized Call projection with accepted media state for current Friend participants."
  @spec get_call(term(), term()) :: {:ok, map()} | {:error, :unauthenticated | :not_found}
  def get_call(%Scope{user: %User{id: user_id}} = scope, call_id) do
    with {:ok, call_id} <- Ecto.UUID.cast(call_id),
         %CallAttempt{} = call_attempt <- participant_call_attempt(call_id, user_id),
         other_user_id when is_binary(other_user_id) <- other_user_id(call_attempt, user_id),
         true <- Friendships.friends?(scope, other_user_id) do
      {:ok, project_live_call(call_attempt)}
    else
      _not_found_or_former_friend -> {:error, :not_found}
    end
  end

  def get_call(_scope, _call_id), do: {:error, :unauthenticated}

  @doc """
  Discovers an admitted real Call Session for its registered owner channel.

  The connection must come from the authenticated socket, never request params.
  Discovery allocates nothing and exposes only the browser ICE projection.
  Ownership and exact runtime publication are checked again after Session access.
  """
  def media_credentials(scope, call_id, connection_id),
    do: media_credentials(scope, call_id, connection_id, nil)

  @doc false
  def media_credentials(
        %Scope{user: %User{}} = scope,
        call_id,
        connection_id,
        signaling_session_id
      ) do
    with {:ok, authority, session} <- authorized_media(scope, call_id, connection_id),
         {:ok, credentials} <-
           DirectCallSession.media_credentials(session, signaling_session_id),
         {:ok, ^authority, ^session} <- authorized_media(scope, call_id, connection_id) do
      {:ok, Map.put(credentials, :call_id, call_id)}
    else
      _ -> {:error, :not_admitted}
    end
  catch
    :exit, _unavailable -> {:error, :not_admitted}
  end

  def media_credentials(_scope, _call_id, _connection_id, _signaling_session_id),
    do: {:error, :unauthenticated}

  @doc "Executes bounded signaling for the exact admitted owner channel and Call Session."
  def signal_media(%Scope{user: %User{}} = scope, call_id, connection_id, operation, payload)
      when operation in [:offer, :candidate, :renew, :local_media_state] and is_map(payload) do
    with {:ok, authority, session} <- authorized_media(scope, call_id, connection_id),
         true <- payload["call_session_id"] == authority.identity.session_id,
         result <- execute_media(session, authority.identity, operation, payload) do
      case authorized_media(scope, call_id, connection_id) do
        {:ok, ^authority, ^session} ->
          if operation == :local_media_state and match?({:ok, _}, result) do
            {:ok, snapshot} = result

            case CallServer.publish_media_state(
                   call_id,
                   scope.user.id,
                   connection_id,
                   authority,
                   snapshot
                 ) do
              :ok -> result
              error -> error
            end
          else
            result
          end

        _ ->
          if operation == :offer and match?({:ok, _}, result) do
            AdmissionCoordinator.begin_terminal_cleanup(
              call_id,
              authority.identity.runtime_generation
            )
          end

          {:error, :not_admitted}
      end
    else
      _ -> {:error, :not_admitted}
    end
  catch
    :exit, _unavailable -> {:error, :not_admitted}
  end

  def signal_media(_scope, _call_id, _connection_id, _operation, _payload),
    do: {:error, :not_admitted}

  @doc false
  def media_event_authorized?(scope, call_id, connection_id, session_id) do
    case authorized_media(scope, call_id, connection_id) do
      {:ok, %{identity: %{session_id: ^session_id}}, _session} -> true
      _ -> false
    end
  catch
    :exit, _unavailable -> false
  end

  defp authorized_media(%Scope{user: %User{id: user_id}} = scope, call_id, connection_id) do
    with {:ok, %{state: state}} when state in [:connecting, :active] <- get_call(scope, call_id),
         {:ok, owner} <- CallServer.authorize_media(call_id, user_id, connection_id),
         {:ok, identity, target} <- AdmissionCoordinator.call_media_session(call_id, user_id),
         {:ok, session} <- DirectCallTarget.session(target, user_id, identity.session_id) do
      {:ok, %{owner: owner, identity: identity, target: target}, session}
    else
      _ -> {:error, :not_admitted}
    end
  end

  defp authorized_media(_scope, _call_id, _connection_id), do: {:error, :not_admitted}

  defp execute_media(session, identity, operation, payload) do
    result =
      case operation do
        :offer -> DirectCallSession.accept_offer(session, payload)
        :candidate -> DirectCallSession.add_ice_candidate(session, payload)
        :renew -> DirectCallSession.renew(session, payload)
        :local_media_state -> DirectCallSession.local_media_state(session, payload)
      end

    if result == {:error, :negotiation_failed} do
      AdmissionCoordinator.begin_terminal_cleanup(identity.target.id, identity.runtime_generation)
    end

    result
  end

  @doc """
  Returns the current authorized, ready, nonterminal Call Attempt for the User.

  Discovery never creates a runtime, publishes a projection, or extends a
  ringing deadline. Overdue ringing attempts are omitted rather than timed out
  from this read. An apparently live attempt without a ready CallServer is
  reported as temporarily unavailable.
  """
  @spec current_call(term()) ::
          {:ok, map() | nil} | {:error, :unauthenticated | :temporarily_unavailable}
  def current_call(%Scope{user: %User{id: user_id}} = scope) do
    with {:ok, call_id} <- CallCoordinator.current_call_id(user_id) do
      discover_current_call(scope, user_id, call_id)
    end
  rescue
    Ecto.ConstraintError -> {:error, :temporarily_unavailable}
    Postgrex.Error -> {:error, :temporarily_unavailable}
  end

  def current_call(_scope), do: {:error, :unauthenticated}

  @doc false
  @spec peer_identity(term(), map()) ::
          {:ok, %{id: Ecto.UUID.t(), username: String.t()}}
          | {:error, :unauthenticated | :not_found}
  def peer_identity(%Scope{user: %User{id: user_id}}, projection) when is_map(projection) do
    with true <- participant_projection?(projection, user_id),
         peer_id when is_binary(peer_id) <- projection_peer_id(projection, user_id),
         %{id: _id, username: _username} = peer <-
           Repo.one(
             from user in User,
               where: user.id == ^peer_id,
               select: %{id: user.id, username: user.username}
           ) do
      {:ok, peer}
    else
      _missing_or_unauthorized -> {:error, :not_found}
    end
  end

  def peer_identity(_scope, _projection), do: {:error, :unauthenticated}

  @doc """
  Declines a ringing Call Attempt as its committed recipient.

  A repeated valid command returns the already committed `declined` outcome
  without writing again. Decline creates no Activity Item or Message.
  """
  @spec decline_call(term(), term()) :: {:ok, map()} | {:error, decline_error()}
  def decline_call(%Scope{user: %User{}} = scope, call_id) do
    with {:ok, call_id} <- Ecto.UUID.cast(call_id) do
      case commit_decline(scope, call_id) do
        {:ok, :declined, %CallAttempt{} = call_attempt} ->
          {:ok, project_committed_terminal(call_attempt, :call_declined, broadcast?: true)}

        {:ok, :already_terminal, %CallAttempt{} = call_attempt} ->
          {:ok, project_committed_terminal(call_attempt, :call_declined, broadcast?: false)}

        {:error, reason} ->
          {:error, normalize_decline_error(reason)}
      end
    else
      :error -> {:error, :not_found}
    end
  end

  def decline_call(_scope, _call_id), do: {:error, :unauthenticated}

  @doc """
  Cancels a Call Attempt as its committed caller.

  Cancelling a ringing attempt commits `cancelled` and inserts exactly one
  missed-call Activity Item for the recipient. A connecting attempt commits
  `cancelled` without Activity. Active attempts are stale. A repeated valid
  command returns the already committed terminal outcome without writing again.
  """
  @spec cancel_call(term(), term()) :: {:ok, map()} | {:error, cancel_error()}
  def cancel_call(scope, call_id), do: cancel_attempt(scope, call_id, false)

  @doc "Cancels through the selected browser owner once the Call has been accepted."
  @spec cancel_call(term(), term(), term()) :: {:ok, map()} | {:error, cancel_error()}
  def cancel_call(%Scope{user: %User{}} = scope, call_id, connection_id)
      when is_binary(connection_id) do
    case get_call(scope, call_id) do
      {:ok, %{state: :terminal}} ->
        cancel_call(scope, call_id)

      {:ok, _live} ->
        terminal_control_result(
          scope,
          call_id,
          CallServer.cancel(scope, call_id, connection_id),
          &cancel_call/2
        )

      error ->
        error
    end
  end

  def cancel_call(_scope, _call_id, _connection_id), do: {:error, :unauthenticated}

  @doc false
  def cancel_ringing_call(scope, call_id), do: cancel_attempt(scope, call_id, true)

  defp cancel_attempt(%Scope{user: %User{}} = scope, call_id, ringing_only?) do
    with {:ok, call_id} <- Ecto.UUID.cast(call_id) do
      case commit_cancel(scope, call_id, ringing_only?) do
        {:ok, :cancelled, %CallAttempt{} = call_attempt, activity_item} ->
          {:ok,
           project_committed_terminal(call_attempt, :call_cancelled,
             broadcast?: true,
             activity?: not is_nil(activity_item)
           )}

        {:ok, :already_terminal, %CallAttempt{} = call_attempt} ->
          {:ok,
           project_committed_terminal(call_attempt, :call_cancelled,
             broadcast?: false,
             activity?: false
           )}

        {:error, reason} ->
          {:error, normalize_cancel_error(reason)}
      end
    else
      :error -> {:error, :not_found}
    end
  rescue
    Ecto.ConstraintError -> {:error, :temporarily_unavailable}
  end

  defp cancel_attempt(_scope, _call_id, _ringing_only?), do: {:error, :unauthenticated}

  @doc """
  Accepts a ringing Call Attempt as its committed recipient.

  Acceptance commits `ringing -> connecting`, sets `accepted_at` once, and
  starts accepted-call execution on the owning CallServer. A repeated valid
  command returns the current committed outcome without rewriting
  `accepted_at` or scheduling a second runtime.
  """
  @spec accept_call(term(), term(), term()) :: {:ok, map()} | {:error, accept_error()}
  def accept_call(scope, call_id, answer_mode) do
    accept_call(scope, call_id, answer_mode, nil)
  end

  @doc false
  @spec accept_call(term(), term(), term(), Ecto.UUID.t() | nil) ::
          {:ok, map()} | {:error, accept_error()}
  def accept_call(%Scope{user: %User{}} = scope, call_id, answer_mode, connection_id) do
    with {:ok, call_id} <- Ecto.UUID.cast(call_id),
         {:ok, answer_mode} <- normalize_answer_mode(answer_mode),
         :ok <- available_answer_mode(scope, call_id, answer_mode) do
      case CallServer.claim_answer_mode(call_id, answer_mode, connection_id) do
        {:owner, claim_ref} ->
          accept_as_mode_claim_owner(scope, call_id, answer_mode, claim_ref)

        {:committed, committed_mode} ->
          accept_with_committed_mode(scope, call_id, answer_mode, committed_mode)

        {:reconcile, claim_ref, claimed_mode} ->
          reconcile_abandoned_answer_mode(
            scope,
            call_id,
            answer_mode,
            claim_ref,
            claimed_mode,
            connection_id
          )

        :retry ->
          accept_call(scope, call_id, answer_mode, connection_id)

        {:error, :temporarily_unavailable} ->
          {:error, :temporarily_unavailable}

        {:error, :not_found} ->
          accept_without_live_server(scope, call_id, answer_mode)
      end
    else
      :error -> {:error, :not_found}
      {:error, :invalid_answer_mode} -> {:error, :stale}
      {:error, reason} -> {:error, reason}
    end
  rescue
    Ecto.ConstraintError -> {:error, :temporarily_unavailable}
  end

  def accept_call(_scope, _call_id, _answer_mode, _connection_id), do: {:error, :unauthenticated}

  @doc """
  Leaves a connecting or active Call Attempt as either committed participant.

  Leaving while connecting commits `cancelled`. Leaving while active commits
  `ended`. Neither creates a missed-call Activity Item or Message.
  """
  @spec leave_call(term(), term()) :: {:ok, map()} | {:error, leave_error()}
  def leave_call(%Scope{user: %User{}} = scope, call_id) do
    with {:ok, call_id} <- Ecto.UUID.cast(call_id) do
      case commit_leave(scope, call_id) do
        {:ok, :left, %CallAttempt{} = call_attempt, event} ->
          {:ok, project_committed_terminal(call_attempt, event, broadcast?: true)}

        {:ok, :already_terminal, %CallAttempt{} = call_attempt} ->
          {:ok,
           project_committed_terminal(call_attempt, leave_terminal_event(call_attempt),
             broadcast?: false
           )}

        {:error, reason} ->
          {:error, normalize_leave_error(reason)}
      end
    else
      :error -> {:error, :not_found}
    end
  rescue
    Ecto.ConstraintError -> {:error, :temporarily_unavailable}
  end

  def leave_call(_scope, _call_id), do: {:error, :unauthenticated}

  @doc "Leaves through the exact selected browser owner registration."
  @spec leave_call(term(), term(), term()) :: {:ok, map()} | {:error, leave_error()}
  def leave_call(%Scope{user: %User{}} = scope, call_id, connection_id)
      when is_binary(connection_id) do
    case get_call(scope, call_id) do
      {:ok, %{state: :terminal}} ->
        leave_call(scope, call_id)

      {:ok, _live} ->
        terminal_control_result(
          scope,
          call_id,
          CallServer.leave(scope, call_id, connection_id),
          &leave_call/2
        )

      error ->
        error
    end
  end

  def leave_call(_scope, _call_id, _connection_id), do: {:error, :unauthenticated}

  # A concurrent terminal winner can retire the mailbox after scoped discovery.
  # Retry only already-committed terminal truth, never a live observer command.
  defp terminal_control_result(scope, call_id, {:error, :stale} = error, callback) do
    case get_call(scope, call_id) do
      {:ok, %{state: :terminal}} -> callback.(scope, call_id)
      _still_live_or_inaccessible -> error
    end
  end

  defp terminal_control_result(_scope, _call_id, result, _callback), do: result

  @doc false
  @spec expire_ringing_attempt(term()) ::
          {:ok, map()} | {:error, :not_found | :stale | :temporarily_unavailable}
  def expire_ringing_attempt(call_id) do
    with {:ok, call_id} <- Ecto.UUID.cast(call_id) do
      case commit_timeout(call_id) do
        {:ok, :timed_out, %CallAttempt{} = call_attempt, activity_item} ->
          {:ok,
           project_committed_terminal(call_attempt, :call_timed_out,
             broadcast?: true,
             activity?: not is_nil(activity_item)
           )}

        {:ok, :already_terminal, %CallAttempt{} = call_attempt} ->
          {:ok,
           project_committed_terminal(call_attempt, :call_timed_out,
             broadcast?: false,
             activity?: false
           )}

        {:ok, :still_ringing, %CallAttempt{} = call_attempt} ->
          {:ok, to_projection(call_attempt)}

        {:error, reason} ->
          {:error, normalize_command_error(reason)}
      end
    else
      :error -> {:error, :not_found}
    end
  rescue
    Ecto.ConstraintError -> {:error, :temporarily_unavailable}
  end

  @doc false
  @spec end_attempt_for_removed_friendship(term(), term()) ::
          {:ok, CallAttempt.t() | nil}
          | {:error, :not_found | :stale | :temporarily_unavailable}
  def end_attempt_for_removed_friendship(first_user_id, second_user_id) do
    with {:ok, first_user_id} <- Ecto.UUID.cast(first_user_id),
         {:ok, second_user_id} <- Ecto.UUID.cast(second_user_id),
         true <- first_user_id != second_user_id do
      {user_low_id, user_high_id} = canonical_user_pair(first_user_id, second_user_id)
      end_nonterminal_attempt_for_pair(user_low_id, user_high_id)
    else
      _invalid_pair -> {:error, :not_found}
    end
  rescue
    Ecto.ConstraintError -> {:error, :temporarily_unavailable}
    Postgrex.Error -> {:error, :temporarily_unavailable}
  end

  @doc false
  @spec project_committed_relationship_ended(Ecto.UUID.t()) :: map() | :ok
  def project_committed_relationship_ended(call_id) when is_binary(call_id) do
    case Repo.get(CallAttempt, call_id) do
      %CallAttempt{} = call_attempt ->
        project_committed_terminal(call_attempt, :call_relationship_ended, broadcast?: true)

      nil ->
        :ok
    end
  end

  @doc false
  @spec prune_safely_materialized_terminal_attempts() ::
          {:ok, %{deleted: non_neg_integer(), retained: non_neg_integer()}}
          | {:error, :temporarily_unavailable}
  def prune_safely_materialized_terminal_attempts do
    cutoff = DateTime.add(DateTime.utc_now(:microsecond), -@terminal_retention_days, :day)

    case Repo.transaction(fn ->
           ids = Enum.map(lock_prunable_terminal_attempts(cutoff), & &1.id)

           if ids == [] do
             0
           else
             {count, _meta} =
               Repo.delete_all(from call_attempt in CallAttempt, where: call_attempt.id in ^ids)

             count
           end
         end) do
      {:ok, deleted} ->
        {:ok,
         %{
           deleted: deleted,
           retained: count_unmaterialized_activity_gated_terminals(cutoff)
         }}

      {:error, reason} ->
        {:error, normalize_command_error(reason)}
    end
  rescue
    Ecto.ConstraintError -> {:error, :temporarily_unavailable}
    Postgrex.Error -> {:error, :temporarily_unavailable}
  end

  @doc false
  @spec recover_nonterminal_attempts() :: %{
          rebuild: [CallAttempt.t()],
          fail_closed: [CallAttempt.t()],
          admit_starts?: boolean()
        }
  def recover_nonterminal_attempts do
    attempts = list_nonterminal_attempts()
    {irreconcilable, reconcilable} = partition_irreconcilable_attempts(attempts)

    recovered =
      Enum.reduce(
        reconcilable,
        %{rebuild: [], admit_starts?: irreconcilable == []},
        &recover_boot_attempt/2
      )

    %{
      rebuild: Enum.reverse(recovered.rebuild),
      fail_closed: irreconcilable,
      admit_starts?: recovered.admit_starts?
    }
  end

  @doc false
  @spec reload_attempt_for_runtime(Ecto.UUID.t()) ::
          {:rebuild, CallAttempt.t()} | :released | :blocked
  def reload_attempt_for_runtime(call_id) do
    case Repo.get(CallAttempt, call_id) do
      nil ->
        :released

      %CallAttempt{state: :terminal} ->
        :released

      %CallAttempt{} = attempt ->
        if occupancy_conflict?(attempt) do
          :blocked
        else
          recover_runtime_attempt(attempt)
        end
    end
  end

  @doc false
  @spec commit_ringing_attempt(
          Scope.t(),
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          CallAttempt.media_intent()
        ) ::
          {:ok, :started, CallAttempt.t()}
          | {:ok, :converged, CallAttempt.t()}
          | {:error, atom()}
  def commit_ringing_attempt(
        %Scope{user: %User{id: caller_user_id}} = scope,
        direct_conversation_id,
        recipient_user_id,
        media_intent
      ) do
    case Repo.transaction(fn ->
           case Friendships.lock_accepted_friendship(scope, recipient_user_id) do
             :ok -> :ok
             {:error, reason} -> Repo.rollback(reason)
           end

           direct_conversation =
             lock_participant_direct_conversation!(
               direct_conversation_id,
               caller_user_id,
               recipient_user_id
             )

           case occupancy_decision(
                  direct_conversation.id,
                  caller_user_id,
                  recipient_user_id
                ) do
             {:converge, %CallAttempt{} = existing} ->
               {:converged, existing}

             :busy ->
               Repo.rollback(:busy)

             :free ->
               started_at = DateTime.utc_now(:microsecond)

               if rate_limited?(caller_user_id, recipient_user_id, started_at) do
                 Repo.rollback(:rate_limited)
               else
                 insert_ringing_attempt(
                   direct_conversation.id,
                   caller_user_id,
                   recipient_user_id,
                   media_intent,
                   started_at
                 )
               end
           end
         end) do
      {:ok, {:started, %CallAttempt{} = call_attempt}} -> {:ok, :started, call_attempt}
      {:ok, {:converged, %CallAttempt{} = call_attempt}} -> {:ok, :converged, call_attempt}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  @spec fail_closed_ringing_attempt(CallAttempt.t()) ::
          {:ok, CallAttempt.t()} | {:error, term()}
  def fail_closed_ringing_attempt(%CallAttempt{id: call_id}) do
    Repo.transaction(fn ->
      attempt = locked_call_attempt(Repo, call_id)

      cond do
        is_nil(attempt) ->
          Repo.rollback(:not_found)

        attempt.state != :ringing ->
          Repo.rollback(:stale)

        true ->
          attempt
          |> CallAttempt.fail_closed_changeset(DateTime.utc_now(:microsecond))
          |> Repo.update()
          |> case do
            {:ok, %CallAttempt{} = updated} -> updated
            {:error, reason} -> Repo.rollback(reason)
          end
      end
    end)
  end

  defp commit_decline(%Scope{user: %User{id: user_id}} = scope, call_id) do
    case Repo.transaction(fn ->
           # Lock only this Call Attempt. Later Friendship-removal work must take
           # Friendship then Conversation before this row, never the reverse.
           attempt = locked_call_attempt(Repo, call_id)

           cond do
             is_nil(attempt) ->
               Repo.rollback(:not_found)

             attempt.recipient_user_id != user_id ->
               Repo.rollback(:not_found)

             not Friendships.friends?(scope, attempt.caller_user_id) ->
               Repo.rollback(:not_found)

             attempt.state == :terminal ->
               {:already_terminal, attempt}

             attempt.state != :ringing ->
               Repo.rollback(:stale)

             true ->
               attempt
               |> CallAttempt.decline_changeset(DateTime.utc_now(:microsecond))
               |> Repo.update()
               |> case do
                 {:ok, %CallAttempt{} = updated} ->
                   {:declined, updated}

                 {:error, %Ecto.Changeset{} = changeset} ->
                   Repo.rollback(normalize_decline_error(changeset))
               end
           end
         end) do
      {:ok, {:declined, %CallAttempt{} = call_attempt}} ->
        {:ok, :declined, call_attempt}

      {:ok, {:already_terminal, %CallAttempt{} = call_attempt}} ->
        {:ok, :already_terminal, call_attempt}

      {:error, reason} ->
        {:error, normalize_decline_error(reason)}
    end
  end

  defp commit_cancel(%Scope{user: %User{id: user_id}} = scope, call_id, ringing_only?) do
    Multi.new()
    |> Multi.run(:locked_attempt, fn repo, _changes ->
      lock_caller_attempt(repo, scope, user_id, call_id)
    end)
    |> Multi.run(:cancelled_attempt, fn repo, %{locked_attempt: attempt} ->
      if ringing_only? and attempt.state == :connecting,
        do: {:error, :stale},
        else: apply_cancel(repo, attempt, DateTime.utc_now(:microsecond))
    end)
    |> Multi.run(:activity_item, fn repo, %{cancelled_attempt: result} ->
      maybe_insert_missed_call_activity(repo, result)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{cancelled_attempt: {:already_terminal, %CallAttempt{} = call_attempt}}} ->
        {:ok, :already_terminal, call_attempt}

      {:ok,
       %{
         cancelled_attempt: {:cancelled, _state, %CallAttempt{} = call_attempt},
         activity_item: activity_item
       }} ->
        {:ok, :cancelled, call_attempt, activity_item}

      {:error, _operation, reason, _changes} ->
        {:error, normalize_cancel_error(reason)}
    end
  end

  defp lock_caller_attempt(repo, scope, user_id, call_id) do
    attempt = locked_call_attempt(repo, call_id)

    cond do
      is_nil(attempt) ->
        {:error, :not_found}

      attempt.caller_user_id != user_id ->
        {:error, :not_found}

      not Friendships.friends?(scope, attempt.recipient_user_id) ->
        {:error, :not_found}

      true ->
        {:ok, attempt}
    end
  end

  defp apply_cancel(_repo, %CallAttempt{state: :terminal} = attempt, _ended_at) do
    {:ok, {:already_terminal, attempt}}
  end

  defp apply_cancel(_repo, %CallAttempt{state: :active}, _ended_at) do
    {:error, :stale}
  end

  defp apply_cancel(repo, %CallAttempt{state: state} = attempt, ended_at)
       when state in [:ringing, :connecting] do
    attempt
    |> CallAttempt.cancel_changeset(ended_at)
    |> repo.update()
    |> case do
      {:ok, %CallAttempt{} = updated} ->
        {:ok, {:cancelled, state, updated}}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, normalize_cancel_error(changeset)}
    end
  end

  defp commit_accept(%Scope{user: %User{id: user_id}} = scope, call_id, answer_mode) do
    case Repo.transaction(fn ->
           attempt = locked_call_attempt(Repo, call_id)

           cond do
             is_nil(attempt) ->
               Repo.rollback(:not_found)

             attempt.recipient_user_id != user_id ->
               Repo.rollback(:not_found)

             not Friendships.friends?(scope, attempt.caller_user_id) ->
               Repo.rollback(:not_found)

             not valid_answer_pair?(attempt.media_intent, answer_mode) ->
               Repo.rollback(:stale)

             attempt.state in [:connecting, :active, :terminal] ->
               {:already_current, attempt}

             attempt.state != :ringing ->
               Repo.rollback(:stale)

             ringing_overdue?(attempt) ->
               Repo.rollback(:stale)

             true ->
               attempt
               |> CallAttempt.accept_changeset(DateTime.utc_now(:microsecond))
               |> Repo.update()
               |> case do
                 {:ok, %CallAttempt{} = updated} ->
                   {:accepted, updated}

                 {:error, %Ecto.Changeset{} = changeset} ->
                   Repo.rollback(normalize_accept_error(changeset))
               end
           end
         end) do
      {:ok, {:accepted, %CallAttempt{} = call_attempt}} ->
        {:ok, :accepted, call_attempt}

      {:ok, {:already_current, %CallAttempt{} = call_attempt}} ->
        {:ok, :already_current, call_attempt}

      {:error, reason} ->
        {:error, normalize_accept_error(reason)}
    end
  end

  defp valid_answer_pair?(:audio, :audio), do: true
  defp valid_answer_pair?(:video, mode) when mode in [:audio, :video], do: true
  defp valid_answer_pair?(_media_intent, _answer_mode), do: false

  # Owner vs reconcile accept flows share the reserve→commit→release shape
  # but finalize differently (`commit`/`reject` vs `resolve`/`discard`), so
  # they stay duplicated rather than sharing a helper that would blur
  # terminal vs retryable semantics.
  defp accept_as_mode_claim_owner(scope, call_id, answer_mode, claim_ref) do
    case reserve_pair_for_accept(scope, call_id, answer_mode) do
      {:ok, reservation} ->
        run_pair_accept_hook()

        case commit_accept(scope, call_id, answer_mode) do
          {:ok, :accepted, %CallAttempt{} = call_attempt} ->
            :ok = CallServer.commit_answer_mode(call_id, claim_ref)
            {:ok, project_committed_connecting(call_attempt, answer_mode)}

          {:ok, :already_current, %CallAttempt{state: :terminal} = call_attempt} ->
            after_accept_reservation_release(call_id, reservation, claim_ref, fn ->
              :ok = CallServer.reject_answer_mode(call_id, claim_ref)
              {:ok, to_projection(call_attempt)}
            end)

          {:ok, :already_current, %CallAttempt{state: :connecting} = call_attempt} ->
            after_accept_reservation_release(call_id, reservation, claim_ref, fn ->
              :ok = CallServer.commit_answer_mode(call_id, claim_ref)
              {:ok, project_committed_connecting(call_attempt, answer_mode)}
            end)

          {:ok, :already_current, %CallAttempt{} = call_attempt} ->
            after_accept_reservation_release(call_id, reservation, claim_ref, fn ->
              :ok = CallServer.reject_answer_mode(call_id, claim_ref)
              {:ok, to_projection(call_attempt)}
            end)

          {:error, reason} ->
            after_accept_reservation_release(call_id, reservation, claim_ref, fn ->
              :ok = CallServer.reject_answer_mode(call_id, claim_ref)
              {:error, normalize_accept_error(reason)}
            end)
        end

      {:error, :no_reservation} ->
        # Preflight says the attempt is not reservable (already terminal,
        # not ringing, not friends). Fall through to the durable truth so a
        # lost race returns the committed outcome without a second switch.
        legacy_accept_as_owner(scope, call_id, answer_mode, claim_ref)

      {:error, {:direct_terminal, outcome}} when outcome in [:failed_capacity, :failed] ->
        # Reservation was refused for capacity or media reasons before any
        # connecting projection. Commit the terminal outcome directly from
        # ringing with the acceptance timestamp; never publish connecting.
        :ok = CallServer.commit_answer_mode(call_id, claim_ref)

        case commit_direct_failure(scope, call_id, outcome) do
          {:ok, :failed, %CallAttempt{} = call_attempt, event} ->
            {:ok, project_committed_terminal(call_attempt, event, broadcast?: true)}

          {:ok, :already_terminal, %CallAttempt{} = call_attempt} ->
            {:ok, to_projection(call_attempt)}

          {:ok, :already_current, %CallAttempt{state: :connecting} = call_attempt} ->
            {:ok, project_committed_connecting(call_attempt, answer_mode)}

          {:ok, :already_current, %CallAttempt{} = call_attempt} ->
            {:ok, to_projection(call_attempt)}

          {:error, reason} ->
            :ok = CallServer.reject_answer_mode(call_id, claim_ref)
            {:error, normalize_accept_error(reason)}
        end

      {:error, reason} ->
        :ok = CallServer.reject_answer_mode(call_id, claim_ref)
        {:error, normalize_accept_error(reason)}
    end
  end

  defp legacy_accept_as_owner(scope, call_id, answer_mode, claim_ref) do
    case commit_accept(scope, call_id, answer_mode) do
      {:ok, :accepted, %CallAttempt{} = call_attempt} ->
        :ok = CallServer.commit_answer_mode(call_id, claim_ref)
        {:ok, project_committed_connecting(call_attempt, answer_mode)}

      {:ok, :already_current, %CallAttempt{state: :terminal} = call_attempt} ->
        :ok = CallServer.reject_answer_mode(call_id, claim_ref)
        {:ok, to_projection(call_attempt)}

      {:ok, :already_current, %CallAttempt{state: :connecting} = call_attempt} ->
        :ok = CallServer.commit_answer_mode(call_id, claim_ref)
        {:ok, project_committed_connecting(call_attempt, answer_mode)}

      {:ok, :already_current, %CallAttempt{} = call_attempt} ->
        :ok = CallServer.reject_answer_mode(call_id, claim_ref)
        {:ok, to_projection(call_attempt)}

      {:error, reason} ->
        :ok = CallServer.reject_answer_mode(call_id, claim_ref)
        {:error, normalize_accept_error(reason)}
    end
  end

  defp after_accept_reservation_release(call_id, reservation, claim_ref, on_released) do
    case release_accept_reservation(call_id, reservation.generation) do
      :ok ->
        on_released.()

      {:error, :temporarily_unavailable} = error ->
        :ok = CallServer.reject_answer_mode(call_id, claim_ref)
        error
    end
  end

  defp release_accept_reservation(call_id, generation) do
    case AdmissionCoordinator.release_reservation(call_id, generation) do
      :ok -> :ok
      # Expiry or another exact cleanup already won. Never retry against
      # a newer generation; every other failure remains retryable uncertainty.
      {:error, :stale_reservation} -> :ok
      {:error, _reason} -> {:error, :temporarily_unavailable}
    end
  catch
    :exit, _reason -> {:error, :temporarily_unavailable}
  end

  # Test-only deterministic seam for the lost-race boundary. Production
  # default is `nil` (inert). Tests may set
  # `Application.put_env(:discord_clone, :pair_accept_between_reserve_and_commit, fun)`
  # where `fun` is a zero-arity function running a real durable command
  # (decline, cancel, timeout, or friendship removal) between reservation and
  # the short durable transaction.
  @doc false
  defp run_pair_accept_hook do
    case Application.get_env(:discord_clone, :pair_accept_between_reserve_and_commit) do
      nil -> :ok
      fun when is_function(fun, 0) -> fun.()
      {mod, fun, args} -> apply(mod, fun, args)
    end
  end

  @doc false
  defp reserve_pair_for_accept(%Scope{user: %User{id: user_id}} = scope, call_id, answer_mode) do
    # Pair admission only runs behind the real adapter. Scripted/Fake test
    # runtimes (via `with_accepted_runtime`) exercise the pre-pair answer-mode
    # and runtime-result machinery without media; they must not reserve.
    if pair_admission_enabled?() do
      case Repo.get(CallAttempt, call_id) do
        nil ->
          {:error, :no_reservation}

        %CallAttempt{state: :terminal} ->
          {:error, :no_reservation}

        %CallAttempt{state: state} when state in [:connecting, :active] ->
          # A concurrent accept already committed connecting/active. Return the
          # current result through the existing claim machinery; never a second
          # reservation or switch.
          {:error, :no_reservation}

        %CallAttempt{state: :ringing} = attempt ->
          # Validate cheap durable guards before any slow target work so
          # invalid accepts never start a target or reserve.
          cond do
            attempt.recipient_user_id != user_id ->
              {:error, :no_reservation}

            not valid_answer_pair?(attempt.media_intent, answer_mode) ->
              {:error, :no_reservation}

            not friends_with_other_participant?(scope, attempt, user_id) ->
              {:error, :no_reservation}

            ringing_overdue?(attempt) ->
              {:error, :no_reservation}

            true ->
              reserve_ringing_pair(attempt, user_id)
          end

        _ ->
          {:error, :no_reservation}
      end
    else
      {:error, :no_reservation}
    end
  rescue
    Postgrex.Error -> {:error, :temporarily_unavailable}
    DBConnection.ConnectionError -> {:error, :temporarily_unavailable}
  catch
    :exit, _reason -> {:error, :temporarily_unavailable}
  end

  defp pair_admission_enabled? do
    Application.get_env(
      :discord_clone,
      :accepted_call_runtime,
      DiscordClone.Calls.PairAdmissionRuntime
    ) == DiscordClone.Calls.PairAdmissionRuntime
  end

  defp reserve_ringing_pair(
         %CallAttempt{id: call_id, caller_user_id: caller_id, recipient_user_id: recipient_id},
         _user_id
       ) do
    with :ok <- ensure_direct_call_target_started(call_id),
         {:ok, first_prior} <- fetch_current_identity(caller_id),
         {:ok, second_prior} <- fetch_current_identity(recipient_id) do
      first = {caller_id, first_prior}
      second = {recipient_id, second_prior}

      case AdmissionCoordinator.reserve_pair(call_id, first, second) do
        {:ok, reservation} ->
          {:ok, reservation}

        {:error, reason} when reason in [:not_found, :stale, :not_friends, :invalid_pair] ->
          {:error, :no_reservation}

        {:error, %{reason: :deployment_full}} ->
          {:error, {:direct_terminal, :failed_capacity}}

        {:error, %{reason: :stale_prior}} ->
          # Prior Voice identity moved between our read and reserve. The
          # durable attempt is still ringing; fail closed without moving
          # either side. A retry will read fresh priors.
          {:error, {:direct_terminal, :failed}}

        {:error, %{reason: :reservation_conflict, same_call?: true}} ->
          # A second concurrent accept while ringing+reserved must not commit
          # durable `failed` and kill the winner. Fall through to durable
          # truth; the winner still holds the reservation.
          {:error, :no_reservation}

        {:error, %{reason: :reservation_conflict, same_call?: false}} ->
          # Another active, reserved, or cleaning Call owns the support cap.
          # Reject before connecting and preserve both exact prior Voices.
          {:error, {:direct_terminal, :failed_capacity}}

        {:error, %{reason: _other}} ->
          # Fail closed retryable, never a terminal fact. Covers
          # `:target_unavailable` and any future held-reservation signal.
          {:error, :temporarily_unavailable}

        {:error, reason}
        when reason in [:recovering, :recovery_timeout, :temporarily_unavailable] ->
          # Coordinator uncertainty or transient outage: retryable, never a
          # terminal fact. The caller may retry acceptance.
          {:error, :temporarily_unavailable}

        {:error, _reason} ->
          {:error, :temporarily_unavailable}
      end
    else
      {:error, :no_reservation} -> {:error, :no_reservation}
      {:error, {:direct_terminal, _} = terminal} -> {:error, terminal}
      {:error, :temporarily_unavailable} -> {:error, :temporarily_unavailable}
      {:error, reason} -> {:error, normalize_accept_error(reason)}
    end
  catch
    :exit, _reason -> {:error, :temporarily_unavailable}
  end

  defp fetch_current_identity(nil), do: {:ok, nil}

  defp fetch_current_identity(user_id) do
    {:ok, AdmissionCoordinator.current_identity(user_id)}
  catch
    :exit, _reason -> {:error, :temporarily_unavailable}
  end

  # Narrow rename: this ensures the fake Direct Call target runtime, not any
  # Voice target. Call IDs are unique so starting here cannot touch a new pair.
  defp ensure_direct_call_target_started(call_id) do
    case fetch_call_target_snapshot(call_id) do
      {:ok, %{status: :ready}} ->
        :ok

      {:ok, nil} ->
        start_call_target(call_id)

      {:ok, %{status: :startup_cleaning}} ->
        {:error, :temporarily_unavailable}

      {:ok, _} ->
        {:error, {:direct_terminal, :failed}}

      {:error, :temporarily_unavailable} ->
        {:error, :temporarily_unavailable}
    end
  end

  defp fetch_call_target_snapshot(call_id) do
    {:ok, AdmissionCoordinator.call_target_snapshot(call_id)}
  catch
    :exit, _reason -> {:error, :temporarily_unavailable}
  end

  defp start_call_target(call_id) do
    case DirectCallTarget.start(call_id) do
      {:ok, _pid} ->
        :ok

      {:error, reason}
      when reason in [:recovering, :recovery_timeout, :temporarily_unavailable, :unavailable] ->
        {:error, :temporarily_unavailable}

      {:error, _reason} ->
        {:error, {:direct_terminal, :failed}}
    end
  catch
    :exit, _reason -> {:error, :temporarily_unavailable}
  end

  @doc false
  defp commit_direct_failure(%Scope{user: %User{id: user_id}} = scope, call_id, outcome)
       when outcome in [:failed_capacity, :failed] do
    case Repo.transaction(fn ->
           attempt = locked_call_attempt(Repo, call_id)

           cond do
             is_nil(attempt) ->
               Repo.rollback(:not_found)

             attempt.state == :terminal ->
               {:already_terminal, attempt}

             attempt.state in [:connecting, :active] ->
               {:already_current, attempt}

             attempt.state != :ringing ->
               Repo.rollback(:stale)

             attempt.recipient_user_id != user_id ->
               Repo.rollback(:not_found)

             not friends_with_other_participant?(scope, attempt, user_id) ->
               Repo.rollback(:not_found)

             true ->
               now = DateTime.utc_now(:microsecond)

               attempt
               |> CallAttempt.accept_failed_changeset(outcome, now, now)
               |> Repo.update()
               |> case do
                 {:ok, %CallAttempt{} = updated} ->
                   {:failed, updated, runtime_failure_event(outcome)}

                 {:error, %Ecto.Changeset{} = changeset} ->
                   Repo.rollback(normalize_command_error(changeset))
               end
           end
         end) do
      {:ok, {:failed, %CallAttempt{} = call_attempt, event}} ->
        {:ok, :failed, call_attempt, event}

      {:ok, {:already_terminal, %CallAttempt{} = call_attempt}} ->
        {:ok, :already_terminal, call_attempt}

      {:ok, {:already_current, %CallAttempt{} = call_attempt}} ->
        {:ok, :already_current, call_attempt}

      {:error, reason} ->
        {:error, normalize_command_error(reason)}
    end
  end

  defp accept_with_committed_mode(scope, call_id, answer_mode, committed_mode) do
    case commit_accept(scope, call_id, answer_mode) do
      {:ok, :already_current, %CallAttempt{state: :connecting} = call_attempt} ->
        {:ok, project_committed_connecting(call_attempt, committed_mode)}

      {:ok, :already_current, %CallAttempt{state: :active} = call_attempt} ->
        {:ok, call_attempt |> to_projection() |> with_answer_mode(committed_mode)}

      {:ok, :already_current, %CallAttempt{} = call_attempt} ->
        {:ok, to_projection(call_attempt)}

      {:ok, :accepted, %CallAttempt{} = call_attempt} ->
        {:ok, project_committed_connecting(call_attempt, committed_mode)}

      {:error, reason} ->
        {:error, normalize_accept_error(reason)}
    end
  end

  defp reconcile_abandoned_answer_mode(
         scope,
         call_id,
         requested_mode,
         claim_ref,
         claimed_mode,
         connection_id
       ) do
    with {:ok, candidate_mode} <-
           prepare_reconciled_answer_mode(
             scope,
             call_id,
             requested_mode,
             claim_ref,
             claimed_mode,
             connection_id
           ) do
      reconcile_answer_mode_commit(scope, call_id, requested_mode, claim_ref, candidate_mode)
    else
      {:error, reason} ->
        :ok = CallServer.reject_answer_mode(call_id, claim_ref)
        {:error, normalize_accept_error(reason)}
    end
  end

  defp prepare_reconciled_answer_mode(
         %Scope{user: %User{id: user_id}} = scope,
         call_id,
         requested_mode,
         claim_ref,
         claimed_mode,
         connection_id
       ) do
    case participant_call_attempt(call_id, user_id) do
      %CallAttempt{} = attempt ->
        cond do
          attempt.recipient_user_id != user_id ->
            {:error, :not_found}

          not friends_with_other_participant?(scope, attempt, user_id) ->
            {:error, :not_found}

          not valid_answer_pair?(attempt.media_intent, requested_mode) ->
            {:error, :stale}

          attempt.state == :ringing ->
            # The original claimant abandoned before committing, so this
            # reconciling connection becomes the first valid accepting one.
            :ok =
              CallServer.update_answer_mode_claim(
                call_id,
                claim_ref,
                requested_mode,
                connection_id
              )

            {:ok, requested_mode}

          true ->
            {:ok, claimed_mode}
        end

      nil ->
        {:error, :not_found}
    end
  end

  defp reconcile_answer_mode_commit(
         scope,
         call_id,
         requested_mode,
         claim_ref,
         candidate_mode
       ) do
    case reserve_pair_for_accept(scope, call_id, requested_mode) do
      {:ok, reservation} ->
        run_pair_accept_hook()

        commit_reconciled_pair(
          scope,
          call_id,
          requested_mode,
          claim_ref,
          candidate_mode,
          reservation
        )

      {:error, :no_reservation} ->
        legacy_reconcile_commit(scope, call_id, requested_mode, claim_ref, candidate_mode)

      {:error, {:direct_terminal, outcome}} when outcome in [:failed_capacity, :failed] ->
        commit_reconciled_direct_terminal(scope, call_id, claim_ref, candidate_mode, outcome)

      {:error, reason} ->
        :ok = CallServer.reject_answer_mode(call_id, claim_ref)
        {:error, normalize_accept_error(reason)}
    end
  end

  defp commit_reconciled_pair(
         scope,
         call_id,
         requested_mode,
         claim_ref,
         candidate_mode,
         reservation
       ) do
    case commit_accept(scope, call_id, requested_mode) do
      {:ok, :accepted, %CallAttempt{} = call_attempt} ->
        :ok = CallServer.resolve_answer_mode(call_id, claim_ref, candidate_mode)
        {:ok, project_committed_connecting(call_attempt, candidate_mode)}

      {:ok, :already_current, %CallAttempt{state: :terminal} = call_attempt} ->
        after_accept_reservation_release(call_id, reservation, claim_ref, fn ->
          :ok = CallServer.discard_answer_mode(call_id, claim_ref)
          {:ok, to_projection(call_attempt)}
        end)

      {:ok, :already_current, %CallAttempt{state: :connecting} = call_attempt} ->
        after_accept_reservation_release(call_id, reservation, claim_ref, fn ->
          :ok = CallServer.resolve_answer_mode(call_id, claim_ref, candidate_mode)
          {:ok, project_committed_connecting(call_attempt, candidate_mode)}
        end)

      {:ok, :already_current, %CallAttempt{state: :active} = call_attempt} ->
        after_accept_reservation_release(call_id, reservation, claim_ref, fn ->
          :ok = CallServer.resolve_answer_mode(call_id, claim_ref, candidate_mode)
          {:ok, call_attempt |> to_projection() |> with_answer_mode(candidate_mode)}
        end)

      {:ok, :already_current, %CallAttempt{} = call_attempt} ->
        after_accept_reservation_release(call_id, reservation, claim_ref, fn ->
          :ok = CallServer.discard_answer_mode(call_id, claim_ref)
          {:ok, to_projection(call_attempt)}
        end)

      {:error, reason} ->
        after_accept_reservation_release(call_id, reservation, claim_ref, fn ->
          :ok = CallServer.reject_answer_mode(call_id, claim_ref)
          {:error, normalize_accept_error(reason)}
        end)
    end
  end

  defp commit_reconciled_direct_terminal(scope, call_id, claim_ref, candidate_mode, outcome) do
    :ok = CallServer.resolve_answer_mode(call_id, claim_ref, candidate_mode)

    case commit_direct_failure(scope, call_id, outcome) do
      {:ok, :failed, %CallAttempt{} = call_attempt, event} ->
        {:ok, project_committed_terminal(call_attempt, event, broadcast?: true)}

      {:ok, :already_terminal, %CallAttempt{} = call_attempt} ->
        {:ok, to_projection(call_attempt)}

      {:ok, :already_current, %CallAttempt{state: :connecting} = call_attempt} ->
        {:ok, project_committed_connecting(call_attempt, candidate_mode)}

      {:ok, :already_current, %CallAttempt{} = call_attempt} ->
        {:ok, to_projection(call_attempt)}

      {:error, reason} ->
        :ok = CallServer.reject_answer_mode(call_id, claim_ref)
        {:error, normalize_accept_error(reason)}
    end
  end

  defp legacy_reconcile_commit(scope, call_id, requested_mode, claim_ref, candidate_mode) do
    case commit_accept(scope, call_id, requested_mode) do
      {:ok, :accepted, %CallAttempt{} = call_attempt} ->
        :ok = CallServer.resolve_answer_mode(call_id, claim_ref, candidate_mode)
        {:ok, project_committed_connecting(call_attempt, candidate_mode)}

      {:ok, :already_current, %CallAttempt{state: :connecting} = call_attempt} ->
        :ok = CallServer.resolve_answer_mode(call_id, claim_ref, candidate_mode)
        {:ok, project_committed_connecting(call_attempt, candidate_mode)}

      {:ok, :already_current, %CallAttempt{state: :active} = call_attempt} ->
        :ok = CallServer.resolve_answer_mode(call_id, claim_ref, candidate_mode)
        {:ok, call_attempt |> to_projection() |> with_answer_mode(candidate_mode)}

      {:ok, :already_current, %CallAttempt{} = call_attempt} ->
        :ok = CallServer.discard_answer_mode(call_id, claim_ref)
        {:ok, to_projection(call_attempt)}

      {:error, reason} ->
        :ok = CallServer.reject_answer_mode(call_id, claim_ref)
        {:error, normalize_accept_error(reason)}
    end
  end

  defp accept_without_live_server(scope, call_id, answer_mode) do
    case commit_accept(scope, call_id, answer_mode) do
      {:ok, :already_current, %CallAttempt{state: :terminal} = call_attempt} ->
        {:ok, to_projection(call_attempt)}

      {:ok, :accepted, %CallAttempt{} = call_attempt} ->
        {:ok, fail_closed_accepted_attempt(call_attempt.id)}

      {:ok, :already_current, _call_attempt} ->
        {:error, :temporarily_unavailable}

      {:error, reason} ->
        {:error, normalize_accept_error(reason)}
    end
  end

  defp project_committed_connecting(%CallAttempt{} = call_attempt, answer_mode) do
    case CallServer.begin_accepted_call(call_attempt, answer_mode) do
      {:ok, projection} -> projection
      {:error, _reason} -> fail_closed_accepted_attempt(call_attempt.id)
    end
  end

  defp commit_leave(%Scope{user: %User{id: user_id}} = scope, call_id) do
    case Repo.transaction(fn ->
           attempt = locked_call_attempt(Repo, call_id)

           cond do
             is_nil(attempt) ->
               Repo.rollback(:not_found)

             not participant?(attempt, user_id) ->
               Repo.rollback(:not_found)

             not friends_with_other_participant?(scope, attempt, user_id) ->
               Repo.rollback(:not_found)

             attempt.state == :terminal ->
               {:already_terminal, attempt}

             attempt.state == :connecting ->
               leave_connecting(attempt)

             attempt.state == :active ->
               leave_active(attempt)

             true ->
               Repo.rollback(:stale)
           end
         end) do
      {:ok, {:left, %CallAttempt{} = call_attempt, event}} ->
        {:ok, :left, call_attempt, event}

      {:ok, {:already_terminal, %CallAttempt{} = call_attempt}} ->
        {:ok, :already_terminal, call_attempt}

      {:error, reason} ->
        {:error, normalize_leave_error(reason)}
    end
  end

  defp leave_connecting(%CallAttempt{} = attempt) do
    AdmissionCoordinator.begin_terminal_cleanup(attempt.id)

    attempt
    |> CallAttempt.cancel_changeset(DateTime.utc_now(:microsecond))
    |> Repo.update()
    |> case do
      {:ok, %CallAttempt{} = updated} ->
        {:left, updated, :call_cancelled}

      {:error, %Ecto.Changeset{} = changeset} ->
        Repo.rollback(normalize_leave_error(changeset))
    end
  end

  defp leave_active(%CallAttempt{} = attempt) do
    AdmissionCoordinator.begin_terminal_cleanup(attempt.id)

    attempt
    |> CallAttempt.ended_changeset(DateTime.utc_now(:microsecond))
    |> Repo.update()
    |> case do
      {:ok, %CallAttempt{} = updated} ->
        {:left, updated, :call_completed}

      {:error, %Ecto.Changeset{} = changeset} ->
        Repo.rollback(normalize_leave_error(changeset))
    end
  end

  defp commit_activate(call_id, runtime) do
    case Repo.transaction(fn ->
           attempt = locked_call_attempt(Repo, call_id)

           cond do
             is_nil(attempt) ->
               Repo.rollback(:not_found)

             attempt.state == :terminal ->
               {:already_terminal, attempt}

             attempt.state == :active ->
               {:already_active, attempt}

             attempt.state != :connecting ->
               Repo.rollback(:stale)

             true ->
               authorize_activation!(call_id, runtime)

               attempt
               |> CallAttempt.activate_changeset()
               |> Repo.update()
               |> case do
                 {:ok, %CallAttempt{} = updated} ->
                   authorize_activation!(call_id, runtime)
                   {:activated, updated}

                 {:error, %Ecto.Changeset{} = changeset} ->
                   Repo.rollback(normalize_command_error(changeset))
               end
           end
         end) do
      {:ok, {:activated, %CallAttempt{} = call_attempt}} ->
        {:ok, :activated, call_attempt}

      {:ok, {:already_active, %CallAttempt{} = call_attempt}} ->
        {:ok, :already_active, call_attempt}

      {:ok, {:already_terminal, %CallAttempt{} = call_attempt}} ->
        {:ok, :already_terminal, call_attempt}

      {:error, reason} ->
        {:error, normalize_command_error(reason)}
    end
  end

  defp authorize_activation!(_call_id, nil), do: :ok

  defp authorize_activation!(call_id, {:real, generation}) do
    # Recheck after locking the durable attempt: a queued snapshot may have
    # lost readiness while activation waited for a competing command.
    with {:ok, deadline} <- AdmissionCoordinator.call_activation_deadline(call_id, generation),
         true <- System.monotonic_time(:millisecond) < deadline do
      :ok
    else
      _ -> Repo.rollback(:stale)
    end
  end

  defp commit_runtime_failure(call_id, outcome) do
    case Repo.transaction(fn ->
           attempt = locked_call_attempt(Repo, call_id)

           cond do
             is_nil(attempt) ->
               Repo.rollback(:not_found)

             attempt.state == :terminal ->
               {:already_terminal, attempt}

             attempt.state != :connecting ->
               Repo.rollback(:stale)

             true ->
               attempt
               |> runtime_failure_changeset(outcome, DateTime.utc_now(:microsecond))
               |> Repo.update()
               |> case do
                 {:ok, %CallAttempt{} = updated} ->
                   {:failed, updated}

                 {:error, %Ecto.Changeset{} = changeset} ->
                   Repo.rollback(normalize_command_error(changeset))
               end
           end
         end) do
      {:ok, {:failed, %CallAttempt{} = call_attempt}} ->
        {:ok, :failed, call_attempt}

      {:ok, {:already_terminal, %CallAttempt{} = call_attempt}} ->
        {:ok, :already_terminal, call_attempt}

      {:error, reason} ->
        {:error, normalize_command_error(reason)}
    end
  end

  defp runtime_failure_changeset(attempt, :failed_capacity, ended_at) do
    CallAttempt.failed_capacity_changeset(attempt, ended_at)
  end

  defp runtime_failure_changeset(attempt, :failed, ended_at) do
    CallAttempt.fail_closed_changeset(attempt, ended_at)
  end

  defp fail_closed_accepted_attempt(call_id) do
    case commit_runtime_failure(call_id, :failed) do
      {:ok, :failed, %CallAttempt{} = call_attempt} ->
        project_committed_terminal(call_attempt, :call_failed, broadcast?: true)

      {:ok, :already_terminal, %CallAttempt{} = call_attempt} ->
        to_projection(call_attempt)

      {:error, _reason} ->
        case interrupt_attempt(call_id) do
          {:ok, projection} -> projection
          {:error, _} -> to_projection(Repo.get!(CallAttempt, call_id))
        end
    end
  end

  @doc false
  # Coordinator-owned two-sided check for restart reconciliation; UI uses
  # scoped `get_call/2`/`accept_call/4`. Reuses the existing `interrupted`
  # outcome (no missed Activity Item, no resume) after the coordinator retires
  # surviving fake targets. Media is already retired under captured identity;
  # projecting settlement must not discover and remove a replacement target.
  # Idempotent: already-terminal stays terminal.
  @spec interrupt_call_for_coordinator_restart(term()) ::
          {:ok, map()} | {:error, :not_found | :stale | :temporarily_unavailable}
  def interrupt_call_for_coordinator_restart(call_id) do
    with {:ok, call_id} <- Ecto.UUID.cast(call_id) do
      case commit_interrupt(call_id) do
        {:ok, :interrupted, %CallAttempt{} = call_attempt} ->
          {:ok,
           project_committed_terminal(call_attempt, :call_interrupted,
             broadcast?: true,
             cleanup_media?: false
           )}

        {:ok, :already_terminal, %CallAttempt{} = call_attempt} ->
          {:ok,
           project_committed_terminal(call_attempt, :call_interrupted,
             broadcast?: false,
             cleanup_media?: false
           )}

        {:error, reason} ->
          {:error, normalize_command_error(reason)}
      end
    else
      :error -> {:error, :not_found}
    end
  rescue
    Ecto.ConstraintError -> {:error, :temporarily_unavailable}
  end

  @doc false
  # Coordinator-owned two-sided check; UI uses scoped `get_call/2`/`accept_call/4`.
  @spec fail_call_for_media_loss(term()) ::
          {:ok, map()} | {:error, :not_found | :stale | :temporarily_unavailable}
  def fail_call_for_media_loss(call_id) do
    with {:ok, call_id} <- Ecto.UUID.cast(call_id) do
      AdmissionCoordinator.begin_terminal_cleanup(call_id)

      case commit_media_failure(call_id) do
        {:ok, :failed, %CallAttempt{} = call_attempt} ->
          {:ok, project_committed_terminal(call_attempt, :call_failed, broadcast?: true)}

        {:ok, :already_terminal, %CallAttempt{} = call_attempt} ->
          {:ok, project_committed_terminal(call_attempt, :call_failed, broadcast?: false)}

        {:error, reason} ->
          {:error, normalize_command_error(reason)}
      end
    else
      :error -> {:error, :not_found}
    end
  rescue
    Ecto.ConstraintError -> {:error, :temporarily_unavailable}
  end

  @doc false
  # Scope-less reverse-switch eligibility for a Voice join from an active Call.
  # Verifies the exact durable participant pair, current friendship, and active
  # state without creating runtime or publishing. Connecting/reservation work
  # is retryable; terminal/missing is stale so the caller falls back to the
  # normal Voice path without resurrecting media.
  @spec voice_switch_eligible?(term(), term()) ::
          :ok | {:error, :retryable | :not_found | :stale | :temporarily_unavailable}
  def voice_switch_eligible?(call_id, user_id) do
    with {:ok, call_id} <- Ecto.UUID.cast(call_id),
         {:ok, user_id} <- Ecto.UUID.cast(user_id),
         %CallAttempt{} = attempt <- Repo.get(CallAttempt, call_id),
         true <- participant?(attempt, user_id),
         other_id when is_binary(other_id) <- other_user_id(attempt, user_id),
         true <- Friendships.friends_between?(user_id, other_id) do
      cond do
        attempt.state == :active -> :ok
        attempt.state in [:connecting, :ringing] -> {:error, :retryable}
        true -> {:error, :stale}
      end
    else
      _ -> {:error, :not_found}
    end
  rescue
    Ecto.ConstraintError -> {:error, :temporarily_unavailable}
    Postgrex.Error -> {:error, :retryable}
    DBConnection.ConnectionError -> {:error, :retryable}
  end

  @doc false
  # Commits `active -> ended` for a reverse Voice switch in a short
  # transaction, then funnels through the Ticket 08 terminal path (pair
  # cleanup before `:call_completed` broadcast). Never holds a row lock
  # across room work; the coordinator destination reservation is held by the
  # caller outside this transaction. Already-terminal callers are stale so
  # the switch falls back to normal Voice admission without resurrection.
  @spec end_active_call_for_voice_switch(term(), term()) ::
          {:ok, map()} | {:error, :retryable | :not_found | :stale | :temporarily_unavailable}
  def end_active_call_for_voice_switch(call_id, user_id) do
    with {:ok, call_id} <- Ecto.UUID.cast(call_id),
         {:ok, user_id} <- Ecto.UUID.cast(user_id) do
      case commit_voice_switch_leave(call_id, user_id) do
        {:ok, :left, %CallAttempt{} = call_attempt, _event} ->
          {:ok, project_committed_terminal(call_attempt, :call_completed, broadcast?: true)}

        {:ok, :already_terminal, %CallAttempt{}} ->
          {:error, :stale}

        {:error, :retryable} ->
          {:error, :retryable}

        {:error, reason} ->
          {:error, normalize_command_error(reason)}
      end
    else
      :error -> {:error, :not_found}
    end
  rescue
    Ecto.ConstraintError -> {:error, :temporarily_unavailable}
  end

  # Intentionally diverges from `commit_leave/2`: connecting is retryable
  # (never cancels half a Call) and friendship is scope-less
  # (`friends_between?/2`) for the coordinator's two-sided switch. Reuses
  # `leave_active/1` for the `active -> ended` transition.
  defp commit_voice_switch_leave(call_id, user_id) do
    case Repo.transaction(fn ->
           with %CallAttempt{} = attempt <- locked_call_attempt(Repo, call_id),
                true <- participant?(attempt, user_id),
                true <- voice_switch_friends?(attempt, user_id) do
             switch_leave_transition(attempt)
           else
             nil -> Repo.rollback(:not_found)
             false -> Repo.rollback(:not_found)
           end
         end) do
      {:ok, {:left, %CallAttempt{} = call_attempt, event}} ->
        {:ok, :left, call_attempt, event}

      {:ok, {:already_terminal, %CallAttempt{} = call_attempt}} ->
        {:ok, :already_terminal, call_attempt}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp switch_leave_transition(%CallAttempt{state: :terminal} = attempt),
    do: {:already_terminal, attempt}

  defp switch_leave_transition(%CallAttempt{state: :connecting}),
    do: Repo.rollback(:retryable)

  defp switch_leave_transition(%CallAttempt{state: :active} = attempt) do
    case leave_active(attempt) do
      {:left, updated, event} -> {:left, updated, event}
      _ -> Repo.rollback(:temporarily_unavailable)
    end
  end

  defp switch_leave_transition(%CallAttempt{}), do: Repo.rollback(:stale)

  defp voice_switch_friends?(%CallAttempt{} = attempt, user_id) do
    case other_user_id(attempt, user_id) do
      other_id when is_binary(other_id) -> Friendships.friends_between?(user_id, other_id)
      nil -> false
    end
  end

  defp commit_media_failure(call_id) do
    case Repo.transaction(fn ->
           attempt = locked_call_attempt(Repo, call_id)

           cond do
             is_nil(attempt) ->
               Repo.rollback(:not_found)

             attempt.state == :terminal ->
               {:already_terminal, attempt}

             attempt.state not in [:connecting, :active] ->
               Repo.rollback(:stale)

             true ->
               attempt
               |> CallAttempt.fail_closed_changeset(DateTime.utc_now(:microsecond))
               |> Repo.update()
               |> case do
                 {:ok, %CallAttempt{} = updated} ->
                   {:failed, updated}

                 {:error, %Ecto.Changeset{} = changeset} ->
                   Repo.rollback(normalize_command_error(changeset))
               end
           end
         end) do
      {:ok, {:failed, %CallAttempt{} = call_attempt}} ->
        {:ok, :failed, call_attempt}

      {:ok, {:already_terminal, %CallAttempt{} = call_attempt}} ->
        {:ok, :already_terminal, call_attempt}

      {:error, reason} ->
        {:error, normalize_command_error(reason)}
    end
  end

  defp participant?(%CallAttempt{} = attempt, user_id) do
    user_id in [attempt.caller_user_id, attempt.recipient_user_id]
  end

  defp friends_with_other_participant?(scope, attempt, user_id) do
    case other_user_id(attempt, user_id) do
      other_user_id when is_binary(other_user_id) -> Friendships.friends?(scope, other_user_id)
      nil -> false
    end
  end

  defp leave_terminal_event(%CallAttempt{terminal_outcome: :ended}), do: :call_completed
  defp leave_terminal_event(%CallAttempt{terminal_outcome: :cancelled}), do: :call_cancelled

  defp leave_terminal_event(%CallAttempt{terminal_outcome: :failed_capacity}),
    do: :call_failed_capacity

  defp leave_terminal_event(%CallAttempt{terminal_outcome: :failed}), do: :call_failed
  defp leave_terminal_event(%CallAttempt{terminal_outcome: :interrupted}), do: :call_interrupted

  defp leave_terminal_event(%CallAttempt{terminal_outcome: :relationship_ended}),
    do: :call_relationship_ended

  defp leave_terminal_event(%CallAttempt{terminal_outcome: :declined}), do: :call_declined
  defp leave_terminal_event(%CallAttempt{terminal_outcome: :timed_out}), do: :call_timed_out
  defp leave_terminal_event(%CallAttempt{}), do: :call_cancelled

  defp runtime_failure_event(:failed_capacity), do: :call_failed_capacity
  defp runtime_failure_event(:failed), do: :call_failed

  defp commit_timeout(call_id) do
    Multi.new()
    |> Multi.run(:locked_attempt, fn repo, _changes ->
      lock_attempt(repo, call_id)
    end)
    |> Multi.run(:timed_out_attempt, fn repo, %{locked_attempt: attempt} ->
      apply_timeout(repo, attempt)
    end)
    |> Multi.run(:activity_item, fn repo, %{timed_out_attempt: result} ->
      maybe_insert_missed_call_activity(repo, result)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{timed_out_attempt: {:already_terminal, %CallAttempt{} = call_attempt}}} ->
        {:ok, :already_terminal, call_attempt}

      {:ok, %{timed_out_attempt: {:still_ringing, %CallAttempt{} = call_attempt}}} ->
        {:ok, :still_ringing, call_attempt}

      {:ok,
       %{
         timed_out_attempt: {:timed_out, %CallAttempt{} = call_attempt},
         activity_item: activity_item
       }} ->
        {:ok, :timed_out, call_attempt, activity_item}

      {:error, _operation, reason, _changes} ->
        {:error, normalize_command_error(reason)}
    end
  end

  defp lock_attempt(repo, call_id) do
    case locked_call_attempt(repo, call_id) do
      nil -> {:error, :not_found}
      %CallAttempt{} = attempt -> {:ok, attempt}
    end
  end

  defp locked_call_attempt(repo, call_id) do
    # Lock only this Call Attempt. Later Friendship-removal work must take
    # Friendship then Conversation before this row, never the reverse.
    repo.one(
      from call_attempt in CallAttempt,
        where: call_attempt.id == ^call_id,
        lock: "FOR UPDATE"
    )
  end

  defp apply_timeout(_repo, %CallAttempt{state: :terminal} = attempt) do
    {:ok, {:already_terminal, attempt}}
  end

  defp apply_timeout(_repo, %CallAttempt{state: state})
       when state in [:connecting, :active] do
    {:error, :stale}
  end

  defp apply_timeout(repo, %CallAttempt{state: :ringing} = attempt) do
    ended_at = DateTime.utc_now(:microsecond)

    if DateTime.compare(attempt.ringing_deadline_at, ended_at) == :gt do
      {:ok, {:still_ringing, attempt}}
    else
      timeout_ringing_attempt(repo, attempt, ended_at)
    end
  end

  defp timeout_ringing_attempt(repo, %CallAttempt{} = attempt, ended_at) do
    attempt
    |> CallAttempt.timeout_changeset(ended_at)
    |> repo.update()
    |> case do
      {:ok, %CallAttempt{} = updated} ->
        {:ok, {:timed_out, updated}}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, normalize_command_error(changeset)}
    end
  end

  defp maybe_insert_missed_call_activity(repo, {:cancelled, :ringing, %CallAttempt{} = attempt}) do
    insert_missed_call_activity(repo, attempt)
  end

  defp maybe_insert_missed_call_activity(repo, {:timed_out, %CallAttempt{} = attempt}) do
    insert_missed_call_activity(repo, attempt)
  end

  defp maybe_insert_missed_call_activity(_repo, _result), do: {:ok, nil}

  defp insert_missed_call_activity(repo, %CallAttempt{} = attempt) do
    %ActivityItem{}
    |> ActivityItem.create_missed_direct_call_changeset(%{
      recipient_user_id: attempt.recipient_user_id,
      actor_user_id: attempt.caller_user_id,
      source_conversation_id: attempt.direct_conversation_id,
      source_call_attempt_id: attempt.id
    })
    |> repo.insert(mode: :savepoint)
    |> case do
      {:ok, %ActivityItem{} = activity_item} ->
        {:ok, activity_item}

      {:error, %Ecto.Changeset{} = changeset} ->
        if unique_missed_call_conflict?(changeset) do
          case existing_missed_call_activity(repo, attempt) do
            %ActivityItem{} = activity_item -> {:ok, activity_item}
            nil -> {:error, :temporarily_unavailable}
          end
        else
          {:error, normalize_cancel_error(changeset)}
        end
    end
  rescue
    Ecto.ConstraintError -> {:error, :temporarily_unavailable}
  end

  defp unique_missed_call_conflict?(%Ecto.Changeset{} = changeset) do
    "activity_items_recipient_source_call_attempt_kind_index" in constraint_names(changeset)
  end

  defp existing_missed_call_activity(repo, %CallAttempt{} = attempt) do
    repo.one(
      from activity_item in ActivityItem,
        where:
          activity_item.recipient_user_id == ^attempt.recipient_user_id and
            activity_item.source_call_attempt_id == ^attempt.id and
            activity_item.kind == ^ActivityItem.missed_direct_call_kind()
    )
  end

  defp lock_prunable_terminal_attempts(cutoff) do
    # SQL is the only prunability gate. Ringing cancel/timeout (`accepted_at` nil)
    # need the missed-call Activity; connecting cancel (`accepted_at` set) does
    # not, because Ticket 04 creates none.
    Repo.all(
      from call_attempt in CallAttempt,
        as: :call_attempt,
        where: call_attempt.state == :terminal,
        where: call_attempt.ended_at <= ^cutoff,
        where: ^prunable_terminal_dynamic(),
        order_by: [asc: call_attempt.ended_at, asc: call_attempt.id],
        limit: ^prune_batch_size(),
        lock: "FOR UPDATE SKIP LOCKED"
    )
  end

  defp count_unmaterialized_activity_gated_terminals(cutoff) do
    Repo.aggregate(
      from(call_attempt in CallAttempt,
        as: :call_attempt,
        where: call_attempt.state == :terminal,
        where: call_attempt.ended_at <= ^cutoff,
        where: ^retained_activity_gated_dynamic()
      ),
      :count
    )
  end

  defp prunable_terminal_dynamic do
    missed_kind = ActivityItem.missed_direct_call_kind()

    dynamic(
      [call_attempt],
      call_attempt.terminal_outcome not in ^[:cancelled, :timed_out] or
        (call_attempt.terminal_outcome == :cancelled and
           not is_nil(call_attempt.accepted_at)) or
        exists(
          from activity_item in ActivityItem,
            where:
              activity_item.recipient_user_id == parent_as(:call_attempt).recipient_user_id and
                activity_item.source_call_attempt_id == parent_as(:call_attempt).id and
                activity_item.kind == ^missed_kind
        )
    )
  end

  defp retained_activity_gated_dynamic do
    dynamic(not (^prunable_terminal_dynamic()))
  end

  @doc false
  @spec get_nonterminal_attempt(Ecto.UUID.t()) :: CallAttempt.t() | nil
  def get_nonterminal_attempt(call_id) do
    Repo.one(
      from call_attempt in CallAttempt,
        where: call_attempt.id == ^call_id and call_attempt.state != :terminal
    )
  end

  @doc false
  # Intentionally scope-less: the media admission coordinator pins both Users
  # and owns no single `current_scope`, so pair preflight verifies the exact
  # durable participant pair plus current friendship instead of one scope.
  # User-facing callers should use the scoped `get_call/2` / `accept_call/4`.
  @spec pair_preflight(term(), term(), term()) ::
          :ok
          | {:error, :not_found | :stale | :not_friends | :temporarily_unavailable}
  def pair_preflight(call_id, first_user_id, second_user_id) do
    with {:ok, call_id} <- Ecto.UUID.cast(call_id),
         {:ok, first_user_id} <- Ecto.UUID.cast(first_user_id),
         {:ok, second_user_id} <- Ecto.UUID.cast(second_user_id),
         true <- first_user_id != second_user_id,
         %CallAttempt{} = call_attempt <- Repo.get(CallAttempt, call_id),
         true <- pair_participants?(call_attempt, first_user_id, second_user_id) do
      cond do
        call_attempt.state != :ringing -> {:error, :stale}
        not Friendships.friends_between?(first_user_id, second_user_id) -> {:error, :not_friends}
        true -> :ok
      end
    else
      _not_found_or_invalid -> {:error, :not_found}
    end
  rescue
    Postgrex.Error -> {:error, :temporarily_unavailable}
    DBConnection.ConnectionError -> {:error, :temporarily_unavailable}
  end

  @doc false
  # See `pair_preflight/3`: scope-less by intent for the coordinator's
  # two-sided commit check.
  @spec pair_connecting?(term(), term(), term()) :: boolean()
  def pair_connecting?(call_id, first_user_id, second_user_id) do
    case Repo.get(CallAttempt, call_id) do
      %CallAttempt{state: :connecting} = call_attempt ->
        pair_participants?(call_attempt, first_user_id, second_user_id)

      _missing_or_not_connecting ->
        false
    end
  rescue
    Ecto.Query.CastError -> false
    Postgrex.Error -> false
    DBConnection.ConnectionError -> false
  end

  defp pair_participants?(%CallAttempt{} = call_attempt, first_user_id, second_user_id) do
    Enum.sort([call_attempt.caller_user_id, call_attempt.recipient_user_id]) ==
      Enum.sort([first_user_id, second_user_id])
  end

  @doc false
  @spec register_connection(Ecto.UUID.t(), Ecto.UUID.t(), :caller | :recipient, Ecto.UUID.t()) ::
          :ok
  def register_connection(call_id, user_id, role, connection_id) do
    CallServer.register(call_id, user_id, role, connection_id)
  end

  @doc false
  @spec unregister_connection(Ecto.UUID.t(), String.t()) :: :ok
  def unregister_connection(call_id, connection_id) do
    CallServer.unregister(call_id, connection_id)
  end

  @doc false
  @spec projection_keys() :: [atom()]
  def projection_keys, do: @projection_keys

  @doc false
  @spec ownership(Ecto.UUID.t(), :caller | :recipient, Ecto.UUID.t() | nil) ::
          :self | :elsewhere | :unclaimed | nil
  def ownership(call_id, role, connection_id) when role in [:caller, :recipient] do
    CallServer.ownership(call_id, role, connection_id)
  end

  def ownership(_call_id, _role, _connection_id), do: nil

  @doc false
  @spec participant_projection?(map(), Ecto.UUID.t()) :: boolean()
  def participant_projection?(projection, user_id)
      when is_map(projection) and is_binary(user_id) do
    user_id in [projection[:caller_user_id], projection[:recipient_user_id]]
  end

  def participant_projection?(_projection, _user_id), do: false

  @doc false
  def to_projection(%CallAttempt{} = call_attempt) do
    Map.new(@projection_source, fn {key, field} ->
      {key, Map.fetch!(call_attempt, field)}
    end)
  end

  @doc false
  def with_answer_mode(projection, answer_mode) when answer_mode in [:audio, :video] do
    Map.put(projection, :answer_mode, answer_mode)
  end

  def with_answer_mode(projection, _answer_mode), do: projection

  @doc false
  def with_media_state(%{state: stage, call_id: call_id} = projection)
      when stage in [:connecting, :active] do
    case CallServer.media_state(call_id) do
      snapshots when map_size(snapshots) > 0 -> Map.put(projection, :media_state, snapshots)
      _ -> Map.delete(projection, :media_state)
    end
  end

  def with_media_state(projection), do: Map.delete(projection, :media_state)

  @doc false
  def broadcast_ringing(projection) when is_map(projection) do
    broadcast_to_participants(projection, :call_ringing)
  end

  @doc false
  def broadcast_connecting(projection) when is_map(projection) do
    broadcast_to_participants(projection, :call_connecting)
  end

  @doc false
  def broadcast_active(projection) when is_map(projection) do
    broadcast_to_participants(projection, :call_active)
  end

  @doc false
  @spec complete_accepted_runtime(
          Ecto.UUID.t(),
          :ready | {:connected, reference()} | :failed_capacity | :failed,
          :audio | :video
        ) ::
          {:ok, :activated, CallAttempt.t()}
          | {:ok, :terminal}
          | {:error, :not_found | :stale | :temporarily_unavailable}
  def complete_accepted_runtime(call_id, :ready, answer_mode) do
    complete_activation(call_id, answer_mode)
  end

  def complete_accepted_runtime(call_id, {:connected, generation}, answer_mode) do
    complete_activation(call_id, answer_mode, {:real, generation})
  end

  def complete_accepted_runtime(call_id, outcome, _answer_mode)
      when outcome in [:failed_capacity, :failed] do
    case commit_runtime_failure(call_id, outcome) do
      {:ok, :failed, %CallAttempt{} = call_attempt} ->
        _ =
          project_committed_terminal(call_attempt, runtime_failure_event(outcome),
            broadcast?: true
          )

        # Postcommit generic failure must not strand a published pair.
        # Precommit capacity paths have no active pair; cleanup is a no-op.
        _ = AdmissionCoordinator.cleanup_active_pair_for_call(call_id)

        {:ok, :terminal}

      {:ok, :already_terminal, _call_attempt} ->
        _ = AdmissionCoordinator.cleanup_active_pair_for_call(call_id)
        {:ok, :terminal}

      {:error, reason} ->
        {:error, normalize_command_error(reason)}
    end
  rescue
    Ecto.ConstraintError -> {:error, :temporarily_unavailable}
  end

  defp complete_activation(call_id, answer_mode, runtime \\ nil) do
    case commit_activate(call_id, runtime) do
      {:ok, :activated, %CallAttempt{} = call_attempt} ->
        case finalize_activation(call_id, runtime) do
          :ok ->
            projection = call_attempt |> to_projection() |> with_answer_mode(answer_mode)
            _ = broadcast_to_participants(projection, :call_active)
            {:ok, :activated, call_attempt}

          {:error, _} ->
            case fail_call_for_media_loss(call_id) do
              {:ok, _projection} -> {:ok, :terminal}
              error -> error
            end
        end

      {:ok, :already_active, %CallAttempt{} = call_attempt} ->
        {:ok, :activated, call_attempt}

      {:ok, :already_terminal, _call_attempt} ->
        # Durable activation lost to a terminal outcome after the pair
        # published. Clean both exact Call sides instead of leaking them;
        # never restore Voice.
        _ = AdmissionCoordinator.cleanup_active_pair_for_call(call_id)
        {:ok, :terminal}

      {:error, reason} ->
        {:error, normalize_command_error(reason)}
    end
  rescue
    Ecto.ConstraintError -> {:error, :temporarily_unavailable}
  end

  defp finalize_activation(_call_id, nil), do: :ok

  defp finalize_activation(call_id, {:real, generation}) do
    case AdmissionCoordinator.call_activated(call_id, generation) do
      :ok ->
        :ok

      error ->
        AdmissionCoordinator.begin_terminal_cleanup(call_id, generation)
        error
    end
  end

  defp project_committed_terminal(%CallAttempt{} = call_attempt, event, opts) do
    projection = to_projection(call_attempt)
    _ = CallCoordinator.release_occupancy(call_attempt.id)

    if Keyword.get(opts, :cleanup_media?, true) do
      _ = release_pair_media(call_attempt.id)
    end

    if Keyword.get(opts, :broadcast?, false) do
      _ = broadcast_to_participants(projection, event)
    end

    if Keyword.get(opts, :activity?, false) do
      _ = broadcast_missed_call_activity(call_attempt)
    end

    stop_call_server_after_projection(call_attempt.id)
    projection
  catch
    :exit, _unavailable -> to_projection(call_attempt)
  end

  defp stop_call_server_after_projection(call_id) do
    case Registry.lookup(DiscordClone.Calls.CallRegistry, call_id) do
      [{pid, _}] when pid != self() ->
        CallServer.stop(call_id)

      _missing_or_self ->
        :ok
    end
  end

  # Ticket 08 single funnel: every durable terminal releases its pair media
  # through the idempotent postcommit cleanup before the terminal projection
  # is broadcast. Precommit causes (still ringing, reservation only) are a
  # no-op here; the accept loser releases the exact reservation. Postcommit
  # causes remove both exact Call Sessions, the target runtime, both per-User
  # indexes, and the charged slots. Never restores Voice. Runs after the
  # short durable transaction and outside the coordinator mailbox; the
  # single-Direct-Call guard stays held until both Call sides are gone.
  defp release_pair_media(call_id) do
    _ = AdmissionCoordinator.cleanup_active_pair_for_call(call_id)
    :ok
  catch
    :exit, _unavailable -> :ok
  end

  defp broadcast_missed_call_activity(%CallAttempt{} = call_attempt) do
    ActivityTopics.broadcast_change(call_attempt.recipient_user_id, %{
      action: :created,
      source_call_attempt_id: call_attempt.id
    })
  end

  defp normalize_decline_error(reason), do: normalize_command_error(reason)

  defp normalize_cancel_error(reason), do: normalize_command_error(reason)

  defp normalize_accept_error(reason), do: normalize_command_error(reason)

  defp normalize_leave_error(reason), do: normalize_command_error(reason)

  defp normalize_command_error(reason)
       when reason in [:unauthenticated, :not_found, :stale, :temporarily_unavailable],
       do: reason

  defp normalize_command_error(_reason), do: :temporarily_unavailable

  defp broadcast_to_participants(projection, event) do
    Enum.each([projection.caller_user_id, projection.recipient_user_id], fn user_id ->
      :ok =
        Phoenix.PubSub.broadcast(
          DiscordClone.PubSub,
          user_topic(user_id),
          {event, projection}
        )
    end)

    :ok
  end

  defp available_media_intent(:video) do
    if camera_lifecycle_available?(), do: :ok, else: {:error, :temporarily_unavailable}
  end

  defp available_media_intent(:audio), do: :ok

  defp available_answer_mode(scope, call_id, :video) do
    if camera_lifecycle_available?() do
      :ok
    else
      with {:ok, call} <- get_call(scope, call_id) do
        if call.media_intent == :audio,
          do: {:error, :stale},
          else: {:error, :temporarily_unavailable}
      end
    end
  end

  defp available_answer_mode(_scope, _call_id, :audio), do: :ok

  defp normalize_media_intent(intent) when intent in [:audio, :video], do: {:ok, intent}
  defp normalize_media_intent("audio"), do: {:ok, :audio}
  defp normalize_media_intent("video"), do: {:ok, :video}
  defp normalize_media_intent(_intent), do: {:error, :invalid_media_intent}

  defp normalize_answer_mode(mode) when mode in [:audio, "audio"], do: {:ok, :audio}
  defp normalize_answer_mode(mode) when mode in [:video, "video"], do: {:ok, :video}
  defp normalize_answer_mode(_mode), do: {:error, :invalid_answer_mode}

  defp discover_current_call(_scope, _user_id, nil), do: {:ok, nil}

  defp discover_current_call(scope, user_id, call_id) do
    case authorized_discoverable_attempt(scope, user_id, call_id) do
      {:ok, %CallAttempt{} = attempt} ->
        await_ready_current_call(scope, user_id, attempt)

      :none ->
        {:ok, nil}
    end
  end

  defp await_ready_current_call(scope, user_id, %CallAttempt{id: call_id}) do
    case CallServer.await_ready(call_id) do
      :ok ->
        case authorized_discoverable_attempt(scope, user_id, call_id) do
          {:ok, %CallAttempt{} = current} -> {:ok, project_live_call(current)}
          :none -> {:ok, nil}
        end

      {:error, _reason} ->
        {:error, :temporarily_unavailable}
    end
  end

  defp project_live_call(%CallAttempt{} = call_attempt) do
    call_attempt
    |> to_projection()
    |> with_answer_mode(CallServer.answer_mode(call_attempt.id))
    |> with_media_state()
  end

  defp authorized_discoverable_attempt(%Scope{} = scope, user_id, call_id) do
    with %CallAttempt{} = attempt <- participant_call_attempt(call_id, user_id),
         true <- attempt.state != :terminal,
         false <- attempt.state == :ringing and ringing_overdue?(attempt),
         other_user_id when is_binary(other_user_id) <- other_user_id(attempt, user_id),
         true <- Friendships.friends?(scope, other_user_id) do
      {:ok, attempt}
    else
      _missing_or_unauthorized -> :none
    end
  end

  defp participant_call_attempt(call_id, user_id) do
    Repo.one(
      from call_attempt in CallAttempt,
        where:
          call_attempt.id == ^call_id and
            (call_attempt.caller_user_id == ^user_id or
               call_attempt.recipient_user_id == ^user_id)
    )
  end

  defp list_nonterminal_attempts do
    Repo.all(
      from call_attempt in CallAttempt,
        where: call_attempt.state != :terminal,
        order_by: [asc: call_attempt.inserted_at]
    )
  end

  defp partition_irreconcilable_attempts(attempts) do
    conflicted_user_ids = conflicted_user_ids(attempts)
    conflicted_conversation_ids = conflicted_conversation_ids(attempts)

    Enum.split_with(attempts, fn %CallAttempt{} = attempt ->
      attempt.caller_user_id in conflicted_user_ids or
        attempt.recipient_user_id in conflicted_user_ids or
        attempt.direct_conversation_id in conflicted_conversation_ids
    end)
  end

  defp conflicted_user_ids(attempts) do
    attempts
    |> Enum.flat_map(fn %CallAttempt{} = attempt ->
      [
        {attempt.caller_user_id, attempt.id},
        {attempt.recipient_user_id, attempt.id}
      ]
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.filter(fn {_user_id, call_ids} -> length(Enum.uniq(call_ids)) > 1 end)
    |> MapSet.new(fn {user_id, _call_ids} -> user_id end)
  end

  defp conflicted_conversation_ids(attempts) do
    attempts
    |> Enum.group_by(& &1.direct_conversation_id, & &1.id)
    |> Enum.filter(fn {_conversation_id, call_ids} -> length(Enum.uniq(call_ids)) > 1 end)
    |> MapSet.new(fn {conversation_id, _call_ids} -> conversation_id end)
  end

  defp recover_boot_attempt(%CallAttempt{state: state} = attempt, acc)
       when state in [:connecting, :active] do
    if CallServer.running?(attempt.id) do
      %{acc | rebuild: [attempt | acc.rebuild]}
    else
      case interrupt_attempt(attempt.id) do
        {:ok, _projection} ->
          acc

        {:error, _reason} ->
          %{acc | admit_starts?: false}
      end
    end
  end

  defp recover_boot_attempt(%CallAttempt{state: :ringing} = attempt, acc) do
    case ringing_recovery_decision(attempt) do
      {:rebuild, %CallAttempt{} = attempt} ->
        %{acc | rebuild: [attempt | acc.rebuild]}

      :released ->
        acc

      :blocked ->
        %{acc | admit_starts?: false}
    end
  end

  defp recover_boot_attempt(%CallAttempt{}, acc) do
    %{acc | admit_starts?: false}
  end

  defp occupancy_conflict?(%CallAttempt{} = attempt) do
    occupant_ids = [attempt.caller_user_id, attempt.recipient_user_id]

    Repo.exists?(
      from call_attempt in CallAttempt,
        where:
          call_attempt.id != ^attempt.id and call_attempt.state != :terminal and
            (call_attempt.direct_conversation_id == ^attempt.direct_conversation_id or
               call_attempt.caller_user_id in ^occupant_ids or
               call_attempt.recipient_user_id in ^occupant_ids)
    )
  end

  defp recover_runtime_attempt(%CallAttempt{state: state} = attempt)
       when state in [:connecting, :active] do
    case interrupt_attempt(attempt.id) do
      {:ok, _projection} -> :released
      {:error, _reason} -> :blocked
    end
  end

  defp recover_runtime_attempt(%CallAttempt{state: :ringing} = attempt) do
    ringing_recovery_decision(attempt)
  end

  defp ringing_recovery_decision(%CallAttempt{} = attempt) do
    cond do
      not current_friends?(attempt) ->
        case persist_missing_friendship_end(attempt) do
          {:ok, _ended} -> :released
          :ok -> :released
          {:error, _reason} -> :blocked
        end

      ringing_overdue?(attempt) ->
        case expire_ringing_attempt(attempt.id) do
          {:ok, %{state: :terminal}} -> :released
          {:ok, %{state: :ringing}} -> {:rebuild, attempt}
          {:error, _reason} -> :blocked
        end

      true ->
        {:rebuild, attempt}
    end
  end

  defp persist_missing_friendship_end(%CallAttempt{} = attempt) do
    result =
      Repo.transaction(fn ->
        case end_attempt_for_removed_friendship(
               attempt.caller_user_id,
               attempt.recipient_user_id
             ) do
          {:ok, ended} -> ended
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, %CallAttempt{id: call_id}} ->
        {:ok, project_committed_relationship_ended(call_id)}

      {:ok, nil} ->
        case Repo.get(CallAttempt, attempt.id) do
          %CallAttempt{state: :ringing} -> {:error, :temporarily_unavailable}
          _missing_or_terminal -> :ok
        end

      {:error, reason} ->
        {:error, normalize_command_error(reason)}
    end
  end

  defp interrupt_attempt(call_id) do
    case commit_interrupt(call_id) do
      {:ok, :interrupted, %CallAttempt{} = call_attempt} ->
        {:ok, project_committed_terminal(call_attempt, :call_interrupted, broadcast?: true)}

      {:ok, :already_terminal, %CallAttempt{} = call_attempt} ->
        {:ok, project_committed_terminal(call_attempt, :call_interrupted, broadcast?: false)}

      {:error, reason} ->
        {:error, normalize_command_error(reason)}
    end
  rescue
    Ecto.ConstraintError -> {:error, :temporarily_unavailable}
  end

  defp commit_interrupt(call_id) do
    case Repo.transaction(fn ->
           attempt = locked_call_attempt(Repo, call_id)

           cond do
             is_nil(attempt) ->
               Repo.rollback(:not_found)

             attempt.state == :terminal ->
               {:already_terminal, attempt}

             attempt.state not in [:connecting, :active] ->
               Repo.rollback(:stale)

             true ->
               attempt
               |> CallAttempt.interrupted_changeset(DateTime.utc_now(:microsecond))
               |> Repo.update()
               |> case do
                 {:ok, %CallAttempt{} = updated} ->
                   {:interrupted, updated}

                 {:error, %Ecto.Changeset{} = changeset} ->
                   Repo.rollback(normalize_command_error(changeset))
               end
           end
         end) do
      {:ok, {:interrupted, %CallAttempt{} = call_attempt}} ->
        {:ok, :interrupted, call_attempt}

      {:ok, {:already_terminal, %CallAttempt{} = call_attempt}} ->
        {:ok, :already_terminal, call_attempt}

      {:error, reason} ->
        {:error, normalize_command_error(reason)}
    end
  end

  defp current_friends?(%CallAttempt{} = attempt) do
    Friendships.friends?(
      %Scope{user: %User{id: attempt.caller_user_id}},
      attempt.recipient_user_id
    )
  end

  defp ringing_overdue?(%CallAttempt{ringing_deadline_at: deadline}) do
    DateTime.compare(deadline, DateTime.utc_now(:microsecond)) != :gt
  end

  defp occupancy_decision(direct_conversation_id, caller_user_id, recipient_user_id) do
    occupant_ids = [caller_user_id, recipient_user_id]

    attempts =
      Repo.all(
        from call_attempt in CallAttempt,
          where:
            call_attempt.state != :terminal and
              (call_attempt.direct_conversation_id == ^direct_conversation_id or
                 call_attempt.caller_user_id in ^occupant_ids or
                 call_attempt.recipient_user_id in ^occupant_ids)
      )

    case Enum.find(attempts, &(&1.direct_conversation_id == direct_conversation_id)) do
      %CallAttempt{state: :ringing} = existing -> {:converge, existing}
      %CallAttempt{} -> :busy
      nil when attempts != [] -> :busy
      nil -> :free
    end
  end

  defp rate_limited?(caller_user_id, recipient_user_id, now) do
    caller_starts_rate_limited?(caller_user_id, now) or
      unanswered_pair_rate_limited?(caller_user_id, recipient_user_id, now)
  end

  defp caller_starts_rate_limited?(caller_user_id, now) do
    cutoff = DateTime.add(now, -@caller_start_window_seconds, :second)
    limit = max_starts_per_caller_per_minute()

    Repo.aggregate(
      from(call_attempt in CallAttempt,
        where:
          call_attempt.caller_user_id == ^caller_user_id and
            call_attempt.inserted_at >= ^cutoff
      ),
      :count
    ) >= limit
  end

  defp unanswered_pair_rate_limited?(caller_user_id, recipient_user_id, now) do
    cutoff = DateTime.add(now, -@unanswered_pair_window_seconds, :second)
    limit = max_unanswered_attempts_per_pair_per_five_minutes()

    Repo.aggregate(
      from(call_attempt in CallAttempt,
        where:
          call_attempt.caller_user_id == ^caller_user_id and
            call_attempt.recipient_user_id == ^recipient_user_id and
            is_nil(call_attempt.accepted_at) and
            call_attempt.inserted_at >= ^cutoff
      ),
      :count
    ) >= limit
  end

  defp max_starts_per_caller_per_minute do
    Keyword.get(
      calls_config(),
      :max_starts_per_caller_per_minute,
      @default_max_starts_per_caller_per_minute
    )
  end

  defp max_unanswered_attempts_per_pair_per_five_minutes do
    Keyword.get(
      calls_config(),
      :max_unanswered_attempts_per_pair_per_five_minutes,
      @default_max_unanswered_attempts_per_pair_per_five_minutes
    )
  end

  @doc false
  @spec prune_batch_size() :: pos_integer()
  def prune_batch_size do
    Keyword.get(calls_config(), :prune_batch_size, @prune_batch_size)
  end

  @doc false
  @spec prune_interval_ms() :: pos_integer()
  def prune_interval_ms do
    Keyword.get(calls_config(), :prune_interval_ms, :timer.hours(1))
  end

  defp calls_config do
    Application.get_env(:discord_clone, __MODULE__, [])
  end

  defp insert_ringing_attempt(
         direct_conversation_id,
         caller_user_id,
         recipient_user_id,
         media_intent,
         started_at
       ) do
    ringing_deadline_at = DateTime.add(started_at, @ringing_seconds, :second)

    attrs = %{
      direct_conversation_id: direct_conversation_id,
      caller_user_id: caller_user_id,
      recipient_user_id: recipient_user_id,
      media_intent: media_intent,
      state: :ringing,
      ringing_deadline_at: ringing_deadline_at
    }

    %CallAttempt{}
    |> CallAttempt.create_changeset(attrs)
    |> Ecto.Changeset.put_change(:inserted_at, started_at)
    |> Ecto.Changeset.put_change(:updated_at, started_at)
    |> Repo.insert()
    |> case do
      {:ok, call_attempt} ->
        {:started, call_attempt}

      {:error, %Ecto.Changeset{} = changeset} ->
        names = constraint_names(changeset)

        if "call_attempts_one_nonterminal_per_direct_conversation_index" in names do
          case nonterminal_attempt_for_conversation(direct_conversation_id) do
            %CallAttempt{} = existing -> {:converged, existing}
            nil -> Repo.rollback(:busy)
          end
        else
          Repo.rollback(insert_failure_reason(changeset))
        end
    end
  end

  defp nonterminal_attempt_for_conversation(direct_conversation_id) do
    Repo.one(nonterminal_attempts_for_conversation(direct_conversation_id))
  end

  defp nonterminal_attempts_for_conversation(direct_conversation_id) do
    from call_attempt in CallAttempt,
      where:
        call_attempt.direct_conversation_id == ^direct_conversation_id and
          call_attempt.state != :terminal
  end

  defp canonical_user_pair(first_id, second_id) do
    if first_id < second_id, do: {first_id, second_id}, else: {second_id, first_id}
  end

  defp end_nonterminal_attempt_for_pair(user_low_id, user_high_id) do
    # Friendship removal already holds the accepted row FOR UPDATE. Take
    # Direct Conversation next, then the exact nonterminal Attempt, so start
    # (Friendship → Conversation) and this write cannot deadlock.
    case locked_direct_conversation_for_pair(user_low_id, user_high_id) do
      nil ->
        {:ok, nil}

      %DirectConversation{id: direct_conversation_id} ->
        case locked_nonterminal_attempt(direct_conversation_id) do
          nil ->
            {:ok, nil}

          %CallAttempt{} = attempt ->
            apply_relationship_ended(attempt)
        end
    end
  end

  defp locked_direct_conversation_for_pair(user_low_id, user_high_id) do
    Repo.one(
      from direct_conversation in DirectConversation,
        where:
          direct_conversation.user_low_id == ^user_low_id and
            direct_conversation.user_high_id == ^user_high_id,
        lock: "FOR UPDATE"
    )
  end

  defp locked_nonterminal_attempt(direct_conversation_id) do
    Repo.one(
      from call_attempt in nonterminal_attempts_for_conversation(direct_conversation_id),
        lock: "FOR UPDATE"
    )
  end

  defp apply_relationship_ended(%CallAttempt{} = attempt) do
    attempt
    |> CallAttempt.relationship_ended_changeset(DateTime.utc_now(:microsecond))
    |> Repo.update()
    |> case do
      {:ok, %CallAttempt{} = updated} ->
        {:ok, updated}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, normalize_command_error(changeset)}
    end
  end

  defp lock_participant_direct_conversation!(
         direct_conversation_id,
         caller_user_id,
         recipient_user_id
       ) do
    direct_conversation =
      Repo.one(
        from direct_conversation in DirectConversation,
          where:
            direct_conversation.id == ^direct_conversation_id and
              (direct_conversation.user_low_id == ^caller_user_id or
                 direct_conversation.user_high_id == ^caller_user_id),
          lock: "FOR UPDATE"
      )

    if is_nil(direct_conversation), do: Repo.rollback(:not_found)

    if DirectConversation.other_user_id(direct_conversation, caller_user_id) != recipient_user_id do
      Repo.rollback(:not_found)
    end

    direct_conversation
  end

  defp other_user_id(
         %CallAttempt{caller_user_id: user_id, recipient_user_id: other_user_id},
         user_id
       ),
       do: other_user_id

  defp other_user_id(
         %CallAttempt{recipient_user_id: user_id, caller_user_id: other_user_id},
         user_id
       ),
       do: other_user_id

  defp other_user_id(%CallAttempt{}, _user_id), do: nil

  defp projection_peer_id(
         %{caller_user_id: user_id, recipient_user_id: peer_id},
         user_id
       ),
       do: peer_id

  defp projection_peer_id(
         %{recipient_user_id: user_id, caller_user_id: peer_id},
         user_id
       ),
       do: peer_id

  defp projection_peer_id(_projection, _user_id), do: nil

  defp insert_failure_reason(%Ecto.Changeset{} = changeset) do
    if Enum.any?(changeset.errors, fn {_field, {_message, opts}} ->
         opts[:constraint] == :foreign
       end) do
      :not_found
    else
      :temporarily_unavailable
    end
  end

  defp constraint_names(%Ecto.Changeset{errors: errors}) do
    for {_field, {_message, opts}} <- errors,
        name = opts[:constraint_name],
        not is_nil(name),
        do: to_string(name)
  end

  defp user_topic(user_id), do: "calls:user:#{user_id}"
end
