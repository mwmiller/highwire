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

// Infinite-scroll sentinel: observes the feed footer and asks the server
// for the next page. Pushes via onReply so a disconnect during the push
// cannot surface as an unhandled rejection.
let InfiniteScroll = {
  mounted() {
    this.observer = new IntersectionObserver(
      (entries) => {
        if (entries.some((e) => e.isIntersecting)) {
          try {
            this.pushEvent("load-more", {}, () => {})
          } catch (_) {}
        }
      },
      {rootMargin: "600px"}
    )
    this.observer.observe(this.el)
  },
  destroyed() {
    if (this.observer) this.observer.disconnect()
  }
}

// Bridges native (Tauri) menu and window events with the LiveView.
let MenuBridge = {
  mounted() {
    // pushEvent rejects when the socket is down (server restarting,
    // between reconnects). Menu/resize/escape can all fire at any time —
    // including then — so every push either supplies the onReply callback
    // (which swallows the rejection) or catches it explicitly.
    this.safePush = (event, payload) => {
      let pushed
      try {
        pushed = this.pushEvent(event, payload, () => {})
      } catch (_) {
        return
      }
      if (pushed && typeof pushed.catch === "function") pushed.catch(() => {})
    }

    this.el.addEventListener("phx:window-init", (e) => {
      const {width, height} = e.detail
      if (window.__TAURI__) {
        window.__TAURI__.core.invoke("set_window_size", {width, height})
      }
    })

    if (window.__TAURI__) {
      window.__TAURI__.event.listen("highwire-menu", (event) => {
        this.safePush("menu", event.payload)
      })

      window.__TAURI__.event.listen("highwire-resize", (event) => {
        this.safePush("window-resize", event.payload)
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
        this.safePush("escape", {})
      }
    })
  }
}

// Client-side preferences (Patchwork's settings page, packaged for the
// browser). Every pref is one localStorage key applied to the document —
// data-* attributes or inline styles on <html> — and the root-layout
// script re-applies the stored values before first paint. Buttons carry
// data-pref-key + data-pref-value; checkboxes carry data-pref-key +
// data-pref-on/off. aria-pressed / checked are the source of truth for
// the active choice, so state survives LiveView patches.
const PREF_DEFAULTS = {theme: "dark", participating: "off", spellcheck: "on"}

function storedPref(key) {
  try {
    const v = localStorage.getItem(key)
    if (v !== null) return v
  } catch (_) {}
  return Object.prototype.hasOwnProperty.call(PREF_DEFAULTS, key) ? PREF_DEFAULTS[key] : ""
}

// Resolves a stored mode ("system" | "light" | "dark") to the concrete
// data-theme value <html> should carry.
function resolveTheme(mode) {
  if (mode === "system") {
    return window.matchMedia("(prefers-color-scheme: light)").matches ? "light" : "dark"
  }
  return mode
}

function applyPref(key, value) {
  const root = document.documentElement
  switch (key) {
    case "theme":
      root.dataset.theme = resolveTheme(value)
      break
    case "font-size":
      root.style.fontSize = value
      break
    case "font-family":
      root.style.fontFamily = value
      break
    case "participating":
      root.dataset.participating = value === "on" ? "on" : "off"
      break
    case "spellcheck":
      root.dataset.spellcheck = value === "off" ? "off" : "on"
      applySpellcheck()
      break
  }
}

// Spellchecking is an element attribute, not a style: stamp every
// editable element from the stored pref (the composer inherits it the
// moment it renders; phx:page-loading-stop catches navigations).
function applySpellcheck() {
  const on = storedPref("spellcheck") !== "off"
  document.querySelectorAll("textarea, [contenteditable]").forEach((el) => {
    el.spellcheck = on
  })
}

function syncPrefButtons() {
  document.querySelectorAll("[data-pref-key]").forEach((el) => {
    const stored = storedPref(el.dataset.prefKey)
    if (el.type === "checkbox") {
      el.checked = stored === (el.dataset.prefOn || "on")
    } else {
      el.setAttribute("aria-pressed", String(stored === (el.dataset.prefValue || "")))
    }
  })
}

// "System" mode follows the OS while the app is open, not just at load:
// re-apply data-theme (and the Settings pressed states) when the OS flips.
try {
  window.matchMedia("(prefers-color-scheme: light)").addEventListener("change", () => {
    if (storedPref("theme") !== "system") return
    applyPref("theme", "system")
    syncPrefButtons()
  })
} catch (_) {}

