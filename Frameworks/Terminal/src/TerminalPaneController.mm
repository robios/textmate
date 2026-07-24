#import "TerminalPaneController.h"
#import "TerminalEmulator.h"
#import "TerminalGridView.h"
#import "TerminalStatusBar.h"
#import "PTYController.h"
#import <OakAppKit/OakUIConstructionFunctions.h>
#include <pwd.h>

static NSString* const kUserDefaultsTerminalScrollbackLinesKey = @"terminalScrollbackLines";

@interface TerminalPaneContainerView : NSView
@property (nonatomic, copy) void(^appearanceChangedHandler)(void);
@end

@implementation TerminalPaneContainerView
- (void)viewDidChangeEffectiveAppearance
{
	[super viewDidChangeEffectiveAppearance];
	if(_appearanceChangedHandler)
		_appearanceChangedHandler();
}
@end

@interface TerminalPaneController ()
{
	std::map<std::string, std::string> _environment;
}
@property (nonatomic) TerminalEmulator* emulator;
@property (nonatomic) PTYController* ptyController;
@property (nonatomic) TerminalStatusBar* statusBar;
@property (nonatomic) NSString* currentDirectory; // last OSC 7 report, shown in the status bar
@property (nonatomic) BOOL shellRequested;
@property (nonatomic) BOOL needsReset; // previous session ended; clear the screen before the next spawn
@property (nonatomic) NSColor* themeBackgroundColor;
@property (nonatomic) NSColor* themeForegroundColor;
@end

@implementation TerminalPaneController
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
		_statusBar = [[TerminalStatusBar alloc] initWithFrame:NSZeroRect];

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

		TerminalPaneContainerView* container = [[TerminalPaneContainerView alloc] initWithFrame:NSZeroRect];
		NSDictionary* views = @{ @"grid": gridScrollView, @"status": _statusBar };
		OakAddAutoLayoutViewsToSuperview(views.allValues, container);
		[container addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:|[grid]|" options:0 metrics:nil views:views]];
		[container addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:|[status]|" options:0 metrics:nil views:views]];
		[container addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"V:|[grid][status]|" options:0 metrics:nil views:views]];
		_view = container;

		__weak TerminalPaneController* weakSelf = self;
		container.appearanceChangedHandler = ^{
			[weakSelf updateColors];
		};

		_gridView.writeDataHandler = ^(NSData* data){
			[weakSelf handleInputData:data];
		};
		_gridView.gridSizeChangedHandler = ^(NSUInteger columns, NSUInteger rows, NSUInteger pixelWidth, NSUInteger pixelHeight){
			TerminalPaneController* strongSelf = weakSelf;
			if(!strongSelf)
				return;
			[strongSelf->_ptyController resizeToColumns:columns rows:rows pixelWidth:pixelWidth pixelHeight:pixelHeight];
			if(strongSelf.shellRequested && !strongSelf.ptyController)
				[strongSelf spawnShell];
		};

		_emulator.pwdChangedHandler = ^(NSString* rawPwd){
			NSString* path = rawPwd;
			if([rawPwd hasPrefix:@"file://"])
				path = [NSURL URLWithString:rawPwd].path ?: rawPwd;
			dispatch_async(dispatch_get_main_queue(), ^{
				TerminalPaneController* strongSelf = weakSelf;
				if(strongSelf && path.length)
				{
					strongSelf.currentDirectory = path;
					strongSelf.statusBar.workingDirectory = path;
				}
			});
		};
		_emulator.bellHandler = ^{
			dispatch_async(dispatch_get_main_queue(), ^{
				NSBeep();
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

		[self updateColors];
	}
	return self;
}

- (void)dealloc
{
	[self shutdown];
}

- (std::map<std::string, std::string>)environment                                    { return _environment; }
- (void)setEnvironment:(std::map<std::string, std::string>)newEnvironment            { _environment = newEnvironment; }

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
	if([self prefersDarkPalette])
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
	if(!_ptyController && _gridView.gridColumns > 0)
		[self spawnShell];
	if(!_statusBar.workingDirectory.length)
		_statusBar.workingDirectory = self.workingDirectory;
}

- (void)prepareForFreshSessionIfNeeded
{
	if(!_needsReset)
		return;
	_needsReset = NO;
	_currentDirectory = nil;
	[_emulator reset];
	[_gridView refreshFromEmulator];
	_gridView.needsDisplay = YES;
}

- (void)spawnShell
{
	[self prepareForFreshSessionIfNeeded];

	NSString* directory = self.workingDirectory ?: NSHomeDirectory();
	NSString* shellPath = [self loginShellPath];

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

	__weak TerminalPaneController* weakSelf = self;
	TerminalEmulator* emulator = _emulator;
	pty.readHandler = ^(void const* bytes, size_t length){
		[emulator feedBytes:bytes length:length];
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
		_statusBar.workingDirectory = directory;
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
	_needsReset = YES; // the next open starts a fresh session
	if(_shellExitedHandler)
		_shellExitedHandler();
}

- (void)handleInputData:(NSData*)data
{
	[_ptyController writeData:data];
}

- (void)shutdown
{
	[_ptyController shutdown];
	_ptyController = nil;
}
@end
