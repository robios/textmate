#ifndef TERMINAL_PANE_CONTROLLER_H_C4F0912B
#define TERMINAL_PANE_CONTROLLER_H_C4F0912B

#import <Cocoa/Cocoa.h>
#include <map>
#include <string>

@class TerminalGridView;

// One integrated terminal: emulator + pty + grid view + status bar.
// The owning window controller supplies workingDirectory and environment
// before calling startShellIfNeeded, attaches `view` to its layout, and
// calls shutdown when the window closes.
@interface TerminalPaneController : NSObject
@property (nonatomic, readonly) NSView* view;
@property (nonatomic, readonly) TerminalGridView* gridView;

@property (nonatomic, copy) NSString* workingDirectory; // used at (re)spawn
@property (nonatomic) std::map<std::string, std::string> environment;

// Called on the main queue when the shell exits; the owner is expected to
// hide the pane. The next startShellIfNeeded starts a fresh session.
@property (nonatomic, copy) void(^shellExitedHandler)(void);

// Terminal colors follow the editor theme when set; otherwise a built-in
// palette based on the effective appearance is used.
- (void)setThemeBackgroundColor:(NSColor*)backgroundColor foregroundColor:(NSColor*)foregroundColor;

- (void)startShellIfNeeded; // spawns once the grid has a real size
- (void)shutdown;           // SIGHUP + reap; safe to call repeatedly
@end

#endif /* TERMINAL_PANE_CONTROLLER_H_C4F0912B */
