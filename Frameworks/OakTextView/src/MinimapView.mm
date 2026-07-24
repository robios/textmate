#import "MinimapView.h"
#import "OakTextView.h"
#import <document/OakDocument.h>
#import <document/OakDocument Private.h>
#import <buffer/buffer.h>
#import <Preferences/Keys.h>
#import <algorithm>
#import <map>
#import <vector>

static CGFloat const kMinimapRowHeight        = 2; // 1 px content + 1 px gap
static CGFloat const kMinimapRowContentHeight = 1;
static CGFloat const kMinimapColumnWidth      = 1;
static size_t const kMinimapMaxColumns        = 110;
static CGFloat const kMinimapDiffStripWidth   = 2;
static CGFloat const kMinimapContentInset     = kMinimapDiffStripWidth + 2; // reserved lane for diff strips; content never enters it

@interface MinimapView ()
- (void)bufferWillReplaceFrom:(size_t)from to:(size_t)to;
- (void)bufferDidReplaceFrom:(size_t)from to:(size_t)to length:(size_t)len;
- (void)bufferDidParseFrom:(size_t)from to:(size_t)to;
@end

namespace
{
	// One row of the minimap: indentation plus [begin, end) column ranges of
	// non-whitespace runs, each with the foreground color of its scope (NULL
	// until parsed, or without a theme — drawn as uniform gray). Columns are
	// tab-expanded and clamped to kMinimapMaxColumns.
	struct minimap_segment_t
	{
		uint16_t begin, end;
		CGColorRef color; // owned by the theme’s style cache — valid while the theme is retained
	};

	struct minimap_line_t
	{
		uint16_t indent = 0;
		std::vector<minimap_segment_t> segments;
	};

	minimap_line_t scan_line (ng::buffer_t const& buffer, size_t lineNumber, size_t tabSize, theme_t const* theme)
	{
		minimap_line_t res;
		size_t const bol = buffer.begin(lineNumber);
		std::string const line = buffer.substr(bol, buffer.eol(lineNumber));

		std::map<size_t, scope::scope_t> scopes; // keys relative to bol
		if(theme && !line.empty())
			scopes = buffer.scopes(bol, bol + line.size());

		auto scopeIter = scopes.begin();
		CGColorRef currentColor = NULL;
		auto colorAt = [&](size_t i) -> CGColorRef {
			while(scopeIter != scopes.end() && scopeIter->first <= i)
			{
				currentColor = theme && scopeIter->second ? theme->styles_for_scope(scopeIter->second).foreground() : NULL;
				++scopeIter;
			}
			return currentColor;
		};

		size_t column = 0, segmentBegin = 0;
		bool inSegment = false;
		CGColorRef segmentColor = NULL;

		for(size_t i = 0; i < line.size() && column < kMinimapMaxColumns; ++i)
		{
			char const ch = line[i];
			if((ch & 0xC0) == 0x80) // UTF-8 continuation byte — count code points, not bytes
				continue;

			if(ch == ' ' || ch == '\t')
			{
				if(inSegment)
				{
					res.segments.push_back({ (uint16_t)segmentBegin, (uint16_t)column, segmentColor });
					inSegment = false;
				}
				column = ch == '\t' ? (column / tabSize + 1) * tabSize : column + 1;
			}
			else
			{
				CGColorRef const color = colorAt(i);
				if(!inSegment)
				{
					if(res.segments.empty())
						res.indent = column;
					segmentBegin = column;
					segmentColor = color;
					inSegment = true;
				}
				else if(color != segmentColor) // scope boundary inside a run — split
				{
					res.segments.push_back({ (uint16_t)segmentBegin, (uint16_t)column, segmentColor });
					segmentBegin = column;
					segmentColor = color;
				}
				++column;
			}
		}

		if(inSegment)
			res.segments.push_back({ (uint16_t)segmentBegin, (uint16_t)column, segmentColor });
		return res;
	}

	struct buffer_callback_t : ng::callback_t
	{
		buffer_callback_t (MinimapView* view) : _view(view) { }

