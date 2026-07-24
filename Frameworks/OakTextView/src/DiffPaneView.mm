#import "DiffPaneView.h"
#import <document/OakDocument.h>
#import <scm/text_diff.h>
#import <text/newlines.h>
#import <text/utf16.h>
#import <parse/parse.h>
#import <parse/grammar.h>
#import <bundles/bundles.h>
#import <ns/ns.h>
#import <atomic>

static CGFloat const kDiffPaneHeaderHeight = 24;

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

// The pane’s content view: non-editable, but it can be first responder (text
// is selectable for copying) — Space must keep toggling the view mode there
// too, Quick Look style.
@interface DiffPaneTextView : NSTextView
@property (nonatomic, weak) DiffPaneView* pane;
@end

@implementation DiffPaneTextView
- (void)keyDown:(NSEvent*)anEvent
{
	// Space toggles the view mode — but not mid-IME-composition, where a
	// space is part of the composition (same guard as OakTextView's gate).
	if([anEvent.charactersIgnoringModifiers isEqualToString:@" "] && !self.hasMarkedText && !(anEvent.modifierFlags & (NSEventModifierFlagCommand|NSEventModifierFlagControl|NSEventModifierFlagOption)))
		return [self.pane toggleViewMode];
	[super keyDown:anEvent];
}
@end

@implementation DiffPaneView
{
	NSTextField*        _headerField;
	NSButton*           _closeButton;
	NSSegmentedControl* _modeControl;
	NSScrollView*       _diffScrollView;
	DiffPaneTextView*   _diffTextView;

	std::string _baseline;   // on-disk contents of _document.path, LF-normalized
	BOOL _baselineValid;

	// theme_t::styles_for_scope caches without locking, so the layout’s
	// instance must stay main-thread-only; renders use this pane-private
	// copy, captured on the main thread and only dereferenced on the
	// (serial) render queue.
	theme_ptr _renderTheme;

	parse::grammar_ptr _grammar; // resolved on the main thread, keyed by _grammarFileType
	NSString* _grammarFileType;

	std::atomic<NSUInteger> _generation; // atomic: render blocks read it off-main to skip superseded work
	dispatch_queue_t _renderQueue;
}

- (id)initWithFrame:(NSRect)aRect
{
	if(self = [super initWithFrame:aRect])
		_renderQueue = dispatch_queue_create("com.macromates.diff-pane.render", DISPATCH_QUEUE_SERIAL);
	return self;
}

// Like the gutter, minimap and markdown preview, the pane lives inside a
// scroller-less NSScrollView: a plain sibling that redraws next to
// OakTextView leaves the text view’s giant tiled backing layer blank. The
// wrapper never scrolls; we keep our frame matched to its clip view and put
// a real (scrolling) text view inside.
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

// The scroll view covers everything below the header, but the header strip
// itself is bare view: without this the window background shows through —
// under a light system appearance with a dark editor theme that meant a
// white strip with appearance-pinned (dark) controls on it. Paint the theme
// background and a hairline separator instead.
- (void)drawRect:(NSRect)aRect
{
	NSColor* background = _themeBackgroundColor ?: NSColor.textBackgroundColor;
	NSColor* foreground = _themeForegroundColor ?: NSColor.textColor;

	[background set];
	NSRectFill(aRect);

	NSRect headerRect, contentRect;
	NSDivideRect(self.bounds, &headerRect, &contentRect, kDiffPaneHeaderHeight, NSMaxYEdge);
	[BlendedColor(foreground, background, 0.85) set];
	NSRectFill(NSMakeRect(NSMinX(headerRect), NSMinY(headerRect), NSWidth(headerRect), 1)); // bottom-most header row — the scroll view covers everything below
}

