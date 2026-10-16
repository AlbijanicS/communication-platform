defmodule DiscordCloneWeb.ActivityLiveTest do
  use DiscordCloneWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import DiscordClone.CallsFixtures
  import DiscordCloneWeb.WorkspaceLiveTestHelpers, only: [add_workspace_member!: 2]

  alias DiscordClone.Activities.ActivityItem
  alias DiscordClone.Calls
  alias DiscordClone.Chat
  alias DiscordClone.Friendships
  alias DiscordClone.Repo
  alias DiscordClone.Workspaces

  describe "authenticated Activity Feed" do
    test "redirects unauthenticated users to log in", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(conn, ~p"/activity")
    end

    test "renders the stable empty feed and linked global bell", %{conn: conn} do
      recipient = DiscordClone.AccountsFixtures.user_fixture()
      recipient_conn = log_in_user(conn, recipient)

      {:ok, view, _html} = live(recipient_conn, ~p"/activity")

      assert has_element?(view, "#global-activity-bell[href='/activity']")
      assert has_element?(view, "#activity-feed")
      assert has_element?(view, "#activity-feed-empty-state")
      refute has_element?(view, "#activity-feed > article")
    end

    test "renders and opens an incoming Friend Request without resolving it", %{conn: conn} do
      recipient_scope = DiscordClone.AccountsFixtures.user_scope_fixture()
      recipient_conn = log_in_user(conn, recipient_scope.user)
      requester_scope = DiscordClone.AccountsFixtures.user_scope_fixture()

      assert {:ok, %{relationship: request}} =
               Friendships.send_friend_request(requester_scope, %{
                 username: recipient_scope.user.username
               })

      item = Repo.get_by!(ActivityItem, source_friend_relationship_id: request.id)
      {:ok, view, _html} = live(recipient_conn, ~p"/activity")

      assert has_element?(
               view,
               "#activity-item-#{item.id}[data-source-kind='friend-relationship'][data-read-state='unread']"
             )

      assert has_element?(
               view,
               "#activity-item-#{item.id} [data-role='actor']",
               requester_scope.user.username
             )

      assert has_element?(
               view,
               "#activity-item-#{item.id} [data-role='kind']",
               "Sent you a Friend Request"
             )

      view
      |> element("#activity-item-#{item.id}-open")
      |> render_click()

      assert_redirect(view, "/friends#incoming-requests")
      assert %DateTime{} = Repo.reload!(item).read_at

      assert {:ok, [%{relationship: pending}]} =
               Friendships.list_incoming_requests(recipient_scope)

      assert pending.id == request.id
    end

    test "retains accepted Friend Request Activity in history and navigates to Friends", %{
      conn: conn
    } do
      requester_scope = DiscordClone.AccountsFixtures.user_scope_fixture()
      requester_conn = log_in_user(conn, requester_scope.user)
      recipient_scope = DiscordClone.AccountsFixtures.user_scope_fixture()

      assert {:ok, %{relationship: request}} =
               Friendships.send_friend_request(requester_scope, %{
                 username: recipient_scope.user.username
               })

      assert {:ok, friendship} =
               Friendships.accept_friend_request(recipient_scope, request.id)

      item =
        Repo.get_by!(ActivityItem,
          source_friend_relationship_id: friendship.id,
          recipient_user_id: requester_scope.user.id
        )

      assert {:ok, _destination} = Chat.open_activity_item(requester_scope, item.id)
      {:ok, view, _html} = live(requester_conn, ~p"/activity")

      assert has_element?(
               view,
               "#activity-item-#{item.id}[data-source-kind='friend-relationship'][data-read-state='read']"
             )

      assert has_element?(
               view,
               "#activity-item-#{item.id} [data-role='kind']",
               "Accepted your Friend Request"
             )

      view
      |> element("#activity-item-#{item.id}-open")
      |> render_click()

      assert_redirect(view, "/friends#friends-list")

      assert {:ok, [%{relationship: listed_friendship}]} =
               Friendships.list_friends(requester_scope)

      assert listed_friendship.id == friendship.id
    end

    test "shows only the user's feed with current labels and previews newest first", %{
      conn: conn
    } do
      recipient_scope = DiscordClone.AccountsFixtures.user_scope_fixture()
      recipient_conn = log_in_user(conn, recipient_scope.user)
      other_scope = DiscordClone.AccountsFixtures.user_scope_fixture()
      first_author_scope = DiscordClone.AccountsFixtures.user_scope_fixture()
      second_author_scope = DiscordClone.AccountsFixtures.user_scope_fixture()

      {:ok, first_workspace} =
        Workspaces.create_workspace(first_author_scope, %{name: "Old First Name"})

      {:ok, second_workspace} =
        Workspaces.create_workspace(second_author_scope, %{name: "Second Workspace"})

      add_workspace_member!(first_workspace, recipient_scope)
      add_workspace_member!(first_workspace, other_scope)
      add_workspace_member!(second_workspace, recipient_scope)

      assert {:ok, first_message} =
               Chat.send_message(first_author_scope, first_workspace.default_channel_id, %{
                 content: "older source preview @#{recipient_scope.user.username}"
               })

      assert {:ok, second_message} =
               Chat.send_message(second_author_scope, second_workspace.default_channel_id, %{
                 content: "newer source preview @#{recipient_scope.user.username}"
               })

      assert {:ok, other_message} =
               Chat.send_message(first_author_scope, first_workspace.default_channel_id, %{
                 content: "other user's private preview @#{other_scope.user.username}"
               })

      first_item = activity_item_for_message!(first_message.id)
      second_item = activity_item_for_message!(second_message.id)
      other_item = activity_item_for_message!(other_message.id)

      set_activity_time!(first_item, ~U[2026-07-15 09:00:00.000000Z])
      set_activity_time!(second_item, ~U[2026-07-15 10:00:00.000000Z])

      assert {:ok, _renamed_workspace} =
               Workspaces.rename_workspace(first_author_scope, first_workspace.id, %{
                 name: "Current First Name"
               })

      assert {:ok, _renamed_channel} =
               Workspaces.rename_channel(
                 first_author_scope,
                 first_workspace.id,
                 first_workspace.default_channel_id,
                 %{name: "current-channel"}
               )

      Repo.update_all(
        from(activity_item in ActivityItem, where: activity_item.id == ^first_item.id),
        set: [actor_user_id: nil]
      )

      {:ok, view, _html} = live(recipient_conn, ~p"/activity")

      assert activity_row_ids(view) == [
               "activity-item-#{second_item.id}",
               "activity-item-#{first_item.id}"
             ]

      assert has_element?(
               view,
               "#activity-item-#{first_item.id} [data-role='workspace']",
               "Current First Name"
             )

      assert has_element?(
               view,
               "#activity-item-#{first_item.id} [data-role='channel']",
               "#current-channel"
             )

      assert has_element?(
               view,
               "#activity-item-#{first_item.id} [data-role='actor']",
               "Former member"
             )

      assert has_element?(
               view,
               "#activity-item-#{second_item.id} [data-role='actor']",
               second_author_scope.user.username
             )

      assert has_element?(
               view,
               "#activity-item-#{first_item.id} [data-role='kind']",
               "Direct mention"
             )

      assert has_element?(
               view,
               "#activity-item-#{first_item.id} [data-role='preview']",
               first_message.content
             )

      assert has_element?(
               view,
               "#activity-item-#{second_item.id} [data-role='preview']",
               second_message.content
             )

      refute has_element?(view, "#activity-item-#{other_item.id}")
      assert {:ok, 2} = Chat.unread_activity_count(recipient_scope)
      assert is_nil(Repo.get!(ActivityItem, first_item.id).read_at)
      assert is_nil(Repo.get!(ActivityItem, second_item.id).read_at)
    end

    test "streams an initial 50 items and loads the remaining older page", %{conn: conn} do
      recipient_scope = DiscordClone.AccountsFixtures.user_scope_fixture()
      recipient_conn = log_in_user(conn, recipient_scope.user)
      author_scope = DiscordClone.AccountsFixtures.user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(author_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, recipient_scope)

      first_fifty_item_ids =
        for index <- 1..50 do
          assert {:ok, message} =
                   Chat.send_message(author_scope, workspace.default_channel_id, %{
                     content: "paged request #{index} @#{recipient_scope.user.username}"
                   })

          activity_item_for_message!(message.id).id
        end

      {:ok, boundary_view, _html} = live(recipient_conn, ~p"/activity")

      assert length(activity_row_ids(boundary_view)) == 50
      refute has_element?(boundary_view, "#activity-load-older")

      two_older_item_ids =
        for index <- 51..52 do
          assert {:ok, message} =
                   Chat.send_message(author_scope, workspace.default_channel_id, %{
                     content: "paged request #{index} @#{recipient_scope.user.username}"
                   })

          activity_item_for_message!(message.id).id
        end

      item_ids = first_fifty_item_ids ++ two_older_item_ids
      {:ok, view, _html} = live(recipient_conn, ~p"/activity")

      assert length(activity_row_ids(view)) == 50
      assert has_element?(view, "#activity-load-older", "Load older activity")

      view
      |> element("#activity-load-older")
      |> render_click()

      assert length(activity_row_ids(view)) == 52

      assert MapSet.new(activity_row_ids(view)) ==
               MapSet.new(Enum.map(item_ids, &"activity-item-#{&1}"))

      refute has_element?(view, "#activity-load-older")

      view
      |> element("#activity-mark-all-read")
      |> render_click()

      assert length(activity_row_ids(view)) == 52
      refute has_element?(view, "#activity-feed > article[data-read-state='unread']")
    end

    test "styles read items and marks the current feed read without changing the route", %{
      conn: conn
    } do
      recipient_scope = DiscordClone.AccountsFixtures.user_scope_fixture()
      recipient_conn = log_in_user(conn, recipient_scope.user)
      author_scope = DiscordClone.AccountsFixtures.user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(author_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, recipient_scope)

      assert {:ok, first_message} =
               Chat.send_message(author_scope, workspace.default_channel_id, %{
                 content: "handled @#{recipient_scope.user.username}"
               })

      assert {:ok, second_message} =
               Chat.send_message(author_scope, workspace.default_channel_id, %{
                 content: "waiting @#{recipient_scope.user.username}"
               })

      first_item = activity_item_for_message!(first_message.id)
      second_item = activity_item_for_message!(second_message.id)
      assert {:ok, _destination} = Chat.open_activity_item(recipient_scope, first_item.id)

      {:ok, view, _html} = live(recipient_conn, ~p"/activity")

      assert has_element?(
               view,
               "#activity-item-#{first_item.id}[data-read-state='read']"
             )

      assert has_element?(
               view,
               "#activity-item-#{second_item.id}[data-read-state='unread']"
             )

      assert has_element?(view, "#activity-mark-all-read:not([disabled])", "Mark all as read")

      view
      |> element("#activity-mark-all-read")
      |> render_click()

      refute has_element?(view, "#global-activity-unread-count")
      assert has_element?(view, "#activity-mark-all-read[disabled]", "Mark all as read")
      assert has_element?(view, "#activity-item-#{first_item.id}[data-read-state='read']")
      assert has_element?(view, "#activity-item-#{second_item.id}[data-read-state='read']")
      refute has_element?(view, "#activity-feed > article[data-read-state='unread']")
    end

    test "opens an out-of-window source, marks only that item read, and refreshes the bell", %{
      conn: conn
    } do
      recipient_scope = DiscordClone.AccountsFixtures.user_scope_fixture()
      recipient_conn = log_in_user(conn, recipient_scope.user)
      author_scope = DiscordClone.AccountsFixtures.user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(author_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, recipient_scope)

      assert {:ok, source_message} =
               Chat.send_message(author_scope, workspace.default_channel_id, %{
                 content: "distant request @#{recipient_scope.user.username}"
               })

      assert {:ok, remaining_message} =
               Chat.send_message(author_scope, workspace.default_channel_id, %{
                 content: "remaining request @#{recipient_scope.user.username}"
               })

      for index <- 1..55 do
        assert {:ok, _message} =
                 Chat.send_message(author_scope, workspace.default_channel_id, %{
                   content: "filler #{index}"
                 })
      end

      source_item = activity_item_for_message!(source_message.id)
      remaining_item = activity_item_for_message!(remaining_message.id)
      {:ok, activity_view, _html} = live(recipient_conn, ~p"/activity")

      destination =
        ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}?message_id=#{source_message.id}"

      {:ok, channel_view, _html} =
        activity_view
        |> element("#activity-item-#{source_item.id}-open")
        |> render_click()
        |> follow_redirect(recipient_conn, destination)

      assert %DateTime{} = Repo.get!(ActivityItem, source_item.id).read_at
      assert is_nil(Repo.get!(ActivityItem, remaining_item.id).read_at)
      assert {:ok, 1} = Chat.unread_activity_count(recipient_scope)
      assert has_element?(channel_view, "#global-activity-unread-count", "1")

      assert has_element?(
               channel_view,
               "#message-#{source_message.id}[data-message-navigation-target='true'].message-target-highlight"
             )

      assert has_element?(
               channel_view,
               "#channel-messages[data-scroll-target-kind='sequence'][data-scroll-target-seq='#{source_message.seq}']"
             )
    end

    test "renders a missed Direct Call and opens the Direct Conversation without a Message", %{
      conn: conn
    } do
      start_supervised!(DiscordClone.Calls.Supervisor)
      DiscordClone.Calls.CallCoordinator.begin_recovery()
      await_recovery_finished()

      caller_scope = DiscordClone.AccountsFixtures.user_scope_fixture()
      recipient_scope = DiscordClone.AccountsFixtures.user_scope_fixture()
      recipient_conn = log_in_user(conn, recipient_scope.user)

      assert {:ok, %{relationship: request}} =
               Friendships.send_friend_request(caller_scope, %{
                 username: recipient_scope.user.username
               })

      assert {:ok, _friendship} =
               Friendships.accept_friend_request(recipient_scope, request.id)

      assert {:ok, direct_conversation} =
               Chat.open_direct_conversation(caller_scope, recipient_scope.user.id)

      assert {:ok, %{call: ringing}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      assert {:ok, cancelled} = Calls.cancel_call(caller_scope, ringing.call_id)
      refute Map.has_key?(cancelled, :pid)
      refute inspect(cancelled) =~ "#PID"

      item =
        Repo.get_by!(ActivityItem,
          recipient_user_id: recipient_scope.user.id,
          kind: "missed_direct_call",
          source_call_attempt_id: ringing.call_id
        )

      {:ok, view, _html} = live(recipient_conn, ~p"/activity")

      refute has_element?(view, "#activity-item-#{item.id}", "#PID")
      refute has_element?(view, "#activity-item-#{item.id}", "application/sdp")
      refute has_element?(view, "#activity-item-#{item.id}", "ice-pwd")

      assert has_element?(
               view,
               "#activity-item-#{item.id}[data-source-kind='missed-direct-call'][data-read-state='unread']"
             )

      assert has_element?(
               view,
               "#activity-item-#{item.id} [data-role='actor']",
               caller_scope.user.username
             )

      assert has_element?(
               view,
               "#activity-item-#{item.id} [data-role='kind']",
               "Missed a Direct Call"
             )

      assert has_element?(
               view,
               "#activity-item-#{item.id} [data-role='direct-conversation']",
               "Direct Conversation with #{caller_scope.user.username}"
             )

      assert has_element?(
               view,
               "#activity-item-#{item.id} [data-role='preview']",
               "This Direct Call was missed."
             )

      assert has_element?(
               view,
               "#activity-preview-item-#{item.id}[data-read-state='unread']"
             )

      destination = ~p"/direct-messages/#{direct_conversation.id}"

      {:ok, conversation_view, _html} =
        view
        |> element("#activity-preview-item-#{item.id}-open")
        |> render_click()
        |> follow_redirect(recipient_conn, destination)

      assert %DateTime{} = Repo.reload!(item).read_at
      assert has_element?(conversation_view, "#direct-conversation-header")

      assert has_element?(
               conversation_view,
               "#direct-conversation-participant-#{caller_scope.user.id}"
             )

      refute has_element?(conversation_view, "#direct-conversation-read-only")
    end

    test "opens a missed Direct Call into the preserved read-only Direct Conversation after Friendship ends",
         %{conn: conn} do
      start_supervised!(DiscordClone.Calls.Supervisor)
      DiscordClone.Calls.CallCoordinator.begin_recovery()
      await_recovery_finished()

      caller_scope = DiscordClone.AccountsFixtures.user_scope_fixture()
      recipient_scope = DiscordClone.AccountsFixtures.user_scope_fixture()
      recipient_conn = log_in_user(conn, recipient_scope.user)

      assert {:ok, %{relationship: request}} =
               Friendships.send_friend_request(caller_scope, %{
                 username: recipient_scope.user.username
               })

      assert {:ok, friendship} =
               Friendships.accept_friend_request(recipient_scope, request.id)

      assert {:ok, direct_conversation} =
               Chat.open_direct_conversation(caller_scope, recipient_scope.user.id)

      assert {:ok, %{call: ringing}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      assert {:ok, _cancelled} = Calls.cancel_call(caller_scope, ringing.call_id)
      assert :ok = Friendships.remove_friend(recipient_scope, friendship.id)

      item =
        Repo.get_by!(ActivityItem,
          recipient_user_id: recipient_scope.user.id,
          kind: "missed_direct_call",
          source_call_attempt_id: ringing.call_id
        )

      {:ok, view, _html} = live(recipient_conn, ~p"/activity")

      assert has_element?(
               view,
               "#activity-item-#{item.id}[data-source-kind='missed-direct-call']"
             )

      destination = ~p"/direct-messages/#{direct_conversation.id}"

      {:ok, conversation_view, _html} =
        view
        |> element("#activity-item-#{item.id}-open")
        |> render_click()
        |> follow_redirect(recipient_conn, destination)

      assert has_element?(conversation_view, "#direct-conversation-read-only")
      refute has_element?(conversation_view, "#direct-message-form")
    end

    test "opens a missed Direct Call after its Call Attempt row is pruned", %{conn: conn} do
      start_supervised!(DiscordClone.Calls.Supervisor)
      DiscordClone.Calls.CallCoordinator.begin_recovery()
      await_recovery_finished()

      caller_scope = DiscordClone.AccountsFixtures.user_scope_fixture()
      recipient_scope = DiscordClone.AccountsFixtures.user_scope_fixture()
      recipient_conn = log_in_user(conn, recipient_scope.user)

      assert {:ok, %{relationship: request}} =
               Friendships.send_friend_request(caller_scope, %{
                 username: recipient_scope.user.username
               })

      assert {:ok, friendship} =
               Friendships.accept_friend_request(recipient_scope, request.id)

      assert {:ok, direct_conversation} =
               Chat.open_direct_conversation(caller_scope, recipient_scope.user.id)

      assert {:ok, %{call: ringing}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      assert {:ok, cancelled} = Calls.cancel_call(caller_scope, ringing.call_id)

      item =
        Repo.get_by!(ActivityItem,
          recipient_user_id: recipient_scope.user.id,
          kind: "missed_direct_call",
          source_call_attempt_id: cancelled.call_id
        )

      backdate_terminal_attempt!(
        cancelled.call_id,
        DateTime.add(DateTime.utc_now(:microsecond), -7, :day)
      )

      run_coordinator_prune()
      assert is_nil(Repo.get(DiscordClone.Calls.CallAttempt, cancelled.call_id))

      kept = Repo.get!(ActivityItem, item.id)
      assert kept.source_call_attempt_id == cancelled.call_id
      assert kept.source_conversation_id == direct_conversation.id

      assert :ok = Friendships.remove_friend(recipient_scope, friendship.id)

      {:ok, view, _html} = live(recipient_conn, ~p"/activity")

      assert has_element?(
               view,
               "#activity-item-#{item.id}[data-source-kind='missed-direct-call']"
             )

      destination = ~p"/direct-messages/#{direct_conversation.id}"

      {:ok, conversation_view, _html} =
        view
        |> element("#activity-item-#{item.id}-open")
        |> render_click()
        |> follow_redirect(recipient_conn, destination)

      assert %DateTime{} = Repo.reload!(item).read_at
      assert has_element?(conversation_view, "#direct-conversation-read-only")
      refute has_element?(conversation_view, "#direct-message-form")
    end

    test "shows the same safe failure for unavailable and malformed activity targets", %{
      conn: conn
    } do
      recipient_scope = DiscordClone.AccountsFixtures.user_scope_fixture()
      recipient_conn = log_in_user(conn, recipient_scope.user)
      author_scope = DiscordClone.AccountsFixtures.user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(author_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, recipient_scope)

      assert {:ok, source_message} =
               Chat.send_message(author_scope, workspace.default_channel_id, %{
                 content: "temporary request @#{recipient_scope.user.username}"
               })

      source_item = activity_item_for_message!(source_message.id)
      {:ok, view, _html} = live(recipient_conn, ~p"/activity")
      assert {:ok, _deleted_message} = Chat.delete_message(author_scope, source_message.id)

      for activity_item_id <- [source_item.id, Ecto.UUID.generate(), "not-a-uuid"] do
        render_hook(view, "open_activity_item", %{"activity-item-id" => activity_item_id})
        assert has_element?(view, "#flash-error", "Activity is no longer available")
      end

      refute Repo.get(ActivityItem, source_item.id)
      assert {:ok, 0} = Chat.unread_activity_count(recipient_scope)
    end
  end

  defp activity_item_for_message!(message_id) do
    Repo.get_by!(ActivityItem, source_message_id: message_id)
  end

  defp set_activity_time!(activity_item, inserted_at) do
    activity_item
    |> Ecto.Changeset.change(inserted_at: inserted_at)
    |> Repo.update!()
  end

  defp activity_row_ids(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> then(& &1["#activity-feed > article"])
    |> LazyHTML.attribute("id")
  end
end
