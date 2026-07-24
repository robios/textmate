#import "TerminalSession.h"
#import "TerminalEmulator.h"
#import "TerminalGridView.h"
#import "PTYController.h"
#include <atomic>
#include <pwd.h>

static NSString* const kUserDefaultsTerminalScrollbackLinesKey = @"terminalScrollbackLines";

@interface TerminalSession ()
{
	std::map<std::string, std::string> _environment;
	std::atomic<bool> _processCheckPending;
	NSUInteger _lastGridColumns, _lastGridRows;
}
@property (nonatomic) NSTimer* processPollTimer; // runs only while a foreground process is shown and polling is allowed
@property (nonatomic) TerminalEmulator* emulator;
@property (nonatomic) PTYController* ptyController;
@property (nonatomic) BOOL shellRequested;
@property (nonatomic, readwrite) BOOL cachedHasRunningProcess;
@property (nonatomic, readwrite) NSString* cachedRunningProcessName;
@property (nonatomic, readwrite) NSString* currentDirectory;
@property (nonatomic, readwrite) NSString* windowTitle;
@property (nonatomic, readwrite) NSString* shellName;
@end

@implementation TerminalSession
+ (void)initialize
{
	[NSUserDefaults.standardUserDefaults registerDefaults:@{
		kUserDefaultsTerminalScrollbackLinesKey: @10000,
	}];
}