- (void)layout
{
	[super layout];
	NSRect bounds = self.bounds;
	NSRect headerRect, contentRect;
	NSDivideRect(bounds, &headerRect, &contentRect, kDiffPaneHeaderHeight, NSMaxYEdge);
	self.needsDisplay = YES; // header background + separator are drawn by us

	// Header line: close ⋅ title … [Diff|Applied]. 8 pt edge margins (matching
	// the content’s effective text inset), 10 pt between groups. All
	// horizontal math uses alignment rects — rounded bezels carry invisible
	// frame padding, so frame-based gaps render wider than specified and
	// visually uneven.
	CGFloat const edgeMargin = 8;
	CGFloat const sectionGap = 10;

	auto alignmentSize = [](NSControl* control) -> NSSize {
		[control sizeToFit];
		return [control alignmentRectForFrame:(NSRect){ NSZeroPoint, control.frame.size }].size;
	};

	// Place a control with its alignment rect’s left edge at x, vertically
	// centered in the header; returns the alignment rect used.
	auto place = [&headerRect](NSControl* control, CGFloat x, NSSize size) -> NSRect {
		NSRect alignmentRect = NSMakeRect(x, NSMinY(headerRect) + round((NSHeight(headerRect) - size.height) / 2), size.width, size.height);
		control.frame = [control frameForAlignmentRect:alignmentRect];
		return alignmentRect;
	};

	CGFloat x = NSMinX(headerRect) + edgeMargin;
	NSRect const closeRect = place(_closeButton, x, NSMakeSize(16, 16));
	x = NSMaxX(closeRect) + sectionGap;

	NSSize const modeSize = alignmentSize(_modeControl);
	NSRect const modeRect = place(_modeControl, NSMaxX(headerRect) - edgeMargin - modeSize.width, modeSize);

	// Title fills the gap between the close button and the segmented control,
	// baseline-aligned with the segment labels (frames are in non-flipped
	// superview coordinates, so the baseline sits offset below NSMaxY).
	[_headerField sizeToFit];
	CGFloat const controlBaseline = NSMaxY([_modeControl alignmentRectForFrame:_modeControl.frame]) - _modeControl.firstBaselineOffsetFromTop;
	CGFloat const fieldHeight     = NSHeight(_headerField.frame);
	CGFloat const fieldY          = controlBaseline + _headerField.firstBaselineOffsetFromTop - fieldHeight;
	_headerField.frame = NSMakeRect(x, fieldY, std::max<CGFloat>(0, NSMinX(modeRect) - sectionGap - x), fieldHeight);

	_diffScrollView.frame = contentRect;
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
		_baselineValid = NO;
		[self renderNow];
	}
	else
	{
		++_generation; // orphan any in-flight render

		[_diffScrollView removeFromSuperview];
		[_headerField removeFromSuperview];
		[_closeButton removeFromSuperview];
		[_modeControl removeFromSuperview];
		_diffScrollView = nil;
		_diffTextView   = nil;
		_headerField    = nil;
		_closeButton    = nil;
		_modeControl    = nil;
		_baselineValid  = NO; // _baseline itself is only touched on _renderQueue
	}
}

