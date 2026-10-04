# HighWire

A local-first social network on **Secure Scuttlebutt** — Catenary's
interface and idioms, speaking the real SSB network so it syncs with
Poncho Wonky, pubs, and every other SSB client.

HighWire itself is MIT. The SSB engine is a local **erlbutt** node (a
GPL-2.0 fork, one process per account) that HighWire drives over muxrpc
on loopback — same pattern as Poncho Wonky's hidden sbot.

## Status

Phase 0: skeleton boots; erlbutt interop spike in progress.

| Phase | What |
|---|---|
| 0 | Fresh repo from selected catenary pieces; erlbutt fork; interop spike |
| 1 | Accounts (N erlbutt processes), SSB read models, identity UI |
| 2 | Publishing: posts, threads, likes, follows, profiles, DMs |
| 3 | Networking: invites, pubs, `_ssb._tcp` LAN discovery |
| 4 | Patchwork parity: images, search, channels |
| 5 | Fusion idioms: highwire-oasis, subjectivity prefs |
| 6 | Packaging, licensing, releases |

Deferred: backgammon, the WASM app platform (both live on as later
phases; their engines stay untouched in catenary meanwhile).

## Development

```sh
mix setup          # deps
mix phx.server     # http://127.0.0.1:14042
```

Data lives in `~/.highwire` (override with `HIGHWIRE_HOME`).

## License

MIT (see `LICENSE`). See `THIRD_PARTY.md` for the erlbutt/GPL notice.
