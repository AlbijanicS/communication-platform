defmodule DiscordClone.Repo.Migrations.AddMessageReplyReferences do
  use Ecto.Migration

  def change do
    alter table(:messages) do
      add :reply_to_message_id,
          references(:messages, type: :binary_id, on_delete: :nothing)
    end

    create index(:messages, [:reply_to_message_id])

    create constraint(:messages, :messages_reply_target_not_self,
             check: "reply_to_message_id IS NULL OR reply_to_message_id <> id"
           )
  end
end
