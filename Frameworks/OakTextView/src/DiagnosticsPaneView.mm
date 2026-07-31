#import "DiagnosticsPaneView.h"
#import <layout/ct.h>
#import <ns/ns.h>

static CGFloat const kPaneHeaderHeight = 24;
static CGFloat const kFileRowHeight    = 20;
static CGFloat const kEntryIndent      = 18;
static CGFloat const kRowPadding       = 6;
static CGFloat const kEntryRowInset    = 2; // above and below the wrapped text

// Same derivation the diff pane uses: theme colors blended toward the
// background rather than system label colors, which ignore the editor theme.
static NSColor* BlendedColor (NSColor* from, NSColor* toward, CGFloat fraction)
{
	NSColor* a = [from colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
	NSColor* b = [toward colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
	if(!a || !b)
		return from;
	return [NSColor colorWithSRGBRed:a.redComponent   + fraction * (b.redComponent   - a.redComponent)
	                           green:a.greenComponent + fraction * (b.greenComponent - a.greenComponent)
	                            blue:a.blueComponent  + fraction * (b.blueComponent  - a.blueComponent)
	                           alpha:1];
}

static NSColor* SeverityColor (NSInteger severity)
{
	return [NSColor colorWithCGColor:ct::diagnostic_color(severity)] ?: NSColor.textColor;
}

// “3 errors, 1 warning” — only the non-zero kinds, singular where it applies.
static NSString* CountsSummary (NSUInteger errors, NSUInteger warnings, NSUInteger notes)
{
	NSMutableArray<NSString*>* parts = [NSMutableArray new];
	if(errors)
		[parts addObject:[NSString stringWithFormat:@"%lu error%@", (unsigned long)errors, errors == 1 ? @"" : @"s"]];
	if(warnings)
		[parts addObject:[NSString stringWithFormat:@"%lu warning%@", (unsigned long)warnings, warnings == 1 ? @"" : @"s"]];
	if(notes)
		[parts addObject:[NSString stringWithFormat:@"%lu note%@", (unsigned long)notes, notes == 1 ? @"" : @"s"]];
	return [parts componentsJoinedByString:@", "];
}

// =========
// = Model =
// =========

// One row per diagnostic. The attributed text is built once per rebuild
// because the row height is measured from it, and measuring is the expensive
// part of a large snapshot.
@interface DiagnosticsPaneRow : NSObject
@property (nonatomic) LSPDiagnosticEntry* entry;
@property (nonatomic) NSString* path;
@property (nonatomic) NSAttributedString* text;
@end

@implementation DiagnosticsPaneRow
@end

// Counts describe the rows actually listed, so they follow the filter — the
// snapshot's own per-file counts describe the unfiltered set.
@interface DiagnosticsPaneGroup : NSObject
@property (nonatomic) NSString* path;
@property (nonatomic) NSString* displayPath;
@property (nonatomic) NSArray<DiagnosticsPaneRow*>* rows;
@property (nonatomic) NSUInteger errorCount;
@property (nonatomic) NSUInteger warningCount;
@property (nonatomic) NSUInteger noteCount;
@property (nonatomic) NSString* summary;
@end

@implementation DiagnosticsPaneGroup
@end

// ==============
// = Cell views =
// ==============

@interface DiagnosticsFileCellView : NSTableCellView
@end

@implementation DiagnosticsFileCellView
- (void)layout
{
	[super layout];
	NSRect const bounds = self.bounds;
	CGFloat const iconSize = 14;
	self.imageView.frame = NSMakeRect(0, round((NSHeight(bounds) - iconSize) / 2), iconSize, iconSize);
	self.textField.frame = NSMakeRect(iconSize + 4, 0, std::max<CGFloat>(0, NSWidth(bounds) - iconSize - 4), NSHeight(bounds));
}
@end

@interface DiagnosticsEntryCellView : NSTableCellView
@end

@implementation DiagnosticsEntryCellView
- (void)layout
{
	[super layout];
	self.textField.frame = NSMakeRect(0, kEntryRowInset, NSWidth(self.bounds), std::max<CGFloat>(0, NSHeight(self.bounds) - 2*kEntryRowInset));
}
@end

// ========
// = Pane =
// ========

@interface DiagnosticsPaneView () <NSOutlineViewDataSource, NSOutlineViewDelegate>
@end

@implementation DiagnosticsPaneView
{
	NSTextField*         _headerField;
	NSButton*            _closeButton;
	NSSegmentedControl*  _filterControl;
	NSScrollView*        _listScrollView;
	NSOutlineView*       _outlineView;
	NSTextField*         _emptyStateField;

	LSPDiagnosticsSnapshot* _snapshot;
	NSArray<DiagnosticsPaneGroup*>* _groups;

	NSMutableSet<NSString*>* _collapsedPaths; // default is expanded, so this records the exceptions

	NSColor* _primaryColor;
	NSColor* _dimColor;

	// Wrapped messages make row heights width-dependent; measuring is by far
	// the most expensive thing a large snapshot does, so it happens once per
	// (row, width) and is thrown away when the width changes.
	NSMapTable<DiagnosticsPaneRow*, NSNumber*>* _heightCache;
	CGFloat _measuredWidth;
	NSUInteger _heightInvalidationGeneration;
}

// Re-noting every row's height makes the outline view re-measure the whole
// list, and the divider drag calls -layout on every step — so a drag over a few
// thousand rows would be thousands of text measurements per mouse event. Wait
// for the width to settle instead. The rows keep their old heights until it
// does, which is a lag rather than a wrong answer.
- (void)scheduleHeightInvalidation
{
	NSUInteger const generation = ++_heightInvalidationGeneration;

	__weak DiagnosticsPaneView* weakSelf = self;
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		DiagnosticsPaneView* strongSelf = weakSelf;
		if(strongSelf)
			[strongSelf applyHeightInvalidationForGeneration:generation];
	});
}

