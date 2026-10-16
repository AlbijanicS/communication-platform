import assert from "node:assert/strict"
import {readFile} from "node:fs/promises"
import test from "node:test"

import {createVoicePeerAttempt} from "../voice_peer_attempt.js"

const controllerSource = await readFile(new URL("./voice_controller.js", import.meta.url), "utf8")
const controllerModuleUrl = `data:text/javascript;base64,${Buffer.from(controllerSource).toString("base64")}`
const {createVoiceController} = await import(controllerModuleUrl)

globalThis.MediaStream = class {
  constructor() { this.tracks = [] }
  addTrack(track) { this.tracks.push(track) }
  getTracks() { return [...this.tracks] }
  removeTrack(track) { this.tracks = this.tracks.filter(candidate => candidate !== track) }
}

let nextRemoteTrackId = 0

function addTransceiver(kindOrTrack, init) {
  return {
    direction: init.direction,
    receiver: {track: {id: `remote-${nextRemoteTrackId++}`, kind: "audio"}},
    sender: {track: typeof kindOrTrack === "string" ? null : kindOrTrack},
  }
}

function deferred() {
  let resolve
  let reject
  const promise = new Promise((nextResolve, nextReject) => {
    resolve = nextResolve
    reject = nextReject
  })

  return {promise, reject, resolve}
}

function track() {
  const listeners = new Map()

  return {
    enabled: true,
    stopped: false,
    stop() {
      this.stopped = true
    },
    addEventListener(name, listener) {
      listeners.set(name, listener)
    },
    removeEventListener(name) {
      listeners.delete(name)
    },
    end() {
      listeners.get("ended")?.()
    },
  }
}

function stream(...tracks) {
  return {
    getAudioTracks() {
      return tracks
    },
  }
}

function disabledAdmission() {
  return {
    signaling_session_id: "server-session",
    occupancy: 1,
    capacity: 5,
    ice_config: {ice_mode: "disabled", ice_servers: [], ice_transport_policy: "all"},
  }
}

function tabNetwork() {
  const listeners = new Set()

  return {
    connect() {
      let listener

      return {
        publish(claim) {
          listeners.forEach(nextListener => nextListener(claim))
        },
        subscribe(nextListener) {
          listener = nextListener
          listeners.add(listener)
          return () => listeners.delete(listener)
        },
        close() {
          if (listener) listeners.delete(listener)
        },
      }
    },
  }
}

function queuedTabNetwork() {
  const listeners = new Set()
  const claims = []

  return {
    connect() {
      return {
        publish(claim) {
          claims.push(claim)
        },
        subscribe(listener) {
          listeners.add(listener)
          return () => listeners.delete(listener)
        },
      }
    },
    deliver(order) {
      order.forEach(index => listeners.forEach(listener => listener(claims[index])))
    },
  }
}

test("a Voice Channel click requests capture, mutes, unmutes, and leaves without another prompt", async () => {
  const capture = deferred()
  let captureRequests = 0
  const mediaDevices = {
    getUserMedia(constraints) {
      captureRequests += 1
      assert.deepEqual(constraints, {audio: true})
      return capture.promise
    },
  }
  const controller = createVoiceController({mediaDevices})
  const microphoneTrack = track()
  const secondaryTrack = track()

  assert.deepEqual(controller.state(), {channelId: null, channelName: null, status: "idle", connectionStatus: "idle", localMuted: false, muted: false, deafened: false, workspaceId: null})

  const join = controller.join({id: "voice-1", name: "lobby", workspaceId: "workspace-1"})
  assert.deepEqual(controller.state(), {
    channelId: "voice-1",
    channelName: "lobby",
    status: "requesting", connectionStatus: "requesting", localMuted: false, muted: false, deafened: false,
    workspaceId: "workspace-1",
  })

  capture.resolve(stream(microphoneTrack, secondaryTrack))
  await join
  assert.equal(controller.state().status, "capturing")

  const reattachedState = []
  const unsubscribe = controller.subscribe(state => reattachedState.push(state))
  assert.deepEqual(reattachedState, [controller.state()])
  assert.equal(captureRequests, 1)
  unsubscribe()

  controller.toggleMute()
  assert.equal(controller.state().status, "muted")
  assert.equal(microphoneTrack.enabled, false)

  controller.toggleMute()
  assert.equal(controller.state().status, "capturing")
  assert.equal(microphoneTrack.enabled, true)

  controller.leave()
  assert.deepEqual(controller.state(), {channelId: null, channelName: null, status: "idle", connectionStatus: "idle", localMuted: false, muted: false, deafened: false, workspaceId: null})
  assert.equal(microphoneTrack.stopped, true)
  assert.equal(secondaryTrack.stopped, true)
})

