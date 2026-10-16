import assert from "node:assert/strict"
import test from "node:test"
import {getEventListeners} from "node:events"
import {createCallPeerAttempt} from "./call_peer_attempt.js"

function deferred() {
  let resolve
  const promise = new Promise(r => { resolve = r })
  return {promise, resolve}
}
function harness({answer, credentials, play = async () => {}, replaceCamera, applyAnswer,
  codecCapabilities = kind => ({codecs: [{mimeType: kind === "audio" ? "audio/opus" : "video/VP8"}]}),
} = {}) {
  const timers = new Map(), sent = [], peers = [], states = [], playback = [], failures = [], cameras = [], remoteVideos = [], videoBindings = []
  let ice, subscriber
  const identity = {call_id: "call", call_session_id: "media", signaling_session_id: "topic"}
  const track = {kind: "audio", readyState: "live"}
  const audio = Object.assign(new EventTarget(), {play, pause() {}, srcObject: null})
  let currentState = {connectionStatus: "connected", callTopicStatus: "joined",
    call: {call_id: "call", ownership: "self", state: "connecting", role: "caller"}}
  const signaling = {
    mediaSessionIsCurrent: session => session.call_id === "call" && session.signaling_session_id === "topic",
    getState: () => currentState,
    subscribe(fn) { subscriber = fn; return () => { subscriber = null } },
    onServerIce(fn) { ice = fn; return () => { ice = null } },
    async mediaCredentials() {
      return credentials?.() ?? {ok: true, ...identity, ice_config: {ice_mode: "disabled", ice_servers: [], ice_transport_policy: "all"}}
    },
    sendMedia(event, payload) {
      sent.push({event, payload})
      if (event === "offer") return answer?.promise ?? Promise.resolve({ok: true, ...payload, description: {type: "answer", sdp: "answer"}})
      return Promise.resolve({ok: true, ...payload})
    },
  }
  class Stream {
    tracks = []
    addTrack(track) { this.tracks.push(track) }
    removeTrack(track) { this.tracks = this.tracks.filter(t => t !== track) }
    getTracks() { return this.tracks }
  }
  class Peer {
    constructor(config) { this.config = config; this.transceivers = []; this.handlers = new Map(); this.candidates = []; peers.push(this) }
    addTransceiver(source, options) {
      const trackEvents = new Map()
      const t = {mid: null, currentDirection: null, direction: options.direction,
        sender: {track: typeof source === "string" ? null : source,
          parameters: {encodings: [{active: true}]},
          getParameters() {return structuredClone(this.parameters)},
          async setParameters(parameters) {this.parameters = structuredClone(parameters)},
          async replaceTrack(track) {await replaceCamera?.(track); this.track = track}}, receiver: {track: {kind: typeof source === "string" ? source : "audio", addEventListener(event, fn) { trackEvents.set(event, fn) }, removeEventListener(event) { trackEvents.delete(event) }, end() { trackEvents.get("ended")?.() }}}, setCodecPreferences(codecs) { this.codecs = codecs }}
      this.transceivers.push(t)
      return t
    }
    addEventListener(event, fn) { this.handlers.set(event, fn) }
    removeEventListener(event) { this.handlers.delete(event) }
    emit(event, payload) { this.handlers.get(event)?.(payload) }
    async createOffer() { return {type: "offer", sdp: "offer"} }
    async setLocalDescription(d) {
      this.localDescription = d
      this.transceivers.forEach((t, i) => {t.mid = String(i)})
    }
    async setRemoteDescription(d) {
      await applyAnswer?.(this)
      this.remoteDescription = d
      this.transceivers.forEach(t => {t.currentDirection = "sendrecv"})
    }
    getTransceivers() {return [...this.transceivers]}
    async addIceCandidate(c) { this.candidates.push(c) }
    close() { this.closed = true }
  }
  const attempt = createCallPeerAttempt({signaling, PeerConnection: Peer, MediaStream: Stream,
    codecCapabilities,
    onRemoteVideo: (track, binding) => {remoteVideos.push(track); videoBindings.push(binding)},
    negotiationId: () => "n", remoteAudio: audio, onState: s => states.push(s), onPlayback: s => playback.push(s), onFailure: s => failures.push(s), onCamera: (state, error) => cameras.push({state, error}),
    setTimeoutFn(fn, ms) {
      const id = {}
      timers.set(id, {fn() {timers.delete(id); fn()}, ms})
      return id
    }, clearTimeoutFn(id) { timers.delete(id) },
  })
  return {attempt, peers, track, audio, sent, timers, states, playback, failures, identity, cameras, remoteVideos, videoBindings,
    ice: payload => ice?.({...identity, negotiation_id: "n", ...payload}),
    project(remote) {currentState = {...currentState, call: {...currentState.call, media_state: {recipient: remote}}}; subscriber?.(currentState)},
    lose: () => subscriber?.({connectionStatus: "unavailable"}),
    connect: () => attempt.connect({callId: "call", track}),
  }
}

