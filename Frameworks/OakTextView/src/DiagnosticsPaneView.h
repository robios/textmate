#import <Cocoa/Cocoa.h>
#import <lsp/LSPDiagnosticsStore.h>

// The cross-file diagnostics list: every problem the window's language
// servers have published, grouped by file. The squiggles say where a problem
// is inside the file you are looking at; this says which files have problems
// at all — including files you never opened, which is the half no in-editor
// surface can cover.
//
// Same hosting and lifecycle contract as DiffPaneView: a documentView inside
// a scroller-less NSScrollView, and while inactive the snapshot and the row
// views are released. Filter and expansion state outlive that teardown,
// because they are the reader's, not the data's.
@interface DiagnosticsPaneView : NSView
@property (nonatomic, getter=isActive) BOOL active;

// The window-scoped snapshot from LSPManager. Rebuilds the row model; the
// caller coalesces publish bursts, the pane does not.
- (void)takeSnapshot:(LSPDiagnosticsSnapshot*)aSnapshot;

// The reader's own state rather than the data's, which is why both outlive the
// teardown that closing the pane does: the filter, and the file groups that
// were collapsed (expanded is the default, so the set records the exceptions).
@property (nonatomic) BOOL errorsOnly;
@property (nonatomic, readonly) NSSet<NSString*>* collapsedFilePaths;

// The rows on display, after the filter — file headers and diagnostics both,
// in the order they are listed.
@property (nonatomic, readonly) NSInteger numberOfRows;

// The reader's place in the list, or -1 for none. A rebuild re-finds it by what
// it names — file and position — since the row objects themselves are replaced.
@property (nonatomic) NSInteger selectedRow;

// What a click does: a file row toggles its group, a diagnostic row calls
// openLocationHandler.
- (void)activateRow:(NSInteger)row;

@property (nonatomic) NSColor* themeBackgroundColor;
@property (nonatomic) NSColor* themeForegroundColor;

// Owner hooks. openLocationHandler carries LSP coordinates — 0-based line and
// 0-based UTF-16 column — because the pane has no buffer to convert them
// against, and cross-file rows point at documents that are not even loaded.
@property (nonatomic, copy) void (^closeHandler)(void);
@property (nonatomic, copy) void (^openLocationHandler)(NSURL* fileURL, NSUInteger line, NSUInteger column);
@end
