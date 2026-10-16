import assert from "node:assert/strict"
import test from "node:test"

import {
  CALL_COMMAND_EVENTS,
  CALL_INBOX_TOPIC,
  CALL_RESERVED_CONTROL_EVENTS,
  CALL_RESERVED_MEDIA_EVENTS,
  CALL_TERMINAL_EVENTS,
  CALL_TOPIC_PREFIX,
  callTopic,
  createCallSignaling,
} from "./call_signaling.js"

const CALL_TOPIC_CLIENT_EVENTS = [
  ...CALL_COMMAND_EVENTS,
  ...CALL_RESERVED_CONTROL_EVENTS,
  ...CALL_RESERVED_MEDIA_EVENTS,
]

test("connects once to the private inbox, registers handlers before join, and is idempotent", () => {
  const events = []
  const receives = []
  const harness = fakeSocket(events, receives)
  const signaling = createCallSignaling({Socket: harness.Socket, csrfToken: "page-csrf-token"})

  signaling.connect()
  signaling.connect()

  assert.deepEqual(
    events.filter(([name]) => name === "new"),
    [["new", "/calls", {params: {_csrf_token: "page-csrf-token"}}]],
  )
  assert.equal(events.filter(([name]) => name === "connect").length, 1)
  assert.deepEqual(events.filter(([name]) => name === "channel"), [
    ["channel", CALL_INBOX_TOPIC, {}],
  ])
  for (const event of CALL_TERMINAL_EVENTS) {
    assert.ok(
      events.some(([name, registered]) => name === "on" && registered === event),
      `expected a handler for ${event}`,
    )
  }

  const handlerIndex = events.findIndex(([name]) => name === "on")
  const joinIndex = events.findIndex(([name]) => name === "join")
  assert.ok(handlerIndex >= 0)
  assert.ok(joinIndex > handlerIndex)

  const snapshots = []
  const unsubscribe = signaling.subscribe(snapshot => snapshots.push(snapshot))
  assert.equal(snapshots.at(-1).connectionStatus, "connecting")
  assert.equal(Object.isFrozen(snapshots.at(-1)), true)

  receives.find(([status]) => status === "ok")[1]({
    signaling_session_id: "session-1",
    call: {call_id: "call-1", role: "caller", state: "ringing"},
  })

  assert.deepEqual(signaling.getState(), {
    connectionStatus: "connected",
    signalingSessionId: "session-1",
    call: {call_id: "call-1", role: "caller", state: "ringing"},
    callTopicStatus: "joining",
  })
  assert.equal(Object.isFrozen(signaling.getState().call), true)

  unsubscribe()
  harness.channel.handlers.incoming_call[0]({
    signaling_session_id: "session-1",
    call: {call_id: "call-2", role: "recipient", state: "ringing"},
  })
  assert.equal(signaling.getState().call.call_id, "call-2")
  assert.equal(snapshots.at(-1).call.call_id, "call-1")
})

test("applies rejoin snapshots, clears matching terminals, and ignores an old Call ID", () => {
  const receives = []
  const harness = fakeSocket([], receives)
  const signaling = createCallSignaling({Socket: harness.Socket, csrfToken: "csrf"})
  signaling.connect()

  receives.find(([status]) => status === "ok")[1]({
    signaling_session_id: "session-1",
    call: {call_id: "call-1", role: "caller"},
  })

  harness.channel.handlers.call_ended[0]({call: {call_id: "call-old"}})
  assert.equal(signaling.getState().call.call_id, "call-1")

  harness.channel.handlers.call_declined[0]({
    signaling_session_id: "session-1",
    call: {call_id: "call-1", role: "caller", terminal_outcome: "declined"},
  })
  assert.equal(signaling.getState().call, null)

  receives.find(([status]) => status === "ok")[1]({
    signaling_session_id: "session-2",
    call: {call_id: "call-2", role: "recipient"},
  })
  assert.deepEqual(signaling.getState(), {
    connectionStatus: "connected",
    signalingSessionId: "session-2",
    call: {call_id: "call-2", role: "recipient"},
    callTopicStatus: "joining",
  })

  receives.find(([status]) => status === "ok")[1]({
    signaling_session_id: "session-3",
    call: null,
  })
  assert.equal(signaling.getState().call, null)
  assert.equal(signaling.getState().signalingSessionId, "session-3")
})

test("transient close clears identity without tearing the socket down, then teardown ignores stale callbacks", () => {
  const events = []
  const receives = []
  const harness = fakeSocket(events, receives)
  const signaling = createCallSignaling({Socket: harness.Socket, csrfToken: "csrf"})
  signaling.connect()

  receives.find(([status]) => status === "ok")[1]({
    signaling_session_id: "session-live",
    call: {call_id: "call-live", role: "caller"},
  })

  harness.socket._onClose()
  assert.deepEqual(signaling.getState(), {
    connectionStatus: "unavailable",
    signalingSessionId: null,
    call: null,
    callTopicStatus: "idle",
  })
  assert.equal(events.filter(([name]) => name === "disconnect").length, 0)

  receives.find(([status]) => status === "ok")[1]({
    signaling_session_id: "session-rejoin",
    call: {call_id: "call-rejoin", role: "caller"},
  })
  assert.equal(signaling.getState().signalingSessionId, "session-rejoin")

  signaling.disconnect()
  assert.equal(signaling.getState().connectionStatus, "disconnected")
  assert.equal(events.filter(([name]) => name === "disconnect").length, 1)

  harness.channel.handlers.incoming_call[0]({
    signaling_session_id: "stale",
    call: {call_id: "stale-call", role: "caller"},
  })
  assert.equal(signaling.getState().connectionStatus, "disconnected")
  assert.equal(signaling.getState().call, null)
})

test("dispose unregisters subscriptions while disconnect keeps them", () => {
  const receives = []
  const signaling = createCallSignaling({Socket: fakeSocket([], receives).Socket, csrfToken: "csrf"})
  const snapshots = []
  signaling.subscribe(snapshot => snapshots.push(snapshot))

  signaling.connect()
  signaling.disconnect()
  assert.equal(snapshots.at(-1).connectionStatus, "disconnected")
  signaling.connect()
  assert.equal(snapshots.at(-1).connectionStatus, "connecting")

  signaling.dispose()
  assert.equal(snapshots.at(-1).connectionStatus, "disconnected")
  const afterDispose = snapshots.length
  signaling.connect()
  assert.equal(snapshots.length, afterDispose)
  assert.equal(signaling.getState().connectionStatus, "disconnected")
})

test("startCall pushes the current wire fields on the existing inbox and applies a success reply", async () => {
  const events = []
  const receives = []
  const harness = fakeSocket(events, receives)
  const signaling = createCallSignaling({Socket: harness.Socket, csrfToken: "csrf"})
  signaling.connect()
  joinOk(receives, {signaling_session_id: "session-1", call: null})

  const pending = signaling.startCall({
    directConversationId: "conversation-1",
    mediaIntent: "video",
    userId: "should-not-be-sent",
  })

  assert.deepEqual(events.filter(([name]) => name === "new"), [
    ["new", "/calls", {params: {_csrf_token: "csrf"}}],
  ])
  assert.deepEqual(events.filter(([name]) => name === "channel"), [
    ["channel", CALL_INBOX_TOPIC, {}],
  ])
  assert.deepEqual(events.filter(([name]) => name === "push"), [
    [
      "push",
      "start_call",
      {
        signaling_session_id: "session-1",
        direct_conversation_id: "conversation-1",
        media_intent: "video",
      },
      CALL_INBOX_TOPIC,
    ],
  ])

  startReceive(receives, "ok")({
    signaling_session_id: "session-1",
    started: true,
    call: {call_id: "call-1", role: "caller", state: "ringing", media_intent: "video"},
  })

  assert.deepEqual(await pending, {
    ok: true,
    signaling_session_id: "session-1",
    started: true,
    call: {call_id: "call-1", role: "caller", state: "ringing", media_intent: "video"},
  })
  assert.deepEqual(signaling.getState(), {
    connectionStatus: "connected",
    signalingSessionId: "session-1",
    call: {call_id: "call-1", role: "caller", state: "ringing", media_intent: "video"},
    callTopicStatus: "joining",
  })
  assert.equal(Object.isFrozen(signaling.getState().call), true)
})

