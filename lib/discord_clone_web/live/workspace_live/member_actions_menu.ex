defmodule DiscordCloneWeb.WorkspaceLive.MemberActionsMenu do
  @moduledoc """
  Shared rendering for member moderation action controls.

  The same set of moderation controls (promote/demote, mute/unmute, timeout
  presets, remove timeout, kick, ban with cleanup windows) is surfaced from two
  places: the member sidebar (`Shell`) and the per-message context menu
  (`ChannelLive.Show`). Both render `menu_items/1` so the control set, DOM ID
  scheme, and emitted events cannot drift apart.

  DOM IDs are derived from the caller-supplied `id_prefix`, e.g.
  `"workspace-member-<user_id>"` for the sidebar and `"message-<message_id>"`
  for a message row. The rendered events (`member_action`, `kick_member`,
  `ban_member`) carry the target `user_id` and are handled identically wherever
  they originate.
  """

  use DiscordCloneWeb, :html

  alias DiscordClone.Workspaces

  attr :id_prefix, :string, required: true
  attr :actions, :list, required: true
  attr :user_id, :string, required: true
  attr :current_scope, :map, required: true
  attr :workspace, :map, required: true
  attr :voice_channel_id, :string, default: nil

  def menu_items(assigns) do
    ~H"""
    <%= for action <- @actions do %>
      <%= cond do %>
        <% action == :voice_disconnect -> %>
          <button
            id={"#{@id_prefix}-voice-disconnect"}
            type="button"
            class="block w-full rounded px-3 py-2 text-left text-xs font-medium text-error transition hover:bg-error/10"
            phx-click="voice_disconnect"
            phx-value-voice_channel_id={@voice_channel_id}
            phx-value-user_id={@user_id}
          >
            Voice Disconnect
          </button>
        <% action == :timeout -> %>
          <div class="border-y border-base-300/70 py-1">
            <p class="px-3 py-1 text-[0.65rem] font-semibold uppercase text-base-content/50">
              Timeout
            </p>
            <button
              :for={{duration, label} <- timeout_duration_presets()}
              id={"#{@id_prefix}-timeout-#{timeout_duration_id(duration)}"}
              type="button"
              class="block w-full rounded px-3 py-2 text-left text-xs font-medium transition hover:bg-base-200"
              phx-click="member_action"
              phx-value-action="timeout"
              phx-value-timeout_duration={duration}
              phx-value-user_id={@user_id}
            >
              {label}
            </button>
          </div>
        <% action == :kick -> %>
          <.form
            for={%{}}
            id={"#{@id_prefix}-kick-form"}
            phx-submit="kick_member"
            class="border-t border-base-300/70 py-1"
          >
            <p class="px-3 py-1 text-[0.65rem] font-semibold uppercase text-error">
              Kick
            </p>
            <input type="hidden" name="user_id" value={@user_id} />
            <input
              type="text"
              name="reason"
              id={"#{@id_prefix}-kick-reason"}
              placeholder="Reason (required)"
              autocomplete="off"
              class="mx-2 mb-1 w-[calc(100%-1rem)] rounded border border-base-300 bg-base-100 px-2 py-1 text-xs outline-none focus:border-primary/40"
            />
            <button
              id={"#{@id_prefix}-kick"}
              type="submit"
              class="block w-full rounded px-3 py-2 text-left text-xs font-medium text-error transition hover:bg-error/10"
              phx-value-user_id={@user_id}
              data-confirm="Kick this member? They lose access immediately but can rejoin with a valid invite."
            >
              Confirm kick
            </button>
          </.form>
        <% action == :ban -> %>
          <.form
            for={%{}}
            id={"#{@id_prefix}-ban-form"}
            phx-submit="ban_member"
            class="border-t border-base-300/70 py-1"
          >
            <p class="px-3 py-1 text-[0.65rem] font-semibold uppercase text-error">
              Ban
            </p>
            <input type="hidden" name="user_id" value={@user_id} />
            <input
              type="text"
              name="reason"
              id={"#{@id_prefix}-ban-reason"}
              placeholder="Reason (required)"
              autocomplete="off"
              class="mx-2 mb-1 w-[calc(100%-1rem)] rounded border border-base-300 bg-base-100 px-2 py-1 text-xs outline-none focus:border-primary/40"
            />
            <fieldset class="mx-2 mb-1 space-y-0.5">
              <legend class="px-1 py-1 text-[0.6rem] font-semibold uppercase text-base-content/50">
                Delete messages
              </legend>
              <label
                :for={{value, label} <- ban_cleanup_window_choices(@current_scope, @workspace)}
                class="flex items-center gap-2 rounded px-1 py-0.5 text-xs font-medium transition hover:bg-base-200"
              >
                <input
                  type="radio"
                  name="cleanup_window"
                  value={value}
                  checked={value == "none"}
                  class="radio radio-xs"
                />
                {label}
              </label>
            </fieldset>
            <button
              id={"#{@id_prefix}-ban"}
              type="submit"
              class="block w-full rounded px-3 py-2 text-left text-xs font-medium text-error transition hover:bg-error/10"
              phx-value-user_id={@user_id}
              data-confirm="Ban this member? They lose access immediately and cannot rejoin via invite."
            >
              Confirm ban
            </button>
          </.form>
        <% true -> %>
          <button
            id={"#{@id_prefix}-#{member_action_id(action)}"}
            type="button"
            class={[
              "block w-full rounded px-3 py-2 text-left text-xs font-medium transition hover:bg-base-200",
              member_action_destructive?(action) && "text-error hover:bg-error/10"
            ]}
            phx-click={member_action_click(action)}
            phx-value-action={action}
            phx-value-user_id={@user_id}
          >
            {member_action_label(action)}
          </button>
      <% end %>
    <% end %>
    """
  end

  defp member_action_id(action) do
    action
    |> Atom.to_string()
    |> String.replace("_", "-")
  end

  defp member_action_label(:promote_to_admin), do: "Promote to admin"
  defp member_action_label(:demote_to_member), do: "Demote to member"
  defp member_action_label(:mute), do: "Mute"
  defp member_action_label(:unmute), do: "Unmute"
  defp member_action_label(:timeout), do: "Timeout"
  defp member_action_label(:remove_timeout), do: "Remove timeout"
  defp member_action_label(:kick), do: "Kick"
  defp member_action_label(:ban), do: "Ban"
  defp member_action_label(:voice_disconnect), do: "Voice Disconnect"
  defp member_action_label(:send_friend_request), do: "Send Friend Request"

  defp member_action_destructive?(action), do: action in [:kick, :ban]

  defp member_action_click(action)
       when action in [
              :promote_to_admin,
              :demote_to_member,
              :mute,
              :unmute,
              :remove_timeout,
              :send_friend_request
            ],
       do: "member_action"

  defp member_action_click(_action), do: nil

  defp timeout_duration_presets do
    [
      {"5_minutes", "5 minutes"},
      {"1_hour", "1 hour"},
      {"24_hours", "24 hours"},
      {"7_days", "7 days"}
    ]
  end

  defp timeout_duration_id(duration), do: String.replace(duration, "_", "-")

  defp ban_cleanup_window_choices(current_scope, workspace) do
    bounded = [
      {"none", "None"},
      {"1_hour", "Last 1 hour"},
      {"24_hours", "Last 24 hours"},
      {"7_days", "Last 7 days"}
    ]

    if Workspaces.can_purge_all_workspace_messages?(current_scope, workspace) do
      bounded ++ [{"all", "All messages"}]
    else
      bounded
    end
  end
end
