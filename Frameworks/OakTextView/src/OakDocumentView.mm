#import "OakDocumentView.h"
#import "OakTextView_Private.h"
#import "GutterView.h"
#import "MinimapView.h"
#import "MarkdownPreviewView.h"
#import "DiffPaneView.h"
#import "BufferDiffService.h"
#import "diff_pane_model.h"
#import "OakReviewBase.h"
#import "diff_mark_palette.h"
#import <lsp/LSPClient.h>
#import <lsp/LSPManager.h>
#import <lsp/CopilotManager.h>
#import "OTVStatusBar.h"
#import <document/OakDocument.h>
#import <file/type.h>
#import <text/ctype.h>
#import <text/parse.h>
#import <text/types.h>
#import <ns/ns.h>
#import <oak/debug.h>
#import <bundles/bundles.h>
#import <settings/settings.h>
#import <OakFilterList/SymbolChooser.h>
#import <OakFoundation/NSString Additions.h>
#import <OakAppKit/OakAppKit.h>
#import <OakAppKit/NSImage Additions.h>
#import <OakAppKit/OakToolTip.h>
#import <OakAppKit/OakPasteboardChooser.h>
#import <OakAppKit/OakPasteboard.h>
#import <OakAppKit/OakUIConstructionFunctions.h>
#import <OakAppKit/NSMenuItem Additions.h>
#import <BundleMenu/BundleMenu.h>
#import <Preferences/Keys.h>
#import <Preferences/Preferences.h>

static NSString* const kBookmarksColumnIdentifier = @"bookmarks";
static NSString* const kFoldingsColumnIdentifier  = @"foldings";
static NSString* const kDiffMarksColumnIdentifier = @"diffMarks";

// The change bars sit between the last icon column and the text, the
// placement every editor with this feature uses: the mark belongs to the
// line of code, so it reads as attached to it rather than to the gutter's
// controls.
static CGFloat const kDiffMarksColumnWidth = 4;
static CGFloat const kDiffMarksBarWidth    = 3;
static CGFloat const kDiffMarksTickHeight  = 2;

// On the editor’s own background the minimap reads as empty margin, so shift
// it the way the gutter goes — lighter on dark themes, darker on light ones —
// but far more gently than the gutter does, enough to separate the strip
// without asking for attention. The gutter’s own step is a shade under 0.09,
// which puts this at about half of it.
static CGFloat const kMinimapBackgroundTint = 0.05;

// Blended by hand in sRGB: -blendedColorWithFraction:ofColor: works in the
// calibrated space, where the same fraction lands twice as hard on the dark
// themes as it does on the light ones.
static NSColor* OakTintedMinimapBackground (NSColor* background, BOOL isDark)
{
	NSColor* srgb = [background colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
	if(!srgb)
		return background;

	CGFloat const target = isDark ? 1 : 0;
	auto tint = [&target](CGFloat component){ return component + kMinimapBackgroundTint * (target - component); };

	return [NSColor colorWithSRGBRed:tint(srgb.redComponent) green:tint(srgb.greenComponent) blue:tint(srgb.blueComponent) alpha:srgb.alphaComponent];
}

@interface OakDocumentView () <NSAccessibilityGroup, GutterViewDelegate, GutterViewColumnDataSource, GutterViewColumnDelegate, OTVStatusBarDelegate>
{
	NSScrollView* gutterScrollView;
	GutterView* gutterView;
	NSMutableDictionary* gutterImages;

	OakBackgroundFillView* gutterDividerView;

	NSScrollView* textScrollView;
	NSScrollView* minimapScrollView;
	MinimapView* minimapView;

	MarkdownPreviewDividerView* diffPaneDividerView;
	NSScrollView* diffPaneScrollView;
	DiffPaneView* diffPaneView;
	CGFloat diffPaneWidth;
	BOOL showDiffPane;

	BufferDiffService* diffService;
	BufferDiffSnapshot* lastDiffSnapshot; // what the base selector and the status bar describe
	NSString* lastDiffRepoRoot;           // repo root of the most recent snapshot

	NSMutableArray* topAuxiliaryViews;
	NSMutableArray* bottomAuxiliaryViews;

	IBOutlet NSPanel* tabSizeSelectorPanel;

	NSUInteger _cursorLine;
	BOOL _cursorLineHasActions;
	NSUInteger _probeGeneration;

	// Change-bar colors, resolved from the theme in -updateStyle so the
	// column's drawing does no color math per row.
	NSColor* diffAddedColor;
	NSColor* diffModifiedColor;
	NSColor* diffDeletedColor;
	BOOL diffMarksShowIcons; // the bars are off, so the classic gutter icons stand in
}
@property (nonatomic, readonly) OTVStatusBar* statusBar;
@property (nonatomic) SymbolChooser* symbolChooser;
@property (nonatomic) NSArray* observedKeys;
- (void)updateStyle;
@end

@implementation OakDocumentView
- (id)initWithFrame:(NSRect)aRect
{
	if(self = [super initWithFrame:aRect])
	{
		self.accessibilityRole  = NSAccessibilityGroupRole;
		self.accessibilityLabel = @"Editor";

		_cursorLine = NSNotFound;

		_textView = [[OakTextView alloc] initWithFrame:NSZeroRect];
		_textView.autoresizingMask = NSViewWidthSizable|NSViewHeightSizable;

		textScrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
		textScrollView.hasVerticalScroller      = YES;
		textScrollView.verticalScrollElasticity = NSScrollElasticityAllowed;
		textScrollView.hasHorizontalScroller    = YES;
		textScrollView.autohidesScrollers       = YES;
		textScrollView.borderType               = NSNoBorder;
		textScrollView.documentView             = _textView;

		gutterView = [[GutterView alloc] initWithFrame:NSZeroRect];
		gutterView.partnerView = _textView;
		gutterView.delegate    = self;
		[gutterView insertColumnWithIdentifier:kBookmarksColumnIdentifier atPosition:0 dataSource:self delegate:self];
		[gutterView insertColumnWithIdentifier:kFoldingsColumnIdentifier atPosition:2 dataSource:self delegate:self];
		[gutterView insertColumnWithIdentifier:kDiffMarksColumnIdentifier atPosition:3 dataSource:self delegate:nil]; // no delegate: the bars are indication, not a control
		if([NSUserDefaults.standardUserDefaults boolForKey:@"DocumentView Disable Line Numbers"])
			[gutterView setVisibility:NO forColumnWithIdentifier:GVLineNumbersColumnIdentifier];
		[gutterView setTranslatesAutoresizingMaskIntoConstraints:NO];

		gutterScrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
		gutterScrollView.accessibilityElement = NO;
		gutterScrollView.borderType   = NSNoBorder;
		gutterScrollView.documentView = gutterView;

		[gutterScrollView.contentView addConstraint:[NSLayoutConstraint constraintWithItem:gutterView attribute:NSLayoutAttributeLeft relatedBy:NSLayoutRelationEqual toItem:gutterScrollView.contentView attribute:NSLayoutAttributeLeft multiplier:1.0 constant:0.0]];
		[gutterScrollView.contentView addConstraint:[NSLayoutConstraint constraintWithItem:gutterView attribute:NSLayoutAttributeTop relatedBy:NSLayoutRelationEqual toItem:gutterScrollView.contentView attribute:NSLayoutAttributeTop multiplier:1.0 constant:0.0]];
		[gutterScrollView.contentView addConstraint:[NSLayoutConstraint constraintWithItem:gutterView attribute:NSLayoutAttributeRight relatedBy:NSLayoutRelationEqual toItem:gutterScrollView.contentView attribute:NSLayoutAttributeRight multiplier:1.0 constant:0.0]];

		gutterDividerView = OakCreateVerticalLine(OakBackgroundFillViewStyleNone);

		minimapView = [[MinimapView alloc] initWithFrame:NSZeroRect];
		minimapView.textView = _textView;

		minimapScrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
		minimapScrollView.accessibilityElement   = NO;
		minimapScrollView.borderType             = NSNoBorder;
		minimapScrollView.hasVerticalScroller    = NO;
		minimapScrollView.hasHorizontalScroller  = NO;
		minimapScrollView.verticalScrollElasticity = NSScrollElasticityNone;
		minimapScrollView.documentView           = minimapView;
		minimapScrollView.hidden = ![NSUserDefaults.standardUserDefaults boolForKey:@"DocumentView Show Minimap"];

		// The diff pane materializes lazily; only its width persists.
		diffPaneWidth = [NSUserDefaults.standardUserDefaults doubleForKey:@"DocumentView Diff Pane Width"];

		// The buffer-diff service runs regardless of the pane: it also
		// maintains the diff.* document marks the minimap renders.
		diffService = [BufferDiffService new];
		__weak OakDocumentView* weakSelfForDiff = self;
		diffService.snapshotHandler = ^(BufferDiffSnapshot* snapshot){
			[weakSelfForDiff takeDiffSnapshot:snapshot];
		};
		diffService.headMovedHandler = ^(NSString* oldHead, NSString* newHead, scm::git_query::head_change change){
			[weakSelfForDiff repoHeadMovedFrom:oldHead to:newHead change:change];
		};

		_statusBar = [[OTVStatusBar alloc] initWithFrame:NSZeroRect];
		_statusBar.delegate = self;
		_statusBar.target = self;

		OakAddAutoLayoutViewsToSuperview(@[ gutterScrollView, gutterDividerView, textScrollView, minimapScrollView, _statusBar ], self);
		OakSetupKeyViewLoop(@[ self, _textView, _statusBar ]);

		self.document = [OakDocument documentWithString:@"" fileType:@"text.plain" customName:@"placeholder"];

		self.observedKeys = @[ @"selectionString", @"symbol", @"recordingMacro", @"themeUUID" ];
		for(NSString* keyPath in self.observedKeys)
			[_textView addObserver:self forKeyPath:keyPath options:NSKeyValueObservingOptionInitial context:NULL];

		[self updateDiffMarksColumnVisibility];
		[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(userDefaultsDidChange:) name:NSUserDefaultsDidChangeNotification object:nil];

		[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(lspDiagnosticsDidChange:) name:LSPDiagnosticsDidChangeNotification object:nil];
		[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(lspServerStatusDidChange:) name:LSPServerStatusDidChangeNotification object:nil];
		[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(lspShowMessage:) name:LSPShowMessageNotification object:nil];
		[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(copilotStatusDidChange:) name:CopilotStatusDidChangeNotification object:nil];
	}
	return self;
}

- (void)updateConstraints
{
	[self removeConstraints:[self constraints]];
	[super updateConstraints];

	NSMutableArray* stackedViews = [NSMutableArray array];
	[stackedViews addObjectsFromArray:topAuxiliaryViews];
	[stackedViews addObject:gutterScrollView];
	[stackedViews addObjectsFromArray:bottomAuxiliaryViews];

	if(_statusBar)
	{
		[stackedViews addObject:_statusBar];
		[self addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:|[_statusBar]|" options:0 metrics:nil views:NSDictionaryOfVariableBindings(_statusBar)]];
	}

	{
		NSMutableDictionary* views = [NSDictionaryOfVariableBindings(gutterScrollView, gutterView, gutterDividerView, textScrollView, minimapScrollView) mutableCopy];
		NSMutableString* format = [@"H:|[gutterScrollView(==gutterView)][gutterDividerView][textScrollView(>=100)][minimapScrollView(==minimapWidth)]" mutableCopy];

		// Diff pane width wins over stretching the text view but yields (@490)
		// to the text view’s required minimum when the window gets too narrow.
		BOOL const diffPaneVisible = diffPaneScrollView && !diffPaneScrollView.hidden;
		CGFloat const maxDiffWidth = NSWidth(self.bounds) - NSWidth(gutterScrollView.frame) - (minimapScrollView.hidden ? 0 : 110) - 150;
		NSDictionary* metrics = @{
			@"minimapWidth": @(minimapScrollView.hidden ? 0 : 110),
			@"diffDividerWidth": @(diffPaneVisible ? 5 : 0),
			@"diffWidth": @(diffPaneVisible ? std::clamp<CGFloat>(diffPaneWidth, 150, std::max<CGFloat>(150, maxDiffWidth)) : 0),
		};

		if(diffPaneScrollView)
		{
			[format appendString:@"[diffPaneDividerView(==diffDividerWidth)][diffPaneScrollView(==diffWidth@490)]"];
			views[@"diffPaneDividerView"] = diffPaneDividerView;
			views[@"diffPaneScrollView"]  = diffPaneScrollView;
		}
		[format appendString:@"|"];

		[self addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:format options:NSLayoutFormatAlignAllTop|NSLayoutFormatAlignAllBottom metrics:metrics views:views]];
	}
	[self addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"V:|[topView]" options:0 metrics:nil views:@{ @"topView": stackedViews[0] }]];
	[self addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"V:[bottomView]|" options:0 metrics:nil views:@{ @"bottomView": [stackedViews lastObject] }]];

	for(size_t i = 0; i < [stackedViews count]-1; ++i)
		[self addConstraint:[NSLayoutConstraint constraintWithItem:stackedViews[i] attribute:NSLayoutAttributeBottom relatedBy:NSLayoutRelationEqual toItem:stackedViews[i+1] attribute:NSLayoutAttributeTop multiplier:1 constant:0]];

	NSArray* array[] = { topAuxiliaryViews, bottomAuxiliaryViews };
	for(NSArray* views : array)
	{
		for(NSView* view in views)
			[self addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:|[view]|" options:0 metrics:nil views:NSDictionaryOfVariableBindings(view)]];
	}
}

