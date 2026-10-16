import assert from "node:assert/strict"
import test from "node:test"

import {createFakeCallDevices, createRealCallDevices} from "./call_devices.js"

test("successful audio acquisition records the request and exposes idempotent release", async () => {
  const devices = createFakeCallDevices()
  const pending = devices.acquire({audio: true, video: false})
  const result = await pending.promise

  assert.equal(result.ok, true)
  assert.deepEqual(result.request, {audio: true, video: false})
  assert.equal(result.capture.audio, true)
  assert.equal(result.capture.video, false)
  assert.equal(result.capture.released, false)

  result.capture.release()
  result.capture.release()
  assert.equal(result.capture.released, true)
})

test("scripted denial, missing-device, and generic failure return presenter-friendly errors", async () => {
  for (const error of ["permission-denied", "no-device", "unknown-error"]) {
    const devices = createFakeCallDevices({
      nextOutcome: () => ({ok: false, error}),
    })
    const result = await devices.acquire({audio: true}).promise
    assert.deepEqual(result, {ok: false, error, device: "microphone"})
  }
})

test("successful audio-plus-video acquisition records the exact request", async () => {
  const devices = createFakeCallDevices()
  const result = await devices.acquire({audio: true, video: true}).promise

  assert.equal(result.ok, true)
  assert.deepEqual(result.request, {audio: true, video: true})
  assert.equal(result.capture.audio, true)
  assert.equal(result.capture.video, true)
  assert.equal(result.capture.released, false)
})

test("microphone-stage failures produce no partial capture", async () => {
  for (const error of ["permission-denied", "no-device", "unknown-error"]) {
    const devices = createFakeCallDevices({
      nextOutcome: () => ({ok: false, error, device: "microphone"}),
    })
    const result = await devices.acquire({audio: true, video: true}).promise

    assert.deepEqual(result, {ok: false, error, device: "microphone"})
    assert.equal(result.capture, undefined)
  }
})

test("camera-stage failures identify the camera and return partial audio capture", async () => {
  for (const error of ["permission-denied", "no-device", "unknown-error"]) {
    const devices = createFakeCallDevices({
      nextOutcome: () => ({ok: false, error, device: "camera"}),
    })
    const result = await devices.acquire({audio: true, video: true}).promise

    assert.equal(result.ok, false)
    assert.equal(result.error, error)
    assert.equal(result.device, "camera")
    assert.equal(result.capture.audio, true)
    assert.equal(result.capture.video, false)
    assert.equal(result.capture.released, false)

    result.capture.release()
    result.capture.release()
    assert.equal(result.capture.released, true)
  }
})

test("camera failure on an audio-only request stays a microphone failure", async () => {
  const devices = createFakeCallDevices({
    nextOutcome: () => ({ok: false, error: "no-device", device: "camera"}),
  })
  const result = await devices.acquire({audio: true, video: false}).promise

  assert.deepEqual(result, {ok: false, error: "no-device", device: "microphone"})
  assert.equal(result.capture, undefined)
})

test("a held late camera failure can be released immediately and idempotently", async () => {
  let run
  const devices = createFakeCallDevices({
    schedule: complete => {
      run = complete
    },
    nextOutcome: () => ({ok: false, error: "permission-denied", device: "camera"}),
  })
  const pending = devices.acquire({audio: true, video: true})
  run()
  const result = await pending.promise

  assert.equal(result.ok, false)
  assert.equal(result.device, "camera")
  result.capture.release()
  result.capture.release()
  assert.equal(result.capture.released, true)
})

test("cancellation before resolution produces no capture", async () => {
  let run
  const devices = createFakeCallDevices({
    schedule: complete => {
      run = complete
    },
  })
  const pending = devices.acquire({audio: true, video: false})
  pending.cancel()
  run()

  assert.deepEqual(await pending.promise, {ok: false, error: "cancelled"})
})

test("cancelled audio-plus-video work produces no full or partial capture", async () => {
  let run
  const devices = createFakeCallDevices({
    schedule: complete => {
      run = complete
    },
    nextOutcome: () => ({ok: false, error: "permission-denied", device: "camera"}),
  })
  const pending = devices.acquire({audio: true, video: true})
  pending.cancel()
  run()

  const result = await pending.promise
  assert.deepEqual(result, {ok: false, error: "cancelled"})
  assert.equal(result.capture, undefined)
})

test("cancelled work does not produce a capture after a late scheduler flush", async () => {
  let run
  const devices = createFakeCallDevices({
    schedule: complete => {
      run = complete
    },
  })
  const pending = devices.acquire({audio: true})
  pending.cancel()
  run()

  const result = await pending.promise
  assert.equal(result.ok, false)
  assert.equal(result.capture, undefined)
})