		void will_replace (size_t from, size_t to, char const* buf, size_t len) override { [_view bufferWillReplaceFrom:from to:to]; }
		void did_replace (size_t from, size_t to, char const* buf, size_t len) override  { [_view bufferDidReplaceFrom:from to:to length:len]; }
		void did_parse (size_t from, size_t to) override                                 { [_view bufferDidParseFrom:from to:to]; }

	private:
		__weak MinimapView* _view;
	};
}

// The minimap lives inside its own scroller-less NSScrollView — the same
// structure as the gutter. Rows are drawn at absolute positions; following
// the text view means scrolling our own clip view, never repositioning
// content inside drawRect:. (A plain sibling view that redraws while the
// huge text view scrolls leaves the text view’s tiled backing layer blank.)
@implementation MinimapView
{
	std::vector<minimap_line_t> _lines;
	std::unique_ptr<buffer_callback_t> _bufferCallback;
	ng::buffer_t* _attachedBuffer;
	size_t _pendingFirstLine;
	size_t _pendingOldSpan;
	NSRect _lastIndicatorRect;
	__weak NSClipView* _observedClipView;
	BOOL _draggingIndicator;
	CGFloat _grabOffsetInIndicator;
	BOOL _useThemeColors;
	enum class diff_mark : uint8_t { added, modified, deleted };
	std::map<size_t, diff_mark> _diffMarks; // keyed by line
}

// The theme is only consulted while colors are enabled.
- (theme_t const*)effectiveTheme
{
	return _useThemeColors ? _theme.get() : nullptr;
}

- (id)initWithFrame:(NSRect)aRect
{
	if(self = [super initWithFrame:aRect])
	{
		_caretLine      = NSNotFound;
		_useThemeColors = ![NSUserDefaults.standardUserDefaults boolForKey:kUserDefaultsDisableMinimapColorsKey];
		[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(userDefaultsDidChange:) name:NSUserDefaultsDidChangeNotification object:nil];
	}
	return self;
}

- (void)userDefaultsDidChange:(NSNotification*)aNotification
{
	BOOL const useThemeColors = ![NSUserDefaults.standardUserDefaults boolForKey:kUserDefaultsDisableMinimapColorsKey];
	if(useThemeColors != _useThemeColors)
	{
		_useThemeColors = useThemeColors;
		[self reloadMetrics];
	}
}

- (void)dealloc
{
	[NSNotificationCenter.defaultCenter removeObserver:self];
	[self detachBuffer];
}

- (BOOL)isFlipped
{
	return YES;
}

- (void)setCaretColor:(NSColor*)aColor
{
	_caretColor = aColor;
	self.needsDisplay = YES;
}

- (void)setCaretLine:(NSUInteger)aLine
{
	if(_caretLine == aLine)
		return;

	NSUInteger const oldLine = _caretLine;
	_caretLine = aLine;

	for(NSUInteger line : { oldLine, aLine })
	{
		if(line != NSNotFound)
			[self setNeedsDisplayInRect:NSMakeRect(0, line * kMinimapRowHeight, NSWidth(self.bounds), kMinimapRowHeight)];
	}
}

- (void)viewDidMoveToSuperview
{
	[super viewDidMoveToSuperview];

	// Track our own clip view’s size: when the minimap is toggled visible its
	// scroll view grows from zero width, and window resizes change our height —
	// neither is reported through the text view’s notifications.
	if(_observedClipView)
		[NSNotificationCenter.defaultCenter removeObserver:self name:NSViewFrameDidChangeNotification object:_observedClipView];
	_observedClipView = nil;

	NSClipView* clipView = (NSClipView*)self.superview;
	if([clipView isKindOfClass:[NSClipView class]])
	{
		clipView.postsFrameChangedNotifications = YES;
		[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(clipViewFrameDidChange:) name:NSViewFrameDidChangeNotification object:clipView];
		_observedClipView = clipView;
	}

	[self updateFrameSize];
}

- (void)clipViewFrameDidChange:(NSNotification*)aNotification
{
	[self updateFrameSize];
	[self synchronizeScrollPosition];
	self.needsDisplay = YES;
}

