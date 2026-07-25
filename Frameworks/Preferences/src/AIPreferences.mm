#import "AIPreferences.h"
#import "Keys.h"
#import <OakAppKit/OakUIConstructionFunctions.h>
#import <lsp/CopilotManager.h>
#import <lsp/LSPManager.h>
#import <AgentBridge/AgentBridge.h>
#import <AgentBridge/AgentSetup.h>
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
			@"codexCommand":   @"codexCommand",
			@"claudeCommand":  @"claudeCommand",
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

	// ==========================================================
	// = Agent Bridge — what every agent CLI shares, then each  =
	// = CLI’s own row. The switch and the AGENTS.md snippet    =
	// = govern both frontends, so they cannot live inside one  =
	// = provider’s section without reading as that provider’s. =
	// ==========================================================

	_bridgeStatusText = OakCreateLabel(@"");

	NSButton* bridgeEnabledCheckBox = OakCreateCheckBox(@"Enable Agent Bridge");

	NSButton* copyAgentsButton = OakCreateButton(@"Copy AGENTS.md Snippet");
	copyAgentsButton.target = self;
	copyAgentsButton.action = @selector(copyAgentsFileSnippet:);

	NSTextField* claudePathField = [NSTextField textFieldWithString:@""];
	[claudePathField.widthAnchor constraintEqualToConstant:360].active = YES;

	NSTextField* codexPathField = [NSTextField textFieldWithString:@""];
	[codexPathField.widthAnchor constraintEqualToConstant:360].active = YES;

	NSButton* copyConfigButton = OakCreateButton(@"Copy config.toml Snippet");
	copyConfigButton.target = self;
	copyConfigButton.action = @selector(copyCodexConfigurationSnippet:);

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

		// Agent Bridge — rows 13-17. Everything shared by every agent CLI: the
		// one switch that governs both frontends, and the house rules that read
		// the same in any project’s AGENTS.md or CLAUDE.md.
		@[ OakCreateLabel(@"Agent Bridge:"),      _bridgeStatusText ],                                                          // 13
		@[ NSGridCell.emptyContentView,           bridgeEnabledCheckBox ],                                                      // 14
		@[ NSGridCell.emptyContentView,           makeHint(@"One switch for both routes into the editor: Claude Code connects as TextMate’s IDE, every other agent CLI reads the same context through the tm_agent MCP server") ], // 15
		@[ NSGridCell.emptyContentView,           copyAgentsButton ],                                                           // 16
		@[ NSGridCell.emptyContentView,           makeHint(@"House rules for a project’s AGENTS.md: when to ask TextMate for the current file, the selection, and diagnostics. Claude Code is pushed that context and needs no snippet") ], // 17

		@[ ], // 18 — separator

		// Claude Code — rows 19-20
		@[ OakCreateLabel(@"Claude Code:"),       claudePathField ],                                                            // 19
		@[ NSGridCell.emptyContentView,           makeHint(@"Path to the claude executable; leave blank to use the one on PATH. Terminal → New Claude Code Terminal starts it already able to see this window") ], // 20

		@[ ], // 21 — separator

		// Codex — rows 22-25
		@[ OakCreateLabel(@"Codex:"),             codexPathField ],                                                            // 22
		@[ NSGridCell.emptyContentView,           makeHint(@"Path to the codex executable; leave blank to use the one on PATH. Terminal → New Codex Terminal registers TextMate’s MCP server for that run and leaves your config.toml alone") ], // 23
		@[ NSGridCell.emptyContentView,           copyConfigButton ],                                                           // 24
		@[ NSGridCell.emptyContentView,           makeHint(@"For a Codex you start yourself instead: paste the snippet into ~/.codex/config.toml") ], // 25

	]];

	// Four providers’ worth of rows no longer fit a fixed pane.
	self.view = OakSetupScrollableGridView(gridView, { 9, 12, 18, 21 });

	[serverPathField bind:NSValueBinding toObject:self withKeyPath:@"copilotCommand" options:@{ NSNullPlaceholderBindingOption: @"Auto-detect" }];
	[claudePathField bind:NSValueBinding toObject:self withKeyPath:@"claudeCommand" options:@{ NSNullPlaceholderBindingOption: @"claude (from PATH)" }];
	[codexPathField bind:NSValueBinding toObject:self withKeyPath:@"codexCommand" options:@{ NSNullPlaceholderBindingOption: @"codex (from PATH)" }];
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
		// The port and the client count belong to the WebSocket half; the stdio
		// shim connects per tool call and has neither. Say which is being
		// reported, now that the section covers both.
		NSUInteger clients = AgentBridge.connectedClientCount;
		_bridgeStatusText.stringValue = [NSString stringWithFormat:@"IDE server on port %lu — %lu client%s connected", AgentBridge.serverPort, clients, clients == 1 ? "" : "s"];
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

// =========
// = Codex =
// =========

// Snippets are copied, never written: both files belong to the user (one is
// their global Codex configuration, the other is checked into their project),
// and nothing here has any business editing either.
- (void)copyToPasteboard:(NSString*)string
{
	NSPasteboard* pasteboard = NSPasteboard.generalPasteboard;
	[pasteboard clearContents];
	[pasteboard writeObjects:@[ string ]];
}

- (void)copyCodexConfigurationSnippet:(id)sender
{
	[self copyToPasteboard:[AgentSetup codexConfigurationSnippet]];
}

- (void)copyAgentsFileSnippet:(id)sender
{
	[self copyToPasteboard:[AgentSetup agentsFileSnippet]];
}
@end
