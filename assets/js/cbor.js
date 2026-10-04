// Hand-written CBOR (RFC 8949) codec for the app ABI.
//
// Not vendored: both ends of the ABI have to agree exactly with what the
// Elixir `cbor` package emits — a host reply is decoded here and an effect's
// `args` is encoded here and decoded there — so the two shapes are cross-
// checked against each other rather than trusted to a third party's defaults.
// The surface is deliberately small: bytes, text, ints, floats, bools, null,
// arrays and maps. Anything else on decode is refused with a message rather
// than guessed at, and a decode is rejected outright if it does not consume
// its input.

// Text decoding is deliberately lossy rather than fatal: the Elixir side
// does not validate UTF-8 either (a CBOR text string decodes to whatever
// bytes it holds), so a byte the host would have accepted must not be able
// to knock an app over. Structure is still validated — a declared length
// that runs off the end of the input is an error, only UTF-8 is forgiven.
const textEncoder = new TextEncoder()
const textDecoder = new TextDecoder("utf-8")

// Every length and integer argument stays inside the double range: CBOR's
// 64-bit integers are reachable in principle, but a value that large is not
// a safe integer and takes the float64 path instead. That is what keeps
// BigInt — an ES2020 literal, and therefore a parse error for anything the
// es2016 bundle target still promises to run — out of this file entirely.

function fail(message) {
  throw new Error(`cbor: ${message}`)
}

// Growable output buffer.
class Out {
  constructor() {
    this.buf = new Uint8Array(64)
    this.len = 0
  }

  #grow(needed) {
    if (this.len + needed <= this.buf.length) return
    let cap = this.buf.length
    while (cap < this.len + needed) cap *= 2
    const next = new Uint8Array(cap)
    next.set(this.buf.subarray(0, this.len))
    this.buf = next
  }

  byte(b) {
    this.#grow(1)
    this.buf[this.len++] = b
  }

  raw(bytes) {
    this.#grow(bytes.length)
    this.buf.set(bytes, this.len)
    this.len += bytes.length
  }

  // Major 7's additional information is never a length — 24..27 name the
  // simple values and the float widths — so it cannot go through head/2.
  ai(major, value) {
    this.byte((major << 5) | value)
  }

  head(major, arg) {
    if (!Number.isSafeInteger(arg) || arg < 0) fail(`argument out of range: ${arg}`)
    const prefix = major << 5
    if (arg < 24) {
      this.byte(prefix | arg)
    } else if (arg < 0x100) {
      this.byte(prefix | 24)
      this.byte(arg)
    } else if (arg < 0x10000) {
      this.byte(prefix | 25)
      this.byte(arg >>> 8)
      this.byte(arg & 0xff)
    } else if (arg <= 0xffffffff) {
      this.byte(prefix | 26)
      this.byte((arg >>> 24) & 0xff)
      this.byte((arg >>> 16) & 0xff)
      this.byte((arg >>> 8) & 0xff)
      this.byte(arg & 0xff)
    } else {
      // The bitwise operators truncate to 32 bits, so the high half has to
      // be divided out before it can be written byte by byte.
      this.byte(prefix | 27)
      const high = Math.floor(arg / 0x100000000)
      const low = arg - high * 0x100000000
      this.#word(high)
      this.#word(low)
    }
  }

  #word(value) {
    this.byte((value >>> 24) & 0xff)
    this.byte((value >>> 16) & 0xff)
    this.byte((value >>> 8) & 0xff)
    this.byte(value & 0xff)
  }

  slice() {
    return this.buf.slice(0, this.len)
  }
}

function encodeNumber(out, value) {
  if (Number.isSafeInteger(value)) {
    if (value >= 0) out.head(0, value)
    else out.head(1, -1 - value)
    return
  }
  // Not an integer, or too large to be one losslessly: CBOR has a float64
  // for exactly this. NaN and the infinities ride along here too.
  out.ai(7, 27)
  const view = new DataView(new ArrayBuffer(8))
  view.setFloat64(0, value)
  for (let i = 0; i < 8; i++) out.byte(view.getUint8(i))
}