test("pending pair publication retries discovery and negotiates once after it becomes available", async () => {
  let published = false, discoveries = 0
  const h = harness({credentials: () => {
    discoveries++
    if (!published) return {ok: false, error: "not_admitted"}
  }})
  const connecting = h.connect()
  for (let i = 0; i < 8; i++) await Promise.resolve()
  assert.equal(h.peers.length, 0)
  assert.equal(h.failures.length, 0)
  assert.equal(h.track.readyState, "live")
  const retry = [...h.timers.values()].find(t => t.ms === 250)
  assert.ok(retry)
  published = true
  retry.fn()
  await connecting
  assert.equal(discoveries, 2)
  assert.equal(h.peers.length, 1)
  assert.equal(h.sent.filter(x => x.event === "offer").length, 1)
  h.attempt.leave()
  assert.equal(h.timers.size, 0)
})

test("unpublished pair discovery has one fixed budget across retries", async () => {
  const h = harness({credentials: () => ({ok: false, error: "not_admitted"})})
  const rejected = assert.rejects(h.connect())
  for (let i = 0; i < 8; i++) await Promise.resolve()
  const deadline = [...h.timers.values()].find(t => t.ms === 20_000)
  const retry = [...h.timers.values()].find(t => t.ms === 250)
  retry.fn()
  for (let i = 0; i < 8; i++) await Promise.resolve()
  assert.equal([...h.timers.values()].find(t => t.ms === 20_000), deadline)
  deadline.fn()
  await rejected
  assert.deepEqual(h.failures, ["connection_lost"])
  assert.equal(h.peers.length, 0)
  assert.equal(h.timers.size, 0)
})

test("owner loss during pending publication cancels retries without late allocation", async () => {
  let discoveries = 0
  const h = harness({credentials: () => {discoveries++; return {ok: false, error: "not_admitted"}}})
  const rejected = assert.rejects(h.connect())
  for (let i = 0; i < 8; i++) await Promise.resolve()
  const oldRetry = [...h.timers.values()].find(t => t.ms === 250)
  h.lose()
  await rejected
  oldRetry.fn()
  for (let i = 0; i < 8; i++) await Promise.resolve()
  assert.equal(discoveries, 1)
  assert.equal(h.peers.length, 0)
  assert.equal(h.timers.size, 0)
  assert.deepEqual(h.failures, ["connection_lost"])
})

test("discovery errors other than pending admission fail without retrying", async () => {
  const h = harness({credentials: () => ({ok: false, error: "invalid_request"})})
  await assert.rejects(h.connect())
  assert.equal(h.timers.size, 0)
  assert.deepEqual(h.failures, ["connection_lost"])
})

test("Call keeps browser RTX capability with VP8 while excluding other primary codecs", async () => {
  const h = harness({codecCapabilities: kind => ({codecs: kind === "audio"
    ? [{mimeType: "audio/opus"}, {mimeType: "audio/PCMU"}]
    : [{mimeType: "video/VP8"}, {mimeType: "video/rtx"}, {mimeType: "video/H264"},
      {mimeType: "video/red"}, {mimeType: "video/ulpfec"}]})})
  await h.connect()
  assert.deepEqual(h.peers[0].transceivers.map(t => t.codecs.map(c => c.mimeType)),
    [["audio/opus"], ["video/VP8", "video/rtx"]])
  h.attempt.leave()
})

