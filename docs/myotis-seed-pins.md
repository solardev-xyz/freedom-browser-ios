# Myotis seed pins (2026-09-24)

**Problem.** A fresh install, or any engine start with a cold `peers.cache`,
fills its execution-layer pool from discv4 — and on mainnet discovery finds
few snap-capable nodes, most of which lag the beacon-verified head. Since
myotis v0.1.12 the engine refuses laggards at dial time and reports the
peers that can serve (`snapServingPeers`), so the app no longer *claims*
to be ready while every read fails; but without a serving peer it simply
stays not-ready. Measured on a cold simulator: 1–2 pooled peers and no
served read for 12+ minutes, versus 8–10 serving peers within 5 s and every
read served when the engine was handed known-good nodes (myotis #465).

**Mechanism.** The engine takes host seed pins (`myotis_set_boot_enodes`,
ABI 31+): a JSON array of `enode://<128 hex pubkey>@ip:port`, numeric hosts
only, at most 64, applied or refused as a whole. Pins are dialed first and
re-dialed only while nobody serves; discovery keeps running, and a pin that
turns out to lag or hang is benched and evicted like any other peer. The
pins are not written to the peer cache.

**What ships.** `Freedom/Freedom/Resources/myotis/seeds-mainnet.json` and
`seeds-gnosis.json`: nodes that have served a verified read to one of our
engines (`snapok` in a warm profile's cache), IPv4, TCP-reachable when the
list was built, and for mainnet additionally checked one at a time to
serve the Universal Resolver `eth_call` a cold engine needs. Each engine
boot (start and every recovery relaunch) pushes a random subset of at most
`MyotisSeedPins.limit` (20), so no operator is dialed first by every
install every time (`MyotisNode.seedEnodes`, set in `FreedomApp`).
`MyotisSeedPins.parse` drops malformed or duplicate-address entries
instead of letting one bad line refuse the whole push.

**Refresh at release time.** `scripts/myotis-seeds.py --network mainnet
<peers.cache>...` rebuilds a candidate list from warm caches (a long-lived
desktop profile is the best source), probing reachability;
`scripts/myotis-seeds-probe.sh <sim-udid> <candidates.json>` then runs the
engine against each candidate alone on a cold cache and reports which ones
actually serve the resolver call and how fast — keep the fast ones. On
2026-09-24, 8 of 41 reachable proven peers served at all (residential
addresses and busy nodes never did) and 5 served in under 3.5 s; those 5
ship. With them a cold simulator resolved a name via Myotis in 4.2 s on
the first attempt and under 1 s afterwards; with all 8 the slow members
led the ladder and reads took 5–7 s, past the 5 s budget. Lists age slowly —
26 of 29 proven peers from a three-day-old cache were still reachable —
but a stale list only costs the cold start its floor, never correctness:
every read is verified against the beacon anchor regardless of who served
it.

**Trade-off.** Every install dials the same few dozen operators first,
which is a mild centralization and lets those operators recognise Freedom
clients by the pin pattern. The random 20-of-N subset and discovery taking
over once the pool is full keep that small. A host-fetched, signed list
(like the RPC seed refresh) would remove the release coupling; not built.

**Smoke.** `FREEDOM_MYOTIS_BOOT_ENODES_MAINNET='[…]'` (DEBUG) replaces the
bundled list for one run; with `FREEDOM_DEBUG_RESOLVE=<name>` and a cold
cache the node log should show `seed pins (N) applied`, `snapServingPeers`
positive within seconds and the name resolving via Myotis.
