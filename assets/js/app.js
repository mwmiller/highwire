// We import the CSS which is extracted to its own file by esbuild.
// Remove this line if you add a your own CSS build pipeline (e.g postcss).
//
// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "./vendor/some-package.js"
//
// Alternatively, you can `npm install some-package` and import
// them using a path starting with the package name:
//
//     import "some-package"
//

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import topbar from "../vendor/topbar"
import {AppRunner} from "./app_runner.js"
import {CodeEditorHook} from "./code_editor.js"
import {WasmDropin} from "./wasm_dropin.js"

let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")

// Bridges native (Tauri) menu and window events with the LiveView.
let MenuBridge = {
  mounted() {
    this.el.addEventListener("phx:window-init", (e) => {
      const {width, height} = e.detail
      if (window.__TAURI__) {
        window.__TAURI__.core.invoke("set_window_size", {width, height})
      }
    })

    if (window.__TAURI__) {
      window.__TAURI__.event.listen("highwire-menu", (event) => {
        this.pushEvent("menu", event.payload)
      })

      window.__TAURI__.event.listen("highwire-resize", (event) => {
        this.pushEvent("window-resize", event.payload)
      })
    }

    this.handleEvent("export-save", ({content, filename}) => {
      if (window.__TAURI__) {
        window.highwireSave(content, filename)
      } else {
        const blob = new Blob([content], {type: "application/octet-stream"})
        const url = URL.createObjectURL(blob)
        const a = document.createElement("a")
        a.href = url
        a.download = filename
        document.body.appendChild(a)
        a.click()
        document.body.removeChild(a)
        URL.revokeObjectURL(url)
      }
    })

    // Pushed by the server whenever the view or entry changes. The scroll
    // containers are morphed in place rather than replaced, so the browser
    // would otherwise keep the previous offset and drop the reader mid-entry.
    this.handleEvent("reset-scroll", () => {
      document.querySelectorAll(".content-wrap").forEach((el) => {
        el.scrollTop = 0
      })
    })

    // Pushed by the server when a compose panel closes, so focus lands back on
    // the trigger that opened it instead of being dropped on <body>. The id is
    // resolved here because the trigger may not be rendered at all (a panel can
    // be forced open by the entry being viewed), in which case there is
    // nothing to return to and this is a no-op.
    this.handleEvent("focus-compose-trigger", ({id}) => {
      const trigger = document.getElementById(id)
      if (trigger) trigger.focus()
    })

    this.el.ownerDocument.addEventListener("keydown", (e) => {
      if (e.key === "Escape") {
        this.pushEvent("escape", {})
      }
    })
  }
}

window.highwireSave = async function(content, defaultName) {
  if (!window.__TAURI__) return null
  const { save } = window.__TAURI__.dialog
  const path = await save({ defaultPath: defaultName })
  if (!path) return null
  await window.__TAURI__.core.invoke("write_file", { path, content })
  return path
}

let liveSocket = new LiveSocket("/live", Socket, {
  params: {_csrf_token: csrfToken},
  hooks: {MenuBridge, AppRunner, CodeEditor: CodeEditorHook, WasmDropin}
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", info => topbar.show())
window.addEventListener("phx:page-loading-stop", info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket
