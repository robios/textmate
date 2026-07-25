# Claude Code bundle

Bundle commands that drive TextMate’s Claude IDE-context integration — the
WebSocket/MCP server that Claude Code discovers from the integrated terminal
or through its standard IDE lock file.

## Commands (Bundles → Claude Code)

| Command                 | Key       | What it does                                                        |
|-------------------------|-----------|---------------------------------------------------------------------|
| Send Selection to Claude| ⌥⌘K       | Pushes the selected line range into the connected CLI (`at_mentioned`) |
| Send File to Claude     | ⌥⇧⌘K      | Pushes a reference to the whole file                                 |
| Claude IDE Context Status| –        | Tool tip with IDE-context state, port, and Claude client count       |

Both send commands save the active file first — the agent reads from disk,
so what you reference is what it sees.

## Requirements

- `tm_agent` ships inside TextMate.app and is found via a symlink the app
  maintains at `~/Library/Application Support/TextMate/bin/tm_agent`
  (declared through this bundle’s `requiredCommands`).
- `claude` — the Claude Code CLI (`npm install -g @anthropic-ai/claude-code`).
  The send commands declare it as a requirement so TextMate offers an
  install hint if it is missing.

## Workflow

1. Open the integrated terminal (⌃`) and run `claude` — the terminal
   environment carries the bridge’s port, so the CLI connects to this
   TextMate instance automatically.
2. Select code and press ⌥⌘K (or use the menu items) to reference it in the
   CLI’s prompt.

If no CLI is connected the commands show a tool tip explaining what to do —
nothing is sent.

These commands are Claude-specific because `at_mentioned` and the discovery
lock file are part of Claude Code’s IDE protocol. Other agents use TextMate’s
provider-neutral `tm_agent mcp` route instead. See `AGENT_BUNDLE.md` at the
repository root for the design.
