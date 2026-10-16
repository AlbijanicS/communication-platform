import assert from "node:assert/strict"
import {readFile} from "node:fs/promises"
import test from "node:test"

const hookSource = await readFile(new URL("./voice_lifecycle.js", import.meta.url), "utf8")
const hookModuleUrl = `data:text/javascript;base64,${Buffer.from(hookSource.replace('import voiceController from "./voice_controller"', "const voiceController = null")).toString("base64")}`
const {createVoiceLifecycle} = await import(hookModuleUrl)

function eventTarget() {
  const listeners = new Map()
  return {
    addEventListener(name, listener) { listeners.set(name, listener) },
    removeEventListener(name) { listeners.delete(name) },
    dispatch(name, event = {}) { listeners.get(name)?.(event) },
  }
}

test("logout and page teardown release browser-local voice capture without treating hook removal as teardown", () => {
  const documentTarget = eventTarget()
  const windowTarget = eventTarget()
  let cleanups = 0
  const hook = createVoiceLifecycle({teardown() { cleanups += 1 }}, {documentTarget, windowTarget})

  hook.mounted()
  documentTarget.dispatch("click", {target: {closest: selector => selector === "[data-voice-logout]" ? {} : null}})
  windowTarget.dispatch("pagehide")
  assert.equal(cleanups, 2)

  hook.destroyed()
  windowTarget.dispatch("pagehide")
  assert.equal(cleanups, 2)
})
