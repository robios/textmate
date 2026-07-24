#import "TerminalGridView.h"
#import "link_detect.h"
#import <Carbon/Carbon.h> // kVK_* virtual key codes only, nothing is linked
#include <atomic>
#include <map>
#include <string>
#include <vector>

static CGFloat const kTerminalViewPadding = 6;

static GhosttyKey key_for_keycode (unsigned short keyCode)
{
	switch(keyCode)
	{
		case kVK_ANSI_A:              return GHOSTTY_KEY_A;
		case kVK_ANSI_B:              return GHOSTTY_KEY_B;
		case kVK_ANSI_C:              return GHOSTTY_KEY_C;
		case kVK_ANSI_D:              return GHOSTTY_KEY_D;
		case kVK_ANSI_E:              return GHOSTTY_KEY_E;
		case kVK_ANSI_F:              return GHOSTTY_KEY_F;
		case kVK_ANSI_G:              return GHOSTTY_KEY_G;
		case kVK_ANSI_H:              return GHOSTTY_KEY_H;
		case kVK_ANSI_I:              return GHOSTTY_KEY_I;
		case kVK_ANSI_J:              return GHOSTTY_KEY_J;
		case kVK_ANSI_K:              return GHOSTTY_KEY_K;
		case kVK_ANSI_L:              return GHOSTTY_KEY_L;
		case kVK_ANSI_M:              return GHOSTTY_KEY_M;
		case kVK_ANSI_N:              return GHOSTTY_KEY_N;
		case kVK_ANSI_O:              return GHOSTTY_KEY_O;
		case kVK_ANSI_P:              return GHOSTTY_KEY_P;
		case kVK_ANSI_Q:              return GHOSTTY_KEY_Q;
		case kVK_ANSI_R:              return GHOSTTY_KEY_R;
		case kVK_ANSI_S:              return GHOSTTY_KEY_S;
		case kVK_ANSI_T:              return GHOSTTY_KEY_T;
		case kVK_ANSI_U:              return GHOSTTY_KEY_U;
		case kVK_ANSI_V:              return GHOSTTY_KEY_V;
		case kVK_ANSI_W:              return GHOSTTY_KEY_W;
		case kVK_ANSI_X:              return GHOSTTY_KEY_X;
		case kVK_ANSI_Y:              return GHOSTTY_KEY_Y;
		case kVK_ANSI_Z:              return GHOSTTY_KEY_Z;
		case kVK_ANSI_0:              return GHOSTTY_KEY_DIGIT_0;
		case kVK_ANSI_1:              return GHOSTTY_KEY_DIGIT_1;
		case kVK_ANSI_2:              return GHOSTTY_KEY_DIGIT_2;
		case kVK_ANSI_3:              return GHOSTTY_KEY_DIGIT_3;
		case kVK_ANSI_4:              return GHOSTTY_KEY_DIGIT_4;
		case kVK_ANSI_5:              return GHOSTTY_KEY_DIGIT_5;
		case kVK_ANSI_6:              return GHOSTTY_KEY_DIGIT_6;
		case kVK_ANSI_7:              return GHOSTTY_KEY_DIGIT_7;
		case kVK_ANSI_8:              return GHOSTTY_KEY_DIGIT_8;
		case kVK_ANSI_9:              return GHOSTTY_KEY_DIGIT_9;
		case kVK_ANSI_Grave:          return GHOSTTY_KEY_BACKQUOTE;
		case kVK_ANSI_Minus:          return GHOSTTY_KEY_MINUS;
		case kVK_ANSI_Equal:          return GHOSTTY_KEY_EQUAL;
		case kVK_ANSI_LeftBracket:    return GHOSTTY_KEY_BRACKET_LEFT;
		case kVK_ANSI_RightBracket:   return GHOSTTY_KEY_BRACKET_RIGHT;
		case kVK_ANSI_Backslash:      return GHOSTTY_KEY_BACKSLASH;
		case kVK_ANSI_Semicolon:      return GHOSTTY_KEY_SEMICOLON;
		case kVK_ANSI_Quote:          return GHOSTTY_KEY_QUOTE;
		case kVK_ANSI_Comma:          return GHOSTTY_KEY_COMMA;
		case kVK_ANSI_Period:         return GHOSTTY_KEY_PERIOD;
		case kVK_ANSI_Slash:          return GHOSTTY_KEY_SLASH;
		case kVK_Space:               return GHOSTTY_KEY_SPACE;
		case kVK_Return:              return GHOSTTY_KEY_ENTER;
		case kVK_Tab:                 return GHOSTTY_KEY_TAB;
		case kVK_Delete:              return GHOSTTY_KEY_BACKSPACE;
		case kVK_ForwardDelete:       return GHOSTTY_KEY_DELETE;
		case kVK_Escape:              return GHOSTTY_KEY_ESCAPE;
		case kVK_LeftArrow:           return GHOSTTY_KEY_ARROW_LEFT;
		case kVK_RightArrow:          return GHOSTTY_KEY_ARROW_RIGHT;
		case kVK_UpArrow:             return GHOSTTY_KEY_ARROW_UP;
		case kVK_DownArrow:           return GHOSTTY_KEY_ARROW_DOWN;
		case kVK_Home:                return GHOSTTY_KEY_HOME;
		case kVK_End:                 return GHOSTTY_KEY_END;
		case kVK_PageUp:              return GHOSTTY_KEY_PAGE_UP;
		case kVK_PageDown:            return GHOSTTY_KEY_PAGE_DOWN;
		case kVK_F1:                  return GHOSTTY_KEY_F1;
		case kVK_F2:                  return GHOSTTY_KEY_F2;
		case kVK_F3:                  return GHOSTTY_KEY_F3;
		case kVK_F4:                  return GHOSTTY_KEY_F4;
		case kVK_F5:                  return GHOSTTY_KEY_F5;
		case kVK_F6:                  return GHOSTTY_KEY_F6;
		case kVK_F7:                  return GHOSTTY_KEY_F7;
		case kVK_F8:                  return GHOSTTY_KEY_F8;
		case kVK_F9:                  return GHOSTTY_KEY_F9;
		case kVK_F10:                 return GHOSTTY_KEY_F10;
		case kVK_F11:                 return GHOSTTY_KEY_F11;
		case kVK_F12:                 return GHOSTTY_KEY_F12;
		case kVK_F13:                 return GHOSTTY_KEY_F13;
		case kVK_F14:                 return GHOSTTY_KEY_F14;
		case kVK_F15:                 return GHOSTTY_KEY_F15;
		case kVK_F16:                 return GHOSTTY_KEY_F16;
		case kVK_F17:                 return GHOSTTY_KEY_F17;
		case kVK_F18:                 return GHOSTTY_KEY_F18;
		case kVK_F19:                 return GHOSTTY_KEY_F19;
		case kVK_F20:                 return GHOSTTY_KEY_F20;
		case kVK_ANSI_Keypad0:        return GHOSTTY_KEY_NUMPAD_0;
		case kVK_ANSI_Keypad1:        return GHOSTTY_KEY_NUMPAD_1;
		case kVK_ANSI_Keypad2:        return GHOSTTY_KEY_NUMPAD_2;
		case kVK_ANSI_Keypad3:        return GHOSTTY_KEY_NUMPAD_3;
		case kVK_ANSI_Keypad4:        return GHOSTTY_KEY_NUMPAD_4;
		case kVK_ANSI_Keypad5:        return GHOSTTY_KEY_NUMPAD_5;
		case kVK_ANSI_Keypad6:        return GHOSTTY_KEY_NUMPAD_6;
		case kVK_ANSI_Keypad7:        return GHOSTTY_KEY_NUMPAD_7;
		case kVK_ANSI_Keypad8:        return GHOSTTY_KEY_NUMPAD_8;
		case kVK_ANSI_Keypad9:        return GHOSTTY_KEY_NUMPAD_9;
		case kVK_ANSI_KeypadDecimal:  return GHOSTTY_KEY_NUMPAD_DECIMAL;
		case kVK_ANSI_KeypadMultiply: return GHOSTTY_KEY_NUMPAD_MULTIPLY;
		case kVK_ANSI_KeypadPlus:     return GHOSTTY_KEY_NUMPAD_ADD;
		case kVK_ANSI_KeypadClear:    return GHOSTTY_KEY_NUMPAD_CLEAR;
		case kVK_ANSI_KeypadDivide:   return GHOSTTY_KEY_NUMPAD_DIVIDE;
		case kVK_ANSI_KeypadEnter:    return GHOSTTY_KEY_NUMPAD_ENTER;
		case kVK_ANSI_KeypadMinus:    return GHOSTTY_KEY_NUMPAD_SUBTRACT;
		case kVK_ANSI_KeypadEquals:   return GHOSTTY_KEY_NUMPAD_EQUAL;
		default:                      return GHOSTTY_KEY_UNIDENTIFIED;
	}
}

