defmodule DiscordClone.Chat.Unread.Spans do
  @moduledoc """
  Pure interval algebra for Channel unread spans.

  Spans are inclusive `{from_seq, to_seq}` integer tuples. This module does not
  validate product range limits or touch persistence; callers own those
  boundaries before storing the resulting spans.
  """

  def merge(spans) do
    spans
    |> Enum.sort_by(fn {from_seq, to_seq} -> {from_seq, to_seq} end)
    |> Enum.reduce([], fn
      span, [] ->
        [span]

      {from_seq, to_seq}, [{current_from_seq, current_to_seq} | rest]
      when from_seq <= current_to_seq + 1 ->
        [{current_from_seq, max(current_to_seq, to_seq)} | rest]

      span, merged ->
        [span | merged]
    end)
    |> Enum.reverse()
  end

  def subtract(spans, read_from_seq, read_to_seq) do
    spans
    |> Enum.flat_map(fn {from_seq, to_seq} ->
      cond do
        read_to_seq < from_seq or read_from_seq > to_seq ->
          [{from_seq, to_seq}]

        read_from_seq <= from_seq and read_to_seq >= to_seq ->
          []

        read_from_seq <= from_seq ->
          [{read_to_seq + 1, to_seq}]

        read_to_seq >= to_seq ->
          [{from_seq, read_from_seq - 1}]

        true ->
          [{from_seq, read_from_seq - 1}, {read_to_seq + 1, to_seq}]
      end
    end)
  end

  def from_sequences([]), do: []

  def from_sequences([first_seq | rest]) do
    {spans, from_seq, to_seq} =
      Enum.reduce(rest, {[], first_seq, first_seq}, fn seq, {spans, from_seq, to_seq} ->
        if seq == to_seq + 1 do
          {spans, from_seq, seq}
        else
          {[{from_seq, to_seq} | spans], seq, seq}
        end
      end)

    Enum.reverse([{from_seq, to_seq} | spans])
  end
end
