export const CALL_INBOX_TOPIC = "call_inbox:current-user"
export const CALL_TOPIC_PREFIX = "call:"
export const CALL_TERMINAL_EVENTS = [
  "call_declined",
  "call_cancelled",
  "call_timed_out",
  "call_ended",
  "call_error",
]
export const CALL_LIFECYCLE_EVENTS = ["call_connecting", "call_active"]
export const CALL_SIBLING_EVENTS = ["sibling_tab_owns_call"]
const CALL_LIFECYCLE_RANK = {ringing: 0, connecting: 1, active: 2}
export const CALL_COMMAND_EVENTS = ["decline_call", "cancel_call", "accept_call", "leave_call"]
export const CALL_RESERVED_CONTROL_EVENTS = []
export const CALL_RESERVED_MEDIA_EVENTS = [
  "offer",
  "ice_candidate",
  "ice_route",
  "renew",
  "local_media_state",
]

export function callTopic(callId) {
  return `${CALL_TOPIC_PREFIX}${callId}`
}

export function createCallSignaling({Socket, csrfToken} = {}) {
  let generation = 0
  let callGeneration = 0
  let startSerial = 0
  let appliedStartSerial = 0
  let disposed = false
  let socket = null
  let channel = null
  let callChannel = null
  let callSignalingSessionId = null
  let joinedCallId = null
  let callTopicStatus = "idle"
  let retiredCallIds = new Set()
  let terminalCallIds = new Set()
  let mediaListeners = new Set()
  let listeners = new Set()
  let inflight = new Set()
  let callInflight = new Set()
  let state = freezeState({
    connectionStatus: "disconnected",
    signalingSessionId: null,
    call: null,
    callTopicStatus: "idle",
  })

  function getState() {
    return state
  }

  function subscribe(listener) {
    listeners.add(listener)
    listener(state)
    return () => listeners.delete(listener)
  }

  function connect() {
    if (disposed || socket) return

    const currentGeneration = ++generation
    socket = new Socket("/calls", {params: {_csrf_token: csrfToken}})
    channel = socket.channel(CALL_INBOX_TOPIC, {})
    registerInboxHandlers(channel, currentGeneration)

    channel.join()
      .receive("ok", payload => {
        if (currentGeneration !== generation) return
        applyJoinSnapshot(payload)
      })
      .receive("error", () => {
        if (currentGeneration !== generation) return
        markUnavailable()
      })

    socket.onError?.(() => {
      if (currentGeneration !== generation) return
      markUnavailable()
    })
    socket.onClose?.(() => {
      if (currentGeneration !== generation) return
      markUnavailable()
    })

    replaceState({
      connectionStatus: "connecting",
      signalingSessionId: null,
      call: null,
    })
    socket.connect()
  }

  function disconnect() {
    teardownSocket()
    replaceState({
      connectionStatus: "disconnected",
      signalingSessionId: null,
      call: null,
    })
  }

  function dispose() {
    if (disposed) return

    disposed = true
    teardownSocket()
    replaceState({
      connectionStatus: "disconnected",
      signalingSessionId: null,
      call: null,
    })
    listeners.clear()
    mediaListeners.clear()
  }

  function startCall({directConversationId, mediaIntent} = {}) {
    const currentChannel = channel
    const capturedGeneration = generation
    const capturedSignalingSessionId = state.signalingSessionId
    const capturedCallId = state.call?.call_id ?? null

    if (state.connectionStatus !== "connected" || !capturedSignalingSessionId) {
      return Promise.resolve({ok: false, error: "unavailable"})
    }

    const capturedStart = ++startSerial

    return sendPush(
      currentChannel,
      "start_call",
      {
        signaling_session_id: capturedSignalingSessionId,
        direct_conversation_id: directConversationId,
        media_intent: mediaIntent,
      },
      () => isCurrentStart(capturedGeneration, capturedSignalingSessionId),
      (reply, settle) => {
        settle({
          ok: true,
          signaling_session_id: reply?.signaling_session_id ?? capturedSignalingSessionId,
          started: reply?.started,
          call: freezeCall(reply?.call),
        })
        // Skip only when a newer start already applied a call; otherwise this
        // invitation would never appear (inbox dedupes the ringing push).
        if (capturedStart !== startSerial && appliedStartSerial > capturedStart) return
        if (reply?.call?.call_id && terminalCallIds.has(reply.call.call_id)) return
        const currentCall = getState().call
        if (currentCall?.call_id && currentCall.call_id !== capturedCallId &&
            currentCall.call_id !== reply?.call?.call_id) return
        if (currentCall?.call_id === reply?.call?.call_id &&
            ["connecting", "active"].includes(currentCall?.state)) return
        applyStartReply(reply)
        appliedStartSerial = capturedStart
      },
    )
  }

  function declineCall({callId} = {}) {
    return sendCallCommand("decline_call", callId, {}, applyMatchingTerminal)
  }

  function cancelCall({callId} = {}) {
    return sendCallCommand("cancel_call", callId, {}, applyMatchingTerminal)
  }

  function acceptCall({callId, answerMode} = {}) {
    if (answerMode !== "audio" && answerMode !== "video") {
      return Promise.resolve({ok: false, error: "invalid_request"})
    }
    return sendCallCommand("accept_call", callId, {answer_mode: answerMode}, reply => {
      // An accepted projection already establishes the winning owner and
      // Answer Mode. A delayed acknowledgement cannot replace those facts.
      if (["connecting", "active"].includes(getState().call?.state)) return
      applyMatchingLifecycle(reply)
    })
  }

  function leaveCall({callId} = {}) {
    return sendCallCommand("leave_call", callId, {}, applyMatchingTerminal)
  }

  function mediaCredentials({callId} = {}) {
    return sendMedia("media_credentials", {call_id: callId})
  }

  function sendMedia(event, payload) {
    const callId = payload?.call_id
    const sessionId = callSignalingSessionId
    const capturedGeneration = callGeneration
    if (!["media_credentials", "offer", "ice_candidate", "renew", "local_media_state"].includes(event) ||
        !sessionId || joinedCallId !== callId || state.call?.call_id !== callId ||
        state.call?.ownership !== "self" || !["connecting", "active"].includes(state.call?.state) ||
        (payload.signaling_session_id && payload.signaling_session_id !== sessionId)) {
      return Promise.resolve({ok: false, error: "unavailable"})
    }
    return sendPush(callChannel, event, {...payload, signaling_session_id: sessionId},
      () => isCurrentCallCommand(capturedGeneration, sessionId, callId) && state.call?.ownership === "self",
      (reply, settle) => settle({ ...reply, ok: true }))
  }

  function mediaSessionIsCurrent(identity) {
    return Boolean(identity && state.connectionStatus === "connected" && callTopicStatus === "joined" &&
      joinedCallId === identity.call_id && state.call?.call_id === identity.call_id &&
      callSignalingSessionId === identity.signaling_session_id && state.call?.ownership === "self" &&
      ["connecting", "active"].includes(state.call?.state))
  }

  function onServerIce(listener) {
    mediaListeners.add(listener)
    return () => mediaListeners.delete(listener)
  }

  function sendCallCommand(event, callId, fields, applyReply) {
    const currentCallChannel = callChannel
    const capturedCallGeneration = callGeneration
    const capturedCallSignalingSessionId = callSignalingSessionId

    if (
      state.connectionStatus !== "connected" ||
      !capturedCallSignalingSessionId ||
      !callId ||
      state.call?.call_id !== callId ||
      joinedCallId !== callId
    ) {
      return Promise.resolve({ok: false, error: "unavailable"})
    }

    return sendPush(
      currentCallChannel,
      event,
      {
        signaling_session_id: capturedCallSignalingSessionId,
        call_id: callId,
        ...fields,
      },
      () => isCurrentCallCommand(capturedCallGeneration, capturedCallSignalingSessionId, callId),
      (reply, settle) => {
        settle({
          ok: true,
          signaling_session_id: reply?.signaling_session_id ?? capturedCallSignalingSessionId,
          call: freezeCall(reply?.call),
        })
        applyReply(reply)
      },
    )
  }

  function sendPush(targetChannel, event, payload, isCurrent, onOk) {
    if (
      !targetChannel ||
      (typeof targetChannel.canPush === "function" && !targetChannel.canPush())
    ) {
      return Promise.resolve({ok: false, error: "unavailable"})
    }

    const push = targetChannel.push(event, payload)

    if (!push || typeof push.receive !== "function") {
      return Promise.resolve({ok: false, error: "unavailable"})
    }

    const bucket = targetChannel === callChannel ? callInflight : inflight
    return trackInflight(bucket, (settle) => {
      push.receive("ok", reply => {
        if (!isCurrent()) {
          settle({ok: false, error: "unavailable"})
          return
        }

        onOk(reply, settle)
      })

      push.receive("error", error => {
        if (!isCurrent()) {
          settle({ok: false, error: "unavailable"})
          return
        }

        settle({
          ok: false,
          error: typeof error?.reason === "string" ? error.reason : "unavailable",
        })
      })

      push.receive("timeout", () => {
        settle({ok: false, error: "timeout"})
      })
    })
  }

  function teardownSocket() {
    generation += 1
    retiredCallIds = new Set()
    terminalCallIds = new Set()
    leaveCallChannel()
    failInflight("unavailable", inflight)
    failInflight("unavailable", callInflight)
    channel?.leave?.()
    socket?.disconnect?.()
    channel = null
    socket = null
  }

  function registerInboxHandlers(joinedChannel, currentGeneration) {
    const onRinging = payload => {
      if (currentGeneration !== generation) return
      applyRinging(payload)
    }

    joinedChannel.on("incoming_call", onRinging)
    joinedChannel.on("outgoing_call_ringing", onRinging)

    const onTerminal = payload => {
      if (currentGeneration !== generation) return
      applyMatchingTerminal(payload)
    }

    for (const event of CALL_TERMINAL_EVENTS) {
      joinedChannel.on(event, onTerminal)
    }

    const onLifecycle = payload => {
      if (currentGeneration !== generation) return
      applyMatchingLifecycle(payload)
    }

    for (const event of CALL_LIFECYCLE_EVENTS) {
      joinedChannel.on(event, onLifecycle)
    }

    for (const event of CALL_SIBLING_EVENTS) {
      joinedChannel.on(event, onLifecycle)
    }

    joinedChannel.onError?.(() => {
      if (currentGeneration !== generation) return
      markUnavailable()
    })
    joinedChannel.onClose?.(() => {
      if (currentGeneration !== generation) return
      markUnavailable()
    })
  }

  function registerCallHandlers(joinedChannel, currentCallGeneration) {
    const onTerminal = payload => {
      if (currentCallGeneration !== callGeneration) return
      applyMatchingTerminal(payload)
    }

    for (const event of CALL_TERMINAL_EVENTS) {
      joinedChannel.on(event, onTerminal)
    }

    const onLifecycle = payload => {
      if (currentCallGeneration !== callGeneration) return
      applyMatchingLifecycle(payload)
    }

    for (const event of CALL_LIFECYCLE_EVENTS) {
      joinedChannel.on(event, onLifecycle)
    }

    for (const event of CALL_SIBLING_EVENTS) {
      joinedChannel.on(event, onLifecycle)
    }

    for (const event of ["ice_candidate", "video_presentation"]) joinedChannel.on(event, payload => {
      if (currentCallGeneration !== callGeneration || payload?.call_id !== joinedCallId ||
          payload?.signaling_session_id !== callSignalingSessionId || state.call?.ownership !== "self") return
      for (const listener of mediaListeners) listener(payload)
    })

    const lost = () => {
      if (currentCallGeneration !== callGeneration) return
      failInflight("unavailable", callInflight)
      abandonCallChannel(currentCallGeneration)
      callGeneration += 1
      callTopicStatus = "failed"
      replaceState({...state})
    }
    joinedChannel.onError?.(lost)
    joinedChannel.onClose?.(lost)
  }

  function applyJoinSnapshot(payload) {
    failInflight("unavailable", inflight)
    failInflight("unavailable", callInflight)
    applyAuthoritativeCall(
      payload?.call,
      payload?.signaling_session_id ?? null,
      "connected",
    )
  }

  function applyStartReply(reply) {
    applyAuthoritativeCall(
      reply?.call,
      reply?.signaling_session_id ?? state.signalingSessionId,
      "connected",
    )
  }

  function applyRinging(payload) {
    const incoming = freezeCall(payload?.call)
    const incomingId = incoming?.call_id
    if (!incomingId || retiredCallIds.has(incomingId)) return

    const currentCall = getState().call
    if (currentCall?.call_id === incomingId) {
      const incomingRank = CALL_LIFECYCLE_RANK[incoming.state] ?? CALL_LIFECYCLE_RANK.ringing
      const currentRank = CALL_LIFECYCLE_RANK[currentCall.state] ?? CALL_LIFECYCLE_RANK.ringing
      if (incomingRank < currentRank) return
    } else if (currentCall?.call_id) {
      retireCallId(currentCall.call_id)
    }

    syncCallChannel(incoming)
    replaceState({
      connectionStatus: "connected",
      signalingSessionId: payload?.signaling_session_id ?? getState().signalingSessionId,
      call: incoming,
      terminalCall: null,
    })
  }

  function applyAuthoritativeCall(call, signalingSessionId, connectionStatus) {
    let nextCall = latestCallProjection(call)
    const previousId = getState().call?.call_id
    let terminalCall = null

    if (nextCall?.state === "terminal") {
      if (previousId && previousId !== nextCall.call_id) retireCallId(previousId)
      retireCallId(nextCall.call_id)
      terminalCallIds.add(nextCall.call_id)
      terminalCall = nextCall
      nextCall = null
    } else if (nextCall?.call_id && terminalCallIds.has(nextCall.call_id)) {
      return
    } else if (nextCall?.call_id) {
      if (previousId && previousId !== nextCall.call_id) retireCallId(previousId)
      retiredCallIds.delete(nextCall.call_id)
    } else if (previousId) {
      retireCallId(previousId)
    }

    syncCallChannel(nextCall)
    replaceState({
      connectionStatus,
      signalingSessionId,
      call: nextCall,
      terminalCall,
    })
  }

  function latestCallProjection(call) {
    const incoming = freezeCall(call)
    const current = getState().call
    if (incoming?.call_id && current?.call_id === incoming.call_id &&
        CALL_LIFECYCLE_RANK[incoming.state] < CALL_LIFECYCLE_RANK[current.state]) return current
    if (incoming?.call_id && current?.call_id === incoming.call_id &&
        ["connecting", "active"].includes(incoming.state)) {
      const mediaState = {...current.media_state}
      for (const [role, snapshot] of Object.entries(incoming.media_state ?? {})) {
        if (!mediaState[role] || snapshot.media_state_version > mediaState[role].media_state_version) {
          mediaState[role] = snapshot
        }
      }
      if (Object.keys(mediaState).length) return freezeCall({...incoming, media_state: mediaState})
    }
    return incoming
  }

  function applyMatchingLifecycle(payload) {
    const incoming = latestCallProjection(payload?.call)
    const currentCall = getState().call
    if (!incoming?.call_id || !currentCall || currentCall.call_id !== incoming.call_id) return
    if (terminalCallIds.has(incoming.call_id) || incoming.state === "terminal") return
    if (!CALL_LIFECYCLE_EVENTS.includes(`call_${incoming.state}`)) return
    if (CALL_LIFECYCLE_RANK[incoming.state] < CALL_LIFECYCLE_RANK[currentCall.state]) return
    if (sameProjection(currentCall, incoming)) return

    syncCallChannel(incoming)
    replaceState({
      connectionStatus: getState().connectionStatus,
      // Lifecycle events arrive on both the inbox and the Call topic. Only the
      // inbox identity authorizes inbox commands, so a Call-topic delivery must
      // never replace it.
      signalingSessionId: getState().signalingSessionId,
      call: incoming,
      terminalCall: null,
    })
  }

  function applyMatchingTerminal(payload) {
    const incomingId = payload?.call?.call_id
    const currentCall = getState().call
    if (!incomingId || !currentCall || currentCall.call_id !== incomingId) return

    retireCallId(incomingId)
    terminalCallIds.add(incomingId)
    if (joinedCallId === incomingId) leaveCallChannel()
    replaceState({
      connectionStatus: getState().connectionStatus,
      signalingSessionId: getState().signalingSessionId,
      call: null,
      terminalCall: freezeCall(payload.call),
    })
  }

  function syncCallChannel(call) {
    const callId = call?.call_id
    if (!callId || (call.state && !["ringing", "connecting", "active"].includes(call.state))) {
      leaveCallChannel()
      return
    }

    if (joinedCallId === callId && callChannel) return

    leaveCallChannel()
    joinCallChannel(callId)
  }

  function retireCallId(callId) {
    if (callId) retiredCallIds.add(callId)
  }

  function joinCallChannel(callId) {
    if (!socket) return

    const currentCallGeneration = ++callGeneration
    const topic = callTopic(callId)
    joinedCallId = callId
    callChannel = socket.channel(topic, {})
    callTopicStatus = "joining"
    registerCallHandlers(callChannel, currentCallGeneration)

    callChannel.join()
      .receive("ok", payload => {
        if (currentCallGeneration !== callGeneration) return
        if (getState().call?.call_id !== callId) return
        if (payload?.call?.call_id && payload.call.call_id !== callId) return
        if (payload?.call?.state === "terminal") {
          applyMatchingTerminal(payload)
          return
        }

        callSignalingSessionId = payload?.signaling_session_id ?? null
        callTopicStatus = "joined"
        replaceState({
          connectionStatus: getState().connectionStatus,
          signalingSessionId: getState().signalingSessionId,
          call: payload?.call ? latestCallProjection(payload.call) : getState().call,
          terminalCall: null,
        })
      })
      .receive("error", () => {
        if (currentCallGeneration !== callGeneration) return
        abandonCallChannel(currentCallGeneration)
        callTopicStatus = "failed"
        replaceState({
          connectionStatus: getState().connectionStatus,
          signalingSessionId: getState().signalingSessionId,
          call: getState().call,
        })
      })
  }

  function leaveCallChannel() {
    if (!callChannel && !joinedCallId) {
      callTopicStatus = "idle"
      return
    }

    callGeneration += 1
    failInflight("unavailable", callInflight)
    callChannel?.leave?.()
    callChannel = null
    callSignalingSessionId = null
    joinedCallId = null
    callTopicStatus = "idle"
  }

  function abandonCallChannel(currentCallGeneration) {
    if (currentCallGeneration !== callGeneration) return

    callSignalingSessionId = null
    callChannel = null
    joinedCallId = null
  }

  function markUnavailable() {
    failInflight("unavailable", inflight)
    failInflight("unavailable", callInflight)
    leaveCallChannel()
    replaceState({
      connectionStatus: "unavailable",
      signalingSessionId: null,
      call: null,
    })
  }

  function isCurrentStart(capturedGeneration, capturedSignalingSessionId) {
    return (
      capturedGeneration === generation &&
      state.connectionStatus === "connected" &&
      state.signalingSessionId === capturedSignalingSessionId
    )
  }

  function isCurrentCallCommand(capturedCallGeneration, capturedCallSignalingSessionId, callId) {
    return (
      capturedCallGeneration === callGeneration &&
      callSignalingSessionId === capturedCallSignalingSessionId &&
      state.connectionStatus === "connected" &&
      state.call?.call_id === callId
    )
  }

  function trackInflight(bucket, register) {
    return new Promise(resolve => {
      let settled = false
      const settle = result => {
        if (settled) return
        settled = true
        bucket.delete(pending)
        resolve(result)
      }
      const pending = {settle}
      bucket.add(pending)
      register(settle)
    })
  }

  function failInflight(error, bucket) {
    const pendingCommands = [...bucket]
    bucket.clear()
    for (const pending of pendingCommands) pending.settle({ok: false, error})
  }

  function replaceState(next) {
    state = freezeState({...next, callTopicStatus})
    for (const listener of listeners) listener(state)
  }

  return {
    connect,
    disconnect,
    dispose,
    subscribe,
    getState,
    startCall,
    acceptCall,
    declineCall,
    cancelCall,
    leaveCall,
    mediaCredentials,
    sendMedia,
    mediaSessionIsCurrent,
    onServerIce,
  }
}

