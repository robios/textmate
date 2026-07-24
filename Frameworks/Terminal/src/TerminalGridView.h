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

// ⌘-click file links: while ⌘-hovering, file references in the output are
// detected on demand (never on the render path) and underlined; ⌘-clicking
// one invokes openFileHandler with an absolute path (line/column 1-based,
// 0 = unspecified). Relative paths resolve against workingDirectoryProvider.
// Without an openFileHandler no detection runs at all.
@property (nonatomic, copy) void(^openFileHandler)(NSString* path, NSUInteger line, NSUInteger column);
@property (nonatomic, copy) NSString*(^workingDirectoryProvider)(void);

@property (nonatomic) NSFont* font;
@property (nonatomic, readonly) NSSize cellSize;
@property (nonatomic, readonly) NSUInteger gridColumns;
@property (nonatomic, readonly) NSUInteger gridRows;

- (void)refreshFromEmulator; // main thread
- (void)noteOutputReceived;  // any thread; coalesces a refresh onto the main queue and snaps to the bottom
@end

#endif /* TERMINAL_GRID_VIEW_H_D91B47E6 */
