#import "../src/MarkdownPreviewView.h"
#import <document/OakDocument.h>
#import <HTMLOutput/HTMLOutput.h>
#import <test/jail.h>
#import <ns/ns.h>
#import <WebKit/WebKit.h>
#import <mutex>

// The name the pane registers its copy world under; worldWithName: hands the
// tests the very same world, so a test can drive the isolated copy channel.
static NSString* const kCopyWorldName = @"com.macromates.markdown-preview.copy";

// gen_test runs a suite’s tests in parallel; several here read and write the
// one general pasteboard. Each holds this around its pasteboard-critical
// section so a “still holds the sentinel” assertion can’t see another test’s
// write.
static std::mutex& pasteboard_mutex ()
{
	static std::mutex mutex;
	return mutex;
}

// Drives the real pane end to end against the ‘source.pane-test’ converter
// committed by t_preview_converter.cc’s setup: activation loads the shell in
// an offscreen WKWebView, the external converter runs through the actual
// render path, and its fragment lands in #content. That covers targeting,
// execution, and render-on-change headlessly; menu gating and the ⚠︎ click
// remain interactive checks.

// AppKit is main-thread only while the runner drives test functions from a
// global queue — same hop as the other view tests.
static void on_main (void(^block)(void))
{
	if(NSThread.isMainThread)
			block();
	else	dispatch_sync(dispatch_get_main_queue(), block);
}

static WKWebView* web_view_in (NSView* view)
{
	for(NSView* subview in view.subviews)
	{
		if([subview isKindOfClass:[WKWebView class]])
			return (WKWebView*)subview;
		if(WKWebView* nested = web_view_in(subview))
			return nested;
	}
	return nil;
}

// The header’s title field — the only text field the pane has.
static NSTextField* text_field_in (NSView* view)
{
	for(NSView* subview in view.subviews)
	{
		if([subview isKindOfClass:[NSTextField class]])
			return (NSTextField*)subview;
		if(NSTextField* nested = text_field_in(subview))
			return nested;
	}
	return nil;
}

// The header’s ⚠︎ — the only control carrying the failure accessibility label.
static NSButton* warning_button_in (NSView* view)
{
	for(NSView* subview in view.subviews)
	{
		if([subview isKindOfClass:[NSButton class]] && [[(NSButton*)subview image].accessibilityDescription isEqualToString:@"Preview Command Failed"])
			return (NSButton*)subview;
		if(NSButton* nested = warning_button_in(subview))
			return nested;
	}
	return nil;
}

