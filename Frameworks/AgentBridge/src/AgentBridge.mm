#import "AgentBridge.h"
#import "AgentBridgeLockFile.h"
#import "AgentBridgeServer.h"
#import "AgentBridgeWorkspace.h"
#import <OakSystem/application.h>
#import <ns/ns.h>
#import <Cocoa/Cocoa.h>

@interface AgentBridge ()
{
	AgentBridgeWorkspace* _workspace;
	AgentBridgeServer*    _server;
	AgentBridgeLockFile*  _lockFile;
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

+ (NSUInteger)serverPort
{
	AgentBridgeServer* server = SharedAgentBridge ? SharedAgentBridge->_server : nil;
	return server.isRunning ? server.port : 0;
}

+ (void)sendAtMentionedWithFilePath:(NSString*)filePath lineStart:(NSInteger)lineStart lineEnd:(NSInteger)lineEnd
{
	if(AgentBridge* bridge = SharedAgentBridge)
		[bridge->_server sendAtMentionedWithFilePath:filePath lineStart:lineStart lineEnd:lineEnd];
}

+ (NSDictionary<NSString*, NSString*>*)handleCLIRequest:(NSString*)command arguments:(NSDictionary<NSString*, NSString*>*)arguments // main thread
{
	AgentBridge* bridge = SharedAgentBridge;
	AgentBridgeServer* server = bridge ? bridge->_server : nil;

	if([command isEqualToString:@"agent-status"])
	{
		BOOL const running = server.isRunning;
		return @{
			@"status":  @"ok",
			@"running": running ? @"yes" : @"no",
			@"port":    [NSString stringWithFormat:@"%lu", (unsigned long)(running ? server.port : 0)],
			@"clients": [NSString stringWithFormat:@"%lu", (unsigned long)(server ? server.connectedClientCount : 0)],
		};
	}

	if([command isEqualToString:@"agent-mention"])
	{
		if(!server.isRunning)
			return ErrorResponse(@"the agent bridge is not running in TextMate");

		NSString* path = arguments[@"path"];
		if(path.length == 0)
			return ErrorResponse(@"missing ‘path’ argument");
		if(!path.absolutePath)
			return ErrorResponse([NSString stringWithFormat:@"path is not absolute: %@", path]);

		path = path.stringByStandardizingPath;
		if(![NSFileManager.defaultManager fileExistsAtPath:path])
			return ErrorResponse([NSString stringWithFormat:@"no such file: %@", path]);

		NSInteger lineStart = 0, lineEnd = 0;
		if(!ParseLineArgument(arguments[@"line-start"], &lineStart) || !ParseLineArgument(arguments[@"line-end"], &lineEnd))
			return ErrorResponse(@"line-start/line-end must be non-negative integers");
		if(lineEnd < lineStart)
			return ErrorResponse(@"line-end must not be less than line-start");

		if(server.connectedClientCount == 0)
			return ErrorResponse(@"no agent client is connected to TextMate");

		[server sendAtMentionedWithFilePath:path lineStart:lineStart lineEnd:lineEnd];
		return @{ @"status": @"ok" };
	}

	return ErrorResponse([NSString stringWithFormat:@"unknown command: %@", command]);
}

- (instancetype)init
{
	if(self = [super init])
	{
		UpdateCLISymlink();

		[AgentBridgeLockFile removeStaleLockFilesInDirectory:[AgentBridgeLockFile defaultLockDirectory]];

		NSString* authToken = [AgentBridgeLockFile generateAuthToken];

		_workspace = [[AgentBridgeWorkspace alloc] init];
		_server    = [[AgentBridgeServer alloc] initWithAuthToken:authToken workspace:_workspace];

		__weak AgentBridge* weakSelf = self;
		_workspace.selectionDidChangeHandler = ^(AgentBridgeSelection* selection){
			if(AgentBridge* strongSelf = weakSelf)
				[strongSelf->_server sendSelectionChanged:selection];
		};
		_workspace.workspaceFoldersDidChangeHandler = ^(NSArray<NSString*>* folders){
			[weakSelf updateLockFile];
		};

		[_server startWithReadyHandler:^(NSUInteger port){
			AgentBridge* strongSelf = weakSelf;
			if(!strongSelf)
				return;

			if(port == 0)
			{
				NSLog(@"[AgentBridge] WebSocket server failed to start; Claude Code IDE integration is unavailable");
				return;
			}

			strongSelf->_lockFile = [[AgentBridgeLockFile alloc] initWithPort:port authToken:authToken directory:[AgentBridgeLockFile defaultLockDirectory]];
			[strongSelf updateLockFile];
		}];

		[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(applicationWillTerminate:) name:NSApplicationWillTerminateNotification object:nil];
	}
	return self;
}

- (void)updateLockFile
{
	[_lockFile writeWithWorkspaceFolders:[_workspace workspaceFolders]];
}

- (void)applicationWillTerminate:(NSNotification*)aNotification
{
	[_lockFile remove];
	[_server stop];
}
@end
