import assert from "node:assert/strict"
import {readFile} from "node:fs/promises"
import test from "node:test"

const hookSource = await readFile(new URL("./voice_workspace_badge.js", import.meta.url), "utf8")
const hookModuleUrl = `data:text/javascript;base64,${Buffer.from(hookSource.replace('import voiceController from "./voice_controller"', "const voiceController = null")).toString("base64")}`
const {createVoiceWorkspaceBadge} = await import(hookModuleUrl)

test("a Workspace badge only appears for its active Voice Channel Workspace and opens the shared controls", () => {
  let listener
  const events = []
  globalThis.CustomEvent = class extends Event {
    constructor(type, {detail}) {
      super(type)
      this.detail = detail
    }
  }
  globalThis.window = {dispatchEvent(event) { events.push(event) }}
  const controller = {
    subscribe(nextListener) {
      listener = nextListener
      listener({channelId: "voice-1", channelName: "lobby", status: "capturing", workspaceId: "workspace-1"})
      return () => listener = null
    },
  }
  const hook = {
    ...createVoiceWorkspaceBadge(controller),
    el: {
      addEventListener() {},
      dataset: {workspaceId: "workspace-2"},
      hidden: true,
      querySelector(selector) {
        return {
          "[data-voice-workspace-badge-microphone]": this.microphone,
          "[data-voice-workspace-badge-warning]": this.warning,
        }[selector]
      },
      microphone: {hidden: false},
      removeEventListener() {},
      setAttribute(name, value) { this[name] = value },
      warning: {hidden: true},
    },
  }

  hook.mounted()
  assert.equal(hook.el.hidden, true)

  listener({channelId: "voice-1", channelName: "lobby", status: "muted", workspaceId: "workspace-2"})
  assert.equal(hook.el.hidden, false)

  hook.handleClick()
  assert.equal(events[0].type, "voice-controls:open")
  assert.equal(events[0].detail.trigger, hook.el)
  assert.equal(hook.el["aria-expanded"], "true")

  listener({channelId: null, channelName: null, status: "idle", workspaceId: null})
  assert.equal(hook.el["aria-expanded"], "false")

  listener({channelId: "voice-2", channelName: "standup", error: "no_device", retryable: true, status: "no_device", workspaceId: "workspace-2"})
  assert.equal(hook.el.hidden, false)
  assert.equal(hook.el.microphone.hidden, true)
  assert.equal(hook.el.warning.hidden, false)
  assert.equal(hook.el["aria-label"], "Open Voice Channel issue")

  listener({channelId: "voice-2", channelName: "standup", error: "taken_over", retryable: false, status: "taken_over", workspaceId: "workspace-2"})
  assert.equal(hook.el.hidden, false)
  assert.equal(hook.el.microphone.hidden, true)
  assert.equal(hook.el.warning.hidden, false)

  hook.destroyed()
  assert.equal(listener, null)
})