test("leaving while permission is pending stops a late stream instead of restoring capture", async () => {
  const capture = deferred()
  const controller = createVoiceController({
    mediaDevices: {getUserMedia: () => capture.promise},
  })
  const microphoneTrack = track()

  const join = controller.join({id: "voice-1", name: "lobby", workspaceId: "workspace-1"})
  controller.leave()
  capture.resolve(stream(microphoneTrack))
  await join

  assert.deepEqual(controller.state(), {channelId: null, channelName: null, status: "idle", connectionStatus: "idle", localMuted: false, muted: false, deafened: false, workspaceId: null})
  assert.equal(microphoneTrack.stopped, true)
})

test("a denied browser permission keeps the selected Voice Channel and offers a retry", async () => {
  let connectionAttempts = 0
  const controller = createVoiceController({
    connectionFactory() { connectionAttempts += 1 },
    mediaDevices: {
      getUserMedia: () => Promise.reject({name: "NotAllowedError"}),
    },
  })

  await controller.join({id: "voice-1", name: "lobby", workspaceId: "workspace-1"})

  assert.deepEqual(controller.state(), {
    channelId: "voice-1",
    channelName: "lobby",
    error: "permission_denied",
    retryable: true,
    status: "permission_denied", connectionStatus: "permission_denied", localMuted: false, muted: false, deafened: false,
    workspaceId: "workspace-1",
  })
  assert.equal(connectionAttempts, 0)
})

test("capture succeeds before one connection attempt receives the owned track and reports connected", async () => {
  const microphoneTrack = track()
  const attempts = []
  const controller = createVoiceController({
    connectionFactory({channel, onFailure, onState, track: suppliedTrack}) {
      attempts.push({channel, onFailure, onState, track: suppliedTrack})
      return {leave() { attempts[0].left = true }}
    },
    mediaDevices: {getUserMedia: () => Promise.resolve(stream(microphoneTrack))},
  })

  await controller.join({id: "voice-1", name: "lobby", workspaceId: "workspace-1"})

  assert.equal(attempts.length, 1)
  assert.equal(attempts[0].track, microphoneTrack)
  assert.equal(controller.state().status, "joining")
  attempts[0].onState("connected")
  assert.equal(controller.state().status, "connected")
})

test("capture with no live audio track never starts admission and releases returned tracks", async () => {
  for (const capturedTracks of [[], [Object.assign(track(), {readyState: "ended"})]]) {
    let connectionAttempts = 0
    const controller = createVoiceController({
      connectionFactory() { connectionAttempts += 1 },
      mediaDevices: {getUserMedia: () => Promise.resolve(stream(...capturedTracks))},
    })

    await controller.join({id: "voice-1", name: "lobby", workspaceId: "workspace-1"})

    assert.equal(connectionAttempts, 0)
    assert.equal(capturedTracks.every(capturedTrack => capturedTrack.stopped), true)
    assert.equal(controller.state().status, "no_device")
  }
})

test("a rejected connection attempt releases capture even without a failure callback", async () => {
  const microphoneTrack = track()
  const controller = createVoiceController({
    connectionFactory() {
      return {
        connect: () => Promise.reject(new Error("admission failed")),
        leave() {},
      }
    },
    mediaDevices: {getUserMedia: () => Promise.resolve(stream(microphoneTrack))},
  })

  await controller.join({id: "voice-1", name: "lobby", workspaceId: "workspace-1"})
  await new Promise(resolve => setImmediate(resolve))

  assert.equal(microphoneTrack.stopped, true)
  assert.deepEqual(controller.state(), {channelId: null, channelName: null, status: "idle", connectionStatus: "idle", localMuted: false, muted: false, deafened: false, workspaceId: null})
})

test("Local Deafen silences playback and restores an unmuted microphone", async () => {
  const microphoneTrack = track()
  const localStates = []
  const playbackStates = []
  let onState
  const controller = createVoiceController({
    connectionFactory(options) {
      onState = options.onState
      return {
        leave() {},
        setDeafened(deafened) { playbackStates.push(deafened) },
        updateLocalVoiceState(state) { localStates.push(state) },
      }
    },
    mediaDevices: {getUserMedia: () => Promise.resolve(stream(microphoneTrack))},
  })

  await controller.join({id: "voice-1", name: "lobby", workspaceId: "workspace-1"})
  onState("connected")

  controller.toggleDeafen()
  assert.equal(controller.state().status, "muted")
  assert.equal(controller.state().deafened, true)
  assert.equal(microphoneTrack.enabled, false)
  assert.equal(playbackStates.at(-1), true)
  assert.deepEqual(localStates.at(-1), {muted: true, deafened: true})

  controller.toggleDeafen()
  assert.equal(controller.state().status, "connected")
  assert.equal(controller.state().deafened, false)
  assert.equal(microphoneTrack.enabled, true)
  assert.equal(playbackStates.at(-1), false)
  assert.deepEqual(localStates.at(-1), {muted: false, deafened: false})
})

