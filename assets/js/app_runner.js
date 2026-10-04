// The `AppRunner` hook: everything that ties a module to the page.
//
// It owns the workers (the kill switch), the two sinks the component
// renders into, and the round trips to the host. The effect semantics live
// in `app_loop.js` and the memory protocol in `app_session.js`; this file is
// only the wiring between them and LiveView.
//
// One deadline covers every wait — the module loading, it starting (which
// includes its own `start` code), a `handle` that never returns, and a host
// reply that never arrives. Any of those is a reason to terminate the
// worker, which is also the only way to stop a module that is spinning.
//
// The hook is started and stopped from outside: `data-wasm-src` runs a
// module as soon as the pane mounts (the way a published app's pane does),
// and LiveView drives the playground's pane with `app-run`/`app-stop`, since
// there the module comes from an editor buffer rather than from a URL.
// Every run also records itself — what the module asked for, what came back,
// what it printed — and hands that list to `app-trace` on the LiveView, which
// is what the playground's left rail steps through.
//
// A foreign `.wasm` reaches the pane from the right rail's picker or by
// being dropped on it, and both are gated: the bytes are instantiated here,
// in this browser, and a drop-in only keeps running once a first tick comes
// back following the ABI — a refusal stops it on the spot. That gate is what
// the publish path will lean on, so it is recorded in the trace like
// everything else.
//
// The pane is a lease (§3): one physical pane, many apps behind it. Apps
// are sessions keyed by who they are, and switching the pane to another app
// transfers the lease rather than rebuilding the pane — the outgoing session
// is parked (its rAF stopped, a `blur` delivered, its print log, view and
// last frame snapshotted beside its worker) and the incoming one is resumed
// from that snapshot, or instantiated fresh the first time it is opened.
// Pointer events and `tick`s reach only the lease holder, and at most
// SESSION_CAP sessions stand behind the pane; opening one more terminates
// the least recently used parked session, which is recoverable because an
// app's durable state lives in kv, not in its worker.
//
// Two messages come from this file rather than from the host: `tick`s on
// requestAnimationFrame once a module asks for `animate`, and `ui` events
// for the pointer over the view's canvas. Both are paced by the same rule —
// one delivery in flight at a time — so a module that draws at its own pace
// is what limits the rate, and the deadline armed over `_deliver` covers a
// tick that never comes back (§3).

import {AppLoop, fromBase64, isMap} from "./app_loop.js"
import {applyDraw, checkDraw} from "./app_draw.js"
import {buildView} from "./app_view.js"
import {encode} from "./cbor.js"
const DEADLINE_MS = 5000
const PRINT_LIMIT = 64 * 1024
const TRACE_LIMIT = 200
const TRACE_DETAIL_LIMIT = 400
const TRACE_FLUSH_MS = 120
// Pointer events arrive faster than any module answers them, so the queue
// between the pane and the worker is bounded: moves coalesce into the one
// sample waiting, and past the cap the oldest entry goes rather than the
// newest — a down or an up is worth more than a stale move.
const UI_QUEUE_LIMIT = 8
// Entries pushed for logs this pane watches arrive on their own wire, and a
// module that is busy when they do is a reason to hold them rather than to
// drop them: past the cap the oldest goes rather than the newest, because
// entries are sequential on their log and a later one is not worth more than
// an earlier one the module has not seen yet. A drop while the session is
// not the lease holder also marks the session for a `queue_overflow` marker
// ahead of the entries on its next resume (§3).
const ENTRY_QUEUE_LIMIT = 64
// How many apps may sit behind one pane. Three is the model's own number
// (§3): the active app plus two parked ones. The cap is enforced by
// terminating the least recently used parked session, never the lease
// holder.
const SESSION_CAP = 3
// Somebody else's artifact, so the drop-in gets the order of magnitude of
// the artifact budget rather than the buffer's own size cap.
const MAX_WASM_BYTES = 4 * 1024 * 1024

