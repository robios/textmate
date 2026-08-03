#import "LSPManager.h"
#import "LSPClient.h"
#import "LSPBundleSettings.h"
#import <document/OakDocumentController.h>
#import <settings/settings.h>
#import <io/path.h>
#import <ns/ns.h>
#import <OakFoundation/NSString Additions.h>

NSString* const LSPDiagnosticsDidChangeNotification = @"LSPDiagnosticsDidChange";
NSString* const LSPServerStatusDidChangeNotification = @"LSPServerStatusDidChange";

static NSDictionary<NSString*, NSString*>* scopeToLanguageId ()
{
	static NSDictionary* map = @{
		@"source.php"           : @"php",
		@"source.c"             : @"c",
		@"source.c++"          : @"cpp",
		@"source.objc"          : @"objective-c",
		@"source.objc++"       : @"objective-cpp",
		@"source.js"            : @"javascript",
		@"source.ts"            : @"typescript",
		@"source.python"        : @"python",
		@"source.go"            : @"go",
		@"source.rust"          : @"rust",
		@"source.ruby"          : @"ruby",
		@"source.java"          : @"java",
		@"source.json"          : @"json",
		@"source.css"           : @"css",
		@"source.html"          : @"html",
		@"source.shell"         : @"shellscript",
		@"source.yaml"          : @"yaml",
		@"source.swift"         : @"swift",
		@"text.html.markdown"   : @"markdown",
		@"text.tex"             : @"latex",
		@"text.bibtex"          : @"bibtex",
	};
	return map;
}

static NSString* languageIdForScope (NSString* fileType)
{
	if(!fileType)
		return @"plaintext";

	NSDictionary* map = scopeToLanguageId();

	// Try progressively shorter scope prefixes for best match
	NSString* scope = fileType;
	while(scope.length > 0)
	{
		NSString* langId = map[scope];
		if(langId)
			return langId;

		NSRange lastDot = [scope rangeOfString:@"." options:NSBackwardsSearch];
		if(lastDot.location == NSNotFound)
			break;
		scope = [scope substringToIndex:lastDot.location];
	}

	// Fallback: strip "source." prefix and use remainder
	if([fileType hasPrefix:@"source."])
		return [fileType substringFromIndex:7];

	return @"plaintext";
}

// Uses shared LSPLanguageIdForExtension() from LSPClient.mm

// Defined below, next to serverStatusForDocument:.
static std::string configuredCommandForDocument (OakDocument* document);

// Would the same lspCommand apply to an arbitrary unrelated file in the same
// directory? If so it is unscoped; if not, something targeted it at this
// file specifically — a path glob like “[ *.zig ]” in .tm_properties or a
// scope-selector match. The probe file name matches no reasonable glob.
static bool commandIsScopedToDocument (OakDocument* document, std::string const& command)
{
	std::string directory = to_s(document.directory ?: [document.path stringByDeletingLastPathComponent]);
	std::string probePath = path::join(directory, ".tm-lsp-scope-probe");
	settings_t probeSettings = settings_for_path(probePath, "text.plain", directory);
	return lsp::setting_with_bundle_fallback(kSettingsLSPCommandKey, probeSettings, scope::scope_t("text.plain")) != command;
}

static std::vector<std::string> const& workspaceMarkers ()
{
	static std::vector<std::string> const markers = {
		".git", "composer.json", "package.json", "tsconfig.json",
		"CMakeLists.txt", "compile_commands.json", "go.mod",
		"Cargo.toml", "pyproject.toml", "setup.py", ".clangd"
	};
	return markers;
}

static std::string detectWorkspaceRoot (std::string const& filePath)
{
	std::string dir = path::parent(filePath);
	std::string previousDir;

	while(dir != previousDir && dir != "/")
	{
		for(auto const& marker : workspaceMarkers())
		{
			if(path::exists(path::join(dir, marker)))
				return dir;
		}
		previousDir = dir;
		dir = path::parent(dir);
	}

	// No marker found — use file's directory
	return path::parent(filePath);
}

@interface LSPManager () <LSPClientDelegate>
{
	NSMutableDictionary<NSString*, LSPClient*>*              _clients;
	NSMutableDictionary<NSUUID*, LSPClient*>*                _documentClients;
	NSMutableDictionary<NSUUID*, NSNumber*>*                 _documentVersions;
	NSMutableSet<NSUUID*>*                                   _openDocuments;
	NSMutableDictionary<NSUUID*, NSTimer*>*                  _changeTimers;
	// Diagnostics are owned by the client that published them, not by the
	// document that happened to be open — a workspace server publishes for
	// files nobody opened, and only the publisher may retract them.
	LSPDiagnosticsStore*                                     _diagnosticsStore;
	// Workspace root per client identity, so the store can scope a snapshot to
	// a window without taking a composite key apart.
	NSMutableDictionary<NSString*, NSString*>*               _workspaceRootByClientId;
	// Keyed like _clients (root + lspCommand) so a re-index only flags the
	// server it was requested for, not every server sharing the workspace.
	NSMutableSet<NSString*>* _clearCacheKeys;

	// lspCommand values whose launch failed (binary not found or not
	// executable), grouped by workspace root — a relative command can exist
	// in one workspace and not another, so a failure must not leak across
	// them. Keys are the full command string, so editing the setting retries
	// naturally; Restart Server clears its workspace's entries explicitly.
	NSMutableDictionary<NSString*, NSMutableSet<NSString*>*>* _failedCommandsByRoot;
}
@end

@implementation LSPManager
+ (instancetype)sharedManager
{
	static LSPManager* instance;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		instance = [LSPManager new];
	});
	return instance;
}

