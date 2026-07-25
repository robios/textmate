#import "CodexIDEContextServer.h"
#import "AgentBridgeWorkspace.h"
#import "agent_json.h"
#import "codex_ide_protocol.h"
#import <io/path.h>
#import <ns/ns.h>
#import <nlohmann/json.hpp>
#import <sys/socket.h>
#import <sys/stat.h>
#import <sys/un.h>
#import <unistd.h>
#import <algorithm>
#import <atomic>
#import <cerrno>
#import <vector>

using json = nlohmann::json;

static constexpr uint32_t kMaximumFrameSize = 16 * 1024 * 1024;
static constexpr NSUInteger kInitialRouterRetrySlices = 10;  // 1 second
static constexpr NSUInteger kMaximumRouterRetrySlices = 300; // 30 seconds

static BOOL WaitForRouterRetry (std::atomic<uint64_t> const& currentGeneration, uint64_t generation, NSUInteger slices)
{
	for(NSUInteger retrySlice = 0; retrySlice != slices && currentGeneration.load() == generation; ++retrySlice)
		usleep(100 * 1000);
	return currentGeneration.load() == generation;
}

static BOOL ReadExactly (int fd, void* bytes, size_t length)
{
	uint8_t* cursor = static_cast<uint8_t*>(bytes);
	while(length)
	{
		ssize_t const count = recv(fd, cursor, length, 0);
		if(count < 0 && errno == EINTR)
			continue;
		if(count <= 0)
			return NO;
		cursor += count;
		length -= count;
	}
	return YES;
}

static BOOL WriteExactly (int fd, void const* bytes, size_t length)
{
	uint8_t const* cursor = static_cast<uint8_t const*>(bytes);
	while(length)
	{
		ssize_t const count = send(fd, cursor, length, 0);
		if(count < 0 && errno == EINTR)
			continue;
		if(count <= 0)
			return NO;
		cursor += count;
		length -= count;
	}
	return YES;
}

static NSString* DisplayPath (NSString* filePath, NSString* projectPath)
{
	if(!filePath.length || !projectPath.length)
		return filePath;

	std::string const file = path::normalize(to_s(filePath));
	std::string const root = path::normalize(to_s(projectPath));
	if(path::is_child(file, root))
		return to_ns(file.substr(root.size() + (root.back() == '/' ? 0 : 1)));
	return filePath;
}

@implementation CodexIDEContextServer
{
	AgentBridgeWorkspace* _workspace;
	dispatch_queue_t _acceptQueue;
	dispatch_queue_t _routerQueue;
	std::atomic<int> _listener;
	std::atomic<int> _routerConnection;
	std::atomic<uint64_t> _routerGeneration;
	std::string _clientIdentifier;
	NSString* _temporaryDirectory;
	NSString* _socketDirectory;
	NSString* _socketPath;
}

- (instancetype)initWithWorkspace:(AgentBridgeWorkspace*)workspace
{
	if(self = [super init])
	{
		_workspace = workspace;
		_acceptQueue = dispatch_queue_create("com.macromates.TextMate.codex-ide-context", DISPATCH_QUEUE_SERIAL);
		_routerQueue = dispatch_queue_create("com.macromates.TextMate.codex-ide-router", DISPATCH_QUEUE_SERIAL);
		_listener.store(-1);
		_routerConnection.store(-1);
		_routerGeneration.store(0);
		_clientIdentifier = "textmate-" + std::to_string(getpid());
	}
	return self;
}

- (BOOL)isRunning
{
	return _listener.load() != -1;
}

- (NSString*)temporaryDirectory
{
	return self.isRunning ? _temporaryDirectory : nil;
}

