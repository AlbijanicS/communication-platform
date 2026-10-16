defmodule DiscordCloneWeb.WorkspaceLive.Home do
  use DiscordCloneWeb, :live_view

  alias DiscordClone.Workspaces
  alias DiscordCloneWeb.WorkspaceLive.EventInputs
  alias DiscordCloneWeb.WorkspaceLive.Shell
  alias DiscordCloneWeb.WorkspaceLive.WorkspaceManagementEvents

  @impl true
  def mount(_params, _session, socket) do
    socket = EventInputs.attach(socket)

    {:ok, discovered_workspaces} = Workspaces.list_workspaces(socket.assigns.current_scope)

    if connected?(socket) do
      Enum.each(discovered_workspaces, fn workspace ->
        Workspaces.subscribe_to_workspace_moderation(socket.assigns.current_scope, workspace.id)
      end)
    end

    {:ok, workspaces} = Workspaces.list_workspaces(socket.assigns.current_scope)

    socket =
      socket
      |> assign(
        :workspace_form,
        WorkspaceManagementEvents.workspace_form(socket.assigns.current_scope)
      )
      |> assign(:show_workspace_form?, workspaces == [])
      |> stream(:workspaces, workspaces)

    {:ok, socket}
  end

  @impl true
  def handle_info({:workspace_access_revoked, _payload}, socket) do
    {:noreply, WorkspaceManagementEvents.restream_workspaces(socket)}
  end

  def handle_info(_event, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <Shell.app
        workspace_stream={@streams.workspaces}
        workspace_form={@workspace_form}
        show_workspace_form?={@show_workspace_form?}
        current_scope={@current_scope}
        unread_activity_count={@unread_activity_count}
        activity_preview_stream={@streams.activity_preview_items}
        direct_message_unread_count={@direct_message_unread_count}
        main_state={:no_workspace}
      />
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("show_workspace_form", _params, socket) do
    WorkspaceManagementEvents.show_workspace_form(socket)
  end

  def handle_event("cancel_workspace_form", _params, socket) do
    WorkspaceManagementEvents.cancel_workspace_form(socket)
  end

  def handle_event("create_workspace", params, socket) do
    WorkspaceManagementEvents.create_workspace(socket, params)
  end

  def handle_event(_event, _params, socket) do
    {:noreply, put_flash(socket, :error, "Action could not be completed.")}
  end
end
