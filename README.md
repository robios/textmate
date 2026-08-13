# TextMate 2.5

A continuation of [TextMate 2][upstream] for current macOS.

TextMate 2 is a fine editor whose upstream development stopped. This fork picks
it up: the build system is CMake and ninja, the external dependencies are gone,
the deprecated frameworks are off, and the things a 2020s editor is expected to
do — language servers, completion, diagnostics, an integrated terminal — are
built in. What has *not* changed is the part worth keeping: scopes, bundles,
snippets, grammars, themes and the `.tm_properties` settings system all work the
way they always did, and existing bundles keep working.

Requires macOS 14 (Sonoma) or later.

![The editor with the minimap, the Markdown preview on the right, and an agent
running in the terminal pane below](docs/images/overview.png)

## What is in it

**Language servers.** An LSP client with completion (⌥⇥), hover, go to
definition, find references, rename, code actions and formatting. Diagnostics
appear as squiggles, as counts in the status bar, in a minimap lane, and in a
workspace-wide diagnostics pane. A server takes one setting, `lspCommand`,
scoped like everything else in TextMate — or shipped as a default by the
language bundle. → [docs/lsp.md](docs/lsp.md)

**GitHub Copilot.** Inline suggestions as ghost text, off by default, driven by
`copilot-language-server`. → [docs/lsp.md](docs/lsp.md#github-copilot)

**Command palette.** ⇧⌘P over commands, symbols, recent projects, bundle items,
lines and editor settings, ranked by what you actually use. →
[docs/command-palette.md](docs/command-palette.md)

**Terminal pane.** A terminal in the document window, several sessions, drag
and drop, and a `runLocation` property so a bundle command that wants a TTY
gets one instead of having its output captured. →
[docs/terminal.md](docs/terminal.md)

**Preview pane.** A live preview beside the editor: cmark-gfm for Markdown
with GitHub-style tables and KaTeX math, scroll sync, its own theme or the
editor's — and the same renderer as a CLI for bundles to use. Other formats
plug in through a bundle-declared `previewCommand`. →
[docs/preview.md](docs/preview.md)

**Minimap.** With a source-control lane on one edge and a diagnostics lane on
the other. → [docs/minimap.md](docs/minimap.md)

**Bundle taps.** Subscribe to a bundle repository, or to a tap that publishes a
catalogue of them, and install straight from GitHub — with an explicit trust
model, because nothing fetched from GitHub is signed. →
[docs/bundle-taps.md](docs/bundle-taps.md)

**Reviewing changes.** A diff pane and a movable review base that the gutter,
the minimap and the file browser all follow — read twenty commits as one diff.
→ [docs/version-control.md](docs/version-control.md)

![The diff pane reviewing several commits against an older base, with the
minimap's change lane alongside](docs/images/diff-pane.png)

**AI companion.** A bridge that lets an agent CLI in the terminal pane see what
you have open — selection, open files, diagnostics — plus agent terminals for
Claude Code and Codex. → [docs/ai-companion.md](docs/ai-companion.md)

**Under the hood.** CMake and ninja in place of the old `rave` build; boost,
Cap'n Proto, sparsehash, ragel and multimarkdown all removed; the deprecated
`WebView` replaced with `WKWebView`; SwiftUI for the newer panels; and an
asset-catalog app icon for current macOS.

## Install

Builds are published on this repository's [releases page][releases], signed and
notarized. Download the archive and move `TextMate.app` to `/Applications`.

Otherwise build it yourself — it needs no dependencies beyond `cmake` and
`ninja`.

Once it is running, add the `robios/tm-bundles` tap under *Preferences →
Bundles*: a catalogue of language bundles maintained alongside this fork,
updated for its features where the official index has fallen behind. Adding
the tap installs nothing by itself — its bundles appear in the list and you
tick the ones you want. → [docs/bundle-taps.md](docs/bundle-taps.md)

## Building

```sh
git clone --recursive https://github.com/robios/textmate.git
cd textmate
make run
```

[docs/building.md](docs/building.md) has the prerequisites, the release build,
the CMake presets and the packaging steps.

## Documentation

[docs/](docs/README.md) covers what this fork adds or changes.

For TextMate itself — scopes and scope selectors, bundles, grammars, snippets,
commands, themes, `.tm_properties` — the [TextMate manual][manual] is still the
reference, and still accurate. Almost nothing in it has been invalidated here.

## Acknowledgments

**TextMate is Allan Odgaard's, at [MacroMates][macromates].** He wrote it,
opened its source, and designed the bundle and scope system that everything
here rests on. This fork is a continuation of [textmate/textmate][upstream] and
would not exist without it. TextMate is a trademark of Allan Odgaard.

**[tectiv3][tectiv3] carried it into the present.** This branch is built
directly on their fork: roughly 190 of their commits form its foundation, and
their authorship is preserved throughout the git history rather than squashed
away. That work includes

* the CMake and ninja build system, and the removal of every external
  dependency the old build needed,
* the LSP client framework — completion, hover, definitions, references,
  rename, code actions, formatting, the log panel, the status bar — together
  with the SwiftUI completion popup and panels it drives,
* the GitHub Copilot integration,
* the command palette,
* the migration from the deprecated `WebView` to `WKWebView`,
* the Formatters and Advanced preference panes,
* and a long tail of crash fixes, main-thread deadlock fixes and performance
  work — the least visible and most valuable part of it.

**Everyone else in the history.** Fixes from other upstream contributors are
cherry-picked into this branch as well. They are not named here individually
because `git log` credits them properly, which is the reason the history was
kept intact rather than flattened.

## License

GPL v3, the same as upstream: released under the GNU General Public License as
published by the Free Software Foundation, either version 3 of the License, or
(at your option) any later version. See [COPYING](COPYING) and the full text in
[LICENSE](LICENSE).

[upstream]:   https://github.com/textmate/textmate
[tectiv3]:    https://github.com/tectiv3/textmate
[macromates]: https://macromates.com/
[manual]:     https://macromates.com/textmate/manual/
[releases]:   https://github.com/robios/textmate/releases