test("startCall errors and timeouts leave the current controller state authoritative", async () => {
  const receives = []
  const harness = fakeSocket([], receives)
  const signaling = createCallSignaling({Socket: harness.Socket, csrfToken: "csrf"})
  signaling.connect()
  joinOk(receives, {
    signaling_session_id: "session-1",
    call: {call_id: "call-live", role: "caller"},
  })

  for (const reason of ["busy", "rate_limited", "not_found", "invalid_request"]) {
    const pending = signaling.startCall({
      directConversationId: "conversation-1",
      mediaIntent: "audio",
    })
    startReceive(receives, "error")({reason})
    assert.deepEqual(await pending, {ok: false, error: reason})
    assert.equal(signaling.getState().call.call_id, "call-live")
    assert.equal(signaling.getState().signalingSessionId, "session-1")
  }

  const timedOut = signaling.startCall({
    directConversationId: "conversation-1",
    mediaIntent: "audio",
  })
  startReceive(receives, "timeout")()
  assert.deepEqual(await timedOut, {ok: false, error: "timeout"})
  assert.equal(signaling.getState().call.call_id, "call-live")
})

test("startCall does not push before join, while unavailable, after disconnect, or after dispose", async () => {
  const events = []
  const receives = []
  const harness = fakeSocket(events, receives)
  const signaling = createCallSignaling({Socket: harness.Socket, csrfToken: "csrf"})

  assert.deepEqual(
    await signaling.startCall({directConversationId: "conversation-1", mediaIntent: "audio"}),
    {ok: false, error: "unavailable"},
  )

  signaling.connect()
  assert.deepEqual(
    await signaling.startCall({directConversationId: "conversation-1", mediaIntent: "audio"}),
    {ok: false, error: "unavailable"},
  )

  joinOk(receives, {signaling_session_id: "session-1", call: null})
  harness.channel._canPush = false
  assert.deepEqual(
    await signaling.startCall({directConversationId: "conversation-1", mediaIntent: "audio"}),
    {ok: false, error: "unavailable"},
  )
  harness.channel._canPush = true

  signaling.disconnect()
  assert.deepEqual(
    await signaling.startCall({directConversationId: "conversation-1", mediaIntent: "audio"}),
    {ok: false, error: "unavailable"},
  )

  signaling.connect()
  joinOk(receives, {signaling_session_id: "session-2", call: null})
  signaling.dispose()
  assert.deepEqual(
    await signaling.startCall({directConversationId: "conversation-1", mediaIntent: "audio"}),
    {ok: false, error: "unavailable"},
  )

  assert.equal(events.filter(([name]) => name === "push").length, 0)
})

test("close and rejoin never replay a start, and a late ack cannot replace a newer snapshot", async () => {
  const events = []
  const receives = []
  const harness = fakeSocket(events, receives)
  const signaling = createCallSignaling({Socket: harness.Socket, csrfToken: "csrf"})
  signaling.connect()
  joinOk(receives, {signaling_session_id: "session-1", call: null})

  const pending = signaling.startCall({
    directConversationId: "conversation-1",
    mediaIntent: "audio",
  })
  assert.equal(events.filter(([name]) => name === "push").length, 1)

  harness.socket._onClose()
  assert.deepEqual(await pending, {ok: false, error: "unavailable"})
  assert.equal(signaling.getState().connectionStatus, "unavailable")

  joinOk(receives, {
    signaling_session_id: "session-2",
    call: {call_id: "call-2", role: "caller"},
  })
  assert.equal(signaling.getState().call.call_id, "call-2")
  assert.equal(events.filter(([name]) => name === "push").length, 1)

  startReceive(receives, "ok")({
    signaling_session_id: "session-1",
    started: true,
    call: {call_id: "call-stale", role: "caller"},
  })
  assert.equal(signaling.getState().signalingSessionId, "session-2")
  assert.equal(signaling.getState().call.call_id, "call-2")

  harness.channel.handlers.outgoing_call_ringing[0]({
    signaling_session_id: "session-2",
    call: {call_id: "call-live-event", role: "caller"},
  })
  assert.equal(signaling.getState().call.call_id, "call-live-event")

  const retry = signaling.startCall({
    directConversationId: "conversation-1",
    mediaIntent: "audio",
  })
  assert.equal(events.filter(([name]) => name === "push").length, 2)
  startReceive(receives, "ok")({
    signaling_session_id: "session-2",
    started: false,
    call: {call_id: "call-2", role: "caller", state: "ringing"},
  })
  assert.deepEqual(await retry, {
    ok: true,
    signaling_session_id: "session-2",
    started: false,
    call: {call_id: "call-2", role: "caller", state: "ringing"},
  })
  assert.equal(signaling.getState().call.call_id, "call-2")
})

test("a superseded start reply does not replace the Call ID a newer start adopted", async () => {
  const receives = []
  const harness = fakeSocket([], receives)
  const signaling = createCallSignaling({Socket: harness.Socket, csrfToken: "csrf"})
  signaling.connect()
  joinOk(receives, {signaling_session_id: "session-1", call: null})

  const first = signaling.startCall({
    directConversationId: "conversation-1",
    mediaIntent: "audio",
  })
  const firstOk = startReceive(receives, "ok")
  const second = signaling.startCall({
    directConversationId: "conversation-1",
    mediaIntent: "audio",
  })
  const secondOk = startReceive(receives, "ok")

  secondOk({
    signaling_session_id: "session-1",
    started: false,
    call: {call_id: "call-2", role: "caller", state: "ringing", media_intent: "audio"},
  })
  assert.equal(signaling.getState().call.call_id, "call-2")

  firstOk({
    signaling_session_id: "session-1",
    started: true,
    call: {call_id: "call-stale", role: "caller", state: "ringing", media_intent: "audio"},
  })
  assert.equal(signaling.getState().call.call_id, "call-2")
  assert.deepEqual(await first, {
    ok: true,
    signaling_session_id: "session-1",
    started: true,
    call: {call_id: "call-stale", role: "caller", state: "ringing", media_intent: "audio"},
  })
  assert.equal((await second).call.call_id, "call-2")

  harness.channel.handlers.outgoing_call_ringing[0]({
    signaling_session_id: "session-1",
    call: {call_id: "call-2", role: "caller", state: "ringing", media_intent: "audio"},
  })
  assert.equal(signaling.getState().call.call_id, "call-2")
})

test("an older start reply still applies when the newer start does not return a call", async () => {
  const receives = []
  const harness = fakeSocket([], receives)
  const signaling = createCallSignaling({Socket: harness.Socket, csrfToken: "csrf"})
  signaling.connect()
  joinOk(receives, {signaling_session_id: "session-1", call: null})

  const first = signaling.startCall({
    directConversationId: "conversation-1",
    mediaIntent: "audio",
  })
  const firstOk = startReceive(receives, "ok")
  const second = signaling.startCall({
    directConversationId: "conversation-2",
    mediaIntent: "audio",
  })
  startReceive(receives, "error")({reason: "busy"})

  assert.deepEqual(await second, {ok: false, error: "busy"})
  assert.equal(signaling.getState().call, null)

  firstOk({
    signaling_session_id: "session-1",
    started: true,
    call: {call_id: "call-first", role: "caller", state: "ringing", media_intent: "audio"},
  })
  assert.equal(signaling.getState().call.call_id, "call-first")
  assert.equal((await first).call.call_id, "call-first")
})

