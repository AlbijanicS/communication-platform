import assert from "node:assert/strict"
import test from "node:test"

import {
  CUE_CHANNEL_NAME,
  CUE_ELECTION_WINDOW_MS,
  CUE_HEARTBEAT_MS,
  CUE_LEASE_MS,
  createCallCueCoordinator,
} from "./call_cue_coordinator.js"

const TIMING = {electionWindowMs: 100, heartbeatMs: 50, leaseMs: 200}

test("named timing constants keep the lease longer than the heartbeat", () => {
  assert.ok(CUE_ELECTION_WINDOW_MS > 0)
  assert.ok(CUE_HEARTBEAT_MS > 0)
  assert.ok(CUE_LEASE_MS > CUE_HEARTBEAT_MS)
  assert.ok(CUE_ELECTION_WINDOW_MS < CUE_LEASE_MS)
  assert.match(CUE_CHANNEL_NAME, /direct.?call/i)
  assert.doesNotMatch(CUE_CHANNEL_NAME, /call_inbox|call:/)
})

test("two tabs elect exactly one deterministic winner after the election window", () => {
  const hub = fakeHub()
  const tabA = createTab(hub, "aaa")
  const tabB = createTab(hub, "bbb")

  tabA.coordinator.contend({callId: "call-1", kind: "incoming"})
  tabB.coordinator.contend({callId: "call-1", kind: "incoming"})

  assert.deepEqual(tabA.events, [])
  assert.deepEqual(tabB.events, [])

  tabA.clock.advance(TIMING.electionWindowMs)
  tabB.clock.advance(TIMING.electionWindowMs)

  assert.deepEqual(tabA.events, [["start", "incoming", "call-1"]])
  assert.deepEqual(tabB.events, [])

  tabA.coordinator.dispose()
  tabB.coordinator.dispose()
})

test("tie-breaking is independent of message order and clock advance order", () => {
  const hub = fakeHub()
  const tabA = createTab(hub, "aaa")
  const tabB = createTab(hub, "bbb")

  tabB.coordinator.contend({callId: "call-1", kind: "outgoing"})
  tabA.coordinator.contend({callId: "call-1", kind: "outgoing"})

  tabB.clock.advance(TIMING.electionWindowMs)
  tabA.clock.advance(TIMING.electionWindowMs)

  assert.deepEqual(tabA.events, [["start", "outgoing", "call-1"]])
  assert.deepEqual(tabB.events, [])

  tabA.coordinator.dispose()
  tabB.coordinator.dispose()
})

test("contending the same call twice does not restart the election", () => {
  const hub = fakeHub()
  const tabA = createTab(hub, "aaa")
  const tabB = createTab(hub, "bbb")

  tabA.coordinator.contend({callId: "call-1", kind: "incoming"})
  tabB.coordinator.contend({callId: "call-1", kind: "incoming"})
  tabA.coordinator.contend({callId: "call-1", kind: "incoming"})
  tabB.coordinator.contend({callId: "call-1", kind: "incoming"})

  assert.equal(hub.channels.length, 2)
  assert.equal(tabA.clock.pending().length, 1)
  assert.equal(tabB.clock.pending().length, 1)

  tabA.clock.advance(TIMING.electionWindowMs)
  tabB.clock.advance(TIMING.electionWindowMs)
  tabA.clock.advance(TIMING.electionWindowMs * 2)

  assert.deepEqual(tabA.events, [["start", "incoming", "call-1"]])
  assert.deepEqual(tabB.events, [])

  tabA.coordinator.dispose()
  tabB.coordinator.dispose()
})

test("siblings stay silent while the winner renews its lease", () => {
  const hub = fakeHub()
  const tabA = createTab(hub, "aaa")
  const tabB = createTab(hub, "bbb")

  tabA.coordinator.contend({callId: "call-1", kind: "incoming"})
  tabB.coordinator.contend({callId: "call-1", kind: "incoming"})
  tabA.clock.advance(TIMING.electionWindowMs)
  tabB.clock.advance(TIMING.electionWindowMs)
  assert.deepEqual(tabA.events, [["start", "incoming", "call-1"]])

  for (let step = 0; step < 12; step += 1) {
    tabA.clock.advance(TIMING.heartbeatMs)
    tabB.clock.advance(TIMING.heartbeatMs)
  }

  assert.deepEqual(tabB.events, [])
  assert.deepEqual(tabA.events, [["start", "incoming", "call-1"]])

  tabA.coordinator.dispose()
  tabB.coordinator.dispose()
})

