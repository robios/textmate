# Minimap

*View → Show Minimap* puts a scaled-down rendering of the whole document beside
the editor, with the visible region marked. It has no key equivalent, and it is
off by default; the setting is remembered per window state, not per document.

The minimap draws the text in the editor's theme colours. *Preferences →
Advanced → Disable minimap colors* renders it in uniform gray instead, if you
find the colour noise distracting.

## The two lanes

The map's edges carry two strips of information, one on each side, so a line
that is both changed and broken tells you both things at once:

* **Left — source control.** Added, modified and deleted lines relative to the
  review base (see [Version control](version-control.md) for what the base is
  and how to move it). These also tint the corresponding row of the map. Unlike the
  gutter's change marks, this lane is always drawn — the *Change marks*
  preference does not apply to it.
* **Right — diagnostics.** One marker per line a language server complained
  about, in the same colours as the squiggles: red for errors, amber for
  warnings, blue for notes. The markers are drawn a little taller than the
  change bars so a single-line diagnostic is not a speck, and when a line has
  several, the worst severity is the one you see. A multi-line diagnostic marks
  every line it crosses.

The right lane sits over the text rather than reserving space for itself, and
it never tints the row — tinting stays the change bars' job, so the two lanes
cannot be confused.

Diagnostic markers come from the buffer, not from a snapshot taken when the
server last published, so they follow your edits instead of drifting.
