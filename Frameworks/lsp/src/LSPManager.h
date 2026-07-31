#ifndef LSP_MANAGER_H_POC
#define LSP_MANAGER_H_POC

#import <document/OakDocument.h>
#import "LSPDiagnosticsStore.h"

extern NSString* const LSPDiagnosticsDidChangeNotification;
extern NSString* const LSPServerStatusDidChangeNotification;

@interface LSPManager : NSObject
+ (instancetype)sharedManager;
- (void)documentDidOpen:(OakDocument*)document;
- (void)documentDidChange:(OakDocument*)document;
- (void)documentDidChangeFileType:(OakDocument*)document;
- (void)documentDidSave:(OakDocument*)document;
- (void)documentWillClose:(OakDocument*)document;
- (void)shutdownAll;
- (void)flushPendingChangesForDocument:(OakDocument*)document;
- (void)requestCompletionsForDocument:(OakDocument*)document line:(NSUInteger)line character:(NSUInteger)character prefix:(NSString*)prefix completion:(void(^)(NSArray<NSDictionary*>*))callback;
- (void)requestDefinitionForDocument:(OakDocument*)document line:(NSUInteger)line character:(NSUInteger)character completion:(void(^)(NSArray<NSDictionary*>*))callback;
- (int)requestHoverForDocument:(OakDocument*)document line:(NSUInteger)line character:(NSUInteger)character completion:(void(^)(NSDictionary*))callback;
- (void)cancelRequest:(int)requestId forDocument:(OakDocument*)document;
- (void)requestReferencesForDocument:(OakDocument*)document line:(NSUInteger)line character:(NSUInteger)character completion:(void(^)(NSArray<NSDictionary*>*))callback;
- (void)requestFormattingForDocument:(OakDocument*)document tabSize:(NSUInteger)tabSize insertSpaces:(BOOL)insertSpaces completion:(void(^)(NSArray<NSDictionary*>*))callback;
- (void)requestRangeFormattingForDocument:(OakDocument*)document startLine:(NSUInteger)startLine startCharacter:(NSUInteger)startCharacter endLine:(NSUInteger)endLine endCharacter:(NSUInteger)endCharacter tabSize:(NSUInteger)tabSize insertSpaces:(BOOL)insertSpaces completion:(void(^)(NSArray<NSDictionary*>*))callback;
- (void)resolveCompletionItem:(NSDictionary*)item forDocument:(OakDocument*)document completion:(void(^)(NSDictionary*))callback;
- (BOOL)serverSupportsCompletionResolveForDocument:(OakDocument*)document;
- (BOOL)serverSupportsFormattingForDocument:(OakDocument*)document;
- (BOOL)serverSupportsRangeFormattingForDocument:(OakDocument*)document;
- (BOOL)serverSupportsRenameForDocument:(OakDocument*)document;
- (NSArray<NSDictionary*>*)diagnosticsForDocument:(OakDocument*)document atLine:(NSUInteger)line character:(NSUInteger)character endLine:(NSUInteger)endLine endCharacter:(NSUInteger)endCharacter;
- (NSDictionary<NSString*, NSArray<NSDictionary*>*>*)allDiagnosticsByURI;

// Everything the live clients serving these workspace roots have published,
// grouped by file — the cross-file panel’s source. Immutable; ask again after
// LSPDiagnosticsDidChangeNotification rather than holding on to it.
- (LSPDiagnosticsSnapshot*)diagnosticsSnapshotForWorkspaceRoots:(NSArray<NSString*>*)roots;

// The revision that snapshot would carry, without building it — ask this first
// and skip the snapshot entirely when it matches what you already show.
- (NSString*)diagnosticsRevisionForWorkspaceRoots:(NSArray<NSString*>*)roots;
- (void)requestPrepareRenameForDocument:(OakDocument*)document line:(NSUInteger)line character:(NSUInteger)character completion:(void(^)(NSDictionary*))callback;
- (void)requestRenameForDocument:(OakDocument*)document line:(NSUInteger)line character:(NSUInteger)character newName:(NSString*)newName completion:(void(^)(NSDictionary*))callback;
- (BOOL)serverSupportsCodeActionsForDocument:(OakDocument*)document;
- (BOOL)serverSupportsCodeActionResolveForDocument:(OakDocument*)document;
- (void)requestCodeActionsForDocument:(OakDocument*)document line:(NSUInteger)line character:(NSUInteger)character endLine:(NSUInteger)endLine endCharacter:(NSUInteger)endCharacter completion:(void(^)(NSArray<NSDictionary*>*))callback;
- (void)resolveCodeAction:(NSDictionary*)codeAction forDocument:(OakDocument*)document completion:(void(^)(NSDictionary*))callback;
- (void)executeCommand:(NSString*)command arguments:(NSArray*)arguments forDocument:(OakDocument*)document completion:(void(^)(id))callback;
- (BOOL)hasClientForDocument:(OakDocument*)document;
- (NSDictionary<NSString*, NSNumber*>*)diagnosticCountsForDocument:(OakDocument*)document;
- (NSString*)serverStatusForDocument:(OakDocument*)document;
- (NSString*)serverNameForDocument:(OakDocument*)document;
- (void)restartServerForDocument:(OakDocument*)document;
- (void)reindexWorkspaceForDocument:(OakDocument*)document;

// Effective lspEnabled for the document (.tm_properties layers plus bundle
// defaults, default true) — what clientForDocument uses to gate connections.
- (BOOL)lspEnabledForDocument:(OakDocument*)document;

// Stop the client serving this document without restarting it; affected
// documents reconnect lazily (documentDidOpen: on focus) once permitted again.
- (void)stopServerForDocument:(OakDocument*)document;
@end

#endif /* LSP_MANAGER_H_POC */
