defmodule DiscordClone.Repo.Migrations.SupportDirectMessageActivity do
  use Ecto.Migration

  def up do
    drop constraint(:activity_items, :activity_items_source_integrity)

    create constraint(:activity_items, :activity_items_source_integrity,
             check: """
             (
               source_friend_relationship_id IS NULL AND
               source_message_id IS NOT NULL AND
               source_conversation_id IS NOT NULL AND
               workspace_id IS NOT NULL AND
               kind NOT IN ('friend_request_received', 'friend_request_accepted', 'direct_message')
             ) OR (
               source_friend_relationship_id IS NULL AND
               source_message_id IS NOT NULL AND
               source_conversation_id IS NOT NULL AND
               workspace_id IS NULL AND
               kind = 'direct_message'
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
end
