defmodule DiscordClone.Workspaces do
  @moduledoc """
  The Workspaces context.

  Owns workspace structure, memberships, channels, and workspace invites.

  Current product-stage permissions are intentionally simple: workspace members
  may manage workspaces and channels, while invite creation follows each
  workspace's invite policy. More granular role-based permissions can replace
  the capability helpers later without changing the public context boundary.
  """

  import Ecto.Query

  require Logger

  alias Ecto.Multi
  alias DiscordClone.Accounts.{Scope, User}
  alias DiscordClone.Activities.ActivityItem
  alias DiscordClone.Chat
  alias DiscordClone.Chat.Conversation
  alias DiscordClone.{Repo, UUIDIdentifier, Voice}

  alias DiscordClone.Workspaces.{
    Channel,
    Roles,
    Workspace,
    WorkspaceAuditEvent,
    WorkspaceBan,
    WorkspaceInvite,
    WorkspaceModeration,
    WorkspaceMembership,
    VoiceChannel
  }

  @mute_type "mute"
  @timeout_type "timeout"
  @timeout_duration_presets %{
    "5_minutes" => {5, :minute},
    "1_hour" => {1, :hour},
    "24_hours" => {24, :hour},
    "7_days" => {7, :day}
  }

  @no_cleanup_window "none"
  @all_messages_cleanup_window "all"
  @ban_cleanup_windows %{
    @no_cleanup_window => :none,
    "1_hour" => {1, :hour},
    "24_hours" => {24, :hour},
    "7_days" => {7, :day},
    @all_messages_cleanup_window => :all
  }

  @owner_only_invites "owner_only"
  @default_channel_name "general"
  @invite_code_bytes 24
  @default_invite_ttl_minutes 30

  @type reason :: atom()
  @type context_result(value) ::
          {:ok, value} | {:error, reason()} | {:error, atom(), Ecto.Changeset.t()}
  @type member_action ::
          :mute | :unmute | :timeout | :remove_timeout | :kick | :ban | :promote | :demote

  def list_workspaces(%Scope{user: %User{id: user_id}}) do
    workspaces =
      Repo.all(
        from workspace in Workspace,
          join: membership in WorkspaceMembership,
          on: membership.workspace_id == workspace.id,
          where: membership.user_id == ^user_id,
          order_by: [desc: membership.inserted_at, desc: membership.id]
      )

    {:ok, workspaces}
  end

  def list_workspaces(_scope), do: {:error, :unauthenticated}

  def fetch_workspace(%Scope{user: %User{id: user_id}}, workspace_id) do
    with {:ok, workspace} <- get_workspace(workspace_id),
         :ok <- authorize_view_workspace(workspace, user_id) do
      {:ok, workspace}
    end
  end

  def fetch_workspace(_scope, _workspace_id), do: {:error, :unauthenticated}

  def list_channels(%Scope{} = scope, workspace_id) do
    with {:ok, %Workspace{id: workspace_id}} <- fetch_workspace(scope, workspace_id) do
      {:ok, Repo.all(channels_for_workspace_query(workspace_id))}
    end
  end

  def list_channels(_scope, _workspace_id), do: {:error, :unauthenticated}

  def list_voice_channels(%Scope{} = scope, workspace_id) do
    with {:ok, %Workspace{id: workspace_id}} <- fetch_workspace(scope, workspace_id) do
      {:ok, Repo.all(voice_channels_for_workspace_query(workspace_id))}
    end
  end

  def list_voice_channels(_scope, _workspace_id), do: {:error, :unauthenticated}

  @doc """
  Returns safe runtime Voice Channel Roster snapshots for a scoped Workspace.

  Voice owns only runtime membership. This Workspace boundary authorizes which
  Voice Channels a subscriber may observe before the web layer resolves User
  display identity from its already-scoped member data.
  """
  @spec list_voice_channel_rosters(Scope.t(), term()) ::
          {:ok, %{Ecto.UUID.t() => [%{user_id: Ecto.UUID.t()}]}} | {:error, reason()}
  def list_voice_channel_rosters(%Scope{} = scope, workspace_id) do
    with {:ok, voice_channels} <- list_voice_channels(scope, workspace_id) do
      rosters =
        Map.new(voice_channels, fn voice_channel ->
          {:ok, %{members: members}} = Voice.voice_channel_roster(voice_channel.id)
          {voice_channel.id, members}
        end)

      {:ok, rosters}
    end
  end

  def list_voice_channel_rosters(_scope, _workspace_id), do: {:error, :unauthenticated}

  @doc false
  @spec subscribe_to_voice_channel_rosters(Scope.t(), term()) :: :ok | {:error, reason()}
  def subscribe_to_voice_channel_rosters(%Scope{} = scope, workspace_id) do
    with {:ok, voice_channels} <- list_voice_channels(scope, workspace_id) do
      Enum.reduce_while(voice_channels, :ok, fn voice_channel, :ok ->
        case Voice.subscribe_to_voice_channel_roster(voice_channel.id) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  def subscribe_to_voice_channel_rosters(_scope, _workspace_id), do: {:error, :unauthenticated}

  def list_members(%Scope{} = scope, workspace_id) do
    with {:ok, %Workspace{id: workspace_id}} <- fetch_workspace(scope, workspace_id) do
      members =
        Repo.all(
          from membership in WorkspaceMembership,
            where: membership.workspace_id == ^workspace_id,
            order_by: [asc: membership.inserted_at, asc: membership.id],
            preload: [:user]
        )

      {:ok, members}
    end
  end

  def list_members(_scope, _workspace_id), do: {:error, :unauthenticated}

  @doc "Returns a known Workspace Member's User after re-authorizing the scoped User."
  @spec fetch_member_user(term(), term(), term()) :: context_result(User.t())
  def fetch_member_user(%Scope{} = scope, workspace_id, target_user_id) do
    with {:ok, %Workspace{id: workspace_id}} <- fetch_workspace(scope, workspace_id),
         {:ok, target_user_id} <- Ecto.UUID.cast(target_user_id),
         %WorkspaceMembership{user: %User{} = user} <-
           Repo.one(
             from membership in WorkspaceMembership,
               where:
                 membership.workspace_id == ^workspace_id and
                   membership.user_id == ^target_user_id,
               preload: [:user]
           ) do
      {:ok, user}
    else
      nil -> {:error, :not_found}
      :error -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def fetch_member_user(_scope, _workspace_id, _target_user_id),
    do: {:error, :unauthenticated}

  def fetch_channel(%Scope{} = scope, workspace_id, channel_id) do
    with {:ok, %Workspace{id: workspace_id}} <- fetch_workspace(scope, workspace_id),
         {:ok, %Channel{} = channel} <- get_channel(workspace_id, channel_id) do
      {:ok, channel}
    end
  end

  def fetch_channel(_scope, _workspace_id, _channel_id), do: {:error, :unauthenticated}

  def fetch_voice_channel(%Scope{} = scope, workspace_id, voice_channel_id) do
    with {:ok, %Workspace{id: workspace_id}} <- fetch_workspace(scope, workspace_id),
         {:ok, %VoiceChannel{} = voice_channel} <-
           get_voice_channel(workspace_id, voice_channel_id) do
      {:ok, voice_channel}
    end
  end

  def fetch_voice_channel(_scope, _workspace_id, _voice_channel_id),
    do: {:error, :unauthenticated}

  @doc """
  Finds a Voice Channel when the scoped User is currently a Workspace Member.

  This is the authorization boundary for ephemeral Voice Channel joins.
  It deliberately returns the same result for malformed, missing, and
  inaccessible identifiers so callers can keep topic joins non-enumerable.
  """
  @spec authorize_voice_channel_for_signaling(Scope.t(), Ecto.UUID.t()) ::
          {:ok, VoiceChannel.t()} | {:error, :not_found}
  def authorize_voice_channel_for_signaling(%Scope{user: %User{id: user_id}}, voice_channel_id) do
    with {:ok, voice_channel_id} <- Ecto.UUID.cast(voice_channel_id),
         %VoiceChannel{} = voice_channel <-
           Repo.one(
             from voice_channel in VoiceChannel,
               join: membership in WorkspaceMembership,
               on: membership.workspace_id == voice_channel.workspace_id,
               where: voice_channel.id == ^voice_channel_id and membership.user_id == ^user_id
           ),
         :ok <- voice_admission_status(voice_channel.workspace_id, user_id) do
      {:ok, voice_channel}
    else
      _ -> {:error, :not_found}
    end
  end

  def authorize_voice_channel_for_signaling(_scope, _voice_channel_id), do: {:error, :not_found}

  def resolve_landing_channel(%Scope{} = scope, workspace_id) do
    with {:ok, %Workspace{} = workspace} <- fetch_workspace(scope, workspace_id),
         {:ok, %Channel{} = channel} <- fetch_landing_channel(workspace) do
      {:ok, channel}
    end
  end

  def resolve_landing_channel(_scope, _workspace_id), do: {:error, :unauthenticated}

  def change_workspace(scope, attrs \\ %{})

  def change_workspace(%Scope{user: %User{} = user}, attrs) when is_map(attrs) do
    workspace_attrs = %{
      name: get_attr(attrs, :name),
      owner_id: user.id,
      invite_policy: @owner_only_invites
    }

    Workspace.create_changeset(%Workspace{}, workspace_attrs)
  end

  def change_workspace(_scope, _attrs), do: Workspace.create_changeset(%Workspace{}, %{})

  @doc """
  Creates a workspace, its owner membership, default channel, and initial read states.

  Returns the created workspace, a tagged validation changeset, or a normalized reason.
  Transaction internals remain inside the context.
  """
  @spec create_workspace(term(), map()) :: context_result(struct())
  def create_workspace(%Scope{user: %User{} = user}, attrs) when is_map(attrs) do
    user
    |> create_workspace_multi(attrs)
    |> Repo.transaction()
    |> handle_create_workspace_result()
  end

  def create_workspace(%Scope{user: %User{}}, _attrs), do: {:error, :invalid_attrs}

  def create_workspace(_scope, _attrs), do: {:error, :unauthenticated}

  def rename_workspace(%Scope{user: %User{}} = scope, workspace_id, attrs)
      when is_map(attrs) do
    with {:ok, workspace} <- fetch_workspace(scope, workspace_id),
         :ok <- authorize_rename_workspace(scope, workspace) do
      workspace
      |> Workspace.rename_changeset(workspace_rename_attrs(attrs))
      |> Repo.update()
      |> case do
        {:ok, workspace} -> {:ok, workspace}
        {:error, changeset} -> {:error, :invalid_workspace, changeset}
      end
    end
  end

  def rename_workspace(%Scope{user: %User{}}, _workspace_id, _attrs),
    do: {:error, :invalid_attrs}

  def rename_workspace(_scope, _workspace_id, _attrs), do: {:error, :unauthenticated}

  defp create_workspace_multi(%User{} = user, attrs) do
    Multi.new()
    |> Multi.insert(
      :workspace,
      Workspace.create_changeset(%Workspace{}, workspace_attrs(user, attrs))
    )
    |> Multi.insert(:owner_membership, fn %{workspace: workspace} ->
      owner_membership_changeset(workspace, user)
    end)
    |> Multi.insert(:default_conversation, Conversation.workspace_channel_changeset())
    |> Multi.insert(:default_channel, fn %{
                                           workspace: workspace,
                                           default_conversation: conversation
                                         } ->
      default_channel_changeset(workspace, conversation)
    end)
    |> Multi.update(:workspace_with_default_channel, fn %{
                                                          workspace: workspace,
                                                          default_channel: default_channel
                                                        } ->
      workspace_default_channel_changeset(workspace, default_channel)
    end)
    |> Multi.run(:owner_channel_reads, fn _repo, %{workspace: workspace} ->
      case Chat.initialize_workspace_reads_for_user(user.id, workspace.id) do
        :ok -> {:ok, :initialized}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  defp workspace_attrs(%User{id: user_id}, attrs) do
    %{
      name: get_attr(attrs, :name),
      owner_id: user_id,
      invite_policy: @owner_only_invites
    }
  end

  defp workspace_rename_attrs(attrs) do
    %{
      name: get_attr(attrs, :name)
    }
  end

  defp owner_membership_changeset(%Workspace{id: workspace_id}, %User{id: user_id}) do
    WorkspaceMembership.changeset(%WorkspaceMembership{}, %{
      workspace_id: workspace_id,
      user_id: user_id,
      role: Roles.owner()
    })
  end

  defp default_channel_changeset(
         %Workspace{id: workspace_id},
         %Conversation{id: conversation_id}
       ) do
    Channel.create_changeset(%Channel{id: conversation_id}, %{
      workspace_id: workspace_id,
      name: @default_channel_name
    })
  end

  defp workspace_default_channel_changeset(
         %Workspace{} = workspace,
         %Channel{id: default_channel_id}
       ) do
    Workspace.default_channel_changeset(workspace, %{
      default_channel_id: default_channel_id
    })
  end

  defp handle_create_workspace_result({:ok, %{workspace_with_default_channel: workspace}}) do
    {:ok, workspace}
  end

  defp handle_create_workspace_result({:error, :workspace, changeset, _changes_so_far}) do
    {:error, :invalid_workspace, changeset}
  end

  defp handle_create_workspace_result({:error, failed_operation, failed_value, changes_so_far}) do
    log_transaction_failure("workspace creation", failed_operation, failed_value, changes_so_far)
    {:error, :workspace_creation_failed}
  end

  def change_channel(workspace_id, attrs \\ %{}) when is_map(attrs) do
    %Channel{}
    |> Channel.create_changeset(channel_attrs(workspace_id, attrs))
  end

  @doc """
  Creates a channel and initializes read states for existing workspace members.

  Returns the channel, a tagged validation changeset, or a normalized reason without
  exposing `Ecto.Multi` failure details.
  """
  @spec create_channel(term(), Ecto.UUID.t(), map()) :: context_result(struct())
  def create_channel(%Scope{user: %User{}} = scope, workspace_id, attrs) when is_map(attrs) do
    with {:ok, workspace} <- get_workspace(workspace_id),
         :ok <- authorize_create_channel(scope, workspace) do
      create_channel_with_reads(workspace, attrs)
    end
  end

  def create_channel(%Scope{user: %User{}}, _workspace_id, _attrs), do: {:error, :invalid_attrs}

  def create_channel(_scope, _workspace_id, _attrs), do: {:error, :unauthenticated}

  def change_voice_channel(workspace_id, attrs \\ %{}) when is_map(attrs) do
    VoiceChannel.create_changeset(
      %VoiceChannel{workspace_id: workspace_id},
      channel_rename_attrs(attrs)
    )
  end

  def create_voice_channel(%Scope{user: %User{}} = scope, workspace_id, attrs)
      when is_map(attrs) do
    with {:ok, workspace} <- get_workspace(workspace_id),
         :ok <- authorize_create_voice_channel(scope, workspace) do
      %VoiceChannel{workspace_id: workspace.id}
      |> VoiceChannel.create_changeset(channel_rename_attrs(attrs))
      |> Repo.insert()
      |> case do
        {:ok, voice_channel} ->
          :ok = broadcast_workspace_voice_channels_changed(voice_channel.workspace_id)
          {:ok, voice_channel}

        {:error, changeset} ->
          {:error, :invalid_voice_channel, changeset}
      end
    end
  end

  def create_voice_channel(%Scope{user: %User{}}, _workspace_id, _attrs),
    do: {:error, :invalid_attrs}

  def create_voice_channel(_scope, _workspace_id, _attrs), do: {:error, :unauthenticated}

  def change_workspace_invite(attrs \\ %{}) when is_map(attrs) do
    WorkspaceInvite.create_changeset(%WorkspaceInvite{}, invite_form_attrs(attrs))
  end

  def create_workspace_invite(scope, workspace_id, attrs \\ %{})

  def create_workspace_invite(%Scope{user: %User{} = user} = scope, workspace_id, attrs)
      when is_map(attrs) do
    with {:ok, %Workspace{id: workspace_id} = workspace} <- fetch_workspace(scope, workspace_id),
         :ok <- authorize_create_invite(scope, workspace) do
      %WorkspaceInvite{}
      |> WorkspaceInvite.create_changeset(invite_creation_attrs(workspace_id, user, attrs))
      |> Repo.insert()
      |> case do
        {:ok, invite} -> {:ok, invite}
        {:error, changeset} -> {:error, :invalid_invite, changeset}
      end
    end
  end

  def create_workspace_invite(%Scope{user: %User{}}, _workspace_id, _attrs),
    do: {:error, :invalid_attrs}

  def create_workspace_invite(_scope, _workspace_id, _attrs), do: {:error, :unauthenticated}

  def can_rename_workspace?(%Scope{} = scope, %Workspace{} = workspace),
    do: has_workspace_role?(scope, workspace, [Roles.owner()])

  def can_rename_workspace?(_scope, _workspace), do: false

  def can_delete_workspace?(%Scope{} = scope, %Workspace{} = workspace),
    do: has_workspace_role?(scope, workspace, [Roles.owner()])

  def can_delete_workspace?(_scope, _workspace), do: false

  def can_create_channel?(%Scope{} = scope, %Workspace{} = workspace),
    do: has_workspace_role?(scope, workspace, [Roles.owner(), Roles.admin()])

  def can_create_channel?(_scope, _workspace), do: false

  def can_rename_channel?(%Scope{} = scope, %Workspace{} = workspace),
    do: has_workspace_role?(scope, workspace, [Roles.owner(), Roles.admin()])

  def can_rename_channel?(_scope, _workspace), do: false

  def can_delete_channel?(%Scope{} = scope, %Workspace{} = workspace),
    do: has_workspace_role?(scope, workspace, [Roles.owner()])

  def can_delete_channel?(_scope, _workspace), do: false

  def can_create_voice_channel?(%Scope{} = scope, %Workspace{} = workspace),
    do: has_workspace_role?(scope, workspace, [Roles.owner(), Roles.admin()])

  def can_create_voice_channel?(_scope, _workspace), do: false

  def can_rename_voice_channel?(%Scope{} = scope, %Workspace{} = workspace),
    do: has_workspace_role?(scope, workspace, [Roles.owner(), Roles.admin()])

  def can_rename_voice_channel?(_scope, _workspace), do: false

  def can_delete_voice_channel?(%Scope{} = scope, %Workspace{} = workspace),
    do: has_workspace_role?(scope, workspace, [Roles.owner()])

  def can_delete_voice_channel?(_scope, _workspace), do: false

  def can_create_workspace_invite?(%Scope{} = scope, %Workspace{} = workspace),
    do: has_workspace_role?(scope, workspace, [Roles.owner(), Roles.admin()])

  def can_create_workspace_invite?(_scope, _workspace), do: false

  def can_view_audit_log?(%Scope{} = scope, %Workspace{} = workspace),
    do: has_workspace_role?(scope, workspace, [Roles.owner()])

  def can_view_audit_log?(_scope, _workspace), do: false

  def can_manage_roles?(%Scope{} = scope, %Workspace{} = workspace),
    do: has_workspace_role?(scope, workspace, [Roles.owner()])

  def can_manage_roles?(_scope, _workspace), do: false

  def can_purge_all_workspace_messages?(%Scope{} = scope, %Workspace{} = workspace),
    do: has_workspace_role?(scope, workspace, [Roles.owner()])

  def can_purge_all_workspace_messages?(_scope, _workspace), do: false

  def can_unban_member?(%Scope{} = scope, %Workspace{} = workspace),
    do: has_workspace_role?(scope, workspace, [Roles.owner()])

  def can_unban_member?(_scope, _workspace), do: false

  @doc """
  Whether an actor holding `actor_role` may delete, as a moderator, a message
  authored by a member holding `author_role`.

  This is the single definition of the message-delete moderation rule — owners
  and admins may delete messages authored by admins and members; nobody may
  delete an owner's message. It is consumed by the Chat context for both delete
  enforcement and the channel view's delete affordance. Deleting one's own
  message is not a moderation decision and is handled by the caller.
  """
  @spec can_delete_message?(String.t() | nil, String.t() | nil) :: boolean()
  def can_delete_message?(actor_role, author_role),
    do: Roles.can_moderate?(actor_role, author_role)

  @doc """
  Returns the moderation and Role actions available to an actor for one workspace member.

  Self, owner, foreign-workspace, and unauthorized targets return an empty action list.
  Active mute and timeout actions are represented by their corresponding removal actions.
  """
  @spec available_member_actions(term(), struct(), struct()) :: [member_action()]
  def available_member_actions(
        %Scope{user: %User{id: actor_user_id}},
        %Workspace{id: workspace_id},
        %WorkspaceMembership{workspace_id: workspace_id, user_id: actor_user_id}
      ) do
    []
  end

  def available_member_actions(
        %Scope{} = scope,
        %Workspace{id: workspace_id} = workspace,
        %WorkspaceMembership{workspace_id: workspace_id} = target_membership
      ) do
    scope
    |> workspace_role(workspace)
    |> role_member_actions(target_membership)
    |> active_mute_actions(target_membership)
    |> active_timeout_actions(target_membership)
  end

  def available_member_actions(_scope, _workspace, _target_membership), do: []

  @doc """
  Batched twin of `available_member_actions/3`. Given the actor's scope, the
  workspace, and the list of target Workspace Memberships, returns a map of
  `target_user_id => action_set`.

  Calling `available_member_actions/3` per member issues roughly three queries
  each (actor role, active mute, active timeout). This instead fetches the
  actor's Role once and loads every target's active moderations in a single
  query, deriving each action set in memory, so the query count does not grow
  with the number of members. The action sets are identical to
  `available_member_actions/3`, including the mute→unmute and
  timeout→remove-timeout swaps and the empty sets for self and owner targets.
  """
  @spec available_member_actions_by_user_id(term(), struct(), [struct()]) ::
          %{Ecto.UUID.t() => [member_action()]}
  def available_member_actions_by_user_id(scope, workspace, members)

  def available_member_actions_by_user_id(
        %Scope{user: %User{id: actor_user_id}} = scope,
        %Workspace{id: workspace_id} = workspace,
        members
      )
      when is_list(members) do
    actor_role = workspace_role(scope, workspace)
    target_user_ids = for %WorkspaceMembership{} = membership <- members, do: membership.user_id
    moderation = active_moderation_flags(workspace_id, target_user_ids)

    Map.new(members, fn %WorkspaceMembership{} = membership ->
      {membership.user_id,
       batched_member_actions(actor_role, actor_user_id, workspace_id, membership, moderation)}
    end)
  end

  def available_member_actions_by_user_id(_scope, _workspace, members) when is_list(members) do
    Map.new(members, &{&1.user_id, []})
  end

  @doc """
  Ends a permitted target's current Voice Session in one Voice Channel.

  This applies the existing Workspace Member moderation authorization without
  changing durable membership or moderation state. A missing or stale matching
  Voice Session is a successful no-op.
  """
  @spec voice_disconnect_member(Scope.t(), term(), term(), term()) ::
          :ok | {:error, reason() | term()}
  def voice_disconnect_member(
        %Scope{user: %User{}} = scope,
        workspace_id,
        voice_channel_id,
        target_user_id
      ) do
    with {:ok, %Workspace{} = workspace} <- fetch_workspace(scope, workspace_id),
         {:ok, %VoiceChannel{} = voice_channel} <-
           fetch_voice_channel(scope, workspace.id, voice_channel_id),
         {:ok, %WorkspaceMembership{} = target_membership} <-
           get_workspace_membership(workspace.id, target_user_id),
         :ok <- authorize_voice_disconnect(scope, workspace, target_membership) do
      Voice.end_user_session(voice_channel.id, target_membership.user_id)
    end
  end

  def voice_disconnect_member(_scope, _workspace_id, _voice_channel_id, _target_user_id),
    do: {:error, :unauthenticated}

  @doc """
  Applies a mute and its audit event atomically, then broadcasts the committed change.

  Returns the moderation record, a tagged validation changeset, or a normalized reason.
  """
  @spec mute_member(term(), Ecto.UUID.t(), Ecto.UUID.t()) :: context_result(term())
  @spec mute_member(term(), Ecto.UUID.t(), Ecto.UUID.t(), map()) :: context_result(term())
  def mute_member(scope, workspace_id, target_user_id, attrs \\ %{})

  def mute_member(%Scope{user: %User{}} = scope, workspace_id, target_user_id, attrs)
      when is_map(attrs) do
    with {:ok, workspace} <- fetch_workspace(scope, workspace_id),
         {:ok, target_membership} <- get_workspace_membership(workspace.id, target_user_id),
         :ok <- authorize_mute_member(scope, workspace, target_membership) do
      mute_member_with_audit(scope, target_membership, attrs)
    end
  end

  def mute_member(%Scope{user: %User{}}, _workspace_id, _target_user_id, _attrs),
    do: {:error, :invalid_attrs}

  def mute_member(_scope, _workspace_id, _target_user_id, _attrs),
    do: {:error, :unauthenticated}

  @doc """
  Ends an active mute and records the audit event in one transaction.

  Returns the ended moderation record or a normalized error reason.
  """
  @spec unmute_member(term(), Ecto.UUID.t(), Ecto.UUID.t()) :: context_result(term())
  def unmute_member(%Scope{user: %User{}} = scope, workspace_id, target_user_id) do
    with {:ok, workspace} <- fetch_workspace(scope, workspace_id),
         {:ok, target_membership} <- get_workspace_membership(workspace.id, target_user_id),
         :ok <- authorize_unmute_member(scope, workspace, target_membership),
         {:ok, moderation} <- fetch_active_moderation(workspace.id, target_user_id, @mute_type) do
      unmute_member_with_audit(scope, moderation)
    end
  end

  def unmute_member(_scope, _workspace_id, _target_user_id), do: {:error, :unauthenticated}

  @doc """
  Applies a timed moderation and its audit event atomically, then schedules expiry.

  Returns the moderation record, a tagged validation changeset, or a normalized reason.
  """
  @spec timeout_member(term(), Ecto.UUID.t(), Ecto.UUID.t(), String.t()) ::
          context_result(term())
  @spec timeout_member(term(), Ecto.UUID.t(), Ecto.UUID.t(), String.t(), map()) ::
          context_result(term())
  def timeout_member(scope, workspace_id, target_user_id, duration, attrs \\ %{})

  def timeout_member(
        %Scope{user: %User{}} = scope,
        workspace_id,
        target_user_id,
        duration,
        attrs
      )
      when is_binary(duration) and is_map(attrs) do
    with {:ok, expires_at} <- timeout_expires_at(duration),
         {:ok, workspace} <- fetch_workspace(scope, workspace_id),
         {:ok, target_membership} <- get_workspace_membership(workspace.id, target_user_id),
         :ok <- authorize_timeout_member(scope, workspace, target_membership),
         {:ok, _expired_timeout} <- expire_due_timeout_for_target(workspace.id, target_user_id) do
      timeout_member_with_audit(scope, target_membership, duration, expires_at, attrs)
    end
  end

  def timeout_member(%Scope{user: %User{}}, _workspace_id, _target_user_id, _duration, _attrs),
    do: {:error, :invalid_attrs}

  def timeout_member(_scope, _workspace_id, _target_user_id, _duration, _attrs),
    do: {:error, :unauthenticated}

  @doc """
  Ends an active timeout, records the audit event, and cancels scheduled expiry.

  Returns the ended moderation record or a normalized error reason.
  """
  @spec remove_member_timeout(term(), Ecto.UUID.t(), Ecto.UUID.t()) :: context_result(term())
  def remove_member_timeout(%Scope{user: %User{}} = scope, workspace_id, target_user_id) do
    with {:ok, workspace} <- fetch_workspace(scope, workspace_id),
         {:ok, target_membership} <- get_workspace_membership(workspace.id, target_user_id),
         :ok <- authorize_remove_member_timeout(scope, workspace, target_membership),
         {:ok, moderation} <- fetch_active_moderation(workspace.id, target_user_id, @timeout_type) do
      remove_member_timeout_with_audit(scope, moderation)
    end
  end

  def remove_member_timeout(_scope, _workspace_id, _target_user_id),
    do: {:error, :unauthenticated}

  def kick_member(scope, workspace_id, target_user_id, attrs \\ %{})

  def kick_member(%Scope{user: %User{}} = scope, workspace_id, target_user_id, attrs)
      when is_map(attrs) do
    with {:ok, workspace} <- fetch_workspace(scope, workspace_id),
         {:ok, target_membership} <- get_workspace_membership(workspace.id, target_user_id),
         :ok <- authorize_kick_member(scope, workspace, target_membership),
         {:ok, reason} <- validate_required_reason(attrs) do
      kick_member_with_audit(scope, workspace, target_membership, reason)
    end
  end

  def kick_member(%Scope{user: %User{}}, _workspace_id, _target_user_id, _attrs),
    do: {:error, :invalid_attrs}

  def kick_member(_scope, _workspace_id, _target_user_id, _attrs),
    do: {:error, :unauthenticated}

  def ban_member(scope, workspace_id, target_user_id, attrs \\ %{})

  def ban_member(%Scope{user: %User{}} = scope, workspace_id, target_user_id, attrs)
      when is_map(attrs) do
    with {:ok, workspace} <- fetch_workspace(scope, workspace_id),
         {:ok, target_membership} <- get_workspace_membership(workspace.id, target_user_id),
         :ok <- authorize_ban_member(scope, workspace, target_membership),
         {:ok, reason} <- validate_required_reason(attrs),
         {:ok, cleanup_window} <- resolve_ban_cleanup_window(scope, workspace, attrs) do
      ban_member_with_audit(scope, workspace, target_membership, reason, cleanup_window)
    end
  end

  def ban_member(%Scope{user: %User{}}, _workspace_id, _target_user_id, _attrs),
    do: {:error, :invalid_attrs}

  def ban_member(_scope, _workspace_id, _target_user_id, _attrs),
    do: {:error, :unauthenticated}

  def workspace_banned?(workspace_id, user_id) do
    UUIDIdentifier.cast_or([workspace_id, user_id], false, fn [workspace_id, user_id] ->
      Repo.exists?(
        from ban in WorkspaceBan,
          where: ban.workspace_id == ^workspace_id and ban.target_user_id == ^user_id
      )
    end)
  end

  def unban_member(%Scope{user: %User{}} = scope, workspace_id, target_user_id) do
    with {:ok, workspace} <- fetch_workspace(scope, workspace_id),
         :ok <- authorize_unban_member(scope, workspace),
         {:ok, ban} <- get_workspace_ban(workspace.id, target_user_id) do
      unban_member_with_audit(scope, workspace, ban)
    end
  end

  def unban_member(_scope, _workspace_id, _target_user_id), do: {:error, :unauthenticated}

  def list_active_future_timeouts(workspace_id) do
    now = DateTime.utc_now(:second)

    UUIDIdentifier.cast_or(workspace_id, [], fn workspace_id ->
      Repo.all(
        from moderation in WorkspaceModeration,
          where:
            moderation.workspace_id == ^workspace_id and
              moderation.type == ^@timeout_type and
              moderation.active? == true and
              moderation.expires_at > ^now,
          order_by: [asc: moderation.expires_at, asc: moderation.id]
      )
    end)
  end

  @doc """
  Expires a timeout by id and records the automatic audit event atomically.

  Returns the ended moderation record or a normalized error reason.
  """
  @spec expire_member_timeout(Ecto.UUID.t()) :: context_result(term())
  def expire_member_timeout(moderation_id) do
    moderation =
      UUIDIdentifier.cast_or(moderation_id, nil, fn moderation_id ->
        Repo.get(WorkspaceModeration, moderation_id)
      end)

    case moderation do
      %WorkspaceModeration{
        type: @timeout_type,
        active?: true,
        expires_at: %DateTime{} = expires_at
      } =
          moderation ->
        if DateTime.compare(expires_at, DateTime.utc_now(:second)) in [:lt, :eq] do
          expire_member_timeout_with_audit(moderation)
        else
          {:ok, :not_due}
        end

      %WorkspaceModeration{type: @timeout_type, active?: false} ->
        {:ok, :already_inactive}

      %WorkspaceModeration{} ->
        {:error, :not_found}

      nil ->
        {:error, :not_found}
    end
  end

  def member_moderation_state(
        %Scope{user: %User{id: actor_user_id}} = scope,
        workspace_id,
        target_user_id
      ) do
    with {:ok, workspace} <- fetch_workspace(scope, workspace_id),
         {:ok, target_membership} <- get_workspace_membership(workspace.id, target_user_id),
         :ok <-
           authorize_view_member_moderation(scope, workspace, target_membership, actor_user_id) do
      mute = get_active_moderation(workspace.id, target_user_id, @mute_type)
      timeout = get_active_moderation(workspace.id, target_user_id, @timeout_type)

      {:ok,
       %{
         muted?: match?(%WorkspaceModeration{}, mute),
         mute_reason: moderation_reason(mute),
         timed_out?: match?(%WorkspaceModeration{}, timeout),
         timeout_reason: moderation_reason(timeout),
         timeout_ends_at: moderation_expires_at(timeout)
       }}
    end
  end

  def member_moderation_state(_scope, _workspace_id, _target_user_id),
    do: {:error, :unauthenticated}

  @doc """
  Whether an active mute or timeout blocks a Workspace Member from participating
  (sending messages, reacting, typing).

  Returns `:ok` when the member may participate, `{:error, :muted}` when an active
  mute is in effect, or `{:error, :timeout}` when an active, unexpired timeout is
  in effect. An active mute takes precedence over an active timeout. This is the
  single owner of the "blocked from participating" rule; the Chat context calls
  it instead of reading the moderation table directly.
  """
  @spec member_participation_status(Ecto.UUID.t(), Ecto.UUID.t()) ::
          :ok | {:error, :muted | :timeout}
  def member_participation_status(workspace_id, user_id) do
    cond do
      match?(%WorkspaceModeration{}, get_active_moderation(workspace_id, user_id, @mute_type)) ->
        {:error, :muted}

      match?(%WorkspaceModeration{}, get_active_moderation(workspace_id, user_id, @timeout_type)) ->
        {:error, :timeout}

      true ->
        :ok
    end
  end

  @doc false
  @spec workspace_mute_active?(Ecto.UUID.t(), Ecto.UUID.t()) :: boolean()
  def workspace_mute_active?(workspace_id, user_id) do
    match?(%WorkspaceModeration{}, get_active_moderation(workspace_id, user_id, @mute_type))
  end

  def change_member_role(
        %Scope{user: %User{}} = scope,
        workspace_id,
        target_user_id,
        role
      )
      when is_binary(role) do
    with {:ok, workspace} <- fetch_workspace(scope, workspace_id),
         :ok <- authorize_manage_roles(scope, workspace),
         {:ok, membership} <- get_workspace_membership(workspace.id, target_user_id),
         :ok <- reject_owner_role_change(membership),
         :ok <- authorize_role_transition(membership.role, role) do
      change_member_role_with_audit(scope, membership, role)
    end
  end

  def change_member_role(%Scope{user: %User{}}, _workspace_id, _target_user_id, _role),
    do: {:error, :invalid_attrs}

  def change_member_role(_scope, _workspace_id, _target_user_id, _role),
    do: {:error, :unauthenticated}

  def list_audit_events(%Scope{user: %User{}} = scope, workspace_id) do
    with {:ok, workspace} <- fetch_workspace(scope, workspace_id),
         :ok <- authorize_view_audit_events(scope, workspace) do
      audit_events =
        Repo.all(
          from audit_event in WorkspaceAuditEvent,
            where: audit_event.workspace_id == ^workspace.id,
            order_by: [desc: audit_event.inserted_at, desc: audit_event.id],
            preload: [:actor_user, :target_user]
        )

      {:ok, audit_events}
    end
  end

  def list_audit_events(_scope, _workspace_id), do: {:error, :unauthenticated}

  def list_banned_members(%Scope{user: %User{}} = scope, workspace_id) do
    with {:ok, workspace} <- fetch_workspace(scope, workspace_id),
         :ok <- authorize_unban_member(scope, workspace) do
      banned_members =
        Repo.all(
          from ban in WorkspaceBan,
            where: ban.workspace_id == ^workspace.id,
            order_by: [desc: ban.inserted_at, desc: ban.id],
            preload: [:target_user, :banned_by_user]
        )

      {:ok, banned_members}
    end
  end

  def list_banned_members(_scope, _workspace_id), do: {:error, :unauthenticated}

  def subscribe_to_workspace_moderation(%Scope{user: %User{id: user_id}}, workspace_id) do
    with :ok <- authorize_view_workspace(workspace_id, user_id) do
      Phoenix.PubSub.subscribe(DiscordClone.PubSub, workspace_moderation_topic(workspace_id))
    end
  end

  def subscribe_to_workspace_moderation(_scope, _workspace_id), do: {:error, :unauthenticated}

  def subscribe_to_workspace_events(%Scope{user: %User{id: user_id}}, workspace_id) do
    with :ok <- authorize_view_workspace(workspace_id, user_id) do
      Phoenix.PubSub.subscribe(DiscordClone.PubSub, workspace_events_topic(workspace_id))
    end
  end

  def subscribe_to_workspace_events(_scope, _workspace_id), do: {:error, :unauthenticated}

  def preview_workspace_invite(%Scope{user: %User{} = user}, code) when is_binary(code) do
    with {:ok, invite} <- get_invite_by_code(code),
         :ok <- validate_invite_usable(invite),
         :ok <- validate_not_banned(invite.workspace_id, user.id) do
      {:ok,
       %{
         invite_code: invite.code,
         workspace_name: invite.workspace.name,
         inviter_username: inviter_username(invite),
         accepting_username: user.username
       }}
    end
  end

  def preview_workspace_invite(%Scope{user: %User{}}, _code), do: {:error, :not_found}

  def preview_workspace_invite(_scope, _code), do: {:error, :unauthenticated}

  def accept_workspace_invite(%Scope{user: %User{} = user} = scope, code) when is_binary(code) do
    Multi.new()
    |> Multi.run(:invite, fn repo, _changes ->
      get_invite_by_code_for_update(repo, code)
    end)
    |> Multi.run(:invite_usable, fn _repo, %{invite: invite} ->
      case validate_invite_usable(invite) do
        :ok -> {:ok, invite}
        {:error, reason} -> {:error, reason}
      end
    end)
    |> Multi.run(:not_banned, fn _repo, %{invite: invite} ->
      case validate_not_banned(invite.workspace_id, user.id) do
        :ok -> {:ok, :not_banned}
        {:error, reason} -> {:error, reason}
      end
    end)
    |> Multi.run(:membership, fn repo, %{invite: invite} ->
      ensure_invite_membership(repo, invite, user)
    end)
    |> Multi.run(:member_channel_reads, fn _repo,
                                           %{
                                             invite: invite,
                                             membership: membership_result
                                           } ->
      initialize_invite_member_reads(user, invite, membership_result)
    end)
    |> Multi.run(:audit_event, fn repo, %{invite: invite, membership: membership_result} ->
      insert_invite_join_audit(repo, invite, membership_result, user)
    end)
    |> Multi.run(:invite_usage, fn repo, %{invite: invite, membership: membership_result} ->
      update_invite_usage(repo, invite, membership_result)
    end)
    |> Repo.transaction()
    |> handle_accept_invite_result(scope)
  end

  def accept_workspace_invite(%Scope{user: %User{}}, _code), do: {:error, :not_found}

  def accept_workspace_invite(_scope, _code), do: {:error, :unauthenticated}

  def rename_channel(%Scope{user: %User{}} = scope, workspace_id, channel_id, attrs)
      when is_map(attrs) do
    with {:ok, workspace} <- fetch_workspace(scope, workspace_id),
         :ok <- authorize_rename_channel(scope, workspace),
         {:ok, channel} <- get_channel(workspace.id, channel_id) do
      channel
      |> Channel.rename_changeset(channel_rename_attrs(attrs))
      |> Repo.update()
      |> case do
        {:ok, channel} -> {:ok, channel}
        {:error, changeset} -> {:error, :invalid_channel, changeset}
      end
    end
  end

  def rename_channel(%Scope{user: %User{}}, _workspace_id, _channel_id, _attrs),
    do: {:error, :invalid_attrs}

  def rename_channel(_scope, _workspace_id, _channel_id, _attrs), do: {:error, :unauthenticated}

  def delete_channel(%Scope{user: %User{}} = scope, workspace_id, channel_id) do
    with {:ok, workspace} <- fetch_workspace(scope, workspace_id),
         :ok <- authorize_delete_channel(scope, workspace),
         {:ok, channel} <- get_channel(workspace.id, channel_id),
         :ok <- reject_landing_channel_delete(workspace, channel) do
      case Repo.delete!(Repo.get!(Conversation, channel.id)) do
        %Conversation{} -> {:ok, channel}
      end
    end
  end

  def delete_channel(_scope, _workspace_id, _channel_id), do: {:error, :unauthenticated}

  def rename_voice_channel(%Scope{user: %User{}} = scope, workspace_id, voice_channel_id, attrs)
      when is_map(attrs) do
    with {:ok, workspace} <- fetch_workspace(scope, workspace_id),
         :ok <- authorize_rename_voice_channel(scope, workspace),
         {:ok, voice_channel} <- get_voice_channel(workspace.id, voice_channel_id) do
      voice_channel
      |> VoiceChannel.rename_changeset(channel_rename_attrs(attrs))
      |> Repo.update()
      |> case do
        {:ok, voice_channel} ->
          :ok = broadcast_workspace_voice_channels_changed(voice_channel.workspace_id)
          {:ok, voice_channel}

        {:error, changeset} ->
          {:error, :invalid_voice_channel, changeset}
      end
    end
  end

  def rename_voice_channel(%Scope{user: %User{}}, _workspace_id, _voice_channel_id, _attrs),
    do: {:error, :invalid_attrs}

  def rename_voice_channel(_scope, _workspace_id, _voice_channel_id, _attrs),
    do: {:error, :unauthenticated}

  def delete_voice_channel(%Scope{user: %User{}} = scope, workspace_id, voice_channel_id) do
    with {:ok, workspace} <- fetch_workspace(scope, workspace_id),
         :ok <- authorize_delete_voice_channel(scope, workspace),
         {:ok, voice_channel} <- get_voice_channel(workspace.id, voice_channel_id),
         {:ok, deleted_voice_channel} <- Repo.delete(voice_channel) do
      :ok = Voice.end_channel_sessions(deleted_voice_channel.id)
      :ok = broadcast_workspace_voice_channels_changed(deleted_voice_channel.workspace_id)
      {:ok, deleted_voice_channel}
    end
  end

  def delete_voice_channel(_scope, _workspace_id, _voice_channel_id),
    do: {:error, :unauthenticated}

  @doc """
  Removes the current member and their workspace-scoped read state atomically.

  Returns the removed membership or a normalized reason. Transaction internals remain
  logged inside the context and are not part of the public contract.
  """
  @spec leave_workspace(term(), Ecto.UUID.t()) :: context_result(struct())
  def leave_workspace(%Scope{user: %User{id: user_id}}, workspace_id) do
    with {:ok, _workspace} <- get_workspace(workspace_id),
         {:ok, membership} <- get_workspace_membership(workspace_id, user_id),
         :ok <- reject_owner_leave(membership) do
      voice_channel_ids = voice_channel_ids_for_workspace(workspace_id)

      Multi.new()
      |> Multi.run(:channel_reads, fn _repo, _changes ->
        :ok = Chat.delete_workspace_reads_for_user(user_id, workspace_id)
        {:ok, :deleted}
      end)
      |> delete_workspace_activity(user_id, workspace_id)
      |> Multi.delete(:membership, membership)
      |> Repo.transaction()
      |> case do
        {:ok, %{membership: membership, activity_items: {removed_count, _}}} ->
          if removed_count > 0 do
            :ok = Chat.broadcast_activity_removed(user_id, %{workspace_id: workspace_id})
          end

          :ok = end_voice_user_sessions(voice_channel_ids, user_id)

          {:ok, membership}

        {:error, failed_operation, failed_value, changes_so_far} ->
          log_transaction_failure(
            "leave workspace",
            failed_operation,
            failed_value,
            changes_so_far
          )

          {:error, :leave_workspace_failed}
      end
    end
  end

  def leave_workspace(_scope, _workspace_id), do: {:error, :unauthenticated}

  def delete_workspace(%Scope{user: %User{}} = scope, workspace_id) do
    with {:ok, workspace} <- get_workspace(workspace_id),
         :ok <- authorize_delete_workspace(scope, workspace) do
      voice_channel_ids = voice_channel_ids_for_workspace(workspace.id)

      with {:ok, deleted_workspace} <- delete_workspace_with_conversations(workspace) do
        :ok = end_voice_channel_sessions(voice_channel_ids)
        :ok = Chat.stop_workspace_presence(deleted_workspace.id)
        {:ok, deleted_workspace}
      end
    end
  end

  def delete_workspace(_scope, _workspace_id), do: {:error, :unauthenticated}

  defp delete_workspace_with_conversations(%Workspace{} = workspace) do
    Repo.transaction(fn ->
      Repo.update_all(
        from(selected_workspace in Workspace, where: selected_workspace.id == ^workspace.id),
        set: [default_channel_id: nil]
      )

      conversation_ids =
        from(channel in Channel,
          where: channel.workspace_id == ^workspace.id,
          select: channel.id
        )

      Repo.delete_all(
        from conversation in Conversation,
          where: conversation.id in subquery(conversation_ids)
      )

      Repo.delete!(workspace)
    end)
  end

  defp get_attr(attrs, key) do
    string_key = Atom.to_string(key)

    cond do
      Map.has_key?(attrs, key) -> Map.fetch!(attrs, key)
      Map.has_key?(attrs, string_key) -> Map.fetch!(attrs, string_key)
      true -> nil
    end
  end

  defp channel_attrs(workspace_id, attrs) do
    %{
      name: get_attr(attrs, :name),
      workspace_id: workspace_id
    }
  end

  defp channel_rename_attrs(attrs) do
    %{
      name: get_attr(attrs, :name)
    }
  end

  defp invite_form_attrs(attrs) do
    %{
      expires_at: get_attr(attrs, :expires_at),
      max_uses: get_attr(attrs, :max_uses)
    }
  end

  defp invite_creation_attrs(workspace_id, user, attrs) do
    %{
      workspace_id: workspace_id,
      created_by_user_id: user.id,
      code: invite_code(),
      expires_at:
        get_attr(attrs, :expires_at) ||
          DateTime.add(DateTime.utc_now(:second), @default_invite_ttl_minutes, :minute),
      max_uses: get_attr(attrs, :max_uses),
      uses_count: 0,
      revoked_at: nil
    }
  end

  defp invite_code do
    @invite_code_bytes
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp get_workspace(workspace_id) do
    workspace =
      UUIDIdentifier.cast_or(workspace_id, nil, fn workspace_id ->
        Repo.get(Workspace, workspace_id)
      end)

    case workspace do
      %Workspace{} = workspace -> {:ok, workspace}
      nil -> {:error, :not_found}
    end
  end

  defp get_channel(workspace_id, channel_id) do
    channel =
      UUIDIdentifier.cast_or([workspace_id, channel_id], nil, fn [workspace_id, channel_id] ->
        Repo.get_by(Channel, id: channel_id, workspace_id: workspace_id)
      end)

    case channel do
      %Channel{} = channel -> {:ok, channel}
      nil -> {:error, :not_found}
    end
  end

  defp get_voice_channel(workspace_id, voice_channel_id) do
    voice_channel =
      UUIDIdentifier.cast_or([workspace_id, voice_channel_id], nil, fn [
                                                                         workspace_id,
                                                                         voice_channel_id
                                                                       ] ->
        Repo.get_by(VoiceChannel, id: voice_channel_id, workspace_id: workspace_id)
      end)

    case voice_channel do
      %VoiceChannel{} = voice_channel -> {:ok, voice_channel}
      nil -> {:error, :not_found}
    end
  end

  defp get_invite_by_code(code) do
    query =
      from invite in WorkspaceInvite,
        where: invite.code == ^code,
        preload: [:workspace, :created_by_user]

    case Repo.one(query) do
      %WorkspaceInvite{} = invite -> {:ok, invite}
      nil -> {:error, :not_found}
    end
  end

  defp get_invite_by_code_for_update(repo, code) do
    query =
      from invite in WorkspaceInvite,
        where: invite.code == ^code,
        lock: "FOR UPDATE"

    case repo.one(query) do
      %WorkspaceInvite{} = invite -> {:ok, invite}
      nil -> {:error, :not_found}
    end
  end

  defp validate_invite_usable(%WorkspaceInvite{revoked_at: %DateTime{}}),
    do: {:error, :revoked}

  defp validate_invite_usable(%WorkspaceInvite{expires_at: %DateTime{} = expires_at} = invite) do
    if DateTime.compare(expires_at, DateTime.utc_now(:second)) == :gt do
      validate_invite_capacity(invite)
    else
      {:error, :expired}
    end
  end

  defp validate_invite_usable(%WorkspaceInvite{} = invite), do: validate_invite_capacity(invite)

  defp validate_invite_capacity(%WorkspaceInvite{max_uses: max_uses, uses_count: uses_count})
       when is_integer(max_uses) and uses_count >= max_uses,
       do: {:error, :full}

  defp validate_invite_capacity(%WorkspaceInvite{}), do: :ok

  defp validate_not_banned(workspace_id, user_id) do
    if workspace_banned?(workspace_id, user_id), do: {:error, :banned}, else: :ok
  end

  defp ensure_invite_membership(
         repo,
         %WorkspaceInvite{workspace_id: workspace_id},
         %User{id: user_id}
       ) do
    case repo.get_by(WorkspaceMembership, workspace_id: workspace_id, user_id: user_id) do
      %WorkspaceMembership{} = membership ->
        {:ok, {:existing_member, membership}}

      nil ->
        insert_invite_membership(repo, workspace_id, user_id)
    end
  end

  defp insert_invite_membership(
         repo,
         workspace_id,
         user_id
       ) do
    %WorkspaceMembership{}
    |> WorkspaceMembership.changeset(%{
      workspace_id: workspace_id,
      user_id: user_id,
      role: Roles.member()
    })
    |> repo.insert()
    |> case do
      {:ok, membership} -> {:ok, {:new_member, membership}}
      {:error, changeset} -> {:error, {:invalid_membership, changeset}}
    end
  end

  defp update_invite_usage(repo, %WorkspaceInvite{} = invite, {:new_member, _membership}) do
    invite
    |> WorkspaceInvite.increment_usage_changeset()
    |> repo.update()
  end

  defp update_invite_usage(_repo, %WorkspaceInvite{} = invite, {:existing_member, _membership}) do
    {:ok, invite}
  end

  defp initialize_invite_member_reads(
         %User{id: user_id},
         %WorkspaceInvite{workspace_id: workspace_id},
         {:new_member, _membership}
       ) do
    case Chat.initialize_workspace_reads_for_user(user_id, workspace_id) do
      :ok -> {:ok, :initialized}
      {:error, reason} -> {:error, reason}
    end
  end

  defp initialize_invite_member_reads(
         %User{},
         %WorkspaceInvite{},
         {:existing_member, _membership}
       ) do
    {:ok, :unchanged}
  end

  defp insert_invite_join_audit(
         repo,
         %WorkspaceInvite{} = invite,
         {:new_member, %WorkspaceMembership{} = membership},
         %User{}
       ) do
    %WorkspaceAuditEvent{}
    |> WorkspaceAuditEvent.changeset(%{
      workspace_id: invite.workspace_id,
      actor_user_id: invite.created_by_user_id,
      target_user_id: membership.user_id,
      event_type: "member_joined_from_invite",
      metadata: %{"invite_id" => invite.id}
    })
    |> repo.insert()
  end

  defp insert_invite_join_audit(
         _repo,
         %WorkspaceInvite{},
         {:existing_member, %WorkspaceMembership{}},
         %User{}
       ) do
    {:ok, :unchanged}
  end

  defp already_member?({:existing_member, _membership}), do: true
  defp already_member?({:new_member, _membership}), do: false

  defp handle_accept_invite_result(
         {:ok, %{invite: invite, membership: membership_result}},
         %Scope{} = scope
       ) do
    with {:ok, channel} <- resolve_landing_channel(scope, invite.workspace_id) do
      :ok = maybe_broadcast_invite_join(scope, invite, membership_result, channel)

      {:ok,
       %{
         workspace_id: invite.workspace_id,
         channel_id: channel.id,
         already_member?: already_member?(membership_result)
       }}
    end
  end

  defp handle_accept_invite_result({:error, _operation, reason, _changes_so_far}, _scope) do
    normalize_accept_invite_error(reason)
  end

  defp normalize_accept_invite_error({:invalid_membership, changeset}),
    do: {:error, :invalid_membership, changeset}

  defp normalize_accept_invite_error(reason), do: {:error, reason}

  defp maybe_broadcast_invite_join(
         %Scope{user: %User{id: user_id, username: username}} = scope,
         %WorkspaceInvite{} = invite,
         {:new_member, _membership},
         %Channel{} = channel
       ) do
    :ok = Chat.broadcast_workspace_user_joined(invite.workspace_id, user_id)
    :ok = broadcast_workspace_member_joined(invite.workspace_id, user_id)
    :ok = broadcast_workspace_audit_changed(invite.workspace_id)

    case Chat.send_message(scope, channel.id, %{
           "content" => "#{username} joined from an invite."
         }) do
      {:ok, _message} -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp maybe_broadcast_invite_join(
         %Scope{},
         %WorkspaceInvite{},
         {:existing_member, _membership},
         %Channel{}
       ) do
    :ok
  end

  defp inviter_username(%WorkspaceInvite{created_by_user: %User{username: username}}),
    do: username

  defp inviter_username(_invite), do: nil

  defp get_workspace_membership(workspace_id, user_id) do
    membership =
      UUIDIdentifier.cast_or([workspace_id, user_id], nil, fn [workspace_id, user_id] ->
        Repo.get_by(WorkspaceMembership, workspace_id: workspace_id, user_id: user_id)
      end)

    case membership do
      %WorkspaceMembership{} = membership -> {:ok, membership}
      nil -> {:error, :unauthorized}
    end
  end

  defp fetch_landing_channel(%Workspace{} = workspace) do
    case default_channel(workspace) do
      %Channel{} = channel -> {:ok, channel}
      nil -> {:error, :landing_channel_not_found}
    end
  end

  defp default_channel(%Workspace{default_channel_id: nil}), do: nil

  defp default_channel(%Workspace{id: workspace_id, default_channel_id: channel_id}) do
    Repo.get_by(Channel, id: channel_id, workspace_id: workspace_id)
  end

  defp channels_for_workspace_query(workspace_id) do
    from channel in Channel,
      where: channel.workspace_id == ^workspace_id,
      order_by: [asc: channel.inserted_at, asc: channel.id]
  end

  defp voice_channels_for_workspace_query(workspace_id) do
    from voice_channel in VoiceChannel,
      where: voice_channel.workspace_id == ^workspace_id,
      order_by: [asc: voice_channel.inserted_at, asc: voice_channel.id]
  end

  defp voice_channel_ids_for_workspace(workspace_id) do
    Repo.all(
      from voice_channel in VoiceChannel,
        where: voice_channel.workspace_id == ^workspace_id,
        select: voice_channel.id
    )
  end

  defp end_voice_user_sessions(voice_channel_ids, user_id) do
    Enum.each(voice_channel_ids, fn voice_channel_id ->
      _ = Voice.end_user_session(voice_channel_id, user_id)
    end)

    :ok
  end

  defp end_voice_channel_sessions(voice_channel_ids) do
    Enum.each(voice_channel_ids, fn voice_channel_id ->
      _ = Voice.end_channel_sessions(voice_channel_id)
    end)

    :ok
  end

  defp apply_workspace_mute_to_voice(%WorkspaceModeration{} = moderation, muted) do
    moderation.workspace_id
    |> voice_channel_ids_for_workspace()
    |> Enum.each(fn voice_channel_id ->
      :ok = Voice.set_workspace_muted(voice_channel_id, moderation.target_user_id, muted)
    end)

    :ok
  end

  defp voice_admission_status(workspace_id, user_id) do
    case member_participation_status(workspace_id, user_id) do
      {:error, :timeout} -> {:error, :timeout}
      _eligible_or_muted -> :ok
    end
  end

  defp authorize_view_workspace(%Workspace{id: workspace_id}, %User{id: user_id}) do
    authorize_view_workspace(workspace_id, user_id)
  end

  defp authorize_view_workspace(%Workspace{id: workspace_id}, user_id) do
    authorize_view_workspace(workspace_id, user_id)
  end

  defp authorize_view_workspace(workspace_id, user_id) do
    if workspace_member?(workspace_id, user_id),
      do: :ok,
      else: {:error, :unauthorized}
  end

  defp authorize_rename_workspace(scope, workspace) do
    if can_rename_workspace?(scope, workspace), do: :ok, else: {:error, :owner_required}
  end

  defp authorize_create_channel(scope, workspace) do
    if can_create_channel?(scope, workspace), do: :ok, else: {:error, :unauthorized}
  end

  defp authorize_rename_channel(scope, workspace) do
    if can_rename_channel?(scope, workspace), do: :ok, else: {:error, :unauthorized}
  end

  defp authorize_delete_channel(scope, workspace) do
    if can_delete_channel?(scope, workspace), do: :ok, else: {:error, :owner_required}
  end

  defp authorize_create_voice_channel(scope, workspace) do
    if can_create_voice_channel?(scope, workspace), do: :ok, else: {:error, :unauthorized}
  end

  defp authorize_rename_voice_channel(scope, workspace) do
    if can_rename_voice_channel?(scope, workspace), do: :ok, else: {:error, :unauthorized}
  end

  defp authorize_delete_voice_channel(scope, workspace) do
    if can_delete_voice_channel?(scope, workspace), do: :ok, else: {:error, :unauthorized}
  end

  defp authorize_create_invite(scope, workspace) do
    if can_create_workspace_invite?(scope, workspace),
      do: :ok,
      else: {:error, :invite_permission_required}
  end

  defp authorize_delete_workspace(scope, workspace) do
    if can_delete_workspace?(scope, workspace), do: :ok, else: {:error, :owner_required}
  end

  defp authorize_manage_roles(scope, workspace) do
    if can_manage_roles?(scope, workspace), do: :ok, else: {:error, :owner_required}
  end

  defp authorize_view_audit_events(scope, workspace) do
    if can_view_audit_log?(scope, workspace), do: :ok, else: {:error, :owner_required}
  end

  defp authorize_mute_member(scope, workspace, %WorkspaceMembership{} = target_membership) do
    if :mute in available_member_actions(scope, workspace, target_membership),
      do: :ok,
      else: {:error, :unauthorized}
  end

  defp authorize_unmute_member(scope, workspace, %WorkspaceMembership{} = target_membership) do
    if :unmute in available_member_actions(scope, workspace, target_membership),
      do: :ok,
      else: {:error, :unauthorized}
  end

  defp authorize_timeout_member(scope, workspace, %WorkspaceMembership{} = target_membership) do
    if :timeout in available_member_actions(scope, workspace, target_membership),
      do: :ok,
      else: {:error, :unauthorized}
  end

  defp authorize_remove_member_timeout(
         scope,
         workspace,
         %WorkspaceMembership{} = target_membership
       ) do
    if :remove_timeout in available_member_actions(scope, workspace, target_membership),
      do: :ok,
      else: {:error, :unauthorized}
  end

  defp authorize_kick_member(scope, workspace, %WorkspaceMembership{} = target_membership) do
    if :kick in available_member_actions(scope, workspace, target_membership),
      do: :ok,
      else: {:error, :unauthorized}
  end

  defp authorize_ban_member(scope, workspace, %WorkspaceMembership{} = target_membership) do
    if :ban in available_member_actions(scope, workspace, target_membership),
      do: :ok,
      else: {:error, :unauthorized}
  end

  defp authorize_voice_disconnect(scope, workspace, %WorkspaceMembership{} = target_membership) do
    if available_member_actions(scope, workspace, target_membership) != [],
      do: :ok,
      else: {:error, :unauthorized}
  end

  defp authorize_unban_member(scope, workspace) do
    if can_unban_member?(scope, workspace), do: :ok, else: {:error, :owner_required}
  end

  defp authorize_view_member_moderation(
         _scope,
         _workspace,
         %WorkspaceMembership{user_id: target_user_id},
         actor_user_id
       )
       when target_user_id == actor_user_id,
       do: :ok

  defp authorize_view_member_moderation(scope, workspace, _target_membership, _actor_user_id) do
    if has_workspace_role?(scope, workspace, [Roles.owner(), Roles.admin()]),
      do: :ok,
      else: {:error, :unauthorized}
  end

  # Shared transaction-result handling for every moderation flow: run the multi,
  # fire the flow-specific success side effect on the resulting moderation, and
  # map the two changeset-error branches uniformly.
  defp run_moderation_multi(%Multi{} = multi, on_success) do
    multi
    |> Repo.transaction()
    |> case do
      {:ok, %{moderation: moderation}} ->
        :ok = on_success.(moderation)
        {:ok, moderation}

      {:error, :moderation, changeset, _changes_so_far} ->
        {:error, :invalid_moderation, changeset}

      {:error, :audit_event, changeset, _changes_so_far} ->
        {:error, :invalid_audit_event, changeset}
    end
  end

  # Shared shape for the three "end a moderation" flows (unmute, remove-timeout,
  # expire): flip the moderation inactive, write the audit event, and run it.
  # `actor_user_id` is nil for the automatic expiry; `metadata_fun` and
  # `on_success` carry the per-flow differences.
  defp end_moderation_with_audit(
         %WorkspaceModeration{} = moderation,
         actor_user_id,
         event_type,
         metadata_fun,
         on_success
       ) do
    Multi.new()
    |> Multi.update(
      :moderation,
      WorkspaceModeration.end_changeset(moderation, %{
        active?: false,
        ended_at: DateTime.utc_now(:second),
        ended_by_user_id: actor_user_id
      })
    )
    |> Multi.insert(:audit_event, fn %{moderation: ended_moderation} ->
      WorkspaceAuditEvent.changeset(%WorkspaceAuditEvent{}, %{
        workspace_id: ended_moderation.workspace_id,
        actor_user_id: actor_user_id,
        target_user_id: ended_moderation.target_user_id,
        event_type: event_type,
        metadata: metadata_fun.(ended_moderation)
      })
    end)
    |> run_moderation_multi(on_success)
  end

  defp base_moderation_metadata(%WorkspaceModeration{type: type}),
    do: %{"moderation_type" => type}

  defp expired_timeout_metadata(%WorkspaceModeration{} = moderation) do
    %{
      "moderation_type" => moderation.type,
      "expires_at" => DateTime.to_iso8601(moderation.expires_at)
    }
  end

  defp broadcast_moderation_changed(%WorkspaceModeration{} = moderation) do
    broadcast_workspace_moderation_changed(moderation.workspace_id, moderation.target_user_id)
  end

  defp mute_member_with_audit(
         %Scope{user: %User{id: actor_user_id}},
         %WorkspaceMembership{} = target_membership,
         attrs
       ) do
    reason = moderation_reason_attrs(attrs)

    Multi.new()
    |> Multi.insert(
      :moderation,
      WorkspaceModeration.create_changeset(%WorkspaceModeration{}, %{
        workspace_id: target_membership.workspace_id,
        target_user_id: target_membership.user_id,
        created_by_user_id: actor_user_id,
        type: @mute_type,
        reason: reason
      })
    )
    |> Multi.insert(:audit_event, fn %{moderation: moderation} ->
      WorkspaceAuditEvent.changeset(%WorkspaceAuditEvent{}, %{
        workspace_id: moderation.workspace_id,
        actor_user_id: actor_user_id,
        target_user_id: moderation.target_user_id,
        event_type: "member_muted",
        reason: moderation.reason,
        metadata: %{"moderation_type" => moderation.type}
      })
    end)
    |> run_moderation_multi(fn moderation ->
      apply_workspace_mute_to_voice(moderation, true)
      broadcast_moderation_changed(moderation)
    end)
  end

  defp unmute_member_with_audit(
         %Scope{user: %User{id: actor_user_id}},
         %WorkspaceModeration{} = moderation
       ) do
    end_moderation_with_audit(
      moderation,
      actor_user_id,
      "member_unmuted",
      &base_moderation_metadata/1,
      fn moderation ->
        apply_workspace_mute_to_voice(moderation, false)
        broadcast_moderation_changed(moderation)
      end
    )
  end

  defp timeout_member_with_audit(
         %Scope{user: %User{id: actor_user_id}},
         %WorkspaceMembership{} = target_membership,
         duration,
         expires_at,
         attrs
       ) do
    reason = moderation_reason_attrs(attrs)

    Multi.new()
    |> Multi.insert(
      :moderation,
      WorkspaceModeration.create_changeset(%WorkspaceModeration{}, %{
        workspace_id: target_membership.workspace_id,
        target_user_id: target_membership.user_id,
        created_by_user_id: actor_user_id,
        type: @timeout_type,
        reason: reason,
        expires_at: expires_at
      })
    )
    |> Multi.insert(:audit_event, fn %{moderation: moderation} ->
      WorkspaceAuditEvent.changeset(%WorkspaceAuditEvent{}, %{
        workspace_id: moderation.workspace_id,
        actor_user_id: actor_user_id,
        target_user_id: moderation.target_user_id,
        event_type: "member_timed_out",
        reason: moderation.reason,
        metadata: %{
          "moderation_type" => moderation.type,
          "duration" => duration,
          "expires_at" => DateTime.to_iso8601(moderation.expires_at)
        }
      })
    end)
    |> run_moderation_multi(fn moderation ->
      :ok = Chat.schedule_workspace_timeout_expiry(moderation)

      :ok =
        end_voice_user_sessions(
          voice_channel_ids_for_workspace(moderation.workspace_id),
          moderation.target_user_id
        )

      broadcast_moderation_changed(moderation)
    end)
  end

  defp remove_member_timeout_with_audit(
         %Scope{user: %User{id: actor_user_id}},
         %WorkspaceModeration{} = moderation
       ) do
    end_moderation_with_audit(
      moderation,
      actor_user_id,
      "member_timeout_removed",
      &base_moderation_metadata/1,
      fn ended_moderation ->
        :ok = Chat.cancel_workspace_timeout_expiry(ended_moderation)
        broadcast_moderation_changed(ended_moderation)
      end
    )
  end

  defp kick_member_with_audit(
         %Scope{user: %User{id: actor_user_id}},
         %Workspace{} = workspace,
         %WorkspaceMembership{} = target_membership,
         reason
       ) do
    target_user_id = target_membership.user_id
    voice_channel_ids = voice_channel_ids_for_workspace(workspace.id)
    active_timeouts = active_timeout_moderations(workspace.id, target_user_id)

    Multi.new()
    |> Multi.delete_all(
      :moderations,
      from(moderation in WorkspaceModeration,
        where:
          moderation.workspace_id == ^workspace.id and
            moderation.target_user_id == ^target_user_id
      )
    )
    |> Multi.run(:channel_reads, fn _repo, _changes ->
      :ok = Chat.delete_workspace_reads_for_user(target_user_id, workspace.id)
      {:ok, :deleted}
    end)
    |> delete_workspace_activity(target_user_id, workspace.id)
    |> Multi.delete(:membership, target_membership)
    |> Multi.insert(
      :audit_event,
      WorkspaceAuditEvent.changeset(%WorkspaceAuditEvent{}, %{
        workspace_id: workspace.id,
        actor_user_id: actor_user_id,
        target_user_id: target_user_id,
        event_type: "member_kicked",
        reason: reason,
        metadata: %{}
      })
    )
    |> Repo.transaction()
    |> case do
      {:ok, %{membership: membership, activity_items: {removed_count, _}}} ->
        Enum.each(active_timeouts, &Chat.cancel_workspace_timeout_expiry/1)

        if removed_count > 0 do
          :ok = Chat.broadcast_activity_removed(target_user_id, %{workspace_id: workspace.id})
        end

        :ok = broadcast_workspace_audit_changed(workspace.id)
        :ok = broadcast_workspace_access_revoked(workspace.id, target_user_id)
        :ok = end_voice_user_sessions(voice_channel_ids, target_user_id)
        {:ok, membership}

      {:error, :audit_event, changeset, _changes_so_far} ->
        {:error, :invalid_audit_event, changeset}

      {:error, _failed_operation, _failed_value, _changes_so_far} ->
        {:error, :kick_failed}
    end
  end

  defp ban_member_with_audit(
         %Scope{user: %User{id: actor_user_id}},
         %Workspace{} = workspace,
         %WorkspaceMembership{} = target_membership,
         reason,
         cleanup_window
       ) do
    target_user_id = target_membership.user_id
    voice_channel_ids = voice_channel_ids_for_workspace(workspace.id)
    active_timeouts = active_timeout_moderations(workspace.id, target_user_id)

    Multi.new()
    |> Multi.insert(
      :ban,
      WorkspaceBan.create_changeset(%WorkspaceBan{}, %{
        workspace_id: workspace.id,
        target_user_id: target_user_id,
        banned_by_user_id: actor_user_id,
        reason: reason
      })
    )
    |> Multi.delete_all(
      :moderations,
      from(moderation in WorkspaceModeration,
        where:
          moderation.workspace_id == ^workspace.id and
            moderation.target_user_id == ^target_user_id
      )
    )
    |> Multi.run(:channel_reads, fn _repo, _changes ->
      :ok = Chat.delete_workspace_reads_for_user(target_user_id, workspace.id)
      {:ok, :deleted}
    end)
    |> Multi.run(:message_cleanup, fn _repo, _changes ->
      clean_up_banned_member_messages(workspace, target_user_id, actor_user_id, cleanup_window)
    end)
    |> delete_workspace_activity(target_user_id, workspace.id)
    |> Multi.delete(:membership, target_membership)
    |> Multi.insert(:audit_event, fn %{message_cleanup: cleanup} ->
      WorkspaceAuditEvent.changeset(%WorkspaceAuditEvent{}, %{
        workspace_id: workspace.id,
        actor_user_id: actor_user_id,
        target_user_id: target_user_id,
        event_type: "member_banned",
        reason: reason,
        metadata: ban_cleanup_metadata(cleanup_window, cleanup.messages)
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok,
       %{
         ban: ban,
         message_cleanup: cleanup,
         activity_items: {removed_count, _}
       }} ->
        Enum.each(active_timeouts, &Chat.cancel_workspace_timeout_expiry/1)

        if removed_count > 0 do
          :ok = Chat.broadcast_activity_removed(target_user_id, %{workspace_id: workspace.id})
        end

        :ok =
          Chat.broadcast_activity_removals(cleanup.activity_recipient_ids, %{
            workspace_id: workspace.id
          })

        :ok = Chat.broadcast_cleaned_messages(cleanup.messages)
        :ok = broadcast_workspace_audit_changed(workspace.id)
        :ok = broadcast_workspace_access_revoked(workspace.id, target_user_id)
        :ok = end_voice_user_sessions(voice_channel_ids, target_user_id)
        {:ok, ban}

      {:error, :ban, changeset, _changes_so_far} ->
        {:error, :invalid_ban, changeset}

      {:error, :audit_event, changeset, _changes_so_far} ->
        {:error, :invalid_audit_event, changeset}

      {:error, _failed_operation, _failed_value, _changes_so_far} ->
        {:error, :ban_failed}
    end
  end

  defp delete_workspace_activity(%Multi{} = multi, user_id, workspace_id) do
    Multi.delete_all(
      multi,
      :activity_items,
      from(activity_item in ActivityItem,
        where:
          activity_item.recipient_user_id == ^user_id and
            activity_item.workspace_id == ^workspace_id
      )
    )
  end

  defp get_workspace_ban(workspace_id, target_user_id) do
    ban =
      UUIDIdentifier.cast_or(
        [workspace_id, target_user_id],
        nil,
        fn [workspace_id, target_user_id] ->
          Repo.get_by(WorkspaceBan, workspace_id: workspace_id, target_user_id: target_user_id)
        end
      )

    case ban do
      %WorkspaceBan{} = ban -> {:ok, ban}
      nil -> {:error, :not_banned}
    end
  end

  defp unban_member_with_audit(
         %Scope{user: %User{id: actor_user_id}},
         %Workspace{} = workspace,
         %WorkspaceBan{} = ban
       ) do
    Multi.new()
    |> Multi.delete(:unban, ban)
    |> Multi.insert(:audit_event, fn _changes ->
      WorkspaceAuditEvent.changeset(%WorkspaceAuditEvent{}, %{
        workspace_id: workspace.id,
        actor_user_id: actor_user_id,
        target_user_id: ban.target_user_id,
        event_type: "member_unbanned",
        metadata: %{}
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{unban: unban}} ->
        :ok = broadcast_workspace_audit_changed(workspace.id)
        {:ok, unban}

      {:error, :audit_event, changeset, _changes_so_far} ->
        {:error, :invalid_audit_event, changeset}

      {:error, _failed_operation, _failed_value, _changes_so_far} ->
        {:error, :unban_failed}
    end
  end

  defp clean_up_banned_member_messages(_workspace, _target_user_id, _actor_user_id, :none),
    do: {:ok, %{messages: [], activity_recipient_ids: []}}

  defp clean_up_banned_member_messages(workspace, target_user_id, actor_user_id, cleanup_window) do
    Chat.soft_delete_user_workspace_messages_with_activity_facts(
      workspace.id,
      target_user_id,
      actor_user_id,
      ban_cleanup_bound(cleanup_window)
    )
  end

  defp ban_cleanup_bound(:all), do: :all

  defp ban_cleanup_bound({amount, unit}),
    do: DateTime.add(DateTime.utc_now(:second), -amount, unit)

  defp ban_cleanup_metadata(:none, _cleaned_messages), do: %{}

  defp ban_cleanup_metadata(cleanup_window, cleaned_messages) do
    %{
      "cleanup_window" => ban_cleanup_window_key(cleanup_window),
      "cleanup_message_count" => length(cleaned_messages)
    }
  end

  defp ban_cleanup_window_key(:all), do: @all_messages_cleanup_window

  defp ban_cleanup_window_key(spec) do
    Enum.find_value(@ban_cleanup_windows, fn {key, value} ->
      if value == spec, do: key
    end)
  end

  defp resolve_ban_cleanup_window(scope, workspace, attrs) do
    case get_attr(attrs, :cleanup_window) do
      nil ->
        {:ok, :none}

      window when is_binary(window) ->
        case Map.fetch(@ban_cleanup_windows, window) do
          {:ok, :all} -> authorize_all_message_cleanup(scope, workspace)
          {:ok, spec} -> {:ok, spec}
          :error -> {:error, :invalid_cleanup_window}
        end

      _window ->
        {:error, :invalid_cleanup_window}
    end
  end

  defp authorize_all_message_cleanup(scope, workspace) do
    if can_purge_all_workspace_messages?(scope, workspace),
      do: {:ok, :all},
      else: {:error, :cleanup_owner_required}
  end

  defp active_timeout_moderations(workspace_id, target_user_id) do
    Repo.all(
      from moderation in WorkspaceModeration,
        where:
          moderation.workspace_id == ^workspace_id and
            moderation.target_user_id == ^target_user_id and
            moderation.type == ^@timeout_type and
            moderation.active? == true
    )
  end

  defp expire_member_timeout_with_audit(%WorkspaceModeration{} = moderation) do
    end_moderation_with_audit(
      moderation,
      nil,
      "member_timeout_expired",
      &expired_timeout_metadata/1,
      &broadcast_moderation_changed/1
    )
  end

  defp timeout_expires_at(duration) do
    case Map.fetch(@timeout_duration_presets, duration) do
      {:ok, {amount, unit}} -> {:ok, DateTime.add(DateTime.utc_now(:second), amount, unit)}
      :error -> {:error, :invalid_timeout_duration}
    end
  end

  defp validate_required_reason(attrs) do
    case moderation_reason_attrs(attrs) do
      nil -> {:error, :reason_required}
      reason -> {:ok, reason}
    end
  end

  defp moderation_reason_attrs(attrs) do
    attrs
    |> get_attr(:reason)
    |> case do
      reason when is_binary(reason) ->
        reason = String.trim(reason)
        if reason == "", do: nil, else: reason

      _reason ->
        nil
    end
  end

  defp get_active_moderation(workspace_id, target_user_id, @timeout_type) do
    now = DateTime.utc_now(:second)

    UUIDIdentifier.cast_or(
      [workspace_id, target_user_id],
      nil,
      fn [workspace_id, target_user_id] ->
        Repo.one(
          from moderation in WorkspaceModeration,
            where:
              moderation.workspace_id == ^workspace_id and
                moderation.target_user_id == ^target_user_id and
                moderation.type == ^@timeout_type and
                moderation.active? == true and
                moderation.expires_at > ^now,
            limit: 1
        )
      end
    )
  end

  defp get_active_moderation(workspace_id, target_user_id, type) do
    UUIDIdentifier.cast_or(
      [workspace_id, target_user_id],
      nil,
      fn [workspace_id, target_user_id] ->
        Repo.get_by(WorkspaceModeration,
          workspace_id: workspace_id,
          target_user_id: target_user_id,
          type: type,
          active?: true
        )
      end
    )
  end

  defp fetch_active_moderation(workspace_id, target_user_id, type) do
    case get_active_moderation(workspace_id, target_user_id, type) do
      %WorkspaceModeration{} = moderation -> {:ok, moderation}
      nil -> {:error, :not_found}
    end
  end

  defp moderation_reason(%WorkspaceModeration{reason: reason}), do: reason
  defp moderation_reason(_moderation), do: nil

  defp moderation_expires_at(%WorkspaceModeration{expires_at: expires_at}), do: expires_at
  defp moderation_expires_at(_moderation), do: nil

  defp expire_due_timeout_for_target(workspace_id, target_user_id) do
    now = DateTime.utc_now(:second)

    query =
      from moderation in WorkspaceModeration,
        where:
          moderation.workspace_id == ^workspace_id and
            moderation.target_user_id == ^target_user_id and
            moderation.type == ^@timeout_type and
            moderation.active? == true and
            moderation.expires_at <= ^now,
        limit: 1

    case Repo.one(query) do
      %WorkspaceModeration{id: moderation_id} -> expire_member_timeout(moderation_id)
      nil -> {:ok, nil}
    end
  end

  defp active_mute_actions(actions, %WorkspaceMembership{} = target_membership) do
    apply_mute_swap(actions, :mute in actions and active_mute?(target_membership))
  end

  defp active_mute?(%WorkspaceMembership{workspace_id: workspace_id, user_id: user_id}) do
    match?(%WorkspaceModeration{}, get_active_moderation(workspace_id, user_id, @mute_type))
  end

  defp active_timeout_actions(actions, %WorkspaceMembership{} = target_membership) do
    apply_timeout_swap(actions, :timeout in actions and active_timeout?(target_membership))
  end

  defp active_timeout?(%WorkspaceMembership{workspace_id: workspace_id, user_id: user_id}) do
    match?(%WorkspaceModeration{}, get_active_moderation(workspace_id, user_id, @timeout_type))
  end

  # Shared mute/timeout swap applied by both the per-member and batched action
  # builders. The boolean already folds in the `:mute`/`:timeout in actions`
  # check, so a `true` value guarantees the action is present to swap.
  defp apply_mute_swap(actions, false), do: actions

  defp apply_mute_swap(actions, true) do
    Enum.map(actions, fn
      :mute -> :unmute
      action -> action
    end)
  end

  defp apply_timeout_swap(actions, false), do: actions

  defp apply_timeout_swap(actions, true) do
    Enum.map(actions, fn
      :timeout -> :remove_timeout
      action -> action
    end)
  end

  defp role_member_actions(actor_role, %WorkspaceMembership{} = target_membership) do
    cond do
      Roles.owner?(actor_role) -> owner_member_actions(target_membership)
      Roles.admin?(actor_role) -> admin_member_actions(target_membership)
      true -> []
    end
  end

  # Per-target twin of the `available_member_actions/3` clauses, reading the
  # target's mute/timeout state from the batch-loaded `moderation` flags instead
  # of querying per member. The three heads mirror the self, in-workspace, and
  # foreign-membership cases exactly.
  defp batched_member_actions(
         _actor_role,
         actor_user_id,
         workspace_id,
         %WorkspaceMembership{workspace_id: workspace_id, user_id: actor_user_id},
         _moderation
       ),
       do: []

  defp batched_member_actions(
         actor_role,
         _actor_user_id,
         workspace_id,
         %WorkspaceMembership{workspace_id: workspace_id} = target_membership,
         moderation
       ) do
    actions = role_member_actions(actor_role, target_membership)
    mute_swap = :mute in actions and moderation_mutes?(moderation, target_membership)
    timeout_swap = :timeout in actions and moderation_times_out?(moderation, target_membership)

    actions
    |> apply_mute_swap(mute_swap)
    |> apply_timeout_swap(timeout_swap)
  end

  defp batched_member_actions(
         _actor_role,
         _actor_user_id,
         _workspace_id,
         _membership,
         _moderation
       ),
       do: []

  # Loads the active mutes and unexpired active timeouts for every target user in
  # one query, returning the two sets of affected user ids. Mirrors the type
  # semantics of `get_active_moderation/3`: mutes have no expiry, timeouts must
  # be active and not yet expired.
  defp active_moderation_flags(_workspace_id, []) do
    %{muted: MapSet.new(), timed_out: MapSet.new()}
  end

  defp active_moderation_flags(workspace_id, user_ids) do
    now = DateTime.utc_now(:second)

    rows =
      Repo.all(
        from moderation in WorkspaceModeration,
          where:
            moderation.workspace_id == ^workspace_id and
              moderation.target_user_id in ^user_ids and
              moderation.active? == true and
              (moderation.type == ^@mute_type or
                 (moderation.type == ^@timeout_type and moderation.expires_at > ^now)),
          select: {moderation.target_user_id, moderation.type}
      )

    %{
      muted: MapSet.new(for {user_id, @mute_type} <- rows, do: user_id),
      timed_out: MapSet.new(for {user_id, @timeout_type} <- rows, do: user_id)
    }
  end

  defp moderation_mutes?(%{muted: muted}, %WorkspaceMembership{user_id: user_id}),
    do: MapSet.member?(muted, user_id)

  defp moderation_times_out?(%{timed_out: timed_out}, %WorkspaceMembership{user_id: user_id}),
    do: MapSet.member?(timed_out, user_id)

  defp broadcast_workspace_moderation_changed(workspace_id, target_user_id) do
    Phoenix.PubSub.broadcast(
      DiscordClone.PubSub,
      workspace_moderation_topic(workspace_id),
      {:workspace_moderation_changed,
       %{workspace_id: workspace_id, target_user_id: target_user_id}}
    )

    :ok = broadcast_workspace_audit_changed(workspace_id)
  end

  defp broadcast_workspace_access_revoked(workspace_id, target_user_id) do
    Phoenix.PubSub.broadcast(
      DiscordClone.PubSub,
      workspace_moderation_topic(workspace_id),
      {:workspace_access_revoked, %{workspace_id: workspace_id, target_user_id: target_user_id}}
    )
  end

  defp workspace_moderation_topic(workspace_id), do: "workspaces:#{workspace_id}:moderation"

  defp broadcast_workspace_member_joined(workspace_id, user_id) do
    Phoenix.PubSub.broadcast(
      DiscordClone.PubSub,
      workspace_events_topic(workspace_id),
      {:workspace_member_joined, %{workspace_id: workspace_id, user_id: user_id}}
    )
  end

  defp broadcast_workspace_channel_created(workspace_id, channel_id) do
    Phoenix.PubSub.broadcast(
      DiscordClone.PubSub,
      workspace_events_topic(workspace_id),
      {:workspace_channel_created, %{workspace_id: workspace_id, channel_id: channel_id}}
    )
  end

  defp broadcast_workspace_voice_channels_changed(workspace_id) do
    Phoenix.PubSub.broadcast(
      DiscordClone.PubSub,
      workspace_events_topic(workspace_id),
      {:workspace_voice_channels_changed, %{workspace_id: workspace_id}}
    )
  end

  defp broadcast_workspace_audit_changed(workspace_id) do
    Phoenix.PubSub.broadcast(
      DiscordClone.PubSub,
      workspace_events_topic(workspace_id),
      {:workspace_audit_changed, %{workspace_id: workspace_id}}
    )
  end

  defp workspace_events_topic(workspace_id), do: "workspaces:#{workspace_id}:events"

  defp change_member_role_with_audit(
         %Scope{user: %User{id: actor_user_id}},
         %WorkspaceMembership{} = membership,
         role
       ) do
    from_role = membership.role

    Multi.new()
    |> Multi.update(:membership, WorkspaceMembership.role_changeset(membership, %{role: role}))
    |> Multi.insert(:audit_event, fn %{membership: updated_membership} ->
      WorkspaceAuditEvent.changeset(%WorkspaceAuditEvent{}, %{
        workspace_id: updated_membership.workspace_id,
        actor_user_id: actor_user_id,
        target_user_id: updated_membership.user_id,
        event_type: role_change_event_type(from_role, updated_membership.role),
        metadata: %{"from_role" => from_role, "to_role" => updated_membership.role}
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{membership: membership}} ->
        :ok = broadcast_workspace_moderation_changed(membership.workspace_id, membership.user_id)
        {:ok, membership}

      {:error, :membership, changeset, _changes_so_far} ->
        {:error, :invalid_role, changeset}

      {:error, :audit_event, changeset, _changes_so_far} ->
        {:error, :invalid_audit_event, changeset}
    end
  end

  defp role_change_event_type(from_role, to_role) do
    cond do
      Roles.member?(from_role) and Roles.admin?(to_role) -> "member_role_promoted"
      Roles.admin?(from_role) and Roles.member?(to_role) -> "member_role_demoted"
      true -> "member_role_changed:#{from_role}:#{to_role}"
    end
  end

  defp create_channel_with_reads(%Workspace{} = workspace, attrs) do
    Multi.new()
    |> Multi.insert(:conversation, Conversation.workspace_channel_changeset())
    |> Multi.insert(:channel, fn %{conversation: conversation} ->
      Channel.create_changeset(
        %Channel{id: conversation.id},
        channel_attrs(workspace.id, attrs)
      )
    end)
    |> Multi.run(:channel_reads, fn _repo, %{channel: channel} ->
      case Chat.initialize_channel_reads_for_workspace_members(channel.id) do
        :ok -> {:ok, :initialized}
        {:error, reason} -> {:error, reason}
      end
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{channel: channel}} ->
        :ok = broadcast_workspace_channel_created(channel.workspace_id, channel.id)
        {:ok, channel}

      {:error, :channel, changeset, _changes_so_far} ->
        {:error, :invalid_channel, changeset}

      {:error, failed_operation, failed_value, changes_so_far} ->
        log_transaction_failure(
          "channel creation",
          failed_operation,
          failed_value,
          changes_so_far
        )

        {:error, :channel_creation_failed}
    end
  end

  # Logs the `Ecto.Multi` failure internals inside the context so callers receive
  # only a normalized `{:error, reason}` instead of a five-element tuple leaking
  # `failed_operation`/`failed_value`/`changes_so_far`.
  defp log_transaction_failure(label, failed_operation, failed_value, changes_so_far) do
    Logger.error(
      "#{label} transaction failed at #{inspect(failed_operation)}: " <>
        "#{inspect(failed_value)} (completed steps: #{inspect(Map.keys(changes_so_far))})"
    )
  end

  defp reject_landing_channel_delete(
         %Workspace{default_channel_id: default_channel_id},
         %Channel{id: channel_id}
       )
       when default_channel_id == channel_id,
       do: {:error, :landing_channel_required}

  defp reject_landing_channel_delete(_workspace, _channel), do: :ok

  defp reject_owner_leave(%WorkspaceMembership{role: role}) do
    if Roles.owner?(role), do: {:error, :owner_must_delete}, else: :ok
  end

  defp reject_owner_role_change(%WorkspaceMembership{role: role}) do
    if Roles.owner?(role), do: {:error, :owner_role_locked}, else: :ok
  end

  defp authorize_role_transition(from_role, to_role) do
    cond do
      Roles.member?(from_role) and Roles.admin?(to_role) -> :ok
      Roles.admin?(from_role) and Roles.member?(to_role) -> :ok
      true -> {:error, :unsupported_role_transition}
    end
  end

  defp has_workspace_role?(%Scope{user: %User{id: user_id}}, %Workspace{id: workspace_id}, roles) do
    case get_workspace_membership(workspace_id, user_id) do
      {:ok, %WorkspaceMembership{role: role}} -> role in roles
      {:error, _reason} -> false
    end
  end

  defp workspace_role(%Scope{user: %User{id: user_id}}, %Workspace{id: workspace_id}) do
    case get_workspace_membership(workspace_id, user_id) do
      {:ok, %WorkspaceMembership{role: role}} -> role
      {:error, _reason} -> nil
    end
  end

  defp workspace_role(_scope, _workspace), do: nil

  defp owner_member_actions(%WorkspaceMembership{role: role}) do
    cond do
      Roles.admin?(role) -> [:demote_to_member, :mute, :timeout, :kick, :ban]
      Roles.member?(role) -> [:promote_to_admin, :mute, :timeout, :kick, :ban]
      true -> []
    end
  end

  defp owner_member_actions(_target_membership), do: []

  defp admin_member_actions(%WorkspaceMembership{role: role}) do
    cond do
      Roles.admin?(role) -> [:mute, :timeout]
      Roles.member?(role) -> [:mute, :timeout, :kick, :ban]
      true -> []
    end
  end

  defp admin_member_actions(_target_membership), do: []

  defp workspace_member?(workspace_id, user_id) do
    Repo.exists?(
      from membership in WorkspaceMembership,
        where: membership.workspace_id == ^workspace_id and membership.user_id == ^user_id
    )
  end
end
