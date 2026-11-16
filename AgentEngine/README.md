# Agent engine (spike)

Pi's agent runtimes bundled for WebKit. Freedom runs the bundle in a hidden
WKWebView (`Freedom/Freedom/Agent/AgentEngine.swift`).

```sh
cd AgentEngine && npm ci && npm run build   # bundle into the app's resources
npm run check                               # kill-and-reopen check under Node
```

The build writes `Freedom/Freedom/Resources/agent-engine/agent-engine.{js,html}`,
which git ignores. Run it again after changing `src/` or the Pi versions. The
Pi packages are pinned to exact versions: `@earendil-works/pi-durable` says its
API changes without notice between releases, so upgrade them together and run
`npm run check` afterwards.

- `src/bridge.js`: engine ↔ app messages (`freedomAgent` handler, `window.__freedomAgent.command`).
- `src/net.js`: every http(s) fetch goes through the app's URLSession via
  `freedom-agent://engine/net`, so providers without browser CORS answer and
  server-sent events stream.
- `src/durable.js`: the durable agent. Pi's durable runtime stores every step
  before showing it, so a run the app was killed during continues when the app
  reopens. Tools: `read_page`, and `send_tip`, a stand-in for a wallet action
  that sends nothing. Sensitive tools wait for the user's approval (a
  `beforeTool` hook); the decision is stored with the call, and an approval
  still pending when the app dies is asked again. The model is scripted
  (offline, deterministic), so restarts can be tested without a provider.
- `src/sqlite.js`: Pi's storage runs on a SQLite file the app owns
  (`Application Support/Agent/agent-spike.sqlite`, `AgentDatabase.swift`);
  each statement crosses the bridge.
- `src/main.js`: the engine's commands: the bare loop (`run`, with
  `@earendil-works/pi-agent-core`) and its providers `faux`, `ollama`,
  `openrouter`, `anthropic`, `openai`; the durable agent (`durableOpen`,
  `durableSubmit`, `durableApprove`, `durableTranscript`, `durableAbort`);
  diagnostics (`info`, `netCheck`, `timerCheck`).

The engine's web view sits in the app's window, invisible: iOS WebKit counts a
web view outside any window as a hidden page and fires its timers about a second
late (40 × 50 ms took 30 s instead of 2), and Pi's streaming and commits run on
timers.

In a DEBUG build, the menu's "Agent (spike)" opens a test bench;
`FREEDOM_DEBUG_SHOW=agent` opens it at launch. The other launch switches are
listed at the top of `AgentSpikeView.swift`; the kill-and-reopen sequence:

```sh
# Run, then SIGKILL the app while the answer streams:
FREEDOM_DEBUG_SHOW=agent FREEDOM_DEBUG_OPEN_URL=https://example.com/ FREEDOM_DEBUG_AGENT_DURABLE=fresh \
  FREEDOM_DEBUG_AGENT_PACE=10 FREEDOM_DEBUG_AGENT_DELAY=4 FREEDOM_DEBUG_AGENT_DURABLE_PROMPT="What is the page I have open about?"
# Relaunch: the run continues.
FREEDOM_DEBUG_SHOW=agent FREEDOM_DEBUG_AGENT_DURABLE=open
```

(as `SIMCTL_CHILD_…` variables for `xcrun simctl launch`).