// Polls the ⚠︎ until it reaches `visible` — the pane’s only outward sign that
// a render completed with a failure rather than content.
static BOOL wait_for_warning (MarkdownPreviewView* pane, BOOL visible, NSTimeInterval timeout)
{
	NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
	while([deadline timeIntervalSinceNow] > 0)
	{
		__block BOOL state = NO;
		on_main(^{
			NSButton* button = warning_button_in(pane);
			state = button && !button.hidden;
		});
		if(state == visible)
			return YES;
		usleep(100'000);
	}
	return NO;
}

// Runs `script` in `webView` from the main run loop.
static id evaluate_js_in_web_view (WKWebView* webView, NSString* script)
{
	__block id value = nil;
	dispatch_semaphore_t done = dispatch_semaphore_create(0);
	on_main(^{
		[webView evaluateJavaScript:script completionHandler:^(id result, NSError* error){
			value = result;
			dispatch_semaphore_signal(done);
		}];
		if(!webView)
			dispatch_semaphore_signal(done);
	});
	dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
	return value;
}

// Runs `script` in the pane’s page from the main run loop.
static id evaluate_js (MarkdownPreviewView* pane, NSString* script)
{
	__block WKWebView* webView = nil;
	on_main(^{ webView = web_view_in(pane); });
	return evaluate_js_in_web_view(webView, script);
}

// Runs `script` in `world` (e.g. the copy control’s isolated world), from the
// main run loop — the page world sees a different global scope.
static id evaluate_js_in_world (MarkdownPreviewView* pane, WKContentWorld* world, NSString* script)
{
	__block WKWebView* webView = nil;
	on_main(^{ webView = web_view_in(pane); });

	__block id value = nil;
	dispatch_semaphore_t done = dispatch_semaphore_create(0);
	on_main(^{
		[webView evaluateJavaScript:script inFrame:nil inContentWorld:world completionHandler:^(id result, NSError* error){
			value = result;
			dispatch_semaphore_signal(done);
		}];
		if(!webView)
			dispatch_semaphore_signal(done);
	});
	dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
	return value;
}

// Seeds the general pasteboard with `sentinel`, from the main run loop.
static void seed_pasteboard (NSString* sentinel)
{
	on_main(^{
		[NSPasteboard.generalPasteboard clearContents];
		[NSPasteboard.generalPasteboard setString:sentinel forType:NSPasteboardTypeString];
	});
}

static NSString* pasteboard_string ()
{
	__block NSString* value = nil;
	on_main(^{ value = [NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString]; });
	return value;
}

// Polls the pasteboard until it equals `expected`, up to `timeout`. Returns the
// last value seen, so a failed assertion shows what was actually there.
static NSString* wait_for_pasteboard (NSString* expected, NSTimeInterval timeout)
{
	NSString* value = nil;
	NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
	while([deadline timeIntervalSinceNow] > 0)
	{
		value = pasteboard_string();
		if([value isEqualToString:expected])
			break;
		usleep(100'000);
	}
	return value;
}

static NSString* page_content (MarkdownPreviewView* pane)
{
	id value = evaluate_js(pane, @"(document.getElementById('content') || {}).innerHTML || ''");
	return [value isKindOfClass:[NSString class]] ? value : @"";
}

// Polls #content from the main run loop until `needle` appears; returns the
// last HTML seen either way, so a failed assertion shows what was there.
static NSString* wait_for_content (MarkdownPreviewView* pane, NSString* needle, NSTimeInterval timeout)
{
	NSString* html = @"";
	NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
	while([deadline timeIntervalSinceNow] > 0)
	{
		html = page_content(pane);
		if([html rangeOfString:needle].location != NSNotFound)
			break;
		usleep(100'000);
	}
	return html;
}

// Whether the shell page itself is up — the converter’s fragment is a
// separate event, and the gated converter below never gets there on its own.
static BOOL wait_for_shell (MarkdownPreviewView* pane, NSTimeInterval timeout)
{
	NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
	while([deadline timeIntervalSinceNow] > 0)
	{
		id value = evaluate_js(pane, @"!!(window.TMPreview && document.getElementById('content'))");
		if([value respondsToSelector:@selector(boolValue)] && [value boolValue])
			return YES;
		usleep(100'000);
	}
	return NO;
}

// The pid a converter wrote to `path`, waited for; the trailing newline is
// what says the shell finished writing it.
static pid_t wait_for_child_pid (std::string const& path, double timeout)
{
	for(size_t i = 0; i < (size_t)(timeout / 0.025); ++i)
	{
		std::string const content = path::content(path);
		if(content != NULL_STR && !content.empty() && content.back() == '\n')
			return atoi(content.c_str());
		usleep(25'000);
	}
	return -1;
}

// Whether the process is gone, waiting up to five seconds for it.
static BOOL wait_for_death (pid_t pid)
{
	for(size_t i = 0; i < 200; ++i)
	{
		if(kill(pid, 0) == -1 && errno == ESRCH)
			return YES;
		usleep(25'000);
	}
	return NO;
}

static BOOL wait_for_file (std::string const& path, double timeout)
{
	for(size_t i = 0; i < (size_t)(timeout / 0.025); ++i)
	{
		if(path::exists(path))
			return YES;
		usleep(25'000);
	}
	return NO;
}

// A document read from disk, so it has a directory the preview can follow.
static OakDocument* loaded_document (std::string const& path, NSString* fileType)
{
	OakDocument* doc = [OakDocument documentWithPath:to_ns(path)];
	doc.fileType = fileType;

	__block BOOL ok = NO;
	dispatch_semaphore_t done = dispatch_semaphore_create(0);
	dispatch_async(dispatch_get_main_queue(), ^{ // loading is main-thread work, and the runner leaves the main thread spinning its run loop
		[doc loadModalForWindow:nil completionHandler:^(OakDocumentIOResult result, NSString* errorMessage, oak::uuid_t const& filterUUID){
			ok = result == OakDocumentIOResultSuccess;
			dispatch_semaphore_signal(done);
		}];
	});
	dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
	return ok ? doc : nil;
}

void test_external_converter_drives_pane ()
{
	__block NSWindow* window;
	__block MarkdownPreviewView* pane;
	__block OakDocument* doc;

	on_main(^{
		window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 400, 600) styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
		pane = [[MarkdownPreviewView alloc] initWithFrame:NSMakeRect(0, 0, 400, 600)];
		window.contentView = pane;

		doc = [OakDocument documentWithString:@"hello preview" fileType:@"source.pane-test" customName:@"pane-test"];
		[doc loadModalForWindow:nil completionHandler:nil]; // untitled: loads from memory, synchronously

		pane.document = doc;
		pane.active   = YES;
	});

	NSString* html = wait_for_content(pane, @"hello preview", 20);
	OAK_ASSERT_NE([html rangeOfString:@"hello preview"].location, NSNotFound);
	OAK_ASSERT_NE([html rangeOfString:@"<pre"].location, NSNotFound);
	OAK_ASSERT_NE([html rangeOfString:@"data-sourcepos"].location, NSNotFound);

	// Render-on-change: a buffer edit re-renders through the converter after
	// the external debounce.
	on_main(^{
		doc.content = @"changed by an edit";
	});
	html = wait_for_content(pane, @"changed by an edit", 20);
	OAK_ASSERT_NE([html rangeOfString:@"changed by an edit"].location, NSNotFound);

	on_main(^{
		pane.active = NO; // kills any converter and tears down the web view
		pane.document = nil;
		window.contentView = nil;
		[doc close]; // balances the load above
	});
}

// A converter that exits normally having left a background job in its process
// group. The run is over as far as the pane is concerned — it drops the record
// of the process the moment the fragment arrives — so closing the pane can no
// longer reach that job, and the promise that a preview leaves nothing running
// behind it holds only if the run itself clears the group.
void test_pane_leaves_no_converter_child_behind ()
{
	test::jail_t jail;
	jail.set_content("orphan.txt", "ORPHANING-DOCUMENT");

	OakDocument* doc = loaded_document(jail.path("orphan.txt"), @"source.pane-test-orphan");
	OAK_ASSERT(doc != nil);

	__block NSWindow* window;
	__block MarkdownPreviewView* pane;

	on_main(^{
		window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 400, 600) styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
		pane = [[MarkdownPreviewView alloc] initWithFrame:NSMakeRect(0, 0, 400, 600)];
		window.contentView = pane;

		pane.document = doc;
		pane.active   = YES;
	});

	NSString* html = wait_for_content(pane, @"ORPHANING-DOCUMENT", 20);
	OAK_ASSERT_NE([html rangeOfString:@"ORPHANING-DOCUMENT"].location, NSNotFound);

	pid_t const childPid = wait_for_child_pid(jail.path("preview-child.pid"), 5);
	OAK_ASSERT(childPid > 0);

	on_main(^{
		pane.active = NO; // the pane going away is the last moment anything could stop it
		pane.document = nil;
		window.contentView = nil;
		[doc close];
	});

	OAK_ASSERT(wait_for_death(childPid));
}

// Switching documents across directories reloads the shell asynchronously,
// which leaves a window in which a result rendered for the document being
// left can still arrive. It must not be shown: the pane would end up with one
// document in its header and another in its page, and nothing short of an
// edit would correct it.
void test_document_switch_orphans_the_old_render ()
{
	test::jail_t oldJail, newJail;
	oldJail.set_content("old.txt", "STALE-DOCUMENT-A");
	newJail.set_content("new.txt", "FRESH-DOCUMENT-B");

	std::string const started = oldJail.path("preview-started");
	std::string const release = oldJail.path("preview-go");
	std::string const done    = oldJail.path("preview-done");

	OakDocument* oldDocument = loaded_document(oldJail.path("old.txt"), @"source.pane-test-gated");
	OakDocument* newDocument = loaded_document(newJail.path("new.txt"), @"source.pane-test");
	OAK_ASSERT(oldDocument && newDocument);

	__block NSWindow* window;
	__block MarkdownPreviewView* pane;

	on_main(^{
		window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 400, 600) styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
		pane = [[MarkdownPreviewView alloc] initWithFrame:NSMakeRect(0, 0, 400, 600)];
		window.contentView = pane;

		pane.document = oldDocument;
		pane.active   = YES;
	});
	OAK_ASSERT(wait_for_shell(pane, 20));

	// The switch happens while the main thread is held, so the old render can
	// only be delivered afterwards — the ordering the pane has to survive.
	__block BOOL gated = NO;
	on_main(^{
		gated = wait_for_file(started, 20) && path::set_content(release, "") && wait_for_file(done, 20);
		pane.document = newDocument;
	});
	OAK_ASSERT(gated);

	NSString* html = wait_for_content(pane, @"FRESH-DOCUMENT-B", 20);
	OAK_ASSERT_NE([html rangeOfString:@"FRESH-DOCUMENT-B"].location, NSNotFound);

	// …and it stays that way: the old result is on the main queue by now.
	for(size_t i = 0; i < 10; ++i)
	{
		usleep(100'000);
		html = page_content(pane);
		OAK_ASSERT(([html rangeOfString:@"STALE-DOCUMENT-A"].location == NSNotFound));
	}
	OAK_ASSERT_NE([html rangeOfString:@"FRESH-DOCUMENT-B"].location, NSNotFound);

	__block std::string title;
	on_main(^{ title = to_s(text_field_in(pane).stringValue); });
	OAK_ASSERT_EQ(title, to_s(newDocument.displayName));

	on_main(^{
		pane.active = NO;
		pane.document = nil;
		window.contentView = nil;
		[oldDocument close];
		[newDocument close];
	});
}

// A failure right after a document switch, before the new document rendered
// anything: within one directory the shell survives the switch, so without a
// clear the old document’s body would sit under the new document’s header
// for as long as the converter keeps failing.
void test_failure_after_document_switch_clears_the_page ()
{
	test::jail_t jail;
	jail.set_content("good.txt", "STALE-BODY-A");
	jail.set_content("bad.txt", "FAIL-AT-ONCE-B");

	OakDocument* goodDocument = loaded_document(jail.path("good.txt"), @"source.pane-test");
	OakDocument* badDocument  = loaded_document(jail.path("bad.txt"), @"source.pane-test-flaky");
	OAK_ASSERT(goodDocument && badDocument);

	__block NSWindow* window;
	__block MarkdownPreviewView* pane;

	on_main(^{
		window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 400, 600) styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
		pane = [[MarkdownPreviewView alloc] initWithFrame:NSMakeRect(0, 0, 400, 600)];
		window.contentView = pane;

		pane.document = goodDocument;
		pane.active   = YES;
	});

	NSString* html = wait_for_content(pane, @"STALE-BODY-A", 20);
	OAK_ASSERT_NE([html rangeOfString:@"STALE-BODY-A"].location, NSNotFound);

	on_main(^{ pane.document = badDocument; });
	OAK_ASSERT(wait_for_warning(pane, YES, 20));

	// The failure must have taken the old document’s body with it — and the
	// page stays empty rather than flickering anything back.
	for(size_t i = 0; i < 5; ++i)
	{
		html = page_content(pane);
		OAK_ASSERT_EQ(to_s(html), "");
		usleep(100'000);
	}

	// Recovery: once the new document renders, the content is its own and the
	// ⚠︎ stands down.
	on_main(^{ badDocument.content = @"RECOVERED-BODY-B"; });
	html = wait_for_content(pane, @"RECOVERED-BODY-B", 20);
	OAK_ASSERT_NE([html rangeOfString:@"RECOVERED-BODY-B"].location, NSNotFound);
	OAK_ASSERT(wait_for_warning(pane, NO, 20));

	on_main(^{
		pane.active = NO;
		pane.document = nil;
		window.contentView = nil;
		[goodDocument close];
		[badDocument close];
	});
}

// The cross-directory variant: the switch reloads the shell, so on top of the
// clear this pins that no stale pending content resurrects the old document’s
// body into the new, failing document’s page.
void test_cross_directory_failure_never_shows_the_old_document ()
{
	test::jail_t oldJail, newJail;
	oldJail.set_content("good.txt", "STALE-BODY-A");
	newJail.set_content("bad.txt", "FAIL-AT-ONCE-B");

	OakDocument* goodDocument = loaded_document(oldJail.path("good.txt"), @"source.pane-test");
	OakDocument* badDocument  = loaded_document(newJail.path("bad.txt"), @"source.pane-test-flaky");
	OAK_ASSERT(goodDocument && badDocument);

	__block NSWindow* window;
	__block MarkdownPreviewView* pane;

	on_main(^{
		window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 400, 600) styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
		pane = [[MarkdownPreviewView alloc] initWithFrame:NSMakeRect(0, 0, 400, 600)];
		window.contentView = pane;

		pane.document = goodDocument;
		pane.active   = YES;
	});

	NSString* html = wait_for_content(pane, @"STALE-BODY-A", 20);
	OAK_ASSERT_NE([html rangeOfString:@"STALE-BODY-A"].location, NSNotFound);

	on_main(^{ pane.document = badDocument; });
	OAK_ASSERT(wait_for_warning(pane, YES, 20));

	for(size_t i = 0; i < 5; ++i)
	{
		html = page_content(pane);
		OAK_ASSERT_EQ(to_s(html), "");
		usleep(100'000);
	}

	on_main(^{
		pane.active = NO;
		pane.document = nil;
		window.contentView = nil;
		[goodDocument close];
		[badDocument close];
	});
}

// The other half of the failure contract: while the failing render is for the
// document already on screen, its last good body stays put under the ⚠︎.
void test_same_document_failure_keeps_content ()
{
	test::jail_t jail;
	jail.set_content("doc.txt", "GOOD-BODY-ONE");

	OakDocument* doc = loaded_document(jail.path("doc.txt"), @"source.pane-test-flaky");
	OAK_ASSERT(doc != nil);

	__block NSWindow* window;
	__block MarkdownPreviewView* pane;

	on_main(^{
		window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 400, 600) styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
		pane = [[MarkdownPreviewView alloc] initWithFrame:NSMakeRect(0, 0, 400, 600)];
		window.contentView = pane;

		pane.document = doc;
		pane.active   = YES;
	});

	NSString* html = wait_for_content(pane, @"GOOD-BODY-ONE", 20);
	OAK_ASSERT_NE([html rangeOfString:@"GOOD-BODY-ONE"].location, NSNotFound);

	on_main(^{ doc.content = @"NOW-PLEASE-FAIL"; });
	OAK_ASSERT(wait_for_warning(pane, YES, 20));

	for(size_t i = 0; i < 5; ++i)
	{
		html = page_content(pane);
		OAK_ASSERT_NE([html rangeOfString:@"GOOD-BODY-ONE"].location, NSNotFound);
		usleep(100'000);
	}

	// …and a later good render replaces it and clears the ⚠︎.
	on_main(^{ doc.content = @"GOOD-BODY-TWO"; });
	html = wait_for_content(pane, @"GOOD-BODY-TWO", 20);
	OAK_ASSERT_NE([html rangeOfString:@"GOOD-BODY-TWO"].location, NSNotFound);
	OAK_ASSERT(wait_for_warning(pane, NO, 20));

	on_main(^{
		pane.active = NO;
		pane.document = nil;
		window.contentView = nil;
		[doc close];
	});
}

// Clicking the ⚠︎ presents the full diagnostic in the classic HTML output
// window. Tests in this suite run in parallel, so the window is matched by
// the diagnostic on its page, never by mere existence.
void test_warning_click_opens_diagnostic_window ()
{
	test::jail_t jail;
	jail.set_content("bad.txt", "FAIL-FOR-THE-DIAGNOSTIC-WINDOW");

	OakDocument* doc = loaded_document(jail.path("bad.txt"), @"source.pane-test-flaky");
	OAK_ASSERT(doc != nil);

	__block NSWindow* window;
	__block MarkdownPreviewView* pane;

	on_main(^{
		window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 400, 600) styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
		pane = [[MarkdownPreviewView alloc] initWithFrame:NSMakeRect(0, 0, 400, 600)];
		window.contentView = pane;

		pane.document = doc;
		pane.active   = YES;
	});
	OAK_ASSERT(wait_for_warning(pane, YES, 20));

	on_main(^{ [warning_button_in(pane) performClick:nil]; });

	// The page carries the runner’s summary line and the converter’s stderr.
	__block NSWindow* diagnosticWindow = nil;
	NSString* pageText = nil;
	NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:20];
	while([deadline timeIntervalSinceNow] > 0 && !diagnosticWindow)
	{
		__block NSArray<NSView*>* outputViews;
		on_main(^{
			NSMutableArray<NSView*>* views = [NSMutableArray array];
			for(NSWindow* candidate in NSApplication.sharedApplication.windows)
			{
				if([candidate.contentView isKindOfClass:[OakHTMLOutputView class]])
					[views addObject:candidate.contentView];
			}
			outputViews = views;
		});

		for(NSView* view in outputViews)
		{
			id text = evaluate_js_in_web_view([(OakHTMLOutputView*)view webView], @"document.body ? document.body.innerText : ''");
			if([text isKindOfClass:[NSString class]] && [text rangeOfString:@"FAIL-FOR-THE-DIAGNOSTIC-WINDOW"].location != NSNotFound)
			{
				pageText = text;
				on_main(^{ diagnosticWindow = view.window; });
				break;
			}
		}
		usleep(100'000);
	}
	OAK_ASSERT(diagnosticWindow != nil);
	OAK_ASSERT_NE([pageText rangeOfString:@"flaky converter refused"].location, NSNotFound);
	OAK_ASSERT_NE([pageText rangeOfString:@"exited with status 1"].location, NSNotFound);

	// The window title identifies the previewed document, via the page title
	// binding — asynchronous, hence polled.
	__block BOOL titled = NO;
	deadline = [NSDate dateWithTimeIntervalSinceNow:10];
	while([deadline timeIntervalSinceNow] > 0 && !titled)
	{
		on_main(^{ titled = [diagnosticWindow.title isEqualToString:@"Preview: bad.txt"]; });
		if(!titled)
			usleep(100'000);
	}
	OAK_ASSERT(titled);

	on_main(^{
		[diagnosticWindow close];
		pane.active = NO;
		pane.document = nil;
		window.contentView = nil;
		[doc close];
	});
}

// Each rendered code block gains exactly one copy control, whose click ends
// with the block’s text on the general pasteboard: the app side writes it,
// because navigator.clipboard is unreliable in a custom-scheme page.
void test_copy_button_copies_code_block ()
{
	__block NSWindow* window;
	__block MarkdownPreviewView* pane;
	__block OakDocument* doc;

	on_main(^{
		window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 400, 600) styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
		pane = [[MarkdownPreviewView alloc] initWithFrame:NSMakeRect(0, 0, 400, 600)];
		window.contentView = pane;

		doc = [OakDocument documentWithString:@"copy me ABC123" fileType:@"source.pane-test" customName:@"copy-test"];
		[doc loadModalForWindow:nil completionHandler:nil];

		pane.document = doc;
		pane.active   = YES;
	});

	NSString* html = wait_for_content(pane, @"copy me ABC123", 20);
	OAK_ASSERT_NE([html rangeOfString:@"copy me ABC123"].location, NSNotFound);

	// One control per block, attached to a wrapper — inside the pre it would
	// scroll with the code and leak into a manual select-all copy.
	id counts = evaluate_js(pane, @"JSON.stringify([document.querySelectorAll('#content pre').length, document.querySelectorAll('#content .tm-pre > button.tm-copy').length, document.querySelectorAll('#content button.tm-copy').length])");
	OAK_ASSERT_EQ(to_s((NSString*)counts), "[1,1,1]");

	// Decoration is per-render: a re-render must not stack a second button.
	on_main(^{ doc.content = @"copy me XYZ789"; });
	html = wait_for_content(pane, @"copy me XYZ789", 20);
	OAK_ASSERT_NE([html rangeOfString:@"copy me XYZ789"].location, NSNotFound);
	counts = evaluate_js(pane, @"JSON.stringify([document.querySelectorAll('#content pre').length, document.querySelectorAll('#content button.tm-copy').length])");
	OAK_ASSERT_EQ(to_s((NSString*)counts), "[1,1]");

	std::lock_guard<std::mutex> lock(pasteboard_mutex());
	seed_pasteboard(@"sentinel-before-copy");

	// A page-world .click() still reaches the button’s listener, which now lives
	// in the isolated world: it flips to the checkmark and posts the block text
	// on its own channel, and the app writes the pasteboard asynchronously.
	id clicked = evaluate_js(pane, @"(function(){ var button = document.querySelector('#content button.tm-copy'); button.click(); return button.classList.contains('tm-copied'); })()");
	OAK_ASSERT([clicked respondsToSelector:@selector(boolValue)] && [clicked boolValue]);

	NSString* pasteboard = wait_for_pasteboard(@"copy me XYZ789", 10);
	OAK_ASSERT_EQ(to_s(pasteboard), "copy me XYZ789");

	on_main(^{
		pane.active = NO;
		pane.document = nil;
		window.contentView = nil;
		[doc close];
	});
}

// The click that ends a drag-selection must stay in the preview — no jump,
// no focus loss — while a plain click still jumps, and the copy button’s
// click never reaches the jump listener. Observed through a webkit shim, so
// the test sees exactly what would have been posted without a partner text
// view; the sourcepos hold-off must fire either way.
void test_selection_click_does_not_jump ()
{
	__block NSWindow* window;
	__block MarkdownPreviewView* pane;
	__block OakDocument* doc;

	on_main(^{
		window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 400, 600) styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
		pane = [[MarkdownPreviewView alloc] initWithFrame:NSMakeRect(0, 0, 400, 600)];
		window.contentView = pane;

		doc = [OakDocument documentWithString:@"select me PQR456" fileType:@"source.pane-test" customName:@"selection-test"];
		[doc loadModalForWindow:nil completionHandler:nil];

		pane.document = doc;
		pane.active   = YES;
	});

	NSString* html = wait_for_content(pane, @"select me PQR456", 20);
	OAK_ASSERT_NE([html rangeOfString:@"select me PQR456"].location, NSNotFound);

	// The copy button’s click (last step) now runs its listener in the isolated
	// world and writes the pasteboard, so keep it off the other pasteboard
	// tests. The page-world shim only sees page-world posts: the selected click
	// posts nothing, the plain click posts its sourcepos, and the copy click —
	// ignored by the page-world jump listener via .tm-copy — posts nothing here.
	std::lock_guard<std::mutex> lock(pasteboard_mutex());
	id result = evaluate_js(pane,
		@"(function(){"
		 "  var saved = window.webkit;"
		 "  var posts = [];"
		 "  window.webkit = { messageHandlers: { tmPreview: { postMessage: function(m){ posts.push(typeof m === 'string' ? m : 'copy:' + m.text); } } } };"
		 "  var el = document.querySelector('#content [data-sourcepos]');"
		 "  var range = document.createRange();"
		 "  range.selectNodeContents(el);"
		 "  var selection = window.getSelection();"
		 "  selection.removeAllRanges();"
		 "  selection.addRange(range);"
		 "  el.dispatchEvent(new MouseEvent('click', { bubbles: true }));"
		 "  var postsWhileSelected = posts.length;"
		 "  var scrollHeldWhileSelected = Date.now() < window.__tmUserScrollUntil;"
		 "  selection.removeAllRanges();"
		 "  el.dispatchEvent(new MouseEvent('click', { bubbles: true }));"
		 "  document.querySelector('#content button.tm-copy').click();"
		 "  window.webkit = saved;"
		 "  return JSON.stringify([postsWhileSelected, scrollHeldWhileSelected].concat(posts));"
		 "})()");
	OAK_ASSERT_EQ(to_s((NSString*)result), "[0,true,\"1:1\"]");

	on_main(^{
		pane.active = NO;
		pane.document = nil;
		window.contentView = nil;
		[doc close];
	});
}

// The legitimate copy path, driven inside the copy control’s own world: the
// test obtains that world by name (worldWithName: is idempotent), clicks the
// button there, and the block’s text lands on the pasteboard through the
// isolated tmPreviewCopy channel.
void test_copy_control_isolated_world_copies ()
{
	__block NSWindow* window;
	__block MarkdownPreviewView* pane;
	__block OakDocument* doc;

	on_main(^{
		window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 400, 600) styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
		pane = [[MarkdownPreviewView alloc] initWithFrame:NSMakeRect(0, 0, 400, 600)];
		window.contentView = pane;

		doc = [OakDocument documentWithString:@"isolated copy LMN321" fileType:@"source.pane-test" customName:@"isolated-copy-test"];
		[doc loadModalForWindow:nil completionHandler:nil];

		pane.document = doc;
		pane.active   = YES;
	});

	NSString* html = wait_for_content(pane, @"isolated copy LMN321", 20);
	OAK_ASSERT_NE([html rangeOfString:@"isolated copy LMN321"].location, NSNotFound);

	WKContentWorld* copyWorld = [WKContentWorld worldWithName:kCopyWorldName];

	std::lock_guard<std::mutex> lock(pasteboard_mutex());
	seed_pasteboard(@"sentinel-before-isolated-copy");

	// Clicking the button in its own world runs the very listener a user click
	// would, and flips it to the checkmark.
	id clicked = evaluate_js_in_world(pane, copyWorld, @"(function(){ var button = document.querySelector('#content button.tm-copy'); if(!button) return false; button.click(); return button.classList.contains('tm-copied'); })()");
	OAK_ASSERT([clicked respondsToSelector:@selector(boolValue)] && [clicked boolValue]);

	NSString* pasteboard = wait_for_pasteboard(@"isolated copy LMN321", 10);
	OAK_ASSERT_EQ(to_s(pasteboard), "isolated copy LMN321");

	on_main(^{
		pane.active = NO;
		pane.document = nil;
		window.contentView = nil;
		[doc close];
	});
}

// A document-derived onerror handler — carried into the page verbatim because
// the Markdown renderer runs cmark UNSAFE — tries to drive the clipboard, once
// through the page-world tmPreview channel (with the old copy dict body) and
// once by naming the isolated channel from the page world. Neither reaches the
// pasteboard: the dict body is no longer honored, and tmPreviewCopy does not
// exist in the page world. The sentinel stands.
void test_document_payload_cannot_write_pasteboard ()
{
	__block NSWindow* window;
	__block MarkdownPreviewView* pane;
	__block OakDocument* doc;

	std::lock_guard<std::mutex> lock(pasteboard_mutex());
	seed_pasteboard(@"sentinel-vs-payload");

	on_main(^{
		window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 400, 600) styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
		pane = [[MarkdownPreviewView alloc] initWithFrame:NSMakeRect(0, 0, 400, 600)];
		window.contentView = pane;

		// A broken image whose onerror fires as soon as the fragment is inserted.
		doc = [OakDocument documentWithString:@"<img src=x onerror=\"try{webkit.messageHandlers.tmPreview.postMessage({action:'copy',text:'PWNED-BY-PAYLOAD'})}catch(e){}; try{webkit.messageHandlers.tmPreviewCopy.postMessage('PWNED-BY-PAYLOAD')}catch(e){}\">" fileType:@"text.html.markdown" customName:@"payload.md"];
		[doc loadModalForWindow:nil completionHandler:nil];

		pane.document = doc;
		pane.active   = YES;
	});

	// The image element (with its onerror) reaches #content, so the handler has
	// certainly run by the time it does.
	NSString* html = wait_for_content(pane, @"onerror", 20);
	OAK_ASSERT_NE([html rangeOfString:@"onerror"].location, NSNotFound);

	// Give any clipboard write time to land, then confirm none did.
	for(size_t i = 0; i < 5; ++i)
	{
		OAK_ASSERT_EQ(to_s(pasteboard_string()), "sentinel-vs-payload");
		usleep(100'000);
	}

	on_main(^{
		pane.active = NO;
		pane.document = nil;
		window.contentView = nil;
		[doc close];
	});
}

// The same boundary against a script evaluating directly in the page world:
// posting the old copy dict to tmPreview is ignored, and tmPreviewCopy is not
// exposed there at all (a TypeError, swallowed). The sentinel is untouched.
void test_page_world_spoof_cannot_write_pasteboard ()
{
	__block NSWindow* window;
	__block MarkdownPreviewView* pane;
	__block OakDocument* doc;

	on_main(^{
		window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 400, 600) styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
		pane = [[MarkdownPreviewView alloc] initWithFrame:NSMakeRect(0, 0, 400, 600)];
		window.contentView = pane;

		doc = [OakDocument documentWithString:@"spoof target STU654" fileType:@"source.pane-test" customName:@"spoof-test"];
		[doc loadModalForWindow:nil completionHandler:nil];

		pane.document = doc;
		pane.active   = YES;
	});

	NSString* html = wait_for_content(pane, @"spoof target STU654", 20);
	OAK_ASSERT_NE([html rangeOfString:@"spoof target STU654"].location, NSNotFound);

	std::lock_guard<std::mutex> lock(pasteboard_mutex());
	seed_pasteboard(@"sentinel-vs-page-spoof");

	// Both spoof attempts run in the page world; tmPreviewCopy is absent there,
	// so the second throws — caught, so evaluation still returns cleanly.
	id ran = evaluate_js(pane,
		@"(function(){"
		 "  try { webkit.messageHandlers.tmPreview.postMessage({ action: 'copy', text: 'PWNED-BY-PAGE' }); } catch(e) {}"
		 "  var reachedCopyChannel = false;"
		 "  try { webkit.messageHandlers.tmPreviewCopy.postMessage('PWNED-BY-PAGE'); reachedCopyChannel = true; } catch(e) {}"
		 "  return reachedCopyChannel;"
		 "})()");
	OAK_ASSERT([ran respondsToSelector:@selector(boolValue)] && ![ran boolValue]); // the copy channel is not reachable from the page world

	for(size_t i = 0; i < 5; ++i)
	{
		OAK_ASSERT_EQ(to_s(pasteboard_string()), "sentinel-vs-page-spoof");
		usleep(100'000);
	}

	on_main(^{
		pane.active = NO;
		pane.document = nil;
		window.contentView = nil;
		[doc close];
	});
}
