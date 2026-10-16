defmodule DiscordCloneWeb.CallSocketTest do
  use DiscordClone.DataCase, async: false

  import DiscordClone.AccountsFixtures
  import Phoenix.ChannelTest

  alias DiscordClone.Accounts
  alias DiscordClone.Accounts.UserToken
  alias DiscordClone.Repo
  alias DiscordCloneWeb.{CallSocket, UserAuth}

  @endpoint DiscordCloneWeb.Endpoint

  describe "connect/3" do
    test "authenticates from a binary session token and ignores client identity params" do
      user = user_fixture()
      other_user = user_fixture()
      token = Accounts.generate_user_session_token(user)

      assert {:ok, socket} =
               connect(
                 CallSocket,
                 %{"user_id" => other_user.id, "signaling_session_id" => "forged"},
                 connect_info: %{session: %{"user_token" => token}}
               )

      assert socket.assigns.current_scope.user.id == user.id
      refute socket.assigns.current_scope.user.id == other_user.id
      assert CallSocket.id(socket) == UserAuth.user_session_topic(token)
    end

    test "rejects missing, malformed, expired, and deleted session tokens" do
      user = user_fixture()
      token = Accounts.generate_user_session_token(user)

      assert :error = connect(CallSocket, %{}, connect_info: %{session: %{}})
      assert :error = connect(CallSocket, %{}, connect_info: %{session: nil})
      assert :error = connect(CallSocket, %{}, connect_info: %{})
      assert :error = connect(CallSocket, %{}, connect_info: %{session: %{"user_token" => 123}})
      assert :error = connect(CallSocket, %{}, connect_info: %{session: %{"user_token" => ""}})

      assert :error =
               connect(CallSocket, %{},
                 connect_info: %{session: %{"user_token" => "not-a-session"}}
               )

      expire_session_token!(token)
      assert :error = connect(CallSocket, %{}, connect_info: %{session: %{"user_token" => token}})

      fresh_token = Accounts.generate_user_session_token(user)
      assert :ok = Accounts.delete_user_session_token(fresh_token)

      assert :error =
               connect(CallSocket, %{}, connect_info: %{session: %{"user_token" => fresh_token}})
    end

    test "assigns a fresh opaque Call Connection ID to every authenticated connect" do
      user = user_fixture()
      token = Accounts.generate_user_session_token(user)

      assert {:ok, first} =
               connect(CallSocket, %{"connection_id" => "forged-connection"},
                 connect_info: %{session: %{"user_token" => token}}
               )

      assert {:ok, second} =
               connect(CallSocket, %{"connection_id" => first.assigns.connection_id},
                 connect_info: %{session: %{"user_token" => token}}
               )

      assert {:ok, _uuid} = Ecto.UUID.cast(first.assigns.connection_id)
      assert {:ok, _uuid} = Ecto.UUID.cast(second.assigns.connection_id)
      refute first.assigns.connection_id == "forged-connection"
      refute first.assigns.connection_id == second.assigns.connection_id
      assert CallSocket.id(first) == UserAuth.user_session_topic(token)
      assert first.assigns.user_session_topic == CallSocket.id(first)
      refute first.assigns.connection_id == first.assigns.user_session_topic
    end

    test "rejects unauthenticated connects without assigning any Call Connection ID" do
      assert :error = connect(CallSocket, %{}, connect_info: %{session: %{}})
      assert :error = connect(CallSocket, %{}, connect_info: %{})
    end

    test "shares socket identity for one token and isolates independent tokens" do
      user = user_fixture()
      token = Accounts.generate_user_session_token(user)
      other_token = Accounts.generate_user_session_token(user)

      assert {:ok, first} =
               connect(CallSocket, %{}, connect_info: %{session: %{"user_token" => token}})

      assert {:ok, second} =
               connect(CallSocket, %{}, connect_info: %{session: %{"user_token" => token}})

      assert {:ok, independent} =
               connect(CallSocket, %{}, connect_info: %{session: %{"user_token" => other_token}})

      assert CallSocket.id(first) == CallSocket.id(second)
      assert CallSocket.id(first) == UserAuth.user_session_topic(token)
      refute CallSocket.id(first) == CallSocket.id(independent)
      assert CallSocket.id(independent) == UserAuth.user_session_topic(other_token)
    end

    test "token revocation broadcasts disconnect on the CallSocket identity" do
      user = user_fixture()
      token = Accounts.generate_user_session_token(user)

      assert {:ok, socket} =
               connect(CallSocket, %{}, connect_info: %{session: %{"user_token" => token}})

      topic = CallSocket.id(socket)
      DiscordCloneWeb.Endpoint.subscribe(topic)

      UserAuth.disconnect_sessions([%{token: token}])

      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect", topic: ^topic}
    end
  end

  describe "endpoint" do
    test "mounts /calls with the same session connect_info as /voice" do
      sockets = DiscordCloneWeb.Endpoint.__sockets__()

      {_, DiscordCloneWeb.VoiceSocket, voice_opts} =
        Enum.find(sockets, fn {path, _module, _opts} -> path == "/voice" end)

      {_, DiscordCloneWeb.CallSocket, call_opts} =
        Enum.find(sockets, fn {path, _module, _opts} -> path == "/calls" end)

      assert call_opts[:websocket][:connect_info] == voice_opts[:websocket][:connect_info]
      assert Keyword.has_key?(call_opts[:websocket][:connect_info], :session)
    end
  end

  defp expire_session_token!(token) do
    {1, _} =
      Repo.update_all(
        from(user_token in UserToken, where: user_token.token == ^token),
        set: [inserted_at: DateTime.add(DateTime.utc_now(:microsecond), -15, :day)]
      )

    :ok
  end
end
