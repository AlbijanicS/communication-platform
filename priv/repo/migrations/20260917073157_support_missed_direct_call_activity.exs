defmodule DiscordClone.Repo.Migrations.SupportMissedDirectCallActivity do
  use Ecto.Migration

  def up do
    alter table(:activity_items) do
      add :source_call_attempt_id, :binary_id
    end

    create unique_index(
             :activity_items,
             [:recipient_user_id, :source_call_attempt_id, :kind],
             name: :activity_items_recipient_source_call_attempt_kind_index,
             where: "source_call_attempt_id IS NOT NULL"
           )

    drop constraint(:activity_items, :activity_items_source_integrity)

    create constraint(:activity_items, :activity_items_source_integrity,
             check: """
             (
               source_friend_relationship_id IS NULL AND
               source_message_id IS NOT NULL AND
               source_conversation_id IS NOT NULL AND
               workspace_id IS NOT NULL AND
               source_call_attempt_id IS NULL AND
               kind NOT IN ('friend_request_received', 'friend_request_accepted', 'direct_message', 'missed_direct_call')
             ) OR (
               source_friend_relationship_id IS NULL AND
               source_message_id IS NOT NULL AND
               source_conversation_id IS NOT NULL AND
               workspace_id IS NULL AND
               source_call_attempt_id IS NULL AND
               kind = 'direct_message'
             ) OR (
               source_friend_relationship_id IS NOT NULL AND
               source_message_id IS NULL AND
               source_conversation_id IS NULL AND
               workspace_id IS NULL AND
               source_call_attempt_id IS NULL AND
               kind IN ('friend_request_received', 'friend_request_accepted')
             ) OR (
               source_friend_relationship_id IS NULL AND
               source_message_id IS NULL AND
               source_conversation_id IS NOT NULL AND
               workspace_id IS NULL AND
               source_call_attempt_id IS NOT NULL AND
               actor_user_id IS NOT NULL AND
               kind = 'missed_direct_call'
             )
             """
           )
  end

  def down do
    # Recreating the prior integrity check fails if missed_direct_call rows remain:
    # after this column is dropped they match no remaining source branch.
    drop constraint(:activity_items, :activity_items_source_integrity)

    drop_if_exists index(
                     :activity_items,
                     [:recipient_user_id, :source_call_attempt_id, :kind],
                     name: :activity_items_recipient_source_call_attempt_kind_index
                   )

    alter table(:activity_items) do
      remove :source_call_attempt_id
    end

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
end