test("local mute and unmute keep the established Voice connection and capture request", async () => {
  const microphoneTrack = track()
  let captureRequests = 0
  let connectionAttempts = 0
  let offers = 0
  const handlers = new Map()
  const peer = {
    addEventListener(event, callback) { handlers.set(event, callback) },
    addTransceiver,
    close() {},
    connectionState: "new",
    createOffer() { offers += 1; return Promise.resolve({type: "offer", sdp: "browser-offer"}) },
    setLocalDescription(description) { this.localDescription = description; return Promise.resolve() },
    setRemoteDescription() { return Promise.resolve() },
  }
  const controller = createVoiceController({
    connectionFactory(options) {
      connectionAttempts += 1
      return createVoicePeerAttempt({
        ...options,
        PeerConnection: class { constructor() { return peer } },
        negotiationId: () => "browser-negotiation",
        signaling: {
          joinVoiceChannel: async () => disabledAdmission(),
          leave() {},
          onClose() {},
          onServerIce() {},
          sendIce() {},
          sendOffer: async () => ({
            signaling_session_id: "server-session",
            negotiation_id: "browser-negotiation",
            description: {type: "answer", sdp: "server-answer"},
          }),
        },
      })
    },
    mediaDevices: {
      getUserMedia() {
        captureRequests += 1
        return Promise.resolve(stream(microphoneTrack))
      },
    },
  })

  await controller.join({id: "voice-1", name: "lobby", workspaceId: "workspace-1"})
  peer.connectionState = "connected"
  handlers.get("connectionstatechange")()
  controller.toggleMute()

  assert.equal(microphoneTrack.enabled, false)
  assert.equal(captureRequests, 1)
  assert.equal(connectionAttempts, 1)
  assert.equal(offers, 1)

  controller.toggleMute()

  assert.equal(microphoneTrack.enabled, true)
  assert.equal(captureRequests, 1)
  assert.equal(connectionAttempts, 1)
  assert.equal(offers, 1)
})

test("the Voice Owner Tab creates one remote audio element and Enable audio retries its active attempt only", async () => {
  const microphoneTrack = track()
  const audio = {autoplay: false, playsInline: false, srcObject: null}
  let createdAudio = 0
  let attempt
  const controller = createVoiceController({
    audioElementFactory() { createdAudio += 1; return audio },
    connectionFactory(options) {
      attempt = options
      return {enableAudio() { attempt.enableCalls = (attempt.enableCalls || 0) + 1 }, leave() {}}
    },
    mediaDevices: {getUserMedia: () => Promise.resolve(stream(microphoneTrack))},
  })

  await controller.join({id: "voice-1", name: "lobby", workspaceId: "workspace-1"})
  attempt.onPlayback("blocked")
  controller.enableAudio()

  assert.equal(createdAudio, 1)
  assert.equal(attempt.remoteAudio, audio)
  assert.equal(controller.state().audioPlayback, "blocked")
  assert.equal(attempt.enableCalls, 1)

  attempt.onPlayback("playing")
  assert.equal(controller.state().audioPlayback, undefined)
})

test("takeover and teardown release the active remote audio attempt exactly once", async () => {
  for (const action of ["takeover", "teardown"]) {
    const microphoneTrack = track()
    const audio = {
      autoplay: false,
      pauseCalls: 0,
      play() { return Promise.resolve() },
      playsInline: false,
      srcObject: null,
      pause() { this.pauseCalls += 1 },
    }
    const handlers = new Map()
    const peer = {
      addEventListener(event, callback) { handlers.set(event, callback) },
      addTransceiver,
      close() { this.closed = true },
      connectionState: "new",
      createOffer() { return Promise.resolve({type: "offer", sdp: "browser-offer"}) },
      setLocalDescription(description) { this.localDescription = description; return Promise.resolve() },
      setRemoteDescription() { return Promise.resolve() },
    }
    let claimListener
    const controller = createVoiceController({
      audioElementFactory: () => audio,
      connectionFactory: options => createVoicePeerAttempt({
        ...options,
        PeerConnection: class { constructor() { return peer } },
        negotiationId: () => "browser-negotiation",
        signaling: {
          joinVoiceChannel: async () => disabledAdmission(),
          leave() {},
          onClose() {},
          onServerIce() {},
          sendIce() {},
          sendOffer: async () => ({
            signaling_session_id: "server-session",
            negotiation_id: "browser-negotiation",
            description: {type: "answer", sdp: "server-answer"},
          }),
        },
      }),
      mediaDevices: {getUserMedia: () => Promise.resolve(stream(microphoneTrack))},
      tabCoordination: {
        publish() {},
        subscribe(listener) { claimListener = listener },
      },
      tabId: "tab-a",
    })

    await controller.join({id: "voice-1", name: "lobby", workspaceId: "workspace-1"})
    handlers.get("track")({streams: [{id: "remote-stream"}], track: {id: "echo"}})
    await new Promise(resolve => setImmediate(resolve))
    if (action === "takeover") claimListener({tabId: "tab-b", timestamp: Number.MAX_SAFE_INTEGER})
    else controller.teardown()

    assert.equal(audio.pauseCalls, 1)
    assert.equal(audio.srcObject, null)
    assert.equal(peer.closed, true)
  }
})