- (void)createSubviewsIfNeeded
{
	if(_diffScrollView)
		return;

	_closeButton = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"xmark.circle.fill" accessibilityDescription:@"Close Diff Pane"] target:self action:@selector(didClickClose:)];
	_closeButton.bordered = NO;
	_closeButton.toolTip  = @"Close diff pane";

	_modeControl = [NSSegmentedControl segmentedControlWithLabels:@[ @"Diff", @"Applied" ] trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(didChangeViewMode:)];
	_modeControl.controlSize     = NSControlSizeSmall;
	_modeControl.font            = [NSFont systemFontOfSize:[NSFont systemFontSizeForControlSize:NSControlSizeSmall]];
	_modeControl.selectedSegment = _viewMode == DiffPaneViewModeApplied ? 1 : 0;
	_modeControl.toolTip         = @"Toggle between unified diff and the full file contents (Space)";

	_headerField = [[NSTextField alloc] initWithFrame:NSZeroRect];
	_headerField.bordered        = NO;
	_headerField.editable        = NO;
	_headerField.selectable      = NO;
	_headerField.bezeled         = NO;
	_headerField.drawsBackground = NO;
	_headerField.font            = [NSFont systemFontOfSize:[NSFont systemFontSizeForControlSize:NSControlSizeSmall]];
	[[_headerField cell] setLineBreakMode:NSLineBreakByTruncatingMiddle]; // long file names keep their extension visible, like the status-bar fields

	// Explicit TextKit 1 stack: a plain -initWithFrame: text view is TextKit 2,
	// whose viewport-based layout makes sizeToFit under-report the width of
	// long lines — the horizontal scroller then stops short of the right
	// edge. TextKit 1 + ensureLayout gives the exact content size.
	NSTextStorage* textStorage     = [NSTextStorage new];
	NSLayoutManager* layoutManager = [NSLayoutManager new];
	[textStorage addLayoutManager:layoutManager];
	NSTextContainer* textContainer = [[NSTextContainer alloc] initWithContainerSize:NSMakeSize(FLT_MAX, FLT_MAX)];
	textContainer.widthTracksTextView = NO;
	[layoutManager addTextContainer:textContainer];

	_diffTextView = [[DiffPaneTextView alloc] initWithFrame:NSZeroRect textContainer:textContainer];
	_diffTextView.pane       = self;
	_diffTextView.editable   = NO;
	_diffTextView.richText   = NO;
	_diffTextView.usesFontPanel = NO;
	_diffTextView.horizontallyResizable = YES;
	_diffTextView.verticallyResizable   = YES;
	_diffTextView.maxSize    = NSMakeSize(FLT_MAX, FLT_MAX);
	_diffTextView.textContainerInset = NSMakeSize(4, 6);
	_diffTextView.autoresizingMask = NSViewNotSizable;

	_diffScrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
	_diffScrollView.borderType            = NSNoBorder;
	_diffScrollView.hasVerticalScroller   = YES;
	_diffScrollView.hasHorizontalScroller = YES;
	_diffScrollView.autohidesScrollers    = YES;
	_diffScrollView.drawsBackground       = YES;
	_diffScrollView.documentView          = _diffTextView;

	[self addSubview:_diffScrollView];
	[self addSubview:_headerField];
	[self addSubview:_closeButton];
	[self addSubview:_modeControl];

	[self applyThemeColors];
	[self updateHeader];
	self.needsLayout = YES;
}

- (void)didClickClose:(id)sender
{
	if(self.closeHandler)
		self.closeHandler();
}

// =============
// = View mode =
// =============

- (void)didChangeViewMode:(id)sender
{
	self.viewMode = _modeControl.selectedSegment == 1 ? DiffPaneViewModeApplied : DiffPaneViewModeUnified;
}

- (void)setViewMode:(DiffPaneViewMode)mode
{
	if(_viewMode == mode)
		return;
	_viewMode = mode;
	_modeControl.selectedSegment = mode == DiffPaneViewModeApplied ? 1 : 0;
	if(_active)
		[self renderNow];
}

- (void)toggleViewMode
{
	self.viewMode = _viewMode == DiffPaneViewModeApplied ? DiffPaneViewModeUnified : DiffPaneViewModeApplied;
}

// ============
// = Document =
// ============

- (void)setDocument:(OakDocument*)aDocument
{
	if(_document == aDocument)
		return;

	_document = aDocument;
	_baselineValid = NO;

	if(_active)
	{
		[self renderNow];
		[self updateHeader];
	}
}

- (void)setComparedContents:(NSString*)someContents
{
	if(_comparedContents == someContents || [_comparedContents isEqualToString:someContents])
		return;
	_comparedContents = [someContents copy];
	if(_active)
		[self renderNow];
}

- (void)documentDidSave
{
	if(!_active)
		return;
	_baselineValid = NO;
	[self renderNow];
}

// ===================
// = Update pipeline =
// ===================

