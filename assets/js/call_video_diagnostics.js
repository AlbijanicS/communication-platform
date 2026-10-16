// Local console evidence only. Missing presentation says nothing about network
// cause. Fixed categories coalesce across Calls without timers or private IDs.
const CAMERA_STATES = new Set(["off", "pending", "preview_ready", "attaching", "enabled", "interrupted", "error"])
const PRESENTATION_STATES = new Set(["off", "loading", "ready", "blocked", "interrupted"])
const CAMERA_ERRORS = new Set(["permission-pending", "permission-denied", "no-device", "device-busy",
  "unsupported-profile", "capture-unavailable", "unknown-error", "ended", "incompatible-sender"])

export function createCallVideoDiagnostics({write = record => globalThis.console?.info?.("Call video diagnostic", record),
  now = () => globalThis.performance.now()} = {}) {
  const previous = new Map(), emitted = new Map()
  function observe(operation, outcome, allowed, error = null, stage = operation) {
    if (!allowed.has(outcome)) return
    const errorCode = operation === "camera" && outcome === "error" && CAMERA_ERRORS.has(error) ? error : null
    const key = `${stage}:${operation}:${outcome}:${errorCode ?? ""}`
    if (previous.get(`${stage}:${operation}`) === key) return
    previous.set(`${stage}:${operation}`, key)
    const time = now()
    if (emitted.has(key) && time - emitted.get(key) < 10_000) return
    emitted.set(key, time)
    const record = {component: "browser", operation, media_kind: "video", stage, outcome,
      ...(errorCode ? {error_code: errorCode} : {})}
    try {write(Object.freeze(record))} catch (_) {}
  }
  return state => {
    if (state.call?.ownership === "elsewhere") return
    if (state.mediaIntent === "video" &&
        ["preflighting", "outgoing_ringing", "incoming_preflighting", "incoming_ringing", "result"].includes(state.presentation)) {
      if (CAMERA_ERRORS.has(state.cameraPreflightError)) {
        observe("camera", "error", CAMERA_STATES, state.cameraPreflightError, "preflight")
      } else if (state.cameraState === "preview_ready") {
        observe("camera", "preview_ready", CAMERA_STATES, null, "preflight")
      }
    }
    if (state.call?.ownership !== "self" || !["connecting", "active"].includes(state.presentation)) return
    observe("camera", state.cameraState, CAMERA_STATES, state.cameraError)
    observe("presentation", state.remoteVideoState, PRESENTATION_STATES)
  }
}
