defmodule DiscordClone.Workspaces.WorkspaceModeration do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @types ~w(mute timeout)

  schema "workspace_moderations" do
    field :type, :string
    field :reason, :string
    field :active?, :boolean, source: :active, default: true
    field :expires_at, :utc_datetime
    field :ended_at, :utc_datetime

    belongs_to :workspace, DiscordClone.Workspaces.Workspace
    belongs_to :target_user, DiscordClone.Accounts.User
    belongs_to :created_by_user, DiscordClone.Accounts.User
    belongs_to :ended_by_user, DiscordClone.Accounts.User

    timestamps(type: :utc_datetime_usec)
  end

  def create_changeset(moderation, attrs) do
    moderation
    |> cast(attrs, [
      :workspace_id,
      :target_user_id,
      :created_by_user_id,
      :type,
      :reason,
      :expires_at
    ])
    |> validate_required([:workspace_id, :target_user_id, :type])
    |> validate_inclusion(:type, @types)
    |> validate_timeout_expiration()
    |> foreign_key_constraint(:workspace_id)
    |> foreign_key_constraint(:target_user_id)
    |> foreign_key_constraint(:created_by_user_id)
    |> unique_constraint([:workspace_id, :target_user_id, :type],
      name: :workspace_moderations_workspace_id_target_user_id_type_index
    )
  end

  def end_changeset(moderation, attrs) do
    moderation
    |> cast(attrs, [:active?, :ended_at, :ended_by_user_id])
    |> validate_required([:active?, :ended_at])
    |> foreign_key_constraint(:ended_by_user_id)
  end

  defp validate_timeout_expiration(changeset) do
    case get_field(changeset, :type) do
      "timeout" -> validate_required(changeset, [:expires_at])
      _type -> changeset
    end
  end
end
