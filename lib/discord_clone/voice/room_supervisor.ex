defmodule DiscordClone.Voice.RoomSupervisor do
  @moduledoc false

  use Supervisor, restart: :temporary

  alias DiscordClone.Voice.{Forwarder, RoomServer, SessionSupervisor}

  @spec start_link(Ecto.UUID.t()) :: Supervisor.on_start()
  def start_link(voice_channel_id) do
    Supervisor.start_link(__MODULE__, voice_channel_id)
  end

  @impl true
  def init(voice_channel_id) do
    children = [
      # Idle retirement exits normally while its outside-tree stop completes.
      # Do not briefly restart an admissible generation in that retiring tree.
      Supervisor.child_spec(
        {RoomServer, voice_channel_id: voice_channel_id, room_supervisor: self()},
        restart: :transient
      ),
      {SessionSupervisor, voice_channel_id: voice_channel_id},
      {Forwarder, voice_channel_id: voice_channel_id}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
