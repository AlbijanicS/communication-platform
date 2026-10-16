import {browserIceServer, turnOnlyIceServer, candidateByteSize, withDeadline} from "./media_peer_helpers.js"
import {usableCameraSettings} from "./call_devices.js"

// One instance belongs to one authorized Call/action; it is never reused.
export function createCallPeerAttempt({
  PeerConnection = globalThis.RTCPeerConnection,
  MediaStream = globalThis.MediaStream,
  codecCapabilities = kind => globalThis.RTCRtpSender?.getCapabilities(kind),
  negotiationId = () => globalThis.crypto.randomUUID(),
  signaling, remoteAudio,
  onFailure = () => {}, onState = () => {}, onPlayback = () => {}, onCamera = () => {},
  onRemoteVideo = () => {},
  setTimeoutFn = globalThis.setTimeout, clearTimeoutFn = globalThis.clearTimeout,
} = {}) {
  const abort = new AbortController()
  let active = false, started = false, pc = null, audio = null, stream = null
  let identity = null, answerApplied = false, pending = [], pendingBytes = 0
  let remoteTrack = null, unsubscribeIce = null, unsubscribeState = null
  let remoteVideoTrack = null, presentationRoute = null, presentationKeys = [], remoteOffVersion = -1
  let mediaStateVersion = 0, localMuted = false
  let localDeafened = false
  let video = null, videoMid = null, videoSender = null, attachedCamera = null, requestedCamera = null
  let cameraGeneration = 0, cameraReplacement = Promise.resolve()
  let playbackGeneration = 0
  let playbackHandler = null
  let recovery = null, renewalPending = false, localCandidates = 0, serverCandidates = 0
  const timers = new Set(), handlers = []

  function schedule(fn, delay) {
    const id = setTimeoutFn(() => { timers.delete(id); if (active) fn() }, delay)
    timers.add(id)
    id?.unref?.()
    return id
  }
  function cleanup() {
    active = false
    cameraGeneration += 1
    attachedCamera = null
    requestedCamera = null
    abort.abort()
    for (const timer of timers) clearTimeoutFn(timer)
    timers.clear()
    unsubscribeIce?.(); unsubscribeState?.()
    for (const [event, fn] of handlers) pc?.removeEventListener(event, fn)
    handlers.length = 0
    clearPlaybackListener()
    remoteTrack?.removeEventListener?.("ended", remoteEnded)
    remoteVideoEnded()
    if (remoteAudio?.srcObject === stream) { remoteAudio.pause?.(); remoteAudio.srcObject = null }
    pc?.close()
    pending = []; pendingBytes = 0; remoteTrack = null; stream = null
  }
  function fail() {
    if (!active) return
    cleanup()
    onFailure("connection_lost")
  }
  function ensureActive() { if (!active) throw Error("Call connection cancelled") }
  function waitForAdmissionRetry() {
    return new Promise((resolve, reject) => {
      const cancelled = () => {
        clearTimeoutFn(timer); timers.delete(timer)
        reject(Error("Call connection cancelled"))
      }
      const timer = schedule(() => {
        abort.signal.removeEventListener("abort", cancelled)
        resolve()
      }, 250)
      abort.signal.addEventListener("abort", cancelled, {once: true})
    })
  }
  async function discoverCredentials(callId) {
    while (active) {
      const credentials = await signaling.mediaCredentials({callId})
      ensureActive()
      // Acceptance is projected before asynchronous pair publication. Discovery
      // remains read-only and owner-authorized; no media starts before success.
      if (credentials?.error !== "not_admitted" ||
          signaling.getState()?.call?.state !== "connecting") return credentials
      await waitForAdmissionRetry()
    }
    ensureActive()
  }
  function matches(message, negotiated = true) {
    return identity && ["call_id", "call_session_id", "signaling_session_id", ...(negotiated ? ["negotiation_id"] : [])]
      .every(key => message?.[key] === identity[key])
  }
  function bind(event, fn) { pc.addEventListener(event, fn); handlers.push([event, fn]) }
  function clearPlaybackListener() {
    if (playbackHandler) remoteAudio?.removeEventListener?.("playing", playbackHandler)
    playbackHandler = null
  }
  async function play() {
    if (!active || !remoteTrack) return
    clearPlaybackListener()
    const track = remoteTrack
    const generation = ++playbackGeneration
    const current = () => active && remoteTrack === track && playbackGeneration === generation &&
      remoteAudio?.srcObject === stream
    let playing = false
    // Autoplay can start the retained stream while the explicit play promise
    // is pending. Observe playback itself without allowing stale work to win.
    const played = () => {
      if (!current() || playing) return
      playing = true
      clearPlaybackListener()
      onPlayback("playing")
    }
    playbackHandler = played
    remoteAudio?.addEventListener?.("playing", played)
    try { await remoteAudio?.play(); played() }
    catch (_) { if (current() && !playing) onPlayback("blocked") }
  }
  function remoteEnded() {
    if (!remoteTrack) return
    clearPlaybackListener()
    stream?.removeTrack(remoteTrack)
    remoteTrack?.removeEventListener?.("ended", remoteEnded)
    remoteTrack = null
    if (active) onPlayback("waiting")
  }
  function receiveTrack(event) {
    if (active && event?.track?.kind === "video" && event.track === video.receiver.track &&
        event.transceiver === video && remoteVideoTrack !== event.track) {
      remoteVideoEnded()
      remoteVideoTrack = event.track
      remoteVideoTrack.addEventListener?.("ended", remoteVideoEnded)
      publishRemoteVideo()
      return
    }
    if (!active || event?.track?.kind !== "audio" || event.track !== audio.receiver.track ||
        event.transceiver !== audio || remoteTrack === event.track) return
    remoteEnded()
    remoteTrack = event.track
    remoteTrack.addEventListener?.("ended", remoteEnded)
    stream.addTrack(remoteTrack)
    // Rebind after adding the track: Brave can retain the initially empty
    // stream's media state while audio is flowing and leave play() pending.
    if (remoteAudio) remoteAudio.srcObject = stream
    play()
  }
  function publishRemoteVideo() {
    if (!remoteVideoTrack) return
    const track = remoteVideoTrack
    const receiver = video.receiver, session = identity, peer = pc
    const current = () => active && identity === session && pc === peer &&
      signaling.mediaSessionIsCurrent(session) && pc.getTransceivers().includes(video) &&
      video.receiver === receiver && receiver.track === remoteVideoTrack &&
      remoteVideoTrack === track && video.mid === videoMid
    const route = presentationRoute
    const currentBinding = () => current() && presentationRoute?.epoch === route?.epoch &&
      (!route || route.camera_version === null || route.camera_version > remoteOffVersion)
    const videoBinding = {receiver, routeEpoch: route?.epoch ?? null, isCurrent: currentBinding,
      presentation(timestamp) {
        if (!currentBinding()) return null
        return timestamp == null ? presentationKeys.at(-1) ?? null
          : presentationKeys.find(key => key.rtp_timestamp === timestamp) ?? null
      },
      async readDecode() {
        if (!currentBinding() || !receiver.getStats) return null
        try {
          const reports = await receiver.getStats()
          if (!currentBinding()) return null
          const inbound = [...reports.values()].filter(report => report.type === "inbound-rtp" &&
            (report.kind ?? report.mediaType) === "video" &&
            report.trackIdentifier === track.id)
          if (inbound.length !== 1) return null
          const {framesDecoded, keyFramesDecoded} = inbound[0]
          if (!Number.isSafeInteger(framesDecoded) || !Number.isSafeInteger(keyFramesDecoded)) return null
          const sampleTime = inbound[0].timestamp - globalThis.performance?.timeOrigin
          return {framesDecoded, keyFramesDecoded,
            ...(Number.isFinite(sampleTime) ? {sampleTime} : {})}
        } catch (_) { return null }
      }}
    onRemoteVideo(remoteVideoTrack, videoBinding)
  }
  function remoteVideoEnded() {
    if (!remoteVideoTrack) return
    remoteVideoTrack.removeEventListener?.("ended", remoteVideoEnded)
    remoteVideoTrack = null
    onRemoteVideo(null)
  }
  async function addCandidate(candidate) {
    const peer = pc
    try { ensureActive(); await peer.addIceCandidate(candidate) }
    catch (_) { if (active) fail() }
  }
  function receiveMediaEvent(message) {
    if (!active || !matches(message)) return
    if (message.video_presentation) {
      const route = message.video_presentation
      if (!Number.isSafeInteger(route.epoch) || route.epoch <= 0 ||
          !(route.camera_version === null || Number.isSafeInteger(route.camera_version) && route.camera_version >= 0) ||
          !(route.rtp_timestamp === null || Number.isInteger(route.rtp_timestamp) && route.rtp_timestamp >= 0 && route.rtp_timestamp <= 0xFFFFFFFF) ||
          route.epoch < (presentationRoute?.epoch ?? 0)) return
      const changed = route.epoch !== presentationRoute?.epoch
      if (!changed && (route.camera_version !== presentationRoute.camera_version || route.rtp_timestamp === null ||
          presentationRoute.rtp_timestamp !== null &&
          (route.rtp_timestamp - presentationRoute.rtp_timestamp + 0x100000000) % 0x100000000 >= 0x80000000)) return
      if (changed) presentationKeys = []
      presentationRoute = Object.freeze({...route})
      if (route.rtp_timestamp !== null && !presentationKeys.some(key => key.rtp_timestamp === route.rtp_timestamp)) {
        presentationKeys.push(presentationRoute)
        presentationKeys = presentationKeys.slice(-4)
      }
      if (changed) publishRemoteVideo()
      return
    }
    const end = message.end_of_candidates === true
    const candidate = end ? {candidate: ""} : message.candidate
    if (!candidate) return
    const bytes = end ? 0 : candidateByteSize(candidate)
    if (bytes > 8 * 1024 || (!end && ++serverCandidates > 64)) { fail(); return }
    if (!answerApplied) {
      if (pending.length >= 16 || pendingBytes + bytes > 128 * 1024) { fail(); return }
      pending.push(candidate); pendingBytes += bytes
    } else addCandidate(candidate)
  }
  function sendIce(event) {
    // The pinned server rejects end-of-candidates markers. Gathering completion
    // is not a connection failure; only actual candidates cross this boundary.
    if (!active || !event.candidate) return
    const candidate = event.candidate?.toJSON?.() ?? event.candidate
    if (candidate && (candidateByteSize(candidate) > 8 * 1024 || ++localCandidates > 64)) { fail(); return }
    signaling.sendMedia("ice_candidate", {...identity, candidate})
      .then(reply => { if (active && !reply?.ok) fail() }).catch(fail)
  }
  function connectionChanged() {
    if (!active) return
    const state = pc.connectionState
    if (["failed", "closed"].includes(state)) { fail(); return }
    if (state === "connected") { clearTimeoutFn(recovery); timers.delete(recovery); recovery = null }
    if (state === "disconnected" && recovery === null) recovery = schedule(fail, 30_000)
    onState(state === "disconnected" ? "interrupted" : state)
  }
  function sendLocalState() {
    if (!active || !answerApplied || mediaStateVersion === 0) return
    const version = mediaStateVersion
    const snapshot = {...identity, media_state_version: version,
      microphone_muted: localMuted, camera_enabled: cameraEnabled()}
    withDeadline(signaling.sendMedia("local_media_state", snapshot), 10_000,
      setTimeoutFn, clearTimeoutFn, abort.signal).then(reply => {
        if (active && mediaStateVersion === version &&
            (!reply?.ok || !matches(reply) || reply.media_state_version !== version ||
              reply.microphone_muted !== snapshot.microphone_muted ||
              reply.camera_enabled !== snapshot.camera_enabled)) fail()
      }).catch(() => { if (active && mediaStateVersion === version) fail() })
  }
  function sendingVideo() {
    return video && pc?.getTransceivers().includes(video) && video.sender === videoSender &&
      typeof videoMid === "string" && video.mid === videoMid && ["sendrecv", "sendonly"].includes(video.currentDirection)
  }
  function cameraEnabled() {
    return Boolean(active && answerApplied && sendingVideo() && attachedCamera &&
      attachedCamera.readyState === "live" && attachedCamera.enabled === true &&
      videoSender.track === attachedCamera)
  }
  function publishCameraState(state, error = null) {
    if (mediaStateVersion === Number.MAX_SAFE_INTEGER) { fail(); return }
    mediaStateVersion += 1
    sendLocalState()
    onCamera(state, error)
  }
  function releaseCamera() {
    const generation = ++cameraGeneration, session = identity
    attachedCamera = null
    requestedCamera = null
    if (!active) return
    if (answerApplied) publishCameraState("off")
    else onCamera("off")
    // Release belongs to the devices/controller. Serialize detachment after
    // any in-flight replacement; capture never waits for this browser promise.
    cameraReplacement = cameraReplacement.then(async () => {
      if (active && answerApplied && identity === session && cameraGeneration === generation &&
          signaling.mediaSessionIsCurrent(session) && videoSender) await videoSender.replaceTrack(null)
    }).catch(() => {})
  }
  function attachCamera(track) {
    if (!active) return
    requestedCamera = track
    cameraGeneration += 1
    if (answerApplied) attachPreparedCamera(track)
    else onCamera("preview_ready")
  }
  function attachPreparedCamera(track) {
    const generation = ++cameraGeneration, peer = pc, session = identity
    const current = () => active && pc === peer && identity === session &&
      cameraGeneration === generation && signaling.mediaSessionIsCurrent(session)
    const live = () => track?.kind === "video" && track.readyState === "live" && track.enabled === true
    const profile = () => {
      if (!usableCameraSettings(track.getSettings?.())) throw {code: "unsupported-profile"}
    }
    onCamera("attaching")
    cameraReplacement = cameraReplacement.then(async () => {
      if (!current()) return
      try {
        if (!answerApplied || !sendingVideo() || !videoSender.replaceTrack) throw Error("incompatible sender")
        if (!live()) throw Error("ended camera")
        profile()
        // Use the browser's fresh transaction without changing codec/encoding
        // identities. Configuration and replacement share the same queue.
        const parameters = videoSender.getParameters()
        if (!Array.isArray(parameters?.encodings) || parameters.encodings.length !== 1 ||
            !parameters.encodings[0] || parameters.encodings[0].active === false) throw Error("unsupported encoding")
        parameters.encodings[0].maxBitrate = 1_200_000
        parameters.encodings[0].maxFramerate = 24
        await videoSender.setParameters(parameters)
        if (!current()) return
        if (!sendingVideo() || !live()) throw Error("unusable camera")
        profile()
        const readback = videoSender.getParameters()
        if (readback?.encodings?.length !== 1 || readback.encodings[0].active === false ||
            readback.encodings[0].maxBitrate !== 1_200_000 ||
            readback.encodings[0].maxFramerate !== 24) throw Error("unverified encoding")
        await videoSender.replaceTrack(track)
        if (!current()) return
        if (!sendingVideo() || !live() || videoSender.track !== track) throw Error("unusable camera")
        profile()
        attachedCamera = track
        publishCameraState("enabled")
      } catch (error) {
        if (!current()) return
        releaseCamera()
        onCamera("error", !live() ? "ended" : error?.code === "unsupported-profile" ? "unsupported-profile" : "incompatible-sender")
      }
    })
  }
  function renew() {
    if (!active || renewalPending) return
    renewalPending = true
    const {negotiation_id: _unused, ...session} = identity
    withDeadline(signaling.sendMedia("renew", session), 10_000, setTimeoutFn, clearTimeoutFn, abort.signal).then(reply => {
      if (!active) return
      if (!reply?.ok || !matches(reply, false)) { fail(); return }
      renewalPending = false
      schedule(renew, 30_000)
    }).catch(fail)
  }

  return {
    async connect({callId, track, cameraTrack = null}) {
      if (started) throw Error("Call connection already started")
      started = true; active = true
      if (cameraGeneration === 0) requestedCamera = cameraTrack
      onState("connecting")
      try {
        if (track?.kind !== "audio" || track.readyState !== "live") throw Error("live audio required")
        unsubscribeState = signaling.subscribe(state => {
          if (state.connectionStatus !== "connected" || state.callTopicStatus !== "joined" ||
              state.call?.call_id !== callId || state.call?.ownership !== "self" ||
              !["connecting", "active"].includes(state.call?.state) ||
              (identity && signaling.mediaSessionIsCurrent?.(identity) === false)) { fail(); return }
          const remote = state.call?.media_state?.[state.call.role === "caller" ? "recipient" : "caller"]
          if (remote?.camera_enabled === false) remoteOffVersion = Math.max(remoteOffVersion, remote.media_state_version ?? -1)
        })
        ensureActive()
        const credentials = await withDeadline(discoverCredentials(callId), 20_000,
          setTimeoutFn, clearTimeoutFn, abort.signal)
        ensureActive()
        if (!credentials?.ok || credentials.call_id !== callId ||
            !credentials.call_session_id || !credentials.signaling_session_id || credentials.negotiation_id) throw Error("invalid credentials")
        identity = {call_id: callId, call_session_id: credentials.call_session_id,
          signaling_session_id: credentials.signaling_session_id, negotiation_id: negotiationId()}
        const config = credentials.ice_config
        if (!config || !["disabled", "standard", "turn_only"].includes(config.ice_mode) ||
            !Array.isArray(config.ice_servers) || !["all", "relay"].includes(config.ice_transport_policy)) throw Error("invalid ICE")
        const iceServers = config.ice_servers.map(server => browserIceServer(server))
        if (config.ice_transport_policy === "relay" && (!iceServers.length || !iceServers.every(turnOnlyIceServer))) throw Error("invalid ICE")
        pc = new PeerConnection({iceServers, iceTransportPolicy: config.ice_transport_policy})
        audio = pc.addTransceiver(track, {direction: "sendrecv"})
        video = pc.addTransceiver("video", {direction: "sendrecv"})
        videoSender = video.sender
        for (const [transceiver, kind, mime] of [[audio, "audio", "audio/opus"], [video, "video", "video/vp8"]]) {
          const capabilities = codecCapabilities(kind)?.codecs ?? []
          if (!capabilities.some(codec => codec.mimeType?.toLowerCase() === mime) ||
              !transceiver.setCodecPreferences) throw Error("incompatible Call codecs")
          // Capabilities expose generic RTX, without an apt. Let the browser
          // associate it with the retained VP8 primary when creating its offer.
          const codecs = capabilities.filter(codec => codec.mimeType?.toLowerCase() === mime ||
            (kind === "video" && codec.mimeType?.toLowerCase() === "video/rtx"))
          transceiver.setCodecPreferences(codecs)
        }
        stream = new MediaStream()
        if (remoteAudio) { remoteAudio.autoplay = true; remoteAudio.playsInline = true; remoteAudio.muted = localDeafened; remoteAudio.srcObject = stream }
        bind("track", receiveTrack); bind("icecandidate", sendIce); bind("connectionstatechange", connectionChanged)
        unsubscribeIce = signaling.onServerIce(receiveMediaEvent)
        const offer = await pc.createOffer()
        ensureActive()
        await pc.setLocalDescription(offer)
        ensureActive()
        videoMid = video.mid
        const description = pc.localDescription?.toJSON?.() ?? pc.localDescription ?? offer
        if (typeof description.sdp !== "string" || new TextEncoder().encode(description.sdp).byteLength > 64 * 1024) throw Error("invalid offer")
        const answer = await withDeadline(signaling.sendMedia("offer", {...identity, description}), 10_000, setTimeoutFn, clearTimeoutFn, abort.signal)
        ensureActive()
        if (!answer?.ok || !matches(answer) || answer.description?.type !== "answer" ||
            typeof answer.description.sdp !== "string" || new TextEncoder().encode(answer.description.sdp).byteLength > 64 * 1024) throw Error("invalid answer")
        await pc.setRemoteDescription(answer.description)
        ensureActive()
        answerApplied = true
        if (mediaStateVersion === 0) mediaStateVersion = 1
        sendLocalState()
        for (const candidate of pending.splice(0)) { ensureActive(); await addCandidate(candidate) }
        pendingBytes = 0
        ensureActive()
        schedule(renew, 30_000)
        if (requestedCamera) attachPreparedCamera(requestedCamera)
      } catch (error) { if (active) fail(); else cleanup(); throw error }
    },
    setMuted(value) {
      if (abort.signal.aborted || typeof value !== "boolean" || value === localMuted) return
      if (mediaStateVersion === Number.MAX_SAFE_INTEGER) { fail(); return }
      localMuted = value
      mediaStateVersion += 1
      sendLocalState()
    },
    setDeafened(value) {
      if (abort.signal.aborted || typeof value !== "boolean") return
      localDeafened = value
      if (remoteAudio?.srcObject === stream && stream) remoteAudio.muted = value
    },
    attachCamera,
    releaseCamera,
    leave: cleanup,
    enableAudio: play,
  }
}
