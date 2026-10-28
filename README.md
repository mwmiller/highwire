# HighWire

A local-first Secure Scuttlebutt client. A Phoenix application served
on loopback, packaged as a desktop app with Tauri, driving a local
**erlbutt** engine over muxrpc on loopback — one engine process per
`HIGHWIRE_HOME`.

HighWire does not sign messages itself: publishing goes through
erlbutt's `publish` method, which owns canonical JSON and signing.

## Download

Grab an installer from the
[latest release](https://github.com/mwmiller/highwire/releases/latest):

| Platform | Artifact |
| --- | --- |
| macOS (Apple Silicon) | `HighWire_<v>_aarch64.dmg` |
| Debian/Ubuntu | `HighWire_<v>_amd64.deb` |
| Fedora/openSUSE | `HighWire-<v>-1.x86_64.rpm` |
| Other Linux | `HighWire_<v>_amd64.AppImage` |
| Linux ARM64 | `_arm64.deb` / `.aarch64.rpm` / `_aarch64.AppImage` |
| Windows | `HighWire_<v>_x64-setup.exe` |

The macOS app bundle is signed with a Developer ID and notarized; the
`.dmg` wrapper is notarized and stapled too, so it opens without a
Gatekeeper override. All artifacts are produced by the tag-triggered
release workflow (`.github/workflows/release.yml`).

## Status

**Application**

- Posting, threads, likes, follows, profiles, private messages, images
  and blobs, full-text search, channels, and pub invites work against
  the engine.
- Profile activity renders newest-first (ordering is done in the UI).
- An install can hold several identities — every feed it can sign as —
  kept in a local registry with the active one mirrored into the
  engine's secret. The identity page switches between them (restarting
  the engine underneath), creates new ones, disables and re-enables
  them, exports a private key, and permanently deletes only from the
  disabled list. The store itself is shared: switching identity never
  moves feeds, blobs, or history.
- The Network page (`/network`) is the general place to manage
  dialing: the network profile switcher, the dialer's enable/disable
  and dial-now controls, joining a pub by redeeming an invite code or
  adding a peer by its address alone, the live connections, the
  `conn.json` address book, and the recent dial attempts. When the
  engine build predates `gossip.peers`, the page falls back to the
  admin namespace — dialer status, connected peers, the address book —
  and marks the report partial. The native menu's Go items (Timeline
  ⌘1, Network ⌘2, Dashboard ⌘D, My Profile ⌘⇧P) and Preferences ⌘,
  navigate the webview; the window remembers its size and position
  across launches.

**Engine**

- erlbutt is a branch-tracking git dep in `mix.exs` (`main`), locked
  to an exact revision in `mix.lock`. `mix deps.get` fetches it;
  `mix deps.update erlbutt` moves it to the current tip; `mix
  engine.build` compiles it into dev's release. `mix setup` does both.
- Release builds embed erlbutt built unmodified from that checkout
  (`github.com/cmoid/erlbutt`) as a complete OTP release under
  `priv/erlbutt`, booted as a sidecar when the app starts.
- First-run import of an existing JS-client `~/.ssb` store (secret,
  flume `log.offset` history, blobs) arrives on its own gated page:
  the offer lists what was found and asks — Import it or Start
  fresh — then shows the converter's progress and, if it fails, the
  reason with a retry. `~/.ssb` is only read, never written.
- Publish round-trip — sign, store, read back — verified against a
  bundled-engine build.

**Build and packaging**

- Tag push runs four native builds on free public runners — macOS
  (arm64), Linux (x86_64 + ARM64), Windows — each bundling
  its own Burrito backend, then publishes the installers to the
  GitHub release for that tag. The workflow is also runnable by hand
  (workflow_dispatch) as a build-only dry run.
- The engine's `enacl` sodium NIF is dlopen'd, so the bundlers never
  see it; the release copies libsodium next to the NIF and repoints the
  NIF at its own directory, keeping the engine self-contained on Linux
  and macOS whatever the host provides. Known gap: the Windows build
  still needs `sodium.dll` beside the backend at runtime.

## Data and identity

Data lives in `~/.highwire` (override with `HIGHWIRE_HOME`) — as the
destination of a complete first-run import. On first launch HighWire
detects an existing `~/.ssb` (Patchwork, Poncho Wonky, and other
JS-client installs) and offers to take it over: your secret, the
entire flume `log.offset` history, and every blob. Decline and it
starts fresh instead. `~/.ssb` is never written to.

After the cutover, retire (rename) the old client before HighWire
publishes with that identity — per erlbutt's rule, two writers on one
feed is a permanent fork.

The engine connects to the mainnet SSB network
(`1KHLiKZvAvjbY1ziZEHMXawbCEIM6qwjCDm3VYRan/s=`).

## Development

```sh
mix setup          # deps, then builds the erlbutt engine
mix phx.server     # http://127.0.0.1:24042
mix precommit      # format, credo, compile --warnings-as-errors, test
```

`mix deps.update erlbutt && mix engine.build` (or the `mix
engine.update` alias) pulls and rebuilds the engine when upstream
moves. Point `ERLBUTT_REL` at another release to run against a
working engine checkout instead.

## License

MIT (see `LICENSE`). See `THIRD_PARTY.md` for the erlbutt/GPL notice.
