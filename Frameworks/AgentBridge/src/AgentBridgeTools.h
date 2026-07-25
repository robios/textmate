#ifndef AGENT_BRIDGE_TOOLS_H_D1KX93VN
#define AGENT_BRIDGE_TOOLS_H_D1KX93VN

#import <nlohmann/json.hpp>
#import <Cocoa/Cocoa.h>

@class AgentBridgeSelection;
@class AgentBridgeWorkspace;

// The reply is the MCP tool result’s content text, already serialized (JSON for
// most tools, a sentence for the few that answer in prose), plus whether it is
// an error result. Each frontend wraps it in its own envelope. Called on the
// main queue, possibly after the invocation returns.
typedef void(^AgentBridgeToolReply)(std::string const& text, BOOL isError);

// The one implementation of the MCP tools, shared by both frontends: the
// WebSocket server Claude Code connects to, and the mate-socket seam that
// ‘tm_agent mcp’ forwards to on behalf of every other agent CLI. The frontends
// differ only in transport and in the routing path they can supply — the shim
// knows the cwd its agent was started in, the WebSocket server does not.
@interface AgentBridgeTools : NSObject
// Returns NO for a name no tool answers to, without calling the reply block —
// each frontend reports an unknown tool in its own protocol’s terms.
// ‘arguments’ is taken by value: the asynchronous tools resolve from completion
// handlers, and a block capturing a C++ reference keeps the reference.
+ (BOOL)invokeToolNamed:(NSString*)name arguments:(nlohmann::json)arguments workspace:(AgentBridgeWorkspace*)workspace routingPath:(NSString*)routingPath reply:(AgentBridgeToolReply)reply;

// The fields a selection contributes to any payload describing it: `text`
// (capped, with `truncated`/`message` when it was), `filePath`, and the
// LSP-style range. Both a tool result and the selection_changed notification
// are this plus their own envelope.
//
// Shared because the cap has to be: Claude is *pushed* the selection and only
// asks for it by tool call as a fallback, so a cap that lived only in the tool
// path would be one the main route never passes through.
+ (nlohmann::json)payloadForSelection:(AgentBridgeSelection*)selection;
@end

#endif /* AGENT_BRIDGE_TOOLS_H_D1KX93VN */
