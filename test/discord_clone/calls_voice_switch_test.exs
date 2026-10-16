defmodule DiscordClone.CallsVoiceSwitchTest do
  @moduledoc false
  use DiscordClone.DataCase, async: false

  import DiscordClone.CallsFixtures
  import Phoenix.ChannelTest

  alias DiscordClone.Accounts
  alias DiscordClone.Calls
  alias DiscordClone.Calls.CallAttempt
  alias DiscordClone.Media.AdmissionCoordinator
  alias DiscordClone.Media.Target
  alias DiscordClone.MediaFixtures
  alias DiscordClone.Repo
  alias DiscordClone.Voice
  alias DiscordClone.Workspaces
  alias DiscordCloneWeb.{CallSignaling, VoiceChannel, VoiceSocket}

  @endpoint DiscordCloneWeb.Endpoint

  setup do
    start_supervised!(DiscordClone.Calls.Supervisor)
    DiscordClone.Calls.CallCoordinator.begin_recovery()
    await_recovery_finished()

    previous_runtime = Application.get_env(:discord_clone, :accepted_call_runtime)
    previous_result = Application.get_env(:discord_clone, :accepted_call_runtime_result)

    Application.put_env(
      :discord_clone,
      :accepted_call_runtime,
      DiscordClone.Calls.PairAdmissionRuntime
    )

    Application.delete_env(:discord_clone, :accepted_call_runtime_result)

    on_exit(fn ->
      if is_nil(previous_runtime) do
        Application.delete_env(:discord_clone, :accepted_call_runtime)
      else
        Application.put_env(:discord_clone, :accepted_call_runtime, previous_runtime)
      end

      if is_nil(previous_result) do
        Application.delete_env(:discord_clone, :accepted_call_runtime_result)
      else
        Application.put_env(:discord_clone, :accepted_call_runtime_result, previous_result)
      end
    end)

    MediaFixtures.setup_coordinator_pair_state!()

    on_exit(fn ->
      Voice.running_room_servers()
      |> Enum.each(fn {voice_channel_id, _room_server} ->
        :ok = Voice.end_channel_sessions(voice_channel_id)
        :ok = Voice.expire_idle_room(voice_channel_id)
      end)
    end)

    :ok
  end

  describe "destination preparation" do
    test "blocked startup of a new destination leaves unrelated room admission responsive" do
      {caller, recipient, conversation, _friendship} =
        direct_conversation_fixture("vswitch_blocked_start")

      assert {:ok, %{call: ringing}} = Calls.start_call(caller, conversation.id, :audio)
      assert {:ok, _} = Calls.accept_call(recipient, ringing.call_id, :audio)
      assert eventually_active?(ringing.call_id)

      unrelated = Ecto.UUID.generate()
      assert :ok = Voice.ensure_room(unrelated)
      destination = Ecto.UUID.generate()
      tasks = start_supervised!(Task.Supervisor)
      parent = self()
      supervisor = DiscordClone.Voice.RoomSupervisor
      :ok = :sys.suspend(supervisor)

      switch =
        Task.Supervisor.async_nolink(tasks, fn ->
          Voice.join(destination, caller.user.id, "blocked-switch", parent)
        end)

      try do
        await_queued_command(supervisor, :start_child)

        admission =
          Task.Supervisor.async_nolink(tasks, fn ->
            Voice.join(unrelated, Ecto.UUID.generate(), "unrelated", parent)
          end)

        assert {:ok, {:ok, %{occupancy: 1}}} = Task.yield(admission, 1_000)
        assert {:ok, %{state: :active}} = Calls.get_call(caller, ringing.call_id)
        assert %{target: target} = AdmissionCoordinator.current_identity(caller.user.id)
        assert target == Target.direct_call(ringing.call_id)
        assert %{target: ^target} = AdmissionCoordinator.current_identity(recipient.user.id)
      after
        :ok = :sys.resume(supervisor)
      end

      assert {:ok, %{occupancy: 1}} = Task.await(switch)

      assert {:ok, %{state: :terminal, terminal_outcome: :ended}} =
               Calls.get_call(caller, ringing.call_id)

      assert AdmissionCoordinator.current_identity(recipient.user.id) == nil
    end

    test "blocked destination startup expires without holding capacity or ending the Call" do
      {caller, recipient, conversation, _friendship} =
        direct_conversation_fixture("vswitch_start_timeout")

      assert {:ok, %{call: ringing}} = Calls.start_call(caller, conversation.id, :audio)
      assert {:ok, _} = Calls.accept_call(recipient, ringing.call_id, :audio)
      assert eventually_active?(ringing.call_id)

      caller_identity = AdmissionCoordinator.current_identity(caller.user.id)
      recipient_identity = AdmissionCoordinator.current_identity(recipient.user.id)
      destination = Ecto.UUID.generate()
      tasks = start_supervised!(Task.Supervisor)
      parent = self()
      supervisor = DiscordClone.Voice.RoomSupervisor
      :ok = :sys.suspend(supervisor)

      switch =
        Task.Supervisor.async_nolink(tasks, fn ->
          Voice.join(destination, caller.user.id, "startup-timeout", parent)
        end)

      try do
        await_queued_command(supervisor, :start_child)
        assert {:error, :unavailable} = Task.await(switch, 6_000)
        assert {:ok, %{state: :active}} = Calls.get_call(caller, ringing.call_id)
        assert AdmissionCoordinator.current_identity(caller.user.id) == caller_identity
        assert AdmissionCoordinator.current_identity(recipient.user.id) == recipient_identity
        assert AdmissionCoordinator.effective_occupancy() == 2
      after
        :ok = :sys.resume(supervisor)
      end

      # Processing the abandoned supervisor request may create an empty room,
      # but it cannot grant a switch or consume replacement credit later.
      _ = DynamicSupervisor.which_children(supervisor)
      assert {:ok, %{state: :active}} = Calls.get_call(caller, ringing.call_id)
      assert AdmissionCoordinator.effective_occupancy() == 2

      assert {:ok, %{occupancy: 1}} =
               Voice.join(destination, caller.user.id, "after-startup-timeout", self())
    end

    test "failed occupancy preparation preserves both exact active Call Sessions" do
      {caller, recipient, conversation, _friendship} =
        direct_conversation_fixture("vswitch_prep_timeout")

      assert {:ok, %{call: ringing}} = Calls.start_call(caller, conversation.id, :audio)
      assert {:ok, _} = Calls.accept_call(recipient, ringing.call_id, :audio)
      assert eventually_active?(ringing.call_id)

      caller_identity = AdmissionCoordinator.current_identity(caller.user.id)
      recipient_identity = AdmissionCoordinator.current_identity(recipient.user.id)
      destination = Ecto.UUID.generate()
      assert :ok = Voice.ensure_room(destination)

      {^destination, room} =
        Enum.find(Voice.running_room_servers(), fn {id, _pid} -> id == destination end)

      tasks = start_supervised!(Task.Supervisor)
      parent = self()
      :ok = :sys.suspend(room)

      switch =
        Task.Supervisor.async_nolink(tasks, fn ->
          Voice.join(destination, caller.user.id, "preparation-timeout", parent)
        end)

      try do
        await_queued_command(room, :occupancy)
        assert AdmissionCoordinator.current_identity(caller.user.id) == caller_identity
        assert AdmissionCoordinator.current_identity(recipient.user.id) == recipient_identity
        assert {:error, :unavailable} = Task.await(switch, 6_000)
      after
        :ok = :sys.resume(room)
      end

      assert {:ok, %{state: :active}} = Calls.get_call(caller, ringing.call_id)
      assert AdmissionCoordinator.current_identity(caller.user.id) == caller_identity
      assert AdmissionCoordinator.current_identity(recipient.user.id) == recipient_identity
      assert {:ok, %{occupancy: 0}} = Voice.room_occupancy(destination)

      # The late occupancy reply left no hold, pin, or replacement credit.
      assert AdmissionCoordinator.effective_occupancy() == 2

      assert {:ok, %{occupancy: 1}} =
               Voice.join(destination, caller.user.id, "after-preparation-failure", self())
    end
  end

  describe "rejection preserves the active Call" do
    test "full destination Voice Channel rejects the switch and leaves the Call active for both" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("vswitch_full")

      assert {:ok, %{call: ringing}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      assert {:ok, _connecting} = Calls.accept_call(recipient_scope, ringing.call_id, :audio)
      assert eventually_active?(ringing.call_id)

      caller_id = caller_scope.user.id
      recipient_id = recipient_scope.user.id
      call_id = ringing.call_id

      assert %{target: %Target{kind: :direct_call, id: ^call_id}} =
               AdmissionCoordinator.current_identity(caller_id)

      destination = Ecto.UUID.generate()

      for number <- 1..5 do
        assert {:ok, %{occupancy: ^number}} =
                 Voice.join(destination, Ecto.UUID.generate(), "full-#{number}", self())
      end

      assert {:error, %{reason: :room_full, occupancy: 5, capacity: 5}} =
               Voice.join(destination, caller_id, "switch-attempt", self())

      # Call preserved for both, no Voice change.
      assert %CallAttempt{state: :active} = Repo.get!(CallAttempt, call_id)

      assert %{target: %Target{kind: :direct_call, id: ^call_id}} =
               AdmissionCoordinator.current_identity(caller_id)

      assert %{target: %Target{kind: :direct_call, id: ^call_id}} =
               AdmissionCoordinator.current_identity(recipient_id)

      assert {:ok, %{occupancy: 5, capacity: 5}} = Voice.room_occupancy(destination)
    end
  end

  describe "shared capacity reverse credit" do
    test "at 20 occupied slots the reverse switch projects 19 while reserved without double charge" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("vswitch_cap")

      # 18 unrelated slots; the active Call contributes 2 for 20 total.
      Enum.each(1..18, fn index ->
        assert {:ok, _} =
                 Voice.join(
                   Ecto.UUID.generate(),
                   Ecto.UUID.generate(),
                   "cap-fill-#{index}",
                   self()
                 )
      end)

      assert {:ok, %{call: ringing}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      assert {:ok, _} = Calls.accept_call(recipient_scope, ringing.call_id, :audio)
      assert eventually_active?(ringing.call_id)

      caller_id = caller_scope.user.id
      call_id = ringing.call_id
      destination = Ecto.UUID.generate()

      # Reverse switch at full occupancy must admit (20 - 2 + 1 = 19).
      assert {:ok, %{occupancy: 1, capacity: 5}} =
               Voice.join(destination, caller_id, "cap-switch", self())

      assert %CallAttempt{state: :terminal, terminal_outcome: :ended} =
               Repo.get!(CallAttempt, call_id)

      # No double charge at conversion: 18 unrelated + 1 Voice = 19, one more admits to 20.
      assert {:ok, _} =
               Voice.join(Ecto.UUID.generate(), Ecto.UUID.generate(), "after-one", self())

      assert {:error, %{reason: :deployment_full, occupancy: 20, capacity: 20}} =
               Voice.join(Ecto.UUID.generate(), Ecto.UUID.generate(), "over-cap", self())
    end
  end

  describe "startup failure after termination" do
    test "Voice startup failure after the Call ended never recreates the Call" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("vswitch_fail")

      assert {:ok, %{call: ringing}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      assert {:ok, _} = Calls.accept_call(recipient_scope, ringing.call_id, :audio)
      assert eventually_active?(ringing.call_id)

      caller_id = caller_scope.user.id
      recipient_id = recipient_scope.user.id
      call_id = ringing.call_id
      destination = Ecto.UUID.generate()

      Application.put_env(:discord_clone, :voice_switch_fault, %{
        admit_failures: [caller_id]
      })

      assert {:error, :unavailable} =
               Voice.join(destination, caller_id, "switch-fail", self())

      # Call stays terminal ended for both; neither side restored.
      assert %CallAttempt{state: :terminal, terminal_outcome: :ended} =
               Repo.get!(CallAttempt, call_id)

      assert AdmissionCoordinator.current_identity(caller_id) == nil
      assert AdmissionCoordinator.current_identity(recipient_id) == nil
      assert_no_call_sessions(call_id)

      # Destination room never gained a ghost membership.
      assert {:ok, %{occupancy: 0}} = Voice.room_occupancy(destination)

      # A later normal Voice join still works without resurrecting the Call.
      assert {:ok, _} = Voice.join(destination, caller_id, "after-fail", self())

      assert %CallAttempt{state: :terminal, terminal_outcome: :ended} =
               Repo.get!(CallAttempt, call_id)

      assert_no_call_sessions(call_id)
    end
  end

  describe "retryable while unresolved" do
    test "Voice join while connecting returns retryable and never takes over half the Call" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("vswitch_retry")

      voice_channel = Ecto.UUID.generate()
      assert {:ok, _} = Voice.join(voice_channel, caller_scope.user.id, "retry-voice", self())

      assert {:ok, %{call: ringing}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      {^voice_channel, room_server} =
        Enum.find(Voice.running_room_servers(), fn {id, _} -> id == voice_channel end)

      :ok = :sys.suspend(room_server)

      try do
        assert {:ok, _} = Calls.accept_call(recipient_scope, ringing.call_id, :audio)
        assert %CallAttempt{state: :connecting} = Repo.get!(CallAttempt, ringing.call_id)

        assert {:error, %{reason: :reservation_conflict}} =
                 Voice.join(Ecto.UUID.generate(), caller_scope.user.id, "during-connect", self())

        assert {:error, %{reason: :reservation_conflict}} =
                 Voice.join(
                   Ecto.UUID.generate(),
                   recipient_scope.user.id,
                   "during-connect-peer",
                   self()
                 )
      after
        :ok = :sys.resume(room_server)
      end

      assert eventually_active?(ringing.call_id)

      # No half Call pair was taken over; both sides still together.
      caller_identity = AdmissionCoordinator.current_identity(caller_scope.user.id)
      recipient_identity = AdmissionCoordinator.current_identity(recipient_scope.user.id)
      assert caller_identity.target == Target.direct_call(ringing.call_id)
      assert recipient_identity.target == Target.direct_call(ringing.call_id)
      refute caller_identity.session_id == recipient_identity.session_id
    end
  end

  describe "eligible join moves only the requester" do
    test "eligible Voice join ends the Call for both, admits only the requester, peer stays out" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("vswitch_happy")

      assert :ok = Calls.subscribe(caller_scope)
      assert :ok = Calls.subscribe(recipient_scope)

      assert {:ok, %{call: ringing}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      assert_receive {:call_ringing, _}
      assert_receive {:call_ringing, _}

      assert {:ok, _connecting} = Calls.accept_call(recipient_scope, ringing.call_id, :audio)
      assert_receive {:call_connecting, _}
      assert_receive {:call_connecting, _}
      assert eventually_active?(ringing.call_id)
      assert_receive {:call_active, _}
      assert_receive {:call_active, _}

      caller_id = caller_scope.user.id
      recipient_id = recipient_scope.user.id
      call_id = ringing.call_id
      destination = Ecto.UUID.generate()

      assert {:ok, %{voice_session_id: _voice_session_id, occupancy: 1, capacity: 5}} =
               Voice.join(destination, caller_id, "switch-happy", self())

      # Durable Call ended for both with the existing ended outcome.
      assert %CallAttempt{state: :terminal, terminal_outcome: :ended} =
               Repo.get!(CallAttempt, call_id)

      assert_receive {:call_completed, first_ended}
      assert first_ended.call_id == call_id
      assert_receive {:call_completed, second_ended}
      assert second_ended.call_id == call_id

      # Only the requester is in Voice; peer is out and not moved.
      assert %{target: %Target{kind: :voice_channel, id: ^destination}} =
               AdmissionCoordinator.current_identity(caller_id)

      assert AdmissionCoordinator.current_identity(recipient_id) == nil
      assert_no_call_sessions(call_id)
      assert {:ok, %{occupancy: 1, capacity: 5}} = Voice.room_occupancy(destination)
    end

    test "terminal broadcasts reach both Users and sibling tabs exactly once via Call topic" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("vswitch_sibling")

      assert {:ok, %{call: ringing}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      assert {:ok, _} = Calls.accept_call(recipient_scope, ringing.call_id, :audio)
      assert eventually_active?(ringing.call_id)

      call_id = ringing.call_id
      topic = CallSignaling.call_topic(call_id)

      %{socket: caller_socket} = connect_calls_socket(caller_scope.user)

      %{socket: recipient_socket, token: recipient_token} =
        connect_calls_socket(recipient_scope.user)

      assert {:ok, _caller_payload, _caller_channel} =
               subscribe_and_join(caller_socket, topic)

      assert {:ok, _recipient_payload, recipient_channel} =
               subscribe_and_join(recipient_socket, topic)

      sibling_socket = connect_authenticated_calls_socket(recipient_token)

      assert {:ok, _sibling_payload, _sibling_channel} =
               subscribe_and_join(sibling_socket, topic)

      destination = Ecto.UUID.generate()

      assert {:ok, _} =
               Voice.join(destination, caller_scope.user.id, "sibling-switch", self())

      assert %CallAttempt{state: :terminal, terminal_outcome: :ended} =
               Repo.get!(CallAttempt, call_id)

      # Each joined tab observes the normal ended projection exactly once.
      assert_push "call_ended", %{call: %{call_id: ^call_id}}
      assert_push "call_ended", %{call: %{call_id: ^call_id}}
      assert_push "call_ended", %{call: %{call_id: ^call_id}}
      refute_push "call_ended", _
      refute_push "call_error", _

      assert %{target: %Target{kind: :voice_channel, id: ^destination}} =
               AdmissionCoordinator.current_identity(caller_scope.user.id)

      assert AdmissionCoordinator.current_identity(recipient_scope.user.id) == nil
      # Silence the unused-variable warning for the recipient channel.
      assert is_pid(recipient_channel.channel_pid)
    end
  end

  describe "authorization preserves the Call" do
    test "unauthorized Voice destination leaves the active Call intact with no Voice change" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("vswitch_auth")

      assert {:ok, %{call: ringing}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      assert {:ok, _} = Calls.accept_call(recipient_scope, ringing.call_id, :audio)
      assert eventually_active?(ringing.call_id)

      call_id = ringing.call_id
      caller_id = caller_scope.user.id
      recipient_id = recipient_scope.user.id

      owner = DiscordClone.AccountsFixtures.user_fixture()
      voice_channel = create_voice_channel!(owner, "Switch authz")

      {:ok, socket} = connect_voice_socket(caller_scope.user)

      assert {:error, %{reason: "not_found"}} =
               subscribe_and_join(socket, VoiceChannel, "voice:#{voice_channel.id}", %{})

      assert %CallAttempt{state: :active} = Repo.get!(CallAttempt, call_id)

      assert %{target: %Target{kind: :direct_call, id: ^call_id}} =
               AdmissionCoordinator.current_identity(caller_id)

      assert %{target: %Target{kind: :direct_call, id: ^call_id}} =
               AdmissionCoordinator.current_identity(recipient_id)

      refute Voice.room_running?(voice_channel.id)
    end
  end

  describe "destination slot races" do
    test "a join after the occupancy sample invalidates the switch before ending the Call" do
      {caller, recipient, conversation, _friendship} =
        direct_conversation_fixture("vswitch_stale_sample")

      assert {:ok, %{call: ringing}} = Calls.start_call(caller, conversation.id, :audio)
      assert {:ok, _} = Calls.accept_call(recipient, ringing.call_id, :audio)
      assert eventually_active?(ringing.call_id)

      caller_identity = AdmissionCoordinator.current_identity(caller.user.id)
      recipient_identity = AdmissionCoordinator.current_identity(recipient.user.id)
      destination = Ecto.UUID.generate()

      for occupancy <- 1..4 do
        assert {:ok, %{occupancy: ^occupancy}} =
                 Voice.join(destination, Ecto.UUID.generate(), "sample-fill-#{occupancy}", self())
      end

      {^destination, room} =
        Enum.find(Voice.running_room_servers(), fn {id, _pid} -> id == destination end)

      tasks = start_supervised!(Task.Supervisor)
      parent = self()
      :ok = :sys.suspend(room)

      switch =
        Task.Supervisor.async_nolink(tasks, fn ->
          Voice.join(destination, caller.user.id, "stale-sample-switch", parent)
        end)

      outsider =
        try do
          await_queued_command(room, :occupancy)

          outsider =
            Task.Supervisor.async_nolink(tasks, fn ->
              Voice.join(destination, Ecto.UUID.generate(), "sample-outsider", parent)
            end)

          # On resume, the room answers occupancy=4 before admitting the
          # queued outsider. The coordinator publishes that join before it
          # can grant the switch, so the old sample must be discarded.
          await_queued_command(room, :join)
          outsider
        after
          :ok = :sys.resume(room)
        end

      assert {:ok, %{occupancy: 5}} = Task.await(outsider)
      assert {:error, %{reason: :room_full, occupancy: 5, capacity: 5}} = Task.await(switch)
      assert {:ok, %{state: :active}} = Calls.get_call(caller, ringing.call_id)
      assert AdmissionCoordinator.current_identity(caller.user.id) == caller_identity
      assert AdmissionCoordinator.current_identity(recipient.user.id) == recipient_identity
      assert {:ok, %{occupancy: 5}} = Voice.room_occupancy(destination)
      assert AdmissionCoordinator.effective_occupancy() == 7
    end

    test "two racing joins for the last Voice Channel slot never exceed the five-Session cap" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("vswitch_race")

      assert {:ok, %{call: ringing}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      assert {:ok, _} = Calls.accept_call(recipient_scope, ringing.call_id, :audio)
      assert eventually_active?(ringing.call_id)

      call_id = ringing.call_id
      caller_id = caller_scope.user.id
      recipient_id = recipient_scope.user.id
      outsider_id = Ecto.UUID.generate()
      destination = Ecto.UUID.generate()

      for number <- 1..4 do
        assert {:ok, %{occupancy: ^number}} =
                 Voice.join(destination, Ecto.UUID.generate(), "race-fill-#{number}", self())
      end

      parent = self()

      switch_task =
        Task.async(fn -> Voice.join(destination, caller_id, "race-switch", parent) end)

      outsider_task =
        Task.async(fn -> Voice.join(destination, outsider_id, "race-outsider", parent) end)

      switch_result = Task.await(switch_task, 5_000)
      outsider_result = Task.await(outsider_task, 5_000)

      # The five-Session cap is never exceeded; exactly one winner admits.
      assert {:ok, %{occupancy: 5, capacity: 5}} = Voice.room_occupancy(destination)

      assert {[_winner], [loser_error]} =
               Enum.split_with([switch_result, outsider_result], &match?({:ok, _}, &1))

      assert {:error, %{reason: :room_full, capacity: 5}} = loser_error

      # Winner determines durable truth: switch win ends the Call, outsider
      # win preserves it.
      if match?({:ok, _}, switch_result) do
        assert %CallAttempt{state: :terminal, terminal_outcome: :ended} =
                 Repo.get!(CallAttempt, call_id)

        assert %{target: %Target{kind: :voice_channel, id: ^destination}} =
                 AdmissionCoordinator.current_identity(caller_id)

        assert AdmissionCoordinator.current_identity(recipient_id) == nil
        assert_no_call_sessions(call_id)
      else
        assert %CallAttempt{state: :active} = Repo.get!(CallAttempt, call_id)

        assert %{target: %Target{kind: :direct_call, id: ^call_id}} =
                 AdmissionCoordinator.current_identity(caller_id)

        assert %{target: %Target{kind: :direct_call, id: ^call_id}} =
                 AdmissionCoordinator.current_identity(recipient_id)

        assert %{target: %Target{kind: :voice_channel, id: ^destination}} =
                 AdmissionCoordinator.current_identity(outsider_id)
      end
    end
  end

  describe "concurrent switches share one credit" do
    test "second held switch for the same Call is rejected without double credit" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("vswitch_concurrent")

      # 18 unrelated slots; the active Call contributes 2 for 20 total.
      Enum.each(1..18, fn index ->
        assert {:ok, _} =
                 Voice.join(
                   Ecto.UUID.generate(),
                   Ecto.UUID.generate(),
                   "concurrent-fill-#{index}",
                   self()
                 )
      end)

      assert {:ok, %{call: ringing}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      assert {:ok, _} = Calls.accept_call(recipient_scope, ringing.call_id, :audio)
      assert eventually_active?(ringing.call_id)

      caller_id = caller_scope.user.id
      recipient_id = recipient_scope.user.id
      call_id = ringing.call_id
      coordinator = DiscordClone.Voice.SessionCoordinator

      destination_a = Ecto.UUID.generate()
      destination_b = Ecto.UUID.generate()

      assert {:ok, plan} =
               AdmissionCoordinator.begin_voice_switch(caller_id, destination_a)

      assert plan.call_id == call_id

      # The peer cannot hold a second switch over the same two exact Call
      # Sessions; otherwise `occupied_slots` would credit the pair twice.
      assert {:error, %{reason: :reservation_conflict}} =
               AdmissionCoordinator.begin_voice_switch(recipient_id, destination_b)

      # Call preserved for both while the first switch is held.
      assert %CallAttempt{state: :active} = Repo.get!(CallAttempt, call_id)

      assert %{target: %Target{kind: :direct_call, id: ^call_id}} =
               AdmissionCoordinator.current_identity(caller_id)

      assert %{target: %Target{kind: :direct_call, id: ^call_id}} =
               AdmissionCoordinator.current_identity(recipient_id)

      # Single credit only: 19 occupied, so exactly one unrelated join admits.
      extra_channel = Ecto.UUID.generate()
      extra_user = Ecto.UUID.generate()

      assert {:ok, _} = Voice.join(extra_channel, extra_user, "concurrent-one", self())

      assert {:error, %{reason: :deployment_full, occupancy: 20, capacity: 20}} =
               Voice.join(Ecto.UUID.generate(), Ecto.UUID.generate(), "concurrent-over", self())

      # Release the extra slot before testing peer begin; otherwise abort
      # leaves 21 active slots over capacity and the peer correctly gets
      # `deployment_full` under single-ledger accounting.
      assert :ok = Voice.end_user_session(extra_channel, extra_user)

      assert :ok = GenServer.call(coordinator, {:abort_voice_switch, caller_id, plan.generation})

      # After the first switch releases, the peer can begin its own switch.
      assert {:ok, peer_plan} =
               AdmissionCoordinator.begin_voice_switch(recipient_id, destination_b)

      assert peer_plan.call_id == call_id

      assert :ok =
               GenServer.call(
                 coordinator,
                 {:abort_voice_switch, recipient_id, peer_plan.generation}
               )
    end
  end

  # Shared polling helpers (`eventually_active?/2`, `poll_until/3`,
  # `flush_call_server/1`, `assert_no_call_sessions/1`) now live in
  # `DiscordClone.CallsFixtures` (imported above) to avoid a third copy.
  # Socket helpers stay per-file: they need the ChannelTest `connect/3`
  # context and endpoint.
  defp await_queued_command(server, command, deadline \\ nil) do
    server = if is_atom(server), do: Process.whereis(server), else: server
    deadline = deadline || System.monotonic_time(:millisecond) + 2_000
    {:messages, messages} = Process.info(server, :messages)

    queued? =
      Enum.any?(messages, fn
        {:"$gen_call", _from, queued} when is_tuple(queued) -> elem(queued, 0) == command
        {:"$gen_call", _from, ^command} -> true
        _ -> false
      end)

    cond do
      queued? ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("command was not queued")

      true ->
        :erlang.yield()
        await_queued_command(server, command, deadline)
    end
  end

  defp connect_calls_socket(user) do
    token = Accounts.generate_user_session_token(user)

    %{
      socket: connect_authenticated_calls_socket(token),
      token: token,
      scope: DiscordClone.Accounts.Scope.for_user(user)
    }
  end

  defp connect_authenticated_calls_socket(token) do
    assert {:ok, socket} =
             connect(DiscordCloneWeb.CallSocket, %{},
               connect_info: %{session: %{"user_token" => token}}
             )

    socket
  end

  defp create_voice_channel!(user, workspace_name) do
    scope = DiscordClone.Accounts.Scope.for_user(user)
    {:ok, workspace} = Workspaces.create_workspace(scope, %{name: workspace_name})
    {:ok, voice_channel} = Workspaces.create_voice_channel(scope, workspace.id, %{name: "lobby"})
    voice_channel
  end

  defp connect_voice_socket(user) do
    token = Accounts.generate_user_session_token(user)
    connect(VoiceSocket, %{}, connect_info: %{session: %{"user_token" => token}})
  end
end
