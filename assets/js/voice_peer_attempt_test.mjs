import assert from "node:assert/strict"
import test from "node:test"

import {createVoicePeerAttempt} from "./voice_peer_attempt.js"

class FakeMediaStream {
  constructor(tracks = []) {
    this.tracks = [...tracks]
  }

  addTrack(track) {
    if (!this.tracks.includes(track)) this.tracks.push(track)
  }

  getTracks() {
    return [...this.tracks]
  }

  removeTrack(track) {
    this.tracks = this.tracks.filter(candidate => candidate !== track)
  }
}

globalThis.MediaStream = FakeMediaStream

function deferred() {
  let resolve
  let reject
  const promise = new Promise((nextResolve, nextReject) => {
    resolve = nextResolve
    reject = nextReject
  })

  return {promise, reject, resolve}
}

function fakeClock() {
  let elapsed = 0
  let nextId = 0
  const timers = new Map()

  return {
    advance(milliseconds) {
      const target = elapsed + milliseconds

      while (true) {
        const due = [...timers.entries()]
          .filter(([, timer]) => timer.at <= target)
          .sort(([, left], [, right]) => left.at - right.at)[0]
        if (!due) break

        const [id, timer] = due
        timers.delete(id)
        elapsed = timer.at
        timer.callback()
      }

      elapsed = target
    },
    clearTimeout(id) { timers.delete(id) },
    setTimeout(callback, delay) {
      const id = ++nextId
      timers.set(id, {at: elapsed + delay, callback})
      return id
    },
  }
}

function fakePeerConnection() {
  const handlers = new Map()

  return {
    addedCandidates: [],
    addedTransceivers: [],
    closed: false,
    connectionState: "new",
    addEventListener(event, callback) { handlers.set(event, callback) },
    addIceCandidate(candidate) { this.addedCandidates.push(candidate); return Promise.resolve() },
    addTransceiver(kindOrTrack, init) {
      const transceiver = {
        direction: init.direction,
        receiver: {track: remoteTrack(`remote-${this.addedTransceivers.length}`)},
        sender: {track: typeof kindOrTrack === "string" ? null : kindOrTrack},
      }
      this.addedTransceivers.push(transceiver)
      return transceiver
    },
    close() { this.closed = true },
    createOffer() { return Promise.resolve({type: "offer", sdp: "browser-offer"}) },
    getStats() { return Promise.resolve(new Map()) },
    setLocalDescription(description) { this.localDescription = description; return Promise.resolve() },
    setRemoteDescription(description) { this.remoteDescription = description; return Promise.resolve() },
    emit(event, payload) { handlers.get(event)?.(payload) },
  }
}

function remoteTrack(id) {
  const handlers = new Map()

  return {
    id,
    kind: "audio",
    addEventListener(event, callback) { handlers.set(event, callback) },
    removeEventListener(event) { handlers.delete(event) },
    hasListener(event) { return handlers.has(event) },
    end() { handlers.get("ended")?.() },
  }
}

function remoteAudio({play = () => Promise.resolve()} = {}) {
  return {
    autoplay: false,
    pauseCalls: 0,
    play,
    playCalls: 0,
    playsInline: false,
    srcObject: null,
    pause() { this.pauseCalls += 1 },
  }
}

function disabledAdmission(overrides = {}) {
  return {
    signaling_session_id: "server-session",
    occupancy: 1,
    capacity: 5,
    ice_config: {ice_mode: "disabled", ice_servers: [], ice_transport_policy: "all"},
    ...overrides,
  }
}

function standardAdmission(overrides = {}) {
  return disabledAdmission({
    ice_config: {
      ice_servers: [
        {urls: ["stun:stun.example.test:3478"]},
        {
          urls: [
            "turn:turn.example.test:3478?transport=udp",
            "turn:turn.example.test:3478?transport=tcp",
            "turns:turn.example.test:5349?transport=tcp",
          ],
          username: "temporary-user",
          credential: "temporary-credential",
        },
      ],
      ice_transport_policy: "all",
      ice_mode: "standard",
    },
    ...overrides,
  })
}

function turnOnlyAdmission(overrides = {}) {
  return disabledAdmission({
    ice_config: {
      ice_servers: [
        {
          urls: [
            "turn:turn.example.test:3478?transport=udp",
            "turn:turn.example.test:3478?transport=tcp",
            "turns:turn.example.test:5349?transport=tcp",
          ],
          username: "temporary-user",
          credential: "temporary-credential",
        },
      ],
      ice_transport_policy: "relay",
      ice_mode: "turn_only",
    },
    ...overrides,
  })
}

function selectedRouteStats({localType = "host", remoteType = "host", localProtocol = "udp", remoteProtocol = localProtocol} = {}) {
  return new Map([
    ["transport", {id: "forbidden-transport-id", type: "transport", selectedCandidatePairId: "selected-pair"}],
    ["selected-pair", {id: "forbidden-pair-id", type: "candidate-pair", localCandidateId: "local", remoteCandidateId: "remote", url: "turn:forbidden.example.test"}],
    ["local", {id: "forbidden-local-id", type: "local-candidate", candidateType: localType, protocol: localProtocol, address: "forbidden-address", port: 50_000, foundation: "forbidden-foundation", usernameFragment: "forbidden-ufrag"}],
    ["remote", {id: "forbidden-remote-id", type: "remote-candidate", candidateType: remoteType, protocol: remoteProtocol, address: "forbidden-remote", port: 34_789, relatedAddress: "forbidden-related-address", relatedPort: 34_790, credential: "forbidden-credential", sdp: "forbidden-sdp"}],
  ])
}

