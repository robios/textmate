#import "AgentBridgeServer.h"
#import "AgentBridgeWorkspace.h"
#import <document/OakDocument.h>
#import <ns/ns.h>
#import <nlohmann/json.hpp>
#import <Network/Network.h>

using json = nlohmann::json;

static char const* const kAuthorizationHeaderField = "x-claude-code-ide-authorization";

// The protocol needs one or two concurrent clients; the cap only exists so a
// misbehaving local process cannot exhaust our file descriptors.
static NSUInteger const kMaxConnections            = 8;
static NSTimeInterval const kHandshakeTimeout      = 10;
static size_t const kMaximumIncomingMessageSize    = 16 << 20; // 16 MiB

// Serialize without throwing: tool results may contain buffer excerpts whose
// range boundaries split a multi-byte character, and dump()’s default strict
// handler throws type_error.316 on invalid UTF-8.
static std::string DumpJSON (json const& payload)
{
	return payload.dump(-1, ' ', false, json::error_handler_t::replace);
}

static std::string StringArg (json const& args, char const* key, std::string const& fallback = "")
{
	auto it = args.find(key);
	return it != args.end() && it->is_string() ? it->get<std::string>() : fallback;
}

static bool BoolArg (json const& args, char const* key, bool fallback)
{
	auto it = args.find(key);
	return it != args.end() && it->is_boolean() ? it->get<bool>() : fallback;
}

static std::string FileURIForPath (NSString* path)
{
	// Percent-encoded like every other IDE client; isDirectory:NO both avoids
	// a stat() and matches the convention of no trailing slash on folder URIs.
	return to_s([NSURL fileURLWithPath:path isDirectory:NO].absoluteString);
}

static json ContentResult (std::string const& text, bool isError)
{
	json res = { { "content", json::array({ { { "type", "text" }, { "text", text } } }) } };
	if(isError)
		res["isError"] = true;
	return res;
}

static json ToolDescriptors ()
{
	auto schema = [](json const& properties, json const& required = json::array()) -> json {
		return { { "type", "object" }, { "properties", properties }, { "required", required } };
	};

	return json::array({
		{
			{ "name", "openFile" },
			{ "description", "Open a file in the editor and optionally select a range of text" },
			{ "inputSchema", schema({
				{ "filePath",          { { "type", "string"  }, { "description", "Path to the file to open" } } },
				{ "preview",           { { "type", "boolean" }, { "description", "Whether to open the file in preview mode" } } },
				{ "startText",         { { "type", "string"  }, { "description", "Text pattern to find the start of the selection" } } },
				{ "endText",           { { "type", "string"  }, { "description", "Text pattern to find the end of the selection" } } },
				{ "selectToEndOfLine", { { "type", "boolean" }, { "description", "Extend selection to end of line" } } },
				{ "makeFrontmost",     { { "type", "boolean" }, { "description", "Whether to make the file the active editor tab" } } },
			}, json::array({ "filePath" })) },
		},
		{
			{ "name", "openDiff" },
			{ "description", "Open a diff view comparing proposed changes against the current file contents; blocks until the user accepts or rejects" },
			{ "inputSchema", schema({
				{ "old_file_path",     { { "type", "string" }, { "description", "Path to the file being modified" } } },
				{ "new_file_path",     { { "type", "string" }, { "description", "Path of the file after the change" } } },
				{ "new_file_contents", { { "type", "string" }, { "description", "Proposed contents of the file" } } },
				{ "tab_name",          { { "type", "string" }, { "description", "Name for the diff tab" } } },
			}, json::array({ "old_file_path", "new_file_path", "new_file_contents", "tab_name" })) },
		},
		{
			{ "name", "getCurrentSelection" },
			{ "description", "Get the current text selection in the active editor" },
			{ "inputSchema", schema(json::object()) },
		},
		{
			{ "name", "getLatestSelection" },
			{ "description", "Get the most recent non-empty text selection" },
			{ "inputSchema", schema(json::object()) },
		},
		{
			{ "name", "getOpenEditors" },
			{ "description", "Get the list of currently open documents" },
			{ "inputSchema", schema(json::object()) },
		},
		{
			{ "name", "getWorkspaceFolders" },
			{ "description", "Get the workspace (project) folders currently open in the IDE" },
			{ "inputSchema", schema(json::object()) },
		},
		{
			{ "name", "getDiagnostics" },
			{ "description", "Get language diagnostics (errors, warnings) from the editor" },
			{ "inputSchema", schema({
				{ "uri", { { "type", "string" }, { "description", "Optional file URI to get diagnostics for; omit for all files" } } },
			}) },
		},
		{
			{ "name", "checkDocumentDirty" },
			{ "description", "Check if a document has unsaved changes" },
			{ "inputSchema", schema({
				{ "filePath", { { "type", "string" }, { "description", "Path to the document to check" } } },
			}, json::array({ "filePath" })) },
		},
		{
			{ "name", "saveDocument" },
			{ "description", "Save a document with unsaved changes" },
			{ "inputSchema", schema({
				{ "filePath", { { "type", "string" }, { "description", "Path to the document to save" } } },
			}, json::array({ "filePath" })) },
		},
		{
			{ "name", "close_tab" },
			{ "description", "Close a tab by name" },
			{ "inputSchema", schema({
				{ "tab_name", { { "type", "string" }, { "description", "Name of the tab to close" } } },
			}, json::array({ "tab_name" })) },
		},
		{
			{ "name", "closeAllDiffTabs" },
			{ "description", "Close all diff tabs in the editor" },
			{ "inputSchema", schema(json::object()) },
		},
		{
			{ "name", "executeCode" },
			{ "description", "Execute code in a Jupyter kernel (not supported by TextMate)" },
			{ "inputSchema", schema({
				{ "code", { { "type", "string" }, { "description", "Code to execute" } } },
			}, json::array({ "code" })) },
		},
	});
}