test("one socket owns the inbox and at most one Call Channel, joined after snapshot, ringing, or start", async () => {
  const events = []
  const receives = []
  const harness = fakeSocket(events, receives)
  const signaling = createCallSignaling({Socket: harness.Socket, csrfToken: "csrf"})
  signaling.connect()

  assert.deepEqual(events.filter(([name]) => name === "channel"), [
    ["channel", CALL_INBOX_TOPIC, {}],
  ])

  joinOk(receives, {
    signaling_session_id: "inbox-1",
    call: {call_id: "call-1", role: "caller", state: "ringing"},
  })

  const call1Topic = callTopic("call-1")
  assert.equal(events.filter(([name, topic]) => name === "channel" && topic === call1Topic).length, 1)
  assert.equal(events.filter(([name]) => name === "new").length, 1)

  const callJoinIndex = events.findIndex(([name, topic]) => name === "join" && topic === call1Topic)
  const firstCallHandler = events.findIndex(([name, _event, topic]) => name === "on" && topic === call1Topic)
  assert.ok(firstCallHandler >= 0)
  assert.ok(callJoinIndex > firstCallHandler)

  callJoinOk(receives, "call-1", {
    signaling_session_id: "call-session-1",
    call: {call_id: "call-1", role: "caller", state: "ringing"},
  })
  assert.notEqual(signaling.getState().signalingSessionId, "call-session-1")
  assert.equal(signaling.getState().signalingSessionId, "inbox-1")

  joinOk(receives, {signaling_session_id: "inbox-1", call: null})
  signaling.disconnect()
  signaling.connect()
  joinOk(receives, {signaling_session_id: "inbox-2", call: null})

  harness.channel.handlers.incoming_call[0]({
    signaling_session_id: "inbox-2",
    call: {call_id: "call-2", role: "recipient", state: "ringing"},
  })
  assert.equal(events.filter(([name, topic]) => name === "channel" && topic === callTopic("call-2")).length, 1)

  const pending = signaling.startCall({directConversationId: "conversation-1", mediaIntent: "audio"})
  startReceive(receives, "ok")({
    signaling_session_id: "inbox-2",
    started: true,
    call: {call_id: "call-3", role: "caller", state: "ringing"},
  })
  await pending

  assert.equal(events.filter(([name, topic]) => name === "leave" && topic === callTopic("call-2")).length, 1)
  assert.equal(events.filter(([name, topic]) => name === "channel" && topic === callTopic("call-3")).length, 1)
  assert.equal(events.filter(([name]) => name === "new").length, 2)
  assert.ok(!events.some(([name, event]) => name === "push" && CALL_TOPIC_CLIENT_EVENTS.includes(event)))
  assert.equal(CALL_TOPIC_PREFIX, "call:")
})

test("a Call-topic lifecycle event cannot replace the inbox Signaling Session ID", async () => {
  const events = []
  const receives = []
  const harness = fakeSocket(events, receives)
  const signaling = createCallSignaling({Socket: harness.Socket, csrfToken: "csrf"})
  signaling.connect()
  joinOk(receives, {
    signaling_session_id: "inbox-1",
    call: {call_id: "call-1", role: "recipient", state: "ringing"},
  })
  callJoinOk(receives, "call-1", {
    signaling_session_id: "call-session-1",
    call: {call_id: "call-1", role: "recipient", state: "ringing"},
  })

  harness.channelFor(callTopic("call-1")).handlers.call_connecting[0]({
    signaling_session_id: "call-session-1",
    call: {call_id: "call-1", role: "recipient", state: "connecting"},
  })

  assert.equal(signaling.getState().call.state, "connecting")
  assert.equal(signaling.getState().signalingSessionId, "inbox-1")

  const pending = signaling.startCall({
    directConversationId: "conversation-1",
    mediaIntent: "video",
  })
  const pushed = events.filter(([name]) => name === "push").at(-1)
  assert.deepEqual(pushed[2], {
    signaling_session_id: "inbox-1",
    direct_conversation_id: "conversation-1",
    media_intent: "video",
  })

  startReceive(receives, "ok")({
    signaling_session_id: "inbox-1",
    started: true,
    call: {call_id: "call-2", role: "caller", state: "ringing"},
  })
  await pending
  assert.equal(signaling.getState().call.call_id, "call-2")
  assert.equal(signaling.getState().signalingSessionId, "inbox-1")
})

for (const delayed of ["start", "join"]) {
  test(`a delayed ${delayed} snapshot cannot replace accepted ownership with its ringing preference`, async () => {
    const receives = [], harness = fakeSocket([], receives)
    const signaling = createCallSignaling({Socket: harness.Socket, csrfToken: "csrf"})
    signaling.connect()
    joinOk(receives, {signaling_session_id: "inbox-1", call: null})
    const pending = delayed === "start" ? signaling.startCall({directConversationId: "conversation", mediaIntent: "audio"}) : null
    const ringing = {call_id: "call-1", state: "ringing", role: "caller", ownership: "self", media_intent: "audio"}
    harness.channel.handlers.outgoing_call_ringing[0]({signaling_session_id: "inbox-1", call: ringing})
    const accepted = {...ringing, state: "active", ownership: "elsewhere"}
    harness.channel.handlers.call_active[0]({signaling_session_id: "inbox-1", call: accepted})
    if (delayed === "start") {
      startReceive(receives, "ok")({signaling_session_id: "inbox-1", call: ringing, started: true})
      await pending
    } else {
      callJoinOk(receives, "call-1", {signaling_session_id: "topic-session", call: ringing})
    }
    assert.deepEqual(signaling.getState().call, accepted)
    assert.equal((await signaling.mediaCredentials({callId: "call-1"})).ok, false)
    signaling.dispose()
  })
}

test("declineCall and cancelCall send the Call-topic identity and clear only the matching Call ID", async () => {
  const events = []
  const receives = []
  const harness = fakeSocket(events, receives)
  const signaling = createCallSignaling({Socket: harness.Socket, csrfToken: "csrf"})
  signaling.connect()
  joinOk(receives, {
    signaling_session_id: "inbox-1",
    call: {call_id: "call-1", role: "recipient", state: "ringing"},
  })
  callJoinOk(receives, "call-1", {
    signaling_session_id: "call-session-1",
    call: {call_id: "call-1", role: "recipient", state: "ringing"},
  })

  const declined = signaling.declineCall({callId: "call-1", userId: "should-not-be-sent"})
  assert.deepEqual(events.filter(([name]) => name === "push"), [
    [
      "push",
      "decline_call",
      {signaling_session_id: "call-session-1", call_id: "call-1"},
      callTopic("call-1"),
    ],
  ])

  commandReceive(receives, "ok", "decline_call")({
    signaling_session_id: "call-session-1",
    call: {call_id: "call-1", role: "recipient", terminal_outcome: "declined"},
  })
  assert.deepEqual(await declined, {
    ok: true,
    signaling_session_id: "call-session-1",
    call: {call_id: "call-1", role: "recipient", terminal_outcome: "declined"},
  })
  assert.equal(signaling.getState().call, null)
  assert.equal(signaling.getState().signalingSessionId, "inbox-1")
  assert.equal(events.filter(([name, topic]) => name === "leave" && topic === callTopic("call-1")).length, 1)

  joinOk(receives, {
    signaling_session_id: "inbox-1",
    call: {call_id: "call-2", role: "caller", state: "ringing"},
  })
  callJoinOk(receives, "call-2", {
    signaling_session_id: "call-session-2",
    call: {call_id: "call-2", role: "caller", state: "ringing"},
  })

  const cancelled = signaling.cancelCall({callId: "call-2"})
  commandReceive(receives, "ok", "cancel_call")({
    signaling_session_id: "call-session-2",
    call: {call_id: "call-2", role: "caller", terminal_outcome: "cancelled"},
  })
  assert.deepEqual(await cancelled, {
    ok: true,
    signaling_session_id: "call-session-2",
    call: {call_id: "call-2", role: "caller", terminal_outcome: "cancelled"},
  })
  assert.equal(signaling.getState().call, null)
})

test("a terminal Call-topic join snapshot clears the matching Call ID and does not remain commandable", async () => {
  const events = []
  const receives = []
  const harness = fakeSocket(events, receives)
  const signaling = createCallSignaling({Socket: harness.Socket, csrfToken: "csrf"})
  signaling.connect()
  joinOk(receives, {
    signaling_session_id: "inbox-1",
    call: {call_id: "call-1", role: "caller", state: "ringing"},
  })
  callJoinOk(receives, "call-1", {
    signaling_session_id: "call-session-1",
    call: {call_id: "call-1", role: "caller", state: "terminal", terminal_outcome: "declined"},
  })

  assert.equal(signaling.getState().call, null)
  assert.equal(signaling.getState().signalingSessionId, "inbox-1")
  assert.equal(events.filter(([name, topic]) => name === "leave" && topic === callTopic("call-1")).length, 1)
  assert.deepEqual(await signaling.declineCall({callId: "call-1"}), {ok: false, error: "unavailable"})
  assert.deepEqual(await signaling.cancelCall({callId: "call-1"}), {ok: false, error: "unavailable"})
  assert.equal(events.filter(([name, event]) => name === "push" && CALL_TOPIC_CLIENT_EVENTS.includes(event)).length, 0)
})

