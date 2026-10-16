import assert from "node:assert/strict"
import test from "node:test"
import {getEventListeners} from "node:events"
import {installCallSignaling} from "./call_signaling_bootstrap.js"
import {createCallSignaling} from "./call_signaling.js"
import {createFakeCallDevices, createRealCallDevices} from "./call_devices.js"
import {createVoiceController} from "./hooks/voice_controller.js"
import {installCallPresenter} from "./call_presenter.js"
import {createCallController} from "./call_controller.js"
import {createCallPeerAttempt} from "./call_peer_attempt.js"

// Browser APIs and the Phoenix wire are the external boundaries here. The
// bootstrap, signaling, devices, controller, peer attempt and presenter are real.
function browser({diagnosticWrite, role = "caller", snapshot = null, permission, startReply, previewPlay, mediaReply, offerReply, acceptReply, declineReply, cancelReply, credentialsReply, iceReply, play, devices, videoAvailable, mediaDevices: injectedMediaDevices, secureContext, replaceCamera, configureCamera, cameraParameters, videoDirection = "sendrecv"} = {}) {
  const requests = [], channels = [], peers = [], tracks = [], commands = [], socketsCreated = [], timers = new Map()
  const doc = new EventTarget(), win = new EventTarget(), nodes = new Map()
  let call = snapshot, sockets = 0, acquisitions = 0, plays = 0, starts = 0
  const node = (id, action) => {
    const attrs = new Map()
    const n = {id, hidden: true, dataset: {}, textContent: "", setAttribute: (k, v) => attrs.set(k, v),
      removeAttribute: k => attrs.delete(k), getAttribute: k => attrs.get(k), disabled: false,
      closest: selector => selector === `[data-call-action='${action}']` ? n : null, focus() {doc.activeElement = n}}
    nodes.set(id, n); return n
  }
  node("call-signaling-bootstrap").dataset.callDevices = "real"
  nodes.get("call-signaling-bootstrap").dataset.callVideoAvailable = videoAvailable
  for (const id of ["direct-call-dock", "direct-call-dock-status", "direct-call-dock-peer",
    "direct-call-dock-title", "direct-call-incoming-backdrop", "direct-call-incoming-title",
    "direct-call-incoming-caller", "direct-call-incoming-intent", "direct-call-incoming-status"]) node(id)
  node("direct-call-focus-fallback").hidden = false
  const start = node("start", "start-audio")
  start.dataset = {directConversationId: "conversation", peerId: "friend", peerUsername: "Friend"}
  const startVideo = node("start-video", "start-video")
  startVideo.dataset = {...start.dataset, callAction: "start-video"}
  const preview = node("direct-call-local-preview")
  preview.srcObject = null
  preview.play = async () => previewPlay?.()
  preview.pause = () => {}
  const incomingPreview = node("direct-call-incoming-preview")
  incomingPreview.srcObject = null
  incomingPreview.play = async () => previewPlay?.()
  incomingPreview.pause = () => {}
  node("direct-call-incoming-preview-region")
  node("direct-call-incoming-preview-status")
  node("direct-call-incoming-preview-retry", "retry-preview")
  node("direct-call-incoming-decline", "decline")
  node("direct-call-incoming-cancel-preparation", "cancel")
  node("direct-call-dock-media-state")
  node("direct-call-dock-preview", "toggle-preview")
  node("direct-call-self-camera-status")
  node("direct-call-local-preview-region")
  node("direct-call-local-preview-status")
  node("direct-call-local-preview-retry", "retry-preview")
  node("direct-call-dock-start-voice-instead", "fallback-audio")
  node("direct-call-dock-retry", "retry")
  node("direct-call-dock-dismiss", "dismiss")
  node("direct-call-dock-cancel", "cancel")
  node("direct-conversation-video-unavailable-reason")
  node("direct-call-video-unavailable-reason")
  const acceptVideo = node("direct-call-incoming-accept-video", "accept-video")
  node("direct-call-incoming-answer-without-video", "answer-without-video")
  const answer = node("direct-call-incoming-accept-audio", "accept-audio")
  const leave = node("direct-call-dock-leave", "leave")
  const camera = node("direct-call-dock-camera", "toggle-camera")
  const mute = node("direct-call-dock-mute", "toggle-mute")
  const deafen = node("direct-call-dock-deafen", "toggle-deafen")
  const enableAudio = node("direct-call-dock-enable-audio", "enable-audio")
  const enable = node("direct-call-dock-enable-microphone", "enable-microphone")
  node("direct-call-remote-video-retry", "retry-video")
  doc.getElementById = id => nodes.get(id)
  doc.querySelectorAll = () => [start, startVideo]
  const audio = Object.assign(new EventTarget(), {
    srcObject: null, play: async () => {plays++; return play?.()}, pause() {},
  })
  let attachedStream = null
  // Capture the tracks present at source selection. The observed Brave run
  // played audio but retained HAVE_NOTHING and a pending promise until rebind.
  Object.defineProperty(audio, "srcObject", {
    get: () => attachedStream,
    set(value) {attachedStream = value; audio.selectedTracks = [...(value?.tracks ?? [])]},
  })
  doc.createElement = () => audio
  function envelope(topic) {
    return {signaling_session_id: topic.startsWith("call:") ? "topic-session" : "inbox-session", call}
  }
  function reply(value) {
    return {receive(status, fn) {if (status === "ok") queueMicrotask(() => fn(value)); return this}}
  }
  class Socket {
    constructor() {sockets++; socketsCreated.push(this)}
    connect() {}
    disconnect() {}
    onClose(fn) {this.closed = fn}
    onError(fn) {this.failed = fn}
    channel(topic) {
      const handlers = new Map()
      const ch = {topic, on: (event, fn) => handlers.set(event, fn), join: () => reply(envelope(topic)), leave() {},
        onClose(fn) {this.closed = fn}, onError(fn) {this.failed = fn},
        emit: (event, payload) => handlers.get(event)?.(payload),
        push(event, payload) {
          commands.push({event, payload})
          if (event === "start_call") {
            if (startReply) return startReply(payload)
            starts++
            call = {call_id: starts === 1 ? "call" : `call-${starts}`, role, ownership: "self", state: "ringing", media_intent: payload.media_intent}
            return reply({...envelope(topic), started: true})
          }
          if (event === "accept_call") {
            if (acceptReply) return acceptReply(payload)
            call = {...call, state: "connecting", ownership: "self", answer_mode: payload.answer_mode}
            return reply(envelope(topic))
          }
          if (event === "decline_call" && declineReply) return declineReply(payload)
          if (event === "cancel_call" && cancelReply) return cancelReply(payload)
          if (event === "leave_call") {
            call = {...call, state: "terminal", terminal_outcome: "ended"}
            return reply(envelope(topic))
          }
          if (event === "media_credentials" && credentialsReply) return credentialsReply(payload)
          if (event === "media_credentials") return reply({call_id: call.call_id, call_session_id: "media-session",
            signaling_session_id: "topic-session", ice_config: {ice_mode: "disabled", ice_servers: [], ice_transport_policy: "all"}})
          if (event === "ice_candidate" && iceReply) return iceReply(payload)
          if (event === "local_media_state" && mediaReply) return mediaReply(payload)
          if (event === "offer" && offerReply) return offerReply(payload)
          if (event === "offer") return reply({...payload, description: {type: "answer", sdp: "answer"}})
          return reply(payload)
        }}
      channels.push(ch); return ch
    }
  }
  class Stream {
    constructor(tracks = []) {this.tracks = tracks}
    addTrack(t) {this.tracks.push(t)}
    removeTrack(t) {this.tracks = this.tracks.filter(x => x !== t)}
  }
  class Peer extends EventTarget {
    transceivers = []
    constructor() {super(); peers.push(this)}
    addTransceiver(source) {
      const remote = new EventTarget(); remote.kind = typeof source === "string" ? source : "audio"
      const t = {mid: null, currentDirection: null, sender: {track: typeof source === "string" ? null : source,
        parameters: {transactionId: "fresh", encodings: [{active: true}], codecs: [{mimeType: "video/VP8"}]},
        getParameters() {return cameraParameters ? cameraParameters(this) : structuredClone(this.parameters)},
        async setParameters(parameters) {await configureCamera?.(parameters, this); this.parameters = structuredClone(parameters)},
        async replaceTrack(track) {await replaceCamera?.(track); this.track = track}}, receiver: {track: remote}, setCodecPreferences() {}}
      this.transceivers.push(t); return t
    }
    async createOffer() {return {type: "offer", sdp: "offer"}}
    async setLocalDescription(d) {
      this.localDescription = d
      this.transceivers.forEach((t, i) => {t.mid = String(i)})
    }
    async setRemoteDescription() {
      this.transceivers[0].currentDirection = "sendrecv"
      this.transceivers[1].currentDirection = videoDirection
    }
    getTransceivers() {return [...this.transceivers]}
    close() {this.closed = true}
    emitCandidate(candidate) {
      const event = new Event("icecandidate"); event.candidate = candidate
      this.dispatchEvent(event)
    }
    ready() {
      this.connectionState = "connected"
      this.dispatchEvent(new Event("connectionstatechange"))
      const e = new Event("track"); e.transceiver = this.transceivers[0]; e.track = e.transceiver.receiver.track
      this.dispatchEvent(e)
    }
  }
  const mediaDevices = injectedMediaDevices === undefined ? {async getUserMedia(request) {
    acquisitions++
    requests.push(request)
    if (permission) return permission(request)
    const track = new EventTarget()
    Object.assign(track, {kind: request.audio ? "audio" : "video", readyState: "live", enabled: true, stops: 0,
      getSettings: () => ({width: 640, height: 360, frameRate: 15}),
      stop() {this.stops++; this.readyState = "ended"},
      end() {this.readyState = "ended"; this.dispatchEvent(new Event("ended"))}})
    tracks.push(track)
    return {getTracks: () => [track], getAudioTracks: () => request.audio ? [track] : [], getVideoTracks: () => request.audio ? [] : [track]}
  }} : injectedMediaDevices
  const installed = installCallSignaling({createController: options => createCallController({...options, diagnosticWrite}), document: doc, window: win, Socket, createCallSignaling,
    createDevices: () => devices ?? createRealCallDevices({mediaDevices, secureContext}),
    installPresenter: options => installCallPresenter({...options, MediaStream: Stream}),
    createCuePlayer: () => ({start() {}, stop() {}, dispose() {}}),
    createCueCoordinator: () => ({contend() {}, withdraw() {}, dispose() {}}),
    createPeerAttempt: options => createCallPeerAttempt({...options, PeerConnection: Peer, MediaStream: Stream,
      codecCapabilities: kind => ({codecs: [{mimeType: kind === "audio" ? "audio/opus" : "video/VP8"}]}),
      negotiationId: () => "negotiation", setTimeoutFn(fn) {const id = {}; timers.set(id, fn); return id},
      clearTimeoutFn(id) {timers.delete(id)}}),
  })
  return {installed, requests, preview, peers, tracks, commands, timers, audio, nodes, win,
    media(payload) {channels.findLast(ch => ch.topic === `call:${call.call_id}`).emit("video_presentation", payload)},
    replacePreview() {
      const replacement = node("direct-call-local-preview")
      Object.assign(replacement, {srcObject: null, play: async () => previewPlay?.(), pause() {}})
      return replacement
    },
    click(n) {const e = new Event("click"); Object.defineProperty(e, "target", {value: n}); doc.dispatchEvent(e)},
    keydown(key) {const e = new Event("keydown"); Object.defineProperty(e, "key", {value: key}); doc.dispatchEvent(e)},
    visibility(state) {doc.visibilityState = state; doc.hidden = state === "hidden"; doc.dispatchEvent(new Event("visibilitychange"))},
    focused: () => doc.activeElement,
    start, startVideo, acceptVideo, answer, leave, enable, mute, deafen, enableAudio, camera,
    project(patch) {
      call = {...call, ...patch}
      const topic = `call:${call.call_id}`
      const event = call.state === "terminal" ? "call_ended" : call.state === "active" ? "call_active" : "call_connecting"
      channels.findLast(ch => ch.topic === topic).emit(event, envelope(topic))
    },
    incoming(patch) {
      call = patch
      channels.findLast(ch => ch.topic === "call_inbox:current-user").emit("incoming_call", envelope("call_inbox:current-user"))
    },
    snapshot(patch) {call = patch},
    loseChannel() {channels.findLast(ch => ch.topic.startsWith("call:")).closed()},
    loseSocket() {socketsCreated.at(-1).closed()},
    count: () => ({sockets, acquisitions, plays}),
  }
}
async function flush() {for (let i = 0; i < 40; i++) await Promise.resolve()}

test("owner hides and shows Self-preview while the same camera keeps sending without signaling", async t => {
  const b = browser({videoAvailable: "true"})
  t.after(() => b.installed.dispose())
  await flush(); b.click(b.startVideo); await flush()
  b.project({state: "connecting"}); await flush()
  b.peers[0].ready(); b.project({state: "active"}); await flush()
  const toggle = b.nodes.get("direct-call-dock-preview"), region = b.nodes.get("direct-call-local-preview-region")
  const camera = b.peers[0].transceivers[1].sender.track, stream = b.preview.srcObject
  const audio = b.audio.srcObject, call = b.installed.controller.getState().call
  const commands = b.commands.length, requests = b.requests.length
  assert.equal(toggle.hidden, false)
  assert.equal(toggle.textContent, "Hide Self-preview")
  b.click(toggle); await flush()
  assert.equal(region.hidden, true)
  assert.equal(toggle.hidden, false)
  assert.equal(toggle.textContent, "Show Self-preview")
  assert.equal(toggle.getAttribute("aria-pressed"), undefined)
  assert.equal(b.nodes.get("direct-call-self-camera-status").textContent, "Your camera is on · Sending video")
  assert.equal(b.peers[0].transceivers[1].sender.track, camera)
  assert.equal(camera.readyState, "live")
  assert.equal(camera.stops, 0)
  assert.equal(b.preview.srcObject, stream)
  assert.equal(b.audio.srcObject, audio)
  assert.deepEqual(b.installed.controller.getState().call, call)
  assert.equal(b.commands.length, commands)
  assert.equal(b.requests.length, requests)
  b.click(toggle); await flush()
  assert.equal(region.hidden, false)
  assert.equal(toggle.textContent, "Hide Self-preview")
  assert.equal(b.preview.srcObject, stream)
})

for (const role of ["caller", "recipient"]) {
  test(`${role} defaults the next Call to visible Self-preview after deliberate audio fallback and fences owner loss`, async t => {
    let denied = false
    const b = browser({role, videoAvailable: "true", snapshot: role === "recipient" ? videoInvitation() : null,
      permission: request => {
        if (request.video && denied) throw {name: "NotAllowedError"}
        return trackStream(request.audio ? ownedAudioTrack() : videoTrack())
      }})
    t.after(() => b.installed.dispose())
    await flush(); b.click(role === "caller" ? b.startVideo : b.acceptVideo); await flush()
    if (role === "caller") {b.project({state: "connecting"}); await flush()}
    b.peers[0].ready(); b.project({state: "active"}); await flush()
    const toggle = b.nodes.get("direct-call-dock-preview"), region = b.nodes.get("direct-call-local-preview-region")
    region.contains = node => node === b.preview || node === b.nodes.get("direct-call-local-preview-retry")
    b.preview.focus(); b.click(toggle); await flush()
    assert.equal(b.focused(), toggle, "hiding a focused preview returns focus to its visible control")
    b.click(b.leave); await flush()
    denied = true
    if (role === "recipient") {
      b.snapshot({...videoInvitation(), call_id: "fresh"})
      b.installed.signaling.disconnect(); b.installed.signaling.connect(); await flush()
    }
    b.click(role === "caller" ? b.startVideo : b.acceptVideo); await flush()
    assert.match(b.nodes.get(role === "caller" ? "direct-call-dock-status" : "direct-call-incoming-status").textContent, /Camera access is blocked/)
    b.click(b.nodes.get(role === "caller" ? "direct-call-dock-start-voice-instead" : "direct-call-incoming-answer-without-video")); await flush()
    if (role === "caller") {b.project({state: "connecting"}); await flush()}
    b.peers[1].ready(); b.project({state: "active"}); await flush()
    assert.equal(toggle.textContent, "Hide Self-preview")
    assert.equal(region.hidden, false)
    assert.equal(b.preview.srcObject, null)
    denied = false; b.click(b.camera); await flush()
    assert.equal(region.hidden, false)
    assert.equal(b.preview.srcObject.tracks[0].readyState, "live")
    const call = b.installed.controller.getState().call
    assert.equal(call[role === "caller" ? "media_intent" : "answer_mode"], "audio")
    b.project({ownership: "elsewhere"}); await flush()
    assert.equal(toggle.hidden, true)
    const commands = b.commands.length
    b.click(toggle); await flush()
    assert.equal(region.hidden, true)
    assert.equal(toggle.textContent, "Hide Self-preview")
    assert.equal(b.preview.srcObject, null)
    assert.equal(b.commands.length, commands)
  })

  test(`${role} resets hidden Self-preview for a new Call and shows deliberate fresh preflight despite obsolete play`, async t => {
    let rejectOld, holdPreflight = false
    const b = browser({role, videoAvailable: "true", snapshot: role === "recipient" ? videoInvitation() : null,
      previewPlay: () => rejectOld ? undefined : new Promise((_resolve, reject) => {rejectOld = reject}),
      permission: request => trackStream(request.audio ? ownedAudioTrack() : videoTrack()),
      startReply: payload => {
        if (holdPreflight) return {receive() {return this}}
        return {receive(status, fn) {if (status === "ok") queueMicrotask(() => fn({started: true,
          signaling_session_id: "inbox-session", call: {call_id: "call", role, state: "ringing", ownership: "self", media_intent: payload.media_intent}})); return this}}
      },
      acceptReply: payload => {
        if (holdPreflight) return {receive() {return this}}
        return {receive(status, fn) {if (status === "ok") queueMicrotask(() => fn({signaling_session_id: "topic-session",
          call: {...videoInvitation(), state: "connecting", ownership: "self", answer_mode: payload.answer_mode}})); return this}}
      }})
    t.after(() => b.installed.dispose())
    await flush(); b.click(role === "caller" ? b.startVideo : b.acceptVideo); await flush()
    b.snapshot({...b.installed.controller.getState().call})
    b.project({state: "connecting"}); await flush()
    b.peers[0].ready(); b.project({state: "active"}); await flush()
    const toggle = b.nodes.get("direct-call-dock-preview")
    b.click(toggle); await flush()
    assert.equal(b.nodes.get("direct-call-local-preview-region").hidden, true)
    b.click(b.leave); await flush()
    holdPreflight = true
    if (role === "recipient") {
      b.snapshot({...videoInvitation(), call_id: "fresh"})
      b.installed.signaling.disconnect(); b.installed.signaling.connect(); await flush()
    }
    b.click(role === "caller" ? b.startVideo : b.acceptVideo); await flush()
    const prefix = role === "caller" ? "direct-call-local-preview" : "direct-call-incoming-preview"
    assert.equal(b.nodes.get(`${prefix}-region`).hidden, false)
    const stream = b.nodes.get(prefix).srcObject
    assert.equal(stream.tracks[0].readyState, "live")
    assert.equal(toggle.hidden, true)
    rejectOld(new Error("obsolete preview")); await flush()
    assert.equal(b.nodes.get(prefix).srcObject, stream)
    assert.equal(b.nodes.get(`${prefix}-retry`).hidden, true)
    // A late click during preflight cannot carry the old preference into the next Call.
    b.click(toggle); await flush()
    assert.equal(b.nodes.get(`${prefix}-region`).hidden, false)
  })

  test(`${role} retains hidden Self-preview through navigation and camera return, with truthful status`, async t => {
    const b = browser({role, videoAvailable: "true", snapshot: role === "recipient" ? videoInvitation() : null})
    t.after(() => b.installed.dispose())
    await flush(); b.click(role === "caller" ? b.startVideo : b.acceptVideo); await flush()
    if (role === "caller") {b.project({state: "connecting"}); await flush()}
    b.peers[0].ready(); b.project({state: "active"}); await flush()
    const toggle = b.nodes.get("direct-call-dock-preview"), region = b.nodes.get("direct-call-local-preview-region")
    const status = b.nodes.get("direct-call-self-camera-status")
    b.click(toggle); await flush()
    const camera = b.tracks[1]
    camera.muted = true; camera.dispatchEvent(new Event("mute")); await flush()
    assert.equal(status.textContent, "Your camera is interrupted")
    camera.muted = false; camera.dispatchEvent(new Event("unmute")); await flush()
    assert.equal(status.textContent, "Your camera is on · Sending video")
    b.win.dispatchEvent(new Event("phx:page-loading-start"))
    b.win.dispatchEvent(new Event("call:conversation-surface"))
    b.win.dispatchEvent(new Event("phx:page-loading-stop")); await flush()
    assert.equal(region.hidden, true)
    b.click(b.camera); await flush()
    assert.equal(status.textContent, "Your camera is off")
    assert.equal(region.hidden, true)
    b.click(b.camera); await flush()
    assert.equal(status.textContent, "Your camera is on · Sending video")
    assert.equal(region.hidden, true)
    assert.equal(toggle.textContent, "Show Self-preview")
    assert.equal(b.tracks[1].stops, 1)
    assert.equal(b.peers[0].transceivers[1].sender.track, b.tracks[2])
    b.click(toggle); await flush()
    assert.equal(region.hidden, false)
    assert.deepEqual(b.preview.srcObject.tracks, [b.tracks[2]])
    assert.equal(b.peers.length, 1)
    assert.equal(b.commands.filter(c => c.event === "offer").length, 1)
    assert.equal(b.tracks[0].stops, 0)
  })
}

for (const role of ["caller", "recipient"]) {
  test(`${role} recovers blocked video locally without changing retained audio, capture or accepted controls`, async t => {
    t.mock.timers.enable({apis: ["setTimeout"]})
    const b = browser({role, videoAvailable: "true", snapshot: role === "recipient" ? videoInvitation() : null})
    t.after(() => b.installed.dispose())
    let presented, videoPlays = 0, finish, blocked = true
    let decoded = {framesDecoded: 2, keyFramesDecoded: 1}
    const video = {srcObject: null, dataset: {}, style: {}, videoWidth: 960, videoHeight: 540,
      paused: false, pause() {},
      play() {
        videoPlays++
        if (blocked) return Promise.reject(new Error("autoplay blocked"))
        return new Promise(resolve => {finish = resolve})
      },
      requestVideoFrameCallback(fn) {presented = fn; return 1}, cancelVideoFrameCallback() {presented = null}}
    b.nodes.set("direct-call-remote-video", video)
    b.nodes.set("direct-call-remote-video-region", {hidden: true})
    await flush(); b.click(role === "caller" ? b.startVideo : b.acceptVideo); await flush()
    const opposite = role === "caller" ? "recipient" : "caller"
    b.project({state: "active", answer_mode: "video", media_state: {
      [opposite]: {media_state_version: 1, microphone_muted: false, camera_enabled: true},
    }})
    await flush()
    const pc = b.peers[0], transceiver = pc.transceivers[1]
    transceiver.receiver.track.id = "opposite-camera"
    transceiver.receiver.getStats = async () => new Map([["video", {type: "inbound-rtp", kind: "video",
      trackIdentifier: "opposite-camera", ...decoded}]])
    pc.ready()
    const event = new Event("track"); event.transceiver = transceiver; event.track = transceiver.receiver.track
    pc.dispatchEvent(event); await flush()
    const offer = b.commands.find(c => c.event === "offer").payload
    b.media({...offer, video_presentation: {epoch: 1, camera_version: 1, rtp_timestamp: 9000}})
    await flush()
    const dock = b.nodes.get("direct-call-dock")
    const home = {id: "direct-call-dock-home", appendChild(node) {node.parentElement = this}}
    const stage = {id: "direct-conversation-call-stage", isConnected: true,
      dataset: {directConversationId: "conversation"}, moveBefore(node) {node.parentElement = this}}
    b.nodes.set(home.id, home); b.nodes.set(stage.id, stage)
    b.project({direct_conversation_id: "conversation"}); await flush()
    assert.equal(dock.parentElement, stage)
    const retry = b.nodes.get("direct-call-remote-video-retry")
    assert.equal(b.installed.controller.getState().remoteVideoState, "blocked")
    assert.equal(retry.hidden, false)
    b.click(b.mute); b.click(b.deafen); await flush()
    const stream = video.srcObject, audio = b.audio.srcObject, camera = transceiver.sender.track
    const microphone = pc.transceivers[0].sender.track, requests = b.requests.length, audioPlays = b.count().plays
    const commands = b.commands.length, binding = b.installed.controller.getState().remoteVideoBinding
    const beforePlays = videoPlays
    blocked = false
    b.click(retry)
    assert.equal(videoPlays, beforePlays + 1)
    b.click(retry); b.win.dispatchEvent(new Event("phx:page-loading-stop"))
    b.win.dispatchEvent(new Event("phx:page-loading-start"))
    assert.equal(dock.parentElement, home)
    stage.isConnected = false
    b.win.dispatchEvent(new Event("phx:page-loading-stop"))
    assert.equal(dock.parentElement, home)
    finish(); await flush()
    assert.equal(b.installed.controller.getState().remoteVideoState, "loading")
    decoded = {framesDecoded: 3, keyFramesDecoded: 2}
    presented(10, {width: 960, height: 540, presentedFrames: 1, mediaTime: 0.1, rtpTimestamp: 9000})
    await flush()
    assert.equal(b.installed.controller.getState().remoteVideoState, "ready")
    stage.isConnected = true
    b.win.dispatchEvent(new Event("call:conversation-surface")); await flush()
    assert.equal(dock.parentElement, stage)
    b.click(retry); await flush()
    assert.equal(videoPlays, beforePlays + 1)
    assert.equal(video.srcObject, stream)
    assert.equal(b.audio.srcObject, audio)
    assert.equal(b.count().plays, audioPlays)
    assert.equal(b.audio.muted, true)
    assert.equal(microphone.enabled, false)
    assert.equal(transceiver.sender.track, camera)
    assert.equal(camera.stops, 0)
    assert.equal(b.requests.length, requests)
    assert.equal(b.commands.length, commands)
    assert.equal(b.peers.length, 1)
    assert.equal(pc.transceivers.length, 2)
    assert.equal(b.installed.controller.getState().remoteVideoBinding, binding)
    assert.equal(video.muted && video.playsInline, true)
    b.click(b.leave); await flush()
    assert.equal(video.srcObject, null)
    assert.equal(retry.hidden, true)
  })
}

for (const role of ["caller", "recipient"]) {
  test(`${role} camera-present disconnection retains its negotiation, preview and audio preferences through recovery`, async t => {
    const invitation = {call_id: "call", role, state: "ringing", ownership: "unclaimed", media_intent: "video"}
    const b = browser({role, videoAvailable: "true", snapshot: role === "recipient" ? invitation : null})
    t.after(() => b.installed.dispose())
    await flush(); b.click(role === "caller" ? b.startVideo : b.acceptVideo); await flush()
    if (role === "caller") b.project({state: "connecting", answer_mode: "video"})
    await flush(); b.peers[0].ready(); b.project({state: "active"}); await flush()
    const peer = b.peers[0], preview = b.preview.srcObject, audio = b.audio.srcObject
    const sender = peer.transceivers[1].sender
    b.click(b.mute); b.click(b.deafen); await flush()
    peer.connectionState = "disconnected"
    peer.dispatchEvent(new Event("connectionstatechange"))
    // Repeated disconnection must retain the same grace.
    const graceTimers = [...b.timers.keys()]
    peer.dispatchEvent(new Event("connectionstatechange"))
    assert.deepEqual([...b.timers.keys()], graceTimers)
    b.win.dispatchEvent(new Event("phx:page-loading-stop"))
    peer.ready(); await flush()
    assert.equal(b.preview.srcObject, preview)
    assert.equal(b.audio.srcObject, audio)
    assert.equal(sender.track, b.tracks[1])
    assert.deepEqual(b.tracks.map(track => track.stops), [0, 0])
    assert.equal(b.audio.muted, true)
    b.click(b.deafen); await flush()
    assert.equal(b.tracks[0].enabled, false)
    assert.equal(b.audio.muted, false)
    assert.equal(b.installed.controller.getState().cameraState, "enabled")
    assert.equal(b.commands.filter(command => command.event === "offer").length, 1)
    assert.equal(b.count().acquisitions, 2)
    assert.equal(b.peers.length, 1)
    assert.equal(b.commands.some(command => command.event === "leave_call"), false)
  })
}

for (const trigger of ["failed", "closed", "interrupted", "relationship_ended"]) {
  test(`camera-present ${trigger} releases accepted media and requires a deliberate fresh Call`, async t => {
    const b = browser({videoAvailable: "true"})
    t.after(() => b.installed.dispose())
    await flush(); b.click(b.startVideo); await flush()
    b.project({state: "connecting", answer_mode: "video"}); await flush()
    const oldPeer = b.peers[0], oldTracks = [...b.tracks]
    oldPeer.ready(); b.project({state: "active"}); await flush()
    const oldTimers = [...b.timers.values()]
    const observedAt = performance.now()
    if (["failed", "closed"].includes(trigger)) {
      oldPeer.connectionState = trigger
      oldPeer.dispatchEvent(new Event("connectionstatechange"))
    } else b.project({state: "terminal", terminal_outcome: trigger})
    assert.deepEqual(oldTracks.map(track => track.stops), [1, 1])
    assert.equal(oldPeer.closed, true)
    assert.equal(b.preview.srcObject, null)
    assert.equal(b.audio.srcObject, null)
    assert.equal(b.timers.size, 0)
    assert.ok(performance.now() - observedAt < 5000)
    await flush()
    if (trigger === "interrupted") assert.match(b.nodes.get("direct-call-dock-status").textContent, /interrupted/i)
    b.installed.signaling.disconnect(); b.installed.signaling.connect(); await flush()
    for (const callback of oldTimers) callback()
    oldPeer.ready(); oldTracks.forEach(track => track.end()); await flush()
    assert.equal(b.count().acquisitions, 2)
    assert.equal(b.peers.length, 1)
    assert.equal(b.commands.filter(command => command.event === "start_call").length, 1)
    // A fresh gesture repeats preparation and starts a different Call ID.
    b.click(b.startVideo); await flush()
    assert.equal(b.installed.controller.getState().call.call_id, "call-2")
    b.project({state: "connecting", answer_mode: "video"}); await flush()
    b.peers[1].ready(); b.project({state: "active"}); await flush()
    oldPeer.ready(); oldTracks.forEach(track => track.end()); await flush()
    assert.deepEqual(b.tracks.map(track => track.stops), [1, 1, 0, 0])
    assert.equal(b.peers[1].closed, undefined)
    assert.equal(b.commands.filter(command => command.event === "offer").length, 2)
    assert.equal(b.commands.filter(command => command.event === "start_call").length, 2)
  })
}

test("video ringing rediscovery preserves the original invitation without recapture or command replay", async t => {
  const b = browser({videoAvailable: "true"})
  t.after(() => b.installed.dispose())
  await flush(); b.click(b.startVideo); await flush()
  const deadline = new Date(Date.now() + 20_000).toISOString()
  b.project({state: "ringing", ringing_deadline_at: deadline}); await flush()
  b.loseSocket()
  assert.deepEqual(b.tracks.map(track => track.stops), [1, 1])
  assert.equal(b.preview.srcObject, null)
  b.installed.signaling.disconnect(); b.installed.signaling.connect(); await flush()
  const state = b.installed.controller.getState()
  assert.equal(state.call.call_id, "call")
  assert.equal(state.call.ringing_deadline_at, deadline)
  assert.equal(state.presentation, "outgoing_ringing")
  assert.equal(state.cameraPreviewTrack, null)
  assert.equal(b.count().acquisitions, 2)
  assert.equal(b.peers.length, 0)
  assert.deepEqual(b.commands.map(command => command.event), ["start_call"])
})

