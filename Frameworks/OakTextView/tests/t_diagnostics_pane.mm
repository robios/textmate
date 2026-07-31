#import "../src/DiagnosticsPaneView.h"
#import "../src/DiffPaneView.h"
#import "../src/OakDocumentView.h"
#import <lsp/LSPDiagnosticsStore.h>
#import <ns/ns.h>

// AppKit is main-thread only and the test runner executes test functions on a
// global queue while the main thread spins its run loop — so every test here
// hops onto the main queue and back. That also serializes them against each
// other, which is what view code wants anyway.
static void on_main (void(^block)(void))
{
	if(NSThread.isMainThread)
			block();
	else	dispatch_sync(dispatch_get_main_queue(), block);
}

static NSDictionary* diag (NSUInteger line, NSInteger severity, NSString* message)
{
	return @{
		@"line":         @(line),
		@"character":    @0,
		@"endLine":      @(line),
		@"endCharacter": @1,
		@"severity":     @(severity),
		@"message":      message,
	};
}

static NSString* uri (NSString* path)
{
	return [NSURL fileURLWithPath:path].absoluteString;
}

// Two files: a.c with one error and one warning, b.c with one warning.
static LSPDiagnosticsSnapshot* two_file_snapshot ()
{
	LSPDiagnosticsStore* store = [LSPDiagnosticsStore new];
	NSArray* first = @[ diag(3, 1, @"undeclared identifier"), diag(9, 2, @"unused variable") ];
	[store setDiagnostics:first forURI:uri(@"/proj/a.c") clientKey:@"clangd" workspaceRoot:@"/proj"];
	[store setDiagnostics:@[ diag(1, 2, @"missing prototype") ] forURI:uri(@"/proj/b.c") clientKey:@"clangd" workspaceRoot:@"/proj"];
	return [store snapshotForWorkspaceRoots:@[ @"/proj" ]];
}

static NSString* title_for_action (id target, SEL action)
{
	NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:@"" action:action keyEquivalent:@""];
	[target validateMenuItem:item];
	return item.title;
}

// Whether a pane of the given class is present in the view tree AND its
// enclosing scroll view is showing. The menu titles only report the flags; this
// reports what the window actually displays, which is what a third pane could
// break without the flags noticing.
static BOOL pane_is_visible (NSView* view, Class paneClass)
{
	if([view isKindOfClass:paneClass])
		return !view.enclosingScrollView.hidden;

	for(NSView* child in view.subviews)
	{
		if(pane_is_visible(child, paneClass))
			return YES;
	}
	return NO;
}

// Everything the pane holds on to has to go when it is closed — the snapshot
// and the row views both. What the reader chose does not: the filter and the
// collapsed groups are still theirs when the pane comes back.
void test_diagnostics_pane_lifecycle ()
{
	on_main(^{
		DiagnosticsPaneView* pane = [[DiagnosticsPaneView alloc] initWithFrame:NSMakeRect(0, 0, 300, 400)];
		pane.active = YES;
		[pane takeSnapshot:two_file_snapshot()];

		OAK_ASSERT_EQ(pane.numberOfRows, 5); // two file headers, three diagnostics
		OAK_ASSERT(pane.subviews.count > 0);

		// Collapsing a group and filtering are the reader's, and both survive
		// the teardown that closing the pane does.
		[pane activateRow:0]; // the a.c header
		OAK_ASSERT_EQ(pane.numberOfRows, 3);
		OAK_ASSERT_EQ(pane.collapsedFilePaths.count, 1);
		OAK_ASSERT([pane.collapsedFilePaths containsObject:@"/proj/a.c"]);

		pane.errorsOnly = YES;
		OAK_ASSERT_EQ(pane.numberOfRows, 1); // a.c's header alone; b.c has no error

		pane.active = NO;
		OAK_ASSERT_EQ(pane.subviews.count, 0);
		OAK_ASSERT_EQ(pane.numberOfRows, 0);

		// An inactive pane holds no snapshot, so handing it one changes nothing
		// — otherwise a closed pane keeps a whole workspace's diagnostics alive.
		[pane takeSnapshot:two_file_snapshot()];
		OAK_ASSERT_EQ(pane.subviews.count, 0);
		OAK_ASSERT_EQ(pane.numberOfRows, 0);

		pane.active = YES;
		OAK_ASSERT_EQ(pane.numberOfRows, 0); // …and it did not quietly keep the one it was handed

		[pane takeSnapshot:two_file_snapshot()];
		OAK_ASSERT_EQ(pane.errorsOnly, YES);
		OAK_ASSERT_EQ(pane.numberOfRows, 1);
		OAK_ASSERT([pane.collapsedFilePaths containsObject:@"/proj/a.c"]);

		pane.errorsOnly = NO;
		[pane activateRow:0]; // expand a.c again
		OAK_ASSERT_EQ(pane.numberOfRows, 5);
		OAK_ASSERT_EQ(pane.collapsedFilePaths.count, 0);
	});
}

