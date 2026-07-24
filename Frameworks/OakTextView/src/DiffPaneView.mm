#import "DiffPaneView.h"
#import "diff_pane_model.h"
#import "OTVHUD.h"
#import <OakAppKit/NSAlert Additions.h>
#import <document/OakDocument.h>
#import <text/utf16.h>
#import <parse/parse.h>
#import <parse/grammar.h>
#import <bundles/bundles.h>
#import <ns/ns.h>
#import <atomic>
#import <functional>

static CGFloat const kDiffPaneHeaderHeight = 24;
static CGFloat const kDiffPaneBannerHeight = 22;
static CGFloat const kHunkHeaderHeight     = 26;
static CGFloat const kGutterPadding        = 7;  // outer padding of the line-number columns
static CGFloat const kGutterColumnGap      = 7;  // between the base-side and buffer-side columns

// Beyond this the bodies render unhighlighted: a full parse of a
// multi-megabyte file on every recompute would cost more than the colour
// is worth.
static size_t const kMaxHighlightBytes = 1024*1024;

// All pane colors derive from the editor theme (pushed by OakDocumentView’s
// updateStyle, like the terminal pane and markdown preview): semantic system
// colors track the macOS appearance, NOT the theme — secondaryLabelColor on
// a dark editor theme under a light system appearance is dark-on-dark.
// “Dimmed” foregrounds are the theme foreground blended toward the theme
// background, so they keep contrast on any theme.
static NSColor* BlendedColor (NSColor* from, NSColor* toward, CGFloat fraction)
{
	NSColor* fromRGB   = [from colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
	NSColor* towardRGB = [toward colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
	if(!fromRGB)
	{
		// The FOREGROUND failed the sRGB conversion (pattern/catalog color):
		// fall back to something readable — never to `toward`, which is the
		// background here and would render the text invisible.
		return from ?: NSColor.textColor;
	}
	NSColor* blended = towardRGB ? [fromRGB blendedColorWithFraction:fraction ofColor:towardRGB] : nil;
	return blended ?: fromRGB;
}

// The document's buffer, byte for byte.
//
// This is deliberately NOT -content, which the diff service uses: that
// round-trips the buffer through an NSString, and a revert edits the
// buffer by byte offset. Where the two disagree — non-UTF-8 content is
// how they could — the hunks' offsets would not mean what the edit takes
// them to mean, and comparing against these bytes turns that into a
// refusal to revert instead of a corrupted file.
static std::string BufferBytes (OakDocument* document)
{
	__block std::string res;
	[document enumerateByteRangesUsingBlock:^(char const* bytes, NSRange byteRange, BOOL* stop){
		if(res.size() < NSMaxRange(byteRange))
			res.resize(NSMaxRange(byteRange));
		std::copy(bytes, bytes + byteRange.length, res.begin() + byteRange.location);
	}];
	return res;
}

static NSString* ShortSHA (NSString* sha)
{
	return sha.length > 10 ? [sha substringToIndex:10] : sha;
}

// Scope runs for `text`, parsed from the very start so multi-line
// constructs are scoped correctly, but abandoned once past `maxLine` —
// a hunk list rarely reaches the end of a big file, and parsing what
// nothing displays is pure cost. Byte offset → scope.
static std::map<size_t, scope::scope_t> ScopesUpToLine (std::string const& text, parse::grammar_ptr const& grammar, size_t maxLine)
{
	std::map<size_t, scope::scope_t> scopes;
	if(!grammar || text.empty() || maxLine == 0)
		return scopes;

	parse::stack_ptr parserState = grammar->seed();
	size_t line = 1;
	for(size_t i = 0; i < text.size() && line <= maxLine; ++line)
	{
		size_t eol = text.find('\n', i);
		eol = eol != std::string::npos ? eol + 1 : text.size();

		std::string const lineText = text.substr(i, eol - i);
		std::map<size_t, scope::scope_t> lineScopes;
		parserState = parse::parse(lineText.data(), lineText.data() + lineText.size(), parserState, lineScopes, i == 0);
		for(auto const& pair : lineScopes)
			scopes[i + pair.first] = pair.second;

		i = eol;
	}
	return scopes;
}

// What a rendered row needs beyond its text: which side it belongs to and
// the two line numbers, so the gutter can be drawn rather than baked into
// the text (keeping copied text free of line numbers and markers).
struct diff_row_t
{
	diff_pane::row_kind kind = diff_pane::row_kind::context;
	size_t base_line = 0, buffer_line = 0;
	size_t jump_line = 0; // where activating this row takes the editor
};

// Fonts, colors and metrics shared by every hunk view. Built on the main
// thread from the editor theme; the row geometry lives here too so the
// drawn gutter and the text view cannot drift apart.
@interface DiffPaneStyle : NSObject
@property (nonatomic) NSFont* codeFont;
@property (nonatomic) NSFont* lineNumberFont;
@property (nonatomic) NSColor* background;
@property (nonatomic) NSColor* foreground;
@property (nonatomic) NSColor* gutterBackground;
@property (nonatomic) NSColor* gutterForeground;
@property (nonatomic) NSColor* gutterDivider;
@property (nonatomic) NSColor* addedTint;
@property (nonatomic) NSColor* deletedTint;
@property (nonatomic) NSColor* headerBackground;
@property (nonatomic) NSColor* activeHeaderBackground;
@property (nonatomic) NSColor* headerForeground;
@property (nonatomic) NSColor* addedMarkerColor;
@property (nonatomic) NSColor* deletedMarkerColor;
@property (nonatomic) CGFloat rowHeight;
@property (nonatomic) CGFloat gutterWidth;  // line numbers AND the change marker
@property (nonatomic) CGFloat markerWidth;
@property (nonatomic) NSInteger digits;   // widest line number, in characters
@property (nonatomic) CGFloat columnWidth; // one line-number column
@end

@implementation DiffPaneStyle
@end

// Methods the hunk subviews call back into.
@interface DiffPaneView (HunkCallbacks)
- (void)jumpToBufferLine:(NSUInteger)line;
- (void)revertHunkAtIndex:(NSUInteger)index;
- (void)appendStyledSlice:(NSMutableAttributedString*)output text:(std::string const&)text from:(size_t)from to:(size_t)to scopes:(std::map<size_t, scope::scope_t> const*)scopes theme:(theme_ptr const&)theme baseAttributes:(NSDictionary*)baseAttributes;
- (std::shared_ptr<std::map<size_t, scope::scope_t>>)baseScopesFor:(std::string const&)text grammar:(parse::grammar_ptr const&)grammar upToLine:(size_t)maxLine key:(std::string const&)key;
@end

// One rendered hunk, built off the main thread and handed to the view.
@interface DiffHunkContent : NSObject
@property (nonatomic) NSString* headerText;
@property (nonatomic) NSAttributedString* body; // code only — no numbers, no markers
@property (nonatomic) NSUInteger anchorLine;
@property (nonatomic) NSUInteger signature;     // content hash; equal ⇒ the view can be reused as-is
- (std::vector<diff_row_t> const&)rows;
- (void)setRows:(std::vector<diff_row_t>)someRows;
@end

@implementation DiffHunkContent
{
	std::vector<diff_row_t> _rows;
}
- (std::vector<diff_row_t> const&)rows       { return _rows; }
- (void)setRows:(std::vector<diff_row_t>)someRows { _rows = std::move(someRows); }
@end

// A hunk body: non-editable but selectable, so a reviewer can copy code
// out of it. Double-clicking a line takes the editor there.
@interface DiffHunkTextView : NSTextView
@property (nonatomic, weak) DiffPaneView* pane;
- (void)setRowJumpLines:(std::vector<NSUInteger>)someLines;
@end

@implementation DiffHunkTextView
{
	std::vector<NSUInteger> _rowJumpLines;
}

- (void)setRowJumpLines:(std::vector<NSUInteger>)someLines { _rowJumpLines = std::move(someLines); }

- (void)mouseDown:(NSEvent*)anEvent
{
	if(anEvent.clickCount == 2)
	{
		NSPoint const point = [self convertPoint:anEvent.locationInWindow fromView:nil];
		NSUInteger const index = [self characterIndexForInsertionAtPoint:point];

		NSString* string = self.textStorage.string;
		NSUInteger row = 0;
		for(NSUInteger i = 0; i < index && i < string.length; ++i)
		{
			if([string characterAtIndex:i] == '\n')
				++row;
		}

		if(row < _rowJumpLines.size() && _rowJumpLines[row] != 0)
			return [self.pane jumpToBufferLine:_rowJumpLines[row]];
	}
	[super mouseDown:anEvent];
}
@end

// One hunk: a header band over the diff body. The body's line-number
// columns, change markers and row tints are drawn here rather than being
// part of the text, so the numbers line up with the editor's own gutter
// and a copied selection contains just the code.
@interface DiffHunkView : NSView
@property (nonatomic, weak) DiffPaneView* pane;
@property (nonatomic) NSUInteger anchorLine;
@property (nonatomic) NSUInteger hunkIndex;
@property (nonatomic) NSUInteger signature;
@property (nonatomic) BOOL activeHunk;
@property (nonatomic) DiffPaneStyle* style;

// Where right-aligned header controls sit. The view is as wide as the
// widest line in the list, which can be far wider than the pane, so the
// Revert control follows the viewport instead of the view's own edge —
// otherwise it would sit off-screen until the reader scrolled sideways.
@property (nonatomic) CGFloat headerContentWidth;

- (void)setRevertTitle:(NSString*)aTitle enabled:(BOOL)flag toolTip:(NSString*)aToolTip;
@end

@implementation DiffHunkView
{
	NSTextField*       _headerField;
	NSButton*          _revertButton;
	DiffHunkTextView*  _bodyView;
	std::vector<diff_row_t> _rows;
	NSString*          _revertTitle;
}

- (BOOL)isFlipped { return YES; }

- (id)initWithFrame:(NSRect)aRect
{
	if(self = [super initWithFrame:aRect])
	{
		_headerField = [[NSTextField alloc] initWithFrame:NSZeroRect];
		_headerField.bordered        = NO;
		_headerField.editable        = NO;
		_headerField.selectable      = NO;
		_headerField.bezeled         = NO;
		_headerField.drawsBackground = NO;
		_headerField.font            = [NSFont systemFontOfSize:[NSFont systemFontSizeForControlSize:NSControlSizeSmall]];
		[[_headerField cell] setLineBreakMode:NSLineBreakByTruncatingTail];

		// Explicit TextKit 1 stack: a plain -initWithFrame: text view is
		// TextKit 2, whose viewport-based layout makes the used rect
		// under-report long lines, so the hunk would be sized short.
		NSTextStorage* textStorage     = [NSTextStorage new];
		NSLayoutManager* layoutManager = [NSLayoutManager new];
		[textStorage addLayoutManager:layoutManager];
		NSTextContainer* textContainer = [[NSTextContainer alloc] initWithContainerSize:NSMakeSize(FLT_MAX, FLT_MAX)];
		textContainer.widthTracksTextView = NO;
		textContainer.lineFragmentPadding = 0;
		[layoutManager addTextContainer:textContainer];

		_bodyView = [[DiffHunkTextView alloc] initWithFrame:NSZeroRect textContainer:textContainer];
		_bodyView.editable        = NO;
		_bodyView.richText        = NO;
		_bodyView.usesFontPanel   = NO;
		_bodyView.drawsBackground = NO; // the row tints are drawn behind it
		_bodyView.horizontallyResizable = YES;
		_bodyView.verticallyResizable   = YES;
		_bodyView.maxSize = NSMakeSize(FLT_MAX, FLT_MAX);
		_bodyView.textContainerInset = NSZeroSize; // row N starts exactly at N × rowHeight
		_bodyView.autoresizingMask = NSViewNotSizable;

		// Borderless and titled: a bezeled control renders for the system
		// appearance rather than the editor theme, and one on every hunk
		// band would weigh the list down. The title is attributed so it
		// takes the theme's own header colour.
		_revertButton = [NSButton buttonWithTitle:@"Revert" target:self action:@selector(didClickRevert:)];
		_revertButton.bordered  = NO;
		_revertButton.hidden    = YES; // until a snapshot says whether reverting is possible
		_revertButton.focusRingType = NSFocusRingTypeNone;

		[self addSubview:_headerField];
		[self addSubview:_revertButton];
		[self addSubview:_bodyView];
	}
	return self;
}

- (void)setRevertTitle:(NSString*)aTitle enabled:(BOOL)flag toolTip:(NSString*)aToolTip
{
	_revertTitle          = aTitle;
	_revertButton.hidden  = aTitle == nil;
	_revertButton.enabled = flag;
	_revertButton.toolTip = aToolTip;
	[self updateRevertTitle];
	self.needsLayout = YES;
}

- (void)updateRevertTitle
{
	if(!_revertTitle)
		return;

	NSColor* color = _style.headerForeground ?: NSColor.controlTextColor;
	if(!_revertButton.enabled)
		color = [color colorWithAlphaComponent:0.5];

	_revertButton.attributedTitle = [[NSAttributedString alloc] initWithString:_revertTitle attributes:@{
		NSFontAttributeName:            [NSFont systemFontOfSize:[NSFont systemFontSizeForControlSize:NSControlSizeSmall]],
		NSForegroundColorAttributeName: color,
	}];
}

- (void)didClickRevert:(id)sender
{
	[self.pane revertHunkAtIndex:_hunkIndex];
}

- (void)setPane:(DiffPaneView*)aPane
{
	_pane = aPane;
	_bodyView.pane = aPane;
}

- (void)setActiveHunk:(BOOL)flag
{
	if(_activeHunk == flag)
		return;
	_activeHunk = flag;
	self.needsDisplay = YES; // an attribute flip — never a rebuild
}

- (void)takeContent:(DiffHunkContent*)content
{
	_headerField.stringValue = content.headerText ?: @"";
	[_bodyView.textStorage setAttributedString:content.body ?: [NSAttributedString new]];
	_rows = content.rows;

	std::vector<NSUInteger> jumpLines;
	jumpLines.reserve(_rows.size());
	for(auto const& row : _rows)
		jumpLines.push_back((NSUInteger)row.jump_line);
	[_bodyView setRowJumpLines:std::move(jumpLines)];

	self.anchorLine = content.anchorLine;
	self.signature  = content.signature;
	self.needsDisplay = YES;
}

- (void)setStyle:(DiffPaneStyle*)aStyle
{
	_style = aStyle;
	_headerField.textColor = aStyle.headerForeground;
	[_headerField sizeToFit];
	[self updateRevertTitle];
	self.needsDisplay = YES;
	self.needsLayout  = YES;
}

- (CGFloat)heightForRows
{
	return kHunkHeaderHeight + _rows.size() * _style.rowHeight;
}

- (CGFloat)widthOfWidestLine
{
	NSLayoutManager* layoutManager = _bodyView.layoutManager;
	NSTextContainer* textContainer = _bodyView.textContainer;
	[layoutManager ensureLayoutForTextContainer:textContainer];
	return NSWidth([layoutManager usedRectForTextContainer:textContainer]);
}

// The code starts just inside the tinted column, so a changed row has a
// little coloured margin before its first glyph.
- (CGFloat)bodyLeftInset
{
	return _style.gutterWidth + 4;
}

- (void)layout
{
	[super layout];
	NSRect const bounds = self.bounds;

	CGFloat const headerRight = std::min(NSWidth(bounds), _headerContentWidth > 0 ? _headerContentWidth : NSWidth(bounds));

	CGFloat labelRight = headerRight - 8;
	if(!_revertButton.hidden)
	{
		[_revertButton sizeToFit];
		NSSize const size = _revertButton.frame.size;
		_revertButton.frame = NSMakeRect(headerRight - 8 - size.width, round((kHunkHeaderHeight - size.height) / 2), size.width, size.height);
		labelRight = NSMinX(_revertButton.frame) - 6;
	}

	_headerField.frame = NSMakeRect(NSMinX(bounds) + 8, round((kHunkHeaderHeight - NSHeight(_headerField.frame)) / 2), std::max<CGFloat>(0, labelRight - NSMinX(bounds) - 8), NSHeight(_headerField.frame));
	_bodyView.frame = NSMakeRect([self bodyLeftInset], kHunkHeaderHeight, std::max<CGFloat>(0, NSWidth(bounds) - [self bodyLeftInset]), _rows.size() * _style.rowHeight);
}

- (void)drawRect:(NSRect)aRect
{
	DiffPaneStyle* style = _style;
	if(!style)
		return;

	NSRect const bounds = self.bounds;

	// Header band, full width, with a hairline above it separating this
	// hunk from the previous one.
	NSRect const headerRect = NSMakeRect(NSMinX(bounds), 0, NSWidth(bounds), kHunkHeaderHeight);
	[(_activeHunk ? style.activeHeaderBackground : style.headerBackground) set];
	NSRectFill(headerRect);
	[style.gutterDivider set];
	NSRectFill(NSMakeRect(NSMinX(bounds), 0, NSWidth(bounds), 1));
	NSRectFill(NSMakeRect(NSMinX(bounds), kHunkHeaderHeight - 1, NSWidth(bounds), 1));

	// Line-number columns sit on the gutter background, matching the
	// editor's own gutter; the code area beside them carries the tint.
	CGFloat const bodyTop = kHunkHeaderHeight;
	NSRect const gutterRect = NSMakeRect(NSMinX(bounds), bodyTop, style.gutterWidth, _rows.size() * style.rowHeight);
	[style.gutterBackground set];
	NSRectFill(gutterRect);

	NSDictionary* numberAttributes = @{ NSFontAttributeName: style.lineNumberFont, NSForegroundColorAttributeName: style.gutterForeground };

	for(size_t i = 0; i < _rows.size(); ++i)
	{
		auto const& row = _rows[i];
		CGFloat const rowTop = bodyTop + i * style.rowHeight;

		bool const isDeleted = row.kind == diff_pane::row_kind::deleted;
		bool const isAdded   = row.kind == diff_pane::row_kind::added;

		// The tint covers the code column only — the gutter keeps its own
		// background, exactly as it does beside the buffer.
		if(NSColor* tint = isDeleted ? style.deletedTint : (isAdded ? style.addedTint : nil))
		{
			[tint set];
			NSRectFill(NSMakeRect(style.gutterWidth, rowTop, NSWidth(bounds) - style.gutterWidth, style.rowHeight));
		}

		// A deleted line has no buffer-side number, an added line no
		// base-side one — the asymmetry is what makes the two columns
		// readable at a glance.
		auto drawNumber = [&](size_t number, CGFloat columnRight){
			if(number == 0)
				return;
			NSString* text = [NSString stringWithFormat:@"%zu", number];
			NSSize const size = [text sizeWithAttributes:numberAttributes];
			[text drawAtPoint:NSMakePoint(columnRight - size.width, rowTop + round((style.rowHeight - size.height) / 2)) withAttributes:numberAttributes];
		};

		CGFloat const baseColumnRight   = kGutterPadding + style.columnWidth;
		CGFloat const bufferColumnRight = baseColumnRight + kGutterColumnGap + style.columnWidth;
		drawNumber(row.base_line, baseColumnRight);
		drawNumber(row.buffer_line, bufferColumnRight);

		if(isDeleted || isAdded)
		{
			NSDictionary* markerAttributes = @{ NSFontAttributeName: style.codeFont, NSForegroundColorAttributeName: isDeleted ? style.deletedMarkerColor : style.addedMarkerColor };
			NSString* marker = isDeleted ? @"-" : @"+";
			NSSize const size = [marker sizeWithAttributes:markerAttributes];
			[marker drawAtPoint:NSMakePoint(style.gutterWidth - style.markerWidth + round((style.markerWidth - size.width) / 2), rowTop + round((style.rowHeight - size.height) / 2)) withAttributes:markerAttributes];
		}
	}

	// Divider between the numbers and the code, like the editor's gutter.
	[style.gutterDivider set];
	NSRectFill(NSMakeRect(style.gutterWidth - 1, bodyTop, 1, _rows.size() * style.rowHeight));
}

// The header band is the hunk's navigation control, so the whole strip has
// to be clickable — the label sitting on it would otherwise swallow the hit.
- (NSView*)hitTest:(NSPoint)aPoint
{
	NSPoint const local = [self convertPoint:aPoint fromView:self.superview];
	if(NSPointInRect(local, self.bounds) && local.y <= kHunkHeaderHeight)
	{
		// …except over the Revert control, which the band would otherwise
		// swallow along with everything else on it.
		if(!_revertButton.hidden && _revertButton.enabled && NSPointInRect(local, _revertButton.frame))
			return _revertButton;
		return self;
	}
	return [super hitTest:aPoint];
}

- (void)mouseDown:(NSEvent*)anEvent
{
	NSPoint const point = [self convertPoint:anEvent.locationInWindow fromView:nil];
	if(point.y <= kHunkHeaderHeight && _anchorLine)
		return [self.pane jumpToBufferLine:_anchorLine];
	[super mouseDown:anEvent];
}
@end

// The list's document view — flipped, so hunks stack downward from the top.
@interface DiffPaneListView : NSView
@end

@implementation DiffPaneListView
- (BOOL)isFlipped { return YES; }
@end

@interface DiffPaneView () <NSMenuDelegate>
@end

@implementation DiffPaneView
{
	NSTextField*   _headerField;
	NSButton*      _closeButton;
	NSButton*      _previousHunkButton;
	NSButton*      _nextHunkButton;
	NSButton*      _revertAllButton;

	NSScrollView*     _listScrollView;
	DiffPaneListView* _listView;
	NSTextField*      _emptyStateField;
	NSMutableArray<DiffHunkView*>* _hunkViews;

	// Banner strip (HEAD-moved notices) under the header.
	NSTextField* _bannerField;
	NSButton*    _bannerActionButton;
	NSButton*    _bannerCloseButton;
	BOOL         _bannerVisible;
	void       (^_bannerHandler)(void);

	BufferDiffSnapshot* _snapshot;
	std::vector<diff_pane::card_t> _cards; // model, main-thread only
	size_t _activeHunkIndex;               // diff_pane::npos when the caret is in no hunk
	DiffPaneStyle* _paneStyle;             // fonts/colors/metrics the hunk views draw with

	// theme_t::styles_for_scope caches without locking, so the layout’s
	// instance must stay main-thread-only; renders use this pane-private
	// copy, captured on the main thread and only dereferenced on the
	// (serial) render queue.
	theme_ptr _renderTheme;

	parse::grammar_ptr _grammar; // resolved on the main thread, keyed by _grammarFileType
	NSString* _grammarFileType;

	// Base-side parse, cached across recomputes — render-queue-only.
	// Typing cannot change the base, so re-parsing it on every keystroke's
	// recompute is half the render's cost for nothing. Keyed by what the
	// scopes depend on, extent included: the parse stops at the last line
	// on display, so a cache built for a shorter reach cannot serve a
	// render that now shows a hunk further down.
	std::string _baseScopesKey;
	size_t _baseScopesMaxLine; // ivars are zero-initialised
	std::shared_ptr<std::map<size_t, scope::scope_t>> _baseScopes;

	std::atomic<NSUInteger> _generation; // atomic: render blocks read it off-main to skip superseded work
	dispatch_queue_t _renderQueue;
}

- (id)initWithFrame:(NSRect)aRect
{
	if(self = [super initWithFrame:aRect])
	{
		_renderQueue     = dispatch_queue_create("com.macromates.diff-pane.render", DISPATCH_QUEUE_SERIAL);
		_activeHunkIndex = diff_pane::npos;
		_hunkViews       = [NSMutableArray new];
	}
	return self;
}

// Like the gutter, minimap and markdown preview, the pane lives inside a
// scroller-less NSScrollView: a plain sibling that redraws next to
// OakTextView leaves the text view’s giant tiled backing layer blank. The
// wrapper never scrolls; we keep our frame matched to its clip view and put
// a real (scrolling) scroll view inside.
- (void)viewDidMoveToSuperview
{
	[super viewDidMoveToSuperview];

	[NSNotificationCenter.defaultCenter removeObserver:self name:NSViewFrameDidChangeNotification object:nil];

	NSClipView* clipView = (NSClipView*)self.superview;
	if([clipView isKindOfClass:[NSClipView class]])
	{
		clipView.postsFrameChangedNotifications = YES;
		[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(clipViewFrameDidChange:) name:NSViewFrameDidChangeNotification object:clipView];
	}
	[self matchClipViewSize];
}

- (void)clipViewFrameDidChange:(NSNotification*)aNotification
{
	[self matchClipViewSize];
}

- (void)matchClipViewSize
{
	NSClipView* clipView = (NSClipView*)self.superview;
	if([clipView isKindOfClass:[NSClipView class]] && !NSEqualSizes(self.frame.size, clipView.bounds.size))
		[self setFrameSize:clipView.bounds.size];
}

- (CGFloat)topStripHeight
{
	return kDiffPaneHeaderHeight + (_bannerVisible ? kDiffPaneBannerHeight : 0);
}

// The scroll view covers everything below the header/banner strip, but the
// strip itself is bare view: without this the window background shows
// through — under a light system appearance with a dark editor theme that
// meant a white strip with appearance-pinned (dark) controls on it. Paint
// the theme background and a hairline separator instead.
- (void)drawRect:(NSRect)aRect
{
	NSColor* background = _themeBackgroundColor ?: NSColor.textBackgroundColor;
	NSColor* foreground = _themeForegroundColor ?: NSColor.textColor;

	[background set];
	NSRectFill(aRect);

	NSRect stripRect, contentRect;
	NSDivideRect(self.bounds, &stripRect, &contentRect, [self topStripHeight], NSMaxYEdge);
	[BlendedColor(foreground, background, 0.85) set];
	NSRectFill(NSMakeRect(NSMinX(stripRect), NSMinY(stripRect), NSWidth(stripRect), 1)); // bottom-most strip row — the scroll view covers everything below

	if(_bannerVisible)
	{
		NSRect bannerRect = NSMakeRect(NSMinX(stripRect), NSMinY(stripRect), NSWidth(stripRect), kDiffPaneBannerHeight);
		[[NSColor.systemYellowColor colorWithAlphaComponent:0.08] set];
		NSRectFillUsingOperation(bannerRect, NSCompositingOperationSourceOver);
		[BlendedColor(foreground, background, 0.85) set];
		NSRectFill(NSMakeRect(NSMinX(bannerRect), NSMaxY(bannerRect) - 1, NSWidth(bannerRect), 1));
	}
}

- (void)layout
{
	[super layout];
	NSRect bounds = self.bounds;
	NSRect headerRect, rest, bannerRect, contentRect;
	NSDivideRect(bounds, &headerRect, &rest, kDiffPaneHeaderHeight, NSMaxYEdge);
	if(_bannerVisible)
		NSDivideRect(rest, &bannerRect, &contentRect, kDiffPaneBannerHeight, NSMaxYEdge);
	else
		contentRect = rest;
	self.needsDisplay = YES; // strip background + separators are drawn by us

	// Header line: close ⋅ ◀ ▶ ⋅ title … [base ▾]. 8 pt edge margins, 10 pt
	// between groups. All horizontal math uses alignment rects — rounded
	// bezels carry invisible frame padding, so frame-based gaps render
	// wider than specified and visually uneven.
	CGFloat const edgeMargin = 8;
	CGFloat const sectionGap = 10;
	CGFloat const buttonGap  = 3;

	auto alignmentSize = [](NSControl* control) -> NSSize {
		[control sizeToFit];
		return [control alignmentRectForFrame:(NSRect){ NSZeroPoint, control.frame.size }].size;
	};

	// Place a control with its alignment rect’s left edge at x, vertically
	// centered in the given strip; returns the alignment rect used.
	auto place = [](NSControl* control, NSRect strip, CGFloat x, NSSize size) -> NSRect {
		NSRect alignmentRect = NSMakeRect(x, NSMinY(strip) + round((NSHeight(strip) - size.height) / 2), size.width, size.height);
		control.frame = [control frameForAlignmentRect:alignmentRect];
		return alignmentRect;
	};

	CGFloat x = NSMinX(headerRect) + edgeMargin;
	NSRect const closeRect = place(_closeButton, headerRect, x, NSMakeSize(16, 16));
	x = NSMaxX(closeRect) + sectionGap;

	NSRect const prevRect = place(_previousHunkButton, headerRect, x, NSMakeSize(16, 16));
	x = NSMaxX(prevRect) + buttonGap;
	NSRect const nextRect = place(_nextHunkButton, headerRect, x, NSMakeSize(16, 16));
	x = NSMaxX(nextRect) + sectionGap;

	CGFloat titleRight = NSMaxX(headerRect) - edgeMargin;
	if(!_revertAllButton.hidden)
	{
		NSSize const revertSize = alignmentSize(_revertAllButton);
		NSRect const revertRect = place(_revertAllButton, headerRect, titleRight - revertSize.width, revertSize);
		titleRight = NSMinX(revertRect) - sectionGap;
	}

	// Title fills what is left between the hunk buttons and the right edge.
	[_headerField sizeToFit];
	place(_headerField, headerRect, x, NSMakeSize(std::max<CGFloat>(0, titleRight - x), NSHeight(_headerField.frame)));

	if(_bannerVisible && _bannerField)
	{
		CGFloat bx = NSMinX(bannerRect) + edgeMargin;
		NSRect const dismissRect = place(_bannerCloseButton, bannerRect, bx, NSMakeSize(14, 14));
		bx = NSMaxX(dismissRect) + sectionGap - 4;

		CGFloat rightEdge = NSMaxX(bannerRect) - edgeMargin;
		if(!_bannerActionButton.hidden)
		{
			NSSize const actionSize = alignmentSize(_bannerActionButton);
			NSRect const actionRect = place(_bannerActionButton, bannerRect, rightEdge - actionSize.width, actionSize);
			rightEdge = NSMinX(actionRect) - sectionGap;
		}

		[_bannerField sizeToFit];
		CGFloat const bannerFieldHeight = NSHeight(_bannerField.frame);
		_bannerField.frame = NSMakeRect(bx, NSMinY(bannerRect) + round((NSHeight(bannerRect) - bannerFieldHeight) / 2), std::max<CGFloat>(0, rightEdge - bx), bannerFieldHeight);
	}

	BOOL const contentChanged = !NSEqualRects(_listScrollView.frame, contentRect);
	_listScrollView.frame = contentRect;
	if(contentChanged)
		[self layoutHunks];

	_emptyStateField.frame = NSMakeRect(NSMinX(contentRect) + 12, NSMaxY(contentRect) - 40, std::max<CGFloat>(0, NSWidth(contentRect) - 24), 20);
}

// =============
// = Lifecycle =
// =============

- (void)setActive:(BOOL)flag
{
	if(_active == flag)
		return;
	_active = flag;

	if(_active)
	{
		[self createSubviewsIfNeeded];
		[self renderNow];
	}
	else
	{
		++_generation; // orphan any in-flight render

		[_listScrollView removeFromSuperview];
		[_emptyStateField removeFromSuperview];
		[_headerField removeFromSuperview];
		[_closeButton removeFromSuperview];
		[_previousHunkButton removeFromSuperview];
		[_nextHunkButton removeFromSuperview];
		[_revertAllButton removeFromSuperview];
		[self removeBannerViews];

		[_hunkViews removeAllObjects];
		_listScrollView     = nil;
		_listView           = nil;
		_emptyStateField    = nil;
		_headerField        = nil;
		_closeButton        = nil;
		_previousHunkButton = nil;
		_nextHunkButton     = nil;
		_revertAllButton    = nil;
		_cards.clear();
		_activeHunkIndex = diff_pane::npos;
	}
}

- (void)createSubviewsIfNeeded
{
	if(_listScrollView)
		return;

	_closeButton = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"xmark.circle.fill" accessibilityDescription:@"Close Diff"] target:self action:@selector(didClickClose:)];
	_closeButton.bordered = NO;
	_closeButton.toolTip  = @"Close diff";

	_previousHunkButton = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"chevron.up" accessibilityDescription:@"Previous Change"] target:self action:@selector(didClickPreviousHunk:)];
	_previousHunkButton.bordered = NO;
	_previousHunkButton.toolTip  = @"Jump to previous change";

	_nextHunkButton = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"chevron.down" accessibilityDescription:@"Next Change"] target:self action:@selector(didClickNextHunk:)];
	_nextHunkButton.bordered = NO;
	_nextHunkButton.toolTip  = @"Jump to next change";

	// Borderless like the hunk bands' own Revert controls, and for the same
	// reason: a bezeled control on the header strip renders for the system
	// appearance rather than the editor theme.
	_revertAllButton = [NSButton buttonWithTitle:@"Revert All" target:self action:@selector(didClickRevertAll:)];
	_revertAllButton.bordered      = NO;
	_revertAllButton.focusRingType = NSFocusRingTypeNone;
	_revertAllButton.toolTip       = @"Put every hunk in this file back, as one undoable edit";


	_headerField = [[NSTextField alloc] initWithFrame:NSZeroRect];
	_headerField.bordered        = NO;
	_headerField.editable        = NO;
	_headerField.selectable      = NO;
	_headerField.bezeled         = NO;
	_headerField.drawsBackground = NO;
	_headerField.font            = [NSFont systemFontOfSize:[NSFont systemFontSizeForControlSize:NSControlSizeSmall]];
	[[_headerField cell] setLineBreakMode:NSLineBreakByTruncatingMiddle]; // long file names keep their extension visible, like the status-bar fields

	_emptyStateField = [[NSTextField alloc] initWithFrame:NSZeroRect];
	_emptyStateField.bordered        = NO;
	_emptyStateField.editable        = NO;
	_emptyStateField.selectable      = NO;
	_emptyStateField.bezeled         = NO;
	_emptyStateField.drawsBackground = NO;
	_emptyStateField.font            = [NSFont systemFontOfSize:[NSFont systemFontSizeForControlSize:NSControlSizeSmall]];
	_emptyStateField.hidden          = YES;

	_listView = [[DiffPaneListView alloc] initWithFrame:NSZeroRect];

	_listScrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
	_listScrollView.borderType            = NSNoBorder;
	_listScrollView.hasVerticalScroller   = YES;
	_listScrollView.hasHorizontalScroller = YES;
	_listScrollView.autohidesScrollers    = YES;
	_listScrollView.drawsBackground       = YES;
	_listScrollView.documentView          = _listView;

	[self addSubview:_listScrollView];
	[self addSubview:_emptyStateField];
	[self addSubview:_headerField];
	[self addSubview:_closeButton];
	[self addSubview:_previousHunkButton];
	[self addSubview:_nextHunkButton];
	[self addSubview:_revertAllButton];

	[self applyThemeColors];
	[self updateHeader];
	self.needsLayout = YES;
}

