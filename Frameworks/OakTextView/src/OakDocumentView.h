#import "OakTextView.h"
#import <oak/debug.h>

@class OakDocument;
@class OakReviewBase;

@interface OakDocumentView : NSView
@property (nonatomic, readonly) OakTextView* textView;
@property (nonatomic) OakDocument* document;
@property (nonatomic) BOOL hideStatusBar;

// The base every git-aware surface in this view compares against. Set by
// the window that hosts the view, so its lifetime is the window's rather
// than this view's; a view that is never given one keeps a private base
// of its own, which behaves the same for a lone editor.
@property (nonatomic) OakReviewBase* reviewBase;

// The review base as it took effect for the current document — "HEAD" or
// a resolved commit sha — or nil outside a git repository. Read from the
// last snapshot, so it names what the diff was actually taken against
// (a pinned sha in the wrong repo, or a relative spec past the root, both
// come back as "HEAD"). This is what the window exports as TM_REVIEW_BASE.
- (NSString*)resolvedReviewBaseRef;

- (IBAction)toggleLineNumbers:(id)sender;
- (IBAction)toggleMinimap:(id)sender;
- (IBAction)toggleDiffPane:(id)sender;
- (IBAction)selectNextDiffHunk:(id)sender;
- (IBAction)selectPreviousDiffHunk:(id)sender;
- (IBAction)toggleDiagnosticsPane:(id)sender;

// The window's project roots, which scope the diagnostics pane to the servers
// that serve this window. Empty falls back to the active document's directory,
// which is what a window with no project root supplies anyway.
@property (nonatomic, copy) NSArray<NSString*>* diagnosticsWorkspaceRoots;

// Where a diagnostics row sends the reader. LSP coordinates: 0-based line,
// 0-based UTF-16 column. A view with no handler navigates within its own
// document and ignores rows for other files — opening a tab is the window's
// job, not the editor view's.
@property (nonatomic, copy) void (^openDiagnosticLocationHandler)(NSURL* fileURL, NSUInteger line, NSUInteger column);

- (void)addAuxiliaryView:(NSView*)aView atEdge:(NSRectEdge)anEdge;
- (void)removeAuxiliaryView:(NSView*)aView;

- (IBAction)showSymbolChooser:(id)sender;

- (void)updateCursorLine:(NSUInteger)line;
- (void)invalidateCodeActionProbe;
@end
