defmodule DiscordCloneWeb.ChannelLive.Show do
  use DiscordCloneWeb, :live_view

  alias DiscordClone.{Chat, Workspaces}
  alias DiscordClone.Chat.{Emoji, MentionParser, PresenceEvents}
  alias DiscordCloneWeb.ChannelLive.MessageRows
  alias DiscordCloneWeb.ChannelLive.MessageWindowState
  alias DiscordCloneWeb.ChannelLive.ScrollAnchoring
  alias DiscordCloneWeb.WorkspaceLive.MemberActions
  alias DiscordCloneWeb.WorkspaceLive.MemberActionsMenu
  alias DiscordCloneWeb.WorkspaceLive.Presence
  alias DiscordCloneWeb.WorkspaceLive.EventInputs
  alias DiscordCloneWeb.WorkspaceLive.Shell
  alias DiscordCloneWeb.WorkspaceLive.WorkspaceEvents
  alias DiscordCloneWeb.WorkspaceLive.WorkspaceManagementEvents
  alias DiscordClone.Workspaces.Roles

  @reaction_palette [
    {"👍", "React with 👍 to message"},
    {"❤️", "React with ❤️ to message"},
    {"😂", "React with 😂 to message"},
    {"🎉", "React with 🎉 to message"},
    {"👀", "React with 👀 to message"}
  ]
  @message_highlight_duration_ms 2_400
  @max_mention_suggestions 8
  @active_mention_pattern ~r/(?<![A-Za-z0-9_@])@([A-Za-z0-9_]{0,32})$/u

  @impl true
  def mount(
        %{"workspace_id" => workspace_id, "channel_id" => channel_id} = params,
        _session,
        socket
      ) do
    socket = EventInputs.attach(socket)

    with {:ok, workspace} <-
           Workspaces.fetch_workspace(socket.assigns.current_scope, workspace_id),
         {:ok, channel} <-
           Workspaces.fetch_channel(socket.assigns.current_scope, workspace_id, channel_id),
         :ok <- WorkspaceEvents.subscribe(socket, workspace.id),
         :ok <- subscribe_to_workspace_messages(socket, workspace.id),
         :ok <- subscribe_to_workspace_moderation(socket, workspace.id),
         :ok <- subscribe_to_channel_messages(socket, channel.id),
         :ok <- subscribe_to_channel_reactions(socket, channel.id),
         {:ok, channels} <- Workspaces.list_channels(socket.assigns.current_scope, workspace_id),
         :ok <- subscribe_to_channel_read_states(socket, channels),
         :ok <- subscribe_to_voice_channel_rosters(socket, workspace.id),
         {:ok, workspaces} <- Workspaces.list_workspaces(socket.assigns.current_scope),
         {:ok, voice_channels} <-
           Workspaces.list_voice_channels(socket.assigns.current_scope, workspace_id),
         {:ok, members} <- Workspaces.list_members(socket.assigns.current_scope, workspace_id),
         {:ok, current_member_moderation_state} <-
           current_member_moderation_state(socket, workspace.id),
         {:ok, message_window} <- open_channel_message_window(socket, channel.id, params),
         {:ok, channel_unread_counts} <- load_channel_unread_counts(socket, workspace.id),
         {:ok, selected_channel_read_summary} <-
           load_channel_read_summary(socket, workspace.id, channel.id),
         messages = message_window.messages,
         {:ok, reaction_summaries} <- load_reaction_summaries(socket, messages),
         {:ok, channel_runtime_monitor_ref} <- monitor_channel_runtime(socket, channel.id),
         {:ok, voice_channel_rosters} <-
           Workspaces.list_voice_channel_rosters(socket.assigns.current_scope, workspace_id) do
      message_rows = MessageRows.annotate(messages)

      socket =
        socket
        |> assign(:selected_workspace, workspace)
        |> assign(:selected_channel, channel)
        |> assign(
          :workspace_form,
          WorkspaceManagementEvents.workspace_form(socket.assigns.current_scope)
        )
        |> assign(:show_workspace_form?, false)
        |> assign(:channel_form, channel_form(workspace.id))
        |> assign(:show_channel_form?, false)
        |> assign(:voice_channel_form, voice_channel_form(workspace.id))
        |> assign(:show_voice_channel_form?, false)
        |> assign(:voice_channel_action_menu_id, nil)
        |> assign(:renaming_voice_channel_id, nil)
        |> assign(:voice_channel_rename_form, nil)
        |> assign(:message_form, message_form())
        |> assign(:mention_context, nil)
        |> assign(:mention_suggestion_count, 0)
        |> assign(:mention_active_index, 0)
        |> assign(:mention_active_option_id, nil)
        |> assign(:reply_target, nil)
        |> assign(
          :message_navigation_target_id,
          get_in(message_window, [:navigation_target, :id])
        )
        |> assign(
          :message_navigation_target_token,
          get_in(message_window, [:navigation_target, :token])
        )
        |> assign(:current_member_moderation_state, current_member_moderation_state)
        |> assign(:oldest_message, List.first(messages))
        |> assign(:latest_message, List.last(messages))
        |> assign(:message_window_meta, message_window.meta)
        |> assign(:message_scroll_target, message_window[:scroll_target])
        |> assign(:has_older_messages?, message_window.meta.has_older?)
        |> assign(:loading_older_messages?, false)
        |> assign(:loading_newer_messages?, false)
        |> assign(:workspace_action_menu_id, nil)
        |> assign(:renaming_workspace_id, nil)
        |> assign(:workspace_rename_form, nil)
        |> assign(:channel_action_menu_id, nil)
        |> assign(:renaming_channel_id, nil)
        |> assign(:channel_rename_form, nil)
        |> assign(:context_menu_position, nil)
        |> assign(:typing_user_ids, MapSet.new())
        |> assign(:channel_runtime_monitor_ref, channel_runtime_monitor_ref)
        |> assign(:channel_unread_counts, channel_unread_counts)
        |> assign(:selected_channel_read_summary, selected_channel_read_summary)
        |> assign(:unread_divider_seq, unread_divider_seq(selected_channel_read_summary))
        |> assign(:suppressed_selected_channel_read_state_payloads, MapSet.new())
        |> assign(:reaction_summaries, reaction_summaries)
        |> assign(:member_by_user_id, member_by_user_id(members))
        |> assign(:voice_channel_rosters, voice_channel_rosters)
        |> assign(
          :member_actions_by_user_id,
          member_actions_by_user_id(socket.assigns.current_scope, workspace, members)
        )
        |> assign(:message_rows_by_id, message_rows_by_id(message_rows))
        |> stream_configure(:messages, dom_id: &"message-#{&1.id}")
        |> stream_configure(:mention_suggestions, dom_id: &mention_option_id/1)
        |> stream(:workspaces, workspaces)
        |> stream(:channels, channels)
        |> stream(:voice_channels, voice_channels)
        |> stream(:messages, message_rows)
        |> stream(:mention_suggestions, [])
        |> Presence.prepare_workspace(workspace.id, members)

      {:ok, socket}
    else
      {:error, _reason} ->
        {:ok,
         socket
         |> put_flash(:error, "Channel not found or you do not have access.")
         |> redirect(to: ~p"/workspaces")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <Shell.app
        workspace_stream={@streams.workspaces}
        channel_stream={@streams.channels}
        voice_channel_stream={@streams.voice_channels}
        voice_channel_rosters={@voice_channel_rosters}
        member_by_user_id={@member_by_user_id}
        selected_workspace={@selected_workspace}
        selected_channel={@selected_channel}
        member_stream={@streams.workspace_members}
        workspace_form={@workspace_form}
        show_workspace_form?={@show_workspace_form?}
        channel_form={@channel_form}
        show_channel_form?={@show_channel_form?}
        workspace_action_menu_id={@workspace_action_menu_id}
        renaming_workspace_id={@renaming_workspace_id}
        workspace_rename_form={@workspace_rename_form}
        channel_action_menu_id={@channel_action_menu_id}
        renaming_channel_id={@renaming_channel_id}
        channel_rename_form={@channel_rename_form}
        voice_channel_form={@voice_channel_form}
        show_voice_channel_form?={@show_voice_channel_form?}
        voice_channel_action_menu_id={@voice_channel_action_menu_id}
        renaming_voice_channel_id={@renaming_voice_channel_id}
        voice_channel_rename_form={@voice_channel_rename_form}
        context_menu_position={@context_menu_position}
        current_scope={@current_scope}
        unread_activity_count={@unread_activity_count}
        activity_preview_stream={@streams.activity_preview_items}
        direct_message_unread_count={@direct_message_unread_count}
        main_state={:channel}
        online_user_ids={@online_user_ids}
        channel_unread_counts={@channel_unread_counts}
      >
        <section
          id="channel-message-surface"
          class="flex h-full min-h-0 flex-col bg-base-100"
          aria-label={"Messages in #{@selected_channel.name}"}
        >
          <div
            :if={
              sticky_unread_actions?(
                @channel_unread_counts,
                @selected_channel,
                @unread_divider_seq,
                @message_rows_by_id
              )
            }
            id="selected-channel-unread-actions"
            class="flex flex-wrap items-center justify-center gap-2 border-b border-base-300/60 bg-base-200/55 px-5 py-2.5 text-sm"
          >
            <button
              id="jump-to-oldest-unread"
              type="button"
              phx-click="jump_to_oldest_unread"
              class="rounded bg-base-100 px-3 py-1.5 font-semibold text-base-content/80 shadow-sm ring-1 ring-base-300 transition hover:-translate-y-0.5 hover:text-base-content focus:outline-none focus:ring-2 focus:ring-primary/25"
            >
              Jump to oldest unread
            </button>
            <button
              id="mark-channel-read"
              type="button"
              phx-click="mark_channel_read"
              class="rounded bg-base-100 px-3 py-1.5 font-semibold text-base-content/80 shadow-sm ring-1 ring-base-300 transition hover:-translate-y-0.5 hover:text-base-content focus:outline-none focus:ring-2 focus:ring-primary/25"
            >
              Mark as read
            </button>
            <button
              id="skip-to-latest"
              type="button"
              phx-click="skip_to_latest"
              aria-label="Skip to latest and mark unread messages read"
              class="rounded bg-primary px-3 py-1.5 font-semibold text-primary-content shadow-sm transition hover:-translate-y-0.5 hover:bg-primary/90 focus:outline-none focus:ring-2 focus:ring-primary/25"
            >
              Skip to latest
            </button>
          </div>
          <div
            :if={
              skip_to_latest_action?(@message_window_meta) and
                not sticky_unread_actions?(
                  @channel_unread_counts,
                  @selected_channel,
                  @unread_divider_seq,
                  @message_rows_by_id
                )
            }
            id="selected-channel-latest-actions"
            class="flex justify-center border-b border-base-300/60 bg-base-100/90 px-5 py-2.5 text-sm"
          >
            <button
              id="skip-to-latest"
              type="button"
              phx-click="skip_to_latest"
              aria-label="Skip to latest and mark unread messages read"
              class="rounded bg-primary px-3 py-1.5 font-semibold text-primary-content shadow-sm transition hover:-translate-y-0.5 hover:bg-primary/90 focus:outline-none focus:ring-2 focus:ring-primary/25"
            >
              Skip to latest
            </button>
          </div>
          <div class="relative min-h-0 flex-1">
            <%!-- The empty state is a sibling of (not a child inside) the
            phx-update="stream" container: LiveView does not patch non-stream
            children of a stream container after the first render, so an empty
            state placed inside would linger until a full reload. --%>
            <div
              :if={is_nil(@oldest_message)}
              id="channel-empty-state"
              class="pointer-events-none absolute inset-0 flex items-center justify-center text-center"
            >
              <div>
                <p class="text-lg font-semibold">No messages yet</p>
                <p class="mt-2 text-sm text-base-content/60">
                  This channel is quiet for now.
                </p>
              </div>
            </div>
            <div
              id="older-messages-loading"
              data-loading={to_string(@loading_older_messages?)}
              aria-live="polite"
              class={[
                "pointer-events-none absolute inset-x-0 top-0 z-10 py-2 text-center text-xs font-semibold uppercase tracking-wide text-base-content/45",
                !@loading_older_messages? && "sr-only"
              ]}
            >
              Loading older messages
            </div>
            <div
              id="channel-messages"
              phx-update="stream"
              phx-hook="ChannelMessages"
              data-has-older-messages={to_string(@has_older_messages?)}
              data-has-newer-messages={to_string(@message_window_meta.has_newer?)}
              data-loading-older={to_string(@loading_older_messages?)}
              data-loading-newer={to_string(@loading_newer_messages?)}
              data-scroll-target-kind={ScrollAnchoring.scroll_target_kind(@message_scroll_target)}
              data-scroll-target-seq={ScrollAnchoring.scroll_target_seq(@message_scroll_target)}
              data-scroll-target-token={ScrollAnchoring.scroll_target_token(@message_scroll_target)}
              class="absolute inset-0 scroll-pb-6 overflow-y-auto px-5 py-6 [overflow-anchor:none]"
            >
              <article
                :for={{dom_id, row} <- @streams.messages}
                id={dom_id}
                data-message-row={row_kind(row)}
                data-message-id={row.message.id}
                data-message-seq={row.message.seq}
                data-message-navigation-target={
                  to_string(row.message.id == @message_navigation_target_id)
                }
                data-visible-read-observe="true"
                data-hover-surface="message-row"
                style={message_highlight_style(row.message.id, @message_navigation_target_id)}
                class={[
                  "group relative grid w-full grid-cols-[2.75rem_minmax(0,1fr)] gap-x-3 rounded-md px-3 transition-colors duration-150 hover:bg-base-200/70 focus-within:bg-base-200/70",
                  row.message.id == @message_navigation_target_id && "message-target-highlight",
                  if(row.row_kind == :compact, do: "py-0.5", else: "py-1.5")
                ]}
              >
                <div
                  :if={row.message.seq == @unread_divider_seq}
                  id="channel-unread-divider"
                  data-unread-divider-seq={row.message.seq}
                  class="col-span-2 mb-2 flex items-center gap-3 text-xs font-semibold uppercase tracking-wide text-primary"
                >
                  <span class="h-px flex-1 bg-primary/30"></span>
                  <span
                    id="channel-unread-divider-marker"
                    data-message-id={row.message.id}
                    class="rounded bg-primary/10 px-2 py-1 ring-1 ring-primary/20"
                  >
                    New messages
                  </span>
                  <span class="h-px flex-1 bg-primary/30"></span>
                </div>
                <div
                  :if={row.row_kind == :full}
                  id={"#{dom_id}-avatar"}
                  class="mt-0.5 flex size-10 shrink-0 items-center justify-center rounded-lg bg-primary/15 text-sm font-semibold text-primary ring-1 ring-primary/20 transition group-hover:bg-primary/20"
                  aria-hidden="true"
                >
                  {user_initial(row.message.user)}
                </div>
                <div :if={row.row_kind == :compact} id={"#{dom_id}-spacer"} aria-hidden="true"></div>
                <div id={"#{dom_id}-body"} class="relative min-w-0">
                  <div
                    :if={!message_deleted?(row.message)}
                    id={"#{dom_id}-hover-actions"}
                    class={[
                      "absolute right-0 z-20 flex items-center gap-2",
                      if(row.row_kind == :compact, do: "top-0", else: "top-0.5")
                    ]}
                  >
                    <button
                      id={"#{dom_id}-reply"}
                      type="button"
                      phx-click="begin_reply"
                      phx-value-message-id={row.message.id}
                      class={[
                        "flex size-8 items-center justify-center rounded-lg bg-base-100/95 text-base-content/65 opacity-0 shadow-lg shadow-base-300/20 ring-1 ring-base-content/10 backdrop-blur-sm transition duration-150 hover:bg-base-200 hover:text-base-content group-hover:opacity-100 focus:opacity-100 focus:outline-none focus:ring-2 focus:ring-primary/25"
                      ]}
                      aria-label={"Reply to message from #{row.message.user.username}"}
                      title="Reply"
                    >
                      <.icon name="hero-arrow-uturn-left" class={["size-4"]} />
                    </button>
                    <div
                      id={"#{dom_id}-reaction-palette"}
                      class="pointer-events-none flex items-center gap-0.5 rounded-lg bg-base-100/95 p-1 opacity-0 shadow-lg shadow-base-300/20 ring-1 ring-base-content/10 backdrop-blur-sm transition duration-150 group-hover:pointer-events-auto group-hover:opacity-100"
                      aria-label="Reaction palette"
                    >
                      <button
                        :for={{{emoji, label}, index} <- Enum.with_index(reaction_palette())}
                        id={reaction_option_id(row.message.id, index)}
                        type="button"
                        phx-click="toggle_reaction"
                        phx-value-message-id={row.message.id}
                        phx-value-emoji={emoji}
                        class="flex size-8 items-center justify-center rounded-md text-base leading-none transition hover:bg-base-200 focus:outline-none focus:ring-2 focus:ring-primary/25"
                        aria-label={label}
                        title={label}
                      >
                        <span aria-hidden="true">{emoji}</span>
                      </button>
                    </div>
                    <details
                      :if={
                        message_menu?(
                          row,
                          @member_by_user_id,
                          @member_actions_by_user_id,
                          @current_scope
                        )
                      }
                      id={"#{dom_id}-actions"}
                      phx-hook="MessageActionsMenu"
                      class="relative"
                    >
                      <summary
                        class="btn btn-square btn-sm btn-ghost list-none rounded-lg bg-base-100/95 opacity-0 shadow-lg shadow-base-300/20 ring-1 ring-base-content/10 backdrop-blur-sm transition duration-150 group-hover:opacity-100 [&::-webkit-details-marker]:hidden"
                        aria-label="Open message actions"
                        data-message-menu-summary
                      >
                        <.icon name="hero-ellipsis-horizontal" class="size-4" />
                      </summary>
                      <div
                        data-message-menu-panel
                        class="fixed z-50 w-52 rounded border border-base-300 bg-base-100 p-1 shadow-2xl shadow-base-300/30"
                      >
                        <button
                          :if={
                            Chat.can_delete_message?(@current_scope, row.message, @member_by_user_id)
                          }
                          id={"#{dom_id}-delete"}
                          type="button"
                          class="block w-full rounded px-3 py-2 text-left text-xs font-medium text-error transition hover:bg-error/10"
                          phx-click="delete_message"
                          phx-value-message-id={row.message.id}
                        >
                          Delete message
                        </button>
                        <MemberActionsMenu.menu_items
                          id_prefix={dom_id}
                          actions={message_author_actions(@member_actions_by_user_id, row)}
                          user_id={row.message.user_id}
                          current_scope={@current_scope}
                          workspace={@selected_workspace}
                        />
                      </div>
                    </details>
                  </div>
                  <button
                    :if={
                      !is_nil(row.message.reply_to_message_id) &&
                        !message_deleted?(row.message.reply_to_message)
                    }
                    id={"#{dom_id}-reply-preview"}
                    type="button"
                    phx-click="navigate_reply_parent"
                    phx-value-message-id={row.message.reply_to_message_id}
                    class={[
                      "mb-1.5 flex min-w-0 max-w-full items-center gap-2 border-l-2 border-primary/35 pl-2 text-left text-xs text-base-content/55 transition hover:border-primary hover:text-base-content/75 focus:outline-none focus:ring-2 focus:ring-primary/25"
                    ]}
                    aria-label="Go to replied message"
                  >
                    <span
                      id={"#{dom_id}-reply-preview-author"}
                      class={["shrink-0 font-semibold text-primary/85"]}
                    >
                      {row.message.reply_to_message.user.username}
                    </span>
                    <span
                      id={"#{dom_id}-reply-preview-content"}
                      class={["truncate"]}
                    >
                      {truncate_reply_content(row.message.reply_to_message.content)}
                    </span>
                  </button>
                  <div
                    :if={
                      !is_nil(row.message.reply_to_message_id) &&
                        message_deleted?(row.message.reply_to_message)
                    }
                    id={"#{dom_id}-deleted-reply-preview"}
                    class="mb-1.5 flex min-w-0 items-center gap-2 border-l-2 border-base-content/20 pl-2 text-xs italic text-base-content/45"
                    aria-label="Replied message was deleted"
                  >
                    <.icon name="hero-no-symbol" class="size-3.5 shrink-0" />
                    <span>Message deleted</span>
                  </div>
                  <div
                    :if={row.row_kind == :full}
                    id={"#{dom_id}-header"}
                    class="flex min-h-5 flex-wrap items-baseline gap-2"
                  >
                    <span
                      id={"#{dom_id}-author"}
                      class="text-sm font-semibold leading-5 text-base-content"
                    >
                      {row.message.user.username}
                    </span>
                    <time
                      id={"#{dom_id}-timestamp"}
                      datetime={DateTime.to_iso8601(row.message.inserted_at)}
                      class="text-xs font-medium leading-5 text-base-content/50"
                    >
                      {compact_time(row.message.inserted_at)}
                    </time>
                  </div>
                  {message_content(row, dom_id)}
                  <%= if !message_deleted?(row.message) &&
                          reaction_summaries_for(@reaction_summaries, row.message.id) != [] do %>
                    <div
                      id={"#{dom_id}-reactions"}
                      class="mt-1.5 flex flex-wrap items-center gap-1.5"
                      aria-label="Message reactions"
                    >
                      <span
                        :for={
                          {summary, index} <-
                            Enum.with_index(
                              reaction_summaries_for(@reaction_summaries, row.message.id)
                            )
                        }
                        id={reaction_pill_id(row.message.id, index)}
                        data-current-user-reacted={to_string(summary.reacted?)}
                        class={reaction_pill_class(summary)}
                        aria-label={reaction_pill_label(summary)}
                      >
                        <span aria-hidden="true">{summary.emoji}</span>
                        <span>{summary.count}</span>
                      </span>
                    </div>
                  <% end %>
                </div>
              </article>
            </div>
            <div
              id="newer-messages-loading"
              data-loading={to_string(@loading_newer_messages?)}
              aria-live="polite"
              class={[
                "pointer-events-none absolute inset-x-0 bottom-0 z-10 py-2 text-center text-xs font-semibold uppercase tracking-wide text-base-content/45",
                !@loading_newer_messages? && "sr-only"
              ]}
            >
              Loading newer messages
            </div>
          </div>
          <% typing_members =
            typing_members(@workspace_members, @typing_user_ids, @current_scope.user.id) %>
          <div
            :if={typing_members != []}
            id="channel-typing-indicator"
            class="px-8 py-2 text-xs font-medium text-base-content/60 shadow-[0_-1px_0_rgb(255_255_255/0.035)]"
            aria-live="polite"
          >
            <span
              :for={member <- typing_members}
              data-typing-user-id={member.user.id}
            >
              {member.user.username} is typing...
            </span>
          </div>
          <div
            id="message-composer-panel"
            class="bg-base-100/95 px-5 pb-4 pt-3 shadow-[0_-12px_28px_rgb(0_0_0/0.10),0_-1px_0_rgb(255_255_255/0.04)]"
          >
            <div
              :if={!is_nil(@reply_target)}
              id="message-reply-target"
              data-message-id={@reply_target && @reply_target.id}
              class={[
                "mb-2 flex items-center gap-3 rounded-lg border border-primary/20 bg-primary/5 px-3 py-2 shadow-sm"
              ]}
            >
              <div class={["min-w-0 flex-1"]}>
                <p class={["text-xs text-base-content/55"]}>
                  Replying to
                  <span id="message-reply-target-author" class={["font-semibold text-primary"]}>
                    {@reply_target && @reply_target.user.username}
                  </span>
                </p>
                <p
                  id="message-reply-target-content"
                  class={["mt-0.5 truncate text-sm text-base-content/75"]}
                >
                  {truncate_reply_content(@reply_target && @reply_target.content)}
                </p>
              </div>
              <button
                id="message-reply-target-cancel"
                type="button"
                phx-click="cancel_reply"
                class={[
                  "flex size-8 shrink-0 items-center justify-center rounded-md text-base-content/55 transition hover:bg-base-200 hover:text-base-content focus:outline-none focus:ring-2 focus:ring-primary/25"
                ]}
                aria-label="Cancel reply"
                title="Cancel reply"
              >
                <.icon name="hero-x-mark" class={["size-4"]} />
              </button>
            </div>
            <.form
              for={@message_form}
              id="message-composer-form"
              phx-change="message_typing"
              phx-submit="send_message"
              phx-hook="MessageComposer"
              data-mentions-enabled="true"
              aria-disabled={current_member_participation_blocked?(@current_member_moderation_state)}
              class="flex items-end"
            >
              <div
                id="message-composer-shell"
                class={[
                  "relative min-w-0 flex-1 rounded-lg bg-base-200/80 px-3 py-2 shadow-inner shadow-base-300/30 ring-1 ring-base-300/60 transition focus-within:bg-base-200 focus-within:ring-primary/35"
                ]}
              >
                <div
                  :if={@mention_suggestion_count > 0}
                  id="message-mention-autocomplete"
                  phx-update="stream"
                  role="listbox"
                  aria-label="Mention suggestions"
                  class={[
                    "absolute bottom-full left-0 z-30 mb-2 w-full overflow-hidden rounded-lg border border-base-300 bg-base-100 p-1 shadow-2xl shadow-base-300/30"
                  ]}
                >
                  <button
                    :for={{dom_id, suggestion} <- @streams.mention_suggestions}
                    id={dom_id}
                    type="button"
                    phx-click="select_mention"
                    phx-value-username={suggestion.username}
                    role="option"
                    aria-selected={to_string(suggestion.index == @mention_active_index)}
                    class={[
                      "flex w-full items-center rounded-md px-3 py-2 text-left text-sm transition",
                      if(suggestion.index == @mention_active_index,
                        do: "bg-primary/10 font-semibold text-primary",
                        else: "text-base-content/75 hover:bg-base-200"
                      )
                    ]}
                  >
                    @<span>{suggestion.username}</span>
                  </button>
                </div>
                <.input
                  field={@message_form[:content]}
                  type="textarea"
                  placeholder={"Message ##{@selected_channel.name}"}
                  autocomplete="off"
                  rows="1"
                  role="combobox"
                  aria-autocomplete="list"
                  aria-controls="message-mention-autocomplete"
                  aria-expanded={to_string(@mention_suggestion_count > 0)}
                  aria-activedescendant={@mention_active_option_id}
                  phx-throttle="3000"
                  disabled={current_member_participation_blocked?(@current_member_moderation_state)}
                  class="w-full resize-none appearance-none border-0 bg-transparent px-1 py-2 text-sm leading-5 text-base-content outline-none ring-0 transition placeholder:text-base-content/40 focus:border-0 focus:outline-none focus:ring-0"
                  error_class="textarea-error border-0 ring-0"
                />
              </div>
            </.form>
            <p
              id="message-composer-sending-status"
              class="mt-2 hidden text-right text-xs font-medium text-base-content/65 phx-submit-loading:block"
              role="status"
            >
              Sending…
            </p>
            <p
              :if={current_member_participation_blocked?(@current_member_moderation_state)}
              id="message-composer-muted-feedback"
              class="mt-2 text-xs font-medium text-error"
            >
              {moderation_feedback(@current_member_moderation_state)}
            </p>
          </div>
        </section>
      </Shell.app>
    </Layouts.app>
    """
  end

  @impl true
  def handle_info({:message_created, message}, socket) do
    # A queued creation can already be in the snapshot, possibly deleted.
    # Never replay an older fact over a loaded row or move the latest cursor back.
    if Map.has_key?(socket.assigns.message_rows_by_id, message.id) do
      {:noreply, socket}
    else
      append_created_message(socket, message)
    end
  end

  def handle_info({:message_deleted, payload}, socket) do
    {:noreply, refresh_deleted_message(socket, payload)}
  end

  def handle_info({:clear_message_navigation_target, target_id, token}, socket) do
    if socket.assigns.message_navigation_target_id == target_id and
         socket.assigns.message_navigation_target_token == token do
      socket =
        socket
        |> assign(:message_navigation_target_id, nil)
        |> assign(:message_navigation_target_token, nil)
        |> assign(:message_scroll_target, nil)
        |> restream_message_row(target_id)

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:workspace_message_created, %{workspace_id: workspace_id} = payload}, socket) do
    if socket.assigns.selected_workspace.id == workspace_id do
      {:noreply, refresh_channel_unread_counts_for_message(socket, payload)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:channel_read_state_changed, %{workspace_id: workspace_id} = payload}, socket) do
    if socket.assigns.selected_workspace.id == workspace_id do
      {:noreply, refresh_channel_read_state(socket, payload)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:reaction_changed, %{message_id: message_id}}, socket) do
    {:noreply, refresh_reaction_summary(socket, message_id)}
  end

  def handle_info(
        {:typing_started, %{conversation_id: conversation_id, user_id: user_id}},
        socket
      ) do
    if socket.assigns.selected_channel.id == conversation_id do
      typing_user_ids = MapSet.put(socket.assigns.typing_user_ids, user_id)

      {:noreply,
       socket
       |> assign(:typing_user_ids, typing_user_ids)
       |> monitor_current_channel_runtime()}
    else
      {:noreply, socket}
    end
  end

  def handle_info(
        {:typing_stopped, %{conversation_id: conversation_id, user_id: user_id}},
        socket
      ) do
    if socket.assigns.selected_channel.id == conversation_id do
      typing_user_ids = MapSet.delete(socket.assigns.typing_user_ids, user_id)

      {:noreply, assign(socket, :typing_user_ids, typing_user_ids)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:workspace_moderation_changed, payload}, socket) do
    {:noreply, refresh_workspace_moderation(socket, payload)}
  end

  def handle_info({:workspace_channel_created, %{workspace_id: workspace_id}}, socket) do
    {:noreply,
     WorkspaceEvents.apply_to_selected(
       socket,
       workspace_id,
       &refresh_channel_sidebar(&1, workspace_id)
     )}
  end

  def handle_info({:workspace_voice_channels_changed, %{workspace_id: workspace_id}}, socket) do
    {:noreply,
     WorkspaceEvents.apply_to_selected(
       socket,
       workspace_id,
       &refresh_voice_channel_sidebar(&1, workspace_id)
     )}
  end

  def handle_info(
        {:voice_channel_roster_changed, %{voice_channel_id: voice_channel_id, members: members}},
        socket
      ) do
    socket =
      assign(
        socket,
        :voice_channel_rosters,
        Map.put(socket.assigns.voice_channel_rosters, voice_channel_id, members)
      )

    case Workspaces.fetch_voice_channel(
           socket.assigns.current_scope,
           socket.assigns.selected_workspace.id,
           voice_channel_id
         ) do
      {:ok, voice_channel} -> {:noreply, stream_insert(socket, :voice_channels, voice_channel)}
      {:error, _reason} -> {:noreply, socket}
    end
  end

  def handle_info({:workspace_member_joined, %{workspace_id: workspace_id}}, socket) do
    {:noreply,
     WorkspaceEvents.apply_to_selected(
       socket,
       workspace_id,
       &refresh_workspace_members(&1, workspace_id)
     )}
  end

  def handle_info({:workspace_audit_changed, _payload}, socket) do
    {:noreply, socket}
  end

  def handle_info(
        {:workspace_access_revoked,
         %{workspace_id: workspace_id, target_user_id: target_user_id}},
        socket
      ) do
    cond do
      socket.assigns.selected_workspace.id != workspace_id ->
        {:noreply, socket}

      target_user_id == socket.assigns.current_scope.user.id ->
        {:noreply,
         socket
         |> put_flash(:error, "You were removed from this workspace.")
         |> push_navigate(to: ~p"/workspaces")}

      true ->
        {:noreply, refresh_workspace_moderation(socket, %{workspace_id: workspace_id})}
    end
  end

  def handle_info(
        {:DOWN, monitor_ref, :process, _pid, _reason},
        %{assigns: %{channel_runtime_monitor_ref: monitor_ref}} = socket
      ) do
    {:noreply,
     socket
     |> assign(:typing_user_ids, MapSet.new())
     |> assign(:channel_runtime_monitor_ref, nil)}
  end

  def handle_info(event, socket) do
    case PresenceEvents.to_presence_event(event) do
      {:ok, :user_joined, payload} -> {:noreply, Presence.user_joined(socket, payload)}
      {:ok, :user_left, payload} -> {:noreply, Presence.user_left(socket, payload)}
      :error -> {:noreply, socket}
    end
  end

  @impl true
  def handle_event("show_workspace_form", _params, socket) do
    WorkspaceManagementEvents.show_workspace_form(socket)
  end

  def handle_event("cancel_workspace_form", _params, socket) do
    WorkspaceManagementEvents.cancel_workspace_form(socket)
  end

  def handle_event("create_workspace", params, socket) do
    WorkspaceManagementEvents.create_workspace(socket, params)
  end

  def handle_event("show_channel_form", _params, socket) do
    {:noreply, assign(socket, :show_channel_form?, true)}
  end

  def handle_event("cancel_channel_form", _params, socket) do
    workspace_id = socket.assigns.selected_workspace.id

    {:noreply,
     socket
     |> assign(:show_channel_form?, false)
     |> assign(:channel_form, channel_form(workspace_id))}
  end

  def handle_event(
        "load_older_messages",
        _params,
        %{assigns: %{loading_older_messages?: true}} = socket
      ) do
    {:noreply, socket}
  end

  def handle_event("load_older_messages", _params, %{assigns: %{oldest_message: nil}} = socket) do
    {:noreply,
     socket
     |> assign(:has_older_messages?, false)
     |> assign(:loading_older_messages?, false)}
  end

  def handle_event("load_older_messages", params, socket) do
    if ScrollAnchoring.unstable_scroll_edge_event?(params) do
      {:noreply, assign(socket, :loading_older_messages?, false)}
    else
      load_older_messages(params, socket)
    end
  end

  def handle_event("mention_keydown", %{"key" => "Escape"}, socket) do
    {:noreply, clear_mention_autocomplete(socket)}
  end

  def handle_event("mention_keydown", %{"key" => key}, socket)
      when key in ["ArrowDown", "ArrowUp"] do
    suggestions = current_mention_suggestions(socket)
    suggestion_count = length(suggestions)

    if suggestion_count == 0 do
      {:noreply, socket}
    else
      offset = if key == "ArrowDown", do: 1, else: -1
      active_index = Integer.mod(socket.assigns.mention_active_index + offset, suggestion_count)
      {:noreply, put_mention_suggestions(socket, suggestions, active_index)}
    end
  end

  def handle_event("mention_keydown", %{"key" => "Enter"}, socket) do
    {:noreply, select_active_mention(socket)}
  end

  def handle_event("mention_keydown", _params, socket), do: {:noreply, socket}

  def handle_event("select_mention", %{"username" => username}, socket) do
    suggestion = Enum.find(current_mention_suggestions(socket), &(&1.username == username))
    {:noreply, select_mention(socket, suggestion)}
  end

  def handle_event(
        "load_newer_messages",
        _params,
        %{assigns: %{loading_newer_messages?: true}} = socket
      ) do
    {:noreply, socket}
  end

  def handle_event(
        "load_newer_messages",
        _params,
        %{assigns: %{latest_message: nil}} = socket
      ) do
    {:noreply, assign(socket, :loading_newer_messages?, false)}
  end

  def handle_event("load_newer_messages", params, socket) do
    cond do
      ScrollAnchoring.unstable_scroll_edge_event?(params) ->
        {:noreply, assign(socket, :loading_newer_messages?, false)}

      socket.assigns.message_window_meta.has_newer? ->
        case Chat.load_newer_message_window(
               socket.assigns.current_scope,
               socket.assigns.selected_channel.id,
               socket.assigns.latest_message.seq
             ) do
          {:ok, %{messages: newer_messages, meta: meta}} ->
            socket =
              newer_messages
              |> append_newer_message_rows(socket)
              |> assign(
                :latest_message,
                List.last(newer_messages) || socket.assigns.latest_message
              )
              |> assign(:loading_newer_messages?, false)
              |> assign(
                :message_window_meta,
                MessageWindowState.merge_newer_window_meta(
                  socket.assigns.message_window_meta,
                  meta
                )
              )
              |> MessageWindowState.trim(:older)
              |> ScrollAnchoring.restore_scroll_after_newer_load(params)

            {:noreply, socket}

          {:error, _reason} ->
            {:noreply,
             socket
             |> put_flash(:error, "Channel not found or you do not have access.")
             |> push_navigate(to: ~p"/workspaces")}
        end

      true ->
        {:noreply, assign(socket, :loading_newer_messages?, false)}
    end
  end

  def handle_event("jump_to_oldest_unread", _params, socket) do
    case Chat.jump_to_oldest_unread(
           socket.assigns.current_scope,
           socket.assigns.selected_channel.id
         ) do
      {:ok, message_window} ->
        {:noreply, replace_message_window(socket, message_window)}

      {:error, :no_unread_messages} ->
        {:noreply, refresh_channel_sidebar(socket, socket.assigns.selected_workspace.id)}

      {:error, _reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Channel not found or you do not have access.")
         |> push_navigate(to: ~p"/workspaces")}
    end
  end

  def handle_event("mark_channel_read", _params, socket) do
    case Chat.mark_channel_read(socket.assigns.current_scope, socket.assigns.selected_channel.id) do
      :ok ->
        {:noreply,
         socket
         |> clear_selected_channel_unread_ui()
         |> refresh_channel_sidebar(socket.assigns.selected_workspace.id)}

      {:error, _reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Channel not found or you do not have access.")
         |> push_navigate(to: ~p"/workspaces")}
    end
  end

  def handle_event("mark_sidebar_channel_read", %{"channel_id" => channel_id}, socket) do
    case Chat.mark_channel_read(socket.assigns.current_scope, channel_id) do
      :ok ->
        socket =
          socket
          |> assign(:channel_action_menu_id, nil)
          |> assign(:context_menu_position, nil)
          |> maybe_clear_selected_channel_unread_ui(channel_id)
          |> refresh_channel_sidebar(socket.assigns.selected_workspace.id)

        {:noreply, socket}

      {:error, _reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Channel not found or you do not have access.")
         |> push_navigate(to: ~p"/workspaces")}
    end
  end

  def handle_event("skip_to_latest", _params, socket) do
    case Chat.jump_to_latest(socket.assigns.current_scope, socket.assigns.selected_channel.id) do
      {:ok, message_window} ->
        socket =
          socket
          |> replace_message_window(message_window)
          |> refresh_channel_sidebar(socket.assigns.selected_workspace.id)
          |> push_event("scroll_channel_messages_to_bottom", %{container_id: "channel-messages"})

        {:noreply, socket}

      {:error, _reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Channel not found or you do not have access.")
         |> push_navigate(to: ~p"/workspaces")}
    end
  end

  def handle_event("visible_read_observed", %{"ranges" => ranges}, socket) when is_list(ranges) do
    ranges = parse_visible_read_ranges(ranges)

    socket =
      if valid_visible_read_ranges?(socket, ranges) do
        apply_visible_read_ranges(socket, ranges)
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_event("visible_read_observed", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("scroll_anchor_observed", %{"seq" => seq}, socket) do
    socket =
      with {:ok, seq} <- ScrollAnchoring.parse_integer(seq),
           true <- rendered_message_seq?(socket, seq),
           {:ok, _read_state} <-
             Chat.persist_channel_anchor(
               socket.assigns.current_scope,
               socket.assigns.selected_channel.id,
               seq
             ) do
        socket
      else
        _ignored -> socket
      end

    {:noreply, socket}
  end

  def handle_event("scroll_anchor_observed", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("send_message", %{"message" => message_params}, socket) do
    if blank_message?(message_params) do
      {:noreply, assign(socket, :message_form, to_form(message_params, as: :message))}
    else
      send_message(message_params, socket)
    end
  end

  def handle_event("navigate_reply_parent", %{"message-id" => message_id}, socket) do
    case navigate_to_message_window(socket, socket.assigns.selected_channel.id, message_id) do
      {:ok, %{navigation_target: navigation_target} = message_window} ->
        {:noreply,
         socket
         |> assign(:message_navigation_target_id, navigation_target.id)
         |> assign(:message_navigation_target_token, navigation_target.token)
         |> replace_message_window(message_window, message_window.scroll_target)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "That replied message is no longer available.")}
    end
  end

  def handle_event("begin_reply", %{"message-id" => message_id}, socket) do
    with {:ok, message} <- Chat.fetch_message(socket.assigns.current_scope, message_id),
         true <- message.channel_id == socket.assigns.selected_channel.id,
         false <- message_deleted?(message) do
      {:noreply, assign(socket, :reply_target, message)}
    else
      _invalid_target ->
        {:noreply, put_flash(socket, :error, "That message is no longer available to reply to.")}
    end
  end

  def handle_event("cancel_reply", _params, socket) do
    {:noreply, assign(socket, :reply_target, nil)}
  end

  def handle_event(
        "mention_query",
        %{"before_cursor" => before_cursor, "after_cursor" => after_cursor},
        socket
      )
      when is_binary(before_cursor) and is_binary(after_cursor) do
    case active_mention_context(before_cursor, after_cursor) do
      nil ->
        {:noreply, clear_mention_autocomplete(socket)}

      mention_context ->
        suggestions = mention_suggestions(socket, mention_context.query)

        {:noreply,
         socket
         |> assign(:mention_context, mention_context)
         |> put_mention_suggestions(suggestions)}
    end
  end

  def handle_event("message_typing", %{"message" => %{"content" => content}}, socket)
      when is_binary(content) do
    socket = assign(socket, :message_form, message_form(%{content: content}))

    if String.trim(content) == "" do
      stop_typing(socket)
    else
      start_typing(socket)
    end
  end

  def handle_event("message_typing", _params, socket) do
    start_typing(socket)
  end

  def handle_event("toggle_reaction", %{"message-id" => message_id, "emoji" => emoji}, socket) do
    case Chat.toggle_reaction(socket.assigns.current_scope, message_id, emoji) do
      {:ok, _reaction_or_deleted_reaction} ->
        {:noreply, refresh_reaction_summary(socket, message_id)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Reaction could not be saved.")}

      {:error, _reason, _detail} ->
        {:noreply, put_flash(socket, :error, "Reaction could not be saved.")}
    end
  end

  def handle_event("delete_message", %{"message-id" => message_id}, socket) do
    case Chat.delete_message(socket.assigns.current_scope, message_id) do
      {:ok, _message} ->
        payload = %{
          conversation_id: socket.assigns.selected_channel.id,
          message_id: message_id
        }

        {:noreply, refresh_deleted_message(socket, payload)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Message could not be deleted.")}
    end
  end

  def handle_event(
        "member_action",
        %{"action" => _action, "user_id" => _user_id} = params,
        socket
      ) do
    workspace_id = socket.assigns.selected_workspace.id

    MemberActions.run(socket, params, workspace_id, &refresh_workspace_moderation/2)
  end

  def handle_event("kick_member", %{"user_id" => _user_id} = params, socket) do
    workspace_id = socket.assigns.selected_workspace.id
    MemberActions.kick(socket, params, workspace_id, &refresh_workspace_moderation/2)
  end

  def handle_event("ban_member", %{"user_id" => _user_id} = params, socket) do
    workspace_id = socket.assigns.selected_workspace.id
    MemberActions.ban(socket, params, workspace_id, &refresh_workspace_moderation/2)
  end

  def handle_event("voice_disconnect", params, socket) do
    workspace_id = socket.assigns.selected_workspace.id
    MemberActions.voice_disconnect(socket, params, workspace_id)
  end

  def handle_event("open_workspace_actions", %{"workspace_id" => workspace_id}, socket) do
    {:noreply,
     socket
     |> assign(
       :workspace_action_menu_id,
       toggled_menu_id(socket.assigns.workspace_action_menu_id, workspace_id)
     )
     |> assign(:channel_action_menu_id, nil)
     |> assign(:voice_channel_action_menu_id, nil)
     |> assign(:context_menu_position, nil)
     |> refresh_navigation_sidebars(socket.assigns.selected_workspace.id)}
  end

  def handle_event("begin_workspace_rename", params, socket) do
    WorkspaceManagementEvents.begin_workspace_rename(socket, params)
  end

  def handle_event("rename_workspace", params, socket) do
    WorkspaceManagementEvents.rename_workspace(socket, params)
  end

  def handle_event("delete_workspace", params, socket) do
    WorkspaceManagementEvents.delete_workspace(socket, params)
  end

  def handle_event("leave_workspace", params, socket) do
    WorkspaceManagementEvents.leave_workspace(socket, params)
  end

  def handle_event("open_channel_actions", %{"channel_id" => channel_id}, socket) do
    workspace_id = socket.assigns.selected_workspace.id
    {:ok, channels} = Workspaces.list_channels(socket.assigns.current_scope, workspace_id)

    socket =
      socket
      |> assign(
        :channel_action_menu_id,
        toggled_menu_id(socket.assigns.channel_action_menu_id, channel_id)
      )
      |> assign(:workspace_action_menu_id, nil)
      |> assign(:voice_channel_action_menu_id, nil)
      |> assign(:context_menu_position, nil)
      |> refresh_channel_sidebar(workspace_id, channels)
      |> refresh_voice_channel_sidebar(workspace_id)

    {:noreply, socket}
  end

  def handle_event(
        "open_context_menu",
        %{"type" => "channel", "id" => channel_id, "x" => x, "y" => y},
        socket
      ) do
    workspace_id = socket.assigns.selected_workspace.id
    {:ok, channels} = Workspaces.list_channels(socket.assigns.current_scope, workspace_id)

    socket =
      socket
      |> assign(:channel_action_menu_id, channel_id)
      |> assign(:workspace_action_menu_id, nil)
      |> assign(:voice_channel_action_menu_id, nil)
      |> assign(:context_menu_position, %{
        x: WorkspaceManagementEvents.coordinate_integer(x),
        y: WorkspaceManagementEvents.coordinate_integer(y)
      })
      |> refresh_channel_sidebar(workspace_id, channels)
      |> refresh_voice_channel_sidebar(workspace_id)

    {:noreply, socket}
  end

  def handle_event(
        "open_context_menu",
        %{"type" => "workspace", "id" => workspace_id, "x" => x, "y" => y},
        socket
      ) do
    {:noreply,
     socket
     |> assign(:workspace_action_menu_id, workspace_id)
     |> assign(:channel_action_menu_id, nil)
     |> assign(:voice_channel_action_menu_id, nil)
     |> assign(:context_menu_position, %{
       x: WorkspaceManagementEvents.coordinate_integer(x),
       y: WorkspaceManagementEvents.coordinate_integer(y)
     })
     |> refresh_navigation_sidebars(socket.assigns.selected_workspace.id)}
  end

  def handle_event("close_context_menu", _params, socket) do
    workspace_id = socket.assigns.selected_workspace.id

    socket =
      socket
      |> assign(:workspace_action_menu_id, nil)
      |> assign(:channel_action_menu_id, nil)
      |> assign(:voice_channel_action_menu_id, nil)
      |> assign(:context_menu_position, nil)
      |> refresh_navigation_sidebars(workspace_id)

    {:noreply, socket}
  end

  def handle_event("begin_channel_rename", %{"channel_id" => channel_id}, socket) do
    workspace_id = socket.assigns.selected_workspace.id

    with {:ok, channel} <-
           Workspaces.fetch_channel(socket.assigns.current_scope, workspace_id, channel_id),
         {:ok, channels} <- Workspaces.list_channels(socket.assigns.current_scope, workspace_id) do
      socket =
        socket
        |> assign(:channel_action_menu_id, nil)
        |> assign(:workspace_action_menu_id, nil)
        |> assign(:voice_channel_action_menu_id, nil)
        |> assign(:context_menu_position, nil)
        |> assign(:renaming_channel_id, channel.id)
        |> assign(:channel_rename_form, channel_form(workspace_id, %{name: channel.name}))
        |> refresh_channel_sidebar(workspace_id, channels)
        |> refresh_voice_channel_sidebar(workspace_id)

      {:noreply, socket}
    else
      {:error, _reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Channel could not be renamed.")
         |> push_navigate(to: ~p"/workspaces")}
    end
  end

  def handle_event("create_channel", %{"channel" => channel_params}, socket) do
    workspace_id = socket.assigns.selected_workspace.id

    case Workspaces.create_channel(socket.assigns.current_scope, workspace_id, channel_params) do
      {:ok, channel} ->
        {:ok, channels} = Workspaces.list_channels(socket.assigns.current_scope, workspace_id)

        socket =
          socket
          |> assign(:channel_form, channel_form(workspace_id))
          |> assign(:show_channel_form?, false)
          |> refresh_channel_sidebar(workspace_id, channels)

        {:noreply,
         push_navigate(socket, to: ~p"/workspaces/#{workspace_id}/channels/#{channel.id}")}

      {:error, :invalid_channel, changeset} ->
        {:noreply,
         socket
         |> assign(:show_channel_form?, true)
         |> assign(:channel_form, to_form(changeset, as: :channel, action: :insert))}

      {:error, _reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Channel could not be created.")
         |> push_navigate(to: ~p"/workspaces")}
    end
  end

  def handle_event(
        "rename_channel",
        %{"channel_id" => channel_id, "channel" => channel_params},
        socket
      ) do
    workspace_id = socket.assigns.selected_workspace.id

    case Workspaces.rename_channel(
           socket.assigns.current_scope,
           workspace_id,
           channel_id,
           channel_params
         ) do
      {:ok, channel} ->
        {:ok, channels} = Workspaces.list_channels(socket.assigns.current_scope, workspace_id)

        selected_channel =
          if socket.assigns.selected_channel.id == channel.id,
            do: channel,
            else: socket.assigns.selected_channel

        socket =
          socket
          |> assign(:selected_channel, selected_channel)
          |> assign(:renaming_channel_id, nil)
          |> assign(:channel_rename_form, nil)
          |> assign(:channel_action_menu_id, nil)
          |> refresh_channel_sidebar(workspace_id, channels)

        {:noreply, socket}

      {:error, :invalid_channel, changeset} ->
        {:noreply,
         socket
         |> assign(:renaming_channel_id, channel_id)
         |> assign(:channel_rename_form, to_form(changeset, as: :channel, action: :insert))
         |> assign(:channel_action_menu_id, nil)
         |> refresh_channel_sidebar(workspace_id)}

      {:error, _reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Channel could not be renamed.")
         |> push_navigate(to: ~p"/workspaces")}
    end
  end

  def handle_event("delete_channel", %{"channel_id" => channel_id}, socket) do
    workspace_id = socket.assigns.selected_workspace.id

    deleting_current_channel? =
      socket.assigns.selected_channel.id == channel_id

    case Workspaces.delete_channel(socket.assigns.current_scope, workspace_id, channel_id) do
      {:ok, _channel} when deleting_current_channel? ->
        {:noreply, push_navigate(socket, to: ~p"/workspaces/#{workspace_id}")}

      {:ok, _channel} ->
        {:ok, channels} = Workspaces.list_channels(socket.assigns.current_scope, workspace_id)

        {:noreply,
         socket
         |> assign(:channel_action_menu_id, nil)
         |> refresh_channel_sidebar(workspace_id, channels)}

      {:error, :landing_channel_required} ->
        {:noreply, put_flash(socket, :error, "The landing channel cannot be deleted.")}

      {:error, _reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Channel could not be deleted.")
         |> push_navigate(to: ~p"/workspaces")}
    end
  end

  def handle_event("show_voice_channel_form", _params, socket) do
    {:noreply, assign(socket, :show_voice_channel_form?, true)}
  end

  def handle_event("cancel_voice_channel_form", _params, socket) do
    workspace_id = socket.assigns.selected_workspace.id

    {:noreply,
     socket
     |> assign(:show_voice_channel_form?, false)
     |> assign(:voice_channel_form, voice_channel_form(workspace_id))}
  end

  def handle_event(
        "open_voice_channel_actions",
        %{"voice_channel_id" => voice_channel_id},
        socket
      ) do
    workspace_id = socket.assigns.selected_workspace.id

    {:noreply,
     socket
     |> assign(
       :voice_channel_action_menu_id,
       toggled_menu_id(socket.assigns.voice_channel_action_menu_id, voice_channel_id)
     )
     |> assign(:workspace_action_menu_id, nil)
     |> assign(:channel_action_menu_id, nil)
     |> assign(:context_menu_position, nil)
     |> refresh_navigation_sidebars(workspace_id)}
  end

  def handle_event("close_voice_channel_context_menu", _params, socket) do
    {:noreply,
     socket
     |> assign(:workspace_action_menu_id, nil)
     |> assign(:channel_action_menu_id, nil)
     |> assign(:voice_channel_action_menu_id, nil)
     |> assign(:context_menu_position, nil)
     |> refresh_navigation_sidebars(socket.assigns.selected_workspace.id)}
  end

  def handle_event("create_voice_channel", %{"voice_channel" => params}, socket) do
    workspace_id = socket.assigns.selected_workspace.id

    case Workspaces.create_voice_channel(socket.assigns.current_scope, workspace_id, params) do
      {:ok, _voice_channel} ->
        {:noreply,
         socket
         |> assign(:show_voice_channel_form?, false)
         |> assign(:voice_channel_form, voice_channel_form(workspace_id))
         |> refresh_voice_channel_sidebar(workspace_id)}

      {:error, :invalid_voice_channel, changeset} ->
        {:noreply,
         socket
         |> assign(:show_voice_channel_form?, true)
         |> assign(:voice_channel_form, to_form(changeset, as: :voice_channel, action: :insert))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Voice channel could not be created.")}
    end
  end

  def handle_event(
        "begin_voice_channel_rename",
        %{"voice_channel_id" => voice_channel_id},
        socket
      ) do
    workspace_id = socket.assigns.selected_workspace.id

    case Workspaces.fetch_voice_channel(
           socket.assigns.current_scope,
           workspace_id,
           voice_channel_id
         ) do
      {:ok, voice_channel} ->
        {:noreply,
         socket
         |> assign(:voice_channel_action_menu_id, nil)
         |> assign(:workspace_action_menu_id, nil)
         |> assign(:channel_action_menu_id, nil)
         |> assign(:context_menu_position, nil)
         |> assign(:renaming_voice_channel_id, voice_channel.id)
         |> assign(
           :voice_channel_rename_form,
           voice_channel_form(workspace_id, %{name: voice_channel.name})
         )
         |> refresh_navigation_sidebars(workspace_id)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Voice channel could not be renamed.")}
    end
  end

  def handle_event(
        "rename_voice_channel",
        %{"voice_channel_id" => voice_channel_id, "voice_channel" => params},
        socket
      ) do
    workspace_id = socket.assigns.selected_workspace.id

    case Workspaces.rename_voice_channel(
           socket.assigns.current_scope,
           workspace_id,
           voice_channel_id,
           params
         ) do
      {:ok, _voice_channel} ->
        {:noreply,
         socket
         |> assign(:renaming_voice_channel_id, nil)
         |> assign(:voice_channel_rename_form, nil)
         |> assign(:voice_channel_action_menu_id, nil)
         |> refresh_voice_channel_sidebar(workspace_id)}

      {:error, :invalid_voice_channel, changeset} ->
        {:noreply,
         socket
         |> assign(:renaming_voice_channel_id, voice_channel_id)
         |> assign(
           :voice_channel_rename_form,
           to_form(changeset, as: :voice_channel, action: :insert)
         )}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Voice channel could not be renamed.")}
    end
  end

  def handle_event("delete_voice_channel", %{"voice_channel_id" => voice_channel_id}, socket) do
    workspace_id = socket.assigns.selected_workspace.id

    case Workspaces.delete_voice_channel(
           socket.assigns.current_scope,
           workspace_id,
           voice_channel_id
         ) do
      {:ok, _voice_channel} ->
        {:noreply,
         socket
         |> assign(:voice_channel_action_menu_id, nil)
         |> refresh_voice_channel_sidebar(workspace_id)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Voice channel could not be deleted.")}
    end
  end

  def handle_event(_event, _params, socket) do
    {:noreply, put_flash(socket, :error, "Action could not be completed.")}
  end

  defp append_created_message(socket, message) do
    if MessageWindowState.append_selected_channel_message?(socket) do
      row = MessageRows.annotate_next(socket.assigns.latest_message, message)

      {:noreply,
       socket
       |> assign(:latest_message, message)
       |> ensure_oldest_message(message)
       |> assign(
         :message_window_meta,
         MessageWindowState.latest_window_meta(socket.assigns.message_window_meta, message)
       )
       |> put_message_row(row)
       |> stream_insert(:messages, row)
       |> MessageWindowState.trim(:older)
       |> push_event("scroll_channel_messages_to_bottom", %{container_id: "channel-messages"})}
    else
      {:noreply,
       assign(
         socket,
         :message_window_meta,
         MessageWindowState.newer_available_meta(socket.assigns.message_window_meta, message)
       )}
    end
  end

  defp load_older_messages(params, socket) do
    case Chat.load_older_message_window(
           socket.assigns.current_scope,
           socket.assigns.selected_channel.id,
           socket.assigns.oldest_message.seq
         ) do
      {:ok, %{messages: older_messages, meta: meta}} ->
        socket =
          older_messages
          |> prepend_older_message_rows(socket)
          |> assign(:oldest_message, List.first(older_messages) || socket.assigns.oldest_message)
          |> assign(:loading_older_messages?, false)
          |> assign(
            :message_window_meta,
            MessageWindowState.merge_older_window_meta(socket.assigns.message_window_meta, meta)
          )
          |> assign(:has_older_messages?, meta.has_older?)
          |> MessageWindowState.trim(:newer)
          |> ScrollAnchoring.preserve_scroll_after_older_load(params)

        {:noreply, socket}

      {:error, _reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Channel not found or you do not have access.")
         |> push_navigate(to: ~p"/workspaces")}
    end
  end

  defp channel_form(workspace_id, attrs \\ %{}) do
    workspace_id
    |> Workspaces.change_channel(attrs)
    |> to_form(as: :channel)
  end

  defp message_form(attrs \\ %{}) do
    attrs
    |> Chat.change_message()
    |> to_form(as: :message)
  end

  defp active_mention_context(before_cursor, after_cursor) do
    case Regex.run(@active_mention_pattern, before_cursor, return: :index) do
      [{mention_start, _mention_length}, {query_start, query_length}] ->
        [{0, suffix_length}] =
          Regex.run(~r/^[A-Za-z0-9_]*/u, after_cursor, return: :index, capture: :first)

        if query_length + suffix_length <= 32 do
          %{
            prefix: binary_part(before_cursor, 0, mention_start),
            query: binary_part(before_cursor, query_start, query_length) |> String.downcase(),
            after:
              binary_part(after_cursor, suffix_length, byte_size(after_cursor) - suffix_length)
          }
        end

      nil ->
        nil
    end
  end

  defp mention_suggestions(socket, query) do
    member_suggestions =
      Enum.map(socket.assigns.workspace_members, &%{username: &1.user.username, kind: :user})

    suggestions =
      if can_mention_everyone?(socket) do
        [%{username: "everyone", kind: :everyone} | member_suggestions]
      else
        member_suggestions
      end

    suggestions
    |> Enum.filter(&String.starts_with?(String.downcase(&1.username), query))
    |> Enum.sort_by(&String.downcase(&1.username))
    |> Enum.take(@max_mention_suggestions)
    |> Enum.with_index()
    |> Enum.map(fn {suggestion, index} -> Map.put(suggestion, :index, index) end)
  end

  defp can_mention_everyone?(socket) do
    current_user_id = socket.assigns.current_scope.user.id

    Enum.any?(socket.assigns.workspace_members, fn membership ->
      membership.user_id == current_user_id and
        (Roles.owner?(membership.role) or Roles.admin?(membership.role))
    end)
  end

  defp clear_mention_autocomplete(socket) do
    socket
    |> assign(:mention_context, nil)
    |> put_mention_suggestions([])
  end

  defp select_active_mention(socket) do
    suggestion = Enum.at(current_mention_suggestions(socket), socket.assigns.mention_active_index)
    select_mention(socket, suggestion)
  end

  defp select_mention(socket, nil), do: socket

  defp select_mention(%{assigns: %{mention_context: nil}} = socket, _suggestion), do: socket

  defp select_mention(socket, suggestion) do
    mention_context = socket.assigns.mention_context
    mention = "@#{suggestion.username}"
    before_cursor = mention_context.prefix <> mention <> mention_separator(mention_context.after)
    content = before_cursor <> mention_context.after

    socket
    |> assign(:message_form, message_form(%{content: content}))
    |> clear_mention_autocomplete()
    |> push_event("mention_selected", %{
      input_id: "message_content",
      before_cursor: before_cursor,
      content: content
    })
  end

  defp mention_separator(""), do: " "

  defp mention_separator(after_cursor) do
    if Regex.match?(~r/^[A-Za-z0-9_@]/u, after_cursor), do: " ", else: ""
  end

  defp mention_option_id(suggestion), do: "message-mention-option-#{suggestion.username}"

  defp current_mention_suggestions(%{assigns: %{mention_context: nil}}), do: []

  defp current_mention_suggestions(socket) do
    mention_suggestions(socket, socket.assigns.mention_context.query)
  end

  defp put_mention_suggestions(socket, suggestions, preferred_index \\ 0) do
    active_index = min(preferred_index, max(length(suggestions) - 1, 0))

    active_option_id =
      case Enum.at(suggestions, active_index) do
        nil -> nil
        suggestion -> mention_option_id(suggestion)
      end

    socket
    |> assign(:mention_suggestion_count, length(suggestions))
    |> assign(:mention_active_index, active_index)
    |> assign(:mention_active_option_id, active_option_id)
    |> stream(:mention_suggestions, suggestions, reset: true)
  end

  defp send_message(message_params, socket) do
    message_params = put_reply_target(message_params, socket.assigns.reply_target)

    case Chat.send_message(
           socket.assigns.current_scope,
           socket.assigns.selected_channel.id,
           message_params
         ) do
      {:ok, message} ->
        row = MessageRows.annotate_next(socket.assigns.latest_message, message)

        {:noreply,
         socket
         |> assign(:message_form, message_form())
         |> clear_mention_autocomplete()
         |> assign(:reply_target, nil)
         |> assign(:latest_message, message)
         |> ensure_oldest_message(message)
         |> put_message_row(row)
         |> push_event("clear_message_composer", %{input_id: "message_content"})
         |> push_event("scroll_channel_messages_to_bottom", %{container_id: "channel-messages"})
         |> stream_insert(:messages, row)
         |> MessageWindowState.trim(:older)}

      {:error, :invalid_message, changeset} ->
        {:noreply,
         socket
         |> assign(:message_form, to_form(changeset, as: :message, action: :insert))
         |> recover_invalid_reply_target(changeset)}

      {:error, _reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Channel not found or you do not have access.")
         |> push_navigate(to: ~p"/workspaces")}
    end
  end

  defp put_reply_target(message_params, nil), do: message_params

  defp put_reply_target(message_params, reply_target) do
    Map.put(message_params, "reply_to_message_id", reply_target.id)
  end

  defp recover_invalid_reply_target(%{assigns: %{reply_target: nil}} = socket, _changeset),
    do: socket

  defp recover_invalid_reply_target(socket, changeset) do
    if Keyword.has_key?(changeset.errors, :reply_to_message_id) do
      clear_deleted_reply_target(socket)
    else
      socket
    end
  end

  defp blank_message?(%{"content" => content}) when is_binary(content) do
    String.trim(content) == ""
  end

  defp blank_message?(_message_params), do: false

  defp current_member_moderation_state(socket, workspace_id) do
    Workspaces.member_moderation_state(
      socket.assigns.current_scope,
      workspace_id,
      socket.assigns.current_scope.user.id
    )
  end

  defp current_member_muted?(%{muted?: muted?}), do: muted?
  defp current_member_muted?(_state), do: false

  defp current_member_timed_out?(%{timed_out?: timed_out?}), do: timed_out?
  defp current_member_timed_out?(_state), do: false

  defp current_member_participation_blocked?(state) do
    current_member_muted?(state) or current_member_timed_out?(state)
  end

  defp moderation_feedback(state) do
    cond do
      current_member_muted?(state) ->
        "You are muted in this workspace and cannot send messages or reactions."

      current_member_timed_out?(state) ->
        "You are timed out in this workspace and cannot send messages or reactions."

      true ->
        nil
    end
  end

  defp refresh_workspace_moderation(socket, %{workspace_id: workspace_id} = payload) do
    if socket.assigns.selected_workspace.id == workspace_id do
      with {:ok, members} <- Workspaces.list_members(socket.assigns.current_scope, workspace_id),
           {:ok, moderation_state} <- current_member_moderation_state(socket, workspace_id) do
        socket
        |> assign(:current_member_moderation_state, moderation_state)
        |> assign(:member_by_user_id, member_by_user_id(members))
        |> assign(
          :member_actions_by_user_id,
          member_actions_by_user_id(
            socket.assigns.current_scope,
            socket.assigns.selected_workspace,
            members
          )
        )
        |> Presence.refresh_workspace_members(members)
        |> refresh_mention_suggestions()
        |> restream_author_message_rows(payload)
      else
        _error -> socket
      end
    else
      socket
    end
  end

  defp refresh_workspace_moderation(socket, _payload), do: socket

  # Rows inside the `phx-update="stream"` container only re-render when the
  # stream is touched, so a moderation change that flips an author's menu
  # (mute↔unmute, timeout↔remove_timeout, or losing actions after kick/ban)
  # must re-stream that author's message rows.
  defp restream_author_message_rows(socket, %{target_user_id: target_user_id}) do
    socket.assigns.message_rows_by_id
    |> Map.values()
    |> Enum.filter(&(&1.message.user_id == target_user_id))
    |> Enum.reduce(socket, fn row, socket -> stream_insert(socket, :messages, row) end)
  end

  defp restream_author_message_rows(socket, _payload), do: socket

  defp reaction_summaries_for(reaction_summaries, message_id) do
    Map.get(reaction_summaries, message_id, [])
  end

  defp refresh_reaction_summary(socket, message_id) do
    socket =
      case Chat.list_reaction_summaries(socket.assigns.current_scope, [message_id]) do
        {:ok, %{^message_id => summaries}} ->
          reaction_summaries =
            Map.put(socket.assigns.reaction_summaries, message_id, summaries)

          assign(socket, :reaction_summaries, reaction_summaries)

        {:ok, %{}} ->
          assign(
            socket,
            :reaction_summaries,
            Map.delete(socket.assigns.reaction_summaries, message_id)
          )

        {:error, _reason} ->
          put_flash(socket, :error, "Reaction summary could not be refreshed.")
      end

    restream_message_row(socket, message_id)
  end

  defp refresh_deleted_message(
         socket,
         %{conversation_id: conversation_id, message_id: message_id}
       ) do
    if socket.assigns.selected_channel.id == conversation_id do
      case Chat.fetch_message(socket.assigns.current_scope, message_id) do
        {:ok, message} ->
          socket
          |> assign(
            :reaction_summaries,
            Map.delete(socket.assigns.reaction_summaries, message_id)
          )
          |> maybe_assign_deleted_boundary_message(message)
          |> maybe_refresh_deleted_message_row(message)
          |> refresh_deleted_reply_previews(message)
          |> recover_deleted_reply_target(message)

        {:error, _reason} ->
          socket
      end
    else
      socket
    end
  end

  defp refresh_deleted_message(socket, _payload), do: socket

  defp maybe_refresh_deleted_message_row(socket, message) do
    case Map.fetch(socket.assigns.message_rows_by_id, message.id) do
      {:ok, row} ->
        replace_message_row(socket, row, message)

      :error ->
        socket
    end
  end

  defp refresh_deleted_reply_previews(socket, deleted_message) do
    socket.assigns.message_rows_by_id
    |> Map.values()
    |> Enum.filter(&(&1.message.reply_to_message_id == deleted_message.id))
    |> Enum.reduce(socket, fn row, socket ->
      message = %{row.message | reply_to_message: deleted_message}
      replace_message_row(socket, row, message)
    end)
  end

  defp recover_deleted_reply_target(%{assigns: %{reply_target: %{id: id}}} = socket, %{id: id}) do
    clear_deleted_reply_target(socket)
  end

  defp recover_deleted_reply_target(socket, _deleted_message), do: socket

  defp clear_deleted_reply_target(socket) do
    socket
    |> assign(:reply_target, nil)
    |> put_flash(:error, "Your reply target was deleted. Your draft was preserved.")
  end

  defp replace_message_row(socket, row, message) do
    row = %{row | message: message}

    socket
    |> put_message_row(row)
    |> stream_insert(:messages, row)
  end

  defp maybe_assign_deleted_boundary_message(socket, message) do
    socket
    |> maybe_assign_boundary_message(:oldest_message, message)
    |> maybe_assign_boundary_message(:latest_message, message)
  end

  # A message appended to a previously empty window is that window's only
  # boundary, so it becomes the `oldest_message` too — without this the
  # `is_nil(@oldest_message)` empty state stays rendered after the first message.
  defp ensure_oldest_message(socket, message) do
    case socket.assigns.oldest_message do
      nil -> assign(socket, :oldest_message, message)
      _oldest -> socket
    end
  end

  defp maybe_assign_boundary_message(socket, assign_name, message) do
    case Map.get(socket.assigns, assign_name) do
      %{id: id} when id == message.id -> assign(socket, assign_name, message)
      _other -> socket
    end
  end

  defp reaction_palette, do: @reaction_palette

  defp message_deleted?(%{deleted_at: %DateTime{}}), do: true
  defp message_deleted?(_message), do: false

  defp message_highlight_style(message_id, message_id),
    do: "--message-highlight-duration: #{@message_highlight_duration_ms}ms"

  defp message_highlight_style(_message_id, _target_id), do: nil

  defp truncate_reply_content(nil), do: ""

  defp truncate_reply_content(content) when is_binary(content) do
    if String.length(content) > 96 do
      String.slice(content, 0, 95) <> "…"
    else
      content
    end
  end

  defp member_by_user_id(members), do: Map.new(members, &{&1.user_id, &1})

  defp member_actions_by_user_id(scope, workspace, members) do
    Workspaces.available_member_actions_by_user_id(scope, workspace, members)
  end

  defp message_author_actions(member_actions_by_user_id, %{message: %{user_id: user_id}}) do
    Map.get(member_actions_by_user_id, user_id, [])
  end

  defp message_menu?(row, member_by_user_id, member_actions_by_user_id, current_scope) do
    Chat.can_delete_message?(current_scope, row.message, member_by_user_id) or
      message_author_actions(member_actions_by_user_id, row) != []
  end

  defp reaction_option_id(message_id, index), do: "message-#{message_id}-reaction-option-#{index}"

  defp reaction_pill_id(message_id, index), do: "message-#{message_id}-reaction-#{index}"

  defp reaction_pill_label(%{emoji: emoji, count: count, reacted?: reacted?}) do
    reacted_label = if reacted?, do: "you reacted", else: "you have not reacted"

    "#{emoji} reaction, #{count} #{reaction_count_label(count)}, #{reacted_label}"
  end

  defp reaction_count_label(1), do: "reaction"
  defp reaction_count_label(_count), do: "reactions"

  defp reaction_pill_class(%{reacted?: true}) do
    "inline-flex items-center gap-1 rounded-full border border-primary/35 bg-primary/10 px-2 py-0.5 text-xs font-semibold text-primary shadow-sm transition"
  end

  defp reaction_pill_class(_summary) do
    "inline-flex items-center gap-1 rounded-full border border-base-300 bg-base-200/70 px-2 py-0.5 text-xs font-semibold text-base-content/75 transition"
  end

  defp message_content(row, dom_id) do
    if message_deleted?(row.message) do
      deleted_message_placeholder(dom_id)
    else
      active_message_content(row, dom_id)
    end
  end

  defp active_message_content(row, dom_id) do
    {:safe, attrs} =
      Phoenix.HTML.attributes_escape(
        id: "#{dom_id}-content",
        class: [
          "whitespace-pre-wrap break-words text-sm leading-5 text-base-content/90 [overflow-wrap:anywhere]",
          row.row_kind == :full && "mt-0.5"
        ]
      )

    content =
      render_message_content(
        row.message.content,
        dom_id,
        row.message.mention_recognition
      )

    {:safe, ["<p", attrs, ">", content, "</p>"]}
  end

  defp render_message_content(content, dom_id, recognition) do
    content
    |> Emoji.render_shortcodes()
    |> MentionParser.segments()
    |> Enum.map_reduce(0, fn
      {:text, text}, mention_index ->
        {:safe, escaped_text} = Phoenix.HTML.html_escape(text)
        {escaped_text, mention_index}

      {:mention, kind, source, username}, mention_index ->
        rendered_mention =
          if recognized_mention?(recognition, kind, username) do
            id = "#{dom_id}-mention-#{mention_index}"
            {:safe, span} = mention_span(id, kind, source)
            span
          else
            {:safe, escaped_source} = Phoenix.HTML.html_escape(source)
            escaped_source
          end

        {rendered_mention, mention_index + 1}
    end)
    |> elem(0)
  end

  defp recognized_mention?(recognition, :user, username) do
    username in Map.get(recognition || %{}, "usernames", [])
  end

  defp recognized_mention?(recognition, :everyone, _username) do
    Map.get(recognition || %{}, "everyone", false)
  end

  defp mention_span(id, kind, source) do
    {:safe, attrs} =
      Phoenix.HTML.attributes_escape(
        id: id,
        data_mention_kind: Atom.to_string(kind),
        class: mention_class(kind)
      )

    {:safe, escaped_source} = Phoenix.HTML.html_escape(source)
    {:safe, ["<span", attrs, ">", escaped_source, "</span>"]}
  end

  defp mention_class(:everyone) do
    "rounded bg-amber-300/10 px-0.5 font-semibold text-amber-300 ring-1 ring-amber-300/20"
  end

  defp mention_class(:user) do
    "rounded bg-primary/10 px-0.5 font-semibold text-primary ring-1 ring-primary/20"
  end

  defp deleted_message_placeholder(dom_id) do
    {:safe, attrs} =
      Phoenix.HTML.attributes_escape(
        id: "#{dom_id}-deleted-placeholder",
        class:
          "mt-0.5 rounded bg-base-200/70 px-3 py-2 text-sm italic leading-5 text-base-content/50 ring-1 ring-base-300/60"
      )

    {:safe, ["<p", attrs, ">Message deleted</p>"]}
  end

  defp prepend_older_message_rows([], socket), do: socket

  defp prepend_older_message_rows(older_messages, socket) do
    boundary_row =
      MessageRows.annotate_next(List.last(older_messages), socket.assigns.oldest_message)

    older_rows = MessageRows.annotate(older_messages)

    older_rows
    |> Enum.reverse()
    |> Enum.reduce(put_message_rows(socket, [boundary_row | older_rows]), fn row, socket ->
      stream_insert(socket, :messages, row, at: 0)
    end)
    |> stream_insert(:messages, boundary_row)
  end

  defp append_newer_message_rows([], socket), do: socket

  defp append_newer_message_rows(newer_messages, socket) do
    {newer_rows, _previous_message} =
      Enum.map_reduce(newer_messages, socket.assigns.latest_message, fn message,
                                                                        previous_message ->
        {MessageRows.annotate_next(previous_message, message), message}
      end)

    newer_rows
    |> Enum.reduce(put_message_rows(socket, newer_rows), fn row, socket ->
      stream_insert(socket, :messages, row)
    end)
  end

  defp parse_visible_read_ranges(ranges) do
    Enum.reduce_while(ranges, [], fn
      %{"from_seq" => from_seq, "to_seq" => to_seq}, parsed_ranges ->
        case {ScrollAnchoring.parse_integer(from_seq), ScrollAnchoring.parse_integer(to_seq)} do
          {{:ok, from_seq}, {:ok, to_seq}} ->
            {:cont, [{from_seq, to_seq} | parsed_ranges]}

          _invalid ->
            {:halt, :invalid}
        end

      _invalid, _parsed_ranges ->
        {:halt, :invalid}
    end)
    |> case do
      :invalid -> :invalid
      parsed_ranges -> Enum.reverse(parsed_ranges)
    end
  end

  # Only the web-only concerns live here: that the reported ranges are ordered
  # and non-overlapping, and that every seq they cover is actually rendered in
  # this client's window (something the context cannot know). The numeric bounds
  # — lower bound, size cap, and last-message ceiling — are validated
  # authoritatively by `Chat.subtract_visible_read_range/4`, so they are not
  # re-checked here. `from_seq <= to_seq` is kept as the guard that makes the
  # ascending `from_seq..to_seq` enumeration below meaningful.
  defp valid_visible_read_ranges?(_socket, :invalid), do: false
  defp valid_visible_read_ranges?(_socket, []), do: false

  defp valid_visible_read_ranges?(socket, ranges) do
    rendered_seqs =
      socket
      |> MessageWindowState.visible_message_rows()
      |> MapSet.new(& &1.message.seq)

    ranges_ordered?(ranges) and
      Enum.all?(ranges, fn {from_seq, to_seq} ->
        from_seq <= to_seq and
          Enum.all?(from_seq..to_seq, &MapSet.member?(rendered_seqs, &1))
      end)
  end

  defp rendered_message_seq?(socket, seq) when is_integer(seq) do
    socket
    |> MessageWindowState.visible_message_rows()
    |> Enum.any?(&(&1.message.seq == seq))
  end

  defp ranges_ordered?(ranges) do
    ranges
    |> Enum.reduce_while(nil, fn {from_seq, to_seq}, previous_to_seq ->
      if is_nil(previous_to_seq) or from_seq > previous_to_seq do
        {:cont, to_seq}
      else
        {:halt, false}
      end
    end)
    |> then(&(&1 != false))
  end

  defp apply_visible_read_ranges(socket, ranges) do
    {changed?, suppressed_payloads} =
      Enum.reduce(ranges, {false, []}, fn {from_seq, to_seq}, {changed?, suppressed_payloads} ->
        case Chat.subtract_visible_read_range(
               socket.assigns.current_scope,
               socket.assigns.selected_channel.id,
               from_seq,
               to_seq
             ) do
          {:ok, read_state} ->
            {true, [read_state_payload(socket, read_state) | suppressed_payloads]}

          {:error, _reason} ->
            {changed?, suppressed_payloads}
        end
      end)

    if changed? do
      socket
      |> suppress_selected_channel_read_state_payloads(suppressed_payloads)
      |> clear_selected_channel_unread_ui_if_read()
      |> refresh_channel_sidebar(socket.assigns.selected_workspace.id)
    else
      socket
    end
  end

  defp read_state_payload(socket, read_state) do
    %{
      workspace_id: socket.assigns.selected_workspace.id,
      channel_id: read_state.channel_id,
      unread_count: read_state.unread_count,
      first_unread_seq: read_state.first_unread_seq,
      last_unread_seq: read_state.last_unread_seq
    }
  end

  defp suppress_selected_channel_read_state_payloads(socket, payloads) do
    suppressed_payloads =
      Enum.reduce(payloads, socket.assigns.suppressed_selected_channel_read_state_payloads, fn
        %{channel_id: channel_id} = payload, suppressed_payloads
        when channel_id == socket.assigns.selected_channel.id ->
          MapSet.put(suppressed_payloads, payload)

        _payload, suppressed_payloads ->
          suppressed_payloads
      end)

    assign(socket, :suppressed_selected_channel_read_state_payloads, suppressed_payloads)
  end

  defp replace_message_window(socket, %{messages: messages, meta: meta}) do
    replace_message_window(socket, %{messages: messages, meta: meta}, nil)
  end

  defp replace_message_window(socket, %{messages: messages, meta: meta}, scroll_target) do
    rows = MessageRows.annotate(messages)

    socket =
      if scroll_target do
        assign(socket, :message_scroll_target, scroll_target)
      else
        socket
      end

    socket
    |> assign(:oldest_message, List.first(messages))
    |> assign(:latest_message, List.last(messages))
    |> assign(:message_window_meta, meta)
    |> assign(:has_older_messages?, meta.has_older?)
    |> assign(:loading_older_messages?, false)
    |> assign(:loading_newer_messages?, false)
    |> assign(:reaction_summaries, reaction_summaries_for_window(socket, messages))
    |> assign(:message_rows_by_id, message_rows_by_id(rows))
    |> recalculate_selected_channel_unread_ui()
    |> stream(:messages, rows, reset: true)
  end

  defp reaction_summaries_for_window(socket, messages) do
    message_ids = Enum.map(messages, & &1.id)

    case Chat.list_reaction_summaries(socket.assigns.current_scope, message_ids) do
      {:ok, reaction_summaries} -> reaction_summaries
      {:error, _reason} -> %{}
    end
  end

  defp message_rows_by_id(rows) do
    Map.new(rows, fn row -> {row.message.id, row} end)
  end

  defp put_message_row(socket, row), do: put_message_rows(socket, [row])

  defp put_message_rows(socket, rows) do
    message_rows_by_id = Map.merge(socket.assigns.message_rows_by_id, message_rows_by_id(rows))
    assign(socket, :message_rows_by_id, message_rows_by_id)
  end

  defp restream_message_row(socket, message_id) do
    case Map.fetch(socket.assigns.message_rows_by_id, message_id) do
      {:ok, row} -> stream_insert(socket, :messages, row)
      :error -> socket
    end
  end

  defp restream_visible_message_rows(socket) do
    stream(socket, :messages, MessageWindowState.visible_message_rows(socket), reset: true)
  end

  defp subscribe_to_channel_messages(socket, channel_id) do
    if connected?(socket) do
      Chat.subscribe_to_channel_messages(socket.assigns.current_scope, channel_id)
    else
      :ok
    end
  end

  defp subscribe_to_channel_reactions(socket, channel_id) do
    if connected?(socket) do
      Chat.subscribe_to_channel_reactions(socket.assigns.current_scope, channel_id)
    else
      :ok
    end
  end

  defp subscribe_to_workspace_messages(socket, workspace_id) do
    if connected?(socket) do
      Chat.subscribe_to_workspace_messages(socket.assigns.current_scope, workspace_id)
    else
      :ok
    end
  end

  defp subscribe_to_workspace_moderation(socket, workspace_id) do
    if connected?(socket) do
      Workspaces.subscribe_to_workspace_moderation(socket.assigns.current_scope, workspace_id)
    else
      :ok
    end
  end

  defp monitor_channel_runtime(socket, channel_id) do
    if connected?(socket) do
      case Chat.ensure_channel_runtime(socket.assigns.current_scope, channel_id) do
        {:ok, pid} -> {:ok, Process.monitor(pid)}
        {:error, reason} -> {:error, reason}
      end
    else
      {:ok, nil}
    end
  end

  defp monitor_current_channel_runtime(
         %{assigns: %{channel_runtime_monitor_ref: monitor_ref}} = socket
       )
       when is_reference(monitor_ref) do
    socket
  end

  defp monitor_current_channel_runtime(socket) do
    case Chat.ensure_channel_runtime(
           socket.assigns.current_scope,
           socket.assigns.selected_channel.id
         ) do
      {:ok, pid} -> assign(socket, :channel_runtime_monitor_ref, Process.monitor(pid))
      {:error, _reason} -> socket
    end
  end

  defp open_channel_message_window(
         socket,
         channel_id,
         %{"message_id" => message_id}
       ) do
    if connected?(socket) do
      navigate_to_message_window(socket, channel_id, message_id)
    else
      {:ok, empty_message_window()}
    end
  end

  defp open_channel_message_window(socket, channel_id, _params) do
    if connected?(socket) do
      with {:ok, %{landing: landing}} <-
             Chat.open_channel(socket.assigns.current_scope, channel_id) do
        load_landing_message_window(socket, channel_id, landing)
      end
    else
      {:ok, empty_message_window()}
    end
  end

  defp empty_message_window do
    %{
      messages: [],
      meta: %{
        oldest_seq: nil,
        newest_seq: nil,
        latest_seq: 0,
        has_older?: false,
        has_newer?: false,
        at_latest?: true,
        at_or_near_latest?: true
      }
    }
  end

  defp navigate_to_message_window(socket, channel_id, message_id) do
    with {:ok, %{target: target} = message_window} <-
           Chat.navigate_to_message(socket.assigns.current_scope, channel_id, message_id) do
      token = System.unique_integer([:positive])

      Process.send_after(
        self(),
        {:clear_message_navigation_target, target.id, token},
        @message_highlight_duration_ms
      )

      {:ok,
       message_window
       |> Map.put(:navigation_target, %{id: target.id, token: token})
       |> Map.put(:scroll_target, %{kind: :sequence, seq: target.seq, token: token})}
    end
  end

  defp load_landing_message_window(socket, channel_id, %{type: :latest}) do
    with {:ok, message_window} <-
           Chat.load_latest_message_window(socket.assigns.current_scope, channel_id) do
      {:ok, Map.put(message_window, :scroll_target, %{kind: :latest})}
    end
  end

  defp load_landing_message_window(socket, channel_id, %{type: :sequence, target_seq: target_seq}) do
    with {:ok, message_window} <-
           Chat.load_message_window_around(socket.assigns.current_scope, channel_id, target_seq) do
      {:ok, Map.put(message_window, :scroll_target, %{kind: :sequence, seq: target_seq})}
    end
  end

  defp load_reaction_summaries(socket, messages) do
    if connected?(socket) do
      message_ids = Enum.map(messages, & &1.id)

      Chat.list_reaction_summaries(socket.assigns.current_scope, message_ids)
    else
      {:ok, %{}}
    end
  end

  defp subscribe_to_channel_read_states(socket, channels) do
    if connected?(socket) do
      Enum.reduce_while(channels, :ok, fn channel, :ok ->
        case Chat.subscribe_to_channel_read_state(socket.assigns.current_scope, channel.id) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    else
      :ok
    end
  end

  defp subscribe_to_voice_channel_rosters(socket, workspace_id) do
    if connected?(socket) do
      Workspaces.subscribe_to_voice_channel_rosters(socket.assigns.current_scope, workspace_id)
    else
      :ok
    end
  end

  defp load_channel_unread_counts(socket, workspace_id) do
    if connected?(socket) do
      Chat.list_unread_counts(socket.assigns.current_scope, workspace_id)
    else
      {:ok, %{}}
    end
  end

  defp load_channel_read_summary(socket, workspace_id, channel_id) do
    if connected?(socket) do
      with {:ok, summaries} <-
             Chat.list_channel_read_summaries(socket.assigns.current_scope, workspace_id) do
        {:ok, Enum.find(summaries, &(&1.channel_id == channel_id))}
      end
    else
      {:ok, nil}
    end
  end

  defp unread_divider_seq(%{unread_count: unread_count, first_unread_seq: first_unread_seq})
       when unread_count > 0 do
    first_unread_seq
  end

  defp unread_divider_seq(_summary), do: nil

  defp clear_selected_channel_unread_ui(socket) do
    unread_divider_seq = socket.assigns.unread_divider_seq

    socket
    |> assign(:selected_channel_read_summary, nil)
    |> assign(:unread_divider_seq, nil)
    |> maybe_restream_after_unread_divider_clear(unread_divider_seq)
  end

  defp maybe_restream_after_unread_divider_clear(socket, nil), do: socket

  defp maybe_restream_after_unread_divider_clear(socket, _unread_divider_seq) do
    restream_visible_message_rows(socket)
  end

  defp maybe_clear_selected_channel_unread_ui(socket, channel_id) do
    if socket.assigns.selected_channel.id == channel_id do
      clear_selected_channel_unread_ui(socket)
    else
      socket
    end
  end

  defp clear_selected_channel_unread_ui_if_read(socket) do
    case load_channel_read_summary(
           socket,
           socket.assigns.selected_workspace.id,
           socket.assigns.selected_channel.id
         ) do
      {:ok, nil} ->
        clear_selected_channel_unread_ui(socket)

      {:ok, %{unread_count: 0}} ->
        clear_selected_channel_unread_ui(socket)

      {:ok, _summary} ->
        socket

      {:error, _reason} ->
        socket
    end
  end

  defp recalculate_selected_channel_unread_ui(socket) do
    case load_channel_read_summary(
           socket,
           socket.assigns.selected_workspace.id,
           socket.assigns.selected_channel.id
         ) do
      {:ok, selected_channel_read_summary} ->
        socket
        |> assign(:selected_channel_read_summary, selected_channel_read_summary)
        |> assign(:unread_divider_seq, unread_divider_seq(selected_channel_read_summary))

      {:error, _reason} ->
        socket
    end
  end

  defp refresh_channel_unread_counts_for_message(socket, %{channel_id: channel_id})
       when channel_id == socket.assigns.selected_channel.id do
    refresh_channel_sidebar(socket, socket.assigns.selected_workspace.id)
  end

  defp refresh_channel_unread_counts_for_message(socket, _payload) do
    refresh_channel_sidebar(socket, socket.assigns.selected_workspace.id)
  end

  defp refresh_channel_read_state(socket, %{channel_id: channel_id} = payload) do
    socket
    |> maybe_refresh_selected_channel_read_state(channel_id, payload)
    |> refresh_channel_sidebar(socket.assigns.selected_workspace.id)
  end

  defp maybe_refresh_selected_channel_read_state(socket, channel_id, payload)
       when channel_id == socket.assigns.selected_channel.id do
    if MapSet.member?(socket.assigns.suppressed_selected_channel_read_state_payloads, payload) do
      suppressed_payloads =
        MapSet.delete(socket.assigns.suppressed_selected_channel_read_state_payloads, payload)

      assign(socket, :suppressed_selected_channel_read_state_payloads, suppressed_payloads)
    else
      refresh_selected_channel_read_state(socket, payload)
    end
  end

  defp maybe_refresh_selected_channel_read_state(socket, _channel_id, _payload), do: socket

  defp refresh_selected_channel_read_state(socket, _payload) do
    socket
    |> recalculate_selected_channel_unread_ui()
    |> restream_visible_message_rows()
  end

  defp start_typing(socket) do
    case Chat.user_started_typing(
           socket.assigns.current_scope,
           socket.assigns.selected_channel.id
         ) do
      :ok ->
        {:noreply, socket}

      {:error, _reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Channel not found or you do not have access.")
         |> push_navigate(to: ~p"/workspaces")}
    end
  end

  defp stop_typing(socket) do
    case Chat.user_stopped_typing(
           socket.assigns.current_scope,
           socket.assigns.selected_channel.id
         ) do
      :ok ->
        {:noreply, socket}

      {:error, _reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Channel not found or you do not have access.")
         |> push_navigate(to: ~p"/workspaces")}
    end
  end

  defp refresh_channel_sidebar(socket, workspace_id) do
    {:ok, channels} = Workspaces.list_channels(socket.assigns.current_scope, workspace_id)
    refresh_channel_sidebar(socket, workspace_id, channels)
  end

  defp refresh_channel_sidebar(socket, workspace_id, channels) do
    :ok = subscribe_to_channel_read_states(socket, channels)

    socket =
      case Chat.list_unread_counts(socket.assigns.current_scope, workspace_id) do
        {:ok, channel_unread_counts} ->
          assign(socket, :channel_unread_counts, channel_unread_counts)

        {:error, _reason} ->
          socket
      end

    stream(socket, :channels, channels, reset: true)
  end

  defp refresh_navigation_sidebars(socket, workspace_id) do
    socket
    |> refresh_channel_sidebar(workspace_id)
    |> refresh_voice_channel_sidebar(workspace_id)
  end

  defp refresh_voice_channel_sidebar(socket, workspace_id) do
    with :ok <- subscribe_to_voice_channel_rosters(socket, workspace_id),
         {:ok, voice_channels} <-
           Workspaces.list_voice_channels(socket.assigns.current_scope, workspace_id),
         {:ok, voice_channel_rosters} <-
           Workspaces.list_voice_channel_rosters(socket.assigns.current_scope, workspace_id) do
      socket
      |> assign(:voice_channel_rosters, voice_channel_rosters)
      |> stream(:voice_channels, voice_channels, reset: true)
    else
      _error -> socket
    end
  end

  defp voice_channel_form(workspace_id, attrs \\ %{}) do
    workspace_id |> Workspaces.change_voice_channel(attrs) |> to_form(as: :voice_channel)
  end

  defp refresh_workspace_members(socket, workspace_id) do
    with {:ok, members} <- Workspaces.list_members(socket.assigns.current_scope, workspace_id) do
      socket
      |> assign(:member_by_user_id, member_by_user_id(members))
      |> assign(
        :member_actions_by_user_id,
        member_actions_by_user_id(
          socket.assigns.current_scope,
          socket.assigns.selected_workspace,
          members
        )
      )
      |> Presence.refresh_workspace_members(members)
      |> refresh_voice_channel_sidebar(workspace_id)
      |> refresh_mention_suggestions()
    else
      _error -> socket
    end
  end

  defp refresh_mention_suggestions(%{assigns: %{mention_context: nil}} = socket), do: socket

  defp refresh_mention_suggestions(socket) do
    suggestions = mention_suggestions(socket, socket.assigns.mention_context.query)
    active_index = min(socket.assigns.mention_active_index, max(length(suggestions) - 1, 0))

    put_mention_suggestions(socket, suggestions, active_index)
  end

  defp selected_channel_unread_count(channel_unread_counts, selected_channel) do
    Map.get(channel_unread_counts, selected_channel.id, 0)
  end

  defp sticky_unread_actions?(
         channel_unread_counts,
         selected_channel,
         unread_divider_seq,
         message_rows_by_id
       ) do
    selected_channel_unread_count(channel_unread_counts, selected_channel) > 0 and
      not rendered_unread_divider?(unread_divider_seq, message_rows_by_id)
  end

  defp rendered_unread_divider?(nil, _message_rows_by_id), do: false

  defp rendered_unread_divider?(unread_divider_seq, message_rows_by_id) do
    Enum.any?(message_rows_by_id, fn {_message_id, row} ->
      row.message.seq == unread_divider_seq
    end)
  end

  defp skip_to_latest_action?(%{has_newer?: has_newer?}), do: has_newer?
  defp skip_to_latest_action?(_meta), do: false

  defp toggled_menu_id(menu_id, menu_id), do: nil
  defp toggled_menu_id(_current_menu_id, menu_id), do: menu_id

  defp compact_time(%DateTime{} = datetime), do: Calendar.strftime(datetime, "%H:%M")

  defp row_kind(%{row_kind: row_kind}), do: Atom.to_string(row_kind)

  defp user_initial(%{username: username}) when is_binary(username) do
    username
    |> String.first()
    |> String.upcase()
  end

  defp typing_members(members, typing_user_ids, current_user_id) do
    members
    |> Enum.filter(&MapSet.member?(typing_user_ids, &1.user.id))
    |> Enum.reject(&(&1.user.id == current_user_id))
  end
end
