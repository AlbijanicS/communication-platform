defmodule DiscordClone.Chat.Emoji do
  @moduledoc """
  Normalizes and validates emoji payloads used by Chat workflows.
  """

  @max_reaction_bytes 64
  @shortcodes %{
    ":thumbsup:" => "👍",
    ":heart:" => "❤️"
  }

  def render_shortcodes(content) when is_binary(content) do
    Enum.reduce(@shortcodes, content, fn {shortcode, emoji}, rendered ->
      String.replace(rendered, shortcode, emoji)
    end)
  end

  def validate_reaction(value) when is_binary(value) do
    if String.valid?(value) do
      value
      |> normalize_reaction()
      |> validate_normalized_reaction()
    else
      {:error, :invalid}
    end
  end

  def validate_reaction(_value), do: {:error, :invalid}

  defp normalize_reaction(value) do
    value
    |> String.trim()
    |> String.normalize(:nfc)
  end

  defp validate_normalized_reaction(normalized) do
    if byte_size(normalized) > @max_reaction_bytes do
      {:error, :too_long}
    else
      validate_reaction_graphemes(normalized)
    end
  end

  defp validate_reaction_graphemes(normalized) do
    case String.graphemes(normalized) do
      [] -> {:error, :blank}
      [_grapheme] -> {:ok, normalized}
      _graphemes -> {:error, :multiple_graphemes}
    end
  end
end
