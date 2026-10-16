import assert from "node:assert/strict"
import test from "node:test"

import {createVoiceSignaling} from "./voice_signaling.js"

test("joins the dedicated Voice topic with the page CSRF token, observes unexpected close, and leaves through Phoenix's built-in lifecycle", () => {
  const events = []
  let onClose
  const joinPush = {receive() { return joinPush }}
  const leavePush = {receive() { return leavePush }}

  class FakeSocket {
    constructor(path, options) { events.push(["new", path, options]) }
    connect() { events.push(["connect"]) }
    channel(topic, params) {
      events.push(["channel", topic, params])
      return {
        join() { return joinPush },
        leave() { events.push(["leave"]); return leavePush },
        onClose(callback) { onClose = callback },
      }
    }
    disconnect() { events.push(["disconnect"]) }
  }

  const signaling = createVoiceSignaling({Socket: FakeSocket, csrfToken: "page-csrf-token"})

  assert.equal(signaling.join("voice-channel-id"), joinPush)
  assert.deepEqual(events, [
    ["new", "/voice", {params: {_csrf_token: "page-csrf-token"}}],
    ["connect"],
    ["channel", "voice:voice-channel-id", {}],
  ])

  let closes = 0
  signaling.onClose(() => { closes += 1 })
  onClose()
  assert.equal(closes, 1)

  assert.equal(signaling.leave(), leavePush)
  assert.deepEqual(events.at(-1), ["leave"])
})

test("pushes a real offer and resolves Phoenix's correlated answer reply", async () => {
  const pushes = []
  const receives = []
  const offerPush = {
    receive(status, callback) {
      receives.push([status, callback])
      return offerPush
    },
  }

  class FakeSocket {
    connect() {}
    channel() {
      return {
        join() { return {receive() { return this }} },
        leave() { return {receive() { return this }} },
        push(event, payload) {
          pushes.push([event, payload])
          return offerPush
        },
      }
    }
  }

  const signaling = createVoiceSignaling({Socket: FakeSocket})
  signaling.join("voice-channel-id")

  const offer = {
    signaling_session_id: "current-signaling-session",
    negotiation_id: "browser-negotiation",
    description: {type: "offer", sdp: "browser-offer"},
  }

  const answerPromise = signaling.sendOffer(offer)

  assert.deepEqual(pushes, [["offer", offer]])

  const answer = {
    signaling_session_id: "current-signaling-session",
    negotiation_id: "browser-negotiation",
    description: {type: "answer", sdp: "server-answer"},
  }
  receives.find(([status]) => status === "ok")[1](answer)

  assert.deepEqual(await answerPromise, answer)
})

test("pushes individual ICE and Voice Session renewal while exposing direct server ICE events", () => {
  const pushes = []
  const handlers = []
  const receives = []
  const icePush = {
    receive(status, callback) {
      receives.push(["ice", status, callback])
      return icePush
    },
  }
  const renewalPush = {
    receive(status, callback) {
      receives.push(["renew", status, callback])
      return renewalPush
    },
  }

  class FakeSocket {
    connect() {}
    channel() {
      return {
        join() { return {receive() { return this }} },
        leave() { return {receive() { return this }} },
        push(event, payload) {
          pushes.push([event, payload])
          return event === "ice_candidate" ? icePush : renewalPush
        },
        on(event, callback) { handlers.push([event, callback]); return 1 },
      }
    }
  }

  const signaling = createVoiceSignaling({Socket: FakeSocket})
  signaling.join("voice-channel-id")

  const ice = {signaling_session_id: "current-id", negotiation_id: "browser-negotiation", candidate: {candidate: "client-ice"}}
  const renewal = {signaling_session_id: "current-id"}
  const receivedServerIce = []

  assert.equal(signaling.sendIce(ice), icePush)
  assert.equal(signaling.renewVoiceSession(renewal), renewalPush)
  assert.equal(signaling.onServerIce(payload => receivedServerIce.push(payload)), 1)
  assert.deepEqual(pushes, [["ice_candidate", ice], ["renew", renewal]])

  const serverIce = {signaling_session_id: "current-id", negotiation_id: "browser-negotiation", candidate: {candidate: "server-ice"}}
  handlers[0][1](serverIce)

  assert.deepEqual(receivedServerIce, [serverIce])

  let receivedError = null
  signaling.sendIce(ice).receive("error", reply => { receivedError = reply })
  receives.at(-1)[2]({reason: "invalid_request"})

  assert.deepEqual(receivedError, {reason: "invalid_request"})
})

test("pushes only the caller-provided bounded ICE route diagnostic", () => {
  const pushes = []
  class FakeSocket {
    connect() {}
    channel() {
      return {
        join() { return {receive() { return this }} },
        leave() {},
        push(event, payload) { pushes.push([event, payload]); return {receive() { return this }} },
      }
    }
  }

  const signaling = createVoiceSignaling({Socket: FakeSocket})
  signaling.join("voice-channel-id")
  const diagnostic = {signaling_session_id: "opaque", route_category: "host_direct", protocol: "udp", duration_ms: 4}
  signaling.reportIceRoute(diagnostic)

  assert.deepEqual(pushes, [["ice_route", diagnostic]])
})
