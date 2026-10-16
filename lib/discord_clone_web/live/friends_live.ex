defmodule DiscordCloneWeb.FriendsLive do
  @moduledoc false

  use DiscordCloneWeb, :live_view

  alias DiscordClone.{Chat, Friendships, Presence, Workspaces}
  alias DiscordCloneWeb.DirectMessagesLive.Shell, as: DirectMessagesShell
  alias DiscordCloneWeb.WorkspaceLive.WorkspaceManagementEvents

  @empty_form %{"username" => ""}

  @impl true
  def mount(_params, _session, socket) do
    {:ok, workspaces} = Workspaces.list_workspaces(socket.assigns.current_scope)

    {:ok, incoming_requests} =
      Friendships.list_incoming_requests(socket.assigns.current_scope)

    {:ok, outgoing_requests} =
      Friendships.list_outgoing_requests(socket.assigns.current_scope)

    {:ok, friends} = Friendships.list_friends(socket.assigns.current_scope)
    {:ok, online_friend_ids} = Presence.list_online_friend_ids(socket.assigns.current_scope)

    if connected?(socket) do
      :ok = Friendships.subscribe(socket.assigns.current_scope)
      subscribe_to_friend_presence(socket.assigns.current_scope, friends)
    end

    {:ok,
     socket
     |> assign(:form, to_form(@empty_form, as: :friend_request))
     |> assign(:request_outcome, nil)
     |> assign(
       :workspace_form,
       WorkspaceManagementEvents.workspace_form(socket.assigns.current_scope)
     )
     |> assign(:show_workspace_form?, false)
     |> assign(:online_friend_ids, MapSet.new(online_friend_ids))
     |> stream(:workspaces, workspaces)
     |> stream_configure(:incoming_requests,
       dom_id: &"incoming-request-#{&1.relationship.id}"
     )
     |> stream(:incoming_requests, incoming_requests)
     |> stream_configure(:outgoing_requests,
       dom_id: &"outgoing-request-#{&1.relationship.id}"
     )
     |> stream(:outgoing_requests, outgoing_requests)
     |> stream_configure(:friends, dom_id: &"friendship-#{&1.relationship.id}")
     |> stream(:friends, friends)}
  end

  def handle_event("accept_friend_request", %{"relationship_id" => relationship_id}, socket) do
    handle_mutation(
      Friendships.accept_friend_request(socket.assigns.current_scope, relationship_id),
      socket,
      "Friend Request accepted."
    )
  end

  def handle_event("decline_friend_request", %{"relationship_id" => relationship_id}, socket) do
    handle_mutation(
      Friendships.decline_friend_request(socket.assigns.current_scope, relationship_id),
      socket,
      "Friend Request declined."
    )
  end

  def handle_event("cancel_friend_request", %{"relationship_id" => relationship_id}, socket) do
    handle_mutation(
      Friendships.cancel_friend_request(socket.assigns.current_scope, relationship_id),
      socket,
      "Friend Request cancelled."
    )
  end

  def handle_event("remove_friend", %{"relationship_id" => relationship_id}, socket) do
    handle_mutation(
      Friendships.remove_friend(socket.assigns.current_scope, relationship_id),
      socket,
      "Friendship removed."
    )
  end

  def handle_event("message_friend", %{"user_id" => friend_user_id}, socket) do
    case Chat.open_direct_conversation(socket.assigns.current_scope, friend_user_id) do
      {:ok, direct_conversation} ->
        {:noreply, push_navigate(socket, to: ~p"/direct-messages/#{direct_conversation.id}")}

      {:error, _reason} ->
        {:noreply,
         assign(socket, :request_outcome, {:error, "Direct Conversation could not be opened."})}
    end
  end

  def handle_event("show_workspace_form", _params, socket),
    do: WorkspaceManagementEvents.show_workspace_form(socket)

  def handle_event("cancel_workspace_form", _params, socket),
    do: WorkspaceManagementEvents.cancel_workspace_form(socket)

  def handle_event("create_workspace", %{"workspace" => workspace_params}, socket),
    do: WorkspaceManagementEvents.create_workspace(socket, %{"workspace" => workspace_params})

  @impl true
  def handle_event("send_friend_request", %{"friend_request" => params}, socket) do
    case Friendships.send_friend_request(socket.assigns.current_scope, params) do
      {:ok, result} ->
        outcome =
          if result.relationship.status == :accepted do
            {:success, "You and @#{result.user.username} are now friends."}
          else
            {:success, "Friend Request sent to @#{result.user.username}."}
          end

        {:noreply,
         socket
         |> assign(:form, to_form(@empty_form, as: :friend_request))
         |> assign(:request_outcome, outcome)
         |> refresh_request_streams()}

      {:error, :unknown_user} ->
        {:noreply, assign(socket, :request_outcome, {:error, "No User has that exact username."})}

      {:error, :self_request} ->
        {:noreply,
         assign(socket, :request_outcome, {:error, "You cannot send yourself a Friend Request."})}

      {:error, :invalid_username} ->
        {:noreply, assign(socket, :request_outcome, {:error, "Enter an exact username."})}

      {:error, _reason} ->
        {:noreply,
         assign(socket, :request_outcome, {:error, "Friend Request could not be sent."})}
    end
  end

  @impl true
  def handle_info({:friendships_changed, _payload}, socket) do
    {:noreply, refresh_relationship_streams(socket)}
  end

  def handle_info({:friend_presence_changed, %{user_id: user_id, state: state}}, socket) do
    if Friendships.friends?(socket.assigns.current_scope, user_id) do
      online_friend_ids =
        update_online_friend_ids(socket.assigns.online_friend_ids, user_id, state)

      {:noreply,
       socket
       |> assign(:online_friend_ids, online_friend_ids)
       |> refresh_friends_stream()}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

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
        current_action={friends_action(@live_action)}
      >
        <:member_panel>
          <.friend_members_panel
            stream={@streams.friends}
            online_user_ids={@online_friend_ids}
          />
        </:member_panel>

        <main id="friends-home" class={["min-h-full bg-base-200/45 px-5 py-10 sm:px-8"]}>
          <div class={["mx-auto w-full max-w-5xl"]}>
            <header class={["mb-8 flex flex-col gap-3"]}>
              <div class={["flex items-center gap-2 text-primary"]}>
                <.icon name="hero-user-group" class="size-5" />
                <span class={["text-xs font-bold uppercase tracking-[0.2em]"]}>Friends</span>
              </div>
            </header>

            <section class={["rounded-3xl border border-base-300 bg-base-100 p-5 shadow-sm sm:p-7"]}>
              <div class={["flex items-center gap-3"]}>
                <div class={[
                  "flex size-10 items-center justify-center rounded-2xl bg-primary/10 text-primary"
                ]}>
                  <.icon name="hero-user-plus" class="size-5" />
                </div>
                <div>
                  <h2 class={["font-semibold text-base-content"]}>Send a Friend Request</h2>
                  <p class={["text-xs text-base-content/55"]}>Exact username matching only</p>
                </div>
              </div>

              <.form
                for={@form}
                id="friend-request-form"
                phx-submit="send_friend_request"
                class={["mt-5 flex flex-col gap-3 sm:flex-row sm:items-end"]}
              >
                <div class={["min-w-0 flex-1"]}>
                  <.input
                    field={@form[:username]}
                    type="text"
                    label="Global username"
                    placeholder="exact_username"
                    autocomplete="off"
                    required
                  />
                </div>
                <button
                  id="send-friend-request-button"
                  type="submit"
                  phx-disable-with="Sending request…"
                  class={[
                    "inline-flex h-11 items-center justify-center gap-2 rounded-xl bg-primary px-5",
                    "text-sm font-semibold text-primary-content shadow-sm transition duration-200",
                    "hover:-translate-y-0.5 hover:shadow-md focus-visible:outline-none",
                    "focus-visible:ring-2 focus-visible:ring-primary focus-visible:ring-offset-2"
                  ]}
                >
                  <.icon name="hero-paper-airplane" class="size-4" /> Send request
                </button>
              </.form>

              <%= if @request_outcome do %>
                <div
                  id="friend-request-outcome"
                  data-kind={elem(@request_outcome, 0)}
                  class={[
                    "mt-4 rounded-xl border px-4 py-3 text-sm",
                    elem(@request_outcome, 0) == :success &&
                      "border-success/25 bg-success/10 text-success",
                    elem(@request_outcome, 0) == :error &&
                      "border-error/25 bg-error/10 text-error"
                  ]}
                >
                  {elem(@request_outcome, 1)}
                </div>
              <% end %>
            </section>

            <div class={["mt-7 grid gap-6 lg:grid-cols-2"]}>
              <.relationship_panel
                id="incoming-requests"
                title="Incoming"
                subtitle="Friend Requests waiting for you"
                empty="No incoming requests"
                icon="hero-inbox-arrow-down"
                stream={@streams.incoming_requests}
                direction={:incoming}
              />
              <.relationship_panel
                id="outgoing-requests"
                title="Outgoing"
                subtitle="Friend Requests you have sent"
                empty="No outgoing requests"
                icon="hero-paper-airplane"
                stream={@streams.outgoing_requests}
                direction={:outgoing}
              />
            </div>
          </div>
        </main>
      </DirectMessagesShell.app>
    </Layouts.app>
    """
  end

  defp friends_action(:requests), do: :requests
  defp friends_action(_action), do: :friends

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :subtitle, :string, required: true
  attr :empty, :string, required: true
  attr :icon, :string, required: true
  attr :stream, :any, required: true
  attr :direction, :atom, required: true
  attr :online_user_ids, :any, default: MapSet.new()

  defp relationship_panel(assigns) do
    ~H"""
    <section class={["overflow-hidden rounded-3xl border border-base-300 bg-base-100 shadow-sm"]}>
      <header class={["flex items-center gap-3 border-b border-base-300 px-5 py-4"]}>
        <div class={[
          "flex size-9 items-center justify-center rounded-xl bg-base-200 text-base-content/60"
        ]}>
          <.icon name={@icon} class="size-4" />
        </div>
        <div>
          <h2 class={["text-sm font-semibold text-base-content"]}>{@title}</h2>
          <p class={["text-xs text-base-content/50"]}>{@subtitle}</p>
        </div>
      </header>
      <div id={@id} phx-update="stream" class={["divide-y divide-base-300"]}>
        <div
          id={"#{@id}-empty-state"}
          class={[
            "hidden only:flex items-center justify-center px-5 py-12 text-sm text-base-content/45"
          ]}
        >
          {@empty}
        </div>
        <article
          :for={{dom_id, relationship_entry} <- @stream}
          id={dom_id}
          data-presence-state={presence_state(@direction, relationship_entry, @online_user_ids)}
          class={["group flex items-center gap-3 px-5 py-4 transition hover:bg-base-200/50"]}
        >
          <div class={[
            "flex size-10 items-center justify-center rounded-full bg-primary/10 font-bold text-primary"
          ]}>
            {relationship_entry.user.username |> String.first() |> String.upcase()}
          </div>
          <div class={["min-w-0 flex-1"]}>
            <p class={["truncate text-sm font-semibold text-base-content"]}>
              @{relationship_entry.user.username}
            </p>
            <p class={["text-xs text-base-content/45"]}>
              {relationship_label(@direction, relationship_entry, @online_user_ids)}
            </p>
          </div>
          <span class={[
            "size-2 rounded-full ring-4",
            @direction == :friends &&
              presence_state(@direction, relationship_entry, @online_user_ids) == "online" &&
              "bg-success ring-success/10",
            @direction == :friends &&
              presence_state(@direction, relationship_entry, @online_user_ids) == "offline" &&
              "bg-base-content/25 ring-base-content/5",
            @direction != :friends && "bg-warning ring-warning/10"
          ]} />
          <div :if={@direction == :incoming} class={["flex shrink-0 items-center gap-2"]}>
            <button
              id={"decline-friend-request-#{relationship_entry.relationship.id}"}
              type="button"
              phx-click="decline_friend_request"
              phx-value-relationship_id={relationship_entry.relationship.id}
              class={[
                "rounded-lg px-3 py-2 text-xs font-semibold text-base-content/60 transition",
                "hover:bg-base-300 hover:text-base-content"
              ]}
            >
              Decline
            </button>
            <button
              id={"accept-friend-request-#{relationship_entry.relationship.id}"}
              type="button"
              phx-click="accept_friend_request"
              phx-value-relationship_id={relationship_entry.relationship.id}
              class={[
                "rounded-lg bg-primary px-3 py-2 text-xs font-semibold text-primary-content",
                "transition hover:-translate-y-0.5 hover:shadow-sm"
              ]}
            >
              Accept
            </button>
          </div>
          <button
            :if={@direction == :outgoing}
            id={"cancel-friend-request-#{relationship_entry.relationship.id}"}
            type="button"
            phx-click="cancel_friend_request"
            phx-value-relationship_id={relationship_entry.relationship.id}
            class={[
              "shrink-0 rounded-lg px-3 py-2 text-xs font-semibold text-base-content/60",
              "transition hover:bg-base-300 hover:text-base-content"
            ]}
          >
            Cancel
          </button>
          <div :if={@direction == :friends} class={["flex shrink-0 items-center gap-2"]}>
            <button
              id={"message-friend-#{relationship_entry.user.id}"}
              type="button"
              phx-click="message_friend"
              phx-value-user_id={relationship_entry.user.id}
              class={[
                "inline-flex items-center gap-1.5 rounded-lg bg-primary px-3 py-2",
                "text-xs font-semibold text-primary-content shadow-sm transition",
                "hover:-translate-y-0.5 hover:shadow-md focus-visible:outline-none",
                "focus-visible:ring-2 focus-visible:ring-primary focus-visible:ring-offset-2"
              ]}
            >
              <.icon name="hero-chat-bubble-left-right" class="size-4" /> Message
            </button>
          </div>
        </article>
      </div>
    </section>
    """
  end

  attr :stream, :any, required: true
  attr :online_user_ids, :any, required: true

  defp friend_members_panel(assigns) do
    ~H"""
    <aside
      id="friends-members-sidebar"
      aria-label="Friends"
      class="hidden min-h-0 bg-base-200/80 shadow-[inset_1px_0_0_rgb(255_255_255/0.04)] xl:flex xl:flex-col"
    >
      <div id="friends-list" phx-update="stream" class="min-h-0 flex-1 space-y-1 overflow-y-auto p-3">
        <div
          id="friends-list-empty-state"
          class="hidden only:flex min-h-32 flex-col items-center justify-center rounded-xl px-4 text-center text-xs leading-5 text-base-content/45"
        >
          <.icon name="hero-user-group" class="mb-2 size-6" /> No friends yet
        </div>
        <article
          :for={{dom_id, relationship_entry} <- @stream}
          id={dom_id}
          data-presence-state={presence_state(:friends, relationship_entry, @online_user_ids)}
          class="group flex items-center gap-3 rounded px-2 py-2 text-sm transition hover:bg-base-300/80"
        >
          <div class={[
            "flex size-8 shrink-0 items-center justify-center rounded text-xs font-semibold",
            presence_state(:friends, relationship_entry, @online_user_ids) == "online" &&
              "bg-primary/15 text-primary",
            presence_state(:friends, relationship_entry, @online_user_ids) == "offline" &&
              "bg-base-300 text-base-content/70"
          ]}>
            {relationship_entry.user.username |> String.first() |> String.upcase()}
          </div>
          <div class="min-w-0 flex-1">
            <p class="truncate font-medium">{relationship_entry.user.username}</p>
            <p class={[
              "flex items-center gap-1.5 text-xs",
              presence_state(:friends, relationship_entry, @online_user_ids) == "online" &&
                "text-primary",
              presence_state(:friends, relationship_entry, @online_user_ids) == "offline" &&
                "text-base-content/45"
            ]}>
              <span class={[
                "size-2 rounded-full",
                presence_state(:friends, relationship_entry, @online_user_ids) == "online" &&
                  "bg-primary",
                presence_state(:friends, relationship_entry, @online_user_ids) == "offline" &&
                  "bg-base-content/30"
              ]}>
              </span>
              {relationship_label(:friends, relationship_entry, @online_user_ids)}
            </p>
          </div>
          <div class="flex shrink-0 items-center gap-1">
            <button
              id={"message-friend-#{relationship_entry.user.id}"}
              type="button"
              phx-click="message_friend"
              phx-value-user_id={relationship_entry.user.id}
              class="btn btn-square btn-xs btn-ghost"
              aria-label={"Message #{relationship_entry.user.username}"}
            >
              <.icon name="hero-chat-bubble-left-right" class="size-4" />
            </button>
          </div>
        </article>
      </div>
    </aside>
    """
  end

  defp refresh_request_streams(socket), do: refresh_relationship_streams(socket)

  defp refresh_relationship_streams(socket) do
    {:ok, incoming_requests} = Friendships.list_incoming_requests(socket.assigns.current_scope)
    {:ok, outgoing_requests} = Friendships.list_outgoing_requests(socket.assigns.current_scope)
    {:ok, friends} = Friendships.list_friends(socket.assigns.current_scope)
    {:ok, online_friend_ids} = Presence.list_online_friend_ids(socket.assigns.current_scope)

    if connected?(socket), do: subscribe_to_friend_presence(socket.assigns.current_scope, friends)

    socket
    |> assign(:online_friend_ids, MapSet.new(online_friend_ids))
    |> stream(:incoming_requests, incoming_requests, reset: true)
    |> stream(:outgoing_requests, outgoing_requests, reset: true)
    |> stream(:friends, friends, reset: true)
  end

  defp refresh_friends_stream(socket) do
    {:ok, friends} = Friendships.list_friends(socket.assigns.current_scope)
    stream(socket, :friends, friends, reset: true)
  end

  defp subscribe_to_friend_presence(scope, friends) do
    Enum.each(friends, fn friend -> :ok = Presence.subscribe_to_friend(scope, friend.user.id) end)
  end

  defp update_online_friend_ids(online_friend_ids, user_id, :online),
    do: MapSet.put(online_friend_ids, user_id)

  defp update_online_friend_ids(online_friend_ids, user_id, :offline),
    do: MapSet.delete(online_friend_ids, user_id)

  defp handle_mutation(result, socket, success_message) do
    case result do
      :ok ->
        {:noreply,
         socket
         |> assign(:request_outcome, {:success, success_message})
         |> refresh_relationship_streams()}

      {:ok, _relationship} ->
        {:noreply,
         socket
         |> assign(:request_outcome, {:success, success_message})
         |> refresh_relationship_streams()}

      {:error, reason} when reason in [:not_found, :stale_state] ->
        {:noreply,
         socket
         |> assign(
           :request_outcome,
           {:error, "That relationship changed. The lists were refreshed."}
         )
         |> refresh_relationship_streams()}

      {:error, _reason} ->
        {:noreply,
         assign(socket, :request_outcome, {:error, "That relationship action is not allowed."})}
    end
  end

  defp relationship_label(:incoming, _entry, _online_user_ids), do: "Wants to be friends"
  defp relationship_label(:outgoing, _entry, _online_user_ids), do: "Request pending"

  defp relationship_label(:friends, entry, online_user_ids) do
    if MapSet.member?(online_user_ids, entry.user.id), do: "Online", else: "Offline"
  end

  defp presence_state(:friends, entry, online_user_ids) do
    if MapSet.member?(online_user_ids, entry.user.id), do: "online", else: "offline"
  end

  defp presence_state(_direction, _entry, _online_user_ids), do: nil
end
