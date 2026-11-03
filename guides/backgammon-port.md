# Backgammon on SSB — port spec

Porting the provably-fair backgammon game from Catenary (Bushbaby over
Baobab logs) to HighWire (SSB over the erlbutt engine).

Status: the SHA-256 chain, rules engine, fold, local store, publish path and
a read-only gameroom are implemented on the `backgammon` branch. Playing a
turn, the automatic openings and the timeline card are not yet built.

Scope decisions taken: game messages are **public typed messages**; players
are **one feed each**; **no compatibility with Catenary's wire format or its
scrypt chain** — the port optimises for how the game feels to play and how
easily another client can verify it.

## 1. What is being ported

Catenary's game is four pieces of pure logic plus two pieces bound to its
log model.

| Source | Lines | Carries over | Notes |
| --- | --- | --- | --- |
| `games/backgammon/chain.ex` | 380 | rewritten, ~200 | scrypt → SHA-256 (§4) |
| `games/backgammon/engine.ex` | 443 | verbatim | rules, legal/maximal plays |
| `games/backgammon/notation.ex` | 135 | verbatim | Magriel notation |
| `games/backgammon/fold.ex` | 615 | ~94% | one reader function replaced |
| `games/backgammon/game.ex` | 436 | ~65% | log addressing and the scrypt spec dropped |
| `indexworker/challenges.ex` | 324 | rewritten | Baobab scan → SSB index |
| `live/backgammonview.ex` | 1,976 | ~85% | three substitutions, plus §9 |
| `test/.../backgammon/*` | 1,691 | ~90% | fixtures need new readers |

The fold is the reason this port is tractable. It orders entries by content,
not by transport: opening rolls sort on `{round, role}` and turns sort on the
integer `turn` field (`fold.ex:174-180`). Nothing depends on timestamps or
arrival order, so SSB's non-deterministic cross-feed delivery changes nothing
about correctness.

## 2. What does not carry over

Catenary gives one identity many append-only logs: a base log, derived logs
discriminated by an 8-bit family tag, and an 8-bit device facet in the high
bits of the log ID. A game is a derived log (`game_base | facet << 56`), which
is what lets a peer carry your journal and refuse your game moves.

SSB gives one keypair one feed, replicated whole. Consequences:

- **No derived logs.** Game messages interleave with posts in the same feed
  and are separated by `type`, not by log.
- **No per-type replication.** Followers replicate every move. Accepted for
  v1; boxed messages are the future escape hatch, and they still replicate
  the bytes.
- **No device facets.** A player is one feed. Multi-device play is deferred
  (§13), and the fold's turn numbering is what makes it possible later.
- **No local message store.** HighWire reads windows over
  `createHistoryStream` and persists only tombstones and edits in DETS. The
  game needs durable state, so it gets its own store (§7).

Around 3,100 of the 4,300 game lines survive with mechanical edits. The chain
and the index are rewritten, and roughly 1,000–1,300 lines are new, most of
them the store and the ergonomics work in §9.

## 3. Wire protocol v1

One namespace, `backgammon/*`, all in the author's public feed. JSON content.
`game_id` is 32 random bytes as 64 lowercase hex characters — safe in URLs and
in file names. Protocol version rides in `"v"`.

Every message carries `game_id`; everything after the challenge also carries
`"root"` — the SSB key of the challenge message — which makes the game a
thread and gives the index one grouping key.

**challenge** (author = challenger)

```json
{
  "type": "backgammon/challenge",
  "v": 1,
  "game_id": "<64 hex>",
  "role": "challenger",
  "commit": "<64 hex>",
  "to": "@feed…"
}
```

`to` is optional and marks a directed challenge; absent means open.

**accept** (author = accepter)

```json
{
  "type": "backgammon/accept",
  "v": 1,
  "game_id": "<64 hex>",
  "root": "%challenge-key.sha256",
  "role": "accepter",
  "commit": "<64 hex>",
  "reveal": "<64 hex>"
}
```

**roll** (opening rounds, alternating)

```json
{"type": "backgammon/roll", "v": 1, "game_id": "…", "root": "…",
 "round": 0, "r_cur": "<64 hex>", "r_next": "<64 hex>", "reveals": 1023}
```

A roll carries the same `r_cur`/`r_next` pair a turn does: the fold advances
both players' chains through the opening rounds, so one half per entry is not
enough to verify or to seed the first turn.

