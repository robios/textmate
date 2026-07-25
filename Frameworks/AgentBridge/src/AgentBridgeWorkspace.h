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
@property (nonatomic, copy) void(^selectionDidChangeHandler)(AgentBridgeSelection* selection);
@property (nonatomic, copy) void(^workspaceFoldersDidChangeHandler)(NSArray<NSString*>* folders);

@property (nonatomic, readonly) AgentBridgeSelection* latestSelection; // last non-empty selection

// Every context query takes a ‘routing path’: the working directory the asking
// agent process was started in (§4.2). The window whose project root contains
// it answers — without this a second TextMate window on an unrelated project
// could answer a query meant for this one. nil, empty, or a path inside no
// open project falls back to the frontmost window, which is what the WebSocket
// frontend (Claude, discovered through the lock file rather than a cwd) has
// always used; the nil-routing methods below are that case spelled out.
- (NSArray<NSString*>*)workspaceFolders; // aggregated project roots of all document windows, frontmost first
- (NSString*)activeProjectPath;
- (NSString*)projectPathForRoutingPath:(NSString*)routingPath; // the answering window’s project root
- (BOOL)canRouteIDEContextForWorkspaceRoot:(NSString*)workspaceRoot; // YES only when this root is inside an open project
- (NSArray<NSDictionary*>*)openEditors;  // path, isActive, label, languageId, isDirty
- (NSArray<NSDictionary*>*)openEditorsForRoutingPath:(NSString*)routingPath; // same list; isActive follows the answering window
- (NSArray<NSDictionary*>*)openEditorsInAnsweringWindowForRoutingPath:(NSString*)routingPath; // same shape, but excludes unrelated project windows
- (AgentBridgeSelection*)currentSelection;
- (AgentBridgeSelection*)currentSelectionForRoutingPath:(NSString*)routingPath;

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