- (BOOL)start // main queue
{
	if(self.isRunning)
		return YES;

	std::string const templateString = to_s([NSTemporaryDirectory() stringByAppendingPathComponent:@"tm-codex-XXXXXX"]);
	std::vector<char> templatePath(templateString.begin(), templateString.end());
	templatePath.push_back('\0');
	char* directory = mkdtemp(templatePath.data());
	if(!directory)
		return NO;

	_temporaryDirectory = [NSString stringWithUTF8String:directory];
	_socketDirectory = [_temporaryDirectory stringByAppendingPathComponent:@"codex-ipc"];
	_socketPath = [_socketDirectory stringByAppendingPathComponent:[NSString stringWithFormat:@"ipc-%u.sock", getuid()]];

	if(mkdir(_socketDirectory.fileSystemRepresentation, 0700) != 0)
	{
		rmdir(_temporaryDirectory.fileSystemRepresentation);
		_temporaryDirectory = nil;
		_socketDirectory = nil;
		_socketPath = nil;
		return NO;
	}

	int const listener = socket(AF_UNIX, SOCK_STREAM, 0);
	if(listener == -1)
	{
		[self removeSocketDirectories];
		return NO;
	}

	sockaddr_un address = {};
	address.sun_family = AF_UNIX;
	char const* socketPath = _socketPath.fileSystemRepresentation;
	if(strlen(socketPath) >= sizeof(address.sun_path))
	{
		close(listener);
		[self removeSocketDirectories];
		return NO;
	}
	strlcpy(address.sun_path, socketPath, sizeof(address.sun_path));

	socklen_t const addressLength = static_cast<socklen_t>(offsetof(sockaddr_un, sun_path) + strlen(address.sun_path) + 1);
	if(bind(listener, reinterpret_cast<sockaddr*>(&address), addressLength) != 0 || listen(listener, 4) != 0)
	{
		close(listener);
		[self removeSocketDirectories];
		return NO;
	}
	chmod(socketPath, 0600);

	_listener.store(listener);
	__weak CodexIDEContextServer* weakSelf = self;
	dispatch_async(_acceptQueue, ^{
		if(CodexIDEContextServer* strongSelf = weakSelf)
			[strongSelf acceptConnectionsOnFileDescriptor:listener];
		else
			close(listener);
	});

	uint64_t const routerGeneration = _routerGeneration.fetch_add(1) + 1;
	dispatch_async(_routerQueue, ^{
		if(CodexIDEContextServer* strongSelf = weakSelf)
			[strongSelf runRouterClientForGeneration:routerGeneration];
	});
	return YES;
}

- (void)stop // main queue
{
	int const listener = _listener.exchange(-1);
	if(listener != -1)
		shutdown(listener, SHUT_RDWR);
	_routerGeneration.fetch_add(1);
	int const routerConnection = _routerConnection.exchange(-1);
	if(routerConnection != -1)
		shutdown(routerConnection, SHUT_RDWR);
	[self removeSocketDirectories];
}

- (void)dealloc
{
	[self stop];
}

- (void)removeSocketDirectories
{
	if(_socketPath)
		unlink(_socketPath.fileSystemRepresentation);
	// Never recurse here: Codex inherits this directory as TMPDIR and may
	// outlive a disabled bridge or the TextMate instance. If it contains
	// child-created files, leave it for the system's temporary-file cleanup.
	if(_socketDirectory)
		rmdir(_socketDirectory.fileSystemRepresentation);
	if(_temporaryDirectory)
		rmdir(_temporaryDirectory.fileSystemRepresentation);
	_socketPath = nil;
	_socketDirectory = nil;
	_temporaryDirectory = nil;
}

- (void)acceptConnectionsOnFileDescriptor:(int)listener
{
	while(_listener.load() == listener)
	{
		int const connection = accept(listener, nullptr, nullptr);
		if(connection == -1)
			break;

		timeval timeout = { 5, 0 };
		setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
		setsockopt(connection, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
		int noSigPipe = 1;
		setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, sizeof(noSigPipe));
		[self handleConnection:connection];
		close(connection);
	}
	close(listener);

	int expected = listener;
	if(_listener.compare_exchange_strong(expected, -1))
	{
		dispatch_async(dispatch_get_main_queue(), ^{
			if(!self.isRunning)
				[self removeSocketDirectories];
		});
	}
}

