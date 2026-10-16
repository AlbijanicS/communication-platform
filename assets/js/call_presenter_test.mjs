import assert from "node:assert/strict"
import test from "node:test"

import {installCallPresenter} from "./call_presenter.js"

test("renders preparation, ringing, unavailable, and start failures into the compact dock", () => {
  const {controller, dock, status, peer, title, cancel, retry, dismiss, fallback, emit, ariaLiveWrites} = mountPresenter()

  assert.equal(dock.hidden, true)
  assert.equal(status.textContent, "")
  assert.equal(title.textContent, "Voice call")
  assert.equal(fallback.hidden, true)

  emit({
    presentation: "preflighting",
    statusText: "Preparing voice call…",
    peerName: "alice",
    mediaIntent: "audio",
    canCancel: true,
    canRetry: false,
    canDismiss: false,
    canFallbackToAudio: false,
    busy: true,
  })
  assert.equal(dock.hidden, false)
  assert.equal(dock.dataset.callDockState, "preflighting")
  assert.equal(status.textContent, "Preparing voice call…")
  assert.equal(title.textContent, "Voice call")
  assert.equal(peer.textContent, "alice")
  assert.equal(cancel.hidden, false)
  assert.equal(retry.hidden, true)
  assert.equal(dismiss.hidden, true)
  assert.equal(fallback.hidden, true)

  emit({
    presentation: "outgoing_ringing",
    statusText: "Calling alice…",
    peerName: "alice",
    mediaIntent: "video",
    canCancel: true,
    canRetry: false,
    canDismiss: false,
    canFallbackToAudio: false,
    busy: true,
  })
  assert.equal(status.textContent, "Calling alice…")
  assert.equal(title.textContent, "Video call")
  assert.equal(dock.dataset.callDockState, "outgoing_ringing")

  emit({
    presentation: "result",
    statusText: "Camera access is blocked. Try again when you're ready.",
    resultCode: "permission-denied",
    peerName: "alice",
    mediaIntent: "video",
    canCancel: false,
    canRetry: true,
    canDismiss: true,
    canFallbackToAudio: true,
    busy: false,
  })
  assert.equal(title.textContent, "Video call")
  assert.equal(fallback.hidden, false)
  assert.equal(retry.hidden, false)
  assert.equal(dismiss.hidden, false)

  emit({
    presentation: "result",
    statusText: "That person is busy.",
    resultCode: "busy",
    peerName: "alice",
    mediaIntent: "audio",
    canCancel: false,
    canRetry: true,
    canDismiss: true,
    canFallbackToAudio: false,
    busy: false,
  })
  assert.equal(status.textContent, "That person is busy.")
  assert.equal(title.textContent, "Voice call")
  assert.equal(cancel.hidden, true)
  assert.equal(retry.hidden, false)
  assert.equal(dismiss.hidden, false)
  assert.equal(fallback.hidden, true)

  emit({
    presentation: "unavailable",
    statusText: "Calling is unavailable. Reconnect, then try again.",
    canCancel: false,
    canRetry: true,
    canDismiss: true,
    canFallbackToAudio: false,
    busy: false,
  })
  assert.equal(status.getAttribute("aria-live"), "polite")
  assert.equal(status.getAttribute("role"), "status")
  assert.equal(ariaLiveWrites(), 0)
  assert.equal(status.textContent.includes("microphone connected"), false)
  controller.dispose()
})

test("delegates audio start, cancel, retry, and dismiss while ignoring disabled controls", () => {
  const {calls, document, startButton, disabledButton, cancel, retry, dismiss, presenter} = mountPresenter()

  document.dispatch("click", {target: startButton})
  assert.deepEqual(calls, [{
    startCall: [
      {
        id: "conversation-1",
        peer: {id: "user-2", username: "alice"},
      },
      "audio",
    ],
  }])

  document.dispatch("click", {target: disabledButton})
  assert.equal(calls.length, 1)

  document.dispatch("click", {target: cancel})
  document.dispatch("click", {target: retry})
  document.dispatch("click", {target: dismiss})
  assert.deepEqual(calls.slice(1), ["cancelCall", "retry", "dismiss"])

  presenter.dispose()
  document.dispatch("click", {target: startButton})
  assert.equal(calls.length, 4)
})

test("delegates video start and ignores disabled video controls", () => {
  const {calls, document, videoButton, disabledVideoButton, presenter} = mountPresenter()

  document.dispatch("click", {target: videoButton})
  assert.deepEqual(calls, [{
    startCall: [
      {
        id: "conversation-1",
        peer: {id: "user-2", username: "alice"},
      },
      "video",
    ],
  }])

  document.dispatch("click", {target: disabledVideoButton})
  assert.equal(calls.length, 1)
  presenter.dispose()
})

test("fallback calls only the explicit controller action and stays hidden otherwise", () => {
  const {calls, document, fallback, emit, presenter} = mountPresenter()

  document.dispatch("click", {target: fallback})
  assert.deepEqual(calls, ["fallbackToAudio"])

  emit({
    presentation: "result",
    statusText: "No camera is available.",
    mediaIntent: "video",
    canCancel: false,
    canRetry: true,
    canDismiss: true,
    canFallbackToAudio: true,
    busy: false,
  })
  assert.equal(fallback.hidden, false)

  emit({
    presentation: "result",
    statusText: "Microphone access is blocked. Try again when you're ready.",
    mediaIntent: "video",
    canCancel: false,
    canRetry: true,
    canDismiss: true,
    canFallbackToAudio: false,
    busy: false,
  })
  assert.equal(fallback.hidden, true)
  presenter.dispose()
})

test("navigation start cancels local preflight only", () => {
  const {calls, window, emit, presenter, document, cancel} = mountPresenter()

  emit({
    presentation: "preflighting",
    statusText: "Preparing video call…",
    mediaIntent: "video",
    canCancel: true,
    canRetry: false,
    canDismiss: false,
    canFallbackToAudio: false,
    busy: true,
  })
  window.trigger("phx:page-loading-start")
  assert.deepEqual(calls, ["cancelLocalPreparation"])

  emit({
    presentation: "outgoing_ringing",
    statusText: "Calling alice…",
    mediaIntent: "video",
    canCancel: true,
    canRetry: false,
    canDismiss: false,
    canFallbackToAudio: false,
    busy: true,
  })
  window.trigger("phx:page-loading-start")
  assert.deepEqual(calls, ["cancelLocalPreparation", "cancelLocalPreparation"])
  assert.equal(calls.includes("cancelCall"), false)
  assert.equal(calls.includes("releaseCues"), false)

  document.dispatch("click", {target: cancel})
  assert.equal(calls.at(-1), "cancelCall")
  presenter.dispose()
})

test("LiveView navigation preserves an incoming ringing cue election", () => {
  const {calls, window, emit, presenter} = mountPresenter()

  emit({
    presentation: "incoming_ringing",
    statusText: "alice is inviting you to an audio call.",
    mediaIntent: "audio",
    canAcceptAudio: true,
    canDecline: true,
    busy: true,
  })
  window.trigger("phx:page-loading-start")
  window.trigger("phx:page-loading-stop")

  assert.deepEqual(calls.filter(call => call !== "cancelLocalPreparation"), [])
  presenter.dispose()
})

test("page loading stop re-syncs header busy state without installing a second listener", () => {
  const {startButton, videoButton, window, emit, presenter, document, calls} = mountPresenter()

  emit({
    presentation: "preflighting",
    statusText: "Preparing voice call…",
    peerName: "alice",
    canCancel: true,
    canRetry: false,
    canDismiss: false,
    canFallbackToAudio: false,
    busy: true,
  })
  assert.equal(startButton.getAttribute("aria-busy"), "true")
  assert.equal(videoButton.getAttribute("aria-busy"), "true")

  startButton.removeAttribute("aria-busy")
  videoButton.removeAttribute("aria-busy")
  window.trigger("phx:page-loading-stop")
  assert.equal(startButton.getAttribute("aria-busy"), "true")
  assert.equal(videoButton.getAttribute("aria-busy"), "true")

  presenter.dispose()
  window.trigger("phx:page-loading-stop")
  window.trigger("phx:page-loading-start")
  startButton.removeAttribute("aria-busy")
  window.trigger("phx:page-loading-stop")
  assert.equal(startButton.hasAttribute("aria-busy"), false)
  document.dispatch("click", {target: startButton})
  document.dispatch("click", {target: videoButton})
  assert.equal(calls.length, 0)
})

test("incoming audio dialog renders, delegates actions, traps focus, and Escape declines", () => {
  const {
    calls,
    document,
    emit,
    backdrop,
    incomingTitle,
    incomingCaller,
    incomingIntent,
    incomingStatus,
    acceptAudio,
    decline,
    priorFocus,
    presenter,
  } = mountPresenter()
  priorFocus.focus()

  emit({
    presentation: "incoming_ringing",
    statusText: "alice is inviting you to an audio call.",
    peerName: "alice",
    mediaIntent: "audio",
    canAcceptAudio: true,
    canDecline: true,
    canCancel: false,
    canRetry: false,
    canDismiss: false,
    canFallbackToAudio: false,
    canLeave: false,
    busy: true,
  })
  assert.equal(backdrop.hidden, false)
  assert.equal(incomingCaller.textContent, "alice")
  assert.equal(incomingIntent.textContent, "Audio invitation")
  assert.equal(incomingStatus.textContent, "alice is inviting you to an audio call.")
  assert.equal(document.activeElement, incomingTitle)
  assert.equal(acceptAudio.getAttribute("aria-label"), "Accept audio call from alice")
  assert.equal(decline.getAttribute("aria-label"), "Decline call from alice")

  document.dispatch("click", {target: acceptAudio})
  document.dispatch("click", {target: decline})
  assert.deepEqual(calls.slice(-2), [{acceptCall: "audio"}, "declineCall"])

  let prevented = 0
  document.dispatch("keydown", {key: "Tab", preventDefault() { prevented += 1 }})
  assert.equal(document.activeElement, decline)
  document.activeElement = acceptAudio
  document.dispatch("keydown", {key: "Tab", preventDefault() { prevented += 1 }})
  assert.equal(document.activeElement, decline)
  document.dispatch("keydown", {key: "Escape", preventDefault() { prevented += 1 }})
  assert.equal(calls.at(-1), "declineCall")
  assert.equal(prevented, 3)

  emit({presentation: "connecting", canLeave: true, canCancel: false, busy: true})
  assert.equal(backdrop.hidden, true)
  assert.equal(document.activeElement, priorFocus)
  presenter.dispose()
})

