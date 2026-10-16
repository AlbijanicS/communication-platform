defmodule DiscordClone.Repo.Migrations.CreateCallAttempts do
  use Ecto.Migration

  def up do
    create table(:call_attempts, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :direct_conversation_id,
          references(:direct_conversations,
            column: :conversation_id,
            type: :binary_id,
            on_delete: :delete_all
          ),
          null: false

      add :caller_user_id, references(:users, type: :binary_id, on_delete: :restrict), null: false

      add :recipient_user_id, references(:users, type: :binary_id, on_delete: :restrict),
        null: false

      add :media_intent, :string, null: false
      add :state, :string, null: false
      add :ringing_deadline_at, :utc_datetime_usec, null: false
      add :accepted_at, :utc_datetime_usec
      add :terminal_outcome, :string
      add :ended_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:call_attempts, :call_attempts_distinct_participants,
             check: "caller_user_id <> recipient_user_id"
           )

    create constraint(:call_attempts, :call_attempts_valid_media_intent,
             check: "media_intent IN ('audio', 'video')"
           )

    create constraint(:call_attempts, :call_attempts_valid_state,
             check: "state IN ('ringing', 'connecting', 'active', 'terminal')"
           )

    create constraint(:call_attempts, :call_attempts_valid_terminal_outcome,
             check: """
             terminal_outcome IS NULL OR
             terminal_outcome IN (
               'declined',
               'cancelled',
               'timed_out',
               'relationship_ended',
               'failed_capacity',
               'failed',
               'interrupted',
               'ended'
             )
             """
           )

    create constraint(:call_attempts, :call_attempts_lifecycle_consistent,
             check: """
             (
               state = 'ringing' AND
               accepted_at IS NULL AND
               terminal_outcome IS NULL AND
               ended_at IS NULL
             ) OR (
               state IN ('connecting', 'active') AND
               accepted_at IS NOT NULL AND
               terminal_outcome IS NULL AND
               ended_at IS NULL
             ) OR (
               state = 'terminal' AND
               terminal_outcome IS NOT NULL AND
               ended_at IS NOT NULL
             )
             """
           )

    create constraint(:call_attempts, :call_attempts_timestamp_order,
             check: """
             ringing_deadline_at > inserted_at AND
             (accepted_at IS NULL OR accepted_at >= inserted_at) AND
             (ended_at IS NULL OR ended_at >= inserted_at) AND
             (accepted_at IS NULL OR ended_at IS NULL OR ended_at >= accepted_at)
             """
           )

    create unique_index(:call_attempts, [:direct_conversation_id],
             where: "state <> 'terminal'",
             name: :call_attempts_one_nonterminal_per_direct_conversation_index
           )

    create index(:call_attempts, [:state, :ringing_deadline_at],
             where: "state = 'ringing'",
             name: :call_attempts_ringing_deadline_index
           )

    create index(:call_attempts, [:caller_user_id, :inserted_at],
             name: :call_attempts_caller_started_index
           )

    create index(:call_attempts, [:caller_user_id, :recipient_user_id, :inserted_at],
             where: "accepted_at IS NULL",
             name: :call_attempts_unanswered_pair_index
           )

    create index(:call_attempts, [:ended_at],
             where: "state = 'terminal'",
             name: :call_attempts_terminal_pruning_index
           )

    create index(:call_attempts, [:recipient_user_id])

    execute("""
    CREATE FUNCTION enforce_call_attempt_direct_conversation_participants()
    RETURNS trigger AS $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1
        FROM direct_conversations
        WHERE conversation_id = NEW.direct_conversation_id
          AND (
            (
              user_low_id = NEW.caller_user_id
              AND user_high_id = NEW.recipient_user_id
            ) OR (
              user_low_id = NEW.recipient_user_id
              AND user_high_id = NEW.caller_user_id
            )
          )
      ) THEN
        RAISE EXCEPTION
          'call_attempts_require_direct_conversation_participants: %',
          NEW.direct_conversation_id;
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """)

    execute("""
    CREATE TRIGGER call_attempts_require_direct_conversation_participants
    BEFORE INSERT OR UPDATE OF direct_conversation_id, caller_user_id, recipient_user_id
    ON call_attempts
    FOR EACH ROW EXECUTE FUNCTION enforce_call_attempt_direct_conversation_participants()
    """)
  end

  def down do
    execute(
      "DROP TRIGGER call_attempts_require_direct_conversation_participants ON call_attempts"
    )

    execute("DROP FUNCTION enforce_call_attempt_direct_conversation_participants()")

    drop table(:call_attempts)
  end
end
