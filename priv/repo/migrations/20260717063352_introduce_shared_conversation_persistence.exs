defmodule DiscordClone.Repo.Migrations.IntroduceSharedConversationPersistence do
  use Ecto.Migration

  def up do
    create table(:conversations, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :kind, :string, null: false
      add :last_message_seq, :bigint, null: false, default: 0
      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:conversations, :conversations_kind_supported,
             check: "kind IN ('workspace_channel')"
           )

    create constraint(:conversations, :conversations_last_message_seq_non_negative,
             check: "last_message_seq >= 0"
           )

    execute("""
    INSERT INTO conversations (id, kind, last_message_seq, inserted_at, updated_at)
    SELECT id, 'workspace_channel', last_message_seq, inserted_at, updated_at
    FROM channels
    """)

    drop constraint(:channels, :channels_last_message_seq_non_negative)

    alter table(:channels) do
      remove :last_message_seq
    end

    execute("ALTER TABLE channels RENAME COLUMN id TO conversation_id")
    execute("ALTER TABLE channels ALTER COLUMN conversation_id DROP DEFAULT")

    alter table(:channels) do
      modify :conversation_id,
             references(:conversations, type: :binary_id, on_delete: :delete_all),
             from: :binary_id
    end

    drop constraint(:channels, :channels_workspace_id_fkey)

    alter table(:channels) do
      modify :workspace_id,
             references(:workspaces, type: :binary_id, on_delete: :nothing),
             from: :binary_id
    end

    drop constraint(:messages, :messages_channel_id_fkey)
    drop_if_exists index(:messages, [:channel_id, :inserted_at, :id])

    drop_if_exists unique_index(:messages, [:channel_id, :seq],
                     name: :messages_channel_id_seq_index
                   )

    execute("ALTER TABLE messages RENAME COLUMN channel_id TO conversation_id")

    alter table(:messages) do
      modify :conversation_id,
             references(:conversations, type: :binary_id, on_delete: :delete_all),
             from: :binary_id
    end

    create index(:messages, [:conversation_id, :inserted_at, :id])

    create unique_index(:messages, [:conversation_id, :seq],
             name: :messages_conversation_id_seq_index
           )

    drop table(:channel_reads)

    drop constraint(:channel_read_states, :channel_read_states_channel_id_fkey)
    execute("ALTER TABLE channel_read_states RENAME TO conversation_read_states")
    execute("ALTER TABLE conversation_read_states RENAME COLUMN channel_id TO conversation_id")

    alter table(:conversation_read_states) do
      modify :conversation_id,
             references(:conversations, type: :binary_id, on_delete: :delete_all),
             from: :binary_id
    end

    rename_read_state_constraints_and_indexes()

    drop constraint(:channel_unread_spans, :channel_unread_spans_channel_id_fkey)
    execute("ALTER TABLE channel_unread_spans RENAME TO conversation_unread_spans")
    execute("ALTER TABLE conversation_unread_spans RENAME COLUMN channel_id TO conversation_id")

    alter table(:conversation_unread_spans) do
      modify :conversation_id,
             references(:conversations, type: :binary_id, on_delete: :delete_all),
             from: :binary_id
    end

    rename_unread_span_constraints_and_indexes()

    drop constraint(:activity_items, :activity_items_source_channel_id_fkey)
    drop_if_exists index(:activity_items, [:source_channel_id])

    execute(
      "ALTER TABLE activity_items RENAME COLUMN source_channel_id TO source_conversation_id"
    )

    alter table(:activity_items) do
      modify :source_conversation_id,
             references(:conversations, type: :binary_id, on_delete: :delete_all),
             from: :binary_id
    end

    create index(:activity_items, [:source_conversation_id])

    create_subtype_integrity_triggers()
  end

  def down do
    raise "Conversation persistence is intentionally irreversible because no application data requires compatibility preservation"
  end

  defp rename_read_state_constraints_and_indexes do
    execute(
      "ALTER TABLE conversation_read_states RENAME CONSTRAINT channel_read_states_pkey TO conversation_read_states_pkey"
    )

    execute(
      "ALTER TABLE conversation_read_states RENAME CONSTRAINT channel_read_states_unread_count_non_negative TO conversation_read_states_unread_count_non_negative"
    )

    execute(
      "ALTER TABLE conversation_read_states RENAME CONSTRAINT channel_read_states_unread_summary_consistent TO conversation_read_states_unread_summary_consistent"
    )

    execute(
      "ALTER TABLE conversation_read_states RENAME CONSTRAINT channel_read_states_last_viewed_anchor_seq_positive TO conversation_read_states_last_viewed_anchor_seq_positive"
    )

    execute(
      "ALTER INDEX channel_read_states_channel_id_user_id_index RENAME TO conversation_read_states_conversation_id_user_id_index"
    )

    execute(
      "ALTER INDEX channel_read_states_user_id_channel_id_index RENAME TO conversation_read_states_user_id_conversation_id_index"
    )

    execute(
      "ALTER INDEX channel_read_states_channel_id_index RENAME TO conversation_read_states_conversation_id_index"
    )
  end

  defp rename_unread_span_constraints_and_indexes do
    execute(
      "ALTER TABLE conversation_unread_spans RENAME CONSTRAINT channel_unread_spans_pkey TO conversation_unread_spans_pkey"
    )

    execute(
      "ALTER TABLE conversation_unread_spans RENAME CONSTRAINT channel_unread_spans_positive_bounds TO conversation_unread_spans_positive_bounds"
    )

    execute(
      "ALTER TABLE conversation_unread_spans RENAME CONSTRAINT channel_unread_spans_ordered_bounds TO conversation_unread_spans_ordered_bounds"
    )

    execute(
      "ALTER TABLE conversation_unread_spans RENAME CONSTRAINT channel_unread_spans_no_overlap TO conversation_unread_spans_no_overlap"
    )

    execute(
      "ALTER INDEX channel_unread_spans_user_id_channel_id_index RENAME TO conversation_unread_spans_user_id_conversation_id_index"
    )

    execute(
      "ALTER INDEX channel_unread_spans_channel_id_index RENAME TO conversation_unread_spans_conversation_id_index"
    )
  end

  defp create_subtype_integrity_triggers do
    execute("""
    CREATE FUNCTION enforce_conversation_subtype_integrity()
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

    execute("""
    CREATE CONSTRAINT TRIGGER conversations_require_matching_subtype
    AFTER INSERT OR UPDATE OF kind ON conversations
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION enforce_conversation_subtype_integrity()
    """)

    execute("""
    CREATE FUNCTION enforce_workspace_channel_conversation_kind()
    RETURNS trigger AS $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM conversations
        WHERE id = NEW.conversation_id AND kind = 'workspace_channel'
      ) THEN
        RAISE EXCEPTION 'channels_require_workspace_channel_conversation: %', NEW.conversation_id;
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """)

    execute("""
    CREATE TRIGGER channels_require_workspace_channel_conversation
    BEFORE INSERT OR UPDATE OF conversation_id ON channels
    FOR EACH ROW EXECUTE FUNCTION enforce_workspace_channel_conversation_kind()
    """)

    execute("""
    CREATE FUNCTION prevent_orphaned_channel_conversation()
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
    CREATE CONSTRAINT TRIGGER channels_prevent_orphaned_conversation
    AFTER DELETE ON channels
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION prevent_orphaned_channel_conversation()
    """)
  end
end
