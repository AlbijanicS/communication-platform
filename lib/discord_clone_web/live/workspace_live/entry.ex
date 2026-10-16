defmodule DiscordCloneWeb.WorkspaceLive.Entry do
  use DiscordCloneWeb, :live_view

  alias DiscordClone.Workspaces
  alias DiscordCloneWeb.WorkspaceLive.EventInputs
  alias DiscordCloneWeb.WorkspaceLive.Shell
  alias DiscordCloneWeb.WorkspaceLive.WorkspaceManagementEvents

  @impl true
  def mount(%{"workspace_id" => workspace_id}, _session, socket) do
    socket = EventInputs.attach(socket)

    case Workspaces.resolve_landing_channel(socket.assigns.current_scope, workspace_id) do
      {:ok, channel} ->
        {:ok, push_navigate(socket, to: ~p"/workspaces/#{workspace_id}/channels/#{channel.id}")}

      {:error, _reason} ->
        redirect_to_workspaces(socket)
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <Shell.app
        workspace_stream={@streams.workspaces}
        channel_stream={@streams.channels}
        selected_workspace={@selected_workspace}
        workspace_form={@workspace_form}
        show_workspace_form?={@show_workspace_form?}
        channel_form={@channel_form}
        show_channel_form?={@show_channel_form?}
        workspace_action_menu_id={@workspace_action_menu_id}
        renaming_workspace_id={@renaming_workspace_id}
        workspace_rename_form={@workspace_rename_form}
        context_menu_position={@context_menu_position}
        current_scope={@current_scope}
        unread_activity_count={@unread_activity_count}
        activity_preview_stream={@streams.activity_preview_items}
        direct_message_unread_count={@direct_message_unread_count}
        main_state={:empty_channel}
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

  def handle_event("show_channel_form", _params, socket) do
    {:noreply, assign(socket, :show_channel_form?, true)}
  end

  def handle_event("cancel_channel_form", _params, socket) do
    workspace_id = socket.assigns.selected_workspace.id

    {:noreply,
     socket
     |> assign(:show_channel_form?, false)
     |> assign(:channel_form, channel_form(workspace_id))}
  end

  def handle_event("open_workspace_actions", %{"workspace_id" => workspace_id}, socket) do
    {:noreply,
     socket
     |> assign(:workspace_action_menu_id, workspace_id)
     |> assign(:context_menu_position, nil)}
  end

  def handle_event(
        "open_context_menu",
        %{"type" => "workspace", "id" => workspace_id, "x" => x, "y" => y},
        socket
      ) do
    {:noreply,
     socket
     |> assign(:workspace_action_menu_id, workspace_id)
     |> assign(:context_menu_position, %{
       x: WorkspaceManagementEvents.coordinate_integer(x),
       y: WorkspaceManagementEvents.coordinate_integer(y)
     })}
  end

  def handle_event("close_context_menu", _params, socket) do
    {:noreply,
     socket
     |> assign(:workspace_action_menu_id, nil)
     |> assign(:context_menu_position, nil)}
  end

  def handle_event("begin_workspace_rename", params, socket) do
    WorkspaceManagementEvents.begin_workspace_rename(socket, params)
  end

  def handle_event("rename_workspace", params, socket) do
    WorkspaceManagementEvents.rename_workspace(socket, params)
  end

  def handle_event("delete_workspace", params, socket) do
    WorkspaceManagementEvents.delete_workspace(socket, params)
  end

  def handle_event("leave_workspace", params, socket) do
    WorkspaceManagementEvents.leave_workspace(socket, params)
  end

  def handle_event("create_channel", %{"channel" => channel_params}, socket) do
    workspace_id = socket.assigns.selected_workspace.id

    case Workspaces.create_channel(socket.assigns.current_scope, workspace_id, channel_params) do
      {:ok, channel} ->
        {:ok, channels} = Workspaces.list_channels(socket.assigns.current_scope, workspace_id)

        socket =
          socket
          |> assign(:channel_form, channel_form(workspace_id))
          |> assign(:show_channel_form?, channels == [])
          |> stream(:channels, channels, reset: true)

        {:noreply,
         push_navigate(socket, to: ~p"/workspaces/#{workspace_id}/channels/#{channel.id}")}

      {:error, :invalid_channel, changeset} ->
        {:noreply,
         socket
         |> assign(:show_channel_form?, true)
         |> assign(:channel_form, to_form(changeset, as: :channel, action: :insert))}

      {:error, _reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Channel could not be created.")
         |> push_navigate(to: ~p"/workspaces")}
    end
  end

  def handle_event(_event, _params, socket) do
    {:noreply, put_flash(socket, :error, "Action could not be completed.")}
  end

  defp redirect_to_workspaces(socket) do
    {:ok,
     socket
     |> put_flash(:error, "Workspace not found or you do not have access.")
     |> redirect(to: ~p"/workspaces")}
  end

  defp channel_form(workspace_id, attrs \\ %{}) do
    workspace_id
    |> Workspaces.change_channel(attrs)
    |> to_form(as: :channel)
  end
end