test("incoming video dialog renders three intent-matched actions and delegates both answer modes", () => {
  const {
    calls,
    document,
    emit,
    incomingIntent,
    acceptAudio,
    acceptVideo,
    answerWithoutVideo,
    decline,
    presenter,
  } = mountPresenter()

  emit({
    presentation: "incoming_ringing",
    statusText: "alice is inviting you to a video call.",
    peerName: "alice",
    mediaIntent: "video",
    canAcceptAudio: false,
    canAcceptVideo: true,
    canAnswerWithoutVideo: true,
    canDecline: true,
    canLeave: false,
    busy: true,
  })

  assert.equal(incomingIntent.textContent, "Video invitation")
  assert.equal(acceptAudio.hidden, true)
  assert.equal(acceptVideo.hidden, false)
  assert.equal(answerWithoutVideo.hidden, false)
  assert.equal(decline.hidden, false)
  assert.equal(acceptVideo.getAttribute("aria-label"), "Accept video call from alice")
  assert.equal(
    answerWithoutVideo.getAttribute("aria-label"),
    "Answer call from alice without video",
  )

  document.dispatch("click", {target: acceptVideo})
  document.dispatch("click", {target: answerWithoutVideo})
  assert.deepEqual(calls.slice(-2), [{acceptCall: "video"}, {acceptCall: "audio"}])

  emit({
    presentation: "incoming_preflighting",
    statusText: "Preparing microphone and camera…",
    peerName: "alice",
    mediaIntent: "video",
    canAcceptAudio: false,
    canAcceptVideo: false,
    canAnswerWithoutVideo: false,
    canDecline: true,
    busy: true,
  })
  assert.equal(acceptVideo.disabled, true)
  assert.equal(answerWithoutVideo.disabled, true)
  assert.equal(decline.disabled, false)
  presenter.dispose()
})

test("incoming ringing uses only the dialog so the dock cannot duplicate the announcement", () => {
  const {dock, backdrop, emit, presenter} = mountPresenter()

  emit({
    presentation: "incoming_ringing",
    statusText: "alice is inviting you to an audio call.",
    peerName: "alice",
    mediaIntent: "audio",
    canAcceptAudio: true,
    canDecline: true,
    busy: true,
  })
  assert.equal(backdrop.hidden, false)
  assert.equal(dock.hidden, true)

  emit({
    presentation: "incoming_preflighting",
    statusText: "Preparing microphone…",
    peerName: "alice",
    mediaIntent: "audio",
    canAcceptAudio: false,
    canDecline: true,
    busy: true,
  })
  assert.equal(backdrop.hidden, false)
  assert.equal(dock.hidden, true)

  emit({
    presentation: "connecting",
    statusText: "Connecting with fake call setup…",
    peerName: "alice",
    mediaIntent: "audio",
    canLeave: true,
    busy: true,
  })
  assert.equal(backdrop.hidden, true)
  assert.equal(dock.hidden, false)

  presenter.dispose()
})

test("the dialog traps Tab both ways, declines once on Escape, and untraps when it closes", () => {
  const {
    calls,
    document,
    emit,
    acceptAudio,
    decline,
    incomingStatus,
    incomingStatusWrites,
    incomingTitle,
    priorFocus,
    presenter,
  } = mountPresenter()
  priorFocus.focus()

  const ringing = {
    presentation: "incoming_ringing",
    statusText: "alice is inviting you to an audio call.",
    peerName: "alice",
    mediaIntent: "audio",
    canAcceptAudio: true,
    canDecline: true,
    canCancel: false,
    canLeave: false,
    busy: true,
  }
  emit(ringing)
  assert.equal(document.activeElement, incomingTitle)

  let prevented = 0
  const tab = overrides =>
    document.dispatch("keydown", {key: "Tab", preventDefault() { prevented += 1 }, ...overrides})

  document.activeElement = acceptAudio
  tab({})
  assert.equal(document.activeElement, decline)

  document.activeElement = decline
  tab({shiftKey: true})
  assert.equal(document.activeElement, acceptAudio)

  document.activeElement = null
  tab({})
  assert.equal(document.activeElement, decline)

  const declinesBefore = calls.filter(call => call === "declineCall").length
  document.dispatch("keydown", {key: "Escape", preventDefault() { prevented += 1 }})
  assert.equal(calls.filter(call => call === "declineCall").length, declinesBefore + 1)
  assert.equal(calls.includes("dismiss"), false)

  const statusWritesBefore = incomingStatusWrites()
  emit(ringing)
  assert.equal(incomingStatusWrites(), statusWritesBefore)
  assert.equal(incomingStatus.textContent, ringing.statusText)

  emit({
    presentation: "active",
    statusText: "Call active — no real media is connected.",
    peerName: "alice",
    mediaIntent: "audio",
    canLeave: true,
    busy: true,
  })
  assert.equal(document.activeElement, priorFocus)

  const preventedAfterClose = prevented
  document.activeElement = priorFocus
  tab({})
  assert.equal(prevented, preventedAfterClose)
  assert.equal(document.activeElement, priorFocus)

  document.dispatch("keydown", {key: "Escape", preventDefault() { prevented += 1 }})
  assert.equal(calls.filter(call => call === "declineCall").length, declinesBefore + 1)
  assert.equal(prevented, preventedAfterClose)
  presenter.dispose()
})

test("active dock exposes Leave while backdrop clicks do nothing and detached focus uses fallback", () => {
  const {calls, document, emit, backdrop, leave, priorFocus, focusFallback, presenter} = mountPresenter()
  priorFocus.focus()
  emit({
    presentation: "incoming_ringing",
    statusText: "Incoming audio call.",
    peerName: "alice",
    canAcceptAudio: true,
    canDecline: true,
    canCancel: false,
    canLeave: false,
    busy: true,
  })
  document.dispatch("click", {target: backdrop})
  assert.deepEqual(calls, [])

  priorFocus.isConnected = false
  emit({
    presentation: "active",
    statusText: "Call active — no real audio is connected.",
    peerName: "alice",
    mediaIntent: "audio",
    canLeave: true,
    canCancel: false,
    canRetry: false,
    canDismiss: false,
    canFallbackToAudio: false,
    busy: true,
  })
  assert.equal(document.activeElement, focusFallback)
  assert.equal(leave.hidden, false)
  document.dispatch("click", {target: leave})
  assert.equal(calls.at(-1), "leaveCall")
  presenter.dispose()
})

test("owner-elsewhere dock announces once and closes the dialog without focus theft", () => {
  const {
    calls,
    document,
    emit,
    backdrop,
    status,
    cancel,
    leave,
    retry,
    dismiss,
    priorFocus,
    acceptAudio,
    decline,
    statusWrites,
    presenter,
  } = mountPresenter()

  priorFocus.focus()
  emit({
    presentation: "incoming_ringing",
    statusText: "alice is inviting you to an audio call.",
    peerName: "alice",
    mediaIntent: "audio",
    canAcceptAudio: true,
    canDecline: true,
    busy: true,
  })
  assert.equal(backdrop.hidden, false)
  assert.equal(acceptAudio.hidden, false)

  const writesBefore = statusWrites()

  emit({
    presentation: "owned_elsewhere",
    statusText: "Call active in another tab.",
    peerName: "alice",
    mediaIntent: "audio",
    canCancel: false,
    canLeave: false,
    canRetry: false,
    canDismiss: false,
    canFallbackToAudio: false,
    busy: true,
  })

  assert.equal(backdrop.hidden, true)
  assert.equal(status.textContent, "Call active in another tab.")
  assert.equal(document.activeElement, priorFocus)
  assert.equal(cancel.hidden, true)
  assert.equal(leave.hidden, true)
  assert.equal(retry.hidden, true)
  assert.equal(dismiss.hidden, true)
  assert.equal(statusWrites(), writesBefore + 1)

  emit({
    presentation: "owned_elsewhere",
    statusText: "Call active in another tab.",
    peerName: "alice",
    mediaIntent: "audio",
    canCancel: false,
    canLeave: false,
    busy: true,
  })
  assert.equal(statusWrites(), writesBefore + 1)
  presenter.dispose()
})

test("caller sibling ringing shows honest copy without a cancel control", () => {
  const {document, emit, cancel, status, presenter} = mountPresenter()

  emit({
    presentation: "outgoing_ringing",
    statusText: "Calling alice from another tab…",
    peerName: "alice",
    mediaIntent: "video",
    canCancel: false,
    canLeave: false,
    canRetry: false,
    canDismiss: false,
    busy: true,
  })

  assert.equal(status.textContent, "Calling alice from another tab…")
  assert.equal(cancel.hidden, true)

  document.dispatch("click", {target: cancel})
  presenter.dispose()
})

test("accepted owners keep named camera-off participant areas without capture", () => {
  const h = mountPresenter()
  h.emit({presentation: "active", call: {ownership: "self"}, peerName: "Alice",
    cameraState: "off", remoteCameraEnabled: false})
  const node = id => h.document.getElementById(`direct-call-${id}`)
  assert.equal(node("remote-video-region").hidden, false)
  assert.equal(node("local-preview-region").hidden, false)
  assert.equal(node("remote-video-name").textContent, "Alice")
  assert.equal(node("remote-video-avatar").textContent, "A")
  assert.equal(node("remote-video-placeholder").hidden, false)
  assert.equal(node("remote-video-status").textContent, "Camera off")
  assert.equal(node("local-preview-placeholder").hidden, false)
  assert.equal(node("local-preview-status").textContent, "Camera off")
  assert.equal(node("remote-video").srcObject, null)
  assert.equal(node("local-preview").srcObject, null)
  h.emit({presentation: "active", call: {ownership: "elsewhere"}})
  assert.equal(node("remote-video-region").hidden, true)
  assert.equal(node("local-preview-region").hidden, true)
  h.presenter.dispose()
})