// =====================
// = Partner text view =
// =====================

- (void)setTextView:(OakTextView*)aTextView
{
	if(_textView == aTextView)
		return;

	if(_textView)
	{
		[NSNotificationCenter.defaultCenter removeObserver:self name:NSViewBoundsDidChangeNotification object:[[_textView enclosingScrollView] contentView]];
		[NSNotificationCenter.defaultCenter removeObserver:self name:NSViewFrameDidChangeNotification object:_textView];
	}

	if(_textView = aTextView)
	{
		[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(textViewGeometryDidChange:) name:NSViewBoundsDidChangeNotification object:[[_textView enclosingScrollView] contentView]];
		[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(textViewGeometryDidChange:) name:NSViewFrameDidChangeNotification object:_textView];
	}
}

- (void)textViewGeometryDidChange:(NSNotification*)aNotification
{
	[self updateFrameSize];
	[self synchronizeScrollPosition];
}

- (void)setBackgroundColor:(NSColor*)aColor
{
	_backgroundColor = aColor;
	self.needsDisplay = YES;
}

- (void)setTheme:(theme_ptr)aTheme
{
	if(_theme == aTheme)
		return;
	_theme = aTheme;
	[self reloadMetrics]; // segment colors are resolved against the theme during scanning
}

// ============
// = Geometry =
// ============

- (CGFloat)contentHeight
{
	return _lines.size() * kMinimapRowHeight;
}

- (void)updateFrameSize
{
	NSClipView* clipView = (NSClipView*)self.superview;
	if(![clipView isKindOfClass:[NSClipView class]])
		return;

	NSSize desired = NSMakeSize(NSWidth(clipView.bounds), std::max<CGFloat>([self contentHeight], NSHeight(clipView.bounds)));
	if(!NSEqualSizes(self.frame.size, desired))
		[self setFrameSize:desired];
}

// When the document is taller than the minimap, follow the text view by
// scrolling our own clip view proportionally (gutter-style synchronization).
- (void)synchronizeScrollPosition
{
	NSScrollView* scrollView = self.enclosingScrollView;
	NSClipView* clipView     = scrollView.contentView;
	if(!clipView || !_textView)
		return;

	CGFloat const viewHeight    = NSHeight(clipView.bounds);
	CGFloat const contentHeight = [self contentHeight];

	CGFloat offset = 0;
	if(contentHeight > viewHeight)
	{
		NSClipView* textClipView = [[_textView enclosingScrollView] contentView];
		CGFloat const maxScroll  = NSHeight(_textView.frame) - NSHeight(textClipView.bounds);
		CGFloat const fraction   = maxScroll > 0 ? std::clamp<CGFloat>(NSMinY(textClipView.bounds) / maxScroll, 0, 1) : 0;
		offset = round(fraction * (contentHeight - viewHeight));
	}

	if(NSMinY(clipView.bounds) != offset)
	{
		[clipView scrollToPoint:NSMakePoint(0, offset)];
		[scrollView reflectScrolledClipView:clipView];
	}

	// The viewport indicator moves even when the map itself does not scroll.
	[self setNeedsDisplayInRect:_lastIndicatorRect];
	[self setNeedsDisplayInRect:[self viewportIndicatorRect]];
}

- (NSRect)viewportIndicatorRect
{
	if(_lines.empty() || !_textView)
		return NSZeroRect;

	NSClipView* textClipView = [[_textView enclosingScrollView] contentView];
	GVLineRecord const firstRecord = [_textView lineRecordForPosition:NSMinY(textClipView.bounds)];
	GVLineRecord const lastRecord  = [_textView lineRecordForPosition:NSMaxY(textClipView.bounds)];

	NSUInteger const firstLine = firstRecord.lineNumber != NSNotFound ? firstRecord.lineNumber : 0;
	NSUInteger const lastLine  = lastRecord.lineNumber != NSNotFound ? lastRecord.lineNumber : _lines.size()-1;

	return NSMakeRect(0, firstLine * kMinimapRowHeight, NSWidth(self.bounds), (lastLine + 1 - firstLine) * kMinimapRowHeight);
}

