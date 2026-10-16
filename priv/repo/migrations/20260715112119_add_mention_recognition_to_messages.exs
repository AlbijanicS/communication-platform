defmodule DiscordClone.Repo.Migrations.AddMentionRecognitionToMessages do
  use Ecto.Migration

  def change do
    alter table(:messages) do
      add :mention_recognition, :map, null: false, default: %{}
    end
  end
end