test("remote surface is muted and inline, accepted off covers it, and Leave clears binding", () => {
  const h = mountPresenter(), track = {kind: "video", readyState: "live"}
  const state = {presentation: "active", call: {ownership: "self"}, remoteCameraEnabled: true, remoteVideoTrack: track}
  h.emit(state)
  const video = h.document.getElementById("direct-call-remote-video")
  const region = h.document.getElementById("direct-call-remote-video-region")
  assert.equal(region.hidden, false)
  assert.deepEqual(video.srcObject.tracks, [track])
  assert.equal(video.muted, true)
  assert.equal(video.playsInline, true)
  const stream = video.srcObject
  h.emit({...state, localMuted: true})
  assert.equal(video.srcObject, stream)
  h.emit({...state, remoteCameraEnabled: false})
  assert.equal(region.hidden, false)
  assert.equal(video.style?.visibility ?? "hidden", "hidden")
  assert.equal(h.document.getElementById("direct-call-remote-video-placeholder").hidden, false)
  assert.equal(video.srcObject, null)
  h.emit(state)
  h.emit({presentation: "result", call: null})
  assert.equal(video.srcObject, null)
  assert.equal(region.hidden, true)
  h.presenter.dispose()
})

function presentedRemote(h, readDecode = async () => ({framesDecoded: 1, keyFramesDecoded: 1})) {
  const video = h.document.getElementById("direct-call-remote-video")
  video.style = {}
  const callbacks = new Map()
  let id = 0
  Object.assign(video, eventTarget(), {videoWidth: 960, videoHeight: 540, paused: false,
    play: async () => {}, pause() {},
    requestVideoFrameCallback(fn) {callbacks.set(++id, fn); return id},
    cancelVideoFrameCallback(id) {callbacks.delete(id)},
  })
  const fence = {rtp_timestamp: 9000}
  const binding = {receiver: {}, isCurrent: () => true, readDecode, presentation: () => fence}
  const state = {presentation: "active", call: {ownership: "self", call_id: "call"},
    remoteCameraEnabled: true, remoteVideoTrack: {kind: "video", readyState: "live"}, remoteVideoBinding: binding}
  return {video, state, callbacks, async frame(metadata = {}, now = 10) {
    const [id, fn] = callbacks.entries().next().value
    callbacks.delete(id)
    fn(now, {width: 960, height: 540, presentedFrames: 1, mediaTime: 0.1, rtpTimestamp: 9000, ...metadata})
    for (let i = 0; i < 8; i++) await Promise.resolve()
  }}
}

test("one-camera watcher keeps Self placeholder while remote loading, ready and interruption stay distinct", async () => {
  const h = mountPresenter(), r = presentedRemote(h)
  const node = id => h.document.getElementById(`direct-call-${id}`)
  h.emit({...r.state, cameraState: "pending"})
  assert.equal(node("local-preview-status").textContent, "Preparing camera…")
  assert.equal(node("local-preview-placeholder").hidden, false)
  assert.equal(node("local-preview").srcObject, null)
  assert.equal(node("remote-video-status").textContent, "Waiting for video…")
  assert.equal(node("remote-video-placeholder").hidden, false)
  await r.frame()
  assert.equal(node("remote-video-placeholder").hidden, true)
  assert.equal(node("remote-video-status").textContent, "Video ready")
  h.advance(5000)
  assert.equal(node("remote-video-placeholder").hidden, false)
  assert.match(node("remote-video-status").textContent, /Video interrupted/)
  assert.equal(node("local-preview-status").textContent, "Preparing camera…")
  h.emit({...r.state, remoteCameraEnabled: false, cameraState: "error"})
  assert.equal(node("remote-video-status").textContent, "Camera off")
  assert.equal(node("local-preview-status").textContent, "Camera unavailable")
  assert.equal(node("remote-video-region").hidden, false)
  h.presenter.dispose()
})

test("blocked remote video retries the retained stream on the gesture and waits for fresh presentation", async () => {
  const h = mountPresenter(), r = presentedRemote(h)
  const retry = h.document.getElementById("direct-call-remote-video-retry")
  let hidden = retry.hidden
  Object.defineProperty(retry, "hidden", {get: () => hidden, set(value) {
    hidden = value
    if (value && h.document.activeElement === retry) h.document.activeElement = null
  }})
  let plays = 0, resolve
  r.video.play = () => {
    plays++
    if (plays === 1) return Promise.reject(new Error("autoplay blocked"))
    return new Promise(done => {resolve = done})
  }
  h.emit(r.state)
  for (let i = 0; i < 8; i++) await Promise.resolve()
  assert.equal(r.video.dataset.remoteVideoState, "blocked")
  assert.equal(retry.hidden, false)
  const stream = r.video.srcObject
  retry.focus()
  h.document.dispatch("click", {target: retry})
  assert.equal(plays, 2, "native play runs inside the deliberate click")
  assert.equal(r.video.srcObject, stream)
  assert.equal(retry.hidden, true)
  assert.equal(h.document.activeElement.id, "direct-call-dock-title")
  h.document.dispatch("click", {target: retry})
  h.emit({...r.state, localMuted: true, localDeafened: true})
  h.window.trigger("phx:page-loading-stop")
  assert.equal(plays, 2)
  resolve()
  for (let i = 0; i < 8; i++) await Promise.resolve()
  assert.equal(r.video.dataset.remoteVideoState, "loading")
  await r.frame()
  assert.equal(r.video.dataset.remoteVideoState, "ready")
  h.document.dispatch("click", {target: retry})
  assert.equal(plays, 2)
  assert.equal(r.video.muted, true)
  h.presenter.dispose()
})

test("a queued initial play cannot run after its playback epoch is suspended", async () => {
  const h = mountPresenter(), r = presentedRemote(h)
  let plays = 0
  r.video.play = () => {plays++; return Promise.resolve()}
  h.emit(r.state)
  h.document.dispatch("freeze"); h.document.dispatch("resume")
  for (let i = 0; i < 8; i++) await Promise.resolve()
  assert.equal(plays, 0)
  h.presenter.dispose()
})

test("retry rejection reoffers local playback and obsolete native frames cannot uncover blocked video", async () => {
  const h = mountPresenter(), r = presentedRemote(h)
  const retry = h.document.getElementById("direct-call-remote-video-retry")
  r.video.play = () => {throw new Error("blocked synchronously")}
  h.emit(r.state)
  const obsolete = [...r.callbacks.values()][0]
  for (let i = 0; i < 8; i++) await Promise.resolve()
  obsolete(10, {width: 960, height: 540, presentedFrames: 1, mediaTime: 0.1, rtpTimestamp: 9000})
  for (let i = 0; i < 8; i++) await Promise.resolve()
  assert.equal(r.video.dataset.remoteVideoState, "blocked")
  assert.equal(r.video.style.visibility, "hidden")
  let reject
  r.video.play = () => new Promise((_resolve, fail) => {reject = fail})
  h.document.dispatch("click", {target: retry})
  reject(new Error("still blocked"))
  for (let i = 0; i < 8; i++) await Promise.resolve()
  assert.equal(retry.hidden, false)
  r.video.play = async () => {}
  h.document.dispatch("click", {target: retry})
  await r.frame()
  assert.equal(r.video.dataset.remoteVideoState, "ready")
  h.presenter.dispose()
})

test("accepted off restores retry focus while preserving its participant region", async () => {
  const h = mountPresenter(), r = presentedRemote(h)
  const retry = h.document.getElementById("direct-call-remote-video-retry")
  const region = h.document.getElementById("direct-call-remote-video-region")
  let hidden = region.hidden
  Object.defineProperty(region, "hidden", {get: () => hidden, set(value) {
    hidden = value
    if (value && h.document.activeElement === retry) h.document.activeElement = null
  }})
  r.video.play = async () => {throw new Error("blocked")}
  h.emit(r.state)
  for (let i = 0; i < 8; i++) await Promise.resolve()
  retry.focus()
  h.emit({...r.state, remoteCameraEnabled: false})
  assert.equal(h.document.activeElement?.id, "direct-call-dock-title")
  assert.equal(region.hidden, false)
  assert.equal(retry.hidden, true)
  assert.equal(r.video.srcObject, null)
  h.presenter.dispose()
})

for (const exit of ["off", "owner loss", "source end", "terminal", "replacement", "new call", "dispose"]) {
  for (const succeeds of [true, false]) {
    test(`held video retry ${succeeds ? "fulfillment" : "rejection"} after ${exit} cannot change current media`, async () => {
      let decoded = {framesDecoded: 1, keyFramesDecoded: 1}
      const h = mountPresenter(), r = presentedRemote(h, async () => decoded)
      r.video.play = async () => {throw new Error("autoplay blocked")}
      h.emit(r.state)
      for (let i = 0; i < 8; i++) await Promise.resolve()
      let finish
      r.video.play = () => new Promise((resolve, reject) => {finish = succeeds ? resolve : reject})
      h.document.dispatch("click", {target: h.document.getElementById("direct-call-remote-video-retry")})
      const oldStream = r.video.srcObject
      if (exit === "dispose") h.presenter.dispose()
      else {
        const state = {...r.state}
        if (exit === "off") state.remoteCameraEnabled = false
        if (exit === "owner loss") state.call = {...state.call, ownership: "elsewhere"}
        if (exit === "source end") state.remoteVideoTrack.readyState = "ended"
        if (exit === "terminal") {state.presentation = "result"; state.call = null}
        if (exit === "replacement") state.remoteVideoBinding = {...state.remoteVideoBinding, receiver: {}}
        if (exit === "new call") state.call = {...state.call, call_id: "new-call"}
        r.video.play = async () => {}
        h.emit(state)
        if (["replacement", "new call"].includes(exit)) {
          for (let i = 0; i < 8; i++) await Promise.resolve()
          decoded = {framesDecoded: 2, keyFramesDecoded: 2}
          await r.frame()
          assert.equal(r.video.dataset.remoteVideoState, "ready")
        }
      }
      const currentStream = r.video.srcObject, state = r.video.dataset.remoteVideoState
      assert.notEqual(currentStream, oldStream)
      const before = h.calls.length
      finish(succeeds ? undefined : new Error("late failure"))
      for (let i = 0; i < 8; i++) await Promise.resolve()
      assert.equal(r.video.srcObject, currentStream)
      assert.equal(r.video.dataset.remoteVideoState, state)
      assert.equal(h.calls.length, before)
      assert.equal(h.document.getElementById("direct-call-remote-video-retry").hidden, true)
      h.presenter.dispose()
    })
  }
}