**turn**

```json
{"type": "backgammon/turn", "v": 1, "game_id": "…", "root": "…",
 "turn": 1, "roll": "3-5", "moves": "13/8 13/10",
 "r_cur": "<64 hex>", "r_next": "<64 hex>", "reveals": 1021,
 "note": ""}
```

**resign** and **withdraw** are single-field terminators; `withdraw` is only
honoured from the feed that authored the challenge.

Dropped from Catenary's shapes: `player` (the message author is the player),
`family` (superseded by `v`), `challenger` on turn entries (`root` resolves
it), `chain_spec` (there is no scrypt parameter set left to describe), and all
of `game_base` / `game_log_id`. Catenary's separate `play` entry is also gone:
it exists only so its derived game log is self-contained without indexing the
challenge log, and `root` removes that need — the fold's `:accept_reveal`
option already takes the reveal straight from the accept message.

A whole game message is a few hundred bytes, well inside SSB's 8 KiB
convention, and readable enough that someone can hand-write one to test a
client.

## 4. Fairness without scrypt

Catenary's chain spends ~10 s in pure Elixir (the comment at `chain.ex:171`
measures it) and costs every verifier a memory-hard KDF to check. Neither buys
anything here. The threat is a player deviating *after* committing, which is
resisted by collision and preimage resistance, not by KDF cost; the chain's
inputs are 32 bytes of entropy derived from an ed25519 secret, so there is no
password to stretch and no dictionary to slow down. scrypt's memory-hardness
exists to protect low-entropy secrets, and this protocol has none.

v1 therefore uses a SHA-256 chain:

```
seed       = HMAC-SHA256(identity_secret, "highwire/backgammon/v1/seed" ‖ game_id ‖ role)
chain[0]   = SHA-256(seed)
chain[i+1] = SHA-256(chain[i])                     // 1024 links
commit     = SHA-256(chain[1023])
dice       = SHA-256(mover_half ‖ opponent_half)   // unchanged
```

The chain is 1024 links against Catenary's 256 — two links are spent per turn,
so a game now has ~512 turns of headroom instead of 128, which no real game
reaches. Building it costs microseconds instead of ten seconds, so the
"cache the chain so a roll doesn't rebuild it" machinery in `chain.ex`
(`cache_get/2`, `cache_put/3`) disappears along with the games-table field it
wrote to.

Verification is a handful of hashes. The shortest honest JS verifier, with no
dependencies, in a browser or Node 19+ (where `crypto.subtle` is global):

```js
const sha256 = async (u8) =>
  new Uint8Array(await crypto.subtle.digest('SHA-256', u8));
const hex = (u8) => [...u8].map((b) => b.toString(16).padStart(2, '0')).join('');

// a reveal is genuine if hashing it reproduces the previous link
const linkOk = async (revealHex, expectedHex) =>
  hex(await sha256(Uint8Array.from(revealHex.match(/../g).map((h) => parseInt(h, 16)))))
    === expectedHex;
```

A full game verifies in microseconds in any runtime, which is the property
that makes third-party clients realistic.

The seed still derives from the identity secret, so fresh-device recovery
works: `HighWire.SSB.Keys.load!/1` returns the private bytes in-process and
`identities.json` keeps a copy per identity. Only commitments and reveals are
published. Losing the identity loses the chain — the same trade Catenary
makes, and not one the protocol can avoid.

## 5. Publish path

No engine or erlbutt change. HighWire already publishes arbitrary content:

```elixir
HighWire.Timeline.publish_content(%{"type" => "backgammon/turn", …})
```

which is `Client.call(client, ["publish"], [content], 10_000)` under the hood
(`timeline.ex:929`), with no type whitelist. A thin
`HighWire.Backgammon.Log` module wraps it per message type, injects `v`, and
returns the published key so the store applies the entry immediately instead
of waiting for the engine's tail.

## 6. Identity

`HighWire.SSB.Identities` keeps several feeds per install with one active. v1
treats the active feed as the player and requires the opponent to follow it.
Two players on one machine means two identities, each with its own feed in the
same store — which is what makes an end-to-end test possible without a network
peer.

## 7. Local index

