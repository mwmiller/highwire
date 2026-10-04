// The playground's editor.
//
// The editor itself is the vendored CodeMirror 6 bundle in assets/vendor
// (rebuilt by scripts/build-codemirror.sh); this file is the LiveView hook
// around it. The hook owns the DOM the component hands it — hence
// `phx-update="ignore"` on the mount point — and reports the document back on
// a debounce, so a burst of typing is one message rather than one per
// keystroke.

import {
  basicSetup,
  EditorState,
  EditorView,
  lintGutter,
  placeholder,
  setDiagnostics
} from "../vendor/codemirror.mjs"

// The same stack as tailwind.config.js's mono: platform faces only, no webfont.
const MONO =
  'ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", "Courier New", monospace'

// Colours are read from the --ed-* custom properties app.css defines, both in
// its light block and its `prefers-color-scheme: dark` one, so the editor
// follows the app's media-based dark mode without re-reading matchMedia here.
const theme = EditorView.theme({
  "&": {
    height: "100%",
    backgroundColor: "var(--ed-bg)",
    color: "var(--ed-fg)",
    fontSize: "13px"
  },
  ".cm-scroller": { fontFamily: MONO },
  ".cm-content": { caretColor: "var(--ed-caret)", padding: "8px 0" },
  ".cm-placeholder": { color: "var(--ed-muted)" },
  ".cm-cursor, .cm-dropCursor": {
    borderLeftColor: "var(--ed-caret)",
    borderLeftWidth: "2px"
  },
  "&.cm-focused .cm-selectionBackground, .cm-selectionBackground, .cm-content ::selection": {
    backgroundColor: "var(--ed-selection)"
  },
  ".cm-activeLine": { backgroundColor: "var(--ed-active)" },
  ".cm-gutters": {
    backgroundColor: "var(--ed-bg)",
    color: "var(--ed-gutter)",
    borderRight: "1px solid var(--ed-border)"
  },
  ".cm-activeLineGutter": { backgroundColor: "var(--ed-active)" },
  ".cm-lineNumbers .cm-gutterElement": { padding: "0 6px 0 10px" },
  ".cm-matchingBracket, &.cm-focused .cm-matchingBracket": {
    backgroundColor: "var(--ed-match)"
  },
  ".cm-tooltip": {
    backgroundColor: "var(--ed-bg)",
    color: "var(--ed-fg)",
    border: "1px solid var(--ed-border)"
  }
})

const DEBOUNCE_MS = 250

// An authoring buffer, not a file format: long enough for anything the DSL
// compiler will accept, short enough that one draft cannot pin an unbounded
// string in socket state. The publish path re-checks size against the real
// artifact cap, so this is only about what a keystroke may carry.
const MAX_SOURCE_BYTES = 256 * 1024

export const CodeEditorHook = {
  mounted() {
    this.pending = null

    this.view = new EditorView({
      parent: this.el,
      state: EditorState.create({
        doc: this.el.dataset.value || "",
        extensions: [
          basicSetup,
          theme,
          EditorView.lineWrapping,
          lintGutter(),
          placeholder("app source"),
          EditorView.updateListener.of((update) => {
            if (!update.docChanged) return
            clearTimeout(this.pending)
            this.pending = setTimeout(() => this.report(), DEBOUNCE_MS)
          })
        ]
      })
    })

    // The server compiles each burst of typing that it already receives and
    // answers with the compiler's verdict: ranges in document coordinates,
    // severity and all set at once, so a fix clears as fast as a typo lands.
    this.handleEvent("playground-diagnostics", (payload) => this.mark(payload))
  },

  // Diagnostics arrive as positions in the same coordinates CodeMirror
  // measures with — UTF-16 code units — but they are clamped here too: the
  // document this hook holds and the source the server compiled can drift by
  // a keystroke between the push and its arrival, and a stale mark on the
  // wrong character is worse than no mark at all.
  mark(payload) {
    if (!this.view) return

    const length = this.view.state.doc.length
    const diagnostics = (payload.diagnostics || []).map((diagnostic) => {
      const from = Math.max(0, Math.min(diagnostic.from, length))
      return {
        from,
        to: Math.max(from, Math.min(diagnostic.to, length)),
        severity: "error",
        message: diagnostic.message
      }
    })

    this.view.dispatch(setDiagnostics(this.view.state, diagnostics))
  },

  report() {
    // Destroyed hooks still fire a pending timer: the editor can go away with
    // the view while the debounce is in flight.
    if (!this.view || !this.el.isConnected) return

    this.pushEvent("playground-source", {
      value: this.view.state.doc.toString().slice(0, MAX_SOURCE_BYTES)
    })
  },

  destroyed() {
    clearTimeout(this.pending)
    this.pending = null

    if (this.view) this.view.destroy()
    this.view = null
  }
}
