import assert from "node:assert/strict"

export function compareEdges(sample, sourceDrawGapMs, baseline = {lowMs: 0, highMs: 0}) {
  assert.ok(Number.isFinite(sourceDrawGapMs) && sourceDrawGapMs >= 0)
  assert.ok(sample.audio.length >= 23 && sample.video.length >= 23)
  const used = new Set()
  const pairs = sample.video.slice(1, 21).map(v => {
    const a = sample.audio.filter(a => a.parity === v.parity)
      .sort((a, b) => Math.abs(a.midpoint - v.midpoint) - Math.abs(b.midpoint - v.midpoint))[0]
    assert.ok(a && !used.has(a), "distinct same-polarity edges required")
    used.add(a)
    return {offsetMs: v.midpoint - a.midpoint,
      lowMs: v.low - sourceDrawGapMs - a.high,
      highMs: v.high - a.low}
  })
  assert.equal(pairs.length, 20)
  const magnitudes = pairs.map(p => Math.abs(p.offsetMs)).sort((a, b) => a - b)
  return {pairs, sourceDrawGapMs, baseline, p95AbsoluteMs: magnitudes[18], maxAbsoluteMs: magnitudes[19],
    failures: pairs.filter(p => p.lowMs > baseline.highMs || p.highMs < baseline.lowMs).length}
}

export function compareRecovery(sample, gap, baseline) {
  assert.ok(sample.video.slice(1, 21).every(v => v.generation === 2), "current returned generation required")
  return compareEdges(sample, gap, baseline)
}

export function compareDirections(samples, gaps, baselines) {
  return samples.map((sample, receiver) => compareEdges(sample, gaps[1 - receiver], baselines[1 - receiver]))
}
