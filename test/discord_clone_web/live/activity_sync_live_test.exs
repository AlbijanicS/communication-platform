defmodule DiscordCloneWeb.ActivitySyncLiveTest do
  use DiscordCloneWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import DiscordCloneWeb.WorkspaceLiveTestHelpers, only: [add_workspace_member!: 2]

  alias DiscordClone.Activities.ActivityItem
  alias DiscordClone.Chat
  alias DiscordClone.Friendships
  alias DiscordClone.Repo
  alias DiscordClone.Workspaces

  test "synchronizes bells and the open feed across the user's sessions", %{conn: conn} do
    recipient_scope = DiscordClone.AccountsFixtures.user_scope_fixture()
    recipient_conn = log_in_user(conn, recipient_scope.user)
    author_scope = DiscordClone.AccountsFixtures.user_scope_fixture()
    {:ok, workspace} = Workspaces.create_workspace(author_scope, %{name: "Foundry"})
    add_workspace_member!(workspace, recipient_scope)

    {:ok, workspace_view, _html} = live(recipient_conn, ~p"/workspaces")

    {:ok, channel_view, _html} =
      live(
        recipient_conn,
        ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}"
      )

    {:ok, activity_view, _html} = live(recipient_conn, ~p"/activity")

    assert {:ok, message} =
             Chat.send_message(author_scope, workspace.default_channel_id, %{
               content: "please review @#{recipient_scope.user.username}"
             })

    item = Repo.get_by!(ActivityItem, source_message_id: message.id)

    assert has_element?(workspace_view, "#global-activity-unread-count", "1")
    assert has_element?(channel_view, "#global-activity-unread-count", "1")
    assert has_element?(activity_view, "#global-activity-unread-count", "1")

    assert has_element?(
             workspace_view,
             "#activity-preview-item-#{item.id}[data-read-state='unread']"
           )

    assert has_element?(
             channel_view,
             "#activity-preview-item-#{item.id}[data-read-state='unread']"
           )

    assert has_element?(activity_view, "#activity-item-#{item.id}[data-read-state='unread']")

    assert {:ok, _destination} = Chat.open_activity_item(recipient_scope, item.id)

    refute has_element?(workspace_view, "#global-activity-unread-count")
    refute has_element?(channel_view, "#global-activity-unread-count")

    assert has_element?(
             workspace_view,
             "#activity-preview-item-#{item.id}[data-read-state='read']"
           )

    assert has_element?(channel_view, "#activity-preview-item-#{item.id}[data-read-state='read']")
    assert has_element?(activity_view, "#activity-item-#{item.id}[data-read-state='read']")
  end

  test "synchronizes Friend Request Activity creation, reads, and cancellation across sessions",
       %{conn: conn} do
    recipient_scope = DiscordClone.AccountsFixtures.user_scope_fixture()
    recipient_conn = log_in_user(conn, recipient_scope.user)
    requester_scope = DiscordClone.AccountsFixtures.user_scope_fixture()

    {:ok, first_feed_view, _html} = live(recipient_conn, ~p"/activity")
    {:ok, second_feed_view, _html} = live(recipient_conn, ~p"/activity")

    assert {:ok, %{relationship: request}} =
             Friendships.send_friend_request(requester_scope, %{
               username: recipient_scope.user.username
             })

    item = Repo.get_by!(ActivityItem, source_friend_relationship_id: request.id)

    assert has_element?(first_feed_view, "#global-activity-unread-count", "1")
    assert has_element?(second_feed_view, "#global-activity-unread-count", "1")
    assert has_element?(first_feed_view, "#activity-item-#{item.id}[data-read-state='unread']")
    assert has_element?(second_feed_view, "#activity-item-#{item.id}[data-read-state='unread']")

    assert {:ok, _destination} = Chat.open_activity_item(recipient_scope, item.id)

    refute has_element?(first_feed_view, "#global-activity-unread-count")
    refute has_element?(second_feed_view, "#global-activity-unread-count")
    assert has_element?(first_feed_view, "#activity-item-#{item.id}[data-read-state='read']")
    assert has_element?(second_feed_view, "#activity-item-#{item.id}[data-read-state='read']")

    assert :ok = Friendships.cancel_friend_request(requester_scope, request.id)
    refute has_element?(first_feed_view, "#activity-item-#{item.id}")
    refute has_element?(second_feed_view, "#activity-item-#{item.id}")
  end

  test "synchronizes mark-all and removals without disturbing loaded feed ordering", %{conn: conn} do
    recipient_scope = DiscordClone.AccountsFixtures.user_scope_fixture()
    recipient_conn = log_in_user(conn, recipient_scope.user)
    author_scope = DiscordClone.AccountsFixtures.user_scope_fixture()
    {:ok, workspace} = Workspaces.create_workspace(author_scope, %{name: "Foundry"})
    add_workspace_member!(workspace, recipient_scope)

    assert {:ok, first_message} =
             Chat.send_message(author_scope, workspace.default_channel_id, %{
               content: "first @#{recipient_scope.user.username}"
             })

    assert {:ok, second_message} =
             Chat.send_message(author_scope, workspace.default_channel_id, %{
               content: "second @#{recipient_scope.user.username}"
             })

    first_item = Repo.get_by!(ActivityItem, source_message_id: first_message.id)
    second_item = Repo.get_by!(ActivityItem, source_message_id: second_message.id)
    {:ok, workspace_view, _html} = live(recipient_conn, ~p"/workspaces")
    {:ok, first_feed_view, _html} = live(recipient_conn, ~p"/activity")
    {:ok, second_feed_view, _html} = live(recipient_conn, ~p"/activity")

    first_order = activity_row_ids(first_feed_view)
    assert first_order == activity_row_ids(second_feed_view)

    first_feed_view
    |> element("#activity-mark-all-read")
    |> render_click()

    refute has_element?(workspace_view, "#global-activity-unread-count")
    refute has_element?(second_feed_view, "#global-activity-unread-count")
    refute has_element?(second_feed_view, "#activity-feed > article[data-read-state='unread']")
    assert activity_row_ids(second_feed_view) == first_order

    assert {:ok, deletion_message} =
             Chat.send_message(author_scope, workspace.default_channel_id, %{
               content: "delete me @#{recipient_scope.user.username}"
             })

    deletion_item = Repo.get_by!(ActivityItem, source_message_id: deletion_message.id)
    assert has_element?(workspace_view, "#global-activity-unread-count", "1")
    assert has_element?(workspace_view, "#activity-preview-item-#{deletion_item.id}")
    assert has_element?(second_feed_view, "#global-activity-unread-count", "1")
    assert has_element?(second_feed_view, "#activity-item-#{deletion_item.id}")

    assert {:ok, _deleted_message} = Chat.delete_message(author_scope, deletion_message.id)
    refute has_element?(workspace_view, "#global-activity-unread-count")
    refute has_element?(workspace_view, "#activity-preview-item-#{deletion_item.id}")
    refute has_element?(second_feed_view, "#global-activity-unread-count")
    refute has_element?(first_feed_view, "#activity-item-#{deletion_item.id}")
    refute has_element?(second_feed_view, "#activity-item-#{deletion_item.id}")

    assert {:ok, _deleted_message} = Chat.delete_message(author_scope, first_message.id)

    refute has_element?(first_feed_view, "#activity-item-#{first_item.id}")
    refute has_element?(second_feed_view, "#activity-item-#{first_item.id}")
    assert has_element?(first_feed_view, "#activity-item-#{second_item.id}")
    assert has_element?(second_feed_view, "#activity-item-#{second_item.id}")
  end

  test "synchronizes membership cleanup across the former member's sessions", %{conn: conn} do
    recipient_scope = DiscordClone.AccountsFixtures.user_scope_fixture()
    recipient_conn = log_in_user(conn, recipient_scope.user)
    owner_scope = DiscordClone.AccountsFixtures.user_scope_fixture()
    {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
    add_workspace_member!(workspace, recipient_scope)

    assert {:ok, message} =
             Chat.send_message(owner_scope, workspace.default_channel_id, %{
               content: "please review @#{recipient_scope.user.username}"
             })

    item = Repo.get_by!(ActivityItem, source_message_id: message.id)
    {:ok, workspace_view, _html} = live(recipient_conn, ~p"/workspaces")
    {:ok, activity_view, _html} = live(recipient_conn, ~p"/activity")

    assert {:ok, _membership} =
             Workspaces.kick_member(owner_scope, workspace.id, recipient_scope.user.id, %{
               "reason" => "Access removed"
             })

    refute has_element?(workspace_view, "#global-activity-unread-count")
    refute has_element?(activity_view, "#global-activity-unread-count")
    refute has_element?(activity_view, "#activity-item-#{item.id}")
  end

  defp activity_row_ids(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.filter("#activity-feed > article")
    |> Enum.map(&LazyHTML.attribute(&1, "id"))
    |> List.flatten()
  end
end