test("persisted restoration releases stale camera and audio before discovery even without a delivered pagehide", async () => {
  const b = browser({videoAvailable: "true"})
  await flush(); b.click(b.startVideo); await flush()
  b.project({state: "connecting"}); await flush()
  b.peers[0].ready(); b.project({state: "active"}); await flush()
  const oldTimers = [...b.timers.values()]
  const mutations = b.commands.length
  // The document executes no callbacks while frozen. Restoration itself must
  // release retained local resources, independently of server discovery.
  const observedAt = performance.now()
  const event = new Event("pageshow"); event.persisted = true
  b.win.dispatchEvent(event)
  assert.deepEqual(b.tracks.map(track => track.stops), [1, 1])
  assert.equal(b.preview.srcObject, null)
  assert.equal(b.audio.srcObject, null)
  assert.equal(b.peers[0].closed, true)
  assert.equal(b.timers.size, 0)
  assert.ok(performance.now() - observedAt < 5000)
  await flush()
  for (const callback of oldTimers) callback()
  b.peers[0].ready(); b.tracks.forEach(track => track.end())
  await flush()
  assert.equal(b.commands.length, mutations)
  assert.equal(b.count().acquisitions, 2)
  assert.equal(b.peers.length, 1)
  assert.equal(b.installed.controller.getState().canEnableMicrophone, false)
  assert.equal(b.installed.controller.getState().canControlCamera, false)
  b.installed.dispose()
})

function exitBrowser(b, exit) {
  if (exit === "leave") b.click(b.leave)
  if (exit === "channel") b.loseChannel()
  if (exit === "authentication-disconnect") b.loseSocket()
  if (exit === "pagehide") b.win.dispatchEvent(new Event("pagehide"))
  if (exit === "dispose") b.installed.dispose()
  if (exit === "resume") {
    const event = new Event("pageshow"); event.persisted = true
    b.win.dispatchEvent(event)
  }
}

for (const exit of ["leave", "channel", "authentication-disconnect", "pagehide", "resume", "dispose"]) {
  for (const outcome of ["resolve", "reject"]) {
    for (const work of ["replacement", "configuration"]) {
      test(`${exit} releases camera/audio with ${work} and preview play held; late ${outcome} cannot affect a fresh Call`, async () => {
        let settleReplacement, settlePreview, held = true, firstPreview = true
        const hold = () => {
          if (held) {
            held = false
            return new Promise((resolve, reject) => {settleReplacement = outcome === "resolve" ? resolve : reject})
          }
        }
        const b = browser({videoAvailable: "true",
          configureCamera: work === "configuration" ? hold : undefined,
          replaceCamera: track => track && work === "replacement" ? hold() : undefined,
          previewPlay: () => {
          if (firstPreview) {
            firstPreview = false
            return new Promise((resolve, reject) => {settlePreview = outcome === "resolve" ? resolve : reject})
          }
        }})
        await flush(); b.click(b.startVideo); await flush()
        b.project({state: "connecting"}); await flush()
        const oldPeer = b.peers[0], oldTracks = [...b.tracks], oldTimers = [...b.timers.values()]
        oldPeer.ready(); b.project({state: "active"}); await flush()
        assert.notEqual(b.preview.srcObject, null)
        assert.notEqual(b.audio.srcObject, null)
        const observedAt = performance.now()
        exitBrowser(b, exit)
        assert.deepEqual(oldTracks.map(t => t.stops), [1, 1])
        assert.equal(b.preview.srcObject, null)
        assert.equal(b.audio.srcObject, null)
        assert.equal(oldPeer.closed, true)
        assert.equal(b.timers.size, 0)
        for (const track of oldTracks) {
          for (const event of ["ended", "mute", "unmute"]) assert.equal(getEventListeners(track, event).length, 0)
        }
        for (const event of ["track", "connectionstatechange", "icecandidate"]) {
          assert.equal(getEventListeners(oldPeer, event).length, 0)
        }
        assert.equal(getEventListeners(b.audio, "playing").length, 0)
        assert.equal(getEventListeners(oldPeer.transceivers[0].receiver.track, "ended").length, 0)
        assert.ok(performance.now() - observedAt < 5000)
        await flush()
        const oldPublications = b.commands.filter(c => c.event === "local_media_state").length
        if (exit !== "dispose") {
          b.snapshot({call_id: "call", role: "caller", state: "terminal", terminal_outcome: "interrupted"})
          b.installed.signaling.disconnect(); b.installed.signaling.connect(); await flush()
          assert.equal(b.count().acquisitions, 2)
          b.click(b.startVideo); await flush(); b.project({state: "connecting"}); await flush()
          b.peers[1].ready(); b.project({state: "active"}); await flush()
        }
        const preview = b.preview.srcObject, playback = b.audio.srcObject, mutations = b.commands.length
        settleReplacement(new Error("obsolete sender")); settlePreview(new Error("obsolete preview"))
        for (const callback of oldTimers) callback()
        oldPeer.ready(); oldTracks.forEach(t => t.end())
        await flush()
        assert.equal(b.commands.length, mutations)
        assert.equal(b.preview.srcObject, preview)
        assert.equal(b.audio.srcObject, playback)
        assert.equal(b.nodes.get("direct-call-local-preview-retry").hidden, true)
        if (exit !== "dispose") {
          assert.deepEqual(b.tracks.slice(2).map(t => t.stops), [0, 0])
          assert.equal(b.peers[1].transceivers[1].sender.track, b.tracks[3])
          assert.equal(b.commands.filter(c => c.event === "local_media_state" && c.payload.call_id === "call").length, oldPublications)
        }
        b.installed.dispose()
        assert.ok(b.tracks.every(t => t.stops === 1))
      })
    }

    test(`${exit} invalidates an active camera permission; late ${outcome} releases every returned track`, async () => {
      let settle
      const microphone = ownedAudioTrack(), late = videoTrack(), extra = videoTrack()
      const {track: voice, controller: voiceController} = await capturedVoice()
      const b = browser({videoAvailable: "true", permission: request => request.audio ? trackStream(microphone) :
        new Promise((resolve, reject) => {settle = () => outcome === "resolve" ? resolve(trackStream(late, extra)) : reject({name: "NotAllowedError"})})})
      await flush(); b.click(b.start); await flush(); b.project({state: "connecting"}); await flush()
      b.peers[0].ready(); b.project({state: "active"}); await flush()
      b.click(b.camera); await flush()
      const observedAt = performance.now()
      exitBrowser(b, exit)
      assert.equal(microphone.stops, 1)
      assert.equal(b.peers[0].closed, true)
      assert.equal(b.audio.srcObject, null)
      assert.equal(b.preview.srcObject, null)
      assert.equal(b.timers.size, 0)
      assert.ok(performance.now() - observedAt < 5000)
      await flush()
      const mutations = b.commands.length
      settle(); await flush()
      assert.deepEqual([late.stops, extra.stops], outcome === "resolve" ? [1, 1] : [0, 0])
      assert.equal(b.commands.length, mutations)
      assert.equal(b.peers[0].transceivers[1].sender.track, null)
      assert.equal(b.count().acquisitions, 2)
      assert.equal(voice.stops, 0)
      assert.equal(voiceController.state().status, "capturing")
      b.installed.dispose(); voiceController.teardown()
    })
  }
}

for (const exit of ["authentication-disconnect", "pagehide", "resume", "dispose"]) {
  for (const role of ["caller", "recipient"]) {
    for (const kind of ["microphone", "camera"]) {
      test(`${exit} cancels ${role} pending ${kind} permission without dispatch or preview revival`, async () => {
        let grant
        const microphone = ownedAudioTrack(), late = kind === "microphone" ? ownedAudioTrack() : videoTrack(), extra = videoTrack()
        const b = browser({role, snapshot: role === "recipient" ? videoInvitation() : null, videoAvailable: "true",
          permission: request => kind === "camera" && request.audio ? trackStream(microphone) : new Promise(resolve => {grant = resolve})})
        await flush(); b.click(role === "caller" ? b.startVideo : b.acceptVideo); await flush()
        exitBrowser(b, exit)
        assert.equal(microphone.stops, kind === "camera" ? 1 : 0)
        assert.equal(b.preview.srcObject, null)
        assert.equal(b.nodes.get("direct-call-incoming-preview").srcObject, null)
        await flush()
        grant(trackStream(late, extra)); await flush()
        assert.deepEqual([late.stops, extra.stops], [1, 1])
        assert.equal(b.commands.length, 0)
        assert.equal(b.peers.length, 0)
        assert.equal(b.count().acquisitions, kind === "camera" ? 2 : 1)
        b.installed.dispose()
      })
    }
  }
}

test("ordinary visibility and observer departure leave the active owned camera/audio intact", async () => {
  const b = browser({videoAvailable: "true"})
  await flush(); b.click(b.startVideo); await flush(); b.project({state: "connecting"}); await flush()
  b.peers[0].ready(); b.project({state: "active"}); await flush()
  const observer = browser({videoAvailable: "true", snapshot: {...b.installed.controller.getState().call, ownership: "elsewhere"}})
  await flush()
  const preview = b.preview.srcObject, playback = b.audio.srcObject, mutations = b.commands.length
  b.visibility("hidden"); b.visibility("visible")
  const ordinaryShow = new Event("pageshow"); ordinaryShow.persisted = false
  b.win.dispatchEvent(ordinaryShow)
  observer.win.dispatchEvent(new Event("pagehide")); observer.installed.dispose()
  await flush()
  assert.deepEqual(b.tracks.map(t => t.stops), [0, 0])
  assert.equal(b.preview.srcObject, preview)
  assert.equal(b.audio.srcObject, playback)
  assert.equal(b.peers[0].closed, undefined)
  assert.equal(b.commands.length, mutations)
  assert.equal(observer.count().acquisitions, 0)
  assert.equal(observer.commands.length, 0)
  b.installed.dispose()
})

test("temporary camera interruption preserves attached capture and audio until the source resumes", async () => {
  const b = browser({role: "recipient", snapshot: videoInvitation(), videoAvailable: "true"})
  await flush(); b.click(b.acceptVideo); await flush()
  b.project({state: "active"}); b.peers[0].ready(); await flush()
  b.click(b.mute); b.click(b.deafen); await flush()
  const camera = b.tracks[1], stream = b.preview.srcObject
  const snapshots = b.commands.filter(c => c.event === "local_media_state").length
  camera.muted = true; camera.dispatchEvent(new Event("mute"))
  assert.equal(b.installed.controller.getState().cameraState, "interrupted")
  assert.match(b.nodes.get("direct-call-local-preview-status").textContent, /Camera interrupted/)
  assert.match(b.nodes.get("direct-call-dock-status").textContent, /Camera interrupted/)
  assert.equal(b.camera.getAttribute("aria-pressed"), undefined)
  assert.equal(b.camera.getAttribute("data-active"), "true")
  assert.equal(b.camera.getAttribute("aria-label"), "Turn camera off")
  assert.equal(b.preview.srcObject, stream)
  assert.equal(b.peers[0].transceivers[1].sender.track, camera)
  assert.equal(camera.stops, 0)
  assert.equal(b.tracks[0].stops, 0)
  assert.equal(b.audio.muted, true)
  camera.muted = false; camera.dispatchEvent(new Event("unmute"))
  assert.equal(b.installed.controller.getState().cameraState, "enabled")
  assert.equal(b.installed.controller.getState().localMuted, true)
  assert.equal(b.installed.controller.getState().localDeafened, true)
  assert.equal(b.commands.filter(c => c.event === "local_media_state").length, snapshots)
  assert.equal(b.requests.length, 2)
  assert.equal(b.commands.some(c => c.event === "leave_call"), false)
  b.installed.dispose()
})

test("caller final video preflight releases an ended camera even before its source event is delivered", async () => {
  const b = browser({videoAvailable: "true"})
  let stream = null
  Object.defineProperty(b.preview, "srcObject", {get: () => stream, set(value) {
    stream = value
    if (value) b.tracks[1].readyState = "ended"
  }})
  await flush(); b.click(b.startVideo); await flush()
  assert.equal(b.commands.some(c => c.event === "start_call"), false)
  assert.equal(b.installed.controller.getState().canFallbackToAudio, true)
  assert.equal(b.installed.controller.getState().canRetry, true)
  assert.equal(b.preview.srcObject, null)
  assert.equal(b.tracks[1].stops, 1)
  assert.equal(b.tracks[0].stops, 0)
  assert.equal(b.requests.length, 2)
  b.installed.dispose()
})

test("ringing interruption and permanent camera end preserve the committed invitation and its deadline", async () => {
  const deadline = new Date(Date.now() + 30_000).toISOString()
  const b = browser({videoAvailable: "true", startReply: () => ({receive(status, fn) {
    if (status === "ok") queueMicrotask(() => fn({signaling_session_id: "inbox-session", call: {
      call_id: "call", role: "caller", ownership: "self", state: "ringing", media_intent: "video",
      ringing_deadline_at: deadline,
    }}))
    return this
  }})})
  await flush(); b.click(b.startVideo); await flush()
  const camera = b.tracks[1], stream = b.preview.srcObject
  camera.muted = true; camera.dispatchEvent(new Event("mute"))
  assert.equal(b.installed.controller.getState().cameraState, "interrupted")
  assert.equal(b.preview.srcObject, stream)
  assert.match(b.nodes.get("direct-call-dock-status").textContent, /Camera interrupted/)
  camera.muted = false; camera.dispatchEvent(new Event("unmute"))
  assert.equal(b.installed.controller.getState().cameraState, "preview_ready")
  camera.end()
  const state = b.installed.controller.getState()
  assert.equal(state.presentation, "outgoing_ringing")
  assert.equal(state.call.call_id, "call")
  assert.equal(state.call.ringing_deadline_at, deadline)
  assert.equal(state.mediaIntent, "video")
  assert.equal(state.cameraState, "off")
  assert.equal(state.microphoneReady, true)
  assert.equal(b.preview.srcObject, null)
  assert.equal(camera.stops, 1)
  assert.equal(b.tracks[0].stops, 0)
  assert.equal(b.requests.length, 2)
  assert.equal(b.commands.some(c => ["cancel_call", "leave_call", "local_media_state"].includes(c.event)), false)
  b.installed.dispose()
})

for (const role of ["caller", "recipient"]) {
  test(`${role} source interruption during final video preflight remains live without reacquisition`, async () => {
    const b = browser({role, snapshot: role === "recipient" ? videoInvitation() : null, videoAvailable: "true"})
    const preview = role === "recipient" ? b.nodes.get("direct-call-incoming-preview") : b.preview
    let stream
    Object.defineProperty(preview, "srcObject", {get: () => stream, set(value) {
      stream = value
      if (value) {
        b.tracks[1].muted = true
        b.tracks[1].dispatchEvent(new Event("mute"))
      }
    }})
    await flush(); b.click(role === "caller" ? b.startVideo : b.acceptVideo); await flush()
    assert.equal(b.installed.controller.getState().cameraState, "interrupted")
    assert.equal(b.commands.filter(c => c.event === (role === "caller" ? "start_call" : "accept_call")).length, 1)
    assert.equal(b.tracks[1].stops, 0)
    assert.equal(b.requests.length, 2)
    b.tracks[1].muted = false; b.tracks[1].dispatchEvent(new Event("unmute"))
    assert.equal(b.installed.controller.getState().cameraState, role === "caller" ? "preview_ready" : "enabled")
    b.installed.dispose()
  })
}

test("camera interruption during sender attachment resumes the pending operation on the same track", async () => {
  let attach
  const b = browser({role: "recipient", snapshot: videoInvitation(), videoAvailable: "true",
    replaceCamera: track => track && new Promise(resolve => {attach = resolve})})
  await flush(); b.click(b.acceptVideo); await flush()
  const camera = b.tracks[1]
  camera.muted = true; camera.dispatchEvent(new Event("mute"))
  assert.equal(b.installed.controller.getState().cameraState, "interrupted")
  assert.equal(b.installed.controller.getState().cameraAttached, false)
  camera.muted = false; camera.dispatchEvent(new Event("unmute"))
  assert.equal(b.installed.controller.getState().cameraState, "attaching")
  attach(); await flush()
  assert.equal(b.installed.controller.getState().cameraState, "enabled")
  assert.equal(b.peers[0].transceivers[1].sender.track, camera)
  assert.equal(b.requests.length, 2)
  assert.equal(b.commands.filter(c => c.event === "offer").length, 1)
  b.installed.dispose()
})

for (const role of ["caller", "recipient"]) {
  test(`${role} audio choice keeps receiving opposite video through local camera denial, enable and off`, async t => {
    t.mock.timers.enable({apis: ["setTimeout"]})
    const microphone = ownedAudioTrack(), camera = videoTrack()
    const records = []
    let deny = true
    const b = browser({diagnosticWrite: record => records.push(record), role, videoAvailable: "true",
      snapshot: role === "recipient" ? videoInvitation() : null,
      permission: request => {
        if (request.audio) return trackStream(microphone)
        if (deny) {deny = false; throw {name: "NotAllowedError"}}
        return trackStream(camera)
      }})
    let presented
    const region = {hidden: true}, video = {srcObject: null, dataset: {}, videoWidth: 960, videoHeight: 540,
      paused: false, play: async () => {}, pause() {},
      requestVideoFrameCallback(fn) {presented = fn; return 1}, cancelVideoFrameCallback() {presented = null}}
    b.nodes.set("direct-call-remote-video-region", region)
    b.nodes.set("direct-call-remote-video", video)
    await flush()
    b.click(role === "caller" ? b.start : b.nodes.get("direct-call-incoming-answer-without-video"))
    await flush()
    const opposite = role === "caller" ? "recipient" : "caller"
    b.project({state: "active", answer_mode: "audio", media_state: {
      [opposite]: {media_state_version: 1, microphone_muted: false, camera_enabled: true},
    }})
    await flush()
    const pc = b.peers[0], receiver = pc.transceivers[1]
    receiver.receiver.track.id = "opposite-camera"
    let decoded = {framesDecoded: 2, keyFramesDecoded: 1}
    receiver.receiver.getStats = async () => new Map([["video", {type: "inbound-rtp", kind: "video",
      trackIdentifier: "opposite-camera", ...decoded}]])
    pc.ready()
    const event = new Event("track")
    event.transceiver = receiver; event.track = receiver.receiver.track
    pc.dispatchEvent(event); await flush()
    const offer = b.commands.find(c => c.event === "offer").payload
    b.media({...offer,
      video_presentation: {epoch: 1, camera_version: 1, rtp_timestamp: 9000}})
    await flush()
    assert.equal(b.installed.controller.getState().remoteVideoState, "loading")
    assert.equal(b.installed.controller.getState().remoteCameraEnabled, true)
    presented(10, {width: 960, height: 540, presentedFrames: 1, mediaTime: 0.1, rtpTimestamp: 9000})
    await flush()
    assert.equal(b.installed.controller.getState().remoteVideoState, "ready")
    const retained = video.srcObject
    t.mock.timers.tick(5000); await flush()
    assert.equal(b.installed.controller.getState().remoteVideoState, "interrupted")
    assert.equal(b.installed.controller.getState().remoteCameraEnabled, true)
    presented(11, {width: 960, height: 540, presentedFrames: 2, mediaTime: 0.2, rtpTimestamp: 12000})
    await flush()
    assert.equal(b.installed.controller.getState().remoteVideoState, "ready")
    assert.equal(video.srcObject, retained)
    b.project({media_state: {[opposite]: {media_state_version: 2, microphone_muted: false, camera_enabled: false}}})
    await flush()
    assert.equal(video.srcObject, null)
    assert.equal(b.installed.controller.getState().remoteVideoState, "off")
    b.project({media_state: {[opposite]: {media_state_version: 3, microphone_muted: false, camera_enabled: true}}})
    await flush()
    assert.equal(b.installed.controller.getState().remoteVideoState, "loading")
    b.media({...offer, video_presentation: {epoch: 3, camera_version: 3, rtp_timestamp: 15000}})
    await flush()
    decoded = {framesDecoded: 3, keyFramesDecoded: 2}
    presented(20, {width: 960, height: 540, presentedFrames: 2, mediaTime: 0.2, rtpTimestamp: 15000})
    await flush()
    assert.equal(b.installed.controller.getState().remoteVideoState, "ready")
    const remote = video.srcObject
    assert.ok(remote)
    assert.equal(region.hidden, false)
    assert.deepEqual(b.requests.map(r => Boolean(r.video)), [false])
    b.click(b.camera); await flush()
    assert.equal(b.installed.controller.getState().cameraError, "permission-denied")
    assert.equal(b.nodes.get("direct-call-local-preview-status").textContent, "Camera unavailable")
    assert.equal(video.srcObject, remote)
    b.click(b.camera); await flush()
    assert.equal(pc.transceivers[1].sender.track, camera)
    b.click(b.mute); b.click(b.deafen); b.click(b.camera); await flush()
    assert.equal(video.srcObject, remote)
    assert.equal(region.hidden, false)
    assert.deepEqual(remote.tracks, [receiver.receiver.track])
    assert.equal(pc.transceivers[1].sender.track, null)
    assert.equal(microphone.stops, 0)
    assert.equal(microphone.enabled, false)
    assert.equal(b.audio.muted, true)
    assert.equal(b.installed.controller.getState().call.answer_mode, "audio")
    assert.equal(b.installed.controller.getState().call.media_intent, role === "caller" ? "audio" : "video")
    assert.equal(b.commands.filter(c => c.event === "offer").length, 1)
    assert.equal(b.peers.length, 1)
    assert.equal(pc.transceivers.length, 2)
    assert.ok(records.some(r => r.operation === "camera" && r.outcome === "error" && r.error_code === "permission-denied"))
    assert.ok(records.some(r => r.operation === "presentation" && r.outcome === "interrupted"))
    assert.ok(records.some(r => r.operation === "presentation" && r.outcome === "off"))
    assert.ok(records.some(r => r.operation === "camera" && r.outcome === "enabled"))
    assert.doesNotMatch(JSON.stringify(records), /opposite-camera|topic-session|negotiation|credential|network/)
    b.installed.dispose()
    assert.equal(video.srcObject, null)
  })
}

for (const stage of ["connecting", "active"]) {
  for (const preparation of ["video answer", "audio answer then camera on"]) {
    test(`${preparation} camera end during ${stage} detaches only camera and preserves audio controls`, async () => {
      const b = browser({role: "recipient", snapshot: videoInvitation(), videoAvailable: "true"})
      await flush()
      b.click(preparation === "video answer" ? b.acceptVideo : b.nodes.get("direct-call-incoming-answer-without-video"))
      await flush()
      if (preparation !== "video answer") {b.click(b.camera); await flush()}
      if (stage === "active") {b.project({state: "active"}); b.peers[0].ready(); await flush()}
      b.click(b.mute); b.click(b.deafen); await flush()
      const peer = b.peers[0], sender = peer.transceivers[1].sender, camera = b.tracks[1]
      camera.end()
      assert.equal(b.preview.srcObject, null)
      assert.equal(camera.stops, 1)
      assert.equal(b.tracks[0].stops, 0)
      await flush()
      const state = b.installed.controller.getState()
      assert.equal(state.presentation, stage)
      assert.equal(state.cameraState, "off")
      assert.equal(state.mediaIntent, "video")
      assert.equal(state.call.answer_mode, preparation === "video answer" ? "video" : "audio")
      assert.equal(state.localMuted, true)
      assert.equal(state.localDeafened, true)
      assert.equal(state.canControlCamera, true)
      assert.equal(sender.track, null)
      assert.equal(peer.closed, undefined)
      const update = b.commands.filter(c => c.event === "local_media_state").at(-1).payload
      assert.equal(update.camera_enabled, false)
      assert.equal(update.microphone_muted, true)
      assert.equal(b.commands.some(c => c.event === "leave_call"), false)
      assert.equal(b.requests.length, 2)
      b.click(b.camera); await flush()
      assert.equal(b.tracks.length, 3)
      assert.equal(b.requests[2].audio, false)
      assert.equal(sender.track, b.tracks[2])
      assert.equal(b.peers.length, 1)
      assert.equal(peer.transceivers.length, 2)
      assert.equal(b.commands.filter(c => c.event === "offer").length, 1)
      assert.equal(b.audio.muted, true)
      // Camera loss/retry must preserve the original microphone's terminal callback.
      b.tracks[0].end(); await flush()
      assert.equal(b.commands.filter(c => c.event === "leave_call").length, 1)
      assert.equal(b.tracks[2].stops, 1)
      b.installed.dispose()
    })
  }
}

for (const release of ["application off", "permanent end"]) {
  test(`${release} invalidates queued source callbacks before fresh camera acquisition`, async () => {
    const b = browser({role: "recipient", snapshot: videoInvitation(), videoAvailable: "true"})
    await flush(); b.click(b.acceptVideo); await flush()
    const old = b.tracks[1]
    const queued = ["ended", "mute", "unmute"].flatMap(event => getEventListeners(old, event))
    old.muted = true; old.dispatchEvent(new Event("mute"))
    if (release === "application off") b.click(b.camera)
    else old.end()
    assert.equal(old.stops, 1)
    for (const event of ["ended", "mute", "unmute"]) assert.equal(getEventListeners(old, event).length, 0)
    await flush(); b.click(b.camera); await flush()
    const fresh = b.tracks[2], stream = b.preview.srcObject
    for (const callback of queued) callback()
    old.dispatchEvent(new Event("unmute")); old.dispatchEvent(new Event("ended"))
    await flush()
    assert.equal(b.installed.controller.getState().cameraState, "enabled")
    assert.equal(b.preview.srcObject, stream)
    assert.equal(b.peers[0].transceivers[1].sender.track, fresh)
    assert.equal(fresh.stops, 0)
    assert.equal(old.stops, 1)
    assert.equal(b.tracks[0].stops, 0)
    assert.equal(b.requests.length, 3)
    assert.equal(b.commands.some(c => c.event === "leave_call"), false)
    b.installed.dispose()
    for (const event of ["ended", "mute", "unmute"]) assert.equal(getEventListeners(fresh, event).length, 0)
  })
}

test("temporary microphone source mute leaves independent camera live but microphone end remains terminal", async () => {
  const b = browser({role: "recipient", snapshot: videoInvitation(), videoAvailable: "true"})
  await flush(); b.click(b.acceptVideo); await flush()
  const microphone = b.tracks[0], camera = b.tracks[1]
  microphone.muted = true; microphone.dispatchEvent(new Event("mute"))
  assert.equal(b.installed.controller.getState().cameraState, "enabled")
  assert.equal(b.installed.controller.getState().microphoneReady, true)
  assert.equal(b.installed.controller.getState().localMuted, false)
  microphone.muted = false; microphone.dispatchEvent(new Event("unmute"))
  camera.muted = true; camera.dispatchEvent(new Event("mute"))
  microphone.end(); await flush()
  assert.equal(b.commands.filter(c => c.event === "leave_call").length, 1)
  assert.equal(camera.stops, 1)
  assert.equal(b.preview.srcObject, null)
  assert.equal(b.requests.length, 2)
  b.installed.dispose()
})

for (const role of ["caller", "recipient"]) {
  test(`${role} camera end before command dispatch offers a deliberate camera-only retry`, async () => {
    const b = browser({role, snapshot: role === "recipient" ? videoInvitation() : null, videoAvailable: "true"})
    const preview = role === "recipient" ? b.nodes.get("direct-call-incoming-preview") : b.preview
    let stream, endOnce = true
    Object.defineProperty(preview, "srcObject", {get: () => stream, set(value) {
      stream = value
      if (value && endOnce) {endOnce = false; b.tracks[1].end()}
    }})
    await flush(); b.click(role === "caller" ? b.startVideo : b.acceptVideo); await flush()
    const command = role === "caller" ? "start_call" : "accept_call"
    assert.equal(b.commands.some(c => c.event === command), false)
    assert.equal(b.installed.controller.getState().presentation, role === "caller" ? "result" : "incoming_ringing")
    assert.equal(b.installed.controller.getState().microphoneReady, true)
    assert.equal(b.tracks[0].stops, 0)
    assert.equal(b.tracks[1].stops, 1)
    assert.equal(b.requests.length, 2)
    assert.equal(preview.srcObject, null)
    if (role === "caller") {
      assert.equal(b.installed.controller.getState().canFallbackToAudio, true)
      b.click(b.nodes.get("direct-call-dock-retry"))
    } else {
      assert.equal(b.installed.controller.getState().canAnswerWithoutVideo, true)
      b.click(b.acceptVideo)
    }
    await flush()
    assert.equal(b.requests.length, 3)
    assert.equal(b.requests[2].audio, false)
    assert.equal(b.tracks[0].stops, 0)
    assert.equal(b.commands.filter(c => c.event === command).length, 1)
    assert.equal(b.commands.find(c => c.event === command).payload[role === "caller" ? "media_intent" : "answer_mode"], "video")
    b.installed.dispose()
  })
}

test("camera end as connecting becomes eligible clears state before peer startup runs", async () => {
  const b = browser({videoAvailable: "true"})
  await flush(); b.click(b.startVideo); await flush()
  let ended = false
  const unsubscribe = b.installed.controller.subscribe(state => {
    if (state.presentation === "connecting" && !ended) {ended = true; b.tracks[1].end()}
  })
  b.project({state: "connecting"})
  assert.equal(b.installed.controller.getState().cameraState, "off")
  assert.equal(b.preview.srcObject, null)
  assert.equal(b.tracks[1].stops, 1)
  assert.equal(b.tracks[0].stops, 0)
  await flush()
  assert.equal(b.installed.controller.getState().cameraState, "off")
  assert.equal(b.peers[0].transceivers[1].sender.track, null)
  assert.equal(b.commands.some(c => c.event === "local_media_state" && c.payload.camera_enabled), false)
  assert.equal(b.commands.some(c => c.event === "leave_call"), false)
  unsubscribe(); b.installed.dispose()
})

test("recipient Cancel abandons permission work without declining and blocks overlapping retry", async () => {
  let grant
  const late = ownedAudioTrack(), extra = ownedAudioTrack()
  let pending = true
  const b = browser({role: "recipient", snapshot: videoInvitation(), videoAvailable: "true",
    permission: request => pending ? new Promise(resolve => {grant = resolve}) :
      {getTracks: () => [late], getAudioTracks: () => request.audio ? [late] : []}})
  await flush(); b.click(b.acceptVideo); b.click(b.acceptVideo); await flush()
  const cancel = b.nodes.get("direct-call-incoming-cancel-preparation")
  assert.equal(cancel.hidden, false)
  assert.equal(cancel.getAttribute("aria-label"), "Cancel device preparation")
  assert.match(b.nodes.get("direct-call-incoming-status").textContent, /browser prompt may still need dismissal/)
  b.click(cancel)
  assert.equal(b.installed.controller.getState().presentation, "incoming_ringing")
  assert.equal(cancel.hidden, true)
  b.click(b.acceptVideo); await flush()
  assert.equal(b.count().acquisitions, 1)
  assert.match(b.nodes.get("direct-call-incoming-status").textContent, /previous microphone request is still pending/i)
  assert.equal(b.commands.length, 0)
  pending = false
  grant({getTracks: () => [late, extra], getAudioTracks: () => [late]}); await flush()
  assert.deepEqual([late.stops, extra.stops], [1, 1])
  assert.equal(b.peers.length, 0)
  assert.equal(b.commands.length, 0)
  b.installed.dispose()
})

