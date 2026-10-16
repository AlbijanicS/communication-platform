import {browserIceServer, turnOnlyIceServer, candidateByteSize, withDeadline} from "./media_peer_helpers.js"

const MAX_PENDING_SERVER_CANDIDATES = 16
const MAX_PENDING_SERVER_CANDIDATE_BYTES = MAX_PENDING_SERVER_CANDIDATES * 8 * 1024
const OFFER_REPLY_TIMEOUT_MS = 10_000
const RENEWAL_INTERVAL_MS = 30_000
const RENEWAL_ACK_TIMEOUT_MS = 10_000
const RENEWAL_GRACE_MS = 75_000
const PEER_CONNECTION_RECOVERY_GRACE_MS = 30_000
const AUDIO_OUTPUT_SLOT_COUNT = 4
const INCOMPATIBLE_AUDIO_OUTPUT_SLOTS = "incompatible_audio_output_slots"

export function createVoicePeerAttempt({
  PeerConnection = globalThis.RTCPeerConnection,
  MediaStream = globalThis.MediaStream,
  negotiationId = createNegotiationId,
  now = () => globalThis.performance?.now?.() ?? Date.now(),
  onFailure = () => {},
  onCue = () => {},
  onPlayback = () => {},
  onState = () => {},
  remoteAudio = null,
  signaling,
  setTimeoutFn = globalThis.setTimeout,
  clearTimeoutFn = globalThis.clearTimeout,
} = {}) {
  let localVoiceState = {muted: false, deafened: false}
  let active = false
  let answerApplied = false
  let aggregatePlaybackStream = null
  let audioOutputSlots = []
  let peerConnection = null
  let sendingTransceiver = null
  let selectedIceTransport = null
  let pendingServerCandidates = []
  let pendingServerCandidateBytes = 0
  let signalingSessionId = null
  let signalingActive = false
  let currentNegotiationId = null
  let mediaState = "joining"
  let peerConnectionRecoveryDeadline = null
  let renewalAckTimeout = null
  let renewalDeadline = null
  let renewalInterval = null
  let controlPlaneInterrupted = false
  let lastRouteCategory = null
  let statsGeneration = 0

  function publishLocalVoiceState() {
    if (active && signalingSessionId) signaling?.sendLocalVoiceState?.(localVoiceState)
  }

  function fail(error = "connection_failed") {
    if (!active) return

    cleanup()
    onFailure(error)
  }

  function cleanup() {
    active = false
    statsGeneration += 1
    answerApplied = false
    pendingServerCandidates = []
    pendingServerCandidateBytes = 0
    clearRenewalTimers()
    clearPeerConnectionRecoveryDeadline()
    releaseRemoteAudio()
    selectedIceTransport?.removeEventListener?.("selectedcandidatepairchange", reportSelectedIceRoute)
    selectedIceTransport = null
    sendingTransceiver = null
    peerConnection?.close()
    peerConnection = null
    if (signalingActive) signaling?.leave()
    signalingActive = false
  }

  function clearRenewalTimers() {
    clearTimeoutFn(renewalAckTimeout)
    clearTimeoutFn(renewalDeadline)
    clearTimeoutFn(renewalInterval)
    renewalAckTimeout = null
    renewalDeadline = null
    renewalInterval = null
  }

  function clearPeerConnectionRecoveryDeadline() {
    clearTimeoutFn(peerConnectionRecoveryDeadline)
    peerConnectionRecoveryDeadline = null
  }

  function startPeerConnectionRecoveryDeadline() {
    if (peerConnectionRecoveryDeadline) return

    peerConnectionRecoveryDeadline = schedule(
      () => fail("connection_lost"),
      PEER_CONNECTION_RECOVERY_GRACE_MS
    )
  }

  function schedule(callback, delay) {
    const timeout = setTimeoutFn(callback, delay)
    timeout?.unref?.()
    return timeout
  }

  function publishConnectionState() {
    onState(controlPlaneInterrupted || mediaState === "disconnected" ? "interrupted" : mediaState)
  }

  function scheduleRenewal() {
    renewalInterval = schedule(() => {
      renewalInterval = null
      renewVoiceSession()
      if (active) scheduleRenewal()
    }, RENEWAL_INTERVAL_MS)
  }

  function setRenewalDeadline() {
    clearTimeoutFn(renewalDeadline)
    renewalDeadline = schedule(() => fail("connection_lost"), RENEWAL_GRACE_MS)
  }

  function receiveRenewalAcknowledgement(reply) {
    if (!active || reply?.signaling_session_id !== signalingSessionId) return

    clearTimeoutFn(renewalAckTimeout)
    renewalAckTimeout = null
    controlPlaneInterrupted = false
    publishLocalVoiceState()
    setRenewalDeadline()
    publishConnectionState()
  }

  function receiveVoiceSessionEnded(message) {
    if (!active || message?.signaling_session_id !== signalingSessionId) return

    fail("connection_lost")
  }

  function interruptControlPlane() {
    if (!active || controlPlaneInterrupted) return

    controlPlaneInterrupted = true
    publishConnectionState()
  }

  function renewVoiceSession() {
    if (!active || !signalingSessionId) return

    const renewal = signaling?.renewVoiceSession?.({signaling_session_id: signalingSessionId})
    clearTimeoutFn(renewalAckTimeout)
    renewalAckTimeout = schedule(interruptControlPlane, RENEWAL_ACK_TIMEOUT_MS)
    renewal?.receive?.("ok", receiveRenewalAcknowledgement)?.receive?.("error", () => fail("connection_lost"))
  }

  function startRenewals() {
    controlPlaneInterrupted = false
    setRenewalDeadline()
    scheduleRenewal()
  }

  async function playRemoteAudio() {
    if (!active || !remoteAudio?.srcObject) return

    try {
      await remoteAudio.play()
      if (active) onPlayback("playing")
    } catch (_) {
      if (active) onPlayback("blocked")
    }
  }

  function receiveRemoteTrack(event) {
    if (!active || !aggregatePlaybackStream || event?.track?.kind !== "audio") return

    const slot = audioOutputSlots.find(candidate =>
      candidate.transceiver === event.transceiver ||
      candidate.transceiver.receiver?.track === event.track
    )
    if (!slot || slot.track === event.track) return

    releaseSlotTrack(slot)
    slot.track = event.track
    slot.onEnded = () => releaseSlotTrack(slot, event.track)
    event.track.addEventListener?.("ended", slot.onEnded)
    aggregatePlaybackStream.addTrack(event.track)
    playRemoteAudio()
  }

  function releaseRemoteAudio() {
    audioOutputSlots.forEach(slot => releaseSlotTrack(slot))
    audioOutputSlots = []
    aggregatePlaybackStream = null

    if (!remoteAudio?.srcObject) return

    remoteAudio.pause?.()
    remoteAudio.srcObject = null
  }

  function releaseSlotTrack(slot, expectedTrack = slot.track) {
    if (!slot.track || slot.track !== expectedTrack) return

    slot.track.removeEventListener?.("ended", slot.onEnded)
    aggregatePlaybackStream?.removeTrack(slot.track)
    slot.track = null
    slot.onEnded = null
  }

  function constructPeerConnection(track, configuration) {
    try {
      if (!PeerConnection || !MediaStream) throw new Error("required WebRTC APIs are unavailable")

      peerConnection = new PeerConnection(configuration)
      if (typeof peerConnection.addTransceiver !== "function") {
        throw new Error("audio transceivers are unavailable")
      }

      sendingTransceiver = peerConnection.addTransceiver(track, {direction: "sendonly"})
      if (!sendingTransceiver?.sender) throw new Error("sending transceiver is unavailable")
      audioOutputSlots = Array.from({length: AUDIO_OUTPUT_SLOT_COUNT}, (_unused, index) => {
        const transceiver = peerConnection.addTransceiver("audio", {direction: "recvonly"})
        if (!transceiver?.receiver?.track || transceiver.receiver.track.kind !== "audio") {
          throw new Error(`audio output slot ${index} is unavailable`)
        }

        return {index, onEnded: null, track: null, transceiver}
      })

      aggregatePlaybackStream = new MediaStream()
      if (remoteAudio) {
        remoteAudio.autoplay = true
        remoteAudio.playsInline = true
        remoteAudio.srcObject = aggregatePlaybackStream
      }
    } catch (error) {
      const compatibilityError = new Error("four Audio Output Slots are required", {cause: error})
      compatibilityError.voiceFailure = INCOMPATIBLE_AUDIO_OUTPUT_SLOTS
      throw compatibilityError
    }
  }

  async function addServerCandidate(candidate) {
    try {
      await peerConnection?.addIceCandidate(candidate)
    } catch (_) {
      fail()
    }
  }

  function receiveServerIce(message) {
    if (
      !active ||
      message?.signaling_session_id !== signalingSessionId ||
      message?.negotiation_id !== currentNegotiationId ||
      (!message?.candidate && message?.end_of_candidates !== true)
    ) return

    const candidate = message.end_of_candidates === true ? {candidate: ""} : message.candidate
    const byteSize = message.end_of_candidates === true ? 0 : candidateByteSize(candidate)

    if (!answerApplied) {
      if (
        pendingServerCandidates.length < MAX_PENDING_SERVER_CANDIDATES &&
        pendingServerCandidateBytes + byteSize <= MAX_PENDING_SERVER_CANDIDATE_BYTES
      ) {
        pendingServerCandidates.push(candidate)
        pendingServerCandidateBytes += byteSize
      }
      return
    }

    addServerCandidate(candidate)
  }

  function handleConnectionStateChange() {
    if (!active) return

    if (peerConnection.connectionState === "connected") {
      mediaState = "connected"
      clearPeerConnectionRecoveryDeadline()
      publishConnectionState()
      observeSelectedPairChanges()
      reportSelectedIceRoute()
    }
    if (peerConnection.connectionState === "disconnected") {
      mediaState = "disconnected"
      startPeerConnectionRecoveryDeadline()
      publishConnectionState()
    }
    if (["failed", "closed"].includes(peerConnection.connectionState)) fail("connection_lost")
  }

  function observeSelectedPairChanges() {
    const iceTransport = sendingTransceiver?.sender?.transport?.iceTransport
    if (!iceTransport || iceTransport === selectedIceTransport) return

    selectedIceTransport?.removeEventListener?.("selectedcandidatepairchange", reportSelectedIceRoute)
    selectedIceTransport = iceTransport
    selectedIceTransport.addEventListener?.("selectedcandidatepairchange", reportSelectedIceRoute)
  }

  async function reportSelectedIceRoute() {
    const generation = ++statsGeneration
    const startedAt = now()
    let route = {route_category: "unknown", protocol: "unknown"}

    try {
      route = classifySelectedIceRoute(await peerConnection?.getStats?.())
    } catch (_) {
      // Unknown diagnostics must never disturb a working Voice connection.
    }

    if (!active || generation !== statsGeneration || route.route_category === lastRouteCategory) return

    lastRouteCategory = route.route_category
    signaling?.reportIceRoute?.({
      signaling_session_id: signalingSessionId,
      ...route,
      duration_ms: boundedDuration(now() - startedAt),
    })
  }

  function sendLocalIce(event) {
    if (!active || !event.candidate) return

    signaling.sendIce({
      signaling_session_id: signalingSessionId,
      negotiation_id: currentNegotiationId,
      candidate: event.candidate.toJSON?.() || event.candidate,
    })
  }

  function ensureActive() {
    if (!active) throw new Error("voice connection cancelled")
  }

  return {
    async connect({channelId, track}) {
      if (!signaling || !track) throw new Error("voice connection unavailable")

      active = true
      lastRouteCategory = null
      mediaState = "joining"
      onState("joining")

      try {
        signalingActive = true
        const joined = await signaling.joinVoiceChannel(channelId)
        ensureActive()

        const admission = voiceAdmission(joined)
        signalingSessionId = admission.signalingSessionId
        publishLocalVoiceState()
        currentNegotiationId = negotiationId()

        signaling.onServerIce(receiveServerIce)
        signaling.onClose(() => fail("connection_lost"))
        signaling.onVoiceSessionEnded?.(receiveVoiceSessionEnded)
        signaling.onRosterCue?.(payload => {
          if (active && payload?.channel_id === channelId && ["join", "leave"].includes(payload?.cue)) {
            onCue({channelId, cue: payload.cue})
          }
        })
        ensureActive()

        constructPeerConnection(track, admission.peerConfiguration)
        peerConnection.addEventListener("icecandidate", sendLocalIce)
        peerConnection.addEventListener("connectionstatechange", handleConnectionStateChange)
        peerConnection.addEventListener("track", receiveRemoteTrack)

        const offer = await peerConnection.createOffer()
        ensureActive()

        await peerConnection.setLocalDescription(offer)
        ensureActive()
        const answer = await withDeadline(
          signaling.sendOffer({
            signaling_session_id: signalingSessionId,
            negotiation_id: currentNegotiationId,
            description: peerConnection.localDescription || offer,
          }),
          OFFER_REPLY_TIMEOUT_MS,
          setTimeoutFn,
          clearTimeoutFn
        )
        ensureActive()

        if (
          answer?.signaling_session_id !== signalingSessionId ||
          answer?.negotiation_id !== currentNegotiationId ||
          answer?.description?.type !== "answer" ||
          typeof answer.description.sdp !== "string"
        ) throw new Error("invalid answer")

        await peerConnection.setRemoteDescription(answer.description)
        ensureActive()
        answerApplied = true

        for (const candidate of pendingServerCandidates) {
          await peerConnection.addIceCandidate(candidate)
        }
        pendingServerCandidates = []
        pendingServerCandidateBytes = 0
        startRenewals()
      } catch (error) {
        if (active) fail(voiceFailure(error))
        throw error
      }
    },

    leave() {
      if (active || peerConnection) cleanup()
    },

    enableAudio() {
      return playRemoteAudio()
    },

    setDeafened(deafened) {
      if (remoteAudio) remoteAudio.muted = deafened === true
    },

    updateLocalVoiceState(state) {
      localVoiceState = {muted: state.muted === true, deafened: state.deafened === true}
      publishLocalVoiceState()
    },
  }
}