- (void)applyHeightInvalidationForGeneration:(NSUInteger)generation
{
	if(generation != _heightInvalidationGeneration || !_outlineView)
		return;

	[_outlineView noteHeightOfRowsWithIndexesChanged:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, _outlineView.numberOfRows)]];
}

- (id)initWithFrame:(NSRect)aRect
{
	if(self = [super initWithFrame:aRect])
	{
		_collapsedPaths = [NSMutableSet new];
		_heightCache    = [NSMapTable strongToStrongObjectsMapTable];
		_groups         = @[];
	}
	return self;
}

// Like the gutter, minimap and diff pane, the pane lives inside a
// scroller-less NSScrollView: a plain sibling that redraws next to
// OakTextView leaves the text view's giant tiled backing layer blank.
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

- (void)dealloc
{
	[NSNotificationCenter.defaultCenter removeObserver:self];
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

// The scroll view covers everything below the header strip; the strip itself
// is bare view, so paint the theme background and a hairline under it or the
// window background shows through.
- (void)drawRect:(NSRect)aRect
{
	NSColor* background = _themeBackgroundColor ?: NSColor.textBackgroundColor;
	NSColor* foreground = _themeForegroundColor ?: NSColor.textColor;

	[background set];
	NSRectFill(aRect);

	NSRect stripRect, contentRect;
	NSDivideRect(self.bounds, &stripRect, &contentRect, kPaneHeaderHeight, NSMaxYEdge);
	[BlendedColor(foreground, background, 0.85) set];
	NSRectFill(NSMakeRect(NSMinX(stripRect), NSMinY(stripRect), NSWidth(stripRect), 1));
}

// Runs on a torn-down pane too — the hosting view lays out whether or not the
// pane is active. Every control is nil then and the messages below no-op.
- (void)layout
{
	[super layout];

	NSRect headerRect, contentRect;
	NSDivideRect(self.bounds, &headerRect, &contentRect, kPaneHeaderHeight, NSMaxYEdge);
	self.needsDisplay = YES;

	CGFloat const edgeMargin = 8;
	CGFloat const sectionGap = 10;

	auto place = [](NSControl* control, NSRect strip, CGFloat x, NSSize size) -> NSRect {
		NSRect alignmentRect = NSMakeRect(x, NSMinY(strip) + round((NSHeight(strip) - size.height) / 2), size.width, size.height);
		control.frame = [control frameForAlignmentRect:alignmentRect];
		return alignmentRect;
	};

	CGFloat x = NSMinX(headerRect) + edgeMargin;
	NSRect const closeRect = place(_closeButton, headerRect, x, NSMakeSize(16, 16));
	x = NSMaxX(closeRect) + sectionGap;

	CGFloat titleRight = NSMaxX(headerRect) - edgeMargin;
	if(_filterControl)
	{
		[_filterControl sizeToFit];
		NSSize const filterSize = [_filterControl alignmentRectForFrame:(NSRect){ NSZeroPoint, _filterControl.frame.size }].size;
		NSRect const filterRect = place(_filterControl, headerRect, titleRight - filterSize.width, filterSize);
		titleRight = NSMinX(filterRect) - sectionGap;
	}

	[_headerField sizeToFit];
	place(_headerField, headerRect, x, NSMakeSize(std::max<CGFloat>(0, titleRight - x), NSHeight(_headerField.frame)));

	_listScrollView.frame = contentRect;
	_emptyStateField.frame = NSMakeRect(NSMinX(contentRect) + 12, NSMaxY(contentRect) - 34, std::max<CGFloat>(0, NSWidth(contentRect) - 24), 20);

	if(_outlineView)
	{
		CGFloat const width = NSWidth(_listScrollView.contentView.bounds);
		if(_outlineView.tableColumns.firstObject.width != width)
			_outlineView.tableColumns.firstObject.width = width;

		// Narrowing the pane re-wraps every message, so the cached heights stop
		// being answers to the question being asked.
		if(width != _measuredWidth)
		{
			_measuredWidth = width;
			[_heightCache removeAllObjects];
			[self scheduleHeightInvalidation];
		}
	}
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
		[self rebuildRows];
	}
	else
	{
		[_listScrollView removeFromSuperview];
		[_emptyStateField removeFromSuperview];
		[_headerField removeFromSuperview];
		[_closeButton removeFromSuperview];
		[_filterControl removeFromSuperview];

		_listScrollView  = nil;
		_outlineView     = nil;
		_emptyStateField = nil;
		_headerField     = nil;
		_closeButton     = nil;
		_filterControl   = nil;

		_snapshot = nil;
		_groups   = @[];
		[_heightCache removeAllObjects];
		_measuredWidth = 0;
	}
}

