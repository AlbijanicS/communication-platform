defmodule DiscordCloneWeb.VoiceSocket do
  use Phoenix.Socket

  alias DiscordCloneWeb.UserAuth

  channel "voice:*", DiscordCloneWeb.VoiceChannel

  @impl true
  def connect(_params, socket, connect_info) do
    UserAuth.authenticate_socket(socket, connect_info)
  end

  @impl true
  def id(socket), do: socket.assigns.user_session_topic
end
