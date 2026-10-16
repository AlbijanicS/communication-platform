defmodule DiscordCloneWeb.WorkspaceLive.HomeInvitesTest do
  use DiscordCloneWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import DiscordCloneWeb.WorkspaceLiveTestHelpers

  alias DiscordClone.Workspaces
  alias DiscordClone.Workspaces.{WorkspaceInvite, WorkspaceMembership}
  alias DiscordClone.Repo

  describe "/workspaces/:workspace_id/invites/new" do
    setup :register_and_log_in_user

    test "hides the invite action from non-owner members in owner-only workspaces", %{
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

      refute has_element?(view, "#workspace-#{workspace.id}-invite-new")
    end

    test "shows the invite action to admins", %{
      conn: conn,
      scope: admin_scope
    } do
      owner_scope = DiscordClone.AccountsFixtures.user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, admin_scope, "admin")

      {:ok, view, _html} =
        live(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      view
      |> element("#workspace-#{workspace.id}-actions")
      |> render_click()

      assert has_element?(view, "#workspace-#{workspace.id}-invite-new")
    end

    test "renders the workspace shell without creating an invite", %{conn: conn, scope: scope} do
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})

      {:ok, view, _html} = live(conn, ~p"/workspaces/#{workspace.id}/invites/new")

      view
      |> element("#workspace-#{workspace.id}-actions")
      |> render_click()

      assert has_element?(view, "#workspace-app-shell")
      assert has_element?(view, "#workspace-#{workspace.id}[aria-current='page']")
      assert has_element?(view, "#workspace-#{workspace.id}-invite-new")
      assert has_element?(view, "#channel-#{workspace.default_channel_id}")
      refute has_element?(view, "#channel-#{workspace.default_channel_id}[aria-current='page']")
      assert has_element?(view, "#workspace-invite-create-form")
      assert Repo.aggregate(WorkspaceInvite, :count) == 0
    end

    test "syncs sidebar read state across invite and channel sessions", %{
      conn: invite_conn,
      scope: admin_scope
    } do
      {_owner_scope, workspace, sibling_channel} =
        workspace_with_sibling_unread!(admin_scope, "admin")

      channel_conn = build_conn() |> log_in_user(admin_scope.user)

      {:ok, invite_view, _html} = live(invite_conn, ~p"/workspaces/#{workspace.id}/invites/new")

      {:ok, channel_view, _html} =
        live(
          channel_conn,
          ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}"
        )

      assert has_element?(invite_view, "#channel-#{sibling_channel.id}-unread-badge", "1")
      assert has_element?(channel_view, "#channel-#{sibling_channel.id}-unread-badge", "1")

      channel_view
      |> element("#channel-#{sibling_channel.id}-actions")
      |> render_click()

      channel_view
      |> element("#channel-#{sibling_channel.id}-mark-read")
      |> render_click()

      refute has_element?(invite_view, "#channel-#{sibling_channel.id}-unread-badge")
      refute has_element?(channel_view, "#channel-#{sibling_channel.id}-unread-badge")
    end

    test "renders durable workspace members in the invite shell", %{
      conn: conn,
      scope: admin_scope
    } do
      owner_scope =
        %{username: "invite_owner"}
        |> DiscordClone.AccountsFixtures.user_fixture()
        |> DiscordClone.AccountsFixtures.user_scope_fixture()

      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, admin_scope, "admin")

      {:ok, view, _html} = live(conn, ~p"/workspaces/#{workspace.id}/invites/new")

      assert has_element?(view, "#workspace-members-sidebar[aria-label='Workspace members']")

      assert has_element?(
               view,
               "#workspace-member-#{owner_scope.user.id}[data-presence-state='offline']",
               "invite_owner"
             )

      assert has_element?(
               view,
               "#workspace-member-#{admin_scope.user.id}",
               admin_scope.user.username
             )

      assert has_element?(view, "#workspace-invite-create-form")
    end

    test "marks the current member online after entering an invite surface", %{
      conn: conn,
      scope: admin_scope
    } do
      owner_scope =
        %{username: "invite_presence_owner"}
        |> DiscordClone.AccountsFixtures.user_fixture()
        |> DiscordClone.AccountsFixtures.user_scope_fixture()

      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, admin_scope, "admin")

      {:ok, view, _html} = live(conn, ~p"/workspaces/#{workspace.id}/invites/new")

      assert has_element?(
               view,
               "#workspace-member-#{admin_scope.user.id}[data-presence-state='online']",
               admin_scope.user.username
             )

      assert has_element?(
               view,
               "#workspace-member-#{admin_scope.user.id} [data-member-status='online']",
               "Online"
             )

      assert has_element?(
               view,
               "#workspace-member-#{owner_scope.user.id}[data-presence-state='offline']",
               "invite_presence_owner"
             )
    end

    test "marks another member online on the invite surface without refresh", %{
      conn: conn,
      scope: receiver_scope
    } do
      sender_scope =
        %{username: "invite_presence_sender"}
        |> DiscordClone.AccountsFixtures.user_fixture()
        |> DiscordClone.AccountsFixtures.user_scope_fixture()

      {:ok, workspace} = Workspaces.create_workspace(receiver_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, sender_scope)
      sender_conn = build_conn() |> log_in_user(sender_scope.user)

      {:ok, receiver_view, _html} = live(conn, ~p"/workspaces/#{workspace.id}/invites/new")

      assert has_element?(
               receiver_view,
               "#workspace-member-#{sender_scope.user.id}[data-presence-state='offline']",
               "invite_presence_sender"
             )

      {:ok, _sender_view, _html} =
        live(
          sender_conn,
          ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}"
        )

      assert has_element?(
               receiver_view,
               "#workspace-member-#{sender_scope.user.id}[data-presence-state='online']",
               "invite_presence_sender"
             )
    end

    test "refreshes the channel sidebar when a channel is created elsewhere", %{
      conn: conn,
      scope: scope
    } do
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})

      {:ok, view, _html} = live(conn, ~p"/workspaces/#{workspace.id}/invites/new")

      assert {:ok, channel} = Workspaces.create_channel(scope, workspace.id, %{name: "Logistics"})

      render(view)

      assert has_element?(view, "#channel-#{channel.id}", "# logistics")
    end

    test "refreshes the member list when a new member joins via invite", %{
      conn: conn,
      scope: scope
    } do
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      {:ok, invite} = Workspaces.create_workspace_invite(scope, workspace.id)

      joiner_scope =
        DiscordClone.AccountsFixtures.user_fixture(%{username: "invite_screen_joiner"})
        |> DiscordClone.AccountsFixtures.user_scope_fixture()

      {:ok, view, _html} = live(conn, ~p"/workspaces/#{workspace.id}/invites/new")

      refute has_element?(view, "#workspace-member-#{joiner_scope.user.id}")

      assert {:ok, _result} = Workspaces.accept_workspace_invite(joiner_scope, invite.code)

      render(view)

      assert has_element?(
               view,
               "#workspace-member-#{joiner_scope.user.id}",
               "invite_screen_joiner"
             )
    end

    test "shows and opens the workspace create action from the invite screen", %{
      conn: conn,
      scope: scope
    } do
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})

      {:ok, view, _html} = live(conn, ~p"/workspaces/#{workspace.id}/invites/new")

      assert has_element?(view, "#workspace-create-toggle[title='Create workspace']")
      refute has_element?(view, "#workspace-create-form")

      view
      |> element("#workspace-create-toggle")
      |> render_click()

      assert has_element?(view, "#workspace-create-form")
    end

    test "cancels workspace creation from the invite screen", %{
      conn: conn,
      scope: scope
    } do
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})

      {:ok, view, _html} = live(conn, ~p"/workspaces/#{workspace.id}/invites/new")

      view
      |> element("#workspace-create-toggle")
      |> render_click()

      view
      |> element("#workspace-create-cancel")
      |> render_click()

      refute has_element?(view, "#workspace-create-form")
      assert has_element?(view, "#workspace-invite-create-form")
    end

    test "submitting the form creates and displays a selectable absolute invite URL", %{
      conn: conn,
      scope: scope
    } do
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      {:ok, view, _html} = live(conn, ~p"/workspaces/#{workspace.id}/invites/new")

      view
      |> form("#workspace-invite-create-form", invite: %{})
      |> render_submit()

      invite = Repo.one!(WorkspaceInvite)
      invite_url = DiscordCloneWeb.Endpoint.url() <> "/invites/#{invite.code}"

      assert has_element?(view, "#workspace-invite-url[value='#{invite_url}']")

      assert has_element?(
               view,
               "#workspace-invite-copy[phx-hook='ClipboardCopy'][phx-update='ignore'][data-copy-target='workspace-invite-url']"
             )
    end

    test "submitting twice replaces the displayed link with a fresh invite URL", %{
      conn: conn,
      scope: scope
    } do
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      {:ok, view, _html} = live(conn, ~p"/workspaces/#{workspace.id}/invites/new")

      view
      |> form("#workspace-invite-create-form", invite: %{})
      |> render_submit()

      first_invite = Repo.one!(WorkspaceInvite)
      first_url = DiscordCloneWeb.Endpoint.url() <> "/invites/#{first_invite.code}"

      view
      |> form("#workspace-invite-create-form", invite: %{})
      |> render_submit()

      second_invite =
        WorkspaceInvite
        |> order_by([invite], desc: invite.inserted_at, desc: invite.id)
        |> limit(1)
        |> Repo.one!()

      second_url = DiscordCloneWeb.Endpoint.url() <> "/invites/#{second_invite.code}"

      assert first_invite.code != second_invite.code
      assert Repo.aggregate(WorkspaceInvite, :count) == 2
      assert has_element?(view, "#workspace-invite-url[value='#{second_url}']")
      refute has_element?(view, "#workspace-invite-url[value='#{first_url}']")
    end

    test "redirects disallowed members back to workspace entry with an error flash", %{
      conn: conn,
      scope: member_scope
    } do
      owner_scope = DiscordClone.AccountsFixtures.user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, member_scope)

      assert {:error, {:redirect, %{to: path, flash: flash}}} =
               live(conn, ~p"/workspaces/#{workspace.id}/invites/new")

      assert path == ~p"/workspaces/#{workspace.id}"
      assert flash["error"] =~ "not allowed to create invites"
    end

    test "redirects non-members to the workspace app with the generic access flash", %{
      conn: conn
    } do
      owner_scope = DiscordClone.AccountsFixtures.user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})

      assert {:error, {:redirect, %{to: path, flash: flash}}} =
               live(conn, ~p"/workspaces/#{workspace.id}/invites/new")

      assert path == ~p"/workspaces"
      assert flash["error"] =~ "Workspace not found or you do not have access"
    end

    test "promotes a member from the invite-surface member menu", %{
      conn: conn,
      scope: owner_scope
    } do
      target_scope =
        DiscordClone.AccountsFixtures.user_fixture(%{username: "invite_promotable"})
        |> DiscordClone.AccountsFixtures.user_scope_fixture()

      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, target_scope, "member")

      {:ok, view, _html} = live(conn, ~p"/workspaces/#{workspace.id}/invites/new")

      view
      |> element("#workspace-member-#{target_scope.user.id}-promote-to-admin")
      |> render_click()

      assert Repo.get_by(WorkspaceMembership,
               workspace_id: workspace.id,
               user_id: target_scope.user.id
             ).role == "admin"

      assert has_element?(view, "#workspace-member-#{target_scope.user.id}-demote-to-member")
    end
  end
end