function voiceAdmission(joined) {
  if (!plainObject(joined) || !exactKeys(joined, [
    "capacity",
    "ice_config",
    "occupancy",
    "signaling_session_id",
  ])) throw new Error("invalid Voice admission")

  const iceConfig = joined.ice_config
  if (
    typeof joined.signaling_session_id !== "string" ||
    joined.signaling_session_id.length === 0 ||
    !Number.isInteger(joined.occupancy) ||
    joined.occupancy < 0 ||
    !Number.isInteger(joined.capacity) ||
    joined.capacity <= 0 ||
    joined.occupancy > joined.capacity ||
    !plainObject(iceConfig) ||
    !exactKeys(iceConfig, ["ice_mode", "ice_servers", "ice_transport_policy"]) ||
    !["disabled", "standard", "turn_only"].includes(iceConfig.ice_mode) ||
    !Array.isArray(iceConfig.ice_servers) ||
    !["all", "relay"].includes(iceConfig.ice_transport_policy)
  ) throw new Error("invalid Voice admission")

  const iceServers = iceConfig.ice_servers.map(browserIceServer)
  if (
    iceConfig.ice_transport_policy === "relay" &&
    (iceServers.length === 0 || !iceServers.every(turnOnlyIceServer))
  ) throw new Error("invalid Voice admission")

  return {
    signalingSessionId: joined.signaling_session_id,
    peerConfiguration: {iceServers, iceTransportPolicy: iceConfig.ice_transport_policy},
  }
}

