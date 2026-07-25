#import "AgentBridge.h"
#import "AgentBridgeTools.h"
#import "ClaudeIDEContextServer.h"
#import "ClaudeIDEContextLockFile.h"
#import "CodexIDEContextServer.h"
#import "agent_tools.h"
#import "AgentBridgeWorkspace.h"
#import <OakSystem/application.h>
#import <ns/ns.h>
#import <nlohmann/json.hpp>
#import <Cocoa/Cocoa.h>

using json = nlohmann::json;

NSString* const kUserDefaultsEditorContextSharingEnabledKey     = @"agentBridgeEnabled";
NSNotificationName const AgentBridgeStatusDidChangeNotification = @"AgentBridgeStatusDidChangeNotification";

@interface AgentBridge ()
{
	AgentBridgeWorkspace*     _workspace;
	ClaudeIDEContextServer*   _claudeIDEContextServer;
	ClaudeIDEContextLockFile* _claudeLockFile;
	CodexIDEContextServer*    _codexIDEContextServer;
}
@end

static AgentBridge* SharedAgentBridge;

// Keep a stable path to the embedded tm_agent CLI so bundle commands can find
// it: the Claude Code bundle declares it via requiredCommands ‘locations’.
// Production and dev builds share the support directory, so the symlink
// points at whichever app instance launched most recently.
static void UpdateCLISymlink ()
{
	NSString* target = [NSBundle.mainBundle.executableURL.URLByDeletingLastPathComponent URLByAppendingPathComponent:@"tm_agent"].path;
	if(![NSFileManager.defaultManager isExecutableFileAtPath:target])
		return;

	NSString* link = to_ns(oak::application_t::support("bin/tm_agent"));
	if([[NSFileManager.defaultManager destinationOfSymbolicLinkAtPath:link error:nil] isEqualToString:target])
		return;

	// Only ever replace a symlink (stale or dangling): if the user parked a
	// real file at this path — say a wrapper script — leave it alone.
	NSString* existingType = [NSFileManager.defaultManager attributesOfItemAtPath:link error:nil].fileType;
	if(existingType && ![existingType isEqualToString:NSFileTypeSymbolicLink])
	{
		NSLog(@"[AgentBridge] not touching %@: existing %@ is not a symlink", link, existingType);
		return;
	}

	NSError* error;
	[NSFileManager.defaultManager createDirectoryAtPath:link.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
	[NSFileManager.defaultManager removeItemAtPath:link error:nil];
	if(![NSFileManager.defaultManager createSymbolicLinkAtPath:link withDestinationPath:target error:&error])
		NSLog(@"[AgentBridge] failed to link tm_agent at %@: %@", link, error.localizedDescription);
}

static NSDictionary<NSString*, NSString*>* ErrorResponse (NSString* message)
{
	return @{ @"status": @"error", @"message": message };
}

// Missing key keeps *line at its current value; anything but a non-negative
// integer is rejected.
static BOOL ParseLineArgument (NSString* value, NSInteger* line)
{
	if(!value)
		return YES;

	char const* str = value.UTF8String;
	char* end = nullptr;
	long res = strtol(str, &end, 10);
	if(end == str || *end != '\0' || res < 0)
		return NO;

	*line = res;
	return YES;
}

@implementation AgentBridge
+ (void)setup
{
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		SharedAgentBridge = [[AgentBridge alloc] init];
	});
}

+ (BOOL)isClaudeIDEContextServerRunning
{
	ClaudeIDEContextServer* server = SharedAgentBridge ? SharedAgentBridge->_claudeIDEContextServer : nil;
	return server.isRunning;
}

+ (NSUInteger)connectedClaudeClientCount
{
	ClaudeIDEContextServer* server = SharedAgentBridge ? SharedAgentBridge->_claudeIDEContextServer : nil;
	return server.connectedClientCount;
}

+ (NSUInteger)claudeIDEContextServerPort
{
	ClaudeIDEContextServer* server = SharedAgentBridge ? SharedAgentBridge->_claudeIDEContextServer : nil;
	return server.isRunning ? server.port : 0;
}

+ (BOOL)isCodexIDEContextServerRunning
{
	CodexIDEContextServer* server = SharedAgentBridge ? SharedAgentBridge->_codexIDEContextServer : nil;
	return server.isRunning;
}

+ (NSString*)codexIDEContextTemporaryDirectory
{
	CodexIDEContextServer* server = SharedAgentBridge ? SharedAgentBridge->_codexIDEContextServer : nil;
	return server.temporaryDirectory;
}

+ (void)sendClaudeAtMentionedWithFilePath:(NSString*)filePath lineStart:(NSInteger)lineStart lineEnd:(NSInteger)lineEnd
{
	if(AgentBridge* bridge = SharedAgentBridge)
		[bridge->_claudeIDEContextServer sendAtMentionedWithFilePath:filePath lineStart:lineStart lineEnd:lineEnd];
}

