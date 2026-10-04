// The playground's right-rail control that hands a foreign `.wasm` to the
// run pane.
//
// The file never leaves the browser — what a drop-in is gated on is whether
// *this* webview can instantiate it — so this hook reads the chosen file and
// passes the `File` over, rather than round-tripping the bytes through the
// LiveView to have them handed straight back.
//
// The two controls live in different columns of the playground and cannot
// reach each other's hooks, so the hand-off is an event on the pane itself:
// this hook fires `highwire:wasm`, and `AppRunner` owns the listener and
// everything that happens to the module afterwards.

const HANDOFF = "highwire:wasm"

export const WasmDropin = {
  mounted() {
    this._onChange = event => {
      const input = event.target
      const file = input.files && input.files[0]
      // Clear first: picking the same file again still has to fire change.
      input.value = ""
      if (!file) return

      const pane = document.getElementById("playground-pane")
      if (pane) pane.dispatchEvent(new CustomEvent(HANDOFF, {detail: file}))
    }

    this.el.addEventListener("change", this._onChange)
  },

  destroyed() {
    this.el.removeEventListener("change", this._onChange)
  }
}