test("remote video waits for current decoded keyframe and positive presented dimensions, never play alone", async () => {
  const h = mountPresenter()
  let stats = {framesDecoded: 1, keyFramesDecoded: 0}
  const r = presentedRemote(h, async () => stats)
  h.emit(r.state)
  await Promise.resolve()
  assert.equal(r.video.dataset.remoteVideoState, "loading")
  await r.frame()
  assert.equal(r.video.dataset.remoteVideoState, "loading")
  stats = {framesDecoded: 2, keyFramesDecoded: 1}
  await r.frame({presentedFrames: 2, mediaTime: 0.2, width: 0})
  assert.equal(r.video.dataset.remoteVideoState, "loading")
  await r.frame({presentedFrames: 3, mediaTime: 0.3})
  assert.equal(r.video.dataset.remoteVideoState, "ready")
  assert.equal(r.video.muted && r.video.playsInline, true)
  assert.equal(h.calls.at(-1).remoteVideoState, "ready")
  h.presenter.dispose()
})

test("returned route stays covered through buffered and late-repaired old frames", async () => {
  const h = mountPresenter()
  const r = presentedRemote(h)
  h.emit(r.state)
  await r.frame()
  assert.equal(r.video.dataset.remoteVideoState, "ready")
  const obsolete = r.state.remoteVideoBinding
  h.emit({...r.state, remoteCameraEnabled: false})
  assert.equal(r.video.srcObject, null)
  assert.equal(r.video.dataset.remoteVideoState, "off")
  let fence = {rtp_timestamp: 15000}
  let decoded = {framesDecoded: 20, keyFramesDecoded: 8}
  r.state.remoteVideoBinding = {receiver: obsolete.receiver, isCurrent: () => true,
    readDecode: async () => decoded,
    presentation: () => fence}
  h.emit(r.state)
  for (let i = 0; i < 8; i++) await Promise.resolve()
  await r.frame({rtpTimestamp: 9000, mediaTime: 999, presentedFrames: 999})
  assert.equal(r.video.dataset.remoteVideoState, "loading")
  assert.equal(r.video.style.visibility, "hidden")
  await r.frame({rtpTimestamp: 12000, presentedFrames: 2, mediaTime: 0.2})
  assert.equal(r.video.dataset.remoteVideoState, "loading")
  await r.frame({rtpTimestamp: 15000, presentedFrames: 3, mediaTime: 0.3})
  assert.equal(r.video.dataset.remoteVideoState, "loading")
  decoded = {framesDecoded: 21, keyFramesDecoded: 9}
  await r.frame({rtpTimestamp: 18000, presentedFrames: 4, mediaTime: 0.4})
  assert.equal(r.video.dataset.remoteVideoState, "loading")
  fence = {rtp_timestamp: 21000}
  await r.frame({rtpTimestamp: 21000, presentedFrames: 5, mediaTime: 0.5})
  assert.equal(r.video.dataset.remoteVideoState, "ready")
  assert.equal(r.video.style.visibility, "visible")
  assert.notEqual(r.state.remoteVideoBinding, obsolete)
  h.presenter.dispose()
})

test("replayed old metadata cannot advance the new route presentation watermark", async () => {
  const h = mountPresenter(), r = presentedRemote(h)
  const fence = {rtp_timestamp: 15000}
  r.state.remoteVideoBinding.presentation = () => fence
  h.emit(r.state)
  await r.frame({rtpTimestamp: 9000, mediaTime: 999, presentedFrames: 999})
  assert.equal(r.video.dataset.remoteVideoState, "loading")
  await r.frame({rtpTimestamp: 15000, mediaTime: 0.2, presentedFrames: 2})
  assert.equal(r.video.dataset.remoteVideoState, "ready")
  h.presenter.dispose()
})

test("rebuilt video confirms an already presented exact keyframe when cached native stats catch up", async () => {
  const h = mountPresenter(), r = presentedRemote(h)
  h.emit(r.state); await r.frame()
  let decoded = {framesDecoded: 20, keyFramesDecoded: 8, sampleTime: 200}
  const fence = {rtp_timestamp: 15000}
  r.state.remoteVideoBinding = {receiver: r.state.remoteVideoBinding.receiver, isCurrent: () => true,
    readDecode: async () => decoded, presentation: timestamp => timestamp === 15000 ? fence : null}
  h.emit(r.state)
  for (let i = 0; i < 8; i++) await Promise.resolve()
  await r.frame({rtpTimestamp: 15000, receiveTime: 220})
  assert.equal(r.video.dataset.remoteVideoState, "loading")
  // The next native snapshot includes the keyframe already observed above.
  decoded = {framesDecoded: 22, keyFramesDecoded: 9, sampleTime: 260}
  await r.frame({rtpTimestamp: 18000, receiveTime: 250, presentedFrames: 2, mediaTime: 0.2})
  assert.equal(r.video.dataset.remoteVideoState, "ready")
  assert.equal(r.video.style.visibility, "visible")
  h.presenter.dispose()
})

test("rebuilt video correlates a native frame observed before its current keyframe marker", async () => {
  const h = mountPresenter(), r = presentedRemote(h)
  h.emit(r.state); await r.frame()
  let marked = false, decoded = {framesDecoded: 20, keyFramesDecoded: 8, sampleTime: 200}
  const fence = {rtp_timestamp: 15000}
  r.state.remoteVideoBinding = {receiver: r.state.remoteVideoBinding.receiver, isCurrent: () => true,
    readDecode: async () => decoded, presentation: timestamp => marked && timestamp === 15000 ? fence : null}
  h.emit(r.state)
  for (let i = 0; i < 8; i++) await Promise.resolve()
  await r.frame({rtpTimestamp: 15000, receiveTime: 220}, 230)
  assert.equal(r.video.dataset.remoteVideoState, "loading")
  marked = true
  decoded = {framesDecoded: 22, keyFramesDecoded: 9, sampleTime: 280}
  await r.frame({rtpTimestamp: 18000, presentedFrames: 2, mediaTime: 0.2}, 285)
  assert.equal(r.video.dataset.remoteVideoState, "ready")
  h.presenter.dispose()
})

for (const condition of ["expired metadata", "evicted metadata", "pause"]) {
  test(`a late marker cannot revive ${condition}`, async () => {
    const h = mountPresenter(), r = presentedRemote(h)
    h.emit(r.state); await r.frame()
    let timestamp = null, decoded = {framesDecoded: 20, keyFramesDecoded: 8, sampleTime: 200}
    let fence = {rtp_timestamp: 15000}
    r.state.remoteVideoBinding = {receiver: r.state.remoteVideoBinding.receiver, isCurrent: () => true,
      readDecode: async () => decoded, presentation: t => t === timestamp ? fence : null}
    h.emit(r.state)
    for (let i = 0; i < 8; i++) await Promise.resolve()
    await r.frame({rtpTimestamp: 15000, receiveTime: 220}, 230)
    if (condition === "evicted metadata") {
      for (let i = 0; i < 8; i++) await r.frame({rtpTimestamp: 18000 + i * 3000,
        presentedFrames: i + 2, mediaTime: 0.2 + i / 10}, 240 + i)
    }
    if (condition === "pause") {
      r.video.paused = true; r.video.dispatch("pause")
      r.video.paused = false; r.video.dispatch("playing")
    }
    timestamp = 15000
    decoded = {framesDecoded: 30, keyFramesDecoded: 9, sampleTime: 850}
    await r.frame({rtpTimestamp: 50000, presentedFrames: 10, mediaTime: 1}, condition === "expired metadata" ? 800 : 300)
    assert.equal(r.video.dataset.remoteVideoState, "loading")
    assert.equal(r.video.style.visibility, "hidden")
    timestamp = 60000; fence = {rtp_timestamp: 60000}
    await r.frame({rtpTimestamp: 60000, presentedFrames: 11, mediaTime: 1.1}, 900)
    assert.equal(r.video.dataset.remoteVideoState, "ready")
    h.presenter.dispose()
  })
}

for (const receiveTime of [150, 250, undefined]) {
  test(`exact keyframe baseline overlap requires a supported earlier receive clock ${receiveTime}`, async () => {
    const h = mountPresenter(), r = presentedRemote(h)
    h.emit(r.state); await r.frame()
    h.emit({...r.state, remoteCameraEnabled: false})
    const fence = {rtp_timestamp: 15000}
    r.state.remoteVideoBinding = {receiver: r.state.remoteVideoBinding.receiver, isCurrent: () => true,
      readDecode: async () => ({framesDecoded: 20, keyFramesDecoded: 8, sampleTime: 200}),
      presentation: () => fence}
    h.emit(r.state)
    for (let i = 0; i < 8; i++) await Promise.resolve()
    await r.frame({rtpTimestamp: 15000, receiveTime})
    assert.equal(r.video.dataset.remoteVideoState, receiveTime === 150 ? "ready" : "loading")
    h.presenter.dispose()
  })
}

