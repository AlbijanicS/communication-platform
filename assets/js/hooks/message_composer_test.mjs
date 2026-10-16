import assert from "node:assert/strict"
import {readFile} from "node:fs/promises"
import test from "node:test"

const hookSource = await readFile(new URL("./message_composer.js", import.meta.url), "utf8")
const hookModuleUrl = `data:text/javascript;base64,${Buffer.from(hookSource).toString("base64")}`
const {default: MessageComposer} = await import(hookModuleUrl)

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

function mountComposer({mentionsEnabled, inputType = "INPUT", autocompleteOpen = false}) {
  const input = {
    ...eventTarget(),
    selectionStart: 5,
    scrollHeight: 42,
    style: {},
    tagName: inputType,
    value: "hello",
  }
  const pushedEvents = []
  let submitCount = 0
  const el = {
    dataset: {mentionsEnabled},
    requestSubmit() {
      submitCount += 1
    },
    querySelector(selector) {
      if (selector === "input, textarea") {
        return input
      }

      return selector === "#message-mention-autocomplete" && autocompleteOpen ? {} : null
    },
  }
  const hook = {
    ...MessageComposer,
    el,
    handleEvent() {},
    pushEvent(name, payload) {
      pushedEvents.push({name, payload})
    },
  }

  hook.mounted()

  return {hook, input, pushedEvents, submitCount: () => submitCount}
}

test("a Direct Message composer does not push Workspace mention queries", () => {
  const {hook, input, pushedEvents} = mountComposer({mentionsEnabled: "false"})

  input.dispatch("input")

  assert.deepEqual(pushedEvents, [{name: "message_typing", payload: {}}])
  hook.destroyed()
})

test("a Workspace composer keeps mention queries enabled", () => {
  const {hook, input, pushedEvents} = mountComposer({mentionsEnabled: "true"})

  input.dispatch("input")

  assert.deepEqual(pushedEvents, [
    {
      name: "mention_query",
      payload: {after_cursor: "", before_cursor: "hello"},
    },
    {name: "message_typing", payload: {}},
  ])
  hook.destroyed()
})

test("Enter submits a non-empty multiline composer while Shift+Enter keeps writing", () => {
  const {hook, input, submitCount} = mountComposer({
    mentionsEnabled: "true",
    inputType: "TEXTAREA",
  })

  input.value = "A considered message"
  let enterPrevented = false
  input.dispatch("keydown", {
    isComposing: false,
    key: "Enter",
    preventDefault() {
      enterPrevented = true
    },
    shiftKey: false,
  })

  assert.equal(enterPrevented, true)
  assert.equal(submitCount(), 1)

  input.dispatch("keydown", {
    isComposing: false,
    key: "Enter",
    preventDefault() {
      throw new Error("Shift+Enter must preserve the newline")
    },
    shiftKey: true,
  })

  assert.equal(submitCount(), 1)
  hook.destroyed()
})

test("Shift+Enter preserves a newline while mention suggestions are open", () => {
  const {hook, pushedEvents, submitCount} = mountComposer({
    mentionsEnabled: "true",
    inputType: "TEXTAREA",
    autocompleteOpen: true,
  })

  let newlinePrevented = false
  hook.input.dispatch("keydown", {
    isComposing: false,
    key: "Enter",
    preventDefault() {
      newlinePrevented = true
    },
    shiftKey: true,
  })

  assert.equal(newlinePrevented, false)
  assert.equal(submitCount(), 0)
  assert.deepEqual(pushedEvents, [])
  hook.destroyed()
})

test("a multiline composer grows to its content cap", () => {
  const {hook, input} = mountComposer({mentionsEnabled: "false", inputType: "TEXTAREA"})

  input.scrollHeight = 240
  input.dispatch("input")

  assert.equal(input.style.height, "176px")
  assert.equal(input.style.overflowY, "auto")
  hook.destroyed()
})
