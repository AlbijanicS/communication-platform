defmodule DiscordCloneWeb.DirectMessagesNavigation do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, stream: 4, stream_configure: 3]

  alias DiscordClone.{Chat, Friendships}

  def on_mount(:assign_destination, _params, _session, socket) do
    if Phoenix.LiveView.connected?(socket) do
      :ok = Chat.subscribe_to_direct_navigation(socket.assigns.current_scope)
      :ok = Friendships.subscribe(socket.assigns.current_scope)
    end

    {:ok, destinations} =
      Chat.list_direct_conversation_destinations(socket.assigns.current_scope)

    {:ok, incoming_requests} =
      Friendships.list_incoming_requests(socket.assigns.current_scope)

    socket =
      socket
      |> stream_configure(:direct_conversation_destinations,
        dom_id: &"direct-conversation-entry-#{&1.direct_conversation.id}"
      )
      |> assign_destination_summary(destinations, incoming_requests)
      |> attach_hook(:direct_messages_navigation, :handle_info, &refresh_on_change/2)

    {:cont, socket}
  end

  defp refresh_on_change({:direct_navigation_changed, _payload}, socket) do
    {:halt, refresh_destination_summary(socket)}
  end

  defp refresh_on_change({:friendships_changed, _payload}, socket) do
    socket = refresh_destination_summary(socket)

    if socket.view in [
         DiscordCloneWeb.FriendsLive,
         DiscordCloneWeb.DirectConversationLive
       ] do
      {:cont, socket}
    else
      {:halt, socket}
    end
  end

  defp refresh_on_change(_message, socket), do: {:cont, socket}

  defp refresh_destination_summary(socket) do
    {:ok, destinations} =
      Chat.list_direct_conversation_destinations(socket.assigns.current_scope)

    {:ok, incoming_requests} =
      Friendships.list_incoming_requests(socket.assigns.current_scope)

    assign_destination_summary(socket, destinations, incoming_requests)
  end

  defp assign_destination_summary(socket, destinations, incoming_requests) do
    socket
    |> assign(
      :direct_message_unread_count,
      destinations |> Enum.map(& &1.unread_count) |> Enum.sum()
    )
    |> assign(:incoming_friend_request_count, length(incoming_requests))
    |> stream(:direct_conversation_destinations, destinations, reset: true)
  end
end
