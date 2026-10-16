defmodule DiscordCloneWeb.HealthControllerTest do
  use DiscordCloneWeb.ConnCase, async: false

  alias DiscordClone.DeploymentReadiness

  setup do
    previous_checks = Application.get_env(:discord_clone, DeploymentReadiness)

    on_exit(fn ->
      if previous_checks do
        Application.put_env(:discord_clone, DeploymentReadiness, previous_checks)
      else
        Application.delete_env(:discord_clone, DeploymentReadiness)
      end
    end)
  end

  test "GET /healthz is anonymous, shallow, and fixed", %{conn: conn} do
    observer = self()

    Application.put_env(:discord_clone, DeploymentReadiness,
      database_check: fn -> send(observer, :database_checked) end,
      static_configuration_check: fn -> send(observer, :static_configuration_checked) end
    )

    conn = get(conn, ~p"/healthz")

    assert json_response(conn, 200) == %{"status" => "ok"}
    refute_receive :database_checked
    refute_receive :static_configuration_checked
    refute Map.has_key?(conn.private, :plug_session)
  end

  test "GET /readyz returns the exact ready response", %{conn: conn} do
    Application.put_env(:discord_clone, DeploymentReadiness,
      database_check: fn -> :ok end,
      static_configuration_check: fn -> :ok end
    )

    conn = get(conn, ~p"/readyz")

    assert json_response(conn, 200) == %{"status" => "ok"}
  end

  test "GET /readyz returns one generic response for every dependency failure", %{conn: conn} do
    forbidden_values = [
      "ecto://alpha:database-secret@private-db/discord_clone",
      "hosted-provider-name",
      "turn:203.0.113.20:3478",
      "temporary-provider-secret",
      "user-123",
      "voice-channel-456",
      "voice-session-789",
      "signaling-session-abc"
    ]

    for failing_check <- [:database_check, :static_configuration_check] do
      Application.put_env(:discord_clone, DeploymentReadiness,
        database_check: fn -> :ok end,
        static_configuration_check: fn -> :ok end
      )

      Application.put_env(
        :discord_clone,
        DeploymentReadiness,
        Keyword.put(
          Application.fetch_env!(:discord_clone, DeploymentReadiness),
          failing_check,
          fn -> {:error, Enum.join(forbidden_values, " ")} end
        )
      )

      response_conn = get(recycle(conn), ~p"/readyz")
      complete_response = inspect(response_conn.resp_headers) <> response_conn.resp_body

      assert response_conn.status == 503
      assert json_response(response_conn, 503) == %{"status" => "unavailable"}

      for forbidden_value <- forbidden_values do
        refute complete_response =~ forbidden_value
      end
    end
  end

  test "health routes do not weaken the authenticated Workspace boundary", %{conn: conn} do
    conn = get(conn, ~p"/workspaces")

    assert redirected_to(conn) == ~p"/users/log-in"
  end
end
