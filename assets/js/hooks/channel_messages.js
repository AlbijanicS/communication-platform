const ChannelMessages = {
  mounted() {
    this.edgeThresholdPx = 300
    this.visibleReadDelayMs = 1000
    this.scrollAnchorDelayMs = 1500
    this.visibleReadRatio = 0.6
    this.visibleReadBatchSize = 50
    this.loadingOlder = false
    this.loadingNewer = false
    this.suppressNextScrollLoad = false
    this.suppressHistoryLoadingUntil = 0
    this.scrollAnchorTimer = null
    this.applyScrollTargetTimer = null
    this.applyScrollTargetRetryUntil = 0
    this.pendingScrollTargetKey = null
    this.lastSentAnchorSeq = null
    this.observedMessageRowIds = new Set()
    this.observedMessageSeqs = new Set()
    this.pendingVisibleReadSeqs = new Set()
    this.visibleReadTimers = new Map()
    this.visibleReadFlushTimer = null
    this.visibleReadObserver = null
    this.handleScroll = () => {
      const suppressingProgrammaticScroll = Date.now() < this.suppressHistoryLoadingUntil

      if (this.suppressNextScrollLoad && suppressingProgrammaticScroll) {
        this.suppressNextScrollLoad = false
      } else if (suppressingProgrammaticScroll) {
        this.suppressNextScrollLoad = false
      } else {
        this.suppressNextScrollLoad = false
        requestAnimationFrame(() => this.maybeLoadHistory())
      }

      this.scheduleScrollAnchor()
    }
    this.handleVisibilityChange = () => this.handleActiveStateChanged()
    this.handleWindowFocus = () => this.handleActiveStateChanged()
    this.handleWindowBlur = () => this.handleActiveStateChanged()

    this.el.addEventListener("scroll", this.handleScroll, {passive: true})
    document.addEventListener("visibilitychange", this.handleVisibilityChange)
    window.addEventListener("focus", this.handleWindowFocus)
    window.addEventListener("blur", this.handleWindowBlur)

    this.handleEvent("scroll_channel_messages_to_bottom", ({container_id}) => {
      const container = document.getElementById(container_id)

      if (!container) {
        return
      }

      requestAnimationFrame(() => scrollToBottom(container))
    })

    this.handleEvent("preserve_channel_messages_scroll", ({
      container_id,
      anchor_offset_top,
      anchor_row_id,
      previous_scroll_height,
      previous_scroll_top,
    }) => {
      const container = document.getElementById(container_id)

      if (!container) {
        return
      }

      requestAnimationFrame(() => {
        this.suppressProgrammaticHistoryLoading(700)

        if (restoreScrollAnchor(container, anchor_row_id, anchor_offset_top)) {
          return
        }

        const addedHeight = container.scrollHeight - previous_scroll_height
        container.scrollTop = previous_scroll_top + Math.max(addedHeight, 0)
      })
    })

    this.handleEvent("restore_channel_messages_scroll", ({
      anchor_offset_top,
      anchor_row_id,
      container_id,
      previous_scroll_top,
    }) => {
      const container = document.getElementById(container_id)

      if (!container) {
        return
      }

      requestAnimationFrame(() => {
        this.suppressProgrammaticHistoryLoading(700)

        if (restoreScrollAnchor(container, anchor_row_id, anchor_offset_top)) {
          return
        }

        container.scrollTop = previous_scroll_top
      })
    })

    this.handleEvent("remove_channel_message_rows", ({row_ids = []}) => {
      this.cancelScrollAnchor()
      row_ids.forEach((rowId) => this.removeVisibleReadRow(rowId))
      this.scheduleScrollAnchor()
    })

    this.suppressProgrammaticHistoryLoading(1000)
    this.scheduleApplyScrollTarget()
    this.syncVisibleReadRows()
    this.scheduleScrollAnchor()
  },

  updated() {
    this.cancelScrollAnchor()
    this.scheduleApplyScrollTarget()
    this.syncVisibleReadRows()

    if (this.el.dataset.loadingOlder !== "true") {
      this.loadingOlder = false
    }

    if (this.el.dataset.loadingNewer !== "true") {
      this.loadingNewer = false
    }

    this.scheduleScrollAnchor()
  },

  destroyed() {
    this.el.removeEventListener("scroll", this.handleScroll)
    document.removeEventListener("visibilitychange", this.handleVisibilityChange)
    window.removeEventListener("focus", this.handleWindowFocus)
    window.removeEventListener("blur", this.handleWindowBlur)
    this.cancelScrollAnchor()
    this.cancelApplyScrollTarget()
    this.cancelVisibleReadTimers()
    this.cancelVisibleReadFlush()

    if (this.visibleReadObserver) {
      this.visibleReadObserver.disconnect()
    }
  },

  maybeLoadHistory() {
    if (Date.now() < this.suppressHistoryLoadingUntil) {
      return
    }

    this.maybeLoadOlder()
    this.maybeLoadNewer()
  },

  suppressProgrammaticHistoryLoading(durationMs = 750) {
    this.suppressNextScrollLoad = true
    this.suppressHistoryLoadingUntil = Date.now() + durationMs
  },

  scheduleApplyScrollTarget() {
    if (this.applyScrollTargetTimer) {
      return
    }

    this.applyScrollTargetTimer = window.setTimeout(() => {
      this.applyScrollTargetTimer = null
      requestAnimationFrame(() => this.applyScrollTarget())
    }, 0)
  },

  retryApplyScrollTarget() {
    if (Date.now() > this.applyScrollTargetRetryUntil) {
      return
    }

    this.suppressProgrammaticHistoryLoading(250)
    this.applyScrollTargetTimer = window.setTimeout(() => {
      this.applyScrollTargetTimer = null
      this.applyScrollTarget()
    }, 50)
  },

  scheduleScrollAnchor() {
    this.cancelScrollAnchor()

    this.scrollAnchorTimer = window.setTimeout(() => {
      this.scrollAnchorTimer = null
      this.persistScrollAnchor()
    }, this.scrollAnchorDelayMs)
  },

  persistScrollAnchor() {
    const seq = centerMostVisibleMessageSeq(this.el)

    if (seq === null || seq === this.lastSentAnchorSeq) {
      return
    }

    this.lastSentAnchorSeq = seq
    this.pushEvent("scroll_anchor_observed", {seq})
  },

  maybeLoadOlder() {
    if (this.loadingOlder || this.el.dataset.hasOlderMessages !== "true") {
      return
    }

    if (this.el.scrollTop > this.edgeThresholdPx) {
      return
    }

    this.loadingOlder = true

    this.pushEvent("load_older_messages", {
      ...scrollAnchorPayload(this.el),
      container_id: this.el.id,
      client_height: this.el.clientHeight,
      scroll_height: this.el.scrollHeight,
      scroll_top: this.el.scrollTop,
    }, () => {
      this.loadingOlder = false
    })
  },

  maybeLoadNewer() {
    if (this.loadingNewer || this.el.dataset.hasNewerMessages !== "true") {
      return
    }

    const distanceFromBottom =
      this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight

    if (distanceFromBottom > this.edgeThresholdPx) {
      return
    }

    this.loadingNewer = true

    this.pushEvent("load_newer_messages", {
      ...scrollAnchorPayload(this.el),
      container_id: this.el.id,
      client_height: this.el.clientHeight,
      scroll_height: this.el.scrollHeight,
      scroll_top: this.el.scrollTop,
    }, () => {
      this.loadingNewer = false
    })
  },

  applyScrollTarget() {
    const kind = this.el.dataset.scrollTargetKind
    const seq = this.el.dataset.scrollTargetSeq || ""
    const token = this.el.dataset.scrollTargetToken || ""
    const key = `${kind || "none"}:${seq}:${token}`

    if (!kind || this.appliedScrollTargetKey === key) {
      return
    }

    if (this.pendingScrollTargetKey !== key) {
      this.pendingScrollTargetKey = key
      this.applyScrollTargetRetryUntil = Date.now() + 2500
    }

    if (Date.now() > this.applyScrollTargetRetryUntil) {
      this.appliedScrollTargetKey = key
      return
    }

    if (kind === "latest") {
      if (this.el.scrollHeight <= this.el.clientHeight) {
        this.retryApplyScrollTarget()
        return
      }

      this.suppressProgrammaticHistoryLoading()
      scrollToBottom(this.el)
      this.appliedScrollTargetKey = key
      return
    }

    if (kind === "sequence" && seq !== "") {
      const target = this.el.querySelector(`[data-message-seq="${seq}"]`)

      if (!target || this.el.scrollHeight <= this.el.clientHeight) {
        this.retryApplyScrollTarget()
        return
      }

      this.suppressProgrammaticHistoryLoading()
      scrollMessageRowToCenter(this.el, target)
      this.appliedScrollTargetKey = key
    }
  },

  syncVisibleReadRows() {
    if (!("IntersectionObserver" in window)) {
      return
    }

    if (!this.visibleReadObserver) {
      this.visibleReadObserver = new IntersectionObserver(
        entries => this.handleVisibleReadEntries(entries),
        {
          root: this.el,
          threshold: [0, this.visibleReadRatio, 1],
        }
      )
    }

    const rows = Array.from(
      this.el.querySelectorAll("[data-visible-read-observe='true'][data-message-seq]")
    )
    const currentRowIds = new Set(rows.map(row => row.id))

    this.observedMessageRowIds.forEach(rowId => {
      if (!currentRowIds.has(rowId)) {
        this.removeVisibleReadRow(rowId)
      }
    })

    rows.forEach(row => {
      if (!this.observedMessageRowIds.has(row.id)) {
        this.observedMessageRowIds.add(row.id)
        this.visibleReadObserver.observe(row)
      }
    })

    if (this.isActiveForVisibleRead()) {
      requestAnimationFrame(() => this.evaluateVisibleReadRows())
    }
  },

  handleVisibleReadEntries(entries) {
    entries.forEach(entry => {
      const row = entry.target

      if (this.rowQualifiesForVisibleRead(entry)) {
        this.startVisibleReadTimer(row)
      } else {
        this.cancelVisibleReadTimer(row.id)
      }
    })
  },

  rowQualifiesForVisibleRead(entry) {
    if (!this.isActiveForVisibleRead()) {
      return false
    }

    const row = entry.target
    const rowSeq = parseMessageSeq(row)

    if (rowSeq === null || this.observedMessageSeqs.has(rowSeq)) {
      return false
    }

    const rowHeight = entry.boundingClientRect.height
    const containerHeight = this.el.getBoundingClientRect().height
    const visibleHeight = entry.intersectionRect.height
    const requiredHeight = Math.min(
      rowHeight * this.visibleReadRatio,
      containerHeight * this.visibleReadRatio
    )

    return visibleHeight >= requiredHeight
  },

  startVisibleReadTimer(row) {
    if (this.visibleReadTimers.has(row.id)) {
      return
    }

    const timer = window.setTimeout(() => {
      this.visibleReadTimers.delete(row.id)

      if (!this.isActiveForVisibleRead() || !this.rowStillQualifiesForVisibleRead(row)) {
        return
      }

      const rowSeq = parseMessageSeq(row)

      if (rowSeq === null || this.observedMessageSeqs.has(rowSeq)) {
        return
      }

      this.observedMessageSeqs.add(rowSeq)
      this.queueVisibleReadSeq(rowSeq)
    }, this.visibleReadDelayMs)

    this.visibleReadTimers.set(row.id, timer)
  },

  evaluateVisibleReadRows() {
    this.observedMessageRowIds.forEach(rowId => {
      const row = document.getElementById(rowId)

      if (!row) {
        return
      }

      if (this.isActiveForVisibleRead() && this.rowStillQualifiesForVisibleRead(row)) {
        this.startVisibleReadTimer(row)
      } else {
        this.cancelVisibleReadTimer(rowId)
      }
    })
  },

  rowStillQualifiesForVisibleRead(row) {
    if (!row.isConnected) {
      return false
    }

    const rowRect = row.getBoundingClientRect()
    const containerRect = this.el.getBoundingClientRect()
    const visibleTop = Math.max(rowRect.top, containerRect.top)
    const visibleBottom = Math.min(rowRect.bottom, containerRect.bottom)
    const visibleHeight = Math.max(visibleBottom - visibleTop, 0)
    const requiredHeight = Math.min(
      rowRect.height * this.visibleReadRatio,
      containerRect.height * this.visibleReadRatio
    )

    return visibleHeight >= requiredHeight
  },

  queueVisibleReadSeq(seq) {
    this.pendingVisibleReadSeqs.add(seq)

    if (this.visibleReadFlushTimer) {
      return
    }

    this.visibleReadFlushTimer = window.setTimeout(() => {
      const seqs = Array.from(this.pendingVisibleReadSeqs)
      this.pendingVisibleReadSeqs.clear()
      this.visibleReadFlushTimer = null
      this.flushVisibleReadSeqs(seqs)
    }, 0)
  },

  flushVisibleReadSeqs(seqs) {
    compactVisibleReadRanges(seqs, this.visibleReadBatchSize).forEach(ranges => {
      this.pushEvent("visible_read_observed", {ranges})
    })
  },

  removeVisibleReadRow(rowId) {
    const row = document.getElementById(rowId)

    this.cancelVisibleReadTimer(rowId)
    this.observedMessageRowIds.delete(rowId)

    if (row && this.visibleReadObserver) {
      this.visibleReadObserver.unobserve(row)
    }
  },

  cancelVisibleReadTimers() {
    this.visibleReadTimers.forEach(timer => window.clearTimeout(timer))
    this.visibleReadTimers.clear()
  },

  cancelVisibleReadFlush() {
    if (this.visibleReadFlushTimer) {
      window.clearTimeout(this.visibleReadFlushTimer)
      this.visibleReadFlushTimer = null
    }

    this.pendingVisibleReadSeqs.clear()
  },

  cancelScrollAnchor() {
    if (!this.scrollAnchorTimer) {
      return
    }

    window.clearTimeout(this.scrollAnchorTimer)
    this.scrollAnchorTimer = null
  },

  cancelApplyScrollTarget() {
    if (!this.applyScrollTargetTimer) {
      return
    }

    window.clearTimeout(this.applyScrollTargetTimer)
    this.applyScrollTargetTimer = null
  },

  cancelVisibleReadTimer(rowId) {
    const timer = this.visibleReadTimers.get(rowId)

    if (!timer) {
      return
    }

    window.clearTimeout(timer)
    this.visibleReadTimers.delete(rowId)
  },

  handleActiveStateChanged() {
    this.cancelVisibleReadTimers()

    if (this.isActiveForVisibleRead()) {
      this.syncVisibleReadRows()
    }
  },

  isActiveForVisibleRead() {
    return document.visibilityState === "visible" && document.hasFocus()
  },
}

