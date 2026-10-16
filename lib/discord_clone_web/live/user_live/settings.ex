defmodule DiscordCloneWeb.UserLive.Settings do
  use DiscordCloneWeb, :live_view

  on_mount {DiscordCloneWeb.UserAuth, :require_sudo_mode}

  alias DiscordClone.Accounts
  alias DiscordCloneWeb.UserSettingsInputs

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="text-center">
        <.header>
          Account Settings
          <:subtitle>Manage your username and password settings</:subtitle>
        </.header>
      </div>

      <.form
        for={@username_form}
        id="username_form"
        phx-submit="update_username"
        phx-change="validate_username"
      >
        <.input
          field={@username_form[:username]}
          type="text"
          label="Username"
          autocomplete="nickname"
          spellcheck="false"
          required
        />
        <.button variant="primary" phx-disable-with="Changing...">Change Username</.button>
      </.form>

      <div class="divider" />

      <.form
        for={@password_form}
        id="password_form"
        action={~p"/users/update-password"}
        method="post"
        phx-change="validate_password"
        phx-submit="update_password"
        phx-trigger-action={@trigger_submit}
      >
        <input
          name={@password_form[:email].name}
          type="hidden"
          id="hidden_user_email"
          spellcheck="false"
          value={@current_email}
        />
        <.input
          field={@password_form[:password]}
          type="password"
          label="New password"
          autocomplete="new-password"
          spellcheck="false"
          required
        />
        <.input
          field={@password_form[:password_confirmation]}
          type="password"
          label="Confirm new password"
          autocomplete="new-password"
          spellcheck="false"
        />
        <.button variant="primary" phx-disable-with="Saving...">
          Save Password
        </.button>
      </.form>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user

    username_changeset =
      Accounts.change_user_username(socket.assigns.current_scope, %{}, validate_unique: false)

    password_changeset = Accounts.change_user_password(user, %{}, hash_password: false)

    socket =
      socket
      |> assign(:current_email, user.email)
      |> assign(:username_form, to_form(username_changeset))
      |> assign(:password_form, to_form(password_changeset))
      |> assign(:trigger_submit, false)

    {:ok, socket}
  end

  @impl true
  def handle_event(event, params, socket) do
    field =
      case event do
        event when event in ["validate_username", "update_username"] -> "username"
        event when event in ["validate_password", "update_password"] -> "password"
        _ -> nil
      end

    cond do
      not Accounts.sudo_mode?(socket.assigns.current_scope.user) ->
        {:noreply,
         socket
         |> assign(:trigger_submit, false)
         |> put_flash(:error, "You must re-authenticate to access this page.")
         |> redirect(to: ~p"/users/log-in")}

      field != nil ->
        case UserSettingsInputs.parse(params, field) do
          {:ok, attrs} -> handle_settings_event(event, %{"user" => attrs}, socket)
          :error -> invalid_request(socket)
        end

      true ->
        invalid_request(socket)
    end
  end

  defp invalid_request(socket) do
    {:noreply,
     socket
     |> assign(:trigger_submit, false)
     |> put_flash(:error, "Invalid settings request. Please check the form and try again.")}
  end

  defp handle_settings_event("validate_username", %{"user" => user_params}, socket) do
    username_form =
      socket.assigns.current_scope
      |> Accounts.change_user_username(user_params, validate_unique: false)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, username_form: username_form)}
  end

  defp handle_settings_event("update_username", %{"user" => user_params}, socket) do
    case Accounts.update_user_username(socket.assigns.current_scope, user_params) do
      {:ok, updated_user} ->
        current_scope = %{socket.assigns.current_scope | user: updated_user}
        username_form = Accounts.change_user_username(current_scope) |> to_form()

        {:noreply,
         socket
         |> assign(:current_scope, current_scope)
         |> assign(:username_form, username_form)
         |> put_flash(:info, "Username changed successfully.")}

      {:error, changeset} ->
        {:noreply, assign(socket, :username_form, to_form(changeset, action: :insert))}
    end
  end

  defp handle_settings_event("validate_password", %{"user" => user_params}, socket) do
    password_form =
      socket.assigns.current_scope.user
      |> Accounts.change_user_password(user_params, hash_password: false)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, password_form: password_form)}
  end

  defp handle_settings_event("update_password", %{"user" => user_params}, socket) do
    user = socket.assigns.current_scope.user

    case Accounts.change_user_password(user, user_params) do
      %{valid?: true} = changeset ->
        {:noreply, assign(socket, trigger_submit: true, password_form: to_form(changeset))}

      changeset ->
        {:noreply, assign(socket, password_form: to_form(changeset, action: :insert))}
    end
  end
end
