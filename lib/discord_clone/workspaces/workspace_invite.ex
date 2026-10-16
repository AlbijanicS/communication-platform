defmodule DiscordClone.Workspaces.WorkspaceInvite do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "workspace_invites" do
    field :code, :string
    field :expires_at, :utc_datetime
    field :max_uses, :integer
    field :uses_count, :integer, default: 0
    field :revoked_at, :utc_datetime

    belongs_to :workspace, DiscordClone.Workspaces.Workspace
    belongs_to :created_by_user, DiscordClone.Accounts.User

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(invite, attrs) do
    create_changeset(invite, attrs)
  end

  def create_changeset(invite, attrs) do
    invite
    |> cast(attrs, [
      :workspace_id,
      :created_by_user_id,
      :code,
      :expires_at,
      :max_uses,
      :uses_count,
      :revoked_at
    ])
    |> update_change(:code, &normalize_code/1)
    |> validate_required([:workspace_id, :code, :uses_count])
    |> validate_length(:code, min: 8, max: 64)
    |> validate_number(:max_uses, greater_than: 0)
    |> validate_number(:uses_count, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:workspace_id)
    |> foreign_key_constraint(:created_by_user_id)
    |> unique_constraint(:code)
  end

  def increment_usage_changeset(invite) do
    change(invite, uses_count: invite.uses_count + 1)
  end

  defp normalize_code(code) when is_binary(code), do: String.trim(code)
  defp normalize_code(code), do: code
end
