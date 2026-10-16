defmodule DiscordCloneWeb.WorkspaceLive.InviteNew do
  use DiscordCloneWeb, :live_view

  alias DiscordClone.Chat
  alias DiscordClone.Chat.PresenceEvents
  alias DiscordClone.Workspaces
  alias DiscordCloneWeb.WorkspaceLive.MemberActions
  alias DiscordCloneWeb.WorkspaceLive.Presence
  alias DiscordCloneWeb.WorkspaceLive.EventInputs
  alias DiscordCloneWeb.WorkspaceLive.Shell
  alias DiscordCloneWeb.WorkspaceLive.WorkspaceEvents

  @impl true
  def mount(%{"workspace_id" => workspace_id}, _session, socket) do
    socket = EventInputs.attach(socket)

    with {:ok, workspace} <-
           Workspaces.fetch_workspace(socket.assigns.current_scope, workspace_id),
         :ok <- authorize_invite_screen(socket.assigns.current_scope, workspace),
         {:ok, workspaces} <- Workspaces.list_workspaces(socket.assigns.current_scope),
         {:ok, channels} <- Workspaces.list_channels(socket.assigns.current_scope, workspace_id),
         {:ok, voice_channels} <-
           Workspaces.list_voice_channels(socket.assigns.current_scope, workspace_id),
         {:ok, members} <- Workspaces.list_members(socket.assigns.current_scope, workspace_id),
         {:ok, channel_unread_counts} <- load_channel_unread_counts(socket, workspace.id),
         :ok <- subscribe_to_channel_read_states(socket, channels),
         :ok <- subscribe_to_voice_channel_rosters(socket, workspace.id),
         {:ok, voice_channel_rosters} <-
           Workspaces.list_voice_channel_rosters(socket.assigns.current_scope, workspace_id),
         :ok <- WorkspaceEvents.subscribe(socket, workspace.id) do
      socket =
        socket
        |> assign(:selected_workspace, workspace)
        |> assign(:workspace_form, workspace_form(socket.assigns.current_scope))
        |> assign(:show_workspace_form?, false)
        |> assign(:workspace_action_menu_id, nil)
        |> assign(:renaming_workspace_id, nil)
        |> assign(:workspace_rename_form, nil)
        |> assign(:channel_form, channel_form(workspace.id))
        |> assign(:show_channel_form?, false)
        |> assign(:context_menu_position, nil)
        |> assign(:invite_form, invite_form())
        |> assign(:invite_url, nil)
        |> assign(:channel_unread_counts, channel_unread_counts)
        |> assign(:voice_channel_rosters, voice_channel_rosters)
        |> assign(:member_by_user_id, Map.new(members, &{&1.user_id, &1}))
        |> stream(:workspaces, workspaces)
        |> stream(:channels, channels)
        |> stream(:voice_channels, voice_channels)
        |> Presence.prepare_workspace(workspace.id, members)

      {:ok, socket}
    else
      {:error, :invite_permission_required, workspace} ->
        {:ok,
         socket
         |> put_flash(:error, "You are not allowed to create invites for this workspace.")
         |> redirect(to: ~p"/workspaces/#{workspace.id}")}

      {:error, _reason} ->
        {:ok,
         socket
         |> put_flash(:error, "Workspace not found or you do not have access.")
         |> redirect(to: ~p"/workspaces")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <Shell.app
        workspace_stream={@streams.workspaces}
        channel_stream={@streams.channels}
        voice_channel_stream={@streams.voice_channels}
        voice_channel_rosters={@voice_channel_rosters}
        member_by_user_id={@member_by_user_id}
        selected_workspace={@selected_workspace}
        workspace_form={@workspace_form}
        show_workspace_form?={@show_workspace_form?}
        workspace_action_menu_id={@workspace_action_menu_id}
        renaming_workspace_id={@renaming_workspace_id}
        workspace_rename_form={@workspace_rename_form}
        channel_form={@channel_form}
        show_channel_form?={@show_channel_form?}
        member_stream={@streams.workspace_members}
        context_menu_position={@context_menu_position}
        current_scope={@current_scope}
        unread_activity_count={@unread_activity_count}
        activity_preview_stream={@streams.activity_preview_items}
        direct_message_unread_count={@direct_message_unread_count}
        invite_form={@invite_form}
        invite_url={@invite_url}
        main_state={:invite}
        online_user_ids={@online_user_ids}
        channel_unread_counts={@channel_unread_counts}
      />
    </Layouts.app>
    """
  end

  @impl true
  def handle_info({:channel_read_state_changed, %{workspace_id: workspace_id}}, socket) do
    if socket.assigns.selected_workspace.id == workspace_id do
      {:noreply, refresh_channel_sidebar(socket, workspace_id)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:workspace_channel_created, %{workspace_id: workspace_id}}, socket) do
    {:noreply,
     WorkspaceEvents.apply_to_selected(
       socket,
       workspace_id,
       &refresh_channel_sidebar(&1, workspace_id)
     )}
  end

  def handle_info({:workspace_voice_channels_changed, %{workspace_id: workspace_id}}, socket) do
    {:noreply,
     WorkspaceEvents.apply_to_selected(
       socket,
       workspace_id,
       &refresh_voice_channels(&1, workspace_id)
     )}
  end

  def handle_info(
        {:voice_channel_roster_changed, %{voice_channel_id: voice_channel_id, members: members}},
        socket
      ) do
    socket =
      assign(
        socket,
        :voice_channel_rosters,
        Map.put(socket.assigns.voice_channel_rosters, voice_channel_id, members)
      )

    case Workspaces.fetch_voice_channel(
           socket.assigns.current_scope,
           socket.assigns.selected_workspace.id,
           voice_channel_id
         ) do
      {:ok, voice_channel} -> {:noreply, stream_insert(socket, :voice_channels, voice_channel)}
      {:error, _reason} -> {:noreply, socket}
    end
  end

  def handle_info({:workspace_member_joined, %{workspace_id: workspace_id}}, socket) do
    {:noreply,
     WorkspaceEvents.apply_to_selected(
       socket,
       workspace_id,
       &refresh_workspace_members(&1, workspace_id)
     )}
  end

  def handle_info({:workspace_audit_changed, _payload}, socket) do
    {:noreply, socket}
  end

  def handle_info(event, socket) do
    case PresenceEvents.to_presence_event(event) do
      {:ok, :user_joined, payload} -> {:noreply, Presence.user_joined(socket, payload)}
      {:ok, :user_left, payload} -> {:noreply, Presence.user_left(socket, payload)}
      :error -> {:noreply, socket}
    end
  end

  @impl true
  def handle_event("show_workspace_form", _params, socket) do
    {:noreply, assign(socket, :show_workspace_form?, true)}
  end

  def handle_event("cancel_workspace_form", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_workspace_form?, false)
     |> assign(:workspace_form, workspace_form(socket.assigns.current_scope))}
  end

  def handle_event("create_workspace", %{"workspace" => workspace_params}, socket) do
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

  def handle_event("create_channel", %{"channel" => channel_params}, socket) do
    workspace_id = socket.assigns.selected_workspace.id

    case Workspaces.create_channel(socket.assigns.current_scope, workspace_id, channel_params) do
      {:ok, channel} ->
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

  def handle_event("create_workspace_invite", params, socket) do
    invite_params = Map.get(params, "invite", %{})
    workspace_id = socket.assigns.selected_workspace.id

    case Workspaces.create_workspace_invite(
           socket.assigns.current_scope,
           workspace_id,
           invite_params
         ) do
      {:ok, invite} ->
        {:noreply,
         socket
         |> assign(:invite_form, invite_form())
         |> assign(:invite_url, invite_url(invite))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Invite link could not be created.")}
    end
  end

  def handle_event("open_workspace_actions", %{"workspace_id" => workspace_id}, socket) do
    {:noreply,
     socket
     |> assign(:workspace_action_menu_id, workspace_id)
     |> assign(:context_menu_position, nil)}
  end

  def handle_event("close_context_menu", _params, socket) do
    {:noreply,
     socket
     |> assign(:workspace_action_menu_id, nil)
     |> assign(:context_menu_position, nil)}
  end

  def handle_event(
        "member_action",
        %{"action" => _action, "user_id" => _user_id} = params,
        socket
      ) do
    workspace_id = socket.assigns.selected_workspace.id

    MemberActions.run(socket, params, workspace_id, &refresh_member_action/2)
  end

  def handle_event("kick_member", %{"user_id" => _user_id} = params, socket) do
    workspace_id = socket.assigns.selected_workspace.id
    MemberActions.kick(socket, params, workspace_id, &refresh_member_action/2)
  end

  def handle_event("ban_member", %{"user_id" => _user_id} = params, socket) do
    workspace_id = socket.assigns.selected_workspace.id
    MemberActions.ban(socket, params, workspace_id, &refresh_member_action/2)
  end

  def handle_event("voice_disconnect", params, socket) do
    workspace_id = socket.assigns.selected_workspace.id
    MemberActions.voice_disconnect(socket, params, workspace_id)
  end

  def handle_event(_event, _params, socket) do
    {:noreply, put_flash(socket, :error, "Action could not be completed.")}
  end

  defp refresh_member_action(socket, %{workspace_id: workspace_id}) do
    {:ok, members} = Workspaces.list_members(socket.assigns.current_scope, workspace_id)
    Presence.refresh_workspace_members(socket, members)
  end

  defp workspace_form(scope, attrs \\ %{}) do
    scope
    |> Workspaces.change_workspace(attrs)
    |> to_form(as: :workspace)
  end

  defp channel_form(workspace_id, attrs \\ %{}) do
    workspace_id
    |> Workspaces.change_channel(attrs)
    |> to_form(as: :channel)
  end

  defp invite_form(attrs \\ %{}) do
    attrs
    |> Workspaces.change_workspace_invite()
    |> to_form(as: :invite)
  end

  defp invite_url(invite) do
    DiscordCloneWeb.Endpoint.url() <> "/invites/#{invite.code}"
  end

  defp load_channel_unread_counts(socket, workspace_id) do
    if connected?(socket) do
      Chat.list_unread_counts(socket.assigns.current_scope, workspace_id)
    else
      {:ok, %{}}
    end
  end

  defp subscribe_to_channel_read_states(socket, channels) do
    if connected?(socket) do
      Enum.reduce_while(channels, :ok, fn channel, :ok ->
        case Chat.subscribe_to_channel_read_state(socket.assigns.current_scope, channel.id) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    else
      :ok
    end
  end

  defp refresh_channel_sidebar(socket, workspace_id) do
    {:ok, channels} = Workspaces.list_channels(socket.assigns.current_scope, workspace_id)

    socket =
      case Chat.list_unread_counts(socket.assigns.current_scope, workspace_id) do
        {:ok, channel_unread_counts} ->
          assign(socket, :channel_unread_counts, channel_unread_counts)

        {:error, _reason} ->
          socket
      end

    stream(socket, :channels, channels, reset: true)
  end

  defp refresh_voice_channels(socket, workspace_id) do
    with :ok <- subscribe_to_voice_channel_rosters(socket, workspace_id),
         {:ok, voice_channels} <-
           Workspaces.list_voice_channels(socket.assigns.current_scope, workspace_id),
         {:ok, voice_channel_rosters} <-
           Workspaces.list_voice_channel_rosters(socket.assigns.current_scope, workspace_id) do
      socket
      |> assign(:voice_channel_rosters, voice_channel_rosters)
      |> stream(:voice_channels, voice_channels, reset: true)
    else
      _error -> socket
    end
  end

  defp refresh_workspace_members(socket, workspace_id) do
    case Workspaces.list_members(socket.assigns.current_scope, workspace_id) do
      {:ok, members} ->
        socket
        |> assign(:member_by_user_id, Map.new(members, &{&1.user_id, &1}))
        |> Presence.refresh_workspace_members(members)
        |> refresh_voice_channels(workspace_id)

      _error ->
        socket
    end
  end

  defp subscribe_to_voice_channel_rosters(socket, workspace_id) do
    if connected?(socket) do
      Workspaces.subscribe_to_voice_channel_rosters(socket.assigns.current_scope, workspace_id)
    else
      :ok
    end
  end

  defp authorize_invite_screen(current_scope, workspace) do
    if Workspaces.can_create_workspace_invite?(current_scope, workspace) do
      :ok
    else
      {:error, :invite_permission_required, workspace}
    end
  end
end