// Keys that either never arrive at -keyDown: (⌃-arrows and friends) or
// must not fall through to menu/bundle key-equivalent matching.
static bool is_special_key (unsigned short keyCode)
{
	switch(keyCode)
	{
		case kVK_Escape: case kVK_ForwardDelete:
		case kVK_LeftArrow: case kVK_RightArrow: case kVK_UpArrow: case kVK_DownArrow:
		case kVK_Home: case kVK_End: case kVK_PageUp: case kVK_PageDown:
		case kVK_F1: case kVK_F2: case kVK_F3: case kVK_F4: case kVK_F5:
		case kVK_F6: case kVK_F7: case kVK_F8: case kVK_F9: case kVK_F10:
		case kVK_F11: case kVK_F12: case kVK_F13: case kVK_F14: case kVK_F15:
		case kVK_F16: case kVK_F17: case kVK_F18: case kVK_F19: case kVK_F20:
			return true;
	}
	return false;
}

static GhosttyMods mods_for_flags (NSEventModifierFlags flags)
{
	GhosttyMods res = 0;
	if(flags & NSEventModifierFlagShift)    res |= GHOSTTY_MODS_SHIFT;
	if(flags & NSEventModifierFlagControl)  res |= GHOSTTY_MODS_CTRL;
	if(flags & NSEventModifierFlagOption)   res |= GHOSTTY_MODS_ALT;
	if(flags & NSEventModifierFlagCommand)  res |= GHOSTTY_MODS_SUPER;
	if(flags & NSEventModifierFlagCapsLock) res |= GHOSTTY_MODS_CAPS_LOCK;
	return res;
}

// Text suitable for GhosttyKeyEvent utf8: no C0 controls, no DEL, no
// macOS function-key PUA code points.
static BOOL is_usable_text (NSString* text)
{
	if(text.length == 0)
		return NO;
	for(NSUInteger i = 0; i < text.length; ++i)
	{
		unichar ch = [text characterAtIndex:i];
		if(ch < 0x20 || ch == 0x7F || (ch >= 0xF700 && ch <= 0xF8FF))
			return NO;
	}
	return YES;
}

struct cell_style_key_t
{
	bool operator== (cell_style_key_t const& rhs) const
	{
		return fontVariant == rhs.fontVariant && hasColor == rhs.hasColor && r == rhs.r && g == rhs.g && b == rhs.b && faint == rhs.faint && underline == rhs.underline && strikethrough == rhs.strikethrough;
	}
	int fontVariant; // 0 plain, 1 bold, 2 italic, 3 bold-italic
	bool hasColor;
	uint8_t r, g, b;
	bool faint;
	uint8_t underline;
	bool strikethrough;
};

struct link_span_t // one viewport row’s stretch of a ⌘-hovered file link
{
	NSUInteger row;
	NSUInteger colBegin, colEnd; // colEnd exclusive
};

@implementation TerminalGridView
{
	std::vector<terminal_cell_t> _grid;
	NSUInteger _cachedColumns, _cachedRows;
	terminal_cursor_t _cursor;
	terminal_colors_t _colors;

	NSFont* _boldFont;
	NSFont* _italicFont;
	NSFont* _boldItalicFont;
	CGFloat _cellWidth, _cellHeight, _cellAscent;

	std::atomic<bool> _refreshPending;
	std::atomic<bool> _snapToBottomPending;

	BOOL _mouseReporting;      // current drag is forwarded to the application
	CGFloat _scrollResidue;

	NSMutableAttributedString* _markedText;
	NSRange _markedSelection;

	id _windowKeyObserver, _windowUnkeyObserver;

	// ⌘-click file links — populated only by ⌘-hover/-click detection
	std::vector<link_span_t> _linkSpans;
	NSString* _linkPath;
	NSUInteger _linkLine, _linkColumn;
	BOOL _linkActive;
	BOOL _linkCursorSet;
	BOOL _linkLookupValid;   // detection already ran for _linkLookup{Column,Row} (result may be “no link”)
	NSUInteger _linkLookupColumn, _linkLookupRow;
	BOOL _linkClickPending;  // swallow the mouseUp of a handled ⌘-click
	id _flagsChangedMonitor;
	NSTrackingArea* _linkTrackingArea;
}

- (instancetype)initWithEmulator:(TerminalEmulator*)emulator
{
	if(self = [super initWithFrame:NSZeroRect])
	{
		_emulator = emulator;
		_markedText = [NSMutableAttributedString new];
		self.font = [self defaultFont];

		__weak TerminalGridView* weakSelf = self;
		emulator.displayNeededHandler = ^{
			[weakSelf noteOutputReceived];
		};

		[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(userDefaultsDidChange:) name:NSUserDefaultsDidChangeNotification object:nil];
	}
	return self;
}

- (void)userDefaultsDidChange:(NSNotification*)aNotification
{
	NSFont* font = [self defaultFont];
	if(![font.fontName isEqualToString:_font.fontName] || font.pointSize != _font.pointSize)
		self.font = font;
}

- (NSFont*)defaultFont
{
	NSUserDefaults* defaults = NSUserDefaults.standardUserDefaults;
	NSString* fontName = [defaults stringForKey:@"terminalFontName"];
	CGFloat fontSize = [defaults doubleForKey:@"terminalFontSize"];
	if(fontSize <= 0)
		fontSize = 12;
	NSFont* font = fontName ? [NSFont fontWithName:fontName size:fontSize] : nil;
	return font ?: [NSFont userFixedPitchFontOfSize:fontSize];
}

- (void)setFont:(NSFont*)font
{
	_font = font;
	NSFontManager* fontManager = NSFontManager.sharedFontManager;
	_boldFont       = [fontManager convertFont:font toHaveTrait:NSBoldFontMask];
	_italicFont     = [fontManager convertFont:font toHaveTrait:NSItalicFontMask];
	_boldItalicFont = [fontManager convertFont:_boldFont toHaveTrait:NSItalicFontMask];

	CGGlyph glyph;
	UniChar capitalM = 'M';
	CGSize advance = CGSizeZero;
	CTFontRef ctFont = (__bridge CTFontRef)font;
	if(CTFontGetGlyphsForCharacters(ctFont, &capitalM, &glyph, 1))
		CTFontGetAdvancesForGlyphs(ctFont, kCTFontOrientationHorizontal, &glyph, &advance, 1);
	// Use the exact (fractional) advance: glyphs inside a text run advance at
	// the font’s natural width, so the grid pitch must match it exactly or
	// runs starting at later columns drift right of the text before them.
	_cellWidth  = std::max<CGFloat>(advance.width, 1);
	_cellAscent = ceil(CTFontGetAscent(ctFont));
	_cellHeight = std::max<CGFloat>(_cellAscent + ceil(CTFontGetDescent(ctFont)) + ceil(CTFontGetLeading(ctFont)), 1);

	[self updateGridSize];
	self.needsDisplay = YES;
}

