#ifndef TERMINAL_STATUS_BAR_H_A18E63C4
#define TERMINAL_STATUS_BAR_H_A18E63C4

#import <Cocoa/Cocoa.h>

// The slim bar at the bottom edge of the terminal pane, visually matching
// OTVStatusBar/OFBActionsView: a compact tab strip (one tab per terminal
// session plus “+”), the active shell’s working directory, the foreground
// process (with an activity dot) while a command runs, a transient
// “cols × rows” readout during live resizes, and a placement switcher
// (left/bottom/right) at the right edge.
@interface TerminalStatusBar : NSVisualEffectView
@property (nonatomic, copy) NSString* workingDirectory; // displayed abbreviated (~)
@property (nonatomic, copy) NSString* processName;      // foreground process; nil/empty hides the dot

// Which window edge the pane sits on: “left”, “bottom”, or “right” (anything
// else normalizes to “right”, matching ProjectLayoutView). The bar is
// preference-free — the owning window controller binds both directions to
// the placement user default, like openFileHandler/environment on the pane.
@property (nonatomic, copy) NSString* placement;
@property (nonatomic, copy) void(^placementChangedHandler)(NSString* placement);

// Tab strip. Activity indexes get a green dot (running process), unread
// indexes an orange dot (bell on a background tab).
@property (nonatomic, copy) void(^tabSelectedHandler)(NSUInteger index);
@property (nonatomic, copy) void(^newTabHandler)(void);
- (void)setTabTitles:(NSArray<NSString*>*)titles selectedIndex:(NSUInteger)selectedIndex activityIndexes:(NSIndexSet*)activityIndexes unreadIndexes:(NSIndexSet*)unreadIndexes;

- (void)flashGridSize:(NSUInteger)columns rows:(NSUInteger)rows; // shows “cols × rows”, fades ~1 s after the last call
@end

#endif /* TERMINAL_STATUS_BAR_H_A18E63C4 */
