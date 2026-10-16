defmodule DiscordCloneWeb.WorkspaceLive.Presence do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [connected?: 1, stream: 4, stream_configure: 3]

  alias DiscordClone.Chat

  def prepare_workspace(socket, workspace_id, members) do
    socket
    |> assign(:workspace_members, members)
    |> stream_configure(:workspace_members, dom_id: &sidebar_item_dom_id/1)
    |> join_workspace(workspace_id)
  end

  # Streaming the sidebar exactly once per mount matters: two stream calls in
  # the same render cycle merge into a single client patch, and items from the
  # first batch that the second batch no longer contains (e.g. a stale
  # "Offline" section header) are never removed from the DOM.
  def join_workspace(socket, workspace_id) do
    socket
    |> assign_online_user_ids(workspace_id)
    |> refresh_workspace_members()
  end

  defp assign_online_user_ids(socket, workspace_id) do
    if connected?(socket) do
      with :ok <- Chat.subscribe_to_workspace_presence(socket.assigns.current_scope, workspace_id),
           :ok <- Chat.join_workspace_presence(socket.assigns.current_scope, workspace_id),
           {:ok, online_user_ids} <-
             Chat.list_online_workspace_user_ids(socket.assigns.current_scope, workspace_id) do
        assign(socket, :online_user_ids, MapSet.new(online_user_ids))
      else
        {:error, _reason} -> assign(socket, :online_user_ids, seed_online_user_ids(socket))
      end
    else
      assign(socket, :online_user_ids, seed_online_user_ids(socket))
    end
  end

  # The current user is always online from their own point of view; seeding the
  # set with their id keeps the static render from listing them under Offline
  # before the real presence data arrives on connect.
  defp seed_online_user_ids(%{assigns: %{current_scope: %{user: %{id: user_id}}}}) do
    MapSet.new([user_id])
  end

  defp seed_online_user_ids(_socket), do: MapSet.new()

  def user_joined(socket, payload), do: update_online_user_ids(socket, payload, :join)
  def user_left(socket, payload), do: update_online_user_ids(socket, payload, :leave)

  def refresh_workspace_members(socket, members) do
    socket
    |> assign(:workspace_members, members)
    |> refresh_workspace_members()
  end

  defp update_online_user_ids(socket, %{workspace_id: workspace_id, user_id: user_id}, event)
       when event in [:join, :leave] do
    if selected_workspace_id(socket) == workspace_id do
      online_user_ids = Map.get(socket.assigns, :online_user_ids, MapSet.new())

      socket
      |> assign(:online_user_ids, update_user_id(online_user_ids, user_id, event))
      |> refresh_workspace_members()
    else
      socket
    end
  end

  defp update_online_user_ids(socket, _payload, _event), do: socket

  defp update_user_id(online_user_ids, user_id, :join), do: MapSet.put(online_user_ids, user_id)

  defp update_user_id(online_user_ids, user_id, :leave),
    do: MapSet.delete(online_user_ids, user_id)

  defp refresh_workspace_members(%{assigns: %{workspace_members: members}} = socket) do
    online_user_ids = Map.get(socket.assigns, :online_user_ids, MapSet.new())

    stream(socket, :workspace_members, sidebar_items(members, online_user_ids), reset: true)
  end

  defp refresh_workspace_members(socket), do: socket

  defp sidebar_items(members, online_user_ids) do
    [
      section_item(
        :online_owner,
        "Owner",
        online_members_by_role(members, online_user_ids, "owner")
      ),
      section_item(
        :online_admin,
        "Admins",
        online_members_by_role(members, online_user_ids, "admin")
      ),
      section_item(
        :online_member,
        "Members",
        online_members_by_role(members, online_user_ids, "member")
      ),
      section_item(:offline, "Offline", offline_members(members, online_user_ids))
    ]
    |> Enum.flat_map(fn
      {_section, _label, []} ->
        []

      {section, label, section_members} ->
        [%{type: :section, section: section, label: label}] ++
          Enum.map(section_members, &%{type: :member, section: section, member: &1})
    end)
  end

  defp section_item(section, label, members), do: {section, label, members}

  defp online_members_by_role(members, online_user_ids, role) do
    Enum.filter(members, fn member ->
      member.role == role and MapSet.member?(online_user_ids, member.user.id)
    end)
  end

  defp offline_members(members, online_user_ids) do
    Enum.reject(members, fn member -> MapSet.member?(online_user_ids, member.user.id) end)
  end

  defp sidebar_item_dom_id(%{type: :section, section: section}) do
    "workspace-members-#{section_dom_id(section)}-section"
  end

  defp sidebar_item_dom_id(%{type: :member, member: member}) do
    "workspace-member-#{member.user.id}"
  end

  defp section_dom_id(:online_owner), do: "online-owner"
  defp section_dom_id(:online_admin), do: "online-admin"
  defp section_dom_id(:online_member), do: "online-member"
  defp section_dom_id(:offline), do: "offline"

  defp selected_workspace_id(%{assigns: %{selected_workspace: %{id: workspace_id}}}) do
    workspace_id
  end

  defp selected_workspace_id(_socket), do: nil
end
