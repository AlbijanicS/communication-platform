import voiceController from "./voice_controller"

export function createVoiceWorkspaceBadge(controller) {
  return {
    mounted() {
      this.handleClick = () => {
        this.el.setAttribute("aria-expanded", "true")
        window.dispatchEvent(new CustomEvent("voice-controls:open", {detail: {trigger: this.el}}))
      }
      this.el.addEventListener("click", this.handleClick)
      this.unsubscribe = controller.subscribe(state => this.renderState(state))
    },

    destroyed() {
      this.el.removeEventListener("click", this.handleClick)
      this.unsubscribe()
    },

    renderState(state) {
      const active =
        ["requesting", "joining", "connected", "muted"].includes(state.status) &&
          state.workspaceId === this.el.dataset.workspaceId
      const attention = state.error && state.workspaceId === this.el.dataset.workspaceId
      const microphone = this.el.querySelector("[data-voice-workspace-badge-microphone]")
      const warning = this.el.querySelector("[data-voice-workspace-badge-warning]")

      this.el.hidden = !active && !attention
      microphone.hidden = Boolean(attention)
      warning.hidden = !attention
      this.el.setAttribute(
        "aria-label",
        attention ? "Open Voice Channel issue" : "Open Voice Channel controls"
      )
      if (!active && !attention) this.el.setAttribute("aria-expanded", "false")
    },
  }
}

export default createVoiceWorkspaceBadge(voiceController)
