export function createVoiceSignaling({Socket, csrfToken} = {}) {
  let socket = null
  let channel = null

  function ensureSocket() {
    if (socket) return socket

    socket = new Socket("/voice", {params: {_csrf_token: csrfToken}})
    socket.connect()
    return socket
  }

  return {
    join(voiceChannelId, params = {}) {
      if (channel) this.leave()

      channel = ensureSocket().channel(`voice:${voiceChannelId}`, params)
      return channel.join()
    },

    joinVoiceChannel(voiceChannelId, params = {}) {
      return awaitReply(this.join(voiceChannelId, params))
    },

    sendOffer(offer) {
      const push = channel?.push("offer", offer)
      return push ? awaitReply(push) : Promise.reject(new Error("voice signaling is not joined"))
    },

    sendIce(ice) {
      return channel?.push("ice_candidate", ice) ?? null
    },

    renewVoiceSession(renewal) {
      return channel?.push("renew", renewal) ?? null
    },

    sendLocalVoiceState(state) {
      return channel?.push("local_voice_state", state) ?? null
    },

    reportIceRoute(diagnostic) {
      return channel?.push("ice_route", diagnostic) ?? null
    },

    onServerIce(callback) {
      return channel?.on("ice_candidate", callback) ?? null
    },

    onVoiceSessionEnded(callback) {
      return channel?.on("voice_session_ended", callback) ?? null
    },

    onClose(callback) {
      return channel?.onClose(callback) ?? null
    },

    onRosterCue(callback) {
      return channel?.on("voice_roster_cue", callback) ?? null
    },

    leave() {
      if (!channel) return null

      const leave = channel.leave()
      channel = null
      return leave
    },

    disconnect() {
      this.leave()
      socket?.disconnect()
      socket = null
    },
  }
}

function awaitReply(push) {
  return new Promise((resolve, reject) => {
    push.receive("ok", resolve)
    push.receive("error", reject)
    push.receive("timeout", () => reject(new Error("voice signaling request timed out")))
  })
}
