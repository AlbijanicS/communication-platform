export const CUE_CHANNEL_NAME = "discord_clone:direct_call_cues:v1"

export const CUE_ELECTION_WINDOW_MS = 150
export const CUE_HEARTBEAT_MS = 500
export const CUE_LEASE_MS = 1_500

const CUE_TYPES = ["candidate", "claim", "renew", "release"]
const CUE_KINDS = ["incoming", "outgoing"]

export function createCallCueCoordinator({
  BroadcastChannel = globalThis.BroadcastChannel,
  now = () => Date.now(),
  scheduleTimeout = (callback, delay) => setTimeout(callback, delay),
  cancelTimeout = clearTimeout,
  scheduleInterval = (callback, delay) => setInterval(callback, delay),
  cancelInterval = clearInterval,
  createContenderId = defaultContenderId,
  onElected = () => {},
  onRevoked = () => {},
  electionWindowMs = CUE_ELECTION_WINDOW_MS,
  heartbeatMs = CUE_HEARTBEAT_MS,
  leaseMs = CUE_LEASE_MS,
} = {}) {
  let disposed = false
  let channel = null
  let current = null
  let candidates = new Map()
  let winner = null
  let leaseExpiresAt = 0
  let elected = false
  let lastClaimAt = 0
  let electionTimer = null
  let heartbeatTimer = null
  let leaseTimer = null
  const contenderId = createContenderId?.() ?? null

  function contend({callId, kind} = {}) {
    if (disposed) return
    if (!validCue(callId, kind)) return
    if (current && current.callId === callId && current.kind === kind) return

    withdraw()
    if (disposed) return

    current = {callId, kind}
    candidates = new Map()
    if (!contenderId) return

    candidates.set(contenderId, now())
    if (!openChannel()) return

    scheduleElection(electionWindowMs)
    announce("candidate", callId, kind)
  }

  function withdraw() {
    const previous = current
    const wasElected = elected

    elected = false
    winner = null
    leaseExpiresAt = 0
    current = null
    candidates = new Map()
    cancelElection()
    cancelHeartbeat()
    cancelLease()

    if (wasElected) invoke(onRevoked)
    if (previous) announce("release", previous.callId, previous.kind)
    closeChannel()
  }

  function dispose() {
    if (disposed) return
    withdraw()
    disposed = true
  }

  function onMessage(event) {
    if (disposed || !current) return

    const message = event?.data
    if (!validMessage(message)) return
    if (message.callId !== current.callId) return
    if (message.kind && message.kind !== current.kind) return
    if (message.contenderId === contenderId) return

    if (message.type === "candidate") onCandidate(message)
    if (message.type === "claim" || message.type === "renew") onClaim(message)
    if (message.type === "release") onRelease(message)
  }

  function onCandidate(message) {
    const known = candidates.has(message.contenderId)
    candidates.set(message.contenderId, now())

    if (elected) {
      sendClaim("renew")
      return
    }

    if (!known) announce("candidate", current.callId, current.kind)
  }

  function onClaim(message) {
    const claimTime = now()

    if (elected) {
      const renewing = claimTime - lastClaimAt < leaseMs
      if (message.contenderId < contenderId || !renewing) {
        yieldTo(message.contenderId, claimTime)
      }
      return
    }

    // A fresh claim means a concurrent contender just won its own election,
    // and a renewal from a contender we have heard contend is equally a
    // concurrent election that may have missed our candidacy. While our own
    // election is pending, neither can cancel it — the smallest contender
    // must still win deterministically. Only a larger contender we have
    // never seen contend is an established winner whose live lease we
    // respect.
    if (electionTimer != null && message.contenderId > contenderId) {
      if (message.type === "claim") {
        candidates.set(message.contenderId, claimTime)
        return
      }
      if (candidates.has(message.contenderId)) return
    }

    winner = message.contenderId
    leaseExpiresAt = claimTime + leaseMs
    cancelElection()
    scheduleLeaseCheck()
  }

  function yieldTo(contender, claimTime) {
    elected = false
    invoke(onRevoked)
    cancelHeartbeat()
    winner = contender
    leaseExpiresAt = claimTime + leaseMs
    scheduleLeaseCheck()
  }

  function onRelease(message) {
    candidates.delete(message.contenderId)
    if (winner !== message.contenderId) return

    winner = null
    leaseExpiresAt = 0
    cancelLease()
    if (!elected && current) scheduleElection(electionWindowMs)
  }

  function runElection() {
    electionTimer = null
    if (disposed || !current || elected) return
    if (winner && winner !== contenderId && now() < leaseExpiresAt) return

    candidates.set(contenderId, now())
    const chosen = [...candidates.keys()].sort()[0]

    if (chosen !== contenderId) {
      winner = chosen
      leaseExpiresAt = now() + leaseMs
      scheduleLeaseCheck()
      return
    }

    if (!sendClaim("claim")) return

    elected = true
    winner = contenderId
    if (!startHeartbeat()) {
      elected = false
      winner = null
      return
    }

    invoke(onElected, {kind: current.kind, callId: current.callId})
  }

  function sendClaim(type) {
    if (!announce(type, current.callId, current.kind)) return false
    lastClaimAt = now()
    return true
  }

  function openChannel() {
    if (channel) return true
    if (!BroadcastChannel) return false

    let opened = null
    try {
      opened = new BroadcastChannel(CUE_CHANNEL_NAME)
      if (!opened || typeof opened.postMessage !== "function") return false
      channel = opened
      channel.addEventListener?.("message", onMessage)
      return true
    } catch (_) {
      channel = null
      return false
    }
  }

  function closeChannel() {
    const closing = channel
    channel = null
    if (!closing) return

    try {
      closing.removeEventListener?.("message", onMessage)
    } catch (_) {}
    try {
      closing.close?.()
    } catch (_) {}
  }

  function announce(type, callId, kind) {
    if (!channel) return false
    const message = {type, callId, contenderId}
    if (kind) message.kind = kind

    try {
      channel.postMessage(message)
      return true
    } catch (_) {
      return false
    }
  }

  function scheduleElection(delay) {
    cancelElection()
    try {
      electionTimer = scheduleTimeout(() => {
        electionTimer = null
        runElection()
      }, delay)
    } catch (_) {
      electionTimer = null
    }
  }

  function scheduleLeaseCheck() {
    cancelLease()
    const remaining = Math.max(0, leaseExpiresAt - now())

    try {
      leaseTimer = scheduleTimeout(() => {
        leaseTimer = null
        if (disposed || !current || elected) return
        if (winner && now() < leaseExpiresAt) {
          scheduleLeaseCheck()
          return
        }

        if (winner) candidates.delete(winner)
        winner = null
        leaseExpiresAt = 0
        scheduleElection(electionWindowMs)
      }, remaining)
    } catch (_) {
      leaseTimer = null
    }
  }

  function startHeartbeat() {
    cancelHeartbeat()
    try {
      heartbeatTimer = scheduleInterval(() => {
        if (disposed || !elected || !current) return
        sendClaim("renew")
      }, heartbeatMs)
      return true
    } catch (_) {
      heartbeatTimer = null
      return false
    }
  }

  function cancelElection() {
    if (electionTimer == null) return
    const timer = electionTimer
    electionTimer = null
    try {
      cancelTimeout(timer)
    } catch (_) {}
  }

  function cancelHeartbeat() {
    if (heartbeatTimer == null) return
    const timer = heartbeatTimer
    heartbeatTimer = null
    try {
      cancelInterval(timer)
    } catch (_) {}
  }

  function cancelLease() {
    if (leaseTimer == null) return
    const timer = leaseTimer
    leaseTimer = null
    try {
      cancelTimeout(timer)
    } catch (_) {}
  }

  function invoke(callback, payload) {
    try {
      if (payload === undefined) callback()
      else callback(payload)
    } catch (_) {}
  }

  return {contend, withdraw, dispose}
}

function validCue(callId, kind) {
  return typeof callId === "string" && callId !== "" && CUE_KINDS.includes(kind)
}

function validMessage(message) {
  if (!message || typeof message !== "object") return false
  if (!CUE_TYPES.includes(message.type)) return false
  if (typeof message.callId !== "string" || message.callId === "") return false
  if (typeof message.contenderId !== "string" || message.contenderId === "") return false
  if (message.type !== "release" && !CUE_KINDS.includes(message.kind)) return false
  return true
}

function defaultContenderId() {
  try {
    if (globalThis.crypto?.randomUUID) return globalThis.crypto.randomUUID()
  } catch (_) {}

  return `cue-${Math.random().toString(36).slice(2)}-${Date.now().toString(36)}`
}
