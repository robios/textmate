#import "AIPreferences.h"
#import "Keys.h"
#import <OakAppKit/OakUIConstructionFunctions.h>
#import <lsp/CopilotManager.h>
#import <lsp/LSPManager.h>
#import <AgentBridge/AgentBridge.h>
#import <settings/settings.h>
#import <ns/ns.h>

// The Copilot settings on this pane (copilotEnabled, copilotGhostTextOnly,
// copilotCommand) live in TextMate’s settings system — the pane reads the
// effective global value via settings_for_path() and writes with
// settings_t::set(), i.e. ~/Library/Application Support/TextMate/
// Global.tmProperties — not NSUserDefaults. Projects can still override any
// of them per directory, file type, or scope through .tm_properties files.
// The Agent Bridge keys are app-global user defaults.

@interface AIPreferences ()
{
	NSTextField* _copilotStatusText;
	NSButton*    _copilotSignInButton;
	NSButton*    _copilotSignOutButton;
	NSButton*    _copilotRestartButton;
	NSButton*    _copilotEnabledCheckBox;
	NSButton*    _ghostTextOnlyCheckBox;
	NSButton*    _lspEnabledCheckBox;
	NSTextField*   _bridgeStatusText;
}
@end

@implementation AIPreferences
- (id)init
{
	if(self = [super initWithNibName:nil label:@"AI" image:PreferencesToolbarImage(@"sparkles", @"AI", nil)])
	{
		self.defaultsProperties = @{
			@"agentBridgeEnabled": kUserDefaultsAgentBridgeEnabledKey,
		};

		self.tmProperties = @{
			@"copilotCommand": @"copilotCommand",
		};

		[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(copilotStatusDidChange:) name:CopilotStatusDidChangeNotification object:nil];
		[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(agentBridgeStatusDidChange:) name:AgentBridgeStatusDidChangeNotification object:nil];
	}
	return self;
}

- (void)loadView
{
	NSFont* hintFont   = [NSFont systemFontOfSize:[NSFont systemFontSizeForControlSize:NSControlSizeSmall]];
	NSColor* hintColor = NSColor.secondaryLabelColor;

	NSTextField* (^makeHint)(NSString*) = ^NSTextField* (NSString* text) {
		NSTextField* label = OakCreateLabel(text, hintFont);
		label.textColor = hintColor;
		label.lineBreakMode = NSLineBreakByWordWrapping;
		label.maximumNumberOfLines = 3;
		return label;
	};

	// =====================
	// = Copilot section   =
	// =====================

	_copilotStatusText = OakCreateLabel(@"");

	_copilotSignInButton = OakCreateButton(@"Sign In…");
	_copilotSignInButton.target = self;
	_copilotSignInButton.action = @selector(copilotSignIn:);

	_copilotSignOutButton = OakCreateButton(@"Sign Out");
	_copilotSignOutButton.target = self;
	_copilotSignOutButton.action = @selector(copilotSignOut:);

	_copilotRestartButton = OakCreateButton(@"Restart Server");
	_copilotRestartButton.target = self;
	_copilotRestartButton.action = @selector(copilotRestartServer:);

	NSStackView* accountStackView = [NSStackView stackViewWithViews:@[ _copilotSignInButton, _copilotSignOutButton, _copilotRestartButton ]];

	_copilotEnabledCheckBox = OakCreateCheckBox(@"Enable Copilot");
	_copilotEnabledCheckBox.target = self;
	_copilotEnabledCheckBox.action = @selector(toggleCopilotEnabled:);

	_ghostTextOnlyCheckBox = OakCreateCheckBox(@"Ghost text only (no popup)");
	_ghostTextOnlyCheckBox.target = self;
	_ghostTextOnlyCheckBox.action = @selector(toggleGhostTextOnly:);

	NSTextField* serverPathField = [NSTextField textFieldWithString:@""];
	[serverPathField.widthAnchor constraintEqualToConstant:360].active = YES;

	// ===============
	// = LSP section =
	// ===============

	_lspEnabledCheckBox = OakCreateCheckBox(@"Enable LSP");
	_lspEnabledCheckBox.target = self;
	_lspEnabledCheckBox.action = @selector(toggleLSPEnabled:);

	// =======================
	// = Agent Bridge section =
	// =======================

	_bridgeStatusText = OakCreateLabel(@"");

	NSButton* bridgeEnabledCheckBox = OakCreateCheckBox(@"Enable Agent Bridge");

	NSGridView* gridView = [NSGridView gridViewWithViews:@[
		// Copilot — rows 0-8
		@[ OakCreateLabel(@"Copilot:"),      _copilotStatusText ],                                                              // 0
		@[ NSGridCell.emptyContentView,      accountStackView ],                                                                // 1
		@[ NSGridCell.emptyContentView,      _copilotEnabledCheckBox ],                                                         // 2
		@[ NSGridCell.emptyContentView,      makeHint(@"Requests inline completions from GitHub Copilot while you type") ],     // 3
		@[ NSGridCell.emptyContentView,      _ghostTextOnlyCheckBox ],                                                          // 4
		@[ NSGridCell.emptyContentView,      makeHint(@"Never shows the completion popup; multiple suggestions appear as ghost text only") ], // 5
		@[ OakCreateLabel(@"Server path:"),  serverPathField ],                                                                 // 6
		@[ NSGridCell.emptyContentView,      makeHint(@"Path to copilot-language-server; leave blank to auto-detect (PATH, npm)") ], // 7
		@[ NSGridCell.emptyContentView,      makeHint(@"These settings are stored in TextMate’s global settings and can be overridden per project via .tm_properties") ], // 8

		@[ ], // 9 — separator

		// LSP — rows 10-11
		@[ OakCreateLabel(@"LSP:"),          _lspEnabledCheckBox ],                                                             // 10
		@[ NSGridCell.emptyContentView,      makeHint(@"Master switch for language servers; the status-bar LSP menu can disable single languages, and .tm_properties can override either per project") ], // 11

		@[ ], // 12 — separator

		// Agent Bridge — rows 13-15
		@[ OakCreateLabel(@"Agent Bridge:"), _bridgeStatusText ],                                                               // 13
		@[ NSGridCell.emptyContentView,      bridgeEnabledCheckBox ],                                                           // 14
		@[ NSGridCell.emptyContentView,      makeHint(@"Lets Claude Code connect to TextMate as its IDE (WebSocket server on 127.0.0.1)") ], // 15

	]];

	self.view = OakSetupGridViewWithSeparators(gridView, { 9, 12 });

	[serverPathField bind:NSValueBinding toObject:self withKeyPath:@"copilotCommand" options:@{ NSNullPlaceholderBindingOption: @"Auto-detect" }];
	[bridgeEnabledCheckBox bind:NSValueBinding toObject:self withKeyPath:@"agentBridgeEnabled" options:nil];
}