function classifySelectedIceRoute(report) {
  if (!report || typeof report.values !== "function" || typeof report.get !== "function") {
    return {route_category: "unknown", protocol: "unknown"}
  }

  const transports = [...report.values()].filter(item => item?.type === "transport" && item.selectedCandidatePairId)
  if (transports.length !== 1) return {route_category: "unknown", protocol: "unknown"}

  const pair = report.get(transports[0].selectedCandidatePairId)
  const local = pair?.type === "candidate-pair" ? report.get(pair.localCandidateId) : null
  const remote = pair?.type === "candidate-pair" ? report.get(pair.remoteCandidateId) : null
  if (local?.type !== "local-candidate" || remote?.type !== "remote-candidate") {
    return {route_category: "unknown", protocol: "unknown"}
  }

  const types = [local.candidateType, remote.candidateType]

  let route_category = "unknown"
  if (types.includes("relay")) route_category = "turn_relay"
  else if (types.some(type => ["srflx", "prflx"].includes(type))) route_category = "reflexive_direct"
  else if (types.every(type => type === "host")) route_category = "host_direct"

  const protocols = [local?.protocol, remote?.protocol]
  const protocol = protocols[0] === protocols[1] && ["udp", "tcp", "tls"].includes(protocols[0])
    ? protocols[0]
    : "unknown"

  return {route_category, protocol}
}

function boundedDuration(value) {
  return Number.isFinite(value) ? Math.max(0, Math.min(Math.round(value), 60_000)) : 0
}

function plainObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value)
}

function exactKeys(value, keys) {
  return Object.keys(value).sort().join("\0") === [...keys].sort().join("\0")
}

function voiceFailure(error) {
  if (error?.voiceFailure === INCOMPATIBLE_AUDIO_OUTPUT_SLOTS) return error.voiceFailure
  if (error?.reason === INCOMPATIBLE_AUDIO_OUTPUT_SLOTS) return error.reason
  return "connection_failed"
}

function createNegotiationId() {
  return globalThis.crypto?.randomUUID?.() || `${Date.now()}-${Math.random()}`
}
