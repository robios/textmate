#ifndef AGENT_BRIDGE_H_ZK59WPB6
#define AGENT_BRIDGE_H_ZK59WPB6

#import <Foundation/Foundation.h>

// User default (BOOL, default YES): run the Claude Code IDE bridge. The
// bridge reconciles against this key whenever user defaults change, so
// toggling it (Preferences → AI) starts/stops the server at runtime.
extern NSString* const kUserDefaultsAgentBridgeEnabledKey;

// Posted on the main queue whenever the server starts or stops, the port
// changes, or a client connects/disconnects.
extern NSNotificationName const AgentBridgeStatusDidChangeNotification;

// App-global Claude Code IDE bridge: one WebSocket server plus one discovery
// lock file per app instance. Call +setup once at launch (AppController).
// Zero behavior change while no client is connected — the bridge only
// listens on 127.0.0.1 and keeps the lock file current.
@interface AgentBridge : NSObject
+ (void)setup;

// Status for the AI preferences pane.
+ (BOOL)isRunning;
+ (NSUInteger)connectedClientCount;

// Port of the running WebSocket server, 0 if unavailable. Used by
// DocumentWindowController to inject CLAUDE_CODE_SSE_PORT into the
// integrated terminal’s environment.
+ (NSUInteger)serverPort;

// Push a file reference into a connected CLI’s prompt (send path only; no UI yet).
+ (void)sendAtMentionedWithFilePath:(NSString*)filePath lineStart:(NSInteger)lineStart lineEnd:(NSInteger)lineEnd;

// Handler for the tm_agent CLI (requests arrive over the mate socket, see
// RMateServer.mm). Must be called on the main thread. Commands are:
//
//   agent-status  — bridge state (running, port, clients)
//   agent-mention — path, line-start, line-end (0-based)
//   agent-tool    — invoke an MCP context tool on behalf of ‘tm_agent mcp’:
//                   ‘name’, ‘arguments’ (a JSON object, serialized), and ‘cwd’
//                   (the shim’s working directory, which routes the query to
//                   the window whose project contains it). Answers with
//                   ‘result’ (the tool’s content text) and ‘tool-error’.
//
// The pairs handed to the completion block form the wire response: ‘status’ is
// @"ok" or @"error", with @"message" explaining errors. The block may be
// called after this method returns — some tools resolve asynchronously — but
// always on the main thread, and always exactly once.
+ (void)handleCLIRequest:(NSString*)command arguments:(NSDictionary<NSString*, NSString*>*)arguments completionHandler:(void(^)(NSDictionary<NSString*, NSString*>* response))handler;
@end

#endif /* AGENT_BRIDGE_H_ZK59WPB6 */
