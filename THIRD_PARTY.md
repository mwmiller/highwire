# Third-party licenses

HighWire is MIT (see `LICENSE`). It ships or operates alongside the
following third-party works:

## erlbutt (sidecar SSB engine)

- Source: <https://github.com/cmoid/erlbutt> (HighWire maintains a fork)
- License: **GPL-2.0-only** (SPDX headers in every source file;
  `LICENSES/COPYING` in that repository is the GPLv2 text)
- Copyright (C) Charles Moid

erlbutt runs as a **separate process**. HighWire never links its code;
the two communicate over muxrpc on loopback. HighWire installers ship an
erlbutt binary, conveyed under GPLv2; its source — including any
HighWire fork modifications — is available from the project's source
repository, and the full erlbutt source tarball accompanies each
release (GPLv2 §3).

erlbutt's own dependencies, as conveyed inside that binary:

| Component | License |
|---|---|
| ranch | ISC |
| enacl | MIT |
| esqlite | Apache-2.0 |
