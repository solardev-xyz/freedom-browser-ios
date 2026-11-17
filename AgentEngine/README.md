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
  - Chats are Pi conversations; the app keeps the list of chat IDs.
  - Models: OpenRouter, Anthropic, OpenAI, and a scripted offline one for tests.
    API keys stay in memory (pi-ai's `InMemoryCredentialStore`): the database
    stores which model a chat uses, never a key, so the app passes the keys
    (from the Keychain) on every open.
  - Approvals: desktop's three modes (`every_interaction`, `sensitive_actions`,
    `allow_website_interactions`) gate the website interactions in a
    `beforeTool` hook. In `sensitive_actions`, form submissions always ask and
    everything else goes to desktop's interaction-intent classifier
    (`classifier.js`, same prompt and contract), which lets an interaction run
    only when it's ordinary with confidence ≥ 0.85. The decision is stored with
    the tool call; after an approval, the element must still be what the user
    approved, or the call is blocked.
- `tools/page.js`: the browser tools, with desktop's names, parameters and
  descriptions: `browser_get_tab`, `browser_snapshot`, `browser_navigate`,
  `browser_click`, `browser_type`, `browser_select`, `browser_scroll`,
  `browser_press`, `browser_wait`. Not yet: tabs, frames, screenshots,
  uploads, downloads, dialogs, WebMCP.
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
```
