defmodule DiscordClone.Repo.Migrations.AddFriendRelationshipActivitySources do
  use Ecto.Migration

  def up do
    alter table(:activity_items) do
      modify :source_message_id, :binary_id, null: true
      modify :source_conversation_id, :binary_id, null: true

      add :source_friend_relationship_id,
          references(:friend_relationships, type: :binary_id, on_delete: :delete_all)
    end

    create index(:activity_items, [:source_friend_relationship_id])

    create unique_index(
             :activity_items,
             [:recipient_user_id, :source_friend_relationship_id, :kind],
             name: :activity_items_recipient_friend_relationship_kind_index,
             where: "source_friend_relationship_id IS NOT NULL"
           )

    create constraint(:activity_items, :activity_items_source_integrity,
             check: """
             (
               source_friend_relationship_id IS NULL AND
               source_message_id IS NOT NULL AND
               source_conversation_id IS NOT NULL AND
               kind NOT IN ('friend_request_received', 'friend_request_accepted')
             ) OR (
               source_friend_relationship_id IS NOT NULL AND
               source_message_id IS NULL AND
               source_conversation_id IS NULL AND
               workspace_id IS NULL AND
               kind IN ('friend_request_received', 'friend_request_accepted')
             )
             """
           )
  end

  def down do
    drop constraint(:activity_items, :activity_items_source_integrity)

    drop_if_exists index(
                     :activity_items,
                     [:recipient_user_id, :source_friend_relationship_id, :kind],
                     name: :activity_items_recipient_friend_relationship_kind_index
                   )

    drop_if_exists index(:activity_items, [:source_friend_relationship_id])

    alter table(:activity_items) do
      remove :source_friend_relationship_id
      modify :source_message_id, :binary_id, null: false
      modify :source_conversation_id, :binary_id, null: false
    end
  end
end
