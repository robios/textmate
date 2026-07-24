#import "AgentBridgeWorkspace.h"
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

static id <AgentBridgeHostWindow> HostControllerForWindow (NSWindow* window)
{
	id delegate = window.delegate;
	if([delegate respondsToSelector:@selector(projectPath)] && [delegate respondsToSelector:@selector(documents)] && [delegate respondsToSelector:@selector(selectedDocument)])
		return delegate;
	return nil;
}

// Front-to-back list of document window controllers. [NSApp orderedWindows]
// provides the ordering but excludes miniaturized windows, so sweep
// NSApp.windows afterwards — a minimized project must not drop out of the
// lock file or getOpenEditors.
static NSArray<id <AgentBridgeHostWindow>>* HostControllers ()
{
	NSMutableArray* res = [NSMutableArray array];
	for(NSArray<NSWindow*>* windows in @[ [NSApp orderedWindows], NSApp.windows ])
	{
		for(NSWindow* window in windows)
		{
			id <AgentBridgeHostWindow> controller = HostControllerForWindow(window);
			if(controller && [res indexOfObjectIdenticalTo:controller] == NSNotFound)
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
	NSMutableArray<NSDictionary*>* res = [NSMutableArray array];
	id <AgentBridgeHostWindow> activeController = [self activeController];
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

// =============
// = Selection =
// =============

- (AgentBridgeSelection*)currentSelection
{
	id <AgentBridgeHostWindow> controller = [self activeController];
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
		[textView addObserver:self forKeyPath:@"selectionString" options:0 context:kAgentBridgeSelectionObserverContext];
		_observedTextView = textView;
		_observedWindow   = window;
		[self noteSelectionMayHaveChanged];
	}
}

- (void)unbindSelectionObservation
{
	[_observedTextView removeObserver:self forKeyPath:@"selectionString" context:kAgentBridgeSelectionObserverContext];
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
	path = path.stringByExpandingTildeInPath;
	if(!path.isAbsolutePath)
	{
		NSString* root = [self activeProjectPath] ?: NSHomeDirectory();
		path = [root stringByAppendingPathComponent:path];
	}
	return to_ns(path::normalize(to_s(path)));
}

- (OakDocument*)openDocumentAtPath:(NSString*)path
{
	NSString* standardized = [self absolutePathForPath:path];
	for(OakDocument* document in [OakDocumentController.sharedInstance openDocuments])
	{
		if(document.path && [document.path isEqualToString:standardized])
			return document;
	}
	return nil;
}

- (void)openFileAtPath:(NSString*)path selectFromText:(NSString*)startText toText:(NSString*)endText selectToEndOfLine:(BOOL)selectToEndOfLine makeFrontmost:(BOOL)makeFrontmost completionHandler:(void(^)(OakDocument*, NSUInteger))handler
{
	NSString* absolutePath = [self absolutePathForPath:path];

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
			[OakDocumentController.sharedInstance showDocument:document andSelect:range inProject:nil bringToFront:makeFrontmost];

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

// ===============
// = Diagnostics =
// ===============

- (NSDictionary<NSString*, NSArray<NSDictionary*>*>*)diagnosticsByURI
{
	return [LSPManager.sharedManager allDiagnosticsByURI];
}
@end
