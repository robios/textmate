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

- (void)addAuxiliaryView:(NSView*)aView atEdge:(NSRectEdge)anEdge;
- (void)removeAuxiliaryView:(NSView*)aView;

- (IBAction)showSymbolChooser:(id)sender;

- (void)updateCursorLine:(NSUInteger)line;
- (void)invalidateCodeActionProbe;
@end
