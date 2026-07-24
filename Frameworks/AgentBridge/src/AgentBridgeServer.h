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
@property (nonatomic, readonly) NSUInteger connectedClientCount; // authorized clients, updated on the main queue

// Called on the main queue whenever running/port/connectedClientCount change.
@property (nonatomic, copy) void(^statusDidChangeHandler)(void);

- (void)sendSelectionChanged:(AgentBridgeSelection*)selection;
- (void)sendAtMentionedWithFilePath:(NSString*)filePath lineStart:(NSInteger)lineStart lineEnd:(NSInteger)lineEnd;

// Orphan every pending review session (main queue). Must be called before a
// deliberate -stop: the per-connection orphaning normally done by the
// connection-cancelled handlers only holds a weak server reference, so once
// the owner releases the stopped server those handlers may never run.
- (void)orphanAllSessions;
@end

#endif /* AGENT_BRIDGE_SERVER_H_WN31TQ8C */
