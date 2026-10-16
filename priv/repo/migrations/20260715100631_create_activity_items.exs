defmodule DiscordClone.Repo.Migrations.CreateActivityItems do
  use Ecto.Migration

  def change do
    create table(:activity_items, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :recipient_user_id, references(:users, type: :binary_id, on_delete: :delete_all),
        null: false

      add :actor_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)

      add :source_message_id,
          references(:messages, type: :binary_id, on_delete: :delete_all),
          null: false

      add :source_channel_id,
          references(:channels, type: :binary_id, on_delete: :delete_all),
          null: false

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all)
      add :kind, :string, null: false
      add :read_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:activity_items, [:recipient_user_id, :read_at])
    create index(:activity_items, [:recipient_user_id, :inserted_at, :id])
    create index(:activity_items, [:actor_user_id])
    create index(:activity_items, [:source_message_id])
    create index(:activity_items, [:source_channel_id])
    create index(:activity_items, [:workspace_id])

    create unique_index(:activity_items, [:recipient_user_id, :source_message_id])
  end
end
