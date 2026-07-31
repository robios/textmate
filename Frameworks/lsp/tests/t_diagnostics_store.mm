#import <lsp/LSPDiagnosticsStore.h>
#import <ns/ns.h>

static NSDictionary* diag (NSUInteger line, NSUInteger character = 0, NSInteger severity = 1, NSString* message = @"boom", NSString* source = nil, id code = nil)
{
	NSMutableDictionary* res = [@{
		@"line":         @(line),
		@"character":    @(character),
		@"endLine":      @(line),
		@"endCharacter": @(character + 1),
		@"severity":     @(severity),
		@"message":      message,
	} mutableCopy];
	if(source)
		res[@"source"] = source;
	if(code)
		res[@"code"] = code;
	return res;
}

static NSString* uri (NSString* path)
{
	return [NSURL fileURLWithPath:path].absoluteString;
}

// Assertions read as std::string so a mismatch prints both sides; comparing
// NSString* directly would compare pointers.
static std::string str (NSString* aString)
{
	return aString ? to_s(aString) : std::string("(nil)");
}

static LSPDiagnosticFileGroup* group_for (LSPDiagnosticsSnapshot* snapshot, NSString* displayPath)
{
	for(LSPDiagnosticFileGroup* group in snapshot.fileGroups)
	{
		if([group.displayPath isEqualToString:displayPath])
			return group;
	}
	return nil;
}

// The panel is deliberately cross-file: a workspace server publishes for files
// nobody opened, and closing an editor does not retract what the server said.
void test_diagnostics_store_ownership ()
{
	LSPDiagnosticsStore* store = [LSPDiagnosticsStore new];

	[store setDiagnostics:@[ diag(1) ] forURI:uri(@"/proj/a.c")     clientKey:@"clangd" workspaceRoot:@"/proj"];
	[store setDiagnostics:@[ diag(2) ] forURI:uri(@"/proj/never.c") clientKey:@"clangd" workspaceRoot:@"/proj"];

	LSPDiagnosticsSnapshot* snapshot = [store snapshotForWorkspaceRoots:@[ @"/proj" ]];
	OAK_ASSERT_EQ(snapshot.fileGroups.count, 2);
	OAK_ASSERT_EQ(snapshot.errorCount, 2);

	// A second client holding the same URI keeps its own entry: replacing one
	// publisher's view must not drop the other's.
	[store setDiagnostics:@[ diag(3, 0, 2) ] forURI:uri(@"/proj/a.c") clientKey:@"linter" workspaceRoot:@"/proj"];
	OAK_ASSERT_EQ([store diagnosticsForURI:uri(@"/proj/a.c")].count, 2);

	[store setDiagnostics:@[ diag(9) ] forURI:uri(@"/proj/a.c") clientKey:@"clangd" workspaceRoot:@"/proj"];
	OAK_ASSERT_EQ([store diagnosticsForURI:uri(@"/proj/a.c")].count, 2);

	snapshot = [store snapshotForWorkspaceRoots:@[ @"/proj" ]];
	OAK_ASSERT_EQ(group_for(snapshot, @"a.c").entries.count, 2);
	OAK_ASSERT_EQ(group_for(snapshot, @"a.c").errorCount, 1);
	OAK_ASSERT_EQ(group_for(snapshot, @"a.c").warningCount, 1);

	// An empty publish is the absence of an entry, not an entry with nothing
	// in it — otherwise the panel lists a file with a zero count.
	[store setDiagnostics:@[] forURI:uri(@"/proj/a.c") clientKey:@"clangd" workspaceRoot:@"/proj"];
	OAK_ASSERT_EQ([store diagnosticsForURI:uri(@"/proj/a.c")].count, 1);
	[store setDiagnostics:@[] forURI:uri(@"/proj/a.c") clientKey:@"linter" workspaceRoot:@"/proj"];
	OAK_ASSERT_EQ([store diagnosticsForURI:uri(@"/proj/a.c")].count, 0);

	snapshot = [store snapshotForWorkspaceRoots:@[ @"/proj" ]];
	OAK_ASSERT_EQ(snapshot.fileGroups.count, 1); // never.c, which nobody opened
	OAK_ASSERT_EQ(str(snapshot.fileGroups[0].displayPath), std::string("never.c"));
}

