# HighWire

A local-first social network on **Secure Scuttlebutt** — Catenary's
interface and idioms, speaking the real SSB network, so it syncs with
Poncho Wonky, pubs, and every other SSB client.

HighWire itself is MIT. The SSB engine is a local **erlbutt** node — a
GPL-2.0 fork, one process per account — that HighWire drives over muxrpc
on loopback, the same pattern as Poncho Wonky's hidden sbot. HighWire
never signs messages itself: publishing goes to erlbutt's `publish`
method, which owns canonical JSON and signing.

## What it does

- Posts, threads, likes, follows, profiles, private messages
- Images and blobs, full-text search, channels
- Pub onboarding via invites; LAN sync over `_ssb._tcp`
- Multiple accounts (one erlbutt process each)
- Fusion idioms: `highwire-oasis` peer discovery, per-peer subjectivity
  preferences carried as follows/blocks with local display filters

## Data and identity

Data lives in `~/.highwire` (override with `HIGHWIRE_HOME`) — **as the
destination of a complete first-run import**. On first launch HighWire
detects an existing `~/.ssb` (Poncho Wonky / Patchwork) and imports the
whole object store: your secret, the entire flume `log.offset` history,
and every blob. `~/.ssb` is never written to.

After the cutover, retire (rename) the old client before HighWire
publishes with that identity — per erlbutt's rule, two writers on one
feed is a permanent fork.

The engine connects to the mainnet SSB network
(`1KHLiKZvAvjbY1ziZEHMXawbCEIM6qwjCDm3VYRan/s=`).

## Development

```sh
mix setup          # deps
mix phx.server     # http://127.0.0.1:14042
```

## License

MIT (see `LICENSE`). See `THIRD_PARTY.md` for the erlbutt/GPL notice.
