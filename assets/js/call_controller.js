import {createCallVideoDiagnostics} from "./call_video_diagnostics.js"
import {combineCallCaptures} from "./call_devices.js"

const RESULT_COPY = {
  "permission-pending": "A previous microphone request is still pending. Dismiss the browser prompt, then retry.",
  "permission-denied": "Microphone access is blocked. Try again when you're ready.",
  "no-device": "No microphone is available.",
  "device-busy": "The microphone is busy. Try again when it is available.",
  "capture-unavailable": "Microphone capture is unavailable. Use a supported browser on a secure page, then retry.",
  "unknown-error": "Couldn't start the voice call.",
  busy: "That person is busy.",
  rate_limited: "You're calling too quickly. Try again shortly.",
  not_friends: "Calls require a current Friendship.",
  not_found: "That conversation isn't available.",
  temporarily_unavailable: "Calling is temporarily unavailable.",
  unavailable: "Calling is unavailable. Reconnect, then try again.",
  timeout: "The call didn't start in time. Try again.",
  cancelled: "Voice call cancelled.",
  ended: "The voice call ended.",
}

const CAMERA_COPY = {
  "permission-pending": "A previous camera request is still pending. Dismiss the browser prompt, then retry.",
  "permission-denied": "Camera access is blocked. Check browser and system camera settings, then retry when ready.",
  "no-device": "No camera is available. Connect a camera, then retry.",
  "unknown-error": "Couldn't start the camera. Retry when ready.",
  "device-busy": "The camera is busy or couldn't be read. Close other camera apps, then retry.",
  "unsupported-profile": "The camera settings are unsupported. Try another camera, then retry.",
  "capture-unavailable": "Camera capture is unavailable. Use a supported browser on a secure page, then retry.",
  ended: "The camera stopped. Retry when ready.",
  "incompatible-sender": "The camera could not attach to this call. Audio can continue.",
}

const VIDEO_RESULT_COPY = {
  "unknown-error": "Couldn't start the video call.",
  cancelled: "Video call cancelled.",
  ended: "The video call ended.",
}

const TERMINAL_COPY = {
  declined: "The call was declined.",
  cancelled: "The call was cancelled.",
  timed_out: "The call wasn't answered.",
  relationship_ended: "The call ended because the Friendship changed.",
  failed_capacity: "The call couldn't start because capacity is unavailable.",
  failed: "The call couldn't connect.",
  interrupted: "The call was interrupted.",
  ended: "The call ended.",
}

export const CALL_RESULT_DISPLAY_MS = 5_000

const NOOP_CUES = Object.freeze({contend() {}, withdraw() {}, dispose() {}})

const START_ERRORS = new Set([
  "permission-pending",
  "busy",
  "rate_limited",
  "not_friends",
  "not_found",
  "temporarily_unavailable",
  "unavailable",
  "timeout",
  "permission-denied",
  "no-device",
  "device-busy",
  "unsupported-profile",
  "capture-unavailable",
  "unknown-error",
  "cancelled",
  "ended",
])

