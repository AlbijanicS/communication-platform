defmodule DiscordClone.Workspaces.WorkspaceAuditEvent do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @event_types ~w(member_role_promoted member_role_demoted member_muted member_unmuted member_timed_out member_timeout_removed member_timeout_expired member_kicked member_banned member_unbanned member_joined_from_invite moderator_message_deleted)

  schema "workspace_audit_events" do
    field :event_type, :string
    field :reason, :string
    field :metadata, :map, default: %{}

    belongs_to :workspace, DiscordClone.Workspaces.Workspace
    belongs_to :actor_user, DiscordClone.Accounts.User
    belongs_to :target_user, DiscordClone.Accounts.User

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(audit_event, attrs) do
    audit_event
    |> cast(attrs, [
      :workspace_id,
      :actor_user_id,
      :target_user_id,
      :event_type,
      :reason,
      :metadata
    ])
    |> validate_required([:workspace_id, :event_type, :metadata])
    |> validate_inclusion(:event_type, @event_types)
    |> foreign_key_constraint(:workspace_id)
    |> foreign_key_constraint(:actor_user_id)
    |> foreign_key_constraint(:target_user_id)
  end
end