// ================
// = Line metrics =
// ================

- (void)setDocument:(OakDocument*)aDocument
{
	if(_document == aDocument)
		return;

	[self detachBuffer];
	_document = aDocument;
	[self attachBuffer];
}

- (void)attachBuffer
{
	if(_attachedBuffer || !_document || !_document.isLoaded)
		return;

	_attachedBuffer = &[_document buffer];
	_bufferCallback = std::make_unique<buffer_callback_t>(self);
	_attachedBuffer->add_callback(_bufferCallback.get());
	[self reloadMetrics];
}

- (void)detachBuffer
{
	if(_attachedBuffer && _bufferCallback)
		_attachedBuffer->remove_callback(_bufferCallback.get());
	_attachedBuffer = nullptr;
	_bufferCallback.reset();
	_lines.clear();
	_diffMarks.clear();
	self.needsDisplay = YES;
}

// SCM diff status lives in buffer marks, maintained by OakTextView’s
// gutter-diff pipeline; mirror them for the strip at the minimap’s left edge.
- (void)documentMarksDidChange
{
	_diffMarks.clear();
	if(_attachedBuffer)
	{
		static struct { char const* type; diff_mark mark; } const kinds[] = {
			{ "diff.added",    diff_mark::added    },
			{ "diff.modified", diff_mark::modified },
			{ "diff.deleted",  diff_mark::deleted  },
		};
		for(auto const& kind : kinds)
		{
			for(auto const& pair : _attachedBuffer->get_marks(0, _attachedBuffer->size(), kind.type))
				_diffMarks[_attachedBuffer->convert(pair.first).line] = kind.mark;
		}
	}
	self.needsDisplay = YES;
}

- (void)documentContentDidChange
{
	// Posted for every edit: incremental updates are handled by the buffer
	// callback, so only re-attach when the document (re)created its buffer,
	// e.g. after loading finished or a revert.
	if(!_document || !_document.isLoaded)
		return;
	if(_attachedBuffer == &[_document buffer])
		return;

	[self detachBuffer];
	[self attachBuffer];
}

- (void)reloadMetrics
{
	_lines.clear();
	if(_attachedBuffer)
	{
		size_t const tabSize = std::max<size_t>(1, _document.tabSize);
		_lines.reserve(_attachedBuffer->lines());
		for(size_t n = 0; n < _attachedBuffer->lines(); ++n)
			_lines.push_back(scan_line(*_attachedBuffer, n, tabSize, [self effectiveTheme]));
	}
	[self updateFrameSize];
	[self synchronizeScrollPosition];
	[self documentMarksDidChange]; // pick up any diff marks already on the buffer
}

- (void)bufferWillReplaceFrom:(size_t)from to:(size_t)to
{
	if(!_attachedBuffer)
		return;
	_pendingFirstLine = _attachedBuffer->convert(from).line;
	_pendingOldSpan   = _attachedBuffer->convert(to).line - _pendingFirstLine;
}

- (void)bufferDidReplaceFrom:(size_t)from to:(size_t)to length:(size_t)len
{
	if(!_attachedBuffer)
		return;

	ng::buffer_t const& buffer = *_attachedBuffer;
	size_t const firstLine = buffer.convert(from).line;
	size_t const newSpan   = buffer.convert(from + len).line - firstLine;
	size_t const tabSize   = std::max<size_t>(1, _document.tabSize);

	if(firstLine != _pendingFirstLine || firstLine + _pendingOldSpan >= _lines.size())
		return [self reloadMetrics]; // cache out of sync — rebuild

	std::vector<minimap_line_t> replacement;
	replacement.reserve(newSpan + 1);
	for(size_t n = firstLine; n <= firstLine + newSpan; ++n)
		replacement.push_back(scan_line(buffer, n, tabSize, [self effectiveTheme]));

	auto first = _lines.begin() + firstLine;
	_lines.erase(first, first + _pendingOldSpan + 1);
	_lines.insert(_lines.begin() + firstLine, std::make_move_iterator(replacement.begin()), std::make_move_iterator(replacement.end()));

	if(_pendingOldSpan == newSpan)
	{
		[self setNeedsDisplayInRect:NSMakeRect(0, firstLine * kMinimapRowHeight, NSWidth(self.bounds), (newSpan + 1) * kMinimapRowHeight)];
	}
	else
	{
		[self updateFrameSize];
		[self synchronizeScrollPosition];
		self.needsDisplay = YES;
	}
}

