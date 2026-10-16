defmodule DiscordClone.Chat.DirectMessageConcurrencyTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import DiscordClone.AccountsFixtures

  alias DiscordClone.Chat
  alias DiscordClone.Chat.Conversation
  alias DiscordClone.Friendships
  alias DiscordClone.Repo
  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    on_exit(fn -> Sandbox.checkin(Repo) end)
  end

  test "a send holding the Friendship lock completes before concurrent removal" do
    suffix = System.unique_integer([:positive])
    parent = self()
    application_name = "direct_send_#{suffix}"

    _setup =
      start_database_task(:setup, fn ->
        sender_scope =
          user_scope_fixture(unconfirmed_user_fixture(username: "race_sender_#{suffix}"))

        recipient_scope =
          user_scope_fixture(unconfirmed_user_fixture(username: "race_recipient_#{suffix}"))

        {:ok, %{relationship: request}} =
          Friendships.send_friend_request(sender_scope, %{username: recipient_scope.user.username})

        {:ok, friendship} = Friendships.accept_friend_request(recipient_scope, request.id)

        {:ok, direct_conversation} =
          Chat.open_direct_conversation(sender_scope, recipient_scope.user.id)

        send(
          parent,
          {:fixture, sender_scope, recipient_scope, direct_conversation, friendship}
        )
      end)

    assert_receive {:fixture, sender_scope, recipient_scope, direct_conversation, friendship},
                   1_000

    blocker =
      start_database_task(:conversation_blocker, fn ->
        Repo.transaction(fn ->
          Repo.one!(
            from conversation in Conversation,
              where: conversation.id == ^direct_conversation.id,
              lock: "FOR UPDATE"
          )

          send(parent, {:conversation_locked, self()})

          receive do
            {:release_conversation, ^parent} -> :ok
          end
        end)
      end)

    assert_receive {:conversation_locked, ^blocker}, 1_000

    _sender =
      start_database_task(:sender, fn ->
        set_application_name(application_name)

        result =
          Chat.send_direct_message(sender_scope, direct_conversation.id, %{content: "race"})

        send(parent, {:send_result, result})
      end)

    assert_waiting_on_lock(application_name)

    _remover =
      start_database_task(:remover, fn ->
        result = Friendships.remove_friend(recipient_scope, friendship.id)
        send(parent, {:remove_result, result})
      end)

    refute_receive {:remove_result, _result}, 100
    refute_receive {:send_result, _result}, 100

    send(blocker, {:release_conversation, parent})

    assert_receive {:send_result, {:ok, message}}, 1_000
    assert_receive {:remove_result, :ok}, 1_000
    assert message.seq == 1
    assert {:ok, [persisted]} = Chat.list_direct_messages(sender_scope, direct_conversation.id)
    assert persisted.id == message.id

    _cleanup =
      start_database_task(:cleanup, fn ->
        Repo.delete!(Repo.get!(Conversation, direct_conversation.id))
        Repo.delete!(sender_scope.user)
        Repo.delete!(recipient_scope.user)
        send(parent, :cleanup_complete)
      end)

    assert_receive :cleanup_complete, 1_000
  end

  defp start_database_task(id, fun) do
    start_supervised!(%{
      id: {__MODULE__, id},
      restart: :temporary,
      start:
        {Task, :start_link,
         [
           fn ->
             :ok = Sandbox.checkout(Repo, sandbox: false)

             try do
               fun.()
             after
               :ok = Sandbox.checkin(Repo)
             end
           end
         ]}
    })
  end

  defp set_application_name(application_name) do
    SQL.query!(Repo, "SELECT set_config('application_name', $1, false)", [application_name])
  end

  defp assert_waiting_on_lock(application_name) do
    deadline = System.monotonic_time(:millisecond) + 3_000
    assert_waiting_on_lock(application_name, deadline)
  end

  defp assert_waiting_on_lock(application_name, deadline) do
    waiting? =
      SQL.query!(
        Repo,
        """
        SELECT EXISTS (
          SELECT 1
          FROM pg_stat_activity
          WHERE application_name = $1
            AND state = 'active'
            AND wait_event_type = 'Lock'
        )
        """,
        [application_name]
      ).rows == [[true]]

    cond do
      waiting? ->
        :ok

      System.monotonic_time(:millisecond) < deadline ->
        :erlang.yield()
        assert_waiting_on_lock(application_name, deadline)

      true ->
        flunk("expected #{application_name} to block after taking the Friendship lock")
    end
  end
end