test("a terminal connection failure releases controller-owned capture and returns to ordinary Join", async () => {
  const microphoneTrack = track()
  let attempt
  const controller = createVoiceController({
    connectionFactory(options) {
      attempt = options
      return {leave() {}}
    },
    mediaDevices: {getUserMedia: () => Promise.resolve(stream(microphoneTrack))},
  })

  await controller.join({id: "voice-1", name: "lobby", workspaceId: "workspace-1"})
  attempt.onFailure("connection_failed")

  assert.equal(microphoneTrack.stopped, true)
  assert.deepEqual(controller.state(), {channelId: null, channelName: null, status: "idle", connectionStatus: "idle", localMuted: false, muted: false, deafened: false, workspaceId: null})
})

test("a four-slot compatibility failure releases capture and preserves an explicit retry", async () => {
  const microphoneTrack = track()
  let attempt
  const controller = createVoiceController({
    connectionFactory(options) {
      attempt = options
      return {leave() {}}
    },
    mediaDevices: {getUserMedia: () => Promise.resolve(stream(microphoneTrack))},
  })

  await controller.join({id: "voice-1", name: "lobby", workspaceId: "workspace-1"})
  attempt.onFailure("incompatible_audio_output_slots")

  assert.equal(microphoneTrack.stopped, true)
  assert.deepEqual(controller.state(), {
    channelId: "voice-1",
    channelName: "lobby",
    error: "incompatible_audio_output_slots",
    retryable: true,
    status: "incompatible_audio_output_slots", connectionStatus: "incompatible_audio_output_slots", localMuted: false, muted: false, deafened: false,
    workspaceId: "workspace-1",
  })
})

test("a stale terminal callback from a retired attempt cannot release a replacement Voice Owner Tab", async () => {
  const firstTrack = track()
  const secondTrack = track()
  const attempts = []
  let captures = 0
  const controller = createVoiceController({
    connectionFactory(options) {
      attempts.push(options)
      return {leave() {}}
    },
    mediaDevices: {
      getUserMedia() {
        captures += 1
        return Promise.resolve(stream(captures === 1 ? firstTrack : secondTrack))
      },
    },
  })

  await controller.join({id: "voice-1", name: "lobby", workspaceId: "workspace-1"})
  controller.leave()
  await controller.join({id: "voice-1", name: "lobby", workspaceId: "workspace-1"})
  attempts[0].onFailure("connection_lost")

  assert.equal(controller.state().status, "joining")
  assert.equal(secondTrack.stopped, false)
})

test("a Voice Owner Tab plays browser-local roster cues only from its active Voice Channel, including while interrupted", async () => {
  const cues = []
  const microphoneTrack = track()
  let attempt
  const controller = createVoiceController({
    connectionFactory(options) {
      attempt = options
      return {leave() {}}
    },
    cuePlayer: cue => cues.push(cue),
    mediaDevices: {getUserMedia: () => Promise.resolve(stream(microphoneTrack))},
  })

  await controller.join({id: "voice-1", name: "lobby", workspaceId: "workspace-1"})
  attempt.onCue({channelId: "voice-1", cue: "join"})
  attempt.onState("interrupted")
  controller.toggleMute()
  assert.equal(controller.state().status, "muted")
  controller.toggleMute()
  assert.equal(controller.state().status, "interrupted")
  attempt.onCue({channelId: "voice-1", cue: "leave"})
  attempt.onCue({channelId: "voice-2", cue: "leave"})
  controller.leave()
  attempt.onCue({channelId: "voice-1", cue: "leave"})

  assert.deepEqual(cues, ["join", "leave"])
})

