defmodule DiscordCloneWeb.ChannelLive.MessageRows do
  @moduledoc false

  @grouping_window_seconds 5 * 60

  def annotate(messages) do
    messages
    |> Enum.map_reduce(nil, fn message, previous_message ->
      {annotate_next(previous_message, message), message}
    end)
    |> elem(0)
  end

  def annotate_next(previous_message, message) do
    %{
      id: message.id,
      message: message,
      row_kind: row_kind(previous_message, message)
    }
  end

  defp row_kind(nil, _message), do: :full

  defp row_kind(previous_message, message) do
    if same_author?(previous_message, message) and
         within_grouping_window?(previous_message, message) do
      :compact
    else
      :full
    end
  end

  defp same_author?(previous_message, message), do: previous_message.user_id == message.user_id

  defp within_grouping_window?(previous_message, message) do
    seconds = DateTime.diff(message.inserted_at, previous_message.inserted_at, :second)
    seconds >= 0 and seconds <= @grouping_window_seconds
  end
end