test("RTX without VP8 fails the Call attempt before sending an offer", async () => {
  const h = harness({codecCapabilities: kind => ({codecs: [
    {mimeType: kind === "audio" ? "audio/opus" : "video/rtx"},
  ]})})
  await assert.rejects(h.connect())
  assert.equal(h.peers[0].closed, true)
  assert.equal(h.sent.some(message => message.event === "offer"), false)
})

test("Call offers exactly duplex Opus and dormant VP8 and plays only the expected audio receiver", async () => {
  const h = harness({play: async () => { throw Error("blocked") }})
  await h.connect()
  const pc = h.peers[0]
  assert.equal(h.peers.length, 1)
  assert.deepEqual(pc.transceivers.map(t => [t.direction, t.sender.track?.kind ?? null, t.codecs[0].mimeType]), [["sendrecv", "audio", "audio/opus"], ["sendrecv", null, "video/VP8"]])
  const stream = h.audio.srcObject
  pc.emit("track", {track: {kind: "audio"}, transceiver: pc.transceivers[1]})
  assert.equal(stream.getTracks().length, 0)
  const remote = pc.transceivers[0].receiver.track
  pc.emit("track", {track: remote, transceiver: pc.transceivers[0]})
  pc.emit("track", {track: remote, transceiver: pc.transceivers[0]})
  await Promise.resolve()
  assert.deepEqual(stream.getTracks(), [remote])
  assert.deepEqual(h.playback, ["blocked"])
  pc.connectionState = "connected"; pc.emit("connectionstatechange")
  assert.equal(h.states.at(-1), "connected")
  h.attempt.leave()
  assert.equal(pc.closed, true)
  assert.equal(h.audio.srcObject, null)
  assert.equal(pc.handlers.size, 0)
  assert.equal(h.timers.size, 0)
})

test("streamless video binds only the exact current receiver and releases its listener on Leave", async () => {
  const h = harness()
  await h.connect()
  const pc = h.peers[0], video = pc.transceivers[1], track = video.receiver.track
  pc.emit("track", {track: {kind: "video"}, transceiver: video, streams: []})
  pc.emit("track", {track, transceiver: pc.transceivers[0], streams: []})
  assert.deepEqual(h.remoteVideos, [])
  pc.emit("track", {track, transceiver: video, streams: []})
  pc.emit("track", {track, transceiver: video, streams: []})
  assert.deepEqual(h.remoteVideos, [track])
  assert.deepEqual(h.audio.srcObject.getTracks(), [])
  h.attempt.leave()
  assert.equal(h.remoteVideos.at(-1), null)
  const count = h.remoteVideos.length
  track.end()
  pc.emit("track", {track, transceiver: video, streams: []})
  assert.equal(h.remoteVideos.length, count)
})

test("video decode evidence belongs to only the current negotiated receiver", async () => {
  const h = harness()
  await h.connect()
  const pc = h.peers[0], video = pc.transceivers[1], track = video.receiver.track
  track.id = "remote-camera"
  const own = {type: "inbound-rtp", kind: "video", trackIdentifier: track.id,
    framesDecoded: 2, keyFramesDecoded: 1}
  let resolve
  video.receiver.getStats = () => new Promise(r => {resolve = r})
  pc.emit("track", {track, transceiver: video, streams: []})
  const binding = h.videoBindings.at(-1), reading = binding.readDecode()
  resolve(new Map([["own", own], ["foreign", {...own, trackIdentifier: "foreign", framesDecoded: 99}]]))
  assert.deepEqual(await reading, {framesDecoded: 2, keyFramesDecoded: 1})
  const stale = binding.readDecode()
  h.attempt.leave()
  resolve(new Map([["own", own]]))
  assert.equal(await stale, null)
  assert.equal(await binding.readDecode(), null)
})

