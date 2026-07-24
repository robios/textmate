#import "TerminalPaneController.h"
#import "TerminalSession.h"
#import "TerminalGridView.h"
#import "TerminalStatusBar.h"
#import <OakAppKit/OakUIConstructionFunctions.h>

@interface TerminalPaneContainerView : NSView
@property (nonatomic, copy) void(^appearanceChangedHandler)(void);
@property (nonatomic, copy) void(^windowChangedHandler)(void);
@end

@implementation TerminalPaneContainerView
- (void)viewDidChangeEffectiveAppearance
{
	[super viewDidChangeEffectiveAppearance];
	if(_appearanceChangedHandler)
		_appearanceChangedHandler();
}

- (void)viewDidMoveToWindow
{
	[super viewDidMoveToWindow];
	if(_windowChangedHandler)
		_windowChangedHandler();
}
@end

@interface TerminalPaneController ()
{
	std::map<std::string, std::string> _environment;
}
@property (nonatomic) NSMutableArray<TerminalSession*>* sessions;
@property (nonatomic) NSUInteger activeIndex; // only meaningful while sessions.count > 0
@property (nonatomic) NSView* installedSessionView;
@property (nonatomic) TerminalStatusBar* statusBar;
@property (nonatomic) NSColor* themeBackgroundColor;
@property (nonatomic) NSColor* themeForegroundColor;
@end

@implementation TerminalPaneController
- (instancetype)init
{
	if(self = [super init])
	{
		_sessions  = [NSMutableArray array];
		_statusBar = [[TerminalStatusBar alloc] initWithFrame:NSZeroRect];

		TerminalPaneContainerView* container = [[TerminalPaneContainerView alloc] initWithFrame:NSZeroRect];
		NSDictionary* views = @{ @"status": _statusBar };
		OakAddAutoLayoutViewsToSuperview(views.allValues, container);
		[container addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:|[status]|" options:0 metrics:nil views:views]];
		[container addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"V:[status]|" options:0 metrics:nil views:views]];
		_view = container;

		__weak TerminalPaneController* weakSelf = self;
		container.appearanceChangedHandler = ^{
			[weakSelf updateColors];
		};
		container.windowChangedHandler = ^{
			TerminalPaneController* strongSelf = weakSelf;
			BOOL inWindow = strongSelf.view.window ? YES : NO;
			for(TerminalSession* session in strongSelf.sessions)
				session.allowsProcessPolling = inWindow;
			[strongSelf refreshStatusBar];
		};
		_statusBar.tabSelectedHandler = ^(NSUInteger index){
			[weakSelf selectTerminalAtIndex:index];
		};
		_statusBar.newTabHandler = ^{
			[weakSelf addTerminal];
		};
	}
	return self;
}

- (void)dealloc
{
	[self shutdown];
}

- (std::map<std::string, std::string>)environment                         { return _environment; }
- (void)setEnvironment:(std::map<std::string, std::string>)newEnvironment { _environment = newEnvironment; }

// Placement is app-layout state owned by the window controller; the pane
// just forwards it to the status bar’s switcher (and clicks back out).
- (NSString*)placement                    { return _statusBar.placement; }
- (void)setPlacement:(NSString*)placement { _statusBar.placement = placement; }

- (void)setPlacementChangedHandler:(void(^)(NSString*))handler
{
	_placementChangedHandler = [handler copy];
	_statusBar.placementChangedHandler = _placementChangedHandler;
}

// ==============
// = Aggregates =
// ==============

- (TerminalSession*)activeSession
{
	return _activeIndex < _sessions.count ? _sessions[_activeIndex] : nil;
}

- (TerminalGridView*)gridView             { return self.activeSession.gridView; }
- (NSUInteger)numberOfTerminals           { return _sessions.count; }

- (BOOL)hasRunningProcess
{
	for(TerminalSession* session in _sessions)
	{
		if(session.hasRunningProcess)
			return YES;
	}
	return NO;
}

