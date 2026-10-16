defmodule DiscordClone.Friendships do
  @moduledoc """
  Owns global Friend Request and Friendship workflows.

  User discovery is deliberately limited to exact normalized usernames.
  """

  import Ecto.Query

  alias DiscordClone.Accounts.{Scope, User}
  alias DiscordClone.Activities.{ActivityItem, Topics}
  alias DiscordClone.Calls
  alias DiscordClone.Friendships.Relationship
  alias DiscordClone.Repo
  alias DiscordClone.Workspaces

  @type mutation_error :: :unauthenticated | :unauthorized | :not_found | :stale_state

  @doc "Subscribes the scoped User to private Friendship change facts."
  @spec subscribe(term()) :: :ok | {:error, :unauthenticated}
  def subscribe(%Scope{user: %User{id: user_id}}) do
    Phoenix.PubSub.subscribe(DiscordClone.PubSub, user_topic(user_id))
  end

  def subscribe(_scope), do: {:error, :unauthenticated}

  @spec send_friend_request(term(), map()) ::
          {:ok, %{relationship: Relationship.t(), user: User.t()}}
          | {:error, :unauthenticated | :invalid_username | :unknown_user | :self_request}
          | {:error, Ecto.Changeset.t()}
  def send_friend_request(%Scope{user: %User{} = requester}, attrs) when is_map(attrs) do
    with {:ok, username} <- normalized_username(attrs),
         %User{} = target <- Repo.get_by(User, username: username),
         :ok <- reject_self(requester, target) do
      persist_friend_request(requester, target)
    else
      nil -> {:error, :unknown_user}
      {:error, reason} -> {:error, reason}
    end
  end

  def send_friend_request(%Scope{user: %User{}}, _attrs), do: {:error, :invalid_username}
  def send_friend_request(_scope, _attrs), do: {:error, :unauthenticated}

  @doc "Sends a Friend Request to a known Workspace Member after re-authorizing membership."
  @spec send_friend_request_to_workspace_member(term(), term(), term()) ::
          {:ok, %{relationship: Relationship.t(), user: User.t()}}
          | {:error, :unauthenticated | :unauthorized | :not_found | :self_request}
          | {:error, Ecto.Changeset.t()}
  def send_friend_request_to_workspace_member(
        %Scope{user: %User{} = requester},
        workspace_id,
        target_user_id
      ) do
    with {:ok, %User{} = target} <-
           Workspaces.fetch_member_user(
             %Scope{user: requester},
             workspace_id,
             target_user_id
           ),
         :ok <- reject_self(requester, target) do
      persist_friend_request(requester, target)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def send_friend_request_to_workspace_member(_scope, _workspace_id, _target_user_id),
    do: {:error, :unauthenticated}

  @doc "Returns a relationship only when the scoped User belongs to its pair."
  @spec get_relationship(term(), term()) ::
          {:ok, Relationship.t()} | {:error, :unauthenticated | :not_found}
  def get_relationship(%Scope{user: %User{id: user_id}}, relationship_id) do
    with {:ok, relationship_id} <- Ecto.UUID.cast(relationship_id),
         %Relationship{} = relationship <-
           Repo.one(
             from relationship in Relationship,
               where:
                 relationship.id == ^relationship_id and
                   (relationship.user_low_id == ^user_id or
                      relationship.user_high_id == ^user_id)
           ) do
      {:ok, relationship}
    else
      _other -> {:error, :not_found}
    end
  end

  def get_relationship(_scope, _relationship_id), do: {:error, :unauthenticated}

  @doc "Accepts an incoming Friend Request for the scoped User."
  @spec accept_friend_request(term(), term()) ::
          {:ok, Relationship.t()} | {:error, mutation_error()}
  def accept_friend_request(%Scope{user: %User{id: user_id}}, relationship_id) do
    update_relationship(user_id, relationship_id, :accept)
  end

  def accept_friend_request(_scope, _relationship_id), do: {:error, :unauthenticated}

  @doc "Declines an incoming Friend Request for the scoped User."
  @spec decline_friend_request(term(), term()) :: :ok | {:error, mutation_error()}
  def decline_friend_request(%Scope{user: %User{id: user_id}}, relationship_id) do
    delete_relationship(user_id, relationship_id, :decline)
  end

  def decline_friend_request(_scope, _relationship_id), do: {:error, :unauthenticated}

  @doc "Cancels an outgoing Friend Request for the scoped User."
  @spec cancel_friend_request(term(), term()) :: :ok | {:error, mutation_error()}
  def cancel_friend_request(%Scope{user: %User{id: user_id}}, relationship_id) do
    delete_relationship(user_id, relationship_id, :cancel)
  end

  def cancel_friend_request(_scope, _relationship_id), do: {:error, :unauthenticated}

  @doc "Removes an accepted Friendship for either User in the pair."
  @spec remove_friend(term(), term()) :: :ok | {:error, mutation_error()}
  def remove_friend(%Scope{user: %User{id: user_id}}, relationship_id) do
    delete_relationship(user_id, relationship_id, :remove)
  end

  def remove_friend(_scope, _relationship_id), do: {:error, :unauthenticated}

  @doc "Lists pending Friend Requests received by the scoped User."
  @spec list_incoming_requests(term()) ::
          {:ok, [%{relationship: Relationship.t(), user: User.t()}]}
          | {:error, :unauthenticated}
  def list_incoming_requests(%Scope{user: %User{id: user_id}}) do
    {:ok, list_pending_requests(user_id, :incoming)}
  end

  def list_incoming_requests(_scope), do: {:error, :unauthenticated}

  @doc "Lists pending Friend Requests sent by the scoped User."
  @spec list_outgoing_requests(term()) ::
          {:ok, [%{relationship: Relationship.t(), user: User.t()}]}
          | {:error, :unauthenticated}
  def list_outgoing_requests(%Scope{user: %User{id: user_id}}) do
    {:ok, list_pending_requests(user_id, :outgoing)}
  end

  def list_outgoing_requests(_scope), do: {:error, :unauthenticated}

  @type relationship_state :: :none | :incoming_request | :outgoing_request | :friends

  @doc "Returns the scoped User's current relationship state with another User."
  @spec relationship_state(term(), term()) ::
          {:ok, relationship_state()} | {:error, :unauthenticated | :not_found}
  def relationship_state(%Scope{user: %User{id: user_id}}, other_user_id) do
    with {:ok, other_user_id} <- Ecto.UUID.cast(other_user_id),
         true <- other_user_id != user_id do
      {user_low_id, user_high_id} = canonical_pair(user_id, other_user_id)

      relationship =
        Repo.one(
          from relationship in Relationship,
            where:
              relationship.user_low_id == ^user_low_id and
                relationship.user_high_id == ^user_high_id,
            select: {relationship.status, relationship.requested_by_user_id}
        )

      {:ok, scoped_relationship_state(relationship, user_id)}
    else
      _invalid_or_self -> {:error, :not_found}
    end
  end

  def relationship_state(_scope, _other_user_id), do: {:error, :unauthenticated}

  @doc "Lists accepted mutual Friendships for the scoped User."
  @spec list_friends(term()) ::
          {:ok, [%{relationship: Relationship.t(), user: User.t()}]}
          | {:error, :unauthenticated}
  def list_friends(%Scope{user: %User{id: user_id}}) do
    friendships =
      Relationship
      |> where(
        [relationship],
        relationship.status == :accepted and
          (relationship.user_low_id == ^user_id or relationship.user_high_id == ^user_id)
      )
      |> order_by([relationship], asc: relationship.accepted_at, asc: relationship.id)
      |> preload([:user_low, :user_high])
      |> Repo.all()
      |> Enum.map(&relationship_entry(&1, user_id))

    {:ok, friendships}
  end

  def list_friends(_scope), do: {:error, :unauthenticated}

  @doc "Lists current Friend User IDs without loading relationship presentation data."
  @spec list_friend_user_ids(term()) :: {:ok, [Ecto.UUID.t()]} | {:error, :unauthenticated}
  def list_friend_user_ids(%Scope{user: %User{id: user_id}}) do
    friend_ids =
      Repo.all(
        from relationship in Relationship,
          where:
            relationship.status == :accepted and
              (relationship.user_low_id == ^user_id or relationship.user_high_id == ^user_id),
          select: {relationship.user_low_id, relationship.user_high_id}
      )
      |> Enum.map(fn
        {^user_id, friend_user_id} -> friend_user_id
        {friend_user_id, _user_id} -> friend_user_id
      end)

    {:ok, friend_ids}
  end

  def list_friend_user_ids(_scope), do: {:error, :unauthenticated}

  @doc "Returns whether the other User currently has an accepted Friendship with the scoped User."
  @spec friends?(term(), term()) :: boolean()
  def friends?(%Scope{user: %User{id: user_id}}, other_user_id),
    do: friends_between?(user_id, other_user_id)

  def friends?(_scope, _other_user_id), do: false

  @doc """
  Returns whether two User IDs currently have an accepted Friendship.

  Intentionally scope-less: server-side pair verification (for example the
  media admission coordinator, which pins both Users and owns no single
  `current_scope`) must check the exact pair. User-facing callers should
  prefer `friends?/2`, which threads the `Scope`.
  """
  @spec friends_between?(term(), term()) :: boolean()
  def friends_between?(first_user_id, second_user_id) do
    with {:ok, first_user_id} <- Ecto.UUID.cast(first_user_id),
         {:ok, second_user_id} <- Ecto.UUID.cast(second_user_id),
         false <- first_user_id == second_user_id do
      {user_low_id, user_high_id} = canonical_pair(first_user_id, second_user_id)

      Repo.exists?(
        from relationship in Relationship,
          where:
            relationship.user_low_id == ^user_low_id and
              relationship.user_high_id == ^user_high_id and
              relationship.status == :accepted
      )
    else
      _invalid_or_self -> false
    end
  end

  @doc """
  Locks the scoped User's accepted Friendship with another User.

  Callers must already be inside the transaction whose Friendship-dependent work
  needs serialization. The shared lock serializes against Friendship removal
  without exposing the relationship schema or its lifecycle policy.
  """
  @spec lock_accepted_friendship(term(), term()) ::
          :ok | {:error, :unauthenticated | :not_found | :not_friends}
  def lock_accepted_friendship(
        %Scope{user: %User{id: user_id}},
        other_user_id
      ) do
    with {:ok, other_user_id} <- Ecto.UUID.cast(other_user_id),
         true <- other_user_id != user_id do
      {user_low_id, user_high_id} = canonical_pair(user_id, other_user_id)

      if Repo.exists?(
           from relationship in Relationship,
             where:
               relationship.user_low_id == ^user_low_id and
                 relationship.user_high_id == ^user_high_id and
                 relationship.status == :accepted,
             lock: "FOR SHARE"
         ) do
        :ok
      else
        {:error, :not_friends}
      end
    else
      _invalid_or_self -> {:error, :not_found}
    end
  end

  def lock_accepted_friendship(_scope, _other_user_id),
    do: {:error, :unauthenticated}

  defp normalized_username(attrs) do
    case Map.get(attrs, :username) || Map.get(attrs, "username") do
      username when is_binary(username) ->
        case username |> String.trim() |> String.downcase() do
          "" -> {:error, :invalid_username}
          normalized -> {:ok, normalized}
        end

      _other ->
        {:error, :invalid_username}
    end
  end

  defp reject_self(%User{id: id}, %User{id: id}), do: {:error, :self_request}
  defp reject_self(%User{}, %User{}), do: :ok

  defp canonical_pair(first_id, second_id) do
    if first_id < second_id, do: {first_id, second_id}, else: {second_id, first_id}
  end

  defp scoped_relationship_state(nil, _user_id), do: :none
  defp scoped_relationship_state({:accepted, _requester_id}, _user_id), do: :friends
  defp scoped_relationship_state({:pending, user_id}, user_id), do: :outgoing_request
  defp scoped_relationship_state({:pending, _requester_id}, _user_id), do: :incoming_request

  defp persist_friend_request(requester, target) do
    pair = canonical_pair(requester.id, target.id)

    case Repo.transaction(fn -> persist_friend_request_transaction(pair, requester, target) end) do
      {:ok, result} ->
        publish_friend_request_changes(result)
        {:ok, %{relationship: result.relationship, user: target}}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp persist_friend_request_transaction(pair, requester, target) do
    candidate_id = insert_relationship_candidate!(pair, requester.id)
    relationship = lock_relationship_pair!(pair)

    {relationship, action} =
      transition_friend_request!(relationship, candidate_id, requester.id)

    activity_recipient_ids =
      insert_relationship_activity(relationship, action, requester.id, target.id)

    %{
      relationship: relationship,
      action: action,
      activity_recipient_ids: activity_recipient_ids
    }
  end

  defp insert_relationship_candidate!({user_low_id, user_high_id}, requester_id) do
    candidate_id = Ecto.UUID.generate()

    %Relationship{id: candidate_id}
    |> Relationship.create_changeset(%{
      user_low_id: user_low_id,
      user_high_id: user_high_id,
      requested_by_user_id: requester_id
    })
    |> Repo.insert(
      on_conflict: :nothing,
      conflict_target: [:user_low_id, :user_high_id]
    )
    |> case do
      {:ok, _relationship} -> candidate_id
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp lock_relationship_pair!({user_low_id, user_high_id}) do
    Repo.one!(
      from relationship in Relationship,
        where:
          relationship.user_low_id == ^user_low_id and
            relationship.user_high_id == ^user_high_id,
        lock: "FOR UPDATE"
    )
  end

  defp transition_friend_request!(relationship, candidate_id, requester_id) do
    cond do
      relationship.id == candidate_id ->
        {relationship, :requested}

      relationship.status == :pending and
          relationship.requested_by_user_id != requester_id ->
        relationship =
          relationship
          |> Relationship.accept_changeset()
          |> Repo.update!()

        {relationship, :accepted}

      true ->
        {relationship, nil}
    end
  end

  defp publish_friend_request_changes(result) do
    if result.action, do: :ok = broadcast_change(result.relationship, result.action)

    broadcast_activity_changes(
      result.activity_recipient_ids,
      :created,
      result.relationship.id
    )
  end

  defp pending_requests_for(user_id) do
    from relationship in Relationship,
      where:
        relationship.status == :pending and
          (relationship.user_low_id == ^user_id or relationship.user_high_id == ^user_id)
  end

  defp list_pending_requests(user_id, direction) do
    requests =
      user_id
      |> pending_requests_for()
      |> requests_in_direction(user_id, direction)
      |> order_by([relationship],
        asc: relationship.inserted_at,
        asc: relationship.id
      )
      |> preload([:user_low, :user_high, :requested_by_user])
      |> Repo.all()

    Enum.map(requests, &relationship_entry(&1, user_id))
  end

  defp requests_in_direction(query, user_id, :incoming) do
    from relationship in query, where: relationship.requested_by_user_id != ^user_id
  end

  defp requests_in_direction(query, user_id, :outgoing) do
    from relationship in query, where: relationship.requested_by_user_id == ^user_id
  end

  defp relationship_entry(%Relationship{user_low_id: user_id} = relationship, user_id) do
    %{relationship: relationship, user: relationship.user_high}
  end

  defp relationship_entry(%Relationship{} = relationship, _user_id) do
    %{relationship: relationship, user: relationship.user_low}
  end

  defp update_relationship(user_id, relationship_id, operation) do
    case mutate_relationship(
           user_id,
           relationship_id,
           operation,
           fn relationship ->
             case relationship |> Relationship.accept_changeset() |> Repo.update() do
               {:ok, accepted} ->
                 insert_friend_relationship_activity!(
                   accepted,
                   accepted.requested_by_user_id,
                   user_id,
                   ActivityItem.friend_request_accepted_kind()
                 )

                 %{
                   relationship: accepted,
                   activity_recipient_ids: [accepted.requested_by_user_id]
                 }

               {:error, changeset} ->
                 Repo.rollback(changeset)
             end
           end
         ) do
      {:ok, %{relationship: relationship, activity_recipient_ids: activity_recipient_ids}} ->
        :ok = broadcast_change(relationship, operation_action(operation))
        broadcast_activity_changes(activity_recipient_ids, :created, relationship.id)
        {:ok, relationship}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp delete_relationship(user_id, relationship_id, operation) do
    case mutate_relationship(
           user_id,
           relationship_id,
           operation,
           fn relationship ->
             ended_call_id = maybe_end_call_attempt(operation, relationship)

             activity_recipient_ids =
               Repo.all(
                 from activity_item in ActivityItem,
                   where: activity_item.source_friend_relationship_id == ^relationship.id,
                   select: activity_item.recipient_user_id,
                   distinct: true
               )

             Repo.delete!(relationship)

             %{
               relationship: relationship,
               activity_recipient_ids: activity_recipient_ids,
               ended_call_id: ended_call_id
             }
           end
         ) do
      {:ok, result} ->
        project_ended_call_attempt(result)
        :ok = broadcast_change(result.relationship, operation_action(operation))

        broadcast_activity_changes(
          result.activity_recipient_ids,
          :removed,
          result.relationship.id
        )

        :ok

      {:error, reason} ->
        {:error, normalize_mutation_error(reason)}
    end
  end

  defp maybe_end_call_attempt(:remove, %Relationship{} = relationship) do
    case Calls.end_attempt_for_removed_friendship(
           relationship.user_low_id,
           relationship.user_high_id
         ) do
      {:ok, nil} ->
        nil

      {:ok, %{id: call_id}} ->
        call_id

      {:error, _reason} ->
        Repo.rollback(:stale_state)
    end
  end

  defp maybe_end_call_attempt(_operation, _relationship), do: nil

  defp project_ended_call_attempt(%{ended_call_id: nil}), do: :ok

  defp project_ended_call_attempt(%{ended_call_id: call_id}) when is_binary(call_id) do
    _ = Calls.project_committed_relationship_ended(call_id)
    :ok
  end

  defp normalize_mutation_error(reason)
       when reason in [:unauthenticated, :unauthorized, :not_found, :stale_state],
       do: reason

  defp normalize_mutation_error(_reason), do: :stale_state

  defp mutate_relationship(user_id, relationship_id, operation, mutation) do
    %{expected_status: expected_status, actor_role: actor_role} = operation_policy(operation)

    with {:ok, relationship_id} <- Ecto.UUID.cast(relationship_id) do
      Repo.transaction(fn ->
        relationship =
          Repo.one(
            from relationship in Relationship,
              where:
                relationship.id == ^relationship_id and
                  (relationship.user_low_id == ^user_id or
                     relationship.user_high_id == ^user_id),
              lock: "FOR UPDATE"
          )

        cond do
          is_nil(relationship) ->
            Repo.rollback(:not_found)

          relationship.status != expected_status ->
            Repo.rollback(:stale_state)

          not authorized_role?(relationship, user_id, actor_role) ->
            Repo.rollback(:unauthorized)

          true ->
            mutation.(relationship)
        end
      end)
    else
      :error -> {:error, :not_found}
    end
  end

  defp authorized_role?(_relationship, _user_id, :either_friend), do: true

  defp authorized_role?(relationship, user_id, :requester) do
    relationship.requested_by_user_id == user_id
  end

  defp authorized_role?(relationship, user_id, :recipient) do
    relationship.requested_by_user_id != user_id
  end

  defp operation_policy(:accept),
    do: %{expected_status: :pending, actor_role: :recipient, action: :accepted}

  defp operation_policy(:decline),
    do: %{expected_status: :pending, actor_role: :recipient, action: :declined}

  defp operation_policy(:cancel),
    do: %{expected_status: :pending, actor_role: :requester, action: :cancelled}

  defp operation_policy(:remove),
    do: %{expected_status: :accepted, actor_role: :either_friend, action: :removed}

  defp operation_action(operation), do: operation_policy(operation).action

  defp insert_relationship_activity(relationship, :requested, requester_id, target_id) do
    insert_friend_relationship_activity!(
      relationship,
      target_id,
      requester_id,
      ActivityItem.friend_request_received_kind()
    )

    [target_id]
  end

  defp insert_relationship_activity(relationship, :accepted, requester_id, _target_id) do
    insert_friend_relationship_activity!(
      relationship,
      relationship.requested_by_user_id,
      requester_id,
      ActivityItem.friend_request_accepted_kind()
    )

    [relationship.requested_by_user_id]
  end

  defp insert_relationship_activity(_relationship, nil, _requester_id, _target_id), do: []

  defp insert_friend_relationship_activity!(relationship, recipient_id, actor_id, kind) do
    %ActivityItem{}
    |> ActivityItem.create_friend_relationship_changeset(
      %{
        recipient_user_id: recipient_id,
        actor_user_id: actor_id,
        source_friend_relationship_id: relationship.id
      },
      kind
    )
    |> Repo.insert!()
  end

  defp broadcast_activity_changes(recipient_ids, action, relationship_id) do
    Enum.each(recipient_ids, fn recipient_id ->
      :ok =
        Topics.broadcast_change(recipient_id, %{
          action: action,
          source_friend_relationship_id: relationship_id
        })
    end)
  end

  defp broadcast_change(%Relationship{} = relationship, action) do
    [relationship.user_low_id, relationship.user_high_id]
    |> Enum.each(fn user_id ->
      friend_user_id =
        if user_id == relationship.user_low_id,
          do: relationship.user_high_id,
          else: relationship.user_low_id

      event =
        {:friendships_changed,
         %{
           action: action,
           relationship_id: relationship.id,
           friend_user_id: friend_user_id
         }}

      :ok = Phoenix.PubSub.broadcast(DiscordClone.PubSub, user_topic(user_id), event)
    end)

    :ok
  end

  defp user_topic(user_id), do: "friendships:user:#{user_id}"
end
