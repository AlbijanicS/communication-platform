defmodule DiscordClone.Repo.Migrations.CreateFriendRelationships do
  use Ecto.Migration

  def change do
    create table(:friend_relationships, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :user_low_id, references(:users, type: :binary_id, on_delete: :restrict), null: false

      add :user_high_id, references(:users, type: :binary_id, on_delete: :restrict), null: false

      add :requested_by_user_id, references(:users, type: :binary_id, on_delete: :restrict),
        null: false

      add :status, :string, null: false, default: "pending"
      add :accepted_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:friend_relationships, [:user_low_id, :user_high_id])
    create index(:friend_relationships, [:user_high_id])
    create index(:friend_relationships, [:requested_by_user_id])

    create constraint(:friend_relationships, :friend_relationships_canonical_pair,
             check: "user_low_id < user_high_id"
           )

    create constraint(:friend_relationships, :friend_relationships_requester_in_pair,
             check: "requested_by_user_id IN (user_low_id, user_high_id)"
           )

    create constraint(:friend_relationships, :friend_relationships_valid_status,
             check: "status IN ('pending', 'accepted')"
           )

    create constraint(:friend_relationships, :friend_relationships_acceptance_consistent,
             check:
               "(status = 'pending' AND accepted_at IS NULL) OR (status = 'accepted' AND accepted_at IS NOT NULL)"
           )
  end
end