// Fires as the asynchronous parser progresses; recolor the affected lines so
// the minimap colorizes incrementally, the same way the editor view does.
- (void)bufferDidParseFrom:(size_t)from to:(size_t)to
{
	if(!_attachedBuffer || ![self effectiveTheme] || _lines.empty())
		return;

	ng::buffer_t const& buffer = *_attachedBuffer;
	size_t const firstLine = buffer.convert(from).line;
	size_t const lastLine  = std::min<size_t>(buffer.convert(to).line, _lines.size()-1);
	if(firstLine >= _lines.size())
		return;

	size_t const tabSize = std::max<size_t>(1, _document.tabSize);
	for(size_t n = firstLine; n <= lastLine && n < buffer.lines(); ++n)
		_lines[n] = scan_line(buffer, n, tabSize, [self effectiveTheme]);

	[self setNeedsDisplayInRect:NSMakeRect(0, firstLine * kMinimapRowHeight, NSWidth(self.bounds), (lastLine + 1 - firstLine) * kMinimapRowHeight)];
}

// ===========
// = Drawing =
// ===========

- (void)drawRect:(NSRect)aRect
{
	if(NSColor* background = self.backgroundColor)
	{
		[background set];
		NSRectFill(aRect);
	}

	if(_lines.empty() || !_textView)
		return;

	size_t const firstRow = std::max<CGFloat>(0, floor(NSMinY(aRect) / kMinimapRowHeight));
	size_t const lastRow  = std::min<size_t>(_lines.size()-1, ceil(NSMaxY(aRect) / kMinimapRowHeight));

	CGFloat const maxX = NSWidth(self.bounds);

	// SCM diff decorations, VS Code palette: a translucent full-width tint
	// underneath the code blocks plus a crisp strip at the left edge.
	// Deletions sit between the marked line and the next, so their wedge
	// straddles the row’s bottom boundary and is a bit wider to stand out.
	std::vector<CGRect> addedRects, modifiedRects, deletedRects;
	for(auto it = _diffMarks.lower_bound(firstRow); it != _diffMarks.end() && it->first <= lastRow; ++it)
	{
		switch(it->second)
		{
			case diff_mark::added:    addedRects.push_back(CGRectMake(0, it->first * kMinimapRowHeight, kMinimapDiffStripWidth, kMinimapRowHeight));    break;
			case diff_mark::modified: modifiedRects.push_back(CGRectMake(0, it->first * kMinimapRowHeight, kMinimapDiffStripWidth, kMinimapRowHeight)); break;
			case diff_mark::deleted:  deletedRects.push_back(CGRectMake(0, (it->first + 1) * kMinimapRowHeight - 1, kMinimapDiffStripWidth, 2));        break;
		}
	}

	CGFloat backgroundBrightness = 0.5;
	if(NSColor* background = [self.backgroundColor colorUsingColorSpace:NSColorSpace.genericRGBColorSpace])
		backgroundBrightness = background.brightnessComponent;
	BOOL const isDarkBackground = backgroundBrightness <= 0.5;

	// Brighter variants on dark themes, VS Code-like darker ones on light.
	struct { std::vector<CGRect> const& rects; CGFloat red, green, blue; } const diffPasses[] = {
		{ addedRects,    isDarkBackground ? 0.45 : 0.28, isDarkBackground ? 0.80 : 0.49, isDarkBackground ? 0.15 : 0.01 }, // #73CC26 / #487E02
		{ modifiedRects, isDarkBackground ? 0.20 : 0.11, isDarkBackground ? 0.67 : 0.51, isDarkBackground ? 0.86 : 0.66 }, // #33ABDB / #1B81A8
		{ deletedRects,  isDarkBackground ? 1.00 : 0.95, isDarkBackground ? 0.36 : 0.30, isDarkBackground ? 0.36 : 0.30 }, // #FF5C5C / #F14C4C
	};

	CGContextRef context = NSGraphicsContext.currentContext.CGContext;
	for(auto const& pass : diffPasses)
	{
		if(pass.rects.empty() || &pass.rects == &deletedRects) // no line left to tint for deletions
			continue;
		std::vector<CGRect> tintRects;
		tintRects.reserve(pass.rects.size());
		for(CGRect const& rect : pass.rects)
			tintRects.push_back(CGRectMake(0, rect.origin.y, maxX, rect.size.height));
		CGContextSetFillColorWithColor(context, [NSColor colorWithSRGBRed:pass.red green:pass.green blue:pass.blue alpha:0.25].CGColor);
		CGContextFillRects(context, tintRects.data(), tintRects.size());
	}

	std::map<CGColorRef, std::vector<CGRect>> rectsByColor; // NULL key → fallback gray
	for(size_t row = firstRow; row <= lastRow; ++row)
	{
		CGFloat const y = row * kMinimapRowHeight;
		for(auto const& segment : _lines[row].segments)
		{
			CGFloat const x = kMinimapContentInset + segment.begin * kMinimapColumnWidth;
			if(x >= maxX)
				break;
			CGFloat const w = std::min<CGFloat>((segment.end - segment.begin) * kMinimapColumnWidth, maxX - x);
			rectsByColor[segment.color].push_back(CGRectMake(x, y, w, kMinimapRowContentHeight));
		}
	}

	// Not-yet-parsed (or theme-less) segments fall back to a mid-gray with
	// alpha which reads acceptably on both light and dark backgrounds.
	NSColor* fallbackColor = [NSColor colorWithCalibratedWhite:0.5 alpha:0.6];
	CGContextSaveGState(context);
	CGContextSetAlpha(context, 0.85); // soften theme colors, akin to scaled-down text
	for(auto const& pair : rectsByColor)
	{
		CGContextSetFillColorWithColor(context, pair.first ?: fallbackColor.CGColor);
		CGContextFillRects(context, pair.second.data(), pair.second.size());
	}
	CGContextRestoreGState(context);

	// Crisp diff strips/wedges on top of everything else.
	for(auto const& pass : diffPasses)
	{
		if(pass.rects.empty())
			continue;
		CGContextSetFillColorWithColor(context, [NSColor colorWithSRGBRed:pass.red green:pass.green blue:pass.blue alpha:1].CGColor);
		CGContextFillRects(context, pass.rects.data(), pass.rects.size());
	}

	NSRect indicatorRect = NSIntersectionRect([self viewportIndicatorRect], self.bounds);
	_lastIndicatorRect = indicatorRect;
	if(!NSIsEmptyRect(indicatorRect))
	{
		CGFloat brightness = 0.5;
		if(NSColor* background = [self.backgroundColor colorUsingColorSpace:NSColorSpace.genericRGBColorSpace])
			brightness = background.brightnessComponent;

		NSColor* indicatorColor = brightness > 0.5 ? [NSColor colorWithCalibratedWhite:0 alpha:0.10] : [NSColor colorWithCalibratedWhite:1 alpha:0.12];
		CGContextSetFillColorWithColor(context, indicatorColor.CGColor);
		CGContextFillRect(context, NSRectToCGRect(indicatorRect));
	}

	// Caret marker: a thin line at the caret’s row in the theme’s caret color,
	// akin to the cursor decoration in VS Code’s overview ruler.
	if(_caretLine != NSNotFound && _caretLine < _lines.size() && self.caretColor)
	{
		NSRect caretRect = NSIntersectionRect(NSMakeRect(0, _caretLine * kMinimapRowHeight, NSWidth(self.bounds), kMinimapRowContentHeight), self.bounds);
		if(!NSIsEmptyRect(caretRect))
		{
			CGContextSetFillColorWithColor(context, [self.caretColor colorWithAlphaComponent:0.9].CGColor);
			CGContextFillRect(context, NSRectToCGRect(caretRect));
		}
	}
}