- (NSSize)cellSize
{
	return NSMakeSize(_cellWidth, _cellHeight);
}

- (BOOL)isFlipped               { return YES; }
- (BOOL)isOpaque                { return YES; }
- (BOOL)acceptsFirstResponder   { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent*)event { return YES; }

- (void)viewWillMoveToWindow:(NSWindow*)newWindow
{
	NSNotificationCenter* center = NSNotificationCenter.defaultCenter;
	if(_windowKeyObserver)
		[center removeObserver:_windowKeyObserver];
	if(_windowUnkeyObserver)
		[center removeObserver:_windowUnkeyObserver];
	_windowKeyObserver = _windowUnkeyObserver = nil;

	[self clearLinkIndication];
	if(_flagsChangedMonitor)
	{
		[NSEvent removeMonitor:_flagsChangedMonitor];
		_flagsChangedMonitor = nil;
	}

	if(newWindow)
	{
		__weak TerminalGridView* weakSelf = self;
		_windowKeyObserver = [center addObserverForName:NSWindowDidBecomeKeyNotification object:newWindow queue:nil usingBlock:^(NSNotification* notification){
			[weakSelf windowKeyStateDidChange:YES];
		}];
		_windowUnkeyObserver = [center addObserverForName:NSWindowDidResignKeyNotification object:newWindow queue:nil usingBlock:^(NSNotification* notification){
			[weakSelf windowKeyStateDidChange:NO];
		}];
		// ⌘ press/release must update link indication even while another view
		// is first responder, so a plain -flagsChanged: override is not enough.
		_flagsChangedMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskFlagsChanged handler:^NSEvent*(NSEvent* event){
			[weakSelf updateLinkIndicationForModifierFlags:event.modifierFlags];
			return event;
		}];
	}
}

- (void)dealloc
{
	NSNotificationCenter* center = NSNotificationCenter.defaultCenter;
	[center removeObserver:self];
	if(_windowKeyObserver)
		[center removeObserver:_windowKeyObserver];
	if(_windowUnkeyObserver)
		[center removeObserver:_windowUnkeyObserver];
	if(_flagsChangedMonitor)
		[NSEvent removeMonitor:_flagsChangedMonitor];
}

- (void)windowKeyStateDidChange:(BOOL)isKey
{
	if(self.window.firstResponder == self)
	{
		if(NSData* data = [_emulator encodeFocus:isKey])
			[self writeToPTY:data snapToBottom:NO];
	}
	[self invalidateCursorCell];
}

- (BOOL)becomeFirstResponder
{
	if(NSData* data = [_emulator encodeFocus:YES])
		[self writeToPTY:data snapToBottom:NO];
	[self invalidateCursorCell];
	return YES;
}

- (BOOL)resignFirstResponder
{
	if(NSData* data = [_emulator encodeFocus:NO])
		[self writeToPTY:data snapToBottom:NO];
	[self invalidateCursorCell];
	return YES;
}

// ============
// = Geometry =
// ============

- (NSRect)rectForRow:(NSUInteger)row
{
	return NSMakeRect(0, kTerminalViewPadding + row * _cellHeight, NSWidth(self.bounds), _cellHeight);
}

- (NSRect)rectForCellAtColumn:(NSUInteger)column row:(NSUInteger)row
{
	return NSMakeRect(kTerminalViewPadding + column * _cellWidth, kTerminalViewPadding + row * _cellHeight, _cellWidth, _cellHeight);
}

- (void)pointToCell:(NSPoint)point column:(NSUInteger*)column row:(NSUInteger*)row
{
	NSInteger col = (NSInteger)floor((point.x - kTerminalViewPadding) / _cellWidth);
	NSInteger r   = (NSInteger)floor((point.y - kTerminalViewPadding) / _cellHeight);
	*column = std::min<NSUInteger>(std::max<NSInteger>(col, 0), _cachedColumns ? _cachedColumns-1 : 0);
	*row    = std::min<NSUInteger>(std::max<NSInteger>(r, 0), _cachedRows ? _cachedRows-1 : 0);
}

- (void)setFrameSize:(NSSize)newSize
{
	[super setFrameSize:newSize];
	[self updateGridSize];
}

- (void)viewDidChangeBackingProperties
{
	[super viewDidChangeBackingProperties];
	[self updateGridSize];
}

- (void)updateGridSize
{
	if(_cellWidth < 1 || _cellHeight < 1 || NSWidth(self.bounds) < 1)
		return;

	NSUInteger cols = std::max<NSInteger>((NSInteger)floor((NSWidth(self.bounds) - 2*kTerminalViewPadding) / _cellWidth), 2);
	NSUInteger rows = std::max<NSInteger>((NSInteger)floor((NSHeight(self.bounds) - 2*kTerminalViewPadding) / _cellHeight), 2);
	if(cols == _gridColumns && rows == _gridRows)
		return;

	_gridColumns = cols;
	_gridRows    = rows;

	CGFloat scale = self.window.backingScaleFactor ?: 2;
	NSUInteger cellPixelWidth  = (NSUInteger)round(_cellWidth * scale);
	NSUInteger cellPixelHeight = (NSUInteger)round(_cellHeight * scale);

	[_emulator resizeToColumns:cols rows:rows cellWidth:cellPixelWidth cellHeight:cellPixelHeight];

	// The mouse encoder’s geometry is integer-only; our cell width is
	// fractional. Use a synthetic 10-px grid and synthesize positions from
	// our own (exact) cell math in mouseReportPositionForEvent:.
	[_emulator setMouseGeometryScreenWidth:cols*10 screenHeight:rows*10 cellWidth:10 cellHeight:10 padding:0];

	if(_gridSizeChangedHandler)
		_gridSizeChangedHandler(cols, rows, cols * cellPixelWidth, rows * cellPixelHeight);

	[self refreshFromEmulator];
	self.needsDisplay = YES;
}

// ===========
// = Refresh =
// ===========

- (void)noteOutputReceived
{
	_snapToBottomPending = true;
	bool expected = false;
	if(_refreshPending.compare_exchange_strong(expected, true))
	{
		__weak TerminalGridView* weakSelf = self;
		dispatch_async(dispatch_get_main_queue(), ^{
			TerminalGridView* strongSelf = weakSelf;
			if(strongSelf)
			{
				strongSelf->_refreshPending = false;
				[strongSelf refreshFromEmulator];
			}
		});
	}
}

