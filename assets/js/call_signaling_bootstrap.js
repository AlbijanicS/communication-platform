import {createCallPeerAttempt} from "./call_peer_attempt.js"
import {createFakeCallDevices, createRealCallDevices} from "./call_devices.js"
import {createCallController} from "./call_controller.js"
import {createCallCueCoordinator} from "./call_cue_coordinator.js"
import {createCallCuePlayer} from "./call_cues.js"
import {installCallPresenter} from "./call_presenter.js"

export function installCallSignaling({
  document: doc,
  window: win,
  Socket,
  csrfToken,
  createCallSignaling,
  createDevices,
  createCuePlayer = createCallCuePlayer,
  createCueCoordinator = createCallCueCoordinator,
  createController = createCallController,
  createPeerAttempt = createCallPeerAttempt,
  installPresenter = installCallPresenter,
} = {}) {
  const bootstrap = doc?.getElementById?.("call-signaling-bootstrap")
  const authenticated = Boolean(bootstrap)

  if (!authenticated) {
    return {signaling: null, controller: null, dispose() {}}
  }

  const signaling = createCallSignaling({Socket, csrfToken})
  const realDevices = bootstrap.dataset?.callDevices !== "fake"
  // Availability is projected by the application, independently of injected
  // devices. It never grants server participant/owner authority.
  const videoAvailable = bootstrap.dataset?.callVideoAvailable === "true"
  const devices = (createDevices ?? (realDevices ? createRealCallDevices : createFakeCallDevices))()
  const cuePlayer = createCuePlayer()
  const cueCoordinator = createCueCoordinator({
    onElected: ({kind, callId}) => cuePlayer.start(kind, callId),
    onRevoked: () => cuePlayer.stop(),
  })
  const remoteAudio = realDevices ? doc.createElement("audio") : null
  const controller = createController({signaling, devices, videoAvailable, cues: cueCoordinator,
    ...(realDevices ? {createPeerAttempt: options => createPeerAttempt({...options, remoteAudio})} : {}),
  })
  const presenter = installPresenter({
    document: doc,
    window: win,
    controller,
  })

  function onPageHide() {
    controller.releaseCues?.()
    controller.suspend?.()
    signaling.disconnect()
  }

  function onPageShow(event) {
    if (event?.persisted) {
      // Resume is also a cleanup boundary: a frozen document may still retain
      // media or pending work. Release it before fresh authenticated discovery.
      onPageHide()
      signaling.connect()
    }
  }

  signaling.connect()
  win?.addEventListener?.("pagehide", onPageHide)
  win?.addEventListener?.("pageshow", onPageShow)
  let disposed = false

  function dispose() {
    if (disposed) return
    disposed = true

    win?.removeEventListener?.("pagehide", onPageHide)
    win?.removeEventListener?.("pageshow", onPageShow)
    presenter?.dispose?.()
    controller.dispose()
    cueCoordinator.dispose?.()
    cuePlayer.dispose?.()
    signaling.dispose()
  }

  return {signaling, controller, dispose}
}
