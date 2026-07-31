#import "LSPDiagnosticsStore.h"
#import <document/OakDocument.h>
#import <io/path.h>
#import <ns/ns.h>

@interface LSPDiagnosticEntry ()
@property (nonatomic) NSUInteger line;
@property (nonatomic) NSUInteger column;
@property (nonatomic) NSInteger severity;
@property (nonatomic) NSString* message;
@property (nonatomic) NSString* source;
@property (nonatomic) NSString* code;
@end

@implementation LSPDiagnosticEntry
@end

@interface LSPDiagnosticFileGroup ()
@property (nonatomic) NSString* path;
@property (nonatomic) NSString* displayPath;
@property (nonatomic) NSArray<LSPDiagnosticEntry*>* entries;
@property (nonatomic) NSUInteger errorCount;
@property (nonatomic) NSUInteger warningCount;
@property (nonatomic) NSUInteger noteCount;
@end

@implementation LSPDiagnosticFileGroup
@end

@interface LSPDiagnosticsSnapshot ()
@property (nonatomic) NSArray<LSPDiagnosticFileGroup*>* fileGroups;
@property (nonatomic) NSUInteger errorCount;
@property (nonatomic) NSUInteger warningCount;
@property (nonatomic) NSUInteger noteCount;
@property (nonatomic) NSString* revision;
@end

@implementation LSPDiagnosticsSnapshot
@end

// Symlinks are why this resolves rather than normalizes. The two sides come
// from different places — the client root from walking up the document path,
// the window root from the project — so a project reached through a symlink on
// one side and its real path on the other would compare as unrelated, and the
// panel would then say “No diagnostics reported.”, which is the one wrong answer a
// survey surface must never give silently.
static std::string ResolvedPath (NSString* path)
{
	return path.length ? path::resolve(path::normalize(to_s(path))) : std::string();
}

// Two directories are related when one contains the other. A window opened on
// a project folder matches its server’s root outright; a window opened on a
// single file matches by sitting inside it.
static BOOL PathsAreRelated (std::string const& lhs, std::string const& rhs)
{
	if(lhs.empty() || rhs.empty())
		return NO;
	return lhs == rhs || path::is_child(lhs, rhs) || path::is_child(rhs, lhs);
}

// Workspace-relative when one of the window’s roots contains the file (the
// deepest one, so a nested root reads as the shorter path it is), otherwise
// the abbreviated absolute path — a server may publish outside every root.
// The file path is resolved here for the same reason the roots are — the
// comparison has to survive a symlinked project — while `path` itself stays the
// one the server named, since that is what a row opens.
static NSString* DisplayPathForPath (NSString* path, std::vector<std::string> const& resolvedRoots)
{
	std::string const filePath = ResolvedPath(path);

	std::string best;
	for(auto const& candidate : resolvedRoots)
	{
		if(path::is_child(filePath, candidate) && candidate.size() > best.size())
			best = candidate;
	}

	if(best.empty())
		return [path stringByAbbreviatingWithTildeInPath];
	return to_ns(path::relative_to(filePath, best));
}

static LSPDiagnosticEntry* EntryFromDictionary (NSDictionary* diagnostic)
{
	NSNumber* line = diagnostic[@"line"];
	if(!line)
		return nil;

	LSPDiagnosticEntry* entry = [LSPDiagnosticEntry new];
	entry.line     = line.unsignedIntegerValue;
	entry.column   = [diagnostic[@"character"] unsignedIntegerValue];
	entry.severity = OakDiagnosticSeverityClass(diagnostic[@"severity"]);
	entry.message  = diagnostic[@"message"] ?: @"";

	if([diagnostic[@"source"] isKindOfClass:[NSString class]])
		entry.source = diagnostic[@"source"];

	id code = diagnostic[@"code"];
	if([code isKindOfClass:[NSString class]] || [code isKindOfClass:[NSNumber class]])
		entry.code = [code description];

	return entry;
}

// Line, then column, then severity, then message: stable across re-publishes,
// so a burst that changes one diagnostic does not reshuffle the list around it.
static NSComparisonResult CompareEntries (LSPDiagnosticEntry* lhs, LSPDiagnosticEntry* rhs)
{
	if(lhs.line != rhs.line)
		return lhs.line < rhs.line ? NSOrderedAscending : NSOrderedDescending;
	if(lhs.column != rhs.column)
		return lhs.column < rhs.column ? NSOrderedAscending : NSOrderedDescending;
	if(lhs.severity != rhs.severity)
		return lhs.severity < rhs.severity ? NSOrderedAscending : NSOrderedDescending;
	return [lhs.message compare:rhs.message];
}

