#import "AgentBridgeWorkspace.h"
#import "agent_routing_path.h"
#import <document/OakDocument.h>
#import <document/OakDocument Private.h>
#import <document/OakDocumentController.h>
#import <lsp/LSPManager.h>
#import <selection/selection.h>
#import <text/types.h>
#import <io/path.h>
#import <ns/ns.h>

// Informal protocol matched against NSWindow delegates: DocumentWindowController
// implements all of these, but AgentBridge must not depend on the DocumentWindow
// framework (DocumentWindow links AgentBridge for the terminal environment
// injection, so the dependency has to stay one-directional).
@protocol AgentBridgeHostWindow <NSObject>
- (NSString*)projectPath;
- (NSArray<OakDocument*>*)documents;
- (OakDocument*)selectedDocument;
@end

// Additional DocumentWindowController selectors used opportunistically
// (guarded by respondsToSelector:) — same one-directional dependency rule.
@protocol AgentBridgeHostWindowExtras <NSObject>
@optional
- (void)makeTextViewFirstResponder:(id)sender;
- (void)closeTabsAtIndexes:(NSIndexSet*)anIndexSet askToSaveChanges:(BOOL)askToSaveFlag createDocumentIfEmpty:(BOOL)createIfEmptyFlag activate:(BOOL)activateFlag;
@end

static id <AgentBridgeHostWindow> HostControllerForWindow (NSWindow* window)
{
	id delegate = window.delegate;
	if([delegate respondsToSelector:@selector(projectPath)] && [delegate respondsToSelector:@selector(documents)] && [delegate respondsToSelector:@selector(selectedDocument)])
		return delegate;
	return nil;
}

// Front-to-back list of document window controllers. [NSApp orderedWindows]
// provides the ordering but excludes miniaturized windows, so sweep the
// miniaturized ones afterwards — a minimized project must not drop out of
// the lock file or getOpenEditors.
static NSArray<id <AgentBridgeHostWindow>>* HostControllers ()
{
	NSMutableArray* res = [NSMutableArray array];
	for(NSWindow* window in [NSApp orderedWindows])
	{
		if(id <AgentBridgeHostWindow> controller = HostControllerForWindow(window))
		{
			if([res indexOfObjectIdenticalTo:controller] == NSNotFound)
				[res addObject:controller];
		}
	}
	for(NSWindow* window in NSApp.windows)
	{
		if(!window.miniaturized)
			continue;
		if(id <AgentBridgeHostWindow> controller = HostControllerForWindow(window))
		{
			if([res indexOfObjectIdenticalTo:controller] == NSNotFound)
				[res addObject:controller];
		}
	}
	return res;
}

// Byte columns on purpose: the resulting text::pos_t feeds TextMate’s own
// selection machinery (showDocument:andSelect: → ng::convert), which resolves
// pos_t.column as a byte offset within the line (selection.cc cap(),
// buffer.h:118). Character counts here would corrupt multibyte selections.
static text::pos_t PositionForOffset (std::string const& content, size_t offset)
{
	size_t line = 0, bol = 0;
	for(size_t i = 0; i < offset && i < content.size(); ++i)
	{
		if(content[i] == '\n')
		{
			++line;
			bol = i+1;
		}
	}
	return text::pos_t(line, offset - bol);
}

static text::range_t RangeForTextMatch (std::string const& content, NSString* startText, NSString* endText, BOOL selectToEndOfLine)
{
	if(!startText.length)
		return text::range_t::undefined;

	std::string const needle = to_s(startText);
	size_t first = content.find(needle);
	if(first == std::string::npos)
		return text::range_t::undefined;

	size_t last = first + needle.size();
	if(endText.length)
	{
		std::string const endNeedle = to_s(endText);
		size_t match = content.find(endNeedle, last);
		if(match != std::string::npos)
			last = match + endNeedle.size();
	}

	if(selectToEndOfLine)
	{
		size_t eol = content.find('\n', last);
		last = eol == std::string::npos ? content.size() : eol;
	}

	return text::range_t(PositionForOffset(content, first), PositionForOffset(content, last));
}

@implementation AgentBridgeSelection
@end

static void* kAgentBridgeSelectionObserverContext = &kAgentBridgeSelectionObserverContext;

@implementation AgentBridgeWorkspace
{
	NSObject* _observedTextView;
	NSWindow* _observedWindow;
	NSArray<NSString*>* _lastWorkspaceFolders;
	NSUInteger _selectionGeneration;
}

