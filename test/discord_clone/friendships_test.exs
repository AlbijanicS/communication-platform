defmodule DiscordClone.FriendshipsTest do
  use DiscordClone.DataCase, async: false

  import DiscordClone.AccountsFixtures

  alias DiscordClone.Activities
  alias DiscordClone.Activities.ActivityItem
  alias DiscordClone.Chat
  alias DiscordClone.Friendships
  alias DiscordClone.Repo
  alias DiscordClone.Workspaces
  alias DiscordClone.Workspaces.WorkspaceMembership

  describe "send_friend_request/2" do
    test "creates one private incoming-request Activity Item for the recipient" do
      requester = user_fixture(username: "activity_requester")
      recipient = user_fixture(username: "activity_recipient")

      assert {:ok, %{relationship: relationship}} =
               Friendships.send_friend_request(user_scope_fixture(requester), %{
                 username: recipient.username
               })

      assert %ActivityItem{
               recipient_user_id: recipient_id,
               actor_user_id: requester_id,
               kind: "friend_request_received"
             } =
               Repo.get_by(ActivityItem,
                 recipient_user_id: recipient.id,
                 kind: "friend_request_received"
               )

      assert recipient_id == recipient.id
      assert requester_id == requester.id

      assert Repo.aggregate(
               from(item in ActivityItem,
                 where:
                   item.recipient_user_id == ^recipient.id and
                     item.kind == "friend_request_received"
               ),
               :count
             ) == 1

      assert {:ok, %{relationship: repeated}} =
               Friendships.send_friend_request(user_scope_fixture(requester), %{
                 username: recipient.username
               })

      assert repeated.id == relationship.id

      assert Repo.aggregate(
               from(item in ActivityItem,
                 where:
                   item.recipient_user_id == ^recipient.id and
                     item.kind == "friend_request_received"
               ),
               :count
             ) == 1
    end

    test "resolves only a canonical exact global username" do
      requester = user_fixture(username: "requester")
      target = user_fixture(username: "exact_target")
      scope = user_scope_fixture(requester)

      assert {:ok, %{relationship: request, user: resolved_target}} =
               Friendships.send_friend_request(scope, %{username: "  EXACT_TARGET  "})

      assert request.status == :pending
      assert request.requested_by_user_id == requester.id
      assert target.id in [request.user_low_id, request.user_high_id]
      assert resolved_target.id == target.id

      assert {:error, :unknown_user} =
               Friendships.send_friend_request(scope, %{username: "exact"})

      assert {:error, :unknown_user} =
               Friendships.send_friend_request(scope, %{username: "missing_user"})
    end

    test "rejects self-targeting and unauthenticated calls" do
      user = user_fixture(username: "self_target")

      assert {:error, :self_request} =
               Friendships.send_friend_request(user_scope_fixture(user), %{
                 username: user.username
               })

      assert {:error, :unauthenticated} =
               Friendships.send_friend_request(nil, %{username: user.username})
    end

    test "is idempotent for repeated pending requests" do
      requester = user_fixture(username: "repeat_sender")
      target = user_fixture(username: "repeat_target")
      scope = user_scope_fixture(requester)

      assert {:ok, %{relationship: first}} =
               Friendships.send_friend_request(scope, %{username: target.username})

      assert {:ok, %{relationship: repeated}} =
               Friendships.send_friend_request(scope, %{username: target.username})

      assert repeated.id == first.id
      assert repeated.status == :pending
    end

    test "crossed requests atomically resolve to one accepted relationship" do
      first_user = user_fixture(username: "crossed_first")
      second_user = user_fixture(username: "crossed_second")

      requests = [
        {user_scope_fixture(first_user), second_user.username},
        {user_scope_fixture(second_user), first_user.username}
      ]

      results =
        requests
        |> Task.async_stream(
          fn {scope, username} ->
            Friendships.send_friend_request(scope, %{username: username})
          end,
          ordered: false,
          timeout: :infinity
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert [
               {:ok, %{relationship: first}},
               {:ok, %{relationship: second}}
             ] = results

      assert first.id == second.id
      relationship_id = first.id

      assert {:ok, %{id: ^relationship_id, status: :accepted}} =
               Friendships.get_relationship(user_scope_fixture(first_user), relationship_id)
    end
  end

  describe "send_friend_request_to_workspace_member/3" do
    test "uses the known member while re-authorizing both Workspace Memberships" do
      requester = user_fixture(username: "member_action_requester")
      requester_scope = user_scope_fixture(requester)
      target = user_fixture(username: "member_action_target")
      outsider = user_fixture(username: "member_action_outsider")
      nonmember_target = user_fixture(username: "not_a_member_target")

      {:ok, workspace} = Workspaces.create_workspace(requester_scope, %{name: "Friends Foundry"})

      %WorkspaceMembership{}
      |> WorkspaceMembership.changeset(%{
        workspace_id: workspace.id,
        user_id: target.id,
        role: "member"
      })
      |> Repo.insert!()

      assert {:ok, %{relationship: request, user: resolved_target}} =
               Friendships.send_friend_request_to_workspace_member(
                 requester_scope,
                 workspace.id,
                 target.id
               )

      assert request.status == :pending
      assert resolved_target.id == target.id

      assert {:error, :unauthenticated} =
               Friendships.send_friend_request_to_workspace_member(nil, workspace.id, target.id)

      assert {:error, :unauthorized} =
               Friendships.send_friend_request_to_workspace_member(
                 user_scope_fixture(outsider),
                 workspace.id,
                 target.id
               )

      assert {:error, :not_found} =
               Friendships.send_friend_request_to_workspace_member(
                 requester_scope,
                 workspace.id,
                 nonmember_target.id
               )

      assert {:error, :self_request} =
               Friendships.send_friend_request_to_workspace_member(
                 requester_scope,
                 workspace.id,
                 requester.id
               )
    end
  end

  describe "pending request lists" do
    test "separates stable incoming and outgoing lists without workspace membership" do
      user = user_fixture(username: "list_owner")
      incoming_user = user_fixture(username: "incoming_user")
      outgoing_user = user_fixture(username: "outgoing_user")

      assert {:ok, %{relationship: incoming_request}} =
               Friendships.send_friend_request(user_scope_fixture(incoming_user), %{
                 username: user.username
               })

      assert {:ok, %{relationship: outgoing_request}} =
               Friendships.send_friend_request(user_scope_fixture(user), %{
                 username: outgoing_user.username
               })

      assert {:ok, [incoming]} =
               Friendships.list_incoming_requests(user_scope_fixture(user))

      assert {:ok, [outgoing]} =
               Friendships.list_outgoing_requests(user_scope_fixture(user))

      assert incoming.relationship.id == incoming_request.id
      assert incoming.user.username == incoming_user.username
      assert outgoing.relationship.id == outgoing_request.id
      assert outgoing.user.username == outgoing_user.username
    end

    test "does not expose another pair through lists or direct relationship lookup" do
      first_user = user_fixture(username: "private_first")
      second_user = user_fixture(username: "private_second")
      unrelated_user = user_fixture(username: "private_unrelated")

      assert {:ok, %{relationship: relationship}} =
               Friendships.send_friend_request(user_scope_fixture(first_user), %{
                 username: second_user.username
               })

      unrelated_scope = user_scope_fixture(unrelated_user)

      assert {:ok, []} = Friendships.list_incoming_requests(unrelated_scope)
      assert {:ok, []} = Friendships.list_outgoing_requests(unrelated_scope)

      assert {:error, :not_found} =
               Friendships.get_relationship(unrelated_scope, relationship.id)

      assert {:error, :unauthenticated} = Friendships.list_incoming_requests(nil)
      assert {:error, :unauthenticated} = Friendships.list_outgoing_requests(nil)
    end
  end

  describe "relationship_state/2" do
    test "reports the scoped direction through the full Friendship lifecycle" do
      requester = user_fixture(username: "state_requester")
      recipient = user_fixture(username: "state_recipient")
      requester_scope = user_scope_fixture(requester)
      recipient_scope = user_scope_fixture(recipient)

      assert {:ok, :none} = Friendships.relationship_state(requester_scope, recipient.id)
      assert {:ok, :none} = Friendships.relationship_state(recipient_scope, requester.id)

      assert {:ok, %{relationship: request}} =
               Friendships.send_friend_request(requester_scope, %{username: recipient.username})

      assert {:ok, :outgoing_request} =
               Friendships.relationship_state(requester_scope, recipient.id)

      assert {:ok, :incoming_request} =
               Friendships.relationship_state(recipient_scope, requester.id)

      assert {:ok, friendship} =
               Friendships.accept_friend_request(recipient_scope, request.id)

      assert {:ok, :friends} = Friendships.relationship_state(requester_scope, recipient.id)
      assert {:ok, :friends} = Friendships.relationship_state(recipient_scope, requester.id)

      assert :ok = Friendships.remove_friend(requester_scope, friendship.id)
      assert {:ok, :none} = Friendships.relationship_state(requester_scope, recipient.id)
      assert {:error, :not_found} = Friendships.relationship_state(requester_scope, "invalid")
      assert {:error, :unauthenticated} = Friendships.relationship_state(nil, recipient.id)
    end
  end

  describe "Friend Request and Friendship lifecycle" do
    setup do
      requester = user_fixture(username: "lifecycle_requester")
      recipient = user_fixture(username: "lifecycle_recipient")

      %{
        requester: requester,
        requester_scope: user_scope_fixture(requester),
        recipient: recipient,
        recipient_scope: user_scope_fixture(recipient)
      }
    end

    test "the recipient accepts a request and both Users list one mutual Friendship", context do
      assert {:ok, %{relationship: request}} =
               Friendships.send_friend_request(context.requester_scope, %{
                 username: context.recipient.username
               })

      assert {:ok, friendship} =
               Friendships.accept_friend_request(context.recipient_scope, request.id)

      assert friendship.id == request.id
      assert friendship.status == :accepted
      assert friendship.accepted_at

      assert {:ok, [%{relationship: requester_friendship, user: recipient}]} =
               Friendships.list_friends(context.requester_scope)

      assert {:ok, [%{relationship: recipient_friendship, user: requester}]} =
               Friendships.list_friends(context.recipient_scope)

      assert requester_friendship.id == friendship.id
      assert recipient_friendship.id == friendship.id
      assert recipient.id == context.recipient.id
      assert requester.id == context.requester.id
    end

    test "acceptance creates requester Activity while request Activity remains in history",
         context do
      assert {:ok, %{relationship: request}} =
               Friendships.send_friend_request(context.requester_scope, %{
                 username: context.recipient.username
               })

      received_item =
        Repo.get_by!(ActivityItem,
          recipient_user_id: context.recipient.id,
          kind: ActivityItem.friend_request_received_kind()
        )

      assert received_item.source_friend_relationship_id == request.id
      assert is_nil(received_item.source_message_id)
      assert is_nil(received_item.source_conversation_id)
      assert is_nil(received_item.workspace_id)

      assert {:ok, %{items: [listed_received], next_cursor: nil}} =
               Chat.list_activity_feed(context.recipient_scope)

      assert listed_received.id == received_item.id

      assert {:ok, %{items: [], next_cursor: nil}} =
               Chat.list_activity_feed(context.requester_scope)

      assert {:ok, friendship} =
               Friendships.accept_friend_request(context.recipient_scope, request.id)

      accepted_item =
        Repo.get_by!(ActivityItem,
          recipient_user_id: context.requester.id,
          kind: ActivityItem.friend_request_accepted_kind()
        )

      assert accepted_item.actor_user_id == context.recipient.id
      assert accepted_item.source_friend_relationship_id == friendship.id
      assert Repo.get!(ActivityItem, received_item.id)

      assert {:ok, %{friends_section: :friends}} =
               Chat.open_activity_item(context.recipient_scope, received_item.id)

      assert {:ok, 1} = Chat.unread_activity_count(context.requester_scope)
      assert {:ok, 0} = Chat.unread_activity_count(context.recipient_scope)
      assert {:ok, [_friendship]} = Friendships.list_friends(context.recipient_scope)
    end

    test "declining and cancelling remove obsolete request Activity without notifying requester",
         context do
      assert {:ok, %{relationship: declined_request}} =
               Friendships.send_friend_request(context.requester_scope, %{
                 username: context.recipient.username
               })

      declined_item =
        Repo.get_by!(ActivityItem, source_friend_relationship_id: declined_request.id)

      assert :ok =
               Friendships.decline_friend_request(context.recipient_scope, declined_request.id)

      refute Repo.get(ActivityItem, declined_item.id)
      assert {:ok, 0} = Chat.unread_activity_count(context.recipient_scope)
      assert {:ok, 0} = Chat.unread_activity_count(context.requester_scope)

      assert {:ok, %{relationship: cancelled_request}} =
               Friendships.send_friend_request(context.requester_scope, %{
                 username: context.recipient.username
               })

      cancelled_item =
        Repo.get_by!(ActivityItem, source_friend_relationship_id: cancelled_request.id)

      assert :ok =
               Friendships.cancel_friend_request(context.requester_scope, cancelled_request.id)

      refute Repo.get(ActivityItem, cancelled_item.id)
      assert {:ok, 0} = Chat.unread_activity_count(context.recipient_scope)
      assert {:ok, 0} = Chat.unread_activity_count(context.requester_scope)
    end

    test "opening relationship Activity marks only that item read without resolving requests",
         context do
      other_requester = user_fixture(username: "activity_other_requester")

      assert {:ok, %{relationship: first_request}} =
               Friendships.send_friend_request(context.requester_scope, %{
                 username: context.recipient.username
               })

      assert {:ok, %{relationship: second_request}} =
               Friendships.send_friend_request(user_scope_fixture(other_requester), %{
                 username: context.recipient.username
               })

      first_item =
        Repo.get_by!(ActivityItem, source_friend_relationship_id: first_request.id)

      second_item =
        Repo.get_by!(ActivityItem, source_friend_relationship_id: second_request.id)

      assert {:ok,
              %{
                friend_relationship_id: relationship_id,
                friends_section: :incoming_requests
              }} = Chat.open_activity_item(context.recipient_scope, first_item.id)

      assert relationship_id == first_request.id
      assert %DateTime{} = Repo.reload!(first_item).read_at
      assert is_nil(Repo.reload!(second_item).read_at)
      assert {:ok, 1} = Chat.unread_activity_count(context.recipient_scope)

      assert {:ok, incoming_requests} =
               Friendships.list_incoming_requests(context.recipient_scope)

      assert MapSet.new(Enum.map(incoming_requests, & &1.relationship.id)) ==
               MapSet.new([first_request.id, second_request.id])

      assert {:error, :not_found} =
               Chat.open_activity_item(context.requester_scope, first_item.id)

      assert {:ok, %{items: history}} = Chat.list_activity_feed(context.recipient_scope)
      assert first_item.id in Enum.map(history, & &1.id)
    end

    test "the recipient declines and the requester cancels pending requests", context do
      assert {:ok, %{relationship: declined_request}} =
               Friendships.send_friend_request(context.requester_scope, %{
                 username: context.recipient.username
               })

      assert :ok =
               Friendships.decline_friend_request(
                 context.recipient_scope,
                 declined_request.id
               )

      assert {:error, :not_found} =
               Friendships.get_relationship(context.requester_scope, declined_request.id)

      assert {:ok, %{relationship: cancelled_request}} =
               Friendships.send_friend_request(context.requester_scope, %{
                 username: context.recipient.username
               })

      assert :ok =
               Friendships.cancel_friend_request(
                 context.requester_scope,
                 cancelled_request.id
               )

      assert {:ok, []} = Friendships.list_incoming_requests(context.recipient_scope)
      assert {:ok, []} = Friendships.list_outgoing_requests(context.requester_scope)
    end

    test "either Friend removes the Friendship and a later accepted request restores it",
         context do
      assert {:ok, %{relationship: request}} =
               Friendships.send_friend_request(context.requester_scope, %{
                 username: context.recipient.username
               })

      assert {:ok, friendship} =
               Friendships.accept_friend_request(context.recipient_scope, request.id)

      assert :ok = Friendships.remove_friend(context.requester_scope, friendship.id)
      assert {:ok, []} = Friendships.list_friends(context.requester_scope)
      assert {:ok, []} = Friendships.list_friends(context.recipient_scope)

      assert {:ok, %{relationship: restored_request}} =
               Friendships.send_friend_request(context.recipient_scope, %{
                 username: context.requester.username
               })

      assert {:ok, restored_friendship} =
               Friendships.accept_friend_request(
                 context.requester_scope,
                 restored_request.id
               )

      refute restored_friendship.id == friendship.id
      assert {:ok, [_one_friendship]} = Friendships.list_friends(context.requester_scope)
      assert {:ok, [_one_friendship]} = Friendships.list_friends(context.recipient_scope)
    end

    test "mutations re-authorize the actor and distinguish invalid state", context do
      unrelated = user_fixture(username: "lifecycle_unrelated")
      unrelated_scope = user_scope_fixture(unrelated)

      assert {:ok, %{relationship: request}} =
               Friendships.send_friend_request(context.requester_scope, %{
                 username: context.recipient.username
               })

      assert {:error, :unauthenticated} =
               Friendships.accept_friend_request(nil, request.id)

      assert {:error, :not_found} =
               Friendships.accept_friend_request(unrelated_scope, request.id)

      assert {:error, :unauthorized} =
               Friendships.accept_friend_request(context.requester_scope, request.id)

      assert {:error, :unauthorized} =
               Friendships.cancel_friend_request(context.recipient_scope, request.id)

      assert {:error, :stale_state} =
               Friendships.remove_friend(context.requester_scope, request.id)

      assert {:ok, friendship} =
               Friendships.accept_friend_request(context.recipient_scope, request.id)

      assert {:error, :stale_state} =
               Friendships.accept_friend_request(context.recipient_scope, friendship.id)

      assert {:error, :stale_state} =
               Friendships.decline_friend_request(context.recipient_scope, friendship.id)

      assert {:error, :stale_state} =
               Friendships.cancel_friend_request(context.requester_scope, friendship.id)
    end

    test "committed changes broadcast only on the affected Users' private topics", context do
      unrelated = user_fixture(username: "lifecycle_event_unrelated")

      assert :ok = Friendships.subscribe(context.requester_scope)
      assert :ok = Friendships.subscribe(context.recipient_scope)
      assert :ok = Friendships.subscribe(user_scope_fixture(unrelated))

      assert {:ok, %{relationship: request}} =
               Friendships.send_friend_request(context.requester_scope, %{
                 username: context.recipient.username
               })

      assert_receive {:friendships_changed, %{action: :requested, relationship_id: request_id}}
      assert request_id == request.id

      assert_receive {:friendships_changed, %{action: :requested, relationship_id: request_id}}
      assert request_id == request.id
      refute_receive {:friendships_changed, _payload}

      assert {:ok, %{relationship: repeated_request}} =
               Friendships.send_friend_request(context.requester_scope, %{
                 username: context.recipient.username
               })

      assert repeated_request.id == request.id
      refute_receive {:friendships_changed, _payload}

      assert {:ok, friendship} =
               Friendships.accept_friend_request(context.recipient_scope, request.id)

      assert_receive {:friendships_changed,
                      %{action: :accepted, relationship_id: relationship_id}}

      assert relationship_id == friendship.id

      assert_receive {:friendships_changed,
                      %{action: :accepted, relationship_id: relationship_id}}

      assert relationship_id == friendship.id

      assert {:ok, %{relationship: repeated_friendship}} =
               Friendships.send_friend_request(context.requester_scope, %{
                 username: context.recipient.username
               })

      assert repeated_friendship.id == friendship.id
      refute_receive {:friendships_changed, _payload}
    end

    test "Activity changes publish only to the recipient after relationship commits", context do
      unrelated_scope = user_scope_fixture(user_fixture(username: "activity_private_unrelated"))

      start_activity_subscriber!(:recipient, context.recipient_scope)
      start_activity_subscriber!(:unrelated_request, unrelated_scope)

      assert {:ok, %{relationship: request}} =
               Friendships.send_friend_request(context.requester_scope, %{
                 username: context.recipient.username
               })

      assert_receive {:recipient,
                      {:activity_changed,
                       %{
                         action: :created,
                         source_friend_relationship_id: relationship_id
                       }}}

      assert relationship_id == request.id
      refute_receive {:unrelated_request, {:activity_changed, _payload}}

      start_activity_subscriber!(:requester, context.requester_scope)
      start_activity_subscriber!(:unrelated_accept, unrelated_scope)

      assert {:ok, friendship} =
               Friendships.accept_friend_request(context.recipient_scope, request.id)

      assert_receive {:requester,
                      {:activity_changed,
                       %{
                         action: :created,
                         source_friend_relationship_id: relationship_id
                       }}}

      assert relationship_id == friendship.id
      refute_receive {:unrelated_accept, {:activity_changed, _payload}}
    end

    test "simultaneous reverse requests retain one accepted row", context do
      calls = [
        {context.requester_scope, context.recipient.username},
        {context.recipient_scope, context.requester.username},
        {context.requester_scope, context.recipient.username},
        {context.recipient_scope, context.requester.username}
      ]

      results =
        calls
        |> Task.async_stream(
          fn {scope, username} ->
            Friendships.send_friend_request(scope, %{username: username})
          end,
          ordered: false,
          max_concurrency: 4,
          timeout: :infinity
        )
        |> Enum.map(fn {:ok, {:ok, %{relationship: relationship}}} -> relationship end)

      assert Enum.uniq_by(results, & &1.id) |> length() == 1
      assert {:ok, [_one_friendship]} = Friendships.list_friends(context.requester_scope)

      [relationship_id] = results |> Enum.map(& &1.id) |> Enum.uniq()

      relationship_activity =
        Repo.all(
          from item in ActivityItem,
            where: item.source_friend_relationship_id == ^relationship_id
        )

      assert MapSet.new(Enum.map(relationship_activity, & &1.kind)) ==
               MapSet.new([
                 ActivityItem.friend_request_received_kind(),
                 ActivityItem.friend_request_accepted_kind()
               ])

      assert MapSet.new(Enum.map(relationship_activity, & &1.recipient_user_id)) ==
               MapSet.new([context.requester.id, context.recipient.id])
    end
  end

  defp start_activity_subscriber!(label, scope) do
    parent = self()

    start_supervised!(%{
      id: {__MODULE__, label},
      start:
        {Task, :start_link,
         [
           fn ->
             :ok = Activities.subscribe(scope)
             send(parent, {:activity_subscriber_ready, label})

             receive do
               message -> send(parent, {label, message})
             end
           end
         ]}
    })

    assert_receive {:activity_subscriber_ready, ^label}
  end
end
