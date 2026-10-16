defmodule DiscordCloneWeb.Signaling do
  @moduledoc false

  @spec decoded_request_byte_count(term()) :: non_neg_integer() | nil
  def decoded_request_byte_count(payload) do
    case Jason.encode(payload) do
      {:ok, encoded} -> byte_size(encoded)
      {:error, _reason} -> nil
    end
  end
end
