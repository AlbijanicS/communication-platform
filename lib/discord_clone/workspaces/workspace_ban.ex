defmodule DiscordClone.Workspaces.WorkspaceBan do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "workspace_bans" do
    field :reason, :string

    belongs_to :workspace, DiscordClone.Workspaces.Workspace
    belongs_to :target_user, DiscordClone.Accounts.User
    belongs_to :banned_by_user, DiscordClone.Accounts.User

    timestamps(type: :utc_datetime_usec)
  end

  def create_changeset(ban, attrs) do
    ban
    |> cast(attrs, [:workspace_id, :target_user_id, :banned_by_user_id, :reason])
    |> validate_required([:workspace_id, :target_user_id, :reason])
    |> foreign_key_constraint(:workspace_id)
    |> foreign_key_constraint(:target_user_id)
    |> foreign_key_constraint(:banned_by_user_id)
    |> unique_constraint([:workspace_id, :target_user_id],
      name: :workspace_bans_workspace_id_target_user_id_index
    )
  end
end
