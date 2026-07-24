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
// RMateServer.mm). Must be called on the main thread. Commands are
// ‘agent-status’ and ‘agent-mention’ (path, line-start, line-end — 0-based);
// the returned pairs form the wire response: ‘status’ is @"ok" or @"error",
// with @"message" explaining errors.
+ (NSDictionary<NSString*, NSString*>*)handleCLIRequest:(NSString*)command arguments:(NSDictionary<NSString*, NSString*>*)arguments;
@end

#endif /* AGENT_BRIDGE_H_ZK59WPB6 */