- (void)didClickClose:(id)sender
{
	if(self.closeHandler)
		self.closeHandler();
}

// ==========================
// = Snapshot, caret, hunks =
// ==========================

- (void)setDocument:(OakDocument*)aDocument
{
	if(_document == aDocument)
		return;

	_document = aDocument;
	_snapshot = nil;
	_cards.clear();
	_activeHunkIndex = diff_pane::npos;

	if(_active)
	{
		[self renderNow];
		[self updateHeader];
	}
}

- (void)takeSnapshot:(BufferDiffSnapshot*)aSnapshot
{
	_snapshot = aSnapshot;
	if(!_active)
		return;

	[self renderNow];
}

- (void)setCaretLine:(NSUInteger)line
{
	if(_caretLine == line)
		return;
	_caretLine = line;
	[self updateActiveHunk];
}

// The active-hunk highlight is a per-view flag, never a rebuild: moving
// the caret must not disturb a list the reader is browsing.
- (void)updateActiveHunk
{
	size_t const index = diff_pane::card_for_caret(_cards, _caretLine);
	if(index == _activeHunkIndex)
		return;
	_activeHunkIndex = index;

	for(NSUInteger i = 0; i < _hunkViews.count; ++i)
		_hunkViews[i].activeHunk = (index != diff_pane::npos && i == index);

	[self updateHeader];
}

