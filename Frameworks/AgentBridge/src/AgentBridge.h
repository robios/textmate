#ifndef AGENT_BRIDGE_H_ZK59WPB6
#define AGENT_BRIDGE_H_ZK59WPB6

#import <Foundation/Foundation.h>

// User default (BOOL, default YES): share TextMate's live editor context with
// agent CLIs. The bridge reconciles against this key whenever user defaults
// change, so toggling it (Preferences → AI) starts/stops both native IDE
// context servers and disables/enables the generic MCP route at runtime.
extern NSString* const kUserDefaultsEditorContextSharingEnabledKey;

// Posted on the main queue whenever a context service starts or stops, the
// Claude server port changes, or a Claude client connects/disconnects.
extern NSNotificationName const AgentBridgeStatusDidChangeNotification;

// App-global coordinator for agent-facing editor context. It owns the shared
// workspace model, Claude Code's WebSocket IDE-context server, Codex's local
// IDE-context IPC server, and the generic `tm_agent mcp` request seam. Call
// +setup once at launch (AppController).
@interface AgentBridge : NSObject
+ (void)setup;

// Provider-specific status for the AI preferences pane.
+ (BOOL)isClaudeIDEContextServerRunning;
+ (NSUInteger)connectedClaudeClientCount;
+ (NSUInteger)claudeIDEContextServerPort; // 0 if unavailable
+ (BOOL)isCodexIDEContextServerRunning;

// Private TMPDIR containing TextMate's fallback Codex IDE-context Unix socket.
// TextMate normally joins Codex's primary IPC router; the integrated terminal
// inherits this value so /ide still works when that router is unavailable.
// nil while the bridge is disabled or failed to start.
+ (NSString*)codexIDEContextTemporaryDirectory;

// Push a file reference into a connected Claude Code prompt. originProjectPath
// is the project the mention comes from — the initiating window’s — and scopes
// it to the sessions working on that project; a mention nobody is listening
// for is logged rather than sent to the sessions that are listening for
// something else.
+ (void)sendClaudeAtMentionedWithFilePath:(NSString*)filePath lineStart:(NSInteger)lineStart lineEnd:(NSInteger)lineEnd originProjectPath:(NSString*)originProjectPath;

// Handler for the tm_agent CLI (requests arrive over the mate socket, see
// RMateServer.mm). Must be called on the main thread. Commands are:
//
//   agent-status  — Claude IDE server state (legacy wire name)
//   agent-mention — send Claude a path, line-start, line-end (0-based), and
//                   ‘cwd’ (the caller’s working directory). The mention goes
//                   to the sessions running in the project that contains that
//                   directory, or failing that the mentioned path; a mention
//                   inside no open project, or with no session listening for
//                   it, is refused with an explanation rather than sent to
//                   sessions working elsewhere.
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