test("recipient expiry releases prepared microphone while the original camera prompt remains guarded", async t => {
  const now = Date.parse("2098-12-31T23:59:59Z")
  t.mock.timers.enable({apis: ["setTimeout", "Date"], now})
  const microphone = ownedAudioTrack(), late = videoTrack(), extra = videoTrack()
  let grant
  const b = browser({role: "recipient", snapshot: videoInvitation(), videoAvailable: "true",
    permission: request => request.audio ? trackStream(microphone) : new Promise(resolve => {grant = resolve})})
  await flush(); b.click(b.acceptVideo); await flush()
  t.mock.timers.tick(1_000); await flush()
  assert.equal(microphone.stops, 1)
  assert.equal(b.installed.controller.getState().presentation, "incoming_ringing")
  assert.equal(b.installed.controller.getState().canAcceptVideo, false)
  b.incoming({...videoInvitation(), call_id: "replacement", ringing_deadline_at: "2099-01-01T00:00:30Z"})
  await flush(); b.click(b.acceptVideo); await flush()
  assert.equal(b.requests.filter(r => r.video).length, 1)
  grant(trackStream(late, extra)); await flush()
  assert.deepEqual([late.stops, extra.stops], [1, 1])
  assert.equal(b.commands.length, 0)
  assert.equal(b.nodes.get("direct-call-incoming-preview").srcObject, null)
  b.installed.dispose()
})

function videoTrack() {
  return Object.assign(ownedAudioTrack(), {kind: "video", getSettings: () => ({width: 640, height: 360, frameRate: 15})})
}

function trackStream(...tracks) {
  return {getTracks: () => tracks, getAudioTracks: () => tracks.filter(t => t.kind === "audio"),
    getVideoTracks: () => tracks.filter(t => t.kind === "video")}
}

test("duplicate caller video clicks preserve pending preparation and Cancel allows only a guarded retry", async () => {
  let grant
  const late = ownedAudioTrack(), extra = videoTrack()
  const b = browser({videoAvailable: "true", permission: () => new Promise(resolve => {grant = resolve})})
  await flush(); b.click(b.startVideo); await flush()
  b.click(b.startVideo); await flush()
  assert.equal(b.installed.controller.getState().presentation, "preflighting")
  assert.equal(b.count().acquisitions, 1)
  assert.match(b.nodes.get("direct-call-dock-status").textContent, /browser prompt may still need dismissal/)
  b.click(b.nodes.get("direct-call-dock-cancel"))
  assert.equal(b.installed.controller.getState().presentation, "idle")
  b.click(b.startVideo); await flush()
  assert.equal(b.count().acquisitions, 1)
  assert.match(b.nodes.get("direct-call-dock-status").textContent, /previous microphone request is still pending/i)
  grant(trackStream(late, extra)); await flush()
  assert.deepEqual([late.stops, extra.stops], [1, 1])
  assert.equal(b.commands.length, 0)
  assert.equal(b.preview.srcObject, null)
  b.installed.dispose()
})

for (const outcome of ["grant", "reject"]) {
  test(`cancelled caller camera ${outcome} cannot affect a new audio Call or its microphone`, async t => {
    t.mock.timers.enable({apis: ["setTimeout"]})
    const oldMicrophone = ownedAudioTrack(), currentMicrophone = ownedAudioTrack()
    const late = videoTrack(), extra = videoTrack()
    let settle, microphones = 0
    const b = browser({videoAvailable: "true", permission: request => {
      if (request.audio) return trackStream(++microphones === 1 ? oldMicrophone : currentMicrophone)
      return new Promise((resolve, reject) => {
        settle = () => outcome === "grant" ? resolve(trackStream(late, extra)) : reject({name: "NotAllowedError"})
      })
    }})
    await flush(); b.click(b.startVideo); await flush()
    t.mock.timers.tick(120_000); await flush()
    assert.equal(b.installed.controller.getState().presentation, "preflighting")
    assert.equal(oldMicrophone.stops, 0)
    assert.equal(b.commands.length, 0)
    b.click(b.nodes.get("direct-call-dock-cancel"))
    assert.equal(oldMicrophone.stops, 1)
    // Different device kinds are independent; the abandoned camera cannot
    // stop this fresh microphone or start video when its prompt later settles.
    b.click(b.start); await flush()
    assert.equal(b.installed.controller.getState().presentation, "outgoing_ringing")
    settle(); await flush()
    assert.deepEqual([late.stops, extra.stops], outcome === "grant" ? [1, 1] : [0, 0])
    assert.equal(currentMicrophone.stops, 0)
    assert.equal(b.commands.filter(c => c.event === "start_call").length, 1)
    assert.equal(b.commands[0].payload.media_intent, "audio")
    assert.equal(b.preview.srcObject, null)
    b.installed.dispose()
    assert.equal(currentMicrophone.stops, 1)
  })
}

for (const exit of ["replacement", "owner loss", "terminal", "transport loss"]) {
  test(`recipient ${exit} keeps an old camera prompt guarded through the next Call`, async () => {
    const microphones = [ownedAudioTrack(), ownedAudioTrack()]
    const late = videoTrack(), extra = videoTrack(), fresh = videoTrack()
    let grant, microphoneRequests = 0, cameraRequests = 0
    const b = browser({role: "recipient", snapshot: videoInvitation(), videoAvailable: "true",
      permission: request => {
        if (request.audio) return trackStream(microphones[microphoneRequests++])
        if (++cameraRequests === 1) return new Promise(resolve => {grant = resolve})
        return trackStream(fresh)
      }})
    await flush(); b.click(b.acceptVideo); await flush()
    if (exit === "owner loss") b.project({state: "connecting", ownership: "elsewhere"})
    if (exit === "terminal") b.project({state: "terminal", terminal_outcome: "timed_out"})
    if (exit === "transport loss") {
      b.loseSocket()
      b.installed.signaling.disconnect()
      b.installed.signaling.connect()
      await flush()
    }
    b.incoming({...videoInvitation(), call_id: "new-invitation"}); await flush()
    assert.equal(microphones[0].stops, 1)
    b.click(b.acceptVideo); await flush()
    assert.equal(cameraRequests, 1)
    assert.equal(microphones[1].stops, 0)
    assert.match(b.nodes.get("direct-call-incoming-status").textContent, /previous camera request is still pending/i)
    assert.equal(b.commands.length, 0)
    grant(trackStream(late, extra)); await flush()
    assert.deepEqual([late.stops, extra.stops], [1, 1])
    assert.equal(microphones[1].stops, 0)
    assert.equal(b.nodes.get("direct-call-incoming-preview").srcObject, null)
    assert.equal(b.commands.length, 0)
    b.click(b.acceptVideo); await flush()
    assert.equal(cameraRequests, 2)
    assert.equal(microphoneRequests, 2)
    assert.deepEqual(b.preview.srcObject.tracks, [fresh])
    assert.equal(b.commands.find(c => c.event === "accept_call").payload.call_id, "new-invitation")
    b.installed.dispose()
    assert.deepEqual([...microphones, fresh].map(track => track.stops), [1, 1, 1])
  })
}

test("Escape cancels recipient capture preparation and leaves the invitation answerable", async () => {
  let grant
  const late = ownedAudioTrack()
  const b = browser({role: "recipient", snapshot: videoInvitation(), videoAvailable: "true",
    permission: () => new Promise(resolve => {grant = resolve})})
  await flush(); b.click(b.acceptVideo); await flush()
  b.nodes.get("direct-call-incoming-cancel-preparation").focus()
  b.keydown("Escape")
  assert.equal(b.installed.controller.getState().presentation, "incoming_ringing")
  assert.equal(b.focused(), b.nodes.get("direct-call-incoming-title"))
  assert.equal(b.commands.length, 0)
  grant(trackStream(late)); await flush()
  assert.equal(late.stops, 1)
  b.installed.dispose()
})