function scrollToBottom(container) {
  container.scrollTop = container.scrollHeight
}

function scrollMessageRowToCenter(container, row) {
  const containerRect = container.getBoundingClientRect()
  const rowRect = row.getBoundingClientRect()
  const containerCenter = containerRect.top + containerRect.height / 2
  const rowCenter = rowRect.top + rowRect.height / 2

  container.scrollTop += rowCenter - containerCenter
}

function scrollAnchorPayload(container) {
  const row = centerMostVisibleMessageRow(container)

  if (!row) {
    return {}
  }

  const rowRect = row.getBoundingClientRect()
  const containerRect = container.getBoundingClientRect()

  return {
    anchor_row_id: row.id,
    anchor_offset_top: rowRect.top - containerRect.top,
  }
}

function restoreScrollAnchor(container, rowId, previousOffsetTop) {
  if (!rowId || !Number.isFinite(previousOffsetTop)) {
    return false
  }

  const row = document.getElementById(rowId)

  if (!row || !container.contains(row)) {
    return false
  }

  const rowRect = row.getBoundingClientRect()
  const containerRect = container.getBoundingClientRect()
  const currentOffsetTop = rowRect.top - containerRect.top

  container.scrollTop += currentOffsetTop - previousOffsetTop
  return true
}

function parseMessageSeq(row) {
  const seq = Number.parseInt(row.dataset.messageSeq, 10)

  return Number.isInteger(seq) && seq > 0 ? seq : null
}

