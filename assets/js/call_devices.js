export function createFakeCallDevices({
  schedule = run => queueMicrotask(run),
  nextOutcome = () => ({ok: true}),
} = {}) {
  function acquire({audio = true, video = false} = {}) {
    let cancelled = false
    let settled = false
    const request = Object.freeze({
      audio: Boolean(audio),
      video: Boolean(video),
    })

    const promise = new Promise(resolve => {
      schedule(() => {
        if (settled) return
        settled = true

        if (cancelled) {
          resolve({ok: false, error: "cancelled"})
          return
        }

        const outcome = nextOutcome(request) ?? {ok: true}
        if (!outcome.ok) {
          const device = failedDeviceFor(request, outcome)
          if (device === "camera" && request.audio) {
            resolve({
              ok: false,
              error: outcome.error ?? "unknown-error",
              device,
              capture: createFakeCapture({audio: true, video: false}),
            })
            return
          }

          resolve({
            ok: false,
            error: outcome.error ?? "unknown-error",
            device,
          })
          return
        }

        resolve({
          ok: true,
          request,
          capture: createFakeCapture(request),
        })
      })
    })

    return {
      promise,
      cancel() {
        cancelled = true
      },
    }
  }

  return {acquire}
}

function failedDeviceFor(request, outcome) {
  if (outcome.device === "camera" && request.video) return "camera"
  return request.audio ? "microphone" : "camera"
}

function createFakeCapture(request) {
  return captureWithSources(
    request.audio ? fakeSource() : null,
    request.video ? fakeSource() : null,
  )
}

function fakeSource() {
  let released = false
  return {
    get live() { return !released },
    get released() { return released },
    release() { released = true },
  }
}

// A preparation releases both sources; each source can also be released alone.
// The legacy audio surface remains microphone-only, including its ended event.
function captureWithSources(microphone, camera, releaseSources = () => {
  microphone?.release()
  camera?.release()
}) {
  let released = false
  return {
    microphone,
    camera,
    audio: Boolean(microphone),
    video: Boolean(camera),
    stream: microphone?.stream,
    audioTrack: microphone?.track,
    get live() { return !released && Boolean(microphone?.live) },
    get released() { return released },
    onEnded(listener) { return microphone?.onEnded?.(listener) },
    release() {
      if (released) return
      released = true
      releaseSources()
    },
  }
}

// Compose separately owned acquisitions without changing their source contracts.
export function combineCallCaptures(microphoneCapture, cameraCapture) {
  const microphone = microphoneCapture.microphone ?? microphoneCapture
  const camera = cameraCapture.camera ?? (cameraCapture.video ? {
    get live() { return !cameraCapture.released },
    release() { cameraCapture.release() },
  } : null)
  return captureWithSources(microphone, camera, () => {
    microphoneCapture.release()
    cameraCapture.release()
  })
}

// navigator.mediaDevices is document-scoped. Keep unresolved requests here so
// replacing the Call controller/adapter cannot forget an abandoned prompt.
// Deliberately separate from Voice's browser-wide microphone arbitration.
const pendingDeviceRequests = new WeakMap()

async function requestDevice(mediaDevices, kind, constraints) {
  if (typeof mediaDevices?.getUserMedia !== "function") throw {code: "capture-unavailable"}
  let pending = pendingDeviceRequests.get(mediaDevices)
  if (!pending) {
    pending = new Set()
    pendingDeviceRequests.set(mediaDevices, pending)
  }
  if (pending.has(kind)) throw {code: "permission-pending"}
  pending.add(kind)
  try {
    return await mediaDevices.getUserMedia(constraints)
  } finally {
    // Application cancellation never clears this guard: only browser settlement.
    pending.delete(kind)
  }
}