- (void)renderNow
{
	if(!_active || !_diffTextView)
		return;

	std::string const compared = to_s(_comparedContents ?: @"");
	NSString* const path       = _document.path;
	bool const needBaseline    = !_baselineValid;
	bool const applied         = _viewMode == DiffPaneViewModeApplied;
	NSUInteger const generation = ++_generation;

	NSColor* foreground = _themeForegroundColor ?: NSColor.textColor;
	NSColor* background = _themeBackgroundColor ?: NSColor.textBackgroundColor;
	NSColor* addedBackground   = [NSColor.systemGreenColor colorWithAlphaComponent:0.18];
	NSColor* removedBackground = [NSColor.systemRedColor colorWithAlphaComponent:0.18];
	NSColor* hunkColor         = BlendedColor(foreground, background, 0.35); // dimmed theme foreground, never a system semantic color

	// Same font as the main buffer: the layout’s theme carries the displayed
	// font (name and point size × scale factor) baked in.
	NSFont* font;
	if(_theme && _theme->font_name() != NULL_STR)
		font = [NSFont fontWithName:to_ns(_theme->font_name()) size:_theme->font_size()];
	if(!font)
		font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];

	// Captured on the main thread; only the serial render queue dereferences
	// them. Highlighting is skipped for huge inputs — a full parse of a
	// multi-megabyte file would stall the queue for little benefit.
	theme_ptr const renderTheme    = _renderTheme;
	parse::grammar_ptr const grammar = applied && renderTheme && compared.size() < 1024*1024 ? [self grammarForFileType:_document.fileType] : parse::grammar_ptr();

	__weak DiffPaneView* weakSelf = self;
	dispatch_async(_renderQueue, ^{
		DiffPaneView* pane = weakSelf;
		if(!pane || generation != pane->_generation)
			return;

		if(needBaseline)
		{
			// Reading the diff base on the render queue keeps a slow disk off
			// the main thread; it only changes on save/reload events. The
			// compared contents are LF-normalized already, so the disk
			// contents are normalized the same way — the pane diffs content,
			// not newline flavor (a CRLF file must not show as all-changed).
			NSData* data = path ? [NSData dataWithContentsOfFile:path] : nil;
			std::string baseline = data ? std::string((char const*)data.bytes, (char const*)data.bytes + data.length) : std::string();
			std::string const newlines = text::estimate_line_endings(baseline.begin(), baseline.end());
			if(newlines != kLF)
				baseline.resize(text::convert_line_endings(baseline.begin(), baseline.end(), newlines) - baseline.begin());
			pane->_baseline = baseline;
			dispatch_async(dispatch_get_main_queue(), ^{
				pane->_baselineValid = YES;
			});
		}

		NSDictionary* baseAttributes    = @{ NSFontAttributeName: font, NSForegroundColorAttributeName: foreground };
		NSDictionary* addedAttributes   = @{ NSFontAttributeName: font, NSForegroundColorAttributeName: foreground, NSBackgroundColorAttributeName: addedBackground };
		NSDictionary* removedAttributes = @{ NSFontAttributeName: font, NSForegroundColorAttributeName: hunkColor,  NSBackgroundColorAttributeName: removedBackground };
		NSDictionary* hunkAttributes    = @{ NSFontAttributeName: font, NSForegroundColorAttributeName: hunkColor };

		NSMutableAttributedString* output = [NSMutableAttributedString new];
		auto append = [&output](std::string const& text, NSDictionary* attributes){
			if(!text.empty())
				[output appendAttributedString:[[NSAttributedString alloc] initWithString:(to_ns(text) ?: @"\n") attributes:attributes]];
		};

		NSUInteger firstChange = NSNotFound; // UTF-16 offset (in `output`) of the first changed region

		if(applied)
		{
			// “Applied” view: the FULL compared file contents, with regions
			// that differ from the baseline highlighted and pure deletions
			// marked by a compact “▸ N lines removed” pill at the deletion
			// point. The line-wise replacements() edits transform baseline →
			// compared, so walking them reconstructs the compared contents —
			// unchanged baseline spans are byte-identical to the corresponding
			// compared spans, which lets every span (unchanged AND inserted)
			// be copied out of one syntax-highlighted rendering of the whole.
			NSMutableAttributedString* styledCompared = [[NSMutableAttributedString alloc] initWithString:(to_ns(compared) ?: @"") attributes:baseAttributes];
			if(grammar && (NSUInteger)styledCompared.length > 0)
			{
				std::map<size_t, scope::scope_t> scopes; // byte offset → scope, whole compared contents
				parse::stack_ptr parserState = grammar->seed();
				for(size_t i = 0; i < compared.size(); )
				{
					size_t eol = compared.find('\n', i);
					eol = eol != std::string::npos ? eol + 1 : compared.size();
					std::string const line = compared.substr(i, eol - i);
					std::map<size_t, scope::scope_t> lineScopes;
					parserState = parse::parse(line.data(), line.data() + line.size(), parserState, lineScopes, i == 0);
					for(auto const& pair : lineScopes)
						scopes[i + pair.first] = pair.second;
					i = eol;
				}

				size_t bytePos = 0, utf16Pos = 0;
				for(auto it = scopes.begin(); it != scopes.end(); ++it)
				{
					size_t const runFrom = it->first;
					auto const next     = std::next(it);
					size_t const runTo  = std::min(next != scopes.end() ? next->first : compared.size(), compared.size());
					if(runTo <= runFrom || runFrom < bytePos)
						continue;

					utf16Pos += utf16::distance(compared.data() + bytePos, compared.data() + runFrom);
					size_t const len = utf16::distance(compared.data() + runFrom, compared.data() + runTo);

					auto const& styles = renderTheme->styles_for_scope(it->second);
					NSMutableDictionary* attrs = [NSMutableDictionary dictionaryWithCapacity:3];
					if(NSColor* color = [NSColor colorWithCGColor:styles.foreground()])
						attrs[NSForegroundColorAttributeName] = color;
					if(NSFont* runFont = (__bridge NSFont*)styles.font()) // theme font — bold/italic variants of the editor font
						attrs[NSFontAttributeName] = runFont;
					if(styles.underlined())
						attrs[NSUnderlineStyleAttributeName] = @(NSUnderlineStyleSingle);
					[styledCompared addAttributes:attrs range:NSMakeRange(utf16Pos, len)];

					utf16Pos += len;
					bytePos = runTo;
				}
			}

			auto const edits = scm::text_diff::replacements(pane->_baseline, compared);
			std::string const& base = pane->_baseline;
			size_t oldPos = 0;           // byte offset into base
			size_t newPos = 0;           // byte offset into compared
			NSUInteger newPosUTF16 = 0;  // same position in styledCompared
			bool atLineStart = true;

			auto appendComparedSpan = [&](size_t byteLen, bool isInsertion){
				if(byteLen == 0)
					return;
				NSUInteger const len = utf16::distance(compared.data() + newPos, compared.data() + newPos + byteLen);
				NSUInteger const outStart = output.length;
				[output appendAttributedString:[styledCompared attributedSubstringFromRange:NSMakeRange(newPosUTF16, len)]];
				if(isInsertion)
				{
					[output addAttribute:NSBackgroundColorAttributeName value:addedBackground range:NSMakeRange(outStart, len)];
					if(firstChange == NSNotFound)
						firstChange = outStart;
				}
				atLineStart = compared[newPos + byteLen - 1] == '\n';
				newPos += byteLen;
				newPosUTF16 += len;
			};

			for(auto const& edit : edits)
			{
				size_t const from = edit.first.first, to = edit.first.second;
				if(from > oldPos)
					appendComparedSpan(from - oldPos, false);
				if(!edit.second.empty())
					appendComparedSpan(edit.second.size(), true);
				if(to > from && edit.second.empty())
				{
					size_t const removedLines = std::max<size_t>(1, std::count(base.begin() + from, base.begin() + to, '\n'));
					std::string marker = removedLines == 1 ? "▸ 1 line removed" : "▸ " + std::to_string(removedLines) + " lines removed";
					if(!atLineStart)
						append("\n", baseAttributes);
					if(firstChange == NSNotFound)
						firstChange = output.length;
					append(" " + marker + " ", removedAttributes);
					append("\n", baseAttributes);
					atLineStart = true;
				}
				oldPos = to;
			}
			if(oldPos < base.size())
				appendComparedSpan(base.size() - oldPos, false);

			if(output.length == 0)
				append("(empty file)\n", hunkAttributes);
		}
		else
		{
			std::string const diff = scm::text_diff::unified(pane->_baseline, compared, 3);
			if(diff.empty())
			{
				append("No changes — the contents match the file on disk.\n", hunkAttributes);
			}
			else
			{
				size_t pos = 0;
				while(pos < diff.size())
				{
					size_t eol = diff.find('\n', pos);
					if(eol == std::string::npos)
						eol = diff.size() - 1;
					std::string const line = diff.substr(pos, eol + 1 - pos);
					pos = eol + 1;

					NSDictionary* attributes = baseAttributes;
					if(line.size() >= 2 && line[0] == '@' && line[1] == '@')
						attributes = hunkAttributes;
					else if(line[0] == '+')
						attributes = addedAttributes;
					else if(line[0] == '-')
						attributes = @{ NSFontAttributeName: font, NSForegroundColorAttributeName: foreground, NSBackgroundColorAttributeName: removedBackground };
					else if(line[0] == '\\')
						attributes = hunkAttributes;

					append(line, attributes);
				}
			}
		}

		dispatch_async(dispatch_get_main_queue(), ^{
			DiffPaneView* strongSelf = weakSelf;
			if(!strongSelf || generation != strongSelf->_generation || !strongSelf->_diffTextView)
				return;
			NSTextView* textView = strongSelf->_diffTextView;
			[textView.textStorage setAttributedString:output];

			// Full layout, then size the frame from the used rect: sizeToFit
			// with lazy/viewport layout under-reports the width of long lines,
			// leaving the horizontal scroller short of the right edge. Clamp
			// to the clip size so the whole pane stays clickable.
			NSLayoutManager* layoutManager = textView.layoutManager;
			NSTextContainer* textContainer = textView.textContainer;
			[layoutManager ensureLayoutForTextContainer:textContainer];
			NSRect const used    = [layoutManager usedRectForTextContainer:textContainer];
			NSSize const inset   = textView.textContainerInset;
			NSSize const visible = strongSelf->_diffScrollView.contentSize;
			[textView setFrameSize:NSMakeSize(std::max(NSWidth(used) + 2*inset.width, visible.width), std::max(NSHeight(used) + 2*inset.height, visible.height))];

			// The Applied view opens at the first changed region (about a
			// third from the top), not at the top of the file.
			if(firstChange != NSNotFound && firstChange < output.length)
			{
				NSUInteger const glyphIndex = [layoutManager glyphIndexForCharacterAtIndex:firstChange];
				NSRect const lineRect = [layoutManager lineFragmentRectForGlyphAtIndex:glyphIndex effectiveRange:NULL];
				[textView scrollPoint:NSMakePoint(0, std::max<CGFloat>(0, NSMinY(lineRect) + inset.height - visible.height/3))];
			}
		});
	});
}