// A dead server has no publisher left; a live one sharing the file keeps its own.
void test_diagnostics_store_client_purge ()
{
	LSPDiagnosticsStore* store = [LSPDiagnosticsStore new];

	[store setDiagnostics:@[ diag(1) ]       forURI:uri(@"/proj/a.c") clientKey:@"clangd" workspaceRoot:@"/proj"];
	[store setDiagnostics:@[ diag(2, 0, 2) ] forURI:uri(@"/proj/a.c") clientKey:@"linter" workspaceRoot:@"/proj"];
	[store setDiagnostics:@[ diag(3) ]       forURI:uri(@"/proj/b.c") clientKey:@"clangd" workspaceRoot:@"/proj"];

	[store removeDiagnosticsForClientKey:@"clangd"];
	OAK_ASSERT_EQ([store diagnosticsForURI:uri(@"/proj/a.c")].count, 1);
	OAK_ASSERT_EQ([store diagnosticsForURI:uri(@"/proj/b.c")].count, 0);

	LSPDiagnosticsSnapshot* snapshot = [store snapshotForWorkspaceRoots:@[ @"/proj" ]];
	OAK_ASSERT_EQ(snapshot.fileGroups.count, 1);
	OAK_ASSERT_EQ(snapshot.errorCount, 0);
	OAK_ASSERT_EQ(snapshot.warningCount, 1);

	// A restart re-registers under a fresh identity, so the successor's
	// diagnostics survive the predecessor's late termination callback.
	[store setDiagnostics:@[ diag(4) ] forURI:uri(@"/proj/b.c") clientKey:@"clangd-2" workspaceRoot:@"/proj"];
	[store removeDiagnosticsForClientKey:@"clangd"];
	OAK_ASSERT_EQ([store diagnosticsForURI:uri(@"/proj/b.c")].count, 1);

	// A grammar switch drops the file from every client at once.
	[store removeDiagnosticsForURI:uri(@"/proj/a.c")];
	OAK_ASSERT_EQ([store diagnosticsForURI:uri(@"/proj/a.c")].count, 0);
	OAK_ASSERT_EQ([store diagnosticsForURI:uri(@"/proj/b.c")].count, 1);
}

// Unrelated windows must not see each other's diagnostics; a window opened on a
// single file must still see the workspace server that serves it.
void test_diagnostics_store_window_scope ()
{
	LSPDiagnosticsStore* store = [LSPDiagnosticsStore new];

	[store setDiagnostics:@[ diag(1) ] forURI:uri(@"/proj/a.c")   clientKey:@"clangd" workspaceRoot:@"/proj"];
	[store setDiagnostics:@[ diag(1) ] forURI:uri(@"/other/z.py") clientKey:@"pyright" workspaceRoot:@"/other"];

	LSPDiagnosticsSnapshot* proj = [store snapshotForWorkspaceRoots:@[ @"/proj" ]];
	OAK_ASSERT_EQ(proj.fileGroups.count, 1);
	OAK_ASSERT_EQ(str(proj.fileGroups[0].displayPath), std::string("a.c"));
	OAK_ASSERT_EQ([store snapshotForWorkspaceRoots:@[ @"/other" ]].fileGroups.count, 1);

	NSArray* bothRoots = @[ @"/proj", @"/other" ];
	OAK_ASSERT_EQ([store snapshotForWorkspaceRoots:bothRoots].fileGroups.count, 2);

	// A window with no project root supplies the active document's parent; the
	// server's root contains it, so the workspace is in scope.
	OAK_ASSERT_EQ([store snapshotForWorkspaceRoots:@[ @"/proj/sub" ]].fileGroups.count, 1);

	// No roots at all means no filtering rather than nothing at all.
	OAK_ASSERT_EQ([store snapshotForWorkspaceRoots:@[]].fileGroups.count, 2);
	OAK_ASSERT_EQ([store snapshotForWorkspaceRoots:nil].fileGroups.count, 2);

	// An unrelated root sees neither.
	OAK_ASSERT_EQ([store snapshotForWorkspaceRoots:@[ @"/elsewhere" ]].fileGroups.count, 0);
}

