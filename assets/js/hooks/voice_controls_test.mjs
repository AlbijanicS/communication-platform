import assert from "node:assert/strict"
import {readFile} from "node:fs/promises"
import test from "node:test"

const hookSource = await readFile(new URL("./voice_controls.js", import.meta.url), "utf8")
const hookModuleUrl = `data:text/javascript;base64,${Buffer.from(hookSource.replace('import voiceController from "./voice_controller"', "const voiceController = null")).toString("base64")}`
const {createVoiceControls} = await import(hookModuleUrl)

function eventTarget() {
  const listeners = new Map()

  return {
    addEventListener(name, listener) { listeners.set(name, listener) },
    removeEventListener(name) { listeners.delete(name) },
    dispatch(name, event = {}) { listeners.get(name)?.(event) },
  }
}

function mountVoiceControls(state) {
  let currentState = state
  let listener
  const calls = []
  const channel = {textContent: ""}
  const status = {textContent: "", setAttribute(name, value) { this[name] = value }}
  const announcement = {textContent: ""}
  const mute = {textContent: "", setAttribute(name, value) { this[name] = value }}
  const deafen = {textContent: "", setAttribute(name, value) { this[name] = value }}
  const panel = {hidden: true}
  const retry = {hidden: true}
  const enableAudio = {hidden: true}
  const localActions = {hidden: false}
  globalThis.document = eventTarget()
  const controller = {
    join(channel) { calls.push({join: channel}) },
    leave() { calls.push("leave") },
    retry() { calls.push("retry") },
    enableAudio() { calls.push("enableAudio") },
    state() { return currentState },
    subscribe(nextListener) { listener = nextListener; listener(currentState); return () => listener = null },
    toggleMute() { calls.push("toggleMute") },
    toggleDeafen() { calls.push("toggleDeafen") },
  }
  const elements = {
    "[data-voice-controls-channel]": channel,
    "[data-voice-controls-status]": status,
    "[data-voice-controls-announcement]": announcement,
    "[data-voice-controls-mute]": mute,
    "[data-voice-controls-deafen]": deafen,
    "[data-voice-controls-panel]": panel,
    "[data-voice-controls-retry]": retry,
    "[data-voice-controls-enable-audio]": enableAudio,
    "[data-voice-controls-local-actions]": localActions,
  }
  const hook = {...createVoiceControls(controller), el: {querySelector: selector => elements[selector]}}
  hook.mounted()
  return {announcement, calls, channel, deafen, emit(nextState) { currentState = nextState; listener(nextState) }, hook, localActions, mute, panel, retry, enableAudio, status}
}

test("the rail adapter immediately renders an existing capture and controls it without requesting media again", () => {
  const mounted = mountVoiceControls({channelId: "voice-1", channelName: "lobby", status: "capturing", workspaceId: "workspace-1"})

  assert.equal(mounted.channel.textContent, "lobby")
  assert.equal(mounted.status.textContent, "Joining voice…")
  assert.equal(mounted.announcement.textContent, "")
  assert.equal(mounted.mute.textContent, "Mute")
  assert.equal(mounted.deafen.textContent, "Deafen")

  const muteButton = {closest: selector => selector === "[data-voice-controls-mute]" ? muteButton : null}
  document.dispatch("click", {target: muteButton})
  assert.deepEqual(mounted.calls, ["toggleMute"])

  const deafenButton = {closest: selector => selector === "[data-voice-controls-deafen]" ? deafenButton : null}
  document.dispatch("click", {target: deafenButton})
  assert.deepEqual(mounted.calls, ["toggleMute", "toggleDeafen"])

  const leaveButton = {closest: selector => selector === "[data-voice-controls-leave]" ? leaveButton : null}
  document.dispatch("click", {target: leaveButton})
  assert.deepEqual(mounted.calls, ["toggleMute", "toggleDeafen", "leave"])

  assert.equal(mounted.panel.hidden, false)

  mounted.hook.destroyed()
  document.dispatch("click", {target: muteButton})
  assert.deepEqual(mounted.calls, ["toggleMute", "toggleDeafen", "leave"])
})

test("a Voice Channel row delegates joining to the global Voice Owner Tab controller", () => {
  const mounted = mountVoiceControls({channelId: null, channelName: null, status: "idle", workspaceId: null})
  const joinButton = {
    closest(selector) {
      return selector === "[data-voice-channel-join]" ? joinButton : null
    },
    dataset: {voiceChannelId: "voice-1", voiceChannelName: "lobby", workspaceId: "workspace-1"},
  }

  document.dispatch("click", {target: joinButton})

  assert.deepEqual(mounted.calls, [{join: {id: "voice-1", name: "lobby", workspaceId: "workspace-1"}}])
  mounted.hook.destroyed()
})

