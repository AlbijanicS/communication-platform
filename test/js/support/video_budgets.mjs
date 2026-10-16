export function summarizeCell(samples) {
  const values = samples.map(s => s.error ? Infinity : s.elapsedMs + s.uncertaintyMs).sort((a, b) => a - b)
  const p95 = values[Math.ceil(.95 * values.length) - 1] ?? Infinity
  const maximum = values.at(-1) ?? Infinity
  return {n: samples.length, failures: samples.filter(s => s.error).length,
    p95UpperMs: Number.isFinite(p95) ? p95 : null, maxUpperMs: Number.isFinite(maximum) ? maximum : null,
    targetPass: samples.length >= 20 && p95 <= 2000}
}
export function payloadRate(a, b) {
  const fields = ["timestamp", "bytesSent", "retransmittedBytesSent", "headerBytesSent"]
  if (!a || !b || typeof a.id !== "string" || !Number.isInteger(a.ssrc) || a.id !== b.id || a.ssrc !== b.ssrc ||
      fields.some(k => !Number.isFinite(a[k]) || !Number.isFinite(b[k]) || a[k] < 0 || b[k] < a[k])) return null
  const windowMs = b.timestamp - a.timestamp, repair = b.retransmittedBytesSent - a.retransmittedBytesSent
  const total = b.bytesSent - a.bytesSent
  if (windowMs <= 0 || repair > total) return null
  return {windowMs, primaryBps: 8000 * (total - repair) / windowMs,
    repairBps: 8000 * repair / windowMs, headerBps: 8000 * (b.headerBytesSent - a.headerBytesSent) / windowMs}
}

export function installBudgetObserver() {
  window.budget = {frames: [], captures: [], markers: []}
  const NativeSocket = WebSocket
  window.WebSocket = class extends NativeSocket {
    constructor(...args) {
      super(...args)
      this.addEventListener("message", event => {
        const payload = JSON.parse(event.data)[4]
        const id = payload?.call_session_id ?? payload?.response?.call_session_id
        if (id) window.budget.session = id
        const marker = payload?.video_presentation
        if (Number.isInteger(marker?.rtp_timestamp)) {
          window.budget.markers.push({epoch: marker.epoch, timestamp: marker.rtp_timestamp, at: performance.now()})
          if (window.budget.markers.length > 16) window.budget.markers.shift()
        }
      })
    }
  }
  const frame = HTMLVideoElement.prototype.requestVideoFrameCallback
  HTMLVideoElement.prototype.requestVideoFrameCallback = function (fn) {
    return frame.call(this, async (now, metadata) => {
      const binding = window.callController?.getState().remoteVideoBinding
      if (this.id === "direct-call-remote-video" && binding?.isCurrent()) {
        const recent = (window.budget.recent ?? []).filter(f => f.binding === binding && now - f.compositorAt <= 500)
        recent.push({binding, timestamp: metadata.rtpTimestamp, compositorAt: now, width: metadata.width, height: metadata.height})
        window.budget.recent = recent.slice(-8)
      }
      await fn(now, metadata)
      const matched = window.budget.recent?.findLast(f => f.binding === binding && binding?.presentation(f.timestamp))
      if (matched) window.budget.presented = {...matched, fence: binding.presentation(matched.timestamp)}
      const presented = window.budget.presented
      const fence = presented && binding?.presentation?.(presented.timestamp)
      if (this.id !== "direct-call-remote-video" || !presented || presented.binding !== binding || !binding?.isCurrent() ||
          !fence || fence !== presented.fence ||
          this.style.visibility === "hidden" || this.paused || presented.width <= 0 || presented.height <= 0 ||
          window.callController.getState().remoteVideoState !== "ready" ||
          window.budget.frames.some(f => f.epoch === fence.epoch)) return
      const marker = window.budget.markers.findLast(m => m.epoch === fence.epoch && m.timestamp === presented.timestamp)
      window.budget.frames.push({epoch: fence.epoch, version: fence.camera_version, at: performance.now(),
        compositorAt: presented.compositorAt, width: presented.width, height: presented.height,
        ...(marker ? {markerLagMs: marker.at - presented.compositorAt} : {})})
    })
  }
  // Install after the synthetic capture override, before the first owner action.
  window.installBudgetCapture = () => {
    const capture = navigator.mediaDevices.getUserMedia.bind(navigator.mediaDevices)
    navigator.mediaDevices.getUserMedia = async constraints => {
      const start = performance.now(), stream = await capture(constraints)
      if (constraints.video) window.budget.captures.push({start, end: performance.now()})
      return stream
    }
  }
}