test("terminal events from inbox and Call Channels are idempotent and ignore an old Call ID", () => {
  const receives = []
  const harness = fakeSocket([], receives)
  const signaling = createCallSignaling({Socket: harness.Socket, csrfToken: "csrf"})
  signaling.connect()
  joinOk(receives, {
    signaling_session_id: "inbox-1",
    call: {call_id: "call-1", role: "caller", state: "ringing"},
  })
  callJoinOk(receives, "call-1", {
    signaling_session_id: "call-session-1",
    call: {call_id: "call-1", role: "caller", state: "ringing"},
  })

  const snapshots = []
  signaling.subscribe(snapshot => snapshots.push(snapshot))
  const before = snapshots.length

  harness.channel.handlers.call_ended[0]({call: {call_id: "call-old"}})
  assert.equal(signaling.getState().call.call_id, "call-1")

  harness.channel.handlers.call_declined[0]({
    signaling_session_id: "inbox-1",
    call: {call_id: "call-1", role: "caller", terminal_outcome: "declined"},
  })
  assert.equal(signaling.getState().call, null)
  const afterInbox = snapshots.length
  assert.ok(afterInbox > before)

  harness.channelFor(callTopic("call-1")).handlers.call_declined[0]({
    signaling_session_id: "call-session-1",
    call: {call_id: "call-1", role: "recipient", terminal_outcome: "declined"},
  })
  assert.equal(signaling.getState().call, null)
  assert.equal(snapshots.length, afterInbox)
})

test("declineCall and cancelCall do not queue before join, on join failure, or after teardown", async () => {
  const events = []
  const receives = []
  const harness = fakeSocket(events, receives)
  const signaling = createCallSignaling({Socket: harness.Socket, csrfToken: "csrf"})

  assert.deepEqual(await signaling.declineCall({callId: "call-1"}), {ok: false, error: "unavailable"})
  assert.deepEqual(await signaling.cancelCall({callId: "call-1"}), {ok: false, error: "unavailable"})

  signaling.connect()
  joinOk(receives, {
    signaling_session_id: "inbox-1",
    call: {call_id: "call-1", role: "caller", state: "ringing"},
  })
  assert.deepEqual(await signaling.declineCall({callId: "call-1"}), {ok: false, error: "unavailable"})

  callJoinOk(receives, "call-1", {signaling_session_id: "call-session-1", call: {call_id: "call-other"}})
  assert.equal(signaling.getState().call.call_id, "call-1")
  assert.deepEqual(await signaling.cancelCall({callId: "call-1"}), {ok: false, error: "unavailable"})

  joinOk(receives, {
    signaling_session_id: "inbox-1",
    call: {call_id: "call-2", role: "caller", state: "ringing"},
  })
  const call2Receives = receives.filter(([_status, _cb, event, topic]) => event == null && topic === callTopic("call-2"))
  call2Receives.find(([status]) => status === "error")[1]()
  assert.equal(signaling.getState().call.call_id, "call-2")
  assert.deepEqual(await signaling.declineCall({callId: "call-2"}), {ok: false, error: "unavailable"})

  joinOk(receives, {
    signaling_session_id: "inbox-1",
    call: {call_id: "call-3", role: "caller", state: "ringing"},
  })
  callJoinOk(receives, "call-3", {
    signaling_session_id: "call-session-3",
    call: {call_id: "call-3", role: "caller", state: "ringing"},
  })
  assert.deepEqual(await signaling.declineCall({callId: "call-old"}), {ok: false, error: "unavailable"})

  harness.channelFor(callTopic("call-3"))._canPush = false
  assert.deepEqual(await signaling.cancelCall({callId: "call-3"}), {ok: false, error: "unavailable"})
  harness.channelFor(callTopic("call-3"))._canPush = true

  signaling.disconnect()
  assert.deepEqual(await signaling.declineCall({callId: "call-3"}), {ok: false, error: "unavailable"})
  assert.equal(events.filter(([name, event]) => name === "push" && CALL_TOPIC_CLIENT_EVENTS.includes(event)).length, 0)
})

test("dispose does not enter a send buffer for declineCall or cancelCall", async () => {
  const events = []
  const receives = []
  const harness = fakeSocket(events, receives)
  const signaling = createCallSignaling({Socket: harness.Socket, csrfToken: "csrf"})
  signaling.connect()
  joinOk(receives, {
    signaling_session_id: "inbox-1",
    call: {call_id: "call-1", role: "caller", state: "ringing"},
  })
  callJoinOk(receives, "call-1", {
    signaling_session_id: "call-session-1",
    call: {call_id: "call-1", role: "caller", state: "ringing"},
  })

  signaling.dispose()
  assert.deepEqual(await signaling.declineCall({callId: "call-1"}), {ok: false, error: "unavailable"})
  assert.deepEqual(await signaling.cancelCall({callId: "call-1"}), {ok: false, error: "unavailable"})
  assert.equal(events.filter(([name, event]) => name === "push" && CALL_TOPIC_CLIENT_EVENTS.includes(event)).length, 0)
})

test("a failed Call-topic join can be retried for the same Call ID from a later ringing event", async () => {
  const events = []
  const receives = []
  const harness = fakeSocket(events, receives)
  const signaling = createCallSignaling({Socket: harness.Socket, csrfToken: "csrf"})
  signaling.connect()
  joinOk(receives, {
    signaling_session_id: "inbox-1",
    call: {call_id: "call-1", role: "caller", state: "ringing"},
  })

  ;[...receives].reverse().find(([status, _callback, event, topic]) => (
    status === "error" && event == null && topic === callTopic("call-1")
  ))[1]()

  assert.equal(signaling.getState().call.call_id, "call-1")
  assert.deepEqual(await signaling.declineCall({callId: "call-1"}), {ok: false, error: "unavailable"})

  harness.channel.handlers.outgoing_call_ringing[0]({
    signaling_session_id: "inbox-1",
    call: {call_id: "call-1", role: "caller", state: "ringing"},
  })
  assert.equal(events.filter(([name, topic]) => name === "channel" && topic === callTopic("call-1")).length, 2)

  callJoinOk(receives, "call-1", {
    signaling_session_id: "call-session-retry",
    call: {call_id: "call-1", role: "caller", state: "ringing"},
  })

  const declined = signaling.declineCall({callId: "call-1"})
  commandReceive(receives, "ok", "decline_call")({
    signaling_session_id: "call-session-retry",
    call: {call_id: "call-1", role: "caller", terminal_outcome: "declined"},
  })
  assert.deepEqual(await declined, {
    ok: true,
    signaling_session_id: "call-session-retry",
    call: {call_id: "call-1", role: "caller", terminal_outcome: "declined"},
  })
  assert.equal(signaling.getState().call, null)
})

test("a late start acknowledgement does not revive a terminal Call ID", async () => {
  const receives = []
  const harness = fakeSocket([], receives)
  const signaling = createCallSignaling({Socket: harness.Socket, csrfToken: "csrf"})
  signaling.connect()
  joinOk(receives, {signaling_session_id: "session-1", call: null})

  const pending = signaling.startCall({
    directConversationId: "conversation-1",
    mediaIntent: "audio",
  })
  const startOk = startReceive(receives, "ok")
  const call = {call_id: "call-1", role: "caller", state: "ringing", media_intent: "audio"}

  harness.channel.handlers.outgoing_call_ringing[0]({
    signaling_session_id: "session-1",
    call,
  })
  assert.equal(signaling.getState().call.call_id, "call-1")

  harness.channel.handlers.call_cancelled[0]({
    signaling_session_id: "session-1",
    call: {call_id: "call-1", role: "caller", terminal_outcome: "cancelled"},
  })
  assert.equal(signaling.getState().call, null)

  startOk({
    signaling_session_id: "session-1",
    started: true,
    call,
  })

  assert.deepEqual(await pending, {
    ok: true,
    signaling_session_id: "session-1",
    started: true,
    call,
  })
  assert.equal(signaling.getState().call, null)
  assert.equal(signaling.getState().signalingSessionId, "session-1")
  assert.equal(signaling.getState().callTopicStatus, "idle")
})