- (void)refreshFromEmulator
{
	if(_snapToBottomPending.exchange(false))
		[_emulator scrollViewportToBottom];

	[_emulator synchronizeRenderState];

	NSUInteger cols = [_emulator columns];
	NSUInteger rows = [_emulator rows];
	GhosttyRenderStateDirty dirtyState = [_emulator dirtyState];

	BOOL fullRedraw = dirtyState == GHOSTTY_RENDER_STATE_DIRTY_FULL || cols != _cachedColumns || rows != _cachedRows;
	if(cols != _cachedColumns || rows != _cachedRows)
	{
		_cachedColumns = cols;
		_cachedRows    = rows;
		_grid.assign(cols * rows, terminal_cell_t());
	}

	terminal_cursor_t oldCursor = _cursor;
	_cursor = [_emulator cursor];
	_colors = [_emulator colors];

	if(dirtyState != GHOSTTY_RENDER_STATE_DIRTY_FALSE || fullRedraw)
	{
		[self clearLinkIndication]; // content moved under the mouse; ⌘-hover recomputes

		std::vector<terminal_cell_t>& grid = _grid;
		[_emulator enumerateRowsClearingDirty:YES usingBlock:^(NSUInteger row, BOOL dirty, terminal_cell_t const* cells, NSUInteger cellCount){
			if(row >= rows)
				return;
			NSUInteger count = std::min<NSUInteger>(cellCount, cols);
			std::copy(cells, cells + count, grid.begin() + row * cols);
			for(NSUInteger i = count; i < cols; ++i)
				grid[row * cols + i] = terminal_cell_t();
			if(!fullRedraw && dirty)
				[self setNeedsDisplayInRect:[self rectForRow:row]];
		}];
	}

	if(fullRedraw)
	{
		self.needsDisplay = YES;
	}
	else if(oldCursor.hasPosition != _cursor.hasPosition || oldCursor.x != _cursor.x || oldCursor.y != _cursor.y || oldCursor.visible != _cursor.visible || oldCursor.style != _cursor.style)
	{
		if(oldCursor.hasPosition)
			[self setNeedsDisplayInRect:[self rectForRow:oldCursor.y]];
		if(_cursor.hasPosition)
			[self setNeedsDisplayInRect:[self rectForRow:_cursor.y]];
	}
}

- (void)invalidateCursorCell
{
	if(_cursor.hasPosition)
		[self setNeedsDisplayInRect:[self rectForRow:_cursor.y]];
}

// ===========
// = Drawing =
// ===========

- (NSFont*)fontForVariant:(int)variant
{
	switch(variant)
	{
		case 1:  return _boldFont;
		case 2:  return _italicFont;
		case 3:  return _boldItalicFont;
		default: return _font;
	}
}

- (void)drawRect:(NSRect)dirtyRect
{
	CGContextRef context = NSGraphicsContext.currentContext.CGContext;

	CGContextSetRGBFillColor(context, _colors.background.r/255.0, _colors.background.g/255.0, _colors.background.b/255.0, 1);
	CGContextFillRect(context, dirtyRect);

	if(_cachedColumns == 0 || _cachedRows == 0)
		return;

	NSInteger firstRow = std::max<NSInteger>((NSInteger)floor((NSMinY(dirtyRect) - kTerminalViewPadding) / _cellHeight), 0);
	NSInteger lastRow  = std::min<NSInteger>((NSInteger)ceil((NSMaxY(dirtyRect) - kTerminalViewPadding) / _cellHeight), (NSInteger)_cachedRows - 1);

	NSColor* selectionColor = [NSColor.selectedTextBackgroundColor colorUsingColorSpace:NSColorSpace.sRGBColorSpace];

	CGContextSetShouldSmoothFonts(context, true);
	CGContextSetTextMatrix(context, CGAffineTransformMakeScale(1, -1));

	for(NSInteger row = firstRow; row <= lastRow; ++row)
	{
		terminal_cell_t const* cells = _grid.data() + row * _cachedColumns;
		CGFloat rowY = kTerminalViewPadding + row * _cellHeight;

		// Backgrounds
		NSUInteger col = 0;
		while(col < _cachedColumns)
		{
			terminal_cell_t const& cell = cells[col];

			double r, g, b;
			bool paint = true;
			if(cell.selected)
			{
				r = selectionColor.redComponent; g = selectionColor.greenComponent; b = selectionColor.blueComponent;
			}
			else if(cell.inverse)
			{
				GhosttyColorRgb color = cell.hasForeground ? cell.foreground : _colors.foreground;
				r = color.r/255.0; g = color.g/255.0; b = color.b/255.0;
			}
			else if(cell.hasBackground)
			{
				r = cell.background.r/255.0; g = cell.background.g/255.0; b = cell.background.b/255.0;
			}
			else
			{
				paint = false;
				r = g = b = 0;
			}

			NSUInteger runStart = col++;
			while(paint && col < _cachedColumns)
			{
				terminal_cell_t const& next = cells[col];
				bool nextPaint;
				double nr, ng, nb;
				if(next.selected)
					{ nr = selectionColor.redComponent; ng = selectionColor.greenComponent; nb = selectionColor.blueComponent; nextPaint = true; }
				else if(next.inverse)
					{ GhosttyColorRgb c = next.hasForeground ? next.foreground : _colors.foreground; nr = c.r/255.0; ng = c.g/255.0; nb = c.b/255.0; nextPaint = true; }
				else if(next.hasBackground)
					{ nr = next.background.r/255.0; ng = next.background.g/255.0; nb = next.background.b/255.0; nextPaint = true; }
				else
					{ nextPaint = false; nr = ng = nb = 0; }
				if(!nextPaint || nr != r || ng != g || nb != b)
					break;
				++col;
			}

			if(paint)
			{
				CGContextSetRGBFillColor(context, r, g, b, 1);
				CGContextFillRect(context, CGRectMake(kTerminalViewPadding + runStart * _cellWidth, rowY, (col - runStart) * _cellWidth, _cellHeight));
			}
		}

		// Text
		col = 0;
		while(col < _cachedColumns)
		{
			terminal_cell_t const& cell = cells[col];
			if(cell.width == 0 || cell.textLen == 0 || cell.invisible)
			{
				++col;
				continue;
			}

			cell_style_key_t key;
			key.fontVariant = (cell.bold ? 1 : 0) | (cell.italic ? 2 : 0);
			if(cell.inverse)
			{
				GhosttyColorRgb color = cell.hasBackground ? cell.background : _colors.background;
				key.hasColor = true; key.r = color.r; key.g = color.g; key.b = color.b;
			}
			else
			{
				key.hasColor = cell.hasForeground;
				key.r = cell.foreground.r; key.g = cell.foreground.g; key.b = cell.foreground.b;
			}
			key.faint = cell.faint;
			key.underline = cell.underline;
			key.strikethrough = cell.strikethrough;

			NSUInteger runStart = col;
			NSMutableString* runText = [NSMutableString new];
			BOOL isWide = cell.width == 2;
			if(isWide)
			{
				[runText appendString:[[NSString alloc] initWithBytes:cell.text length:cell.textLen encoding:NSUTF8StringEncoding] ?: @"?"];
				col += 1; // spacer cell that follows has width 0 and is skipped
			}
			else
			{
				while(col < _cachedColumns)
				{
					terminal_cell_t const& runCell = cells[col];
					if(runCell.width != 1 || runCell.invisible)
						break;

					cell_style_key_t runKey;
					runKey.fontVariant = (runCell.bold ? 1 : 0) | (runCell.italic ? 2 : 0);
					if(runCell.inverse)
					{
						GhosttyColorRgb color = runCell.hasBackground ? runCell.background : _colors.background;
						runKey.hasColor = true; runKey.r = color.r; runKey.g = color.g; runKey.b = color.b;
					}
					else
					{
						runKey.hasColor = runCell.hasForeground;
						runKey.r = runCell.foreground.r; runKey.g = runCell.foreground.g; runKey.b = runCell.foreground.b;
					}
					runKey.faint = runCell.faint;
					runKey.underline = runCell.underline;
					runKey.strikethrough = runCell.strikethrough;

					if(!(runKey == key))
						break;

					if(runCell.textLen)
							[runText appendString:[[NSString alloc] initWithBytes:runCell.text length:runCell.textLen encoding:NSUTF8StringEncoding] ?: @" "];
					else	[runText appendString:@" "];
					++col;
				}
			}

			CGFloat runX = kTerminalViewPadding + runStart * _cellWidth;
			CGFloat baseline = rowY + _cellAscent;

			GhosttyColorRgb fg = key.hasColor ? (GhosttyColorRgb){ key.r, key.g, key.b } : _colors.foreground;
			CGFloat alpha = key.faint ? 0.6 : 1.0;
			NSColor* textColor = [NSColor colorWithSRGBRed:fg.r/255.0 green:fg.g/255.0 blue:fg.b/255.0 alpha:alpha];

			if([runText stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet].length > 0)
			{
				NSDictionary* attributes = @{
					NSFontAttributeName:            [self fontForVariant:key.fontVariant],
					NSForegroundColorAttributeName: textColor,
				};
				NSAttributedString* attributedString = [[NSAttributedString alloc] initWithString:runText attributes:attributes];
				CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)attributedString);
				CGContextSetTextPosition(context, runX, baseline);
				CTLineDraw(line, context);
				CFRelease(line);
			}

			NSUInteger runCells = isWide ? 2 : (col - runStart);
			CGFloat runWidth = runCells * _cellWidth;
			CGContextSetRGBFillColor(context, fg.r/255.0, fg.g/255.0, fg.b/255.0, alpha);
			if(key.underline != GHOSTTY_SGR_UNDERLINE_NONE)
			{
				CGContextFillRect(context, CGRectMake(runX, rowY + _cellHeight - 2, runWidth, 1));
				if(key.underline == GHOSTTY_SGR_UNDERLINE_DOUBLE)
					CGContextFillRect(context, CGRectMake(runX, rowY + _cellHeight - 4, runWidth, 1));
			}
			if(key.strikethrough)
				CGContextFillRect(context, CGRectMake(runX, rowY + round(_cellHeight/2), runWidth, 1));

			if(isWide)
				col = runStart + 2;
		}
	}

	// ⌘-hover link underline
	if(!_linkSpans.empty())
	{
		CGContextSetRGBFillColor(context, _colors.foreground.r/255.0, _colors.foreground.g/255.0, _colors.foreground.b/255.0, 1);
		for(auto const& span : _linkSpans)
		{
			if((NSInteger)span.row < firstRow || (NSInteger)span.row > lastRow)
				continue;
			CGFloat rowY = kTerminalViewPadding + span.row * _cellHeight;
			CGContextFillRect(context, CGRectMake(kTerminalViewPadding + span.colBegin * _cellWidth, rowY + _cellHeight - 2, (span.colEnd - span.colBegin) * _cellWidth, 1));
		}
	}

	[self drawCursorInContext:context];
	[self drawMarkedTextInContext:context];
}

