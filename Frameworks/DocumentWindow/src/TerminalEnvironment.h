#ifndef TERMINAL_ENVIRONMENT_H_QZ4M8XKD
#define TERMINAL_ENVIRONMENT_H_QZ4M8XKD

#include <map>
#include <string>

// The integrations every terminal TextMate spawns is expected to carry: `mate`
// on PATH, TM_AGENT_BRIDGE for anything that can register an MCP server, and,
// while the bridge runs, the Claude IDE-context variables. A
// terminal opened for a bundle command starts from that command’s environment
// rather than from the window’s, and after the script finishes the tab lives on
// as an ordinary interactive shell — without these it would quietly differ from
// every terminal the user opens themselves.
//
// Two rules make it safe to apply early, before requiredCommands is checked
// against the environment the session will actually get:
//
//  * The base wins. Integration variables are only inserted when absent, so a
//    bundle or .tm_properties can deliberately override or disable one, and the
//    TM_MATE directory is appended at *lower* PATH precedence than anything the
//    command brought.
//  * It is idempotent. Applying it twice adds no duplicate PATH component and
//    changes no value.
//
// Deliberately process-global only: no document or project variables, so this
// can run before an application-level command has a window at all.
std::map<std::string, std::string> TerminalEnvironmentByAddingExtras (std::map<std::string, std::string> environment);

#endif /* end of include guard: TERMINAL_ENVIRONMENT_H_QZ4M8XKD */