test("a late start acknowledgement for a retired Call ID does not replace a newer pending start", async () => {
  const receives = []
  const harness = fakeSocket([], receives)
  const signaling = createCallSignaling({Socket: harness.Socket, csrfToken: "csrf"})
  signaling.connect()
  joinOk(receives, {signaling_session_id: "session-1", call: null})

  const first = signaling.startCall({
    directConversationId: "conversation-1",
    mediaIntent: "audio",
  })
  const firstOk = startReceive(receives, "ok")
  const stale = {call_id: "call-stale", role: "caller", state: "ringing", media_intent: "audio"}

  harness.channel.handlers.outgoing_call_ringing[0]({
    signaling_session_id: "session-1",
    call: stale,
  })
  harness.channel.handlers.call_cancelled[0]({
    signaling_session_id: "session-1",
    call: {call_id: "call-stale", role: "caller", terminal_outcome: "cancelled"},
  })
  assert.equal(signaling.getState().call, null)

  const second = signaling.startCall({
    directConversationId: "conversation-1",
    mediaIntent: "audio",
  })
  const secondOk = startReceive(receives, "ok")

  firstOk({
    signaling_session_id: "session-1",
    started: true,
    call: stale,
  })
  assert.equal(signaling.getState().call, null)
  assert.equal((await first).call.call_id, "call-stale")

  secondOk({
    signaling_session_id: "session-1",
    started: true,
    call: {call_id: "call-2", role: "caller", state: "ringing", media_intent: "audio"},
  })
  assert.equal(signaling.getState().call.call_id, "call-2")
  assert.equal((await second).call.call_id, "call-2")
})

test("Call-topic join success and failure update callTopicStatus without a second ringing event", () => {
  const receives = []
  const harness = fakeSocket([], receives)
  const signaling = createCallSignaling({Socket: harness.Socket, csrfToken: "csrf"})
  signaling.connect()
  joinOk(receives, {
    signaling_session_id: "inbox-1",
    call: {call_id: "call-1", role: "caller", state: "ringing"},
  })
  assert.equal(signaling.getState().callTopicStatus, "joining")
  assert.equal(signaling.getState().call.call_id, "call-1")

  callJoinOk(receives, "call-1", {
    signaling_session_id: "call-session-1",
    call: {call_id: "call-1", role: "caller", state: "ringing"},
  })
  assert.equal(signaling.getState().callTopicStatus, "joined")
  assert.equal(signaling.getState().call.call_id, "call-1")

  joinOk(receives, {
    signaling_session_id: "inbox-1",
    call: {call_id: "call-2", role: "caller", state: "ringing"},
  })
  assert.equal(signaling.getState().callTopicStatus, "joining")

  ;[...receives].reverse().find(([status, _callback, event, topic]) => (
    status === "error" && event == null && topic === callTopic("call-2")
  ))[1]()

  assert.equal(signaling.getState().callTopicStatus, "failed")
  assert.equal(signaling.getState().call.call_id, "call-2")
  assert.equal(signaling.getState().signalingSessionId, "inbox-1")
})

test("a non-ringing inbox snapshot does not join a Call topic", () => {
  const events = []
  const receives = []
  const harness = fakeSocket(events, receives)
  const signaling = createCallSignaling({Socket: harness.Socket, csrfToken: "csrf"})
  signaling.connect()
  joinOk(receives, {
    signaling_session_id: "inbox-1",
    call: {call_id: "call-1", role: "caller", state: "terminal", terminal_outcome: "declined"},
  })

  assert.equal(signaling.getState().call, null)
  assert.equal(events.filter(([name, topic]) => name === "channel" && topic === callTopic("call-1")).length, 0)
  assert.ok(!events.some(([name, event]) => name === "push" && CALL_TOPIC_CLIENT_EVENTS.includes(event)))
})

test("inbox rejoin snapshot replaces ringing with a newer Call or null and syncs the Call topic without commands", () => {
  const events = []
  const receives = []
  const harness = fakeSocket(events, receives)
  const signaling = createCallSignaling({Socket: harness.Socket, csrfToken: "csrf"})
  signaling.connect()
  joinOk(receives, {
    signaling_session_id: "inbox-1",
    call: {call_id: "call-1", role: "caller", state: "ringing"},
  })
  callJoinOk(receives, "call-1", {
    signaling_session_id: "call-session-1",
    call: {call_id: "call-1", role: "caller", state: "ringing"},
  })

  joinOk(receives, {
    signaling_session_id: "inbox-2",
    call: {call_id: "call-2", role: "caller", state: "ringing"},
  })
  assert.equal(signaling.getState().call.call_id, "call-2")
  assert.equal(signaling.getState().signalingSessionId, "inbox-2")
  assert.equal(events.filter(([name, topic]) => name === "leave" && topic === callTopic("call-1")).length, 1)
  assert.equal(events.filter(([name, topic]) => name === "channel" && topic === callTopic("call-2")).length, 1)

  callJoinOk(receives, "call-2", {
    signaling_session_id: "call-session-2",
    call: {call_id: "call-2", role: "caller", state: "ringing"},
  })

  joinOk(receives, {signaling_session_id: "inbox-3", call: null})
  assert.equal(signaling.getState().call, null)
  assert.equal(signaling.getState().signalingSessionId, "inbox-3")
  assert.equal(events.filter(([name, topic]) => name === "leave" && topic === callTopic("call-2")).length, 1)
  assert.ok(!events.some(([name, event]) => name === "push" && CALL_TOPIC_CLIENT_EVENTS.includes(event)))
})

test("delayed ringing after a terminal snapshot cannot revive that Call ID", () => {
  const receives = []
  const harness = fakeSocket([], receives)
  const signaling = createCallSignaling({Socket: harness.Socket, csrfToken: "csrf"})
  signaling.connect()
  joinOk(receives, {
    signaling_session_id: "inbox-1",
    call: {call_id: "call-1", role: "recipient", state: "ringing"},
  })
  callJoinOk(receives, "call-1", {
    signaling_session_id: "call-session-1",
    call: {call_id: "call-1", role: "recipient", state: "ringing"},
  })

  harness.channel.handlers.call_declined[0]({
    signaling_session_id: "inbox-1",
    call: {call_id: "call-1", role: "recipient", terminal_outcome: "declined"},
  })
  assert.equal(signaling.getState().call, null)

  harness.channel.handlers.incoming_call[0]({
    signaling_session_id: "inbox-1",
    call: {call_id: "call-1", role: "recipient", state: "ringing"},
  })
  assert.equal(signaling.getState().call, null)
  assert.equal(signaling.getState().signalingSessionId, "inbox-1")
})

test("a delayed ringing push cannot move a connecting or active Call backward", () => {
  const events = []
  const receives = []
  const harness = fakeSocket(events, receives)
  const signaling = createCallSignaling({Socket: harness.Socket, csrfToken: "csrf"})
  const snapshots = []
  signaling.subscribe(snapshot => snapshots.push(snapshot))
  signaling.connect()
  joinOk(receives, {
    signaling_session_id: "inbox-1",
    call: {
      call_id: "call-1",
      role: "recipient",
      state: "ringing",
      media_intent: "audio",
      ownership: "unclaimed",
    },
  })
  callJoinOk(receives, "call-1", {
    signaling_session_id: "call-session-1",
    call: {
      call_id: "call-1",
      role: "recipient",
      state: "ringing",
      media_intent: "audio",
      ownership: "unclaimed",
    },
  })

  harness.channel.handlers.call_connecting[0]({
    signaling_session_id: "inbox-1",
    call: {
      call_id: "call-1",
      role: "recipient",
      state: "connecting",
      media_intent: "audio",
      ownership: "self",
    },
  })
  assert.equal(signaling.getState().call.state, "connecting")
  const afterConnecting = snapshots.length
  const channelsAfterConnecting = events.filter(([name]) => name === "channel").length

  // Acceptance can commit between the inbox database check and its ringing push.
  harness.channel.handlers.incoming_call[0]({
    signaling_session_id: "inbox-1",
    call: {
      call_id: "call-1",
      role: "recipient",
      state: "ringing",
      media_intent: "audio",
      ownership: "unclaimed",
    },
  })
  harness.channel.handlers.outgoing_call_ringing[0]({
    signaling_session_id: "inbox-1",
    call: {
      call_id: "call-1",
      role: "caller",
      state: "ringing",
      media_intent: "audio",
      ownership: "elsewhere",
    },
  })

  assert.equal(signaling.getState().call.state, "connecting")
  assert.equal(signaling.getState().call.ownership, "self")
  assert.equal(snapshots.length, afterConnecting)
  assert.equal(events.filter(([name]) => name === "channel").length, channelsAfterConnecting)

  harness.channel.handlers.call_active[0]({
    signaling_session_id: "inbox-1",
    call: {
      call_id: "call-1",
      role: "recipient",
      state: "active",
      media_intent: "audio",
      ownership: "self",
    },
  })
  assert.equal(signaling.getState().call.state, "active")
  const afterActive = snapshots.length

  harness.channel.handlers.incoming_call[0]({
    signaling_session_id: "inbox-1",
    call: {
      call_id: "call-1",
      role: "recipient",
      state: "ringing",
      media_intent: "audio",
      ownership: "unclaimed",
    },
  })

  assert.equal(signaling.getState().call.state, "active")
  assert.equal(signaling.getState().call.ownership, "self")
  assert.equal(snapshots.length, afterActive)
})