for (const condition of ["cached stats", "missing stats clock", "missing receive clock", "retired marker", "pause"]) {
  test(`deferred keyframe confirmation stays covered after ${condition}`, async () => {
    const h = mountPresenter(), r = presentedRemote(h)
    h.emit(r.state); await r.frame()
    let decoded = {framesDecoded: 20, keyFramesDecoded: 8, sampleTime: 200}
    let fence = {rtp_timestamp: 15000}
    r.state.remoteVideoBinding = {receiver: r.state.remoteVideoBinding.receiver, isCurrent: () => true,
      readDecode: async () => decoded, presentation: timestamp => timestamp === fence.rtp_timestamp ? fence : null}
    h.emit(r.state)
    for (let i = 0; i < 8; i++) await Promise.resolve()
    await r.frame({rtpTimestamp: 15000, receiveTime: condition === "missing receive clock" ? undefined : 220})
    decoded = {framesDecoded: 22, keyFramesDecoded: 9,
      sampleTime: condition === "missing stats clock" ? undefined : condition === "cached stats" ? 200 : 260}
    if (condition === "retired marker") fence = {rtp_timestamp: 21000}
    if (condition === "pause") {
      r.video.paused = true; r.video.dispatch("pause")
      r.video.paused = false; r.video.dispatch("playing")
    }
    await r.frame({rtpTimestamp: 18000, presentedFrames: 2, mediaTime: 0.2})
    assert.equal(r.video.dataset.remoteVideoState, "loading")
    assert.equal(r.video.style.visibility, "hidden")
    fence = {rtp_timestamp: 21000}
    await r.frame({rtpTimestamp: 21000, presentedFrames: 3, mediaTime: 0.3})
    assert.equal(r.video.dataset.remoteVideoState, "ready")
    h.presenter.dispose()
  })
}

for (const timestamp of [undefined, 0xFFFFFF00, 1999]) {
  test(`current route excludes absent or older RTP presentation ${timestamp}`, async () => {
    const h = mountPresenter(), r = presentedRemote(h)
    const fence = {rtp_timestamp: 2000}
    r.state.remoteVideoBinding.presentation = () => fence
    h.emit(r.state)
    await r.frame({rtpTimestamp: timestamp})
    assert.equal(r.video.dataset.remoteVideoState, "loading")
    await r.frame({rtpTimestamp: 2000, presentedFrames: 2, mediaTime: 0.2})
    assert.equal(r.video.dataset.remoteVideoState, "ready")
    h.presenter.dispose()
  })
}

test("current keyframe marker matches exactly through uint32 wrap", async () => {
  const h = mountPresenter(), r = presentedRemote(h)
  let fence = {rtp_timestamp: 0xFFFFFF00}
  r.state.remoteVideoBinding.presentation = () => fence
  h.emit(r.state)
  await r.frame({rtpTimestamp: 2000})
  assert.equal(r.video.dataset.remoteVideoState, "loading")
  fence = {rtp_timestamp: 2000}
  await r.frame({rtpTimestamp: 2000, presentedFrames: 2, mediaTime: 0.2})
  assert.equal(r.video.dataset.remoteVideoState, "ready")
  h.presenter.dispose()
})

test("obsolete presentation and held decode cannot ready a replaced binding or a departed Call", async () => {
  const h = mountPresenter()
  let resolve
  const r = presentedRemote(h, () => new Promise(r => {resolve = r}))
  h.emit(r.state)
  const staleFrame = r.callbacks.values().next().value
  await r.frame()
  const next = {...r.state, remoteVideoBinding: {isCurrent: () => true,
    readDecode: async () => ({framesDecoded: 1, keyFramesDecoded: 1})}}
  h.emit(next)
  resolve({framesDecoded: 9, keyFramesDecoded: 2})
  await Promise.resolve()
  staleFrame(20, {width: 960, height: 540, mediaTime: 1, presentedFrames: 9})
  assert.equal(r.video.dataset.remoteVideoState, "loading")
  h.emit({presentation: "result", call: null})
  assert.equal(r.callbacks.size, 0)
  assert.equal(r.video.srcObject, null)
  assert.equal(r.video.dataset.remoteVideoState, "off")
  h.presenter.dispose()
})

for (const condition of ["missing callbacks", "missing decode", "paused", "zero sink dimensions", "hidden", "invalid receiver"]) {
  test(`remote presentation stays loading with ${condition}`, async () => {
    const h = mountPresenter(), r = presentedRemote(h)
    if (condition === "missing callbacks") delete r.video.requestVideoFrameCallback
    if (condition === "missing decode") r.state.remoteVideoBinding.readDecode = async () => null
    if (condition === "paused") r.video.paused = true
    if (condition === "zero sink dimensions") r.video.videoHeight = 0
    if (condition === "hidden") h.document.visibilityState = "hidden"
    if (condition === "invalid receiver") r.state.remoteVideoBinding.isCurrent = () => false
    h.emit(r.state)
    if (r.callbacks.size) await r.frame()
    await Promise.resolve()
    assert.equal(r.video.dataset.remoteVideoState, "loading")
    h.presenter.dispose()
  })
}

test("held current decode cannot ready a sink whose dimensions became unusable", async () => {
  const h = mountPresenter()
  let resolve
  const r = presentedRemote(h, () => new Promise(r => {resolve = r}))
  h.emit(r.state)
  await r.frame()
  r.video.videoWidth = 0
  resolve({framesDecoded: 1, keyFramesDecoded: 1})
  for (let i = 0; i < 8; i++) await Promise.resolve()
  assert.equal(r.video.dataset.remoteVideoState, "loading")
  h.presenter.dispose()
})

test("late play rejection cannot undo current fresh presentation or affect a newer playback epoch", async () => {
  const h = mountPresenter(), r = presentedRemote(h)
  let reject
  r.video.play = () => new Promise((_resolve, r) => {reject = r})
  h.emit(r.state)
  await Promise.resolve()
  await r.frame()
  reject(Error("old play result"))
  for (let i = 0; i < 8; i++) await Promise.resolve()
  assert.equal(r.video.dataset.remoteVideoState, "ready")
  h.emit({...r.state, remoteCameraEnabled: false})
  h.emit(r.state)
  for (let i = 0; i < 8; i++) await Promise.resolve()
  const oldReject = reject
  h.emit({presentation: "result", call: null})
  oldReject(Error("departed epoch"))
  for (let i = 0; i < 8; i++) await Promise.resolve()
  assert.equal(r.video.dataset.remoteVideoState, "off")
  h.presenter.dispose()
})

test("foreground missing frames cover video only after five seconds and fresh frames resume", async () => {
  const h = mountPresenter(), r = presentedRemote(h)
  h.emit(r.state); await r.frame()
  h.advance(4999)
  assert.equal(r.video.dataset.remoteVideoState, "ready")
  h.advance(1)
  assert.equal(r.video.dataset.remoteVideoState, "interrupted")
  assert.equal(r.video.style.visibility, "hidden")
  await r.frame({mediaTime: 0.2, presentedFrames: 2, rtpTimestamp: 12000})
  assert.equal(r.video.dataset.remoteVideoState, "ready")
  assert.equal(r.video.style.visibility, "visible")
  h.presenter.dispose()
})

test("hidden and frozen intervals reset foreground diagnosis and reject held callbacks", async () => {
  const h = mountPresenter(), r = presentedRemote(h)
  h.emit(r.state); await r.frame()
  const oldFrame = r.callbacks.values().next().value
  h.advance(4000)
  h.document.visibilityState = "hidden"; h.document.dispatch("visibilitychange")
  h.advance(60000)
  assert.notEqual(r.video.dataset.remoteVideoState, "interrupted")
  h.document.visibilityState = "visible"; h.document.dispatch("visibilitychange")
  assert.equal(r.video.dataset.remoteVideoState, "loading")
  oldFrame(1, {width: 960, height: 540, presentedFrames: 99, mediaTime: 99, rtpTimestamp: 12000})
  await Promise.resolve()
  assert.equal(r.video.dataset.remoteVideoState, "loading")
  h.advance(4999)
  assert.equal(r.video.dataset.remoteVideoState, "loading")
  await r.frame({mediaTime: 0.2, presentedFrames: 2, rtpTimestamp: 12000})
  assert.equal(r.video.dataset.remoteVideoState, "ready")
  h.document.dispatch("freeze"); h.advance(60000); h.document.dispatch("resume")
  h.advance(4999)
  assert.equal(r.video.dataset.remoteVideoState, "loading")
  h.advance(1)
  assert.equal(r.video.dataset.remoteVideoState, "interrupted")
  h.presenter.dispose()
})

test("stationary live frames and sub-threshold delays stay ready; replayed timestamps cannot resume", async () => {
  const h = mountPresenter(), r = presentedRemote(h)
  h.emit(r.state); await r.frame()
  for (let i = 2; i <= 5; i++) {
    h.advance(4000)
    await r.frame({mediaTime: i / 10, presentedFrames: i, rtpTimestamp: i * 9000})
    assert.equal(r.video.dataset.remoteVideoState, "ready")
  }
  h.advance(5000)
  assert.equal(r.video.dataset.remoteVideoState, "interrupted")
  await r.frame({mediaTime: 0.6, presentedFrames: 6, rtpTimestamp: 9000})
  assert.equal(r.video.dataset.remoteVideoState, "interrupted")
  await r.frame({mediaTime: 0.6, presentedFrames: 6, rtpTimestamp: 54000})
  assert.equal(r.video.dataset.remoteVideoState, "ready")
  h.presenter.dispose()
})

test("paused playback gets a fresh playing baseline and blocked autoplay stays distinct", async () => {
  const h = mountPresenter(), r = presentedRemote(h)
  h.emit(r.state); await r.frame()
  r.video.paused = true; r.video.dispatch("pause")
  h.advance(60000)
  assert.notEqual(r.video.dataset.remoteVideoState, "interrupted")
  r.video.paused = false; r.video.dispatch("playing")
  h.advance(4999)
  assert.equal(r.video.dataset.remoteVideoState, "loading")
  h.advance(1)
  assert.equal(r.video.dataset.remoteVideoState, "interrupted")
  h.presenter.dispose()
  const blocked = mountPresenter(), b = presentedRemote(blocked)
  b.video.play = () => Promise.reject(new Error("autoplay"))
  blocked.emit(b.state)
  for (let i = 0; i < 8; i++) await Promise.resolve()
  blocked.advance(60000)
  assert.equal(b.video.dataset.remoteVideoState, "blocked")
  blocked.presenter.dispose()
})

