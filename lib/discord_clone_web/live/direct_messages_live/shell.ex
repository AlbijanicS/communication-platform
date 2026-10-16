defmodule DiscordCloneWeb.DirectMessagesLive.Shell do
  @moduledoc false

  use DiscordCloneWeb, :html

  alias DiscordCloneWeb.GlobalDestinationRail

  attr :workspace_stream, :any, required: true
  attr :conversation_stream, :any, required: true
  attr :incoming_request_count, :integer, default: 0
  attr :direct_message_unread_count, :integer, default: 0
  attr :workspace_form, :any, default: nil
  attr :show_workspace_form?, :boolean, default: false
  attr :unread_activity_count, :integer, default: 0
  attr :activity_preview_stream, :any, default: []
  attr :current_scope, :any, default: nil
  attr :current_action, :atom, default: :conversation
  attr :selected_conversation_id, :string, default: nil

  slot :member_panel
  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div id="direct-messages-app-shell" class={direct_messages_shell_class(@member_panel != [])}>
      <GlobalDestinationRail.rail
        workspace_stream={@workspace_stream}
        workspace_form={@workspace_form}
        show_workspace_form?={@show_workspace_form?}
        direct_message_unread_count={@direct_message_unread_count}
        unread_activity_count={@unread_activity_count}
        activity_preview_stream={@activity_preview_stream}
      />

      <aside
        id="direct-messages-sidebar"
        aria-label="Direct Messages navigation"
        class="flex min-h-0 flex-col border-b border-base-300/60 bg-base-200/70 lg:border-b-0 lg:border-r"
      >
        <nav class="space-y-1 border-b border-base-300/70 p-4" aria-label="Friends">
          <.link
            id="direct-messages-friends-link"
            navigate={~p"/direct-messages"}
            aria-current={if(@current_action == :friends, do: "page")}
            class={[
              navigation_class(@current_action == :friends),
              "phx-click-loading:pointer-events-none phx-click-loading:animate-pulse"
            ]}
          >
            <.icon name="hero-user-group" class="size-5" />
            <span class="flex-1">Friends</span>
          </.link>
          <.link
            id="direct-messages-requests-link"
            navigate={~p"/direct-messages/requests"}
            aria-current={if(@current_action == :requests, do: "page")}
            class={[
              navigation_class(@current_action == :requests),
              "phx-click-loading:pointer-events-none phx-click-loading:animate-pulse"
            ]}
          >
            <.icon name="hero-user-plus" class="size-5" />
            <span class="flex-1">Requests</span>
            <span
              :if={@incoming_request_count > 0}
              id="direct-messages-request-count"
              aria-label={request_count_label(@incoming_request_count)}
              class="min-w-5 rounded-full bg-primary px-1.5 py-0.5 text-center text-[0.6875rem] font-bold leading-4 text-primary-content"
            >
              {@incoming_request_count}
            </span>
          </.link>
        </nav>

        <div class="flex min-h-0 flex-1 flex-col px-4 pb-4 pt-5">
          <div class="mb-3 flex items-center justify-between px-2">
            <h2 class="text-xs font-bold uppercase tracking-[0.16em] text-base-content/50">
              Direct Conversations
            </h2>
            <.icon name="hero-chat-bubble-left-right" class="size-4 text-base-content/40" />
          </div>

          <div
            id="direct-conversations"
            phx-update="stream"
            class="min-h-0 flex-1 space-y-1.5 overflow-y-auto"
          >
            <div
              id="direct-conversations-empty"
              class="hidden only:flex min-h-32 flex-col items-center justify-center rounded-2xl px-4 text-center text-xs leading-5 text-base-content/45"
            >
              <.icon name="hero-chat-bubble-oval-left-ellipsis" class="mb-2 size-6" />
              Message a Friend to start a Direct Conversation.
            </div>

            <.link
              :for={{dom_id, destination} <- @conversation_stream}
              id={dom_id}
              navigate={~p"/direct-messages/#{destination.direct_conversation.id}"}
              data-conversation-id={destination.direct_conversation.id}
              data-writable={to_string(destination.writable?)}
              aria-current={
                if(@selected_conversation_id == destination.direct_conversation.id, do: "page")
              }
              class={[
                "group flex items-center gap-3 rounded-xl px-3 py-2.5 transition duration-150",
                "phx-click-loading:pointer-events-none phx-click-loading:animate-pulse",
                @selected_conversation_id == destination.direct_conversation.id &&
                  "bg-base-300 text-base-content",
                @selected_conversation_id != destination.direct_conversation.id &&
                  "text-base-content/70 hover:bg-base-300/75 hover:text-base-content",
                "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/60"
              ]}
            >
              <span class="flex size-10 shrink-0 items-center justify-center rounded-xl bg-primary/10 text-sm font-bold text-primary ring-1 ring-primary/15">
                {participant_initial(destination.other_participant)}
              </span>
              <span class="min-w-0 flex-1">
                <span class="block truncate text-sm font-semibold">
                  {destination.other_participant.username}
                </span>
                <span
                  :if={!destination.writable?}
                  id={"direct-conversation-read-only-#{destination.direct_conversation.id}"}
                  class="block truncate text-[0.6875rem] text-base-content/45"
                >
                  Read-only · Former Friend
                </span>
                <span
                  :if={is_nil(destination.latest_message_at)}
                  id={"direct-conversation-empty-label-#{destination.direct_conversation.id}"}
                  class="block truncate text-[0.6875rem] text-base-content/45"
                >
                  Empty Conversation
                </span>
              </span>
              <span
                :if={destination.unread_count > 0}
                id={"direct-conversation-unread-#{destination.direct_conversation.id}"}
                aria-label={conversation_unread_label(destination)}
                class="min-w-5 rounded-full bg-primary px-1.5 py-0.5 text-center text-[0.6875rem] font-bold leading-4 text-primary-content"
              >
                {destination.unread_count}
              </span>
            </.link>
          </div>
        </div>

        <GlobalDestinationRail.voice_controls />

        <div
          :if={@current_scope && @current_scope.user}
          id="direct-messages-current-user"
          class="bg-base-300/70 p-3 shadow-[inset_0_1px_0_rgb(255_255_255/0.04)]"
        >
          <div class="flex items-center gap-3">
            <div class="flex size-9 shrink-0 items-center justify-center rounded bg-primary text-sm font-semibold text-primary-content">
              {user_initial(@current_scope.user)}
            </div>
            <div class="min-w-0 flex-1">
              <p class="truncate text-sm font-semibold">{@current_scope.user.username}</p>
              <p class="truncate text-xs text-base-content/50">{@current_scope.user.email}</p>
            </div>
            <.link
              id="direct-messages-settings-link"
              navigate={~p"/users/settings"}
              class="btn btn-square btn-xs btn-ghost"
              aria-label="Settings"
            >
              <.icon name="hero-cog-6-tooth" class="size-4" />
            </.link>
            <.link
              href={~p"/users/log-out"}
              method="delete"
              data-voice-logout
              class="btn btn-square btn-xs btn-ghost"
              aria-label="Log out"
            >
              <.icon name="hero-arrow-right-on-rectangle" class="size-4" />
            </.link>
          </div>
        </div>
      </aside>

      <main id="direct-messages-main" class="min-h-0 min-w-0 overflow-hidden bg-base-100">
        {render_slot(@inner_block)}
      </main>

      {render_slot(@member_panel)}
    </div>
    """
  end

  defp navigation_class(selected?) do
    [
      "flex items-center gap-3 rounded-xl px-3 py-2.5 text-sm font-semibold transition",
      "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/60",
      selected? && "bg-base-300 text-base-content",
      !selected? && "text-base-content/65 hover:bg-base-300/75 hover:text-base-content"
    ]
  end

  defp direct_messages_shell_class(true),
    do:
      "fixed inset-0 grid min-h-screen grid-cols-1 grid-rows-[auto_minmax(12rem,36vh)_minmax(0,1fr)] overflow-hidden bg-base-100 lg:grid-cols-[var(--app-rail-width)_var(--app-sidebar-width)_minmax(0,1fr)] lg:grid-rows-1 xl:grid-cols-[var(--app-rail-width)_var(--app-sidebar-width)_minmax(0,1fr)_var(--app-member-panel-width)]"

  defp direct_messages_shell_class(false),
    do:
      "fixed inset-0 grid min-h-screen grid-cols-1 grid-rows-[auto_minmax(12rem,36vh)_minmax(0,1fr)] overflow-hidden bg-base-100 lg:grid-cols-[var(--app-rail-width)_var(--app-sidebar-width)_minmax(0,1fr)] lg:grid-rows-1"

  defp participant_initial(user) do
    user.username |> String.first() |> String.upcase()
  end

  defp user_initial(user) do
    user.username |> String.first() |> String.upcase()
  end

  defp request_count_label(1), do: "1 incoming Friend Request"
  defp request_count_label(count), do: "#{count} incoming Friend Requests"

  defp conversation_unread_label(destination) do
    count = destination.unread_count

    "#{count} unread #{if(count == 1, do: "message", else: "messages")} with #{destination.other_participant.username}"
  end
end
