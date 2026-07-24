#import "TerminalEmulator.h"
#include <algorithm>
#include <mutex>
#include <string>
#include <vector>

@implementation TerminalEmulator
{
	GhosttyTerminal _terminal;
	GhosttyRenderState _renderState;
	GhosttyRenderStateRowIterator _rowIterator;
	GhosttyRenderStateRowCells _rowCells;
	GhosttyKeyEncoder _keyEncoder;
	GhosttyKeyEvent _keyEvent;
	GhosttyMouseEncoder _mouseEncoder;
	GhosttyMouseEvent _mouseEvent;
	GhosttyMouseEncoderSize _mouseGeometry;
	GhosttySelectionGesture _gesture;
	GhosttySelectionGestureEvent _pressEvent;
	GhosttySelectionGestureEvent _dragEvent;
	GhosttySelectionGestureEvent _releaseEvent;

	std::mutex _terminalMutex;
	std::vector<terminal_cell_t> _cellBuffer;

	// Pending effect data, only touched while _terminalMutex is held
	// (the callbacks fire synchronously inside ghostty_terminal_vt_write).
	std::string _pendingWriteBack;
	std::string _pendingClipboard;
	bool _pendingTitleChanged, _pendingPwdChanged, _pendingBell, _pendingClipboardChanged;

	uint16_t _gridColumns, _gridRows;
	uint32_t _cellWidth, _cellHeight;
}

// ============================
// = Effect callbacks (all fire inside ghostty_terminal_vt_write while we hold the lock — they may only stash data) =
// ============================

static void write_pty_callback (GhosttyTerminal terminal, void* userdata, uint8_t const* data, size_t len)
{
	TerminalEmulator* self = (__bridge TerminalEmulator*)userdata;
	self->_pendingWriteBack.append((char const*)data, len);
}

static void title_changed_callback (GhosttyTerminal terminal, void* userdata)
{
	((__bridge TerminalEmulator*)userdata)->_pendingTitleChanged = true;
}

static void pwd_changed_callback (GhosttyTerminal terminal, void* userdata)
{
	((__bridge TerminalEmulator*)userdata)->_pendingPwdChanged = true;
}

static void bell_callback (GhosttyTerminal terminal, void* userdata)
{
	((__bridge TerminalEmulator*)userdata)->_pendingBell = true;
}

static GhosttyClipboardWriteResult clipboard_write_callback (GhosttyTerminal terminal, void* userdata, GhosttyClipboardWrite const* write)
{
	TerminalEmulator* self = (__bridge TerminalEmulator*)userdata;
	if(write->contents_len == 0)
		return GHOSTTY_CLIPBOARD_WRITE_RESULT_SUCCESS;
	for(size_t i = 0; i < write->contents_len; ++i)
	{
		GhosttyClipboardContent const& content = write->contents[i];
		if(content.mime.len == 10 && strncmp((char const*)content.mime.ptr, "text/plain", 10) == 0)
		{
			self->_pendingClipboard.assign((char const*)content.data.ptr, content.data.len);
			self->_pendingClipboardChanged = true;
			return GHOSTTY_CLIPBOARD_WRITE_RESULT_SUCCESS;
		}
	}
	return GHOSTTY_CLIPBOARD_WRITE_RESULT_UNSUPPORTED;
}

static bool size_callback (GhosttyTerminal terminal, void* userdata, GhosttySizeReportSize* outSize)
{
	TerminalEmulator* self = (__bridge TerminalEmulator*)userdata;
	outSize->rows        = self->_gridRows;
	outSize->columns     = self->_gridColumns;
	outSize->cell_width  = self->_cellWidth;
	outSize->cell_height = self->_cellHeight;
	return true;
}

static bool device_attributes_callback (GhosttyTerminal terminal, void* userdata, GhosttyDeviceAttributes* outAttrs)
{
	outAttrs->primary.conformance_level = GHOSTTY_DA_CONFORMANCE_VT220;
	outAttrs->primary.features[0]       = GHOSTTY_DA_FEATURE_COLUMNS_132;
	outAttrs->primary.features[1]       = GHOSTTY_DA_FEATURE_SELECTIVE_ERASE;
	outAttrs->primary.features[2]       = GHOSTTY_DA_FEATURE_ANSI_COLOR;
	outAttrs->primary.num_features      = 3;
	outAttrs->secondary.device_type      = GHOSTTY_DA_DEVICE_TYPE_VT220;
	outAttrs->secondary.firmware_version = 10000;
	outAttrs->secondary.rom_cartridge    = 0;
	outAttrs->tertiary.unit_id           = 0x544D5445; // “TMTE”
	return true;
}

static GhosttyString xtversion_callback (GhosttyTerminal terminal, void* userdata)
{
	static char const* version = "TextMate";
	return (GhosttyString){ (uint8_t const*)version, strlen(version) };
}

// ==============
// = Life cycle =
// ==============