test("presentation routes fence the retained receiver, off generations and obsolete signaling", async () => {
  const h = harness()
  await h.connect()
  const pc = h.peers[0], video = pc.transceivers[1]
  pc.emit("track", {track: video.receiver.track, transceiver: video})
  h.ice({video_presentation: {epoch: 1, camera_version: 1, rtp_timestamp: null}})
  const old = h.videoBindings.at(-1)
  h.ice({video_presentation: {epoch: 1, camera_version: 1, rtp_timestamp: 9000}})
  assert.deepEqual(old.presentation(), {epoch: 1, camera_version: 1, rtp_timestamp: 9000})
  h.project({camera_enabled: false, media_state_version: 2})
  assert.equal(old.isCurrent(), false)
  h.project({camera_enabled: true, media_state_version: 3})
  assert.equal(old.isCurrent(), false)
  h.ice({video_presentation: {epoch: 2, camera_version: null, rtp_timestamp: null}})
  assert.equal(old.isCurrent(), false)
  h.ice({video_presentation: {epoch: 3, camera_version: 3, rtp_timestamp: null}})
  const current = h.videoBindings.at(-1)
  h.ice({video_presentation: {epoch: 1, camera_version: 1, rtp_timestamp: 9000}})
  h.ice({negotiation_id: "retired", video_presentation: {epoch: 4, camera_version: 3, rtp_timestamp: 15000}})
  assert.equal(current.presentation(), null)
  h.ice({video_presentation: {epoch: 3, camera_version: 3, rtp_timestamp: 15000}})
  assert.equal(current.presentation().rtp_timestamp, 15000)
  for (const timestamp of [18000, 21000, 24000, 27000]) h.ice({video_presentation: {epoch: 3, camera_version: 3, rtp_timestamp: timestamp}})
  assert.equal(current.presentation(15000), null)
  assert.equal(current.presentation(18000).rtp_timestamp, 18000)
  assert.equal(current.presentation(24001), null)
  assert.equal(pc.transceivers[1].receiver, video.receiver)
  h.attempt.leave()
  assert.equal(current.isCurrent(), false)
})

test("ICE is fenced and buffered through answer, including end-of-candidates", async () => {
  const answer = deferred(), h = harness({answer})
  const connecting = h.connect()
  for (let i = 0; i < 8; i++) await Promise.resolve()
  const candidate = {candidate: "candidate:expected"}
  h.ice({candidate, call_session_id: "stale"})
  h.ice({candidate})
  h.ice({end_of_candidates: true})
  assert.deepEqual(h.peers[0].candidates, [])
  answer.resolve({ok: true, ...h.identity, negotiation_id: "n", description: {type: "answer", sdp: "answer"}})
  await connecting
  assert.deepEqual(h.peers[0].candidates, [candidate, {candidate: ""}])
  h.attempt.leave()
})

test("late answer cannot attach to retired peer or clear replacement playback", async () => {
  const answer = deferred(), h = harness({answer})
  const connecting = h.connect()
  const rejected = assert.rejects(connecting)
  for (let i = 0; i < 8; i++) await Promise.resolve()
  h.attempt.leave()
  const replacement = {replacement: true}
  h.audio.srcObject = replacement
  answer.resolve({ok: true, ...h.identity, negotiation_id: "n", description: {type: "answer", sdp: "answer"}})
  await rejected
  assert.equal(h.peers[0].remoteDescription, undefined)
  assert.equal(h.audio.srcObject, replacement)
  assert.equal(h.timers.size, 0)
  assert.equal(h.failures.length, 0)
})

test("offer budget expiry closes the exact peer and cancels its timers", async () => {
  const h = harness({answer: deferred()})
  const rejected = assert.rejects(h.connect())
  for (let i = 0; i < 8; i++) await Promise.resolve()
  const offerTimer = [...h.timers.values()].find(t => t.ms === 10_000)
  assert.ok(offerTimer)
  offerTimer.fn()
  await rejected
  assert.equal(h.peers[0].closed, true)
  assert.equal(h.timers.size, 0)
  assert.deepEqual(h.failures, ["connection_lost"])
})

for (const trigger of ["signaling", "failed", "closed", "overflow"]) {
  test(`${trigger} failure releases the exact media synchronously`, async () => {
    const h = harness()
    await h.connect()
    const pc = h.peers[0]
    if (trigger === "signaling") h.lose()
    else if (trigger === "overflow") h.ice({candidate: {candidate: "x".repeat(8192)}})
    else { pc.connectionState = trigger; pc.emit("connectionstatechange") }
    assert.equal(pc.closed, true)
    assert.equal(h.audio.srcObject, null)
    assert.equal(h.timers.size, 0)
    assert.deepEqual(h.failures, ["connection_lost"])
  })
}

