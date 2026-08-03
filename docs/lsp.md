# Language Servers

TextMate talks to language servers over LSP. There is no server bundled and
none is downloaded for you: you install the server, tell TextMate the command
to run it, and the editor features below light up for that file type.

## Configuring a server

`lspCommand` is the only setting a server needs. Put it in `.tm_properties`,
scoped the way you scope everything else in TextMate — per project, per file
type, or globally in `~/.tm_properties`:

```
# .tm_properties
[ *.go ]
lspCommand = gopls

[ *.rs ]
lspCommand = rust-analyzer

[ *.{c,cc,cpp,h,hpp,m,mm} ]
lspCommand = clangd

[ *.py ]
lspCommand = "pyright-langserver --stdio"

[ *.{sh,bash,zsh} ]
lspCommand = "bash-language-server start"

[ *.rb ]
lspCommand = ruby-lsp

[ *.lua ]
lspCommand = lua-language-server

[ *.swift ]
lspCommand = "xcrun sourcekit-lsp"
```

Quote the value when it has arguments — the first whitespace-separated token is
the executable and the rest are passed as arguments. The command is looked up
on the `PATH` TextMate knows about, which you set in *Preferences → Variables*
or in `.tm_properties`.

Servers that want configuration at startup take it as a JSON string in
`lspInitOptions`:

```
[ *.php ]
lspCommand     = "intelephense --stdio"
lspInitOptions = '{"licenceKey":"…","clearCache":true}'

[ *.py ]
lspCommand     = pylsp
lspInitOptions = '{"pylsp": {"plugins": {"pylsp_mypy": {"enabled": false}}}}'
```

For a TypeScript server living in the project rather than on `PATH`, point at
it through `$TM_PROJECT_DIRECTORY`:

```
[ *.{vue,ts,tsx,js,jsx} ]
lspCommand     = "$TM_PROJECT_DIRECTORY/node_modules/.bin/typescript-language-server --stdio"
lspInitOptions = '{ "plugins": [{ "name": "@vue/typescript-plugin", "location": "./node_modules/@vue/language-server", "languages": ["vue"] }] }'
```

### Settings

| Key                           | Default          | Meaning                                                                 |
|-------------------------------|------------------|-------------------------------------------------------------------------|
| `lspCommand`                  | none             | Command line for the server. Empty means no server.                      |
| `lspEnabled`                  | `true`           | Set `false` to keep a configured server switched off                     |
| `lspRootPath`                 | auto-detected    | Workspace root override                                                  |
| `lspInitOptions`              | none             | A *string containing JSON*, sent as `initializationOptions`               |
| `lspCodeActions`              | `true`           | Whether code actions (and the ⌘. binding) are offered                    |
| `lspFormatOnSave`             | `false`          | Ask the server to format the document before saving                      |
| `lspFileWatchExclude`         | none             | Comma-separated directory names to keep out of LSP file watching          |
| `lspDefinitionExcludePattern` | none             | Regex; when Go to Definition returns several locations, matching ones are ranked last |

### Bundle-provided defaults

A language bundle can ship a sensible default so that installing it is enough.
It does that with a Preferences item whose scope selector targets the language
and whose settings carry the LSP keys — see
[lsp-bundle-config.md](lsp-bundle-config.md) for the format.

Your own settings always win. Presence is what counts, so `lspCommand = ''` in
`.tm_properties` switches off a server a bundle provided, and `lspEnabled =
true` re-enables one a bundle shipped disabled. Only `lspCommand`,
`lspEnabled`, `lspRootPath` and `lspInitOptions` have this fallback.

## Status and troubleshooting

The status bar carries an **LSP** item showing the server for the current
document and its diagnostic counts. Click it for a menu:

* the server's name, with `(starting…)`, `(indexing…)` or `(not installed)`
  when that applies — or *LSP — No Server for This File Type*. The checkmark
  toggles the server for this file type, which is written into your global
  settings as `lspEnabled = false` for that scope.
* **Restart Server** — also the way to retry after installing a server whose
  command failed to launch.
* **Re-index Workspace**
* **Show Diagnostics** / **Hide Diagnostics**
* **Next Diagnostic** / **Previous Diagnostic**, when the document has any —
  the same commands as F5 / ⇧F5.

*Text → LSP → Debug Panel* opens the **LSP Log** window: JSON-RPC traffic,
server stderr, lifecycle events, filterable by server name or message text.
That is the first place to look when a server does not come up.

## Completion

**⌥⇥** (*Text → LSP → Complete*) asks the server for completions at the caret.
There is no automatic popup on trigger characters — completion happens when you
ask for it.

In the popup, ↑/↓ move, **Return** or **Tab** accepts, **Esc** dismisses.
Typing keeps it open and re-queries as long as you are still typing a word;
backspace does the same until the word is gone. If the server returns exactly
one candidate, it is inserted without showing the popup at all. Completions
that come back as snippets get tab stops.

Selecting an item fetches its documentation and shows it in a side panel.

## Hover

**⌃⌘H** (*Text → LSP → Show Hover Info*) shows what the server knows about the
symbol at the caret, rendered from the server's Markdown with syntax
highlighting. Hovering the mouse over a symbol does the same after a moment.

