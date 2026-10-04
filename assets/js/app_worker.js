// The worker that runs a module. It exists to be killable: the main thread
// holds the deadline and calls terminate() when it expires, and nothing
// here can keep that from working.
//
// Two messages come in — `start` with the module's bytes, and `deliver`
// with a message for it — and two go out: `ready` once the module has
// instantiated (which is the part that may spin in its own `start` code),
// and either `effects` or `error`.

import {openSession} from "./app_session.js"

let session = null

self.onmessage = event => {
  const message = event.data
  if (!message) return

  if (message.type === "start") {
    session = null
    openSession(message.wasm)
      .then(started => {
        session = started
        self.postMessage({type: "ready"})
      })
      .catch(error => {
        self.postMessage({type: "error", message: describe(error)})
      })
    return
  }

  if (message.type === "deliver") {
    if (!session) {
      self.postMessage({type: "error", message: "a message arrived before the module started"})
      return
    }
    try {
      const bytes = session.step(message.bytes)
      self.postMessage({type: "effects", bytes}, [bytes.buffer])
    } catch (error) {
      self.postMessage({type: "error", message: describe(error)})
    }
  }
}

function describe(error) {
  if (error && error.message) return error.message
  return String(error)
}
