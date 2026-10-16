defmodule DiscordCloneWeb.DirectCallAudioStartTest do
  @moduledoc """
  Ticket 01 proof for audio caller preflight, server authorization, and no-media
  leakage. Channel and Calls suites remain the source of invitation lifecycle.
  """

  use DiscordClone.DataCase, async: false

  import DiscordClone.CallsFixtures

  alias DiscordClone.Calls
  alias DiscordClone.Calls.CallAttempt
  alias DiscordClone.Friendships
  alias DiscordClone.Repo
  alias DiscordClone.Voice
  alias DiscordCloneWeb.Router

  @production_js [
    "assets/js/call_devices.js",
    "assets/js/call_controller.js",
    "assets/js/call_cue_coordinator.js",
    "assets/js/call_cues.js",
    "assets/js/call_presenter.js",
    "assets/js/call_signaling.js",
    "assets/js/call_signaling_bootstrap.js",
    "assets/js/app.js"
  ]

  setup do
    start_supervised!(DiscordClone.Calls.Supervisor)
    DiscordClone.Calls.CallCoordinator.begin_recovery()
    await_recovery_finished()
    :ok
  end

  test "only the controlled device adapter may request microphone media; no browser transport yet" do
    for path <- @production_js do
      contents = File.read!(path)

      if path != "assets/js/call_devices.js" do
        refute contents =~ "getUserMedia", "#{path} leaked device-permission flow"
      end

      refute contents =~ "RTCPeerConnection", "#{path} leaked PeerConnection"
      refute contents =~ "RTCSessionDescription", "#{path} leaked SDP"
      refute contents =~ "addIceCandidate", "#{path} leaked ICE"
      refute contents =~ "MediaAdmissionCoordinator", "#{path} leaked pair admission"
    end
  end

  test "Direct Conversation stays in the existing authenticated live session with no call route" do
    routes = Router.__routes__()

    refute Enum.any?(routes, fn route -> String.contains?(route.path, "/call") end)

    direct_route =
      Enum.find(routes, fn route -> route.path == "/direct-messages/:direct_conversation_id" end)

    assert direct_route
    {_view, _action, _opts, live_session} = direct_route.metadata.phoenix_live_view
    assert live_session.name == :require_authenticated_user
  end

  test "forged former-Friend starts are rejected by server Friendship authorization" do
    {caller_scope, recipient_scope, direct_conversation, friendship} =
      direct_conversation_fixture("audio_forged")

    attempts_before = Repo.aggregate(CallAttempt, :count)
    assert :ok = Friendships.remove_friend(recipient_scope, friendship.id)

    assert {:error, :not_friends} =
             Calls.start_call(caller_scope, direct_conversation.id, :audio)

    assert Repo.aggregate(CallAttempt, :count) == attempts_before
  end

  test "a successful audio start creates a ringing attempt and leaves Voice occupancy unchanged" do
    {caller_scope, _recipient_scope, direct_conversation, _friendship} =
      direct_conversation_fixture("audio_voice")

    voice_channel_id = Ecto.UUID.generate()

    assert {:ok, %{voice_session_id: voice_session_id}} =
             Voice.join(voice_channel_id, caller_scope.user.id, "audio-voice", self())

    running_before = MapSet.new(ExWebRTC.PeerConnection.get_all_running())

    assert {:ok, %{call: call, started?: true}} =
             Calls.start_call(caller_scope, direct_conversation.id, :audio)

    assert call.state == :ringing
    assert call.media_intent == :audio

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
