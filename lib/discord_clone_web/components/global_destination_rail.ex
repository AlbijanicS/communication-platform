defmodule DiscordCloneWeb.GlobalDestinationRail do
  @moduledoc false

  use DiscordCloneWeb, :html

  attr :workspace_stream, :any, required: true
  attr :selected_workspace, :any, default: nil
  attr :workspace_form, :any, default: nil
  attr :show_workspace_form?, :boolean, default: false
  attr :direct_message_unread_count, :integer, default: 0
  attr :unread_activity_count, :integer, default: 0
  attr :activity_preview_stream, :any, default: []

  def rail(assigns) do
    ~H"""
    <div id="global-destination-rail" class="contents">
      <aside
        id="workspace-sidebar"
        aria-label="Global destinations"
        class="flex h-full min-h-0 min-w-0 self-stretch flex-col items-center overflow-x-hidden bg-base-300 p-3 shadow-[inset_-1px_0_0_rgb(255_255_255/0.03)]"
      >
        <.link
          id="global-direct-messages-destination"
          navigate={~p"/direct-messages"}
          aria-label="Direct Messages"
          title="Direct Messages"
          class={[
            "relative flex size-12 shrink-0 items-center justify-center rounded-2xl",
            "bg-primary text-primary-content shadow-sm ring-1 ring-primary/40 transition duration-200",
            "hover:shadow-md focus-visible:outline-none",
            "focus-visible:ring-2 focus-visible:ring-primary focus-visible:ring-offset-2 focus-visible:ring-offset-base-300",
            "phx-click-loading:pointer-events-none phx-click-loading:animate-pulse"
          ]}
        >
          <.icon name="hero-chat-bubble-left-right" class="size-6" />
          <span
            :if={@direct_message_unread_count > 0}
            id="direct-messages-unread-count"
            aria-label={direct_message_unread_label(@direct_message_unread_count)}
            class="absolute -right-1.5 -top-1.5 flex min-w-5 items-center justify-center rounded-full bg-error px-1.5 text-[0.6875rem] font-bold leading-5 text-error-content shadow-sm ring-2 ring-base-300"
          >
            {@direct_message_unread_count}
          </span>
        </.link>

        <div id="activity-preview-anchor" class="group relative shrink-0">
          <.link
            id="global-activity-bell"
            navigate={~p"/activity"}
            class={[
              "relative flex size-12 items-center justify-center rounded-2xl text-base-content/60 transition",
              "hover:bg-base-100 hover:text-base-content focus-visible:bg-base-100",
              "focus-visible:text-base-content focus-visible:outline-none focus-visible:ring-2",
              "focus-visible:ring-primary/60"
            ]}
            aria-label={activity_unread_label(@unread_activity_count)}
            aria-haspopup="dialog"
            aria-controls="activity-preview-popover"
            title="Activity"
          >
            <.icon name="hero-bell" class="size-5" />
            <span
              :if={@unread_activity_count > 0}
              id="global-activity-unread-count"
              class="absolute -right-1.5 -top-1.5 flex min-w-4 items-center justify-center rounded-full bg-primary px-1 text-[0.625rem] font-bold leading-4 text-primary-content shadow-sm ring-2 ring-base-300"
            >
              {@unread_activity_count}
            </span>
          </.link>

          <section
            id="activity-preview-popover"
            role="dialog"
            aria-label="Recent activity"
            class={[
              "invisible pointer-events-none absolute left-[calc(100%+0.75rem)] top-0 z-50",
              "w-96 max-w-[calc(100vw-7rem)] translate-x-1 rounded-2xl border border-base-300",
              "bg-base-100 text-base-content opacity-0 shadow-2xl ring-1 ring-black/10",
              "transition duration-150 ease-out before:absolute before:inset-y-0 before:-left-3 before:w-3",
              "group-hover:visible group-hover:pointer-events-auto group-hover:translate-x-0 group-hover:opacity-100",
              "group-focus-within:visible group-focus-within:pointer-events-auto",
              "group-focus-within:translate-x-0 group-focus-within:opacity-100"
            ]}
          >
            <header class="flex items-center justify-between gap-4 border-b border-base-300 px-4 py-3.5">
              <div class="min-w-0">
                <h2 class="text-sm font-bold tracking-tight">Activity</h2>
                <p class="mt-0.5 text-xs text-base-content/50">
                  {@unread_activity_count} unread in your private feed
                </p>
              </div>
              <.link
                id="activity-preview-view-all"
                navigate={~p"/activity"}
                class="shrink-0 rounded-lg px-2.5 py-1.5 text-xs font-semibold text-primary transition hover:bg-primary/10 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/50"
              >
                View all activity
              </.link>
            </header>

            <div
              id="activity-preview-feed"
              phx-update="stream"
              class="max-h-[28rem] overflow-y-auto overscroll-contain p-2"
            >
              <div
                id="activity-preview-empty-state"
                class="hidden only:flex min-h-36 flex-col items-center justify-center rounded-xl px-5 text-center"
              >
                <div class="flex size-9 items-center justify-center rounded-full bg-success/10 text-success ring-1 ring-success/20">
                  <.icon name="hero-check" class="size-4" />
                </div>
                <p class="mt-3 text-sm font-semibold">You're all caught up</p>
                <p class="mt-1 text-xs leading-5 text-base-content/50">
                  New mentions, Friend updates, and missed Direct Calls will show up here.
                </p>
              </div>

              <article
                :for={{dom_id, activity_item} <- @activity_preview_stream}
                id={dom_id}
                data-read-state={if(activity_item.read_at, do: "read", else: "unread")}
                class="relative rounded-xl transition hover:bg-base-200/80 focus-within:bg-base-200/80"
              >
                <button
                  id={"#{dom_id}-open"}
                  type="button"
                  phx-click="open_activity_preview_item"
                  phx-value-activity-item-id={activity_item.id}
                  aria-label={activity_open_label(activity_item)}
                  class="flex w-full gap-3 rounded-xl px-3 py-3 text-left focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/60"
                >
                  <div class="relative flex size-9 shrink-0 items-center justify-center rounded-lg bg-primary/10 text-sm font-bold text-primary ring-1 ring-primary/15">
                    {activity_actor_initial(activity_item)}
                    <span
                      :if={is_nil(activity_item.read_at)}
                      class="absolute -right-1 -top-1 size-2.5 rounded-full bg-primary ring-2 ring-base-100"
                      aria-label="Unread"
                    >
                    </span>
                  </div>
                  <div class="min-w-0 flex-1">
                    <div class="flex items-start justify-between gap-3">
                      <p class="min-w-0 truncate text-sm font-semibold">
                        {activity_actor_name(activity_item)}
                      </p>
                      <time class="shrink-0 text-[0.6875rem] font-medium text-base-content/40">
                        {activity_preview_time(activity_item.inserted_at)}
                      </time>
                    </div>
                    <p class="mt-0.5 truncate text-xs font-medium text-base-content/55">
                      {activity_context(activity_item)}
                    </p>
                    <p class="mt-1.5 line-clamp-2 break-words text-xs leading-5 text-base-content/75">
                      {activity_preview(activity_item)}
                    </p>
                  </div>
                </button>
              </article>
            </div>
          </section>
        </div>

        <div
          id="voice-lifecycle"
          phx-hook="VoiceLifecycle"
          phx-update="ignore"
          hidden
        >
        </div>

        <div class="h-px w-8 shrink-0 bg-base-content/15" aria-hidden="true"></div>

        <div
          id="workspaces"
          phx-update="stream"
          class="flex min-h-0 w-full flex-1 justify-start gap-2 overflow-x-auto lg:flex-col lg:items-center lg:overflow-y-auto"
        >
          <div id="workspace-empty-state" class="hidden only:block text-sm text-base-content/60">
            Create a workspace to start.
          </div>
          <div :for={{dom_id, workspace} <- @workspace_stream} id={dom_id} class="relative shrink-0">
            <.link
              id={"workspace-#{workspace.id}"}
              navigate={~p"/workspaces/#{workspace.id}"}
              aria-current={selected_workspace_aria(workspace, @selected_workspace)}
              phx-hook={selected_workspace?(workspace, @selected_workspace) && "ContextMenu"}
              title={workspace.name}
              class={[
                "flex size-12 shrink-0 items-center justify-center rounded-2xl text-base font-bold shadow-sm ring-1 transition duration-200",
                "hover:shadow-md",
                selected_workspace?(workspace, @selected_workspace) &&
                  "bg-primary text-primary-content ring-primary",
                !selected_workspace?(workspace, @selected_workspace) &&
                  "bg-base-100 ring-base-300 hover:bg-primary hover:text-primary-content"
              ]}
              data-stream-id={dom_id}
              data-workspace-id={workspace.id}
              data-context-menu-type="workspace"
              data-context-menu-id={workspace.id}
              aria-label={"Open #{workspace.name}"}
            >
              <span aria-hidden="true">{workspace_initial(workspace)}</span>
            </.link>
            <button
              id={"workspace-#{workspace.id}-voice-badge"}
              type="button"
              phx-hook="VoiceWorkspaceBadge"
              phx-update="ignore"
              data-workspace-id={workspace.id}
              aria-label={"Open #{workspace.name} Voice Channel controls"}
              aria-controls="global-voice-connection-panel"
              aria-expanded="false"
              class="absolute -right-1 -top-1 flex size-5 items-center justify-center rounded-full bg-success text-success-content shadow-sm ring-2 ring-base-300 transition hover:scale-110 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-success/60"
              hidden
            >
              <span data-voice-workspace-badge-microphone>
                <.icon name="hero-microphone" class="size-3" />
              </span>
              <span data-voice-workspace-badge-warning class="font-bold" hidden>!</span>
            </button>
          </div>
        </div>

        <button
          :if={@workspace_form && !@show_workspace_form?}
          id="workspace-create-toggle"
          type="button"
          class={[
            "mt-3 inline-flex size-9 shrink-0 items-center justify-center rounded-xl",
            "text-base-content/60 transition duration-150 hover:scale-105 hover:bg-base-100",
            "hover:text-base-content focus-visible:outline-none focus-visible:ring-2",
            "focus-visible:ring-primary/60"
          ]}
          phx-click="show_workspace_form"
          aria-label="Create workspace"
          title="Create workspace"
        >
          <.icon name="hero-plus" class="size-4" />
        </button>

        <.form
          :if={@workspace_form && @show_workspace_form?}
          for={@workspace_form}
          id="workspace-create-form"
          phx-submit="create_workspace"
          class="mt-3 space-y-2"
        >
          <.input
            field={@workspace_form[:name]}
            type="text"
            label="Workspace name"
            placeholder="Design guild"
            autocomplete="off"
          />
          <div class="grid grid-cols-2 gap-2">
            <button
              id="workspace-create-cancel"
              type="button"
              class={[
                "inline-flex h-9 items-center justify-center rounded-lg px-3 text-xs font-semibold",
                "text-base-content/65 transition hover:bg-base-100 hover:text-base-content",
                "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/60"
              ]}
              phx-click="cancel_workspace_form"
            >
              Cancel
            </button>
            <.button
              type="submit"
              class={[
                "inline-flex h-9 items-center justify-center rounded-lg bg-primary px-3",
                "text-xs font-semibold text-primary-content shadow-sm transition",
                "hover:-translate-y-0.5 hover:bg-primary/90 focus-visible:outline-none",
                "focus-visible:ring-2 focus-visible:ring-primary/60"
              ]}
            >
              Create
            </.button>
          </div>
        </.form>
      </aside>
    </div>
    """
  end

  def voice_controls(assigns) do
    ~H"""
    <div id="global-voice-controls" phx-hook="VoiceControls" phx-update="ignore" class="shrink-0">
      <p
        id="global-voice-controls-announcement"
        data-voice-controls-announcement
        role="status"
        aria-live="polite"
        class="sr-only"
      >
      </p>
      <section
        id="global-voice-connection-panel"
        data-voice-controls-panel
        aria-label="Voice Connection Panel"
        hidden
        class="overflow-hidden border-b border-primary/20 bg-base-200 p-3 text-base-content"
      >
        <div class="flex items-center gap-2.5">
          <span class="flex size-8 shrink-0 items-center justify-center rounded-lg bg-primary/15 text-primary ring-1 ring-primary/25">
            <.icon name="hero-microphone" class="size-4" />
          </span>
          <div class="min-w-0">
            <p class="text-[0.625rem] font-bold uppercase tracking-[0.14em] text-base-content/45">
              Voice connected
            </p>
            <p data-voice-controls-channel class="mt-0.5 truncate text-sm font-bold"></p>
          </div>
        </div>
        <p
          id="global-voice-controls-status"
          data-voice-controls-status
          role="status"
          aria-live="polite"
          class="mt-2 truncate text-xs font-medium text-base-content/60"
        >
        </p>
        <div data-voice-controls-local-actions class="mt-3 grid grid-cols-3 gap-1.5">
          <button
            id="global-voice-controls-retry"
            type="button"
            data-voice-controls-retry
            class="btn btn-sm btn-primary col-span-3"
            hidden
          >
            Retry microphone
          </button>
          <button
            id="global-voice-controls-enable-audio"
            type="button"
            data-voice-controls-enable-audio
            class="btn btn-sm btn-primary col-span-3"
            hidden
          >
            Enable audio
          </button>
          <button
            id="global-voice-controls-mute"
            type="button"
            data-voice-controls-mute
            aria-pressed="false"
            class="btn btn-sm btn-ghost border border-base-content/10 bg-base-200/70"
          >
            Mute
          </button>
          <button
            id="global-voice-controls-deafen"
            type="button"
            data-voice-controls-deafen
            aria-pressed="false"
            class="btn btn-sm btn-ghost border border-base-content/10 bg-base-200/70"
          >
            Deafen
          </button>
          <button
            id="global-voice-controls-leave"
            type="button"
            data-voice-controls-leave
            class="btn btn-sm btn-error"
          >
            Leave
          </button>
        </div>
      </section>
    </div>
    """
  end

  defp selected_workspace?(workspace, selected_workspace),
    do: selected_workspace && workspace.id == selected_workspace.id

  defp selected_workspace_aria(workspace, selected_workspace) do
    if selected_workspace?(workspace, selected_workspace), do: "page"
  end

  defp workspace_initial(workspace) do
    workspace.name
    |> String.trim()
    |> String.first()
    |> case do
      nil -> "?"
      initial -> String.upcase(initial)
    end
  end

  defp direct_message_unread_label(1), do: "1 unread Direct Message"
  defp direct_message_unread_label(count), do: "#{count} unread Direct Messages"

  defp activity_unread_label(1), do: "1 unread activity"
  defp activity_unread_label(count), do: "#{count} unread activities"

  defp activity_actor_name(%{actor_user: %{username: username}}), do: username
  defp activity_actor_name(_activity_item), do: "Former member"

  defp activity_actor_initial(activity_item) do
    activity_item
    |> activity_actor_name()
    |> String.first()
    |> String.upcase()
  end

  defp activity_kind_label("user_mention"), do: "Mentioned you"
  defp activity_kind_label("everyone_mention"), do: "Mentioned everyone"
  defp activity_kind_label("friend_request_received"), do: "Sent you a Friend Request"
  defp activity_kind_label("friend_request_accepted"), do: "Accepted your Friend Request"
  defp activity_kind_label("direct_message"), do: "Sent you a Direct Message"
  defp activity_kind_label("missed_direct_call"), do: "Missed a Direct Call"
  defp activity_kind_label(_kind), do: "New activity"

  defp activity_context(
         %{workspace: %{name: workspace_name}, source_channel: %{name: name}} = item
       ),
       do: "#{activity_kind_label(item.kind)} in #{workspace_name} / ##{name}"

  defp activity_context(item), do: activity_kind_label(item.kind)

  defp activity_preview(%{source_message: %{content: content}}), do: content
  defp activity_preview(%{kind: "friend_request_received"}), do: "Review your incoming requests."
  defp activity_preview(%{kind: "friend_request_accepted"}), do: "Your Friendship is now active."
  defp activity_preview(%{kind: "missed_direct_call"}), do: "This Direct Call was missed."
  defp activity_preview(_activity_item), do: "Open this activity for details."

  defp activity_open_label(%{source_channel: %{name: name}}), do: "Open activity in ##{name}"
  defp activity_open_label(%{kind: "direct_message"}), do: "Open Direct Message activity"
  defp activity_open_label(%{kind: "missed_direct_call"}), do: "Open missed Direct Call activity"
  defp activity_open_label(_activity_item), do: "Open Friend relationship activity"

  defp activity_preview_time(%DateTime{} = datetime),
    do: Calendar.strftime(datetime, "%b %-d, %H:%M")
end
