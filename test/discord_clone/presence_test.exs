defmodule DiscordClone.PresenceTest do
  use DiscordClone.DataCase, async: false

  import DiscordClone.AccountsFixtures

  alias DiscordClone.{Friendships, Presence}

  test "requires authentication and current Friendship for private status access" do
    user = user_fixture(username: "presence_access_user")
    friend = user_fixture(username: "presence_access_friend")
    stranger = user_fixture(username: "presence_access_stranger")
    user_scope = user_scope_fixture(user)
    friend_scope = user_scope_fixture(friend)

    friendship = accept_friendship(user_scope, friend_scope, friend.username)

    assert {:error, :unauthenticated} = Presence.list_online_friend_ids(nil)
    assert {:error, :unauthenticated} = Presence.subscribe_to_friend(nil, friend.id)
    assert {:error, :not_found} = Presence.friend_status(user_scope, stranger.id)
    assert {:error, :not_found} = Presence.subscribe_to_friend(user_scope, stranger.id)
    assert {:ok, :offline} = Presence.friend_status(user_scope, friend.id)
    assert :ok = Presence.subscribe_to_friend(user_scope, friend.id)

    connection = spawn_connection()
    assert :ok = Presence.join(friend_scope, connection)
    assert_receive {:friend_presence_changed, %{user_id: friend_id, state: :online}}

    assert :ok = Friendships.remove_friend(user_scope, friendship.id)

    presence_pid = Presence.user_presence_pid(friend.id)
    _ = :sys.get_state(presence_pid)
    presence_ref = Process.monitor(presence_pid)
    stop_connection(connection)
    assert_receive {:DOWN, ^presence_ref, :process, ^presence_pid, :normal}
    refute_receive {:friend_presence_changed, %{user_id: ^friend_id, state: :offline}}

    assert {:error, :not_found} = Presence.friend_status(user_scope, friend.id)
    assert {:error, :not_found} = Presence.subscribe_to_friend(user_scope, friend.id)
  end

  test "reports edge-triggered global presence and revokes events after unfriend" do
    user = user_fixture(username: "presence_events_user")
    friend = user_fixture(username: "presence_events_friend")
    user_scope = user_scope_fixture(user)
    friend_scope = user_scope_fixture(friend)
    friendship = accept_friendship(user_scope, friend_scope, friend.username)

    assert :ok = Presence.subscribe_to_friend(user_scope, friend.id)
    assert {:ok, []} = Presence.list_online_friend_ids(user_scope)

    first_connection = spawn_connection()
    second_connection = spawn_connection()

    assert :ok = Presence.join(friend_scope, first_connection)
    assert_receive {:friend_presence_changed, %{user_id: friend_id, state: :online}}
    assert friend_id == friend.id
    assert {:ok, [friend_id]} = Presence.list_online_friend_ids(user_scope)

    assert :ok = Presence.join(friend_scope, first_connection)
    assert :ok = Presence.join(friend_scope, second_connection)
    refute_receive {:friend_presence_changed, %{user_id: ^friend_id, state: :online}}

    stop_connection(first_connection)
    refute_receive {:friend_presence_changed, %{user_id: ^friend_id, state: :offline}}

    presence_pid = Presence.user_presence_pid(friend.id)
    presence_ref = Process.monitor(presence_pid)
    stop_connection(second_connection)

    assert_receive {:friend_presence_changed, %{user_id: ^friend_id, state: :offline}}
    assert_receive {:DOWN, ^presence_ref, :process, ^presence_pid, :normal}

    assert :ok = Friendships.remove_friend(user_scope, friendship.id)

    replacement_connection = spawn_connection()
    assert :ok = Presence.join(friend_scope, replacement_connection)
    refute_receive {:friend_presence_changed, %{user_id: ^friend_id}}
    replacement_presence_pid = Presence.user_presence_pid(friend.id)
    replacement_presence_ref = Process.monitor(replacement_presence_pid)
    stop_connection(replacement_connection)

    assert_receive {:DOWN, ^replacement_presence_ref, :process, ^replacement_presence_pid,
                    :normal}
  end

  defp accept_friendship(requester_scope, recipient_scope, recipient_username) do
    assert {:ok, %{relationship: request}} =
             Friendships.send_friend_request(requester_scope, %{username: recipient_username})

    assert {:ok, friendship} = Friendships.accept_friend_request(recipient_scope, request.id)
    friendship
  end

  defp spawn_connection do
    start_supervised!(
      {Task, fn -> receive do: (:stop -> :ok) end},
      id: {:presence_connection, System.unique_integer([:positive])}
    )
  end

  defp stop_connection(pid) do
    ref = Process.monitor(pid)
    send(pid, :stop)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
  end
end