function centerMostVisibleMessageSeq(container) {
  const row = centerMostVisibleMessageRow(container)

  return row ? parseMessageSeq(row) : null
}

function centerMostVisibleMessageRow(container) {
  const containerRect = container.getBoundingClientRect()
  const containerCenter = containerRect.top + containerRect.height / 2
  const rows = Array.from(container.querySelectorAll("[data-message-seq]"))
  let bestRow = null
  let bestDistance = Infinity

  rows.forEach(row => {
    const seq = parseMessageSeq(row)

    if (seq === null) {
      return
    }

    const rowRect = row.getBoundingClientRect()
    const visibleTop = Math.max(rowRect.top, containerRect.top)
    const visibleBottom = Math.min(rowRect.bottom, containerRect.bottom)

    if (visibleBottom <= visibleTop) {
      return
    }

    const visibleCenter = visibleTop + (visibleBottom - visibleTop) / 2
    const distance = Math.abs(visibleCenter - containerCenter)

    if (distance < bestDistance) {
      bestDistance = distance
      bestRow = row
    }
  })

  return bestRow
}

function compactVisibleReadRanges(seqs, maxRangeSize) {
  const sortedSeqs = Array.from(new Set(seqs)).sort((left, right) => left - right)
  const batches = []
  let currentBatch = []
  let currentRange = null

  sortedSeqs.forEach(seq => {
    const startsNewRange =
      !currentRange ||
      seq !== currentRange.to_seq + 1 ||
      currentRange.to_seq - currentRange.from_seq + 1 >= maxRangeSize

    if (startsNewRange) {
      currentRange = {from_seq: seq, to_seq: seq}
      currentBatch.push(currentRange)
    } else {
      currentRange.to_seq = seq
    }

    if (currentBatch.length >= maxRangeSize) {
      batches.push(currentBatch)
      currentBatch = []
      currentRange = null
    }
  })

  if (currentBatch.length > 0) {
    batches.push(currentBatch)
  }

  return batches
}

export default ChannelMessages