function encodeBytes(out, bytes) {
  out.head(2, bytes.byteLength)
  out.raw(new Uint8Array(bytes.buffer ?? bytes, bytes.byteOffset ?? 0, bytes.byteLength))
}

function write(out, value) {
  switch (typeof value) {
    case "boolean":
      out.ai(7, value ? 21 : 20)
      return
    case "number":
      encodeNumber(out, value)
      return
    case "string": {
      const bytes = textEncoder.encode(value)
      out.head(3, bytes.length)
      out.raw(bytes)
      return
    }
    case "undefined":
      out.ai(7, 22)
      return
    case "object":
      break
    default:
      fail(`cannot encode ${typeof value}`)
  }

  if (value === null) {
    out.ai(7, 22)
  } else if (value instanceof Uint8Array || value instanceof ArrayBuffer) {
    encodeBytes(out, value)
  } else if (Array.isArray(value)) {
    out.head(4, value.length)
    for (const item of value) write(out, item)
  } else if (value instanceof Map) {
    out.head(5, value.size)
    for (const [key, item] of value) {
      // Keys decoded from a host reply keep whatever type they arrived with,
      // so an integer-keyed map has to survive being handed back.
      if (typeof key === "string") write(out, key)
      else if (typeof key === "number") encodeNumber(out, key)
      else fail(`map key of type ${typeof key} cannot be encoded`)
      write(out, item)
    }
  } else if (typeof value === "object") {
    const keys = Object.keys(value)
    out.head(5, keys.length)
    for (const key of keys) {
      write(out, key)
      write(out, value[key])
    }
  } else {
    fail(`cannot encode ${Object.prototype.toString.call(value)}`)
  }
}

export function encode(value) {
  const out = new Out()
  write(out, value)
  return out.slice()
}

class Reader {
  constructor(buf) {
    this.buf = buf
    this.pos = 0
  }

  u8() {
    if (this.pos >= this.buf.length) fail("input ended early")
    return this.buf[this.pos++]
  }

  take(count) {
    if (!Number.isSafeInteger(count) || count < 0) fail(`length out of range: ${count}`)
    if (this.pos + count > this.buf.length) fail("input ended early")
    const slice = this.buf.subarray(this.pos, this.pos + count)
    this.pos += count
    return slice
  }

  // Returns the argument of a length/major head as a Number, or null for
  // the indefinite-length marker (ai 31). The 64-bit form can hold a value
  // no double represents exactly; anything that large fails the bounds
  // check against the input anyway, so the precision is not needed.
  length(ai) {
    if (ai < 24) return ai
    if (ai === 24) return this.u8()
    if (ai === 25) {
      const b = this.take(2)
      return (b[0] << 8) | b[1]
    }
    if (ai === 26) {
      const b = this.take(4)
      return ((b[0] << 24) >>> 0) + (b[1] << 16) + (b[2] << 8) + b[3]
    }
    if (ai === 27) {
      const b = this.take(8)
      const view = new DataView(b.buffer, b.byteOffset, b.byteLength)
      return view.getUint32(0) * 0x100000000 + view.getUint32(4)
    }
    if (ai === 31) return null
    fail(`reserved additional information: ${ai}`)
  }

  indefiniteChunks(concat) {
    const parts = []
    for (;;) {
      const ib = this.u8()
      if (ib === 0xff) break
      if (ib >> 5 !== concat.major) fail("indefinite chunk of mixed type")
      const ai = ib & 0x1f
      const len = this.length(ai)
      if (len === null) fail("nested indefinite length")
      parts.push(this.take(Number(len)))
    }
    if (parts.length === 0) return concat.empty
    const total = parts.reduce((sum, part) => sum + part.length, 0)
    const merged = new Uint8Array(total)
    let offset = 0
    for (const part of parts) {
      merged.set(part, offset)
      offset += part.length
    }
    return merged
  }

