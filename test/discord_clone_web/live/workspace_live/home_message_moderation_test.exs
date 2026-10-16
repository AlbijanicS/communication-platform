defmodule DiscordCloneWeb.WorkspaceLive.HomeMessageModerationTest do
  use DiscordCloneWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import DiscordCloneWeb.WorkspaceLiveTestHelpers

  alias DiscordClone.Workspaces
  alias DiscordClone.Chat
  alias DiscordClone.Chat.Message
  alias DiscordClone.Workspaces.WorkspaceMembership
  alias DiscordClone.Repo

  describe "channel message moderation context menus" do
    setup :register_and_log_in_user

    test "authors can delete their own message from its context menu", %{
      conn: conn,
      scope: scope
    } do
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})

      {:ok, message} =
        Chat.send_message(scope, workspace.default_channel_id, %{"content" => "delete me please"})

      {:ok, view, html} =
        live(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      assert html =~ "delete me please"
      assert has_element?(view, "#message-#{message.id}-actions")
      assert has_element?(view, "#message-#{message.id}-delete")

      view
      |> element("#message-#{message.id}-delete")
      |> render_click()

      assert Repo.get(Message, message.id).deleted_at

      updated_html = render(view)
      assert updated_html =~ "Message deleted"
      refute updated_html =~ "delete me please"
    end

    test "moderators can delete another member's message from its context menu", %{
      conn: owner_conn,
      scope: owner_scope
    } do
      member_scope =
        %{username: "message_delete_target"}
        |> DiscordClone.AccountsFixtures.user_fixture()
        |> DiscordClone.AccountsFixtures.user_scope_fixture()

      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, member_scope, "member")

      {:ok, message} =
        Chat.send_message(member_scope, workspace.default_channel_id, %{
          "content" => "moderate me"
        })

      {:ok, owner_view, html} =
        live(owner_conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      assert html =~ "moderate me"
      assert has_element?(owner_view, "#message-#{message.id}-delete")

      owner_view
      |> element("#message-#{message.id}-delete")
      |> render_click()

      assert Repo.get(Message, message.id).deleted_at

      updated_html = render(owner_view)
      assert updated_html =~ "Message deleted"
      refute updated_html =~ "moderate me"

      assert {:ok, events} = Workspaces.list_audit_events(owner_scope, workspace.id)
      assert Enum.any?(events, &(&1.event_type == "moderator_message_deleted"))
    end

    test "regular members cannot delete another member's message", %{
      conn: viewer_conn,
      scope: viewer_scope
    } do
      author_scope =
        %{username: "message_delete_author"}
        |> DiscordClone.AccountsFixtures.user_fixture()
        |> DiscordClone.AccountsFixtures.user_scope_fixture()

      {:ok, workspace} = Workspaces.create_workspace(author_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, viewer_scope, "member")

      {:ok, message} =
        Chat.send_message(author_scope, workspace.default_channel_id, %{"content" => "hands off"})

      {:ok, viewer_view, html} =
        live(
          viewer_conn,
          ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}"
        )

      assert html =~ "hands off"
      refute has_element?(viewer_view, "#message-#{message.id}-delete")
      refute has_element?(viewer_view, "#message-#{message.id}-mute")
      assert has_element?(viewer_view, "#message-#{message.id}-reaction-palette")
    end

    test "message menus expose author moderation actions per owner authorization", %{
      conn: owner_conn,
      scope: owner_scope
    } do
      admin_scope =
        %{username: "msg_mod_admin"}
        |> DiscordClone.AccountsFixtures.user_fixture()
        |> DiscordClone.AccountsFixtures.user_scope_fixture()

      member_scope =
        %{username: "msg_mod_member"}
        |> DiscordClone.AccountsFixtures.user_fixture()
        |> DiscordClone.AccountsFixtures.user_scope_fixture()

      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, admin_scope, "admin")
      add_workspace_member!(workspace, member_scope, "member")

      channel_id = workspace.default_channel_id
      {:ok, owner_msg} = Chat.send_message(owner_scope, channel_id, %{"content" => "owner post"})
      {:ok, admin_msg} = Chat.send_message(admin_scope, channel_id, %{"content" => "admin post"})

      {:ok, member_msg} =
        Chat.send_message(member_scope, channel_id, %{"content" => "member post"})

      {:ok, owner_view, _html} =
        live(owner_conn, ~p"/workspaces/#{workspace.id}/channels/#{channel_id}")

      assert has_element?(owner_view, "#message-#{member_msg.id}-mute")
      assert has_element?(owner_view, "#message-#{member_msg.id}-timeout-5-minutes")
      assert has_element?(owner_view, "#message-#{member_msg.id}-kick")
      assert has_element?(owner_view, "#message-#{member_msg.id}-ban")
      assert has_element?(owner_view, "#message-#{member_msg.id}-promote-to-admin")

      assert has_element?(owner_view, "#message-#{admin_msg.id}-demote-to-member")
      assert has_element?(owner_view, "#message-#{admin_msg.id}-mute")
      assert has_element?(owner_view, "#message-#{admin_msg.id}-ban")

      refute has_element?(owner_view, "#message-#{owner_msg.id}-mute")
      assert has_element?(owner_view, "#message-#{owner_msg.id}-delete")
    end

    test "message menus hide actions blocked by admin/admin and owner immunity", %{
      conn: admin_conn,
      scope: admin_scope
    } do
      owner_scope =
        %{username: "msg_mod_owner"}
        |> DiscordClone.AccountsFixtures.user_fixture()
        |> DiscordClone.AccountsFixtures.user_scope_fixture()

      peer_admin_scope =
        %{username: "msg_mod_peer_admin"}
        |> DiscordClone.AccountsFixtures.user_fixture()
        |> DiscordClone.AccountsFixtures.user_scope_fixture()

      member_scope =
        %{username: "msg_mod_target"}
        |> DiscordClone.AccountsFixtures.user_fixture()
        |> DiscordClone.AccountsFixtures.user_scope_fixture()

      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, admin_scope, "admin")
      add_workspace_member!(workspace, peer_admin_scope, "admin")
      add_workspace_member!(workspace, member_scope, "member")

      channel_id = workspace.default_channel_id
      {:ok, self_msg} = Chat.send_message(admin_scope, channel_id, %{"content" => "self post"})
      {:ok, owner_msg} = Chat.send_message(owner_scope, channel_id, %{"content" => "owner post"})

      {:ok, peer_msg} =
        Chat.send_message(peer_admin_scope, channel_id, %{"content" => "peer admin post"})

      {:ok, member_msg} =
        Chat.send_message(member_scope, channel_id, %{"content" => "member post"})

      {:ok, admin_view, _html} =
        live(admin_conn, ~p"/workspaces/#{workspace.id}/channels/#{channel_id}")

      assert has_element?(admin_view, "#message-#{self_msg.id}-delete")
      refute has_element?(admin_view, "#message-#{self_msg.id}-mute")
      refute has_element?(admin_view, "#message-#{self_msg.id}-timeout-5-minutes")

      assert has_element?(admin_view, "#message-#{peer_msg.id}-mute")
      assert has_element?(admin_view, "#message-#{peer_msg.id}-timeout-5-minutes")
      refute has_element?(admin_view, "#message-#{peer_msg.id}-kick")
      refute has_element?(admin_view, "#message-#{peer_msg.id}-ban")

      refute has_element?(admin_view, "#message-#{owner_msg.id}-delete")
      refute has_element?(admin_view, "#message-#{owner_msg.id}-mute")
      assert has_element?(admin_view, "#message-#{owner_msg.id}-reaction-palette")

      assert has_element?(admin_view, "#message-#{member_msg.id}-kick")
      assert has_element?(admin_view, "#message-#{member_msg.id}-ban")
    end

    test "mute applies immediately from a message context menu", %{
      conn: owner_conn,
      scope: owner_scope
    } do
      target_scope =
        %{username: "msg_mute_target"}
        |> DiscordClone.AccountsFixtures.user_fixture()
        |> DiscordClone.AccountsFixtures.user_scope_fixture()

      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, target_scope, "member")

      {:ok, message} =
        Chat.send_message(target_scope, workspace.default_channel_id, %{"content" => "noisy"})

      {:ok, owner_view, _html} =
        live(owner_conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      assert has_element?(owner_view, "#message-#{message.id}-mute")

      owner_view
      |> element("#message-#{message.id}-mute")
      |> render_click()

      assert has_element?(owner_view, "#message-#{message.id}-unmute")
      refute has_element?(owner_view, "#message-#{message.id}-mute")

      assert {:ok, %{muted?: true}} =
               Workspaces.member_moderation_state(owner_scope, workspace.id, target_scope.user.id)
    end

    test "mute from a message context menu refreshes every rendered author row", %{
      conn: owner_conn,
      scope: owner_scope
    } do
      target_scope =
        %{username: "msg_multi_row_mute_target"}
        |> DiscordClone.AccountsFixtures.user_fixture()
        |> DiscordClone.AccountsFixtures.user_scope_fixture()

      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, target_scope, "member")

      {:ok, first_message} =
        Chat.send_message(target_scope, workspace.default_channel_id, %{
          "content" => "first noisy"
        })

      {:ok, second_message} =
        Chat.send_message(target_scope, workspace.default_channel_id, %{
          "content" => "second noisy"
        })

      {:ok, owner_view, _html} =
        live(owner_conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      assert has_element?(owner_view, "#message-#{first_message.id}-mute")
      assert has_element?(owner_view, "#message-#{second_message.id}-mute")

      owner_view
      |> element("#message-#{first_message.id}-mute")
      |> render_click()

      assert has_element?(owner_view, "#message-#{first_message.id}-unmute")
      assert has_element?(owner_view, "#message-#{second_message.id}-unmute")
      refute has_element?(owner_view, "#message-#{first_message.id}-mute")
      refute has_element?(owner_view, "#message-#{second_message.id}-mute")
    end

    test "timeout applies after selecting a preset from a message context menu", %{
      conn: owner_conn,
      scope: owner_scope
    } do
      target_scope =
        %{username: "msg_timeout_target"}
        |> DiscordClone.AccountsFixtures.user_fixture()
        |> DiscordClone.AccountsFixtures.user_scope_fixture()

      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, target_scope, "member")

      {:ok, message} =
        Chat.send_message(target_scope, workspace.default_channel_id, %{"content" => "slow down"})

      {:ok, owner_view, _html} =
        live(owner_conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      assert has_element?(owner_view, "#message-#{message.id}-timeout-5-minutes")

      owner_view
      |> element("#message-#{message.id}-timeout-5-minutes")
      |> render_click()

      assert has_element?(owner_view, "#message-#{message.id}-remove-timeout")

      assert {:ok, %{timed_out?: true}} =
               Workspaces.member_moderation_state(owner_scope, workspace.id, target_scope.user.id)
    end

    test "kick from a message context menu requires a reason and clears the author's menu", %{
      conn: owner_conn,
      scope: owner_scope
    } do
      target_scope =
        %{username: "msg_kick_target"}
        |> DiscordClone.AccountsFixtures.user_fixture()
        |> DiscordClone.AccountsFixtures.user_scope_fixture()

      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, target_scope, "member")

      {:ok, message} =
        Chat.send_message(target_scope, workspace.default_channel_id, %{"content" => "spam city"})

      {:ok, owner_view, _html} =
        live(owner_conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      assert has_element?(owner_view, "#message-#{message.id}-kick")

      blank_html =
        owner_view
        |> form("#message-#{message.id}-kick-form", %{reason: "   "})
        |> render_submit()

      assert blank_html =~ "reason is required"

      assert Repo.get_by(WorkspaceMembership,
               workspace_id: workspace.id,
               user_id: target_scope.user.id
             )

      owner_view
      |> form("#message-#{message.id}-kick-form", %{reason: "Repeated spam"})
      |> render_submit()

      refute Repo.get_by(WorkspaceMembership,
               workspace_id: workspace.id,
               user_id: target_scope.user.id
             )

      refute has_element?(owner_view, "#message-#{message.id}-delete")
      refute has_element?(owner_view, "#message-#{message.id}-mute")
      refute has_element?(owner_view, "#message-#{message.id}-kick")
      assert has_element?(owner_view, "#message-#{message.id}-reaction-palette")

      assert {:ok, events} = Workspaces.list_audit_events(owner_scope, workspace.id)

      assert Enum.any?(
               events,
               &(&1.event_type == "member_kicked" and &1.reason == "Repeated spam")
             )
    end

    test "ban from a message context menu requires a reason and applies the cleanup choice", %{
      conn: owner_conn,
      scope: owner_scope
    } do
      target_scope =
        %{username: "msg_ban_target"}
        |> DiscordClone.AccountsFixtures.user_fixture()
        |> DiscordClone.AccountsFixtures.user_scope_fixture()

      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, target_scope, "member")

      {:ok, message} =
        Chat.send_message(target_scope, workspace.default_channel_id, %{"content" => "toxic post"})

      {:ok, owner_view, html} =
        live(owner_conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      assert html =~ "toxic post"

      assert has_element?(
               owner_view,
               "#message-#{message.id}-ban-form input[name='cleanup_window'][value='all']"
             )

      blank_html =
        owner_view
        |> form("#message-#{message.id}-ban-form", %{reason: "   "})
        |> render_submit()

      assert blank_html =~ "reason is required"
      refute Workspaces.workspace_banned?(workspace.id, target_scope.user.id)

      owner_view
      |> form("#message-#{message.id}-ban-form", %{
        reason: "Persistent abuse",
        cleanup_window: "all"
      })
      |> render_submit()

      assert Workspaces.workspace_banned?(workspace.id, target_scope.user.id)
      assert Repo.get(Message, message.id).deleted_at

      updated_html = render(owner_view)
      assert updated_html =~ "Message deleted"
      refute updated_html =~ "toxic post"

      assert {:ok, events} = Workspaces.list_audit_events(owner_scope, workspace.id)
      ban_event = Enum.find(events, &(&1.event_type == "member_banned"))
      assert ban_event.reason == "Persistent abuse"
      assert ban_event.metadata["cleanup_window"] == "all"
    end

    test "message ban form hides the all-messages cleanup option from admins", %{
      conn: admin_conn,
      scope: admin_scope
    } do
      owner_scope =
        %{username: "msg_ban_owner"}
        |> DiscordClone.AccountsFixtures.user_fixture()
        |> DiscordClone.AccountsFixtures.user_scope_fixture()

      member_scope =
        %{username: "msg_ban_member"}
        |> DiscordClone.AccountsFixtures.user_fixture()
        |> DiscordClone.AccountsFixtures.user_scope_fixture()

      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, admin_scope, "admin")
      add_workspace_member!(workspace, member_scope, "member")

      {:ok, message} =
        Chat.send_message(member_scope, workspace.default_channel_id, %{"content" => "borderline"})

      {:ok, admin_view, _html} =
        live(admin_conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      assert has_element?(
               admin_view,
               "#message-#{message.id}-ban-form input[name='cleanup_window'][value='24_hours']"
             )

      refute has_element?(
               admin_view,
               "#message-#{message.id}-ban-form input[name='cleanup_window'][value='all']"
             )
    end

    test "admins see moderation success feedback from a message menu without the audit log", %{
      conn: admin_conn,
      scope: admin_scope
    } do
      owner_scope =
        %{username: "msg_flash_owner"}
        |> DiscordClone.AccountsFixtures.user_fixture()
        |> DiscordClone.AccountsFixtures.user_scope_fixture()

      member_scope =
        %{username: "msg_flash_member"}
        |> DiscordClone.AccountsFixtures.user_fixture()
        |> DiscordClone.AccountsFixtures.user_scope_fixture()

      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, admin_scope, "admin")
      add_workspace_member!(workspace, member_scope, "member")

      {:ok, message} =
        Chat.send_message(member_scope, workspace.default_channel_id, %{
          "content" => "rule breaker"
        })

      {:ok, admin_view, _html} =
        live(admin_conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      # Admins cannot view the audit log, so the flash is their only confirmation.
      assert {:error, _reason} = Workspaces.list_audit_events(admin_scope, workspace.id)

      admin_view
      |> form("#message-#{message.id}-kick-form", %{reason: "Spamming"})
      |> render_submit()

      assert render(admin_view) =~ "Member removed from the workspace"
    end
  end
end
