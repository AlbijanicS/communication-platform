defmodule DiscordCloneWeb.WorkspaceLive.WorkspaceManagementEvents do
  @moduledoc """
  Shared workspace-lifecycle `handle_event` bodies for the LiveViews that render
  the workspace sidebar.

  The home, entry, and channel (`ChannelLive.Show`) LiveViews all let a Workspace
  Member create, rename, delete, and leave a Workspace and drive the workspace
  creation/rename forms. Those handlers had effectively the same behavior across
  the three surfaces, so this module owns the single copy: each LiveView's
  `handle_event` clause delegates here and this module returns the
  `{:noreply, socket}` the callback expects. It also holds the small helpers those
  handlers share — the workspace form builder, the sidebar re-stream, and the
  defensive context-menu coordinate parser.

  Channel-management handlers and the channel-sidebar refresh stay in
  `ChannelLive.Show`: their bodies differ per surface (e.g. `create_channel`
  streams channels in `Entry` but refreshes the sidebar in `Show`, and `Home` has
  no channels at all), so there was no single shared shape to extract.
  """

  use DiscordCloneWeb, :verified_routes

  import Phoenix.Component, only: [assign: 3, to_form: 2]
  import Phoenix.LiveView, only: [put_flash: 3, push_navigate: 2, stream: 4]

  alias DiscordClone.Workspaces

  @doc "Reveals the create-Workspace form."
  def show_workspace_form(socket) do
    {:noreply, assign(socket, :show_workspace_form?, true)}
  end

  @doc "Hides and resets the create-Workspace form."
  def cancel_workspace_form(socket) do
    {:noreply,
     socket
     |> assign(:show_workspace_form?, false)
     |> assign(:workspace_form, workspace_form(socket.assigns.current_scope))}
  end

  @doc """
  Creates a Workspace, navigating to it on success and surfacing changeset or
  generic errors on the form otherwise.
  """
  def create_workspace(socket, %{"workspace" => workspace_params}) do
    case Workspaces.create_workspace(socket.assigns.current_scope, workspace_params) do
      {:ok, workspace} ->
        {:noreply, push_navigate(socket, to: ~p"/workspaces/#{workspace.id}")}

      {:error, :invalid_workspace, changeset} ->
        {:noreply,
         socket
         |> assign(:show_workspace_form?, true)
         |> assign(:workspace_form, to_form(changeset, as: :workspace, action: :insert))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Workspace could not be created.")}
    end
  end

  @doc """
  Opens the inline rename form for a Workspace, re-streaming the sidebar so the
  edited row renders its form.
  """
  def begin_workspace_rename(socket, %{"workspace_id" => workspace_id}) do
    with {:ok, workspace} <-
           Workspaces.fetch_workspace(socket.assigns.current_scope, workspace_id),
         {:ok, workspaces} <- Workspaces.list_workspaces(socket.assigns.current_scope) do
      socket =
        socket
        |> assign(:workspace_action_menu_id, nil)
        |> assign(:renaming_workspace_id, workspace.id)
        |> assign(
          :workspace_rename_form,
          workspace_form(socket.assigns.current_scope, %{
            name: workspace.name
          })
        )
        |> stream(:workspaces, workspaces, reset: true)

      {:noreply, socket}
    else
      {:error, _reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Workspace could not be renamed.")
         |> push_navigate(to: ~p"/workspaces")}
    end
  end

  @doc """
  Renames a Workspace, keeping the selected Workspace and sidebar in sync and
  re-rendering the rename form on validation errors.
  """
  def rename_workspace(socket, %{"workspace_id" => workspace_id, "workspace" => workspace_params}) do
    case Workspaces.rename_workspace(socket.assigns.current_scope, workspace_id, workspace_params) do
      {:ok, workspace} ->
        {:ok, workspaces} = Workspaces.list_workspaces(socket.assigns.current_scope)

        selected_workspace =
          if socket.assigns.selected_workspace.id == workspace.id,
            do: workspace,
            else: socket.assigns.selected_workspace

        socket =
          socket
          |> assign(:selected_workspace, selected_workspace)
          |> assign(:renaming_workspace_id, nil)
          |> assign(:workspace_rename_form, nil)
          |> assign(:workspace_action_menu_id, nil)
          |> stream(:workspaces, workspaces, reset: true)

        {:noreply, socket}

      {:error, :invalid_workspace, changeset} ->
        {:noreply,
         socket
         |> assign(:renaming_workspace_id, workspace_id)
         |> assign(:workspace_rename_form, to_form(changeset, as: :workspace, action: :insert))
         |> assign(:workspace_action_menu_id, nil)
         |> restream_workspaces()}

      {:error, _reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Workspace could not be renamed.")
         |> push_navigate(to: ~p"/workspaces")}
    end
  end

  @doc "Deletes a Workspace and returns to the workspaces index."
  def delete_workspace(socket, %{"workspace_id" => workspace_id}) do
    case Workspaces.delete_workspace(socket.assigns.current_scope, workspace_id) do
      {:ok, _workspace} ->
        {:noreply, push_navigate(socket, to: ~p"/workspaces")}

      {:error, _reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Workspace could not be deleted.")
         |> push_navigate(to: ~p"/workspaces")}
    end
  end

  @doc "Leaves a Workspace and returns to the workspaces index."
  def leave_workspace(socket, %{"workspace_id" => workspace_id}) do
    case Workspaces.leave_workspace(socket.assigns.current_scope, workspace_id) do
      {:ok, _membership} ->
        {:noreply, push_navigate(socket, to: ~p"/workspaces")}

      {:error, _reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Workspace could not be left.")
         |> push_navigate(to: ~p"/workspaces")}
    end
  end

  @doc "Builds a form for the create/rename Workspace changeset."
  def workspace_form(scope, attrs \\ %{}) do
    scope
    |> Workspaces.change_workspace(attrs)
    |> to_form(as: :workspace)
  end

  @doc "Re-streams the Workspace sidebar from the current scope's workspaces."
  def restream_workspaces(socket) do
    {:ok, workspaces} = Workspaces.list_workspaces(socket.assigns.current_scope)
    stream(socket, :workspaces, workspaces, reset: true)
  end

  @doc """
  Parses a context-menu coordinate from event input, tolerating malformed or
  forged values by falling back to `0` instead of raising.
  """
  def coordinate_integer(value) when is_integer(value), do: value

  def coordinate_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _invalid -> 0
    end
  end

  def coordinate_integer(_value), do: 0
end
