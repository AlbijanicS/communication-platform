defmodule DiscordClone.Media.Profile do
  @moduledoc "Stable topology of a media target, independent of its transport implementation."

  @enforce_keys [:kind, :capacity, :topology]
  defstruct [:kind, :capacity, :topology]

  @type t :: %__MODULE__{
          kind: :direct_call | :voice,
          capacity: 2 | 5,
          topology: :one_to_one | :microphone_and_four_outputs
        }

  @spec direct_call() :: t()
  def direct_call, do: %__MODULE__{kind: :direct_call, capacity: 2, topology: :one_to_one}

  @spec voice() :: t()
  def voice, do: %__MODULE__{kind: :voice, capacity: 5, topology: :microphone_and_four_outputs}

  @doc "Browser positions; dormant video keeps sendrecv without a camera track."
  @spec positions(t()) :: [{:audio | :video, :sendonly | :recvonly | :sendrecv, :opus | :vp8}]
  def positions(%__MODULE__{topology: :one_to_one}),
    do: [{:audio, :sendrecv, :opus}, {:video, :sendrecv, :vp8}]

  def positions(%__MODULE__{topology: :microphone_and_four_outputs}),
    do: [{:audio, :sendonly, :opus} | List.duplicate({:audio, :recvonly, :opus}, 4)]
end
