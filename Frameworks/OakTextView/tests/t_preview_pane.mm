#import "../src/MarkdownPreviewView.h"
#import <document/OakDocument.h>
#import <test/jail.h>
#import <ns/ns.h>
#import <WebKit/WebKit.h>

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

// Runs `script` in the pane’s page from the main run loop.
static id evaluate_js (MarkdownPreviewView* pane, NSString* script)
{
	__block id value = nil;
	dispatch_semaphore_t done = dispatch_semaphore_create(0);
	on_main(^{
		WKWebView* webView = web_view_in(pane);
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
