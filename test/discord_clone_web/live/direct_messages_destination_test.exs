defmodule DiscordCloneWeb.DirectMessagesDestinationTest do
  use DiscordCloneWeb.ConnCase, async: false

  import DiscordClone.AccountsFixtures
  import Phoenix.LiveViewTest

  alias DiscordClone.{Chat, Friendships, Workspaces}

  setup :register_and_log_in_user

  test "authenticated Workspace and Direct Messages surfaces share one global destination rail",
       %{
         conn: conn,
         scope: scope
       } do
    assert {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Rail guild"})

    {:ok, workspace_view, _html} = live(conn, ~p"/workspaces")

    assert has_element?(workspace_view, "#global-destination-rail")

    assert has_element?(workspace_view, "#workspace-sidebar[class*='overflow-x-hidden']")
    assert has_element?(workspace_view, "#workspaces[class*='flex-1']")
    refute has_element?(workspace_view, "#workspaces[class*='py-2']")

    assert has_element?(
             workspace_view,
             "#channel-sidebar #global-voice-controls[phx-hook='VoiceControls'][phx-update='ignore']"
           )

    assert has_element?(
             workspace_view,
             "#channel-sidebar #global-voice-connection-panel[data-voice-controls-panel][hidden]"
           )

    assert has_element?(
             workspace_view,
             "#global-voice-controls-status[role='status'][aria-live='polite']"
           )

    assert has_element?(
             workspace_view,
             "#global-voice-controls-announcement[role='status'][aria-live='polite']"
           )

    assert has_element?(
             workspace_view,
             "#voice-lifecycle[phx-hook='VoiceLifecycle'][phx-update='ignore'][hidden]"
           )

    assert has_element?(
             workspace_view,
             "#global-voice-controls-retry[type='button'][data-voice-controls-retry][hidden]"
           )

    assert has_element?(
             workspace_view,
             "#workspace-#{workspace.id}-voice-badge[phx-hook='VoiceWorkspaceBadge'][phx-update='ignore'][aria-controls='global-voice-connection-panel'][aria-expanded='false'][class*='-right-1'][class*='-top-1'][hidden]"
           )

    assert has_element?(
             workspace_view,
             "#global-direct-messages-destination[href='/direct-messages'][aria-label='Direct Messages'][title='Direct Messages']"
           )

    assert has_element?(workspace_view, "#workspaces [data-workspace-id='#{workspace.id}']")

    assert has_element?(workspace_view, "#workspace-#{workspace.id}[class*='rounded-2xl']")

    refute has_element?(
             workspace_view,
             "#workspace-#{workspace.id}[class*='hover:-translate-y-0.5']"
           )

    {:ok, direct_view, _html} = live(conn, ~p"/direct-messages")

    assert has_element?(direct_view, "#global-destination-rail")

    assert has_element?(
             direct_view,
             "#direct-messages-sidebar > #global-voice-controls[phx-hook='VoiceControls'][phx-update='ignore']"
           )

    assert has_element?(direct_view, "[data-voice-logout]")

    assert has_element?(direct_view, "#global-activity-bell[href='/activity']")
    assert has_element?(direct_view, "#workspace-create-toggle[title='Create workspace']")
    assert has_element?(direct_view, "#friends-members-sidebar[aria-label='Friends']")
    assert has_element?(direct_view, "#friends-list[phx-update='stream']")
    assert has_element?(direct_view, "#direct-messages-sidebar")
    assert has_element?(direct_view, "#direct-messages-current-user")
    assert has_element?(direct_view, "#direct-messages-settings-link[data-phx-link=redirect]")
    assert has_element?(direct_view, "#direct-messages-current-user [aria-label='Log out']")
    assert has_element?(direct_view, "#direct-messages-friends-link[aria-current='page']")
    assert has_element?(direct_view, "#direct-conversations[phx-update='stream']")
    assert has_element?(direct_view, "#direct-conversations-empty")
    assert has_element?(direct_view, "[data-workspace-id='#{workspace.id}']")
  end

  test "Direct Messages routes require authentication", %{conn: _conn} do
    conn = Phoenix.ConnTest.build_conn()

    assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(conn, ~p"/direct-messages")

    assert {:error, {:redirect, %{to: "/users/log-in"}}} =
             live(conn, ~p"/direct-messages/requests")
  end

  test "sidebar shows request counts, empty and former-Friend Conversations, and unread badges",
       %{
         conn: conn,
         user: user,
         scope: scope
       } do
    requester = user_fixture(username: "sidebar_requester")

    assert {:ok, %{relationship: _request}} =
             Friendships.send_friend_request(user_scope_fixture(requester), %{
               username: user.username
             })

    {friend, friend_scope, active_conversation, _active_friendship} =
      direct_conversation_with(scope, "sidebar_active")

    {former_friend, _former_scope, former_conversation, former_friendship} =
      direct_conversation_with(scope, "sidebar_former")

    assert :ok = Friendships.remove_friend(scope, former_friendship.id)

    assert {:ok, _message} =
             Chat.send_direct_message(friend_scope, active_conversation.id, %{
               content: "Unread attention"
             })

    {:ok, view, _html} = live(conn, ~p"/direct-messages")

    assert has_element?(view, "#direct-messages-request-count", "1")
    assert has_element?(view, "#direct-messages-unread-count", "1")
    assert has_element?(view, "#direct-conversation-unread-#{active_conversation.id}", "1")

    assert has_element?(
             view,
             "#direct-conversation-entry-#{active_conversation.id}",
             friend.username
           )

    assert has_element?(
             view,
             "#direct-conversation-entry-#{former_conversation.id}[data-writable='false']",
             former_friend.username
           )

    assert has_element?(view, "#direct-conversation-read-only-#{former_conversation.id}")
    assert has_element?(view, "#direct-conversation-empty-label-#{former_conversation.id}")
  end

  test "new Messages update badges and move streamed Conversations in every open session", %{
    conn: conn,
    user: user,
    scope: scope
  } do
    {_first_friend, first_scope, first_conversation, _first_friendship} =
      direct_conversation_with(scope, "stream_first")

    {_second_friend, second_scope, second_conversation, _second_friendship} =
      direct_conversation_with(scope, "stream_second")

    assert {:ok, _message} =
             Chat.send_direct_message(second_scope, second_conversation.id, %{content: "second"})

    second_conn = build_conn() |> log_in_user(user)
    {:ok, first_view, _html} = live(conn, ~p"/direct-messages")
    {:ok, second_view, _html} = live(second_conn, ~p"/direct-messages")
    {:ok, workspace_view, _html} = live(conn, ~p"/workspaces")

    assert conversation_ids(first_view) |> List.first() == second_conversation.id

    assert {:ok, _message} =
             Chat.send_direct_message(first_scope, first_conversation.id, %{content: "now first"})

    assert conversation_ids(first_view) |> List.first() == first_conversation.id
    assert conversation_ids(second_view) |> List.first() == first_conversation.id
    assert has_element?(first_view, "#direct-messages-unread-count", "2")
    assert has_element?(second_view, "#direct-messages-unread-count", "2")
    assert has_element?(workspace_view, "#direct-messages-unread-count", "2")
  end

  test "incoming request badges synchronize across authenticated sessions", %{
    conn: conn,
    user: user
  } do
    second_conn = build_conn() |> log_in_user(user)
    {:ok, first_view, _html} = live(conn, ~p"/direct-messages")
    {:ok, second_view, _html} = live(second_conn, ~p"/direct-messages/requests")

    requester = user_fixture(username: "synchronized_requester")

    assert {:ok, %{relationship: _request}} =
             Friendships.send_friend_request(user_scope_fixture(requester), %{
               username: user.username
             })

    assert has_element?(first_view, "#direct-messages-request-count", "1")
    assert has_element?(second_view, "#direct-messages-request-count", "1")
  end

  defp direct_conversation_with(scope, username) do
    friend = user_fixture(username: username)
    friend_scope = user_scope_fixture(friend)

    assert {:ok, %{relationship: request}} =
             Friendships.send_friend_request(scope, %{username: friend.username})

    assert {:ok, friendship} = Friendships.accept_friend_request(friend_scope, request.id)
    assert {:ok, direct_conversation} = Chat.open_direct_conversation(scope, friend.id)

    {friend, friend_scope, direct_conversation, friendship}
  end

  defp conversation_ids(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> then(& &1["#direct-conversations > [data-conversation-id]"])
    |> LazyHTML.attribute("data-conversation-id")
  end
end