// Settings page preference controls. Entirely client-side: values are
// persisted to localStorage and applied to <html> the moment a control
// changes (the root-layout script re-applies them before first paint).
let Prefs = {
  mounted() {
    this.onClick = (e) => {
      const btn = e.target.closest("[data-pref-key][data-pref-value]")
      if (!btn || !this.el.contains(btn)) return
      const key = btn.dataset.prefKey
      try {
        localStorage.setItem(key, btn.dataset.prefValue)
      } catch (_) {}
      applyPref(key, btn.dataset.prefValue)
      syncPrefButtons()
    }
    this.onChange = (e) => {
      const box = e.target.closest("input[type=checkbox][data-pref-key]")
      if (!box || !this.el.contains(box)) return
      const key = box.dataset.prefKey
      const value = box.checked ? (box.dataset.prefOn || "on") : (box.dataset.prefOff || "off")
      try {
        localStorage.setItem(key, value)
      } catch (_) {}
      applyPref(key, value)
      syncPrefButtons()
    }
    this.el.addEventListener("click", this.onClick)
    this.el.addEventListener("change", this.onChange)
    syncPrefButtons()
  },
  destroyed() {
    this.el.removeEventListener("click", this.onClick)
    this.el.removeEventListener("change", this.onChange)
  }
}

applySpellcheck()
document.addEventListener("phx:page-loading-stop", () => applySpellcheck())

// Post rows: clicking anywhere except a link or button opens the post
// viewer (pushEvent, not a link, because markdown bodies contain their
// own links that must keep their behaviour).
let OpenPost = {
  mounted() {
    this.onClick = (e) => {
      if (e.target.closest("a, button")) return
      const key = this.el.dataset.key
      if (!key) return
      try {
        const pushed = this.pushEvent("open-post", {key}, () => {})
        if (pushed && typeof pushed.catch === "function") pushed.catch(() => {})
      } catch (_) {}
    }
    this.el.addEventListener("click", this.onClick)
  },
  destroyed() {
    this.el.removeEventListener("click", this.onClick)
  }
}