- (void)jumpToBufferLine:(NSUInteger)line
{
	if(line && self.moveCaretHandler)
		self.moveCaretHandler(line);
}

// ==============
// = Navigation =
// ==============

// Stepping is caret-relative: since next/previous also MOVE the caret,
// repeated presses walk the list without any stored cursor to fall out
// of sync with a rebuilt list.
- (size_t)indexOfNextHunk
{
	for(size_t i = 0; i < _cards.size(); ++i)
	{
		if(_cards[i].anchor_line > _caretLine)
			return i;
	}
	return diff_pane::npos;
}

- (size_t)indexOfPreviousHunk
{
	for(size_t i = _cards.size(); i-- > 0; )
	{
		if(_cards[i].anchor_line < _caretLine)
			return i;
	}
	return diff_pane::npos;
}

- (BOOL)canSelectNextHunk     { return [self indexOfNextHunk] != diff_pane::npos; }
- (BOOL)canSelectPreviousHunk { return [self indexOfPreviousHunk] != diff_pane::npos; }

- (BOOL)selectHunkAtIndex:(size_t)index
{
	if(index == diff_pane::npos || index >= _cards.size())
		return NO;

	[self scrollHunkToVisible:index];
	[self jumpToBufferLine:_cards[index].anchor_line];
	return YES;
}