test("reports only the standardized selected ICE route and deduplicates unchanged categories", async () => {
  const {peer, signaling} = attemptFixture()
  const diagnostics = []
  signaling.reportIceRoute = diagnostic => diagnostics.push(diagnostic)
  peer.getStats = async () => selectedRouteStats({remoteType: "relay"})
  const attempt = createVoicePeerAttempt({
    PeerConnection: class { constructor() { return peer } },
    negotiationId: () => "browser-negotiation",
    now: () => 25,
    signaling,
  })

  await attempt.connect({channelId: "voice-1", track: {id: "microphone"}})
  peer.connectionState = "connected"
  peer.emit("connectionstatechange")
  await Promise.resolve()
  peer.emit("connectionstatechange")
  await Promise.resolve()

  assert.deepEqual(diagnostics, [{
    signaling_session_id: "server-session",
    route_category: "turn_relay",
    protocol: "udp",
    duration_ms: 0,
  }])
  assert.equal(JSON.stringify(diagnostics).includes("forbidden"), false)
})

test("emits one new diagnostic when the selected route category later changes", async () => {
  const {peer, signaling} = attemptFixture()
  const diagnostics = []
  const reports = [selectedRouteStats(), selectedRouteStats({remoteType: "relay"})]
  peer.getStats = async () => reports.shift()
  signaling.reportIceRoute = diagnostic => diagnostics.push(diagnostic)
  const attempt = createVoicePeerAttempt({
    PeerConnection: class { constructor() { return peer } },
    negotiationId: () => "browser-negotiation",
    signaling,
  })

  await attempt.connect({channelId: "voice-1", track: {id: "microphone"}})
  let selectedPairChanged
  peer.addedTransceivers[0].sender.transport = {
    iceTransport: {
      addEventListener(_event, callback) { selectedPairChanged = callback },
      removeEventListener() {},
    },
  }
  peer.connectionState = "connected"
  peer.emit("connectionstatechange")
  await Promise.resolve()
  selectedPairChanged()
  await Promise.resolve()

  assert.deepEqual(diagnostics.map(({route_category}) => route_category), ["host_direct", "turn_relay"])
})

test("ignores an older selected-route observation that completes after a newer one", async () => {
  const {peer, signaling} = attemptFixture()
  const diagnostics = []
  const older = deferred()
  const newer = deferred()
  const reports = [older.promise, newer.promise]
  peer.getStats = () => reports.shift()
  signaling.reportIceRoute = diagnostic => diagnostics.push(diagnostic)
  const attempt = createVoicePeerAttempt({
    PeerConnection: class { constructor() { return peer } },
    negotiationId: () => "browser-negotiation",
    signaling,
  })

  await attempt.connect({channelId: "voice-1", track: {id: "microphone"}})
  peer.connectionState = "connected"
  peer.emit("connectionstatechange")
  peer.emit("connectionstatechange")

  newer.resolve(selectedRouteStats({remoteType: "relay"}))
  await Promise.resolve()
  older.resolve(selectedRouteStats())
  await Promise.resolve()

  assert.deepEqual(diagnostics.map(({route_category}) => route_category), ["turn_relay"])
})

test("classifies every selected route category with exact precedence and bounded protocol", async () => {
  const cases = [
    [{localType: "host", remoteType: "host"}, "host_direct", "udp"],
    [{localType: "host", remoteType: "srflx"}, "reflexive_direct", "udp"],
    [{localType: "prflx", remoteType: "relay"}, "turn_relay", "udp"],
    [{localType: "host", remoteType: "unsupported"}, "unknown", "udp"],
    [{localType: "host", remoteType: "host", remoteProtocol: "tcp"}, "host_direct", "unknown"],
  ]

  for (const [statsOptions, route_category, protocol] of cases) {
    const {peer, signaling} = attemptFixture()
    const diagnostics = []
    signaling.reportIceRoute = diagnostic => diagnostics.push(diagnostic)
    peer.getStats = async () => selectedRouteStats(statsOptions)
    const attempt = createVoicePeerAttempt({
      PeerConnection: class { constructor() { return peer } },
      negotiationId: () => "browser-negotiation",
      signaling,
    })
    await attempt.connect({channelId: "voice-1", track: {id: "microphone"}})
    peer.connectionState = "connected"
    peer.emit("connectionstatechange")
    await Promise.resolve()

    assert.equal(diagnostics[0].route_category, route_category)
    assert.equal(diagnostics[0].protocol, protocol)
  }
})

test("uses only the transport-selected pair even when an unselected relay pair exists", async () => {
  const {peer, signaling} = attemptFixture()
  const diagnostics = []
  const stats = selectedRouteStats()
  stats.set("relay-pair", {id: "relay-pair", type: "candidate-pair", localCandidateId: "relay", remoteCandidateId: "remote"})
  stats.set("relay", {id: "relay", type: "local-candidate", candidateType: "relay", protocol: "udp"})
  peer.getStats = async () => stats
  signaling.reportIceRoute = diagnostic => diagnostics.push(diagnostic)
  const attempt = createVoicePeerAttempt({
    PeerConnection: class { constructor() { return peer } },
    negotiationId: () => "browser-negotiation",
    signaling,
  })

  await attempt.connect({channelId: "voice-1", track: {id: "microphone"}})
  peer.connectionState = "connected"
  peer.emit("connectionstatechange")
  await Promise.resolve()

  assert.equal(diagnostics[0].route_category, "host_direct")
})

