#import "ClaudeIDEContextServer.h"
#import "AgentBridgeTools.h"
#import "AgentBridgeWorkspace.h"
#import "agent_json.h"
#import "agent_tools.h"
#import <document/OakDocument.h>
#import <ns/ns.h>
#import <nlohmann/json.hpp>
#import <Network/Network.h>

using json = nlohmann::json;

using agent_json::dump;
using agent_json::file_uri;
using agent_json::string_arg;

static char const* const kAuthorizationHeaderField = "x-claude-code-ide-authorization";
static char const* const kMCPSubprotocol            = "mcp";

// The protocol needs one or two concurrent clients; the cap only exists so a
// misbehaving local process cannot exhaust our file descriptors.
static NSUInteger const kMaxConnections            = 8;
static NSTimeInterval const kHandshakeTimeout      = 10;
static NSTimeInterval const kSeedDelay             = 0.5; // see seedEditorContextForConnection:
static size_t const kMaximumIncomingMessageSize    = 16 << 20; // 16 MiB

// selection_changed payload per claudecode.nvim’s selection.lua: text (empty
// when nothing is selected), filePath/fileUrl, and an LSP-style start/end
// range with isEmpty — the same shape whether broadcast on selection changes
// or sent once to seed a newly connected client.
//
// The selection fields come from the shared payload, so this notification is
// capped exactly as a tool result is. That matters more here than there:
// Claude reads the current selection from these pushes and only falls back to
// asking, so a cap that lived in the tool path alone would sit on the route
// nobody takes.
static json SelectionChangedParams (AgentBridgeSelection* selection)
{
	json res = [AgentBridgeTools payloadForSelection:selection];
	res["fileUrl"] = selection.filePath ? json(file_uri(selection.filePath)) : json(nullptr);
	return res;
}

static json ContentResult (std::string const& text, bool isError)
{
	json res = { { "content", json::array({ { { "type", "text" }, { "text", text } } }) } };
	if(isError)
		res["isError"] = true;
	return res;
}

@implementation ClaudeIDEContextServer
{
	NSString*             _authToken;
	AgentBridgeWorkspace* _workspace;

	dispatch_queue_t      _queue;
	dispatch_group_t      _sendGroup; // tracks in-flight nw_connection_send completions (see drainPendingSendsWithTimeout:)
	nw_listener_t         _listener;

	// All accessed only on _queue. Handshakes are strictly serialized: at most
	// one connection is started-but-not-ready at any time, so the WS client
	// request handler (same serial queue) always belongs to
	// _handshakingConnection and cancel-on-reject cannot hit a bystander.
	NSMutableArray*       _connections;            // authorized and ready
	NSMutableArray*       _pendingConnections;     // accepted, waiting for their turn to handshake
	nw_connection_t       _handshakingConnection;

	// Main queue only, unlike the collections above. Weak so a dropped
	// connection leaves nothing behind — the seed is a per-connection one-shot,
	// not a lifetime the server needs to track.
	NSHashTable*          _seededConnections;

	BOOL                  _didCallReadyHandler;
}

- (instancetype)initWithAuthToken:(NSString*)authToken workspace:(AgentBridgeWorkspace*)workspace
{
	if(self = [super init])
	{
		_authToken          = [authToken copy];
		_workspace          = workspace;
		_queue              = dispatch_queue_create("com.macromates.TextMate.agent-bridge", DISPATCH_QUEUE_SERIAL);
		_sendGroup          = dispatch_group_create();
		_connections        = [NSMutableArray array];
		_pendingConnections = [NSMutableArray array];
		_seededConnections  = [NSHashTable weakObjectsHashTable];
	}
	return self;
}

// ============
// = Listener =
// ============

- (void)startWithReadyHandler:(void(^)(NSUInteger))readyHandler
{
	dispatch_async(_queue, ^{
		[self setupListenerWithAttemptsRemaining:5 readyHandler:readyHandler];
	});
}

