#import <Cocoa/Cocoa.h>

@class OakDocument;
@class OakTextView;

// Draggable divider between the editor area and a companion pane (used by the
// diff pane): a thin theme-colored line centered in a wider grab strip.
// Dragging reports the suggested new width of the view to its right via
// widthChangeHandler.
@interface MarkdownPreviewDividerView : NSView
@property (nonatomic) NSColor* backgroundColor;
@property (nonatomic) NSColor* lineColor;
@property (nonatomic, weak) NSView* resizedView;
@property (nonatomic, copy) void (^widthChangeHandler)(CGFloat newWidth);
@end

// Live preview pane. Markdown renders in-process via cmark-gfm; any scope
// whose bundle declares a `previewCommand` setting renders through that
// external converter instead (see docs/preview.md). Either way the
// pane is a pure read-only observer of the document: buffer change callbacks
// → debounce → off-main render → innerHTML patch; the page itself is loaded
// only once per baseURL. While inactive the web view is torn down, no
// callbacks are registered, and no converter runs — a converter only ever
// executes while the pane is open, and closing the pane kills it.
//
// The view observes its document’s notifications itself (content changed,
// saved, will close), so the owner only re-targets `document` — e.g. when
// the active tab switches to another previewable document — and calls
// `refreshConverter` when the document’s file type changes in place. When
// the previewed document closes, or loses its converter, the renderer
// detaches but the last render stays on screen until the pane is
// re-targeted.
//
// A header strip above the page names the previewed document and carries the
// close control: the preview keeps showing the last previewable document
// after the active tab moves on to something else, so without a name on it
// there is nothing saying WHAT is on screen. After an external converter
// fails, the header also shows a clickable ⚠︎ carrying the diagnostic.
//
// `textView` enables editor → preview scroll sync and click-to-jump; the
// owner should set it to nil while the text view shows a different document
// than the previewed one, so sync and jumps never target the wrong buffer.
@interface MarkdownPreviewView : NSView
@property (nonatomic, weak) OakTextView* textView;
@property (nonatomic) OakDocument* document;
@property (nonatomic, getter=isActive) BOOL active;

// Re-resolves the document’s preview converter (built-in, external, or none)
// after a file-type change; a no-op when the resolution is unchanged.
- (void)refreshConverter;

// Owner hook: the header's close control (the pane has no other way to
// dismiss itself).
@property (nonatomic, copy) void (^closeHandler)(void);

// Editor theme colors, exposed to the shell page as CSS variables. The
// background also fills the view’s own layer, which shows through the
// transparent web view until the shell’s first themed paint.
@property (nonatomic) NSColor* themeBackgroundColor;
@property (nonatomic) NSColor* themeForegroundColor;
@end