test("stats rejection reports unknown without ending Voice and stale completion after leave emits nothing", async () => {
  const {peer, signaling} = attemptFixture()
  const diagnostics = []
  signaling.reportIceRoute = diagnostic => diagnostics.push(diagnostic)
  peer.getStats = async () => { throw new Error("forbidden raw stats failure") }
  const attempt = createVoicePeerAttempt({
    PeerConnection: class { constructor() { return peer } },
    negotiationId: () => "browser-negotiation",
    signaling,
  })
  await attempt.connect({channelId: "voice-1", track: {id: "microphone"}})
  peer.connectionState = "connected"
  peer.emit("connectionstatechange")
  await Promise.resolve()
  assert.equal(peer.closed, false)
  assert.equal(diagnostics[0].route_category, "unknown")
  assert.equal(JSON.stringify(diagnostics).includes("forbidden"), false)

  const pending = deferred()
  peer.getStats = () => pending.promise
  peer.emit("connectionstatechange")
  attempt.leave()
  pending.resolve(selectedRouteStats({remoteType: "relay"}))
  await Promise.resolve()
  assert.equal(diagnostics.length, 1)
})

function attemptFixture() {
  const peer = fakePeerConnection()
  const serverIce = []
  const closes = []
  const rosterCues = []
  const sessionEnded = []
  const signaling = {
    joinVoiceChannel: async () => disabledAdmission(),
    leave() {},
    onClose(callback) { closes.push(callback); return 1 },
    onRosterCue(callback) { rosterCues.push(callback); return 1 },
    onVoiceSessionEnded(callback) { sessionEnded.push(callback); return 1 },
    onServerIce(callback) { serverIce.push(callback); return 1 },
    sendIce() {},
    sendOffer: async () => ({
      signaling_session_id: "server-session",
      negotiation_id: "browser-negotiation",
      description: {type: "answer", sdp: "server-answer"},
    }),
  }

  return {closes, peer, rosterCues, serverIce, sessionEnded, signaling}
}

test("admits before constructing one configured microphone connection and four Audio Output Slots", async () => {
  const {peer, signaling} = attemptFixture()
  const states = []
  const constructorConfigurations = []
  let admissionArguments
  signaling.joinVoiceChannel = async (...args) => {
    admissionArguments = args
    assert.deepEqual(constructorConfigurations, [])
    return disabledAdmission()
  }
  const attempt = createVoicePeerAttempt({
    PeerConnection: class {
      constructor(configuration) {
        constructorConfigurations.push(configuration)
        return peer
      }
    },
    negotiationId: () => "browser-negotiation",
    onState: state => states.push(state),
    signaling,
  })

  await attempt.connect({channelId: "voice-1", track: {id: "microphone"}})

  assert.deepEqual(admissionArguments, ["voice-1"])
  assert.deepEqual(constructorConfigurations, [{iceServers: [], iceTransportPolicy: "all"}])
  assert.deepEqual(
    peer.addedTransceivers.map(({direction, sender}) => ({direction, track: sender.track})),
    [
      {direction: "sendonly", track: {id: "microphone"}},
      {direction: "recvonly", track: null},
      {direction: "recvonly", track: null},
      {direction: "recvonly", track: null},
      {direction: "recvonly", track: null},
    ]
  )
  assert.deepEqual(peer.localDescription, {type: "offer", sdp: "browser-offer"})
  assert.deepEqual(peer.remoteDescription, {type: "answer", sdp: "server-answer"})
  assert.deepEqual(states, ["joining"])

  peer.connectionState = "connected"
  peer.emit("connectionstatechange")
  assert.deepEqual(states, ["joining", "connected"])
})

test("constructs the final PeerConnection from the admitted standard ICE projection", async () => {
  const {peer, signaling} = attemptFixture()
  const constructorConfigurations = []
  signaling.joinVoiceChannel = async () => standardAdmission()
  const attempt = createVoicePeerAttempt({
    PeerConnection: class {
      constructor(configuration) {
        constructorConfigurations.push(configuration)
        return peer
      }
    },
    negotiationId: () => "browser-negotiation",
    signaling,
  })

  await attempt.connect({channelId: "voice-1", track: {id: "microphone"}})

  assert.deepEqual(constructorConfigurations, [{
    iceServers: [
      {urls: ["stun:stun.example.test:3478"]},
      {
        urls: [
          "turn:turn.example.test:3478?transport=udp",
          "turn:turn.example.test:3478?transport=tcp",
          "turns:turn.example.test:5349?transport=tcp",
        ],
        username: "temporary-user",
        credential: "temporary-credential",
      },
    ],
    iceTransportPolicy: "all",
  }])
})

test("constructs the final PeerConnection with the admitted TURN-only relay policy", async () => {
  const {peer, signaling} = attemptFixture()
  const constructorConfigurations = []
  signaling.joinVoiceChannel = async () => turnOnlyAdmission()
  const attempt = createVoicePeerAttempt({
    PeerConnection: class {
      constructor(configuration) {
        constructorConfigurations.push(configuration)
        return peer
      }
    },
    negotiationId: () => "browser-negotiation",
    signaling,
  })

  await attempt.connect({channelId: "voice-1", track: {id: "microphone"}})

  assert.deepEqual(constructorConfigurations, [{
    iceServers: [
      {
        urls: [
          "turn:turn.example.test:3478?transport=udp",
          "turn:turn.example.test:3478?transport=tcp",
          "turns:turn.example.test:5349?transport=tcp",
        ],
        username: "temporary-user",
        credential: "temporary-credential",
      },
    ],
    iceTransportPolicy: "relay",
  }])
})

