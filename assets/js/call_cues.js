export const CALL_CUE_PATTERNS = Object.freeze({
  incoming: Object.freeze({
    cycleMs: 1400,
    tones: Object.freeze([
      Object.freeze({frequency: 660, offsetMs: 0, durationMs: 170}),
      Object.freeze({frequency: 520, offsetMs: 240, durationMs: 170}),
    ]),
  }),
  outgoing: Object.freeze({
    cycleMs: 2000,
    tones: Object.freeze([Object.freeze({frequency: 440, offsetMs: 0, durationMs: 480})]),
  }),
})

const CUE_GAIN = 0.045
const CUE_SILENCE = 0.0001

export function createCallCuePlayer({
  AudioContext = globalThis.AudioContext || globalThis.webkitAudioContext,
  scheduleTimer = (callback, delay) => setTimeout(callback, delay),
  cancelTimer = clearTimeout,
} = {}) {
  let disposed = false
  let generation = 0
  let active = null
  let contextRef = null
  let patternTimer = null
  const nodes = new Set()

  function start(kind, callId) {
    if (disposed) return
    if (!CALL_CUE_PATTERNS[kind]) return
    if (typeof callId !== "string" || callId === "") return
    if (active && active.kind === kind && active.callId === callId) return

    teardown()
    active = {kind, callId}
    generation += 1
    const gen = generation

    const context = createContext()
    if (!context) return
    contextRef = context

    let resumed
    try {
      resumed = context.resume ? context.resume() : null
    } catch (_) {
      teardown()
      return
    }

    Promise.resolve(resumed).then(
      () => {
        if (isCurrent(gen)) playPattern(gen)
      },
      () => {
        if (isCurrent(gen)) teardown()
      },
    )
  }

  function stop() {
    teardown()
  }

  function dispose() {
    if (disposed) return
    disposed = true
    teardown()
  }

  function playPattern(gen) {
    if (!isCurrent(gen)) return
    const context = contextRef
    if (!context) return
    const pattern = CALL_CUE_PATTERNS[active.kind]

    try {
      const now = context.currentTime

      for (const tone of pattern.tones) {
        const oscillator = context.createOscillator()
        nodes.add(oscillator)
        const gain = context.createGain()
        nodes.add(gain)

        const startAt = now + tone.offsetMs / 1000
        const endAt = startAt + tone.durationMs / 1000

        oscillator.type = "sine"
        oscillator.frequency.setValueAtTime(tone.frequency, startAt)
        gain.gain.setValueAtTime(CUE_GAIN, startAt)
        gain.gain.exponentialRampToValueAtTime(CUE_SILENCE, endAt)
        oscillator.connect(gain)
        gain.connect(context.destination)
        oscillator.start(startAt)
        oscillator.stop(endAt)

        oscillator.addEventListener?.("ended", () => {
          nodes.delete(oscillator)
          nodes.delete(gain)
          disconnect(oscillator)
          disconnect(gain)
        })
      }
    } catch (_) {
      teardown()
      return
    }

    schedulePattern(gen, pattern.cycleMs)
  }

  function schedulePattern(gen, delay) {
    cancelPatternTimer()
    try {
      patternTimer = scheduleTimer(() => {
        patternTimer = null
        if (isCurrent(gen)) playPattern(gen)
      }, delay)
    } catch (_) {
      patternTimer = null
      teardown()
    }
  }

  function teardown() {
    generation += 1
    active = null
    cancelPatternTimer()
    stopNodes()
    closeContext()
  }

  function isCurrent(gen) {
    return !disposed && generation === gen && active !== null
  }

  function createContext() {
    if (!AudioContext) return null
    try {
      return new AudioContext()
    } catch (_) {
      return null
    }
  }

  function cancelPatternTimer() {
    if (patternTimer == null) return
    const timer = patternTimer
    patternTimer = null
    try {
      cancelTimer(timer)
    } catch (_) {}
  }

  function stopNodes() {
    for (const node of nodes) {
      try {
        node.stop?.()
      } catch (_) {}
      disconnect(node)
    }
    nodes.clear()
  }

  function disconnect(node) {
    try {
      node.disconnect?.()
    } catch (_) {}
  }

  function closeContext() {
    const context = contextRef
    contextRef = null
    if (!context) return
    try {
      Promise.resolve(context.close?.()).catch(() => {})
    } catch (_) {}
  }

  return {start, stop, dispose}
}