- (instancetype)init
{
	if(self = [super init])
	{
		[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(windowDidChange:) name:NSWindowDidBecomeKeyNotification object:nil];
		[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(windowDidChange:) name:NSWindowDidBecomeMainNotification object:nil];
		[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(windowWillClose:) name:NSWindowWillCloseNotification object:nil];
		_lastWorkspaceFolders = [self workspaceFolders];

		// Windows created before setup won’t emit a key/main notification —
		// bind to whatever is already frontmost once the runloop settles.
		dispatch_async(dispatch_get_main_queue(), ^{
			[self rebindSelectionObservation];
		});
	}
	return self;
}

- (void)dealloc
{
	[NSNotificationCenter.defaultCenter removeObserver:self];
	[self unbindSelectionObservation];
}

// ========================
// = Workspace enumeration =
// ========================

- (NSArray<NSString*>*)workspaceFolders
{
	NSMutableOrderedSet<NSString*>* folders = [NSMutableOrderedSet orderedSet];
	for(id <AgentBridgeHostWindow> controller in HostControllers())
	{
		if(NSString* path = controller.projectPath)
			[folders addObject:path];
	}
	return folders.array;
}

- (NSString*)activeProjectPath
{
	NSWindow* keyWindow = NSApp.keyWindow ?: NSApp.mainWindow;
	if(id <AgentBridgeHostWindow> controller = keyWindow ? HostControllerForWindow(keyWindow) : nil)
		return controller.projectPath;
	return [self workspaceFolders].firstObject;
}

- (id <AgentBridgeHostWindow>)activeController
{
	NSWindow* keyWindow = NSApp.keyWindow ?: NSApp.mainWindow;
	if(id <AgentBridgeHostWindow> controller = keyWindow ? HostControllerForWindow(keyWindow) : nil)
		return controller;
	return HostControllers().firstObject;
}

// The window that answers a query from an agent started in ‘routingPath’: the
// one whose project root contains it, longest root first so a project checked
// out inside another does not lose to its parent. Nothing containing it (or no
// path at all) means the asking process is outside every open project, and the
// frontmost window is the best guess left.
- (id <AgentBridgeHostWindow>)controllerForRoutingPath:(NSString*)routingPath
{
	if(!routingPath.length || !routingPath.absolutePath)
		return [self activeController];

	std::string const cwd = agent_routing_path::normalize(to_s(routingPath));

	id <AgentBridgeHostWindow> res = nil;
	size_t bestLength = 0;
	for(id <AgentBridgeHostWindow> controller in HostControllers())
	{
		NSString* projectPath = controller.projectPath;
		if(!projectPath.length)
			continue;

		std::string const root = agent_routing_path::normalize(to_s(projectPath));
		if(root != cwd && !path::is_child(cwd, root))
			continue;
		if(res && root.size() <= bestLength)
			continue;

		res        = controller;
		bestLength = root.size();
	}
	return res ?: [self activeController];
}

- (NSString*)projectPathForRoutingPath:(NSString*)routingPath
{
	return [self controllerForRoutingPath:routingPath].projectPath ?: [self workspaceFolders].firstObject;
}

- (BOOL)canRouteIDEContextForWorkspaceRoot:(NSString*)workspaceRoot
{
	if(!workspaceRoot.length || !workspaceRoot.absolutePath)
		return NO;

	for(NSString* folder in [self workspaceFolders])
	{
		// A parent of several open projects is ambiguous. Only advertise a
		// provider when controllerForRoutingPath: can resolve the same project
		// without falling back to whichever window happens to be active.
		if(agent_routing_path::routes_to_project(to_s(workspaceRoot), to_s(folder)))
			return YES;
	}
	return NO;
}

- (NSWindow*)windowForController:(id <AgentBridgeHostWindow>)controller
{
	if(!controller)
		return nil;

	for(NSArray<NSWindow*>* windows in @[ [NSApp orderedWindows], NSApp.windows ])
	{
		for(NSWindow* window in windows)
		{
			if(window.delegate == (id)controller)
				return window;
		}
	}
	return nil;
}

- (NSArray<NSDictionary*>*)openEditors
{
	return [self openEditorsForRoutingPath:nil];
}

