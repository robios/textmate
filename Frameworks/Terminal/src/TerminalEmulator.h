#ifndef TERMINAL_EMULATOR_H_F3A9C2D1
#define TERMINAL_EMULATOR_H_F3A9C2D1

#import <Cocoa/Cocoa.h>
#include <ghostty/vt.h>

// A snapshot of one terminal cell, resolved for drawing. Text is the
// UTF-8 grapheme cluster (not NUL-terminated). width is 0 for spacer
// cells that must not be drawn (tail of a wide character).
struct terminal_cell_t
{
	char text[32];
	uint8_t textLen;
	uint8_t width;
	bool hasForeground, hasBackground;
	GhosttyColorRgb foreground, background;
	bool bold, italic, faint, inverse, invisible, strikethrough, selected;
	uint8_t underline; // GHOSTTY_SGR_UNDERLINE_*
};

struct terminal_cursor_t
{
	bool hasPosition;
	uint16_t x, y;
	bool visible, blinking, wideTail;
	GhosttyRenderStateCursorVisualStyle style;
};

struct terminal_colors_t
{
	GhosttyColorRgb background, foreground, cursor;
	bool hasCursorColor;
};

struct terminal_scrollbar_t
{
	uint64_t total, offset, length;
};

// Wraps a libghostty-vt terminal + render state behind a single lock.
// Feeding (any thread) and render-state synchronization (main thread)
// follow the library’s two-phase update discipline: only the begin
// phase holds the terminal lock, and all row/cell reads afterwards
// touch only render-state memory.
@interface TerminalEmulator : NSObject
- (instancetype)initWithColumns:(NSUInteger)columns rows:(NSUInteger)rows maxScrollback:(NSUInteger)maxScrollback;

// Called synchronously while feeding (on the feeding thread): responses
// the application must write back to the pty (DSR, DECRQM, …).
@property (nonatomic, copy) void(^writeToPTYHandler)(NSData* data);

// Called on the feeding thread after a batch that changed state.
@property (nonatomic, copy) void(^displayNeededHandler)(void);
@property (nonatomic, copy) void(^titleChangedHandler)(NSString* title);
@property (nonatomic, copy) void(^pwdChangedHandler)(NSString* rawPwd); // raw OSC 7 value, often a file:// URI
@property (nonatomic, copy) void(^bellHandler)(void);
@property (nonatomic, copy) void(^clipboardWriteHandler)(NSString* text);

- (void)feedBytes:(void const*)bytes length:(size_t)length;
- (void)resizeToColumns:(NSUInteger)columns rows:(NSUInteger)rows cellWidth:(NSUInteger)cellWidth cellHeight:(NSUInteger)cellHeight;
- (void)setDefaultBackgroundColor:(GhosttyColorRgb)background foregroundColor:(GhosttyColorRgb)foreground cursorColor:(GhosttyColorRgb)cursor;

// == Render state (main thread) ==
- (void)synchronizeRenderState;
- (NSUInteger)columns;
- (NSUInteger)rows;
- (GhosttyRenderStateDirty)dirtyState;
- (void)clearDirtyState;
- (struct terminal_cursor_t)cursor;
- (struct terminal_colors_t)colors;
- (void)enumerateRowsClearingDirty:(BOOL)clearDirty usingBlock:(void(^)(NSUInteger row, BOOL dirty, struct terminal_cell_t const* cells, NSUInteger cellCount))block;

// == Viewport / scrollback ==
- (void)scrollViewportBy:(NSInteger)rowDelta;
- (void)scrollViewportToBottom;
- (struct terminal_scrollbar_t)scrollbar;
- (BOOL)viewportIsAtBottom;

// == Input ==
- (NSData*)encodeKey:(GhosttyKey)key action:(GhosttyKeyAction)action mods:(GhosttyMods)mods consumedMods:(GhosttyMods)consumedMods text:(NSString*)text unshiftedCodepoint:(uint32_t)codepoint;
- (NSData*)encodePaste:(NSString*)string;
- (NSData*)encodeFocus:(BOOL)gained; // empty unless mode 1004 is set
- (BOOL)mouseTrackingActive;
- (BOOL)altScreenActive;
- (BOOL)altScrollModeActive; // DEC mode 1007: wheel becomes arrow keys on the alternate screen

// Mouse reporting. Positions are view-local pixels; geometry must be kept
// current via setMouseGeometry… for pixel→cell conversion.
- (void)setMouseGeometryScreenWidth:(NSUInteger)screenWidth screenHeight:(NSUInteger)screenHeight cellWidth:(NSUInteger)cellWidth cellHeight:(NSUInteger)cellHeight padding:(NSUInteger)padding;
- (NSData*)encodeMouseAction:(GhosttyMouseAction)action button:(GhosttyMouseButton)button hasButton:(BOOL)hasButton mods:(GhosttyMods)mods position:(NSPoint)position anyButtonPressed:(BOOL)anyButtonPressed;

// == Selection (coordinates are viewport cells / view-local pixels) ==
- (BOOL)selectionBeginAtColumn:(NSUInteger)column row:(NSUInteger)row position:(NSPoint)position timestamp:(NSTimeInterval)timestamp clickCount:(NSUInteger)clickCount;
- (BOOL)selectionDragToColumn:(NSUInteger)column row:(NSUInteger)row position:(NSPoint)position geometry:(GhosttySelectionGestureGeometry)geometry;
- (void)selectionEndAtColumn:(NSUInteger)column row:(NSUInteger)row;
- (void)selectAll;
- (void)clearSelection;
- (BOOL)hasSelection;
- (NSString*)selectedString;

- (void)reset;
@end

#endif /* TERMINAL_EMULATOR_H_F3A9C2D1 */
