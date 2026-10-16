// Presentation evidence is local to one sink/playback epoch. Never substitute
// packet arrival, a playing event or play fulfillment for a compositor frame.
export function observeCallVideo({element, binding, current, onState, firstObservation, document: doc, clock = {
  setTimeout: (fn, delay) => globalThis.setTimeout(fn, delay),
  clearTimeout: id => globalThis.clearTimeout(id),
}}) {
  let active = true, callback = null, ready = false
  let lastFrames = 0, lastTime = -Infinity, lastTimestamp = null, timer = null
  let state = "loading", frozen = false, epoch = 0, observingEpoch = null
  let floor = firstObservation ? {framesDecoded: 0, keyFramesDecoded: 0} : null
  let presentedKeyframe = null
  let recentFrames = []
  const eligible = () => active && current() && binding.isCurrent()
  const foreground = () => eligible() && !frozen && doc?.visibilityState !== "hidden"
  const positive = value => Number.isFinite(value) && value > 0

  function setState(value) {
    if (state === value) return
    state = value
    onState(value)
  }
  function deadline() {
    if (timer !== null) clock.clearTimeout(timer)
    const id = clock.setTimeout(() => {
      if (timer !== id || !foreground() || element.paused || state === "blocked") return
      timer = null
      setState("interrupted")
    }, 5000)
    timer = id
  }
  function arm() {
    if (!foreground() || !floor || callback !== null || observingEpoch === epoch || !element.requestVideoFrameCallback) return
    const generation = epoch
    callback = element.requestVideoFrameCallback((now, metadata) => presented(now, metadata, generation))
  }
  async function presented(now, metadata, generation) {
    if (generation !== epoch || !foreground()) return
    callback = null
    observingEpoch = generation
    const fresh = Number.isFinite(metadata.mediaTime) && metadata.mediaTime > lastTime &&
      Number.isSafeInteger(metadata.presentedFrames) && metadata.presentedFrames > lastFrames
    try {
      if (!fresh || !positive(metadata.width) || !positive(metadata.height) ||
          !positive(element.videoWidth) || !positive(element.videoHeight) || element.paused) return
      const timestamp = metadata.rtpTimestamp
      if (ready && Number.isInteger(timestamp) && timestamp >= 0 && timestamp <= 0xFFFFFFFF &&
          ((timestamp - lastTimestamp) >>> 0) > 0 && ((timestamp - lastTimestamp) >>> 0) < 0x80000000) {
        lastTime = metadata.mediaTime
        lastFrames = metadata.presentedFrames
        lastTimestamp = timestamp
        deadline()
        setState("ready")
        return
      }
      if (ready) return
      if (!Number.isInteger(timestamp) || timestamp < 0 || timestamp > 0xFFFFFFFF) return
      const fence = binding.presentation?.(timestamp)
      // Match a complete current-route keyframe itself. A later delta plus
      // an old repaired keyframe counter cannot establish this correlation.
      const exact = fence && timestamp === fence.rtp_timestamp
      // Authenticated marker delivery can follow native presentation. Keep
      // only eight metadata entries for 500ms in this exact observer/binding.
      recentFrames = recentFrames.filter(frame => now >= frame.observedAt && now - frame.observedAt <= 500)
      recentFrames.push({timestamp, receiveTime: metadata.receiveTime, observedAt: now})
      if (recentFrames.length > 8) recentFrames.shift()
      const observed = exact ? recentFrames.at(-1) : recentFrames.findLast(frame => binding.presentation?.(frame.timestamp))
      if (observed) presentedKeyframe = {...observed, fence: binding.presentation(observed.timestamp)}
      const keyframe = presentedKeyframe
      // Chrome can cache getStats across a compositor callback. Retain only
      // this exact presented keyframe until a native snapshot catches up.
      // A delta without that observation, or unsupported clocks, cannot pass.
      if (!keyframe || binding.presentation?.(keyframe.timestamp) !== keyframe.fence ||
          (!exact && (!Number.isFinite(keyframe.receiveTime) || !Number.isFinite(keyframe.observedAt)))) return
      lastTime = metadata.mediaTime
      lastFrames = metadata.presentedFrames
      const decoded = await binding.readDecode()
      if (generation !== epoch || !foreground() || element.paused || !positive(element.videoWidth) ||
          !positive(element.videoHeight) || binding.presentation?.(keyframe.timestamp) !== keyframe.fence || !decoded || !floor) return
      if (!exact && (!Number.isFinite(decoded.sampleTime) ||
          decoded.sampleTime < Math.max(keyframe.observedAt, keyframe.receiveTime))) return
      // Stats may already include this exact keyframe when the new binding
      // samples its baseline. Native receiveTime and stats timestamp share the
      // performance clock; only that observed overlap permits equal counters.
      const sampledAfterArrival = Number.isFinite(floor.sampleTime) && Number.isFinite(keyframe.receiveTime) &&
        floor.sampleTime >= keyframe.receiveTime
      if (decoded.framesDecoded > 0 && decoded.keyFramesDecoded > 0 &&
          (decoded.framesDecoded > floor.framesDecoded && decoded.keyFramesDecoded > floor.keyFramesDecoded ||
           sampledAfterArrival && decoded.framesDecoded >= floor.framesDecoded && decoded.keyFramesDecoded >= floor.keyFramesDecoded)) {
        ready = true
        presentedKeyframe = null
        recentFrames = []
        lastTimestamp = timestamp
        deadline()
        setState("ready")
      }
    } finally { if (generation === epoch) {observingEpoch = null; arm()} }
  }
  function suspend() {
    epoch += 1
    presentedKeyframe = null
    recentFrames = []
    if (timer !== null) clock.clearTimeout(timer)
    timer = null
    if (callback !== null) element.cancelVideoFrameCallback?.(callback)
    callback = null
  }
  function restart() {
    suspend()
    if (!foreground() || element.paused) return
    if (state !== "blocked") {setState("loading"); deadline()}
    arm()
  }
  function pause() {
    if (!element.paused) return
    suspend()
    if (state !== "blocked") setState("loading")
  }
  function playing() {
    if (!foreground() || element.paused) return
    if (state === "blocked") setState("loading")
    if (timer === null) deadline()
    arm()
  }
  function visibility() { restart() }
  function freeze() { frozen = true; suspend() }
  function resume() { frozen = false; restart() }
  doc?.addEventListener?.("visibilitychange", visibility)
  doc?.addEventListener?.("freeze", freeze)
  doc?.addEventListener?.("resume", resume)
  element.addEventListener?.("pause", pause)
  element.addEventListener?.("playing", playing)
  onState("loading")
  if (foreground() && !element.paused) deadline()
  if (floor) arm()
  else Promise.resolve(binding.readDecode()).then(value => {
    if (!eligible()) return
    // Rebinding a retained receiver requires subsequent decode/keyframe work.
    floor = value
    arm()
  }).catch(() => {})
  function play() {
    const playEpoch = epoch
    const blocked = () => {
      if (eligible() && playEpoch === epoch && !ready) {
        suspend()
        setState("blocked")
      }
    }
    // Explicit retries must reach native play inside the owner's gesture.
    try { Promise.resolve(element.play?.()).catch(blocked) }
    catch { blocked() }
  }
  const initialPlayEpoch = epoch
  Promise.resolve().then(() => { if (eligible() && initialPlayEpoch === epoch) play() })
  function retry() {
    if (!foreground() || state !== "blocked") return
    suspend()
    setState("loading")
    arm()
    play()
  }
  function cancel() {
    active = false
    presentedKeyframe = null
    recentFrames = []
    element.removeEventListener?.("pause", pause)
    element.removeEventListener?.("playing", playing)
    doc?.removeEventListener?.("visibilitychange", visibility)
    doc?.removeEventListener?.("freeze", freeze)
    doc?.removeEventListener?.("resume", resume)
    if (timer !== null) clock.clearTimeout(timer)
    if (callback !== null) element.cancelVideoFrameCallback?.(callback)
  }
  return {cancel, retry}
}