// Collapse is the reader's state for as long as the file is on the list. It
// must not outlive the file going clean, or the group comes back weeks later
// already closed and the pane looks like it is hiding rows by itself.
void test_diagnostics_pane_collapse_expires_with_the_file ()
{
	on_main(^{
		DiagnosticsPaneView* pane = [[DiagnosticsPaneView alloc] initWithFrame:NSMakeRect(0, 0, 300, 400)];
		pane.active = YES;
		[pane takeSnapshot:two_file_snapshot()];

		[pane activateRow:0]; // collapse a.c
		OAK_ASSERT([pane.collapsedFilePaths containsObject:@"/proj/a.c"]);

		// Still listed, still collapsed — a publish that changed something else.
		[pane takeSnapshot:two_file_snapshot()];
		OAK_ASSERT([pane.collapsedFilePaths containsObject:@"/proj/a.c"]);
		OAK_ASSERT_EQ(pane.numberOfRows, 3);

		// The filter is not the file leaving: a.c has no warning-only rows to
		// show under Errors, but it is still in the snapshot.
		LSPDiagnosticsStore* store = [LSPDiagnosticsStore new];
		[store setDiagnostics:@[ diag(1, 2, @"only a warning") ] forURI:uri(@"/proj/a.c") clientKey:@"clangd" workspaceRoot:@"/proj"];
		pane.errorsOnly = YES;
		[pane takeSnapshot:[store snapshotForWorkspaceRoots:@[ @"/proj" ]]];
		OAK_ASSERT([pane.collapsedFilePaths containsObject:@"/proj/a.c"]);
		pane.errorsOnly = NO;

		// a.c goes clean: the collapse goes with it.
		LSPDiagnosticsStore* without = [LSPDiagnosticsStore new];
		[without setDiagnostics:@[ diag(1, 2, @"missing prototype") ] forURI:uri(@"/proj/b.c") clientKey:@"clangd" workspaceRoot:@"/proj"];
		[pane takeSnapshot:[without snapshotForWorkspaceRoots:@[ @"/proj" ]]];
		OAK_ASSERT_EQ(pane.collapsedFilePaths.count, 0);

		// …so when it comes back, it comes back open.
		[pane takeSnapshot:two_file_snapshot()];
		OAK_ASSERT_EQ(pane.numberOfRows, 5);
	});
}