- (instancetype)init
{
	if(self = [super init])
	{
		_clients            = [NSMutableDictionary new];
		_documentClients    = [NSMutableDictionary new];
		_documentVersions   = [NSMutableDictionary new];
		_openDocuments      = [NSMutableSet new];
		_changeTimers       = [NSMutableDictionary new];
		_diagnosticsStore   = [LSPDiagnosticsStore new];
		_workspaceRootByClientId = [NSMutableDictionary new];
		_clearCacheKeys     = [NSMutableSet new];
		_failedCommandsByRoot = [NSMutableDictionary new];

		[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(applicationWillTerminate:) name:NSApplicationWillTerminateNotification object:nil];
		[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(documentDidReloadNotification:) name:OakDocumentDidReloadNotification object:nil];
	}
	return self;
}

// Reloading swaps the buffer content, which wipes the squiggle ranges stored
// in it; the server only republishes when the content actually changed, so
// re-apply what we have cached.
- (void)documentDidReloadNotification:(NSNotification*)notification
{
	OakDocument* document = notification.object;
	if(!document.path || ![_openDocuments containsObject:document.identifier])
		return;

	NSString* uri = [NSURL fileURLWithPath:document.path].absoluteString;
	NSArray<NSDictionary*>* cached = [_diagnosticsStore diagnosticsForURI:uri];
	if(cached.count)
		[self applyDiagnostics:cached toDocument:document];
}

- (void)applicationWillTerminate:(NSNotification*)notification
{
	[self shutdownAll];
}

// _clients is keyed by workspace root + lspCommand: one server per language
// per workspace, so a C file and a Python file in the same root each get
// their own server.
static NSString* clientKey (NSString* root, std::string const& lspCommand)
{
	return [NSString stringWithFormat:@"%@\n%s", root, lspCommand.c_str()];
}

- (NSString*)keyForClient:(LSPClient*)client
{
	for(NSString* key in _clients)
	{
		if(_clients[key] == client)
			return key;
	}
	return nil;
}

- (LSPClient*)clientForDocument:(OakDocument*)document
{
	if(!document.path)
		return nil;

	std::string filePath  = to_s(document.path);
	std::string fileType  = to_s(document.fileType);
	std::string directory = to_s(document.directory ?: [document.path stringByDeletingLastPathComponent]);

	settings_t settings = settings_for_path(filePath, fileType, directory);
	scope::context_t const scopeContext = scope::scope_t(fileType);

	// Settings from .tm_properties take precedence; language bundles may
	// provide defaults via scoped Preferences items (see docs/lsp-bundle-config.md).
	std::string lspCommand = lsp::setting_with_bundle_fallback(kSettingsLSPCommandKey, settings, scopeContext);
	if(lspCommand.empty())
		return nil;

	bool lspEnabled = lsp::setting_with_bundle_fallback(kSettingsLSPEnabledKey, settings, scopeContext, true);
	if(!lspEnabled)
		return nil;

	// Determine workspace root
	std::string rootPath = lsp::setting_with_bundle_fallback(kSettingsLSPRootPathKey, settings, scopeContext);
	if(rootPath.empty())
		rootPath = detectWorkspaceRoot(filePath);

	// A running client for this workspace and command always wins — even if
	// the same command failed to launch elsewhere.
	NSString* root = to_ns(rootPath);
	NSString* key = clientKey(root, lspCommand);
	LSPClient* client = _clients[key];
	if(client)
		return client;

	// Don’t retry a launch that already failed in this workspace on every
	// document open — Restart Server (or editing lspCommand) clears it.
	if([_failedCommandsByRoot[root] containsObject:to_ns(lspCommand)])
		return nil;

	// Parse command: first whitespace-delimited token is executable, rest are args
	std::vector<std::string> parts = path::unescape(lspCommand);
	if(parts.empty())
		return nil;

	NSString* executable = to_ns(parts[0]);
	NSMutableArray<NSString*>* args = [NSMutableArray new];
	for(size_t i = 1; i < parts.size(); ++i)
		[args addObject:to_ns(parts[i])];

	std::string initOpts = lsp::setting_with_bundle_fallback(kSettingsLSPInitOptionsKey, settings, scopeContext);
	NSString* initOptsJSON = initOpts.empty() ? nil : to_ns(initOpts);

	if([_clearCacheKeys containsObject:key])
	{
		[_clearCacheKeys removeObject:key];
		// Merge clearCache:true into initializationOptions for servers like Intelephense
		if(initOptsJSON.length)
		{
			NSData* data = [initOptsJSON dataUsingEncoding:NSUTF8StringEncoding];
			NSMutableDictionary* opts = [[NSJSONSerialization JSONObjectWithData:data options:0 error:nil] mutableCopy];
			if(!opts)
				opts = [NSMutableDictionary new];
			opts[@"clearCache"] = @YES;
			NSData* merged = [NSJSONSerialization dataWithJSONObject:opts options:0 error:nil];
			initOptsJSON = [[NSString alloc] initWithData:merged encoding:NSUTF8StringEncoding];
		}
		else
		{
			initOptsJSON = @"{\"clearCache\":true}";
		}
	}

	client = [[LSPClient alloc] initWithCommand:executable arguments:args workingDirectory:root initOptions:initOptsJSON];
	if(!client)
	{
		NSMutableSet<NSString*>* failed = _failedCommandsByRoot[root];
		if(!failed)
			failed = _failedCommandsByRoot[root] = [NSMutableSet new];
		[failed addObject:to_ns(lspCommand)];
		[NSNotificationCenter.defaultCenter postNotificationName:LSPServerStatusDidChangeNotification object:self];
		return nil;
	}
	client.delegate = self;
	_clients[key] = client;
	_workspaceRootByClientId[client.identifier] = root;
	[NSNotificationCenter.defaultCenter postNotificationName:LSPServerStatusDidChangeNotification object:self];
	return client;
}