+ (void)handleCLIRequest:(NSString*)command arguments:(NSDictionary<NSString*, NSString*>*)arguments completionHandler:(void(^)(NSDictionary<NSString*, NSString*>*))handler // main thread
{
	AgentBridge* bridge = SharedAgentBridge;
	ClaudeIDEContextServer* claudeServer = bridge ? bridge->_claudeIDEContextServer : nil;

	if([command isEqualToString:@"agent-status"])
	{
		BOOL const running = claudeServer.isRunning;
		return handler(@{
			@"status":  @"ok",
			@"running": running ? @"yes" : @"no",
			@"port":    [NSString stringWithFormat:@"%lu", (unsigned long)(running ? claudeServer.port : 0)],
			@"clients": [NSString stringWithFormat:@"%lu", (unsigned long)(claudeServer ? claudeServer.connectedClientCount : 0)],
		});
	}

	if([command isEqualToString:@"agent-mention"])
	{
		if(!claudeServer.isRunning)
			return handler(ErrorResponse(@"the Claude IDE context server is not running in TextMate"));

		NSString* path = arguments[@"path"];
		if(path.length == 0)
			return handler(ErrorResponse(@"missing ‘path’ argument"));
		if(!path.absolutePath)
			return handler(ErrorResponse([NSString stringWithFormat:@"path is not absolute: %@", path]));

		path = path.stringByStandardizingPath;
		if(![NSFileManager.defaultManager fileExistsAtPath:path])
			return handler(ErrorResponse([NSString stringWithFormat:@"no such file: %@", path]));

		NSInteger lineStart = 0, lineEnd = 0;
		if(!ParseLineArgument(arguments[@"line-start"], &lineStart) || !ParseLineArgument(arguments[@"line-end"], &lineEnd))
			return handler(ErrorResponse(@"line-start/line-end must be non-negative integers"));
		if(lineEnd < lineStart)
			return handler(ErrorResponse(@"line-end must not be less than line-start"));

		if(claudeServer.connectedClientCount == 0)
			return handler(ErrorResponse(@"no Claude Code client is connected to TextMate"));

		[claudeServer sendAtMentionedWithFilePath:path lineStart:lineStart lineEnd:lineEnd];
		return handler(@{ @"status": @"ok" });
	}

	if([command isEqualToString:@"agent-tool"])
		return [self handleToolRequestWithArguments:arguments completionHandler:handler];

	handler(ErrorResponse([NSString stringWithFormat:@"unknown command: %@", command]));
}

// The stdio MCP shim’s tool calls (‘tm_agent mcp’). Unlike agent-mention this
// does not need the WebSocket server — it is a second, independent frontend —
// but it does follow the same master switch, so turning the bridge off in
// Preferences still means no agent reads this editor.
+ (void)handleToolRequestWithArguments:(NSDictionary<NSString*, NSString*>*)arguments completionHandler:(void(^)(NSDictionary<NSString*, NSString*>*))handler // main thread
{
	AgentBridge* bridge = SharedAgentBridge;
	if(!bridge)
		return handler(ErrorResponse(@"editor context sharing is not set up in TextMate"));
	if(![NSUserDefaults.standardUserDefaults boolForKey:kUserDefaultsEditorContextSharingEnabledKey])
		return handler(ErrorResponse(@"editor context sharing is disabled in TextMate (Preferences → AI)"));

	NSString* name = arguments[@"name"];
	if(name.length == 0)
		return handler(ErrorResponse(@"missing ‘name’ argument"));

	// The shim’s tool table is this route’s contract, stated once here rather
	// than trusted to the client that shares it. Anything reaching the mate
	// socket can ask for a tool the shim never advertised — the socket is
	// local and unprivileged either way, so this is not a boundary — and a
	// websocket-only tool answered here would be answered without the routing
	// its stdio siblings get, which is a wrong answer rather than a refused
	// one. The refusal is the same message the shim would have given.
	if(!agent_tools::advertised(to_s(name), agent_tools::stdio))
		return handler(ErrorResponse([NSString stringWithFormat:@"unknown tool: %@", name]));

	// Arguments travel as one serialized JSON object; anything else is a bug in
	// the caller, not something to guess at.
	json toolArguments = json::object();
	if(NSString* serialized = arguments[@"arguments"])
	{
		std::string const str = to_s(serialized);
		json parsed = json::parse(str.begin(), str.end(), nullptr, false);
		if(parsed.is_discarded() || !parsed.is_object())
			return handler(ErrorResponse(@"‘arguments’ must be a JSON object"));
		toolArguments = parsed;
	}

	__block BOOL didReply = NO;
	BOOL known = [AgentBridgeTools invokeToolNamed:name arguments:toolArguments workspace:bridge->_workspace routingPath:arguments[@"cwd"] reply:^(std::string const& text, BOOL isError){
		if(std::exchange(didReply, YES))
			return; // a tool that answered twice must not corrupt the wire
		handler(@{
			@"status":     @"ok",
			@"result":     to_ns(text),
			@"tool-error": isError ? @"yes" : @"no",
		});
	}];

	if(!known)
		handler(ErrorResponse([NSString stringWithFormat:@"unknown tool: %@", name]));
}

