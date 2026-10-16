import {observeCallVideo} from "./call_video_readiness.js"

export function installCallPresenter({
  document: doc,
  window: win,
  controller,
  MediaStream = globalThis.MediaStream,
  videoClock,
} = {}) {
  if (!doc || !controller) return {dispose() {}}
  let incomingOpen = false
  let priorFocus = null
  let preview = null
  let previewSource = null
  let remoteVideo = null
  let navigating = false
  let previewCallId = null
  let selfPreviewHidden = false
  let stageExpanded = false
  const seenReceivers = new WeakSet()
  const dock = doc.getElementById("direct-call-dock")

  function placeCallSurface(state, movingAway = navigating) {
    const stage = doc.getElementById("direct-conversation-call-stage")
    const inConversation = !movingAway && stage?.isConnected && ownerParticipants(state) &&
      stage.dataset.directConversationId === state.call.direct_conversation_id
    const destination = inConversation ? stage : doc.getElementById("direct-call-dock-home")
    if (dock && destination && dock.parentElement !== destination) {
      const focus = doc.activeElement
      // Native atomic moves preserve playback and frame observers. Older browsers
      // retain the same elements/streams through appendChild's relocation.
      if (destination.moveBefore) destination.moveBefore(dock, null)
      else destination.appendChild(dock)
      if (dock.contains?.(focus)) focus?.focus?.({preventScroll: true})
    }
    setHidden(stage, !inConversation)
    const compact = ownerParticipants(state) && !inConversation
    if (doc.body?.dataset) doc.body.dataset.callCompact = String(compact)
    const returnLink = doc.getElementById("direct-call-dock-return")
    const conversationId = state.call?.direct_conversation_id
    setHidden(returnLink, !compact || !conversationId)
    if (compact && conversationId) returnLink?.setAttribute?.("href", `/direct-messages/${encodeURIComponent(conversationId)}`)
    else returnLink?.removeAttribute?.("href")
    reservePanelSpace()
  }

  function reservePanelSpace() {
    if (doc.body?.dataset?.callCompact === "true") {
      const height = Math.ceil(dock?.getBoundingClientRect?.().height ?? 0)
      doc.body.style?.setProperty?.("--call-panel-height", `${height}px`)
    } else doc.body?.style?.removeProperty?.("--call-panel-height")
  }

  const PanelObserver = win?.ResizeObserver
  const panelObserver = dock && PanelObserver ? new PanelObserver(reservePanelSpace) : null
  panelObserver?.observe(dock)

  function onClick(event) {
    const target = event?.target
    if (!target?.closest) return

    if (target.closest("[data-call-action='toggle-size']")) {
      const state = controller.getState()
      if (!ownerParticipants(state) || state.call.call_id !== previewCallId) return
      stageExpanded = !stageExpanded
      render(state)
      doc.getElementById("direct-call-dock-size")?.focus?.({preventScroll: true})
      return
    }

    if (target.closest("[data-call-action='toggle-preview']")) {
      const state = controller.getState()
      if (!ownerParticipants(state) || state.call.call_id !== previewCallId) return
      selfPreviewHidden = !selfPreviewHidden
      render(state)
      return
    }

    if (target.closest("[data-call-action='retry-video']")) {
      remoteVideo?.observer?.retry()
      return
    }

    if (target.closest("[data-call-action='retry-preview']")) {
      if (preview) playPreview(preview)
      return
    }

    const startAudio = target.closest("[data-call-action='start-audio']")
    if (startAudio) {
      startFrom(startAudio, "audio")
      return
    }

    const startVideo = target.closest("[data-call-action='start-video']")
    if (startVideo) {
      startFrom(startVideo, "video")
      return
    }

    if (target.closest("[data-call-action='cancel']")) {
      controller.cancelCall()
      return
    }

    if (target.closest("[data-call-action='accept-audio']")) {
      controller.acceptCall("audio")
      return
    }

    if (target.closest("[data-call-action='accept-video']")) {
      if (controller.getState().videoAvailable !== false) controller.acceptCall("video")
      return
    }

    if (target.closest("[data-call-action='answer-without-video']")) {
      controller.acceptCall("audio")
      return
    }

    if (target.closest("[data-call-action='decline']")) {
      controller.declineCall()
      return
    }

    if (target.closest("[data-call-action='enable-microphone']")) {
      controller.enableMicrophone()
      return
    }

    if (target.closest("[data-call-action='toggle-camera']")) {
      controller.toggleCamera()
      return
    }

    if (target.closest("[data-call-action='toggle-mute']")) {
      controller.toggleMute()
      return
    }

    if (target.closest("[data-call-action='toggle-deafen']")) {
      controller.toggleDeafen()
      return
    }

    if (target.closest("[data-call-action='enable-audio']")) {
      controller.enableAudio()
      return
    }

    if (target.closest("[data-call-action='leave']")) {
      controller.leaveCall()
      return
    }

    if (target.closest("[data-call-action='retry']")) {
      controller.retry()
      return
    }

    if (target.closest("[data-call-action='fallback-audio']")) {
      controller.fallbackToAudio()
      return
    }

    if (target.closest("[data-call-action='dismiss']")) controller.dismiss()
  }

  function startFrom(button, intent) {
    if (button.getAttribute("aria-disabled") === "true") return
    controller.startCall({
      id: button.dataset.directConversationId,
      peer: {
        id: button.dataset.peerId,
        username: button.dataset.peerUsername,
      },
    }, intent)
  }

  function onPageLoadingStart(event) {
    // Device acquire only. An in-flight start_call must not become cancel_call
    // just because LiveView replaced the page; the dock is navigation-persistent.
    controller.cancelLocalPreparation?.()
    if (event?.detail?.kind !== "element") {
      navigating = true
      placeCallSurface(controller.getState())
    }
  }

  function onPageLoadingStop(event) {
    if (event?.detail?.kind === "element") return
    navigating = false
    render(controller.getState())
  }

  function onConversationSurface() {
    // An outgoing hook can be destroyed while its DOM is still connected.
    // Reconcile without releasing the page replacement fence.
    render(controller.getState())
  }

  function onKeyDown(event) {
    if (!incomingOpen) return
    if (event.key === "Escape") {
      event.preventDefault?.()
      if (controller.getState().canCancel) controller.cancelCall()
      else controller.declineCall()
      return
    }
    if (event.key !== "Tab") return

    const dialog = doc.getElementById("direct-call-incoming-dialog")
    const focusable = focusableElements(dialog)
    if (focusable.length === 0) return
    const first = focusable[0]
    const last = focusable.at(-1)
    if (!focusable.includes(doc.activeElement)) {
      event.preventDefault?.()
      ;(event.shiftKey ? last : first).focus?.()
    } else if (event.shiftKey && doc.activeElement === first) {
      event.preventDefault?.()
      last.focus?.()
    } else if (!event.shiftKey && doc.activeElement === last) {
      event.preventDefault?.()
      first.focus?.()
    }
  }

  function render(state) {
    const focused = doc.activeElement
    if (previewCallId !== (state.call?.call_id ?? null)) {
      previewCallId = state.call?.call_id ?? null
      selfPreviewHidden = false
      stageExpanded = false
    }
    updateIncoming(doc, state)
    syncIncomingFocus(state)
    placeCallSurface(state)
    updateDock(doc, state)
    syncHeader(doc, state)
    const participants = ownerParticipants(state)
    const size = doc.getElementById("direct-call-dock-size")
    const expanded = participants && stageExpanded
    if (dock?.dataset) dock.dataset.stageExpanded = String(expanded)
    if (size?.hidden === false && !participants && doc.activeElement === size) focusCallSurface()
    setHidden(size, !participants)
    setText(size, expanded ? "Collapse" : "Expand")
    size?.setAttribute?.("aria-expanded", String(expanded))
    const group = doc.getElementById("direct-call-participants")
    if (group?.dataset) group.dataset.participantsActive = String(participants)
    const name = state.peerName || "Friend"
    setText(doc.getElementById("direct-call-remote-video-name"), name)
    setText(doc.getElementById("direct-call-remote-video-avatar"), Array.from(name)[0].toLocaleUpperCase())
    const toggle = doc.getElementById("direct-call-dock-preview")
    setHidden(toggle, !participants)
    setText(toggle, selfPreviewHidden ? "Show Self-preview" : "Hide Self-preview")
    const cameraStatus = doc.getElementById("direct-call-self-camera-status")
    setHidden(cameraStatus, !participants)
    setText(cameraStatus, state.cameraState === "interrupted" ? "Your camera is interrupted"
      : state.cameraAttached ? "Your camera is on · Sending video"
      : state.cameraState === "pending" ? "Preparing your camera…"
      : state.cameraState === "attaching" ? "Connecting your camera…"
      : state.cameraState === "error" ? "Your camera is unavailable" : "Your camera is off")
    syncPreview(state)
    syncRemoteVideo(state)
    reservePanelSpace()
    // Hiding a focused ancestor can synchronously drop focus to the body.
    // Retain the old target, but never override another deliberate restoration.
    if (focused?.id?.startsWith("direct-call-") && !focusableForRestore(focused) &&
        (!doc.activeElement || doc.activeElement === doc.body || doc.activeElement === focused)) focusCallSurface()
  }

  function clearPreview() {
    const previous = preview
    preview = null
    if (previous) {
      previous.element.pause?.()
      previous.element.srcObject = null
      const retry = doc.getElementById(`${previous.prefix}-retry`)
      setHidden(retry, true)
      if (doc.activeElement === previous.element || doc.activeElement === retry) focusCallSurface()
    }
  }

  function clearRemoteVideo(state = "off") {
    remoteVideo?.observer?.cancel()
    if (remoteVideo && remoteVideo.element.srcObject === remoteVideo.stream) {
      remoteVideo.element.pause?.()
      remoteVideo.element.srcObject = null
    }
    remoteVideo = null
    videoState(state)
  }

  function videoState(value, entry = null) {
    const element = doc.getElementById("direct-call-remote-video")
    if (element?.dataset) element.dataset.remoteVideoState = value
    if (element?.style) element.style.visibility = value === "ready" ? "visible" : "hidden"
    setHidden(doc.getElementById("direct-call-remote-video-placeholder"), value === "ready")
    const retry = doc.getElementById("direct-call-remote-video-retry")
    const retryFocused = retry && doc.activeElement === retry
    if (value !== "blocked" && retryFocused) focusCallSurface()
    setHidden(retry, value !== "blocked")
    setText(doc.getElementById("direct-call-remote-video-status"), value === "loading"
      ? "Waiting for video…" : value === "blocked" ? "Video couldn't play. Try playing video again."
      : value === "interrupted" ? "Video interrupted. Waiting for fresh frames…" : value === "off" ? "Camera off" : "Video ready")
    if (entry) controller.setRemoteVideoState?.(entry.binding, value)
  }

  function syncRemoteVideo(state) {
    const element = doc.getElementById("direct-call-remote-video")
    const track = state.remoteVideoTrack
    const binding = state.remoteVideoBinding
    const visible = Boolean(element && MediaStream && state.call?.ownership === "self" &&
      ["connecting", "active"].includes(state.presentation) && state.remoteCameraEnabled &&
      track && track.readyState !== "ended")
    const waitingState = ownerParticipants(state) && state.remoteCameraEnabled ? "loading" : "off"
    if (!visible || remoteVideo?.track !== track || remoteVideo?.element !== element ||
        remoteVideo?.binding !== binding || remoteVideo?.callId !== state.call?.call_id) clearRemoteVideo(waitingState)
    setHidden(doc.getElementById("direct-call-remote-video-region"), !ownerParticipants(state))
    if (!visible) {
      videoState(waitingState)
      return
    }
    if (remoteVideo) return
    if (binding?.isCurrent() === false) { videoState("loading"); return }
    const stream = new MediaStream([track])
    const entry = {element, track, stream, binding, callId: state.call?.call_id}
    remoteVideo = entry
    element.muted = true
    element.playsInline = true
    element.autoplay = true
    element.srcObject = stream
    if (!binding) { videoState("loading"); return }
    const receiver = binding.receiver ?? binding
    const firstObservation = !seenReceivers.has(receiver)
    if (binding.routeEpoch !== null) seenReceivers.add(receiver)
    entry.observer = observeCallVideo({element, binding, firstObservation, document: doc, clock: videoClock,
      current: () => remoteVideo === entry && element.srcObject === stream &&
        doc.getElementById("direct-call-remote-video") === element && element.isConnected !== false &&
        (element.getClientRects?.().length ?? 1) > 0 &&
        !doc.getElementById("direct-call-remote-video-region")?.hidden && track.readyState !== "ended",
      onState: value => videoState(value, entry),
    })
  }

  function focusCallSurface() {
    const incoming = ["incoming_ringing", "incoming_preflighting"].includes(controller.getState().presentation)
    const camera = doc.getElementById("direct-call-dock-camera")
    const target = incoming ? doc.getElementById("direct-call-incoming-title")
      : !doc.getElementById("direct-call-dock")?.hidden
      ? (camera && !camera.hidden && !camera.disabled ? camera : doc.getElementById("direct-call-dock-title"))
      : ["message_content", "direct-conversation-start-voice-call", "direct-call-focus-fallback"]
        .map(id => doc.getElementById(id)).find(focusableForRestore)
    target?.focus?.()
  }

  function syncPreview(state) {
    const incoming = ["incoming_ringing", "incoming_preflighting"].includes(state.presentation)
    const prefix = incoming ? "direct-call-incoming-preview" : "direct-call-local-preview"
    const element = doc.getElementById(prefix)
    const track = state.cameraPreviewTrack
    const eligible = Boolean(track && track.readyState !== "ended" && MediaStream && state.call?.ownership !== "elsewhere")
    if (!eligible || previewSource?.track !== track) previewSource = null
    if (preview && (preview.element !== element || preview.track !== track)) clearPreview()
    const visible = Boolean(element && eligible)
    for (const surface of ["direct-call-local-preview", "direct-call-incoming-preview"]) {
      const region = doc.getElementById(`${surface}-region`)
      const hidden = surface !== prefix ||
        (!visible && !(surface === "direct-call-local-preview" && ownerParticipants(state))) ||
        (surface === "direct-call-local-preview" && ownerParticipants(state) && selfPreviewHidden)
      if (hidden && region?.contains?.(doc.activeElement)) {
        doc.getElementById("direct-call-dock-preview")?.focus?.()
      }
      setHidden(region, hidden)
    }
    setHidden(doc.getElementById("direct-call-local-preview-placeholder"), prefix === "direct-call-local-preview" && visible)
    if (!visible) {
      clearPreview()
      const status = state.cameraState === "pending" ? "Preparing camera…"
        : state.cameraState === "attaching" ? "Connecting camera…"
        : state.cameraState === "interrupted" ? "Camera interrupted"
        : state.cameraState === "error" ? "Camera unavailable" : "Camera off"
      setText(doc.getElementById("direct-call-local-preview-status"), status)
      return
    }
    if (!preview) {
      previewSource ??= {track, stream: new MediaStream([track])}
      const {stream} = previewSource
      const entry = {element, track, stream, prefix, cameraState: state.cameraState, blocked: false}
      preview = entry
      element.muted = true
      element.playsInline = true
      element.autoplay = true
      element.srcObject = stream
      if (preview === entry) playPreview(entry)
    }
    if (preview?.track === track && preview.element === element) {
      preview.cameraState = state.cameraState
      if (!preview.blocked) previewStatus(preview)
    }
  }

  function previewStatus(entry) {
    // Camera transitions are already announced by the current Call surface.
    doc.getElementById(`${entry.prefix}-status`)?.setAttribute?.("aria-live", "off")
    setText(doc.getElementById(`${entry.prefix}-status`), entry.cameraState === "interrupted"
      ? "Camera interrupted. Waiting for the camera source to resume."
      : entry.cameraState === "enabled"
      ? "Local preview. Camera attached."
      : "Local preview. Camera is not sending video yet.")
  }

  function playPreview(entry) {
    const version = entry.playVersion = (entry.playVersion ?? 0) + 1
    const current = () => preview === entry && entry.playVersion === version &&
      doc.getElementById(entry.prefix) === entry.element
    entry.blocked = false
    const retry = doc.getElementById(`${entry.prefix}-retry`)
    if (doc.activeElement === retry) focusCallSurface()
    setHidden(retry, true)
    previewStatus(entry)
    Promise.resolve().then(() => {
      if (current()) return entry.element.play?.()
    }).catch(() => {
      if (!current()) return
      entry.blocked = true
      doc.getElementById(`${entry.prefix}-status`)?.setAttribute?.("aria-live", "polite")
      setText(doc.getElementById(`${entry.prefix}-status`), "Preview couldn't play. Try preview again.")
      setHidden(doc.getElementById(`${entry.prefix}-retry`), false)
    })
  }

  function syncIncomingFocus(state) {
    const shouldOpen = ["incoming_ringing", "incoming_preflighting"].includes(state.presentation)
    if (shouldOpen && !incomingOpen) {
      incomingOpen = true
      priorFocus = doc.activeElement ?? null
      doc.getElementById("direct-call-incoming-title")?.focus?.()
      return
    }
    const cancel = doc.getElementById("direct-call-incoming-cancel-preparation")
    if (shouldOpen && cancel?.hidden && doc.activeElement === cancel) {
      doc.getElementById("direct-call-incoming-title")?.focus?.()
    }
    if (!shouldOpen && incomingOpen) {
      incomingOpen = false
      const restore = focusableForRestore(priorFocus)
        ? priorFocus
        : doc.getElementById("direct-call-focus-fallback")
      restore?.focus?.()
      priorFocus = null
    }
  }

  const unsubscribe = controller.subscribe(render)
  doc.addEventListener?.("click", onClick)
  doc.addEventListener?.("keydown", onKeyDown)
  win?.addEventListener?.("phx:page-loading-start", onPageLoadingStart)
  win?.addEventListener?.("phx:page-loading-stop", onPageLoadingStop)
  win?.addEventListener?.("call:conversation-surface", onConversationSurface)

  function dispose() {
    placeCallSurface(controller.getState(), true)
    panelObserver?.disconnect()
    if (doc.body?.dataset) doc.body.dataset.callCompact = "false"
    doc.body?.style?.removeProperty?.("--call-panel-height")
    clearRemoteVideo()
    setHidden(doc.getElementById("direct-call-remote-video-region"), true)
    clearPreview()
    previewSource = null
    setHidden(doc.getElementById("direct-call-local-preview-region"), true)
    setHidden(doc.getElementById("direct-call-incoming-preview-region"), true)
    doc.removeEventListener?.("click", onClick)
    doc.removeEventListener?.("keydown", onKeyDown)
    win?.removeEventListener?.("phx:page-loading-start", onPageLoadingStart)
    win?.removeEventListener?.("phx:page-loading-stop", onPageLoadingStop)
    win?.removeEventListener?.("call:conversation-surface", onConversationSurface)
    unsubscribe?.()
  }

  return {dispose}
}

