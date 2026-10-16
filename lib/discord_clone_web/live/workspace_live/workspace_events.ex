defmodule DiscordCloneWeb.WorkspaceLive.WorkspaceEvents do
  @moduledoc """
  Shared plumbing for the `workspaces:<id>:events` fan-out.

  Three surfaces subscribe to the same workspace-events topic — the channel
  view (`ChannelLive.Show`), the audit log, and the invite screen. Each one
  refreshes its own assigns differently, so this module owns only the parts
  that were byte-identical across them: subscribing on connect, the
  "act only when the broadcast targets the selected workspace" guard, and the
  member-list refresh. The per-surface refreshes stay in their own modules.
  """

  import Phoenix.LiveView, only: [connected?: 1]

  alias DiscordClone.Workspaces
  alias DiscordCloneWeb.WorkspaceLive.Presence

  @doc """
  Subscribes to the workspace-events topic once the socket is connected.

  Returns `:ok` on a static (disconnected) mount so callers can keep it in a
  `with` chain without special-casing the first render.
  """
  def subscribe(socket, workspace_id) do
    if connected?(socket) do
      Workspaces.subscribe_to_workspace_events(socket.assigns.current_scope, workspace_id)
    else
      :ok
    end
  end

  @doc """
  Runs `fun.(socket)` only when a broadcast targets the workspace the surface
  currently has selected; otherwise returns the socket untouched.
  """
  def apply_to_selected(socket, workspace_id, fun) when is_function(fun, 1) do
    if socket.assigns.selected_workspace.id == workspace_id do
      fun.(socket)
    else
      socket
    end
  end

  @doc """
  Re-fetches the workspace members and re-renders the presence sidebar, leaving
  the socket untouched if the members can no longer be listed.
  """
  def refresh_members(socket, workspace_id) do
    case Workspaces.list_members(socket.assigns.current_scope, workspace_id) do
      {:ok, members} -> Presence.refresh_workspace_members(socket, members)
      _error -> socket
    end
  end
end