test("a sibling takes over after lease expiry and the lapsed winner stops", () => {
  const hub = fakeHub()
  const tabA = createTab(hub, "aaa", {heartbeatMs: 10_000})
  const tabB = createTab(hub, "bbb")

  tabA.coordinator.contend({callId: "call-1", kind: "incoming"})
  tabA.clock.advance(TIMING.electionWindowMs)
  assert.deepEqual(tabA.events, [["start", "incoming", "call-1"]])

  tabB.coordinator.contend({callId: "call-1", kind: "incoming"})
  assert.deepEqual(tabB.events, [])

  // Tab A is throttled: its clock advances but its heartbeat never fires.
  tabA.clock.advance(TIMING.leaseMs + TIMING.electionWindowMs)

  tabB.clock.advance(TIMING.leaseMs)
  assert.deepEqual(tabB.events, [])

  tabB.clock.advance(TIMING.electionWindowMs)
  assert.deepEqual(tabB.events, [["start", "incoming", "call-1"]])
  assert.deepEqual(tabA.events, [["start", "incoming", "call-1"], ["stop"]])

  tabA.coordinator.dispose()
  tabB.coordinator.dispose()
})

test("a withdrawn sibling does not re-elect after lease expiry", () => {
  const hub = fakeHub()
  const tabA = createTab(hub, "aaa")
  const tabB = createTab(hub, "bbb")

  tabA.coordinator.contend({callId: "call-1", kind: "incoming"})
  tabA.clock.advance(TIMING.electionWindowMs)
  tabB.coordinator.contend({callId: "call-1", kind: "incoming"})
  tabB.coordinator.withdraw()

  tabB.clock.advance(TIMING.leaseMs + TIMING.electionWindowMs)

  assert.deepEqual(tabB.events, [])
  assert.deepEqual(tabA.events, [["start", "incoming", "call-1"]])

  tabA.coordinator.dispose()
  tabB.coordinator.dispose()
})

test("a late contender respects the existing winner lease and re-claims", () => {
  const hub = fakeHub()
  const tabA = createTab(hub, "aaa")
  const tabB = createTab(hub, "bbb")

  tabA.coordinator.contend({callId: "call-1", kind: "incoming"})
  tabA.clock.advance(TIMING.electionWindowMs)
  assert.deepEqual(tabA.events, [["start", "incoming", "call-1"]])

  tabB.coordinator.contend({callId: "call-1", kind: "incoming"})
  tabB.clock.advance(TIMING.electionWindowMs)

  assert.deepEqual(tabB.events, [])
  assert.deepEqual(tabA.events, [["start", "incoming", "call-1"]])

  tabA.coordinator.dispose()
  tabB.coordinator.dispose()
})

test("withdrawal allows prompt takeover without a second audible winner", () => {
  const hub = fakeHub()
  const tabA = createTab(hub, "aaa")
  const tabB = createTab(hub, "bbb")

  tabA.coordinator.contend({callId: "call-1", kind: "incoming"})
  tabB.coordinator.contend({callId: "call-1", kind: "incoming"})
  tabA.clock.advance(TIMING.electionWindowMs)
  tabB.clock.advance(TIMING.electionWindowMs)
  assert.deepEqual(tabA.events, [["start", "incoming", "call-1"]])

  tabA.coordinator.withdraw()
  assert.deepEqual(tabA.events, [["start", "incoming", "call-1"], ["stop"]])

  tabB.clock.advance(TIMING.electionWindowMs)
  assert.deepEqual(tabB.events, [["start", "incoming", "call-1"]])

  tabA.coordinator.dispose()
  tabB.coordinator.dispose()
})

test("replacement withdraws the old election and releases the old Call", () => {
  const hub = fakeHub()
  const tabA = createTab(hub, "aaa")
  const tabB = createTab(hub, "bbb")

  tabA.coordinator.contend({callId: "call-1", kind: "incoming"})
  tabB.coordinator.contend({callId: "call-1", kind: "incoming"})
  tabA.clock.advance(TIMING.electionWindowMs)
  tabB.clock.advance(TIMING.electionWindowMs)

  tabA.coordinator.contend({callId: "call-2", kind: "outgoing"})
  assert.deepEqual(tabA.events, [["start", "incoming", "call-1"], ["stop"]])

  tabA.clock.advance(TIMING.electionWindowMs)
  assert.deepEqual(tabA.events, [
    ["start", "incoming", "call-1"],
    ["stop"],
    ["start", "outgoing", "call-2"],
  ])

  assert.deepEqual(tabB.events, [])

  tabA.coordinator.dispose()
  tabB.coordinator.dispose()
})

