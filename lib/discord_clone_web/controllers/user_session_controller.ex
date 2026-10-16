defmodule DiscordCloneWeb.UserSessionController do
  use DiscordCloneWeb, :controller

  alias DiscordClone.Accounts
  alias DiscordCloneWeb.UserAuth
  alias DiscordCloneWeb.UserSettingsInputs

  def create(conn, params) do
    create(conn, params, "Welcome back!")
  end

  defp create(conn, %{"user" => %{"email" => email, "password" => password} = user_params}, info) do
    if user = Accounts.get_user_by_email_and_password(email, password) do
      conn
      |> put_flash(:info, info)
      |> UserAuth.log_in_user(user, user_params)
    else
      # In order to prevent user enumeration attacks, don't disclose whether the email is registered.
      conn
      |> put_flash(:error, "Invalid email or password")
      |> put_flash(:email, String.slice(email, 0, 160))
      |> redirect(to: ~p"/users/log-in")
    end
  end

  defp create(conn, _invalid_params, _info) do
    conn
    |> put_flash(:error, "Invalid email or password")
    |> redirect(to: ~p"/users/log-in")
  end

  def update_password(conn, params) do
    user = conn.assigns.current_scope.user

    if Accounts.sudo_mode?(user) do
      with {:ok, user_params} <- UserSettingsInputs.parse(params, "password"),
           {:ok, {updated_user, expired_tokens}} <-
             Accounts.update_user_password(user, user_params) do
        UserAuth.disconnect_sessions(expired_tokens)

        conn
        |> put_session(:user_return_to, ~p"/users/settings")
        |> put_flash(:info, "Password updated successfully!")
        |> UserAuth.log_in_user(%{updated_user | authenticated_at: nil})
      else
        _invalid ->
          conn
          |> put_flash(:error, "Unable to update password. Please check the form and try again.")
          |> redirect(to: ~p"/users/settings")
      end
    else
      conn
      |> put_flash(:error, "You must re-authenticate to access this page.")
      |> redirect(to: ~p"/users/log-in")
    end
  end

  def delete(conn, _params) do
    conn
    |> put_flash(:info, "Logged out successfully.")
    |> UserAuth.log_out_user()
  end
end