- (NSArray<NSString*>*)runningProcessNames
{
	NSMutableArray<NSString*>* res = [NSMutableArray array];
	for(TerminalSession* session in _sessions)
	{
		if(session.hasRunningProcess)
		{
			if(NSString* name = session.runningProcessName)
				[res addObject:name];
		}
	}
	return res;
}

- (NSString*)runningProcessName                   { return self.runningProcessNames.firstObject; }
- (BOOL)activeTerminalHasRunningProcess           { return self.activeSession.hasRunningProcess; }
- (NSString*)activeTerminalRunningProcessName     { return self.activeSession.runningProcessName; }

// ==========
// = Colors =
// ==========

- (void)setThemeBackgroundColor:(NSColor*)backgroundColor foregroundColor:(NSColor*)foregroundColor
{
	_themeBackgroundColor = backgroundColor;
	_themeForegroundColor = foregroundColor;
	[self updateColors];
}

// The editor theme only decides dark vs. light; the terminal itself uses a
// neutral palette — the standard ANSI colors are designed against neutral
// backgrounds and clash with saturated theme backgrounds.
- (BOOL)prefersDarkPalette
{
	if(NSColor* srgb = [_themeBackgroundColor colorUsingColorSpace:NSColorSpace.sRGBColorSpace])
		return 0.299*srgb.redComponent + 0.587*srgb.greenComponent + 0.114*srgb.blueComponent < 0.5;
	return [[_view.effectiveAppearance bestMatchFromAppearancesWithNames:@[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ]] isEqualToString:NSAppearanceNameDarkAqua];
}

- (void)updateColors
{
	BOOL dark = [self prefersDarkPalette];
	for(TerminalSession* session in _sessions)
		[session applyDarkPalette:dark];
}

// =====================
// = Session lifecycle =
// =====================

- (TerminalSession*)createSession
{
	TerminalSession* session = [[TerminalSession alloc] init];
	session.workingDirectory = self.workingDirectory;
	session.environment      = _environment;
	[session applyDarkPalette:[self prefersDarkPalette]];
	session.allowsProcessPolling = _view.window ? YES : NO;

	__weak TerminalPaneController* weakSelf = self;
	__weak TerminalSession* weakSession = session;
	session.exitedHandler = ^{
		if(TerminalSession* strongSession = weakSession)
			[weakSelf removeSession:strongSession];
	};
	session.stateChangedHandler = ^{
		[weakSelf refreshStatusBar];
	};
	session.bellHandler = ^{
		NSBeep();
		TerminalPaneController* strongSelf = weakSelf;
		TerminalSession* strongSession = weakSession;
		if(strongSelf && strongSession && strongSession != strongSelf.activeSession)
		{
			strongSession.hasUnreadBell = YES;
			[strongSelf refreshStatusBar];
		}
	};
	session.gridSizeChangedHandler = ^(NSUInteger columns, NSUInteger rows){
		TerminalPaneController* strongSelf = weakSelf;
		if(strongSelf && weakSession == strongSelf.activeSession)
			[strongSelf.statusBar flashGridSize:columns rows:rows];
	};

	return session;
}

- (void)startShellIfNeeded
{
	if(_sessions.count == 0)
	{
		[_sessions addObject:[self createSession]];
		_activeIndex = 0;
		[self installActiveSessionView];
		[self refreshStatusBar];
	}
	for(TerminalSession* session in _sessions)
		[session startShellIfNeeded];
}

- (void)addTerminal
{
	TerminalSession* session = [self createSession];
	NSUInteger insertionIndex = _sessions.count ? _activeIndex + 1 : 0;
	[_sessions insertObject:session atIndex:insertionIndex];
	[self selectTerminalAtIndex:insertionIndex];
	[session startShellIfNeeded]; // spawns once the grid gets its size from layout
}