// ===============
// = Interaction =
// ===============

- (void)mouseDown:(NSEvent*)anEvent
{
	NSPoint const p = [self convertPoint:anEvent.locationInWindow fromView:nil];
	NSRect indicatorRect = [self viewportIndicatorRect];
	if(!NSPointInRect(p, indicatorRect))
	{
		[self scrollToLineAtPoint:p];
		indicatorRect = [self viewportIndicatorRect];
	}

	// Grab the viewport indicator (scrollbar-thumb style): dragging moves the
	// view relative to the grab point instead of jumping.
	_draggingIndicator     = YES;
	_grabOffsetInIndicator = std::clamp<CGFloat>(p.y - NSMinY(indicatorRect), 0, NSHeight(indicatorRect));
}

- (void)mouseDragged:(NSEvent*)anEvent
{
	NSPoint const p = [self convertPoint:anEvent.locationInWindow fromView:nil];
	if(_draggingIndicator)
			[self dragIndicatorToPoint:p];
	else	[self scrollToLineAtPoint:p];
}

- (void)mouseUp:(NSEvent*)anEvent
{
	_draggingIndicator = NO;
}

- (void)dragIndicatorToPoint:(NSPoint)aPoint
{
	if(_lines.empty() || !_textView)
		return;

	NSScrollView* textScrollView = [_textView enclosingScrollView];
	NSClipView* textClipView     = textScrollView.contentView;
	CGFloat const maxScroll      = std::max<CGFloat>(0, NSHeight(_textView.frame) - NSHeight(textClipView.bounds));
	if(maxScroll == 0)
		return;

	NSClipView* ownClipView       = self.enclosingScrollView.contentView;
	CGFloat const stripHeight     = std::min<CGFloat>([self contentHeight], NSHeight(ownClipView.bounds));
	CGFloat const indicatorHeight = NSHeight([self viewportIndicatorRect]);

	// Desired indicator top (clip-relative) → scroll fraction: the indicator’s
	// top travels [0, stripHeight − indicatorHeight] as the text view scrolls
	// [0, maxScroll], in both the top-aligned and the scroll-linked mapping.
	CGFloat const thumbTop = (aPoint.y - NSMinY(ownClipView.bounds)) - _grabOffsetInIndicator;
	CGFloat const fraction = std::clamp<CGFloat>(thumbTop / std::max<CGFloat>(1, stripHeight - indicatorHeight), 0, 1);

	[textClipView scrollToPoint:NSMakePoint(NSMinX(textClipView.bounds), round(fraction * maxScroll))];
	[textScrollView reflectScrolledClipView:textClipView];
}

