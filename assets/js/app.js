// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/discord_clone"
import topbar from "../vendor/topbar"
import ChannelMessages from "./hooks/channel_messages"
import ClipboardCopy from "./hooks/clipboard_copy"
import MessageActionsMenu from "./hooks/message_actions_menu"
import MessageComposer from "./hooks/message_composer"
import VoiceControls from "./hooks/voice_controls"
import VoiceWorkspaceBadge from "./hooks/voice_workspace_badge"
import VoiceLifecycle from "./hooks/voice_lifecycle"
import voiceController from "./hooks/voice_controller"
import {createVoicePeerAttempt} from "./voice_peer_attempt"
import {createVoiceSignaling} from "./voice_signaling"
import {playVoiceCue} from "./voice_cues"
import {createCallSignaling} from "./call_signaling"
import {installCallSignaling} from "./call_signaling_bootstrap"

const Hooks = {
  ChannelMessages,
  ClipboardCopy,
  MessageActionsMenu,
  MessageComposer,
  VoiceControls,
  VoiceWorkspaceBadge,
  VoiceLifecycle,
  CallConversationStage: {
    mounted() { window.dispatchEvent(new Event("call:conversation-surface")) },
    updated() { window.dispatchEvent(new Event("call:conversation-surface")) },
    destroyed() { window.dispatchEvent(new Event("call:conversation-surface")) },
  },

  ContextMenu: {
    mounted() {
      this.handleContextMenu = event => {
        event.preventDefault()

        this.pushEvent("open_context_menu", {
          type: this.el.dataset.contextMenuType,
          id: this.el.dataset.contextMenuId,
          x: event.clientX,
          y: event.clientY,
        })
      }

      this.el.addEventListener("contextmenu", this.handleContextMenu)
    },

    destroyed() {
      this.el.removeEventListener("contextmenu", this.handleContextMenu)
    },
  },
}

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, ...Hooks},
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// Voice signaling is deliberately separate from the Voice Owner Tab controller,
// which remains responsible only for local microphone capture and ownership.
window.voiceSignaling = createVoiceSignaling({Socket, csrfToken})
const callExperience = installCallSignaling({
  document,
  window,
  Socket,
  csrfToken,
  createCallSignaling,
})
window.callSignaling = callExperience.signaling
window.callController = callExperience.controller
voiceController.configure({
  connectionFactory: options => createVoicePeerAttempt({...options, signaling: window.voiceSignaling}),
  cuePlayer: playVoiceCue,
})

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}