- (void)setHideStatusBar:(BOOL)flag
{
	if(_hideStatusBar == flag)
		return;

	_hideStatusBar = flag;
	if(_hideStatusBar)
	{
		[_statusBar removeFromSuperview];
		_statusBar.delegate = nil;
		_statusBar.target = nil;
		_statusBar = nil;
	}
	else
	{
		_statusBar = [[OTVStatusBar alloc] initWithFrame:NSZeroRect];
		_statusBar.delegate = self;
		_statusBar.target = self;

		OakAddAutoLayoutViewsToSuperview(@[ _statusBar ], self);
	}
	[self setNeedsUpdateConstraints:YES];
}

- (CGFloat)lineHeight
{
	return round(std::min(1.5 * [_textView.font capHeight], [_textView.font ascender] - [_textView.font descender] + [_textView.font leading]));
}

- (NSImage*)gutterImage:(NSString*)aName
{
	id res = gutterImages[aName];
	if(!res)
	{
		gutterImages = gutterImages ?: [NSMutableDictionary new];

		NSImage* image = [aName hasPrefix:@"/"] ? [[NSImage alloc] initWithContentsOfFile:aName] : [NSImage imageNamed:aName inSameBundleAsClass:[self class]];
		if(!image && ![aName hasPrefix:@"/"] && ![aName hasSuffix:@" Template"])
			image = [NSImage imageNamed:[aName stringByAppendingString:@" Template"] inSameBundleAsClass:[self class]];

		if([aName hasPrefix:@"/"] && [[aName stringByDeletingPathExtension] hasSuffix:@" Template"])
			[image setTemplate:YES];

		if(image)
		{
			CGFloat imageWidth  = image.size.width;
			CGFloat imageHeight = image.size.height;

			CGFloat viewWidth   = [self widthForColumnWithIdentifier:nil];
			CGFloat viewHeight  = self.lineHeight;

			res = image = [image copy];

			if(imageWidth / imageHeight < viewWidth / viewHeight)
					image.size = NSMakeSize(round(viewHeight * imageWidth / imageHeight), viewHeight);
			else	image.size = NSMakeSize(viewWidth, round(viewWidth * imageHeight / imageWidth));
		}
		else
		{
			res = [NSNull null];
			NSLog(@"%s no image named ‘%@’", sel_getName(_cmd), aName);
		}

		gutterImages[aName] = res;
	}
	return res == [NSNull null] ? nil : res;
}

- (void)updateGutterViewFont:(id)sender
{
	CGFloat const scaleFactor = [NSUserDefaults.standardUserDefaults floatForKey:kUserDefaultsLineNumberScaleFactorKey] ?: 0.8;
	NSString* lineNumberFontName = [NSUserDefaults.standardUserDefaults stringForKey:kUserDefaultsLineNumberFontNameKey] ?: [_textView.font fontName];

	gutterImages = nil; // force image sizes to be recalculated
	gutterView.lineNumberFont = [NSFont fontWithName:lineNumberFontName size:round(scaleFactor * [_textView.font pointSize] * _textView.fontScaleFactor)];
	[gutterView reloadData:self];

	// The diff pane renders with the editor font, which is baked into the
	// layout’s theme — every font change (Font panel, ⌘+/⌘−) and every theme
	// change funnels through here, so this keeps the pane in sync with both.
	diffPaneView.theme            = _textView.theme;
	diffPaneView.lineNumberFont   = gutterView.lineNumberFont;
	diffPaneView.editorLineHeight = _textView.lineHeight;
}

- (IBAction)makeTextLarger:(id)sender
{
	_textView.fontScaleFactor += 0.1;
	[self updateGutterViewFont:self];
}

- (IBAction)makeTextSmaller:(id)sender
{
	if(_textView.fontScaleFactor > 0.1)
	{
		_textView.fontScaleFactor -= 0.1;
		[self updateGutterViewFont:self];
	}
}

- (IBAction)makeTextStandardSize:(id)sender
{
	_textView.fontScaleFactor = 1;
	[self updateGutterViewFont:self];
}

- (void)changeFont:(id)sender
{
	NSFont* defaultFont = [NSFont userFixedPitchFontOfSize:0];
	if(NSFont* newFont = [sender convertFont:_textView.font ?: defaultFont])
	{
		std::string fontName = [newFont.fontName isEqualToString:defaultFont.fontName] ? NULL_STR : to_s(newFont.fontName);
		settings_t::set(kSettingsFontNameKey, fontName);
		settings_t::set(kSettingsFontSizeKey, [newFont pointSize]);
		_textView.font = newFont;
		[self updateGutterViewFont:self];
	}
}

- (void)observeValueForKeyPath:(NSString*)aKeyPath ofObject:(id)observableController change:(NSDictionary*)changeDictionary context:(void*)userData
{
	if([aKeyPath isEqualToString:@"selectionString"])
	{
		NSString* str = [_textView valueForKey:@"selectionString"];
		[gutterView setHighlightedRange:to_s(str ?: @"1")];
		[_statusBar setSelectionString:str];
		_symbolChooser.selectionString = str;

		text::selection_t const sel(to_s(str ?: @"1"));
		minimapView.caretLine = sel.empty() ? NSNotFound : sel.last().to.line;
		if(showDiffPane)
			diffPaneView.caretLine = sel.empty() ? 1 : sel.last().to.line + 1; // highlights the card the caret is in
	}
	else if([aKeyPath isEqualToString:@"symbol"])
	{
		_statusBar.symbolName = _textView.symbol;
	}
	else if([aKeyPath isEqualToString:@"recordingMacro"])
	{
		_statusBar.recordingMacro = _textView.isRecordingMacro;
	}
	else if([aKeyPath isEqualToString:@"fileType"])
	{
		_statusBar.fileType = self.document.fileType;

		// A real grammar switch re-registers the document with LSP so it can
		// attach to the new type's server. The initial KVO firing has no old
		// value — it must not detach/reattach on every tab focus.
		NSString* oldType = [changeDictionary[NSKeyValueChangeOldKey] isKindOfClass:[NSString class]] ? changeDictionary[NSKeyValueChangeOldKey] : nil;
		if(oldType && ![oldType isEqualToString:self.document.fileType])
			[LSPManager.sharedManager documentDidChangeFileType:self.document];
	}
	else if([aKeyPath isEqualToString:@"tabSize"])
	{
		_statusBar.tabSize = self.document.tabSize;
		[minimapView reloadMetrics]; // tab expansion affects all cached line metrics
	}
	else if([aKeyPath isEqualToString:@"softTabs"])
	{
		_statusBar.softTabs = self.document.softTabs;
	}
	else if([aKeyPath isEqualToString:@"themeUUID"])
	{
		[self updateStyle];
	}
}