- (void)selectTerminalAtIndex:(NSUInteger)index
{
	if(index >= _sessions.count)
		return;
	_activeIndex = index;
	self.activeSession.hasUnreadBell = NO;
	[self installActiveSessionView];
	[self refreshStatusBar];
	if(_view.window && self.activeSession)
		[_view.window makeFirstResponder:self.activeSession.gridView];
}

- (void)selectNextTerminal
{
	if(_sessions.count > 1)
		[self selectTerminalAtIndex:(_activeIndex + 1) % _sessions.count];
}

- (void)selectPreviousTerminal
{
	if(_sessions.count > 1)
		[self selectTerminalAtIndex:(_activeIndex + _sessions.count - 1) % _sessions.count];
}

- (void)closeActiveTerminal
{
	if(TerminalSession* session = self.activeSession)
		[self removeSession:session]; // removeSession shuts the session down
}

- (void)removeSession:(TerminalSession*)session
{
	NSUInteger index = [_sessions indexOfObjectIdenticalTo:session];
	if(index == NSNotFound)
		return;

	BOOL wasActive = index == _activeIndex;
	[session shutdown];
	[_sessions removeObjectAtIndex:index];
	if(_activeIndex > index || _activeIndex >= _sessions.count)
		_activeIndex = _activeIndex > 0 ? _activeIndex - 1 : 0;

	if(_sessions.count == 0)
	{
		// Notify before tearing the view out: the owner’s hide path restores
		// editor focus only while the pane (with the focused grid) is still
		// in the window.
		if(_shellExitedHandler)
			_shellExitedHandler();
		[self installActiveSessionView]; // clears the slot
		[self refreshStatusBar];
	}
	else if(wasActive)
	{
		[self selectTerminalAtIndex:_activeIndex]; // adjacent tab takes over, focused
	}
	else
	{
		[self refreshStatusBar];
	}
}

- (void)shutdown
{
	for(TerminalSession* session in _sessions)
		[session shutdown];
}

// ======================
// = View and status bar =
// ======================

- (void)installActiveSessionView
{
	NSView* newView = self.activeSession.view;
	if(_installedSessionView == newView)
		return;

	[_installedSessionView removeFromSuperview];
	_installedSessionView = newView;

	if(newView)
	{
		newView.translatesAutoresizingMaskIntoConstraints = NO;
		[_view addSubview:newView];
		[NSLayoutConstraint activateConstraints:@[
			[newView.leadingAnchor constraintEqualToAnchor:_view.leadingAnchor],
			[newView.trailingAnchor constraintEqualToAnchor:_view.trailingAnchor],
			[newView.topAnchor constraintEqualToAnchor:_view.topAnchor],
			[newView.bottomAnchor constraintEqualToAnchor:_statusBar.topAnchor],
		]];
		[_view layoutSubtreeIfNeeded]; // size the grid now so TIOCSWINSZ is current before the first keystroke
	}
}

- (void)refreshStatusBar
{
	TerminalSession* active = self.activeSession;
	_statusBar.workingDirectory = active.currentDirectory ?: active.workingDirectory ?: self.workingDirectory;
	_statusBar.processName = active.cachedHasRunningProcess ? (active.cachedRunningProcessName ?: @"process") : nil;

	NSMutableArray<NSString*>* titles = [NSMutableArray array];
	NSMutableIndexSet* activity = [NSMutableIndexSet indexSet];
	NSMutableIndexSet* unread   = [NSMutableIndexSet indexSet];
	[_sessions enumerateObjectsUsingBlock:^(TerminalSession* session, NSUInteger i, BOOL* stop){
		[titles addObject:session.displayName ?: @"terminal"];
		if(session.cachedHasRunningProcess)
			[activity addIndex:i];
		if(session.hasUnreadBell)
			[unread addIndex:i];
	}];
	[_statusBar setTabTitles:titles selectedIndex:_activeIndex activityIndexes:activity unreadIndexes:unread];
}
@end