test("explicit Leave, page teardown, and an ended microphone tell the active attempt to leave before release", async () => {
  for (const action of ["leave", "teardown", "end"]) {
    const microphoneTrack = track()
    let attemptLeaves = 0
    const controller = createVoiceController({
      connectionFactory() { return {leave() { attemptLeaves += 1 }} },
      mediaDevices: {getUserMedia: () => Promise.resolve(stream(microphoneTrack))},
    })

    await controller.join({id: "voice-1", name: "lobby", workspaceId: "workspace-1"})
    if (action === "leave") controller.leave()
    else if (action === "teardown") controller.teardown()
    else microphoneTrack.end()

    assert.equal(attemptLeaves, 1)
    assert.equal(microphoneTrack.stopped, true)
  }
})

test("browser failures have safe understandable states", async () => {
  const cases = [
    [{name: "NotAllowedError"}, "permission_denied", true],
    [{name: "NotFoundError"}, "no_device", true],
    [{name: "SecurityError"}, "insecure_context", false],
    [{name: "NotSupportedError"}, "unsupported", false],
    [{name: "UnexpectedError"}, "unknown_error", true],
  ]

  for (const [error, expected, retryable] of cases) {
    const controller = createVoiceController({mediaDevices: {getUserMedia: () => Promise.reject(error)}})
    await controller.join({id: "voice-1", name: "lobby", workspaceId: "workspace-1"})
    assert.equal(controller.state().status, expected)
    assert.equal(controller.state().retryable, retryable)
  }

  const unsupported = createVoiceController({mediaDevices: undefined})
  await unsupported.join({id: "voice-1", name: "lobby", workspaceId: "workspace-1"})
  assert.equal(unsupported.state().status, "unsupported")
  assert.equal(unsupported.state().retryable, false)

  const insecure = createVoiceController({mediaDevices: {getUserMedia() { throw new Error("must not request") }}, secureContext: false})
  await insecure.join({id: "voice-1", name: "lobby", workspaceId: "workspace-1"})
  assert.equal(insecure.state().status, "insecure_context")
  assert.equal(insecure.state().retryable, false)
})

test("retry makes a fresh request for the failed Voice Channel", async () => {
  const capture = deferred()
  let requests = 0
  const controller = createVoiceController({
    mediaDevices: {
      getUserMedia() {
        requests += 1
        return requests === 1 ? Promise.reject({name: "NotAllowedError"}) : capture.promise
      },
    },
  })
  const microphoneTrack = track()

  await controller.join({id: "voice-1", name: "lobby", workspaceId: "workspace-1"})
  const retry = controller.retry()
  capture.resolve(stream(microphoneTrack))
  await retry

  assert.equal(requests, 2)
  assert.equal(controller.state().status, "capturing")
})

test("rejoining an active Voice Channel is idempotent and switching stops old tracks first", async () => {
  const first = deferred()
  const second = deferred()
  let requests = 0
  const controller = createVoiceController({
    mediaDevices: {getUserMedia: () => ++requests === 1 ? first.promise : second.promise},
  })
  const firstTrack = track()
  const secondTrack = track()

  const initialJoin = controller.join({id: "voice-1", name: "lobby", workspaceId: "workspace-1"})
  first.resolve(stream(firstTrack))
  await initialJoin
  await controller.join({id: "voice-1", name: "lobby", workspaceId: "workspace-1"})
  assert.equal(requests, 1)

  const switchJoin = controller.join({id: "voice-2", name: "standup", workspaceId: "workspace-1"})
  assert.equal(firstTrack.stopped, true)
  second.resolve(stream(secondTrack))
  await switchJoin
  assert.deepEqual(controller.state(), {channelId: "voice-2", channelName: "standup", status: "capturing", connectionStatus: "capturing", localMuted: false, muted: false, deafened: false, workspaceId: "workspace-1"})
})

test("conflicting Voice Channel clicks do not create more permission requests while one is pending", async () => {
  const capture = deferred()
  let requests = 0
  const controller = createVoiceController({
    mediaDevices: {getUserMedia: () => { requests += 1; return capture.promise }},
  })

  const firstJoin = controller.join({id: "voice-1", name: "lobby", workspaceId: "workspace-1"})
  await controller.join({id: "voice-2", name: "standup", workspaceId: "workspace-1"})
  await controller.join({id: "voice-3", name: "planning", workspaceId: "workspace-1"})

  assert.equal(requests, 1)
  assert.equal(controller.state().channelId, "voice-1")
  capture.resolve(stream(track()))
  await firstJoin
})

