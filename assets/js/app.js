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

// Composer mentions: typing @ or ~ before a word opens the popup the
// server renders from mention-query. Picking splices the feed id into
// the draft here in the browser — string indices stay UTF-16-safe
// locally — and pushes the new body via compose-draft so the server's
// draft matches immediately (the textarea's phx-debounce would lag).
let Mentions = {
  mounted() {
    this.query = null

    this.onInput = () => this.scan()
    this.onBlur = () => this.close()
    this.onKeyDown = (e) => this.keydown(e)

    this.el.addEventListener("input", this.onInput)
    this.el.addEventListener("click", this.onInput)
    this.el.addEventListener("blur", this.onBlur)
    this.el.addEventListener("keydown", this.onKeyDown)

    // Keep focus — and the caret — in the textarea when a popup row
    // is clicked: mousedown would blur us and close the list first.
    this.onMouseDown = (e) => {
      if (e.target.closest("[data-mention-option]")) e.preventDefault()
    }
    this.onClick = (e) => {
      const opt = e.target.closest("[data-mention-option]")
      if (!opt) return
      e.preventDefault()
      const idx = this.options().indexOf(opt)
      if (idx >= 0) this.pick(idx)
    }

    document.addEventListener("mousedown", this.onMouseDown)
    document.addEventListener("click", this.onClick)
  },

  destroyed() {
    this.el.removeEventListener("input", this.onInput)
    this.el.removeEventListener("click", this.onInput)
    this.el.removeEventListener("blur", this.onBlur)
    this.el.removeEventListener("keydown", this.onKeyDown)
    document.removeEventListener("mousedown", this.onMouseDown)
    document.removeEventListener("click", this.onClick)
  },

  // The @ or ~ token ending at the caret: which sigil opened it, where
  // the token starts, and what has been typed after it.
  token() {
    const caret = this.el.selectionStart ?? 0
    const before = this.el.value.slice(0, caret)
    const m = /(?:^|\s)([@~])([^\s@~]*)$/.exec(before)
    if (!m) return null
    return {sigil: m[1], q: m[2], start: before.length - m[2].length - 1, end: caret}
  },

  scan() {
    const t = this.token()
    if (!t) {
      this.close()
      return
    }
    if (t.q === this.query) return
    this.query = t.q
    try {
      this.pushEvent("mention-query", {q: t.q}, () => {})
    } catch (_) {}
  },

  close() {
    if (this.query === null) return
    this.query = null
    try {
      this.pushEvent("mention-close", {}, () => {})
    } catch (_) {}
  },

  options() {
    return Array.from(document.querySelectorAll("#mention-list [data-mention-option]"))
  },

  activeIndex(opts) {
    const active = document.querySelector("#mention-list [data-mention-option][data-active]")
    return active ? opts.indexOf(active) : -1
  },

  setActive(opts, idx) {
    opts.forEach((o, i) => {
      if (i === idx) {
        o.setAttribute("data-active", "")
        o.classList.add("bg-panel2")
      } else {
        o.removeAttribute("data-active")
        o.classList.remove("bg-panel2")
      }
    })
  },

  keydown(e) {
    if (e.key === "Escape") {
      if (this.query !== null) {
        e.preventDefault()
        this.close()
      }
      return
    }

    // Moving the caret out of the token retires the popup.
    if (["ArrowLeft", "ArrowRight", "Home", "End"].includes(e.key)) {
      if (!this.token()) this.close()
      return
    }

    const opts = this.options()
    if (opts.length === 0) return

    if (e.key === "ArrowDown" || e.key === "ArrowUp") {
      e.preventDefault()
      let idx = this.activeIndex(opts)
      if (e.key === "ArrowDown") idx = idx < 0 ? 0 : (idx + 1) % opts.length
      else idx = idx <= 0 ? opts.length - 1 : idx - 1
      this.setActive(opts, idx)
    } else if (e.key === "Enter" || e.key === "Tab") {
      e.preventDefault()
      const idx = this.activeIndex(opts)
      this.pick(idx >= 0 ? idx : 0)
    }
  },

  pick(idx) {
    const t = this.token()
    const opts = this.options()
    if (!t || idx < 0 || idx >= opts.length) {
      this.close()
      return
    }

    const opt = opts[idx]
    const id = opt.dataset.id
    const name = opt.dataset.name || id

    // The draft takes markdown that keeps the sigil the user opened
    // with — @[Name](@id) or \~[Name](@id) — both render the sigil
    // in front of a profile link, and the backslash stops a lone ~
    // from opening ~…~ strikethrough in other SSB clients.
    const mention =
      (t.sigil === "~" ? "\\~" : "@") + "[" + this.escapeMd(name) + "](" + id + ") "
    const value = this.el.value.slice(0, t.start) + mention + this.el.value.slice(t.end)
    const caret = t.start + mention.length

    this.el.value = value
    this.el.setSelectionRange(caret, caret)
    this.close()

    try {
      this.pushEvent("compose-draft", {body: value}, () => {})
    } catch (_) {}
  },

  // Link text: brackets or backslashes in a display name would break
  // out of the […] markdown.
  escapeMd(s) {
    return s.replace(/([\\[\]])/g, "\\$1")
  }
}

let liveSocket = new LiveSocket("/live", Socket, {
  params: {_csrf_token: csrfToken},
  hooks: {InfiniteScroll, Prefs, OpenPost, TabActivity, Mentions}
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
