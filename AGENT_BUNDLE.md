# tm_agent and the Claude Code bundle

Step 3 of the AI-companion roadmap: bundle commands drive the agent bridge
through a small CLI, so pushing editor context into a connected agent CLI is
one keystroke.

```
bundle command ──(TM_AGENT env)──▶ tm_agent ──(mate socket)──▶ RMateServer
                                                                   │ main thread
                                                             AgentBridge
                                                                   │ WebSocket (MCP)
                                                             claude CLI (at_mentioned)
```

## tm_agent

A small CLI embedded in `TextMate.app/Contents/MacOS/`. It is
protocol-agnostic towards the agent: it talks to the *agent bridge* in the
running app, which forwards to whatever client is connected.

```
tm_agent mention --file <path> [--line-start <n>] [--line-end <n>]
tm_agent status
```

- `mention` — TextMate broadcasts an `at_mentioned` notification (the Claude
  Code IDE protocol’s “reference this in the prompt”) to connected clients.
  Line numbers are **0-based**, matching the wire protocol. Omitting both
  references the start of the file; `--line-start` alone references a single
  line. Relative paths are made absolute against the caller’s cwd.
- `status` — prints `bridge: running|stopped`, `port: N`, `clients: N`.

Exit codes: `0` success (for `status`: bridge running), `1` request rejected
by TextMate (bad path, bridge stopped, no client connected — message on
stderr), `2` bridge stopped (`status` only), `64` usage error, `69` TextMate
not running.

`tm_agent` never launches TextMate: a mention only makes sense against a
live editor session.

## Transport: the mate socket

`tm_agent` reuses the UNIX domain socket that the `mate` CLI already uses
(`/tmp/textmate-$UID.sock`, served by `Applications/TextMate/src/RMateServer.mm`).
Two new record types, `agent-mention` and `agent-status`, ride the existing
line-based framing (`command\r\n`, `key: value\r\n`…, `\r\n`, `.\r\n`); the
app answers with `key: value` lines and closes the connection.

Why this transport, considering the alternatives:

- **mate socket (chosen)** — an always-on listener the app already owns,
  with an extensible command/arguments framing and a parser that runs on the
  main queue (so AgentBridge is reached on the main thread for free). Adding
  two record types means no new attack surface and ~40 lines of glue.
- **WebSocket client to the bridge itself** — wrong role: the bridge
  authenticates *agent* clients via the auth token in `~/.claude/ide/*.lock`,
  and a tm_agent connection would be indistinguishable from an IDE client.
  tm_agent must work without knowing auth tokens.
- **Mach service (tm_dialog2 precedent)** — the `com.macromates.dialog`
  service belongs to the Dialog plugin; registering a *new* Mach service
  just for this would add a second always-on listener where one already
  suffices.

Caveat (pre-existing, shared with `mate`): production TextMate and the dev
build both bind the same socket path — whichever launched last owns it.

## App-side wiring

- `RMateServer.mm` routes records whose command starts with `agent-` to
  `[AgentBridge handleCLIRequest:arguments:]` and writes the returned pairs
  back. Transport knowledge stays in RMateServer; bridge knowledge stays in
  AgentBridge.
- `AgentBridge.mm` implements the two commands: `agent-status` reports
  `running`/`port`/`clients`; `agent-mention` validates the path (absolute,
  exists), the 0-based line range, and that a client is connected, then
  calls the existing `sendAtMentionedWithFilePath:lineStart:lineEnd:` path.
- `AgentBridgeServer` gained `connectedClientCount` (synchronizes with the
  server queue).
- On launch, AgentBridge maintains a symlink
  `~/Library/Application Support/TextMate/bin/tm_agent` → the embedded
  binary, giving bundles a stable path independent of where the app lives.

## Claude Code bundle

Source lives in `Bundles/Claude Code.tmbundle/`; the app build rsyncs it
into `TextMate.app/Contents/SharedSupport/Bundles/` (a bundle discovery
location — `Frameworks/bundles/src/locations.cc`), so it ships with the app
and needs no separate install.

Commands (menu: Bundles → Claude Code; see the bundle’s README.md):

- **Send Selection to Claude** (⌥⌘K) — saves the file, measures the selected
  line range (selection input, falls back to the whole document) and runs
  `"$TM_AGENT" mention` with the 0-based range.
- **Send File to Claude** (⌥⇧⌘K) — same for the whole file.
- **Agent Bridge Status** — tool tip from `tm_agent status`.

Key equivalents: nothing in `MainMenu.xib` binds K with any modifiers, and
no installed managed bundle uses `~@k`/`~@K` (plain `@k` is used by three
scope-limited items: Textile, Ruby RDoc, Markdown Raw — different chords).
⌥⌘K also matches Claude Code’s own “insert file reference” shortcut in
other IDEs.

`requiredCommands`: the bundle declares `tm_agent` (bundle-level, resolved
via the support-path symlink into `$TM_AGENT`) and the send commands declare
`claude` with an install hint (https://docs.anthropic.com/en/docs/claude-code/setup,
`npm install -g @anthropic-ai/claude-code`). Failure modes degrade to a tool
tip; when no client is connected the tip says to run `claude` in the
integrated terminal (⌃`) first.

## Dev iteration

- Editing the bundle source: `ninja -C build-debug` re-rsyncs it into the
  app (`--delete`, so removals propagate); relaunch TextMate to re-index.
- To iterate without rebuilding, copy the bundle to
  `~/Library/Application Support/TextMate/Bundles/` — user locations shadow
  SharedSupport (same UUIDs win by precedence).
- Unit tests: `Frameworks/AgentBridge/tests/t_agent_cli.mm` covers the CLI’s
  arg parsing and wire framing (shared header
  `Applications/tm_agent/src/agent_cli.h`);
  `Frameworks/AgentBridge/tests/protocol_smoke.py` is a fake agent client —
  connect it, run `tm_agent mention`, and it prints the received
  `at_mentioned` notification.

## Reusing the seam for other agents

Nothing in `tm_agent`, the socket records, or the bridge send path is
Claude-specific. A Gemini/Codex/aider-style CLI gets the same integration
by:

1. Connecting to the bridge’s WebSocket (port from
   `CLAUDE_CODE_SSE_PORT`/`ENABLE_IDE_INTEGRATION` in the integrated
   terminal’s environment, auth token from `~/.claude/ide/<port>.lock`) and
   speaking MCP — then `tm_agent mention` reaches it as `at_mentioned`,
   selections stream as `selection_changed`.
2. Optionally, a “Gemini” bundle that reuses `$TM_AGENT` verbatim — only
   names, key equivalents, and the `requiredCommands` entry for the CLI
   binary differ.

New IDE→CLI notifications should follow the same pattern: add the send path
to `AgentBridgeServer`, expose it in `handleCLIRequest:`, add a `tm_agent`
subcommand.
