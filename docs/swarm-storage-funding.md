# Node-side storage funding

How a user goes from browsing (ultra-light) to publishing (light node with
a storage plan) since PR "node-side storage funding". Replaces the
`SwarmNodeFunder` one-transaction flow, which is gone from the tree.

## The shape

The node wallet is the only account that pays. The user sends plain xDAI
to it and ant (via `freedom-mobile-ffi`) does everything on-chain:

1. `ant_storage_quote(depth, days)` prices a plan **all-in**: the batch
   itself, plus the one-time settlement deposit for the chequebook when it
   isn't funded yet, plus gas headroom. The result says what the node
   wallet holds, what it needs, and `sufficient_funds`.
2. The app shows the shortfall (`xdai_to_send_display`, rounded up to the
   next cent), an EIP-681 QR (`ethereum:<node>@100?value=<wei>`), the node
   address, and a "Pay from Freedom wallet" button that opens the normal
   send flow prefilled with recipient and amount.
3. While the payment step is up the app re-quotes every 6 s. The moment a
   quote comes back `sufficient_funds == true` it calls
   `ant_storage_buy_xdai(depth, amount_per_chunk, immutable = 1)`
   **once**. The buy swaps xDAI → xBZZ, approves, creates the batch,
   registers it with ant, and deploys and funds the chequebook when
   needed. It blocks until the transactions confirm (one to two minutes
   on Gnosis).
4. On success the running gateway lists the batch at once (the C API and
   the gateway share the issuer registry); it reports `usable:false` for
   about 70 s (ant #107), then usable. The app re-runs the idempotent
   `ant_start_gateway` (`SwarmNode.refreshChainState`) so the gateway
   adopts the chequebook the buy deployed and its `/chequebook` and
   `/wallet` surfaces follow; `StampService` polls fast until `/stamps`
   lists the batch as usable. No mode switch, no restart.

Extending a node-side plan works the same way with
`ant_storage_topup_quote(days)` / `ant_storage_topup_xdai(amount_per_chunk)`
(`StampExtendView` → "Extend plan" when the batch is the connected plan
from `ant_storage_status`). Dilutes and legacy batches keep bee's gateway
endpoints.

The chequebook's settlement deposit is visible on the node sheet
(`ant_storage_settlement_deposit`) and a "Top up from node wallet"
button runs `ant_storage_settlement_topup`. That replaces the old
silent `topUpChequebookIfBelowFloor` after every stamp purchase, which
deposited xBZZ the node no longer holds.

## Where it lives

| Piece | File |
|---|---|
| FFI wrappers (`storageQuote`, `storageBuyXdai`, `storageTopupQuote`, `storageTopupXdai`, `storageStatus`, `settlementDeposit`, `settlementTopup`) | `Packages/SwarmKit/Sources/SwarmKit/SwarmNode.swift` |
| JSON models, cent rounding, EIP-681 URI | `Freedom/Swarm/Storage/StorageQuote.swift` |
| State machine (plan → payment → activating → done), single-flight buy, deposit card state | `Freedom/Swarm/Storage/StorageFundingController.swift` |
| UI (plan picker, payment card, activating, done) | `Freedom/Swarm/UI/StorageFundingView.swift` |
| Checklist (fund → sync → chequebook) | `Freedom/Swarm/UI/PublishSetupView.swift` |
| App wiring (`storageRPC`, `onActivated` → mode switch / reload) | `Freedom/FreedomApp.swift` |

## Decisions

- **Immutable batches.** A full mutable batch silently overwrites its
  oldest chunks; for published sites that is data loss, so the flow buys
  `immutable = true`. AntDrive buys mutable.
- **Presets stay the desktop ones** ("Try it out" 1 GB/7 d, "Small
  project" 1 GB/30 d, "Standard" 5 GB/30 d), priced live per plan.
- **Buy once, in Swift.** ant v0.5.47 has no guard against a second
  `ant_storage_buy_xdai` while one is running. `StorageFundingController`
  activates at most once per payment session; a failed buy drops back to
  the payment step with ant's message and needs a manual "Activate again".
- **No light / ultra-light mode.** ant has none any more: `light_mode` on
  `ant_start_gateway` is a label, the Gnosis RPC argument is the switch
  that makes ant build a chain client, and the installed chain transport
  routes that client's requests through the app's chain-data router.
  Freedom always passes the RPC (desktop #459 does the same), so the
  `BeeNodeMode` setting, the mode row, the post-buy restart and the
  startup `ant_deploy_chequebook` / `ant_storage_discover` calls are gone.
  A node that never bought storage pays nothing for it: ant's startup
  chain block only reads (a block number and two xBZZ log scans filtered
  by the node address — about nine `eth_getLogs` through the router on
  the simulator, each answered by the quorum in well under a second).
- **Gateway start never deploys.** It verifies persisted batches,
  rediscovers owned ones, and adopts a chequebook the node wallet ever
  funded. An account with batches but no chequebook (a deploy that ran
  out of gas, a reinstall whose old chequebook was never funded from the
  node wallet) shows "Settlement is off" on the chequebook card with a
  "Set up settlement" button (`ant_deploy_chequebook`).
- **The capability reason** dapps get for a node without a plan is
  `no-usable-stamps`, as on desktop; `ultra-light-mode` no longer exists.
- **`awaitConfirmation` reads the receipt.** A mined transaction has a
  block number whether it succeeded or reverted; the wallet's send flow
  now requires `status == 0x1` and surfaces `transactionReverted`.
- **Bee's 4xx bodies surface.** `BeeAPIClient.Error.rejected(status:message:)`
  carries bee's `{"message": …}` and every case is `LocalizedError`.

## Follow-ups

- A Rust-side single-flight guard would let the app drop `didAutoActivate`.
- ant: the running gateway's chequebook slot isn't updated by a C-API
  buy (hence `refreshChainState`); ant-23 is raising an ant fix.