test("an old Call's terminal or ringing cannot clear or replace a newer snapshot", () => {
  const receives = []
  const harness = fakeSocket([], receives)
  const signaling = createCallSignaling({Socket: harness.Socket, csrfToken: "csrf"})
  signaling.connect()
  joinOk(receives, {
    signaling_session_id: "inbox-1",
    call: {call_id: "call-1", role: "caller", state: "ringing"},
  })
  callJoinOk(receives, "call-1", {
    signaling_session_id: "call-session-1",
    call: {call_id: "call-1", role: "caller", state: "ringing"},
  })

  joinOk(receives, {
    signaling_session_id: "inbox-1",
    call: {call_id: "call-2", role: "caller", state: "ringing"},
  })
  callJoinOk(receives, "call-2", {
    signaling_session_id: "call-session-2",
    call: {call_id: "call-2", role: "caller", state: "ringing"},
  })
  assert.equal(signaling.getState().call.call_id, "call-2")

  harness.channel.handlers.call_ended[0]({call: {call_id: "call-1", terminal_outcome: "cancelled"}})
  harness.channel.handlers.call_declined[0]({call: {call_id: "call-1", terminal_outcome: "declined"}})
  harness.channel.handlers.call_cancelled[0]({call: {call_id: "call-1", terminal_outcome: "cancelled"}})
  harness.channel.handlers.outgoing_call_ringing[0]({
    signaling_session_id: "inbox-1",
    call: {call_id: "call-1", role: "caller", state: "ringing"},
  })
  harness.channelFor(callTopic("call-1")).handlers.call_ended[0]({
    call: {call_id: "call-1", terminal_outcome: "relationship_ended"},
  })

  assert.equal(signaling.getState().call.call_id, "call-2")
  assert.equal(signaling.getState().signalingSessionId, "inbox-1")
})

test("late Call-topic join ok, error, close, and command ack from a retired generation cannot replace a newer snapshot", async () => {
  const events = []
  const receives = []
  const harness = fakeSocket(events, receives)
  const signaling = createCallSignaling({Socket: harness.Socket, csrfToken: "csrf"})
  signaling.connect()
  joinOk(receives, {
    signaling_session_id: "inbox-1",
    call: {call_id: "call-1", role: "caller", state: "ringing"},
  })
  callJoinOk(receives, "call-1", {
    signaling_session_id: "call-session-1",
    call: {call_id: "call-1", role: "caller", state: "ringing"},
  })

  joinOk(receives, {
    signaling_session_id: "inbox-2",
    call: {call_id: "call-2", role: "caller", state: "ringing"},
  })
  callJoinOk(receives, "call-2", {
    signaling_session_id: "call-session-2",
    call: {call_id: "call-2", role: "caller", state: "ringing"},
  })

  callJoinOk(receives, "call-1", {
    signaling_session_id: "stale-call-session",
    call: {call_id: "call-1", role: "caller", state: "ringing"},
  })
  ;[...receives].reverse().find(([status, _callback, event, topic]) => (
    status === "error" && event == null && topic === callTopic("call-1")
  ))[1]()
  harness.channelFor(callTopic("call-1"))._onClose()

  assert.equal(signaling.getState().call.call_id, "call-2")
  assert.equal(signaling.getState().signalingSessionId, "inbox-2")
  assert.deepEqual(await signaling.declineCall({callId: "call-1"}), {ok: false, error: "unavailable"})
  assert.ok(!events.some(([name, event]) => name === "push" && CALL_TOPIC_CLIENT_EVENTS.includes(event)))
})

test("server-style Call-topic onClose after a matching call_ended does not send a command or clear a different Call ID", async () => {
  const events = []
  const receives = []
  const harness = fakeSocket(events, receives)
  const signaling = createCallSignaling({Socket: harness.Socket, csrfToken: "csrf"})
  signaling.connect()
  joinOk(receives, {
    signaling_session_id: "inbox-1",
    call: {call_id: "call-1", role: "caller", state: "ringing"},
  })
  callJoinOk(receives, "call-1", {
    signaling_session_id: "call-session-1",
    call: {call_id: "call-1", role: "caller", state: "ringing"},
  })

  harness.channelFor(callTopic("call-1")).handlers.call_ended[0]({
    signaling_session_id: "call-session-1",
    call: {call_id: "call-1", role: "caller", terminal_outcome: "relationship_ended"},
  })
  assert.equal(signaling.getState().call, null)
  harness.channelFor(callTopic("call-1"))._onClose()
  assert.equal(signaling.getState().call, null)
  assert.equal(signaling.getState().signalingSessionId, "inbox-1")
  assert.ok(!events.some(([name, event]) => name === "push" && CALL_TOPIC_CLIENT_EVENTS.includes(event)))

  joinOk(receives, {
    signaling_session_id: "inbox-1",
    call: {call_id: "call-2", role: "caller", state: "ringing"},
  })
  callJoinOk(receives, "call-2", {
    signaling_session_id: "call-session-2",
    call: {call_id: "call-2", role: "caller", state: "ringing"},
  })
  harness.channelFor(callTopic("call-1"))._onClose()
  assert.equal(signaling.getState().call.call_id, "call-2")
  assert.equal(signaling.getState().signalingSessionId, "inbox-1")
  assert.equal(events.filter(([name, event]) => name === "push" && CALL_TOPIC_CLIENT_EVENTS.includes(event)).length, 0)
})

test("late Call-topic callbacks cannot replace a newer snapshot, and reconnect does not replay decline or cancel", async () => {
  const events = []
  const receives = []
  const harness = fakeSocket(events, receives)
  const signaling = createCallSignaling({Socket: harness.Socket, csrfToken: "csrf"})
  signaling.connect()
  joinOk(receives, {
    signaling_session_id: "inbox-1",
    call: {call_id: "call-1", role: "caller", state: "ringing"},
  })
  callJoinOk(receives, "call-1", {
    signaling_session_id: "call-session-1",
    call: {call_id: "call-1", role: "caller", state: "ringing"},
  })

  const pending = signaling.cancelCall({callId: "call-1"})
  harness.socket._onClose()
  assert.deepEqual(await pending, {ok: false, error: "unavailable"})

  joinOk(receives, {
    signaling_session_id: "inbox-2",
    call: {call_id: "call-2", role: "caller", state: "ringing"},
  })
  callJoinOk(receives, "call-2", {
    signaling_session_id: "call-session-2",
    call: {call_id: "call-2", role: "caller", state: "ringing"},
  })
  assert.equal(signaling.getState().call.call_id, "call-2")

  commandReceive(receives, "ok", "cancel_call")({
    signaling_session_id: "call-session-1",
    call: {call_id: "call-1", role: "caller", terminal_outcome: "cancelled"},
  })
  assert.equal(signaling.getState().call.call_id, "call-2")

  harness.channelFor(callTopic("call-1")).handlers.call_cancelled[0]({
    call: {call_id: "call-1", terminal_outcome: "cancelled"},
  })
  assert.equal(signaling.getState().call.call_id, "call-2")

  callJoinOk(receives, "call-1", {
    signaling_session_id: "stale-call-session",
    call: {call_id: "call-1", role: "caller", state: "ringing"},
  })
  assert.equal(signaling.getState().call.call_id, "call-2")
  assert.equal(signaling.getState().signalingSessionId, "inbox-2")
  assert.equal(events.filter(([name, event]) => name === "push" && CALL_TOPIC_CLIENT_EVENTS.includes(event)).length, 1)

  const timeoutPending = signaling.cancelCall({callId: "call-2"})
  commandReceive(receives, "timeout", "cancel_call")()
  assert.deepEqual(await timeoutPending, {ok: false, error: "timeout"})
  assert.equal(signaling.getState().call.call_id, "call-2")
})

