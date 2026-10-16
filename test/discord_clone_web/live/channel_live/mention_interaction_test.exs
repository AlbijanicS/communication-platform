defmodule DiscordCloneWeb.ChannelLive.MentionInteractionTest do
  use DiscordCloneWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias DiscordClone.Chat
  alias DiscordClone.Repo
  alias DiscordClone.Workspaces
  alias DiscordClone.Workspaces.Roles
  alias DiscordClone.Workspaces.WorkspaceMembership

  describe "mention autocomplete" do
    setup :register_and_log_in_user

    test "filters current Workspace Members by username", %{conn: conn, scope: owner_scope} do
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      alice_scope = member_scope("alice_member")
      albert_scope = member_scope("albert_member")
      beta_scope = member_scope("beta_member")
      add_workspace_member!(workspace, alice_scope)
      add_workspace_member!(workspace, albert_scope)
      add_workspace_member!(workspace, beta_scope)

      {:ok, view, _html} =
        live(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      render_hook(view, "mention_query", %{
        "before_cursor" => "Hello @al",
        "after_cursor" => " world"
      })

      assert has_element?(view, "#message-mention-autocomplete[role='listbox']")
      assert has_element?(view, "#message-mention-option-albert_member", "@albert_member")
      assert has_element?(view, "#message-mention-option-alice_member", "@alice_member")
      refute has_element?(view, "#message-mention-option-beta_member")
    end

    test "offers everyone to owners and admins but never regular members", %{
      conn: owner_conn,
      scope: owner_scope
    } do
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      admin_scope = member_scope("mention_admin")
      member_scope = member_scope("mention_member")
      add_workspace_member!(workspace, admin_scope, Roles.admin())
      add_workspace_member!(workspace, member_scope)

      owner_view = open_channel!(owner_conn, workspace)

      render_hook(owner_view, "mention_query", %{
        "before_cursor" => "@e",
        "after_cursor" => ""
      })

      assert has_element?(owner_view, "#message-mention-option-everyone", "@everyone")

      admin_conn = build_conn() |> log_in_user(admin_scope.user)
      admin_view = open_channel!(admin_conn, workspace)

      render_hook(admin_view, "mention_query", %{
        "before_cursor" => "@e",
        "after_cursor" => ""
      })

      assert has_element?(admin_view, "#message-mention-option-everyone", "@everyone")

      member_conn = build_conn() |> log_in_user(member_scope.user)
      member_view = open_channel!(member_conn, workspace)

      render_hook(member_view, "mention_query", %{
        "before_cursor" => "@e",
        "after_cursor" => ""
      })

      refute has_element?(member_view, "#message-mention-option-everyone")
    end

    test "supports keyboard dismissal, navigation, and selection without losing reply state", %{
      conn: conn,
      scope: owner_scope
    } do
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, member_scope("albert_member"))
      add_workspace_member!(workspace, member_scope("alice_member"))

      {:ok, parent} =
        Chat.send_message(owner_scope, workspace.default_channel_id, %{content: "Reply here"})

      view = open_channel!(conn, workspace)
      view |> element("#message-#{parent.id}-reply") |> render_click()

      render_hook(view, "mention_query", %{
        "before_cursor" => "Before @al",
        "after_cursor" => " and after"
      })

      assert has_element?(
               view,
               "#message_content[aria-expanded='true'][aria-activedescendant='message-mention-option-albert_member']"
             )

      render_hook(view, "mention_keydown", %{"key" => "Escape"})
      refute has_element?(view, "#message-mention-autocomplete")
      assert has_element?(view, "#message-reply-target[data-message-id='#{parent.id}']")

      render_hook(view, "mention_query", %{
        "before_cursor" => "Before @al",
        "after_cursor" => " and after"
      })

      render_hook(view, "mention_keydown", %{"key" => "ArrowDown"})

      assert has_element?(
               view,
               "#message-mention-option-alice_member[aria-selected='true']"
             )

      render_hook(view, "mention_keydown", %{"key" => "Enter"})

      assert_push_event(view, "mention_selected", %{
        input_id: "message_content",
        before_cursor: "Before @alice_member",
        content: "Before @alice_member and after"
      })

      assert has_element?(view, "textarea#message_content", "Before @alice_member and after")
      assert has_element?(view, "#message-reply-target[data-message-id='#{parent.id}']")
      refute has_element?(view, "#message-mention-autocomplete")
    end

    test "replaces the entire active token when the caret is inside it", %{
      conn: conn,
      scope: owner_scope
    } do
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, member_scope("alice_member"))
      view = open_channel!(conn, workspace)

      render_hook(view, "mention_query", %{
        "before_cursor" => "Before @ali",
        "after_cursor" => "ce and after"
      })

      render_hook(view, "mention_keydown", %{"key" => "Enter"})

      assert_push_event(view, "mention_selected", %{
        input_id: "message_content",
        before_cursor: "Before @alice_member",
        content: "Before @alice_member and after"
      })
    end
  end

  describe "recognized mention rendering" do
    setup :register_and_log_in_user

    test "manual mention syntax remains authoritative and renders in a live row", %{
      conn: conn,
      scope: owner_scope
    } do
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      target_scope = member_scope("manual_target")
      add_workspace_member!(workspace, target_scope)
      view = open_channel!(conn, workspace)
      content = "Hello @manual_target and @everyone"

      view
      |> form("#message-composer-form", message: %{content: content})
      |> render_submit()

      message = Repo.get_by!(DiscordClone.Chat.Message, content: content)
      assert message.content == content
      assert {:ok, 1} = Chat.unread_activity_count(target_scope)

      assert has_element?(
               view,
               "#message-#{message.id}-mention-0[data-mention-kind='user']",
               "@manual_target"
             )

      assert has_element?(
               view,
               "#message-#{message.id}-mention-1[data-mention-kind='everyone']",
               "@everyone"
             )
    end

    test "renders recognized mention syntax in initially loaded rows without changing content", %{
      conn: conn,
      scope: owner_scope
    } do
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      target_scope = member_scope("initial_target")
      add_workspace_member!(workspace, target_scope)
      content = "Initial (@initial_target), then @everyone."

      {:ok, message} =
        Chat.send_message(owner_scope, workspace.default_channel_id, %{content: content})

      target_membership =
        Repo.get_by!(WorkspaceMembership,
          workspace_id: workspace.id,
          user_id: target_scope.user.id
        )

      owner_membership =
        Repo.get_by!(WorkspaceMembership,
          workspace_id: workspace.id,
          user_id: owner_scope.user.id
        )

      Repo.delete!(target_membership)

      owner_membership
      |> Ecto.Changeset.change(role: Roles.member())
      |> Repo.update!()

      view = open_channel!(conn, workspace)

      assert has_element?(view, "#message-#{message.id}-content", "Initial")
      assert has_element?(view, "#message-#{message.id}-mention-0", "@initial_target")
      assert has_element?(view, "#message-#{message.id}-mention-1", "@everyone")
      assert Repo.get!(DiscordClone.Chat.Message, message.id).content == content
    end

    test "leaves unknown users and a regular member's everyone token as ordinary content", %{
      conn: member_conn,
      scope: member_scope
    } do
      owner_scope = member_scope("render_owner")
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, member_scope)
      content = "Ordinary @unknown_user and @everyone"

      {:ok, message} =
        Chat.send_message(member_scope, workspace.default_channel_id, %{content: content})

      view = open_channel!(member_conn, workspace)

      assert has_element?(view, "#message-#{message.id}-content", content)
      refute has_element?(view, "#message-#{message.id}-content [data-mention-kind]")
    end
  end

  defp member_scope(username) do
    %{username: username}
    |> DiscordClone.AccountsFixtures.user_fixture()
    |> DiscordClone.AccountsFixtures.user_scope_fixture()
  end

  defp add_workspace_member!(workspace, scope, role \\ Roles.member()) do
    %WorkspaceMembership{}
    |> WorkspaceMembership.changeset(%{
      workspace_id: workspace.id,
      user_id: scope.user.id,
      role: role
    })
    |> Repo.insert!()

    :ok = Chat.initialize_workspace_reads_for_user(scope.user.id, workspace.id)
  end

  defp open_channel!(conn, workspace) do
    {:ok, view, _html} =
      live(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

    view
  end
end