- (NSArray<NSDictionary*>*)openEditorsForRoutingPath:(NSString*)routingPath
{
	NSMutableArray<NSDictionary*>* res = [NSMutableArray array];
	id <AgentBridgeHostWindow> activeController = [self controllerForRoutingPath:routingPath];
	for(id <AgentBridgeHostWindow> controller in HostControllers())
	{
		for(OakDocument* document in controller.documents)
		{
			if(!document.path)
				continue;

			[res addObject:@{
				@"path":       document.path,
				@"isActive":   @(controller == activeController && document == controller.selectedDocument),
				@"label":      document.displayName ?: document.path.lastPathComponent,
				@"languageId": document.fileType ?: @"plaintext",
				@"isDirty":    @(document.isDocumentEdited),
			}];
		}
	}
	return res;
}

- (NSArray<NSDictionary*>*)openEditorsInAnsweringWindowForRoutingPath:(NSString*)routingPath
{
	NSMutableArray<NSDictionary*>* res = [NSMutableArray array];
	id <AgentBridgeHostWindow> controller = [self controllerForRoutingPath:routingPath];
	for(OakDocument* document in controller.documents)
	{
		if(!document.path)
			continue;

		[res addObject:@{
			@"path":       document.path,
			@"isActive":   @(document == controller.selectedDocument),
			@"label":      document.displayName ?: document.path.lastPathComponent,
			@"languageId": document.fileType ?: @"plaintext",
			@"isDirty":    @(document.isDocumentEdited),
		}];
	}
	return res;
}

// =============
// = Selection =
// =============

- (AgentBridgeSelection*)currentSelection
{
	return [self currentSelectionForRoutingPath:nil];
}

- (AgentBridgeSelection*)currentSelectionForRoutingPath:(NSString*)routingPath
{
	id <AgentBridgeHostWindow> controller = [self controllerForRoutingPath:routingPath];
	OakDocument* document = controller.selectedDocument;
	if(!document || !document.isLoaded)
		return nil;

	NSString* selectionString = document.selection;
	if(_observedTextView && controller == (id)_observedWindow.delegate)
		selectionString = [_observedTextView valueForKey:@"selectionString"] ?: selectionString;

	ng::buffer_t& buffer = [document buffer];
	ng::ranges_t const ranges = ng::convert(buffer, text::selection_t(selectionString ? to_s(selectionString) : "1"));
	if(ranges.empty())
		return nil;

	ng::range_t const range = ranges.last();
	size_t from = std::min<size_t>(range.min().index, buffer.size());
	size_t to   = std::min<size_t>(range.max().index, buffer.size());

	text::pos_t const start = buffer.convert(from);
	text::pos_t const end   = buffer.convert(to);

	// pos_t.column is a byte offset within the line (buffer.h:118); the
	// protocol wants LSP-style character offsets (UTF-16 code units, what
	// VS Code reports), which differ on any multi-byte text. Convert by
	// measuring the line prefix.
	auto characterOffset = [&buffer](text::pos_t const& pos, size_t index) -> NSUInteger {
		size_t bol = buffer.begin(std::min(pos.line, buffer.lines()-1));
		return bol < index ? to_ns(buffer.substr(bol, index)).length : 0;
	};

	AgentBridgeSelection* res = [AgentBridgeSelection new];
	res.filePath       = document.path;
	res.text           = to_ns(buffer.substr(from, to));
	res.startLine      = start.line;
	res.startCharacter = characterOffset(start, from);
	res.endLine        = end.line;
	res.endCharacter   = characterOffset(end, to);
	res.empty          = from == to;
	return res;
}

- (void)windowDidChange:(NSNotification*)aNotification
{
	[self rebindSelectionObservation];
	[self checkWorkspaceFolders];
}

- (void)windowWillClose:(NSNotification*)aNotification
{
	if(aNotification.object == _observedWindow)
		[self unbindSelectionObservation];

	// Folders change once the window is gone; check on the next runloop pass.
	dispatch_async(dispatch_get_main_queue(), ^{
		[self rebindSelectionObservation];
		[self checkWorkspaceFolders];
	});
}