- (instancetype)init
{
	if(self = [super init])
	{
		NSInteger scrollback = [NSUserDefaults.standardUserDefaults integerForKey:kUserDefaultsTerminalScrollbackLinesKey];
		_emulator = [[TerminalEmulator alloc] initWithColumns:80 rows:24 maxScrollback:std::max<NSInteger>(scrollback, 0)];
		_gridView = [[TerminalGridView alloc] initWithEmulator:_emulator];

		// The grid view must be an NSScrollView documentView: a plain sibling
		// whose drawRect: runs in the same window commit as OakTextView’s
		// huge tiled layer blanks the text view silently (gutter/minimap
		// pattern; see OakDocumentView.mm).
		NSScrollView* gridScrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
		gridScrollView.borderType                 = NSNoBorder;
		gridScrollView.hasVerticalScroller        = NO;
		gridScrollView.hasHorizontalScroller      = NO;
		gridScrollView.verticalScrollElasticity   = NSScrollElasticityNone;
		gridScrollView.horizontalScrollElasticity = NSScrollElasticityNone;
		gridScrollView.drawsBackground            = NO;
		gridScrollView.documentView               = _gridView;

		_gridView.translatesAutoresizingMaskIntoConstraints = NO;
		[NSLayoutConstraint activateConstraints:@[
			[_gridView.leadingAnchor constraintEqualToAnchor:gridScrollView.contentView.leadingAnchor],
			[_gridView.topAnchor constraintEqualToAnchor:gridScrollView.contentView.topAnchor],
			[_gridView.widthAnchor constraintEqualToAnchor:gridScrollView.contentView.widthAnchor],
			[_gridView.heightAnchor constraintEqualToAnchor:gridScrollView.contentView.heightAnchor],
		]];
		_view = gridScrollView;

		__weak TerminalSession* weakSelf = self;
		_gridView.writeDataHandler = ^(NSData* data){
			TerminalSession* strongSelf = weakSelf;
			[strongSelf->_ptyController writeData:data];
		};
		_gridView.gridSizeChangedHandler = ^(NSUInteger columns, NSUInteger rows, NSUInteger pixelWidth, NSUInteger pixelHeight){
			TerminalSession* strongSelf = weakSelf;
			if(!strongSelf)
				return;
			[strongSelf->_ptyController resizeToColumns:columns rows:rows pixelWidth:pixelWidth pixelHeight:pixelHeight];

			// A transient “cols × rows” readout while resizing — skipped for
			// the initial sizing when the grid first gets its geometry.
			if(strongSelf->_lastGridColumns && strongSelf->_lastGridRows && strongSelf.gridSizeChangedHandler)
				strongSelf.gridSizeChangedHandler(columns, rows);
			strongSelf->_lastGridColumns = columns;
			strongSelf->_lastGridRows    = rows;

			if(strongSelf.shellRequested && !strongSelf.ptyController)
				[strongSelf spawnShell];
		};

		_emulator.pwdChangedHandler = ^(NSString* rawPwd){
			NSString* path = rawPwd;
			if([rawPwd hasPrefix:@"file://"])
				path = [NSURL URLWithString:rawPwd].path ?: rawPwd;
			dispatch_async(dispatch_get_main_queue(), ^{
				TerminalSession* strongSelf = weakSelf;
				if(strongSelf && path.length && ![path isEqualToString:strongSelf.currentDirectory])
				{
					strongSelf.currentDirectory = path;
					[strongSelf noteStateChanged];
				}
			});
		};
		_emulator.titleChangedHandler = ^(NSString* title){
			NSString* copiedTitle = [title copy];
			dispatch_async(dispatch_get_main_queue(), ^{
				TerminalSession* strongSelf = weakSelf;
				if(strongSelf && ![copiedTitle isEqualToString:strongSelf.windowTitle])
				{
					strongSelf.windowTitle = copiedTitle;
					[strongSelf noteStateChanged];
				}
			});
		};
		_emulator.bellHandler = ^{
			dispatch_async(dispatch_get_main_queue(), ^{
				TerminalSession* strongSelf = weakSelf;
				if(strongSelf.bellHandler)
					strongSelf.bellHandler();
			});
		};
		_emulator.clipboardWriteHandler = ^(NSString* text){
			dispatch_async(dispatch_get_main_queue(), ^{
				if(text.length)
				{
					[NSPasteboard.generalPasteboard clearContents];
					[NSPasteboard.generalPasteboard setString:text forType:NSPasteboardTypeString];
				}
			});
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

- (BOOL)hasRunningProcess        { return _ptyController.hasForegroundProcess; }
- (NSString*)runningProcessName  { return _ptyController.foregroundProcessName; }

- (NSString*)displayName
{
	if(_windowTitle.length)
		return _windowTitle;
	if(_cachedHasRunningProcess && _cachedRunningProcessName.length)
		return _cachedRunningProcessName;
	return _shellName ?: [[self loginShellPath] lastPathComponent];
}

- (void)noteStateChanged
{
	if(_stateChangedHandler)
		_stateChangedHandler();
}

- (void)applyDarkPalette:(BOOL)useDarkPalette
{
	if(useDarkPalette)
			[_emulator setDefaultBackgroundColor:(GhosttyColorRgb){ 12, 12, 12 } foregroundColor:(GhosttyColorRgb){ 212, 212, 212 } cursorColor:(GhosttyColorRgb){ 212, 212, 212 }];
	else	[_emulator setDefaultBackgroundColor:(GhosttyColorRgb){ 252, 252, 252 } foregroundColor:(GhosttyColorRgb){ 40, 40, 40 } cursorColor:(GhosttyColorRgb){ 40, 40, 40 }];
	[_gridView refreshFromEmulator];
	_gridView.needsDisplay = YES;
}

- (NSString*)loginShellPath
{
	auto shell = _environment.find("SHELL");
	if(shell != _environment.end() && !shell->second.empty())
		return [NSString stringWithUTF8String:shell->second.c_str()];
	if(struct passwd* entry = getpwuid(getuid()))
	{
		if(entry->pw_shell && *entry->pw_shell)
			return [NSString stringWithUTF8String:entry->pw_shell];
	}
	return @"/bin/zsh";
}

- (void)startShellIfNeeded
{
	_shellRequested = YES;
	if(!_shellName)
		_shellName = [[self loginShellPath] lastPathComponent];
	if(!_ptyController && _gridView.gridColumns > 0)
		[self spawnShell];
}

- (void)spawnShell
{
	NSString* directory = self.workingDirectory ?: NSHomeDirectory();
	NSString* shellPath = [self loginShellPath];
	_shellName = [shellPath lastPathComponent];

	std::map<std::string, std::string> environment = _environment;
	environment["TERM"]         = "xterm-256color";
	environment["TERM_PROGRAM"] = "TextMate";
	if(environment.find("SHELL") == environment.end())
		environment["SHELL"] = shellPath.fileSystemRepresentation;

	NSUInteger columns = std::max<NSUInteger>(_gridView.gridColumns, 20);
	NSUInteger rows    = std::max<NSUInteger>(_gridView.gridRows, 5);
	NSSize cellSize    = _gridView.cellSize;
	CGFloat scale      = _gridView.window.backingScaleFactor ?: 2;

	PTYController* pty = [[PTYController alloc] initWithPath:shellPath.fileSystemRepresentation arguments:{ } environment:environment workingDirectory:directory.fileSystemRepresentation loginShell:YES columns:columns rows:rows pixelWidth:columns * cellSize.width * scale pixelHeight:rows * cellSize.height * scale];

	__weak TerminalSession* weakSelf = self;
	TerminalEmulator* emulator = _emulator;
	pty.readHandler = ^(void const* bytes, size_t length){
		[emulator feedBytes:bytes length:length];
		[weakSelf noteOutputActivity];
	};
	pty.exitHandler = ^(int status){
		dispatch_async(dispatch_get_main_queue(), ^{
			[weakSelf shellDidExitWithStatus:status];
		});
	};

	emulator.writeToPTYHandler = ^(NSData* data){
		[weakSelf.ptyController writeData:data];
	};

	if([pty spawn])
	{
		_ptyController = pty;
		if(!_currentDirectory.length)
			_currentDirectory = directory;
		[self noteStateChanged];
	}
	else
	{
		char const* message = "[failed to start shell]\r\n";
		[_emulator feedBytes:message length:strlen(message)];
	}
}

- (void)shellDidExitWithStatus:(int)status
{
	_ptyController = nil;
	_shellRequested = NO;
	[self updateForegroundProcessInfo];
	if(_exitedHandler)
		_exitedHandler();
}

// ======================
// = Foreground process =
// ======================

// Called on the pty read queue for every output batch. Foreground process
// changes are bracketed by output (the echoed command line before, the next
// prompt after), so piggybacking a coalesced, slightly delayed check on
// output keeps the terminal free of periodic wakeups while idle. The small
// delay lets the shell fork the job before we look at tcgetpgrp.
- (void)noteOutputActivity
{
	bool expected = false;
	if(_processCheckPending.compare_exchange_strong(expected, true))
	{
		__weak TerminalSession* weakSelf = self;
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(250 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
			TerminalSession* strongSelf = weakSelf;
			if(!strongSelf)
				return;
			strongSelf->_processCheckPending = false;
			[strongSelf updateForegroundProcessInfo];
		});
	}
}

// Main thread. While a foreground process is shown (and the host allows
// polling, i.e. the pane is in a window), a slow poll catches silent
// transitions such as `sleep 1; vim` where the job changes without output.
- (void)updateForegroundProcessInfo
{
	BOOL running = _ptyController.hasForegroundProcess;
	NSString* name = running ? (_ptyController.foregroundProcessName ?: @"process") : nil;
	if(running != _cachedHasRunningProcess || (name != _cachedRunningProcessName && ![name isEqualToString:_cachedRunningProcessName]))
	{
		self.cachedHasRunningProcess = running;
		self.cachedRunningProcessName = name;
		[self noteStateChanged];
	}

	BOOL shouldPoll = running && _allowsProcessPolling;
	if(shouldPoll && !_processPollTimer)
	{
		__weak TerminalSession* weakSelf = self;
		_processPollTimer = [NSTimer scheduledTimerWithTimeInterval:2 repeats:YES block:^(NSTimer*){
			[weakSelf updateForegroundProcessInfo];
		}];
		_processPollTimer.tolerance = 0.5;
	}
	else if(!shouldPoll && _processPollTimer)
	{
		[_processPollTimer invalidate];
		_processPollTimer = nil;
	}
}

- (void)setAllowsProcessPolling:(BOOL)flag
{
	if(_allowsProcessPolling == flag)
		return;
	_allowsProcessPolling = flag;
	[self updateForegroundProcessInfo];
}

- (void)shutdown
{
	[_processPollTimer invalidate];
	_processPollTimer = nil;
	[_ptyController shutdown];
	_ptyController = nil;
}
@end
