import assert from "node:assert/strict"
import test from "node:test"

import {createCallCuePlayer} from "./call_cues.js"

test("incoming ringtone is a repeating two-tone pattern with a quiet gain", async () => {
  const audio = fakeAudio()
  const timers = manualTimers()
  const player = createCallCuePlayer({
    AudioContext: audio.AudioContext,
    scheduleTimer: timers.scheduleTimer,
    cancelTimer: timers.cancelTimer,
  })

  player.start("incoming", "call-1")
  await microtask()

  assert.equal(audio.contexts.length, 1)
  const context = audio.contexts[0]
  assert.deepEqual(context.oscillators.map(oscillator => oscillator.frequency.value), [660, 520])
  assert.ok(context.gains.every(gain => gain.gain.startValue <= 0.05))
  assert.deepEqual(context.oscillators.map(oscillator => oscillator.started), [1, 1])
  assert.deepEqual(context.oscillators.map(oscillator => oscillator.connectedTo), context.gains)
  assert.ok(context.gains.every(gain => gain.connectedTo === context.destination))

  assert.equal(timers.active().length, 1)
  assert.equal(timers.active()[0].ms, 1400)

  timers.fire(timers.active()[0])
  assert.equal(context.oscillators.length, 4)
  assert.equal(timers.active().length, 1)

  player.dispose()
})

test("outgoing ringback is a distinct restrained single-tone pattern", async () => {
  const audio = fakeAudio()
  const timers = manualTimers()
  const player = createCallCuePlayer({
    AudioContext: audio.AudioContext,
    scheduleTimer: timers.scheduleTimer,
    cancelTimer: timers.cancelTimer,
  })

  player.start("outgoing", "call-1")
  await microtask()

  const context = audio.contexts[0]
  assert.deepEqual(context.oscillators.map(oscillator => oscillator.frequency.value), [440])
  assert.ok(context.gains.every(gain => gain.gain.startValue <= 0.05))
  assert.equal(timers.active()[0].ms, 2000)

  player.dispose()
})

test("starting the same cue twice is idempotent and replaces a different cue", async () => {
  const audio = fakeAudio()
  const timers = manualTimers()
  const player = createCallCuePlayer({
    AudioContext: audio.AudioContext,
    scheduleTimer: timers.scheduleTimer,
    cancelTimer: timers.cancelTimer,
  })

  player.start("incoming", "call-1")
  await microtask()
  player.start("incoming", "call-1")
  await microtask()

  assert.equal(audio.contexts.length, 1)
  assert.equal(audio.contexts[0].oscillators.length, 2)
  assert.equal(timers.active().length, 1)

  player.start("outgoing", "call-2")
  await microtask()

  assert.equal(audio.contexts.length, 2)
  assert.equal(audio.contexts[0].closed, 1)
  assert.ok(audio.contexts[0].oscillators.every(oscillator => oscillator.stopped >= 1))
  assert.ok(audio.contexts[0].oscillators.every(oscillator => oscillator.disconnected === 1))
  assert.ok(audio.contexts[0].gains.every(gain => gain.disconnected === 1))
  assert.equal(audio.events.indexOf("close-1") < audio.events.indexOf("open-2"), true)

  player.start("outgoing", "call-2")
  await microtask()
  assert.equal(audio.contexts.length, 2)

  player.dispose()
})

test("stop is safe before start, repeatedly, and closes every resource once", async () => {
  const audio = fakeAudio()
  const timers = manualTimers()
  const player = createCallCuePlayer({
    AudioContext: audio.AudioContext,
    scheduleTimer: timers.scheduleTimer,
    cancelTimer: timers.cancelTimer,
  })

  player.stop()
  player.stop()
  assert.equal(audio.contexts.length, 0)

  player.start("incoming", "call-1")
  await microtask()
  const context = audio.contexts[0]
  const timer = timers.active()[0]

  player.stop()
  player.stop()

  assert.equal(timer.cancelled, true)
  assert.equal(timers.active().length, 0)
  assert.equal(context.closed, 1)
  assert.ok(context.oscillators.every(oscillator => oscillator.stopped >= 1))
  assert.ok(context.oscillators.every(oscillator => oscillator.disconnected === 1))
  assert.ok(context.gains.every(gain => gain.disconnected === 1))

  player.start("incoming", "call-2")
  await microtask()
  assert.equal(audio.contexts.length, 2)
  player.dispose()
})

test("stale pattern callbacks cannot revive sound after stop or replacement", async () => {
  const audio = fakeAudio()
  const timers = manualTimers()
  const player = createCallCuePlayer({
    AudioContext: audio.AudioContext,
    scheduleTimer: timers.scheduleTimer,
    cancelTimer: timers.cancelTimer,
  })

  player.start("incoming", "call-1")
  await microtask()
  const stale = timers.active()[0]
  player.stop()

  timers.fire(stale)
  assert.equal(audio.contexts.length, 1)
  assert.equal(audio.contexts[0].oscillators.length, 2)
  assert.equal(timers.active().length, 0)

  player.start("outgoing", "call-2")
  await microtask()
  const staleReplacement = timers.active()[0]
  player.start("incoming", "call-3")
  await microtask()

  timers.fire(staleReplacement)
  assert.equal(audio.contexts.length, 3)
  assert.equal(audio.contexts[2].oscillators.length, 2)
  player.dispose()
})