- (void)setupListenerWithAttemptsRemaining:(NSUInteger)attempts readyHandler:(void(^)(NSUInteger))readyHandler // _queue
{
	// The protocol wants a random port in 10000–65535; retry on collision.
	uint16_t requestedPort = 10000 + arc4random_uniform(65536 - 10000);

	nw_parameters_t parameters = nw_parameters_create_secure_tcp(NW_PARAMETERS_DISABLE_PROTOCOL, NW_PARAMETERS_DEFAULT_CONFIGURATION);
	nw_endpoint_t localEndpoint = nw_endpoint_create_host("127.0.0.1", std::to_string(requestedPort).c_str());
	nw_parameters_set_local_endpoint(parameters, localEndpoint);

	nw_protocol_options_t wsOptions = nw_ws_create_options(nw_ws_version_13);
	nw_ws_options_set_auto_reply_ping(wsOptions, true);
	nw_ws_options_set_maximum_message_size(wsOptions, kMaximumIncomingMessageSize);

	__weak ClaudeIDEContextServer* weakSelf = self;
	nw_ws_options_set_client_request_handler(wsOptions, _queue, ^nw_ws_response_t(nw_ws_request_t request){
		ClaudeIDEContextServer* strongSelf = weakSelf;
		return strongSelf ? [strongSelf responseForClientRequest:request] : nw_ws_response_create(nw_ws_response_status_reject, NULL);
	});

	nw_protocol_stack_t protocolStack = nw_parameters_copy_default_protocol_stack(parameters);
	nw_protocol_stack_prepend_application_protocol(protocolStack, wsOptions);

	nw_listener_t listener = nw_listener_create(parameters);
	nw_listener_set_queue(listener, _queue);

	__weak nw_listener_t weakListener = listener;
	nw_listener_set_state_changed_handler(listener, ^(nw_listener_state_t state, nw_error_t error){
		ClaudeIDEContextServer* strongSelf = weakSelf;
		nw_listener_t strongListener = weakListener;
		if(!strongSelf || !strongListener)
			return;

		if(state == nw_listener_state_ready)
		{
			uint16_t boundPort = nw_listener_get_port(strongListener);
			dispatch_async(dispatch_get_main_queue(), ^{
				strongSelf->_port    = boundPort;
				strongSelf->_running = YES;
				if(!strongSelf->_didCallReadyHandler)
				{
					strongSelf->_didCallReadyHandler = YES;
					readyHandler(boundPort);
				}
			});
		}
		else if(state == nw_listener_state_failed)
		{
			int code = error ? nw_error_get_error_code(error) : 0;
			nw_listener_cancel(strongListener);
			if(strongSelf->_listener != strongListener)
				return; // already replaced by a retry

			strongSelf->_listener = nil;
			if(attempts > 1)
			{
				[strongSelf setupListenerWithAttemptsRemaining:attempts-1 readyHandler:readyHandler];
			}
			else
			{
				NSLog(@"[AgentBridge] failed to start WebSocket listener: error %d", code);
				dispatch_async(dispatch_get_main_queue(), ^{
					strongSelf->_running = NO;
					if(!strongSelf->_didCallReadyHandler)
					{
						strongSelf->_didCallReadyHandler = YES;
						readyHandler(0);
					}
				});
			}
		}
	});

	nw_listener_set_new_connection_handler(listener, ^(nw_connection_t connection){
		if(ClaudeIDEContextServer* strongSelf = weakSelf)
			[strongSelf acceptConnection:connection];
		else
			nw_connection_cancel(connection);
	});

	_listener = listener;
	nw_listener_start(listener);
}

- (void)stop
{
	dispatch_async(_queue, ^{
		for(nw_connection_t connection in self->_connections)
			nw_connection_cancel(connection);
		[self->_connections removeAllObjects];

		for(nw_connection_t connection in self->_pendingConnections)
			nw_connection_cancel(connection);
		[self->_pendingConnections removeAllObjects];

		if(self->_handshakingConnection)
			nw_connection_cancel(self->_handshakingConnection);
		self->_handshakingConnection = nil;

		if(self->_listener)
			nw_listener_cancel(self->_listener);
		self->_listener = nil;

		[self publishConnectionCount];
	});
	_running = NO;
}

- (void)publishConnectionCount // _queue
{
	NSUInteger count = _connections.count;
	dispatch_async(dispatch_get_main_queue(), ^{
		if(self->_connectedClientCount == count)
			return;
		self->_connectedClientCount = count;
		if(self->_statusDidChangeHandler)
			self->_statusDidChangeHandler();
	});
}