test("malformed or old-Call messages can never win or revive sound", () => {
  const hub = fakeHub()
  const tabA = createTab(hub, "aaa")
  tabA.coordinator.contend({callId: "call-1", kind: "incoming"})

  const rogue = {}
  hub.deliver(rogue, {type: "claim", callId: "call-1", kind: "incoming", contenderId: "aaa"})
  hub.deliver(rogue, {type: "claim", callId: "call-1", kind: "incoming"})
  hub.deliver(rogue, {type: "claim", callId: "call-2", kind: "incoming", contenderId: "zzz"})
  hub.deliver(rogue, {type: "claim", callId: "call-1", kind: "video", contenderId: "zzz"})
  hub.deliver(rogue, {type: "nonsense", callId: "call-1", contenderId: "zzz"})
  hub.deliver(rogue, null)
  hub.deliver(rogue, "claim")

  tabA.clock.advance(TIMING.electionWindowMs)
  assert.deepEqual(tabA.events, [["start", "incoming", "call-1"]])

  tabA.coordinator.dispose()
})

test("an elected tab yields to a smaller claim and keeps playing for a larger one", () => {
  const hub = fakeHub()
  const tabA = createTab(hub, "bbb")
  tabA.coordinator.contend({callId: "call-1", kind: "incoming"})
  tabA.clock.advance(TIMING.electionWindowMs)
  assert.deepEqual(tabA.events, [["start", "incoming", "call-1"]])

  hub.deliver({}, {type: "claim", callId: "call-1", kind: "incoming", contenderId: "zzz"})
  tabA.clock.advance(TIMING.heartbeatMs)
  assert.deepEqual(tabA.events, [["start", "incoming", "call-1"]])

  hub.deliver({}, {type: "claim", callId: "call-1", kind: "incoming", contenderId: "aab"})
  assert.deepEqual(tabA.events, [["start", "incoming", "call-1"], ["stop"]])

  tabA.clock.advance(TIMING.heartbeatMs)
  assert.deepEqual(tabA.events, [["start", "incoming", "call-1"], ["stop"]])

  tabA.coordinator.dispose()
})

test("dispose removes listeners, closes the channel, and clears every timer", () => {
  const hub = fakeHub()
  const tabA = createTab(hub, "aaa")
  tabA.coordinator.contend({callId: "call-1", kind: "incoming"})
  tabA.clock.advance(TIMING.electionWindowMs)

  const channel = hub.channels[0]
  assert.equal(channel.name, CUE_CHANNEL_NAME)
  assert.equal(channel.listeners.size, 1)

  tabA.coordinator.dispose()
  tabA.coordinator.dispose()

  assert.equal(channel.closed, true)
  assert.equal(channel.listeners.size, 0)
  assert.equal(tabA.clock.pending().length, 0)

  tabA.clock.advance(TIMING.leaseMs * 4)
  assert.deepEqual(tabA.events, [["start", "incoming", "call-1"], ["stop"]])

  tabA.coordinator.contend({callId: "call-2", kind: "incoming"})
  tabA.clock.advance(TIMING.leaseMs * 4)
  assert.equal(hub.channels.length, 1)
})

test("missing BroadcastChannel degrades to silent cues", () => {
  const clock = manualClock()
  const events = []
  const coordinator = createCallCueCoordinator({
    BroadcastChannel: null,
    now: clock.now,
    scheduleTimeout: clock.scheduleTimeout,
    cancelTimeout: clock.cancelTimeout,
    scheduleInterval: clock.scheduleInterval,
    cancelInterval: clock.cancelInterval,
    createContenderId: () => "aaa",
    onElected: cue => events.push(["start", cue.kind, cue.callId]),
    onRevoked: () => events.push(["stop"]),
    ...TIMING,
  })

  coordinator.contend({callId: "call-1", kind: "incoming"})
  clock.advance(TIMING.leaseMs * 4)
  assert.deepEqual(events, [])

  coordinator.withdraw()
  coordinator.dispose()
  assert.equal(clock.pending().length, 0)
})

