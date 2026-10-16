import {test} from "node:test"
import assert from "node:assert/strict"
import {compareEdges, compareRecovery, compareDirections} from "./support/video_alignment.mjs"

function fixture(offset = 0) {
  return {audio: Array.from({length: 23}, (_, i) => ({parity: i % 2,
    low: i * 1000 - 4, high: i * 1000 + 4, midpoint: i * 1000})),
  video: Array.from({length: 23}, (_, i) => ({parity: i % 2,
    low: i * 1000 + offset - 20, high: i * 1000 + offset + 20, midpoint: i * 1000 + offset}))}
}

test("calibrated coincident edges pass their declared observation intervals", () => {
  const result = compareEdges(fixture(), 42)
  assert.equal(result.failures, 0)
  assert.equal(result.pairs.length, 20)
})

test("a known 250ms video offset fails every edge without expanding the rule", () => {
  const result = compareEdges(fixture(250), 42)
  assert.equal(result.failures, 20)
  assert.equal(result.p95AbsoluteMs, 250)
  assert.equal(result.maxAbsoluteMs, 250)
})

test("insufficient changing presentation cannot pass alignment", () => {
  const sample = fixture(); sample.video = sample.video.slice(0, 10)
  assert.throws(() => compareEdges(sample, 42))
})

test("calibration is explicit and cannot hide the shifted control", () => {
  const baseline = {lowMs: -30, highMs: 30}
  assert.equal(compareEdges(fixture(-30), 42, baseline).failures, 0)
  assert.equal(compareEdges(fixture(250), 42, baseline).failures, 20)
  assert.equal(compareEdges(fixture(-250), 42, baseline).failures, 20)
})

test("missing opposite-polarity audio cannot be paired as aligned presentation", () => {
  const sample = fixture(); sample.audio = sample.audio.map(a => ({...a, parity: 0}))
  assert.throws(() => compareEdges(sample, 42))
})

test("a prior camera generation cannot pass a returned alignment measurement", () => {
  const sample = fixture()
  sample.video = sample.video.map(v => ({...v, generation: 1}))
  assert.throws(() => compareRecovery(sample, 42, {lowMs: -30, highMs: 30}))
  sample.video = sample.video.map(v => ({...v, generation: 2}))
  assert.equal(compareRecovery(sample, 42, {lowMs: -30, highMs: 30}).failures, 0)
})

test("opposite direction uses its actual source calibration, not the receiver's camera", () => {
  const results = compareDirections([fixture(150), fixture(-150)], [42, 42],
    [{lowMs: -170, highMs: -130}, {lowMs: 130, highMs: 170}])
  assert.deepEqual(results.map(r => r.failures), [0, 0])
})
