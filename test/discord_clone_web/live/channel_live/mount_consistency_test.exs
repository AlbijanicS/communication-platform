defmodule DiscordCloneWeb.ChannelLive.MountConsistencyTest do
  use DiscordCloneWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import DiscordCloneWeb.WorkspaceLiveTestHelpers

  alias DiscordClone.{Chat, Workspaces}
  alias DiscordClone.Chat.ConversationTopics

  setup :register_and_log_in_user

  test "a Message committed while the initial window is returning is not missed", %{
    conn: conn,
    scope: scope
  } do
    {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Race"})
    channel_id = workspace.default_channel_id

    during_snapshot("messages", fn ->
      {:ok, message} = Chat.send_message(scope, channel_id, %{content: "during mount"})
      # Chat excludes the sending process; replay the external sender's fact.
      Phoenix.PubSub.broadcast(
        DiscordClone.PubSub,
        ConversationTopics.messages(channel_id),
        {:message_created, message}
      )

      message
    end)

    {:ok, view, _} = live(conn, ~p"/workspaces/#{workspace.id}/channels/#{channel_id}")
    assert_receive {:snapshot_change, message}
    assert has_element?(view, "#message-#{message.id}-content", "during mount")
    assert rendered_message_ids(view) == ["message-#{message.id}"]
  end

  test "snapshot overlap cannot resurrect a deleted Message or reorder the latest rows", %{
    conn: conn,
    scope: scope
  } do
    {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Overlap"})
    channel_id = workspace.default_channel_id
    {:ok, first} = Chat.send_message(scope, channel_id, %{content: "first"})
    {:ok, second} = Chat.send_message(scope, channel_id, %{content: "second"})
    {:ok, _} = Chat.delete_message(scope, first.id)

    {:ok, view, _} = live(conn, ~p"/workspaces/#{workspace.id}/channels/#{channel_id}")
    send(view.pid, {:message_created, first})
    send(view.pid, {:message_created, second})
    refute has_element?(view, "#message-#{first.id}-content", "first")
    assert rendered_message_ids(view) == ["message-#{first.id}", "message-#{second.id}"]
  end

  test "channel discovery overlap refreshes the list and subscribes new read states once", %{
    conn: conn,
    scope: scope
  } do
    {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Discovery"})

    during_snapshot("messages", fn ->
      {:ok, channel} = Workspaces.create_channel(scope, workspace.id, %{name: "during-mount"})
      channel
    end)

    {:ok, view, _} =
      live(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

    assert_receive {:snapshot_change, channel}
    assert has_element?(view, "#channel-#{channel.id}")
    send(view.pid, {:workspace_channel_created, %{workspace_id: workspace.id}})
    render(view)
    topics = Registry.keys(DiscordClone.PubSub, view.pid)

    assert Enum.count(topics, &(&1 == ConversationTopics.read_state(scope.user.id, channel.id))) ==
             1

    assert length(topics) == length(Enum.uniq(topics))
  end

  test "unread snapshot overlap and duplicate facts retain the exact count", %{
    conn: conn,
    scope: scope
  } do
    {owner, workspace, sibling} = workspace_with_sibling_unread!(scope)

    during_snapshot("messages", fn ->
      {:ok, message} = Chat.send_message(owner, sibling.id, %{content: "second unread"})
      message
    end)

    {:ok, view, _} =
      live(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

    assert_receive {:snapshot_change, message}
    payload = %{workspace_id: workspace.id, channel_id: sibling.id, message_id: message.id}
    send(view.pid, {:workspace_message_created, payload})
    send(view.pid, {:workspace_message_created, payload})
    assert has_element?(view, "#channel-#{sibling.id}-unread-badge", "2")
    assert {:ok, counts} = Chat.list_unread_counts(scope, workspace.id)
    assert counts[sibling.id] == 2
  end

  test "a roster update overlapping mount renders once and refreshes do not duplicate subscriptions",
       %{conn: conn, scope: scope} do
    {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Roster"})
    {:ok, voice_channel} = Workspaces.create_voice_channel(scope, workspace.id, %{name: "Lobby"})
    owner = self()

    on_exit(fn ->
      DiscordClone.Voice.end_channel_sessions(voice_channel.id)
      DiscordClone.Voice.expire_idle_room(voice_channel.id)
    end)

    during_snapshot("messages", fn ->
      DiscordClone.Voice.join(voice_channel.id, scope.user.id, "mount-roster", owner)
    end)

    {:ok, view, _} =
      live(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

    assert_receive {:snapshot_change, {:ok, _}}
    selector = "#voice-channel-#{voice_channel.id}-roster-member-#{scope.user.id}"
    assert has_element?(view, selector)
    send(view.pid, {:workspace_voice_channels_changed, %{workspace_id: workspace.id}})
    send(view.pid, {:workspace_member_joined, %{workspace_id: workspace.id}})
    render(view)
    topics = Registry.keys(DiscordClone.PubSub, view.pid)
    assert length(topics) == length(Enum.uniq(topics))
    assert has_element?(view, selector)
    document = view |> render() |> LazyHTML.from_fragment()
    assert LazyHTML.attribute(document[selector], "id") == [String.trim_leading(selector, "#")]
  end

  test "home removes a revoked membership while its subscribed snapshot is returning", %{
    conn: conn,
    scope: scope
  } do
    owner = DiscordClone.AccountsFixtures.user_scope_fixture()
    {:ok, workspace} = Workspaces.create_workspace(owner, %{name: "Home"})
    add_workspace_member!(workspace, scope)

    during_snapshot(
      "workspaces",
      fn ->
        Workspaces.kick_member(owner, workspace.id, scope.user.id, %{reason: "removed"})
      end,
      1
    )

    {:ok, view, _} = live(conn, ~p"/workspaces")
    assert_receive {:snapshot_change, {:ok, _}}
    refute has_element?(view, "#workspace-#{workspace.id}")
    assert has_element?(view, "#workspace-app-shell")
  end

  test "the shared Direct Messages badge receives a change during its initial query", %{
    conn: conn,
    scope: scope
  } do
    friend = DiscordClone.AccountsFixtures.user_scope_fixture()

    {:ok, request} =
      DiscordClone.Friendships.send_friend_request(friend, %{username: scope.user.username})

    {:ok, _} = DiscordClone.Friendships.accept_friend_request(scope, request.relationship.id)
    {:ok, conversation} = Chat.open_direct_conversation(friend, scope.user.id)

    during_snapshot("direct_conversations", fn ->
      Chat.send_direct_message(friend, conversation.id, %{content: "during shell mount"})
    end)

    {:ok, view, _} = live(conn, ~p"/workspaces")
    assert_receive {:snapshot_change, {:ok, _}}
    assert has_element?(view, "#direct-messages-unread-count", "1")
  end

  test "disconnected rendering does not subscribe the HTTP process", %{conn: conn, scope: scope} do
    {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Static"})
    before = Registry.keys(DiscordClone.PubSub, self())
    conn = get(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")
    assert html_response(conn, 200)
    assert Registry.keys(DiscordClone.PubSub, self()) == before
  end

  # The query event runs after PostgreSQL has produced the snapshot, before the
  # caller consumes it. Mount telemetry scopes this seam to the connected view;
  # a one-shot process flag prevents recursive queries from firing it again.
  defp during_snapshot(source, change, skip \\ 0) do
    handler = {__MODULE__, make_ref()}

    config = %{
      key: handler,
      source: source,
      skip: skip,
      change: change,
      test: self()
    }

    :ok =
      :telemetry.attach_many(
        handler,
        [
          [:phoenix, :live_view, :mount, :start],
          [:phoenix, :live_view, :mount, :stop],
          [:discord_clone, :repo, :query]
        ],
        &__MODULE__.on_snapshot/4,
        config
      )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  def on_snapshot([:phoenix, :live_view, :mount, :start], _, %{socket: socket}, config) do
    if Phoenix.LiveView.connected?(socket) do
      Process.put(config.key, config.skip)
    end
  end

  def on_snapshot([:phoenix, :live_view, :mount, :stop], _, _, config) do
    Process.delete(config.key)
  end

  def on_snapshot([:discord_clone, :repo, :query], _, %{source: source}, config) do
    if source == config.source do
      case Process.get(config.key) do
        0 ->
          Process.delete(config.key)
          send(config.test, {:snapshot_change, config.change.()})

        remaining when is_integer(remaining) ->
          Process.put(config.key, remaining - 1)

        nil ->
          :ok
      end
    end
  end
end
