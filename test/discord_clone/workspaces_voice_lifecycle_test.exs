defmodule DiscordClone.WorkspacesVoiceLifecycleTest do
  use DiscordClone.DataCase, async: false

  alias DiscordClone.Voice
  alias DiscordClone.Workspaces
  alias DiscordClone.Repo
  alias DiscordClone.Workspaces.{VoiceChannel, WorkspaceMembership}

  import DiscordClone.AccountsFixtures

  describe "durable access revocation" do
    test "a permitted Voice Disconnect ends only the target Voice Session without changing Workspace state" do
      owner_scope = user_scope_fixture()
      disconnected_scope = user_scope_fixture()
      retained_scope = user_scope_fixture()

      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Voice Disconnect"})
      add_workspace_member!(workspace, disconnected_scope)
      add_workspace_member!(workspace, retained_scope)

      {:ok, voice_channel} =
        Workspaces.create_voice_channel(owner_scope, workspace.id, %{name: "lobby"})

      on_exit(fn -> cleanup_room(voice_channel.id) end)

      assert {:ok, %{occupancy: 1}} =
               Voice.join(
                 voice_channel.id,
                 disconnected_scope.user.id,
                 "disconnected-connection",
                 self()
               )

      assert {:ok, %{occupancy: 2}} =
               Voice.join(voice_channel.id, retained_scope.user.id, "retained-connection", self())

      assert :ok =
               Workspaces.voice_disconnect_member(
                 owner_scope,
                 workspace.id,
                 voice_channel.id,
                 disconnected_scope.user.id
               )

      assert {:ok, %{occupancy: 1, capacity: 5}} = Voice.room_occupancy(voice_channel.id)

      assert {:ok, members} = Workspaces.list_members(owner_scope, workspace.id)

      assert Enum.any?(members, &(&1.user_id == disconnected_scope.user.id))
      assert Enum.any?(members, &(&1.user_id == retained_scope.user.id))

      assert {:ok, %{occupancy: 2}} =
               Voice.join(
                 voice_channel.id,
                 disconnected_scope.user.id,
                 "eligible-rejoin",
                 self()
               )
    end

    test "Voice Disconnect rejects unauthorized actors and leaves a moved Voice Session alone" do
      owner_scope = user_scope_fixture()
      member_scope = user_scope_fixture()
      target_scope = user_scope_fixture()

      {:ok, workspace} =
        Workspaces.create_workspace(owner_scope, %{name: "Voice Disconnect Safety"})

      add_workspace_member!(workspace, member_scope)
      add_workspace_member!(workspace, target_scope)

      {:ok, first_voice_channel} =
        Workspaces.create_voice_channel(owner_scope, workspace.id, %{name: "lobby"})

      {:ok, second_voice_channel} =
        Workspaces.create_voice_channel(owner_scope, workspace.id, %{name: "focus"})

      on_exit(fn -> cleanup_room(first_voice_channel.id) end)
      on_exit(fn -> cleanup_room(second_voice_channel.id) end)

      assert {:ok, %{occupancy: 1}} =
               Voice.join(
                 first_voice_channel.id,
                 target_scope.user.id,
                 "target-connection",
                 self()
               )

      assert {:error, :unauthorized} =
               Workspaces.voice_disconnect_member(
                 member_scope,
                 workspace.id,
                 first_voice_channel.id,
                 target_scope.user.id
               )

      assert {:ok, %{occupancy: 1, capacity: 5}} = Voice.room_occupancy(first_voice_channel.id)

      assert {:ok, %{occupancy: 1}} =
               Voice.join(
                 second_voice_channel.id,
                 target_scope.user.id,
                 "moved-connection",
                 self()
               )

      assert :ok =
               Workspaces.voice_disconnect_member(
                 owner_scope,
                 workspace.id,
                 first_voice_channel.id,
                 target_scope.user.id
               )

      assert {:ok, %{occupancy: 1, capacity: 5}} = Voice.room_occupancy(second_voice_channel.id)

      assert :ok =
               Workspaces.voice_disconnect_member(
                 owner_scope,
                 workspace.id,
                 first_voice_channel.id,
                 target_scope.user.id
               )
    end

    test "a Workspace Mute keeps a Voice Session connected and publishes only its effective muted state" do
      owner_scope = user_scope_fixture()
      muted_scope = user_scope_fixture()
      listener_scope = user_scope_fixture()

      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Voice Mute"})
      add_workspace_member!(workspace, muted_scope)
      add_workspace_member!(workspace, listener_scope)

      {:ok, voice_channel} =
        Workspaces.create_voice_channel(owner_scope, workspace.id, %{name: "lobby"})

      on_exit(fn -> cleanup_room(voice_channel.id) end)

      assert {:ok, %{voice_session_id: muted_session_id, occupancy: 1}} =
               Voice.join(voice_channel.id, muted_scope.user.id, "muted-connection", self())

      assert {:ok, %{occupancy: 2}} =
               Voice.join(voice_channel.id, listener_scope.user.id, "listener-connection", self())

      assert {:ok, _moderation} =
               Workspaces.mute_member(owner_scope, workspace.id, muted_scope.user.id, %{})

      assert {:ok, %{occupancy: 2, capacity: 5}} = Voice.room_occupancy(voice_channel.id)

      assert {:ok, %{members: members}} = Voice.voice_channel_roster(voice_channel.id)

      assert Enum.find(members, &(&1.user_id == muted_scope.user.id)) == %{
               user_id: muted_scope.user.id,
               muted: true,
               deafened: false,
               speaking: false
             }

      refute Enum.any?(
               members,
               &(Map.has_key?(&1, :workspace_muted) or Map.has_key?(&1, :reason))
             )

      assert :ok =
               Voice.update_local_voice_state(
                 muted_scope,
                 voice_channel.id,
                 muted_session_id,
                 %{muted: false, deafened: false}
               )

      assert {:ok, _moderation} =
               Workspaces.unmute_member(owner_scope, workspace.id, muted_scope.user.id)

      assert {:ok, %{members: members}} = Voice.voice_channel_roster(voice_channel.id)

      assert Enum.find(members, &(&1.user_id == muted_scope.user.id)).muted == false
    end

    test "a Workspace Timeout ends the Voice Session and blocks signaling admission until removed" do
      owner_scope = user_scope_fixture()
      timed_out_scope = user_scope_fixture()

      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Voice Timeout"})
      add_workspace_member!(workspace, timed_out_scope)

      {:ok, voice_channel} =
        Workspaces.create_voice_channel(owner_scope, workspace.id, %{name: "lobby"})

      on_exit(fn -> cleanup_room(voice_channel.id) end)

      assert {:ok, %{occupancy: 1}} =
               Voice.join(voice_channel.id, timed_out_scope.user.id, "timeout-connection", self())

      assert {:ok, _moderation} =
               Workspaces.timeout_member(
                 owner_scope,
                 workspace.id,
                 timed_out_scope.user.id,
                 "5_minutes",
                 %{}
               )

      assert {:ok, %{occupancy: 0, capacity: 5}} = Voice.room_occupancy(voice_channel.id)

      assert {:error, :not_found} =
               Workspaces.authorize_voice_channel_for_signaling(timed_out_scope, voice_channel.id)

      assert {:ok, _moderation} =
               Workspaces.remove_member_timeout(
                 owner_scope,
                 workspace.id,
                 timed_out_scope.user.id
               )

      assert {:ok, _voice_channel} =
               Workspaces.authorize_voice_channel_for_signaling(timed_out_scope, voice_channel.id)

      assert {:ok, moderation} =
               Workspaces.timeout_member(
                 owner_scope,
                 workspace.id,
                 timed_out_scope.user.id,
                 "5_minutes",
                 %{}
               )

      expired_moderation =
        moderation
        |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(:second), -1, :second))
        |> Repo.update!()

      assert {:ok, _moderation} = Workspaces.expire_member_timeout(expired_moderation.id)

      assert {:ok, _voice_channel} =
               Workspaces.authorize_voice_channel_for_signaling(timed_out_scope, voice_channel.id)
    end

    test "kicking a connected member ends only that member's Voice Session" do
      owner_scope = user_scope_fixture()
      kicked_scope = user_scope_fixture()
      retained_scope = user_scope_fixture()

      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Voice Access"})
      add_workspace_member!(workspace, kicked_scope)
      add_workspace_member!(workspace, retained_scope)

      {:ok, voice_channel} =
        Workspaces.create_voice_channel(owner_scope, workspace.id, %{name: "lobby"})

      on_exit(fn -> cleanup_room(voice_channel.id) end)

      assert {:ok, %{occupancy: 1}} =
               Voice.join(voice_channel.id, kicked_scope.user.id, "kicked-connection", self())

      assert {:ok, %{occupancy: 2}} =
               Voice.join(voice_channel.id, retained_scope.user.id, "retained-connection", self())

      assert {:ok, _membership} =
               Workspaces.kick_member(owner_scope, workspace.id, kicked_scope.user.id, %{
                 "reason" => "Access removed"
               })

      assert {:ok, %{occupancy: 1, capacity: 5}} = Voice.room_occupancy(voice_channel.id)

      assert {:ok, %{occupancy: 2, capacity: 5}} =
               Voice.join(voice_channel.id, kicked_scope.user.id, "reconnected", self())
    end

    test "banning a connected member ends only that member's Voice Session" do
      owner_scope = user_scope_fixture()
      banned_scope = user_scope_fixture()
      retained_scope = user_scope_fixture()

      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Voice Ban"})
      add_workspace_member!(workspace, banned_scope)
      add_workspace_member!(workspace, retained_scope)

      {:ok, voice_channel} =
        Workspaces.create_voice_channel(owner_scope, workspace.id, %{name: "lobby"})

      on_exit(fn -> cleanup_room(voice_channel.id) end)

      assert {:ok, %{occupancy: 1}} =
               Voice.join(voice_channel.id, banned_scope.user.id, "banned-connection", self())

      assert {:ok, %{occupancy: 2}} =
               Voice.join(voice_channel.id, retained_scope.user.id, "retained-connection", self())

      assert {:ok, _ban} =
               Workspaces.ban_member(owner_scope, workspace.id, banned_scope.user.id, %{
                 "reason" => "Access removed"
               })

      assert {:ok, %{occupancy: 1, capacity: 5}} = Voice.room_occupancy(voice_channel.id)

      assert {:ok, %{occupancy: 2, capacity: 5}} =
               Voice.join(voice_channel.id, banned_scope.user.id, "reconnected", self())
    end

    test "a member leaving a workspace ends that member's Voice Session" do
      owner_scope = user_scope_fixture()
      leaving_scope = user_scope_fixture()
      retained_scope = user_scope_fixture()

      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Voice Leave"})
      add_workspace_member!(workspace, leaving_scope)
      add_workspace_member!(workspace, retained_scope)

      {:ok, voice_channel} =
        Workspaces.create_voice_channel(owner_scope, workspace.id, %{name: "lobby"})

      on_exit(fn -> cleanup_room(voice_channel.id) end)

      assert {:ok, %{occupancy: 1}} =
               Voice.join(voice_channel.id, leaving_scope.user.id, "leaving-connection", self())

      assert {:ok, %{occupancy: 2}} =
               Voice.join(voice_channel.id, retained_scope.user.id, "retained-connection", self())

      assert {:ok, _membership} = Workspaces.leave_workspace(leaving_scope, workspace.id)

      assert {:ok, %{occupancy: 1, capacity: 5}} = Voice.room_occupancy(voice_channel.id)

      assert {:ok, %{occupancy: 2, capacity: 5}} =
               Voice.join(voice_channel.id, leaving_scope.user.id, "reconnected", self())
    end

    test "failed kick and ban validation preserve a connected member's Voice Session" do
      owner_scope = user_scope_fixture()
      member_scope = user_scope_fixture()

      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Voice Validation"})
      add_workspace_member!(workspace, member_scope)

      {:ok, voice_channel} =
        Workspaces.create_voice_channel(owner_scope, workspace.id, %{name: "lobby"})

      on_exit(fn -> cleanup_room(voice_channel.id) end)

      assert {:ok, %{occupancy: 1}} =
               Voice.join(voice_channel.id, member_scope.user.id, "member-connection", self())

      assert {:error, :reason_required} =
               Workspaces.kick_member(owner_scope, workspace.id, member_scope.user.id, %{})

      assert {:error, :reason_required} =
               Workspaces.ban_member(owner_scope, workspace.id, member_scope.user.id, %{})

      assert {:ok, %{occupancy: 1, capacity: 5}} = Voice.room_occupancy(voice_channel.id)
    end
  end

  describe "durable Voice Channel deletion" do
    test "ends every session in the deleted channel and preserves an unrelated room" do
      owner_scope = user_scope_fixture()
      first_user_scope = user_scope_fixture()
      second_user_scope = user_scope_fixture()

      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Voice Deletion"})

      {:ok, ended_voice_channel} =
        Workspaces.create_voice_channel(owner_scope, workspace.id, %{name: "ended"})

      {:ok, unrelated_voice_channel} =
        Workspaces.create_voice_channel(owner_scope, workspace.id, %{name: "unrelated"})

      on_exit(fn ->
        cleanup_room(ended_voice_channel.id)
        cleanup_room(unrelated_voice_channel.id)
      end)

      assert {:ok, %{occupancy: 1}} =
               Voice.join(
                 ended_voice_channel.id,
                 first_user_scope.user.id,
                 "ended-connection-1",
                 self()
               )

      assert {:ok, %{occupancy: 2}} =
               Voice.join(
                 ended_voice_channel.id,
                 second_user_scope.user.id,
                 "ended-connection-2",
                 self()
               )

      assert {:ok, %{occupancy: 1}} =
               Voice.join(
                 unrelated_voice_channel.id,
                 owner_scope.user.id,
                 "unrelated-connection",
                 self()
               )

      assert {:ok, deleted_voice_channel} =
               Workspaces.delete_voice_channel(owner_scope, workspace.id, ended_voice_channel.id)

      assert deleted_voice_channel.id == ended_voice_channel.id
      refute Repo.get(VoiceChannel, ended_voice_channel.id)
      assert {:ok, %{occupancy: 0, capacity: 5}} = Voice.room_occupancy(ended_voice_channel.id)

      assert {:ok, %{occupancy: 1, capacity: 5}} =
               Voice.room_occupancy(unrelated_voice_channel.id)

      assert Voice.room_running?(ended_voice_channel.id)

      assert :ok = Voice.expire_idle_room(ended_voice_channel.id)
      refute Voice.room_running?(ended_voice_channel.id)
    end

    test "deleting a workspace ends sessions in Voice Channels removed by cascade" do
      owner_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Voice Cascade"})

      {:ok, voice_channel} =
        Workspaces.create_voice_channel(owner_scope, workspace.id, %{name: "cascade"})

      on_exit(fn -> cleanup_room(voice_channel.id) end)

      assert {:ok, %{occupancy: 1}} =
               Voice.join(voice_channel.id, owner_scope.user.id, "cascade-connection", self())

      assert {:ok, deleted_workspace} = Workspaces.delete_workspace(owner_scope, workspace.id)

      assert deleted_workspace.id == workspace.id
      refute Repo.get(VoiceChannel, voice_channel.id)
      assert {:ok, %{occupancy: 0, capacity: 5}} = Voice.room_occupancy(voice_channel.id)

      assert :ok = Voice.expire_idle_room(voice_channel.id)
      refute Voice.room_running?(voice_channel.id)
    end

    test "unauthorized Voice Channel deletion preserves its active sessions" do
      owner_scope = user_scope_fixture()
      member_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Voice Delete Auth"})
      add_workspace_member!(workspace, member_scope)

      {:ok, voice_channel} =
        Workspaces.create_voice_channel(owner_scope, workspace.id, %{name: "lobby"})

      on_exit(fn -> cleanup_room(voice_channel.id) end)

      assert {:ok, %{occupancy: 1}} =
               Voice.join(voice_channel.id, member_scope.user.id, "member-connection", self())

      assert {:error, :unauthorized} =
               Workspaces.delete_voice_channel(member_scope, workspace.id, voice_channel.id)

      assert {:ok, %{occupancy: 1, capacity: 5}} = Voice.room_occupancy(voice_channel.id)
    end
  end

  defp add_workspace_member!(workspace, scope, role \\ "member") do
    %WorkspaceMembership{}
    |> WorkspaceMembership.changeset(%{
      workspace_id: workspace.id,
      user_id: scope.user.id,
      role: role
    })
    |> Repo.insert!()
  end

  defp cleanup_room(voice_channel_id) do
    _ = Voice.end_channel_sessions(voice_channel_id)
    _ = Voice.expire_idle_room(voice_channel_id)
  end
end