export function createCallController({
  signaling,
  devices,
  videoAvailable = devices?.videoAvailable !== false,
  cues,
  scheduleResultDismissal = defaultSchedule,
  cancelResultDismissal = clearTimeout,
  resultDisplayMs = CALL_RESULT_DISPLAY_MS,
  onCaptureEnded = () => {},
  createPeerAttempt,
  diagnosticWrite,
} = {}) {
  const observeVideo = createCallVideoDiagnostics({write: diagnosticWrite})
  const cueSystem = cues ?? NOOP_CUES
  let cameraOperationGeneration = 0
  let cameraRequest = null
  let cameraCapture = null
  let mediaAttempt = null
  let mediaConnectionState = "idle"
  let playbackState = "waiting"
  let localMuted = false
  let localDeafened = false
  let disposed = false
  let actionGeneration = 0
  let capture = null
  let unsubscribeMicrophone = null
  let unsubscribeCamera = null
  let captureEnded = false
  let activeConversation = null
  let mediaIntent = null
  let resultCode = null
  let failedDevice = null
  let lastCallId = signaling?.getState?.()?.call?.call_id ?? null
  let acceptedCallId = null
  let currentStart = null
  let adoptedCall = null
  let ignoredCallId = null
  let fallbackPreparation = null
  const attemptedMediaCallIds = new Set()
  let currentAccept = null
  let recipientPreparation = null
  let recipientDeadlineTimer = null
  let pendingAcceptExit = null
  let recipientError = null
  let recipientFailedDevice = null
  let recipientCommand = null
  let leaveError = null
  let declineInFlightCallId = null
  let leaveInFlightCallId = null
  let resultTimer = null
  let terminalResultId = null
  let requestedCue = null
  const starts = []
  const cancels = new Map()
  const suppressedCallIds = new Set()
  const retiredCallIds = new Set()
  const dismissedTerminalIds = new Set()
  const listeners = new Set()

  const unsubscribeSignaling = signaling?.subscribe(onSignaling) ?? (() => {})

  function getState() {
    return freezeState(derive())
  }

  function subscribe(listener) {
    listeners.add(listener)
    listener(getState())
    return () => listeners.delete(listener)
  }

  function startCall(conversation, intent) {
    startCallerPreparation(conversation, intent)
  }

  function startCallerPreparation(conversation, intent, retained = null) {
    if (disposed || !conversation?.id || (intent !== "audio" && intent !== "video")) return
    if (intent === "video" && !videoAvailable) return
    if (derive().presentation === "outgoing_ringing") return
    if (currentStart?.acquire && currentStart.conversationId === conversation.id &&
        currentStart.intent === intent) return

    const generation = beginAction()
    if (!retained) releaseCapture()
    resultCode = null
    failedDevice = null
    activeConversation = freezeConversation(conversation)
    mediaIntent = intent
    adoptedCall = null
    const action = {
      generation,
      conversationId: conversation.id,
      intent,
      reusedMicrophone: Boolean(retained),
      signalingSessionId: currentSignaling().signalingSessionId,
      cancel: false,
      expectsReply: false,
      acked: false,
      callId: null,
      acquire: null,
      starting: false,
      cancelConsumed: false,
    }
    currentStart = action
    starts.push(action)
    if (retained) retainCapture(retained, action)
    publish()
    if (retained && (generation !== actionGeneration || capture !== retained ||
        microphoneSource(retained)?.live === false)) return

    const acquire = retained
      ? acquireWithMicrophone(retained, action)
      : devices.acquire(intent === "video" ? {audio: true, video: true} : {audio: true, video: false})
    action.acquire = acquire
    publish()

    acquire.promise.then(result => {
      if (generation !== actionGeneration || disposed || currentSignaling().signalingSessionId !== action.signalingSessionId) {
        result.capture?.release()
        return
      }

      action.acquire = null

      const microphoneLive = microphoneSource(result.capture)?.live !== false
      const cameraLive = intent !== "video" || cameraReady(result.capture)
      if (!result.ok || !microphoneLive || !cameraLive) {
        const cameraFailure = microphoneLive && (result.device === "camera" || (result.ok && !cameraLive))
        if (cameraFailure && result.capture) {
          result.capture.camera?.release()
          retainCapture(result.capture, action)
        } else result.capture?.release()
        ignoredCallId = null
        action.acked = true
        flushDeferredCancels(null)
        if (result.error === "cancelled") {
          resultCode = null
          failedDevice = null
          publish()
          return
        }

        resultCode = normalizeError(!microphoneLive || (result.ok && !cameraLive) ? "ended" : result.error)
        failedDevice = cameraFailure ? "camera" : "microphone"
        publish()
        return
      }

      retainCapture(result.capture, action)
      action.starting = true
      publish()

      if (generation !== actionGeneration || disposed || !capture || microphoneSource(capture)?.live === false) {
        action.starting = false
        publish()
        return
      }
      if (intent === "video" && !cameraReady(capture)) {
        releaseOwnedCamera()
        action.starting = false
        action.acked = true
        resultCode = "ended"
        failedDevice = "camera"
        publish()
        return
      }
      const sig = currentSignaling()
      if (sig.connectionStatus !== "connected" || sig.signalingSessionId !== action.signalingSessionId ||
          sig.call?.role === "recipient" || sig.call?.ownership === "elsewhere") {
        action.starting = false
        releaseCapture()
        publish()
        return
      }
      action.expectsReply = true
      const pendingReply = signaling.startCall({
        directConversationId: action.conversationId,
        mediaIntent: action.intent,
      })

      return Promise.resolve(pendingReply).then(reply => {
        action.expectsReply = false
        if (generation !== actionGeneration || disposed) {
          if (!disposed) applyStartReplyToAction(action, reply)
          return
        }

        action.starting = false
        action.acked = true

        if (!reply?.ok) {
          // A delivered projection is a committed fact even when the wire
          // reply fails. Camera loss must not discard its live microphone.
          const call = currentSignaling().call
          if (action.callId === call?.call_id && call?.role === "caller" &&
              ownsCall(call) && ["ringing", "connecting", "active"].includes(call.state)) {
            flushDeferredCancels(action.callId)
            if (action.cancel) requestCancelForAction(action)
            publish()
            return
          }
          if (cameraCommitUnconfirmed(action, reply)) {
            action.awaitingCommit = true
            action.starting = true
            action.acked = false
            publish()
            return
          }
          releaseCapture()
          ignoredCallId = null
          resultCode = normalizeError(reply?.error)
          flushDeferredCancels(null)
          publish()
          return
        }

        if (reply.call?.call_id) {
          action.callId = reply.call.call_id
          adoptCommittedIntent(reply.call)
          if (!retiredCallIds.has(reply.call.call_id)) {
            adoptedCall = reply.call
            if (ignoredCallId === reply.call.call_id) ignoredCallId = null
            lastCallId = reply.call.call_id
          }
        }
        flushDeferredCancels(action.callId)
        if (action.cancel) requestCancelForAction(action)
        publish()
      })
    })
  }

  function acquireWithMicrophone(retained, action) {
    if ((action.intent ?? action.answerMode) === "audio") {
      retained.camera?.release()
      return {promise: Promise.resolve({ok: true, capture: retained}), cancel() {}}
    }
    const acquisition = devices.acquire({audio: false, video: true})
    return {
      cancel: () => acquisition.cancel(),
      promise: acquisition.promise.then(result => {
        if (disposed || action.generation !== actionGeneration || capture !== retained ||
            currentSignaling().signalingSessionId !== action.signalingSessionId ||
            microphoneSource(retained)?.live === false) {
          result.capture?.release()
          return {ok: false, error: "cancelled"}
        }
        if (!result.ok) {
          result.capture?.release()
          return {...result, device: "camera", capture: retained}
        }
        return {ok: true, capture: combineCallCaptures(retained, result.capture)}
      }),
    }
  }

  function cancelCall() {
    if (disposed) return

    const state = derive()
    if (state.call?.ownership === "elsewhere") return

    if (currentAccept?.acquire || recipientPreparation) {
      invalidateRecipientWork()
      recipientError = null
      recipientFailedDevice = null
      recipientCommand = null
      publish()
      return
    }

    if (state.presentation === "result" && failedDevice === "camera") {
      beginAction()
      releaseCapture()
      resultCode = "cancelled"
      failedDevice = null
      publish()
      return
    }

    if (state.presentation === "preflighting" && currentStart?.starting) {
      currentStart.cancel = true
      beginAction()
      releaseCapture()
      resultCode = null
      failedDevice = null
      publish()
      return
    }

    if (state.presentation === "preflighting") {
      beginAction()
      releaseCapture()
      resultCode = null
      failedDevice = null
      ignoredCallId = null
      publish()
      return
    }

    if (state.presentation === "outgoing_ringing" && state.call?.call_id) {
      if (currentStart) {
        currentStart.cancel = true
        currentStart.cancelConsumed = true
      }
      releaseCapture()
      requestCancel(state.call.call_id, {suppress: false})
    }
  }

  function acceptCall(answerMode) {
    if (disposed || !["audio", "video"].includes(answerMode) || currentAccept) return
    if (answerMode === "video" && !videoAvailable) return
    const state = derive()
    const call = state.call
    if (recipientPreparation && !reusableRecipientCapture()) {
      invalidateRecipientWork()
      publish()
    }
    if (
      state.presentation !== "incoming_ringing" ||
      currentSignaling().callTopicStatus !== "joined" ||
      !call?.call_id ||
      call.role !== "recipient" ||
      call.state !== "ringing" ||
      declineInFlightCallId ||
      !recipientInvitationEligible(call) ||
      !validRecipientAnswer(call.media_intent, answerMode)
    ) return

    const retained = reusableRecipientCapture()
    const generation = beginAction()
    recipientPreparation = null
    if (!retained) releaseCapture()
    recipientError = null
    recipientFailedDevice = null
    recipientCommand = null
    const action = {
      generation,
      callId: call.call_id,
      signalingSessionId: currentSignaling().signalingSessionId,
      answerMode,
      acquire: null,
      commandInFlight: false,
    }
    currentAccept = action
    if (retained) retainCapture(retained, action)
    action.acquire = retained ? acquireWithMicrophone(retained, action) :
      devices.acquire({audio: true, video: answerMode === "video"})
    watchRecipientPreparationDeadline(action, call.ringing_deadline_at)
    publish()

    action.acquire.promise.then(result => {
      if (!currentAcceptActionIsCurrent(action) || !recipientInvitationEligible(currentSignaling().call)) {
        result.capture?.release()
        if (currentAccept === action) {
          invalidateRecipientWork()
          publish()
        }
        return
      }
      action.acquire = null

      const microphoneLive = microphoneSource(result.capture)?.live !== false
      const cameraLive = answerMode !== "video" || cameraReady(result.capture)
      if (!result.ok || !microphoneLive || !cameraLive) {
        const cameraFailure = microphoneLive && (result.device === "camera" || (result.ok && !cameraLive))
        if (cameraFailure && result.capture) {
          result.capture.camera?.release()
          retainCapture(result.capture, action)
          recipientPreparation = action
        } else {
          result.capture?.release()
          clearRecipientPreparationDeadline()
        }
        currentAccept = null
        recipientError = normalizeError(!microphoneLive || (result.ok && !cameraLive) ? "ended" : result.error)
        recipientFailedDevice = cameraFailure ? "camera" : "microphone"
        recipientCommand = null
        publish()
        return
      }

      retainCapture(result.capture, action)
      publish()
      if (!currentAcceptActionIsCurrent(action) || !recipientInvitationEligible(currentSignaling().call)) {
        if (currentAccept === action) invalidateRecipientWork()
        publish()
        return
      }
      if (!capture || microphoneSource(capture)?.live === false) {
        invalidateRecipientWork()
        recipientError = "ended"
        recipientFailedDevice = "microphone"
        publish()
        return
      }
      if (answerMode === "video" && !cameraReady(capture)) {
        capture.camera?.release()
        currentAccept = null
        recipientPreparation = action
        recipientError = "ended"
        recipientFailedDevice = "camera"
        publish()
        return
      }
      action.commandInFlight = true
      clearRecipientPreparationDeadline()
      return Promise.resolve(signaling.acceptCall({
        callId: action.callId,
        answerMode: action.answerMode,
      }))
        .then(reply => {
          // Decline can invalidate preparation while acceptance still commits.
          // Its exact exit obligation outlives that local action.
          if (pendingAcceptExit === action) {
            if (reply?.ok && reply.call?.call_id === action.callId &&
                currentSignaling().signalingSessionId === action.signalingSessionId) {
              requestLeaveCall(reply.call)
            } else if (!reply?.ok && !["timeout", "unavailable"].includes(reply?.error)) {
              pendingAcceptExit = null
            }
          }
          if (!currentAcceptActionIsCurrent(action)) return
          if (action.captureLost) {
            currentAccept = null
            publish()
            return
          }
          if (!reply?.ok) {
            if (cameraCommitUnconfirmed(action, reply)) {
              action.awaitingCommit = true
              publish()
              return
            }
            releaseCapture()
            currentAccept = null
            recipientError = normalizeError(reply?.error)
            recipientFailedDevice = null
            recipientCommand = "accept"
            publish()
          }
        })
    })
  }

  function declineCall() {
    if (disposed) return
    const call = derive().call
    if (
      !call?.call_id ||
      call.ownership === "elsewhere" ||
      call.role !== "recipient" ||
      call.state !== "ringing" ||
      declineInFlightCallId === call.call_id
    ) return

    // Decline releases preparation, but cannot roll back a dispatched accept.
    // Preserve its exact exit obligation if acceptance wins the server race.
    if (currentAccept?.commandInFlight) pendingAcceptExit = currentAccept
    invalidateRecipientWork()
    declineInFlightCallId = call.call_id
    recipientError = null
    recipientFailedDevice = null
    recipientCommand = null
    publish()
    Promise.resolve(signaling.declineCall({callId: call.call_id})).then(reply => {
      if (disposed || declineInFlightCallId !== call.call_id) return
      if (!reply?.ok) {
        declineInFlightCallId = null
        recipientError = normalizeError(reply?.error)
        recipientFailedDevice = null
        recipientCommand = "decline"
        publish()
      }
    })
  }

  function canPrepareFallback(sig = currentSignaling()) {
    return Boolean(createPeerAttempt && !disposed && sig.connectionStatus === "connected" &&
      sig.callTopicStatus === "joined" && sig.call?.state === "connecting" &&
      sig.call.role === "caller" && sig.call.ownership === "self" && !capture &&
      !captureEnded && !fallbackPreparation && !attemptedMediaCallIds.has(sig.call.call_id) &&
      leaveInFlightCallId !== sig.call.call_id)
  }

  function enableMicrophone() {
    if (!canPrepareFallback()) return
    const sig = currentSignaling()
    const action = {generation: beginAction(), callId: sig.call.call_id,
      signalingSessionId: sig.signalingSessionId, acquire: devices.acquire({audio: true, video: false})}
    attemptedMediaCallIds.add(action.callId)
    fallbackPreparation = action
    publish()
    action.acquire.promise.then(result => {
      const current = currentSignaling()
      if (disposed || fallbackPreparation !== action || action.generation !== actionGeneration ||
          current.call?.call_id !== action.callId || current.call?.ownership !== "self" ||
          current.signalingSessionId !== action.signalingSessionId || current.callTopicStatus !== "joined" ||
          current.call.state !== "connecting") {
        result.capture?.release()
        return
      }
      fallbackPreparation = null
      if (!result.ok || microphoneSource(result.capture)?.live === false) {
        result.capture?.release()
        captureEnded = true
        requestLeaveCall(current.call)
      } else {
        retainCapture(result.capture, action)
      }
      publish()
    })
  }

  function canMute() {
    const sig = currentSignaling()
    return Boolean(!disposed && mediaAttempt && microphoneTrack(capture) && microphoneSource(capture)?.live !== false &&
      sig.call?.ownership === "self" && sig.callTopicStatus === "joined" &&
      sig.connectionStatus === "connected" && ["connecting", "active"].includes(sig.call?.state) &&
      leaveInFlightCallId !== sig.call.call_id)
  }

  function canControlCamera() {
    return videoAvailable && canMute() && Boolean(mediaAttempt.peer?.attachCamera)
  }

  function cameraStatusText(state) {
    return {
      off: " Camera off.",
      preview_ready: " Camera preview ready; waiting for the call connection.",
      attaching: " Camera attaching.",
      enabled: " Camera attached.",
      interrupted: " Camera interrupted. Waiting for the camera source to resume.",
    }[state] ?? ""
  }

  function cameraWorking() {
    return Boolean(cameraRequest || capture?.camera?.live ||
      ["preview_ready", "attaching", "enabled"].includes(mediaAttempt?.cameraState))
  }

  function releaseOwnedCamera() {
    cameraOperationGeneration += 1
    cameraRequest?.cancel()
    cameraRequest = null
    unsubscribeCamera?.()
    unsubscribeCamera = null
    capture?.camera?.release()
    cameraCapture?.release()
    cameraCapture = null
    if (capture) capture.camera = null
  }

  function clearOwnedCamera() {
    releaseOwnedCamera()
    if (mediaAttempt) {
      mediaAttempt.cameraState = "off"
      mediaAttempt.cameraError = null
      mediaAttempt.peer?.releaseCamera?.()
    }
  }

  function turnCameraOff() {
    clearOwnedCamera()
    publish()
  }

  function toggleCamera() {
    if (!canControlCamera()) return
    if (cameraWorking()) { turnCameraOff(); return }
    const entry = mediaAttempt, prepared = capture
    const generation = ++cameraOperationGeneration
    const signalingSessionId = currentSignaling().signalingSessionId
    const current = () => canControlCamera() && mediaAttempt === entry && capture === prepared &&
      generation === cameraOperationGeneration && actionGeneration === entry.generation &&
      currentSignaling().call?.call_id === entry.callId &&
      currentSignaling().signalingSessionId === signalingSessionId
    const request = devices.acquire({audio: false, video: true})
    cameraRequest = request
    entry.cameraState = "pending"
    entry.cameraError = null
    publish()
    request.promise.then(result => {
      if (!current()) {result.capture?.release(); return}
      cameraRequest = null
      if (!result.ok || !result.capture?.camera?.live) {
        result.capture?.release()
        entry.cameraState = "error"
        entry.cameraError = normalizeError(result.ok ? "ended" : result.error)
        publish()
        return
      }
      cameraCapture = result.capture
      prepared.camera = result.capture.camera
      const camera = prepared.camera
      observeCamera(prepared, current, turnCameraOff)
      entry.cameraState = "preview_ready"
      publish()
      // Preview binding can synchronously trigger a source or owner change.
      if (current() && camera.live && prepared.camera === camera) entry.peer.attachCamera(camera.track)
      else if (current()) turnCameraOff()
    })
  }

  function toggleMute() {
    if (!canMute()) return
    localMuted = !localMuted
    applyLocalMediaState()
    publish()
  }

  function toggleDeafen() {
    if (!canMute()) return
    localDeafened = !localDeafened
    applyLocalMediaState()
    publish()
  }

  function applyLocalMediaState() {
    const effectiveMuted = localMuted || localDeafened
    microphoneTrack(capture).enabled = !effectiveMuted
    mediaAttempt.peer?.setMuted?.(effectiveMuted)
    mediaAttempt.peer?.setDeafened?.(localDeafened)
  }

  function canEnableAudio() {
    return canMute() && !localDeafened && mediaConnectionState === "connected" &&
      playbackState === "blocked"
  }

  function enableAudio() {
    if (canEnableAudio()) mediaAttempt.peer?.enableAudio()
  }

  function leaveCall() {
    requestLeaveCall(derive().call)
  }

  function requestLeaveCall(call) {
    if (disposed) return
    if (!call?.call_id || !["connecting", "active"].includes(call.state)) return
    if (currentSignaling().call?.call_id !== call.call_id) return
    if (!ownsCall(call)) return
    if (currentSignaling().call?.ownership === "elsewhere") return
    if (leaveInFlightCallId === call.call_id) return

    leaveInFlightCallId = call.call_id
    if (createPeerAttempt) {
      attemptedMediaCallIds.add(call.call_id)
      releaseCapture()
    }
    leaveError = null
    publish()
    Promise.resolve(signaling.leaveCall({callId: call.call_id})).then(reply => {
      if (disposed || leaveInFlightCallId !== call.call_id) return
      if (!reply?.ok) {
        leaveInFlightCallId = null
        leaveError = normalizeError(reply?.error)
        publish()
      }
    })
  }

  function cancelLocalPreparation() {
    if (disposed || !currentStart?.acquire) return

    beginAction()
    releaseCapture()
    resultCode = null
    failedDevice = null
    ignoredCallId = null
    publish()
  }

  function retry() {
    if (disposed || !activeConversation) return
    const retained = failedDevice === "camera" ? reusableCallerCapture() : null
    if (retained) startCallerPreparation(activeConversation, "video", retained)
    else startCall(activeConversation, mediaIntent || "audio")
  }

  function reusableCallerCapture() {
    const sig = currentSignaling()
    if (disposed || !currentStart || currentStart.generation !== actionGeneration ||
        currentStart.signalingSessionId !== sig.signalingSessionId || sig.connectionStatus !== "connected" ||
        sig.call || currentStart.callId || startCommitPending(currentStart) ||
        currentStart.conversationId !== activeConversation?.id || !capture ||
        microphoneSource(capture)?.live === false || capture.released) return null
    return capture
  }

  function fallbackToAudio() {
    if (disposed || !derive().canFallbackToAudio) return
    const retained = reusableCallerCapture()
    if (!retained) return
    startCallerPreparation(activeConversation, "audio", retained)
  }

  function dismiss() {
    if (disposed) return
    if (!derive().canDismiss) return

    if (terminalResultId) dismissedTerminalIds.add(terminalResultId)
    cancelResultTimer()
    terminalResultId = null
    releaseCapture()
    resultCode = null
    failedDevice = null
    activeConversation = null
    mediaIntent = null
    publish()
  }

  function suspend() {
    if (disposed) return
    const callId = currentSignaling().call?.call_id
    if (callId) attemptedMediaCallIds.add(callId)
    resetForTransportLoss(null)
  }

  function releaseCues() {
    if (disposed) return
    requestedCue = null
    try {
      cueSystem.withdraw?.()
    } catch (_) {}
  }

  function dispose() {
    if (disposed) return

    disposed = true
    pendingAcceptExit = null
    invalidateRecipientWork()
    beginAction()
    releaseCapture()
    cancelResultTimer()
    if (currentStart) currentStart.cancel = false
    cancels.clear()
    suppressedCallIds.clear()
    requestedCue = null
    try {
      cueSystem.dispose?.()
    } catch (_) {}
    unsubscribeSignaling()
    listeners.clear()
  }

  function onSignaling() {
    if (disposed) return

    const sig = currentSignaling()
    const callId = sig.call?.call_id ?? null
    if (recipientPreparation && !reusableRecipientCapture()) invalidateRecipientWork()
    if (currentAccept && !currentAccept.commandInFlight &&
        !recipientInvitationEligible(sig.call)) invalidateRecipientWork()
    const callerPreparing = currentStart && !currentStart.callId && (currentStart.acquire || capture)
    if (callerPreparing && (sig.signalingSessionId !== currentStart.signalingSessionId ||
        sig.call?.role === "recipient" || (sig.call && (failedDevice === "camera" || currentStart.reusedMicrophone) &&
          !startCommitPending(currentStart) && !belongsToOtherStart(callId)))) {
      beginAction()
      releaseCapture()
      resultCode = null
      failedDevice = null
    }
    if (["connecting", "active"].includes(sig.call?.state)) {
      acceptedCallId = callId
      if (sig.callTopicStatus === "failed") {
        attemptedMediaCallIds.add(callId)
        releaseCapture()
      }
    }
    if (currentAccept && (sig.callTopicStatus === "failed" ||
        sig.signalingSessionId !== currentAccept.signalingSessionId)) {
      pendingAcceptExit = null
      invalidateRecipientWork()
    }
    if (callId && callId !== lastCallId && !capture) captureEnded = false
    if (fallbackPreparation && (callId !== fallbackPreparation.callId ||
        sig.call?.ownership !== "self" || sig.call?.state !== "connecting" ||
        sig.signalingSessionId !== fallbackPreparation.signalingSessionId || sig.callTopicStatus !== "joined")) {
      releaseCapture()
    }

    if (pendingAcceptExit &&
        (callId !== pendingAcceptExit.callId ||
         sig.signalingSessionId !== pendingAcceptExit.signalingSessionId ||
         sig.call?.ownership === "elsewhere")) pendingAcceptExit = null

    if (sig.terminalCall?.call_id && !dismissedTerminalIds.has(sig.terminalCall.call_id)) {
      applyTerminalResult(sig.terminalCall)
      return
    }

    if (sig.connectionStatus === "unavailable") {
      resetForTransportLoss("unavailable")
      return
    }

    if (sig.connectionStatus === "disconnected") {
      resetForTransportLoss(null)
      return
    }

    if (callId && terminalResultId && callId !== terminalResultId) {
      cancelResultTimer()
      terminalResultId = null
      resultCode = null
    }

    if (lastCallId && callId && lastCallId !== callId) {
      if (currentAccept) invalidateRecipientWork()
      declineInFlightCallId = null
      leaveInFlightCallId = null
      recipientError = null
      recipientFailedDevice = null
      recipientCommand = null
      leaveError = null
    }

    if (callId && retiredCallIds.has(callId)) {
      maybeRetryOrRestoreCancel(sig)
      publish()
      return
    }

    if (ignoreSupersededProjection(callId)) {
      maybeRetryOrRestoreCancel(sig)
      publish()
      return
    }

    if (lastCallId && callId && lastCallId !== callId && shouldReleaseCaptureFor(callId)) {
      releaseCapture()
    }

    if (sig.call?.ownership === "elsewhere") {
      // Losing sibling contract: cancel pending preflight, drop late
      // acknowledgements, release capture, and stop local mutation work.
      invalidateRecipientWork()
      if (currentStart?.acquire) beginAction()
      releaseCapture()
      declineInFlightCallId = null
      leaveInFlightCallId = null
      recipientError = null
      recipientFailedDevice = null
      recipientCommand = null
      leaveError = null
    }

    if (sig.call?.role === "recipient" && sig.call.state === "ringing") {
      activeConversation = conversationFromProjection(sig.call)
      mediaIntent = sig.call.media_intent
      lastCallId = callId
      publish()
      return
    }

    if (["connecting", "active"].includes(sig.call?.state)) {
      if (currentStart && sig.call.role === "caller" && startForProjection(callId) === currentStart) {
        currentStart.callId = callId
        currentStart.awaitingCommit = false
        currentStart.starting = false
        currentStart.acked = true
      }
      const lostAccept = pendingAcceptExit?.callId === callId
      const lostStart = (currentStart?.captureLost || currentStart?.cancel) &&
        currentStart.callId === callId && currentStart.signalingSessionId === sig.signalingSessionId
      if ((lostAccept || lostStart) && ownsCall(sig.call) && sig.callTopicStatus === "joined") leaveCall()
      currentAccept = null
      declineInFlightCallId = null
      recipientError = null
      recipientFailedDevice = null
      recipientCommand = null
      leaveError = null
      activeConversation = conversationFromProjection(sig.call) ?? activeConversation
      mediaIntent = sig.call.media_intent ?? mediaIntent
      resultCode = null
      lastCallId = callId
      publish()
      return
    }

    if (sig.call?.role === "caller" && sig.call.state === "ringing") {
      if (currentStart?.acquire) {
        beginAction()
        releaseCapture()
      }

      const owner = startForProjection(callId)
      if (owner?.cancel && !adoptedByLiveStart(callId)) {
        owner.callId = callId
        requestCancelForAction(owner)
        maybeRetryOrRestoreCancel(sig)
        lastCallId = callId
        publish()
        return
      }

      if (owner === currentStart || canAdoptProjection(callId)) {
        adoptedCall = sig.call
        adoptCommittedIntent(sig.call)
        if (currentStart) {
          currentStart.acked = true
          currentStart.callId = callId
          currentStart.awaitingCommit = false
          currentStart.starting = false
        }
      }
      if (ignoredCallId === callId) ignoredCallId = null
      flushDeferredCancels(callId)

      if (suppressedCallIds.has(callId)) {
        maybeRetryOrRestoreCancel(sig)
        lastCallId = callId
        publish()
        return
      }

      if (currentStart?.cancel && currentStart.callId === callId) {
        requestCancelForAction(currentStart)
        maybeRetryOrRestoreCancel(sig)
        publish()
        return
      }

      resultCode = null
      lastCallId = callId
      publish()
      return
    }

    if (lastCallId && !callId) {
      retiredCallIds.add(lastCallId)
      if (currentStart && !currentStart.acked) {
        if (adoptedCall?.call_id === lastCallId) adoptedCall = null
        lastCallId = currentStart.callId
        publish()
        return
      }

      const cancelled =
        suppressedCallIds.has(lastCallId) ||
        Boolean(currentStart?.cancel && currentStart.callId === lastCallId)
      releaseCapture()
      resultCode = cancelled ? "cancelled" : "ended"
      failedDevice = null
      cancels.delete(lastCallId)
      suppressedCallIds.delete(lastCallId)
      lastCallId = null
      adoptedCall = null
      ignoredCallId = null
      if (currentStart) {
        currentStart.starting = false
        currentStart.acquire = null
      }
      publish()
      return
    }

    lastCallId = callId
    maybeRetryOrRestoreCancel(sig)
    publish()
  }

  function derive() {
    const sig = currentSignaling()
    const call = visibleCall(sig)
    const presentation = presentationFor(sig, call)
    const terminalCall = currentSignaling().terminalCall
    const peerName = call?.peer?.username ?? terminalCall?.peer?.username ?? activeConversation?.peer?.username ?? null

    const remoteVideoState = mediaAttempt?.remoteVideoBinding?.isCurrent() === false
      ? "loading" : mediaAttempt?.remoteVideoState ?? "loading"
    const displayedIntent = displayedMediaIntent(call, mediaIntent)
    const awaitingCommit = (presentation === "preflighting" && currentStart?.awaitingCommit) ||
      (presentation === "incoming_preflighting" && currentAccept?.awaitingCommit)

    return {
      presentation,
      captureEnded,
      mediaConnectionState,
      playbackState,
      localMuted,
      localDeafened,
      canMute: canMute(),
      canDeafen: canMute(),
      canEnableAudio: canEnableAudio(),
      canControlCamera: canControlCamera(),
      cameraWorking: cameraWorking(),
      connectionStatus: sig.connectionStatus,
      call,
      conversation: activeConversation,
      mediaIntent: displayedIntent,
      videoAvailable,
      microphoneReady: Boolean(capture && microphoneSource(capture)?.live !== false),
      cameraState: localCameraState(),
      cameraAttached: mediaAttempt?.cameraState === "enabled",
      cameraError: mediaAttempt?.cameraError ?? null,
      cameraPreviewTrack: capture?.camera?.live ? capture.camera.track ?? null : null,
      remoteVideoTrack: mediaAttempt?.remoteVideoTrack ?? null,
      remoteVideoBinding: mediaAttempt?.remoteVideoBinding ?? null,
      remoteVideoState: call?.media_state?.[call.role === "caller" ? "recipient" : "caller"]?.camera_enabled
        ? remoteVideoState : "off",
      remoteCameraEnabled: call?.media_state?.[call.role === "caller" ? "recipient" : "caller"]?.camera_enabled === true,
      resultCode: presentation === "unavailable" ? "unavailable" : resultCode,
      peerName,
      canEnableMicrophone: canPrepareFallback(sig),
      statusText: (awaitingCommit ? "Waiting to confirm the video call. Camera stopped; microphone ready." : (realStatusText(presentation, call) ?? statusTextFor(
        presentation,
        resultCode,
        peerName,
        displayedIntent,
        failedDevice,
        Boolean(call?.call_id && cancels.has(call.call_id) && !suppressedCallIds.has(call.call_id)),
        recipientError,
        recipientFailedDevice,
        recipientCommand,
        leaveError,
        currentAccept?.answerMode ?? null,
        Boolean(call?.call_id && leaveInFlightCallId === call.call_id),
        Boolean(terminalResultId),
        call?.ownership ?? null,
      ))) + (localCameraState() === "interrupted" || canControlCamera() ? cameraStatusText(localCameraState()) : "") + (mediaAttempt?.cameraError ? ` ${CAMERA_COPY[mediaAttempt.cameraError]}` : "") + (mediaAttempt?.cameraState === "pending" ? " Camera permission pending. Turn camera off to cancel preparation; the browser prompt may still need dismissal." : "") + (currentStart?.acquire || currentAccept?.acquire ?
        " Cancel stops preparation; the browser prompt may still need dismissal." : "") + (presentation === "result" && failedDevice === "camera" && capture ? " Microphone ready." : "") + (presentation === "incoming_ringing" && reusableRecipientCapture() ? " Microphone ready." : "") + (canMute() ? (localDeafened ? " Deafened. Audio silenced and microphone muted." :
        localMuted ? " Microphone muted." : "") : ""),
      canCancel:
        (presentation === "preflighting" || presentation === "outgoing_ringing" ||
          Boolean(currentAccept?.acquire || recipientPreparation) ||
          (presentation === "result" && failedDevice === "camera" && Boolean(capture))) &&
        !(call?.call_id && cancels.has(call.call_id)) &&
        (ownsCall(call) || recipientInvitationEligible(call)),
      canRetry: presentation === "result" || presentation === "unavailable",
      canDismiss:
        presentation === "result" ||
        (presentation === "unavailable" && sig.connectionStatus !== "unavailable"),
      canFallbackToAudio:
        presentation === "result" && displayedIntent === "video" && failedDevice === "camera" &&
        Boolean(reusableCallerCapture()),
      canAcceptAudio:
        presentation === "incoming_ringing" &&
        sig.callTopicStatus === "joined" &&
        recipientInvitationEligible(call) &&
        call?.media_intent === "audio" &&
        !currentAccept &&
        !declineInFlightCallId,
      canAcceptVideo:
        videoAvailable &&
        presentation === "incoming_ringing" &&
        sig.callTopicStatus === "joined" &&
        recipientInvitationEligible(call) &&
        call?.media_intent === "video" &&
        !currentAccept &&
        !declineInFlightCallId,
      canAnswerWithoutVideo:
        presentation === "incoming_ringing" &&
        sig.callTopicStatus === "joined" &&
        recipientInvitationEligible(call) &&
        call?.media_intent === "video" &&
        !currentAccept &&
        !declineInFlightCallId,
      canDecline:
        ["incoming_ringing", "incoming_preflighting"].includes(presentation) &&
        !declineInFlightCallId,
      canLeave:
        ["connecting", "active"].includes(presentation) &&
        !leaveInFlightCallId &&
        ownsCall(call),
      busy: Boolean(call) || presentation === "preflighting" || presentation === "outgoing_ringing",
    }
  }

  function realStatusText(presentation, call) {
    if (!createPeerAttempt || !["connecting", "active"].includes(presentation)) return null
    if (leaveError) return "Couldn't leave the call. Try again."
    if (leaveInFlightCallId === call?.call_id) return "Leaving…"
    if (fallbackPreparation) return "Preparing microphone…"
    if (canPrepareFallback()) return "Awaiting microphone. Enable your microphone to connect."
    if (captureEnded) return "The microphone stopped. Ending the call…"
    if (!capture && attemptedMediaCallIds.has(call?.call_id)) {
      return "Call interrupted. Waiting for the call to end."
    }
    if (mediaConnectionState === "interrupted") return "Connection interrupted. Waiting to reconnect…"
    if (presentation === "connecting") {
      return call?.role === "recipient" && mediaConnectionState === "connected"
        ? "Waiting for the caller's microphone and connection…"
        : "Connecting call…"
    }
    if (mediaConnectionState !== "connected") return "Connecting audio…"
    if (playbackState === "blocked") return localDeafened ? "Call connected." :
      "Call connected. Audio playback is blocked. Select Play audio to hear the call."
    return playbackState === "playing" ? "Call connected." : "Call connected. Waiting for audio…"
  }

  // preflighting is device acquire OR an in-flight start_call. Only acquire is
  // local preparation; starting already committed a Call Attempt on the server.
  function presentationFor(sig, call) {
    if (disposed) return "idle"
    if (sig.connectionStatus === "unavailable" || resultCode === "unavailable") return "unavailable"
    if (call?.ownership === "elsewhere" && !callerRingingFromAnotherTab(call)) {
      return "owned_elsewhere"
    }
    if (
      call?.role === "caller" &&
      call.state === "ringing" &&
      !suppressedCallIds.has(call.call_id)
    ) {
      return "outgoing_ringing"
    }
    if (
      call?.role === "recipient" &&
      call.state === "ringing" &&
      ["audio", "video"].includes(call.media_intent)
    ) {
      return currentAccept ? "incoming_preflighting" : "incoming_ringing"
    }
    if (call?.state === "connecting") return "connecting"
    if (call?.state === "active") return "active"
    if (currentStart?.acquire || currentStart?.starting) return "preflighting"
    if (resultCode) return "result"
    return "idle"
  }

  function currentSignaling() {
    const sig = signaling?.getState?.() ?? {}
    return {
      connectionStatus: sig.connectionStatus ?? "disconnected",
      signalingSessionId: sig.signalingSessionId ?? null,
      call: sig.call ?? null,
      terminalCall: sig.terminalCall ?? null,
      callTopicStatus: sig.callTopicStatus ?? "idle",
    }
  }

  function beginAction() {
    actionGeneration += 1
    currentStart?.acquire?.cancel()
    if (currentStart) {
      currentStart.acquire = null
      currentStart.starting = false
    }
    return actionGeneration
  }

  function currentAcceptActionIsCurrent(action) {
    return currentAccept === action && recipientActionIsCurrent(action)
  }

  function cameraCommitUnconfirmed(action, reply) {
    return Boolean(action.cameraLost && ["timeout", "unavailable"].includes(reply?.error) &&
      capture && microphoneSource(capture)?.live !== false &&
      currentSignaling().connectionStatus === "connected")
  }

  function recipientActionIsCurrent(action, sig = currentSignaling()) {
    return (
      !disposed &&
      Boolean(action) &&
      action.generation === actionGeneration &&
      sig.call?.call_id === action.callId &&
      sig.signalingSessionId === action.signalingSessionId &&
      sig.connectionStatus === "connected" && sig.callTopicStatus === "joined"
    )
  }

  function recipientInvitationEligible(call) {
    return Boolean(call?.role === "recipient" && call.state === "ringing" &&
      (!call.ownership || ["unclaimed", "self"].includes(call.ownership)) &&
      (!call.ringing_deadline_at || Date.parse(call.ringing_deadline_at) > Date.now()))
  }

  function reusableRecipientCapture() {
    const sig = currentSignaling()
    const action = recipientPreparation
    if (!recipientActionIsCurrent(action, sig) || !recipientInvitationEligible(sig.call) ||
        !capture || capture.released || microphoneSource(capture)?.live === false) return null
    return capture
  }

  function invalidateRecipientWork() {
    clearRecipientPreparationDeadline()
    recipientPreparation = null
    if (currentAccept) {
      currentAccept.acquire?.cancel()
      currentAccept = null
      actionGeneration += 1
    }
    releaseCapture()
  }

  function clearRecipientPreparationDeadline() {
    if (recipientDeadlineTimer != null) clearTimeout(recipientDeadlineTimer)
    recipientDeadlineTimer = null
  }

  function watchRecipientPreparationDeadline(action, deadlineAt) {
    clearRecipientPreparationDeadline()
    const deadline = Date.parse(deadlineAt)
    if (!Number.isFinite(deadline)) return
    // This is the original invitation deadline, never a device timeout. Cap
    // long delays at the browser timer limit without bringing expiry forward.
    const timer = defaultSchedule(() => {
      if (recipientDeadlineTimer !== timer) return
      recipientDeadlineTimer = null
      if (!recipientActionIsCurrent(action) ||
          (currentAccept !== action && recipientPreparation !== action)) return
      if (Date.now() < deadline) {
        watchRecipientPreparationDeadline(action, deadlineAt)
        return
      }
      invalidateRecipientWork()
      recipientError = null
      recipientFailedDevice = null
      publish()
    }, Math.min(Math.max(0, deadline - Date.now()), 2_147_483_647))
    recipientDeadlineTimer = timer
  }

  // Owned sources keep camera lifetime changes outside the parent audio action.
  // Retain compatibility with the existing audio-only injected adapters.
  function microphoneSource(prepared) {
    return prepared?.microphone ?? prepared
  }

  function microphoneTrack(prepared) {
    return prepared?.microphone ? prepared.microphone.track : prepared?.audioTrack
  }

  function cameraReady(prepared) {
    // Flat injected fixtures predate separate source handles.
    return prepared?.camera ? prepared.camera.live !== false : prepared?.video === true && !prepared?.microphone
  }

  function localCameraState() {
    if (capture?.camera?.interrupted) return "interrupted"
    return mediaAttempt?.cameraState ?? (capture?.camera?.live ? "preview_ready" : "off")
  }

  function observeCamera(prepared, current, onEnded) {
    unsubscribeCamera?.()
    const camera = prepared.camera
    const valid = () => !disposed && capture === prepared && prepared.camera === camera && current()
    const ended = camera?.onEnded?.(() => { if (valid()) onEnded() })
    const interruption = camera?.onInterruption?.(() => { if (valid()) publish() })
    unsubscribeCamera = () => { ended?.(); interruption?.() }
  }

  function retainCapture(prepared, action) {
    unsubscribeMicrophone?.()
    unsubscribeCamera?.()
    unsubscribeMicrophone = null
    unsubscribeCamera = null
    capture = prepared
    captureEnded = false
    const microphone = microphoneSource(prepared)
    unsubscribeMicrophone = microphone?.onEnded?.(() => {
      if (disposed || capture !== prepared || microphoneSource(capture) !== microphone ||
          action.generation !== actionGeneration) return
      captureEnded = true
      const call = derive().call
      releaseCapture()
      if (["connecting", "active"].includes(call?.state)) {
        requestLeaveCall(call)
        onCaptureEnded({callId: call.call_id, generation: action.generation})
      } else if (action === currentAccept || action === recipientPreparation) {
        recipientPreparation = null
        action.acquire?.cancel()
        action.captureLost = true
        if (action.commandInFlight) pendingAcceptExit = action
        recipientError = "ended"
        recipientFailedDevice = "microphone"
        if (!action.commandInFlight) currentAccept = null
      } else if (action === currentStart) {
        if (action.acquire && !action.expectsReply) {
          beginAction()
          action.acked = true
        }
        action.cancel = true
        action.captureLost = true
        resultCode = "ended"
        failedDevice = "microphone"
        if (call?.call_id && ownsCall(call)) {
          action.callId = call.call_id
          requestCancelForAction(action)
        }
      }
      publish()
    })
    observeCamera(prepared, () => action.generation === actionGeneration, () => {
      clearOwnedCamera()
      if (action.expectsReply || action.commandInFlight) action.cameraLost = true
      if (action === currentStart && !startCommitPending(action) && !action.acked && !derive().call) {
        action.starting = false
        action.acked = true
        resultCode = "ended"
        failedDevice = "camera"
      }
      if (action === currentAccept && !action.commandInFlight) {
        currentAccept = null
        recipientPreparation = action
        recipientError = "ended"
        recipientFailedDevice = "camera"
      }
      publish()
    })
  }

  function releaseCapture() {
    clearRecipientPreparationDeadline()
    fallbackPreparation?.acquire?.cancel()
    fallbackPreparation = null
    releaseOwnedCamera()
    releasePeer()
    unsubscribeMicrophone?.()
    unsubscribeMicrophone = null
    unsubscribeCamera?.()
    unsubscribeCamera = null
    const previous = capture
    capture = null
    localMuted = false
    localDeafened = false
    previous?.release()
  }

  function releasePeer() {
    const previous = mediaAttempt
    mediaAttempt = null
    previous?.peer?.leave()
    mediaConnectionState = "idle"
    playbackState = "waiting"
  }

  function reconcilePeer(state) {
    if (!createPeerAttempt) return
    const sig = currentSignaling()
    const call = sig.call
    const eligible = !disposed && microphoneTrack(capture) && microphoneSource(capture)?.live !== false &&
      call?.ownership === "self" && sig.callTopicStatus === "joined" &&
      sig.connectionStatus === "connected" && ["connecting", "active"].includes(call?.state) &&
      state.call?.call_id === call.call_id && leaveInFlightCallId !== call.call_id
    if (!eligible) { if (mediaAttempt) releaseCapture(); return }
    if (mediaAttempt) return
    const entry = {callId: call.call_id, capture, generation: actionGeneration, peer: null,
      cameraState: capture.camera?.live ? "preview_ready" : "off", cameraError: null}
    attemptedMediaCallIds.add(call.call_id)
    mediaAttempt = entry
    const current = () => !disposed && mediaAttempt === entry && capture === entry.capture &&
      actionGeneration === entry.generation && currentSignaling().call?.call_id === entry.callId &&
      currentSignaling().call?.ownership === "self"
    entry.peer = createPeerAttempt({signaling,
      onState(value) { if (current()) { mediaConnectionState = value; publish() } },
      onPlayback(value) { if (current()) { playbackState = value; publish() } },
      onRemoteVideo(track, binding = null) {
        if (!current()) return
        entry.remoteVideoTrack = track
        entry.remoteVideoBinding = binding
        entry.remoteVideoState = track ? "loading" : "off"
        publish()
      },
      onFailure() { if (current()) leaveCall() },
      onCamera(value, error) {
        if (!current()) return
        entry.cameraState = value
        entry.cameraError = error
        if (value === "error") releaseOwnedCamera()
        publish()
      },
    })
    applyLocalMediaState()
    Promise.resolve().then(() => {
      if (current()) return entry.peer.connect({callId: entry.callId, track: microphoneTrack(entry.capture),
        cameraTrack: entry.capture.camera?.live ? entry.capture.camera.track : null})
    }).catch(() => { if (current()) leaveCall() })
  }

  function resetForTransportLoss(code) {
    if (acceptedCallId) attemptedMediaCallIds.add(acceptedCallId)
    pendingAcceptExit = null
    invalidateRecipientWork()
    beginAction()
    releaseCapture()
    cancelResultTimer()
    resultCode = code
    failedDevice = null
    lastCallId = null
    adoptedCall = null
    ignoredCallId = null
    cancels.clear()
    suppressedCallIds.clear()
    retiredCallIds.clear()
    currentAccept = null
    recipientError = null
    recipientFailedDevice = null
    recipientCommand = null
    leaveError = null
    declineInFlightCallId = null
    leaveInFlightCallId = null
    terminalResultId = null
    for (const action of starts) {
      action.abandoned = true
      action.expectsReply = false
      action.awaitingCommit = false
      action.acquire = null
      action.starting = false
    }
    currentStart = null
    publish()
  }

  function visibleCall(sig) {
    const call = sig.call ?? null
    const liveId = currentStart?.callId ?? adoptedCall?.call_id
    if (call?.call_id && liveId && call.call_id !== liveId && belongsToOtherStart(call.call_id)) {
      return adoptedCall
    }
    if (call?.call_id && retiredCallIds.has(call.call_id) && adoptedCall?.call_id !== call.call_id) {
      return adoptedCall
    }
    if (call?.call_id && ignoredCallId === call.call_id && adoptedCall?.call_id !== call.call_id) {
      return adoptedCall
    }
    return call
  }

  // Ignore a superseded ringing snapshot while a newer start is in preflight, or
  // once that start already owns a different Call ID. Do not hide a leftover
  // invitation after a later start fails, and do not hide a converged Call ID.
  function ignoreSupersededProjection(callId) {
    if (!callId) return false
    if (retiredCallIds.has(callId)) return true
    if (adoptedCall?.call_id === callId) return false
    if (
      currentStart?.callId &&
      currentStart.callId !== callId &&
      starts.some(action => action !== currentStart && (action.callId === callId || startCommitPending(action)))
    ) {
      ignoredCallId = callId
      return true
    }
    if (adoptedCall?.call_id && adoptedCall.call_id !== callId && hasSupersededInFlight()) {
      ignoredCallId = callId
      return true
    }
    if (ignoredCallId === callId && !currentStart?.acked &&
        !(currentStart && startCommitPending(currentStart))) return true
    if (currentStart?.acked) return false
    if (currentStart && startCommitPending(currentStart)) return false
    if (!hasSupersededInFlight()) return false
    ignoredCallId = callId
    return true
  }

  function hasSupersededInFlight() {
    return starts.some(action => action !== currentStart && startCommitPending(action))
  }

  function startCommitPending(action) {
    return action.expectsReply || action.awaitingCommit
  }

  function startForProjection(callId) {
    const known = starts.find(action => action.callId === callId)
    if (known) return known
    const pending = starts.filter(action => startCommitPending(action) && !action.callId)
    if (pending.length === 1) return pending[0]
    return null
  }

  function canAdoptProjection(callId) {
    if (!currentStart) return true
    if (belongsToOtherStart(callId)) return false
    return starts.filter(action => startCommitPending(action) && !action.callId).length <= 1
  }

  function belongsToOtherStart(callId) {
    return starts.some(action => (
      action !== currentStart &&
      (action.callId === callId || startCommitPending(action))
    ))
  }

  function shouldReleaseCaptureFor(callId) {
    if (starts.some(action => action !== currentStart && (action.callId === callId || startCommitPending(action)))) {
      return false
    }
    return true
  }

  function applyStartReplyToAction(action, reply) {
    if (action.abandoned) return
    action.acked = true
    action.expectsReply = false
    if (reply?.ok && reply.call?.call_id) action.callId = reply.call.call_id
    if (action === currentStart) flushDeferredCancels(action.callId)
    if (action.cancel && action.callId) {
      if (currentStart && currentStart !== action && !currentStart.acked) return
      requestCancelForAction(action)
      return
    }
    publish()
  }

  function flushDeferredCancels(adoptedId) {
    for (const action of starts) {
      if (action === currentStart) continue
      if (action.callId && action.callId === adoptedId) {
        action.cancelConsumed = true
        continue
      }
      if (action.cancel && action.callId) requestCancelForAction(action)
    }
  }

  function adoptedByLiveStart(callId) {
    return Boolean(
      currentStart &&
      !currentStart.cancel &&
      currentStart.acked &&
      (currentStart.callId === callId || adoptedCall?.call_id === callId) &&
      resultCode == null &&
      capture,
    )
  }

  function requestCancelForAction(action) {
    if (!action.cancel || !action.callId || action.cancelConsumed) return
    if (adoptedByLiveStart(action.callId)) {
      action.cancelConsumed = true
      return
    }
    action.cancelConsumed = true
    requestCancel(action.callId)
  }

  function requestCancel(callId, {suppress = true} = {}) {
    if (!callId || disposed) return
    if (suppress) suppressedCallIds.add(callId)
    const existing = cancels.get(callId)
    if (existing && (existing.inFlight || existing.accepted || existing.attempts > 0)) {
      publish()
      return
    }

    const entry = {callId, attempts: 0, inFlight: false, accepted: false}
    cancels.set(callId, entry)
    lastCallId = callId
    attemptCancel(entry)
    publish()
  }

  function maybeRetryOrRestoreCancel(sig) {
    const callId = sig.call?.call_id
    if (!callId) return
    const entry = cancels.get(callId)
    if (!entry || entry.accepted || entry.inFlight) return

    if (sig.callTopicStatus === "joined") {
      attemptCancel(entry)
      return
    }

    if (sig.callTopicStatus === "failed") restoreVisibleRinging(callId)
  }

  function attemptCancel(entry) {
    if (disposed || !entry || entry.inFlight || entry.accepted) return
    if (currentSignaling().connectionStatus !== "connected") return
    if (entry.attempts >= 2) {
      restoreVisibleRinging(entry.callId)
      return
    }

    entry.attempts += 1
    entry.inFlight = true
    const callId = entry.callId
    Promise.resolve(signaling.cancelCall({callId})).then(reply => {
      const current = cancels.get(callId)
      if (disposed || current !== entry) return
      entry.inFlight = false
      if (reply?.ok) {
        entry.accepted = true
        return
      }

      const status = currentSignaling().callTopicStatus ?? "idle"
      if (reply?.error === "unavailable" && status === "joining") return
      const call = derive().call
      // The join can become commandable before the unavailable promise runs.
      // Resume its bounded retry here when that projection already arrived.
      if (reply?.error === "unavailable" && status === "joined" && call?.call_id === callId) {
        attemptCancel(entry)
        return
      }
      if (reply?.error === "stale" && (currentStart?.captureLost || currentStart?.cancel) &&
          currentStart.callId === callId && call?.call_id === callId &&
          ["connecting", "active"].includes(call.state) && ownsCall(call)) leaveCall()
      restoreVisibleRinging(callId)
    })
  }

  function restoreVisibleRinging(callId) {
    if (!callId || !cancels.has(callId)) return
    cancels.delete(callId)
    suppressedCallIds.delete(callId)
    publish()
  }

  function publish() {
    if (disposed) return
    reconcilePeer(getState())
    const state = getState()
    reconcileCue(state)
    observeVideo({...state, cameraPreflightError: failedDevice === "camera" ? resultCode
      : recipientFailedDevice === "camera" ? recipientError : null})
    for (const listener of listeners) listener(state)
  }

  function reconcileCue(state) {
    const desired = desiredCueFor(state)
    if (sameCue(desired, requestedCue)) return

    try {
      if (requestedCue) cueSystem.withdraw?.()
      if (desired) cueSystem.contend?.(desired)
      requestedCue = desired
    } catch (_) {}
  }

  function desiredCueFor(state) {
    if (state.connectionStatus !== "connected" || !state.call?.call_id) return null

    const ownership = state.call.ownership
    if (!["self", "elsewhere", "unclaimed"].includes(ownership)) return null

    if (state.presentation === "incoming_ringing" || state.presentation === "incoming_preflighting") {
      return {kind: "incoming", callId: state.call.call_id}
    }
    if (state.presentation === "outgoing_ringing" && ownership === "self") {
      return {kind: "outgoing", callId: state.call.call_id}
    }
    return null
  }

  function applyTerminalResult(terminalCall) {
    const callId = terminalCall.call_id
    if (!callId || terminalResultId === callId) return
    if (pendingAcceptExit?.callId === callId) pendingAcceptExit = null
    invalidateRecipientWork()
    cancelResultTimer()
    terminalResultId = callId
    lastCallId = null
    adoptedCall = null
    declineInFlightCallId = null
    leaveInFlightCallId = null
    recipientError = null
    recipientFailedDevice = null
    recipientCommand = null
    leaveError = null
    activeConversation = conversationFromProjection(terminalCall) ?? activeConversation
    mediaIntent = terminalCall.media_intent ?? mediaIntent
    resultCode = terminalCall.terminal_outcome ?? "failed"
    resultTimer = scheduleResultDismissal(() => {
      if (disposed || terminalResultId !== callId) return
      dismissedTerminalIds.add(callId)
      resultTimer = null
      terminalResultId = null
      resultCode = null
      activeConversation = null
      mediaIntent = null
      publish()
    }, resultDisplayMs)
    publish()
  }

  function cancelResultTimer() {
    if (resultTimer != null) cancelResultDismissal(resultTimer)
    resultTimer = null
  }

  function adoptCommittedIntent(call) {
    const committed = call?.media_intent
    if (committed !== "audio" && committed !== "video") return
    if (cameraReady(capture) && committed !== "video") releaseCapture()
    mediaIntent = committed
  }

  return {
    subscribe,
    getState,
    setRemoteVideoState(binding, value) {
      const state = derive()
      if (!binding || mediaAttempt?.remoteVideoBinding !== binding || !binding.isCurrent() ||
          state.call?.ownership !== "self" || !state.remoteCameraEnabled ||
          !["connecting", "active"].includes(state.presentation) ||
          !["loading", "ready", "blocked", "interrupted"].includes(value) || mediaAttempt.remoteVideoState === value) return
      mediaAttempt.remoteVideoState = value
      publish()
    },
    startCall,
    cancelCall,
    acceptCall,
    declineCall,
    leaveCall,
    toggleCamera,
    toggleMute,
    toggleDeafen,
    enableAudio,
    enableMicrophone,
    cancelLocalPreparation,
    retry,
    fallbackToAudio,
    dismiss,
    releaseCues,
    suspend,
    dispose,
  }
}

