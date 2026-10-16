defmodule DiscordClone.Workspaces.Workspace do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @invite_policies ~w(owner_only members_can_invite)

  schema "workspaces" do
    field :name, :string
    field :invite_policy, :string, default: "owner_only"

    belongs_to :owner, DiscordClone.Accounts.User
    belongs_to :default_channel, DiscordClone.Workspaces.Channel

    has_many :channels, DiscordClone.Workspaces.Channel
    has_many :voice_channels, DiscordClone.Workspaces.VoiceChannel
    has_many :memberships, DiscordClone.Workspaces.WorkspaceMembership
    has_many :invites, DiscordClone.Workspaces.WorkspaceInvite
    has_many :audit_events, DiscordClone.Workspaces.WorkspaceAuditEvent
    has_many :activity_items, DiscordClone.Activities.ActivityItem

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(workspace, attrs) do
    create_changeset(workspace, attrs)
  end

  def create_changeset(workspace, attrs) do
    workspace
    |> cast(attrs, [:name, :owner_id, :default_channel_id, :invite_policy])
    |> update_change(:name, &normalize_name/1)
    |> validate_required([:name, :owner_id, :invite_policy])
    |> validate_length(:name, min: 1, max: 80)
    |> validate_inclusion(:invite_policy, @invite_policies)
    |> foreign_key_constraint(:owner_id)
    |> foreign_key_constraint(:default_channel_id)
  end

  def rename_changeset(workspace, attrs) do
    workspace
    |> cast(attrs, [:name])
    |> update_change(:name, &normalize_name/1)
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 80)
  end

  def default_channel_changeset(workspace, attrs) do
    workspace
    |> cast(attrs, [:default_channel_id])
    |> validate_required([:default_channel_id])
    |> foreign_key_constraint(:default_channel_id)
  end

  def invite_policies, do: @invite_policies

  defp normalize_name(name) when is_binary(name), do: String.trim(name)
  defp normalize_name(name), do: name
end