test("rejects malformed or server-only admission configuration before PeerConnection construction", async () => {
  const malformedAdmissions = [
    disabledAdmission({voice_session_id: "private-session"}),
    disabledAdmission({ice_config: {ice_servers: [], ice_transport_policy: "all", udp_port_range: [50_000, 50_031]}}),
    disabledAdmission({ice_config: {ice_servers: [{urls: "https://provider.example.test/ice"}], ice_transport_policy: "all"}}),
    disabledAdmission({ice_config: {ice_servers: [{urls: "turn:turn.example.test:3478"}], ice_transport_policy: "all"}}),
    disabledAdmission({ice_config: {ice_servers: [{urls: "stun:stun.example.test:3478", provider: "vendor"}], ice_transport_policy: "all"}}),
    disabledAdmission({ice_config: {ice_servers: [], ice_transport_policy: "relay"}}),
    disabledAdmission({ice_config: {ice_servers: [{urls: "stun:stun.example.test:3478"}], ice_transport_policy: "relay"}}),
    disabledAdmission({ice_config: {ice_servers: [], ice_transport_policy: "unknown"}}),
  ]

  for (const admission of malformedAdmissions) {
    const {signaling} = attemptFixture()
    const failures = []
    let peerCreations = 0
    let leaves = 0
    signaling.joinVoiceChannel = async () => admission
    signaling.leave = () => { leaves += 1 }
    const attempt = createVoicePeerAttempt({
      PeerConnection: class { constructor() { peerCreations += 1 } },
      onFailure: failure => failures.push(failure),
      signaling,
    })

    await assert.rejects(attempt.connect({channelId: "voice-1", track: {id: "microphone"}}))
    assert.equal(peerCreations, 0)
    assert.equal(leaves, 1)
    assert.deepEqual(failures, ["connection_failed"])
  }
})

test("construction, every transceiver stage, offer, and local-description failures leave exactly once", async () => {
  const stages = ["constructor", "send", "send-result", "receive-1", "receive-2", "receive-3", "receive-4", "offer", "local-description"]

  for (const stage of stages) {
    const {signaling} = attemptFixture()
    const peer = fakePeerConnection()
    const failures = []
    let leaves = 0
    signaling.leave = () => { leaves += 1 }

    if (stage.startsWith("receive-") || stage === "send" || stage === "send-result") {
      const failingIndex = stage === "send" ? 0 : Number(stage.split("-")[1])
      const addTransceiver = peer.addTransceiver
      peer.addTransceiver = function(kindOrTrack, init) {
        if (this.addedTransceivers.length === failingIndex) throw new Error(`${stage} unavailable`)
        if (stage === "send-result" && this.addedTransceivers.length === 0) return null
        return addTransceiver.call(this, kindOrTrack, init)
      }
    }
    if (stage === "offer") peer.createOffer = async () => { throw new Error("offer unavailable") }
    if (stage === "local-description") peer.setLocalDescription = async () => { throw new Error("local description unavailable") }

    const attempt = createVoicePeerAttempt({
      PeerConnection: class {
        constructor() {
          if (stage === "constructor") throw new Error("constructor unavailable")
          return peer
        }
      },
      onFailure: failure => failures.push(failure),
      signaling,
    })

    await assert.rejects(attempt.connect({channelId: "voice-1", track: {id: "microphone"}}))
    attempt.leave()

    assert.equal(leaves, 1)
    assert.deepEqual(failures, [stage === "offer" || stage === "local-description"
      ? "connection_failed"
      : "incompatible_audio_output_slots"])
    assert.equal(peer.closed, stage !== "constructor")
  }
})

test("a connected silent microphone remains active without an RTP inactivity timeout", async () => {
  const {peer, signaling} = attemptFixture()
  const failures = []
  const states = []
  const attempt = createVoicePeerAttempt({
    PeerConnection: class { constructor() { return peer } },
    negotiationId: () => "browser-negotiation",
    onFailure: failure => failures.push(failure),
    onState: state => states.push(state),
    signaling,
  })

  await attempt.connect({channelId: "voice-1", track: {id: "microphone"}})
  peer.connectionState = "connected"
  peer.emit("connectionstatechange")

  assert.deepEqual(states, ["joining", "connected"])
  assert.deepEqual(failures, [])
  assert.equal(peer.closed, false)
})

test("renews the active signaling session every thirty seconds while a background tab remains active", async () => {
  const {peer, signaling} = attemptFixture()
  const clock = fakeClock()
  const renewals = []
  signaling.renewVoiceSession = renewal => {
    renewals.push(renewal)
    return {receive() { return this }}
  }
  const attempt = createVoicePeerAttempt({
    PeerConnection: class { constructor() { return peer } },
    clearTimeoutFn: clock.clearTimeout,
    negotiationId: () => "browser-negotiation",
    setTimeoutFn: clock.setTimeout,
    signaling,
  })

  await attempt.connect({channelId: "voice-1", track: {id: "microphone"}})
  clock.advance(60_000)

  assert.deepEqual(renewals, [
    {signaling_session_id: "server-session"},
    {signaling_session_id: "server-session"},
  ])
  assert.equal(peer.closed, false)
})

test("a missing renewal acknowledgement interrupts control-plane presentation and a valid delayed acknowledgement recovers only connected media", async () => {
  const {peer, signaling} = attemptFixture()
  const clock = fakeClock()
  const states = []
  let acknowledge
  signaling.renewVoiceSession = () => ({
    receive(status, callback) {
      if (status === "ok") acknowledge = callback
      return this
    },
  })
  const attempt = createVoicePeerAttempt({
    PeerConnection: class { constructor() { return peer } },
    clearTimeoutFn: clock.clearTimeout,
    negotiationId: () => "browser-negotiation",
    onState: state => states.push(state),
    setTimeoutFn: clock.setTimeout,
    signaling,
  })

  await attempt.connect({channelId: "voice-1", track: {id: "microphone"}})
  peer.connectionState = "connected"
  peer.emit("connectionstatechange")
  clock.advance(40_000)
  assert.equal(states.at(-1), "interrupted")

  peer.connectionState = "disconnected"
  peer.emit("connectionstatechange")
  acknowledge({signaling_session_id: "server-session"})
  assert.equal(states.at(-1), "interrupted")

  peer.connectionState = "connected"
  peer.emit("connectionstatechange")
  assert.equal(states.at(-1), "connected")
})

