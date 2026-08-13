# Command Palette

*Navigate → Command Palette…* (⌃⌘C) opens a fuzzy-search field over the front
window. It is one field with several modes; the first character of the query
picks the mode.

| Prefix | Mode            | Searches                                                   |
|--------|-----------------|------------------------------------------------------------|
| (none) | Recent Projects | Projects you have opened before                             |
| `>`    | Commands        | Every enabled main-menu action and bundle command           |
| `@`    | Symbols         | Symbols in the current document                             |
| `#`    | Bundles         | Commands, grammars and snippets, opened in the Bundle Editor |
| `:`    | Go to Line      | A line number in the current document                       |
| `/`    | Find            | Lines of the current document containing the query          |
| `~`    | Settings        | Editor toggles — soft wrap, invisibles, line numbers, minimap, preview, diff pane, diagnostics pane, wrap column, indent guides, spell checking, scroll past end |

Delete the prefix to fall back to Recent Projects.

Notes on individual modes:

* **Commands** is built by walking the main menu at the moment the palette
  opens, so it reflects what is actually enabled for the current window, and
  each row shows the item's key equivalent. Bundle commands installed in the
  *Bundles* menu are included, and the current document also contributes a
  *Reveal in Finder* entry.
* **Symbols** uses the same symbol list as *Navigate → Jump to Symbol…*, which
  comes from the grammar's `symbolTransformation` — so how good it is depends on
  the language bundle. Separator entries are skipped.
* **Find** (`/`) searches the *current document* line by line, case
  insensitively, and stops at 50 matches; selecting a result jumps to that
  line. It does not open the *Find in Project* window.
* **Bundles** (`#`) does not run anything — it reveals the item in the Bundle
  Editor, which is what you want when you are editing bundles rather than using
  them.

Results are ranked by fuzzy-match score combined with how often and how
recently you picked them, so the entries you use settle at the top over time.
That usage record lives in
`~/Library/Application Support/TextMate/CommandPalette.db` and is keyed per
item, not per mode.

The palette is part of the Swift UI layer: a build made without `swift`
available does not have it (see [Building](building.md)).