// ==================
// = Authentication =
// ==================

static bool TokenMatches (NSString* candidate, NSString* expected)
{
	NSData* lhs = [candidate dataUsingEncoding:NSUTF8StringEncoding];
	NSData* rhs = [expected dataUsingEncoding:NSUTF8StringEncoding];
	if(!lhs || !rhs || lhs.length != rhs.length) // length is public (32 hex chars), only the content compare must be constant-time
		return false;
	return timingsafe_bcmp(lhs.bytes, rhs.bytes, rhs.length) == 0;
}

- (nw_ws_response_t)responseForClientRequest:(nw_ws_request_t)request // _queue
{
	__block NSString* token = nil;
	nw_ws_request_enumerate_additional_headers(request, ^bool(char const* name, char const* value){
		if(strcasecmp(name, kAuthorizationHeaderField) == 0)
		{
			token = [NSString stringWithUTF8String:value];
			return false; // first match wins; ignore duplicate headers
		}
		return true;
	});

	if(token && TokenMatches(token, _authToken))
	{
		// Echo the subprotocol back. A client that offers one and is accepted
		// without a selection is entitled to treat that as a failed handshake,
		// and Claude Code does: since it began sending ‘Sec-WebSocket-Protocol:
		// mcp’ (2.1.x) an accept with no selection reads to it as “this server
		// does not speak MCP”, and it drops the connection before a single
		// frame — the IDE still appears in its list, then refuses to connect.
		__block char const* selectedSubprotocol = NULL;
		nw_ws_request_enumerate_subprotocols(request, ^bool(char const* subprotocol){
			if(strcasecmp(subprotocol, kMCPSubprotocol) != 0)
				return true;
			selectedSubprotocol = kMCPSubprotocol; // a literal: the response outlives the enumeration
			return false;
		});
		return nw_ws_response_create(nw_ws_response_status_accept, selectedSubprotocol);
	}

	NSLog(@"[AgentBridge] rejecting WebSocket connection with %s authorization token", token ? "an invalid" : "no");

	// Cancel the connection whose handshake this is, so the client receives
	// the HTTP 400 immediately instead of waiting out its own timeout
	// (verified at runtime: without the cancel the response never flushes).
	// Handshakes are serialized, so this is guaranteed to be the connection
	// this request belongs to.
	if(nw_connection_t doomed = _handshakingConnection)
		dispatch_async(_queue, ^{ nw_connection_cancel(doomed); });

	return nw_ws_response_create(nw_ws_response_status_reject, NULL);
}

// ===============
// = Connections =
// ===============

- (void)acceptConnection:(nw_connection_t)connection // _queue
{
	NSUInteger activeCount = _connections.count + _pendingConnections.count + (_handshakingConnection ? 1 : 0);
	if(activeCount >= kMaxConnections)
	{
		NSLog(@"[AgentBridge] refusing WebSocket connection: limit of %lu concurrent connections reached", kMaxConnections);
		nw_connection_set_queue(connection, _queue);
		nw_connection_start(connection);
		nw_connection_cancel(connection);
		return;
	}

	[_pendingConnections addObject:connection];
	[self startNextHandshakeIfIdle];
}

