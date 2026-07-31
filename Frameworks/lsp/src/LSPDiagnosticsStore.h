#ifndef LSP_DIAGNOSTICS_STORE_H_PANEL
#define LSP_DIAGNOSTICS_STORE_H_PANEL

#import <Foundation/Foundation.h>

// One diagnostic as a reading surface wants it: the protocol dictionary’s
// fields normalized once — severity through OakDiagnosticSeverityClass, so no
// surface can re-derive a different class than the buffer stores.
@interface LSPDiagnosticEntry : NSObject
@property (nonatomic, readonly) NSUInteger line;      // 0-based
@property (nonatomic, readonly) NSUInteger column;    // 0-based, UTF-16 code units
@property (nonatomic, readonly) NSInteger severity;   // 1 error, 2 warning, 3 note
@property (nonatomic, readonly) NSString* message;
@property (nonatomic, readonly) NSString* source;     // may be nil
@property (nonatomic, readonly) NSString* code;       // may be nil
@end

// Every diagnostic for one file, in reading order.
@interface LSPDiagnosticFileGroup : NSObject
@property (nonatomic, readonly) NSString* path;         // absolute
@property (nonatomic, readonly) NSString* displayPath;  // relative to the window root that contains it
@property (nonatomic, readonly) NSArray<LSPDiagnosticEntry*>* entries;
@property (nonatomic, readonly) NSUInteger errorCount;
@property (nonatomic, readonly) NSUInteger warningCount;
@property (nonatomic, readonly) NSUInteger noteCount;
@end

// An immutable cross-file view of what the live servers have published,
// already grouped, sorted and counted. The panel derives its row model from
// this and keeps no second source of truth.
@interface LSPDiagnosticsSnapshot : NSObject
@property (nonatomic, readonly) NSArray<LSPDiagnosticFileGroup*>* fileGroups;
@property (nonatomic, readonly) NSUInteger errorCount;
@property (nonatomic, readonly) NSUInteger warningCount;
@property (nonatomic, readonly) NSUInteger noteCount;

// Equal revisions mean equal contents for equal scope. Servers re-publish
// unchanged diagnostics constantly, so this is what keeps an idle project from
// rebuilding and re-measuring a whole list several times a second.
@property (nonatomic, readonly) NSString* revision;
@end

// The manager’s diagnostics cache, keyed by publishing client and then URI.
//
// Ownership is what makes the cross-file panel possible: a workspace server
// publishes for files the user never opened, so a URI outlives the editor that
// showed it, and only the client that published an entry may remove it. Two
// clients can hold the same URI (a C file served by clangd and a linter, say)
// and each keeps its own.
//
// Deliberately unlocked, so an instance must not be touched from two threads at
// once. The manager's instance is main-thread-only in particular: every
// mutation happens inside an LSPManager delegate callback, and LSPClient
// delivers those onto the main queue before they are handled; snapshot reads
// come from the main thread too. The affinity is the owner's, not the store's —
// which is why the assertion belongs at that boundary if it is ever wanted.
@interface LSPDiagnosticsStore : NSObject

// Replace one client’s entry for one URI. An empty array removes it — a clean
// file is the absence of an entry, not an entry with nothing in it, so the
// panel never lists a file with zero diagnostics.
- (void)setDiagnostics:(NSArray<NSDictionary*>*)diagnostics forURI:(NSString*)uri clientKey:(NSString*)clientKey workspaceRoot:(NSString*)workspaceRoot;

// Everything this client published. Termination and restart both go through
// here: a dead server has no publisher left to retract what it said. Returns
// the URIs that were removed — the caller has to bring those documents back in
// line, and it cannot work that out from its own registrations, since a
// workspace server publishes for files no editor is attached to.
- (NSArray<NSString*>*)removeDiagnosticsForClientKey:(NSString*)clientKey;

// This URI from every client — the document left its servers behind (grammar
// switch), so nobody’s entry for it still applies.
- (void)removeDiagnosticsForURI:(NSString*)uri;

// Merged across clients, in stable client-key order. This is what the
// document-facing paths (apply, code actions, counts) read.
- (NSArray<NSDictionary*>*)diagnosticsForURI:(NSString*)uri;
- (NSDictionary<NSString*, NSArray<NSDictionary*>*>*)allDiagnosticsByURI;

// Diagnostics owned by clients whose workspace root is related to one of
// `roots` — equal to, inside, or containing it. Containing counts because a
// window opened on a single file sits inside the workspace its server serves.
// An empty or nil `roots` means no filtering.
- (LSPDiagnosticsSnapshot*)snapshotForWorkspaceRoots:(NSArray<NSString*>*)roots;

// What the snapshot for those roots would carry as its revision, without
// building it. Lets a caller skip the grouping and sorting entirely when
// nothing has changed since it last asked.
- (NSString*)revisionForWorkspaceRoots:(NSArray<NSString*>*)roots;
@end

#endif /* LSP_DIAGNOSTICS_STORE_H_PANEL */
