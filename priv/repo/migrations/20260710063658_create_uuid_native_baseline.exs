defmodule DiscordClone.Repo.Migrations.CreateUuidNativeBaseline do
  use Ecto.Migration

  def change do
    execute "CREATE EXTENSION IF NOT EXISTS citext", ""
    execute "CREATE EXTENSION IF NOT EXISTS btree_gist", "SELECT 1"

    create table(:users, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :email, :citext, null: false
      add :username, :string
      add :hashed_password, :string
      add :confirmed_at, :utc_datetime
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:users, [:email])
    create unique_index(:users, [:username])

    create table(:users_tokens, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :token, :binary, null: false
      add :context, :string, null: false
      add :sent_to, :string
      add :authenticated_at, :utc_datetime
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:users_tokens, [:user_id])
    create unique_index(:users_tokens, [:context, :token])

    create table(:workspaces, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :name, :string, null: false
      add :owner_id, references(:users, type: :binary_id, on_delete: :restrict), null: false
      add :invite_policy, :string, null: false, default: "owner_only"
      timestamps(type: :utc_datetime_usec)
    end

    create index(:workspaces, [:owner_id])

    create table(:channels, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :name, :string, null: false
      add :last_message_seq, :bigint, null: false, default: 0
      timestamps(type: :utc_datetime_usec)
    end

    create index(:channels, [:workspace_id])
    create unique_index(:channels, [:workspace_id, :name])

    create constraint(:channels, :channels_last_message_seq_non_negative,
             check: "last_message_seq >= 0"
           )

    alter table(:workspaces) do
      add :default_channel_id, references(:channels, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:workspaces, [:default_channel_id])

    create table(:workspace_memberships, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :role, :string, null: false, default: "member"
      timestamps(type: :utc_datetime_usec)
    end

    create index(:workspace_memberships, [:workspace_id])
    create index(:workspace_memberships, [:user_id])
    create unique_index(:workspace_memberships, [:workspace_id, :user_id])

    create table(:workspace_invites, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :created_by_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :code, :string, null: false
      add :expires_at, :utc_datetime
      add :max_uses, :integer
      add :uses_count, :integer, null: false, default: 0
      add :revoked_at, :utc_datetime
      timestamps(type: :utc_datetime_usec)
    end

    create index(:workspace_invites, [:workspace_id])
    create index(:workspace_invites, [:created_by_user_id])
    create unique_index(:workspace_invites, [:code])

    create table(:workspace_moderations, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :target_user_id, references(:users, type: :binary_id, on_delete: :delete_all),
        null: false

      add :created_by_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :ended_by_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :type, :string, null: false
      add :reason, :text
      add :active, :boolean, null: false, default: true
      add :expires_at, :utc_datetime
      add :ended_at, :utc_datetime
      timestamps(type: :utc_datetime_usec)
    end

    create index(:workspace_moderations, [:workspace_id])
    create index(:workspace_moderations, [:target_user_id])
    create index(:workspace_moderations, [:created_by_user_id])
    create index(:workspace_moderations, [:ended_by_user_id])

    create unique_index(:workspace_moderations, [:workspace_id, :target_user_id, :type],
             where: "active"
           )

    create table(:workspace_bans, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :target_user_id, references(:users, type: :binary_id, on_delete: :delete_all),
        null: false

      add :banned_by_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :reason, :string, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create index(:workspace_bans, [:target_user_id])

    create unique_index(:workspace_bans, [:workspace_id, :target_user_id],
             name: :workspace_bans_workspace_id_target_user_id_index
           )

    create table(:workspace_audit_events, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :actor_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :target_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :event_type, :string, null: false
      add :reason, :text
      add :metadata, :map, null: false, default: %{}
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:workspace_audit_events, [:workspace_id, :inserted_at, :id])
    create index(:workspace_audit_events, [:actor_user_id])
    create index(:workspace_audit_events, [:target_user_id])
    create index(:workspace_audit_events, [:event_type])

    create table(:messages, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :channel_id, references(:channels, type: :binary_id, on_delete: :delete_all),
        null: false

      add :user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :content, :string, null: false
      add :seq, :bigint, null: false
      add :deleted_at, :utc_datetime
      add :deleted_by_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      timestamps(type: :utc_datetime_usec)
    end

    create index(:messages, [:user_id])
    create index(:messages, [:channel_id, :inserted_at, :id])
    create index(:messages, [:deleted_by_user_id])
    create constraint(:messages, :messages_seq_positive, check: "seq > 0")
    create unique_index(:messages, [:channel_id, :seq], name: :messages_channel_id_seq_index)

    create table(:message_reactions, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :message_id, references(:messages, type: :binary_id, on_delete: :delete_all),
        null: false

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :emoji, :string, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:message_reactions, [:message_id, :user_id, :emoji])
    create index(:message_reactions, [:message_id])
    create index(:message_reactions, [:user_id])

    create table(:channel_reads, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :channel_id, references(:channels, type: :binary_id, on_delete: :delete_all),
        null: false

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :last_read_message_id, references(:messages, type: :binary_id, on_delete: :nilify_all)
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:channel_reads, [:channel_id, :user_id])
    create index(:channel_reads, [:user_id])

    create table(:channel_read_states, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :channel_id, references(:channels, type: :binary_id, on_delete: :delete_all),
        null: false

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :unread_count, :bigint, null: false, default: 0
      add :first_unread_seq, :bigint
      add :last_unread_seq, :bigint
      add :last_viewed_anchor_seq, :bigint
      add :last_opened_at, :utc_datetime
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:channel_read_states, [:channel_id, :user_id])
    create index(:channel_read_states, [:user_id, :channel_id])
    create index(:channel_read_states, [:channel_id])

    create constraint(:channel_read_states, :channel_read_states_unread_count_non_negative,
             check: "unread_count >= 0"
           )

    create constraint(:channel_read_states, :channel_read_states_unread_summary_consistent,
             check: """
             (unread_count = 0 AND first_unread_seq IS NULL AND last_unread_seq IS NULL)
             OR
             (unread_count > 0 AND first_unread_seq IS NOT NULL AND last_unread_seq IS NOT NULL
              AND first_unread_seq > 0 AND last_unread_seq > 0 AND first_unread_seq <= last_unread_seq)
             """
           )

    create constraint(:channel_read_states, :channel_read_states_last_viewed_anchor_seq_positive,
             check: "last_viewed_anchor_seq IS NULL OR last_viewed_anchor_seq > 0"
           )

    create table(:channel_unread_spans, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :channel_id, references(:channels, type: :binary_id, on_delete: :delete_all),
        null: false

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :from_seq, :bigint, null: false
      add :to_seq, :bigint, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:channel_unread_spans, :channel_unread_spans_positive_bounds,
             check: "from_seq > 0 AND to_seq > 0"
           )

    create constraint(:channel_unread_spans, :channel_unread_spans_ordered_bounds,
             check: "from_seq <= to_seq"
           )

    create index(:channel_unread_spans, [:user_id, :channel_id])
    create index(:channel_unread_spans, [:channel_id])

    execute(
      """
      ALTER TABLE channel_unread_spans
      ADD CONSTRAINT channel_unread_spans_no_overlap
      EXCLUDE USING gist (
        user_id WITH =,
        channel_id WITH =,
        int8range(from_seq, to_seq, '[]') WITH &&
      )
      """,
      "ALTER TABLE channel_unread_spans DROP CONSTRAINT channel_unread_spans_no_overlap"
    )
  end
end
