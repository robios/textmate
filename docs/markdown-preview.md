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

## Math

TeX math renders through [KaTeX](https://katex.org), which is vendored inside
the app — the preview works fully offline, nothing is fetched from a CDN. The
delimiters are GitHub's:

* **Display math** is block-position `$$…$$`: either a line whose only
  non-whitespace content is `$$…$$`, or a standalone `$$` line opening the
  block and another closing it, with the formula on the lines between. `$$`
  embedded in prose stays literal.
* **Inline math** is `$…$`, where the opening `$` is not followed by
  whitespace or a digit and the closing `$` is not preceded by whitespace.
  Empty spans don't count. The digit rule keeps prices like "$5 and $10" out
  of math.
* `\$` is a literal dollar sign.
* Code spans and code blocks (fenced or indented) are immune — a `$` inside
  them is never a delimiter.

Unsupported TeX renders as the source text in KaTeX's error color rather than
failing the page. Long display equations scroll horizontally inside their own
box, like wide tables.

Because the math pipeline lives in the shared renderer, `tm_markdown`
fragments now carry math as elements like
`<span data-tm-math="inline">\alpha_i^2</span>` (a `div` with
`data-tm-math="display"` for display math), whose text content is the
HTML-escaped TeX source. A page that embeds a fragment without loading KaTeX
shows the raw TeX as plain text.

A fragment may also carry macro definitions for KaTeX in a single

    <script type="application/json" id="tm-katex-macros">{"\\R": "\\mathbb{R}"}</script>

element — at most one per fragment, a JSON object mapping macro names to
replacement strings, which the preview passes to KaTeX as its `macros`
option. The JSON must be HTML-safe-serialized: every `<` in string values
encoded as `\u003c` (likewise U+2028/U+2029), so a value containing
`</script>` cannot terminate the element during HTML parsing. A malformed,
duplicate, or wrongly shaped element is ignored with a console warning; the
fragment itself still displays.

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
