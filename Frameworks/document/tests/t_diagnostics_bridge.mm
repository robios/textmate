#import <document/OakDocument.h>
#import <document/OakDocument Private.h>
#import <buffer/buffer.h>
#import <ns/ns.h>

typedef std::vector<std::pair<size_t, size_t>> ranges_t;

static NSDictionary* lsp_diagnostic (NSUInteger line, NSUInteger character, NSUInteger endLine, NSUInteger endCharacter, id severity = nil, NSString* message = @"boom")
{
	NSMutableDictionary* res = [@{
		@"line":         @(line),
		@"character":    @(character),
		@"endLine":      @(endLine),
		@"endCharacter": @(endCharacter),
		@"message":      message,
	} mutableCopy];
	if(severity)
		res[@"severity"] = severity;
	return res;
}

static OakDocument* document_with (NSString* content)
{
	OakDocument* res = [OakDocument documentWithString:@"" fileType:@"text.plain" customName:@"diagnostics"];
	res.content = content;
	return res;
}

// One test function: creating documents registers them with the shared
// OakDocumentController, and the test runner runs test functions in parallel.
void test_diagnostics_bridge ()
{
	// LSP columns are UTF-16 code units, not bytes
	{
		OakDocument* doc = document_with(@"aébc\n"); // ‘é’ is two bytes
		[doc setDiagnostics:@[ lsp_diagnostic(0, 1, 0, 2) ]];
		OAK_ASSERT([doc buffer].diagnostics(3, 0, [doc buffer].size()) == (ranges_t{ { 1, 3 } }));

		// …and a column past the end of the line clamps to its end
		[doc setDiagnostics:@[ lsp_diagnostic(0, 0, 0, 99) ]];
		OAK_ASSERT([doc buffer].diagnostics(3, 0, [doc buffer].size()) == (ranges_t{ { 0, 5 } }));

		// …as does a line past the end of the document
		[doc setDiagnostics:@[ lsp_diagnostic(99, 0, 99, 1) ]];
		OAK_ASSERT([doc buffer].diagnostics(3, 0, [doc buffer].size()).empty()); // last line is empty
	}

	// Severity classes: 1/2 stay, everything else — including a missing value —
	// reads as note on every surface
	{
		OakDocument* doc = document_with(@"abcdefgh\n");
		[doc setDiagnostics:@[
			lsp_diagnostic(0, 0, 0, 1, @1),
			lsp_diagnostic(0, 2, 0, 3, @2),
			lsp_diagnostic(0, 4, 0, 5, @4),
			lsp_diagnostic(0, 6, 0, 7),      // no severity at all
		]];

		ng::buffer_t const& buf = [doc buffer];
		OAK_ASSERT(buf.diagnostics(1, 0, buf.size()) == (ranges_t{ { 0, 1 } }));
		OAK_ASSERT(buf.diagnostics(2, 0, buf.size()) == (ranges_t{ { 2, 3 } }));
		OAK_ASSERT(buf.diagnostics(3, 0, buf.size()) == (ranges_t{ { 4, 5 }, { 6, 7 } }));

		OAK_ASSERT_EQ(OakDiagnosticSeverityClass(nil), 3);
		OAK_ASSERT_EQ(OakDiagnosticSeverityClass(@1), 1);
		OAK_ASSERT_EQ(OakDiagnosticSeverityClass(@2), 2);
		OAK_ASSERT_EQ(OakDiagnosticSeverityClass(@3), 3);
		OAK_ASSERT_EQ(OakDiagnosticSeverityClass(@4), 3);
		OAK_ASSERT_EQ(OakDiagnosticSeverityClass(@99), 3);
		OAK_ASSERT_EQ(OakDiagnosticSeverityClass([NSNull null]), 3);
	}

	// A zero-length range mid-line grows onto the next character
	{
		OakDocument* doc = document_with(@"abc\n");
		[doc setDiagnostics:@[ lsp_diagnostic(0, 1, 0, 1, @1) ]];
		OAK_ASSERT([doc buffer].diagnostics(1, 0, [doc buffer].size()) == (ranges_t{ { 1, 2 } }));
	}

	// At end of line there is no next character — it grows leftwards instead,
	// because a squiggle on the newline would not be drawn at all
	{
		OakDocument* doc = document_with(@"abc\ndef\n");
		[doc setDiagnostics:@[ lsp_diagnostic(0, 3, 0, 3, @1) ]];
		OAK_ASSERT([doc buffer].diagnostics(1, 0, [doc buffer].size()) == (ranges_t{ { 2, 3 } }));
		OAK_ASSERT_EQ([doc buffer].diagnostics_at(3).size(), 1); // still readable where it was reported
	}

	// Same at the end of a document with no trailing newline
	{
		OakDocument* doc = document_with(@"abc");
		[doc setDiagnostics:@[ lsp_diagnostic(0, 3, 0, 3, @1) ]];
		OAK_ASSERT([doc buffer].diagnostics(1, 0, [doc buffer].size()) == (ranges_t{ { 2, 3 } }));
		OAK_ASSERT_EQ([doc buffer].diagnostics_at(3).size(), 1);
	}

	// An empty line has nothing to grow onto: it stays a zero-width point
	{
		OakDocument* doc = document_with(@"abc\n\ndef\n");
		[doc setDiagnostics:@[ lsp_diagnostic(1, 0, 1, 0, @1) ]];
		OAK_ASSERT([doc buffer].diagnostics(1, 0, [doc buffer].size()).empty());
		OAK_ASSERT([doc buffer].diagnostic_points(0, [doc buffer].size()) == (ranges_t{ { 4, 1 } }));
		OAK_ASSERT_EQ([doc buffer].diagnostics_at(4).size(), 1);
	}

	// …and so does an empty document
	{
		OakDocument* doc = document_with(@"");
		[doc setDiagnostics:@[ lsp_diagnostic(0, 0, 0, 0, @1) ]];
		OAK_ASSERT([doc buffer].has_diagnostics());
		OAK_ASSERT([doc buffer].diagnostic_points(0, 0) == (ranges_t{ { 0, 1 } }));
	}

	// Only real changes are announced: pyright and friends re-publish the same
	// set constantly, and each notification would cost a repaint
	{
		OakDocument* doc = document_with(@"abcdefgh\n");
		__block NSUInteger notifications = 0;
		id observer = [NSNotificationCenter.defaultCenter addObserverForName:OakDocumentDiagnosticsDidChangeNotification object:doc queue:nil usingBlock:^(NSNotification*){ ++notifications; }];

		NSArray* diagnostics = @[ lsp_diagnostic(0, 1, 0, 3, @1) ];
		[doc setDiagnostics:diagnostics];
		OAK_ASSERT_EQ(notifications, 1);

		[doc setDiagnostics:diagnostics];
		OAK_ASSERT_EQ(notifications, 1);

		[doc setDiagnostics:@[ lsp_diagnostic(0, 1, 0, 4, @1) ]];
		OAK_ASSERT_EQ(notifications, 2);

		[doc setDiagnostics:@[]];
		OAK_ASSERT_EQ(notifications, 3);
		OAK_ASSERT(![doc buffer].has_diagnostics());

		[NSNotificationCenter.defaultCenter removeObserver:observer];
	}

	// A message that changed without moving is announced — a tooltip showing the
	// old one has to stop — but flagged as needing no repaint
	{
		OakDocument* doc = document_with(@"abcdefgh\n");
		__block NSUInteger notifications = 0;
		__block BOOL lastRedraw = NO;
		id observer = [NSNotificationCenter.defaultCenter addObserverForName:OakDocumentDiagnosticsDidChangeNotification object:doc queue:nil usingBlock:^(NSNotification* notification){
			++notifications;
			lastRedraw = [notification.userInfo[@"redraw"] boolValue];
		}];

		[doc setDiagnostics:@[ lsp_diagnostic(0, 1, 0, 3, @1, @"first") ]];
		OAK_ASSERT_EQ(notifications, 1);
		OAK_ASSERT(lastRedraw);

		[doc setDiagnostics:@[ lsp_diagnostic(0, 1, 0, 3, @1, @"first") ]];
		OAK_ASSERT_EQ(notifications, 1); // identical: still silent

		[doc setDiagnostics:@[ lsp_diagnostic(0, 1, 0, 3, @1, @"second") ]];
		OAK_ASSERT_EQ(notifications, 2);
		OAK_ASSERT(!lastRedraw);
		OAK_ASSERT([doc buffer].diagnostics_at(1)[0].message == "second");

		[NSNotificationCenter.defaultCenter removeObserver:observer];
	}

	// A malformed range (end before start) is dropped rather than clamped into
	// something the server never said
	{
		OakDocument* doc = document_with(@"abcdefgh\n");
		[doc setDiagnostics:@[ lsp_diagnostic(0, 5, 0, 2, @1) ]];
		OAK_ASSERT(![doc buffer].has_diagnostics());
	}

	// The extent a point contributes reaches one byte past it, so a consumer
	// treating [from, to) as half-open — which the layout does — still repaints
	// the row the point sits on. Every point the bridge makes sits at a line
	// start, including the one on the trailing empty line, whose index is the
	// size of the buffer.
	{
		OakDocument* doc = document_with(@"abc\n");
		__block NSUInteger dirtyTo = 0;
		id observer = [NSNotificationCenter.defaultCenter addObserverForName:OakDocumentDiagnosticsDidChangeNotification object:doc queue:nil usingBlock:^(NSNotification* notification){
			dirtyTo = [notification.userInfo[@"to"] unsignedIntegerValue];
		}];

		[doc setDiagnostics:@[ lsp_diagnostic(0, 0, 0, 3, @1), lsp_diagnostic(1, 0, 1, 0, @1) ]];
		[doc setDiagnostics:@[ lsp_diagnostic(0, 1, 0, 3, @1), lsp_diagnostic(1, 0, 1, 0, @2) ]];
		OAK_ASSERT_EQ(dirtyTo, [doc buffer].size() + 1);

		[NSNotificationCenter.defaultCenter removeObserver:observer];
	}
}