test("unacknowledged renewal expires after seventy-five seconds, while a rejected renewal is immediately terminal and stale replies do nothing", async () => {
  for (const outcome of ["silent", "rejected"]) {
    const {peer, signaling} = attemptFixture()
    const clock = fakeClock()
    const failures = []
    let rejectRenewal
    let acknowledge
    signaling.leave = () => { signaling.left = (signaling.left || 0) + 1 }
    signaling.renewVoiceSession = () => ({
      receive(status, callback) {
        if (status === "ok") acknowledge = callback
        if (status === "error") rejectRenewal = callback
        return this
      },
    })
    const attempt = createVoicePeerAttempt({
      PeerConnection: class { constructor() { return peer } },
      clearTimeoutFn: clock.clearTimeout,
      negotiationId: () => "browser-negotiation",
      onFailure: failure => failures.push(failure),
      setTimeoutFn: clock.setTimeout,
      signaling,
    })

    await attempt.connect({channelId: "voice-1", track: {id: "microphone"}})
    clock.advance(30_000)
    if (outcome === "silent") clock.advance(45_000)
    else rejectRenewal({reason: "invalid_session"})

    assert.equal(peer.closed, true)
    assert.equal(signaling.left, 1)
    assert.deepEqual(failures, ["connection_lost"])
    acknowledge?.({signaling_session_id: "server-session"})
    assert.deepEqual(failures, ["connection_lost"])
  }
})

test("terminal cleanup cancels renewal traffic after the controller releases its attempt", async () => {
  const {peer, signaling} = attemptFixture()
  const clock = fakeClock()
  const renewals = []
  signaling.renewVoiceSession = renewal => {
    renewals.push(renewal)
    return {receive() { return this }}
  }
  const attempt = createVoicePeerAttempt({
    PeerConnection: class { constructor() { return peer } },
    clearTimeoutFn: clock.clearTimeout,
    negotiationId: () => "browser-negotiation",
    setTimeoutFn: clock.setTimeout,
    signaling,
  })

  await attempt.connect({channelId: "voice-1", track: {id: "microphone"}})
  attempt.leave()
  clock.advance(75_000)

  assert.deepEqual(renewals, [])
  assert.equal(peer.closed, true)
})

test("ends and releases only the matching attempt when the server ends its Voice Session", async () => {
  const {peer, sessionEnded, signaling} = attemptFixture()
  const failures = []
  signaling.leave = () => { signaling.left = (signaling.left || 0) + 1 }
  const attempt = createVoicePeerAttempt({
    PeerConnection: class { constructor() { return peer } },
    negotiationId: () => "browser-negotiation",
    onFailure: failure => failures.push(failure),
    signaling,
  })

  await attempt.connect({channelId: "voice-1", track: {id: "microphone"}})
  sessionEnded[0]({signaling_session_id: "stale-session"})
  assert.equal(peer.closed, false)

  sessionEnded[0]({signaling_session_id: "server-session"})
  sessionEnded[0]({signaling_session_id: "server-session"})

  assert.equal(peer.closed, true)
  assert.equal(signaling.left, 1)
  assert.deepEqual(failures, ["connection_lost"])
})

test("ignores an ended event from a retired attempt after a replacement connects", async () => {
  const first = attemptFixture()
  const second = attemptFixture()
  first.signaling.sendOffer = async () => ({
    signaling_session_id: "server-session",
    negotiation_id: "first-negotiation",
    description: {type: "answer", sdp: "server-answer"},
  })
  second.signaling.sendOffer = async () => ({
    signaling_session_id: "server-session",
    negotiation_id: "second-negotiation",
    description: {type: "answer", sdp: "server-answer"},
  })
  const firstAttempt = createVoicePeerAttempt({
    PeerConnection: class { constructor() { return first.peer } },
    negotiationId: () => "first-negotiation",
    signaling: first.signaling,
  })
  const secondAttempt = createVoicePeerAttempt({
    PeerConnection: class { constructor() { return second.peer } },
    negotiationId: () => "second-negotiation",
    signaling: second.signaling,
  })

  await firstAttempt.connect({channelId: "voice-1", track: {id: "first-microphone"}})
  firstAttempt.leave()
  await secondAttempt.connect({channelId: "voice-1", track: {id: "second-microphone"}})

  first.sessionEnded[0]({signaling_session_id: "server-session"})

  assert.equal(first.peer.closed, true)
  assert.equal(second.peer.closed, false)
})

test("reports a disconnected peer as interrupted without ending its Voice Session", async () => {
  const {peer, signaling} = attemptFixture()
  const states = []
  const failures = []
  const attempt = createVoicePeerAttempt({
    PeerConnection: class { constructor() { return peer } },
    negotiationId: () => "browser-negotiation",
    onFailure: failure => failures.push(failure),
    onState: state => states.push(state),
    signaling,
  })

  await attempt.connect({channelId: "voice-1", track: {id: "microphone"}})
  peer.connectionState = "disconnected"
  peer.emit("connectionstatechange")

  assert.deepEqual(states, ["joining", "interrupted"])
  assert.deepEqual(failures, [])
  assert.equal(peer.closed, false)
})

test("recovers a disconnected peer before its thirty-second deadline and isolates a stale deadline", async () => {
  const {peer, signaling} = attemptFixture()
  const clock = fakeClock()
  const failures = []
  const states = []
  const attempt = createVoicePeerAttempt({
    PeerConnection: class { constructor() { return peer } },
    clearTimeoutFn: clock.clearTimeout,
    negotiationId: () => "browser-negotiation",
    onFailure: failure => failures.push(failure),
    onState: state => states.push(state),
    setTimeoutFn: clock.setTimeout,
    signaling,
  })

  await attempt.connect({channelId: "voice-1", track: {id: "microphone"}})
  peer.connectionState = "connected"
  peer.emit("connectionstatechange")
  peer.connectionState = "disconnected"
  peer.emit("connectionstatechange")
  clock.advance(29_999)
  peer.connectionState = "connected"
  peer.emit("connectionstatechange")
  peer.connectionState = "disconnected"
  peer.emit("connectionstatechange")
  clock.advance(1)
  assert.deepEqual(failures, [])
  clock.advance(29_999)

  assert.equal(states.at(-1), "interrupted")
  assert.deepEqual(failures, ["connection_lost"])
  assert.equal(peer.closed, true)
})

