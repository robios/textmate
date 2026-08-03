# Version control

The [TextMate manual][manual-vc] covers the basics that still hold: the file
browser badges files with their SCM status, and `TM_SCM_*` variables are there
for bundle commands. What this fork changes is how you *read* changes: the
gutter diff is computed in-process (no `git` subprocess per keystroke), the
minimap grew a source-control lane, and there is a diff pane with a movable
review base.

## The diff pane

*View → Show Diff* (**⌃⌥⌘G**) opens a pane listing every hunk in the current
document, in document order, rendered in the editor's font and theme with three
lines of context and both sets of line numbers. Double-clicking a row moves the
caret to that line in the editor.

The header says `<file> — N hunks`, plus `Unsaved` when the buffer differs from
disk and `Staged` when the index differs from the base. Its buttons close the
pane and step through hunks; **F4** and **⇧F4** (*Navigate → Jump to Next /
Previous Change*) do the same from the keyboard, and move the pane's selection
and the editor caret together. They work only while the pane is open.

Each hunk has a **Revert** button, and the header has **Revert All**. Revert
puts the lines back the way the base has them by *editing the buffer* — ⌘Z
undoes it — and deliberately leaves the git index alone: anything you had
staged stays staged and stays committable. There is no staging or unstaging
from this pane.

Only one side pane is shown at a time, so opening the diff pane closes the
diagnostics pane.

## The review base

Everything above — the diff pane, the gutter change marks, the minimap's
left-hand lane, and the file browser's SCM listing — is computed against a
**review base**, and the base is a pop-up in the status bar (`Base: HEAD`),
shown whenever the document is in a git repository.

The default base is `HEAD`, which gives you uncommitted changes: the usual
thing. Point it at an earlier commit and every one of those surfaces switches
to "what changed since then" — which is what you want when someone (or some
agent) has made twenty commits and you are reading the result rather than the
last step. The menu offers `HEAD`, `HEAD~1`, the previous HEAD when it is
known, and a list of recent commits with their subjects.

The base is per window and is not remembered across relaunches.

When HEAD moves under you, the pane says so rather than silently changing
meaning: a banner offers to review the range HEAD moved across, and a branch
switch or a rewrite resets the base to HEAD with an explanation.

*Preferences → Advanced* has two related settings:

| Setting        | Meaning                                                                                              |
|----------------|------------------------------------------------------------------------------------------------------|
| `Change marks:`| `Always` / `Only while the diff pane is open` (default) / `Never`. Full-height colour bars are the reviewing register; with the pane closed the gutter goes back to its classic `diff.*` icons. The minimap's lane is unaffected. |
| `Base commits:`| How many recent commits the review-base menu lists — 20 by default, `0` for none. A project can override it as `reviewBaseCommitLimit` in `.tm_properties`. |

Bundle commands see the current base as `TM_REVIEW_BASE`.

[manual-vc]: https://macromates.com/textmate/manual/version-control