test("renewal carries exact Session identity without another offer; disconnection keeps one grace", async () => {
  const h = harness()
  await h.connect()
  const pc = h.peers[0]
  const renewal = [...h.timers.values()].find(t => t.ms === 30_000)
  renewal.fn()
  await Promise.resolve(); await Promise.resolve()
  assert.deepEqual(h.sent.find(s => s.event === "renew").payload, h.identity)
  assert.equal(h.sent.filter(s => s.event === "offer").length, 1)
  pc.connectionState = "disconnected"; pc.emit("connectionstatechange")
  const timers = h.timers.size
  pc.emit("connectionstatechange")
  assert.equal(h.timers.size, timers)
  pc.connectionState = "connected"; pc.emit("connectionstatechange")
  assert.equal(h.states.at(-1), "connected")
  h.attempt.leave()
})

for (const exit of ["receiver ended", "leave", "output replaced"]) {
  test(`pending playing events cannot report playback after ${exit}`, async () => {
    const h = harness({play: () => new Promise(() => {})})
    await h.connect()
    const transceiver = h.peers[0].transceivers[0]
    h.peers[0].emit("track", {track: transceiver.receiver.track, transceiver})
    const [queuedPlaying] = getEventListeners(h.audio, "playing")
    assert.equal(typeof queuedPlaying, "function")
    if (exit === "receiver ended") transceiver.receiver.track.end()
    else if (exit === "leave") h.attempt.leave()
    else h.audio.srcObject = {replacement: true}
    const before = [...h.playback]
    queuedPlaying()
    h.audio.dispatchEvent(new Event("playing"))
    assert.deepEqual(h.playback, before)
    if (exit !== "output replaced") assert.equal(getEventListeners(h.audio, "playing").length, 0)
    h.attempt.leave()
    assert.equal(getEventListeners(h.audio, "playing").length, 0)
  })
}

test("a superseded playing callback cannot report playback for an explicit retry", async () => {
  const h = harness({play: () => new Promise(() => {})})
  await h.connect()
  const transceiver = h.peers[0].transceivers[0]
  h.peers[0].emit("track", {track: transceiver.receiver.track, transceiver})
  const [oldPlaying] = getEventListeners(h.audio, "playing")
  h.attempt.enableAudio()
  oldPlaying()
  assert.deepEqual(h.playback, [])
  h.audio.dispatchEvent(new Event("playing"))
  assert.deepEqual(h.playback, ["playing"])
  h.attempt.leave()
})

for (const success of [true, false]) {
  test(`late playback ${success ? "success" : "failure"} cannot overwrite an ended receiver`, async () => {
    const playing = deferred()
    const h = harness({play: () => playing.promise.then(() => { if (!success) throw Error("blocked") })})
    await h.connect()
    const transceiver = h.peers[0].transceivers[0]
    h.peers[0].emit("track", {track: transceiver.receiver.track, transceiver})
    transceiver.receiver.track.end()
    playing.resolve()
    await Promise.resolve(); await Promise.resolve(); await Promise.resolve()
    assert.deepEqual(h.playback, ["waiting"])
    h.attempt.leave()
  })
}

test("an older blocked play promise cannot overwrite a successful explicit retry", async () => {
  const first = deferred()
  let attempts = 0
  const h = harness({play: () => ++attempts === 1 ? first.promise.then(() => {throw Error("blocked")}) : Promise.resolve()})
  await h.connect()
  const transceiver = h.peers[0].transceivers[0]
  h.peers[0].emit("track", {track: transceiver.receiver.track, transceiver})
  await h.attempt.enableAudio()
  first.resolve()
  for (let i = 0; i < 5; i++) await Promise.resolve()
  assert.deepEqual(h.playback, ["playing"])
  assert.equal(h.failures.length, 0)
  h.attempt.leave()
})