- (void)dealloc
{
	for(NSString* keyPath in self.observedKeys)
		[_textView removeObserver:self forKeyPath:keyPath];
	[NSNotificationCenter.defaultCenter removeObserver:self];

	self.document = nil;
	self.symbolChooser = nil;
}

- (void)setDocument:(OakDocument*)aDocument
{
	NSArray* const documentKeys = @[ @"fileType", @"tabSize", @"softTabs" ];

	OakDocument* oldDocument = self.document;
	if(oldDocument)
	{
		for(NSString* key in documentKeys)
			[oldDocument removeObserver:self forKeyPath:key];
		[NSNotificationCenter.defaultCenter removeObserver:self name:OakDocumentMarksDidChangeNotification object:oldDocument];
		[NSNotificationCenter.defaultCenter removeObserver:self name:OakDocumentContentDidChangeNotification object:oldDocument];
		[NSNotificationCenter.defaultCenter removeObserver:self name:OakDocumentDidSaveNotification object:oldDocument];
		[NSNotificationCenter.defaultCenter removeObserver:self name:OakDocumentWillCloseNotification object:oldDocument];
	}

	if(aDocument)
		[aDocument loadModalForWindow:self.window completionHandler:nullptr];

	if(_document = aDocument)
	{
		[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(documentMarksDidChange:) name:OakDocumentMarksDidChangeNotification object:self.document];
		[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(documentContentDidChange:) name:OakDocumentContentDidChangeNotification object:self.document];
		[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(documentDidSave:) name:OakDocumentDidSaveNotification object:self.document];
		[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(documentWillClose:) name:OakDocumentWillCloseNotification object:self.document];
		for(NSString* key in documentKeys)
			[self.document addObserver:self forKeyPath:key options:NSKeyValueObservingOptionInitial|NSKeyValueObservingOptionOld context:nullptr];
	}

	[_textView setDocument:self.document];
	[minimapView setDocument:self.document];
	[diffPaneView setDocument:self.document]; // the pane follows the active tab
	[diffService setDocument:self.document];
	[self updateDiffPaneVisibility];
	[LSPManager.sharedManager documentDidOpen:aDocument];
	[[CopilotManager sharedManager] documentDidOpen:aDocument];
	[[CopilotManager sharedManager] documentDidFocus:aDocument];
	[gutterView reloadData:self];
	[self updateStyle];

	if(_symbolChooser)
	{
		_symbolChooser.TMDocument      = self.document;
		_symbolChooser.selectionString = _textView.selectionString;
	}

	if(oldDocument)
		[oldDocument close];

	if(aDocument)
	{
		__weak OakDocumentView* weakSelf = self;
		dispatch_async(dispatch_get_main_queue(), ^{
			[weakSelf updateLSPStatusBar];
		});
	}
}

- (void)updateStyle
{
	if(theme_ptr theme = _textView.theme)
	{
		[textScrollView setBackgroundColor:[NSColor colorWithCGColor:theme->background(to_s(self.document.fileType))]];
		[textScrollView setScrollerKnobStyle:theme->is_dark() ? NSScrollerKnobStyleLight : NSScrollerKnobStyleDark];

		[_textView setIbeamCursor:NSCursor.IBeamCursor];

		[self updateGutterViewFont:self]; // trigger update of gutter view’s line number font
		auto const& styles = theme->gutter_styles();

		gutterView.foregroundColor           = [NSColor colorWithCGColor:styles.foreground];
		gutterView.backgroundColor           = [NSColor colorWithCGColor:styles.background];
		gutterView.iconColor                 = [NSColor colorWithCGColor:styles.icons];
		gutterView.iconHoverColor            = [NSColor colorWithCGColor:styles.iconsHover];
		gutterView.iconPressedColor          = [NSColor colorWithCGColor:styles.iconsPressed];
		gutterView.selectionForegroundColor  = [NSColor colorWithCGColor:styles.selectionForeground];
		gutterView.selectionBackgroundColor  = [NSColor colorWithCGColor:styles.selectionBackground];
		gutterView.selectionIconColor        = [NSColor colorWithCGColor:styles.selectionIcons];
		gutterView.selectionIconHoverColor   = [NSColor colorWithCGColor:styles.selectionIconsHover];
		gutterView.selectionIconPressedColor = [NSColor colorWithCGColor:styles.selectionIconsPressed];
		gutterView.selectionBorderColor      = [NSColor colorWithCGColor:styles.selectionBorder];
		gutterScrollView.backgroundColor     = gutterView.backgroundColor;

		gutterDividerView.activeBackgroundColor = [NSColor colorWithCGColor:styles.divider];

		// The change bars are drawn on the gutter's own background, so its
		// brightness — not the editor's — picks the palette variant.
		CGFloat gutterBrightness = 0.5;
		if(NSColor* background = [gutterView.backgroundColor colorUsingColorSpace:NSColorSpace.genericRGBColorSpace])
			gutterBrightness = background.brightnessComponent;
		BOOL const isDarkGutter = gutterBrightness <= 0.5;

		auto paletteColor = [](diff_mark_palette::rgb_t rgb){ return [NSColor colorWithSRGBRed:rgb.red green:rgb.green blue:rgb.blue alpha:1]; };
		diffAddedColor    = paletteColor(diff_mark_palette::added(isDarkGutter));
		diffModifiedColor = paletteColor(diff_mark_palette::modified(isDarkGutter));
		diffDeletedColor  = paletteColor(diff_mark_palette::deleted(isDarkGutter));

		// The diff pane draws its own two line-number columns; give it the
		// gutter's palette so they match the one beside the buffer.
		diffPaneView.gutterForegroundColor = gutterView.foregroundColor;
		diffPaneView.gutterBackgroundColor = gutterView.backgroundColor;
		diffPaneView.gutterDividerColor    = gutterDividerView.activeBackgroundColor;

		minimapView.backgroundColor       = OakTintedMinimapBackground([NSColor colorWithCGColor:theme->background(to_s(self.document.fileType))], theme->is_dark());
		minimapView.caretColor            = [NSColor colorWithCGColor:theme->styles_for_scope(to_s(self.document.fileType)).caret()];
		minimapView.theme                 = theme;
		minimapScrollView.backgroundColor = minimapView.backgroundColor;

		diffPaneView.themeBackgroundColor   = [NSColor colorWithCGColor:theme->background(to_s(self.document.fileType))];
		diffPaneView.themeForegroundColor   = [NSColor colorWithCGColor:theme->styles_for_scope(to_s(self.document.fileType)).foreground()];
		diffPaneDividerView.backgroundColor = diffPaneView.themeBackgroundColor;
		diffPaneDividerView.lineColor       = [NSColor colorWithCGColor:styles.divider];
		diffPaneScrollView.backgroundColor  = diffPaneView.themeBackgroundColor;

		[gutterView setNeedsDisplay:YES];
	}
}

- (IBAction)toggleLineNumbers:(id)sender
{
	BOOL isVisibleFlag = ![gutterView visibilityForColumnWithIdentifier:GVLineNumbersColumnIdentifier];
	[gutterView setVisibility:isVisibleFlag forColumnWithIdentifier:GVLineNumbersColumnIdentifier];
	if(isVisibleFlag)
			[NSUserDefaults.standardUserDefaults removeObjectForKey:@"DocumentView Disable Line Numbers"];
	else	[NSUserDefaults.standardUserDefaults setObject:@YES forKey:@"DocumentView Disable Line Numbers"];
}

- (IBAction)toggleMinimap:(id)sender
{
	BOOL showFlag = minimapScrollView.hidden;
	minimapScrollView.hidden = !showFlag;
	if(showFlag)
			[NSUserDefaults.standardUserDefaults setObject:@YES forKey:@"DocumentView Show Minimap"];
	else	[NSUserDefaults.standardUserDefaults removeObjectForKey:@"DocumentView Show Minimap"];
	[self setNeedsUpdateConstraints:YES];
}

// =============
// = Diff pane =
// =============

// The git-native review pane: lists every hunk of the document from the
// buffer-vs-review-base snapshot the BufferDiffService publishes.
- (IBAction)toggleDiffPane:(id)sender
{
	showDiffPane = !showDiffPane;
	[self updateDiffPaneVisibility];
	[self updateDiffMarksColumnVisibility]; // the “only while the pane is open” setting
}

// The gutter's change indication follows a three-way preference; the
// minimap and the pane are unaffected, since this is about how loud the
// indication in the buffer itself should be.
//
// The two presentations are never shown together, because they say the
// same thing. Full-height colour bars in their own column are the
// reviewing register, and the gutter falls back to the marks it has
// always carried otherwise: the same `diff.* Template.pdf` icons in the
// bookmark column, tinted like every other gutter icon. With the pane
// closed and the setting left alone, the gutter therefore looks exactly
// as it did before any of this existed.
- (void)updateDiffMarksColumnVisibility
{
	NSString* const mode = [NSUserDefaults.standardUserDefaults stringForKey:kUserDefaultsDiffMarksVisibilityKey];
	BOOL const never  = [mode isEqualToString:kDiffMarksVisibilityNever];
	BOOL const always = [mode isEqualToString:kDiffMarksVisibilityAlways];

	BOOL const showBars   = !never && (always || showDiffPane);
	BOOL const showIcons  = !never && !showBars;

	BOOL const columnChanged = [gutterView visibilityForColumnWithIdentifier:kDiffMarksColumnIdentifier] != showBars;
	if(columnChanged)
		[gutterView setVisibility:showBars forColumnWithIdentifier:kDiffMarksColumnIdentifier];

	if(!columnChanged && diffMarksShowIcons == showIcons)
		return;

	diffMarksShowIcons = showIcons;
	[gutterView setNeedsDisplay:YES]; // -setVisibility: resizes but does not redraw
}

// Whether a mark type should come out of the bookmark column's generic
// “mark type name doubles as an image name” path. The change marks have
// a second presentation of their own, so they pass only while the bars
// are not showing — otherwise the same change is indicated twice.
// `diff.deleted` never passes: there is no icon for it (the bundle this
// replaced never drew one either), and letting it through would let a
// nil image shadow the real icon on a line that is also modified.
- (BOOL)shouldDrawMarkTypeAsGutterImage:(NSString*)type
{
	if(![type hasPrefix:@"diff."])
		return YES;
	return diffMarksShowIcons && ![type isEqualToString:@"diff.deleted"];
}

