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
// server (adapter) translates between it and the wire protocol, and WP2's
// ProposalSession will sit on this side of the boundary.
@interface AgentBridgeWorkspace : NSObject
@property (nonatomic, copy) void(^selectionDidChangeHandler)(AgentBridgeSelection* selection);
@property (nonatomic, copy) void(^workspaceFoldersDidChangeHandler)(NSArray<NSString*>* folders);

@property (nonatomic, readonly) AgentBridgeSelection* latestSelection; // last non-empty selection

- (NSArray<NSString*>*)workspaceFolders; // aggregated project roots of all document windows, frontmost first
- (NSString*)activeProjectPath;
- (NSArray<NSDictionary*>*)openEditors;  // path, isActive, label, languageId, isDirty
- (AgentBridgeSelection*)currentSelection;

- (NSString*)absolutePathForPath:(NSString*)path;
- (OakDocument*)openDocumentAtPath:(NSString*)path;
- (void)openFileAtPath:(NSString*)path selectFromText:(NSString*)startText toText:(NSString*)endText selectToEndOfLine:(BOOL)selectToEndOfLine makeFrontmost:(BOOL)makeFrontmost completionHandler:(void(^)(OakDocument* document, NSUInteger lineCount))handler;
- (void)saveDocument:(OakDocument*)document completionHandler:(void(^)(BOOL saved, NSString* message))handler;

- (NSDictionary<NSString*, NSArray<NSDictionary*>*>*)diagnosticsByURI; // raw LSP diagnostic entries per file URI
@end

#endif /* AGENT_BRIDGE_WORKSPACE_H_MV82RKD4 */