// A panel row addresses a caret the way the rest of the editor does — a
// selection string — but the position it starts from is an LSP one, whose
// column counts UTF-16 code units rather than the bytes a selection string
// wants. The panel cannot do this conversion itself: it needs the line.
void test_diagnostics_selection_string ()
{
	OakDocument* doc = [OakDocument documentWithString:@"" fileType:@"text.plain" customName:@"selection"];
	doc.content = @"aébc\nxy\n"; // ‘é’ is two bytes, one UTF-16 unit

	OAK_ASSERT_EQ(to_s([doc selectionStringForLine:0 utf16Column:0]), std::string("1")); // column 1 is implicit
	OAK_ASSERT_EQ(to_s([doc selectionStringForLine:0 utf16Column:2]), std::string("1:4")); // past ‘é’: three bytes in
	OAK_ASSERT_EQ(to_s([doc selectionStringForLine:1 utf16Column:1]), std::string("2:2"));

	// Out-of-range positions clamp rather than escaping the buffer, the same
	// way the diagnostic ranges themselves do.
	OAK_ASSERT_EQ(to_s([doc selectionStringForLine:0 utf16Column:99]), std::string("1:6"));
	OAK_ASSERT_EQ(to_s([doc selectionStringForLine:99 utf16Column:0]), std::string("3"));

	// An unloaded document has no line to convert against, which is the
	// caller's cue that it has to load first.
	OAK_ASSERT([[OakDocument documentWithPath:@"/tmp/never-loaded-diagnostics.txt"] selectionStringForLine:0 utf16Column:0] == nil);
}