- (void)userDefaultsDidChange:(NSNotification*)aNotification
{
	[self updateDiffMarksColumnVisibility];
}

@synthesize reviewBase = _reviewBase; // both accessors are written below

// The window hands its base down; a view nobody gave one to keeps its
// own, so a standalone editor behaves exactly as a hosted one does.
- (OakReviewBase*)reviewBase
{
	if(!_reviewBase)
		self.reviewBase = [OakReviewBase new];
	return _reviewBase;
}

- (void)setReviewBase:(OakReviewBase*)aReviewBase
{
	if(_reviewBase == aReviewBase)
		return;

	if(_reviewBase)
		[NSNotificationCenter.defaultCenter removeObserver:self name:OakReviewBaseDidChangeNotification object:_reviewBase];
	_reviewBase = aReviewBase;
	if(_reviewBase)
		[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(reviewBaseDidChange:) name:OakReviewBaseDidChangeNotification object:_reviewBase];

	[self pushReviewBaseToDiffService];
}

// The base drives one thing here — what the service diffs against. Pane,
// gutter, minimap and status bar all read the snapshot that comes back,
// so none of them needs its own hook.
- (void)reviewBaseDidChange:(NSNotification*)aNotification
{
	[self pushReviewBaseToDiffService];
}

- (void)pushReviewBaseToDiffService
{
	[diffService setBaseKind:_reviewBase.kind spec:_reviewBase.spec repoRoot:_reviewBase.repoRoot];
}

- (void)takeDiffSnapshot:(BufferDiffSnapshot*)snapshot
{
	lastDiffSnapshot = snapshot;
	if(snapshot.repoRoot.length)
		lastDiffRepoRoot = snapshot.repoRoot;

	// Drop a PINNED base once the window is actually looking at a
	// different repository — the service has already fallen back to HEAD
	// for it, and leaving the old sha behind would revive it the moment a
	// tab from the original repository came back, with the selector still
	// showing HEAD. HEAD and a relative spec resolve in whatever
	// repository the document is in, so they travel with the window.
	//
	// Keyed on the repository, not on the fallback having happened:
	// closing a tab or glancing at an untitled scratch buffer also
	// delivers a HEAD snapshot, and those must not throw away a base the
	// user picked for a repository they are still in.
	OakReviewBase* base = self.reviewBase;
	if(base.kind == OakReviewBaseKindCommit && snapshot.repoRoot.length && ![snapshot.repoRoot isEqualToString:base.repoRoot])
		[base resetToHead];

	// Named from the snapshot rather than from the model, so the bar
	// says what the diff was actually taken against — and only inside a
	// repository, where there is a base to name at all.
	[self.statusBar setReviewBaseName:(snapshot.repoRoot.length ? [OakReviewBase displayNameForKind:snapshot.baseKind spec:snapshot.baseSpec resolvedRef:snapshot.baseRef] : nil) isHead:snapshot.isBaseHead];

	[diffPaneView takeSnapshot:snapshot];
}

- (NSString*)resolvedReviewBaseRef
{
	// From the snapshot, not the model, so it names the base the diff was
	// actually taken against; nil outside a repository, where there is no
	// base to name.
	//
	// Guarded by the snapshot's document identity: switching tabs or Save-As
	// leaves the previous document's snapshot in place until the async
	// recompute lands, and its sha would belong to another repository — so a
	// command reading TM_REVIEW_BASE in that window could be handed a ref
	// `git diff` cannot resolve. Withhold it until the snapshot catches up.
	BufferDiffSnapshot* snapshot = lastDiffSnapshot;
	if(snapshot.repoRoot.length && snapshot.documentPath && [snapshot.documentPath isEqualToString:self.document.path])
		return snapshot.baseRef;
	return nil;
}

- (void)repoHeadMovedFrom:(NSString*)oldHead to:(NSString*)newHead change:(scm::git_query::head_change)change
{
	if(change == scm::git_query::head_change::committed)
	{
		// A commit landed on top of the old HEAD (the agent or the user
		// committed): offer to review what just landed. Never changes the
		// review base on its own.
		//
		// A relative base needs no offer: it has already followed the
		// move, and after a single commit the new HEAD~1 IS the old HEAD
		// the banner would be offering.
		if(self.reviewBase.kind == OakReviewBaseKindRelative)
			return;

		if(diffPaneView && showDiffPane)
		{
			__weak OakDocumentView* weakSelf = self;
			NSString* message = [NSString stringWithFormat:@"HEAD moved — review %@…%@", [OakReviewBase shortNameForRef:oldHead], [OakReviewBase shortNameForRef:newHead]];
			[diffPaneView showBannerWithMessage:message actionTitle:@"Review" handler:^{
				[weakSelf takeReviewBaseOfKind:OakReviewBaseKindCommit spec:oldHead];
			}];
		}
		return;
	}

	// A switch to another branch, or a rewrite of this one (amend, reset,
	// rebase). Whether this unseats the review base is the pure rule in
	// diff_pane; the short of it is that a switch resets every kind, while
	// a rewrite spares a relative base — following rewrites is what
	// "relative" means, so an amend-per-turn agent keeps its HEAD~1 view.
	diff_pane::review_base_kind baseKind = diff_pane::review_base_kind::head;
	switch(self.reviewBase.kind)
	{
		case OakReviewBaseKindHead:     baseKind = diff_pane::review_base_kind::head;     break;
		case OakReviewBaseKindCommit:   baseKind = diff_pane::review_base_kind::commit;   break;
		case OakReviewBaseKindRelative: baseKind = diff_pane::review_base_kind::relative; break;
	}

	if(!diff_pane::head_move_resets_base(baseKind, change))
		return; // a relative base following a rewrite: silent, the status bar re-renders with the fresh resolution

	BOOL const hadOlderBase = self.reviewBase.kind != OakReviewBaseKindHead;
	[self.reviewBase resetToHead];
	if(diffPaneView && showDiffPane && hadOlderBase)
	{
		NSString* message = change == scm::git_query::head_change::switched
			? @"HEAD changed branches — review base reset to HEAD"
			: @"HEAD was rewritten — review base reset to HEAD";
		[diffPaneView showBannerWithMessage:message actionTitle:nil handler:nil];
	}
}

// The review base selector. It lives in the status bar because that is
// the one surface always on screen: a base other than HEAD changes what
// the gutter and the minimap mean, so the way back has to be reachable
// without opening anything.
//
// Built on demand from the last snapshot — which is also what decides
// the checked item, so a base that resolved to nothing (a spec reaching
// past the first commit, a sha from another repository) shows as the
// HEAD it fell back to rather than as a choice that did not take.
- (void)showReviewBaseMenu:(NSPopUpButton*)popUpButton
{
	NSMenu* menu = [NSMenu new];

	// Each item carries the KIND it selects in its tag and the spec in its
	// represented object: "HEAD~1" and a sha are both strings, but only
	// one of them means a different commit tomorrow.
	NSMenuItem* headItem = [menu addItemWithTitle:@"HEAD" action:@selector(takeReviewBaseFromMenuItem:) keyEquivalent:@""];
	headItem.target = self;
	headItem.tag    = OakReviewBaseKindHead;

	// The standing "latest commit plus uncommitted edits" view: it
	// re-resolves as HEAD moves, so an agent that commits every turn
	// leaves it showing that turn's work with nobody touching the menu.
	NSMenuItem* relativeItem = [menu addItemWithTitle:@"HEAD~1 (follows HEAD)" action:@selector(takeReviewBaseFromMenuItem:) keyEquivalent:@""];
	relativeItem.target = self;
	relativeItem.tag    = OakReviewBaseKindRelative;
	relativeItem.representedObject = @"HEAD~1";

	if(NSString* previous = lastDiffSnapshot.previousHeadCommit)
	{
		NSMenuItem* item = [menu addItemWithTitle:[NSString stringWithFormat:@"Previous HEAD (%@)", [OakReviewBase shortNameForRef:previous]] action:@selector(takeReviewBaseFromMenuItem:) keyEquivalent:@""];
		item.target = self;
		item.tag    = OakReviewBaseKindCommit;
		item.representedObject = previous;
	}

	auto const& commits = lastDiffSnapshot ? [lastDiffSnapshot recentCommits] : std::vector<scm::git_query::commit_t>();
	if(!commits.empty())
		[menu addItem:[NSMenuItem separatorItem]];
	for(auto const& commit : commits)
	{
		NSString* subject = to_ns(commit.subject);
		if(subject.length > 40)
			subject = [[subject substringToIndex:40] stringByAppendingString:@"…"];
		NSMenuItem* item = [menu addItemWithTitle:[NSString stringWithFormat:@"%@ %@", [OakReviewBase shortNameForRef:to_ns(commit.sha)], subject] action:@selector(takeReviewBaseFromMenuItem:) keyEquivalent:@""];
		item.target = self;
		item.tag    = OakReviewBaseKindCommit;
		item.representedObject = to_ns(commit.sha);
	}

	NSMenuItem* selectedItem = headItem;
	if(lastDiffSnapshot.baseKind == OakReviewBaseKindRelative)
	{
		selectedItem = relativeItem;
	}
	else if(NSString* selectedRef = lastDiffSnapshot && ![lastDiffSnapshot isBaseHead] ? [lastDiffSnapshot baseRef] : nil)
	{
		for(NSMenuItem* item in menu.itemArray)
		{
			if([item.representedObject isEqualToString:selectedRef])
			{
				selectedItem = item;
				break;
			}
		}

		// A base that is neither Previous HEAD nor among the listed commits
		// still needs an entry to show as the selection — reachable when the
		// commit list is shorter than the history the base came from.
		if(selectedItem == headItem)
		{
			NSMenuItem* item = [menu addItemWithTitle:[OakReviewBase shortNameForRef:selectedRef] action:@selector(takeReviewBaseFromMenuItem:) keyEquivalent:@""];
			item.target = self;
			item.tag    = OakReviewBaseKindCommit;
			item.representedObject = selectedRef;
			selectedItem = item;
		}
	}

	popUpButton.menu = menu;
	[popUpButton selectItem:selectedItem];
}

