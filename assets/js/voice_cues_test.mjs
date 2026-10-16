import assert from "node:assert/strict"
import test from "node:test"

import {createVoiceCuePlayer} from "./voice_cues.js"

test("plays short distinct browser-local join and leave cues", async () => {
  const oscillators = []
  const context = {
    close() {},
    createGain: () => ({connect() {}, gain: {exponentialRampToValueAtTime() {}, setValueAtTime() {}}}),
    createOscillator: () => {
      const oscillator = {addEventListener() {}, connect() {}, frequency: {setValueAtTime(value) { oscillator.frequencyValue = value }}, start() {}, stop() {}}
      oscillators.push(oscillator)
      return oscillator
    },
    currentTime: 0,
    destination: {},
    resume: () => Promise.resolve(),
  }
  const play = createVoiceCuePlayer({AudioContext: class { constructor() { return context } }, setTimeoutFn() {}})

  await play("join")
  await play("leave")

  assert.deepEqual(oscillators.map(oscillator => oscillator.frequencyValue), [880, 660])
})

test("silently tolerates browser playback restrictions", async () => {
  const play = createVoiceCuePlayer({
    AudioContext: class {
      constructor() {
        this.currentTime = 0
        this.destination = {}
      }
      createGain() { return {connect() {}, gain: {exponentialRampToValueAtTime() {}, setValueAtTime() {}}} }
      createOscillator() { return {addEventListener() {}, connect() {}, frequency: {setValueAtTime() {}}, start() {}, stop() {}} }
      resume() { return Promise.reject(new Error("blocked")) }
    },
    setTimeoutFn() {},
  })

  await assert.doesNotReject(play("join"))
})
