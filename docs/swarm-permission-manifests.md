# Swarm permission manifests

Port of desktop Freedom's `src/main/swarm/permission-manifests.js`. Lets a Swarm-hosted app declare up front which `window.swarm` capabilities it needs, so the user answers one sheet instead of a prompt per action.

## The manifest

Served at the app's root: `bzz://<host>/freedom-manifest.json` (`<host>` is the content reference or the ENS name the page is loaded from). At most 8 KB. Exact keys only — an unknown field anywhere makes the manifest invalid.

```json
{
  "schema": "freedom-manifest/1",
  "name": "Notes",
  "description": "Keep notes on Swarm.",
  "capabilities": {
    "swarm": {
      "publish":   { "why": "Save your notes to Swarm." },
      "feeds":     { "why": "Keep an index of your notes." },
      "signing":   { "why": "Sign notes with an app-scoped key." },
      "messaging": { "why": "Share notes with other people." }
    }
  }
}
```

| Field | Rule |
| --- | --- |
| `schema` | must be `freedom-manifest/1` |
| `name` | 1–32 code points, no control / bidi characters |
| `description` | optional, ≤ 160 code points |
| `capabilities.swarm` | at least one of `publish`, `feeds`, `signing`, `messaging` |
| `<capability>.why` | 1–140 code points; shown verbatim under the browser's own label |

Browser labels are fixed: *Publish content*, *Manage feeds*, *Sign Swarm content*, *Send and receive messages*.

## What each capability turns on

"Allow all" projects the declaration onto the grants the ordinary prompts read:

| Capability | Projections (iOS) |
| --- | --- |
| `publish` | connection, auto-approve publish |
| `feeds` | connection, app-scoped feed identity, auto-approve feeds |
| `signing` | connection, app-scoped feed identity, auto-approve feeds |
| `messaging` | connection, messaging grant, auto-approve messaging |

Desktop lists a separate feed-grant flag and a separate signing auto-approve; on iOS the feed grant *is* the `SwarmFeedIdentity` row and feeds and signing share one tier, so they collapse. The identity mode chosen by a manifest is always app-scoped.

## Lifecycle

- **Discovery** happens on `swarm_requestAccess` only. Other grant-touching methods refresh a manifest the browser already knows; the permission-free reads never look. One check per page load and origin.
- **Consent**: the sheet lists added capabilities (and removed ones), then *Allow all* / *Connect, but ask each time* / *Don't allow*. Two tabs of one app share one consent. A token lives 5 minutes and dies when the manifest or the record changes underneath it.
- **Ownership**: the record remembers which capability turned on which projection. Removing a capability from the manifest withdraws only what it owned; a grant the user already had is never touched; a grant the user changes by hand is detached from the manifest for good.
- **Absent / invalid** manifest for a known app: managed grants are pruned, identity metadata stays. **Transient** failure (transport, 5xx, stalled body): grants stay, the origin's methods fail with 4900 until the backoff (2 s, 10 s, 30 s, 60 s) elapses.
- **Settings → Swarm → App permissions**: per app, each capability with *Allowed by manifest* / *Individual approvals*, an *Ask each time* button, and *Disconnect*.

Records persist in `Application Support/swarm-manifest-grants.json` with desktop's layout (`{version: 1, records: {origin: …}}`), including receipts of what each sheet showed (`rawHash` of the manifest bytes).

## Testing on the simulator

Publish a directory containing `index.html` and `freedom-manifest.json` through the node (Publish sheet or `swarm_publishFiles`), open the `bzz://<ref>/` it returns, and call `window.swarm.request({ method: 'swarm_requestAccess' })` from the page. The manifest sheet replaces the connect sheet; a page without the file gets the connect sheet as before.