New module `HighWire.Backgammon.Store`, modelled on the existing
`HighWire.SSB.MessageIndex` DETS pattern: one file, `<home>/backgammon.dets`,
owned by a GenServer.

Per game, keyed by `game_id`:

- participants (challenger feed, accepter feed), challenge key, accept key
- raw backgammon entries, in the order received (the fold re-sorts)
- the folded snapshot: position, turn count, mover, phase, remaining reveals,
  winner, history for the scrubber
- per-feed backfill cursor (max `seq` seen)

Entry ingestion:

1. **Backfill** — for each followed feed, `createHistoryStream` with
   `%{"id" => feed, "seq" => cursor, "limit" => n}`, keeping only
   `backgammon/*` types and advancing the cursor. This is the expensive path
   and it runs once per feed, resumed on restart.
2. **Live** — open the engine's append tail (`patchwork.publicFeed.latest`,
   the stream Timeline already consumes at `timeline.ex:2311`) and apply
   matching messages as they land. Each subscriber opens its own muxrpc
   stream, so the Timeline's own tail is unaffected.

Fold cost per game is small (a few hundred entries of pure Elixir), so the
snapshot is recomputed on append and cached; a page read never folds.

The store is also what makes §9 possible: it is the only thing in the app that
knows it is your move, so the badge, the timeline card and the game list all
read from it rather than from the feed.

## 8. Timeline

Game traffic must not read as social noise. Two changes:

- Game messages are dropped from the feed before rows are built. Doing it
  that late is not enough: a turn carries `root` at the challenge, so the
  thread builder would hang a board under the invitation, and a lone
  challenge would collapse into a "sent a … message" run. Both go in
  `build_feed/3`, ahead of threading.
- `MessageText.typed_label/4` keeps its generic fallback for the places game
  messages still surface (a profile feed, the post page), so nothing renders
  blank.

Where those rows used to be, a single card stands in for the game (§9).

## 9. Ergonomics for players

This is the part that decides whether anyone plays. Everything below is a
requirement, not polish.

**Starting a game takes one click.** The board page of someone you follow has
"Play backgammon"; it publishes a challenge and opens the game. Open
challenges are listed on `/games` and joinable in one click. There are no
codes to type, no lobby, and nothing to paste.

**The openings are silent.** Catenary alternates revealed rolls until a
starter is decided, which is correct and, done by hand, horrible. The accepter
publishes its opening roll as part of accepting, and the challenger's client
answers automatically when it sees it. The player sees "You're white" and a
board. If a client is not running, the same rolls can be published on next
launch — the fold only needs the entries, not the timing.

**Offline is normal.** Nothing requires both players to be online: SSB is
asynchronous, so a game is a slow conversation that survives a week of
silence. No presence, no timers, no server.

**The board is yours.** Local checkers sit at the bottom in the light set,
whatever role the log says. Tapping a checker highlights legal destinations;
tapping a destination prepares the move and shows the resulting position
before it is confirmed; prepared moves can be taken back until confirm. Illegal
input is not offered rather than rejected afterwards. The roll is drawn
automatically because the reveals were already published.

**Updates arrive in a second, not two minutes.** The timeline's 120 s reload
is right for posts and wrong for a game. The Store follows the engine's append
push and the game page is a LiveView subscribed to it, so an opponent's move
lands as a re-render.

**You are told when it is your move.** A nav badge, a games list ordered by
whose turn it is, and a timeline card reading "Ada played 6-3 — your move"
with a board thumbnail, replacing the raw entry rows. All three read the
store's snapshot.

**Stalls are visible and honest.** "Ada's move, 3 days" rather than a game
that silently sits. There is no forfeit to enforce without an arbiter, so the
action offered is "abandon", which archives the game locally and says so.

**Finished games stay readable.** Opening one shows the final position with
the replay scrubber, so the whole game can be walked turn by turn.

## 10. UI

Catenary's view is a `LiveComponent`: board, tap-to-move with a legal-play
list, prepared-move preview, replay scrubber with per-turn checker diffs.
HighWire is the same stack (Phoenix LiveView, Tailwind), so the markup and the
interaction model carry over. Three substitutions:

| Catenary | HighWire |
| --- | --- |
| `Catenary.Display` | `HighWire.Avatar` / `HighWireWeb.Components.*` |
| `Catenary.LogWriter` | `HighWire.Backgammon.Log` |
| `:challenges` index row | `HighWire.Backgammon.Store` snapshot |

