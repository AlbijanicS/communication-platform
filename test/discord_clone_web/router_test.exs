defmodule DiscordCloneWeb.RouterTest do
  use DiscordCloneWeb.ConnCase, async: true

  test "private deployment does not expose self-service account creation", %{conn: conn} do
    assert response(get(conn, "/users/register"), :not_found)
    assert response(get(recycle(conn), "/users/log-in/not-a-real-token"), :not_found)
  end
end
