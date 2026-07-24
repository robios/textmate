#import "ProjectLayoutView.h"
#import <OakAppKit/OakUIConstructionFunctions.h>
#import <OakFoundation/OakFoundation.h>
#import <Preferences/Keys.h>
#import <oak/misc.h>
#import <oak/debug.h>

NSString* const kUserDefaultsFileBrowserWidthKey          = @"fileBrowserWidth";
NSString* const kUserDefaultsHTMLOutputSizeKey            = @"htmlOutputSize";
NSString* const kUserDefaultsTerminalViewSizeKey          = @"terminalViewSize";
NSString* const kUserDefaultsMarkdownPreviewViewSizeKey   = @"markdownPreviewViewSize";

@interface ProjectLayoutView () <OakUserDefaultsObserver>
@property (nonatomic) NSView* fileBrowserDivider;
@property (nonatomic) NSView* htmlOutputDivider;
@property (nonatomic) NSView* terminalDivider;
@property (nonatomic) NSView* markdownPreviewDivider;
@property (nonatomic) NSLayoutConstraint* fileBrowserWidthConstraint;
@property (nonatomic) NSLayoutConstraint* htmlOutputSizeConstraint;
@property (nonatomic) NSLayoutConstraint* terminalSizeConstraint;
@property (nonatomic) NSLayoutConstraint* markdownPreviewSizeConstraint;
@property (nonatomic) NSMutableArray* myConstraints;
@property (nonatomic) BOOL mouseDownRecursionGuard;
@end

@implementation ProjectLayoutView
+ (void)initialize
{
	[NSUserDefaults.standardUserDefaults registerDefaults:@{
		kUserDefaultsFileBrowserWidthKey:        @250,
		kUserDefaultsHTMLOutputSizeKey:          NSStringFromSize(NSMakeSize(200, 200)),
		kUserDefaultsTerminalViewSizeKey:        NSStringFromSize(NSMakeSize(480, 240)),
		kUserDefaultsMarkdownPreviewViewSizeKey: NSStringFromSize(NSMakeSize(480, 320)),
	}];
}

- (id)initWithFrame:(NSRect)aRect
{
	if(self = [super initWithFrame:aRect])
	{
		_myConstraints            = [NSMutableArray array];
		_fileBrowserWidth         = [NSUserDefaults.standardUserDefaults integerForKey:kUserDefaultsFileBrowserWidthKey];
		_htmlOutputSize           = NSSizeFromString([NSUserDefaults.standardUserDefaults stringForKey:kUserDefaultsHTMLOutputSizeKey]);
		_terminalSize             = NSSizeFromString([NSUserDefaults.standardUserDefaults stringForKey:kUserDefaultsTerminalViewSizeKey]);
		_markdownPreviewSize      = NSSizeFromString([NSUserDefaults.standardUserDefaults stringForKey:kUserDefaultsMarkdownPreviewViewSizeKey]);
		_terminalPlacement        = @"right";
		_markdownPreviewPlacement = @"right";

		[self userDefaultsDidChange:nil];
		OakObserveUserDefaults(self);
	}
	return self;
}