function sameProjection(left, right) {
  return JSON.stringify(left) === JSON.stringify(right)
}

function freezeCall(call) {
  if (!call) return null
  const frozen = {...call}
  if (call.peer) frozen.peer = Object.freeze({...call.peer})
  if (["connecting", "active"].includes(call.state)) {
    const mediaState = {}
    for (const role of ["caller", "recipient"]) {
      const snapshot = call.media_state?.[role]
      if (Number.isSafeInteger(snapshot?.media_state_version) && snapshot.media_state_version >= 0 &&
          typeof snapshot.microphone_muted === "boolean" && typeof snapshot.camera_enabled === "boolean") {
        mediaState[role] = Object.freeze({media_state_version: snapshot.media_state_version,
          microphone_muted: snapshot.microphone_muted, camera_enabled: snapshot.camera_enabled})
      }
    }
    if (Object.keys(mediaState).length || call.media_state) frozen.media_state = Object.freeze(mediaState)
  } else delete frozen.media_state
  return Object.freeze(frozen)
}

function freezeState(next) {
  const state = {
    connectionStatus: next.connectionStatus,
    signalingSessionId: next.signalingSessionId ?? null,
    call: freezeCall(next.call),
    callTopicStatus: next.callTopicStatus ?? "idle",
  }
  if (next.terminalCall) state.terminalCall = freezeCall(next.terminalCall)
  return Object.freeze(state)
}
