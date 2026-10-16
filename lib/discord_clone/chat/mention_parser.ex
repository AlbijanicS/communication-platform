defmodule DiscordClone.Chat.MentionParser do
  @moduledoc """
  Recognizes username-shaped direct mentions in message content.

  Resolution and authorization deliberately live in the Chat context, where
  membership can be checked in the message-send transaction.
  """

  @username_pattern ~r/(?<![A-Za-z0-9_@])@([A-Za-z0-9_]{3,32})(?![A-Za-z0-9_])/u

  @doc "Returns unique, normalized username candidates in first-seen order."
  @spec usernames(term()) :: [String.t()]
  def usernames(content) when is_binary(content) do
    content
    |> segments()
    |> Enum.flat_map(fn
      {:mention, _kind, _source, username} -> [username]
      {:text, _text} -> []
    end)
    |> Enum.uniq()
  end

  def usernames(_content), do: []

  @doc "Splits Message content into plain text and recognized mention syntax."
  @spec segments(String.t()) ::
          [{:text, String.t()} | {:mention, :user | :everyone, String.t(), String.t()}]
  def segments(content) when is_binary(content) do
    {segments, cursor} =
      @username_pattern
      |> Regex.scan(content, return: :index, capture: :all)
      |> Enum.reduce({[], 0}, fn
        [{mention_start, mention_length}, {username_start, username_length}],
        {segments, cursor} ->
          text = binary_part(content, cursor, mention_start - cursor)
          source = binary_part(content, mention_start, mention_length)

          username =
            content
            |> binary_part(username_start, username_length)
            |> String.downcase()

          mention_kind = if username == "everyone", do: :everyone, else: :user

          segments =
            segments
            |> prepend_text(text)
            |> then(&[{:mention, mention_kind, source, username} | &1])

          {segments, mention_start + mention_length}
      end)

    trailing_text = binary_part(content, cursor, byte_size(content) - cursor)

    segments
    |> prepend_text(trailing_text)
    |> Enum.reverse()
  end

  defp prepend_text(segments, ""), do: segments
  defp prepend_text(segments, text), do: [{:text, text} | segments]
end
