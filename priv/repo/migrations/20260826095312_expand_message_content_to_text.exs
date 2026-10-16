defmodule DiscordClone.Repo.Migrations.ExpandMessageContentToText do
  use Ecto.Migration

  def change do
    alter table(:messages) do
      modify :content, :text, from: :string, null: false
    end
  end
end