// Grouping, ordering and counts have to be stable, because the panel rebuilds
// its whole row model on every publish burst.
void test_diagnostics_store_grouping ()
{
	LSPDiagnosticsStore* store = [LSPDiagnosticsStore new];

	NSArray* mixed = @[
		diag(7, 2, 2, @"later line"),
		diag(3, 9, 1, @"same line, later column"),
		diag(3, 1, 3, @"note first by column"),
		diag(3, 1, 1, @"error wins the severity tie", @"clang", @(42)),
	];
	[store setDiagnostics:mixed forURI:uri(@"/proj/src/b.c") clientKey:@"clangd" workspaceRoot:@"/proj"];
	[store setDiagnostics:@[ diag(0, 0, 3, @"note") ] forURI:uri(@"/proj/a.c") clientKey:@"clangd" workspaceRoot:@"/proj"];

	LSPDiagnosticsSnapshot* snapshot = [store snapshotForWorkspaceRoots:@[ @"/proj" ]];
	OAK_ASSERT_EQ(snapshot.fileGroups.count, 2);
	OAK_ASSERT_EQ(str(snapshot.fileGroups[0].displayPath), std::string("a.c"));
	OAK_ASSERT_EQ(str(snapshot.fileGroups[1].displayPath), std::string("src/b.c"));
	OAK_ASSERT_EQ(str(snapshot.fileGroups[1].path), std::string("/proj/src/b.c"));

	LSPDiagnosticFileGroup* group = snapshot.fileGroups[1];
	OAK_ASSERT_EQ(group.entries.count, 4);
	OAK_ASSERT_EQ(str(group.entries[0].message), std::string("error wins the severity tie"));
	OAK_ASSERT_EQ(str(group.entries[1].message), std::string("note first by column"));
	OAK_ASSERT_EQ(str(group.entries[2].message), std::string("same line, later column"));
	OAK_ASSERT_EQ(str(group.entries[3].message), std::string("later line"));

	OAK_ASSERT_EQ(group.entries[0].line, 3);
	OAK_ASSERT_EQ(group.entries[0].column, 1);
	OAK_ASSERT_EQ(str(group.entries[0].source), std::string("clang"));
	OAK_ASSERT_EQ(str(group.entries[0].code), std::string("42"));

	OAK_ASSERT_EQ(group.errorCount, 2);
	OAK_ASSERT_EQ(group.warningCount, 1);
	OAK_ASSERT_EQ(group.noteCount, 1);

	OAK_ASSERT_EQ(snapshot.errorCount, 2);
	OAK_ASSERT_EQ(snapshot.warningCount, 1);
	OAK_ASSERT_EQ(snapshot.noteCount, 2);

	// Severity normalizes exactly once, the way every other surface reads it:
	// 3, 4, an unknown number and a missing value are all notes.
	NSArray* odd = @[
		diag(0, 0, 4, @"info"),
		diag(1, 0, 99, @"nonsense"),
		@{ @"line": @2, @"character": @0, @"message": @"no severity" },
	];
	[store setDiagnostics:odd forURI:uri(@"/proj/a.c") clientKey:@"clangd" workspaceRoot:@"/proj"];
	OAK_ASSERT_EQ(group_for([store snapshotForWorkspaceRoots:@[ @"/proj" ]], @"a.c").noteCount, 3);
}

// A file outside every root still has to be readable — a server may publish for
// a header or a dependency the window's roots do not contain.
void test_diagnostics_store_display_path_outside_roots ()
{
	LSPDiagnosticsStore* store = [LSPDiagnosticsStore new];
	[store setDiagnostics:@[ diag(1) ] forURI:uri(@"/proj/a.c") clientKey:@"clangd" workspaceRoot:@"/proj"];
	[store setDiagnostics:@[ diag(1) ] forURI:uri(@"/usr/include/stdio.h") clientKey:@"clangd" workspaceRoot:@"/proj"];

	LSPDiagnosticsSnapshot* snapshot = [store snapshotForWorkspaceRoots:@[ @"/proj" ]];
	OAK_ASSERT_EQ(snapshot.fileGroups.count, 2);
	OAK_ASSERT(group_for(snapshot, @"/usr/include/stdio.h") != nil);

	// Nested roots: the deepest containing root wins, so the path reads short.
	[store setDiagnostics:@[ diag(1) ] forURI:uri(@"/proj/vendor/lib/x.c") clientKey:@"other" workspaceRoot:@"/proj/vendor"];
	NSArray* nestedRoots = @[ @"/proj", @"/proj/vendor" ];
	OAK_ASSERT(group_for([store snapshotForWorkspaceRoots:nestedRoots], @"lib/x.c") != nil);
}

