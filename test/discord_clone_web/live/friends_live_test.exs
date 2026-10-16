defmodule DiscordCloneWeb.FriendsLiveTest do
  use DiscordCloneWeb.ConnCase, async: false

  import DiscordClone.AccountsFixtures
  import Phoenix.LiveViewTest

  alias DiscordClone.{Friendships, Presence}

  setup :register_and_log_in_user

  test "authenticated User sees stable incoming and outgoing request streams", %{
    conn: conn,
    user: user
  } do
    sender = user_fixture(username: "friends_sender")
    recipient = user_fixture(username: "friends_recipient")

    assert {:ok, %{relationship: incoming}} =
             Friendships.send_friend_request(user_scope_fixture(sender), %{
               username: user.username
             })

    assert {:ok, %{relationship: outgoing}} =
             Friendships.send_friend_request(user_scope_fixture(user), %{
               username: recipient.username
             })

    {:ok, view, _html} = live(conn, ~p"/friends")

    assert has_element?(view, "#friends-home")
    assert has_element?(view, "#friend-request-form")
    assert has_element?(view, "#incoming-requests[phx-update='stream']")
    assert has_element?(view, "#incoming-request-#{incoming.id}")
    assert has_element?(view, "#outgoing-requests[phx-update='stream']")
    assert has_element?(view, "#outgoing-request-#{outgoing.id}")
  end

  test "exact-username form reports validation outcomes and refreshes outgoing requests", %{
    conn: conn,
    user: user
  } do
    target = user_fixture(username: "form_target")
    {:ok, view, _html} = live(conn, ~p"/friends")

    view
    |> form("#friend-request-form", friend_request: %{username: "form"})
    |> render_submit()

    assert has_element?(view, "#friend-request-outcome[data-kind='error']")
    refute has_element?(view, "#outgoing-requests [id^='outgoing-request-']")

    view
    |> form("#friend-request-form", friend_request: %{username: target.username})
    |> render_submit()

    assert has_element?(view, "#friend-request-outcome[data-kind='success']")
    assert has_element?(view, "#outgoing-requests [id^='outgoing-request-']")

    view
    |> form("#friend-request-form", friend_request: %{username: user.username})
    |> render_submit()

    assert has_element?(view, "#friend-request-outcome[data-kind='error']")
  end

  test "unauthenticated visitors follow the established login redirect", %{conn: _conn} do
    conn = Phoenix.ConnTest.build_conn()

    assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(conn, ~p"/friends")
  end

  test "accepts, declines, and cancels relationships with stable stream identities", %{
    conn: conn,
    user: user
  } do
    accepted_sender = user_fixture(username: "accepted_sender")
    declined_sender = user_fixture(username: "declined_sender")
    cancelled_target = user_fixture(username: "cancelled_target")

    assert {:ok, %{relationship: accepted_request}} =
             Friendships.send_friend_request(user_scope_fixture(accepted_sender), %{
               username: user.username
             })

    assert {:ok, %{relationship: declined_request}} =
             Friendships.send_friend_request(user_scope_fixture(declined_sender), %{
               username: user.username
             })

    assert {:ok, %{relationship: cancelled_request}} =
             Friendships.send_friend_request(user_scope_fixture(user), %{
               username: cancelled_target.username
             })

    {:ok, view, _html} = live(conn, ~p"/friends")

    assert has_element?(view, "#incoming-request-#{accepted_request.id}")

    view
    |> element("#accept-friend-request-#{accepted_request.id}")
    |> render_click()

    refute has_element?(view, "#incoming-request-#{accepted_request.id}")
    assert has_element?(view, "#friendship-#{accepted_request.id}")

    view
    |> element("#decline-friend-request-#{declined_request.id}")
    |> render_click()

    refute has_element?(view, "#incoming-request-#{declined_request.id}")

    view
    |> element("#cancel-friend-request-#{cancelled_request.id}")
    |> render_click()

    refute has_element?(view, "#outgoing-request-#{cancelled_request.id}")
  end

  test "refreshes crossed Friend Requests in every open session", %{
    conn: conn,
    user: user
  } do
    other_user = user_fixture(username: "crossed_live_user")
    other_conn = build_conn() |> log_in_user(other_user)

    {:ok, first_view, _html} = live(conn, ~p"/friends")
    {:ok, second_view, _html} = live(other_conn, ~p"/friends")

    first_view
    |> form("#friend-request-form", friend_request: %{username: other_user.username})
    |> render_submit()

    assert has_element?(first_view, "#outgoing-requests [id^='outgoing-request-']")
    assert has_element?(second_view, "#incoming-requests [id^='incoming-request-']")

    second_view
    |> form("#friend-request-form", friend_request: %{username: user.username})
    |> render_submit()

    assert has_element?(first_view, "#friends-list [id^='friendship-']")
    assert has_element?(second_view, "#friends-list [id^='friendship-']")
    refute has_element?(first_view, "#outgoing-requests [id^='outgoing-request-']")
    refute has_element?(second_view, "#incoming-requests [id^='incoming-request-']")
  end

  test "private Friendship events refresh all open sessions for the affected User", %{
    conn: conn,
    user: user
  } do
    sender = user_fixture(username: "multi_session_sender")
    second_conn = build_conn() |> log_in_user(user)

    {:ok, first_view, _html} = live(conn, ~p"/friends")
    {:ok, second_view, _html} = live(second_conn, ~p"/friends")

    assert {:ok, %{relationship: request}} =
             Friendships.send_friend_request(user_scope_fixture(sender), %{
               username: user.username
             })

    assert has_element?(first_view, "#incoming-request-#{request.id}")
    assert has_element?(second_view, "#incoming-request-#{request.id}")
  end

  test "global Friend Presence stays online until the final authenticated LiveView disconnects",
       %{
         conn: conn,
         user: user,
         scope: scope
       } do
    friend = user_fixture(username: "global_presence_friend")
    friend_scope = user_scope_fixture(friend)

    assert {:ok, %{relationship: request}} =
             Friendships.send_friend_request(scope, %{username: friend.username})

    assert {:ok, friendship} = Friendships.accept_friend_request(friend_scope, request.id)

    {:ok, observer_view, _html} = live(conn, ~p"/friends")

    assert has_element?(
             observer_view,
             "#friendship-#{friendship.id}[data-presence-state='offline']"
           )

    friend_conn = build_conn() |> log_in_user(friend)
    {:ok, first_friend_view, _html} = live(friend_conn, ~p"/friends")
    {:ok, second_friend_view, _html} = live(friend_conn, ~p"/activity")

    assert has_element?(
             observer_view,
             "#friendship-#{friendship.id}[data-presence-state='online']"
           )

    stop_live_view(first_friend_view)

    assert has_element?(
             observer_view,
             "#friendship-#{friendship.id}[data-presence-state='online']"
           )

    presence_pid = Presence.user_presence_pid(friend.id)
    presence_ref = Process.monitor(presence_pid)
    stop_live_view(second_friend_view)
    assert_receive {:DOWN, ^presence_ref, :process, ^presence_pid, :normal}

    assert has_element?(
             observer_view,
             "#friendship-#{friendship.id}[data-presence-state='offline']"
           )

    assert user.id != friend.id
  end

  defp stop_live_view(view) do
    Process.unlink(view.pid)
    ref = Process.monitor(view.pid)
    GenServer.stop(view.pid)
    assert_receive {:DOWN, ^ref, :process, _pid, :normal}
  end
end