function ownerParticipants(state) {
  return state.call?.ownership === "self" && ["connecting", "active"].includes(state.presentation)
}

function updateIncoming(doc, state) {
  const backdrop = doc.getElementById("direct-call-incoming-backdrop")
  if (!backdrop) return
  const visible = ["incoming_ringing", "incoming_preflighting"].includes(state.presentation)
  backdrop.hidden = !visible
  if (backdrop.dataset) backdrop.dataset.callIncomingState = state.presentation ?? "idle"

  setText(doc.getElementById("direct-call-incoming-caller"), state.peerName ?? "Unknown caller")
  setText(
    doc.getElementById("direct-call-incoming-intent"),
    state.mediaIntent === "video" ? "Video invitation" : "Audio invitation",
  )
  setText(doc.getElementById("direct-call-incoming-status"), state.statusText ?? "")
  const acceptAudio = doc.getElementById("direct-call-incoming-accept-audio")
  const acceptVideo = doc.getElementById("direct-call-incoming-accept-video")
  const answerWithoutVideo = doc.getElementById("direct-call-incoming-answer-without-video")
  const decline = doc.getElementById("direct-call-incoming-decline")
  const cancel = doc.getElementById("direct-call-incoming-cancel-preparation")
  setHidden(cancel, !visible || !state.canCancel)
  cancel?.setAttribute?.("aria-label", "Cancel device preparation")
  setHidden(acceptAudio, !visible || state.mediaIntent !== "audio")
  setHidden(acceptVideo, !visible || state.mediaIntent !== "video")
  setHidden(answerWithoutVideo, !visible || state.mediaIntent !== "video")
  setHidden(decline, !visible)
  setDisabled(acceptAudio, !state.canAcceptAudio)
  const videoUnavailable = state.videoAvailable === false
  setDisabled(acceptVideo, !videoUnavailable && !state.canAcceptVideo)
  if (acceptVideo) {
    acceptVideo.setAttribute?.("aria-disabled", videoUnavailable ? "true" : "false")
    if (videoUnavailable) acceptVideo.setAttribute?.("aria-describedby", "direct-call-video-unavailable-reason")
    else acceptVideo.removeAttribute?.("aria-describedby")
  }
  setHidden(doc.getElementById("direct-call-video-unavailable-reason"), !visible || state.mediaIntent !== "video" || !videoUnavailable)
  setDisabled(answerWithoutVideo, !state.canAnswerWithoutVideo)
  setDisabled(decline, !state.canDecline)
  if (acceptAudio) {
    acceptAudio.setAttribute?.("aria-label", `Accept audio call from ${state.peerName ?? "caller"}`)
  }
  if (acceptVideo) {
    acceptVideo.setAttribute?.("aria-label", `Accept video call from ${state.peerName ?? "caller"}`)
  }
  if (answerWithoutVideo) {
    answerWithoutVideo.setAttribute?.(
      "aria-label",
      `Answer call from ${state.peerName ?? "caller"} without video`,
    )
  }
  if (decline) decline.setAttribute?.("aria-label", `Decline call from ${state.peerName ?? "caller"}`)
}