- (instancetype)init
{
	if(self = [super init])
	{
		[NSUserDefaults.standardUserDefaults registerDefaults:@{
			kUserDefaultsEditorContextSharingEnabledKey: @YES,
		}];

		UpdateCLISymlink();

		[ClaudeIDEContextLockFile removeStaleLockFilesInDirectory:[ClaudeIDEContextLockFile defaultLockDirectory]];

		_workspace = [[AgentBridgeWorkspace alloc] init];

		__weak AgentBridge* weakSelf = self;
		_workspace.selectionDidChangeHandler = ^(AgentBridgeSelection* selection){
			if(AgentBridge* strongSelf = weakSelf)
				[strongSelf->_claudeIDEContextServer sendSelectionChanged:selection];
		};
		_workspace.workspaceFoldersDidChangeHandler = ^(NSArray<NSString*>* folders){
			[weakSelf updateLockFile];
		};

		if([NSUserDefaults.standardUserDefaults boolForKey:kUserDefaultsEditorContextSharingEnabledKey])
			[self startContextServices];

		[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(applicationWillTerminate:) name:NSApplicationWillTerminateNotification object:nil];
		[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(userDefaultsDidChange:) name:NSUserDefaultsDidChangeNotification object:nil];
	}
	return self;
}

- (void)startContextServices // main queue
{
	if(_claudeIDEContextServer || _codexIDEContextServer)
		return;

	_codexIDEContextServer = [[CodexIDEContextServer alloc] initWithWorkspace:_workspace];
	if(![_codexIDEContextServer start])
	{
		NSLog(@"[AgentBridge] Codex IDE-context server failed to start; /ide integration is unavailable");
		_codexIDEContextServer = nil;
	}

	NSString* authToken = [ClaudeIDEContextLockFile generateAuthToken];
	ClaudeIDEContextServer* server = [[ClaudeIDEContextServer alloc] initWithAuthToken:authToken workspace:_workspace];
	_claudeIDEContextServer = server;

	__weak AgentBridge* weakSelf = self;
	server.statusDidChangeHandler = ^{
		[weakSelf postStatusNotification];
	};

	[server startWithReadyHandler:^(NSUInteger port){
		AgentBridge* strongSelf = weakSelf;
		if(!strongSelf || strongSelf->_claudeIDEContextServer != server) // stopped (or replaced) before the listener came up
			return;

		if(port == 0)
		{
			NSLog(@"[AgentBridge] Claude IDE-context server failed to start");
			[strongSelf postStatusNotification];
			return;
		}

		strongSelf->_claudeLockFile = [[ClaudeIDEContextLockFile alloc] initWithPort:port authToken:authToken directory:[ClaudeIDEContextLockFile defaultLockDirectory]];
		[strongSelf updateLockFile];
		[strongSelf postStatusNotification];
	}];
}

- (void)stopContextServices // main queue
{
	if(!_claudeIDEContextServer && !_codexIDEContextServer)
		return;

	[_claudeLockFile remove];
	_claudeLockFile = nil;

	[_claudeIDEContextServer stop];
	_claudeIDEContextServer = nil;
	[_codexIDEContextServer stop];
	_codexIDEContextServer = nil;

	[self postStatusNotification];
}

- (void)userDefaultsDidChange:(NSNotification*)aNotification
{
	dispatch_async(dispatch_get_main_queue(), ^{
		BOOL enabled = [NSUserDefaults.standardUserDefaults boolForKey:kUserDefaultsEditorContextSharingEnabledKey];
		if(enabled && !self->_claudeIDEContextServer && !self->_codexIDEContextServer)
			[self startContextServices];
		else if(!enabled && (self->_claudeIDEContextServer || self->_codexIDEContextServer))
			[self stopContextServices];
	});
}

- (void)postStatusNotification
{
	[NSNotificationCenter.defaultCenter postNotificationName:AgentBridgeStatusDidChangeNotification object:nil];
}

- (void)updateLockFile
{
	[_claudeLockFile writeWithWorkspaceFolders:[_workspace workspaceFolders]];
}

- (void)applicationWillTerminate:(NSNotification*)aNotification
{
	[_claudeLockFile remove];
	[_claudeIDEContextServer drainPendingSendsWithTimeout:1.0]; // a quit-time tool reply must reach the socket before the connections are cancelled
	[_claudeIDEContextServer stop];
	[_codexIDEContextServer stop];
}
@end
