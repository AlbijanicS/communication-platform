defmodule DiscordCloneWeb.WorkspaceLive.HomeMembersTest do
  use DiscordCloneWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import DiscordCloneWeb.WorkspaceLiveTestHelpers

  alias DiscordClone.Workspaces
  alias DiscordClone.Friendships
  alias DiscordClone.Chat
  alias DiscordClone.Chat.Message
  alias DiscordClone.Chat.Runtime
  alias DiscordClone.Workspaces.WorkspaceMembership
  alias DiscordClone.Repo

  describe "channel members, moderation, and presence" do
    setup :register_and_log_in_user

    test "a Workspace Member sends a Friend Request to a known member without retyping", %{
      conn: conn,
      scope: member_scope
    } do
      owner_scope =
        %{username: "known_workspace_member"}
        |> DiscordClone.AccountsFixtures.user_fixture()
        |> DiscordClone.AccountsFixtures.user_scope_fixture()

      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, member_scope)

      {:ok, view, _html} =
        live(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      assert has_element?(
               view,
               "#workspace-member-#{owner_scope.user.id}-send-friend-request"
             )

      view
      |> element("#workspace-member-#{owner_scope.user.id}-send-friend-request")
      |> render_click()

      assert {:ok, [%{user: requested_user}]} =
               Friendships.list_outgoing_requests(member_scope)

      assert requested_user.id == owner_scope.user.id
    end

    test "starts a channel runtime after connected channel entry", %{
      conn: conn,
      scope: scope
    } do
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})

      assert Runtime.conversation_pid(workspace.default_channel_id) == nil

      {:ok, _view, _html} =
        live(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      assert is_pid(Runtime.conversation_pid(workspace.default_channel_id))
    end

    test "does not start a channel runtime during disconnected static render", %{
      conn: conn,
      scope: scope
    } do
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})

      conn = get(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      assert html_response(conn, 200)
      assert Runtime.conversation_pid(workspace.default_channel_id) == nil
    end

    test "renders durable workspace members in the channel shell", %{
      conn: conn,
      scope: member_scope
    } do
      owner_scope =
        %{username: "foundry_owner"}
        |> DiscordClone.AccountsFixtures.user_fixture()
        |> DiscordClone.AccountsFixtures.user_scope_fixture()

      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, member_scope)

      {:ok, view, _html} =
        live(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      assert has_element?(view, "#workspace-members-sidebar[aria-label='Workspace members']")
      assert has_element?(view, "#workspace-members-sidebar", "Members")

      assert has_element?(
               view,
               "#workspace-member-#{owner_scope.user.id}[data-presence-state='offline']",
               "foundry_owner"
             )

      assert has_element?(
               view,
               "#workspace-member-#{member_scope.user.id}",
               member_scope.user.username
             )

      assert has_element?(
               view,
               "#workspace-member-#{owner_scope.user.id} [data-member-status='offline']",
               "Offline"
             )

      assert has_element?(view, "#channel-message-surface")
      assert has_element?(view, "#message-composer-form")
    end

    test "groups online members by role and offline members together", %{
      conn: conn,
      scope: owner_scope
    } do
      admin_scope =
        %{username: "sidebar_admin"}
        |> DiscordClone.AccountsFixtures.user_fixture()
        |> DiscordClone.AccountsFixtures.user_scope_fixture()

      member_scope =
        %{username: "sidebar_member"}
        |> DiscordClone.AccountsFixtures.user_fixture()
        |> DiscordClone.AccountsFixtures.user_scope_fixture()

      offline_scope =
        %{username: "sidebar_offline"}
        |> DiscordClone.AccountsFixtures.user_fixture()
        |> DiscordClone.AccountsFixtures.user_scope_fixture()

      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, admin_scope, "admin")
      add_workspace_member!(workspace, member_scope, "member")
      add_workspace_member!(workspace, offline_scope, "member")

      admin_live_view_pid = start_live_view_process()
      member_live_view_pid = start_live_view_process()
      assert :ok = Chat.join_workspace_presence(admin_scope, workspace.id, admin_live_view_pid)
      assert :ok = Chat.join_workspace_presence(member_scope, workspace.id, member_live_view_pid)

      {:ok, view, _html} =
        live(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      assert has_element?(view, "#workspace-members-online-owner-section", "Owner")
      assert has_element?(view, "#workspace-members-online-admin-section", "Admins")
      assert has_element?(view, "#workspace-members-online-member-section", "Members")
      assert has_element?(view, "#workspace-members-offline-section", "Offline")

      assert has_element?(
               view,
               "#workspace-members-online-owner-section + #workspace-member-#{owner_scope.user.id}[data-presence-state='online']",
               owner_scope.user.username
             )

      assert has_element?(
               view,
               "#workspace-members-online-admin-section ~ #workspace-member-#{admin_scope.user.id}[data-presence-state='online']",
               "sidebar_admin"
             )

      assert has_element?(
               view,
               "#workspace-members-online-member-section ~ #workspace-member-#{member_scope.user.id}[data-presence-state='online']",
               "sidebar_member"
             )

      assert has_element?(
               view,
               "#workspace-members-offline-section ~ #workspace-member-#{offline_scope.user.id}[data-presence-state='offline']",
               "sidebar_offline"
             )
    end

    test "does not render the offline section when every member is online", %{
      conn: conn,
      scope: scope
    } do
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})

      {:ok, view, _html} =
        live(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      refute has_element?(view, "#workspace-members-offline-section")
    end

    test "does not render the offline section in the static render of a solo workspace", %{
      conn: conn,
      scope: scope
    } do
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})

      conn = get(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      refute html_response(conn, 200) =~ "workspace-members-offline-section"
    end

    test "removes the offline header when the last offline member comes online", %{
      conn: conn,
      scope: owner_scope
    } do
      member_scope =
        %{username: "late_joiner"}
        |> DiscordClone.AccountsFixtures.user_fixture()
        |> DiscordClone.AccountsFixtures.user_scope_fixture()

      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, member_scope, "member")

      {:ok, view, _html} =
        live(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      assert has_element?(view, "#workspace-members-offline-section", "Offline")

      member_pid = start_live_view_process()
      assert :ok = Chat.join_workspace_presence(member_scope, workspace.id, member_pid)

      render(view)
      refute has_element?(view, "#workspace-members-offline-section")
    end

    test "shows moderation actions to owners and Friend Request actions to regular members", %{
      conn: owner_conn,
      scope: owner_scope
    } do
      member_scope =
        %{username: "sidebar_action_member"}
        |> DiscordClone.AccountsFixtures.user_fixture()
        |> DiscordClone.AccountsFixtures.user_scope_fixture()

      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, member_scope, "member")

      {:ok, owner_view, _html} =
        live(owner_conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      assert has_element?(owner_view, "#workspace-member-#{member_scope.user.id}-actions")

      assert has_element?(
               owner_view,
               "#workspace-member-#{member_scope.user.id}-promote-to-admin"
             )

      assert has_element?(owner_view, "#workspace-member-#{member_scope.user.id}-mute")

      assert has_element?(
               owner_view,
               "#workspace-member-#{member_scope.user.id}-timeout-5-minutes"
             )

      assert has_element?(owner_view, "#workspace-member-#{member_scope.user.id}-kick")
      assert has_element?(owner_view, "#workspace-member-#{member_scope.user.id}-ban")

      refute has_element?(owner_view, "#workspace-member-#{owner_scope.user.id}-actions")

      member_conn = build_conn() |> log_in_user(member_scope.user)

      {:ok, member_view, _html} =
        live(
          member_conn,
          ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}"
        )

      assert has_element?(member_view, "#workspace-member-#{owner_scope.user.id}")
      assert has_element?(member_view, "#workspace-member-#{owner_scope.user.id}-actions")

      assert has_element?(
               member_view,
               "#workspace-member-#{owner_scope.user.id}-send-friend-request"
             )

      refute has_element?(member_view, "#workspace-member-#{owner_scope.user.id}-mute")
      refute has_element?(member_view, "#workspace-member-#{owner_scope.user.id}-kick")
      refute has_element?(member_view, "#workspace-member-#{member_scope.user.id}-actions")
    end

    test "limits admin member row actions by target role", %{conn: conn, scope: admin_scope} do
      owner_scope =
        %{username: "sidebar_action_owner"}
        |> DiscordClone.AccountsFixtures.user_fixture()
        |> DiscordClone.AccountsFixtures.user_scope_fixture()

      peer_admin_scope =
        %{username: "sidebar_action_admin"}
        |> DiscordClone.AccountsFixtures.user_fixture()
        |> DiscordClone.AccountsFixtures.user_scope_fixture()

      member_scope =
        %{username: "sidebar_action_target"}
        |> DiscordClone.AccountsFixtures.user_fixture()
        |> DiscordClone.AccountsFixtures.user_scope_fixture()

      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, admin_scope, "admin")
      add_workspace_member!(workspace, peer_admin_scope, "admin")
      add_workspace_member!(workspace, member_scope, "member")

      {:ok, view, _html} =
        live(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      assert has_element?(view, "#workspace-member-#{owner_scope.user.id}-actions")

      assert has_element?(
               view,
               "#workspace-member-#{owner_scope.user.id}-send-friend-request"
             )

      refute has_element?(view, "#workspace-member-#{owner_scope.user.id}-mute")
      refute has_element?(view, "#workspace-member-#{owner_scope.user.id}-kick")
      refute has_element?(view, "#workspace-member-#{admin_scope.user.id}-actions")

      assert has_element?(view, "#workspace-member-#{peer_admin_scope.user.id}-actions")
      assert has_element?(view, "#workspace-member-#{peer_admin_scope.user.id}-mute")
      assert has_element?(view, "#workspace-member-#{peer_admin_scope.user.id}-timeout-5-minutes")
      refute has_element?(view, "#workspace-member-#{peer_admin_scope.user.id}-kick")
      refute has_element?(view, "#workspace-member-#{peer_admin_scope.user.id}-ban")
      refute has_element?(view, "#workspace-member-#{peer_admin_scope.user.id}-demote-to-member")

      assert has_element?(view, "#workspace-member-#{member_scope.user.id}-actions")
      assert has_element?(view, "#workspace-member-#{member_scope.user.id}-mute")
      assert has_element?(view, "#workspace-member-#{member_scope.user.id}-timeout-5-minutes")
      assert has_element?(view, "#workspace-member-#{member_scope.user.id}-kick")
      assert has_element?(view, "#workspace-member-#{member_scope.user.id}-ban")
      refute has_element?(view, "#workspace-member-#{member_scope.user.id}-promote-to-admin")
    end

    test "shows active mute controls to staff and disables only the muted user's composer", %{
      conn: owner_conn,
      scope: owner_scope
    } do
      muted_scope =
        %{username: "muted_member"}
        |> DiscordClone.AccountsFixtures.user_fixture()
        |> DiscordClone.AccountsFixtures.user_scope_fixture()

      observer_scope =
        %{username: "observer_member"}
        |> DiscordClone.AccountsFixtures.user_fixture()
        |> DiscordClone.AccountsFixtures.user_scope_fixture()

      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, muted_scope, "member")
      add_workspace_member!(workspace, observer_scope, "member")

      assert {:ok, _moderation} =
               Workspaces.mute_member(owner_scope, workspace.id, muted_scope.user.id, %{
                 "reason" => "Cooling down"
               })

      {:ok, owner_view, _html} =
        live(owner_conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      assert has_element?(owner_view, "#workspace-member-#{muted_scope.user.id}-unmute")
      refute has_element?(owner_view, "#workspace-member-#{muted_scope.user.id}-mute")

      muted_conn = build_conn() |> log_in_user(muted_scope.user)

      {:ok, muted_view, _html} =
        live(
          muted_conn,
          ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}"
        )

      assert has_element?(muted_view, "#message_content[disabled]")
      assert has_element?(muted_view, "#message-composer-muted-feedback", "muted")

      observer_conn = build_conn() |> log_in_user(observer_scope.user)

      {:ok, observer_view, _html} =
        live(
          observer_conn,
          ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}"
        )

      assert has_element?(observer_view, "#workspace-member-#{muted_scope.user.id}")
      refute has_element?(observer_view, "#workspace-member-#{muted_scope.user.id}-unmute")
      refute has_element?(observer_view, "#message-composer-muted-feedback")
    end

    test "refreshes connected channel surfaces after mute and unmute actions", %{
      conn: owner_conn,
      scope: owner_scope
    } do
      target_scope =
        %{username: "live_muted_member"}
        |> DiscordClone.AccountsFixtures.user_fixture()
        |> DiscordClone.AccountsFixtures.user_scope_fixture()

      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, target_scope, "member")

      {:ok, owner_view, _html} =
        live(owner_conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      target_conn = build_conn() |> log_in_user(target_scope.user)

      {:ok, target_view, _html} =
        live(
          target_conn,
          ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}"
        )

      refute has_element?(target_view, "#message-composer-muted-feedback")

      owner_view
      |> element("#workspace-member-#{target_scope.user.id}-mute")
      |> render_click()

      render(target_view)
      assert has_element?(target_view, "#message-composer-muted-feedback")
      assert has_element?(owner_view, "#workspace-member-#{target_scope.user.id}-unmute")

      owner_view
      |> element("#workspace-member-#{target_scope.user.id}-unmute")
      |> render_click()

      render(target_view)
      refute has_element?(target_view, "#message-composer-muted-feedback")
      assert has_element?(owner_view, "#workspace-member-#{target_scope.user.id}-mute")
    end

    test "promotes a member to admin from the member menu and refreshes the controls", %{
      conn: owner_conn,
      scope: owner_scope
    } do
      target_scope =
        %{username: "promotable_member"}
        |> DiscordClone.AccountsFixtures.user_fixture()
        |> DiscordClone.AccountsFixtures.user_scope_fixture()

      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, target_scope, "member")

      {:ok, owner_view, _html} =
        live(owner_conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      owner_view
      |> element("#workspace-member-#{target_scope.user.id}-promote-to-admin")
      |> render_click()

      assert Repo.get_by(WorkspaceMembership,
               workspace_id: workspace.id,
               user_id: target_scope.user.id
             ).role == "admin"

      assert has_element?(
               owner_view,
               "#workspace-member-#{target_scope.user.id}-demote-to-member"
             )

      refute has_element?(
               owner_view,
               "#workspace-member-#{target_scope.user.id}-promote-to-admin"
             )
    end

    test "moves an online promoted member into the admins section from a broadcast", %{
      conn: owner_conn,
      scope: owner_scope
    } do
      target_scope =
        %{username: "broadcast_promotable"}
        |> DiscordClone.AccountsFixtures.user_fixture()
        |> DiscordClone.AccountsFixtures.user_scope_fixture()

      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, target_scope, "member")

      target_live_view_pid = start_live_view_process()
      assert :ok = Chat.join_workspace_presence(target_scope, workspace.id, target_live_view_pid)

      {:ok, owner_view, _html} =
        live(owner_conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      assert has_element?(
               owner_view,
               "#workspace-members-online-member-section ~ #workspace-member-#{target_scope.user.id}[data-presence-state='online']",
               "broadcast_promotable"
             )

      assert {:ok, _membership} =
               Workspaces.change_member_role(
                 owner_scope,
                 workspace.id,
                 target_scope.user.id,
                 "admin"
               )

      render(owner_view)

      assert has_element?(
               owner_view,
               "#workspace-members-online-admin-section ~ #workspace-member-#{target_scope.user.id}[data-presence-state='online']",
               "broadcast_promotable"
             )
    end

    test "demotes an admin to member from the member menu and refreshes the controls", %{
      conn: owner_conn,
      scope: owner_scope
    } do
      target_scope =
        %{username: "demotable_admin"}
        |> DiscordClone.AccountsFixtures.user_fixture()
        |> DiscordClone.AccountsFixtures.user_scope_fixture()

      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, target_scope, "admin")

      {:ok, owner_view, _html} =
        live(owner_conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      owner_view
      |> element("#workspace-member-#{target_scope.user.id}-demote-to-member")
      |> render_click()

      assert Repo.get_by(WorkspaceMembership,
               workspace_id: workspace.id,
               user_id: target_scope.user.id
             ).role == "member"

      assert has_element?(
               owner_view,
               "#workspace-member-#{target_scope.user.id}-promote-to-admin"
             )

      refute has_element?(
               owner_view,
               "#workspace-member-#{target_scope.user.id}-demote-to-member"
             )
    end

    test "shows timeout preset controls and disables the timed-out user's composer", %{
      conn: owner_conn,
      scope: owner_scope
    } do
      target_scope =
        %{username: "timed_out_member"}
        |> DiscordClone.AccountsFixtures.user_fixture()
        |> DiscordClone.AccountsFixtures.user_scope_fixture()

      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, target_scope, "member")

      {:ok, owner_view, _html} =
        live(owner_conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      assert has_element?(
               owner_view,
               "#workspace-member-#{target_scope.user.id}-timeout-5-minutes"
             )

      owner_view
      |> element("#workspace-member-#{target_scope.user.id}-timeout-5-minutes")
      |> render_click()

      assert has_element?(owner_view, "#workspace-member-#{target_scope.user.id}-remove-timeout")

      target_conn = build_conn() |> log_in_user(target_scope.user)

      {:ok, target_view, _html} =
        live(
          target_conn,
          ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}"
        )

      assert has_element?(target_view, "#message_content[disabled]")
      assert has_element?(target_view, "#message-composer-muted-feedback", "timed out")
    end

    test "kicks a member with a reason, removes them live, and redirects the kicked user", %{
      conn: owner_conn,
      scope: owner_scope
    } do
      target_scope =
        %{username: "kick_target_member"}
        |> DiscordClone.AccountsFixtures.user_fixture()
        |> DiscordClone.AccountsFixtures.user_scope_fixture()

      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, target_scope, "member")

      {:ok, owner_view, _html} =
        live(owner_conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      target_conn = build_conn() |> log_in_user(target_scope.user)

      {:ok, target_view, _html} =
        live(
          target_conn,
          ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}"
        )

      assert has_element?(owner_view, "#workspace-member-#{target_scope.user.id}-kick")

      owner_view
      |> form("#workspace-member-#{target_scope.user.id}-kick-form", %{reason: "Repeated spam"})
      |> render_submit()

      assert_redirect(target_view, ~p"/workspaces")

      refute has_element?(owner_view, "#workspace-member-#{target_scope.user.id}")

      refute Repo.get_by(WorkspaceMembership,
               workspace_id: workspace.id,
               user_id: target_scope.user.id
             )

      assert {:ok, events} = Workspaces.list_audit_events(owner_scope, workspace.id)

      assert Enum.any?(
               events,
               &(&1.event_type == "member_kicked" and &1.reason == "Repeated spam")
             )
    end

    test "rejects a kick submitted without a reason", %{conn: owner_conn, scope: owner_scope} do
      target_scope =
        %{username: "kick_reason_member"}
        |> DiscordClone.AccountsFixtures.user_fixture()
        |> DiscordClone.AccountsFixtures.user_scope_fixture()

      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, target_scope, "member")

      {:ok, owner_view, _html} =
        live(owner_conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      html =
        owner_view
        |> form("#workspace-member-#{target_scope.user.id}-kick-form", %{reason: "   "})
        |> render_submit()

      assert html =~ "reason is required"
      assert has_element?(owner_view, "#workspace-member-#{target_scope.user.id}")

      assert Repo.get_by(WorkspaceMembership,
               workspace_id: workspace.id,
               user_id: target_scope.user.id
             )
    end

    test "bans a member with a reason, removes them live, and redirects the banned user", %{
      conn: owner_conn,
      scope: owner_scope
    } do
      target_scope =
        %{username: "ban_target_member"}
        |> DiscordClone.AccountsFixtures.user_fixture()
        |> DiscordClone.AccountsFixtures.user_scope_fixture()

      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, target_scope, "member")

      {:ok, owner_view, _html} =
        live(owner_conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      target_conn = build_conn() |> log_in_user(target_scope.user)

      {:ok, target_view, _html} =
        live(
          target_conn,
          ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}"
        )

      assert has_element?(owner_view, "#workspace-member-#{target_scope.user.id}-ban")

      owner_view
      |> form("#workspace-member-#{target_scope.user.id}-ban-form", %{reason: "Persistent abuse"})
      |> render_submit()

      assert_redirect(target_view, ~p"/workspaces")

      refute has_element?(owner_view, "#workspace-member-#{target_scope.user.id}")

      refute Repo.get_by(WorkspaceMembership,
               workspace_id: workspace.id,
               user_id: target_scope.user.id
             )

      assert Workspaces.workspace_banned?(workspace.id, target_scope.user.id)

      assert {:ok, events} = Workspaces.list_audit_events(owner_scope, workspace.id)

      assert Enum.any?(
               events,
               &(&1.event_type == "member_banned" and &1.reason == "Persistent abuse")
             )
    end

    test "rejects a ban submitted without a reason", %{conn: owner_conn, scope: owner_scope} do
      target_scope =
        %{username: "ban_reason_member"}
        |> DiscordClone.AccountsFixtures.user_fixture()
        |> DiscordClone.AccountsFixtures.user_scope_fixture()

      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, target_scope, "member")

      {:ok, owner_view, _html} =
        live(owner_conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      html =
        owner_view
        |> form("#workspace-member-#{target_scope.user.id}-ban-form", %{reason: "   "})
        |> render_submit()

      assert html =~ "reason is required"
      assert has_element?(owner_view, "#workspace-member-#{target_scope.user.id}")

      assert Repo.get_by(WorkspaceMembership,
               workspace_id: workspace.id,
               user_id: target_scope.user.id
             )

      refute Workspaces.workspace_banned?(workspace.id, target_scope.user.id)
    end

    test "bans a member with a cleanup window and refreshes affected messages live", %{
      conn: owner_conn,
      scope: owner_scope
    } do
      target_scope =
        %{username: "ban_cleanup_member"}
        |> DiscordClone.AccountsFixtures.user_fixture()
        |> DiscordClone.AccountsFixtures.user_scope_fixture()

      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, target_scope, "member")

      {:ok, message} =
        Chat.send_message(target_scope, workspace.default_channel_id, %{
          "content" => "cleanup me"
        })

      {:ok, owner_view, html} =
        live(owner_conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      assert html =~ "cleanup me"

      assert has_element?(
               owner_view,
               "#workspace-member-#{target_scope.user.id}-ban-form input[name='cleanup_window'][value='all']"
             )

      owner_view
      |> form("#workspace-member-#{target_scope.user.id}-ban-form", %{
        reason: "Persistent abuse",
        cleanup_window: "all"
      })
      |> render_submit()

      assert Repo.get(Message, message.id).deleted_at

      updated_html = render(owner_view)
      assert updated_html =~ "Message deleted"
      refute updated_html =~ "cleanup me"

      assert {:ok, events} = Workspaces.list_audit_events(owner_scope, workspace.id)
      ban_event = Enum.find(events, &(&1.event_type == "member_banned"))
      assert ban_event.metadata["cleanup_window"] == "all"
      assert ban_event.metadata["cleanup_message_count"] == 1
    end

    test "hides the all-messages cleanup option from admins in the ban form", %{
      conn: admin_conn,
      scope: admin_scope
    } do
      owner_scope =
        %{username: "ban_cleanup_owner"}
        |> DiscordClone.AccountsFixtures.user_fixture()
        |> DiscordClone.AccountsFixtures.user_scope_fixture()

      member_scope =
        %{username: "ban_cleanup_target"}
        |> DiscordClone.AccountsFixtures.user_fixture()
        |> DiscordClone.AccountsFixtures.user_scope_fixture()

      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, admin_scope, "admin")
      add_workspace_member!(workspace, member_scope, "member")

      {:ok, admin_view, _html} =
        live(admin_conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      assert has_element?(
               admin_view,
               "#workspace-member-#{member_scope.user.id}-ban-form input[name='cleanup_window'][value='24_hours']"
             )

      refute has_element?(
               admin_view,
               "#workspace-member-#{member_scope.user.id}-ban-form input[name='cleanup_window'][value='all']"
             )
    end

    test "renders durable members offline after workspace presence runtime loss", %{
      conn: conn,
      scope: member_scope
    } do
      other_scope =
        %{username: "runtime_loss_member"}
        |> DiscordClone.AccountsFixtures.user_fixture()
        |> DiscordClone.AccountsFixtures.user_scope_fixture()

      {:ok, workspace} = Workspaces.create_workspace(member_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, other_scope)

      other_live_view_pid = start_live_view_process()
      assert :ok = Chat.join_workspace_presence(other_scope, workspace.id, other_live_view_pid)
      workspace_pid = Runtime.workspace_presence_pid(workspace.id)
      assert is_pid(workspace_pid)

      ref = Process.monitor(workspace_pid)
      Process.exit(workspace_pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^workspace_pid, :killed}
      _ = :sys.get_state(DiscordClone.Chat.WorkspaceSupervisor)

      {:ok, view, _html} =
        live(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      assert has_element?(view, "#workspace-members-sidebar[aria-label='Workspace members']")

      assert has_element?(
               view,
               "#workspace-member-#{other_scope.user.id}[data-presence-state='offline']",
               "runtime_loss_member"
             )

      assert has_element?(
               view,
               "#workspace-member-#{other_scope.user.id} [data-member-status='offline']",
               "Offline"
             )
    end

    test "marks the current member online after entering a channel surface", %{
      conn: conn,
      scope: member_scope
    } do
      owner_scope =
        %{username: "presence_owner"}
        |> DiscordClone.AccountsFixtures.user_fixture()
        |> DiscordClone.AccountsFixtures.user_scope_fixture()

      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, member_scope)

      {:ok, view, _html} =
        live(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      assert has_element?(
               view,
               "#workspace-member-#{member_scope.user.id}[data-presence-state='online']",
               member_scope.user.username
             )

      assert has_element?(
               view,
               "#workspace-member-#{member_scope.user.id} [data-member-status='online']",
               "Online"
             )

      assert has_element?(
               view,
               "#workspace-member-#{owner_scope.user.id}[data-presence-state='offline']",
               "presence_owner"
             )
    end

    test "marks another member online when they enter the same workspace without refresh", %{
      conn: conn,
      scope: receiver_scope
    } do
      sender_scope =
        %{username: "live_presence_sender"}
        |> DiscordClone.AccountsFixtures.user_fixture()
        |> DiscordClone.AccountsFixtures.user_scope_fixture()

      {:ok, workspace} = Workspaces.create_workspace(receiver_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, sender_scope)
      channel_path = ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}"
      sender_conn = build_conn() |> log_in_user(sender_scope.user)

      {:ok, receiver_view, _html} = live(conn, channel_path)

      assert has_element?(
               receiver_view,
               "#workspace-member-#{sender_scope.user.id}[data-presence-state='offline']",
               "live_presence_sender"
             )

      {:ok, _sender_view, _html} = live(sender_conn, channel_path)

      assert has_element?(
               receiver_view,
               "#workspace-member-#{sender_scope.user.id}[data-presence-state='online']",
               "live_presence_sender"
             )

      assert has_element?(
               receiver_view,
               "#workspace-member-#{sender_scope.user.id} [data-member-status='online']",
               "Online"
             )
    end

    test "marks another member offline when their last channel surface closes without refresh", %{
      conn: conn,
      scope: receiver_scope
    } do
      sender_scope =
        %{username: "live_presence_leaver"}
        |> DiscordClone.AccountsFixtures.user_fixture()
        |> DiscordClone.AccountsFixtures.user_scope_fixture()

      {:ok, workspace} = Workspaces.create_workspace(receiver_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, sender_scope)
      channel_path = ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}"
      sender_conn = build_conn() |> log_in_user(sender_scope.user)

      {:ok, receiver_view, _html} = live(conn, channel_path)
      :ok = Chat.subscribe_to_workspace_presence(receiver_scope, workspace.id)
      {:ok, sender_view, _html} = live(sender_conn, channel_path)

      assert_receive {:workspace_user_joined,
                      %{workspace_id: workspace_id, user_id: sender_user_id}}

      assert workspace_id == workspace.id
      assert sender_user_id == sender_scope.user.id

      assert has_element?(
               receiver_view,
               "#workspace-member-#{sender_scope.user.id}[data-presence-state='online']",
               "live_presence_leaver"
             )

      workspace_server = Runtime.workspace_presence_pid(workspace.id)
      _ = :sys.get_state(workspace_server)

      ref = Process.monitor(sender_view.pid)
      Process.flag(:trap_exit, true)
      Process.exit(sender_view.pid, :shutdown)
      assert_receive {:DOWN, ^ref, :process, _pid, :shutdown}
      _ = :sys.get_state(workspace_server)

      assert_receive {:workspace_user_left,
                      %{workspace_id: ^workspace_id, user_id: ^sender_user_id}},
                     6_000

      assert has_element?(
               receiver_view,
               "#workspace-member-#{sender_scope.user.id}[data-presence-state='offline']",
               "live_presence_leaver"
             )

      assert has_element?(
               receiver_view,
               "#workspace-member-#{sender_scope.user.id} [data-member-status='offline']",
               "Offline"
             )
    end

    test "keeps another member online until their final connected surface closes", %{
      conn: conn,
      scope: receiver_scope
    } do
      sender_scope =
        %{username: "multi_surface_member"}
        |> DiscordClone.AccountsFixtures.user_fixture()
        |> DiscordClone.AccountsFixtures.user_scope_fixture()

      {:ok, workspace} = Workspaces.create_workspace(receiver_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, sender_scope)
      channel_path = ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}"
      first_sender_conn = build_conn() |> log_in_user(sender_scope.user)
      second_sender_conn = build_conn() |> log_in_user(sender_scope.user)

      {:ok, receiver_view, _html} = live(conn, channel_path)
      :ok = Chat.subscribe_to_workspace_presence(receiver_scope, workspace.id)
      {:ok, first_sender_view, _html} = live(first_sender_conn, channel_path)

      assert_receive {:workspace_user_joined,
                      %{workspace_id: workspace_id, user_id: sender_user_id}}

      assert workspace_id == workspace.id
      assert sender_user_id == sender_scope.user.id

      {:ok, second_sender_view, _html} = live(second_sender_conn, channel_path)

      assert has_element?(
               receiver_view,
               "#workspace-member-#{sender_scope.user.id}[data-presence-state='online']",
               "multi_surface_member"
             )

      assert workspace_member_row_ids(receiver_view, sender_scope.user.id) == [
               "workspace-member-#{sender_scope.user.id}"
             ]

      workspace_server = Runtime.workspace_presence_pid(workspace.id)
      _ = :sys.get_state(workspace_server)

      Process.flag(:trap_exit, true)
      first_ref = Process.monitor(first_sender_view.pid)
      Process.exit(first_sender_view.pid, :shutdown)
      assert_receive {:DOWN, ^first_ref, :process, _pid, :shutdown}
      _ = :sys.get_state(workspace_server)

      assert has_element?(
               receiver_view,
               "#workspace-member-#{sender_scope.user.id}[data-presence-state='online']",
               "multi_surface_member"
             )

      assert workspace_member_row_ids(receiver_view, sender_scope.user.id) == [
               "workspace-member-#{sender_scope.user.id}"
             ]

      second_ref = Process.monitor(second_sender_view.pid)
      Process.exit(second_sender_view.pid, :shutdown)
      assert_receive {:DOWN, ^second_ref, :process, _pid, :shutdown}
      _ = :sys.get_state(workspace_server)

      assert_receive {:workspace_user_left,
                      %{workspace_id: ^workspace_id, user_id: ^sender_user_id}},
                     6_000

      assert has_element?(
               receiver_view,
               "#workspace-member-#{sender_scope.user.id}[data-presence-state='offline']",
               "multi_surface_member"
             )

      assert has_element?(
               receiver_view,
               "#workspace-member-#{sender_scope.user.id} [data-member-status='offline']",
               "Offline"
             )
    end

    test "keeps another member online while they switch channels in the same workspace", %{
      conn: conn,
      scope: receiver_scope
    } do
      sender_scope =
        %{username: "channel_switch_member"}
        |> DiscordClone.AccountsFixtures.user_fixture()
        |> DiscordClone.AccountsFixtures.user_scope_fixture()

      {:ok, workspace} = Workspaces.create_workspace(receiver_scope, %{name: "Foundry"})

      {:ok, other_channel} =
        Workspaces.create_channel(receiver_scope, workspace.id, %{name: "Ops"})

      add_workspace_member!(workspace, sender_scope)

      first_channel_path =
        ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}"

      other_channel_path = ~p"/workspaces/#{workspace.id}/channels/#{other_channel.id}"
      sender_conn = build_conn() |> log_in_user(sender_scope.user)

      {:ok, receiver_view, _html} = live(conn, first_channel_path)
      :ok = Chat.subscribe_to_workspace_presence(receiver_scope, workspace.id)
      {:ok, sender_view, _html} = live(sender_conn, first_channel_path)

      assert_receive {:workspace_user_joined, %{workspace_id: workspace_id, user_id: user_id}}

      assert workspace_id == workspace.id
      assert user_id == sender_scope.user.id

      assert has_element?(
               receiver_view,
               "#workspace-member-#{sender_scope.user.id}[data-presence-state='online']",
               "channel_switch_member"
             )

      workspace_id = workspace.id
      sender_user_id = sender_scope.user.id

      {:ok, _sender_view, _html} =
        sender_view
        |> element("#channel-#{other_channel.id} a")
        |> render_click()
        |> follow_redirect(sender_conn, other_channel_path)

      workspace_server = Runtime.workspace_presence_pid(workspace.id)
      _ = :sys.get_state(workspace_server)

      refute_receive {:workspace_user_left,
                      %{workspace_id: ^workspace_id, user_id: ^sender_user_id}},
                     50

      assert has_element?(
               receiver_view,
               "#workspace-member-#{sender_scope.user.id}[data-presence-state='online']",
               "channel_switch_member"
             )
    end

    test "keeps member rows stable when duplicate presence events arrive", %{
      conn: conn,
      scope: receiver_scope
    } do
      other_scope =
        %{username: "stable_presence_member"}
        |> DiscordClone.AccountsFixtures.user_fixture()
        |> DiscordClone.AccountsFixtures.user_scope_fixture()

      {:ok, workspace} = Workspaces.create_workspace(receiver_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, other_scope)

      {:ok, view, _html} =
        live(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      joined_event =
        {:workspace_user_joined, %{workspace_id: workspace.id, user_id: other_scope.user.id}}

      send(view.pid, joined_event)
      send(view.pid, joined_event)

      assert has_element?(
               view,
               "#workspace-member-#{other_scope.user.id}[data-presence-state='online']",
               "stable_presence_member"
             )

      assert workspace_member_row_ids(view, other_scope.user.id) == [
               "workspace-member-#{other_scope.user.id}"
             ]

      left_event =
        {:workspace_user_left, %{workspace_id: workspace.id, user_id: other_scope.user.id}}

      send(view.pid, left_event)
      send(view.pid, left_event)

      assert has_element?(
               view,
               "#workspace-member-#{other_scope.user.id}[data-presence-state='offline']",
               "stable_presence_member"
             )

      assert workspace_member_row_ids(view, other_scope.user.id) == [
               "workspace-member-#{other_scope.user.id}"
             ]
    end
  end
end
