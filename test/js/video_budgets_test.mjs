import {test} from "node:test"
import assert from "node:assert/strict"
import {runInNewContext} from "node:vm"
import {summarizeCell, payloadRate, installBudgetObserver} from "./support/video_budgets.mjs"

test("timing correlates a late marker and ends on visible readiness, never a delta alone or retired binding", async () => {
  let callback, state = "loading", at = 100
  const fence = {epoch: 1, camera_version: 1, rtp_timestamp: 9000}
  let current = true, marked = false
  const binding = {isCurrent: () => current, presentation: t => marked && t === 9000 ? fence : null}
  let activeBinding = binding
  class Video {
    id = "direct-call-remote-video"
    style = {visibility: "visible"}
    paused = false
    requestVideoFrameCallback(fn) {callback = fn}
  }
  const window = {callController: {getState: () => ({remoteVideoBinding: activeBinding, remoteVideoState: state})}}
  runInNewContext(`(${installBudgetObserver.toString()})()`, {
    window, WebSocket: class {}, HTMLVideoElement: Video, performance: {now: () => at},
  })
  const video = new Video()
  video.requestVideoFrameCallback(() => {state = "ready"})
  await callback(10, {rtpTimestamp: 12000, width: 960, height: 540})
  assert.equal(window.budget.frames.length, 0)
  state = "loading"
  video.requestVideoFrameCallback(() => {})
  await callback(20, {rtpTimestamp: 9000, width: 960, height: 540})
  assert.equal(window.budget.frames.length, 0)
  marked = true
  video.requestVideoFrameCallback(() => {})
  await callback(30, {rtpTimestamp: 12000, width: 960, height: 540})
  assert.equal(window.budget.frames.length, 0)
  // Decode confirmation may follow after the unmatched-frame history expires.
  video.requestVideoFrameCallback(() => {state = "ready"})
  at = 1400
  await callback(1300, {rtpTimestamp: 12000, width: 960, height: 540})
  assert.deepEqual(JSON.parse(JSON.stringify(window.budget.frames)), [
    {epoch: 1, version: 1, at: 1400, compositorAt: 20, width: 960, height: 540},
  ])
  window.budget.frames = []
  current = false
  video.requestVideoFrameCallback(() => {})
  await callback(40, {rtpTimestamp: 12000, width: 960, height: 540})
  assert.equal(window.budget.frames.length, 0)
  activeBinding = null
  video.requestVideoFrameCallback(() => {})
  await callback(50, {rtpTimestamp: 12000, width: 960, height: 540})
  assert.equal(window.budget.frames.length, 0)
})

test("engineering p95 includes timeout and uncertainty without hiding the maximum", () => {
  const samples = Array.from({length: 18}, () => ({elapsedMs: 100, uncertaintyMs: 2}))
  samples.push({elapsedMs: 2100, uncertaintyMs: 2}, {error: "timeout"})
  assert.deepEqual(summarizeCell(samples), {n: 20, failures: 1, p95UpperMs: 2102, maxUpperMs: null, targetPass: false})
  assert.equal(summarizeCell(samples.slice(0, 18)).targetPass, false)
})

test("payload and repair remain separate from headers, absent fields and replaced streams", () => {
  const a = {id: "v", ssrc: 10, timestamp: 1000, bytesSent: 1000, retransmittedBytesSent: 100, headerBytesSent: 200}
  const b = {...a, timestamp: 1250, bytesSent: 2100, retransmittedBytesSent: 200, headerBytesSent: 300}
  assert.deepEqual(payloadRate(a, b), {windowMs: 250, primaryBps: 32000, repairBps: 3200, headerBps: 3200})
  assert.equal(payloadRate(a, {...b, retransmittedBytesSent: undefined}), null)
  assert.equal(payloadRate(a, {...b, ssrc: 11}), null)
  assert.equal(payloadRate(a, {...b, bytesSent: 900}), null)
  assert.equal(payloadRate(a, {...b, retransmittedBytesSent: 1300}), null)
  assert.equal(payloadRate(a, {...b, timestamp: 1000}), null)
  assert.equal(payloadRate({...a, ssrc: undefined}, {...b, ssrc: undefined}), null)
})
