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
// Editor-context sharing is an app-global user default.

@interface AIPreferences ()
{
	NSTextField* _copilotStatusText;
	NSButton*    _copilotSignInButton;
	NSButton*    _copilotSignOutButton;
	NSButton*    _copilotRestartButton;
	NSButton*    _copilotEnabledCheckBox;
	NSButton*    _ghostTextOnlyCheckBox;
	NSButton*    _lspEnabledCheckBox;
	NSTextField* _claudeIDEStatusText;
	NSTextField* _codexIDEStatusText;
}
@end

@implementation AIPreferences
- (id)init
{
	if(self = [super initWithNibName:nil label:@"AI" image:PreferencesToolbarImage(@"sparkles", @"AI", nil)])
	{
		self.defaultsProperties = @{
			@"editorContextSharingEnabled": kUserDefaultsEditorContextSharingEnabledKey,
		};

		self.tmProperties = @{
			@"copilotCommand": @"copilotCommand",
			@"codexCommand":   @"codexCommand",
			@"claudeCommand":  @"claudeCommand",
		};

		[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(copilotStatusDidChange:) name:CopilotStatusDidChangeNotification object:nil];
		[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(agentContextStatusDidChange:) name:AgentBridgeStatusDidChangeNotification object:nil];
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

	// ==============================
	// = Agent editor context       =
	// ==============================

	_claudeIDEStatusText = OakCreateLabel(@"");
	_codexIDEStatusText  = OakCreateLabel(@"");

	NSButton* editorContextEnabledCheckBox = OakCreateCheckBox(@"Enable Editor Context Sharing");

	NSButton* copyAgentsButton = OakCreateButton(@"Copy AGENTS.md Guidance");
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

		// Editor Context — rows 13-14. This is the only shared control; provider
		// status belongs in the provider sections below.
		@[ OakCreateLabel(@"Editor Context:"),    editorContextEnabledCheckBox ],                                               // 13
		@[ NSGridCell.emptyContentView,           makeHint(@"Allows Claude Code, Codex, and MCP-compatible agents to read TextMate’s live selection, open editors, and diagnostics") ], // 14

		@[ ], // 15 — separator

		// Claude Code — rows 16-18
		@[ OakCreateLabel(@"Claude Code:"),       _claudeIDEStatusText ],                                                       // 16
		@[ OakCreateLabel(@"Executable:"),        claudePathField ],                                                            // 17
		@[ NSGridCell.emptyContentView,           makeHint(@"Uses Claude Code’s native IDE protocol; leave the executable blank to use claude from PATH") ], // 18

		@[ ], // 19 — separator

		// Codex — rows 20-24
		@[ OakCreateLabel(@"Codex:"),             _codexIDEStatusText ],                                                        // 20
		@[ OakCreateLabel(@"Executable:"),        codexPathField ],                                                             // 21
		@[ NSGridCell.emptyContentView,           makeHint(@"Uses Codex’s native /ide context plus TextMate MCP tools. Terminal → New Codex Terminal configures both for that run; leave the executable blank to use codex from PATH") ], // 22
		@[ NSGridCell.emptyContentView,           copyConfigButton ],                                                           // 23
		@[ NSGridCell.emptyContentView,           makeHint(@"For Codex started outside TextMate, add the MCP snippet to ~/.codex/config.toml") ], // 24

		@[ ], // 25 — separator

		// Other MCP agents — rows 26-27
		@[ OakCreateLabel(@"MCP Agents:"),        copyAgentsButton ],                                                           // 26
		@[ NSGridCell.emptyContentView,           makeHint(@"Other MCP-compatible agents connect through tm_agent mcp. Copy project guidance that tells them when to request TextMate’s current selection, open editors, and diagnostics") ], // 27

	]];

	// The provider sections no longer fit a fixed pane.
	self.view = OakSetupScrollableGridView(gridView, { 9, 12, 15, 19, 25 });

	[serverPathField bind:NSValueBinding toObject:self withKeyPath:@"copilotCommand" options:@{ NSNullPlaceholderBindingOption: @"Auto-detect" }];
	[claudePathField bind:NSValueBinding toObject:self withKeyPath:@"claudeCommand" options:@{ NSNullPlaceholderBindingOption: @"claude (from PATH)" }];
	[codexPathField bind:NSValueBinding toObject:self withKeyPath:@"codexCommand" options:@{ NSNullPlaceholderBindingOption: @"codex (from PATH)" }];
	[editorContextEnabledCheckBox bind:NSValueBinding toObject:self withKeyPath:@"editorContextSharingEnabled" options:nil];
}

- (void)viewWillAppear
{
	[super viewWillAppear];

	_ghostTextOnlyCheckBox.state = settings_for_path().get("copilotGhostTextOnly", false) ? NSControlStateValueOn : NSControlStateValueOff;
	_lspEnabledCheckBox.state    = settings_for_path().get("lspEnabled", true)            ? NSControlStateValueOn : NSControlStateValueOff;

	[self updateCopilotStatus];
	[self updateAgentContextStatus];
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

// ========================
// = Agent editor context =
// ========================

- (void)updateAgentContextStatus
{
	BOOL enabled = [NSUserDefaults.standardUserDefaults boolForKey:kUserDefaultsEditorContextSharingEnabledKey];
	if(!enabled)
	{
		_claudeIDEStatusText.stringValue = @"Disabled";
		_codexIDEStatusText.stringValue  = @"Disabled";
		return;
	}

	if(AgentBridge.isClaudeIDEContextServerRunning)
	{
		NSUInteger clients = AgentBridge.connectedClaudeClientCount;
		_claudeIDEStatusText.stringValue = [NSString stringWithFormat:@"IDE context active — /ide available — %lu client%s", clients, clients == 1 ? "" : "s"];
	}
	else
	{
		_claudeIDEStatusText.stringValue = @"IDE context unavailable";
	}

	_codexIDEStatusText.stringValue = AgentBridge.isCodexIDEContextServerRunning ? @"IDE context active — /ide available" : @"IDE context unavailable";
}

- (void)agentContextStatusDidChange:(NSNotification*)aNotification
{
	if(self.viewLoaded)
		[self updateAgentContextStatus];
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
