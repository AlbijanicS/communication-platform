import assert from "node:assert/strict"
import test from "node:test"

import {createRealCallDevices} from "./call_devices.js"
import {createCallVideoDiagnostics} from "./call_video_diagnostics.js"
import {createCallController} from "./call_controller.js"

const conversation = {
  id: "conversation-1",
  peer: {id: "user-2", username: "alice"},
}

test("subscribes to the initial signaling snapshot with frozen public state", () => {
  const signaling = fakeSignaling({
    connectionStatus: "connected",
    signalingSessionId: "session-1",
    call: null,
  })
  const snapshots = []
  const controller = createCallController({signaling, devices: deferredDevices()})
  const unsubscribe = controller.subscribe(state => snapshots.push(state))

  assert.equal(snapshots.at(-1).presentation, "idle")
  assert.equal(snapshots.at(-1).connectionStatus, "connected")
  assert.equal(Object.isFrozen(snapshots.at(-1)), true)
  assert.deepEqual(controller.getState(), snapshots.at(-1))

  unsubscribe()
  signaling.replace({connectionStatus: "unavailable"})
  assert.equal(snapshots.at(-1).presentation, "idle")
  assert.equal(controller.getState().presentation, "unavailable")
  controller.dispose()
})

test("preflight then starts an audio-only invitation with the conversation id and no peer identity", async () => {
  const signaling = fakeSignaling()
  const devices = deferredDevices()
  const controller = createCallController({signaling, devices})

  controller.startCall(conversation, "audio")
  assert.equal(controller.getState().presentation, "preflighting")
  assert.equal(controller.getState().statusText, "Preparing voice call… Cancel stops preparation; the browser prompt may still need dismissal.")
  assert.equal(controller.getState().canCancel, true)
  assert.equal(controller.getState().busy, true)
  assert.equal(signaling.starts.length, 0)
  assert.deepEqual(devices.queue[0].request, {audio: true, video: false})

  devices.queue[0].succeed()
  await microtask()

  assert.equal(signaling.starts.length, 1)
  assert.deepEqual(signaling.starts[0], {
    directConversationId: "conversation-1",
    mediaIntent: "audio",
  })
  assert.equal(controller.getState().presentation, "outgoing_ringing")
  assert.equal(controller.getState().statusText, "Calling alice…")
  assert.equal(controller.getState().call.call_id, "call-1")
  assert.equal(devices.queue[0].capture.released, false)
  controller.dispose()
})