function updateDock(doc, state) {
  const dock = doc.getElementById("direct-call-dock")
  if (!dock) return

  // The modal dialog is the only surface while an invitation is ringing or
  // being answered, so the dock cannot duplicate its live announcement.
  const dialogSurface = ["incoming_ringing", "incoming_preflighting"].includes(state.presentation)
  const visible = state.presentation && state.presentation !== "idle" && !dialogSurface
  dock.hidden = !visible
  if (dock.dataset) dock.dataset.callDockState = state.presentation ?? "idle"

  setText(doc.getElementById("direct-call-dock-status"), state.statusText ?? "")
  const inStage = dock.parentElement?.id === "direct-conversation-call-stage"
  setText(doc.getElementById("direct-call-dock-peer"), state.peerName ?? "")
  setHidden(doc.getElementById("direct-call-dock-peer"), inStage)
  const mediaStatus = doc.getElementById("direct-call-dock-media-state")
  const mediaText = acceptedMediaText(state.call)
  setText(mediaStatus, mediaText)
  setHidden(mediaStatus, !visible || !mediaText)
  setText(
    doc.getElementById("direct-call-dock-title"),
    (state.mediaIntent === "video" ? "Video call" : "Voice call") +
      (inStage && state.peerName ? ` with ${state.peerName}` : ""),
  )
  const camera = doc.getElementById("direct-call-dock-camera")
  setHidden(camera, !state.canMute)
  const cameraUnavailable = state.videoAvailable === false
  camera?.setAttribute?.("aria-disabled", cameraUnavailable ? "true" : "false")
  setDisabled(camera, !cameraUnavailable && !state.canControlCamera)
  camera?.setAttribute?.("aria-label", state.cameraWorking ? "Turn camera off" : "Turn camera on")
  camera?.setAttribute?.("data-active", (state.cameraAttached ?? state.cameraState === "enabled") ? "true" : "false")
  camera?.setAttribute?.("aria-busy", ["pending", "attaching"].includes(state.cameraState) ? "true" : "false")
  if (cameraUnavailable) camera?.setAttribute?.("aria-describedby", "direct-call-camera-unavailable-reason")
  else camera?.removeAttribute?.("aria-describedby")
  setText(camera, state.cameraWorking ? "Camera off" : "Camera on")
  setHidden(doc.getElementById("direct-call-camera-unavailable-reason"), !state.canMute || !cameraUnavailable)
  const mute = doc.getElementById("direct-call-dock-mute")
  setHidden(mute, !state.canMute)
  if (mute) {
    const action = state.localMuted ? "Unmute" : "Mute"
    mute.setAttribute?.("aria-label", `${action} microphone${state.localDeafened ? " after undeafening" : ""}`)
    mute.setAttribute?.("data-active", state.localMuted ? "true" : "false")
    setText(mute, `${action}${state.localDeafened ? " later" : ""}`)
  }
  const deafen = doc.getElementById("direct-call-dock-deafen")
  setHidden(deafen, !state.canDeafen)
  if (deafen) {
    deafen.setAttribute?.("aria-label", state.localDeafened ? "Undeafen audio" : "Deafen audio")
    deafen.setAttribute?.("data-active", state.localDeafened ? "true" : "false")
    setText(deafen, state.localDeafened ? "Undeafen" : "Deafen")
  }
  const enableAudio = doc.getElementById("direct-call-dock-enable-audio")
  setHidden(enableAudio, !state.canEnableAudio)
  enableAudio?.setAttribute?.("aria-label", "Play call audio")
  setHidden(doc.getElementById("direct-call-dock-cancel"), !state.canCancel)
  setHidden(doc.getElementById("direct-call-dock-leave"), !state.canLeave)
  setHidden(doc.getElementById("direct-call-dock-enable-microphone"), !state.canEnableMicrophone)
  const retry = doc.getElementById("direct-call-dock-retry")
  setHidden(retry, !state.canRetry)
  setText(retry, state.canFallbackToAudio ? "Retry camera" : "Retry")
  setHidden(doc.getElementById("direct-call-dock-dismiss"), !state.canDismiss)
  setHidden(doc.getElementById("direct-call-dock-start-voice-instead"), !state.canFallbackToAudio)
}