// Opening a diagnostics row is the panel's one path into an arbitrary, possibly
// stale, file name, so what a failing load does with its own reference is
// load-bearing for it. -loadModalForWindow: opens the document before anything
// else, but on failure OakDocument closes itself from -didLoadContent: BEFORE
// calling back — so the caller must close only on success. Closing on both
// drives an unsigned open count below zero, after which the document never
// closes again, never posts OakDocumentWillCloseNotification, and never tells
// its server the file was closed.
//
// This lives with the diagnostics tests because they are what made the contract
// load-bearing; it belongs to OakDocument.
static BOOL load_failed_for (OakDocument* doc)
{
	__block BOOL failed = NO;
	dispatch_semaphore_t done = dispatch_semaphore_create(0);

	// -loadModalForWindow: is main-thread work; the runner leaves the main
	// thread spinning its run loop while test functions run off it.
	dispatch_async(dispatch_get_main_queue(), ^{
		[doc loadModalForWindow:nil completionHandler:^(OakDocumentIOResult result, NSString* errorMessage, oak::uuid_t const& filterUUID){
			failed = result != OakDocumentIOResultSuccess;
			dispatch_semaphore_signal(done);
		}];
	});
	OAK_ASSERT_EQ((long)dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC))), 0L);
	return failed;
}

void test_failed_load_releases_its_own_reference ()
{
	// A path that cannot be read as a file. Note that a *deleted* file is not
	// one of these: TextMate opens a missing path as a new empty document, so
	// the row for a file the server has since lost simply opens it empty.
	OakDocument* unreadable = [OakDocument documentWithPath:@"/private/etc"];
	OAK_ASSERT_EQ((BOOL)unreadable.isOpen, NO);

	OAK_ASSERT_EQ(load_failed_for(unreadable), YES);
	OAK_ASSERT_EQ((BOOL)unreadable.isOpen, NO); // …so the caller must NOT close it
	OAK_ASSERT_EQ((BOOL)unreadable.isLoaded, NO);

	// The success path is the other half of the same contract: there the open
	// reference is the caller's to release.
	OakDocument* missing = [OakDocument documentWithPath:@"/tmp/com.macromates.textmate.no-such-file-for-diagnostics.txt"];
	OAK_ASSERT_EQ(load_failed_for(missing), NO);
	OAK_ASSERT_EQ((BOOL)missing.isOpen, YES);
	[missing close];
	OAK_ASSERT_EQ((BOOL)missing.isOpen, NO);
}