test("dispose stops resources permanently and later starts stay silent", async () => {
  const audio = fakeAudio()
  const timers = manualTimers()
  const player = createCallCuePlayer({
    AudioContext: audio.AudioContext,
    scheduleTimer: timers.scheduleTimer,
    cancelTimer: timers.cancelTimer,
  })

  player.start("incoming", "call-1")
  await microtask()
  const stale = timers.active()[0]

  player.dispose()
  player.dispose()

  assert.equal(audio.contexts[0].closed, 1)
  assert.equal(timers.active().length, 0)

  timers.fire(stale)
  player.start("incoming", "call-2")
  await microtask()

  assert.equal(audio.contexts.length, 1)
  assert.equal(timers.active().length, 0)
})

test("missing Web Audio, constructor failure, and rejected resume are nonfatal", async () => {
  const silent = createCallCuePlayer({AudioContext: undefined})
  silent.start("incoming", "call-1")
  silent.stop()
  silent.dispose()

  const constructFailure = fakeAudio({constructError: true})
  const constructTimers = manualTimers()
  const constructPlayer = createCallCuePlayer({
    AudioContext: constructFailure.AudioContext,
    scheduleTimer: constructTimers.scheduleTimer,
    cancelTimer: constructTimers.cancelTimer,
  })
  constructPlayer.start("incoming", "call-1")
  await microtask()
  assert.equal(constructTimers.active().length, 0)
  constructPlayer.stop()
  constructPlayer.dispose()

  const blocked = fakeAudio({resumeError: true})
  const blockedTimers = manualTimers()
  const blockedPlayer = createCallCuePlayer({
    AudioContext: blocked.AudioContext,
    scheduleTimer: blockedTimers.scheduleTimer,
    cancelTimer: blockedTimers.cancelTimer,
  })
  blockedPlayer.start("incoming", "call-1")
  await microtask()
  assert.equal(blocked.contexts[0].oscillators.length, 0)
  assert.equal(blockedTimers.active().length, 0)
  blockedPlayer.stop()
  blockedPlayer.dispose()
})

test("an oscillator failure stays silent without spinning", async () => {
  const audio = fakeAudio({oscillatorError: true})
  const timers = manualTimers()
  const player = createCallCuePlayer({
    AudioContext: audio.AudioContext,
    scheduleTimer: timers.scheduleTimer,
    cancelTimer: timers.cancelTimer,
  })

  player.start("incoming", "call-1")
  await microtask()
  assert.equal(timers.active().length, 0)
  player.stop()
  player.dispose()
})

test("malformed start arguments fail silent", async () => {
  const audio = fakeAudio()
  const timers = manualTimers()
  const player = createCallCuePlayer({
    AudioContext: audio.AudioContext,
    scheduleTimer: timers.scheduleTimer,
    cancelTimer: timers.cancelTimer,
  })

  player.start("sideways", "call-1")
  player.start("incoming", "")
  player.start("incoming", null)
  player.start(null, "call-1")
  await microtask()

  assert.equal(audio.contexts.length, 0)
  player.dispose()
})

test("a rejected close is nonfatal and does not revive sound", async () => {
  const audio = fakeAudio({closeError: true})
  const timers = manualTimers()
  const player = createCallCuePlayer({
    AudioContext: audio.AudioContext,
    scheduleTimer: timers.scheduleTimer,
    cancelTimer: timers.cancelTimer,
  })

  player.start("incoming", "call-1")
  await microtask()
  const context = audio.contexts[0]

  player.stop()
  player.stop()
  player.dispose()
  player.start("incoming", "call-2")
  await microtask()

  assert.equal(audio.contexts.length, 1)
  assert.ok(context.oscillators.every(oscillator => oscillator.stopped >= 1))
  assert.equal(timers.active().length, 0)
})

