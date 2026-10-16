defmodule DiscordCloneWeb.WorkspaceLive.HomeScrollTest do
  use DiscordCloneWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import DiscordCloneWeb.WorkspaceLiveTestHelpers

  alias DiscordClone.Workspaces
  alias DiscordClone.Chat
  alias DiscordClone.Chat.ChannelReadState
  alias DiscordClone.Repo

  describe "message window scrolling" do
    setup :register_and_log_in_user

    test "renders scroll-edge history controls without the old manual load button", %{
      conn: conn,
      scope: scope
    } do
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})

      for index <- 1..51 do
        insert_message!(
          workspace.default_channel_id,
          scope.user.id,
          "message #{index}",
          DateTime.add(~U[2026-06-19 10:00:00Z], index, :second)
        )
      end

      {:ok, view, _html} =
        live(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      assert has_element?(view, "#channel-messages[phx-hook='ChannelMessages']")
      assert has_element?(view, "#older-messages-loading")
      assert has_element?(view, "#newer-messages-loading")
      refute has_element?(view, "#load-older-messages")
    end

    test "renders scroll-edge history controls for empty and short channels", %{
      conn: conn,
      scope: scope
    } do
      {:ok, empty_workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})

      {:ok, empty_view, _html} =
        live(
          conn,
          ~p"/workspaces/#{empty_workspace.id}/channels/#{empty_workspace.default_channel_id}"
        )

      refute has_element?(empty_view, "#load-older-messages")
      assert has_element?(empty_view, "#older-messages-loading")
      assert has_element?(empty_view, "#newer-messages-loading")

      {:ok, short_workspace} = Workspaces.create_workspace(scope, %{name: "Workshop"})

      for index <- 1..3 do
        insert_message!(
          short_workspace.default_channel_id,
          scope.user.id,
          "short #{index}",
          DateTime.add(~U[2026-06-19 11:00:00Z], index, :second)
        )
      end

      {:ok, short_view, _html} =
        live(
          conn,
          ~p"/workspaces/#{short_workspace.id}/channels/#{short_workspace.default_channel_id}"
        )

      refute has_element?(short_view, "#load-older-messages")
      assert has_element?(short_view, "#older-messages-loading")
      assert has_element?(short_view, "#newer-messages-loading")
    end

    test "top-edge loading prepends older messages without duplicating the cursor", %{
      conn: conn,
      scope: scope
    } do
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})

      messages =
        for index <- 1..55 do
          insert_message!(
            workspace.default_channel_id,
            scope.user.id,
            "message #{index}",
            DateTime.add(~U[2026-06-19 10:00:00Z], index, :second)
          )
        end

      {:ok, view, _html} =
        live(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      recent_cursor = Enum.at(messages, 5)

      assert has_element?(view, "#message-#{recent_cursor.id}")
      assert has_element?(view, "#message-#{recent_cursor.id}[data-message-row='full']")
      refute has_element?(view, "#message-#{hd(messages).id}")

      render_hook(view, "load_older_messages", %{
        "anchor_offset_top" => 112.5,
        "anchor_row_id" => "message-#{recent_cursor.id}",
        "container_id" => "channel-messages",
        "scroll_height" => 1_600,
        "scroll_top" => 320
      })

      message_ids =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> then(& &1["#channel-messages > article"])
        |> LazyHTML.attribute("id")

      assert Enum.take(message_ids, 6) ==
               messages
               |> Enum.take(6)
               |> Enum.map(&"message-#{&1.id}")

      assert has_element?(view, "#message-#{hd(messages).id}")
      assert has_element?(view, "#message-#{recent_cursor.id}")
      assert has_element?(view, "#message-#{recent_cursor.id}[data-message-row='compact']")
      refute has_element?(view, "#load-older-messages")

      recent_cursor_row_id = "message-#{recent_cursor.id}"

      assert_push_event(view, "preserve_channel_messages_scroll", %{
        anchor_offset_top: 112.5,
        anchor_row_id: ^recent_cursor_row_id,
        container_id: "channel-messages",
        previous_scroll_height: 1600,
        previous_scroll_top: 320
      })

      refute_push_event(view, "scroll_channel_messages_to_bottom", %{
        container_id: _container_id
      })
    end

    test "top-edge loading accepts fractional browser scroll offsets", %{
      conn: conn,
      scope: scope
    } do
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})

      messages =
        for index <- 1..55 do
          insert_message!(
            workspace.default_channel_id,
            scope.user.id,
            "fractional message #{index}",
            DateTime.add(~U[2026-06-19 10:00:00Z], index, :second)
          )
        end

      {:ok, view, _html} =
        live(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      refute has_element?(view, "#message-#{hd(messages).id}")

      render_hook(view, "load_older_messages", %{
        "container_id" => "channel-messages",
        "scroll_height" => 5_425,
        "scroll_top" => 64.5
      })

      assert has_element?(view, "#message-#{hd(messages).id}")

      assert_push_event(view, "preserve_channel_messages_scroll", %{
        container_id: "channel-messages",
        previous_scroll_height: 5425,
        previous_scroll_top: 64.5
      })
    end

    test "top-edge loading trims newer rendered messages when the window exceeds the cap", %{
      conn: conn,
      scope: scope
    } do
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})

      messages =
        for index <- 1..350 do
          insert_message!(
            workspace.default_channel_id,
            scope.user.id,
            "bounded message #{index}",
            DateTime.add(~U[2026-06-19 10:00:00Z], index, :second)
          )
        end

      Repo.get_by!(ChannelReadState,
        channel_id: workspace.default_channel_id,
        user_id: scope.user.id
      )
      |> ChannelReadState.changeset(%{last_viewed_anchor_seq: 275})
      |> Repo.update!()

      {:ok, view, _html} =
        live(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      assert has_element?(view, "#message-#{Enum.at(messages, 259).id}-content")
      assert has_element?(view, "#message-#{Enum.at(messages, 309).id}-content")
      refute has_element?(view, "#message-#{Enum.at(messages, 209).id}-content")

      for page <- 1..5 do
        render_hook(view, "load_older_messages", %{
          "container_id" => "channel-messages",
          "scroll_height" => 1_600 + page,
          "scroll_top" => 320
        })
      end

      message_ids = rendered_message_ids(view)

      assert length(message_ids) == 300
      assert List.first(message_ids) == "message-#{Enum.at(messages, 9).id}"
      assert List.last(message_ids) == "message-#{Enum.at(messages, 308).id}"
      assert has_element?(view, "#message-#{Enum.at(messages, 9).id}-content")
      refute has_element?(view, "#message-#{Enum.at(messages, 309).id}-content")

      trimmed_message = Enum.at(messages, 309)
      trimmed_message_id = trimmed_message.id
      trimmed_row_id = "message-#{trimmed_message.id}"

      assert_push_event(view, "remove_channel_message_rows", %{
        container_id: "channel-messages",
        message_ids: [^trimmed_message_id],
        row_ids: [^trimmed_row_id]
      })

      {:ok, _reaction} = Chat.toggle_reaction(scope, trimmed_message.id, "👍")

      refute has_element?(view, "#message-#{trimmed_message.id}-content")

      assert_push_event(view, "preserve_channel_messages_scroll", %{
        container_id: "channel-messages",
        previous_scroll_height: 1601,
        previous_scroll_top: 320
      })
    end

    test "top-edge loading prunes reaction summaries for trimmed messages", %{
      conn: conn,
      scope: scope
    } do
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})

      messages =
        for index <- 1..350 do
          insert_message!(
            workspace.default_channel_id,
            scope.user.id,
            "reaction bounded message #{index}",
            DateTime.add(~U[2026-06-19 10:00:00Z], index, :second)
          )
        end

      Repo.get_by!(ChannelReadState,
        channel_id: workspace.default_channel_id,
        user_id: scope.user.id
      )
      |> ChannelReadState.changeset(%{last_viewed_anchor_seq: 275})
      |> Repo.update!()

      trimmed_message = Enum.at(messages, 309)
      assert {:ok, _reaction} = Chat.toggle_reaction(scope, trimmed_message.id, "👍")

      {:ok, view, _html} =
        live(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      assert has_element?(view, "#message-#{trimmed_message.id}-reaction-0", "👍 1")

      for page <- 1..5 do
        render_hook(view, "load_older_messages", %{
          "container_id" => "channel-messages",
          "scroll_height" => 1_600 + page,
          "scroll_top" => 320
        })
      end

      refute has_element?(view, "#message-#{trimmed_message.id}")
      assert {:ok, _deleted_reaction} = Chat.toggle_reaction(scope, trimmed_message.id, "👍")

      refute has_element?(view, "#message-#{trimmed_message.id}")
      refute has_element?(view, "#message-#{trimmed_message.id}-reaction-0")
    end

    test "bottom-edge loading continues from the visible boundary after newer rows were trimmed",
         %{
           conn: conn,
           scope: scope
         } do
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})

      messages =
        for index <- 1..350 do
          insert_message!(
            workspace.default_channel_id,
            scope.user.id,
            "continued message #{index}",
            DateTime.add(~U[2026-06-19 10:00:00Z], index, :second)
          )
        end

      Repo.get_by!(ChannelReadState,
        channel_id: workspace.default_channel_id,
        user_id: scope.user.id
      )
      |> ChannelReadState.changeset(%{last_viewed_anchor_seq: 275})
      |> Repo.update!()

      {:ok, view, _html} =
        live(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      for page <- 1..5 do
        render_hook(view, "load_older_messages", %{
          "container_id" => "channel-messages",
          "scroll_height" => 1_600 + page,
          "scroll_top" => 320
        })
      end

      assert List.last(rendered_message_ids(view)) == "message-#{Enum.at(messages, 308).id}"
      refute has_element?(view, "#message-#{Enum.at(messages, 349).id}-content")

      render_hook(view, "load_newer_messages", %{"container_id" => "channel-messages"})

      message_ids = rendered_message_ids(view)

      assert length(message_ids) == 300
      assert List.first(message_ids) == "message-#{Enum.at(messages, 50).id}"
      assert List.last(message_ids) == "message-#{Enum.at(messages, 349).id}"
      assert has_element?(view, "#message-#{Enum.at(messages, 349).id}-content")
      refute has_element?(view, "#message-#{Enum.at(messages, 9).id}-content")
    end

    test "bottom-edge loading appends newer messages in sequence order", %{
      conn: conn,
      scope: scope
    } do
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})

      messages =
        for index <- 1..120 do
          insert_message!(
            workspace.default_channel_id,
            scope.user.id,
            "paged message #{index}",
            DateTime.add(~U[2026-06-19 10:00:00Z], index, :second)
          )
        end

      Repo.get_by!(ChannelReadState,
        channel_id: workspace.default_channel_id,
        user_id: scope.user.id
      )
      |> ChannelReadState.changeset(%{last_viewed_anchor_seq: 20})
      |> Repo.update!()

      {:ok, view, _html} =
        live(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      assert has_element?(
               view,
               "#message-#{Enum.at(messages, 19).id}-content",
               "paged message 20"
             )

      refute has_element?(view, "#message-#{List.last(messages).id}-content", "paged message 120")

      render_hook(view, "load_newer_messages", %{"container_id" => "channel-messages"})

      message_ids = rendered_message_ids(view)

      assert Enum.slice(message_ids, 0, 5) ==
               messages
               |> Enum.slice(4, 5)
               |> Enum.map(&"message-#{&1.id}")

      assert Enum.slice(message_ids, -5, 5) ==
               messages
               |> Enum.slice(100, 5)
               |> Enum.map(&"message-#{&1.id}")

      assert has_element?(
               view,
               "#message-#{Enum.at(messages, 104).id}-content",
               "paged message 105"
             )

      refute has_element?(view, "#message-#{List.last(messages).id}-content", "paged message 120")
    end

    test "bottom-edge loading accepts fractional browser scroll offsets", %{
      conn: conn,
      scope: scope
    } do
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})

      messages =
        for index <- 1..120 do
          insert_message!(
            workspace.default_channel_id,
            scope.user.id,
            "fractional newer message #{index}",
            DateTime.add(~U[2026-06-19 10:00:00Z], index, :second)
          )
        end

      Repo.get_by!(ChannelReadState,
        channel_id: workspace.default_channel_id,
        user_id: scope.user.id
      )
      |> ChannelReadState.changeset(%{last_viewed_anchor_seq: 20})
      |> Repo.update!()

      {:ok, view, _html} =
        live(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      refute has_element?(view, "#message-#{List.last(messages).id}-content")

      render_hook(view, "load_newer_messages", %{
        "anchor_offset_top" => 96.25,
        "anchor_row_id" => "message-#{Enum.at(messages, 19).id}",
        "container_id" => "channel-messages",
        "scroll_top" => 64.5
      })

      assert has_element?(view, "#message-#{Enum.at(messages, 104).id}-content")

      anchor_row_id = "message-#{Enum.at(messages, 19).id}"

      assert_push_event(view, "restore_channel_messages_scroll", %{
        anchor_offset_top: 96.25,
        anchor_row_id: ^anchor_row_id,
        container_id: "channel-messages",
        previous_scroll_top: 64.5
      })
    end

    test "bottom-edge loading trims older rendered messages when the window exceeds the cap", %{
      conn: conn,
      scope: scope
    } do
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})

      messages =
        for index <- 1..350 do
          insert_message!(
            workspace.default_channel_id,
            scope.user.id,
            "forward bounded message #{index}",
            DateTime.add(~U[2026-06-19 10:00:00Z], index, :second)
          )
        end

      Repo.get_by!(ChannelReadState,
        channel_id: workspace.default_channel_id,
        user_id: scope.user.id
      )
      |> ChannelReadState.changeset(%{last_viewed_anchor_seq: 40})
      |> Repo.update!()

      {:ok, view, _html} =
        live(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      assert has_element?(view, "#message-#{Enum.at(messages, 24).id}-content")
      assert has_element?(view, "#message-#{Enum.at(messages, 74).id}-content")
      refute has_element?(view, "#message-#{Enum.at(messages, 324).id}-content")

      for _page <- 1..5 do
        render_hook(view, "load_newer_messages", %{"container_id" => "channel-messages"})
      end

      message_ids = rendered_message_ids(view)

      assert length(message_ids) == 300
      assert List.first(message_ids) == "message-#{Enum.at(messages, 25).id}"
      assert List.last(message_ids) == "message-#{Enum.at(messages, 324).id}"
      refute has_element?(view, "#message-#{Enum.at(messages, 24).id}-content")
      assert has_element?(view, "#message-#{Enum.at(messages, 324).id}-content")
    end
  end
end