for (const exit of ["off", "owner loss", "source end", "terminal", "replacement", "dispose"]) {
  test(`${exit} rejects stale interruption timers and cannot resume obsolete video`, async () => {
    const h = mountPresenter(), r = presentedRemote(h)
    h.emit(r.state); await r.frame()
    const timers = [...h.deadlines.values()].map(task => task.fn)
    const oldFrame = r.callbacks.values().next().value
    if (exit === "off") h.emit({...r.state, remoteCameraEnabled: false})
    if (exit === "owner loss") h.emit({...r.state, call: {ownership: "elsewhere"}})
    if (exit === "source end") {r.state.remoteVideoTrack.readyState = "ended"; h.emit(r.state)}
    if (exit === "terminal") h.emit({...r.state, presentation: "idle"})
    if (exit === "replacement") h.emit({...r.state, remoteVideoBinding: {...r.state.remoteVideoBinding, receiver: {}}})
    if (exit === "dispose") h.presenter.dispose()
    for (const fn of timers) fn()
    oldFrame(1, {width: 960, height: 540, mediaTime: 99, presentedFrames: 99, rtpTimestamp: 12000})
    h.document.dispatch("resume")
    await Promise.resolve()
    assert.equal(r.video.dataset.remoteVideoState, ["replacement", "source end"].includes(exit) ? "loading" : "off")
    assert.equal(r.video.style.visibility, "hidden")
    h.presenter.dispose()
    assert.equal(h.deadlines.size, 0)
  })
}

test("native playing does not discard a current keyframe with held decode evidence", async () => {
  const h = mountPresenter()
  let resolve
  const r = presentedRemote(h, () => new Promise(done => {resolve = done}))
  h.emit(r.state); await r.frame()
  r.video.dispatch("playing")
  resolve({framesDecoded: 1, keyFramesDecoded: 1})
  for (let i = 0; i < 8; i++) await Promise.resolve()
  assert.equal(r.video.dataset.remoteVideoState, "ready")
  h.presenter.dispose()
})

test("a play rejection from before suspension cannot block the new foreground baseline", async () => {
  const h = mountPresenter(), r = presentedRemote(h)
  let reject
  r.video.play = () => new Promise((_resolve, fail) => {reject = fail})
  h.emit(r.state); await Promise.resolve()
  h.document.dispatch("freeze"); h.document.dispatch("resume")
  reject(new Error("obsolete play"))
  for (let i = 0; i < 8; i++) await Promise.resolve()
  assert.equal(r.video.dataset.remoteVideoState, "loading")
  h.presenter.dispose()
})

test("an obsolete native pause event cannot cover or cancel a playing current sink", async () => {
  const h = mountPresenter(), r = presentedRemote(h)
  h.emit(r.state); await r.frame()
  r.video.dispatch("pause")
  assert.equal(r.video.dataset.remoteVideoState, "ready")
  await r.frame({mediaTime: 0.2, presentedFrames: 2, rtpTimestamp: 12000})
  assert.equal(r.video.dataset.remoteVideoState, "ready")
  h.presenter.dispose()
})

test("playing while a retained decode baseline is held preserves the first eligible keyframe", async () => {
  const h = mountPresenter(), r = presentedRemote(h)
  h.emit(r.state); await r.frame(); h.emit({...r.state, remoteCameraEnabled: false})
  let resolve, first = true
  const baseline = new Promise(done => {resolve = done})
  r.state.remoteVideoBinding = {receiver: r.state.remoteVideoBinding.receiver, isCurrent: () => true,
    presentation: () => fence,
    readDecode() {if (first) {first = false; return baseline} return Promise.resolve({framesDecoded: 11, keyFramesDecoded: 4})},
  }
  const fence = {rtp_timestamp: 15000}
  h.emit(r.state); r.video.dispatch("playing")
  const frame = {mediaTime: 0.2, presentedFrames: 2, rtpTimestamp: 15000, receiveTime: 150}
  if (r.callbacks.size) await r.frame(frame)
  resolve({framesDecoded: 10, keyFramesDecoded: 3, sampleTime: 200})
  for (let i = 0; i < 8; i++) await Promise.resolve()
  await r.frame(frame)
  assert.equal(r.video.dataset.remoteVideoState, "ready")
  h.presenter.dispose()
})

test("owner size disclosure retains presentation, focus and size through navigation and resets next Call", async () => {
  const h = mountPresenter(), r = presentedRemote(h)
  const size = element({id: "direct-call-dock-size", hidden: true,
    closest(selector) {return selector === "[data-call-action='toggle-size']" ? this : null},
    focus() {h.document.activeElement = this}})
  const lookup = h.document.getElementById
  h.document.getElementById = id => id === size.id ? size : lookup(id)
  h.dock.contains = node => node === size || node === r.video
  h.emit(r.state); await r.frame()
  const stream = r.video.srcObject, callbacks = [...r.callbacks.keys()]
  let plays = 0
  r.video.play = () => {plays++; return Promise.resolve()}
  assert.equal(size.hidden, false)
  assert.equal(size.textContent, "Expand")
  assert.equal(size.getAttribute("aria-expanded"), "false")
  size.focus()
  h.document.dispatch("click", {target: size})
  assert.equal(size.textContent, "Collapse")
  assert.equal(size.getAttribute("aria-expanded"), "true")
  assert.equal(h.dock.dataset.stageExpanded, "true")
  assert.equal(h.document.activeElement, size)
  let prevented = false
  h.document.dispatch("keydown", {key: "Tab", preventDefault() {prevented = true}})
  assert.equal(prevented, false, "the nonmodal stage never traps Tab")
  h.window.dispatch("phx:page-loading-start", {detail: {kind: "redirect"}})
  h.window.dispatch("phx:page-loading-stop")
  assert.equal(size.getAttribute("aria-expanded"), "true")
  h.document.dispatch("click", {target: size})
  assert.equal(size.getAttribute("aria-expanded"), "false")
  assert.equal(h.document.activeElement, size)
  assert.equal(r.video.srcObject, stream)
  assert.equal(r.video.dataset.remoteVideoState, "ready")
  assert.deepEqual([...r.callbacks.keys()], callbacks)
  assert.equal(plays, 0)
  h.document.dispatch("click", {target: size})
  h.emit({...r.state, call: {...r.state.call, call_id: "next-call"}})
  assert.equal(size.getAttribute("aria-expanded"), "false")
  h.emit({...r.state, call: {...r.state.call, ownership: "elsewhere"}})
  assert.equal(size.hidden, true)
  assert.equal(h.document.activeElement, h.title, "hidden disclosure returns focus to call status")
  h.document.dispatch("click", {target: size})
  assert.equal(h.dock.dataset.stageExpanded, "false", "observers cannot expand")
  h.presenter.dispose()
})

test("owner stage mounts the retained presentation and Message updates do no playback work", async () => {
  const h = mountPresenter(), r = presentedRemote(h)
  const home = element({isConnected: true, appendChild(node) {node.parentElement = this}})
  const stage = element({isConnected: true, dataset: {directConversationId: "conversation-1"},
    moveBefore(node) {node.parentElement = this}})
  const lookup = h.document.getElementById
  h.document.getElementById = id => id === "direct-conversation-call-stage" ? stage :
    id === "direct-call-dock-home" ? home : lookup(id)
  const returnLink = element({id: "direct-call-dock-return", hidden: true})
  const oldLookup = h.document.getElementById
  h.document.getElementById = id => id === returnLink.id ? returnLink : oldLookup(id)
  h.document.body = element({dataset: {}, style: {setProperty() {}, removeProperty() {}}})
  h.dock.parentElement = home
  r.state.call.direct_conversation_id = "conversation-1"
  h.emit(r.state); await r.frame()
  assert.equal(h.dock.parentElement, stage)
  assert.equal(stage.hidden, false)
  const stream = r.video.srcObject, callbacks = [...r.callbacks.keys()]
  let plays = 0
  r.video.play = () => {plays++; return Promise.resolve()}
  h.window.dispatch("call:conversation-surface")
  h.emit(r.state)
  await Promise.resolve()
  assert.equal(r.video.srcObject, stream)
  assert.equal(r.video.dataset.remoteVideoState, "ready")
  assert.deepEqual([...r.callbacks.keys()], callbacks)
  assert.equal(plays, 0)
  h.window.dispatch("phx:page-loading-start", {detail: {kind: "element"}})
  assert.equal(h.dock.parentElement, stage)
  h.window.dispatch("phx:page-loading-start", {detail: {kind: "redirect"}})
  assert.equal(h.dock.parentElement, home)
  assert.equal(returnLink.hidden, false)
  assert.equal(returnLink.getAttribute("href"), "/direct-messages/conversation-1")
  assert.equal(h.document.body.dataset.callCompact, "true")
  h.window.dispatch("call:conversation-surface")
  h.window.dispatch("phx:page-loading-stop", {detail: {kind: "element"}})
  assert.equal(h.dock.parentElement, home, "outgoing hook teardown and unrelated element completion keep the redirect fenced")
  h.emit(r.state)
  assert.equal(h.dock.parentElement, home, "updates during navigation cannot return to the departing stage")
  assert.equal(r.video.srcObject, stream)
  h.window.dispatch("phx:page-loading-stop")
  assert.equal(returnLink.hidden, true)
  assert.equal(h.document.body.dataset.callCompact, "false")
  assert.equal(h.dock.parentElement, stage)
  stage.dataset.directConversationId = "unrelated-conversation"
  h.window.dispatch("call:conversation-surface")
  assert.equal(stage.hidden, true)
  assert.equal(h.dock.parentElement, home)
  stage.dataset.directConversationId = "conversation-1"
  h.window.dispatch("call:conversation-surface")
  h.emit({...r.state, call: {...r.state.call, ownership: "elsewhere"}})
  assert.equal(stage.hidden, true)
  assert.equal(h.dock.parentElement, home)
  assert.equal(r.video.srcObject, null)
  h.presenter.dispose()
})

