defmodule DiscordCloneWeb.UserLive.LoginTest do
  use DiscordCloneWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import DiscordClone.AccountsFixtures

  describe "login page" do
    test "renders password-only login", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/log-in")

      assert has_element?(lv, "#login_form_password")
      refute has_element?(lv, "#login_form_magic")
      refute has_element?(lv, "a[href='/users/register']")
    end
  end

  describe "user login - password" do
    test "redirects if user logs in with valid credentials", %{conn: conn} do
      user = user_fixture() |> set_password()
      {:ok, lv, _html} = live(conn, ~p"/users/log-in")

      form =
        form(lv, "#login_form_password",
          user: %{email: user.email, password: valid_user_password(), remember_me: true}
        )

      conn = submit_form(form, conn)
      assert redirected_to(conn) == ~p"/workspaces"
    end

    test "redirects with a flash error if credentials are invalid", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/log-in")

      form =
        form(lv, "#login_form_password", user: %{email: "test@email.com", password: "123456"})

      render_submit(form, %{user: %{remember_me: true}})

      conn = follow_trigger_action(form, conn)
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Invalid email or password"
      assert redirected_to(conn) == ~p"/users/log-in"
    end
  end

  describe "re-authentication (sudo mode)" do
    setup %{conn: conn} do
      user = user_fixture()
      %{user: user, conn: log_in_user(conn, user)}
    end

    test "shows login page with email filled in", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/users/log-in")

      assert has_element?(lv, "#user_email[value='#{user.email}'][readonly]")
      assert has_element?(lv, "#login-remember-button")
      assert has_element?(lv, "#login-once-button")
      refute has_element?(lv, "a[href='/users/register']")
    end
  end
end