- (void)handleConnection:(int)connection
{
	uint8_t header[4];
	if(!ReadExactly(connection, header, sizeof(header)))
		return;

	uint32_t const length = static_cast<uint32_t>(header[0]) |
		(static_cast<uint32_t>(header[1]) << 8) |
		(static_cast<uint32_t>(header[2]) << 16) |
		(static_cast<uint32_t>(header[3]) << 24);
	if(length == 0 || length > kMaximumFrameSize)
		return;

	std::string payload(length, '\0');
	if(!ReadExactly(connection, payload.data(), payload.size()))
		return;

	json const request = json::parse(payload.begin(), payload.end(), nullptr, false);
	if(request.is_discarded())
		return;

	json response = [self responseForRequest:request];
	if(response.is_null())
		return;
	[self writeFrame:response toFileDescriptor:connection];
}

- (json)responseForRequest:(json const&)request
{
	// Router requests arrive only after our positive discovery response. The
	// direct listener has no discovery phase, but its private TMPDIR scopes it
	// to a Codex launched by this TextMate instance; active-window fallback is
	// therefore intentional when that request omits a usable workspace root.
	NSString* workspaceRoot = nil;
	if(request.contains("params") && request["params"].is_object())
	{
		std::string const root = request["params"].value("workspaceRoot", "");
		if(!root.empty())
			workspaceRoot = to_ns(root);
	}

	__block json context = json::object();
	dispatch_sync(dispatch_get_main_queue(), ^{
		context = [self ideContextForRoutingPath:workspaceRoot];
	});

	json response;
	if(!codex_ide_protocol::response_for(request, context, _clientIdentifier, &response))
		return nullptr;
	return response;
}

- (BOOL)writeFrame:(json const&)response toFileDescriptor:(int)connection
{
	std::string const serialized = response.dump();
	if(serialized.size() > kMaximumFrameSize)
		return NO;
	uint32_t const responseLength = static_cast<uint32_t>(serialized.size());
	uint8_t const responseHeader[4] = {
		static_cast<uint8_t>(responseLength),
		static_cast<uint8_t>(responseLength >> 8),
		static_cast<uint8_t>(responseLength >> 16),
		static_cast<uint8_t>(responseLength >> 24),
	};
	return WriteExactly(connection, responseHeader, sizeof(responseHeader)) &&
		WriteExactly(connection, serialized.data(), serialized.size());
}

- (json)readFrameFromFileDescriptor:(int)connection
{
	uint8_t header[4];
	if(!ReadExactly(connection, header, sizeof(header)))
		return nullptr;

	uint32_t const length = static_cast<uint32_t>(header[0]) |
		(static_cast<uint32_t>(header[1]) << 8) |
		(static_cast<uint32_t>(header[2]) << 16) |
		(static_cast<uint32_t>(header[3]) << 24);
	if(length == 0 || length > kMaximumFrameSize)
		return nullptr;

	std::string payload(length, '\0');
	if(!ReadExactly(connection, payload.data(), payload.size()))
		return nullptr;
	json message = json::parse(payload.begin(), payload.end(), nullptr, false);
	return message.is_discarded() ? json(nullptr) : message;
}

- (NSString*)codexRouterSocketPath
{
	char const* configuredHome = getenv("CODEX_HOME");
	NSString* codexHome = configuredHome && *configuredHome ? [NSString stringWithUTF8String:configuredHome] : [NSHomeDirectory() stringByAppendingPathComponent:@".codex"];
	return [[codexHome stringByAppendingPathComponent:@"ipc"] stringByAppendingPathComponent:@"ipc.sock"];
}

