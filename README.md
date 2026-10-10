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
| macOS (Intel) | `HighWire_<v>_x64.dmg` |
| Debian/Ubuntu | `HighWire_<v>_amd64.deb` |
| Fedora/openSUSE | `HighWire-<v>-1.x86_64.rpm` |
| Other Linux | `HighWire_<v>_amd64.AppImage` |
| Linux ARM64 | `_arm64.deb` / `.aarch64.rpm` / `_aarch64.AppImage` |
| Windows | `HighWire_<v>_x64-setup.exe` |

The macOS builds are notarized. All artifacts are produced by the
tag-triggered release workflow (`.github/workflows/release.yml`).

## Status

**Application**

- Posting, threads, likes, follows, profiles, private messages, images
  and blobs, full-text search, channels, and pub invites work against
  the engine.
- Profile activity renders newest-first (ordering is done in the UI).
- One identity per `HIGHWIRE_HOME`; there is no in-app account
  switching.
- The Network page (`/network`) is the general place to manage
  dialing: the network profile switcher, the dialer's enable/disable
  and dial-now controls, the live connections, the `conn.json`
  address book, and the recent dial attempts. The native menu's Go
  items (Timeline ⌘1, Network ⌘2, Dashboard ⌘D, My Profile ⌘⇧P) and
  Preferences ⌘, navigate the webview; the window remembers its size
  and position across launches.

**Engine**

- Release builds embed erlbutt built unmodified from upstream
  (`github.com/cmoid/erlbutt`) as a complete OTP release under
  `priv/erlbutt`, booted as a sidecar when the app starts.
- First-run import of an existing JS-client `~/.ssb` store (secret,
  flume `log.offset` history, blobs) is provided by erlbutt's
  converter at boot. `~/.ssb` is only read, never written.
- Publish round-trip — sign, store, read back — verified against a
  bundled-engine build.

**Build and packaging**

- Tag push runs five native builds on free public runners — macOS
  (arm64 + Intel), Linux (x86_64 + ARM64), Windows — each bundling
  its own Burrito backend, then publishes the installers to the
  GitHub release for that tag. The workflow is also runnable by hand
  (workflow_dispatch) as a build-only dry run.
- Known gap: the Windows enacl build needs `sodium.dll` beside the
  backend at runtime.
- The Intel macOS leg rides `macos-15-intel`, the last x86_64 image
  on GitHub Actions (EOL Aug 2027).

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