- (void)documentDidOpen:(OakDocument*)document
{
	NSUUID* docId = document.identifier;
	if([_openDocuments containsObject:docId])
		return;

	NSString* langId = languageIdForScope(document.fileType);
	if([langId isEqualToString:@"plaintext"] && document.path)
	{
		langId = LSPLanguageIdForExtension(document.path.pathExtension);

		// Unknown extension: still connect when the lspCommand was targeted
		// at this file (e.g. “[ *.zig ] lspCommand = zls” with no Zig
		// grammar installed), passing the raw extension as languageId. Only
		// an unscoped command — one an arbitrary file next door would
		// inherit — must not attach plain-text documents.
		if(!langId && document.path.pathExtension.length)
		{
			std::string command = configuredCommandForDocument(document);
			if(!command.empty() && commandIsScopedToDocument(document, command))
				langId = document.path.pathExtension.lowercaseString;
		}
		langId = langId ?: @"plaintext";
	}

	// Don't connect plaintext files — prevents unscoped lspCommand
	// from launching a server for every file type
	if([langId isEqualToString:@"plaintext"])
		return;

	LSPClient* client = [self clientForDocument:document];
	if(!client)
		return;

	[_openDocuments addObject:docId];
	_documentClients[docId]  = client;
	_documentVersions[docId] = @1;

	[client openDocument:document languageId:langId];

	// Servers like pyright analyze imports ahead of the user opening them, so
	// diagnostics for this file may already be cached — apply them now instead
	// of waiting out the server’s re-analysis after didOpen.
	if(document.path)
	{
		NSString* uri = [NSURL fileURLWithPath:document.path].absoluteString;
		NSArray<NSDictionary*>* cached = [_diagnosticsStore diagnosticsForURI:uri];
		if(cached.count)
			[self applyDiagnostics:cached toDocument:document];
	}
}

- (void)documentDidChange:(OakDocument*)document
{
	NSUUID* docId = document.identifier;
	if(![_openDocuments containsObject:docId])
		return;

	[_changeTimers[docId] invalidate];

	__weak LSPManager* weakSelf = self;
	_changeTimers[docId] = [NSTimer scheduledTimerWithTimeInterval:0.3 repeats:NO block:^(NSTimer* timer) {
		[weakSelf sendDidChangeForDocument:document];
	}];
}

- (void)sendDidChangeForDocument:(OakDocument*)document
{
	NSUUID* docId = document.identifier;
	[_changeTimers removeObjectForKey:docId];

	LSPClient* client = _documentClients[docId];
	if(!client)
		return;

	int version = [_documentVersions[docId] intValue] + 1;
	_documentVersions[docId] = @(version);
	[client documentDidChange:document version:version];
}

- (void)documentDidSave:(OakDocument*)document
{
	NSUUID* docId = document.identifier;
	if(![_openDocuments containsObject:docId])
	{
		// An untitled document has no path to attach with — its first save
		// is the first chance to connect it to a server.
		[self documentDidOpen:document];
		return;
	}

	// Flush any pending change notification
	if(_changeTimers[docId])
	{
		[_changeTimers[docId] invalidate];
		[self sendDidChangeForDocument:document];
	}

	LSPClient* client = _documentClients[docId];
	if(client)
		[client documentDidSave:document];
}

- (void)documentWillClose:(OakDocument*)document
{
	NSUUID* docId = document.identifier;
	if(![_openDocuments containsObject:docId])
		return;

	[_changeTimers[docId] invalidate];
	[_changeTimers removeObjectForKey:docId];

	LSPClient* client = _documentClients[docId];
	if(client)
		[client closeDocument:document];

	[_openDocuments removeObject:docId];
	[_documentClients removeObjectForKey:docId];
	[_documentVersions removeObjectForKey:docId];

	// The cached entry deliberately stays: the client is still live and still
	// responsible for this file, and the cross-file panel lists files nobody
	// has open. didClose tells the server we stopped watching, not that what
	// it said stopped being true.
}

// Bring the document back in line with what the store now holds for it —
// whatever survived a client going away, which is usually nothing but can be
// a second server’s diagnostics for the same file. Silent: the caller decides
// whether this is one document’s news or a whole client’s.
- (void)applyStoredDiagnosticsToDocument:(OakDocument*)document
{
	// An unloaded document has nowhere to put them — its diagnostics lived in a
	// buffer that no longer exists — and asks the store again when it loads. A
	// purge walks every document it owned, so this is worth not looking up.
	if(!document.isLoaded)
		return;

	NSString* uri = document.path ? [NSURL fileURLWithPath:document.path].absoluteString : nil;
	[self applyDiagnostics:uri ? [_diagnosticsStore diagnosticsForURI:uri] : @[] toDocument:document];
}

- (void)reapplyDiagnosticsForDocument:(OakDocument*)document
{
	[self applyStoredDiagnosticsToDocument:document];

	if(NSString* uri = document.path ? [NSURL fileURLWithPath:document.path].absoluteString : nil)
		[NSNotificationCenter.defaultCenter postNotificationName:LSPDiagnosticsDidChangeNotification object:self userInfo:@{ @"uri": uri }];
}

// Drop every client's entry for this document and update the UI. Only needed
// when a document leaves its server while staying open (grammar switch); a
// normal close keeps its diagnostics, since the client still owns them.
- (void)clearDiagnosticsForDocument:(OakDocument*)document
{
	if(NSString* uri = document.path ? [NSURL fileURLWithPath:document.path].absoluteString : nil)
		[_diagnosticsStore removeDiagnosticsForURI:uri];

	[self reapplyDiagnosticsForDocument:document];
}