test("an externally ended track and repeated teardown release all local ownership", async () => {
  const microphoneTrack = track()
  const secondaryTrack = track()
  const controller = createVoiceController({mediaDevices: {getUserMedia: () => Promise.resolve(stream(microphoneTrack, secondaryTrack))}})

  await controller.join({id: "voice-1", name: "lobby", workspaceId: "workspace-1"})
  microphoneTrack.end()

  assert.deepEqual(controller.state(), {
    channelId: "voice-1",
    channelName: "lobby",
    error: "externally_ended",
    retryable: true,
    status: "externally_ended", connectionStatus: "externally_ended", localMuted: false, muted: false, deafened: false,
    workspaceId: "workspace-1",
  })
  assert.equal(microphoneTrack.stopped, true)
  assert.equal(secondaryTrack.stopped, true)

  controller.teardown()
  controller.teardown()
  assert.deepEqual(controller.state(), {channelId: null, channelName: null, status: "idle", connectionStatus: "idle", localMuted: false, muted: false, deafened: false, workspaceId: null})
})

test("a newer Voice Owner Tab claim releases active capture and explains the takeover", async () => {
  const network = tabNetwork()
  const microphoneTrack = track()
  const first = createVoiceController({
    mediaDevices: {getUserMedia: () => Promise.resolve(stream(microphoneTrack))},
    tabCoordination: network.connect(),
    tabId: "tab-a",
    now: () => 100,
  })
  const second = createVoiceController({
    mediaDevices: {getUserMedia: () => Promise.resolve(stream(track()))},
    tabCoordination: network.connect(),
    tabId: "tab-b",
    now: () => 101,
  })

  await first.join({id: "voice-1", name: "lobby", workspaceId: "workspace-1"})
  await second.join({id: "voice-2", name: "standup", workspaceId: "workspace-1"})

  assert.equal(microphoneTrack.stopped, true)
  assert.deepEqual(first.state(), {
    channelId: "voice-1",
    channelName: "lobby",
    error: "taken_over",
    retryable: false,
    status: "taken_over", connectionStatus: "taken_over", localMuted: false, muted: false, deafened: false,
    workspaceId: "workspace-1",
  })
  assert.equal(second.state().status, "capturing")
})

test("a remote claim invalidates a pending request and stops its late stream", async () => {
  const network = tabNetwork()
  const capture = deferred()
  const lateTrack = track()
  const first = createVoiceController({
    mediaDevices: {getUserMedia: () => capture.promise},
    tabCoordination: network.connect(),
    tabId: "tab-a",
    now: () => 100,
  })
  const second = createVoiceController({
    mediaDevices: {getUserMedia: () => Promise.resolve(stream(track()))},
    tabCoordination: network.connect(),
    tabId: "tab-b",
    now: () => 101,
  })

  const join = first.join({id: "voice-1", name: "lobby", workspaceId: "workspace-1"})
  await second.join({id: "voice-2", name: "standup", workspaceId: "workspace-1"})
  capture.resolve(stream(lateTrack))
  await join

  assert.equal(first.state().status, "taken_over")
  assert.equal(lateTrack.stopped, true)
})

test("claim arbitration uses tab ID for equal timestamps without takeover ping-pong", async () => {
  const network = tabNetwork()
  const firstTrack = track()
  const secondTrack = track()
  const first = createVoiceController({
    mediaDevices: {getUserMedia: () => Promise.resolve(stream(firstTrack))},
    tabCoordination: network.connect(),
    tabId: "tab-a",
    now: () => 100,
  })
  const second = createVoiceController({
    mediaDevices: {getUserMedia: () => Promise.resolve(stream(secondTrack))},
    tabCoordination: network.connect(),
    tabId: "tab-b",
    now: () => 100,
  })

  await first.join({id: "voice-1", name: "lobby", workspaceId: "workspace-1"})
  await second.join({id: "voice-2", name: "standup", workspaceId: "workspace-1"})

  assert.equal(first.state().status, "taken_over")
  assert.equal(firstTrack.stopped, true)
  assert.equal(second.state().status, "capturing")
  assert.equal(secondTrack.stopped, false)
})

test("simultaneous claims converge on the same tab regardless of delivery order", () => {
  for (const order of [[0, 1], [1, 0]]) {
    const network = queuedTabNetwork()
    const first = createVoiceController({
      mediaDevices: {getUserMedia: () => new Promise(() => {})},
      tabCoordination: network.connect(),
      tabId: "tab-a",
      now: () => 100,
    })
    const second = createVoiceController({
      mediaDevices: {getUserMedia: () => new Promise(() => {})},
      tabCoordination: network.connect(),
      tabId: "tab-b",
      now: () => 100,
    })

    first.join({id: "voice-1", name: "lobby", workspaceId: "workspace-1"})
    second.join({id: "voice-2", name: "standup", workspaceId: "workspace-1"})
    network.deliver(order)

    assert.equal(first.state().status, "taken_over")
    assert.equal(second.state().status, "requesting")
  }
})