- (void)rebindSelectionObservation
{
	// The key window may be a panel (Find, filter list, …) that is not a
	// document window — fall back to the main window and then the frontmost
	// document window instead of dropping the observation.
	NSWindow* window = nil;
	id <AgentBridgeHostWindow> controller = nil;
	if(NSApp.keyWindow && (controller = HostControllerForWindow(NSApp.keyWindow)))
		window = NSApp.keyWindow;
	else if(NSApp.mainWindow && (controller = HostControllerForWindow(NSApp.mainWindow)))
		window = NSApp.mainWindow;
	else if((controller = [self activeController]))
		window = [self windowForController:controller];

	NSObject* textView = nil;
	if(controller && [(id)controller respondsToSelector:@selector(textView)])
		textView = [(id)controller valueForKey:@"textView"];

	if(textView == _observedTextView)
		return;

	[self unbindSelectionObservation];
	if(textView)
	{
		// Observe the document too: a tab switch swaps the text view’s document
		// but setSelectionString: early-returns when the new document’s caret
		// spells the same selection string (e.g. both files at 1:1), so the
		// selectionString observation alone misses tab switches — and the CLI
		// would keep targeting the previous file. This is the counterpart of
		// claudecode.nvim sending selection_changed on BufEnter.
		[textView addObserver:self forKeyPath:@"selectionString" options:0 context:kAgentBridgeSelectionObserverContext];
		[textView addObserver:self forKeyPath:@"document" options:0 context:kAgentBridgeSelectionObserverContext];
		_observedTextView = textView;
		_observedWindow   = window;
		[self noteSelectionMayHaveChanged];
	}
}

- (void)unbindSelectionObservation
{
	[_observedTextView removeObserver:self forKeyPath:@"selectionString" context:kAgentBridgeSelectionObserverContext];
	[_observedTextView removeObserver:self forKeyPath:@"document" context:kAgentBridgeSelectionObserverContext];
	_observedTextView = nil;
	_observedWindow   = nil;
}

- (void)observeValueForKeyPath:(NSString*)keyPath ofObject:(id)object change:(NSDictionary*)change context:(void*)context
{
	if(context == kAgentBridgeSelectionObserverContext)
		[self noteSelectionMayHaveChanged];
	else
		[super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
}

- (void)noteSelectionMayHaveChanged
{
	NSUInteger generation = ++_selectionGeneration; // ~100 ms debounce so notification traffic doesn’t track every caret movement
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		if(generation != self->_selectionGeneration)
			return;

		AgentBridgeSelection* selection = [self currentSelection];
		if(!selection)
			return;

		if(!selection.isEmpty)
			self->_latestSelection = selection;
		if(self.selectionDidChangeHandler)
			self.selectionDidChangeHandler(selection);

		// Tab switches move the caret and can change the window’s project
		// path (document directory fallback) — keep the lock file current.
		[self checkWorkspaceFolders];
	});
}

- (void)checkWorkspaceFolders
{
	NSArray<NSString*>* folders = [self workspaceFolders];
	if([folders isEqualToArray:_lastWorkspaceFolders])
		return;

	_lastWorkspaceFolders = folders;
	if(self.workspaceFoldersDidChangeHandler)
		self.workspaceFoldersDidChangeHandler(folders);
}

// =============
// = Documents =
// =============

// Lexical only (path::normalize) — must not touch the file system, since
// callers run on the main thread and paths come from an external client.
- (NSString*)absolutePathForPath:(NSString*)path
{
	return [self absolutePathForPath:path routingPath:nil];
}

- (NSString*)absolutePathForPath:(NSString*)path routingPath:(NSString*)routingPath
{
	path = path.stringByExpandingTildeInPath;
	if(!path.isAbsolutePath)
	{
		// A relative path from an agent means “relative to where I am”: the
		// routing path is that process’ own cwd, which is a better answer than
		// the project of whatever window happens to be frontmost.
		NSString* root = routingPath.length && routingPath.absolutePath ? routingPath : ([self projectPathForRoutingPath:routingPath] ?: NSHomeDirectory());
		path = [root stringByAppendingPathComponent:path];
	}
	return to_ns(path::normalize(to_s(path)));
}

- (OakDocument*)openDocumentAtPath:(NSString*)path
{
	return [self openDocumentAtPath:path routingPath:nil];
}

- (OakDocument*)openDocumentAtPath:(NSString*)path routingPath:(NSString*)routingPath
{
	NSString* standardized = [self absolutePathForPath:path routingPath:routingPath];
	for(OakDocument* document in [OakDocumentController.sharedInstance openDocuments])
	{
		if(document.path && [document.path isEqualToString:standardized])
			return document;
	}
	return nil;
}