- (void)takeReviewBaseFromMenuItem:(NSMenuItem*)sender
{
	[self takeReviewBaseOfKind:(OakReviewBaseKind)sender.tag spec:sender.representedObject]; // spec is nil for HEAD
}

- (void)takeReviewBaseOfKind:(OakReviewBaseKind)aKind spec:(NSString*)aSpec
{
	switch(aKind)
	{
		case OakReviewBaseKindCommit:   [self.reviewBase setCommit:aSpec inRepoRoot:lastDiffRepoRoot]; break;
		case OakReviewBaseKindRelative: [self.reviewBase setRelativeSpec:aSpec];                       break;
		case OakReviewBaseKindHead:     [self.reviewBase resetToHead];                                 break;
	}
}

- (IBAction)selectNextDiffHunk:(id)sender     { [diffPaneView selectNextHunk]; }
- (IBAction)selectPreviousDiffHunk:(id)sender { [diffPaneView selectPreviousHunk]; }

- (void)updateDiffPaneVisibility
{
	BOOL const show = showDiffPane;

	if(show && !diffPaneView)
	{
		if(diffPaneWidth <= 0)
			diffPaneWidth = std::max<CGFloat>(150, round(NSWidth(textScrollView.frame) / 2));

		diffPaneView = [[DiffPaneView alloc] initWithFrame:NSZeroRect];
		diffPaneView.document = self.document;

		__weak OakDocumentView* weakSelf = self;
		diffPaneView.closeHandler = ^{
			[weakSelf hideDiffPane];
		};
		diffPaneView.moveCaretHandler = ^(NSUInteger line){
			[weakSelf moveCaretToLine:line];
		};

		// Scroller-less scroll view wrapper, mirroring the gutter and minimap:
		// a plain sibling that redraws next to OakTextView leaves the text
		// view’s giant tiled backing layer blank.
		diffPaneScrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
		diffPaneScrollView.borderType               = NSNoBorder;
		diffPaneScrollView.hasVerticalScroller      = NO;
		diffPaneScrollView.hasHorizontalScroller    = NO;
		diffPaneScrollView.verticalScrollElasticity = NSScrollElasticityNone;
		diffPaneScrollView.documentView             = diffPaneView;

		diffPaneDividerView = [[MarkdownPreviewDividerView alloc] initWithFrame:NSZeroRect];
		diffPaneDividerView.resizedView = diffPaneScrollView;
		diffPaneDividerView.widthChangeHandler = ^(CGFloat newWidth){
			[weakSelf takeDiffPaneWidthFrom:newWidth];
		};

		diffPaneScrollView.hidden  = YES; // flipped below, so the constraint pass always runs
		diffPaneDividerView.hidden = YES;

		OakAddAutoLayoutViewsToSuperview(@[ diffPaneDividerView, diffPaneScrollView ], self);
		[self updateStyle]; // seed the pane’s theme colors
	}

	if(diffPaneScrollView && diffPaneScrollView.hidden == show)
	{
		diffPaneScrollView.hidden  = !show;
		diffPaneDividerView.hidden = !show;
		[self setNeedsUpdateConstraints:YES];
	}
	diffPaneView.active = show;

	if(show)
	{
		[self pushCaretLineToDiffPane];
		[diffService updateNow]; // the pane needs a snapshot right away
	}
}

- (void)moveCaretToLine:(NSUInteger)line
{
	_textView.selectionString = [NSString stringWithFormat:@"%lu", (unsigned long)line];
	[_textView centerSelectionInVisibleArea:self];
}

- (void)pushCaretLineToDiffPane
{
	NSString* str = _textView.selectionString;
	text::selection_t const sel(to_s(str ?: @"1"));
	diffPaneView.caretLine = sel.empty() ? 1 : sel.last().to.line + 1;
}

- (void)hideDiffPane
{
	showDiffPane = NO;
	[self updateDiffPaneVisibility];
}

- (void)takeDiffPaneWidthFrom:(CGFloat)newWidth
{
	diffPaneWidth = newWidth;
	[NSUserDefaults.standardUserDefaults setDouble:newWidth forKey:@"DocumentView Diff Pane Width"];
	[self setNeedsUpdateConstraints:YES];
	[self layoutSubtreeIfNeeded]; // live resize while the divider is dragged
}

- (BOOL)validateMenuItem:(NSMenuItem*)aMenuItem
{
	if([aMenuItem action] == @selector(toggleLineNumbers:))
		[aMenuItem setTitle:[gutterView visibilityForColumnWithIdentifier:GVLineNumbersColumnIdentifier] ? @"Hide Line Numbers" : @"Show Line Numbers"];
	else if([aMenuItem action] == @selector(toggleMinimap:))
		[aMenuItem setTitle:minimapScrollView.hidden ? @"Show Minimap" : @"Hide Minimap"];
	else if([aMenuItem action] == @selector(toggleDiffPane:))
		[aMenuItem setTitle:showDiffPane ? @"Hide Diff" : @"Show Diff"];
	else if([aMenuItem action] == @selector(selectNextDiffHunk:))
		return showDiffPane && diffPaneView.canSelectNextHunk;
	else if([aMenuItem action] == @selector(selectPreviousDiffHunk:))
		return showDiffPane && diffPaneView.canSelectPreviousHunk;
	else if([aMenuItem action] == @selector(takeTabSizeFrom:))
		[aMenuItem setState:_textView.tabSize == [aMenuItem tag] ? NSControlStateValueOn : NSControlStateValueOff];
	else if([aMenuItem action] == @selector(showTabSizeSelectorPanel:))
	{
		static NSInteger const predefined[] = { 2, 3, 4, 8 };
		if(oak::contains(std::begin(predefined), std::end(predefined), _textView.tabSize))
		{
			[aMenuItem setTitle:@"Other…"];
			[aMenuItem setState:NSControlStateValueOff];
		}
		else
		{
			[aMenuItem setDynamicTitle:[NSString stringWithFormat:@"Other (%zd)…", _textView.tabSize]];
			[aMenuItem setState:NSControlStateValueOn];
		}
	}
	else if([aMenuItem action] == @selector(setIndentWithTabs:))
		[aMenuItem setState:_textView.softTabs ? NSControlStateValueOff : NSControlStateValueOn];
	else if([aMenuItem action] == @selector(setIndentWithSpaces:))
		[aMenuItem setState:_textView.softTabs ? NSControlStateValueOn : NSControlStateValueOff];
	else if([aMenuItem action] == @selector(takeGrammarUUIDFrom:))
	{
		NSString* uuidString = [aMenuItem representedObject];
		if(bundles::item_ptr bundleItem = bundles::lookup(to_s(uuidString)))
		{
			bool selectedGrammar = to_s(self.document.fileType) == bundleItem->value_for_field(bundles::kFieldGrammarScope);
			[aMenuItem setState:selectedGrammar ? NSControlStateValueOn : NSControlStateValueOff];
		}
	}
	return YES;
}

// ===================
// = Auxiliary Views =
// ===================

- (void)addAuxiliaryView:(NSView*)aView atEdge:(NSRectEdge)anEdge
{
	topAuxiliaryViews    = topAuxiliaryViews    ?: [NSMutableArray new];
	bottomAuxiliaryViews = bottomAuxiliaryViews ?: [NSMutableArray new];
	if(anEdge == NSMinYEdge)
			[bottomAuxiliaryViews addObject:aView];
	else	[topAuxiliaryViews addObject:aView];
	OakAddAutoLayoutViewsToSuperview(@[ aView ], self);
	[self setNeedsUpdateConstraints:YES];
}

- (void)removeAuxiliaryView:(NSView*)aView
{
	if([topAuxiliaryViews containsObject:aView])
		[topAuxiliaryViews removeObject:aView];
	else if([bottomAuxiliaryViews containsObject:aView])
		[bottomAuxiliaryViews removeObject:aView];
	else
		return;
	[aView removeFromSuperview];
	[self setNeedsUpdateConstraints:YES];
}

// ======================
// = Pasteboard History =
// ======================

- (void)showClipboardHistory:(id)sender
{
	OakPasteboardChooser* chooser = [OakPasteboardChooser sharedChooserForPasteboard:OakPasteboard.generalPasteboard];
	chooser.action = @selector(paste:);
	[chooser showWindowRelativeToFrame:[self.window convertRectToScreen:[_textView convertRect:[_textView visibleRect] toView:nil]]];
}

- (void)showFindHistory:(id)sender
{
	OakPasteboardChooser* chooser = [OakPasteboardChooser sharedChooserForPasteboard:OakPasteboard.findPasteboard];
	chooser.action          = @selector(findNext:);
	chooser.alternateAction = @selector(orderFrontFindPanelForProject:);
	[chooser showWindowRelativeToFrame:[self.window convertRectToScreen:[_textView convertRect:[_textView visibleRect] toView:nil]]];
}

// ==================
// = Symbol Chooser =
// ==================

- (void)selectAndCenter:(NSString*)aSelectionString
{
	_textView.selectionString = aSelectionString;
	[_textView centerSelectionInVisibleArea:self];
}

- (void)setSymbolChooser:(SymbolChooser*)aSymbolChooser
{
	if(_symbolChooser == aSymbolChooser)
		return;

	if(_symbolChooser)
	{
		[NSNotificationCenter.defaultCenter removeObserver:self name:NSWindowWillCloseNotification object:_symbolChooser.window];

		_symbolChooser.target     = nil;
		_symbolChooser.TMDocument = nil;
	}

	if(_symbolChooser = aSymbolChooser)
	{
		_symbolChooser.target          = self;
		_symbolChooser.action          = @selector(symbolChooserDidSelectItems:);
		_symbolChooser.filterString    = @"";
		_symbolChooser.TMDocument      = self.document;
		_symbolChooser.selectionString = _textView.selectionString;

		[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(symbolChooserWillClose:) name:NSWindowWillCloseNotification object:_symbolChooser.window];
	}
}

- (void)symbolChooserWillClose:(NSNotification*)aNotification
{
	self.symbolChooser = nil;
}

