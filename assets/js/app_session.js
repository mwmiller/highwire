// The wasm half of the ABI, in one place: hand a module a message, take
// back the effects it produced.
//
// Three rules are fixed here rather than negotiated per module, and a
// module written against them is what `HighWire.AppFixture` is:
//
//   * the module exports `memory` and `handle`;
//   * `handle(in_ptr, in_len)` returns a pointer, and leaves the length of
//     what it returned as a 32-bit little-endian integer at address 0;
//   * the message is written at `INPUT_BASE`, so a module's own data and
//     results live below that. `handle` must not overlap its input.
//
// Everything from `step` down is synchronous, which is what lets the main
// thread keep a deadline over it: a `handle` that never returns blocks this
// worker, and the worker is the thing that gets terminated.

export const LENGTH_SLOT = 0
export const INPUT_BASE = 0x1000

// A module may claim any length it likes in the first four bytes, so the
// claim is checked against its own memory before a byte is read. This is
// also the ceiling on how much CBOR gets handed to a decoder.
const MAX_RESULT_BYTES = 1 << 20

export async function openSession(wasmBytes) {
  const {instance} = await WebAssembly.instantiate(wasmBytes, {})
  const {memory, handle} = instance.exports

  if (!(memory instanceof WebAssembly.Memory)) {
    throw new Error("module does not export memory")
  }
  if (typeof handle !== "function") {
    throw new Error("module does not export handle")
  }

  return {
    step(message) {
      if (!(message instanceof Uint8Array)) throw new Error("message is not bytes")
      if (INPUT_BASE + message.length > memory.buffer.byteLength) {
        memory.grow(
          Math.ceil((INPUT_BASE + message.length - memory.buffer.byteLength) / 65536)
        )
      }

      // Written before the call: `handle` may grow memory, which detaches
      // this view, so nothing written after it may assume it is still live.
      new Uint8Array(memory.buffer).set(message, INPUT_BASE)

      const outPtr = handle(INPUT_BASE, message.length) >>> 0
      const result = new Uint8Array(memory.buffer)
      const length = readLength(result)

      if (outPtr + length > result.byteLength) {
        throw new Error("module returned a result outside its memory")
      }
      return result.slice(outPtr, outPtr + length)
    }
  }
}

function readLength(view) {
  const data = new DataView(view.buffer, LENGTH_SLOT, 4)
  const length = data.getUint32(0, true)
  if (length > MAX_RESULT_BYTES) throw new Error(`result claims ${length} bytes`)
  return length
}