test("acceptCall and leaveCall use exact envelopes and keep the Call topic through active", async () => {
  const events = []
  const receives = []
  const harness = fakeSocket(events, receives)
  const signaling = createCallSignaling({Socket: harness.Socket, csrfToken: "csrf"})
  signaling.connect()
  joinOk(receives, {
    signaling_session_id: "inbox-1",
    call: {
      call_id: "call-1",
      role: "recipient",
      state: "ringing",
      media_intent: "audio",
      peer: {id: "caller-1", username: "alice"},
    },
  })
  callJoinOk(receives, "call-1", {
    signaling_session_id: "call-session-1",
    call: {call_id: "call-1", role: "recipient", state: "ringing", media_intent: "audio"},
  })

  const accepted = signaling.acceptCall({callId: "call-1", answerMode: "audio", role: "forged"})
  assert.deepEqual(events.filter(([name, event]) => name === "push" && event === "accept_call"), [[
    "push",
    "accept_call",
    {
      signaling_session_id: "call-session-1",
      call_id: "call-1",
      answer_mode: "audio",
    },
    callTopic("call-1"),
  ]])

  commandReceive(receives, "ok", "accept_call")({
    signaling_session_id: "call-session-1",
    call: {call_id: "call-1", role: "recipient", state: "connecting", media_intent: "audio"},
  })
  assert.equal((await accepted).call.state, "connecting")
  assert.equal(signaling.getState().call.state, "connecting")
  assert.equal(signaling.getState().callTopicStatus, "joined")
  assert.equal(events.filter(([name, topic]) => name === "leave" && topic === callTopic("call-1")).length, 0)

  harness.channel.handlers.call_active[0]({
    signaling_session_id: "inbox-1",
    call: {call_id: "call-1", role: "recipient", state: "active", media_intent: "audio"},
  })
  assert.equal(signaling.getState().call.state, "active")
  assert.equal(signaling.getState().callTopicStatus, "joined")

  const left = signaling.leaveCall({callId: "call-1", userId: "forged"})
  assert.deepEqual(events.filter(([name, event]) => name === "push" && event === "leave_call"), [[
    "push",
    "leave_call",
    {signaling_session_id: "call-session-1", call_id: "call-1"},
    callTopic("call-1"),
  ]])
  commandReceive(receives, "ok", "leave_call")({
    signaling_session_id: "call-session-1",
    call: {call_id: "call-1", role: "recipient", state: "terminal", terminal_outcome: "ended"},
  })
  assert.equal((await left).call.terminal_outcome, "ended")
  assert.equal(signaling.getState().call, null)
  assert.equal(signaling.getState().terminalCall.terminal_outcome, "ended")
  assert.equal(signaling.getState().callTopicStatus, "idle")
})

test("acceptCall transports video mode exactly and rejects modes outside the allowlist", async () => {
  const events = []
  const receives = []
  const harness = fakeSocket(events, receives)
  const signaling = createCallSignaling({Socket: harness.Socket, csrfToken: "csrf"})
  signaling.connect()
  joinOk(receives, {
    signaling_session_id: "inbox-1",
    call: {call_id: "video-1", role: "recipient", state: "ringing", media_intent: "video"},
  })
  callJoinOk(receives, "video-1", {
    signaling_session_id: "call-session-1",
    call: {call_id: "video-1", role: "recipient", state: "ringing", media_intent: "video"},
  })

  const accepted = signaling.acceptCall({callId: "video-1", answerMode: "video"})
  assert.deepEqual(events.filter(([name, event]) => name === "push" && event === "accept_call"), [[
    "push",
    "accept_call",
    {
      signaling_session_id: "call-session-1",
      call_id: "video-1",
      answer_mode: "video",
    },
    callTopic("video-1"),
  ]])
  commandReceive(receives, "ok", "accept_call")({
    signaling_session_id: "call-session-1",
    call: {
      call_id: "video-1",
      role: "recipient",
      state: "connecting",
      media_intent: "video",
      answer_mode: "video",
    },
  })
  assert.equal((await accepted).call.answer_mode, "video")
  assert.equal(signaling.getState().call.answer_mode, "video")

  assert.deepEqual(await signaling.acceptCall({callId: "video-1", answerMode: "screen"}), {
    ok: false,
    error: "invalid_request",
  })
  assert.equal(events.filter(([name, event]) => name === "push" && event === "accept_call").length, 1)
})

test("lifecycle delivery is idempotent, stale-safe, and terminal truth is retained", () => {
  const receives = []
  const harness = fakeSocket([], receives)
  const signaling = createCallSignaling({Socket: harness.Socket, csrfToken: "csrf"})
  const snapshots = []
  signaling.subscribe(snapshot => snapshots.push(snapshot))
  signaling.connect()
  joinOk(receives, {
    signaling_session_id: "inbox-1",
    call: {call_id: "call-1", role: "caller", state: "ringing", media_intent: "audio"},
  })
  callJoinOk(receives, "call-1", {
    signaling_session_id: "call-session-1",
    call: {call_id: "call-1", role: "caller", state: "ringing", media_intent: "audio"},
  })

  const connecting = {
    signaling_session_id: "inbox-1",
    call: {call_id: "call-1", role: "caller", state: "connecting", media_intent: "audio"},
  }
  harness.channel.handlers.call_connecting[0](connecting)
  const afterInbox = snapshots.length
  harness.channelFor(callTopic("call-1")).handlers.call_connecting[0](connecting)
  assert.equal(snapshots.length, afterInbox)

  harness.channel.handlers.call_connecting[0]({
    ...connecting,
    call: {...connecting.call, answer_mode: "audio"},
  })
  assert.equal(signaling.getState().call.answer_mode, "audio")
  assert.equal(snapshots.length, afterInbox + 1)

  harness.channel.handlers.call_active[0]({
    call: {call_id: "stale", role: "caller", state: "active"},
  })
  assert.equal(signaling.getState().call.state, "connecting")

  harness.channel.handlers.call_active[0]({
    signaling_session_id: "inbox-1",
    call: {call_id: "call-1", role: "caller", state: "active", media_intent: "audio"},
  })
  const active = signaling.getState().call
  const afterActive = snapshots.length
  harness.channelFor(callTopic("call-1")).handlers.call_connecting[0](connecting)
  assert.equal(signaling.getState().call, active)
  assert.equal(signaling.getState().call.state, "active")
  assert.equal(snapshots.length, afterActive)

  harness.channel.handlers.call_error[0]({
    signaling_session_id: "inbox-1",
    call: {
      call_id: "call-1",
      role: "caller",
      state: "terminal",
      terminal_outcome: "failed_capacity",
      peer: {id: "recipient-1", username: "bob"},
    },
  })
  const terminal = signaling.getState().terminalCall
  assert.equal(terminal.terminal_outcome, "failed_capacity")
  assert.deepEqual(terminal.peer, {id: "recipient-1", username: "bob"})
  assert.equal(Object.isFrozen(terminal.peer), true)
  const afterTerminal = snapshots.length

  harness.channel.handlers.call_active[0]({
    call: {call_id: "call-1", role: "caller", state: "active"},
  })
  assert.equal(signaling.getState().call, null)
  assert.equal(signaling.getState().terminalCall, terminal)
  assert.equal(snapshots.length, afterTerminal)
})