// Everything one client published goes when the client does. Ownership is by
// client identity, not by workspace root and command, because a restart puts a
// new client under that same composite key — and its late predecessor must not
// take the successor's diagnostics with it.
// Every purge is explicit — none of them waits for lspClientDidTerminate: to
// notice. For a deliberate teardown that callback is not merely late: the
// task's termination handler holds the client weakly, so releasing the last
// strong reference deallocates it and the delegate call never happens at all.
- (void)purgeDiagnosticsForClient:(LSPClient*)client
{
	if(!client)
		return;

	// URI-driven rather than registration-driven. The documents a client is
	// *registered to* are not the files it published for: a workspace server
	// analyses files no editor is attached to, and a file open under one client
	// can carry a second client's diagnostics. Re-applying only the former
	// leaves the latter showing a dead server's squiggles for good.
	NSArray<NSString*>* removed = [_diagnosticsStore removeDiagnosticsForClientKey:client.identifier];
	[_workspaceRootByClientId removeObjectForKey:client.identifier];

	NSMutableSet<NSString*>* removedPaths = [NSMutableSet new];
	for(NSString* uri in removed)
	{
		if(NSString* filePath = [NSURL URLWithString:uri].path)
			[removedPaths addObject:filePath];
	}

	// Only documents that already exist. A file nobody opened has no buffer to
	// clear, and materializing one per URI would register hundreds of documents
	// on a single crash.
	if(removedPaths.count)
	{
		for(OakDocument* doc in OakDocumentController.sharedInstance.documents)
		{
			if(doc.path && [removedPaths containsObject:doc.path])
				[self applyStoredDiagnosticsToDocument:doc];
		}
	}

	// Announced once, not per document: most of what a workspace server
	// publishes is for files nobody opened, so a server can die owning nothing
	// that would carry the news on its own.
	[NSNotificationCenter.defaultCenter postNotificationName:LSPDiagnosticsDidChangeNotification object:self userInfo:@{}];
}

// The document's grammar changed: whatever registration it had under the
// old language — a client, a languageId, possibly none — no longer applies.
// Detach (a no-op when unregistered), drop the old language's diagnostics —
// a server that no longer covers the document will never send the empty
// update that would clear them — and run the open path again so the document
// attaches to whichever server the new type is configured with.
- (void)documentDidChangeFileType:(OakDocument*)document
{
	[self documentWillClose:document];
	[self clearDiagnosticsForDocument:document];
	[self documentDidOpen:document];
	[NSNotificationCenter.defaultCenter postNotificationName:LSPServerStatusDidChangeNotification object:self];
}

- (void)shutdownAll
{
	for(NSTimer* timer in _changeTimers.allValues)
		[timer invalidate];
	[_changeTimers removeAllObjects];

	for(LSPClient* client in _clients.allValues)
	{
		// Explicitly, before the last strong reference goes: this is the path
		// the AI pane's master switch takes, and leaving the store to
		// lspClientDidTerminate: would leave it holding every entry for the
		// rest of the session — that callback cannot arrive once the client is
		// deallocated (see purgeDiagnosticsForClient:).
		[self purgeDiagnosticsForClient:client];
		[client shutdown];
	}

	[_clients removeAllObjects];
	[_documentClients removeAllObjects];
	[_documentVersions removeAllObjects];
	[_openDocuments removeAllObjects];

	[NSNotificationCenter.defaultCenter postNotificationName:LSPServerStatusDidChangeNotification object:self];
}

- (void)flushPendingChangesForDocument:(OakDocument*)document
{
	NSUUID* docId = document.identifier;
	if(![_openDocuments containsObject:docId])
		return;

	// Cancel any pending debounce timer
	[_changeTimers[docId] invalidate];
	[_changeTimers removeObjectForKey:docId];

	// Always send current content so server has latest state
	LSPClient* client = _documentClients[docId];
	if(!client)
		return;

	int version = [_documentVersions[docId] intValue] + 1;
	_documentVersions[docId] = @(version);
	[client documentDidChange:document version:version];
}

- (void)requestCompletionsForDocument:(OakDocument*)document line:(NSUInteger)line character:(NSUInteger)character prefix:(NSString*)prefix completion:(void(^)(NSArray<NSDictionary*>*))callback
{
	NSUUID* docId = document.identifier;
	LSPClient* client = _documentClients[docId];
	if(!client)
	{
		if(callback)
			callback(@[]);
		return;
	}

	NSString* path = document.path;
	if(!path)
	{
		if(callback)
			callback(@[]);
		return;
	}

	NSURL* fileURL = [NSURL fileURLWithPath:path];
	NSString* uri = fileURL.absoluteString;

	[client requestCompletionForURI:uri line:line character:character completion:^(NSArray<NSDictionary*>* suggestions) {
		if(callback)
			callback(suggestions);
	}];
}

- (void)requestDefinitionForDocument:(OakDocument*)document line:(NSUInteger)line character:(NSUInteger)character completion:(void(^)(NSArray<NSDictionary*>*))callback
{
	NSUUID* docId = document.identifier;
	LSPClient* client = _documentClients[docId];
	if(!client)
	{
		if(callback)
			callback(@[]);
		return;
	}

	NSString* path = document.path;
	if(!path)
	{
		if(callback)
			callback(@[]);
		return;
	}

	NSURL* fileURL = [NSURL fileURLWithPath:path];
	NSString* uri = fileURL.absoluteString;

	[client requestDefinitionForURI:uri line:line character:character completion:callback];
}

- (int)requestHoverForDocument:(OakDocument*)document line:(NSUInteger)line character:(NSUInteger)character completion:(void(^)(NSDictionary*))callback
{
	NSUUID* docId = document.identifier;
	LSPClient* client = _documentClients[docId];
	if(!client)
	{
		if(callback)
			callback(nil);
		return 0;
	}

	NSString* path = document.path;
	if(!path)
	{
		if(callback)
			callback(nil);
		return 0;
	}

	NSURL* fileURL = [NSURL fileURLWithPath:path];
	NSString* uri = fileURL.absoluteString;

	return [client requestHoverForURI:uri line:line character:character completion:callback];
}

