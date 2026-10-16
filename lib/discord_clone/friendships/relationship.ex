defmodule DiscordClone.Friendships.Relationship do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "friend_relationships" do
    field :status, Ecto.Enum, values: [:pending, :accepted], default: :pending
    field :accepted_at, :utc_datetime_usec

    belongs_to :user_low, DiscordClone.Accounts.User
    belongs_to :user_high, DiscordClone.Accounts.User
    belongs_to :requested_by_user, DiscordClone.Accounts.User

    timestamps(type: :utc_datetime_usec)
  end

  def create_changeset(relationship, attrs) do
    relationship
    |> change(attrs)
    |> validate_required([:user_low_id, :user_high_id, :requested_by_user_id, :status])
    |> foreign_key_constraint(:user_low_id)
    |> foreign_key_constraint(:user_high_id)
    |> foreign_key_constraint(:requested_by_user_id)
    |> check_constraint(:user_low_id, name: :friend_relationships_canonical_pair)
    |> check_constraint(:requested_by_user_id, name: :friend_relationships_requester_in_pair)
    |> check_constraint(:status, name: :friend_relationships_valid_status)
    |> check_constraint(:accepted_at, name: :friend_relationships_acceptance_consistent)
    |> unique_constraint([:user_low_id, :user_high_id])
  end

  def accept_changeset(relationship) do
    relationship
    |> change(status: :accepted, accepted_at: DateTime.utc_now())
    |> check_constraint(:accepted_at, name: :friend_relationships_acceptance_consistent)
  end
end