let TabActivity = {
  mounted() {
    this.active = null
    this.push = (active) => {
      if (this.active === active) return
      this.active = active
      try {
        let pushed = this.pushEvent(active ? "tab-active" : "tab-inactive", {}, () => {})
        if (pushed && typeof pushed.catch === "function") pushed.catch(() => {})
      } catch (_) {}
    }
    this.check = () => this.push(document.visibilityState === "visible" && document.hasFocus())
    document.addEventListener("visibilitychange", this.check)
    window.addEventListener("focus", this.check)
    window.addEventListener("blur", this.check)
    this.check()
  },
  destroyed() {
    document.removeEventListener("visibilitychange", this.check)
    window.removeEventListener("focus", this.check)
    window.removeEventListener("blur", this.check)
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

// Settings: the network combination lock. The lock face holds one
// one-character box per key character (44, grouped in fours) and — on
// narrow screens — a single whole-key field with a mirror that paints
// each character green or red. Typing advances, backspace retreats,
// Escape clears, and pasting the key fills every box at once. A
// capture-phase listener on the lock gates the shackle until the key
// is spelled out, and holds back the leave-Mainnet plate until the
// pointer (or Space) has held it for a deliberate beat. The server
// owns which network is engaged: every entry carries its
// server-rendered value, and a patch settles the entries back to the
// server's view.
const LOCK_HOLD_MS = 1500

let LockDials = {
  mounted() {
    this.onClick = (e) => {
      if (e.target.closest("[data-unlock]")) {
        if (this.el.dataset.lockState !== "open" && !this.matched()) {
          e.preventDefault()
          e.stopPropagation()
          this.shake()
          this.focus(this.firstWrong())
          this.setStatus(this.wrongMessage())
        }
        return
      }
      const leave = e.target.closest("[data-leave]")
      if (leave) {
        if (this.el.dataset.lockState !== "open") return
        if (this.holdOk) {
          this.holdOk = false
          this.setHold(false)
          this.setStatus("Network set to: Development — starting the engine…")
          return
        }
        e.preventDefault()
        e.stopPropagation()
        this.setStatus("Held too briefly — press and hold the plate to snap shut.")
        return
      }
      if (e.target.closest("[data-fill]")) return this.fill()
      const copy = e.target.closest("[data-copy]")
      if (copy) return this.copy(copy)
    }
    this.onInput = (e) => {
      const field = e.target.closest && e.target.closest(".lock-key-field")
      if (field && this.el.contains(field)) {
        field.value = (field.value || "")
          .replace(/[^A-Za-z0-9+/=]/g, "")
          .slice(0, this.combo().length)
        this.markField(field)
        this.updateMirror()
        this.updateState()
        return
      }
      const box = this.box(e.target)
      if (!box) return
      const v = (box.value || "").replace(/[^A-Za-z0-9+/=]/g, "")
      box.value = v ? v[v.length - 1] : ""
      this.mark(box)
      if (box.value) this.focus(this.next(box))
      this.updateState()
    }
    this.onKey = (e) => {
      if (e.key === "Escape") {
        e.preventDefault()
        this.clearAll()
        return
      }
      const leave = e.target.closest("[data-leave]")
      if (leave) {
        if (this.el.dataset.lockState !== "open") return
        if (e.key === "Enter" || e.key === " ") {
          e.preventDefault()
          if (!e.repeat) this.startHold()
        }
        return
      }
      const field = e.target.closest(".lock-key-field")
      if (field) {
        if (e.key === "Enter") {
          e.preventDefault()
          const shackle = this.el.querySelector("[data-unlock]")
          if (shackle) shackle.click()
        }
        return
      }
      const box = this.box(e.target)
      if (!box) return
      if (e.key === "Backspace" && !box.value) {
        e.preventDefault()
        this.focus(this.prev(box))
      } else if (e.key === "ArrowLeft" || e.key === "ArrowUp") {
        e.preventDefault()
        this.focus(this.prev(box))
      } else if (e.key === "ArrowRight" || e.key === "ArrowDown") {
        e.preventDefault()
        this.focus(this.next(box))
      } else if (e.key === "Enter") {
        e.preventDefault()
        const shackle = this.el.querySelector("[data-unlock]")
        if (shackle) shackle.click()
      }
    }
    // Keyboard hold: Enter/Space are prevented on keydown so no native
    // click fires — a completed hold dispatches the click itself.
    this.onKeyUp = (e) => {
      if (e.key !== "Enter" && e.key !== " ") return
      const leave = e.target.closest && e.target.closest("[data-leave]")
      if (!leave || this.el.dataset.lockState !== "open") return
      if (this.holdOk) {
        leave.click()
      } else {
        this.abortHold()
        this.setStatus("Held too briefly — press and hold the plate to snap shut.")
      }
    }
    this.onPaste = (e) => {
      const box = this.box(e.target)
      if (!box) return
      e.preventDefault()
      const text = ((e.clipboardData || window.clipboardData).getData("text") || "").replace(
        /[^A-Za-z0-9+/=]/g,
        ""
      )
      const boxes = this.boxes()
      const start = text.length >= boxes.length ? 0 : boxes.indexOf(box)
      let last = -1
      for (let i = start; i < boxes.length && i - start < text.length; i++) {
        boxes[i].value = text[i - start]
        this.mark(boxes[i])
        last = i
      }
      if (last >= 0) this.focus(boxes[Math.min(boxes.length - 1, last + 1)])
      this.updateState()
    }
    // Focus selects the content so the next keystroke replaces it.
    this.onFocusIn = (e) => {
      const box = this.box(e.target)
      if (box) return box.select()
      const field = e.target.closest && e.target.closest(".lock-key-field")
      if (field && this.el.contains(field)) field.select()
    }
    this.onPointerDown = (e) => {
      if (
        e.target.closest &&
        e.target.closest("[data-leave]") &&
        this.el.dataset.lockState === "open"
      ) {
        this.startHold()
      }
    }
    this.onPointerUp = () => this.abortHold()
    this.el.addEventListener("click", this.onClick, true)
    this.el.addEventListener("input", this.onInput)
    this.el.addEventListener("keydown", this.onKey)
    this.el.addEventListener("keyup", this.onKeyUp)
    this.el.addEventListener("paste", this.onPaste)
    this.el.addEventListener("focusin", this.onFocusIn)
    this.el.addEventListener("pointerdown", this.onPointerDown)
    window.addEventListener("pointerup", this.onPointerUp)
    window.addEventListener("blur", this.onPointerUp)
    this.sync()
  },
  updated() {
    this.sync()
  },
  destroyed() {
    this.el.removeEventListener("click", this.onClick, true)
    this.el.removeEventListener("input", this.onInput)
    this.el.removeEventListener("keydown", this.onKey)
    this.el.removeEventListener("keyup", this.onKeyUp)
    this.el.removeEventListener("paste", this.onPaste)
    this.el.removeEventListener("focusin", this.onFocusIn)
    this.el.removeEventListener("pointerdown", this.onPointerDown)
    window.removeEventListener("pointerup", this.onPointerUp)
    window.removeEventListener("blur", this.onPointerUp)
    if (this.holdTimer) clearTimeout(this.holdTimer)
  },
  box(el) {
    const b = el && el.closest ? el.closest("input.lock-char") : null
    return b && this.el.contains(b) ? b : null
  },
  boxes() {
    return Array.from(this.el.querySelectorAll("input.lock-char"))
  },
  field() {
    return this.el.querySelector("input.lock-key-field")
  },
  next(box) {
    return this.boxes()[this.boxes().indexOf(box) + 1]
  },
  prev(box) {
    return this.boxes()[this.boxes().indexOf(box) - 1]
  },
  focus(el) {
    if (el) el.focus()
  },
  combo() {
    return this.el.dataset.combo || ""
  },
  // Server truth: data-value is what the render wants in the entry, and
  // a patch only ever moves an entry that disagrees with it.
  sync() {
    this.boxes().forEach((box) => {
      const want = box.dataset.value || ""
      if ((box.value || "") !== want) box.value = want
      this.mark(box)
    })
    const f = this.field()
    if (f) {
      const want = f.dataset.value || ""
      if ((f.value || "") !== want) f.value = want
      this.markField(f)
      this.updateMirror()
    }
    this.updateState()
  },
  mark(box) {
    const want = this.combo()[Number(box.dataset.idx)] || ""
    const v = box.value || ""
    // Green when the character matches, red when it varies from the
    // key, plain while the box is empty.
    if (!v) {
      delete box.dataset.correct
    } else {
      box.dataset.correct = String(v === want)
    }
  },
  markField(f) {
    const v = f.value || ""
    if (!v) {
      delete f.dataset.correct
    } else {
      f.dataset.correct = String(v === this.combo())
    }
  },
  // The mirror paints the whole key behind the mobile field: typed
  // characters green/red, the rest a dim ghost of what is expected.
  updateMirror() {
    const m = this.el.querySelector(".lock-mirror")
    const f = this.field()
    if (!m || !f) return
    const c = this.combo()
    const v = f.value || ""
    const frag = document.createDocumentFragment()
    for (let i = 0; i < c.length; i++) {
      const span = document.createElement("span")
      span.textContent = c[i]
      span.className = i < v.length ? (v[i] === c[i] ? "ok" : "bad") : "todo"
      frag.appendChild(span)
    }
    m.textContent = ""
    m.appendChild(frag)
  },
  updateState() {
    this.el.dataset.comboOk = String(this.matched())
    this.refreshStatus()
  },
  refreshStatus() {
    if (this.el.dataset.lockState === "open") {
      this.setStatus("Open on the Mainnet — hold the plate to snap shut to Development.")
      return
    }
    if (this.matched()) {
      this.setStatus(`All ${this.combo().length} match — click the shackle.`)
      return
    }
    const p = this.progress()
    this.setStatus(p.any ? this.progressLine("") : "")
  },
  // Whichever entry is in play: the mobile field when it is visible
  // and typed into, the boxes otherwise.
  progress() {
    const c = this.combo()
    const f = this.field()
    if (f && f.offsetParent !== null && f.value) {
      const v = f.value
      let right = 0
      let firstBad = -1
      for (let i = 0; i < c.length; i++) {
        if (i < v.length && v[i] === c[i]) right++
        else if (i < v.length && firstBad < 0) firstBad = i
      }
      return {any: true, right, total: c.length, firstBad, field: true}
    }
    const boxes = this.boxes()
    let right = 0
    let firstBad = -1
    let any = false
    for (let i = 0; i < boxes.length; i++) {
      const v = boxes[i].value || ""
      if (v) any = true
      if (v === c[i]) right++
      else if (v && firstBad < 0) firstBad = i
    }
    return {any, right, total: boxes.length, firstBad, field: false}
  },
  progressLine(prefix) {
    const p = this.progress()
    if (!p.any) return ""
    const where =
      p.firstBad >= 0 ? `, first mismatch at ${p.field ? "character" : "box"} ${p.firstBad + 1}` : ""
    return `${prefix ? prefix + ": " : ""}${p.right} of ${p.total} correct${where}.`
  },
  wrongMessage() {
    const p = this.progress()
    if (!p.any) return "The boxes are empty — type or paste the key first."
    return this.progressLine("Won't open")
  },
  matched() {
    const c = this.combo()
    if (!c) return false
    const f = this.field()
    if (f && f.offsetParent !== null && f.value === c) return true
    const boxes = this.boxes()
    if (boxes.length !== c.length) return false
    return boxes.every((b, i) => (b.value || "") === c[i])
  },
  // Where a failed attempt should put the caret: the visible entry.
  firstWrong() {
    const f = this.field()
    if (f && f.offsetParent !== null) return f
    const boxes = this.boxes()
    const c = this.combo()
    return boxes.find((b, i) => (b.value || "") !== c[i]) || boxes[0] || f
  },
  clearAll() {
    this.boxes().forEach((b) => {
      b.value = ""
      this.mark(b)
    })
    const f = this.field()
    if (f) {
      f.value = ""
      this.markField(f)
      this.updateMirror()
    }
    this.updateState()
    this.focus(this.firstWrong())
  },
  fill() {
    if (this.el.dataset.lockState === "open") {
      this.setStatus("The lock is already open on the Mainnet.")
      return
    }
    const c = this.combo()
    this.boxes().forEach((b, i) => {
      b.value = c[i] || ""
      this.mark(b)
    })
    const f = this.field()
    if (f) {
      f.value = c
      this.markField(f)
      this.updateMirror()
    }
    this.updateState()
    const shackle = this.el.querySelector("[data-unlock]")
    if (shackle) shackle.focus()
  },
  copy(btn) {
    const done = () => {
      const was = btn.textContent
      btn.textContent = "Copied"
      this.setStatus("Key copied to the clipboard.")
      setTimeout(() => {
        btn.textContent = was
      }, 1500)
    }
    const fallback = () => {
      const k = this.el.querySelector("[data-fill]")
      if (k && window.getSelection) {
        const range = document.createRange()
        range.selectNodeContents(k)
        const sel = window.getSelection()
        sel.removeAllRanges()
        sel.addRange(range)
        k.focus()
      }
      this.setStatus("Press Cmd/Ctrl+C to copy the selected key.")
    }
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(this.combo()).then(done).catch(fallback)
    } else {
      fallback()
    }
  },
  // Hold-to-leave: the plate only passes the capture gate after the
  // pointer (or Space) has held it down for LOCK_HOLD_MS.
  startHold() {
    if (this.holdTimer || this.holdOk) return
    this.setHold(true)
    this.setStatus("Keep holding to snap shut to Development…")
    this.holdTimer = setTimeout(() => {
      this.holdTimer = null
      this.holdOk = true
      this.setStatus("Release to snap shut to Development.")
    }, LOCK_HOLD_MS)
  },
  abortHold() {
    if (this.holdTimer) {
      clearTimeout(this.holdTimer)
      this.holdTimer = null
      this.setHold(false)
    }
  },
  setHold(on) {
    const plate = this.el.querySelector("[data-leave]")
    if (plate) plate.classList.toggle("holding", on)
  },
  setStatus(text) {
    const el = this.el.querySelector("#net-lock-status")
    if (el) el.textContent = text
  },
  shake() {
    const body = this.el.querySelector(".lock-body")
    if (!body) return
    body.classList.remove("lock-shaking")
    void body.offsetWidth
    body.classList.add("lock-shaking")
    setTimeout(() => body.classList.remove("lock-shaking"), 450)
  },
}

let liveSocket = new LiveSocket("/live", Socket, {
  params: {_csrf_token: csrfToken},
  hooks: {MenuBridge, InfiniteScroll, Prefs, OpenPost, TabActivity, AppRunner, CodeEditor: CodeEditorHook, WasmDropin, LockDials}
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
