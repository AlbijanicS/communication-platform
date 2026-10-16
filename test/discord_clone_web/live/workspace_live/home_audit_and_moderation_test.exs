defmodule DiscordCloneWeb.WorkspaceLive.HomeAuditAndModerationTest do
  use DiscordCloneWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import DiscordCloneWeb.WorkspaceLiveTestHelpers

  alias DiscordClone.Workspaces
  alias DiscordClone.Chat
  alias DiscordClone.Workspaces.WorkspaceMembership
  alias DiscordClone.Repo

  describe "/workspaces/:workspace_id/audit-log" do
    setup :register_and_log_in_user

    test "lists newest audit events for owners", %{conn: conn, scope: owner_scope} do
      admin_scope =
        DiscordClone.AccountsFixtures.user_fixture(%{username: "admin_user"})
        |> DiscordClone.AccountsFixtures.user_scope_fixture()

      member_scope =
        DiscordClone.AccountsFixtures.user_fixture(%{username: "member_user"})
        |> DiscordClone.AccountsFixtures.user_scope_fixture()

      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, admin_scope, "admin")
      add_workspace_member!(workspace, member_scope, "member")

      assert {:ok, _membership} =
               Workspaces.change_member_role(
                 owner_scope,
                 workspace.id,
                 member_scope.user.id,
                 "admin"
               )

      assert {:ok, _membership} =
               Workspaces.change_member_role(
                 owner_scope,
                 workspace.id,
                 admin_scope.user.id,
                 "member"
               )

      {:ok, view, _html} = live(conn, ~p"/workspaces/#{workspace.id}/audit-log")

      assert has_element?(view, "#workspace-audit-log")
      assert has_element?(view, "#workspace-audit-events")
      assert has_element?(view, "#workspace-audit-events article:first-child", "admin_user")
      assert has_element?(view, "#workspace-audit-events article:first-child", "demoted")
      assert has_element?(view, "#workspace-audit-events article:last-child", "member_user")
      assert has_element?(view, "#workspace-audit-events article:last-child", "promoted")
    end

    test "shows the channel context for a moderator message delete", %{
      conn: conn,
      scope: owner_scope
    } do
      member_scope =
        DiscordClone.AccountsFixtures.user_fixture(%{username: "member_user"})
        |> DiscordClone.AccountsFixtures.user_scope_fixture()

      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, member_scope, "member")

      {:ok, message} =
        Chat.send_message(member_scope, workspace.default_channel_id, %{
          "content" => "needs moderation"
        })

      assert {:ok, _deleted} = Chat.delete_message(owner_scope, message.id)

      {:ok, view, _html} = live(conn, ~p"/workspaces/#{workspace.id}/audit-log")

      assert has_element?(
               view,
               "#workspace-audit-events article:first-child",
               "deleted a message by member_user in #general"
             )
    end

    test "redirects admins and members away from the audit log", %{
      conn: owner_conn,
      scope: owner_scope
    } do
      admin_scope = DiscordClone.AccountsFixtures.user_scope_fixture()
      member_scope = DiscordClone.AccountsFixtures.user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, admin_scope, "admin")
      add_workspace_member!(workspace, member_scope, "member")

      admin_conn = build_conn() |> log_in_user(admin_scope.user)
      member_conn = build_conn() |> log_in_user(member_scope.user)

      assert {:error, {:redirect, %{to: admin_path, flash: admin_flash}}} =
               live(admin_conn, ~p"/workspaces/#{workspace.id}/audit-log")

      assert admin_path == ~p"/workspaces/#{workspace.id}"
      assert admin_flash["error"] =~ "Only workspace owners can view the audit log"

      assert {:error, {:redirect, %{to: member_path, flash: member_flash}}} =
               live(member_conn, ~p"/workspaces/#{workspace.id}/audit-log")

      assert member_path == ~p"/workspaces/#{workspace.id}"
      assert member_flash["error"] =~ "Only workspace owners can view the audit log"

      {:ok, _view, _html} = live(owner_conn, ~p"/workspaces/#{workspace.id}/audit-log")
    end

    test "owners can view banned members and unban them from the audit log", %{
      conn: conn,
      scope: owner_scope
    } do
      banned_scope =
        DiscordClone.AccountsFixtures.user_fixture(%{username: "banished_user"})
        |> DiscordClone.AccountsFixtures.user_scope_fixture()

      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, banned_scope, "member")

      assert {:ok, _ban} =
               Workspaces.ban_member(owner_scope, workspace.id, banned_scope.user.id, %{
                 "reason" => "Persistent spam"
               })

      {:ok, view, _html} = live(conn, ~p"/workspaces/#{workspace.id}/audit-log")

      assert has_element?(view, "#workspace-banned-members")
      assert has_element?(view, "#workspace-banned-members", "banished_user")

      view
      |> element("#workspace-banned-members button[phx-value-user_id='#{banned_scope.user.id}']")
      |> render_click()

      refute Workspaces.workspace_banned?(workspace.id, banned_scope.user.id)
      refute has_element?(view, "#workspace-banned-members", "banished_user")
      assert has_element?(view, "#workspace-banned-members-empty-state")
    end

    test "promotes a member from the audit-log member menu and logs the event", %{
      conn: conn,
      scope: owner_scope
    } do
      target_scope =
        DiscordClone.AccountsFixtures.user_fixture(%{username: "audit_promotable"})
        |> DiscordClone.AccountsFixtures.user_scope_fixture()

      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, target_scope, "member")

      {:ok, view, _html} = live(conn, ~p"/workspaces/#{workspace.id}/audit-log")

      view
      |> element("#workspace-member-#{target_scope.user.id}-promote-to-admin")
      |> render_click()

      assert Repo.get_by(WorkspaceMembership,
               workspace_id: workspace.id,
               user_id: target_scope.user.id
             ).role == "admin"

      assert has_element?(view, "#workspace-member-#{target_scope.user.id}-demote-to-member")
      assert has_element?(view, "#workspace-audit-events article:first-child", "promoted")
    end

    test "refreshes when an admin action creates an audit event elsewhere", %{
      conn: owner_conn,
      scope: owner_scope
    } do
      admin_scope =
        DiscordClone.AccountsFixtures.user_fixture(%{username: "remote_admin_actor"})
        |> DiscordClone.AccountsFixtures.user_scope_fixture()

      target_scope =
        DiscordClone.AccountsFixtures.user_fixture(%{username: "remote_audit_target"})
        |> DiscordClone.AccountsFixtures.user_scope_fixture()

      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, admin_scope, "admin")
      add_workspace_member!(workspace, target_scope, "member")

      {:ok, audit_view, _html} = live(owner_conn, ~p"/workspaces/#{workspace.id}/audit-log")

      admin_conn = build_conn() |> log_in_user(admin_scope.user)

      {:ok, admin_view, _html} =
        live(admin_conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      admin_view
      |> element("#workspace-member-#{target_scope.user.id}-mute")
      |> render_click()

      render(audit_view)

      assert has_element?(
               audit_view,
               "#workspace-audit-events article:first-child",
               "remote_admin_actor muted remote_audit_target"
             )
    end

    test "refreshes the channel sidebar when a channel is created elsewhere", %{
      conn: conn,
      scope: owner_scope
    } do
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})

      {:ok, view, _html} = live(conn, ~p"/workspaces/#{workspace.id}/audit-log")

      assert {:ok, channel} =
               Workspaces.create_channel(owner_scope, workspace.id, %{name: "Logistics"})

      render(view)

      assert has_element?(view, "#channel-#{channel.id}", "# logistics")
    end

    test "refreshes the member list when a new member joins via invite", %{
      conn: conn,
      scope: owner_scope
    } do
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      {:ok, invite} = Workspaces.create_workspace_invite(owner_scope, workspace.id)

      joiner_scope =
        DiscordClone.AccountsFixtures.user_fixture(%{username: "audit_join_watcher"})
        |> DiscordClone.AccountsFixtures.user_scope_fixture()

      {:ok, view, _html} = live(conn, ~p"/workspaces/#{workspace.id}/audit-log")

      refute has_element?(view, "#workspace-member-#{joiner_scope.user.id}")

      assert {:ok, _result} = Workspaces.accept_workspace_invite(joiner_scope, invite.code)

      render(view)

      assert has_element?(
               view,
               "#workspace-member-#{joiner_scope.user.id}",
               "audit_join_watcher"
             )
    end

    test "renders invite-join and unban audit entries", %{conn: conn, scope: owner_scope} do
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      {:ok, invite} = Workspaces.create_workspace_invite(owner_scope, workspace.id)

      joiner_scope =
        DiscordClone.AccountsFixtures.user_fixture(%{username: "history_member"})
        |> DiscordClone.AccountsFixtures.user_scope_fixture()

      assert {:ok, _result} = Workspaces.accept_workspace_invite(joiner_scope, invite.code)

      assert {:ok, _ban} =
               Workspaces.ban_member(owner_scope, workspace.id, joiner_scope.user.id, %{
                 "reason" => "spam"
               })

      assert {:ok, _unban} =
               Workspaces.unban_member(owner_scope, workspace.id, joiner_scope.user.id)

      {:ok, view, _html} = live(conn, ~p"/workspaces/#{workspace.id}/audit-log")

      assert has_element?(
               view,
               "#workspace-audit-events",
               "joined from an invite created by"
             )

      assert has_element?(view, "#workspace-audit-events article:first-child", "unbanned")
    end
  end

  describe "moderation live refresh and access-loss hardening" do
    setup :register_and_log_in_user

    test "re-enables the timed-out user's composer live when the timeout expires", %{
      conn: owner_conn,
      scope: owner_scope
    } do
      target_scope =
        %{username: "expiring_timeout_member"}
        |> DiscordClone.AccountsFixtures.user_fixture()
        |> DiscordClone.AccountsFixtures.user_scope_fixture()

      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, target_scope, "member")

      {:ok, owner_view, _html} =
        live(owner_conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      owner_view
      |> element("#workspace-member-#{target_scope.user.id}-timeout-5-minutes")
      |> render_click()

      target_conn = build_conn() |> log_in_user(target_scope.user)

      {:ok, target_view, _html} =
        live(
          target_conn,
          ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}"
        )

      assert has_element?(target_view, "#message_content[disabled]")

      expire_active_timeout!(workspace.id, target_scope.user.id)

      render(target_view)
      refute has_element?(target_view, "#message_content[disabled]")
      refute has_element?(target_view, "#message-composer-muted-feedback")
    end

    test "re-enables the timed-out user's composer live when a moderator removes the timeout", %{
      conn: owner_conn,
      scope: owner_scope
    } do
      target_scope =
        %{username: "manual_removed_timeout_member"}
        |> DiscordClone.AccountsFixtures.user_fixture()
        |> DiscordClone.AccountsFixtures.user_scope_fixture()

      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, target_scope, "member")

      {:ok, owner_view, _html} =
        live(owner_conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      owner_view
      |> element("#workspace-member-#{target_scope.user.id}-timeout-5-minutes")
      |> render_click()

      target_conn = build_conn() |> log_in_user(target_scope.user)

      {:ok, target_view, _html} =
        live(
          target_conn,
          ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}"
        )

      assert has_element?(target_view, "#message_content[disabled]")

      owner_view
      |> element("#workspace-member-#{target_scope.user.id}-remove-timeout")
      |> render_click()

      render(target_view)
      refute has_element?(target_view, "#message_content[disabled]")
      refute has_element?(target_view, "#message-composer-muted-feedback")
    end

    test "keeps the composer blocked after timeout expiry when a mute is still active", %{
      conn: owner_conn,
      scope: owner_scope
    } do
      target_scope =
        %{username: "muted_and_timed_out_member"}
        |> DiscordClone.AccountsFixtures.user_fixture()
        |> DiscordClone.AccountsFixtures.user_scope_fixture()

      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, target_scope, "member")

      {:ok, owner_view, _html} =
        live(owner_conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      owner_view
      |> element("#workspace-member-#{target_scope.user.id}-timeout-5-minutes")
      |> render_click()

      owner_view
      |> element("#workspace-member-#{target_scope.user.id}-mute")
      |> render_click()

      target_conn = build_conn() |> log_in_user(target_scope.user)

      {:ok, target_view, _html} =
        live(
          target_conn,
          ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}"
        )

      assert has_element?(target_view, "#message_content[disabled]")

      expire_active_timeout!(workspace.id, target_scope.user.id)

      render(target_view)
      assert has_element?(target_view, "#message_content[disabled]")
      assert has_element?(target_view, "#message-composer-muted-feedback", "muted")
    end

    test "moderation broadcasts to regular members carry no private moderation details", %{
      scope: owner_scope
    } do
      member_scope =
        %{username: "plain_member_subscriber"}
        |> DiscordClone.AccountsFixtures.user_fixture()
        |> DiscordClone.AccountsFixtures.user_scope_fixture()

      target_scope =
        %{username: "reported_member"}
        |> DiscordClone.AccountsFixtures.user_fixture()
        |> DiscordClone.AccountsFixtures.user_scope_fixture()

      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, member_scope, "member")
      add_workspace_member!(workspace, target_scope, "member")

      :ok = Workspaces.subscribe_to_workspace_moderation(member_scope, workspace.id)

      {:ok, _moderation} =
        Workspaces.mute_member(owner_scope, workspace.id, target_scope.user.id, %{
          "reason" => "leaking private channel secrets"
        })

      assert_receive {:workspace_moderation_changed, payload}

      assert payload == %{workspace_id: workspace.id, target_user_id: target_scope.user.id}
    end
  end

  # Simulates the runtime timer firing on a naturally expired timeout: backdate
  # the active timeout's expiry into the past, then run the same expiry the
  # WorkspaceServer timer invokes.
end
