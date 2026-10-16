defmodule DiscordCloneWeb.WorkspaceLive.Shell do
  use DiscordCloneWeb, :html

  alias DiscordClone.Workspaces
  alias DiscordCloneWeb.GlobalDestinationRail
  alias DiscordCloneWeb.WorkspaceLive.MemberActionsMenu

  attr :workspace_stream, :any, required: true
  attr :channel_stream, :any, default: nil
  attr :voice_channel_stream, :any, default: nil
  attr :voice_channel_rosters, :map, default: %{}
  attr :member_by_user_id, :map, default: %{}
  attr :selected_workspace, :any, default: nil
  attr :selected_channel, :any, default: nil
  attr :member_stream, :any, default: []
  attr :workspace_form, :any, default: nil
  attr :show_workspace_form?, :boolean, default: false
  attr :workspace_action_menu_id, :string, default: nil
  attr :renaming_workspace_id, :string, default: nil
  attr :workspace_rename_form, :any, default: nil
  attr :channel_form, :any, default: nil
  attr :show_channel_form?, :boolean, default: false
  attr :channel_action_menu_id, :string, default: nil
  attr :renaming_channel_id, :string, default: nil
  attr :channel_rename_form, :any, default: nil
  attr :voice_channel_form, :any, default: nil
  attr :show_voice_channel_form?, :boolean, default: false
  attr :voice_channel_action_menu_id, :string, default: nil
  attr :renaming_voice_channel_id, :string, default: nil
  attr :voice_channel_rename_form, :any, default: nil
  attr :context_menu_position, :map, default: nil
  attr :current_scope, :any, default: nil
  attr :main_state, :atom, default: :no_workspace
  attr :invite_form, :any, default: nil
  attr :invite_url, :string, default: nil
  attr :audit_events, :list, default: []
  attr :banned_members, :list, default: []
  attr :online_user_ids, :any, default: MapSet.new()
  attr :channel_unread_counts, :map, default: %{}
  attr :unread_activity_count, :integer, default: 0
  attr :activity_preview_stream, :any, default: []
  attr :direct_message_unread_count, :integer, default: 0

  slot :inner_block

  def app(assigns) do
    ~H"""
    <div
      id="workspace-app-shell"
      class={workspace_shell_class(@show_workspace_form?)}
    >
      <GlobalDestinationRail.rail
        workspace_stream={@workspace_stream}
        selected_workspace={@selected_workspace}
        workspace_form={@workspace_form}
        show_workspace_form?={@show_workspace_form?}
        direct_message_unread_count={@direct_message_unread_count}
        unread_activity_count={@unread_activity_count}
        activity_preview_stream={@activity_preview_stream}
      />

      <aside
        id="channel-sidebar"
        class="flex min-h-0 flex-col border-b border-base-300/60 bg-base-200 shadow-[inset_-1px_0_0_rgb(255_255_255/0.04)] lg:border-b-0 lg:border-r"
      >
        <div class="min-h-0 flex-1 overflow-y-auto px-3 py-4">
          <%= if @selected_workspace do %>
            <div class="mb-4">
              <div class="relative flex items-center justify-between gap-2">
                <%= if @renaming_workspace_id == @selected_workspace.id && @workspace_rename_form do %>
                  <.form
                    for={@workspace_rename_form}
                    id={"workspace-#{@selected_workspace.id}-rename-form"}
                    phx-submit="rename_workspace"
                    phx-value-workspace_id={@selected_workspace.id}
                    class="min-w-0 flex-1"
                  >
                    <.input
                      field={@workspace_rename_form[:name]}
                      type="text"
                      label="Workspace name"
                      autocomplete="off"
                    />
                  </.form>
                <% else %>
                  <p id="selected-workspace-name" class="min-w-0 truncate text-sm font-semibold">
                    {@selected_workspace.name}
                  </p>
                <% end %>
                <button
                  :if={
                    not (@renaming_workspace_id == @selected_workspace.id &&
                           not is_nil(@workspace_rename_form))
                  }
                  id={"workspace-#{@selected_workspace.id}-actions"}
                  type="button"
                  class="btn btn-square btn-xs btn-ghost shrink-0 transition hover:scale-105"
                  phx-click="open_workspace_actions"
                  phx-value-workspace_id={@selected_workspace.id}
                  aria-label={"Open #{@selected_workspace.name} workspace actions"}
                >
                  <.icon name="hero-ellipsis-horizontal" class="size-4" />
                </button>
                <div
                  :if={@workspace_action_menu_id == @selected_workspace.id}
                  id={"workspace-#{@selected_workspace.id}-menu"}
                  style={context_menu_style(@context_menu_position)}
                  class={menu_class(@context_menu_position, "absolute right-0 top-8", "w-44")}
                  phx-click-away="close_context_menu"
                  phx-window-keydown="close_context_menu"
                  phx-key="escape"
                >
                  <.link
                    :if={can_create_workspace_invite?(@selected_workspace, @current_scope)}
                    id={"workspace-#{@selected_workspace.id}-invite-new"}
                    navigate={~p"/workspaces/#{@selected_workspace.id}/invites/new"}
                    class="block w-full rounded px-3 py-2 text-left text-sm transition hover:bg-base-200"
                    aria-label={"Create invite for #{@selected_workspace.name}"}
                  >
                    Invite
                  </.link>
                  <.link
                    :if={can_view_audit_log?(@selected_workspace, @current_scope)}
                    id={"workspace-#{@selected_workspace.id}-audit-log"}
                    navigate={~p"/workspaces/#{@selected_workspace.id}/audit-log"}
                    class="block w-full rounded px-3 py-2 text-left text-sm transition hover:bg-base-200"
                    aria-label={"View audit log for #{@selected_workspace.name}"}
                  >
                    Audit log
                  </.link>
                  <button
                    :if={can_rename_workspace?(@selected_workspace, @current_scope)}
                    id={"workspace-#{@selected_workspace.id}-rename"}
                    type="button"
                    class="block w-full rounded px-3 py-2 text-left text-sm transition hover:bg-base-200"
                    phx-click="begin_workspace_rename"
                    phx-value-workspace_id={@selected_workspace.id}
                  >
                    Rename
                  </button>
                  <button
                    :if={can_delete_workspace?(@selected_workspace, @current_scope)}
                    id={"workspace-#{@selected_workspace.id}-delete"}
                    type="button"
                    class="block w-full rounded px-3 py-2 text-left text-sm text-error transition hover:bg-error/10"
                    phx-click="delete_workspace"
                    phx-value-workspace_id={@selected_workspace.id}
                    phx-confirm="Delete this workspace? The workspace and all contained channels/messages will be removed."
                  >
                    Delete workspace
                  </button>
                  <button
                    :if={!can_delete_workspace?(@selected_workspace, @current_scope)}
                    id={"workspace-#{@selected_workspace.id}-leave"}
                    type="button"
                    class="block w-full rounded px-3 py-2 text-left text-sm text-error transition hover:bg-error/10"
                    phx-click="leave_workspace"
                    phx-value-workspace_id={@selected_workspace.id}
                    phx-confirm="Leave this workspace? You will lose access and need a new invite to return."
                  >
                    Leave workspace
                  </button>
                </div>
              </div>
              <div class="mt-1 flex items-center justify-between gap-2">
                <p class="text-xs font-semibold uppercase tracking-wide text-base-content/50">
                  Channels
                </p>
                <button
                  :if={
                    @channel_form && !@show_channel_form? &&
                      can_create_channel?(@selected_workspace, @current_scope)
                  }
                  id="channel-create-toggle"
                  type="button"
                  class="btn btn-square btn-xs btn-ghost transition hover:scale-105"
                  phx-click="show_channel_form"
                  aria-label="Create channel"
                >
                  <.icon name="hero-plus" class="size-3.5" />
                </button>
              </div>
            </div>

            <div id="channels" phx-update="stream" class="space-y-1">
              <div
                id="channel-list-empty-state"
                class="hidden only:block text-sm text-base-content/60"
              >
                No channels yet.
              </div>
              <div :for={{dom_id, channel} <- @channel_stream} id={dom_id}>
                <div
                  id={"channel-#{channel.id}"}
                  aria-current={selected_channel_aria(channel, @selected_channel)}
                  phx-hook="ContextMenu"
                  data-context-menu-type="channel"
                  data-context-menu-id={channel.id}
                  class={[
                    "group relative flex items-center rounded-md text-sm transition",
                    selected_channel?(channel, @selected_channel) &&
                      "bg-base-300 font-semibold text-base-content",
                    !selected_channel?(channel, @selected_channel) &&
                      "text-base-content/70 hover:bg-base-300 hover:text-base-content"
                  ]}
                >
                  <%= if @renaming_channel_id == channel.id && @channel_rename_form do %>
                    <.form
                      for={@channel_rename_form}
                      id={"channel-#{channel.id}-rename-form"}
                      phx-submit="rename_channel"
                      phx-value-channel_id={channel.id}
                      class="min-w-0 flex-1 px-2 py-1"
                    >
                      <.input
                        field={@channel_rename_form[:name]}
                        type="text"
                        label="Channel name"
                        autocomplete="off"
                      />
                    </.form>
                  <% else %>
                    <.link
                      navigate={~p"/workspaces/#{@selected_workspace.id}/channels/#{channel.id}"}
                      class="min-w-0 flex-1 truncate py-2 pl-3 pr-16"
                    >
                      # {channel.name}
                    </.link>
                  <% end %>
                  <span
                    :if={channel_unread_count(@channel_unread_counts, channel, @selected_channel) > 0}
                    id={"channel-#{channel.id}-unread-badge"}
                    aria-label={
                      channel_unread_label(
                        channel_unread_count(@channel_unread_counts, channel, @selected_channel),
                        channel
                      )
                    }
                    class="absolute right-9 top-1/2 min-w-5 max-w-10 -translate-y-1/2 rounded-full bg-primary px-1.5 py-0.5 text-center text-[0.6875rem] font-bold leading-none text-primary-content shadow-sm ring-1 ring-primary/30"
                  >
                    {channel_unread_count(@channel_unread_counts, channel, @selected_channel)}
                  </span>
                  <button
                    :if={not (@renaming_channel_id == channel.id && not is_nil(@channel_rename_form))}
                    id={"channel-#{channel.id}-actions"}
                    type="button"
                    class="btn btn-square btn-xs btn-ghost absolute right-1 top-1/2 -translate-y-1/2 opacity-70 transition hover:opacity-100"
                    phx-click="open_channel_actions"
                    phx-value-channel_id={channel.id}
                    aria-label={"Open #{channel.name} channel actions"}
                  >
                    <.icon name="hero-ellipsis-horizontal" class="size-4" />
                  </button>
                  <div
                    :if={@channel_action_menu_id == channel.id}
                    id={"channel-#{channel.id}-menu"}
                    style={context_menu_style(@context_menu_position)}
                    class={menu_class(@context_menu_position, "absolute mt-10 ml-8", "w-36")}
                    phx-click-away="close_context_menu"
                    phx-window-keydown="close_context_menu"
                    phx-key="escape"
                  >
                    <button
                      :if={channel_has_unread?(@channel_unread_counts, channel)}
                      id={"channel-#{channel.id}-mark-read"}
                      type="button"
                      class="block w-full rounded px-3 py-2 text-left text-sm transition hover:bg-base-200"
                      phx-click="mark_sidebar_channel_read"
                      phx-value-channel_id={channel.id}
                    >
                      Mark as read
                    </button>
                    <button
                      :if={can_rename_channel?(@selected_workspace, @current_scope)}
                      id={"channel-#{channel.id}-rename"}
                      type="button"
                      class="block w-full rounded px-3 py-2 text-left text-sm transition hover:bg-base-200"
                      phx-click="begin_channel_rename"
                      phx-value-channel_id={channel.id}
                    >
                      Rename
                    </button>
                    <button
                      :if={
                        @selected_workspace.default_channel_id != channel.id &&
                          can_delete_channel?(@selected_workspace, @current_scope)
                      }
                      id={"channel-#{channel.id}-delete"}
                      type="button"
                      class="block w-full rounded px-3 py-2 text-left text-sm text-error transition hover:bg-error/10"
                      phx-click="delete_channel"
                      phx-value-channel_id={channel.id}
                      phx-confirm="Delete this channel? The channel and future messages in it will be removed."
                    >
                      Delete
                    </button>
                  </div>
                </div>
              </div>
            </div>

            <.form
              :if={
                @channel_form && @show_channel_form? &&
                  can_create_channel?(@selected_workspace, @current_scope)
              }
              for={@channel_form}
              id="channel-create-form"
              phx-submit="create_channel"
              class="mt-4 space-y-2"
            >
              <.input
                field={@channel_form[:name]}
                type="text"
                label="Channel name"
                placeholder="planning"
                autocomplete="off"
              />
              <div class="grid grid-cols-2 gap-2">
                <button
                  id="channel-create-cancel"
                  type="button"
                  class="btn btn-sm btn-ghost"
                  phx-click="cancel_channel_form"
                >
                  Cancel
                </button>
                <.button type="submit" class="btn btn-primary btn-sm">
                  Create
                </.button>
              </div>
            </.form>

            <div class="mt-5 border-t border-base-300 pt-4">
              <div class="flex items-center justify-between gap-2">
                <p class="text-xs font-semibold uppercase tracking-wide text-base-content/50">
                  Voice Channels
                </p>
                <button
                  :if={
                    @voice_channel_form && !@show_voice_channel_form? &&
                      can_create_voice_channel?(@selected_workspace, @current_scope)
                  }
                  id="voice-channel-create-toggle"
                  type="button"
                  class="btn btn-square btn-xs btn-ghost transition hover:scale-105"
                  phx-click="show_voice_channel_form"
                  aria-label="Create voice channel"
                >
                  <.icon name="hero-plus" class="size-3.5" />
                </button>
              </div>
              <div id="voice-channel-controls" class="mt-2">
                <div id="voice-channels" phx-update="stream" class="space-y-1">
                  <div
                    id="voice-channel-list-empty-state"
                    class="hidden only:block text-sm text-base-content/60"
                  >
                    No voice channels yet.
                  </div>
                  <div :for={{dom_id, voice_channel} <- @voice_channel_stream || []} id={dom_id}>
                    <% roster_members =
                      roster_members(
                        @voice_channel_rosters,
                        @member_by_user_id,
                        voice_channel.id
                      ) %>
                    <div
                      id={"voice-channel-#{voice_channel.id}"}
                      data-voice-channel-row
                      class="group relative flex items-center rounded-md text-sm text-base-content/70 transition hover:bg-base-300 hover:text-base-content"
                    >
                      <%= if @renaming_voice_channel_id == voice_channel.id && @voice_channel_rename_form do %>
                        <.form
                          for={@voice_channel_rename_form}
                          id={"voice-channel-#{voice_channel.id}-rename-form"}
                          phx-submit="rename_voice_channel"
                          phx-value-voice_channel_id={voice_channel.id}
                          class="min-w-0 flex-1 px-2 py-1"
                        >
                          <.input
                            field={@voice_channel_rename_form[:name]}
                            type="text"
                            label="Voice channel name"
                            autocomplete="off"
                          />
                        </.form>
                      <% else %>
                        <button
                          id={"voice-channel-#{voice_channel.id}-join"}
                          type="button"
                          data-voice-channel-join
                          data-voice-channel-id={voice_channel.id}
                          data-voice-channel-name={voice_channel.name}
                          data-workspace-id={@selected_workspace.id}
                          aria-label={
                            "Join voice channel #{voice_channel.name}, #{voice_channel_occupancy_label(roster_members)}"
                          }
                          aria-pressed="false"
                          class="flex min-w-0 flex-1 items-center gap-2 rounded-md py-2 pl-3 pr-10 text-left transition hover:bg-base-300"
                        >
                          <.icon name="hero-speaker-wave" class="size-4 shrink-0" />
                          <span class="min-w-0 flex-1 truncate">{voice_channel.name}</span>
                        </button>
                      <% end %>
                      <button
                        :if={
                          @voice_channel_form &&
                            not (@renaming_voice_channel_id == voice_channel.id &&
                                   not is_nil(@voice_channel_rename_form)) &&
                            (can_rename_voice_channel?(@selected_workspace, @current_scope) ||
                               can_delete_voice_channel?(@selected_workspace, @current_scope))
                        }
                        id={"voice-channel-#{voice_channel.id}-actions"}
                        type="button"
                        class="btn btn-square btn-xs btn-ghost absolute right-1 top-1/2 -translate-y-1/2 opacity-70 transition hover:opacity-100"
                        phx-click="open_voice_channel_actions"
                        phx-value-voice_channel_id={voice_channel.id}
                        aria-label={"Open #{voice_channel.name} voice channel actions"}
                      >
                        <.icon name="hero-ellipsis-horizontal" class="size-4" />
                      </button>
                      <div
                        :if={@voice_channel_action_menu_id == voice_channel.id}
                        id={"voice-channel-#{voice_channel.id}-menu"}
                        class="absolute right-0 top-8 z-30 w-36 rounded border border-base-300 bg-base-100 p-1 shadow-lg"
                        phx-click-away="close_voice_channel_context_menu"
                        phx-window-keydown="close_voice_channel_context_menu"
                        phx-key="escape"
                      >
                        <button
                          :if={can_rename_voice_channel?(@selected_workspace, @current_scope)}
                          id={"voice-channel-#{voice_channel.id}-rename"}
                          type="button"
                          class="block w-full rounded px-3 py-2 text-left text-sm transition hover:bg-base-200"
                          phx-click="begin_voice_channel_rename"
                          phx-value-voice_channel_id={voice_channel.id}
                        >
                          Rename
                        </button>
                        <button
                          :if={can_delete_voice_channel?(@selected_workspace, @current_scope)}
                          id={"voice-channel-#{voice_channel.id}-delete"}
                          type="button"
                          class="block w-full rounded px-3 py-2 text-left text-sm text-error transition hover:bg-error/10"
                          phx-click="delete_voice_channel"
                          phx-value-voice_channel_id={voice_channel.id}
                          phx-confirm="Delete this voice channel? This cannot be undone."
                        >
                          Delete
                        </button>
                      </div>
                    </div>
                    <div
                      id={"voice-channel-#{voice_channel.id}-roster"}
                      class="ml-5 space-y-1 pb-2 pt-1"
                      aria-label={"#{voice_channel.name} Voice Channel Roster: #{voice_channel_occupancy_label(roster_members)}"}
                      role="list"
                    >
                      <div
                        :for={
                          %{user_id: user_id, user: user} = member <-
                            visible_voice_roster_members(roster_members)
                        }
                        id={"voice-channel-#{voice_channel.id}-roster-member-#{user_id}"}
                        class="flex min-w-0 items-center gap-2 rounded-md px-2 py-1 text-sm text-base-content/80"
                        role="listitem"
                      >
                        <span
                          id={"voice-channel-#{voice_channel.id}-roster-member-#{user_id}-avatar"}
                          class={[
                            "flex size-5 shrink-0 items-center justify-center rounded-md bg-primary/10 text-[0.625rem] font-bold text-primary ring-1 ring-primary/15",
                            member.speaking && "ring-2 ring-emerald-400/80"
                          ]}
                          aria-hidden="true"
                          data-speaking-indicator={if(member.speaking, do: "true")}
                        >
                          {user_initial(user)}
                        </span>
                        <span class="truncate">{user.username}</span>
                        <span
                          :if={member.muted}
                          aria-label="Muted"
                          class="ml-auto shrink-0 text-base-content/45"
                        >
                          <.icon name="hero-microphone" class="size-3.5" />
                        </span>
                        <span
                          :if={member.deafened}
                          aria-label="Deafened"
                          class="shrink-0 text-base-content/45"
                        >
                          <.icon name="hero-speaker-x-mark" class="size-3.5" />
                        </span>
                        <% roster_actions =
                          roster_member_actions(
                            @current_scope,
                            @selected_workspace,
                            @member_by_user_id,
                            user_id
                          ) %>
                        <details
                          :if={roster_actions != []}
                          id={"voice-channel-#{voice_channel.id}-roster-member-#{user_id}-actions"}
                          class="relative ml-auto shrink-0"
                        >
                          <summary
                            class="btn btn-square btn-xs btn-ghost list-none transition hover:scale-105 [&::-webkit-details-marker]:hidden"
                            aria-label={"Open #{user.username} Voice Channel Roster actions"}
                          >
                            <.icon name="hero-ellipsis-horizontal" class="size-4" />
                          </summary>
                          <div class="absolute right-0 z-30 mt-1 w-40 rounded border border-base-300 bg-base-100 p-1 shadow-lg">
                            <MemberActionsMenu.menu_items
                              id_prefix={"voice-channel-#{voice_channel.id}-roster-member-#{user_id}"}
                              actions={roster_actions}
                              user_id={user_id}
                              current_scope={@current_scope}
                              workspace={@selected_workspace}
                              voice_channel_id={voice_channel.id}
                            />
                          </div>
                        </details>
                      </div>
                      <p
                        :if={voice_roster_overflow_count(roster_members) > 0}
                        id={"voice-channel-#{voice_channel.id}-roster-overflow"}
                        class="px-2 py-1 text-xs font-semibold text-base-content/55"
                        role="listitem"
                      >
                        +{voice_roster_overflow_count(roster_members)} more
                      </p>
                    </div>
                  </div>
                </div>
              </div>
              <.form
                :if={
                  @voice_channel_form && @show_voice_channel_form? &&
                    can_create_voice_channel?(@selected_workspace, @current_scope)
                }
                for={@voice_channel_form}
                id="voice-channel-create-form"
                phx-submit="create_voice_channel"
                class="mt-3 space-y-2"
              >
                <.input
                  field={@voice_channel_form[:name]}
                  type="text"
                  label="Voice channel name"
                  placeholder="lobby"
                  autocomplete="off"
                />
                <div class="grid grid-cols-2 gap-2">
                  <button
                    id="voice-channel-create-cancel"
                    type="button"
                    class="btn btn-sm btn-ghost"
                    phx-click="cancel_voice_channel_form"
                  >
                    Cancel
                  </button>
                  <.button type="submit" class="btn btn-primary btn-sm">Create</.button>
                </div>
              </.form>
            </div>
          <% else %>
            <div class="mb-4">
              <p class="text-sm font-semibold">No workspace selected</p>
              <p class="mt-1 text-sm text-base-content/60">Choose a workspace to see channels.</p>
            </div>
          <% end %>
        </div>

        <GlobalDestinationRail.voice_controls />

        <div
          :if={@current_scope && @current_scope.user}
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

      <main id="workspace-main" class={main_class(@main_state)}>
        <%= case @main_state do %>
          <% :channel -> %>
            <header class="bg-base-100/95 px-6 py-4 shadow-[0_1px_0_rgb(255_255_255/0.04),0_10px_28px_rgb(0_0_0/0.08)]">
              <p id="selected-channel-title" class="min-w-0 truncate text-sm font-semibold">
                # {@selected_channel.name}
              </p>
            </header>
            <div id="channel-main" class="min-h-0 flex-1">
              {render_slot(@inner_block)}
            </div>
          <% :activity -> %>
            <div id="activity-main" class={["min-h-0 min-w-0"]}>
              {render_slot(@inner_block)}
            </div>
          <% :empty_channel -> %>
            <div
              id="workspace-main-empty-channel"
              class="flex h-full items-center justify-center text-center"
            >
              <div>
                <p class="text-lg font-semibold">No channels yet</p>
                <p class="mt-2 text-sm text-base-content/60">
                  Create a channel to start shaping this workspace.
                </p>
              </div>
            </div>
          <% :invite -> %>
            <section
              id="workspace-invite-main"
              class="mx-auto flex min-h-full w-full max-w-2xl items-center"
            >
              <div class="w-full rounded border border-base-300 bg-base-100 p-6 shadow-sm">
                <p class="text-xs font-semibold uppercase tracking-wide text-primary">
                  Invite people
                </p>
                <h1 class="mt-2 text-2xl font-semibold tracking-tight">
                  Create an invite for {@selected_workspace.name}
                </h1>
                <p class="mt-2 text-sm text-base-content/60">
                  Generate a fresh link that expires in 30 minutes.
                </p>

                <.form
                  for={@invite_form}
                  id="workspace-invite-create-form"
                  phx-submit="create_workspace_invite"
                  class="mt-6"
                >
                  <.button type="submit" class="btn btn-primary">
                    Create invite link
                  </.button>
                </.form>

                <div :if={@invite_url} id="workspace-invite-result" class="mt-6 space-y-2">
                  <label
                    for="workspace-invite-url"
                    class="text-xs font-semibold uppercase tracking-wide text-base-content/50"
                  >
                    Invite link
                  </label>
                  <div class="flex gap-2">
                    <input
                      id="workspace-invite-url"
                      type="text"
                      value={@invite_url}
                      readonly
                      class="input input-bordered min-w-0 flex-1 select-text font-mono text-sm"
                    />
                    <button
                      id="workspace-invite-copy"
                      type="button"
                      class="btn btn-square btn-outline group transition data-[copied=true]:border-success data-[copied=true]:bg-success/10 data-[copied=true]:text-success"
                      aria-label="Copy invite link"
                      phx-hook="ClipboardCopy"
                      phx-update="ignore"
                      data-copy-target="workspace-invite-url"
                    >
                      <.icon
                        name="hero-clipboard-document"
                        class="size-4 group-data-[copied=true]:hidden"
                      />
                      <.icon
                        name="hero-check"
                        class="hidden size-4 group-data-[copied=true]:block"
                      />
                      <span class="sr-only" data-copy-label>Copy invite link</span>
                    </button>
                  </div>
                </div>
              </div>
            </section>
          <% :audit -> %>
            <section id="workspace-audit-log" class="mx-auto w-full max-w-5xl px-6 py-8">
              <div class="flex flex-wrap items-end justify-between gap-4 border-b border-base-300 pb-5">
                <div>
                  <p class="text-xs font-semibold uppercase tracking-wide text-primary">
                    Audit log
                  </p>
                  <h1 class="mt-2 text-2xl font-semibold tracking-tight">
                    {@selected_workspace.name}
                  </h1>
                </div>
                <.link
                  navigate={~p"/workspaces/#{@selected_workspace.id}"}
                  class="btn btn-sm btn-ghost"
                >
                  Back
                </.link>
              </div>

              <div id="workspace-audit-events" class="mt-5 space-y-2">
                <div
                  :if={@audit_events == []}
                  id="workspace-audit-empty-state"
                  class="rounded border border-base-300 bg-base-200/60 p-5 text-sm text-base-content/60"
                >
                  No audit events yet.
                </div>
                <article
                  :for={event <- @audit_events}
                  id={"workspace-audit-event-#{event.id}"}
                  class="rounded border border-base-300 bg-base-100 p-4 shadow-sm transition hover:border-primary/30"
                >
                  <div class="flex flex-wrap items-start justify-between gap-3">
                    <div class="min-w-0">
                      <p class="font-semibold">{audit_event_title(event)}</p>
                      <p class="mt-1 text-sm text-base-content/60">
                        {audit_event_detail(event)}
                      </p>
                    </div>
                    <time
                      datetime={DateTime.to_iso8601(event.inserted_at)}
                      class="shrink-0 text-xs font-medium text-base-content/45"
                    >
                      {audit_event_time(event.inserted_at)}
                    </time>
                  </div>
                  <p
                    :if={event.reason}
                    id={"workspace-audit-event-#{event.id}-reason"}
                    class="mt-3 rounded bg-base-200 px-3 py-2 text-sm text-base-content/70"
                  >
                    {event.reason}
                  </p>
                </article>
              </div>

              <div class="mt-10 border-t border-base-300 pt-6">
                <h2 class="text-lg font-semibold tracking-tight">Banned members</h2>
                <p class="mt-1 text-sm text-base-content/60">
                  Unbanning restores rejoin eligibility. It does not restore membership or roles.
                </p>

                <div id="workspace-banned-members" class="mt-4 space-y-2">
                  <div
                    :if={@banned_members == []}
                    id="workspace-banned-members-empty-state"
                    class="rounded border border-base-300 bg-base-200/60 p-5 text-sm text-base-content/60"
                  >
                    No banned members.
                  </div>
                  <article
                    :for={ban <- @banned_members}
                    id={"workspace-banned-member-#{ban.target_user_id}"}
                    class="flex flex-wrap items-start justify-between gap-3 rounded border border-base-300 bg-base-100 p-4 shadow-sm"
                  >
                    <div class="min-w-0">
                      <p class="font-semibold">{ban.target_user.username}</p>
                      <p
                        :if={ban.reason}
                        class="mt-1 text-sm text-base-content/60"
                      >
                        {ban.reason}
                      </p>
                    </div>
                    <button
                      type="button"
                      phx-click="unban_member"
                      phx-value-user_id={ban.target_user_id}
                      class="btn btn-sm btn-ghost"
                    >
                      Unban
                    </button>
                  </article>
                </div>
              </div>
            </section>
          <% :no_workspace -> %>
            <div class="flex h-full items-center justify-center text-center">
              <div>
                <p class="text-lg font-semibold">Select a workspace to continue</p>
                <p class="mt-2 text-sm text-base-content/60">
                  Your workspace channels will appear here once you enter one.
                </p>
              </div>
            </div>
        <% end %>
      </main>

      <aside
        :if={@selected_workspace}
        id="workspace-members-sidebar"
        aria-label="Workspace members"
        class="hidden min-h-0 bg-base-200/80 shadow-[inset_1px_0_0_rgb(255_255_255/0.04)] xl:flex xl:flex-col"
      >
        <div class="px-4 py-4 shadow-[0_1px_0_rgb(255_255_255/0.04)]">
          <p class="text-xs font-semibold uppercase tracking-wide text-base-content/50">
            Members
          </p>
        </div>
        <div
          id="workspace-members"
          phx-update="stream"
          class="min-h-0 flex-1 space-y-1 overflow-y-auto px-3 py-3"
        >
          <%= for {dom_id, item} <- @member_stream do %>
            <div
              :if={item.type == :section}
              id={dom_id}
              class="px-2 pb-1 pt-3 text-[0.6875rem] font-bold uppercase tracking-wide text-base-content/45 first:pt-0"
            >
              {item.label}
            </div>
            <div
              :if={item.type == :member}
              id={dom_id}
              data-presence-state={member_presence_state(@online_user_ids, item.member)}
              class={[
                "flex items-center gap-3 rounded px-2 py-2 text-sm transition hover:bg-base-300/80",
                member_online?(@online_user_ids, item.member) && "text-base-content",
                !member_online?(@online_user_ids, item.member) && "text-base-content/70"
              ]}
            >
              <div class={[
                "flex size-8 shrink-0 items-center justify-center rounded text-xs font-semibold",
                member_online?(@online_user_ids, item.member) && "bg-primary/15 text-primary",
                !member_online?(@online_user_ids, item.member) && "bg-base-300 text-base-content/70"
              ]}>
                {user_initial(item.member.user)}
              </div>
              <div class="min-w-0 flex-1">
                <p class="truncate font-medium">{item.member.user.username}</p>
                <p
                  data-member-status={member_presence_state(@online_user_ids, item.member)}
                  class={[
                    "flex items-center gap-1.5 text-xs",
                    member_online?(@online_user_ids, item.member) && "text-primary",
                    !member_online?(@online_user_ids, item.member) && "text-base-content/45"
                  ]}
                >
                  <span
                    class={[
                      "size-2 rounded-full",
                      member_online?(@online_user_ids, item.member) && "bg-primary",
                      !member_online?(@online_user_ids, item.member) && "bg-base-content/30"
                    ]}
                    aria-hidden="true"
                  >
                  </span>
                  {member_presence_label(@online_user_ids, item.member)}
                </p>
              </div>
              <% member_actions = member_actions(@current_scope, @selected_workspace, item.member) %>
              <details
                :if={member_actions != []}
                id={"#{dom_id}-actions"}
                class="relative shrink-0"
              >
                <summary
                  class="btn btn-square btn-xs btn-ghost list-none transition hover:scale-105 [&::-webkit-details-marker]:hidden"
                  aria-label={"Open #{item.member.user.username} member actions"}
                >
                  <.icon name="hero-ellipsis-horizontal" class="size-4" />
                </summary>
                <div class="absolute right-0 z-30 mt-1 w-40 rounded border border-base-300 bg-base-100 p-1 shadow-lg">
                  <MemberActionsMenu.menu_items
                    id_prefix={dom_id}
                    actions={member_actions}
                    user_id={item.member.user.id}
                    current_scope={@current_scope}
                    workspace={@selected_workspace}
                  />
                </div>
              </details>
            </div>
          <% end %>
        </div>
      </aside>
    </div>
    """
  end

  defp selected_channel?(channel, selected_channel),
    do: selected_channel && channel.id == selected_channel.id

  defp channel_unread_count(_channel_unread_counts, channel, selected_channel)
       when not is_nil(selected_channel) and channel.id == selected_channel.id,
       do: 0

  defp channel_unread_count(channel_unread_counts, channel, _selected_channel) do
    Map.get(channel_unread_counts, channel.id, 0)
  end

  defp channel_has_unread?(channel_unread_counts, channel) do
    Map.get(channel_unread_counts, channel.id, 0) > 0
  end

  defp channel_unread_label(1, channel), do: "1 unread message in #{channel.name}"

  defp channel_unread_label(count, channel), do: "#{count} unread messages in #{channel.name}"

  defp selected_channel_aria(channel, selected_channel) do
    if selected_channel?(channel, selected_channel), do: "page"
  end

  defp can_rename_workspace?(workspace, current_scope) do
    Workspaces.can_rename_workspace?(current_scope, workspace)
  end

  defp can_delete_workspace?(workspace, current_scope) do
    Workspaces.can_delete_workspace?(current_scope, workspace)
  end

  defp can_create_channel?(workspace, current_scope) do
    Workspaces.can_create_channel?(current_scope, workspace)
  end

  defp can_rename_channel?(workspace, current_scope) do
    Workspaces.can_rename_channel?(current_scope, workspace)
  end

  defp can_delete_channel?(workspace, current_scope) do
    Workspaces.can_delete_channel?(current_scope, workspace)
  end

  defp can_create_voice_channel?(workspace, current_scope),
    do: Workspaces.can_create_voice_channel?(current_scope, workspace)

  defp can_rename_voice_channel?(workspace, current_scope),
    do: Workspaces.can_rename_voice_channel?(current_scope, workspace)

  defp can_delete_voice_channel?(workspace, current_scope),
    do: Workspaces.can_delete_voice_channel?(current_scope, workspace)

  defp can_create_workspace_invite?(workspace, current_scope) do
    Workspaces.can_create_workspace_invite?(current_scope, workspace)
  end

  defp can_view_audit_log?(workspace, current_scope) do
    Workspaces.can_view_audit_log?(current_scope, workspace)
  end

  defp member_actions(current_scope, workspace, member) do
    friendship_actions =
      if current_scope.user.id == member.user_id do
        []
      else
        [:send_friend_request]
      end

    friendship_actions ++ Workspaces.available_member_actions(current_scope, workspace, member)
  end

  defp audit_event_title(%{event_type: "member_role_promoted"}), do: "Member promoted"
  defp audit_event_title(%{event_type: "member_role_demoted"}), do: "Admin demoted"
  defp audit_event_title(%{event_type: "member_muted"}), do: "Member muted"
  defp audit_event_title(%{event_type: "member_unmuted"}), do: "Member unmuted"
  defp audit_event_title(%{event_type: "member_timed_out"}), do: "Member timed out"
  defp audit_event_title(%{event_type: "member_timeout_removed"}), do: "Timeout removed"
  defp audit_event_title(%{event_type: "member_timeout_expired"}), do: "Timeout expired"
  defp audit_event_title(%{event_type: "member_kicked"}), do: "Member kicked"
  defp audit_event_title(%{event_type: "member_banned"}), do: "Member banned"
  defp audit_event_title(%{event_type: "member_unbanned"}), do: "Member unbanned"
  defp audit_event_title(%{event_type: "member_joined_from_invite"}), do: "Member joined"
  defp audit_event_title(%{event_type: "moderator_message_deleted"}), do: "Message deleted"
  defp audit_event_title(event), do: event.event_type

  defp audit_event_detail(event) do
    actor = audit_user_name(event.actor_user)
    target = audit_user_name(event.target_user)

    case event.event_type do
      "member_role_promoted" ->
        "#{actor} promoted #{target} to admin"

      "member_role_demoted" ->
        "#{actor} demoted #{target} to member"

      "member_muted" ->
        "#{actor} muted #{target}"

      "member_unmuted" ->
        "#{actor} unmuted #{target}"

      "member_timed_out" ->
        "#{actor} timed out #{target}"

      "member_timeout_removed" ->
        "#{actor} removed timeout from #{target}"

      "member_timeout_expired" ->
        "Timeout expired for #{target}"

      "member_kicked" ->
        "#{actor} kicked #{target}"

      "member_banned" ->
        "#{actor} banned #{target}"

      "member_unbanned" ->
        "#{actor} unbanned #{target}"

      "member_joined_from_invite" ->
        "#{target} joined from an invite created by #{actor}"

      "moderator_message_deleted" ->
        "#{actor} deleted a message by #{target}#{audit_channel_context(event)}"

      _event_type ->
        "#{actor} changed #{target}"
    end
  end

  defp audit_user_name(%{username: username}) when is_binary(username), do: username
  defp audit_user_name(_user), do: "Unknown user"

  defp audit_channel_context(%{metadata: %{"channel_name" => name}}) when is_binary(name),
    do: " in ##{name}"

  defp audit_channel_context(_event), do: ""

  defp audit_event_time(%DateTime{} = datetime),
    do: Calendar.strftime(datetime, "%b %-d, %Y %H:%M")

  defp workspace_shell_class(true),
    do:
      "fixed inset-0 grid min-h-screen grid-cols-1 grid-rows-[auto_minmax(10rem,30vh)_minmax(0,1fr)] overflow-hidden bg-base-100 lg:grid-cols-[var(--app-sidebar-expanded-width)_var(--app-sidebar-width)_minmax(0,1fr)] lg:grid-rows-1 xl:grid-cols-[var(--app-sidebar-expanded-width)_var(--app-sidebar-width)_minmax(0,1fr)_var(--app-member-panel-width)]"

  defp workspace_shell_class(_show_workspace_form?),
    do:
      "fixed inset-0 grid min-h-screen grid-cols-1 grid-rows-[auto_minmax(10rem,30vh)_minmax(0,1fr)] overflow-hidden bg-base-100 lg:grid-cols-[var(--app-rail-width)_var(--app-sidebar-width)_minmax(0,1fr)] lg:grid-rows-1 xl:grid-cols-[var(--app-rail-width)_var(--app-sidebar-width)_minmax(0,1fr)_var(--app-member-panel-width)]"

  defp context_menu_style(%{x: x, y: y}), do: "left: #{x}px; top: #{y}px;"
  defp context_menu_style(_position), do: nil

  defp menu_class(nil, anchor_class, width_class),
    do: [
      anchor_class,
      "z-20",
      width_class,
      "rounded border border-base-300 bg-base-100 p-1 shadow-lg"
    ]

  defp menu_class(_position, _anchor_class, width_class),
    do: ["fixed z-50", width_class, "rounded border border-base-300 bg-base-100 p-1 shadow-lg"]

  defp user_initial(user) do
    user.username
    |> String.first()
    |> String.upcase()
  end

  defp roster_members(voice_channel_rosters, member_by_user_id, voice_channel_id) do
    voice_channel_rosters
    |> Map.get(voice_channel_id, [])
    |> Enum.flat_map(fn %{user_id: user_id} = roster_member ->
      case Map.get(member_by_user_id, user_id) do
        %{user: user} ->
          [
            %{
              user_id: user_id,
              user: user,
              muted: Map.get(roster_member, :muted, false),
              deafened: Map.get(roster_member, :deafened, false),
              speaking: Map.get(roster_member, :speaking, false)
            }
          ]

        nil ->
          []
      end
    end)
  end

  defp visible_voice_roster_members(roster_members), do: Enum.take(roster_members, 4)

  defp voice_roster_overflow_count(roster_members), do: max(length(roster_members) - 4, 0)

  defp voice_channel_occupancy_label([]), do: "Empty"
  defp voice_channel_occupancy_label([_member]), do: "1 person"
  defp voice_channel_occupancy_label(roster_members), do: "#{length(roster_members)} people"

  defp roster_member_actions(current_scope, workspace, member_by_user_id, user_id) do
    case Map.get(member_by_user_id, user_id) do
      nil ->
        []

      membership ->
        case Workspaces.available_member_actions(current_scope, workspace, membership) do
          [] -> []
          actions -> actions ++ [:voice_disconnect]
        end
    end
  end

  defp member_presence_state(online_user_ids, member) do
    if member_online?(online_user_ids, member), do: "online", else: "offline"
  end

  defp member_presence_label(online_user_ids, member) do
    if member_online?(online_user_ids, member), do: "Online", else: "Offline"
  end

  defp member_online?(online_user_ids, member) do
    MapSet.member?(online_user_ids, member.user.id)
  end

  defp main_class(:channel), do: "flex min-h-0 min-w-0 flex-col bg-base-100"
  defp main_class(_state), do: "min-h-0 overflow-auto bg-base-100 p-6"
end
