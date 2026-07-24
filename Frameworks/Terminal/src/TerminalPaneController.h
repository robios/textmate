#ifndef TERMINAL_PANE_CONTROLLER_H_C4F0912B
#define TERMINAL_PANE_CONTROLLER_H_C4F0912B

#import <Cocoa/Cocoa.h>
#include <map>
#include <string>

@class TerminalGridView;

// The integrated terminal pane: hosts any number of terminal sessions
// (TerminalSession), one visible at a time, behind a shared status bar
// whose tab strip switches between them. The owning window controller
// supplies workingDirectory and environment before calling
// startShellIfNeeded or addTerminal (they are consumed per spawn),
// attaches `view` to its layout, and calls shutdown when the window
// closes.
@interface TerminalPaneController : NSObject
@property (nonatomic, readonly) NSView* view;
@property (nonatomic, readonly) TerminalGridView* gridView; // the active session’s grid

@property (nonatomic, copy) NSString* workingDirectory; // used at the next spawn
@property (nonatomic) std::map<std::string, std::string> environment;

// Called on the main queue when the last session is gone (its shell exited
// or it was closed); the owner is expected to hide the pane. The next
// startShellIfNeeded starts a fresh session.
@property (nonatomic, copy) void(^shellExitedHandler)(void);

// ⌘-clicked file reference in any session’s output (injected by the owning
// window controller, like environment/theme). Paths are absolute — relative
// references were resolved against the originating session’s live cwd;
// line/column are 1-based, 0 = unspecified. Without a handler the terminal
// does no link detection at all.
@property (nonatomic, copy) void(^openFileHandler)(NSString* path, NSUInteger line, NSUInteger column);

// The status bar’s placement switcher (left/bottom/right, see
// TerminalStatusBar). The pane is preference-free: the owning window
// controller keeps `placement` in sync with the placement user default and
// writes the default from placementChangedHandler (which fires only on an
// actual change, so the write triggers the live relocation exactly once).
@property (nonatomic, copy) NSString* placement;
@property (nonatomic, copy) void(^placementChangedHandler)(NSString* placement);

// Aggregates across all sessions (Terminal.app semantics per session, see
// PTYController): YES when any session runs a foreground/child process.
// runningProcessNames lists the resolvable names, one per busy session.
@property (nonatomic, readonly) BOOL hasRunningProcess;
@property (nonatomic, readonly) NSString* runningProcessName; // first of runningProcessNames
@property (nonatomic, readonly) NSArray<NSString*>* runningProcessNames;

@property (nonatomic, readonly) NSUInteger numberOfTerminals;
@property (nonatomic, readonly) BOOL activeTerminalHasRunningProcess;
@property (nonatomic, readonly) NSString* activeTerminalRunningProcessName;

// Terminal colors follow the editor theme when set; otherwise a built-in
// palette based on the effective appearance is used.
- (void)setThemeBackgroundColor:(NSColor*)backgroundColor foregroundColor:(NSColor*)foregroundColor;

- (void)startShellIfNeeded;      // ensures one session exists; spawns once the grid has a real size
- (void)addTerminal;             // new session (spawned with the current workingDirectory/environment), selected and focused
- (void)selectNextTerminal;
- (void)selectPreviousTerminal;
- (void)closeActiveTerminal;     // kills the active session; the adjacent tab (if any) takes over
- (void)shutdown;                // SIGHUP + reap all sessions; safe to call repeatedly
@end

#endif /* TERMINAL_PANE_CONTROLLER_H_C4F0912B */