test("repeated size changes preserve loading, interruption and accepted off precedence", async () => {
  const h = mountPresenter(), r = presentedRemote(h)
  const size = element({id: "direct-call-dock-size",
    closest(selector) {return selector === "[data-call-action='toggle-size']" ? this : null}})
  const lookup = h.document.getElementById
  h.document.getElementById = id => id === size.id ? size : lookup(id)
  const toggle = () => h.document.dispatch("click", {target: size})
  h.emit(r.state)
  toggle(); toggle()
  assert.equal(r.video.dataset.remoteVideoState, "loading")
  await r.frame()
  h.advance(5000)
  assert.equal(r.video.dataset.remoteVideoState, "interrupted")
  const stream = r.video.srcObject
  toggle(); toggle()
  assert.equal(r.video.dataset.remoteVideoState, "interrupted")
  assert.equal(r.video.srcObject, stream)
  h.emit({...r.state, remoteCameraEnabled: false})
  toggle(); toggle()
  assert.equal(r.video.dataset.remoteVideoState, "off")
  assert.equal(r.video.srcObject, null)
  assert.equal(h.document.getElementById("direct-call-remote-video-placeholder").hidden, false)
  h.presenter.dispose()
})

test("compact space follows tray resize and releases on owner loss and disposal", () => {
  const h = mountPresenter()
  let resize, disconnected = false, height = 180
  const properties = new Map()
  h.document.body = element({dataset: {}, style: {
    setProperty: (key, value) => properties.set(key, value), removeProperty: key => properties.delete(key)}})
  h.dock.getBoundingClientRect = () => ({height})
  h.window.ResizeObserver = class {
    constructor(fn) {resize = fn}
    observe() {}
    disconnect() {disconnected = true}
  }
  h.presenter.dispose()
  h.presenter = installCallPresenter({document: h.document, window: h.window, controller: h.controller})
  const state = {presentation: "active", call: {ownership: "self", direct_conversation_id: "conversation"}}
  h.emit(state)
  assert.equal(properties.get("--call-panel-height"), "180px")
  height = 240; resize()
  assert.equal(properties.get("--call-panel-height"), "240px")
  h.emit({...state, call: {...state.call, ownership: "elsewhere"}})
  assert.equal(h.document.body.dataset.callCompact, "false")
  assert.equal(properties.has("--call-panel-height"), false)
  h.emit(state); h.presenter.dispose(); resize()
  assert.equal(disconnected, true)
  assert.equal(h.document.body.dataset.callCompact, "false")
  assert.equal(properties.has("--call-panel-height"), false)
})

test("camera, microphone and deafen name their actions without contradictory pressed state", () => {
  const h = mountPresenter()
  const controls = ["camera", "mute", "deafen"].map(kind => {
    const node = element({id: `direct-call-dock-${kind}`, hidden: true, dataset: {}})
    const lookup = h.document.getElementById
    h.document.getElementById = id => id === node.id ? node : lookup(id)
    return node
  })
  const state = {presentation: "active", call: {ownership: "self", call_id: "call"},
    canMute: true, canDeafen: true, canControlCamera: true}
  h.emit(state)
  assert.deepEqual(controls.map(n => n.getAttribute("aria-label")),
    ["Turn camera on", "Mute microphone", "Deafen audio"])
  h.emit({...state, cameraWorking: true, cameraAttached: true, localMuted: true, localDeafened: true})
  assert.deepEqual(controls.map(n => n.getAttribute("aria-label")),
    ["Turn camera off", "Unmute microphone after undeafening", "Undeafen audio"])
  assert.deepEqual(controls.map(n => n.getAttribute("aria-pressed")), [null, null, null])
  h.presenter.dispose()
})

test("Leave and owner loss restore focus even when hiding a parent drops browser focus", () => {
  for (const presentation of ["idle", "owned_elsewhere"]) {
    const h = mountPresenter()
    const composer = element({id: "message_content", focus() {h.document.activeElement = this}})
    const lookup = h.document.getElementById
    h.document.getElementById = id => id === composer.id ? composer : lookup(id)
    h.leave.parentElement = h.dock
    h.dock.contains = node => node === h.leave
    h.emit({presentation: "active", call: {ownership: "self"}, canLeave: true})
    h.leave.focus()
    for (const node of [h.dock, h.leave]) {
      let hidden = node.hidden
      Object.defineProperty(node, "hidden", {get: () => hidden, set(value) {
        hidden = value
        if (value && h.document.activeElement === h.leave) h.document.activeElement = null
      }})
    }
    h.emit({presentation, call: presentation === "idle" ? null : {ownership: "elsewhere"}})
    assert.equal(h.document.activeElement, presentation === "idle" ? composer : h.title)
    h.priorFocus.focus()
    h.emit({presentation: "idle"})
    assert.equal(h.document.activeElement, h.priorFocus, "unrelated page focus stays put")
    h.presenter.dispose()
  }
})

test("modal Tab and return focus exclude controls inside hidden ancestors", () => {
  const h = mountPresenter()
  h.priorFocus.parentElement = element({hidden: true})
  h.priorFocus.focus()
  h.emit({presentation: "incoming_ringing", mediaIntent: "audio", canDecline: true, canAcceptAudio: true})
  h.decline.parentElement = element({hidden: true})
  h.document.dispatch("keydown", {key: "Tab", preventDefault() {}})
  assert.equal(h.document.activeElement, h.acceptAudio)
  h.emit({presentation: "idle"})
  assert.equal(h.document.activeElement, h.focusFallback)
  h.presenter.dispose()
})

test("remote announcements report readiness once, distinguish interruption/off, and ignore frame volume", async () => {
  const h = mountPresenter(), r = presentedRemote(h)
  const status = h.document.getElementById("direct-call-remote-video-status")
  let text = "", writes = 0
  Object.defineProperty(status, "textContent", {get: () => text, set(value) {text = value; writes++}})
  h.emit(r.state)
  assert.equal(text, "Waiting for video…")
  await r.frame()
  assert.equal(text, "Video ready")
  const readyWrites = writes
  for (let i = 2; i <= 20; i++) await r.frame({presentedFrames: i, mediaTime: i / 10, rtpTimestamp: 9000 + i})
  h.emit(r.state)
  assert.equal(writes, readyWrites)
  h.advance(5000)
  assert.match(text, /Video interrupted/)
  await r.frame({presentedFrames: 21, mediaTime: 2.1, rtpTimestamp: 9021})
  assert.equal(text, "Video ready")
  h.emit({...r.state, remoteCameraEnabled: false})
  assert.equal(text, "Camera off")
  h.presenter.dispose()
})