- (instancetype)initWithColumns:(NSUInteger)columns rows:(NSUInteger)rows maxScrollback:(NSUInteger)maxScrollback
{
	if(self = [super init])
	{
		_gridColumns = std::max<NSUInteger>(columns, 2);
		_gridRows    = std::max<NSUInteger>(rows, 2);
		_cellWidth   = 8;
		_cellHeight  = 16;

		GhosttyTerminalOptions options = { .cols = _gridColumns, .rows = _gridRows, .max_scrollback = maxScrollback };
		if(ghostty_terminal_new(NULL, &_terminal, options) != GHOSTTY_SUCCESS)
			return nil;
		ghostty_terminal_resize(_terminal, _gridColumns, _gridRows, _cellWidth, _cellHeight);

		void* userdata = (__bridge void*)self;
		ghostty_terminal_set(_terminal, GHOSTTY_TERMINAL_OPT_USERDATA, userdata);
		ghostty_terminal_set(_terminal, GHOSTTY_TERMINAL_OPT_WRITE_PTY, (void const*)&write_pty_callback);
		ghostty_terminal_set(_terminal, GHOSTTY_TERMINAL_OPT_TITLE_CHANGED, (void const*)&title_changed_callback);
		ghostty_terminal_set(_terminal, GHOSTTY_TERMINAL_OPT_PWD_CHANGED, (void const*)&pwd_changed_callback);
		ghostty_terminal_set(_terminal, GHOSTTY_TERMINAL_OPT_BELL, (void const*)&bell_callback);
		ghostty_terminal_set(_terminal, GHOSTTY_TERMINAL_OPT_CLIPBOARD_WRITE, (void const*)&clipboard_write_callback);
		ghostty_terminal_set(_terminal, GHOSTTY_TERMINAL_OPT_SIZE, (void const*)&size_callback);
		ghostty_terminal_set(_terminal, GHOSTTY_TERMINAL_OPT_DEVICE_ATTRIBUTES, (void const*)&device_attributes_callback);
		ghostty_terminal_set(_terminal, GHOSTTY_TERMINAL_OPT_XTVERSION, (void const*)&xtversion_callback);

		if(ghostty_render_state_new(NULL, &_renderState) != GHOSTTY_SUCCESS
			|| ghostty_render_state_row_iterator_new(NULL, &_rowIterator) != GHOSTTY_SUCCESS
			|| ghostty_render_state_row_cells_new(NULL, &_rowCells) != GHOSTTY_SUCCESS
			|| ghostty_key_encoder_new(NULL, &_keyEncoder) != GHOSTTY_SUCCESS
			|| ghostty_key_event_new(NULL, &_keyEvent) != GHOSTTY_SUCCESS
			|| ghostty_mouse_encoder_new(NULL, &_mouseEncoder) != GHOSTTY_SUCCESS
			|| ghostty_mouse_event_new(NULL, &_mouseEvent) != GHOSTTY_SUCCESS
			|| ghostty_selection_gesture_new(NULL, &_gesture) != GHOSTTY_SUCCESS
			|| ghostty_selection_gesture_event_new(NULL, &_pressEvent, GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_PRESS) != GHOSTTY_SUCCESS
			|| ghostty_selection_gesture_event_new(NULL, &_dragEvent, GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_DRAG) != GHOSTTY_SUCCESS
			|| ghostty_selection_gesture_event_new(NULL, &_releaseEvent, GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_RELEASE) != GHOSTTY_SUCCESS)
		{
			return nil;
		}

		_mouseGeometry = GHOSTTY_INIT_SIZED(GhosttyMouseEncoderSize);
		_mouseGeometry.screen_width  = _gridColumns * _cellWidth;
		_mouseGeometry.screen_height = _gridRows * _cellHeight;
		_mouseGeometry.cell_width    = _cellWidth;
		_mouseGeometry.cell_height   = _cellHeight;

		bool trackLastCell = true;
		ghostty_mouse_encoder_setopt(_mouseEncoder, GHOSTTY_MOUSE_ENCODER_OPT_TRACK_LAST_CELL, &trackLastCell);

		_cellBuffer.resize(_gridColumns);
	}
	return self;
}

- (void)dealloc
{
	ghostty_selection_gesture_event_free(_releaseEvent);
	ghostty_selection_gesture_event_free(_dragEvent);
	ghostty_selection_gesture_event_free(_pressEvent);
	ghostty_selection_gesture_free(_gesture, _terminal);
	ghostty_mouse_event_free(_mouseEvent);
	ghostty_mouse_encoder_free(_mouseEncoder);
	ghostty_key_event_free(_keyEvent);
	ghostty_key_encoder_free(_keyEncoder);
	ghostty_render_state_row_cells_free(_rowCells);
	ghostty_render_state_row_iterator_free(_rowIterator);
	ghostty_render_state_free(_renderState);
	ghostty_terminal_free(_terminal);
}

// ===========
// = Feeding =
// ===========