test("a held late success can be released immediately and idempotently", async () => {
  let run
  const devices = createFakeCallDevices({
    schedule: complete => {
      run = complete
    },
  })
  const pending = devices.acquire({audio: true, video: true})
  run()
  const result = await pending.promise

  assert.equal(result.ok, true)
  assert.deepEqual(result.request, {audio: true, video: true})
  result.capture.release()
  result.capture.release()
  assert.equal(result.capture.released, true)
})

test("real preparation owns a live independent audio track and observes source ending", async () => {
  const voice = browserTrack()
  const microphone = browserTrack()
  const requests = []
  const devices = createRealCallDevices({mediaDevices: {getUserMedia(request) {
    requests.push(request)
    return Promise.resolve(browserStream(microphone))
  }}})
  const result = await devices.acquire().promise
  assert.equal(result.ok, true)
  assert.deepEqual(requests, [{audio: true, video: false}])
  assert.equal(result.capture.audioTrack, microphone)
  assert.equal(result.capture.live, true)
  let ended = 0
  result.capture.onEnded(() => ended++)
  microphone.end()
  assert.equal(result.capture.live, false)
  assert.equal(ended, 1)
  result.capture.release()
  result.capture.release()
  assert.equal(microphone.stops, 1)
  assert.equal(voice.readyState, "live")
  assert.equal(voice.stops, 0)
})

function browserTrack(kind = "audio", settings = {width: 640, height: 360, frameRate: 15}) {
  const track = new EventTarget()
  track.kind = kind
  track.getSettings = () => settings
  track.readyState = "live"
  track.stops = 0
  track.stop = () => { track.stops++; track.readyState = "ended" }
  track.end = () => { track.readyState = "ended"; track.dispatchEvent(new Event("ended")) }
  return track
}

function browserStream(...tracks) {
  return {getTracks: () => tracks, getAudioTracks: () => tracks.filter(t => t.kind === "audio"),
    getVideoTracks: () => tracks.filter(t => t.kind === "video")}
}

test("cancelled permission stays guarded across adapter replacement until every late track is released", async () => {
  let grant
  let requests = 0
  const late = browserTrack(), extra = browserTrack("video"), replacement = browserTrack()
  const mediaDevices = {getUserMedia() {
    requests++
    return requests === 1 ? new Promise(resolve => {grant = resolve}) : Promise.resolve(browserStream(replacement))
  }}
  const pending = createRealCallDevices({mediaDevices}).acquire()
  await Promise.resolve()
  pending.cancel()
  assert.equal((await pending.promise).error, "cancelled")
  const next = createRealCallDevices({mediaDevices})
  assert.deepEqual(await next.acquire().promise, {ok: false, error: "permission-pending", device: "microphone"})
  assert.equal(requests, 1)
  grant(browserStream(late, extra))
  for (let i = 0; i < 10; i++) await Promise.resolve()
  assert.deepEqual([late.stops, extra.stops], [1, 1])
  const result = await next.acquire().promise
  assert.equal(result.capture.microphone.track, replacement)
  assert.equal(requests, 2)
  result.capture.release()
})

for (const kind of ["microphone", "camera"]) {
  test(`pending ${kind} rejects duplicates, permits the other device and unlocks after late rejection`, async () => {
    const audio = kind === "microphone"
    const request = {audio, video: !audio}
    let reject, requests = 0
    const other = browserTrack(audio ? "video" : "audio")
    const replacement = browserTrack(audio ? "audio" : "video")
    const devices = createRealCallDevices({mediaDevices: {getUserMedia(constraints) {
      requests++
      if (requests === 1) return new Promise((_, r) => {reject = r})
      return Promise.resolve(browserStream(constraints.audio === audio ? replacement : other))
    }}})
    const pending = devices.acquire(request)
    await Promise.resolve()
    assert.deepEqual(await devices.acquire(request).promise, {ok: false, error: "permission-pending", device: kind})
    pending.cancel()
    assert.equal((await pending.promise).error, "cancelled")
    const independent = await devices.acquire({audio: !audio, video: audio}).promise
    assert.equal(independent.ok, true)
    assert.equal(other.stops, 0)
    assert.deepEqual(await devices.acquire(request).promise, {ok: false, error: "permission-pending", device: kind})
    assert.equal(requests, 2)
    reject({name: "NotAllowedError", message: "private browser detail"})
    for (let i = 0; i < 10; i++) await Promise.resolve()
    const next = await devices.acquire(request).promise
    assert.equal(next.ok, true)
    assert.equal(other.stops, 0)
    independent.capture.release()
    next.capture.release()
    assert.deepEqual([other.stops, replacement.stops], [1, 1])
  })
}