test("older claims and unavailable tab coordination leave local capture safe and usable", async () => {
  const microphoneTrack = track()
  let deliverClaim
  const controller = createVoiceController({
    mediaDevices: {getUserMedia: () => Promise.resolve(stream(microphoneTrack))},
    tabCoordination: {
      publish() { throw new Error("blocked") },
      subscribe(listener) {
        deliverClaim = listener
      },
    },
    tabId: "tab-b",
    now: () => 100,
  })

  await controller.join({id: "voice-1", name: "lobby", workspaceId: "workspace-1"})
  assert.equal(controller.state().status, "capturing")

  // A stale message delivered by a transport that becomes available later cannot steal capture.
  deliverClaim({tabId: "tab-a", timestamp: 99})
  assert.equal(controller.state().status, "capturing")
  assert.equal(microphoneTrack.stopped, false)
})

for (const initiallyMuted of [false, true]) {
  test(`deafen survives interruption and recovery, restoring mute=${initiallyMuted}`, async () => {
    const microphone = track()
    const roster = []
    const playback = []
    let attempt
    const controller = createVoiceController({
      tabCoordination: null,
      mediaDevices: {getUserMedia: async () => stream(microphone)},
      connectionFactory(options) {
        attempt = options
        return {
          leave() {},
          setDeafened(value) { playback.push(value) },
          updateLocalVoiceState(value) { roster.push(value) },
        }
      },
    })
    await controller.join({id: "voice-1", name: "lobby"})
    attempt.onState("connected")
    if (initiallyMuted) controller.toggleMute()
    controller.toggleDeafen()
    attempt.onPlayback("blocked")
    attempt.onState("interrupted")
    assert.equal(controller.state().deafened, true)
    assert.equal(controller.state().connectionStatus, "interrupted")
    assert.equal(controller.state().audioPlayback, "blocked")
    assert.equal(microphone.enabled, false)
    attempt.onState("connected")
    assert.deepEqual(roster.at(-1), {muted: true, deafened: true})
    assert.equal(playback.at(-1), true)
    controller.toggleDeafen()
    assert.equal(controller.state().status, initiallyMuted ? "muted" : "connected")
    assert.equal(microphone.enabled, !initiallyMuted)
    assert.equal(playback.at(-1), false)
    assert.deepEqual(roster.at(-1), {muted: initiallyMuted, deafened: false})
    controller.leave()
  })
}

for (const initiallyMuted of [false, true]) {
  test(`joining, ended-track retry, stale callbacks, and leave preserve the intended controls (mute=${initiallyMuted})`, async () => {
    const captures = []
    const attempts = []
    const microphones = []
    const cues = []
    let takeover
    const controller = createVoiceController({
      tabId: "tab-a",
      now: () => 1,
      tabCoordination: {publish() {}, subscribe(listener) { takeover = listener }},
      cuePlayer: cue => cues.push(cue),
      mediaDevices: {getUserMedia() { const capture = deferred(); captures.push(capture); return capture.promise }},
      connectionFactory(options) {
        const attempt = {options, playback: [], roster: [], leaves: 0,
          leave() { this.leaves += 1 },
          setDeafened(value) { this.playback.push(value) },
          updateLocalVoiceState(value) { this.roster.push(value) },
        }
        attempts.push(attempt)
        return attempt
      },
    })
    const join = controller.join({id: "voice-1", name: "lobby"})
    if (initiallyMuted) controller.toggleMute()
    controller.toggleDeafen()
    const first = track()
    microphones.push(first)
    captures[0].resolve(stream(first))
    await join
    assert.equal(controller.state().connectionStatus, "joining")
    assert.equal(first.enabled, false)
    assert.equal(attempts[0].playback.at(-1), true)
    first.end()
    assert.equal(first.stopped, true)
    assert.equal(controller.state().retryable, true)
    const retry = controller.retry()
    const second = track()
    microphones.push(second)
    captures[1].resolve(stream(second))
    await retry
    for (const callback of [
      () => attempts[0].options.onState("connected"),
      () => attempts[0].options.onPlayback("blocked"),
      () => attempts[0].options.onCue({channelId: "voice-1", cue: "join"}),
      () => attempts[0].options.onFailure("connection_lost"),
    ]) callback()
    assert.equal(controller.state().connectionStatus, "joining")
    assert.equal(controller.state().audioPlayback, undefined)
    assert.equal(second.stopped, false)
    assert.equal(second.enabled, false)
    assert.equal(attempts[1].playback.at(-1), true)
    assert.deepEqual(attempts[1].roster.at(-1), {muted: true, deafened: true})
    assert.deepEqual(cues, [])
    attempts[1].options.onState("connected")
    controller.toggleDeafen()
    assert.equal(second.enabled, !initiallyMuted)
    assert.equal(controller.state().localMuted, initiallyMuted)
    controller.toggleDeafen()
    takeover({tabId: "tab-b", timestamp: 2})
    assert.equal(controller.state().status, "taken_over")
    assert.equal(second.stopped, true)
    attempts[1].options.onState("connected")
    assert.equal(controller.state().status, "taken_over")
    controller.leave()
    assert.equal(controller.state().muted, false)
    assert.equal(controller.state().deafened, false)
    const freshJoin = controller.join({id: "voice-1", name: "lobby"})
    const third = track()
    microphones.push(third)
    captures[2].resolve(stream(third))
    await freshJoin
    assert.equal(third.enabled, true)
    assert.equal(attempts[2].playback.at(-1), false)
    controller.leave()
    assert.ok(microphones.every(microphone => microphone.stopped))
    assert.ok(attempts.every(attempt => attempt.leaves === 1))
  })
}

