# Documentation

These pages cover what this fork adds or changes. They assume you already know
TextMate, or are willing to look things up.

For TextMate itself — scopes and scope selectors, bundles, grammars, snippets,
commands and drag commands, themes, the `.tm_properties` settings system,
`mate` and `rmate` — the [TextMate manual][manual] remains the reference. It
has not been superseded: this fork changes very little about how any of that
works, and re-explaining it here would only produce a second, worse copy.

## Pages

* [Language servers](lsp.md) — configuring a server, completion, hover,
  diagnostics, definitions and references, rename, code actions, formatting,
  and GitHub Copilot
* [LSP bundle configuration](lsp-bundle-config.md) — for bundle authors: how a
  language bundle ships a default language server configuration
* [Minimap](minimap.md) — the map, and its source-control and diagnostics lanes
* [Terminal](terminal.md) — the terminal pane, launchers, and running bundle
  commands in a terminal
* [Preview pane](preview.md) — the preview pane, its themes,
  `tm_markdown`, and the `previewCommand` contract for other formats
* [Command palette](command-palette.md) — ⌃⌘C and what each mode searches
* [Bundle taps](bundle-taps.md) — subscribing to bundle repositories, the trust
  model, updates, and replacing an official bundle
* [Version control](version-control.md) — the diff pane, hunk navigation, and
  the movable review base behind the gutter and minimap change marks
* [AI companion](ai-companion.md) — giving an agent CLI the editor's context,
  agent terminals, and GitHub Copilot
* [Building](building.md) — prerequisites, build commands, presets, packaging

## Elsewhere in the repository

* [INTERNALS.md](../INTERNALS.md) — the core data structures
* [CONTRIBUTING.md](../CONTRIBUTING.md)

[manual]: https://macromates.com/textmate/manual/
