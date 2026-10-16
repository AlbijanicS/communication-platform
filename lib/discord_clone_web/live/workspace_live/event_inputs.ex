defmodule DiscordCloneWeb.WorkspaceLive.EventInputs do
  @moduledoc """
  Rejects malformed Workspace management payloads before they reach handlers.
  This checks shape and identifier syntax only; contexts still authorize every
  mutation and validate names, moderation presets, and other business values.
  """

  import Phoenix.LiveView, only: [attach_hook: 4, put_flash: 3]

  alias DiscordClone.UUIDIdentifier

  @fields %{
    "create_workspace" => [{"workspace", :map}],
    "begin_workspace_rename" => [{"workspace_id", :uuid}],
    "rename_workspace" => [{"workspace_id", :uuid}, {"workspace", :map}],
    "delete_workspace" => [{"workspace_id", :uuid}],
    "leave_workspace" => [{"workspace_id", :uuid}],
    "open_workspace_actions" => [{"workspace_id", :uuid}],
    "create_channel" => [{"channel", :map}],
    "begin_channel_rename" => [{"channel_id", :uuid}],
    "rename_channel" => [{"channel_id", :uuid}, {"channel", :map}],
    "delete_channel" => [{"channel_id", :uuid}],
    "open_channel_actions" => [{"channel_id", :uuid}],
    "mark_sidebar_channel_read" => [{"channel_id", :uuid}],
    "create_voice_channel" => [{"voice_channel", :map}],
    "begin_voice_channel_rename" => [{"voice_channel_id", :uuid}],
    "rename_voice_channel" => [{"voice_channel_id", :uuid}, {"voice_channel", :map}],
    "delete_voice_channel" => [{"voice_channel_id", :uuid}],
    "open_voice_channel_actions" => [{"voice_channel_id", :uuid}],
    "member_action" => [{"action", :string}, {"user_id", :uuid}],
    "kick_member" => [{"user_id", :uuid}],
    "ban_member" => [{"user_id", :uuid}],
    "unban_member" => [{"user_id", :uuid}],
    "voice_disconnect" => [{"voice_channel_id", :uuid}, {"user_id", :uuid}],
    "open_context_menu" => [{"type", :menu_type}, {"id", :uuid}, {"x", :present}, {"y", :present}]
  }

  def attach(socket), do: attach_hook(socket, :workspace_event_inputs, :handle_event, &validate/3)

  defp validate(event, params, socket) do
    case Map.fetch(@fields, event) do
      {:ok, fields} ->
        if valid_fields?(params, fields),
          do: {:cont, socket},
          else: {:halt, put_flash(socket, :error, "Action could not be completed.")}

      :error ->
        {:cont, socket}
    end
  end

  defp valid_fields?(params, fields) when is_map(params) do
    Enum.all?(fields, fn {key, type} ->
      case Map.fetch(params, key) do
        {:ok, value} -> valid_value?(type, value)
        :error -> false
      end
    end)
  end

  defp valid_fields?(_params, _fields), do: false

  defp valid_value?(:uuid, value), do: match?({:ok, _}, UUIDIdentifier.cast(value))
  defp valid_value?(:map, value), do: is_map(value)
  defp valid_value?(:string, value), do: is_binary(value)
  defp valid_value?(:menu_type, value), do: value in ["workspace", "channel"]
  defp valid_value?(:present, _value), do: true
end
