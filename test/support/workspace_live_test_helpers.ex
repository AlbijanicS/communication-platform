defmodule DiscordCloneWeb.WorkspaceLiveTestHelpers do
  import Ecto.Query
  import ExUnit.Callbacks
  import Phoenix.LiveViewTest

  alias DiscordClone.Chat
  alias DiscordClone.Chat.{Conversation, Message}
  alias DiscordClone.Repo
  alias DiscordClone.Workspaces
  alias DiscordClone.Workspaces.WorkspaceMembership

  def expire_active_timeout!(workspace_id, target_user_id) do
    moderation =
      Repo.one!(
        from moderation in DiscordClone.Workspaces.WorkspaceModeration,
          where:
            moderation.workspace_id == ^workspace_id and
              moderation.target_user_id == ^target_user_id and
              moderation.type == "timeout" and
              moderation.active? == true
      )

    moderation
    |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(:second), -1, :second))
    |> Repo.update!()

    {:ok, _expired} = Workspaces.expire_member_timeout(moderation.id)
  end

  def add_workspace_member!(workspace, scope, role \\ "member") do
    %WorkspaceMembership{}
    |> WorkspaceMembership.changeset(%{
      workspace_id: workspace.id,
      user_id: scope.user.id,
      role: role
    })
    |> Repo.insert!()
  end

  def workspace_with_sibling_unread!(member_scope, role \\ "member") do
    owner_scope = DiscordClone.AccountsFixtures.user_scope_fixture()
    {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
    {:ok, sibling_channel} = Workspaces.create_channel(owner_scope, workspace.id, %{name: "ops"})

    add_workspace_member!(workspace, member_scope, role)
    :ok = Chat.initialize_workspace_reads_for_user(member_scope.user.id, workspace.id)
    {:ok, _message} = Chat.send_message(owner_scope, sibling_channel.id, %{content: "ops update"})

    {owner_scope, workspace, sibling_channel}
  end

  def rendered_message_ids(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> then(& &1["#channel-messages > article"])
    |> LazyHTML.attribute("id")
  end

  def insert_message!(channel_id, user_id, content, inserted_at) do
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

  def start_live_view_process do
    start_supervised!(%{
      id: System.unique_integer([:positive]),
      start:
        {Task, :start_link,
         [
           fn ->
             receive do
               :stop -> :ok
             end
           end
         ]}
    })
  end

  def workspace_member_row_ids(view, user_id) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> then(& &1["#workspace-members > #workspace-member-#{user_id}"])
    |> LazyHTML.attribute("id")
  end
end
