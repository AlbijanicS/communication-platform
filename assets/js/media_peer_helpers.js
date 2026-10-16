const MAX_PENDING_SERVER_CANDIDATE_BYTES = 16 * 8 * 1024

export function turnOnlyIceServer(server) {
  const urls = typeof server.urls === "string" ? [server.urls] : server.urls
  return urls.every(url => /^turns?:/i.test(url))
}

export function browserIceServer(server) {
  if (
    !plainObject(server) ||
    !Object.hasOwn(server, "urls") ||
    !Object.keys(server).every(key => ["credential", "urls", "username"].includes(key))
  ) throw new Error("invalid Voice admission")

  const urls = typeof server.urls === "string" ? [server.urls] : server.urls
  if (!Array.isArray(urls) || urls.length === 0 || !urls.every(standardIceUrl)) {
    throw new Error("invalid Voice admission")
  }

  const hasTurn = urls.some(url => /^turns?:/i.test(url))
  const hasUsername = Object.hasOwn(server, "username")
  const hasCredential = Object.hasOwn(server, "credential")
  if (
    hasUsername !== hasCredential ||
    hasTurn !== hasUsername ||
    (hasUsername && (typeof server.username !== "string" || server.username.length === 0)) ||
    (hasCredential && (typeof server.credential !== "string" || server.credential.length === 0))
  ) throw new Error("invalid Voice admission")

  return {
    urls: server.urls,
    ...(hasUsername ? {username: server.username, credential: server.credential} : {}),
  }
}

function standardIceUrl(url) {
  return typeof url === "string" && /^(stun|stuns|turn|turns):[^\s]+$/i.test(url)
}


export function candidateByteSize(candidate) {
  try {
    return new TextEncoder().encode(JSON.stringify(candidate)).byteLength
  } catch (_) {
    return MAX_PENDING_SERVER_CANDIDATE_BYTES + 1
  }
}

export function withDeadline(promise, timeoutMs, setTimeoutFn, clearTimeoutFn, signal) {
  return new Promise((resolve, reject) => {
    let timeout
    const clear = () => { clearTimeoutFn(timeout); signal?.removeEventListener("abort", cancelled) }
    const cancelled = () => { clear(); reject(new Error("connection cancelled")) }
    if (signal?.aborted) { cancelled(); return }
    signal?.addEventListener("abort", cancelled, {once: true})
    timeout = setTimeoutFn(() => { clear(); reject(new Error("offer reply timed out")) }, timeoutMs)
    timeout?.unref?.()
    Promise.resolve(promise).then(
      result => { clear(); resolve(result) },
      error => { clear(); reject(error) }
    )
  })
}

function plainObject(value) { return value !== null && typeof value === "object" && !Array.isArray(value) }