function sameCue(left, right) {
  if (!left && !right) return true
  if (!left || !right) return false
  return left.kind === right.kind && left.callId === right.callId
}

function normalizeError(error) {
  if (START_ERRORS.has(error)) return error
  return "unknown-error"
}

function validRecipientAnswer(mediaIntent, answerMode) {
  return (
    (mediaIntent === "audio" && answerMode === "audio") ||
    (mediaIntent === "video" && ["audio", "video"].includes(answerMode))
  )
}

function displayedMediaIntent(call, localIntent) {
  if (call?.media_intent === "audio" || call?.media_intent === "video") return call.media_intent
  return localIntent
}

function ownsCall(call) {
  return !call?.ownership || call.ownership === "self"
}

function callerRingingFromAnotherTab(call) {
  return call?.role === "caller" && call.state === "ringing"
}

function statusTextFor(
  presentation,
  resultCode,
  peerName,
  mediaIntent,
  failedDevice,
  cancelling,
  recipientError,
  recipientFailedDevice,
  recipientCommand,
  leaveError,
  recipientAnswerMode,
  leaving,
  terminalResult,
  ownership,
) {
  if (presentation === "preflighting") {
    return mediaIntent === "video" ? "Preparing video call…" : "Preparing voice call…"
  }
  if (presentation === "outgoing_ringing") {
    if (cancelling) return "Cancelling…"
    if (ownership === "elsewhere") {
      return peerName ? `Calling ${peerName} from another tab…` : "Calling from another tab…"
    }
    return peerName ? `Calling ${peerName}…` : "Calling…"
  }
  if (presentation === "owned_elsewhere") return "Call active in another tab."
  if (presentation === "incoming_ringing") {
    if (recipientCommand === "decline") return "Couldn't decline the call. Try again."
    if (recipientCommand === "accept") return "Couldn't answer the call. Try again or decline."
    if (recipientError) {
      if (recipientError === "permission-pending") {
        return recipientFailedDevice === "camera" ? CAMERA_COPY[recipientError] : RESULT_COPY[recipientError]
      }
      if (recipientFailedDevice === "camera") {
        return `${CAMERA_COPY[recipientError] ?? CAMERA_COPY["unknown-error"]} You can answer without video or decline.`
      }
      if (recipientError === "capture-unavailable") return `${RESULT_COPY[recipientError]} You can decline.`
      if (recipientError === "permission-denied") return "Microphone access is blocked. Try again or decline."
      if (recipientError === "no-device") return "No microphone is available. You can retry or decline."
      if (recipientError === "ended") return "The microphone stopped. Try again or decline."
      if (recipientError === "device-busy") return "The microphone is busy. Try again or decline."
      return "The microphone isn't ready. Try again or decline."
    }
    const kind = mediaIntent === "video" ? "video" : "audio"
    return peerName ? `${peerName} is inviting you to a ${kind} call.` : `Incoming ${kind} call.`
  }
  if (presentation === "incoming_preflighting") {
    return recipientAnswerMode === "video"
      ? "Preparing microphone and camera…"
      : "Preparing microphone…"
  }
  if (presentation === "connecting") {
    if (leaveError) return "Couldn't leave the call. Try again."
    return leaving ? "Leaving…" : "Connecting with fake call setup…"
  }
  if (presentation === "active") {
    if (leaveError) return "Couldn't leave the call. Try again."
    return leaving ? "Leaving…" : "Call active — no real media is connected."
  }
  if (presentation === "unavailable") return RESULT_COPY.unavailable
  if (failedDevice === "camera") return CAMERA_COPY[resultCode] ?? CAMERA_COPY["unknown-error"]
  if (failedDevice === "microphone") {
    if (resultCode === "unknown-error") return "Couldn't start the microphone."
    if (resultCode === "ended") return "The microphone stopped. Start again when you're ready."
    return RESULT_COPY[resultCode] ?? RESULT_COPY["unknown-error"]
  }
  if (mediaIntent === "video" && VIDEO_RESULT_COPY[resultCode]) return VIDEO_RESULT_COPY[resultCode]
  if (terminalResult && TERMINAL_COPY[resultCode]) return TERMINAL_COPY[resultCode]
  return RESULT_COPY[resultCode] ?? RESULT_COPY["unknown-error"]
}

function conversationFromProjection(call) {
  if (!call?.peer) return null
  return freezeConversation({
    id: call.direct_conversation_id ?? null,
    peer: call.peer,
  })
}

function defaultSchedule(callback, delay) {
  const timer = setTimeout(callback, delay)
  timer?.unref?.()
  return timer
}

function freezeConversation(conversation) {
  return Object.freeze({
    id: conversation.id,
    peer: conversation.peer
      ? Object.freeze({
        id: conversation.peer.id,
        username: conversation.peer.username,
      })
      : null,
  })
}

function freezeState(next) {
  return Object.freeze({
    ...next,
    conversation: next.conversation ?? null,
    call: next.call ? Object.freeze({...next.call}) : null,
  })
}