- (void)drawCursorInContext:(CGContextRef)context
{
	if(!_cursor.hasPosition || !_cursor.visible)
		return;
	if(_markedText.length > 0)
		return; // the composition overlay replaces the cursor

	NSUInteger cursorColumn = _cursor.x >= 1 && _cursor.wideTail ? _cursor.x - 1 : _cursor.x;
	NSRect cellRect = [self rectForCellAtColumn:cursorColumn row:_cursor.y];
	if(cursorColumn < _cachedColumns && _cursor.y < _cachedRows && _grid[_cursor.y * _cachedColumns + cursorColumn].width == 2)
		cellRect.size.width *= 2;

	GhosttyColorRgb cursorColor = _colors.hasCursorColor ? _colors.cursor : _colors.foreground;
	CGContextSetRGBFillColor(context, cursorColor.r/255.0, cursorColor.g/255.0, cursorColor.b/255.0, 1);

	BOOL focused = self.window.isKeyWindow && self.window.firstResponder == self;
	if(!focused)
	{
		CGContextSetRGBStrokeColor(context, cursorColor.r/255.0, cursorColor.g/255.0, cursorColor.b/255.0, 1);
		CGContextStrokeRectWithWidth(context, CGRectInset(cellRect, 0.5, 0.5), 1);
		return;
	}

	switch(_cursor.style)
	{
		case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BAR:
			CGContextFillRect(context, CGRectMake(NSMinX(cellRect), NSMinY(cellRect), 2, NSHeight(cellRect)));
			break;

		case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_UNDERLINE:
			CGContextFillRect(context, CGRectMake(NSMinX(cellRect), NSMaxY(cellRect) - 2, NSWidth(cellRect), 2));
			break;

		case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK_HOLLOW:
			CGContextSetRGBStrokeColor(context, cursorColor.r/255.0, cursorColor.g/255.0, cursorColor.b/255.0, 1);
			CGContextStrokeRectWithWidth(context, CGRectInset(cellRect, 0.5, 0.5), 1);
			break;

		case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK:
		default:
		{
			CGContextFillRect(context, cellRect);

			// Redraw the covered glyph in the background color
			if(cursorColumn < _cachedColumns && _cursor.y < _cachedRows)
			{
				terminal_cell_t const& cell = _grid[_cursor.y * _cachedColumns + cursorColumn];
				if(cell.textLen && !cell.invisible)
				{
					NSString* text = [[NSString alloc] initWithBytes:cell.text length:cell.textLen encoding:NSUTF8StringEncoding];
					if(text.length)
					{
						NSColor* glyphColor = [NSColor colorWithSRGBRed:_colors.background.r/255.0 green:_colors.background.g/255.0 blue:_colors.background.b/255.0 alpha:1];
						NSDictionary* attributes = @{
							NSFontAttributeName:            [self fontForVariant:(cell.bold ? 1 : 0) | (cell.italic ? 2 : 0)],
							NSForegroundColorAttributeName: glyphColor,
						};
						NSAttributedString* attributedString = [[NSAttributedString alloc] initWithString:text attributes:attributes];
						CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)attributedString);
						CGContextSetTextPosition(context, NSMinX(cellRect), NSMinY(cellRect) + _cellAscent);
						CTLineDraw(line, context);
						CFRelease(line);
					}
				}
			}
			break;
		}
	}
}

- (void)drawMarkedTextInContext:(CGContextRef)context
{
	if(_markedText.length == 0 || !_cursor.hasPosition)
		return;

	NSRect cellRect = [self rectForCellAtColumn:_cursor.x row:_cursor.y];
	NSMutableAttributedString* str = [_markedText mutableCopy];
	[str addAttributes:@{
		NSFontAttributeName:            _font,
		NSForegroundColorAttributeName: [NSColor colorWithSRGBRed:_colors.foreground.r/255.0 green:_colors.foreground.g/255.0 blue:_colors.foreground.b/255.0 alpha:1],
		NSUnderlineStyleAttributeName:  @(NSUnderlineStyleThick),
	} range:NSMakeRange(0, str.length)];

	CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)str);
	CGFloat width = ceil(CTLineGetTypographicBounds(line, NULL, NULL, NULL));

	CGContextSetRGBFillColor(context, _colors.background.r/255.0, _colors.background.g/255.0, _colors.background.b/255.0, 1);
	CGContextFillRect(context, CGRectMake(NSMinX(cellRect), NSMinY(cellRect), width, _cellHeight));
	CGContextSetTextPosition(context, NSMinX(cellRect), NSMinY(cellRect) + _cellAscent);
	CTLineDraw(line, context);
	CFRelease(line);
}

// =============
// = Key input =
// =============

- (void)writeToPTY:(NSData*)data snapToBottom:(BOOL)snapToBottom
{
	if(!data.length)
		return;
	if(snapToBottom)
	{
		[_emulator scrollViewportToBottom];
		[self refreshFromEmulator];
		self.needsDisplay = YES;
	}
	if(_writeDataHandler)
		_writeDataHandler(data);
}

