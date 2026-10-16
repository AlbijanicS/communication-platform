defmodule DiscordCloneWeb.CallSignalingProtocolTest do
  use ExUnit.Case, async: true

  alias DiscordCloneWeb.CallSignaling

  @js_path "assets/js/call_signaling.js"

  test "browser topic, command events, and terminal events match the Elixir protocol" do
    js = File.read!(@js_path)

    assert js =~
             ~r/export const CALL_INBOX_TOPIC = "#{Regex.escape(CallSignaling.inbox_topic())}"/

    assert js =~
             ~r/export const CALL_TOPIC_PREFIX = "#{Regex.escape(CallSignaling.call_topic_prefix())}"/

    assert exported_js_events(js, "CALL_COMMAND_EVENTS") ==
             Enum.sort(CallSignaling.call_command_events())

    assert exported_js_events(js, "CALL_RESERVED_CONTROL_EVENTS") ==
             Enum.sort(CallSignaling.reserved_control_events())

    assert exported_js_events(js, "CALL_RESERVED_MEDIA_EVENTS") ==
             Enum.sort(CallSignaling.reserved_media_events())

    assert exported_js_events(js, "CALL_LIFECYCLE_EVENTS") ==
             Enum.sort(Map.values(CallSignaling.lifecycle_events()))

    assert exported_js_events(js, "CALL_SIBLING_EVENTS") ==
             Enum.sort(CallSignaling.sibling_events())

    [_, array] = Regex.run(~r/export const CALL_TERMINAL_EVENTS = \[([^\]]+)\]/, js)

    js_events =
      array
      |> String.split(",")
      |> Enum.map(&(&1 |> String.trim() |> String.trim("\"")))
      |> Enum.reject(&(&1 == ""))
      |> Enum.sort()

    elixir_events =
      CallSignaling.terminal_events()
      |> Map.values()
      |> Enum.uniq()
      |> Enum.sort()

    assert js_events == elixir_events
  end

  defp exported_js_events(js, constant_name) do
    [_, array] = Regex.run(~r/export const #{constant_name} = \[([^\]]*)\]/s, js)

    array
    |> String.split(",")
    |> Enum.map(&(&1 |> String.trim() |> String.trim("\"")))
    |> Enum.reject(&(&1 == ""))
    |> Enum.sort()
  end
end