export function createRealCallDevices({
  mediaDevices = globalThis.navigator?.mediaDevices,
  secureContext = globalThis.isSecureContext !== false,
} = {}) {
  function acquire({audio = true, video = false} = {}) {
    let cancelled = false
    let settle
    const promise = new Promise(resolve => { settle = resolve })
    let microphone = null
    let camera = null
    let device = audio ? "microphone" : "camera"
    const failure = error => ({ok: false, error, device})

    if (!audio && !video) {
      settle(failure("unavailable"))
    } else {
      Promise.resolve().then(async () => {
        if (cancelled) return
        if (!secureContext) throw {code: "capture-unavailable"}
        if (audio) {
          microphone = realSource(await requestDevice(mediaDevices, "microphone", {audio: true, video: false}), "audio")
          if (cancelled || !microphone.live) {
            microphone.release()
            settle(failure(cancelled ? "cancelled" : "ended"))
            return
          }
        }
        if (video) {
          device = "camera"
          camera = realSource(await requestDevice(mediaDevices, "camera", {audio: false, video: {
            width: {ideal: 960, max: 960},
            height: {ideal: 540, max: 540},
            frameRate: {ideal: 24, max: 24},
          }}), "video")
          if (!camera.live) throw {code: "ended"}
          if (!usableCameraSettings(camera.track.getSettings?.())) throw {code: "unsupported-profile"}
        }
        const capture = captureWithSources(microphone, camera)
        if (cancelled || (audio && !microphone.live)) {
          capture.release()
          settle({...failure(cancelled ? "cancelled" : "ended"), device: "microphone"})
          return
        }
        settle({ok: true, request: {audio: Boolean(audio), video: Boolean(video)}, capture})
      }).catch(error => {
        camera?.release()
        if (cancelled || !microphone?.live || device === "microphone") {
          const microphoneEnded = microphone && !microphone.live
          microphone?.release()
          settle(microphoneEnded && !cancelled ?
            {ok: false, error: "ended", device: "microphone"} : failure(cancelled ? "cancelled" : deviceError(error)))
        } else {
          settle({...failure(deviceError(error)), capture: captureWithSources(microphone, null)})
        }
      })
    }

    return {promise, cancel() {
      cancelled = true
      microphone?.release()
      camera?.release()
      settle(failure("cancelled"))
    }}
  }

  return {acquire, videoAvailable: true}
}

export function usableCameraSettings(settings) {
  return settings && [[settings.width, 960], [settings.height, 540], [settings.frameRate, 24]]
    .every(([value, max]) => Number.isFinite(value) && value > 0 && value <= max)
}

function deviceError(error) {
  if (["ended", "unsupported-profile", "permission-pending", "capture-unavailable"].includes(error?.code)) return error.code
  switch (error?.name) {
    case "NotAllowedError":
    case "SecurityError": return "permission-denied"
    case "NotFoundError": return "no-device"
    case "NotReadableError":
    case "AbortError": return "device-busy"
    case "OverconstrainedError": return "unsupported-profile"
    default: return "unknown-error"
  }
}

function realSource(stream, kind) {
  const ownedTracks = [...new Set(stream.getTracks())]
  const track = (kind === "audio" ? stream.getAudioTracks() : stream.getVideoTracks())[0] ?? null
  const listeners = new Set()
  const interruptionListeners = new Set()
  let released = false
  const ended = () => {
    if (!released) for (const listener of listeners) listener()
  }
  track?.addEventListener("ended", ended)
  const interruption = () => {
    if (!released && track?.readyState === "live") {
      for (const listener of interruptionListeners) listener()
    }
  }
  track?.addEventListener("mute", interruption)
  track?.addEventListener("unmute", interruption)

  return {
    stream,
    track,
    get live() { return !released && track?.readyState === "live" },
    get interrupted() { return !released && track?.readyState === "live" && track.muted === true },
    get released() { return released },
    onEnded(listener) {
      listeners.add(listener)
      return () => listeners.delete(listener)
    },
    onInterruption(listener) {
      interruptionListeners.add(listener)
      return () => interruptionListeners.delete(listener)
    },
    release() {
      if (released) return
      released = true
      track?.removeEventListener("ended", ended)
      track?.removeEventListener("mute", interruption)
      track?.removeEventListener("unmute", interruption)
      listeners.clear()
      interruptionListeners.clear()
      for (const track of ownedTracks) track.stop()
    },
  }
}
