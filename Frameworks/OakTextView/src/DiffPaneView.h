#import <Cocoa/Cocoa.h>
#import <theme/theme.h>

@class OakDocument;

typedef NS_ENUM(NSInteger, DiffPaneViewMode) {
	DiffPaneViewModeUnified = 0, // classic unified diff of the base vs the compared contents
	DiffPaneViewModeApplied = 1, // full compared contents; changed/added regions highlighted, deletions marked
};

// Read-only diff pane (in-process xdiff — no subprocess). Same lifecycle
// contract as MarkdownPreviewView: while inactive the text view is torn down.
//
// Two view modes, toggled by the header's segmented control and by Space
// (Quick Look style) when the pane's own text view has focus.
//
// The content source is being rewired to buffer-vs-git-review-base — see
// AI_COMPANION_GIT_NATIVE_DESIGN.md phase B. Until then the pane keeps its
// disk-baseline renderer but has no driver.
@interface DiffPaneView : NSView
@property (nonatomic) OakDocument* document;
@property (nonatomic, getter=isActive) BOOL active;

// LF-normalized full contents to compare against the baseline.
@property (nonatomic) NSString* comparedContents;

@property (nonatomic) DiffPaneViewMode viewMode;
- (void)toggleViewMode;

@property (nonatomic) NSColor* themeBackgroundColor;
@property (nonatomic) NSColor* themeForegroundColor;

// The editor’s theme (the layout’s instance, which has the displayed font
// name/size baked in via copy_with_font_name_and_size) — the pane renders
// with the same font as the main buffer and, in the Applied view, uses the
// theme’s scope styles for syntax highlighting. nil → monospaced fallback,
// no highlighting.
@property (nonatomic) theme_ptr theme;

// Trailing note in the pane's header line, after the file name.
@property (nonatomic) NSString* statusText;

// Invoked by the pane's close button; the owner just hides the pane.
@property (nonatomic, copy) void (^closeHandler)(void);

// Forwarded after saves: disk changed, so the diff base must be re-read.
- (void)documentDidSave;
@end