- (void)handleTerminalKeyEvent:(NSEvent*)event
{
	GhosttyKey key = key_for_keycode(event.keyCode);
	GhosttyMods mods = mods_for_flags(event.modifierFlags);

	NSString* text = nil;
	uint32_t unshifted = 0;
	if(event.type == NSEventTypeKeyDown)
	{
		if(is_usable_text(event.characters))
			text = event.characters;
		NSString* unshiftedText = [event charactersByApplyingModifiers:0] ?: event.charactersIgnoringModifiers;
		if(unshiftedText.length == 1)
		{
			unichar ch = [unshiftedText characterAtIndex:0];
			if(ch >= 0x20 && ch != 0x7F && !(ch >= 0xF700 && ch <= 0xF8FF))
				unshifted = ch;
		}
	}

	GhosttyMods consumed = text ? (mods & (GHOSTTY_MODS_SHIFT|GHOSTTY_MODS_ALT)) : 0;
	NSData* data = [_emulator encodeKey:key action:event.isARepeat ? GHOSTTY_KEY_ACTION_REPEAT : GHOSTTY_KEY_ACTION_PRESS mods:mods consumedMods:consumed text:text unshiftedCodepoint:unshifted];
	[self writeToPTY:data snapToBottom:YES];
}

- (void)encodeKeypress:(GhosttyKey)key mods:(GhosttyMods)mods
{
	NSData* data = [_emulator encodeKey:key action:GHOSTTY_KEY_ACTION_PRESS mods:mods consumedMods:0 text:nil unshiftedCodepoint:0];
	[self writeToPTY:data snapToBottom:YES];
}

// TextMate’s terminal-management shortcuts are control-only combos (⌃`
// toggles, ⌃⇧` opens a new terminal), which the code below would otherwise
// consume for the PTY. Match against the live menu items — not hardcoded
// keys — so equivalents customized in System Settings keep working. Shift
// is ignored in the flag comparison because the key-equivalent character
// itself encodes it (“~” vs “`”, uppercase vs lowercase).
static BOOL EventMatchesTerminalMenuItem (NSEvent* event, NSMenu* menu)
{
	for(NSMenuItem* item in menu.itemArray)
	{
		if(item.hasSubmenu)
		{
			if(EventMatchesTerminalMenuItem(event, item.submenu))
				return YES;
		}
		else if(item.action == @selector(toggleTerminal:) || item.action == @selector(newTerminal:) || item.action == @selector(nextTerminal:) || item.action == @selector(previousTerminal:) || item.action == @selector(closeTerminal:))
		{
			NSEventModifierFlags const mask = (NSEventModifierFlagCommand|NSEventModifierFlagControl|NSEventModifierFlagOption|NSEventModifierFlagShift) & ~NSEventModifierFlagShift;
			if(item.keyEquivalent.length && [item.keyEquivalent isEqualToString:event.charactersIgnoringModifiers] && (item.keyEquivalentModifierMask & mask) == (event.modifierFlags & mask))
				return YES;
		}
	}
	return NO;
}

- (BOOL)performKeyEquivalent:(NSEvent*)event
{
	if(event.type != NSEventTypeKeyDown)
		return NO;
	if(!(NSApp.isActive && self.window.isKeyWindow && self.window.firstResponder == self))
		return NO;

	NSEventModifierFlags flags = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
	if(flags & NSEventModifierFlagCommand)
		return NO; // key equivalents carrying ⌘ stay with TextMate’s menus

	if(self.hasMarkedText)
		return NO; // let the input context finish/cancel the composition

	// TextMate’s own terminal-management shortcuts (⌃`, ⌃⇧`, …) must beat
	// the PTY while the terminal has focus — hand them back to the menu.
	if(EventMatchesTerminalMenuItem(event, NSApp.mainMenu))
		return NO;

	// Consume control combos and function keys here: some (⌃-arrows,
	// ⌃-delete) never reach -keyDown:, and returning YES also keeps
	// bundle-item key equivalents (e.g. ⌃C) from stealing them.
	if((flags & NSEventModifierFlagControl) || is_special_key(event.keyCode))
	{
		[self handleTerminalKeyEvent:event];
		return YES;
	}
	return NO;
}

- (void)keyDown:(NSEvent*)event
{
	if(self.hasMarkedText)
	{
		[self.inputContext handleEvent:event];
		return;
	}

	NSEventModifierFlags flags = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
	if((flags & NSEventModifierFlagControl) || is_special_key(event.keyCode))
			[self handleTerminalKeyEvent:event];
	else	[self.inputContext handleEvent:event];
}

- (void)doCommandBySelector:(SEL)selector
{
	if(selector == @selector(insertNewline:) || selector == @selector(insertNewlineIgnoringFieldEditor:) || selector == @selector(insertLineBreak:))
		[self encodeKeypress:GHOSTTY_KEY_ENTER mods:0];
	else if(selector == @selector(insertTab:))
		[self encodeKeypress:GHOSTTY_KEY_TAB mods:0];
	else if(selector == @selector(insertBacktab:))
		[self encodeKeypress:GHOSTTY_KEY_TAB mods:GHOSTTY_MODS_SHIFT];
	else if(selector == @selector(deleteBackward:))
		[self encodeKeypress:GHOSTTY_KEY_BACKSPACE mods:0];
	else if(selector == @selector(deleteWordBackward:))
		[self encodeKeypress:GHOSTTY_KEY_BACKSPACE mods:GHOSTTY_MODS_ALT];
	else if(selector == @selector(deleteForward:))
		[self encodeKeypress:GHOSTTY_KEY_DELETE mods:0];
	else if(selector == @selector(cancelOperation:))
		[self encodeKeypress:GHOSTTY_KEY_ESCAPE mods:0];
	else if(selector == @selector(moveUp:))
		[self encodeKeypress:GHOSTTY_KEY_ARROW_UP mods:0];
	else if(selector == @selector(moveDown:))
		[self encodeKeypress:GHOSTTY_KEY_ARROW_DOWN mods:0];
	else if(selector == @selector(moveLeft:))
		[self encodeKeypress:GHOSTTY_KEY_ARROW_LEFT mods:0];
	else if(selector == @selector(moveRight:))
		[self encodeKeypress:GHOSTTY_KEY_ARROW_RIGHT mods:0];
	else if(selector == @selector(scrollPageUp:))
		[self encodeKeypress:GHOSTTY_KEY_PAGE_UP mods:0];
	else if(selector == @selector(scrollPageDown:))
		[self encodeKeypress:GHOSTTY_KEY_PAGE_DOWN mods:0];
	else if(selector == @selector(scrollToBeginningOfDocument:))
		[self encodeKeypress:GHOSTTY_KEY_HOME mods:0];
	else if(selector == @selector(scrollToEndOfDocument:))
		[self encodeKeypress:GHOSTTY_KEY_END mods:0];
	// Anything else is deliberately ignored — the terminal has no
	// equivalent, and beeping on every unknown selector is worse.
}

// ====================================
// = NSTextInputClient (IME, minimal) =
// ====================================

- (void)insertText:(id)string replacementRange:(NSRange)replacementRange
{
	NSString* text = [string isKindOfClass:NSAttributedString.class] ? [string string] : string;
	if(_markedText.length)
	{
		[_markedText deleteCharactersInRange:NSMakeRange(0, _markedText.length)];
		[self invalidateCursorCell];
	}
	if(text.length)
		[self writeToPTY:[text dataUsingEncoding:NSUTF8StringEncoding] snapToBottom:YES];
}

