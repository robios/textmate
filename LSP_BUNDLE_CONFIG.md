# LSP Configuration via Bundle Preferences

Language bundles can ship default LSP configuration, so installing e.g. a Go
bundle makes `gopls` work out of the box — no `.tm_properties` editing
required. Users can still override (or disable) everything from
`.tm_properties`.

## Item Format

Add a Preferences item (`.tmPreferences`, in the bundle's `Preferences/`
directory) whose scope selector targets the language and whose `settings`
dictionary carries the LSP keys:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>name</key>
	<string>Language Server</string>
	<key>scope</key>
	<string>source.go</string>
	<key>settings</key>
	<dict>
		<key>lspCommand</key>
		<string>gopls</string>
		<key>lspInitOptions</key>
		<string>{ "usePlaceholders": true }</string>
	</dict>
	<key>uuid</key>
	<string>…</string>
</dict>
</plist>
```

A working copy of this item lives at
`Frameworks/lsp/tests/fixtures/Go LSP.tmPreferences` (used by the unit
tests). No default server commands are shipped in the app itself.

## Supported Keys

| Key              | Type                 | Default | Meaning                                                            |
|------------------|----------------------|---------|--------------------------------------------------------------------|
| `lspCommand`     | string               | —       | Server command line; first token is the executable, rest are args. |
| `lspEnabled`     | boolean              | `true`  | Set to `false` to ship a command but leave it opt-in.              |
| `lspRootPath`    | string               | —       | Workspace root override; auto-detected when unset.                 |
| `lspInitOptions` | string (JSON)        | —       | JSON string passed as `initializationOptions` on `initialize`.     |

`lspInitOptions` must be a *string containing JSON* (matching the
`.tm_properties` representation), not a nested plist dictionary. Boolean
keys accept plist `<true/>`/`<false/>` as well as the strings
`"true"`/`"false"` (and `0`/`1`).

## Precedence

For each key independently, highest priority first:

1. **Settings machinery** — `.tm_properties` at any level, `Global.tmProperties`,
   and TextMate's environment-variable settings. Presence is what counts: an
   explicitly assigned value wins even if it is empty. In particular
   `lspCommand = ''` in `.tm_properties` disables a bundle-provided server
   (empty command has always meant “no language server”), and
   `lspEnabled = true` re-enables a server the bundle shipped disabled.
2. **Bundle Preferences item** — the highest-ranked item (by scope-selector
   specificity) matching the document's scope. Only consulted when the
   settings machinery does not define the key at all.
3. **Built-in default** — no server / enabled / auto-detected root / no
   init options.

Do not add `lsp*` keys to `Default.tmProperties`: assignments there count as
tier 1 and would permanently shadow every bundle's defaults.

Resolution happens in `Frameworks/lsp/src/LSPBundleSettings.cc`
(`lsp::setting_with_bundle_fallback`), called from `LSPManager`. The Copilot
keys (`copilotEnabled`, `copilotCommand`) intentionally do **not** get bundle
fallback — Copilot is not language-specific, so per-scope bundle defaults make
little sense there.
