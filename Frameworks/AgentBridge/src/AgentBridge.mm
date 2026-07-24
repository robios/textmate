#import "AgentBridge.h"
#import "AgentBridgeLockFile.h"
#import "AgentBridgeServer.h"
#import "AgentBridgeWorkspace.h"
#import <Cocoa/Cocoa.h>

@interface AgentBridge ()
{
	AgentBridgeWorkspace* _workspace;
	AgentBridgeServer*    _server;
	AgentBridgeLockFile*  _lockFile;
}
@end

static AgentBridge* SharedAgentBridge;

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

- (instancetype)init
{
	if(self = [super init])
	{
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