- (void)createSubviewsIfNeeded
{
	if(_listScrollView)
		return;

	_closeButton = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"xmark.circle.fill" accessibilityDescription:@"Close Diagnostics"] target:self action:@selector(didClickClose:)];
	_closeButton.bordered = NO;
	_closeButton.toolTip  = @"Close diagnostics";

	_headerField = [[NSTextField alloc] initWithFrame:NSZeroRect];
	_headerField.bordered        = NO;
	_headerField.editable        = NO;
	_headerField.selectable      = NO;
	_headerField.bezeled         = NO;
	_headerField.drawsBackground = NO;
	_headerField.font            = [NSFont systemFontOfSize:[NSFont systemFontSizeForControlSize:NSControlSizeSmall]];
	[[_headerField cell] setLineBreakMode:NSLineBreakByTruncatingTail];

	_filterControl = [NSSegmentedControl segmentedControlWithLabels:@[ @"All", @"Errors" ] trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(didChangeFilter:)];
	_filterControl.controlSize      = NSControlSizeSmall;
	// controlSize alone does not shrink a segmented control’s label font
	_filterControl.font             = [NSFont systemFontOfSize:[NSFont systemFontSizeForControlSize:NSControlSizeSmall]];
	_filterControl.segmentStyle     = NSSegmentStyleRounded;
	_filterControl.selectedSegment  = _errorsOnly ? 1 : 0;
	_filterControl.toolTip          = @"Show all reported diagnostics, or errors only";

	_emptyStateField = [[NSTextField alloc] initWithFrame:NSZeroRect];
	_emptyStateField.bordered        = NO;
	_emptyStateField.editable        = NO;
	_emptyStateField.selectable      = NO;
	_emptyStateField.bezeled         = NO;
	_emptyStateField.drawsBackground = NO;
	_emptyStateField.font            = [NSFont systemFontOfSize:[NSFont systemFontSizeForControlSize:NSControlSizeSmall]];
	_emptyStateField.hidden          = YES;

	NSTableColumn* column = [[NSTableColumn alloc] initWithIdentifier:@"diagnostic"];
	column.resizingMask = NSTableColumnAutoresizingMask;

	_outlineView = [[NSOutlineView alloc] initWithFrame:NSZeroRect];
	[_outlineView addTableColumn:column];
	_outlineView.outlineTableColumn        = column;
	_outlineView.headerView                = nil;
	_outlineView.rowSizeStyle              = NSTableViewRowSizeStyleCustom;
	_outlineView.indentationPerLevel       = kEntryIndent;
	_outlineView.gridStyleMask             = NSTableViewGridNone;
	_outlineView.selectionHighlightStyle   = NSTableViewSelectionHighlightStyleRegular;
	_outlineView.usesAlternatingRowBackgroundColors = NO;
	_outlineView.columnAutoresizingStyle   = NSTableViewLastColumnOnlyAutoresizingStyle;
	_outlineView.dataSource                = self;
	_outlineView.delegate                  = self;
	_outlineView.target                    = self;
	_outlineView.action                    = @selector(didClickRow:);

	_listScrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
	_listScrollView.borderType            = NSNoBorder;
	_listScrollView.hasVerticalScroller   = YES;
	_listScrollView.hasHorizontalScroller = NO;
	_listScrollView.autohidesScrollers    = YES;
	_listScrollView.drawsBackground       = YES;
	_listScrollView.documentView          = _outlineView;

	[self addSubview:_listScrollView];
	[self addSubview:_emptyStateField];
	[self addSubview:_headerField];
	[self addSubview:_closeButton];
	[self addSubview:_filterControl];

	[self applyThemeColors];
	self.needsLayout = YES;
}