test("ownership passes through untouched and the sibling event is a lifecycle-class signal", () => {
  const receives = []
  const harness = fakeSocket([], receives)
  const signaling = createCallSignaling({Socket: harness.Socket, csrfToken: "csrf"})
  const snapshots = []
  signaling.subscribe(snapshot => snapshots.push(snapshot))
  signaling.connect()

  joinOk(receives, {
    signaling_session_id: "inbox-1",
    call: {
      call_id: "call-1",
      role: "recipient",
      state: "ringing",
      media_intent: "audio",
      ownership: "unclaimed",
    },
  })
  assert.equal(signaling.getState().call.ownership, "unclaimed")

  harness.channel.handlers.call_connecting[0]({
    signaling_session_id: "inbox-1",
    call: {
      call_id: "call-1",
      role: "recipient",
      state: "connecting",
      media_intent: "audio",
      ownership: "elsewhere",
    },
  })
  assert.equal(signaling.getState().call.state, "connecting")
  assert.equal(signaling.getState().call.ownership, "elsewhere")
  assert.equal(signaling.getState().callTopicStatus, "joining")

  const afterConnecting = snapshots.length
  const callChannel = harness.channelFor(callTopic("call-1"))
  callChannel.handlers.sibling_tab_owns_call[0]({
    signaling_session_id: "call-session-1",
    call: {
      call_id: "call-1",
      role: "recipient",
      state: "connecting",
      media_intent: "audio",
      ownership: "elsewhere",
    },
  })
  assert.equal(snapshots.length, afterConnecting)

  harness.channel.handlers.call_active[0]({
    signaling_session_id: "inbox-1",
    call: {
      call_id: "call-1",
      role: "recipient",
      state: "active",
      media_intent: "audio",
      ownership: "self",
    },
  })
  assert.equal(signaling.getState().call.state, "active")
  assert.equal(signaling.getState().call.ownership, "self")
  const afterActive = snapshots.length

  callChannel.handlers.sibling_tab_owns_call[0]({
    signaling_session_id: "call-session-1",
    call: {
      call_id: "call-1",
      role: "recipient",
      state: "active",
      media_intent: "audio",
      ownership: "elsewhere",
    },
  })
  assert.equal(signaling.getState().call.state, "active")
  assert.equal(signaling.getState().call.ownership, "elsewhere")
  assert.equal(snapshots.length, afterActive + 1)

  callChannel.handlers.sibling_tab_owns_call[0]({
    signaling_session_id: "call-session-1",
    call: {
      call_id: "call-1",
      role: "recipient",
      state: "active",
      media_intent: "audio",
      ownership: "elsewhere",
    },
  })
  assert.equal(snapshots.length, afterActive + 1)

  harness.channel.handlers.call_connecting[0]({
    signaling_session_id: "inbox-1",
    call: {
      call_id: "call-1",
      role: "recipient",
      state: "connecting",
      media_intent: "audio",
      ownership: "elsewhere",
    },
  })
  assert.equal(signaling.getState().call.state, "active")

  harness.channel.handlers.call_ended[0]({
    signaling_session_id: "inbox-1",
    call: {
      call_id: "call-1",
      role: "recipient",
      state: "terminal",
      terminal_outcome: "ended",
    },
  })
  assert.equal(signaling.getState().call, null)
  assert.equal(Object.hasOwn(signaling.getState().terminalCall, "ownership"), false)
})

test("the transport never invents, stores, or sends a tab identity", async () => {
  const events = []
  const receives = []
  const harness = fakeSocket(events, receives)
  const signaling = createCallSignaling({Socket: harness.Socket, csrfToken: "csrf"})
  signaling.connect()

  joinOk(receives, {
    signaling_session_id: "inbox-1",
    call: {
      call_id: "call-1",
      role: "recipient",
      state: "ringing",
      media_intent: "audio",
      ownership: "unclaimed",
    },
  })
  callJoinOk(receives, "call-1", {
    signaling_session_id: "call-session-1",
    call: {
      call_id: "call-1",
      role: "recipient",
      state: "ringing",
      media_intent: "audio",
      ownership: "unclaimed",
    },
  })

  assert.deepEqual(
    Object.keys(signaling.getState()).sort(),
    ["call", "callTopicStatus", "connectionStatus", "signalingSessionId"],
  )
  assert.equal(signaling.getState().callTopicStatus, "joined")

  const accepted = signaling.acceptCall({callId: "call-1", answerMode: "audio"})

  assert.deepEqual(events.filter(([name]) => name === "push"), [[
    "push",
    "accept_call",
    {
      signaling_session_id: "call-session-1",
      call_id: "call-1",
      answer_mode: "audio",
    },
    callTopic("call-1"),
  ]])

  commandReceive(receives, "ok", "accept_call")({
    signaling_session_id: "call-session-1",
    call: {call_id: "call-1", role: "recipient", state: "connecting", ownership: "self"},
  })
  const reply = await accepted
  assert.equal(reply.call.state, "connecting")

  const state = signaling.getState()
  assert.equal(Object.hasOwn(state, "connectionId"), false)
  assert.equal(Object.hasOwn(state, "tabId"), false)
})

test("accept and leave never queue before join or replay after reconnect", async () => {
  const events = []
  const receives = []
  const harness = fakeSocket(events, receives)
  const signaling = createCallSignaling({Socket: harness.Socket, csrfToken: "csrf"})
  signaling.connect()
  joinOk(receives, {
    signaling_session_id: "inbox-1",
    call: {call_id: "call-1", role: "recipient", state: "ringing", media_intent: "audio"},
  })
  assert.deepEqual(await signaling.acceptCall({callId: "call-1", answerMode: "audio"}), {
    ok: false,
    error: "unavailable",
  })
  assert.deepEqual(await signaling.acceptCall({callId: "call-1", answerMode: "video"}), {
    ok: false,
    error: "unavailable",
  })
  assert.deepEqual(await signaling.leaveCall({callId: "call-1"}), {ok: false, error: "unavailable"})
  assert.equal(events.filter(([name, event]) => name === "push" && ["accept_call", "leave_call"].includes(event)).length, 0)

  harness.socket._onClose()
  joinOk(receives, {
    signaling_session_id: "inbox-2",
    call: {call_id: "call-1", role: "recipient", state: "ringing", media_intent: "audio"},
  })
  assert.equal(events.filter(([name, event]) => name === "push" && ["accept_call", "leave_call"].includes(event)).length, 0)
})

function fakeSocket(events, receives) {
  let createdSocket = null
  const channels = new Map()

  class Socket {
    constructor(path, options) {
      events.push(["new", path, options])
      createdSocket = this
    }

    connect() {
      events.push(["connect"])
    }

    disconnect() {
      events.push(["disconnect"])
    }

    channel(topic, params) {
      events.push(["channel", topic, params])
      const createdChannel = {
        topic,
        handlers: {},
        _canPush: true,
        join() {
          events.push(["join", topic])
          const push = {
            receive(status, callback) {
              receives.push([status, callback, null, topic])
              return push
            },
          }
          return push
        },
        canPush() {
          return this._canPush !== false
        },
        push(event, payload) {
          events.push(["push", event, payload, topic])
          const push = {
            receive(status, callback) {
              receives.push([status, callback, event, topic])
              return push
            },
          }
          return push
        },
        on(event, callback) {
          events.push(["on", event, topic])
          this.handlers[event] = this.handlers[event] || []
          this.handlers[event].push(callback)
        },
        onError(callback) {
          this._onError = callback
        },
        onClose(callback) {
          this._onClose = callback
        },
        leave() {
          events.push(["leave", topic])
        },
      }
      channels.set(topic, createdChannel)
      return createdChannel
    }

    onError(callback) {
      this._onError = callback
    }

    onClose(callback) {
      this._onClose = callback
    }
  }

  return {
    Socket,
    get socket() {
      return createdSocket
    },
    get channel() {
      return channels.get(CALL_INBOX_TOPIC)
    },
    channelFor(topic) {
      return channels.get(topic)
    },
  }
}

function joinOk(receives, payload, topic = CALL_INBOX_TOPIC) {
  receives.find(([status, _callback, event, joinTopic]) => (
    status === "ok" && event == null && joinTopic === topic
  ))[1](payload)
}

function callJoinOk(receives, callId, payload) {
  const topic = callTopic(callId)
  ;[...receives].reverse().find(([status, _callback, event, joinTopic]) => (
    status === "ok" && event == null && joinTopic === topic
  ))[1](payload)
}

function startReceive(receives, status) {
  return [...receives].reverse().find(([name, _callback, event]) => name === status && event === "start_call")[1]
}

function commandReceive(receives, status, event) {
  return [...receives].reverse().find(([name, _callback, pushed]) => name === status && pushed === event)[1]
}

test("owner media commands use Call-topic identities and stale channel work cannot escape", async () => {
  const events = [], receives = []
  const harness = fakeSocket(events, receives)
  const signaling = createCallSignaling({Socket: harness.Socket})
  signaling.connect()
  const call = {call_id: "call-1", state: "connecting", ownership: "self"}
  joinOk(receives, {signaling_session_id: "inbox", call})
  callJoinOk(receives, "call-1", {signaling_session_id: "topic", call})
  const credentials = signaling.mediaCredentials({callId: "call-1"})
  assert.deepEqual(events.at(-1), ["push", "media_credentials", {call_id: "call-1", signaling_session_id: "topic"}, "call:call-1"])
  commandReceive(receives, "ok", "media_credentials")({call_id: "call-1", call_session_id: "media", signaling_session_id: "topic"})
  assert.equal((await credentials).call_session_id, "media")
  const offer = signaling.sendMedia("offer", {call_id: "call-1", call_session_id: "media", signaling_session_id: "topic", negotiation_id: "n", description: {type: "offer", sdp: "sdp"}})
  harness.channelFor("call:call-1")._onError()
  assert.equal((await offer).ok, false)
  assert.equal(signaling.getState().callTopicStatus, "failed")
})