- (void)openFileAtPath:(NSString*)path selectFromText:(NSString*)startText toText:(NSString*)endText selectToEndOfLine:(BOOL)selectToEndOfLine makeFrontmost:(BOOL)makeFrontmost routingPath:(NSString*)routingPath completionHandler:(void(^)(OakDocument*, NSUInteger))handler
{
	NSString* absolutePath = [self absolutePathForPath:path routingPath:routingPath];

	// Open in the window that answers for the asking agent, so a file it names
	// lands beside the project it is working on rather than in whichever window
	// is frontmost. nil identifier keeps TextMate’s own project choice.
	NSObject* routedController = (NSObject*)[self controllerForRoutingPath:routingPath];
	NSUUID* projectIdentifier = nil;
	if(routingPath.length && [routedController respondsToSelector:@selector(identifier)])
	{
		id identifier = [routedController valueForKey:@"identifier"];
		if([identifier isKindOfClass:[NSUUID class]])
			projectIdentifier = identifier;
	}

	// Never stat or read an arbitrary path on the main thread: open(2) can
	// block indefinitely (pending TCC consent, dead mounts, dataless files)
	// and a blocked main thread would freeze the whole app.
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		BOOL isDirectory = NO;
		BOOL exists = [NSFileManager.defaultManager fileExistsAtPath:absolutePath isDirectory:&isDirectory] && !isDirectory;
		NSString* diskContent = exists ? [NSString stringWithContentsOfFile:absolutePath encoding:NSUTF8StringEncoding error:nil] : nil;

		dispatch_async(dispatch_get_main_queue(), ^{
			if(!exists)
				return handler(nil, 0);

			OakDocument* document = [OakDocumentController.sharedInstance documentWithPath:absolutePath];
			if(!document)
				return handler(nil, 0);

			NSString* content = document.isLoaded ? document.content : diskContent;
			std::string const buffer = content ? to_s(content) : std::string();

			text::range_t const range = RangeForTextMatch(buffer, startText, endText, selectToEndOfLine);
			[OakDocumentController.sharedInstance showDocument:document andSelect:range inProject:projectIdentifier bringToFront:makeFrontmost];

			// Opening a document can create a window or change the active
			// project without any key-window notification firing.
			[self rebindSelectionObservation];
			[self checkWorkspaceFolders];

			NSUInteger lineCount = content ? 1 + std::count(buffer.begin(), buffer.end(), '\n') : 0;
			handler(document, lineCount);
		});
	});
}

- (void)saveDocument:(OakDocument*)document completionHandler:(void(^)(BOOL, NSString*))handler
{
	[document saveModalForWindow:nil completionHandler:^(OakDocumentIOResult result, NSString* errorMessage, oak::uuid_t const& filterUUID){
		handler(result == OakDocumentIOResultSuccess, errorMessage);
	}];
}

- (id <AgentBridgeHostWindow>)controllerForDocument:(OakDocument*)document
{
	if(!document)
		return nil;
	for(id <AgentBridgeHostWindow> controller in HostControllers())
	{
		if([controller.documents indexOfObjectIdenticalTo:document] != NSNotFound)
			return controller;
	}
	return nil;
}

- (NSUUID*)projectIdentifierForDocument:(OakDocument*)document
{
	NSObject* controller = (NSObject*)[self controllerForDocument:document];
	if([controller respondsToSelector:@selector(identifier)])
	{
		id identifier = [controller valueForKey:@"identifier"];
		if([identifier isKindOfClass:[NSUUID class]])
			return identifier;
	}
	return nil;
}

- (void)focusTextViewForDocument:(OakDocument*)document
{
	id <AgentBridgeHostWindowExtras> controller = (id)[self controllerForDocument:document];
	if([controller respondsToSelector:@selector(makeTextViewFirstResponder:)])
		[controller makeTextViewFirstResponder:nil];
}

- (BOOL)closeTabForDocument:(OakDocument*)document
{
	id <AgentBridgeHostWindow> controller = [self controllerForDocument:document];
	NSUInteger index = [controller.documents indexOfObjectIdenticalTo:document];
	if(index == NSNotFound || ![(id)controller respondsToSelector:@selector(closeTabsAtIndexes:askToSaveChanges:createDocumentIfEmpty:activate:)])
		return NO;

	[(id <AgentBridgeHostWindowExtras>)controller closeTabsAtIndexes:[NSIndexSet indexSetWithIndex:index] askToSaveChanges:NO createDocumentIfEmpty:YES activate:YES];
	return YES;
}

// ===============
// = Diagnostics =
// ===============

- (NSDictionary<NSString*, NSArray<NSDictionary*>*>*)diagnosticsByURI
{
	return [LSPManager.sharedManager allDiagnosticsByURI];
}
@end
