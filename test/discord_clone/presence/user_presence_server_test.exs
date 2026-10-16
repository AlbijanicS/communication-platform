defmodule DiscordClone.Presence.UserPresenceServerTest do
  use ExUnit.Case, async: true

  alias DiscordClone.Presence.UserPresenceServer

  test "broadcasts only connection edges and stops after the final connection exits" do
    test_pid = self()
    user_id = Ecto.UUID.generate()
    registry = unique_registry_name()
    start_supervised!({Registry, keys: :unique, name: registry})

    server =
      start_supervised!(
        {UserPresenceServer,
         user_id: user_id, registry: registry, transition: &send(test_pid, {user_id, &1})}
      )

    first_connection = start_connection()
    second_connection = start_connection()

    assert :ok = UserPresenceServer.join(server, first_connection)
    assert_receive {^user_id, :online}

    assert :ok = UserPresenceServer.join(server, first_connection)
    assert :ok = UserPresenceServer.join(server, second_connection)
    refute_receive {^user_id, :online}

    send(first_connection, :stop)
    _ = :sys.get_state(server)
    refute_receive {^user_id, :offline}

    server_ref = Process.monitor(server)
    send(second_connection, :stop)

    assert_receive {^user_id, :offline}
    assert_receive {:DOWN, ^server_ref, :process, ^server, :normal}
  end

  test "pending Friendship actions never enter the authorized transition audience" do
    test_pid = self()
    user_id = Ecto.UUID.generate()
    existing_friend_id = Ecto.UUID.generate()
    pending_user_id = Ecto.UUID.generate()
    registry = unique_registry_name()
    start_supervised!({Registry, keys: :unique, name: registry})

    server =
      start_supervised!(
        {UserPresenceServer,
         user_id: user_id, registry: registry, transition: &send(test_pid, {&1, &2})}
      )

    connection = start_connection()
    assert :ok = UserPresenceServer.join(server, connection, [existing_friend_id])
    assert_receive {:online, [^existing_friend_id]}

    send(server, {
      :friendships_changed,
      %{action: :requested, friend_user_id: pending_user_id}
    })

    _ = :sys.get_state(server)
    server_ref = Process.monitor(server)
    send(connection, :stop)

    assert_receive {:offline, [^existing_friend_id]}
    assert_receive {:DOWN, ^server_ref, :process, ^server, :normal}
  end

  defp unique_registry_name do
    String.to_atom("presence_test_registry_#{System.unique_integer([:positive])}")
  end

  defp start_connection do
    start_supervised!(
      {Task, fn -> receive do: (:stop -> :ok) end},
      id: {:connection, System.unique_integer([:positive])}
    )
  end
end
