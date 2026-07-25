#ifndef AGENT_SETUP_H_L9TQ3XB7
#define AGENT_SETUP_H_L9TQ3XB7

#import <Foundation/Foundation.h>

// Everything an agent CLI needs to reach TextMate’s editor context, in one
// place: where the bridge executable is, how to start Codex with it already
// registered, and the two snippets the AI preferences pane offers for copying
// — one for a Codex started outside TextMate, one for the project’s AGENTS.md.
//
// Deliberately snippet-only: nothing here writes to a user’s configuration.
@interface AgentSetup : NSObject
// The stable path to the tm_agent CLI (the symlink in Application Support,
// falling back to this app’s own copy). This is what a configuration file
// should name — the symlink survives the app moving.
+ (NSString*)commandLineToolPath;

// The codex executable: the global ‘codexCommand’ setting when set
// (Preferences → AI), otherwise a bare ‘codex’ for the shell to find on PATH.
// Global on purpose — one executable per machine, like copilotCommand; nothing
// here resolves it per project.
+ (NSString*)codexExecutable;

// The claude executable, same rule under the ‘claudeCommand’ setting.
+ (NSString*)claudeExecutable;

// A shell command line starting Claude Code. Nothing is injected: Claude finds
// TextMate through the lock file, and the terminal pane’s environment already
// carries CLAUDE_CODE_SSE_PORT — so this is the executable and nothing else.
// It exists so both agents are started the same way, from the same menu.
+ (NSString*)claudeLaunchCommandLine;

// A complete shell command line starting Codex with the TextMate MCP server
// registered through launch-time -c overrides, leaving the user’s own
// config.toml untouched. Quoted for the shell, so a path with spaces (or a
// quote) survives the trip.
+ (NSString*)codexLaunchCommandLine;

// The equivalent registration as a config.toml block, for a Codex the user
// starts in an external terminal.
+ (NSString*)codexConfigurationSnippet;

// House rules for a project’s AGENTS.md: when to ask TextMate for the current
// file, the selection, and diagnostics.
//
// Aimed at the CLIs that reach the editor through the `textmate` MCP server —
// **not** at a CLAUDE.md. Claude Code is *pushed* this context (the
// selection_changed notifications the bridge sends) and surfaces only part of
// the tool set to its model, so telling it to call `getCurrentSelection` names
// something it does not have.
+ (NSString*)agentsFileSnippet;
@end

#endif /* AGENT_SETUP_H_L9TQ3XB7 */
