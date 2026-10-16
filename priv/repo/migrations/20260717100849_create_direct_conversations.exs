defmodule DiscordClone.Repo.Migrations.CreateDirectConversations do
  use Ecto.Migration

  def up do
    drop constraint(:conversations, :conversations_kind_supported)

    create constraint(:conversations, :conversations_kind_supported,
             check: "kind IN ('workspace_channel', 'direct_conversation')"
           )

    create table(:direct_conversations, primary_key: false) do
      add :conversation_id,
          references(:conversations, type: :binary_id, on_delete: :delete_all),
          primary_key: true

      add :user_low_id, references(:users, type: :binary_id, on_delete: :restrict), null: false
      add :user_high_id, references(:users, type: :binary_id, on_delete: :restrict), null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:direct_conversations, [:user_low_id, :user_high_id])
    create index(:direct_conversations, [:user_high_id])

    create constraint(:direct_conversations, :direct_conversations_canonical_pair,
             check: "user_low_id < user_high_id"
           )

    execute("""
    CREATE OR REPLACE FUNCTION enforce_conversation_subtype_integrity()
    RETURNS trigger AS $$
    BEGIN
      IF EXISTS (SELECT 1 FROM conversations WHERE id = NEW.id)
         AND NEW.kind = 'workspace_channel'
         AND NOT EXISTS (
           SELECT 1 FROM channels WHERE conversation_id = NEW.id
         ) THEN
        RAISE EXCEPTION 'conversations_require_matching_subtype: %', NEW.id;
      END IF;

      IF EXISTS (SELECT 1 FROM conversations WHERE id = NEW.id)
         AND NEW.kind = 'direct_conversation'
         AND NOT EXISTS (
           SELECT 1 FROM direct_conversations WHERE conversation_id = NEW.id
         ) THEN
        RAISE EXCEPTION 'conversations_require_matching_subtype: %', NEW.id;
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """)

    execute("""
    CREATE FUNCTION enforce_direct_conversation_kind()
    RETURNS trigger AS $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM conversations
        WHERE id = NEW.conversation_id AND kind = 'direct_conversation'
      ) THEN
        RAISE EXCEPTION 'direct_conversations_require_direct_kind: %', NEW.conversation_id;
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """)

    execute("""
    CREATE TRIGGER direct_conversations_require_direct_kind
    BEFORE INSERT OR UPDATE OF conversation_id ON direct_conversations
    FOR EACH ROW EXECUTE FUNCTION enforce_direct_conversation_kind()
    """)

    execute("""
    CREATE FUNCTION prevent_orphaned_direct_conversation()
    RETURNS trigger AS $$
    BEGIN
      IF EXISTS (SELECT 1 FROM conversations WHERE id = OLD.conversation_id) THEN
        RAISE EXCEPTION 'conversations_require_matching_subtype: %', OLD.conversation_id;
      END IF;

      RETURN OLD;
    END;
    $$ LANGUAGE plpgsql
    """)

    execute("""
    CREATE CONSTRAINT TRIGGER direct_conversations_prevent_orphaned_conversation
    AFTER DELETE ON direct_conversations
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION prevent_orphaned_direct_conversation()
    """)
  end

  def down do
    execute(
      "DROP TRIGGER direct_conversations_prevent_orphaned_conversation ON direct_conversations"
    )

    execute("DROP FUNCTION prevent_orphaned_direct_conversation()")
    execute("DROP TRIGGER direct_conversations_require_direct_kind ON direct_conversations")
    execute("DROP FUNCTION enforce_direct_conversation_kind()")

    drop table(:direct_conversations)

    execute("""
    CREATE OR REPLACE FUNCTION enforce_conversation_subtype_integrity()
    RETURNS trigger AS $$
    BEGIN
      IF NEW.kind = 'workspace_channel'
         AND NOT EXISTS (
           SELECT 1 FROM channels WHERE conversation_id = NEW.id
         ) THEN
        RAISE EXCEPTION 'conversations_require_matching_subtype: %', NEW.id;
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """)

    drop constraint(:conversations, :conversations_kind_supported)

    create constraint(:conversations, :conversations_kind_supported,
             check: "kind IN ('workspace_channel')"
           )
  end
end
