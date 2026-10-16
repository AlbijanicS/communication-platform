defmodule DiscordClone.Voice.ForwarderTest do
  use ExUnit.Case, async: false

  alias DiscordClone.Voice.Forwarder

  test "routes the complete three-Session matrix without blocking ready pairs" do
    attach_route_diagnostics()
    forwarder = start_forwarder()
    [first_id, second_id, third_id] = Enum.map(1..3, fn _ -> Ecto.UUID.generate() end)
    first_packet = ExRTP.Packet.new(<<1>>, sequence_number: 1, timestamp: 1, ssrc: 1)

    register_ready_session(forwarder, second_id, 202)
    register_ready_session(forwarder, first_id, 101)
    assert :ok = Forwarder.sync(forwarder)

    assert :ok = Forwarder.forward_rtp(forwarder, first_id, 101, first_packet)
    assert_receive {_cast, {:deliver_rtp, ^second_id, 0, ^first_packet}}
    assert_receive {:voice_route_diagnostic, %{media_lifecycle: :rtp_forwarded} = forwarded}
    assert_route_diagnostic(forwarded, 1, 0)
    refute_receive {_cast, {:deliver_rtp, ^first_id, _, ^first_packet}}, 0

    assert :ok = Forwarder.session_started(forwarder, third_id, self())
    assert :ok = Forwarder.sync(forwarder)
    assert :ok = Forwarder.forward_rtp(forwarder, first_id, 101, first_packet)
    assert_receive {_cast, {:deliver_rtp, ^second_id, 0, ^first_packet}}
    refute_receive {_cast, {:deliver_rtp, ^third_id, _, ^first_packet}}, 0

    assert :ok = Forwarder.receive_ready(forwarder, third_id, self(), :opus)
    assert :ok = Forwarder.send_ready(forwarder, third_id, self(), 303, :opus)
    assert :ok = Forwarder.sync(forwarder)

    source_packets = [
      {first_id, 101, ExRTP.Packet.new(<<11>>, sequence_number: 11, timestamp: 11, ssrc: 11)},
      {second_id, 202, ExRTP.Packet.new(<<22>>, sequence_number: 22, timestamp: 22, ssrc: 22)},
      {third_id, 303, ExRTP.Packet.new(<<33>>, sequence_number: 33, timestamp: 33, ssrc: 33)}
    ]

    deliveries =
      Enum.flat_map(source_packets, fn {source_id, track_id, packet} ->
        assert :ok = Forwarder.forward_rtp(forwarder, source_id, track_id, packet)

        Enum.map(1..2, fn _ ->
          assert_receive {_cast, {:deliver_rtp, destination_id, slot, ^packet}}
          {source_id, destination_id, slot}
        end)
      end)

    assert MapSet.new(
             Enum.map(deliveries, fn {source_id, destination_id, _slot} ->
               {source_id, destination_id}
             end)
           ) ==
             MapSet.new([
               {first_id, second_id},
               {first_id, third_id},
               {second_id, first_id},
               {second_id, third_id},
               {third_id, first_id},
               {third_id, second_id}
             ])

    for destination_id <- [first_id, second_id, third_id] do
      destination_slots =
        for {_source_id, ^destination_id, slot} <- deliveries, do: slot

      assert Enum.sort(destination_slots) == [0, 1]
    end
  end

  test "a Workspace-Muted Audio Source cannot forward while remaining an Audio Destination" do
    forwarder = start_forwarder()
    source_id = Ecto.UUID.generate()
    muted_destination_id = Ecto.UUID.generate()

    register_ready_session(forwarder, source_id, 101)
    register_ready_session(forwarder, muted_destination_id, 202)
    assert :ok = Forwarder.sync(forwarder)

    assert :ok = Forwarder.set_source_muted(forwarder, source_id, true)

    blocked_packet = ExRTP.Packet.new(<<1>>, sequence_number: 1, timestamp: 1, ssrc: 1)
    assert :ok = Forwarder.forward_rtp(forwarder, source_id, 101, blocked_packet)
    assert :ok = Forwarder.sync(forwarder)
    refute_receive {_cast, {:deliver_rtp, ^muted_destination_id, _, ^blocked_packet}}, 0

    inbound_packet = ExRTP.Packet.new(<<2>>, sequence_number: 2, timestamp: 2, ssrc: 2)
    assert :ok = Forwarder.forward_rtp(forwarder, muted_destination_id, 202, inbound_packet)
    assert_receive {_cast, {:deliver_rtp, ^source_id, 0, ^inbound_packet}}

    assert :ok = Forwarder.set_source_muted(forwarder, source_id, false)
    assert :ok = Forwarder.forward_rtp(forwarder, source_id, 101, blocked_packet)
    assert_receive {_cast, {:deliver_rtp, ^muted_destination_id, 0, ^blocked_packet}}
  end

  test "duplicate readiness in a different order keeps each source in its destination slot" do
    forwarder = start_forwarder()
    [first_id, second_id, third_id] = Enum.map(1..3, fn _ -> Ecto.UUID.generate() end)

    for voice_session_id <- [first_id, second_id, third_id] do
      assert :ok = Forwarder.session_started(forwarder, voice_session_id, self())
    end

    for {voice_session_id, track_id} <- [{third_id, 303}, {first_id, 101}, {second_id, 202}] do
      assert :ok = Forwarder.send_ready(forwarder, voice_session_id, self(), track_id, :opus)
      assert :ok = Forwarder.receive_ready(forwarder, voice_session_id, self(), :opus)
    end

    assert :ok = Forwarder.sync(forwarder)
    packet = ExRTP.Packet.new(<<4>>, sequence_number: 4, timestamp: 4, ssrc: 4)
    assert :ok = Forwarder.forward_rtp(forwarder, third_id, 303, packet)

    first_deliveries =
      Enum.map(1..2, fn _ ->
        assert_receive {_cast, {:deliver_rtp, destination_id, slot, ^packet}}
        {destination_id, slot}
      end)

    assert :ok = Forwarder.receive_ready(forwarder, third_id, self(), :opus)
    assert :ok = Forwarder.send_ready(forwarder, third_id, self(), 303, :opus)
    assert :ok = Forwarder.sync(forwarder)
    assert :ok = Forwarder.forward_rtp(forwarder, third_id, 303, packet)

    second_deliveries =
      Enum.map(1..2, fn _ ->
        assert_receive {_cast, {:deliver_rtp, destination_id, slot, ^packet}}
        {destination_id, slot}
      end)

    assert MapSet.new(second_deliveries) == MapSet.new(first_deliveries)
  end

  test "requires complementary readiness and removes only the ended source" do
    forwarder = start_forwarder()
    first_id = Ecto.UUID.generate()
    second_id = Ecto.UUID.generate()
    packet = ExRTP.Packet.new(<<2>>, sequence_number: 2, timestamp: 2, ssrc: 2)

    assert :ok = Forwarder.session_started(forwarder, first_id, self())
    assert :ok = Forwarder.session_started(forwarder, second_id, self())
    assert :ok = Forwarder.receive_ready(forwarder, first_id, self(), :opus)
    assert :ok = Forwarder.send_ready(forwarder, first_id, self(), 101, :opus)
    assert :ok = Forwarder.send_ready(forwarder, second_id, self(), 202, :opus)
    assert :ok = Forwarder.sync(forwarder)

    assert :ok = Forwarder.forward_rtp(forwarder, first_id, 101, packet)
    assert :ok = Forwarder.sync(forwarder)
    refute_receive {_cast, {:deliver_rtp, _, _, ^packet}}, 0

    assert :ok = Forwarder.receive_ready(forwarder, second_id, self(), :opus)
    assert :ok = Forwarder.sync(forwarder)
    assert :ok = Forwarder.forward_rtp(forwarder, first_id, 101, packet)
    assert_receive {_cast, {:deliver_rtp, ^second_id, 0, ^packet}}

    assert :ok = Forwarder.source_ended(forwarder, first_id, self(), 101)
    assert :ok = Forwarder.sync(forwarder)
    assert :ok = Forwarder.forward_rtp(forwarder, first_id, 101, packet)
    assert :ok = Forwarder.sync(forwarder)
    refute_receive {_cast, {:deliver_rtp, _, _, ^packet}}, 0

    assert :ok = Forwarder.forward_rtp(forwarder, second_id, 202, packet)
    assert_receive {_cast, {:deliver_rtp, ^first_id, 0, ^packet}}
  end

  test "routes every ordered pair for room sizes one through five" do
    for room_size <- 1..5 do
      forwarder = start_forwarder()

      sessions =
        Enum.map(1..room_size, fn number ->
          {Ecto.UUID.generate(), number * 100}
        end)

      for {voice_session_id, track_id} <- sessions do
        register_ready_session(forwarder, voice_session_id, track_id)
      end

      assert :ok = Forwarder.sync(forwarder)

      deliveries =
        Enum.flat_map(sessions, fn {source_id, track_id} ->
          packet =
            ExRTP.Packet.new(<<track_id>>, sequence_number: track_id, timestamp: track_id)

          assert :ok = Forwarder.forward_rtp(forwarder, source_id, track_id, packet)

          receive_deliveries(packet, room_size - 1)
          |> Enum.map(fn {destination_id, slot} -> {source_id, destination_id, slot} end)
        end)

      expected_pairs =
        for {source_id, _} <- sessions,
            {destination_id, _} <- sessions,
            source_id != destination_id,
            into: MapSet.new() do
          {source_id, destination_id}
        end

      assert MapSet.new(
               Enum.map(deliveries, fn {source_id, destination_id, _slot} ->
                 {source_id, destination_id}
               end)
             ) == expected_pairs

      refute Enum.any?(deliveries, fn {source_id, destination_id, _slot} ->
               source_id == destination_id
             end)

      for {destination_id, _} <- sessions do
        destination_slots =
          for {_source_id, ^destination_id, slot} <- deliveries, do: slot

        assert Enum.sort(destination_slots) == Enum.to_list(0..(room_size - 2)//1)
      end
    end
  end

  test "preserves existing slots and gives a replacement source the first released slot" do
    forwarder = start_forwarder()

    [{first_id, _}, {second_id, _}, {third_id, _}, {fourth_id, _}] =
      sessions =
      Enum.map(1..4, fn number ->
        {Ecto.UUID.generate(), number * 100}
      end)

    for {voice_session_id, track_id} <- sessions do
      register_ready_session(forwarder, voice_session_id, track_id)
    end

    assert :ok = Forwarder.sync(forwarder)

    initial_slots =
      slots_at_destination(
        forwarder,
        first_id,
        [{second_id, 200}, {third_id, 300}, {fourth_id, 400}],
        3
      )

    assert :ok = Forwarder.session_removed(forwarder, third_id)

    replacement_id = Ecto.UUID.generate()
    register_ready_session(forwarder, replacement_id, 500)
    assert :ok = Forwarder.sync(forwarder)

    replacement_slots =
      slots_at_destination(
        forwarder,
        first_id,
        [{second_id, 200}, {fourth_id, 400}, {replacement_id, 500}],
        3
      )

    assert replacement_slots[second_id] == initial_slots[second_id]
    assert replacement_slots[fourth_id] == initial_slots[fourth_id]
    assert replacement_slots[replacement_id] == initial_slots[third_id]
    assert MapSet.size(MapSet.new(Map.values(replacement_slots))) == 3
  end

  test "keeps an RTP timeline continuous when a released Audio Output Slot gets a new source" do
    forwarder = start_forwarder()
    destination_id = Ecto.UUID.generate()
    first_source_id = Ecto.UUID.generate()
    replacement_source_id = Ecto.UUID.generate()

    register_ready_session(forwarder, destination_id, 100)
    register_ready_session(forwarder, first_source_id, 200)
    assert :ok = Forwarder.sync(forwarder)

    first_packet = ExRTP.Packet.new(<<1>>, sequence_number: 8_003, timestamp: 2_920, ssrc: 1)
    assert :ok = Forwarder.forward_rtp(forwarder, first_source_id, 200, first_packet)
    assert_receive {_cast, {:deliver_rtp, ^destination_id, 0, ^first_packet}}

    assert :ok = Forwarder.session_removed(forwarder, first_source_id)
    register_ready_session(forwarder, replacement_source_id, 300)
    assert :ok = Forwarder.sync(forwarder)

    replacement_packet =
      ExRTP.Packet.new(<<2>>, sequence_number: 47_120, timestamp: 918_273, ssrc: 2)

    assert :ok = Forwarder.forward_rtp(forwarder, replacement_source_id, 300, replacement_packet)

    assert_receive {_cast, {:deliver_rtp, ^destination_id, 0, munged_packet}}
    assert munged_packet.sequence_number == 8_004
    assert munged_packet.timestamp > first_packet.timestamp
    refute munged_packet.timestamp == replacement_packet.timestamp
  end

  test "updates an Audio Output Slot RTP timeline when its source replaces an inbound track" do
    forwarder = start_forwarder()
    destination_id = Ecto.UUID.generate()
    source_id = Ecto.UUID.generate()

    register_ready_session(forwarder, destination_id, 100)
    register_ready_session(forwarder, source_id, 200)
    assert :ok = Forwarder.sync(forwarder)

    first_packet = ExRTP.Packet.new(<<1>>, sequence_number: 8_003, timestamp: 2_920, ssrc: 1)
    assert :ok = Forwarder.forward_rtp(forwarder, source_id, 200, first_packet)
    assert_receive {_cast, {:deliver_rtp, ^destination_id, 0, ^first_packet}}

    assert :ok = Forwarder.source_ended(forwarder, source_id, self(), 200)
    assert :ok = Forwarder.send_ready(forwarder, source_id, self(), 300, :opus)
    assert :ok = Forwarder.sync(forwarder)

    replacement_packet =
      ExRTP.Packet.new(<<2>>, sequence_number: 47_120, timestamp: 918_273, ssrc: 2)

    assert :ok = Forwarder.forward_rtp(forwarder, source_id, 300, replacement_packet)

    assert_receive {_cast, {:deliver_rtp, ^destination_id, 0, munged_packet}}
    assert munged_packet.sequence_number == 8_004
    assert munged_packet.timestamp > first_packet.timestamp
    refute munged_packet.timestamp == replacement_packet.timestamp
  end

  test "an ended source withdraws every destination route without disturbing other sources" do
    forwarder = start_forwarder()

    [{first_id, first_track_id}, {second_id, second_track_id}, {third_id, _third_track_id}] =
      sessions =
      Enum.map(1..3, fn number ->
        {Ecto.UUID.generate(), number * 100}
      end)

    for {voice_session_id, track_id} <- sessions do
      register_ready_session(forwarder, voice_session_id, track_id)
    end

    assert :ok = Forwarder.sync(forwarder)

    ended_packet = ExRTP.Packet.new(<<1>>, sequence_number: 1, timestamp: 1, ssrc: 1)
    assert :ok = Forwarder.forward_rtp(forwarder, first_id, first_track_id, ended_packet)

    assert MapSet.new(receive_deliveries(ended_packet, 2) |> Enum.map(&elem(&1, 0))) ==
             MapSet.new([second_id, third_id])

    assert :ok = Forwarder.source_ended(forwarder, first_id, self(), first_track_id)
    assert :ok = Forwarder.source_ended(forwarder, first_id, self(), first_track_id)
    assert :ok = Forwarder.sync(forwarder)
    assert :ok = Forwarder.forward_rtp(forwarder, first_id, first_track_id, ended_packet)
    assert :ok = Forwarder.sync(forwarder)
    refute_receive {_cast, {:deliver_rtp, _, _, ^ended_packet}}, 0

    retained_packet = ExRTP.Packet.new(<<2>>, sequence_number: 2, timestamp: 2, ssrc: 2)
    assert :ok = Forwarder.forward_rtp(forwarder, second_id, second_track_id, retained_packet)

    assert MapSet.new(receive_deliveries(retained_packet, 2) |> Enum.map(&elem(&1, 0))) ==
             MapSet.new([first_id, third_id])
  end

  test "duplicate cleanup and late readiness cannot resurrect a removed Session" do
    attach_route_diagnostics()
    forwarder = start_forwarder()

    sessions =
      Enum.map(1..5, fn number ->
        {Ecto.UUID.generate(), number * 100}
      end)

    for {voice_session_id, track_id} <- sessions do
      register_ready_session(forwarder, voice_session_id, track_id)
    end

    [{removed_id, removed_track_id} | retained_sessions] = sessions

    assert :ok = Forwarder.session_removed(forwarder, removed_id)
    assert :ok = Forwarder.session_removed(forwarder, removed_id)
    assert :ok = Forwarder.receive_ready(forwarder, removed_id, self(), :opus)
    assert :ok = Forwarder.send_ready(forwarder, removed_id, self(), removed_track_id, :opus)
    assert :ok = Forwarder.sync(forwarder)

    late_packet = ExRTP.Packet.new(<<5>>, sequence_number: 5, timestamp: 5, ssrc: 5)
    assert :ok = Forwarder.forward_rtp(forwarder, removed_id, removed_track_id, late_packet)
    assert :ok = Forwarder.sync(forwarder)
    refute_receive {_cast, {:deliver_rtp, _, _, ^late_packet}}, 0

    assert_receive {:voice_route_diagnostic, %{media_lifecycle: :rtp_dropped} = dropped}
    assert_route_diagnostic(dropped, 0, 1)

    [{retained_id, retained_track_id} | _] = retained_sessions
    retained_packet = ExRTP.Packet.new(<<6>>, sequence_number: 6, timestamp: 6, ssrc: 6)
    assert :ok = Forwarder.forward_rtp(forwarder, retained_id, retained_track_id, retained_packet)
    assert length(receive_deliveries(retained_packet, 3)) == 3

    refute_receive {_cast, {:deliver_rtp, ^removed_id, _, ^retained_packet}}, 0
  end

  defp start_forwarder do
    start_supervised!(%{
      id: make_ref(),
      start: {Forwarder, :start_link, [[voice_channel_id: Ecto.UUID.generate()]]}
    })
  end

  defp register_ready_session(forwarder, voice_session_id, track_id) do
    assert :ok = Forwarder.session_started(forwarder, voice_session_id, self())
    assert :ok = Forwarder.receive_ready(forwarder, voice_session_id, self(), :opus)
    assert :ok = Forwarder.send_ready(forwarder, voice_session_id, self(), track_id, :opus)
  end

  defp receive_deliveries(_packet, 0), do: []

  defp receive_deliveries(packet, count) do
    receive_deliveries(packet, count, &(&1 == packet))
  end

  defp receive_deliveries(_packet, count, assert_packet) when is_function(assert_packet, 1) do
    Enum.map(1..count, fn _ ->
      assert_receive {_cast, {:deliver_rtp, destination_id, slot, delivered_packet}}
      assert assert_packet.(delivered_packet)
      {destination_id, slot}
    end)
  end

  defp slots_at_destination(forwarder, destination_id, sources, delivery_count) do
    Enum.reduce(sources, %{}, fn {source_id, track_id}, slots ->
      packet = ExRTP.Packet.new(<<track_id>>, sequence_number: track_id, timestamp: track_id)
      assert :ok = Forwarder.forward_rtp(forwarder, source_id, track_id, packet)

      source_slots =
        packet
        |> receive_deliveries(delivery_count, &(&1.payload == packet.payload))
        |> Map.new()

      Map.put(slots, source_id, Map.fetch!(source_slots, destination_id))
    end)
  end

  defp attach_route_diagnostics do
    handler_id = "voice-route-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:discord_clone, :voice_signaling, :operation],
        fn _, _, metadata, _ ->
          if metadata[:media_lifecycle] in [:rtp_forwarded, :rtp_dropped] do
            send(test_pid, {:voice_route_diagnostic, metadata})
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp assert_route_diagnostic(metadata, forwarded_count, dropped_count) do
    assert metadata == %{
             media_lifecycle: metadata.media_lifecycle,
             forwarded_packet_count: forwarded_count,
             dropped_packet_count: dropped_count
           }
  end
end
