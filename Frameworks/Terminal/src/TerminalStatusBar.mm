#import "TerminalStatusBar.h"
#import <OakAppKit/OakUIConstructionFunctions.h>

static NSUInteger const kTerminalTabTitleMaxWidth = 110;

// Segment order of the placement switcher (and index ↔ string mapping).
static NSArray<NSString*>* TerminalPlacements ()
{
	return @[ @"left", @"bottom", @"right" ];
}

@implementation TerminalStatusBar
{
	NSStackView* _tabStack;
	NSTextField* _directoryLabel;
	NSTextField* _gridSizeLabel;
	NSTextField* _processLabel;
	NSStackView* _placementStack;
	NSArray<NSButton*>* _placementButtons;
	NSTimer* _gridSizeHideTimer;

	NSArray<NSString*>* _tabTitles;
	NSUInteger _selectedTabIndex;
	NSIndexSet* _activityIndexes;
	NSIndexSet* _unreadIndexes;
}

- (instancetype)initWithFrame:(NSRect)aRect
{
	if(self = [super initWithFrame:aRect])
	{
		self.material     = NSVisualEffectMaterialTitlebar;
		self.blendingMode = NSVisualEffectBlendingModeWithinWindow;
		self.state        = NSVisualEffectStateFollowsWindowActiveState;
		self.wantsLayer   = YES;

		NSView* topDivider = OakCreateNSBoxSeparator();

		_tabStack = [[NSStackView alloc] initWithFrame:NSZeroRect];
		_tabStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
		_tabStack.spacing     = 2;
		[_tabStack setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
		[_tabStack setContentCompressionResistancePriority:NSLayoutPriorityDefaultHigh forOrientation:NSLayoutConstraintOrientationHorizontal];

		_directoryLabel = OakCreateLabel(@"", OakStatusBarFont(), NSTextAlignmentLeft, NSLineBreakByTruncatingHead);
		[_directoryLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];

		_gridSizeLabel = OakCreateLabel(@"", OakStatusBarFont(), NSTextAlignmentRight, NSLineBreakByClipping);
		_gridSizeLabel.textColor = NSColor.secondaryLabelColor;
		_gridSizeLabel.alphaValue = 0;

		_processLabel = OakCreateLabel(@"", OakStatusBarFont(), NSTextAlignmentRight, NSLineBreakByTruncatingTail);

		_placement      = @"right";
		_placementStack = [self createPlacementControl];

		NSDictionary* views = @{
			@"topDivider": topDivider,
			@"tabs":       _tabStack,
			@"directory":  _directoryLabel,
			@"gridSize":   _gridSizeLabel,
			@"process":    _processLabel,
			@"placement":  _placementStack,
		};
		OakAddAutoLayoutViewsToSuperview(views.allValues, self);

		[self addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:|[topDivider]|" options:0 metrics:nil views:views]];
		[self addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"V:|[topDivider(==1)]" options:0 metrics:nil views:views]];
		[self addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:|-4-[tabs]-8-[directory]-(>=8)-[gridSize]-12-[process]-8-[placement]-5-|" options:0 metrics:nil views:views]];
		[self addConstraint:[NSLayoutConstraint constraintWithItem:self attribute:NSLayoutAttributeHeight relatedBy:NSLayoutRelationEqual toItem:nil attribute:NSLayoutAttributeNotAnAttribute multiplier:1 constant:25]];
		[self addConstraint:[NSLayoutConstraint constraintWithItem:_tabStack attribute:NSLayoutAttributeCenterY relatedBy:NSLayoutRelationEqual toItem:self attribute:NSLayoutAttributeCenterY multiplier:1 constant:0.5]];
		[self addConstraint:[NSLayoutConstraint constraintWithItem:_placementStack attribute:NSLayoutAttributeCenterY relatedBy:NSLayoutRelationEqual toItem:self attribute:NSLayoutAttributeCenterY multiplier:1 constant:0.5]];
		for(NSTextField* label in @[ _directoryLabel, _gridSizeLabel, _processLabel ])
			[self addConstraint:[NSLayoutConstraint constraintWithItem:label attribute:NSLayoutAttributeCenterY relatedBy:NSLayoutRelationEqual toItem:self attribute:NSLayoutAttributeCenterY multiplier:1 constant:0.5]];
	}
	return self;
}

// ======================
// = Placement switcher =
// ======================

- (NSStackView*)createPlacementControl
{
	NSArray<NSString*>* symbols  = @[ @"rectangle.lefthalf.inset.filled", @"rectangle.bottomhalf.inset.filled", @"rectangle.righthalf.inset.filled" ];
	NSArray<NSString*>* toolTips = @[ @"Terminal on Left", @"Terminal at Bottom", @"Terminal on Right" ];

	NSImageSymbolConfiguration* configuration = [NSImageSymbolConfiguration configurationWithPointSize:10 weight:NSFontWeightRegular scale:NSImageSymbolScaleSmall];

	NSMutableArray<NSButton*>* buttons = [NSMutableArray array];
	for(NSInteger i = 0; i < 3; ++i)
	{
		NSImage* image = [[NSImage imageWithSystemSymbolName:symbols[i] accessibilityDescription:toolTips[i]] imageWithSymbolConfiguration:configuration];
		[image setTemplate:YES];

		// Styled by the same factory as the tab-strip buttons so the two can’t
		// drift apart — the selected placement must render exactly like the
		// selected tab (accessory-bar dark gray, not the accent color).
		NSButton* button = [self accessoryBarToggleButton];
		button.image   = image;
		button.tag     = i;
		button.action  = @selector(didClickPlacement:);
		button.toolTip = toolTips[i];
		button.state   = [TerminalPlacements()[i] isEqualToString:_placement] ? NSControlStateValueOn : NSControlStateValueOff;
		button.accessibilityLabel = toolTips[i];
		[button.widthAnchor constraintEqualToConstant:24].active = YES;

		// The switcher is tiny and fixed: it must never take part in the
		// squeeze behavior of the tab strip and the readouts.
		[button setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
		[button setContentCompressionResistancePriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];

		[buttons addObject:button];
	}
	_placementButtons = [buttons copy];

	NSStackView* stack = [NSStackView stackViewWithViews:buttons];
	stack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
	stack.spacing     = 2;
	[stack setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
	[stack setContentCompressionResistancePriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
	stack.accessibilityElement = YES;
	stack.accessibilityRole    = NSAccessibilityGroupRole;
	stack.accessibilityLabel   = @"Terminal Placement";

	return stack;
}

- (void)updatePlacementButtonStates
{
	for(NSButton* button in _placementButtons)
		button.state = [TerminalPlacements()[button.tag] isEqualToString:_placement] ? NSControlStateValueOn : NSControlStateValueOff;
}

- (void)setPlacement:(NSString*)aPlacement
{
	if(![TerminalPlacements() containsObject:aPlacement])
		aPlacement = @"right"; // same normalization as ProjectLayoutView
	if([_placement isEqualToString:aPlacement])
		return;
	_placement = [aPlacement copy];
	[self updatePlacementButtonStates];
}

- (void)didClickPlacement:(NSButton*)sender
{
	// Like didClickTab: — a push-on/push-off button flips its own state on
	// click; the model wins. Radio behavior: adopt the clicked placement,
	// then re-render all three from the model (which also snaps the clicked
	// button back when the placement didn’t change).
	NSString* placement = TerminalPlacements()[sender.tag];
	if(![_placement isEqualToString:placement])
	{
		_placement = [placement copy];
		if(_placementChangedHandler)
			_placementChangedHandler(placement);
	}
	[self updatePlacementButtonStates];
}

- (void)dealloc
{
	[_gridSizeHideTimer invalidate];
}

- (void)setWorkingDirectory:(NSString*)aDirectory
{
	_workingDirectory = [aDirectory copy];
	_directoryLabel.stringValue = [aDirectory stringByAbbreviatingWithTildeInPath] ?: @"";
	_directoryLabel.toolTip = aDirectory;
}

- (void)setProcessName:(NSString*)aName
{
	if(_processName == aName || [_processName isEqualToString:aName])
		return;
	_processName = [aName copy];

	if(aName.length)
	{
		NSMutableAttributedString* str = [[NSMutableAttributedString alloc] initWithString:@"● " attributes:@{ NSFontAttributeName: [NSFont systemFontOfSize:8], NSForegroundColorAttributeName: NSColor.systemGreenColor, NSBaselineOffsetAttributeName: @1 }];
		[str appendAttributedString:[[NSAttributedString alloc] initWithString:aName attributes:@{ NSFontAttributeName: OakStatusBarFont(), NSForegroundColorAttributeName: NSColor.secondaryLabelColor }]];
		_processLabel.attributedStringValue = str;
	}
	else
	{
		_processLabel.stringValue = @"";
	}
}

// =============
// = Tab strip =
// =============

- (void)setTabTitles:(NSArray<NSString*>*)titles selectedIndex:(NSUInteger)selectedIndex activityIndexes:(NSIndexSet*)activityIndexes unreadIndexes:(NSIndexSet*)unreadIndexes
{
	if([_tabTitles isEqualToArray:titles] && _selectedTabIndex == selectedIndex && [_activityIndexes isEqualToIndexSet:activityIndexes] && [_unreadIndexes isEqualToIndexSet:unreadIndexes])
		return;
	_tabTitles        = [titles copy];
	_selectedTabIndex = selectedIndex;
	_activityIndexes  = [activityIndexes copy];
	_unreadIndexes    = [unreadIndexes copy];

	for(NSView* view in [_tabStack.arrangedSubviews copy])
	{
		[_tabStack removeArrangedSubview:view];
		[view removeFromSuperview];
	}

	[titles enumerateObjectsUsingBlock:^(NSString* title, NSUInteger i, BOOL* stop){
		NSButton* button = [self tabButtonWithTitle:title activity:[activityIndexes containsIndex:i] unread:[unreadIndexes containsIndex:i]];
		button.tag    = (NSInteger)i;
		button.state  = i == selectedIndex ? NSControlStateValueOn : NSControlStateValueOff;
		button.action = @selector(didClickTab:);
		[_tabStack addArrangedSubview:button];
	}];

	if(titles.count)
	{
		NSButton* addButton = [NSButton buttonWithTitle:@"+" target:self action:@selector(didClickNewTab:)];
		[addButton setButtonType:NSButtonTypeMomentaryPushIn];
		addButton.bezelStyle  = NSBezelStyleAccessoryBar;
		addButton.controlSize = NSControlSizeSmall;
		addButton.font        = OakStatusBarFont();
		addButton.toolTip     = @"New Terminal";
		[_tabStack addArrangedSubview:addButton];
	}
}

// The one place that decides how a selectable bar button looks: the tab
// strip and the placement switcher both build on this, so a selected
// placement renders exactly like a selected tab.
- (NSButton*)accessoryBarToggleButton
{
	NSButton* button = [NSButton buttonWithTitle:@"" target:self action:NULL];
	[button setButtonType:NSButtonTypePushOnPushOff];
	button.bezelStyle  = NSBezelStyleAccessoryBar;
	button.controlSize = NSControlSizeSmall;
	button.font        = OakStatusBarFont();
	return button;
}

- (NSButton*)tabButtonWithTitle:(NSString*)title activity:(BOOL)hasActivity unread:(BOOL)hasUnreadBell
{
	NSButton* button = [self accessoryBarToggleButton];
	button.title = title;
	button.lineBreakMode = NSLineBreakByTruncatingTail;
	button.toolTip     = title;
	[button.widthAnchor constraintLessThanOrEqualToConstant:kTerminalTabTitleMaxWidth].active = YES;

	if(hasActivity || hasUnreadBell)
	{
		NSDictionary* dotAttributes = @{
			NSFontAttributeName:            [NSFont systemFontOfSize:8],
			NSForegroundColorAttributeName: hasUnreadBell ? NSColor.systemOrangeColor : NSColor.systemGreenColor,
			NSBaselineOffsetAttributeName:  @1,
		};
		NSMutableAttributedString* str = [[NSMutableAttributedString alloc] initWithString:@"● " attributes:dotAttributes];
		[str appendAttributedString:[[NSAttributedString alloc] initWithString:title attributes:@{ NSFontAttributeName: OakStatusBarFont(), NSForegroundColorAttributeName: NSColor.labelColor }]];
		button.attributedTitle = str;
	}
	return button;
}

- (void)didClickTab:(NSButton*)sender
{
	// A push-on/push-off button flips its own state on click; snap it back to
	// the model (the handler re-renders the strip only when the selection
	// actually changes, e.g. not when the active tab is clicked again).
	sender.state = (NSUInteger)sender.tag == _selectedTabIndex ? NSControlStateValueOn : NSControlStateValueOff;
	if(_tabSelectedHandler)
		_tabSelectedHandler((NSUInteger)sender.tag);
}

- (void)didClickNewTab:(id)sender
{
	if(_newTabHandler)
		_newTabHandler();
}

- (void)flashGridSize:(NSUInteger)columns rows:(NSUInteger)rows
{
	_gridSizeLabel.stringValue = [NSString stringWithFormat:@"%lu × %lu", (unsigned long)columns, (unsigned long)rows];

	[NSAnimationContext runAnimationGroup:^(NSAnimationContext* context){
		context.duration = 0; // cancel a fade in flight
		self->_gridSizeLabel.animator.alphaValue = 1;
	}];

	[_gridSizeHideTimer invalidate];
	__weak TerminalStatusBar* weakSelf = self;
	_gridSizeHideTimer = [NSTimer timerWithTimeInterval:1 repeats:NO block:^(NSTimer*){
		TerminalStatusBar* strongSelf = weakSelf;
		if(!strongSelf)
			return;
		[NSAnimationContext runAnimationGroup:^(NSAnimationContext* context){
			context.duration = 0.35;
			strongSelf->_gridSizeLabel.animator.alphaValue = 0;
		}];
	}];
	// Common modes so the hide fires during window live-resize and our own
	// divider-drag event-tracking loops.
	[NSRunLoop.currentRunLoop addTimer:_gridSizeHideTimer forMode:NSRunLoopCommonModes];
}
@end
