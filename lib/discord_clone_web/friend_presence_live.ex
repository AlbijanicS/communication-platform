defmodule DiscordCloneWeb.FriendPresenceLive do
  @moduledoc false

  alias DiscordClone.Presence

  def on_mount(:register_connection, _params, _session, socket) do
    if Phoenix.LiveView.connected?(socket) do
      :ok = Presence.join(socket.assigns.current_scope, self())
    end

    {:cont, socket}
  end
end