// ==========
// = Header =
// ==========

- (void)setStatusText:(NSString*)text
{
	_statusText = [text copy];
	[self updateHeader];
}

- (void)updateHeader
{
	NSString* name = _document.displayName ?: @"";
	_headerField.stringValue = _statusText.length ? [NSString stringWithFormat:@"%@ — %@", name, _statusText] : name;
}

// =========
// = Theme =
// =========

// Both setters re-render: the hunk/dimmed colors are blends of foreground
// AND background, so a change to either must recolor the diff text (theme
// switches while the pane is open push both).
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
	if(!_diffScrollView)
		return;
	NSColor* background = _themeBackgroundColor ?: NSColor.textBackgroundColor;
	NSColor* foreground = _themeForegroundColor ?: NSColor.textColor;
	_diffScrollView.backgroundColor = background;
	_diffTextView.backgroundColor   = background;

	// The header/status line must stay readable on the theme background:
	// theme foreground, dimmed only slightly.
	_headerField.textColor        = BlendedColor(foreground, background, 0.25);
	_closeButton.contentTintColor = BlendedColor(foreground, background, 0.35);

	// The bezeled controls (segmented control, buttons) render for the
	// SYSTEM appearance, not the editor theme — on a dark theme under a
	// light system appearance the unselected segment label is dark-on-dark.
	// Pin their NSAppearance to the theme's brightness instead.
	NSColor* backgroundRGB = [background colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
	BOOL const isDarkTheme = backgroundRGB && (0.2126*backgroundRGB.redComponent + 0.7152*backgroundRGB.greenComponent + 0.0722*backgroundRGB.blueComponent) < 0.5;
	_modeControl.appearance = [NSAppearance appearanceNamed:isDarkTheme ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua];

	self.needsDisplay = YES; // the header strip background is drawn from these colors
}
@end
