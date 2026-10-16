defmodule DiscordCloneWeb.VoiceChannelTest do
  use DiscordClone.DataCase, async: false

  import DiscordClone.AccountsFixtures
  import DiscordClone.VoiceICEConfigurationHelpers
  import ExUnit.CaptureLog
  import Phoenix.ChannelTest

  alias DiscordClone.Accounts
  alias DiscordClone.Voice

  alias DiscordClone.Voice.{
    FakeICEProvider,
    Forwarder,
    RoomServer,
    SessionSupervisor
  }

  alias DiscordClone.Workspaces
  alias DiscordClone.Workspaces.VoiceChannel, as: VoiceChannelSchema
  alias DiscordClone.Workspaces.WorkspaceMembership
  alias DiscordCloneWeb.{VoiceChannel, VoiceSocket}
  import DiscordCloneWeb.VoiceSignalingHelpers

  @endpoint DiscordCloneWeb.Endpoint

  describe "authenticated Voice Channel negotiation" do
    setup do
      user = user_fixture()
      voice_channel = create_voice_channel!(user, "Voice negotiation")

      token = Accounts.generate_user_session_token(user)

      {:ok, socket} =
        connect(VoiceSocket, %{}, connect_info: %{session: %{"user_token" => token}})

      {:ok, join_payload, channel_socket} =
        subscribe_and_join(
          socket,
          VoiceChannel,
          "voice:#{voice_channel.id}",
          admission_params()
        )

      %{
        channel_socket: channel_socket,
        join_payload: join_payload,
        signaling_session_id: join_payload.signaling_session_id,
        voice_session_id: channel_socket.assigns.voice_session_id,
        voice_channel_id: voice_channel.id
      }
    end

    test "returns only opaque signaling identity and the safe disabled browser projection",
         context do
      %{join_payload: join_payload, signaling_session_id: signaling_session_id} = context

      assert %{
               signaling_session_id: ^signaling_session_id,
               occupancy: 1,
               capacity: 5,
               ice_config: %{ice_mode: "disabled", ice_servers: [], ice_transport_policy: "all"}
             } = join_payload

      refute Map.has_key?(join_payload, :voice_session_id)

      assert Map.keys(join_payload) |> Enum.sort() == [
               :capacity,
               :ice_config,
               :occupancy,
               :signaling_session_id
             ]

      assert Map.keys(join_payload.ice_config) |> Enum.sort() == [
               :ice_mode,
               :ice_servers,
               :ice_transport_policy
             ]
    end

    test "accepts only a bounded correlated browser ICE route diagnostic", context do
      test_process = self()
      handler_id = "ticket-07-browser-route-#{System.unique_integer()}"

      :ok =
        :telemetry.attach(
          handler_id,
          [:discord_clone, :voice_signaling, :operation],
          fn _event, measurements, metadata, _config ->
            send(test_process, {:ice_route_diagnostic, measurements, metadata})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      diagnostic = %{
        "signaling_session_id" => context.signaling_session_id,
        "route_category" => "reflexive_direct",
        "protocol" => "udp",
        "duration_ms" => 7
      }

      assert_reply push(context.channel_socket, "ice_route", diagnostic), :ok

      assert_receive {:ice_route_diagnostic, %{duration_ms: 7}, metadata}

      assert metadata == %{
               endpoint: :browser,
               ice_mode: :disabled,
               operation: "ice_route",
               outcome: :accepted,
               protocol: :udp,
               route_category: :reflexive_direct
             }

      forbidden = Map.put(diagnostic, "address", "forbidden-address-and-identity")

      assert_reply push(context.channel_socket, "ice_route", forbidden), :error, %{
        reason: "invalid_request"
      }

      assert_receive {:ice_route_diagnostic, %{duration_ms: 0}, rejected_metadata}

      assert rejected_metadata == %{
               endpoint: :browser,
               error_code: :invalid_request,
               ice_mode: :disabled,
               operation: "ice_route",
               outcome: :rejected,
               protocol: :unknown,
               route_category: :unknown
             }

      refute inspect(rejected_metadata) =~ "forbidden-address-and-identity"
    end

    test "updates the active Voice Session's Local Mute and Local Deafen state", context do
      %{
        channel_socket: channel_socket,
        voice_channel_id: voice_channel_id
      } = context

      assert_reply push(channel_socket, "local_voice_state", %{muted: false, deafened: true}), :ok

      assert {:ok,
              %{
                voice_channel_id: ^voice_channel_id,
                members: [%{muted: true, deafened: true}]
              }} = Voice.voice_channel_roster(voice_channel_id)

      assert_reply push(channel_socket, "local_voice_state", %{muted: true, deafened: false}), :ok

      assert {:ok, %{members: [%{muted: true, deafened: false}]}} =
               Voice.voice_channel_roster(voice_channel_id)
    end

    test "renews only the current authenticated Voice Session", context do
      %{channel_socket: channel_socket, signaling_session_id: signaling_session_id} = context

      assert_reply push(channel_socket, "renew", %{"signaling_session_id" => signaling_session_id}),
                   :ok,
                   %{signaling_session_id: ^signaling_session_id}

      assert_reply push(channel_socket, "renew", %{"signaling_session_id" => "stale-session"}),
                   :error,
                   %{reason: "invalid_request"}
    end

    test "projects an intentional Voice Session end as opaque current-attempt correlation",
         context do
      %{
        channel_socket: channel_socket,
        voice_session_id: voice_session_id,
        signaling_session_id: signaling_session_id,
        voice_channel_id: voice_channel_id
      } = context

      user_id = channel_socket.assigns.current_scope.user.id

      assert :ok = Voice.end_user_session(voice_channel_id, user_id)

      assert_push "voice_session_ended", %{signaling_session_id: ^signaling_session_id} = payload
      assert payload == %{signaling_session_id: signaling_session_id}

      assert {:ok, %{occupancy: 0, capacity: 5}} = Voice.room_occupancy(voice_channel_id)

      assert {:error, :not_found} =
               Voice.dispatch_test_ex_webrtc(voice_channel_id, voice_session_id, :late)
    end

    test "rejects renewal from a Channel whose Voice Session was replaced", context do
      %{
        channel_socket: channel_socket,
        voice_session_id: original_voice_session_id,
        signaling_session_id: signaling_session_id,
        voice_channel_id: voice_channel_id
      } = context

      user_id = channel_socket.assigns.current_scope.user.id

      assert {:ok, %{voice_session_id: replacement_voice_session_id}} =
               Voice.join(voice_channel_id, user_id, "replacement-signaling-session", self())

      refute replacement_voice_session_id == original_voice_session_id

      assert_reply push(channel_socket, "renew", %{"signaling_session_id" => signaling_session_id}),
                   :error,
                   %{reason: "invalid_session"}
    end

    test "returns a correlated real answer and sends server ICE only to its connection",
         context do
      %{channel_socket: channel_socket, signaling_session_id: signaling_session_id} = context

      negotiation_id = "first-negotiation"

      offer_ref = push(channel_socket, "offer", offer(signaling_session_id, negotiation_id))

      assert_reply offer_ref, :ok, reply

      assert %{
               signaling_session_id: ^signaling_session_id,
               negotiation_id: ^negotiation_id,
               description: %{"type" => "answer", "sdp" => answer_sdp}
             } = reply

      assert Map.keys(reply) |> Enum.sort() == [
               :description,
               :negotiation_id,
               :signaling_session_id
             ]

      assert is_binary(answer_sdp)
      assert byte_size(answer_sdp) > 0

      assert_server_ice_gathering(signaling_session_id, negotiation_id)
    end

    test "rejects mismatched, duplicate, malformed, and oversized offers safely", context do
      %{channel_socket: channel_socket, signaling_session_id: signaling_session_id} = context
      valid_offer = offer(signaling_session_id, "first-negotiation")

      assert_reply push(
                     channel_socket,
                     "offer",
                     put_in(valid_offer["signaling_session_id"], "wrong")
                   ),
                   :error,
                   %{reason: "invalid_request"}

      assert_reply push(channel_socket, "offer", %{"signaling_session_id" => signaling_session_id}),
                   :error,
                   %{reason: "invalid_negotiation"}

      oversized_offer = %{
        "signaling_session_id" => signaling_session_id,
        "negotiation_id" => "oversized",
        "description" => %{"type" => "offer", "sdp" => String.duplicate("x", 64 * 1024 + 1)}
      }

      assert_reply push(channel_socket, "offer", oversized_offer), :error, %{
        reason: "description_too_large"
      }

      assert_reply push(channel_socket, "offer", valid_offer), :ok

      assert_reply push(
                     channel_socket,
                     "offer",
                     put_in(valid_offer["negotiation_id"], "another")
                   ),
                   :error,
                   %{reason: "negotiation_already_active"}
    end

    test "closes an incompatible media offer without exposing its description", context do
      %{channel_socket: channel_socket, signaling_session_id: signaling_session_id} = context

      incompatible_offer =
        offer(signaling_session_id, "first-negotiation")
        |> update_in(["description", "sdp"], &String.replace(&1, "opus/48000/2", "ISAC/16000"))

      Process.unlink(channel_socket.channel_pid)
      monitor_ref = Process.monitor(channel_socket.channel_pid)

      assert_reply push(channel_socket, "offer", incompatible_offer), :error, %{
        reason: "negotiation_failed"
      }

      assert_receive {:DOWN, ^monitor_ref, :process, _, :normal}
    end

    test "reports a retryable four-slot compatibility failure and removes the attempted Session",
         context do
      %{
        channel_socket: channel_socket,
        signaling_session_id: signaling_session_id,
        voice_channel_id: voice_channel_id
      } = context

      incomplete_offer = %{
        "signaling_session_id" => signaling_session_id,
        "negotiation_id" => "first-negotiation",
        "description" => browser_offer(3)
      }

      Process.unlink(channel_socket.channel_pid)
      monitor_ref = Process.monitor(channel_socket.channel_pid)

      assert_reply push(channel_socket, "offer", incomplete_offer), :error, %{
        reason: "incompatible_audio_output_slots"
      }

      assert_receive {:DOWN, ^monitor_ref, :process, _, :normal}
      assert :ok = Voice.await_empty_room(voice_channel_id)
      assert {:ok, %{occupancy: 0, capacity: 5}} = Voice.room_occupancy(voice_channel_id)
    end

    test "rejects client ICE from a stale Signaling Session", context do
      %{channel_socket: channel_socket, signaling_session_id: signaling_session_id} = context
      negotiation_id = "first-negotiation"
      assert_reply push(channel_socket, "offer", offer(signaling_session_id, negotiation_id)), :ok

      assert_reply(
        push(channel_socket, "ice_candidate", %{
          "signaling_session_id" => "stale-signaling-session",
          "negotiation_id" => negotiation_id,
          "candidate" => candidate()
        }),
        :error,
        %{reason: "invalid_request"}
      )
    end

    test "rejects malformed client ICE at the Channel boundary", context do
      %{channel_socket: channel_socket, signaling_session_id: signaling_session_id} = context
      negotiation_id = "first-negotiation"

      assert_reply(
        push(channel_socket, "ice_candidate", %{
          "signaling_session_id" => signaling_session_id,
          "negotiation_id" => negotiation_id,
          "candidate" => Map.delete(candidate(), "sdpMid")
        }),
        :error,
        %{reason: "invalid_candidate"}
      )
    end

    test "rejects client ICE from a stale Negotiation", context do
      %{channel_socket: channel_socket, signaling_session_id: signaling_session_id} = context
      negotiation_id = "first-negotiation"
      assert_reply push(channel_socket, "offer", offer(signaling_session_id, negotiation_id)), :ok

      assert_reply(
        push(channel_socket, "ice_candidate", %{
          "signaling_session_id" => signaling_session_id,
          "negotiation_id" => "stale-negotiation",
          "candidate" => candidate()
        }),
        :error,
        %{reason: "invalid_negotiation"}
      )
    end

    test "rejects oversized client ICE at the Channel boundary", context do
      %{channel_socket: channel_socket, signaling_session_id: signaling_session_id} = context
      negotiation_id = "first-negotiation"

      assert_reply(
        push(channel_socket, "ice_candidate", %{
          "signaling_session_id" => signaling_session_id,
          "negotiation_id" => negotiation_id,
          "candidate" => Map.put(candidate(), "candidate", String.duplicate("x", 8 * 1024 + 1))
        }),
        :error,
        %{reason: "candidate_too_large"}
      )
    end

    test "buffers a bounded early ICE candidate until its offer is accepted", context do
      %{channel_socket: channel_socket, signaling_session_id: signaling_session_id} = context
      negotiation_id = "first-negotiation"

      assert_reply(
        push(channel_socket, "ice_candidate", %{
          "signaling_session_id" => signaling_session_id,
          "negotiation_id" => negotiation_id,
          "candidate" => candidate()
        }),
        :ok,
        %{negotiation_id: ^negotiation_id}
      )

      assert_reply push(channel_socket, "offer", offer(signaling_session_id, negotiation_id)), :ok
    end

    test "rejects a seventeenth early ICE candidate before the offer", context do
      %{channel_socket: channel_socket, signaling_session_id: signaling_session_id} = context
      negotiation_id = "first-negotiation"

      for number <- 1..16 do
        assert_reply(
          push(channel_socket, "ice_candidate", %{
            "signaling_session_id" => signaling_session_id,
            "negotiation_id" => negotiation_id,
            "candidate" =>
              Map.put(
                candidate(),
                "candidate",
                "candidate:#{number} 1 udp 1 127.0.0.1 9 typ host"
              )
          }),
          :ok,
          %{negotiation_id: ^negotiation_id}
        )
      end

      assert_reply(
        push(channel_socket, "ice_candidate", %{
          "signaling_session_id" => signaling_session_id,
          "negotiation_id" => negotiation_id,
          "candidate" => candidate()
        }),
        :error,
        %{reason: "pending_candidate_limit_reached"}
      )
    end

    test "bounds early ICE by total decoded candidate bytes before the count limit", context do
      %{channel_socket: channel_socket, signaling_session_id: signaling_session_id} = context
      negotiation_id = "first-negotiation"

      # Edge validation sees 8,177 bytes. Runtime normalization adds usernameFragment,
      # making each queued candidate 8,201 bytes and the sixteenth exceed 16 * 8 KiB.
      near_limit_candidate =
        candidate()
        |> Map.put("candidate", String.duplicate("x", 8_130))

      for _number <- 1..15 do
        assert_reply(
          push(channel_socket, "ice_candidate", %{
            "signaling_session_id" => signaling_session_id,
            "negotiation_id" => negotiation_id,
            "candidate" => near_limit_candidate
          }),
          :ok,
          %{negotiation_id: ^negotiation_id}
        )
      end

      assert_reply(
        push(channel_socket, "ice_candidate", %{
          "signaling_session_id" => signaling_session_id,
          "negotiation_id" => negotiation_id,
          "candidate" => near_limit_candidate
        }),
        :error,
        %{reason: "pending_candidate_limit_reached"}
      )
    end

    test "rejects the sixty-fifth accepted ICE candidate", context do
      %{channel_socket: channel_socket, signaling_session_id: signaling_session_id} = context
      negotiation_id = "first-negotiation"
      assert_reply push(channel_socket, "offer", offer(signaling_session_id, negotiation_id)), :ok

      for number <- 1..64 do
        assert_reply(
          push(channel_socket, "ice_candidate", %{
            "signaling_session_id" => signaling_session_id,
            "negotiation_id" => negotiation_id,
            "candidate" =>
              Map.put(
                candidate(),
                "candidate",
                "candidate:#{number} 1 udp 1 127.0.0.1 9 typ host"
              )
          }),
          :ok,
          %{negotiation_id: ^negotiation_id}
        )
      end

      assert_reply(
        push(channel_socket, "ice_candidate", %{
          "signaling_session_id" => signaling_session_id,
          "negotiation_id" => negotiation_id,
          "candidate" => candidate()
        }),
        :error,
        %{reason: "candidate_limit_reached"}
      )
    end

    test "keeps server ICE events isolated between two joined connections",
         context do
      %{
        channel_socket: first_channel_socket,
        signaling_session_id: first_signaling_session_id,
        voice_session_id: first_voice_session_id,
        voice_channel_id: voice_channel_id
      } = context

      [first_peer_connection] = ExWebRTC.PeerConnection.get_all_running()

      second_user = user_fixture()
      add_workspace_member!(voice_channel_id, second_user)
      {:ok, second_socket} = connect_voice_socket(second_user)

      assert {:ok, %{signaling_session_id: second_signaling_session_id} = second_payload,
              second_channel_socket} =
               subscribe_and_join(
                 second_socket,
                 VoiceChannel,
                 first_channel_socket.topic,
                 admission_params()
               )

      second_voice_session_id = second_channel_socket.assigns.voice_session_id
      refute Map.has_key?(second_payload, :voice_session_id)
      refute first_signaling_session_id == second_signaling_session_id

      [second_peer_connection] =
        ExWebRTC.PeerConnection.get_all_running() -- [first_peer_connection]

      negotiation_id = "shared-negotiation"

      assert_reply push(
                     first_channel_socket,
                     "offer",
                     offer(first_signaling_session_id, negotiation_id)
                   ),
                   :ok

      assert_server_ice_gathering(first_signaling_session_id, negotiation_id)

      assert_reply push(
                     second_channel_socket,
                     "offer",
                     offer(second_signaling_session_id, negotiation_id)
                   ),
                   :ok

      assert_server_ice_gathering(second_signaling_session_id, negotiation_id)

      first_candidate_value = "candidate:101 1 udp 1 127.0.0.1 10001 typ host"

      assert :ok =
               Voice.dispatch_test_ex_webrtc(
                 voice_channel_id,
                 first_voice_session_id,
                 {:ex_webrtc, first_peer_connection,
                  {:ice_candidate, server_candidate(first_candidate_value)}}
               )

      assert_push "ice_candidate", %{
        signaling_session_id: ^first_signaling_session_id,
        negotiation_id: ^negotiation_id,
        candidate: %{"candidate" => ^first_candidate_value}
      }

      refute_push "ice_candidate", %{
        signaling_session_id: ^second_signaling_session_id,
        candidate: %{"candidate" => ^first_candidate_value}
      }

      second_candidate_value = "candidate:202 1 udp 1 127.0.0.1 10002 typ host"

      assert :ok =
               Voice.dispatch_test_ex_webrtc(
                 voice_channel_id,
                 second_voice_session_id,
                 {:ex_webrtc, second_peer_connection,
                  {:ice_candidate, server_candidate(second_candidate_value)}}
               )

      assert_push "ice_candidate", %{
        signaling_session_id: ^second_signaling_session_id,
        negotiation_id: ^negotiation_id,
        candidate: %{"candidate" => ^second_candidate_value}
      }

      refute_push "ice_candidate", %{
        signaling_session_id: ^first_signaling_session_id,
        candidate: %{"candidate" => ^second_candidate_value}
      }

      assert :ok =
               Voice.dispatch_test_ex_webrtc(
                 voice_channel_id,
                 first_voice_session_id,
                 {:ex_webrtc, first_peer_connection, {:ice_gathering_state_change, :complete}}
               )

      assert_push "ice_candidate", %{
        signaling_session_id: ^first_signaling_session_id,
        negotiation_id: ^negotiation_id,
        end_of_candidates: true
      }

      refute_push "ice_candidate", %{
        signaling_session_id: ^second_signaling_session_id,
        end_of_candidates: true
      }

      assert :ok =
               Voice.dispatch_test_ex_webrtc(
                 voice_channel_id,
                 second_voice_session_id,
                 {:ex_webrtc, second_peer_connection, {:ice_gathering_state_change, :complete}}
               )

      assert_push "ice_candidate", %{
        signaling_session_id: ^second_signaling_session_id,
        negotiation_id: ^negotiation_id,
        end_of_candidates: true
      }

      refute_push "ice_candidate", %{
        signaling_session_id: ^first_signaling_session_id,
        end_of_candidates: true
      }
    end

    test "sends join and leave cues only to existing Voice Owner Tabs", context do
      %{channel_socket: first_channel_socket, voice_channel_id: voice_channel_id} = context

      second_user = user_fixture()
      add_workspace_member!(voice_channel_id, second_user)
      {:ok, second_socket} = connect_voice_socket(second_user)

      assert {:ok, _join_payload, second_channel_socket} =
               subscribe_and_join(
                 second_socket,
                 VoiceChannel,
                 first_channel_socket.topic,
                 admission_params()
               )

      assert_push "voice_roster_cue", %{channel_id: ^voice_channel_id, cue: "join"}

      Process.unlink(second_channel_socket.channel_pid)
      assert_reply leave(second_channel_socket), :ok
      assert_push "voice_roster_cue", %{channel_id: ^voice_channel_id, cue: "leave"}
    end

    test "ignores stale Voice Session and Negotiation events before serializing server ICE",
         context do
      %{
        channel_socket: channel_socket,
        signaling_session_id: signaling_session_id,
        voice_session_id: voice_session_id
      } = context

      negotiation_id = "current-negotiation"
      assert_reply push(channel_socket, "offer", offer(signaling_session_id, negotiation_id)), :ok
      assert_push "ice_candidate", %{signaling_session_id: ^signaling_session_id}

      assert_push "ice_candidate", %{
        signaling_session_id: ^signaling_session_id,
        end_of_candidates: true
      }

      stale_session_candidate = %{"candidate" => "stale-session-candidate"}
      stale_negotiation_candidate = %{"candidate" => "stale-negotiation-candidate"}

      send(
        channel_socket.channel_pid,
        {:voice_session_event, Ecto.UUID.generate(),
         {:ice_candidate, negotiation_id, stale_session_candidate}}
      )

      send(
        channel_socket.channel_pid,
        {:voice_session_event, voice_session_id,
         {:ice_candidate, "stale-negotiation", stale_negotiation_candidate}}
      )

      send(
        channel_socket.channel_pid,
        {:voice_session_event, voice_session_id, {:end_of_candidates, "stale-negotiation"}}
      )

      _ = :sys.get_state(channel_socket.channel_pid)

      refute_push "ice_candidate", %{candidate: ^stale_session_candidate}
      refute_push "ice_candidate", %{candidate: ^stale_negotiation_candidate}
      refute_push "ice_candidate", %{negotiation_id: "stale-negotiation"}

      current_candidate = %{"candidate" => "current-candidate"}

      send(
        channel_socket.channel_pid,
        {:voice_session_event, voice_session_id,
         {:ice_candidate, negotiation_id, current_candidate}}
      )

      assert_push "ice_candidate", %{
        signaling_session_id: ^signaling_session_id,
        negotiation_id: ^negotiation_id,
        candidate: ^current_candidate
      }
    end

    test "stops the Session-owned peer connection when the topic leaves", context do
      %{channel_socket: channel_socket} = context
      running_before_leave = ExWebRTC.PeerConnection.get_all_running()

      assert Enum.any?(running_before_leave)
      [peer_connection] = running_before_leave
      peer_connection_ref = Process.monitor(peer_connection)

      Process.unlink(channel_socket.channel_pid)
      monitor_ref = Process.monitor(channel_socket.channel_pid)
      assert_reply leave(channel_socket), :ok
      assert_receive {:DOWN, ^monitor_ref, :process, _, _reason}
      assert_receive {:DOWN, ^peer_connection_ref, :process, ^peer_connection, _reason}

      refute Enum.any?(ExWebRTC.PeerConnection.get_all_running())
      assert {:ok, %{occupancy: 0, capacity: 5}} = Voice.room_occupancy(context.voice_channel_id)
    end

    test "keeps disconnected peers available but releases terminal server peers", context do
      %{channel_socket: channel_socket, voice_session_id: voice_session_id} =
        context

      [peer_connection] = ExWebRTC.PeerConnection.get_all_running()

      assert :ok =
               Voice.dispatch_test_ex_webrtc(
                 context.voice_channel_id,
                 voice_session_id,
                 {:ex_webrtc, peer_connection, {:connection_state_change, :disconnected}}
               )

      _ = :sys.get_state(channel_socket.channel_pid)

      Process.unlink(channel_socket.channel_pid)
      monitor_ref = Process.monitor(channel_socket.channel_pid)

      assert :ok =
               Voice.dispatch_test_ex_webrtc(
                 context.voice_channel_id,
                 voice_session_id,
                 {:ex_webrtc, peer_connection, {:connection_state_change, :failed}}
               )

      assert_receive {:DOWN, ^monitor_ref, :process, _, :normal}
      refute Enum.any?(ExWebRTC.PeerConnection.get_all_running())
      assert {:ok, %{occupancy: 0, capacity: 5}} = Voice.room_occupancy(context.voice_channel_id)
    end

    test "closes the owning Channel for a closed server peer", context do
      %{channel_socket: channel_socket, voice_session_id: voice_session_id} =
        context

      [peer_connection] = ExWebRTC.PeerConnection.get_all_running()
      peer_connection_monitor = Process.monitor(peer_connection)

      Process.unlink(channel_socket.channel_pid)
      channel_monitor = Process.monitor(channel_socket.channel_pid)

      assert :ok =
               Voice.dispatch_test_ex_webrtc(
                 context.voice_channel_id,
                 voice_session_id,
                 {:ex_webrtc, peer_connection, {:connection_state_change, :closed}}
               )

      assert_receive {:DOWN, ^channel_monitor, :process, _, :normal}
      assert_receive {:DOWN, ^peer_connection_monitor, :process, ^peer_connection, _reason}
      assert {:ok, %{occupancy: 0, capacity: 5}} = Voice.room_occupancy(context.voice_channel_id)
    end

    test "emits metadata-only diagnostics for real descriptions", context do
      %{channel_socket: channel_socket, signaling_session_id: signaling_session_id} = context
      handler_id = "voice-signaling-#{System.unique_integer([:positive])}"
      test_pid = self()

      :ok =
        :telemetry.attach(
          handler_id,
          [:discord_clone, :voice_signaling, :operation],
          fn _, _, metadata, _ ->
            send(test_pid, {:voice_diagnostic, metadata})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert_reply push(
                     channel_socket,
                     "offer",
                     offer(signaling_session_id, "first-negotiation")
                   ),
                   :ok

      assert_receive {:voice_diagnostic, %{operation: "offer"} = metadata}

      assert metadata.outcome == :accepted
      assert is_integer(metadata.decoded_request_byte_count)

      assert Map.keys(metadata) |> Enum.sort() == [
               :decoded_request_byte_count,
               :operation,
               :outcome
             ]

      for forbidden <- [
            :sdp,
            :ice_username_fragment,
            :raw_rtp,
            :packet,
            :pid,
            :user_id,
            :voice_channel_id,
            :voice_session_id,
            :signaling_session_id,
            :negotiation_id,
            :description,
            :candidate,
            :ice_servers,
            :ice_credentials,
            :params,
            :socket,
            :user,
            :voice_channel
          ] do
        refute Map.has_key?(metadata, forbidden)
      end

      refute Enum.any?(Map.values(metadata), &is_pid/1)
    end

    test "counts accepted and dropped media without self-echo or identifying metadata", context do
      %{
        channel_socket: channel_socket,
        signaling_session_id: signaling_session_id,
        voice_session_id: voice_session_id
      } = context

      handler_id = "voice-media-#{System.unique_integer([:positive])}"
      test_pid = self()

      assert_reply push(
                     channel_socket,
                     "offer",
                     offer(signaling_session_id, "first-negotiation")
                   ),
                   :ok

      [peer_connection] =
        Enum.filter(ExWebRTC.PeerConnection.get_all_running(), fn peer_connection ->
          peer_connection
          |> ExWebRTC.PeerConnection.get_transceivers()
          |> Enum.count(&(&1.current_direction == :sendonly))
          |> Kernel.==(4)
        end)

      transceiver =
        peer_connection
        |> ExWebRTC.PeerConnection.get_transceivers()
        |> Enum.find(&(&1.current_direction == :recvonly))

      inbound_track = transceiver.receiver.track

      :ok =
        :telemetry.attach(
          handler_id,
          [:discord_clone, :voice_signaling, :operation],
          fn _, _, metadata, _ -> send(test_pid, {:voice_media_diagnostic, metadata}) end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert :ok =
               Voice.dispatch_test_ex_webrtc(
                 context.voice_channel_id,
                 voice_session_id,
                 {:ex_webrtc, peer_connection, {:track, inbound_track}}
               )

      assert_receive {:voice_media_diagnostic,
                      %{media_lifecycle: :inbound_track_admitted} = admitted_metadata}

      assert_media_diagnostic_metadata(admitted_metadata)
      assert admitted_metadata.inbound_packet_count == 0
      assert admitted_metadata.forwarded_packet_count == 0
      assert admitted_metadata.dropped_packet_count == 0
      assert admitted_metadata.dropped_media_count == 0

      packet =
        ExRTP.Packet.new(<<>>, payload_type: 111, sequence_number: 1, timestamp: 1, ssrc: 1)

      assert :ok =
               Voice.dispatch_test_ex_webrtc(
                 context.voice_channel_id,
                 voice_session_id,
                 {:ex_webrtc, peer_connection, {:rtp, inbound_track.id, nil, packet}}
               )

      assert_receive {:voice_media_diagnostic,
                      %{media_lifecycle: :rtp_received} = received_metadata}

      assert_media_diagnostic_metadata(received_metadata)
      assert received_metadata.inbound_packet_count == 1
      assert received_metadata.forwarded_packet_count == 0
      assert received_metadata.dropped_packet_count == 0
      assert received_metadata.dropped_media_count == 0

      assert_receive {:voice_media_diagnostic, %{media_lifecycle: :rtp_dropped} = route_metadata}
      assert_route_diagnostic_metadata(route_metadata)
      assert route_metadata.forwarded_packet_count == 0
      assert route_metadata.dropped_packet_count == 1

      for {message, lifecycle} <- [
            {{:track_muted, inbound_track.id}, :inbound_track_muted},
            {{:track_ended, inbound_track.id}, :inbound_track_ended}
          ] do
        assert :ok =
                 Voice.dispatch_test_ex_webrtc(
                   context.voice_channel_id,
                   voice_session_id,
                   {:ex_webrtc, peer_connection, message}
                 )

        assert_receive {:voice_media_diagnostic, %{media_lifecycle: ^lifecycle} = track_metadata}
        assert_media_diagnostic_metadata(track_metadata)
      end

      unsupported_media = [
        {:track, %ExWebRTC.MediaStreamTrack{id: inbound_track.id + 1, kind: :video}},
        {:data_channel, %{}},
        {:data_channel_state_change, make_ref(), :open},
        {:data, make_ref(), "unsupported"},
        {:rtcp, []}
      ]

      for message <- unsupported_media do
        assert :ok =
                 Voice.dispatch_test_ex_webrtc(
                   context.voice_channel_id,
                   voice_session_id,
                   {:ex_webrtc, peer_connection, message}
                 )

        assert_receive {:voice_media_diagnostic,
                        %{media_lifecycle: :unexpected_media_dropped} = dropped_metadata}

        assert_media_diagnostic_metadata(dropped_metadata)
      end

      assert :ok =
               Voice.dispatch_test_ex_webrtc(
                 context.voice_channel_id,
                 voice_session_id,
                 {:ex_webrtc, self(), {:rtp, inbound_track.id, nil, packet}}
               )

      assert :ok =
               Voice.dispatch_test_ex_webrtc(
                 context.voice_channel_id,
                 voice_session_id,
                 {:ex_webrtc, peer_connection, {:rtp, inbound_track.id + 2, nil, packet}}
               )

      assert_receive {:voice_media_diagnostic,
                      %{media_lifecycle: :unexpected_media_dropped} = final_metadata}

      assert_media_diagnostic_metadata(final_metadata)
      assert final_metadata.inbound_packet_count == 1
      assert final_metadata.forwarded_packet_count == 0
      assert final_metadata.dropped_packet_count == 1
      assert final_metadata.dropped_media_count == length(unsupported_media)
    end
  end

  describe "authenticated Voice joins" do
    test "join returns the established wire payload and Channel termination removes only its Session" do
      first_user = user_fixture()
      second_user = user_fixture()
      voice_channel = create_voice_channel!(first_user, "Admission characterization")
      add_workspace_member!(voice_channel.id, second_user)
      assert :ok = Voice.subscribe_to_voice_channel_roster(voice_channel.id)

      {:ok, first_socket} = connect_voice_socket(first_user)
      {:ok, second_socket} = connect_voice_socket(second_user)

      assert {:ok, first_payload, first_channel_socket} =
               subscribe_and_join(
                 first_socket,
                 VoiceChannel,
                 "voice:#{voice_channel.id}",
                 admission_params()
               )

      assert Map.keys(first_payload) |> Enum.sort() ==
               [:capacity, :ice_config, :occupancy, :signaling_session_id]

      assert first_payload.occupancy == 1
      assert first_payload.capacity == 5
      assert is_binary(first_payload.signaling_session_id)

      assert first_payload.ice_config == %{
               ice_mode: "disabled",
               ice_servers: [],
               ice_transport_policy: "all"
             }

      assert {:ok, second_payload, second_channel_socket} =
               subscribe_and_join(
                 second_socket,
                 VoiceChannel,
                 "voice:#{voice_channel.id}",
                 admission_params()
               )

      assert second_payload.occupancy == 2
      assert second_payload.capacity == 5

      assert {:ok, %{members: [%{user_id: first_id}, %{user_id: second_id}]}} =
               Voice.voice_channel_roster(voice_channel.id)

      assert first_id == first_user.id
      assert second_id == second_user.id

      Process.unlink(first_channel_socket.channel_pid)
      first_monitor = Process.monitor(first_channel_socket.channel_pid)
      Process.exit(first_channel_socket.channel_pid, :shutdown)
      assert_receive {:DOWN, ^first_monitor, :process, _, _reason}
      assert_receive {:voice_channel_roster_changed, %{members: [%{user_id: ^second_id}]}}

      assert {:ok, %{members: [%{user_id: ^second_id}]}} =
               Voice.voice_channel_roster(voice_channel.id)

      assert {:ok, %{occupancy: 1, capacity: 5}} = Voice.room_occupancy(voice_channel.id)

      Process.unlink(second_channel_socket.channel_pid)
      second_monitor = Process.monitor(second_channel_socket.channel_pid)
      Process.exit(second_channel_socket.channel_pid, :shutdown)
      assert_receive {:DOWN, ^second_monitor, :process, _, _reason}
      assert :ok = Voice.await_empty_room(voice_channel.id)
      assert {:ok, %{members: []}} = Voice.voice_channel_roster(voice_channel.id)
    end

    test "a full destination rejects a Channel move and retains the source Session" do
      owner = user_fixture()
      source_channel = create_voice_channel!(owner, "Full destination move")
      source_workspace = Repo.get!(VoiceChannelSchema, source_channel.id).workspace_id

      assert {:ok, destination_channel} =
               Workspaces.create_voice_channel(
                 DiscordClone.Accounts.Scope.for_user(owner),
                 source_workspace,
                 %{name: "full"}
               )

      on_exit(fn ->
        :ok = Voice.end_channel_sessions(source_channel.id)
        :ok = Voice.end_channel_sessions(destination_channel.id)
        :ok = Voice.expire_idle_room(source_channel.id)
        :ok = Voice.expire_idle_room(destination_channel.id)
      end)

      {:ok, socket} = connect_voice_socket(owner)

      assert {:ok, source_payload, source_socket} =
               subscribe_and_join(socket, VoiceChannel, "voice:#{source_channel.id}", %{})

      source_session_id = source_socket.assigns.voice_session_id

      for number <- 1..5 do
        assert {:ok, %{occupancy: ^number, capacity: 5}} =
                 Voice.join(
                   destination_channel.id,
                   Ecto.UUID.generate(),
                   "destination-filler-#{number}",
                   self()
                 )
      end

      assert {:error, %{reason: "room_full", occupancy: 5, capacity: 5}} =
               subscribe_and_join(socket, VoiceChannel, "voice:#{destination_channel.id}", %{})

      assert {:ok, %{members: [%{user_id: owner_id}]}} =
               Voice.voice_channel_roster(source_channel.id)

      assert owner_id == owner.id

      assert :ok =
               Voice.renew_session(
                 DiscordClone.Accounts.Scope.for_user(owner),
                 source_channel.id,
                 source_session_id,
                 source_payload.signaling_session_id
               )

      assert source_payload.occupancy == 1
      assert {:ok, %{occupancy: 1, capacity: 5}} = Voice.room_occupancy(source_channel.id)
      assert {:ok, %{occupancy: 5, capacity: 5}} = Voice.room_occupancy(destination_channel.id)
    end

    test "deployment capacity is normalized to unavailable at the authenticated Channel" do
      requester = user_fixture()
      destination_channel = create_voice_channel!(requester, "Deployment cap wire result")

      on_exit(fn ->
        Voice.running_room_servers()
        |> Enum.each(fn {room_id, _room_server} ->
          :ok = Voice.end_channel_sessions(room_id)
          :ok = Voice.expire_idle_room(room_id)
        end)
      end)

      {first_room, first_user, first_connection, first_session_id} =
        Enum.reduce(1..20, nil, fn number, first ->
          room_id = Ecto.UUID.generate()
          user_id = Ecto.UUID.generate()
          connection = "capacity-#{number}"

          assert {:ok, %{voice_session_id: session_id, occupancy: 1, capacity: 5}} =
                   Voice.join(room_id, user_id, connection, self())

          first || {room_id, user_id, connection, session_id}
        end)

      {:ok, socket} = connect_voice_socket(requester)

      assert {:error, %{reason: "unavailable"}} =
               subscribe_and_join(socket, VoiceChannel, "voice:#{destination_channel.id}", %{})

      refute Voice.room_running?(destination_channel.id)

      assert {:ok, %{voice_session_id: ^first_session_id}} =
               Voice.join(first_room, first_user, first_connection, self())
    end

    test "standard admission negotiates with one provider-neutral STUN and TURN bundle" do
      put_voice_ice_configuration(
        mode: :standard,
        stun_urls: ["stun:127.0.0.1:9"],
        provider: FakeICEProvider,
        provider_secret: "durable-provider-secret",
        provider_options: [
          observer: self(),
          results:
            {:ok,
             %{
               urls: [
                 "turn:127.0.0.1:9?transport=udp",
                 "turn:127.0.0.1:9?transport=tcp",
                 "turns:127.0.0.1:9?transport=tcp"
               ],
               username: "temporary-user",
               credential: "temporary-credential",
               expires_at: DateTime.add(DateTime.utc_now(), 120, :second)
             }}
        ]
      )

      owner = user_fixture()
      voice_channel = create_voice_channel!(owner)
      {:ok, socket} = connect_voice_socket(owner)

      assert {:ok, payload, channel_socket} =
               subscribe_and_join(socket, VoiceChannel, "voice:#{voice_channel.id}", %{})

      assert_receive {:voice_ice_provider_requested, _options}
      refute_receive {:voice_ice_provider_requested, _options}

      assert payload.ice_config == %{
               ice_mode: "standard",
               ice_servers: [
                 %{urls: ["stun:127.0.0.1:9"]},
                 %{
                   urls: [
                     "turn:127.0.0.1:9?transport=udp",
                     "turn:127.0.0.1:9?transport=tcp",
                     "turns:127.0.0.1:9?transport=tcp"
                   ],
                   username: "temporary-user",
                   credential: "temporary-credential"
                 }
               ],
               ice_transport_policy: "all"
             }

      refute inspect(payload) =~ "durable-provider-secret"

      signaling_session_id = payload.signaling_session_id

      assert_reply push(
                     channel_socket,
                     "offer",
                     offer(signaling_session_id, "standard-negotiation")
                   ),
                   :ok,
                   %{signaling_session_id: ^signaling_session_id}

      assert :ok =
               Voice.leave(
                 voice_channel.id,
                 channel_socket.assigns.voice_session_id
               )

      assert :ok = Voice.await_empty_room(voice_channel.id)
      assert {:ok, %{occupancy: 0, capacity: 5}} = Voice.room_occupancy(voice_channel.id)
    end

    test "turn-only admission returns only temporary TURN authorization with relay policy" do
      put_voice_ice_configuration(
        mode: :turn_only,
        stun_urls: [],
        provider: FakeICEProvider,
        provider_secret: "durable-provider-secret",
        provider_options: [
          observer: self(),
          results:
            {:ok,
             %{
               urls: [
                 "turn:127.0.0.1:9?transport=udp",
                 "turn:127.0.0.1:9?transport=tcp",
                 "turns:127.0.0.1:9?transport=tcp"
               ],
               username: "temporary-user",
               credential: "temporary-credential",
               expires_at: DateTime.add(DateTime.utc_now(), 120, :second)
             }}
        ]
      )

      owner = user_fixture()
      voice_channel = create_voice_channel!(owner)
      {:ok, socket} = connect_voice_socket(owner)

      assert {:ok, payload, channel_socket} =
               subscribe_and_join(socket, VoiceChannel, "voice:#{voice_channel.id}", %{})

      assert payload.ice_config == %{
               ice_mode: "turn_only",
               ice_servers: [
                 %{
                   urls: [
                     "turn:127.0.0.1:9?transport=udp",
                     "turn:127.0.0.1:9?transport=tcp",
                     "turns:127.0.0.1:9?transport=tcp"
                   ],
                   username: "temporary-user",
                   credential: "temporary-credential"
                 }
               ],
               ice_transport_policy: "relay"
             }

      refute inspect(payload) =~ "durable-provider-secret"
      refute inspect(payload) =~ "stun:"
      assert_receive {:voice_ice_provider_requested, _options}

      assert :ok = Voice.leave(voice_channel.id, channel_socket.assigns.voice_session_id)
      assert :ok = Voice.await_empty_room(voice_channel.id)
      assert {:ok, %{occupancy: 0, capacity: 5}} = Voice.room_occupancy(voice_channel.id)
    end

    test "an explicit retry performs a fresh authorized admission and credential request" do
      expires_at = DateTime.add(DateTime.utc_now(), 300, :second)

      results =
        start_supervised!(
          {Agent,
           fn ->
             [
               {:ok,
                %{
                  urls: ["turn:127.0.0.1:9?transport=udp"],
                  username: "first-temporary-user",
                  credential: "first-temporary-credential",
                  expires_at: expires_at
                }},
               {:ok,
                %{
                  urls: ["turn:127.0.0.1:9?transport=udp"],
                  username: "second-temporary-user",
                  credential: "second-temporary-credential",
                  expires_at: expires_at
                }}
             ]
           end}
        )

      put_voice_ice_configuration(
        mode: :standard,
        stun_urls: ["stun:127.0.0.1:9"],
        provider: FakeICEProvider,
        provider_secret: "durable-provider-secret",
        provider_options: [observer: self(), results: results]
      )

      owner = user_fixture()
      voice_channel = create_voice_channel!(owner)
      {:ok, socket} = connect_voice_socket(owner)

      assert {:ok, first_payload, first_channel_socket} =
               subscribe_and_join(socket, VoiceChannel, "voice:#{voice_channel.id}", %{})

      assert :ok = Voice.leave(voice_channel.id, first_channel_socket.assigns.voice_session_id)

      assert {:ok, second_payload, second_channel_socket} =
               subscribe_and_join(socket, VoiceChannel, "voice:#{voice_channel.id}", %{})

      [first_turn] =
        Enum.filter(first_payload.ice_config.ice_servers, &Map.has_key?(&1, :username))

      [second_turn] =
        Enum.filter(second_payload.ice_config.ice_servers, &Map.has_key?(&1, :username))

      assert first_turn.username == "first-temporary-user"
      assert second_turn.username == "second-temporary-user"
      refute first_turn.credential == second_turn.credential
      assert_receive {:voice_ice_provider_requested, _options}
      assert_receive {:voice_ice_provider_requested, _options}
      refute_receive {:voice_ice_provider_requested, _options}

      assert :ok = Voice.leave(voice_channel.id, second_channel_socket.assigns.voice_session_id)
      assert :ok = Voice.await_empty_room(voice_channel.id)
    end

    test "standard mode resolves no provider authorization before Workspace authorization" do
      put_voice_ice_configuration(
        mode: :standard,
        stun_urls: ["stun:127.0.0.1:9"],
        provider: FakeICEProvider,
        provider_secret: "durable-provider-secret",
        provider_options: [observer: self(), results: {:error, :unavailable}]
      )

      owner = user_fixture()
      unauthorized_user = user_fixture()
      voice_channel = create_voice_channel!(owner)
      {:ok, socket} = connect_voice_socket(unauthorized_user)

      assert {:error, %{reason: "not_found"}} =
               subscribe_and_join(socket, VoiceChannel, "voice:#{voice_channel.id}", %{})

      refute_receive {:voice_ice_provider_requested, _options}
      refute Voice.room_running?(voice_channel.id)
    end

    test "standard provider errors reject only the attempted Voice admission" do
      durable_secret = "forbidden-durable-provider-secret"
      provider_body = "forbidden-provider-response-body"
      diagnostic_handler = "ticket-04-provider-redaction-#{System.unique_integer()}"
      test_process = self()

      :ok =
        :telemetry.attach(
          diagnostic_handler,
          [:discord_clone, :voice_signaling, :operation],
          fn _event, _measurements, metadata, _config ->
            send(test_process, {:provider_failure_diagnostic, metadata})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(diagnostic_handler) end)

      put_voice_ice_configuration(
        mode: :standard,
        stun_urls: ["stun:127.0.0.1:9"],
        provider: FakeICEProvider,
        provider_secret: durable_secret,
        provider_options: [
          observer: self(),
          results: {:raise, "#{durable_secret}:#{provider_body}"}
        ]
      )

      owner = user_fixture()
      voice_channel = create_voice_channel!(owner)
      {:ok, socket} = connect_voice_socket(owner)

      logs =
        capture_log(fn ->
          assert {:error, %{reason: "unavailable"} = public_error} =
                   subscribe_and_join(socket, VoiceChannel, "voice:#{voice_channel.id}", %{})

          refute inspect(public_error) =~ durable_secret
          refute inspect(public_error) =~ provider_body
        end)

      assert_receive {:voice_ice_provider_requested, _options}
      refute_receive {:provider_failure_diagnostic, _metadata}
      refute logs =~ durable_secret
      refute logs =~ provider_body
      refute Voice.room_running?(voice_channel.id)
    end

    test "PeerConnection startup failure returns no temporary authorization and leaves no membership" do
      temporary_username = "forbidden-temporary-username"
      temporary_credential = "forbidden-temporary-credential"

      put_voice_ice_configuration(
        mode: :standard,
        stun_urls: ["stun:127.0.0.1:9"],
        provider: FakeICEProvider,
        provider_secret: "forbidden-durable-provider-secret",
        provider_options: [
          observer: self(),
          results:
            {:ok,
             %{
               urls: ["turn:127.0.0.1:9?transport=udp"],
               username: temporary_username,
               credential: temporary_credential,
               expires_at: DateTime.add(DateTime.utc_now(), 120, :second)
             }}
        ]
      )

      owner = user_fixture()
      voice_channel = create_voice_channel!(owner)
      start_failing_voice_room!(voice_channel.id)
      {:ok, socket} = connect_voice_socket(owner)

      logs =
        capture_log(fn ->
          assert {:error, %{reason: "unavailable"} = public_error} =
                   subscribe_and_join(socket, VoiceChannel, "voice:#{voice_channel.id}", %{})

          refute inspect(public_error) =~ temporary_username
          refute inspect(public_error) =~ temporary_credential
        end)

      refute logs =~ "forbidden-durable-provider-secret"
      refute logs =~ temporary_username
      refute logs =~ temporary_credential
      assert_receive {:voice_ice_provider_requested, _options}
      assert :ok = Voice.await_empty_room(voice_channel.id)
      assert {:ok, %{occupancy: 0, capacity: 5}} = Voice.room_occupancy(voice_channel.id)
    end

    test "admits without an offer and ignores client negotiation fields" do
      owner = user_fixture()
      voice_channel = create_voice_channel!(owner)
      {:ok, socket} = connect_voice_socket(owner)

      assert {:ok,
              %{
                signaling_session_id: signaling_session_id,
                occupancy: 1,
                capacity: 5,
                ice_config: %{ice_servers: [], ice_transport_policy: "all"}
              } = payload, channel_socket} =
               subscribe_and_join(
                 socket,
                 VoiceChannel,
                 "voice:#{voice_channel.id}",
                 %{
                   "description" => browser_offer(3),
                   "negotiation_id" => "client-controlled-admission-id",
                   "server_ice_projection" => %{"transport_policy" => "relay"}
                 }
               )

      assert is_binary(signaling_session_id)
      refute Map.has_key?(payload, :voice_session_id)
      assert is_binary(channel_socket.assigns.voice_session_id)
      assert {:ok, %{occupancy: 1, capacity: 5}} = Voice.room_occupancy(voice_channel.id)
    end

    test "denies unauthorized, missing, and malformed Voice Channels without runtime state" do
      owner = user_fixture()
      unauthorized_user = user_fixture()
      voice_channel = create_voice_channel!(owner)

      {:ok, unauthorized_socket} = connect_voice_socket(unauthorized_user)
      missing_voice_channel_id = Ecto.UUID.generate()

      assert {:error, %{reason: "not_found"}} =
               subscribe_and_join(unauthorized_socket, VoiceChannel, "voice:#{voice_channel.id}")

      assert {:error, %{reason: "not_found"}} =
               subscribe_and_join(
                 unauthorized_socket,
                 VoiceChannel,
                 "voice:#{missing_voice_channel_id}"
               )

      assert {:error, %{reason: "not_found"}} =
               subscribe_and_join(unauthorized_socket, VoiceChannel, "voice:not-a-uuid")

      refute Voice.room_running?(voice_channel.id)
      refute Voice.room_running?(missing_voice_channel_id)
      refute Voice.room_running?("not-a-uuid")
    end

    test "rolls back admission when final Workspace authorization is lost" do
      owner = user_fixture()
      member = user_fixture()
      voice_channel = create_voice_channel!(owner)
      add_workspace_member!(voice_channel.id, member)
      {:ok, socket} = connect_voice_socket(member)
      readiness_gate = make_ref()
      start_gated_voice_room!(voice_channel.id, readiness_gate)
      test_process = self()

      start_supervised!(%{
        id: {:final_authorization_join, voice_channel.id},
        restart: :temporary,
        start:
          {Task, :start_link,
           [
             fn ->
               result = VoiceChannel.join("voice:#{voice_channel.id}", %{}, socket)
               send(test_process, {:final_authorization_join_result, result})
             end
           ]}
      })

      assert_receive {:peer_connection_starting, ^readiness_gate, peer_connection}, 1_000

      WorkspaceMembership
      |> Repo.get_by!(workspace_id: voice_channel.workspace_id, user_id: member.id)
      |> Repo.delete!()

      send(peer_connection, {:release_peer_connection_start, readiness_gate})

      assert_receive {:final_authorization_join_result, {:error, %{reason: "not_found"}}}, 1_000
      assert :ok = Voice.await_empty_room(voice_channel.id)
      assert {:ok, %{occupancy: 0, capacity: 5}} = Voice.room_occupancy(voice_channel.id)
    end

    test "rolls back every failed join-reply and roster finalization stage" do
      durable_secret = "forbidden-finalization-durable-secret"
      temporary_username = "forbidden-finalization-temporary-user"
      temporary_credential = "forbidden-finalization-temporary-credential"
      provider_metadata = "forbidden-finalization-provider-metadata"
      turn_url = "turn:127.0.0.1:9?transport=udp"
      diagnostic_handler = "ticket-04-finalization-redaction-#{System.unique_integer()}"
      test_process = self()

      :ok =
        :telemetry.attach(
          diagnostic_handler,
          [:discord_clone, :voice_signaling, :operation],
          fn _event, _measurements, metadata, _config ->
            send(test_process, {:finalization_failure_diagnostic, metadata})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(diagnostic_handler) end)

      put_voice_ice_configuration(
        mode: :standard,
        stun_urls: ["stun:127.0.0.1:9"],
        provider: FakeICEProvider,
        provider_secret: durable_secret,
        provider_options: [
          observer: self(),
          provider_private_metadata: provider_metadata,
          results:
            {:ok,
             %{
               urls: [turn_url],
               username: temporary_username,
               credential: temporary_credential,
               expires_at: DateTime.add(DateTime.utc_now(), 300, :second)
             }}
        ]
      )

      forbidden_values = [
        durable_secret,
        temporary_username,
        temporary_credential,
        provider_metadata,
        turn_url
      ]

      captured_logs =
        capture_log(fn ->
          for failure <- [:join_payload, :roster_lookup, :roster_subscription] do
            owner = user_fixture()
            voice_channel = create_voice_channel!(owner, "Finalization #{failure}")
            {:ok, socket} = connect_voice_socket(owner)
            socket = Phoenix.Socket.assign(socket, :voice_admission_failure, failure)

            assert {:error, %{reason: "unavailable"} = public_error} =
                     subscribe_and_join(socket, VoiceChannel, "voice:#{voice_channel.id}", %{})

            for forbidden_value <- forbidden_values do
              refute inspect(public_error) =~ forbidden_value
            end

            assert :ok = Voice.await_empty_room(voice_channel.id)
            assert {:ok, %{occupancy: 0, capacity: 5}} = Voice.room_occupancy(voice_channel.id)
          end
        end)

      for _attempt <- 1..3 do
        assert_receive {:voice_ice_provider_requested, _options}
      end

      diagnostics = collect_finalization_diagnostics([])

      for forbidden_value <- forbidden_values do
        refute captured_logs =~ forbidden_value

        refute Enum.any?(diagnostics, fn metadata ->
                 inspect(metadata) =~ forbidden_value
               end)
      end
    end

    test "normalizes a full-room join and releases the unused PeerConnection" do
      owner = user_fixture()
      voice_channel = create_voice_channel!(owner)

      voice_session_ids =
        for number <- 1..5 do
          assert {:ok, %{voice_session_id: voice_session_id, occupancy: ^number, capacity: 5}} =
                   Voice.join(
                     voice_channel.id,
                     Ecto.UUID.generate(),
                     "filler-#{number}",
                     self()
                   )

          voice_session_id
        end

      on_exit(fn ->
        Enum.each(voice_session_ids, &Voice.leave(voice_channel.id, &1))
        Voice.expire_idle_room(voice_channel.id)
      end)

      running_before_join = ExWebRTC.PeerConnection.get_all_running()
      {:ok, socket} = connect_voice_socket(owner)

      assert {:error, %{reason: "room_full", occupancy: 5, capacity: 5}} =
               subscribe_and_join(
                 socket,
                 VoiceChannel,
                 "voice:#{voice_channel.id}",
                 admission_params()
               )

      assert ExWebRTC.PeerConnection.get_all_running() == running_before_join
      assert {:ok, %{occupancy: 5, capacity: 5}} = Voice.room_occupancy(voice_channel.id)
    end

    test "an older Channel termination cannot remove a newer Voice Session" do
      user = user_fixture()
      voice_channel = create_voice_channel!(user)
      {:ok, socket} = connect_voice_socket(user)

      assert {:ok, first_payload, first_channel_socket} =
               subscribe_and_join(
                 socket,
                 VoiceChannel,
                 "voice:#{voice_channel.id}",
                 admission_params()
               )

      first_voice_session_id = first_channel_socket.assigns.voice_session_id
      refute Map.has_key?(first_payload, :voice_session_id)

      assert {:ok, second_payload, second_channel_socket} =
               subscribe_and_join(
                 first_channel_socket,
                 VoiceChannel,
                 first_channel_socket.topic,
                 admission_params()
               )

      second_voice_session_id = second_channel_socket.assigns.voice_session_id
      refute Map.has_key?(second_payload, :voice_session_id)
      refute first_voice_session_id == second_voice_session_id
      assert {:ok, %{occupancy: 1, capacity: 5}} = Voice.room_occupancy(voice_channel.id)

      Process.unlink(first_channel_socket.channel_pid)
      monitor_ref = Process.monitor(first_channel_socket.channel_pid)
      Process.exit(first_channel_socket.channel_pid, :shutdown)
      assert_receive {:DOWN, ^monitor_ref, :process, _, _reason}

      assert {:ok, %{occupancy: 1, capacity: 5}} = Voice.room_occupancy(voice_channel.id)

      Process.unlink(second_channel_socket.channel_pid)
      second_monitor_ref = Process.monitor(second_channel_socket.channel_pid)
      Process.exit(second_channel_socket.channel_pid, :shutdown)
      assert_receive {:DOWN, ^second_monitor_ref, :process, _, _reason}
      assert :ok = Voice.await_empty_room(voice_channel.id)
      assert {:ok, %{occupancy: 0, capacity: 5}} = Voice.room_occupancy(voice_channel.id)
    end
  end

  describe "socket joins" do
    test "uses the exact authentication session topic as its socket identity" do
      user = user_fixture()
      token = Accounts.generate_user_session_token(user)
      other_token = Accounts.generate_user_session_token(user)

      assert {:ok, socket} =
               connect(VoiceSocket, %{}, connect_info: %{session: %{"user_token" => token}})

      assert {:ok, other_socket} =
               connect(VoiceSocket, %{}, connect_info: %{session: %{"user_token" => other_token}})

      assert VoiceSocket.id(socket) == "users_sessions:#{Base.url_encode64(token)}"
      assert VoiceSocket.id(other_socket) == "users_sessions:#{Base.url_encode64(other_token)}"
      refute VoiceSocket.id(socket) == VoiceSocket.id(other_socket)
    end

    test "derives scope from the signed session and denies invalid sessions" do
      user = user_fixture()
      other_user = user_fixture()
      token = Accounts.generate_user_session_token(user)

      assert {:ok, socket} =
               connect(VoiceSocket, %{"user_id" => other_user.id},
                 connect_info: %{session: %{"user_token" => token}}
               )

      assert socket.assigns.current_scope.user.id == user.id
      assert :error = connect(VoiceSocket, %{}, connect_info: %{session: nil})
    end
  end

  defp offer(signaling_session_id, negotiation_id) do
    %{
      "signaling_session_id" => signaling_session_id,
      "negotiation_id" => negotiation_id,
      "description" => browser_offer()
    }
  end

  defp admission_params do
    %{}
  end

  defp assert_media_diagnostic_metadata(metadata) do
    assert Map.keys(metadata) |> Enum.sort() == [
             :dropped_media_count,
             :dropped_packet_count,
             :forwarded_packet_count,
             :inbound_packet_count,
             :media_lifecycle
           ]
  end

  defp assert_route_diagnostic_metadata(metadata) do
    assert Map.keys(metadata) |> Enum.sort() == [
             :dropped_packet_count,
             :forwarded_packet_count,
             :media_lifecycle
           ]
  end

  defp candidate do
    %{
      "candidate" => "candidate:1 1 udp 1 127.0.0.1 9 typ host",
      "sdpMid" => "0",
      "sdpMLineIndex" => 0
    }
  end

  defp server_candidate(candidate_value) do
    %ExWebRTC.ICECandidate{
      candidate: candidate_value,
      sdp_mid: "0",
      sdp_m_line_index: 0
    }
  end

  defp assert_server_ice_gathering(signaling_session_id, negotiation_id, candidate_count \\ 0) do
    assert_push "ice_candidate", payload

    assert %{
             signaling_session_id: ^signaling_session_id,
             negotiation_id: ^negotiation_id
           } = payload

    case payload do
      %{candidate: %{"candidate" => candidate}} when is_binary(candidate) ->
        assert byte_size(candidate) > 0
        assert_server_ice_gathering(signaling_session_id, negotiation_id, candidate_count + 1)

      %{end_of_candidates: true} ->
        assert candidate_count > 0

      _other ->
        flunk("unexpected server ICE event shape")
    end
  end

  defp create_voice_channel!(user, workspace_name \\ "Voice join") do
    scope = DiscordClone.Accounts.Scope.for_user(user)
    {:ok, workspace} = Workspaces.create_workspace(scope, %{name: workspace_name})
    {:ok, voice_channel} = Workspaces.create_voice_channel(scope, workspace.id, %{name: "lobby"})
    voice_channel
  end

  defp connect_voice_socket(user) do
    token = Accounts.generate_user_session_token(user)
    connect(VoiceSocket, %{}, connect_info: %{session: %{"user_token" => token}})
  end

  defp add_workspace_member!(voice_channel_id, user) do
    voice_channel = Repo.get!(VoiceChannelSchema, voice_channel_id)

    %WorkspaceMembership{}
    |> WorkspaceMembership.changeset(%{
      workspace_id: voice_channel.workspace_id,
      user_id: user.id,
      role: "member"
    })
    |> Repo.insert!()
  end

  defp start_gated_voice_room!(voice_channel_id, readiness_gate) do
    start_voice_room_with_peer_options!(
      voice_channel_id,
      :gated,
      test_readiness_gate: {self(), readiness_gate}
    )
  end

  defp start_failing_voice_room!(voice_channel_id) do
    start_voice_room_with_peer_options!(voice_channel_id, :failing, audio_codecs: [:invalid])
  end

  defp start_voice_room_with_peer_options!(voice_channel_id, id_prefix, peer_options) do
    start_supervised!(%{
      id: {id_prefix, :voice_room, voice_channel_id},
      start:
        {RoomServer, :start_link,
         [
           [
             voice_channel_id: voice_channel_id,
             room_supervisor: self(),
             test_peer_connection_opts: peer_options
           ]
         ]}
    })

    start_supervised!(%{
      id: {id_prefix, :voice_sessions, voice_channel_id},
      start: {SessionSupervisor, :start_link, [[voice_channel_id: voice_channel_id]]}
    })

    start_supervised!(%{
      id: {id_prefix, :voice_forwarder, voice_channel_id},
      start: {Forwarder, :start_link, [[voice_channel_id: voice_channel_id]]}
    })
  end

  defp collect_finalization_diagnostics(diagnostics) do
    receive do
      {:finalization_failure_diagnostic, metadata} ->
        collect_finalization_diagnostics([metadata | diagnostics])
    after
      0 -> diagnostics
    end
  end
end