- (IBAction)showSymbolChooser:(id)sender
{
	self.symbolChooser = SymbolChooser.sharedInstance;
	[self.symbolChooser showWindowRelativeToFrame:[self.window convertRectToScreen:[_textView convertRect:[_textView visibleRect] toView:nil]]];
}

- (void)symbolChooserDidSelectItems:(id)sender
{
	for(id item in [sender selectedItems])
		[self selectAndCenter:[item selectionString]];
}

// =======================
// = Status bar delegate =
// =======================

- (void)takeGrammarUUIDFrom:(id)sender
{
	if(bundles::item_ptr item = bundles::lookup(to_s([sender representedObject])))
		[_textView performBundleItem:item];
}

- (void)goToSymbol:(id)sender
{
	[self selectAndCenter:[sender representedObject]];
}

- (void)showSymbolSelector:(NSPopUpButton*)symbolPopUp
{
	NSMenu* symbolMenu = symbolPopUp.menu;
	[symbolMenu removeAllItems];

	text::selection_t sel(to_s(_textView.selectionString));
	text::pos_t caret = sel.last().max();

	__block NSInteger index = 0;
	[self.document enumerateSymbolsUsingBlock:^(text::pos_t const& pos, NSString* symbol){
		if([symbol isEqualToString:@"-"])
		{
			[symbolMenu addItem:[NSMenuItem separatorItem]];
		}
		else
		{
			NSUInteger indent = 0;
			while(indent < symbol.length && [symbol characterAtIndex:indent] == 0x2003) // Em-space
				++indent;

			NSMenuItem* item = [symbolMenu addItemWithTitle:[symbol substringFromIndex:indent] action:@selector(goToSymbol:) keyEquivalent:@""];
			[item setIndentationLevel:indent];
			[item setTarget:self];
			[item setRepresentedObject:to_ns(pos)];
		}

		if(pos <= caret)
			++index;
	}];

	if(symbolMenu.numberOfItems == 0)
		[symbolMenu addItemWithTitle:@"No symbols to show for current document." action:@selector(nop:) keyEquivalent:@""];

	[symbolPopUp selectItemAtIndex:(index ? index-1 : 0)];
}

- (void)showBundlesMenu:(id)sender
{
	if(!self.statusBar)
		return NSBeep();

	[NSApp sendAction:_cmd to:self.statusBar from:self];
}

- (void)showBundleItemSelector:(NSPopUpButton*)bundleItemsPopUp
{
	NSMenu* bundleItemsMenu = bundleItemsPopUp.menu;
	[bundleItemsMenu removeAllItems];

	std::multimap<std::string, bundles::item_ptr, text::less_t> ordered;
	for(auto item : bundles::query(bundles::kFieldAny, NULL_STR, scope::wildcard, bundles::kItemTypeBundle))
		ordered.emplace(item->name(), item);

	NSMenuItem* selectedItem = nil;
	for(auto pair : ordered)
	{
		bool selectedGrammar = false;
		for(auto item : bundles::query(bundles::kFieldGrammarScope, to_s(self.document.fileType), scope::wildcard, bundles::kItemTypeGrammar, pair.second->uuid(), true, true))
			selectedGrammar = true;
		if(!selectedGrammar && pair.second->hidden_from_user() || pair.second->menu().empty())
			continue;

		NSMenuItem* menuItem = [bundleItemsMenu addItemWithTitle:[NSString stringWithCxxString:pair.first] action:NULL keyEquivalent:@""];
		menuItem.submenu = [[NSMenu alloc] initWithTitle:[NSString stringWithCxxString:pair.second->uuid()]];
		menuItem.submenu.delegate = BundleMenuDelegate.sharedInstance;

		if(selectedGrammar)
		{
			[menuItem setState:NSControlStateValueOn];
			selectedItem = menuItem;
		}
	}

	if(ordered.empty())
		[bundleItemsMenu addItemWithTitle:@"No Bundles Loaded" action:@selector(nop:) keyEquivalent:@""];

	if(selectedItem)
		[bundleItemsPopUp selectItem:selectedItem];
}

- (NSUInteger)tabSize
{
	return _textView.tabSize;
}

- (void)setTabSize:(NSUInteger)newTabSize
{
	_textView.tabSize = newTabSize;
	settings_t::set(kSettingsTabSizeKey, (size_t)newTabSize, to_s(self.document.fileType));
}

- (IBAction)takeTabSizeFrom:(id)sender
{
	ASSERT([sender respondsToSelector:@selector(tag)]);
	if([sender tag] > 0)
		self.tabSize = [sender tag];
}

- (IBAction)setIndentWithSpaces:(id)sender
{
	_textView.softTabs = YES;
	settings_t::set(kSettingsSoftTabsKey, true, to_s(self.document.fileType));
}

- (IBAction)setIndentWithTabs:(id)sender
{
	_textView.softTabs = NO;
	settings_t::set(kSettingsSoftTabsKey, false, to_s(self.document.fileType));
}

- (IBAction)showTabSizeSelectorPanel:(id)sender
{
	if(!tabSizeSelectorPanel)
		[[NSBundle bundleForClass:[self class]] loadNibNamed:@"TabSizeSetting" owner:self topLevelObjects:NULL];
	[tabSizeSelectorPanel makeKeyAndOrderFront:self];
}

- (void)toggleMacroRecording:(id)sender    { [_textView toggleMacroRecording:sender]; }

// =============================
// = GutterView Delegate Proxy =
// =============================

- (GVLineRecord)lineRecordForPosition:(CGFloat)yPos                              { return [_textView lineRecordForPosition:yPos];               }
- (GVLineRecord)lineFragmentForLine:(NSUInteger)aLine column:(NSUInteger)aColumn { return [_textView lineFragmentForLine:aLine column:aColumn]; }

// =========================
// = Cursor Line Tracking  =
// =========================

- (void)invalidateCodeActionProbe
{
	_cursorLineHasActions = NO;
	++_probeGeneration;
	[NSNotificationCenter.defaultCenter postNotificationName:GVColumnDataSourceDidChange object:self];
}

- (void)updateCursorLine:(NSUInteger)line
{
	if(_cursorLine == line)
		return;

	NSUInteger oldLine = _cursorLine;
	_cursorLine = line;
	_cursorLineHasActions = NO;
	++_probeGeneration;

	// Redraw gutter for old line (remove lightbulb) and new line
	if(oldLine != NSNotFound || line != NSNotFound)
		[NSNotificationCenter.defaultCenter postNotificationName:GVColumnDataSourceDidChange object:self];

	// Check if new cursor line has diagnostics — if so, probe server for actions
	if(line == NSNotFound)
		return;

	OakDocument* doc = self.document;
	if(!doc)
		return;

	auto const settings = settings_for_path(doc.virtualPath ? to_s(doc.virtualPath) : to_s(doc.path), to_s(doc.fileType), to_s(doc.directory ?: @""));
	if(!settings.get(kSettingsLSPCodeActionsKey, true))
		return;

	LSPManager* lsp = [LSPManager sharedManager];
	if(![lsp serverSupportsCodeActionsForDocument:doc])
		return;

	__block BOOL hasDiagnostic = NO;
	[doc enumerateBookmarksAtLine:line block:^(text::pos_t const& pos, NSString* type, NSString* payload){
		if([type isEqualToString:@"error"] || [type isEqualToString:@"warning"] || [type isEqualToString:@"note"])
			hasDiagnostic = YES;
	}];

	if(!hasDiagnostic)
		return;

	// Probe server for available actions on this line
	NSUInteger generation = _probeGeneration;
	__weak OakDocumentView* weakSelf = self;
	[lsp requestCodeActionsForDocument:doc
		line:line character:0
		endLine:line endCharacter:0
		completion:^(NSArray<NSDictionary*>* actions) {
			dispatch_async(dispatch_get_main_queue(), ^{
				OakDocumentView* strongSelf = weakSelf;
				if(!strongSelf || strongSelf->_probeGeneration != generation)
					return;
				strongSelf->_cursorLineHasActions = actions.count > 0;
				if(strongSelf->_cursorLineHasActions)
					[NSNotificationCenter.defaultCenter postNotificationName:GVColumnDataSourceDidChange object:strongSelf];
			});
		}];
}

// =========================
// = GutterView DataSource =
// =========================

- (CGFloat)widthForColumnWithIdentifier:(id)columnIdentifier
{
	if([columnIdentifier isEqualToString:kDiffMarksColumnIdentifier])
		return kDiffMarksColumnWidth; // a bar, not an icon — independent of the line height
	return floor((self.lineHeight-1) / 2) * 2 + 1;
}

// The buffer-vs-review-base change bars. Drawn rather than imaged: the
// bar spans the row edge to edge and carries its own color, neither of
// which the image path (centered on the cap height, tinted with the
// gutter's icon color) can express. This column is hidden whenever the
// bars are off, so there is nothing here for the quieter presentation to
// do — that one is the bookmark column's icons.
//
// A deletion has no line of its own — the mark sits on the line PRECEDING
// the deletion site — so it draws as a tick on that line's lower boundary
// instead of a bar, and only on a soft-wrapped line's last fragment,
// where the boundary actually is.
- (BOOL)drawColumnWithIdentifier:(id)columnIdentifier inRect:(NSRect)aRect forLine:(NSUInteger)aLine
{
	if(![columnIdentifier isEqualToString:kDiffMarksColumnIdentifier])
		return NO;

	__block NSColor* color = nil;
	__block BOOL isDeletion = NO;
	[self.document enumerateBookmarksAtLine:aLine block:^(text::pos_t const& pos, NSString* type, NSString* payload){
		if([type isEqualToString:@"diff.added"])
			color = diffAddedColor;
		else if([type isEqualToString:@"diff.modified"])
			color = diffModifiedColor;
		else if([type isEqualToString:@"diff.deleted"])
			color = diffDeletedColor, isDeletion = YES;
	}];

	if(!color)
		return YES; // ours to draw, and there is nothing on this line

	if(isDeletion)
	{
		// The tick belongs on the line's lower boundary, so on a wrapped
		// line it draws only on the last fragment. We are also the gutter's
		// delegate, so we can ask what sits just past this fragment's bottom
		// edge: another fragment of the same line means this is not the last
		// one.
		//
		// Comparing the line number alone is not enough at end of document.
		// index_at_point clamps a y at or beyond the final row back to that
		// row, so on the buffer's LAST line the lookup past the bottom edge
		// returns this same line — and the tick, which lands on the last
		// line whenever trailing lines are deleted, would be skipped forever.
		// The softline offset tells the two apart: a real next fragment has
		// a larger one, while the clamp returns this fragment's own.
		GVLineRecord const here = [self lineRecordForPosition:NSMinY(aRect)];
		GVLineRecord const below = [self lineRecordForPosition:NSMaxY(aRect)];
		if(below.lineNumber == aLine && below.softlineOffset > here.softlineOffset)
			return YES;

		[color set];
		NSRectFill(NSMakeRect(NSMinX(aRect), NSMaxY(aRect) - kDiffMarksTickHeight, NSWidth(aRect), kDiffMarksTickHeight));
	}
	else
	{
		[color set];
		NSRectFill(NSMakeRect(NSMaxX(aRect) - kDiffMarksBarWidth, NSMinY(aRect), kDiffMarksBarWidth, NSHeight(aRect)));
	}
	return YES;
}

