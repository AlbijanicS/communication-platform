defmodule DiscordCloneWeb.UserSessionControllerTest do
  use DiscordCloneWeb.ConnCase, async: true

  import DiscordClone.AccountsFixtures

  setup do
    %{user: user_fixture()}
  end

  describe "POST /users/log-in - email and password" do
    test "logs the user in", %{conn: conn, user: user} do
      user = set_password(user)

      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{"email" => user.email, "password" => valid_user_password()}
        })

      assert get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/workspaces"

      conn = get(conn, ~p"/")
      assert redirected_to(conn) == ~p"/workspaces"
    end

    test "logs the user in with remember me", %{conn: conn, user: user} do
      user = set_password(user)

      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{
            "email" => user.email,
            "password" => valid_user_password(),
            "remember_me" => "true"
          }
        })

      assert conn.resp_cookies["_discord_clone_web_user_remember_me"]
      assert redirected_to(conn) == ~p"/workspaces"
    end

    test "logs the user in with return to", %{conn: conn, user: user} do
      user = set_password(user)

      conn =
        conn
        |> init_test_session(user_return_to: "/foo/bar")
        |> post(~p"/users/log-in", %{
          "user" => %{"email" => user.email, "password" => valid_user_password()}
        })

      assert redirected_to(conn) == "/foo/bar"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Welcome back!"
    end

    test "redirects to login page with invalid credentials", %{conn: conn, user: user} do
      conn =
        post(conn, ~p"/users/log-in?mode=password", %{
          "user" => %{"email" => user.email, "password" => "invalid_password"}
        })

      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Invalid email or password"
      assert redirected_to(conn) == ~p"/users/log-in"
    end
  end

  describe "POST /users/log-in - disabled login methods" do
    test "does not accept a legacy magic-link token", %{conn: conn, user: user} do
      {token, _hashed_token} = generate_user_magic_link_token(user)

      conn = post(conn, ~p"/users/log-in", %{"user" => %{"token" => token}})

      refute get_session(conn, :user_token)
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Invalid email or password"
      assert redirected_to(conn) == ~p"/users/log-in"
    end
  end

  describe "POST /users/update-password" do
    test "expired sudo requires reauthentication without changing password or session", %{
      conn: conn,
      user: user
    } do
      user = set_password(user)

      conn =
        log_in_user(conn, user,
          token_authenticated_at: DateTime.add(DateTime.utc_now(:second), -21, :minute)
        )

      token = get_session(conn, :user_token)

      conn =
        post(conn, ~p"/users/update-password", %{
          "user" => %{"email" => user.email, "password" => "a different valid password"}
        })

      assert redirected_to(conn) == ~p"/users/log-in"

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "You must re-authenticate to access this page."

      assert get_session(conn, :user_token) == token

      assert DiscordClone.Accounts.get_user_by_email_and_password(
               user.email,
               valid_user_password()
             )

      refute DiscordClone.Accounts.get_user_by_email_and_password(
               user.email,
               "a different valid password"
             )
    end
  end

  test "fresh password update renews the current user's session and disconnects old sessions", %{
    conn: conn,
    user: user
  } do
    user = set_password(user)
    other_user = set_password(user_fixture())

    conn =
      conn
      |> log_in_user(user,
        token_authenticated_at: DateTime.add(DateTime.utc_now(:second), -15, :minute)
      )
      |> put_session(:user_remember_me, true)

    old_token = get_session(conn, :user_token)
    other_session = DiscordClone.Accounts.generate_user_session_token(user)
    DiscordCloneWeb.Endpoint.subscribe(DiscordCloneWeb.UserAuth.user_session_topic(old_token))

    response =
      post(conn, ~p"/users/update-password", %{
        "user" => %{"email" => other_user.email, "password" => "a different valid password"}
      })

    assert redirected_to(response) == ~p"/users/settings"
    assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
    refute DiscordClone.Accounts.get_user_by_session_token(old_token)
    refute DiscordClone.Accounts.get_user_by_session_token(other_session)

    assert {session_user, _} =
             DiscordClone.Accounts.get_user_by_session_token(get_session(response, :user_token))

    assert session_user.id == user.id
    assert DiscordClone.Accounts.sudo_mode?(session_user, -10)
    assert response.resp_cookies["_discord_clone_web_user_remember_me"]

    assert DiscordClone.Accounts.get_user_by_email_and_password(
             user.email,
             "a different valid password"
           )

    assert DiscordClone.Accounts.get_user_by_email_and_password(
             other_user.email,
             valid_user_password()
           )
  end

  test "malformed and invalid password updates keep the current session", %{
    conn: conn,
    user: user
  } do
    user = set_password(user)
    conn = log_in_user(conn, user)
    token = get_session(conn, :user_token)

    for params <- [
          %{},
          %{"user" => nil},
          %{"user" => []},
          %{"user" => "bad"},
          %{"user" => %{}},
          %{"user" => %{"password" => []}},
          %{"user" => %{"password" => "short"}},
          %{"user" => %{"password" => valid_user_password(), "password_confirmation" => %{}}}
        ] do
      response = post(conn, ~p"/users/update-password", params)
      assert redirected_to(response) == ~p"/users/settings"

      assert Phoenix.Flash.get(response.assigns.flash, :error) ==
               "Unable to update password. Please check the form and try again."

      assert get_session(response, :user_token) == token

      assert DiscordClone.Accounts.get_user_by_email_and_password(
               user.email,
               valid_user_password()
             )
    end
  end

  describe "DELETE /users/log-out" do
    test "logs the user out", %{conn: conn, user: user} do
      conn = conn |> log_in_user(user) |> delete(~p"/users/log-out")
      assert redirected_to(conn) == ~p"/"
      refute get_session(conn, :user_token)
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Logged out successfully"
    end

    test "succeeds even if the user is not logged in", %{conn: conn} do
      conn = delete(conn, ~p"/users/log-out")
      assert redirected_to(conn) == ~p"/"
      refute get_session(conn, :user_token)
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Logged out successfully"
    end
  end
end