function acceptedMediaText(call) {
  if (!["connecting", "active"].includes(call?.state)) return ""
  const descriptions = []
  const describe = (label, snapshot) => {
    if (snapshot) descriptions.push(`${label}: microphone ${snapshot.microphone_muted ? "muted" : "on"}, camera ${snapshot.camera_enabled ? "on" : "off"}.`)
  }
  if (call.ownership === "elsewhere") describe("Your call tab", call.media_state?.[call.role])
  describe("Peer", call.media_state?.[call.role === "caller" ? "recipient" : "caller"])
  return descriptions.join(" ")
}

function syncHeader(doc, state) {
  const buttons = doc.querySelectorAll?.(
    "[data-call-action='start-audio'], [data-call-action='start-video']",
  ) ?? []
  for (const button of buttons) {
    if (button.dataset?.callAction === "start-video") {
      const unavailable = state.videoAvailable === false
      const reason = "direct-conversation-video-unavailable-reason"
      if (unavailable) {
        button.setAttribute("aria-disabled", "true")
        button.setAttribute("aria-describedby", reason)
      } else if (button.getAttribute("aria-describedby") === reason) {
        button.setAttribute("aria-disabled", "false")
        button.removeAttribute("aria-describedby")
      } else if (button.getAttribute("aria-disabled") !== "true") {
        button.setAttribute("aria-disabled", "false")
      }
      setHidden(doc.getElementById(reason), !unavailable)
    }
    if (button.getAttribute("aria-disabled") === "true") {
      button.removeAttribute("aria-busy")
      continue
    }

    if (state.busy) button.setAttribute("aria-busy", "true")
    else button.removeAttribute("aria-busy")
  }
}

function setText(node, value) {
  if (node && node.textContent !== value) node.textContent = value
}

function setHidden(node, hidden) {
  if (node) node.hidden = hidden
}

function setDisabled(node, disabled) {
  if (node) node.disabled = Boolean(disabled)
}

function focusableElements(dialog) {
  if (!dialog?.querySelectorAll) return []
  return [...dialog.querySelectorAll("button, [href], input, select, textarea, [tabindex]")]
    .filter(node => focusableForRestore(node) && node.getAttribute?.("tabindex") !== "-1")
}

function focusableForRestore(node) {
  if (!node?.focus || node.isConnected === false || node.disabled) return false
  for (let ancestor = node; ancestor; ancestor = ancestor.parentElement) {
    if (ancestor.hidden || ancestor.inert) return false
  }
  return true
}
