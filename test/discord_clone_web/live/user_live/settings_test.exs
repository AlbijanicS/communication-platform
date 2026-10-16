defmodule DiscordCloneWeb.UserLive.SettingsTest do
  use DiscordCloneWeb.ConnCase, async: true

  alias DiscordClone.Accounts
  import Phoenix.LiveViewTest
  import DiscordClone.AccountsFixtures

  test "email changes are unavailable, including forged events", %{conn: conn} do
    user = user_fixture()
    {:ok, lv, _html} = conn |> log_in_user(user) |> live(~p"/users/settings")
    refute has_element?(lv, "#email_form")
    render_hook(lv, "update_email", %{"user" => %{"email" => "changed@example.test"}})
    assert has_element?(lv, "#flash-error", "Invalid settings request")
    assert Accounts.get_user!(user.id).email == user.email
    refute_receive {:email, %Swoosh.Email{subject: "Update email instructions"}}
  end

  test "the old email confirmation route is unavailable", %{conn: conn} do
    conn = log_in_user(conn, user_fixture())
    response = get(conn, "/users/settings/confirm-email/old-token")
    assert response.status == 404
  end

  describe "Settings page" do
    test "renders settings page", %{conn: conn} do
      {:ok, lv, html} =
        conn
        |> log_in_user(user_fixture())
        |> live(~p"/users/settings")

      assert html =~ "Save Password"
      assert has_element?(lv, "#username_form")
    end

    test "redirects if user is not logged in", %{conn: conn} do
      assert {:error, redirect} = live(conn, ~p"/users/settings")

      assert {:redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/users/log-in"
      assert %{"error" => "You must log in to access this page."} = flash
    end

    test "redirects if user is not in sudo mode", %{conn: conn} do
      {:ok, conn} =
        conn
        |> log_in_user(user_fixture(),
          token_authenticated_at: DateTime.add(DateTime.utc_now(:second), -11, :minute)
        )
        |> live(~p"/users/settings")
        |> follow_redirect(conn, ~p"/users/log-in")

      assert conn.resp_body =~ "You must re-authenticate to access this page."
    end
  end

  describe "settings event boundaries" do
    test "expired sudo after opening settings rejects each update", %{conn: conn} do
      user = set_password(user_fixture())
      conn = log_in_user(conn, user)

      for {event, attrs} <- [
            {"update_username", %{"username" => "changed_name"}},
            {"update_password", %{"password" => "a different valid password"}}
          ] do
        {:ok, lv, _html} = live(conn, ~p"/users/settings")

        # Simulate elapsed authentication time without waiting twenty minutes.
        :sys.replace_state(lv.pid, fn state ->
          put_in(
            state.socket.assigns.current_scope.user.authenticated_at,
            DateTime.add(DateTime.utc_now(:second), -21, :minute)
          )
        end)

        render_submit(lv, event, %{"user" => attrs})
        assert_redirect(lv, ~p"/users/log-in")
        assert Accounts.get_user!(user.id).username == user.username
        assert Accounts.get_user!(user.id).email == user.email
        assert Accounts.get_user_by_email_and_password(user.email, valid_user_password())
        refute_receive {:email, %Swoosh.Email{subject: "Update email instructions"}}
      end
    end

    test "malformed form payloads and unknown events leave settings usable", %{conn: conn} do
      user = user_fixture()
      {:ok, lv, _html} = conn |> log_in_user(user) |> live(~p"/users/settings")

      for field <- ["username", "password"],
          prefix <- ["validate_", "update_"],
          params <- [
            %{},
            %{"user" => nil},
            %{"user" => []},
            %{"user" => "bad"},
            %{"user" => %{}},
            %{"user" => %{field => %{}}},
            %{"user" => %{field => []}},
            %{"user" => %{field => 42}}
          ] do
        render_hook(lv, prefix <> field, params)
        assert has_element?(lv, "#" <> field <> "_form")

        assert has_element?(
                 lv,
                 "#flash-error",
                 "Invalid settings request. Please check the form and try again."
               )

        refute has_element?(lv, "#password_form[phx-trigger-action]")
      end

      render_submit(lv, "unknown_settings_action", %{})
      assert has_element?(lv, "#username_form")
      assert Accounts.get_user!(user.id).username == user.username
      assert Accounts.get_user!(user.id).email == user.email
      refute_receive {:email, %Swoosh.Email{subject: "Update email instructions"}}
    end
  end

  describe "update username form" do
    setup %{conn: conn} do
      user = user_fixture()
      %{conn: log_in_user(conn, user), user: user}
    end

    test "updates and normalizes the username", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      lv
      |> form("#username_form", %{"user" => %{"username" => "  New_Username  "}})
      |> render_submit()

      assert has_element?(lv, "#flash-info", "Username changed successfully.")
      assert has_element?(lv, "#username_form input[value='new_username']")
      assert Accounts.get_user!(user.id).username == "new_username"
    end

    test "renders a field error for the reserved everyone username", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      lv
      |> element("#username_form")
      |> render_change(%{"user" => %{"username" => " EVERYONE "}})

      assert has_element?(lv, "#username_form p", "is reserved")
    end
  end

  describe "update password form" do
    setup %{conn: conn} do
      user = user_fixture()
      %{conn: log_in_user(conn, user), user: user}
    end

    test "updates the user password", %{conn: conn, user: user} do
      new_password = valid_user_password()

      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      form =
        form(lv, "#password_form", %{
          "user" => %{
            "email" => user.email,
            "password" => new_password,
            "password_confirmation" => new_password
          }
        })

      render_submit(form)

      new_password_conn = follow_trigger_action(form, conn)

      assert redirected_to(new_password_conn) == ~p"/users/settings"

      assert get_session(new_password_conn, :user_token) != get_session(conn, :user_token)

      assert Phoenix.Flash.get(new_password_conn.assigns.flash, :info) =~
               "Password updated successfully"

      assert Accounts.get_user_by_email_and_password(user.email, new_password)
    end

    test "renders errors with invalid data (phx-change)", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      result =
        lv
        |> element("#password_form")
        |> render_change(%{
          "user" => %{
            "password" => "too short",
            "password_confirmation" => "does not match"
          }
        })

      assert result =~ "Save Password"
      assert result =~ "should be at least 12 character(s)"
      assert result =~ "does not match password"
    end

    test "renders errors with invalid data (phx-submit)", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      result =
        lv
        |> form("#password_form", %{
          "user" => %{
            "password" => "too short",
            "password_confirmation" => "does not match"
          }
        })
        |> render_submit()

      assert result =~ "Save Password"
      assert result =~ "should be at least 12 character(s)"
      assert result =~ "does not match password"
    end
  end
end
