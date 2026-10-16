defmodule DiscordClone.Repo.UUIDBaselineTest do
  use DiscordClone.DataCase, async: false

  alias DiscordClone.Workspaces

  import DiscordClone.AccountsFixtures

  @id_tables ~w(
    users
    users_tokens
    workspaces
    workspace_memberships
    workspace_invites
    workspace_moderations
    workspace_bans
    workspace_audit_events
    messages
    message_reactions
    activity_items
    friend_relationships
    conversations
    conversation_read_states
    conversation_unread_spans
    call_attempts
    voice_channels
  )

  test "every persisted entity has a database-generated UUID primary key" do
    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        Repo,
        """
        SELECT table_name, data_type, column_default
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND column_name = 'id'
          AND table_name = ANY($1)
        ORDER BY table_name
        """,
        [@id_tables]
      )

    assert rows ==
             @id_tables
             |> Enum.sort()
             |> Enum.map(&[&1, "uuid", "gen_random_uuid()"])

    assert %{rows: [["uuid", nil]]} =
             Ecto.Adapters.SQL.query!(
               Repo,
               """
               SELECT data_type, column_default
               FROM information_schema.columns
               WHERE table_schema = 'public'
                 AND table_name = 'channels'
                 AND column_name = 'conversation_id'
               """,
               []
             )
  end

  test "every foreign key is UUID-native and preserves its delete action" do
    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        Repo,
        """
        SELECT con.conname,
               CASE con.confdeltype
                 WHEN 'c' THEN 'delete_all'
                 WHEN 'n' THEN 'nilify_all'
                 WHEN 'r' THEN 'restrict'
                 WHEN 'a' THEN 'no_action'
                 ELSE con.confdeltype::text
               END,
               pg_catalog.format_type(source_attribute.atttypid, source_attribute.atttypmod),
               pg_catalog.format_type(target_attribute.atttypid, target_attribute.atttypmod)
        FROM pg_constraint con
        JOIN pg_attribute source_attribute
          ON source_attribute.attrelid = con.conrelid
         AND source_attribute.attnum = con.conkey[1]
        JOIN pg_attribute target_attribute
          ON target_attribute.attrelid = con.confrelid
         AND target_attribute.attnum = con.confkey[1]
        WHERE con.contype = 'f'
        ORDER BY con.conname
        """,
        []
      )

    assert Enum.all?(rows, fn [_name, _delete_action, source_type, target_type] ->
             source_type == "uuid" and target_type == "uuid"
           end)

    delete_actions =
      Map.new(rows, fn [name, action, _source_type, _target_type] -> {name, action} end)

    assert delete_actions == expected_foreign_key_delete_actions()
  end

  test "the baseline preserves required unique, check, and exclusion constraints" do
    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        Repo,
        """
        SELECT conname, contype::text
        FROM pg_constraint
        WHERE connamespace = 'public'::regnamespace
          AND contype IN ('u', 'c', 'x')
        ORDER BY conname
        """,
        []
      )

    constraints = Map.new(rows, fn [name, type] -> {name, type} end)

    for name <- ~w(
          conversations_kind_supported
          conversations_last_message_seq_non_negative
          messages_reply_target_not_self
          messages_seq_positive
          conversation_read_states_unread_count_non_negative
          conversation_read_states_unread_summary_consistent
          conversation_read_states_last_viewed_anchor_seq_positive
          conversation_unread_spans_positive_bounds
          conversation_unread_spans_ordered_bounds
          call_attempts_distinct_participants
          call_attempts_lifecycle_consistent
          call_attempts_timestamp_order
          call_attempts_valid_media_intent
          call_attempts_valid_state
          call_attempts_valid_terminal_outcome
          direct_conversations_canonical_pair
          friend_relationships_canonical_pair
          friend_relationships_requester_in_pair
          friend_relationships_valid_status
          friend_relationships_acceptance_consistent
          activity_items_source_integrity
        ) do
      assert constraints[name] == "c"
    end

    assert constraints["conversation_unread_spans_no_overlap"] == "x"

    %{rows: unique_indexes} =
      Ecto.Adapters.SQL.query!(
        Repo,
        """
        SELECT indexname
        FROM pg_indexes
        WHERE schemaname = 'public'
          AND indexdef LIKE 'CREATE UNIQUE INDEX%'
        ORDER BY indexname
        """,
        []
      )

    unique_indexes = MapSet.new(unique_indexes, fn [name] -> name end)

    for name <- ~w(
          users_email_index
          users_username_index
          users_tokens_context_token_index
          channels_workspace_id_name_index
          voice_channels_workspace_id_name_index
          workspace_memberships_workspace_id_user_id_index
          workspace_invites_code_index
          workspace_moderations_workspace_id_target_user_id_type_index
          workspace_bans_workspace_id_target_user_id_index
          messages_conversation_id_seq_index
          message_reactions_message_id_user_id_emoji_index
          activity_items_recipient_user_id_source_message_id_index
          activity_items_recipient_friend_relationship_kind_index
          activity_items_recipient_source_call_attempt_kind_index
          call_attempts_one_nonterminal_per_direct_conversation_index
          friend_relationships_user_low_id_user_high_id_index
          conversation_read_states_conversation_id_user_id_index
          direct_conversations_user_low_id_user_high_id_index
        ) do
      assert MapSet.member?(unique_indexes, name)
    end
  end

  test "Call Attempt and missed-call Activity keep recovery, pruning, and exactly-once indexes without an Activity FK" do
    %{rows: indexes} =
      Ecto.Adapters.SQL.query!(
        Repo,
        """
        SELECT indexname
        FROM pg_indexes
        WHERE schemaname = 'public'
        ORDER BY indexname
        """,
        []
      )

    index_names = MapSet.new(indexes, fn [name] -> name end)

    for name <- ~w(
          activity_items_recipient_source_call_attempt_kind_index
          call_attempts_one_nonterminal_per_direct_conversation_index
          call_attempts_ringing_deadline_index
          call_attempts_terminal_pruning_index
        ) do
      assert MapSet.member?(index_names, name)
    end

    assert %{rows: [["uuid"]]} =
             Ecto.Adapters.SQL.query!(
               Repo,
               """
               SELECT data_type
               FROM information_schema.columns
               WHERE table_schema = 'public'
                 AND table_name = 'activity_items'
                 AND column_name = 'source_call_attempt_id'
               """,
               []
             )

    %{rows: activity_foreign_keys} =
      Ecto.Adapters.SQL.query!(
        Repo,
        """
        SELECT con.conname
        FROM pg_constraint con
        JOIN pg_attribute source_attribute
          ON source_attribute.attrelid = con.conrelid
         AND source_attribute.attnum = con.conkey[1]
        WHERE con.contype = 'f'
          AND con.conrelid = 'activity_items'::regclass
          AND source_attribute.attname = 'source_call_attempt_id'
        """,
        []
      )

    assert activity_foreign_keys == []
  end

  test "raw inserts receive UUID defaults and unread summary checks are enforced" do
    %{rows: [[id]]} =
      Ecto.Adapters.SQL.query!(
        Repo,
        """
        INSERT INTO users (email, username, inserted_at, updated_at)
        VALUES ('raw-default@example.com', 'raw_default', now(), now())
        RETURNING id::text
        """,
        []
      )

    assert {:ok, ^id} = Ecto.UUID.cast(id)

    scope = user_scope_fixture()
    other_user = user_fixture()
    {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Baseline checks"})

    assert_raise Postgrex.Error, ~r/conversation_read_states_unread_summary_consistent/, fn ->
      Ecto.Adapters.SQL.query!(
        Repo,
        """
        INSERT INTO conversation_read_states (
          conversation_id, user_id, unread_count, inserted_at, updated_at
        )
        VALUES ($1, $2, 1, now(), now())
        """,
        [Ecto.UUID.dump!(workspace.default_channel_id), Ecto.UUID.dump!(other_user.id)]
      )
    end
  end

  test "the unread-span exclusion constraint rejects overlaps" do
    scope = user_scope_fixture()
    other_user = user_fixture()
    {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Exclusion checks"})

    Ecto.Adapters.SQL.query!(
      Repo,
      """
      INSERT INTO conversation_unread_spans (
        conversation_id, user_id, from_seq, to_seq, inserted_at, updated_at
      )
      VALUES ($1, $2, 3, 5, now(), now())
      """,
      [Ecto.UUID.dump!(workspace.default_channel_id), Ecto.UUID.dump!(other_user.id)]
    )

    assert_raise Postgrex.Error, ~r/conversation_unread_spans_no_overlap/, fn ->
      Ecto.Adapters.SQL.query!(
        Repo,
        """
        INSERT INTO conversation_unread_spans (
          conversation_id, user_id, from_seq, to_seq, inserted_at, updated_at
        )
        VALUES ($1, $2, 5, 8, now(), now())
        """,
        [Ecto.UUID.dump!(workspace.default_channel_id), Ecto.UUID.dump!(other_user.id)]
      )
    end
  end

  defp expected_foreign_key_delete_actions do
    %{
      "activity_items_actor_user_id_fkey" => "nilify_all",
      "activity_items_recipient_user_id_fkey" => "delete_all",
      "activity_items_source_conversation_id_fkey" => "delete_all",
      "activity_items_source_friend_relationship_id_fkey" => "delete_all",
      "activity_items_source_message_id_fkey" => "delete_all",
      "activity_items_workspace_id_fkey" => "delete_all",
      "call_attempts_caller_user_id_fkey" => "restrict",
      "call_attempts_direct_conversation_id_fkey" => "delete_all",
      "call_attempts_recipient_user_id_fkey" => "restrict",
      "channel_read_states_user_id_fkey" => "delete_all",
      "channel_unread_spans_user_id_fkey" => "delete_all",
      "channels_conversation_id_fkey" => "delete_all",
      "channels_workspace_id_fkey" => "no_action",
      "conversation_read_states_conversation_id_fkey" => "delete_all",
      "conversation_unread_spans_conversation_id_fkey" => "delete_all",
      "direct_conversations_conversation_id_fkey" => "delete_all",
      "direct_conversations_user_high_id_fkey" => "restrict",
      "direct_conversations_user_low_id_fkey" => "restrict",
      "friend_relationships_requested_by_user_id_fkey" => "restrict",
      "friend_relationships_user_high_id_fkey" => "restrict",
      "friend_relationships_user_low_id_fkey" => "restrict",
      "message_reactions_message_id_fkey" => "delete_all",
      "message_reactions_user_id_fkey" => "delete_all",
      "messages_conversation_id_fkey" => "delete_all",
      "messages_deleted_by_user_id_fkey" => "nilify_all",
      "messages_reply_to_message_id_fkey" => "no_action",
      "messages_user_id_fkey" => "nilify_all",
      "users_tokens_user_id_fkey" => "delete_all",
      "voice_channels_workspace_id_fkey" => "delete_all",
      "workspace_audit_events_actor_user_id_fkey" => "nilify_all",
      "workspace_audit_events_target_user_id_fkey" => "nilify_all",
      "workspace_audit_events_workspace_id_fkey" => "delete_all",
      "workspace_bans_banned_by_user_id_fkey" => "nilify_all",
      "workspace_bans_target_user_id_fkey" => "delete_all",
      "workspace_bans_workspace_id_fkey" => "delete_all",
      "workspace_invites_created_by_user_id_fkey" => "nilify_all",
      "workspace_invites_workspace_id_fkey" => "delete_all",
      "workspace_memberships_user_id_fkey" => "delete_all",
      "workspace_memberships_workspace_id_fkey" => "delete_all",
      "workspace_moderations_created_by_user_id_fkey" => "nilify_all",
      "workspace_moderations_ended_by_user_id_fkey" => "nilify_all",
      "workspace_moderations_target_user_id_fkey" => "delete_all",
      "workspace_moderations_workspace_id_fkey" => "delete_all",
      "workspaces_default_channel_id_fkey" => "nilify_all",
      "workspaces_owner_id_fkey" => "restrict"
    }
  end
end
