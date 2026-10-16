defmodule DiscordCloneWeb.InviteControllerTest do
  use DiscordCloneWeb.ConnCase

  alias DiscordClone.Repo
  alias DiscordClone.Chat
  alias DiscordClone.Chat.Message
  alias DiscordClone.Workspaces
  alias DiscordClone.Workspaces.WorkspaceAuditEvent
  alias DiscordClone.Workspaces.WorkspaceMembership

  import Ecto.Query
  import DiscordClone.AccountsFixtures

  describe "GET /invites/:code" do
    test "redirects anonymous visitors to login and stores return to", %{conn: conn} do
      conn = get(conn, ~p"/invites/missing-code")

      assert redirected_to(conn) == ~p"/users/log-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "must log in"
      assert get_session(conn, :user_return_to) == ~p"/invites/missing-code"
    end

    test "renders a standalone preview page for a valid invite", %{conn: conn} do
      owner_scope = user_scope_fixture()
      invited_user = user_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})

      {:ok, _channel} =
        Workspaces.create_channel(owner_scope, workspace.id, %{name: "Secret Ops"})

      {:ok, invite} = Workspaces.create_workspace_invite(owner_scope, workspace.id)

      conn =
        conn
        |> log_in_user(invited_user)
        |> get(~p"/invites/#{invite.code}")

      response = html_response(conn, 200)

      assert response =~ "Join Foundry"
      assert response =~ owner_scope.user.username
      assert response =~ invited_user.username
      assert response =~ "Accept invite"
      refute response =~ "workspace-app-shell"
      refute response =~ "secret-ops"
      refute response =~ owner_scope.user.email
    end

    test "renders a clear failure state without an accept control for missing invites", %{
      conn: conn
    } do
      user = user_fixture()

      conn =
        conn
        |> log_in_user(user)
        |> get(~p"/invites/missing-code")

      response = html_response(conn, 404)

      assert response =~ "This invite link cannot be used."
      assert response =~ "Ask for a fresh invite link"
      refute response =~ "Accept invite"
      refute response =~ "invite-preview-accept-form"
    end

    test "renders a revoked failure state without an accept control", %{conn: conn} do
      owner_scope = user_scope_fixture()
      invited_user = user_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      {:ok, invite} = Workspaces.create_workspace_invite(owner_scope, workspace.id)

      invite
      |> Ecto.Changeset.change(revoked_at: DateTime.utc_now(:second))
      |> Repo.update!()

      conn =
        conn
        |> log_in_user(invited_user)
        |> get(~p"/invites/#{invite.code}")

      response = html_response(conn, 410)

      assert response =~ "This invite link is no longer active."
      assert response =~ "Ask for a fresh invite link"
      refute response =~ "Accept invite"
      refute response =~ "invite-preview-accept-form"
    end

    test "renders an expired failure state without an accept control", %{conn: conn} do
      owner_scope = user_scope_fixture()
      invited_user = user_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})

      {:ok, invite} =
        Workspaces.create_workspace_invite(owner_scope, workspace.id, %{
          expires_at: DateTime.add(DateTime.utc_now(:second), -1, :second)
        })

      conn =
        conn
        |> log_in_user(invited_user)
        |> get(~p"/invites/#{invite.code}")

      response = html_response(conn, 410)

      assert response =~ "This invite link has expired."
      assert response =~ "Ask for a fresh invite link"
      refute response =~ "Accept invite"
      refute response =~ "invite-preview-accept-form"
    end

    test "renders a generic unavailable state without an accept control for banned users", %{
      conn: conn
    } do
      owner_scope = user_scope_fixture()
      banned_user = user_fixture()
      banned_scope = user_scope_fixture(banned_user)
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, banned_scope)
      {:ok, invite} = Workspaces.create_workspace_invite(owner_scope, workspace.id)

      {:ok, _ban} =
        Workspaces.ban_member(owner_scope, workspace.id, banned_user.id, %{"reason" => "spam"})

      conn =
        conn
        |> log_in_user(banned_user)
        |> get(~p"/invites/#{invite.code}")

      response = html_response(conn, 403)

      assert response =~ "This invite link cannot be used."
      refute response =~ "Foundry"
      refute response =~ "Accept invite"
      refute response =~ "invite-preview-accept-form"
    end

    test "renders a fully-used failure state without an accept control", %{conn: conn} do
      owner_scope = user_scope_fixture()
      invited_user = user_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})

      {:ok, invite} =
        Workspaces.create_workspace_invite(owner_scope, workspace.id, %{max_uses: 1})

      invite
      |> Ecto.Changeset.change(uses_count: 1)
      |> Repo.update!()

      conn =
        conn
        |> log_in_user(invited_user)
        |> get(~p"/invites/#{invite.code}")

      response = html_response(conn, 410)

      assert response =~ "This invite link has no remaining uses."
      assert response =~ "Ask for a fresh invite link"
      refute response =~ "Accept invite"
      refute response =~ "invite-preview-accept-form"
    end
  end

  describe "POST /invites/:code/accept" do
    test "accepts a valid invite and redirects the new member to the landing channel", %{
      conn: conn
    } do
      owner_scope = user_scope_fixture()
      invited_user = user_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      {:ok, invite} = Workspaces.create_workspace_invite(owner_scope, workspace.id)
      assert :ok = Workspaces.subscribe_to_workspace_events(owner_scope, workspace.id)
      assert :ok = Chat.subscribe_to_workspace_presence(owner_scope, workspace.id)

      conn =
        conn
        |> log_in_user(invited_user)
        |> post(~p"/invites/#{invite.code}/accept")

      assert redirected_to(conn) ==
               ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}"

      assert %WorkspaceMembership{role: "member"} =
               Repo.get_by(WorkspaceMembership,
                 workspace_id: workspace.id,
                 user_id: invited_user.id
               )

      assert_receive {:workspace_member_joined, %{workspace_id: workspace_id, user_id: user_id}}

      assert workspace_id == workspace.id
      assert user_id == invited_user.id

      assert_receive {:workspace_user_joined, %{workspace_id: workspace_id, user_id: user_id}}
      assert workspace_id == workspace.id
      assert user_id == invited_user.id

      assert_receive {:workspace_audit_changed, %{workspace_id: workspace_id}}
      assert workspace_id == workspace.id

      assert %WorkspaceAuditEvent{
               event_type: "member_joined_from_invite",
               actor_user_id: actor_user_id,
               target_user_id: target_user_id
             } =
               Repo.get_by(WorkspaceAuditEvent,
                 workspace_id: workspace.id,
                 target_user_id: invited_user.id
               )

      assert actor_user_id == owner_scope.user.id
      assert target_user_id == invited_user.id

      assert %Message{content: content, user_id: user_id} =
               Repo.get_by(Message,
                 channel_id: workspace.default_channel_id,
                 user_id: invited_user.id
               )

      assert content == "#{invited_user.username} joined from an invite."
      assert user_id == invited_user.id
    end

    test "redirects existing members to the landing channel with an informational flash", %{
      conn: conn
    } do
      owner_scope = user_scope_fixture()
      existing_user = user_fixture()
      existing_scope = user_scope_fixture(existing_user)
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, existing_scope)
      {:ok, invite} = Workspaces.create_workspace_invite(owner_scope, workspace.id)

      conn =
        conn
        |> log_in_user(existing_user)
        |> post(~p"/invites/#{invite.code}/accept")

      assert redirected_to(conn) ==
               ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}"

      assert Phoenix.Flash.get(conn.assigns.flash, :info) == "You're already in this workspace."

      assert Repo.aggregate(
               from(membership in WorkspaceMembership,
                 where:
                   membership.workspace_id == ^workspace.id and
                     membership.user_id == ^existing_user.id
               ),
               :count
             ) == 1

      assert Repo.get!(DiscordClone.Workspaces.WorkspaceInvite, invite.id).uses_count == 0

      refute Repo.get_by(WorkspaceAuditEvent,
               workspace_id: workspace.id,
               target_user_id: existing_user.id,
               event_type: "member_joined_from_invite"
             )
    end

    test "blocks banned users from accepting without creating membership", %{conn: conn} do
      owner_scope = user_scope_fixture()
      banned_user = user_fixture()
      banned_scope = user_scope_fixture(banned_user)
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, banned_scope)
      {:ok, invite} = Workspaces.create_workspace_invite(owner_scope, workspace.id)

      {:ok, _ban} =
        Workspaces.ban_member(owner_scope, workspace.id, banned_user.id, %{"reason" => "spam"})

      conn =
        conn
        |> log_in_user(banned_user)
        |> post(~p"/invites/#{invite.code}/accept")

      response = html_response(conn, 403)

      assert response =~ "This invite link cannot be used."
      refute response =~ "Accept invite"

      refute Repo.get_by(WorkspaceMembership,
               workspace_id: workspace.id,
               user_id: banned_user.id
             )
    end

    test "renders a failure page for expired invites without creating membership", %{conn: conn} do
      owner_scope = user_scope_fixture()
      invited_user = user_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})

      {:ok, invite} =
        Workspaces.create_workspace_invite(owner_scope, workspace.id, %{
          expires_at: DateTime.add(DateTime.utc_now(:second), -1, :second)
        })

      conn =
        conn
        |> log_in_user(invited_user)
        |> post(~p"/invites/#{invite.code}/accept")

      response = html_response(conn, 410)

      assert response =~ "This invite link has expired."

      refute Repo.get_by(WorkspaceMembership,
               workspace_id: workspace.id,
               user_id: invited_user.id
             )

      assert Repo.get!(DiscordClone.Workspaces.WorkspaceInvite, invite.id).uses_count == 0
    end
  end

  defp add_workspace_member!(workspace, scope) do
    %WorkspaceMembership{}
    |> WorkspaceMembership.changeset(%{
      workspace_id: workspace.id,
      user_id: scope.user.id,
      role: "member"
    })
    |> Repo.insert!()
  end
end
