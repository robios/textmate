#import "../src/OakDocumentView.h"
#import "../src/GutterView.h"
#import <document/OakDocument.h>
#import <lsp/LSPManager Private.h>
#import <ns/ns.h>

// Diagnostics used to be published into the bookmark column as
// `error`/`warning`/`note` marks carrying the message as their payload, which
// made the column mean two things and the popover the only way to read one.
// They no longer are.
//
// Publishing therefore goes through -[LSPManager applyDiagnostics:toDocument:],
// which is where the mark writing lived and where re-adding it would go.
// Driving -[OakDocument setDiagnostics:] instead would assert nothing: that
// method never wrote marks, so the assertions below would hold just as well
// with the gutter publishing restored.
//
// What the gutter draws and what a click there does is asserted through the
// mark model rather than through the drawn image: the image is looked up by
// mark type, from resources that live in the application bundle and not in this
// test binary, so an assertion on the image would pass whether or not the marks
// were still being written.

static NSString* const kBookmarksColumn = @"bookmarks";

static void on_main (void(^block)(void))
{
	if(NSThread.isMainThread)
			block();
	else	dispatch_sync(dispatch_get_main_queue(), block);
}

static NSDictionary* lsp_diagnostic (NSUInteger line, NSInteger severity)
{
	return @{
		@"line":         @(line),
		@"character":    @0,
		@"endLine":      @(line),
		@"endCharacter": @3,
		@"severity":     @(severity),
		@"message":      @"undeclared identifier",
	};
}

static NSUInteger mark_count (OakDocument* doc, NSUInteger line)
{
	__block NSUInteger res = 0;
	[doc enumerateBookmarksAtLine:line block:^(text::pos_t const& pos, NSString* type, NSString* payload){
		++res;
	}];
	return res;
}

static NSUInteger bookmark_count (OakDocument* doc, NSUInteger line)
{
	__block NSUInteger res = 0;
	[doc enumerateBookmarksAtLine:line block:^(text::pos_t const& pos, NSString* type, NSString* payload){
		if([type isEqualToString:OakDocumentBookmarkIdentifier])
			++res;
	}];
	return res;
}

// One test function: it registers a document with the shared
// OakDocumentController, which the parallel runner must not race.
void test_gutter_carries_no_diagnostics ()
{
	on_main(^{
		OakDocument* doc = [OakDocument documentWithString:@"" fileType:@"text.plain" customName:@"gutter-diagnostics"];
		doc.content = @"int x;\nint y;\n";
		[doc loadModalForWindow:nil completionHandler:nil]; // an untitled document loads from memory, synchronously

		OakDocumentView* documentView = [[OakDocumentView alloc] initWithFrame:NSMakeRect(0, 0, 800, 600)];
		documentView.document = doc;

		id<GutterViewColumnDelegate> gutterDelegate = (id<GutterViewColumnDelegate>)documentView;
		LSPManager* manager = LSPManager.sharedManager; // applying diagnostics starts no client

		[manager applyDiagnostics:@[ lsp_diagnostic(0, 1) ] toDocument:doc];

		// The diagnostic did arrive — otherwise everything below passes for the
		// wrong reason
		OAK_ASSERT([doc hasDiagnosticsOnLine:0]);
		OAK_ASSERT_EQ(mark_count(doc, 0), 0); // …and left nothing in the gutter

		// So the click is a plain bookmark toggle, not a popover
		[gutterDelegate userDidClickColumnWithIdentifier:kBookmarksColumn atLine:0];
		OAK_ASSERT_EQ(bookmark_count(doc, 0), 1);
		OAK_ASSERT_EQ(mark_count(doc, 0), 1);

		[gutterDelegate userDidClickColumnWithIdentifier:kBookmarksColumn atLine:0];
		OAK_ASSERT_EQ(mark_count(doc, 0), 0);

		// A bookmark on a line survives a publish that changes the diagnostic
		// sitting on it, because the two no longer share a storage
		[gutterDelegate userDidClickColumnWithIdentifier:kBookmarksColumn atLine:1];
		[manager applyDiagnostics:@[ lsp_diagnostic(0, 2), lsp_diagnostic(1, 1) ] toDocument:doc];
		OAK_ASSERT_EQ(bookmark_count(doc, 1), 1);
		OAK_ASSERT_EQ(mark_count(doc, 1), 1);

		// A mark someone else put there — `mate --set-mark error:…`, which the
		// Bundle Support executor uses for every compiler line it parses — is
		// untouched by a publish too. Both halves of the old code destroyed it:
		// arrival cleared all three type names, and a clean file cleared them
		// again with nothing to put back.
		[doc setMarkOfType:@"error" atPosition:text::pos_t(1, 0) content:@"make: recipe failed"];
		[manager applyDiagnostics:@[ lsp_diagnostic(0, 1) ] toDocument:doc];
		OAK_ASSERT_EQ(mark_count(doc, 1), 2); // the bookmark and the external mark
		[manager applyDiagnostics:@[] toDocument:doc];
		OAK_ASSERT(![doc hasDiagnosticsOnLine:1]);
		OAK_ASSERT_EQ(mark_count(doc, 1), 2); // the bookmark and the external mark

		documentView.document = nil;
		[doc close]; // balances the load above, which opens the document
	});
}
