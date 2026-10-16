defmodule DiscordClone.Media.CallForwarderTest do
  use ExUnit.Case, async: false

  alias DiscordClone.Voice.Forwarder

  # Synthetic sinks consume a whole frame here; real transport completion is
  # covered by ticket14_delivery at the two-Session media seam.
  defmacrop assert_video(id, packet) do
    quote do
      assert_receive {_,
                      {:deliver_video, forwarder, unquote(id), ref, credit, [unquote(packet)], _}}

      Forwarder.video_delivered(forwarder, unquote(id), self(), ref, credit)
      Forwarder.sync(forwarder)
    end
  end

  @tag :ticket14_delivery
  @tag :ticket15_recovery
  test "retired route completion cannot release current destination credit" do
    forwarder = start_forwarder()
    ready(forwarder, "a", self(), 101)
    ready(forwarder, "b", self(), 202)
    Forwarder.receive_ready(forwarder, "b", self(), :video, :vp8)
    Forwarder.send_ready(forwarder, "a", self(), :video, 303, :vp8)
    forward_video(forwarder, fragment(1, <<0x10, 0, 1>>, marker: true))
    assert_receive {_, {:deliver_video, ^forwarder, "b", old_ref, old_credit, [_], _}}
    assert_receive {_, {:video_route_status, ^forwarder, "b", ^old_ref, :interrupted}}, 500
    Forwarder.send_ready(forwarder, "a", self(), :video, 303, :vp8, make_ref())
    forward_video(forwarder, fragment(2, <<0x10, 0, 2>>, marker: true, timestamp: 97_500))
    Forwarder.sync(forwarder)
    refute_receive {_, {:deliver_video, _, _, _, _, _, _}}, 0
    # The retained PC remains occupied across route retirement until consumed.
    Forwarder.video_delivered(forwarder, "b", self(), old_ref, old_credit)
    forward_video(forwarder, fragment(3, <<0x10, 0, 3>>, marker: true, timestamp: 101_250))
    assert_receive {_, {:deliver_video, ^forwarder, "b", current_ref, credit, [_], _}}
    assert current_ref != old_ref

    assert {:ok, %{interruptions: 0, recoveries: 0}} =
             Forwarder.video_route_status(forwarder, "b", self())

    Forwarder.video_delivered(forwarder, "b", self(), old_ref, old_credit)
    Forwarder.video_delivered(forwarder, "b", sink(), current_ref, credit)
    forward_video(forwarder, fragment(4, <<0x10, 0, 4>>, marker: true, timestamp: 105_000))
    Forwarder.sync(forwarder)
    refute_receive {_, {:deliver_video, _, _, _, _, _, _}}, 0
    Forwarder.video_delivered(forwarder, "b", self(), current_ref, credit, :dropped)
    forward_video(forwarder, fragment(5, <<0x10, 1, 5>>, marker: true, timestamp: 108_750))
    Forwarder.sync(forwarder)
    refute_receive {_, {:deliver_video, _, _, _, _, _, _}}, 0
    forward_video(forwarder, fragment(6, <<0x10, 0, 6>>, marker: true, timestamp: 112_500))
    assert_video("b", _)
    Forwarder.session_removed(forwarder, "b", self())
    Forwarder.video_delivered(forwarder, "b", self(), current_ref, credit)
    assert {:error, :not_ready} = Forwarder.video_route_status(forwarder, "b", self())
  end

  @tag :ticket15_recovery
  test "overdue delivery interrupts only its current direction and resumes through a fresh keyframe" do
    forwarder = start_forwarder()
    ready(forwarder, "a", self(), 101)
    ready(forwarder, "b", self(), 202)
    Forwarder.receive_ready(forwarder, "b", self(), :video, :vp8)
    Forwarder.send_ready(forwarder, "a", self(), :video, 303, :vp8)
    forward_video(forwarder, fragment(1, <<0x10, 0, 1>>, marker: true))
    assert_receive {_, {:deliver_video, ^forwarder, "b", ref, credit, [_], _}}
    assert_receive {_, {:video_route_status, ^forwarder, "b", ^ref, :interrupted}}, 500

    assert {:ok, %{state: :interrupted, interruptions: 1, recoveries: 0}} =
             Forwarder.video_route_status(forwarder, "b", self())

    for sequence <- 2..61 do
      forward_video(
        forwarder,
        fragment(sequence, <<0x10, 0, 7>>, marker: true, timestamp: 90_000 + sequence * 3_750)
      )
    end

    Forwarder.sync(forwarder)
    refute_receive {_, {:deliver_video, _, _, _, _, _, _}}, 0
    Forwarder.video_delivered(forwarder, "b", sink(), ref, credit)
    assert {:ok, %{state: :interrupted}} = Forwarder.video_route_status(forwarder, "b", self())
    Forwarder.video_delivered(forwarder, "b", self(), ref, credit)
    assert_receive {_, {:video_route_status, ^forwarder, "b", ^ref, :recovering}}
    assert_receive {_, {:request_keyframe, ^forwarder, "a", 303, _, ^ref}}
    forward_video(forwarder, fragment(61, <<0x10, 0, 7>>, marker: true, timestamp: 318_750))
    forward_video(forwarder, fragment(62, <<0x10, 1, 8>>, marker: true, timestamp: 330_000))
    Forwarder.sync(forwarder)
    refute_receive {_, {:deliver_video, _, _, _, _, _, _}}, 0
    forward_video(forwarder, fragment(63, <<0x10, 0, 9>>, marker: true, timestamp: 333_750))
    assert_video("b", _)

    assert {:ok, %{state: :active, interruptions: 1, recoveries: 1, discarded_packets: 60}} =
             Forwarder.video_route_status(forwarder, "b", self())

    Forwarder.source_ended(forwarder, "a", self(), :video, 303)
    assert {:error, :not_ready} = Forwarder.video_route_status(forwarder, "b", self())
  end

  @tag :ticket13_admission
  test "video waits for a complete reordered frame across sequence wrap" do
    forwarder = start_forwarder()
    ready(forwarder, "a", self(), 101)
    ready(forwarder, "b", self(), 202)
    Forwarder.receive_ready(forwarder, "b", self(), :video, :vp8)
    Forwarder.send_ready(forwarder, "a", self(), :video, 303, :vp8)
    first = ExRTP.Packet.new(<<0x10, 0, 1>>, sequence_number: 65_535, timestamp: 90_000)
    last = ExRTP.Packet.new(<<1, 2>>, sequence_number: 1, timestamp: 90_000, marker: true)
    middle = ExRTP.Packet.new(<<0x11, 3>>, sequence_number: 0, timestamp: 90_000)

    for packet <- [last, first, first] do
      forward_video(forwarder, packet)
    end

    Forwarder.sync(forwarder)
    refute_receive {_, {:deliver_video, _, _, _, _, _, _}}, 0
    forward_video(forwarder, middle)
    assert_receive {_, {:deliver_video, ^forwarder, "b", ref, credit, packets, _}}
    assert packets == [first, middle, last]
    Forwarder.video_delivered(forwarder, "b", self(), ref, credit)
    Forwarder.sync(forwarder)
    forward_video(forwarder, last)
    Forwarder.sync(forwarder)
    refute_receive {_, {:deliver_video, _, _, _, _, _, _}}, 0
  end

  @tag :ticket13_admission
  test "partial, oversized and inconsistent frames gate dependents until a current keyframe" do
    forwarder = start_forwarder()
    ready(forwarder, "a", self(), 101)
    ready(forwarder, "b", self(), 202)
    Forwarder.receive_ready(forwarder, "b", self(), :video, :vp8)
    Forwarder.send_ready(forwarder, "a", self(), :video, 303, :vp8)

    start = fragment(2, <<0x10, 0, 1>>)
    last = fragment(3, <<0, 2>>, marker: true)

    faults = [
      partial: [start, %{last | sequence_number: 4}],
      bytes: burst_fragments(201, 1_490),
      packets: burst_fragments(257, 2),
      oversized: [%{start | payload: <<0x10>> <> :binary.copy(<<0>>, 1_500)}],
      partition: [start, %{last | payload: <<0x01, 2>>}],
      marker: [%{last | sequence_number: 2}, last],
      conflict: [start, %{start | payload: <<0x10, 0, 9>>}, last],
      metadata: [start, %{last | ssrc: 99}],
      missing_frame: []
    ]

    for {_fault, damaged} <- faults do
      Forwarder.send_ready(forwarder, "a", self(), :video, 303, :vp8, make_ref())

      Forwarder.forward_rtp(
        forwarder,
        "a",
        self(),
        :video,
        303,
        fragment(1, <<0x10, 0, 1>>, timestamp: 90_000, marker: true)
      )

      assert_video("b", _)

      for input <- damaged do
        forward_video(forwarder, input)
      end

      Forwarder.sync(forwarder)
      refute_receive {_, {:deliver_video, _, _, _, _, _, _}}, 0

      frame =
        get_in(:sys.get_state(forwarder), [:routes, {:video, "a", 303}, "b", :admission, :frame])

      if frame do
        assert frame.bytes <= 262_144
        assert map_size(frame.packets) <= 256
      end

      dependent = fragment(400, <<0x10, 1, 1>>, timestamp: 97_500, marker: true)
      forward_video(forwarder, dependent)
      Forwarder.sync(forwarder)
      refute_receive {_, {:deliver_video, _, _, _, _, _, _}}, 0
      assert_receive {_, {:request_keyframe, ^forwarder, "a", 303, _, _}}
      # Retiring an incomplete frame and dropping its successor are distinct
      # recovery edges; the actual Session coalesces them to one pending PLI.
      receive do
        {_, {:request_keyframe, ^forwarder, "a", 303, _, _}} -> :ok
      after
        0 -> :ok
      end

      refute_receive {_, {:request_keyframe, ^forwarder, "a", 303, _, _}}, 0

      Forwarder.forward_rtp(
        forwarder,
        "a",
        self(),
        :video,
        303,
        fragment(401, <<0x10, 0, 1>>, timestamp: 101_250, marker: true)
      )

      assert_video("b", _)

      forward_video(forwarder, %{
        dependent
        | sequence_number: 402,
          timestamp: 105_000
      })

      assert_video("b", _)
    end
  end

  @tag :ticket13_admission
  test "idle incomplete video expires and retired route timers cannot occupy the rebuilt route" do
    forwarder = start_forwarder()
    ready(forwarder, "a", self(), 101)
    ready(forwarder, "b", self(), 202)
    Forwarder.receive_ready(forwarder, "b", self(), :video, :vp8)
    Forwarder.send_ready(forwarder, "a", self(), :video, 303, :vp8)
    assert_receive {_, {:video_source_route, ^forwarder, "a", {_, old_ref}}}
    first = ExRTP.Packet.new(<<0x10, 0, 1>>, sequence_number: 10, timestamp: 90_000)
    forward_video(forwarder, first)
    assert_receive {_, {:request_keyframe, ^forwarder, "a", 303, _, ^old_ref}}, 500
    Forwarder.sync(forwarder)

    assert video_route(forwarder).admission.frame == nil

    forward_video(forwarder, %{first | marker: true})
    Forwarder.sync(forwarder)
    refute_receive {_, {:deliver_video, _, _, _, _, _, _}}, 0

    for retirement <- [:off, :source_end, :receiver, :source_replacement, :cleanup] do
      Forwarder.send_ready(forwarder, "a", self(), :video, 303, :vp8, make_ref())
      Forwarder.receive_ready(forwarder, "b", self(), :video, :vp8)
      forward_video(forwarder, first)
      Forwarder.sync(forwarder)
      route = video_route(forwarder)
      assert is_integer(Process.read_timer(route.expiry))

      case retirement do
        action when action in [:off, :source_end] ->
          Forwarder.source_ended(forwarder, "a", self(), :video, 303)

        :receiver ->
          Forwarder.receive_unready(forwarder, "b", self(), :video)

        :source_replacement ->
          ready(forwarder, "a", sink(), 101)

        :cleanup ->
          Forwarder.session_removed(forwarder, "a", self())
      end

      Forwarder.sync(forwarder)
      assert Process.read_timer(route.expiry) == false
      ready(forwarder, "a", self(), 101)
      Forwarder.send_ready(forwarder, "a", self(), :video, 303, :vp8, make_ref())
      Forwarder.receive_ready(forwarder, "b", self(), :video, :vp8)
      # Old fragments/timer cannot complete the new direction's frame.
      send(forwarder, {:expire_video, route.ref, first.timestamp})
      {_, _, retired_source_ref} = route.identity
      Forwarder.forward_rtp(forwarder, "a", self(), :video, 303, retired_source_ref, first)

      forward_video(forwarder, %{
        first
        | payload: <<0, 2>>,
          sequence_number: 11,
          marker: true
      })

      Forwarder.sync(forwarder)
      refute_receive {_, {:deliver_video, _, _, _, _, _, _}}, 0

      forward_video(forwarder, %{
        first
        | sequence_number: 20,
          timestamp: 93_750,
          marker: true
      })

      assert_video("b", _)
    end
  end

  test "keyframe lookup fences removed and replaced route identities" do
    forwarder = start_forwarder()
    destination = sink()
    ready(forwarder, "a", self(), 101)
    ready(forwarder, "b", destination, 202)
    source_ref = make_ref()
    Forwarder.receive_ready(forwarder, "b", destination, :video, :vp8)
    Forwarder.send_ready(forwarder, "a", self(), :video, 303, :vp8, source_ref)
    assert_receive {_, {:video_source_route, ^forwarder, "a", {^source_ref, ref}}}
    assert_receive {:sink, ^destination, {_, {:video_route, ^forwarder, "b", ^ref}}}

    for {id, process, token} <- [
          {"wrong", destination, ref},
          {"b", self(), ref},
          {"b", destination, make_ref()},
          {"a", self(), ref}
        ] do
      Forwarder.request_keyframe(forwarder, id, process, token)
    end

    Forwarder.sync(forwarder)
    refute_receive {_, {:request_keyframe, _, _, _, _, _}}, 0
    Forwarder.request_keyframe(forwarder, "b", destination, ref)
    assert_receive {_, {:request_keyframe, ^forwarder, "a", 303, ^source_ref, ^ref}}

    Forwarder.source_ended(forwarder, "a", self(), :video, 303)
    assert_receive {_, {:video_source_route, ^forwarder, "a", nil}}
    assert_receive {:sink, ^destination, {_, {:video_route, ^forwarder, "b", nil}}}
    Forwarder.request_keyframe(forwarder, "b", destination, ref)
    next_source_ref = make_ref()
    Forwarder.send_ready(forwarder, "a", self(), :video, 303, :vp8, next_source_ref)
    assert_receive {_, {:video_source_route, ^forwarder, "a", {^next_source_ref, next_ref}}}
    refute next_ref == ref

    replacement = sink()
    ready(forwarder, "b", replacement, 202)
    Forwarder.receive_ready(forwarder, "b", replacement, :video, :vp8)
    assert_receive {_, {:video_source_route, ^forwarder, "a", nil}}
    assert_receive {_, {:video_source_route, ^forwarder, "a", {^next_source_ref, replaced_ref}}}
    assert_receive {:sink, ^destination, {_, {:video_route, ^forwarder, "b", nil}}}
    Forwarder.request_keyframe(forwarder, "b", destination, next_ref)
    Forwarder.request_keyframe(forwarder, "b", replacement, next_ref)
    Forwarder.sync(forwarder)
    refute_receive {_, {:request_keyframe, _, _, _, _, _}}, 0
    Forwarder.request_keyframe(forwarder, "b", replacement, replaced_ref)
    assert_receive {_, {:request_keyframe, ^forwarder, "a", 303, ^next_source_ref, ^replaced_ref}}

    source_replacement = sink()
    ready(forwarder, "a", source_replacement, 101)
    replacement_source_ref = make_ref()

    Forwarder.send_ready(
      forwarder,
      "a",
      source_replacement,
      :video,
      505,
      :vp8,
      replacement_source_ref
    )

    assert_receive {_, {:video_source_route, ^forwarder, "a", nil}}

    assert_receive {:sink, ^source_replacement,
                    {_,
                     {:video_source_route, ^forwarder, "a",
                      {^replacement_source_ref, current_ref}}}}

    Forwarder.request_keyframe(forwarder, "b", replacement, replaced_ref)
    Forwarder.request_keyframe(forwarder, "b", replacement, current_ref)

    assert_receive {:sink, ^source_replacement,
                    {_,
                     {:request_keyframe, ^forwarder, "a", 505, ^replacement_source_ref,
                      ^current_ref}}}

    Forwarder.session_removed(forwarder, "a", source_replacement)
    Forwarder.request_keyframe(forwarder, "b", replacement, current_ref)
    Forwarder.sync(forwarder)
    refute_receive {_, {:request_keyframe, _, _, _, _, _}}, 0
    refute_receive {:sink, _, {_, {:request_keyframe, _, _, _, _, _}}}, 0
  end

  test "invalid video packet fields are dropped before the shared munger" do
    forwarder = start_forwarder()
    ready(forwarder, "a", self(), 101)
    ready(forwarder, "b", self(), 202)
    Forwarder.receive_ready(forwarder, "b", self(), :video, :vp8)
    Forwarder.send_ready(forwarder, "a", self(), :video, 303, :vp8)
    valid = video_packet(10, 90_000, 10, 10, 10)

    for bad <- [
          nil,
          %{payload: valid.payload},
          %{valid | payload: nil},
          %{valid | sequence_number: nil},
          %{valid | sequence_number: -1},
          %{valid | sequence_number: 65_536},
          %{valid | timestamp: 1.5},
          %{valid | timestamp: -1},
          %{valid | timestamp: 4_294_967_296}
        ] do
      Forwarder.forward_rtp(forwarder, "a", self(), :video, 303, bad)
    end

    Forwarder.sync(forwarder)
    refute_receive {_, {:deliver_video, _, _, _, _, _, _}}, 0
    Forwarder.forward_rtp(forwarder, "a", self(), :video, 303, valid)
    assert_video("b", ^valid)
    Forwarder.forward_rtp(forwarder, "b", self(), :audio, 202, packet(20, 960))
    assert_receive {_, {:deliver_rtp, "a", :audio, 0, _}}
  end

  test "invalid VP8 descriptors cannot start or advance a current destination timeline" do
    forwarder = start_forwarder()
    ready(forwarder, "a", self(), 101)
    ready(forwarder, "b", self(), 202)
    Forwarder.receive_ready(forwarder, "a", self(), :video, :vp8)
    Forwarder.receive_ready(forwarder, "b", self(), :video, :vp8)
    Forwarder.send_ready(forwarder, "a", self(), :video, 303, :vp8)
    Forwarder.send_ready(forwarder, "b", self(), :video, 404, :vp8)

    for stage <- [:initial, :current, :returned] do
      if stage == :returned do
        Forwarder.source_ended(forwarder, "a", self(), :video, 303)
        Forwarder.send_ready(forwarder, "a", self(), :video, 505, :vp8)
      end

      track = if stage == :returned, do: 505, else: 303

      # Missing extension/optional octets, descriptor-only payload, reserved
      # shapes unsupported by the pinned parser, and L without the required T.
      for payload <- [
            <<>>,
            <<0x80>>,
            <<0x90, 0x80>>,
            <<0x90, 0x80, 0x80>>,
            <<0x90, 0x40>>,
            <<0x90, 0x20>>,
            <<0x90, 0x10>>,
            <<0x90, 0xF0, 0x80, 1, 2>>,
            <<0x10>>,
            <<0x50, 0>>,
            <<0x18, 0>>,
            <<0x90, 1, 0>>,
            <<0x90, 0x40, 1, 0>>,
            <<0x90, 0xD0, 100, 100, 1, 0>>
          ] do
        bad = ExRTP.Packet.new(payload, sequence_number: 30_000, timestamp: 3_000_000)
        Forwarder.forward_rtp(forwarder, "a", self(), :video, track, bad)
      end

      Forwarder.sync(forwarder)
      refute_receive {_, {:deliver_video, _, _, _, _, _, _}}, 0

      sequence =
        case stage do
          :initial -> 10
          :current -> 11
          :returned -> 500
        end

      expected =
        case stage do
          :initial -> 10
          :current -> 11
          :returned -> 12
        end

      valid = video_packet(sequence, 90_000 + sequence * 3_750, sequence, expected, expected)
      Forwarder.forward_rtp(forwarder, "a", self(), :video, track, valid)
      assert_video("b", delivered)
      assert delivered.sequence_number == expected

      assert {:ok, %{picture_id: picture, tl0picidx: tl0, keyidx: key}} =
               ExWebRTC.RTP.VP8.Payload.parse(delivered.payload)

      assert picture == expected
      assert tl0 == expected
      assert key == expected

      reverse =
        ExRTP.Packet.new(<<0x10, 0, 9>>,
          sequence_number: expected + 20,
          timestamp: 90_000 + expected * 3_750,
          marker: true
        )

      Forwarder.forward_rtp(forwarder, "b", self(), :video, 404, reverse)
      assert_video("a", _)
      Forwarder.forward_rtp(forwarder, "a", self(), :audio, 101, packet(20, 960))
      assert_receive {_, {:deliver_rtp, "b", :audio, 0, _}}
      Forwarder.forward_rtp(forwarder, "b", self(), :audio, 202, packet(30, 1_920))
      assert_receive {_, {:deliver_rtp, "a", :audio, 0, _}}
    end
  end

  test "supported VP8 optional layouts remain admissible as complete frames" do
    forwarder = start_forwarder()
    ready(forwarder, "a", self(), 101)
    ready(forwarder, "b", self(), 202)
    Forwarder.receive_ready(forwarder, "b", self(), :video, :vp8)
    Forwarder.send_ready(forwarder, "a", self(), :video, 303, :vp8)

    # Independently specified RFC 7741 wire forms: no extensions, empty X,
    # short/long PictureID, T-only, K-only (including Y), and L/T/K together.
    payloads = [
      {<<0x10, 0, 1>>, nil, nil, nil, nil},
      {<<0x90, 0, 0, 1>>, nil, nil, nil, nil},
      {<<0x90, 0x80, 17, 0, 1>>, 17, nil, nil, nil},
      {<<0x90, 0x80, 0x80, 18, 0, 1>>, 18, nil, nil, nil},
      {<<0x90, 0x20, 0x20, 0, 1>>, nil, nil, 0, nil},
      {<<0x90, 0x10, 0xA3, 0, 1>>, nil, nil, nil, 3},
      {<<0x90, 0x70, 4, 5, 0, 1>>, nil, 4, 0, 5}
    ]

    for {{payload, picture, tl0, tid, key}, sequence} <- Enum.with_index(payloads, 1) do
      input =
        ExRTP.Packet.new(payload,
          sequence_number: sequence,
          timestamp: 90_000 + sequence * 3_750,
          marker: true
        )

      Forwarder.forward_rtp(forwarder, "a", self(), :video, 303, input)
      assert_video("b", output)
      assert output.sequence_number == sequence
      assert {:ok, descriptor} = ExWebRTC.RTP.VP8.Payload.parse(output.payload)
      assert descriptor.picture_id == picture
      assert descriptor.tl0picidx == tl0
      assert descriptor.tid == tid
      assert descriptor.keyidx == key
      assert descriptor.payload == <<0, 1>>
    end
  end

  test "foreign and retired video identities cannot poison the returned current route" do
    forwarder = start_forwarder()
    unrelated = start_forwarder()
    old = sink()
    ready(forwarder, "a", old, 101)
    ready(forwarder, "b", self(), 202)
    Forwarder.receive_ready(forwarder, "b", self(), :video, :vp8)
    Forwarder.send_ready(forwarder, "a", old, :video, 303, :vp8)
    first = video_packet(10, 90_000, 10, 10, 10)
    Forwarder.forward_rtp(forwarder, "a", old, :video, 303, first)
    assert_video("b", ^first)

    ready(forwarder, "a", self(), 101)
    Forwarder.send_ready(forwarder, "a", self(), :video, 505, :vp8)
    poison = video_packet(30_000, 3_000_000, 20_000, 200, 20)

    for {id, process, track} <- [
          {"foreign", self(), 505},
          {"b", self(), 505},
          {"a", old, 505},
          {"a", self(), 303},
          {"a", self(), 999}
        ] do
      Forwarder.forward_rtp(forwarder, id, process, :video, track, poison)
    end

    Forwarder.forward_rtp(unrelated, "a", self(), :video, 505, poison)
    Forwarder.forward_rtp(forwarder, "a", 505, poison)
    Forwarder.source_ended(forwarder, "a", old, :video, 505)
    Forwarder.session_removed(forwarder, "a", old)
    Forwarder.sync(forwarder)
    Forwarder.sync(unrelated)
    refute_receive {_, {:deliver_video, _, _, _, _, _, _}}, 0

    current = video_packet(500, 900_000, 50, 50, 5)
    Forwarder.forward_rtp(forwarder, "a", self(), :video, 505, current)
    assert_video("b", output)
    assert output.sequence_number == 11
    assert output.timestamp > first.timestamp

    assert {:ok, %{picture_id: 11, tl0picidx: 11, keyidx: 11}} =
             ExWebRTC.RTP.VP8.Payload.parse(output.payload)
  end

  test "valid camera return may omit optional VP8 fields without losing audio or continuity" do
    forwarder = start_forwarder()
    ready(forwarder, "a", self(), 101)
    ready(forwarder, "b", self(), 202)
    Forwarder.receive_ready(forwarder, "b", self(), :video, :vp8)
    Forwarder.send_ready(forwarder, "a", self(), :video, 303, :vp8)

    Forwarder.forward_rtp(
      forwarder,
      "a",
      self(),
      :video,
      303,
      video_packet(10, 90_000, 10, 10, 10)
    )

    assert_video("b", _)
    Forwarder.source_ended(forwarder, "a", self(), :video, 303)
    Forwarder.send_ready(forwarder, "a", self(), :video, 303, :vp8)

    plain =
      ExRTP.Packet.new(<<0x10, 0, 2>>, sequence_number: 500, timestamp: 900_000, marker: true)

    Forwarder.forward_rtp(forwarder, "a", self(), :video, 303, plain)
    assert_video("b", returned)
    assert returned.sequence_number == 11
    assert returned.payload == plain.payload
    Forwarder.forward_rtp(forwarder, "a", self(), :audio, 101, packet(20, 960))
    assert_receive {_, {:deliver_rtp, "b", :audio, 0, _}}

    Forwarder.forward_rtp(
      forwarder,
      "a",
      self(),
      :video,
      303,
      video_packet(501, 903_750, 50, 50, 5)
    )

    assert_video("b", described)
    assert described.sequence_number == 12

    assert {:ok, %{picture_id: 11, tl0picidx: 11, keyidx: 11}} =
             ExWebRTC.RTP.VP8.Payload.parse(described.payload)

    Forwarder.forward_rtp(
      forwarder,
      "a",
      self(),
      :video,
      303,
      video_packet(502, 907_500, 52, 52, 7)
    )

    assert_video("b", next)
    assert next.sequence_number == 13
    assert next.timestamp == described.timestamp + 3_750

    assert {:ok, %{picture_id: 13, tl0picidx: 13, keyidx: 13}} =
             ExWebRTC.RTP.VP8.Payload.parse(next.payload)
  end

  test "fresh camera return preserves the retained destination RTP and VP8 timeline" do
    forwarder = start_forwarder()
    ready(forwarder, "a", self(), 101)
    ready(forwarder, "b", self(), 202)
    Forwarder.receive_ready(forwarder, "a", self(), :video, :vp8)
    Forwarder.receive_ready(forwarder, "b", self(), :video, :vp8)
    Forwarder.send_ready(forwarder, "a", self(), :video, 303, :vp8)
    Forwarder.send_ready(forwarder, "b", self(), :video, 404, :vp8)
    first = video_packet(65_535, 90_000, 32_767, 255, 31)
    Forwarder.forward_rtp(forwarder, "a", self(), :video, 303, first)
    assert_video("b", ^first)

    Forwarder.source_ended(forwarder, "a", self(), :video, 303)
    Forwarder.forward_rtp(forwarder, "a", self(), :video, 303, first)
    Forwarder.sync(forwarder)
    refute_receive {_, {:deliver_video, _, "b", _, _, _, _}}, 0
    reverse = video_packet(100, 180_000, 100, 100, 10)
    Forwarder.forward_rtp(forwarder, "b", self(), :video, 404, reverse)
    assert_video("a", ^reverse)
    Forwarder.forward_rtp(forwarder, "a", self(), :audio, 101, packet(20, 960))
    assert_receive {_, {:deliver_rtp, "b", :audio, 0, _}}

    Forwarder.send_ready(forwarder, "a", self(), :video, 303, :vp8)

    Forwarder.forward_rtp(
      forwarder,
      "a",
      self(),
      :video,
      303,
      video_packet(500, 900_000, 50, 50, 5)
    )

    assert_video("b", returned)
    assert returned.sequence_number == 0
    assert returned.timestamp > 90_000
    refute returned.timestamp == 900_000

    assert {:ok, %{picture_id: 0, tl0picidx: 0, keyidx: 0}} =
             ExWebRTC.RTP.VP8.Payload.parse(returned.payload)

    # Duplicate readiness does not restart continuity for each publication.
    Forwarder.send_ready(forwarder, "a", self(), :video, 303, :vp8)

    Forwarder.forward_rtp(
      forwarder,
      "a",
      self(),
      :video,
      303,
      video_packet(501, 903_750, 51, 51, 6)
    )

    assert_video("b", next)
    assert next.sequence_number == 1
    assert next.timestamp == returned.timestamp + 3_750

    assert {:ok, %{picture_id: 1, tl0picidx: 1, keyidx: 1}} =
             ExWebRTC.RTP.VP8.Payload.parse(next.payload)
  end

  test "video route rebuild and source replacement retain only the current receiver timeline" do
    forwarder = start_forwarder()
    old_source = sink()
    ready(forwarder, "a", old_source, 101)
    ready(forwarder, "b", self(), 202)
    Forwarder.receive_ready(forwarder, "b", self(), :video, :vp8)
    Forwarder.send_ready(forwarder, "a", old_source, :video, 303, :vp8)
    first = video_packet(10, 90_000, 10, 10, 10)
    Forwarder.forward_rtp(forwarder, "a", old_source, :video, 303, first)
    assert_video("b", ^first)

    Forwarder.receive_unready(forwarder, "b", self(), :video)
    Forwarder.forward_rtp(forwarder, "a", old_source, :video, 303, first)
    Forwarder.sync(forwarder)
    refute_receive {_, {:deliver_video, _, "b", _, _, _, _}}, 0
    Forwarder.receive_ready(forwarder, "b", self(), :video, :vp8)

    Forwarder.forward_rtp(
      forwarder,
      "a",
      old_source,
      :video,
      303,
      video_packet(100, 900_000, 50, 50, 5)
    )

    assert_video("b", rebuilt)
    assert rebuilt.sequence_number == 11
    assert rebuilt.timestamp > first.timestamp

    assert {:ok, %{picture_id: 11, tl0picidx: 11, keyidx: 11}} =
             ExWebRTC.RTP.VP8.Payload.parse(rebuilt.payload)

    ready(forwarder, "a", self(), 101)
    Forwarder.send_ready(forwarder, "a", self(), :video, 303, :vp8)
    # Same IDs cannot admit the old process's packets, withdrawal or removal.
    Forwarder.source_ended(forwarder, "a", old_source, :video, 303)
    Forwarder.session_removed(forwarder, "a", old_source)
    Forwarder.forward_rtp(forwarder, "a", old_source, :video, 303, first)
    Forwarder.sync(forwarder)
    refute_receive {_, {:deliver_video, _, "b", _, _, _, _}}, 0

    Forwarder.forward_rtp(
      forwarder,
      "a",
      self(),
      :video,
      303,
      video_packet(500, 1_800_000, 100, 100, 20)
    )

    assert_video("b", replacement)
    assert replacement.sequence_number == 12
    assert replacement.timestamp > rebuilt.timestamp

    assert {:ok, %{picture_id: 12, tl0picidx: 12, keyidx: 12}} =
             ExWebRTC.RTP.VP8.Payload.parse(replacement.payload)

    # Removing the receiver discards its timeline, even if its ID/PID is reused.
    Forwarder.session_removed(forwarder, "b", self())
    ready(forwarder, "b", self(), 202)
    Forwarder.receive_ready(forwarder, "b", self(), :video, :vp8)
    fresh = video_packet(700, 2_700_000, 200, 200, 25)
    Forwarder.forward_rtp(forwarder, "a", self(), :video, 303, fresh)
    assert_video("b", ^fresh)

    receiver = sink()
    ready(forwarder, "b", receiver, 202)
    Forwarder.receive_ready(forwarder, "b", receiver, :video, :vp8)
    Forwarder.receive_ready(forwarder, "b", self(), :video, :vp8)
    Forwarder.session_removed(forwarder, "b", self())
    Forwarder.forward_rtp(forwarder, "a", self(), :video, 303, first)
    assert_receive {:sink, ^receiver, {_, {:deliver_rtp, "b", :video, 0, ^first}}}
    refute_receive {_, {:deliver_video, _, "b", _, _, _, _}}, 0
  end

  test "VP8 flows only to the opposite current video receiver and off preserves audio" do
    forwarder = start_forwarder()
    ready(forwarder, "a", self(), 101)
    ready(forwarder, "b", self(), 202)
    Forwarder.receive_ready(forwarder, "b", self(), :video, :vp8)
    Forwarder.send_ready(forwarder, "a", self(), :video, 303, :vp8)
    # Chromium can send padding-only probes before the first encoded frame.
    Forwarder.forward_rtp(forwarder, "a", self(), :video, 303, ExRTP.Packet.new(<<>>))
    Forwarder.forward_rtp(forwarder, "a", self(), :video, 303, ExRTP.Packet.new(<<0x80>>))
    video = ExRTP.Packet.new(<<0x10, 0, 1>>, sequence_number: 10, timestamp: 90_000, marker: true)
    Forwarder.forward_rtp(forwarder, "a", self(), :video, 303, video)
    assert_video("b", ^video)
    refute_receive {_, {:deliver_video, _, "a", _, _, _, _}}, 0

    Forwarder.forward_rtp(forwarder, "a", sink(), :video, 303, video)
    Forwarder.forward_rtp(forwarder, "a", self(), :video, 999, video)
    Forwarder.source_ended(forwarder, "a", self(), :video, 303)
    Forwarder.forward_rtp(forwarder, "a", self(), :video, 303, video)
    Forwarder.sync(forwarder)
    refute_receive {_, {:deliver_video, _, _, _, _, _, _}}, 0
    Forwarder.forward_rtp(forwarder, "a", self(), :audio, 101, packet(20, 960))
    assert_receive {_, {:deliver_rtp, "b", :audio, 0, _}}
  end

  test "video readiness loss and duplicate transitions preserve both audio directions" do
    forwarder = start_forwarder()
    ready(forwarder, "a", self(), 101)
    ready(forwarder, "b", self(), 202)

    for _ <- 1..2 do
      Forwarder.receive_ready(forwarder, "a", self(), :video, :vp8)
      Forwarder.send_ready(forwarder, "a", self(), :video, 303, :vp8)
      Forwarder.source_ended(forwarder, "a", self(), :video, 303)
      Forwarder.receive_unready(forwarder, "b", self(), :video)
    end

    # Deliberately reuse an audio track ID under the wrong kind/codec.
    Forwarder.send_ready(forwarder, "a", self(), :video, 101, :opus)
    Forwarder.source_ended(forwarder, "a", self(), :video, 101)
    Forwarder.receive_ready(forwarder, "b", self(), :audio, :vp8)
    Forwarder.forward_rtp(forwarder, "a", self(), :video, 101, packet(1, 960))
    Forwarder.sync(forwarder)
    refute_receive {_, {:deliver_rtp, _, :audio, _, _}}, 0
    refute_receive {_, {:deliver_video, _, _, _, _, _, _}}, 0

    Forwarder.forward_rtp(forwarder, "a", self(), 101, packet(10, 960))
    assert_receive {_, {:deliver_rtp, "b", :audio, 0, first}}
    assert first.sequence_number == 10
    Forwarder.forward_rtp(forwarder, "b", self(), :audio, 202, packet(20, 1_920))
    assert_receive {_, {:deliver_rtp, "a", :audio, 0, second}}
    assert second.sequence_number == 20
  end

  test "stale kind-specific withdrawals cannot disable a replacement audio source" do
    forwarder = start_forwarder()
    old = sink()
    ready(forwarder, "a", old, 101)
    ready(forwarder, "b", self(), 202)
    ready(forwarder, "a", self(), 303)

    for kind <- [:audio, :video] do
      Forwarder.receive_unready(forwarder, "a", old, kind)
      Forwarder.source_ended(forwarder, "a", old, kind, 303)
      Forwarder.receive_unready(forwarder, "foreign", self(), kind)
      Forwarder.source_ended(forwarder, "a", self(), kind, 101)
    end

    first = packet(10, 960)
    Forwarder.forward_rtp(forwarder, "a", self(), :audio, 303, first)
    assert_receive {_, {:deliver_rtp, "b", :audio, 0, ^first}}

    # A current audio failure still withdraws audio even with video marked ready.
    Forwarder.receive_ready(forwarder, "a", self(), :video, :vp8)
    Forwarder.receive_unready(forwarder, "a", self(), :audio)
    Forwarder.forward_rtp(forwarder, "a", self(), :audio, 303, packet(11, 1_920))
    Forwarder.forward_rtp(forwarder, "b", self(), :audio, 202, packet(20, 2_880))
    Forwarder.sync(forwarder)
    refute_receive {_, {:deliver_rtp, _, _, _, _}}, 0

    ready(forwarder, "a", self(), 303)
    Forwarder.forward_rtp(forwarder, "a", self(), :audio, 303, packet(12, 3_840))
    assert_receive {_, {:deliver_rtp, "b", :audio, 0, resumed}}
    assert resumed.sequence_number == 11
  end

  test "readiness withdraws both directions and reconnect preserves the destination timeline" do
    forwarder = start_forwarder()
    ready(forwarder, "a", self(), 101)
    ready(forwarder, "b", self(), 202)
    first = packet(10, 960)
    Forwarder.forward_rtp(forwarder, "a", self(), 101, first)
    assert_receive {_, {:deliver_rtp, "b", :audio, 0, delivered}}
    assert delivered.sequence_number == 10

    Forwarder.receive_unready(forwarder, "b", self())
    Forwarder.forward_rtp(forwarder, "a", self(), 101, packet(11, 1_920))
    Forwarder.forward_rtp(forwarder, "b", self(), 202, packet(20, 2_880))
    Forwarder.sync(forwarder)
    refute_receive {_, {:deliver_rtp, _, :audio, _, _}}, 0

    # The retained destination resumes with a replaced input track/timeline.
    ready(forwarder, "b", self(), 202)
    Forwarder.source_ended(forwarder, "a", self(), 101)
    Forwarder.send_ready(forwarder, "a", self(), 303, :opus)
    Forwarder.forward_rtp(forwarder, "a", self(), 303, packet(500, 900_000))
    assert_receive {_, {:deliver_rtp, "b", :audio, 0, resumed}}
    assert resumed.sequence_number == 11
    assert resumed.timestamp > delivered.timestamp
    refute resumed.timestamp == 900_000
  end

  test "only exact ready membership forwards, with no self or cross-target delivery" do
    forwarder = start_forwarder()
    unrelated = start_forwarder()
    ready(forwarder, "a", self(), 101)
    ready(unrelated, "other", self(), 101)
    first = packet(10, 960)
    Forwarder.forward_rtp(forwarder, "a", self(), 101, first)
    Forwarder.sync(forwarder)
    refute_receive {_, {:deliver_rtp, _, :audio, _, _}}, 0

    assert :ok = Forwarder.session_started(forwarder, "b", self())
    Forwarder.forward_rtp(forwarder, "a", self(), 101, first)
    Forwarder.sync(forwarder)
    refute_receive {_, {:deliver_rtp, _, :audio, _, _}}, 0
    ready(forwarder, "b", self(), 202)
    assert {:error, :full} = Forwarder.session_started(forwarder, "third", self())

    stranger = sink()

    for {id, session, track} <- [{"a", stranger, 101}, {"a", self(), 999}, {"other", self(), 101}] do
      Forwarder.forward_rtp(forwarder, id, session, track, first)
    end

    Forwarder.forward_rtp(forwarder, "a", 101, first)
    Forwarder.sync(forwarder)
    refute_receive {_, {:deliver_rtp, _, :audio, _, _}}, 0

    Forwarder.forward_rtp(forwarder, "a", self(), 101, first)
    assert_receive {_, {:deliver_rtp, "b", :audio, 0, ^first}}
    refute_receive {_, {:deliver_rtp, _, :audio, _, _}}, 0
  end

  test "retired destination and stale readiness cannot reach a replacement" do
    forwarder = start_forwarder()
    old = sink()
    ready(forwarder, "a", self(), 101)
    ready(forwarder, "b", old, 202)
    first = packet(10, 960)
    Forwarder.forward_rtp(forwarder, "a", self(), 101, first)
    assert_receive {:sink, ^old, {_, {:deliver_rtp, "b", :audio, 0, ^first}}}

    Forwarder.session_removed(forwarder, "b", old)
    Forwarder.forward_rtp(forwarder, "a", self(), 101, first)
    Forwarder.sync(forwarder)
    refute_receive {:sink, ^old, _}, 100

    replacement = sink()
    # Reuse the track number deliberately: the old PID must still be rejected.
    ready(forwarder, "b", replacement, 202)
    Forwarder.session_removed(forwarder, "b", old)
    Forwarder.receive_ready(forwarder, "b", old, :opus)
    Forwarder.send_ready(forwarder, "b", old, 202, :opus)
    Forwarder.forward_rtp(forwarder, "b", old, 202, first)
    Forwarder.forward_rtp(forwarder, "a", self(), 101, packet(11, 1_920))
    assert_receive {:sink, ^replacement, {_, {:deliver_rtp, "b", :audio, 0, delivered}}}
    assert delivered.sequence_number == 11
    refute_receive {:sink, ^old, _}, 100
    refute_receive {_, {:deliver_rtp, "a", :audio, _, _}}, 0
  end

  defp sink do
    parent = self()
    start_supervised!(%{id: make_ref(), start: {Task, :start_link, [fn -> relay(parent) end]}})
  end

  defp relay(parent) do
    receive do
      {tag, {:deliver_video, forwarder, id, ref, credit, packets, _}} ->
        for packet <- packets,
            do: send(parent, {:sink, self(), {tag, {:deliver_rtp, id, :video, 0, packet}}})

        Forwarder.video_delivered(forwarder, id, self(), ref, credit)
        relay(parent)

      message ->
        send(parent, {:sink, self(), message})
        relay(parent)
    end
  end

  defp start_forwarder do
    start_supervised!(%{
      id: make_ref(),
      start: {Forwarder, :start_call_link, [Ecto.UUID.generate(), make_ref()]}
    })
  end

  defp forward_video(forwarder, packet),
    do: Forwarder.forward_rtp(forwarder, "a", self(), :video, 303, packet)

  defp video_route(forwarder),
    do: get_in(:sys.get_state(forwarder), [:routes, {:video, "a", 303}, "b"])

  defp fragment(sequence, payload, opts \\ []) do
    ExRTP.Packet.new(payload, Keyword.merge([sequence_number: sequence, timestamp: 93_750], opts))
  end

  defp burst_fragments(count, bytes) do
    for offset <- 0..(count - 1) do
      fragment(
        2 + offset,
        <<if(offset == 0, do: 0x10, else: 0)>> <> :binary.copy(<<0>>, bytes - 1)
      )
    end
  end

  defp ready(forwarder, id, session, track) do
    assert :ok = Forwarder.session_started(forwarder, id, session)
    Forwarder.receive_ready(forwarder, id, session, :opus)
    Forwarder.send_ready(forwarder, id, session, track, :opus)
    Forwarder.sync(forwarder)
  end

  defp packet(sequence, timestamp),
    do: ExRTP.Packet.new(<<0xF8, 0xFF, 0xFE>>, sequence_number: sequence, timestamp: timestamp)

  defp video_packet(sequence, timestamp, picture, tl0, key) do
    payload =
      ExWebRTC.RTP.VP8.Payload.serialize(%ExWebRTC.RTP.VP8.Payload{
        n: 0,
        s: 1,
        pid: 0,
        picture_id: picture,
        tl0picidx: tl0,
        tid: 0,
        y: 0,
        keyidx: key,
        payload: <<0, 1>>
      })

    ExRTP.Packet.new(payload, sequence_number: sequence, timestamp: timestamp, marker: true)
  end
end
