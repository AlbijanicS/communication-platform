defmodule DiscordClone.Repo.Migrations.CreateVoiceChannels do
  use Ecto.Migration

  def change do
    create table(:voice_channels, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :name, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:voice_channels, [:workspace_id, :name])
    create index(:voice_channels, [:workspace_id, :inserted_at, :id])
  end
end