- (void)didClickClose:(id)sender
{
	if(self.closeHandler)
		self.closeHandler();
}

- (void)didChangeFilter:(id)sender
{
	self.errorsOnly = _filterControl.selectedSegment == 1;
}

- (void)setErrorsOnly:(BOOL)flag
{
	if(_errorsOnly == flag)
		return;

	_errorsOnly = flag;
	_filterControl.selectedSegment = flag ? 1 : 0;
	[self rebuildRows];
}

- (NSSet<NSString*>*)collapsedFilePaths
{
	return [_collapsedPaths copy];
}

- (NSInteger)numberOfRows
{
	return _outlineView.numberOfRows;
}

- (NSInteger)selectedRow
{
	return _outlineView ? _outlineView.selectedRow : -1;
}

- (void)setSelectedRow:(NSInteger)row
{
	if(row >= 0 && row < _outlineView.numberOfRows)
			[_outlineView selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
	else	[_outlineView deselectAll:nil];
}

// ============
// = Contents =
// ============

- (void)takeSnapshot:(LSPDiagnosticsSnapshot*)aSnapshot
{
	// An inactive pane holds no snapshot — that is the contract the header and
	// the hosting lifecycle both state, and keeping one here would quietly
	// break it for the next caller.
	if(!_active)
		return;

	_snapshot = aSnapshot;
	[self rebuildRows];
}

- (NSAttributedString*)textForEntry:(LSPDiagnosticEntry*)entry
{
	NSFont* font = [NSFont systemFontOfSize:[NSFont systemFontSizeForControlSize:NSControlSizeSmall]];

	NSMutableParagraphStyle* paragraphStyle = [NSMutableParagraphStyle new];
	paragraphStyle.lineBreakMode = NSLineBreakByWordWrapping;
	paragraphStyle.headIndent    = 0;

	NSMutableAttributedString* res = [NSMutableAttributedString new];
	[res appendAttributedString:[[NSAttributedString alloc] initWithString:@"● " attributes:@{
		NSFontAttributeName:            font,
		NSForegroundColorAttributeName: SeverityColor(entry.severity),
	}]];

	// LSP counts from zero; the rest of the editor counts from one.
	[res appendAttributedString:[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"%lu:%lu  ", (unsigned long)(entry.line + 1), (unsigned long)(entry.column + 1)] attributes:@{
		NSFontAttributeName:            font,
		NSForegroundColorAttributeName: _dimColor ?: NSColor.secondaryLabelColor,
	}]];

	[res appendAttributedString:[[NSAttributedString alloc] initWithString:entry.message ?: @"" attributes:@{
		NSFontAttributeName:            font,
		NSForegroundColorAttributeName: _primaryColor ?: NSColor.textColor,
	}]];

	NSString* attribution = nil;
	if(entry.source.length && entry.code.length)
		attribution = [NSString stringWithFormat:@"  %@(%@)", entry.source, entry.code];
	else if(entry.source.length)
		attribution = [NSString stringWithFormat:@"  %@", entry.source];
	else if(entry.code.length)
		attribution = [NSString stringWithFormat:@"  (%@)", entry.code];

	if(attribution)
	{
		[res appendAttributedString:[[NSAttributedString alloc] initWithString:attribution attributes:@{
			NSFontAttributeName:            font,
			NSForegroundColorAttributeName: _dimColor ?: NSColor.secondaryLabelColor,
		}]];
	}

	[res addAttribute:NSParagraphStyleAttributeName value:paragraphStyle range:NSMakeRange(0, res.length)];
	return res;
}

