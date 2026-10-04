// The view-model renderer: the value a module sent with `render`, made
// into DOM without the browser ever being asked to parse markup.
//
// The vocabulary is fixed — `text`, `col`, `row`, `canvas` — and every
// string in it reaches the page through `textContent`, so a view cannot
// carry markup however it is written (§11.6). Three outcomes, and only
// three:
//
//   * a value that is not a node is not a mistake: the ABI lets `render`
//     carry any CBOR value, so it falls back to the text dump step 3
//     used, silently, which is what keeps a module written before this
//     renderer still showing something;
//   * a tree that fails validation is struck once and shown as that same
//     dump — a module gets told, and never sees a half-built view;
//   * a tree that passes is built node by node.
//
// Caps are here rather than in the loop because they are properties of
// the view: 2000 nodes, 64 KiB of text (the print log's ceiling), 64
// levels deep. The 1 MiB cap on the effect array that carried the view
// bounds all of it before anything is counted.

export const MAX_NODES = 2000
export const MAX_TEXT_BYTES = 64 * 1024
export const MAX_DEPTH = 64

const MAX_WIDGET_SIZE = 4096
const encoder = new TextEncoder()

// A node claims to be one by carrying a text `t`; whether that name is in
// the vocabulary is `checkView`'s business, so an unknown widget is
// reported rather than mistaken for a plain value.
function isNode(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value) &&
    typeof value.t === "string"
}

// `null` when the value renders as a tree, otherwise the reason it does
// not. Pure — no DOM — so the rules are checkable anywhere.
export function checkView(value) {
  if (!isNode(value)) return null
  return checkNode(value, {nodes: 0, text: 0}, 1)
}

// Build the view. `strike` is present exactly when the tree failed
// validation, in which case `node` is the text dump instead: the caller
// counts the strike and shows whatever came back.
export function buildView(value) {
  const problem = checkView(value)

  if (problem) return {node: textNode(dump(value)), strike: problem}
  if (!isNode(value)) return {node: textNode(dump(value))}
  return {node: toElement(value)}
}

function checkNode(node, budget, depth) {
  if (++budget.nodes > MAX_NODES) {
    return `a view with more than ${MAX_NODES} widgets`
  }
  if (depth > MAX_DEPTH) {
    return `a view nested deeper than ${MAX_DEPTH}`
  }

  switch (node.t) {
    case "text": {
      const {s} = node
      if (typeof s !== "string" && typeof s !== "number" && typeof s !== "boolean") {
        return "a text widget with no text"
      }
      budget.text += encoder.encode(String(s)).length
      if (budget.text > MAX_TEXT_BYTES) {
        return `a view with more than ${MAX_TEXT_BYTES} bytes of text`
      }
      return null
    }

    case "col":
    case "row": {
      if (!Array.isArray(node.kids)) {
        return `a ${node.t} widget with no children`
      }
      for (const kid of node.kids) {
        if (!isNode(kid)) return "a child that is not a view widget"
        const problem = checkNode(kid, budget, depth + 1)
        if (problem) return problem
      }
      return null
    }

    case "canvas": {
      if (!size(node.w) || !size(node.h)) {
        return "a canvas widget without a usable size"
      }
      return null
    }

    default:
      return `an unknown widget: ${node.t}`
  }
}

function size(value) {
  return Number.isSafeInteger(value) && value >= 1 && value <= MAX_WIDGET_SIZE
}

// No innerHTML, no insertAdjacentHTML: elements are created and children
// are appended, so the only way text gets onto the page is as a text node.
function toElement(node) {
  switch (node.t) {
    case "text": {
      const el = document.createElement("span")
      el.textContent = String(node.s)
      return el
    }

    case "col": {
      const el = document.createElement("div")
      el.className = "flex flex-col gap-1"
      for (const kid of node.kids) el.appendChild(toElement(kid))
      return el
    }

    case "row": {
      const el = document.createElement("div")
      el.className = "flex flex-row flex-wrap items-center gap-2"
      for (const kid of node.kids) el.appendChild(toElement(kid))
      return el
    }

    case "canvas": {
      const el = document.createElement("canvas")
      el.width = node.w
      el.height = node.h
      // Reserved: tier 1 draw ops replay onto this context (§3).
      el.className = "rounded border border-slate-300 dark:border-slate-700"
      el.dataset.appCanvas = ""
      return el
    }
  }
}

function textNode(text) {
  return document.createTextNode(text)
}

function dump(value) {
  const text = viewText(value)
  if (text.length <= MAX_TEXT_BYTES) return text
  return `${text.slice(0, MAX_TEXT_BYTES)}\n… truncated`
}

// The text dump: a view that is not a widget tree, or one that failed
// validation, shown as data. Written with `createTextNode`, so nothing in
// it can be read as markup however it is written.
export function viewText(value, depth = 0) {
  const pad = "  ".repeat(depth)
  const inner = "  ".repeat(depth + 1)

  if (value === null || value === undefined) return "null"
  if (typeof value === "string") return JSON.stringify(value)
  if (typeof value === "number" || typeof value === "boolean") return String(value)
  if (value instanceof Uint8Array) return bytesText(value)

  if (Array.isArray(value)) {
    if (value.length === 0) return "[]"
    return `[\n${value.map(item => inner + viewText(item, depth + 1)).join(",\n")}\n${pad}]`
  }

  if (value instanceof Map) return viewText(new MapToObject(value), depth)

  if (typeof value === "object") {
    const keys = Object.keys(value)
    if (keys.length === 0) return "{}"
    const lines = keys.map(key => `${inner}${JSON.stringify(key)}: ${viewText(value[key], depth + 1)}`)
    return `{\n${lines.join(",\n")}\n${pad}}`
  }

  return String(value)
}

// A map whose keys were not all text decodes into a Map rather than an
// object; for a text dump it is enough to show it as one.
class MapToObject {
  constructor(map) {
    for (const [key, item] of map) this[String(key)] = item
  }
}

function bytesText(bytes) {
  if (bytes.length === 0) return "0x"
  const shown = Array.from(bytes.subarray(0, 32), byte =>
    byte.toString(16).padStart(2, "0")
  ).join("")
  const suffix = bytes.length > 32 ? ` … +${bytes.length - 32} more bytes` : ""
  return `0x${shown}${suffix}`
}
