# AI Companion

Coding agents write a lot of code quickly, and the bottleneck moves to reading
it. So the support here is in two halves: **a review workflow** built on git,
for reading what changed, and **a context bridge**, so an agent CLI running in
the terminal pane knows what you are looking at.

There is no chat panel, no model picker, and nowhere to put an API key. The
agent runs in the terminal, as its own program; TextMate's job is to show it
the editor and to show you the diff.

## Reviewing changes

The reading half is the diff pane and the movable review base, and it is
ordinary version-control machinery — it works the same whether the commits
came from an agent or from you, so it has its own page:
[Version control](version-control.md). The short version: *View → Show Diff*
(**⌃⌥⌘G**) shows the hunks, **F4**/**⇧F4** step through them, and the status
bar's `Base:` pop-up moves the base back to whatever commit you want to review
against — which is what you want when an agent has made twenty commits and you
are reading the result rather than the last step.

## Editor context for agents

*Preferences → AI → **Enable Editor Context Sharing*** (on by default) lets an
agent ask TextMate what is open, what is selected, and what the language
servers are complaining about. The tools it exposes:

| Tool                  | Answers                                     |
|-----------------------|---------------------------------------------|
| `getCurrentSelection` | The selection in the front window            |
| `getOpenEditors`      | The open documents                           |
| `getWorkspaceFolders` | The project roots                            |
| `getDiagnostics`      | Diagnostics from the language servers        |
| `openFile`            | Opens a file in the editor                   |

Selections and diagnostics are capped so a large document cannot flood an
agent's context.

### Claude Code

Claude Code needs no configuration. TextMate runs the IDE-context service
Claude discovers on its own, and `/ide` inside Claude finds this window.
Started from *Terminal → **New Claude Code Terminal***, or from any session in
the integrated terminal, the connection is automatic — every terminal session
inherits the environment Claude looks for.

*Preferences → AI* shows the state (`IDE context active — /ide available — N
client(s)`) and lets you point at a `claude` executable other than the one on
`PATH`.

The app also ships a small **Claude Code** bundle, built in and not
uninstallable:

| Command                     | Key    |
|-----------------------------|--------|
| Send Selection to Claude    | ⌥⌘K    |
| Send File to Claude         | ⌥⇧⌘K   |
| Claude IDE Context Status   | —      |

These push a file-and-line reference into the connected CLI — the equivalent of
`@`-mentioning it in the prompt — so you can select code, press ⌥⌘K, and type
your question rather than describing where you are. The file has to be saved
first; the commands say so if it is not.

### Codex

TextMate speaks Codex's IDE-context protocol natively, so `/ide` in Codex
resolves to the window you are working in. This is a private protocol observed
against a specific Codex release, so treat it as best-effort: a Codex update
can change it.

*Terminal → **New Codex Terminal*** starts `codex` with both the IDE context
and TextMate's MCP tools configured **for that run only**, without touching
`~/.codex/config.toml`. For a Codex you start yourself, *Preferences → AI →
Copy config.toml Snippet* puts the equivalent `[mcp_servers.textmate]` block on
the clipboard.

Both agent terminals *type* the command line into a new session instead of
running it, so you can see and edit it before pressing Return.

### Any other MCP agent

`tm_agent mcp` is a stdio MCP server exposing the tools above. Register it with
whatever agent you use; its path is in `$TM_AGENT_BRIDGE` inside the integrated
terminal, and is otherwise

```
~/Library/Application Support/TextMate/bin/tm_agent
```

*Preferences → AI → **Copy AGENTS.md Guidance*** copies a block you can paste
into a project's `AGENTS.md`, telling the agent when it is worth asking
TextMate for the selection, the open editors or the diagnostics. Neither *Copy*
button writes to any file — they only fill the clipboard.

`tm_agent` also has two commands of its own, which is what the Claude Code
bundle uses:

```
tm_agent mention --file <path> [--line-start <n>] [--line-end <n>]
                 [--project <path>]
tm_agent status
```

Line numbers are 0-based, matching the wire protocol. `tm_agent` never launches
TextMate — a reference to what you are looking at only means something while
you are looking at it.

Which project window answers a request is decided by the working directory the
agent was started in, so an agent in one project cannot read another's
documents by accident. A mention is placed the same way unless `--project`
names an absolute path, which is how the bundle commands say which window they
were run from.

## GitHub Copilot

Copilot is the one AI feature that lives inside the editor rather than beside
it. It is off by default and needs a Copilot subscription and
`copilot-language-server`:

```sh
npm install -g @github/copilot-language-server
```

Turn it on in *Preferences → AI → Enable Copilot*, from the `sparkle` item in
the status bar, or with `copilotEnabled = true` in `.tm_properties`. If you are
not signed in, enabling it starts the sign-in: a dialog shows a device code —
already copied to your clipboard — and *Open Browser* takes you to GitHub to
enter it.

Suggestions then appear as ghost text about half a second after you stop
typing. **Tab** accepts, any other key dismisses, and **⌥⎋** (*Text → Copilot
Complete*) asks for one on demand. *Ghost text only (no popup)* in the AI pane
suppresses the popup when there are several suggestions.

See [Language servers](lsp.md#github-copilot) for the settings keys.