- (NSImage*)imageForLine:(NSUInteger)lineNumber inColumnWithIdentifier:(id)columnIdentifier state:(GutterViewRowState)rowState
{
	if([columnIdentifier isEqualToString:kBookmarksColumnIdentifier])
	{
		// Show lightbulb only when server confirmed actions are available for this line
		if(lineNumber == _cursorLine && _cursorLineHasActions)
		{
			NSImage* img = [NSImage imageWithSystemSymbolName:@"lightbulb.fill" accessibilityDescription:@"Code Actions"];
			if(img)
			{
				CGFloat size = floor((self.lineHeight - 1) / 2) * 2 + 1;
				NSImageSymbolConfiguration* config = [NSImageSymbolConfiguration configurationWithPointSize:size * 0.5 weight:NSFontWeightRegular];
				return [img imageWithSymbolConfiguration:config];
			}
		}

		__block std::map<size_t, NSString*> gutterImageName;

		[self.document enumerateBookmarksAtLine:lineNumber block:^(text::pos_t const& pos, NSString* type, NSString* payload){
			if(payload.length != 0)
				gutterImageName.emplace(0, type);
			else if([type isEqualToString:OakDocumentBookmarkIdentifier])
				gutterImageName.emplace(1, rowState != GutterViewRowStateRegular ? @"Bookmark Hover Remove Template" : @"Bookmark Template");
			else if(rowState == GutterViewRowStateRegular && [self shouldDrawMarkTypeAsGutterImage:type])
				gutterImageName.emplace(2, type); // a mark type doubling as an image name
		}];

		if(rowState != GutterViewRowStateRegular)
			gutterImageName.emplace(3, @"Bookmark Hover Add Template");

		if(!gutterImageName.empty())
			return [self gutterImage:gutterImageName.begin()->second];
	}
	else if([columnIdentifier isEqualToString:kFoldingsColumnIdentifier])
	{
		switch([_textView foldingStateForLine:lineNumber])
		{
			case kFoldingTop:       return [self gutterImage:rowState == GutterViewRowStateRegular ? @"Folding Top Template"       : @"Folding Top Hover Template"];
			case kFoldingCollapsed: return [self gutterImage:rowState == GutterViewRowStateRegular ? @"Folding Collapsed Template" : @"Folding Collapsed Hover Template"];
			case kFoldingBottom:    return [self gutterImage:rowState == GutterViewRowStateRegular ? @"Folding Bottom Template"    : @"Folding Bottom Hover Template"];
		}
	}
	return nil;
}

// =============================
// = Bookmark Submenu Delegate =
// =============================

- (void)takeBookmarkFrom:(id)sender
{
	if([sender respondsToSelector:@selector(representedObject)])
		[self selectAndCenter:[sender representedObject]];
}

- (void)updateBookmarksMenu:(NSMenu*)aMenu
{
	[self.document enumerateBookmarksUsingBlock:^(text::pos_t const& pos, NSString* excerpt){
		NSString* prefix = to_ns(text::pad(pos.line+1, 4) + ": ");
		NSMenuItem* item = [aMenu addItemWithTitle:[prefix stringByAppendingString:excerpt] action:@selector(takeBookmarkFrom:) keyEquivalent:@""];
		[item setRepresentedObject:to_ns(pos)];
	}];

	BOOL hasBookmarks = aMenu.numberOfItems;
	if(hasBookmarks)
		[aMenu addItem:[NSMenuItem separatorItem]];
	[aMenu addItemWithTitle:@"Clear Bookmarks" action:hasBookmarks ? @selector(clearAllBookmarks:) : @selector(nop:) keyEquivalent:@""];
}

// =======================
// = GutterView Delegate =
// =======================

- (void)userDidClickColumnWithIdentifier:(id)columnIdentifier atLine:(NSUInteger)lineNumber
{
	if([columnIdentifier isEqualToString:kBookmarksColumnIdentifier])
	{
		// Lightbulb click triggers code actions
		if(lineNumber == _cursorLine && _cursorLineHasActions)
		{
			[_textView lspCodeActions:self];
			return;
		}

		__block std::vector<text::pos_t> bookmarks;
		__block NSMutableArray* content = [NSMutableArray array];

		[self.document enumerateBookmarksAtLine:lineNumber block:^(text::pos_t const& pos, NSString* type, NSString* payload){
			if(payload.length != 0)
				[content addObject:payload];
			else if([type isEqualToString:OakDocumentBookmarkIdentifier])
				bookmarks.push_back(pos);
		}];

		if(content.count == 0)
		{
			if(bookmarks.empty())
					[self.document setMarkOfType:OakDocumentBookmarkIdentifier atPosition:text::pos_t(lineNumber, 0) content:nil];
			else	[self.document removeMarkOfType:OakDocumentBookmarkIdentifier atPosition:bookmarks.front()];
		}
		else
		{
			NSView* popoverContainerView = [[NSView alloc] initWithFrame:NSZeroRect];

			NSTextField* textField = OakCreateLabel([content componentsJoinedByString:@"\n"]);
			OakAddAutoLayoutViewsToSuperview(@[ textField ], popoverContainerView);

			NSDictionary* views = NSDictionaryOfVariableBindings(textField);
			[popoverContainerView addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:|-(5)-[textField]-(5)-|" options:0 metrics:0 views:views]];
			[popoverContainerView addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"V:|-(10)-[textField]-(10)-|" options:0 metrics:0 views:views]];

			NSViewController* viewController = [NSViewController new];
			viewController.view = popoverContainerView;

			NSPopover* popover = [NSPopover new];
			popover.behavior = NSPopoverBehaviorTransient;
			popover.contentViewController = viewController;

			GVLineRecord record = [self lineFragmentForLine:lineNumber column:0];
			NSRect rect = NSMakeRect(0, record.firstY, [self widthForColumnWithIdentifier:columnIdentifier], record.lastY - record.firstY);
			[popover showRelativeToRect:rect ofView:gutterView preferredEdge:NSMaxXEdge];
		}
	}
	else if([columnIdentifier isEqualToString:kFoldingsColumnIdentifier])
	{
		[_textView toggleFoldingAtLine:lineNumber recursive:OakIsAlternateKeyOrMouseEvent()];
		[NSNotificationCenter.defaultCenter postNotificationName:GVColumnDataSourceDidChange object:self];
	}
}

- (void)clearAllBookmarks:(id)sender
{
	[self.document removeAllMarksOfType:OakDocumentBookmarkIdentifier];
}

- (void)documentMarksDidChange:(NSNotification*)aNotification
{
	[NSNotificationCenter.defaultCenter postNotificationName:GVColumnDataSourceDidChange object:self];
	[minimapView documentMarksDidChange];
}

- (void)documentContentDidChange:(NSNotification*)notification
{
	[LSPManager.sharedManager documentDidChange:notification.object];
	[[CopilotManager sharedManager] documentDidChange:notification.object];
	[minimapView documentContentDidChange];
}

- (void)documentDidSave:(NSNotification*)notification
{
	[LSPManager.sharedManager documentDidSave:notification.object];
	[[CopilotManager sharedManager] documentDidSave:notification.object];
}

- (void)documentWillClose:(NSNotification*)notification
{
	[LSPManager.sharedManager documentWillClose:notification.object];
	[[CopilotManager sharedManager] documentWillClose:notification.object];
	[minimapView setDocument:nil]; // detach buffer callback before the document deletes its buffer
	[diffPaneView setDocument:nil];
	[diffService setDocument:nil];
}

// =======================
// = LSP Status Bar      =
// =======================

- (void)updateLSPStatusBar
{
	if(!_statusBar)
		return;

	LSPManager* lsp = [LSPManager sharedManager];
	OakDocument* doc = self.document;

	// The indicator is visible whenever the global lspEnabled master switch
	// (AI preference pane) is on, showing the idle look while no server is
	// attached to the current document.
	BOOL lspMasterEnabled = settings_for_path().get("lspEnabled", true);

	NSString* status = [lsp serverStatusForDocument:doc];
	NSDictionary<NSString*, NSNumber*>* counts = [lsp diagnosticCountsForDocument:doc];

	[_statusBar setLspEnabled:lspMasterEnabled
	                   status:status
	               serverName:[lsp serverNameForDocument:doc]
	                   errors:[counts[@"errors"] unsignedIntegerValue]
	                 warnings:[counts[@"warnings"] unsignedIntegerValue]
	                     info:[counts[@"info"] unsignedIntegerValue]];

	[_statusBar setCopilotStatus:[CopilotManager sharedManager].status];
}

- (void)lspDiagnosticsDidChange:(NSNotification*)notification
{
	if(!_statusBar || !self.document)
		return;

	NSString* uri = notification.userInfo[@"uri"];
	if(uri)
	{
		NSURL* fileURL = self.document.path ? [NSURL fileURLWithPath:self.document.path] : nil;
		if(fileURL && ![uri isEqualToString:fileURL.absoluteString])
			return;
	}

	[self updateLSPStatusBar];
}