- (BOOL)selectNextHunk     { return [self selectHunkAtIndex:[self indexOfNextHunk]]; }
- (BOOL)selectPreviousHunk { return [self selectHunkAtIndex:[self indexOfPreviousHunk]]; }

- (void)didClickNextHunk:(id)sender     { [self selectNextHunk]; }
- (void)didClickPreviousHunk:(id)sender { [self selectPreviousHunk]; }

// ==========================
// = Revert — a buffer edit =
// ==========================
//
// Reverting puts the base-side text back by editing the buffer, never by
// running git: it cannot clobber unsaved work (that work IS what is being
// edited), it needs no subprocess, and ⌘Z un-reverts it like any other
// edit.

// Reverting needs a base to revert to, which an untracked file has not:
// its single hunk is the whole file, so "revert" would mean emptying the
// buffer. Delete the file instead.
- (BOOL)canRevert
{
	return _document && _snapshot.repoState == BufferDiffRepoStateReady && _snapshot.isTracked;
}

// Against an older base this is a restore to a past version, not an undo
// of the reader's own edits — so the label says which version, before the
// click rather than only in a confirmation.
- (NSString*)revertTitleForAll:(BOOL)all
{
	NSString* const verb = all ? @"Revert All" : @"Revert";
	return _snapshot.isBaseHead ? verb : [NSString stringWithFormat:@"%@ to %@", verb, ShortSHA(_snapshot.baseRef)];
}

