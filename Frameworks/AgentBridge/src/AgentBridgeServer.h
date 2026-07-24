#ifndef AGENT_BRIDGE_SERVER_H_WN31TQ8C
#define AGENT_BRIDGE_SERVER_H_WN31TQ8C

#import <Foundation/Foundation.h>

@class AgentBridgeWorkspace;
@class AgentBridgeSelection;

// WebSocket (Network.framework) + JSON-RPC 2.0 / MCP adapter for the Claude
// Code IDE protocol. All protocol knowledge lives in this class; editor
// state is reached exclusively through AgentBridgeWorkspace.
@interface AgentBridgeServer : NSObject
- (instancetype)initWithAuthToken:(NSString*)authToken workspace:(AgentBridgeWorkspace*)workspace;

// readyHandler is called once on the main queue with the bound port (0 on failure).
- (void)startWithReadyHandler:(void(^)(NSUInteger port))readyHandler;
- (void)stop;

@property (nonatomic, readonly) NSUInteger port; // 0 until the listener is ready
@property (nonatomic, readonly, getter = isRunning) BOOL running;

- (void)sendSelectionChanged:(AgentBridgeSelection*)selection;
- (void)sendAtMentionedWithFilePath:(NSString*)filePath lineStart:(NSInteger)lineStart lineEnd:(NSInteger)lineEnd;
@end

#endif /* AGENT_BRIDGE_SERVER_H_WN31TQ8C */
