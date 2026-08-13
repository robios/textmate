# Preview

*View → Show Preview* opens a live preview beside the editor. There is no key
equivalent. The item is enabled whenever the document has a preview — Markdown
out of the box, any other format whose bundle declares a
[`previewCommand`](#other-formats--previewcommand) — and stays enabled while
the pane is open so you can close it from any tab.

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

*Preferences → Projects → Show preview* chooses whether the pane sits to the
right of the text view or below it.

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
preview. *View → Preview Theme* can give it its own:

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

## Other formats — `previewCommand`

Markdown is the built-in case of a general mechanism: the pane resolves a
*converter* for the document's file type. A bundle can plug any format in by
declaring a `previewCommand` in a Preferences (settings) item with a scope
selector:

    previewCommand = "\"${TM_RUBY:-ruby}\" \"$TM_BUNDLE_SUPPORT/bin/latex_preview.rb\"";

Resolution order for a document's file type:

1. A `previewCommand` declared for the scope — external converter. This wins
   even for a Markdown scope, so the built-in renderer is a default, not a
   special case.
2. The scope has prefix `text.html.markdown` — the built-in cmark renderer.
3. Neither — the document has no preview and the menu item is disabled.

### The converter contract

The command is run with `/bin/sh -c`, with the working directory set to the
document's directory (the home directory for an unsaved document). It receives
the **full buffer contents** on stdin — unsaved changes must preview — and
writes a UTF-8 HTML **fragment** to stdout: no `<html>`, `<head>`, `<body>`,
no stylesheet. This is the same fragment contract as `tm_markdown` below.

Block-level elements should carry `data-sourcepos="SL:SC-EL:EC"` (cmark's
format, 1-based). Scroll sync reads the leading integer — the start line — and
click-to-jump posts the start position back to the editor, so a converter that
emits only `data-sourcepos="N:1-N:1"` on paragraphs and headings already gets
useful sync. Elements without the attribute degrade gracefully.

Math uses the shared markup described [above](#math): `data-tm-math` elements
whose text content is the HTML-escaped TeX source, rendered by the pane's
KaTeX pass, plus the optional `tm-katex-macros` element.

The environment is deliberately **not** the full command environment — a
converter is a pure document transform, so there is no selection and no
caret. It consists of the app's base environment plus:

| Variable            | Value |
|---------------------|-------|
| `TM_DISPLAYNAME`    | the document's display name |
| `TM_BUNDLE_SUPPORT` | the declaring bundle's Support directory, if it has one |
| `TM_PREVIEW`        | `1` |
| `TM_FILEPATH`       | the document's path — saved documents only |
| `TM_DIRECTORY`      | the document's directory — saved documents only |

### Execution and failure

External converters re-render 0.5 s after the last change (the in-process
Markdown path uses 0.25 s), and also on save — the buffer is unchanged then,
but the converter may want to read the saved file. A newer render terminates
the previous converter's whole process group (pipelines and helper processes
included), as does closing the pane or the previewed document. A run is
forcibly terminated after 10 seconds; stdout is capped at 16 MB and stderr at
1 MB, and stdout must be valid UTF-8.

The run ends with the group, not with your command: anything still in it when
your command exits is sent the same SIGTERM and, half a second later, SIGKILL.
A helper meant to outlive one render therefore has to leave the group of its
own accord (`setsid`), and is then yours to manage.

When a run fails — nonzero exit, timeout, kill, launch failure, invalid
UTF-8, output overflow — the pane shows a small ⚠︎ in its header: the tooltip
carries the first lines of stderr, and clicking it opens the full (bounded)
diagnostic — a summary line plus the captured stderr — in TextMate's HTML
output window, titled after the previewed document. The failure also goes to
the log. There is no modal and no content flash.

A failure never paints content of its own, and what happens to the content
already on screen depends on whose it is. While the failing render is for the
document the pane is already showing, the last good render stays put — a
transient converter error must not blank the page you are reading. But when
the pane was just switched to a different document and that document fails
before producing any good render, the page is cleared: the previous
document's body must not sit under the new document's header.

A converter runs only while the preview pane is open — never on merely
opening a file — and closing the pane kills it. `previewCommand` executes
bundle-provided code at the same trust level as every bundle command.

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