export const AppRunner = {
  mounted() {
    this._sessions = new Map()
    this._session = null
    this._activeKey = null
    this._switching = Promise.resolve()
    this._trace = []
    this._traceTimer = null
    this._animateOn = false
    this._raf = null

    this.handleEvent("app-run", payload => this._run(payload || {}))
    this.handleEvent("app-stop", () => {
      const session = this._session
      if (session) session.loop.stop("stopped")
    })
    this.handleEvent("app-entry", payload => this._queueEntry(payload || {}))

    // The rail's picker sits in another column and cannot reach this hook,
    // so it hands the file over on this element; dropping one on the pane is
    // the same hand-off with no rail involved.
    this._onHandoff = event => this._dropin(event.detail)
    this._onDragOver = event => {
      event.preventDefault()
      this.el.classList.add("run-pane-drop")
    }
    this._onDragLeave = event => {
      if (this.el.contains(event.relatedTarget)) return
      this.el.classList.remove("run-pane-drop")
    }
    this._onDrop = event => {
      event.preventDefault()
      this.el.classList.remove("run-pane-drop")
      const file = event.dataTransfer && event.dataTransfer.files[0]
      if (file) this._dropin(file)
    }

    this.el.addEventListener("highwire:wasm", this._onHandoff)
    this.el.addEventListener("dragenter", this._onDragOver)
    this.el.addEventListener("dragover", this._onDragOver)
    this.el.addEventListener("dragleave", this._onDragLeave)
    this.el.addEventListener("drop", this._onDrop)
    // Delegated from the pane rather than bound to each canvas: the canvas
    // is rebuilt on every render, and the pane outlives all of them.
    this._onPointer = event => this._pointer(event)
    this.el.addEventListener("pointerdown", this._onPointer)
    this.el.addEventListener("pointermove", this._onPointer)
    this.el.addEventListener("pointerup", this._onPointer)

    this._activeKey = this._paneKey()
    const src = this.el.dataset.wasmSrc
    if (src) this._activate(this._activeKey, src)
  },

  // The pane's data attributes are the lease's transfer signal: LiveView
  // merges `data-*` onto an ignored element, so when the parent navigates
  // to another app the key under the hook changes while the hook itself
  // stays mounted — which is what lets the outgoing worker be parked
  // instead of destroyed (§3).
  updated() {
    const key = this._paneKey()
    if (key === this._activeKey) return
    const src = this.el.dataset.wasmSrc || null
    this._switching = this._switching.then(() => this._switch(key, src)).catch(() => {})
  },

  destroyed() {
    if (this._traceTimer !== null) clearTimeout(this._traceTimer)
    this._traceTimer = null
    this.el.removeEventListener("highwire:wasm", this._onHandoff)
    this.el.removeEventListener("dragenter", this._onDragOver)
    this.el.removeEventListener("dragover", this._onDragOver)
    this.el.removeEventListener("dragleave", this._onDragLeave)
    this.el.removeEventListener("drop", this._onDrop)
    this.el.removeEventListener("pointerdown", this._onPointer)
    this.el.removeEventListener("pointermove", this._onPointer)
    this.el.removeEventListener("pointerup", this._onPointer)
    this.el.classList.remove("run-pane-drop")
    this._stopAnimate()
    // Leaving the view ends every session: the lease lives with the pane
    // that grants it, and a parked worker with nothing to resume into is
    // only a process still burning a core.
    for (const session of Array.from(this._sessions.values())) {
      this._teardownSession(session)
    }
    this._sessions.clear()
    this._session = null
  },

  _paneKey() {
    const pk = this.el.dataset.pk
    const slug = this.el.dataset.slug
    if (pk && slug) return `${pk}/${slug}`
    return this.el.id || "pane"
  },

  // One session per app behind the pane: its worker, its loop with the
  // strikes and the stopped flag that belong to one attempt at running it,
  // its own queues, and — once it has been parked — the snapshot of the
  // pane it gave up. A run gets a fresh session, so re-running builds those
  // things again rather than resuming a loop that already gave up.
  _newSession(key) {
    const session = {
      key,
      state: "running",
      ready: false,
      worker: null,
      loop: null,
      timer: null,
      inFlight: false,
      ui: [],
      entries: [],
      overflowed: false,
      animateOn: false,
      gate: false,
      removed: false,
      statusText: null,
      printText: null,
      viewHtml: null,
      viewHidden: true,
      frame: null
    }
    session.loop = this._newLoop(session)
    return session
  },

  _newLoop(session) {
    const status = this.el.querySelector("#app-status")
    const print = this.el.querySelector("#app-print")
    const view = this.el.querySelector("#app-view")

    return new AppLoop({
      status: text => {
        if (session === this._session) {
          status.textContent = text
        } else {
          session.statusText = text
        }
      },
      stop: reason => {
        this._refuseGate(session, reason)
        this._record("stop", reason)
        const wasLeaseHolder = session === this._session
        this._teardownSession(session)
        // The run is over — it struck out, finished or was stopped — and the
        // LiveView is holding watch baselines on this pane's behalf. It
        // clears them on its own way out (a new run, navigation), but a run
        // that ends here has no other message coming, and a baseline with
        // nothing listening keeps polling a log for nobody. A parked session
        // that dies is not the one the baselines belong to, so it stays
        // silent.
        if (wasLeaseHolder) this.pushEvent("app-stopped", {})
      },
      print: text => {
        this._record("print", text)
        if (session === this._session) {
          print.textContent = appendPrint(print.textContent, text)
          // The console is a fixed-height window onto the log: each line the
          // module prints scrolls the tail into view rather than growing the
          // pane the way a print log left to itself would.
          print.scrollTop = print.scrollHeight
        } else {
          session.printText = appendPrint(session.printText, text)
        }
      },
      render: value => {
        // A tree that failed validation comes back with `strike`, and as
        // the text dump rather than as a half-built view.
        const built = buildView(value)
        if (built.strike) session.loop.strike(built.strike)
        this._record("render", viewShape(value))
        if (session === this._session) {
          view.textContent = ""
          view.appendChild(built.node)
          view.classList.remove("hidden")
        } else {
          session.viewHtml = built.node.outerHTML
          session.viewHidden = false
        }
      },
      draw: ops => {
        // One canvas per view, the first one the tree declares: the lease
        // that keeps a viewer to one app at a time is the same one canvas
        // (§3), so a draw does not get to choose where it lands. A draw for
        // a session that does not hold the lease has no canvas to land on
        // and is dropped — the parked app redraws from its own frame when it
        // is resumed.
        if (session !== this._session) return
        const canvas = this.el.querySelector("#app-view canvas[data-app-canvas]")
        const problem = canvas ? checkDraw(ops) : "a draw with no canvas in the view"
        this._record("draw", problem ? "rejected" : `${ops.length} ops`)
        if (problem) {
          session.loop.strike(problem)
          return
        }
        try {
          const failure = applyDraw(canvas, ops)
          if (failure) session.loop.strike(failure)
        } catch (error) {
          session.loop.strike(`the draw could not be applied (${error.message})`)
        }
      },
      animate: on => {
        // The on/off is worth one trace entry; the ticks themselves are
        // not — sixty an second would push the run's own history out of
        // the rail the reader is stepping through. The wish itself belongs
        // to the session and survives parking: a resumed app's frame clock
        // starts again the way it was left (§3).
        this._record("animate", on ? "on" : "off")
        session.animateOn = on
        if (session === this._session && session.state === "running") {
          if (on) this._startAnimate()
          else this._stopAnimate()
        }
      },
      want: (op, args) => {
        this._record("want", op)
        return this._want(session, op, args)
      },
      publish: entry => {
        return this._publish(session, entry)
      },
      deliver: message => {
        this._record("reply", replyShape(message))
        return this._deliver(session, message)
      }
    })
  },

  // Transfer the lease to `key`: park whoever holds it, blank the pane, and
  // either resume the incoming app's parked session, instantiate it fresh,
  // or — with no release behind it — leave the pane with its own words.
  // Switches are chained, so a navigation that lands before the previous one
  // finished waits its turn rather than interleaving two parks.
  async _switch(key, src) {
    const outgoing = this._session
    if (outgoing && outgoing.key === key) {
      this._activeKey = key
      return
    }

    if (outgoing) {
      await this._park(outgoing)
      this._session = null
    }

    this._clearPane()
    this._activeKey = key

    const held = this._sessions.get(key)
    if (held && !held.removed) {
      this._resume(held)
    } else if (src) {
      this._activate(key, src)
    }
    // else: nothing runnable stands behind this key — the pane keeps the
    // "No module loaded." line `_clearPane` wrote.
  },

  // Park a session: stop its frame clock, let whatever delivery it owes
  // finish, hand it the `blur` it saves on, and lift the pane's contents
  // into its snapshot — print log, view tree, status line and the canvas's
  // last frame, so resuming can blit the frame back with no white flash
  // (§3). A session that never reached `ready` has nothing to preserve and
  // is simply dropped; the next open instantiates it again.
  async _park(session) {
    if (session.state !== "running") return
    session.state = "parking"
    this._stopAnimate()
    await this._settle(session)
    if (session.removed) return

    if (!session.ready) {
      this._teardownSession(session)
      return
    }

    this._deliver(session, {msg: "blur"})
    await this._settle(session)
    if (session.removed) return

    this._snapshot(session)
    session.state = "parked"
  },

  // Resume a parked session: the snapshot goes back onto the pane (the
  // frame blitted first, so the reader sees the app where it was left), a
  // `queue_overflow` marker — if anything was dropped while this session
  // waited — heads the entry queue, and the `resume` message tells the
  // module it holds the lease again. Deliveries are one at a time, so the
  // marker and the queued entries follow the `resume` in order.
  _resume(session) {
    session.state = "running"
    this._session = session
    this._remember(session)
    this._restore(session)

    if (session.overflowed) {
      session.overflowed = false
      session.entries.unshift({msg: "queue_overflow"})
    }

    this._deliver(session, {msg: "resume"})
    if (session.animateOn) this._startAnimate()
    this._flushUi(session)
    this._flushEntries(session)
  },

  // A fresh lease: remember the session under its key (evicting beyond the
  // cap first) and start its module from the release route.
  _activate(key, src) {
    this._evict()
    const session = this._newSession(key)
    this._remember(session)
    this._session = session
    this._load(session, src)
  },

  // The recency order the cap evicts from: re-inserting makes this session
  // the newest entry in the map's insertion order.
  _remember(session) {
    this._sessions.delete(session.key)
    this._sessions.set(session.key, session)
  },

  _evict() {
    while (this._sessions.size >= SESSION_CAP) {
      let victim = null
      for (const session of this._sessions.values()) {
        if (session.state === "parked" && session !== this._session) {
          victim = session
          break
        }
      }
      if (!victim) {
        for (const session of this._sessions.values()) {
          if (session !== this._session) {
            victim = session
            break
          }
        }
      }
      // Only the lease holder is left (or nothing at all): nothing to evict.
      if (!victim) return
      this._teardownSession(victim)
    }
  },

  // Wait out a session's outstanding work: the delivery in flight, then the
  // effects chain it feeds — deferred wants and publishes included — until
  // the worker is idle. The deadline is the same one the run lives under, so
  // a session that never comes back fails its own park the way it fails
  // everything else: stopped, and out of the map.
  //
  // The chain gets the deadline too, rather than being awaited outright: it
  // is waiting on a host reply that may never come, and a park wedged on one
  // would wedge every switch queued behind it, since `_switching` is a chain
  // of its own. Racing it against a slice keeps the wait bounded and lets the
  // park go on with whatever the module had finished.
  async _settle(session) {
    const until = Date.now() + DEADLINE_MS
    while (Date.now() < until && !session.removed && session.worker) {
      if (session.inFlight) {
        await nap(2)
        continue
      }

      const settled = await Promise.race([
        session.loop.settle().then(() => "settled"),
        nap(50).then(() => "waiting")
      ])
      if (settled === "settled") return
      if (session.inFlight) continue
    }
  },

  _snapshot(session) {
    const status = this.el.querySelector("#app-status")
    const print = this.el.querySelector("#app-print")
    const view = this.el.querySelector("#app-view")

    session.statusText = status ? status.textContent : ""
    session.printText = print ? print.textContent : ""
    session.viewHtml = view ? view.innerHTML : ""
    session.viewHidden = view ? view.classList.contains("hidden") : true

    const canvas = view && view.querySelector("canvas[data-app-canvas]")
    if (canvas) session.frame = copyCanvas(canvas)
  },

  _restore(session) {
    const status = this.el.querySelector("#app-status")
    const print = this.el.querySelector("#app-print")
    const view = this.el.querySelector("#app-view")

    if (status) status.textContent = session.statusText || ""
    if (print) {
      print.textContent = session.printText || ""
      print.scrollTop = print.scrollHeight
    }
    if (view) {
      // The tree comes back as the markup the pane had — it was built here
      // from the module's own view, so the only text in it is text nodes
      // and the serialization keeps them escaped. The canvas inside it is
      // an empty element at this point: its pixels were snapshotted
      // separately and are blitted back below.
      view.innerHTML = session.viewHtml || ""
      if (session.viewHidden || !session.viewHtml) view.classList.add("hidden")
      else view.classList.remove("hidden")

      const canvas = view.querySelector("canvas[data-app-canvas]")
      if (canvas && session.frame) {
        try {
          const context = canvas.getContext("2d")
          if (context) context.drawImage(session.frame, 0, 0)
        } catch (_) {
          // A frame the browser will not draw back leaves the module's own
          // redraw (or the blank canvas) rather than failing the resume.
        }
      }
    }
  },

  _clearPane() {
    const status = this.el.querySelector("#app-status")
    const print = this.el.querySelector("#app-print")
    const view = this.el.querySelector("#app-view")
    if (status) status.textContent = "No module loaded."
    if (print) print.textContent = ""
    if (view) {
      view.textContent = ""
      view.classList.add("hidden")
    }
  },

  // A run gets a fresh session: strikes, the stopped flag and the sinks all
  // belong to one attempt at running a module, so re-running has to build
  // them again rather than resuming a loop that already gave up. The pane's
  // own rows are cleared the same way a fresh run always cleared them —
  // this is the playground's path, where there is one session and no lease
  // to transfer.
  _run(payload) {
    this._teardownSession(this._session)
    this._stopAnimate()
    if (this._traceTimer !== null) clearTimeout(this._traceTimer)
    this._traceTimer = null
    this._trace = []

    this._evict()
    const session = this._newSession(this._activeKey)
    this._remember(session)
    this._session = session
    session.gate = payload.gate === true
    if (session.gate) this.pushEvent("app-run-start", {})

    const status = this.el.querySelector("#app-status")
    const print = this.el.querySelector("#app-print")
    const view = this.el.querySelector("#app-view")
    print.textContent = ""
    view.textContent = ""
    view.classList.add("hidden")

    if (payload.error) {
      this._refuseGate(session, payload.error)
      session.loop.sinks.status(payload.status || `could not compile (${payload.error})`)
      return
    }

    status.textContent = "starting…"
    if (payload.bytes) this._spawn(session, payload.bytes)
    else if (payload.wasm) this._spawn(session, fromBase64(payload.wasm))
    else if (payload.src) this._load(session, payload.src)
    else session.loop.sinks.status("nothing to run")
  },

  // A foreign module, from the rail's picker or from a drop on the pane.
  // The bytes never leave the browser: what is being gated is whether *this*
  // webview can instantiate them and get a first tick back, which is the
  // only evidence a peer running a different webview would give us anyway.
  async _dropin(blob) {
    if (!blob || typeof blob.arrayBuffer !== "function") {
      this._run({gate: true, error: "no file", status: "nothing to run"})
      return
    }

    if (blob.size > MAX_WASM_BYTES) {
      const limit = `${MAX_WASM_BYTES / (1024 * 1024)} MB`
      this._run({
        gate: true,
        error: `larger than the ${limit} drop-in limit`,
        status: `the file is larger than the ${limit} drop-in limit`
      })
      return
    }

    const bytes = new Uint8Array(await blob.arrayBuffer())
    if (!isWasm(bytes)) {
      this._run({
        gate: true,
        error: "the file is not a wasm module",
        status: "the file is not a wasm module"
      })
      return
    }

    this._run({gate: true, bytes})
  },

  // The gate speaks exactly once. A refusal from a stop (the module did not
  // load, the deadline expired, it was stopped) or from one of the checks
  // above ends it one way; the verdict after the first tick ends it the
  // other. `gate` is the session's only flag, so no run can be gated twice.
  _refuseGate(session, reason) {
    if (!session.gate) return
    session.gate = false
    this._record("gate", `refused (${reason})`)
  },

  // The verdict comes after the first tick's effects have been applied, so
  // the module has had its chance to show what it is. Refusing is not only a
  // record: a file that did not pass the gate does not keep running here, so
  // the loop is stopped on the spot and the stop sink records the run's end
  // the way it does for any other stop. `gate` is already closed by then,
  // so that sink finds the gate silent and it still speaks exactly once.
  _gateVerdict(session) {
    if (!session.gate) return
    session.gate = false
    if (session.loop.strikes > 0 || session.loop.stopped) {
      const reason = "refused (the first tick did not follow the ABI)"
      this._record("gate", reason)
      session.loop.stop(reason)
    } else {
      this._record("gate", "instantiate + first tick ok")
    }
  },

  async _load(session, src) {
    session.loop.sinks.status("loading module…")
    this._arm(session)
    try {
      const response = await fetch(src)
      if (!response.ok) throw new Error(`the server answered ${response.status}`)
      const wasm = await response.arrayBuffer()
      // The lease may have moved on while the bytes were coming — a session
      // parked with no worker is dropped rather than kept, and one that was
      // dropped mid-fetch must not spawn into a map that no longer holds it.
      if (session.removed || session.loop.stopped) return
      this._spawn(session, wasm)
    } catch (error) {
      if (!session.removed) {
        session.loop.stop(`the module could not be loaded (${error.message})`)
      }
    }
  },

  _spawn(session, wasm) {
    const worker = this.el.dataset.workerSrc
    session.worker = new Worker(worker)
    session.worker.onmessage = event => this._onWorker(session, event.data)
    session.worker.onerror = event => {
      if (!session.removed) session.loop.stop(`the worker failed (${event.message})`)
    }
    this._arm(session)
    // The transfer list takes buffers, not views: a module that arrived as
    // base64 is a Uint8Array, and only its buffer can move to the worker.
    const bytes = wasm instanceof Uint8Array ? wasm : new Uint8Array(wasm)
    session.worker.postMessage({type: "start", wasm: bytes}, [bytes.buffer])
  },

  async _onWorker(session, message) {
    if (!message || session.removed) return
    switch (message.type) {
      case "ready":
        this._disarm(session)
        session.ready = true
        session.loop.sinks.status("running")
        this._deliver(session, {msg: "init"})
        break
      case "effects":
        // The worker is free the moment it posts the answer, so the next
        // tick or queued pointer event may go out while this delivery's
        // effects are still being applied — the loop queues those behind
        // the array it is working on, which is what keeps two deliveries
        // from interleaving (§3).
        this._disarm(session)
        session.inFlight = false
        // The gate is judged on the first tick *after* its effects have been
        // applied: a module that instantiates and then hands back junk has
        // instantiated, but it has not passed. A stop during that run speaks
        // first, so the verdict below finds the gate already closed.
        await session.loop.effects(message.bytes)
        this._flushUi(session)
        this._flushEntries(session)
        this._gateVerdict(session)
        break
      case "error":
        session.inFlight = false
        session.loop.stop(`the module failed (${message.message})`)
        break
      default:
        session.loop.stop("the worker sent something unexpected")
    }
  },

  async _deliver(session, message) {
    // A parked session holds no deliveries: its worker waits for `resume`
    // (or `blur`, delivered while parking) and nothing else (§3).
    if (
      session.removed ||
      session.state === "parked" ||
      session.loop.stopped ||
      !session.worker
    ) {
      return
    }
    const bytes = encode(message)
    this._arm(session)
    session.inFlight = true
    session.worker.postMessage({type: "deliver", bytes}, [bytes.buffer])
  },

  async _want(session, op, args) {
    if (session.loop.stopped || !session.worker) {
      throw new Error("no module is running")
    }
    if (!isMap(args)) throw new Error("the arguments are not a map")
    this._arm(session)
    // The pane belongs to a component, so the call has to name it. An
    // untargeted pushEvent lands on the root LiveView, which has no
    // app-want clause, and the reply never comes back. pushEventTo
    // answers with one settled result per target, so the reply is
    // unpacked here rather than handed to the loop.
    const results = await this.pushEventTo(this.el, "app-want", {
      op,
      args: toBase64(encode(args))
    })
    const first = results && results[0]
    if (!first || first.status !== "fulfilled" || !first.value) {
      throw new Error("the app view did not answer")
    }
    return first.value.reply
  },

  // One publish, one round trip. The entry goes up as base64(CBOR(entry))
  // for the same reason a want's arguments do — LiveView carries JSON, and
  // neither bytes nor arbitrary terms survive it — and the reply is handed
  // straight back to the loop, which turns a refusal into a strike.
  //
  // The deadline armed here covers a component that never answers. Unlike a
  // `want`, a publish has no reply to deliver to the module afterwards, so
  // it is disarmed on the way out: nothing is in flight once the host has
  // answered, and a timer left running would stop an idle run rather than a
  // late one.
  async _publish(session, entry) {
    if (session.loop.stopped || !session.worker) {
      throw new Error("no module is running")
    }
    this._arm(session)
    try {
      const results = await this.pushEventTo(this.el, "app-publish", {
        entry: toBase64(encode(entry))
      })
      const first = results && results[0]
      if (!first || first.status !== "fulfilled" || !first.value) {
        throw new Error("the app view did not answer")
      }
      const reply = first.value.reply
      this._record("publish", publishShape(reply))
      return reply
    } finally {
      this._disarm(session)
    }
  },

  // One entry of the run's own history. Batching keeps a module that prints
  // in a loop from turning into one socket message per line: the trace is a
  // list to read back, not a log tail that has to be live. Only panes that
  // asked for a trace get one — a published app's pane has nowhere to show
  // it and would only be pushing state nobody reads.
  _record(kind, detail) {
    if (!this.el.dataset.trace) return
    if (this._trace.length >= TRACE_LIMIT) this._trace.shift()
    this._trace.push({kind, detail: String(detail).slice(0, TRACE_DETAIL_LIMIT)})
    if (this._traceTimer !== null) return
    this._traceTimer = setTimeout(() => this._flushTrace(), TRACE_FLUSH_MS)
  },

  _flushTrace() {
    this._traceTimer = null
    if (this._trace.length === 0) return
    const entries = this._trace
    this._trace = []
    this.pushEvent("app-trace", {entries})
  },

  _arm(session) {
    this._disarm(session)
    session.timer = setTimeout(() => {
      if (!session.removed) session.loop.stop("the app took too long")
    }, DEADLINE_MS)
  },

  _disarm(session) {
    if (session.timer !== null) clearTimeout(session.timer)
    session.timer = null
  },

  _teardownSession(session) {
    if (!session || session.removed) return
    session.removed = true
    session.state = "stopped"
    this._disarm(session)
    if (session === this._session) this._stopAnimate()
    if (session.worker) {
      session.worker.terminate()
      session.worker = null
    }
    this._sessions.delete(session.key)
  },

  // `{"do":"animate"}` turns the pane's frame clock on; `on: false` turns
  // it off. Each frame delivers one `{"msg":"tick","t":…}` — and only when
  // the previous delivery has been answered, so a module that takes 100 ms
  // a frame ticks ten a second rather than building a queue of sixteen
  // millisecond promises it has not kept. Skipping the frame *is* the
  // budget: the deadline armed in `_deliver` is what stops a module that
  // never answers at all. The clock is the lease holder's alone — a parked
  // session's rAF stops when the lease leaves it (§3).
  _startAnimate() {
    if (this._animateOn) return
    this._animateOn = true
    const frame = time => {
      if (!this._animateOn) return
      const session = this._session
      if (
        session &&
        session.state === "running" &&
        !session.inFlight &&
        session.worker &&
        session.loop &&
        !session.loop.stopped
      ) {
        this._deliver(session, {msg: "tick", t: time})
      }
      this._raf = requestAnimationFrame(frame)
    }
    this._raf = requestAnimationFrame(frame)
  },

  _stopAnimate() {
    this._animateOn = false
    if (this._raf !== null) cancelAnimationFrame(this._raf)
    this._raf = null
  },

  // Pointer events over the view's canvas, delegated from the pane. The
  // coordinates are the module's own — canvas pixels, origin at its top
  // left — because the module owns the geometry and does the hit-testing
  // (§3). A capture on the way down keeps the matching `up` arriving even
  // when the pointer leaves the region mid-drag. Only the lease holder has
  // a canvas in the pane, so a parked app never sees a pointer event.
  _pointer(event) {
    const target = event.target
    if (!(target instanceof Element)) return
    const canvas = target.closest("canvas[data-app-canvas]")
    if (!canvas) return

    const type = {pointerdown: "down", pointermove: "move", pointerup: "up"}[event.type]
    if (!type) return

    if (type === "down") {
      try {
        canvas.setPointerCapture(event.pointerId)
      } catch (_) {
        // A capture is a convenience; without one the `up` simply does
        // not arrive if the pointer has left, which is the old behaviour.
      }
    }

    const entry = {type, x: Math.round(event.offsetX), y: Math.round(event.offsetY)}
    if (type !== "move") entry.button = event.button
    this._queueUi(entry)
  },

  // One message to the module at a time, newest sample wins for a move.
  _queueUi(entry) {
    const session = this._session
    if (!session || session.state !== "running") return
    const queue = session.ui
    const last = queue[queue.length - 1]
    if (entry.type === "move" && last && last.type === "move") {
      queue[queue.length - 1] = entry
    } else {
      queue.push(entry)
    }
    if (queue.length > UI_QUEUE_LIMIT) queue.shift()
    this._flushUi(session)
  },

  _flushUi(session) {
    if (session.state !== "running" || session.inFlight || session.ui.length === 0) return
    if (!session.worker || session.loop.stopped) {
      session.ui = []
      return
    }
    this._deliver(session, {msg: "ui", event: session.ui.shift()})
  },

  // One `app-entry` push from the LiveView: a log this pane watches just
  // moved. Entries wait in their own queue rather than being delivered
  // straight away so that a pointer event the module is still answering for
  // is not interrupted — the same one-delivery-at-a-time rule, in the same
  // place the UI queue obeys it. The push belongs to the lease holder (the
  // LiveView clears the baselines it polls from on every switch), and a
  // session that is parking holds what arrives until it holds the lease
  // again, marking itself for the `queue_overflow` message if the cap
  // pushed anything out while it waited (§3).
  _queueEntry(entry) {
    const session = this._session
    if (!session || session.removed) return
    session.entries.push({
      msg: "entry",
      author: entry.author,
      log_id: entry.log_id,
      seq: entry.seq
    })
    if (session.entries.length > ENTRY_QUEUE_LIMIT) {
      session.entries.shift()
      if (session.state !== "running") session.overflowed = true
    }
    this._flushEntries(session)
  },

  _flushEntries(session) {
    if (session.state !== "running" || session.inFlight || session.entries.length === 0) return
    if (!session.worker || session.loop.stopped) {
      session.entries = []
      return
    }
    const entry = session.entries.shift()
    if (entry.msg === "queue_overflow") {
      this._record("entry", "queue_overflow")
    } else {
      this._record("entry", `${entry.author}#${entry.log_id}:${entry.seq}`)
    }
    this._deliver(session, entry)
  }
}