- (void)startNextHandshakeIfIdle // _queue
{
	if(_handshakingConnection || _pendingConnections.count == 0)
		return;

	nw_connection_t connection = _pendingConnections.firstObject;
	[_pendingConnections removeObjectAtIndex:0];
	_handshakingConnection = connection;

	nw_connection_set_queue(connection, _queue);

	__weak ClaudeIDEContextServer* weakSelf = self;
	nw_connection_set_state_changed_handler(connection, ^(nw_connection_state_t state, nw_error_t error){
		ClaudeIDEContextServer* strongSelf = weakSelf;
		if(!strongSelf)
			return;

		if(state == nw_connection_state_ready)
		{
			if(strongSelf->_handshakingConnection == connection)
				strongSelf->_handshakingConnection = nil;
			if(![strongSelf->_connections containsObject:connection])
			{
				[strongSelf->_connections addObject:connection];
				[strongSelf receiveNextMessageOnConnection:connection];
				[strongSelf publishConnectionCount];
			}
			[strongSelf startNextHandshakeIfIdle];
		}
		else if(state == nw_connection_state_failed || state == nw_connection_state_cancelled)
		{
			if(strongSelf->_handshakingConnection == connection)
				strongSelf->_handshakingConnection = nil;
			[strongSelf->_connections removeObject:connection];
			[strongSelf->_pendingConnections removeObject:connection];
			[strongSelf publishConnectionCount];
			[strongSelf startNextHandshakeIfIdle];
		}
	});
	nw_connection_start(connection);

	// A connection that never completes the upgrade must not hold its file
	// descriptor (or the serialized handshake slot) forever.
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kHandshakeTimeout * NSEC_PER_SEC)), _queue, ^{
		ClaudeIDEContextServer* strongSelf = weakSelf;
		if(strongSelf && strongSelf->_handshakingConnection == connection)
		{
			NSLog(@"[AgentBridge] cancelling connection: WebSocket handshake timed out");
			nw_connection_cancel(connection);
		}
	});
}

- (void)dropConnection:(nw_connection_t)connection // _queue
{
	nw_connection_cancel(connection);
	[_connections removeObject:connection];
}

- (void)receiveNextMessageOnConnection:(nw_connection_t)connection // _queue
{
	__weak ClaudeIDEContextServer* weakSelf = self;
	nw_connection_receive_message(connection, ^(dispatch_data_t content, nw_content_context_t context, bool isComplete, nw_error_t error){
		ClaudeIDEContextServer* strongSelf = weakSelf;
		if(!strongSelf)
			return;

		if(error || (!content && !context))
		{
			[strongSelf dropConnection:connection];
			return;
		}

		bool isText = false, isClose = false;
		if(context)
		{
			if(nw_protocol_metadata_t metadata = nw_content_context_copy_protocol_metadata(context, nw_protocol_copy_ws_definition()))
			{
				nw_ws_opcode_t opcode = nw_ws_metadata_get_opcode(metadata);
				isText  = opcode == nw_ws_opcode_text || opcode == nw_ws_opcode_binary;
				isClose = opcode == nw_ws_opcode_close;
			}
		}

		if(isClose)
		{
			[strongSelf dropConnection:connection];
			return;
		}

		if(content && isText)
			[strongSelf handleIncomingData:(NSData*)content onConnection:connection];

		[strongSelf receiveNextMessageOnConnection:connection];
	});
}

- (void)sendJSON:(json const&)payload toConnection:(nw_connection_t)connection
{
	std::string serialized = dump(payload);
	dispatch_data_t data = dispatch_data_create(serialized.data(), serialized.size(), _queue, DISPATCH_DATA_DESTRUCTOR_DEFAULT);

	nw_protocol_metadata_t metadata = nw_ws_create_metadata(nw_ws_opcode_text);
	nw_content_context_t context = nw_content_context_create("send");
	nw_content_context_set_metadata_for_protocol(context, metadata);
	dispatch_group_enter(_sendGroup);
	dispatch_group_t sendGroup = _sendGroup;
	nw_connection_send(connection, data, context, true, ^(nw_error_t error){
		if(error)
			NSLog(@"[AgentBridge] send failed: error %d", nw_error_get_error_code(error));
		dispatch_group_leave(sendGroup);
	});
}

- (void)drainPendingSendsWithTimeout:(NSTimeInterval)timeout // main queue
{
	// Called right before the deliberate quit-time -stop: a tool reply
	// resolved during application termination (saveDocument and openFile
	// answer from asynchronous completion handlers) is still hopping main →
	// _queue → nw_connection_send at this point, and cancelling the
	// connections first would silently drop it — the CLI would then wait out
	// its own timeout on a call we did answer. The dispatch_sync flushes the
	// hop (every already-queued sendJSON has called nw_connection_send once
	// it returns — _queue blocks never sync back onto the main queue, so
	// this cannot deadlock); the bounded group wait then lets the frames
	// reach the socket.
	dispatch_sync(_queue, ^{});
	dispatch_group_wait(_sendGroup, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)));
}

// ====================
// = JSON-RPC framing =
// ====================