@implementation AgentBridgeServer
{
	NSString*             _authToken;
	AgentBridgeWorkspace* _workspace;

	dispatch_queue_t      _queue;
	nw_listener_t         _listener;

	// All accessed only on _queue. Handshakes are strictly serialized: at most
	// one connection is started-but-not-ready at any time, so the WS client
	// request handler (same serial queue) always belongs to
	// _handshakingConnection and cancel-on-reject cannot hit a bystander.
	NSMutableArray*       _connections;            // authorized and ready
	NSMutableArray*       _pendingConnections;     // accepted, waiting for their turn to handshake
	nw_connection_t       _handshakingConnection;

	BOOL                  _didCallReadyHandler;
}

- (instancetype)initWithAuthToken:(NSString*)authToken workspace:(AgentBridgeWorkspace*)workspace
{
	if(self = [super init])
	{
		_authToken          = [authToken copy];
		_workspace          = workspace;
		_queue              = dispatch_queue_create("com.macromates.TextMate.agent-bridge", DISPATCH_QUEUE_SERIAL);
		_connections        = [NSMutableArray array];
		_pendingConnections = [NSMutableArray array];
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

	__weak AgentBridgeServer* weakSelf = self;
	nw_ws_options_set_client_request_handler(wsOptions, _queue, ^nw_ws_response_t(nw_ws_request_t request){
		AgentBridgeServer* strongSelf = weakSelf;
		return strongSelf ? [strongSelf responseForClientRequest:request] : nw_ws_response_create(nw_ws_response_status_reject, NULL);
	});

	nw_protocol_stack_t protocolStack = nw_parameters_copy_default_protocol_stack(parameters);
	nw_protocol_stack_prepend_application_protocol(protocolStack, wsOptions);

	nw_listener_t listener = nw_listener_create(parameters);
	nw_listener_set_queue(listener, _queue);

	__weak nw_listener_t weakListener = listener;
	nw_listener_set_state_changed_handler(listener, ^(nw_listener_state_t state, nw_error_t error){
		AgentBridgeServer* strongSelf = weakSelf;
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
		if(AgentBridgeServer* strongSelf = weakSelf)
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
	});
	_running = NO;
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
		return nw_ws_response_create(nw_ws_response_status_accept, NULL);

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

	__weak AgentBridgeServer* weakSelf = self;
	nw_connection_set_state_changed_handler(connection, ^(nw_connection_state_t state, nw_error_t error){
		AgentBridgeServer* strongSelf = weakSelf;
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
			}
			[strongSelf startNextHandshakeIfIdle];
		}
		else if(state == nw_connection_state_failed || state == nw_connection_state_cancelled)
		{
			if(strongSelf->_handshakingConnection == connection)
				strongSelf->_handshakingConnection = nil;
			[strongSelf->_connections removeObject:connection];
			[strongSelf->_pendingConnections removeObject:connection];
			[strongSelf startNextHandshakeIfIdle];
		}
	});
	nw_connection_start(connection);

	// A connection that never completes the upgrade must not hold its file
	// descriptor (or the serialized handshake slot) forever.
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kHandshakeTimeout * NSEC_PER_SEC)), _queue, ^{
		AgentBridgeServer* strongSelf = weakSelf;
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
	__weak AgentBridgeServer* weakSelf = self;
	nw_connection_receive_message(connection, ^(dispatch_data_t content, nw_content_context_t context, bool isComplete, nw_error_t error){
		AgentBridgeServer* strongSelf = weakSelf;
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
	std::string serialized = DumpJSON(payload);
	dispatch_data_t data = dispatch_data_create(serialized.data(), serialized.size(), _queue, DISPATCH_DATA_DESTRUCTOR_DEFAULT);

	nw_protocol_metadata_t metadata = nw_ws_create_metadata(nw_ws_opcode_text);
	nw_content_context_t context = nw_content_context_create("send");
	nw_content_context_set_metadata_for_protocol(context, metadata);
	nw_connection_send(connection, data, context, true, ^(nw_error_t error){
		if(error)
			NSLog(@"[AgentBridge] send failed: error %d", nw_error_get_error_code(error));
	});
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
	std::string const method = StringArg(message, "method");
	json const params = message.contains("params") && message["params"].is_object() ? message["params"] : json::object();

	if(method == "initialize")
	{
		std::string protocolVersion = "2024-11-05";
		if(params.contains("protocolVersion") && params["protocolVersion"].is_string())
			protocolVersion = params["protocolVersion"].get<std::string>();

		NSString* appVersion = [NSBundle.mainBundle.infoDictionary objectForKey:@"CFBundleShortVersionString"] ?: @"dev";
		json result = {
			{ "protocolVersion", protocolVersion },
			{ "capabilities", {
				{ "logging", json::object() },
				{ "prompts", { { "listChanged", true } } },
				{ "tools",   { { "listChanged", true } } },
			} },
			{ "serverInfo", { { "name", "TextMate" }, { "version", to_s(appVersion) } } },
		};
		[self sendResult:result forRequestId:requestId toConnection:connection];
	}
	else if(method.compare(0, 14, "notifications/") == 0)
	{
		// notifications/initialized, notifications/cancelled, … — nothing to do
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
		json result = { { "tools", ToolDescriptors() } };
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

// =========
// = Tools =
// =========

// params/requestId are taken BY VALUE on purpose: the asynchronous tool
// completion handlers capture them from blocks, and a block capturing a C++
// reference keeps the reference — which would dangle once the caller’s
// stack frame is gone.
- (void)handleToolCallWithParams:(json)params requestId:(json)requestId onConnection:(nw_connection_t)connection // main queue
{
	std::string const name = StringArg(params, "name");
	json const args = params.contains("arguments") && params["arguments"].is_object() ? params["arguments"] : json::object();

	__weak AgentBridgeServer* weakSelf = self;
	void (^replyText)(std::string const&, bool) = ^(std::string const& text, bool isError){
		[weakSelf sendResult:ContentResult(text, isError) forRequestId:requestId toConnection:connection];
	};
	void (^replyJSON)(json const&, bool) = ^(json const& payload, bool isError){
		replyText(payload.dump(), isError);
	};

	if(name == "getWorkspaceFolders")
	{
		NSArray<NSString*>* folders = [_workspace workspaceFolders];
		json folderList = json::array();
		for(NSString* folder in folders)
			folderList.push_back({ { "name", to_s(folder.lastPathComponent) }, { "uri", FileURIForPath(folder) }, { "path", to_s(folder) } });

		NSString* rootPath = [_workspace activeProjectPath] ?: folders.firstObject;
		json result = { { "success", true }, { "folders", folderList } };
		result["rootPath"] = rootPath ? json(to_s(rootPath)) : json(nullptr);
		replyJSON(result, false);
	}
	else if(name == "getOpenEditors")
	{
		json tabs = json::array();
		for(NSDictionary* editor in [_workspace openEditors])
		{
			tabs.push_back({
				{ "uri",        FileURIForPath((NSString*)editor[@"path"]) },
				{ "isActive",   [editor[@"isActive"] boolValue] ? true : false },
				{ "label",      to_s((NSString*)editor[@"label"]) },
				{ "languageId", to_s((NSString*)editor[@"languageId"]) },
				{ "isDirty",    [editor[@"isDirty"] boolValue] ? true : false },
			});
		}
		replyJSON({ { "tabs", tabs } }, false);
	}
	else if(name == "getCurrentSelection" || name == "getLatestSelection")
	{
		AgentBridgeSelection* selection;
		if(name == "getCurrentSelection")
		{
			selection = [_workspace currentSelection];
			if(!selection)
				return replyJSON({ { "success", false }, { "message", "No active editor found" } }, false);
		}
		else
		{
			selection = _workspace.latestSelection;
			if(!selection) // no selection change observed yet — a current non-empty selection is an acceptable seed
			{
				AgentBridgeSelection* current = [_workspace currentSelection];
				if(current && !current.isEmpty)
					selection = current;
			}
			if(!selection)
				return replyJSON({ { "success", false }, { "message", "No selection history available" } }, false);
		}

		json result = {
			{ "success", true },
			{ "text", to_s(selection.text ?: @"") },
			{ "filePath", selection.filePath ? json(to_s(selection.filePath)) : json(nullptr) },
			{ "selection", {
				{ "start", { { "line", selection.startLine }, { "character", selection.startCharacter } } },
				{ "end",   { { "line", selection.endLine   }, { "character", selection.endCharacter   } } },
				{ "isEmpty", selection.isEmpty ? true : false },
			} },
		};
		replyJSON(result, false);
	}
	else if(name == "openFile")
	{
		NSString* filePath = to_ns(StringArg(args, "filePath"));
		if(!filePath.length)
			return replyJSON({ { "success", false }, { "message", "filePath is required" } }, true);

		std::string const startTextArg = StringArg(args, "startText");
		std::string const endTextArg   = StringArg(args, "endText");
		NSString* startText = startTextArg.empty() ? nil : to_ns(startTextArg);
		NSString* endText   = endTextArg.empty()   ? nil : to_ns(endTextArg);
		BOOL selectToEndOfLine = BoolArg(args, "selectToEndOfLine", false);
		BOOL makeFrontmost     = BoolArg(args, "makeFrontmost", true);

		[_workspace openFileAtPath:filePath selectFromText:startText toText:endText selectToEndOfLine:selectToEndOfLine makeFrontmost:makeFrontmost completionHandler:^(OakDocument* document, NSUInteger lineCount){
			if(!document)
				return replyJSON({ { "success", false }, { "message", "File not found: " + to_s(filePath) } }, true);

			if(makeFrontmost)
				replyText("Opened file: " + to_s(document.path), false);
			else
				replyJSON({ { "success", true }, { "filePath", to_s(document.path) }, { "languageId", to_s(document.fileType ?: @"plaintext") }, { "lineCount", lineCount } }, false);
		}];
	}
	else if(name == "checkDocumentDirty")
	{
		NSString* filePath = to_ns(StringArg(args, "filePath"));
		OakDocument* document = [_workspace openDocumentAtPath:filePath];
		if(!document)
			return replyJSON({ { "success", false }, { "message", "Document not open: " + to_s(filePath) } }, false);

		replyJSON({ { "success", true }, { "filePath", to_s(document.path) }, { "isDirty", document.isDocumentEdited ? true : false }, { "isUntitled", false } }, false);
	}
	else if(name == "saveDocument")
	{
		NSString* filePath = to_ns(StringArg(args, "filePath"));
		OakDocument* document = [_workspace openDocumentAtPath:filePath];
		if(!document)
			return replyJSON({ { "success", false }, { "message", "Document not open: " + to_s(filePath) } }, false);

		[_workspace saveDocument:document completionHandler:^(BOOL saved, NSString* message){
			replyJSON({ { "success", true }, { "filePath", to_s(document.path) }, { "saved", saved ? true : false }, { "message", to_s(message ?: (saved ? @"Document saved" : @"Save failed")) } }, false);
		}];
	}
	else if(name == "getDiagnostics")
	{
		std::string const uriFilter = StringArg(args, "uri");
		static char const* const severityNames[] = { "Error", "Error", "Warning", "Information", "Hint" };

		// The cache keys are URIs as the LSP server sent them (percent-encoded);
		// the client’s filter may round-trip our own URIs or be a plain path.
		// Compare decoded filesystem paths so encodings can’t prevent a match.
		NSString* filterPath = nil;
		if(!uriFilter.empty())
		{
			NSURL* filterURL = [NSURL URLWithString:to_ns(uriFilter)];
			filterPath = filterURL.isFileURL ? filterURL.path : to_ns(uriFilter);
		}

		json result = json::array();
		NSDictionary<NSString*, NSArray<NSDictionary*>*>* diagnosticsByURI = [_workspace diagnosticsByURI];
		for(NSString* uri in diagnosticsByURI)
		{
			if(filterPath)
			{
				NSURL* url = [NSURL URLWithString:uri];
				NSString* path = url.isFileURL ? url.path : uri;
				if(![path isEqualToString:filterPath])
					continue;
			}

			json diagnostics = json::array();
			for(NSDictionary* entry in diagnosticsByURI[uri])
			{
				NSInteger severity = [entry[@"severity"] integerValue];
				json diagnostic = {
					{ "message",  to_s((NSString*)entry[@"message"]) },
					{ "severity", severityNames[severity >= 1 && severity <= 4 ? severity : 1] },
					{ "range", {
						{ "start", { { "line", [entry[@"line"] integerValue]    }, { "character", [entry[@"character"] integerValue]    } } },
						{ "end",   { { "line", [entry[@"endLine"] integerValue] }, { "character", [entry[@"endCharacter"] integerValue] } } },
					} },
				};
				if(NSString* source = entry[@"source"])
					diagnostic["source"] = to_s(source);
				if(id code = entry[@"code"])
					diagnostic["code"] = to_s([code description]);
				diagnostics.push_back(diagnostic);
			}
			result.push_back({ { "uri", to_s(uri) }, { "diagnostics", diagnostics } });
		}
		replyJSON(result, false);
	}
	else if(name == "openDiff")
	{
		// WP2 wires this to ProposalSession; advertised in tools/list so the
		// CLI knows the IDE intends to support it, but not yet callable.
		[self sendErrorWithCode:-32000 message:"openDiff is not yet available in TextMate" forRequestId:requestId toConnection:connection];
	}
	else if(name == "close_tab")
	{
		replyText("TAB_CLOSED", false); // no diff tabs exist until WP2, so nothing to close
	}
	else if(name == "closeAllDiffTabs")
	{
		replyText("CLOSED_0_DIFF_TABS", false); // no diff tabs exist until WP2
	}
	else if(name == "executeCode")
	{
		replyText("executeCode is not supported: TextMate has no Jupyter kernel integration", true);
	}
	else
	{
		[self sendErrorWithCode:-32601 message:"Unknown tool: " + name forRequestId:requestId toConnection:connection];
	}
}

// ============================
// = Notifications (IDE→CLI) =
// ============================

- (void)sendSelectionChanged:(AgentBridgeSelection*)selection
{
	json params = {
		{ "text", to_s(selection.text ?: @"") },
		{ "filePath", selection.filePath ? json(to_s(selection.filePath)) : json(nullptr) },
		{ "fileUrl",  selection.filePath ? json(FileURIForPath(selection.filePath)) : json(nullptr) },
		{ "selection", {
			{ "start", { { "line", selection.startLine }, { "character", selection.startCharacter } } },
			{ "end",   { { "line", selection.endLine   }, { "character", selection.endCharacter   } } },
			{ "isEmpty", selection.isEmpty ? true : false },
		} },
	};
	[self broadcastNotification:"selection_changed" params:params];
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