- (void)lspServerStatusDidChange:(NSNotification*)notification
{
	// The AI pane's master switch asks visible documents to reconnect when it
	// turns LSP back on (documentDidOpen: is idempotent and re-checks the
	// effective settings). Deliberately flag-gated: reattaching on EVERY
	// status notification would turn a crashing server into a restart loop,
	// since lspClientDidTerminate: also dissociates documents and posts here.
	if([notification.userInfo[@"reconnectDocuments"] boolValue] && self.document)
		[LSPManager.sharedManager documentDidOpen:self.document];

	[self updateLSPStatusBar];
}

- (void)lspShowMessage:(NSNotification*)notification
{
	NSNumber* type = notification.userInfo[@"type"];
	if(type && type.intValue == 1 && _statusBar)
		[_statusBar flashLspError];
}

// Status changes surface only through the status-bar indicator: its tint and
// tooltip cover every state, and the quick menu links to the AI pane for
// sign-in. A floating toast on connect would tell the user nothing the
// indicator doesn’t already show.
- (void)copilotStatusDidChange:(NSNotification*)notification
{
	[_statusBar setCopilotStatus:[CopilotManager sharedManager].status];
}

// The Copilot indicator’s quick menu: the global on/off switch, a server
// restart, and a shortcut to the AI preference pane — sign in/out and the
// ghost-text flag live on that pane. The status itself stays visible via the
// indicator tint and tooltip. The checkmark reads the effective global
// setting fresh each time the menu opens; the same key is written by the AI
// pane, both through settings_t::set (a project’s .tm_properties can still
// override it per directory, file type, or scope).
- (void)showCopilotStatusMenu:(NSPopUpButton*)popUpButton
{
	// The popup cell marks its selected item with a checkmark by default,
	// which would permanently check the first item; the checkmark on the
	// toggle below must reflect the setting alone.
	((NSPopUpButtonCell*)popUpButton.cell).altersStateOfSelectedItem = NO;

	NSMenu* menu = popUpButton.menu;
	[menu removeAllItems];

	NSMenuItem* copilotItem = [[NSMenuItem alloc] initWithTitle:@"Copilot" action:@selector(toggleCopilotEnabled:) keyEquivalent:@""];
	copilotItem.target = self;
	copilotItem.state = settings_for_path().get("copilotEnabled", false) ? NSControlStateValueOn : NSControlStateValueOff;
	[menu addItem:copilotItem];

	[menu addItem:[NSMenuItem separatorItem]];

	NSMenuItem* restartItem = [[NSMenuItem alloc] initWithTitle:@"Restart Server" action:@selector(copilotRestart:) keyEquivalent:@""];
	restartItem.target = self;
	[menu addItem:restartItem];

	[menu addItem:[NSMenuItem separatorItem]];

	NSMenuItem* settingsItem = [[NSMenuItem alloc] initWithTitle:@"AI Settings…" action:@selector(showAISettings:) keyEquivalent:@""];
	settingsItem.target = self;
	[menu addItem:settingsItem];
}

- (void)copilotRestart:(id)sender
{
	CopilotManager* copilot = [CopilotManager sharedManager];
	[copilot shutdown];
	[copilot reloadSettings];
	if(self.document)
		[copilot documentDidOpen:self.document];
}

- (void)toggleCopilotEnabled:(id)sender
{
	bool enable = !settings_for_path().get("copilotEnabled", false);
	settings_t::set("copilotEnabled", enable); // invalidates the settings cache synchronously, so the reads below see the new value

	CopilotManager* copilot = [CopilotManager sharedManager];
	[copilot reloadSettings];
	if(enable)
	{
		if(self.document)
			[copilot documentDidOpen:self.document];

		// The client may already be running unauthenticated (e.g. started via
		// a per-project copilotEnabled override); start the sign-in flow right
		// away so the toggle is never a dead switch. A freshly started client
		// reports auth asynchronously and posts its own notification instead.
		if(copilot.status == CopilotStatusAuthRequired)
			[copilot signIn];
	}
}

- (void)showAISettings:(id)sender
{
	[Preferences.sharedInstance selectPaneWithIdentifier:@"AI"];
}

// The LSP indicator’s menu: a per-file-type on/off switch (written as a
// scope-selector section in the global settings file, e.g.
// “[ source.go ] lspEnabled = false”), then the server actions. The global
// master switch lives on the AI preference pane; a project’s .tm_properties
// still outranks both (established settings precedence). The toggle state is
// read fresh each time the menu opens.
- (void)showLSPStatusMenu:(NSPopUpButton*)popUpButton
{
	// Keep the popup cell from force-checking its selected (first) item — the
	// checkmark must reflect the setting alone.
	((NSPopUpButtonCell*)popUpButton.cell).altersStateOfSelectedItem = NO;

	LSPManager* lsp = [LSPManager sharedManager];
	OakDocument* doc = self.document;
	NSMenu* menu = popUpButton.menu;
	[menu removeAllItems];

	NSString* serverName = [lsp serverNameForDocument:doc];
	NSString* status = [lsp serverStatusForDocument:doc];

	if(serverName)
	{
		// No status suffix in the steady state — only abnormal/transient
		// states; the full status stays in the indicator tooltip.
		NSString* title = [NSString stringWithFormat:@"LSP — %@", serverName];
		if([status isEqualToString:@"starting"])
			title = [title stringByAppendingString:@" (starting…)"];
		else if([status isEqualToString:@"indexing"])
			title = [title stringByAppendingString:@" (indexing…)"];
		else if([status isEqualToString:@"unavailable"])
			title = [title stringByAppendingString:@" (not installed)"];

		NSMenuItem* toggleItem = [[NSMenuItem alloc] initWithTitle:title action:@selector(toggleLSPEnabledForFileType:) keyEquivalent:@""];
		toggleItem.target = self;
		toggleItem.state = [lsp lspEnabledForDocument:doc] ? NSControlStateValueOn : NSControlStateValueOff;
		[menu addItem:toggleItem];
	}
	else
	{
		NSMenuItem* header = [[NSMenuItem alloc] initWithTitle:@"LSP — No Server for This File Type" action:nil keyEquivalent:@""];
		header.enabled = NO;
		[menu addItem:header];
	}

	if(status)
	{
		[menu addItem:[NSMenuItem separatorItem]];
		NSMenuItem* restart = [[NSMenuItem alloc] initWithTitle:@"Restart Server" action:@selector(lspRestartServer:) keyEquivalent:@""];
		restart.target = self;
		[menu addItem:restart];

		// With no live client there is no workspace to re-index; Restart
		// Server doubles as the retry after installing the missing binary.
		if(![status isEqualToString:@"unavailable"])
		{
			NSMenuItem* reindex = [[NSMenuItem alloc] initWithTitle:@"Re-index Workspace" action:@selector(lspReindexWorkspace:) keyEquivalent:@""];
			reindex.target = self;
			[menu addItem:reindex];
		}
	}

	NSDictionary* counts = [lsp diagnosticCountsForDocument:doc];
	NSUInteger errors   = [counts[@"errors"] unsignedIntegerValue];
	NSUInteger warnings = [counts[@"warnings"] unsignedIntegerValue];
	NSUInteger info     = [counts[@"info"] unsignedIntegerValue];

	if(errors + warnings + info > 0)
	{
		[menu addItem:[NSMenuItem separatorItem]];

		NSMenuItem* next = [[NSMenuItem alloc] initWithTitle:@"Next Diagnostic" action:@selector(lspNextDiagnostic:) keyEquivalent:@""];
		next.target = self;
		[menu addItem:next];

		NSMenuItem* prev = [[NSMenuItem alloc] initWithTitle:@"Previous Diagnostic" action:@selector(lspPrevDiagnostic:) keyEquivalent:@""];
		prev.target = self;
		[menu addItem:prev];
	}
}

- (void)toggleLSPEnabledForFileType:(id)sender
{
	OakDocument* document = self.document;
	if(!document.fileType)
		return;

	bool enable = ![LSPManager.sharedManager lspEnabledForDocument:document];

	// Write the override as a scope-selector section in the global settings
	// file (“[ source.go ] lspEnabled = false”) via settings_t::set’s exact
	// section parameter — the same mechanism the file-type association uses
	// for its glob sections. Re-enabling removes the override (NULL_STR
	// deletes the assignment) so the value falls back to the global master
	// switch instead of pinning a scoped “true” that would outrank it.
	if(enable)
			settings_t::set("lspEnabled", std::string(NULL_STR), NULL_STR, to_s(document.fileType));
	else	settings_t::set("lspEnabled", std::string("false"), NULL_STR, to_s(document.fileType));

	// set() invalidates the settings cache synchronously, so the manager
	// reads the new value here
	if(enable)
			[LSPManager.sharedManager documentDidOpen:document];   // other documents of this type reattach lazily on focus
	else	[LSPManager.sharedManager stopServerForDocument:document];
	[self updateLSPStatusBar];
}

- (void)lspRestartServer:(id)sender
{
	[[LSPManager sharedManager] restartServerForDocument:self.document];
}

- (void)lspReindexWorkspace:(id)sender
{
	[[LSPManager sharedManager] reindexWorkspaceForDocument:self.document];
}

- (void)lspNextDiagnostic:(id)sender
{
	NSArray<NSString*>* types = @[ @"error", @"warning", @"note" ];
	text::selection_t sel(to_s(_textView.selectionString));
	text::pos_t caret = sel.last().max();
	text::pos_t next = [self.document nextMarkOfTypes:types fromPosition:caret];
	if(next != text::pos_t::undefined)
	{
		_textView.selectionString = to_ns(next);
		[_textView centerSelectionInVisibleArea:self];
	}
}

- (void)lspPrevDiagnostic:(id)sender
{
	NSArray<NSString*>* types = @[ @"error", @"warning", @"note" ];
	text::selection_t sel(to_s(_textView.selectionString));
	text::pos_t caret = sel.last().max();
	text::pos_t prev = [self.document prevMarkOfTypes:types fromPosition:caret];
	if(prev != text::pos_t::undefined)
	{
		_textView.selectionString = to_ns(prev);
		[_textView centerSelectionInVisibleArea:self];
	}
}

// ============
// = Printing =
// ============

- (void)printDocument:(id)sender
{
	[self.document runPrintOperationModalForWindow:self.window fontName:_textView.font.fontName];
}
@end
