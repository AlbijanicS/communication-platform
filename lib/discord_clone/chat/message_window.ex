defmodule DiscordClone.Chat.MessageWindow do
  @moduledoc """
  Seq-based message-window loading and pagination metadata for the Chat context.

  A window is a `%{messages: [...], meta: %{...}}` map: the messages ordered by
  ascending `seq`, plus meta flags describing where the window sits relative to a
  channel's latest message (`has_older?` / `has_newer?` / `at_latest?` /
  `at_or_near_latest?`). Both the `DiscordClone.Chat` context and its
  `DiscordClone.Chat.Unread` submodule load windows through this module so the
  query, the meta builder, and the boundary rules live in exactly one place.
  """

  import Ecto.Query

  alias DiscordClone.Chat.{Conversation, Message}
  alias DiscordClone.Repo
  alias DiscordClone.Workspaces.Channel

  @message_page_size 50

  @doc """
  Loads the window of messages in `[from_seq, to_seq]` for `channel`, ordered by
  ascending `seq`, with pagination meta computed against the channel's latest
  message.
  """
  def load_for_channel(%Channel{} = channel, from_seq, to_seq) do
    load_for_conversation(channel.conversation, from_seq, to_seq)
  end

  @doc """
  Loads a bounded Message window for either Conversation kind.
  """
  def load_for_conversation(%Conversation{} = conversation, from_seq, to_seq) do
    messages =
      conversation.id
      |> messages_between_sequences(from_seq, to_seq)
      |> Repo.all()

    message_window(messages, conversation.last_message_seq)
  end

  @doc """
  Loads a window centered on `target_seq` — a small backtrack before the target
  and a larger run after it — clamped to the channel's message range.
  """
  def load_around_channel(%Channel{} = channel, target_seq) do
    load_around_conversation(channel.conversation, target_seq)
  end

  @doc """
  Loads a bounded Message window centered on a target sequence for either
  Conversation kind.
  """
  def load_around_conversation(%Conversation{} = conversation, target_seq) do
    from_seq = max(1, target_seq - 15)
    to_seq = min(conversation.last_message_seq, target_seq + 35)
    load_for_conversation(conversation, from_seq, to_seq)
  end

  defp messages_between_sequences(conversation_id, from_seq, to_seq) do
    Message
    |> where([message], message.channel_id == ^conversation_id)
    |> where([message], message.seq >= ^from_seq and message.seq <= ^to_seq)
    |> order_by([message], asc: message.seq)
    |> preload(^Message.display_preloads())
  end

  defp message_window(messages, latest_seq) do
    oldest_seq = messages |> List.first() |> message_seq()
    newest_seq = messages |> List.last() |> message_seq()

    %{
      messages: messages,
      meta: %{
        oldest_seq: oldest_seq,
        newest_seq: newest_seq,
        latest_seq: latest_seq,
        has_older?: older_history?(oldest_seq),
        has_newer?: newer_history?(newest_seq, latest_seq),
        at_latest?: at_latest?(newest_seq, latest_seq),
        at_or_near_latest?: at_or_near_latest?(newest_seq, latest_seq)
      }
    }
  end

  defp message_seq(%Message{seq: seq}), do: seq
  defp message_seq(nil), do: nil

  defp older_history?(oldest_seq) when is_integer(oldest_seq), do: oldest_seq > 1
  defp older_history?(nil), do: false

  defp newer_history?(newest_seq, latest_seq) when is_integer(newest_seq),
    do: newest_seq < latest_seq

  defp newer_history?(nil, latest_seq), do: latest_seq > 0

  defp at_latest?(newest_seq, latest_seq) when is_integer(newest_seq),
    do: newest_seq == latest_seq

  defp at_latest?(nil, 0), do: true
  defp at_latest?(nil, _latest_seq), do: false

  defp at_or_near_latest?(newest_seq, latest_seq) when is_integer(newest_seq),
    do: latest_seq - newest_seq <= @message_page_size

  defp at_or_near_latest?(nil, 0), do: true
  defp at_or_near_latest?(nil, _latest_seq), do: false
end