test("a pattern failure closes the graph and context without a later stop", async () => {
  const oscillatorFailure = fakeAudio({oscillatorError: true})
  const oscillatorTimers = manualTimers()
  const oscillatorPlayer = createCallCuePlayer({
    AudioContext: oscillatorFailure.AudioContext,
    scheduleTimer: oscillatorTimers.scheduleTimer,
    cancelTimer: oscillatorTimers.cancelTimer,
  })

  oscillatorPlayer.start("incoming", "call-1")
  await microtask()

  assert.equal(oscillatorFailure.contexts[0].closed, 1)
  oscillatorPlayer.dispose()

  const startFailure = fakeAudio({startError: true})
  const startTimers = manualTimers()
  const startPlayer = createCallCuePlayer({
    AudioContext: startFailure.AudioContext,
    scheduleTimer: startTimers.scheduleTimer,
    cancelTimer: startTimers.cancelTimer,
  })

  startPlayer.start("incoming", "call-1")
  await microtask()

  const context = startFailure.contexts[0]
  assert.equal(context.closed, 1)
  assert.equal(startTimers.active().length, 0)
  assert.ok(context.oscillators.every(oscillator => oscillator.disconnected >= 1))
  assert.ok(context.gains.every(gain => gain.disconnected >= 1))
  startPlayer.dispose()
})

test("a gain failure stops the oscillator that was already created", async () => {
  const audio = fakeAudio({gainError: true})
  const timers = manualTimers()
  const player = createCallCuePlayer({
    AudioContext: audio.AudioContext,
    scheduleTimer: timers.scheduleTimer,
    cancelTimer: timers.cancelTimer,
  })

  player.start("incoming", "call-1")
  await microtask()

  const context = audio.contexts[0]
  assert.equal(context.oscillators.length, 1)
  assert.equal(context.oscillators[0].stopped, 1)
  assert.equal(context.oscillators[0].disconnected, 1)
  assert.equal(context.closed, 1)
  assert.equal(timers.active().length, 0)
  player.dispose()
})

test("a scheduler failure closes the graph and context without a later stop", async () => {
  const audio = fakeAudio()
  const throwingTimers = {
    scheduleTimer() {
      throw new Error("no timers")
    },
    cancelTimer() {},
  }
  const player = createCallCuePlayer({
    AudioContext: audio.AudioContext,
    scheduleTimer: throwingTimers.scheduleTimer,
    cancelTimer: throwingTimers.cancelTimer,
  })

  player.start("incoming", "call-1")
  await microtask()

  const context = audio.contexts[0]
  assert.equal(context.closed, 1)
  assert.ok(context.oscillators.every(oscillator => oscillator.disconnected >= 1))
  assert.ok(context.gains.every(gain => gain.disconnected >= 1))
  player.dispose()
})

function fakeAudio(options = {}) {
  const events = []
  const contexts = []

  class FakeAudioContext {
    constructor() {
      if (options.constructError) throw new Error("audio unavailable")
      this.currentTime = 0
      this.state = "suspended"
      this.destination = {name: "destination"}
      this.closed = 0
      this.oscillators = []
      this.gains = []
      contexts.push(this)
      events.push(`open-${contexts.length}`)
    }

    createOscillator() {
      if (options.oscillatorError) throw new Error("oscillator unavailable")
      const oscillator = {
        frequency: {
          value: null,
          setValueAtTime(value) {
            oscillator.frequency.value = value
          },
        },
        started: 0,
        stopped: 0,
        disconnected: 0,
        connectedTo: null,
        listeners: {},
        connect(node) {
          oscillator.connectedTo = node
        },
        disconnect() {
          oscillator.disconnected += 1
        },
        start() {
          oscillator.started += 1
          if (options.startError) throw new Error("start unavailable")
        },
        stop() {
          oscillator.stopped += 1
        },
        addEventListener(type, callback) {
          oscillator.listeners[type] = oscillator.listeners[type] || []
          oscillator.listeners[type].push(callback)
        },
      }
      this.oscillators.push(oscillator)
      return oscillator
    }

    createGain() {
      if (options.gainError) throw new Error("gain unavailable")
      const gain = {
        gain: {
          startValue: null,
          endValue: null,
          setValueAtTime(value) {
            gain.gain.startValue = value
          },
          exponentialRampToValueAtTime(value) {
            gain.gain.endValue = value
          },
        },
        disconnected: 0,
        connectedTo: null,
        connect(node) {
          gain.connectedTo = node
        },
        disconnect() {
          gain.disconnected += 1
        },
      }
      this.gains.push(gain)
      return gain
    }

    resume() {
      if (options.resumeError) return Promise.reject(new Error("blocked"))
      return Promise.resolve()
    }

    close() {
      if (options.closeError) return Promise.reject(new Error("close failed"))
      this.closed += 1
      events.push(`close-${contexts.length}`)
      return Promise.resolve()
    }
  }

  return {AudioContext: FakeAudioContext, contexts, events}
}

function manualTimers() {
  const scheduled = []
  return {
    scheduled,
    scheduleTimer(callback, ms) {
      const timer = {callback, ms, cancelled: false, fired: false}
      scheduled.push(timer)
      return timer
    },
    cancelTimer(timer) {
      if (timer) timer.cancelled = true
    },
    fire(timer) {
      timer.fired = true
      timer.callback()
    },
    active() {
      return scheduled.filter(timer => !timer.cancelled && !timer.fired)
    },
  }
}

function microtask() {
  return Promise.resolve()
}
