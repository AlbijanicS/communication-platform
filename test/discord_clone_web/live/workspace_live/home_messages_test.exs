defmodule DiscordCloneWeb.WorkspaceLive.HomeMessagesTest do
  use DiscordCloneWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import DiscordCloneWeb.WorkspaceLiveTestHelpers

  alias DiscordClone.Workspaces
  alias DiscordClone.Chat
  alias DiscordClone.Chat.Message
  alias DiscordClone.Chat.Runtime
  alias DiscordClone.Repo

  describe "messages, reactions, composer, and typing" do
    setup :register_and_log_in_user

    test "renders persisted channel messages with author and timestamp", %{
      conn: conn,
      scope: scope
    } do
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})

      message =
        insert_message!(
          workspace.default_channel_id,
          scope.user.id,
          "Hello <strong>there</strong>",
          ~U[2026-06-19 10:30:00Z]
        )

      {:ok, view, _html} =
        live(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      assert has_element?(view, "#message-#{message.id}")
      assert has_element?(view, "#message-#{message.id}-author", scope.user.username)

      assert has_element?(
               view,
               "#message-#{message.id} time[datetime='2026-06-19T10:30:00.000000Z']"
             )

      assert has_element?(view, "#message-#{message.id}-content", message.content)
    end

    test "renders supported emoji shortcodes in persisted channel messages", %{
      conn: conn,
      scope: scope
    } do
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})

      message =
        insert_message!(
          workspace.default_channel_id,
          scope.user.id,
          "Ship it :thumbsup:",
          ~U[2026-06-19 10:30:00Z]
        )

      {:ok, view, _html} =
        live(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      assert Repo.get!(Message, message.id).content == "Ship it :thumbsup:"
      assert has_element?(view, "#message-#{message.id}-content", "Ship it 👍")
    end

    test "leaves unknown emoji shortcodes unchanged in channel messages", %{
      conn: conn,
      scope: scope
    } do
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})

      message =
        insert_message!(
          workspace.default_channel_id,
          scope.user.id,
          "Launch :rocketship:",
          ~U[2026-06-19 10:30:00Z]
        )

      {:ok, view, _html} =
        live(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      assert has_element?(view, "#message-#{message.id}-content", "Launch :rocketship:")
    end

    test "renders reaction pills under persisted channel messages", %{
      conn: conn,
      scope: scope
    } do
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})

      message =
        insert_message!(
          workspace.default_channel_id,
          scope.user.id,
          "tiny celebration",
          ~U[2026-06-19 10:30:00Z]
        )

      assert {:ok, _reaction} = Chat.toggle_reaction(scope, message.id, "👍")

      {:ok, view, _html} =
        live(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      assert has_element?(view, "#message-#{message.id}-reactions")

      assert has_element?(
               view,
               "#message-#{message.id}-reaction-0[aria-label='👍 reaction, 1 reaction, you reacted']",
               "👍 1"
             )
    end

    test "keeps reaction summaries visible after page refresh", %{
      conn: conn,
      scope: scope
    } do
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      channel_path = ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}"

      message =
        insert_message!(
          workspace.default_channel_id,
          scope.user.id,
          "refresh proof",
          ~U[2026-06-19 10:30:00Z]
        )

      assert {:ok, _reaction} = Chat.toggle_reaction(scope, message.id, "👍")

      {:ok, first_view, _html} = live(conn, channel_path)

      assert has_element?(
               first_view,
               "#message-#{message.id}-reaction-0[aria-label='👍 reaction, 1 reaction, you reacted']",
               "👍 1"
             )

      {:ok, refreshed_view, _html} = live(conn, channel_path)

      assert has_element?(
               refreshed_view,
               "#message-#{message.id}-reaction-0[aria-label='👍 reaction, 1 reaction, you reacted']",
               "👍 1"
             )
    end

    test "does not render empty reaction chrome for messages without reactions", %{
      conn: conn,
      scope: scope
    } do
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})

      message =
        insert_message!(
          workspace.default_channel_id,
          scope.user.id,
          "plain update",
          ~U[2026-06-19 10:30:00Z]
        )

      {:ok, view, _html} =
        live(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      assert has_element?(view, "#message-#{message.id}-content", "plain update")
      refute has_element?(view, "#message-#{message.id}-reactions")
      refute has_element?(view, "#message-#{message.id}-reaction-0")
    end

    test "renders another member's reaction without the current user state", %{
      conn: conn,
      scope: scope
    } do
      other_scope = DiscordClone.AccountsFixtures.user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      add_workspace_member!(workspace, other_scope)

      message =
        insert_message!(
          workspace.default_channel_id,
          scope.user.id,
          "someone noticed",
          ~U[2026-06-19 10:30:00Z]
        )

      assert {:ok, _reaction} = Chat.toggle_reaction(other_scope, message.id, "❤️")

      {:ok, view, _html} =
        live(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      assert has_element?(
               view,
               "#message-#{message.id}-reaction-0[data-current-user-reacted='false'][aria-label='❤️ reaction, 1 reaction, you have not reacted']",
               "❤️ 1"
             )
    end

    test "renders reaction pills under compact grouped message rows", %{
      conn: conn,
      scope: scope
    } do
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})

      first_message =
        insert_message!(
          workspace.default_channel_id,
          scope.user.id,
          "first thought",
          ~U[2026-06-19 10:30:00Z]
        )

      second_message =
        insert_message!(
          workspace.default_channel_id,
          scope.user.id,
          "follow-up thought",
          ~U[2026-06-19 10:31:00Z]
        )

      assert {:ok, _reaction} = Chat.toggle_reaction(scope, second_message.id, "👀")

      {:ok, view, _html} =
        live(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      assert has_element?(view, "#message-#{first_message.id}[data-message-row='full']")
      assert has_element?(view, "#message-#{second_message.id}[data-message-row='compact']")

      assert has_element?(
               view,
               "#message-#{first_message.id}[data-message-id='#{first_message.id}'][data-message-seq='#{first_message.seq}'][data-visible-read-observe='true']"
             )

      assert has_element?(
               view,
               "#message-#{second_message.id}-body #message-#{second_message.id}-reaction-0[data-current-user-reacted='true']",
               "👀 1"
             )
    end

    test "toggles a reaction from the fixed message palette", %{
      conn: conn,
      scope: scope
    } do
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})

      message =
        insert_message!(
          workspace.default_channel_id,
          scope.user.id,
          "please react",
          ~U[2026-06-19 10:30:00Z]
        )

      message_id = message.id

      {:ok, view, _html} =
        live(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      assert has_element?(
               view,
               "#message-#{message_id}-reaction-option-0[aria-label='React with 👍 to message']",
               "👍"
             )

      assert has_element?(
               view,
               "#message-#{message_id}-reaction-option-1[aria-label='React with ❤️ to message']",
               "❤️"
             )

      assert has_element?(
               view,
               "#message-#{message_id}-reaction-option-2[aria-label='React with 😂 to message']",
               "😂"
             )

      assert has_element?(
               view,
               "#message-#{message_id}-reaction-option-3[aria-label='React with 🎉 to message']",
               "🎉"
             )

      assert has_element?(
               view,
               "#message-#{message_id}-reaction-option-4[aria-label='React with 👀 to message']",
               "👀"
             )

      refute has_element?(
               view,
               "#message-#{message_id}-reaction-palette[class*='group-focus-within']"
             )

      view
      |> element("#message-#{message_id}-reaction-option-0")
      |> render_click()

      assert has_element?(
               view,
               "#message-#{message_id}-reaction-0[data-current-user-reacted='true'][aria-label='👍 reaction, 1 reaction, you reacted']",
               "👍 1"
             )

      assert {:ok, %{^message_id => [%{emoji: "👍", count: 1, reacted?: true}]}} =
               Chat.list_reaction_summaries(scope, [message_id])

      view
      |> element("#message-#{message_id}-reaction-option-0")
      |> render_click()

      refute has_element?(view, "#message-#{message_id}-reactions")
      refute has_element?(view, "#message-#{message_id}-reaction-0")

      assert {:ok, %{}} = Chat.list_reaction_summaries(scope, [message_id])
    end

    test "refreshes another connected viewer after a reaction changes", %{
      conn: viewer_conn,
      scope: viewer_scope
    } do
      sender_scope = DiscordClone.AccountsFixtures.user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(sender_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, viewer_scope)

      message =
        insert_message!(
          workspace.default_channel_id,
          sender_scope.user.id,
          "please react live",
          ~U[2026-06-19 10:30:00Z]
        )

      channel_path = ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}"
      sender_conn = build_conn() |> log_in_user(sender_scope.user)

      {:ok, viewer_view, _html} = live(viewer_conn, channel_path)
      {:ok, sender_view, _html} = live(sender_conn, channel_path)

      refute has_element?(viewer_view, "#message-#{message.id}-reactions")

      sender_view
      |> element("#message-#{message.id}-reaction-option-0")
      |> render_click()

      _ = :sys.get_state(viewer_view.pid)

      assert has_element?(
               viewer_view,
               "#message-#{message.id}-reaction-0[data-current-user-reacted='false'][aria-label='👍 reaction, 1 reaction, you have not reacted']",
               "👍 1"
             )

      assert has_element?(viewer_view, "#message-#{message.id}[data-message-row='full']")
      assert has_element?(viewer_view, "#message-#{message.id}-content", "please react live")
    end

    test "refreshes connected viewers with a deleted message placeholder and clears reactions", %{
      conn: viewer_conn,
      scope: viewer_scope
    } do
      owner_scope = DiscordClone.AccountsFixtures.user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, viewer_scope)

      message =
        insert_message!(
          workspace.default_channel_id,
          viewer_scope.user.id,
          "remove this live",
          ~U[2026-06-19 10:30:00Z]
        )

      assert {:ok, _reaction} = Chat.toggle_reaction(owner_scope, message.id, "👍")

      channel_path = ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}"
      {:ok, viewer_view, _html} = live(viewer_conn, channel_path)

      assert has_element?(viewer_view, "#message-#{message.id}-content", "remove this live")
      assert has_element?(viewer_view, "#message-#{message.id}-reaction-0", "👍 1")

      assert {:ok, _deleted_message} = Chat.delete_message(owner_scope, message.id)
      _ = :sys.get_state(viewer_view.pid)

      assert has_element?(
               viewer_view,
               "#message-#{message.id}-deleted-placeholder",
               "Message deleted"
             )

      refute has_element?(viewer_view, "#message-#{message.id}-content", "remove this live")
      refute has_element?(viewer_view, "#message-#{message.id}-reaction-0")
      refute has_element?(viewer_view, "#message-#{message.id}-reaction-option-0")
    end

    test "keeps the full message experience working together", %{
      conn: viewer_conn,
      scope: viewer_scope
    } do
      sender_scope = DiscordClone.AccountsFixtures.user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(sender_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, viewer_scope)
      channel_id = workspace.default_channel_id

      first_message =
        insert_message!(
          channel_id,
          sender_scope.user.id,
          "Ship it :thumbsup:",
          ~U[2026-06-19 10:30:00Z]
        )

      second_message =
        insert_message!(
          channel_id,
          sender_scope.user.id,
          "Launch :rocketship:",
          ~U[2026-06-19 10:31:00Z]
        )

      channel_path = ~p"/workspaces/#{workspace.id}/channels/#{channel_id}"
      sender_conn = build_conn() |> log_in_user(sender_scope.user)

      {:ok, viewer_view, _html} = live(viewer_conn, channel_path)
      {:ok, sender_view, _html} = live(sender_conn, channel_path)

      assert has_element?(viewer_view, "#channel-message-surface")
      assert has_element?(viewer_view, "#channel-messages[phx-hook='ChannelMessages']")
      assert has_element?(viewer_view, "#message-composer-form")
      assert has_element?(viewer_view, "#message-composer-shell")
      refute has_element?(viewer_view, "#message-composer-submit")
      assert has_element?(viewer_view, "#message-#{first_message.id}[data-message-row='full']")
      assert has_element?(viewer_view, "#message-#{first_message.id}-avatar")
      assert has_element?(viewer_view, "#message-#{first_message.id}-header")
      assert has_element?(viewer_view, "#message-#{first_message.id}-content", "Ship it 👍")

      assert has_element?(
               viewer_view,
               "#message-#{second_message.id}[data-message-row='compact']"
             )

      assert has_element?(viewer_view, "#message-#{second_message.id}-spacer[aria-hidden='true']")

      assert has_element?(
               viewer_view,
               "#message-#{second_message.id}-content",
               "Launch :rocketship:"
             )

      refute has_element?(viewer_view, "#message-#{second_message.id}-avatar")
      refute has_element?(viewer_view, "#message-#{second_message.id}-reactions")

      assert has_element?(
               sender_view,
               "#message-#{second_message.id}-reaction-option-0[aria-label='React with 👍 to message']",
               "👍"
             )

      sender_view
      |> element("#message-#{second_message.id}-reaction-option-0")
      |> render_click()

      _ = :sys.get_state(viewer_view.pid)

      assert has_element?(
               viewer_view,
               "#message-#{second_message.id}-reaction-0[data-current-user-reacted='false'][aria-label='👍 reaction, 1 reaction, you have not reacted']",
               "👍 1"
             )

      viewer_view
      |> element("#message-#{second_message.id}-reaction-option-0")
      |> render_click()

      assert has_element?(
               viewer_view,
               "#message-#{second_message.id}-reaction-0[data-current-user-reacted='true'][aria-label='👍 reaction, 2 reactions, you reacted']",
               "👍 2"
             )

      viewer_view
      |> element("#message-#{second_message.id}-reaction-option-0")
      |> render_click()

      assert has_element?(
               viewer_view,
               "#message-#{second_message.id}-reaction-0[data-current-user-reacted='false'][aria-label='👍 reaction, 1 reaction, you have not reacted']",
               "👍 1"
             )

      {:ok, refreshed_view, _html} = live(viewer_conn, channel_path)

      assert has_element?(
               refreshed_view,
               "#message-#{second_message.id}-reaction-0[data-current-user-reacted='false'][aria-label='👍 reaction, 1 reaction, you have not reacted']",
               "👍 1"
             )
    end

    test "rejects invalid reaction payloads sent to the palette event", %{
      conn: conn,
      scope: scope
    } do
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})

      message =
        insert_message!(
          workspace.default_channel_id,
          scope.user.id,
          "tamper-resistant",
          ~U[2026-06-19 10:30:00Z]
        )

      {:ok, view, _html} =
        live(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      render_click(view, "toggle_reaction", %{
        "message-id" => "not-a-uuid",
        "emoji" => "👍❤️"
      })

      assert {:ok, %{}} = Chat.list_reaction_summaries(scope, [message.id])
    end

    test "renders persisted channel messages in a stable anchored row layout", %{
      conn: conn,
      scope: scope
    } do
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})

      content = "first line\n#{String.duplicate("unbroken", 24)} 😀😀😀"

      message =
        insert_message!(
          workspace.default_channel_id,
          scope.user.id,
          content,
          ~U[2026-06-19 10:30:00Z]
        )

      {:ok, view, _html} =
        live(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      assert has_element?(view, "#message-#{message.id}[data-message-row='full']")

      assert has_element?(
               view,
               "#message-#{message.id}-avatar",
               scope.user.username |> String.first() |> String.upcase()
             )

      assert has_element?(view, "#message-#{message.id}-body")
      assert has_element?(view, "#message-#{message.id}-header")
      assert has_element?(view, "#message-#{message.id}-author", scope.user.username)

      assert has_element?(
               view,
               "#message-#{message.id}-timestamp[datetime='2026-06-19T10:30:00.000000Z']"
             )

      content_text =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> then(& &1["#message-#{message.id}-content"])
        |> LazyHTML.text()
        |> String.trim()

      assert content_text == content
    end

    test "groups consecutive same-author messages within five minutes", %{
      conn: conn,
      scope: scope
    } do
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})

      first_message =
        insert_message!(
          workspace.default_channel_id,
          scope.user.id,
          "first thought",
          ~U[2026-06-19 10:30:00Z]
        )

      second_message =
        insert_message!(
          workspace.default_channel_id,
          scope.user.id,
          "follow-up thought",
          ~U[2026-06-19 10:33:00Z]
        )

      {:ok, view, _html} =
        live(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      assert has_element?(view, "#message-#{first_message.id}[data-message-row='full']")
      assert has_element?(view, "#message-#{first_message.id}-avatar")
      assert has_element?(view, "#message-#{first_message.id}-header")

      assert has_element?(view, "#message-#{second_message.id}[data-message-row='compact']")
      assert has_element?(view, "#message-#{second_message.id}-spacer[aria-hidden='true']")
      assert has_element?(view, "#message-#{second_message.id}-body")
      assert has_element?(view, "#message-#{second_message.id}-content", "follow-up thought")
      refute has_element?(view, "#message-#{second_message.id}-avatar")
      refute has_element?(view, "#message-#{second_message.id}-header")
    end

    test "keeps polished row and composer surfaces on stable selectors", %{
      conn: conn,
      scope: scope
    } do
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})

      first_message =
        insert_message!(
          workspace.default_channel_id,
          scope.user.id,
          "anchored thought",
          ~U[2026-06-19 10:30:00Z]
        )

      second_message =
        insert_message!(
          workspace.default_channel_id,
          scope.user.id,
          "connected follow-up",
          ~U[2026-06-19 10:31:00Z]
        )

      {:ok, view, _html} =
        live(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      assert has_element?(
               view,
               "#message-#{first_message.id}[data-message-row='full'][data-hover-surface='message-row']"
             )

      assert has_element?(
               view,
               "#message-#{second_message.id}[data-message-row='compact'][data-hover-surface='message-row']"
             )

      assert has_element?(view, "#message-composer-panel #message-composer-form")
      assert has_element?(view, "#message-composer-shell #message_content")
      refute has_element?(view, "#message-composer-submit")
    end

    test "starts a full message row when the speaker changes", %{
      conn: conn,
      scope: first_scope
    } do
      second_scope = DiscordClone.AccountsFixtures.user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(first_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, second_scope)

      first_message =
        insert_message!(
          workspace.default_channel_id,
          first_scope.user.id,
          "first speaker",
          ~U[2026-06-19 10:30:00Z]
        )

      second_message =
        insert_message!(
          workspace.default_channel_id,
          second_scope.user.id,
          "second speaker",
          ~U[2026-06-19 10:31:00Z]
        )

      {:ok, view, _html} =
        live(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      assert has_element?(view, "#message-#{first_message.id}[data-message-row='full']")
      assert has_element?(view, "#message-#{second_message.id}[data-message-row='full']")
      assert has_element?(view, "#message-#{second_message.id}-avatar")
      assert has_element?(view, "#message-#{second_message.id}-header")

      assert has_element?(
               view,
               "#message-#{second_message.id}-author",
               second_scope.user.username
             )
    end

    test "starts a full message row when the same speaker is outside the grouping window", %{
      conn: conn,
      scope: scope
    } do
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})

      first_message =
        insert_message!(
          workspace.default_channel_id,
          scope.user.id,
          "morning note",
          ~U[2026-06-19 10:30:00Z]
        )

      second_message =
        insert_message!(
          workspace.default_channel_id,
          scope.user.id,
          "later note",
          ~U[2026-06-19 10:36:00Z]
        )

      {:ok, view, _html} =
        live(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      assert has_element?(view, "#message-#{first_message.id}[data-message-row='full']")
      assert has_element?(view, "#message-#{second_message.id}[data-message-row='full']")
      assert has_element?(view, "#message-#{second_message.id}-avatar")
      assert has_element?(view, "#message-#{second_message.id}-header")

      assert has_element?(
               view,
               "#message-#{second_message.id}-timestamp[datetime='2026-06-19T10:36:00.000000Z']"
             )
    end

    test "renders persisted messages after channel runtime loss", %{
      conn: conn,
      scope: scope
    } do
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      channel_id = workspace.default_channel_id

      first_message =
        insert_message!(
          channel_id,
          scope.user.id,
          "before runtime loss",
          ~U[2026-06-19 10:30:00Z]
        )

      assert {:ok, first_pid} = Chat.ensure_channel_runtime(scope, channel_id)
      ref = Process.monitor(first_pid)
      Process.exit(first_pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^first_pid, :killed}
      _ = :sys.get_state(DiscordClone.Chat.ConversationSupervisor)

      second_message =
        insert_message!(
          channel_id,
          scope.user.id,
          "after runtime loss",
          ~U[2026-06-19 10:31:00Z]
        )

      {:ok, view, _html} = live(conn, ~p"/workspaces/#{workspace.id}/channels/#{channel_id}")

      assert has_element?(view, "#message-#{first_message.id}-content", "before runtime loss")
      assert has_element?(view, "#message-#{second_message.id}-content", "after runtime loss")

      replacement_pid = Runtime.conversation_pid(channel_id)
      assert is_pid(replacement_pid)
      assert replacement_pid != first_pid
    end

    test "renders persisted reaction summaries after channel runtime loss", %{
      conn: conn,
      scope: scope
    } do
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      channel_id = workspace.default_channel_id

      message =
        insert_message!(
          channel_id,
          scope.user.id,
          "reaction before runtime loss",
          ~U[2026-06-19 10:30:00Z]
        )

      assert {:ok, _reaction} = Chat.toggle_reaction(scope, message.id, "👍")

      assert {:ok, first_pid} = Chat.ensure_channel_runtime(scope, channel_id)
      ref = Process.monitor(first_pid)
      Process.exit(first_pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^first_pid, :killed}
      _ = :sys.get_state(DiscordClone.Chat.ConversationSupervisor)

      {:ok, view, _html} = live(conn, ~p"/workspaces/#{workspace.id}/channels/#{channel_id}")

      assert has_element?(
               view,
               "#message-#{message.id}-reaction-0[aria-label='👍 reaction, 1 reaction, you reacted']",
               "👍 1"
             )

      replacement_pid = Runtime.conversation_pid(channel_id)
      assert is_pid(replacement_pid)
      assert replacement_pid != first_pid
    end

    test "sends a message into the current channel stream and clears the composer", %{
      conn: conn,
      scope: scope
    } do
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})

      {:ok, view, _html} =
        live(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      view
      |> form("#message-composer-form",
        message: %{
          content: "  hello from liveview  "
        }
      )
      |> render_submit()

      message = Repo.one!(Message)

      assert message.content == "hello from liveview"
      assert message.channel_id == workspace.default_channel_id
      assert message.user_id == scope.user.id
      assert has_element?(view, "#message-#{message.id}")
      assert has_element?(view, "#message-#{message.id}[data-message-row='full']")
      assert has_element?(view, "#message-#{message.id}-author", scope.user.username)
      assert has_element?(view, "#message-#{message.id}-content", "hello from liveview")
      refute has_element?(view, "textarea#message_content", "  hello from liveview  ")

      assert_push_event(view, "clear_message_composer", %{input_id: "message_content"})

      assert_push_event(view, "scroll_channel_messages_to_bottom", %{
        container_id: "channel-messages"
      })

      _ = :sys.get_state(view.pid)

      assert has_element?(view, "#message-#{message.id}[data-message-row='full']")
      assert has_element?(view, "#message-#{message.id}-author", scope.user.username)
    end

    test "ignores blank message submits without showing composer errors", %{
      conn: conn,
      scope: scope
    } do
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})

      {:ok, view, _html} =
        live(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      view
      |> form("#message-composer-form", message: %{content: "   "})
      |> render_submit()

      assert Repo.aggregate(Message, :count) == 0
      assert has_element?(view, "#message-composer-form")
      refute has_element?(view, "#message_content.textarea-error")
      refute has_element?(view, "#message-composer-form", "can't be blank")
      refute_push_event(view, "clear_message_composer", %{input_id: _input_id})
      refute_push_event(view, "scroll_channel_messages_to_bottom", %{container_id: _container_id})
    end

    test "groups a sent live message with the current newest same-author message", %{
      conn: conn,
      scope: scope
    } do
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})

      existing_message =
        insert_message!(
          workspace.default_channel_id,
          scope.user.id,
          "already thinking",
          DateTime.add(DateTime.utc_now(:second), -60, :second)
        )

      {:ok, view, _html} =
        live(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      view
      |> form("#message-composer-form", message: %{content: "same thread"})
      |> render_submit()

      sent_message =
        Message
        |> order_by([message], desc: message.seq)
        |> limit(1)
        |> Repo.one!()

      assert has_element?(view, "#message-#{existing_message.id}[data-message-row='full']")
      assert has_element?(view, "#message-#{sent_message.id}[data-message-row='compact']")
      assert has_element?(view, "#message-#{sent_message.id}-spacer[aria-hidden='true']")
      refute has_element?(view, "#message-#{sent_message.id}-header")
    end

    test "renders the sender's saved message exactly once", %{
      conn: conn,
      scope: scope
    } do
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})

      {:ok, view, _html} =
        live(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      view
      |> form("#message-composer-form", message: %{content: "one local copy"})
      |> render_submit()

      message = Repo.one!(Message)

      message_ids =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> then(& &1["#channel-messages > article"])
        |> LazyHTML.attribute("id")

      assert message_ids == ["message-#{message.id}"]
      assert has_element?(view, "#message-#{message.id}-content", "one local copy")
    end

    test "keeps invalid message content visible with field errors", %{
      conn: conn,
      scope: scope
    } do
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      content = String.duplicate("a", 4_001)

      {:ok, view, _html} =
        live(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      view
      |> form("#message-composer-form", message: %{content: content})
      |> render_submit()

      assert Repo.aggregate(Message, :count) == 0
      assert has_element?(view, "#message-composer-form")
      assert has_element?(view, "textarea#message_content.textarea-error", content)

      assert has_element?(
               view,
               "#message-composer-form",
               "should be at most 4000 character(s)"
             )

      refute_push_event(view, "clear_message_composer", %{input_id: _input_id})
    end

    test "shows a sent message after reopening the channel page", %{
      conn: conn,
      scope: scope
    } do
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})

      {:ok, view, _html} =
        live(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      view
      |> form("#message-composer-form", message: %{content: "reload proof"})
      |> render_submit()

      message = Repo.one!(Message)

      {:ok, reloaded_view, _html} =
        live(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      assert has_element?(reloaded_view, "#message-#{message.id}")
      assert has_element?(reloaded_view, "#message-#{message.id}-content", "reload proof")
    end

    test "delivers sent messages live to another member in the same channel", %{
      conn: conn,
      scope: member_scope
    } do
      owner_scope = DiscordClone.AccountsFixtures.user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, member_scope)
      channel_path = ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}"

      existing_message =
        insert_message!(
          workspace.default_channel_id,
          member_scope.user.id,
          "already here",
          ~U[2026-06-19 10:00:00Z]
        )

      sender_conn = build_conn() |> log_in_user(owner_scope.user)

      {:ok, receiver_view, _html} = live(conn, channel_path)
      {:ok, sender_view, _html} = live(sender_conn, channel_path)

      sender_view
      |> form("#message-composer-form", message: %{content: "live hello"})
      |> render_submit()

      message =
        Message
        |> order_by([message], desc: message.seq)
        |> limit(1)
        |> Repo.one!()

      assert has_element?(receiver_view, "#message-#{message.id}")
      assert has_element?(receiver_view, "#message-#{message.id}[data-message-row='full']")

      assert has_element?(
               receiver_view,
               "#message-#{message.id}-author",
               owner_scope.user.username
             )

      assert has_element?(receiver_view, "#message-#{message.id}-content", "live hello")

      assert_push_event(receiver_view, "scroll_channel_messages_to_bottom", %{
        container_id: "channel-messages"
      })

      message_ids =
        receiver_view
        |> render()
        |> LazyHTML.from_fragment()
        |> then(& &1["#channel-messages > article"])
        |> LazyHTML.attribute("id")

      assert List.last(message_ids) == "message-#{message.id}"
      assert "message-#{existing_message.id}" in message_ids
    end

    test "keeps selected-channel live messages unread without duplicating timeline entries", %{
      conn: conn,
      scope: member_scope
    } do
      owner_scope = DiscordClone.AccountsFixtures.user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, member_scope)
      :ok = Chat.initialize_workspace_reads_for_user(member_scope.user.id, workspace.id)

      channel_path = ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}"
      sender_conn = build_conn() |> log_in_user(owner_scope.user)

      {:ok, receiver_view, _html} = live(conn, channel_path)
      {:ok, sender_view, _html} = live(sender_conn, channel_path)

      sender_view
      |> form("#message-composer-form", message: %{content: "read while open"})
      |> render_submit()

      message =
        Message
        |> order_by([message], desc: message.seq)
        |> limit(1)
        |> Repo.one!()

      _ = :sys.get_state(receiver_view.pid)

      assert has_element?(receiver_view, "#message-#{message.id}-content", "read while open")
      refute has_element?(receiver_view, "#channel-#{workspace.default_channel_id}-unread-badge")

      assert Chat.list_unread_counts(member_scope, workspace.id) ==
               {:ok, %{workspace.default_channel_id => 1}}

      message_ids =
        receiver_view
        |> render()
        |> LazyHTML.from_fragment()
        |> then(& &1["#channel-messages > article"])
        |> LazyHTML.attribute("id")

      assert Enum.count(message_ids, &(&1 == "message-#{message.id}")) == 1
    end

    test "does not deliver live messages across channels in the same workspace", %{
      conn: conn,
      scope: member_scope
    } do
      owner_scope = DiscordClone.AccountsFixtures.user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      {:ok, other_channel} = Workspaces.create_channel(owner_scope, workspace.id, %{name: "ops"})
      add_workspace_member!(workspace, member_scope)

      selected_channel_path =
        ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}"

      other_channel_path = ~p"/workspaces/#{workspace.id}/channels/#{other_channel.id}"
      sender_conn = build_conn() |> log_in_user(owner_scope.user)

      {:ok, selected_channel_view, _html} = live(conn, selected_channel_path)
      {:ok, other_channel_view, _html} = live(conn, other_channel_path)
      {:ok, sender_view, _html} = live(sender_conn, selected_channel_path)

      sender_view
      |> form("#message-composer-form", message: %{content: "only planning"})
      |> render_submit()

      message =
        Message
        |> order_by([message], desc: message.seq)
        |> limit(1)
        |> Repo.one!()

      assert has_element?(
               selected_channel_view,
               "#message-#{message.id}-content",
               "only planning"
             )

      refute has_element?(other_channel_view, "#message-#{message.id}")

      other_channel_message_ids =
        other_channel_view
        |> render()
        |> LazyHTML.from_fragment()
        |> then(& &1["#channel-messages > article"])
        |> LazyHTML.attribute("id")

      refute "message-#{message.id}" in other_channel_message_ids
    end

    test "recovers live-delivered messages from Postgres after receiver refresh", %{
      conn: conn,
      scope: member_scope
    } do
      owner_scope = DiscordClone.AccountsFixtures.user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, member_scope)
      channel_path = ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}"
      sender_conn = build_conn() |> log_in_user(owner_scope.user)

      {:ok, receiver_view, _html} = live(conn, channel_path)
      {:ok, sender_view, _html} = live(sender_conn, channel_path)

      sender_view
      |> form("#message-composer-form", message: %{content: "refresh after live"})
      |> render_submit()

      message =
        Message
        |> order_by([message], desc: message.seq)
        |> limit(1)
        |> Repo.one!()

      assert has_element?(receiver_view, "#message-#{message.id}-content", "refresh after live")

      {:ok, refreshed_receiver_view, _html} = live(conn, channel_path)

      assert has_element?(
               refreshed_receiver_view,
               "#message-#{message.id}-content",
               "refresh after live"
             )
    end

    test "keeps receiver composer state when a live message arrives", %{
      conn: conn,
      scope: member_scope
    } do
      owner_scope = DiscordClone.AccountsFixtures.user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, member_scope)
      channel_path = ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}"
      sender_conn = build_conn() |> log_in_user(owner_scope.user)
      too_long_content = String.duplicate("draft", 801)

      {:ok, receiver_view, _html} = live(conn, channel_path)
      {:ok, sender_view, _html} = live(sender_conn, channel_path)

      receiver_view
      |> form("#message-composer-form", message: %{content: too_long_content})
      |> render_submit()

      assert has_element?(
               receiver_view,
               "textarea#message_content.textarea-error",
               too_long_content
             )

      sender_view
      |> form("#message-composer-form", message: %{content: "while you type"})
      |> render_submit()

      message =
        Message
        |> order_by([message], desc: message.seq)
        |> limit(1)
        |> Repo.one!()

      assert has_element?(receiver_view, "#message-#{message.id}-content", "while you type")

      assert has_element?(
               receiver_view,
               "textarea#message_content.textarea-error",
               too_long_content
             )
    end

    test "shows another member typing in the same channel and hides self typing", %{
      conn: conn,
      scope: receiver_scope
    } do
      sender_scope =
        %{username: "typing_sender"}
        |> DiscordClone.AccountsFixtures.user_fixture()
        |> DiscordClone.AccountsFixtures.user_scope_fixture()

      {:ok, workspace} = Workspaces.create_workspace(receiver_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, sender_scope)
      channel_path = ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}"
      sender_conn = build_conn() |> log_in_user(sender_scope.user)

      {:ok, receiver_view, _html} = live(conn, channel_path)
      {:ok, sender_view, _html} = live(sender_conn, channel_path)

      sender_view
      |> form("#message-composer-form", message: %{content: "typing now"})
      |> render_change()

      assert has_element?(
               receiver_view,
               "#channel-typing-indicator [data-typing-user-id='#{sender_scope.user.id}']",
               "typing_sender"
             )

      sender_view
      |> form("#message-composer-form", message: %{content: "still typing"})
      |> render_change()

      refute has_element?(
               sender_view,
               "#channel-typing-indicator [data-typing-user-id='#{sender_scope.user.id}']"
             )

      sender_view
      |> form("#message-composer-form", message: %{content: ""})
      |> render_change()

      refute has_element?(
               receiver_view,
               "#channel-typing-indicator [data-typing-user-id='#{sender_scope.user.id}']"
             )

      sender_view
      |> form("#message-composer-form", message: %{content: "typing before submit"})
      |> render_change()

      assert has_element?(
               receiver_view,
               "#channel-typing-indicator [data-typing-user-id='#{sender_scope.user.id}']",
               "typing_sender"
             )

      sender_view
      |> form("#message-composer-form", message: %{content: "sent after typing"})
      |> render_submit()

      refute has_element?(
               receiver_view,
               "#channel-typing-indicator [data-typing-user-id='#{sender_scope.user.id}']"
             )
    end

    test "does not show typing indicators across channels in the same workspace", %{
      conn: conn,
      scope: receiver_scope
    } do
      sender_scope =
        %{username: "typing_sender"}
        |> DiscordClone.AccountsFixtures.user_fixture()
        |> DiscordClone.AccountsFixtures.user_scope_fixture()

      {:ok, workspace} = Workspaces.create_workspace(receiver_scope, %{name: "Foundry"})

      {:ok, other_channel} =
        Workspaces.create_channel(receiver_scope, workspace.id, %{name: "ops"})

      add_workspace_member!(workspace, sender_scope)

      default_channel_path =
        ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}"

      other_channel_path = ~p"/workspaces/#{workspace.id}/channels/#{other_channel.id}"
      sender_conn = build_conn() |> log_in_user(sender_scope.user)

      {:ok, receiver_view, _html} = live(conn, default_channel_path)
      {:ok, other_channel_view, _html} = live(conn, other_channel_path)
      {:ok, sender_view, _html} = live(sender_conn, default_channel_path)

      sender_view
      |> form("#message-composer-form", message: %{content: "typing in general"})
      |> render_change()

      assert has_element?(
               receiver_view,
               "#channel-typing-indicator [data-typing-user-id='#{sender_scope.user.id}']",
               "typing_sender"
             )

      refute has_element?(
               other_channel_view,
               "#channel-typing-indicator [data-typing-user-id='#{sender_scope.user.id}']"
             )
    end

    test "removes another member typing indicator after typing stops", %{
      conn: conn,
      scope: receiver_scope
    } do
      sender_scope =
        %{username: "typing_sender"}
        |> DiscordClone.AccountsFixtures.user_fixture()
        |> DiscordClone.AccountsFixtures.user_scope_fixture()

      {:ok, workspace} = Workspaces.create_workspace(receiver_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, sender_scope)
      channel_id = workspace.default_channel_id
      channel_path = ~p"/workspaces/#{workspace.id}/channels/#{channel_id}"
      sender_conn = build_conn() |> log_in_user(sender_scope.user)
      sender_id = sender_scope.user.id

      assert :ok = Chat.subscribe_to_channel_messages(receiver_scope, channel_id)

      {:ok, receiver_view, _html} = live(conn, channel_path)
      {:ok, sender_view, _html} = live(sender_conn, channel_path)

      sender_view
      |> form("#message-composer-form", message: %{content: "typing now"})
      |> render_change()

      assert has_element?(
               receiver_view,
               "#channel-typing-indicator [data-typing-user-id='#{sender_id}']",
               "typing_sender"
             )

      assert :ok = Chat.user_stopped_typing(sender_scope, channel_id)

      assert_receive {:typing_stopped, %{conversation_id: ^channel_id, user_id: ^sender_id}}

      refute has_element?(
               receiver_view,
               "#channel-typing-indicator [data-typing-user-id='#{sender_id}']"
             )
    end

    test "clears stale typing indicators after channel runtime loss", %{
      conn: conn,
      scope: receiver_scope
    } do
      sender_scope =
        %{username: "typing_sender"}
        |> DiscordClone.AccountsFixtures.user_fixture()
        |> DiscordClone.AccountsFixtures.user_scope_fixture()

      {:ok, workspace} = Workspaces.create_workspace(receiver_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, sender_scope)
      channel_id = workspace.default_channel_id
      channel_path = ~p"/workspaces/#{workspace.id}/channels/#{channel_id}"
      sender_conn = build_conn() |> log_in_user(sender_scope.user)
      sender_id = sender_scope.user.id

      {:ok, receiver_view, _html} = live(conn, channel_path)
      {:ok, sender_view, _html} = live(sender_conn, channel_path)

      sender_view
      |> form("#message-composer-form", message: %{content: "typing before crash"})
      |> render_change()

      assert has_element?(
               receiver_view,
               "#channel-typing-indicator [data-typing-user-id='#{sender_id}']",
               "typing_sender"
             )

      runtime_pid = Runtime.conversation_pid(channel_id)
      ref = Process.monitor(runtime_pid)
      Process.exit(runtime_pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^runtime_pid, :killed}

      refute has_element?(
               receiver_view,
               "#channel-typing-indicator [data-typing-user-id='#{sender_id}']"
             )

      sender_view
      |> form("#message-composer-form", message: %{content: "typing after restart"})
      |> render_change()

      assert has_element?(
               receiver_view,
               "#channel-typing-indicator [data-typing-user-id='#{sender_id}']",
               "typing_sender"
             )

      restarted_runtime_pid = Runtime.conversation_pid(channel_id)
      restarted_ref = Process.monitor(restarted_runtime_pid)
      Process.exit(restarted_runtime_pid, :kill)
      assert_receive {:DOWN, ^restarted_ref, :process, ^restarted_runtime_pid, :killed}

      refute has_element?(
               receiver_view,
               "#channel-typing-indicator [data-typing-user-id='#{sender_id}']"
             )
    end
  end
end
