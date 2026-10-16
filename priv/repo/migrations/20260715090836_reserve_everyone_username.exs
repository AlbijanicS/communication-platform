defmodule DiscordClone.Repo.Migrations.ReserveEveryoneUsername do
  use Ecto.Migration

  def up do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1
        FROM users
        WHERE lower(regexp_replace(username, '^[[:space:]]+|[[:space:]]+$', '', 'g')) = 'everyone'
      ) THEN
        RAISE EXCEPTION USING
          MESSAGE = 'cannot reserve username everyone: existing users normalize to everyone',
          HINT = 'Rename conflicting users before retrying this migration.';
      END IF;
    END
    $$
    """)

    create constraint(:users, :users_username_not_reserved,
             check:
               "lower(regexp_replace(username, '^[[:space:]]+|[[:space:]]+$', '', 'g')) <> 'everyone'"
           )
  end

  def down do
    drop constraint(:users, :users_username_not_reserved)
  end
end