test("a failing BroadcastChannel constructor degrades to silent cues", () => {
  const hub = fakeHub()
  hub.constructError = true
  const tabA = createTab(hub, "aaa")

  tabA.coordinator.contend({callId: "call-1", kind: "incoming"})
  tabA.clock.advance(TIMING.leaseMs * 4)

  assert.deepEqual(tabA.events, [])
  tabA.coordinator.dispose()
})

test("a reordered higher-ID claim cannot defeat the deterministic winner", () => {
  const hub = fakeHub()
  const tabA = createTab(hub, "aaa")
  const tabB = createTab(hub, "bbb", {silenced: true})

  // Tab B announces before Tab A opens its channel, so neither contender ever
  // learns the other; only the claim order reaches them.
  tabB.coordinator.contend({callId: "call-1", kind: "incoming"})
  tabA.coordinator.contend({callId: "call-1", kind: "incoming"})

  tabB.clock.advance(TIMING.electionWindowMs)
  assert.deepEqual(tabB.events, [["start", "incoming", "call-1"]])

  // Tab A is still inside its election window when the larger claim lands, so
  // it must finish its own election instead of accepting the first claim.
  for (const channel of hub.channels) channel.silenced = false
  tabA.clock.advance(TIMING.electionWindowMs)

  assert.deepEqual(tabA.events, [["start", "incoming", "call-1"]])
  assert.deepEqual(tabB.events, [["start", "incoming", "call-1"], ["stop"]])

  tabA.coordinator.dispose()
  tabB.coordinator.dispose()
})

test("a reordered higher-ID renewal cannot defeat the deterministic winner", () => {
  const hub = fakeHub()
  const tabB = createTab(hub, "bbb")
  const tabA = createTab(hub, "aaa", {held: true})

  // Tab B starts first, before Tab A is listening, and Tab A's candidacy is
  // delayed on the way to Tab B.
  tabB.coordinator.contend({callId: "call-1", kind: "incoming"})
  tabA.coordinator.contend({callId: "call-1", kind: "incoming"})

  // Tab B's window ends first: it elects and claims without ever hearing
  // Tab A, whose election window is still pending.
  tabB.clock.advance(TIMING.electionWindowMs)
  assert.deepEqual(tabB.events, [["start", "incoming", "call-1"]])

  // Tab A's candidacy finally lands on Tab B, which answers with a renewal
  // that reaches Tab A before its window ends.
  hub.releaseHeld()

  // The renewal cannot cancel Tab A's election, so the deterministic winner
  // claims and Tab B yields.
  tabA.clock.advance(TIMING.electionWindowMs)
  assert.deepEqual(tabA.events, [["start", "incoming", "call-1"]])
  assert.deepEqual(tabB.events, [["start", "incoming", "call-1"], ["stop"]])

  tabA.coordinator.dispose()
  tabB.coordinator.dispose()
})

test("a late smaller contender still respects the elected larger incumbent", () => {
  const hub = fakeHub()
  const tabB = createTab(hub, "bbb")
  const tabA = createTab(hub, "aaa")

  tabB.coordinator.contend({callId: "call-1", kind: "incoming"})
  tabB.clock.advance(TIMING.electionWindowMs)
  assert.deepEqual(tabB.events, [["start", "incoming", "call-1"]])

  // Tab A arrives after the election, so it only ever hears renewals — never
  // Tab B's candidacy or its fresh claim.
  tabA.coordinator.contend({callId: "call-1", kind: "incoming"})
  tabA.clock.advance(TIMING.electionWindowMs)

  assert.deepEqual(tabA.events, [])
  assert.deepEqual(tabB.events, [["start", "incoming", "call-1"]])

  tabA.coordinator.dispose()
  tabB.coordinator.dispose()
})

test("one-way message loss cannot create a lasting second winner", () => {
  const hub = fakeHub()
  const tabA = createTab(hub, "aaa")
  const tabB = createTab(hub, "bbb", {silenced: true})

  tabB.coordinator.contend({callId: "call-1", kind: "incoming"})
  tabA.coordinator.contend({callId: "call-1", kind: "incoming"})

  tabA.clock.advance(TIMING.electionWindowMs)
  tabB.clock.advance(TIMING.electionWindowMs)
  assert.deepEqual(tabA.events, [["start", "incoming", "call-1"]])
  assert.deepEqual(tabB.events, [["start", "incoming", "call-1"]])

  // Delivery recovers: the winner's next heartbeat reaches the deaf tab,
  // which deterministically yields to the smaller contender ID.
  for (const channel of hub.channels) channel.silenced = false
  tabA.clock.advance(TIMING.heartbeatMs)

  assert.deepEqual(tabB.events, [["start", "incoming", "call-1"], ["stop"]])
  assert.deepEqual(tabA.events, [["start", "incoming", "call-1"]])

  tabA.coordinator.dispose()
  tabB.coordinator.dispose()
})

