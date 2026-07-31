#import <document/OakDocument.h>
#import <document/OakDocument Private.h>
#import <buffer/buffer.h>

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
}