// Workspace analysis publishes for hundreds of files at once; building the
// snapshot the panel renders from must stay a plain sort, not a per-row search.
void test_diagnostics_store_large_snapshot ()
{
	LSPDiagnosticsStore* store = [LSPDiagnosticsStore new];

	for(NSUInteger file = 0; file < 400; ++file)
	{
		NSMutableArray* diagnostics = [NSMutableArray new];
		for(NSUInteger i = 0; i < 25; ++i)
			[diagnostics addObject:diag(25 - i, 0, 1 + (i % 3))];
		[store setDiagnostics:diagnostics forURI:uri([NSString stringWithFormat:@"/proj/f%03lu.c", (unsigned long)file]) clientKey:@"clangd" workspaceRoot:@"/proj"];
	}

	LSPDiagnosticsSnapshot* snapshot = [store snapshotForWorkspaceRoots:@[ @"/proj" ]];
	OAK_ASSERT_EQ(snapshot.fileGroups.count, 400);
	OAK_ASSERT_EQ(snapshot.errorCount + snapshot.warningCount + snapshot.noteCount, 400*25);
	OAK_ASSERT_EQ(str(snapshot.fileGroups[0].displayPath), std::string("f000.c"));
	OAK_ASSERT_EQ(str(snapshot.fileGroups[399].displayPath), std::string("f399.c"));
	OAK_ASSERT_EQ(snapshot.fileGroups[0].entries[0].line, 1);
	OAK_ASSERT_EQ(snapshot.fileGroups[0].entries[24].line, 25);
}

// Servers re-publish unchanged diagnostics constantly, so a reader that trusts
// "something was published" rebuilds forever on an idle project. The revision
// is what lets it tell a real change from a repeat — and it covers scope too,
// since one store answers differently for different windows.
void test_diagnostics_store_revision ()
{
	LSPDiagnosticsStore* store = [LSPDiagnosticsStore new];
	NSArray* roots = @[ @"/proj" ];

	NSString* empty = [store revisionForWorkspaceRoots:roots];

	[store setDiagnostics:@[ diag(1) ] forURI:uri(@"/proj/a.c") clientKey:@"clangd" workspaceRoot:@"/proj"];
	NSString* first = [store revisionForWorkspaceRoots:roots];
	OAK_ASSERT(![first isEqualToString:empty]);

	// The identical publish again — the case pyright makes constantly.
	[store setDiagnostics:@[ diag(1) ] forURI:uri(@"/proj/a.c") clientKey:@"clangd" workspaceRoot:@"/proj"];
	OAK_ASSERT_EQ(str([store revisionForWorkspaceRoots:roots]), str(first));
	OAK_ASSERT_EQ(str([store snapshotForWorkspaceRoots:roots].revision), str(first));

	// A changed message is a change even though the range and severity are not.
	[store setDiagnostics:@[ diag(1, 0, 1, @"different") ] forURI:uri(@"/proj/a.c") clientKey:@"clangd" workspaceRoot:@"/proj"];
	OAK_ASSERT(![[store revisionForWorkspaceRoots:roots] isEqualToString:first]);
	NSString* second = [store revisionForWorkspaceRoots:roots];

	// Removing something nobody published changes nothing.
	[store setDiagnostics:@[] forURI:uri(@"/proj/absent.c") clientKey:@"clangd" workspaceRoot:@"/proj"];
	[store removeDiagnosticsForURI:uri(@"/proj/absent.c")];
	[store removeDiagnosticsForClientKey:@"never-existed"];
	OAK_ASSERT_EQ(str([store revisionForWorkspaceRoots:roots]), str(second));

	// …and the same contents seen through different roots are different rows.
	OAK_ASSERT(![[store revisionForWorkspaceRoots:@[ @"/proj/sub" ]] isEqualToString:second]);

	// A publish in a workspace this reader cannot see must leave it alone.
	// Every window gets the change notification, so a store-wide counter would
	// make each of them rebuild its whole list for a change it cannot show.
	[store setDiagnostics:@[ diag(1) ] forURI:uri(@"/other/z.py") clientKey:@"pyright" workspaceRoot:@"/other"];
	OAK_ASSERT_EQ(str([store revisionForWorkspaceRoots:roots]), str(second));
	[store setDiagnostics:@[ diag(2) ] forURI:uri(@"/other/z.py") clientKey:@"pyright" workspaceRoot:@"/other"];
	OAK_ASSERT_EQ(str([store revisionForWorkspaceRoots:roots]), str(second));
	[store removeDiagnosticsForClientKey:@"pyright"];
	OAK_ASSERT_EQ(str([store revisionForWorkspaceRoots:roots]), str(second));

	// …while a reader that can see both notices either one.
	NSArray* bothRoots = @[ @"/proj", @"/other" ];
	NSString* both = [store revisionForWorkspaceRoots:bothRoots];
	[store setDiagnostics:@[ diag(3) ] forURI:uri(@"/other/z.py") clientKey:@"pyright" workspaceRoot:@"/other"];
	OAK_ASSERT(![[store revisionForWorkspaceRoots:bothRoots] isEqualToString:both]);
	OAK_ASSERT_EQ(str([store revisionForWorkspaceRoots:roots]), str(second));

	[store removeDiagnosticsForClientKey:@"clangd"];
	OAK_ASSERT(![[store revisionForWorkspaceRoots:roots] isEqualToString:second]);
}