  float(ai, bytes) {
    const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength)
    if (ai === 25) {
      const half = view.getUint16(0)
      const sign = half & 0x8000 ? -1 : 1
      const exponent = (half & 0x7c00) >> 10
      const fraction = half & 0x03ff
      if (exponent === 0) return sign * fraction * 2 ** -24
      if (exponent === 0x1f) return fraction ? NaN : sign * Infinity
      return sign * (1 + fraction / 1024) * 2 ** (exponent - 15)
    }
    if (ai === 26) return view.getFloat32(0)
    if (ai === 27) return view.getFloat64(0)
    if (ai === 24) fail(`unsupported simple value: ${this.take(1)[0]}`)
    fail(`not a float: ai ${ai}`)
  }

  value() {
    const ib = this.u8()
    const major = ib >> 5
    const ai = ib & 0x1f

    switch (major) {
      case 0:
        return this.#arg(ai)
      case 1:
        return -1 - this.#arg(ai)
      case 2: {
        if (ai === 31) return this.indefiniteChunks({major: 2, empty: new Uint8Array(0)})
        return this.take(this.#arg(ai))
      }
      case 3: {
        let bytes
        if (ai === 31) bytes = this.indefiniteChunks({major: 3, empty: new Uint8Array(0)})
        else bytes = this.take(this.#arg(ai))
        return textDecoder.decode(bytes)
      }
      case 4: {
        const items = []
        if (ai === 31) {
          for (;;) {
            if (this.buf[this.pos] === 0xff) {
              this.pos++
              break
            }
            items.push(this.value())
          }
        } else {
          const count = this.#arg(ai)
          for (let i = 0; i < count; i++) items.push(this.value())
        }
        return items
      }
      case 5: {
        const entries = []
        if (ai === 31) {
          for (;;) {
            if (this.buf[this.pos] === 0xff) {
              this.pos++
              break
            }
            entries.push([this.value(), this.value()])
          }
        } else {
          const count = Number(this.#arg(ai))
          for (let i = 0; i < count; i++) entries.push([this.value(), this.value()])
        }
        // Text keys become a plain object, which is what an effect decoded
        // from our own encoder always is. Anything else keeps its key types
        // in a Map rather than having them stringified into collisions.
        if (entries.every(([key]) => typeof key === "string")) {
          const object = {}
          for (const [key, item] of entries) object[key] = item
          return object
        }
        return new Map(entries)
      }
      case 6: {
        this.#arg(ai)
        return this.value()
      }
      case 7:
        if (ai === 20) return false
        if (ai === 21) return true
        if (ai === 22) return null
        if (ai === 23) return undefined
        if (ai === 31) fail("unexpected break marker")
        if (ai === 25 || ai === 26 || ai === 27) {
          const width = ai === 25 ? 2 : ai === 26 ? 4 : 8
          return this.float(ai, this.take(width))
        }
        if (ai === 24) fail(`unsupported simple value: ${this.u8()}`)
        fail(`reserved additional information: ${ai}`)
      default:
        fail(`unknown major type: ${major}`)
    }
  }

  #arg(ai) {
    const arg = this.length(ai)
    if (arg === null) fail("indefinite length where a length was required")
    return arg
  }
}

export function decode(input) {
  let buf
  if (input instanceof Uint8Array) buf = input
  else if (input instanceof ArrayBuffer) buf = new Uint8Array(input)
  else if (ArrayBuffer.isView(input)) buf = new Uint8Array(input.buffer, input.byteOffset, input.byteLength)
  else fail(`cannot decode ${typeof input}`)

  const reader = new Reader(buf)
  const value = reader.value()
  if (reader.pos !== buf.length) fail(`${buf.length - reader.pos} trailing byte(s)`)
  return value
}