- (void)rebuildRows
{
	if(!_outlineView)
		return;

	NSMutableArray<DiagnosticsPaneGroup*>* groups = [NSMutableArray new];
	for(LSPDiagnosticFileGroup* fileGroup in _snapshot.fileGroups)
	{
		NSMutableArray<DiagnosticsPaneRow*>* rows = [NSMutableArray new];
		NSUInteger errors = 0, warnings = 0, notes = 0;

		for(LSPDiagnosticEntry* entry in fileGroup.entries)
		{
			if(_errorsOnly && entry.severity != 1)
				continue;

			DiagnosticsPaneRow* row = [DiagnosticsPaneRow new];
			row.entry = entry;
			row.path  = fileGroup.path;
			row.text  = [self textForEntry:entry];
			[rows addObject:row];

			switch(entry.severity)
			{
				case 1:  errors   += 1; break;
				case 2:  warnings += 1; break;
				default: notes    += 1; break;
			}
		}

		if(!rows.count)
			continue;

		DiagnosticsPaneGroup* group = [DiagnosticsPaneGroup new];
		group.path         = fileGroup.path;
		group.displayPath  = fileGroup.displayPath;
		group.rows         = rows;
		group.errorCount   = errors;
		group.warningCount = warnings;
		group.noteCount    = notes;
		group.summary      = CountsSummary(errors, warnings, notes);
		[groups addObject:group];
	}

	// Collapse is remembered for exactly as long as the file stays listed. It
	// deliberately survives a rebuild and closing the pane — it is the reader's
	// state — but not the file going clean and coming back later, where a group
	// that opens collapsed reads as the pane hiding rows of its own accord.
	// Compared against the whole snapshot rather than the filtered groups, so
	// switching to Errors does not forget a warnings-only file's collapse.
	// Only against a snapshot we actually have: a pane that has just been
	// reopened has none yet, and "no snapshot" is not "no file has problems".
	if(_snapshot)
	{
		NSMutableSet<NSString*>* listedPaths = [NSMutableSet new];
		for(LSPDiagnosticFileGroup* fileGroup in _snapshot.fileGroups)
			[listedPaths addObject:fileGroup.path];
		[_collapsedPaths intersectSet:listedPaths];
	}

	// What the reader was looking at, so a publish elsewhere in the project
	// does not yank them back to the top of a list they are working through.
	NSPoint const scrollOrigin = _listScrollView.contentView.bounds.origin;
	DiagnosticsPaneRow* selectedRow = nil;
	NSString* selectedGroupPath = nil;
	if(NSInteger selected = _outlineView.selectedRow; selected >= 0)
	{
		id item = [_outlineView itemAtRow:selected];
		if([item isKindOfClass:[DiagnosticsPaneGroup class]])
				selectedGroupPath = ((DiagnosticsPaneGroup*)item).path;
		else	selectedRow = item;
	}

	_groups = groups;
	[_heightCache removeAllObjects];
	[_outlineView reloadData];

	// Expanded is the default; _collapsedPaths records what the reader closed.
	for(DiagnosticsPaneGroup* group in _groups)
	{
		if(![_collapsedPaths containsObject:group.path])
			[_outlineView expandItem:group];
	}

	[self restoreSelectionForRow:selectedRow groupPath:selectedGroupPath];
	[_listScrollView.contentView scrollToPoint:scrollOrigin];
	[_listScrollView reflectScrolledClipView:_listScrollView.contentView];

	[self updateHeader];
}

