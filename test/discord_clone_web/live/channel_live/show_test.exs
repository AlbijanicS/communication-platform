defmodule DiscordCloneWeb.ChannelLive.ShowTest do
  use DiscordCloneWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias DiscordClone.Workspaces
  alias DiscordClone.Chat
  alias DiscordClone.Chat.Message
  alias DiscordClone.Workspaces.WorkspaceMembership
  alias DiscordClone.Repo

  describe "unauthorized channel access" do
    setup :register_and_log_in_user

    test "redirects a non-member to the workspace app with a flash", %{conn: conn} do
      owner_scope = DiscordClone.AccountsFixtures.user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})

      assert {:error, {:redirect, %{to: "/workspaces", flash: flash}}} =
               live(
                 conn,
                 ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}"
               )

      assert flash["error"] =~ "Channel not found or you do not have access"
    end

    test "redirects when the workspace or channel is missing", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/workspaces", flash: flash}}} =
               live(conn, ~p"/workspaces/not-a-uuid/channels/also-missing")

      assert flash["error"] =~ "Channel not found or you do not have access"
    end
  end

  describe "channel render" do
    setup :register_and_log_in_user

    test "renders the channel surface with its existing messages", %{conn: conn, scope: scope} do
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})

      {:ok, first} =
        Chat.send_message(scope, workspace.default_channel_id, %{content: "first up"})

      {:ok, second} =
        Chat.send_message(scope, workspace.default_channel_id, %{content: "second up"})

      {:ok, view, _html} =
        live(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      assert has_element?(view, "#channel-message-surface")
      assert has_element?(view, "#message-composer-form")
      assert has_element?(view, "#message-#{first.id}-content", "first up")
      assert has_element?(view, "#message-#{second.id}-content", "second up")
      refute has_element?(view, "#channel-empty-state")
    end
  end

  describe "sending messages" do
    setup :register_and_log_in_user

    test "posts a message from the composer and renders it in the stream", %{
      conn: conn,
      scope: scope
    } do
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})

      {:ok, view, _html} =
        live(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      assert has_element?(view, "#channel-empty-state")

      view
      |> form("#message-composer-form", message: %{content: "hello team"})
      |> render_submit()

      message = Repo.get_by!(Message, content: "hello team")

      assert has_element?(view, "#message-#{message.id}-content", "hello team")
      refute has_element?(view, "#channel-empty-state")
    end

    test "appends a newly sent message after messages from earlier dates", %{
      conn: conn,
      scope: scope
    } do
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      other_scope = DiscordClone.AccountsFixtures.user_scope_fixture()

      DiscordCloneWeb.WorkspaceLiveTestHelpers.add_workspace_member!(workspace, other_scope)

      first =
        DiscordCloneWeb.WorkspaceLiveTestHelpers.insert_message!(
          workspace.default_channel_id,
          scope.user.id,
          "older message",
          ~U[2026-07-14 21:58:00Z]
        )

      second =
        DiscordCloneWeb.WorkspaceLiveTestHelpers.insert_message!(
          workspace.default_channel_id,
          other_scope.user.id,
          "newer old message",
          ~U[2026-07-15 07:04:00Z]
        )

      {:ok, view, _html} =
        live(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      refute has_element?(view, "#channel-messages > :not(article)")

      view
      |> form("#message-composer-form", message: %{content: "newest message"})
      |> render_submit()

      newest = Repo.get_by!(Message, content: "newest message")

      message_ids = DiscordCloneWeb.WorkspaceLiveTestHelpers.rendered_message_ids(view)

      assert message_ids == [
               "message-#{first.id}",
               "message-#{second.id}",
               "message-#{newest.id}"
             ]
    end

    test "ignores a blank message submission", %{conn: conn, scope: scope} do
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})

      {:ok, view, _html} =
        live(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      view
      |> form("#message-composer-form", message: %{content: "   "})
      |> render_submit()

      assert has_element?(view, "#channel-empty-state")
      assert Repo.aggregate(Message, :count) == 0
    end

    test "selects and cancels a reply target without losing the draft", %{
      conn: conn,
      scope: scope
    } do
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})

      {:ok, parent} =
        Chat.send_message(scope, workspace.default_channel_id, %{
          content:
            "A deliberately long parent message that should be shortened in the reply composer preview so the selected target stays compact and readable."
        })

      {:ok, deleted} =
        Chat.send_message(scope, workspace.default_channel_id, %{content: "deleted target"})

      {:ok, _deleted} = Chat.delete_message(scope, deleted.id)

      {:ok, view, _html} =
        live(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      refute has_element?(view, "#message-#{deleted.id}-reply")

      view
      |> form("#message-composer-form", message: %{content: "draft reply"})
      |> render_change()

      view
      |> element("#message-#{parent.id}-reply")
      |> render_click()

      assert has_element?(view, "#message-reply-target")
      assert has_element?(view, "#message-reply-target-author", scope.user.username)
      assert has_element?(view, "#message-reply-target-content", "…")
      assert has_element?(view, "#message-reply-target-cancel[aria-label='Cancel reply']")
      assert has_element?(view, "textarea#message_content", "draft reply")

      view
      |> element("#message-reply-target-cancel")
      |> render_click()

      refute has_element?(view, "#message-reply-target")
      assert has_element?(view, "textarea#message_content", "draft reply")
    end

    test "sends a flat reply, renders its direct-parent preview, and clears the target", %{
      conn: conn,
      scope: scope
    } do
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      channel_id = workspace.default_channel_id
      {:ok, parent} = Chat.send_message(scope, channel_id, %{content: "root message"})

      {:ok, view, _html} =
        live(conn, ~p"/workspaces/#{workspace.id}/channels/#{channel_id}")

      view |> element("#message-#{parent.id}-reply") |> render_click()

      view
      |> form("#message-composer-form", message: %{content: "reply body"})
      |> render_submit()

      reply = Repo.get_by!(Message, content: "reply body")

      assert reply.reply_to_message_id == parent.id
      refute has_element?(view, "#message-reply-target")
      assert has_element?(view, "#message-#{reply.id}-reply-preview")
      assert has_element?(view, "#message-#{reply.id}-reply-preview-author", scope.user.username)
      assert has_element?(view, "#message-#{reply.id}-reply-preview-content", "root message")

      view |> element("#message-#{reply.id}-reply") |> render_click()

      view
      |> form("#message-composer-form", message: %{content: "nested reply"})
      |> render_submit()

      nested_reply = Repo.get_by!(Message, content: "nested reply")

      assert nested_reply.reply_to_message_id == reply.id
      assert has_element?(view, "#message-#{nested_reply.id}-reply-preview-content", "reply body")

      refute has_element?(
               view,
               "#message-#{nested_reply.id}-reply-preview-content",
               "root message"
             )
    end

    test "preserves a valid reply target and draft when message validation fails", %{
      conn: conn,
      scope: scope
    } do
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      channel_id = workspace.default_channel_id
      {:ok, parent} = Chat.send_message(scope, channel_id, %{content: "reply here"})
      oversized_draft = String.duplicate("x", 4_001)

      {:ok, view, _html} =
        live(conn, ~p"/workspaces/#{workspace.id}/channels/#{channel_id}")

      view |> element("#message-#{parent.id}-reply") |> render_click()

      view
      |> form("#message-composer-form", message: %{content: oversized_draft})
      |> render_submit()

      assert has_element?(view, "#message-reply-target[data-message-id='#{parent.id}']")
      assert has_element?(view, "textarea#message_content", oversized_draft)
      assert Repo.aggregate(Message, :count) == 1
    end
  end

  describe "deleting messages" do
    setup :register_and_log_in_user

    test "replaces a deleted message with the deleted placeholder", %{conn: conn, scope: scope} do
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})

      {:ok, message} =
        Chat.send_message(scope, workspace.default_channel_id, %{content: "delete me"})

      {:ok, view, _html} =
        live(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      assert has_element?(view, "#message-#{message.id}-content", "delete me")

      view
      |> element("#message-#{message.id}-delete")
      |> render_click()

      assert has_element?(view, "#message-#{message.id}-deleted-placeholder", "Message deleted")
      refute has_element?(view, "#message-#{message.id}-content")
    end
  end

  describe "reply parent navigation" do
    setup :register_and_log_in_user

    test "loads, scrolls to, and highlights a live parent outside the current window", %{
      conn: conn,
      scope: scope
    } do
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      channel_id = workspace.default_channel_id
      {:ok, parent} = Chat.send_message(scope, channel_id, %{content: "distant parent"})

      for index <- 1..55 do
        {:ok, _message} = Chat.send_message(scope, channel_id, %{content: "filler #{index}"})
      end

      {:ok, reply} =
        Chat.send_message(scope, channel_id, %{
          content: "reply near the latest edge",
          reply_to_message_id: parent.id
        })

      {:ok, view, _html} =
        live(conn, ~p"/workspaces/#{workspace.id}/channels/#{channel_id}")

      refute has_element?(view, "#message-#{parent.id}")
      assert has_element?(view, "#message-#{reply.id}-reply-preview")

      view
      |> element("#message-#{reply.id}-reply-preview")
      |> render_click()

      assert has_element?(
               view,
               "#message-#{parent.id}[data-message-navigation-target='true'].message-target-highlight"
             )

      assert has_element?(
               view,
               "#channel-messages[data-scroll-target-kind='sequence'][data-scroll-target-seq='#{parent.seq}']"
             )
    end

    test "keeps replies but replaces a deleted parent's preview with a non-clickable placeholder",
         %{
           conn: conn,
           scope: scope
         } do
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      channel_id = workspace.default_channel_id
      {:ok, parent} = Chat.send_message(scope, channel_id, %{content: "sensitive parent"})

      {:ok, reply} =
        Chat.send_message(scope, channel_id, %{
          content: "durable reply",
          reply_to_message_id: parent.id
        })

      {:ok, view, _html} =
        live(conn, ~p"/workspaces/#{workspace.id}/channels/#{channel_id}")

      assert has_element?(view, "#message-#{reply.id}-reply-preview")
      {:ok, _deleted_parent} = Chat.delete_message(scope, parent.id)

      assert has_element?(
               view,
               "#message-#{reply.id}-deleted-reply-preview:not(button)",
               "Message deleted"
             )

      refute has_element?(view, "#message-#{reply.id}-reply-preview")
      refute has_element?(view, "#message-#{reply.id}-reply-preview-author")
      refute has_element?(view, "#message-#{reply.id}-reply-preview-content")
      assert Repo.get!(Message, reply.id).reply_to_message_id == parent.id
    end

    test "preserves the draft and clears a selected target deleted before send", %{
      conn: conn,
      scope: scope
    } do
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      channel_id = workspace.default_channel_id
      {:ok, parent} = Chat.send_message(scope, channel_id, %{content: "reply target"})

      {:ok, view, _html} =
        live(conn, ~p"/workspaces/#{workspace.id}/channels/#{channel_id}")

      view |> element("#message-#{parent.id}-reply") |> render_click()

      view
      |> form("#message-composer-form", message: %{content: "carefully written draft"})
      |> render_change()

      {:ok, _deleted_parent} = Chat.delete_message(scope, parent.id)

      refute has_element?(view, "#message-reply-target")
      assert has_element?(view, "textarea#message_content", "carefully written draft")
      assert has_element?(view, "#flash-error", "reply target was deleted")
    end

    test "recovers when the target is deleted during the send race", %{
      conn: conn,
      scope: scope
    } do
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      channel_id = workspace.default_channel_id
      {:ok, parent} = Chat.send_message(scope, channel_id, %{content: "racy target"})

      {:ok, view, _html} =
        live(conn, ~p"/workspaces/#{workspace.id}/channels/#{channel_id}")

      view |> element("#message-#{parent.id}-reply") |> render_click()

      parent
      |> Message.soft_delete_changeset(%{
        deleted_at: DateTime.utc_now(:second),
        deleted_by_user_id: scope.user.id
      })
      |> Repo.update!()

      view
      |> form("#message-composer-form", message: %{content: "draft sent during deletion"})
      |> render_submit()

      refute has_element?(view, "#message-reply-target")
      assert has_element?(view, "textarea#message_content", "draft sent during deletion")
      assert has_element?(view, "#flash-error", "reply target was deleted")
      refute Repo.get_by(Message, content: "draft sent during deletion")
    end

    test "gives the same safe feedback for deleted and inaccessible navigation targets", %{
      conn: conn,
      scope: scope
    } do
      inaccessible_scope = DiscordClone.AccountsFixtures.user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})

      {:ok, inaccessible_workspace} =
        Workspaces.create_workspace(inaccessible_scope, %{name: "Private"})

      {:ok, inaccessible_message} =
        Chat.send_message(inaccessible_scope, inaccessible_workspace.default_channel_id, %{
          content: "private message"
        })

      {:ok, deleted_message} =
        Chat.send_message(scope, workspace.default_channel_id, %{content: "deleted message"})

      {:ok, _deleted_message} = Chat.delete_message(scope, deleted_message.id)

      {:ok, view, _html} =
        live(
          conn,
          ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}"
        )

      for target_id <- [deleted_message.id, inaccessible_message.id, "not-a-uuid"] do
        render_hook(view, "navigate_reply_parent", %{"message-id" => target_id})
        assert has_element?(view, "#flash-error", "replied message is no longer available")
      end
    end
  end

  describe "toggling reactions" do
    setup :register_and_log_in_user

    test "adds and then removes a reaction on a message", %{conn: conn, scope: scope} do
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})

      {:ok, message} =
        Chat.send_message(scope, workspace.default_channel_id, %{content: "react to me"})

      {:ok, view, _html} =
        live(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      refute has_element?(view, "#message-#{message.id}-reaction-0")

      view
      |> element("#message-#{message.id}-reaction-option-0")
      |> render_click()

      assert has_element?(
               view,
               "#message-#{message.id}-reaction-0[data-current-user-reacted='true']"
             )

      view
      |> element("#message-#{message.id}-reaction-option-0")
      |> render_click()

      refute has_element?(view, "#message-#{message.id}-reaction-0")
    end
  end

  describe "message moderation menu visibility" do
    setup :register_and_log_in_user

    test "surfaces moderation controls to an owner over a member's message", %{
      conn: owner_conn,
      scope: owner_scope
    } do
      member_scope = DiscordClone.AccountsFixtures.user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, member_scope, "member")

      {:ok, message} =
        Chat.send_message(member_scope, workspace.default_channel_id, %{content: "hi from member"})

      {:ok, view, _html} =
        live(owner_conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      assert has_element?(view, "#message-#{message.id}-actions")
      assert has_element?(view, "#message-#{message.id}-delete")
      assert has_element?(view, "#message-#{message.id}-promote-to-admin")
      assert has_element?(view, "#message-#{message.id}-mute")
      assert has_element?(view, "#message-#{message.id}-kick")
      assert has_element?(view, "#message-#{message.id}-ban")
    end

    test "hides the moderation menu from a member over another member's message", %{
      conn: conn,
      scope: viewer_scope
    } do
      owner_scope = DiscordClone.AccountsFixtures.user_scope_fixture()
      author_scope = DiscordClone.AccountsFixtures.user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, viewer_scope, "member")
      add_workspace_member!(workspace, author_scope, "member")

      {:ok, message} =
        Chat.send_message(author_scope, workspace.default_channel_id, %{content: "peer message"})

      {:ok, view, _html} =
        live(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      assert has_element?(view, "#message-#{message.id}-content", "peer message")
      refute has_element?(view, "#message-#{message.id}-actions")
      refute has_element?(view, "#message-#{message.id}-mute")
    end

    test "surfaces moderation controls to an admin over a member's message", %{
      conn: conn,
      scope: admin_scope
    } do
      owner_scope = DiscordClone.AccountsFixtures.user_scope_fixture()
      member_scope = DiscordClone.AccountsFixtures.user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, admin_scope, "admin")
      add_workspace_member!(workspace, member_scope, "member")

      {:ok, message} =
        Chat.send_message(member_scope, workspace.default_channel_id, %{content: "member ping"})

      {:ok, view, _html} =
        live(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      assert has_element?(view, "#message-#{message.id}-actions")
      assert has_element?(view, "#message-#{message.id}-mute")
      assert has_element?(view, "#message-#{message.id}-kick")
    end

    test "hides moderation controls from an admin over an owner's message", %{
      conn: conn,
      scope: admin_scope
    } do
      owner_scope = DiscordClone.AccountsFixtures.user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, admin_scope, "admin")

      {:ok, message} =
        Chat.send_message(owner_scope, workspace.default_channel_id, %{content: "owner note"})

      {:ok, view, _html} =
        live(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      assert has_element?(view, "#message-#{message.id}-content", "owner note")
      refute has_element?(view, "#message-#{message.id}-actions")
    end
  end

  describe "forged member actions" do
    setup :register_and_log_in_user

    test "rejects a member-action event from a non-permitted actor", %{
      conn: conn,
      scope: viewer_scope
    } do
      owner_scope = DiscordClone.AccountsFixtures.user_scope_fixture()
      target_scope = DiscordClone.AccountsFixtures.user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, viewer_scope, "member")
      add_workspace_member!(workspace, target_scope, "member")

      {:ok, view, _html} =
        live(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      html =
        render_hook(view, "member_action", %{
          "action" => "promote_to_admin",
          "user_id" => target_scope.user.id
        })

      # The LiveView event path handled and rejected the forged action itself:
      # it surfaces the error flash rather than silently applying the change.
      assert html =~ "Member action could not be completed."

      assert Repo.get_by(WorkspaceMembership,
               workspace_id: workspace.id,
               user_id: target_scope.user.id
             ).role == "member"
    end
  end

  defp add_workspace_member!(workspace, scope, role) do
    {:ok, membership} =
      %WorkspaceMembership{}
      |> WorkspaceMembership.changeset(%{
        workspace_id: workspace.id,
        user_id: scope.user.id,
        role: role
      })
      |> Repo.insert()

    :ok = Chat.initialize_workspace_reads_for_user(scope.user.id, workspace.id)

    membership
  end
end
