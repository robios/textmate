#ifndef TERMINAL_GRID_VIEW_H_D91B47E6
#define TERMINAL_GRID_VIEW_H_D91B47E6

#import <Cocoa/Cocoa.h>
#import "TerminalEmulator.h"

// Draws a TerminalEmulator’s viewport as a CoreText cell grid and routes
// keyboard/mouse/IME input back to it. Bytes destined for the pty are
// handed to writeDataHandler; grid geometry changes (for TIOCSWINSZ) to
// gridSizeChangedHandler.
@interface TerminalGridView : NSView <NSTextInputClient>
- (instancetype)initWithEmulator:(TerminalEmulator*)emulator;

@property (nonatomic, readonly) TerminalEmulator* emulator;
@property (nonatomic, copy) void(^writeDataHandler)(NSData* data);
@property (nonatomic, copy) void(^gridSizeChangedHandler)(NSUInteger columns, NSUInteger rows, NSUInteger pixelWidth, NSUInteger pixelHeight);

@property (nonatomic) NSFont* font;
@property (nonatomic, readonly) NSSize cellSize;
@property (nonatomic, readonly) NSUInteger gridColumns;
@property (nonatomic, readonly) NSUInteger gridRows;

- (void)refreshFromEmulator; // main thread
- (void)noteOutputReceived;  // any thread; coalesces a refresh onto the main queue and snaps to the bottom
@end

#endif /* TERMINAL_GRID_VIEW_H_D91B47E6 */