- (void)feedBytes:(void const*)bytes length:(size_t)length
{
	NSData* writeBack = nil;
	NSString* title = nil, *pwd = nil, *clipboard = nil;
	BOOL bell = NO;

	{
		std::lock_guard<std::mutex> lock(_terminalMutex);
		_pendingWriteBack.clear();
		_pendingClipboard.clear();
		_pendingTitleChanged = _pendingPwdChanged = _pendingBell = _pendingClipboardChanged = false;

		ghostty_terminal_vt_write(_terminal, (uint8_t const*)bytes, length);

		if(!_pendingWriteBack.empty())
			writeBack = [NSData dataWithBytes:_pendingWriteBack.data() length:_pendingWriteBack.size()];
		if(_pendingTitleChanged)
		{
			GhosttyString str;
			if(ghostty_terminal_get(_terminal, GHOSTTY_TERMINAL_DATA_TITLE, &str) == GHOSTTY_SUCCESS)
				title = [[NSString alloc] initWithBytes:str.ptr length:str.len encoding:NSUTF8StringEncoding];
		}
		if(_pendingPwdChanged)
		{
			GhosttyString str;
			if(ghostty_terminal_get(_terminal, GHOSTTY_TERMINAL_DATA_PWD, &str) == GHOSTTY_SUCCESS)
				pwd = [[NSString alloc] initWithBytes:str.ptr length:str.len encoding:NSUTF8StringEncoding];
		}
		if(_pendingClipboardChanged)
			clipboard = [[NSString alloc] initWithBytes:_pendingClipboard.data() length:_pendingClipboard.size() encoding:NSUTF8StringEncoding];
		bell = _pendingBell;
	}

	if(writeBack && _writeToPTYHandler)
		_writeToPTYHandler(writeBack);
	if(title && _titleChangedHandler)
		_titleChangedHandler(title);
	if(pwd && _pwdChangedHandler)
		_pwdChangedHandler(pwd);
	if(clipboard && _clipboardWriteHandler)
		_clipboardWriteHandler(clipboard);
	if(bell && _bellHandler)
		_bellHandler();
	if(_displayNeededHandler)
		_displayNeededHandler();
}

- (void)resizeToColumns:(NSUInteger)columns rows:(NSUInteger)rows cellWidth:(NSUInteger)cellWidth cellHeight:(NSUInteger)cellHeight
{
	std::lock_guard<std::mutex> lock(_terminalMutex);
	_gridColumns = std::max<NSUInteger>(columns, 2);
	_gridRows    = std::max<NSUInteger>(rows, 2);
	_cellWidth   = std::max<NSUInteger>(cellWidth, 1);
	_cellHeight  = std::max<NSUInteger>(cellHeight, 1);
	ghostty_terminal_resize(_terminal, _gridColumns, _gridRows, _cellWidth, _cellHeight);
	_cellBuffer.resize(_gridColumns);
}

- (void)setDefaultBackgroundColor:(GhosttyColorRgb)background foregroundColor:(GhosttyColorRgb)foreground cursorColor:(GhosttyColorRgb)cursor
{
	std::lock_guard<std::mutex> lock(_terminalMutex);
	ghostty_terminal_set(_terminal, GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, &background);
	ghostty_terminal_set(_terminal, GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, &foreground);
	ghostty_terminal_set(_terminal, GHOSTTY_TERMINAL_OPT_COLOR_CURSOR, &cursor);

	// ANSI 0-15 use Terminal.app’s vivid palette (libghostty’s stock 16 are
	// noticeably muted); the 216-color cube and grayscale ramp are then
	// regenerated to harmonize with the background/foreground.
	static GhosttyColorRgb const appleAnsiColors[16] = {
		{   0,   0,   0 }, { 194,  54,  33 }, {  37, 188,  36 }, { 173, 173,  39 },
		{  73,  46, 225 }, { 211,  56, 211 }, {  51, 187, 200 }, { 203, 204, 205 },
		{ 129, 131, 131 }, { 252,  57,  31 }, {  49, 231,  34 }, { 234, 236,  35 },
		{  88,  51, 255 }, { 249,  53, 248 }, {  20, 240, 240 }, { 233, 235, 235 },
	};
	GhosttyColorRgb palette[256];
	ghostty_color_palette_default(palette);
	std::copy(std::begin(appleAnsiColors), std::end(appleAnsiColors), palette);
	ghostty_color_palette_generate(palette, NULL, &background, &foreground, false, palette);
	ghostty_terminal_set(_terminal, GHOSTTY_TERMINAL_OPT_COLOR_PALETTE, palette);
}

- (void)reset
{
	std::lock_guard<std::mutex> lock(_terminalMutex);
	ghostty_terminal_reset(_terminal);
}

// ================================
// = Render state (main thread) =
// ================================

- (void)synchronizeRenderState
{
	{
		std::lock_guard<std::mutex> lock(_terminalMutex);
		ghostty_render_state_begin_update(_renderState, _terminal);
	}
	ghostty_render_state_end_update(_renderState);
}

- (NSUInteger)columns
{
	uint16_t res = 0;
	ghostty_render_state_get(_renderState, GHOSTTY_RENDER_STATE_DATA_COLS, &res);
	return res;
}

- (NSUInteger)rows
{
	uint16_t res = 0;
	ghostty_render_state_get(_renderState, GHOSTTY_RENDER_STATE_DATA_ROWS, &res);
	return res;
}

- (GhosttyRenderStateDirty)dirtyState
{
	GhosttyRenderStateDirty res = GHOSTTY_RENDER_STATE_DIRTY_FULL;
	ghostty_render_state_get(_renderState, GHOSTTY_RENDER_STATE_DATA_DIRTY, &res);
	return res;
}

- (void)clearDirtyState
{
	GhosttyRenderStateDirty value = GHOSTTY_RENDER_STATE_DIRTY_FALSE;
	ghostty_render_state_set(_renderState, GHOSTTY_RENDER_STATE_OPTION_DIRTY, &value);
}

