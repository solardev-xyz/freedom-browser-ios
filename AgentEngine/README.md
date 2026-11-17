# Agent engine

Freedom Agent's engine: Pi's agent runtime bundled for WebKit, plus the
script the agent's browser tools run in a tab. The app runs the engine in a
hidden WKWebView (`Freedom/Freedom/Agent/AgentEngine.swift`) and injects the
page script into the user's tab (`AgentPageDriver.swift`).

```sh
cd AgentEngine && npm ci && npm run build   # bundle into the app's resources
npm run check                               # kill-and-reopen + approval checks under Node
```

The build writes `Freedom/Freedom/Resources/agent-engine/` (`agent-engine.{js,html}`
and `agent-page.js`), which git ignores. Run it again after changing `src/`,
`page/` or the Pi versions. The Pi packages are pinned to exact versions:
`@earendil-works/pi-durable` says its API changes without notice between
releases, so upgrade them together and run `npm run check` afterwards.

## Engine (`src/`)

- `agent.js`: Freedom Agent. Pi's durable runtime (`pi-durable`) stores every
  step before showing it, so a run the app was killed during continues when
  the app reopens: a streaming answer is requested again, a read-only tool runs
  again, a page action the app died during reports "interrupted" to the model
  instead of repeating, and an approval still pending is asked again.
  - Asking first (`askBeforeResuming`, Florian 2026-11-17): at launch, and
    when the engine was stopped in the background, the app opens the agent
    without continuing; `interrupted()` lists the chats (from
    `harness.inspect()`, which runs nothing), the sheet asks "Continue" or
    "Stop", and `resumeInterrupted(proceed)` continues them or aborts their
    runs with `abortTask` (which, unlike `Conversation.abort`, doesn't start
    scheduling) before `resume()`. Sending or stopping in the meantime stops
    them first. A restart after the engine's process crashed continues
    without asking. In the background, a working run gets iOS's background
    time (about 30 s); still working when it ends, the engine stops as if
    killed (AgentService), and coming back asks.
  - Chats are Pi conversations; the app keeps the list of chat IDs.
  - Models: OpenRouter, Anthropic, OpenAI, and a scripted offline one for tests.
    API keys stay in memory (pi-ai's `InMemoryCredentialStore`): the database
    stores which model a chat uses, never a key, so the app passes the keys
    (from the Keychain) on every open.
  - Approvals: desktop's three modes (`every_interaction`, `sensitive_actions`,
    `allow_website_interactions`) gate the website interactions in a
    `beforeTool` hook. `sensitive_actions` is looser than desktop's (Florian,
    2026-11-17: the agent acts in the user's own browser, so only what sends,
    buys or commits something asks): typing, choosing, scrolling, keys that
    don't submit and links to another page run; form submissions and other
    clicks go to desktop's interaction-intent classifier (`classifier.js`,
    desktop's output contract with an iPhone prompt), and ask when it calls
    them consequential, or when it can't tell for a form. The decision is stored with
    the tool call; after an approval, the element must still be what the user
    approved, or the call is blocked.
