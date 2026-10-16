defmodule DiscordCloneWeb.WorkspaceLive.HomeNavigationTest do
  use DiscordCloneWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias DiscordClone.Workspaces
  alias DiscordClone.Workspaces.Channel
  alias DiscordClone.Repo

  describe "/workspaces authentication" do
    test "requires an authenticated user", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(conn, ~p"/workspaces")
    end
  end

  describe "/workspaces shell" do
    setup :register_and_log_in_user

    test "shows the app shell and open workspace form when the user has no workspaces", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/workspaces")

      assert has_element?(view, "#workspace-app-shell")
      assert has_element?(view, "#workspace-sidebar")
      assert has_element?(view, "#channel-sidebar")
      assert has_element?(view, "#workspace-main")
      assert has_element?(view, "#workspace-create-form")
      assert has_element?(view, "#workspace-empty-state")
    end

    test "shows existing workspaces as first-letter rail items with compact create action", %{
      conn: conn,
      scope: scope
    } do
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})

      {:ok, view, _html} = live(conn, ~p"/workspaces")

      assert has_element?(
               view,
               "#workspaces [aria-label='Open #{workspace.name}'][title='#{workspace.name}']",
               "F"
             )

      assert has_element?(view, "#workspace-create-toggle[title='Create workspace']")
      refute has_element?(view, "#workspace-create-form")
      refute has_element?(view, "#workspace-sidebar", "Workspaces")
    end

    test "opens the workspace form from the compact create action", %{
      conn: conn,
      scope: scope
    } do
      {:ok, _workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      {:ok, view, _html} = live(conn, ~p"/workspaces")

      view
      |> element("#workspace-create-toggle")
      |> render_click()

      assert has_element?(view, "#workspace-create-form")
    end

    test "cancels workspace creation without navigating", %{
      conn: conn,
      scope: scope
    } do
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      {:ok, view, _html} = live(conn, ~p"/workspaces")

      view
      |> element("#workspace-create-toggle")
      |> render_click()

      assert has_element?(view, "#workspace-create-form")

      view
      |> element("#workspace-create-cancel")
      |> render_click()

      refute has_element?(view, "#workspace-create-form")
      assert has_element?(view, "#workspace-create-toggle")
      assert has_element?(view, "#workspaces [aria-label='Open #{workspace.name}']")
    end

    test "keeps the workspace form open with field errors for invalid input", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/workspaces")

      view
      |> form("#workspace-create-form", workspace: %{name: ""})
      |> render_submit()

      assert has_element?(view, "#workspace-create-form")
      assert has_element?(view, "#workspace_name.input-error")
      assert has_element?(view, "#workspace-create-form", "can't be blank")
    end

    test "creates a workspace and navigates into workspace entry", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/workspaces")

      {:error, {:live_redirect, %{to: path}}} =
        view
        |> form("#workspace-create-form", workspace: %{name: "Launch Room"})
        |> render_submit()

      assert path =~ ~r|^/workspaces/[0-9a-f-]{36}$|
    end
  end

  describe "/workspaces/:workspace_id entry" do
    setup :register_and_log_in_user

    test "navigates to the resolved landing channel", %{conn: conn, scope: scope} do
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})

      assert {:error, {:live_redirect, %{to: path}}} = live(conn, ~p"/workspaces/#{workspace.id}")

      assert path == ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}"
    end

    test "redirects when no landing channel exists", %{
      conn: conn,
      scope: scope
    } do
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      Repo.delete_all(Channel)

      assert {:error, {:redirect, %{to: "/workspaces", flash: flash}}} =
               live(conn, ~p"/workspaces/#{workspace.id}")

      assert flash["error"] =~ "Workspace not found or you do not have access"
    end

    test "redirects missing or unauthorized workspace entry to the workspace app", %{
      conn: conn
    } do
      assert {:error, {:redirect, %{to: "/workspaces", flash: flash}}} =
               live(conn, ~p"/workspaces/not-a-uuid")

      assert flash["error"] =~ "Workspace not found"
    end
  end
end