test("cancelling a permission prompt settles immediately and stops only its late stream", async () => {
  let resolve
  const track = browserTrack()
  const devices = createRealCallDevices({mediaDevices: {getUserMedia: () => new Promise(r => {resolve = r})}})
  const pending = devices.acquire()
  await Promise.resolve()
  pending.cancel()
  assert.equal((await pending.promise).error, "cancelled")
  resolve(browserStream(track))
  await Promise.resolve()
  await Promise.resolve()
  assert.equal(track.stops, 1)
})

test("missing capture APIs and insecure contexts are distinct from absent hardware", async () => {
  for (const mediaDevices of [null, {}, {getUserMedia: true}]) {
    const devices = createRealCallDevices({mediaDevices})
    assert.deepEqual(await devices.acquire({audio: false, video: true}).promise,
      {ok: false, error: "capture-unavailable", device: "camera"})
  }
  let requests = 0
  const devices = createRealCallDevices({secureContext: false,
    mediaDevices: {getUserMedia() {requests++; return browserStream(browserTrack())}}})
  assert.deepEqual(await devices.acquire({video: true}).promise,
    {ok: false, error: "capture-unavailable", device: "microphone"})
  assert.equal(requests, 0)
})

test("unsupported requests and device errors expose only safe codes", async () => {
  const devices = createRealCallDevices({mediaDevices: {getUserMedia() {throw new Error("must not capture")}}})
  assert.equal((await devices.acquire({audio: false}).promise).error, "unavailable")
  for (const [name, expected] of [["NotAllowedError", "permission-denied"], ["NotFoundError", "no-device"], ["NotReadableError", "device-busy"], ["OtherError", "unknown-error"]]) {
    const denied = createRealCallDevices({mediaDevices: {getUserMedia: () => Promise.reject({name, message: "private device"})}})
    assert.deepEqual(await denied.acquire().promise, {ok: false, error: expected, device: "microphone"})
  }
})

test("camera exceptions remain bounded categories without raw device or policy data", async () => {
  for (const [name, expected] of [
    ["NotAllowedError", "permission-denied"], ["SecurityError", "permission-denied"],
    ["NotFoundError", "no-device"], ["NotReadableError", "device-busy"], ["AbortError", "device-busy"],
    ["OverconstrainedError", "unsupported-profile"], ["TypeError", "unknown-error"],
    ["OtherError", "unknown-error"], ["toString", "unknown-error"], ["__proto__", "unknown-error"],
  ]) {
    const devices = createRealCallDevices({mediaDevices: {getUserMedia() {
      throw {name, message: "private camera", constraint: "private constraint", deviceId: "private id"}
    }}})
    assert.deepEqual(await devices.acquire({audio: false, video: true}).promise,
      {ok: false, error: expected, device: "camera"}, name)
  }
})

test("empty or already-ended results release all acquired tracks and cannot prepare a Call", async () => {
  const ended = browserTrack()
  ended.readyState = "ended"
  for (const tracks of [[], [ended]]) {
    const devices = createRealCallDevices({mediaDevices: {getUserMedia: () => Promise.resolve(browserStream(...tracks))}})
    assert.equal((await devices.acquire().promise).error, "ended")
  }
  assert.equal(ended.stops, 1)
})

test("intentional release invalidates ended listeners including later source events", async () => {
  const track = browserTrack()
  const devices = createRealCallDevices({mediaDevices: {getUserMedia: () => Promise.resolve(browserStream(track))}})
  const {capture} = await devices.acquire().promise
  let ended = 0
  capture.onEnded(() => ended++)
  capture.release()
  track.end()
  assert.equal(ended, 0)
})


test("fake camera release preserves its microphone and whole-preparation release stays idempotent", async () => {
  const {capture} = await createFakeCallDevices().acquire({audio: true, video: true}).promise
  capture.camera.release()
  capture.camera.release()
  assert.equal(capture.camera.released, true)
  assert.equal(capture.microphone.released, false)
  assert.equal(capture.live, true)
  assert.equal(capture.released, false)
  capture.release()
  capture.release()
  assert.equal(capture.microphone.released, true)
  assert.equal(capture.released, true)
})

test("source release stops only acquisition-owned tracks even if the stream later changes", async () => {
  const voice = browserTrack(), microphone = browserTrack()
  const tracks = [microphone]
  const stream = browserStream(...tracks)
  stream.getTracks = () => tracks
  const devices = createRealCallDevices({mediaDevices: {getUserMedia: async () => stream}})
  const {capture} = await devices.acquire().promise
  assert.equal(capture.microphone.track, microphone)
  assert.equal(capture.microphone.stream, capture.stream)
  assert.equal(capture.camera, null)
  tracks.push(voice)
  capture.microphone.release()
  capture.release()
  capture.release()
  assert.equal(microphone.stops, 1)
  assert.equal(voice.stops, 0)
  assert.equal(voice.readyState, "live")
  assert.equal(capture.live, false)
})


