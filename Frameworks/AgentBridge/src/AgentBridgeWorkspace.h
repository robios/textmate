#ifndef AGENT_BRIDGE_WORKSPACE_H_MV82RKD4
#define AGENT_BRIDGE_WORKSPACE_H_MV82RKD4

#import <Cocoa/Cocoa.h>

@class OakDocument;

// Plain data snapshot of an editor selection (0-based line/character).
@interface AgentBridgeSelection : NSObject
@property (nonatomic) NSString*  filePath; // nil for untitled documents
@property (nonatomic) NSString*  text;
@property (nonatomic) NSUInteger startLine;
@property (nonatomic) NSUInteger startCharacter;
@property (nonatomic) NSUInteger endLine;
@property (nonatomic) NSUInteger endCharacter;
@property (nonatomic, getter = isEmpty) BOOL empty;
@end

// Protocol-agnostic access to the app's windows, documents, selection and
// diagnostics. This layer knows nothing about WebSockets or JSON-RPC — the
// server (adapter) translates between it and the wire protocol. It is the
// one shared context source: Claude's WebSocket MCP frontend, Codex's native
// IDE-context frontend, and the stdio MCP shim for other providers all answer
// out of here.
@interface AgentBridgeWorkspace : NSObject
// originProjectPath is the project the selection was observed in (nil for a
// window with no project), captured with the selection itself: a push is
// addressed to the agent sessions working on that project, and by the time it
// is delivered the frontmost window may be another one.
@property (nonatomic, copy) void(^selectionDidChangeHandler)(AgentBridgeSelection* selection, NSString* originProjectPath);
@property (nonatomic, copy) void(^workspaceFoldersDidChangeHandler)(NSArray<NSString*>* folders);

// Every context query takes a ‘routing path’: the working directory the asking
// agent process was started in (§4.2). The window whose project root contains
// it answers — without this a second TextMate window on an unrelated project
// could answer a query meant for this one. Claude's WebSocket frontend finds
// TextMate through the lock file rather than a cwd, so it derives one per
// connection from the pid in ide_connected. nil, empty, or a path inside no
// open project falls back to the frontmost window, which is the answer every
// frontend used to get; the nil-routing methods below are that case spelled
// out. Pushes must not take that fallback — see agent_ide_routing.h.
- (NSArray<NSString*>*)workspaceFolders; // aggregated project roots of all document windows, frontmost first
- (NSString*)activeProjectPath;
- (NSString*)projectPathForRoutingPath:(NSString*)routingPath; // the answering window’s project root
- (BOOL)canRouteIDEContextForWorkspaceRoot:(NSString*)workspaceRoot; // YES only when this root is inside an open project
- (NSArray<NSDictionary*>*)openEditors;  // path, isActive, label, languageId, isDirty
- (NSArray<NSDictionary*>*)openEditorsForRoutingPath:(NSString*)routingPath; // same list; isActive follows the answering window
- (NSArray<NSDictionary*>*)openEditorsInAnsweringWindowForRoutingPath:(NSString*)routingPath; // same shape, but excludes unrelated project windows
- (AgentBridgeSelection*)currentSelection;
- (AgentBridgeSelection*)currentSelectionForRoutingPath:(NSString*)routingPath;
// Last non-empty selection made in the project that answers for routingPath,
// nil when that project has none of its own — never another project’s, which
// is the one place the fallback above must not apply. A caller that cannot be
// placed keeps the app-wide last selection, the answer everyone used to get.
// A project’s history is discarded when its last window closes, since nothing
// can be routed to a project that is not open.
- (AgentBridgeSelection*)latestSelectionForRoutingPath:(NSString*)routingPath;

- (NSString*)absolutePathForPath:(NSString*)path;
- (NSString*)absolutePathForPath:(NSString*)path routingPath:(NSString*)routingPath; // relative paths resolve against the answering project
- (OakDocument*)openDocumentAtPath:(NSString*)path;
- (OakDocument*)openDocumentAtPath:(NSString*)path routingPath:(NSString*)routingPath;
- (void)openFileAtPath:(NSString*)path selectFromText:(NSString*)startText toText:(NSString*)endText selectToEndOfLine:(BOOL)selectToEndOfLine makeFrontmost:(BOOL)makeFrontmost routingPath:(NSString*)routingPath completionHandler:(void(^)(OakDocument* document, NSUInteger lineCount))handler;
- (void)saveDocument:(OakDocument*)document completionHandler:(void(^)(BOOL saved, NSString* message))handler;
- (void)focusTextViewForDocument:(OakDocument*)document; // make the document's window's text view first responder
- (BOOL)closeTabForDocument:(OakDocument*)document;      // close the document's tab without a save prompt
- (NSUUID*)projectIdentifierForDocument:(OakDocument*)document; // identifier of the window (project) showing the document

- (NSDictionary<NSString*, NSArray<NSDictionary*>*>*)diagnosticsByURI; // raw LSP diagnostic entries per file URI
@end

#endif /* AGENT_BRIDGE_WORKSPACE_H_MV82RKD4 */