- (void)cancelRequest:(int)requestId forDocument:(OakDocument*)document
{
	if(requestId == 0)
		return;

	NSUUID* docId = document.identifier;
	LSPClient* client = _documentClients[docId];
	[client cancelRequest:requestId];
}

- (void)requestReferencesForDocument:(OakDocument*)document line:(NSUInteger)line character:(NSUInteger)character completion:(void(^)(NSArray<NSDictionary*>*))callback
{
	NSUUID* docId = document.identifier;
	LSPClient* client = _documentClients[docId];
	if(!client)
	{
		if(callback)
			callback(@[]);
		return;
	}

	NSString* path = document.path;
	if(!path)
	{
		if(callback)
			callback(@[]);
		return;
	}

	NSURL* fileURL = [NSURL fileURLWithPath:path];
	NSString* uri = fileURL.absoluteString;

	[client requestReferencesForURI:uri line:line character:character completion:callback];
}

- (void)requestFormattingForDocument:(OakDocument*)document tabSize:(NSUInteger)tabSize insertSpaces:(BOOL)insertSpaces completion:(void(^)(NSArray<NSDictionary*>*))callback
{
	NSUUID* docId = document.identifier;
	LSPClient* client = _documentClients[docId];
	if(!client || !client.documentFormattingProvider)
	{
		if(callback)
			callback(nil);
		return;
	}

	NSString* path = document.path;
	if(!path)
	{
		if(callback)
			callback(nil);
		return;
	}

	NSURL* fileURL = [NSURL fileURLWithPath:path];
	NSString* uri = fileURL.absoluteString;

	[client requestFormattingForURI:uri tabSize:tabSize insertSpaces:insertSpaces completion:callback];
}

- (void)requestRangeFormattingForDocument:(OakDocument*)document startLine:(NSUInteger)startLine startCharacter:(NSUInteger)startCharacter endLine:(NSUInteger)endLine endCharacter:(NSUInteger)endCharacter tabSize:(NSUInteger)tabSize insertSpaces:(BOOL)insertSpaces completion:(void(^)(NSArray<NSDictionary*>*))callback
{
	NSUUID* docId = document.identifier;
	LSPClient* client = _documentClients[docId];
	if(!client || !client.documentRangeFormattingProvider)
	{
		if(callback)
			callback(nil);
		return;
	}

	NSString* path = document.path;
	if(!path)
	{
		if(callback)
			callback(nil);
		return;
	}

	NSURL* fileURL = [NSURL fileURLWithPath:path];
	NSString* uri = fileURL.absoluteString;

	[client requestRangeFormattingForURI:uri startLine:startLine startCharacter:startCharacter endLine:endLine endCharacter:endCharacter tabSize:tabSize insertSpaces:insertSpaces completion:callback];
}

- (void)resolveCompletionItem:(NSDictionary*)item forDocument:(OakDocument*)document completion:(void(^)(NSDictionary*))callback
{
	NSUUID* docId = document.identifier;
	LSPClient* client = _documentClients[docId];
	if(!client)
	{
		if(callback)
			callback(nil);
		return;
	}

	[client resolveCompletionItem:item completion:^(NSDictionary* resolved) {
		if(callback)
			callback(resolved);
	}];
}

- (BOOL)serverSupportsCompletionResolveForDocument:(OakDocument*)document
{
	NSUUID* docId = document.identifier;
	LSPClient* client = _documentClients[docId];
	return client && client.completionResolveProvider;
}

- (BOOL)serverSupportsFormattingForDocument:(OakDocument*)document
{
	NSUUID* docId = document.identifier;
	LSPClient* client = _documentClients[docId];
	return client && client.documentFormattingProvider;
}

- (BOOL)serverSupportsRangeFormattingForDocument:(OakDocument*)document
{
	NSUUID* docId = document.identifier;
	LSPClient* client = _documentClients[docId];
	return client && client.documentRangeFormattingProvider;
}

- (BOOL)serverSupportsRenameForDocument:(OakDocument*)document
{
	NSUUID* docId = document.identifier;
	LSPClient* client = _documentClients[docId];
	return client && client.renameProvider;
}

- (void)requestPrepareRenameForDocument:(OakDocument*)document line:(NSUInteger)line character:(NSUInteger)character completion:(void(^)(NSDictionary* _Nullable))callback
{
	NSUUID* docId = document.identifier;
	LSPClient* client = _documentClients[docId];
	if(!client)
	{
		if(callback)
			callback(nil);
		return;
	}

	NSString* path = document.path;
	if(!path)
	{
		if(callback)
			callback(nil);
		return;
	}

	NSURL* fileURL = [NSURL fileURLWithPath:path];
	NSString* uri = fileURL.absoluteString;

	[client prepareRenameForURI:uri line:line character:character completion:callback];
}

- (void)requestRenameForDocument:(OakDocument*)document line:(NSUInteger)line character:(NSUInteger)character newName:(NSString*)newName completion:(void(^)(NSDictionary* _Nullable))callback
{
	NSUUID* docId = document.identifier;
	LSPClient* client = _documentClients[docId];
	if(!client)
	{
		if(callback)
			callback(nil);
		return;
	}

	NSString* path = document.path;
	if(!path)
	{
		if(callback)
			callback(nil);
		return;
	}

	NSURL* fileURL = [NSURL fileURLWithPath:path];
	NSString* uri = fileURL.absoluteString;

	[client requestRenameForURI:uri line:line character:character newName:newName completion:callback];
}

