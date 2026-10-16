defmodule DiscordCloneWeb.VoiceSignaling.FakeIce do
  @moduledoc false

  alias DiscordCloneWeb.VoiceSignaling.FakeMessage

  @spec validate(map()) ::
          {:ok, %{label: String.t(), sequence: non_neg_integer()}} | {:error, map()}
  defdelegate validate(payload), to: FakeMessage
end