test("ends an unrecovered disconnected peer at its thirty-second deadline", async () => {
  const {peer, signaling} = attemptFixture()
  const clock = fakeClock()
  const failures = []
  signaling.leave = () => { signaling.left = (signaling.left || 0) + 1 }
  const attempt = createVoicePeerAttempt({
    PeerConnection: class { constructor() { return peer } },
    clearTimeoutFn: clock.clearTimeout,
    negotiationId: () => "browser-negotiation",
    onFailure: failure => failures.push(failure),
    setTimeoutFn: clock.setTimeout,
    signaling,
  })

  await attempt.connect({channelId: "voice-1", track: {id: "microphone"}})
  peer.connectionState = "disconnected"
  peer.emit("connectionstatechange")
  clock.advance(30_000)

  assert.deepEqual(failures, ["connection_lost"])
  assert.equal(peer.closed, true)
  assert.equal(signaling.left, 1)
})

test("forwards server roster cues to the active Voice Owner Tab", async () => {
  const {rosterCues, signaling} = attemptFixture()
  const cues = []
  const attempt = createVoicePeerAttempt({
    PeerConnection: class { constructor() { return fakePeerConnection() } },
    negotiationId: () => "browser-negotiation",
    onCue: cue => cues.push(cue),
    signaling,
  })

  await attempt.connect({channelId: "voice-1", track: {id: "microphone"}})
  rosterCues[0]({channel_id: "voice-1", cue: "join"})

  assert.deepEqual(cues, [{channelId: "voice-1", cue: "join"}])
})

test("keeps four remote tracks separate in one stable aggregate playback stream", async () => {
  const {peer, signaling} = attemptFixture()
  const audio = remoteAudio({
    play() { this.playCalls += 1; return Promise.resolve() },
  })
  const playback = []
  const attempt = createVoicePeerAttempt({
    PeerConnection: class { constructor() { return peer } },
    negotiationId: () => "browser-negotiation",
    onPlayback: outcome => playback.push(outcome),
    remoteAudio: audio,
    signaling,
  })

  await attempt.connect({channelId: "voice-1", track: {id: "microphone"}})
  const aggregateStream = audio.srcObject
  const remoteTracks = peer.addedTransceivers.slice(1).map(transceiver => transceiver.receiver.track)

  peer.addedTransceivers.slice(1).forEach((transceiver, index) => {
    peer.emit("track", {track: remoteTracks[index], transceiver})
  })
  await new Promise(resolve => setImmediate(resolve))

  assert.equal(audio.autoplay, true)
  assert.equal(audio.playsInline, true)
  assert.equal(audio.srcObject, aggregateStream)
  assert.deepEqual(aggregateStream.getTracks(), remoteTracks)
  assert.equal(audio.playCalls, 4)
  assert.deepEqual(playback, ["playing", "playing", "playing", "playing"])

  remoteTracks[1].end()
  assert.equal(audio.srcObject, aggregateStream)
  assert.deepEqual(aggregateStream.getTracks(), [remoteTracks[0], remoteTracks[2], remoteTracks[3]])
})

test("a failed four-slot construction leaves the admitted Voice Session with a retryable result", async () => {
  const {peer, signaling} = attemptFixture()
  const failures = []
  let joins = 0
  let leaves = 0
  signaling.joinVoiceChannel = async () => { joins += 1; return disabledAdmission() }
  signaling.leave = () => { leaves += 1 }
  peer.addTransceiver = function(kindOrTrack, init) {
    if (this.addedTransceivers.length === 4) throw new Error("fifth media lane unavailable")
    return fakePeerConnection().addTransceiver.call(this, kindOrTrack, init)
  }
  const attempt = createVoicePeerAttempt({
    PeerConnection: class { constructor() { return peer } },
    negotiationId: () => "browser-negotiation",
    onFailure: failure => failures.push(failure),
    signaling,
  })

  await assert.rejects(attempt.connect({channelId: "voice-1", track: {id: "microphone"}}))

  assert.equal(joins, 1)
  assert.equal(leaves, 1)
  assert.equal(peer.closed, true)
  assert.deepEqual(failures, ["incompatible_audio_output_slots"])
})

test("a blocked automatic playback keeps the attempt active and Enable audio retries only playback", async () => {
  const {peer, signaling} = attemptFixture()
  let offers = 0
  signaling.sendOffer = async () => {
    offers += 1
    return {
      signaling_session_id: "server-session",
      negotiation_id: "browser-negotiation",
      description: {type: "answer", sdp: "server-answer"},
    }
  }
  let remainingFailures = 1
  const audio = remoteAudio({
    play() {
      this.playCalls += 1
      if (remainingFailures > 0) {
        remainingFailures -= 1
        return Promise.reject(new Error("autoplay blocked"))
      }
      return Promise.resolve()
    },
  })
  const failures = []
  const playback = []
  const attempt = createVoicePeerAttempt({
    PeerConnection: class { constructor() { return peer } },
    negotiationId: () => "browser-negotiation",
    onFailure: failure => failures.push(failure),
    onPlayback: outcome => playback.push(outcome),
    remoteAudio: audio,
    signaling,
  })

  await attempt.connect({channelId: "voice-1", track: {id: "microphone"}})
  const transceiver = peer.addedTransceivers[1]
  peer.emit("track", {track: transceiver.receiver.track, transceiver})
  await new Promise(resolve => setImmediate(resolve))
  await attempt.enableAudio()

  assert.equal(audio.playCalls, 2)
  assert.deepEqual(playback, ["blocked", "playing"])
  assert.deepEqual(failures, [])
  assert.equal(peer.closed, false)
  assert.equal(offers, 1)
})