- (BOOL)serverSupportsCodeActionsForDocument:(OakDocument*)document
{
	NSUUID* docId = document.identifier;
	LSPClient* client = _documentClients[docId];
	return client && client.codeActionProvider;
}

- (BOOL)serverSupportsCodeActionResolveForDocument:(OakDocument*)document
{
	NSUUID* docId = document.identifier;
	LSPClient* client = _documentClients[docId];
	return client && client.codeActionResolveProvider;
}

- (void)requestCodeActionsForDocument:(OakDocument*)document line:(NSUInteger)line character:(NSUInteger)character endLine:(NSUInteger)endLine endCharacter:(NSUInteger)endCharacter completion:(void(^)(NSArray<NSDictionary*>*))callback
{
	NSUUID* docId = document.identifier;
	LSPClient* client = _documentClients[docId];
	if(!client)
	{
		if(callback) callback(nil);
		return;
	}

	NSString* path = document.path;
	if(!path)
	{
		if(callback) callback(nil);
		return;
	}

	NSURL* fileURL = [NSURL fileURLWithPath:path];
	NSString* uri = fileURL.absoluteString;

	NSArray<NSDictionary*>* diagnostics = [self diagnosticsForDocument:document atLine:line character:character endLine:endLine endCharacter:endCharacter];

	[self flushPendingChangesForDocument:document];
	[client requestCodeActionsForURI:uri line:line character:character endLine:endLine endCharacter:endCharacter diagnostics:diagnostics completion:callback];
}

- (void)resolveCodeAction:(NSDictionary*)codeAction forDocument:(OakDocument*)document completion:(void(^)(NSDictionary*))callback
{
	NSUUID* docId = document.identifier;
	LSPClient* client = _documentClients[docId];
	if(!client)
	{
		if(callback) callback(nil);
		return;
	}
	[client resolveCodeAction:codeAction completion:callback];
}

- (void)executeCommand:(NSString*)command arguments:(NSArray*)arguments forDocument:(OakDocument*)document completion:(void(^)(id))callback
{
	NSUUID* docId = document.identifier;
	LSPClient* client = _documentClients[docId];
	if(!client)
	{
		if(callback) callback(nil);
		return;
	}
	[client executeCommand:command arguments:arguments completion:callback];
}

- (BOOL)hasClientForDocument:(OakDocument*)document
{
	return document && _documentClients[document.identifier] != nil;
}

- (NSDictionary<NSString*, NSNumber*>*)diagnosticCountsForDocument:(OakDocument*)document
{
	NSUInteger errors = 0, warnings = 0, info = 0;
	NSString* path = document.path;
	if(path)
	{
		NSURL* fileURL = [NSURL fileURLWithPath:path];
		NSArray<NSDictionary*>* diags = [_diagnosticsStore diagnosticsForURI:fileURL.absoluteString];
		for(NSDictionary* diag in diags)
		{
			switch([diag[@"severity"] intValue])
			{
				case 1:  errors++;   break;
				case 2:  warnings++; break;
				case 3:
				case 4:  info++;     break;
				default: break;
			}
		}
	}
	return @{ @"errors": @(errors), @"warnings": @(warnings), @"info": @(info) };
}

// The CONFIGURED lspCommand for this document (settings with bundle
// Preferences fallback), or the empty string when none is set — independent
// of whether a client is currently attached.
static std::string configuredCommandForDocument (OakDocument* document)
{
	NSString* path = document.path;
	if(!path)
		return "";

	std::string filePath  = to_s(path);
	std::string fileType  = to_s(document.fileType);
	std::string directory = to_s(document.directory ?: [path stringByDeletingLastPathComponent]);

	settings_t settings = settings_for_path(filePath, fileType, directory);
	return lsp::setting_with_bundle_fallback(kSettingsLSPCommandKey, settings, scope::scope_t(fileType));
}

// The workspace root the document's client uses (lspRootPath setting or
// marker detection) — the unit the failure cache is scoped by.
- (NSString*)workspaceRootForDocument:(OakDocument*)document
{
	NSString* path = document.path;
	if(!path)
		return nil;

	std::string filePath  = to_s(path);
	std::string fileType  = to_s(document.fileType);
	std::string directory = to_s(document.directory ?: [path stringByDeletingLastPathComponent]);

	settings_t settings = settings_for_path(filePath, fileType, directory);
	std::string rootPath = lsp::setting_with_bundle_fallback(kSettingsLSPRootPathKey, settings, scope::scope_t(fileType));
	if(rootPath.empty())
		rootPath = detectWorkspaceRoot(filePath);
	return to_ns(rootPath);
}

- (NSString*)serverStatusForDocument:(OakDocument*)document
{
	LSPClient* client = _documentClients[document.identifier];
	if(!client)
	{
		// No client can mean “nothing configured” (nil → idle look) or “the
		// configured command failed to launch” — the status bar must not
		// render the latter as idle. A document whose effective lspEnabled is
		// off is idle by choice, never “unavailable”, even with a recorded
		// failure — re-enabling brings the failure state back until Restart
		// Server retries.
		std::string lspCommand = configuredCommandForDocument(document);
		if(!lspCommand.empty() && [self lspEnabledForDocument:document])
		{
			NSString* root = [self workspaceRootForDocument:document];
			if(root && [_failedCommandsByRoot[root] containsObject:to_ns(lspCommand)])
				return @"unavailable";
		}
		return nil;
	}
	if(client.initialized && client.indexing)
		return @"indexing";
	if(client.initialized)
		return @"running";
	if(client.running)
		return @"starting";
	return nil;
}

// The CONFIGURED server for this document — independent of whether a client
// is currently attached or lspEnabled permits one, so the status-bar menu
// can offer the per-file-type toggle while the server is disabled.
- (NSString*)serverNameForDocument:(OakDocument*)document
{
	std::string lspCommand = configuredCommandForDocument(document);
	if(lspCommand.empty())
		return nil;

	std::vector<std::string> parts = path::unescape(lspCommand);
	if(parts.empty())
		return nil;

	return [[NSString stringWithCxxString:parts[0]] lastPathComponent];
}