- (struct terminal_cursor_t)cursor
{
	terminal_cursor_t res = { };
	bool flag = false;
	if(ghostty_render_state_get(_renderState, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_HAS_VALUE, &flag) == GHOSTTY_SUCCESS && flag)
	{
		res.hasPosition = true;
		ghostty_render_state_get(_renderState, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_X, &res.x);
		ghostty_render_state_get(_renderState, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_Y, &res.y);
		bool wideTail = false;
		ghostty_render_state_get(_renderState, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_WIDE_TAIL, &wideTail);
		res.wideTail = wideTail;
	}
	bool visible = false, blinking = false;
	ghostty_render_state_get(_renderState, GHOSTTY_RENDER_STATE_DATA_CURSOR_VISIBLE, &visible);
	ghostty_render_state_get(_renderState, GHOSTTY_RENDER_STATE_DATA_CURSOR_BLINKING, &blinking);
	res.visible  = visible;
	res.blinking = blinking;
	res.style = GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK;
	ghostty_render_state_get(_renderState, GHOSTTY_RENDER_STATE_DATA_CURSOR_VISUAL_STYLE, &res.style);
	return res;
}

- (struct terminal_colors_t)colors
{
	terminal_colors_t res = { };
	GhosttyRenderStateColors colors = GHOSTTY_INIT_SIZED(GhosttyRenderStateColors);
	if(ghostty_render_state_colors_get(_renderState, &colors) == GHOSTTY_SUCCESS)
	{
		res.background     = colors.background;
		res.foreground     = colors.foreground;
		res.cursor         = colors.cursor;
		res.hasCursorColor = colors.cursor_has_value;
	}
	return res;
}

- (void)enumerateRowsClearingDirty:(BOOL)clearDirty usingBlock:(void(^)(NSUInteger row, BOOL dirty, terminal_cell_t const* cells, NSUInteger cellCount))block
{
	if(ghostty_render_state_get(_renderState, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &_rowIterator) != GHOSTTY_SUCCESS)
		return;

	NSUInteger cols = [self columns];
	if(_cellBuffer.size() < cols)
		_cellBuffer.resize(cols);

	NSUInteger rowIndex = 0;
	while(ghostty_render_state_row_iterator_next(_rowIterator))
	{
		bool dirty = false;
		ghostty_render_state_row_get(_rowIterator, GHOSTTY_RENDER_STATE_ROW_DATA_DIRTY, &dirty);

		NSUInteger cellCount = 0;
		if(ghostty_render_state_row_get(_rowIterator, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &_rowCells) == GHOSTTY_SUCCESS)
		{
			while(ghostty_render_state_row_cells_next(_rowCells) && cellCount < cols)
			{
				terminal_cell_t& cell = _cellBuffer[cellCount++];
				cell = terminal_cell_t();

				GhosttyBuffer textBuffer = { .ptr = (uint8_t*)cell.text, .cap = sizeof(cell.text), .len = 0 };
				if(ghostty_render_state_row_cells_get(_rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_UTF8, &textBuffer) == GHOSTTY_SUCCESS)
					cell.textLen = textBuffer.len;

				cell.width = 1;
				GhosttyCell rawCell = 0;
				if(ghostty_render_state_row_cells_get(_rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW, &rawCell) == GHOSTTY_SUCCESS)
				{
					GhosttyCellWide wide = GHOSTTY_CELL_WIDE_NARROW;
					if(ghostty_cell_get(rawCell, GHOSTTY_CELL_DATA_WIDE, &wide) == GHOSTTY_SUCCESS)
					{
						switch(wide)
						{
							case GHOSTTY_CELL_WIDE_NARROW:      cell.width = 1; break;
							case GHOSTTY_CELL_WIDE_WIDE:        cell.width = 2; break;
							default:                            cell.width = 0; break;
						}
					}
				}

				bool hasStyling = false;
				ghostty_render_state_row_cells_get(_rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_HAS_STYLING, &hasStyling);
				if(hasStyling)
				{
					GhosttyStyle style = GHOSTTY_INIT_SIZED(GhosttyStyle);
					if(ghostty_render_state_row_cells_get(_rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &style) == GHOSTTY_SUCCESS)
					{
						cell.bold          = style.bold;
						cell.italic        = style.italic;
						cell.faint         = style.faint;
						cell.inverse       = style.inverse;
						cell.invisible     = style.invisible;
						cell.strikethrough = style.strikethrough;
						cell.underline     = style.underline;
					}
				}

				cell.hasForeground = ghostty_render_state_row_cells_get(_rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR, &cell.foreground) == GHOSTTY_SUCCESS;
				cell.hasBackground = ghostty_render_state_row_cells_get(_rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, &cell.background) == GHOSTTY_SUCCESS;

				bool selected = false;
				ghostty_render_state_row_cells_get(_rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_SELECTED, &selected);
				cell.selected = selected;
			}
		}

		block(rowIndex, dirty, _cellBuffer.data(), cellCount);

		if(clearDirty && dirty)
		{
			bool value = false;
			ghostty_render_state_row_set(_rowIterator, GHOSTTY_RENDER_STATE_ROW_OPTION_DIRTY, &value);
		}

		++rowIndex;
	}

	if(clearDirty)
		[self clearDirtyState];
}