test("preflight failures create no signaling start and render distinct retryable results", async () => {
  for (const error of ["permission-denied", "no-device", "unknown-error"]) {
    const signaling = fakeSignaling()
    const devices = deferredDevices()
    const controller = createCallController({signaling, devices})
    controller.startCall(conversation, "audio")
    devices.queue[0].fail(error)
    await microtask()

    const state = controller.getState()
    assert.equal(signaling.starts.length, 0)
    assert.equal(state.presentation, "result")
    assert.equal(state.resultCode, error)
    assert.equal(state.canRetry, true)
    assert.equal(state.canDismiss, true)
    assert.equal(state.canCancel, false)
    assert.equal(state.canFallbackToAudio, false)
    assert.match(state.statusText, /Microphone|microphone|Couldn't start/)
    controller.dispose()
  }
})

test("local cancel during preflight releases no server command and ignores late success", async () => {
  const signaling = fakeSignaling()
  const devices = deferredDevices()
  const controller = createCallController({signaling, devices})
  controller.startCall(conversation, "audio")
  controller.cancelCall()

  assert.equal(controller.getState().presentation, "idle")
  assert.equal(devices.queue[0].cancelled, true)
  assert.equal(signaling.cancels.length, 0)

  devices.queue[0].succeed()
  await microtask()
  assert.equal(signaling.starts.length, 0)
  assert.equal(devices.queue[0].capture.released, true)
  assert.equal(controller.getState().presentation, "idle")
  controller.dispose()
})

test("local preparation cancel during device acquire does not send start or cancel", async () => {
  const signaling = fakeSignaling()
  const devices = deferredDevices()
  const controller = createCallController({signaling, devices})
  controller.startCall(conversation, "video")
  controller.cancelLocalPreparation()

  assert.equal(controller.getState().presentation, "idle")
  assert.equal(devices.queue[0].cancelled, true)
  assert.equal(signaling.starts.length, 0)
  assert.equal(signaling.cancels.length, 0)

  devices.queue[0].succeed()
  await microtask()
  assert.equal(signaling.starts.length, 0)
  assert.equal(devices.queue[0].capture.released, true)
  controller.dispose()
})

test("local preparation cancel during in-flight start does not cancel the committed invitation", async () => {
  const signaling = fakeSignaling()
  let settleStart
  signaling.onStart(() => new Promise(resolve => {
    settleStart = resolve
  }))
  const devices = deferredDevices()
  const controller = createCallController({signaling, devices})
  controller.startCall(conversation, "video")
  devices.queue[0].succeed()
  await microtask()

  assert.equal(controller.getState().presentation, "preflighting")
  assert.equal(signaling.starts.length, 1)

  controller.cancelLocalPreparation()
  assert.equal(controller.getState().presentation, "preflighting")
  assert.equal(signaling.cancels.length, 0)

  const call = {
    call_id: "call-1",
    role: "caller",
    state: "ringing",
    media_intent: "video",
  }
  signaling.replace({call})
  settleStart({ok: true, started: true, call})
  await microtask()

  assert.equal(controller.getState().presentation, "outgoing_ringing")
  assert.equal(controller.getState().call.call_id, "call-1")
  assert.equal(signaling.cancels.length, 0)
  assert.equal(devices.queue[0].capture.released, false)

  controller.cancelLocalPreparation()
  assert.equal(signaling.cancels.length, 0)
  assert.equal(controller.getState().presentation, "outgoing_ringing")
  controller.dispose()
})

test("cancel during outgoing ringing uses the current Call ID and existing signaling command", async () => {
  const signaling = fakeSignaling()
  const devices = deferredDevices()
  const controller = createCallController({signaling, devices})
  await startRinging(controller, devices)

  controller.cancelCall()
  assert.deepEqual(signaling.cancels, [{callId: "call-1"}])
  assert.equal(controller.getState().presentation, "outgoing_ringing")
  assert.equal(controller.getState().statusText, "Cancelling…")
  assert.equal(controller.getState().canCancel, false)
  signaling.replace({call: null})

  assert.equal(controller.getState().presentation, "result")
  assert.equal(controller.getState().resultCode, "cancelled")
  assert.equal(controller.getState().statusText, "Voice call cancelled.")
  assert.equal(devices.queue[0].capture.released, true)
  controller.dispose()
})

test("a rejected ringing cancel keeps the dock visible and restores the cancel control", async () => {
  const signaling = fakeSignaling()
  signaling.cancelCall = () => Promise.resolve({ok: false, error: "timeout"})
  const devices = deferredDevices()
  const controller = createCallController({signaling, devices})
  await startRinging(controller, devices)

  controller.cancelCall()
  assert.equal(controller.getState().presentation, "outgoing_ringing")
  assert.equal(controller.getState().statusText, "Cancelling…")
  await microtask()

  assert.equal(controller.getState().presentation, "outgoing_ringing")
  assert.equal(controller.getState().statusText, "Calling alice…")
  assert.equal(controller.getState().canCancel, true)
  controller.dispose()
})

test("start errors have distinct copy and never send peer data or retry automatically", async () => {
  const cases = {
    busy: "That person is busy.",
    rate_limited: "You're calling too quickly. Try again shortly.",
    not_friends: "Calls require a current Friendship.",
    not_found: "That conversation isn't available.",
    temporarily_unavailable: "Calling is temporarily unavailable.",
    timeout: "The call didn't start in time. Try again.",
    unexpected: "Couldn't start the voice call.",
  }

  for (const [error, copy] of Object.entries(cases)) {
    const signaling = fakeSignaling()
    signaling.onStart(() => Promise.resolve({ok: false, error}))
    const devices = deferredDevices()
    const controller = createCallController({signaling, devices})
    await startAfterPreflight(controller, devices)

    const state = controller.getState()
    assert.equal(state.presentation, "result")
    assert.equal(state.statusText, copy)
    assert.equal(state.resultCode, error === "unexpected" ? "unknown-error" : error)
    assert.equal(devices.queue[0].capture.released, true)
    assert.equal(signaling.starts[0].peer, undefined)
    assert.equal(signaling.starts[0].userId, undefined)
    controller.dispose()
  }
})

test("authoritative server ringing replaces local preparation without a second start", async () => {
  const signaling = fakeSignaling()
  const devices = deferredDevices()
  const controller = createCallController({signaling, devices})
  controller.startCall(conversation, "audio")

  signaling.replace({
    call: {call_id: "call-live", role: "caller", state: "ringing", media_intent: "audio"},
  })

  assert.equal(controller.getState().presentation, "outgoing_ringing")
  assert.equal(controller.getState().call.call_id, "call-live")
  assert.equal(devices.queue[0].cancelled, true)

  devices.queue[0].succeed()
  await microtask()
  assert.equal(signaling.starts.length, 0)
  assert.equal(devices.queue[0].capture.released, true)
  controller.dispose()
})

test("release happens on start rejection, matching terminal, replacement, transport loss, and disposal", async () => {
  const signaling = fakeSignaling()
  signaling.onStart(() => Promise.resolve({ok: false, error: "busy"}))
  const devices = deferredDevices()
  const controller = createCallController({signaling, devices})
  await startAfterPreflight(controller, devices)
  assert.equal(devices.queue[0].capture.released, true)
  controller.dispose()

  const replaced = fakeSignaling()
  const replacedDevices = deferredDevices()
  const replacing = createCallController({signaling: replaced, devices: replacedDevices})
  await startRinging(replacing, replacedDevices)
  replaced.replace({
    call: {call_id: "call-2", role: "caller", state: "ringing"},
  })
  assert.equal(replacedDevices.queue[0].capture.released, true)
  replacing.dispose()

  const lost = fakeSignaling()
  const lostDevices = deferredDevices()
  const losing = createCallController({signaling: lost, devices: lostDevices})
  await startRinging(losing, lostDevices)
  lost.replace({connectionStatus: "unavailable", call: null})
  assert.equal(lostDevices.queue[0].capture.released, true)
  assert.equal(losing.getState().presentation, "unavailable")
  losing.dispose()

  const disposedSignaling = fakeSignaling()
  const disposedDevices = deferredDevices()
  const disposing = createCallController({signaling: disposedSignaling, devices: disposedDevices})
  await startRinging(disposing, disposedDevices)
  disposing.dispose()
  assert.equal(disposedDevices.queue[0].capture.released, true)
})

test("late signaling acknowledgements after a newer action do not start or revive a Call Attempt", async () => {
  const signaling = fakeSignaling()
  let settleStart
  signaling.onStart(() => new Promise(resolve => {
    settleStart = resolve
  }))
  const devices = deferredDevices()
  const controller = createCallController({signaling, devices})
  controller.startCall(conversation, "audio")
  devices.queue[0].succeed()
  await microtask()
  controller.cancelCall()

  settleStart({
    ok: true,
    started: true,
    call: {call_id: "stale", role: "caller", state: "ringing"},
  })
  await microtask()

  assert.equal(controller.getState().presentation, "idle")
  assert.equal(controller.getState().call, null)
  assert.equal(devices.queue[0].capture.released, true)
  controller.dispose()
})

test("cancel during an in-flight start cancels that Call ID and does not revive outgoing ringing", async () => {
  const signaling = fakeSignaling()
  let settleStart
  signaling.onStart(() => new Promise(resolve => {
    settleStart = resolve
  }))
  const devices = deferredDevices()
  const controller = createCallController({signaling, devices})
  controller.startCall(conversation, "audio")
  devices.queue[0].succeed()
  await microtask()

  assert.equal(controller.getState().presentation, "preflighting")
  assert.equal(signaling.starts.length, 1)

  controller.cancelCall()
  assert.equal(controller.getState().presentation, "idle")
  assert.equal(signaling.cancels.length, 0)

  const call = {
    call_id: "call-late",
    role: "caller",
    state: "ringing",
    media_intent: "audio",
  }
  signaling.replace({call})
  settleStart({ok: true, started: true, call})
  await microtask()

  assert.notEqual(controller.getState().presentation, "outgoing_ringing")
  assert.deepEqual(signaling.cancels, [{callId: "call-late"}])
  assert.equal(devices.queue[0].capture.released, true)

  signaling.replace({call})
  await microtask()
  assert.notEqual(controller.getState().presentation, "outgoing_ringing")
  assert.deepEqual(signaling.cancels, [{callId: "call-late"}])
  assert.equal(devices.queue[0].capture.released, true)
  controller.dispose()
})

test("in-flight start cancel retries when the first cancel is not accepted", async () => {
  const signaling = fakeSignaling()
  let settleStart
  signaling.onStart(() => new Promise(resolve => {
    settleStart = resolve
  }))
  const devices = deferredDevices()
  const controller = createCallController({signaling, devices})
  controller.startCall(conversation, "audio")
  devices.queue[0].succeed()
  await microtask()
  controller.cancelCall()

  const call = {call_id: "call-late", role: "caller", state: "ringing", media_intent: "audio"}
  let attempts = 0
  signaling.cancelCall = payload => {
    attempts += 1
    if (attempts === 1) return Promise.resolve({ok: false, error: "unavailable"})
    signaling.cancels.push(payload)
    return Promise.resolve({ok: true, call: {call_id: payload.callId, terminal_outcome: "cancelled"}})
  }

  signaling.replace({call, callTopicStatus: "joining"})
  settleStart({ok: true, started: true, call})
  await microtask()
  assert.equal(attempts, 1)
  assert.equal(signaling.cancels.length, 0)
  assert.notEqual(controller.getState().presentation, "outgoing_ringing")

  signaling.replace({call, callTopicStatus: "joined"})
  await microtask()
  assert.deepEqual(signaling.cancels, [{callId: "call-late"}])
  assert.notEqual(controller.getState().presentation, "outgoing_ringing")
  assert.equal(devices.queue[0].capture.released, true)
  controller.dispose()
})

test("a stale start acknowledgement does not release the newer ringing capture", async () => {
  const signaling = fakeSignaling()
  let settleFirst
  signaling.onStart(() => new Promise(resolve => {
    settleFirst = resolve
  }))
  const devices = deferredDevices()
  const controller = createCallController({signaling, devices})

  controller.startCall(conversation, "audio")
  devices.queue[0].succeed()
  await microtask()
  assert.equal(signaling.starts.length, 1)

  signaling.onStart(payload => defaultStart(signaling, payload))
  controller.startCall(conversation, "audio")
  assert.equal(devices.queue[0].capture.released, true)

  devices.queue[1].succeed()
  await microtask()
  assert.equal(controller.getState().presentation, "outgoing_ringing")
  assert.equal(controller.getState().call.call_id, "call-1")
  assert.equal(devices.queue[1].capture.released, false)

  // Match createCallSignaling: apply the reply (retire the previous Call ID) before the promise resolves.
  signaling.replace({
    call: {call_id: "stale", role: "caller", state: "ringing"},
  })
  settleFirst({
    ok: true,
    started: true,
    call: {call_id: "stale", role: "caller", state: "ringing"},
  })
  await microtask()

  assert.equal(devices.queue[1].capture.released, false)
  assert.equal(controller.getState().presentation, "outgoing_ringing")
  assert.equal(controller.getState().call.call_id, "call-1")
  controller.dispose()
})

test("a superseded start reply does not drop the newer preflight", async () => {
  const signaling = fakeSignaling()
  let settleFirst
  signaling.onStart(() => new Promise(resolve => {
    settleFirst = resolve
  }))
  const devices = deferredDevices()
  const controller = createCallController({signaling, devices})

  controller.startCall(conversation, "audio")
  devices.queue[0].succeed()
  await microtask()

  signaling.onStart(payload => defaultStart(signaling, payload))
  controller.startCall(conversation, "audio")
  assert.equal(devices.queue[1].cancelled, false)

  signaling.replace({
    call: {call_id: "stale", role: "caller", state: "ringing"},
  })
  settleFirst({
    ok: true,
    started: true,
    call: {call_id: "stale", role: "caller", state: "ringing"},
  })
  await microtask()

  assert.equal(devices.queue[1].cancelled, false)
  assert.equal(controller.getState().presentation, "preflighting")
  assert.equal(controller.getState().call, null)
  controller.dispose()
})

test("a superseded cancel does not cancel the Call ID the newer start adopts", async () => {
  const signaling = fakeSignaling()
  let settleFirst
  signaling.onStart(() => new Promise(resolve => {
    settleFirst = resolve
  }))
  const devices = deferredDevices()
  const controller = createCallController({signaling, devices})

  controller.startCall(conversation, "audio")
  devices.queue[0].succeed()
  await microtask()
  controller.cancelCall()

  const call = {call_id: "call-1", role: "caller", state: "ringing", media_intent: "audio"}
  signaling.onStart(() => {
    signaling.replace({call})
    return Promise.resolve({ok: true, started: false, call})
  })
  controller.startCall(conversation, "audio")
  devices.queue[1].succeed()
  await microtask()

  assert.equal(controller.getState().presentation, "outgoing_ringing")
  assert.equal(controller.getState().call.call_id, "call-1")
  assert.equal(signaling.cancels.length, 0)

  signaling.replace({call})
  settleFirst({ok: true, started: true, call})
  await microtask()

  assert.equal(signaling.cancels.length, 0)
  assert.equal(controller.getState().presentation, "outgoing_ringing")
  assert.equal(controller.getState().canCancel, true)
  assert.equal(devices.queue[1].capture.released, false)
  controller.dispose()
})

test("a later busy start does not hide the earlier ringing invitation", async () => {
  const signaling = fakeSignaling()
  let settleFirst
  signaling.onStart(() => new Promise(resolve => {
    settleFirst = resolve
  }))
  const devices = deferredDevices()
  const controller = createCallController({signaling, devices})

  controller.startCall(conversation, "audio")
  devices.queue[0].succeed()
  await microtask()

  const other = {id: "conversation-2", peer: {id: "user-3", username: "bob"}}
  signaling.onStart(() => Promise.resolve({ok: false, error: "busy"}))
  controller.startCall(other, "audio")
  devices.queue[1].succeed()
  await microtask()
  await microtask()
  assert.equal(controller.getState().resultCode, "busy")

  const call = {call_id: "call-first", role: "caller", state: "ringing", media_intent: "audio"}
  signaling.replace({call})
  settleFirst({ok: true, started: true, call})
  await microtask()

  assert.equal(controller.getState().presentation, "outgoing_ringing")
  assert.equal(controller.getState().call.call_id, "call-first")
  assert.equal(controller.getState().canCancel, true)
  controller.dispose()
})

test("a superseded reply is adopted when the newer start converges on that Call ID", async () => {
  const signaling = fakeSignaling()
  let settleFirst
  signaling.onStart(() => new Promise(resolve => {
    settleFirst = resolve
  }))
  const devices = deferredDevices()
  const controller = createCallController({signaling, devices})

  controller.startCall(conversation, "audio")
  devices.queue[0].succeed()
  await microtask()

  const call = {call_id: "call-1", role: "caller", state: "ringing", media_intent: "audio"}
  controller.startCall(conversation, "audio")
  signaling.replace({call})
  settleFirst({ok: true, started: true, call})
  await microtask()

  assert.equal(controller.getState().presentation, "preflighting")
  assert.equal(devices.queue[1].cancelled, false)

  signaling.onStart(() => {
    signaling.replace({call})
    return Promise.resolve({ok: true, started: false, call})
  })
  devices.queue[1].succeed()
  await microtask()

  assert.equal(controller.getState().presentation, "outgoing_ringing")
  assert.equal(controller.getState().call.call_id, "call-1")
  assert.equal(controller.getState().canCancel, true)
  assert.equal(signaling.cancels.length, 0)
  controller.dispose()
})

test("a cancelled older start still cancels a different Call ID after a newer start is busy", async () => {
  const signaling = fakeSignaling()
  let settleFirst
  signaling.onStart(() => new Promise(resolve => {
    settleFirst = resolve
  }))
  const devices = deferredDevices()
  const controller = createCallController({signaling, devices})

  controller.startCall(conversation, "audio")
  devices.queue[0].succeed()
  await microtask()
  controller.cancelCall()

  const other = {id: "conversation-2", peer: {id: "user-3", username: "bob"}}
  signaling.onStart(() => Promise.resolve({ok: false, error: "busy"}))
  controller.startCall(other, "audio")
  devices.queue[1].succeed()
  await microtask()
  await microtask()

  const call = {call_id: "call-first", role: "caller", state: "ringing", media_intent: "audio"}
  signaling.replace({call})
  settleFirst({ok: true, started: true, call})
  await microtask()

  assert.deepEqual(signaling.cancels, [{callId: "call-first"}])
  controller.dispose()
})

test("a late start acknowledgement after a terminal projection stays terminal", async () => {
  const signaling = fakeSignaling()
  let settleStart
  signaling.onStart(() => new Promise(resolve => {
    settleStart = resolve
  }))
  const devices = deferredDevices()
  const controller = createCallController({signaling, devices})
  controller.startCall(conversation, "audio")
  devices.queue[0].succeed()
  await microtask()

  const call = {call_id: "call-1", role: "caller", state: "ringing", media_intent: "audio"}
  signaling.replace({call})
  await microtask()
  assert.equal(controller.getState().presentation, "outgoing_ringing")

  signaling.replace({call: null})
  await microtask()
  assert.equal(controller.getState().presentation, "result")
  assert.equal(controller.getState().resultCode, "ended")

  signaling.replace({call})
  settleStart({ok: true, started: true, call})
  await microtask()

  assert.equal(controller.getState().presentation, "result")
  assert.equal(controller.getState().resultCode, "ended")
  assert.notEqual(controller.getState().presentation, "outgoing_ringing")
  controller.dispose()
})

test("an old acknowledgement cannot cancel a newer preflight, replace its Call, or release its capture", async () => {
  const signaling = fakeSignaling()
  let settleFirst
  signaling.onStart(() => new Promise(resolve => {
    settleFirst = resolve
  }))
  const devices = deferredDevices()
  const controller = createCallController({signaling, devices})

  controller.startCall(conversation, "audio")
  devices.queue[0].succeed()
  await microtask()

  const stale = {call_id: "call-stale", role: "caller", state: "ringing", media_intent: "audio"}
  signaling.replace({call: stale})
  await microtask()
  signaling.replace({call: null})
  await microtask()

  signaling.onStart(payload => defaultStart(signaling, payload))
  controller.startCall(conversation, "audio")
  assert.equal(controller.getState().presentation, "preflighting")
  assert.equal(devices.queue[1].cancelled, false)

  signaling.replace({call: stale})
  settleFirst({ok: true, started: true, call: stale})
  await microtask()

  assert.equal(devices.queue[1].cancelled, false)
  assert.equal(controller.getState().presentation, "preflighting")
  assert.equal(controller.getState().call, null)

  devices.queue[1].succeed()
  await microtask()
  assert.equal(controller.getState().presentation, "outgoing_ringing")
  assert.equal(controller.getState().call.call_id, "call-1")
  assert.equal(devices.queue[1].capture.released, false)

  signaling.replace({call: stale})
  await microtask()
  assert.equal(devices.queue[1].capture.released, false)
  assert.equal(controller.getState().call.call_id, "call-1")
  controller.dispose()
})

test("each cancelled start cancels its own Call ID and cannot revive the later invitation", async () => {
  const signaling = fakeSignaling()
  let settleFirst
  let settleSecond
  signaling.onStart(() => new Promise(resolve => {
    settleFirst = resolve
  }))
  const devices = deferredDevices()
  const controller = createCallController({signaling, devices})

  controller.startCall(conversation, "audio")
  devices.queue[0].succeed()
  await microtask()
  controller.cancelCall()

  signaling.onStart(() => new Promise(resolve => {
    settleSecond = resolve
  }))
  controller.startCall(conversation, "audio")
  devices.queue[1].succeed()
  await microtask()
  controller.cancelCall()

  const callA = {call_id: "call-a", role: "caller", state: "ringing", media_intent: "audio"}
  const callB = {call_id: "call-b", role: "caller", state: "ringing", media_intent: "audio"}

  signaling.replace({call: callA})
  settleFirst({ok: true, started: true, call: callA})
  await microtask()
  signaling.replace({call: callB})
  settleSecond({ok: true, started: true, call: callB})
  await microtask()

  assert.equal(signaling.cancels.length, 2)
  assert.deepEqual(signaling.cancels.map(item => item.callId).sort(), ["call-a", "call-b"])
  assert.notEqual(controller.getState().presentation, "outgoing_ringing")
  controller.dispose()
})

test("reconnect does not replay a start mutation", async () => {
  const signaling = fakeSignaling()
  const devices = deferredDevices()
  const controller = createCallController({signaling, devices})
  await startRinging(controller, devices)
  signaling.replace({connectionStatus: "disconnected", signalingSessionId: null, call: null})
  assert.equal(controller.getState().presentation, "idle")
  assert.equal(devices.queue[0].capture.released, true)

  signaling.replace({
    connectionStatus: "connected",
    signalingSessionId: "session-2",
    call: {call_id: "call-1", role: "caller", state: "ringing"},
  })
  assert.equal(controller.getState().presentation, "outgoing_ringing")
  assert.equal(controller.getState().statusText, "Calling alice…")
  assert.equal(signaling.starts.length, 1)
  controller.dispose()
})

test("page teardown via disconnect releases ringing capture without sending cancel", async () => {
  const signaling = fakeSignaling()
  const devices = deferredDevices()
  const controller = createCallController({signaling, devices})
  await startRinging(controller, devices)

  signaling.replace({connectionStatus: "disconnected", signalingSessionId: null, call: null})
  assert.equal(devices.queue[0].capture.released, true)
  assert.equal(signaling.cancels.length, 0)
  assert.equal(controller.getState().presentation, "idle")
  controller.dispose()
})

test("transport unavailable is distinct from start failures and stays retryable", async () => {
  const signaling = fakeSignaling()
  signaling.onStart(() => Promise.resolve({ok: false, error: "unavailable"}))
  const devices = deferredDevices()
  const controller = createCallController({signaling, devices})
  await startAfterPreflight(controller, devices)

  assert.equal(controller.getState().presentation, "unavailable")
  assert.equal(
    controller.getState().statusText,
    "Calling is unavailable. Reconnect, then try again.",
  )
  assert.equal(controller.getState().canRetry, true)
  assert.equal(controller.getState().canDismiss, true)
  controller.dismiss()
  assert.equal(controller.getState().presentation, "idle")
  controller.dispose()
})

test("a cancel that is not accepted shows the ringing invitation again", async () => {
  const signaling = fakeSignaling()
  let settleStart
  signaling.onStart(() => new Promise(resolve => {
    settleStart = resolve
  }))
  const devices = deferredDevices()
  const controller = createCallController({signaling, devices})
  controller.startCall(conversation, "audio")
  devices.queue[0].succeed()
  await microtask()
  controller.cancelCall()

  const call = {call_id: "call-late", role: "caller", state: "ringing", media_intent: "audio"}
  let attempts = 0
  signaling.cancelCall = () => {
    attempts += 1
    return Promise.resolve({ok: false, error: "timeout"})
  }

  signaling.replace({call})
  settleStart({ok: true, started: true, call})
  await microtask()

  assert.equal(attempts, 1)
  assert.equal(controller.getState().presentation, "outgoing_ringing")
  assert.equal(controller.getState().canCancel, true)
  assert.equal(controller.getState().call.call_id, "call-late")
  controller.dispose()
})

test("an unavailable cancel is retried once, then the ringing control returns", async () => {
  const signaling = fakeSignaling()
  let settleStart
  signaling.onStart(() => new Promise(resolve => {
    settleStart = resolve
  }))
  const devices = deferredDevices()
  const controller = createCallController({signaling, devices})
  controller.startCall(conversation, "audio")
  devices.queue[0].succeed()
  await microtask()
  controller.cancelCall()

  const call = {call_id: "call-late", role: "caller", state: "ringing", media_intent: "audio"}
  let attempts = 0
  signaling.cancelCall = () => {
    attempts += 1
    return Promise.resolve({ok: false, error: "unavailable"})
  }

  signaling.replace({call, callTopicStatus: "joining"})
  settleStart({ok: true, started: true, call})
  await microtask()
  assert.equal(attempts, 1)
  assert.notEqual(controller.getState().presentation, "outgoing_ringing")

  signaling.replace({call, callTopicStatus: "joined"})
  await microtask()
  assert.equal(attempts, 2)
  assert.equal(controller.getState().presentation, "outgoing_ringing")
  assert.equal(controller.getState().canCancel, true)

  signaling.replace({call, callTopicStatus: "joined"})
  await microtask()
  assert.equal(attempts, 2)
  controller.dispose()
})

test("an unavailable cancel retries after the Call topic becomes commandable", async () => {
  const signaling = fakeSignaling()
  let settleStart
  signaling.onStart(() => new Promise(resolve => {
    settleStart = resolve
  }))
  const devices = deferredDevices()
  const controller = createCallController({signaling, devices})
  controller.startCall(conversation, "audio")
  devices.queue[0].succeed()
  await microtask()
  controller.cancelCall()

  const call = {call_id: "call-late", role: "caller", state: "ringing", media_intent: "audio"}
  let attempts = 0
  signaling.cancelCall = payload => {
    attempts += 1
    if (attempts === 1) return Promise.resolve({ok: false, error: "unavailable"})
    signaling.cancels.push(payload)
    return Promise.resolve({ok: true, call: {call_id: payload.callId, terminal_outcome: "cancelled"}})
  }

  signaling.replace({call, callTopicStatus: "joining"})
  settleStart({ok: true, started: true, call})
  await microtask()
  assert.equal(attempts, 1)
  assert.equal(signaling.cancels.length, 0)
  assert.notEqual(controller.getState().presentation, "outgoing_ringing")

  signaling.replace({call, callTopicStatus: "joined"})
  await microtask()
  assert.deepEqual(signaling.cancels, [{callId: "call-late"}])
  assert.notEqual(controller.getState().presentation, "outgoing_ringing")
  controller.dispose()
})

test("a failed Call-topic join restores ringing and its cancel control without another projection", async () => {
  const signaling = fakeSignaling()
  let settleStart
  signaling.onStart(() => new Promise(resolve => {
    settleStart = resolve
  }))
  const devices = deferredDevices()
  const controller = createCallController({signaling, devices})
  controller.startCall(conversation, "audio")
  devices.queue[0].succeed()
  await microtask()
  controller.cancelCall()

  const call = {call_id: "call-late", role: "caller", state: "ringing", media_intent: "audio"}
  let attempts = 0
  signaling.cancelCall = () => {
    attempts += 1
    return Promise.resolve({ok: false, error: "unavailable"})
  }

  signaling.replace({call, callTopicStatus: "joining"})
  settleStart({ok: true, started: true, call})
  await microtask()
  assert.equal(attempts, 1)
  assert.notEqual(controller.getState().presentation, "outgoing_ringing")

  signaling.replace({call, callTopicStatus: "failed"})
  await microtask()
  assert.equal(attempts, 1)
  assert.equal(controller.getState().presentation, "outgoing_ringing")
  assert.equal(controller.getState().canCancel, true)
  assert.equal(controller.getState().call.call_id, "call-late")
  controller.dispose()
})

test("cancellation does not retry automatically after reconnect", async () => {
  const signaling = fakeSignaling()
  let settleStart
  signaling.onStart(() => new Promise(resolve => {
    settleStart = resolve
  }))
  const devices = deferredDevices()
  const controller = createCallController({signaling, devices})
  controller.startCall(conversation, "audio")
  devices.queue[0].succeed()
  await microtask()
  controller.cancelCall()

  const call = {call_id: "call-late", role: "caller", state: "ringing", media_intent: "audio"}
  let attempts = 0
  signaling.cancelCall = payload => {
    attempts += 1
    signaling.cancels.push(payload)
    return Promise.resolve({ok: false, error: "unavailable"})
  }

  signaling.replace({call, callTopicStatus: "joining"})
  settleStart({ok: true, started: true, call})
  await microtask()
  assert.equal(attempts, 1)
  assert.notEqual(controller.getState().presentation, "outgoing_ringing")

  signaling.replace({connectionStatus: "disconnected", signalingSessionId: null, call: null})
  await microtask()
  signaling.replace({
    connectionStatus: "connected",
    signalingSessionId: "session-2",
    call,
    callTopicStatus: "joined",
  })
  await microtask()

  assert.equal(attempts, 1)
  assert.equal(controller.getState().presentation, "outgoing_ringing")
  assert.equal(controller.getState().canCancel, true)
  controller.dispose()
})

test("dismiss is not offered while the transport connection is unavailable", () => {
  const signaling = fakeSignaling()
  const controller = createCallController({signaling, devices: deferredDevices()})

  signaling.replace({connectionStatus: "unavailable", call: null})
  assert.equal(controller.getState().presentation, "unavailable")
  assert.equal(controller.getState().canRetry, true)
  assert.equal(controller.getState().canDismiss, false)

  controller.dismiss()
  assert.equal(controller.getState().presentation, "unavailable")
  controller.dispose()
})

test("retry is a new deliberate start and dismiss returns to idle", async () => {
  const signaling = fakeSignaling()
  signaling.onStart(() => Promise.resolve({ok: false, error: "busy"}))
  const devices = deferredDevices()
  const controller = createCallController({signaling, devices})
  await startAfterPreflight(controller, devices)
  signaling.onStart(payload => defaultStart(signaling, payload))

  controller.retry()
  assert.equal(controller.getState().presentation, "preflighting")
  devices.queue[1].succeed()
  await microtask()
  assert.equal(signaling.starts.length, 2)
  assert.equal(controller.getState().presentation, "outgoing_ringing")

  controller.cancelCall()
  signaling.replace({call: null})
  controller.dismiss()
  assert.equal(controller.getState().presentation, "idle")
  controller.dispose()
})

test("preflight then starts a video invitation with audio-plus-video capture and no peer identity", async () => {
  const signaling = fakeSignaling()
  const devices = deferredDevices()
  const controller = createCallController({signaling, devices})

  controller.startCall(conversation, "video")
  assert.equal(controller.getState().presentation, "preflighting")
  assert.equal(controller.getState().mediaIntent, "video")
  assert.equal(controller.getState().statusText, "Preparing video call… Cancel stops preparation; the browser prompt may still need dismissal.")
  assert.equal(controller.getState().canCancel, true)
  assert.equal(signaling.starts.length, 0)
  assert.deepEqual(devices.queue[0].request, {audio: true, video: true})

  devices.queue[0].succeed()
  await microtask()

  assert.equal(signaling.starts.length, 1)
  assert.deepEqual(signaling.starts[0], {
    directConversationId: "conversation-1",
    mediaIntent: "video",
  })
  assert.equal(signaling.starts[0].peer, undefined)
  assert.equal(signaling.starts[0].userId, undefined)
  assert.equal(controller.getState().presentation, "outgoing_ringing")
  assert.equal(controller.getState().statusText, "Calling alice…")
  assert.equal(controller.getState().call.media_intent, "video")
  assert.equal(devices.queue[0].capture.released, false)
  controller.dispose()
})

test("invalid media intent is a no-op", () => {
  const signaling = fakeSignaling()
  const devices = deferredDevices()
  const controller = createCallController({signaling, devices})

  controller.startCall(conversation, "screen")
  controller.startCall(conversation)
  controller.startCall(conversation, "AUDIO")

  assert.equal(devices.queue.length, 0)
  assert.equal(signaling.starts.length, 0)
  assert.equal(controller.getState().presentation, "idle")
  controller.dispose()
})

test("video microphone failure sends no start, offers retry, and no audio fallback", async () => {
  const cases = {
    "permission-denied": "Microphone access is blocked. Try again when you're ready.",
    "no-device": "No microphone is available.",
    "unknown-error": "Couldn't start the microphone.",
  }

  for (const [error, copy] of Object.entries(cases)) {
    const signaling = fakeSignaling()
    const devices = deferredDevices()
    const controller = createCallController({signaling, devices})
    controller.startCall(conversation, "video")
    devices.queue[0].fail(error, {device: "microphone"})
    await microtask()

    const state = controller.getState()
    assert.equal(signaling.starts.length, 0)
    assert.equal(state.presentation, "result")
    assert.equal(state.mediaIntent, "video")
    assert.equal(state.canRetry, true)
    assert.equal(state.canFallbackToAudio, false)
    assert.equal(state.statusText, copy)
    controller.dispose()
  }
})

test("camera failure sends no start, retains visibly ready microphone, and exposes audio fallback", async () => {
  const cases = {
    "permission-denied": "Camera access is blocked. Check browser and system camera settings, then retry when ready.",
    "no-device": "No camera is available. Connect a camera, then retry.",
    "unknown-error": "Couldn't start the camera. Retry when ready.",
  }

  for (const [error, copy] of Object.entries(cases)) {
    const signaling = fakeSignaling()
    const devices = deferredDevices()
    const controller = createCallController({signaling, devices})
    controller.startCall(conversation, "video")
    devices.queue[0].fail(error, {device: "camera"})
    await microtask()

    const state = controller.getState()
    assert.equal(signaling.starts.length, 0)
    assert.equal(devices.queue[0].capture.released, false)
    assert.equal(state.presentation, "result")
    assert.equal(state.mediaIntent, "video")
    assert.equal(state.resultCode, error)
    assert.equal(state.canRetry, true)
    assert.equal(state.canFallbackToAudio, true)
    assert.equal(state.statusText, copy + " Microphone ready.")
    controller.dispose()
  }
})

test("retry after camera failure repeats only camera preflight", async () => {
  const signaling = fakeSignaling()
  const devices = deferredDevices()
  const controller = createCallController({signaling, devices})
  controller.startCall(conversation, "video")
  devices.queue[0].fail("permission-denied", {device: "camera"})
  await microtask()

  controller.retry()
  assert.equal(controller.getState().presentation, "preflighting")
  assert.equal(controller.getState().mediaIntent, "video")
  assert.deepEqual(devices.queue[1].request, {audio: false, video: true})
  assert.equal(signaling.starts.length, 0)

  devices.queue[1].succeed()
  await microtask()
  await microtask()
  assert.deepEqual(signaling.starts[0], {
    directConversationId: "conversation-1",
    mediaIntent: "video",
  })
  controller.dispose()
})

test("explicit audio fallback reuses the microphone and does not revive video", async () => {
  const signaling = fakeSignaling()
  const devices = deferredDevices()
  const controller = createCallController({signaling, devices})
  controller.startCall(conversation, "video")
  devices.queue[0].fail("no-device", {device: "camera"})
  await microtask()

  controller.fallbackToAudio()
  assert.equal(controller.getState().presentation, "preflighting")
  assert.equal(controller.getState().mediaIntent, "audio")
  assert.equal(controller.getState().canFallbackToAudio, false)
  assert.equal(devices.queue.length, 1)
  assert.equal(signaling.starts.length, 0)
  await microtask()
  assert.deepEqual(signaling.starts[0], {
    directConversationId: "conversation-1",
    mediaIntent: "audio",
  })
  assert.equal(controller.getState().presentation, "outgoing_ringing")
  controller.dispose()
})

test("rejected audio fallback releases its microphone and does not revive video", async () => {
  const signaling = fakeSignaling()
  const devices = deferredDevices()
  const controller = createCallController({signaling, devices})
  controller.startCall(conversation, "video")
  devices.queue[0].fail("permission-denied", {device: "camera"})
  await microtask()

  signaling.onStart(() => Promise.resolve({ok: false, error: "busy"}))
  controller.fallbackToAudio()
  await microtask()
  await microtask()

  const state = controller.getState()
  assert.equal(signaling.starts.length, 1)
  assert.equal(state.mediaIntent, "audio")
  assert.equal(state.canFallbackToAudio, false)
  assert.equal(state.resultCode, "busy")
  assert.equal(devices.queue.length, 1)
  assert.equal(devices.queue[0].capture.released, true)
  controller.dispose()
})

test("fallback is a no-op unless the current result is a camera failure", async () => {
  const signaling = fakeSignaling()
  const devices = deferredDevices()
  const controller = createCallController({signaling, devices})

  controller.fallbackToAudio()
  assert.equal(devices.queue.length, 0)

  controller.startCall(conversation, "video")
  devices.queue[0].fail("permission-denied", {device: "microphone"})
  await microtask()
  controller.fallbackToAudio()
  assert.equal(devices.queue.length, 1)
  assert.equal(controller.getState().mediaIntent, "video")
  controller.dispose()
})

test("video copy never mislabels preparation, cancel, ended, or generic start failure as voice", async () => {
  const signaling = fakeSignaling()
  const devices = deferredDevices()
  const controller = createCallController({signaling, devices})
  controller.startCall(conversation, "video")
  assert.equal(controller.getState().statusText, "Preparing video call… Cancel stops preparation; the browser prompt may still need dismissal.")
  controller.cancelCall()
  assert.equal(controller.getState().presentation, "idle")

  await startVideoRinging(controller, devices)
  controller.cancelCall()
  signaling.replace({call: null})
  assert.equal(controller.getState().statusText, "Video call cancelled.")
  controller.dispose()

  const ended = fakeSignaling()
  const endedDevices = deferredDevices()
  const ending = createCallController({signaling: ended, devices: endedDevices})
  await startVideoRinging(ending, endedDevices)
  ended.replace({call: null})
  assert.equal(ending.getState().statusText, "The video call ended.")
  ending.dispose()

  const failed = fakeSignaling()
  failed.onStart(() => Promise.resolve({ok: false, error: "unexpected"}))
  const failedDevices = deferredDevices()
  const failing = createCallController({signaling: failed, devices: failedDevices})
  await startVideoAfterPreflight(failing, failedDevices)
  assert.equal(failing.getState().statusText, "Couldn't start the video call.")
  failing.dispose()
})

test("successful video ringing retains capture until rejection, replacement, transport loss, and disposal", async () => {
  const signaling = fakeSignaling()
  signaling.onStart(() => Promise.resolve({ok: false, error: "busy"}))
  const devices = deferredDevices()
  const controller = createCallController({signaling, devices})
  await startVideoAfterPreflight(controller, devices)
  assert.equal(devices.queue[0].capture.released, true)
  controller.dispose()

  const replaced = fakeSignaling()
  const replacedDevices = deferredDevices()
  const replacing = createCallController({signaling: replaced, devices: replacedDevices})
  await startVideoRinging(replacing, replacedDevices)
  replaced.replace({
    call: {call_id: "call-2", role: "caller", state: "ringing", media_intent: "video"},
  })
  assert.equal(replacedDevices.queue[0].capture.released, true)
  replacing.dispose()

  const lost = fakeSignaling()
  const lostDevices = deferredDevices()
  const losing = createCallController({signaling: lost, devices: lostDevices})
  await startVideoRinging(losing, lostDevices)
  lost.replace({connectionStatus: "unavailable", call: null})
  assert.equal(lostDevices.queue[0].capture.released, true)
  losing.dispose()

  const disposedSignaling = fakeSignaling()
  const disposedDevices = deferredDevices()
  const disposing = createCallController({signaling: disposedSignaling, devices: disposedDevices})
  await startVideoRinging(disposing, disposedDevices)
  disposing.dispose()
  assert.equal(disposedDevices.queue[0].capture.released, true)
})

test("an authoritative audio projection releases mismatched video capture and shows audio", async () => {
  const signaling = fakeSignaling()
  const devices = deferredDevices()
  const controller = createCallController({signaling, devices})
  controller.startCall(conversation, "video")
  devices.queue[0].succeed()
  await microtask()

  signaling.replace({
    call: {
      call_id: "call-1",
      role: "caller",
      state: "ringing",
      media_intent: "audio",
    },
  })
  await microtask()

  assert.equal(controller.getState().presentation, "outgoing_ringing")
  assert.equal(controller.getState().mediaIntent, "audio")
  assert.equal(controller.getState().call.media_intent, "audio")
  assert.equal(devices.queue[0].capture.released, true)
  controller.dispose()
})

test("a converged audio start reply overrides a local video request and releases video capture", async () => {
  const signaling = fakeSignaling()
  const call = {
    call_id: "call-existing",
    role: "caller",
    state: "ringing",
    media_intent: "audio",
  }
  signaling.onStart(() => {
    signaling.replace({call})
    return Promise.resolve({ok: true, started: false, call})
  })
  const devices = deferredDevices()
  const controller = createCallController({signaling, devices})
  controller.startCall(conversation, "video")
  devices.queue[0].succeed()
  await microtask()

  assert.equal(signaling.starts[0].mediaIntent, "video")
  assert.equal(controller.getState().presentation, "outgoing_ringing")
  assert.equal(controller.getState().mediaIntent, "audio")
  assert.equal(controller.getState().call.media_intent, "audio")
  assert.equal(devices.queue[0].capture.released, true)
  controller.dispose()
})

test("late full and partial video results cannot start or retain resources after a newer action", async () => {
  const signaling = fakeSignaling()
  const devices = deferredDevices()
  const controller = createCallController({signaling, devices})
  controller.startCall(conversation, "video")
  controller.startCall({...conversation, id: "replacement-conversation"}, "video")

  devices.queue[0].succeed()
  await microtask()
  assert.equal(signaling.starts.length, 0)
  assert.equal(devices.queue[0].capture.released, true)
  assert.equal(controller.getState().presentation, "preflighting")

  devices.queue[1].fail("no-device", {device: "camera"})
  await microtask()
  assert.equal(devices.queue[1].capture.released, false)
  assert.equal(signaling.starts.length, 0)

  controller.fallbackToAudio()
  devices.queue[1].succeed?.()
  await microtask()
  assert.equal(devices.queue.length, 2)
  assert.equal(signaling.starts.length, 1)
  assert.equal(signaling.starts[0].mediaIntent, "audio")
  controller.dispose()
})

test("late camera failure after cancel, transport loss, or disposal releases partial capture without starting", async () => {
  const signaling = fakeSignaling()
  const devices = deferredDevices()
  const controller = createCallController({signaling, devices})
  controller.startCall(conversation, "video")
  controller.cancelCall()
  devices.queue[0].fail("permission-denied", {device: "camera"})
  await microtask()
  assert.equal(signaling.starts.length, 0)
  assert.equal(devices.queue[0].capture.released, true)
  controller.dispose()

  const lost = fakeSignaling()
  const lostDevices = deferredDevices()
  const losing = createCallController({signaling: lost, devices: lostDevices})
  losing.startCall(conversation, "video")
  lost.replace({connectionStatus: "unavailable", call: null})
  lostDevices.queue[0].fail("no-device", {device: "camera"})
  await microtask()
  assert.equal(lost.starts.length, 0)
  assert.equal(lostDevices.queue[0].capture.released, true)
  losing.dispose()

  const disposedSignaling = fakeSignaling()
  const disposedDevices = deferredDevices()
  const disposing = createCallController({signaling: disposedSignaling, devices: disposedDevices})
  disposing.startCall(conversation, "video")
  disposing.dispose()
  disposedDevices.queue[0].succeed()
  await microtask()
  assert.equal(disposedSignaling.starts.length, 0)
  assert.equal(disposedDevices.queue[0].capture.released, true)
})

test("an elsewhere ownership projection invalidates pending video work and releases capture", async () => {
  const signaling = fakeSignaling()
  const devices = deferredDevices()
  const controller = createCallController({signaling, devices})
  controller.startCall(conversation, "video")

  signaling.replace({
    call: {
      call_id: "call-owned",
      role: "caller",
      state: "ringing",
      media_intent: "video",
      ownership: "elsewhere",
    },
  })
  assert.equal(devices.queue[0].cancelled, true)

  devices.queue[0].succeed()
  await microtask()
  assert.equal(signaling.starts.length, 0)
  assert.equal(devices.queue[0].capture.released, true)
  assert.equal(controller.getState().call?.ownership, "elsewhere")
  controller.dispose()

  const ringing = fakeSignaling()
  const ringingDevices = deferredDevices()
  const owner = createCallController({signaling: ringing, devices: ringingDevices})
  await startVideoRinging(owner, ringingDevices)
  ringing.replace({
    call: {
      call_id: "call-1",
      role: "caller",
      state: "ringing",
      media_intent: "video",
      ownership: "elsewhere",
    },
  })
  assert.equal(ringingDevices.queue[0].capture.released, true)
  assert.equal(owner.getState().presentation, "outgoing_ringing")
  owner.dispose()
})

test("an unclaimed ringing recipient keeps the full intent-matched dialog flow", async () => {
  const call = {
    call_id: "incoming-unclaimed",
    role: "recipient",
    state: "ringing",
    media_intent: "video",
    ownership: "unclaimed",
    peer: {id: "caller-1", username: "alice"},
  }
  const signaling = fakeSignaling({call})
  const devices = deferredDevices()
  const controller = createCallController({signaling, devices})

  assert.equal(controller.getState().presentation, "incoming_ringing")
  assert.equal(controller.getState().canAcceptVideo, true)
  assert.equal(controller.getState().canAnswerWithoutVideo, true)
  assert.equal(controller.getState().canDecline, true)
  assert.equal(devices.queue.length, 0)

  controller.acceptCall("video")
  assert.deepEqual(devices.queue[0].request, {audio: true, video: true})
  devices.queue[0].succeed()
  await microtask()
  assert.deepEqual(signaling.accepts, [{callId: call.call_id, answerMode: "video"}])
  controller.dispose()
})

test("a flip to elsewhere cancels pending recipient preflight and never answers", async () => {
  const call = {
    call_id: "incoming-lost",
    role: "recipient",
    state: "ringing",
    media_intent: "audio",
    ownership: "unclaimed",
    peer: {id: "caller-1", username: "alice"},
  }
  const signaling = fakeSignaling({call})
  const devices = deferredDevices()
  const controller = createCallController({signaling, devices})

  controller.acceptCall("audio")
  assert.equal(devices.queue[0].cancelled, false)

  signaling.replace({call: {...call, state: "connecting", ownership: "elsewhere"}})

  assert.equal(devices.queue[0].cancelled, true)
  devices.queue[0].succeed()
  await microtask()

  assert.equal(signaling.accepts.length, 0)
  assert.equal(devices.queue[0].capture.released, true)
  assert.equal(controller.getState().presentation, "owned_elsewhere")
  assert.equal(controller.getState().statusText, "Call active in another tab.")
  assert.equal(controller.getState().canAcceptAudio, false)
  assert.equal(controller.getState().canAcceptVideo, false)
  assert.equal(controller.getState().canAnswerWithoutVideo, false)
  assert.equal(controller.getState().canDecline, false)
  assert.equal(controller.getState().canLeave, false)
  assert.equal(controller.getState().canCancel, false)

  controller.acceptCall("audio")
  controller.declineCall()
  controller.leaveCall()
  controller.cancelCall()
  assert.equal(signaling.accepts.length, 0)
  assert.equal(signaling.declines.length, 0)
  assert.equal(signaling.leaves.length, 0)
  assert.equal(signaling.cancels.length, 0)
  controller.dispose()
})

test("a flip to elsewhere ignores late accept, decline, and leave acknowledgements", async () => {
  const call = {
    call_id: "incoming-late",
    role: "recipient",
    state: "ringing",
    media_intent: "audio",
    ownership: "unclaimed",
    peer: {id: "caller-1", username: "alice"},
  }
  const signaling = fakeSignaling({call})
  const devices = deferredDevices()
  const controller = createCallController({signaling, devices})

  let settleAccept = null
  signaling.acceptCall = payload => {
    signaling.accepts.push({...payload})
    return new Promise(resolve => {
      settleAccept = resolve
    })
  }

  controller.acceptCall("audio")
  devices.queue[0].succeed()
  await microtask()
  assert.equal(signaling.accepts.length, 1)

  const elsewhere = {...call, state: "connecting", ownership: "elsewhere"}
  signaling.replace({call: elsewhere})

  settleAccept({ok: true, call: {...call, state: "connecting", ownership: "self"}})
  await microtask()
  assert.equal(controller.getState().call.ownership, "elsewhere")
  assert.equal(controller.getState().presentation, "owned_elsewhere")
  assert.equal(devices.queue[0].capture.released, true)

  let settleLeave = null
  signaling.leaveCall = payload => {
    signaling.leaves.push({...payload})
    return new Promise(resolve => {
      settleLeave = resolve
    })
  }
  controller.leaveCall()
  assert.equal(signaling.leaves.length, 0)
  assert.equal(settleLeave, null)

  controller.dispose()
})

test("a caller sibling ringing dock hides cancel while the preferred tab keeps capture", async () => {
  const signaling = fakeSignaling()
  const devices = deferredDevices()
  const preferred = createCallController({signaling, devices})
  await startVideoRinging(preferred, devices)

  assert.equal(preferred.getState().presentation, "outgoing_ringing")
  assert.equal(preferred.getState().canCancel, true)
  assert.equal(devices.queue[0].capture.released, false)

  const siblingCall = {
    call_id: "call-1",
    role: "caller",
    state: "ringing",
    media_intent: "video",
    ownership: "elsewhere",
    peer: {id: "bob", username: "bob"},
  }
  const siblingSignaling = fakeSignaling({call: siblingCall})
  const siblingDevices = deferredDevices()
  const sibling = createCallController({signaling: siblingSignaling, devices: siblingDevices})

  assert.equal(sibling.getState().presentation, "outgoing_ringing")
  assert.equal(sibling.getState().canCancel, false)
  assert.equal(sibling.getState().statusText, "Calling bob from another tab…")
  assert.equal(siblingDevices.queue.length, 0)

  sibling.cancelCall()
  assert.equal(siblingSignaling.cancels.length, 0)

  preferred.dispose()
  sibling.dispose()
})

test("deterministic fallback promotes a caller sibling at connecting", () => {
  const call = {
    call_id: "call-fallback",
    role: "caller",
    state: "ringing",
    media_intent: "audio",
    ownership: "elsewhere",
    peer: {id: "bob", username: "bob"},
  }
  const signaling = fakeSignaling({call})
  const controller = createCallController({signaling, devices: deferredDevices()})

  assert.equal(controller.getState().presentation, "outgoing_ringing")
  assert.equal(controller.getState().canCancel, false)

  signaling.replace({call: {...call, state: "connecting", ownership: "self", answer_mode: "audio"}})

  assert.equal(controller.getState().presentation, "connecting")
  assert.equal(controller.getState().canLeave, true)
  assert.equal(controller.getState().statusText, "Connecting with fake call setup…")

  signaling.replace({call: {...call, state: "active", ownership: "self", answer_mode: "audio"}})
  assert.equal(controller.getState().presentation, "active")
  assert.equal(controller.getState().canLeave, true)
  controller.dispose()
})

test("leaveCall refuses a connecting or active tab whose role has no live winner", () => {
  const call = {
    call_id: "call-unclaimed",
    role: "caller",
    state: "active",
    media_intent: "audio",
    ownership: "unclaimed",
    peer: {id: "bob", username: "bob"},
  }
  const signaling = fakeSignaling({call})
  const controller = createCallController({signaling, devices: deferredDevices()})

  assert.equal(controller.getState().presentation, "active")
  assert.equal(controller.getState().canLeave, false)

  controller.leaveCall()
  assert.equal(signaling.leaves.length, 0)
  controller.dispose()
})

test("a reconnect snapshot applies server ownership without replaying mutations", () => {
  const call = {
    call_id: "call-reconnect",
    role: "recipient",
    state: "connecting",
    media_intent: "audio",
    ownership: "elsewhere",
    peer: {id: "caller-1", username: "alice"},
  }
  const signaling = fakeSignaling({call})
  const controller = createCallController({signaling, devices: deferredDevices()})

  assert.equal(controller.getState().presentation, "owned_elsewhere")

  signaling.replace({connectionStatus: "disconnected", call: null})
  signaling.replace({connectionStatus: "connected", call})

  assert.equal(controller.getState().presentation, "owned_elsewhere")
  assert.equal(controller.getState().statusText, "Call active in another tab.")
  assert.equal(controller.getState().canLeave, false)
  assert.equal(signaling.accepts.length, 0)
  assert.equal(signaling.declines.length, 0)
  assert.equal(signaling.leaves.length, 0)
  assert.equal(signaling.cancels.length, 0)
  controller.dispose()
})

test("a self ownership keeps recipient capture and controls through active", async () => {
  const call = {
    call_id: "call-owned",
    role: "recipient",
    state: "ringing",
    media_intent: "audio",
    ownership: "unclaimed",
    peer: {id: "caller-1", username: "alice"},
  }
  const signaling = fakeSignaling({call})
  const devices = deferredDevices()
  const controller = createCallController({signaling, devices})

  controller.acceptCall("audio")
  devices.queue[0].succeed()
  await microtask()

  signaling.replace({call: {...call, state: "connecting", ownership: "self", answer_mode: "audio"}})
  assert.equal(controller.getState().presentation, "connecting")
  assert.equal(controller.getState().canLeave, true)
  assert.equal(devices.queue[0].capture.released, false)

  signaling.replace({call: {...call, state: "active", ownership: "self", answer_mode: "audio"}})
  assert.equal(controller.getState().presentation, "active")
  assert.equal(controller.getState().canLeave, true)
  assert.equal(devices.queue[0].capture.released, false)

  controller.leaveCall()
  assert.deepEqual(signaling.leaves, [{callId: call.call_id}])

  signaling.replace({
    connectionStatus: "connected",
    call: null,
    terminalCall: {call_id: call.call_id, terminal_outcome: "ended"},
  })
  assert.equal(devices.queue[0].capture.released, true)
  controller.dispose()
})

test("incoming audio and video ring globally without device work and expose intent-matched choices", () => {
  const audio = {
    call_id: "incoming-audio",
    role: "recipient",
    state: "ringing",
    media_intent: "audio",
    peer: {id: "caller-1", username: "alice"},
  }
  const signaling = fakeSignaling({call: audio})
  const devices = deferredDevices()
  const controller = createCallController({signaling, devices})

  assert.equal(controller.getState().presentation, "incoming_ringing")
  assert.equal(controller.getState().peerName, "alice")
  assert.equal(controller.getState().canAcceptAudio, true)
  assert.equal(controller.getState().canAcceptVideo, false)
  assert.equal(controller.getState().canAnswerWithoutVideo, false)
  assert.equal(controller.getState().canDecline, true)
  assert.equal(devices.queue.length, 0)

  signaling.replace({call: {...audio, call_id: "incoming-video", media_intent: "video"}})
  assert.equal(controller.getState().presentation, "incoming_ringing")
  assert.equal(controller.getState().canAcceptAudio, false)
  assert.equal(controller.getState().canAcceptVideo, true)
  assert.equal(controller.getState().canAnswerWithoutVideo, true)
  assert.equal(devices.queue.length, 0)
  controller.dispose()
})

test("video recipient chooses exact video or audio-only preflight on the same Call ID", async () => {
  for (const [answerMode, request] of [
    ["video", {audio: true, video: true}],
    ["audio", {audio: true, video: false}],
  ]) {
    const call = {
      call_id: `incoming-${answerMode}`,
      role: "recipient",
      state: "ringing",
      media_intent: "video",
      peer: {id: "caller-1", username: "alice"},
    }
    const signaling = fakeSignaling({call})
    const devices = deferredDevices()
    const controller = createCallController({signaling, devices})

    controller.acceptCall(answerMode)
    assert.deepEqual(devices.queue[0].request, request)
    devices.queue[0].succeed()
    await microtask()
    assert.deepEqual(signaling.accepts, [{callId: call.call_id, answerMode}])
    assert.equal(controller.getState().mediaIntent, "video")
    controller.dispose()
  }
})

test("camera failure keeps current microphone capture for an explicit audio-only answer", async () => {
  const call = {
    call_id: "incoming-camera-failure",
    role: "recipient",
    state: "ringing",
    media_intent: "video",
    peer: {id: "caller-1", username: "alice"},
  }
  const signaling = fakeSignaling({call})
  const devices = deferredDevices()
  const controller = createCallController({signaling, devices})

  controller.acceptCall("video")
  devices.queue[0].fail("permission-denied", {device: "camera"})
  await microtask()
  assert.equal(devices.queue[0].capture.released, false)
  assert.equal(signaling.accepts.length, 0)
  assert.equal(controller.getState().call.call_id, call.call_id)
  assert.equal(controller.getState().mediaIntent, "video")
  assert.equal(controller.getState().canAnswerWithoutVideo, true)
  assert.match(controller.getState().statusText, /Camera access is blocked/)

  controller.acceptCall("audio")
  await microtask()
  await microtask()
  assert.equal(devices.queue.length, 1)
  assert.deepEqual(signaling.accepts, [{callId: call.call_id, answerMode: "audio"}])
  controller.dispose()
  assert.equal(devices.queue[0].capture.released, true)
})

test("decline and replacement invalidate video recipient preflight and release late capture", async () => {
  const call = {
    call_id: "incoming-video-stale",
    role: "recipient",
    state: "ringing",
    media_intent: "video",
    peer: {id: "caller-1", username: "alice"},
  }
  const signaling = fakeSignaling({call})
  const devices = deferredDevices()
  const controller = createCallController({signaling, devices})

  controller.acceptCall("video")
  controller.declineCall()
  assert.equal(devices.queue[0].cancelled, true)
  assert.deepEqual(signaling.declines, [{callId: call.call_id}])
  devices.queue[0].succeed()
  await microtask()
  assert.equal(devices.queue[0].capture.released, true)
  assert.equal(signaling.accepts.length, 0)

  signaling.replace({call: {...call, call_id: "incoming-video-replacement"}})
  controller.acceptCall("audio")
  signaling.replace({call: {...call, call_id: "incoming-newer"}})
  assert.equal(devices.queue[1].cancelled, true)
  devices.queue[1].succeed()
  await microtask()
  assert.equal(devices.queue[1].capture.released, true)
  assert.equal(signaling.accepts.length, 0)
  controller.dispose()
})

test("microphone failure on either video answer sends no command and remains retryable", async () => {
  for (const answerMode of ["video", "audio"]) {
    const call = {
      call_id: `incoming-mic-${answerMode}`,
      role: "recipient",
      state: "ringing",
      media_intent: "video",
      peer: {id: "caller-1", username: "alice"},
    }
    const signaling = fakeSignaling({call})
    const devices = deferredDevices()
    const controller = createCallController({signaling, devices})
    controller.acceptCall(answerMode)
    devices.queue[0].fail("no-device", {device: "microphone"})
    await microtask()
    assert.equal(signaling.accepts.length, 0)
    assert.equal(controller.getState().presentation, "incoming_ringing")
    assert.equal(controller.getState().canAcceptVideo, true)
    assert.equal(controller.getState().canAnswerWithoutVideo, true)
    assert.equal(controller.getState().canDecline, true)
    assert.match(controller.getState().statusText, /microphone/i)
    controller.dispose()
  }
})

test("recipient audio preflight failure retains the invitation and decline invalidates late work", async () => {
  const call = {
    call_id: "incoming-1",
    role: "recipient",
    state: "ringing",
    media_intent: "audio",
    peer: {id: "caller-1", username: "alice"},
  }
  const signaling = fakeSignaling({call})
  const devices = deferredDevices()
  const controller = createCallController({signaling, devices})

  controller.acceptCall("audio")
  assert.deepEqual(devices.queue[0].request, {audio: true, video: false})
  assert.equal(controller.getState().presentation, "incoming_preflighting")
  devices.queue[0].fail("permission-denied", {device: "microphone"})
  await microtask()
  assert.equal(signaling.accepts.length, 0)
  assert.equal(controller.getState().presentation, "incoming_ringing")
  assert.equal(controller.getState().call.call_id, "incoming-1")
  assert.match(controller.getState().statusText, /Microphone access is blocked/)
  assert.equal(controller.getState().canAcceptAudio, true)

  controller.acceptCall("audio")
  controller.declineCall()
  assert.equal(devices.queue[1].cancelled, true)
  assert.deepEqual(signaling.declines, [{callId: "incoming-1"}])
  devices.queue[1].succeed()
  await microtask()
  assert.equal(devices.queue[1].capture.released, true)
  assert.equal(signaling.accepts.length, 0)
  controller.dispose()
})

test("an answer command failure keeps the invitation, reports it, and allows another answer", async () => {
  const call = {
    call_id: "incoming-3",
    role: "recipient",
    state: "ringing",
    media_intent: "audio",
    peer: {id: "caller-1", username: "alice"},
  }
  const signaling = fakeSignaling({call})
  signaling.acceptCall = payload => {
    signaling.accepts.push({...payload})
    return Promise.resolve({ok: false, error: "timeout"})
  }
  const devices = deferredDevices()
  const controller = createCallController({signaling, devices})

  controller.acceptCall("audio")
  devices.queue[0].succeed()
  await microtask()
  await microtask()

  assert.deepEqual(signaling.accepts, [{callId: "incoming-3", answerMode: "audio"}])
  const state = controller.getState()
  assert.equal(state.presentation, "incoming_ringing")
  assert.equal(state.statusText, "Couldn't answer the call. Try again or decline.")
  assert.equal(state.canAcceptAudio, true)
  assert.equal(state.canDecline, true)
  assert.equal(devices.queue[0].capture.released, true)

  controller.acceptCall("audio")
  assert.equal(controller.getState().presentation, "incoming_preflighting")
  controller.dispose()
})

test("a decline command failure keeps the invitation and reports the failed action", async () => {
  const call = {
    call_id: "incoming-4",
    role: "recipient",
    state: "ringing",
    media_intent: "audio",
    peer: {id: "caller-1", username: "alice"},
  }
  const signaling = fakeSignaling({call})
  signaling.declineCall = payload => {
    signaling.declines.push({...payload})
    return Promise.resolve({ok: false, error: "unavailable"})
  }
  const controller = createCallController({signaling, devices: deferredDevices()})

  controller.declineCall()
  await microtask()

  const state = controller.getState()
  assert.equal(state.presentation, "incoming_ringing")
  assert.equal(state.statusText, "Couldn't decline the call. Try again.")
  assert.equal(state.canDecline, true)
  assert.equal(state.canAcceptAudio, true)
  assert.deepEqual(signaling.declines, [{callId: "incoming-4"}])

  controller.declineCall()
  await microtask()
  assert.equal(signaling.declines.length, 2)
  controller.dispose()
})

test("a leave command failure keeps the call, reports it, and never replays the command", async () => {
  const call = {
    call_id: "active-1",
    role: "recipient",
    state: "active",
    media_intent: "audio",
    ownership: "self",
    peer: {id: "caller-1", username: "alice"},
  }
  const signaling = fakeSignaling({call})
  signaling.leaveCall = payload => {
    signaling.leaves.push({...payload})
    return Promise.resolve({ok: false, error: "timeout"})
  }
  const controller = createCallController({signaling, devices: deferredDevices()})

  controller.leaveCall()
  await microtask()

  const state = controller.getState()
  assert.equal(state.presentation, "active")
  assert.equal(state.statusText, "Couldn't leave the call. Try again.")
  assert.equal(state.canLeave, true)
  assert.deepEqual(signaling.leaves, [{callId: "active-1"}])

  await microtask()
  assert.equal(signaling.leaves.length, 1)
  controller.dispose()
})

test("recipient accepts once, keeps capture through connecting and active, then leaves", async () => {
  const call = {
    call_id: "incoming-2",
    role: "recipient",
    state: "ringing",
    media_intent: "audio",
    peer: {id: "caller-1", username: "alice"},
  }
  const signaling = fakeSignaling({call})
  const devices = deferredDevices()
  const controller = createCallController({signaling, devices})

  controller.acceptCall("audio")
  controller.acceptCall("audio")
  assert.equal(devices.queue.length, 1)
  devices.queue[0].succeed()
  await microtask()
  assert.deepEqual(signaling.accepts, [{callId: "incoming-2", answerMode: "audio"}])
  assert.equal(devices.queue[0].capture.released, false)

  signaling.replace({call: {...call, state: "connecting"}})
  assert.equal(controller.getState().presentation, "connecting")
  assert.equal(controller.getState().canLeave, true)
  assert.equal(devices.queue[0].capture.released, false)

  signaling.replace({call: {...call, state: "active"}})
  assert.equal(controller.getState().presentation, "active")
  controller.leaveCall()
  controller.leaveCall()
  assert.deepEqual(signaling.leaves, [{callId: "incoming-2"}])

  signaling.replace({
    call: null,
    terminalCall: {...call, state: "terminal", terminal_outcome: "ended"},
  })
  assert.equal(devices.queue[0].capture.released, true)
  assert.equal(controller.getState().presentation, "result")
  assert.equal(controller.getState().resultCode, "ended")
  controller.dispose()
})

test("terminal outcomes schedule one deterministic dismissal and stale timers cannot clear a newer call", () => {
  const timers = controlledTimers()
  const base = {
    call_id: "call-1",
    role: "caller",
    media_intent: "audio",
    peer: {id: "peer-1", username: "bob"},
  }
  const signaling = fakeSignaling({call: {...base, state: "active"}})
  const controller = createCallController({
    signaling,
    devices: deferredDevices(),
    scheduleResultDismissal: timers.schedule,
    cancelResultDismissal: timers.cancel,
    resultDisplayMs: 4_000,
  })

  signaling.replace({
    call: null,
    terminalCall: {...base, state: "terminal", terminal_outcome: "failed_capacity"},
  })
  assert.equal(controller.getState().statusText, "The call couldn't start because capacity is unavailable.")
  assert.deepEqual(timers.delays, [4_000])

  signaling.replace({
    call: null,
    terminalCall: {...base, state: "terminal", terminal_outcome: "failed_capacity"},
  })
  assert.deepEqual(timers.delays, [4_000])

  const stale = timers.callbacks[0]
  signaling.replace({
    call: {...base, call_id: "call-2", role: "recipient", state: "ringing", peer: {id: "peer-2", username: "carol"}},
    terminalCall: null,
  })
  assert.equal(controller.getState().presentation, "incoming_ringing")
  stale()
  assert.equal(controller.getState().presentation, "incoming_ringing")
  assert.equal(controller.getState().call.call_id, "call-2")
  controller.dispose()
})

test("terminal outcomes retain distinct copy and manual dismissal does not mutate signaling", () => {
  const expected = {
    declined: "The call was declined.",
    cancelled: "The call was cancelled.",
    timed_out: "The call wasn't answered.",
    relationship_ended: "The call ended because the Friendship changed.",
    failed_capacity: "The call couldn't start because capacity is unavailable.",
    failed: "The call couldn't connect.",
    interrupted: "The call was interrupted.",
    ended: "The call ended.",
  }

  for (const [outcome, copy] of Object.entries(expected)) {
    const signaling = fakeSignaling({
      terminalCall: {
        call_id: `terminal-${outcome}`,
        role: "caller",
        state: "terminal",
        terminal_outcome: outcome,
        media_intent: "audio",
        peer: {id: "peer", username: "alice"},
      },
    })
    const controller = createCallController({signaling, devices: deferredDevices()})
    assert.equal(controller.getState().presentation, "result")
    assert.equal(controller.getState().statusText, copy)
    controller.dismiss()
    assert.equal(controller.getState().presentation, "idle")
    assert.equal(signaling.accepts.length + signaling.declines.length + signaling.leaves.length, 0)
    controller.dispose()
  }
})

test("incoming recipient ringing contends for an incoming ringtone without device capture", () => {
  const call = ringingCall({role: "recipient", ownership: "unclaimed"})
  const signaling = fakeSignaling({call})
  const devices = deferredDevices()
  const cues = fakeCues()
  const controller = createCallController({signaling, devices, cues})

  assert.equal(controller.getState().presentation, "incoming_ringing")
  assert.equal(controller.getState().canAcceptAudio, true)
  assert.deepEqual(cues.contends, [{kind: "incoming", callId: "call-cue"}])
  assert.equal(cues.withdraws, 0)
  assert.equal(devices.queue.length, 0)
  controller.dispose()
})

test("preferred caller ringing contends for ringback and caller siblings stay silent", () => {
  const ownerCues = fakeCues()
  const owner = createCallController({
    signaling: fakeSignaling({call: ringingCall({role: "caller", ownership: "self"})}),
    devices: deferredDevices(),
    cues: ownerCues,
  })
  assert.deepEqual(ownerCues.contends, [{kind: "outgoing", callId: "call-cue"}])
  owner.dispose()

  for (const ownership of ["elsewhere", "unclaimed", null]) {
    const siblingCues = fakeCues()
    const sibling = createCallController({
      signaling: fakeSignaling({call: ringingCall({role: "caller", ownership})}),
      devices: deferredDevices(),
      cues: siblingCues,
    })
    assert.deepEqual(siblingCues.contends, [], `ownership ${ownership}`)
    assert.equal(siblingCues.withdraws, 0)
    sibling.dispose()
  }
})

test("caller owner loss stops the outgoing ringback immediately", () => {
  const call = ringingCall({role: "caller", ownership: "self"})
  const signaling = fakeSignaling({call})
  const cues = fakeCues()
  const controller = createCallController({signaling, devices: deferredDevices(), cues})
  assert.deepEqual(cues.contends, [{kind: "outgoing", callId: "call-cue"}])

  signaling.replace({call: {...call, ownership: "elsewhere"}})
  assert.equal(cues.withdraws, 1)
  assert.equal(cues.contends.length, 1)
  assert.equal(controller.getState().presentation, "outgoing_ringing")
  controller.dispose()
})

test("recipient preflight keeps the ringtone until the projection moves forward", () => {
  const call = ringingCall({role: "recipient", ownership: "unclaimed"})
  const signaling = fakeSignaling({call})
  const cues = fakeCues()
  const controller = createCallController({signaling, devices: deferredDevices(), cues})

  controller.acceptCall("audio")
  assert.equal(controller.getState().presentation, "incoming_preflighting")
  assert.equal(cues.contends.length, 1)
  assert.equal(cues.withdraws, 0)

  signaling.replace({call: {...call, state: "connecting", ownership: "self"}})
  assert.equal(controller.getState().presentation, "connecting")
  assert.equal(cues.withdraws, 1)

  signaling.replace({call: {...call, state: "active", ownership: "self"}})
  assert.equal(controller.getState().presentation, "active")
  assert.equal(cues.withdraws, 1)
  controller.dispose()
})

test("server ownership override, terminal state, and transport loss stop the cue once", () => {
  const scenarios = [
    {name: "ownership elsewhere", patch: call => ({call: {...call, ownership: "elsewhere"}})},
    {
      name: "terminal",
      patch: call => ({
        call: null,
        terminalCall: {
          call_id: call.call_id,
          role: "recipient",
          state: "terminal",
          terminal_outcome: "declined",
          media_intent: "audio",
          peer: {id: "peer-1", username: "alice"},
        },
      }),
    },
    {name: "disconnected", patch: () => ({call: null, connectionStatus: "disconnected"})},
    {name: "unavailable", patch: () => ({call: null, connectionStatus: "unavailable"})},
  ]

  for (const scenario of scenarios) {
    const call = ringingCall({role: "recipient", ownership: "unclaimed"})
    const signaling = fakeSignaling({call})
    const cues = fakeCues()
    const controller = createCallController({signaling, devices: deferredDevices(), cues})
    assert.equal(cues.contends.length, 1, scenario.name)

    const projection = scenario.patch(call)
    signaling.replace(projection)
    assert.equal(cues.withdraws, 1, scenario.name)

    signaling.replace(projection)
    assert.equal(cues.withdraws, 1, scenario.name)
    controller.dispose()
  }
})

test("unchanged ringing projections never restart the cue", () => {
  const call = ringingCall({role: "recipient", ownership: "unclaimed"})
  const signaling = fakeSignaling({call})
  const cues = fakeCues()
  const controller = createCallController({signaling, devices: deferredDevices(), cues})

  for (let publish = 0; publish < 5; publish += 1) {
    signaling.replace({call: {...call}})
  }

  assert.equal(cues.contends.length, 1)
  assert.equal(cues.withdraws, 0)
  controller.dispose()
})

test("a replaced Call stops the old cue before contending the new one", () => {
  const signaling = fakeSignaling({call: ringingCall({role: "recipient", ownership: "unclaimed"})})
  const cues = fakeCues()
  const controller = createCallController({signaling, devices: deferredDevices(), cues})

  signaling.replace({
    call: {
      call_id: "call-next",
      role: "recipient",
      state: "ringing",
      media_intent: "video",
      ownership: "unclaimed",
      peer: {id: "peer-2", username: "carol"},
    },
  })

  assert.deepEqual(cues.events, [
    ["contend", "incoming", "call-cue"],
    ["withdraw"],
    ["contend", "incoming", "call-next"],
  ])
  controller.dispose()
})

test("releaseCues stops the cue and a later projection re-contends from server truth", () => {
  const call = ringingCall({role: "recipient", ownership: "unclaimed"})
  const signaling = fakeSignaling({call})
  const cues = fakeCues()
  const controller = createCallController({signaling, devices: deferredDevices(), cues})

  controller.releaseCues()
  assert.equal(cues.withdraws, 1)
  assert.equal(cues.contends.length, 1)

  signaling.replace({call: {...call}})
  assert.equal(cues.contends.length, 2)
  assert.deepEqual(cues.contends[1], {kind: "incoming", callId: "call-cue"})

  controller.dispose()
  assert.equal(cues.disposes, 1)
  controller.dispose()
  assert.equal(cues.disposes, 1)
})

test("cue failures never change the dialog, controls, or announcements", () => {
  const call = ringingCall({role: "recipient", ownership: "unclaimed"})
  const signaling = fakeSignaling({call})
  const cues = fakeCues()
  cues.contend = () => {
    throw new Error("audio unavailable")
  }
  const controller = createCallController({signaling, devices: deferredDevices(), cues})

  const state = controller.getState()
  assert.equal(state.presentation, "incoming_ringing")
  assert.equal(state.canAcceptAudio, true)
  assert.equal(state.canDecline, true)
  assert.match(state.statusText, /inviting you/)

  cues.withdraw = () => {
    throw new Error("audio unavailable")
  }
  signaling.replace({call: {...call, ownership: "elsewhere"}})
  assert.equal(controller.getState().presentation, "owned_elsewhere")

  cues.dispose = () => {
    throw new Error("audio unavailable")
  }
  controller.dispose()
})

test("a malformed ringing projection fails silent instead of guessing a cue", () => {
  const malformed = [
    {...ringingCall({role: "recipient", ownership: "unclaimed"}), media_intent: "hologram"},
    {...ringingCall({role: "recipient", ownership: "unclaimed"}), media_intent: null},
    {...ringingCall({role: "recipient", ownership: "banana"})},
    {...ringingCall({role: "recipient", ownership: null})},
    {...ringingCall({role: "moderator", ownership: "self"})},
    {...ringingCall({role: "caller", ownership: "self"}), state: "ringing", call_id: ""},
  ]

  for (const call of malformed) {
    const cues = fakeCues()
    const controller = createCallController({
      signaling: fakeSignaling({call}),
      devices: deferredDevices(),
      cues,
    })
    assert.deepEqual(cues.contends, [], JSON.stringify(call))
    controller.dispose()
  }
})

function ringingCall({role, ownership}) {
  return {
    call_id: "call-cue",
    role,
    state: "ringing",
    media_intent: "audio",
    ownership,
    peer: {id: "peer-1", username: "alice"},
  }
}

function deferredDevices() {
  const queue = []
  return {
    queue,
    acquire(request = {}) {
      const item = {
        request: {audio: Boolean(request.audio), video: Boolean(request.video)},
        cancelled: false,
        capture: fakeCapture(request),
      }
      const promise = new Promise(resolve => {
        item.succeed = () => resolve({ok: true, request: item.request, capture: item.capture})
        item.fail = (error, extras = {}) => {
          const device = extras.device ?? "microphone"
          const result = {ok: false, error, device}
          if (device === "camera") {
            item.capture = fakeCapture({audio: true, video: false})
            result.capture = item.capture
          }
          resolve(result)
        }
      })
      queue.push(item)
      return {
        promise,
        cancel() {
          item.cancelled = true
        },
      }
    },
  }
}

function fakeCapture(request) {
  let released = false
  return {
    audio: Boolean(request.audio),
    video: Boolean(request.video),
    get released() {
      return released
    },
    release() {
      released = true
    },
  }
}

function fakeCues() {
  const cues = {contends: [], withdraws: 0, disposes: 0, events: []}
  cues.contend = cue => {
    cues.contends.push({...cue})
    cues.events.push(["contend", cue.kind, cue.callId])
  }
  cues.withdraw = () => {
    cues.withdraws += 1
    cues.events.push(["withdraw"])
  }
  cues.dispose = () => {
    cues.disposes += 1
    cues.events.push(["dispose"])
  }
  return cues
}

function fakeSignaling(initial = {}) {
  let state = freezeSignaling({
    connectionStatus: initial.connectionStatus ?? "connected",
    signalingSessionId: initial.signalingSessionId ?? "session-1",
    call: initial.call ?? null,
    terminalCall: initial.terminalCall ?? null,
  })
  const listeners = new Set()
  const starts = []
  const cancels = []
  const accepts = []
  const declines = []
  const leaves = []
  let startHandler = payload => defaultStart({replace, getState: () => state}, payload)
  let cancelHandler = payload => {
    cancels.push(payload)
    return Promise.resolve({ok: true, call: {call_id: payload.callId, terminal_outcome: "cancelled"}})
  }

  function replace(patch) {
    const merged = {...state, ...patch}
    if (!Object.hasOwn(patch, "callTopicStatus")) {
      merged.callTopicStatus =
        merged.call && merged.connectionStatus === "connected" ? "joined" : "idle"
    }
    state = freezeSignaling(merged)
    for (const listener of listeners) listener(state)
  }

  return {
    starts,
    cancels,
    accepts,
    declines,
    leaves,
    onStart(handler) {
      startHandler = handler
    },
    replace,
    subscribe(listener) {
      listeners.add(listener)
      listener(state)
      return () => listeners.delete(listener)
    },
    getState() {
      return state
    },
    startCall(payload) {
      starts.push({...payload})
      return startHandler(payload)
    },
    cancelCall(payload) {
      return cancelHandler(payload)
    },
    acceptCall(payload) {
      accepts.push({...payload})
      return Promise.resolve({ok: true, call: {...state.call, state: "connecting"}})
    },
    declineCall(payload) {
      declines.push({...payload})
      return Promise.resolve({ok: true, call: {call_id: payload.callId, terminal_outcome: "declined"}})
    },
    leaveCall(payload) {
      leaves.push({...payload})
      return Promise.resolve({ok: true, call: {call_id: payload.callId, terminal_outcome: "ended"}})
    },
  }
}

function defaultStart(signaling, payload) {
  const call = {
    call_id: "call-1",
    role: "caller",
    state: "ringing",
    media_intent: payload.mediaIntent,
    direct_conversation_id: payload.directConversationId,
  }
  signaling.replace({call})
  return Promise.resolve({ok: true, started: true, call, signaling_session_id: "session-1"})
}

function freezeSignaling(next) {
  const call = next.call ? Object.freeze({...next.call}) : null
  const frozen = {
    connectionStatus: next.connectionStatus,
    signalingSessionId: next.signalingSessionId ?? null,
    call,
    callTopicStatus: next.callTopicStatus ?? (
      call && next.connectionStatus === "connected" ? "joined" : "idle"
    ),
  }
  if (next.terminalCall) frozen.terminalCall = Object.freeze({...next.terminalCall})
  return Object.freeze(frozen)
}

function controlledTimers() {
  const callbacks = []
  const delays = []
  const cancelled = []
  return {
    callbacks,
    delays,
    cancelled,
    schedule(callback, delay) {
      callbacks.push(callback)
      delays.push(delay)
      return callbacks.length
    },
    cancel(id) {
      cancelled.push(id)
    },
  }
}

async function startAfterPreflight(controller, devices, intent = "audio") {
  controller.startCall(conversation, intent)
  devices.queue.at(-1).succeed()
  await microtask()
}

async function startRinging(controller, devices) {
  await startAfterPreflight(controller, devices)
  assert.equal(controller.getState().presentation, "outgoing_ringing")
}

async function startVideoAfterPreflight(controller, devices) {
  await startAfterPreflight(controller, devices, "video")
}

async function startVideoRinging(controller, devices) {
  await startVideoAfterPreflight(controller, devices)
  assert.equal(controller.getState().presentation, "outgoing_ringing")
}

function microtask() {
  return Promise.resolve()
}

test("real-only video actions preserve controller state and request no device", () => {
  const signaling = fakeSignaling()
  const devices = {...deferredDevices(), videoAvailable: false}
  const controller = createCallController({signaling, devices})
  const before = controller.getState()
  controller.startCall(conversation, "video")
  assert.deepEqual(controller.getState(), before)
  assert.equal(devices.queue.length, 0)
  signaling.replace({call: {call_id: "recovered-video", role: "recipient", state: "ringing", media_intent: "video", ownership: "unclaimed"}})
  const ringing = controller.getState()
  controller.acceptCall("video")
  assert.deepEqual(controller.getState(), ringing)
  assert.equal(devices.queue.length, 0)
  controller.acceptCall("audio")
  assert.deepEqual(devices.queue[0].request, {audio: true, video: false})
})

function realMicrophone() {
  const track = new EventTarget()
  track.readyState = "live"
  track.stops = 0
  track.stop = () => { track.stops++; track.readyState = "ended" }
  track.end = () => { track.readyState = "ended"; track.dispatchEvent(new Event("ended")) }
  const devices = createRealCallDevices({mediaDevices: {getUserMedia: async () => ({
    getAudioTracks: () => [track], getTracks: () => [track],
  })}})
  return {track, devices}
}

test("recipient Channel loss cancels preparation and releases capture before acceptance settles", async () => {
  for (const prepared of [false, true]) {
    const invitation = {call_id: "incoming", state: "ringing", role: "recipient", media_intent: "audio", ownership: "unclaimed"}
    const signaling = fakeSignaling({call: invitation}), devices = deferredDevices()
    let settle
    signaling.acceptCall = () => new Promise(resolve => {settle = resolve})
    const controller = createCallController({signaling, devices})
    controller.acceptCall("audio")
    if (prepared) {devices.queue[0].succeed(); await flushCapture()}
    signaling.replace({callTopicStatus: "failed"})
    if (prepared) assert.equal(devices.queue[0].capture.released, true)
    else assert.equal(devices.queue[0].cancelled, true)
    if (prepared) settle({ok: true, call: {...invitation, state: "connecting", ownership: "self"}})
    else devices.queue[0].succeed()
    await flushCapture()
    assert.equal(devices.queue[0].capture.released, true)
    assert.deepEqual(signaling.leaves, [])
    controller.dispose()
  }
})

test("Answer waits for a commandable Call topic and fast permission cannot strand preparation", async () => {
  const invitation = {call_id: "incoming", state: "ringing", role: "recipient", media_intent: "audio", ownership: "unclaimed"}
  const signaling = fakeSignaling({call: invitation}), devices = deferredDevices()
  signaling.replace({callTopicStatus: "joining"})
  const controller = createCallController({signaling, devices})
  assert.equal(controller.getState().canAcceptAudio, false)
  controller.acceptCall("audio")
  assert.equal(devices.queue.length, 0)
  signaling.replace({callTopicStatus: "joined"})
  assert.equal(controller.getState().canAcceptAudio, true)
  controller.acceptCall("audio")
  devices.queue[0].succeed(); await flushCapture()
  assert.deepEqual(signaling.accepts, [{callId: "incoming", answerMode: "audio"}])
  signaling.replace({call: {...invitation, state: "connecting", ownership: "self"}})
  assert.equal(controller.getState().presentation, "connecting")
  assert.equal(devices.queue[0].capture.released, false)
  controller.dispose()
})

test("an unprepared selected fallback cannot resume accepted media after transport or Channel loss", async () => {
  for (const loss of ["transport", "channel"]) {
    const call = {call_id: "fallback", state: "connecting", role: "caller", ownership: "self", media_intent: "audio"}
    const signaling = fakeSignaling({call}), devices = deferredDevices()
    const controller = createCallController({signaling, devices, createPeerAttempt: () => {throw Error("resumed peer")}})
    assert.equal(controller.getState().canEnableMicrophone, true)
    if (loss === "transport") signaling.replace({connectionStatus: "unavailable", call: null})
    else signaling.replace({callTopicStatus: "failed"})
    signaling.replace({connectionStatus: "connected", callTopicStatus: "joined", call})
    assert.equal(controller.getState().canEnableMicrophone, false)
    controller.enableMicrophone()
    assert.equal(devices.queue.length, 0)
    assert.match(controller.getState().statusText, /interrupted/i)
    assert.deepEqual(signaling.leaves, [])
    controller.dispose()
  }
})

test("suspension fences source-loss reconciliation and late start replies from a resumed generation", async () => {
  const {track, devices} = realMicrophone(), signaling = fakeSignaling()
  let settle
  signaling.onStart(() => new Promise(resolve => {settle = resolve}))
  const controller = createCallController({signaling, devices})
  controller.startCall(conversation, "audio"); await flushCapture()
  track.end()
  controller.suspend()
  signaling.replace({connectionStatus: "disconnected", signalingSessionId: null, call: null})
  signaling.replace({connectionStatus: "connected", signalingSessionId: "resumed", call: null})
  settle({ok: true, call: {call_id: "old", state: "ringing", role: "caller", ownership: "self", media_intent: "audio"}})
  await flushCapture()
  assert.deepEqual(signaling.cancels, [])
  assert.deepEqual(signaling.leaves, [])
  assert.equal(controller.getState().call, null)
  assert.equal(track.stops, 1)
  controller.dispose()
})

async function flushCapture() {
  for (let i = 0; i < 10; i++) await Promise.resolve()
}

test("an already-ended microphone creates no invitation and requires another gesture", async () => {
  const {track, devices} = realMicrophone()
  track.end()
  const signaling = fakeSignaling()
  const controller = createCallController({signaling, devices})
  controller.startCall(conversation, "audio")
  await flushCapture()
  assert.equal(signaling.starts.length, 0)
  assert.equal(controller.getState().resultCode, "ended")
  assert.equal(track.stops, 1)
})

test("source loss while caller rings cancels the exact invitation without recapture", async () => {
  const {track, devices} = realMicrophone()
  const signaling = fakeSignaling()
  const controller = createCallController({signaling, devices})
  controller.startCall(conversation, "audio")
  await flushCapture()
  track.end()
  await flushCapture()
  assert.deepEqual(signaling.cancels, [{callId: "call-1"}])
  assert.equal(signaling.starts.length, 1)
  assert.equal(track.stops, 1)
})

test("recipient ended acquisition preserves ringing and submits no acceptance", async () => {
  const {track, devices} = realMicrophone()
  const signaling = fakeSignaling({call: {call_id: "incoming", state: "ringing", role: "recipient", media_intent: "audio", ownership: "unclaimed"}})
  const controller = createCallController({signaling, devices})
  await flushCapture()
  assert.equal(track.stops, 0)
  controller.acceptCall("audio")
  track.end()
  await flushCapture()
  assert.equal(signaling.accepts.length, 0)
  assert.equal(controller.getState().presentation, "incoming_ringing")
  assert.equal(controller.getState().canDecline, true)
})

test("recipient source loss during acceptance reconciles its reply without assuming rollback", async () => {
  for (const committed of [false, true]) {
    const {track, devices} = realMicrophone()
    const signaling = fakeSignaling({call: {call_id: "incoming", state: "ringing", role: "recipient", media_intent: "audio", ownership: "unclaimed"}})
    let reply
    signaling.acceptCall = () => new Promise(resolve => {reply = resolve})
    const controller = createCallController({signaling, devices})
    controller.acceptCall("audio")
    await flushCapture()
    track.end()
    reply(committed ? {ok: true, call: {...signaling.getState().call, state: "connecting", ownership: "self"}} : {ok: false, error: "stale"})
    await flushCapture()
    assert.deepEqual(signaling.leaves, committed ? [{callId: "incoming"}] : [])
    assert.equal(controller.getState().presentation, "incoming_ringing")
    assert.equal(track.stops, 1)
  }
})

test("accepted source loss leaves the exact Call once; intentional old release is inert", async () => {
  const {track, devices} = realMicrophone()
  const signaling = fakeSignaling()
  const endings = []
  const controller = createCallController({signaling, devices, onCaptureEnded: event => endings.push(event)})
  controller.startCall(conversation, "audio")
  await flushCapture()
  signaling.replace({call: {...signaling.getState().call, state: "active", ownership: "self"}})
  track.end()
  track.end()
  assert.deepEqual(signaling.leaves, [{callId: "call-1"}])
  assert.equal(endings.length, 1)
  assert.equal(endings[0].callId, "call-1")
  assert.equal(controller.getState().captureEnded, true)
  controller.dispose()
  track.end()
  assert.equal(endings.length, 1)
})

test("recipient capture loss survives Decline when acceptance wins, in either delivery order", async () => {
  for (const projectionFirst of [false, true]) {
    const {track, devices} = realMicrophone()
    const invitation = {call_id: "incoming", state: "ringing", role: "recipient", media_intent: "audio", ownership: "unclaimed"}
    const signaling = fakeSignaling({call: invitation})
    let settleAccept
    signaling.acceptCall = () => new Promise(resolve => {settleAccept = resolve})
    signaling.declineCall = async () => ({ok: false, error: "stale"})
    const controller = createCallController({signaling, devices})
    controller.acceptCall("audio")
    await flushCapture()
    track.end()
    assert.equal(controller.getState().canDecline, true)
    controller.declineCall()
    const committed = {...invitation, state: "connecting", ownership: "self"}
    if (projectionFirst) signaling.replace({call: committed})
    settleAccept({ok: true, call: committed})
    await flushCapture()
    if (!projectionFirst) signaling.replace({call: committed})
    signaling.replace({call: {...committed, state: "active"}})
    await flushCapture()
    assert.deepEqual(signaling.leaves, [{callId: "incoming"}])
    assert.equal(track.stops, 1)
    controller.dispose()
  }
})

test("a declined lost acceptance cannot terminate a replacement or another owner", async () => {
  for (const outcome of ["rejected", "replacement", "elsewhere", "disconnected", "terminal"]) {
    const {track, devices} = realMicrophone()
    const invitation = {call_id: "incoming", state: "ringing", role: "recipient", media_intent: "audio", ownership: "unclaimed"}
    const signaling = fakeSignaling({call: invitation})
    let settleAccept
    signaling.acceptCall = () => new Promise(resolve => {settleAccept = resolve})
    const controller = createCallController({signaling, devices})
    controller.acceptCall("audio")
    await flushCapture()
    track.end()
    controller.declineCall()
    const committed = {...invitation, state: "connecting", ownership: "self"}
    if (outcome === "replacement") signaling.replace({call: {...committed, call_id: "replacement"}})
    if (outcome === "elsewhere") signaling.replace({call: {...committed, ownership: "elsewhere"}})
    if (outcome === "disconnected") signaling.replace({connectionStatus: "disconnected", call: null})
    if (outcome === "terminal") signaling.replace({call: null, terminalCall: {...invitation, state: "terminal", terminal_outcome: "declined"}})
    settleAccept(outcome === "rejected" ? {ok: false, error: "stale"} : {ok: true, call: committed})
    await flushCapture()
    if (outcome === "rejected") signaling.replace({call: committed})
    assert.deepEqual(signaling.leaves, [], outcome)
    assert.equal(track.stops, 1)
    controller.dispose()
  }
})

test("microphone loss at the prepared boundary submits neither start nor accept", async () => {
  for (const recipient of [false, true]) {
    const devices = deferredDevices()
    const signaling = fakeSignaling(recipient ? {call: {call_id: "incoming", state: "ringing", role: "recipient", media_intent: "audio", ownership: "unclaimed"}} : {})
    const controller = createCallController({signaling, devices})
    let end
    let live = true
    controller.subscribe(() => {if (end && live) {live = false; end()}})
    if (recipient) controller.acceptCall("audio")
    else controller.startCall(conversation, "audio")
    const item = devices.queue[0]
    item.capture.onEnded = listener => {end = listener; return () => {}}
    Object.defineProperty(item.capture, "live", {get: () => live})
    item.succeed()
    await flushCapture()
    assert.equal(signaling.starts.length + signaling.accepts.length, 0)
    assert.equal(item.capture.released, true)
  }
})

test("loss on a retired caller capture cannot end a later recipient Call", async () => {
  const {track, devices} = realMicrophone()
  const signaling = fakeSignaling()
  const controller = createCallController({signaling, devices})
  controller.startCall(conversation, "audio")
  await flushCapture()
  track.end()
  signaling.replace({call: null})
  signaling.replace({call: {call_id: "replacement", state: "connecting", role: "recipient", ownership: "self", media_intent: "audio"}})
  assert.deepEqual(signaling.leaves, [])
})

test("caller capture loss reconciles acceptance winning its cancellation race", async () => {
  const {track, devices} = realMicrophone()
  const signaling = fakeSignaling()
  const controller = createCallController({signaling, devices})
  controller.startCall(conversation, "audio")
  await flushCapture()
  track.end()
  signaling.replace({call: {...signaling.getState().call, state: "active", ownership: "self"}})
  assert.deepEqual(signaling.leaves, [{callId: "call-1"}])
})

test("prepared owner starts one peer across projections and local leave releases it before the reply", async () => {
  const signaling = fakeSignaling(), devices = deferredDevices(), attempts = []
  const controller = createCallController({signaling, devices, createPeerAttempt: options => {
    const attempt = {connect: async fields => { attempt.fields = fields; options.onState("connected"); options.onPlayback("blocked") }, leave() { attempt.closed = true }}
    attempts.push(attempt)
    return attempt
  }})
  controller.startCall(conversation, "audio")
  const capture = devices.queue[0].capture
  capture.audioTrack = {kind: "audio", readyState: "live"}
  devices.queue[0].succeed(); await microtask()
  const call = {...signaling.getState().call, state: "connecting", ownership: "self"}
  signaling.replace({call})
  await microtask()
  signaling.replace({call: {...call, state: "active"}})
  assert.equal(attempts.length, 1)
  assert.equal(attempts[0].fields.track, capture.audioTrack)
  assert.equal(controller.getState().mediaConnectionState, "connected")
  assert.equal(controller.getState().playbackState, "blocked")
  controller.leaveCall()
  assert.equal(attempts[0].closed, true)
  assert.equal(capture.released, true)
  controller.dispose()
})

for (const loss of ["owner", "channel", "terminal", "suspension", "dispose"]) {
  test(`${loss} releases prepared Call media and stale callbacks cannot affect a replacement`, async () => {
    const signaling = fakeSignaling(), devices = deferredDevices(), attempts = []
    const controller = createCallController({signaling, devices, createPeerAttempt: options => {
      const peer = {connect: async () => {}, leave() { peer.closed = true }}
      attempts.push({peer, options}); return peer
    }})
    controller.startCall(conversation, "audio")
    const prepared = devices.queue[0].capture
    prepared.audioTrack = {kind: "audio", readyState: "live"}
    devices.queue[0].succeed(); await microtask()
    const call = {...signaling.getState().call, ownership: "self", state: "connecting"}
    signaling.replace({call}); await microtask()
    assert.equal(attempts.length, 1)
    if (loss === "owner") signaling.replace({call: {...call, ownership: "elsewhere"}})
    if (loss === "channel") signaling.replace({callTopicStatus: "failed"})
    if (loss === "terminal") signaling.replace({call: null, terminalCall: {...call, state: "terminal", terminal_outcome: "ended"}})
    if (loss === "suspension") signaling.replace({connectionStatus: "disconnected", call: null})
    if (loss === "dispose") controller.dispose()
    assert.equal(attempts[0].peer.closed, true)
    assert.equal(prepared.released, true)
    attempts[0].options.onState("connected")
    attempts[0].options.onPlayback("playing")
    attempts[0].options.onFailure()
    assert.equal(signaling.leaves.length, 0)
    assert.equal(controller.getState().mediaConnectionState, "idle")
    if (loss !== "dispose") {
      signaling.replace({connectionStatus: "connected", call, terminalCall: null})
      await microtask()
      assert.equal(attempts.length, 1)
    }
    controller.dispose()
  })
}

test("selected fallback waits for a gesture, then connects once with an independent microphone", async () => {
  const call = {call_id: "fallback", state: "connecting", role: "caller", ownership: "self", media_intent: "audio"}
  const signaling = fakeSignaling({call}), devices = deferredDevices(), attempts = []
  const controller = createCallController({signaling, devices, createPeerAttempt: options => {
    const peer = {connect: async fields => {peer.track = fields.track; options.onState("connected")}, leave() {peer.closed = true}}
    attempts.push(peer); return peer
  }})
  assert.equal(devices.queue.length, 0)
  assert.equal(controller.getState().canEnableMicrophone, true)
  assert.match(controller.getState().statusText, /Awaiting microphone/)
  controller.enableMicrophone()
  controller.enableMicrophone()
  assert.equal(devices.queue.length, 1)
  assert.match(controller.getState().statusText, /Preparing microphone/)
  devices.queue[0].capture.audioTrack = {kind: "audio", readyState: "live"}
  devices.queue[0].succeed(); await flushCapture()
  assert.equal(attempts.length, 1)
  assert.equal(controller.getState().canEnableMicrophone, false)
  signaling.replace({call: {...call, state: "active"}})
  assert.match(controller.getState().statusText, /Call connected/)
  assert.equal(signaling.starts.length, 0)
  assert.equal(signaling.accepts.length, 0)
  controller.leaveCall()
  assert.equal(attempts[0].closed, true)
  assert.equal(devices.queue[0].capture.released, true)
  controller.dispose()
})

test("fallback denial ends the accepted Call instead of silently retrying capture", async () => {
  const call = {call_id: "fallback", state: "connecting", role: "caller", ownership: "self", media_intent: "audio"}
  const signaling = fakeSignaling({call}), devices = deferredDevices()
  const controller = createCallController({signaling, devices, createPeerAttempt: () => {throw Error("no peer before capture")}})
  controller.enableMicrophone()
  devices.queue[0].fail("permission-denied"); await flushCapture()
  assert.deepEqual(signaling.leaves, [{callId: "fallback"}])
  assert.equal(controller.getState().canEnableMicrophone, false)
  assert.equal(devices.queue.length, 1)
  controller.dispose()
})

for (const loss of ["owner", "channel", "replacement", "terminal", "suspend", "dispose"]) {
  test(`fallback permission settling after ${loss} cannot attach capture or submit another command`, async () => {
    const call = {call_id: "fallback", state: "connecting", role: "caller", ownership: "self", media_intent: "audio"}
    const signaling = fakeSignaling({call}), devices = deferredDevices()
    const controller = createCallController({signaling, devices, createPeerAttempt: () => {throw Error("stale peer")}})
    controller.enableMicrophone()
    if (loss === "owner") signaling.replace({call: {...call, ownership: "elsewhere"}})
    if (loss === "channel") signaling.replace({callTopicStatus: "failed"})
    if (loss === "replacement") signaling.replace({call: {...call, call_id: "new-call"}})
    if (loss === "terminal") signaling.replace({call: null, terminalCall: {...call, state: "terminal", terminal_outcome: "failed"}})
    if (loss === "suspend") controller.suspend()
    if (loss === "dispose") controller.dispose()
    assert.equal(devices.queue[0].cancelled, true)
    devices.queue[0].succeed(); await flushCapture()
    assert.equal(devices.queue[0].capture.released, true)
    assert.deepEqual(signaling.leaves, [])
    controller.dispose()
  })
}

test("source loss in a retired Call does not prevent a new selected fallback gesture", async () => {
  const {track, devices} = realMicrophone()
  const signaling = fakeSignaling()
  const controller = createCallController({signaling, devices, createPeerAttempt: () => ({connect: async () => {}, leave() {}})})
  controller.startCall(conversation, "audio"); await flushCapture()
  const old = {...signaling.getState().call, state: "active", ownership: "self"}
  signaling.replace({call: old}); await flushCapture(); track.end()
  signaling.replace({call: null, terminalCall: {...old, state: "terminal", terminal_outcome: "ended"}})
  signaling.replace({terminalCall: null, call: {...old, call_id: "new-call", state: "connecting"}})
  assert.equal(controller.getState().canEnableMicrophone, true)
  controller.dispose()
})

for (const error of ["timeout", "unavailable"]) {
 test(`an acceptance ${error} cannot erase capture loss before a committed projection arrives`, async () => {
  const {track, devices} = realMicrophone()
  const call = {call_id: "incoming", role: "recipient", state: "ringing", ownership: "unclaimed", media_intent: "audio"}
  const signaling = fakeSignaling({call})
  let settle
  signaling.acceptCall = () => new Promise(resolve => {settle = resolve})
  const controller = createCallController({signaling, devices})
  controller.acceptCall("audio"); await flushCapture(); track.end()
  settle({ok: false, error}); await flushCapture()
  assert.equal(controller.getState().presentation, "incoming_ringing")
  signaling.replace({call: {...call, state: "connecting", ownership: "self"}})
  assert.deepEqual(signaling.leaves, [{callId: "incoming"}])
  assert.equal(track.stops, 1)
  controller.dispose()
})
}

for (const recipient of [false, true]) {
  test(`${recipient ? "recipient retains ringing" : "caller creates no invitation"} when the owned microphone has ended`, async () => {
    const invitation = {call_id: "incoming", state: "ringing", role: "recipient", media_intent: "audio", ownership: "unclaimed"}
    const signaling = fakeSignaling(recipient ? {call: invitation} : {})
    const devices = deferredDevices()
    const controller = createCallController({signaling, devices})
    if (recipient) controller.acceptCall("audio")
    else controller.startCall(conversation, "audio")
    // The owned source is authoritative even if an adapter's aggregate is stale.
    devices.queue[0].capture.microphone = {live: false}
    devices.queue[0].succeed()
    await flushCapture()
    assert.equal(signaling.starts.length + signaling.accepts.length, 0)
    assert.equal(devices.queue[0].capture.released, true)
    if (recipient) assert.equal(controller.getState().call.state, "ringing")
    controller.dispose()
  })
}


for (const replacement of ["signaling session", "incoming invitation"]) {
  test(`caller video preparation releases rather than dispatching under a changed ${replacement}`, async () => {
    const signaling = fakeSignaling(), devices = deferredDevices()
    const controller = createCallController({signaling, devices})
    controller.startCall(conversation, "video")
    if (replacement === "signaling session") signaling.replace({signalingSessionId: "replacement-session"})
    else signaling.replace({call: {call_id: "incoming", role: "recipient", ownership: "unclaimed",
      state: "ringing", media_intent: "audio", direct_conversation_id: "other-conversation", peer: {username: "bob"}}})
    devices.queue[0].succeed()
    await microtask()
    assert.equal(signaling.starts.length, 0)
    assert.equal(devices.queue[0].capture.released, true)
    if (replacement === "incoming invitation") assert.equal(controller.getState().presentation, "incoming_ringing")
    controller.dispose()
  })
}


for (const replacement of ["signaling session", "incoming invitation"]) {
  test(`retained caller microphone releases when its ${replacement} replaces failed video preparation`, async () => {
    const signaling = fakeSignaling(), devices = deferredDevices()
    const controller = createCallController({signaling, devices})
    controller.startCall(conversation, "video")
    devices.queue[0].fail("permission-denied", {device: "camera"})
    await microtask()
    assert.equal(controller.getState().microphoneReady, true)
    if (replacement === "signaling session") signaling.replace({signalingSessionId: "replacement-session"})
    else signaling.replace({call: {call_id: "incoming", role: "recipient", state: "ringing", media_intent: "audio"}})
    assert.equal(devices.queue[0].capture.released, true)
    assert.equal(controller.getState().microphoneReady, false)
    assert.equal(signaling.starts.length, 0)
    controller.dispose()
  })
}


test("owner video diagnostics distinguish presentation faults, camera choice and observers safely", async () => {
  const records = [], signaling = fakeSignaling(), devices = deferredDevices()
  let callbacks
  const binding = {isCurrent: () => true}
  const controller = createCallController({signaling, devices, diagnosticWrite: record => records.push(record),
    createPeerAttempt: options => {
      callbacks = options
      return {connect: async () => {options.onState("connected")}, leave() {}}
    }})
  controller.startCall(conversation, "audio")
  devices.queue[0].capture.audioTrack = {kind: "audio", readyState: "live"}
  devices.queue[0].succeed(); await flushCapture()
  const call = {...signaling.getState().call, state: "active", ownership: "self",
    media_state: {recipient: {camera_enabled: true}}}
  signaling.replace({call}); await flushCapture()
  callbacks.onRemoteVideo({kind: "video", id: "private-device-track"}, binding)
  controller.setRemoteVideoState(binding, "interrupted")
  for (let i = 0; i < 100; i++) signaling.replace({call})
  controller.setRemoteVideoState(binding, "ready")
  controller.setRemoteVideoState(binding, "blocked")
  const before = records.length
  signaling.replace({call: {...call, ownership: "elsewhere"}})
  controller.setRemoteVideoState(binding, "interrupted")
  assert.equal(records.length, before)
  assert.deepEqual(records.filter(r => r.operation === "presentation").map(r => r.outcome),
    ["loading", "interrupted", "ready", "blocked"])
  assert.ok(records.every(r => r.component === "browser" && r.media_kind === "video"))
  assert.equal(records.find(r => r.outcome === "interrupted").stage, "presentation")
  assert.ok(records.some(r => r.operation === "camera" && r.outcome === "off"))
  assert.doesNotMatch(JSON.stringify(records), /private-device-track|call-1|alice|conversation-1|network|credential/)
  controller.dispose()
})


test("video diagnostic categories reject raw data and bound repeated transitions across Calls", () => {
  let time = 0
  const records = [], observe = createCallVideoDiagnostics({write: record => records.push(record), now: () => time})
  const state = {call: {ownership: "self", call_id: "private-id"}, presentation: "active",
    cameraState: "error", cameraError: "permission-denied", remoteVideoState: "interrupted"}
  observe(state)
  for (let i = 0; i < 100; i++) {
    observe({...state, cameraState: "off", remoteVideoState: "ready"})
    observe(state)
  }
  assert.equal(records.length, 4)
  observe({...state, cameraError: "sdp-credential-device", remoteVideoState: "raw-network-value"})
  assert.deepEqual(records.at(-1), {component: "browser", operation: "camera", media_kind: "video",
    stage: "camera", outcome: "error"})
  time = 10_000
  observe({...state, cameraState: "off", remoteVideoState: "ready"})
  observe(state)
  assert.equal(records.filter(r => r.error_code === "permission-denied").length, 2)
  assert.doesNotMatch(JSON.stringify(records), /sdp|credential|device|network|private-id/)
})
