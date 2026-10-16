defmodule DiscordCloneWeb.WorkspaceLive.HomeUnreadTest do
  use DiscordCloneWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import DiscordCloneWeb.WorkspaceLiveTestHelpers

  alias DiscordClone.Workspaces
  alias DiscordClone.Chat
  alias DiscordClone.Chat.ChannelReadState
  alias DiscordCloneWeb.WorkspaceLive.Shell
  alias DiscordClone.Workspaces.Channel
  alias DiscordClone.Repo

  describe "/workspaces/:workspace_id/channels/:channel_id show" do
    setup :register_and_log_in_user

    test "renders a refreshable channel URL with selected shell state", %{
      conn: conn,
      scope: scope
    } do
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      {:ok, channel} = Workspaces.create_channel(scope, workspace.id, %{name: "Planning"})

      {:ok, view, _html} = live(conn, ~p"/workspaces/#{workspace.id}/channels/#{channel.id}")

      assert has_element?(view, "#workspace-app-shell")
      assert has_element?(view, "#workspace-#{workspace.id}[aria-current='page']")
      assert has_element?(view, "#channel-#{channel.id}[aria-current='page']")
      assert has_element?(view, "#channel-#{channel.id}-actions")
      assert has_element?(view, "#channel-create-toggle")
      assert has_element?(view, "#channel-message-surface")
      assert has_element?(view, "#channel-messages[phx-hook='ChannelMessages']")
      assert has_element?(view, "#channel-empty-state")
      assert has_element?(view, "#message-composer-form")
      assert has_element?(view, "#message_content")
      refute has_element?(view, "#message-composer-placeholder")
    end

    test "renders an unread badge for a sibling channel when entering a channel", %{
      conn: conn,
      scope: member_scope
    } do
      {_owner_scope, workspace, sibling_channel} =
        workspace_with_sibling_unread!(member_scope)

      {:ok, view, _html} =
        live(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      assert has_element?(
               view,
               "#channel-#{sibling_channel.id}-unread-badge[aria-label='1 unread message in ops']",
               "1"
             )
    end

    test "syncs sidebar read state across same-user channel sessions", %{
      conn: conn,
      scope: member_scope
    } do
      {_owner_scope, workspace, sibling_channel} =
        workspace_with_sibling_unread!(member_scope)

      path = ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}"
      other_conn = build_conn() |> log_in_user(member_scope.user)

      {:ok, reading_view, _html} = live(conn, path)
      {:ok, synced_view, _html} = live(other_conn, path)

      assert has_element?(reading_view, "#channel-#{sibling_channel.id}-unread-badge", "1")
      assert has_element?(synced_view, "#channel-#{sibling_channel.id}-unread-badge", "1")

      reading_view
      |> element("#channel-#{sibling_channel.id}-actions")
      |> render_click()

      reading_view
      |> element("#channel-#{sibling_channel.id}-mark-read")
      |> render_click()

      refute has_element?(reading_view, "#channel-#{sibling_channel.id}-unread-badge")
      refute has_element?(synced_view, "#channel-#{sibling_channel.id}-unread-badge")
    end

    test "keeps private read-state events isolated between different users", %{
      conn: unread_conn,
      scope: unread_scope
    } do
      owner_scope = DiscordClone.AccountsFixtures.user_scope_fixture()
      other_scope = DiscordClone.AccountsFixtures.user_scope_fixture()
      other_conn = build_conn() |> log_in_user(other_scope.user)

      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})

      {:ok, sibling_channel} =
        Workspaces.create_channel(owner_scope, workspace.id, %{name: "ops"})

      add_workspace_member!(workspace, unread_scope)
      add_workspace_member!(workspace, other_scope)
      :ok = Chat.initialize_workspace_reads_for_user(unread_scope.user.id, workspace.id)
      :ok = Chat.initialize_workspace_reads_for_user(other_scope.user.id, workspace.id)

      {:ok, _message} =
        Chat.send_message(owner_scope, sibling_channel.id, %{content: "ops update"})

      path = ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}"
      {:ok, unread_view, _html} = live(unread_conn, path)
      {:ok, other_view, _html} = live(other_conn, path)

      assert has_element?(unread_view, "#channel-#{sibling_channel.id}-unread-badge", "1")
      assert has_element?(other_view, "#channel-#{sibling_channel.id}-unread-badge", "1")

      other_view
      |> element("#channel-#{sibling_channel.id}-actions")
      |> render_click()

      other_view
      |> element("#channel-#{sibling_channel.id}-mark-read")
      |> render_click()

      assert has_element?(unread_view, "#channel-#{sibling_channel.id}-unread-badge", "1")
      refute has_element?(other_view, "#channel-#{sibling_channel.id}-unread-badge")
    end

    test "clears selected-channel unread UI across same-user channel sessions", %{
      conn: conn,
      scope: member_scope
    } do
      owner_scope = DiscordClone.AccountsFixtures.user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})

      add_workspace_member!(workspace, member_scope)
      :ok = Chat.initialize_workspace_reads_for_user(member_scope.user.id, workspace.id)

      for index <- 1..80 do
        insert_message!(
          workspace.default_channel_id,
          owner_scope.user.id,
          "general update #{index}",
          DateTime.add(~U[2026-06-19 10:00:00Z], index, :second)
        )
      end

      assert {:ok, _read_state} =
               Chat.add_channel_unread_range(member_scope, workspace.default_channel_id, 10, 12)

      path = ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}"
      other_conn = build_conn() |> log_in_user(member_scope.user)

      {:ok, reading_view, _html} = live(conn, path)
      {:ok, synced_view, _html} = live(other_conn, path)

      assert has_element?(reading_view, "#channel-unread-divider[data-unread-divider-seq='10']")
      assert has_element?(synced_view, "#channel-unread-divider[data-unread-divider-seq='10']")

      reading_view
      |> element("#channel-#{workspace.default_channel_id}-actions")
      |> render_click()

      reading_view
      |> element("#channel-#{workspace.default_channel_id}-mark-read")
      |> render_click()

      refute has_element?(reading_view, "#selected-channel-unread-actions")
      refute has_element?(reading_view, "#channel-unread-divider")
      refute has_element?(synced_view, "#selected-channel-unread-actions")
      refute has_element?(synced_view, "#channel-unread-divider")
    end

    test "recalculates selected-channel unread UI across same-user channel sessions", %{
      conn: conn,
      scope: member_scope
    } do
      owner_scope = DiscordClone.AccountsFixtures.user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})

      add_workspace_member!(workspace, member_scope)
      :ok = Chat.initialize_workspace_reads_for_user(member_scope.user.id, workspace.id)

      for index <- 1..80 do
        insert_message!(
          workspace.default_channel_id,
          owner_scope.user.id,
          "general update #{index}",
          DateTime.add(~U[2026-06-19 10:00:00Z], index, :second)
        )
      end

      assert {:ok, _read_state} =
               Chat.add_channel_unread_range(member_scope, workspace.default_channel_id, 10, 12)

      path = ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}"
      other_conn = build_conn() |> log_in_user(member_scope.user)

      {:ok, reading_view, _html} = live(conn, path)
      {:ok, synced_view, _html} = live(other_conn, path)

      assert has_element?(reading_view, "#channel-unread-divider[data-unread-divider-seq='10']")
      assert has_element?(synced_view, "#channel-unread-divider[data-unread-divider-seq='10']")

      render_hook(reading_view, "visible_read_observed", %{
        "ranges" => [%{"from_seq" => 10, "to_seq" => 10}]
      })

      assert has_element?(reading_view, "#channel-unread-divider[data-unread-divider-seq='10']")
      assert has_element?(synced_view, "#channel-unread-divider[data-unread-divider-seq='11']")
    end

    test "starts disconnected channel render with no unread badges", %{
      conn: conn,
      scope: member_scope
    } do
      {_owner_scope, workspace, sibling_channel} =
        workspace_with_sibling_unread!(member_scope)

      html =
        conn
        |> get(~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")
        |> html_response(200)

      assert html
             |> LazyHTML.from_fragment()
             |> then(& &1["#channel-#{sibling_channel.id}-unread-badge"])
             |> LazyHTML.attribute("id") == []
    end

    test "opens an unread channel near its unread messages without marking it read", %{
      conn: conn,
      scope: member_scope
    } do
      owner_scope = DiscordClone.AccountsFixtures.user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})

      {:ok, sibling_channel} =
        Workspaces.create_channel(owner_scope, workspace.id, %{name: "ops"})

      add_workspace_member!(workspace, member_scope)
      :ok = Chat.initialize_workspace_reads_for_user(member_scope.user.id, workspace.id)

      messages =
        for index <- 1..60 do
          insert_message!(
            sibling_channel.id,
            owner_scope.user.id,
            "ops update #{index}",
            DateTime.add(~U[2026-06-19 10:00:00Z], index, :second)
          )
        end

      unread_message = Enum.at(messages, 9)
      latest_message = List.last(messages)

      assert {:ok, _read_state} =
               Chat.add_channel_unread_range(member_scope, sibling_channel.id, 10, 12)

      default_channel_path =
        ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}"

      sibling_channel_path = ~p"/workspaces/#{workspace.id}/channels/#{sibling_channel.id}"

      {:ok, view, _html} = live(conn, default_channel_path)

      assert has_element?(view, "#channel-#{sibling_channel.id}-unread-badge", "3")

      {:ok, opened_view, _html} =
        view
        |> element("#channel-#{sibling_channel.id} a")
        |> render_click()
        |> follow_redirect(conn, sibling_channel_path)

      assert has_element?(opened_view, "#channel-#{sibling_channel.id}[aria-current='page']")
      assert has_element?(opened_view, "#message-#{unread_message.id}-content", "ops update 10")

      assert has_element?(
               opened_view,
               "#channel-unread-divider[data-unread-divider-seq='10']"
             )

      assert has_element?(
               opened_view,
               "#channel-unread-divider-marker[data-message-id='#{unread_message.id}']"
             )

      refute has_element?(opened_view, "#message-#{latest_message.id}-content", "ops update 60")
      refute has_element?(opened_view, "#channel-#{sibling_channel.id}-unread-badge")

      assert Chat.list_unread_counts(member_scope, workspace.id) ==
               {:ok, %{sibling_channel.id => 3}}
    end

    test "jumps to oldest unread from the selected channel without marking it read", %{
      conn: conn,
      scope: member_scope
    } do
      owner_scope = DiscordClone.AccountsFixtures.user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, member_scope)
      :ok = Chat.initialize_workspace_reads_for_user(member_scope.user.id, workspace.id)

      messages =
        for index <- 1..80 do
          insert_message!(
            workspace.default_channel_id,
            owner_scope.user.id,
            "general update #{index}",
            DateTime.add(~U[2026-06-19 10:00:00Z], index, :second)
          )
        end

      {:ok, view, _html} =
        live(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      latest_message = List.last(messages)
      oldest_unread_message = Enum.at(messages, 9)

      assert has_element?(view, "#message-#{latest_message.id}-content", "general update 80")
      refute has_element?(view, "#message-#{oldest_unread_message.id}-content")

      assert {:ok, _read_state} =
               Chat.add_channel_unread_range(member_scope, workspace.default_channel_id, 10, 12)

      send(
        view.pid,
        {:workspace_message_created,
         %{workspace_id: workspace.id, channel_id: workspace.default_channel_id}}
      )

      assert has_element?(view, "#selected-channel-unread-actions")
      refute has_element?(view, "#channel-unread-divider")
      assert has_element?(view, "#jump-to-oldest-unread", "Jump to oldest unread")
      assert has_element?(view, "#mark-channel-read", "Mark as read")
      refute has_element?(view, "#selected-channel-unread-count")
      refute has_element?(view, "#jump-to-next-unread")
      refute render(view) =~ "Jump to next unread"

      view
      |> element("#jump-to-oldest-unread")
      |> render_click()

      assert has_element?(
               view,
               "#message-#{oldest_unread_message.id}-content",
               "general update 10"
             )

      refute has_element?(view, "#message-#{latest_message.id}-content")
      assert has_element?(view, "#channel-unread-divider[data-unread-divider-seq='10']")
      refute has_element?(view, "#selected-channel-unread-actions")

      assert Chat.list_unread_counts(member_scope, workspace.id) ==
               {:ok, %{workspace.default_channel_id => 3}}
    end

    test "marks the selected channel read without changing the message window", %{
      conn: conn,
      scope: member_scope
    } do
      owner_scope = DiscordClone.AccountsFixtures.user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, member_scope)
      :ok = Chat.initialize_workspace_reads_for_user(member_scope.user.id, workspace.id)

      for index <- 1..80 do
        insert_message!(
          workspace.default_channel_id,
          owner_scope.user.id,
          "general update #{index}",
          DateTime.add(~U[2026-06-19 10:00:00Z], index, :second)
        )
      end

      {:ok, view, _html} =
        live(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      assert {:ok, _read_state} =
               Chat.add_channel_unread_range(member_scope, workspace.default_channel_id, 10, 12)

      send(
        view.pid,
        {:workspace_message_created,
         %{workspace_id: workspace.id, channel_id: workspace.default_channel_id}}
      )

      assert has_element?(view, "#selected-channel-unread-actions")
      refute has_element?(view, "#channel-unread-divider")
      message_ids_before = rendered_message_ids(view)

      view
      |> element("#mark-channel-read")
      |> render_click()

      refute has_element?(view, "#selected-channel-unread-actions")
      assert rendered_message_ids(view) == message_ids_before
      assert Chat.list_unread_counts(member_scope, workspace.id) == {:ok, %{}}
    end

    test "marks rendered visible message ranges read from the channel hook", %{
      conn: conn,
      scope: member_scope
    } do
      owner_scope = DiscordClone.AccountsFixtures.user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, member_scope)
      :ok = Chat.initialize_workspace_reads_for_user(member_scope.user.id, workspace.id)

      messages =
        for index <- 1..80 do
          insert_message!(
            workspace.default_channel_id,
            owner_scope.user.id,
            "general update #{index}",
            DateTime.add(~U[2026-06-19 10:00:00Z], index, :second)
          )
        end

      first_read_message = Enum.at(messages, 9)
      last_read_message = Enum.at(messages, 11)

      assert {:ok, _read_state} =
               Chat.add_channel_unread_range(member_scope, workspace.default_channel_id, 10, 12)

      {:ok, view, _html} =
        live(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      assert has_element?(view, "#channel-unread-divider[data-unread-divider-seq='10']")
      refute has_element?(view, "#selected-channel-unread-actions")
      assert has_element?(view, "#message-#{first_read_message.id}[data-message-seq='10']")
      assert has_element?(view, "#message-#{last_read_message.id}[data-message-seq='12']")

      render_hook(view, "visible_read_observed", %{
        "ranges" => [%{"from_seq" => "10", "to_seq" => "12"}]
      })

      refute has_element?(view, "#selected-channel-unread-actions")
      refute has_element?(view, "#channel-unread-divider")
      assert Chat.list_unread_counts(member_scope, workspace.id) == {:ok, %{}}
    end

    test "keeps the unread divider stable after a visible-read event", %{
      conn: conn,
      scope: member_scope
    } do
      owner_scope = DiscordClone.AccountsFixtures.user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, member_scope)
      :ok = Chat.initialize_workspace_reads_for_user(member_scope.user.id, workspace.id)

      messages =
        for index <- 1..80 do
          insert_message!(
            workspace.default_channel_id,
            owner_scope.user.id,
            "general update #{index}",
            DateTime.add(~U[2026-06-19 10:00:00Z], index, :second)
          )
        end

      original_divider_message = Enum.at(messages, 9)
      next_unread_message = Enum.at(messages, 10)

      assert {:ok, _read_state} =
               Chat.add_channel_unread_range(member_scope, workspace.default_channel_id, 10, 12)

      {:ok, view, _html} =
        live(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      assert has_element?(view, "#channel-unread-divider[data-unread-divider-seq='10']")

      assert has_element?(
               view,
               "#channel-unread-divider-marker[data-message-id='#{original_divider_message.id}']"
             )

      render_hook(view, "visible_read_observed", %{
        "ranges" => [%{"from_seq" => "10", "to_seq" => "10"}]
      })

      assert has_element?(view, "#channel-unread-divider[data-unread-divider-seq='10']")

      assert has_element?(
               view,
               "#channel-unread-divider-marker[data-message-id='#{original_divider_message.id}']"
             )

      refute has_element?(
               view,
               "#channel-unread-divider-marker[data-message-id='#{next_unread_message.id}']"
             )

      assert Chat.list_unread_counts(member_scope, workspace.id) ==
               {:ok, %{workspace.default_channel_id => 2}}
    end

    test "ignores invalid and non-rendered visible-read ranges from the channel hook", %{
      conn: conn,
      scope: member_scope
    } do
      owner_scope = DiscordClone.AccountsFixtures.user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, member_scope)
      :ok = Chat.initialize_workspace_reads_for_user(member_scope.user.id, workspace.id)

      messages =
        for index <- 1..80 do
          insert_message!(
            workspace.default_channel_id,
            owner_scope.user.id,
            "general update #{index}",
            DateTime.add(~U[2026-06-19 10:00:00Z], index, :second)
          )
        end

      non_rendered_message = Enum.at(messages, 69)

      assert {:ok, _read_state} =
               Chat.add_channel_unread_range(member_scope, workspace.default_channel_id, 10, 12)

      {:ok, view, _html} =
        live(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      assert has_element?(view, "#channel-unread-divider[data-unread-divider-seq='10']")
      refute has_element?(view, "#selected-channel-unread-actions")
      refute has_element?(view, "#message-#{non_rendered_message.id}[data-message-seq='70']")

      for ranges <- [
            [%{"from_seq" => "11", "to_seq" => "11"}, %{"from_seq" => "10", "to_seq" => "10"}],
            [%{"from_seq" => "70", "to_seq" => "70"}],
            [%{"from_seq" => "12", "to_seq" => "10"}],
            [%{"from_seq" => "1", "to_seq" => "51"}],
            [%{"from_seq" => "not-a-sequence", "to_seq" => "12"}]
          ] do
        render_hook(view, "visible_read_observed", %{"ranges" => ranges})

        assert Chat.list_unread_counts(member_scope, workspace.id) ==
                 {:ok, %{workspace.default_channel_id => 3}}
      end

      assert has_element?(view, "#channel-unread-divider[data-unread-divider-seq='10']")
      refute has_element?(view, "#selected-channel-unread-actions")
    end

    test "persists a rendered scroll anchor from the channel hook", %{
      conn: conn,
      scope: scope
    } do
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})

      messages =
        for index <- 1..80 do
          insert_message!(
            workspace.default_channel_id,
            scope.user.id,
            "anchorable update #{index}",
            DateTime.add(~U[2026-06-19 10:00:00Z], index, :second)
          )
        end

      anchored_message = Enum.at(messages, 39)

      {:ok, view, _html} =
        live(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      assert has_element?(view, "#message-#{anchored_message.id}[data-message-seq='40']")

      render_hook(view, "scroll_anchor_observed", %{"seq" => "40"})

      assert %ChannelReadState{last_viewed_anchor_seq: 40} =
               Repo.get_by(ChannelReadState,
                 channel_id: workspace.default_channel_id,
                 user_id: scope.user.id
               )
    end

    test "ignores invalid scroll anchors and preserves unread state", %{
      conn: conn,
      scope: member_scope
    } do
      owner_scope = DiscordClone.AccountsFixtures.user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, member_scope)
      :ok = Chat.initialize_workspace_reads_for_user(member_scope.user.id, workspace.id)

      messages =
        for index <- 1..80 do
          insert_message!(
            workspace.default_channel_id,
            owner_scope.user.id,
            "anchor guard update #{index}",
            DateTime.add(~U[2026-06-19 10:00:00Z], index, :second)
          )
        end

      non_rendered_message = Enum.at(messages, 19)
      rendered_message = Enum.at(messages, 39)

      assert {:ok, _read_state} =
               Chat.add_channel_unread_range(member_scope, workspace.default_channel_id, 40, 42)

      {:ok, view, _html} =
        live(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      assert has_element?(view, "#channel-unread-divider[data-unread-divider-seq='40']")
      refute has_element?(view, "#selected-channel-unread-actions")
      refute has_element?(view, "#message-#{non_rendered_message.id}[data-message-seq='20']")
      assert has_element?(view, "#message-#{rendered_message.id}[data-message-seq='40']")

      for payload <- [
            %{"seq" => "20"},
            %{"seq" => "81"},
            %{"seq" => "not-a-sequence"},
            %{}
          ] do
        render_hook(view, "scroll_anchor_observed", payload)

        assert %ChannelReadState{last_viewed_anchor_seq: nil} =
                 Repo.get_by(ChannelReadState,
                   channel_id: workspace.default_channel_id,
                   user_id: member_scope.user.id
                 )

        assert Chat.list_unread_counts(member_scope, workspace.id) ==
                 {:ok, %{workspace.default_channel_id => 3}}
      end

      render_hook(view, "scroll_anchor_observed", %{"seq" => "40"})

      assert %ChannelReadState{
               last_viewed_anchor_seq: 40,
               unread_count: 3,
               first_unread_seq: 40,
               last_unread_seq: 42
             } =
               Repo.get_by(ChannelReadState,
                 channel_id: workspace.default_channel_id,
                 user_id: member_scope.user.id
               )

      assert has_element?(view, "#channel-unread-divider[data-unread-divider-seq='40']")
      refute has_element?(view, "#selected-channel-unread-actions")

      assert Chat.list_unread_counts(member_scope, workspace.id) ==
               {:ok, %{workspace.default_channel_id => 3}}
    end

    test "skips to latest by clearing unread and replacing the message window", %{
      conn: conn,
      scope: member_scope
    } do
      owner_scope = DiscordClone.AccountsFixtures.user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, member_scope)
      :ok = Chat.initialize_workspace_reads_for_user(member_scope.user.id, workspace.id)

      messages =
        for index <- 1..80 do
          insert_message!(
            workspace.default_channel_id,
            owner_scope.user.id,
            "general update #{index}",
            DateTime.add(~U[2026-06-19 10:00:00Z], index, :second)
          )
        end

      oldest_unread_message = Enum.at(messages, 9)
      latest_message = List.last(messages)

      assert {:ok, _read_state} =
               Chat.add_channel_unread_range(member_scope, workspace.default_channel_id, 10, 12)

      {:ok, view, _html} =
        live(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      assert has_element?(view, "#channel-unread-divider[data-unread-divider-seq='10']")
      refute has_element?(view, "#selected-channel-unread-actions")

      assert has_element?(
               view,
               "#skip-to-latest[aria-label='Skip to latest and mark unread messages read']"
             )

      assert has_element?(
               view,
               "#message-#{oldest_unread_message.id}-content",
               "general update 10"
             )

      refute has_element?(view, "#message-#{latest_message.id}-content")

      view
      |> element("#skip-to-latest")
      |> render_click()

      refute has_element?(view, "#selected-channel-unread-actions")
      refute has_element?(view, "#message-#{oldest_unread_message.id}-content")
      assert has_element?(view, "#message-#{latest_message.id}-content", "general update 80")
      assert Chat.list_unread_counts(member_scope, workspace.id) == {:ok, %{}}

      assert %ChannelReadState{last_viewed_anchor_seq: 80} =
               Repo.get_by(ChannelReadState,
                 channel_id: workspace.default_channel_id,
                 user_id: member_scope.user.id
               )
    end

    test "reopens a read channel around its last viewed anchor", %{
      conn: conn,
      scope: scope
    } do
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      channel_id = workspace.default_channel_id

      messages =
        for index <- 1..120 do
          insert_message!(
            channel_id,
            scope.user.id,
            "anchored update #{index}",
            DateTime.add(~U[2026-06-19 11:00:00Z], index, :second)
          )
        end

      anchored_message = Enum.at(messages, 19)
      latest_message = List.last(messages)

      Repo.get_by!(ChannelReadState, channel_id: channel_id, user_id: scope.user.id)
      |> ChannelReadState.changeset(%{last_viewed_anchor_seq: 20})
      |> Repo.update!()

      {:ok, view, _html} = live(conn, ~p"/workspaces/#{workspace.id}/channels/#{channel_id}")

      assert has_element?(view, "#message-#{anchored_message.id}-content", "anchored update 20")
      refute has_element?(view, "#message-#{latest_message.id}-content", "anchored update 120")
      assert Chat.list_unread_counts(scope, workspace.id) == {:ok, %{}}
    end

    test "keeps selected-channel live messages out of an older landing window", %{
      conn: conn,
      scope: member_scope
    } do
      owner_scope = DiscordClone.AccountsFixtures.user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      channel_id = workspace.default_channel_id

      add_workspace_member!(workspace, member_scope)
      :ok = Chat.initialize_workspace_reads_for_user(member_scope.user.id, workspace.id)

      messages =
        for index <- 1..120 do
          insert_message!(
            channel_id,
            owner_scope.user.id,
            "older-window update #{index}",
            DateTime.add(~U[2026-06-19 12:00:00Z], index, :second)
          )
        end

      anchored_message = Enum.at(messages, 19)

      Repo.get_by!(ChannelReadState, channel_id: channel_id, user_id: member_scope.user.id)
      |> ChannelReadState.changeset(%{last_viewed_anchor_seq: 20})
      |> Repo.update!()

      {:ok, view, _html} = live(conn, ~p"/workspaces/#{workspace.id}/channels/#{channel_id}")

      assert has_element?(
               view,
               "#message-#{anchored_message.id}-content",
               "older-window update 20"
             )

      assert {:ok, live_message} =
               Chat.send_message(owner_scope, channel_id, %{"content" => "new distant latest"})

      _ = :sys.get_state(view.pid)

      refute has_element?(view, "#message-#{live_message.id}-content", "new distant latest")

      refute_push_event(view, "scroll_channel_messages_to_bottom", %{
        container_id: _container_id
      })

      assert Chat.list_unread_counts(member_scope, workspace.id) == {:ok, %{channel_id => 1}}
    end

    test "refreshes a sibling channel unread badge from a live workspace message event", %{
      conn: conn,
      scope: member_scope
    } do
      owner_scope = DiscordClone.AccountsFixtures.user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})

      {:ok, sibling_channel} =
        Workspaces.create_channel(owner_scope, workspace.id, %{name: "ops"})

      add_workspace_member!(workspace, member_scope)
      :ok = Chat.initialize_workspace_reads_for_user(member_scope.user.id, workspace.id)

      {:ok, view, _html} =
        live(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      refute has_element?(view, "#channel-#{sibling_channel.id}-unread-badge")

      assert {:ok, message} =
               Chat.send_message(owner_scope, sibling_channel.id, %{
                 "content" => "ops live update"
               })

      _ = :sys.get_state(view.pid)

      assert has_element?(
               view,
               "#channel-#{sibling_channel.id}-unread-badge[aria-label='1 unread message in ops']",
               "1"
             )

      refute has_element?(view, "#message-#{message.id}")
    end

    test "renders exact larger unread counts and hides quiet channel badges", %{
      conn: conn,
      scope: member_scope
    } do
      owner_scope = DiscordClone.AccountsFixtures.user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      {:ok, busy_channel} = Workspaces.create_channel(owner_scope, workspace.id, %{name: "ops"})

      {:ok, quiet_channel} =
        Workspaces.create_channel(owner_scope, workspace.id, %{name: "quiet"})

      add_workspace_member!(workspace, member_scope)
      :ok = Chat.initialize_workspace_reads_for_user(member_scope.user.id, workspace.id)

      now = DateTime.utc_now(:second)

      for index <- 1..123 do
        insert_message!(
          busy_channel.id,
          owner_scope.user.id,
          "ops update #{index}",
          DateTime.add(now, index, :second)
        )
      end

      assert {:ok, _read_state} =
               Chat.add_channel_unread_range(member_scope, busy_channel.id, 1, 123)

      {:ok, view, _html} =
        live(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      assert has_element?(
               view,
               "#channel-#{busy_channel.id}-unread-badge[aria-label='123 unread messages in ops']",
               "123"
             )

      refute has_element?(view, "#channel-#{quiet_channel.id}-unread-badge")
      refute has_element?(view, "#channel-#{workspace.default_channel_id}-unread-badge")
    end

    test "scopes unread badges to the current user", %{
      conn: unread_conn,
      scope: unread_scope
    } do
      owner_scope = DiscordClone.AccountsFixtures.user_scope_fixture()
      read_scope = DiscordClone.AccountsFixtures.user_scope_fixture()
      read_conn = build_conn() |> log_in_user(read_scope.user)

      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})

      {:ok, sibling_channel} =
        Workspaces.create_channel(owner_scope, workspace.id, %{name: "ops"})

      add_workspace_member!(workspace, unread_scope)
      add_workspace_member!(workspace, read_scope)
      :ok = Chat.initialize_workspace_reads_for_user(unread_scope.user.id, workspace.id)
      :ok = Chat.initialize_workspace_reads_for_user(read_scope.user.id, workspace.id)

      {:ok, _message} =
        Chat.send_message(owner_scope, sibling_channel.id, %{"content" => "ops update"})

      assert :ok = Chat.mark_channel_read(read_scope, sibling_channel.id)

      {:ok, unread_view, _html} =
        live(
          unread_conn,
          ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}"
        )

      {:ok, read_view, _html} =
        live(read_conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      assert has_element?(
               unread_view,
               "#channel-#{sibling_channel.id}-unread-badge[aria-label='1 unread message in ops']",
               "1"
             )

      refute has_element?(read_view, "#channel-#{sibling_channel.id}-unread-badge")
    end

    test "suppresses the selected channel badge when the shell receives a transient count", %{
      scope: scope
    } do
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      {:ok, sibling_channel} = Workspaces.create_channel(scope, workspace.id, %{name: "ops"})
      selected_channel = Repo.get!(Channel, workspace.default_channel_id)

      html =
        render_component(&Shell.app/1,
          workspace_stream: [{"workspace-#{workspace.id}", workspace}],
          channel_stream: [
            {"channel-#{selected_channel.id}", selected_channel},
            {"channel-#{sibling_channel.id}", sibling_channel}
          ],
          selected_workspace: workspace,
          selected_channel: selected_channel,
          current_scope: scope,
          main_state: :empty_channel,
          channel_unread_counts: %{selected_channel.id => 7, sibling_channel.id => 2}
        )

      document = LazyHTML.from_fragment(html)

      assert document
             |> then(& &1["#channel-#{sibling_channel.id}-unread-badge"])
             |> LazyHTML.attribute("id") == ["channel-#{sibling_channel.id}-unread-badge"]

      assert document
             |> then(& &1["#channel-#{selected_channel.id}-unread-badge"])
             |> LazyHTML.attribute("id") == []
    end
  end
end