- (void)restartServerForDocument:(OakDocument*)document
{
	// Forget this workspace's failed launches so the restart really retries —
	// the recovery path after the user installs a missing server binary.
	// Other workspaces' failure records stay untouched.
	if(NSString* root = [self workspaceRootForDocument:document])
		[_failedCommandsByRoot removeObjectForKey:root];

	LSPClient* client = _documentClients[document.identifier];
	if(!client)
	{
		// A failed launch left the document unregistered (documentDidOpen:
		// bailed before adding it), so opening it again runs the full path.
		[self documentDidOpen:document];
		[NSNotificationCenter.defaultCenter postNotificationName:LSPServerStatusDidChangeNotification object:self];
		return;
	}

	// Collect affected documents and clean up state synchronously
	// so documentDidOpen: can re-register them with a fresh client
	NSMutableArray<OakDocument*>* affectedDocs = [NSMutableArray new];
	for(NSUUID* docId in _documentClients)
	{
		if(_documentClients[docId] == client)
		{
			OakDocument* doc = [OakDocument documentWithIdentifier:docId];
			if(doc && doc.isLoaded)
				[affectedDocs addObject:doc];
		}
	}

	// Remove client from _clients so a new one will be created
	NSString* keyToRemove = [self keyForClient:client];
	if(keyToRemove)
		[_clients removeObjectForKey:keyToRemove];

	// The restarted server republishes from scratch, so nothing the old one
	// said outlives it. Done here rather than left to the old process's late
	// termination callback, which arrives after the new client has connected.
	[self purgeDiagnosticsForClient:client];

	// Dissociate documents before shutdown
	for(OakDocument* doc in affectedDocs)
	{
		NSUUID* docId = doc.identifier;
		[_changeTimers[docId] invalidate];
		[_changeTimers removeObjectForKey:docId];
		[_documentClients removeObjectForKey:docId];
		[_documentVersions removeObjectForKey:docId];
		[_openDocuments removeObject:docId];
	}

	// Old process shuts down asynchronously; lspClientDidTerminate: will be a no-op
	[client shutdown];

	// Re-open with fresh client immediately
	for(OakDocument* doc in affectedDocs)
		[self documentDidOpen:doc];

	[NSNotificationCenter.defaultCenter postNotificationName:LSPServerStatusDidChangeNotification object:self];
}

- (BOOL)lspEnabledForDocument:(OakDocument*)document
{
	if(!document.path)
		return settings_for_path().get(kSettingsLSPEnabledKey, true);

	std::string filePath  = to_s(document.path);
	std::string fileType  = to_s(document.fileType);
	std::string directory = to_s(document.directory ?: [document.path stringByDeletingLastPathComponent]);

	settings_t settings = settings_for_path(filePath, fileType, directory);
	return lsp::setting_with_bundle_fallback(kSettingsLSPEnabledKey, settings, scope::scope_t(fileType), true);
}

- (void)stopServerForDocument:(OakDocument*)document
{
	LSPClient* client = _documentClients[document.identifier];
	if(!client)
		return;

	// Dissociate every document served by this client so a later
	// documentDidOpen: (lazy attach on focus) can start fresh
	NSString* keyToRemove = [self keyForClient:client];
	if(keyToRemove)
		[_clients removeObjectForKey:keyToRemove];

	// Stopping is a detach like any other: no publisher is left, so what this
	// server said goes with it rather than lingering until something reopens.
	[self purgeDiagnosticsForClient:client];

	for(NSUUID* docId in [_documentClients allKeys])
	{
		if(_documentClients[docId] != client)
			continue;

		[_changeTimers[docId] invalidate];
		[_changeTimers removeObjectForKey:docId];
		[_documentClients removeObjectForKey:docId];
		[_documentVersions removeObjectForKey:docId];
		[_openDocuments removeObject:docId];
	}

	[client shutdown];

	[NSNotificationCenter.defaultCenter postNotificationName:LSPServerStatusDidChangeNotification object:self];
}

- (void)reindexWorkspaceForDocument:(OakDocument*)document
{
	LSPClient* client = _documentClients[document.identifier];
	if(!client)
		return;

	// Check if server advertises a reindex-like command
	for(NSString* cmd in client.executeCommands)
	{
		NSString* lower = cmd.lowercaseString;
		if([lower containsString:@"reindex"] || [lower containsString:@"index.workspace"] || [lower containsString:@"index-workspace"])
		{
			NSLog(@"[LSP:%@] Re-index: using server command '%@'", client.serverName, cmd);
			[client executeCommand:cmd arguments:nil completion:^(id result) {
				if(!result)
					NSLog(@"[LSP:%@] Re-index command '%@' failed or returned null", client.serverName, cmd);
			}];
			return;
		}
	}
	NSLog(@"[LSP:%@] Re-index: restarting with clearCache", client.serverName);

	// Fallback: restart with clearCache in initializationOptions
	if(NSString* keyToFlag = [self keyForClient:client])
		[_clearCacheKeys addObject:keyToFlag];

	[self restartServerForDocument:document];
}