// A purge has to tell its caller which files it touched: the documents a client
// is registered to are not the files it published for, and re-applying only the
// former leaves a dead server's squiggles on the rest.
void test_diagnostics_store_purge_reports_uris ()
{
	LSPDiagnosticsStore* store = [LSPDiagnosticsStore new];
	[store setDiagnostics:@[ diag(1) ] forURI:uri(@"/proj/a.c") clientKey:@"clangd" workspaceRoot:@"/proj"];
	[store setDiagnostics:@[ diag(1) ] forURI:uri(@"/proj/b.c") clientKey:@"clangd" workspaceRoot:@"/proj"];
	[store setDiagnostics:@[ diag(1) ] forURI:uri(@"/proj/c.c") clientKey:@"linter" workspaceRoot:@"/proj"];

	NSArray<NSString*>* removed = [store removeDiagnosticsForClientKey:@"clangd"];
	OAK_ASSERT_EQ(removed.count, 2);
	OAK_ASSERT([removed containsObject:uri(@"/proj/a.c")]);
	OAK_ASSERT([removed containsObject:uri(@"/proj/b.c")]);
	OAK_ASSERT(![removed containsObject:uri(@"/proj/c.c")]);

	OAK_ASSERT_EQ([store removeDiagnosticsForClientKey:@"clangd"].count, 0);
}

// A client whose root was never recorded belongs to no window rather than to
// all of them — the safe direction for a surface that is meant to be scoped.
void test_diagnostics_store_client_without_root ()
{
	LSPDiagnosticsStore* store = [LSPDiagnosticsStore new];
	[store setDiagnostics:@[ diag(1) ] forURI:uri(@"/proj/a.c") clientKey:@"rootless" workspaceRoot:nil];

	OAK_ASSERT_EQ([store snapshotForWorkspaceRoots:@[ @"/proj" ]].fileGroups.count, 0);
	OAK_ASSERT_EQ([store snapshotForWorkspaceRoots:@[]].fileGroups.count, 1); // unscoped reader still sees it
	OAK_ASSERT_EQ([store diagnosticsForURI:uri(@"/proj/a.c")].count, 1); // …and so does the document
}

// The AgentBridge read merges across clients the same way the document does.
void test_diagnostics_store_all_by_uri_merges ()
{
	LSPDiagnosticsStore* store = [LSPDiagnosticsStore new];
	[store setDiagnostics:@[ diag(1) ]       forURI:uri(@"/proj/a.c") clientKey:@"clangd" workspaceRoot:@"/proj"];
	[store setDiagnostics:@[ diag(2, 0, 2) ] forURI:uri(@"/proj/a.c") clientKey:@"linter" workspaceRoot:@"/proj"];
	[store setDiagnostics:@[ diag(3) ]       forURI:uri(@"/proj/b.c") clientKey:@"clangd" workspaceRoot:@"/proj"];

	NSDictionary<NSString*, NSArray<NSDictionary*>*>* all = [store allDiagnosticsByURI];
	OAK_ASSERT_EQ(all.count, 2);
	OAK_ASSERT_EQ(all[uri(@"/proj/a.c")].count, 2);
	OAK_ASSERT_EQ(all[uri(@"/proj/b.c")].count, 1);
}