test("real video prepares independent microphone then a bounded lower-profile camera", async () => {
  const microphone = browserTrack(), camera = browserTrack("video"), requests = []
  let grantMicrophone
  const devices = createRealCallDevices({mediaDevices: {getUserMedia(request) {
    requests.push(request)
    return request.audio ? new Promise(r => { grantMicrophone = r }) : Promise.resolve(browserStream(camera))
  }}})
  const pending = devices.acquire({audio: true, video: true})
  await Promise.resolve()
  assert.deepEqual(requests, [{audio: true, video: false}])
  grantMicrophone(browserStream(microphone))
  const {ok, capture} = await pending.promise
  assert.equal(ok, true)
  assert.deepEqual(requests[1], {audio: false, video: {
    width: {ideal: 960, max: 960}, height: {ideal: 540, max: 540}, frameRate: {ideal: 24, max: 24},
  }})
  assert.equal(capture.microphone.track, microphone)
  assert.equal(capture.camera.track, camera)
  assert.equal(capture.camera.live, true)
  capture.camera.release()
  assert.equal(camera.stops, 1)
  assert.equal(microphone.stops, 0)
  capture.release()
  assert.equal(microphone.stops, 1)
})


test("camera preflight inspects actual settings and releases excessive, empty or ended results", async () => {
  for (const settings of [
    {width: 1280, height: 540, frameRate: 24}, {width: 960, height: 720, frameRate: 24},
    {width: 960, height: 540, frameRate: 30}, {width: 0, height: 540, frameRate: 24}, {},
    {width: 960, height: -1, frameRate: 24}, {width: 960, height: 540, frameRate: 0},
    {width: NaN, height: 540, frameRate: 24}, {width: 960, height: Infinity, frameRate: 24},
    {width: 960, height: 540, frameRate: "24"}, null,
  ]) {
    const microphone = browserTrack(), camera = browserTrack("video", settings), extra = browserTrack("video")
    const devices = createRealCallDevices({mediaDevices: {getUserMedia: async request =>
      request.audio ? browserStream(microphone) : browserStream(camera, extra)}})
    const result = await devices.acquire({video: true}).promise
    assert.equal(result.ok, false)
    assert.equal(result.error, "unsupported-profile")
    assert.equal(result.device, "camera")
    assert.equal(camera.stops, 1)
    assert.equal(extra.stops, 1)
    assert.equal(microphone.stops, 0)
    result.capture.release()
    assert.equal(microphone.stops, 1)
  }
  for (const empty of [true, false]) {
    const microphone = browserTrack(), camera = browserTrack("video")
    camera.readyState = "ended"
    const devices = createRealCallDevices({mediaDevices: {getUserMedia: async request =>
      request.audio ? browserStream(microphone) : browserStream(...(empty ? [] : [camera]))}})
    const result = await devices.acquire({video: true}).promise
    assert.equal(result.error, "ended")
    assert.equal(result.device, "camera")
    assert.equal(camera.stops, empty ? 0 : 1)
    result.capture.release()
  }
})

test("cancelling a pending camera releases microphone now and every late acquired track", async () => {
  const microphone = browserTrack(), camera = browserTrack("video"), extra = browserTrack("video")
  let grantCamera, cameraRequested
  const requested = new Promise(r => {cameraRequested = r})
  const devices = createRealCallDevices({mediaDevices: {getUserMedia(request) {
    if (request.audio) return Promise.resolve(browserStream(microphone))
    cameraRequested()
    return new Promise(r => {grantCamera = r})
  }}})
  const pending = devices.acquire({video: true})
  await requested
  pending.cancel()
  assert.equal((await pending.promise).error, "cancelled")
  assert.equal(microphone.stops, 1)
  grantCamera(browserStream(camera, extra))
  await Promise.resolve(); await Promise.resolve()
  assert.equal(camera.stops, 1)
  assert.equal(extra.stops, 1)
  assert.equal(microphone.stops, 1)
})


test("microphone loss while camera fails cannot be reported as a camera-only fallback", async () => {
  const microphone = browserTrack()
  const devices = createRealCallDevices({mediaDevices: {getUserMedia: async request => {
    if (request.audio) return browserStream(microphone)
    microphone.end()
    throw {name: "NotAllowedError"}
  }}})
  const result = await devices.acquire({video: true}).promise
  assert.deepEqual(result, {ok: false, error: "ended", device: "microphone"})
  assert.equal(microphone.stops, 1)
})