// A publish elsewhere in the project must not move the reader: the row model is
// rebuilt whole, so the selection has to be re-found by what it names.
void test_diagnostics_pane_preserves_selection_across_rebuild ()
{
	on_main(^{
		DiagnosticsPaneView* pane = [[DiagnosticsPaneView alloc] initWithFrame:NSMakeRect(0, 0, 300, 400)];
		pane.active = YES;
		[pane takeSnapshot:two_file_snapshot()];

		__block NSString* opened = nil;
		pane.openLocationHandler = ^(NSURL* fileURL, NSUInteger line, NSUInteger column){ opened = fileURL.path; };

		// Row 4 is b.c's only diagnostic — the last row in the list.
		pane.selectedRow = 4;
		OAK_ASSERT_EQ(pane.selectedRow, 4);

		// A file appearing above it shifts every row number under the reader.
		LSPDiagnosticsStore* store = [LSPDiagnosticsStore new];
		NSArray* first = @[ diag(3, 1, @"undeclared identifier"), diag(9, 2, @"unused variable") ];
		[store setDiagnostics:first forURI:uri(@"/proj/a.c") clientKey:@"clangd" workspaceRoot:@"/proj"];
		[store setDiagnostics:@[ diag(1, 2, @"missing prototype") ] forURI:uri(@"/proj/b.c") clientKey:@"clangd" workspaceRoot:@"/proj"];
		[store setDiagnostics:@[ diag(0, 1, @"new problem") ] forURI:uri(@"/proj/AAA.c") clientKey:@"clangd" workspaceRoot:@"/proj"];
		[pane takeSnapshot:[store snapshotForWorkspaceRoots:@[ @"/proj" ]]];

		OAK_ASSERT_EQ(pane.numberOfRows, 7);
		OAK_ASSERT_EQ(pane.selectedRow, 6); // …and the reader is still on b.c's row

		[pane activateRow:pane.selectedRow];
		OAK_ASSERT_EQ(to_s(opened), std::string("/proj/b.c"));

		// A selection whose diagnostic is gone is dropped rather than moved.
		LSPDiagnosticsStore* without = [LSPDiagnosticsStore new];
		[without setDiagnostics:first forURI:uri(@"/proj/a.c") clientKey:@"clangd" workspaceRoot:@"/proj"];
		[pane takeSnapshot:[without snapshotForWorkspaceRoots:@[ @"/proj" ]]];
		OAK_ASSERT_EQ(pane.selectedRow, -1);
	});
}

// A diagnostic row hands the owner LSP coordinates for the file it names,
// which is the only thing that can carry a cross-file jump.
void test_diagnostics_pane_navigation ()
{
	on_main(^{
		__block NSString* openedPath = nil;
		__block NSUInteger openedLine = 0, openedColumn = 0;
		__block NSUInteger openCount = 0;

		DiagnosticsPaneView* pane = [[DiagnosticsPaneView alloc] initWithFrame:NSMakeRect(0, 0, 300, 400)];
		pane.openLocationHandler = ^(NSURL* fileURL, NSUInteger line, NSUInteger column){
			openedPath   = fileURL.path;
			openedLine   = line;
			openedColumn = column;
			openCount   += 1;
		};
		pane.active = YES;
		[pane takeSnapshot:two_file_snapshot()];

		// Rows: 0 = a.c, 1 = its error, 2 = its warning, 3 = b.c, 4 = b.c's warning.
		[pane activateRow:1];
		OAK_ASSERT_EQ(openCount, 1);
		OAK_ASSERT_EQ(to_s(openedPath), std::string("/proj/a.c"));
		OAK_ASSERT_EQ(openedLine, 3);   // 0-based, exactly as the server said
		OAK_ASSERT_EQ(openedColumn, 0);

		[pane activateRow:4];
		OAK_ASSERT_EQ(openCount, 2);
		OAK_ASSERT_EQ(to_s(openedPath), std::string("/proj/b.c"));
		OAK_ASSERT_EQ(openedLine, 1);

		// A file row toggles instead of navigating, and a row that does not
		// exist does nothing at all.
		[pane activateRow:3];
		OAK_ASSERT_EQ(openCount, 2);
		[pane activateRow:99];
		OAK_ASSERT_EQ(openCount, 2);
	});
}