- (void)didClickRevertAll:(id)sender { [self beginRevertOfHunk:diff_pane::kAllHunks]; }
- (void)revertHunkAtIndex:(NSUInteger)index { [self beginRevertOfHunk:(size_t)index]; }

// A single hunk is shown in full right above the control and ⌘Z takes it
// back, so it needs no confirmation of its own. Two things the reader
// cannot see from the card do warrant one: that the base is an older
// commit (a restore, not an undo), and that the index holds a staged copy
// this will not touch. Reverting everything always confirms — the target
// is the whole file, most of which is off-screen.
- (void)beginRevertOfHunk:(size_t)index
{
	if(![self canRevert])
		return;

	BOOL const all = index == diff_pane::kAllHunks;
	BOOL const staged = _snapshot.hasStagedChanges;
	BOOL const olderBase = !_snapshot.isBaseHead;

	// The revert acts on THIS snapshot, not on whichever one is current
	// when it is confirmed. A confirmation runs the run loop, and while
	// its sheet is up an agent write can reload the document and deliver
	// a fresh snapshot into _snapshot — a different hunk 2, at a different
	// place. Capturing here means the byte gate in the apply compares the
	// live buffer against the snapshot the reader actually saw, so if the
	// buffer moved on the revert refuses rather than acting on a hunk the
	// sheet never named. (The unconfirmed path applies synchronously in
	// this same event, so nothing can interleave, but it costs nothing to
	// route it through the same capture.)
	BufferDiffSnapshot* const snapshot = _snapshot;

	if(!all && !staged && !olderBase)
		return [self applyRevertOfHunk:index fromSnapshot:snapshot];

	NSString* const target = all ? @"every change in this file" : @"this hunk";
	NSString* const messageText = olderBase
		? [NSString stringWithFormat:@"Restore %@ to %@?", target, ShortSHA(snapshot.baseRef)]
		: [NSString stringWithFormat:@"Revert %@?", target];

	NSMutableArray<NSString*>* notes = [NSMutableArray array];
	[notes addObject:[NSString stringWithFormat:@"The buffer goes back to the %@ version; ⌘Z undoes it.", olderBase ? ShortSHA(snapshot.baseRef) : @"committed"]];
	if(staged)
		[notes addObject:@"Staged changes are left in the index and stay committable."];

	NSAlert* alert = [NSAlert tmAlertWithMessageText:messageText informativeText:[notes componentsJoinedByString:@" "] buttons:[self revertTitleForAll:all], @"Cancel", nil];

	__weak DiffPaneView* weakSelf = self;
	auto const handler = ^(NSModalResponse response){
		if(response == NSAlertFirstButtonReturn)
			[weakSelf applyRevertOfHunk:index fromSnapshot:snapshot];
	};

	if(self.window)
			[alert beginSheetModalForWindow:self.window completionHandler:handler];
	else	handler([alert runModal]);
}

- (void)applyRevertOfHunk:(size_t)index fromSnapshot:(BufferDiffSnapshot*)snapshot
{
	OakDocument* document = _document;
	if(!snapshot || !document.isLoaded)
		return;

	std::string const liveText = BufferBytes(document);

	auto const replacements = diff_pane::replacements_for_revert([snapshot hunks], index, [snapshot baseText], [snapshot bufferText], liveText);
	if(replacements.empty())
	{
		// Typing inside the recompute debounce is enough to get here: the
		// snapshot still looks current while the buffer has already moved
		// on. The recompute already on its way redraws the list.
		[OTVHUD showHudForView:self withText:@"Changed while reverting — try again"];
		return;
	}

	// Whether the revert should reach disk depends on what disk held
	// BEFORE it, so ask now.
	BOOL const wasClean = !document.isDocumentEdited;

	if(![document performReplacements:replacements checksum:0])
		return;

	// Disk-sync rule: when the document had nothing unsaved, save, so
	// that agents, tests and git see what the reader now sees — this is
	// the ordinary case, an agent having written the file and the reader
	// putting one hunk back. When it was already dirty, saving would
	// flush unrelated unsaved edits as a side effect, so leave it to the
	// reader; the Unsaved chip says so.
	if(wasClean)
	{
		if(![NSApp sendAction:@selector(saveDocument:) to:nil from:self])
			[document saveModalForWindow:self.window completionHandler:nil];
	}
}

- (void)scrollHunkToVisible:(size_t)index
{
	if(index >= _hunkViews.count)
		return;

	NSRect const hunkFrame = _hunkViews[index].frame;
	NSRect const visible   = _listScrollView.contentView.bounds;

	// Bring the hunk's header into view, but leave the list alone when it
	// is already comfortably visible.
	if(NSMinY(hunkFrame) < NSMinY(visible) || NSMaxY(hunkFrame) > NSMaxY(visible))
		[_listView scrollPoint:NSMakePoint(NSMinX(visible), std::max<CGFloat>(0, NSMinY(hunkFrame) - kHunkHeaderHeight))];
}

// ==========
// = Banner =
// ==========

- (void)showBannerWithMessage:(NSString*)aMessage actionTitle:(NSString*)aTitle handler:(void(^)(void))aHandler
{
	if(!_active)
		return;
	[self createSubviewsIfNeeded];

	if(!_bannerField)
	{
		_bannerField = [[NSTextField alloc] initWithFrame:NSZeroRect];
		_bannerField.bordered        = NO;
		_bannerField.editable        = NO;
		_bannerField.selectable      = NO;
		_bannerField.bezeled         = NO;
		_bannerField.drawsBackground = NO;
		_bannerField.font            = [NSFont systemFontOfSize:[NSFont systemFontSizeForControlSize:NSControlSizeSmall]];
		[[_bannerField cell] setLineBreakMode:NSLineBreakByTruncatingTail];

		_bannerCloseButton = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"xmark" accessibilityDescription:@"Dismiss"] target:self action:@selector(didDismissBanner:)];
		_bannerCloseButton.bordered = NO;

		_bannerActionButton = [NSButton buttonWithTitle:@"" target:self action:@selector(didClickBannerAction:)];
		_bannerActionButton.controlSize = NSControlSizeSmall;
		_bannerActionButton.bezelStyle  = NSBezelStyleRounded;
		_bannerActionButton.font        = [NSFont systemFontOfSize:[NSFont systemFontSizeForControlSize:NSControlSizeSmall]];

		[self addSubview:_bannerField];
		[self addSubview:_bannerCloseButton];
		[self addSubview:_bannerActionButton];
	}

	_bannerField.stringValue   = aMessage ?: @"";
	_bannerActionButton.hidden = aTitle == nil;
	if(aTitle)
		_bannerActionButton.title = aTitle;
	_bannerHandler = [aHandler copy];
	_bannerVisible = YES;

	[self applyThemeColors];
	self.needsLayout = YES;
}

- (void)dismissBanner
{
	if(!_bannerVisible)
		return;
	[self removeBannerViews];
	self.needsLayout  = YES;
	self.needsDisplay = YES;
}

- (void)removeBannerViews
{
	[_bannerField removeFromSuperview];
	[_bannerActionButton removeFromSuperview];
	[_bannerCloseButton removeFromSuperview];
	_bannerField        = nil;
	_bannerActionButton = nil;
	_bannerCloseButton  = nil;
	_bannerVisible      = NO;
	_bannerHandler      = nil;
}

- (void)didDismissBanner:(id)sender
{
	[self dismissBanner];
}

- (void)didClickBannerAction:(id)sender
{
	void (^handler)(void) = _bannerHandler;
	[self dismissBanner];
	if(handler)
		handler();
}

// =========
// = Style =
// =========