- Conversation privacy (desktop's session-privacy.js ledger): every model
  request attempt, the agent's (`beforeProviderRequest`) and the interaction
  classifier's (`onPayload`), is sent to the app as a `privacy_request` event
  with provider, model, destination origin, role, claim and zero-retention
  state; the app keeps the per-chat record (AgentPrivacy.swift,
  Application Support/Agent/privacy.json) and shows it from the agent sheet.
  Desktop's hardware attestation and end-to-end encryption checks aren't here.
- `mcp.js`: connected services (desktop's mcp-connections.js and
  pi-mcp-tools.js): remote MCP servers over Streamable HTTP with
  `@earendil-works/pi-mcp`, public or with OAuth (dynamic client
  registration, PKCE; the app opens the sign-in page in
  ASWebAuthenticationSession with the redirect `com.browser.freedom:/mcp-oauth`
  and keeps the OAuth state in the Keychain, AgentMcp.swift). The model gets
  desktop's two tools, `mcp_discover` and `mcp_request`; every request asks
  (agent.js `mcpGate`), in every mode. Discovery matches the query's words,
  not the whole query (desktop's substring match found nothing for the
  phrases models send). No GET stream, no local (stdio) servers. pi-mcp is
  written for Node: build.mjs gives its modules a small Buffer and
  node:crypto (src/shims/) and stubs its process and loopback-server imports.
- `tools/page.js`: the browser tools, with desktop's names, parameters and
  descriptions: `browser_get_tab`, `browser_list_tabs`, `browser_create_tab`,
  `browser_focus_tab`, `browser_close_tab`, `browser_snapshot`,
  `browser_navigate`, `browser_click`, `browser_type`, `browser_select`,
  `browser_scroll`, `browser_press`, `browser_wait`, `browser_stop_loading`,
  `browser_screenshot`, `browser_target_point`, `browser_get_dialog`,
  `browser_handle_dialog`, `browser_list_frames`, `browser_read_frame`,
  `browser_download`, `browser_list_downloads`, `browser_upload`. Every call carries the chat's
  ID: each chat has its own tabs (the user's tab it started in, which a new
  message re-points to the tab the user is on, and the tabs it opened; it
  closes only those). Screenshots are JPEG images of the page's viewport for
  models that accept images; `browser_target_point` turns a point of the
  latest screenshot into a single-use reference for `browser_click`, valid
  while the viewport and DOM are unchanged, and that click always asks outside
  `allow_website_interactions` (desktop's `visual_effect_unknown`). A page's
  alert/confirm/prompt (`BrowserTab.pendingDialog`) blocks its scripts: page
  calls then fail with DIALOG_OPEN at once, an action that opens one returns
  it, and answering it always asks the user, in every mode. Embedded
  cross-origin frames: WebKit can't list a page's frames, so the tab keeps
  the frame handles its navigation delegate sees (`BrowserTab.subframes`);
  the driver probes which are alive and reads one with the page script run
  inside it, and its references (`frame_element_<key>_…`) route actions back
  to that frame. Downloads go through Freedom's download manager (receipts,
  never paths; the chat's list in UserDefaults `agent.chatDownloads`);
  uploads open a picker on the agent's sheet (photo library or Files) and the
  page script puts the chosen file into the input (DataTransfer). Both always
  ask, in every mode, as on desktop. WebMCP doesn't exist in WebKit.
- `tools/wallet.js`: desktop's `wallet_transfer`. The app's `wallet` service
  (`AgentWallet.swift`) resolves the network, asset (symbol or contract) and
  recipient (address or name, as the Send form), checks balances and the fee,
  and shows the exact transfer on the agent's sheet; nothing is signed until
  the user slides to send. Replay `unsafe`: a transfer interrupted by a
  restart is reported, never sent again.
- `tools/attachments.js`: desktop's `attachment_list`, `attachment_read`,
  `attachment_render_page`. Files the user attaches in the composer (photo
  library or Files; 10 per message, 20 MB each, 50 MB in all, like desktop)
  live per chat in `Application Support/Agent/attachments`
  (`AgentAttachments.swift`). The message names them, and for a model that
  accepts images their images go along; the tools read bounded text, images,
  PDF text (PDFKit, 1–4 pages) and PDF pages as images.
- `tools/node.js`: desktop's `node_status`, `node_request`,
  `node_diagnostics`, `swarm_publish`, `swarm_publication_status` on the
  phone's nodes (`AgentNodes.swift`): status of Swarm (Ant), IPFS, Radicle
  and Myotis; raw requests to Ant's Bee-compatible API at 127.0.0.1:1633
  (reads run, anything else asks); a node's own log (asks; the app's home
  folder shows as ~); publishing an attachment or bounded text, public only
  (no drafts or stable addresses on iPhone yet), always asked with the
  storage it uses. `skills/`: desktop's swarm-publishing and swarm-postage
  skills adapted to the phone, read with `skill_read`.
- `classifier.js`: desktop's interaction-intent classifier.
- `page-check.js`: scripted checks of the browser tools on real sites, no model.
- `bridge.js`: engine ↔ app messages (`freedomAgent` handler, `window.__freedomAgent.command`).
- `net.js`: every http(s) fetch goes through the app's URLSession via
  `freedom-agent://engine/net`, so providers without browser CORS answer and
  server-sent events stream.
- `sqlite.js`: Pi's storage runs on a SQLite file the app owns
  (`Application Support/Agent/agent.sqlite`, `AgentDatabase.swift`); each
  statement crosses the bridge.
- `main.js`: the engine's commands: the agent (`agentOpen`, `agentCreateChat`,
  `agentSubmit`, `agentView`, `agentApprove`, `agentAbort`, `agentSummaries`,
  `agentSetKey`, `agentSetApprovalMode`); the test bench's bare loop (`run`,
  `@earendil-works/pi-agent-core`); diagnostics (`info`, `netCheck`,
  `timerCheck`, `pageCheck`).