test("releases remote audio exactly once on explicit leave and terminal connection failure", async () => {
  for (const terminal of ["leave", "failed"]) {
    const {peer, signaling} = attemptFixture()
    const audio = remoteAudio({
      play() { this.playCalls += 1; return Promise.resolve() },
    })
    const attempt = createVoicePeerAttempt({
      PeerConnection: class { constructor() { return peer } },
      negotiationId: () => "browser-negotiation",
      remoteAudio: audio,
      signaling,
    })

    await attempt.connect({channelId: "voice-1", track: {id: "microphone"}})
    const transceiver = peer.addedTransceivers[1]
    const remote = transceiver.receiver.track
    peer.emit("track", {track: remote, transceiver})
    await new Promise(resolve => setImmediate(resolve))
    assert.deepEqual(audio.srcObject.getTracks(), [remote])
    assert.equal(remote.hasListener("ended"), true)
    if (terminal === "leave") attempt.leave()
    else {
      peer.connectionState = "failed"
      peer.emit("connectionstatechange")
    }
    attempt.leave()

    assert.equal(audio.pauseCalls, 1)
    assert.equal(audio.srcObject, null)
    assert.equal(remote.hasListener("ended"), false)
    assert.equal(peer.closed, true)
  }
})

test("buffers matching server ICE until the answer is applied, then preserves arrival order", async () => {
  const {peer, serverIce, signaling} = attemptFixture()
  const answer = deferred()
  signaling.sendOffer = async () => answer.promise
  const attempt = createVoicePeerAttempt({
    PeerConnection: class { constructor() { return peer } },
    negotiationId: () => "browser-negotiation",
    signaling,
  })

  const connecting = attempt.connect({channelId: "voice-1", track: {id: "microphone"}})
  await new Promise(resolve => setImmediate(resolve))
  serverIce[0]({signaling_session_id: "server-session", negotiation_id: "browser-negotiation", candidate: {candidate: "first"}})
  serverIce[0]({signaling_session_id: "server-session", negotiation_id: "stale", candidate: {candidate: "stale"}})
  assert.deepEqual(peer.addedCandidates, [])

  answer.resolve({
    signaling_session_id: "server-session",
    negotiation_id: "browser-negotiation",
    description: {type: "answer", sdp: "server-answer"},
  })
  await connecting

  assert.deepEqual(peer.addedCandidates, [{candidate: "first"}])
})

test("buffers the correlated server end marker until the answer, then applies ExWebRTC's empty-candidate form", async () => {
  const {peer, serverIce, signaling} = attemptFixture()
  const answer = deferred()
  signaling.sendOffer = async () => answer.promise
  const attempt = createVoicePeerAttempt({
    PeerConnection: class { constructor() { return peer } },
    negotiationId: () => "browser-negotiation",
    signaling,
  })

  const connecting = attempt.connect({channelId: "voice-1", track: {id: "microphone"}})
  await new Promise(resolve => setImmediate(resolve))
  serverIce[0]({
    signaling_session_id: "server-session",
    negotiation_id: "browser-negotiation",
    end_of_candidates: true,
  })

  answer.resolve({
    signaling_session_id: "server-session",
    negotiation_id: "browser-negotiation",
    description: {type: "answer", sdp: "server-answer"},
  })
  await connecting

  assert.deepEqual(peer.addedCandidates, [{candidate: ""}])
})

test("applies a correlated server end marker received after the answer as an empty candidate", async () => {
  const {peer, serverIce, signaling} = attemptFixture()
  const attempt = createVoicePeerAttempt({
    PeerConnection: class { constructor() { return peer } },
    negotiationId: () => "browser-negotiation",
    signaling,
  })

  await attempt.connect({channelId: "voice-1", track: {id: "microphone"}})
  serverIce[0]({
    signaling_session_id: "server-session",
    negotiation_id: "browser-negotiation",
    end_of_candidates: true,
  })

  assert.deepEqual(peer.addedCandidates, [{candidate: ""}])
})

test("sends browser ICE candidates individually and never sends the null gathering event", async () => {
  const {peer, signaling} = attemptFixture()
  const sent = []
  signaling.sendIce = payload => sent.push(payload)
  const attempt = createVoicePeerAttempt({
    PeerConnection: class { constructor() { return peer } },
    negotiationId: () => "browser-negotiation",
    signaling,
  })

  await attempt.connect({channelId: "voice-1", track: {id: "microphone"}})
  peer.emit("icecandidate", {candidate: {candidate: "local-candidate"}})
  peer.emit("icecandidate", {candidate: null})

  assert.deepEqual(sent, [{
    signaling_session_id: "server-session",
    negotiation_id: "browser-negotiation",
    candidate: {candidate: "local-candidate"},
  }])
})

test("a rejected offer is terminal, closes the peer, and leaves signaling", async () => {
  const {peer, signaling} = attemptFixture()
  const failures = []
  let leaves = 0
  signaling.leave = () => { leaves += 1 }
  signaling.sendOffer = async () => { throw new Error("rejected") }
  const attempt = createVoicePeerAttempt({
    PeerConnection: class { constructor() { return peer } },
    negotiationId: () => "browser-negotiation",
    onFailure: failure => failures.push(failure),
    signaling,
  })

  await assert.rejects(attempt.connect({channelId: "voice-1", track: {id: "microphone"}}))
  assert.equal(peer.closed, true)
  assert.equal(leaves, 1)
  assert.deepEqual(failures, ["connection_failed"])
})

