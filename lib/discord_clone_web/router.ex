defmodule DiscordCloneWeb.Router do
  use DiscordCloneWeb, :router

  import DiscordCloneWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {DiscordCloneWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", DiscordCloneWeb do
    pipe_through :api

    get "/healthz", HealthController, :health
    get "/readyz", HealthController, :ready
  end

  # Other scopes may use custom stacks.
  # scope "/api", DiscordCloneWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:discord_clone, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: DiscordCloneWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  ## Authentication routes

  scope "/", DiscordCloneWeb do
    pipe_through [:browser, :require_authenticated_user]

    get "/invites/:code", InviteController, :show
    post "/invites/:code/accept", InviteController, :accept

    live_session :require_authenticated_user,
      on_mount: [
        {DiscordCloneWeb.UserAuth, :require_authenticated},
        {DiscordCloneWeb.FriendPresenceLive, :register_connection},
        {DiscordCloneWeb.ActivityLive, :assign_unread_count},
        {DiscordCloneWeb.DirectMessagesNavigation, :assign_destination}
      ] do
      live "/workspaces", WorkspaceLive.Home, :index
      live "/workspaces/:workspace_id", WorkspaceLive.Entry, :show
      live "/workspaces/:workspace_id/audit-log", WorkspaceLive.AuditLog, :index
      live "/workspaces/:workspace_id/invites/new", WorkspaceLive.InviteNew, :new
      live "/workspaces/:workspace_id/channels/:channel_id", ChannelLive.Show, :show
      live "/activity", ActivityLive, :index
      live "/friends", FriendsLive, :index
      live "/direct-messages", FriendsLive, :friends
      live "/direct-messages/requests", FriendsLive, :requests
      live "/direct-messages/:direct_conversation_id", DirectConversationLive, :show
      live "/users/settings", UserLive.Settings, :edit
    end

    post "/users/update-password", UserSessionController, :update_password
  end

  scope "/", DiscordCloneWeb do
    pipe_through [:browser, :redirect_if_user_is_authenticated]

    live_session :current_user,
      on_mount: [{DiscordCloneWeb.UserAuth, :mount_current_scope}] do
      live "/", UserLive.Login, :new
      live "/users/log-in", UserLive.Login, :new
    end

    post "/users/log-in", UserSessionController, :create
  end

  scope "/", DiscordCloneWeb do
    pipe_through [:browser]

    delete "/users/log-out", UserSessionController, :delete
  end
end