## Page script (`page/`)

Runs in the tab's isolated content world ("FreedomAgent"), injected on first
use per document, so page scripts can neither see nor call it.

- `desktop-page.js`: desktop's page-side functions, copied unchanged (snapshot,
  element references, state checks, select). Keep it identical to desktop.
- `index.js`: input. Desktop clicks and types with OS-level events; a WKWebView
  can only dispatch events from script (`isTrusted` false). So a click is the
  event sequence of a tap (pointer, touch, compatibility mouse events, focus,
  click), typing goes through `execCommand("insertText")` (falling back to the
  value setter plus an `input` event), and a key press also performs the
  browser's default action for that key (implicit form submission on Enter,
  focus moves on Tab, …). Results are returned as JSON text: WebKit refuses
  some values otherwise.

## Notes

- The engine's web view sits in the app's window, invisible: iOS WebKit counts
  a web view outside any window as a hidden page and fires its timers about a
  second late (40 × 50 ms took 30 s instead of 2), and Pi's streaming and
  commits run on timers.
- `AgentEngine.pageDriver` is a reference, not a closure: an async closure
  with arguments stored there miscompiled with this target's concurrency
  settings (the method string arrived as garbage).

## Testing in the simulator (DEBUG builds)

`AgentService` and the test bench read `SIMCTL_CHILD_…` launch variables:

```sh
# The agent sheet with a real model, a question asked at launch, approvals answered:
FREEDOM_DEBUG_SHOW=agent FREEDOM_DEBUG_OPEN_URL=https://en.wikipedia.org/ FREEDOM_DEBUG_AGENT_DELAY=5 \
  FREEDOM_DEBUG_AGENT_SETUP=openrouter:anthropic/claude-haiku-5.5 FREEDOM_DEBUG_AGENT_KEY=<key> \
  FREEDOM_DEBUG_AGENT_MODE=sensitive_actions FREEDOM_DEBUG_AGENT_APPROVE=yes \
  FREEDOM_DEBUG_AGENT_ASK="Search Wikipedia for swarm intelligence"

# The browser tools on real sites, without a model (the test bench):
FREEDOM_DEBUG_SHOW=agent-bench FREEDOM_DEBUG_OPEN_URL=https://example.com/ FREEDOM_DEBUG_AGENT_DELAY=4 \
  FREEDOM_DEBUG_AGENT_PAGECHECK=all
# Also: FREEDOM_DEBUG_AGENT_RESUME=continue|stop answers the "continue?" question after a
# kill or a stop in the background; FREEDOM_DEBUG_AGENT_BACKGROUND_SECONDS=<n> ends the
# background time after n seconds.
```
