defmodule DiscordCloneWeb.CallSocket do
  use Phoenix.Socket, log: false

  alias DiscordCloneWeb.CallSignaling
  alias DiscordCloneWeb.CallSignaling.Diagnostics
  alias DiscordCloneWeb.UserAuth

  @inbox_topic CallSignaling.inbox_topic()

  channel @inbox_topic, DiscordCloneWeb.CallInboxChannel
  channel "call:*", DiscordCloneWeb.CallChannel

  @impl true
  def connect(_params, socket, connect_info) do
    case UserAuth.authenticate_socket(socket, connect_info) do
      {:ok, socket} ->
        socket = Phoenix.Socket.assign(socket, :connection_id, Ecto.UUID.generate())
        Diagnostics.emit("connect", :accepted)
        {:ok, socket}

      :error ->
        Diagnostics.emit("connect", :rejected, error_code: :unauthenticated)
        :error
    end
  end

  @impl true
  def id(socket), do: socket.assigns.user_session_topic
end
