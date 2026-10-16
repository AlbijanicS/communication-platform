defmodule DiscordClone.Workspaces.WorkspaceMembership do
  use Ecto.Schema
  import Ecto.Changeset

  alias DiscordClone.Workspaces.Roles

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "workspace_memberships" do
    field :role, :string, default: Roles.member()

    belongs_to :workspace, DiscordClone.Workspaces.Workspace
    belongs_to :user, DiscordClone.Accounts.User

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(membership, attrs) do
    membership
    |> cast(attrs, [:workspace_id, :user_id, :role])
    |> validate_required([:workspace_id, :user_id, :role])
    |> validate_inclusion(:role, Roles.all())
    |> foreign_key_constraint(:workspace_id)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint([:workspace_id, :user_id])
  end

  def role_changeset(membership, attrs) do
    membership
    |> cast(attrs, [:role])
    |> validate_required([:role])
    |> validate_inclusion(:role, Roles.all())
  end
end
