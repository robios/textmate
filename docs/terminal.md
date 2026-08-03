# Terminal

TextMate has a terminal pane in the document window, so the shell you run your
project's commands in is next to the code rather than in another application.

## The pane

*View → Show Terminal* (**⌃`**) opens it and gives it focus; the same key
closes it once it has focus. The pane holds several sessions and shows them in
its own status bar.

| Command                | Key   |
|------------------------|-------|
| New Terminal           | ⌃⇧`   |
| Next Terminal          | ⌃⌘]   |
| Previous Terminal      | ⌃⌘[   |
| Close Terminal         | —     |

These live under the **Terminal** menu. Closing a session that still has a
process running asks first, naming the process.

The shell is your login shell (`$SHELL`, or `/bin/zsh` if that is unset) and
the colours follow the editor theme — there is nothing to configure for either.
What you can configure is in *Preferences → Terminal*:

| Setting              | Options                                  |
|----------------------|------------------------------------------|
| Show terminal on     | Left side / Right side / Bottom          |
| Scrollback           | Lines to keep; 10000 by default          |
| Font                 | Any fixed-pitch font, via the font panel |

The pane's own status bar has the same three placement buttons, plus a button
for a new session.

File references in the output — the `path:line` shapes compilers and test
runners emit — are detected and open in the editor.

## Dragging into the terminal

Drop a file on the terminal and its path is pasted, shell-escaped, with a
trailing space, ready for you to finish the command. Several files at once
paste as several escaped paths. Nothing is executed, and nothing goes into the
editor.

Dragging text pastes the text verbatim. Dragging something that exists only as
a promise — a screenshot thumbnail, an image from a browser — writes it to a
temporary file first and pastes that path.

Pastes are sent in bracketed-paste mode when the program asks for it, so a CLI
running in the pane sees one paste rather than a burst of typing.

## Running bundle commands in the terminal

A bundle command normally runs in-process: TextMate captures its output and
does something with it — replaces the selection, opens an HTML window, shows a
tooltip. That is the wrong shape for anything long-running or interactive: a
dev server, a REPL, a test watcher, a CLI that wants a TTY.

`runLocation` is the command property that says so. It takes two values:

| Value       | Meaning                                              |
|-------------|------------------------------------------------------|
| `inProcess` | The default. TextMate runs the command and handles its output. |
| `terminal`  | TextMate hands the command to a new terminal session and stays out of the way. |

In the Bundle Editor it is the **Run in Terminal** check box, available for
commands and for drag commands. Ticking it greys out every control that only
makes sense for a captured command — input source and format, output location,
format and caret, and the rest — and a line under them names any of those
settings the command still carries but that will now be ignored.

A command that runs in the terminal always gets a fresh session; it never
lands in one you are working in. Its working directory is the current
document's directory, or the project directory. If the window has no terminal
pane, the command reports that instead of running somewhere unexpected.

## Launchers

*Terminal → Launchers* collects the commands whose whole purpose is to start
something in a terminal — a Rails console, a REPL, a watcher — so they are
where you look for a terminal rather than buried in their bundle's menu.

A command appears there when it both sets `runLocation` to `terminal` and
carries the semantic class `terminal.launcher` (or something more specific
beneath it, such as `terminal.launcher.rails`). Scope selectors still apply, so
the list follows the language you are in. With nothing to show, the submenu
says *No Launchers*.

The Terminal menu also has **New Claude Code Terminal** and **New Codex
Terminal**, which start those agent CLIs in a session that can already see the
window's editor context — see [AI companion](ai-companion.md).