function mountPresenter() {
  const calls = []
  let now = 0
  const deadlines = new Map()
  const videoClock = {now: () => now,
    setTimeout(fn, delay) {const id = {}; deadlines.set(id, {fn, at: now + delay}); return id},
    clearTimeout(id) {deadlines.delete(id)},
  }
  let currentState = {
    presentation: "idle",
    statusText: "",
    peerName: null,
    canCancel: false,
    canRetry: false,
    canDismiss: false,
    busy: false,
  }
  let listener = null
  const controller = {
    startCall(...args) { calls.push({startCall: args}) },
    cancelCall() { calls.push("cancelCall") },
    cancelLocalPreparation() { calls.push("cancelLocalPreparation") },
    releaseCues() { calls.push("releaseCues") },
    retry() { calls.push("retry") },
    fallbackToAudio() { calls.push("fallbackToAudio") },
    acceptCall(mode) { calls.push({acceptCall: mode}) },
    declineCall() { calls.push("declineCall") },
    leaveCall() { calls.push("leaveCall") },
    enableMicrophone() { calls.push("enableMicrophone") },
    dismiss() { calls.push("dismiss") },
    getState() { return currentState },
    subscribe(next) {
      listener = next
      listener(currentState)
      return () => { listener = null }
    },
    setRemoteVideoState(binding, value) {calls.push({remoteVideoState: value})},
    dispose() {},
  }

  const dock = element({id: "direct-call-dock", hidden: true, dataset: {}})
  const status = element({id: "direct-call-dock-status", textContent: ""})
  status.setAttribute("role", "status")
  status.setAttribute("aria-live", "polite")
  let ariaLiveWrites = 0
  let statusWrites = 0
  let statusText = ""
  Object.defineProperty(status, "textContent", {
    get() {
      return statusText
    },
    set(value) {
      if (value !== statusText) {
        statusText = value
        statusWrites += 1
      }
    },
  })
  const writeAttribute = status.setAttribute.bind(status)
  status.setAttribute = (name, value) => {
    if (name === "aria-live") ariaLiveWrites += 1
    writeAttribute(name, value)
  }
  const peer = element({id: "direct-call-dock-peer", textContent: ""})
  const title = element({id: "direct-call-dock-title", textContent: "Voice call"})
  const cancel = element({id: "direct-call-dock-cancel", hidden: true, dataset: {}})
  cancel.closest = selector => selector === "[data-call-action='cancel']" ? cancel : null
  cancel.setAttribute("data-call-action", "cancel")
  const retry = element({id: "direct-call-dock-retry", hidden: true, dataset: {}})
  retry.closest = selector => selector === "[data-call-action='retry']" ? retry : null
  retry.setAttribute("data-call-action", "retry")
  const dismiss = element({id: "direct-call-dock-dismiss", hidden: true, dataset: {}})
  dismiss.closest = selector => selector === "[data-call-action='dismiss']" ? dismiss : null
  dismiss.setAttribute("data-call-action", "dismiss")
  const fallback = element({id: "direct-call-dock-start-voice-instead", hidden: true, dataset: {}})
  fallback.closest = selector => selector === "[data-call-action='fallback-audio']" ? fallback : null
  fallback.setAttribute("data-call-action", "fallback-audio")
  const leave = element({id: "direct-call-dock-leave", hidden: true, dataset: {}})
  leave.closest = selector => selector === "[data-call-action='leave']" ? leave : null
  leave.setAttribute("data-call-action", "leave")
  const backdrop = element({id: "direct-call-incoming-backdrop", hidden: true, dataset: {}})
  backdrop.closest = () => null
  const dialog = element({id: "direct-call-incoming-dialog"})
  const incomingTitle = element({id: "direct-call-incoming-title", textContent: "Incoming call"})
  const incomingCaller = element({id: "direct-call-incoming-caller"})
  const incomingIntent = element({id: "direct-call-incoming-intent", textContent: "Audio invitation"})
  const incomingStatus = element({id: "direct-call-incoming-status"})
  let incomingStatusText = ""
  let incomingStatusWrites = 0
  Object.defineProperty(incomingStatus, "textContent", {
    get() {
      return incomingStatusText
    },
    set(value) {
      if (value !== incomingStatusText) {
        incomingStatusText = value
        incomingStatusWrites += 1
      }
    },
  })
  const acceptAudio = element({id: "direct-call-incoming-accept-audio", dataset: {}})
  acceptAudio.closest = selector => selector === "[data-call-action='accept-audio']" ? acceptAudio : null
  acceptAudio.setAttribute("data-call-action", "accept-audio")
  const acceptVideo = element({id: "direct-call-incoming-accept-video", dataset: {}})
  acceptVideo.closest = selector => selector === "[data-call-action='accept-video']" ? acceptVideo : null
  acceptVideo.setAttribute("data-call-action", "accept-video")
  const answerWithoutVideo = element({
    id: "direct-call-incoming-answer-without-video",
    dataset: {},
  })
  answerWithoutVideo.closest = selector => (
    selector === "[data-call-action='answer-without-video']" ? answerWithoutVideo : null
  )
  answerWithoutVideo.setAttribute("data-call-action", "answer-without-video")
  const decline = element({id: "direct-call-incoming-decline", dataset: {}})
  decline.closest = selector => selector === "[data-call-action='decline']" ? decline : null
  decline.setAttribute("data-call-action", "decline")
  dialog.querySelectorAll = () => [decline, acceptAudio, acceptVideo, answerWithoutVideo]
  const focusFallback = element({id: "direct-call-focus-fallback"})
  const priorFocus = element({id: "prior-focus", isConnected: true})
  const startButton = element({
    id: "direct-conversation-start-voice-call",
    dataset: {
      callAction: "start-audio",
      directConversationId: "conversation-1",
      peerId: "user-2",
      peerUsername: "alice",
    },
  })
  startButton.closest = selector => selector === "[data-call-action='start-audio']" ? startButton : null
  startButton.setAttribute("data-call-action", "start-audio")
  const disabledButton = element({
    id: "direct-conversation-start-voice-call-disabled",
    dataset: {
      callAction: "start-audio",
      directConversationId: "conversation-1",
      peerId: "user-2",
      peerUsername: "alice",
    },
  })
  disabledButton.setAttribute("data-call-action", "start-audio")
  disabledButton.setAttribute("aria-disabled", "true")
  disabledButton.closest = selector => selector === "[data-call-action='start-audio']" ? disabledButton : null
  const videoButton = element({
    id: "direct-conversation-start-video-call",
    dataset: {
      callAction: "start-video",
      directConversationId: "conversation-1",
      peerId: "user-2",
      peerUsername: "alice",
    },
  })
  videoButton.closest = selector => selector === "[data-call-action='start-video']" ? videoButton : null
  videoButton.setAttribute("data-call-action", "start-video")
  const disabledVideoButton = element({
    id: "direct-conversation-start-video-call-disabled",
    dataset: {
      callAction: "start-video",
      directConversationId: "conversation-1",
      peerId: "user-2",
      peerUsername: "alice",
    },
  })
  disabledVideoButton.setAttribute("data-call-action", "start-video")
  disabledVideoButton.setAttribute("aria-disabled", "true")
  disabledVideoButton.closest = selector => selector === "[data-call-action='start-video']" ? disabledVideoButton : null

  const enableMicrophone = element({id: "direct-call-dock-enable-microphone", hidden: true})
  enableMicrophone.closest = selector => selector === "[data-call-action='enable-microphone']" ? enableMicrophone : null
  const byId = {
    "direct-call-participants": element(),
    "direct-call-remote-video-name": element(),
    "direct-call-remote-video-avatar": element(),
    "direct-call-remote-video-placeholder": element(),
    "direct-call-remote-video-status": element(),
    "direct-call-local-preview": element({srcObject: null}),
    "direct-call-local-preview-region": element({hidden: true}),
    "direct-call-local-preview-placeholder": element(),
    "direct-call-local-preview-status": element(),
    "direct-call-remote-video-retry": element({id: "direct-call-remote-video-retry", hidden: true,
      closest(selector) {return selector === "[data-call-action='retry-video']" ? this : null}}),
    "direct-call-remote-video": element({srcObject: null}),
    "direct-call-remote-video-region": element({hidden: true}),
    "direct-call-dock-enable-microphone": enableMicrophone,
    "direct-call-dock": dock,
    "direct-call-dock-status": status,
    "direct-call-dock-peer": peer,
    "direct-call-dock-title": title,
    "direct-call-dock-cancel": cancel,
    "direct-call-dock-leave": leave,
    "direct-call-dock-retry": retry,
    "direct-call-dock-dismiss": dismiss,
    "direct-call-dock-start-voice-instead": fallback,
    "direct-call-incoming-backdrop": backdrop,
    "direct-call-incoming-dialog": dialog,
    "direct-call-incoming-title": incomingTitle,
    "direct-call-incoming-caller": incomingCaller,
    "direct-call-incoming-intent": incomingIntent,
    "direct-call-incoming-status": incomingStatus,
    "direct-call-incoming-accept-audio": acceptAudio,
    "direct-call-incoming-accept-video": acceptVideo,
    "direct-call-incoming-answer-without-video": answerWithoutVideo,
    "direct-call-incoming-decline": decline,
    "direct-call-focus-fallback": focusFallback,
  }
  const document = eventTarget()
  document.activeElement = null
  for (const node of Object.values(byId).concat(priorFocus)) {
    node.isConnected ??= true
    node.focus = () => { document.activeElement = node }
  }
  document.getElementById = id => byId[id] ?? null
  document.querySelectorAll = selector => {
    if (selector.includes("start-audio") && selector.includes("start-video")) {
      return [startButton, disabledButton, videoButton, disabledVideoButton]
    }
    if (selector === "[data-call-action='start-audio']") return [startButton, disabledButton]
    if (selector === "[data-call-action='start-video']") return [videoButton, disabledVideoButton]
    return []
  }
  const window = eventTarget()

  const presenter = installCallPresenter({document, window, controller, videoClock, MediaStream: class {constructor(tracks) {this.tracks = tracks}}})
  return {
    advance(ms) {
      now += ms
      for (const [id, task] of [...deadlines]) if (task.at <= now) {deadlines.delete(id); task.fn()}
    },
    deadlines,
    calls,
    enableMicrophone,
    acceptAudio,
    acceptVideo,
    answerWithoutVideo,
    backdrop,
    cancel,
    controller,
    dismiss,
    decline,
    disabledButton,
    disabledVideoButton,
    document,
    dock,
    emit(state) {
      currentState = state
      listener?.(state)
    },
    fallback,
    focusFallback,
    incomingCaller,
    incomingIntent,
    incomingStatus,
    incomingTitle,
    leave,
    peer,
    priorFocus,
    presenter,
    retry,
    startButton,
    status,
    title,
    videoButton,
    ariaLiveWrites: () => ariaLiveWrites,
    statusWrites: () => statusWrites,
    incomingStatusWrites: () => incomingStatusWrites,
    window,
  }
}

function element(initial = {}) {
  const attrs = {}
  return {
    hidden: false,
    textContent: "",
    dataset: {},
    disabled: false,
    ...initial,
    getAttribute(name) { return Object.hasOwn(attrs, name) ? attrs[name] : null },
    setAttribute(name, value) { attrs[name] = String(value) },
    removeAttribute(name) { delete attrs[name] },
    hasAttribute(name) { return Object.hasOwn(attrs, name) },
  }
}

function eventTarget() {
  const listeners = new Map()
  return {
    addEventListener(name, listener) {
      const current = listeners.get(name) || []
      current.push(listener)
      listeners.set(name, current)
    },
    removeEventListener(name, listener) {
      listeners.set(name, (listeners.get(name) || []).filter(item => item !== listener))
    },
    dispatch(name, event = {}) {
      for (const listener of listeners.get(name) || []) listener(event)
    },
    trigger(name, event = {}) {
      for (const listener of listeners.get(name) || []) listener(event)
    },
  }
}

test("unavailable video answer remains focusable and inert while explicit audio answer works", () => {
  const {document, emit, acceptVideo, answerWithoutVideo, calls, presenter} = mountPresenter()
  emit({presentation: "incoming_ringing", mediaIntent: "video", videoAvailable: false,
    canAcceptVideo: false, canAnswerWithoutVideo: true, canDecline: true})
  assert.equal(acceptVideo.hidden, false)
  assert.equal(acceptVideo.disabled, false)
  assert.equal(acceptVideo.getAttribute("aria-disabled"), "true")
  assert.equal(acceptVideo.getAttribute("aria-describedby"), "direct-call-video-unavailable-reason")
  document.dispatch("click", {target: acceptVideo})
  assert.deepEqual(calls, [])
  document.dispatch("click", {target: answerWithoutVideo})
  assert.deepEqual(calls, [{acceptCall: "audio"}])
  presenter.dispose()
})


test("fallback dock exposes a named microphone action only while the owner awaits a gesture", () => {
  const h = mountPresenter()
  h.emit({presentation: "connecting", canEnableMicrophone: true, canLeave: true,
    statusText: "Awaiting microphone. Enable your microphone to connect."})
  assert.equal(h.enableMicrophone.hidden, false)
  h.document.trigger("click", {target: h.enableMicrophone})
  assert.deepEqual(h.calls, ["enableMicrophone"])
  h.emit({presentation: "connecting", canEnableMicrophone: false, canLeave: true,
    statusText: "Preparing microphone…"})
  assert.equal(h.enableMicrophone.hidden, true)
  h.presenter.dispose()
})
