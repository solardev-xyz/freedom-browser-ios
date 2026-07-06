# Ad-block feed: production key ceremony

What to do when we're ready to switch the filter-list update channel from the
throwaway test key to a durable production key. Until this is done, both
clients ship with zero-address placeholders — the update path is **dormant**
and they run on bundled lists only, which is safe.

The same ceremony is documented in the desktop repo
(`freedom-browser/research/adblock-production-key-ceremony.md`); do it once,
update both clients.

## What this key is

One secp256k1 key is (a) the **Swarm feed owner** — it signs the feed's
Single-Owner-Chunks — and (b) the **manifest signer** — it makes the EIP-191
`sig` over the canonical manifest. Its **address** is compiled into every
client as the trust anchor:

- iOS: `Freedom/Freedom/Adblock/AdblockUpdateFeed.swift`
  (`feedOwnerAddress`, `manifestSigAddress`)
- Desktop: `freedom-browser/src/main/adblock/feed-config.js`
  (`FEED_OWNER_ADDRESS`, `MANIFEST_SIG_ADDRESS`)

Both are pinned separately on purpose: it leaves room to later split manifest
signing onto a more-protected key without changing the feed identity.

**Threat model:** whoever holds the private key can push filter lists to every
Freedom user. Rotation requires shipping new app builds (the address is
compiled in). Treat it accordingly. The key needs **no funds, ever** — storage
is paid by the publisher node's own wallet/batch, which is a different key with
no trust role.

## The ceremony

1. **Generate the key offline.** On a machine you trust (ideally offline), from
   a `freedom-adblock-service` checkout:

   ```bash
   node -e "const {Wallet}=require('ethers'); const w=Wallet.createRandom(); console.log('address:', w.address); console.log('privateKey:', w.privateKey)"
   ```

2. **Store the private key** in the password manager (and, if you want a
   belt-and-braces copy, on paper/offline). It must never land in a repo, CI
   config, or chat. The **address** is public — paste it anywhere.

3. **Install it on the publisher** (Coolify app `adblock-publisher` on the
   swarmit server): update the `FEED_SIGNER_KEY` secret to the new private key
   (PATCH via the Coolify API or UI) and redeploy. See
   `freedom-adblock-service/docs/deploy.md`.

4. **Let it publish version 1 of the new feed.** A new owner means a brand-new
   feed at `freedom/adblock/lists/v1`; the daemon's first cycle publishes
   version 1 signed by the new key. Verify in the container logs:
   `[publish] wrote version 1`.

5. **Verify before pinning.** Point a dev build at the new feed via the env
   overrides — no code change needed:
   - iOS (Xcode scheme env or simulator):
     `FREEDOM_ADBLOCK_FEED_OWNER=<address>` and
     `FREEDOM_ADBLOCK_SIG_ADDRESS=<address>`; run the app or the
     `AdblockUpdateLiveTests` e2e (adjust its pinned owner) against a local
     node.
   - Desktop: same two env vars on a dev launch.
   Confirm: manifest verifies, lists download, engine/rule-lists rebuild.

6. **Hardcode the anchor** in both clients (replace the zero-address defaults,
   keep the env override for dev):
   - `AdblockUpdateFeed.swift` → `feedOwnerAddress` / `manifestSigAddress`
   - `feed-config.js` → `FEED_OWNER_ADDRESS` / `MANIFEST_SIG_ADDRESS`
   Ship both through the normal release process. From the first build with the
   anchor, the update path goes live for users.

7. **Retire the test feed.** The throwaway key
   `0xf6aa84e06Ed0C5fF6DD707fba16F0c1BA459FCE0` (test feed, versions 1–6) has
   no further role; dev builds can keep using it via env overrides while its
   batch lasts.

## Ops notes (already in place, listed for completeness)

- The publisher's postage batch is **owned by the node wallet**, not this key.
  Batch must be **mutable** and **depth ≥ 20** (depth 17's 2-slots-per-bucket
  silently drops chunks on multi-MB publishes — learned the hard way, see the
  desktop repo's `research/wp5-build-status.md`).
- The daemon warns in its logs when the batch TTL drops below 30 days; topping
  up is a manual action (`PATCH /stamps/topup/...`, see
  `freedom-adblock-service/docs/deploy.md`).
- Watch for **unexpected feed versions** in the publisher logs — the daemon
  logs every version it writes; a version appearing that the daemon didn't
  write would mean key compromise.
