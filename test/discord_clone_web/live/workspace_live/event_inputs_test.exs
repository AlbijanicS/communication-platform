defmodule DiscordCloneWeb.WorkspaceLive.EventInputsTest do
  use DiscordCloneWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import DiscordCloneWeb.WorkspaceLiveTestHelpers

  alias DiscordClone.Workspaces

  setup :register_and_log_in_user

  setup %{scope: scope} do
    {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Inputs"})
    member = DiscordClone.AccountsFixtures.user_scope_fixture()
    add_workspace_member!(workspace, member)
    {:ok, channel} = Workspaces.create_channel(scope, workspace.id, %{name: "keep"})
    {:ok, voice} = Workspaces.create_voice_channel(scope, workspace.id, %{name: "keep"})
    %{workspace: workspace, member: member, channel: channel, voice: voice}
  end

  test "missing timeout duration reports an error and preserves membership", %{
    conn: conn,
    scope: scope,
    workspace: workspace,
    member: member
  } do
    {:ok, view, _} =
      live(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

    render_click(view, "member_action", %{"action" => "timeout", "user_id" => member.user.id})
    assert has_element?(view, "#flash-error")
    assert has_element?(view, "#workspace-member-#{member.user.id}")
    assert {:ok, state} = Workspaces.member_moderation_state(scope, workspace.id, member.user.id)
    refute state.timed_out?
  end

  for event <-
        ~w(create_workspace begin_workspace_rename rename_workspace delete_workspace leave_workspace create_channel begin_channel_rename rename_channel delete_channel create_voice_channel begin_voice_channel_rename rename_voice_channel delete_voice_channel member_action kick_member ban_member open_workspace_actions open_channel_actions open_voice_channel_actions open_context_menu mark_sidebar_channel_read) do
    test "#{event} tolerates missing keys", %{
      conn: conn,
      scope: scope,
      workspace: workspace,
      channel: channel,
      voice: voice
    } do
      {:ok, view, _} =
        live(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

      render_click(view, unquote(event), %{})
      assert has_element?(view, "#workspace-app-shell")
      assert {:ok, _} = Workspaces.fetch_channel(scope, workspace.id, channel.id)
      assert {:ok, _} = Workspaces.fetch_voice_channel(scope, workspace.id, voice.id)
      assert {:ok, unchanged} = Workspaces.fetch_workspace(scope, workspace.id)
      assert unchanged.name == "Inputs"
    end
  end

  test "member actions reject wrong types, unknown actions, invalid presets and private IDs", %{
    conn: conn,
    scope: scope,
    workspace: workspace,
    member: member
  } do
    {:ok, view, _} =
      live(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

    for duration <- [nil, "", "1minute-junk", "999", 60, [], %{}] do
      render_click(view, "member_action", %{
        "action" => "timeout",
        "user_id" => member.user.id,
        "timeout_duration" => duration
      })

      assert has_element?(view, "#flash-error")
    end

    for user_id <- [nil, "", "bad-uuid", 3, [], %{}, Ecto.UUID.generate()] do
      render_click(view, "member_action", %{"action" => "mute", "user_id" => user_id})
      assert has_element?(view, "#workspace-app-shell")
    end

    render_click(view, "member_action", %{"action" => "unknown", "user_id" => member.user.id})
    assert has_element?(view, "#flash-error")
    assert {:ok, state} = Workspaces.member_moderation_state(scope, workspace.id, member.user.id)
    refute state.timed_out?
    refute state.muted?
  end

  test "management payloads reject malformed identifiers and non-map form values", %{
    conn: conn,
    workspace: workspace,
    channel: channel,
    voice: voice
  } do
    {:ok, view, _} =
      live(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

    for value <- [nil, 123, [], %{}, "invalid"] do
      for {event, key} <- [
            {"delete_workspace", "workspace_id"},
            {"delete_channel", "channel_id"},
            {"delete_voice_channel", "voice_channel_id"},
            {"open_workspace_actions", "workspace_id"},
            {"open_channel_actions", "channel_id"},
            {"open_voice_channel_actions", "voice_channel_id"}
          ] do
        render_click(view, event, %{key => value})
        assert has_element?(view, "#flash-error")
        assert has_element?(view, "#channel-#{channel.id}")
        assert has_element?(view, "#voice-channel-#{voice.id}")
      end
    end

    for value <- [nil, 123, [], "invalid"] do
      for {event, params} <- [
            {"create_workspace", %{"workspace" => value}},
            {"create_channel", %{"channel" => value}},
            {"create_voice_channel", %{"voice_channel" => value}},
            {"rename_workspace", %{"workspace_id" => workspace.id, "workspace" => value}},
            {"rename_channel", %{"channel_id" => channel.id, "channel" => value}},
            {"rename_voice_channel", %{"voice_channel_id" => voice.id, "voice_channel" => value}}
          ] do
        render_click(view, event, params)
        assert has_element?(view, "#flash-error")
      end
    end
  end

  test "a forged private Channel cannot be renamed", %{
    conn: conn,
    scope: scope,
    workspace: workspace
  } do
    outsider = DiscordClone.AccountsFixtures.user_scope_fixture()
    {:ok, private} = Workspaces.create_workspace(outsider, %{name: "Private"})

    {:ok, view, _} =
      live(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

    render_click(view, "rename_channel", %{
      "channel_id" => private.default_channel_id,
      "channel" => %{"name" => "forged"}
    })

    assert_redirect(view, ~p"/workspaces")

    assert {:ok, channel} =
             Workspaces.fetch_channel(outsider, private.id, private.default_channel_id)

    assert channel.name == "general"
    assert {:error, _} = Workspaces.fetch_channel(scope, private.id, private.default_channel_id)
  end

  for surface <- [:home, :invite, :audit] do
    test "#{surface} rejects malformed shared actions and remains usable", %{
      conn: conn,
      workspace: workspace,
      member: member
    } do
      path =
        case unquote(surface) do
          :home -> ~p"/workspaces"
          :invite -> ~p"/workspaces/#{workspace.id}/invites/new"
          :audit -> ~p"/workspaces/#{workspace.id}/audit-log"
        end

      {:ok, view, _} = live(conn, path)
      render_click(view, "create_workspace", %{})
      assert has_element?(view, "#flash-error")
      render_click(view, "create_workspace", %{"workspace" => []})
      assert has_element?(view, "#workspace-app-shell")
      render_click(view, "unknown_action", %{})
      assert has_element?(view, "#workspace-app-shell")

      if unquote(surface) != :home do
        render_click(view, "member_action", %{"action" => "timeout", "user_id" => member.user.id})
        render_click(view, "kick_member", %{})
        render_click(view, "ban_member", %{})
        assert has_element?(view, "#workspace-member-#{member.user.id}")
      end

      if unquote(surface) == :audit do
        render_click(view, "unban_member", %{})
        assert has_element?(view, "#flash-error")
      end
    end
  end

  test "context-menu coordinates require a complete integer", %{
    conn: conn,
    workspace: workspace,
    channel: channel
  } do
    {:ok, view, _} =
      live(conn, ~p"/workspaces/#{workspace.id}/channels/#{workspace.default_channel_id}")

    render_click(view, "open_context_menu", %{
      "type" => "channel",
      "id" => channel.id,
      "x" => "42junk",
      "y" => "17"
    })

    assert has_element?(
             view,
             "#channel-#{channel.id}-menu[style*='left: 0px'][style*='top: 17px']"
           )
  end
end