- (void)scrollToLineAtPoint:(NSPoint)aPoint
{
	if(_lines.empty() || !_textView)
		return;

	// Jump to the line rendered under the cursor — what you see is what you
	// get. Long-distance travel is covered by grabbing the viewport highlight,
	// whose drag range spans the entire document.
	NSInteger row = floor(aPoint.y / kMinimapRowHeight);
	row = std::clamp<NSInteger>(row, 0, (NSInteger)_lines.size()-1);

	GVLineRecord const record = [_textView lineFragmentForLine:row column:0];
	if(record.lineNumber == NSNotFound)
		return;

	NSScrollView* scrollView    = [_textView enclosingScrollView];
	NSClipView* clipView        = scrollView.contentView;
	CGFloat const visibleHeight = NSHeight(clipView.bounds);
	CGFloat const maxScroll     = std::max<CGFloat>(0, NSHeight(_textView.frame) - visibleHeight);
	CGFloat const targetY       = std::clamp<CGFloat>((record.firstY + record.lastY - visibleHeight) / 2, 0, maxScroll);

	[clipView scrollToPoint:NSMakePoint(NSMinX(clipView.bounds), round(targetY))];
	[scrollView reflectScrolledClipView:clipView];
}

- (void)scrollWheel:(NSEvent*)anEvent
{
	[_textView scrollWheel:anEvent];
}
@end
