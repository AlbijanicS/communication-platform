defmodule DiscordClone.WorkspacesTest do
  use DiscordClone.DataCase

  alias DiscordClone.Activities.ActivityItem
  alias DiscordClone.Chat

  alias DiscordClone.Chat.{
    ChannelReadState,
    ChannelUnreadSpan,
    Conversation,
    Message,
    Runtime
  }

  alias DiscordClone.Workspaces

  alias DiscordClone.Workspaces.{
    Channel,
    VoiceChannel,
    WorkspaceAuditEvent,
    WorkspaceBan,
    WorkspaceInvite,
    WorkspaceMembership,
    WorkspaceModeration
  }

  import DiscordClone.AccountsFixtures
  import DiscordClone.WorkspacesFixtures

  describe "voice channels" do
    test "lets a workspace owner create a normalized voice channel without creating a conversation" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Voice Server"})

      assert {:ok, voice_channel} =
               Workspaces.create_voice_channel(scope, workspace.id, %{name: " Design Room "})

      assert %VoiceChannel{workspace_id: workspace_id, name: "design-room"} = voice_channel
      assert workspace_id == workspace.id
      refute Repo.get(Conversation, voice_channel.id)
    end

    test "lists and fetches voice channels only for workspace members in creation order" do
      owner_scope = user_scope_fixture()
      member_scope = user_scope_fixture()
      non_member_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Voice Server"})
      add_workspace_member!(workspace, member_scope)
      {:ok, first} = Workspaces.create_voice_channel(owner_scope, workspace.id, %{name: "lobby"})

      {:ok, second} =
        Workspaces.create_voice_channel(owner_scope, workspace.id, %{name: "standup"})

      assert {:ok, voice_channels} = Workspaces.list_voice_channels(member_scope, workspace.id)
      assert Enum.map(voice_channels, & &1.id) == [first.id, second.id]
      assert {:ok, ^first} = Workspaces.fetch_voice_channel(member_scope, workspace.id, first.id)

      assert Workspaces.list_voice_channels(non_member_scope, workspace.id) ==
               {:error, :unauthorized}

      assert Workspaces.fetch_voice_channel(member_scope, workspace.id, second.id) ==
               {:ok, second}
    end

    test "allows admins to create and rename, but only owners to delete" do
      owner_scope = user_scope_fixture()
      admin_scope = user_scope_fixture()
      member_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Voice Server"})
      add_workspace_member!(workspace, admin_scope, "admin")
      add_workspace_member!(workspace, member_scope)

      assert {:ok, voice_channel} =
               Workspaces.create_voice_channel(admin_scope, workspace.id, %{name: "planning"})

      assert {:ok, %{name: "design-room"}} =
               Workspaces.rename_voice_channel(admin_scope, workspace.id, voice_channel.id, %{
                 name: "Design Room"
               })

      assert Workspaces.create_voice_channel(member_scope, workspace.id, %{name: "member-room"}) ==
               {:error, :unauthorized}

      assert Workspaces.delete_voice_channel(admin_scope, workspace.id, voice_channel.id) ==
               {:error, :unauthorized}

      assert {:ok, _} =
               Workspaces.delete_voice_channel(owner_scope, workspace.id, voice_channel.id)
    end

    test "enforces the channel naming boundary and has no position field" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Voice Server"})

      assert {:ok, %{name: valid_name}} =
               Workspaces.create_voice_channel(scope, workspace.id, %{
                 name: String.duplicate("a", 80)
               })

      assert String.length(valid_name) == 80

      assert {:error, :invalid_voice_channel, changeset} =
               Workspaces.create_voice_channel(scope, workspace.id, %{name: "not/valid"})

      assert errors_on(changeset).name != []

      assert {:error, :invalid_voice_channel, changeset} =
               Workspaces.create_voice_channel(scope, workspace.id, %{
                 name: String.duplicate("a", 81)
               })

      assert errors_on(changeset).name != []
      refute :position in VoiceChannel.__schema__(:fields)
    end

    test "keeps voice names independent from text channels and returns tagged validation errors" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Voice Server"})
      assert {:ok, _channel} = Workspaces.create_channel(scope, workspace.id, %{name: "lobby"})

      assert {:ok, _voice_channel} =
               Workspaces.create_voice_channel(scope, workspace.id, %{name: "lobby"})

      assert {:ok, second_voice_channel} =
               Workspaces.create_voice_channel(scope, workspace.id, %{name: "standup"})

      assert {:error, :invalid_voice_channel, changeset} =
               Workspaces.create_voice_channel(scope, workspace.id, %{name: " "})

      assert errors_on(changeset).name == ["can't be blank"]

      assert {:error, :invalid_voice_channel, changeset} =
               Workspaces.rename_voice_channel(scope, workspace.id, second_voice_channel.id, %{
                 name: "LOBBY"
               })

      assert errors_on(changeset).name == ["has already been taken"]
    end

    test "uses not found and unauthenticated errors for inaccessible voice channel references" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Voice Server"})
      {:ok, other_workspace} = Workspaces.create_workspace(scope, %{name: "Other Server"})

      {:ok, voice_channel} =
        Workspaces.create_voice_channel(scope, other_workspace.id, %{name: "lobby"})

      assert Workspaces.fetch_voice_channel(scope, workspace.id, voice_channel.id) ==
               {:error, :not_found}

      assert Workspaces.rename_voice_channel(scope, workspace.id, voice_channel.id, %{name: "new"}) ==
               {:error, :not_found}

      assert Workspaces.delete_voice_channel(scope, workspace.id, voice_channel.id) ==
               {:error, :not_found}

      assert Workspaces.list_voice_channels(nil, workspace.id) == {:error, :unauthenticated}

      assert Workspaces.create_voice_channel(nil, workspace.id, %{name: "lobby"}) ==
               {:error, :unauthenticated}
    end
  end

  describe "create_workspace/2" do
    test "creates a workspace with owner membership and a default general channel" do
      scope = user_scope_fixture()

      assert {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "My Server"})

      assert workspace.name == "My Server"
      assert workspace.owner_id == scope.user.id
      assert workspace.invite_policy == "owner_only"

      assert %Channel{name: "general", id: default_channel_id} =
               Repo.get_by(Channel, workspace_id: workspace.id)

      assert workspace.default_channel_id == default_channel_id

      assert %WorkspaceMembership{role: "owner"} =
               Repo.get_by(WorkspaceMembership,
                 workspace_id: workspace.id,
                 user_id: scope.user.id
               )
    end

    test "initializes the owner read state for the default general channel" do
      scope = user_scope_fixture()

      assert {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "My Server"})

      assert %ChannelReadState{
               unread_count: 0,
               first_unread_seq: nil,
               last_unread_seq: nil
             } =
               Repo.get_by(ChannelReadState,
                 channel_id: workspace.default_channel_id,
                 user_id: scope.user.id
               )
    end

    test "uses the authenticated user and owner-only invite policy" do
      scope = user_scope_fixture()
      other_user = user_fixture()

      assert {:ok, workspace} =
               Workspaces.create_workspace(scope, %{
                 "name" => "Spoof Proof",
                 "owner_id" => other_user.id,
                 "invite_policy" => "members_can_invite"
               })

      assert workspace.owner_id == scope.user.id
      assert workspace.invite_policy == "owner_only"
    end

    test "uses general as the default channel name instead of caller-provided channel input" do
      scope = user_scope_fixture()

      assert {:ok, workspace} =
               Workspaces.create_workspace(scope, %{
                 name: "Channels Later",
                 main_channel_name: "lobby"
               })

      assert %Channel{name: "general", id: default_channel_id} =
               Repo.get_by(Channel, workspace_id: workspace.id)

      assert workspace.default_channel_id == default_channel_id
    end

    test "allows duplicate workspace names" do
      first_scope = user_scope_fixture()
      second_scope = user_scope_fixture()

      assert {:ok, first_workspace} =
               Workspaces.create_workspace(first_scope, %{name: "Same Name"})

      assert {:ok, second_workspace} =
               Workspaces.create_workspace(second_scope, %{name: "Same Name"})

      assert first_workspace.name == second_workspace.name
      assert first_workspace.id != second_workspace.id
    end

    test "allows duplicate workspace names for the same user" do
      scope = user_scope_fixture()

      assert {:ok, first_workspace} =
               Workspaces.create_workspace(scope, %{name: "Same Name"})

      assert {:ok, second_workspace} =
               Workspaces.create_workspace(scope, %{name: "Same Name"})

      assert first_workspace.name == second_workspace.name
      assert first_workspace.owner_id == second_workspace.owner_id
      assert first_workspace.id != second_workspace.id
    end

    test "rejects unauthenticated scopes" do
      assert Workspaces.create_workspace(nil, %{name: "Nope"}) == {:error, :unauthenticated}

      assert Workspaces.create_workspace(%DiscordClone.Accounts.Scope{}, %{name: "Nope"}) ==
               {:error, :unauthenticated}
    end

    test "returns an invalid workspace changeset for invalid input" do
      scope = user_scope_fixture()

      assert {:error, :invalid_workspace, changeset} =
               Workspaces.create_workspace(scope, %{name: ""})

      assert errors_on(changeset).name == ["can't be blank"]
    end

    test "rejects invalid workspace attrs from authenticated scopes" do
      scope = user_scope_fixture()

      assert Workspaces.create_workspace(scope, "bad attrs") == {:error, :invalid_attrs}
    end
  end

  describe "workspace_fixture/1" do
    test "creates a workspace through the public context" do
      workspace = workspace_fixture(%{name: "Fixture Server"})

      assert workspace.name == "Fixture Server"
      assert workspace.default_channel_id
      assert Repo.get_by(WorkspaceMembership, workspace_id: workspace.id, role: "owner")
    end
  end

  describe "workspace membership roles" do
    test "accepts owner, admin, and member roles" do
      owner_scope = user_scope_fixture()
      admin_scope = user_scope_fixture()
      member_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Role Workspace"})

      assert add_workspace_member!(workspace, admin_scope, "admin").role == "admin"
      assert add_workspace_member!(workspace, member_scope, "member").role == "member"
      assert Repo.get_by!(WorkspaceMembership, workspace_id: workspace.id, role: "owner")
    end
  end

  describe "role capabilities" do
    test "exposes workspace, channel, and invite capabilities by workspace role" do
      owner_scope = user_scope_fixture()
      admin_scope = user_scope_fixture()
      peer_admin_scope = user_scope_fixture()
      member_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Role Workspace"})
      add_workspace_member!(workspace, admin_scope, "admin")
      add_workspace_member!(workspace, peer_admin_scope, "admin")
      add_workspace_member!(workspace, member_scope, "member")

      assert Workspaces.can_rename_workspace?(owner_scope, workspace)
      assert Workspaces.can_delete_workspace?(owner_scope, workspace)
      assert Workspaces.can_create_channel?(owner_scope, workspace)
      assert Workspaces.can_rename_channel?(owner_scope, workspace)
      assert Workspaces.can_delete_channel?(owner_scope, workspace)
      assert Workspaces.can_create_workspace_invite?(owner_scope, workspace)

      refute Workspaces.can_rename_workspace?(admin_scope, workspace)
      refute Workspaces.can_delete_workspace?(admin_scope, workspace)
      assert Workspaces.can_create_channel?(admin_scope, workspace)
      assert Workspaces.can_rename_channel?(admin_scope, workspace)
      refute Workspaces.can_delete_channel?(admin_scope, workspace)
      assert Workspaces.can_create_workspace_invite?(admin_scope, workspace)

      refute Workspaces.can_rename_workspace?(member_scope, workspace)
      refute Workspaces.can_delete_workspace?(member_scope, workspace)
      refute Workspaces.can_create_channel?(member_scope, workspace)
      refute Workspaces.can_rename_channel?(member_scope, workspace)
      refute Workspaces.can_delete_channel?(member_scope, workspace)
      refute Workspaces.can_create_workspace_invite?(member_scope, workspace)
    end

    test "derives member action availability by actor and target role" do
      owner_scope = user_scope_fixture()
      admin_scope = user_scope_fixture()
      peer_admin_scope = user_scope_fixture()
      member_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Role Workspace"})
      add_workspace_member!(workspace, admin_scope, "admin")
      add_workspace_member!(workspace, peer_admin_scope, "admin")
      add_workspace_member!(workspace, member_scope, "member")

      owner_membership =
        Repo.get_by!(WorkspaceMembership,
          workspace_id: workspace.id,
          user_id: owner_scope.user.id
        )

      admin_membership =
        Repo.get_by!(WorkspaceMembership,
          workspace_id: workspace.id,
          user_id: admin_scope.user.id
        )

      peer_admin_membership =
        Repo.get_by!(WorkspaceMembership,
          workspace_id: workspace.id,
          user_id: peer_admin_scope.user.id
        )

      member_membership =
        Repo.get_by!(WorkspaceMembership,
          workspace_id: workspace.id,
          user_id: member_scope.user.id
        )

      assert Workspaces.available_member_actions(owner_scope, workspace, admin_membership) == [
               :demote_to_member,
               :mute,
               :timeout,
               :kick,
               :ban
             ]

      assert Workspaces.available_member_actions(owner_scope, workspace, member_membership) == [
               :promote_to_admin,
               :mute,
               :timeout,
               :kick,
               :ban
             ]

      assert Workspaces.available_member_actions(admin_scope, workspace, owner_membership) == []
      assert Workspaces.available_member_actions(admin_scope, workspace, admin_membership) == []

      assert Workspaces.available_member_actions(admin_scope, workspace, peer_admin_membership) ==
               [
                 :mute,
                 :timeout
               ]

      assert Workspaces.available_member_actions(admin_scope, workspace, member_membership) == [
               :mute,
               :timeout,
               :kick,
               :ban
             ]

      assert Workspaces.available_member_actions(member_scope, workspace, owner_membership) == []
      assert Workspaces.available_member_actions(nil, workspace, member_membership) == []
    end
  end

  describe "available_member_actions_by_user_id/3" do
    setup do
      owner_scope = user_scope_fixture()
      admin_scope = user_scope_fixture()
      muted_member_scope = user_scope_fixture()
      timed_out_member_scope = user_scope_fixture()
      plain_member_scope = user_scope_fixture()

      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Batched Actions"})
      add_workspace_member!(workspace, admin_scope, "admin")
      add_workspace_member!(workspace, muted_member_scope, "member")
      add_workspace_member!(workspace, timed_out_member_scope, "member")
      add_workspace_member!(workspace, plain_member_scope, "member")

      {:ok, _mute} =
        Workspaces.mute_member(owner_scope, workspace.id, muted_member_scope.user.id, %{})

      {:ok, _timeout} =
        Workspaces.timeout_member(
          owner_scope,
          workspace.id,
          timed_out_member_scope.user.id,
          "1_hour",
          %{}
        )

      members =
        Repo.all(
          from membership in WorkspaceMembership,
            where: membership.workspace_id == ^workspace.id
        )

      %{
        owner_scope: owner_scope,
        admin_scope: admin_scope,
        muted_member_scope: muted_member_scope,
        timed_out_member_scope: timed_out_member_scope,
        plain_member_scope: plain_member_scope,
        workspace: workspace,
        members: members
      }
    end

    test "matches per-member available_member_actions/3 across a mixed-state list", ctx do
      batched =
        Workspaces.available_member_actions_by_user_id(
          ctx.owner_scope,
          ctx.workspace,
          ctx.members
        )

      for membership <- ctx.members do
        assert Map.fetch!(batched, membership.user_id) ==
                 Workspaces.available_member_actions(ctx.owner_scope, ctx.workspace, membership)
      end
    end

    test "swaps mute→unmute and timeout→remove-timeout and empties self/owner targets", ctx do
      batched =
        Workspaces.available_member_actions_by_user_id(
          ctx.owner_scope,
          ctx.workspace,
          ctx.members
        )

      assert :unmute in Map.fetch!(batched, ctx.muted_member_scope.user.id)
      refute :mute in Map.fetch!(batched, ctx.muted_member_scope.user.id)

      assert :remove_timeout in Map.fetch!(batched, ctx.timed_out_member_scope.user.id)
      refute :timeout in Map.fetch!(batched, ctx.timed_out_member_scope.user.id)

      assert Map.fetch!(batched, ctx.plain_member_scope.user.id) == [
               :promote_to_admin,
               :mute,
               :timeout,
               :kick,
               :ban
             ]

      # The owner is their own actor here, so the self target yields no actions.
      assert Map.fetch!(batched, ctx.owner_scope.user.id) == []
    end

    test "returns empty action sets for an unauthenticated scope", ctx do
      batched =
        Workspaces.available_member_actions_by_user_id(nil, ctx.workspace, ctx.members)

      for membership <- ctx.members do
        assert Map.fetch!(batched, membership.user_id) == []
      end
    end
  end

  describe "can_delete_message?/2" do
    test "owners and admins may delete admin- and member-authored messages" do
      assert Workspaces.can_delete_message?("owner", "admin")
      assert Workspaces.can_delete_message?("owner", "member")
      assert Workspaces.can_delete_message?("admin", "admin")
      assert Workspaces.can_delete_message?("admin", "member")
    end

    test "nobody may delete an owner-authored message via moderation" do
      refute Workspaces.can_delete_message?("owner", "owner")
      refute Workspaces.can_delete_message?("admin", "owner")
    end

    test "members may not delete others' messages via moderation" do
      refute Workspaces.can_delete_message?("member", "member")
      refute Workspaces.can_delete_message?("member", "admin")
    end

    test "a missing role on either side denies deletion" do
      refute Workspaces.can_delete_message?(nil, "member")
      refute Workspaces.can_delete_message?("owner", nil)
    end
  end

  describe "member_participation_status/2" do
    setup do
      owner_scope = user_scope_fixture()
      member_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Participation"})
      add_workspace_member!(workspace, member_scope, "member")

      %{owner_scope: owner_scope, member_scope: member_scope, workspace: workspace}
    end

    test "returns :ok when no active moderation blocks the member", ctx do
      assert Workspaces.member_participation_status(
               ctx.workspace.id,
               ctx.member_scope.user.id
             ) == :ok
    end

    test "returns {:error, :muted} for an actively muted member", ctx do
      assert {:ok, _moderation} =
               Workspaces.mute_member(
                 ctx.owner_scope,
                 ctx.workspace.id,
                 ctx.member_scope.user.id,
                 %{}
               )

      assert Workspaces.member_participation_status(
               ctx.workspace.id,
               ctx.member_scope.user.id
             ) == {:error, :muted}
    end

    test "returns {:error, :timeout} for an active, unexpired timeout", ctx do
      assert {:ok, _moderation} =
               Workspaces.timeout_member(
                 ctx.owner_scope,
                 ctx.workspace.id,
                 ctx.member_scope.user.id,
                 "1_hour",
                 %{}
               )

      assert Workspaces.member_participation_status(
               ctx.workspace.id,
               ctx.member_scope.user.id
             ) == {:error, :timeout}
    end

    test "a mute takes precedence over a concurrent timeout", ctx do
      assert {:ok, _mute} =
               Workspaces.mute_member(
                 ctx.owner_scope,
                 ctx.workspace.id,
                 ctx.member_scope.user.id,
                 %{}
               )

      assert {:ok, _timeout} =
               Workspaces.timeout_member(
                 ctx.owner_scope,
                 ctx.workspace.id,
                 ctx.member_scope.user.id,
                 "1_hour",
                 %{}
               )

      assert Workspaces.member_participation_status(
               ctx.workspace.id,
               ctx.member_scope.user.id
             ) == {:error, :muted}
    end
  end

  describe "change_member_role/4" do
    test "allows owners to promote members to admins" do
      owner_scope = user_scope_fixture()
      member_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Role Workspace"})
      add_workspace_member!(workspace, member_scope, "member")

      assert {:ok, membership} =
               Workspaces.change_member_role(
                 owner_scope,
                 workspace.id,
                 member_scope.user.id,
                 "admin"
               )

      assert membership.role == "admin"

      assert %WorkspaceMembership{role: "admin"} =
               Repo.get_by(WorkspaceMembership,
                 workspace_id: workspace.id,
                 user_id: member_scope.user.id
               )
    end

    test "allows owners to demote admins to members" do
      owner_scope = user_scope_fixture()
      admin_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Role Workspace"})
      add_workspace_member!(workspace, admin_scope, "admin")

      assert {:ok, membership} =
               Workspaces.change_member_role(
                 owner_scope,
                 workspace.id,
                 admin_scope.user.id,
                 "member"
               )

      assert membership.role == "member"

      assert %WorkspaceMembership{role: "member"} =
               Repo.get_by(WorkspaceMembership,
                 workspace_id: workspace.id,
                 user_id: admin_scope.user.id
               )
    end

    test "rejects admin and member role changes" do
      owner_scope = user_scope_fixture()
      admin_scope = user_scope_fixture()
      member_scope = user_scope_fixture()
      target_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Role Workspace"})
      add_workspace_member!(workspace, admin_scope, "admin")
      add_workspace_member!(workspace, member_scope, "member")
      add_workspace_member!(workspace, target_scope, "member")

      assert Workspaces.change_member_role(
               admin_scope,
               workspace.id,
               target_scope.user.id,
               "admin"
             ) ==
               {:error, :owner_required}

      assert Workspaces.change_member_role(
               member_scope,
               workspace.id,
               target_scope.user.id,
               "admin"
             ) ==
               {:error, :owner_required}

      assert Repo.get_by!(
               WorkspaceMembership,
               workspace_id: workspace.id,
               user_id: target_scope.user.id
             ).role == "member"
    end

    test "rejects owner role changes" do
      owner_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Role Workspace"})

      assert Workspaces.change_member_role(
               owner_scope,
               workspace.id,
               owner_scope.user.id,
               "member"
             ) ==
               {:error, :owner_role_locked}

      assert Repo.get_by!(
               WorkspaceMembership,
               workspace_id: workspace.id,
               user_id: owner_scope.user.id
             ).role == "owner"
    end

    test "rejects unsupported role transitions" do
      owner_scope = user_scope_fixture()
      member_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Role Workspace"})
      add_workspace_member!(workspace, member_scope, "member")

      assert Workspaces.change_member_role(
               owner_scope,
               workspace.id,
               member_scope.user.id,
               "owner"
             ) ==
               {:error, :unsupported_role_transition}

      assert Repo.get_by!(
               WorkspaceMembership,
               workspace_id: workspace.id,
               user_id: member_scope.user.id
             ).role == "member"
    end

    test "role changes append audit events visible newest first to owners" do
      owner_scope = user_scope_fixture()
      admin_scope = user_scope_fixture()
      member_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Role Workspace"})
      add_workspace_member!(workspace, admin_scope, "admin")
      add_workspace_member!(workspace, member_scope, "member")

      assert {:ok, _membership} =
               Workspaces.change_member_role(
                 owner_scope,
                 workspace.id,
                 member_scope.user.id,
                 "admin"
               )

      assert {:ok, _membership} =
               Workspaces.change_member_role(
                 owner_scope,
                 workspace.id,
                 admin_scope.user.id,
                 "member"
               )

      assert {:ok, [demotion, promotion]} =
               Workspaces.list_audit_events(owner_scope, workspace.id)

      assert %WorkspaceAuditEvent{} = promotion
      assert promotion.workspace_id == workspace.id
      assert promotion.actor_user_id == owner_scope.user.id
      assert promotion.target_user_id == member_scope.user.id
      assert promotion.event_type == "member_role_promoted"
      assert promotion.reason == nil
      assert promotion.metadata == %{"from_role" => "member", "to_role" => "admin"}

      assert demotion.target_user_id == admin_scope.user.id
      assert demotion.event_type == "member_role_demoted"
      assert demotion.metadata == %{"from_role" => "admin", "to_role" => "member"}
    end

    test "role changes broadcast workspace member and audit refresh events" do
      owner_scope = user_scope_fixture()
      member_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Role Workspace"})
      add_workspace_member!(workspace, member_scope, "member")

      assert :ok = Workspaces.subscribe_to_workspace_moderation(owner_scope, workspace.id)
      assert :ok = Workspaces.subscribe_to_workspace_events(owner_scope, workspace.id)

      assert {:ok, _membership} =
               Workspaces.change_member_role(
                 owner_scope,
                 workspace.id,
                 member_scope.user.id,
                 "admin"
               )

      assert_receive {:workspace_moderation_changed,
                      %{workspace_id: workspace_id, target_user_id: target_user_id}}

      assert workspace_id == workspace.id
      assert target_user_id == member_scope.user.id

      assert_receive {:workspace_audit_changed, %{workspace_id: workspace_id}}
      assert workspace_id == workspace.id
    end

    test "rejects audit event listing for admins and members" do
      owner_scope = user_scope_fixture()
      admin_scope = user_scope_fixture()
      member_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Role Workspace"})
      add_workspace_member!(workspace, admin_scope, "admin")
      add_workspace_member!(workspace, member_scope, "member")

      assert Workspaces.list_audit_events(admin_scope, workspace.id) == {:error, :owner_required}
      assert Workspaces.list_audit_events(member_scope, workspace.id) == {:error, :owner_required}
    end
  end

  describe "workspace-wide mute workflow" do
    test "owners can mute members with an optional reason and audit event" do
      owner_scope = user_scope_fixture()
      member_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Mute Workspace"})
      add_workspace_member!(workspace, member_scope, "member")

      assert {:ok, moderation} =
               Workspaces.mute_member(owner_scope, workspace.id, member_scope.user.id, %{
                 "reason" => "Posting launch spoilers"
               })

      assert moderation.workspace_id == workspace.id
      assert moderation.target_user_id == member_scope.user.id
      assert moderation.reason == "Posting launch spoilers"
      assert moderation.active?

      assert {:ok, %{muted?: true, mute_reason: "Posting launch spoilers"}} =
               Workspaces.member_moderation_state(
                 member_scope,
                 workspace.id,
                 member_scope.user.id
               )

      assert {:ok, [audit_event]} = Workspaces.list_audit_events(owner_scope, workspace.id)
      assert audit_event.event_type == "member_muted"
      assert audit_event.actor_user_id == owner_scope.user.id
      assert audit_event.target_user_id == member_scope.user.id
      assert audit_event.reason == "Posting launch spoilers"
      assert audit_event.metadata == %{"moderation_type" => "mute"}
    end

    test "admins can mute and unmute non-owners while members cannot inspect others" do
      owner_scope = user_scope_fixture()
      admin_scope = user_scope_fixture()
      peer_admin_scope = user_scope_fixture()
      member_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Mute Workspace"})
      add_workspace_member!(workspace, admin_scope, "admin")
      add_workspace_member!(workspace, peer_admin_scope, "admin")
      add_workspace_member!(workspace, member_scope, "member")

      assert {:error, :unauthorized} =
               Workspaces.mute_member(admin_scope, workspace.id, owner_scope.user.id, %{})

      assert {:ok, moderation} =
               Workspaces.mute_member(admin_scope, workspace.id, peer_admin_scope.user.id, %{})

      assert moderation.reason == nil
      assert Workspaces.can_create_channel?(peer_admin_scope, workspace)

      assert {:error, :unauthorized} =
               Workspaces.member_moderation_state(
                 member_scope,
                 workspace.id,
                 peer_admin_scope.user.id
               )

      assert {:ok, ended_moderation} =
               Workspaces.unmute_member(admin_scope, workspace.id, peer_admin_scope.user.id)

      refute ended_moderation.active?

      assert {:ok, %{muted?: false, mute_reason: nil}} =
               Workspaces.member_moderation_state(
                 peer_admin_scope,
                 workspace.id,
                 peer_admin_scope.user.id
               )

      assert {:ok, [unmute_event, mute_event]} =
               Workspaces.list_audit_events(owner_scope, workspace.id)

      assert unmute_event.event_type == "member_unmuted"
      assert unmute_event.actor_user_id == admin_scope.user.id
      assert unmute_event.target_user_id == peer_admin_scope.user.id
      assert mute_event.event_type == "member_muted"
    end
  end

  # Regression tests for two latent risks flagged before the moderation/role
  # refactors (issue 05). They pin current behavior at the Workspaces public-API
  # seam so the refactors cannot silently change it.
  describe "latent-bug regression tests" do
    # Every Role transition the context permits must generate an audit
    # event_type that WorkspaceAuditEvent's allow-list accepts, so an
    # out-of-list type can never roll back the whole role-change transaction.
    #
    # The {:ok, _} return is itself the allow-list proof: an out-of-list
    # event_type would fail validate_inclusion and yield
    # {:error, :invalid_audit_event, _}. On top of that we pin the exact
    # event_type each transition must record — a stronger check than mere
    # allow-list membership, since success alone doesn't say *which* type was
    # logged. member <-> admin are exactly the transitions Workspaces permits
    # (authorize_role_transition/2); every other transition is rejected before
    # an audit event is ever built.
    test "every supported role transition records its expected allowed event type" do
      expected_event_types = %{
        {"member", "admin"} => "member_role_promoted",
        {"admin", "member"} => "member_role_demoted"
      }

      for {{from_role, to_role}, expected_event_type} <- expected_event_types do
        owner_scope = user_scope_fixture()
        target_scope = user_scope_fixture()
        {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Role Workspace"})
        add_workspace_member!(workspace, target_scope, from_role)

        assert {:ok, membership} =
                 Workspaces.change_member_role(
                   owner_scope,
                   workspace.id,
                   target_scope.user.id,
                   to_role
                 )

        assert membership.role == to_role

        assert {:ok, [audit_event]} = Workspaces.list_audit_events(owner_scope, workspace.id)
        assert audit_event.event_type == expected_event_type
      end
    end

    # The uniqueness index on (workspace_id, target_user_id, type) is partial
    # (WHERE active), so once a mute has ended it no longer blocks a fresh mute.
    # Intended behavior: re-muting after an ended mute is ALLOWED and creates a
    # new active moderation alongside the ended one.
    test "muting again after a previous mute has ended is allowed" do
      owner_scope = user_scope_fixture()
      member_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Mute Workspace"})
      add_workspace_member!(workspace, member_scope, "member")

      assert {:ok, first_mute} =
               Workspaces.mute_member(owner_scope, workspace.id, member_scope.user.id, %{})

      assert {:ok, ended_mute} =
               Workspaces.unmute_member(owner_scope, workspace.id, member_scope.user.id)

      refute ended_mute.active?

      # Second mute after the first has ended: a brand-new active moderation.
      assert {:ok, second_mute} =
               Workspaces.mute_member(owner_scope, workspace.id, member_scope.user.id, %{})

      assert second_mute.active?
      assert second_mute.id != first_mute.id

      assert {:ok, %{muted?: true}} =
               Workspaces.member_moderation_state(
                 member_scope,
                 workspace.id,
                 member_scope.user.id
               )

      # Both the ended and the new active mute rows coexist in Postgres.
      mutes =
        Repo.all(
          from moderation in WorkspaceModeration,
            where:
              moderation.workspace_id == ^workspace.id and
                moderation.target_user_id == ^member_scope.user.id and
                moderation.type == "mute"
        )

      assert length(mutes) == 2
      assert Enum.count(mutes, & &1.active?) == 1
    end
  end

  describe "workspace-wide timeout workflow" do
    test "owners can timeout members with a fixed duration preset and audit event" do
      owner_scope = user_scope_fixture()
      member_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Timeout Workspace"})
      add_workspace_member!(workspace, member_scope, "member")

      assert {:ok, moderation} =
               Workspaces.timeout_member(
                 owner_scope,
                 workspace.id,
                 member_scope.user.id,
                 "5_minutes",
                 %{"reason" => "Cooling down"}
               )

      assert moderation.workspace_id == workspace.id
      assert moderation.target_user_id == member_scope.user.id
      assert moderation.reason == "Cooling down"
      assert moderation.active?
      assert DateTime.compare(moderation.expires_at, DateTime.utc_now(:second)) == :gt

      assert {:ok,
              %{
                timed_out?: true,
                timeout_reason: "Cooling down",
                timeout_ends_at: timeout_ends_at
              }} =
               Workspaces.member_moderation_state(
                 member_scope,
                 workspace.id,
                 member_scope.user.id
               )

      assert DateTime.compare(timeout_ends_at, DateTime.utc_now(:second)) == :gt

      assert {:ok, [audit_event]} = Workspaces.list_audit_events(owner_scope, workspace.id)
      assert audit_event.event_type == "member_timed_out"
      assert audit_event.actor_user_id == owner_scope.user.id
      assert audit_event.target_user_id == member_scope.user.id
      assert audit_event.reason == "Cooling down"
      assert audit_event.metadata["moderation_type"] == "timeout"
      assert audit_event.metadata["duration"] == "5_minutes"
    end

    test "admins can timeout and remove timeouts for non-owners with fixed presets only" do
      owner_scope = user_scope_fixture()
      admin_scope = user_scope_fixture()
      peer_admin_scope = user_scope_fixture()
      member_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Timeout Workspace"})
      add_workspace_member!(workspace, admin_scope, "admin")
      add_workspace_member!(workspace, peer_admin_scope, "admin")
      add_workspace_member!(workspace, member_scope, "member")

      assert Workspaces.timeout_member(
               admin_scope,
               workspace.id,
               member_scope.user.id,
               "13_minutes",
               %{}
             ) == {:error, :invalid_timeout_duration}

      assert {:error, :unauthorized} =
               Workspaces.timeout_member(admin_scope, workspace.id, owner_scope.user.id, "1_hour")

      assert {:ok, moderation} =
               Workspaces.timeout_member(
                 admin_scope,
                 workspace.id,
                 peer_admin_scope.user.id,
                 "1_hour"
               )

      assert moderation.reason == nil
      assert Workspaces.can_create_channel?(peer_admin_scope, workspace)

      peer_admin_membership =
        Repo.get_by!(WorkspaceMembership,
          workspace_id: workspace.id,
          user_id: peer_admin_scope.user.id
        )

      assert :remove_timeout in Workspaces.available_member_actions(
               admin_scope,
               workspace,
               peer_admin_membership
             )

      refute :timeout in Workspaces.available_member_actions(
               admin_scope,
               workspace,
               peer_admin_membership
             )

      assert {:ok, ended_moderation} =
               Workspaces.remove_member_timeout(
                 admin_scope,
                 workspace.id,
                 peer_admin_scope.user.id
               )

      refute ended_moderation.active?

      assert {:ok, %{timed_out?: false, timeout_reason: nil, timeout_ends_at: nil}} =
               Workspaces.member_moderation_state(
                 peer_admin_scope,
                 workspace.id,
                 peer_admin_scope.user.id
               )

      assert {:ok, [remove_event, timeout_event]} =
               Workspaces.list_audit_events(owner_scope, workspace.id)

      assert remove_event.event_type == "member_timeout_removed"
      assert remove_event.actor_user_id == admin_scope.user.id
      assert timeout_event.event_type == "member_timed_out"
    end

    test "natural timeout expiry is audited once and broadcasts moderation changes" do
      owner_scope = user_scope_fixture()
      member_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Timeout Workspace"})
      add_workspace_member!(workspace, member_scope, "member")

      assert {:ok, moderation} =
               Workspaces.timeout_member(
                 owner_scope,
                 workspace.id,
                 member_scope.user.id,
                 "5_minutes"
               )

      moderation
      |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(:second), -1, :second))
      |> Repo.update!()

      assert :ok = Workspaces.subscribe_to_workspace_moderation(owner_scope, workspace.id)

      assert {:ok, expired_moderation} = Workspaces.expire_member_timeout(moderation.id)
      refute expired_moderation.active?

      assert_receive {:workspace_moderation_changed,
                      %{workspace_id: workspace_id, target_user_id: target_user_id}}

      assert workspace_id == workspace.id
      assert target_user_id == member_scope.user.id

      assert Workspaces.expire_member_timeout(moderation.id) == {:ok, :already_inactive}

      assert {:ok, [expired_event, timeout_event]} =
               Workspaces.list_audit_events(owner_scope, workspace.id)

      assert expired_event.event_type == "member_timeout_expired"
      assert expired_event.actor_user_id == nil
      assert expired_event.target_user_id == member_scope.user.id
      assert timeout_event.event_type == "member_timed_out"
    end

    test "expired timeout timestamps stop counting as active even before the scheduler runs" do
      owner_scope = user_scope_fixture()
      member_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Timeout Workspace"})
      add_workspace_member!(workspace, member_scope, "member")

      assert {:ok, stale_timeout} =
               Workspaces.timeout_member(
                 owner_scope,
                 workspace.id,
                 member_scope.user.id,
                 "5_minutes"
               )

      stale_timeout
      |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(:second), -1, :second))
      |> Repo.update!()

      assert {:ok, %{timed_out?: false, timeout_reason: nil, timeout_ends_at: nil}} =
               Workspaces.member_moderation_state(
                 member_scope,
                 workspace.id,
                 member_scope.user.id
               )

      member_membership =
        Repo.get_by!(WorkspaceMembership,
          workspace_id: workspace.id,
          user_id: member_scope.user.id
        )

      assert :timeout in Workspaces.available_member_actions(
               owner_scope,
               workspace,
               member_membership
             )

      refute :remove_timeout in Workspaces.available_member_actions(
               owner_scope,
               workspace,
               member_membership
             )

      assert {:ok, replacement_timeout} =
               Workspaces.timeout_member(
                 owner_scope,
                 workspace.id,
                 member_scope.user.id,
                 "1_hour"
               )

      assert replacement_timeout.id != stale_timeout.id
      assert replacement_timeout.active?
      assert DateTime.compare(replacement_timeout.expires_at, DateTime.utc_now(:second)) == :gt
    end
  end

  describe "kick_member/4" do
    test "permanently removes only the kicked member's workspace activity" do
      owner_scope = user_scope_fixture(user_fixture(%{username: "kick_owner"}))
      kicked_scope = user_scope_fixture(user_fixture(%{username: "kick_target"}))
      retained_scope = user_scope_fixture(user_fixture(%{username: "kick_retained"}))
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Kick Workspace"})
      add_workspace_member!(workspace, kicked_scope, "member")
      add_workspace_member!(workspace, retained_scope, "member")
      {:ok, invite} = Workspaces.create_workspace_invite(owner_scope, workspace.id)

      {:ok, source_message} =
        Chat.send_message(owner_scope, workspace.default_channel_id, %{
          content: "hello @kick_target and @kick_retained"
        })

      assert Repo.get_by(ActivityItem,
               recipient_user_id: kicked_scope.user.id,
               source_message_id: source_message.id
             )

      assert {:ok, _membership} =
               Workspaces.kick_member(owner_scope, workspace.id, kicked_scope.user.id, %{
                 "reason" => "Access removed"
               })

      refute Repo.get_by(ActivityItem,
               recipient_user_id: kicked_scope.user.id,
               source_message_id: source_message.id
             )

      assert Repo.get_by(ActivityItem,
               recipient_user_id: retained_scope.user.id,
               source_message_id: source_message.id
             )

      assert {:ok, %{already_member?: false}} =
               Workspaces.accept_workspace_invite(kicked_scope, invite.code)

      refute Repo.get_by(ActivityItem,
               recipient_user_id: kicked_scope.user.id,
               workspace_id: workspace.id
             )
    end

    test "owners can kick members and admins with a required reason and audit event" do
      owner_scope = user_scope_fixture()
      admin_scope = user_scope_fixture()
      member_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Kick Workspace"})
      add_workspace_member!(workspace, admin_scope, "admin")
      add_workspace_member!(workspace, member_scope, "member")

      assert {:ok, kicked_membership} =
               Workspaces.kick_member(owner_scope, workspace.id, member_scope.user.id, %{
                 "reason" => "Repeated spam"
               })

      assert kicked_membership.user_id == member_scope.user.id

      refute Repo.get_by(WorkspaceMembership,
               workspace_id: workspace.id,
               user_id: member_scope.user.id
             )

      assert {:ok, kicked_admin} =
               Workspaces.kick_member(owner_scope, workspace.id, admin_scope.user.id, %{
                 "reason" => "Abusing staff powers"
               })

      assert kicked_admin.user_id == admin_scope.user.id

      assert {:ok, events} = Workspaces.list_audit_events(owner_scope, workspace.id)
      kick_events = Enum.filter(events, &(&1.event_type == "member_kicked"))

      assert [admin_event, member_event] = kick_events
      assert admin_event.target_user_id == admin_scope.user.id
      assert admin_event.actor_user_id == owner_scope.user.id
      assert admin_event.reason == "Abusing staff powers"
      assert member_event.target_user_id == member_scope.user.id
      assert member_event.reason == "Repeated spam"
    end

    test "kick requires a non-empty reason" do
      owner_scope = user_scope_fixture()
      member_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Kick Workspace"})
      add_workspace_member!(workspace, member_scope, "member")

      assert {:error, :reason_required} =
               Workspaces.kick_member(owner_scope, workspace.id, member_scope.user.id, %{
                 "reason" => "   "
               })

      assert {:error, :reason_required} =
               Workspaces.kick_member(owner_scope, workspace.id, member_scope.user.id, %{})

      assert Repo.get_by(WorkspaceMembership,
               workspace_id: workspace.id,
               user_id: member_scope.user.id
             )
    end

    test "admins can kick members but not owners or other admins" do
      owner_scope = user_scope_fixture()
      admin_scope = user_scope_fixture()
      peer_admin_scope = user_scope_fixture()
      member_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Kick Workspace"})
      add_workspace_member!(workspace, admin_scope, "admin")
      add_workspace_member!(workspace, peer_admin_scope, "admin")
      add_workspace_member!(workspace, member_scope, "member")

      assert {:error, :unauthorized} =
               Workspaces.kick_member(admin_scope, workspace.id, owner_scope.user.id, %{
                 "reason" => "Trying to remove the owner"
               })

      assert {:error, :unauthorized} =
               Workspaces.kick_member(admin_scope, workspace.id, peer_admin_scope.user.id, %{
                 "reason" => "Trying to remove a peer admin"
               })

      assert {:ok, _kicked} =
               Workspaces.kick_member(admin_scope, workspace.id, member_scope.user.id, %{
                 "reason" => "Disruptive behavior"
               })

      assert Repo.get_by(WorkspaceMembership,
               workspace_id: workspace.id,
               user_id: owner_scope.user.id
             )

      assert Repo.get_by(WorkspaceMembership,
               workspace_id: workspace.id,
               user_id: peer_admin_scope.user.id
             )
    end

    test "regular members cannot kick anyone" do
      owner_scope = user_scope_fixture()
      member_scope = user_scope_fixture()
      other_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Kick Workspace"})
      add_workspace_member!(workspace, member_scope, "member")
      add_workspace_member!(workspace, other_scope, "member")

      assert {:error, :unauthorized} =
               Workspaces.kick_member(member_scope, workspace.id, other_scope.user.id, %{
                 "reason" => "I do not have permission"
               })
    end

    test "kicking clears active moderation state, read/unread state, and preserves messages" do
      owner_scope = user_scope_fixture()
      member_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Kick Workspace"})
      channel = Repo.get_by!(Channel, workspace_id: workspace.id)
      add_workspace_member!(workspace, member_scope, "member")

      {:ok, message} =
        Chat.send_message(member_scope, channel.id, %{"content" => "hello there"})

      {:ok, _mute} =
        Workspaces.mute_member(owner_scope, workspace.id, member_scope.user.id, %{})

      {:ok, _timeout} =
        Workspaces.timeout_member(owner_scope, workspace.id, member_scope.user.id, "1_hour")

      assert {:ok, _kicked} =
               Workspaces.kick_member(owner_scope, workspace.id, member_scope.user.id, %{
                 "reason" => "Cleanup verification"
               })

      refute Repo.exists?(
               from moderation in WorkspaceModeration,
                 where:
                   moderation.workspace_id == ^workspace.id and
                     moderation.target_user_id == ^member_scope.user.id
             )

      refute Repo.exists?(
               from read_state in ChannelReadState,
                 where:
                   read_state.channel_id == ^channel.id and
                     read_state.user_id == ^member_scope.user.id
             )

      preserved = Repo.get(Message, message.id)
      assert preserved
      assert preserved.user_id == member_scope.user.id
      assert is_nil(preserved.deleted_at)
    end

    test "kicked users can rejoin with a valid invite as regular members" do
      owner_scope = user_scope_fixture()
      admin_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Kick Workspace"})
      add_workspace_member!(workspace, admin_scope, "admin")
      {:ok, invite} = Workspaces.create_workspace_invite(owner_scope, workspace.id)

      assert {:ok, _kicked} =
               Workspaces.kick_member(owner_scope, workspace.id, admin_scope.user.id, %{
                 "reason" => "Temporary removal"
               })

      refute Repo.get_by(WorkspaceMembership,
               workspace_id: workspace.id,
               user_id: admin_scope.user.id
             )

      assert {:ok, %{already_member?: false}} =
               Workspaces.accept_workspace_invite(admin_scope, invite.code)

      assert %WorkspaceMembership{role: "member"} =
               Repo.get_by(WorkspaceMembership,
                 workspace_id: workspace.id,
                 user_id: admin_scope.user.id
               )
    end

    test "kicking broadcasts access revocation to moderation subscribers" do
      owner_scope = user_scope_fixture()
      member_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Kick Workspace"})
      add_workspace_member!(workspace, member_scope, "member")

      :ok = Workspaces.subscribe_to_workspace_moderation(owner_scope, workspace.id)

      assert {:ok, _kicked} =
               Workspaces.kick_member(owner_scope, workspace.id, member_scope.user.id, %{
                 "reason" => "Broadcast verification"
               })

      assert_receive {:workspace_access_revoked,
                      %{workspace_id: workspace_id, target_user_id: target_user_id}}

      assert workspace_id == workspace.id
      assert target_user_id == member_scope.user.id
    end
  end

  describe "ban_member/4" do
    test "permanently removes only the banned member's workspace activity" do
      owner_scope = user_scope_fixture(user_fixture(%{username: "ban_owner"}))
      banned_scope = user_scope_fixture(user_fixture(%{username: "ban_target"}))
      retained_scope = user_scope_fixture(user_fixture(%{username: "ban_retained"}))
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Ban Workspace"})
      add_workspace_member!(workspace, banned_scope, "member")
      add_workspace_member!(workspace, retained_scope, "member")

      {:ok, source_message} =
        Chat.send_message(owner_scope, workspace.default_channel_id, %{
          content: "hello @ban_target and @ban_retained"
        })

      assert {:ok, _ban} =
               Workspaces.ban_member(owner_scope, workspace.id, banned_scope.user.id, %{
                 "reason" => "Access removed"
               })

      refute Repo.get_by(ActivityItem,
               recipient_user_id: banned_scope.user.id,
               source_message_id: source_message.id
             )

      assert Repo.get_by(ActivityItem,
               recipient_user_id: retained_scope.user.id,
               source_message_id: source_message.id
             )
    end

    test "owners can ban members and admins with a durable ban record and audit event" do
      owner_scope = user_scope_fixture()
      admin_scope = user_scope_fixture()
      member_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Ban Workspace"})
      add_workspace_member!(workspace, admin_scope, "admin")
      add_workspace_member!(workspace, member_scope, "member")

      assert {:ok, member_ban} =
               Workspaces.ban_member(owner_scope, workspace.id, member_scope.user.id, %{
                 "reason" => "Repeated spam"
               })

      assert member_ban.target_user_id == member_scope.user.id
      assert member_ban.reason == "Repeated spam"

      refute Repo.get_by(WorkspaceMembership,
               workspace_id: workspace.id,
               user_id: member_scope.user.id
             )

      assert Repo.get_by(WorkspaceBan,
               workspace_id: workspace.id,
               target_user_id: member_scope.user.id
             )

      assert {:ok, _admin_ban} =
               Workspaces.ban_member(owner_scope, workspace.id, admin_scope.user.id, %{
                 "reason" => "Abusing staff powers"
               })

      assert {:ok, events} = Workspaces.list_audit_events(owner_scope, workspace.id)
      ban_events = Enum.filter(events, &(&1.event_type == "member_banned"))

      assert [admin_event, member_event] = ban_events
      assert admin_event.target_user_id == admin_scope.user.id
      assert admin_event.actor_user_id == owner_scope.user.id
      assert admin_event.reason == "Abusing staff powers"
      assert member_event.target_user_id == member_scope.user.id
      assert member_event.reason == "Repeated spam"
    end

    test "the ban record survives membership deletion" do
      owner_scope = user_scope_fixture()
      member_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Ban Workspace"})
      add_workspace_member!(workspace, member_scope, "member")

      assert {:ok, _ban} =
               Workspaces.ban_member(owner_scope, workspace.id, member_scope.user.id, %{
                 "reason" => "Durable storage check"
               })

      refute Repo.get_by(WorkspaceMembership,
               workspace_id: workspace.id,
               user_id: member_scope.user.id
             )

      assert Workspaces.workspace_banned?(workspace.id, member_scope.user.id)
    end

    test "ban requires a non-empty reason" do
      owner_scope = user_scope_fixture()
      member_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Ban Workspace"})
      add_workspace_member!(workspace, member_scope, "member")

      assert {:error, :reason_required} =
               Workspaces.ban_member(owner_scope, workspace.id, member_scope.user.id, %{
                 "reason" => "   "
               })

      assert {:error, :reason_required} =
               Workspaces.ban_member(owner_scope, workspace.id, member_scope.user.id, %{})

      assert Repo.get_by(WorkspaceMembership,
               workspace_id: workspace.id,
               user_id: member_scope.user.id
             )

      refute Repo.get_by(WorkspaceBan,
               workspace_id: workspace.id,
               target_user_id: member_scope.user.id
             )
    end

    test "admins can ban members but not owners or other admins" do
      owner_scope = user_scope_fixture()
      admin_scope = user_scope_fixture()
      peer_admin_scope = user_scope_fixture()
      member_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Ban Workspace"})
      add_workspace_member!(workspace, admin_scope, "admin")
      add_workspace_member!(workspace, peer_admin_scope, "admin")
      add_workspace_member!(workspace, member_scope, "member")

      assert {:error, :unauthorized} =
               Workspaces.ban_member(admin_scope, workspace.id, owner_scope.user.id, %{
                 "reason" => "Trying to remove the owner"
               })

      assert {:error, :unauthorized} =
               Workspaces.ban_member(admin_scope, workspace.id, peer_admin_scope.user.id, %{
                 "reason" => "Trying to remove a peer admin"
               })

      assert {:ok, _banned} =
               Workspaces.ban_member(admin_scope, workspace.id, member_scope.user.id, %{
                 "reason" => "Disruptive behavior"
               })

      assert Repo.get_by(WorkspaceMembership,
               workspace_id: workspace.id,
               user_id: owner_scope.user.id
             )

      assert Repo.get_by(WorkspaceMembership,
               workspace_id: workspace.id,
               user_id: peer_admin_scope.user.id
             )
    end

    test "regular members cannot ban anyone" do
      owner_scope = user_scope_fixture()
      member_scope = user_scope_fixture()
      other_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Ban Workspace"})
      add_workspace_member!(workspace, member_scope, "member")
      add_workspace_member!(workspace, other_scope, "member")

      assert {:error, :unauthorized} =
               Workspaces.ban_member(member_scope, workspace.id, other_scope.user.id, %{
                 "reason" => "I do not have permission"
               })
    end

    test "banning clears active moderation state, read/unread state, and preserves messages" do
      owner_scope = user_scope_fixture()
      member_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Ban Workspace"})
      channel = Repo.get_by!(Channel, workspace_id: workspace.id)
      add_workspace_member!(workspace, member_scope, "member")

      {:ok, message} =
        Chat.send_message(member_scope, channel.id, %{"content" => "hello there"})

      {:ok, _mute} =
        Workspaces.mute_member(owner_scope, workspace.id, member_scope.user.id, %{})

      {:ok, _timeout} =
        Workspaces.timeout_member(owner_scope, workspace.id, member_scope.user.id, "1_hour")

      assert {:ok, _banned} =
               Workspaces.ban_member(owner_scope, workspace.id, member_scope.user.id, %{
                 "reason" => "Cleanup verification"
               })

      refute Repo.exists?(
               from moderation in WorkspaceModeration,
                 where:
                   moderation.workspace_id == ^workspace.id and
                     moderation.target_user_id == ^member_scope.user.id
             )

      refute Repo.exists?(
               from read_state in ChannelReadState,
                 where:
                   read_state.channel_id == ^channel.id and
                     read_state.user_id == ^member_scope.user.id
             )

      preserved = Repo.get(Message, message.id)
      assert preserved
      assert preserved.user_id == member_scope.user.id
      assert is_nil(preserved.deleted_at)
    end

    test "banning broadcasts access revocation to moderation subscribers" do
      owner_scope = user_scope_fixture()
      member_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Ban Workspace"})
      add_workspace_member!(workspace, member_scope, "member")

      :ok = Workspaces.subscribe_to_workspace_moderation(owner_scope, workspace.id)

      assert {:ok, _banned} =
               Workspaces.ban_member(owner_scope, workspace.id, member_scope.user.id, %{
                 "reason" => "Broadcast verification"
               })

      assert_receive {:workspace_access_revoked,
                      %{workspace_id: workspace_id, target_user_id: target_user_id}}

      assert workspace_id == workspace.id
      assert target_user_id == member_scope.user.id
    end

    test "cleans up the banned member's messages within the chosen window and records metadata" do
      owner_scope = user_scope_fixture()
      member_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Ban Workspace"})
      channel = Repo.get_by!(Channel, workspace_id: workspace.id)
      add_workspace_member!(workspace, member_scope, "member")

      {:ok, recent} = Chat.send_message(member_scope, channel.id, %{"content" => "recent spam"})
      {:ok, stale} = Chat.send_message(member_scope, channel.id, %{"content" => "old message"})
      backdate_message!(stale, ~U[2020-01-01 00:00:00Z])

      assert {:ok, _ban} =
               Workspaces.ban_member(owner_scope, workspace.id, member_scope.user.id, %{
                 "reason" => "Cleanup window",
                 "cleanup_window" => "1_hour"
               })

      assert Repo.get(Message, recent.id).deleted_at
      assert Repo.get(Message, recent.id).deleted_by_user_id == owner_scope.user.id
      assert is_nil(Repo.get(Message, stale.id).deleted_at)

      assert {:ok, events} = Workspaces.list_audit_events(owner_scope, workspace.id)
      ban_event = Enum.find(events, &(&1.event_type == "member_banned"))
      assert ban_event.metadata["cleanup_window"] == "1_hour"
      assert ban_event.metadata["cleanup_message_count"] == 1
    end

    test "the default ban preserves messages and records no cleanup metadata" do
      owner_scope = user_scope_fixture()
      member_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Ban Workspace"})
      channel = Repo.get_by!(Channel, workspace_id: workspace.id)
      add_workspace_member!(workspace, member_scope, "member")

      {:ok, message} = Chat.send_message(member_scope, channel.id, %{"content" => "keep me"})

      assert {:ok, _ban} =
               Workspaces.ban_member(owner_scope, workspace.id, member_scope.user.id, %{
                 "reason" => "No cleanup"
               })

      assert is_nil(Repo.get(Message, message.id).deleted_at)

      assert {:ok, events} = Workspaces.list_audit_events(owner_scope, workspace.id)
      ban_event = Enum.find(events, &(&1.event_type == "member_banned"))
      assert ban_event.metadata == %{}
    end

    test "owners can purge all of the banned member's workspace messages regardless of age" do
      owner_scope = user_scope_fixture()
      member_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Ban Workspace"})
      channel = Repo.get_by!(Channel, workspace_id: workspace.id)
      add_workspace_member!(workspace, member_scope, "member")

      {:ok, recent} = Chat.send_message(member_scope, channel.id, %{"content" => "recent"})
      {:ok, ancient} = Chat.send_message(member_scope, channel.id, %{"content" => "ancient"})
      backdate_message!(ancient, ~U[2000-01-01 00:00:00Z])

      assert {:ok, _ban} =
               Workspaces.ban_member(owner_scope, workspace.id, member_scope.user.id, %{
                 "reason" => "Purge everything",
                 "cleanup_window" => "all"
               })

      assert Repo.get(Message, recent.id).deleted_at
      assert Repo.get(Message, ancient.id).deleted_at

      assert {:ok, events} = Workspaces.list_audit_events(owner_scope, workspace.id)
      ban_event = Enum.find(events, &(&1.event_type == "member_banned"))
      assert ban_event.metadata["cleanup_window"] == "all"
      assert ban_event.metadata["cleanup_message_count"] == 2
    end

    test "admins cannot purge all workspace messages but may use bounded windows" do
      owner_scope = user_scope_fixture()
      admin_scope = user_scope_fixture()
      member_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Ban Workspace"})
      channel = Repo.get_by!(Channel, workspace_id: workspace.id)
      add_workspace_member!(workspace, admin_scope, "admin")
      add_workspace_member!(workspace, member_scope, "member")

      {:ok, message} = Chat.send_message(member_scope, channel.id, %{"content" => "recent"})

      assert {:error, :cleanup_owner_required} =
               Workspaces.ban_member(admin_scope, workspace.id, member_scope.user.id, %{
                 "reason" => "Forging owner-only cleanup",
                 "cleanup_window" => "all"
               })

      assert Repo.get_by(WorkspaceMembership,
               workspace_id: workspace.id,
               user_id: member_scope.user.id
             )

      refute Repo.get_by(WorkspaceBan,
               workspace_id: workspace.id,
               target_user_id: member_scope.user.id
             )

      assert is_nil(Repo.get(Message, message.id).deleted_at)

      assert {:ok, _ban} =
               Workspaces.ban_member(admin_scope, workspace.id, member_scope.user.id, %{
                 "reason" => "Bounded cleanup",
                 "cleanup_window" => "24_hours"
               })

      assert Repo.get(Message, message.id).deleted_at
    end

    test "rejects an unknown cleanup window without banning" do
      owner_scope = user_scope_fixture()
      member_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Ban Workspace"})
      channel = Repo.get_by!(Channel, workspace_id: workspace.id)
      add_workspace_member!(workspace, member_scope, "member")

      {:ok, message} = Chat.send_message(member_scope, channel.id, %{"content" => "recent"})

      assert {:error, :invalid_cleanup_window} =
               Workspaces.ban_member(owner_scope, workspace.id, member_scope.user.id, %{
                 "reason" => "Bad window",
                 "cleanup_window" => "forever"
               })

      assert Repo.get_by(WorkspaceMembership,
               workspace_id: workspace.id,
               user_id: member_scope.user.id
             )

      assert is_nil(Repo.get(Message, message.id).deleted_at)
    end

    test "banned users are blocked from previewing and accepting invites" do
      owner_scope = user_scope_fixture()
      member_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Ban Workspace"})
      add_workspace_member!(workspace, member_scope, "member")
      {:ok, invite} = Workspaces.create_workspace_invite(owner_scope, workspace.id)

      assert {:ok, _banned} =
               Workspaces.ban_member(owner_scope, workspace.id, member_scope.user.id, %{
                 "reason" => "No rejoining"
               })

      assert {:error, :banned} =
               Workspaces.preview_workspace_invite(member_scope, invite.code)

      assert {:error, :banned} =
               Workspaces.accept_workspace_invite(member_scope, invite.code)

      refute Repo.get_by(WorkspaceMembership,
               workspace_id: workspace.id,
               user_id: member_scope.user.id
             )
    end
  end

  describe "moderation does not post channel system messages" do
    test "mute, kick, and ban create no new channel messages" do
      owner_scope = user_scope_fixture()
      muted_scope = user_scope_fixture()
      kicked_scope = user_scope_fixture()
      banned_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, muted_scope, "member")
      add_workspace_member!(workspace, kicked_scope, "member")
      add_workspace_member!(workspace, banned_scope, "member")

      message_count_before = Repo.aggregate(Message, :count)

      assert {:ok, _moderation} =
               Workspaces.mute_member(owner_scope, workspace.id, muted_scope.user.id, %{})

      assert {:ok, _membership} =
               Workspaces.kick_member(owner_scope, workspace.id, kicked_scope.user.id, %{
                 "reason" => "Spamming"
               })

      assert {:ok, _ban} =
               Workspaces.ban_member(owner_scope, workspace.id, banned_scope.user.id, %{
                 "reason" => "Repeated abuse"
               })

      assert Repo.aggregate(Message, :count) == message_count_before
    end
  end

  describe "unban_member/3" do
    test "owners can unban a member, appending an audit event without restoring access" do
      owner_scope = user_scope_fixture()
      member_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Ban Workspace"})
      add_workspace_member!(workspace, member_scope, "admin")

      assert {:ok, _ban} =
               Workspaces.ban_member(owner_scope, workspace.id, member_scope.user.id, %{
                 "reason" => "Temporary removal"
               })

      assert {:ok, _unban} =
               Workspaces.unban_member(owner_scope, workspace.id, member_scope.user.id)

      refute Workspaces.workspace_banned?(workspace.id, member_scope.user.id)

      refute Repo.get_by(WorkspaceBan,
               workspace_id: workspace.id,
               target_user_id: member_scope.user.id
             )

      # Unban never re-creates membership nor restores the prior admin role.
      refute Repo.get_by(WorkspaceMembership,
               workspace_id: workspace.id,
               user_id: member_scope.user.id
             )

      assert {:ok, events} = Workspaces.list_audit_events(owner_scope, workspace.id)
      unban_event = Enum.find(events, &(&1.event_type == "member_unbanned"))

      assert unban_event.target_user_id == member_scope.user.id
      assert unban_event.actor_user_id == owner_scope.user.id
    end

    test "admins and members cannot unban, leaving the ban in place" do
      owner_scope = user_scope_fixture()
      admin_scope = user_scope_fixture()
      member_scope = user_scope_fixture()
      banned_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Ban Workspace"})
      add_workspace_member!(workspace, admin_scope, "admin")
      add_workspace_member!(workspace, member_scope, "member")
      add_workspace_member!(workspace, banned_scope, "member")

      assert {:ok, _ban} =
               Workspaces.ban_member(owner_scope, workspace.id, banned_scope.user.id, %{
                 "reason" => "Spam"
               })

      assert {:error, :owner_required} =
               Workspaces.unban_member(admin_scope, workspace.id, banned_scope.user.id)

      assert {:error, :owner_required} =
               Workspaces.unban_member(member_scope, workspace.id, banned_scope.user.id)

      assert Workspaces.workspace_banned?(workspace.id, banned_scope.user.id)
    end

    test "unbanning a user who is not banned returns an error" do
      owner_scope = user_scope_fixture()
      member_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Ban Workspace"})
      add_workspace_member!(workspace, member_scope, "member")

      assert {:error, :not_banned} =
               Workspaces.unban_member(owner_scope, workspace.id, member_scope.user.id)
    end
  end

  describe "list_banned_members/2" do
    test "owners can list banned users with their ban details" do
      owner_scope = user_scope_fixture()
      first_scope = user_scope_fixture()
      second_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Ban Workspace"})
      add_workspace_member!(workspace, first_scope, "member")
      add_workspace_member!(workspace, second_scope, "member")

      assert {:ok, _} =
               Workspaces.ban_member(owner_scope, workspace.id, first_scope.user.id, %{
                 "reason" => "First offense"
               })

      assert {:ok, _} =
               Workspaces.ban_member(owner_scope, workspace.id, second_scope.user.id, %{
                 "reason" => "Second offense"
               })

      assert {:ok, banned} = Workspaces.list_banned_members(owner_scope, workspace.id)

      banned_ids = Enum.map(banned, & &1.target_user_id)
      assert banned_ids == [second_scope.user.id, first_scope.user.id]

      ban = Enum.find(banned, &(&1.target_user_id == first_scope.user.id))
      assert ban.reason == "First offense"
      assert ban.target_user.id == first_scope.user.id
    end

    test "admins and members cannot list banned users" do
      owner_scope = user_scope_fixture()
      admin_scope = user_scope_fixture()
      member_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Ban Workspace"})
      add_workspace_member!(workspace, admin_scope, "admin")
      add_workspace_member!(workspace, member_scope, "member")

      assert {:error, :owner_required} =
               Workspaces.list_banned_members(admin_scope, workspace.id)

      assert {:error, :owner_required} =
               Workspaces.list_banned_members(member_scope, workspace.id)
    end

    test "an unbanned admin can accept an invite and rejoins as a regular member" do
      owner_scope = user_scope_fixture()
      target_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Ban Workspace"})
      add_workspace_member!(workspace, target_scope, "admin")
      {:ok, invite} = Workspaces.create_workspace_invite(owner_scope, workspace.id)

      assert {:ok, _ban} =
               Workspaces.ban_member(owner_scope, workspace.id, target_scope.user.id, %{
                 "reason" => "Cooling off"
               })

      assert {:error, :banned} = Workspaces.accept_workspace_invite(target_scope, invite.code)

      assert {:ok, _unban} =
               Workspaces.unban_member(owner_scope, workspace.id, target_scope.user.id)

      assert {:ok, _landing} = Workspaces.accept_workspace_invite(target_scope, invite.code)

      # Rejoin restores a plain membership only — never the prior admin role.
      assert %WorkspaceMembership{role: "member"} =
               Repo.get_by(WorkspaceMembership,
                 workspace_id: workspace.id,
                 user_id: target_scope.user.id
               )
    end
  end

  describe "list_workspaces/1" do
    test "returns only workspaces where the user is a workspace member" do
      scope = user_scope_fixture()
      other_scope = user_scope_fixture()

      assert {:ok, member_workspace} =
               Workspaces.create_workspace(scope, %{name: "Member Workspace"})

      assert {:ok, _other_workspace} =
               Workspaces.create_workspace(other_scope, %{name: "Other Workspace"})

      assert Workspaces.list_workspaces(scope) == {:ok, [member_workspace]}
    end

    test "orders workspaces by newest membership first" do
      scope = user_scope_fixture()

      assert {:ok, first_workspace} =
               Workspaces.create_workspace(scope, %{name: "First Workspace"})

      assert {:ok, second_workspace} =
               Workspaces.create_workspace(scope, %{name: "Second Workspace"})

      assert Workspaces.list_workspaces(scope) == {:ok, [second_workspace, first_workspace]}
    end

    test "requires an authenticated scope" do
      assert Workspaces.list_workspaces(nil) == {:error, :unauthenticated}

      assert Workspaces.list_workspaces(%DiscordClone.Accounts.Scope{}) ==
               {:error, :unauthenticated}
    end
  end

  describe "fetch_workspace/2" do
    test "returns a workspace where the user is a workspace member" do
      scope = user_scope_fixture()

      assert {:ok, workspace} =
               Workspaces.create_workspace(scope, %{name: "Member Workspace"})

      assert Workspaces.fetch_workspace(scope, workspace.id) == {:ok, workspace}
    end

    test "returns not found for a missing workspace" do
      scope = user_scope_fixture()

      assert Workspaces.fetch_workspace(scope, "not-a-uuid") == {:error, :not_found}
      refute Workspaces.workspace_banned?("not-a-uuid", scope.user.id)
      assert Workspaces.list_active_future_timeouts("not-a-uuid") == []
    end

    test "rejects logged-in users who are not workspace members" do
      owner_scope = user_scope_fixture()
      non_member_scope = user_scope_fixture()

      assert {:ok, workspace} =
               Workspaces.create_workspace(owner_scope, %{name: "Private Workspace"})

      assert Workspaces.fetch_workspace(non_member_scope, workspace.id) == {:error, :unauthorized}
    end

    test "requires an authenticated scope" do
      assert Workspaces.fetch_workspace(nil, 1) == {:error, :unauthenticated}

      assert Workspaces.fetch_workspace(%DiscordClone.Accounts.Scope{}, 1) ==
               {:error, :unauthenticated}
    end
  end

  describe "list_channels/2" do
    test "returns workspace channels oldest first for a workspace member" do
      scope = user_scope_fixture()

      assert {:ok, workspace} =
               Workspaces.create_workspace(scope, %{name: "Member Workspace"})

      assert {:ok, first_channel} =
               Workspaces.create_channel(scope, workspace.id, %{name: "first"})

      assert {:ok, second_channel} =
               Workspaces.create_channel(scope, workspace.id, %{name: "second"})

      default_channel = Repo.get!(Channel, workspace.default_channel_id)

      assert Workspaces.list_channels(scope, workspace.id) ==
               {:ok, [default_channel, first_channel, second_channel]}
    end

    test "returns not found for a missing workspace" do
      scope = user_scope_fixture()

      assert Workspaces.list_channels(scope, -1) == {:error, :not_found}
    end

    test "rejects logged-in users who are not workspace members" do
      owner_scope = user_scope_fixture()
      non_member_scope = user_scope_fixture()

      assert {:ok, workspace} =
               Workspaces.create_workspace(owner_scope, %{name: "Private Workspace"})

      assert Workspaces.list_channels(non_member_scope, workspace.id) == {:error, :unauthorized}
    end

    test "requires an authenticated scope" do
      assert Workspaces.list_channels(nil, 1) == {:error, :unauthenticated}

      assert Workspaces.list_channels(%DiscordClone.Accounts.Scope{}, 1) ==
               {:error, :unauthenticated}
    end
  end

  describe "list_members/2" do
    test "returns workspace members with user display data for a workspace member" do
      owner_scope = user_fixture(%{username: "owner_user"}) |> user_scope_fixture()
      member_scope = user_fixture(%{username: "member_user"}) |> user_scope_fixture()

      assert {:ok, workspace} =
               Workspaces.create_workspace(owner_scope, %{name: "Presence Workspace"})

      add_workspace_member!(workspace, member_scope)

      assert {:ok, members} = Workspaces.list_members(owner_scope, workspace.id)

      assert Enum.map(members, & &1.role) == ["owner", "member"]
      assert Enum.map(members, & &1.user.username) == ["owner_user", "member_user"]
      assert Enum.all?(members, &(&1.workspace_id == workspace.id))
    end

    test "requires an authenticated scope" do
      assert Workspaces.list_members(nil, 1) == {:error, :unauthenticated}

      assert Workspaces.list_members(%DiscordClone.Accounts.Scope{}, 1) ==
               {:error, :unauthenticated}
    end

    test "rejects logged-in users who are not workspace members" do
      owner_scope = user_scope_fixture()
      non_member_scope = user_scope_fixture()

      assert {:ok, workspace} =
               Workspaces.create_workspace(owner_scope, %{name: "Private Workspace"})

      assert Workspaces.list_members(non_member_scope, workspace.id) == {:error, :unauthorized}
    end

    test "returns not found for a missing workspace" do
      scope = user_scope_fixture()

      assert Workspaces.list_members(scope, -1) == {:error, :not_found}
    end

    test "allows non-owner workspace members to list members" do
      owner_scope = user_scope_fixture()
      member_scope = user_scope_fixture()

      assert {:ok, workspace} =
               Workspaces.create_workspace(owner_scope, %{name: "Member Visible Workspace"})

      add_workspace_member!(workspace, member_scope)

      assert {:ok, members} = Workspaces.list_members(member_scope, workspace.id)
      assert Enum.map(members, & &1.user_id) == [owner_scope.user.id, member_scope.user.id]
    end
  end

  describe "fetch_channel/3" do
    test "returns a channel in the selected workspace for a workspace member" do
      scope = user_scope_fixture()

      assert {:ok, workspace} =
               Workspaces.create_workspace(scope, %{name: "Member Workspace"})

      assert {:ok, channel} =
               Workspaces.create_channel(scope, workspace.id, %{name: "planning"})

      assert Workspaces.fetch_channel(scope, workspace.id, channel.id) == {:ok, channel}
    end

    test "returns not found when the channel is missing or belongs to another workspace" do
      scope = user_scope_fixture()

      assert {:ok, selected_workspace} =
               Workspaces.create_workspace(scope, %{name: "Selected Workspace"})

      assert {:ok, other_workspace} =
               Workspaces.create_workspace(scope, %{name: "Other Workspace"})

      assert {:ok, other_channel} =
               Workspaces.create_channel(scope, other_workspace.id, %{name: "planning"})

      assert Workspaces.fetch_channel(scope, selected_workspace.id, -1) == {:error, :not_found}

      assert Workspaces.fetch_channel(scope, selected_workspace.id, other_channel.id) ==
               {:error, :not_found}
    end

    test "rejects logged-in users who are not workspace members" do
      owner_scope = user_scope_fixture()
      non_member_scope = user_scope_fixture()

      assert {:ok, workspace} =
               Workspaces.create_workspace(owner_scope, %{name: "Private Workspace"})

      assert {:ok, channel} =
               Workspaces.create_channel(owner_scope, workspace.id, %{name: "planning"})

      assert Workspaces.fetch_channel(non_member_scope, workspace.id, channel.id) ==
               {:error, :unauthorized}
    end

    test "requires an authenticated scope" do
      assert Workspaces.fetch_channel(nil, 1, 1) == {:error, :unauthenticated}

      assert Workspaces.fetch_channel(%DiscordClone.Accounts.Scope{}, 1, 1) ==
               {:error, :unauthenticated}
    end
  end

  describe "resolve_landing_channel/2" do
    test "returns the workspace default channel for a workspace member" do
      scope = user_scope_fixture()

      assert {:ok, workspace} =
               Workspaces.create_workspace(scope, %{name: "Workspace"})

      default_channel = Repo.get!(Channel, workspace.default_channel_id)

      assert Workspaces.resolve_landing_channel(scope, workspace.id) == {:ok, default_channel}
    end

    test "returns an explicit error when the default channel is missing" do
      scope = user_scope_fixture()

      assert {:ok, workspace} =
               Workspaces.create_workspace(scope, %{name: "Workspace"})

      assert {:ok, _channel} =
               Workspaces.create_channel(scope, workspace.id, %{name: "oldest"})

      assert {:ok, _newest_channel} =
               Workspaces.create_channel(scope, workspace.id, %{name: "newest"})

      workspace
      |> Ecto.Changeset.change(default_channel_id: nil)
      |> Repo.update!()

      assert Workspaces.resolve_landing_channel(scope, workspace.id) ==
               {:error, :landing_channel_not_found}
    end

    test "returns an explicit error when no landing channel can be resolved" do
      scope = user_scope_fixture()

      assert {:ok, workspace} =
               Workspaces.create_workspace(scope, %{name: "Workspace"})

      Repo.delete_all(from channel in Channel, where: channel.workspace_id == ^workspace.id)

      assert Workspaces.resolve_landing_channel(scope, workspace.id) ==
               {:error, :landing_channel_not_found}
    end

    test "returns not found for a missing workspace" do
      scope = user_scope_fixture()

      assert Workspaces.resolve_landing_channel(scope, -1) == {:error, :not_found}
    end

    test "rejects logged-in users who are not workspace members" do
      owner_scope = user_scope_fixture()
      non_member_scope = user_scope_fixture()

      assert {:ok, workspace} =
               Workspaces.create_workspace(owner_scope, %{name: "Private Workspace"})

      assert Workspaces.resolve_landing_channel(non_member_scope, workspace.id) ==
               {:error, :unauthorized}
    end

    test "requires an authenticated scope" do
      assert Workspaces.resolve_landing_channel(nil, 1) == {:error, :unauthenticated}

      assert Workspaces.resolve_landing_channel(%DiscordClone.Accounts.Scope{}, 1) ==
               {:error, :unauthenticated}
    end
  end

  describe "create_channel/3" do
    test "allows the workspace owner to create a channel" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "My Server"})
      assert :ok = Workspaces.subscribe_to_workspace_events(scope, workspace.id)

      assert {:ok, channel} =
               Workspaces.create_channel(scope, workspace.id, %{name: "General Chat"})

      assert channel.workspace_id == workspace.id
      assert channel.name == "general-chat"

      assert_receive {:workspace_channel_created,
                      %{workspace_id: workspace_id, channel_id: channel_id}}

      assert workspace_id == workspace.id
      assert channel_id == channel.id
    end

    test "allows admins but rejects members creating channels" do
      owner_scope = user_scope_fixture()
      admin_scope = user_scope_fixture()
      member_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "My Server"})
      add_workspace_member!(workspace, admin_scope, "admin")
      add_workspace_member!(workspace, member_scope, "member")

      assert {:ok, channel} =
               Workspaces.create_channel(admin_scope, workspace.id, %{name: "Admin Planning"})

      assert channel.name == "admin-planning"

      assert Workspaces.create_channel(member_scope, workspace.id, %{name: "Member Planning"}) ==
               {:error, :unauthorized}
    end

    test "initializes empty read states for all current workspace members" do
      owner_scope = user_scope_fixture()
      member_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "My Server"})
      add_workspace_member!(workspace, member_scope)

      assert {:ok, channel} =
               Workspaces.create_channel(owner_scope, workspace.id, %{name: "planning"})

      assert %ChannelReadState{unread_count: 0} =
               Repo.get_by(ChannelReadState,
                 channel_id: channel.id,
                 user_id: owner_scope.user.id
               )

      assert %ChannelReadState{unread_count: 0} =
               Repo.get_by(ChannelReadState,
                 channel_id: channel.id,
                 user_id: member_scope.user.id
               )
    end

    test "starts empty channels with no message sequence progress" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "My Server"})

      assert Repo.get!(Conversation, workspace.default_channel_id).last_message_seq == 0

      assert {:ok, channel} =
               Workspaces.create_channel(scope, workspace.id, %{name: "planning"})

      assert Repo.get!(Conversation, channel.id).last_message_seq == 0
    end

    test "accepts string-keyed channel attributes" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "My Server"})

      assert {:ok, channel} =
               Workspaces.create_channel(scope, workspace.id, %{"name" => "General Chat"})

      assert channel.name == "general-chat"
    end

    test "returns not found for a missing workspace" do
      scope = user_scope_fixture()

      assert Workspaces.create_channel(scope, -1, %{name: "general"}) == {:error, :not_found}
    end

    test "rejects logged-in users who are not workspace members" do
      owner_scope = user_scope_fixture()
      non_member_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Private Server"})

      assert Workspaces.create_channel(non_member_scope, workspace.id, %{name: "general"}) ==
               {:error, :unauthorized}
    end

    test "returns an invalid channel changeset for invalid input" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "My Server"})

      assert {:error, :invalid_channel, changeset} =
               Workspaces.create_channel(scope, workspace.id, %{name: ""})

      assert errors_on(changeset).name == ["can't be blank"]
    end

    test "rejects unauthenticated scopes" do
      assert Workspaces.create_channel(nil, 1, %{name: "general"}) == {:error, :unauthenticated}

      assert Workspaces.create_channel(%DiscordClone.Accounts.Scope{}, 1, %{name: "general"}) ==
               {:error, :unauthenticated}
    end

    test "rejects invalid channel attrs from authenticated scopes" do
      scope = user_scope_fixture()

      assert Workspaces.create_channel(scope, 1, "bad attrs") == {:error, :invalid_attrs}
    end

    test "uses the explicit workspace identifier instead of spoofed attrs" do
      scope = user_scope_fixture()
      {:ok, selected_workspace} = Workspaces.create_workspace(scope, %{name: "Selected"})
      {:ok, spoofed_workspace} = Workspaces.create_workspace(scope, %{name: "Spoofed"})

      assert {:ok, channel} =
               Workspaces.create_channel(scope, selected_workspace.id, %{
                 name: "planning",
                 workspace_id: spoofed_workspace.id
               })

      assert channel.workspace_id == selected_workspace.id
    end

    test "rejects duplicate normalized names inside the same workspace" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "My Server"})

      assert {:ok, _channel} =
               Workspaces.create_channel(scope, workspace.id, %{name: "Main Room"})

      assert {:error, :invalid_channel, changeset} =
               Workspaces.create_channel(scope, workspace.id, %{name: "main-room"})

      assert errors_on(changeset).name == ["has already been taken"]
    end

    test "allows duplicate normalized names in different workspaces" do
      scope = user_scope_fixture()
      {:ok, first_workspace} = Workspaces.create_workspace(scope, %{name: "First"})
      {:ok, second_workspace} = Workspaces.create_workspace(scope, %{name: "Second"})

      assert {:ok, first_channel} =
               Workspaces.create_channel(scope, first_workspace.id, %{name: "General Chat"})

      assert {:ok, second_channel} =
               Workspaces.create_channel(scope, second_workspace.id, %{name: "general-chat"})

      assert first_channel.name == second_channel.name
      assert first_channel.workspace_id != second_channel.workspace_id
    end

    test "does not update the workspace default channel after creating another channel" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "My Server"})

      assert {:ok, _channel} = Workspaces.create_channel(scope, workspace.id, %{name: "planning"})

      assert Repo.reload!(workspace).default_channel_id == workspace.default_channel_id
    end
  end

  describe "change_channel/2" do
    test "returns a channel changeset for form usage" do
      workspace_id = Ecto.UUID.generate()

      changeset =
        Workspaces.change_channel(workspace_id, %{
          "name" => "Main Room",
          "workspace_id" => Ecto.UUID.generate()
        })

      assert %Ecto.Changeset{} = changeset
      assert Ecto.Changeset.get_field(changeset, :workspace_id) == workspace_id
      assert Ecto.Changeset.get_change(changeset, :name) == "main-room"
    end
  end

  describe "create_workspace_invite/3" do
    test "allows the workspace owner to create a fresh 30-minute invite" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      before_create = DateTime.utc_now(:second)

      assert {:ok, invite} = Workspaces.create_workspace_invite(scope, workspace.id)

      assert %WorkspaceInvite{} = invite
      assert invite.workspace_id == workspace.id
      assert invite.created_by_user_id == scope.user.id
      assert invite.uses_count == 0
      assert invite.revoked_at == nil
      assert invite.max_uses == nil
      assert invite.code =~ ~r/^[A-Za-z0-9_-]{32}$/

      expires_at_lower_bound = DateTime.add(before_create, 30, :minute)
      expires_at_upper_bound = DateTime.add(DateTime.utc_now(:second), 30, :minute)

      assert DateTime.compare(invite.expires_at, expires_at_lower_bound) in [:eq, :gt]
      assert DateTime.compare(invite.expires_at, expires_at_upper_bound) in [:eq, :lt]
    end

    test "rejects non-owner members in owner-only workspaces" do
      owner_scope = user_scope_fixture()
      member_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, member_scope)

      assert Workspaces.create_workspace_invite(member_scope, workspace.id) ==
               {:error, :invite_permission_required}

      assert Repo.aggregate(WorkspaceInvite, :count) == 0
    end

    test "allows admins but rejects members creating invites" do
      owner_scope = user_scope_fixture()
      admin_scope = user_scope_fixture()
      member_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, admin_scope, "admin")
      add_workspace_member!(workspace, member_scope, "member")

      assert {:ok, invite} = Workspaces.create_workspace_invite(admin_scope, workspace.id)

      assert invite.workspace_id == workspace.id
      assert invite.created_by_user_id == admin_scope.user.id

      assert Workspaces.create_workspace_invite(member_scope, workspace.id) ==
               {:error, :invite_permission_required}
    end

    test "ignores server-owned attributes while accepting controlled expiration and max uses" do
      scope = user_scope_fixture()
      other_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "Foundry"})
      {:ok, spoofed_workspace} = Workspaces.create_workspace(scope, %{name: "Spoofed"})
      expires_at = DateTime.add(DateTime.utc_now(:second), 2, :hour)

      assert {:ok, invite} =
               Workspaces.create_workspace_invite(scope, workspace.id, %{
                 "workspace_id" => spoofed_workspace.id,
                 "created_by_user_id" => other_scope.user.id,
                 "code" => "spoofed-code",
                 "expires_at" => expires_at,
                 "max_uses" => 5,
                 "uses_count" => 99,
                 "revoked_at" => DateTime.utc_now(:second)
               })

      assert invite.workspace_id == workspace.id
      assert invite.created_by_user_id == scope.user.id
      assert invite.code != "spoofed-code"
      assert invite.expires_at == expires_at
      assert invite.max_uses == 5
      assert invite.uses_count == 0
      assert invite.revoked_at == nil
    end
  end

  describe "change_workspace_invite/1" do
    test "returns an invite changeset for form usage with controlled fields only" do
      expires_at = DateTime.add(DateTime.utc_now(:second), 1, :hour)

      changeset =
        Workspaces.change_workspace_invite(%{
          "workspace_id" => 456,
          "code" => "spoofed-code",
          "expires_at" => expires_at,
          "max_uses" => 3
        })

      assert %Ecto.Changeset{} = changeset
      assert Ecto.Changeset.get_field(changeset, :workspace_id) == nil
      assert Ecto.Changeset.get_change(changeset, :code) == nil
      assert Ecto.Changeset.get_change(changeset, :expires_at) == expires_at
      assert Ecto.Changeset.get_change(changeset, :max_uses) == 3
    end
  end

  describe "preview_workspace_invite/2" do
    test "returns privacy-safe invite details without joining or incrementing usage" do
      owner_scope = user_scope_fixture()
      invited_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      {:ok, invite} = Workspaces.create_workspace_invite(owner_scope, workspace.id)

      assert {:ok, preview} = Workspaces.preview_workspace_invite(invited_scope, invite.code)

      assert preview.invite_code == invite.code
      assert preview.workspace_name == "Foundry"
      assert preview.inviter_username == owner_scope.user.username
      assert preview.accepting_username == invited_scope.user.username
      refute Map.has_key?(preview, :channels)
      refute Map.has_key?(preview, :members)
      refute Map.has_key?(preview, :owner_email)
      refute Map.has_key?(preview, :inviter_email)

      assert Repo.get!(WorkspaceInvite, invite.id).uses_count == 0

      refute Repo.get_by(WorkspaceMembership,
               workspace_id: workspace.id,
               user_id: invited_scope.user.id
             )
    end

    test "returns not found for a missing invite code" do
      scope = user_scope_fixture()

      assert Workspaces.preview_workspace_invite(scope, "missing-code") == {:error, :not_found}
    end

    test "returns revoked for a revoked invite" do
      owner_scope = user_scope_fixture()
      invited_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      {:ok, invite} = Workspaces.create_workspace_invite(owner_scope, workspace.id)

      invite
      |> Ecto.Changeset.change(revoked_at: DateTime.utc_now(:second))
      |> Repo.update!()

      assert Workspaces.preview_workspace_invite(invited_scope, invite.code) == {:error, :revoked}
    end

    test "returns expired for an expired invite" do
      owner_scope = user_scope_fixture()
      invited_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})

      {:ok, invite} =
        Workspaces.create_workspace_invite(owner_scope, workspace.id, %{
          expires_at: DateTime.add(DateTime.utc_now(:second), -1, :second)
        })

      assert Workspaces.preview_workspace_invite(invited_scope, invite.code) == {:error, :expired}
    end

    test "returns full for a fully-used invite" do
      owner_scope = user_scope_fixture()
      invited_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})

      {:ok, invite} =
        Workspaces.create_workspace_invite(owner_scope, workspace.id, %{max_uses: 1})

      invite
      |> Ecto.Changeset.change(uses_count: 1)
      |> Repo.update!()

      assert Workspaces.preview_workspace_invite(invited_scope, invite.code) == {:error, :full}
    end

    test "requires an authenticated scope" do
      assert Workspaces.preview_workspace_invite(nil, "missing-code") ==
               {:error, :unauthenticated}

      assert Workspaces.preview_workspace_invite(%DiscordClone.Accounts.Scope{}, "missing-code") ==
               {:error, :unauthenticated}
    end
  end

  describe "accept_workspace_invite/2" do
    test "creates a member membership, consumes one use, and returns the landing channel" do
      owner_scope = user_scope_fixture()
      invited_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      {:ok, invite} = Workspaces.create_workspace_invite(owner_scope, workspace.id)

      assert {:ok, landing} = Workspaces.accept_workspace_invite(invited_scope, invite.code)

      assert landing.workspace_id == workspace.id
      assert landing.channel_id == workspace.default_channel_id

      assert %WorkspaceMembership{role: "member"} =
               Repo.get_by(WorkspaceMembership,
                 workspace_id: workspace.id,
                 user_id: invited_scope.user.id
               )

      assert Repo.get!(WorkspaceInvite, invite.id).uses_count == 1
    end

    test "initializes read rows for new invite members" do
      owner_scope = user_scope_fixture()
      invited_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})

      {:ok, release_channel} =
        Workspaces.create_channel(owner_scope, workspace.id, %{name: "release"})

      {:ok, invite} = Workspaces.create_workspace_invite(owner_scope, workspace.id)

      _release_message =
        insert_message!(
          release_channel.id,
          owner_scope.user.id,
          "Release notes",
          DateTime.add(DateTime.utc_now(:second), -60, :second)
        )

      assert {:ok, _landing} = Workspaces.accept_workspace_invite(invited_scope, invite.code)

      assert %ChannelReadState{
               unread_count: 0,
               first_unread_seq: nil,
               last_unread_seq: nil
             } =
               Repo.get_by(ChannelReadState,
                 channel_id: release_channel.id,
                 user_id: invited_scope.user.id
               )

      refute Repo.get_by(ChannelUnreadSpan,
               channel_id: release_channel.id,
               user_id: invited_scope.user.id
             )
    end

    test "existing workspace members enter the landing channel without duplicate membership or usage" do
      owner_scope = user_scope_fixture()
      member_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      add_workspace_member!(workspace, member_scope)
      {:ok, invite} = Workspaces.create_workspace_invite(owner_scope, workspace.id)

      assert {:ok, landing} = Workspaces.accept_workspace_invite(member_scope, invite.code)

      assert landing.workspace_id == workspace.id
      assert landing.channel_id == workspace.default_channel_id
      assert landing.already_member? == true

      assert Repo.aggregate(
               from(membership in WorkspaceMembership,
                 where:
                   membership.workspace_id == ^workspace.id and
                     membership.user_id == ^member_scope.user.id
               ),
               :count
             ) == 1

      assert Repo.get!(WorkspaceInvite, invite.id).uses_count == 0
    end

    test "existing workspace member invite acceptance leaves read rows unchanged" do
      owner_scope = user_scope_fixture()
      member_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})

      {:ok, release_channel} =
        Workspaces.create_channel(owner_scope, workspace.id, %{name: "release"})

      add_workspace_member!(workspace, member_scope)

      _first_message =
        insert_message!(
          release_channel.id,
          owner_scope.user.id,
          "First",
          DateTime.add(DateTime.utc_now(:second), -60, :second)
        )

      _second_message =
        insert_message!(
          release_channel.id,
          owner_scope.user.id,
          "Second",
          DateTime.add(DateTime.utc_now(:second), -30, :second)
        )

      Repo.insert!(
        ChannelReadState.changeset(%ChannelReadState{}, %{
          channel_id: release_channel.id,
          user_id: member_scope.user.id,
          unread_count: 1,
          first_unread_seq: 2,
          last_unread_seq: 2,
          last_viewed_anchor_seq: 1
        })
      )

      Repo.insert!(
        ChannelUnreadSpan.changeset(%ChannelUnreadSpan{}, %{
          channel_id: release_channel.id,
          user_id: member_scope.user.id,
          from_seq: 2,
          to_seq: 2
        })
      )

      {:ok, invite} = Workspaces.create_workspace_invite(owner_scope, workspace.id)

      assert {:ok, landing} = Workspaces.accept_workspace_invite(member_scope, invite.code)
      assert landing.already_member? == true

      assert %ChannelReadState{
               unread_count: 1,
               first_unread_seq: 2,
               last_unread_seq: 2,
               last_viewed_anchor_seq: 1
             } =
               Repo.get_by(ChannelReadState,
                 channel_id: release_channel.id,
                 user_id: member_scope.user.id
               )

      assert %ChannelUnreadSpan{from_seq: 2, to_seq: 2} =
               Repo.get_by(ChannelUnreadSpan,
                 channel_id: release_channel.id,
                 user_id: member_scope.user.id
               )
    end

    test "workspace owners accept their own invites as navigation-only" do
      owner_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      {:ok, invite} = Workspaces.create_workspace_invite(owner_scope, workspace.id)

      assert {:ok, landing} = Workspaces.accept_workspace_invite(owner_scope, invite.code)

      assert landing.workspace_id == workspace.id
      assert landing.channel_id == workspace.default_channel_id
      assert landing.already_member? == true

      assert Repo.aggregate(
               from(membership in WorkspaceMembership,
                 where:
                   membership.workspace_id == ^workspace.id and
                     membership.user_id == ^owner_scope.user.id
               ),
               :count
             ) == 1

      assert Repo.get!(WorkspaceInvite, invite.id).uses_count == 0
    end

    test "rejects revoked invites without creating membership or consuming usage" do
      owner_scope = user_scope_fixture()
      invited_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      {:ok, invite} = Workspaces.create_workspace_invite(owner_scope, workspace.id)

      invite
      |> Ecto.Changeset.change(revoked_at: DateTime.utc_now(:second))
      |> Repo.update!()

      assert Workspaces.accept_workspace_invite(invited_scope, invite.code) == {:error, :revoked}

      refute Repo.get_by(WorkspaceMembership,
               workspace_id: workspace.id,
               user_id: invited_scope.user.id
             )

      assert Repo.get!(WorkspaceInvite, invite.id).uses_count == 0
    end

    test "rejects expired invites without creating membership or consuming usage" do
      owner_scope = user_scope_fixture()
      invited_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})

      {:ok, invite} =
        Workspaces.create_workspace_invite(owner_scope, workspace.id, %{
          expires_at: DateTime.add(DateTime.utc_now(:second), -1, :second)
        })

      assert Workspaces.accept_workspace_invite(invited_scope, invite.code) == {:error, :expired}

      refute Repo.get_by(WorkspaceMembership,
               workspace_id: workspace.id,
               user_id: invited_scope.user.id
             )

      assert Repo.get!(WorkspaceInvite, invite.id).uses_count == 0
    end

    test "rejects fully-used invites without creating membership or consuming usage" do
      owner_scope = user_scope_fixture()
      invited_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})

      {:ok, invite} =
        Workspaces.create_workspace_invite(owner_scope, workspace.id, %{max_uses: 1})

      invite
      |> Ecto.Changeset.change(uses_count: 1)
      |> Repo.update!()

      assert Workspaces.accept_workspace_invite(invited_scope, invite.code) == {:error, :full}

      refute Repo.get_by(WorkspaceMembership,
               workspace_id: workspace.id,
               user_id: invited_scope.user.id
             )

      assert Repo.get!(WorkspaceInvite, invite.id).uses_count == 1
    end

    test "treats nil max uses as unlimited until expiration or revocation" do
      owner_scope = user_scope_fixture()
      invited_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Foundry"})
      {:ok, invite} = Workspaces.create_workspace_invite(owner_scope, workspace.id)

      invite
      |> Ecto.Changeset.change(uses_count: 3)
      |> Repo.update!()

      assert {:ok, landing} = Workspaces.accept_workspace_invite(invited_scope, invite.code)

      assert landing.workspace_id == workspace.id
      assert landing.channel_id == workspace.default_channel_id

      assert %WorkspaceMembership{role: "member"} =
               Repo.get_by(WorkspaceMembership,
                 workspace_id: workspace.id,
                 user_id: invited_scope.user.id
               )

      assert Repo.get!(WorkspaceInvite, invite.id).uses_count == 4
    end

    test "returns not found for a missing invite without creating membership" do
      invited_scope = user_scope_fixture()

      assert Workspaces.accept_workspace_invite(invited_scope, "missing-code") ==
               {:error, :not_found}

      refute Repo.get_by(WorkspaceMembership, user_id: invited_scope.user.id)
    end
  end

  describe "rename_workspace/3" do
    test "allows the workspace owner to rename a workspace" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "My Server"})

      assert {:ok, renamed_workspace} =
               Workspaces.rename_workspace(scope, workspace.id, %{name: "Design Guild"})

      assert renamed_workspace.id == workspace.id
      assert renamed_workspace.name == "Design Guild"
    end

    test "rejects admins and members renaming a workspace" do
      owner_scope = user_scope_fixture()
      admin_scope = user_scope_fixture()
      member_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "My Server"})
      add_workspace_member!(workspace, admin_scope, "admin")
      add_workspace_member!(workspace, member_scope, "member")

      assert Workspaces.rename_workspace(admin_scope, workspace.id, %{name: "Admin Name"}) ==
               {:error, :owner_required}

      assert Workspaces.rename_workspace(member_scope, workspace.id, %{name: "Member Name"}) ==
               {:error, :owner_required}

      assert Repo.reload!(workspace).name == "My Server"
    end

    test "returns an invalid workspace changeset for invalid input" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "My Server"})

      assert {:error, :invalid_workspace, changeset} =
               Workspaces.rename_workspace(scope, workspace.id, %{name: ""})

      assert errors_on(changeset).name == ["can't be blank"]
    end

    test "rejects logged-in users who are not workspace members" do
      owner_scope = user_scope_fixture()
      non_member_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Private Server"})

      assert Workspaces.rename_workspace(non_member_scope, workspace.id, %{name: "New Name"}) ==
               {:error, :unauthorized}
    end

    test "distinguishes missing workspaces, unauthenticated scopes, and invalid attrs" do
      scope = user_scope_fixture()

      assert Workspaces.rename_workspace(scope, -1, %{name: "New Name"}) == {:error, :not_found}

      assert Workspaces.rename_workspace(nil, 1, %{name: "New Name"}) ==
               {:error, :unauthenticated}

      assert Workspaces.rename_workspace(%DiscordClone.Accounts.Scope{}, 1, %{name: "New Name"}) ==
               {:error, :unauthenticated}

      assert Workspaces.rename_workspace(scope, 1, "bad attrs") == {:error, :invalid_attrs}
    end
  end

  describe "rename_channel/4" do
    test "allows the workspace owner to rename a channel" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "My Server"})
      {:ok, channel} = Workspaces.create_channel(scope, workspace.id, %{name: "planning"})

      assert {:ok, renamed_channel} =
               Workspaces.rename_channel(scope, workspace.id, channel.id, %{name: "Design Room"})

      assert renamed_channel.id == channel.id
      assert renamed_channel.workspace_id == workspace.id
      assert renamed_channel.name == "design-room"
    end

    test "allows admins but rejects members renaming channels" do
      owner_scope = user_scope_fixture()
      admin_scope = user_scope_fixture()
      member_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "My Server"})
      add_workspace_member!(workspace, admin_scope, "admin")
      add_workspace_member!(workspace, member_scope, "member")
      {:ok, channel} = Workspaces.create_channel(owner_scope, workspace.id, %{name: "planning"})

      assert {:ok, renamed_channel} =
               Workspaces.rename_channel(admin_scope, workspace.id, channel.id, %{
                 name: "Admin Planning"
               })

      assert renamed_channel.name == "admin-planning"

      assert Workspaces.rename_channel(member_scope, workspace.id, channel.id, %{
               name: "Member Planning"
             }) == {:error, :unauthorized}
    end

    test "allows renaming the landing channel without changing the landing channel id" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "My Server"})
      landing_channel = Repo.get!(Channel, workspace.default_channel_id)

      assert {:ok, renamed_channel} =
               Workspaces.rename_channel(scope, workspace.id, landing_channel.id, %{
                 name: "Welcome Desk"
               })

      assert renamed_channel.id == workspace.default_channel_id
      assert renamed_channel.name == "welcome-desk"
      assert Repo.reload!(workspace).default_channel_id == landing_channel.id
    end

    test "returns not found when the workspace or channel is missing" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "My Server"})

      assert Workspaces.rename_channel(scope, -1, workspace.default_channel_id, %{name: "new"}) ==
               {:error, :not_found}

      assert Workspaces.rename_channel(scope, workspace.id, -1, %{name: "new"}) ==
               {:error, :not_found}
    end

    test "returns not found when the channel belongs to another workspace" do
      scope = user_scope_fixture()
      {:ok, selected_workspace} = Workspaces.create_workspace(scope, %{name: "Selected"})
      {:ok, other_workspace} = Workspaces.create_workspace(scope, %{name: "Other"})
      other_channel = Repo.get!(Channel, other_workspace.default_channel_id)

      assert Workspaces.rename_channel(scope, selected_workspace.id, other_channel.id, %{
               name: "new"
             }) == {:error, :not_found}
    end

    test "rejects logged-in users who are not workspace members" do
      owner_scope = user_scope_fixture()
      non_member_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Private Server"})

      assert Workspaces.rename_channel(
               non_member_scope,
               workspace.id,
               workspace.default_channel_id,
               %{name: "new"}
             ) == {:error, :unauthorized}
    end

    test "requires an authenticated scope" do
      assert Workspaces.rename_channel(nil, 1, 1, %{name: "new"}) == {:error, :unauthenticated}

      assert Workspaces.rename_channel(%DiscordClone.Accounts.Scope{}, 1, 1, %{name: "new"}) ==
               {:error, :unauthenticated}
    end

    test "returns an invalid channel changeset for invalid input" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "My Server"})

      assert {:error, :invalid_channel, changeset} =
               Workspaces.rename_channel(scope, workspace.id, workspace.default_channel_id, %{
                 name: ""
               })

      assert errors_on(changeset).name == ["can't be blank"]
    end

    test "rejects duplicate normalized names inside the same workspace" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "My Server"})
      {:ok, channel} = Workspaces.create_channel(scope, workspace.id, %{name: "Planning"})

      assert {:error, :invalid_channel, changeset} =
               Workspaces.rename_channel(scope, workspace.id, channel.id, %{name: "general"})

      assert errors_on(changeset).name == ["has already been taken"]
    end
  end

  describe "delete_channel/3" do
    test "deletes a non-landing channel" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "My Server"})
      {:ok, channel} = Workspaces.create_channel(scope, workspace.id, %{name: "planning"})

      assert {:ok, deleted_channel} = Workspaces.delete_channel(scope, workspace.id, channel.id)

      assert deleted_channel.id == channel.id
      refute Repo.get(Channel, channel.id)
    end

    test "rejects admins and members deleting channels" do
      owner_scope = user_scope_fixture()
      admin_scope = user_scope_fixture()
      member_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "My Server"})
      add_workspace_member!(workspace, admin_scope, "admin")
      add_workspace_member!(workspace, member_scope, "member")
      {:ok, channel} = Workspaces.create_channel(owner_scope, workspace.id, %{name: "planning"})

      assert Workspaces.delete_channel(admin_scope, workspace.id, channel.id) ==
               {:error, :owner_required}

      assert Workspaces.delete_channel(member_scope, workspace.id, channel.id) ==
               {:error, :owner_required}

      assert Repo.get(Channel, channel.id)
    end

    test "deletes messages for the deleted channel only" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "My Server"})
      {:ok, channel} = Workspaces.create_channel(scope, workspace.id, %{name: "planning"})

      deleted_channel_message =
        insert_message!(
          channel.id,
          scope.user.id,
          "delete this history",
          ~U[2026-06-19 10:00:00Z]
        )

      kept_channel_message =
        insert_message!(
          workspace.default_channel_id,
          scope.user.id,
          "keep this history",
          ~U[2026-06-19 10:01:00Z]
        )

      assert {:ok, deleted_channel} = Workspaces.delete_channel(scope, workspace.id, channel.id)

      assert deleted_channel.id == channel.id
      refute Repo.get(Channel, channel.id)
      refute Repo.get(Message, deleted_channel_message.id)
      assert Repo.get(Message, kept_channel_message.id)
    end

    test "rejects deleting the landing channel" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "My Server"})

      assert Workspaces.delete_channel(scope, workspace.id, workspace.default_channel_id) ==
               {:error, :landing_channel_required}

      assert Repo.get(Channel, workspace.default_channel_id)
    end

    test "returns not found when the workspace or channel is missing" do
      scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(scope, %{name: "My Server"})

      assert Workspaces.delete_channel(scope, -1, workspace.default_channel_id) ==
               {:error, :not_found}

      assert Workspaces.delete_channel(scope, workspace.id, -1) == {:error, :not_found}
    end

    test "returns not found when the channel belongs to another workspace" do
      scope = user_scope_fixture()
      {:ok, selected_workspace} = Workspaces.create_workspace(scope, %{name: "Selected"})
      {:ok, other_workspace} = Workspaces.create_workspace(scope, %{name: "Other"})

      {:ok, other_channel} =
        Workspaces.create_channel(scope, other_workspace.id, %{name: "other"})

      assert Workspaces.delete_channel(scope, selected_workspace.id, other_channel.id) ==
               {:error, :not_found}
    end

    test "rejects logged-in users who are not workspace members" do
      owner_scope = user_scope_fixture()
      non_member_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Private Server"})
      {:ok, channel} = Workspaces.create_channel(owner_scope, workspace.id, %{name: "planning"})

      assert Workspaces.delete_channel(non_member_scope, workspace.id, channel.id) ==
               {:error, :unauthorized}

      assert Repo.get(Channel, channel.id)
    end

    test "requires an authenticated scope" do
      assert Workspaces.delete_channel(nil, 1, 1) == {:error, :unauthenticated}

      assert Workspaces.delete_channel(%DiscordClone.Accounts.Scope{}, 1, 1) ==
               {:error, :unauthenticated}
    end
  end

  describe "workspace activity cleanup transactions" do
    test "rolls leave, kick, and ban back when activity cleanup fails" do
      owner_scope = user_scope_fixture(user_fixture(%{username: "access_rollback_owner"}))
      leaving_scope = user_scope_fixture(user_fixture(%{username: "access_rollback_leave"}))
      kicked_scope = user_scope_fixture(user_fixture(%{username: "access_rollback_kick"}))
      banned_scope = user_scope_fixture(user_fixture(%{username: "access_rollback_ban"}))
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Rollback Space"})
      add_workspace_member!(workspace, leaving_scope, "member")
      add_workspace_member!(workspace, kicked_scope, "member")
      add_workspace_member!(workspace, banned_scope, "member")

      {:ok, source_message} =
        Chat.send_message(owner_scope, workspace.default_channel_id, %{
          content: "hello @access_rollback_leave @access_rollback_kick @access_rollback_ban"
        })

      install_reject_activity_cleanup_trigger!()

      assert_raise Postgrex.Error, fn ->
        Workspaces.leave_workspace(leaving_scope, workspace.id)
      end

      assert_raise Postgrex.Error, fn ->
        Workspaces.kick_member(owner_scope, workspace.id, kicked_scope.user.id, %{
          "reason" => "Rollback check"
        })
      end

      assert_raise Postgrex.Error, fn ->
        Workspaces.ban_member(owner_scope, workspace.id, banned_scope.user.id, %{
          "reason" => "Rollback check"
        })
      end

      for scope <- [leaving_scope, kicked_scope, banned_scope] do
        assert Repo.get_by(WorkspaceMembership,
                 workspace_id: workspace.id,
                 user_id: scope.user.id
               )

        assert Repo.get_by(ActivityItem,
                 recipient_user_id: scope.user.id,
                 source_message_id: source_message.id
               )
      end

      refute Repo.get_by(WorkspaceBan,
               workspace_id: workspace.id,
               target_user_id: banned_scope.user.id
             )
    end
  end

  describe "leave_workspace/2" do
    test "permanently removes only the leaving member's workspace activity" do
      owner_scope = user_scope_fixture(user_fixture(%{username: "leave_owner"}))
      leaving_scope = user_scope_fixture(user_fixture(%{username: "leave_target"}))
      retained_scope = user_scope_fixture(user_fixture(%{username: "leave_retained"}))
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Team Space"})
      add_workspace_member!(workspace, leaving_scope, "member")
      add_workspace_member!(workspace, retained_scope, "member")
      {:ok, invite} = Workspaces.create_workspace_invite(owner_scope, workspace.id)

      {:ok, source_message} =
        Chat.send_message(owner_scope, workspace.default_channel_id, %{
          content: "hello @leave_target and @leave_retained"
        })

      assert {:ok, %WorkspaceMembership{}} =
               Workspaces.leave_workspace(leaving_scope, workspace.id)

      refute Repo.get_by(ActivityItem,
               recipient_user_id: leaving_scope.user.id,
               source_message_id: source_message.id
             )

      assert Repo.get_by(ActivityItem,
               recipient_user_id: retained_scope.user.id,
               source_message_id: source_message.id
             )

      assert {:ok, %{already_member?: false}} =
               Workspaces.accept_workspace_invite(leaving_scope, invite.code)

      refute Repo.get_by(ActivityItem,
               recipient_user_id: leaving_scope.user.id,
               workspace_id: workspace.id
             )
    end

    test "allows a non-owner workspace member to leave a workspace" do
      owner_scope = user_scope_fixture()
      member_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Team Space"})
      add_workspace_member!(workspace, member_scope)

      assert {:ok, %WorkspaceMembership{}} =
               Workspaces.leave_workspace(member_scope, workspace.id)

      refute Repo.get_by(WorkspaceMembership,
               workspace_id: workspace.id,
               user_id: member_scope.user.id
             )

      assert Workspaces.list_workspaces(member_scope) == {:ok, []}
    end

    test "deletes the leaving member read rows for channels in that workspace" do
      owner_scope = user_scope_fixture()
      member_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Team Space"})
      {:ok, channel} = Workspaces.create_channel(owner_scope, workspace.id, %{name: "planning"})
      {:ok, other_workspace} = Workspaces.create_workspace(member_scope, %{name: "Other Space"})
      add_workspace_member!(workspace, member_scope)

      Repo.insert!(
        ChannelReadState.changeset(%ChannelReadState{}, %{
          channel_id: workspace.default_channel_id,
          user_id: member_scope.user.id,
          unread_count: 1,
          first_unread_seq: 1,
          last_unread_seq: 1
        })
      )

      Repo.insert!(
        ChannelUnreadSpan.changeset(%ChannelUnreadSpan{}, %{
          channel_id: workspace.default_channel_id,
          user_id: member_scope.user.id,
          from_seq: 1,
          to_seq: 1
        })
      )

      Repo.insert!(
        ChannelReadState.changeset(%ChannelReadState{}, %{
          channel_id: channel.id,
          user_id: member_scope.user.id,
          unread_count: 1,
          first_unread_seq: 1,
          last_unread_seq: 1
        })
      )

      Repo.insert!(
        ChannelUnreadSpan.changeset(%ChannelUnreadSpan{}, %{
          channel_id: channel.id,
          user_id: member_scope.user.id,
          from_seq: 1,
          to_seq: 1
        })
      )

      Repo.insert!(
        ChannelUnreadSpan.changeset(%ChannelUnreadSpan{}, %{
          channel_id: other_workspace.default_channel_id,
          user_id: member_scope.user.id,
          from_seq: 1,
          to_seq: 1
        })
      )

      assert {:ok, %WorkspaceMembership{}} =
               Workspaces.leave_workspace(member_scope, workspace.id)

      refute Repo.get_by(ChannelReadState,
               channel_id: workspace.default_channel_id,
               user_id: member_scope.user.id
             )

      refute Repo.get_by(ChannelUnreadSpan,
               channel_id: workspace.default_channel_id,
               user_id: member_scope.user.id
             )

      refute Repo.get_by(ChannelReadState,
               channel_id: channel.id,
               user_id: member_scope.user.id
             )

      refute Repo.get_by(ChannelUnreadSpan,
               channel_id: channel.id,
               user_id: member_scope.user.id
             )

      assert Repo.get_by(ChannelReadState,
               channel_id: other_workspace.default_channel_id,
               user_id: member_scope.user.id
             )

      assert Repo.get_by(ChannelUnreadSpan,
               channel_id: other_workspace.default_channel_id,
               user_id: member_scope.user.id
             )
    end

    test "requires owners to delete the workspace instead of leaving" do
      owner_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Team Space"})

      assert Workspaces.leave_workspace(owner_scope, workspace.id) == {:error, :owner_must_delete}

      assert Repo.get_by(WorkspaceMembership,
               workspace_id: workspace.id,
               user_id: owner_scope.user.id
             )
    end

    test "distinguishes missing workspaces, non-members, and unauthenticated scopes" do
      owner_scope = user_scope_fixture()
      non_member_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Team Space"})

      assert Workspaces.leave_workspace(owner_scope, -1) == {:error, :not_found}
      assert Workspaces.leave_workspace(non_member_scope, workspace.id) == {:error, :unauthorized}
      assert Workspaces.leave_workspace(nil, workspace.id) == {:error, :unauthenticated}

      assert Workspaces.leave_workspace(%DiscordClone.Accounts.Scope{}, workspace.id) ==
               {:error, :unauthenticated}
    end
  end

  describe "delete_workspace/2" do
    test "allows the owner to delete a workspace" do
      owner_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Team Space"})
      {:ok, channel} = Workspaces.create_channel(owner_scope, workspace.id, %{name: "planning"})

      assert {:ok, deleted_workspace} = Workspaces.delete_workspace(owner_scope, workspace.id)

      assert deleted_workspace.id == workspace.id
      refute Repo.get(DiscordClone.Workspaces.Workspace, workspace.id)
      refute Repo.get(Channel, channel.id)
      refute Repo.get_by(WorkspaceMembership, workspace_id: workspace.id)
      assert Workspaces.list_workspaces(owner_scope) == {:ok, []}
    end

    test "stops the workspace presence runtime for a deleted workspace" do
      owner_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Team Space"})

      assert :ok = DiscordClone.Chat.join_workspace_presence(owner_scope, workspace.id)
      presence_pid = Runtime.workspace_presence_pid(workspace.id)
      assert is_pid(presence_pid)

      ref = Process.monitor(presence_pid)

      assert {:ok, deleted_workspace} = Workspaces.delete_workspace(owner_scope, workspace.id)

      assert deleted_workspace.id == workspace.id
      assert_receive {:DOWN, ^ref, :process, ^presence_pid, :shutdown}
      assert Runtime.workspace_presence_pid(workspace.id) == nil
    end

    test "rejects non-owners, missing workspaces, and unauthenticated scopes" do
      owner_scope = user_scope_fixture()
      member_scope = user_scope_fixture()
      {:ok, workspace} = Workspaces.create_workspace(owner_scope, %{name: "Team Space"})
      add_workspace_member!(workspace, member_scope)

      assert Workspaces.delete_workspace(member_scope, workspace.id) == {:error, :owner_required}
      assert Workspaces.delete_workspace(owner_scope, -1) == {:error, :not_found}
      assert Workspaces.delete_workspace(nil, workspace.id) == {:error, :unauthenticated}

      assert Workspaces.delete_workspace(%DiscordClone.Accounts.Scope{}, workspace.id) ==
               {:error, :unauthenticated}

      assert Repo.get(DiscordClone.Workspaces.Workspace, workspace.id)
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

  defp backdate_message!(%Message{id: id}, %DateTime{} = inserted_at) do
    {1, _} =
      Repo.update_all(
        from(message in Message, where: message.id == ^id),
        set: [inserted_at: inserted_at]
      )
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
end
