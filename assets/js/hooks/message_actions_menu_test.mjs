import assert from "node:assert/strict"
import {readFile} from "node:fs/promises"
import test from "node:test"

const hookSource = await readFile(new URL("./message_actions_menu.js", import.meta.url), "utf8")
const hookModuleUrl = `data:text/javascript;base64,${Buffer.from(hookSource).toString("base64")}`
const {default: MessageActionsMenu} = await import(hookModuleUrl)

function eventTarget() {
  const listeners = new Map()

  return {
    addEventListener(name, listener) {
      listeners.set(name, listener)
    },
    removeEventListener(name) {
      listeners.delete(name)
    },
    dispatch(name, event = {}) {
      listeners.get(name)?.(event)
    },
  }
}

function mountMenu() {
  const insideTarget = {}
  const outsideTarget = {}
  const actionsLayer = {
    style: {
      zIndex: "",
      removeProperty(property) {
        if (property === "z-index") this.zIndex = ""
      },
    },
  }
  const summary = {
    focused: false,
    focus() {
      this.focused = true
    },
    getBoundingClientRect() {
      return {bottom: 40, right: 100, top: 12}
    },
    style: {
      opacity: "",
      removeProperty() {},
    },
  }
  const panel = {
    getBoundingClientRect() {
      return {height: 200, width: 160}
    },
    style: {},
  }
  const elementEvents = eventTarget()
  const el = {
    ...elementEvents,
    open: true,
    parentElement: actionsLayer,
    contains(target) {
      return target === insideTarget
    },
    querySelector(selector) {
      return selector === "[data-message-menu-summary]" ? summary : panel
    },
  }
  const hook = {el, ...MessageActionsMenu}

  hook.mounted()

  return {actionsLayer, el, hook, insideTarget, outsideTarget, summary}
}

globalThis.window = {
  ...eventTarget(),
  innerHeight: 800,
  innerWidth: 1200,
}
globalThis.document = {
  ...eventTarget(),
  getElementById() {
    return null
  },
}

test("an open moderation menu stays open after the pointer leaves its trigger", async () => {
  const {el, hook} = mountMenu()

  el.dispatch("mouseleave")
  await new Promise(resolve => setTimeout(resolve, 300))

  assert.equal(el.open, true)
  hook.destroyed()
})

test("pointer interaction inside the moderation menu keeps it open", () => {
  const {el, hook, insideTarget} = mountMenu()

  document.dispatch("pointerdown", {target: insideTarget})

  assert.equal(el.open, true)
  hook.destroyed()
})

test("an outside pointer interaction closes the moderation menu", () => {
  const {actionsLayer, el, hook, outsideTarget} = mountMenu()

  el.dispatch("toggle")

  document.dispatch("pointerdown", {target: outsideTarget})

  assert.equal(el.open, false)
  assert.equal(actionsLayer.style.zIndex, "")
  hook.destroyed()
})

test("Escape closes the moderation menu and restores trigger focus", () => {
  const {el, hook, summary} = mountMenu()

  document.dispatch("keydown", {key: "Escape"})

  assert.equal(el.open, false)
  assert.equal(summary.focused, true)
  hook.destroyed()
})

test("an open moderation menu elevates its message action layer above sibling reactions", () => {
  const {actionsLayer, el, hook} = mountMenu()

  el.dispatch("toggle")

  assert.equal(actionsLayer.style.zIndex, "50")
  hook.destroyed()
})