- (void)setMarkedText:(id)string selectedRange:(NSRange)selectedRange replacementRange:(NSRange)replacementRange
{
	NSAttributedString* str = [string isKindOfClass:NSAttributedString.class] ? string : [[NSAttributedString alloc] initWithString:string ?: @""];
	[_markedText setAttributedString:str];
	_markedSelection = selectedRange;
	self.needsDisplay = YES;
}

- (void)unmarkText
{
	[_markedText deleteCharactersInRange:NSMakeRange(0, _markedText.length)];
	self.needsDisplay = YES;
}

- (BOOL)hasMarkedText
{
	return _markedText.length > 0;
}

- (NSRange)markedRange
{
	return _markedText.length ? NSMakeRange(0, _markedText.length) : NSMakeRange(NSNotFound, 0);
}

- (NSRange)selectedRange
{
	return NSMakeRange(NSNotFound, 0);
}

- (NSArray<NSAttributedStringKey>*)validAttributesForMarkedText
{
	return @[ ];
}

- (NSAttributedString*)attributedSubstringForProposedRange:(NSRange)range actualRange:(NSRangePointer)actualRange
{
	return nil;
}

- (NSUInteger)characterIndexForPoint:(NSPoint)point
{
	return 0;
}

- (NSRect)firstRectForCharacterRange:(NSRange)range actualRange:(NSRangePointer)actualRange
{
	if(actualRange)
		*actualRange = range;
	NSRect rect = _cursor.hasPosition ? [self rectForCellAtColumn:_cursor.x row:_cursor.y] : NSMakeRect(kTerminalViewPadding, kTerminalViewPadding, _cellWidth, _cellHeight);
	rect = [self convertRect:rect toView:nil];
	return [self.window convertRectToScreen:rect];
}

// =====================
// = ⌘-click file links =
// =====================

- (void)updateTrackingAreas
{
	[super updateTrackingAreas];
	if(_linkTrackingArea)
		[self removeTrackingArea:_linkTrackingArea];
	_linkTrackingArea = [[NSTrackingArea alloc] initWithRect:NSZeroRect options:NSTrackingMouseEnteredAndExited|NSTrackingMouseMoved|NSTrackingActiveInActiveApp|NSTrackingInVisibleRect owner:self userInfo:nil];
	[self addTrackingArea:_linkTrackingArea];
}

- (void)mouseMoved:(NSEvent*)event
{
	[self updateLinkIndicationForModifierFlags:event.modifierFlags location:event.locationInWindow];
}

- (void)mouseExited:(NSEvent*)event
{
	[self clearLinkIndication];
}

// The flags-changed monitor has no mouse position of its own
- (void)updateLinkIndicationForModifierFlags:(NSEventModifierFlags)flags
{
	if(self.window)
		[self updateLinkIndicationForModifierFlags:flags location:self.window.mouseLocationOutsideOfEventStream];
}

- (void)updateLinkIndicationForModifierFlags:(NSEventModifierFlags)flags location:(NSPoint)windowLocation
{
	if(!(flags & NSEventModifierFlagCommand) || !_openFileHandler || !self.window)
		return [self clearLinkIndication];

	NSPoint point = [self convertPoint:windowLocation fromView:nil];
	if(!NSMouseInRect(point, self.bounds, self.isFlipped))
		return [self clearLinkIndication];

	NSUInteger column, row;
	[self pointToCell:point column:&column row:&row];
	if(_linkLookupValid && column == _linkLookupColumn && row == _linkLookupRow)
		return; // detection already ran for this cell

	[self detectLinkAtColumn:column row:row];
}

- (void)detectLinkAtColumn:(NSUInteger)column row:(NSUInteger)row
{
	[self clearLinkIndication];
	_linkLookupValid  = YES;
	_linkLookupColumn = column;
	_linkLookupRow    = row;

	std::string text;
	size_t hoverOffset = 0;
	std::vector<terminal_link_cell_t> cells;
	if(![_emulator logicalLineAtColumn:column row:row text:&text hoverOffset:&hoverOffset cells:&cells])
		return;

	terminal::file_link_t link;
	if(!terminal::link_at_offset(text, hoverOffset, link))
		return;

	NSString* resolvedPath = [self resolveLinkPath:link.path];
	if(!resolvedPath && !link.alt_path.empty())
		resolvedPath = [self resolveLinkPath:link.alt_path];
	if(!resolvedPath)
		return;

	// Merge the visible cells covering the reference into per-row spans
	std::map<NSUInteger, std::pair<NSUInteger, NSUInteger>> rowSpans; // row → [min, max] column
	for(auto const& cell : cells)
	{
		if(cell.byteEnd <= link.first || cell.byteBegin >= link.last)
			continue;
		if(cell.viewportRow < 0 || cell.viewportRow >= (NSInteger)_cachedRows)
			continue;
		auto it = rowSpans.find(cell.viewportRow);
		if(it == rowSpans.end())
				rowSpans.emplace((NSUInteger)cell.viewportRow, std::make_pair(cell.column, cell.column));
		else	it->second = std::make_pair(std::min(it->second.first, cell.column), std::max(it->second.second, cell.column));
	}

	for(auto const& pair : rowSpans)
	{
		_linkSpans.push_back({ pair.first, pair.second.first, pair.second.second + 1 });
		[self setNeedsDisplayInRect:[self rectForRow:pair.first]];
	}

	_linkActive = YES;
	_linkPath   = resolvedPath;
	_linkLine   = link.line;
	_linkColumn = link.column;

	[NSCursor.pointingHandCursor set];
	_linkCursorSet = YES;
}

// Expands ‘~’, resolves relative paths against the session’s live working
// directory, and requires an existing regular file — a candidate that does
// not exist on disk is not a link.
- (NSString*)resolveLinkPath:(std::string const&)path
{
	NSString* candidate = [NSString stringWithUTF8String:path.c_str()];
	if(!candidate.length)
		return nil;
	if([candidate hasPrefix:@"~"])
		candidate = candidate.stringByExpandingTildeInPath;
	if(!candidate.absolutePath)
	{
		NSString* base = _workingDirectoryProvider ? _workingDirectoryProvider() : nil;
		if(!base.length)
			return nil;
		candidate = [base stringByAppendingPathComponent:candidate];
	}
	candidate = candidate.stringByStandardizingPath;

	BOOL isDirectory = NO;
	if([NSFileManager.defaultManager fileExistsAtPath:candidate isDirectory:&isDirectory] && !isDirectory)
		return candidate;
	return nil;
}

- (void)clearLinkIndication
{
	_linkLookupValid = NO;
	if(_linkCursorSet)
	{
		[NSCursor.arrowCursor set];
		_linkCursorSet = NO;
	}
	if(!_linkActive)
		return;
	for(auto const& span : _linkSpans)
		[self setNeedsDisplayInRect:[self rectForRow:span.row]];
	_linkSpans.clear();
	_linkActive = NO;
	_linkPath   = nil;
	_linkLine   = 0;
	_linkColumn = 0;
}

// =========
// = Mouse =
// =========

- (NSPoint)mouseReportPositionForEvent:(NSEvent*)event
{
	NSUInteger column, row;
	[self pointToCell:[self convertPoint:event.locationInWindow fromView:nil] column:&column row:&row];
	return NSMakePoint(column * 10 + 5, row * 10 + 5); // matches the synthetic mouse geometry
}