// The row objects are rebuilt every time, so the selection is re-found by what
// it names — file and position — rather than by identity or row number, either
// of which a publish above it invalidates.
- (void)restoreSelectionForRow:(DiagnosticsPaneRow*)aRow groupPath:(NSString*)aGroupPath
{
	id target = nil;
	for(DiagnosticsPaneGroup* group in _groups)
	{
		if(aGroupPath)
		{
			if([group.path isEqualToString:aGroupPath])
				target = group;
			continue;
		}

		if(!aRow || ![group.path isEqualToString:aRow.path])
			continue;

		for(DiagnosticsPaneRow* row in group.rows)
		{
			if(row.entry.line == aRow.entry.line && row.entry.column == aRow.entry.column && [row.entry.message isEqualToString:aRow.entry.message])
			{
				target = row;
				break;
			}
		}
	}

	NSInteger const row = target ? [_outlineView rowForItem:target] : -1;
	if(row >= 0)
			[_outlineView selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
	else	[_outlineView deselectAll:nil];
}

- (void)updateHeader
{
	// The counts describe the list under them. Reading the snapshot's totals
	// instead would put "5 warnings" above a list of errors with no way to tell
	// which number answered which question.
	NSUInteger errors = 0, warnings = 0, notes = 0;
	for(DiagnosticsPaneGroup* group in _groups)
	{
		errors   += group.errorCount;
		warnings += group.warningCount;
		notes    += group.noteCount;
	}

	NSString* summary = CountsSummary(errors, warnings, notes);
	_headerField.stringValue = summary.length ? [NSString stringWithFormat:@"Diagnostics — %@", summary] : @"Diagnostics";

	BOOL const empty = _groups.count == 0;
	_emptyStateField.hidden = !empty;
	if(empty)
		_emptyStateField.stringValue = _errorsOnly && _snapshot.errorCount == 0 && (_snapshot.warningCount || _snapshot.noteCount) ? @"No errors reported." : @"No diagnostics reported.";

	self.needsLayout = YES;
}

// ==============
// = Navigation =
// ==============

- (void)didClickRow:(id)sender
{
	[self activateRow:_outlineView.clickedRow];
}

- (void)activateRow:(NSInteger)row
{
	if(row < 0 || row >= _outlineView.numberOfRows)
		return;

	id item = [_outlineView itemAtRow:row];
	if([item isKindOfClass:[DiagnosticsPaneGroup class]])
	{
		// The whole header row is the disclosure control — a file row has
		// nothing else to do, and the triangle alone is a small target.
		if([_outlineView isItemExpanded:item])
				[_outlineView collapseItem:item];
		else	[_outlineView expandItem:item];
		return;
	}

	DiagnosticsPaneRow* diagnostic = item;
	if(self.openLocationHandler && diagnostic.path)
		self.openLocationHandler([NSURL fileURLWithPath:diagnostic.path], diagnostic.entry.line, diagnostic.entry.column);
}

// ===============
// = Outline view =
// ===============

- (NSInteger)outlineView:(NSOutlineView*)outlineView numberOfChildrenOfItem:(id)item
{
	if(!item)
		return _groups.count;
	if([item isKindOfClass:[DiagnosticsPaneGroup class]])
		return ((DiagnosticsPaneGroup*)item).rows.count;
	return 0;
}

- (id)outlineView:(NSOutlineView*)outlineView child:(NSInteger)index ofItem:(id)item
{
	if(!item)
		return _groups[index];
	return ((DiagnosticsPaneGroup*)item).rows[index];
}

- (BOOL)outlineView:(NSOutlineView*)outlineView isItemExpandable:(id)item
{
	return [item isKindOfClass:[DiagnosticsPaneGroup class]];
}

- (CGFloat)outlineView:(NSOutlineView*)outlineView heightOfRowByItem:(id)item
{
	if([item isKindOfClass:[DiagnosticsPaneGroup class]])
		return kFileRowHeight;

	DiagnosticsPaneRow* row = item;

	// Before the first layout pass there is no width to wrap against, and
	// measuring every row against a 40 pt floor only to throw all of it away is
	// the pass that runs while the reader waits for the pane to appear. Give
	// the outline view a cheap answer and let that layout pass invalidate it.
	if(_measuredWidth <= 0)
		return kFileRowHeight;

	if(NSNumber* cached = [_heightCache objectForKey:row])
		return cached.doubleValue;

	// Deliberately a little narrower than the width the cell will actually give
	// the text: the exact inset AppKit leaves is not ours to know, and erring
	// this way costs at most one blank line on a row that wraps, where erring
	// the other way clips the last line of a message.
	CGFloat const width = std::max<CGFloat>(40, _measuredWidth - kEntryIndent - 2*kRowPadding);
	NSRect const bounds = [row.text boundingRectWithSize:NSMakeSize(width, 0) options:NSStringDrawingUsesLineFragmentOrigin];
	CGFloat const height = std::max<CGFloat>(kFileRowHeight, ceil(NSHeight(bounds)) + 2*kEntryRowInset);

	[_heightCache setObject:@(height) forKey:row];
	return height;
}

- (NSView*)outlineView:(NSOutlineView*)outlineView viewForTableColumn:(NSTableColumn*)tableColumn item:(id)item
{
	if([item isKindOfClass:[DiagnosticsPaneGroup class]])
	{
		DiagnosticsPaneGroup* group = item;

		DiagnosticsFileCellView* view = [outlineView makeViewWithIdentifier:@"file" owner:self];
		if(!view)
		{
			view = [[DiagnosticsFileCellView alloc] initWithFrame:NSZeroRect];
			view.identifier = @"file";

			NSImageView* imageView = [[NSImageView alloc] initWithFrame:NSZeroRect];
			[view addSubview:imageView];
			view.imageView = imageView;

			NSTextField* textField = [[NSTextField alloc] initWithFrame:NSZeroRect];
			textField.bordered        = NO;
			textField.editable        = NO;
			textField.selectable      = NO;
			textField.bezeled         = NO;
			textField.drawsBackground = NO;
			[[textField cell] setLineBreakMode:NSLineBreakByTruncatingMiddle];
			[view addSubview:textField];
			view.textField = textField;
		}

		view.imageView.image = [NSWorkspace.sharedWorkspace iconForFile:group.path];

		NSFont* font = [NSFont systemFontOfSize:[NSFont systemFontSizeForControlSize:NSControlSizeSmall]];
		NSMutableAttributedString* title = [[NSMutableAttributedString alloc] initWithString:group.displayPath ?: @"" attributes:@{
			NSFontAttributeName:            font,
			NSForegroundColorAttributeName: _primaryColor ?: NSColor.textColor,
		}];
		if(group.summary.length)
		{
			[title appendAttributedString:[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"  %@", group.summary] attributes:@{
				NSFontAttributeName:            font,
				NSForegroundColorAttributeName: _dimColor ?: NSColor.secondaryLabelColor,
			}]];
		}
		view.textField.attributedStringValue = title;
		view.needsLayout = YES;
		return view;
	}

	DiagnosticsPaneRow* row = item;

	DiagnosticsEntryCellView* view = [outlineView makeViewWithIdentifier:@"entry" owner:self];
	if(!view)
	{
		view = [[DiagnosticsEntryCellView alloc] initWithFrame:NSZeroRect];
		view.identifier = @"entry";

		NSTextField* textField = [[NSTextField alloc] initWithFrame:NSZeroRect];
		textField.bordered        = NO;
		textField.editable        = NO;
		textField.selectable      = NO;
		textField.bezeled         = NO;
		textField.drawsBackground = NO;
		textField.usesSingleLineMode = NO;
		[[textField cell] setWraps:YES];
		[view addSubview:textField];
		view.textField = textField;
	}

	view.textField.attributedStringValue = row.text;
	view.toolTip = row.entry.message;
	view.needsLayout = YES;
	return view;
}