// =========================
// = Viewport / scrollback =
// =========================

- (void)scrollViewportBy:(NSInteger)rowDelta
{
	std::lock_guard<std::mutex> lock(_terminalMutex);
	GhosttyTerminalScrollViewport behavior = { .tag = GHOSTTY_SCROLL_VIEWPORT_DELTA };
	behavior.value.delta = rowDelta;
	ghostty_terminal_scroll_viewport(_terminal, behavior);
}

- (void)scrollViewportToBottom
{
	std::lock_guard<std::mutex> lock(_terminalMutex);
	GhosttyTerminalScrollViewport behavior = { .tag = GHOSTTY_SCROLL_VIEWPORT_BOTTOM };
	ghostty_terminal_scroll_viewport(_terminal, behavior);
}

- (struct terminal_scrollbar_t)scrollbar
{
	std::lock_guard<std::mutex> lock(_terminalMutex);
	GhosttyTerminalScrollbar info = { };
	ghostty_terminal_get(_terminal, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &info);
	return (terminal_scrollbar_t){ info.total, info.offset, info.len };
}

- (BOOL)viewportIsAtBottom
{
	std::lock_guard<std::mutex> lock(_terminalMutex);
	bool res = true;
	ghostty_terminal_get(_terminal, GHOSTTY_TERMINAL_DATA_VIEWPORT_ACTIVE, &res);
	return res;
}

// =========
// = Input =
// =========

- (NSData*)encodeKey:(GhosttyKey)key action:(GhosttyKeyAction)action mods:(GhosttyMods)mods consumedMods:(GhosttyMods)consumedMods text:(NSString*)text unshiftedCodepoint:(uint32_t)codepoint
{
	std::lock_guard<std::mutex> lock(_terminalMutex);
	ghostty_key_encoder_setopt_from_terminal(_keyEncoder, _terminal);

	std::string utf8 = text ? std::string([text UTF8String] ?: "") : std::string();
	ghostty_key_event_set_action(_keyEvent, action);
	ghostty_key_event_set_key(_keyEvent, key);
	ghostty_key_event_set_mods(_keyEvent, mods);
	ghostty_key_event_set_consumed_mods(_keyEvent, consumedMods);
	ghostty_key_event_set_composing(_keyEvent, false);
	ghostty_key_event_set_unshifted_codepoint(_keyEvent, codepoint);
	ghostty_key_event_set_utf8(_keyEvent, utf8.empty() ? NULL : utf8.data(), utf8.size());

	char stackBuffer[128];
	size_t written = 0;
	GhosttyResult result = ghostty_key_encoder_encode(_keyEncoder, _keyEvent, stackBuffer, sizeof(stackBuffer), &written);
	if(result == GHOSTTY_SUCCESS)
		return written ? [NSData dataWithBytes:stackBuffer length:written] : nil;
	if(result == GHOSTTY_OUT_OF_SPACE)
	{
		std::vector<char> heapBuffer(written);
		if(ghostty_key_encoder_encode(_keyEncoder, _keyEvent, heapBuffer.data(), heapBuffer.size(), &written) == GHOSTTY_SUCCESS && written)
			return [NSData dataWithBytes:heapBuffer.data() length:written];
	}
	return nil;
}

