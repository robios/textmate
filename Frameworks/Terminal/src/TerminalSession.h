#ifndef TERMINAL_SESSION_H_E52A7D19
#define TERMINAL_SESSION_H_E52A7D19

#import <Cocoa/Cocoa.h>
#include <map>
#include <string>

@class TerminalGridView;

// One terminal: emulator + pty + grid view, wrapped in the scroll view the
// grid must live in (see TerminalPaneController for why). Sessions are
// one-shot — when the shell exits the session is done and its owner removes
// it; a fresh terminal is a fresh TerminalSession. The owner supplies
// workingDirectory and environment before startShellIfNeeded, installs
// `view` while the session is frontmost, and calls shutdown to kill it.
@interface TerminalSession : NSObject
@property (nonatomic, readonly) NSView* view; // scroll view wrapping the grid
@property (nonatomic, readonly) TerminalGridView* gridView;

@property (nonatomic, copy) NSString* workingDirectory; // used at spawn
@property (nonatomic) std::map<std::string, std::string> environment;

// Live queries (Terminal.app semantics, see PTYController). The cached
// variants are refreshed by the output-driven checks and the slow poll and
// are what tab titles/dots should use — the live ones hit the kernel.
@property (nonatomic, readonly) BOOL hasRunningProcess;
@property (nonatomic, readonly) NSString* runningProcessName;
@property (nonatomic, readonly) BOOL cachedHasRunningProcess;
@property (nonatomic, readonly) NSString* cachedRunningProcessName;

@property (nonatomic, readonly) NSString* currentDirectory; // last OSC 7 report
@property (nonatomic, readonly) NSString* windowTitle;      // last OSC 0/2 title, nil if never set
@property (nonatomic, readonly) NSString* shellName;        // e.g. “zsh”
@property (nonatomic, readonly) NSString* displayName;      // OSC title ?: running process ?: shell

// Display state owned by the host (set on background-tab bell, cleared on
// selection); kept here so it travels with the session.
@property (nonatomic) BOOL hasUnreadBell;

// The slow foreground-process poll only runs while this is YES (the host
// sets it while the pane is in a window) and a process is being shown.
@property (nonatomic) BOOL allowsProcessPolling;

// ⌘-clicked file reference in this session’s output. Paths are absolute
// (relative references were resolved against this session’s live cwd);
// line/column are 1-based, 0 = unspecified.
@property (nonatomic, copy) void(^openFileHandler)(NSString* path, NSUInteger line, NSUInteger column);

// All handlers are invoked on the main queue.
@property (nonatomic, copy) void(^exitedHandler)(void);                       // shell exited; remove the session
@property (nonatomic, copy) void(^stateChangedHandler)(void);                 // title, pwd, or process info changed
@property (nonatomic, copy) void(^bellHandler)(void);                         // BEL received
@property (nonatomic, copy) void(^gridSizeChangedHandler)(NSUInteger columns, NSUInteger rows); // live-resize readout (initial sizing skipped)

- (void)applyDarkPalette:(BOOL)useDarkPalette;
- (void)startShellIfNeeded; // spawns once the grid has a real size
- (void)shutdown;           // SIGHUP + reap; safe to call repeatedly
@end

#endif /* TERMINAL_SESSION_H_E52A7D19 */
