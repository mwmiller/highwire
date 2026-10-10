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

let liveSocket = new LiveSocket("/live", Socket, {
  params: {_csrf_token: csrfToken},
  hooks: {InfiniteScroll, Prefs, OpenPost, TabActivity}
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
