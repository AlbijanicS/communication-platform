import assert from "node:assert/strict"
import test from "node:test"

import {installCallSignaling} from "./call_signaling_bootstrap.js"

test("does not connect or create cue resources on anonymous pages", () => {
  const events = []
  const anonymous = installCallSignaling({
    document: {getElementById() { return null }},
    window: fakeWindow(events),
    Socket: FakeSocket,
    csrfToken: "csrf",
    createCallSignaling: ({csrfToken}) => fakeSignaling(events, csrfToken),
    createCuePlayer: () => {
      events.push(["create-cue-player"])
      return fakeCuePlayer(events)
    },
    createCueCoordinator: () => {
      events.push(["create-cue-coordinator"])
      return fakeCueCoordinator(events, {})
    },
  })

  assert.equal(anonymous.signaling, null)
  assert.equal(anonymous.controller, null)
  assert.deepEqual(events, [])
  anonymous.dispose()
  assert.deepEqual(events, [])
})

test("authenticated bootstrap creates one controller, cue player, and cue coordinator", () => {
  const harness = installAuthenticated()

  assert.equal(harness.events.filter(([name]) => name === "connect").length, 1)
  assert.equal(harness.events.filter(([name]) => name === "create-controller").length, 1)
  assert.equal(harness.events.filter(([name]) => name === "install-presenter").length, 1)
  assert.equal(harness.events.filter(([name]) => name === "create-cue-player").length, 1)
  assert.equal(harness.events.filter(([name]) => name === "create-cue-coordinator").length, 1)
  assert.deepEqual(harness.events.find(([name]) => name === "create-controller"), [
    "create-controller",
    true,
    true,
    true,
  ])
  assert.ok(harness.installed.controller)
  assert.deepEqual(harness.windowEvents, [
    ["add", "pagehide"],
    ["add", "pageshow"],
  ])

  const coordinator = harness.coordinators[0]
  coordinator.options.onElected({kind: "incoming", callId: "call-1"})
  coordinator.options.onRevoked()
  assert.deepEqual(harness.events.slice(-2), [
    ["cue-start", "incoming", "call-1"],
    ["cue-stop"],
  ])

  harness.win.trigger("pagehide")
  assert.equal(harness.events.filter(([name]) => name === "release-cues").length, 1)
  assert.equal(harness.events.filter(([name]) => name === "disconnect").length, 1)

  harness.win.trigger("pageshow", {persisted: false})
  assert.equal(harness.events.filter(([name]) => name === "connect").length, 1)

  harness.win.trigger("pageshow", {persisted: true})
  assert.equal(harness.events.filter(([name]) => name === "connect").length, 2)
  assert.equal(harness.events.filter(([name]) => name === "cue-contend").length, 0)

  harness.installed.dispose()
  harness.installed.dispose()
  assert.equal(harness.events.filter(([name]) => name === "dispose-presenter").length, 1)
  assert.equal(harness.events.filter(([name]) => name === "dispose-controller").length, 1)
  assert.equal(harness.events.filter(([name]) => name === "dispose-cue-coordinator").length, 1)
  assert.equal(harness.events.filter(([name]) => name === "dispose-cue-player").length, 1)
  assert.equal(harness.events.filter(([name]) => name === "dispose").length, 1)
  assert.deepEqual(harness.windowEvents.slice(-2), [
    ["remove", "pagehide"],
    ["remove", "pageshow"],
  ])

  harness.win.trigger("pageshow", {persisted: true})
  assert.equal(harness.events.filter(([name]) => name === "connect").length, 2)

  harness.installed.signaling.dispose()
  assert.equal(harness.events.filter(([name]) => name === "dispose").length, 2)
})

test("authenticated bootstrap does not replay a start or cue claim after persisted pageshow", () => {
  const harness = installAuthenticated()

  harness.win.trigger("pagehide")
  harness.win.trigger("pageshow", {persisted: true})

  assert.equal(harness.events.filter(([name]) => name === "startCall").length, 0)
  assert.equal(harness.events.filter(([name]) => name === "fallbackToAudio").length, 0)
  assert.equal(harness.events.filter(([name]) => name === "cue-contend").length, 0)
  assert.equal(harness.events.filter(([name]) => name === "cue-start").length, 0)
  assert.equal(harness.events.filter(([name]) => name === "connect").length, 2)
  harness.installed.dispose()
})

