# Radicle on iOS — status & roadmap

*Branch `radicle`, last updated 2026-08-19.*

The app embeds a **publish-capable** Radicle node: heartwood's
`serve-in-process` feature answers peers' fetches in-process (hand-written
non-delta packfile — no `git upload-pack`, no `git gc`, zero child
processes), so peers replicate the phone's COB writes back over the
sessions it opened. The phone can clone/browse, file issues, comment, and
serve those refs.

## Architecture (what lives where)

| Layer | Where | Notes |
|---|---|---|
| In-process serving | `solardev-xyz/heartwood` branch `freedom/embed` | 5 patches over upstream, written to be upstreamable |
| Embedded node facade | `solardev-xyz/libradicle` (`uniffi/` crate) | 31 sync JSON-string functions mirroring the desktop napi addon |
| Merged staticlib | `solardev-xyz/freedom-mobile-ffi` branch `radicle`, release v0.9.0 | 4th member behind default-on `radicle` feature; Android excludes it |
| Swift kit | `Packages/SwarmKit` → `RadicleKit` | `Generated/libradicle_uniffi.swift` is bindgen output — regenerate on every framework bump |
| Provider (writes) | `Freedom/Radicle/Bridge/` | `window.radicle`, 14 methods, 3 consent tiers — desktop `docs/radicle-provider-api.md` v0.2, payload-identical |
| Reads | `Freedom/Radicle/RadSchemeHandler.swift` | `fetch('rad:<rid>/…')`, port of desktop `radicle-api-protocol.js` `serveRepoApi` — **provider and scheme handler must ship together** (canopy infers both from `isFreedomBrowser`) |
| Node UI | node-menu row + `RadicleNodeSheet` | identity, peers, seeded repos, seed-by-RID |

Pin cascade — always bump in this order:
heartwood → libradicle (re-pin rev ×3 Cargo.tomls) → freedom-mobile-ffi →
rebuild xcframework (`scripts/build-xcframework.sh`) → copy regenerated
Swift into `RadicleKit/Generated/` → new release + Package.swift checksum.

## Hard-won integration constraints (do not regress)

- **Non-delta packfile**: libgit2's packbuilder only emits `REF_DELTA`,
  which gix (the fetch client) rejects for in-pack bases. Serving emits
  full objects.
- **One SQLite**: radicle's `sqlite3-src` and ant's `libsqlite3-sys` both
  declare `links = "sqlite3"`; freedom-mobile-ffi patches `sqlite3-src`
  to a no-op and radicle's bindings resolve against ant's bundled copy
  (`vendor/sqlite3-src/README.md`). Invariant: ant keeps rusqlite.
- **No cdylib** on `libradicle-uniffi` (dylib links can't resolve SQLite
  within their own graph); bindgen scans the staticlib.
- **`radicle-signals` is iOS-gated** in heartwood (`sem_safe` doesn't
  compile for iOS); only the `Signal` enum exists there.
- **Control socket ≤104 bytes** (`sun_path`): `RadicleNode.start` sets
  `RAD_SOCKET` via `shortSocketPath()` — device sandbox tmp fits; the
  simulator has NO short sandbox dir (even `DARWIN_USER_TEMP_DIR` is
  ~100 bytes there) so it falls back to host `/tmp`, pid-scoped. Guarded
  by `RadicleSocketPathTests` (runs in-simulator) and libradicle's
  `tests/socket_env_override.rs`.
- **Every UniFFI call blocks** — route through `RadicleNode`'s detached
  tasks, at *default* QoS (the node's event-loop thread runs default;
  higher-QoS waiters are a priority inversion).
- RadicleKit links `libz` + `libiconv` (vendored libgit2).
- `rad:` URLs are **hand-parsed, never canonicalized** (base58 RIDs are
  case-sensitive).
- Desktop reference code lives on freedom-browser branch
  **`feat/radicle-embedded`** — its `main` still has the old
  spawn-httpd integration; read via `git show feat/radicle-embedded:…`.

## Roadmap — missing / next

**1. Full publish-loop verification — DONE (2026-08-20).** Phone-authored
issues + comments replicated to iris AND rosa via the in-process serve
path, verified through the seeds' public APIs. (Desktop's failure to
show them was a desktop-side refetch/profile question, tracked
separately — the seeds have the content.)

**2. Release swap — DONE.** SwarmKit consumes the v0.9.0 release.

**3. Phase D — lifecycle (biggest real gap).** iOS suspends the app; the
node has no pause/resume (uniffi surface is start/shutdown only, unlike
Myotis). Backgrounding drops sessions; reconnection behavior is untested.
Until done, the phone effectively publishes only while foregrounded.
Needs: pause/resume in libradicle + scenePhase wiring + possibly
background-task grace.

**4. Peer count investigation (parked, observed on-device).** 0→2 peers
is slow; later in the same session the node reached 9+ on its own, so
the plateau is transient address-book warm-up, not a hard cap. Still
worth understanding the ramp rate. Revisit with Phase D (same
connection-maintenance subsystem).

**5. Revocation UI.** Radicle grants can only be dropped by the dApp
itself (`radicle_disconnect`); no chrome-side "manage connected sites"
surface yet. The disconnect event plumbing already exists
(`.radiclePermissionRevoked`).

**Deliberate v1 exclusions** (parity with the desktop spec): no repo
creation / `importRepo` on the phone (needs in-process `git push` — same
class of effort as upload-pack); no patch creation (COB writes only);
private repos invisible everywhere; seed progress is phase-level, not
byte-level (parked upstream).

**Cosmetic/ops:** Radicle logo asset + node-indicator segment (currently
SF Symbol, no segment); alias hardcoded `freedom-ios`; upstream the
heartwood patches (5: `Profile::load_from`, `no-serve`/`no-gc`,
`serve-in-process`, COB-publish e2e, iOS `radicle-signals` gate);
Windows desktop sequencing (after iOS; mostly CI/packaging).