- (void)handleIncomingData:(NSData*)data onConnection:(nw_connection_t)connection // _queue
{
	char const* bytes = (char const*)data.bytes;
	json message = json::parse(bytes, bytes + data.length, nullptr, false);
	if(message.is_discarded() || !message.is_object())
	{
		json parseError = { { "jsonrpc", "2.0" }, { "id", nullptr }, { "error", { { "code", -32700 }, { "message", "Parse error" } } } };
		[self sendJSON:parseError toConnection:connection];
		return;
	}

	dispatch_async(dispatch_get_main_queue(), ^{
		[self dispatchMessage:message onConnection:connection];
	});
}

- (void)sendResult:(json const&)result forRequestId:(json const&)requestId toConnection:(nw_connection_t)connection
{
	json response = { { "jsonrpc", "2.0" }, { "id", requestId }, { "result", result } };
	dispatch_async(_queue, ^{ [self sendJSON:response toConnection:connection]; });
}

- (void)sendErrorWithCode:(int)code message:(std::string const&)message forRequestId:(json const&)requestId toConnection:(nw_connection_t)connection
{
	json response = { { "jsonrpc", "2.0" }, { "id", requestId }, { "error", { { "code", code }, { "message", message } } } };
	dispatch_async(_queue, ^{ [self sendJSON:response toConnection:connection]; });
}

- (void)broadcastNotification:(std::string const&)method params:(json const&)params
{
	json message = { { "jsonrpc", "2.0" }, { "method", method }, { "params", params } };
	dispatch_async(_queue, ^{
		for(nw_connection_t connection in self->_connections)
			[self sendJSON:message toConnection:connection];
	});
}

- (void)sendNotification:(std::string const&)method params:(json const&)params toConnection:(nw_connection_t)connection
{
	json message = { { "jsonrpc", "2.0" }, { "method", method }, { "params", params } };
	dispatch_async(_queue, ^{
		if([self->_connections containsObject:connection]) // may have dropped between main queue and _queue
			[self sendJSON:message toConnection:connection];
	});
}

// ================
// = MCP dispatch =
// ================

- (void)dispatchMessage:(json const&)message onConnection:(nw_connection_t)connection // main queue
{
	// Field accesses are type-guarded (value() throws type_error.302 when a
	// key exists with the wrong type), and the whole dispatch is additionally
	// wrapped so no client payload can take down the main thread.
	bool const hasId = message.contains("id") && !message["id"].is_null();
	json const requestId = hasId ? json(message["id"]) : json(nullptr);

	try {
		[self dispatchMessage:message withRequestId:requestId hasId:hasId onConnection:connection];
	}
	catch(std::exception const& e) {
		NSLog(@"[AgentBridge] exception while dispatching request: %s", e.what());
		if(hasId)
			[self sendErrorWithCode:-32603 message:std::string("Internal error: ") + e.what() forRequestId:requestId toConnection:connection];
	}
}

- (void)dispatchMessage:(json const&)message withRequestId:(json const&)requestId hasId:(bool)hasId onConnection:(nw_connection_t)connection // main queue
{
	std::string const method = string_arg(message, "method");
	json const params = message.contains("params") && message["params"].is_object() ? message["params"] : json::object();

	if(method == "initialize")
	{
		std::string requested;
		if(params.contains("protocolVersion") && params["protocolVersion"].is_string())
			requested = params["protocolVersion"].get<std::string>();

		NSString* appVersion = [NSBundle.mainBundle.infoDictionary objectForKey:@"CFBundleShortVersionString"] ?: @"dev";
		json result = {
			{ "protocolVersion", agent_tools::negotiated_protocol_version(requested) },
			{ "capabilities", {
				{ "logging", json::object() },
				{ "prompts", { { "listChanged", true } } },
				{ "tools",   { { "listChanged", true } } },
			} },
			{ "serverInfo", { { "name", "TextMate" }, { "version", to_s(appVersion) } } },
		};
		[self sendResult:result forRequestId:requestId toConnection:connection];
	}
	else if(method.compare(0, 14, "notifications/") == 0 || method == "ide_connected")
	{
		// notifications/cancelled, … — nothing to do
		if(method == "notifications/initialized" || method == "ide_connected")
			[self seedEditorContextForConnection:connection];
	}
	else if(method == "ping")
	{
		[self sendResult:json::object() forRequestId:requestId toConnection:connection];
	}
	else if(method == "prompts/list")
	{
		json result = { { "prompts", json::array() } };
		[self sendResult:result forRequestId:requestId toConnection:connection];
	}
	else if(method == "tools/list")
	{
		json result = { { "tools", agent_tools::descriptors(agent_tools::claude_websocket) } };
		[self sendResult:result forRequestId:requestId toConnection:connection];
	}
	else if(method == "tools/call")
	{
		[self handleToolCallWithParams:params requestId:requestId onConnection:connection];
	}
	else if(hasId)
	{
		[self sendErrorWithCode:-32601 message:"Method not found: " + method forRequestId:requestId toConnection:connection];
	}
}

