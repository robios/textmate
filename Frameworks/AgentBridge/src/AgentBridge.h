#ifndef AGENT_BRIDGE_H_ZK59WPB6
#define AGENT_BRIDGE_H_ZK59WPB6

#import <Foundation/Foundation.h>

// App-global Claude Code IDE bridge: one WebSocket server plus one discovery
// lock file per app instance. Call +setup once at launch (AppController).
// Zero behavior change while no client is connected — the bridge only
// listens on 127.0.0.1 and keeps the lock file current.
@interface AgentBridge : NSObject
+ (void)setup;

// Port of the running WebSocket server, 0 if unavailable. Used by
// DocumentWindowController to inject CLAUDE_CODE_SSE_PORT into the
// integrated terminal’s environment.
+ (NSUInteger)serverPort;

// Push a file reference into a connected CLI’s prompt (send path only; no UI yet).
+ (void)sendAtMentionedWithFilePath:(NSString*)filePath lineStart:(NSInteger)lineStart lineEnd:(NSInteger)lineEnd;
@end

#endif /* AGENT_BRIDGE_H_ZK59WPB6 */
