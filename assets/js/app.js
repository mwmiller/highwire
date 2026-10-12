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

// The constellation's selected peer: when the server-side selection
// changes, bring the matching list row into view. The row is found by
// its data-sky-key (same string the SVG nodes carry), scoped to the
// two lists so a node never scrolls to itself.
let SkyScroll = {
  mounted() {
    this.maybeScroll()
  },
  updated() {
    this.maybeScroll()
  },
  maybeScroll() {
    const key = this.el.dataset.target
    if (!key) return
    const escaped = window.CSS && CSS.escape ? CSS.escape(key) : key.replace(/"/g, '\\"')
    const row = this.el.ownerDocument.querySelector(
      `#dial-rows [data-sky-key="${escaped}"], #known-peer-rows [data-sky-key="${escaped}"]`
    )
    if (row) {
      const reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches
      row.scrollIntoView({block: "nearest", behavior: reduced ? "auto" : "smooth"})
    }
  }
}

// Feed scroll position: opening a post tears the timeline down, and
// coming back used to drop the reader at the top of a fresh mount.
// Save on a rAF-throttled scroll; restore on mount and keep retrying
// while the stored offset doesn't stick — the first render can be
// shorter than the final content, and a user scroll always wins.
const FEED_SCROLL_KEY = "highwire:feed-scroll"

let FeedScroll = {
  mounted() {
    this.stored = 0
    try {
      this.stored = Number(sessionStorage.getItem(FEED_SCROLL_KEY)) || 0
    } catch (_) {}
    this.restored = this.stored <= 0
    this.restoring = false
    this.frame = 0

    this.onScroll = () => {
      if (this.restoring) return
      this.restored = true
      cancelAnimationFrame(this.frame)
      this.frame = requestAnimationFrame(() => {
        try {
          sessionStorage.setItem(FEED_SCROLL_KEY, String(Math.round(this.el.scrollTop)))
        } catch (_) {}
      })
    }

    this.el.addEventListener("scroll", this.onScroll, {passive: true})
    this.apply()
  },

  updated() {
    if (!this.restored) this.apply()
  },

  apply() {
    this.restoring = true
    this.el.scrollTop = this.stored
    requestAnimationFrame(() => {
      this.restoring = false
      if (this.el.scrollTop >= this.stored) this.restored = true
    })
  },

  destroyed() {
    cancelAnimationFrame(this.frame)
    this.el.removeEventListener("scroll", this.onScroll)
    // A departure mid-restore holds a clamped offset; keep the stored
    // one rather than overwriting the position with its shadow.
    const keep = this.restoring ? this.stored : this.el.scrollTop
    try {
      sessionStorage.setItem(FEED_SCROLL_KEY, String(Math.round(keep)))
    } catch (_) {}
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
        o.classList.add("bg-active")
      } else {
        o.removeAttribute("data-active")
        o.classList.remove("bg-active")
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

    // The draft takes markdown with the sigil inside the brackets —
    // [@Name](@id) / [~Name](@id) — so the rendered mention reads
    // @Name or ~Name, wholly linked to the identity view.
    const mention = "[" + t.sigil + this.escapeMd(name) + "](" + id + ") "
    const value = this.el.value.slice(0, t.start) + mention + this.el.value.slice(t.end)
    const caret = t.start + mention.length

    this.el.value = value
    this.el.setSelectionRange(caret, caret)
    this.close()

    // The host input picks its own event: the timeline composer drafts
    // via "compose-draft", the thread reply box via "reply-draft".
    try {
      const draftEvent = this.el.dataset.draftEvent || "compose-draft"
      this.pushEvent(draftEvent, {body: value}, () => {})
    } catch (_) {}
  },

  // Link text: brackets or backslashes in a display name would break
  // out of the […] markdown.
  escapeMd(s) {
    return s.replace(/([\\[\]])/g, "\\$1")
  }
}

// Relative-time labels: the server renders the initial text plus the
// data-ts it came from; this rewrites the text from that stamp so the
// labels stay accurate with zero server re-renders. Mirrors
// HighWireWeb.Components.Time.rel_time/1, including the "%b %d, %Y"
// UTC date the server prints once a label passes a week.
const relAge = ts => {
  const diff = Date.now() - ts
  if (diff < 60_000) return "just now"
  if (diff < 3_600_000) return Math.floor(diff / 60_000) + "m ago"
  if (diff < 86_400_000) return Math.floor(diff / 3_600_000) + "h ago"
  if (diff < 604_800_000) return Math.floor(diff / 86_400_000) + "d ago"
  return new Date(ts).toLocaleDateString("en-US", {
    timeZone: "UTC",
    month: "short",
    day: "2-digit",
    year: "numeric"
  })
}

const ageLabels = () => {
  document.querySelectorAll("time[data-ts]").forEach(el => {
    const ts = Number(el.dataset.ts)
    if (!ts) return
    const text = relAge(ts)
    if (el.textContent !== text) el.textContent = text
  })
}

ageLabels()
setInterval(ageLabels, 15_000)
// Background tabs throttle timers, so refresh the moment one returns.
document.addEventListener("visibilitychange", () => {
  if (!document.hidden) ageLabels()
})

// Slash puts the caret in the feed search box unless the user is
// already typing somewhere; Escape empties it and leaves. The
// dispatched input event bubbles to the form's phx-change, so the
// server's @q resets with the value instead of keeping stale results.
const feedSearchInput = () => document.querySelector("#feed-search input")

document.addEventListener("keydown", e => {
  if (e.key === "/" && !e.metaKey && !e.ctrlKey && !e.altKey) {
    const t = e.target
    if (t && (t.tagName === "INPUT" || t.tagName === "TEXTAREA" || t.isContentEditable)) return
    const input = feedSearchInput()
    if (!input) return
    e.preventDefault()
    input.focus()
    input.select()
    return
  }

  if (e.key === "Escape") {
    const input = feedSearchInput()
    if (input && document.activeElement === input) {
      input.value = ""
      input.dispatchEvent(new Event("input", {bubbles: true}))
      input.blur()
      return
    }

    // On a post, Escape walks back to the timeline — unless a text
    // field holds the key (the reply box's mention popup handles its
    // own Escape on the way past) or that popup is still rendered.
    if (!window.location.pathname.startsWith("/post/")) return
    const t = e.target
    if (t && (t.tagName === "INPUT" || t.tagName === "TEXTAREA" || t.isContentEditable)) return
    if (document.getElementById("mention-list")) return
    const back = document.getElementById("post-back")
    if (!back) return
    e.preventDefault()
    back.click()
  }
})

// The webview never grants new windows, so a target="_blank" click
// dies silently. External URLs go to the shell, which opens the
// system browser; same-origin links (LiveView navigation) and plain
// browser previews keep their native behavior.
const externalUrl = href => {
  try {
    const url = new URL(href, window.location.href)
    if (url.origin === window.location.origin) return null
    if (url.protocol === "http:" || url.protocol === "https:" || url.protocol === "mailto:") {
      return url.href
    }
  } catch (_) {}
  return null
}

const openExternally = e => {
  if (!window.__TAURI__) return
  const target = e.target instanceof Element ? e.target.closest("a[href]") : null
  if (!target) return
  const url = externalUrl(target.getAttribute("href"))
  if (!url) return
  e.preventDefault()
  window.__TAURI__.core.invoke("open_external", {url}).catch(() => {})
}

document.addEventListener("click", openExternally)
// Middle-click asks for a new window too; treat it the same way.
document.addEventListener("auxclick", e => {
  if (e.button === 1) openExternally(e)
})

let liveSocket = new LiveSocket("/live", Socket, {
  params: {_csrf_token: csrfToken},
  hooks: {InfiniteScroll, Prefs, OpenPost, TabActivity, Mentions, SkyScroll, FeedScroll}
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