// Seed a freshly connected client’s editor context. The CLI only learns the
// active file from selection_changed pushes, so a client that connects after
// the last caret movement would otherwise start blind — “edit this file” then
// targets the wrong document, and stays wrong until the user happens to switch
// tabs.
//
// Sent on a short delay, which is the whole point. Claude Code announces itself
// with notifications/initialized and ide_connected and immediately fires its
// discovery requests; a selection_changed answered in that same instant arrives
// while the client is still starting up and is dropped — observed on the wire:
// the seed went out with the correct path, before the client’s own tools/list
// response, and never reached the conversation, while the identical push from a
// tab switch twenty seconds later did. Waiting until the burst is over costs
// nothing a person can perceive, and computing the selection at send time makes
// the seed describe the editor as it is when the client is ready to hear it.
//
// Once per connection: either announcement triggers it, and clients send both.
- (void)seedEditorContextForConnection:(nw_connection_t)connection // main queue
{
	if([_seededConnections containsObject:connection])
		return;
	[_seededConnections addObject:connection];

	__weak ClaudeIDEContextServer* weakSelf = self;
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kSeedDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		ClaudeIDEContextServer* strongSelf = weakSelf;
		if(!strongSelf)
			return;

		// An empty selection at the caret is the normal no-selection payload.
		// A connection dropped in the meantime is handled by sendNotification:,
		// which checks it is still connected.
		if(AgentBridgeSelection* selection = [strongSelf->_workspace currentSelection])
			[strongSelf sendNotification:"selection_changed" params:SelectionChangedParams(selection) toConnection:connection];
	});
}

// =========
// = Tools =
// =========

// params/requestId are taken BY VALUE on purpose: the asynchronous tool
// completion handlers capture them from blocks, and a block capturing a C++
// reference keeps the reference — which would dangle once the caller’s
// stack frame is gone.
- (void)handleToolCallWithParams:(json)params requestId:(json)requestId onConnection:(nw_connection_t)connection // main queue
{
	std::string const name = string_arg(params, "name");
	json const args = params.contains("arguments") && params["arguments"].is_object() ? params["arguments"] : json::object();

	__weak ClaudeIDEContextServer* weakSelf = self;
	AgentBridgeToolReply reply = ^(std::string const& text, BOOL isError){
		[weakSelf sendResult:ContentResult(text, isError) forRequestId:requestId toConnection:connection];
	};

	// No routing path: Claude finds TextMate through the lock file, not from a
	// working directory, so the frontmost window answers as it always has.
	if(![AgentBridgeTools invokeToolNamed:to_ns(name) arguments:args workspace:_workspace routingPath:nil reply:reply])
		[self sendErrorWithCode:-32601 message:"Unknown tool: " + name forRequestId:requestId toConnection:connection];
}

// ============================
// = Notifications (IDE→CLI) =
// ============================

- (void)sendSelectionChanged:(AgentBridgeSelection*)selection
{
	[self broadcastNotification:"selection_changed" params:SelectionChangedParams(selection)];
}

- (void)sendAtMentionedWithFilePath:(NSString*)filePath lineStart:(NSInteger)lineStart lineEnd:(NSInteger)lineEnd
{
	json params = {
		{ "filePath",  to_s(filePath) },
		{ "lineStart", lineStart },
		{ "lineEnd",   lineEnd },
	};
	[self broadcastNotification:"at_mentioned" params:params];
}
@end