- (NSArray<NSDictionary*>*)diagnosticsForDocument:(OakDocument*)document atLine:(NSUInteger)line character:(NSUInteger)character endLine:(NSUInteger)endLine endCharacter:(NSUInteger)endCharacter
{
	NSString* path = document.path;
	if(!path)
		return @[];

	NSURL* fileURL = [NSURL fileURLWithPath:path];
	NSString* uri = fileURL.absoluteString;
	NSArray<NSDictionary*>* allDiags = [_diagnosticsStore diagnosticsForURI:uri];
	if(!allDiags.count)
		return @[];

	NSMutableArray<NSDictionary*>* result = [NSMutableArray array];
	for(NSDictionary* diag in allDiags)
	{
		NSUInteger dLine    = [diag[@"line"] unsignedIntegerValue];
		NSUInteger dEndLine = [diag[@"endLine"] unsignedIntegerValue];

		// Simple line-range overlap check
		if(dEndLine >= line && dLine <= endLine)
			[result addObject:diag];
	}
	return result;
}

// Read-only access to the diagnostics cache (used by AgentBridge’s getDiagnostics).
// Main thread only: the cache is filled from handleMessage, which runs on the main queue.
- (NSDictionary<NSString*, NSArray<NSDictionary*>*>*)allDiagnosticsByURI
{
	return [_diagnosticsStore allDiagnosticsByURI];
}

- (LSPDiagnosticsSnapshot*)diagnosticsSnapshotForWorkspaceRoots:(NSArray<NSString*>*)roots
{
	return [_diagnosticsStore snapshotForWorkspaceRoots:roots];
}

- (NSString*)diagnosticsRevisionForWorkspaceRoots:(NSArray<NSString*>*)roots
{
	return [_diagnosticsStore revisionForWorkspaceRoots:roots];
}

#pragma mark - LSPClientDelegate

- (void)lspClient:(LSPClient*)client didReceiveApplyEditRequest:(NSDictionary*)workspaceEdit requestId:(id)requestId
{
	dispatch_async(dispatch_get_main_queue(), ^{
		NSDictionary* userInfo = @{
			@"workspaceEdit": workspaceEdit,
			@"requestId": requestId ?: [NSNull null],
			@"client": client
		};
		[NSNotificationCenter.defaultCenter postNotificationName:@"LSPApplyEditRequest" object:self userInfo:userInfo];
	});
}

- (void)lspClientDidTerminate:(LSPClient*)client
{
	NSLog(@"[LSP:%@] Handling server termination, cleaning up client", client.serverName);

	// Find and remove the dead client from _clients
	NSString* keyToRemove = [self keyForClient:client];
	if(keyToRemove)
		[_clients removeObjectForKey:keyToRemove];

	// Nobody is left to update or retract what this server said — cross-file
	// entries included, which the panel would otherwise keep listing.
	[self purgeDiagnosticsForClient:client];

	// Dissociate all documents that were using this client
	NSMutableArray<NSUUID*>* docIdsToRemove = [NSMutableArray new];
	for(NSUUID* docId in _documentClients)
	{
		if(_documentClients[docId] == client)
			[docIdsToRemove addObject:docId];
	}

	for(NSUUID* docId in docIdsToRemove)
	{
		[_changeTimers[docId] invalidate];
		[_changeTimers removeObjectForKey:docId];
		[_documentClients removeObjectForKey:docId];
		[_documentVersions removeObjectForKey:docId];
		[_openDocuments removeObject:docId];
	}

	[NSNotificationCenter.defaultCenter postNotificationName:LSPServerStatusDidChangeNotification object:self];
}

// Push diagnostics into a loaded document, as ranges in its buffer. Shared by
// arrival and the re-apply paths (didOpen of a file the server already
// analyzed, reload).
//
// The gutter is deliberately not among the surfaces written to. Diagnostics
// used to be published as `error`/`warning`/`note` marks in the bookmark
// column, which is where they were read from — a click per message, in a
// column that already had a job. Every one of those roles now has a surface of
// its own (squiggle, hover, panel, minimap lane), so the column is left to the
// bookmarks and to whatever `mate --set-mark` puts there.
- (void)applyDiagnostics:(NSArray<NSDictionary*>*)diagnostics toDocument:(OakDocument*)doc
{
	if(!doc || !doc.isLoaded)
		return;

	[doc setDiagnostics:diagnostics];
}

- (void)lspClient:(LSPClient*)client didReceiveDiagnostics:(NSArray<NSDictionary*>*)diagnostics forDocumentURI:(NSString*)uri
{
	// Publishes reach the main queue by dispatch_async, so one parsed just
	// before the user hit Stop or Restart Server routinely lands after the
	// purge. Taking it would resurrect a dead server's diagnostics — with no
	// workspace root, since the purge took that too — and after an explicit
	// stop nothing would ever republish to take them down again.
	if(![self keyForClient:client])
		return;

	// Cached under the publishing client, so a second server's diagnostics for
	// the same file survive this one replacing its own. An empty publish means
	// the file is clean, which the store expresses as the absence of an entry —
	// the cross-file panel must not list a file with nothing left in it.
	[_diagnosticsStore setDiagnostics:diagnostics forURI:uri clientKey:client.identifier workspaceRoot:_workspaceRootByClientId[client.identifier]];

	NSURL* url = [NSURL URLWithString:uri];
	NSString* filePath = url.path;
	if(!filePath)
		return;

	OakDocument* doc = [OakDocument documentWithPath:filePath];
	// The document shows every server's view of it, not just this publisher's.
	[self applyDiagnostics:[_diagnosticsStore diagnosticsForURI:uri] toDocument:doc];

	[NSNotificationCenter.defaultCenter postNotificationName:LSPDiagnosticsDidChangeNotification object:self userInfo:@{ @"uri": uri }];
}

- (NSSet<NSString*>*)lspClientOpenDocumentPaths:(LSPClient*)client
{
	NSMutableSet<NSString*>* paths = [NSMutableSet new];
	for(NSUUID* docId in _openDocuments)
	{
		if(_documentClients[docId] != client)
			continue;

		OakDocument* doc = [OakDocument documentWithIdentifier:docId];
		if(doc.path)
			[paths addObject:doc.path];
	}
	return paths;
}
@end