Routes, inside the existing `live_session :app` scope:

```elixir
live "/games", GamesLive
live "/games/:game_id", GameLive
```

The rewrite is mostly the publish actions, which move from "append to a log at
this ID" to "publish this content", and the index lookups.

## 11. File plan

```
lib/highwire/backgammon/chain.ex        rewritten: SHA-256 chain, no cache
lib/highwire/backgammon/engine.ex       from catenary, verbatim
lib/highwire/backgammon/notation.ex     from catenary, verbatim
lib/highwire/backgammon/fold.ex         from catenary, reader replaced
lib/highwire/backgammon/game.ex         from catenary, addressing removed
lib/highwire/backgammon/log.ex          new: message builders + publish
lib/highwire/backgammon/store.ex        new: DETS index, backfill, live tail
lib/highwire/backgammon/reader.ex       new: SSB entries → fold input
lib/highwire_web/live/games_live.ex     new: list, challenge, accept, badge
lib/highwire_web/live/game_live.ex      new: board host, turn notification
lib/highwire_web/components/board.ex    ported from backgammonview
```

## 12. Verification

- Port the 1,691 lines of tests. Most exercise the rules, the chain and the
  fold through injected entry lists, so they run unchanged once the fixture
  reader emits SSB-shaped maps instead of Baobab entries. Chain tests get new
  vectors; the properties (no reveal predicts the next, commitment binds,
  fresh-device recovery) are unchanged and stay property-tested.
- New: chain recovery from logs plus secret (§4), store backfill cursor
  resumption, live-tail application, timeline exclusion.
- New: end-to-end with two identities in one store — challenge, accept,
  automatic openings, several turns, resign — asserting both sides fold to the
  same position.
- New: adversarial — forged reveal, turn from the wrong feed, out-of-order
  arrival, duplicated entry, an entry claiming a game it did not start.
- New: the JS verifier in §4 runs against a recorded game, since a protocol
  only one language can check is a protocol nobody adopts.

## 13. Deferred

- **Multi-device players.** A player would become a set of feeds. The fold
  already orders by turn number, so this is a reader and verification change
  rather than a rewrite, but it needs its own tests. ~3–5 days.
- **Private games.** Box the content to the two feeds. The engine supports
  it; the index would unbox before folding. Content stays out of followers'
  view but the ciphertext still replicates.
- **An app/plugin framework.** Catenary's `apps.ex` + DSL is a general
  scripting surface for logs. Nothing here needs it.

## 14. Effort

| Phase | Work | Days |
| --- | --- | --- |
| 0 | Protocol module, message builders, publish wrapper, SHA-256 chain | 1–2 |
| 1 | Store: DETS, backfill, live tail, timeline exclusion | 3–4 |
| 2 | Fold + reader port, fairness and recovery tests | 3 |
| 3 | Board component, games pages, routes, and §9 in full | 6–8 |
| 4 | Hardening: stalls, malformed and forged entries, packaging | 3–4 |
| | **Total** | **16–21** |

Three to four weeks of focused work with both codebases open. Dropping scrypt
returns about a day (no KDF plumbing, no chain cache, no ten-second builds, no
dependency); §9 spends two or three. The narrower scope — one feed per player,
public messages, no badges or cards — lands near 11–14 days.

## 15. Risks

| Risk | Effect | Mitigation |
| --- | --- | --- |
| Followers replicate every move | Feed bloat, visible game traffic | Accepted for v1; boxed games later (§13) |
| A player withholds reveals | Game stalls with no arbiter | Surface it from `reveals` counters and show "Ada's move, 3 days"; no protocol fix without a third party |
| Backfill cost on large feeds | Slow first open, engine CPU | Per-feed cursors, bounded windows, index built once |
| No device facets | Two devices look like two players | v1 constraint, documented; §13 |
| Automatic openings need a client online | Game does not start until one launches | Rolls are deterministic from reveals, so the publish is idempotent and happens on next launch |
| Someone "hardens" the SHA-256 chain back to scrypt | Patches diverge, clients break | §4 states why the KDF is not a security control here; the chain spec is fixed at `v: 1` |
| Engine history path is expensive | Polling games is CPU burn | Store owns state; engine is touched only for backfill and the tail |