for (const role of ["caller", "recipient"]) {
  test(`${role} keeps the active Call when browser ICE gathering completes`, async () => {
    const b = browser({role, ...(role === "recipient" ? {snapshot: {
      call_id: "call", role, state: "ringing", ownership: "unclaimed", media_intent: "audio",
    }} : {}), iceReply(payload) {
      // This is the pinned server's actual response to this optional marker;
      // see call_media_signaling_test.exs, "candidate queues ...".
      const reason = payload.end_of_candidates ? "end_of_candidates_unsupported" : null
      return {receive(status, fn) {
        if (reason && status === "error") queueMicrotask(() => fn({reason}))
        else if (!reason && status === "ok") queueMicrotask(() => fn(payload))
        return this
      }}
    }})
    await flush(); b.click(role === "caller" ? b.start : b.answer); await flush()
    if (role === "caller") {b.project({state: "connecting"}); await flush()}
    b.peers[0].ready(); b.project({state: "active"}); await flush()
    b.peers[0].emitCandidate(null); await flush()
    assert.equal(b.commands.filter(c => c.event === "leave_call").length, 0)
    assert.equal(b.installed.controller.getState().presentation, "active")
    assert.equal(b.peers[0].closed, undefined)
    assert.equal(b.tracks[0].readyState, "live")
    assert.notEqual(b.audio.srcObject, null)
    b.installed.dispose()
  })

  for (const [name, message] of [
    ["SecurityError", /Camera access is blocked.*browser and system camera settings/],
    ["NotFoundError", /No camera is available.*Connect a camera/],
    ["NotReadableError", /camera is busy or couldn't be read.*Close other camera apps/],
    ["AbortError", /camera is busy or couldn't be read.*Close other camera apps/],
    ["OverconstrainedError", /camera settings are unsupported.*Try another camera/],
    ["TypeError", /Couldn't start the camera.*Retry/],
    ["UnexpectedError", /Couldn't start the camera.*Retry/],
  ]) {
    test(`${role} ${name} explains camera recovery locally until explicit audio fallback`, async t => {
      const microphone = ownedAudioTrack()
      const b = browser({role, snapshot: role === "recipient" ? videoInvitation() : null,
        videoAvailable: "true", permission: request => {
          if (request.audio) return trackStream(microphone)
          throw {name, message: "private camera", constraint: "private constraint", deviceId: "private id"}
        }})
      t.after(() => b.installed.dispose())
      await flush(); b.click(role === "caller" ? b.startVideo : b.acceptVideo); await flush()
      const status = b.nodes.get(role === "caller" ? "direct-call-dock-status" : "direct-call-incoming-status")
      assert.match(status.textContent, message)
      assert.doesNotMatch(status.textContent, /private|Error|prompt|you denied|policy/)
      assert.match(status.textContent, /Microphone ready/)
      assert.equal(b.preview.srcObject, null)
      assert.equal(b.nodes.get("direct-call-incoming-preview").srcObject, null)
      assert.equal(microphone.stops, 0)
      const command = role === "caller" ? "start_call" : "accept_call"
      assert.equal(b.commands.filter(c => c.event === command).length, 0)
      if (role === "recipient") {
        assert.equal(b.installed.controller.getState().call.state, "ringing")
        assert.equal(b.installed.controller.getState().call.ringing_deadline_at, "2099-01-01T00:00:00Z")
      }
      b.click(b.nodes.get(role === "caller" ? "direct-call-dock-start-voice-instead" :
        "direct-call-incoming-answer-without-video")); await flush()
      assert.deepEqual(b.requests.map(r => Boolean(r.audio)), [true, false])
      assert.deepEqual(b.commands.filter(c => c.event === command).map(c =>
        c.payload[role === "caller" ? "media_intent" : "answer_mode"]), ["audio"])
      assert.equal(microphone.stops, 0)
      b.installed.dispose()
      assert.equal(microphone.stops, 1)
    })
  }

  for (const environment of ["missing-api", "insecure"]) {
    test(`${role} ${environment} explains unavailable capture without requesting devices or dispatching`, async t => {
      const b = browser({role, snapshot: role === "recipient" ? videoInvitation() : null,
        videoAvailable: "true", ...(environment === "missing-api" ? {mediaDevices: null} : {secureContext: false})})
      t.after(() => b.installed.dispose())
      await flush(); b.click(role === "caller" ? b.startVideo : b.acceptVideo); await flush()
      assert.match(b.nodes.get(role === "caller" ? "direct-call-dock-status" : "direct-call-incoming-status")
        .textContent, /Microphone capture is unavailable.*supported browser.*secure page.*retry/)
      assert.equal(b.count().acquisitions, 0)
      assert.equal(b.commands.some(c => ["start_call", "accept_call"].includes(c.event)), false)
      assert.equal(b.installed.controller.getState().microphoneReady, false)
      assert.equal(b.installed.controller.getState().canFallbackToAudio, false)
      if (role === "recipient") {
        assert.equal(b.installed.controller.getState().call.state, "ringing")
        assert.equal(b.nodes.get("direct-call-incoming-decline").disabled, false)
        assert.equal(b.acceptVideo.disabled, false)
      } else assert.equal(b.nodes.get("direct-call-dock-retry").hidden, false)
    })
  }

  test(`${role} camera API loss preserves the ready microphone for explicit fallback`, async t => {
    const microphone = ownedAudioTrack(), requests = []
    const mediaDevices = {getUserMedia(request) {
      requests.push(request)
      mediaDevices.getUserMedia = undefined
      return trackStream(microphone)
    }}
    const b = browser({role, snapshot: role === "recipient" ? videoInvitation() : null,
      videoAvailable: "true", mediaDevices})
    t.after(() => b.installed.dispose())
    await flush(); b.click(role === "caller" ? b.startVideo : b.acceptVideo); await flush()
    assert.match(b.nodes.get(role === "caller" ? "direct-call-dock-status" : "direct-call-incoming-status")
      .textContent, /Camera capture is unavailable.*supported browser.*secure page.*retry.*Microphone ready/)
    assert.equal(b.commands.some(c => ["start_call", "accept_call"].includes(c.event)), false)
    b.click(b.nodes.get(role === "caller" ? "direct-call-dock-start-voice-instead" :
      "direct-call-incoming-answer-without-video")); await flush()
    assert.deepEqual(requests, [{audio: true, video: false}])
    assert.equal(b.installed.controller.getState().call[role === "caller" ? "media_intent" : "answer_mode"], "audio")
    b.installed.dispose()
    assert.equal(microphone.stops, 1)
  })

  for (const [failure, settings] of [
    ["width", {width: 1280, height: 540, frameRate: 24}],
    ["height", {width: 960, height: 720, frameRate: 24}],
    ["frame-rate", {width: 960, height: 540, frameRate: 30}],
    ["missing-settings", {}], ["empty", null], ["ended", null],
  ]) {
    test(`${role} ${failure} camera result releases every returned track and permits lower-profile retry`, async t => {
      const records = []
      const microphone = ownedAudioTrack(), rejected = Object.assign(ownedAudioTrack(), {
        kind: "video", getSettings: () => settings,
        readyState: failure === "ended" ? "ended" : "live",
      })
      const extra = ownedAudioTrack()
      const lower = Object.assign(ownedAudioTrack(), {
        kind: "video", getSettings: () => ({width: 320, height: 180, frameRate: 12}),
      })
      let cameras = 0
      const b = browser({diagnosticWrite: record => records.push(record), role, snapshot: role === "recipient" ? videoInvitation() : null,
        videoAvailable: "true", permission: request => {
          if (request.audio) return trackStream(microphone)
          if (++cameras === 1) return trackStream(...(failure === "empty" ? [extra] : [rejected, extra]))
          return trackStream(lower)
        }})
      t.after(() => b.installed.dispose())
      await flush(); b.click(role === "caller" ? b.startVideo : b.acceptVideo); await flush()
      assert.deepEqual(b.requests.map(r => Boolean(r.audio)), [true, false])
      assert.equal(extra.stops, 1)
      assert.equal(rejected.stops, failure === "empty" ? 0 : 1)
      assert.equal(microphone.stops, 0)
      const command = role === "caller" ? "start_call" : "accept_call"
      assert.equal(b.commands.filter(c => c.event === command).length, 0)
      assert.equal(b.preview.srcObject, null)
      assert.equal(b.nodes.get("direct-call-incoming-preview").srcObject, null)
      assert.match(b.nodes.get(role === "caller" ? "direct-call-dock-status" : "direct-call-incoming-status")
        .textContent, failure === "empty" || failure === "ended" ? /camera stopped/ : /camera settings are unsupported/)
      b.click(role === "caller" ? b.nodes.get("direct-call-dock-retry") : b.acceptVideo); await flush()
      assert.deepEqual(b.requests, [{audio: true, video: false},
        {audio: false, video: {width: {ideal: 960, max: 960}, height: {ideal: 540, max: 540}, frameRate: {ideal: 24, max: 24}}},
        {audio: false, video: {width: {ideal: 960, max: 960}, height: {ideal: 540, max: 540}, frameRate: {ideal: 24, max: 24}}}])
      assert.deepEqual(b.commands.filter(c => c.event === command).map(c =>
        c.payload[role === "caller" ? "media_intent" : "answer_mode"]), ["video"])
      assert.deepEqual(b.preview.srcObject.tracks, [lower])
      assert.equal(b.installed.controller.getState().cameraState, role === "caller" ? "preview_ready" : "enabled")
      assert.ok(records.some(r => r.stage === "preflight" && r.outcome === "error"))
      assert.ok(records.some(r => r.stage === "preflight" && r.outcome === "preview_ready"))
      assert.doesNotMatch(JSON.stringify(records), /private|credential|call_id|deviceId/)
      b.installed.dispose()
      assert.deepEqual([microphone.stops, extra.stops, lower.stops], [1, 1, 1])
      assert.equal(rejected.stops, failure === "empty" ? 0 : 1)
    })
  }
}

test("actual browser ICE candidates are forwarded and their rejection still terminates the Call", async () => {
  let rejected = false
  const b = browser({iceReply(payload) {
    return {receive(status, fn) {
      if (status === (rejected ? "error" : "ok")) {
        queueMicrotask(() => fn(rejected ? {reason: "candidate_rejected"} : payload))
      }
      return this
    }}
  }})
  await flush(); b.click(b.start); await flush()
  b.project({state: "connecting"}); await flush()
  b.peers[0].ready(); b.project({state: "active"}); await flush()
  const candidate = {candidate: "candidate:1 1 UDP 2122260223 127.0.0.1 50000 typ host", sdpMid: "0", sdpMLineIndex: 0}
  b.peers[0].emitCandidate({toJSON: () => candidate}); await flush()
  assert.deepEqual(b.commands.find(c => c.event === "ice_candidate").payload.candidate, candidate)
  assert.equal(b.commands.filter(c => c.event === "leave_call").length, 0)
  rejected = true
  b.peers[0].emitCandidate({toJSON: () => candidate}); await flush()
  assert.equal(b.commands.filter(c => c.event === "leave_call").length, 1)
  assert.equal(b.peers[0].closed, true)
  assert.equal(b.tracks[0].readyState, "ended")
  assert.equal(b.audio.srcObject, null)
  b.installed.dispose()
})

test("answering keeps live capture while accepted pair media is still being published", async () => {
  const b = browser({role: "recipient", snapshot: {
    call_id: "call", role: "recipient", state: "ringing", ownership: "unclaimed", media_intent: "audio",
  }, credentialsReply: () => ({receive(status, fn) {
    if (status === "error") queueMicrotask(() => fn({reason: "not_admitted"}))
    return this
  }})})
  await flush()
  b.click(b.answer)
  await flush()
  assert.equal(b.commands.filter(c => c.event === "accept_call").length, 1)
  assert.equal(b.commands.filter(c => c.event === "leave_call").length, 0)
  assert.equal(b.tracks[0].readyState, "live")
  b.installed.dispose()
})

for (const permissionPending of [true, false]) {
  test(`recipient tabs elect one media owner while the loser has ${permissionPending ? "permission" : "acceptance"} pending`, async () => {
    const invitation = {call_id: "call", role: "recipient", state: "ringing", ownership: "unclaimed", media_intent: "audio"}
    let settlePermission, settleAccept
    const loser = browser({role: "recipient", snapshot: invitation,
      ...(permissionPending ? {permission: () => new Promise(resolve => {settlePermission = resolve})} :
        {acceptReply: () => ({receive(status, fn) {if (status === "ok") settleAccept = fn; return this}})})})
    const winner = browser({role: "recipient", snapshot: invitation})
    const observer = browser({role: "recipient", snapshot: invitation})
    await flush()
    assert.equal(observer.count().acquisitions, 0)
    loser.click(loser.answer); winner.click(winner.answer); await flush()
    loser.project({state: "connecting", ownership: "elsewhere"})
    observer.project({state: "connecting", ownership: "elsewhere"})
    const oldTrack = permissionPending ? Object.assign(new EventTarget(), {kind: "audio", readyState: "live", enabled: true, stops: 0,
      stop() {this.stops++; this.readyState = "ended"}}) : loser.tracks[0]
    if (permissionPending) settlePermission({getTracks: () => [oldTrack], getAudioTracks: () => [oldTrack]})
    else settleAccept({signaling_session_id: "topic-session", call: {...invitation, state: "connecting", ownership: "elsewhere"}})
    await flush()
    assert.equal(oldTrack.stops, 1)
    assert.equal(loser.peers.length, 0)
    assert.equal(observer.peers.length, 0)
    assert.equal(observer.count().acquisitions, 0)
    assert.equal(winner.peers.length, 1)
    assert.equal(winner.tracks[0].stops, 0)
    assert.equal(loser.installed.controller.getState().presentation, "owned_elsewhere")
    assert.equal(observer.installed.controller.getState().presentation, "owned_elsewhere")
    assert.equal(loser.commands.filter(c => c.event === "media_credentials").length, 0)
    winner.peers[0].ready(); winner.project({state: "active"}); await flush()
    oldTrack.dispatchEvent(new Event("ended"))
    assert.equal(winner.audio.srcObject != null, true)
    assert.equal(winner.tracks[0].stops, 0)
    winner.click(winner.leave); await flush()
    assert.equal(winner.tracks[0].stops, 1)
    assert.equal(winner.timers.size, 0)
    for (const tab of [loser, winner, observer]) tab.installed.dispose()
  })
}

for (const exit of ["terminal", "channel", "socket", "pagehide", "dispose"]) {
  test(`full audio flow releases exact resources on ${exit} and ignores old callbacks after a new Call`, async () => {
    const b = browser()
    await flush(); b.click(b.start); await flush(); b.project({state: "connecting"}); await flush()
    const oldPeer = b.peers[0], oldTrack = b.tracks[0]
    oldPeer.ready(); b.project({state: "active"}); await flush()
    if (exit === "terminal") b.project({state: "terminal", terminal_outcome: "ended"})
    if (exit === "channel") b.loseChannel()
    if (exit === "socket") b.loseSocket()
    if (exit === "pagehide") b.win.dispatchEvent(new Event("pagehide"))
    if (exit === "dispose") b.installed.dispose()
    // Synchronous observation/local teardown is independently below five seconds.
    assert.equal(oldTrack.stops, 1)
    assert.equal(oldPeer.closed, true)
    assert.equal(b.audio.srcObject, null)
    assert.equal(b.timers.size, 0)
    if (["channel", "socket", "pagehide"].includes(exit)) {
      b.snapshot({call_id: "call", role: "caller", state: "terminal", terminal_outcome: "ended"})
      b.installed.signaling.disconnect(); b.installed.signaling.connect(); await flush()
    }
    if (exit !== "dispose") {
      b.click(b.start); await flush(); b.project({state: "connecting"}); await flush()
      b.peers[1].ready(); b.project({state: "active"}); await flush()
      const stream = b.audio.srcObject
      oldTrack.end(); oldPeer.ready()
      await flush()
      assert.equal(b.tracks[1].stops, 0)
      assert.equal(b.peers[1].closed, undefined)
      assert.equal(b.audio.srcObject, stream)
      assert.equal(b.commands.filter(c => c.event === "leave_call").length, 0)
      assert.equal(b.count().acquisitions, 2)
    }
    b.installed.dispose()
  })
}

for (const terminalWhileFrozen of [false, true]) {
  test(`BFCache restores an unprepared selected caller as ${terminalWhileFrozen ? "terminal" : "interrupted"} without media resumption`, async () => {
    const call = {call_id: "call", role: "caller", state: "connecting", ownership: "self", media_intent: "audio"}
    const b = browser({snapshot: call})
    await flush()
    assert.equal(b.enable.hidden, false)
    b.win.dispatchEvent(new Event("pagehide"))
    if (terminalWhileFrozen) b.snapshot({...call, state: "terminal", terminal_outcome: "ended"})
    const event = new Event("pageshow"); event.persisted = true
    b.win.dispatchEvent(event); await flush()
    b.click(b.enable)
    assert.equal(b.enable.hidden, true)
    assert.equal(b.count().acquisitions, 0)
    assert.equal(b.peers.length, 0)
    assert.equal(b.commands.length, 0)
    if (!terminalWhileFrozen) assert.match(b.nodes.get("direct-call-dock-status").textContent, /interrupted/i)
    b.installed.dispose()
  })
}

for (const initiallyMuted of [false, true]) {
  test(`deafen silences playback and restores ${initiallyMuted ? "muted" : "unmuted"} microphone preference`, async () => {
    const b = browser()
    await flush(); b.click(b.start); await flush()
    b.project({state: "connecting"}); await flush()
    b.peers[0].ready(); b.project({state: "active"}); await flush()
    if (initiallyMuted) b.click(b.mute)
    b.click(b.deafen)
    assert.equal(b.audio.muted, true)
    assert.equal(b.tracks[0].enabled, false)
    assert.equal(b.installed.controller.getState().localMuted, initiallyMuted)
    assert.equal(b.installed.controller.getState().localDeafened, true)
    assert.equal(b.deafen.getAttribute("aria-label"), "Undeafen audio")
    assert.equal(b.deafen.getAttribute("aria-pressed"), undefined)
    assert.equal(b.deafen.getAttribute("data-active"), "true")
    assert.match(b.nodes.get("direct-call-dock-status").textContent, /Deafened.*microphone muted/)
    b.click(b.deafen); await flush()
    assert.equal(b.audio.muted, false)
    assert.equal(b.tracks[0].enabled, !initiallyMuted)
    assert.equal(b.installed.controller.getState().localMuted, initiallyMuted)
    assert.equal(b.deafen.getAttribute("aria-pressed"), undefined)
    assert.equal(b.deafen.getAttribute("data-active"), "false")
    assert.deepEqual(b.commands.filter(c => c.event === "local_media_state").map(c => c.payload.microphone_muted), initiallyMuted ? [false, true] : [false, true, false])
    assert.equal(b.count().acquisitions, 1)
    assert.equal(b.peers.length, 1)
    assert.equal(b.peers[0].transceivers.length, 2)
    assert.equal(b.commands.filter(c => c.event === "offer").length, 1)
    b.installed.dispose()
  })
}

for (const role of ["caller", "recipient"]) {
  test(`${role} selects populated audio before play so the connected dock does not keep waiting`, async () => {
    const b = browser({role, play: () => b.audio.selectedTracks.length ? Promise.resolve() : new Promise(() => {}),
      snapshot: role === "recipient" ? {call_id: "call", role, state: "ringing", ownership: "unclaimed", media_intent: "audio"} : null})
    await flush(); b.click(role === "caller" ? b.start : b.answer); await flush()
    if (role === "caller") {b.project({state: "connecting"}); await flush()}
    b.peers[0].ready(); b.project({state: "active"}); await flush()
    assert.equal(b.nodes.get("direct-call-dock-status").textContent, "Call connected.")
    assert.equal(b.audio.selectedTracks.length, 1)
    assert.equal(b.count().plays, 1)
    assert.equal(b.peers.length, 1)
    b.click(b.leave); await flush()
    assert.equal(b.audio.srcObject, null)
    b.installed.dispose()
  })

  test(`${role} playback clears the waiting status while the play promise is pending`, async () => {
    const b = browser({role, play: () => new Promise(() => {}), snapshot: role === "recipient" ? {
      call_id: "call", role, state: "ringing", ownership: "unclaimed", media_intent: "audio",
    } : null})
    b.audio.dispatchEvent(new Event("playing"))
    await flush(); b.click(role === "caller" ? b.start : b.answer); await flush()
    if (role === "caller") {b.project({state: "connecting"}); await flush()}
    b.peers[0].ready(); b.project({state: "active"}); await flush()
    assert.equal(b.nodes.get("direct-call-dock-status").textContent, "Call connected. Waiting for audio…")
    b.audio.dispatchEvent(new Event("playing")); await flush()
    assert.equal(b.nodes.get("direct-call-dock-status").textContent, "Call connected.")
    assert.equal(b.commands.filter(c => c.event === "leave_call").length, 0)
    assert.equal(b.count().plays, 1)
    assert.equal(b.count().acquisitions, 1)
    assert.equal(b.peers.length, 1)
    b.click(b.leave); await flush()
    assert.equal(getEventListeners(b.audio, "playing").length, 0)
    b.installed.dispose()
  })
}

for (const success of [true, false]) {
  test(`late play ${success ? "resolution" : "rejection"} preserves observed playback`, async () => {
    let settle
    const pending = new Promise(resolve => {settle = resolve})
    const b = browser({play: () => pending.then(() => {if (!success) throw Error("blocked")})})
    await flush(); b.click(b.start); await flush()
    b.project({state: "connecting"}); await flush()
    b.peers[0].ready(); b.project({state: "active"}); await flush()
    b.audio.dispatchEvent(new Event("playing")); await flush()
    settle(); await flush()
    assert.equal(b.nodes.get("direct-call-dock-status").textContent, "Call connected.")
    assert.equal(b.enableAudio.hidden, true)
    assert.equal(b.installed.controller.getState().playbackState, "playing")
    b.installed.dispose()
    assert.equal(getEventListeners(b.audio, "playing").length, 0)
  })
}

test("blocked audio keeps transport active and its dock action retries playback only", async () => {
  let blocked = true
  const b = browser({play: () => {if (blocked) throw Error("autoplay blocked")}})
  await flush(); b.click(b.start); await flush()
  b.project({state: "connecting"}); await flush()
  b.peers[0].ready(); b.project({state: "active"}); await flush()
  const stream = b.audio.srcObject
  assert.equal(b.installed.controller.getState().presentation, "active")
  assert.equal(b.installed.controller.getState().mediaConnectionState, "connected")
  assert.equal(b.enableAudio.hidden, false)
  assert.equal(b.enableAudio.getAttribute("aria-label"), "Play call audio")
  assert.match(b.nodes.get("direct-call-dock-status").textContent, /Select Play audio/)
  b.click(b.deafen)
  assert.equal(b.enableAudio.hidden, true)
  b.click(b.enableAudio)
  assert.equal(b.count().plays, 1)
  b.click(b.deafen)
  assert.equal(b.enableAudio.hidden, false)
  b.click(b.enableAudio); await flush()
  assert.equal(b.enableAudio.hidden, false)
  blocked = false
  b.click(b.enableAudio); await flush()
  assert.equal(b.enableAudio.hidden, true)
  assert.equal(b.installed.controller.getState().playbackState, "playing")
  assert.equal(b.nodes.get("direct-call-dock-status").textContent, "Call connected.")
  assert.equal(b.count().plays, 3)
  assert.equal(b.count().acquisitions, 1)
  assert.equal(b.peers.length, 1)
  assert.equal(b.audio.srcObject, stream)
  assert.equal(b.commands.filter(c => c.event === "offer").length, 1)
  b.installed.dispose()
})

test("mute changes while deafened remain independent across interruption and navigation", async () => {
  const b = browser()
  await flush(); b.click(b.start); await flush()
  b.project({state: "connecting"}); await flush()
  b.peers[0].ready(); b.project({state: "active"}); await flush()
  b.click(b.deafen); b.click(b.mute)
  assert.equal(b.mute.getAttribute("aria-pressed"), undefined)
  assert.equal(b.mute.getAttribute("data-active"), "true")
  assert.equal(b.tracks[0].enabled, false)
  b.peers[0].connectionState = "disconnected"
  b.peers[0].dispatchEvent(new Event("connectionstatechange"))
  b.win.dispatchEvent(new Event("phx:page-loading-start"))
  b.win.dispatchEvent(new Event("phx:page-loading-stop"))
  assert.equal(b.installed.controller.getState().localDeafened, true)
  assert.equal(b.installed.controller.getState().localMuted, true)
  assert.equal(b.audio.muted, true)
  b.peers[0].ready(); b.click(b.deafen)
  assert.equal(b.tracks[0].enabled, false)
  b.click(b.deafen); b.click(b.mute)
  assert.equal(b.mute.getAttribute("aria-pressed"), undefined)
  assert.equal(b.mute.getAttribute("data-active"), "false")
  assert.equal(b.tracks[0].enabled, false)
  b.click(b.deafen); await flush()
  assert.equal(b.tracks[0].enabled, true)
  assert.equal(b.audio.muted, false)
  assert.deepEqual(b.commands.filter(c => c.event === "local_media_state").map(c => c.payload.microphone_muted), [false, true, false])
  b.click(b.deafen); b.click(b.leave)
  assert.equal(b.installed.controller.getState().localDeafened, false)
  assert.equal(b.installed.controller.getState().localMuted, false)
  assert.equal(b.deafen.hidden, true)
  assert.equal(b.audio.srcObject, null)
  await flush()
  b.click(b.start); await flush(); b.project({state: "connecting"}); await flush()
  assert.equal(b.installed.controller.getState().localDeafened, false)
  assert.equal(b.installed.controller.getState().localMuted, false)
  assert.equal(b.audio.muted, false)
  b.installed.dispose()
})

test("deafen during negotiation silences the retained output and sends only the latest effective state", async () => {
  let answer
  const b = browser({offerReply(payload) {
    return {receive(status, fn) {
      if (status === "ok") answer = () => fn({...payload, description: {type: "answer", sdp: "answer"}})
      return this
    }}
  }})
  await flush(); b.click(b.start); await flush()
  b.project({state: "connecting"}); await flush()
  b.click(b.deafen)
  assert.equal(b.audio.muted, true)
  assert.equal(b.tracks[0].enabled, false)
  b.click(b.mute); b.click(b.deafen)
  assert.equal(b.audio.muted, false)
  assert.equal(b.tracks[0].enabled, false)
  assert.equal(b.commands.filter(c => c.event === "local_media_state").length, 0)
  answer(); await flush()
  const updates = b.commands.filter(c => c.event === "local_media_state")
  assert.equal(updates.length, 1)
  assert.equal(updates[0].payload.microphone_muted, true)
  assert.equal(updates[0].payload.camera_enabled, false)
  assert.equal(b.peers.length, 1)
  b.installed.dispose()
})

for (const trigger of ["owner-loss", "pagehide"]) {
  test(`${trigger} clears deafen and fences further local audio controls`, async () => {
    const b = browser()
    await flush(); b.click(b.start); await flush()
    b.project({state: "connecting"}); await flush()
    b.peers[0].ready(); b.project({state: "active"}); await flush()
    b.click(b.deafen)
    if (trigger === "owner-loss") b.project({ownership: "elsewhere"})
    else b.win.dispatchEvent(new Event("pagehide"))
    await flush()
    b.click(b.deafen); b.click(b.enableAudio)
    assert.equal(b.installed.controller.getState().localDeafened, false)
    assert.equal(b.installed.controller.getState().canDeafen, false)
    assert.equal(b.installed.controller.getState().canEnableAudio, false)
    assert.equal(b.tracks[0].stops, 1)
    assert.equal(b.peers[0].closed, true)
    assert.equal(b.audio.srcObject, null)
    assert.equal(b.count().plays, 1)
    b.installed.dispose()
  })
}

for (const success of [true, false]) {
  test(`late playback ${success ? "success" : "failure"} after terminal cleanup cannot restore controls`, async () => {
    let settle
    const pending = new Promise(resolve => {settle = resolve})
    const b = browser({play: () => pending.then(() => {if (!success) throw Error("blocked")})})
    await flush(); b.click(b.start); await flush()
    b.project({state: "connecting"}); await flush()
    b.peers[0].ready(); b.project({state: "active"}); await flush()
    b.click(b.deafen)
    b.project({state: "terminal", terminal_outcome: "ended"})
    await flush()
    const state = b.installed.controller.getState()
    settle(); await flush()
    b.click(b.deafen); b.click(b.enableAudio)
    assert.deepEqual(b.installed.controller.getState(), state)
    assert.equal(state.localDeafened, false)
    assert.equal(b.deafen.hidden, true)
    assert.equal(b.enableAudio.hidden, true)
    assert.equal(b.peers[0].closed, true)
    assert.equal(b.tracks[0].stops, 1)
    assert.equal(b.audio.srcObject, null)
    assert.equal(b.count().plays, 1)
    b.installed.dispose()
  })
}

for (const role of ["caller", "recipient"]) {
  test(`${role} completes the controlled browser audio flow across navigation and leaves`, async () => {
    const b = browser({role, snapshot: role === "recipient" ? {call_id: "call", role, state: "ringing", ownership: "unclaimed", media_intent: "audio"} : null})
    await flush()
    assert.equal(b.count().acquisitions, 0)
    b.click(role === "caller" ? b.start : b.answer); await flush()
    if (role === "caller") b.project({state: "connecting"})
    await flush()
    assert.equal(b.peers.length, 1)
    assert.equal(b.installed.controller.getState().presentation, "connecting")
    b.peers[0].ready(); await flush()
    assert.equal(b.count().plays, 1)
    if (role === "recipient") assert.match(b.nodes.get("direct-call-dock-status").textContent, /caller's microphone/)
    b.project({state: "active"}); await flush()
    assert.equal(b.installed.controller.getState().presentation, "active")
    assert.equal(b.nodes.get("direct-call-dock-status").textContent, "Call connected.")
    const stream = b.audio.srcObject
    for (let i = 0; i < 3; i++) {
      b.win.dispatchEvent(new Event("phx:page-loading-start")); b.win.dispatchEvent(new Event("phx:page-loading-stop"))
    }
    assert.deepEqual(b.count(), {sockets: 1, acquisitions: 1, plays: 1})
    assert.equal(b.audio.srcObject, stream)
    assert.equal(b.peers.length, 1)
    b.click(b.leave)
    assert.equal(b.tracks[0].stops, 1)
    assert.equal(b.peers[0].closed, true)
    assert.equal(b.audio.srcObject, null)
    assert.equal(b.timers.size, 0)
    await flush()
    assert.equal(b.installed.controller.getState().resultCode, "ended")
    b.installed.dispose()
  })
}

test("pagehide cancels a pending answer and releases a late permission result", async () => {
  let resolve
  const pending = new Promise(r => {resolve = r})
  const b = browser({role: "recipient", snapshot: {call_id: "call", role: "recipient", state: "ringing", ownership: "unclaimed", media_intent: "audio"}, permission: () => pending})
  await flush(); b.click(b.answer); await flush()
  b.win.dispatchEvent(new Event("pagehide"))
  const track = Object.assign(new EventTarget(), {kind: "audio", readyState: "live", enabled: true, stops: 0, stop() {this.stops++}})
  resolve({getTracks: () => [track], getAudioTracks: () => [track]}); await flush()
  assert.equal(track.stops, 1)
  assert.equal(b.commands.filter(c => c.event === "accept_call").length, 0)
  assert.equal(b.peers.length, 0)
  b.installed.dispose()
})

test("selected video caller requests only microphone explicitly and camera only through a later gesture", async t => {
  const {track: voice, controller: voiceController} = await capturedVoice()
  t.after(() => voiceController.leave())
  const invitation = {call_id: "call", role: "caller", state: "ringing", ownership: "elsewhere",
    media_intent: "video", ringing_deadline_at: "2099-01-01T00:00:00Z"}
  const selected = browser({snapshot: invitation, videoAvailable: "true"})
  const observer = browser({snapshot: invitation, videoAvailable: "true"})
  t.after(() => {selected.installed.dispose(); observer.installed.dispose()})
  await flush()
  for (const tab of [selected, observer]) {
    assert.equal(tab.requests.length, 0)
    tab.click(tab.camera); tab.click(tab.enable)
  }
  selected.project({state: "connecting", ownership: "self", answer_mode: "video"})
  observer.project({state: "connecting", ownership: "elsewhere", answer_mode: "video"})
  await flush()
  assert.equal(selected.requests.length, 0)
  assert.equal(selected.enable.hidden, false)
  assert.equal(observer.enable.hidden, true)
  selected.click(selected.camera); observer.click(observer.enable); observer.click(observer.camera)
  await flush()
  assert.equal(selected.requests.length, 0)
  selected.click(selected.enable); await flush()
  assert.deepEqual(selected.requests, [{audio: true, video: false}])
  assert.equal(selected.peers.length, 1)
  assert.equal(selected.peers[0].transceivers[1].sender.track, null)
  assert.equal(selected.preview.srcObject, null)
  selected.peers[0].ready(); selected.project({state: "active"}); await flush()
  selected.click(selected.mute); selected.click(selected.deafen)
  selected.click(selected.camera); await flush()
  assert.equal(selected.requests.length, 2)
  assert.equal(selected.requests[1].audio, false)
  assert.equal(selected.peers[0].transceivers[1].sender.track, selected.tracks[1])
  assert.equal(selected.preview.srcObject.tracks[0], selected.tracks[1])
  assert.equal(selected.tracks[0].enabled, false)
  assert.equal(selected.installed.controller.getState().call.media_intent, "video")
  assert.equal(selected.installed.controller.getState().call.answer_mode, "video")
  assert.equal(observer.requests.length, 0)
  assert.equal(observer.peers.length, 0)
  assert.equal(voice.stops, 0)
  assert.equal(voiceController.state().status, "capturing")
})

test("selected fallback has no capture before its dock gesture; observers have no microphone action", async () => {
  for (const ownership of ["self", "elsewhere"]) {
    const b = browser({snapshot: {call_id: "call", role: "caller", state: "connecting", ownership, media_intent: "audio"}})
    await flush()
    assert.equal(b.count().acquisitions, 0)
    assert.equal(b.enable.hidden, ownership !== "self")
    if (ownership === "self") {
      b.click(b.enable); await flush()
      assert.equal(b.peers.length, 1)
      b.peers[0].ready(); b.project({state: "active"}); await flush()
      b.tracks[0].end(); await flush()
      assert.equal(b.peers[0].closed, true)
      assert.equal(b.installed.controller.getState().resultCode, "ended")
    } else {
      assert.equal(b.installed.controller.getState().presentation, "owned_elsewhere")
      assert.equal(b.peers.length, 0)
    }
    b.installed.dispose()
  }
})

for (const exit of ["original deadline", "owner loss", "channel loss"]) {
  test(`selected video caller releases late microphone after ${exit} without camera or ownership replay`, async t => {
    const {track: voice, controller: voiceController} = await capturedVoice()
    t.after(() => voiceController.teardown())
    let resolve
    const late = ownedAudioTrack(), extra = ownedAudioTrack()
    const b = browser({snapshot: {call_id: "call", state: "connecting", role: "caller", ownership: "self",
      media_intent: "video", answer_mode: "video"}, videoAvailable: "true",
      permission: () => new Promise(r => {resolve = r})})
    t.after(() => b.installed.dispose())
    await flush()
    assert.equal(b.requests.length, 0)
    b.click(b.enable); await flush()
    assert.deepEqual(b.requests, [{audio: true, video: false}])
    if (exit === "original deadline") b.project({state: "terminal", terminal_outcome: "failed"})
    if (exit === "owner loss") b.project({ownership: "elsewhere"})
    if (exit === "channel loss") b.loseChannel()
    resolve({getTracks: () => [late, extra], getAudioTracks: () => [late, extra]}); await flush()
    assert.equal(late.stops, 1)
    assert.equal(extra.stops, 1)
    assert.equal(b.peers.length, 0)
    assert.equal(b.preview.srcObject, null)
    b.click(b.enable); b.click(b.camera); await flush()
    assert.equal(b.requests.length, 1)
    assert.equal(b.commands.some(c => ["offer", "media_credentials", "accept_call", "start_call"].includes(c.event)), false)
    assert.equal(voice.stops, 0)
    assert.equal(voiceController.state().status, "capturing")
  })
}

for (const state of ["connecting", "active"]) {
  test(`microphone source loss during ${state} terminates despite connected transport`, async () => {
    const b = browser()
    await flush(); b.click(b.start); await flush(); b.project({state: "connecting"}); await flush()
    b.peers[0].ready()
    if (state === "active") b.project({state})
    await flush()
    b.tracks[0].end(); await flush()
    assert.equal(b.commands.filter(c => c.event === "leave_call").length, 1)
    assert.equal(b.peers[0].closed, true)
    assert.equal(b.audio.srcObject, null)
    assert.equal(b.timers.size, 0)
    assert.equal(b.count().acquisitions, 1)
    b.installed.dispose()
  })
}

test("pagehide releases active audio immediately; persisted pageshow never reacquires it", async () => {
  const b = browser()
  await flush(); b.click(b.start); await flush(); b.project({state: "connecting"}); await flush()
  b.peers[0].ready(); b.project({state: "active"}); await flush()
  b.win.dispatchEvent(new Event("pagehide"))
  assert.equal(b.tracks[0].stops, 1)
  assert.equal(b.peers[0].closed, true)
  assert.equal(b.audio.srcObject, null)
  assert.equal(b.timers.size, 0)
  const event = new Event("pageshow"); event.persisted = true
  b.win.dispatchEvent(event); await flush()
  assert.equal(b.count().acquisitions, 1)
  assert.equal(b.peers.length, 1)
  assert.equal(b.installed.controller.getState().canEnableMicrophone, false)
  b.installed.dispose()
})


test("negotiated audio publishes a complete initial snapshot under the exact media identity", async () => {
  const b = browser()
  await flush(); b.click(b.start); await flush()
  b.project({state: "connecting"}); await flush()
  const offer = b.commands.find(c => c.event === "offer").payload
  const states = b.commands.filter(c => c.event === "local_media_state")
  assert.deepEqual(states.map(c => c.payload), [{
    call_id: offer.call_id, call_session_id: offer.call_session_id,
    signaling_session_id: offer.signaling_session_id, negotiation_id: offer.negotiation_id,
    media_state_version: 1, microphone_muted: false, camera_enabled: false,
  }])
  assert.equal(b.tracks[0].enabled, true)
  assert.equal(b.peers[0].closed, undefined)
  b.installed.dispose()
})

test("dock mute immediately suppresses capture, survives interruption/navigation and resets on leave", async () => {
  const b = browser()
  await flush(); b.click(b.start); await flush()
  b.project({state: "connecting"}); await flush()
  b.peers[0].ready(); b.project({state: "active"}); await flush()
  const peer = b.peers[0], stream = b.audio.srcObject, receiver = peer.transceivers[0].receiver.track
  assert.equal(b.mute.hidden, false)
  assert.equal(b.mute.getAttribute("aria-label"), "Mute microphone")
  b.click(b.mute)
  assert.equal(b.tracks[0].enabled, false)
  assert.equal(b.mute.getAttribute("aria-pressed"), undefined)
  assert.equal(b.mute.getAttribute("data-active"), "true")
  assert.match(b.nodes.get("direct-call-dock-status").textContent, /Microphone muted/)
  await flush()
  peer.connectionState = "disconnected"; peer.dispatchEvent(new Event("connectionstatechange"))
  b.win.dispatchEvent(new Event("phx:page-loading-stop"))
  assert.equal(b.installed.controller.getState().localMuted, true)
  peer.ready(); await flush()
  b.click(b.mute); await flush()
  assert.equal(b.tracks[0].enabled, true)
  assert.equal(b.mute.getAttribute("aria-label"), "Mute microphone")
  assert.deepEqual(b.commands.filter(c => c.event === "local_media_state").map(c => [c.payload.media_state_version, c.payload.microphone_muted, c.payload.camera_enabled]), [[1, false, false], [2, true, false], [3, false, false]])
  assert.equal(b.commands.filter(c => c.event === "offer").length, 1)
  assert.equal(b.peers.length, 1)
  assert.equal(b.audio.srcObject, stream)
  assert.equal(peer.transceivers[0].receiver.track, receiver)
  b.click(b.mute); b.click(b.leave)
  assert.equal(b.installed.controller.getState().localMuted, false)
  assert.equal(b.mute.hidden, true)
  assert.equal(b.tracks[0].stops, 1)
  await flush(); b.installed.dispose()
})


for (const obsoleteReply of ["accepted", "rejected"]) {
  test(`delayed ${obsoleteReply} snapshots cannot undo mute/deafen or fail newer state`, async () => {
    const replies = []
    const b = browser({mediaReply(payload) {
      const callbacks = {}
      replies.push({payload, callbacks})
      return {receive(status, fn) {callbacks[status] = fn; return this}}
    }})
    await flush(); b.click(b.start); await flush()
    b.project({state: "connecting"}); await flush()
    b.peers[0].ready(); b.project({state: "active"}); await flush()
    b.click(b.mute); b.click(b.deafen); b.click(b.mute)
    assert.equal(b.tracks[0].enabled, false)
    assert.equal(b.audio.muted, true)
    b.click(b.deafen)
    assert.deepEqual(replies.map(r => [r.payload.media_state_version, r.payload.microphone_muted, r.payload.camera_enabled]),
      [[1, false, false], [2, true, false], [3, false, false]])
    replies[2].callbacks.ok(replies[2].payload)
    for (const old of replies.slice(0, 2)) {
      if (obsoleteReply === "accepted") old.callbacks.ok({...old.payload, camera_enabled: true})
      else old.callbacks.error({reason: "stale_media_state"})
    }
    await flush()
    assert.equal(b.tracks[0].enabled, true)
    assert.equal(b.audio.muted, false)
    assert.equal(b.installed.controller.getState().localMuted, false)
    assert.equal(b.installed.controller.getState().localDeafened, false)
    assert.equal(b.peers[0].closed, undefined)
    b.click(b.mute)
    replies[3].callbacks.error({reason: "not_admitted"})
    await flush()
    assert.equal(b.peers[0].closed, true)
    assert.equal(b.tracks[0].stops, 1)
    assert.equal(b.commands.filter(c => c.event === "leave_call").length, 1)
    b.installed.dispose()
  })
}

for (const field of ["microphone_muted", "camera_enabled", "media_state_version", "call_id",
  "call_session_id", "signaling_session_id", "negotiation_id"]) {
  test(`current snapshot acknowledgement requires ${field} before retaining audio`, async () => {
    const b = browser({mediaReply(payload) {
      const incomplete = {...payload}
      delete incomplete[field]
      return {receive(status, fn) {
        if (status === "ok") queueMicrotask(() => fn(incomplete))
        return this
      }}
    }})
    await flush(); b.click(b.start); await flush()
    b.project({state: "connecting"}); await flush()
    assert.equal(b.peers[0].closed, true)
    assert.equal(b.tracks[0].stops, 1)
    assert.equal(b.commands.filter(c => c.event === "leave_call").length, 1)
    b.installed.dispose()
  })
}

test("pending mute replies after leave cannot revive capture or send a second leave", async () => {
  let settle
  const b = browser({mediaReply(payload) {
    return {receive(status, fn) {if (status === "error") settle = fn; return this}}
  }})
  await flush(); b.click(b.start); await flush()
  b.project({state: "connecting"}); await flush()
  b.click(b.mute)
  b.click(b.leave)
  settle({reason: "not_admitted"}); await flush()
  b.click(b.mute)
  assert.equal(b.tracks[0].stops, 1)
  assert.equal(b.installed.controller.getState().localMuted, false)
  assert.equal(b.commands.filter(c => c.event === "leave_call").length, 1)
  assert.equal(b.commands.filter(c => c.event === "local_media_state").length, 2)
  b.installed.dispose()
})


test("mute during a held offer sends only the latest preference after the exact answer", async () => {
  let answer
  const b = browser({offerReply(payload) {
    return {receive(status, fn) {
      if (status === "ok") answer = () => fn({...payload, description: {type: "answer", sdp: "answer"}})
      return this
    }}
  }})
  await flush(); b.click(b.start); await flush()
  b.project({state: "connecting"}); await flush()
  b.click(b.mute)
  assert.equal(b.tracks[0].enabled, false)
  b.click(b.mute); b.click(b.mute)
  assert.equal(b.commands.filter(c => c.event === "local_media_state").length, 0)
  answer(); await flush()
  const states = b.commands.filter(c => c.event === "local_media_state")
  assert.equal(states.length, 1)
  assert.equal(states[0].payload.media_state_version, 3)
  assert.equal(states[0].payload.microphone_muted, true)
  assert.equal(states[0].payload.camera_enabled, false)
  assert.equal(states[0].payload.negotiation_id, "negotiation")
  assert.equal(b.peers.length, 1)
  assert.equal(b.tracks[0].stops, 0)
  b.installed.dispose()
})

test("a mute gesture as the prepared owner becomes eligible reaches the admitted Session", async () => {
  const b = browser()
  await flush(); b.click(b.start); await flush()
  let muted = false
  const unsubscribe = b.installed.controller.subscribe(state => {
    if (state.canMute && !muted) {
      muted = true
      b.click(b.mute)
    }
  })
  b.project({state: "connecting"}); await flush()
  assert.equal(b.tracks[0].enabled, false)
  assert.equal(b.commands.filter(c => c.event === "local_media_state").length, 1)
  unsubscribe(); b.installed.dispose()
})

for (const trigger of ["terminal", "local leave", "resume after unreachable transport"]) {
  test(`responsive client cleanup has its own five-second clock from ${trigger}`, async () => {
    const b = browser()
    await flush(); b.click(b.start); await flush(); b.project({state: "connecting"}); await flush()
    const oldPeer = b.peers[0], oldTrack = b.tracks[0]
    oldPeer.ready(); b.project({state: "active"}); await flush()
    const oldTimers = [...b.timers.values()]
    assert.notEqual(b.audio.srcObject, null)
    if (trigger === "resume after unreachable transport") {
      // No server event or browser callback executes during the simulated freeze.
      // The server's terminal snapshot is observed only after execution resumes.
      b.snapshot({call_id: "call", role: "caller", ownership: "self", state: "terminal",
        terminal_outcome: "interrupted", media_intent: "audio"})
      assert.equal(oldTrack.stops, 0)
    }
    const observedAt = performance.now()
    if (trigger === "terminal") b.project({state: "terminal", terminal_outcome: "interrupted"})
    if (trigger === "local leave") b.click(b.leave)
    if (trigger === "resume after unreachable transport") {
      b.installed.signaling.disconnect(); b.installed.signaling.connect()
    }
    assert.equal(oldTrack.stops, 1)
    assert.equal(oldPeer.closed, true)
    assert.equal(b.audio.srcObject, null)
    assert.equal(b.timers.size, 0)
    assert.ok(performance.now() - observedAt < 5000)
    await flush()
    assert.equal(b.count().acquisitions, 1)
    assert.equal(b.peers.length, 1)
    assert.equal(b.installed.controller.getState().canEnableMicrophone, false)
    const leaves = b.commands.filter(c => c.event === "leave_call").length
    assert.equal(leaves, trigger === "local leave" ? 1 : 0)

    b.click(b.start); await flush(); b.project({state: "connecting"}); await flush()
    b.peers[1].ready(); b.project({state: "active"}); await flush()
    const replacementPlayback = b.audio.srcObject
    for (const callback of oldTimers) callback()
    oldPeer.ready(); oldTrack.end(); await flush()
    assert.equal(b.tracks[1].stops, 0)
    assert.equal(b.peers[1].closed, undefined)
    assert.equal(b.audio.srcObject, replacementPlayback)
    assert.equal(b.commands.filter(c => c.event === "leave_call").length, leaves)
    b.installed.dispose()
  })
}

function ownedAudioTrack() {
  return Object.assign(new EventTarget(), {kind: "audio", readyState: "live", enabled: true, stops: 0,
    stop() {this.stops++; this.readyState = "ended"},
    end() {this.readyState = "ended"; this.dispatchEvent(new Event("ended"))}})
}

test("a rejected answer releases its independent microphone while Voice and a fresh answer survive", async () => {
  const voice = ownedAudioTrack(), rejected = ownedAudioTrack(), replacement = ownedAudioTrack()
  const invitation = {call_id: "call", role: "recipient", state: "ringing", ownership: "unclaimed", media_intent: "audio"}
  let first = true
  const b = browser({role: "recipient", snapshot: invitation,
    permission: async () => {
      const track = first ? rejected : replacement
      return {getTracks: () => [track], getAudioTracks: () => [track]}
    },
    acceptReply() {
      return {receive(status, fn) {
        if (first && status === "error") queueMicrotask(() => fn({reason: "busy"}))
        if (!first && status === "ok") queueMicrotask(() => fn({signaling_session_id: "topic-session",
          call: {...invitation, state: "connecting", ownership: "self"}}))
        return this
      }}
    },
  })
  await flush(); b.click(b.answer); await flush()
  assert.equal(rejected.stops, 1)
  assert.equal(voice.stops, 0)
  assert.equal(b.peers.length, 0)
  assert.equal(b.installed.controller.getState().call.state, "ringing")
  first = false
  b.click(b.answer); await flush()
  b.peers[0].ready(); b.project({state: "active", ownership: "self"}); await flush()
  b.click(b.deafen); b.click(b.deafen)
  rejected.end(); await flush()
  assert.equal(replacement.readyState, "live")
  assert.equal(replacement.stops, 0)
  assert.notEqual(b.audio.srcObject, null)
  assert.equal(b.commands.filter(c => c.event === "leave_call").length, 0)
  replacement.end(); await flush()
  assert.equal(b.commands.filter(c => c.event === "leave_call").length, 1)
  assert.equal(replacement.stops, 1)
  assert.equal(b.audio.srcObject, null)
  b.installed.dispose(); b.installed.dispose()
  assert.equal(rejected.stops, 1)
  assert.equal(replacement.stops, 1)
  assert.equal(voice.readyState, "live")
  assert.equal(voice.stops, 0)
})

for (const capability of [undefined, "false", "true", "1"]) {
  test(`composed video actions follow only the bootstrap capability ${capability}`, async () => {
    const requests = []
    const devices = createFakeCallDevices({nextOutcome(request) {requests.push(request); return {ok: true}}})
    const enabled = capability === "true"
    const caller = browser({devices, videoAvailable: capability})
    await flush()
    const state = caller.installed.controller.getState()
    assert.equal(state.videoAvailable, enabled)
    assert.equal(caller.startVideo.getAttribute("aria-disabled"), enabled ? "false" : "true")
    if (!enabled) {
      assert.equal(caller.startVideo.getAttribute("aria-describedby"), "direct-conversation-video-unavailable-reason")
    }
    caller.click(caller.startVideo)
    await flush()
    assert.deepEqual(requests, enabled ? [{audio: true, video: true}] : [])
    assert.equal(caller.commands.filter(c => c.event === "start_call").length, enabled ? 1 : 0)
    assert.equal(caller.peers.length, 0)
    caller.installed.dispose()

    requests.length = 0
    const recipient = browser({devices, videoAvailable: capability,
      snapshot: {call_id: "call", state: "ringing", role: "recipient", media_intent: "video", ownership: "unclaimed"},
      acceptReply: payload => ({receive(status, fn) {
        if (status === "error") queueMicrotask(() => fn({reason: "stale"}))
        return this
      }}),
    })
    await flush()
    assert.deepEqual(requests, [])
    assert.equal(recipient.acceptVideo.getAttribute("aria-disabled"), enabled ? "false" : "true")
    const explanation = recipient.nodes.get("direct-call-video-unavailable-reason")
    assert.equal(explanation.hidden, enabled)
    recipient.click(recipient.acceptVideo)
    await flush()
    assert.deepEqual(requests, enabled ? [{audio: true, video: true}] : [])
    assert.equal(recipient.commands.filter(c => c.event === "accept_call").length, enabled ? 1 : 0)
    assert.equal(recipient.peers.length, 0)
    recipient.installed.dispose()
  })
}

test("controlled availability never acquires devices for ringing or sibling observation and audio still requests no camera", async () => {
  const requests = []
  const devices = createFakeCallDevices({nextOutcome(request) {requests.push(request); return {ok: true}}})
  const observer = browser({devices, videoAvailable: "true",
    snapshot: {call_id: "observed", role: "recipient", state: "connecting", media_intent: "video", ownership: "elsewhere"},
  })
  await flush()
  observer.click(observer.acceptVideo)
  await flush()
  assert.deepEqual(requests, [])
  assert.equal(observer.peers.length, 0)
  assert.equal(observer.commands.filter(c => c.event === "accept_call" || c.event === "media_credentials").length, 0)
  observer.installed.dispose()

  const caller = browser({devices, videoAvailable: "true"})
  await flush()
  caller.click(caller.start)
  await flush()
  assert.deepEqual(requests, [{audio: true, video: false}])
  const start = caller.commands.find(c => c.event === "start_call")
  assert.equal(start.payload.media_intent, "audio")
  caller.installed.dispose()
})


test("controlled caller video previews its owned camera while ringing without media or recipient capture", async () => {
  const {track: voice, controller: voiceController} = await capturedVoice()
  const caller = browser({videoAvailable: "true"})
  await flush(); caller.click(caller.startVideo); await flush()
  assert.equal(caller.requests.length, 2)
  assert.deepEqual(caller.requests[0], {audio: true, video: false})
  assert.equal(caller.requests[1].audio, false)
  assert.equal(caller.commands.find(c => c.event === "start_call").payload.media_intent, "video")
  assert.equal(caller.installed.controller.getState().presentation, "outgoing_ringing")
  assert.equal(caller.installed.controller.getState().mediaIntent, "video")
  assert.deepEqual(caller.preview.srcObject.tracks, [caller.tracks[1]])
  assert.equal(caller.preview.muted, true)
  assert.equal(caller.preview.playsInline, true)
  assert.equal(caller.preview.autoplay, true)
  assert.equal(caller.peers.length, 0)
  const recipient = browser({role: "recipient", videoAvailable: "true", snapshot: {
    call_id: "call", role: "recipient", state: "ringing", ownership: "unclaimed", media_intent: "video",
  }})
  await flush()
  assert.equal(recipient.count().acquisitions, 0)
  assert.equal(recipient.peers.length, 0)
  assert.equal(recipient.preview.srcObject, null)
  caller.installed.controller.cancelCall()
  assert.equal(caller.preview.srcObject, null)
  assert.deepEqual(caller.tracks.map(t => t.stops), [1, 1])
  assert.equal(voice.stops, 0)
  caller.installed.dispose(); recipient.installed.dispose()
  assert.equal(voiceController.state().status, "capturing")
  voiceController.teardown()
})


test("an ended camera at the final start preflight creates no invitation or silent audio fallback", async () => {
  const b = browser({videoAvailable: "true"})
  let stream
  Object.defineProperty(b.preview, "srcObject", {
    get: () => stream,
    set(value) {stream = value; value?.tracks[0].end()},
  })
  await flush(); b.click(b.startVideo); await flush()
  assert.equal(b.commands.filter(c => c.event === "start_call").length, 0)
  assert.equal(b.installed.controller.getState().canFallbackToAudio, true)
  assert.equal(b.preview.srcObject, null)
  assert.deepEqual(b.tracks.map(t => t.stops), [0, 1])
  b.installed.controller.dismiss()
  assert.equal(b.tracks[0].stops, 1)
  b.installed.dispose()
})

// Hold only the Phoenix wire reply; the composed application remains real.
function heldCommandReply() {
  const callbacks = new Map()
  return {
    receive(status, callback) {callbacks.set(status, callback); return this},
    settle(status, value) {callbacks.get(status)?.(value)},
  }
}

for (const role of ["caller", "recipient"]) {
  test(`${role} retains live audio when camera loss and wire timeout precede the committed projection`, async t => {
    const reply = heldCommandReply()
    const invitation = {call_id: "call", role, ownership: role === "caller" ? "self" : "unclaimed",
      state: "ringing", media_intent: "video", ringing_deadline_at: new Date(Date.now() + 60_000).toISOString()}
    const b = browser({role, videoAvailable: "true", ...(role === "caller" ? {startReply: () => reply} :
      {snapshot: invitation, acceptReply: () => reply})})
    t.after(() => b.installed.dispose())
    await flush(); b.click(role === "caller" ? b.startVideo : b.acceptVideo); await flush()
    const [microphone, camera] = b.tracks
    camera.end()
    reply.settle("timeout"); await flush()
    assert.equal(microphone.stops, 0)
    assert.equal(b.installed.controller.getState().microphoneReady, true)
    assert.equal(b.preview.srcObject, null)
    const statusId = role === "caller" ? "direct-call-dock-status" : "direct-call-incoming-status"
    assert.match(b.nodes.get(statusId).textContent, /confirm/i)
    assert.equal(b.installed.controller.getState().canFallbackToAudio, false)
    assert.equal(b.installed.controller.getState().canAnswerWithoutVideo, false)
    if (role === "caller") b.incoming(invitation)
    else b.project({state: "connecting", ownership: "self", answer_mode: "video"})
    await flush()
    if (role === "caller") b.project({state: "connecting", answer_mode: "video"})
    await flush()
    b.peers[0].ready(); b.project({state: "active"}); await flush()
    assert.equal(b.peers[0].transceivers[0].sender.track, microphone)
    assert.equal(b.peers[0].transceivers[1].sender.track, null)
    assert.equal(b.installed.controller.getState().call.media_intent, "video")
    assert.equal(b.installed.controller.getState().call.answer_mode, "video")
    assert.equal(b.commands.filter(c => ["start_call", "accept_call"].includes(c.event)).length, 1)
    assert.equal(b.commands.filter(c => ["cancel_call", "leave_call"].includes(c.event)).length, 0)
    b.installed.dispose()
    assert.deepEqual(b.tracks.map(track => track.stops), [1, 1])
  })
}

test("a caller camera-only retry retains its reused microphone across unconfirmed start and projection", async t => {
  const reply = heldCommandReply()
  const b = browser({videoAvailable: "true", startReply: () => reply})
  t.after(() => b.installed.dispose())
  let stream, first = true
  Object.defineProperty(b.preview, "srcObject", {
    get: () => stream,
    set(value) {stream = value; if (value && first) {first = false; value.tracks[0].end()}},
  })
  await flush(); b.click(b.startVideo); await flush()
  assert.equal(b.installed.controller.getState().canFallbackToAudio, true)
  b.click(b.nodes.get("direct-call-dock-retry")); await flush()
  b.tracks[2].end(); reply.settle("timeout"); await flush()
  b.incoming({call_id: "call", role: "caller", ownership: "self", state: "ringing", media_intent: "video"})
  await flush(); b.project({state: "connecting", answer_mode: "video"}); await flush()
  assert.equal(b.tracks[0].stops, 0)
  assert.equal(b.peers[0].transceivers[0].sender.track, b.tracks[0])
  assert.equal(b.peers[0].transceivers[1].sender.track, null)
  assert.deepEqual(b.tracks.map(track => track.stops), [0, 1, 1])
  assert.equal(b.requests.length, 3)
  assert.equal(b.commands.filter(c => c.event === "start_call").length, 1)
})

test("a committed video invitation survives a timed-out start reply after camera loss", async t => {
  const reply = heldCommandReply()
  const b = browser({videoAvailable: "true", startReply: () => reply})
  t.after(() => b.installed.dispose())
  await flush(); b.click(b.startVideo); await flush()
  const [microphone, camera] = b.tracks
  camera.end()
  const committed = {call_id: "call", role: "caller", ownership: "self", state: "ringing",
    media_intent: "video", ringing_deadline_at: new Date(Date.now() + 60_000).toISOString()}
  b.incoming(committed); await flush()
  reply.settle("timeout"); await flush()
  assert.equal(b.installed.controller.getState().presentation, "outgoing_ringing")
  assert.equal(b.installed.controller.getState().microphoneReady, true)
  assert.equal(microphone.stops, 0)
  assert.equal(camera.stops, 1)
  b.project({state: "connecting", answer_mode: "video"}); await flush()
  assert.equal(b.peers[0].transceivers[0].sender.track, microphone)
  assert.equal(b.peers[0].transceivers[1].sender.track, null)
  assert.equal(b.commands.filter(c => ["cancel_call", "leave_call"].includes(c.event)).length, 0)
})

for (const role of ["caller", "recipient"]) {
  for (const order of ["reply first", "projection first"]) {
    test(`${role} camera loss preserves committed video choices and audio with ${order}`, async t => {
      const reply = heldCommandReply()
      const invitation = {call_id: "call", role, ownership: role === "caller" ? "self" : "unclaimed",
        state: "ringing", media_intent: "video", ringing_deadline_at: new Date(Date.now() + 60_000).toISOString()}
      const committed = role === "caller" ? invitation :
        {...invitation, ownership: "self", state: "connecting", answer_mode: "video"}
      const b = browser({role, videoAvailable: "true", ...(role === "caller" ? {startReply: () => reply} :
        {snapshot: invitation, acceptReply: () => reply})})
      t.after(() => b.installed.dispose())
      await flush(); b.click(role === "caller" ? b.startVideo : b.acceptVideo); await flush()
      const [microphone, camera] = b.tracks
      camera.end()
      assert.equal(b.preview.srcObject, null)
      assert.deepEqual(b.tracks.map(track => track.stops), [0, 1])
      const project = () => role === "caller" ? b.incoming(committed) : b.project(committed)
      if (order === "projection first") {project(); await flush()}
      b.snapshot(committed)
      reply.settle("ok", {signaling_session_id: role === "caller" ? "inbox-session" : "topic-session", call: committed})
      await flush()
      if (order === "reply first") {project(); await flush()}
      assert.equal(b.installed.controller.getState().call.media_intent, "video")
      assert.equal(b.installed.controller.getState().call.ringing_deadline_at, invitation.ringing_deadline_at)
      if (role === "caller") {b.project({state: "connecting", answer_mode: "video"}); await flush()}
      b.peers[0].ready(); b.project({state: "active"}); await flush()
      assert.equal(b.peers[0].transceivers[0].sender.track, microphone)
      assert.equal(b.peers[0].transceivers[1].sender.track, null)
      assert.equal(b.installed.controller.getState().call.answer_mode, "video")
      assert.equal(b.installed.controller.getState().cameraState, "off")
      b.click(b.deafen); b.click(b.deafen); b.click(b.mute); await flush()
      assert.equal(microphone.enabled, false)
      assert.equal(microphone.stops, 0)
      assert.equal(b.commands.filter(c => ["start_call", "accept_call"].includes(c.event)).length, 1)
      assert.equal(b.commands.filter(c => ["cancel_call", "leave_call"].includes(c.event)).length, 0)
      b.click(b.leave); await flush()
      assert.deepEqual(b.tracks.map(track => track.stops), [1, 1])
      assert.equal(b.peers[0].closed, true)
    })
  }

  test(`${role} definitive video rejection after camera loss releases preparation and waits for an explicit action`, async t => {
    const reply = heldCommandReply()
    const invitation = {call_id: "call", role, ownership: "unclaimed", state: "ringing", media_intent: "video",
      ringing_deadline_at: new Date(Date.now() + 60_000).toISOString()}
    let rejected = false
    const b = browser({role, videoAvailable: "true", ...(role === "caller" ? {startReply: payload => {
      if (!rejected) return reply
      return {receive(status, fn) {
        if (status === "ok") queueMicrotask(() => fn({signaling_session_id: "inbox-session",
          call: {...invitation, call_id: "fresh", ownership: "self", media_intent: payload.media_intent}}))
        return this
      }}
    }} : {snapshot: invitation, acceptReply: payload => {
      if (!rejected) return reply
      return {receive(status, fn) {
        if (status === "ok") queueMicrotask(() => fn({signaling_session_id: "topic-session",
          call: {...invitation, ownership: "self", state: "connecting", answer_mode: payload.answer_mode}}))
        return this
      }}
    }})})
    t.after(() => b.installed.dispose())
    await flush(); b.click(role === "caller" ? b.startVideo : b.acceptVideo); await flush()
    b.tracks[1].end(); rejected = true
    reply.settle("error", {reason: "busy"}); await flush()
    assert.deepEqual(b.tracks.map(track => track.stops), [1, 1])
    assert.equal(b.preview.srcObject, null)
    assert.equal(b.peers.length, 0)
    assert.equal(b.requests.length, 2)
    assert.equal(b.commands.filter(c => ["start_call", "accept_call"].includes(c.event)).length, 1)
    assert.equal(b.installed.controller.getState().presentation, role === "caller" ? "result" : "incoming_ringing")
    b.click(role === "caller" ? b.start : b.nodes.get("direct-call-incoming-answer-without-video")); await flush()
    assert.equal(b.requests.length, 3)
    assert.equal(b.requests[2].video, false)
    const commands = b.commands.filter(c => ["start_call", "accept_call"].includes(c.event))
    assert.equal(commands.length, 2)
    assert.equal(role === "caller" ? commands[1].payload.media_intent : commands[1].payload.answer_mode, "audio")
    assert.equal(b.tracks[2].stops, 0)
    if (role === "recipient") assert.equal(b.installed.controller.getState().call.media_intent, "video")
  })

  test(`${role} original invitation expiry releases pending video work and ignores late commitment`, async t => {
    const reply = heldCommandReply()
    const invitation = {call_id: "call", role, ownership: role === "caller" ? "self" : "unclaimed",
      state: "ringing", media_intent: "video", ringing_deadline_at: new Date(Date.now() + 60_000).toISOString()}
    const b = browser({role, videoAvailable: "true", ...(role === "caller" ? {startReply: () => reply} :
      {snapshot: invitation, acceptReply: () => reply})})
    t.after(() => b.installed.dispose())
    await flush(); b.click(role === "caller" ? b.startVideo : b.acceptVideo); await flush()
    b.tracks[1].end()
    if (role === "caller") {b.incoming(invitation); await flush()}
    b.project({state: "terminal", terminal_outcome: "timed_out"}); await flush()
    reply.settle("ok", {signaling_session_id: role === "caller" ? "inbox-session" : "topic-session",
      call: {...invitation, ownership: "self", ...(role === "recipient" ? {state: "connecting", answer_mode: "video"} : {})}})
    await flush()
    assert.deepEqual(b.tracks.map(track => track.stops), [1, 1])
    assert.equal(b.preview.srcObject, null)
    assert.equal(b.installed.controller.getState().call, null)
    assert.equal(b.peers.length, 0)
    assert.equal(b.requests.length, 2)
    assert.equal(b.commands.filter(c => ["cancel_call", "leave_call"].includes(c.event)).length, 0)
  })
}

for (const role of ["caller", "recipient"]) {
  for (const invalidation of ["another owner", "replacement Call"]) {
    test(`${role} late video command after camera loss cannot replace ${invalidation}`, async t => {
      const reply = heldCommandReply()
      const invitation = {call_id: "call", role, ownership: role === "caller" ? "self" : "unclaimed",
        state: "ringing", media_intent: "video"}
      const committed = {...invitation, ownership: "self", ...(role === "recipient" ?
        {state: "connecting", answer_mode: "video"} : {})}
      const b = browser({role, videoAvailable: "true", ...(role === "caller" ? {startReply: () => reply} :
        {snapshot: invitation, acceptReply: () => reply})})
      t.after(() => b.installed.dispose())
      await flush(); b.click(role === "caller" ? b.startVideo : b.acceptVideo); await flush()
      b.tracks[1].end()
      const current = {...invitation, ownership: "elsewhere", state: "connecting", answer_mode: "audio",
        ...(invalidation === "replacement Call" ? {call_id: "replacement", role: "recipient"} : {})}
      if (invalidation === "replacement Call" || role === "caller") b.incoming(current)
      else b.project(current)
      await flush()
      assert.deepEqual(b.tracks.map(track => track.stops), [1, 1])
      reply.settle("ok", {signaling_session_id: role === "caller" ? "inbox-session" : "topic-session", call: committed})
      await flush()
      assert.equal(b.installed.controller.getState().call.call_id, current.call_id)
      assert.equal(b.installed.controller.getState().call.ownership, "elsewhere")
      assert.equal(b.installed.controller.getState().call.answer_mode, "audio")
      assert.equal(b.installed.controller.getState().presentation, "owned_elsewhere")
      assert.equal(b.installed.controller.getState().canEnableMicrophone, false)
      assert.equal(b.preview.srcObject, null)
      assert.equal(b.peers.length, 0)
      assert.equal(b.requests.length, 2)
      assert.equal(b.commands.filter(c => ["cancel_call", "leave_call", "media_credentials"].includes(c.event)).length, 0)
    })
  }
}

for (const role of ["caller", "recipient"]) {
  for (const timeoutFirst of [false, true]) {
    test(`${role} microphone loss after camera loss remains terminal ${timeoutFirst ? "after timeout" : "with reply held"}`, async t => {
      const reply = heldCommandReply()
      const invitation = {call_id: "call", role, ownership: role === "caller" ? "self" : "unclaimed",
        state: "ringing", media_intent: "video"}
      const committed = {...invitation, ownership: "self", state: "connecting", answer_mode: "video"}
      const b = browser({role, videoAvailable: "true", ...(role === "caller" ? {startReply: () => reply} :
        {snapshot: invitation, acceptReply: () => reply})})
      t.after(() => b.installed.dispose())
      await flush(); b.click(role === "caller" ? b.startVideo : b.acceptVideo); await flush()
      b.tracks[1].end()
      if (timeoutFirst) {reply.settle("timeout"); await flush()}
      b.tracks[0].end()
      if (role === "caller") b.incoming(committed)
      else b.project(committed)
      await flush()
      if (!timeoutFirst) {
        reply.settle("ok", {signaling_session_id: role === "caller" ? "inbox-session" : "topic-session", call: committed})
        await flush()
      }
      assert.equal(b.commands.filter(c => c.event === "leave_call").length, 1)
      assert.deepEqual(b.tracks.map(track => track.stops), [1, 1])
      assert.equal(b.peers.length, 0)
      assert.equal(b.preview.srcObject, null)
      assert.equal(b.requests.length, 2)
    })
  }

  test(`${role} explicit ${role === "caller" ? "Cancel" : "Decline"} remains authoritative while the video reply is held`, async t => {
    const reply = heldCommandReply()
    const invitation = {call_id: "call", role, ownership: role === "caller" ? "self" : "unclaimed",
      state: "ringing", media_intent: "video"}
    const b = browser({role, videoAvailable: "true", ...(role === "caller" ? {startReply: () => reply} :
      {snapshot: invitation, acceptReply: () => reply})})
    t.after(() => b.installed.dispose())
    await flush(); b.click(role === "caller" ? b.startVideo : b.acceptVideo); await flush()
    b.tracks[1].end()
    if (role === "caller") {
      reply.settle("timeout"); await flush()
      b.click(b.nodes.get("direct-call-dock-cancel"))
      b.incoming(invitation); await flush()
    } else {
      b.click(b.nodes.get("direct-call-incoming-decline")); await flush()
      b.project({state: "terminal", terminal_outcome: "declined"}); await flush()
      reply.settle("ok", {signaling_session_id: "topic-session",
        call: {...invitation, state: "connecting", ownership: "self", answer_mode: "video"}})
      await flush()
    }
    assert.equal(b.commands.filter(c => c.event === (role === "caller" ? "cancel_call" : "decline_call")).length, 1)
    assert.deepEqual(b.tracks.map(track => track.stops), [1, 1])
    assert.equal(b.preview.srcObject, null)
    assert.equal(b.peers.length, 0)
    assert.equal(b.requests.length, 2)
  })

  test(`${role} socket loss releases unconfirmed video preparation and cannot replay its late reply`, async t => {
    const reply = heldCommandReply()
    const invitation = {call_id: "call", role, ownership: "unclaimed", state: "ringing", media_intent: "video"}
    const b = browser({role, videoAvailable: "true", ...(role === "caller" ? {startReply: () => reply} :
      {snapshot: invitation, acceptReply: () => reply})})
    t.after(() => b.installed.dispose())
    await flush(); b.click(role === "caller" ? b.startVideo : b.acceptVideo); await flush()
    b.tracks[1].end(); reply.settle("timeout"); await flush()
    b.loseSocket(); await flush()
    reply.settle("ok", {signaling_session_id: role === "caller" ? "inbox-session" : "topic-session",
      call: {...invitation, state: "connecting", ownership: "self", answer_mode: "video"}})
    await flush()
    assert.deepEqual(b.tracks.map(track => track.stops), [1, 1])
    assert.equal(b.installed.controller.getState().microphoneReady, false)
    assert.equal(b.preview.srcObject, null)
    assert.equal(b.peers.length, 0)
    assert.equal(b.requests.length, 2)
    assert.equal(b.commands.filter(c => ["start_call", "accept_call"].includes(c.event)).length, 1)
    assert.equal(b.commands.filter(c => c.event === "leave_call").length, 0)
  })
}

for (const projectionFirst of [false, true]) {
  test(`recipient Decline after camera loss retires acceptance when ${projectionFirst ? "projection" : "reply"} arrives first`, async t => {
    const accept = heldCommandReply(), decline = heldCommandReply()
    const invitation = videoInvitation()
    const b = browser({role: "recipient", snapshot: invitation, videoAvailable: "true",
      acceptReply: () => accept, declineReply: () => decline})
    t.after(() => b.installed.dispose())
    await flush(); b.click(b.acceptVideo); await flush()
    b.tracks[1].end()
    b.click(b.nodes.get("direct-call-incoming-decline")); await flush()
    const committed = {...invitation, ownership: "self", state: "connecting", answer_mode: "video"}
    if (projectionFirst) {b.project(committed); await flush()}
    if (!projectionFirst) b.snapshot(committed)
    accept.settle("ok", {signaling_session_id: "topic-session", call: committed}); await flush()
    if (!projectionFirst) {b.project(committed); await flush()}
    decline.settle("error", {reason: "stale"}); await flush()
    assert.equal(b.commands.filter(c => c.event === "leave_call").length, 1)
    assert.equal(b.commands.filter(c => c.event === "decline_call").length, 1)
    assert.deepEqual(b.tracks.map(track => track.stops), [1, 1])
    assert.equal(b.installed.controller.getState().call, null)
    assert.equal(b.peers.length, 0)
    assert.equal(b.preview.srcObject, null)
    assert.equal(b.requests.length, 2)
  })
}

for (const projectionFirst of [false, true]) {
  test(`caller Cancel after camera loss retires the Call when ${projectionFirst ? "active projection" : "stale reply"} arrives first`, async t => {
    const start = heldCommandReply(), cancel = heldCommandReply()
    const b = browser({videoAvailable: "true", startReply: () => start, cancelReply: () => cancel})
    t.after(() => b.installed.dispose())
    await flush(); b.click(b.startVideo); await flush()
    b.tracks[1].end()
    const invitation = {call_id: "call", role: "caller", ownership: "self", state: "ringing", media_intent: "video"}
    b.incoming(invitation); await flush()
    b.click(b.nodes.get("direct-call-dock-cancel")); await flush()
    if (projectionFirst) {b.project({state: "active", answer_mode: "video"}); await flush()}
    cancel.settle("error", {reason: "stale"}); await flush()
    if (!projectionFirst) {b.project({state: "active", answer_mode: "video"}); await flush()}
    start.settle("ok", {signaling_session_id: "inbox-session", call: invitation}); await flush()
    assert.equal(b.commands.filter(c => c.event === "cancel_call").length, 1)
    assert.equal(b.commands.filter(c => c.event === "leave_call").length, 1)
    assert.deepEqual(b.tracks.map(track => track.stops), [1, 1])
    assert.equal(b.installed.controller.getState().call, null)
    assert.equal(b.peers.length, 0)
    assert.equal(b.preview.srcObject, null)
    assert.equal(b.requests.length, 2)
  })
}

for (const role of ["caller", "recipient"]) {
  for (const invalidation of ["another owner", "replacement Call", "transport loss", "terminal Call"]) {
    test(`${role} exit after camera loss cannot leave ${invalidation} when the old command settles`, async t => {
      const command = heldCommandReply(), exit = heldCommandReply()
      const invitation = {call_id: "call", role, ownership: role === "caller" ? "self" : "unclaimed",
        state: "ringing", media_intent: "video"}
      const b = browser({role, videoAvailable: "true", ...(role === "caller" ?
        {startReply: () => command, cancelReply: () => exit} :
        {snapshot: invitation, acceptReply: () => command, declineReply: () => exit})})
      t.after(() => b.installed.dispose())
      await flush(); b.click(role === "caller" ? b.startVideo : b.acceptVideo); await flush()
      b.tracks[1].end()
      if (role === "caller") {b.incoming(invitation); await flush()}
      b.click(b.nodes.get(role === "caller" ? "direct-call-dock-cancel" : "direct-call-incoming-decline")); await flush()
      let current
      if (invalidation === "another owner") {
        current = {...invitation, state: "connecting", ownership: "elsewhere", answer_mode: "audio"}
        b.project(current)
      } else if (invalidation === "replacement Call") {
        current = {...invitation, call_id: "replacement", role: "recipient", ownership: "unclaimed"}
        b.incoming(current)
      } else if (invalidation === "transport loss") b.loseSocket()
      else b.project({state: "terminal", terminal_outcome: "cancelled"})
      await flush()
      command.settle("ok", {signaling_session_id: role === "caller" ? "inbox-session" : "topic-session",
        call: {...invitation, state: "connecting", ownership: "self", answer_mode: "video"}})
      exit.settle("error", {reason: "stale"}); await flush()
      assert.equal(b.commands.filter(c => c.event === "leave_call").length, 0)
      assert.equal(b.commands.filter(c => c.event === (role === "caller" ? "cancel_call" : "decline_call")).length, 1)
      assert.deepEqual(b.tracks.map(track => track.stops), [1, 1])
      assert.equal(b.preview.srcObject, null)
      assert.equal(b.peers.length, 0)
      assert.equal(b.requests.length, 2)
      if (current) {
        assert.equal(b.installed.controller.getState().call.call_id, current.call_id)
        assert.equal(b.installed.controller.getState().call.ownership, current.ownership)
      } else assert.equal(b.installed.controller.getState().call, null)
    })
  }
}

test("camera source end while video start replies preserves the committed intent and live microphone", async () => {
  let commit
  const b = browser({videoAvailable: "true", startReply: () => ({receive(status, fn) {
    if (status === "ok") commit = () => fn({signaling_session_id: "inbox-session", call: {
      call_id: "call", role: "caller", ownership: "self", state: "ringing", media_intent: "video",
    }})
    return this
  }})})
  await flush(); b.click(b.startVideo); await flush()
  b.tracks[1].end()
  assert.equal(b.preview.srcObject, null)
  assert.equal(b.tracks[1].stops, 1)
  assert.equal(b.tracks[0].stops, 0)
  commit(); await flush()
  assert.equal(b.installed.controller.getState().presentation, "outgoing_ringing")
  assert.equal(b.installed.controller.getState().mediaIntent, "video")
  assert.equal(b.installed.controller.getState().cameraState, "off")
  assert.equal(b.commands.filter(c => c.event === "start_call").length, 1)
  assert.equal(b.commands.filter(c => c.event === "cancel_call").length, 0)
  b.installed.dispose()
})


for (const failure of ["microphone", "camera", "rejected"]) {
  test(`controlled video ${failure} failure creates no invitation and releases only owned work`, async () => {
    const {track: voice, controller: voiceController} = await capturedVoice()
    const microphone = ownedAudioTrack()
    const camera = Object.assign(ownedAudioTrack(), {kind: "video", getSettings: () => ({width: 960, height: 540, frameRate: 24})})
    const b = browser({videoAvailable: "true", permission: async request => {
      if ((failure === "microphone" && request.audio) || (failure === "camera" && !request.audio)) throw {name: "NotAllowedError"}
      const track = request.audio ? microphone : camera
      return {getTracks: () => [track], getAudioTracks: () => request.audio ? [track] : [],
        getVideoTracks: () => request.audio ? [] : [track]}
    }, ...(failure === "rejected" ? {startReply: () => ({receive(status, fn) {
      if (status === "error") queueMicrotask(() => fn({reason: "busy"}))
      return this
    }})} : {})})
    await flush(); b.click(b.startVideo); await flush()
    assert.equal(b.commands.filter(c => c.event === "start_call").length, failure === "rejected" ? 1 : 0)
    assert.equal(b.installed.controller.getState().presentation, "result")
    assert.equal(b.peers.length, 0)
    assert.equal(b.preview.srcObject, null)
    if (failure === "camera") {
      assert.equal(microphone.stops, 0)
      assert.equal(b.installed.controller.getState().microphoneReady, true)
      assert.match(b.nodes.get("direct-call-dock-status").textContent, /Microphone ready/)
      b.installed.controller.cancelCall()
    }
    assert.equal(microphone.stops, failure === "microphone" ? 0 : 1)
    assert.equal(camera.stops, failure === "rejected" ? 1 : 0)
    assert.equal(voice.stops, 0)
    b.installed.dispose()
    assert.equal(voiceController.state().status, "capturing")
    voiceController.teardown()
  })
}

test("committed ringing camera end clears preview without cancelling the video invitation or stopping microphone", async () => {
  const b = browser({videoAvailable: "true"})
  await flush(); b.click(b.startVideo); await flush()
  b.tracks[1].end()
  assert.equal(b.preview.srcObject, null)
  assert.equal(b.installed.controller.getState().call.media_intent, "video")
  assert.equal(b.tracks[0].stops, 0)
  assert.equal(b.tracks[1].stops, 1)
  assert.equal(b.commands.filter(c => c.event === "cancel_call" || c.event === "leave_call").length, 0)
  b.installed.dispose()
})

test("preview play rejection has local retry and obsolete rejection cannot overwrite new preview", async () => {
  let rejectOld, fail = true
  const b = browser({videoAvailable: "true", previewPlay: () => fail ? Promise.reject(new Error("blocked")) :
    new Promise((_, reject) => {rejectOld = reject})})
  await flush(); b.click(b.startVideo); await flush()
  const retry = b.nodes.get("direct-call-local-preview-retry")
  assert.equal(retry.hidden, false)
  assert.equal(b.tracks[0].stops, 0)
  assert.equal(b.tracks[1].stops, 0)
  fail = false
  b.click(retry); await flush()
  assert.equal(b.requests.length, 2)
  assert.equal(retry.hidden, true)
  b.installed.controller.cancelCall()
  rejectOld(new Error("late")); await flush()
  assert.equal(retry.hidden, true)
  assert.equal(b.preview.srcObject, null)
  assert.equal(b.nodes.get("direct-call-local-preview-region").hidden, true)
  assert.equal(b.commands.filter(c => c.event === "leave_call").length, 0)
  b.installed.dispose()
})


test("cancelled caller camera permission releases its microphone and every late camera without invitation", async () => {
  let grantCamera
  const {track: voice, controller: voiceController} = await capturedVoice()
  const microphone = ownedAudioTrack(), camera = Object.assign(ownedAudioTrack(), {
    kind: "video", getSettings: () => ({width: 960, height: 540, frameRate: 24}),
  })
  const b = browser({videoAvailable: "true", permission: request => request.audio ?
    Promise.resolve({getTracks: () => [microphone], getAudioTracks: () => [microphone]}) :
    new Promise(r => {grantCamera = r})})
  await flush(); b.click(b.startVideo); await flush()
  assert.equal(b.installed.controller.getState().presentation, "preflighting")
  b.installed.controller.cancelCall()
  assert.equal(microphone.stops, 1)
  grantCamera({getTracks: () => [camera], getVideoTracks: () => [camera]})
  await flush()
  assert.equal(camera.stops, 1)
  assert.equal(b.commands.filter(c => c.event === "start_call").length, 0)
  assert.equal(b.preview.srcObject, null)
  assert.equal(voice.stops, 0)
  b.installed.dispose()
  assert.equal(voiceController.state().status, "capturing")
  voiceController.teardown()
})


async function capturedVoice() {
  const track = ownedAudioTrack()
  const controller = createVoiceController({secureContext: true, tabCoordination: null,
    mediaDevices: {getUserMedia: async () => ({getAudioTracks: () => [track]})},
  })
  await controller.join({id: "voice", name: "Voice", workspaceId: "workspace"})
  assert.equal(controller.state().status, "capturing")
  return {track, controller}
}


test("explicit caller audio fallback reuses ready microphone and creates only an audio invitation", async () => {
  const {track: voice, controller: voiceController} = await capturedVoice()
  const microphone = ownedAudioTrack()
  const b = browser({videoAvailable: "true", permission: async request => {
    if (!request.audio) throw {name: "NotAllowedError"}
    return {getTracks: () => [microphone], getAudioTracks: () => [microphone]}
  }})
  await flush(); b.click(b.startVideo); await flush()
  const fallback = b.nodes.get("direct-call-dock-start-voice-instead")
  assert.equal(fallback.hidden, false)
  assert.match(b.nodes.get("direct-call-dock-status").textContent, /Microphone ready/)
  assert.equal(b.commands.filter(c => c.event === "start_call").length, 0)
  b.click(fallback); await flush()
  assert.deepEqual(b.requests.map(r => Boolean(r.audio)), [true, false])
  assert.deepEqual(b.commands.filter(c => c.event === "start_call").map(c => c.payload.media_intent), ["audio"])
  assert.equal(b.installed.controller.getState().mediaIntent, "audio")
  assert.equal(microphone.stops, 0)
  assert.equal(b.preview.srcObject, null)
  b.click(b.nodes.get("direct-call-dock-cancel"))
  assert.equal(microphone.stops, 1)
  assert.equal(voice.stops, 0)
  b.installed.dispose(); voiceController.teardown()
})

test("deliberate camera retry uses a fresh camera only while its ready microphone stays owned", async () => {
  const microphone = ownedAudioTrack()
  const camera = Object.assign(ownedAudioTrack(), {kind: "video", getSettings: () => ({width: 640, height: 360, frameRate: 15})})
  let cameras = 0
  const b = browser({videoAvailable: "true", permission: async request => {
    if (!request.audio && ++cameras === 1) throw {name: "NotAllowedError"}
    const track = request.audio ? microphone : camera
    return {getTracks: () => [track], getAudioTracks: () => request.audio ? [track] : [],
      getVideoTracks: () => request.audio ? [] : [track]}
  }})
  await flush(); b.click(b.startVideo); await flush()
  b.click(b.nodes.get("direct-call-dock-retry")); await flush()
  assert.deepEqual(b.requests.map(r => Boolean(r.audio)), [true, false, false])
  assert.deepEqual(b.commands.filter(c => c.event === "start_call").map(c => c.payload.media_intent), ["video"])
  assert.deepEqual(b.preview.srcObject.tracks, [camera])
  assert.equal(microphone.stops, 0)
  b.installed.dispose()
  assert.deepEqual([microphone.stops, camera.stops], [1, 1])
})

for (const exit of ["cancel", "dismiss", "replacement", "socket-loss", "microphone-end", "pagehide"]) {
  test(`retained caller microphone releases exactly on ${exit} and Voice remains intact`, async () => {
    const {track: voice, controller: voiceController} = await capturedVoice()
    const microphone = ownedAudioTrack()
    const b = browser({videoAvailable: "true", permission: async request => {
      if (!request.audio) throw {name: "NotFoundError"}
      return {getTracks: () => [microphone], getAudioTracks: () => [microphone]}
    }})
    await flush(); b.click(b.startVideo); await flush()
    assert.equal(microphone.stops, 0)
    if (exit === "replacement") b.click(b.start)
    else if (exit === "socket-loss") b.loseSocket()
    else if (exit === "microphone-end") microphone.end()
    else if (exit === "pagehide") b.win.dispatchEvent(new Event("pagehide"))
    else b.click(b.nodes.get(`direct-call-dock-${exit}`))
    assert.equal(microphone.stops, 1)
    assert.equal(b.installed.controller.getState().microphoneReady, false)
    assert.equal(b.installed.controller.getState().canFallbackToAudio, false)
    assert.equal(voice.stops, 0)
    b.installed.dispose(); await flush()
    assert.equal(voiceController.state().status, "capturing")
    voiceController.teardown()
  })
}

for (const error of ["busy", "rate_limited", "not_friends", "unavailable"]) {
  test(`audio fallback rejected with ${error} releases retained capture without video or new permission`, async () => {
    const b = browser({videoAvailable: "true", permission: async request => {
      if (!request.audio) throw {name: "NotFoundError"}
      const track = ownedAudioTrack(); b.tracks.push(track)
      return {getTracks: () => [track], getAudioTracks: () => [track]}
    }, startReply: () => ({receive(status, fn) {
      if (status === "error") queueMicrotask(() => fn({reason: error}))
      return this
    }})})
    await flush(); b.click(b.startVideo); await flush()
    b.click(b.nodes.get("direct-call-dock-start-voice-instead")); await flush()
    assert.equal(b.requests.length, 2)
    assert.deepEqual(b.commands.filter(c => c.event === "start_call").map(c => c.payload.media_intent), ["audio"])
    assert.equal(b.tracks[0].stops, 1)
    assert.equal(b.installed.controller.getState().microphoneReady, false)
    assert.equal(b.installed.controller.getState().mediaIntent, "audio")
    assert.equal(b.installed.controller.getState().canFallbackToAudio, false)
    b.installed.dispose()
  })
}

for (const exit of ["cancel", "microphone-end", "replacement", "socket-loss"]) {
  test(`a camera-only retry settling after ${exit} releases its late camera without starting video`, async () => {
    let grant, cameraRequests = 0
    const microphone = ownedAudioTrack(), replacement = ownedAudioTrack()
    const camera = Object.assign(ownedAudioTrack(), {kind: "video", getSettings: () => ({width: 640, height: 360, frameRate: 15})})
    const b = browser({videoAvailable: "true", permission: async request => {
      if (!request.audio) {
        if (++cameraRequests === 1) throw {name: "NotFoundError"}
        return new Promise(resolve => { grant = resolve })
      }
      const track = b.requests.length === 1 ? microphone : replacement
      return {getTracks: () => [track], getAudioTracks: () => [track]}
    }})
    await flush(); b.click(b.startVideo); await flush()
    b.click(b.nodes.get("direct-call-dock-retry")); await flush()
    assert.equal(microphone.stops, 0)
    assert.deepEqual(b.requests.map(r => Boolean(r.audio)), [true, false, false])
    if (exit === "microphone-end") microphone.end()
    else if (exit === "replacement") b.click(b.start)
    else if (exit === "socket-loss") b.loseSocket()
    else b.click(b.nodes.get("direct-call-dock-cancel"))
    assert.equal(microphone.stops, 1)
    grant({getTracks: () => [camera], getVideoTracks: () => [camera]}); await flush()
    assert.equal(camera.stops, 1)
    assert.equal(b.preview.srcObject, null)
    assert.deepEqual(b.commands.filter(c => c.event === "start_call").map(c => c.payload.media_intent), exit === "replacement" ? ["audio"] : [])
    if (exit === "replacement") assert.equal(replacement.stops, 0)
    b.installed.dispose()
  })
}

test("microphone end during camera-only retry exits preparation immediately and keeps recovery explicit", async () => {
  const microphone = ownedAudioTrack()
  let grant, cameraRequests = 0
  const camera = Object.assign(ownedAudioTrack(), {kind: "video", getSettings: () => ({width: 640, height: 360, frameRate: 15})})
  const b = browser({videoAvailable: "true", permission: async request => {
    if (request.audio) return {getTracks: () => [microphone], getAudioTracks: () => [microphone]}
    if (++cameraRequests === 1) throw {name: "NotFoundError"}
    return new Promise(resolve => {grant = resolve})
  }})
  await flush(); b.click(b.startVideo); await flush()
  b.click(b.nodes.get("direct-call-dock-retry")); await flush()
  microphone.end()
  assert.equal(b.installed.controller.getState().presentation, "result")
  assert.equal(b.installed.controller.getState().resultCode, "ended")
  assert.equal(b.installed.controller.getState().canFallbackToAudio, false)
  assert.equal(b.requests.length, 3)
  grant({getTracks: () => [camera], getVideoTracks: () => [camera]}); await flush()
  assert.equal(camera.stops, 1)
  assert.equal(b.installed.controller.getState().resultCode, "ended")
  assert.equal(b.commands.filter(c => c.event === "start_call").length, 0)
  b.installed.dispose()
})

test("repeated failed camera-only retry retains one microphone until explicit audio fallback", async () => {
  const microphone = ownedAudioTrack()
  const b = browser({videoAvailable: "true", permission: async request => {
    if (!request.audio) throw {name: "NotReadableError"}
    return {getTracks: () => [microphone], getAudioTracks: () => [microphone]}
  }})
  await flush(); b.click(b.startVideo); await flush()
  const retry = b.nodes.get("direct-call-dock-retry")
  assert.equal(retry.textContent, "Retry camera")
  b.click(retry); await flush()
  assert.equal(b.installed.controller.getState().canFallbackToAudio, true)
  assert.equal(microphone.stops, 0)
  b.click(b.nodes.get("direct-call-dock-start-voice-instead")); await flush()
  assert.deepEqual(b.requests.map(r => Boolean(r.audio)), [true, false, false])
  assert.deepEqual(b.commands.filter(c => c.event === "start_call").map(c => c.payload.media_intent), ["audio"])
  b.installed.dispose()
  assert.equal(microphone.stops, 1)
})

test("final fallback rechecks microphone liveness before dispatch without acquiring a replacement", async () => {
  const b = browser({videoAvailable: "true"})
  let stream
  Object.defineProperty(b.preview, "srcObject", {
    get: () => stream,
    set(value) {stream = value; value?.tracks[0].end()},
  })
  await flush(); b.click(b.startVideo); await flush()
  const microphone = b.tracks[0]
  const unsubscribe = b.installed.controller.subscribe(state => {
    if (state.mediaIntent === "audio" && state.microphoneReady) microphone.end()
  })
  b.click(b.nodes.get("direct-call-dock-start-voice-instead")); await flush()
  assert.equal(b.requests.length, 2)
  assert.equal(b.commands.filter(c => c.event === "start_call").length, 0)
  assert.equal(microphone.stops, 1)
  assert.equal(b.installed.controller.getState().canFallbackToAudio, false)
  unsubscribe(); b.installed.dispose()
})

test("explicit audio fallback after final camera end keeps its live microphone through ringing", async () => {
  const b = browser({videoAvailable: "true"})
  let stream
  Object.defineProperty(b.preview, "srcObject", {
    get: () => stream,
    set(value) {stream = value; value?.tracks[0].end()},
  })
  await flush(); b.click(b.startVideo); await flush()
  b.click(b.nodes.get("direct-call-dock-start-voice-instead")); await flush()
  assert.deepEqual(b.requests.map(r => Boolean(r.audio)), [true, false])
  assert.deepEqual(b.commands.filter(c => c.event === "start_call").map(c => c.payload.media_intent), ["audio"])
  assert.equal(b.installed.controller.getState().presentation, "outgoing_ringing")
  assert.equal(b.installed.controller.getState().microphoneReady, true)
  assert.deepEqual(b.tracks.map(t => t.stops), [0, 1])
  b.installed.dispose()
  assert.deepEqual(b.tracks.map(t => t.stops), [1, 1])
})

const videoInvitation = () => ({call_id: "call", role: "recipient", state: "ringing",
  ownership: "unclaimed", media_intent: "video", ringing_deadline_at: "2099-01-01T00:00:00Z"})

for (const role of ["caller", "recipient"]) {
  test(`${role} persistent camera denial offers settings guidance and deliberate microphone reuse`, async t => {
    const records = []
    const microphone = ownedAudioTrack()
    const b = browser({diagnosticWrite: record => records.push(record), role, snapshot: role === "recipient" ? videoInvitation() : null,
      videoAvailable: "true", permission: request => {
        if (request.audio) return trackStream(microphone)
        throw {name: "NotAllowedError", message: "private policy", deviceId: "private device"}
      }})
    t.after(() => b.installed.dispose())
    await flush()
    const retry = role === "caller" ? b.nodes.get("direct-call-dock-retry") : b.acceptVideo
    const status = b.nodes.get(role === "caller" ? "direct-call-dock-status" : "direct-call-incoming-status")
    const command = role === "caller" ? "start_call" : "accept_call"
    b.click(role === "caller" ? b.startVideo : b.acceptVideo); await flush()
    assert.match(status.textContent, /Camera access is blocked/)
    assert.match(status.textContent, /browser.*system.*settings/i)
    assert.match(status.textContent, /retry/i)
    assert.doesNotMatch(status.textContent, /private|prompt|you denied|policy/i)
    assert.equal(retry.disabled, false)
    assert.equal(b.commands.filter(c => c.event === command).length, 0)
    assert.equal(microphone.stops, 0)
    b.click(retry); await flush()
    assert.match(status.textContent, /browser.*system.*settings/i)
    assert.deepEqual(b.requests.map(r => Boolean(r.audio)), [true, false, false])
    assert.equal(b.commands.filter(c => c.event === command).length, 0)
    assert.match(status.textContent, /Microphone ready/)
    const fallback = b.nodes.get(role === "caller" ? "direct-call-dock-start-voice-instead" :
      "direct-call-incoming-answer-without-video")
    assert.equal(fallback.hidden, false)
    assert.equal(fallback.disabled, false)
    assert.deepEqual(records.filter(r => r.stage === "preflight").map(r => r.error_code), ["permission-denied"])
    assert.doesNotMatch(JSON.stringify(records), /private|device|policy|credential|call_id/)
    b.click(fallback); await flush()
    assert.deepEqual(b.requests.map(r => Boolean(r.audio)), [true, false, false])
    assert.deepEqual(b.commands.filter(c => c.event === command).map(c =>
      c.payload[role === "caller" ? "media_intent" : "answer_mode"]), ["audio"])
    if (role === "recipient") {
      assert.equal(b.installed.controller.getState().call.call_id, "call")
      assert.equal(b.installed.controller.getState().mediaIntent, "video")
    }
    b.installed.dispose()
    assert.equal(microphone.stops, 1)
  })
}

test("recipient camera failure offers explicit audio answer using the same ready microphone", async () => {
  const microphone = ownedAudioTrack()
  const b = browser({role: "recipient", snapshot: videoInvitation(), videoAvailable: "true",
    permission: async request => {
      if (request.video) throw {name: "NotAllowedError"}
      return {getTracks: () => [microphone], getAudioTracks: () => [microphone]}
    }})
  await flush()
  assert.equal(b.count().acquisitions, 0)
  b.click(b.acceptVideo); await flush()
  assert.equal(b.commands.filter(c => c.event === "accept_call").length, 0)
  assert.equal(microphone.stops, 0)
  assert.equal(b.installed.controller.getState().microphoneReady, true)
  assert.match(b.nodes.get("direct-call-incoming-status").textContent, /Microphone ready/)
  b.click(b.nodes.get("direct-call-incoming-answer-without-video")); await flush()
  assert.equal(b.count().acquisitions, 2)
  assert.deepEqual(b.commands.filter(c => c.event === "accept_call").map(c => c.payload.answer_mode), ["audio"])
  assert.equal(b.installed.controller.getState().call.media_intent, "video")
  assert.equal(b.installed.controller.getState().call.answer_mode, "audio")
  assert.equal(b.peers[0].transceivers[0].sender.track, microphone)
  b.installed.dispose()
  assert.equal(microphone.stops, 1)
})

test("recipient video answer previews its exact camera inside the incoming dialog before committing", async () => {
  const b = browser({role: "recipient", snapshot: videoInvitation(), videoAvailable: "true"})
  let previewed = null
  const unsubscribe = b.installed.controller.subscribe(state => {
    if (state.cameraPreviewTrack && state.presentation === "incoming_preflighting") {
      previewed = b.nodes.get("direct-call-incoming-preview").srcObject
    }
  })
  await flush(); b.click(b.acceptVideo); await flush()
  assert.deepEqual(previewed.tracks, [b.tracks[1]])
  assert.equal(b.requests[1].audio, false)
  assert.equal(b.count().acquisitions, 2)
  assert.deepEqual(b.preview.srcObject.tracks, [b.tracks[1]])
  assert.equal(b.preview.srcObject, previewed)
  assert.equal(b.installed.controller.getState().call.answer_mode, "video")
  assert.equal(b.installed.controller.getState().call.media_intent, "video")
  assert.equal(b.commands.filter(c => c.event === "accept_call").length, 1)
  unsubscribe(); b.installed.dispose()
  assert.deepEqual(b.tracks.map(t => t.stops), [1, 1])
})

test("ended recipient camera at final preflight cannot accept video and leaves explicit audio ready", async () => {
  const b = browser({role: "recipient", snapshot: videoInvitation(), videoAvailable: "true"})
  const preview = b.nodes.get("direct-call-incoming-preview")
  let stream = null
  Object.defineProperty(preview, "srcObject", {get: () => stream, set(value) {
    stream = value
    if (value) value.tracks[0].end()
  }})
  await flush(); b.click(b.acceptVideo); await flush()
  assert.equal(b.commands.filter(c => c.event === "accept_call").length, 0)
  assert.equal(b.installed.controller.getState().presentation, "incoming_ringing")
  assert.equal(b.installed.controller.getState().microphoneReady, true)
  assert.equal(b.tracks[0].stops, 0)
  assert.equal(b.tracks[1].stops, 1)
  assert.equal(preview.srcObject, null)
  b.click(b.nodes.get("direct-call-incoming-answer-without-video")); await flush()
  assert.equal(b.count().acquisitions, 2)
  assert.equal(b.installed.controller.getState().call.answer_mode, "audio")
  b.installed.dispose()
})

test("recipient retry asks only for camera and keeps its independent Voice microphone", async () => {
  const {track: voice, controller: voiceController} = await capturedVoice()
  const microphone = ownedAudioTrack()
  const camera = Object.assign(ownedAudioTrack(), {kind: "video", getSettings: () => ({width: 640, height: 360, frameRate: 15})})
  let cameras = 0
  const b = browser({role: "recipient", snapshot: videoInvitation(), videoAvailable: "true",
    permission: async request => {
      if (request.video && ++cameras === 1) throw {name: "NotReadableError"}
      const track = request.audio ? microphone : camera
      return {getTracks: () => [track], getAudioTracks: () => request.audio ? [track] : [],
        getVideoTracks: () => request.video ? [track] : []}
    }})
  await flush(); b.click(b.acceptVideo); await flush()
  assert.equal(b.installed.controller.getState().microphoneReady, true)
  b.click(b.acceptVideo); await flush()
  assert.deepEqual(b.requests.map(r => Boolean(r.audio)), [true, false, false])
  assert.deepEqual(b.preview.srcObject.tracks, [camera])
  assert.equal(b.installed.controller.getState().call.answer_mode, "video")
  assert.equal(b.peers[0].transceivers[0].sender.track, microphone)
  assert.equal(voice.stops, 0)
  b.installed.dispose()
  assert.equal(microphone.stops, 1)
  assert.equal(camera.stops, 1)
  assert.equal(voice.stops, 0)
  voiceController.leave()
})

test("recipient microphone failure keeps the invitation and original deadline for deliberate retry", async () => {
  let failures = true
  const microphone = ownedAudioTrack()
  const invitation = videoInvitation()
  const b = browser({role: "recipient", snapshot: invitation, videoAvailable: "true",
    permission: async () => {
      if (failures) throw {name: "NotAllowedError"}
      return {getTracks: () => [microphone], getAudioTracks: () => [microphone]}
    }})
  await flush(); b.click(b.acceptVideo); await flush()
  assert.equal(b.count().acquisitions, 1)
  assert.equal(b.commands.filter(c => c.event === "accept_call").length, 0)
  assert.equal(b.installed.controller.getState().call.ringing_deadline_at, invitation.ringing_deadline_at)
  assert.equal(b.installed.controller.getState().canDecline, true)
  assert.equal(b.installed.controller.getState().canAcceptVideo, true)
  failures = false
  b.click(b.nodes.get("direct-call-incoming-answer-without-video")); await flush()
  assert.equal(b.count().acquisitions, 2)
  assert.equal(b.installed.controller.getState().call.answer_mode, "audio")
  assert.equal(b.installed.controller.getState().call.ringing_deadline_at, invitation.ringing_deadline_at)
  b.installed.dispose()
})

for (const exit of ["decline", "expiry", "elsewhere", "replacement", "channel"]) {
  test(`recipient retained microphone is released on ${exit} and cannot answer the old invitation`, async () => {
    const microphone = ownedAudioTrack()
    const b = browser({role: "recipient", snapshot: videoInvitation(), videoAvailable: "true",
      permission: async request => {
        if (request.video) throw {name: "NotFoundError"}
        return {getTracks: () => [microphone], getAudioTracks: () => [microphone]}
      }})
    await flush(); b.click(b.acceptVideo); await flush()
    if (exit === "decline") b.click(b.nodes.get("direct-call-incoming-decline"))
    if (exit === "expiry") b.project({state: "terminal", terminal_outcome: "timed_out"})
    if (exit === "elsewhere") b.project({state: "connecting", ownership: "elsewhere"})
    if (exit === "replacement") b.incoming({...videoInvitation(), call_id: "replacement"})
    if (exit === "channel") b.loseChannel()
    await flush()
    assert.equal(microphone.stops, 1)
    assert.equal(b.installed.controller.getState().microphoneReady, false)
    if (exit !== "replacement") b.click(b.nodes.get("direct-call-incoming-answer-without-video"))
    await flush()
    assert.equal(b.commands.filter(c => c.event === "accept_call").length, 0)
    assert.equal(b.peers.length, 0)
    assert.equal(b.count().acquisitions, 2)
    b.installed.dispose()
  })
}

for (const mode of ["audio", "video"]) {
  for (const delivery of ["reply first", "projection first"]) {
    test(`competing prepared tabs keep the ${mode} winner with loser ${delivery}`, async t => {
      const reply = heldCommandReply()
      const loser = browser({role: "recipient", snapshot: videoInvitation(), videoAvailable: "true",
        acceptReply: () => reply})
      const winner = browser({role: "recipient", snapshot: videoInvitation(), videoAvailable: "true"})
      t.after(() => {loser.installed.dispose(); winner.installed.dispose()})
      await flush(); loser.click(loser.acceptVideo)
      winner.click(mode === "video" ? winner.acceptVideo : winner.nodes.get("direct-call-incoming-answer-without-video"))
      await flush()
      assert.equal(loser.nodes.get("direct-call-incoming-preview").srcObject.tracks[0], loser.tracks[1])
      const accepted = {...videoInvitation(), state: "connecting", ownership: "elsewhere", answer_mode: mode}
      if (delivery === "projection first") loser.project(accepted)
      reply.settle("ok", {signaling_session_id: "topic-session", call: accepted})
      await flush()
      if (delivery === "reply first") loser.project(accepted)
      await flush()
      assert.deepEqual(loser.tracks.map(track => track.stops), [1, 1])
      assert.equal(loser.peers.length, 0)
      assert.equal(loser.nodes.get("direct-call-incoming-preview").srcObject, null)
      assert.equal(loser.installed.controller.getState().call.answer_mode, mode)
      assert.equal(loser.commands.some(c => c.event === "media_credentials" || c.event === "leave_call"), false)
      const camera = mode === "video" ? winner.tracks[1] : null
      winner.peers[0].ready(); winner.project({state: "active"}); await flush()
      assert.equal(winner.peers[0].transceivers[1].sender.track, camera)
      assert.equal(winner.requests.length, mode === "video" ? 2 : 1)
      assert.equal(winner.tracks.every(track => track.stops === 0), true)
      assert.equal(winner.installed.controller.getState().call.answer_mode, mode)
      assert.equal(winner.audio.srcObject != null, true)
      loser.click(loser.acceptVideo); loser.click(loser.camera); await flush()
      assert.equal(loser.requests.length, 2)
      assert.equal(loser.commands.filter(c => c.event === "accept_call").length, 1)
      winner.click(winner.leave); await flush()
      assert.equal(winner.tracks.every(track => track.stops === 1), true)
    })
  }
}

for (const pending of ["microphone", "camera", "accept"]) {
  for (const completion of ["success", "error"]) {
    test(`winning video owner survives losing ${pending} ${completion} and observer departure with prior Voice`, async t => {
      const {track: voice, controller: voiceController} = await capturedVoice()
      t.after(() => voiceController.teardown())
      const reply = heldCommandReply()
      let settlePermission
      const microphone = ownedAudioTrack(), camera = videoTrack()
      const extra = pending === "microphone" ? ownedAudioTrack() : videoTrack()
      const loser = browser({role: "recipient", snapshot: videoInvitation(), videoAvailable: "true",
        permission: request => {
          const track = request.audio ? microphone : camera
          const held = (pending === "microphone" && request.audio) || (pending === "camera" && request.video)
          if (held) return new Promise((resolve, reject) => {settlePermission = () => {
            if (completion === "error") reject(Object.assign(new Error("private device detail"), {name: "NotAllowedError"}))
            else resolve({getTracks: () => [track, extra],
              getAudioTracks: () => request.audio ? [track, extra] : [],
              getVideoTracks: () => request.video ? [track, extra] : []})
          }})
          return {getTracks: () => [track], getAudioTracks: () => request.audio ? [track] : [],
            getVideoTracks: () => request.video ? [track] : []}
        }, ...(pending === "accept" ? {acceptReply: () => reply} : {})})
      const winner = browser({role: "recipient", snapshot: videoInvitation(), videoAvailable: "true"})
      const observer = browser({role: "recipient", snapshot: videoInvitation(), videoAvailable: "true"})
      t.after(() => {loser.installed.dispose(); winner.installed.dispose(); observer.installed.dispose()})
      await flush(); loser.click(loser.acceptVideo); winner.click(winner.acceptVideo); await flush()
      assert.equal(observer.requests.length, 0)
      loser.project({state: "connecting", ownership: "elsewhere", answer_mode: "video"})
      observer.project({state: "connecting", ownership: "elsewhere", answer_mode: "video"})
      if (pending !== "microphone") assert.equal(microphone.stops, 1)
      if (pending === "accept") {
        assert.equal(camera.stops, 1)
        // A late reply claiming this tab won cannot replace committed ownership.
        reply.settle(completion === "success" ? "ok" : "error", completion === "success" ? {
          signaling_session_id: "topic-session", call: {...videoInvitation(), state: "connecting",
            ownership: "self", answer_mode: "audio"},
        } : {reason: "temporarily_unavailable"})
      } else settlePermission()
      await flush()
      assert.equal(microphone.stops, pending === "microphone" && completion === "error" ? 0 : 1)
      assert.equal(camera.stops, pending === "microphone" || (pending === "camera" && completion === "error") ? 0 : 1)
      assert.equal(extra.stops, pending !== "accept" && completion === "success" ? 1 : 0)
      assert.equal(loser.installed.controller.getState().presentation, "owned_elsewhere")
      assert.equal(loser.installed.controller.getState().call.answer_mode, "video")
      assert.equal(loser.peers.length, 0)
      assert.equal(loser.preview.srcObject, null)
      assert.equal(loser.nodes.get("direct-call-incoming-preview").srcObject, null)
      assert.equal(loser.commands.some(c => ["media_credentials", "leave_call", "local_media_state"].includes(c.event)), false)
      assert.equal(loser.commands.filter(c => c.event === "accept_call").length, pending === "accept" ? 1 : 0)
      assert.equal(loser.requests.length, pending === "microphone" ? 1 : 2)
      winner.peers[0].ready(); winner.project({state: "active"}); await flush()
      const coarse = {recipient: {media_state_version: 1, microphone_muted: false, camera_enabled: true}}
      observer.project({state: "active", media_state: coarse}); await flush()
      assert.deepEqual(observer.installed.controller.getState().call.media_state, coarse)
      assert.match(observer.nodes.get("direct-call-dock-media-state").textContent, /Your call tab: microphone on, camera on/)
      for (const control of [observer.enable, observer.camera, observer.mute, observer.deafen, observer.leave]) {
        assert.equal(control.hidden, true)
        observer.click(control)
      }
      observer.installed.dispose(); await flush()
      microphone.dispatchEvent(new Event("ended")); camera.dispatchEvent(new Event("mute"))
      camera.dispatchEvent(new Event("ended")); await flush()
      assert.equal(winner.audio.srcObject != null, true)
      assert.equal(winner.peers[0].closed, undefined)
      assert.equal(winner.peers[0].transceivers[1].sender.track, winner.tracks[1])
      assert.deepEqual(winner.tracks.map(track => track.stops), [0, 0])
      assert.equal(observer.requests.length, 0)
      assert.equal(observer.commands.length, 0)
      assert.equal(voice.stops, 0)
      assert.equal(voiceController.state().status, "capturing")
      winner.click(winner.leave); await flush()
      assert.deepEqual(winner.tracks.map(track => track.stops), [1, 1])
      assert.equal(winner.timers.size, 0)
      assert.equal(voice.stops, 0)
    })
  }
}

for (const pending of ["camera", "accept"]) {
  test(`losing recipient video preparation releases both owned sources with ${pending} pending`, async () => {
    let settle
    const microphone = ownedAudioTrack()
    const camera = Object.assign(ownedAudioTrack(), {kind: "video", getSettings: () => ({width: 640, height: 360, frameRate: 15})})
    const b = browser({role: "recipient", snapshot: videoInvitation(), videoAvailable: "true",
      permission: request => {
        const track = request.audio ? microphone : camera
        const result = {getTracks: () => [track], getAudioTracks: () => request.audio ? [track] : [],
          getVideoTracks: () => request.video ? [track] : []}
        return pending === "camera" && request.video ? new Promise(resolve => {settle = () => resolve(result)}) : result
      }, ...(pending === "accept" ? {acceptReply: () => ({receive(status, fn) {
        if (status === "ok") settle = () => fn({signaling_session_id: "topic-session",
          call: {...videoInvitation(), state: "connecting", ownership: "elsewhere", answer_mode: "video"}})
        return this
      }})} : {})})
    const winner = browser({role: "recipient", snapshot: videoInvitation(), videoAvailable: "true"})
    await flush(); b.click(b.acceptVideo); winner.click(winner.acceptVideo); await flush()
    b.project({state: "connecting", ownership: "elsewhere", answer_mode: "video"})
    assert.equal(microphone.stops, 1)
    settle(); await flush()
    assert.equal(camera.stops, 1)
    assert.equal(b.peers.length, 0)
    assert.equal(b.preview.srcObject, null)
    assert.equal(b.nodes.get("direct-call-incoming-preview").srcObject, null)
    assert.equal(winner.peers.length, 1)
    assert.deepEqual(winner.tracks.map(t => t.stops), [0, 0])
    b.installed.dispose(); winner.installed.dispose()
  })
}

for (const answerMode of ["video", "audio"]) {
  test(`rejected recipient ${answerMode} answer releases capture and preserves ringing choices`, async () => {
    const b = browser({role: "recipient", snapshot: videoInvitation(), videoAvailable: "true",
      acceptReply: () => ({receive(status, fn) {
        if (status === "error") queueMicrotask(() => fn({reason: "temporarily_unavailable"}))
        return this
      }})})
    await flush()
    b.click(answerMode === "video" ? b.acceptVideo : b.nodes.get("direct-call-incoming-answer-without-video")); await flush()
    assert.deepEqual(b.tracks.map(t => t.stops), answerMode === "video" ? [1, 1] : [1])
    assert.equal(b.installed.controller.getState().presentation, "incoming_ringing")
    assert.equal(b.installed.controller.getState().call.media_intent, "video")
    assert.equal(b.installed.controller.getState().canAcceptVideo, true)
    assert.equal(b.installed.controller.getState().canAnswerWithoutVideo, true)
    assert.equal(b.preview.srcObject, null)
    assert.equal(b.nodes.get("direct-call-incoming-preview").srcObject, null)
    b.installed.dispose()
  })
}

test("original ringing deadline passing during camera permission prevents acceptance without a terminal projection", async t => {
  let grant
  const microphone = ownedAudioTrack()
  const camera = Object.assign(ownedAudioTrack(), {kind: "video", getSettings: () => ({width: 640, height: 360, frameRate: 15})})
  const b = browser({role: "recipient", snapshot: videoInvitation(), videoAvailable: "true",
    permission: request => request.audio ? {getTracks: () => [microphone], getAudioTracks: () => [microphone]} :
      new Promise(resolve => {grant = () => resolve({getTracks: () => [camera], getVideoTracks: () => [camera]})})})
  await flush(); b.click(b.acceptVideo); await flush()
  t.mock.method(Date, "now", () => Date.parse("2099-01-01T00:00:01Z"))
  grant(); await flush()
  assert.equal(b.commands.filter(c => c.event === "accept_call").length, 0)
  assert.equal(microphone.stops, 1)
  assert.equal(camera.stops, 1)
  assert.equal(b.installed.controller.getState().presentation, "incoming_ringing")
  assert.equal(b.installed.controller.getState().canAcceptVideo, false)
  b.installed.dispose()
})

test("expired retained recipient preparation releases microphone instead of dispatching audio fallback", async t => {
  const microphone = ownedAudioTrack()
  const b = browser({role: "recipient", snapshot: videoInvitation(), videoAvailable: "true",
    permission: async request => {
      if (request.video) throw {name: "NotAllowedError"}
      return {getTracks: () => [microphone], getAudioTracks: () => [microphone]}
    }})
  await flush(); b.click(b.acceptVideo); await flush()
  t.mock.method(Date, "now", () => Date.parse("2099-01-01T00:00:01Z"))
  b.click(b.nodes.get("direct-call-incoming-answer-without-video")); await flush()
  assert.equal(microphone.stops, 1)
  assert.equal(b.commands.filter(c => c.event === "accept_call").length, 0)
  assert.equal(b.count().acquisitions, 2)
  b.installed.dispose()
})

for (const source of ["microphone", "camera"]) {
  test(`recipient final preflight detects ${source} end before its queued source event`, async () => {
    const b = browser({role: "recipient", snapshot: videoInvitation(), videoAvailable: "true"})
    const preview = b.nodes.get("direct-call-incoming-preview")
    let stream = null
    Object.defineProperty(preview, "srcObject", {get: () => stream, set(value) {
      stream = value
      if (value) b.tracks[source === "microphone" ? 0 : 1].readyState = "ended"
    }})
    await flush(); b.click(b.acceptVideo); await flush()
    assert.equal(b.commands.filter(c => c.event === "accept_call").length, 0)
    assert.equal(b.installed.controller.getState().presentation, "incoming_ringing")
    assert.equal(b.tracks[0].stops, source === "microphone" ? 1 : 0)
    assert.equal(b.tracks[1].stops, 1)
    assert.equal(preview.srcObject, null)
    assert.equal(b.installed.controller.getState().microphoneReady, source === "camera")
    b.installed.dispose()
  })
}

for (const role of ["caller", "recipient"]) {
  test(`${role} prepared camera attaches to the negotiated dormant sender using its preview track`, async () => {
    const b = browser({role, snapshot: role === "recipient" ? videoInvitation() : null, videoAvailable: "true"})
    await flush()
    b.click(role === "caller" ? b.startVideo : b.acceptVideo)
    await flush()
    if (role === "caller") {
      assert.equal(b.installed.controller.getState().cameraState, "preview_ready")
      assert.equal(b.peers.length, 0)
      b.project({state: "connecting", answer_mode: "video"}); await flush()
    }
    const pc = b.peers[0]
    assert.equal(pc.transceivers[1].sender.track, b.tracks[1])
    assert.equal(pc.transceivers[0].sender.track, b.tracks[0])
    assert.deepEqual(b.preview.srcObject.tracks, [b.tracks[1]])
    assert.equal(b.installed.controller.getState().cameraState, "enabled")
    assert.match(b.nodes.get("direct-call-local-preview-status").textContent, /Camera attached/i)
    assert.equal(b.commands.filter(c => c.event === "offer").length, 1)
    assert.equal(pc.transceivers.length, 2)
    const state = b.commands.filter(c => c.event === "local_media_state").at(-1).payload
    assert.equal(state.camera_enabled, true)
    assert.equal(state.microphone_muted, false)
    b.installed.dispose()
    assert.deepEqual(b.tracks.map(t => t.stops), [1, 1])
  })
}

for (const videoDirection of [null, "recvonly", "inactive"]) {
  test(`a ${videoDirection} negotiated camera direction cannot be advertised as enabled`, async () => {
    const b = browser({role: "recipient", snapshot: videoInvitation(), videoAvailable: "true", videoDirection})
    await flush(); b.click(b.acceptVideo); await flush()
    assert.equal(b.tracks[1].stops, 1)
    assert.equal(b.tracks[0].stops, 0)
    assert.equal(b.peers[0].closed, undefined)
    assert.equal(b.peers[0].transceivers[1].sender.track, null)
    assert.equal(b.installed.controller.getState().cameraState, "error")
    assert.equal(b.commands.some(c => c.event === "local_media_state" && c.payload.camera_enabled), false)
    assert.equal(b.commands.some(c => c.event === "leave_call"), false)
    b.installed.dispose()
  })
}

test("incompatible camera replacement reports a local error with playback, mute, renewal and intent preserved", async () => {
  const b = browser({role: "recipient", snapshot: videoInvitation(), videoAvailable: "true",
    replaceCamera: track => {if (track) throw {name: "InvalidModificationError"}}})
  await flush(); b.click(b.acceptVideo); await flush()
  const pc = b.peers[0]
  pc.ready(); b.project({state: "active"}); await flush()
  assert.equal(b.installed.controller.getState().cameraError, "incompatible-sender")
  assert.match(b.nodes.get("direct-call-dock-status").textContent, /camera could not attach.*audio can continue/i)
  assert.equal(b.installed.controller.getState().playbackState, "playing")
  assert.equal(b.tracks[1].stops, 1)
  assert.equal(b.preview.srcObject, null)
  assert.equal(b.tracks[0].stops, 0)
  b.click(b.mute); await flush()
  assert.equal(b.tracks[0].enabled, false)
  assert.equal(b.commands.filter(c => c.event === "local_media_state").at(-1).payload.microphone_muted, true)
  for (const timer of [...b.timers.values()]) timer()
  await flush()
  assert.equal(b.commands.some(c => c.event === "renew"), true)
  assert.equal(b.commands.filter(c => c.event === "offer").length, 1)
  assert.equal(b.installed.controller.getState().call.media_intent, "video")
  assert.equal(b.installed.controller.getState().call.answer_mode, "video")
  assert.equal(b.commands.some(c => c.event === "leave_call"), false)
  b.installed.dispose()
})

test("held camera attachment publishes only after success and combines with current deafen and mute", async () => {
  let finish
  const b = browser({role: "recipient", snapshot: videoInvitation(), videoAvailable: "true",
    replaceCamera: track => track && new Promise(resolve => {finish = resolve})})
  await flush(); b.click(b.acceptVideo); await flush()
  assert.equal(b.installed.controller.getState().cameraState, "attaching")
  assert.equal(b.commands.some(c => c.event === "local_media_state" && c.payload.camera_enabled), false)
  assert.deepEqual(b.preview.srcObject.tracks, [b.tracks[1]])
  b.click(b.deafen); await flush()
  finish(); await flush()
  const state = b.commands.filter(c => c.event === "local_media_state").at(-1).payload
  assert.equal(state.camera_enabled, true)
  assert.equal(state.microphone_muted, true)
  b.click(b.mute); b.click(b.deafen); await flush()
  assert.equal(b.commands.filter(c => c.event === "local_media_state").at(-1).payload.camera_enabled, true)
  assert.equal(b.tracks[0].enabled, false)
  b.installed.dispose()
})

for (const exit of ["camera ended", "leave", "owner loss", "terminal", "channel loss"]) {
  test(`pending attachment after ${exit} cannot publish enabled or stop surviving audio`, async () => {
    let finish
    const b = browser({role: "recipient", snapshot: videoInvitation(), videoAvailable: "true",
      replaceCamera: track => track && new Promise(resolve => {finish = resolve})})
    await flush(); b.click(b.acceptVideo); await flush()
    assert.equal(typeof finish, "function")
    if (exit === "camera ended") b.tracks[1].end()
    else if (exit === "leave") b.click(b.leave)
    else if (exit === "owner loss") b.project({ownership: "elsewhere"})
    else if (exit === "terminal") b.project({state: "terminal", terminal_outcome: "ended"})
    else b.loseChannel()
    await flush()
    assert.equal(b.tracks[1].stops, 1)
    assert.equal(b.preview.srcObject, null)
    finish(); await flush()
    assert.equal(b.commands.some(c => c.event === "local_media_state" && c.payload.camera_enabled), false)
    if (exit === "camera ended") {
      assert.equal(b.tracks[0].stops, 0)
      assert.equal(b.peers[0].closed, undefined)
      assert.equal(b.peers[0].transceivers[1].sender.track, null)
      assert.equal(b.installed.controller.getState().cameraState, "off")
      assert.equal(b.commands.some(c => c.event === "leave_call"), false)
    } else assert.equal(b.tracks[0].stops, 1)
    b.installed.dispose()
  })
}

test("camera end while the initial answer is pending reports off and preserves audio negotiation", async () => {
  let answer
  const b = browser({role: "recipient", snapshot: videoInvitation(), videoAvailable: "true",
    offerReply(payload) {
      return {receive(status, fn) {
        if (status === "ok") answer = () => fn({...payload, description: {type: "answer", sdp: "answer"}})
        return this
      }}
    }})
  await flush(); b.click(b.acceptVideo); await flush()
  b.tracks[1].end()
  assert.equal(b.installed.controller.getState().cameraState, "off")
  assert.equal(b.preview.srcObject, null)
  assert.equal(b.tracks[0].stops, 0)
  assert.equal(b.commands.some(c => c.event === "local_media_state"), false)
  answer(); await flush()
  assert.equal(b.installed.controller.getState().cameraState, "off")
  assert.equal(b.peers[0].transceivers[1].sender.track, null)
  assert.equal(b.commands.some(c => c.event === "local_media_state" && c.payload.camera_enabled), false)
  assert.equal(b.commands.some(c => c.event === "leave_call"), false)
  b.installed.dispose()
})

for (const role of ["caller", "recipient"]) {
  test(`${role} audio owner turns camera on/off/on with fresh capture and continued audio`, async () => {
    const replacements = []
    const b = browser({role, videoAvailable: "true", snapshot: role === "recipient" ? videoInvitation() : null,
      replaceCamera: track => {replacements.push(track)}})
    await flush()
    b.click(role === "caller" ? b.start : b.nodes.get("direct-call-incoming-answer-without-video"))
    await flush()
    if (role === "caller") {b.project({state: "connecting", answer_mode: "audio"}); await flush()}
    const pc = b.peers[0], sender = pc.transceivers[1].sender, microphone = b.tracks[0]
    pc.ready(); b.project({state: "active"}); await flush()
    const playback = b.audio.srcObject
    assert.equal(b.camera.hidden, false)
    assert.equal(b.camera.getAttribute("aria-label"), "Turn camera on")
    b.click(b.mute); b.click(b.deafen)
    b.click(b.camera); await flush()
    const first = b.tracks[1]
    assert.equal(sender.track, first)
    assert.deepEqual(b.preview.srcObject.tracks, [first])
    assert.equal(b.camera.getAttribute("aria-pressed"), undefined)
    assert.equal(b.camera.getAttribute("data-active"), "true")
    b.click(b.camera)
    assert.equal(first.stops, 1)
    assert.equal(b.preview.srcObject, null)
    assert.equal(b.installed.controller.getState().cameraState, "off")
    await flush()
    assert.equal(sender.track, null)
    b.click(b.camera); await flush()
    const fresh = b.tracks[2]
    assert.notEqual(fresh, first)
    assert.equal(sender.track, fresh)
    assert.deepEqual(replacements, [first, null, fresh])
    assert.deepEqual(b.requests.map(r => Boolean(r.audio)), [true, false, false])
    assert.equal(b.peers.length, 1)
    assert.equal(pc.transceivers.length, 2)
    assert.equal(b.commands.filter(c => c.event === "offer").length, 1)
    assert.equal(microphone.stops, 0)
    assert.equal(microphone.enabled, false)
    assert.equal(b.audio.srcObject, playback)
    assert.equal(b.audio.muted, true)
    assert.equal(b.installed.controller.getState().playbackState, "playing")
    assert.equal(b.installed.controller.getState().call.answer_mode, "audio")
    assert.equal(b.installed.controller.getState().call.media_intent, role === "caller" ? "audio" : "video")
    const state = b.commands.filter(c => c.event === "local_media_state").at(-1).payload
    assert.equal(state.microphone_muted, true)
    assert.equal(state.camera_enabled, true)
    for (const timer of [...b.timers.values()]) timer()
    await flush()
    assert.equal(b.commands.some(c => c.event === "renew"), true)
    b.click(b.deafen); b.click(b.mute); await flush()
    assert.equal(microphone.enabled, true)
    assert.equal(sender.track, fresh)
    b.installed.dispose()
    assert.deepEqual(b.tracks.map(t => t.stops), [1, 1, 1])
  })
}

test("camera off abandons a pending prompt and releases late tracks while audio callbacks survive", async () => {
  let grant, cameraRequests = 0
  const microphone = ownedAudioTrack(), late = videoTrack(), extra = videoTrack(), fresh = videoTrack()
  const b = browser({videoAvailable: "true", permission: request => {
    if (request.audio) return trackStream(microphone)
    if (++cameraRequests === 1) return new Promise(resolve => {grant = resolve})
    return trackStream(fresh)
  }})
  await flush(); b.click(b.start); await flush()
  b.project({state: "connecting", answer_mode: "audio"}); await flush()
  b.peers[0].ready(); b.project({state: "active"}); await flush()
  b.click(b.camera); await flush()
  assert.equal(b.installed.controller.getState().cameraState, "pending")
  assert.equal(b.camera.getAttribute("aria-label"), "Turn camera off")
  assert.equal(b.camera.getAttribute("aria-busy"), "true")
  assert.equal(b.camera.getAttribute("aria-pressed"), undefined)
  assert.equal(b.camera.getAttribute("data-active"), "false")
  assert.match(b.nodes.get("direct-call-dock-status").textContent, /Camera permission pending.*browser prompt/)
  b.click(b.camera)
  assert.equal(b.installed.controller.getState().cameraState, "off")
  assert.match(b.nodes.get("direct-call-dock-status").textContent, /Camera off/)
  b.click(b.camera); await flush()
  assert.equal(cameraRequests, 1)
  assert.equal(b.installed.controller.getState().cameraError, "permission-pending")
  grant(trackStream(late, extra)); await flush()
  assert.deepEqual([late.stops, extra.stops], [1, 1])
  assert.equal(b.preview.srcObject, null)
  assert.equal(b.peers[0].transceivers[1].sender.track, null)
  assert.equal(microphone.stops, 0)
  b.click(b.camera); await flush()
  assert.equal(cameraRequests, 2)
  assert.equal(b.peers[0].transceivers[1].sender.track, fresh)
  assert.equal(b.installed.controller.getState().playbackState, "playing")
  // A camera gesture must not invalidate the parent microphone-ended callback.
  microphone.end(); await flush()
  assert.equal(b.commands.filter(c => c.event === "leave_call").length, 1)
  assert.equal(fresh.stops, 1)
  assert.equal(b.preview.srcObject, null)
  b.installed.dispose()
})

for (const boundary of ["answer", "attachment", "detachment"]) {
  test(`camera off releases capture immediately while ${boundary} is pending without replacing audio`, async () => {
    let answer, finish
    const detached = []
    const b = browser({videoAvailable: "true",
      offerReply: boundary === "answer" ? payload => ({receive(status, fn) {
        if (status === "ok") answer = () => fn({...payload, description: {type: "answer", sdp: "answer"}})
        return this
      }}) : undefined,
      replaceCamera: track => {
        detached.push(track)
        if ((boundary === "attachment" && track) || (boundary === "detachment" && !track)) {
          return new Promise(resolve => {finish = resolve})
        }
      }})
    await flush(); b.click(b.start); await flush()
    b.project({state: "connecting", answer_mode: "audio"}); await flush()
    b.click(b.camera); await flush()
    const camera = b.tracks[1], pc = b.peers[0]
    assert.equal(b.installed.controller.getState().cameraState,
      boundary === "answer" ? "preview_ready" : boundary === "attachment" ? "attaching" : "enabled")
    b.click(b.camera)
    assert.equal(camera.stops, 1)
    assert.equal(b.tracks[0].stops, 0)
    assert.equal(b.preview.srcObject, null)
    assert.equal(b.camera.getAttribute("aria-busy"), "false")
    if (boundary === "answer") answer()
    await flush()
    if (finish) finish()
    await flush()
    assert.equal(pc.transceivers[1].sender.track, null)
    assert.equal(b.installed.controller.getState().cameraState, "off")
    if (boundary === "answer") assert.equal(detached.includes(camera), false)
    else assert.equal(detached.at(-1), null)
    pc.ready(); b.project({state: "active"}); await flush()
    assert.equal(b.installed.controller.getState().playbackState, "playing")
    b.click(b.mute); await flush()
    assert.equal(b.tracks[0].enabled, false)
    assert.equal(b.commands.filter(c => c.event === "offer").length, 1)
    assert.equal(b.commands.some(c => c.event === "leave_call"), false)
    b.installed.dispose()
  })
}

for (const failure of ["permission", "sender"]) {
  test(`active audio camera ${failure} failure releases camera only and supports deliberate fresh retry`, async () => {
    let fail = true
    const b = browser({videoAvailable: "true",
      permission: failure === "permission" ? request => {
        if (!request.audio && fail) throw {name: "NotAllowedError"}
        const track = request.audio ? ownedAudioTrack() : videoTrack()
        b.tracks.push(track)
        return trackStream(track)
      } : undefined,
      replaceCamera: track => {if (failure === "sender" && fail && track) throw {name: "InvalidModificationError"}}})
    await flush(); b.click(b.start); await flush()
    b.project({state: "connecting", answer_mode: "audio"}); await flush()
    const pc = b.peers[0]
    pc.ready(); b.project({state: "active"}); await flush()
    b.click(b.camera); await flush()
    assert.equal(b.installed.controller.getState().cameraError, failure === "permission" ? "permission-denied" : "incompatible-sender")
    assert.equal(b.preview.srcObject, null)
    assert.equal(pc.transceivers[1].sender.track, null)
    if (failure === "sender") assert.equal(b.tracks[1].stops, 1)
    assert.equal(b.tracks[0].stops, 0)
    assert.equal(b.installed.controller.getState().playbackState, "playing")
    assert.equal(b.camera.getAttribute("aria-label"), "Turn camera on")
    b.click(b.mute); await flush()
    fail = false
    b.click(b.camera); await flush()
    assert.equal(b.installed.controller.getState().cameraState, "enabled")
    assert.equal(pc.transceivers[1].sender.track, b.tracks.at(-1))
    assert.equal(b.tracks[0].enabled, false)
    assert.deepEqual(b.requests.map(r => Boolean(r.audio)), [true, false, false])
    assert.equal(b.commands.some(c => c.event === "leave_call"), false)
    b.installed.dispose()
  })
}

for (const unavailable of ["disabled", "sibling"]) {
  test(`${unavailable} camera control cannot capture or change committed audio choices`, async () => {
    const b = browser({videoAvailable: unavailable === "disabled" ? "false" : "true"})
    await flush(); b.click(b.start); await flush()
    b.project({state: "connecting", answer_mode: "audio"}); await flush()
    b.peers[0].ready(); b.project({state: "active"}); await flush()
    if (unavailable === "sibling") b.project({ownership: "elsewhere"})
    await flush()
    if (unavailable === "disabled") {
      assert.equal(b.camera.hidden, false)
      assert.equal(b.camera.getAttribute("aria-disabled"), "true")
      assert.equal(b.camera.getAttribute("aria-describedby"), "direct-call-camera-unavailable-reason")
    } else assert.equal(b.camera.hidden, true)
    b.click(b.camera); b.installed.controller.toggleCamera(); await flush()
    assert.equal(b.requests.length, 1)
    assert.equal(b.installed.controller.getState().call.media_intent, "audio")
    assert.equal(b.installed.controller.getState().call.answer_mode, "audio")
    assert.equal(b.peers.length, 1)
    b.installed.dispose()
  })
}

// Exercise gestures through the persistent dock; only browser promises are held.
for (const outcome of ["resolve", "reject"]) {
  for (const latest of ["on", "off"]) {
    test(`held old camera attachment ${outcome} converges to the latest ${latest} gesture`, async () => {
      let settle, held = true
      const b = browser({videoAvailable: "true", replaceCamera: track => {
        if (track && held) {
          held = false
          return new Promise((resolve, reject) => {settle = outcome === "resolve" ? resolve : reject})
        }
      }})
      await flush(); b.click(b.start); await flush()
      b.project({state: "connecting", answer_mode: "audio"}); await flush()
      const pc = b.peers[0], sender = pc.transceivers[1].sender, microphone = b.tracks[0]
      pc.ready(); b.project({state: "active"}); await flush()
      const playback = b.audio.srcObject
      b.click(b.camera); await flush()
      const old = b.tracks[1]
      assert.equal(b.installed.controller.getState().cameraState, "attaching")
      b.click(b.camera)
      assert.equal(old.stops, 1)
      assert.equal(b.preview.srcObject, null)
      b.click(b.camera); await flush()
      const fresh = b.tracks[2]
      if (latest === "off") b.click(b.camera)
      b.click(b.deafen); await flush()
      assert.equal(b.commands.some(c => c.event === "local_media_state" && c.payload.camera_enabled), false)
      settle(new Error("obsolete replacement")); await flush()
      const state = b.installed.controller.getState()
      assert.equal(state.cameraState, latest === "on" ? "enabled" : "off")
      assert.equal(state.cameraError, null)
      assert.equal(sender.track, latest === "on" ? fresh : null)
      assert.equal(fresh.stops, latest === "on" ? 0 : 1)
      assert.equal(b.preview.srcObject?.tracks[0] ?? null, latest === "on" ? fresh : null)
      const published = b.commands.filter(c => c.event === "local_media_state").at(-1).payload
      assert.equal(published.camera_enabled, latest === "on")
      assert.equal(published.microphone_muted, true)
      assert.equal(microphone.stops, 0)
      assert.equal(microphone.enabled, false)
      assert.equal(b.audio.srcObject, playback)
      assert.equal(state.playbackState, "playing")
      assert.equal(pc.closed, undefined)
      assert.equal(b.peers.length, 1)
      assert.equal(pc.transceivers.length, 2)
      assert.equal(b.commands.filter(c => c.event === "offer").length, 1)
      assert.equal(b.commands.some(c => c.event === "leave_call"), false)
      b.installed.dispose()
      assert.deepEqual(b.tracks.map(t => t.stops), [1, 1, 1])
    })
  }
}

for (const outcome of ["resolve", "reject"]) {
  for (const latest of ["on", "off"]) {
    test(`held old camera detachment ${outcome} cannot erase the latest ${latest} gesture`, async () => {
      let settle, held = true
      const b = browser({videoAvailable: "true", replaceCamera: track => {
        if (!track && held) {
          held = false
          return new Promise((resolve, reject) => {settle = outcome === "resolve" ? resolve : reject})
        }
      }})
      await flush(); b.click(b.start); await flush()
      b.project({state: "connecting", answer_mode: "audio"}); await flush()
      const pc = b.peers[0], sender = pc.transceivers[1].sender
      pc.ready(); b.project({state: "active"}); await flush()
      b.click(b.camera); await flush()
      b.click(b.camera); await flush()
      assert.equal(b.tracks[1].stops, 1)
      assert.equal(b.preview.srcObject, null)
      b.click(b.camera); await flush()
      const fresh = b.tracks[2]
      if (latest === "off") b.click(b.camera)
      settle(new Error("obsolete detachment")); await flush()
      assert.equal(sender.track, latest === "on" ? fresh : null)
      assert.equal(b.installed.controller.getState().cameraState, latest === "on" ? "enabled" : "off")
      assert.equal(b.installed.controller.getState().cameraError, null)
      assert.equal(fresh.stops, latest === "on" ? 0 : 1)
      b.click(b.mute); await flush()
      const published = b.commands.filter(c => c.event === "local_media_state").at(-1).payload
      assert.equal(published.camera_enabled, latest === "on")
      assert.equal(published.microphone_muted, true)
      assert.equal(b.tracks[0].stops, 0)
      assert.equal(b.installed.controller.getState().playbackState, "playing")
      assert.equal(b.peers.length, 1)
      assert.equal(pc.transceivers.length, 2)
      assert.equal(b.commands.filter(c => c.event === "offer").length, 1)
      assert.equal(b.commands.some(c => c.event === "leave_call"), false)
      b.installed.dispose()
      assert.deepEqual(b.tracks.map(t => t.stops), [1, 1, 1])
    })
  }
}

for (const outcome of ["grant", "reject"]) {
  test(`rapid off/on/off during old camera permission ${outcome} requires a fresh deliberate retry`, async () => {
    let settle, cameraRequests = 0
    const microphone = ownedAudioTrack(), late = videoTrack(), extra = videoTrack(), fresh = videoTrack()
    const b = browser({videoAvailable: "true", permission: request => {
      if (request.audio) return trackStream(microphone)
      if (++cameraRequests === 1) return new Promise((resolve, reject) => {
        settle = () => outcome === "grant" ? resolve(trackStream(late, extra)) : reject({name: "NotAllowedError"})
      })
      return trackStream(fresh)
    }})
    await flush(); b.click(b.start); await flush()
    b.project({state: "connecting", answer_mode: "audio"}); await flush()
    const pc = b.peers[0], sender = pc.transceivers[1].sender
    pc.ready(); b.project({state: "active"}); await flush()
    b.click(b.camera); await flush()
    b.click(b.camera); b.click(b.camera); b.click(b.camera); await flush()
    assert.equal(cameraRequests, 1)
    assert.equal(b.installed.controller.getState().cameraState, "off")
    settle(); await flush()
    assert.equal(cameraRequests, 1)
    assert.deepEqual([late.stops, extra.stops], outcome === "grant" ? [1, 1] : [0, 0])
    assert.equal(sender.track, null)
    assert.equal(b.preview.srcObject, null)
    assert.equal(b.installed.controller.getState().cameraState, "off")
    assert.equal(b.installed.controller.getState().cameraError, null)
    assert.equal(b.commands.some(c => c.event === "local_media_state" && c.payload.camera_enabled), false)
    b.click(b.camera); await flush()
    assert.equal(cameraRequests, 2)
    assert.equal(sender.track, fresh)
    assert.equal(b.installed.controller.getState().cameraState, "enabled")
    assert.equal(microphone.stops, 0)
    assert.equal(b.installed.controller.getState().playbackState, "playing")
    assert.equal(b.peers.length, 1)
    assert.equal(pc.transceivers.length, 2)
    assert.equal(b.commands.filter(c => c.event === "offer").length, 1)
    assert.equal(b.commands.some(c => c.event === "leave_call"), false)
    b.installed.dispose()
    assert.equal(fresh.stops, 1)
    assert.equal(microphone.stops, 1)
  })
}

for (const outcome of ["resolve", "reject"]) {
  test(`terminal cleanup cancels queued attachment before old ${outcome} and preserves a replacement Call`, async () => {
    let settle, held = true
    const b = browser({videoAvailable: "true", replaceCamera: track => {
      if (track && held) {
        held = false
        return new Promise((resolve, reject) => {settle = outcome === "resolve" ? resolve : reject})
      }
    }})
    await flush(); b.click(b.start); await flush()
    b.project({state: "connecting", answer_mode: "audio"}); await flush()
    const oldPeer = b.peers[0]
    oldPeer.ready(); b.project({state: "active"}); await flush()
    b.click(b.camera); await flush()
    b.click(b.camera); b.click(b.camera); await flush()
    const queued = b.tracks[2]
    b.click(b.leave)
    assert.deepEqual(b.tracks.map(t => t.stops), [1, 1, 1])
    assert.equal(oldPeer.closed, true)
    assert.equal(b.preview.srcObject, null)
    assert.equal(b.audio.srcObject, null)
    assert.equal(b.timers.size, 0)
    await flush()
    b.click(b.nodes.get("direct-call-dock-dismiss")); b.click(b.start); await flush()
    b.project({state: "connecting", answer_mode: "audio"}); await flush()
    const pc = b.peers[1], microphone = b.tracks[3]
    pc.ready(); b.project({state: "active"}); await flush()
    b.click(b.camera); await flush()
    const fresh = b.tracks[4], playback = b.audio.srcObject
    assert.equal(pc.transceivers[1].sender.track, fresh)
    settle(new Error("obsolete Call")); await flush()
    assert.notEqual(oldPeer.transceivers[1].sender.track, queued)
    assert.equal(pc.transceivers[1].sender.track, fresh)
    assert.equal(b.preview.srcObject.tracks[0], fresh)
    assert.equal(b.installed.controller.getState().call.call_id, "call-2")
    assert.equal(b.installed.controller.getState().cameraState, "enabled")
    assert.equal(b.installed.controller.getState().cameraError, null)
    assert.equal(b.installed.controller.getState().playbackState, "playing")
    assert.equal(b.audio.srcObject, playback)
    assert.equal(microphone.stops, 0)
    assert.equal(fresh.stops, 0)
    assert.equal(pc.closed, undefined)
    assert.equal(b.peers.length, 2)
    assert.equal(pc.transceivers.length, 2)
    assert.equal(b.commands.filter(c => c.event === "offer").length, 2)
    assert.equal(b.commands.filter(c => c.event === "leave_call").length, 1)
    assert.equal(b.commands.some(c => c.event === "local_media_state" && c.payload.call_id === "call" && c.payload.camera_enabled), false)
    b.installed.dispose()
    assert.deepEqual(b.tracks.map(t => t.stops), [1, 1, 1, 1, 1])
  })
}

for (const outcome of ["ok", "error"]) {
  test(`delayed old enabled/off ${outcome} replies cannot roll back fresh camera and current mute`, async () => {
    const replies = []
    const b = browser({videoAvailable: "true", mediaReply: payload => ({receive(status, fn) {
      if (status === outcome) replies.push(() => fn(outcome === "ok" ? payload : {error: "unavailable"}))
      return this
    }})})
    await flush(); b.click(b.start); await flush()
    b.project({state: "connecting", answer_mode: "audio"}); await flush()
    const pc = b.peers[0]
    pc.ready(); b.project({state: "active"}); await flush()
    b.click(b.camera); await flush()
    b.click(b.camera); await flush()
    b.click(b.mute); b.click(b.camera); await flush()
    const fresh = b.tracks[2]
    // Keep the current acknowledgement outstanding; settle obsolete ones in reverse order.
    for (const reply of replies.slice(0, -1).reverse()) reply()
    await flush()
    const published = b.commands.filter(c => c.event === "local_media_state").map(c => c.payload)
    assert.ok(published.some(s => s.camera_enabled === true && s.microphone_muted === false))
    assert.ok(published.some(s => s.camera_enabled === false))
    assert.equal(published.at(-1).camera_enabled, true)
    assert.equal(published.at(-1).microphone_muted, true)
    assert.ok(published.every((s, i) => i === 0 || s.media_state_version > published[i - 1].media_state_version))
    assert.equal(b.installed.controller.getState().cameraState, "enabled")
    assert.equal(pc.transceivers[1].sender.track, fresh)
    assert.equal(b.preview.srcObject.tracks[0], fresh)
    assert.equal(b.tracks[0].enabled, false)
    assert.equal(b.tracks[0].stops, 0)
    assert.equal(b.tracks[1].stops, 1)
    assert.equal(b.installed.controller.getState().playbackState, "playing")
    assert.equal(b.commands.some(c => c.event === "leave_call"), false)
    b.installed.dispose()
    assert.deepEqual(b.tracks.map(t => t.stops), [1, 1, 1])
  })
}

for (const outcome of ["grant", "reject"]) {
  test(`late active camera permission ${outcome} cannot mutate a replacement audio Call`, async () => {
    let settle, cameraRequests = 0, microphoneRequests = 0
    const oldMicrophone = ownedAudioTrack(), currentMicrophone = ownedAudioTrack()
    const late = videoTrack(), extra = videoTrack(), fresh = videoTrack()
    const b = browser({videoAvailable: "true", permission: request => {
      if (request.audio) return trackStream(++microphoneRequests === 1 ? oldMicrophone : currentMicrophone)
      if (++cameraRequests === 1) return new Promise((resolve, reject) => {
        settle = () => outcome === "grant" ? resolve(trackStream(late, extra)) : reject({name: "NotAllowedError"})
      })
      return trackStream(fresh)
    }})
    await flush(); b.click(b.start); await flush()
    b.project({state: "connecting", answer_mode: "audio"}); await flush()
    b.peers[0].ready(); b.project({state: "active"}); await flush()
    b.click(b.camera); await flush()
    b.click(b.leave)
    assert.equal(oldMicrophone.stops, 1)
    assert.equal(b.peers[0].closed, true)
    assert.equal(b.timers.size, 0)
    await flush()
    b.click(b.nodes.get("direct-call-dock-dismiss")); b.click(b.start); await flush()
    b.project({state: "connecting", answer_mode: "audio"}); await flush()
    const pc = b.peers[1]
    pc.ready(); b.project({state: "active"}); await flush()
    b.click(b.camera); await flush()
    assert.equal(cameraRequests, 1)
    assert.equal(b.installed.controller.getState().cameraError, "permission-pending")
    settle(); await flush()
    assert.equal(cameraRequests, 1)
    assert.deepEqual([late.stops, extra.stops], outcome === "grant" ? [1, 1] : [0, 0])
    assert.equal(b.installed.controller.getState().call.call_id, "call-2")
    assert.equal(b.installed.controller.getState().cameraError, "permission-pending")
    assert.equal(b.preview.srcObject, null)
    assert.equal(pc.transceivers[1].sender.track, null)
    assert.equal(currentMicrophone.stops, 0)
    b.click(b.camera); await flush()
    assert.equal(cameraRequests, 2)
    assert.equal(pc.transceivers[1].sender.track, fresh)
    assert.equal(b.installed.controller.getState().cameraState, "enabled")
    assert.equal(b.installed.controller.getState().playbackState, "playing")
    assert.equal(pc.closed, undefined)
    assert.equal(pc.transceivers.length, 2)
    assert.equal(b.commands.filter(c => c.event === "offer").length, 2)
    assert.equal(b.commands.filter(c => c.event === "leave_call").length, 1)
    b.installed.dispose()
    assert.equal(currentMicrophone.stops, 1)
    assert.equal(fresh.stops, 1)
  })
}

for (const ownership of ["self", "elsewhere"]) {
  test(`${ownership} tab retains the latest complete accepted peer states through delayed projections`, async () => {
    const b = browser({snapshot: {call_id: "call", state: "active", role: "caller", ownership,
      media_intent: "audio", answer_mode: "audio"}, videoAvailable: "true"})
    await flush()
    const latest = {
      caller: {media_state_version: 5, microphone_muted: true, camera_enabled: true},
      recipient: {media_state_version: 2, microphone_muted: false, camera_enabled: false},
    }
    b.project({media_state: latest}); await flush()
    assert.deepEqual(b.installed.controller.getState().call.media_state, latest)
    assert.equal(b.nodes.get("direct-call-dock-media-state").hidden, false)
    assert.match(b.nodes.get("direct-call-dock-media-state").textContent, /Peer: microphone on, camera off/)
    if (ownership === "elsewhere") {
      assert.match(b.nodes.get("direct-call-dock-media-state").textContent, /Your call tab: microphone muted, camera on/)
    }
    b.project({media_state: {caller: {media_state_version: 4, microphone_muted: false, camera_enabled: false},
      recipient: {media_state_version: 3, microphone_muted: true, camera_enabled: false}}})
    await flush()
    assert.deepEqual(b.installed.controller.getState().call.media_state, {
      caller: latest.caller, recipient: {media_state_version: 3, microphone_muted: true, camera_enabled: false},
    })
    b.project({media_state: undefined}); await flush()
    assert.equal(b.installed.controller.getState().call.media_state.caller.camera_enabled, true)
    assert.equal(b.installed.controller.getState().call.ownership, ownership)
    assert.match(b.nodes.get("direct-call-dock-media-state").textContent, /Peer: microphone muted, camera off/)
    for (const invalid of [
      {media_state_version: 9_007_199_254_740_992, microphone_muted: false, camera_enabled: false},
      {media_state_version: 6, microphone_muted: "false", camera_enabled: false},
      {media_state_version: 6, microphone_muted: false},
      {media_state_version: 5, microphone_muted: false, camera_enabled: false},
    ]) {
      b.project({media_state: {caller: invalid}}); await flush()
      assert.deepEqual(b.installed.controller.getState().call.media_state.caller, latest.caller)
    }
    if (ownership === "elsewhere") {
      b.click(b.camera); b.click(b.mute); b.click(b.deafen); b.click(b.enable); await flush()
      assert.equal(b.commands.length, 0)
      assert.equal(b.mute.hidden, true)
      assert.equal(b.camera.hidden, true)
    }
    assert.equal(b.count().acquisitions, 0)
    assert.equal(b.preview.srcObject, null)
    assert.equal(b.peers.length, 0)
    b.project({state: "terminal", terminal_outcome: "ended"}); await flush()
    assert.equal(b.nodes.get("direct-call-dock-media-state").hidden, true)
    assert.equal(b.nodes.get("direct-call-dock-media-state").textContent, "")
    b.incoming({call_id: "replacement", state: "ringing", role: "recipient", ownership: "unclaimed",
      media_intent: "video", media_state: latest}); await flush()
    assert.equal(b.installed.controller.getState().call.media_state, undefined)
    assert.equal(b.count().acquisitions, 0)
    b.installed.dispose()
  })
}

for (const role of ["caller", "recipient"]) {
  for (const initiallyMuted of [false, true]) {
    test(`${role} camera acquisition and replacement keep independent ${initiallyMuted ? "muted" : "unmuted"} audio choices with reversed replies`, async t => {
      let grant, attach
      const replies = []
      const camera = videoTrack()
      const b = browser({role, videoAvailable: "true",
        ...(role === "recipient" ? {snapshot: videoInvitation()} : {}),
        permission: request => request.audio ? trackStream(ownedAudioTrack()) :
          new Promise(resolve => {grant = () => resolve(trackStream(camera))}),
        replaceCamera: track => track && new Promise(resolve => {attach = resolve}),
        mediaReply: payload => {
          const reply = heldCommandReply()
          replies.push({payload, reply})
          return reply
        },
      })
      t.after(() => b.installed.dispose())
      await flush(); b.click(role === "caller" ? b.start : b.answer); await flush()
      if (role === "caller") {b.project({state: "connecting", answer_mode: "audio"}); await flush()}
      b.project({state: "active"}); b.peers[0].ready(); await flush()
      const pc = b.peers[0], microphone = pc.transceivers[0].sender.track, playback = b.audio.srcObject
      if (initiallyMuted) b.click(b.mute)
      b.click(b.camera); await flush()
      b.click(b.deafen); b.click(b.mute); await flush()
      assert.equal(microphone.enabled, false)
      assert.equal(b.audio.muted, true)
      grant(); await flush()
      assert.equal(b.installed.controller.getState().cameraState, "attaching")
      assert.equal(replies.at(-1).payload.camera_enabled, false)
      attach(); await flush()
      assert.equal(replies.at(-1).payload.microphone_muted, true)
      assert.equal(replies.at(-1).payload.camera_enabled, true)
      b.click(b.deafen); await flush()
      assert.equal(microphone.enabled, initiallyMuted)
      assert.equal(b.audio.muted, false)
      assert.equal(b.installed.controller.getState().localMuted, !initiallyMuted)
      assert.equal(pc.transceivers[1].sender.track, camera)
      const latest = replies.at(-1)
      assert.equal(latest.payload.microphone_muted, !initiallyMuted)
      assert.equal(latest.payload.camera_enabled, true)
      latest.reply.settle("ok", latest.payload)
      for (const old of replies.slice(0, -1).reverse()) old.reply.settle("error", {reason: "stale_media_state"})
      await flush()
      assert.equal(microphone.stops, 0)
      assert.equal(microphone.enabled, initiallyMuted)
      assert.equal(camera.stops, 0)
      assert.equal(b.audio.srcObject, playback)
      assert.equal(b.installed.controller.getState().playbackState, "playing")
      assert.equal(pc.closed, undefined)
      assert.equal(b.peers.length, 1)
      assert.equal(pc.transceivers.length, 2)
      assert.equal(b.commands.filter(c => c.event === "offer").length, 1)
      assert.equal(b.commands.some(c => c.event === "leave_call"), false)
    })
  }
}


for (const stage of ["ringing", "active"]) {
  test(`${stage} video preview rebinds the same stream through authenticated navigation without recapture`, async () => {
    const b = browser({videoAvailable: "true"})
    await flush(); b.click(b.startVideo); await flush()
    if (stage === "active") {
      b.project({state: "connecting"}); await flush()
      b.peers[0].ready(); b.project({state: "active"}); await flush()
      b.click(b.mute); b.click(b.deafen); await flush()
    }
    const stream = b.preview.srcObject
    const commandCount = b.commands.length
    b.win.dispatchEvent(new Event("phx:page-loading-start"))
    const replacement = b.replacePreview()
    b.win.dispatchEvent(new Event("phx:page-loading-stop")); await flush()
    assert.equal(b.preview.srcObject, null)
    assert.equal(replacement.srcObject, stream)
    assert.deepEqual(stream.tracks, [b.tracks[1]])
    assert.equal(replacement.muted, true)
    assert.equal(replacement.playsInline, true)
    assert.equal(replacement.autoplay, true)
    assert.equal(b.count().acquisitions, 2)
    assert.equal(b.commands.length, commandCount)
    assert.equal(b.nodes.get("direct-call-local-preview-status").getAttribute("aria-live"), "off")
    assert.equal(b.installed.controller.getState().call.state, stage)
    assert.deepEqual(b.tracks.map(t => t.stops), [0, 0])
    if (stage === "active") {
      assert.equal(b.peers.length, 1)
      assert.equal(b.peers[0].transceivers[1].sender.track, b.tracks[1])
      assert.equal(b.tracks[0].enabled, false)
      assert.equal(b.audio.muted, true)
      b.click(b.deafen); await flush()
      assert.equal(b.audio.muted, false)
      assert.equal(b.tracks[0].enabled, false)
      b.click(b.mute); await flush()
      assert.equal(b.tracks[0].enabled, true)
      b.click(b.camera)
    } else b.tracks[1].end()
    assert.equal(replacement.srcObject, null)
    assert.equal(b.nodes.get("direct-call-local-preview-region").hidden, stage !== "active")
    assert.equal(b.tracks[0].stops, 0)
    b.installed.dispose()
  })
}

for (const replacement of ["retry", "element"]) {
  test(`obsolete preview play rejection cannot overwrite a current ${replacement} while audio remains usable`, async () => {
    let attempt = 0, rejectOld
    const b = browser({videoAvailable: "true", previewPlay: () => {
      attempt++
      if (attempt === 1) return Promise.reject(new Error("blocked"))
      if (attempt === 2) return new Promise((_, reject) => {rejectOld = reject})
    }})
    await flush(); b.click(b.startVideo); await flush()
    b.project({state: "connecting"}); await flush()
    b.peers[0].ready(); b.project({state: "active"}); await flush()
    const retry = b.nodes.get("direct-call-local-preview-retry")
    assert.equal(retry.hidden, false)
    b.click(retry); await flush()
    if (replacement === "retry") b.click(retry)
    else {
      b.replacePreview()
      b.win.dispatchEvent(new Event("phx:page-loading-stop"))
    }
    await flush()
    rejectOld(new Error("obsolete")); await flush()
    assert.equal(retry.hidden, true)
    assert.match(b.nodes.get("direct-call-local-preview-status").textContent, /Camera attached/)
    assert.equal(b.installed.controller.getState().call.state, "active")
    b.click(b.mute); b.click(b.deafen); await flush()
    assert.equal(b.tracks[0].enabled, false)
    assert.equal(b.audio.muted, true)
    assert.equal(b.peers[0].transceivers[1].sender.track, b.tracks[1])
    assert.equal(b.requests.length, 2)
    assert.equal(b.commands.some(c => c.event === "leave_call"), false)
    b.installed.dispose()
  })
}

test("keyboard preview recovery keeps focus visible and camera off returns it to a stable control", async () => {
  let blocked = true
  const b = browser({videoAvailable: "true", previewPlay: () => {
    if (blocked) return Promise.reject(new Error("blocked"))
  }})
  await flush(); b.click(b.startVideo); await flush()
  b.project({state: "connecting"}); await flush()
  b.peers[0].ready(); b.project({state: "active"}); await flush()
  const retry = b.nodes.get("direct-call-local-preview-retry")
  retry.focus(); blocked = false
  b.click(retry); await flush()
  assert.equal(retry.hidden, true)
  assert.equal(b.focused(), b.camera)
  b.click(b.camera)
  assert.equal(b.preview.srcObject, null)
  assert.equal(b.focused(), b.camera)
  assert.equal(b.camera.getAttribute("aria-label"), "Turn camera on")
  assert.equal(b.camera.getAttribute("aria-pressed"), undefined)
  assert.equal(b.camera.getAttribute("data-active"), "false")
  b.installed.dispose()
})

test("navigation through a missing preview element retains its stream and fences old playback before rebinding", async () => {
  let rejectOld
  const b = browser({videoAvailable: "true", previewPlay: () => new Promise((_, reject) => {rejectOld = reject})})
  await flush(); b.click(b.startVideo); await flush()
  const stream = b.preview.srcObject
  b.nodes.delete("direct-call-local-preview")
  rejectOld(new Error("detached")); await flush()
  assert.equal(b.nodes.get("direct-call-local-preview-retry").hidden, true)
  b.win.dispatchEvent(new Event("phx:page-loading-stop"))
  assert.equal(b.preview.srcObject, null)
  assert.equal(b.nodes.get("direct-call-local-preview-region").hidden, true)
  const replacement = b.replacePreview()
  b.win.dispatchEvent(new Event("phx:page-loading-stop")); await flush()
  assert.equal(replacement.srcObject, stream)
  assert.equal(b.count().acquisitions, 2)
  b.installed.dispose()
  assert.equal(replacement.srcObject, null)
  assert.deepEqual(b.tracks.map(t => t.stops), [1, 1])
  rejectOld(new Error("disposed")); await flush()
  assert.equal(b.nodes.get("direct-call-local-preview-retry").hidden, true)
})

test("camera replacement preview ignores the old track's pending play and announces only local playback failure", async () => {
  let rejectOld, attempt = 0
  const b = browser({videoAvailable: "true", previewPlay: () => {
    attempt++
    if (attempt === 1) return new Promise((_, reject) => {rejectOld = reject})
    return Promise.reject(new Error("blocked"))
  }})
  await flush(); b.click(b.startVideo); await flush()
  b.project({state: "connecting"}); await flush()
  b.peers[0].ready(); b.project({state: "active"}); await flush()
  const old = b.tracks[1], oldStream = b.preview.srcObject
  b.click(b.camera); await flush()
  b.click(b.camera); await flush()
  const fresh = b.tracks[2]
  assert.notEqual(b.preview.srcObject, oldStream)
  assert.deepEqual(b.preview.srcObject.tracks, [fresh])
  assert.equal(old.stops, 1)
  const status = b.nodes.get("direct-call-local-preview-status")
  assert.equal(status.getAttribute("aria-live"), "polite")
  assert.match(status.textContent, /Preview couldn't play/)
  rejectOld(new Error("old camera")); await flush()
  assert.match(status.textContent, /Preview couldn't play/)
  assert.equal(b.nodes.get("direct-call-local-preview-retry").hidden, false)
  assert.equal(b.peers[0].transceivers[1].sender.track, fresh)
  assert.equal(b.tracks[0].stops, 0)
  assert.equal(b.installed.controller.getState().call.state, "active")
  b.installed.dispose()
})

for (const role of ["caller", "recipient"]) {
  test(`${role} keyboard Cancel releases pending preparation and leaves focus on the visible Call surface`, async () => {
    let grantCamera
    const microphone = ownedAudioTrack()
    const b = browser({role, snapshot: role === "recipient" ? videoInvitation() : null,
      videoAvailable: "true", permission: request => request.audio ? trackStream(microphone)
        : new Promise(resolve => {grantCamera = resolve})})
    await flush(); b.click(role === "caller" ? b.startVideo : b.acceptVideo); await flush()
    const cancel = b.nodes.get(role === "caller" ? "direct-call-dock-cancel" : "direct-call-incoming-cancel-preparation")
    assert.equal(cancel.hidden, false)
    cancel.focus()
    if (role === "recipient") b.keydown("Escape")
    else b.click(cancel)
    assert.equal(cancel.hidden, true)
    assert.equal(b.focused(), b.nodes.get(role === "recipient" ? "direct-call-incoming-title" : "direct-call-focus-fallback"))
    assert.equal(microphone.stops, 1)
    const camera = videoTrack(); grantCamera(trackStream(camera)); await flush()
    assert.equal(camera.stops, 1)
    assert.equal(b.commands.some(c => ["start_call", "accept_call", "decline_call"].includes(c.event)), false)
    b.installed.dispose()
  })
}


test("public camera enable verifies the encoding budget before attachment without disturbing audio", async () => {
  let configuring, configured
  const b = browser({videoAvailable: "true", configureCamera: (parameters, sender) => {
    assert.equal(sender.track, null)
    configured = parameters
    return new Promise(resolve => {configuring = resolve})
  }})
  await flush(); b.click(b.start); await flush()
  b.project({state: "connecting"}); await flush()
  b.peers[0].ready(); b.project({state: "active"}); await flush()
  b.click(b.camera); await flush()
  const sender = b.peers[0].transceivers[1].sender
  assert.equal(b.installed.controller.getState().cameraState, "attaching")
  assert.equal(sender.track, null)
  assert.deepEqual(configured.encodings, [{active: true, maxBitrate: 1_200_000, maxFramerate: 24}])
  assert.deepEqual(configured.codecs, [{mimeType: "video/VP8"}])
  assert.equal(configured.transactionId, "fresh")
  b.click(b.mute); b.click(b.deafen); await flush()
  assert.equal(b.tracks[0].stops, 0)
  configuring(); await flush()
  assert.equal(sender.track, b.tracks[1])
  assert.equal(b.installed.controller.getState().cameraState, "enabled")
  assert.equal(b.installed.controller.getState().localMuted, true)
  assert.equal(b.audio.muted, true)
  assert.equal(b.peers.length, 1)
  assert.equal(b.commands.filter(c => c.event === "offer").length, 1)
  b.installed.dispose()
})


test("capture exceeding the profile during pending configuration releases only that camera", async () => {
  let configured
  const b = browser({videoAvailable: "true", configureCamera: () => new Promise(resolve => {configured = resolve})})
  await flush(); b.click(b.start); await flush()
  b.project({state: "connecting"}); await flush()
  b.peers[0].ready(); b.project({state: "active"}); await flush()
  b.click(b.camera); await flush()
  b.tracks[1].getSettings = () => ({width: 1920, height: 1080, frameRate: 30})
  configured(); await flush()
  assert.equal(b.installed.controller.getState().cameraState, "error")
  assert.match(b.installed.controller.getState().statusText, /unsupported/)
  assert.equal(b.tracks[1].stops, 1)
  assert.equal(b.tracks[0].stops, 0)
  assert.equal(b.peers[0].transceivers[1].sender.track, null)
  assert.equal(b.peers[0].closed, undefined)
  assert.equal(b.commands.some(c => c.event === "leave_call"), false)
  b.installed.dispose()
})


for (const failure of ["missing API", "missing get API", "missing encoding", "multiple encodings", "inactive encoding", "rejection", "readback", "readback bitrate", "readback fps", "readback throws"]) {
  test(`public camera ${failure} releases the attempted capture and permits a deliberate retry with audio intact`, async () => {
    let faulty = true, configured = false
    const b = browser({videoAvailable: "true",
      configureCamera: () => {
        configured = true
        if (faulty && failure === "rejection") throw Error("rejected")
      },
      cameraParameters: sender => {
        if (faulty && failure === "readback throws" && configured) throw Error("readback failed")
        if (faulty && failure === "readback" && configured) return {encodings: [{}]}
        if (faulty && failure === "readback bitrate" && configured) return {encodings: [{maxBitrate: 1_500_000, maxFramerate: 24}]}
        if (faulty && failure === "readback fps" && configured) return {encodings: [{maxBitrate: 1_200_000, maxFramerate: 30}]}
        if (faulty && failure === "missing encoding") return {encodings: []}
        if (faulty && failure === "multiple encodings") return {encodings: [{}, {}]}
        if (faulty && failure === "inactive encoding") return {encodings: [{active: false}]}
        return structuredClone(sender.parameters)
      }})
    await flush(); b.click(b.start); await flush()
    b.project({state: "connecting"}); await flush()
    b.peers[0].ready(); b.project({state: "active"}); await flush()
    const sender = b.peers[0].transceivers[1].sender, setParameters = sender.setParameters, getParameters = sender.getParameters
    if (failure === "missing API") sender.setParameters = undefined
    if (failure === "missing get API") sender.getParameters = undefined
    b.click(b.camera); await flush()
    assert.equal(b.installed.controller.getState().cameraState, "error")
    assert.match(b.installed.controller.getState().statusText, /Audio can continue/)
    assert.equal(b.tracks[1].stops, 1)
    assert.equal(b.tracks[0].stops, 0)
    assert.equal(sender.track, null)
    assert.equal(b.commands.some(c => c.event === "local_media_state" && c.payload.camera_enabled), false)
    assert.equal(b.peers[0].closed, undefined)
    assert.equal(b.commands.some(c => c.event === "leave_call"), false)
    faulty = false; sender.setParameters = setParameters; sender.getParameters = getParameters
    b.click(b.camera); await flush()
    assert.equal(sender.track, b.tracks[2])
    assert.equal(b.installed.controller.getState().cameraState, "enabled")
    b.click(b.mute); await flush()
    assert.equal(b.tracks[0].enabled, false)
    assert.equal(b.peers.length, 1)
    assert.equal(b.commands.filter(c => c.event === "offer").length, 1)
    b.installed.dispose()
  })
}

for (const outcome of ["success", "rejection"]) {
  test(`obsolete parameter ${outcome} cannot attach or detach a newer camera`, async () => {
    let settle, transactions = 0
    const b = browser({videoAvailable: "true", configureCamera: () => {
      if (++transactions === 1) return new Promise((resolve, reject) => {
        settle = () => outcome === "success" ? resolve() : reject(Error("late rejection"))
      })
    }})
    await flush(); b.click(b.start); await flush()
    b.project({state: "connecting"}); await flush()
    b.peers[0].ready(); b.project({state: "active"}); await flush()
    b.click(b.camera); await flush()
    assert.equal(transactions, 1)
    b.click(b.camera); await flush()
    assert.equal(b.tracks[1].stops, 1)
    b.click(b.camera); await flush()
    assert.equal(b.tracks[2].stops, 0)
    assert.equal(transactions, 1, "new configuration waits for the obsolete browser transaction")
    settle(); await flush()
    assert.equal(transactions, 2)
    assert.equal(b.peers[0].transceivers[1].sender.track, b.tracks[2])
    assert.equal(b.installed.controller.getState().cameraState, "enabled")
    assert.equal(b.tracks[2].stops, 0)
    assert.equal(b.tracks[0].stops, 0)
    assert.equal(b.commands.filter(c => c.event === "local_media_state" && c.payload.camera_enabled).length, 1)
    assert.equal(b.commands.filter(c => c.event === "offer").length, 1)
    assert.equal(b.commands.some(c => c.event === "leave_call"), false)
    b.installed.dispose()
  })
}

for (const role of ["caller", "recipient"]) {
  test(`${role} video-present sibling remains an observer across controls, events and reconnect`, async t => {
    const coarse = {
      caller: {media_state_version: 1, microphone_muted: false, camera_enabled: true},
      recipient: {media_state_version: 1, microphone_muted: false, camera_enabled: true},
    }
    const b = browser({role, videoAvailable: "true", snapshot: {
      call_id: "call", role, state: "active", ownership: "elsewhere", media_intent: "video",
      answer_mode: "video", media_state: coarse,
    }})
    t.after(() => b.installed.dispose())
    const video = {srcObject: null, dataset: {}, play() {throw Error("observer playback")}, pause() {}}
    b.nodes.set("direct-call-remote-video", video)
    b.nodes.set("direct-call-remote-video-region", {hidden: true})
    await flush()
    assert.equal(b.installed.controller.getState().presentation, "owned_elsewhere")
    assert.match(b.nodes.get("direct-call-dock-status").textContent, /another tab/)
    assert.match(b.nodes.get("direct-call-dock-media-state").textContent, /camera on/)
    for (const control of [b.enable, b.enableAudio, b.camera, b.mute, b.deafen, b.leave,
      b.nodes.get("direct-call-dock-preview"), b.nodes.get("direct-call-remote-video-retry")]) {
      assert.equal(control.hidden, true)
      b.click(control)
    }
    b.installed.controller.toggleCamera()
    b.installed.controller.toggleMute()
    b.installed.controller.toggleDeafen()
    b.installed.controller.leaveCall()
    b.media({call_id: "call", call_session_id: "foreign", signaling_session_id: "topic-session",
      negotiation_id: "foreign", video_presentation: {epoch: 1, camera_version: 1, rtp_timestamp: 9000}})
    b.loseSocket(); await flush()
    assert.equal(b.requests.length, 0)
    assert.equal(b.peers.length, 0)
    assert.equal(b.commands.length, 0)
    assert.equal(b.audio.srcObject, null)
    assert.equal(video.srcObject, null)
    assert.equal(b.preview.srcObject, null)
    assert.equal(b.count().plays, 0)
    assert.equal(b.nodes.get("direct-call-remote-video-region").hidden, true)
  })
}

test("video owner loss clears every sink and fences held playback and old receiver events", async t => {
  const pendingPlays = []
  let videoPlays = 0
  const b = browser({videoAvailable: "true"})
  t.after(() => b.installed.dispose())
  const video = {srcObject: null, dataset: {}, videoWidth: 960, videoHeight: 540, paused: false,
    play() {videoPlays++; return new Promise(resolve => {pendingPlays.push(resolve)})}, pause() {},
    requestVideoFrameCallback() {return 1}, cancelVideoFrameCallback() {}}
  b.nodes.set("direct-call-remote-video", video)
  b.nodes.set("direct-call-remote-video-region", {hidden: true})
  await flush(); b.click(b.startVideo); await flush()
  b.project({state: "active", answer_mode: "video", media_state: {
    recipient: {media_state_version: 1, microphone_muted: false, camera_enabled: true},
  }}); await flush()
  const pc = b.peers[0], receiver = pc.transceivers[1]
  pc.ready()
  const event = new Event("track")
  event.transceiver = receiver; event.track = receiver.receiver.track
  pc.dispatchEvent(event); await flush()
  const offer = b.commands.find(c => c.event === "offer").payload
  b.media({...offer, video_presentation: {epoch: 1, camera_version: 1, rtp_timestamp: 9000}})
  await flush()
  assert.ok(b.audio.srcObject)
  assert.ok(b.preview.srcObject)
  assert.ok(video.srcObject)
  assert.ok(videoPlays > 0)
  const retainedPlays = videoPlays
  const requests = b.requests.length
  b.project({ownership: "elsewhere"}); await flush()
  assert.equal(pc.closed, true)
  assert.deepEqual(b.tracks.map(track => track.stops), [1, 1])
  assert.equal(b.audio.srcObject, null)
  assert.equal(b.preview.srcObject, null)
  assert.equal(video.srcObject, null)
  for (const finish of pendingPlays) finish()
  pc.dispatchEvent(event)
  b.media({...offer, video_presentation: {epoch: 2, camera_version: 1, rtp_timestamp: 12000}})
  b.win.dispatchEvent(new Event("pageshow")); await flush()
  assert.equal(b.installed.controller.getState().presentation, "owned_elsewhere")
  assert.equal(b.installed.controller.getState().remoteVideoTrack, null)
  assert.equal(video.srcObject, null)
  assert.equal(videoPlays, retainedPlays)
  assert.equal(b.requests.length, requests)
  assert.equal(b.peers.length, 1)
})

for (const exit of ["leave", "failed", "closed", "microphone ended", "terminal",
  "channel loss", "authentication loss", "owner loss", "frozen resume"]) {
  const ticket = ["channel loss", "authentication loss", "owner loss", "frozen resume"].includes(exit) ? "ticket30" : "ticket29"
  test(`${ticket} ${exit} retires presented video within the browser clock and fences a replacement Call`, async t => {
    t.mock.timers.enable({apis: ["setTimeout"]})
    const {track: voice, controller: voiceController} = await capturedVoice()
    t.after(() => voiceController.leave())
    const pendingPlays = [], frames = new Map()
    let frameId = 0, finishDecode, holdDecode = false
    const video = Object.assign(new EventTarget(), {srcObject: null, dataset: {},
      videoWidth: 960, videoHeight: 540, paused: false,
      play() {return new Promise((resolve, reject) => pendingPlays.push({resolve, reject}))},
      pause() {}, requestVideoFrameCallback(fn) {frames.set(++frameId, fn); return frameId},
      cancelVideoFrameCallback(id) {frames.delete(id)}})
    const b = browser({videoAvailable: "true"})
    t.after(() => b.installed.dispose())
    b.nodes.set("direct-call-remote-video", video)
    b.nodes.set("direct-call-remote-video-region", {hidden: true})
    const receive = async pc => {
      const transceiver = pc.transceivers[1]
      transceiver.receiver.track.id = `camera-${b.peers.length}`
      transceiver.receiver.getStats = () => {
        const reports = new Map([["video", {type: "inbound-rtp", kind: "video",
          trackIdentifier: transceiver.receiver.track.id, framesDecoded: 2, keyFramesDecoded: 1}]])
        return holdDecode ? new Promise(resolve => {finishDecode = () => resolve(reports)}) : Promise.resolve(reports)
      }
      pc.ready()
      const event = new Event("track")
      event.transceiver = transceiver; event.track = transceiver.receiver.track
      pc.dispatchEvent(event); await flush()
      const offer = b.commands.filter(c => c.event === "offer").at(-1).payload
      b.media({...offer, video_presentation: {epoch: 1, camera_version: 1, rtp_timestamp: 9000}})
      await flush()
      return {event, offer}
    }
    await flush(); b.click(b.startVideo); await flush()
    const opposite = {recipient: {media_state_version: 1, microphone_muted: false, camera_enabled: true}}
    b.project({state: "active", answer_mode: "video", media_state: opposite}); await flush()
    const oldPeer = b.peers[0], oldTracks = [...b.tracks]
    const {event, offer} = await receive(oldPeer)
    const oldFrame = frames.values().next().value
    assert.equal(typeof oldFrame, "function")
    holdDecode = true
    frames.clear() // Native callbacks are one-shot, even while stats is pending.
    oldFrame(10, {width: 960, height: 540, presentedFrames: 1, mediaTime: 0.1, rtpTimestamp: 9000})
    assert.equal(typeof finishDecode, "function")
    const oldTimers = [...b.timers.values()]
    const observedAt = performance.now()
    if (exit === "leave") b.click(b.leave)
    else if (exit === "microphone ended") oldTracks[0].end()
    else if (exit === "terminal") b.project({state: "terminal", terminal_outcome: "interrupted"})
    else if (exit === "channel loss") b.loseChannel()
    else if (exit === "authentication loss") b.loseSocket()
    else if (exit === "owner loss") b.project({ownership: "elsewhere"})
    else if (exit === "frozen resume") {
      // No pagehide or server callback executed while the document was frozen.
      // The executing browser's clock begins when persisted pageshow arrives.
      b.snapshot({call_id: "call", state: "terminal", terminal_outcome: "failed"})
      const resumed = new Event("pageshow"); resumed.persisted = true
      b.win.dispatchEvent(resumed)
    }
    else {oldPeer.connectionState = exit; oldPeer.dispatchEvent(new Event("connectionstatechange"))}
    assert.ok(performance.now() - observedAt < 5000)
    assert.deepEqual(oldTracks.map(track => track.stops), [1, 1])
    assert.equal(oldPeer.closed, true)
    for (const sink of [b.audio, b.preview, video]) assert.equal(sink.srcObject, null)
    assert.equal(frames.size, 0)
    assert.equal(b.timers.size, 0)
    for (const name of ["pause", "playing"]) {
      assert.equal(getEventListeners(video, name).length, 0)
    }
    for (const transceiver of oldPeer.transceivers) {
      assert.equal(getEventListeners(transceiver.receiver.track, "ended").length, 0)
    }
    await flush()
    const captures = b.requests.length, mutations = b.commands.length
    // Keep decode/play promises held until the replacement exists below.
    oldFrame(15, {width: 960, height: 540, presentedFrames: 2, mediaTime: 0.2, rtpTimestamp: 9000})
    for (const timer of oldTimers) timer()
    oldPeer.dispatchEvent(event); await flush()
    assert.equal(b.requests.length, captures)
    assert.equal(b.peers.length, 1)
    assert.equal(b.commands.length, mutations)
    for (const sink of [b.audio, b.preview, video]) assert.equal(sink.srcObject, null)
    assert.equal(voice.stops, 0)
    assert.equal(b.installed.controller.getState().canControlCamera, false)
    if (["channel loss", "authentication loss"].includes(exit)) {
      b.snapshot({call_id: "call", state: "terminal", terminal_outcome: "failed"})
      b.installed.signaling.disconnect(); b.installed.signaling.connect(); await flush()
    }
    b.project({state: "terminal", terminal_outcome: "interrupted"}); await flush()
    holdDecode = false
    b.click(b.startVideo); await flush()
    b.project({state: "active", answer_mode: "video", media_state: opposite}); await flush()
    await receive(b.peers[1])
    const bindings = [b.audio.srcObject, b.preview.srcObject, video.srcObject]
    const commands = b.commands.length
    finishDecode()
    pendingPlays[0].resolve(); pendingPlays[1].reject(Error("obsolete playback"))
    oldFrame(20, {width: 960, height: 540, presentedFrames: 2, mediaTime: 0.2, rtpTimestamp: 9000})
    for (const timer of oldTimers) timer()
    oldPeer.dispatchEvent(event)
    b.media({...offer, video_presentation: {epoch: 2, camera_version: 1, rtp_timestamp: 12000}})
    oldTracks.forEach(track => track.end()); await flush()
    assert.deepEqual([b.audio.srcObject, b.preview.srcObject, video.srcObject], bindings)
    assert.equal(b.installed.controller.getState().remoteVideoState, "loading")
    assert.deepEqual(b.tracks.slice(2).map(track => track.stops), [0, 0])
    assert.equal(b.commands.length, commands)
    assert.equal(voice.stops, 0)
    b.installed.dispose(); b.installed.dispose()
    assert.ok(b.tracks.every(track => track.stops === 1))
    assert.equal(voice.stops, 0)
  })
}