// Everything the hunk views need to draw, resolved from the editor theme.
// The line-number columns deliberately reuse the editor gutter's own font
// and colors, so the pane reads as part of the same editor.
- (DiffPaneStyle*)buildStyleForLineCount:(size_t)widestNumber
{
	NSColor* background = _themeBackgroundColor ?: NSColor.textBackgroundColor;
	NSColor* foreground = _themeForegroundColor ?: NSColor.textColor;

	NSFont* codeFont;
	if(_theme && _theme->font_name() != NULL_STR)
		codeFont = [NSFont fontWithName:to_ns(_theme->font_name()) size:_theme->font_size()];
	if(!codeFont)
		codeFont = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];

	NSFont* numberFont = _lineNumberFont ?: [NSFont fontWithName:codeFont.fontName size:round(codeFont.pointSize * 0.8)] ?: codeFont;

	DiffPaneStyle* style = [DiffPaneStyle new];
	style.codeFont         = codeFont;
	style.lineNumberFont   = numberFont;
	style.background       = background;
	style.foreground       = foreground;
	style.gutterBackground = _gutterBackgroundColor ?: BlendedColor(foreground, background, 0.94);
	style.gutterForeground = _gutterForegroundColor ?: BlendedColor(foreground, background, 0.55);
	style.gutterDivider    = _gutterDividerColor ?: BlendedColor(foreground, background, 0.85);

	// Blend the tints into the theme background rather than compositing a
	// translucent system color, so they stay legible on dark themes and
	// never fight the theme's own palette. They only have to be enough to
	// read a row's side at a glance — the marker column says which it is.
	style.addedTint   = BlendedColor(NSColor.systemGreenColor, background, 0.88);
	style.deletedTint = BlendedColor(NSColor.systemRedColor, background, 0.88);

	// The markers sit in the gutter, on the gutter background rather than
	// on the tint, so they must carry the add/delete signal on their own —
	// they are the only cue a reader who cannot separate the two tints has.
	style.addedMarkerColor   = BlendedColor(NSColor.systemGreenColor, style.gutterForeground, 0.45);
	style.deletedMarkerColor = BlendedColor(NSColor.systemRedColor, style.gutterForeground, 0.45);

	style.headerBackground       = style.gutterBackground;
	style.activeHeaderBackground = BlendedColor(NSColor.controlAccentColor, background, 0.75);
	style.headerForeground       = BlendedColor(foreground, background, 0.25);

	// Match the editor's layout exactly, so a diff row and the buffer line
	// it came from are the same height. TextKit's own line height for the
	// same font is a different calculation and comes out slightly shorter.
	style.rowHeight = _editorLineHeight > 0 ? _editorLineHeight : ceil([[NSLayoutManager new] defaultLineHeightForFont:codeFont]);

	int digits = 1;
	for(size_t n = widestNumber; n >= 10; n /= 10)
		++digits;
	style.digits = digits;

	NSDictionary* numberAttributes = @{ NSFontAttributeName: numberFont };
	style.columnWidth = ceil([[@"" stringByPaddingToLength:digits withString:@"9" startingAtIndex:0] sizeWithAttributes:numberAttributes].width);
	style.markerWidth = ceil([@"+" sizeWithAttributes:@{ NSFontAttributeName: codeFont }].width) + 6;
	style.gutterWidth = ceil(kGutterPadding + style.columnWidth + kGutterColumnGap + style.columnWidth + style.markerWidth);

	return style;
}

// ===================
// = Update pipeline =
// ===================

