import voiceController from "./voice_controller"

export function createVoiceLifecycle(controller, {documentTarget = globalThis.document, windowTarget = globalThis.window} = {}) {
  return {
    mounted() {
      this.handleClick = event => {
        if (event.target.closest("[data-voice-logout]")) controller.teardown()
      }
      this.handlePageHide = () => controller.teardown()
      documentTarget.addEventListener("click", this.handleClick)
      windowTarget.addEventListener("pagehide", this.handlePageHide)
    },

    destroyed() {
      documentTarget.removeEventListener("click", this.handleClick)
      windowTarget.removeEventListener("pagehide", this.handlePageHide)
    },
  }
}

export default createVoiceLifecycle(voiceController)
