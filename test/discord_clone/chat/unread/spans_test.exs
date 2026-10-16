defmodule DiscordClone.Chat.Unread.SpansTest do
  use DiscordClone.DataCase, async: false

  import Ecto.Query

  alias DiscordClone.Chat
  alias DiscordClone.Chat.{Conversation, Message}
  alias DiscordClone.Workspaces
  alias DiscordClone.Workspaces.WorkspaceMembership

  import DiscordClone.AccountsFixtures

  describe "unread span behavior through the Chat context" do
    test "coalesces overlapping and adjacent unread ranges into one summary" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})

      assert {:ok, _read_state} =
               Chat.add_channel_unread_range(scope, workspace.default_channel_id, 8, 10)

      assert {:ok, _read_state} =
               Chat.add_channel_unread_range(scope, workspace.default_channel_id, 2, 4)

      assert {:ok, read_state} =
               Chat.add_channel_unread_range(scope, workspace.default_channel_id, 5, 8)

      assert read_state.unread_count == 9
      assert read_state.first_unread_seq == 2
      assert read_state.last_unread_seq == 10

      assert {:ok, [summary]} = Chat.list_channel_read_summaries(scope, workspace.id)
      assert summary.unread_count == 9
      assert summary.first_unread_seq == 2
      assert summary.last_unread_seq == 10
    end

    test "subtracts visible ranges across exact, edge, middle, and disjoint spans" do
      scope = user_scope_fixture()
      other_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      add_workspace_member!(workspace, other_scope)
      insert_messages!(workspace.default_channel_id, other_scope.user.id, 12)

      assert {:ok, _read_state} =
               Chat.add_channel_unread_range(scope, workspace.default_channel_id, 2, 4)

      assert {:ok, _read_state} =
               Chat.add_channel_unread_range(scope, workspace.default_channel_id, 8, 10)

      assert {:ok, read_state} =
               Chat.subtract_visible_read_range(scope, workspace.default_channel_id, 4, 8)

      assert read_state.unread_count == 4
      assert read_state.first_unread_seq == 2
      assert read_state.last_unread_seq == 10

      assert {:ok, read_state} =
               Chat.subtract_visible_read_range(scope, workspace.default_channel_id, 3, 9)

      assert read_state.unread_count == 2
      assert read_state.first_unread_seq == 2
      assert read_state.last_unread_seq == 10

      assert {:ok, read_state} =
               Chat.subtract_visible_read_range(scope, workspace.default_channel_id, 1, 12)

      assert read_state.unread_count == 0
      assert is_nil(read_state.first_unread_seq)
      assert is_nil(read_state.last_unread_seq)
    end

    test "rejects over-large visible ranges without changing the unread summary" do
      scope = user_scope_fixture()
      other_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      add_workspace_member!(workspace, other_scope)
      insert_messages!(workspace.default_channel_id, other_scope.user.id, 60)

      assert {:ok, read_state} =
               Chat.add_channel_unread_range(scope, workspace.default_channel_id, 20, 22)

      assert Chat.subtract_visible_read_range(scope, workspace.default_channel_id, 1, 51) ==
               {:error, :range_too_large}

      assert {:ok, [summary]} = Chat.list_channel_read_summaries(scope, workspace.id)
      assert summary.unread_count == read_state.unread_count
      assert summary.first_unread_seq == read_state.first_unread_seq
      assert summary.last_unread_seq == read_state.last_unread_seq
    end
  end

  defp insert_messages!(channel_id, user_id, count) do
    for index <- 1..count do
      insert_message!(
        channel_id,
        user_id,
        "message #{index}",
        DateTime.add(~U[2026-06-19 10:00:00Z], index, :second)
      )
    end
  end

  defp insert_message!(channel_id, user_id, content, inserted_at) do
    inserted_at = %{inserted_at | microsecond: {elem(inserted_at.microsecond, 0), 6}}

    {:ok, message} =
      Repo.transaction(fn ->
        conversation =
          Repo.one!(
            from conversation in Conversation,
              where: conversation.id == ^channel_id,
              lock: "FOR UPDATE"
          )

        seq = conversation.last_message_seq + 1

        message =
          Repo.insert!(%Message{
            channel_id: channel_id,
            user_id: user_id,
            content: content,
            seq: seq,
            inserted_at: inserted_at,
            updated_at: inserted_at
          })

        conversation
        |> Ecto.Changeset.change(last_message_seq: seq)
        |> Repo.update!()

        message
      end)

    message
  end

  defp add_workspace_member!(workspace, scope) do
    %WorkspaceMembership{}
    |> WorkspaceMembership.changeset(%{
      workspace_id: workspace.id,
      user_id: scope.user.id,
      role: "member"
    })
    |> Repo.insert!()
  end
end
