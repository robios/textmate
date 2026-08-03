# Markdown Preview

*View → Show Markdown Preview* opens a live preview beside the editor for
Markdown documents. There is no key equivalent. The item is enabled for
Markdown files, and stays enabled while the pane is open so you can close it
from any tab.

The renderer is cmark-gfm with GitHub's extensions switched on: tables,
strikethrough, autolinks and task lists. Tables are styled the way GitHub's
documentation styles them — no outer frame, no vertical rules, a rule under the
header row, and horizontal scrolling inside the table rather than a squeezed
page. Explicit column alignment in the Markdown still wins, and a headerless
table does not get an empty header band.

The preview scrolls to follow the editor as you move through the document. It
stands down for a second whenever you scroll or click inside the preview
itself, so it does not fight you while you are reading, and it re-anchors after
a re-render so typing at the end of a document keeps the bottom in view.

Links open in your default browser. *Reload* in the preview's context menu
re-renders the buffer rather than reloading a page.

*Preferences → Projects → Show Markdown preview* chooses whether the pane sits
to the right of the text view or below it.

## Preview themes

By default the preview uses the editor's theme, so a dark editor gets a dark
preview. *View → Markdown Preview Theme* can give it its own:

* **Use Editor Theme** — the default. Clears every preview-specific choice
  below and follows the editor again.
* **Appearance → Light / Dark / Auto** — whether the preview follows the
  system appearance or is pinned. The *Light* and *Dark* entries are labelled
  with the theme they currently resolve to.
* **Theme for Light Appearance** and **Theme for Dark Appearance** — pick the
  theme used in each appearance, from the same list of installed themes the
  editor uses.

Each of these falls back to the editor's corresponding setting while it is
unset, which is why *Use Editor Theme* is simply "none of them are set" rather
than a theme of its own.

## tm_markdown

The same renderer is available as a command-line tool inside the app bundle, at
`TextMate.app/Contents/MacOS/tm_markdown`. Bundle commands get it as
`$TM_MARKDOWN`, so a bundle can produce HTML that matches the preview exactly
instead of shelling out to whatever Markdown tool happens to be installed.

```
Usage: tm_markdown [-hv] [file ...]
```

It reads the named files, or standard input when given none, and writes an HTML
*fragment* to standard output — no `<html>` wrapper and no stylesheet, since
the point is to embed it in something that has its own.