test("malformed contend arguments fail silent", () => {
  const hub = fakeHub()
  const tabA = createTab(hub, "aaa")

  tabA.coordinator.contend({callId: "", kind: "incoming"})
  tabA.coordinator.contend({callId: "call-1", kind: "video"})
  tabA.coordinator.contend({})
  tabA.coordinator.contend()
  tabA.clock.advance(TIMING.leaseMs * 4)

  assert.deepEqual(tabA.events, [])
  assert.equal(hub.channels.length, 0)
  tabA.coordinator.dispose()
})

function createTab(hub, id, overrides = {}) {
  const clock = manualClock()
  const events = []
  const {silenced, held, ...timing} = overrides
  let Channel = hub.BroadcastChannel
  if (silenced) Channel = silencedChannel(Channel)
  if (held) Channel = heldChannel(Channel)
  const coordinator = createCallCueCoordinator({
    BroadcastChannel: Channel,
    now: clock.now,
    scheduleTimeout: clock.scheduleTimeout,
    cancelTimeout: clock.cancelTimeout,
    scheduleInterval: clock.scheduleInterval,
    cancelInterval: clock.cancelInterval,
    createContenderId: () => id,
    onElected: cue => events.push(["start", cue.kind, cue.callId]),
    onRevoked: () => events.push(["stop"]),
    ...TIMING,
    ...timing,
  })

  return {id, clock, events, coordinator}
}

function silencedChannel(Base) {
  return class extends Base {
    constructor(name) {
      super(name)
      this.silenced = true
    }
  }
}

function heldChannel(Base) {
  return class extends Base {
    constructor(name) {
      super(name)
      this.held = true
    }
  }
}

function fakeHub() {
  const channels = []

  class FakeBroadcastChannel {
    constructor(name) {
      if (hub.constructError) throw new Error("channel unavailable")
      this.name = name
      this.closed = false
      this.silenced = false
      this.held = false
      this.heldMessages = []
      this.listeners = new Set()
      this.posted = []
      channels.push(this)
    }

    addEventListener(type, callback) {
      if (type === "message") this.listeners.add(callback)
    }

    removeEventListener(type, callback) {
      if (type === "message") this.listeners.delete(callback)
    }

    postMessage(message) {
      this.posted.push(message)
      if (this.held) {
        this.heldMessages.push(message)
        return
      }
      hub.deliver(this, message)
    }

    releaseHeld() {
      if (!this.held) return
      this.held = false
      const released = this.heldMessages
      this.heldMessages = []
      for (const message of released) hub.deliver(this, message)
    }

    close() {
      this.closed = true
      this.listeners.clear()
    }
  }

  const hub = {
    BroadcastChannel: FakeBroadcastChannel,
    channels,
    constructError: false,
    deliver(from, message) {
      for (const channel of channels) {
        if (channel === from || channel.closed || channel.silenced) continue
        for (const listener of channel.listeners) listener({data: message})
      }
    },
    releaseHeld() {
      for (const channel of channels) channel.releaseHeld()
    },
  }

  return hub
}

function manualClock() {
  let current = 0
  const timers = []

  function schedule(callback, ms, interval) {
    const timer = {callback, at: current + ms, interval, cancelled: false}
    timers.push(timer)
    return timer
  }

  function runDue() {
    let guard = 0
    for (;;) {
      const due = timers
        .filter(timer => !timer.cancelled && timer.at <= current)
        .sort((left, right) => left.at - right.at)
      if (due.length === 0 || guard++ > 500) return

      const timer = due[0]
      if (timer.interval) {
        timer.at = current + timer.interval
      } else {
        timer.cancelled = true
      }
      timer.callback()
    }
  }

  return {
    now: () => current,
    scheduleTimeout: (callback, ms) => schedule(callback, ms, null),
    cancelTimeout: timer => {
      if (timer) timer.cancelled = true
    },
    scheduleInterval: (callback, ms) => schedule(callback, ms, ms),
    cancelInterval: timer => {
      if (timer) timer.cancelled = true
    },
    advance(ms) {
      current += ms
      runDue()
    },
    pending() {
      return timers.filter(timer => !timer.cancelled)
    },
  }
}