// Workspace analysis can put thousands of rows in the list. The outline view
// must recycle: materializing one view per diagnostic is what makes a large
// project unusable rather than merely busy.
void test_diagnostics_pane_recycles_rows ()
{
	on_main(^{
		LSPDiagnosticsStore* store = [LSPDiagnosticsStore new];
		for(NSUInteger file = 0; file < 60; ++file)
		{
			NSMutableArray* diagnostics = [NSMutableArray new];
			for(NSUInteger i = 0; i < 40; ++i)
				[diagnostics addObject:diag(i, 1 + (i % 3), @"something is wrong with this line")];
			[store setDiagnostics:diagnostics forURI:uri([NSString stringWithFormat:@"/proj/f%02lu.c", (unsigned long)file]) clientKey:@"clangd" workspaceRoot:@"/proj"];
		}

		NSWindow* window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 320, 400) styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];

		DiagnosticsPaneView* pane = [[DiagnosticsPaneView alloc] initWithFrame:NSMakeRect(0, 0, 320, 400)];
		window.contentView = pane;
		pane.active = YES;
		[pane takeSnapshot:[store snapshotForWorkspaceRoots:@[ @"/proj" ]]];

		[pane layoutSubtreeIfNeeded];
		[window displayIfNeeded];

		OAK_ASSERT_EQ(pane.numberOfRows, 60 + 60*40);

		// Count the row views AppKit actually built. A 400 pt pane cannot show
		// 2460 rows, so anything close to that number means no recycling.
		__block NSUInteger rowViews = 0;
		void (^__block count)(NSView*) = nil;
		count = ^(NSView* view){
			for(NSView* child in view.subviews)
			{
				if([child isKindOfClass:[NSTableRowView class]])
					rowViews += 1;
				count(child);
			}
		};
		count(pane);

		OAK_ASSERT_GT(rowViews, 0);   // …and the count means nothing if nothing was built at all
		OAK_ASSERT_LT(rowViews, 200);
	});
}

// The two side panes are peers in the same document view and v1 makes them
// mutually exclusive, so opening one closes the other.
void test_diagnostics_pane_excludes_diff_pane ()
{
	on_main(^{
		OakDocumentView* documentView = [[OakDocumentView alloc] initWithFrame:NSMakeRect(0, 0, 800, 600)];

		OAK_ASSERT_EQ(to_s(title_for_action(documentView, @selector(toggleDiffPane:))), std::string("Show Diff"));
		OAK_ASSERT_EQ(to_s(title_for_action(documentView, @selector(toggleDiagnosticsPane:))), std::string("Show Diagnostics"));

		[documentView toggleDiffPane:nil];
		OAK_ASSERT_EQ(to_s(title_for_action(documentView, @selector(toggleDiffPane:))), std::string("Hide Diff"));
		OAK_ASSERT_EQ(to_s(title_for_action(documentView, @selector(toggleDiagnosticsPane:))), std::string("Show Diagnostics"));
		OAK_ASSERT(pane_is_visible(documentView, [DiffPaneView class]));
		OAK_ASSERT(!pane_is_visible(documentView, [DiagnosticsPaneView class]));

		[documentView toggleDiagnosticsPane:nil];
		OAK_ASSERT_EQ(to_s(title_for_action(documentView, @selector(toggleDiffPane:))), std::string("Show Diff"));
		OAK_ASSERT_EQ(to_s(title_for_action(documentView, @selector(toggleDiagnosticsPane:))), std::string("Hide Diagnostics"));
		OAK_ASSERT(!pane_is_visible(documentView, [DiffPaneView class]));
		OAK_ASSERT(pane_is_visible(documentView, [DiagnosticsPaneView class]));

		[documentView toggleDiffPane:nil];
		OAK_ASSERT_EQ(to_s(title_for_action(documentView, @selector(toggleDiffPane:))), std::string("Hide Diff"));
		OAK_ASSERT_EQ(to_s(title_for_action(documentView, @selector(toggleDiagnosticsPane:))), std::string("Show Diagnostics"));

		[documentView toggleDiffPane:nil];
		OAK_ASSERT_EQ(to_s(title_for_action(documentView, @selector(toggleDiffPane:))), std::string("Show Diff"));
	});
}
