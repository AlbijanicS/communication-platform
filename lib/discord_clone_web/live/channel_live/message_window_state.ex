defmodule DiscordCloneWeb.ChannelLive.MessageWindowState do
  @moduledoc """
  Rendered-window state management for `ChannelLive.Show`.

  The channel view keeps a bounded window of messages in a stream plus a
  `message_window_meta` map describing where that window sits relative to the
  channel's latest message. This module owns the family of operations that keep
  the two in sync as messages arrive and the user scrolls:

    * **trim** — capping the rendered stream at `@rendered_message_limit`,
      deleting the overflow rows and pruning their per-message state
    * **boundary** — recomputing the `oldest_message` / `latest_message`
      assigns after a trim
    * **window-meta** — the pure map transforms that advance the meta when a
      new message lands (`latest_window_meta` / `newer_available_meta`) or when
      an older/newer page is merged in (`merge_older_window_meta` /
      `merge_newer_window_meta`)

  The view calls into these helpers instead of owning the logic inline.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [stream_delete: 3, push_event: 3]

  @rendered_message_limit 300
  @message_page_size 50

  @doc """
  Returns the currently rendered rows sorted by ascending `seq`.
  """
  def visible_message_rows(socket) do
    socket.assigns.message_rows_by_id
    |> Map.values()
    |> Enum.sort_by(& &1.message.seq)
  end

  @doc """
  Whether a newly created message should be appended to the rendered window —
  true only when the window is at or near the channel's latest message.
  """
  def append_selected_channel_message?(socket) do
    socket.assigns.message_window_meta.at_or_near_latest?
  end

  @doc """
  Trims the rendered stream back to `@rendered_message_limit`, removing rows
  from `trim_side` (`:older` or `:newer`) and keeping the message state,
  boundaries, and window meta consistent with what remains.
  """
  def trim(socket, trim_side) do
    rows = visible_message_rows(socket)
    overage = length(rows) - @rendered_message_limit

    if overage > 0 do
      {removed_rows, kept_rows} = split_trimmed_rows(rows, overage, trim_side)
      removed_message_ids = Enum.map(removed_rows, & &1.message.id)

      socket
      |> delete_message_rows(removed_rows)
      |> prune_message_state(removed_message_ids)
      |> assign_visible_boundaries(kept_rows, trim_side)
      |> push_removed_message_rows(removed_rows)
    else
      socket
    end
  end

  @doc """
  Advances the window meta when `message` becomes the new latest rendered
  message, pinning the window to the channel tail.
  """
  def latest_window_meta(meta, message) do
    latest_seq = max(meta.latest_seq || 0, message.seq)

    meta
    |> Map.put(:newest_seq, message.seq)
    |> Map.put(:latest_seq, latest_seq)
    |> Map.put(:has_newer?, false)
    |> Map.put(:at_latest?, true)
    |> Map.put(:at_or_near_latest?, true)
  end

  @doc """
  Advances the window meta when a newer `message` exists on the channel but is
  not being appended to the rendered window.
  """
  def newer_available_meta(meta, message) do
    latest_seq = max(meta.latest_seq || 0, message.seq)

    meta
    |> Map.put(:latest_seq, latest_seq)
    |> Map.put(:has_newer?, true)
    |> Map.put(:at_latest?, false)
    |> Map.put(:at_or_near_latest?, false)
  end

  @doc """
  Merges the meta of a freshly loaded older page into the current window meta.
  """
  def merge_older_window_meta(current_meta, older_meta) do
    current_meta
    |> Map.put(:oldest_seq, older_meta.oldest_seq || current_meta.oldest_seq)
    |> Map.put(:latest_seq, max(current_meta.latest_seq || 0, older_meta.latest_seq || 0))
    |> Map.put(:has_older?, older_meta.has_older?)
  end

  @doc """
  Merges the meta of a freshly loaded newer page into the current window meta.
  """
  def merge_newer_window_meta(current_meta, newer_meta) do
    current_meta
    |> Map.put(:newest_seq, newer_meta.newest_seq || current_meta.newest_seq)
    |> Map.put(:latest_seq, max(current_meta.latest_seq || 0, newer_meta.latest_seq || 0))
    |> Map.put(:has_newer?, newer_meta.has_newer?)
    |> Map.put(:at_latest?, newer_meta.at_latest?)
    |> Map.put(:at_or_near_latest?, newer_meta.at_or_near_latest?)
  end

  defp split_trimmed_rows(rows, overage, :newer) do
    Enum.split(rows, length(rows) - overage)
    |> then(fn {kept_rows, removed_rows} -> {removed_rows, kept_rows} end)
  end

  defp split_trimmed_rows(rows, overage, :older) do
    Enum.split(rows, overage)
  end

  defp delete_message_rows(socket, removed_rows) do
    Enum.reduce(removed_rows, socket, fn row, socket ->
      stream_delete(socket, :messages, row)
    end)
  end

  defp prune_message_state(socket, message_ids) do
    socket
    |> assign(:message_rows_by_id, Map.drop(socket.assigns.message_rows_by_id, message_ids))
    |> assign(:reaction_summaries, Map.drop(socket.assigns.reaction_summaries, message_ids))
  end

  defp assign_visible_boundaries(socket, [] = _kept_rows, _trim_side) do
    socket
    |> assign(:oldest_message, nil)
    |> assign(:latest_message, nil)
    |> assign(:has_older_messages?, false)
  end

  defp assign_visible_boundaries(socket, kept_rows, trim_side) do
    oldest_message = kept_rows |> List.first() |> Map.fetch!(:message)
    latest_message = kept_rows |> List.last() |> Map.fetch!(:message)

    socket
    |> assign(:oldest_message, oldest_message)
    |> assign(:latest_message, latest_message)
    |> assign(
      :message_window_meta,
      trimmed_window_meta(
        socket.assigns.message_window_meta,
        oldest_message,
        latest_message,
        trim_side
      )
    )
    |> assign(
      :has_older_messages?,
      trimmed_has_older?(socket.assigns.message_window_meta, trim_side)
    )
  end

  defp trimmed_window_meta(meta, oldest_message, latest_message, trim_side) do
    meta
    |> Map.put(:oldest_seq, oldest_message.seq)
    |> Map.put(:newest_seq, latest_message.seq)
    |> Map.put(:has_older?, trimmed_has_older?(meta, trim_side))
    |> Map.put(:has_newer?, trimmed_has_newer?(meta, trim_side))
    |> Map.put(:at_latest?, trimmed_at_latest?(meta, latest_message, trim_side))
    |> Map.put(:at_or_near_latest?, trimmed_at_or_near_latest?(meta, latest_message, trim_side))
  end

  defp trimmed_has_older?(_meta, :older), do: true
  defp trimmed_has_older?(meta, :newer), do: meta.has_older?

  defp trimmed_has_newer?(_meta, :newer), do: true
  defp trimmed_has_newer?(meta, :older), do: meta.has_newer?

  defp trimmed_at_latest?(_meta, _latest_message, :newer), do: false
  defp trimmed_at_latest?(meta, latest_message, :older), do: latest_message.seq == meta.latest_seq

  defp trimmed_at_or_near_latest?(_meta, _latest_message, :newer), do: false

  defp trimmed_at_or_near_latest?(meta, latest_message, :older) do
    meta.latest_seq - latest_message.seq <= @message_page_size
  end

  defp push_removed_message_rows(socket, []), do: socket

  defp push_removed_message_rows(socket, removed_rows) do
    push_event(socket, "remove_channel_message_rows", %{
      container_id: "channel-messages",
      message_ids: Enum.map(removed_rows, & &1.message.id),
      row_ids: Enum.map(removed_rows, &"message-#{&1.message.id}")
    })
  end
end