function installAuthenticated() {
  const events = []
  const windowEvents = []
  const win = fakeWindow(windowEvents)
  const coordinators = []

  const installed = installCallSignaling({
    document: {getElementById(id) { return id === "call-signaling-bootstrap" ? {dataset: {callDevices: "fake"}} : null }},
    window: win,
    Socket: FakeSocket,
    csrfToken: "csrf",
    createCallSignaling: ({csrfToken}) => fakeSignaling(events, csrfToken),
    createDevices: () => fakeDevices(events),
    createCuePlayer: () => {
      events.push(["create-cue-player"])
      return fakeCuePlayer(events)
    },
    createCueCoordinator: options => {
      events.push(["create-cue-coordinator"])
      const coordinator = fakeCueCoordinator(events, options)
      coordinators.push(coordinator)
      return coordinator
    },
    createController: ({signaling, devices, cues}) =>
      fakeController(events, signaling, devices, cues),
    installPresenter: ({controller}) => fakePresenter(events, controller),
  })

  return {events, windowEvents, win, coordinators, installed}
}

function fakeSignaling(events, csrfToken) {
  events.push(["create", csrfToken])
  return {
    connect() { events.push(["connect"]) },
    disconnect() { events.push(["disconnect"]) },
    dispose() { events.push(["dispose"]) },
    subscribe() { return () => {} },
    getState() { return {connectionStatus: "disconnected", signalingSessionId: null, call: null} },
    startCall() { events.push(["startCall"]); return Promise.resolve({ok: false, error: "unavailable"}) },
    cancelCall() { return Promise.resolve({ok: false, error: "unavailable"}) },
  }
}

function fakeDevices(events) {
  events.push(["create-devices"])
  return {
    acquire() {
      return {promise: Promise.resolve({ok: false, error: "cancelled"}), cancel() {}}
    },
  }
}

function fakeCuePlayer(events) {
  return {
    start(kind, callId) { events.push(["cue-start", kind, callId]) },
    stop() { events.push(["cue-stop"]) },
    dispose() { events.push(["dispose-cue-player"]) },
  }
}

function fakeCueCoordinator(events, options) {
  return {
    options,
    contend(cue) { events.push(["cue-contend", cue.kind, cue.callId]) },
    withdraw() { events.push(["cue-withdraw"]) },
    dispose() { events.push(["dispose-cue-coordinator"]) },
  }
}

function fakeController(events, signaling, devices, cues) {
  events.push(["create-controller", Boolean(signaling), Boolean(devices), Boolean(cues)])
  return {
    subscribe() { return () => {} },
    getState() { return {presentation: "idle"} },
    startCall() { events.push(["startCall"]) },
    cancelCall() {},
    cancelLocalPreparation() {},
    retry() {},
    fallbackToAudio() { events.push(["fallbackToAudio"]) },
    dismiss() {},
    releaseCues() { events.push(["release-cues"]) },
    dispose() { events.push(["dispose-controller"]) },
  }
}

function fakePresenter(events, controller) {
  events.push(["install-presenter", Boolean(controller)])
  return {dispose() { events.push(["dispose-presenter"]) }}
}

function fakeWindow(events) {
  const listeners = {}
  return {
    addEventListener(type, callback) {
      events.push(["add", type])
      listeners[type] = listeners[type] || []
      listeners[type].push(callback)
    },
    removeEventListener(type, callback) {
      events.push(["remove", type])
      listeners[type] = (listeners[type] || []).filter(listener => listener !== callback)
    },
    trigger(type, event = {}) {
      for (const listener of listeners[type] || []) listener(event)
    },
  }
}

class FakeSocket {}

test("bootstrap defaults to real audio and reserves fake video for explicit test adapters", async () => {
  for (const mode of [undefined, "fake", "real"]) {
    const events = []
    let selected
    const installed = installCallSignaling({
      document: {getElementById: () => ({dataset: {callDevices: mode}}), createElement: () => ({})},
      createCallSignaling: () => fakeSignaling(events, "csrf"),
      createCuePlayer: () => fakeCuePlayer(events),
      createCueCoordinator: () => fakeCueCoordinator(events, {}),
      createController: ({devices}) => {selected = devices; return fakeController(events, {}, devices, {})},
      installPresenter: () => ({dispose() {}}),
    })
    const video = await selected.acquire({video: true}).promise
    assert.equal(video.ok, mode === "fake")
    video.capture?.release()
    installed.dispose()
  }
})
