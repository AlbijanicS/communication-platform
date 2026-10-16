import assert from "node:assert/strict"
import {readFile} from "node:fs/promises"
import test from "node:test"

const hookSource = await readFile(new URL("./channel_messages.js", import.meta.url), "utf8")
const hookModuleUrl = `data:text/javascript;base64,${Buffer.from(hookSource).toString("base64")}`
const {default: ChannelMessages} = await import(hookModuleUrl)

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

function messageRow(seq) {
  return {
    id: `message-${seq}`,
    dataset: {messageSeq: String(seq)},
    isConnected: true,
    getBoundingClientRect() {
      return {bottom: 80, height: 40, top: 40}
    },
  }
}

function mountMessages(seqs, {visibleReadDelayMs = 20} = {}) {
  const rows = seqs.map(messageRow)
  const rowsById = new Map(rows.map(row => [row.id, row]))
  const pushedEvents = []
  const observers = []
  let focused = true

  globalThis.document = {
    ...eventTarget(),
    visibilityState: "visible",
    hasFocus() {
      return focused
    },
    getElementById(id) {
      return rowsById.get(id) || null
    },
  }

  class FakeIntersectionObserver {
    constructor(callback) {
      this.callback = callback
      observers.push(this)
    }

    observe() {}
    unobserve() {}
    disconnect() {}
  }

  globalThis.IntersectionObserver = FakeIntersectionObserver
  globalThis.requestAnimationFrame = callback => callback()
  globalThis.window = {
    ...eventTarget(),
    IntersectionObserver: FakeIntersectionObserver,
    clearTimeout,
    setTimeout,
  }

  const el = {
    ...eventTarget(),
    clientHeight: 100,
    dataset: {
      hasNewerMessages: "false",
      hasOlderMessages: "false",
      loadingNewer: "false",
      loadingOlder: "false",
    },
    id: "messages",
    scrollHeight: 100,
    scrollTop: 0,
    contains(row) {
      return rows.includes(row)
    },
    getBoundingClientRect() {
      return {bottom: 100, height: 100, top: 0}
    },
    querySelector() {
      return null
    },
    querySelectorAll() {
      return rows
    },
  }

  const hook = {
    ...ChannelMessages,
    el,
    handleEvent() {},
    pushEvent(name, payload) {
      pushedEvents.push({name, payload})
    },
  }

  hook.mounted()
  hook.cancelApplyScrollTarget()
  hook.cancelScrollAnchor()
  const configuredVisibleReadDelayMs = hook.visibleReadDelayMs
  hook.visibleReadDelayMs = visibleReadDelayMs
  hook.cancelVisibleReadTimers()
  hook.evaluateVisibleReadRows()

  return {
    configuredVisibleReadDelayMs,
    hook,
    observer: observers[0],
    pushedEvents,
    rows,
    setFocused(value) {
      focused = value
    },
  }
}

function intersectionEntry(row, visibleHeight) {
  return {
    target: row,
    boundingClientRect: {height: 40},
    intersectionRect: {height: visibleHeight},
  }
}

function visibleReadEvents(pushedEvents) {
  return pushedEvents.filter(event => event.name === "visible_read_observed")
}

function wait(milliseconds) {
  return new Promise(resolve => setTimeout(resolve, milliseconds))
}

async function waitFor(predicate, {timeoutMs = 1_000, intervalMs = 5} = {}) {
  const deadline = Date.now() + timeoutMs

  while (!predicate() && Date.now() < deadline) {
    await wait(intervalMs)
  }
}

test("a Message requires one continuous attentive threshold", async () => {
  const {configuredVisibleReadDelayMs, hook, pushedEvents} = mountMessages([1])

  assert.equal(configuredVisibleReadDelayMs, 1000)
  await wait(10)
  assert.deepEqual(visibleReadEvents(pushedEvents), [])

  await waitFor(() => visibleReadEvents(pushedEvents).length === 1)

  assert.deepEqual(visibleReadEvents(pushedEvents), [
    {name: "visible_read_observed", payload: {ranges: [{from_seq: 1, to_seq: 1}]}},
  ])

  hook.destroyed()
})

test("an unrelated LiveView patch preserves a continuous attentive timer", async () => {
  const {hook, pushedEvents} = mountMessages([6])

  await wait(10)
  hook.updated()
  hook.cancelApplyScrollTarget()
  hook.cancelScrollAnchor()

  await waitFor(() => visibleReadEvents(pushedEvents).length === 1)

  assert.deepEqual(visibleReadEvents(pushedEvents), [
    {name: "visible_read_observed", payload: {ranges: [{from_seq: 6, to_seq: 6}]}},
  ])

  hook.destroyed()
})

test("leaving the viewport cancels an incomplete visibility timer", async () => {
  const {hook, observer, pushedEvents, rows} = mountMessages([2], {visibleReadDelayMs: 5_000})

  await wait(10)
  assert.equal(hook.visibleReadTimers.size, 1)
  observer.callback([intersectionEntry(rows[0], 0)])
  await wait(20)

  assert.deepEqual(visibleReadEvents(pushedEvents), [])
  hook.destroyed()
})

test("hiding the document cancels an incomplete visibility timer", async () => {
  const {hook, pushedEvents} = mountMessages([3], {visibleReadDelayMs: 5_000})

  await wait(10)
  assert.equal(hook.visibleReadTimers.size, 1)
  document.visibilityState = "hidden"
  document.dispatch("visibilitychange")
  await wait(20)

  assert.deepEqual(visibleReadEvents(pushedEvents), [])
  hook.destroyed()
})

test("losing window focus cancels an incomplete visibility timer", async () => {
  const {hook, pushedEvents, setFocused} = mountMessages([4], {visibleReadDelayMs: 5_000})

  await wait(10)
  assert.equal(hook.visibleReadTimers.size, 1)
  setFocused(false)
  window.dispatch("blur")
  await wait(20)

  assert.deepEqual(visibleReadEvents(pushedEvents), [])
  hook.destroyed()
})

test("eligible sequences are grouped into bounded range reports", async () => {
  const {hook, pushedEvents} = mountMessages([1, 2, 3, 5])

  await waitFor(() => visibleReadEvents(pushedEvents).length === 1)

  assert.deepEqual(visibleReadEvents(pushedEvents), [
    {
      name: "visible_read_observed",
      payload: {
        ranges: [
          {from_seq: 1, to_seq: 3},
          {from_seq: 5, to_seq: 5},
        ],
      },
    },
  ])

  hook.destroyed()
})