test("the real peer publishes controls at admission and signaling recovery and keeps newly attached audio deafened", async () => {
  const admission = deferred()
  const roster = []
  const handlers = new Map()
  const timers = new Map()
  let acknowledge
  const microphone = track()
  const audio = {muted: false, play: async () => {}, pause() {}}
  const peer = {
    transceivers: [],
    connectionState: "new",
    addEventListener(event, callback) { handlers.set(event, callback) },
    addTransceiver(...args) { const value = addTransceiver(...args); this.transceivers.push(value); return value },
    close() {},
    createOffer: async () => ({type: "offer", sdp: "browser-offer"}),
    async setLocalDescription(description) { this.localDescription = description },
    async setRemoteDescription() {},
  }
  let connectionReady
  const controller = createVoiceController({
    tabCoordination: null,
    mediaDevices: {getUserMedia: async () => stream(microphone)},
    audioElementFactory: () => audio,
    connectionFactory(options) {
      const attempt = createVoicePeerAttempt({
        ...options,
        PeerConnection: class { constructor() { return peer } },
        negotiationId: () => "browser-negotiation",
        setTimeoutFn(callback, delay) { const token = {}; timers.set(token, {callback, delay}); return token },
        clearTimeoutFn(token) { timers.delete(token) },
        signaling: {
          joinVoiceChannel: () => admission.promise,
          leave() {}, onClose() {}, onServerIce() {},
          sendLocalVoiceState(state) { roster.push(state) },
          renewVoiceSession() { return {receive(status, callback) { if (status === "ok") acknowledge = callback; return this }} },
          sendOffer: async () => ({signaling_session_id: "server-session", negotiation_id: "browser-negotiation", description: {type: "answer", sdp: "server-answer"}}),
        },
      })
      return {...attempt, connect(args) { connectionReady = attempt.connect(args); return connectionReady }}
    },
  })
  await controller.join({id: "voice-1", name: "lobby"})
  controller.toggleDeafen()
  assert.deepEqual(roster, [])
  admission.resolve(disabledAdmission())
  await connectionReady
  assert.deepEqual(roster.at(-1), {muted: true, deafened: true})
  peer.connectionState = "connected"
  handlers.get("connectionstatechange")()
  const transceiver = peer.transceivers[1]
  handlers.get("track")({track: transceiver.receiver.track, transceiver})
  await Promise.resolve()
  assert.equal(audio.muted, true)
  assert.equal(microphone.enabled, false)
  assert.equal(controller.state().connectionStatus, "connected")
  const fire = delay => {
    const [token, timer] = [...timers].find(([, timer]) => timer.delay === delay)
    timers.delete(token)
    timer.callback()
  }
  fire(30_000)
  fire(10_000)
  assert.equal(controller.state().connectionStatus, "interrupted")
  controller.toggleDeafen()
  controller.toggleMute()
  const beforeRecovery = roster.length
  acknowledge({signaling_session_id: "server-session"})
  assert.ok(roster.length > beforeRecovery)
  assert.deepEqual(roster.at(-1), {muted: true, deafened: false})
  assert.equal(controller.state().connectionStatus, "connected")
  assert.equal(microphone.enabled, false)
  assert.equal(audio.muted, false)
  controller.leave()
  assert.equal(timers.size, 0)
  assert.equal(audio.srcObject, null)
})