- (NSData*)encodePaste:(NSString*)string
{
	NSUInteger inputLength = [string lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
	if(inputLength == 0)
		return nil;

	bool bracketed = false;
	{
		std::lock_guard<std::mutex> lock(_terminalMutex);
		ghostty_terminal_mode_get(_terminal, GHOSTTY_MODE_BRACKETED_PASTE, &bracketed);
	}

	std::vector<char> input(inputLength);
	[string getBytes:input.data() maxLength:input.size() usedLength:NULL encoding:NSUTF8StringEncoding options:0 range:NSMakeRange(0, string.length) remainingRange:NULL];

	size_t required = 0;
	ghostty_paste_encode(input.data(), input.size(), bracketed, NULL, 0, &required);
	std::vector<char> output(required);
	size_t written = 0;
	if(ghostty_paste_encode(input.data(), input.size(), bracketed, output.data(), output.size(), &written) != GHOSTTY_SUCCESS)
		return nil;
	return written ? [NSData dataWithBytes:output.data() length:written] : nil;
}

- (NSData*)encodeFocus:(BOOL)gained
{
	bool focusEvents = false;
	{
		std::lock_guard<std::mutex> lock(_terminalMutex);
		ghostty_terminal_mode_get(_terminal, GHOSTTY_MODE_FOCUS_EVENT, &focusEvents);
	}
	if(!focusEvents)
		return nil;

	char buffer[16];
	size_t written = 0;
	if(ghostty_focus_encode(gained ? GHOSTTY_FOCUS_GAINED : GHOSTTY_FOCUS_LOST, buffer, sizeof(buffer), &written) != GHOSTTY_SUCCESS)
		return nil;
	return written ? [NSData dataWithBytes:buffer length:written] : nil;
}

- (BOOL)mouseTrackingActive
{
	std::lock_guard<std::mutex> lock(_terminalMutex);
	bool res = false;
	ghostty_terminal_get(_terminal, GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING, &res);
	return res;
}

- (BOOL)altScreenActive
{
	std::lock_guard<std::mutex> lock(_terminalMutex);
	GhosttyTerminalScreen screen = GHOSTTY_TERMINAL_SCREEN_PRIMARY;
	ghostty_terminal_get(_terminal, GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &screen);
	return screen == GHOSTTY_TERMINAL_SCREEN_ALTERNATE;
}

- (BOOL)altScrollModeActive
{
	std::lock_guard<std::mutex> lock(_terminalMutex);
	bool res = false;
	ghostty_terminal_mode_get(_terminal, GHOSTTY_MODE_ALT_SCROLL, &res);
	return res;
}

- (void)setMouseGeometryScreenWidth:(NSUInteger)screenWidth screenHeight:(NSUInteger)screenHeight cellWidth:(NSUInteger)cellWidth cellHeight:(NSUInteger)cellHeight padding:(NSUInteger)padding
{
	std::lock_guard<std::mutex> lock(_terminalMutex);
	_mouseGeometry = GHOSTTY_INIT_SIZED(GhosttyMouseEncoderSize);
	_mouseGeometry.screen_width   = (uint32_t)screenWidth;
	_mouseGeometry.screen_height  = (uint32_t)screenHeight;
	_mouseGeometry.cell_width     = (uint32_t)std::max<NSUInteger>(cellWidth, 1);
	_mouseGeometry.cell_height    = (uint32_t)std::max<NSUInteger>(cellHeight, 1);
	_mouseGeometry.padding_top    = (uint32_t)padding;
	_mouseGeometry.padding_bottom = (uint32_t)padding;
	_mouseGeometry.padding_left   = (uint32_t)padding;
	_mouseGeometry.padding_right  = (uint32_t)padding;
}

- (NSData*)encodeMouseAction:(GhosttyMouseAction)action button:(GhosttyMouseButton)button hasButton:(BOOL)hasButton mods:(GhosttyMods)mods position:(NSPoint)position anyButtonPressed:(BOOL)anyButtonPressed
{
	std::lock_guard<std::mutex> lock(_terminalMutex);
	ghostty_mouse_encoder_setopt_from_terminal(_mouseEncoder, _terminal);
	ghostty_mouse_encoder_setopt(_mouseEncoder, GHOSTTY_MOUSE_ENCODER_OPT_SIZE, &_mouseGeometry);
	bool pressed = anyButtonPressed;
	ghostty_mouse_encoder_setopt(_mouseEncoder, GHOSTTY_MOUSE_ENCODER_OPT_ANY_BUTTON_PRESSED, &pressed);

	ghostty_mouse_event_set_action(_mouseEvent, action);
	if(hasButton)
			ghostty_mouse_event_set_button(_mouseEvent, button);
	else	ghostty_mouse_event_clear_button(_mouseEvent);
	ghostty_mouse_event_set_mods(_mouseEvent, mods);
	ghostty_mouse_event_set_position(_mouseEvent, (GhosttyMousePosition){ (float)position.x, (float)position.y });

	char buffer[64];
	size_t written = 0;
	if(ghostty_mouse_encoder_encode(_mouseEncoder, _mouseEvent, buffer, sizeof(buffer), &written) != GHOSTTY_SUCCESS)
		return nil;
	return written ? [NSData dataWithBytes:buffer length:written] : nil;
}

// =============
// = Selection =
// =============

// Caller must hold _terminalMutex.
- (BOOL)gridRefForColumn:(NSUInteger)column row:(NSUInteger)row outRef:(GhosttyGridRef*)outRef
{
	GhosttyPoint point = { .tag = GHOSTTY_POINT_TAG_VIEWPORT };
	point.value.coordinate = (GhosttyPointCoordinate){ (uint16_t)column, (uint32_t)row };
	*outRef = GHOSTTY_INIT_SIZED(GhosttyGridRef);
	return ghostty_terminal_grid_ref(_terminal, point, outRef) == GHOSTTY_SUCCESS;
}

- (BOOL)selectionBeginAtColumn:(NSUInteger)column row:(NSUInteger)row position:(NSPoint)position timestamp:(NSTimeInterval)timestamp clickCount:(NSUInteger)clickCount
{
	std::lock_guard<std::mutex> lock(_terminalMutex);

	GhosttyGridRef ref;
	if(![self gridRefForColumn:column row:row outRef:&ref])
	{
		ghostty_terminal_set(_terminal, GHOSTTY_TERMINAL_OPT_SELECTION, NULL);
		return NO;
	}

	GhosttySurfacePosition surfacePosition = { position.x, position.y };
	uint64_t timeNS = (uint64_t)(timestamp * 1e9);
	uint64_t repeatIntervalNS = (uint64_t)([NSEvent doubleClickInterval] * 1e9);
	double repeatDistance = 4;

	ghostty_selection_gesture_event_set(_pressEvent, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REF, &ref);
	ghostty_selection_gesture_event_set(_pressEvent, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_POSITION, &surfacePosition);
	ghostty_selection_gesture_event_set(_pressEvent, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_TIME_NS, &timeNS);
	ghostty_selection_gesture_event_set(_pressEvent, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REPEAT_INTERVAL_NS, &repeatIntervalNS);
	ghostty_selection_gesture_event_set(_pressEvent, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REPEAT_DISTANCE, &repeatDistance);

	GhosttySelection selection = GHOSTTY_INIT_SIZED(GhosttySelection);
	GhosttyResult result = ghostty_selection_gesture_event(_gesture, _terminal, _pressEvent, &selection);
	if(result == GHOSTTY_SUCCESS)
	{
		ghostty_terminal_set(_terminal, GHOSTTY_TERMINAL_OPT_SELECTION, &selection);
		return YES;
	}
	ghostty_terminal_set(_terminal, GHOSTTY_TERMINAL_OPT_SELECTION, NULL);
	return NO;
}

- (BOOL)selectionDragToColumn:(NSUInteger)column row:(NSUInteger)row position:(NSPoint)position geometry:(GhosttySelectionGestureGeometry)geometry
{
	std::lock_guard<std::mutex> lock(_terminalMutex);

	GhosttyGridRef ref;
	if(![self gridRefForColumn:column row:row outRef:&ref])
		return NO;

	GhosttySurfacePosition surfacePosition = { position.x, position.y };
	ghostty_selection_gesture_event_set(_dragEvent, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REF, &ref);
	ghostty_selection_gesture_event_set(_dragEvent, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_POSITION, &surfacePosition);
	ghostty_selection_gesture_event_set(_dragEvent, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_GEOMETRY, &geometry);

	GhosttySelection selection = GHOSTTY_INIT_SIZED(GhosttySelection);
	if(ghostty_selection_gesture_event(_gesture, _terminal, _dragEvent, &selection) == GHOSTTY_SUCCESS)
	{
		ghostty_terminal_set(_terminal, GHOSTTY_TERMINAL_OPT_SELECTION, &selection);
		return YES;
	}
	return NO;
}

- (void)selectionEndAtColumn:(NSUInteger)column row:(NSUInteger)row
{
	std::lock_guard<std::mutex> lock(_terminalMutex);
	GhosttyGridRef ref;
	if([self gridRefForColumn:column row:row outRef:&ref])
			ghostty_selection_gesture_event_set(_releaseEvent, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REF, &ref);
	else	ghostty_selection_gesture_event_set(_releaseEvent, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REF, NULL);
	ghostty_selection_gesture_event(_gesture, _terminal, _releaseEvent, NULL);
}

- (void)selectAll
{
	std::lock_guard<std::mutex> lock(_terminalMutex);
	GhosttySelection selection = GHOSTTY_INIT_SIZED(GhosttySelection);
	if(ghostty_terminal_select_all(_terminal, &selection) == GHOSTTY_SUCCESS)
		ghostty_terminal_set(_terminal, GHOSTTY_TERMINAL_OPT_SELECTION, &selection);
}

- (void)clearSelection
{
	std::lock_guard<std::mutex> lock(_terminalMutex);
	ghostty_terminal_set(_terminal, GHOSTTY_TERMINAL_OPT_SELECTION, NULL);
	ghostty_selection_gesture_reset(_gesture, _terminal);
}

- (BOOL)hasSelection
{
	std::lock_guard<std::mutex> lock(_terminalMutex);
	GhosttySelection selection = GHOSTTY_INIT_SIZED(GhosttySelection);
	return ghostty_terminal_get(_terminal, GHOSTTY_TERMINAL_DATA_SELECTION, &selection) == GHOSTTY_SUCCESS;
}

// ================
// = Logical line =
// ================

static void append_codepoint (std::string& str, uint32_t cp)
{
	if(cp == 0)
	{
		str += ' ';
	}
	else if(cp < 0x80)
	{
		str += (char)cp;
	}
	else if(cp < 0x800)
	{
		str += (char)(0xC0 | (cp >> 6));
		str += (char)(0x80 | (cp & 0x3F));
	}
	else if(cp < 0x10000)
	{
		str += (char)(0xE0 | (cp >> 12));
		str += (char)(0x80 | ((cp >> 6) & 0x3F));
		str += (char)(0x80 | (cp & 0x3F));
	}
	else
	{
		str += (char)(0xF0 | (cp >> 18));
		str += (char)(0x80 | ((cp >> 12) & 0x3F));
		str += (char)(0x80 | ((cp >> 6) & 0x3F));
		str += (char)(0x80 | (cp & 0x3F));
	}
}

- (BOOL)logicalLineAtColumn:(NSUInteger)column row:(NSUInteger)row text:(std::string*)outText hoverOffset:(size_t*)outHoverOffset cells:(std::vector<terminal_link_cell_t>*)outCells
{
	std::lock_guard<std::mutex> lock(_terminalMutex);

	GhosttyGridRef hoverRef;
	if(![self gridRefForColumn:column row:row outRef:&hoverRef])
		return NO;

	GhosttyPointCoordinate screenCoord;
	if(ghostty_terminal_point_from_grid_ref(_terminal, &hoverRef, GHOSTTY_POINT_TAG_SCREEN, &screenCoord) != GHOSTTY_SUCCESS)
		return NO;
	uint32_t const hoverScreenY = screenCoord.y;

	GhosttyTerminal terminal = _terminal;
	auto refForScreenRow = [&terminal](uint32_t y, GhosttyGridRef* outRef) -> bool {
		GhosttyPoint point = { .tag = GHOSTTY_POINT_TAG_SCREEN };
		point.value.coordinate = (GhosttyPointCoordinate){ 0, y };
		*outRef = GHOSTTY_INIT_SIZED(GhosttyGridRef);
		return ghostty_terminal_grid_ref(terminal, point, outRef) == GHOSTTY_SUCCESS;
	};

	// Sanity bound for pathological wrapped lines (e.g. minified output).
	// Residual risk of truncating at the cap: a token cut mid-path could
	// match a *different* existing file — the on-disk existence check in the
	// grid view is the only barrier against opening it. At 100 rows × typical
	// widths that is thousands of columns, so accepted for v1.
	NSUInteger const kMaxLogicalRows = 100;

	// Walk up while the row is a wrap continuation to find the line’s first row
	uint32_t startY = hoverScreenY;
	for(NSUInteger guard = 0; guard < kMaxLogicalRows && startY > 0; ++guard)
	{
		GhosttyGridRef ref;
		GhosttyRow rowHandle = 0;
		bool continuation = false;
		if(!refForScreenRow(startY, &ref) || ghostty_grid_ref_row(&ref, &rowHandle) != GHOSTTY_SUCCESS)
			break;
		ghostty_row_get(rowHandle, GHOSTTY_ROW_DATA_WRAP_CONTINUATION, &continuation);
		if(!continuation)
			break;
		--startY;
	}

	// Collect rows downward while each row soft-wraps onto the next
	std::string text;
	std::vector<terminal_link_cell_t> cells;
	size_t hoverOffset = std::string::npos;
	NSUInteger const cols = _gridColumns;

	uint32_t y = startY;
	for(NSUInteger guard = 0; guard < kMaxLogicalRows; ++guard, ++y)
	{
		GhosttyGridRef rowRef;
		if(!refForScreenRow(y, &rowRef))
			break;

		GhosttyRow rowHandle = 0;
		bool wrapped = false;
		if(ghostty_grid_ref_row(&rowRef, &rowHandle) == GHOSTTY_SUCCESS)
			ghostty_row_get(rowHandle, GHOSTTY_ROW_DATA_WRAP, &wrapped);

		NSInteger const viewportRow = (NSInteger)row + ((NSInteger)y - (NSInteger)hoverScreenY);

		size_t prevBegin = text.size(), prevEnd = text.size();
		for(NSUInteger x = 0; x < cols; ++x)
		{
			GhosttyGridRef cellRef = rowRef; // same row node, vary the column
			cellRef.x = (uint16_t)x;

			GhosttyCell cellValue = 0;
			GhosttyCellWide wide = GHOSTTY_CELL_WIDE_NARROW;
			if(ghostty_grid_ref_cell(&cellRef, &cellValue) == GHOSTTY_SUCCESS)
				ghostty_cell_get(cellValue, GHOSTTY_CELL_DATA_WIDE, &wide);

			size_t begin = text.size(), end;
			if(wide == GHOSTTY_CELL_WIDE_SPACER_TAIL)
			{
				begin = prevBegin; // covered by the wide character before it
				end   = prevEnd;
			}
			else if(wide == GHOSTTY_CELL_WIDE_SPACER_HEAD)
			{
				end = begin; // zero-width filler before a soft-wrapped wide character
			}
			else
			{
				uint32_t buffer[16];
				size_t len = 0;
				if(ghostty_grid_ref_graphemes(&cellRef, buffer, sizeof(buffer)/sizeof(buffer[0]), &len) == GHOSTTY_SUCCESS && len > 0)
				{
					for(size_t i = 0; i < len; ++i)
						append_codepoint(text, buffer[i]);
				}
				else
				{
					text += ' '; // empty cell (or oversized cluster) keeps column alignment
				}
				end = text.size();
				prevBegin = begin;
				prevEnd   = end;
			}

			if(y == hoverScreenY && x == column)
				hoverOffset = begin;

			cells.push_back({ viewportRow, x, begin, end });
		}

		if(!wrapped)
			break;
	}

	while(!text.empty() && text.back() == ' ')
		text.pop_back();

	if(hoverOffset == std::string::npos || hoverOffset >= text.size())
		return NO;

	*outText        = std::move(text);
	*outHoverOffset = hoverOffset;
	*outCells       = std::move(cells);
	return YES;
}

- (NSString*)selectedString
{
	std::lock_guard<std::mutex> lock(_terminalMutex);

	GhosttyTerminalSelectionFormatOptions options = GHOSTTY_INIT_SIZED(GhosttyTerminalSelectionFormatOptions);
	options.emit   = GHOSTTY_FORMATTER_FORMAT_PLAIN;
	options.unwrap = true;
	options.trim   = true;

	uint8_t* buffer = NULL;
	size_t length = 0;
	if(ghostty_terminal_selection_format_alloc(_terminal, NULL, options, &buffer, &length) != GHOSTTY_SUCCESS)
		return nil;

	NSString* res = [[NSString alloc] initWithBytes:buffer length:length encoding:NSUTF8StringEncoding];
	ghostty_free(NULL, buffer, length);
	return res;
}
@end
