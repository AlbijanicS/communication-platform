export function createVoiceCuePlayer({AudioContext = globalThis.AudioContext || globalThis.webkitAudioContext, setTimeoutFn = globalThis.setTimeout} = {}) {
  return cue => {
    if (!AudioContext || !["join", "leave"].includes(cue)) return Promise.resolve()

    try {
      const context = new AudioContext()
      const oscillator = context.createOscillator()
      const gain = context.createGain()
      const now = context.currentTime
      const frequency = cue === "join" ? 880 : 660

      oscillator.frequency.setValueAtTime(frequency, now)
      gain.gain.setValueAtTime(0.05, now)
      gain.gain.exponentialRampToValueAtTime(0.001, now + 0.12)
      oscillator.connect(gain)
      gain.connect(context.destination)
      oscillator.start(now)
      oscillator.stop(now + 0.12)
      oscillator.addEventListener?.("ended", () => context.close?.())
      setTimeoutFn(() => context.close?.(), 500)

      return context.resume?.().catch?.(() => {}) || Promise.resolve()
    } catch (_) {
      return Promise.resolve()
    }
  }
}

export const playVoiceCue = createVoiceCuePlayer()
