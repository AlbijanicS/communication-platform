defmodule DiscordClone.Chat.ActivitySyncTest do
  use DiscordClone.DataCase, async: false

  import DiscordClone.AccountsFixtures
  import DiscordCloneWeb.WorkspaceLiveTestHelpers, only: [add_workspace_member!: 2]

  alias DiscordClone.Activities.ActivityItem
  alias DiscordClone.Chat
  alias DiscordClone.Repo
  alias DiscordClone.Workspaces

  describe "private Activity synchronization" do
    test "publishes compact creation facts only to the intended recipients after commit" do
      author_scope = user_scope_fixture(user_fixture(%{username: "sync_author"}))
      recipient_scope = user_scope_fixture(user_fixture(%{username: "sync_recipient"}))
      other_scope = user_scope_fixture(user_fixture(%{username: "sync_other"}))
      {:ok, workspace} = Workspaces.create_workspace(author_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, recipient_scope)
      add_workspace_member!(workspace, other_scope)

      start_activity_subscriber!(:recipient, recipient_scope)
      start_activity_subscriber!(:other, other_scope)

      assert {:ok, message} =
               Chat.send_message(author_scope, workspace.default_channel_id, %{
                 content: "hello @sync_recipient"
               })

      assert_receive {:recipient, {:activity_changed, payload}}
      assert payload == %{action: :created, source_message_id: message.id}
      refute_receive {:other, {:activity_changed, _payload}}
    end

    test "does not publish creation when the enclosing message transaction rolls back" do
      author_scope = user_scope_fixture(user_fixture(%{username: "rollback_author"}))
      recipient_scope = user_scope_fixture(user_fixture(%{username: "rollback_recipient"}))
      {:ok, workspace} = Workspaces.create_workspace(author_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, recipient_scope)
      assert :ok = Chat.subscribe_to_activity(recipient_scope)

      Ecto.Adapters.SQL.query!(
        Repo,
        """
        CREATE FUNCTION reject_sync_activity() RETURNS trigger AS $$
        BEGIN
          RAISE EXCEPTION 'activity insert rejected';
        END;
        $$ LANGUAGE plpgsql
        """
      )

      Ecto.Adapters.SQL.query!(
        Repo,
        """
        CREATE TRIGGER reject_sync_activity
        BEFORE INSERT ON activity_items
        FOR EACH ROW EXECUTE FUNCTION reject_sync_activity()
        """
      )

      assert_raise Postgrex.Error, fn ->
        Chat.send_message(author_scope, workspace.default_channel_id, %{
          content: "hello @rollback_recipient"
        })
      end

      refute_receive {:activity_changed, _payload}
    end

    test "publishes compact facts for individual read, mark-all, and message removal" do
      author_scope = user_scope_fixture(user_fixture(%{username: "facts_author"}))
      recipient_scope = user_scope_fixture(user_fixture(%{username: "facts_recipient"}))
      {:ok, workspace} = Workspaces.create_workspace(author_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, recipient_scope)
      assert :ok = Chat.subscribe_to_activity(recipient_scope)

      assert {:ok, first_message} =
               Chat.send_message(author_scope, workspace.default_channel_id, %{
                 content: "first @facts_recipient"
               })

      assert_receive {:activity_changed, %{action: :created}}
      first_item = Repo.get_by!(ActivityItem, source_message_id: first_message.id)

      assert {:ok, _destination} = Chat.open_activity_item(recipient_scope, first_item.id)

      assert_receive {:activity_changed, %{action: :read, activity_item_id: activity_item_id}}

      assert activity_item_id == first_item.id

      assert {:ok, second_message} =
               Chat.send_message(author_scope, workspace.default_channel_id, %{
                 content: "second @facts_recipient"
               })

      assert_receive {:activity_changed, %{action: :created}}
      assert {:ok, 1} = Chat.mark_all_activity_read(recipient_scope)
      assert_receive {:activity_changed, %{action: :all_read, updated_count: 1}}

      assert {:ok, _deleted_message} = Chat.delete_message(author_scope, second_message.id)

      assert_receive {:activity_changed,
                      %{action: :removed, source_message_id: source_message_id}}

      assert source_message_id == second_message.id
    end

    test "publishes removal after bulk message cleanup commits" do
      owner_scope = user_scope_fixture(user_fixture(%{username: "bulk_owner"}))
      author_scope = user_scope_fixture(user_fixture(%{username: "bulk_author"}))
      recipient_scope = user_scope_fixture(user_fixture(%{username: "bulk_recipient"}))
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, author_scope)
      add_workspace_member!(workspace, recipient_scope)

      assert {:ok, _message} =
               Chat.send_message(author_scope, workspace.default_channel_id, %{
                 content: "hello @bulk_recipient"
               })

      assert :ok = Chat.subscribe_to_activity(recipient_scope)

      assert {:ok, [_deleted_message]} =
               Chat.soft_delete_user_workspace_messages(
                 workspace.id,
                 author_scope.user.id,
                 owner_scope.user.id,
                 :all
               )

      assert_receive {:activity_changed, payload}
      assert payload == %{action: :removed, workspace_id: workspace.id}
    end

    test "does not publish removal when message deletion rolls back" do
      author_scope = user_scope_fixture(user_fixture(%{username: "remove_rollback_author"}))

      recipient_scope =
        user_scope_fixture(user_fixture(%{username: "remove_rollback_recipient"}))

      {:ok, workspace} = Workspaces.create_workspace(author_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, recipient_scope)

      assert {:ok, message} =
               Chat.send_message(author_scope, workspace.default_channel_id, %{
                 content: "hello @remove_rollback_recipient"
               })

      assert :ok = Chat.subscribe_to_activity(recipient_scope)
      install_reject_activity_cleanup_trigger!()

      assert_raise Postgrex.Error, fn ->
        Chat.delete_message(author_scope, message.id)
      end

      refute_receive {:activity_changed, _payload}
    end

    test "does not publish individual read when its update rolls back" do
      {_author_scope, recipient_scope, _workspace, activity_item} =
        activity_fixture("read_failure")

      assert :ok = Chat.subscribe_to_activity(recipient_scope)
      install_reject_activity_update_trigger!()

      assert_raise Postgrex.Error, fn ->
        Chat.open_activity_item(recipient_scope, activity_item.id)
      end

      refute_receive {:activity_changed, _payload}
      assert {:ok, 1} = Chat.unread_activity_count(recipient_scope)
    end

    test "does not publish mark-all when its update rolls back" do
      {_author_scope, recipient_scope, _workspace, _activity_item} =
        activity_fixture("mark_all_failure")

      assert :ok = Chat.subscribe_to_activity(recipient_scope)
      install_reject_activity_update_trigger!()

      assert_raise Postgrex.Error, fn ->
        Chat.mark_all_activity_read(recipient_scope)
      end

      refute_receive {:activity_changed, _payload}
    end

    test "does not publish bulk removal when its transaction rolls back" do
      {author_scope, recipient_scope, workspace, _activity_item} =
        activity_fixture("bulk_failure")

      owner_scope = user_scope_fixture(user_fixture(%{username: "bulk_failure_owner"}))
      add_workspace_member!(workspace, owner_scope)
      assert :ok = Chat.subscribe_to_activity(recipient_scope)
      install_reject_activity_cleanup_trigger!()

      assert_raise Postgrex.Error, fn ->
        Chat.soft_delete_user_workspace_messages(
          workspace.id,
          author_scope.user.id,
          owner_scope.user.id,
          :all
        )
      end

      refute_receive {:activity_changed, _payload}
    end

    test "does not publish membership cleanup when its transaction rolls back" do
      {_author_scope, recipient_scope, workspace, _activity_item} =
        activity_fixture("membership_failure")

      assert :ok = Chat.subscribe_to_activity(recipient_scope)
      install_reject_activity_cleanup_trigger!()

      assert_raise Postgrex.Error, fn ->
        Workspaces.leave_workspace(recipient_scope, workspace.id)
      end

      refute_receive {:activity_changed, _payload}
    end

    test "publishes workspace removal only to the member whose private feed changed" do
      owner_scope = user_scope_fixture(user_fixture(%{username: "cleanup_owner"}))
      leaving_scope = user_scope_fixture(user_fixture(%{username: "cleanup_leaving"}))
      retained_scope = user_scope_fixture(user_fixture(%{username: "cleanup_retained"}))
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, leaving_scope)
      add_workspace_member!(workspace, retained_scope)

      assert {:ok, _message} =
               Chat.send_message(owner_scope, workspace.default_channel_id, %{
                 content: "hello @cleanup_leaving and @cleanup_retained"
               })

      start_activity_subscriber!(:leaving, leaving_scope)
      start_activity_subscriber!(:retained, retained_scope)
      assert {:ok, _membership} = Workspaces.leave_workspace(leaving_scope, workspace.id)

      assert_receive {:leaving, {:activity_changed, payload}}
      assert payload == %{action: :removed, workspace_id: workspace.id}
      refute_receive {:retained, {:activity_changed, _payload}}
    end

    test "requires an authenticated scope to subscribe" do
      assert Chat.subscribe_to_activity(nil) == {:error, :unauthenticated}

      assert Chat.subscribe_to_activity(%DiscordClone.Accounts.Scope{}) ==
               {:error, :unauthenticated}
    end
  end

  defp start_activity_subscriber!(label, scope) do
    parent = self()

    start_supervised!(%{
      id: {__MODULE__, label},
      start:
        {Task, :start_link,
         [
           fn ->
             :ok = Chat.subscribe_to_activity(scope)
             send(parent, {:activity_subscriber_ready, label})

             receive do
               message -> send(parent, {label, message})
             end
           end
         ]}
    })

    assert_receive {:activity_subscriber_ready, ^label}
  end

  defp activity_fixture(prefix) do
    author_scope = user_scope_fixture(user_fixture(%{username: "#{prefix}_author"}))
    recipient_scope = user_scope_fixture(user_fixture(%{username: "#{prefix}_recipient"}))
    {:ok, workspace} = Workspaces.create_workspace(author_scope, %{name: "Foundry"})
    add_workspace_member!(workspace, recipient_scope)

    assert {:ok, message} =
             Chat.send_message(author_scope, workspace.default_channel_id, %{
               content: "hello @#{prefix}_recipient"
             })

    activity_item = Repo.get_by!(ActivityItem, source_message_id: message.id)
    {author_scope, recipient_scope, workspace, activity_item}
  end

  defp install_reject_activity_update_trigger! do
    Ecto.Adapters.SQL.query!(
      Repo,
      """
      CREATE FUNCTION reject_activity_update() RETURNS trigger AS $$
      BEGIN
        RAISE EXCEPTION 'activity update rejected';
      END;
      $$ LANGUAGE plpgsql
      """
    )

    Ecto.Adapters.SQL.query!(
      Repo,
      """
      CREATE TRIGGER reject_activity_update
      BEFORE UPDATE ON activity_items
      FOR EACH ROW EXECUTE FUNCTION reject_activity_update()
      """
    )
  end
end
