// Canvas tier 1: `{"do":"draw","ops":[...]}`, replayed onto the canvas in
// the app view (§3). Immediate-mode — each effect resets the transform,
// clears the region and replays what it carries, so a module redraws its
// whole frame per tick and nothing drawn in one effect reaches the next.
//
// Validation is pure — no canvas, no context, no DOM — for the reason
// `checkView` is: the rules are checkable anywhere, and the pane shows a
// reason rather than a half-drawn frame. The caps mirror the view's:
// 2000 ops, 64 KiB of text, 4096 points across the paths in one effect,
// all bounded long before the 1 MiB cap on the effect array that carried
// them.
//
// The vocabulary is fixed and small — rectangles, a line, a path, text
// and two transforms — because everything else rides the message loop
// rather than the op list: images arrive from the store as their own
// message, and animation as `tick`s, neither of which fits in a list of
// draw commands.

export const MAX_OPS = 2000
export const MAX_DRAW_TEXT_BYTES = 64 * 1024
export const MAX_POINTS = 4096

// Slate, which is what the canvas border already is in both schemes: an op
// that does not name a colour still draws something a reader can see.
const DEFAULT_COLOR = "#64748b"
const DEFAULT_SIZE = 16

const encoder = new TextEncoder()

// `null` when the ops replay, otherwise the reason they do not.
export function checkDraw(ops) {
  if (!Array.isArray(ops)) return "a draw effect with no list of ops"
  if (ops.length > MAX_OPS) return `a draw with more than ${MAX_OPS} ops`

  let points = 0
  let text = 0

  for (const op of ops) {
    if (op === null || typeof op !== "object" || Array.isArray(op)) {
      return "a draw op that is not a map"
    }
    if (typeof op.op !== "string") {
      return "a draw op that does not name an operation"
    }

    switch (op.op) {
      case "fill_rect":
        if (!rect(op)) return "a draw op with an unusable rectangle"
        if (!goodColour(op.c)) return "a draw op with an unusable colour"
        break

      case "stroke_rect":
        if (!rect(op)) return "a draw op with an unusable rectangle"
        if (!width(op.lw)) return "a draw op with an unusable line width"
        if (!goodColour(op.c)) return "a draw op with an unusable colour"
        break

      case "line":
        if (!pair(op.x1, op.y1) || !pair(op.x2, op.y2)) {
          return "a draw op with an unusable coordinate"
        }
        if (!width(op.lw)) return "a draw op with an unusable line width"
        if (!goodColour(op.c)) return "a draw op with an unusable colour"
        break

      case "stroke_path":
      case "fill_path": {
        if (!Array.isArray(op.pts) || op.pts.length === 0) {
          return "a path draw op with no points"
        }
        points += op.pts.length
        if (points > MAX_POINTS) return `a draw with more than ${MAX_POINTS} points`
        for (const point of op.pts) {
          if (!Array.isArray(point) || !pair(point[0], point[1])) {
            return "a path point that is not a pair of numbers"
          }
        }
        if (op.op === "stroke_path" && !width(op.lw)) {
          return "a draw op with an unusable line width"
        }
        if (!goodColour(op.c)) return "a draw op with an unusable colour"
        break
      }

      case "text": {
        const {s} = op
        if (typeof s !== "string" && typeof s !== "number" && typeof s !== "boolean") {
          return "a text draw op with no text"
        }
        text += encoder.encode(String(s)).length
        if (text > MAX_DRAW_TEXT_BYTES) {
          return `a draw with more than ${MAX_DRAW_TEXT_BYTES} bytes of text`
        }
        if (!pair(op.x, op.y)) return "a draw op with an unusable coordinate"
        if (op.size !== undefined && !size(op.size)) {
          return "a text draw op with an unusable size"
        }
        if (!goodColour(op.c)) return "a draw op with an unusable colour"
        break
      }

      case "translate":
      case "scale":
        if (!pair(op.x, op.y)) return "a draw op with an unusable coordinate"
        break

      default:
        return `an unknown draw op: ${op.op}`
    }
  }

  return null
}

// Replay. Callers run `checkDraw` first; `applyDraw` returns a reason only
// for the one thing validation cannot see — a canvas without a 2D
// context — and lets a context that refuses an op surface as a thrown
// error, which is how a browser's own limits report.
export function applyDraw(canvas, ops) {
  const ctx = canvas.getContext("2d")
  if (!ctx) return "the canvas has no 2D drawing context"

  ctx.setTransform(1, 0, 0, 1, 0, 0)
  ctx.clearRect(0, 0, canvas.width, canvas.height)

  for (const op of ops) runOp(ctx, op)
  return null
}

function runOp(ctx, op) {
  const c = op.c === undefined ? DEFAULT_COLOR : op.c

  switch (op.op) {
    case "fill_rect":
      ctx.fillStyle = c
      ctx.fillRect(op.x, op.y, op.w, op.h)
      break

    case "stroke_rect":
      ctx.strokeStyle = c
      if (op.lw !== undefined) ctx.lineWidth = op.lw
      ctx.strokeRect(op.x, op.y, op.w, op.h)
      break

    case "line":
      ctx.strokeStyle = c
      if (op.lw !== undefined) ctx.lineWidth = op.lw
      ctx.beginPath()
      ctx.moveTo(op.x1, op.y1)
      ctx.lineTo(op.x2, op.y2)
      ctx.stroke()
      break

    case "stroke_path":
      tracePath(ctx, op)
      ctx.strokeStyle = c
      if (op.lw !== undefined) ctx.lineWidth = op.lw
      ctx.stroke()
      break

    case "fill_path":
      tracePath(ctx, op)
      ctx.fillStyle = c
      ctx.fill()
      break

    case "text":
      ctx.fillStyle = c
      ctx.font = `${op.size === undefined ? DEFAULT_SIZE : op.size}px system-ui, sans-serif`
      ctx.fillText(String(op.s), op.x, op.y)
      break

    case "translate":
      ctx.translate(op.x, op.y)
      break

    case "scale":
      ctx.scale(op.x, op.y)
      break
  }
}

function tracePath(ctx, op) {
  ctx.beginPath()
  ctx.moveTo(op.pts[0][0], op.pts[0][1])
  for (const [x, y] of op.pts.slice(1)) ctx.lineTo(x, y)
  if (op.close === true) ctx.closePath()
}

function rect(op) {
  return pair(op.x, op.y) && pair(op.w, op.h)
}

function pair(x, y) {
  return num(x) && num(y)
}

function num(value) {
  return Number.isFinite(value)
}

function width(lw) {
  return lw === undefined || (num(lw) && lw >= 0)
}

function size(value) {
  return num(value) && value >= 1 && value <= 1024
}

// Absent is fine — the replay substitutes the default — and present means
// a non-empty string, so an empty or numeric colour is a reason rather
// than a context assignment the browser silently ignores.
function goodColour(c) {
  return c === undefined || (typeof c === "string" && c.length > 0)
}
