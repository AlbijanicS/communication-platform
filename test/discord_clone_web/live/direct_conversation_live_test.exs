defmodule DiscordCloneWeb.DirectConversationLiveTest do
  use DiscordCloneWeb.ConnCase, async: false

  import DiscordClone.AccountsFixtures
  import Phoenix.LiveViewTest

  alias DiscordClone.Activities.ActivityItem
  alias DiscordClone.Chat
  alias DiscordClone.Chat.Runtime
  alias DiscordClone.Friendships
  alias DiscordClone.Repo

  setup :register_and_log_in_user

  test "Message opens one empty Direct Conversation and either participant can revisit it", %{
    conn: conn,
    user: user,
    scope: scope
  } do
    friend = user_fixture(username: "live_direct_friend")
    friend_scope = user_scope_fixture(friend)

    assert {:ok, %{relationship: request}} =
             Friendships.send_friend_request(scope, %{username: friend.username})

    assert {:ok, _friendship} = Friendships.accept_friend_request(friend_scope, request.id)

    {:ok, friends_view, _html} = live(conn, ~p"/friends")

    assert has_element?(friends_view, "#message-friend-#{friend.id}")

    friends_view
    |> element("#message-friend-#{friend.id}")
    |> render_click()

    assert {:ok, direct_conversation} = Chat.find_direct_conversation(scope, friend.id)
    direct_path = ~p"/direct-messages/#{direct_conversation.id}"
    assert_redirected(friends_view, direct_path)

    {:ok, direct_view, _html} = live(conn, direct_path)

    assert has_element?(direct_view, "#direct-conversation")
    assert has_element?(direct_view, "#direct-conversation-empty")
    assert has_element?(direct_view, "#direct-conversation-participant-#{friend.id}")

    friend_conn = build_conn() |> log_in_user(friend)
    assert {:ok, friend_view, _html} = live(friend_conn, direct_path)
    assert has_element?(friend_view, "#direct-conversation-participant-#{user.id}")

    assert has_element?(
             direct_view,
             "#direct-conversation-presence-#{friend.id}[data-presence-state='online']"
           )

    assert has_element?(
             friend_view,
             "#direct-conversation-presence-#{user.id}[data-presence-state='online']"
           )
  end

  test "the call stage stays above Messages while the composer sends and receives", %{
    conn: conn,
    scope: scope
  } do
    friend = user_fixture()
    friend_scope = user_scope_fixture(friend)

    {:ok, %{relationship: request}} =
      Friendships.send_friend_request(scope, %{username: friend.username})

    {:ok, _} = Friendships.accept_friend_request(friend_scope, request.id)
    {:ok, conversation} = Chat.open_direct_conversation(scope, friend.id)
    {:ok, view, _} = live(conn, ~p"/direct-messages/#{conversation.id}")

    assert has_element?(
             view,
             "#direct-conversation-call-stage[phx-update='ignore'][data-direct-conversation-id='#{conversation.id}'] + #direct-message-surface"
           )

    assert has_element?(view, "#direct-conversation-call-stage[aria-label='Direct Call'][hidden]")
    assert has_element?(view, "#direct-message-form")
    assert has_element?(view, "#direct-messages-friends-link")

    view
    |> form("#direct-message-form", message: %{content: "Message during a call"})
    |> render_submit()

    assert {:ok, [message]} = Chat.list_direct_messages(scope, conversation.id)
    assert has_element?(view, "#direct-message-#{message.id}")

    assert {:ok, reply} =
             Chat.send_direct_message(friend_scope, conversation.id, %{
               content: "Reply during a call"
             })

    assert has_element?(view, "#direct-message-#{reply.id}")

    assert has_element?(
             view,
             "#direct-conversation-call-stage + #direct-message-surface #direct-message-form"
           )
  end

  test "non-participants receive the same not-found navigation as a missing Conversation", %{
    conn: _conn,
    scope: scope
  } do
    friend = user_fixture(username: "private_route_friend")
    friend_scope = user_scope_fixture(friend)
    outsider = user_fixture(username: "private_route_outsider")

    assert {:ok, %{relationship: request}} =
             Friendships.send_friend_request(scope, %{username: friend.username})

    assert {:ok, _friendship} = Friendships.accept_friend_request(friend_scope, request.id)
    assert {:ok, direct_conversation} = Chat.open_direct_conversation(scope, friend.id)

    outsider_conn = build_conn() |> log_in_user(outsider)

    assert {:error, {:live_redirect, %{to: "/friends"}}} =
             live(outsider_conn, ~p"/direct-messages/#{direct_conversation.id}")

    assert {:error, {:live_redirect, %{to: "/friends"}}} =
             live(outsider_conn, ~p"/direct-messages/#{Ecto.UUID.generate()}")
  end

  test "Direct Conversation routes require the established authenticated session", %{conn: _conn} do
    conn = Phoenix.ConnTest.build_conn()

    assert {:error, {:redirect, %{to: "/users/log-in"}}} =
             live(conn, ~p"/direct-messages/#{Ecto.UUID.generate()}")
  end

  test "current Friends exchange durable Direct Messages live in both sessions", %{
    conn: conn,
    user: user,
    scope: scope
  } do
    friend = user_fixture(username: "live_message_friend")
    friend_scope = user_scope_fixture(friend)

    assert {:ok, %{relationship: request}} =
             Friendships.send_friend_request(scope, %{username: friend.username})

    assert {:ok, _friendship} = Friendships.accept_friend_request(friend_scope, request.id)
    assert {:ok, direct_conversation} = Chat.open_direct_conversation(scope, friend.id)

    direct_path = ~p"/direct-messages/#{direct_conversation.id}"
    friend_conn = build_conn() |> log_in_user(friend)

    {:ok, sender_view, _html} = live(conn, direct_path)
    {:ok, recipient_view, _html} = live(friend_conn, direct_path)

    assert has_element?(sender_view, "#direct-message-form")
    assert has_element?(recipient_view, "#direct-message-form")

    sender_view
    |> form("#direct-message-form", message: %{content: "A durable hello"})
    |> render_submit()

    assert_eventually_has_message(sender_view, "A durable hello")
    assert_eventually_has_message(recipient_view, "A durable hello")

    assert {:ok, [message]} = Chat.list_direct_messages(scope, direct_conversation.id)
    assert has_element?(sender_view, "#direct-message-#{message.id}")
    assert has_element?(recipient_view, "#direct-message-#{message.id}")

    refute has_element?(
             sender_view,
             "#direct-message-#{message.id}[data-visible-read-observe='true']"
           )

    assert has_element?(
             recipient_view,
             "#direct-message-#{message.id}[data-visible-read-observe='true']"
           )

    Process.unlink(sender_view.pid)
    ref = Process.monitor(sender_view.pid)
    GenServer.stop(sender_view.pid)
    assert_receive {:DOWN, ^ref, :process, _pid, :normal}

    {:ok, reconnected_view, _html} = live(conn, direct_path)
    assert has_element?(reconnected_view, "#direct-message-#{message.id}")
    assert has_element?(reconnected_view, "#direct-message-#{message.id}", "A durable hello")

    assert user.id == message.user_id
  end

  test "blank Direct Message submissions are ignored without composer errors", %{
    conn: conn,
    scope: scope
  } do
    {_friend, _friend_scope, direct_conversation, direct_path, _friendship} =
      direct_conversation_fixture(scope, "live_blank_message")

    {:ok, view, _html} = live(conn, direct_path)

    view
    |> form("#direct-message-form", message: %{content: "   "})
    |> render_submit()

    assert {:ok, []} = Chat.list_direct_messages(scope, direct_conversation.id)
    refute has_element?(view, "#direct-message-form", "can't be blank")
  end

  test "the shared composer mention query does not disconnect a Direct Conversation", %{
    conn: conn,
    scope: scope
  } do
    {_friend, _friend_scope, _direct_conversation, direct_path, _friendship} =
      direct_conversation_fixture(scope, "mention_query")

    {:ok, view, _html} = live(conn, direct_path)

    render_hook(view, "mention_query", %{"before_cursor" => "", "after_cursor" => ""})

    assert has_element?(view, "#direct-message-form")
  end

  test "Direct Messages use the Workspace conversation surface and compact message rhythm", %{
    conn: conn,
    scope: scope
  } do
    {_friend, _friend_scope, direct_conversation, direct_path, _friendship} =
      direct_conversation_fixture(scope, "workspace_look")

    assert {:ok, first_message} =
             Chat.send_direct_message(scope, direct_conversation.id, %{content: "first line"})

    assert {:ok, second_message} =
             Chat.send_direct_message(scope, direct_conversation.id, %{content: "second line"})

    {:ok, view, _html} = live(conn, direct_path)

    assert has_element?(view, "#direct-message-surface")
    assert has_element?(view, "#direct-conversation-header")
    assert has_element?(view, "#direct-message-composer-panel")
    assert has_element?(view, "#direct-message-composer-shell")

    assert has_element?(
             view,
             "#direct-message-#{first_message.id}[data-message-row='full']"
           )

    assert has_element?(
             view,
             "#direct-message-#{second_message.id}[data-message-row='compact']"
           )
  end

  test "genuine visibility synchronizes Direct Message and Activity badges across sessions", %{
    conn: conn,
    user: user,
    scope: scope
  } do
    {_friend, friend_scope, direct_conversation, direct_path, _friendship} =
      direct_conversation_fixture(scope, "live_visibility")

    assert {:ok, _updated_count} = Chat.mark_all_activity_read(scope)

    assert {:ok, first_message} =
             Chat.send_direct_message(friend_scope, direct_conversation.id, %{content: "first"})

    assert {:ok, second_message} =
             Chat.send_direct_message(friend_scope, direct_conversation.id, %{content: "second"})

    second_conn = build_conn() |> log_in_user(user)
    {:ok, reading_view, _html} = live(conn, direct_path)
    {:ok, second_view, _html} = live(second_conn, direct_path)
    {:ok, activity_view, _html} = live(conn, ~p"/activity")
    {:ok, primary_activity_view, _html} = live(second_conn, ~p"/workspaces")

    first_item = Repo.get_by!(ActivityItem, source_message_id: first_message.id)
    second_item = Repo.get_by!(ActivityItem, source_message_id: second_message.id)

    assert has_element?(reading_view, "#direct-messages-unread-count", "2")
    assert has_element?(second_view, "#direct-conversation-unread-#{direct_conversation.id}", "2")
    assert has_element?(activity_view, "#global-activity-unread-count", "2")
    assert has_element?(primary_activity_view, "#activity-preview-item-#{first_item.id}")
    assert has_element?(primary_activity_view, "#activity-preview-item-#{second_item.id}")

    render_hook(reading_view, "visible_read_observed", %{
      "ranges" => [
        %{"from_seq" => first_message.seq, "to_seq" => second_message.seq}
      ]
    })

    refute has_element?(reading_view, "#direct-messages-unread-count")
    refute has_element?(second_view, "#direct-messages-unread-count")
    refute has_element?(second_view, "#direct-conversation-unread-#{direct_conversation.id}")
    refute has_element?(activity_view, "#global-activity-unread-count")
    refute has_element?(primary_activity_view, "#activity-preview-item-#{first_item.id}")
    refute has_element?(primary_activity_view, "#activity-preview-item-#{second_item.id}")

    assert has_element?(activity_view, "#activity-item-#{first_item.id}[data-read-state='read']")
    assert has_element?(activity_view, "#activity-item-#{second_item.id}[data-read-state='read']")
  end

  test "current Friends reply and both sessions share author deletion placeholders", %{
    conn: conn,
    scope: scope
  } do
    {friend, friend_scope, direct_conversation, direct_path, _friendship} =
      direct_conversation_fixture(scope, "live_reply")

    assert {:ok, parent} =
             Chat.send_direct_message(scope, direct_conversation.id, %{content: "reply target"})

    friend_conn = build_conn() |> log_in_user(friend)
    {:ok, author_view, _html} = live(conn, direct_path)
    {:ok, friend_view, _html} = live(friend_conn, direct_path)

    assert {:ok, stale_target} =
             Chat.send_direct_message(scope, direct_conversation.id, %{content: "stale target"})

    assert {:ok, _deleted_stale_target} = Chat.delete_message(scope, stale_target.id)

    render_click(author_view, "begin_direct_reply", %{"message-id" => stale_target.id})
    refute has_element?(author_view, "#direct-message-reply-target")
    assert has_element?(author_view, "#flash-error", "no longer available")

    author_view |> element("#direct-message-#{parent.id}-reply") |> render_click()

    assert has_element?(
             author_view,
             "#direct-message-reply-target[data-message-id='#{parent.id}']"
           )

    author_view
    |> form("#direct-message-form", message: %{content: "flat reply"})
    |> render_submit()

    assert {:ok, messages} = Chat.list_direct_messages(friend_scope, direct_conversation.id)
    reply = List.last(messages)

    assert reply.reply_to_message_id == parent.id
    assert_eventually_has_element(friend_view, "#direct-message-#{reply.id}-reply-preview")

    author_view |> element("#direct-message-#{parent.id}-delete") |> render_click()

    assert_eventually_has_element(author_view, "#direct-message-#{parent.id}-deleted")
    assert_eventually_has_element(friend_view, "#direct-message-#{parent.id}-deleted")
    refute has_element?(friend_view, "#direct-message-#{parent.id}", "reply target")

    render_click(author_view, "delete_direct_message", %{"message-id" => parent.id})
    assert has_element?(author_view, "#flash-error", "could not be deleted")

    assert_eventually_has_element(
      friend_view,
      "#direct-message-#{reply.id}-deleted-reply-preview"
    )

    refute has_element?(friend_view, "#direct-message-#{reply.id}-reply-preview", "reply target")
  end

  test "reactions synchronize and former Friends retain only cleanup controls", %{
    conn: conn,
    scope: scope
  } do
    {friend, friend_scope, direct_conversation, direct_path, friendship} =
      direct_conversation_fixture(scope, "live_reaction")

    assert {:ok, own_message} =
             Chat.send_direct_message(scope, direct_conversation.id, %{content: "react here"})

    assert {:ok, friend_message} =
             Chat.send_direct_message(friend_scope, direct_conversation.id, %{content: "cleanup"})

    friend_conn = build_conn() |> log_in_user(friend)
    {:ok, first_view, _html} = live(conn, direct_path)
    {:ok, second_view, _html} = live(friend_conn, direct_path)

    first_view
    |> element("#direct-message-#{own_message.id}-reaction-option-0")
    |> render_click()

    assert_eventually_has_element(
      second_view,
      "#direct-message-#{own_message.id}-reaction-0[data-current-user-reacted='false']"
    )

    second_view
    |> element("#direct-message-#{friend_message.id}-reaction-option-0")
    |> render_click()

    assert :ok = Friendships.remove_friend(friend_scope, friendship.id)
    _ = render(first_view)
    _ = render(second_view)

    assert_eventually_has_element(first_view, "#direct-conversation-read-only")
    refute has_element?(first_view, "#direct-conversation-presence-#{friend.id}")
    refute has_element?(first_view, "#direct-message-form")
    refute has_element?(first_view, "#direct-message-#{own_message.id}-reply")
    refute has_element?(first_view, "#direct-message-#{own_message.id}-reaction-option-0")
    assert has_element?(first_view, "#direct-message-#{own_message.id}-delete")

    assert has_element?(second_view, "#direct-message-#{friend_message.id}-reaction-0")

    second_view
    |> element("#direct-message-#{friend_message.id}-reaction-0")
    |> render_click()

    assert_eventually_lacks_element(first_view, "#direct-message-#{friend_message.id}-reaction-0")
    assert has_element?(second_view, "#direct-message-#{friend_message.id}-delete")
  end

  test "open sessions preserve drafts and restore live capabilities in the same Conversation", %{
    conn: conn,
    scope: scope
  } do
    {friend, friend_scope, direct_conversation, direct_path, friendship} =
      direct_conversation_fixture(scope, "capability")

    assert {:ok, existing_message} =
             Chat.send_direct_message(scope, direct_conversation.id, %{content: "kept history"})

    friend_conn = build_conn() |> log_in_user(friend)
    {:ok, current_user_view, _html} = live(conn, direct_path)
    {:ok, friend_view, _html} = live(friend_conn, direct_path)

    current_user_view
    |> form("#direct-message-form", message: %{content: "unsent draft"})
    |> render_change()

    friend_view
    |> form("#direct-message-form", message: %{content: "typing before removal"})
    |> render_change()

    assert_eventually_has_element(current_user_view, "#direct-typing-indicator")
    assert :ok = Friendships.remove_friend(friend_scope, friendship.id)

    assert_eventually_has_element(current_user_view, "#direct-conversation-read-only")
    assert_eventually_has_element(friend_view, "#direct-conversation-read-only")

    assert has_element?(
             current_user_view,
             "#direct-message-#{existing_message.id}",
             "kept history"
           )

    refute has_element?(current_user_view, "#direct-typing-indicator")
    refute has_element?(current_user_view, "#direct-conversation-presence-#{friend.id}")

    assert {:ok, []} = Chat.list_direct_typing_user_ids(scope, direct_conversation.id)

    assert has_element?(current_user_view, "#direct-conversation-send-friend-request")

    current_user_view
    |> element("#direct-conversation-send-friend-request")
    |> render_click()

    assert_eventually_has_element(
      current_user_view,
      "#direct-conversation-friend-request-pending"
    )

    assert_eventually_has_element(friend_view, "#direct-conversation-send-friend-request")

    friend_view
    |> element("#direct-conversation-send-friend-request")
    |> render_click()

    assert_eventually_has_element(current_user_view, "#direct-message-form")
    assert_eventually_has_element(friend_view, "#direct-message-form")

    assert has_element?(
             current_user_view,
             "#direct-message-form input[name='message[content]'][value='unsent draft']"
           )

    assert has_element?(
             current_user_view,
             "#direct-conversation-presence-#{friend.id}[data-presence-state='online']"
           )

    assert has_element?(
             current_user_view,
             "#direct-conversation-entry-#{direct_conversation.id}[data-writable='true']"
           )

    current_user_view
    |> form("#direct-message-form", message: %{content: "unsent draft"})
    |> render_submit()

    assert_eventually_has_message(friend_view, "unsent draft")

    current_user_view
    |> element("#direct-message-#{existing_message.id}-reply")
    |> render_click()

    current_user_view
    |> form("#direct-message-form", message: %{content: "reply restored"})
    |> render_submit()

    assert_eventually_has_message(friend_view, "reply restored")

    current_user_view
    |> element("#direct-message-#{existing_message.id}-reaction-option-0")
    |> render_click()

    assert_eventually_has_element(
      friend_view,
      "#direct-message-#{existing_message.id}-reaction-0"
    )

    friend_view
    |> form("#direct-message-form", message: %{content: "typing restored"})
    |> render_change()

    assert_eventually_has_element(current_user_view, "#direct-typing-indicator")

    assert {:ok, messages} = Chat.list_direct_messages(scope, direct_conversation.id)
    restored_reply = Enum.find(messages, &(&1.content == "reply restored"))
    assert restored_reply.reply_to_message_id == existing_message.id

    assert {:ok, same_conversation} = Chat.find_direct_conversation(scope, friend.id)
    assert same_conversation.id == direct_conversation.id
  end

  test "former Friends reject forged mutations but retain authorized ownership cleanup", %{
    conn: conn,
    scope: scope
  } do
    {_friend, friend_scope, direct_conversation, direct_path, friendship} =
      direct_conversation_fixture(scope, "stale_capability")

    assert {:ok, own_message} =
             Chat.send_direct_message(scope, direct_conversation.id, %{content: "owned cleanup"})

    assert {:ok, friend_message} =
             Chat.send_direct_message(friend_scope, direct_conversation.id, %{
               content: "forged target"
             })

    assert {:ok, _reaction} = Chat.toggle_reaction(scope, friend_message.id, "👍")

    {:ok, view, _html} = live(conn, direct_path)
    assert :ok = Friendships.remove_friend(friend_scope, friendship.id)
    assert_eventually_has_element(view, "#direct-conversation-read-only")

    render_submit(view, "send_direct_message", %{
      "message" => %{"content" => "must not persist"}
    })

    render_click(view, "begin_direct_reply", %{"message-id" => friend_message.id})

    render_click(view, "toggle_direct_reaction", %{
      "message-id" => friend_message.id,
      "emoji" => "🎉"
    })

    render_change(view, "message_typing", %{
      "message" => %{"content" => "must not type"}
    })

    assert {:ok, messages} = Chat.list_direct_messages(scope, direct_conversation.id)
    refute Enum.any?(messages, &(&1.content == "must not persist"))
    refute has_element?(view, "#direct-message-reply-target")
    assert {:ok, []} = Chat.list_direct_typing_user_ids(scope, direct_conversation.id)

    assert {:ok, summaries} = Chat.list_reaction_summaries(scope, [friend_message.id])
    refute Enum.any?(summaries[friend_message.id], &(&1.emoji == "🎉"))

    view
    |> element("#direct-message-#{friend_message.id}-reaction-0")
    |> render_click()

    assert_eventually_lacks_element(view, "#direct-message-#{friend_message.id}-reaction-0")

    view
    |> element("#direct-message-#{own_message.id}-delete")
    |> render_click()

    assert_eventually_has_element(view, "#direct-message-#{own_message.id}-deleted")
  end

  test "loads bounded Direct Message history and navigates to an authorized target", %{
    conn: conn,
    scope: scope
  } do
    {_friend, _friend_scope, direct_conversation, direct_path, _friendship} =
      direct_conversation_fixture(scope, "live_history")

    messages =
      for index <- 1..75 do
        assert {:ok, message} =
                 Chat.send_direct_message(scope, direct_conversation.id, %{
                   content: "history #{index}"
                 })

        message
      end

    first = List.first(messages)
    target = Enum.at(messages, 19)
    latest = List.last(messages)

    {:ok, latest_view, _html} = live(conn, direct_path)
    refute has_element?(latest_view, "#direct-message-#{first.id}")
    assert has_element?(latest_view, "#direct-message-#{latest.id}")
    assert has_element?(latest_view, "#direct-messages[data-has-older-messages='true']")

    render_hook(latest_view, "scroll_anchor_observed", %{"seq" => latest.seq})
    render_hook(latest_view, "visible_read_observed", %{"ranges" => []})

    assert has_element?(latest_view, "#direct-message-#{latest.id}")

    render_hook(latest_view, "load_older_messages", %{})
    assert has_element?(latest_view, "#direct-message-#{first.id}")
    assert has_element?(latest_view, "#direct-messages[data-has-older-messages='false']")

    {:ok, target_view, _html} = live(conn, direct_path <> "?message_id=#{target.id}")

    assert has_element?(
             target_view,
             "#direct-message-#{target.id}[data-message-navigation-target='true']"
           )

    refute has_element?(target_view, "#direct-message-#{latest.id}")
    assert has_element?(target_view, "#direct-messages[data-has-newer-messages='true']")

    render_hook(target_view, "load_newer_messages", %{})
    assert has_element?(target_view, "#direct-message-#{latest.id}")
    assert has_element?(target_view, "#direct-messages[data-has-newer-messages='false']")
  end

  test "current Friends see typing stop and runtime loss clears ephemeral state", %{
    conn: conn,
    scope: scope
  } do
    {friend, friend_scope, direct_conversation, direct_path, _friendship} =
      direct_conversation_fixture(scope, "live_typing")

    friend_conn = build_conn() |> log_in_user(friend)
    {:ok, sender_view, _html} = live(conn, direct_path)
    {:ok, recipient_view, _html} = live(friend_conn, direct_path)

    sender_view
    |> form("#direct-message-form", message: %{content: "typing"})
    |> render_change()

    assert_eventually_has_element(
      recipient_view,
      "#direct-typing-indicator [data-typing-user-id='#{scope.user.id}']"
    )

    sender_view
    |> form("#direct-message-form", message: %{content: " "})
    |> render_change()

    assert_eventually_lacks_element(
      recipient_view,
      "#direct-typing-indicator [data-typing-user-id='#{scope.user.id}']"
    )

    sender_view
    |> form("#direct-message-form", message: %{content: "typing again"})
    |> render_change()

    assert_eventually_has_element(
      recipient_view,
      "#direct-typing-indicator [data-typing-user-id='#{scope.user.id}']"
    )

    runtime_pid = Runtime.conversation_pid(direct_conversation.id)
    runtime_ref = Process.monitor(runtime_pid)
    Process.exit(runtime_pid, :kill)
    assert_receive {:DOWN, ^runtime_ref, :process, ^runtime_pid, :killed}

    assert_eventually_lacks_element(
      recipient_view,
      "#direct-typing-indicator [data-typing-user-id='#{scope.user.id}']"
    )

    assert {:ok, []} = Chat.list_direct_typing_user_ids(friend_scope, direct_conversation.id)
  end

  test "reopens durable recent Direct Messages after runtime loss", %{conn: conn, scope: scope} do
    {_friend, _friend_scope, direct_conversation, direct_path, _friendship} =
      direct_conversation_fixture(scope, "live_recovery")

    assert {:ok, message} =
             Chat.send_direct_message(scope, direct_conversation.id, %{
               content: "survives restart"
             })

    assert {:ok, runtime_pid} =
             Chat.ensure_direct_conversation_runtime(scope, direct_conversation.id)

    runtime_ref = Process.monitor(runtime_pid)
    Process.exit(runtime_pid, :kill)
    assert_receive {:DOWN, ^runtime_ref, :process, ^runtime_pid, :killed}

    {:ok, view, _html} = live(conn, direct_path)
    assert has_element?(view, "#direct-message-#{message.id}", "survives restart")

    restarted_pid = Runtime.conversation_pid(direct_conversation.id)
    assert is_pid(restarted_pid)
    assert restarted_pid != runtime_pid
  end

  test "current Friends get an enabled Start voice call action with authorized display metadata",
       %{
         conn: conn,
         scope: scope
       } do
    {friend, _friend_scope, direct_conversation, direct_path, _friendship} =
      direct_conversation_fixture(scope, "voice_call_header")

    {:ok, view, _html} = live(conn, direct_path)

    assert has_element?(view, "#direct-conversation-header")
    assert has_element?(view, "#direct-conversation-start-voice-call")

    assert has_element?(
             view,
             "#direct-conversation-start-voice-call[data-call-action='start-audio']"
           )

    assert has_element?(
             view,
             "#direct-conversation-start-voice-call[data-direct-conversation-id='#{direct_conversation.id}']"
           )

    assert has_element?(
             view,
             "#direct-conversation-start-voice-call[data-peer-id='#{friend.id}']"
           )

    assert has_element?(
             view,
             "#direct-conversation-start-voice-call[data-peer-username='#{friend.username}']"
           )

    assert has_element?(
             view,
             "#direct-conversation-start-voice-call[aria-label='Start voice call with #{friend.username}']"
           )

    refute has_element?(view, "#direct-conversation-start-voice-call[aria-disabled='true']")
    refute has_element?(view, "#direct-conversation-start-voice-call[disabled]")
    refute has_element?(view, "#direct-conversation-start-voice-call[phx-click]")
    refute has_element?(view, "#direct-conversation-call-unavailable-reason")
    refute has_element?(view, "#direct-conversation-start-voice-call[data-peer-email]")

    assert has_element?(view, "#direct-conversation-start-video-call")

    assert has_element?(
             view,
             "#direct-conversation-start-video-call[data-call-action='start-video']"
           )

    assert has_element?(
             view,
             "#direct-conversation-start-video-call[data-direct-conversation-id='#{direct_conversation.id}']"
           )

    assert has_element?(
             view,
             "#direct-conversation-start-video-call[data-peer-id='#{friend.id}']"
           )

    assert has_element?(
             view,
             "#direct-conversation-start-video-call[data-peer-username='#{friend.username}']"
           )

    assert has_element?(
             view,
             "#direct-conversation-start-video-call[aria-label='Start video call with #{friend.username}']"
           )

    refute has_element?(view, "#direct-conversation-start-video-call[aria-disabled='true']")
    refute has_element?(view, "#direct-conversation-start-video-call[disabled]")
    refute has_element?(view, "#direct-conversation-start-video-call[phx-click]")
    refute has_element?(view, "#direct-conversation-start-video-call[data-peer-email]")
  end

  test "former Friends keep the voice call action focusable, explained, and inert", %{
    conn: conn,
    scope: scope
  } do
    {friend, friend_scope, direct_conversation, direct_path, friendship} =
      direct_conversation_fixture(scope, "voice_call_former")

    {:ok, view, _html} = live(conn, direct_path)
    assert :ok = Friendships.remove_friend(friend_scope, friendship.id)
    assert_eventually_has_element(view, "#direct-conversation-read-only")

    assert has_element?(view, "#direct-conversation-header")
    assert has_element?(view, "#direct-conversation-start-voice-call")

    assert has_element?(
             view,
             "#direct-conversation-start-voice-call[aria-disabled='true']"
           )

    assert has_element?(
             view,
             "#direct-conversation-start-voice-call[aria-describedby='direct-conversation-call-unavailable-reason']"
           )

    assert has_element?(
             view,
             "#direct-conversation-call-unavailable-reason",
             "Calls require a current Friendship."
           )

    assert has_element?(
             view,
             "#direct-conversation-start-voice-call[data-direct-conversation-id='#{direct_conversation.id}']"
           )

    assert has_element?(
             view,
             "#direct-conversation-start-voice-call[data-peer-id='#{friend.id}']"
           )

    refute has_element?(view, "#direct-conversation-start-voice-call[disabled]")
    refute has_element?(view, "#direct-conversation-start-voice-call[phx-click]")

    assert has_element?(view, "#direct-conversation-start-video-call")

    assert has_element?(
             view,
             "#direct-conversation-start-video-call[aria-disabled='true']"
           )

    assert has_element?(
             view,
             "#direct-conversation-start-video-call[aria-describedby='direct-conversation-call-unavailable-reason']"
           )

    assert has_element?(
             view,
             "#direct-conversation-start-video-call[data-direct-conversation-id='#{direct_conversation.id}']"
           )

    assert has_element?(
             view,
             "#direct-conversation-start-video-call[data-peer-id='#{friend.id}']"
           )

    refute has_element?(view, "#direct-conversation-start-video-call[disabled]")
    refute has_element?(view, "#direct-conversation-start-video-call[phx-click]")
  end

  test "operational off explains unavailable video despite browser query claims", %{
    conn: conn,
    scope: scope
  } do
    previous =
      for key <- [:direct_call_transport, :direct_call_camera_lifecycle_enabled],
          do: {key, Application.fetch_env(:discord_clone, key)}

    Application.delete_env(:discord_clone, :direct_call_transport)
    Application.put_env(:discord_clone, :direct_call_camera_lifecycle_enabled, false)

    on_exit(fn ->
      for {key, value} <- previous do
        case value do
          {:ok, value} -> Application.put_env(:discord_clone, key, value)
          :error -> Application.delete_env(:discord_clone, key)
        end
      end
    end)

    {_friend, _friend_scope, _conversation, path, _friendship} =
      direct_conversation_fixture(scope, "real_video_action")

    document =
      conn
      |> get(path <> "?camera_enabled=true&video_available=true")
      |> html_response(200)
      |> LazyHTML.from_fragment()

    assert LazyHTML.attribute(
             LazyHTML.query(document, "#call-signaling-bootstrap"),
             "data-call-devices"
           ) == ["real"]

    assert LazyHTML.attribute(
             LazyHTML.query(document, "#call-signaling-bootstrap"),
             "data-call-video-available"
           ) == ["false"]

    {:ok, view, _html} = live(conn, path)
    assert has_element?(view, "#direct-conversation-start-video-call[aria-disabled='true']")

    assert has_element?(
             view,
             "#direct-conversation-start-video-call[aria-describedby='direct-conversation-video-unavailable-reason']"
           )

    assert has_element?(view, "#direct-conversation-video-unavailable-reason")
    refute has_element?(view, "#direct-conversation-start-video-call[disabled]")
    refute has_element?(view, "#direct-conversation-start-voice-call[aria-disabled='true']")
  end

  test "shipping video default projects availability to bootstrap and authenticated conversation",
       %{conn: conn, scope: scope} do
    previous =
      for key <- [:direct_call_transport, :direct_call_camera_lifecycle_enabled],
          do: {key, Application.fetch_env(:discord_clone, key)}

    Application.put_env(:discord_clone, :direct_call_transport, :real)

    on_exit(fn ->
      for {key, value} <- previous do
        case value do
          {:ok, value} -> Application.put_env(:discord_clone, key, value)
          :error -> Application.delete_env(:discord_clone, key)
        end
      end
    end)

    {_friend, _friend_scope, _conversation, path, _friendship} =
      direct_conversation_fixture(scope, "camera_policy")

    document = conn |> get(path) |> html_response(200) |> LazyHTML.from_fragment()
    marker = LazyHTML.query(document, "#call-signaling-bootstrap")
    assert LazyHTML.attribute(marker, "data-call-devices") == ["real"]
    assert LazyHTML.attribute(marker, "data-call-video-available") == ["true"]

    assert LazyHTML.query(document, "#direct-call-incoming-accept-video[aria-describedby]")
           |> Enum.empty?()

    {:ok, view, _html} = live(conn, path)
    refute has_element?(view, "#direct-conversation-start-video-call[aria-disabled='true']")
    refute has_element?(view, "#direct-conversation-video-unavailable-reason")
  end

  defp assert_eventually_has_message(view, content, attempts \\ 10)

  defp assert_eventually_has_message(view, content, attempts) when attempts > 0 do
    if has_element?(view, "[data-direct-message-content]", content) do
      :ok
    else
      _ = render(view)
      assert_eventually_has_message(view, content, attempts - 1)
    end
  end

  defp assert_eventually_has_message(_view, content, 0) do
    flunk("expected Direct Message content #{inspect(content)}")
  end

  defp assert_eventually_has_element(view, selector, attempts \\ 10)

  defp assert_eventually_has_element(view, selector, attempts) when attempts > 0 do
    if has_element?(view, selector) do
      :ok
    else
      _ = render(view)
      assert_eventually_has_element(view, selector, attempts - 1)
    end
  end

  defp assert_eventually_has_element(_view, selector, 0) do
    flunk("expected element #{selector}")
  end

  defp assert_eventually_lacks_element(view, selector, attempts \\ 10)

  defp assert_eventually_lacks_element(view, selector, attempts) when attempts > 0 do
    if has_element?(view, selector) do
      _ = render(view)
      assert_eventually_lacks_element(view, selector, attempts - 1)
    else
      :ok
    end
  end

  defp assert_eventually_lacks_element(_view, selector, 0) do
    flunk("expected element #{selector} to disappear")
  end

  defp direct_conversation_fixture(scope, suffix) do
    friend = user_fixture(username: "#{suffix}_friend")
    friend_scope = user_scope_fixture(friend)

    assert {:ok, %{relationship: request}} =
             Friendships.send_friend_request(scope, %{username: friend.username})

    assert {:ok, friendship} = Friendships.accept_friend_request(friend_scope, request.id)
    assert {:ok, direct_conversation} = Chat.open_direct_conversation(scope, friend.id)
    direct_path = ~p"/direct-messages/#{direct_conversation.id}"

    {friend, friend_scope, direct_conversation, direct_path, friendship}
  end
end