- (void)viewWillAppear
{
	[super viewWillAppear];

	_ghostTextOnlyCheckBox.state = settings_for_path().get("copilotGhostTextOnly", false) ? NSControlStateValueOn : NSControlStateValueOff;
	_lspEnabledCheckBox.state    = settings_for_path().get("lspEnabled", true)            ? NSControlStateValueOn : NSControlStateValueOff;

	[self updateCopilotStatus];
	[self updateAgentBridgeStatus];
}

// ===========
// = Copilot =
// ===========

- (void)updateCopilotStatus
{
	CopilotManager* copilot = CopilotManager.sharedManager;

	NSString* statusText;
	switch(copilot.status)
	{
		case CopilotStatusReady:
			statusText = [NSString stringWithFormat:@"Signed in as %@", copilot.username ?: @"(unknown)"];
			break;
		case CopilotStatusConnecting:
			statusText = @"Connecting…";
			break;
		case CopilotStatusAuthRequired:
			statusText = @"Sign-in required";
			break;
		case CopilotStatusError:
			statusText = @"Server error — is copilot-language-server installed?";
			break;
		default:
			statusText = @"Disabled";
			break;
	}
	_copilotStatusText.stringValue = statusText;

	// Re-read the setting here as well: the status-bar AI menu writes the same
	// key and triggers a status notification, so an open pane stays in sync.
	_copilotEnabledCheckBox.state = settings_for_path().get("copilotEnabled", false) ? NSControlStateValueOn : NSControlStateValueOff;

	_copilotSignInButton.enabled  = copilot.status == CopilotStatusAuthRequired;
	_copilotSignOutButton.enabled = copilot.status == CopilotStatusReady;
	_copilotRestartButton.enabled = copilot.status != CopilotStatusDisabled;
}

- (void)copilotStatusDidChange:(NSNotification*)aNotification
{
	if(self.viewLoaded)
		[self updateCopilotStatus];
}

- (void)copilotSignIn:(id)sender
{
	[CopilotManager.sharedManager signIn];
}

- (void)copilotSignOut:(id)sender
{
	[CopilotManager.sharedManager signOut];
}

- (void)copilotRestartServer:(id)sender
{
	// Stop the server, then start it again if copilotEnabled says so; open
	// documents re-register with the fresh client on their next completion
	// request or focus change.
	CopilotManager* copilot = CopilotManager.sharedManager;
	[copilot shutdown];
	[copilot reloadSettings];
}

- (void)toggleCopilotEnabled:(NSButton*)sender
{
	settings_t::set("copilotEnabled", sender.state == NSControlStateValueOn ? true : false); // invalidates the settings cache synchronously
	[CopilotManager.sharedManager reloadSettings];
}

- (void)toggleGhostTextOnly:(NSButton*)sender
{
	settings_t::set("copilotGhostTextOnly", sender.state == NSControlStateValueOn ? true : false);
}

// =======
// = LSP =
// =======

- (void)toggleLSPEnabled:(NSButton*)sender
{
	BOOL enable = sender.state == NSControlStateValueOn;
	settings_t::set("lspEnabled", enable ? true : false); // invalidates the settings cache synchronously

	// Master off tears every client down; master on asks the visible
	// documents to reconnect right away (the reconnectDocuments flag is
	// handled by OakDocumentView) — other documents still reattach lazily on
	// focus. Both paths end in LSPServerStatusDidChangeNotification so the
	// status-bar indicators show or hide immediately.
	if(!enable)
			[LSPManager.sharedManager shutdownAll];
	else	[NSNotificationCenter.defaultCenter postNotificationName:LSPServerStatusDidChangeNotification object:self userInfo:@{ @"reconnectDocuments": @YES }];
}

// ================
// = Agent Bridge =
// ================

- (void)updateAgentBridgeStatus
{
	if(AgentBridge.isRunning)
	{
		NSUInteger clients = AgentBridge.connectedClientCount;
		_bridgeStatusText.stringValue = [NSString stringWithFormat:@"Running on port %lu — %lu client%s connected", AgentBridge.serverPort, clients, clients == 1 ? "" : "s"];
	}
	else
	{
		_bridgeStatusText.stringValue = @"Stopped";
	}
}

- (void)agentBridgeStatusDidChange:(NSNotification*)aNotification
{
	if(self.viewLoaded)
		[self updateAgentBridgeStatus];
}
@end