- (void)outlineViewItemDidExpand:(NSNotification*)aNotification
{
	DiagnosticsPaneGroup* group = aNotification.userInfo[@"NSObject"];
	if([group isKindOfClass:[DiagnosticsPaneGroup class]])
		[_collapsedPaths removeObject:group.path];
}

- (void)outlineViewItemDidCollapse:(NSNotification*)aNotification
{
	DiagnosticsPaneGroup* group = aNotification.userInfo[@"NSObject"];
	if([group isKindOfClass:[DiagnosticsPaneGroup class]])
		[_collapsedPaths addObject:group.path];
}

// =========
// = Theme =
// =========

- (void)setThemeBackgroundColor:(NSColor*)aColor
{
	if(_themeBackgroundColor == aColor || [_themeBackgroundColor isEqual:aColor])
		return;
	_themeBackgroundColor = aColor;
	[self applyThemeColors];
}

- (void)setThemeForegroundColor:(NSColor*)aColor
{
	if(_themeForegroundColor == aColor || [_themeForegroundColor isEqual:aColor])
		return;
	_themeForegroundColor = aColor;
	[self applyThemeColors];
}

- (void)applyThemeColors
{
	NSColor* background = _themeBackgroundColor ?: NSColor.textBackgroundColor;
	NSColor* foreground = _themeForegroundColor ?: NSColor.textColor;

	_primaryColor = BlendedColor(foreground, background, 0.10);
	_dimColor     = BlendedColor(foreground, background, 0.45);

	if(!_listScrollView)
		return;

	_listScrollView.backgroundColor = background;
	_outlineView.backgroundColor    = background;
	_headerField.textColor          = BlendedColor(foreground, background, 0.25);
	_emptyStateField.textColor      = _dimColor;
	_closeButton.contentTintColor   = BlendedColor(foreground, background, 0.35);

	// A bezeled control renders for the SYSTEM appearance, not the editor
	// theme — on a dark theme under a light system appearance its label comes
	// out dark on dark. Pin it to the theme's brightness instead.
	NSColor* backgroundRGB = [background colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
	BOOL const isDarkTheme = backgroundRGB && (0.2126*backgroundRGB.redComponent + 0.7152*backgroundRGB.greenComponent + 0.0722*backgroundRGB.blueComponent) < 0.5;
	_filterControl.appearance = [NSAppearance appearanceNamed:isDarkTheme ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua];

	// The row text carries its own colors, so they have to be rebuilt too.
	[self rebuildRows];
	self.needsDisplay = YES;
}
@end