- (void)renderNow
{
	if(!_active || !_listView)
		return;

	BufferDiffSnapshot* snapshot = _snapshot;
	NSUInteger const generation  = ++_generation;

	diff_pane::empty_state const state = [self classifyEmptyStateForSnapshot:snapshot];
	if(state != diff_pane::empty_state::has_hunks)
	{
		_activeHunkIndex = diff_pane::npos;
		[self applyHunkContents:@[] cards:std::vector<diff_pane::card_t>()];
		_emptyStateField.stringValue = to_ns([self emptyStateMessage:state forSnapshot:snapshot]) ?: @"";
		_emptyStateField.hidden      = NO;
		[self updateHeader];
		return;
	}

	// There are hunks, but the rendering of them runs off the main thread
	// and can take a moment on a large file. With no previous list to keep
	// showing, the pane would otherwise sit blank and silent until it
	// finishes.
	if(_hunkViews.count == 0)
	{
		_emptyStateField.stringValue = @"Preparing diff…";
		_emptyStateField.hidden      = NO;
	}

	std::vector<diff_pane::card_t> cards = diff_pane::build_cards([snapshot hunks], [snapshot baseText], [snapshot bufferText]);

	// Main-thread-only references, used to size the style and decide about
	// highlighting below. The render block deliberately does NOT use them
	// — see the re-acquisition inside it.
	std::string const& baseText   = [snapshot baseText];
	std::string const& bufferText = [snapshot bufferText];

	DiffPaneStyle* style = [self buildStyleForLineCount:std::max(diff_pane::line_count(baseText), diff_pane::line_count(bufferText))];
	theme_ptr const renderTheme = _renderTheme;

	// Highlighting needs a parse from the file start (a fragment would
	// mis-scope multi-line comments and strings), but only up to the last
	// line any hunk displays.
	size_t maxBaseLine = 0, maxBufferLine = 0;
	for(auto const& card : cards)
	{
		for(auto const& row : card.rows)
		{
			maxBaseLine   = std::max(maxBaseLine, row.base_line);
			maxBufferLine = std::max(maxBufferLine, row.buffer_line);
		}
	}

	parse::grammar_ptr const grammar = renderTheme && baseText.size() + bufferText.size() < kMaxHighlightBytes ? [self grammarForFileType:_document.fileType] : parse::grammar_ptr();

	// Identifies the base parse: everything its scopes depend on. Hashing
	// the text rather than trusting the ref catches a base that changed
	// underneath the same name — HEAD moving, or a commit amended.
	std::string baseScopesKey = to_s(snapshot.baseRef ?: @"");
	baseScopesKey += '\0';
	baseScopesKey += to_s(_document.path ?: @"");
	baseScopesKey += '\0';
	baseScopesKey += to_s(_document.fileType ?: @"");
	baseScopesKey += '\0';
	baseScopesKey += std::to_string(std::hash<std::string>{}(baseText));

	// Pin every row to the same height, so the drawn line numbers, markers
	// and tints line up with the text no matter what the theme's bold or
	// italic variants would otherwise measure.
	NSMutableParagraphStyle* paragraphStyle = [NSMutableParagraphStyle new];
	paragraphStyle.minimumLineHeight = style.rowHeight;
	paragraphStyle.maximumLineHeight = style.rowHeight;
	paragraphStyle.lineSpacing       = 0;

	// Folded into every hunk's signature, so that switching theme or font
	// — which leaves the text identical but restyles it — still counts as
	// changed content. Without this the reuse check below would keep the
	// old attributed strings and the bodies would stay the old colour.
	//
	// The theme's own identity has to be in here, not just the colours it
	// resolves to: two themes can agree on plain foreground, background
	// and font while scoping keywords and strings completely differently,
	// and only the syntax runs would have gone stale. The grammar counts
	// for the same reason — it decides which scopes exist at all.
	NSString* const themeIdentity   = renderTheme ? to_ns(to_s(renderTheme->uuid())) : @"-";
	NSString* const grammarIdentity = grammar ? (_document.fileType ?: @"?") : @"-";
	NSUInteger const styleHash = [[NSString stringWithFormat:@"%@|%@|%@|%@|%.2f|%.2f|%@|%@", style.foreground, style.background, style.gutterForeground, style.codeFont.fontName, style.codeFont.pointSize, style.rowHeight, themeIdentity, grammarIdentity] hash];

	__weak DiffPaneView* weakSelf = self;
	dispatch_async(_renderQueue, ^{
		DiffPaneView* pane = weakSelf;
		if(!pane || generation != pane->_generation)
			return;

		// Ask the snapshot for its text HERE, not outside: a block captures
		// a reference variable as a reference, not as a copy of what it
		// points at, and nothing else in this block mentions the snapshot —
		// so it would not be retained, and the pane replacing _snapshot
		// mid-parse would leave these dangling. Naming `snapshot` inside
		// the block is what keeps it alive for the whole render. The
		// generation check above only guards entry, never a parse already
		// running. Snapshots are immutable, so sharing one is safe.
		std::string const& baseText   = [snapshot baseText];
		std::string const& bufferText = [snapshot bufferText];

		auto const baseScopes   = [pane baseScopesFor:baseText grammar:grammar upToLine:maxBaseLine key:baseScopesKey];
		auto const bufferScopes = std::make_shared<std::map<size_t, scope::scope_t>>(ScopesUpToLine(bufferText, grammar, maxBufferLine));

		auto lineStarts = [](std::string const& text){
			std::vector<size_t> starts { 0 };
			for(size_t i = 0; i < text.size(); ++i)
			{
				if(text[i] == '\n')
					starts.push_back(i + 1);
			}
			return starts;
		};
		auto const baseStarts   = lineStarts(baseText);
		auto const bufferStarts = lineStarts(bufferText);

		NSDictionary* baseAttributes = @{ NSFontAttributeName: style.codeFont, NSForegroundColorAttributeName: style.foreground, NSParagraphStyleAttributeName: paragraphStyle };

		NSMutableArray<DiffHunkContent*>* contents = [NSMutableArray arrayWithCapacity:cards.size()];
		std::hash<std::string> const hasher;

		for(auto const& card : cards)
		{
			NSMutableAttributedString* body = [NSMutableAttributedString new];
			std::vector<diff_row_t> rows;
			size_t signature = card.rows.size();

			for(size_t i = 0; i < card.rows.size(); ++i)
			{
				auto const& row = card.rows[i];
				bool const isDeleted = row.kind == diff_pane::row_kind::deleted;

				// Code comes from whichever side the row belongs to, sliced
				// out of that side's full-text parse.
				std::string const& sourceText = isDeleted ? baseText : bufferText;
				auto const& sourceStarts      = isDeleted ? baseStarts : bufferStarts;
				auto const& sourceScopes      = isDeleted ? baseScopes : bufferScopes;  // shared_ptr
				size_t const sourceLine       = isDeleted ? row.base_line : row.buffer_line;

				size_t from = 0, to = 0;
				if(sourceLine >= 1 && sourceLine <= sourceStarts.size())
				{
					from = sourceStarts[sourceLine-1];
					to   = sourceLine < sourceStarts.size() ? sourceStarts[sourceLine] : sourceText.size();
					while(to > from && (sourceText[to-1] == '\n' || sourceText[to-1] == '\r'))
						--to;
				}

				[pane appendStyledSlice:body text:sourceText from:from to:to scopes:sourceScopes.get() theme:renderTheme baseAttributes:baseAttributes];
				if(i + 1 < card.rows.size())
					[body appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n" attributes:baseAttributes]];

				rows.push_back({ row.kind, row.base_line, row.buffer_line, row.jump_line });
				signature = signature * 31 + hasher(row.text) + (size_t)row.kind * 7 + row.base_line * 13 + row.buffer_line * 17;
			}

			// The lines on display, buffer-side — a range the reader can go
			// look at. Only a card with nothing left on the buffer side has
			// to name base-side lines, and then it says so.
			NSString* span = card.header_span.first == card.header_span.last
				? [NSString stringWithFormat:@"Line %zu", card.header_span.first]
				: [NSString stringWithFormat:@"Lines %zu–%zu", card.header_span.first, card.header_span.last];
			NSString* headerText = [NSString stringWithFormat:@"Hunk %zu : %@%@", card.hunk_index + 1, span, card.header_is_base_side ? @" (deleted)" : @""];

			DiffHunkContent* content = [DiffHunkContent new];
			content.headerText = headerText;
			content.body       = body;
			content.anchorLine = (NSUInteger)card.anchor_line;
			content.signature  = (NSUInteger)(signature * 31 + hasher(to_s(headerText))) ^ styleHash;
			[content setRows:std::move(rows)];
			[contents addObject:content];
		}

		dispatch_async(dispatch_get_main_queue(), ^{
			DiffPaneView* strongSelf = weakSelf;
			if(!strongSelf || generation != strongSelf->_generation || !strongSelf->_listView)
				return;
			[strongSelf takeStyle:style];
			[strongSelf applyHunkContents:contents cards:cards];
			[strongSelf updateHeader];
		});
	});
}

- (void)takeStyle:(DiffPaneStyle*)aStyle
{
	for(DiffHunkView* hunk in _hunkViews)
		hunk.style = aStyle;
	_listScrollView.backgroundColor = aStyle.background;
	_paneStyle = aStyle;
}

// Swap in a freshly built hunk list. Views whose content is unchanged are
// kept, so typing inside one hunk does not rebuild the others; the scroll
// position is re-anchored to the hunk that was at the top, by buffer
// position rather than by index.
- (void)applyHunkContents:(NSArray<DiffHunkContent*>*)contents cards:(std::vector<diff_pane::card_t> const&)cards
{
	// Remember what the reader was looking at before anything moves.
	NSUInteger anchoredLine = 0;
	CGFloat anchoredOffset = 0;
	NSRect const visible = _listScrollView.contentView.bounds;
	for(DiffHunkView* hunk in _hunkViews)
	{
		if(NSMaxY(hunk.frame) > NSMinY(visible))
		{
			anchoredLine   = hunk.anchorLine;
			anchoredOffset = NSMinY(hunk.frame) - NSMinY(visible);
			break;
		}
	}

	while(_hunkViews.count > contents.count)
	{
		[_hunkViews.lastObject removeFromSuperview];
		[_hunkViews removeLastObject];
	}

	for(NSUInteger i = 0; i < contents.count; ++i)
	{
		DiffHunkView* view = i < _hunkViews.count ? _hunkViews[i] : nil;
		if(!view)
		{
			view = [[DiffHunkView alloc] initWithFrame:NSZeroRect];
			view.pane  = self;
			view.style = _paneStyle;
			[_listView addSubview:view];
			[_hunkViews addObject:view];
		}
		// Outside the signature check: a reused view may be showing the
		// same lines at a different position in the list, and its Revert
		// control has to act on the hunk it is actually sitting on.
		view.hunkIndex = i;
		if(view.signature != contents[i].signature)
			[view takeContent:contents[i]];
	}

	if(contents.count)
		_emptyStateField.hidden = YES; // the list is up — retire the placeholder

	_cards = cards;
	[self layoutHunks];

	// The caret's hunk may be a different index now.
	_activeHunkIndex = diff_pane::npos;
	[self updateActiveHunk];

	if(anchoredLine)
		[self restoreScrollToAnchorLine:anchoredLine offset:anchoredOffset];
}

- (void)restoreScrollToAnchorLine:(NSUInteger)anchoredLine offset:(CGFloat)anchoredOffset
{
	if(!_hunkViews.count)
		return;

	// The hunk that was on top may have moved, merged or gone; land on
	// the nearest surviving one by buffer position.
	NSUInteger best = 0;
	NSUInteger bestDistance = NSUIntegerMax;
	for(NSUInteger i = 0; i < _hunkViews.count; ++i)
	{
		NSUInteger const line = _hunkViews[i].anchorLine;
		NSUInteger const distance = line > anchoredLine ? line - anchoredLine : anchoredLine - line;
		if(distance < bestDistance)
		{
			bestDistance = distance;
			best = i;
		}
	}

	NSRect const target = _hunkViews[best].frame;
	CGFloat const maxY  = std::max<CGFloat>(0, NSHeight(_listView.frame) - NSHeight(_listScrollView.contentView.bounds));
	[_listView scrollPoint:NSMakePoint(NSMinX(_listScrollView.contentView.bounds), std::min(std::max<CGFloat>(0, NSMinY(target) - anchoredOffset), maxY))];
}

// Hunks stack flush against each other: the header band is the separator,
// so the list reads as one continuous document rather than a set of cards.
- (void)layoutHunks
{
	if(!_listView || !_paneStyle)
		return;

	CGFloat const availableWidth = _listScrollView.contentSize.width;

	CGFloat contentWidth = availableWidth;
	std::vector<CGFloat> heights;
	heights.reserve(_hunkViews.count);
	for(DiffHunkView* hunk in _hunkViews)
	{
		contentWidth = std::max(contentWidth, [hunk bodyLeftInset] + [hunk widthOfWidestLine]);
		heights.push_back([hunk heightForRows]);
	}

	CGFloat y = 0;
	for(NSUInteger i = 0; i < _hunkViews.count; ++i)
	{
		[_hunkViews[i] setFrame:NSMakeRect(0, y, contentWidth, heights[i])];
		_hunkViews[i].headerContentWidth = availableWidth; // keeps the Revert control inside the viewport
		_hunkViews[i].needsLayout = YES;
		y += heights[i];
	}

	[_listView setFrameSize:NSMakeSize(contentWidth, std::max(y, NSHeight(_listScrollView.contentView.bounds)))];
}

// Render-queue-only: the base-side parse, reused across recomputes.
// Buffer edits cannot change the base, so without this every keystroke's
// recompute re-parses an identical text — half the render for nothing.
// A cache built for a shorter reach is not reusable: the parse stops at
// the last line on display, so a hunk further down needs a longer one.
- (std::shared_ptr<std::map<size_t, scope::scope_t>>)baseScopesFor:(std::string const&)text grammar:(parse::grammar_ptr const&)grammar upToLine:(size_t)maxLine key:(std::string const&)key
{
	bool const haveGrammar = (bool)grammar;

	if(_baseScopes && diff_pane::can_reuse_base_scopes(_baseScopesKey, _baseScopesMaxLine, key, maxLine, haveGrammar))
		return _baseScopes;

	auto scopes = std::make_shared<std::map<size_t, scope::scope_t>>(ScopesUpToLine(text, grammar, maxLine));

	// Without a grammar there is nothing to remember, and remembering the
	// empty result would shadow a real parse of the same base: the
	// highlighting cap counts base and buffer together, so typing alone
	// can switch the grammar off and back on while the base sits still.
	if(haveGrammar)
	{
		_baseScopesKey     = key;
		_baseScopesMaxLine = maxLine;
		_baseScopes        = scopes;
	}
	return scopes;
}

// Render-queue-only: append text[from, to) styled by the (full-text)
// scope runs.
- (void)appendStyledSlice:(NSMutableAttributedString*)output text:(std::string const&)text from:(size_t)from to:(size_t)to scopes:(std::map<size_t, scope::scope_t> const*)scopes theme:(theme_ptr const&)theme baseAttributes:(NSDictionary*)baseAttributes
{
	if(to <= from)
		return;

	auto appendRun = [&](size_t runFrom, size_t runTo, scope::scope_t const* scope){
		NSMutableDictionary* attrs = [baseAttributes mutableCopy];
		if(scope && theme)
		{
			auto const& styles = theme->styles_for_scope(*scope);
			if(NSColor* color = [NSColor colorWithCGColor:styles.foreground()])
				attrs[NSForegroundColorAttributeName] = color;
			if(NSFont* runFont = (__bridge NSFont*)styles.font()) // theme font — bold/italic variants of the editor font
				attrs[NSFontAttributeName] = runFont;
			if(styles.underlined())
				attrs[NSUnderlineStyleAttributeName] = @(NSUnderlineStyleSingle);
		}
		NSString* str = to_ns(text.substr(runFrom, runTo - runFrom));
		if(str.length)
			[output appendAttributedString:[[NSAttributedString alloc] initWithString:str attributes:attrs]];
	};

	if(!scopes || scopes->empty() || !theme)
		return appendRun(from, to, nullptr);

	size_t pos = from;
	auto it = scopes->upper_bound(pos); // first run starting AFTER pos…
	if(it != scopes->begin())
		--it;                            // …so this is the run covering pos, if any

	while(pos < to)
	{
		scope::scope_t const* scope = nullptr;
		size_t runTo = to;
		if(it != scopes->end())
		{
			if(it->first <= pos)
			{
				scope = &it->second;
				auto next = std::next(it);
				runTo = next != scopes->end() ? std::min(next->first, to) : to;
				it = next;
			}
			else
			{
				runTo = std::min(it->first, to); // gap before the first known run
			}
		}
		appendRun(pos, runTo, scope);
		pos = runTo;
	}
}

// ================
// = Empty states =
// ================

- (diff_pane::empty_state)classifyEmptyStateForSnapshot:(BufferDiffSnapshot*)snapshot
{
	if(!snapshot)
		return diff_pane::empty_state::no_repository; // no data yet — quiet placeholder
	return diff_pane::classify_empty_state(
		snapshot.repoState != BufferDiffRepoStateNoRepository,
		snapshot.repoState == BufferDiffRepoStateTooLarge,
		snapshot.isTracked,
		![snapshot hunks].empty(),
		snapshot.isDocumentEdited,
		snapshot.hasStagedChanges,
		snapshot.isBaseHead);
}

- (std::string)emptyStateMessage:(diff_pane::empty_state)state forSnapshot:(BufferDiffSnapshot*)snapshot
{
	switch(state)
	{
		case diff_pane::empty_state::no_repository:      return "Not in a git repository.";
		case diff_pane::empty_state::too_large:          return "File is too large to diff.";
		case diff_pane::empty_state::untracked_empty:    return "Untracked file — not in git.";
		case diff_pane::empty_state::clean:              return "No uncommitted changes.";
		case diff_pane::empty_state::unsaved_only:       return "Buffer matches HEAD — not saved to disk yet (⌘S).";
		case diff_pane::empty_state::staged_only:        return "Buffer matches HEAD — staged changes remain in the index.";
		case diff_pane::empty_state::unsaved_and_staged: return "Buffer matches HEAD — not saved to disk yet (⌘S); staged changes remain in the index.";
		case diff_pane::empty_state::clean_vs_base:      return "Buffer matches " + to_s(ShortSHA(snapshot.baseRef)) + " — no changes against the review base.";
		default:                                         return "";
	}
}

// ==========
// = Header =
// ==========

- (void)updateHeader
{
	if(!_headerField)
		return;

	NSString* name = _document.displayName ?: @"";
	NSMutableString* title = [name mutableCopy];

	size_t const hunkCount = _cards.size();
	if(hunkCount > 0)
		[title appendFormat:@" — %zu %@", hunkCount, hunkCount == 1 ? @"hunk" : @"hunks"];

	// Status chips — the four-state divergence made visible instead of
	// lying by omission.
	if(_snapshot.isDocumentEdited)
		[title appendString:@" · Unsaved"];
	if(_snapshot.hasStagedChanges)
		[title appendString:@" · Staged"];

	_headerField.stringValue = title;
	_previousHunkButton.enabled = self.canSelectPreviousHunk;
	_nextHunkButton.enabled     = self.canSelectNextHunk;
	[self updateRevertControls];
	self.needsLayout = YES;
}

// Titles and enablement for every Revert control — the header bar's and
// each hunk band's. They are kept disabled rather than hidden on an
// untracked file: the pane still lists its one all-added hunk, and a
// control that quietly disappears on some files explains less than one
// that says, on hover, why it will not act.
- (void)updateRevertControls
{
	BOOL const enabled = [self canRevert];

	NSColor* const background = _themeBackgroundColor ?: NSColor.textBackgroundColor;
	NSColor* const foreground = _themeForegroundColor ?: NSColor.textColor;
	NSColor* titleColor = BlendedColor(foreground, background, 0.25);
	if(!enabled)
		titleColor = [titleColor colorWithAlphaComponent:0.5];

	NSString* const untrackedNote = @"This file is not in the base — reverting it would empty the buffer";

	_revertAllButton.hidden  = _cards.empty();
	_revertAllButton.enabled = enabled;
	_revertAllButton.toolTip = enabled ? @"Put every hunk in this file back, as one undoable edit" : untrackedNote;
	_revertAllButton.attributedTitle = [[NSAttributedString alloc] initWithString:[self revertTitleForAll:YES] attributes:@{
		NSFontAttributeName:            [NSFont systemFontOfSize:[NSFont systemFontSizeForControlSize:NSControlSizeSmall]],
		NSForegroundColorAttributeName: titleColor,
	}];

	NSString* const hunkTitle   = [self revertTitleForAll:NO];
	NSString* const hunkToolTip = enabled ? @"Put this hunk back the way the base has it; ⌘Z undoes it" : untrackedNote;
	for(DiffHunkView* hunk in _hunkViews)
		[hunk setRevertTitle:hunkTitle enabled:enabled toolTip:hunkToolTip];
}

// =========
// = Theme =
// =========

// Every setter re-renders: the dimmed colors are blends of foreground AND
// background, so a change to either must recolor the list (theme switches
// while the pane is open push both).
- (void)setThemeBackgroundColor:(NSColor*)aColor
{
	if(_themeBackgroundColor == aColor || [_themeBackgroundColor isEqual:aColor])
		return;
	_themeBackgroundColor = aColor;
	[self applyThemeColors];
	if(_active)
		[self renderNow];
}

- (void)setThemeForegroundColor:(NSColor*)aColor
{
	if(_themeForegroundColor == aColor || [_themeForegroundColor isEqual:aColor])
		return;
	_themeForegroundColor = aColor;
	[self applyThemeColors];
	if(_active)
		[self renderNow];
}

- (void)setGutterForegroundColor:(NSColor*)aColor
{
	if(_gutterForegroundColor == aColor || [_gutterForegroundColor isEqual:aColor])
		return;
	_gutterForegroundColor = aColor;
	if(_active)
		[self renderNow];
}

- (void)setGutterBackgroundColor:(NSColor*)aColor
{
	if(_gutterBackgroundColor == aColor || [_gutterBackgroundColor isEqual:aColor])
		return;
	_gutterBackgroundColor = aColor;
	if(_active)
		[self renderNow];
}

- (void)setGutterDividerColor:(NSColor*)aColor
{
	if(_gutterDividerColor == aColor || [_gutterDividerColor isEqual:aColor])
		return;
	_gutterDividerColor = aColor;
	if(_active)
		[self renderNow];
}

- (void)setLineNumberFont:(NSFont*)aFont
{
	if(_lineNumberFont == aFont || [_lineNumberFont isEqual:aFont])
		return;
	_lineNumberFont = aFont;
	if(_active)
		[self renderNow];
}

- (void)setEditorLineHeight:(CGFloat)aHeight
{
	if(_editorLineHeight == aHeight)
		return;
	_editorLineHeight = aHeight;
	if(_active)
		[self renderNow];
}

- (void)setTheme:(theme_ptr)aTheme
{
	if(_theme == aTheme)
		return;
	_theme = aTheme;
	_renderTheme = aTheme ? aTheme->copy_with_font_name_and_size(aTheme->font_name(), aTheme->font_size()) : theme_ptr();
	if(_active)
		[self renderNow];
}

- (parse::grammar_ptr)grammarForFileType:(NSString*)fileType
{
	if(!fileType)
		return parse::grammar_ptr();
	if(!_grammar || ![fileType isEqualToString:_grammarFileType])
	{
		_grammar = parse::grammar_ptr();
		_grammarFileType = fileType;
		for(auto const& item : bundles::query(bundles::kFieldGrammarScope, to_s(fileType), scope::wildcard, bundles::kItemTypeGrammar))
		{
			if((_grammar = parse::parse_grammar(item)))
				break;
		}
	}
	return _grammar;
}

- (void)applyThemeColors
{
	if(!_listScrollView)
		return;
	NSColor* background = _themeBackgroundColor ?: NSColor.textBackgroundColor;
	NSColor* foreground = _themeForegroundColor ?: NSColor.textColor;
	_listScrollView.backgroundColor = background;

	// The header/status line must stay readable on the theme background:
	// theme foreground, dimmed only slightly.
	_headerField.textColor               = BlendedColor(foreground, background, 0.25);
	_emptyStateField.textColor           = BlendedColor(foreground, background, 0.35);
	_closeButton.contentTintColor        = BlendedColor(foreground, background, 0.35);
	_previousHunkButton.contentTintColor = BlendedColor(foreground, background, 0.35);
	_nextHunkButton.contentTintColor     = BlendedColor(foreground, background, 0.35);
	_bannerField.textColor               = BlendedColor(foreground, background, 0.15);
	_bannerCloseButton.contentTintColor  = BlendedColor(foreground, background, 0.35);
	[self updateRevertControls]; // the Revert titles are attributed strings, so they carry their own colour

	// The bezeled controls render for the SYSTEM appearance, not the
	// editor theme — on a dark theme under a light system appearance the
	// pop-up label is dark-on-dark. Pin their NSAppearance to the theme's
	// brightness instead.
	NSColor* backgroundRGB = [background colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
	BOOL const isDarkTheme = backgroundRGB && (0.2126*backgroundRGB.redComponent + 0.7152*backgroundRGB.greenComponent + 0.0722*backgroundRGB.blueComponent) < 0.5;
	NSAppearance* appearance = [NSAppearance appearanceNamed:isDarkTheme ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua];
	_bannerActionButton.appearance = appearance;

	self.needsDisplay = YES; // the header strip background is drawn from these colors
}
@end
