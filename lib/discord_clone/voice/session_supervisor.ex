defmodule DiscordClone.Voice.SessionSupervisor do
  @moduledoc false

  use DynamicSupervisor

  alias DiscordClone.Media.{SessionSupervisor, Target}

  @spec start_link(keyword()) :: DynamicSupervisor.on_start()
  def start_link(opts) do
    voice_channel_id = Keyword.fetch!(opts, :voice_channel_id)
    room = room_server(voice_channel_id)

    with {:ok, supervisor} <-
           SessionSupervisor.start_link(
             target: Target.voice_channel(voice_channel_id),
             generation: room
           ) do
      if is_pid(room), do: send(room, {:session_supervisor_started, room, supervisor})
      {:ok, supervisor}
    end
  end

  @spec name(Ecto.UUID.t()) :: {:via, Registry, {module(), term()}}
  def name(voice_channel_id),
    do:
      Target.runtime_name(
        Target.voice_channel(voice_channel_id),
        room_server(voice_channel_id),
        :sessions
      )

  @impl true
  def init(opts), do: SessionSupervisor.init(opts)

  defp room_server(voice_channel_id) do
    GenServer.whereis(
      {:via, Registry, {DiscordClone.Voice.RoomRegistry, {:room, voice_channel_id}}}
    )
  end
end
