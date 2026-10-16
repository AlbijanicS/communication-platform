defmodule DiscordCloneWeb.DirectConversationLive do
  @moduledoc false

  use DiscordCloneWeb, :live_view

  alias DiscordClone.{Calls, Chat, Friendships, Presence, Workspaces}
  alias DiscordCloneWeb.ChannelLive.MessageRows
  alias DiscordCloneWeb.ChannelLive.ScrollAnchoring
  alias DiscordCloneWeb.DirectMessagesLive.Shell, as: DirectMessagesShell
  alias DiscordCloneWeb.WorkspaceLive.WorkspaceManagementEvents

  @reaction_palette ["👍", "❤️", "😂", "🎉", "👀"]
  @rendered_message_limit 300
  @visible_read_range_limit 50

  @impl true
  def mount(%{"direct_conversation_id" => direct_conversation_id} = params, _session, socket) do
    with {:ok, destination} <-
           Chat.get_direct_conversation(socket.assigns.current_scope, direct_conversation_id),
         :ok <- subscribe_to_messages(socket, direct_conversation_id),
         {:ok, message_window} <- open_message_window(socket, direct_conversation_id, params),
         messages = message_window.messages,
         {:ok, reaction_summaries} <-
           Chat.list_reaction_summaries(socket.assigns.current_scope, Enum.map(messages, & &1.id)),
         {:ok, runtime_monitor_ref} <- monitor_runtime(socket, direct_conversation_id),
         {:ok, typing_user_ids} <- list_typing_user_ids(socket, direct_conversation_id),
         {:ok, destinations} <-
           Chat.list_direct_conversation_destinations(socket.assigns.current_scope),
         {:ok, workspaces} <- Workspaces.list_workspaces(socket.assigns.current_scope) do
      writable? = destination_writable?(destinations, direct_conversation_id)

      presence_status =
        friend_presence_status(socket, destination.other_participant.id, writable?)

      {:ok,
       socket
       |> assign(:direct_conversation, destination.direct_conversation)
       |> assign(:other_participant, destination.other_participant)
       |> assign(:message_form, message_form())
       |> assign(:reply_target, nil)
       |> assign(:reaction_summaries, reaction_summaries)
       |> assign(:writable?, writable?)
       |> assign(
         :call_capabilities,
         Calls.browser_media_capabilities(socket.assigns.current_scope)
       )
       |> assign_friendship_recovery_state(writable?)
       |> assign(:friend_presence_status, presence_status)
       |> assign(:direct_messages_empty?, messages == [])
       |> assign(:direct_messages_by_id, messages_by_id(messages))
       |> assign(:direct_message_row_kinds, direct_message_row_kinds(messages))
       |> assign(
         :workspace_form,
         WorkspaceManagementEvents.workspace_form(socket.assigns.current_scope)
       )
       |> assign(:show_workspace_form?, false)
       |> assign(:oldest_message, List.first(messages))
       |> assign(:latest_message, List.last(messages))
       |> assign(:message_window_meta, message_window.meta)
       |> assign(:loading_older_messages?, false)
       |> assign(:loading_newer_messages?, false)
       |> assign(:message_navigation_target_id, get_in(message_window, [:target, :id]))
       |> assign(:message_scroll_target, message_window[:scroll_target])
       |> assign(:typing_user_ids, MapSet.new(typing_user_ids))
       |> assign(:runtime_monitor_ref, runtime_monitor_ref)
       |> stream(:workspaces, workspaces)
       |> stream_configure(:direct_messages, dom_id: &"direct-message-#{&1.id}")
       |> stream(:direct_messages, messages)}
    else
      {:error, _reason} ->
        {:ok,
         socket
         |> put_flash(:error, "Direct Conversation not found.")
         |> push_navigate(to: ~p"/friends")}
    end
  end

  @impl true
  def handle_event(
        "load_older_messages",
        _params,
        %{assigns: %{loading_older_messages?: true}} = socket
      ) do
    {:noreply, socket}
  end

  def handle_event("load_older_messages", _params, %{assigns: %{oldest_message: nil}} = socket) do
    {:noreply, assign(socket, :loading_older_messages?, false)}
  end

  def handle_event("load_older_messages", params, socket) do
    if ScrollAnchoring.unstable_scroll_edge_event?(params) do
      {:noreply, assign(socket, :loading_older_messages?, false)}
    else
      case Chat.load_older_direct_message_window(
             socket.assigns.current_scope,
             socket.assigns.direct_conversation.id,
             socket.assigns.oldest_message.seq
           ) do
        {:ok, window} ->
          {:noreply,
           socket
           |> merge_message_window(window, :older)
           |> ScrollAnchoring.preserve_scroll_after_older_load(params)}

        {:error, _reason} ->
          {:noreply, direct_conversation_unavailable(socket)}
      end
    end
  end

  def handle_event(
        "load_newer_messages",
        _params,
        %{assigns: %{loading_newer_messages?: true}} = socket
      ) do
    {:noreply, socket}
  end

  def handle_event("load_newer_messages", _params, %{assigns: %{latest_message: nil}} = socket) do
    {:noreply, assign(socket, :loading_newer_messages?, false)}
  end

  def handle_event("load_newer_messages", params, socket) do
    cond do
      ScrollAnchoring.unstable_scroll_edge_event?(params) ->
        {:noreply, assign(socket, :loading_newer_messages?, false)}

      socket.assigns.message_window_meta.has_newer? ->
        case Chat.load_newer_direct_message_window(
               socket.assigns.current_scope,
               socket.assigns.direct_conversation.id,
               socket.assigns.latest_message.seq
             ) do
          {:ok, window} ->
            {:noreply,
             socket
             |> merge_message_window(window, :newer)
             |> ScrollAnchoring.restore_scroll_after_newer_load(params)}

          {:error, _reason} ->
            {:noreply, direct_conversation_unavailable(socket)}
        end

      true ->
        {:noreply, assign(socket, :loading_newer_messages?, false)}
    end
  end

  # The shared message-history hook emits this event for every Conversation kind.
  # Direct Conversations do not persist scroll anchors here.
  def handle_event("scroll_anchor_observed", _params, socket), do: {:noreply, socket}

  # Direct Messages do not recognize Workspace mentions, but safely ignore a
  # stale or forged query from the shared composer instead of crashing.
  def handle_event("mention_query", _params, socket), do: {:noreply, socket}

  def handle_event("show_workspace_form", _params, socket),
    do: WorkspaceManagementEvents.show_workspace_form(socket)

  def handle_event("cancel_workspace_form", _params, socket),
    do: WorkspaceManagementEvents.cancel_workspace_form(socket)

  def handle_event("create_workspace", %{"workspace" => workspace_params}, socket),
    do: WorkspaceManagementEvents.create_workspace(socket, %{"workspace" => workspace_params})

  def handle_event("visible_read_observed", %{"ranges" => ranges}, socket)
      when is_list(ranges) do
    ranges = parse_visible_read_ranges(ranges)

    if valid_visible_read_ranges?(socket, ranges) do
      Enum.each(ranges, fn {from_seq, to_seq} ->
        _result =
          Chat.mark_direct_messages_visible(
            socket.assigns.current_scope,
            socket.assigns.direct_conversation.id,
            from_seq,
            to_seq
          )
      end)
    end

    {:noreply, socket}
  end

  def handle_event("visible_read_observed", _params, socket), do: {:noreply, socket}

  def handle_event("navigate_direct_message", %{"message-id" => message_id}, socket) do
    case navigate_to_message_window(socket, message_id) do
      {:ok, window} -> {:noreply, replace_message_window(socket, window)}
      {:error, _reason} -> {:noreply, put_flash(socket, :error, "That message is unavailable.")}
    end
  end

  def handle_event("message_typing", %{"message" => %{"content" => content}}, socket) do
    socket = assign(socket, :message_form, to_form(%{"content" => content}, as: :message))

    if String.trim(content) == "" do
      stop_typing(socket)
    else
      start_typing(socket)
    end
  end

  def handle_event("message_typing", _params, socket), do: start_typing(socket)

  def handle_event("send_friend_request", _params, %{assigns: %{writable?: true}} = socket) do
    {:noreply, socket}
  end

  def handle_event("send_friend_request", _params, socket) do
    case Friendships.send_friend_request(socket.assigns.current_scope, %{
           username: socket.assigns.other_participant.username
         }) do
      {:ok, %{relationship: %{status: :accepted}}} ->
        {:noreply,
         socket
         |> put_flash(:info, "Friendship restored. You can send Direct Messages again.")
         |> refresh_writable_capability()}

      {:ok, %{relationship: %{status: :pending}}} ->
        {:noreply,
         socket
         |> assign(:friendship_recovery_state, :outgoing_request)
         |> put_flash(:info, "Friend Request sent.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Friend Request could not be sent.")}
    end
  end

  def handle_event("send_direct_message", %{"message" => message_params}, socket) do
    if blank_direct_message?(message_params) do
      {:noreply, assign(socket, :message_form, to_form(message_params, as: :message))}
    else
      message_params = put_reply_target(message_params, socket.assigns.reply_target)

      case Chat.send_direct_message(
             socket.assigns.current_scope,
             socket.assigns.direct_conversation.id,
             message_params
           ) do
        {:ok, _message} ->
          {:noreply,
           socket
           |> assign(:message_form, message_form())
           |> assign(:reply_target, nil)}

        {:error, :invalid_message, changeset} ->
          {:noreply,
           socket
           |> assign(:message_form, to_form(changeset, as: :message, action: :insert))
           |> recover_invalid_reply_target(changeset)}

        {:error, :not_friends} ->
          {:noreply, put_flash(socket, :error, "You can only message current Friends.")}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, "Direct Message could not be sent.")}
      end
    end
  end

  def handle_event("begin_direct_reply", %{"message-id" => message_id}, socket) do
    with true <- socket.assigns.writable?,
         {:ok, message} <-
           Chat.fetch_direct_message(
             socket.assigns.current_scope,
             socket.assigns.direct_conversation.id,
             message_id
           ),
         false <- message_deleted?(message) do
      {:noreply, assign(socket, :reply_target, message)}
    else
      _invalid ->
        {:noreply, put_flash(socket, :error, "That message is no longer available to reply to.")}
    end
  end

  def handle_event("cancel_direct_reply", _params, socket) do
    {:noreply, assign(socket, :reply_target, nil)}
  end

  def handle_event(
        "toggle_direct_reaction",
        %{"message-id" => message_id, "emoji" => emoji},
        socket
      ) do
    case Chat.toggle_reaction(socket.assigns.current_scope, message_id, emoji) do
      {:ok, _reaction} ->
        {:noreply, refresh_reaction_summary(socket, message_id)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Reaction could not be saved.")}

      {:error, _reason, _detail} ->
        {:noreply, put_flash(socket, :error, "Reaction could not be saved.")}
    end
  end

  def handle_event("delete_direct_message", %{"message-id" => message_id}, socket) do
    case Chat.delete_message(socket.assigns.current_scope, message_id) do
      {:ok, _message} -> {:noreply, refresh_message(socket, message_id)}
      {:error, _reason} -> {:noreply, put_flash(socket, :error, "Message could not be deleted.")}
    end
  end

  @impl true
  def handle_info(
        {:direct_message_created, %{conversation_id: conversation_id, message_id: message_id}},
        %{assigns: %{direct_conversation: %{id: conversation_id}}} = socket
      ) do
    {:noreply, handle_created_message(socket, message_id)}
  end

  def handle_info(
        {:message_deleted, %{conversation_id: conversation_id, message_id: message_id}},
        %{assigns: %{direct_conversation: %{id: conversation_id}}} = socket
      ) do
    {:noreply, refresh_message(socket, message_id)}
  end

  def handle_info({:reaction_changed, %{message_id: message_id}}, socket) do
    {:noreply, refresh_reaction_summary(socket, message_id)}
  end

  def handle_info({:friendships_changed, _payload}, socket) do
    {:noreply, refresh_writable_capability(socket)}
  end

  def handle_info(
        {:friend_presence_changed, %{user_id: user_id, state: state}},
        %{assigns: %{other_participant: %{id: user_id}, writable?: true}} = socket
      ) do
    if Friendships.friends?(socket.assigns.current_scope, user_id) do
      {:noreply, assign(socket, :friend_presence_status, state)}
    else
      {:noreply, assign(socket, :friend_presence_status, nil)}
    end
  end

  def handle_info(
        {:typing_started, %{conversation_id: conversation_id, user_id: user_id}},
        %{assigns: %{direct_conversation: %{id: conversation_id}}} = socket
      ) do
    {:noreply,
     socket
     |> assign(:typing_user_ids, MapSet.put(socket.assigns.typing_user_ids, user_id))
     |> monitor_current_runtime()}
  end

  def handle_info(
        {:typing_stopped, %{conversation_id: conversation_id, user_id: user_id}},
        %{assigns: %{direct_conversation: %{id: conversation_id}}} = socket
      ) do
    {:noreply,
     assign(socket, :typing_user_ids, MapSet.delete(socket.assigns.typing_user_ids, user_id))}
  end

  def handle_info(
        {:DOWN, monitor_ref, :process, _pid, _reason},
        %{assigns: %{runtime_monitor_ref: monitor_ref}} = socket
      ) do
    {:noreply,
     socket
     |> assign(:typing_user_ids, MapSet.new())
     |> assign(:runtime_monitor_ref, nil)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, socket) do
    if direct_conversation = Map.get(socket.assigns, :direct_conversation) do
      _result =
        Chat.direct_user_stopped_typing(socket.assigns.current_scope, direct_conversation.id)
    end

    :ok
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <DirectMessagesShell.app
        workspace_stream={@streams.workspaces}
        conversation_stream={@streams.direct_conversation_destinations}
        incoming_request_count={@incoming_friend_request_count}
        direct_message_unread_count={@direct_message_unread_count}
        workspace_form={@workspace_form}
        show_workspace_form?={@show_workspace_form?}
        unread_activity_count={@unread_activity_count}
        activity_preview_stream={@streams.activity_preview_items}
        current_scope={@current_scope}
        selected_conversation_id={@direct_conversation.id}
      >
        <main
          id="direct-conversation"
          class="h-full min-h-0 bg-base-100"
        >
          <div class="flex h-full min-h-0 flex-col">
            <header
              id="direct-conversation-header"
              class="flex h-[4.5rem] shrink-0 items-center gap-3 border-b border-base-300/70 bg-base-100 px-5 shadow-sm sm:px-7"
            >
              <.link
                id="direct-conversation-back"
                navigate={~p"/friends"}
                aria-label="Back to Friends"
                class={[
                  "inline-flex size-9 items-center justify-center rounded-xl text-base-content/55 lg:hidden",
                  "transition hover:bg-base-200 hover:text-base-content focus-visible:outline-none",
                  "focus-visible:ring-2 focus-visible:ring-primary"
                ]}
              >
                <.icon name="hero-arrow-left" class="size-4" />
              </.link>

              <div class={[
                "flex size-11 items-center justify-center rounded-2xl bg-primary/15",
                "text-base font-semibold text-primary ring-1 ring-primary/20"
              ]}>
                {@other_participant.username |> String.first() |> String.upcase()}
              </div>

              <div
                id={"direct-conversation-participant-#{@other_participant.id}"}
                class={["min-w-0 flex-1"]}
              >
                <p class="flex items-center gap-1.5 truncate text-base font-bold leading-5 text-base-content">
                  <span class="text-base-content/40">@</span>{@other_participant.username}
                </p>
                <p
                  :if={@friend_presence_status}
                  id={"direct-conversation-presence-#{@other_participant.id}"}
                  role="status"
                  data-presence-state={@friend_presence_status}
                  class={["mt-0.5 text-xs font-medium text-base-content/50"]}
                >
                  {presence_label(@friend_presence_status)}
                </p>
                <p
                  :if={!@friend_presence_status}
                  class={["mt-0.5 text-xs font-medium text-base-content/50"]}
                >
                  Direct Conversation
                </p>
              </div>

              <div class="ml-auto flex shrink-0 items-center gap-2">
                <p
                  :if={!@writable?}
                  id="direct-conversation-call-unavailable-reason"
                  class="max-w-[9.5rem] text-right text-xs leading-4 text-base-content/50"
                >
                  Calls require a current Friendship.
                </p>
                <button
                  id="direct-conversation-start-voice-call"
                  type="button"
                  data-call-action="start-audio"
                  data-direct-conversation-id={@direct_conversation.id}
                  data-peer-id={@other_participant.id}
                  data-peer-username={@other_participant.username}
                  aria-label={"Start voice call with #{@other_participant.username}"}
                  aria-disabled={if(!@writable?, do: "true")}
                  aria-describedby={
                    if(!@writable?, do: "direct-conversation-call-unavailable-reason")
                  }
                  class={[
                    "inline-flex size-9 items-center justify-center rounded-xl text-base-content/55",
                    "transition hover:bg-base-200 hover:text-base-content focus-visible:outline-none",
                    "focus-visible:ring-2 focus-visible:ring-primary",
                    !@writable? &&
                      "cursor-not-allowed opacity-50 hover:bg-transparent hover:text-base-content/55"
                  ]}
                >
                  <.icon name="hero-phone" class="size-4" />
                </button>
                <button
                  id="direct-conversation-start-video-call"
                  type="button"
                  data-call-action="start-video"
                  data-direct-conversation-id={@direct_conversation.id}
                  data-peer-id={@other_participant.id}
                  data-peer-username={@other_participant.username}
                  aria-label={"Start video call with #{@other_participant.username}"}
                  aria-disabled={
                    if(!@writable? || !@call_capabilities.video_available?,
                      do: "true"
                    )
                  }
                  aria-describedby={
                    if(!@call_capabilities.video_available?,
                      do: "direct-conversation-video-unavailable-reason",
                      else: if(!@writable?, do: "direct-conversation-call-unavailable-reason")
                    )
                  }
                  class={[
                    "inline-flex size-9 items-center justify-center rounded-xl text-base-content/55",
                    "transition hover:bg-base-200 hover:text-base-content focus-visible:outline-none",
                    "focus-visible:ring-2 focus-visible:ring-primary",
                    !@writable? &&
                      "cursor-not-allowed opacity-50 hover:bg-transparent hover:text-base-content/55"
                  ]}
                >
                  <.icon name="hero-video-camera" class="size-4" />
                </button>
                <p
                  :if={!@call_capabilities.video_available?}
                  id="direct-conversation-video-unavailable-reason"
                  class="max-w-[9.5rem] text-right text-xs leading-4 text-base-content/50"
                >
                  Video calling is unavailable.
                </p>
              </div>
            </header>

            <section
              id="direct-conversation-call-stage"
              phx-hook="CallConversationStage"
              phx-update="ignore"
              data-direct-conversation-id={@direct_conversation.id}
              aria-label="Direct Call"
              hidden
            >
            </section>

            <section
              id="direct-message-surface"
              class="flex min-h-0 flex-1 flex-col overflow-hidden bg-base-100"
              aria-label={"Direct Messages with #{@other_participant.username}"}
            >
              <div class="relative min-h-0 flex-1">
                <div
                  :if={@direct_messages_empty?}
                  id="direct-conversation-empty"
                  class="pointer-events-none absolute inset-0 flex flex-col items-center justify-center p-8 text-center"
                >
                  <div class={[
                    "mx-auto flex size-14 items-center justify-center rounded-2xl",
                    "bg-primary/10 text-primary"
                  ]}>
                    <.icon name="hero-chat-bubble-left-right" class="size-7" />
                  </div>
                  <h1 class={["mt-5 text-xl font-bold tracking-tight text-base-content"]}>
                    Start your conversation
                  </h1>
                  <p class={["mt-2 text-sm leading-6 text-base-content/55"]}>
                    This Direct Conversation with @{@other_participant.username} is empty and ready for your first message.
                  </p>
                </div>

                <div
                  id="direct-older-messages-loading"
                  data-loading={to_string(@loading_older_messages?)}
                  aria-live="polite"
                  class={[
                    "pointer-events-none absolute inset-x-0 top-0 z-10 py-2 text-center text-xs font-semibold uppercase tracking-wide text-base-content/45",
                    !@loading_older_messages? && "sr-only"
                  ]}
                >
                  Loading older Direct Messages
                </div>

                <div
                  id="direct-newer-messages-loading"
                  data-loading={to_string(@loading_newer_messages?)}
                  aria-live="polite"
                  class={[
                    "pointer-events-none absolute inset-x-0 bottom-0 z-10 py-2 text-center text-xs font-semibold uppercase tracking-wide text-base-content/45",
                    !@loading_newer_messages? && "sr-only"
                  ]}
                >
                  Loading newer Direct Messages
                </div>

                <div
                  id="direct-messages"
                  phx-update="stream"
                  phx-hook="ChannelMessages"
                  data-has-older-messages={to_string(@message_window_meta.has_older?)}
                  data-has-newer-messages={to_string(@message_window_meta.has_newer?)}
                  data-loading-older={to_string(@loading_older_messages?)}
                  data-loading-newer={to_string(@loading_newer_messages?)}
                  data-scroll-target-kind={ScrollAnchoring.scroll_target_kind(@message_scroll_target)}
                  data-scroll-target-seq={ScrollAnchoring.scroll_target_seq(@message_scroll_target)}
                  data-scroll-target-token={
                    ScrollAnchoring.scroll_target_token(@message_scroll_target)
                  }
                  class="absolute inset-0 scroll-pb-6 overflow-y-auto px-4 py-5 [overflow-anchor:none] sm:px-7 sm:py-6"
                >
                  <article
                    :for={{dom_id, message} <- @streams.direct_messages}
                    id={dom_id}
                    data-message-row={direct_message_row_kind(@direct_message_row_kinds, message.id)}
                    data-message-seq={message.seq}
                    data-visible-read-observe={message.user_id != @current_scope.user.id && "true"}
                    data-message-navigation-target={
                      to_string(message.id == @message_navigation_target_id)
                    }
                    class={[
                      "group relative grid w-full grid-cols-[2.75rem_minmax(0,1fr)] gap-x-3 rounded-md px-3 transition-colors duration-150 hover:bg-base-200/70 focus-within:bg-base-200/70",
                      if(
                        direct_message_row_kind(@direct_message_row_kinds, message.id) == :compact,
                        do: "py-0.5",
                        else: "py-1.5"
                      ),
                      message.id == @message_navigation_target_id &&
                        "message-target-highlight"
                    ]}
                  >
                    <div
                      :if={direct_message_row_kind(@direct_message_row_kinds, message.id) == :full}
                      class="mt-0.5 flex size-10 shrink-0 items-center justify-center rounded-lg bg-primary/15 text-sm font-semibold text-primary ring-1 ring-primary/20 transition group-hover:bg-primary/20"
                    >
                      {message.user.username |> String.first() |> String.upcase()}
                    </div>
                    <div
                      :if={direct_message_row_kind(@direct_message_row_kinds, message.id) == :compact}
                      id={"#{dom_id}-spacer"}
                      aria-hidden="true"
                    >
                    </div>
                    <div id={"#{dom_id}-body"} class="relative min-w-0 pr-40 text-left">
                      <div
                        :if={!message_deleted?(message)}
                        id={"#{dom_id}-actions"}
                        class="direct-message-actions absolute right-0 top-0 z-20 flex items-center gap-2"
                      >
                        <button
                          :if={@writable?}
                          id={"#{dom_id}-reply"}
                          type="button"
                          phx-click="begin_direct_reply"
                          phx-value-message-id={message.id}
                          aria-label={"Reply to message from #{message.user.username}"}
                          class="flex size-8 items-center justify-center rounded-lg bg-base-100/95 text-base-content/65 opacity-0 shadow-lg shadow-base-300/20 ring-1 ring-base-content/10 backdrop-blur-sm transition duration-150 hover:bg-base-200 hover:text-base-content group-hover:opacity-100 focus:opacity-100 focus:outline-none focus:ring-2 focus:ring-primary/25"
                        >
                          <.icon name="hero-arrow-uturn-left" class="size-4" />
                        </button>
                        <div
                          :if={@writable?}
                          id={"#{dom_id}-reaction-palette"}
                          class="pointer-events-none flex items-center gap-0.5 rounded-lg bg-base-100/95 p-1 opacity-0 shadow-lg shadow-base-300/20 ring-1 ring-base-content/10 backdrop-blur-sm transition duration-150 group-hover:pointer-events-auto group-hover:opacity-100"
                        >
                          <button
                            :for={{emoji, index} <- Enum.with_index(reaction_palette())}
                            id={"#{dom_id}-reaction-option-#{index}"}
                            type="button"
                            phx-click="toggle_direct_reaction"
                            phx-value-message-id={message.id}
                            phx-value-emoji={emoji}
                            aria-label={"React with #{emoji} to message"}
                            class="flex size-8 items-center justify-center rounded-md text-base leading-none transition hover:bg-base-200 focus:outline-none focus:ring-2 focus:ring-primary/25"
                          >
                            {emoji}
                          </button>
                        </div>
                        <button
                          :if={message.user_id == @current_scope.user.id}
                          id={"#{dom_id}-delete"}
                          type="button"
                          phx-click="delete_direct_message"
                          phx-value-message-id={message.id}
                          aria-label="Delete Direct Message"
                          class="flex size-8 items-center justify-center rounded-lg bg-base-100/95 text-base-content/65 opacity-0 shadow-lg shadow-base-300/20 ring-1 ring-base-content/10 backdrop-blur-sm transition duration-150 hover:bg-error/10 hover:text-error group-hover:opacity-100 focus:opacity-100 focus:outline-none focus:ring-2 focus:ring-error/25"
                        >
                          <.icon name="hero-trash" class="size-4" />
                        </button>
                      </div>
                      <button
                        :if={
                          !is_nil(message.reply_to_message_id) &&
                            !message_deleted?(message.reply_to_message)
                        }
                        id={"#{dom_id}-reply-preview"}
                        type="button"
                        phx-click="navigate_direct_message"
                        phx-value-message-id={message.reply_to_message_id}
                        class="mb-1.5 flex max-w-full items-center gap-2 border-l-2 border-primary/35 pl-2 text-left text-xs text-base-content/55"
                      >
                        <span class="shrink-0 font-semibold text-primary/85">
                          {message.reply_to_message.user.username}
                        </span>
                        <span class="truncate">
                          {truncate_reply_content(message.reply_to_message.content)}
                        </span>
                      </button>
                      <div
                        :if={
                          !is_nil(message.reply_to_message_id) &&
                            message_deleted?(message.reply_to_message)
                        }
                        id={"#{dom_id}-deleted-reply-preview"}
                        class="mb-1.5 flex items-center gap-2 border-l-2 border-base-content/20 pl-2 text-xs italic text-base-content/45"
                      >
                        <.icon name="hero-no-symbol" class="size-3.5" />
                        <span>Message deleted</span>
                      </div>
                      <div
                        :if={direct_message_row_kind(@direct_message_row_kinds, message.id) == :full}
                        class="flex min-h-5 flex-wrap items-baseline gap-2 pr-40"
                      >
                        <span class="text-sm font-semibold leading-5 text-base-content">
                          {message.user.username}
                        </span>
                        <time
                          datetime={DateTime.to_iso8601(message.inserted_at)}
                          class="text-xs font-medium leading-5 text-base-content/50"
                        >
                          {Calendar.strftime(message.inserted_at, "%H:%M")}
                        </time>
                      </div>
                      {direct_message_content(
                        message,
                        direct_message_row_kind(@direct_message_row_kinds, message.id)
                      )}
                      <p
                        :if={message_deleted?(message)}
                        id={"#{dom_id}-deleted"}
                        class="mt-0.5 flex items-center gap-2 text-sm italic leading-5 text-base-content/45"
                      >
                        <.icon name="hero-no-symbol" class="size-4" /> Message deleted
                      </p>
                      <div
                        :if={
                          !message_deleted?(message) &&
                            reaction_summaries_for(@reaction_summaries, message.id) != []
                        }
                        id={"#{dom_id}-reactions"}
                        class="mt-1.5 flex flex-wrap items-center gap-1.5"
                      >
                        <button
                          :for={
                            {summary, index} <-
                              Enum.with_index(reaction_summaries_for(@reaction_summaries, message.id))
                          }
                          id={"#{dom_id}-reaction-#{index}"}
                          type="button"
                          disabled={!@writable? && !summary.reacted?}
                          phx-click="toggle_direct_reaction"
                          phx-value-message-id={message.id}
                          phx-value-emoji={summary.emoji}
                          data-current-user-reacted={to_string(summary.reacted?)}
                          aria-label={reaction_label(summary)}
                          class={[
                            "inline-flex items-center gap-1 rounded-full border px-2 py-0.5 text-xs font-semibold shadow-sm transition",
                            summary.reacted? &&
                              "border-primary/35 bg-primary/10 text-primary hover:bg-primary/15",
                            !summary.reacted? &&
                              "border-base-300 bg-base-200/70 text-base-content/75",
                            !@writable? && !summary.reacted? && "cursor-default opacity-70"
                          ]}
                        >
                          <span>{summary.emoji}</span><span>{summary.count}</span>
                        </button>
                      </div>
                    </div>
                  </article>
                </div>
              </div>

              <div
                :if={typing_participants(@typing_user_ids, @other_participant) != []}
                id="direct-typing-indicator"
                class="px-6 py-2 text-xs font-medium text-base-content/60 shadow-[0_-1px_0_rgb(255_255_255/0.035)]"
                aria-live="polite"
              >
                <span
                  :for={participant <- typing_participants(@typing_user_ids, @other_participant)}
                  data-typing-user-id={participant.id}
                >
                  {participant.username} is typing...
                </span>
              </div>

              <div
                :if={@writable?}
                id="direct-message-composer-panel"
                class="shrink-0 bg-base-100/95 px-5 pb-5 pt-4 shadow-[0_-12px_28px_rgb(0_0_0/0.10),0_-1px_0_rgb(255_255_255/0.04)] sm:px-7"
              >
                <div
                  :if={!is_nil(@reply_target)}
                  id="direct-message-reply-target"
                  data-message-id={@reply_target && @reply_target.id}
                  class="mb-2 flex items-center gap-3 rounded-lg border border-primary/20 bg-primary/5 px-3 py-2 shadow-sm"
                >
                  <p class="min-w-0 flex-1 truncate text-xs text-base-content/60">
                    Replying to <span class="font-semibold text-primary">{@reply_target.user.username}</span>: {@reply_target.content}
                  </p>
                  <button
                    id="cancel-direct-message-reply"
                    type="button"
                    phx-click="cancel_direct_reply"
                    aria-label="Cancel reply"
                    class="text-base-content/45 hover:text-base-content"
                  >
                    <.icon name="hero-x-mark" class="size-4" />
                  </button>
                </div>
                <.form
                  for={@message_form}
                  id="direct-message-form"
                  phx-submit="send_direct_message"
                  phx-change="message_typing"
                  phx-hook="MessageComposer"
                  data-mentions-enabled="false"
                  class="flex items-end"
                >
                  <div
                    id="direct-message-composer-shell"
                    class="relative min-w-0 flex-1 rounded-xl bg-base-200/80 px-3 py-2.5 shadow-inner shadow-base-300/30 ring-1 ring-base-300/60 transition focus-within:bg-base-200 focus-within:ring-primary/35"
                  >
                    <.input
                      field={@message_form[:content]}
                      type="text"
                      placeholder={"Message @#{@other_participant.username}"}
                      autocomplete="off"
                      phx-throttle="3000"
                      class="w-full appearance-none border-0 bg-transparent px-1 py-2 text-sm leading-5 text-base-content outline-none ring-0 transition placeholder:text-base-content/40 focus:border-0 focus:outline-none focus:ring-0"
                      error_class="input-error border-0 ring-0"
                    />
                  </div>
                </.form>
              </div>
              <div
                :if={!@writable?}
                id="direct-conversation-read-only"
                class="border-t border-base-300/70 bg-base-200/55 px-5 py-5"
              >
                <div class="mx-auto flex max-w-xl flex-col items-center gap-3 text-center sm:flex-row sm:text-left">
                  <span class="flex size-10 shrink-0 items-center justify-center rounded-2xl bg-warning/10 text-warning">
                    <.icon name="hero-lock-closed" class="size-5" />
                  </span>
                  <div class="min-w-0 flex-1">
                    <p class="text-sm font-semibold text-base-content">
                      This conversation is read-only
                    </p>
                    <p class="mt-0.5 text-xs leading-5 text-base-content/55">
                      You are no longer Friends. Your history and unsent draft are preserved.
                    </p>
                  </div>
                  <button
                    :if={@friendship_recovery_state in [:none, :incoming_request]}
                    id="direct-conversation-send-friend-request"
                    type="button"
                    phx-click="send_friend_request"
                    phx-disable-with="Sending…"
                    class={[
                      "inline-flex h-10 shrink-0 items-center justify-center gap-2 rounded-xl",
                      "bg-primary px-4 text-xs font-semibold text-primary-content shadow-sm",
                      "transition hover:-translate-y-0.5 hover:bg-primary/90 focus-visible:outline-none",
                      "focus-visible:ring-2 focus-visible:ring-primary focus-visible:ring-offset-2"
                    ]}
                  >
                    <.icon name="hero-user-plus" class="size-4" />
                    {if @friendship_recovery_state == :incoming_request,
                      do: "Accept Friend Request",
                      else: "Send Friend Request"}
                  </button>
                  <p
                    :if={@friendship_recovery_state == :outgoing_request}
                    id="direct-conversation-friend-request-pending"
                    class="shrink-0 rounded-xl bg-base-300 px-3 py-2 text-xs font-semibold text-base-content/60"
                  >
                    Friend Request pending
                  </p>
                </div>
              </div>
            </section>
          </div>
        </main>
      </DirectMessagesShell.app>
    </Layouts.app>
    """
  end

  defp subscribe_to_messages(socket, direct_conversation_id) do
    if connected?(socket) do
      with :ok <-
             Chat.subscribe_to_direct_messages(
               socket.assigns.current_scope,
               direct_conversation_id
             ) do
        Chat.subscribe_to_direct_reactions(socket.assigns.current_scope, direct_conversation_id)
      end
    else
      :ok
    end
  end

  defp open_message_window(socket, direct_conversation_id, %{"message_id" => message_id}) do
    if connected?(socket) do
      navigate_to_message_window(socket, direct_conversation_id, message_id)
    else
      Chat.load_latest_direct_message_window(socket.assigns.current_scope, direct_conversation_id)
    end
  end

  defp open_message_window(socket, direct_conversation_id, _params) do
    Chat.load_latest_direct_message_window(socket.assigns.current_scope, direct_conversation_id)
  end

  defp navigate_to_message_window(socket, message_id) do
    navigate_to_message_window(socket, socket.assigns.direct_conversation.id, message_id)
  end

  defp navigate_to_message_window(socket, direct_conversation_id, message_id) do
    case Chat.navigate_to_direct_message(
           socket.assigns.current_scope,
           direct_conversation_id,
           message_id
         ) do
      {:ok, %{target: target} = window} ->
        token = System.unique_integer([:positive, :monotonic])

        {:ok,
         window
         |> Map.put(:target, %{id: target.id, token: token})
         |> Map.put(:scroll_target, %{kind: :sequence, seq: target.seq, token: token})}

      error ->
        error
    end
  end

  defp monitor_runtime(socket, direct_conversation_id) do
    if connected?(socket) do
      case Chat.ensure_direct_conversation_runtime(
             socket.assigns.current_scope,
             direct_conversation_id
           ) do
        {:ok, pid} -> {:ok, Process.monitor(pid)}
        {:error, reason} -> {:error, reason}
      end
    else
      {:ok, nil}
    end
  end

  defp list_typing_user_ids(socket, direct_conversation_id) do
    if connected?(socket) do
      Chat.list_direct_typing_user_ids(socket.assigns.current_scope, direct_conversation_id)
    else
      {:ok, []}
    end
  end

  defp monitor_current_runtime(%{assigns: %{runtime_monitor_ref: monitor_ref}} = socket)
       when is_reference(monitor_ref),
       do: socket

  defp monitor_current_runtime(socket) do
    case Chat.ensure_direct_conversation_runtime(
           socket.assigns.current_scope,
           socket.assigns.direct_conversation.id
         ) do
      {:ok, pid} -> assign(socket, :runtime_monitor_ref, Process.monitor(pid))
      {:error, _reason} -> socket
    end
  end

  defp replace_message_window(socket, %{messages: messages, meta: meta} = window) do
    reaction_summaries = reaction_summaries(socket, messages)

    socket
    |> assign(:direct_messages_empty?, messages == [])
    |> assign(:direct_messages_by_id, messages_by_id(messages))
    |> assign(:direct_message_row_kinds, direct_message_row_kinds(messages))
    |> assign(:oldest_message, List.first(messages))
    |> assign(:latest_message, List.last(messages))
    |> assign(:message_window_meta, meta)
    |> assign(:loading_older_messages?, false)
    |> assign(:loading_newer_messages?, false)
    |> assign(:reaction_summaries, reaction_summaries)
    |> assign(:message_navigation_target_id, get_in(window, [:target, :id]))
    |> assign(:message_scroll_target, window[:scroll_target])
    |> clear_deleted_reply_target(messages)
    |> stream(:direct_messages, messages, reset: true)
  end

  defp merge_message_window(socket, %{messages: messages, meta: loaded_meta}, direction) do
    all_messages =
      socket.assigns.direct_messages_by_id
      |> Map.merge(messages_by_id(messages))
      |> Map.values()
      |> Enum.sort_by(& &1.seq)

    trimmed? = length(all_messages) > @rendered_message_limit
    merged_messages = trim_messages(all_messages, direction)

    meta =
      merged_window_meta(
        socket.assigns.message_window_meta,
        loaded_meta,
        merged_messages,
        direction,
        trimmed?
      )

    socket
    |> assign(:direct_messages_empty?, merged_messages == [])
    |> assign(:direct_messages_by_id, messages_by_id(merged_messages))
    |> assign(:direct_message_row_kinds, direct_message_row_kinds(merged_messages))
    |> assign(:oldest_message, List.first(merged_messages))
    |> assign(:latest_message, List.last(merged_messages))
    |> assign(:message_window_meta, meta)
    |> assign(:loading_older_messages?, false)
    |> assign(:loading_newer_messages?, false)
    |> assign(:reaction_summaries, reaction_summaries(socket, merged_messages))
    |> stream(:direct_messages, merged_messages, reset: true)
  end

  defp trim_messages(messages, :older), do: Enum.take(messages, @rendered_message_limit)
  defp trim_messages(messages, :newer), do: Enum.take(messages, -@rendered_message_limit)

  defp merged_window_meta(current, loaded, messages, direction, trimmed?) do
    oldest_seq = messages |> List.first() |> message_seq()
    newest_seq = messages |> List.last() |> message_seq()
    latest_seq = max(current.latest_seq || 0, loaded.latest_seq || 0)

    %{
      oldest_seq: oldest_seq,
      newest_seq: newest_seq,
      latest_seq: latest_seq,
      has_older?: loaded.has_older? || (direction == :newer && trimmed?),
      has_newer?:
        loaded.has_newer? || (direction == :older && trimmed? && newest_seq < latest_seq),
      at_latest?: newest_seq == latest_seq,
      at_or_near_latest?: is_integer(newest_seq) && latest_seq - newest_seq <= 50
    }
  end

  defp handle_created_message(socket, message_id) do
    if socket.assigns.message_window_meta.at_or_near_latest? do
      case Chat.load_latest_direct_message_window(
             socket.assigns.current_scope,
             socket.assigns.direct_conversation.id
           ) do
        {:ok, window} -> merge_message_window(socket, window, :newer)
        {:error, _reason} -> socket
      end
    else
      case Chat.fetch_direct_message(
             socket.assigns.current_scope,
             socket.assigns.direct_conversation.id,
             message_id
           ) do
        {:ok, message} ->
          meta =
            socket.assigns.message_window_meta
            |> Map.put(:latest_seq, message.seq)
            |> Map.put(:has_newer?, true)
            |> Map.put(:at_latest?, false)
            |> Map.put(:at_or_near_latest?, false)

          assign(socket, :message_window_meta, meta)

        {:error, _reason} ->
          socket
      end
    end
  end

  defp refresh_message(socket, message_id) do
    case Chat.fetch_direct_message(
           socket.assigns.current_scope,
           socket.assigns.direct_conversation.id,
           message_id
         ) do
      {:ok, message} ->
        messages_by_id = Map.put(socket.assigns.direct_messages_by_id, message.id, message)

        socket
        |> assign(:direct_messages_by_id, messages_by_id)
        |> recover_deleted_reply_target(message)
        |> stream_insert(:direct_messages, message)
        |> refresh_reply_previews(message)

      {:error, _reason} ->
        socket
    end
  end

  defp refresh_reply_previews(socket, deleted_message) do
    if message_deleted?(deleted_message) do
      socket.assigns.direct_messages_by_id
      |> Map.values()
      |> Enum.filter(&(&1.reply_to_message_id == deleted_message.id))
      |> Enum.reduce(socket, fn reply, socket -> refresh_one_message(socket, reply.id) end)
    else
      socket
    end
  end

  defp refresh_one_message(socket, message_id) do
    case Chat.fetch_direct_message(
           socket.assigns.current_scope,
           socket.assigns.direct_conversation.id,
           message_id
         ) do
      {:ok, message} ->
        socket
        |> assign(
          :direct_messages_by_id,
          Map.put(socket.assigns.direct_messages_by_id, message.id, message)
        )
        |> stream_insert(:direct_messages, message)

      {:error, _reason} ->
        socket
    end
  end

  defp refresh_reaction_summary(socket, message_id) do
    case Chat.list_reaction_summaries(socket.assigns.current_scope, [message_id]) do
      {:ok, summaries} ->
        socket
        |> assign(
          :reaction_summaries,
          Map.put(
            socket.assigns.reaction_summaries,
            message_id,
            Map.get(summaries, message_id, [])
          )
        )
        |> restream_message(message_id)

      {:error, _reason} ->
        socket
    end
  end

  defp restream_message(socket, message_id) do
    case Map.fetch(socket.assigns.direct_messages_by_id, message_id) do
      {:ok, message} -> stream_insert(socket, :direct_messages, message)
      :error -> socket
    end
  end

  defp reaction_summaries(socket, messages) do
    message_ids = Enum.map(messages, & &1.id)

    case Chat.list_reaction_summaries(socket.assigns.current_scope, message_ids) do
      {:ok, summaries} -> summaries
      {:error, _reason} -> %{}
    end
  end

  defp messages_by_id(messages), do: Map.new(messages, &{&1.id, &1})

  defp direct_message_row_kinds(messages) do
    messages
    |> MessageRows.annotate()
    |> Map.new(&{&1.message.id, &1.row_kind})
  end

  defp direct_message_row_kind(row_kinds, message_id), do: Map.fetch!(row_kinds, message_id)
  defp message_seq(nil), do: nil
  defp message_seq(message), do: message.seq

  defp parse_visible_read_ranges(ranges) do
    ranges
    |> Enum.reduce_while([], fn range, parsed_ranges ->
      with %{"from_seq" => from_seq, "to_seq" => to_seq} <- range,
           {:ok, from_seq} <- ScrollAnchoring.parse_integer(from_seq),
           {:ok, to_seq} <- ScrollAnchoring.parse_integer(to_seq) do
        {:cont, [{from_seq, to_seq} | parsed_ranges]}
      else
        _invalid -> {:halt, :invalid}
      end
    end)
    |> case do
      :invalid -> :invalid
      parsed_ranges -> Enum.reverse(parsed_ranges)
    end
  end

  defp valid_visible_read_ranges?(_socket, :invalid), do: false
  defp valid_visible_read_ranges?(_socket, []), do: false

  defp valid_visible_read_ranges?(socket, ranges) do
    received_rendered_seqs =
      socket.assigns.direct_messages_by_id
      |> Map.values()
      |> Enum.reject(&(&1.user_id == socket.assigns.current_scope.user.id))
      |> MapSet.new(& &1.seq)

    length(ranges) <= @visible_read_range_limit and
      ordered_visible_read_ranges?(ranges) and
      Enum.all?(ranges, fn {from_seq, to_seq} ->
        from_seq > 0 and
          from_seq <= to_seq and
          to_seq - from_seq + 1 <= @visible_read_range_limit and
          Enum.all?(from_seq..to_seq, &MapSet.member?(received_rendered_seqs, &1))
      end)
  end

  defp ordered_visible_read_ranges?(ranges) do
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

  defp message_form do
    %{}
    |> Chat.change_message()
    |> to_form(as: :message)
  end

  defp direct_message_content(message, row_kind) do
    if message_deleted?(message) do
      nil
    else
      {:safe, attrs} =
        Phoenix.HTML.attributes_escape(
          data_direct_message_content: true,
          class: [
            "whitespace-pre-wrap break-words text-left text-sm leading-5 text-base-content/90 [overflow-wrap:anywhere]",
            row_kind == :full && "mt-0.5"
          ]
        )

      {:safe, content} = Phoenix.HTML.html_escape(message.content)
      {:safe, ["<p", attrs, ">", content, "</p>"]}
    end
  end

  defp blank_direct_message?(%{"content" => content}) when is_binary(content) do
    String.trim(content) == ""
  end

  defp blank_direct_message?(_message_params), do: false

  defp put_reply_target(message_params, nil), do: message_params

  defp put_reply_target(message_params, reply_target),
    do: Map.put(message_params, "reply_to_message_id", reply_target.id)

  defp recover_invalid_reply_target(%{assigns: %{reply_target: nil}} = socket, _changeset),
    do: socket

  defp recover_invalid_reply_target(socket, changeset) do
    if Keyword.has_key?(changeset.errors, :reply_to_message_id) do
      socket
      |> assign(:reply_target, nil)
      |> put_flash(:error, "That message is no longer available to reply to.")
    else
      socket
    end
  end

  defp refresh_writable_capability(socket) do
    {:ok, destinations} = Chat.list_direct_conversation_destinations(socket.assigns.current_scope)
    writable? = destination_writable?(destinations, socket.assigns.direct_conversation.id)

    socket =
      socket
      |> assign(:writable?, writable?)
      |> assign_friendship_recovery_state(writable?)
      |> assign(
        :friend_presence_status,
        friend_presence_status(socket, socket.assigns.other_participant.id, writable?)
      )
      |> then(fn socket ->
        if writable? do
          socket
        else
          _result =
            Chat.direct_user_stopped_typing(
              socket.assigns.current_scope,
              socket.assigns.direct_conversation.id
            )

          socket
          |> assign(:reply_target, nil)
          |> assign(:typing_user_ids, MapSet.new())
        end
      end)

    socket
    |> stream(
      :direct_messages,
      socket.assigns.direct_messages_by_id |> Map.values() |> Enum.sort_by(& &1.seq),
      reset: true
    )
  end

  defp destination_writable?(destinations, direct_conversation_id) do
    Enum.any?(destinations, fn destination ->
      destination.direct_conversation.id == direct_conversation_id && destination.writable?
    end)
  end

  defp assign_friendship_recovery_state(socket, true) do
    assign(socket, :friendship_recovery_state, :friends)
  end

  defp assign_friendship_recovery_state(socket, false) do
    {:ok, relationship_state} =
      Friendships.relationship_state(
        socket.assigns.current_scope,
        socket.assigns.other_participant.id
      )

    assign(socket, :friendship_recovery_state, relationship_state)
  end

  defp friend_presence_status(socket, friend_user_id, true) do
    if connected?(socket),
      do: :ok = Presence.subscribe_to_friend(socket.assigns.current_scope, friend_user_id)

    case Presence.friend_status(socket.assigns.current_scope, friend_user_id) do
      {:ok, state} -> state
      {:error, _reason} -> nil
    end
  end

  defp friend_presence_status(_socket, _friend_user_id, false), do: nil

  defp presence_label(:online), do: "Online"
  defp presence_label(:offline), do: "Offline"

  defp clear_deleted_reply_target(%{assigns: %{reply_target: nil}} = socket, _messages),
    do: socket

  defp clear_deleted_reply_target(socket, messages) do
    target_id = socket.assigns.reply_target.id

    if Enum.any?(messages, &(&1.id == target_id && is_nil(&1.deleted_at))) do
      socket
    else
      socket
      |> assign(:reply_target, nil)
      |> put_flash(:error, "That reply target was deleted.")
    end
  end

  defp recover_deleted_reply_target(%{assigns: %{reply_target: %{id: id}}} = socket, %{id: id}) do
    socket
    |> assign(:reply_target, nil)
    |> put_flash(:error, "That reply target was deleted.")
  end

  defp recover_deleted_reply_target(socket, _message), do: socket

  defp start_typing(%{assigns: %{writable?: false}} = socket), do: {:noreply, socket}

  defp start_typing(socket) do
    case Chat.direct_user_started_typing(
           socket.assigns.current_scope,
           socket.assigns.direct_conversation.id
         ) do
      :ok ->
        {:noreply, monitor_current_runtime(socket)}

      {:error, :not_friends} ->
        {:noreply, refresh_writable_capability(socket)}

      {:error, _reason} ->
        {:noreply, direct_conversation_unavailable(socket)}
    end
  end

  defp stop_typing(socket) do
    case Chat.direct_user_stopped_typing(
           socket.assigns.current_scope,
           socket.assigns.direct_conversation.id
         ) do
      :ok -> {:noreply, socket}
      {:error, _reason} -> {:noreply, direct_conversation_unavailable(socket)}
    end
  end

  defp direct_conversation_unavailable(socket) do
    socket
    |> put_flash(:error, "Direct Conversation not found.")
    |> push_navigate(to: ~p"/friends")
  end

  defp typing_participants(typing_user_ids, other_participant) do
    if MapSet.member?(typing_user_ids, other_participant.id), do: [other_participant], else: []
  end

  defp reaction_summaries_for(summaries, message_id), do: Map.get(summaries, message_id, [])
  defp reaction_palette, do: @reaction_palette
  defp message_deleted?(%{deleted_at: %DateTime{}}), do: true
  defp message_deleted?(_message), do: false

  defp truncate_reply_content(content) do
    if String.length(content) > 80, do: String.slice(content, 0, 77) <> "…", else: content
  end

  defp reaction_label(summary) do
    count_label = if summary.count == 1, do: "1 reaction", else: "#{summary.count} reactions"
    "#{summary.emoji} reaction, #{count_label}"
  end
end
