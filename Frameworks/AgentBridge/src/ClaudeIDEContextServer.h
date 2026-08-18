#ifndef CLAUDE_IDE_CONTEXT_SERVER_H_WN31TQ8C
#define CLAUDE_IDE_CONTEXT_SERVER_H_WN31TQ8C

#import <Foundation/Foundation.h>

@class AgentBridgeWorkspace;
@class AgentBridgeSelection;

// WebSocket (Network.framework) + JSON-RPC 2.0 / MCP adapter for the Claude
// Code IDE protocol. All protocol knowledge lives in this class; editor
// state is reached exclusively through AgentBridgeWorkspace. The bridge only
// PROVIDES context (open editors, selection, diagnostics) — writes are the
// agent’s own business and are reviewed after the fact against git.
@interface ClaudeIDEContextServer : NSObject
- (instancetype)initWithAuthToken:(NSString*)authToken workspace:(AgentBridgeWorkspace*)workspace;

// readyHandler is called once on the main queue with the bound port (0 on failure).
- (void)startWithReadyHandler:(void(^)(NSUInteger port))readyHandler;
- (void)stop;

@property (nonatomic, readonly) NSUInteger port; // 0 until the listener is ready
@property (nonatomic, readonly, getter = isRunning) BOOL running;
@property (nonatomic, readonly) NSUInteger connectedClientCount; // authorized clients, updated on the main queue

// Called on the main queue whenever running/port/connectedClientCount change.
@property (nonatomic, copy) void(^statusDidChangeHandler)(void);

// Pushes (main queue). One server serves every Claude Code session on the
// machine, so both carry the project they originated in and reach only the
// sessions that project belongs to: the ones launched inside it, plus any
// session whose own working directory names no open project. originProjectPath
// must be captured where the event happened — resolving it later from the
// active window is how a push ends up attributed to the wrong project.
- (void)sendSelectionChanged:(AgentBridgeSelection*)selection originProjectPath:(NSString*)originProjectPath;

// targetCount is how many sessions the mention was sent to; 0 means every
// connected session belongs to another project, which callers report rather
// than retry unaddressed. It counts sessions selected for sending, not
// WebSocket delivery acknowledgements. The handler runs on the main queue.
- (void)sendAtMentionedWithFilePath:(NSString*)filePath lineStart:(NSInteger)lineStart lineEnd:(NSInteger)lineEnd originProjectPath:(NSString*)originProjectPath completionHandler:(void(^)(NSUInteger targetCount))handler;

// Block (bounded) until every already-queued outgoing frame has been handed
// to the socket (main queue). Call before -stop at application termination
// so a quit-time tool reply is not dropped by the connection cancel.
- (void)drainPendingSendsWithTimeout:(NSTimeInterval)timeout;
@end

#endif /* CLAUDE_IDE_CONTEXT_SERVER_H_WN31TQ8C */