## Diagnostics

Diagnostics arrive from the server as you edit and are surfaced in several
places at once, so you can pick the one that suits what you are doing:

* **Squiggles** under the offending range, red for errors, amber for warnings,
  blue for notes. A zero-width diagnostic — a missing semicolon at end of
  line — still gets a short stub of squiggle so it is visible.
* **The status bar**, whose LSP item is a three-dot semaphore: errors,
  warnings and notes with their counts, dimmed when zero.
* **The minimap**, whose right-hand lane marks every diagnostic in the file —
  see [Minimap](minimap.md).
* **The diagnostics pane** — *View → Show Diagnostics* — a list of every
  problem the servers have reported across the window's workspace, grouped by
  file, including files you never opened. A segmented control filters it to
  *Errors* only; selecting a row jumps to it.
* **The lightbulb** in the gutter, on a line that has a diagnostic the server
  offers a code action for.

To read one: point at a squiggle and wait a moment, or press **⌃⌘H** with the
caret on it — the popup shows the diagnostic message along with whatever hover
information the server has.

**F5** and **⇧F5** (*Navigate → Jump to Next / Previous Diagnostic*) walk
through them, in the same family as the F2/F3/F4 jumps for bookmarks, marks and
changes. They are disabled in a document that has no diagnostics.

The gutter itself is not used for diagnostics: clicking a line still sets a
bookmark, whatever the server thinks of that line.

## Navigation and refactoring

| Command                | Key   | Notes                                                        |
|------------------------|-------|--------------------------------------------------------------|
| Go to Definition       | ⌥⌘D   | Also ⌘-click. With several results, `lspDefinitionExcludePattern` pushes the noisy ones down. |
| Find References        | ⌃⌘R   | Results in a panel                                            |
| Rename Symbol          | ⇧⌘R   | Renames inline, with a preview of the edits across the workspace |
| Code Actions           | ⌘.    | Quick fixes and refactorings at the caret. An amber lightbulb appears in the gutter on the caret's line once the server has confirmed it has something to offer; clicking it does the same as ⌘. Set `lspCodeActions = false` to switch both off. |

All of these live under *Text → LSP*, and are disabled when the document has no
language server.

## Formatting

*Text → Format Code / Selection* formats the document, or the selection if
there is one. It prefers an external formatter and falls back to the language
server when none is configured. *Text → LSP → Format Document / Selection* is
the same thing but always goes to the server. Neither has a key equivalent.

### External formatters

`formatCommand` is a shell command that reads the document on stdin and writes
the formatted text to stdout. The usual TextMate variables (`TM_FILEPATH`,
`TM_TAB_SIZE`, `TM_SOFT_TABS`, …) are available, and the working directory is
the project root so the tool finds its own config file.

```
# .tm_properties
[ *.{js,jsx,ts,tsx} ]
formatCommand = "prettier --parser=typescript"

[ *.py ]
formatCommand = "black -q -"

[ *.rs ]
formatCommand = rustfmt

[ *.{c,cc,cpp,h,hpp,m,mm} ]
formatCommand = clang-format
```

*Preferences → Formatters* is the same thing without the text file. It lists
known formatters against file-type globs — swiftformat, prettier, black, gofmt,
rustfmt, clang-format, rubocop — with a *Status* column saying whether the
executable was found on your search paths, an editable *Command* column, and a
**Re-detect** button. These entries apply only when `.tm_properties` does not
set `formatCommand` for the file; the pane says as much.

**`formatOnSave` defaults to on whenever a `formatCommand` is in play**,
including one that the Formatters pane detected for you. Set
`formatOnSave = false` for a file type you would rather format by hand:

```
[ *.py ]
formatOnSave = false
```

### Server formatting

For file types with no `formatCommand`, `lspFormatOnSave = true` asks the
language server to format before saving instead. It is a separate switch from
`formatOnSave`, and the request is given half a second before the save goes
ahead unformatted, so a slow server delays nothing.


## GitHub Copilot

Copilot is off by default and needs a Copilot subscription plus the language
server:

```sh
npm install -g @github/copilot-language-server
```

Enable it from the Copilot item in the status bar or in *Preferences → AI*, or
set it in `.tm_properties` — it is scoped like anything else:

```
# ~/.tm_properties — everywhere
copilotEnabled = true

# or per file type
[ *.md ]
copilotEnabled = true
```

| Key                    | Default       | Meaning                                                    |
|------------------------|---------------|------------------------------------------------------------|
| `copilotEnabled`       | `false`       | Turn Copilot on for matching files                          |
| `copilotCommand`       | auto-detected | Path to `copilot-language-server`, when it is not on `PATH` or in the usual node module directories |
| `copilotGhostTextOnly` | `false`       | Always render the first suggestion as ghost text instead of showing a popup when there are several |

With it on and signed in, suggestions appear as ghost text about half a second
after you stop typing. **Tab** accepts, any other keystroke dismisses.
**⌥⎋** (*Text → Copilot Complete*) asks for a suggestion explicitly. The
Copilot status item's menu has *Restart Server* and *AI Settings…*; see
[AI companion](ai-companion.md).