@implementation LSPDiagnosticsStore
{
	// clientKey → (URI → the diagnostics that client last published for it)
	NSMutableDictionary<NSString*, NSMutableDictionary<NSString*, NSArray<NSDictionary*>*>*>* _byClientKey;
	// clientKey → workspace root, which is what window scoping filters on. Kept
	// beside the entries rather than parsed back out of the composite key.
	NSMutableDictionary<NSString*, NSString*>* _rootByClientKey;

	// Bumped only when a mutation actually changes something, and kept per
	// client so a revision can be built from the clients a reader can see.
	// Servers re-publish identical diagnostics constantly, and a reader that
	// rebuilds on every publish rebuilds forever on an idle project.
	//
	// Entries outlive their client deliberately: the key is a per-process UUID
	// in production, but a key that did come back would otherwise restart at a
	// version it has already used.
	NSMutableDictionary<NSString*, NSNumber*>* _versionByClientKey;
}

- (void)bumpVersionForClientKey:(NSString*)clientKey
{
	_versionByClientKey[clientKey] = @(_versionByClientKey[clientKey].unsignedIntegerValue + 1);
}

- (instancetype)init
{
	if(self = [super init])
	{
		_byClientKey        = [NSMutableDictionary new];
		_rootByClientKey    = [NSMutableDictionary new];
		_versionByClientKey = [NSMutableDictionary new];
	}
	return self;
}

// Drop a client's entry for one URI, and the client itself once it holds
// nothing — the root record goes with it, so no stale scoping survives.
- (BOOL)removeURI:(NSString*)uri fromClientKey:(NSString*)clientKey
{
	if(!_byClientKey[clientKey][uri])
		return NO;

	[_byClientKey[clientKey] removeObjectForKey:uri];
	if(!_byClientKey[clientKey].count)
	{
		[_byClientKey removeObjectForKey:clientKey];
		[_rootByClientKey removeObjectForKey:clientKey];
	}
	return YES;
}

- (void)setDiagnostics:(NSArray<NSDictionary*>*)diagnostics forURI:(NSString*)uri clientKey:(NSString*)clientKey workspaceRoot:(NSString*)workspaceRoot
{
	if(!uri.length || !clientKey.length)
		return;

	if(!diagnostics.count)
	{
		if([self removeURI:uri fromClientKey:clientKey])
			[self bumpVersionForClientKey:clientKey];
		return;
	}

	NSArray<NSDictionary*>* existing = _byClientKey[clientKey][uri];
	NSString* existingRoot = _rootByClientKey[clientKey];

	NSMutableDictionary* entries = _byClientKey[clientKey];
	if(!entries)
		entries = _byClientKey[clientKey] = [NSMutableDictionary new];
	entries[uri] = [diagnostics copy];

	if(workspaceRoot.length)
		_rootByClientKey[clientKey] = workspaceRoot;

	if(![existing isEqualToArray:diagnostics] || (workspaceRoot.length && ![existingRoot isEqualToString:workspaceRoot]))
		[self bumpVersionForClientKey:clientKey];
}

- (NSArray<NSString*>*)removeDiagnosticsForClientKey:(NSString*)clientKey
{
	if(!clientKey.length || !_byClientKey[clientKey])
		return @[];

	NSArray<NSString*>* removed = _byClientKey[clientKey].allKeys;
	[_byClientKey removeObjectForKey:clientKey];
	[_rootByClientKey removeObjectForKey:clientKey];
	[self bumpVersionForClientKey:clientKey];
	return removed;
}

- (void)removeDiagnosticsForURI:(NSString*)uri
{
	if(!uri.length)
		return;

	for(NSString* clientKey in _byClientKey.allKeys)
	{
		if([self removeURI:uri fromClientKey:clientKey])
			[self bumpVersionForClientKey:clientKey];
	}
}

- (NSArray<NSDictionary*>*)diagnosticsForURI:(NSString*)uri
{
	if(!uri.length)
		return @[];

	NSMutableArray<NSDictionary*>* result = [NSMutableArray new];
	for(NSString* clientKey in [_byClientKey.allKeys sortedArrayUsingSelector:@selector(compare:)])
	{
		if(NSArray<NSDictionary*>* diagnostics = _byClientKey[clientKey][uri])
			[result addObjectsFromArray:diagnostics];
	}
	return result;
}

- (NSDictionary<NSString*, NSArray<NSDictionary*>*>*)allDiagnosticsByURI
{
	NSMutableDictionary<NSString*, NSMutableArray<NSDictionary*>*>* result = [NSMutableDictionary new];
	for(NSString* clientKey in [_byClientKey.allKeys sortedArrayUsingSelector:@selector(compare:)])
	{
		[_byClientKey[clientKey] enumerateKeysAndObjectsUsingBlock:^(NSString* uri, NSArray<NSDictionary*>* diagnostics, BOOL*){
			NSMutableArray* merged = result[uri];
			if(!merged)
				merged = result[uri] = [NSMutableArray new];
			[merged addObjectsFromArray:diagnostics];
		}];
	}
	return result;
}

static std::vector<std::string> ResolvedRoots (NSArray<NSString*>* roots)
{
	std::vector<std::string> res;
	for(NSString* root in roots)
	{
		if(std::string resolved = ResolvedPath(root); !resolved.empty())
			res.push_back(resolved);
	}
	return res;
}

