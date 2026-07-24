#ifndef TERMINAL_STATUS_BAR_H_A18E63C4
#define TERMINAL_STATUS_BAR_H_A18E63C4

#import <Cocoa/Cocoa.h>

// The slim bar at the bottom edge of the terminal pane, visually matching
// OTVStatusBar/OFBActionsView: shows the shell’s working directory.
@interface TerminalStatusBar : NSVisualEffectView
@property (nonatomic, copy) NSString* workingDirectory; // displayed abbreviated (~)
@end

#endif /* TERMINAL_STATUS_BAR_H_A18E63C4 */
