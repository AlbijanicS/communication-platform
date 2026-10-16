defmodule DiscordCloneWeb.WorkspaceLive.HomeManagementTest do
  use DiscordCloneWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import DiscordClone.AccountsFixtures
  import DiscordCloneWeb.WorkspaceLiveTestHelpers

  alias DiscordClone.Workspaces
  alias DiscordClone.Chat
  alias DiscordClone.Workspaces.Channel
  alias DiscordClone.Repo
  alias DiscordClone.Voice

  describe "workspace and channel management" do
    setup :register_and_log_in_user

    test "shows an accessible browser-owned Voice Channel join surface and owner controls", %{
      conn: conn,
      scope: scope
    } do
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})

      {:ok, voice_channel} =
        Workspaces.create_voice_channel(scope, workspace.id, %{name: "Lobby"})

      {:ok, view, _html} =
        live(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      assert has_element?(view, "#voice-channels")

      assert has_element?(view, "#voice-channel-#{voice_channel.id}", "lobby")

      assert has_element?(view, "#voice-channel-#{voice_channel.id}[data-voice-channel-row]")

      assert has_element?(
               view,
               "#voice-channel-#{voice_channel.id}-join[type='button'][aria-label='Join voice channel lobby, Empty'][aria-pressed='false'][data-workspace-id='#{workspace.id}']"
             )

      refute has_element?(view, "#voice-channel-local-state")
      refute has_element?(view, "#voice-channel-local-controls")
      refute has_element?(view, "#voice-channel-leave")

      assert has_element?(
               view,
               "#channel-sidebar #global-voice-connection-panel[data-voice-controls-panel][hidden]"
             )

      assert has_element?(
               view,
               "#global-voice-controls-deafen[data-voice-controls-deafen][aria-pressed='false']"
             )

      assert has_element?(view, "[data-voice-logout]")
      assert has_element?(view, "#voice-channel-create-toggle")
    end

    test "renders each Voice Channel Roster independently and updates it without a refresh", %{
      conn: conn,
      scope: scope
    } do
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})

      {:ok, first_voice_channel} =
        Workspaces.create_voice_channel(scope, workspace.id, %{name: "Lobby"})

      {:ok, second_voice_channel} =
        Workspaces.create_voice_channel(scope, workspace.id, %{name: "Focus"})

      first_member_scope = DiscordClone.AccountsFixtures.user_scope_fixture()
      second_member_scope = DiscordClone.AccountsFixtures.user_scope_fixture()
      add_workspace_member!(workspace, first_member_scope)
      add_workspace_member!(workspace, second_member_scope)

      {:ok, view, _html} =
        live(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      assert has_element?(view, "#voice-channel-#{first_voice_channel.id}-roster")
      assert has_element?(view, "#voice-channel-#{second_voice_channel.id}-roster")

      refute has_element?(
               view,
               "#voice-channel-#{first_voice_channel.id}-roster-member-#{first_member_scope.user.id}"
             )

      assert {:ok, %{voice_session_id: first_voice_session_id}} =
               Voice.join(
                 first_voice_channel.id,
                 first_member_scope.user.id,
                 "first-roster-session",
                 self()
               )

      assert has_element?(
               view,
               "#voice-channel-#{first_voice_channel.id}-roster-member-#{first_member_scope.user.id}",
               first_member_scope.user.username
             )

      assert has_element?(
               view,
               "#voice-channel-#{first_voice_channel.id}-roster-member-#{first_member_scope.user.id} [aria-hidden='true']",
               first_member_scope.user.username |> String.first() |> String.upcase()
             )

      refute has_element?(
               view,
               "#voice-channel-#{first_voice_channel.id}-roster-member-#{first_member_scope.user.id}-avatar[data-speaking-indicator='true']"
             )

      assert :ok =
               Voice.publish_voice_channel_roster(%{
                 voice_channel_id: first_voice_channel.id,
                 members: [
                   %{
                     user_id: first_member_scope.user.id,
                     muted: false,
                     deafened: false,
                     speaking: true
                   }
                 ]
               })

      assert has_element?(
               view,
               "#voice-channel-#{first_voice_channel.id}-roster-member-#{first_member_scope.user.id}-avatar[data-speaking-indicator='true'].ring-2"
             )

      refute has_element?(
               view,
               "#voice-channel-#{second_voice_channel.id}-roster-member-#{first_member_scope.user.id}"
             )

      assert {:ok, %{voice_session_id: second_voice_session_id}} =
               Voice.join(
                 first_voice_channel.id,
                 second_member_scope.user.id,
                 "second-roster-session",
                 self()
               )

      assert has_element?(
               view,
               "#voice-channel-#{first_voice_channel.id}-roster-member-#{first_member_scope.user.id} + #voice-channel-#{first_voice_channel.id}-roster-member-#{second_member_scope.user.id}"
             )

      assert :ok =
               Voice.update_local_voice_state(
                 first_member_scope,
                 first_voice_channel.id,
                 first_voice_session_id,
                 %{muted: true, deafened: true}
               )

      assert has_element?(
               view,
               "#voice-channel-#{first_voice_channel.id}-roster-member-#{first_member_scope.user.id} [aria-label='Muted']"
             )

      assert has_element?(
               view,
               "#voice-channel-#{first_voice_channel.id}-roster-member-#{first_member_scope.user.id} [aria-label='Deafened']"
             )

      assert :ok = Voice.leave(first_voice_channel.id, first_voice_session_id)

      refute has_element?(
               view,
               "#voice-channel-#{first_voice_channel.id}-roster-member-#{first_member_scope.user.id}"
             )

      assert has_element?(
               view,
               "#voice-channel-#{first_voice_channel.id}-roster-member-#{second_member_scope.user.id}"
             )

      assert :ok = Voice.leave(first_voice_channel.id, second_voice_session_id)
    end

    test "keeps a Voice Channel roster scannable at its visible-member boundary", %{
      conn: conn,
      scope: scope
    } do
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})

      {:ok, voice_channel} =
        Workspaces.create_voice_channel(scope, workspace.id, %{name: "Lobby"})

      member_scopes = Enum.map(1..5, fn _ -> user_scope_fixture() end)
      Enum.each(member_scopes, &add_workspace_member!(workspace, &1))

      {:ok, view, _html} =
        live(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      voice_session_ids =
        Enum.map(member_scopes, fn member_scope ->
          assert {:ok, %{voice_session_id: voice_session_id}} =
                   Voice.join(
                     voice_channel.id,
                     member_scope.user.id,
                     "boundary-#{member_scope.user.id}",
                     self()
                   )

          voice_session_id
        end)

      assert has_element?(
               view,
               "#voice-channel-#{voice_channel.id}-join[aria-label='Join voice channel lobby, 5 people']"
             )

      refute has_element?(view, "#voice-channel-#{voice_channel.id}-occupancy")

      member_scopes
      |> Enum.take(4)
      |> Enum.each(fn member_scope ->
        assert has_element?(
                 view,
                 "#voice-channel-#{voice_channel.id}-roster-member-#{member_scope.user.id}"
               )
      end)

      fifth_member_scope = Enum.at(member_scopes, 4)

      refute has_element?(
               view,
               "#voice-channel-#{voice_channel.id}-roster-member-#{fifth_member_scope.user.id}"
             )

      assert has_element?(view, "#voice-channel-#{voice_channel.id}-roster-overflow", "+1 more")

      Enum.each(voice_session_ids, &Voice.leave(voice_channel.id, &1))
    end

    test "shows Voice Disconnect only for permitted roster targets", %{
      conn: owner_conn,
      scope: owner_scope
    } do
      admin_scope = user_scope_fixture()
      member_scope = user_scope_fixture()
      regular_scope = user_scope_fixture()

      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Roster actions"})
      add_workspace_member!(workspace, admin_scope, "admin")
      add_workspace_member!(workspace, member_scope)
      add_workspace_member!(workspace, regular_scope)

      {:ok, voice_channel} =
        Workspaces.create_voice_channel(owner_scope, workspace.id, %{name: "Lobby"})

      on_exit(fn -> cleanup_room(voice_channel.id) end)

      for {scope, connection_id} <- [
            {owner_scope, "owner"},
            {admin_scope, "admin"},
            {member_scope, "member"},
            {regular_scope, "regular"}
          ] do
        assert {:ok, _session} =
                 Voice.join(voice_channel.id, scope.user.id, connection_id, self())
      end

      {:ok, owner_view, _html} =
        live(owner_conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      assert has_element?(
               owner_view,
               "#voice-channel-#{voice_channel.id}-roster-member-#{admin_scope.user.id}-voice-disconnect"
             )

      assert has_element?(
               owner_view,
               "#voice-channel-#{voice_channel.id}-roster-member-#{member_scope.user.id}-voice-disconnect"
             )

      refute has_element?(
               owner_view,
               "#voice-channel-#{voice_channel.id}-roster-member-#{owner_scope.user.id}-actions"
             )

      admin_conn = build_conn() |> log_in_user(admin_scope.user)

      {:ok, admin_view, _html} =
        live(admin_conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      assert has_element?(
               admin_view,
               "#voice-channel-#{voice_channel.id}-roster-member-#{member_scope.user.id}-voice-disconnect"
             )

      refute has_element?(
               admin_view,
               "#voice-channel-#{voice_channel.id}-roster-member-#{owner_scope.user.id}-actions"
             )

      refute has_element?(
               admin_view,
               "#voice-channel-#{voice_channel.id}-roster-member-#{admin_scope.user.id}-actions"
             )

      regular_conn = build_conn() |> log_in_user(regular_scope.user)

      {:ok, regular_view, _html} =
        live(
          regular_conn,
          ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}"
        )

      refute has_element?(
               regular_view,
               "#voice-channel-#{voice_channel.id}-roster-member-#{member_scope.user.id}-actions"
             )
    end

    test "Voice Disconnect silently removes the target from the Voice Channel Roster", %{
      conn: conn,
      scope: owner_scope
    } do
      target_scope = user_scope_fixture()

      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Roster disconnect"})
      add_workspace_member!(workspace, target_scope)

      {:ok, voice_channel} =
        Workspaces.create_voice_channel(owner_scope, workspace.id, %{name: "Lobby"})

      on_exit(fn -> cleanup_room(voice_channel.id) end)

      assert {:ok, _session} =
               Voice.join(voice_channel.id, target_scope.user.id, "target-connection", self())

      {:ok, view, _html} =
        live(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      disconnect_button =
        "#voice-channel-#{voice_channel.id}-roster-member-#{target_scope.user.id}-voice-disconnect"

      assert has_element?(view, disconnect_button)
      view |> element(disconnect_button) |> render_click()

      refute has_element?(
               view,
               "#voice-channel-#{voice_channel.id}-roster-member-#{target_scope.user.id}"
             )

      refute has_element?(view, "#flash-info[role='alert']")
      refute has_element?(view, "#flash-error[role='alert']")
    end

    test "creates, validates, renames, and deletes a voice channel from the shell", %{
      conn: conn,
      scope: scope
    } do
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})

      {:ok, view, _html} =
        live(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      view |> element("#voice-channel-create-toggle") |> render_click()
      assert has_element?(view, "#voice-channel-create-form")

      view
      |> form("#voice-channel-create-form", voice_channel: %{name: " "})
      |> render_submit()

      assert has_element?(view, "#voice-channel-create-form", "can't be blank")

      view
      |> form("#voice-channel-create-form", voice_channel: %{name: "Design Room"})
      |> render_submit()

      {:ok, [voice_channel]} = Workspaces.list_voice_channels(scope, workspace.id)
      assert has_element?(view, "#voice-channel-#{voice_channel.id}", "design-room")

      view |> element("#voice-channel-#{voice_channel.id}-actions") |> render_click()
      view |> element("#voice-channel-#{voice_channel.id}-rename") |> render_click()
      assert has_element?(view, "#voice-channel-#{voice_channel.id}-rename-form")

      view
      |> form("#voice-channel-#{voice_channel.id}-rename-form", voice_channel: %{name: "Ops"})
      |> render_submit()

      assert has_element?(view, "#voice-channel-#{voice_channel.id}", "ops")
      view |> element("#voice-channel-#{voice_channel.id}-actions") |> render_click()
      assert has_element?(view, "#voice-channel-#{voice_channel.id}-delete[phx-confirm]")
      view |> element("#voice-channel-#{voice_channel.id}-delete") |> render_click()
      refute has_element?(view, "#voice-channel-#{voice_channel.id}")
    end

    test "keeps one action menu open and removes its trigger while renaming", %{
      conn: conn,
      scope: scope
    } do
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})

      {:ok, voice_channel} =
        Workspaces.create_voice_channel(scope, workspace.id, %{name: "Lobby"})

      {:ok, view, _html} =
        live(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      view
      |> element("#channel-#{workspace.default_channel_id}-actions")
      |> render_click()

      assert has_element?(view, "#channel-#{workspace.default_channel_id}-menu")

      view
      |> element("#voice-channel-#{voice_channel.id}-actions")
      |> render_click()

      refute has_element?(view, "#channel-#{workspace.default_channel_id}-menu")
      assert has_element?(view, "#voice-channel-#{voice_channel.id}-menu")

      render_hook(view, "close_voice_channel_context_menu")

      refute has_element?(view, "#voice-channel-#{voice_channel.id}-menu")

      view
      |> element("#voice-channel-#{voice_channel.id}-actions")
      |> render_click()

      assert has_element?(view, "#voice-channel-#{voice_channel.id}-menu")

      view
      |> element("#voice-channel-#{voice_channel.id}-actions")
      |> render_click()

      refute has_element?(view, "#voice-channel-#{voice_channel.id}-menu")

      view
      |> element("#voice-channel-#{voice_channel.id}-actions")
      |> render_click()

      view
      |> element("#voice-channel-#{voice_channel.id}-rename")
      |> render_click()

      assert has_element?(view, "#voice-channel-#{voice_channel.id}-rename-form")
      refute has_element?(view, "#voice-channel-#{voice_channel.id}-actions")

      view
      |> element("#channel-#{workspace.default_channel_id}-actions")
      |> render_click()

      view
      |> element("#channel-#{workspace.default_channel_id}-rename")
      |> render_click()

      assert has_element?(view, "#channel-#{workspace.default_channel_id}-rename-form")
      refute has_element?(view, "#channel-#{workspace.default_channel_id}-actions")
    end

    test "shows and opens the workspace create action from a selected channel", %{
      conn: conn,
      scope: scope
    } do
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      {:ok, channel} = Workspaces.create_channel(scope, workspace.id, %{name: "Planning"})

      {:ok, view, _html} = live(conn, ~p"/workspaces/#{workspace.id}/channels/#{channel.id}")

      assert has_element?(view, "#workspace-create-toggle[title='Create workspace']")
      refute has_element?(view, "#workspace-create-form")

      view
      |> element("#workspace-create-toggle")
      |> render_click()

      assert has_element?(view, "#workspace-create-form")
    end

    test "cancels workspace creation from a selected channel", %{
      conn: conn,
      scope: scope
    } do
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      {:ok, channel} = Workspaces.create_channel(scope, workspace.id, %{name: "Planning"})

      {:ok, view, _html} = live(conn, ~p"/workspaces/#{workspace.id}/channels/#{channel.id}")

      view
      |> element("#workspace-create-toggle")
      |> render_click()

      view
      |> element("#workspace-create-cancel")
      |> render_click()

      refute has_element?(view, "#workspace-create-form")
      assert has_element?(view, "#channel-message-surface")
      assert has_element?(view, "#workspace-#{workspace.id}[aria-current='page']")
    end

    test "marks workspace and channel targets for context menu hooks", %{
      conn: conn,
      scope: scope
    } do
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})

      {:ok, view, _html} =
        live(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      assert has_element?(
               view,
               "#workspace-#{workspace.id}[phx-hook='ContextMenu'][data-context-menu-type='workspace'][data-context-menu-id='#{workspace.id}']"
             )

      assert has_element?(
               view,
               "#channel-#{workspace.default_channel_id}[phx-hook='ContextMenu'][data-context-menu-type='channel'][data-context-menu-id='#{workspace.default_channel_id}']"
             )
    end

    test "redirects missing or unauthorized channel URLs to the workspace app", %{
      conn: conn,
      scope: scope
    } do
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})

      assert {:error, {:redirect, %{to: "/workspaces", flash: flash}}} =
               live(conn, ~p"/workspaces/#{workspace.id}/channels/not-a-uuid")

      assert flash["error"] =~ "Channel not found"
    end

    test "redirects non-member channel URLs to the workspace app with generic access flash", %{
      conn: conn
    } do
      owner_scope = DiscordClone.AccountsFixtures.user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Private Foundry"})
      {:ok, channel} = Workspaces.create_channel(owner_scope, workspace.id, %{name: "planning"})

      assert {:error, {:redirect, %{to: "/workspaces", flash: flash}}} =
               live(conn, ~p"/workspaces/#{workspace.id}/channels/#{channel.id}")

      assert flash["error"] =~ "Channel not found or you do not have access"
    end

    test "creates a channel from the shell and navigates to it", %{conn: conn, scope: scope} do
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})

      {:ok, view, _html} =
        live(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      view
      |> element("#channel-create-toggle")
      |> render_click()

      {:error, {:live_redirect, %{to: path}}} =
        view
        |> form("#channel-create-form", channel: %{name: "Planning"})
        |> render_submit()

      assert %{path: expected_path} = URI.parse(path)
      assert expected_path =~ ~r|^/workspaces/#{workspace.id}/channels/[0-9a-f-]{36}$|

      refute expected_path ==
               ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}"
    end

    test "opens the channel action menu with rename", %{conn: conn, scope: scope} do
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})

      {:ok, view, _html} =
        live(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      view
      |> element("#channel-#{workspace.default_channel_id}-actions")
      |> render_click()

      assert has_element?(view, "#channel-#{workspace.default_channel_id}-menu")
      assert has_element?(view, "#channel-#{workspace.default_channel_id}-rename")
    end

    test "refreshes unread badges when opening a channel action menu", %{
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

      inserted_at = DateTime.add(DateTime.utc_now(:second), 5, :second)

      message =
        insert_message!(sibling_channel.id, owner_scope.user.id, "ops update", inserted_at)

      assert {:ok, _read_state} =
               Chat.add_channel_unread_range(
                 member_scope,
                 sibling_channel.id,
                 message.seq,
                 message.seq
               )

      view
      |> element("#channel-#{sibling_channel.id}-actions")
      |> render_click()

      assert has_element?(
               view,
               "#channel-#{sibling_channel.id}-unread-badge[aria-label='1 unread message in ops']",
               "1"
             )
    end

    test "shows mark as read in an unread channel action menu", %{
      conn: conn,
      scope: member_scope
    } do
      {_owner_scope, workspace, sibling_channel} =
        workspace_with_sibling_unread!(member_scope)

      {:ok, view, _html} =
        live(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      view
      |> element("#channel-#{sibling_channel.id}-actions")
      |> render_click()

      assert has_element?(view, "#channel-#{sibling_channel.id}-mark-read", "Mark as read")
    end

    test "hides mark as read in a quiet channel action menu", %{conn: conn, scope: scope} do
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      {:ok, quiet_channel} = Workspaces.create_channel(scope, workspace.id, %{name: "quiet"})

      {:ok, view, _html} =
        live(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      view
      |> element("#channel-#{quiet_channel.id}-actions")
      |> render_click()

      refute has_element?(view, "#channel-#{quiet_channel.id}-mark-read")
    end

    test "marks a non-selected sidebar channel read without navigating", %{
      conn: conn,
      scope: member_scope
    } do
      {_owner_scope, workspace, sibling_channel} =
        workspace_with_sibling_unread!(member_scope)

      {:ok, view, _html} =
        live(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      assert has_element?(view, "#channel-#{workspace.default_channel_id}[aria-current='page']")
      assert has_element?(view, "#channel-#{sibling_channel.id}-unread-badge", "1")

      view
      |> element("#channel-#{sibling_channel.id}-actions")
      |> render_click()

      view
      |> element("#channel-#{sibling_channel.id}-mark-read")
      |> render_click()

      assert has_element?(view, "#channel-#{workspace.default_channel_id}[aria-current='page']")
      refute has_element?(view, "#channel-#{sibling_channel.id}-unread-badge")
      assert Chat.list_unread_counts(member_scope, workspace.id) == {:ok, %{}}
    end

    test "marks the selected sidebar channel read without changing the message window", %{
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
      refute has_element?(view, "#channel-#{workspace.default_channel_id}-unread-badge")
      message_ids_before = rendered_message_ids(view)

      view
      |> element("#channel-#{workspace.default_channel_id}-actions")
      |> render_click()

      assert has_element?(
               view,
               "#channel-#{workspace.default_channel_id}-mark-read",
               "Mark as read"
             )

      view
      |> element("#channel-#{workspace.default_channel_id}-mark-read")
      |> render_click()

      refute has_element?(view, "#selected-channel-unread-actions")
      refute has_element?(view, "#channel-unread-divider")
      assert rendered_message_ids(view) == message_ids_before
      assert Chat.list_unread_counts(member_scope, workspace.id) == {:ok, %{}}
    end

    test "opens the channel action menu from a context menu event", %{
      conn: conn,
      scope: scope
    } do
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})

      {:ok, view, _html} =
        live(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      render_hook(view, "open_context_menu", %{
        "type" => "channel",
        "id" => workspace.default_channel_id,
        "x" => 320,
        "y" => 180
      })

      assert has_element?(
               view,
               "#channel-#{workspace.default_channel_id}-menu[style='left: 320px; top: 180px;']"
             )

      assert has_element?(view, "#channel-#{workspace.default_channel_id}-rename")
    end

    test "tolerates a context menu event with non-numeric coordinates", %{
      conn: conn,
      scope: scope
    } do
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})

      {:ok, view, _html} =
        live(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      render_hook(view, "open_context_menu", %{
        "type" => "channel",
        "id" => workspace.default_channel_id,
        "x" => "not-a-number",
        "y" => "also-bad"
      })

      assert Process.alive?(view.pid)

      assert has_element?(
               view,
               "#channel-#{workspace.default_channel_id}-menu[style='left: 0px; top: 0px;']"
             )
    end

    test "refreshes unread badges when opening a channel context menu", %{
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

      inserted_at = DateTime.add(DateTime.utc_now(:second), 5, :second)

      message =
        insert_message!(sibling_channel.id, owner_scope.user.id, "ops update", inserted_at)

      assert {:ok, _read_state} =
               Chat.add_channel_unread_range(
                 member_scope,
                 sibling_channel.id,
                 message.seq,
                 message.seq
               )

      render_hook(view, "open_context_menu", %{
        "type" => "channel",
        "id" => sibling_channel.id,
        "x" => 320,
        "y" => 180
      })

      assert has_element?(
               view,
               "#channel-#{sibling_channel.id}-unread-badge[aria-label='1 unread message in ops']",
               "1"
             )
    end

    test "opens the workspace action menu with rename", %{conn: conn, scope: scope} do
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})

      {:ok, view, _html} =
        live(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      view
      |> element("#workspace-#{workspace.id}-actions")
      |> render_click()

      assert has_element?(view, "#workspace-#{workspace.id}-menu")
      assert has_element?(view, "#workspace-#{workspace.id}-rename")
    end

    test "opens the workspace action menu from a context menu event", %{
      conn: conn,
      scope: scope
    } do
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})

      {:ok, view, _html} =
        live(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      render_hook(view, "open_context_menu", %{
        "type" => "workspace",
        "id" => workspace.id,
        "x" => 96,
        "y" => 144
      })

      assert has_element?(
               view,
               "#workspace-#{workspace.id}-menu[style='left: 96px; top: 144px;']"
             )

      assert has_element?(view, "#workspace-#{workspace.id}-rename")
      assert has_element?(view, "#workspace-#{workspace.id}-delete")
    end

    test "closes an open context menu", %{conn: conn, scope: scope} do
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})

      {:ok, view, _html} =
        live(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      render_hook(view, "open_context_menu", %{
        "type" => "channel",
        "id" => workspace.default_channel_id,
        "x" => 320,
        "y" => 180
      })

      assert has_element?(view, "#channel-#{workspace.default_channel_id}-menu")

      render_hook(view, "close_context_menu")

      refute has_element?(view, "#channel-#{workspace.default_channel_id}-menu")
    end

    test "wires context menus for click-away and Escape closing", %{
      conn: conn,
      scope: scope
    } do
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})

      {:ok, view, _html} =
        live(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      render_hook(view, "open_context_menu", %{
        "type" => "workspace",
        "id" => workspace.id,
        "x" => 96,
        "y" => 144
      })

      assert has_element?(
               view,
               "#workspace-#{workspace.id}-menu[phx-click-away='close_context_menu'][phx-window-keydown='close_context_menu'][phx-key='escape']"
             )

      render_hook(view, "open_context_menu", %{
        "type" => "channel",
        "id" => workspace.default_channel_id,
        "x" => 320,
        "y" => 180
      })

      assert has_element?(
               view,
               "#channel-#{workspace.default_channel_id}-menu[phx-click-away='close_context_menu'][phx-window-keydown='close_context_menu'][phx-key='escape']"
             )
    end

    test "shows delete workspace for owner action menus", %{conn: conn, scope: scope} do
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})

      {:ok, view, _html} =
        live(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      view
      |> element("#workspace-#{workspace.id}-actions")
      |> render_click()

      assert has_element?(
               view,
               "#workspace-#{workspace.id}-delete[phx-confirm='Delete this workspace? The workspace and all contained channels/messages will be removed.']",
               "Delete workspace"
             )

      refute has_element?(view, "#workspace-#{workspace.id}-leave")
    end

    test "shows leave workspace for non-owner member action menus", %{
      conn: conn,
      scope: member_scope
    } do
      owner_scope = DiscordClone.AccountsFixtures.user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, member_scope)

      {:ok, view, _html} =
        live(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      view
      |> element("#workspace-#{workspace.id}-actions")
      |> render_click()

      assert has_element?(
               view,
               "#workspace-#{workspace.id}-leave[phx-confirm='Leave this workspace? You will lose access and need a new invite to return.']",
               "Leave workspace"
             )

      refute has_element?(view, "#workspace-#{workspace.id}-delete")
    end

    test "owner deletes the selected workspace and returns to workspace app", %{
      conn: conn,
      scope: scope
    } do
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})

      {:ok, view, _html} =
        live(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      view
      |> element("#workspace-#{workspace.id}-actions")
      |> render_click()

      assert {:error, {:live_redirect, %{to: path}}} =
               view
               |> element("#workspace-#{workspace.id}-delete")
               |> render_click()

      assert path == ~p"/workspaces"
      assert Workspaces.fetch_workspace(scope, workspace.id) == {:error, :not_found}
    end

    test "non-owner leaves the selected workspace and returns to workspace app", %{
      conn: conn,
      scope: member_scope
    } do
      owner_scope = DiscordClone.AccountsFixtures.user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, member_scope)

      {:ok, view, _html} =
        live(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      view
      |> element("#workspace-#{workspace.id}-actions")
      |> render_click()

      assert {:error, {:live_redirect, %{to: path}}} =
               view
               |> element("#workspace-#{workspace.id}-leave")
               |> render_click()

      assert path == ~p"/workspaces"
      assert Workspaces.fetch_workspace(member_scope, workspace.id) == {:error, :unauthorized}
    end

    test "opens a workspace rename form from the action menu", %{conn: conn, scope: scope} do
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})

      {:ok, view, _html} =
        live(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      view
      |> element("#workspace-#{workspace.id}-actions")
      |> render_click()

      view
      |> element("#workspace-#{workspace.id}-rename")
      |> render_click()

      assert has_element?(view, "#workspace-#{workspace.id}-rename-form")
    end

    test "renames the selected workspace and keeps the channel URL", %{
      conn: conn,
      scope: scope
    } do
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      path = ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}"
      {:ok, view, _html} = live(conn, path)

      view
      |> element("#workspace-#{workspace.id}-actions")
      |> render_click()

      view
      |> element("#workspace-#{workspace.id}-rename")
      |> render_click()

      view
      |> form("#workspace-#{workspace.id}-rename-form", workspace: %{name: "Design Guild"})
      |> render_submit()

      assert has_element?(view, "#workspace-#{workspace.id}[title='Design Guild']", "D")
      assert has_element?(view, "#selected-workspace-name", "Design Guild")
      assert has_element?(view, "#channel-message-surface")
      refute has_element?(view, "#workspace-#{workspace.id}-rename-form")
      assert {:ok, renamed_workspace} = Workspaces.fetch_workspace(scope, workspace.id)
      assert renamed_workspace.name == "Design Guild"
    end

    test "keeps the workspace rename form open with field errors for invalid input", %{
      conn: conn,
      scope: scope
    } do
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})

      {:ok, view, _html} =
        live(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      view
      |> element("#workspace-#{workspace.id}-actions")
      |> render_click()

      view
      |> element("#workspace-#{workspace.id}-rename")
      |> render_click()

      view
      |> form("#workspace-#{workspace.id}-rename-form", workspace: %{name: ""})
      |> render_submit()

      assert has_element?(view, "#workspace-#{workspace.id}-rename-form")
      assert has_element?(view, "#workspace_name.input-error")
      assert has_element?(view, "#workspace-#{workspace.id}-rename-form", "can't be blank")
    end

    test "shows delete only for non-landing channel action menus", %{conn: conn, scope: scope} do
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      {:ok, channel} = Workspaces.create_channel(scope, workspace.id, %{name: "Planning"})

      {:ok, view, _html} = live(conn, ~p"/workspaces/#{workspace.id}/channels/#{channel.id}")

      view
      |> element("#channel-#{workspace.default_channel_id}-actions")
      |> render_click()

      refute has_element?(view, "#channel-#{workspace.default_channel_id}-delete")

      view
      |> element("#channel-#{channel.id}-actions")
      |> render_click()

      assert has_element?(
               view,
               "#channel-#{channel.id}-delete[phx-confirm='Delete this channel? The channel and future messages in it will be removed.']"
             )
    end

    test "opens a channel rename form from the action menu", %{conn: conn, scope: scope} do
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})

      {:ok, view, _html} =
        live(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      view
      |> element("#channel-#{workspace.default_channel_id}-actions")
      |> render_click()

      view
      |> element("#channel-#{workspace.default_channel_id}-rename")
      |> render_click()

      assert has_element?(view, "#channel-#{workspace.default_channel_id}-rename-form")
    end

    test "refreshes unread badges while a different channel is being renamed", %{
      conn: conn,
      scope: member_scope
    } do
      owner_scope = DiscordClone.AccountsFixtures.user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      {:ok, unread_channel} = Workspaces.create_channel(owner_scope, workspace.id, %{name: "ops"})

      {:ok, renamed_channel} =
        Workspaces.create_channel(owner_scope, workspace.id, %{name: "planning"})

      add_workspace_member!(workspace, member_scope, "admin")
      :ok = Chat.initialize_workspace_reads_for_user(member_scope.user.id, workspace.id)

      {:ok, view, _html} =
        live(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      view
      |> element("#channel-#{renamed_channel.id}-actions")
      |> render_click()

      refute has_element?(view, "#channel-#{unread_channel.id}-unread-badge")

      inserted_at = DateTime.add(DateTime.utc_now(:second), 5, :second)
      message = insert_message!(unread_channel.id, owner_scope.user.id, "ops update", inserted_at)

      assert {:ok, _read_state} =
               Chat.add_channel_unread_range(
                 member_scope,
                 unread_channel.id,
                 message.seq,
                 message.seq
               )

      view
      |> element("#channel-#{renamed_channel.id}-rename")
      |> render_click()

      assert has_element?(view, "#channel-#{renamed_channel.id}-rename-form")

      assert has_element?(
               view,
               "#channel-#{unread_channel.id}-unread-badge[aria-label='1 unread message in ops']",
               "1"
             )
    end

    test "renames the selected channel and keeps the channel URL", %{conn: conn, scope: scope} do
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      path = ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}"
      {:ok, view, _html} = live(conn, path)

      view
      |> element("#channel-#{workspace.default_channel_id}-actions")
      |> render_click()

      view
      |> element("#channel-#{workspace.default_channel_id}-rename")
      |> render_click()

      view
      |> form("#channel-#{workspace.default_channel_id}-rename-form",
        channel: %{name: "Welcome Desk"}
      )
      |> render_submit()

      assert has_element?(view, "#channel-#{workspace.default_channel_id}", "# welcome-desk")
      assert has_element?(view, "#selected-channel-title", "# welcome-desk")
      assert has_element?(view, "#channel-message-surface")
      refute has_element?(view, "#channel-#{workspace.default_channel_id}-rename-form")
      assert Repo.get!(Channel, workspace.default_channel_id).name == "welcome-desk"
    end

    test "deletes another channel and keeps the current channel open", %{conn: conn, scope: scope} do
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      {:ok, channel} = Workspaces.create_channel(scope, workspace.id, %{name: "Planning"})

      {:ok, view, _html} =
        live(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      view
      |> element("#channel-#{channel.id}-actions")
      |> render_click()

      view
      |> element("#channel-#{channel.id}-delete")
      |> render_click()

      refute has_element?(view, "#channel-#{channel.id}")
      refute Repo.get(Channel, channel.id)
      assert has_element?(view, "#channel-#{workspace.default_channel_id}[aria-current='page']")
    end

    test "refreshes unread badges after deleting another channel", %{
      conn: conn,
      scope: member_scope
    } do
      owner_scope = DiscordClone.AccountsFixtures.user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      {:ok, unread_channel} = Workspaces.create_channel(owner_scope, workspace.id, %{name: "ops"})

      {:ok, deleted_channel} =
        Workspaces.create_channel(owner_scope, workspace.id, %{name: "planning"})

      add_workspace_member!(workspace, member_scope, "owner")
      :ok = Chat.initialize_workspace_reads_for_user(member_scope.user.id, workspace.id)

      {:ok, view, _html} =
        live(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      view
      |> element("#channel-#{deleted_channel.id}-actions")
      |> render_click()

      refute has_element?(view, "#channel-#{unread_channel.id}-unread-badge")

      inserted_at = DateTime.add(DateTime.utc_now(:second), 5, :second)
      message = insert_message!(unread_channel.id, owner_scope.user.id, "ops update", inserted_at)

      assert {:ok, _read_state} =
               Chat.add_channel_unread_range(
                 member_scope,
                 unread_channel.id,
                 message.seq,
                 message.seq
               )

      view
      |> element("#channel-#{deleted_channel.id}-delete")
      |> render_click()

      refute has_element?(view, "#channel-#{deleted_channel.id}")

      assert has_element?(
               view,
               "#channel-#{unread_channel.id}-unread-badge[aria-label='1 unread message in ops']",
               "1"
             )
    end

    test "deletes the current channel and navigates to workspace entry", %{
      conn: conn,
      scope: scope
    } do
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      {:ok, channel} = Workspaces.create_channel(scope, workspace.id, %{name: "Planning"})

      {:ok, view, _html} = live(conn, ~p"/workspaces/#{workspace.id}/channels/#{channel.id}")

      view
      |> element("#channel-#{channel.id}-actions")
      |> render_click()

      assert {:error, {:live_redirect, %{to: path}}} =
               view
               |> element("#channel-#{channel.id}-delete")
               |> render_click()

      assert path == ~p"/workspaces/#{workspace.id}"
      refute Repo.get(Channel, channel.id)
    end

    test "live-updates the channel sidebar when another session creates a channel", %{
      conn: conn,
      scope: scope
    } do
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})

      {:ok, view, _html} =
        live(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      assert {:ok, channel} = Workspaces.create_channel(scope, workspace.id, %{name: "Ops Room"})

      render(view)

      assert has_element?(view, "#channel-#{channel.id}", "# ops-room")
    end

    test "adds a newly-joined member to the sidebar when they accept an invite", %{
      conn: conn,
      scope: scope
    } do
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      {:ok, invite} = Workspaces.create_workspace_invite(scope, workspace.id)

      joiner_scope =
        DiscordClone.AccountsFixtures.user_fixture(%{username: "channel_view_joiner"})
        |> DiscordClone.AccountsFixtures.user_scope_fixture()

      {:ok, view, _html} =
        live(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      refute has_element?(view, "#workspace-member-#{joiner_scope.user.id}")

      assert {:ok, _result} = Workspaces.accept_workspace_invite(joiner_scope, invite.code)

      render(view)

      assert has_element?(
               view,
               "#workspace-member-#{joiner_scope.user.id}",
               "channel_view_joiner"
             )
    end

    test "keeps the rename form open with field errors for invalid input", %{
      conn: conn,
      scope: scope
    } do
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})

      {:ok, view, _html} =
        live(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      view
      |> element("#channel-#{workspace.default_channel_id}-actions")
      |> render_click()

      view
      |> element("#channel-#{workspace.default_channel_id}-rename")
      |> render_click()

      view
      |> form("#channel-#{workspace.default_channel_id}-rename-form", channel: %{name: ""})
      |> render_submit()

      assert has_element?(view, "#channel-#{workspace.default_channel_id}-rename-form")
      assert has_element?(view, "#channel_name.input-error")

      assert has_element?(
               view,
               "#channel-#{workspace.default_channel_id}-rename-form",
               "can't be blank"
             )
    end

    test "keeps the channel form open with field errors for invalid input", %{
      conn: conn,
      scope: scope
    } do
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})

      {:ok, view, _html} =
        live(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      view
      |> element("#channel-create-toggle")
      |> render_click()

      view
      |> form("#channel-create-form", channel: %{name: ""})
      |> render_submit()

      assert has_element?(view, "#channel-create-form")
      assert has_element?(view, "#channel_name.input-error")
      assert has_element?(view, "#channel-create-form", "can't be blank")
    end

    test "cancels channel creation without navigating", %{
      conn: conn,
      scope: scope
    } do
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})

      {:ok, view, _html} =
        live(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      view
      |> element("#channel-create-toggle")
      |> render_click()

      assert has_element?(view, "#channel-create-form")

      view
      |> element("#channel-create-cancel")
      |> render_click()

      refute has_element?(view, "#channel-create-form")
      assert has_element?(view, "#channel-create-toggle")
      assert has_element?(view, "#channel-#{workspace.default_channel_id}[aria-current='page']")
    end
  end

  defp cleanup_room(voice_channel_id) do
    _ = Voice.end_channel_sessions(voice_channel_id)
    _ = Voice.expire_idle_room(voice_channel_id)
  end
end