- (void)runRouterClientForGeneration:(uint64_t)generation
{
	NSUInteger retrySlices = kInitialRouterRetrySlices;
	while(_routerGeneration.load() == generation)
	{
		int connection = socket(AF_UNIX, SOCK_STREAM, 0);
		if(connection == -1)
			return;

		sockaddr_un address = {};
		address.sun_family = AF_UNIX;
		char const* socketPath = self.codexRouterSocketPath.fileSystemRepresentation;
		if(strlen(socketPath) >= sizeof(address.sun_path))
		{
			close(connection);
			return;
		}
		strlcpy(address.sun_path, socketPath, sizeof(address.sun_path));
		socklen_t const addressLength = static_cast<socklen_t>(offsetof(sockaddr_un, sun_path) + strlen(address.sun_path) + 1);
		if(connect(connection, reinterpret_cast<sockaddr*>(&address), addressLength) != 0)
		{
			close(connection);
			if(!WaitForRouterRetry(_routerGeneration, generation, retrySlices))
				break;
			retrySlices = std::min(retrySlices * 2, kMaximumRouterRetrySlices);
			continue;
		}

		retrySlices = kInitialRouterRetrySlices;
		int noSigPipe = 1;
		setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, sizeof(noSigPipe));
		_routerConnection.store(connection);

		json const initialize = {
			{ "type", "request" },
			{ "requestId", to_s(NSUUID.UUID.UUIDString) },
			{ "sourceClientId", _clientIdentifier },
			{ "version", 0 },
			{ "method", "initialize" },
			{ "params", { { "clientType", "textmate" } } },
		};
		if(![self writeFrame:initialize toFileDescriptor:connection])
		{
			int expected = connection;
			_routerConnection.compare_exchange_strong(expected, -1);
			close(connection);
			if(!WaitForRouterRetry(_routerGeneration, generation, retrySlices))
				break;
			retrySlices = std::min(retrySlices * 2, kMaximumRouterRetrySlices);
			continue;
		}

		while(_routerGeneration.load() == generation)
		{
			json const message = [self readFrameFromFileDescriptor:connection];
			if(message.is_null())
				break;

			json response;
			std::string const type = message.value("type", "");
			if(type == "client-discovery-request")
			{
				NSString* workspaceRoot = nil;
				json const request = message.value("request", json::object());
				if(request.contains("params") && request["params"].is_object())
				{
					std::string const root = request["params"].value("workspaceRoot", "");
					if(!root.empty())
						workspaceRoot = to_ns(root);
				}

				__block BOOL providerAvailable = NO;
				dispatch_sync(dispatch_get_main_queue(), ^{
					providerAvailable = [self->_workspace canRouteIDEContextForWorkspaceRoot:workspaceRoot];
				});
				if(codex_ide_protocol::discovery_response_for(message, providerAvailable, &response))
					[self writeFrame:response toFileDescriptor:connection];
			}
			else if(type == "request")
			{
				response = [self responseForRequest:message];
				if(!response.is_null())
					[self writeFrame:response toFileDescriptor:connection];
			}
		}

		int expected = connection;
		_routerConnection.compare_exchange_strong(expected, -1);
		close(connection);

		// Avoid a tight reconnect loop if a present but unhealthy router accepts
		// the socket and then immediately drops it.
		if(!WaitForRouterRetry(_routerGeneration, generation, retrySlices))
			break;
	}
}

- (json)ideContextForRoutingPath:(NSString*)routingPath // main queue
{
	NSString* projectPath = [_workspace projectPathForRoutingPath:routingPath];
	AgentBridgeSelection* selection = [_workspace currentSelectionForRoutingPath:routingPath];

	json openTabs = json::array();
	for(NSDictionary* editor in [_workspace openEditorsInAnsweringWindowForRoutingPath:routingPath])
	{
		NSString* filePath = editor[@"path"];
		openTabs.push_back({
			{ "label", to_s(editor[@"label"] ?: filePath.lastPathComponent) },
			{ "path",  to_s(DisplayPath(filePath, projectPath)) },
			{ "fsPath", to_s(filePath) },
		});
	}

	json activeFile = nullptr;
	if(selection.filePath.length)
	{
		// Keep the native IDE-context response comfortably below its frame cap.
		// The observed Codex schema has no truncation-metadata field, so preserve
		// its wire shape and share the same UTF-8-safe 64 KiB cap as Claude/MCP.
		std::string const selectionText = agent_json::truncate_utf8(
			to_s(selection.text ?: @""), agent_json::maximum_selection_bytes);
		activeFile = {
			{ "label", selection.filePath.lastPathComponent.UTF8String },
			{ "path", to_s(DisplayPath(selection.filePath, projectPath)) },
			{ "fsPath", to_s(selection.filePath) },
			{ "selection", {
				{ "start", {
					{ "line", selection.startLine },
					{ "character", selection.startCharacter },
				} },
				{ "end", {
					{ "line", selection.endLine },
					{ "character", selection.endCharacter },
				} },
			} },
			{ "activeSelectionContent", selectionText },
			{ "selections", json::array() },
		};
	}

	return {
		{ "activeFile", activeFile },
		{ "openTabs", openTabs },
	};
}

@end