for (const success of [true, false]) {
  test(`late playback ${success ? "success" : "failure"} and deafen controls cannot affect replacement audio`, async () => {
    const pending = deferred()
    const h = harness({play: () => pending.promise.then(() => {if (!success) throw Error("blocked")})})
    h.attempt.setDeafened(true)
    await h.connect()
    assert.equal(h.audio.muted, true)
    const transceiver = h.peers[0].transceivers[0]
    h.peers[0].emit("track", {track: transceiver.receiver.track, transceiver})
    h.attempt.leave()
    const replacement = {replacement: true}
    h.audio.srcObject = replacement
    h.audio.muted = false
    h.attempt.setDeafened(true)
    h.attempt.enableAudio()
    pending.resolve()
    for (let i = 0; i < 5; i++) await Promise.resolve()
    assert.equal(h.audio.srcObject, replacement)
    assert.equal(h.audio.muted, false)
    assert.deepEqual(h.playback, [])
    assert.deepEqual(h.failures, [])
  })
}


test("prepared camera waits for application of the current answer, retaining its exact negotiated sender", async () => {
  const answer = deferred(), remote = deferred()
  const camera = {kind: "video", readyState: "live", enabled: true, getSettings: () => ({width: 960, height: 540, frameRate: 24})}
  const h = harness({answer, applyAnswer: () => remote.promise})
  const connecting = h.attempt.connect({callId: "call", track: h.track, cameraTrack: camera})
  for (let i = 0; i < 12; i++) await Promise.resolve()
  const pc = h.peers[0], video = pc.transceivers[1]
  assert.equal(video.sender.track, null)
  answer.resolve({ok: true, ...h.identity, negotiation_id: "n", description: {type: "answer", sdp: "answer"}})
  for (let i = 0; i < 12; i++) await Promise.resolve()
  assert.equal(video.sender.track, null)
  assert.equal(h.sent.some(s => s.payload.camera_enabled), false)
  // API enumeration order is not identity; both original objects stay current.
  pc.transceivers.reverse()
  remote.resolve()
  await connecting
  for (let i = 0; i < 12; i++) await Promise.resolve()
  assert.equal(video.sender.track, camera)
  assert.equal(h.sent.filter(s => s.event === "local_media_state").at(-1).payload.camera_enabled, true)
  assert.equal(h.sent.filter(s => s.event === "offer").length, 1)
  assert.equal(pc.transceivers.length, 2)
  h.attempt.leave()
})

for (const changed of ["mid", "sender", "direction", "track enabled"]) {
  test(`a changed ${changed} while replaceTrack is pending cannot publish camera enabled`, async () => {
    const replacement = deferred()
    const camera = {kind: "video", readyState: "live", enabled: true, getSettings: () => ({width: 960, height: 540, frameRate: 24})}
    const h = harness({replaceCamera: track => track && replacement.promise})
    await h.attempt.connect({callId: "call", track: h.track, cameraTrack: camera})
    for (let i = 0; i < 12; i++) await Promise.resolve()
    const video = h.peers[0].transceivers[1]
    if (changed === "mid") video.mid = "other"
    else if (changed === "sender") video.sender = {track: null}
    else if (changed === "direction") video.currentDirection = "recvonly"
    else camera.enabled = false
    replacement.resolve()
    for (let i = 0; i < 12; i++) await Promise.resolve()
    assert.equal(h.sent.some(s => s.payload.camera_enabled), false)
    assert.equal(h.cameras.at(-1).state, "error")
    assert.equal(h.failures.length, 0)
    assert.equal(h.peers[0].closed, undefined)
    h.attempt.leave()
  })
}

test("releasing prepared camera before the answer invalidates attachment without cancelling audio negotiation", async () => {
  const answer = deferred(), h = harness({answer})
  const camera = {kind: "video", readyState: "live", enabled: true, getSettings: () => ({width: 960, height: 540, frameRate: 24})}
  const connecting = h.attempt.connect({callId: "call", track: h.track, cameraTrack: camera})
  for (let i = 0; i < 12; i++) await Promise.resolve()
  h.attempt.releaseCamera()
  answer.resolve({ok: true, ...h.identity, negotiation_id: "n", description: {type: "answer", sdp: "answer"}})
  await connecting
  for (let i = 0; i < 12; i++) await Promise.resolve()
  assert.equal(h.peers[0].transceivers[1].sender.track, null)
  assert.equal(h.sent.some(s => s.payload.camera_enabled), false)
  assert.equal(h.failures.length, 0)
  h.attempt.leave()
})
