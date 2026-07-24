#import <Cocoa/Cocoa.h>
#import <theme/theme.h>
#import "BufferDiffService.h"

@class OakDocument;

// The git-native review pane: a scrolling list of every hunk in the
// current document, diffed against the window's review base — the
// per-file change list a git front end shows. Gutter and minimap say
// where the changes are inside the editor; this pane shows all of them
// at once, in document order.
//
// Same lifecycle contract as MarkdownPreviewView: while inactive the
// card views are torn down.
@interface DiffPaneView : NSView
@property (nonatomic) OakDocument* document;   // header name + grammar; the pane follows the active tab
@property (nonatomic, getter=isActive) BOOL active;

// Latest buffer-diff result. Rebuilds the card list, preserving the
// scroll position by re-anchoring to the topmost visible hunk.
- (void)takeSnapshot:(BufferDiffSnapshot*)aSnapshot;

// 1-indexed caret line. Only moves the active-card highlight — never
// rebuilds or scrolls the list, so browsing it stays under the reader's
// control.
@property (nonatomic) NSUInteger caretLine;

// Step to the neighbouring card, scrolling it into view and moving the
// editor caret with it (via moveCaretHandler).
- (BOOL)selectNextHunk;
- (BOOL)selectPreviousHunk;
@property (nonatomic, readonly) BOOL canSelectNextHunk;
@property (nonatomic, readonly) BOOL canSelectPreviousHunk;

@property (nonatomic) NSColor* themeBackgroundColor;
@property (nonatomic) NSColor* themeForegroundColor;

// The editor gutter's own colors and line-number font. The pane's two
// line-number columns reuse them verbatim, so the diff's numbers read as
// the same gutter the buffer has. nil → derived from the theme fore/back.
@property (nonatomic) NSColor* gutterForegroundColor;
@property (nonatomic) NSColor* gutterBackgroundColor;
@property (nonatomic) NSColor* gutterDividerColor;
@property (nonatomic) NSFont* lineNumberFont;

// The editor's own line height. The pane matches it row for row, so a
// diff line and the buffer line it came from are the same height. 0 →
// derived from the font, which does not agree with the editor's layout.
@property (nonatomic) CGFloat editorLineHeight;

// The editor's theme (the layout's instance, which has the displayed
// font name/size baked in) — the pane renders with the same font as the
// main buffer and highlights card bodies with the theme's scope styles.
// nil → monospaced fallback, no highlighting.
@property (nonatomic) theme_ptr theme;

// Owner hooks.
@property (nonatomic, copy) void (^closeHandler)(void);
@property (nonatomic, copy) void (^moveCaretHandler)(NSUInteger line);  // 1-indexed buffer line
@property (nonatomic, copy) void (^selectBaseRefHandler)(NSString* ref); // base selector choice; nil → HEAD

// One-line banner strip under the header (HEAD-moved notices). An
// actionTitle of nil shows a passive, dismiss-only note.
- (void)showBannerWithMessage:(NSString*)aMessage actionTitle:(NSString*)aTitle handler:(void(^)(void))aHandler;
- (void)dismissBanner;
@end
