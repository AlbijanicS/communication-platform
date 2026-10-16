defmodule DiscordClone.CallsPhase1BoundaryTest do
  @moduledoc """
  Phase 1 Completion Gate certification.

  Tickets 01–08 own the lifecycle rows. This module is the auditor surface:
  public-interface gaps, leakage, sensitive-data hygiene, constraint facts,
  and later-attempt safety that 01–08 left implicit. It does not clone
  `calls_test.exs`.

  Coverage map (Ticket 09 / PLAN.md required proof):

  Public authz matrix
    start unauthenticated / invalid intent / outsider / former-Friend —
      CallsTest start_call "rejects unauthenticated..."
    start malformed and missing Conversation IDs — this file
    decline/cancel unauthenticated / wrong-role / outsider / former-Friend / malformed —
      CallsTest decline_call and cancel_call authz tests
    get_call friends-only / unauthenticated — CallsTest get_call
    compact matrix across every public command, including empty Scope — this file
    busy / rate-limited / connecting cancel create no Activity or Message — this file

  Same-pair convergence — CallsTest start_call retry / simultaneous / cold occupancy
  Differently busy Users — CallsTest "returns busy when either User..."
  Both rate limits and window expiry — CallsTest rate-limit tests
  Offline timeout — CallsTest expire "times out an unanswered attempt for an offline recipient"
  Terminal idempotency — CallsTest repeated decline / cancel / expire
  Later-attempt safety after decline / cancel / timeout / prune —
    CallsTest later-Call-ID tests
  Later-attempt after interruption and after relationship_ended then re-friend —
    this file

  Failure injection
    Activity-insert rollback — CallsTest cancel/expire "rolls back the terminal write..."
    CallServer crash rebuild — CallsTest recovery "rebuilds a crashed CallServer..."
    Coordinator restart — CallsTest recovery coordinator restart
    Registry / Calls-subtree restart — CallsTest recovery rest_for_one and interrupted connecting
    start gated until recovery — CallsConcurrencyTest recovery gate
    prune overlapping a live terminal write — CallsConcurrencyTest SKIP LOCKED
    cancel after CallServer rebuild still exactly one Activity — this file

  Exactly-one missed-call Activity
    ringing cancel — CallsTest cancel_call
    ringing timeout — CallsTest expire_ringing_attempt
    across retries — CallsTest repeated cancel/expire
    across restarts — CallsTest overdue recovery expire; this file cancel-after-rebuild

  Zero Activity / Message
    decline, busy, rate limit, relationship end — CallsTest
    interruption — CallsTest recovery interrupted
    connecting cancel — CallsTest cancel connecting
    capacity rejection and accepted failure — absent public API (this file)

  Recovery + prune
    future reconstruct same Call ID / deadline — CallsTest recovery crash rebuild
    overdue expire — CallsTest recovery overdue
    terminals including pruned do not block a new Call ID — CallsTest prune later-attempt
    pruned row gone, Activity still navigates —
      CallsTest prune; ActivityLiveTest pruned missed-call item

  Leakage, hygiene, public surface, Voice preservation — this file
  Constraint inventory — uuid_baseline_test.exs plus this file
  """

  use DiscordClone.DataCase, async: false

  import DiscordClone.AccountsFixtures
  import DiscordClone.CallsFixtures
  import ExUnit.CaptureLog

  alias DiscordClone.Accounts.Scope
  alias DiscordClone.Calls
  alias DiscordClone.Calls.CallAttempt
  alias DiscordClone.Chat
  alias DiscordClone.Friendships
  alias DiscordClone.Repo
  alias DiscordClone.Voice

  @locked_projection_keys MapSet.new([
                            :call_id,
                            :direct_conversation_id,
                            :caller_user_id,
                            :recipient_user_id,
                            :media_intent,
                            :state,
                            :ringing_deadline_at,
                            :started_at,
                            :terminal_outcome,
                            :ended_at
                          ])

  @sensitive_fragments [
    "#PID",
    "#Reference",
    "application/sdp",
    "ice-pwd",
    "ice-ufrag",
    "a=candidate",
    "credential",
    "device_id",
    "signaling_session",
    "rtpmap",
    "m=audio",
    "m=video",
    "opus",
    "vp8"
  ]

  setup do
    start_supervised!(DiscordClone.Calls.Supervisor)
    DiscordClone.Calls.CallCoordinator.begin_recovery()
    await_recovery_finished()

    on_exit(fn ->
      DiscordClone.Voice.running_room_servers()
      |> Enum.each(fn {voice_channel_id, _room_server} ->
        :ok = Voice.end_channel_sessions(voice_channel_id)
        :ok = Voice.expire_idle_room(voice_channel_id)
      end)
    end)

    :ok
  end

  describe "public Calls surface" do
    test "documents the scoped invitation, lifecycle and owner-media discovery surface" do
      assert {:docs_v1, _, :elixir, _, _, _, docs} = Code.fetch_docs(Calls)

      visible =
        for {{:function, name, arity}, _, _, doc, _} <- docs,
            doc != :hidden,
            do: {name, arity}

      assert Enum.sort(visible) == [
               {:accept_call, 3},
               {:browser_media_capabilities, 1},
               {:cancel_call, 2},
               {:cancel_call, 3},
               {:current_call, 1},
               {:decline_call, 2},
               {:get_call, 2},
               {:leave_call, 2},
               {:leave_call, 3},
               {:media_credentials, 3},
               {:signal_media, 5},
               {:start_call, 3},
               {:subscribe, 1}
             ]

      assert MapSet.new(Calls.projection_keys()) == @locked_projection_keys

      refute function_exported?(Calls, :accept_call, 1)
      refute function_exported?(Calls, :accept_call, 2)
      refute function_exported?(Calls, :leave_call, 1)
      refute function_exported?(Calls, :prune_call, 0)
      refute function_exported?(Calls, :prune_call, 1)
    end

    test "capacity rejection and accepted-call failure are schema outcomes, not public commands" do
      assert :failed_capacity in CallAttempt.terminal_outcomes()
      assert :failed in CallAttempt.terminal_outcomes()
      refute function_exported?(Calls, :accept_call, 2)
      refute Code.ensure_loaded?(DiscordClone.Calls.MediaAdmissionCoordinator)
      refute Code.ensure_loaded?(DiscordClone.MediaAdmissionCoordinator)
    end
  end

  describe "public-command authorization matrix" do
    test "rejects unauthenticated, unauthorized, outsider, wrong-role, malformed, and former-Friend commands" do
      {caller_scope, recipient_scope, direct_conversation, friendship} =
        direct_conversation_fixture("p1b_auth")

      outsider_scope = user_scope_fixture(user_fixture(username: "p1b_auth_out"))
      empty_scope = %Scope{}
      missing_id = Ecto.UUID.generate()

      assert {:error, :unauthenticated} = Calls.subscribe(nil)
      assert {:error, :unauthenticated} = Calls.subscribe(empty_scope)
      assert {:error, :unauthenticated} = Calls.start_call(nil, direct_conversation.id, :audio)

      assert {:error, :unauthenticated} =
               Calls.start_call(empty_scope, direct_conversation.id, :audio)

      assert {:error, :unauthenticated} = Calls.get_call(nil, missing_id)
      assert {:error, :unauthenticated} = Calls.get_call(empty_scope, missing_id)
      assert {:error, :unauthenticated} = Calls.decline_call(nil, missing_id)
      assert {:error, :unauthenticated} = Calls.decline_call(empty_scope, missing_id)
      assert {:error, :unauthenticated} = Calls.cancel_call(nil, missing_id)
      assert {:error, :unauthenticated} = Calls.cancel_call(empty_scope, missing_id)

      assert {:error, :not_found} = Calls.start_call(caller_scope, "not-a-uuid", :audio)
      assert {:error, :not_found} = Calls.start_call(caller_scope, missing_id, :audio)

      assert {:error, :not_found} =
               Calls.start_call(outsider_scope, direct_conversation.id, :audio)

      assert {:error, :invalid_media_intent} =
               Calls.start_call(caller_scope, direct_conversation.id, :screen)

      assert {:ok, %{call: ringing, started?: true}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      assert {:error, :not_found} = Calls.get_call(caller_scope, "not-a-uuid")
      assert {:error, :not_found} = Calls.get_call(caller_scope, missing_id)
      assert {:error, :not_found} = Calls.get_call(outsider_scope, ringing.call_id)
      assert {:error, :not_found} = Calls.decline_call(recipient_scope, "not-a-uuid")
      assert {:error, :not_found} = Calls.decline_call(recipient_scope, missing_id)
      assert {:error, :not_found} = Calls.decline_call(caller_scope, ringing.call_id)
      assert {:error, :not_found} = Calls.decline_call(outsider_scope, ringing.call_id)
      assert {:error, :not_found} = Calls.cancel_call(caller_scope, "not-a-uuid")
      assert {:error, :not_found} = Calls.cancel_call(caller_scope, missing_id)
      assert {:error, :not_found} = Calls.cancel_call(recipient_scope, ringing.call_id)
      assert {:error, :not_found} = Calls.cancel_call(outsider_scope, ringing.call_id)

      assert {:ok, %{state: :ringing, call_id: call_id}} =
               Calls.get_call(caller_scope, ringing.call_id)

      assert call_id == ringing.call_id
      assert Repo.get!(CallAttempt, ringing.call_id).state == :ringing

      assert :ok = Friendships.remove_friend(caller_scope, friendship.id)
      ended = Repo.get!(CallAttempt, ringing.call_id)
      assert ended.terminal_outcome == :relationship_ended

      assert {:error, :not_found} = Calls.get_call(caller_scope, ringing.call_id)
      assert {:error, :not_found} = Calls.get_call(recipient_scope, ringing.call_id)
      assert {:error, :not_found} = Calls.decline_call(recipient_scope, ringing.call_id)
      assert {:error, :not_found} = Calls.cancel_call(caller_scope, ringing.call_id)

      assert {:error, :not_friends} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)
    end
  end

  describe "later-attempt safety" do
    test "an interrupted Call ID cannot mutate a later same-pair attempt" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("p1b_int")

      messages_before = Repo.aggregate(DiscordClone.Chat.Message, :count)

      assert {:ok, %{call: ringing}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      now = DateTime.utc_now(:microsecond)

      Repo.get!(CallAttempt, ringing.call_id)
      |> Ecto.Changeset.change(%{state: :connecting, accepted_at: now})
      |> Repo.update!()

      restart_calls_runtime()

      interrupted = Repo.get!(CallAttempt, ringing.call_id)
      assert interrupted.state == :terminal
      assert interrupted.terminal_outcome == :interrupted
      assert missed_call_activity_items(recipient_scope.user.id, ringing.call_id) == []
      assert Repo.aggregate(DiscordClone.Chat.Message, :count) == messages_before

      assert {:ok, %{call: later, started?: true}} =
               Calls.start_call(caller_scope, direct_conversation.id, :video)

      assert later.call_id != ringing.call_id
      assert later.state == :ringing
      %CallAttempt{updated_at: later_updated_at} = Repo.get!(CallAttempt, later.call_id)

      assert {:ok, retry} = Calls.cancel_call(caller_scope, ringing.call_id)
      assert retry.call_id == ringing.call_id
      assert retry.terminal_outcome == :interrupted
      assert retry.ended_at == interrupted.ended_at

      assert {:ok, still_ringing} = Calls.get_call(recipient_scope, later.call_id)
      assert still_ringing.call_id == later.call_id
      assert still_ringing.state == :ringing

      reloaded_later = Repo.get!(CallAttempt, later.call_id)
      assert reloaded_later.state == :ringing
      assert reloaded_later.updated_at == later_updated_at
      assert is_nil(reloaded_later.terminal_outcome)
      assert missed_call_activity_items(recipient_scope.user.id, later.call_id) == []
    end

    test "re-friended Users start a new Call ID after relationship_ended and cannot mutate the old one" do
      {caller_scope, recipient_scope, direct_conversation, friendship} =
        direct_conversation_fixture("p1b_rel")

      messages_before = Repo.aggregate(DiscordClone.Chat.Message, :count)

      assert {:ok, %{call: ringing}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      assert :ok = Friendships.remove_friend(caller_scope, friendship.id)

      ended = Repo.get!(CallAttempt, ringing.call_id)
      assert ended.terminal_outcome == :relationship_ended
      assert missed_call_activity_items(recipient_scope.user.id, ringing.call_id) == []
      assert Repo.aggregate(DiscordClone.Chat.Message, :count) == messages_before

      {reopened, _friendship} =
        befriend_and_open_direct_conversation(caller_scope, recipient_scope)

      assert reopened.id == direct_conversation.id

      assert {:ok, %{call: later, started?: true}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      assert later.call_id != ringing.call_id
      assert later.state == :ringing
      %CallAttempt{updated_at: later_updated_at} = Repo.get!(CallAttempt, later.call_id)

      assert {:ok, retry} = Calls.cancel_call(caller_scope, ringing.call_id)
      assert retry.call_id == ringing.call_id
      assert retry.terminal_outcome == :relationship_ended
      assert retry.ended_at == ended.ended_at

      assert {:ok, still_ringing} = Calls.get_call(recipient_scope, later.call_id)
      assert still_ringing.call_id == later.call_id
      assert still_ringing.state == :ringing

      reloaded_later = Repo.get!(CallAttempt, later.call_id)
      assert reloaded_later.state == :ringing
      assert reloaded_later.updated_at == later_updated_at
      assert missed_call_activity_items(recipient_scope.user.id, ringing.call_id) == []
      assert missed_call_activity_items(recipient_scope.user.id, later.call_id) == []
    end
  end

  describe "zero Activity and Messages for non-missed outcomes" do
    test "busy, rate-limited, and connecting cancel create no missed-call Activity or Message" do
      {alice_scope, bob_scope, alice_bob, _friendship} =
        direct_conversation_fixture("p1b_none")

      carol_scope = user_scope_fixture(user_fixture(username: "p1b_none_carol"))
      dave_scope = user_scope_fixture(user_fixture(username: "p1b_none_dave"))

      {alice_carol, _alice_carol_friendship} =
        befriend_and_open_direct_conversation(alice_scope, carol_scope)

      {alice_dave, _alice_dave_friendship} =
        befriend_and_open_direct_conversation(alice_scope, dave_scope)

      messages_before = Repo.aggregate(DiscordClone.Chat.Message, :count)
      activity_before = Repo.aggregate(DiscordClone.Activities.ActivityItem, :count)

      assert {:ok, %{call: ringing}} =
               Calls.start_call(alice_scope, alice_bob.id, :audio)

      assert {:error, :busy} = Calls.start_call(alice_scope, alice_carol.id, :audio)

      now = DateTime.utc_now(:microsecond)

      Repo.get!(CallAttempt, ringing.call_id)
      |> Ecto.Changeset.change(%{state: :connecting, accepted_at: now})
      |> Repo.update!()

      assert {:ok, cancelled} = Calls.cancel_call(alice_scope, ringing.call_id)
      assert cancelled.terminal_outcome == :cancelled
      assert missed_call_activity_items(bob_scope.user.id, ringing.call_id) == []

      for offset <- 0..4 do
        %CallAttempt{}
        |> Ecto.Changeset.change(%{
          direct_conversation_id: alice_dave.id,
          caller_user_id: alice_scope.user.id,
          recipient_user_id: dave_scope.user.id,
          media_intent: :audio,
          state: :terminal,
          ringing_deadline_at: DateTime.add(now, 30 - offset, :second),
          accepted_at: DateTime.add(now, -offset, :second),
          terminal_outcome: :ended,
          ended_at: DateTime.add(now, -offset, :second),
          inserted_at: DateTime.add(now, -offset, :second),
          updated_at: DateTime.add(now, -offset, :second)
        })
        |> Repo.insert!()
      end

      assert {:error, :rate_limited} = Calls.start_call(alice_scope, alice_dave.id, :audio)

      assert Repo.aggregate(DiscordClone.Chat.Message, :count) == messages_before
      assert Repo.aggregate(DiscordClone.Activities.ActivityItem, :count) == activity_before
      assert missed_call_activity_items(carol_scope.user.id, ringing.call_id) == []
      assert missed_call_activity_items(dave_scope.user.id, ringing.call_id) == []
    end
  end

  describe "exactly-once Activity across restart" do
    test "cancelling after a CallServer rebuild still creates exactly one missed-call Activity" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("p1b_cxl")

      messages_before = Repo.aggregate(DiscordClone.Chat.Message, :count)

      assert {:ok, %{call: ringing, started?: true}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      original_deadline = ringing.ringing_deadline_at
      [{old_pid, _}] = Registry.lookup(DiscordClone.Calls.CallRegistry, ringing.call_id)
      old_ref = Process.monitor(old_pid)

      :ok = DynamicSupervisor.terminate_child(DiscordClone.Calls.CallSupervisor, old_pid)
      assert_receive {:DOWN, ^old_ref, :process, ^old_pid, _reason}

      _new_pid = await_replaced_call_server(ringing.call_id, old_pid)
      assert_call_server_ready(ringing.call_id)

      assert {:ok, recovered} = Calls.get_call(caller_scope, ringing.call_id)
      assert recovered.call_id == ringing.call_id
      assert recovered.state == :ringing
      assert recovered.ringing_deadline_at == original_deadline

      assert {:ok, cancelled} = Calls.cancel_call(caller_scope, ringing.call_id)
      assert cancelled.terminal_outcome == :cancelled
      assert cancelled.ringing_deadline_at == original_deadline

      assert {:ok, retried} = Calls.cancel_call(caller_scope, ringing.call_id)
      assert retried.call_id == cancelled.call_id
      assert retried.ended_at == cancelled.ended_at
      assert retried.terminal_outcome == :cancelled

      assert [item] = missed_call_activity_items(recipient_scope.user.id, ringing.call_id)
      assert item.kind == "missed_direct_call"
      assert item.source_call_attempt_id == ringing.call_id
      refute_sensitive(item)
      assert Repo.aggregate(DiscordClone.Chat.Message, :count) == messages_before
    end
  end

  describe "sensitive-data hygiene" do
    test "projections, PubSub payloads, Activity rows, and normal logs omit prohibited data" do
      {caller_scope, recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("p1b_hyg")

      assert :ok = Calls.subscribe(caller_scope)
      assert :ok = Calls.subscribe(recipient_scope)

      previous_level = Logger.level()
      Logger.configure(level: :info)

      logs =
        try do
          capture_log(fn ->
            assert {:ok, %{call: ringing, started?: true}} =
                     Calls.start_call(caller_scope, direct_conversation.id, :audio)

            refute_sensitive_projection(ringing)

            assert_receive {:call_ringing, first_projection}
            assert_receive {:call_ringing, second_projection}
            refute_sensitive_projection(first_projection)
            refute_sensitive_projection(second_projection)

            assert {:ok, cancelled} = Calls.cancel_call(caller_scope, ringing.call_id)
            refute_sensitive_projection(cancelled)

            assert_receive {:call_cancelled, cancelled_projection}
            refute_sensitive_projection(cancelled_projection)

            [item] = missed_call_activity_items(recipient_scope.user.id, ringing.call_id)
            refute_sensitive(item)
            assert is_nil(item.source_message_id)
            assert is_binary(item.source_call_attempt_id)

            backdate_terminal_attempt!(
              cancelled.call_id,
              DateTime.add(DateTime.utc_now(:microsecond), -7, :day)
            )

            run_coordinator_prune()
            restart_calls_runtime()
          end)
        after
          Logger.configure(level: previous_level)
        end

      refute_sensitive(logs)
    end
  end

  describe "Voice isolation" do
    test "ringing does not join, leave, or allocate Direct Call PeerConnections" do
      {caller_scope, _recipient_scope, direct_conversation, _friendship} =
        direct_conversation_fixture("p1b_voice")

      voice_channel_id = Ecto.UUID.generate()

      assert {:ok, %{voice_session_id: voice_session_id}} =
               Voice.join(voice_channel_id, caller_scope.user.id, "p1b-voice", self())

      running_before =
        ExWebRTC.PeerConnection.get_all_running()
        |> MapSet.new()

      assert {:ok, %{call: call, started?: true}} =
               Calls.start_call(caller_scope, direct_conversation.id, :audio)

      assert call.state == :ringing

      assert {:ok, %{members: [%{user_id: caller_user_id}]}} =
               Voice.voice_channel_roster(voice_channel_id)

      assert caller_user_id == caller_scope.user.id

      assert ExWebRTC.PeerConnection.get_all_running()
             |> MapSet.new()
             |> MapSet.difference(running_before)
             |> MapSet.size() == 0

      assert :ok = Voice.leave(voice_channel_id, voice_session_id)
    end
  end

  describe "leakage audit" do
    test "Endpoint keeps /live, /voice, and authenticated /calls" do
      sockets = DiscordCloneWeb.Endpoint.__sockets__()
      paths = Enum.map(sockets, fn {path, _module, _opts} -> path end)
      modules = Enum.map(sockets, fn {_path, module, _opts} -> module end)

      assert "/live" in paths
      assert "/voice" in paths
      assert "/calls" in paths
      assert DiscordCloneWeb.VoiceSocket in modules
      assert DiscordCloneWeb.CallSocket in modules
    end

    test "router keeps Direct Conversation in the authenticated live session and adds no call routes" do
      routes = DiscordCloneWeb.Router.__routes__()

      refute Enum.any?(routes, fn route ->
               String.contains?(route.path, "/call")
             end)

      live_modules =
        for %{metadata: %{phoenix_live_view: {view, _action, _opts, _session}}} <- routes,
            do: view

      refute Enum.any?(live_modules, fn module ->
               module
               |> Module.split()
               |> Enum.any?(&String.contains?(&1, "Call"))
             end)

      direct_route =
        Enum.find(routes, fn route ->
          route.path == "/direct-messages/:direct_conversation_id"
        end)

      activity_route = Enum.find(routes, fn route -> route.path == "/activity" end)

      assert direct_route
      assert activity_route

      {_view, _action, _opts, live_session} = direct_route.metadata.phoenix_live_view
      assert live_session.name == :require_authenticated_user

      {_activity_view, _activity_action, _activity_opts, activity_session} =
        activity_route.metadata.phoenix_live_view

      assert activity_session.name == :require_authenticated_user

      live_session_names =
        routes
        |> Enum.map(&live_session_name/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
        |> Enum.sort()

      assert live_session_names == [:current_user, :require_authenticated_user]
    end

    test "Calls runtime and non-Voice web sources do not introduce Direct Call media" do
      phase1_paths =
        ["lib/discord_clone/calls.ex"] ++
          Path.wildcard("lib/discord_clone/calls/**/*.ex") ++
          non_voice_web_sources()

      for path <- phase1_paths do
        contents = File.read!(path)
        refute_calls_media_leakage(path, contents)
      end

      lib_paths = Path.wildcard("lib/**/*.{ex,heex}")

      sources_with_accept =
        Enum.filter(lib_paths, fn path -> File.read!(path) =~ ~r/\baccept_call\b/ end)

      sources_with_leave =
        Enum.filter(lib_paths, fn path -> File.read!(path) =~ ~r/\bleave_call\b/ end)

      allowed_command_sources =
        Enum.sort([
          "lib/discord_clone/calls.ex",
          "lib/discord_clone_web/call_channel.ex",
          "lib/discord_clone_web/call_signaling.ex",
          "lib/discord_clone_web/call_signaling/diagnostics.ex"
        ])

      assert Enum.sort(sources_with_accept) == allowed_command_sources

      assert Enum.sort(sources_with_leave) ==
               Enum.sort(["lib/discord_clone/calls/call_server.ex" | allowed_command_sources])

      for path <- lib_paths do
        contents = File.read!(path)
        refute contents =~ "CallLive", "#{path} leaked call LiveView"
        refute contents =~ "CallControls", "#{path} leaked call controls"

        refute contents =~ "MediaAdmissionCoordinator",
               "#{path} leaked Media AdmissionCoordinator"

        refute contents =~ "getUserMedia", "#{path} leaked device-permission flow"
        refute contents =~ "shared-media", "#{path} leaked shared-media extraction"
      end

      assert File.exists?("lib/discord_clone_web/voice_socket.ex")
      assert File.exists?("lib/discord_clone/voice/peer_connection.ex")
      assert Code.ensure_loaded?(DiscordCloneWeb.VoiceSocket)
      assert Code.ensure_loaded?(ExWebRTC.PeerConnection)
      assert Code.ensure_loaded?(DiscordClone.Voice.PeerConnection)
    end
  end

  describe "constraint inventory" do
    test "missed-call Activity has an opaque source Call ID with no FK and the recovery/pruning indexes exist" do
      %{rows: indexes} =
        Ecto.Adapters.SQL.query!(
          Repo,
          """
          SELECT indexname
          FROM pg_indexes
          WHERE schemaname = 'public'
            AND indexname = ANY($1)
          """,
          [
            [
              "activity_items_recipient_source_call_attempt_kind_index",
              "call_attempts_ringing_deadline_index",
              "call_attempts_terminal_pruning_index",
              "call_attempts_one_nonterminal_per_direct_conversation_index"
            ]
          ]
        )

      assert MapSet.new(indexes, fn [name] -> name end) ==
               MapSet.new([
                 "activity_items_recipient_source_call_attempt_kind_index",
                 "call_attempts_ringing_deadline_index",
                 "call_attempts_terminal_pruning_index",
                 "call_attempts_one_nonterminal_per_direct_conversation_index"
               ])

      %{rows: foreign_keys} =
        Ecto.Adapters.SQL.query!(
          Repo,
          """
          SELECT con.conname
          FROM pg_constraint con
          JOIN pg_attribute source_attribute
            ON source_attribute.attrelid = con.conrelid
           AND source_attribute.attnum = con.conkey[1]
          WHERE con.contype = 'f'
            AND con.conrelid = 'activity_items'::regclass
            AND source_attribute.attname = 'source_call_attempt_id'
          """,
          []
        )

      assert foreign_keys == []
    end
  end

  defp befriend_and_open_direct_conversation(scope, other_scope) do
    assert {:ok, %{relationship: request}} =
             Friendships.send_friend_request(scope, %{username: other_scope.user.username})

    assert {:ok, friendship} = Friendships.accept_friend_request(other_scope, request.id)

    assert {:ok, direct_conversation} =
             Chat.open_direct_conversation(scope, other_scope.user.id)

    {direct_conversation, friendship}
  end

  defp restart_calls_runtime do
    stop_supervised!(DiscordClone.Calls.Supervisor)
    start_supervised!(DiscordClone.Calls.Supervisor)
    DiscordClone.Calls.CallCoordinator.begin_recovery()
    await_recovery_finished()
    :ok
  end

  defp await_replaced_call_server(call_id, old_pid) do
    deadline = System.monotonic_time(:millisecond) + 1_000
    await_replaced_call_server(call_id, old_pid, deadline)
  end

  defp await_replaced_call_server(call_id, old_pid, deadline) do
    case Process.whereis(DiscordClone.Calls.CallCoordinator) do
      pid when is_pid(pid) -> _ = safe_sys_state(pid)
      nil -> :ok
    end

    case safe_registry_lookup(call_id) do
      {:ok, [{pid, _value}]} when pid != old_pid ->
        assert :ok = DiscordClone.Calls.CallServer.await_ready(call_id)
        pid

      _missing_or_same ->
        retry_until(deadline, "expected CallServer for #{call_id} to be rebuilt", fn ->
          await_replaced_call_server(call_id, old_pid, deadline)
        end)
    end
  end

  defp assert_call_server_ready(call_id) do
    assert [{pid, _value}] = Registry.lookup(DiscordClone.Calls.CallRegistry, call_id)
    assert :ok = DiscordClone.Calls.CallServer.await_ready(call_id)

    assert %{call_attempt: %CallAttempt{id: ^call_id}, ringing_timer_ref: timer_ref} =
             :sys.get_state(pid)

    assert is_reference(timer_ref)
  end

  defp safe_sys_state(pid) do
    {:ok, :sys.get_state(pid)}
  catch
    :exit, _reason -> :error
  end

  defp safe_registry_lookup(call_id) do
    {:ok, Registry.lookup(DiscordClone.Calls.CallRegistry, call_id)}
  catch
    :exit, _reason -> :error
    :error, _reason -> :error
  end

  defp retry_until(deadline, message, fun) do
    if System.monotonic_time(:millisecond) < deadline do
      :erlang.yield()
      fun.()
    else
      flunk(message)
    end
  end

  defp refute_sensitive_projection(projection) when is_map(projection) do
    assert MapSet.new(Map.keys(projection)) == @locked_projection_keys
    refute_sensitive(projection)
  end

  defp refute_sensitive(value) do
    text = inspect(value, limit: :infinity, pretty: false)

    for fragment <- @sensitive_fragments do
      refute String.contains?(text, fragment)
    end

    downcased = String.downcase(text)
    refute downcased =~ "application/sdp"
    refute downcased =~ ~r/\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b/
  end

  defp live_session_name(%{metadata: %{phoenix_live_view: {_view, _action, _opts, session}}}) do
    session.name
  end

  defp live_session_name(_route), do: nil

  defp non_voice_web_sources do
    Path.wildcard("lib/discord_clone_web/**/*.{ex,heex}")
    |> Enum.reject(fn path ->
      String.contains?(path, "/voice_socket") or
        String.contains?(path, "/voice_channel") or
        String.contains?(path, "/voice_signaling")
    end)
  end

  defp refute_calls_media_leakage(path, contents) do
    refute contents =~ "CallLive", "#{path} leaked call LiveView"
    refute contents =~ "CallControls", "#{path} leaked call controls"

    refute contents =~ "MediaAdmissionCoordinator",
           "#{path} leaked Media AdmissionCoordinator"

    refute contents =~ "getUserMedia", "#{path} leaked device-permission flow"
    refute contents =~ "shared-media", "#{path} leaked shared-media extraction"
    refute contents =~ "ExWebRTC", "#{path} leaked ExWebRTC"
    refute contents =~ "PeerConnection", "#{path} leaked PeerConnection"
    refute contents =~ ":gen_udp", "#{path} leaked UDP allocation"
    refute contents =~ ~r/\bRTP\b/, "#{path} leaked RTP"
  end
end
