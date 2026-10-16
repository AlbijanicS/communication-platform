defmodule DiscordCloneWeb.ActivityLive do
  @moduledoc false

  use DiscordCloneWeb, :live_view

  alias DiscordClone.{Chat, Workspaces}
  alias DiscordCloneWeb.WorkspaceLive.Shell

  @activity_preview_limit 5

  def on_mount(:assign_unread_count, _params, _session, socket) do
    if activity_consumer?(socket.view) do
      if connected?(socket) do
        :ok = Chat.subscribe_to_activity(socket.assigns.current_scope)
      end

      socket =
        socket
        |> stream_configure(:activity_preview_items,
          dom_id: &"activity-preview-item-#{&1.id}"
        )
        |> assign_activity_shell(socket.view)
        |> attach_hook(:activity_summary, :handle_info, &refresh_activity_summary/2)
        |> attach_hook(:activity_preview_events, :handle_event, &handle_activity_preview_event/3)

      {:cont, socket}
    else
      {:cont, socket}
    end
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok, workspaces} = Workspaces.list_workspaces(socket.assigns.current_scope)
    {:ok, activity_feed_page} = Chat.list_activity_feed(socket.assigns.current_scope)

    socket =
      socket
      |> assign(:activity_feed_pages_loaded, 1)
      |> assign(:activity_next_cursor, activity_feed_page.next_cursor)
      |> stream(:workspaces, workspaces)
      |> refresh_activity_preview()
      |> stream_configure(:activity_items, dom_id: &"activity-item-#{&1.id}")
      |> stream(:activity_items, activity_feed_page.items)

    {:ok, socket}
  end

  @impl true
  def handle_event(
        "load_older_activity",
        _params,
        %{assigns: %{activity_next_cursor: nil}} = socket
      ) do
    {:noreply, socket}
  end

  def handle_event("load_older_activity", _params, socket) do
    case Chat.list_activity_feed(
           socket.assigns.current_scope,
           socket.assigns.activity_next_cursor
         ) do
      {:ok, activity_feed_page} ->
        {:noreply,
         socket
         |> update(:activity_feed_pages_loaded, &(&1 + 1))
         |> assign(:activity_next_cursor, activity_feed_page.next_cursor)
         |> stream(:activity_items, activity_feed_page.items, at: -1)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Older activity could not be loaded.")}
    end
  end

  @impl true
  def handle_event("mark_all_activity_read", _params, socket) do
    with {:ok, _updated_count} <- Chat.mark_all_activity_read(socket.assigns.current_scope),
         {:ok, activity_feed_page} <-
           list_loaded_activity_feed_pages(
             socket.assigns.current_scope,
             socket.assigns.activity_feed_pages_loaded
           ),
         {:ok, unread_count} <- Chat.unread_activity_count(socket.assigns.current_scope) do
      {:noreply,
       socket
       |> assign(:activity_next_cursor, activity_feed_page.next_cursor)
       |> assign(:unread_activity_count, unread_count)
       |> refresh_activity_preview()
       |> stream(:activity_items, activity_feed_page.items, reset: true)}
    else
      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Activity could not be marked read.")}
    end
  end

  @impl true
  def handle_event("open_activity_item", %{"activity-item-id" => activity_item_id}, socket) do
    case Chat.open_activity_item(socket.assigns.current_scope, activity_item_id) do
      {:ok, destination} ->
        {:ok, unread_count} = Chat.unread_activity_count(socket.assigns.current_scope)

        {:noreply,
         socket
         |> assign(:unread_activity_count, unread_count)
         |> push_navigate(to: activity_destination_path(destination))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Activity is no longer available.")}
    end
  end

  @impl true
  def handle_info({:activity_changed, _payload}, socket) do
    case list_loaded_activity_feed_pages(
           socket.assigns.current_scope,
           socket.assigns.activity_feed_pages_loaded
         ) do
      {:ok, activity_feed_page} ->
        {:noreply,
         socket
         |> assign(:activity_next_cursor, activity_feed_page.next_cursor)
         |> refresh_activity_preview()
         |> stream(:activity_items, activity_feed_page.items, reset: true)}

      {:error, _reason} ->
        {:noreply, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <Shell.app
        workspace_stream={@streams.workspaces}
        current_scope={@current_scope}
        unread_activity_count={@unread_activity_count}
        activity_preview_stream={@streams.activity_preview_items}
        direct_message_unread_count={@direct_message_unread_count}
        main_state={:activity}
      >
        <section
          id="activity-feed-surface"
          class={["mx-auto w-full max-w-5xl px-5 py-8 sm:px-8"]}
        >
          <header class={[
            "flex flex-wrap items-end justify-between gap-4 border-b border-base-300 pb-6"
          ]}>
            <div>
              <div class={["flex items-center gap-2 text-primary"]}>
                <.icon name="hero-bell" class="size-4" />
                <p class={["text-xs font-semibold uppercase tracking-[0.18em]"]}>
                  Activity Feed
                </p>
              </div>
              <h1 class={["mt-2 text-3xl font-bold tracking-tight text-base-content"]}>
                Requests for your attention
              </h1>
              <p class={["mt-2 max-w-2xl text-sm leading-6 text-base-content/60"]}>
                Mentions, Friend relationship updates, and missed Direct Calls, gathered in one
                private feed.
              </p>
            </div>
            <div class={["flex items-center gap-2"]}>
              <button
                id="activity-mark-all-read"
                type="button"
                phx-click="mark_all_activity_read"
                disabled={@unread_activity_count == 0}
                class={[
                  "inline-flex items-center gap-2 rounded-xl border px-3 py-2 text-xs font-semibold",
                  "transition duration-200 focus-visible:outline-none focus-visible:ring-2",
                  "focus-visible:ring-primary focus-visible:ring-offset-2",
                  "border-base-300 bg-base-100 text-base-content/75 hover:border-primary/30",
                  "hover:bg-primary/5 hover:text-primary",
                  "disabled:cursor-not-allowed disabled:opacity-45 disabled:hover:border-base-300",
                  "disabled:hover:bg-base-100 disabled:hover:text-base-content/75"
                ]}
              >
                <.icon name="hero-check" class="size-4" /> Mark all as read
              </button>
              <div class={[
                "rounded-full border border-base-300 bg-base-200/70 px-3 py-1.5",
                "text-xs font-semibold text-base-content/70"
              ]}>
                {@unread_activity_count} unread
              </div>
            </div>
          </header>

          <div id="activity-feed" phx-update="stream" class={["mt-6 space-y-3"]}>
            <div
              id="activity-feed-empty-state"
              class={[
                "hidden only:flex min-h-64 flex-col items-center justify-center rounded-2xl",
                "border border-dashed border-base-300 bg-base-200/35 px-6 text-center"
              ]}
            >
              <div class={[
                "flex size-12 items-center justify-center rounded-2xl bg-base-200",
                "text-base-content/50 shadow-sm ring-1 ring-base-300"
              ]}>
                <.icon name="hero-check-circle" class="size-6" />
              </div>
              <h2 class={["mt-4 text-base font-semibold"]}>You're all caught up</h2>
              <p class={["mt-1 max-w-sm text-sm leading-6 text-base-content/55"]}>
                New mentions, Friend relationship updates, and missed Direct Calls will appear here.
              </p>
            </div>

            <article
              :for={{dom_id, activity_item} <- @streams.activity_items}
              id={dom_id}
              data-read-state={if(activity_item.read_at, do: "read", else: "unread")}
              data-source-kind={activity_source_kind(activity_item)}
              class={[
                "group rounded-2xl border shadow-sm transition duration-200",
                "hover:-translate-y-0.5 hover:border-primary/30 hover:shadow-md",
                if(activity_item.read_at,
                  do: "border-base-300/70 bg-base-100/65",
                  else: "border-primary/20 bg-base-100 ring-1 ring-primary/5"
                )
              ]}
            >
              <button
                id={"#{dom_id}-open"}
                type="button"
                phx-click="open_activity_item"
                phx-value-activity-item-id={activity_item.id}
                aria-label={activity_open_label(activity_item)}
                class={[
                  "flex w-full gap-4 rounded-2xl p-5 text-left",
                  "transition-colors duration-200 focus-visible:outline-none",
                  "focus-visible:ring-2 focus-visible:ring-primary focus-visible:ring-offset-2",
                  "hover:bg-base-200/35"
                ]}
              >
                <div class={[
                  "flex size-10 shrink-0 items-center justify-center rounded-xl",
                  if(activity_item.read_at,
                    do: "bg-base-200 text-base-content/40 ring-1 ring-base-300",
                    else: "bg-primary/10 text-primary ring-1 ring-primary/15"
                  )
                ]}>
                  <.icon name={activity_icon(activity_item)} class="size-5" />
                </div>
                <div class={["min-w-0 flex-1"]}>
                  <div class={["flex flex-wrap items-center justify-between gap-2"]}>
                    <div class={[
                      "flex min-w-0 flex-wrap items-center gap-x-2 gap-y-1 text-sm"
                    ]}>
                      <span data-role="actor" class={["font-semibold text-base-content"]}>
                        {actor_name(activity_item)}
                      </span>
                      <span class="text-base-content/35" aria-hidden="true">·</span>
                      <span data-role="kind" class={["font-medium text-primary"]}>
                        {activity_kind_label(activity_item.kind)}
                      </span>
                    </div>
                    <time class={["text-xs font-medium text-base-content/45"]}>
                      {activity_time(activity_item.inserted_at)}
                    </time>
                  </div>

                  <%= cond do %>
                    <% activity_item.source_message && activity_item.workspace -> %>
                      <div class={[
                        "mt-1 flex flex-wrap items-center gap-1.5 text-xs font-medium",
                        "text-base-content/55"
                      ]}>
                        <span data-role="workspace">{activity_item.workspace.name}</span>
                        <span aria-hidden="true">/</span>
                        <span data-role="channel">#{activity_item.source_channel.name}</span>
                      </div>
                    <% activity_item.kind in ["direct_message", "missed_direct_call"] -> %>
                      <p
                        data-role="direct-conversation"
                        class="mt-1 text-xs font-medium text-base-content/55"
                      >
                        Direct Conversation with {actor_name(activity_item)}
                      </p>
                    <% true -> %>
                      <p
                        data-role="relationship"
                        class="mt-1 text-xs font-medium text-base-content/55"
                      >
                        Friend relationship
                      </p>
                  <% end %>

                  <p
                    data-role="preview"
                    class={[
                      "mt-3 whitespace-pre-wrap break-words rounded-xl bg-base-200/60 px-4 py-3",
                      "text-sm leading-6 text-base-content/80 ring-1 ring-base-300/60"
                    ]}
                  >
                    {activity_preview(activity_item)}
                  </p>
                </div>
              </button>
            </article>
          </div>

          <div :if={@activity_next_cursor} id="activity-load-older-control" class={["pt-5"]}>
            <button
              id="activity-load-older"
              type="button"
              phx-click="load_older_activity"
              class={[
                "mx-auto flex items-center gap-2 rounded-xl border border-base-300 bg-base-100",
                "px-4 py-2.5 text-sm font-semibold text-base-content/70 shadow-sm",
                "transition duration-200 hover:border-primary/30 hover:bg-primary/5 hover:text-primary",
                "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary",
                "focus-visible:ring-offset-2"
              ]}
            >
              <.icon name="hero-arrow-down" class="size-4" /> Load older activity
            </button>
          </div>
        </section>
      </Shell.app>
    </Layouts.app>
    """
  end

  defp actor_name(%{actor_user: %{username: username}}), do: username
  defp actor_name(_activity_item), do: "Former member"

  defp activity_kind_label("user_mention"), do: "Direct mention"
  defp activity_kind_label("everyone_mention"), do: "Everyone mention"
  defp activity_kind_label("friend_request_received"), do: "Sent you a Friend Request"
  defp activity_kind_label("friend_request_accepted"), do: "Accepted your Friend Request"
  defp activity_kind_label("direct_message"), do: "Sent you a Direct Message"
  defp activity_kind_label("missed_direct_call"), do: "Missed a Direct Call"
  defp activity_kind_label(_kind), do: "Activity"

  defp activity_source_kind(%{kind: "direct_message"}), do: "direct-message"
  defp activity_source_kind(%{kind: "missed_direct_call"}), do: "missed-direct-call"
  defp activity_source_kind(%{source_friend_relationship_id: nil}), do: "message"
  defp activity_source_kind(_activity_item), do: "friend-relationship"

  defp activity_open_label(%{source_channel: %{name: name}}), do: "Open activity in ##{name}"
  defp activity_open_label(%{kind: "direct_message"}), do: "Open Direct Message activity"
  defp activity_open_label(%{kind: "missed_direct_call"}), do: "Open missed Direct Call activity"
  defp activity_open_label(_activity_item), do: "Open Friend relationship activity"

  defp activity_icon(%{kind: "direct_message"}), do: "hero-chat-bubble-left-right"
  defp activity_icon(%{kind: "missed_direct_call"}), do: "hero-phone-x-mark"
  defp activity_icon(%{source_friend_relationship_id: nil}), do: "hero-at-symbol"
  defp activity_icon(_activity_item), do: "hero-user-plus"

  defp activity_preview(%{source_message: %{content: content}}), do: content
  defp activity_preview(%{kind: "friend_request_received"}), do: "Review your incoming requests."
  defp activity_preview(%{kind: "friend_request_accepted"}), do: "Your Friendship is now active."
  defp activity_preview(%{kind: "missed_direct_call"}), do: "This Direct Call was missed."
  defp activity_preview(_activity_item), do: "Open this activity for details."

  defp activity_time(%DateTime{} = datetime), do: Calendar.strftime(datetime, "%b %-d, %H:%M")

  defp list_loaded_activity_feed_pages(scope, page_count) do
    load_activity_feed_pages(scope, page_count, nil, [])
  end

  defp refresh_activity_summary({:activity_changed, _payload}, %{view: __MODULE__} = socket) do
    {:cont, assign_unread_activity_count(socket)}
  end

  defp refresh_activity_summary({:activity_changed, _payload}, socket) do
    {:halt, assign_activity_summary(socket)}
  end

  defp refresh_activity_summary(_message, socket), do: {:cont, socket}

  defp assign_activity_summary(socket) do
    {:ok, unread_count} = Chat.unread_activity_count(socket.assigns.current_scope)

    socket
    |> assign(:unread_activity_count, unread_count)
    |> refresh_activity_preview()
  end

  defp refresh_activity_preview(socket) do
    {:ok, activity_preview_items} =
      Chat.list_activity_preview(socket.assigns.current_scope, @activity_preview_limit)

    stream(socket, :activity_preview_items, activity_preview_items, reset: true)
  end

  defp handle_activity_preview_event(
         "open_activity_preview_item",
         %{"activity-item-id" => activity_item_id},
         socket
       ) do
    socket =
      case Chat.open_activity_item(socket.assigns.current_scope, activity_item_id) do
        {:ok, destination} ->
          socket
          |> assign_unread_activity_count()
          |> push_navigate(to: activity_destination_path(destination))

        {:error, _reason} ->
          put_flash(socket, :error, "Activity is no longer available.")
      end

    {:halt, socket}
  end

  defp handle_activity_preview_event(_event, _params, socket), do: {:cont, socket}

  defp assign_activity_shell(socket, __MODULE__), do: assign_unread_activity_count(socket)
  defp assign_activity_shell(socket, _view), do: assign_activity_summary(socket)

  defp assign_unread_activity_count(socket) do
    {:ok, unread_count} = Chat.unread_activity_count(socket.assigns.current_scope)
    assign(socket, :unread_activity_count, unread_count)
  end

  defp activity_destination_path(%{
         workspace_id: workspace_id,
         channel_id: channel_id,
         message_id: message_id
       }) do
    ~p"/workspaces/#{workspace_id}/channels/#{channel_id}?message_id=#{message_id}"
  end

  defp activity_destination_path(%{
         direct_conversation_id: direct_conversation_id,
         message_id: message_id
       }) do
    ~p"/direct-messages/#{direct_conversation_id}?message_id=#{message_id}"
  end

  defp activity_destination_path(%{direct_conversation_id: direct_conversation_id}) do
    ~p"/direct-messages/#{direct_conversation_id}"
  end

  defp activity_destination_path(%{friends_section: :incoming_requests}),
    do: ~p"/friends" <> "#incoming-requests"

  defp activity_destination_path(%{friends_section: :friends}),
    do: ~p"/friends" <> "#friends-list"

  defp activity_consumer?(view) do
    view in [
      __MODULE__,
      DiscordCloneWeb.ChannelLive.Show,
      DiscordCloneWeb.DirectConversationLive,
      DiscordCloneWeb.FriendsLive,
      DiscordCloneWeb.WorkspaceLive.AuditLog,
      DiscordCloneWeb.WorkspaceLive.Entry,
      DiscordCloneWeb.WorkspaceLive.Home,
      DiscordCloneWeb.WorkspaceLive.InviteNew
    ]
  end

  defp load_activity_feed_pages(_scope, 0, next_cursor, feed_pages) do
    {:ok, %{items: feed_pages |> Enum.reverse() |> List.flatten(), next_cursor: next_cursor}}
  end

  defp load_activity_feed_pages(scope, pages_remaining, cursor, feed_pages) do
    case Chat.list_activity_feed(scope, cursor) do
      {:ok, activity_feed_page} ->
        next_feed_pages = [activity_feed_page.items | feed_pages]

        if activity_feed_page.next_cursor do
          load_activity_feed_pages(
            scope,
            pages_remaining - 1,
            activity_feed_page.next_cursor,
            next_feed_pages
          )
        else
          load_activity_feed_pages(scope, 0, nil, next_feed_pages)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
end
