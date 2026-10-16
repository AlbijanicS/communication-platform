const MessageActionsMenu = {
  mounted() {
    this.summary = this.el.querySelector("[data-message-menu-summary]")
    this.panel = this.el.querySelector("[data-message-menu-panel]")
    this.actionsLayer = this.el.parentElement

    this.position = () => positionMessageMenu(this.summary, this.panel)

    this.handleToggle = () => {
      if (this.el.open) {
        this.actionsLayer.style.zIndex = "50"
        this.summary.style.opacity = "1"
        this.position()
      } else {
        this.actionsLayer.style.removeProperty("z-index")
        this.summary.style.removeProperty("opacity")
      }
    }

    this.handleDocumentPointerDown = event => {
      if (this.el.open && !this.el.contains(event.target)) {
        this.el.open = false
        this.handleToggle()
      }
    }

    this.handleDocumentKeydown = event => {
      if (this.el.open && event.key === "Escape") {
        this.el.open = false
        this.handleToggle()
        this.summary.focus()
      }
    }

    this.reposition = () => {
      if (this.el.open) {
        this.position()
      }
    }

    this.el.addEventListener("toggle", this.handleToggle)
    document.addEventListener("pointerdown", this.handleDocumentPointerDown, true)
    document.addEventListener("keydown", this.handleDocumentKeydown)
    window.addEventListener("resize", this.reposition)
    window.addEventListener("scroll", this.reposition, true)
  },

  destroyed() {
    this.actionsLayer.style.removeProperty("z-index")
    this.el.removeEventListener("toggle", this.handleToggle)
    document.removeEventListener("pointerdown", this.handleDocumentPointerDown, true)
    document.removeEventListener("keydown", this.handleDocumentKeydown)
    window.removeEventListener("resize", this.reposition)
    window.removeEventListener("scroll", this.reposition, true)
  },
}

function positionMessageMenu(summary, panel) {
  if (!summary || !panel) {
    return
  }

  const margin = 12
  const rect = summary.getBoundingClientRect()
  const panelRect = panel.getBoundingClientRect()
  const composer = document.getElementById("message-composer-panel")
  const composerTop = composer?.getBoundingClientRect().top ?? window.innerHeight
  const availableBottom = Math.min(window.innerHeight - margin, composerTop - margin)

  let left = rect.right - panelRect.width
  let top = rect.bottom + 8

  if (top + panelRect.height > availableBottom) {
    top = rect.top - panelRect.height - 8
  }

  left = Math.max(margin, Math.min(left, window.innerWidth - panelRect.width - margin))
  top = Math.max(margin, Math.min(top, window.innerHeight - panelRect.height - margin))

  panel.style.left = `${left}px`
  panel.style.top = `${top}px`
}

export default MessageActionsMenu
