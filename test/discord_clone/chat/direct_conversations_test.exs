defmodule DiscordClone.Chat.DirectConversationsTest do
  use DiscordClone.DataCase, async: false

  import DiscordClone.AccountsFixtures

  alias DiscordClone.Chat
  alias DiscordClone.Chat.{Conversation, DirectConversation}
  alias DiscordClone.Friendships
  alias DiscordClone.Repo
  alias DiscordClone.Workspaces

  describe "list_direct_conversation_destinations/1" do
    test "lists every Conversation by latest activity with unread and Friendship state" do
      user = user_fixture(username: "destination_owner")
      scope = user_scope_fixture(user)

      {older_friend, older_scope, older_conversation, _older_friendship} =
        direct_conversation_with(scope, "destination_older")

      {active_friend, active_scope, active_conversation, _active_friendship} =
        direct_conversation_with(scope, "destination_active")

      {former_friend, _former_scope, former_conversation, former_friendship} =
        direct_conversation_with(scope, "destination_former")

      Repo.update_all(
        from(conversation in Conversation, where: conversation.id == ^older_conversation.id),
        set: [inserted_at: ~U[2026-01-01 10:00:00.000000Z]]
      )

      Repo.update_all(
        from(conversation in Conversation, where: conversation.id == ^former_conversation.id),
        set: [inserted_at: ~U[2026-01-02 10:00:00.000000Z]]
      )

      assert {:ok, _message} =
               Chat.send_direct_message(active_scope, active_conversation.id, %{
                 content: "most recent"
               })

      assert :ok = Friendships.remove_friend(scope, former_friendship.id)

      assert {:ok, destinations} = Chat.list_direct_conversation_destinations(scope)

      assert Enum.map(destinations, & &1.direct_conversation.id) == [
               active_conversation.id,
               former_conversation.id,
               older_conversation.id
             ]

      assert [active, former, older] = destinations
      assert active.other_participant.id == active_friend.id
      assert active.unread_count == 1
      assert active.writable?
      assert %DateTime{} = active.latest_message_at

      assert former.other_participant.id == former_friend.id
      assert former.unread_count == 0
      refute former.writable?
      assert is_nil(former.latest_message_at)

      assert older.other_participant.id == older_friend.id
      assert older.unread_count == 0
      assert older.writable?
      assert is_nil(older.latest_message_at)
      assert older_scope.user.id == older_friend.id
    end

    test "uses the durable Conversation identifier as the final ordering tie-breaker" do
      user = user_fixture(username: "destination_tie_owner")
      scope = user_scope_fixture(user)

      {_first_friend, _first_scope, first_conversation, _first_friendship} =
        direct_conversation_with(scope, "destination_tie_first")

      {_second_friend, _second_scope, second_conversation, _second_friendship} =
        direct_conversation_with(scope, "destination_tie_second")

      tied_at = ~U[2026-01-03 10:00:00.000000Z]

      Repo.update_all(
        from(conversation in Conversation,
          where: conversation.id in ^[first_conversation.id, second_conversation.id]
        ),
        set: [inserted_at: tied_at]
      )

      assert {:ok, destinations} = Chat.list_direct_conversation_destinations(scope)

      assert Enum.map(destinations, & &1.direct_conversation.id) ==
               Enum.sort([first_conversation.id, second_conversation.id])
    end

    test "rejects an unauthenticated destination query" do
      assert {:error, :unauthenticated} = Chat.list_direct_conversation_destinations(nil)
    end
  end

  describe "open_direct_conversation/2" do
    test "creates one empty Direct Conversation lazily for an accepted Friendship" do
      {first_user, second_user, first_scope, _second_scope, _friendship} = accepted_friendship()

      assert {:error, :not_found} =
               Chat.find_direct_conversation(first_scope, second_user.id)

      assert {:ok, direct_conversation} =
               Chat.open_direct_conversation(first_scope, second_user.id)

      assert direct_conversation.user_low_id in [first_user.id, second_user.id]
      assert direct_conversation.user_high_id in [first_user.id, second_user.id]
      assert direct_conversation.user_low_id < direct_conversation.user_high_id
      assert direct_conversation.conversation.kind == :direct_conversation
      assert direct_conversation.conversation.last_message_seq == 0

      assert {:ok, found} = Chat.find_direct_conversation(first_scope, second_user.id)
      assert found.id == direct_conversation.id
    end

    test "does not create a Direct Conversation for a pending request or by accepting alone" do
      first_user = user_fixture(username: "lazy_pending_first")
      second_user = user_fixture(username: "lazy_pending_second")
      first_scope = user_scope_fixture(first_user)
      second_scope = user_scope_fixture(second_user)

      assert {:ok, %{relationship: request}} =
               Friendships.send_friend_request(first_scope, %{username: second_user.username})

      assert {:error, :not_friends} = Chat.open_direct_conversation(first_scope, second_user.id)

      assert {:error, :not_found} =
               Chat.find_direct_conversation(first_scope, second_user.id)

      assert {:ok, _friendship} = Friendships.accept_friend_request(second_scope, request.id)

      assert {:error, :not_found} =
               Chat.find_direct_conversation(first_scope, second_user.id)

      assert {:error, :not_found} =
               Chat.find_direct_conversation(second_scope, first_user.id)
    end

    test "simultaneous first opens converge on the canonical pair" do
      {_first_user, second_user, first_scope, second_scope, _friendship} =
        accepted_friendship("concurrent")

      parent = self()

      workers =
        [
          {first_scope, second_user.id},
          {second_scope, first_scope.user.id},
          {first_scope, second_user.id},
          {second_scope, first_scope.user.id}
        ]
        |> Enum.with_index()
        |> Enum.map(fn {{scope, friend_user_id}, index} ->
          pid =
            start_supervised!(%{
              id: {__MODULE__, index},
              start:
                {Task, :start_link,
                 [
                   fn ->
                     send(parent, {:ready, self()})

                     receive do
                       {:open, ^parent} ->
                         send(
                           parent,
                           {:opened, Chat.open_direct_conversation(scope, friend_user_id)}
                         )
                     end
                   end
                 ]}
            })

          assert_receive {:ready, ^pid}
          pid
        end)

      Enum.each(workers, &send(&1, {:open, parent}))

      results =
        for _worker <- workers do
          assert_receive {:opened, {:ok, direct_conversation}}
          direct_conversation
        end

      assert results |> Enum.map(& &1.id) |> Enum.uniq() |> length() == 1

      assert {:ok, one_direct_conversation} =
               Chat.find_direct_conversation(first_scope, second_user.id)

      assert one_direct_conversation.id == hd(results).id
    end

    test "preserves history identity after removal and reuses it after restoration" do
      {_first_user, second_user, first_scope, second_scope, friendship} =
        accepted_friendship("restored")

      assert {:ok, original} = Chat.open_direct_conversation(first_scope, second_user.id)
      assert :ok = Friendships.remove_friend(first_scope, friendship.id)

      assert {:ok, preserved} = Chat.get_direct_conversation(second_scope, original.id)
      assert preserved.direct_conversation.id == original.id
      assert {:ok, still_accessible} = Chat.open_direct_conversation(first_scope, second_user.id)
      assert still_accessible.id == original.id

      assert {:ok, %{relationship: request}} =
               Friendships.send_friend_request(first_scope, %{username: second_user.username})

      assert {:ok, _restored_friendship} =
               Friendships.accept_friend_request(second_scope, request.id)

      assert {:ok, reopened} = Chat.open_direct_conversation(second_scope, first_scope.user.id)
      assert reopened.id == original.id
    end

    test "rejects unauthenticated, self, missing, and non-Friend opens" do
      user = user_fixture(username: "invalid_open_user")
      other_user = user_fixture(username: "invalid_open_other")
      scope = user_scope_fixture(user)

      assert {:error, :unauthenticated} = Chat.open_direct_conversation(nil, other_user.id)
      assert {:error, :invalid_participant} = Chat.open_direct_conversation(scope, user.id)
      assert {:error, :not_found} = Chat.open_direct_conversation(scope, Ecto.UUID.generate())
      assert {:error, :not_friends} = Chat.open_direct_conversation(scope, other_user.id)
    end
  end

  describe "get_direct_conversation/2" do
    test "returns the same private Conversation to either participant and not-found to others" do
      {_first_user, second_user, first_scope, second_scope, _friendship} =
        accepted_friendship("private")

      outsider_scope = user_scope_fixture(user_fixture(username: "private_outsider"))
      {:ok, direct_conversation} = Chat.open_direct_conversation(first_scope, second_user.id)

      assert {:ok, first_view} =
               Chat.get_direct_conversation(first_scope, direct_conversation.id)

      assert {:ok, second_view} =
               Chat.get_direct_conversation(second_scope, direct_conversation.id)

      assert first_view.direct_conversation.id == second_view.direct_conversation.id
      assert first_view.other_participant.id == second_scope.user.id
      assert second_view.other_participant.id == first_scope.user.id

      assert {:error, :not_found} =
               Chat.get_direct_conversation(outsider_scope, direct_conversation.id)

      assert {:error, :not_found} =
               Chat.get_direct_conversation(outsider_scope, Ecto.UUID.generate())

      assert {:error, :unauthenticated} =
               Chat.get_direct_conversation(nil, direct_conversation.id)
    end

    test "participant foreign keys restrict hard User deletion" do
      {first_user, second_user, first_scope, _second_scope, friendship} =
        accepted_friendship("delete")

      assert {:ok, _direct_conversation} =
               Chat.open_direct_conversation(first_scope, second_user.id)

      assert :ok = Friendships.remove_friend(first_scope, friendship.id)
      assert_raise Ecto.ConstraintError, fn -> Repo.delete!(first_user) end
    end
  end

  describe "Direct Conversation message windows" do
    test "loads bounded latest, older, newer, and around-target windows for participants" do
      scope = user_scope_fixture()

      {_friend, _friend_scope, direct_conversation, _friendship} =
        direct_conversation_with(scope, "window_friend")

      messages =
        for index <- 1..75 do
          assert {:ok, message} =
                   Chat.send_direct_message(scope, direct_conversation.id, %{
                     content: "bounded message #{index}"
                   })

          message
        end

      assert {:ok, latest} =
               Chat.load_latest_direct_message_window(scope, direct_conversation.id)

      assert Enum.map(latest.messages, & &1.seq) == Enum.to_list(26..75)

      assert latest.meta == %{
               oldest_seq: 26,
               newest_seq: 75,
               latest_seq: 75,
               has_older?: true,
               has_newer?: false,
               at_latest?: true,
               at_or_near_latest?: true
             }

      assert {:ok, older} =
               Chat.load_older_direct_message_window(scope, direct_conversation.id, 26)

      assert Enum.map(older.messages, & &1.seq) == Enum.to_list(1..25)
      refute older.meta.has_older?
      assert older.meta.has_newer?

      assert {:ok, newer} =
               Chat.load_newer_direct_message_window(scope, direct_conversation.id, 25)

      assert Enum.map(newer.messages, & &1.seq) == Enum.to_list(26..75)
      assert newer.meta.at_latest?

      target = Enum.at(messages, 39)

      assert {:ok, around} =
               Chat.navigate_to_direct_message(scope, direct_conversation.id, target.id)

      assert around.target.id == target.id
      assert Enum.map(around.messages, & &1.seq) == Enum.to_list(25..75)
    end

    test "redacts deleted content in windows and does not disclose targets to outsiders" do
      owner_scope = user_scope_fixture()

      {_friend, _friend_scope, direct_conversation, _friendship} =
        direct_conversation_with(owner_scope, "private_window_friend")

      assert {:ok, deleted} =
               Chat.send_direct_message(owner_scope, direct_conversation.id, %{content: "secret"})

      assert {:ok, _deleted} = Chat.delete_message(owner_scope, deleted.id)

      assert {:ok, window} =
               Chat.load_latest_direct_message_window(owner_scope, direct_conversation.id)

      assert [%{content: nil}] = window.messages

      outsider_scope = user_scope_fixture(user_fixture(username: "private_window_outsider"))

      assert {:error, :not_found} =
               Chat.navigate_to_direct_message(
                 outsider_scope,
                 direct_conversation.id,
                 deleted.id
               )

      assert {:error, :not_found} =
               Chat.navigate_to_direct_message(
                 outsider_scope,
                 Ecto.UUID.generate(),
                 Ecto.UUID.generate()
               )
    end
  end

  describe "Direct Conversation typing and runtime recovery" do
    test "current Friends type ephemerally while former Friends and outsiders cannot" do
      scope = user_scope_fixture()

      {friend, friend_scope, direct_conversation, friendship} =
        direct_conversation_with(scope, "typing_friend")

      assert :ok = Chat.subscribe_to_direct_messages(friend_scope, direct_conversation.id)
      assert :ok = Chat.direct_user_started_typing(scope, direct_conversation.id)

      assert_receive {:typing_started, %{conversation_id: conversation_id, user_id: user_id}}

      assert conversation_id == direct_conversation.id
      assert user_id == scope.user.id

      assert {:ok, [^user_id]} =
               Chat.list_direct_typing_user_ids(friend_scope, direct_conversation.id)

      assert :ok = Friendships.remove_friend(friend_scope, friendship.id)

      assert {:error, :not_friends} =
               Chat.direct_user_started_typing(scope, direct_conversation.id)

      assert :ok = Chat.direct_user_stopped_typing(scope, direct_conversation.id)
      assert {:ok, []} = Chat.list_direct_typing_user_ids(friend_scope, direct_conversation.id)

      outsider_scope = user_scope_fixture(user_fixture(username: "typing_outsider"))

      assert {:error, :not_found} =
               Chat.direct_user_started_typing(outsider_scope, direct_conversation.id)

      assert friend.id == friend_scope.user.id
    end

    test "typing expires automatically without persistence" do
      scope = user_scope_fixture()

      {_friend, friend_scope, direct_conversation, _friendship} =
        direct_conversation_with(scope, "typing_expiry_friend")

      previous = Application.get_env(:discord_clone, :conversation_runtime_typing_timeout_ms)
      Application.put_env(:discord_clone, :conversation_runtime_typing_timeout_ms, 0)

      on_exit(fn ->
        if is_nil(previous) do
          Application.delete_env(:discord_clone, :conversation_runtime_typing_timeout_ms)
        else
          Application.put_env(:discord_clone, :conversation_runtime_typing_timeout_ms, previous)
        end
      end)

      assert :ok = Chat.subscribe_to_direct_messages(friend_scope, direct_conversation.id)
      assert :ok = Chat.direct_user_started_typing(scope, direct_conversation.id)

      assert_receive {:typing_started, %{user_id: user_id}}
      assert_receive {:typing_stopped, %{user_id: ^user_id}}
      assert {:ok, []} = Chat.list_direct_typing_user_ids(friend_scope, direct_conversation.id)
    end

    test "restarts after idle shutdown and reloads bounded durable Direct Messages" do
      scope = user_scope_fixture()

      {_friend, _friend_scope, direct_conversation, _friendship} =
        direct_conversation_with(scope, "recovery_friend")

      assert {:ok, message} =
               Chat.send_direct_message(scope, direct_conversation.id, %{content: "durable"})

      previous = Application.get_env(:discord_clone, :conversation_runtime_inactivity_timeout_ms)
      Application.put_env(:discord_clone, :conversation_runtime_inactivity_timeout_ms, 0)

      on_exit(fn ->
        if is_nil(previous) do
          Application.delete_env(:discord_clone, :conversation_runtime_inactivity_timeout_ms)
        else
          Application.put_env(
            :discord_clone,
            :conversation_runtime_inactivity_timeout_ms,
            previous
          )
        end
      end)

      assert {:ok, first_pid} =
               Chat.ensure_direct_conversation_runtime(scope, direct_conversation.id)

      ref = Process.monitor(first_pid)
      assert_receive {:DOWN, ^ref, :process, ^first_pid, :normal}

      Application.put_env(
        :discord_clone,
        :conversation_runtime_inactivity_timeout_ms,
        :timer.minutes(15)
      )

      assert {:ok, [reloaded]} =
               Chat.list_recent_direct_messages(scope, direct_conversation.id)

      assert reloaded.id == message.id
      assert reloaded.content == "durable"

      assert {:ok, second_pid} =
               Chat.ensure_direct_conversation_runtime(scope, direct_conversation.id)

      assert second_pid != first_pid
    end
  end

  describe "Direct Conversation persistence invariants" do
    test "rejects a bare Direct Conversation base and a subtype with the wrong kind" do
      assert_raise Postgrex.Error, ~r/conversations_require_matching_subtype/, fn ->
        Repo.transaction(fn ->
          %Conversation{}
          |> Conversation.direct_conversation_changeset()
          |> Repo.insert!()

          Ecto.Adapters.SQL.query!(Repo, "SET CONSTRAINTS ALL IMMEDIATE", [])
        end)
      end

      first_user = user_fixture(username: "wrong_kind_first")
      second_user = user_fixture(username: "wrong_kind_second")

      {:ok, workspace} =
        Workspaces.create_workspace(user_scope_fixture(first_user), %{name: "Wrong subtype"})

      assert_raise Postgrex.Error, ~r/direct_conversations_require_direct_kind/, fn ->
        %DirectConversation{id: workspace.default_channel_id}
        |> DirectConversation.create_changeset(%{
          user_low_id: min(first_user.id, second_user.id),
          user_high_id: max(first_user.id, second_user.id)
        })
        |> Repo.insert!()
      end
    end

    test "rejects a repeated User and has no Workspace identity" do
      user = user_fixture(username: "same_direct_participant")

      assert_raise Postgrex.Error, ~r/direct_conversations_canonical_pair/, fn ->
        Repo.transaction(fn ->
          conversation =
            %Conversation{}
            |> Conversation.direct_conversation_changeset()
            |> Repo.insert!()

          Ecto.Adapters.SQL.query!(
            Repo,
            """
            INSERT INTO direct_conversations (
              conversation_id, user_low_id, user_high_id, inserted_at, updated_at
            ) VALUES ($1, $2, $2, now(), now())
            """,
            [Ecto.UUID.dump!(conversation.id), Ecto.UUID.dump!(user.id)]
          )
        end)
      end

      refute :workspace_id in DirectConversation.__schema__(:fields)
    end

    test "rejects deleting the subtype while its Conversation base remains" do
      {_first_user, second_user, first_scope, _second_scope, _friendship} =
        accepted_friendship("orphan")

      {:ok, direct_conversation} =
        Chat.open_direct_conversation(first_scope, second_user.id)

      assert_raise Postgrex.Error, ~r/conversations_require_matching_subtype/, fn ->
        Repo.transaction(fn ->
          Repo.delete!(direct_conversation)
          Ecto.Adapters.SQL.query!(Repo, "SET CONSTRAINTS ALL IMMEDIATE", [])
        end)
      end

      assert Repo.get(Conversation, direct_conversation.id)
    end
  end

  defp accepted_friendship(suffix \\ "lazy") do
    first_user = user_fixture(username: "#{suffix}_first")
    second_user = user_fixture(username: "#{suffix}_second")
    first_scope = user_scope_fixture(first_user)
    second_scope = user_scope_fixture(second_user)

    assert {:ok, %{relationship: request}} =
             Friendships.send_friend_request(first_scope, %{username: second_user.username})

    assert {:ok, friendship} = Friendships.accept_friend_request(second_scope, request.id)

    {first_user, second_user, first_scope, second_scope, friendship}
  end

  defp direct_conversation_with(scope, username) do
    friend = user_fixture(username: username)
    friend_scope = user_scope_fixture(friend)

    assert {:ok, %{relationship: request}} =
             Friendships.send_friend_request(scope, %{username: friend.username})

    assert {:ok, friendship} = Friendships.accept_friend_request(friend_scope, request.id)
    assert {:ok, direct_conversation} = Chat.open_direct_conversation(scope, friend.id)

    {friend, friend_scope, direct_conversation, friendship}
  end
end