- (void)mouseDown:(NSEvent*)event
{
	if((event.modifierFlags & NSEventModifierFlagCommand) && _openFileHandler)
	{
		NSUInteger column, row;
		[self pointToCell:[self convertPoint:event.locationInWindow fromView:nil] column:&column row:&row];
		[self detectLinkAtColumn:column row:row]; // recompute at the click point (hover state may be stale)
		if(_linkActive)
		{
			void(^handler)(NSString*, NSUInteger, NSUInteger) = _openFileHandler;
			NSString* path = _linkPath;
			NSUInteger line = _linkLine, linkColumn = _linkColumn;
			[self clearLinkIndication];
			_linkClickPending = YES; // swallow the matching mouseUp
			handler(path, line, linkColumn);
			return; // never starts a selection or reaches mouse reporting
		}
	}

	[self.window makeFirstResponder:self];

	NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
	if([_emulator mouseTrackingActive] && !(event.modifierFlags & NSEventModifierFlagOption))
	{
		_mouseReporting = YES;
		[self writeToPTY:[_emulator encodeMouseAction:GHOSTTY_MOUSE_ACTION_PRESS button:GHOSTTY_MOUSE_BUTTON_LEFT hasButton:YES mods:mods_for_flags(event.modifierFlags) position:[self mouseReportPositionForEvent:event] anyButtonPressed:NO] snapToBottom:NO];
		return;
	}

	_mouseReporting = NO;
	NSUInteger column, row;
	[self pointToCell:point column:&column row:&row];
	[_emulator selectionBeginAtColumn:column row:row position:point timestamp:event.timestamp clickCount:event.clickCount];
	[self refreshFromEmulator];
	self.needsDisplay = YES;
}

- (void)mouseDragged:(NSEvent*)event
{
	if(_linkClickPending)
		return; // the ⌘-click was handled as a link; no selection drag to feed

	NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
	if(_mouseReporting)
	{
		[self writeToPTY:[_emulator encodeMouseAction:GHOSTTY_MOUSE_ACTION_MOTION button:GHOSTTY_MOUSE_BUTTON_LEFT hasButton:YES mods:mods_for_flags(event.modifierFlags) position:[self mouseReportPositionForEvent:event] anyButtonPressed:YES] snapToBottom:NO];
		return;
	}

	NSUInteger column, row;
	[self pointToCell:point column:&column row:&row];
	GhosttySelectionGestureGeometry geometry = {
		.columns       = (uint32_t)_cachedColumns,
		.cell_width    = (uint32_t)_cellWidth,
		.padding_left  = (uint32_t)kTerminalViewPadding,
		.screen_height = (uint32_t)NSHeight(self.bounds),
	};
	[_emulator selectionDragToColumn:column row:row position:point geometry:geometry];
	[self refreshFromEmulator];
	self.needsDisplay = YES;
}

- (void)mouseUp:(NSEvent*)event
{
	if(_linkClickPending)
	{
		_linkClickPending = NO;
		return; // the ⌘-click was handled as a link; no selection to end
	}

	NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
	if(_mouseReporting)
	{
		[self writeToPTY:[_emulator encodeMouseAction:GHOSTTY_MOUSE_ACTION_RELEASE button:GHOSTTY_MOUSE_BUTTON_LEFT hasButton:YES mods:mods_for_flags(event.modifierFlags) position:[self mouseReportPositionForEvent:event] anyButtonPressed:NO] snapToBottom:NO];
		_mouseReporting = NO;
		return;
	}

	NSUInteger column, row;
	[self pointToCell:point column:&column row:&row];
	[_emulator selectionEndAtColumn:column row:row];
}

- (void)rightMouseDown:(NSEvent*)event
{
	if([_emulator mouseTrackingActive] && !(event.modifierFlags & NSEventModifierFlagOption))
			[self writeToPTY:[_emulator encodeMouseAction:GHOSTTY_MOUSE_ACTION_PRESS button:GHOSTTY_MOUSE_BUTTON_RIGHT hasButton:YES mods:mods_for_flags(event.modifierFlags) position:[self mouseReportPositionForEvent:event] anyButtonPressed:NO] snapToBottom:NO];
	else	[super rightMouseDown:event];
}

- (void)rightMouseUp:(NSEvent*)event
{
	if([_emulator mouseTrackingActive] && !(event.modifierFlags & NSEventModifierFlagOption))
			[self writeToPTY:[_emulator encodeMouseAction:GHOSTTY_MOUSE_ACTION_RELEASE button:GHOSTTY_MOUSE_BUTTON_RIGHT hasButton:YES mods:mods_for_flags(event.modifierFlags) position:[self mouseReportPositionForEvent:event] anyButtonPressed:NO] snapToBottom:NO];
	else	[super rightMouseUp:event];
}

- (void)scrollWheel:(NSEvent*)event
{
	CGFloat delta = event.scrollingDeltaY;
	if(event.hasPreciseScrollingDeltas)
	{
		_scrollResidue += delta / _cellHeight;
	}
	else
	{
		_scrollResidue += delta;
	}

	NSInteger lines = (NSInteger)_scrollResidue;
	if(lines == 0)
		return;
	_scrollResidue -= lines;

	NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
	if([_emulator mouseTrackingActive] && !(event.modifierFlags & NSEventModifierFlagOption))
	{
		GhosttyMouseButton button = lines > 0 ? GHOSTTY_MOUSE_BUTTON_FOUR : GHOSTTY_MOUSE_BUTTON_FIVE;
		for(NSInteger i = 0; i < labs(lines); ++i)
		{
			[self writeToPTY:[_emulator encodeMouseAction:GHOSTTY_MOUSE_ACTION_PRESS button:button hasButton:YES mods:mods_for_flags(event.modifierFlags) position:[self mouseReportPositionForEvent:event] anyButtonPressed:NO] snapToBottom:NO];
			[self writeToPTY:[_emulator encodeMouseAction:GHOSTTY_MOUSE_ACTION_RELEASE button:button hasButton:YES mods:mods_for_flags(event.modifierFlags) position:[self mouseReportPositionForEvent:event] anyButtonPressed:NO] snapToBottom:NO];
		}
	}
	else if([_emulator altScreenActive])
	{
		if([_emulator altScrollModeActive])
		{
			GhosttyKey key = lines > 0 ? GHOSTTY_KEY_ARROW_UP : GHOSTTY_KEY_ARROW_DOWN;
			for(NSInteger i = 0; i < labs(lines); ++i)
			{
				NSData* data = [_emulator encodeKey:key action:GHOSTTY_KEY_ACTION_PRESS mods:0 consumedMods:0 text:nil unshiftedCodepoint:0];
				[self writeToPTY:data snapToBottom:NO];
			}
		}
	}
	else
	{
		[_emulator scrollViewportBy:-lines];
		[self clearLinkIndication]; // link cells shifted; ⌘-hover recomputes
		[self refreshFromEmulator];
		self.needsDisplay = YES;
	}
}

// ==============================
// = Clipboard / menu actions =
// ==============================

- (void)copy:(id)sender
{
	NSString* string = [_emulator selectedString];
	if(string.length)
	{
		[NSPasteboard.generalPasteboard clearContents];
		[NSPasteboard.generalPasteboard setString:string forType:NSPasteboardTypeString];
	}
}

- (void)paste:(id)sender
{
	NSString* string = [NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString];
	if(string.length)
		[self writeToPTY:[_emulator encodePaste:string] snapToBottom:YES];
}

- (void)selectAll:(id)sender
{
	[_emulator selectAll];
	[self refreshFromEmulator];
	self.needsDisplay = YES;
}

- (BOOL)validateMenuItem:(NSMenuItem*)menuItem
{
	if(menuItem.action == @selector(copy:))
		return [_emulator hasSelection];
	if(menuItem.action == @selector(paste:))
		return [NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString].length > 0;
	if(menuItem.action == @selector(selectAll:))
		return YES;
	return YES;
}
@end
