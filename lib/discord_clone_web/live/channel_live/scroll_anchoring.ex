defmodule DiscordCloneWeb.ChannelLive.ScrollAnchoring do
  @moduledoc """
  Scroll-anchoring helpers for `ChannelLive.Show`.

  When an older or newer page of messages is spliced into the rendered window,
  the browser's scroll position has to be preserved so the viewport does not
  jump. This module builds the payloads pushed to the `ChannelMessages` hook to
  preserve or restore that position, guards against unstable scroll-edge events
  fired before the container has laid out, and owns the numeric parsing the
  hook payloads and scroll-target data attributes depend on.
  """

  import Phoenix.LiveView, only: [push_event: 3]

  @doc """
  Pushes the payload that preserves scroll position after older messages are
  prepended, keeping the anchor row visually fixed.
  """
  def preserve_scroll_after_older_load(
        socket,
        %{
          "container_id" => container_id,
          "scroll_height" => scroll_height,
          "scroll_top" => scroll_top
        } = params
      ) do
    payload =
      params
      |> scroll_anchor_payload()
      |> Map.merge(%{
        container_id: container_id,
        previous_scroll_height: scroll_number(scroll_height),
        previous_scroll_top: scroll_number(scroll_top)
      })

    push_event(socket, "preserve_channel_messages_scroll", payload)
  end

  def preserve_scroll_after_older_load(socket, _params), do: socket

  @doc """
  Pushes the payload that restores scroll position after newer messages are
  appended.
  """
  def restore_scroll_after_newer_load(
        socket,
        %{
          "container_id" => container_id,
          "scroll_top" => scroll_top
        } = params
      ) do
    payload =
      params
      |> scroll_anchor_payload()
      |> Map.merge(%{
        container_id: container_id,
        previous_scroll_top: scroll_number(scroll_top)
      })

    push_event(socket, "restore_channel_messages_scroll", payload)
  end

  def restore_scroll_after_newer_load(socket, _params), do: socket

  @doc """
  Whether a scroll-edge load event fired while the container was too short to
  scroll (height not yet exceeding the viewport), which should be ignored.
  """
  def unstable_scroll_edge_event?(%{
        "client_height" => client_height,
        "scroll_height" => scroll_height
      }) do
    with {:ok, client_height} <- parse_number(client_height),
         {:ok, scroll_height} <- parse_number(scroll_height) do
      scroll_height <= client_height
    else
      :error -> false
    end
  end

  def unstable_scroll_edge_event?(_params), do: false

  @doc """
  The scroll-target kind rendered as a data attribute for the hook, or `nil`.
  """
  def scroll_target_kind(%{kind: kind}), do: Atom.to_string(kind)
  def scroll_target_kind(_target), do: nil

  @doc """
  The scroll-target seq rendered as a data attribute for the hook, or `nil`.
  """
  def scroll_target_seq(%{seq: seq}) when is_integer(seq), do: seq
  def scroll_target_seq(_target), do: nil

  @doc """
  Returns the unique token for a user-initiated scroll target, or `nil`.

  The browser includes this token in its de-duplication key so navigating to
  the same Message more than once still performs a fresh scroll.
  """
  def scroll_target_token(%{token: token}) when is_integer(token), do: token
  def scroll_target_token(_target), do: nil

  @doc """
  Parses a value into an integer, returning `{:ok, integer}` or `:error`.
  """
  def parse_integer(value) when is_integer(value), do: {:ok, value}

  def parse_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> {:ok, integer}
      _invalid -> :error
    end
  end

  def parse_integer(_value), do: :error

  defp scroll_anchor_payload(%{
         "anchor_row_id" => anchor_row_id,
         "anchor_offset_top" => anchor_offset_top
       })
       when is_binary(anchor_row_id) do
    %{
      anchor_row_id: anchor_row_id,
      anchor_offset_top: scroll_number(anchor_offset_top)
    }
  end

  defp scroll_anchor_payload(_params), do: %{}

  defp parse_number(value) when is_integer(value) or is_float(value), do: {:ok, value}

  defp parse_number(value) when is_binary(value) do
    case Float.parse(value) do
      {number, ""} -> {:ok, number}
      _invalid -> :error
    end
  end

  defp parse_number(_value), do: :error

  defp scroll_number(value) when is_integer(value) or is_float(value), do: value

  defp scroll_number(value) when is_binary(value) do
    case Float.parse(value) do
      {number, ""} -> number
      _invalid -> 0
    end
  end

  defp scroll_number(_value), do: 0
end
