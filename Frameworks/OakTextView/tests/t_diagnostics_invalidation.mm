#import "../src/OakTextView.h"
#import <document/OakDocument.h>
#import <objc/runtime.h>
#import <objc/message.h>

// The clamp in -documentDiagnosticsDidChange: has to allow an extent ending one
// past the last byte, because that is where a point diagnostic on a trailing
// empty line ends. Clamped at the buffer size instead, the extent lands exactly
// on the start of that line's row — and a half-open extent deliberately spares
// the row it ends on, so the marker for the diagnostic that just changed would
// never be repainted.
//
// Asserting that needs the rects the view invalidates. A test subclass
// overriding -setNeedsDisplayInRect: is the obvious way and cannot be written
// here: gen_test wraps every test file in a namespace, and an Objective-C
// @interface may only appear at global scope. The runtime has no such
// restriction, so the subclass is built with objc_allocateClassPair instead.

static NSMutableArray<NSValue*>* RecordedRects;

static Class recording_text_view_class ()
{
	static Class res = Nil;
	if(!res)
	{
		res = objc_allocateClassPair([OakTextView class], "OakTextViewRecordingInvalidations", 0);
		IMP imp = imp_implementationWithBlock(^(OakTextView* self, NSRect rect){
			[RecordedRects addObject:[NSValue valueWithRect:rect]];

			struct objc_super superInfo = { self, [OakTextView class] };
			((void(*)(struct objc_super*, SEL, NSRect))objc_msgSendSuper)(&superInfo, @selector(setNeedsDisplayInRect:), rect);
		});
		class_addMethod(res, @selector(setNeedsDisplayInRect:), imp, "v@:{CGRect={CGPoint=dd}{CGSize=dd}}");
		objc_registerClassPair(res);
	}
	return res;
}

static BOOL recorded_rect_covers (CGFloat minY, CGFloat maxY)
{
	for(NSValue* value in RecordedRects)
	{
		NSRect const rect = value.rectValue;
		if(NSMinY(rect) <= minY && maxY <= NSMaxY(rect))
			return YES;
	}
	return NO;
}

static NSDictionary* lsp_diagnostic (NSUInteger line, NSUInteger character, NSUInteger endLine, NSUInteger endCharacter, NSInteger severity)
{
	return @{
		@"line":         @(line),
		@"character":    @(character),
		@"endLine":      @(endLine),
		@"endCharacter": @(endCharacter),
		@"severity":     @(severity),
		@"message":      @"boom",
	};
}

// AppKit is main-thread only while the runner drives test functions from a
// global queue — same hop as t_diagnostics_pane.mm, which also serializes this
// against the other view tests.
static void on_main (void(^block)(void))
{
	if(NSThread.isMainThread)
			block();
	else	dispatch_sync(dispatch_get_main_queue(), block);
}

// One test function: it registers a document with the shared
// OakDocumentController, which the parallel runner must not race.
void test_diagnostics_invalidation ()
{
	on_main(^{
		OakDocument* doc = [OakDocument documentWithString:@"" fileType:@"text.plain" customName:@"diagnostics-invalidation"];
		doc.content = @"abc\n"; // line 1 is the trailing empty line, at index 4 == size
		[doc loadModalForWindow:nil completionHandler:nil]; // an untitled document loads from memory, synchronously

		// In a window because the refresh cycle intersects its damage with the
		// view's visible rect, and a view with no window has nothing visible.
		NSWindow* window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 600, 400) styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
		OakTextView* textView = [[recording_text_view_class() alloc] initWithFrame:NSMakeRect(0, 0, 600, 400)];
		window.contentView = textView;
		textView.document = doc;

		// The row the point sits on, in the view's own coordinates
		GVLineRecord const trailingLine = [textView lineFragmentForLine:1 column:0];
		OAK_ASSERT(trailingLine.lineNumber != NSNotFound);
		OAK_ASSERT_LT(trailingLine.firstY, trailingLine.lastY);

		// A publish whose furthest change is the point on that line. It has to
		// arrive with an earlier change, or `from == to` would take the
		// single-row path and prove nothing about the clamp.
		[doc setDiagnostics:@[ lsp_diagnostic(0, 0, 0, 3, 1), lsp_diagnostic(1, 0, 1, 0, 1) ]];

		RecordedRects = [NSMutableArray new];
		[doc setDiagnostics:@[ lsp_diagnostic(0, 1, 0, 3, 1), lsp_diagnostic(1, 0, 1, 0, 2) ]];

		OAK_ASSERT_GT(RecordedRects.count, 0); // nothing invalidated at all would pass the real check vacuously
		OAK_ASSERT(recorded_rect_covers(trailingLine.firstY, trailingLine.lastY));

		RecordedRects = nil;
		textView.document = nil;
		window.contentView = nil;
		[doc close]; // balances the load above, which opens the document
	});
}
