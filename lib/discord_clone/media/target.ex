defmodule DiscordClone.Media.Target do
  @moduledoc false

  @enforce_keys [:kind, :id]
  defstruct [:kind, :id]

  @type t :: %__MODULE__{kind: :voice_channel | :direct_call, id: Ecto.UUID.t()}

  @spec voice_channel(Ecto.UUID.t()) :: t()
  def voice_channel(id), do: %__MODULE__{kind: :voice_channel, id: id}

  @spec direct_call(Ecto.UUID.t()) :: t()
  def direct_call(id), do: %__MODULE__{kind: :direct_call, id: id}

  @type generation :: pid() | reference()
  @type role :: :room | :sessions | :forwarder

  # Voice's RoomServer PID changes on every coherent room restart. Calls use
  # their existing opaque runtime generation. Neither can address a successor.
  @spec runtime_name(t(), generation(), role()) :: {:via, Registry, {module(), term()}}
  def runtime_name(%__MODULE__{} = target, generation, role) do
    {:via, Registry, {DiscordClone.Voice.RoomRegistry, {target, generation, role}}}
  end

  @spec register_runtime(t(), generation(), role()) :: {:ok, pid()} | {:error, term()}
  def register_runtime(target, generation, role) do
    {:via, Registry, {registry, key}} = runtime_name(target, generation, role)
    Registry.register(registry, key, nil)
  end
end