- (void)dealloc
{
	[NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)userDefaultsDidChange:(NSNotification*)aNotification
{
	self.htmlOutputOnRight = [[NSUserDefaults.standardUserDefaults stringForKey:kUserDefaultsHTMLOutputPlacementKey] isEqualToString:@"right"];

	NSString* terminalPlacement = [NSUserDefaults.standardUserDefaults stringForKey:kUserDefaultsTerminalPlacementKey];
	if(![terminalPlacement isEqualToString:@"left"] && ![terminalPlacement isEqualToString:@"bottom"])
		terminalPlacement = @"right";
	self.terminalPlacement = terminalPlacement;

	NSString* markdownPreviewPlacement = [NSUserDefaults.standardUserDefaults stringForKey:kUserDefaultsMarkdownPreviewPlacementKey];
	if(![markdownPreviewPlacement isEqualToString:@"bottom"])
		markdownPreviewPlacement = @"right";
	self.markdownPreviewPlacement = markdownPreviewPlacement;
}

- (BOOL)terminalAtBottom { return _terminalView && [_terminalPlacement isEqualToString:@"bottom"]; }
- (BOOL)terminalOnLeft   { return _terminalView && [_terminalPlacement isEqualToString:@"left"]; }
- (BOOL)terminalOnRight  { return _terminalView && ![self terminalAtBottom] && ![self terminalOnLeft]; }

- (BOOL)previewAtBottom  { return _markdownPreviewView && [_markdownPreviewPlacement isEqualToString:@"bottom"]; }
- (BOOL)previewOnRight   { return _markdownPreviewView && ![self previewAtBottom]; }

- (NSView*)replaceView:(NSView*)oldView withView:(NSView*)newView
{
	if(newView == oldView)
		return oldView;

	[oldView removeFromSuperview];
	if(newView)
		OakAddAutoLayoutViewsToSuperview(@[ newView ], self);

	[self setNeedsUpdateConstraints:YES];
	return newView;
}

- (void)updateKeyViewLoop
{
	NSMutableArray<NSView*>* views = [NSMutableArray array];
	for(NSView* view : { _documentView, _markdownPreviewView, _htmlOutputView, _fileBrowserView, _terminalView })
	{
		if(view)
			[views addObject:view];
	}
	OakSetupKeyViewLoop(views);
}

- (void)setDocumentView:(NSView*)aDocumentView       { _documentView = [self replaceView:_documentView withView:aDocumentView]; [self updateKeyViewLoop]; }

- (NSView*)createDividerAlongYAxis:(BOOL)flag
{
	NSView* res = OakCreateNSBoxSeparator();
	res.translatesAutoresizingMaskIntoConstraints = NO;
	[res addConstraint:[NSLayoutConstraint constraintWithItem:res attribute:(flag ? NSLayoutAttributeWidth : NSLayoutAttributeHeight) relatedBy:NSLayoutRelationEqual toItem:nil attribute:NSLayoutAttributeNotAnAttribute multiplier:1 constant:1]];
	[res addConstraint:[NSLayoutConstraint constraintWithItem:res attribute:(flag ? NSLayoutAttributeHeight : NSLayoutAttributeWidth) relatedBy:NSLayoutRelationGreaterThanOrEqual toItem:nil attribute:NSLayoutAttributeNotAnAttribute multiplier:1 constant:2]];
	return res;
}

- (void)setHtmlOutputView:(NSView*)aHtmlOutputView
{
	_htmlOutputDivider = [self replaceView:_htmlOutputDivider withView:(aHtmlOutputView ? [self createDividerAlongYAxis:_htmlOutputOnRight] : nil)];
	_htmlOutputView    = [self replaceView:_htmlOutputView withView:aHtmlOutputView];
	[self updateKeyViewLoop];
}

- (void)setFileBrowserView:(NSView*)aFileBrowserView
{
	_fileBrowserDivider = [self replaceView:_fileBrowserDivider withView:aFileBrowserView ? [self createDividerAlongYAxis:YES] : nil];
	_fileBrowserView    = [self replaceView:_fileBrowserView withView:aFileBrowserView];
	[self updateKeyViewLoop];
}

- (void)setTerminalView:(NSView*)aTerminalView
{
	_terminalDivider = [self replaceView:_terminalDivider withView:(aTerminalView ? [self createDividerAlongYAxis:![_terminalPlacement isEqualToString:@"bottom"]] : nil)];
	_terminalView    = [self replaceView:_terminalView withView:aTerminalView];
	[self updateKeyViewLoop];
}

- (void)setTerminalPlacement:(NSString*)aPlacement
{
	if(![_terminalPlacement isEqualToString:aPlacement])
	{
		_terminalPlacement = aPlacement;
		self.terminalView = _terminalView; // recreate divider line, required due to <rdar://13093498>
	}
}

- (void)setTerminalSize:(NSSize)aSize
{
	_terminalSize = aSize;
	if(_terminalView)
		[self setNeedsUpdateConstraints:YES];
}

- (void)setMarkdownPreviewView:(NSView*)aMarkdownPreviewView
{
	_markdownPreviewDivider = [self replaceView:_markdownPreviewDivider withView:(aMarkdownPreviewView ? [self createDividerAlongYAxis:![_markdownPreviewPlacement isEqualToString:@"bottom"]] : nil)];
	_markdownPreviewView    = [self replaceView:_markdownPreviewView withView:aMarkdownPreviewView];
	[self updateKeyViewLoop];
}

- (void)setMarkdownPreviewPlacement:(NSString*)aPlacement
{
	if(![_markdownPreviewPlacement isEqualToString:aPlacement])
	{
		_markdownPreviewPlacement = aPlacement;
		self.markdownPreviewView = _markdownPreviewView; // recreate divider line, required due to <rdar://13093498>
	}
}

- (void)setMarkdownPreviewSize:(NSSize)aSize
{
	_markdownPreviewSize = aSize;
	if(_markdownPreviewView)
		[self setNeedsUpdateConstraints:YES];
}

- (void)setFileBrowserOnRight:(BOOL)flag
{
	if(_fileBrowserOnRight != flag)
	{
		_fileBrowserOnRight = flag;
		if(_fileBrowserView)
			[self setNeedsUpdateConstraints:YES];
	}
}

- (void)setHtmlOutputOnRight:(BOOL)flag
{
	if(_htmlOutputOnRight != flag)
	{
		_htmlOutputOnRight = flag;
		self.htmlOutputView = _htmlOutputView; // recreate divider line, required due to <rdar://13093498>
	}
}

#ifndef CONSTRAINT
#define CONSTRAINT(str, align) [_myConstraints addObjectsFromArray:[NSLayoutConstraint constraintsWithVisualFormat:str options:align metrics:nil views:views]]
#endif

- (void)updateConstraints
{
	[self removeConstraints:_myConstraints];
	[_myConstraints removeAllObjects];
	[super updateConstraints];

	NSDictionary* views = @{
		@"documentView":           _documentView,
		@"fileBrowserView":        _fileBrowserView        ?: [NSNull null],
		@"fileBrowserDivider":     _fileBrowserDivider     ?: [NSNull null],
		@"htmlOutputView":         _htmlOutputView         ?: [NSNull null],
		@"htmlOutputDivider":      _htmlOutputDivider      ?: [NSNull null],
		@"terminalView":           _terminalView           ?: [NSNull null],
		@"terminalDivider":        _terminalDivider        ?: [NSNull null],
		@"markdownPreviewView":    _markdownPreviewView    ?: [NSNull null],
		@"markdownPreviewDivider": _markdownPreviewDivider ?: [NSNull null],
	};

	// The terminal claims an entire window edge (left, right, or bottom);
	// everything else lays out in the remaining rectangle. The Markdown
	// preview is a document companion and always sits innermost on its edge,
	// directly adjacent to the document view.
	BOOL terminalAtBottom = [self terminalAtBottom];
	BOOL terminalOnLeft   = [self terminalOnLeft];
	BOOL terminalOnRight  = [self terminalOnRight];
	BOOL previewAtBottom  = [self previewAtBottom];
	BOOL previewOnRight   = [self previewOnRight];

	// ========================
	// = Anchor Document View =
	// ========================

	// top
	CONSTRAINT(@"V:|[documentView]", 0);

	// bottom
	if(previewAtBottom)
		CONSTRAINT(@"V:[documentView][markdownPreviewDivider]", 0);
	else if(_htmlOutputView && !_htmlOutputOnRight)
		CONSTRAINT(@"V:[documentView][htmlOutputDivider]", 0);
	else if(terminalAtBottom)
		CONSTRAINT(@"V:[documentView][terminalDivider]", 0);
	else
		CONSTRAINT(@"V:[documentView]|", 0);

	// left
	if(_fileBrowserView && !_fileBrowserOnRight)
		CONSTRAINT(@"H:[fileBrowserDivider][documentView]", 0);
	else if(terminalOnLeft)
		CONSTRAINT(@"H:[terminalDivider][documentView]", 0);
	else
		CONSTRAINT(@"H:|[documentView]", 0);

	// right
	if(previewOnRight)
		CONSTRAINT(@"H:[documentView][markdownPreviewDivider]", 0);
	else if(_htmlOutputView && _htmlOutputOnRight)
		CONSTRAINT(@"H:[documentView][htmlOutputDivider]", 0);
	else if(_fileBrowserView && _fileBrowserOnRight)
		CONSTRAINT(@"H:[documentView][fileBrowserDivider]", 0);
	else if(terminalOnRight)
		CONSTRAINT(@"H:[documentView][terminalDivider]", 0);
	else
		CONSTRAINT(@"H:[documentView]|", 0);

	// ===========================
	// = Anchor Markdown Preview =
	// ===========================

	if(_markdownPreviewView)
	{
		self.markdownPreviewSizeConstraint = previewAtBottom ? [NSLayoutConstraint constraintWithItem:_markdownPreviewView attribute:NSLayoutAttributeHeight relatedBy:NSLayoutRelationEqual toItem:nil attribute:NSLayoutAttributeNotAnAttribute multiplier:1 constant:_markdownPreviewSize.height] : [NSLayoutConstraint constraintWithItem:_markdownPreviewView attribute:NSLayoutAttributeWidth relatedBy:NSLayoutRelationEqual toItem:nil attribute:NSLayoutAttributeNotAnAttribute multiplier:1 constant:_markdownPreviewSize.width];
		self.markdownPreviewSizeConstraint.priority = NSLayoutPriorityDragThatCannotResizeWindow-1;
		[_myConstraints addObject:self.markdownPreviewSizeConstraint];

		if(previewAtBottom)
		{
			// Like the bottom terminal, a bottom preview spans the document
			// area only: its edges follow the document view, and side panes
			// keep their full height beside it.
			CONSTRAINT(@"V:[markdownPreviewDivider][markdownPreviewView]", NSLayoutFormatAlignAllLeft|NSLayoutFormatAlignAllRight);
			[_myConstraints addObject:[NSLayoutConstraint constraintWithItem:_markdownPreviewDivider attribute:NSLayoutAttributeLeft relatedBy:NSLayoutRelationEqual toItem:_documentView attribute:NSLayoutAttributeLeft multiplier:1 constant:0]];
			[_myConstraints addObject:[NSLayoutConstraint constraintWithItem:_markdownPreviewDivider attribute:NSLayoutAttributeRight relatedBy:NSLayoutRelationEqual toItem:_documentView attribute:NSLayoutAttributeRight multiplier:1 constant:0]];

			// bottom neighbor — HTML output and the terminal stack below the
			// preview; their own sections anchor against it when previewAtBottom.
			if(_htmlOutputView && !_htmlOutputOnRight)
				; // the HTML output section chains [markdownPreviewView][htmlOutputDivider]
			else if(terminalAtBottom)
				CONSTRAINT(@"V:[markdownPreviewView][terminalDivider]", 0);
			else
				CONSTRAINT(@"V:[markdownPreviewView]|", 0);
		}
		else
		{
			// Full height on the right, like other right-edge panes.
			CONSTRAINT(@"V:|[markdownPreviewView]|", 0);
			CONSTRAINT(@"V:|[markdownPreviewDivider]|", 0);
			CONSTRAINT(@"H:[documentView][markdownPreviewDivider][markdownPreviewView]", 0);

			// right neighbor — HTML output / file browser sections chain from
			// the preview when previewOnRight.
			if(_htmlOutputView && _htmlOutputOnRight)
				;
			else if(_fileBrowserView && _fileBrowserOnRight)
				;
			else if(terminalOnRight)
				CONSTRAINT(@"H:[markdownPreviewView][terminalDivider]", 0);
			else
				CONSTRAINT(@"H:[markdownPreviewView]|", 0);
		}
	}

	// =======================
	// = Anchor File Browser =
	// =======================

	if(_fileBrowserView)
	{
		// width
		self.fileBrowserWidthConstraint = [NSLayoutConstraint constraintWithItem:_fileBrowserView attribute:NSLayoutAttributeWidth relatedBy:NSLayoutRelationEqual toItem:nil attribute:NSLayoutAttributeNotAnAttribute multiplier:1 constant:_fileBrowserWidth];
		self.fileBrowserWidthConstraint.priority = NSLayoutPriorityDragThatCannotResizeWindow;
		[_myConstraints addObject:self.fileBrowserWidthConstraint];

		// top
		CONSTRAINT(@"V:|[fileBrowserDivider]", 0);
		CONSTRAINT(@"V:|[fileBrowserView]", 0);

		// bottom
		if(_htmlOutputView && !_htmlOutputOnRight)
		{
			CONSTRAINT(@"V:[fileBrowserView][htmlOutputDivider]", 0);
			CONSTRAINT(@"V:[fileBrowserDivider][htmlOutputDivider]", 0);
		}
		else if(terminalAtBottom)
		{
			CONSTRAINT(@"V:[fileBrowserView][terminalDivider]", 0);
			CONSTRAINT(@"V:[fileBrowserDivider][terminalDivider]", 0);
		}
		else
		{
			CONSTRAINT(@"V:[fileBrowserView]|", 0);
			CONSTRAINT(@"V:[fileBrowserDivider]|", 0);
		}

		// left
		if(_fileBrowserOnRight && _htmlOutputView && _htmlOutputOnRight)
			CONSTRAINT(@"H:[htmlOutputView][fileBrowserDivider][fileBrowserView]", 0);
		else if(_fileBrowserOnRight && previewOnRight)
			CONSTRAINT(@"H:[markdownPreviewView][fileBrowserDivider][fileBrowserView]", 0);
		else if(_fileBrowserOnRight)
			CONSTRAINT(@"H:[documentView][fileBrowserDivider][fileBrowserView]", 0);
		else if(terminalOnLeft)
			CONSTRAINT(@"H:[terminalDivider][fileBrowserView][fileBrowserDivider]", 0);
		else
			CONSTRAINT(@"H:|[fileBrowserView][fileBrowserDivider]", 0);

		// right
		if(_fileBrowserOnRight && terminalOnRight)
			CONSTRAINT(@"H:[fileBrowserView][terminalDivider]", 0);
		else if(_fileBrowserOnRight)
			CONSTRAINT(@"H:[fileBrowserView]|", 0);
		else
			CONSTRAINT(@"H:[fileBrowserDivider][documentView]", 0);
	}

	// ===========================
	// = Anchor HTML Output View =
	// ===========================

	if(_htmlOutputView)
	{
		// size (either width or height)
		self.htmlOutputSizeConstraint = _htmlOutputOnRight ? [NSLayoutConstraint constraintWithItem:_htmlOutputView attribute:NSLayoutAttributeWidth relatedBy:NSLayoutRelationEqual toItem:nil attribute:NSLayoutAttributeNotAnAttribute multiplier:1 constant:_htmlOutputSize.width] : [NSLayoutConstraint constraintWithItem:_htmlOutputView attribute:NSLayoutAttributeHeight relatedBy:NSLayoutRelationEqual toItem:nil attribute:NSLayoutAttributeNotAnAttribute multiplier:1 constant:_htmlOutputSize.height];
		self.htmlOutputSizeConstraint.priority = NSLayoutPriorityDragThatCannotResizeWindow-1;
		[_myConstraints addObject:self.htmlOutputSizeConstraint];

		if(_htmlOutputOnRight)
		{
			// top + bottom
			CONSTRAINT(@"V:|[htmlOutputView]", 0);
			CONSTRAINT(@"V:|[htmlOutputDivider]", 0);
			if(terminalAtBottom)
			{
				CONSTRAINT(@"V:[htmlOutputView][terminalDivider]", 0);
				CONSTRAINT(@"V:[htmlOutputDivider][terminalDivider]", 0);
			}
			else
			{
				CONSTRAINT(@"V:[htmlOutputView]|", 0);
				CONSTRAINT(@"V:[htmlOutputDivider]|", 0);
			}

			// left + right — a right-side preview sits between the document
			// view and the HTML output (preview is innermost on its edge).
			NSString* leadingView = previewOnRight ? @"markdownPreviewView" : @"documentView";
			if(_fileBrowserView && _fileBrowserOnRight)
				CONSTRAINT(([NSString stringWithFormat:@"H:[%@][htmlOutputDivider][htmlOutputView][fileBrowserDivider]", leadingView]), 0);
			else if(terminalOnRight)
				CONSTRAINT(([NSString stringWithFormat:@"H:[%@][htmlOutputDivider][htmlOutputView][terminalDivider]", leadingView]), 0);
			else
				CONSTRAINT(([NSString stringWithFormat:@"H:[%@][htmlOutputDivider][htmlOutputView]|", leadingView]), 0);
		}
		else
		{
			// top + bottom — a bottom preview sits between the document view
			// and the HTML output (preview is innermost on its edge).
			NSString* topView = previewAtBottom ? @"markdownPreviewView" : @"documentView";
			if(terminalAtBottom)
				CONSTRAINT(([NSString stringWithFormat:@"V:[%@][htmlOutputDivider][htmlOutputView][terminalDivider]", topView]), 0);
			else
				CONSTRAINT(([NSString stringWithFormat:@"V:[%@][htmlOutputDivider][htmlOutputView]|", topView]), 0);

			// left + right
			if(terminalOnLeft)
			{
				CONSTRAINT(@"H:[terminalDivider][htmlOutputView]", 0);
				CONSTRAINT(@"H:[terminalDivider][htmlOutputDivider]", 0);
			}
			else
			{
				CONSTRAINT(@"H:|[htmlOutputView]", 0);
				CONSTRAINT(@"H:|[htmlOutputDivider]", 0);
			}

			if(terminalOnRight)
			{
				CONSTRAINT(@"H:[htmlOutputView][terminalDivider]", 0);
				CONSTRAINT(@"H:[htmlOutputDivider][terminalDivider]", 0);
			}
			else
			{
				CONSTRAINT(@"H:[htmlOutputView]|", 0);
				CONSTRAINT(@"H:[htmlOutputDivider]|", 0);
			}
		}
	}

	// ========================
	// = Anchor Terminal View =
	// ========================

	if(_terminalView)
	{
		self.terminalSizeConstraint = terminalAtBottom ? [NSLayoutConstraint constraintWithItem:_terminalView attribute:NSLayoutAttributeHeight relatedBy:NSLayoutRelationEqual toItem:nil attribute:NSLayoutAttributeNotAnAttribute multiplier:1 constant:_terminalSize.height] : [NSLayoutConstraint constraintWithItem:_terminalView attribute:NSLayoutAttributeWidth relatedBy:NSLayoutRelationEqual toItem:nil attribute:NSLayoutAttributeNotAnAttribute multiplier:1 constant:_terminalSize.width];
		self.terminalSizeConstraint.priority = NSLayoutPriorityDragThatCannotResizeWindow-1;
		[_myConstraints addObject:self.terminalSizeConstraint];

		if(terminalAtBottom)
		{
			CONSTRAINT(@"V:[terminalDivider][terminalView]|", 0);
			CONSTRAINT(@"H:|[terminalView]|", 0);
			CONSTRAINT(@"H:|[terminalDivider]|", 0);
		}
		else if(terminalOnLeft)
		{
			CONSTRAINT(@"V:|[terminalView]|", 0);
			CONSTRAINT(@"V:|[terminalDivider]|", 0);
			CONSTRAINT(@"H:|[terminalView][terminalDivider]", 0);
		}
		else
		{
			CONSTRAINT(@"V:|[terminalView]|", 0);
			CONSTRAINT(@"V:|[terminalDivider]|", 0);
			CONSTRAINT(@"H:[terminalDivider][terminalView]|", 0);
		}
	}

	[self addConstraints:_myConstraints];
	[[self window] invalidateCursorRectsForView:self];
}

#undef CONSTRAINT

- (NSRect)fileBrowserResizeRect
{
	if(!_fileBrowserView)
		return NSZeroRect;
	NSRect r = _fileBrowserView.frame;
	return NSMakeRect(_fileBrowserOnRight ? NSMinX(r)-3 : NSMaxX(r)-4, NSMinY(r), 10, NSHeight(r));
}

- (NSRect)htmlOutputResizeRect
{
	if(!_htmlOutputView)
		return NSZeroRect;
	NSRect r = _htmlOutputView.frame;
	return _htmlOutputOnRight ? NSMakeRect(NSMinX(r)-3, NSMinY(r), 10, NSHeight(r)) : NSMakeRect(NSMinX(r), NSMaxY(r)-4, NSWidth(r), 10);
}

- (NSRect)terminalResizeRect
{
	if(!_terminalView)
		return NSZeroRect;
	NSRect r = _terminalView.frame;
	if([self terminalAtBottom])
		return NSMakeRect(NSMinX(r), NSMaxY(r)-4, NSWidth(r), 10);
	return [self terminalOnRight] ? NSMakeRect(NSMinX(r)-3, NSMinY(r), 10, NSHeight(r)) : NSMakeRect(NSMaxX(r)-4, NSMinY(r), 10, NSHeight(r));
}

- (NSRect)markdownPreviewResizeRect
{
	if(!_markdownPreviewView)
		return NSZeroRect;
	NSRect r = _markdownPreviewView.frame;
	if([self previewAtBottom])
		return NSMakeRect(NSMinX(r), NSMaxY(r)-4, NSWidth(r), 10);
	return NSMakeRect(NSMinX(r)-3, NSMinY(r), 10, NSHeight(r)); // the preview always sits right of the document view
}

- (void)resetCursorRects
{
	[self addCursorRect:[self fileBrowserResizeRect]     cursor:[NSCursor resizeLeftRightCursor]];
	[self addCursorRect:[self htmlOutputResizeRect]      cursor:_htmlOutputOnRight ? [NSCursor resizeLeftRightCursor] : [NSCursor resizeUpDownCursor]];
	[self addCursorRect:[self terminalResizeRect]        cursor:[self terminalAtBottom] ? [NSCursor resizeUpDownCursor] : [NSCursor resizeLeftRightCursor]];
	[self addCursorRect:[self markdownPreviewResizeRect] cursor:[self previewAtBottom] ? [NSCursor resizeUpDownCursor] : [NSCursor resizeLeftRightCursor]];
}

- (BOOL)mouseDownCanMoveWindow
{
	return NO;
}

- (NSView*)hitTest:(NSPoint)aPoint
{
	if(NSMouseInRect([self convertPoint:aPoint fromView:[self superview]], [self fileBrowserResizeRect], [self isFlipped]))
		return self;
	if(NSMouseInRect([self convertPoint:aPoint fromView:[self superview]], [self htmlOutputResizeRect], [self isFlipped]))
		return self;
	if(NSMouseInRect([self convertPoint:aPoint fromView:[self superview]], [self terminalResizeRect], [self isFlipped]))
		return self;
	if(NSMouseInRect([self convertPoint:aPoint fromView:[self superview]], [self markdownPreviewResizeRect], [self isFlipped]))
		return self;
	return [super hitTest:aPoint];
}

- (void)mouseDown:(NSEvent*)anEvent
{
	if(_mouseDownRecursionGuard)
		return;
	_mouseDownRecursionGuard = YES;

	NSView* view = nil;
	NSPoint mouseDownPos = [self convertPoint:[anEvent locationInWindow] fromView:nil];
	if(NSMouseInRect(mouseDownPos, [self fileBrowserResizeRect], [self isFlipped]))
		view = _fileBrowserView;
	else if(NSMouseInRect(mouseDownPos, [self htmlOutputResizeRect], [self isFlipped]))
		view = _htmlOutputView;
	else if(NSMouseInRect(mouseDownPos, [self terminalResizeRect], [self isFlipped]))
		view = _terminalView;
	else if(NSMouseInRect(mouseDownPos, [self markdownPreviewResizeRect], [self isFlipped]))
		view = _markdownPreviewView;

	if(!view || [anEvent type] != NSEventTypeLeftMouseDown)
	{
		[super mouseDown:anEvent];
	}
	else
	{
		if(_fileBrowserView)
		{
			self.fileBrowserWidthConstraint.constant = NSWidth(_fileBrowserView.frame);
			self.fileBrowserWidthConstraint.priority = NSLayoutPriorityDragThatCannotResizeWindow;
		}

		if(_htmlOutputView)
		{
			if(_htmlOutputOnRight)
					self.htmlOutputSizeConstraint.constant = NSWidth(_htmlOutputView.frame);
			else	self.htmlOutputSizeConstraint.constant = NSHeight(_htmlOutputView.frame);
			self.htmlOutputSizeConstraint.priority = NSLayoutPriorityDragThatCannotResizeWindow;
		}

		if(_terminalView)
		{
			if([self terminalAtBottom])
					self.terminalSizeConstraint.constant = NSHeight(_terminalView.frame);
			else	self.terminalSizeConstraint.constant = NSWidth(_terminalView.frame);
			self.terminalSizeConstraint.priority = NSLayoutPriorityDragThatCannotResizeWindow;
		}

		if(_markdownPreviewView)
		{
			if([self previewAtBottom])
					self.markdownPreviewSizeConstraint.constant = NSHeight(_markdownPreviewView.frame);
			else	self.markdownPreviewSizeConstraint.constant = NSWidth(_markdownPreviewView.frame);
			self.markdownPreviewSizeConstraint.priority = NSLayoutPriorityDragThatCannotResizeWindow;
		}

		NSEvent* mouseDownEvent = anEvent;
		NSRect initialFrame = view.frame;

		BOOL didDrag = NO;
		while([anEvent type] != NSEventTypeLeftMouseUp)
		{
			anEvent = [NSApp nextEventMatchingMask:(NSEventMaskLeftMouseDragged|NSEventMaskLeftMouseDown|NSEventMaskLeftMouseUp) untilDate:[NSDate distantFuture] inMode:NSEventTrackingRunLoopMode dequeue:YES];
			if([anEvent type] != NSEventTypeLeftMouseDragged)
				break;

			NSPoint mouseCurrentPos = [self convertPoint:[anEvent locationInWindow] fromView:nil];
			if(!didDrag && hypot(mouseDownPos.x - mouseCurrentPos.x, mouseDownPos.y - mouseCurrentPos.y) < 2.5)
				continue;

			if(view == _htmlOutputView)
			{
				if(_htmlOutputOnRight)
				{
					CGFloat width = NSWidth(initialFrame) + (mouseCurrentPos.x - mouseDownPos.x) * (_htmlOutputOnRight ? -1 : +1);
					_htmlOutputSize.width = std::max<CGFloat>(50, round(width));
					self.htmlOutputSizeConstraint.constant = width;
				}
				else
				{
					CGFloat height = NSHeight(initialFrame) + (mouseCurrentPos.y - mouseDownPos.y);
					_htmlOutputSize.height = std::max<CGFloat>(50, round(height));
					self.htmlOutputSizeConstraint.constant = height;
				}
				self.htmlOutputSizeConstraint.priority   = NSLayoutPriorityDragThatCannotResizeWindow-1;

				[NSUserDefaults.standardUserDefaults setObject:NSStringFromSize(_htmlOutputSize) forKey:kUserDefaultsHTMLOutputSizeKey];
			}
			else if(view == _fileBrowserView)
			{
				CGFloat width = NSWidth(initialFrame) + (mouseCurrentPos.x - mouseDownPos.x) * (_fileBrowserOnRight ? -1 : +1);
				_fileBrowserWidth = std::max<CGFloat>(50, round(width));
				self.fileBrowserWidthConstraint.constant = _fileBrowserWidth;
				self.fileBrowserWidthConstraint.priority = NSLayoutPriorityDragThatCannotResizeWindow-1;

				[NSUserDefaults.standardUserDefaults setInteger:_fileBrowserWidth forKey:kUserDefaultsFileBrowserWidthKey];
			}
			else if(view == _terminalView)
			{
				if([self terminalAtBottom])
				{
					CGFloat height = NSHeight(initialFrame) + (mouseCurrentPos.y - mouseDownPos.y);
					_terminalSize.height = std::max<CGFloat>(50, round(height));
					self.terminalSizeConstraint.constant = _terminalSize.height;
				}
				else
				{
					CGFloat width = NSWidth(initialFrame) + (mouseCurrentPos.x - mouseDownPos.x) * ([self terminalOnRight] ? -1 : +1);
					_terminalSize.width = std::max<CGFloat>(100, round(width));
					self.terminalSizeConstraint.constant = _terminalSize.width;
				}
				self.terminalSizeConstraint.priority = NSLayoutPriorityDragThatCannotResizeWindow-1;

				[NSUserDefaults.standardUserDefaults setObject:NSStringFromSize(_terminalSize) forKey:kUserDefaultsTerminalViewSizeKey];
			}
			else if(view == _markdownPreviewView)
			{
				if([self previewAtBottom])
				{
					CGFloat height = NSHeight(initialFrame) + (mouseCurrentPos.y - mouseDownPos.y);
					_markdownPreviewSize.height = std::max<CGFloat>(50, round(height));
					self.markdownPreviewSizeConstraint.constant = _markdownPreviewSize.height;
				}
				else
				{
					CGFloat width = NSWidth(initialFrame) + (mouseDownPos.x - mouseCurrentPos.x); // right of the document view: dragging left grows it
					_markdownPreviewSize.width = std::max<CGFloat>(150, round(width));
					self.markdownPreviewSizeConstraint.constant = _markdownPreviewSize.width;
				}
				self.markdownPreviewSizeConstraint.priority = NSLayoutPriorityDragThatCannotResizeWindow-1;

				[NSUserDefaults.standardUserDefaults setObject:NSStringFromSize(_markdownPreviewSize) forKey:kUserDefaultsMarkdownPreviewViewSizeKey];
			}

			[[self window] invalidateCursorRectsForView:self];
			didDrag = YES;
		}

		if(!didDrag)
		{
			NSView* view = [super hitTest:[[self superview] convertPoint:[mouseDownEvent locationInWindow] fromView:nil]];
			if(view && view != self)
			{
				[NSApp postEvent:anEvent atStart:NO];
				[view mouseDown:mouseDownEvent];
			}
		}

		self.fileBrowserWidthConstraint.priority        = NSLayoutPriorityDragThatCannotResizeWindow;
		self.htmlOutputSizeConstraint.priority          = NSLayoutPriorityDragThatCannotResizeWindow-1;
		self.terminalSizeConstraint.priority            = NSLayoutPriorityDragThatCannotResizeWindow-1;
		self.markdownPreviewSizeConstraint.priority     = NSLayoutPriorityDragThatCannotResizeWindow-1;
	}

	_mouseDownRecursionGuard = NO;
}

- (void)performClose:(id)sender
{
	NSView* view = (NSView*)[[self window] firstResponder];
	if([view isKindOfClass:[NSView class]] && [view isDescendantOf:_htmlOutputView])
		[NSApp sendAction:@selector(performCloseSplit:) to:nil from:_htmlOutputView];
	else if([self.window.delegate respondsToSelector:@selector(performClose:)])
		[self.window.delegate performSelector:@selector(performClose:) withObject:sender];
	else
		NSBeep();
}
@end