test("an unexpected signaling-topic close is terminal and releases the browser peer", async () => {
  const {closes, peer, signaling} = attemptFixture()
  const failures = []
  let leaves = 0
  signaling.leave = () => { leaves += 1 }
  const attempt = createVoicePeerAttempt({
    PeerConnection: class { constructor() { return peer } },
    negotiationId: () => "browser-negotiation",
    onFailure: failure => failures.push(failure),
    signaling,
  })

  await attempt.connect({channelId: "voice-1", track: {id: "microphone"}})
  closes[0]()

  assert.equal(peer.closed, true)
  assert.equal(leaves, 1)
  assert.deepEqual(failures, ["connection_lost"])
})

test("explicit Leave closes one active browser peer and leaves its topic only once", async () => {
  const {peer, signaling} = attemptFixture()
  let leaves = 0
  signaling.leave = () => { leaves += 1 }
  const attempt = createVoicePeerAttempt({
    PeerConnection: class { constructor() { return peer } },
    negotiationId: () => "browser-negotiation",
    signaling,
  })

  await attempt.connect({channelId: "voice-1", track: {id: "microphone"}})
  attempt.leave()
  attempt.leave()

  assert.equal(peer.closed, true)
  assert.equal(leaves, 1)
})

test("Leave clears server ICE buffered before the answer", async () => {
  const {peer, serverIce, signaling} = attemptFixture()
  const answer = deferred()
  signaling.sendOffer = () => answer.promise
  const attempt = createVoicePeerAttempt({
    PeerConnection: class { constructor() { return peer } },
    negotiationId: () => "browser-negotiation",
    signaling,
  })

  const connecting = attempt.connect({channelId: "voice-1", track: {id: "microphone"}})
  await new Promise(resolve => setImmediate(resolve))
  serverIce[0]({
    signaling_session_id: "server-session",
    negotiation_id: "browser-negotiation",
    candidate: {candidate: "early-candidate"},
  })
  attempt.leave()
  answer.resolve({
    signaling_session_id: "server-session",
    negotiation_id: "browser-negotiation",
    description: {type: "answer", sdp: "server-answer"},
  })

  await assert.rejects(connecting, /cancelled/)
  assert.deepEqual(peer.addedCandidates, [])
})

test("failed and closed browser connection states are terminal and use the retryable lost-connection state", async () => {
  for (const state of ["failed", "closed"]) {
    const {peer, signaling} = attemptFixture()
    const failures = []
    const attempt = createVoicePeerAttempt({
      PeerConnection: class { constructor() { return peer } },
      negotiationId: () => "browser-negotiation",
      onFailure: failure => failures.push(failure),
      signaling,
    })

    await attempt.connect({channelId: "voice-1", track: {id: "microphone"}})
    peer.connectionState = state
    peer.emit("connectionstatechange")

    assert.equal(peer.closed, true)
    assert.deepEqual(failures, ["connection_lost"])
  }
})

test("an offer reply that exceeds ten seconds is terminal", async () => {
  const {peer, signaling} = attemptFixture()
  let timeoutCallback
  const failures = []
  signaling.sendOffer = () => new Promise(() => {})
  const attempt = createVoicePeerAttempt({
    PeerConnection: class { constructor() { return peer } },
    negotiationId: () => "browser-negotiation",
    onFailure: failure => failures.push(failure),
    setTimeoutFn(callback, delay) { assert.equal(delay, 10_000); timeoutCallback = callback; return 1 },
    clearTimeoutFn() {},
    signaling,
  })

  const connecting = attempt.connect({channelId: "voice-1", track: {id: "microphone"}})
  await new Promise(resolve => setImmediate(resolve))
  timeoutCallback()

  await assert.rejects(connecting, /timed out/)
  assert.equal(peer.closed, true)
  assert.deepEqual(failures, ["connection_failed"])
})

test("Leave during topic admission never constructs a browser peer and ignores a late reply", async () => {
  const {peer, signaling} = attemptFixture()
  const joined = deferred()
  let peerCreations = 0
  let leaves = 0
  signaling.joinVoiceChannel = () => joined.promise
  signaling.leave = () => { leaves += 1 }
  const attempt = createVoicePeerAttempt({
    PeerConnection: class { constructor() { peerCreations += 1; return peer } },
    signaling,
  })

  const connecting = attempt.connect({channelId: "voice-1", track: {id: "microphone"}})
  const rejected = assert.rejects(connecting, /cancelled/)
  await new Promise(resolve => setImmediate(resolve))
  attempt.leave()
  joined.resolve(disabledAdmission())

  await rejected
  assert.equal(peerCreations, 0)
  assert.equal(peer.closed, false)
  assert.equal(leaves, 1)
})

test("bounds server ICE buffered before the answer at sixteen candidates", async () => {
  const {peer, serverIce, signaling} = attemptFixture()
  const answer = deferred()
  signaling.sendOffer = () => answer.promise
  const attempt = createVoicePeerAttempt({
    PeerConnection: class { constructor() { return peer } },
    negotiationId: () => "browser-negotiation",
    signaling,
  })

  const connecting = attempt.connect({channelId: "voice-1", track: {id: "microphone"}})
  await new Promise(resolve => setImmediate(resolve))
  for (let number = 0; number < 17; number += 1) {
    serverIce[0]({
      signaling_session_id: "server-session",
      negotiation_id: "browser-negotiation",
      candidate: {candidate: `candidate-${number}`},
    })
  }
  answer.resolve({
    signaling_session_id: "server-session",
    negotiation_id: "browser-negotiation",
    description: {type: "answer", sdp: "server-answer"},
  })

  await connecting
  assert.equal(peer.addedCandidates.length, 16)
  assert.deepEqual(peer.addedCandidates[0], {candidate: "candidate-0"})
  assert.deepEqual(peer.addedCandidates.at(-1), {candidate: "candidate-15"})
})