test("the rail renders a browser failure and delegates its explicit retry", () => {
  const mounted = mountVoiceControls({channelId: "voice-1", channelName: "lobby", error: "no_device", retryable: true, status: "no_device", workspaceId: "workspace-1"})

  assert.equal(mounted.status.textContent, "No microphone was found. Connect an input, then retry.")
  assert.equal(mounted.announcement.textContent, "No microphone was found. Connect an input, then retry.")
  assert.equal(mounted.status["aria-live"], "off")
  assert.equal(mounted.retry.hidden, false)
  assert.equal(mounted.panel.hidden, false)

  const retryButton = {closest: selector => selector === "[data-voice-controls-retry]" ? retryButton : null}
  document.dispatch("click", {target: retryButton})
  assert.deepEqual(mounted.calls, ["retry"])
  mounted.hook.destroyed()
})

test("the rail explains a retryable four-slot compatibility failure", () => {
  const mounted = mountVoiceControls({channelId: "voice-1", channelName: "lobby", error: "incompatible_audio_output_slots", retryable: true, status: "incompatible_audio_output_slots", workspaceId: "workspace-1"})

  assert.equal(mounted.status.textContent, "This browser could not prepare group audio. Try again after checking browser support.")
  assert.equal(mounted.retry.hidden, false)
  assert.equal(mounted.panel.hidden, false)
  mounted.hook.destroyed()
})

test("the rail announces blocked remote playback and delegates Enable audio without retrying microphone capture", () => {
  const mounted = mountVoiceControls({audioPlayback: "blocked", channelId: "voice-1", channelName: "lobby", status: "connected", workspaceId: "workspace-1"})

  assert.equal(mounted.status.textContent, "Audio is ready — select Enable audio to hear it.")
  assert.equal(mounted.announcement.textContent, "Audio is ready — select Enable audio to hear it.")
  assert.equal(mounted.enableAudio.hidden, false)
  assert.equal(mounted.panel.hidden, false)

  const enableButton = {closest: selector => selector === "[data-voice-controls-enable-audio]" ? enableButton : null}
  document.dispatch("click", {target: enableButton})
  assert.deepEqual(mounted.calls, ["enableAudio"])
  mounted.hook.destroyed()
})

test("the rail keeps a Voice Owner Tab takeover discoverable without active controls", () => {
  const mounted = mountVoiceControls({channelId: "voice-1", channelName: "lobby", error: "taken_over", retryable: false, status: "taken_over", workspaceId: "workspace-1"})

  assert.equal(mounted.channel.textContent, "lobby")
  assert.equal(mounted.status.textContent, "Voice moved to another tab")
  assert.equal(mounted.announcement.textContent, "Voice moved to another tab")
  assert.equal(mounted.status["aria-live"], "off")
  assert.equal(mounted.retry.hidden, true)
  assert.equal(mounted.panel.hidden, false)
  assert.equal(mounted.localActions.hidden, true)
  mounted.hook.destroyed()
})

test("the persistent panel remains visible through controller state updates until Voice ends", () => {
  const mounted = mountVoiceControls({channelId: "voice-1", channelName: "lobby", status: "capturing", workspaceId: "workspace-1"})

  mounted.emit({channelId: "voice-1", channelName: "lobby", status: "muted", workspaceId: "workspace-1"})
  assert.equal(mounted.panel.hidden, false)

  mounted.emit({channelId: null, channelName: null, status: "idle", workspaceId: null})
  assert.equal(mounted.panel.hidden, true)
  mounted.hook.destroyed()
})

test("the panel distinguishes an interrupted connection while retaining ordinary Voice controls", () => {
  const mounted = mountVoiceControls({channelId: "voice-1", channelName: "lobby", status: "interrupted", workspaceId: "workspace-1"})

  assert.equal(mounted.status.textContent, "Connection interrupted")
  assert.equal(mounted.panel.hidden, false)
  assert.equal(mounted.localActions.hidden, false)
  mounted.hook.destroyed()
})

test("muted controls show the actual joining and interrupted lifecycle", () => {
  const mounted = mountVoiceControls({status: "joining", connectionStatus: "joining", muted: true, deafened: true})
  assert.equal(mounted.status.textContent, "Joining voice…")
  assert.equal(mounted.mute["aria-pressed"], "true")
  assert.equal(mounted.deafen["aria-pressed"], "true")
  mounted.emit({status: "muted", connectionStatus: "interrupted", muted: true, deafened: true})
  assert.equal(mounted.status.textContent, "Connection interrupted")
  assert.equal(mounted.mute.textContent, "Unmute")
  mounted.emit({status: "muted", connectionStatus: "connected", muted: true, deafened: true})
  assert.equal(mounted.status.textContent, "Connected")
  mounted.hook.destroyed()
})