// No roots means no filtering. A client whose root was never recorded fails
// closed: it belongs to no scoped reader rather than to all of them.
- (BOOL)clientKey:(NSString*)clientKey isInScope:(std::vector<std::string> const&)resolvedRoots
{
	if(resolvedRoots.empty())
		return YES;

	std::string const clientRoot = ResolvedPath(_rootByClientKey[clientKey]);
	for(auto const& root : resolvedRoots)
	{
		if(PathsAreRelated(clientRoot, root))
			return YES;
	}
	return NO;
}

// Scope and contents together: two snapshots with the same revision describe
// the same rows.
//
// Built from the in-scope clients' own versions rather than a store-wide
// counter, so a server publishing in one workspace cannot invalidate a panel
// showing another. Every window gets the change notification, so a store-wide
// counter would have made every other window rebuild, sort and re-measure its
// whole list for a change it cannot even see. The roots are part of it too:
// the same clients seen from a different root produce different display paths.
- (NSString*)revisionForWorkspaceRoots:(NSArray<NSString*>*)roots
{
	std::vector<std::string> const resolvedRoots = ResolvedRoots(roots);

	NSMutableArray<NSString*>* parts = [NSMutableArray new];
	[parts addObject:[(roots ?: @[]) componentsJoinedByString:@"\n"]];

	for(NSString* clientKey in [_byClientKey.allKeys sortedArrayUsingSelector:@selector(compare:)])
	{
		if([self clientKey:clientKey isInScope:resolvedRoots])
			[parts addObject:[NSString stringWithFormat:@"%@=%@", clientKey, _versionByClientKey[clientKey]]];
	}

	return [parts componentsJoinedByString:@"\n"];
}

- (LSPDiagnosticsSnapshot*)snapshotForWorkspaceRoots:(NSArray<NSString*>*)roots
{
	std::vector<std::string> const resolvedRoots = ResolvedRoots(roots);

	// URI → the dictionaries every in-scope client published for it, so the
	// same file served by two servers is one group rather than two.
	NSMutableDictionary<NSString*, NSMutableArray<NSDictionary*>*>* byURI = [NSMutableDictionary new];
	for(NSString* clientKey in [_byClientKey.allKeys sortedArrayUsingSelector:@selector(compare:)])
	{
		if(![self clientKey:clientKey isInScope:resolvedRoots])
			continue;

		[_byClientKey[clientKey] enumerateKeysAndObjectsUsingBlock:^(NSString* uri, NSArray<NSDictionary*>* diagnostics, BOOL*){
			NSMutableArray* merged = byURI[uri];
			if(!merged)
				merged = byURI[uri] = [NSMutableArray new];
			[merged addObjectsFromArray:diagnostics];
		}];
	}

	NSMutableArray<LSPDiagnosticFileGroup*>* groups = [NSMutableArray new];
	NSUInteger errors = 0, warnings = 0, notes = 0;

	for(NSString* uri in byURI)
	{
		NSString* path = [NSURL URLWithString:uri].path;
		if(!path)
			continue;

		NSMutableArray<LSPDiagnosticEntry*>* entries = [NSMutableArray new];
		LSPDiagnosticFileGroup* group = [LSPDiagnosticFileGroup new];

		for(NSDictionary* diagnostic in byURI[uri])
		{
			LSPDiagnosticEntry* entry = EntryFromDictionary(diagnostic);
			if(!entry)
				continue;

			[entries addObject:entry];
			switch(entry.severity)
			{
				case 1:  group.errorCount   += 1; errors   += 1; break;
				case 2:  group.warningCount += 1; warnings += 1; break;
				default: group.noteCount    += 1; notes    += 1; break;
			}
		}

		if(!entries.count)
			continue;

		[entries sortUsingComparator:^NSComparisonResult(LSPDiagnosticEntry* lhs, LSPDiagnosticEntry* rhs){
			return CompareEntries(lhs, rhs);
		}];

		group.path        = path;
		group.displayPath = DisplayPathForPath(path, resolvedRoots);
		group.entries     = [entries copy];
		[groups addObject:group];
	}

	[groups sortUsingComparator:^NSComparisonResult(LSPDiagnosticFileGroup* lhs, LSPDiagnosticFileGroup* rhs){
		NSComparisonResult res = [lhs.displayPath localizedStandardCompare:rhs.displayPath];
		return res != NSOrderedSame ? res : [lhs.path compare:rhs.path];
	}];

	LSPDiagnosticsSnapshot* snapshot = [LSPDiagnosticsSnapshot new];
	snapshot.fileGroups   = [groups copy]; // the header promises immutable; make it structural
	snapshot.errorCount   = errors;
	snapshot.warningCount = warnings;
	snapshot.noteCount    = notes;
	snapshot.revision     = [self revisionForWorkspaceRoots:roots];
	return snapshot;
}
@end
