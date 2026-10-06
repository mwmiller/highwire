# HighWire

A local-first Secure Scuttlebutt client. A Phoenix application served
on loopback, packaged as a desktop app with Tauri, driving a local
**erlbutt** engine over muxrpc on loopback — one engine process per
`HIGHWIRE_HOME`.

HighWire does not sign messages itself: publishing goes through
erlbutt's `publish` method, which owns canonical JSON and signing.

## Status

State of the `v0.1.0` line:

**Application**

- Posting, threads, likes, follows, profiles, private messages, images
  and blobs, full-text search, channels, and pub invites work against
  the engine.
- Profile activity renders newest-first (ordering is done in the UI).
- One identity per `HIGHWIRE_HOME`; there is no in-app account
  switching.

**Engine**

- Release builds embed erlbutt built unmodified from upstream
  (`github.com/cmoid/erlbutt`) as a complete OTP release under
  `priv/erlbutt`, booted as a sidecar when the app starts.
- First-run import of an existing JS-client `~/.ssb` store (secret,
  flume `log.offset` history, blobs) is provided by erlbutt's
  converter at boot. `~/.ssb` is only read, never written.
- Publish round-trip — sign, store, read back — verified against a
  bundled-engine build.

**Build and packaging** (`.github/workflows/release.yml`, tag `v0.1.0`)

- Linux: workflow passes and produces the app bundle.
- macOS: builds and codesigns; notarization fails because the Apple
  credentials in the repo secrets are not valid. It needs an
  app-specific password from appleid.apple.com.
- Windows: vcpkg resolves libsodium; the engine build stalls fetching
  rebar3's plugin from hex.pm (bounded at 15 minutes, exit 124). Open.
- No GitHub release is published. The publish job runs only after all
  three OS builds pass.

## Data and identity

Data lives in `~/.highwire` (override with `HIGHWIRE_HOME`) — as the
destination of a complete first-run import. On first launch HighWire
detects an existing `~/.ssb` (Patchwork, Poncho Wonky, and other
JS-client installs) and imports the whole object store: your secret,
the entire flume `log.offset` history, and every blob. `~/.ssb` is
never written to.

After the cutover, retire (rename) the old client before HighWire
publishes with that identity — per erlbutt's rule, two writers on one
feed is a permanent fork.

The engine connects to the mainnet SSB network
(`1KHLiKZvAvjbY1ziZEHMXawbCEIM6qwjCDm3VYRan/s=`).

## Development

```sh
mix setup          # deps
mix phx.server     # http://127.0.0.1:24042
mix precommit      # format, credo, compile --warnings-as-errors, test
```

## License

MIT (see `LICENSE`). See `THIRD_PARTY.md` for the erlbutt/GPL notice.