function appendPrint(current, text) {
  const next = current ? `${current}\n${text}` : text
  return next.length > PRINT_LIMIT ? next.slice(next.length - PRINT_LIMIT) : next
}

// The canvas's pixels, copied to a canvas of its own: what a parked session
// keeps of its drawing, blitted back on resume (§3).
function copyCanvas(canvas) {
  const copy = document.createElement("canvas")
  copy.width = canvas.width
  copy.height = canvas.height
  const context = copy.getContext("2d")
  if (context) context.drawImage(canvas, 0, 0)
  return copy
}

function nap(ms) {
  return new Promise(resolve => setTimeout(resolve, ms))
}

// The wasm header: a NUL, then "asm", then a format version that is at least
// another four bytes. Checked before a drop-in is spawned so a text file
// dropped by mistake is a message in the pane rather than a link error out
// of the worker.
function isWasm(bytes) {
  return (
    bytes.length >= 8 &&
    bytes[0] === 0x00 &&
    bytes[1] === 0x61 &&
    bytes[2] === 0x73 &&
    bytes[3] === 0x6d
  )
}

function viewShape(value) {
  if (value === null || typeof value !== "object") return "value"
  if (typeof value.t === "string") return value.t
  if (typeof value.text === "string") return "text dump"
  return "value"
}

function replyShape(message) {
  if (!message) return "nothing"
  if (message.msg === "err") return `err ${message.error}`
  return `data #${message.ref}`
}

// One publish reads in the trace as what it wrote and where: the seqnum the
// store gave it, or the reason the host would not.
function publishShape(reply) {
  if (!reply || reply.ok !== true) {
    return `refused (${(reply && reply.error) || "no reason given"})`
  }
  return typeof reply.seq === "number" ? `ok, seq ${reply.seq}` : "ok"
}

function toBase64(bytes) {
  let binary = ""
  for (let i = 0; i < bytes.length; i += 0x8000) {
    binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000))
  }
  return btoa(binary)
}
