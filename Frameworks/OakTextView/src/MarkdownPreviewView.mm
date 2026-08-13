#import "MarkdownPreviewView.h"
#import "OakTextView.h"
#import "preview_converter.h"
#import "preview_command_runner.h"
#import <markdown/markdown_render.h>
#import <WebKit/WebKit.h>
#import <QuartzCore/QuartzCore.h>
#import <document/OakDocument.h>
#import <document/OakDocument Private.h>
#import <HTMLOutput/helpers/OakFileURLSchemeHandler.h>
#import <HTMLOutputWindow/HTMLOutputWindow.h>
#import <buffer/buffer.h>
#import <bundles/bundles.h>
#import <io/environment.h>
#import <theme/theme.h>
#import <ns/ns.h>
#import <atomic>

static CGFloat const kMarkdownPreviewMinWidth = 150;
static CGFloat const kMarkdownPreviewHeaderHeight = 24; // same band as the diff pane’s header
static NSTimeInterval const kRenderDebounceInterval = 0.25;
static NSTimeInterval const kExternalRenderDebounceInterval = 0.5; // external converters pay a process spawn per render — the in-process cadence would be pointless
static NSTimeInterval const kScrollSyncThrottleInterval = 0.1;

// The header takes its colors from the editor theme, like the rest of the
// pane: semantic system colors track the macOS appearance, NOT the theme, so
// secondaryLabelColor on a dark theme under a light system appearance is
// dark-on-dark. Dimmed foregrounds are the theme foreground blended toward
// the theme background, so they keep contrast on any theme.
static NSColor* BlendedColor (NSColor* from, NSColor* toward, CGFloat fraction)
{
	NSColor* fromRGB   = [from colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
	NSColor* towardRGB = [toward colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
	if(!fromRGB) // pattern/catalog color: fall back to something readable, never to the background
		return from ?: NSColor.textColor;
	NSColor* blended = towardRGB ? [fromRGB blendedColorWithFraction:fraction ofColor:towardRGB] : nil;
	return blended ?: fromRGB;
}

// ===============================
// = MarkdownPreviewDividerView  =
// ===============================

// In-editor pane divider, used by the diff pane (the Markdown preview itself
// is a window-level pane laid out by ProjectLayoutView, which has its own
// resize handling). Drawn purely with layer background colors — never via
// drawRect:. A plain sibling whose drawRect runs in the same window commit
// as OakTextView’s giant tiled layer causes AppKit to drop the tile render
// (the editor goes permanently blank); see the minimap commit for the
// original diagnosis.
@implementation MarkdownPreviewDividerView
{
	CALayer* _lineLayer;
}

- (id)initWithFrame:(NSRect)aRect
{
	if(self = [super initWithFrame:aRect])
	{
		self.wantsLayer = YES;
		_lineLayer = [CALayer layer];
		[self.layer addSublayer:_lineLayer];
		[self applyLayerColors];
	}
	return self;
}

- (void)setBackgroundColor:(NSColor*)aColor { _backgroundColor = aColor; [self applyLayerColors]; }
- (void)setLineColor:(NSColor*)aColor       { _lineColor = aColor;       [self applyLayerColors]; }

- (void)applyLayerColors
{
	[CATransaction begin];
	[CATransaction setDisableActions:YES];
	self.layer.backgroundColor = (self.backgroundColor ?: NSColor.windowBackgroundColor).CGColor;
	_lineLayer.backgroundColor = (self.lineColor ?: NSColor.separatorColor).CGColor;
	[CATransaction commit];
}

- (void)layout
{
	[super layout];
	[CATransaction begin];
	[CATransaction setDisableActions:YES];
	_lineLayer.frame = CGRectMake(floor(NSWidth(self.bounds) / 2), 0, 1, NSHeight(self.bounds));
	[CATransaction commit];
}

- (void)resetCursorRects
{
	[self addCursorRect:self.bounds cursor:NSCursor.resizeLeftRightCursor];
}

- (void)mouseDown:(NSEvent*)anEvent
{
	NSView* target = self.resizedView;
	if(!target || !self.widthChangeHandler)
		return;

	CGFloat const initialWidth = NSWidth(target.frame);
	CGFloat const startX       = anEvent.locationInWindow.x;

	while(true)
	{
		NSEvent* event = [self.window nextEventMatchingMask:NSEventMaskLeftMouseDragged|NSEventMaskLeftMouseUp];
		if(event.type == NSEventTypeLeftMouseUp)
			break;
		// The preview sits right of the divider: dragging left grows it.
		self.widthChangeHandler(std::max<CGFloat>(kMarkdownPreviewMinWidth, initialWidth + (startX - event.locationInWindow.x)));
	}
}
@end

// =============================
// = MarkdownPreviewHeaderView =
// =============================

// The pane’s title band: close control, then the previewed document’s name,
// and — only after an external converter failed — a warning control at the
// right edge. Modelled on the diff pane’s header, but — like the divider
// above — drawn with layer background colors instead of drawRect:.
@interface MarkdownPreviewHeaderView : NSView
@property (nonatomic) NSColor* backgroundColor;
@property (nonatomic) NSColor* separatorColor;
@property (nonatomic, readonly) NSTextField* titleField;
@property (nonatomic, readonly) NSButton* closeButton;
@property (nonatomic, readonly) NSButton* warningButton;
- (id)initWithFrame:(NSRect)aRect closeTarget:(id)aTarget closeAction:(SEL)anAction warningAction:(SEL)aWarningAction;
@end

@implementation MarkdownPreviewHeaderView
{
	CALayer* _separatorLayer;
}

- (id)initWithFrame:(NSRect)aRect closeTarget:(id)aTarget closeAction:(SEL)anAction warningAction:(SEL)aWarningAction
{
	if(self = [super initWithFrame:aRect])
	{
		self.wantsLayer = YES;
		_separatorLayer = [CALayer layer];
		[self.layer addSublayer:_separatorLayer];

		_closeButton = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"xmark.circle.fill" accessibilityDescription:@"Close Preview"] target:aTarget action:anAction];
		_closeButton.bordered = NO;
		_closeButton.toolTip  = @"Close preview";

		_titleField = [[NSTextField alloc] initWithFrame:NSZeroRect];
		_titleField.bordered        = NO;
		_titleField.editable        = NO;
		_titleField.selectable      = NO;
		_titleField.bezeled         = NO;
		_titleField.drawsBackground = NO;
		_titleField.font            = [NSFont systemFontOfSize:[NSFont systemFontSizeForControlSize:NSControlSizeSmall]];
		[[_titleField cell] setLineBreakMode:NSLineBreakByTruncatingMiddle]; // long names keep their extension visible, like the status-bar fields

		// Hidden until an external converter fails; the tooltip carries the
		// first lines of its stderr, clicking opens the full diagnostic.
		_warningButton = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"exclamationmark.triangle.fill" accessibilityDescription:@"Preview Command Failed"] target:aTarget action:aWarningAction];
		_warningButton.bordered         = NO;
		_warningButton.contentTintColor = NSColor.systemYellowColor; // semantic warning color on any theme, like the LSP lightbulb
		_warningButton.hidden           = YES;

		[self addSubview:_closeButton];
		[self addSubview:_titleField];
		[self addSubview:_warningButton];

		[self applyLayerColors];
	}
	return self;
}

- (void)setBackgroundColor:(NSColor*)aColor { _backgroundColor = aColor; [self applyLayerColors]; }
- (void)setSeparatorColor:(NSColor*)aColor  { _separatorColor  = aColor; [self applyLayerColors]; }

- (void)applyLayerColors
{
	[CATransaction begin];
	[CATransaction setDisableActions:YES];
	self.layer.backgroundColor = (self.backgroundColor ?: NSColor.textBackgroundColor).CGColor;
	_separatorLayer.backgroundColor = (self.separatorColor ?: NSColor.separatorColor).CGColor;
	[CATransaction commit];
}

- (void)layout
{
	[super layout];
	NSRect const bounds = self.bounds;

	[CATransaction begin];
	[CATransaction setDisableActions:YES];
	_separatorLayer.frame = CGRectMake(0, 0, NSWidth(bounds), 1); // hairline along the bottom, against the page
	[CATransaction commit];

	// close ⋅ title ⋅ warning, with the diff pane header’s 8 pt edge margin
	// and 10 pt group gap. The horizontal math uses alignment rects: a
	// borderless image button still carries invisible frame padding, so
	// frame-based gaps render wider than specified.
	CGFloat const edgeMargin = 8, sectionGap = 10, buttonSize = 16;

	NSRect const closeRect = NSMakeRect(edgeMargin, round((NSHeight(bounds) - buttonSize) / 2), buttonSize, buttonSize);
	_closeButton.frame = [_closeButton frameForAlignmentRect:closeRect];

	NSRect const warningRect = NSMakeRect(NSMaxX(bounds) - edgeMargin - buttonSize, round((NSHeight(bounds) - buttonSize) / 2), buttonSize, buttonSize);
	_warningButton.frame = [_warningButton frameForAlignmentRect:warningRect];

	[_titleField sizeToFit];
	CGFloat const x = NSMaxX(closeRect) + sectionGap;
	CGFloat const titleRight = _warningButton.hidden ? NSMaxX(bounds) - edgeMargin : NSMinX(warningRect) - sectionGap;
	CGFloat const titleHeight = NSHeight(_titleField.frame);
	_titleField.frame = NSMakeRect(x, round((NSHeight(bounds) - titleHeight) / 2), std::max<CGFloat>(0, titleRight - x), titleHeight);
}
@end

// =======================
// = MarkdownPreviewView =
// =======================

@interface MarkdownPreviewView () <WKNavigationDelegate, WKScriptMessageHandler>
- (void)bufferDidChange;
@end

// WKUserContentController retains its script message handlers; this weak
// forwarder keeps the web view from retaining the preview view in a cycle.
@interface MarkdownPreviewWeakMessageHandler : NSObject <WKScriptMessageHandler>
@property (nonatomic, weak) id <WKScriptMessageHandler> target;
@end

@implementation MarkdownPreviewWeakMessageHandler
- (void)userContentController:(WKUserContentController*)userContentController didReceiveScriptMessage:(WKScriptMessage*)message
{
	[self.target userContentController:userContentController didReceiveScriptMessage:message];
}
@end

namespace
{
	struct preview_buffer_callback_t : ng::callback_t
	{
		preview_buffer_callback_t (MarkdownPreviewView* view) : _view(view) { }
		void did_replace (size_t from, size_t to, char const* buf, size_t len) override { [_view bufferDidChange]; }
	private:
		__weak MarkdownPreviewView* _view;
	};
}

// Percent-encoded tm-file URL for an absolute path, so spaces in the app’s
// location survive the trip through the shell’s href/src attributes.
static NSString* TMFileURLString (NSString* path)
{
	NSURLComponents* components = [NSURLComponents new];
	components.scheme = @"tm-file";
	components.host   = @"";
	components.path   = path;
	return components.URL.absoluteString;
}

// The static page loaded once per baseURL; all updates patch #content. CSS
// falls back to prefers-color-scheme palettes unless the editor theme has
// injected --tm-bg/--tm-fg. TMPreview.scrollToLine implements the one-way
// editor → preview sync via cmark’s data-sourcepos attributes, and stands
// down for a second whenever the user scrolls the preview themselves.
// Assembled at runtime because the KaTeX tags reference the app bundle’s
// Resources/katex by absolute tm-file:// URL — same scheme handler that
// serves relative images; the assets load once per shell load, so per-render
// cost is zero. Math arrives in fragments as data-tm-math elements (see
// docs/preview.md) and is rendered by setContent’s math pass;
// missing KaTeX assets degrade to the raw TeX as plain text.
static NSString* MarkdownPreviewShell ()
{
	static NSString* shell;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		NSString* katexDir = [NSBundle.mainBundle.resourceURL URLByAppendingPathComponent:@"katex" isDirectory:YES].path;
		NSString* head = [NSString stringWithFormat:@"<!DOCTYPE html><html><head><meta charset='utf-8'>"
			"<link rel=\"stylesheet\" href=\"%@\"><script src=\"%@\"></script>",
			TMFileURLString([katexDir stringByAppendingPathComponent:@"katex.min.css"]),
			TMFileURLString([katexDir stringByAppendingPathComponent:@"katex.min.js"])];
		shell = [head stringByAppendingString:
	@"<style>"
	 ":root { color-scheme: light dark; --bg: #ffffff; --fg: #1f2328; --muted: #59636e; --border: #d1d9e0; --code-bg: rgba(129,139,152,0.15); }"
	 "@media (prefers-color-scheme: dark) { :root { --bg: #1e1e1e; --fg: #e8e8e8; --muted: #9198a1; --border: #3d444d; } }"
	 "html { background: var(--tm-bg, var(--bg)); }"
	 "body { background: var(--tm-bg, var(--bg)); color: var(--tm-fg, var(--fg));"
	 "  font: 15px/1.6 -apple-system, sans-serif; margin: 0; -webkit-text-size-adjust: 100%; }"
	 "article { max-width: 44em; margin: 0 auto; padding: 1.5em 2em 4em; box-sizing: border-box; }"
	 "h1, h2 { padding-bottom: 0.3em; border-bottom: 1px solid var(--border); }"
	 "h1:first-child, h2:first-child, h3:first-child, p:first-child { margin-top: 0; }"
	 "a { color: #4493f8; text-decoration: none; } a:hover { text-decoration: underline; }"
	 "@media (prefers-color-scheme: light) { a { color: #0969da; } }"
	 "code, pre { font: 0.9em/1.45 ui-monospace, Menlo, monospace; }"
	 "code { background: var(--code-bg); border-radius: 4px; padding: 0.15em 0.3em; }"
	 "pre { background: var(--code-bg); border-radius: 6px; padding: 1em; overflow-x: auto; }"
	 "pre code { background: none; padding: 0; }"
	 // The copy control floats over the block’s top-right corner from a wrapper
	 // around the pre — inside the pre it would ride along with its horizontal
	 // scrolling. Colors come from the same variables as the page, so both
	 // custom preview themes and the fallback palettes carry it.
	 ".tm-pre { position: relative; }"
	 ".tm-copy { position: absolute; top: 6px; right: 6px; width: 26px; height: 26px; padding: 0;"
	 "  display: flex; align-items: center; justify-content: center;"
	 "  color: var(--tm-fg, var(--fg)); background: var(--tm-bg, var(--bg)); border: 1px solid var(--border); border-radius: 6px;"
	 "  opacity: 0; transition: opacity 0.1s; cursor: pointer; -webkit-user-select: none; }"
	 ".tm-pre:hover .tm-copy, .tm-copy.tm-copied { opacity: 1; }"
	 ".tm-copy svg { width: 14px; height: 14px; display: block; }"
	 ".tm-copy .tm-copy-check { display: none; }"
	 ".tm-copy.tm-copied .tm-copy-icon { display: none; }"
	 ".tm-copy.tm-copied .tm-copy-check { display: block; }"
	 "blockquote { margin: 0; padding-left: 1em; border-left: 0.25em solid var(--border); color: var(--muted); }"
	 "table { display: block; width: max-content; max-width: 100%; overflow-x: auto;"
	 "  border-collapse: collapse; margin: 1em 0; }"
	 "th, td { padding: 0.55em 1.75em 0.55em 0; border-bottom: 1px solid var(--border); }"
	 "th:last-child, td:last-child { padding-right: 0; }"
	 "tbody tr:last-child td { border-bottom: none; }"
	 "th { font-weight: 600; border-bottom-width: 2px; }"
	 "th:not([align]) { text-align: left; }" // author CSS would override cmark’s align="…" hints, so only style unaligned headers
	 "thead:not(:has(th:not(:empty))) { display: none; }" // an all-empty header row is GFM’s headerless-table workaround, so drop its empty band
	 "img { max-width: 100%; }"
	 "hr { border: none; border-top: 1px solid var(--border); }"
	 "ul.contains-task-list { list-style: none; padding-left: 1em; }"
	 "[data-tm-math='display'] { margin: 1em 0; text-align: center; overflow-x: auto; }" // long equations scroll in their own box, like wide tables — the page never scrolls horizontally
	 ".katex-display { margin: 0; }" // the display margin lives on our wrapper; KaTeX’s own would double it
	 "</style>"
	 "<script>"
	 "window.TMPreview = {"
	 "  setContent: function(html) {"
	 "    document.getElementById('content').innerHTML = html;"
	 "    if(window.katex) {" // assets missing: leave the raw TeX as plain text, never touch the console
	 "      var macros = {};"
	 "      var scripts = document.querySelectorAll('#content script#tm-katex-macros');" // at most one per fragment; anything else is ignored wholesale
	 "      if(scripts.length == 1) {"
	 "        try {"
	 "          var parsed = JSON.parse(scripts[0].textContent);"
	 "          if(parsed && parsed.constructor === Object && Object.values(parsed).every(function(v) { return typeof v === 'string'; }))"
	 "              macros = parsed;"
	 "          else  console.warn('tm-katex-macros: expected an object with string values');"
	 "        } catch(e) { console.warn('tm-katex-macros: ' + e.message); }"
	 "      } else if(scripts.length > 1) {"
	 "        console.warn('tm-katex-macros: more than one element');"
	 "      }"
	 "      document.querySelectorAll('#content [data-tm-math]').forEach(function(el) {"
	 "        try { katex.render(el.textContent, el, { displayMode: el.dataset.tmMath === 'display', throwOnError: false, macros: macros }); }"
	 "        catch(e) { console.warn('katex: ' + e.message); }" // throwOnError:false already shows bad input in the error color; anything past that must not kill the remaining spans
	 "      });"
	 "    }"
	 // The code-block copy control is decorated and handled in a separate
	 // WKContentWorld (MarkdownPreviewCopyWorldScript), driven by the app after
	 // each setContent — never here. A handler reachable from page-world JS
	 // would let document-derived scripts write the clipboard, so the copy UI
	 // lives where the page cannot reach its message channel.
	 "  },"
	 "  scrollToLine: function(line, atEnd) {"
	 "    if(Date.now() < (window.__tmUserScrollUntil || 0)) return;"
	 "    if(atEnd) { window.scrollTo(0, document.body.scrollHeight); return; }"
	 "    if(line <= 1) { window.scrollTo(0, 0); return; }"
	 "    var els = document.querySelectorAll('#content [data-sourcepos]');"
	 "    for(var i = 0; i < els.length; ++i) {"
	 "      if(parseInt(els[i].getAttribute('data-sourcepos'), 10) >= line) {"
	 "        els[i].scrollIntoView({ behavior: 'auto', block: 'start' });"
	 "        return;"
	 "      }"
	 "    }"
	 "    window.scrollTo(0, document.body.scrollHeight);"
	 "  }"
	 "};"
	 "window.addEventListener('wheel', function() { window.__tmUserScrollUntil = Date.now() + 1000; }, { passive: true });"
	 "document.addEventListener('click', function(ev) {"
	 "  window.__tmUserScrollUntil = Date.now() + 1000;" // clicking is interacting — hold off editor → preview sync
	 "  if(ev.target.closest && ev.target.closest('.tm-copy')) return;" // the copy control runs in its own world and never navigates — the page listener must not treat its clicks as a jump
	 "  var selection = window.getSelection();" // the click ending a drag-selection selects, it does not navigate — and a jump would move focus off the page, killing the ⌘C it was selected for
	 "  if(selection && !selection.isCollapsed) return;"
	 "  if(!ev.target.closest || ev.target.closest('a')) return;" // links open in the browser instead
	 "  var el = ev.target.closest('[data-sourcepos]');"
	 "  if(el) webkit.messageHandlers.tmPreview.postMessage(el.getAttribute('data-sourcepos').split('-')[0]);" // start of range, “line:column”
	 "});"
	 "</script></head><body><article id='content'></article></body></html>"];
	});
	return shell;
}

// Runs in the copy control’s isolated WKContentWorld (see -copyContentWorld):
// it shares the DOM with the page — so it can find #content pre, wrap it, and
// read its text — but shares no JS objects with the page, and the tmPreviewCopy
// message channel it posts to is registered ONLY in this world, so page-world
// JS (including anything a document injects through CMARK_OPT_UNSAFE) cannot
// reach it. The app calls TMPreviewCopy.decorate() after each setContent; the
// button never calls stopPropagation, so the page-world click listener still
// sees the click and holds off scroll sync — it just ignores the .tm-copy
// target instead of jumping.
static NSString* MarkdownPreviewCopyWorldScript ()
{
	return
		@"window.TMPreviewCopy = {"
		 "  decorate: function() {"
		 "    document.querySelectorAll('#content pre').forEach(function(pre) {"
		 "      if(pre.closest('.tm-pre')) return;" // idempotent: never wrap a block twice
		 "      var text = pre.textContent;" // captured before any decoration, so the button can never leak into what it copies
		 "      var wrap = document.createElement('div');"
		 "      wrap.className = 'tm-pre';"
		 "      pre.parentNode.insertBefore(wrap, pre);"
		 "      wrap.appendChild(pre);"
		 "      var button = document.createElement('button');"
		 "      button.type = 'button';"
		 "      button.className = 'tm-copy';"
		 "      button.title = 'Copy';"
		 "      button.innerHTML = '<svg class=\"tm-copy-icon\" viewBox=\"0 0 16 16\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><rect x=\"5.5\" y=\"5.5\" width=\"8\" height=\"8\" rx=\"1.5\"/><path d=\"M10.5 3.5v-1a1 1 0 0 0-1-1h-6a1 1 0 0 0-1 1v6a1 1 0 0 0 1 1h1\"/></svg>'"
		 "                       + '<svg class=\"tm-copy-check\" viewBox=\"0 0 16 16\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M3 8.5l3.5 3.5L13 4.5\"/></svg>';"
		 "      button.addEventListener('click', function(ev) {"
		 "        try { webkit.messageHandlers.tmPreviewCopy.postMessage(text); }"
		 "        catch(e) { return; }" // no handler, no feedback: the checkmark must not claim a copy that never happened
		 "        button.classList.add('tm-copied');"
		 "        clearTimeout(button.__tmCopyTimer);"
		 "        button.__tmCopyTimer = setTimeout(function() { button.classList.remove('tm-copied'); }, 1500);"
		 "      });"
		 "      wrap.appendChild(button);"
		 "    });"
		 "  }"
		 "};";
}

// The isolated world the copy control lives in. worldWithName: returns the
// same world for the same name, so the pane and its tests name the one world.
static WKContentWorld* MarkdownPreviewCopyContentWorld ()
{
	return [WKContentWorld worldWithName:@"com.macromates.markdown-preview.copy"];
}

static NSString* JSONStringLiteral (NSString* aString)
{
	NSData* data = [NSJSONSerialization dataWithJSONObject:(aString ?: @"") options:NSJSONWritingFragmentsAllowed error:nil];
	return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

static NSString* CSSColorString (NSColor* aColor)
{
	NSColor* color = [aColor colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
	if(!color)
		return nil;
	return [NSString stringWithFormat:@"rgba(%d, %d, %d, %.3f)", (int)round(255 * color.redComponent), (int)round(255 * color.greenComponent), (int)round(255 * color.blueComponent), color.alphaComponent];
}

@implementation MarkdownPreviewView
{
	WKWebView* _webView;
	MarkdownPreviewHeaderView* _headerView;
	BOOL _shellLoaded;
	NSURL* _baseURL;
	NSString* _pendingContent;
	NSUUID* _pendingContentDocumentIdentifier; // whose render is waiting for the shell to load — paired with _pendingContent, set and cleared together
	NSUUID* _renderedDocumentIdentifier; // whose render the page shows — nil while the page is empty; decides whether a failure may keep it

	std::unique_ptr<preview_buffer_callback_t> _bufferCallback;
	ng::buffer_t* _attachedBuffer;

	NSTimer* _renderDebounceTimer;
	NSTimer* _scrollSyncTimer;
	std::atomic<NSUInteger> _renderGeneration; // atomic: queued external renders check staleness off the main thread before launching
	dispatch_queue_t _renderQueue;

	// The current external converter process, protected independently of the
	// serial render queue so cancellation is never queued behind the process
	// it must stop.
	std::mutex _externalProcessMutex;
	std::shared_ptr<preview::command_runner_t> _externalProcess;
	preview::converter_t _activeConverter; // what the last renderNow resolved — refreshConverter’s change detector
	NSString* _externalDiagnostic;         // last failure’s bounded stderr, backing the header’s ⚠︎
	HTMLOutputWindowController* _diagnosticWindowController; // lazily created by the ⚠︎ click, reused for every later one

	// View → Preview Theme: when set, these override the editor theme
	// colors pushed via themeBackgroundColor/themeForegroundColor.
	NSString* _customThemeUUID;
	NSColor* _customBackgroundColor;
	NSColor* _customForegroundColor;
}

- (id)initWithFrame:(NSRect)aRect
{
	if(self = [super initWithFrame:aRect])
	{
		_renderQueue = dispatch_queue_create("com.macromates.markdown-preview.render", DISPATCH_QUEUE_SERIAL);

		// The preview theme defaults keys live app-wide (View → Preview
		// Theme); the pane resolves them itself so the window controller
		// only ever pushes the editor’s colors.
		[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(userDefaultsDidChange:) name:NSUserDefaultsDidChangeNotification object:nil];
		[self updateCustomThemeColors];

		// The layer background shows through the transparent web view until
		// the shell’s first themed paint — this is what avoids the white flash.
		self.wantsLayer = YES;
		[self applyLayerBackground];

		// The header outlives the web view: it is what the pane looks like
		// while inactive, and it says which document the page belongs to.
		_headerView = [[MarkdownPreviewHeaderView alloc] initWithFrame:NSZeroRect closeTarget:self closeAction:@selector(didClickClose:) warningAction:@selector(didClickWarning:)];
		[self addSubview:_headerView];
		[self applyHeaderColors];
		[self updateHeader];
	}
	return self;
}

// The header sits above the page; the web view takes what is left. Both
// frames are set here rather than by autoresizing, so the two can never
// overlap.
- (void)layout
{
	[super layout];

	NSRect headerRect, contentRect;
	NSDivideRect(self.bounds, &headerRect, &contentRect, kMarkdownPreviewHeaderHeight, NSMaxYEdge);

	_headerView.frame = headerRect;
	_webView.frame    = contentRect;
}

- (NSRect)pageRect
{
	NSRect headerRect, contentRect;
	NSDivideRect(self.bounds, &headerRect, &contentRect, kMarkdownPreviewHeaderHeight, NSMaxYEdge);
	return contentRect;
}

- (void)didClickClose:(id)sender
{
	if(_closeHandler)
		_closeHandler();
}

- (void)updateHeader
{
	_headerView.titleField.stringValue = _document.displayName ?: @"";
	_headerView.titleField.toolTip     = _document.path ?: _document.displayName;
	_headerView.needsLayout            = YES;
}

- (void)dealloc
{
	[self detachBuffer];
	[self cancelExternalRender];
	[_renderDebounceTimer invalidate];
	[_scrollSyncTimer invalidate];
}

// =====================
// = Partner text view =
// =====================

- (void)setTextView:(OakTextView*)aTextView
{
	if(_textView == aTextView)
		return;

	if(_textView)
		[NSNotificationCenter.defaultCenter removeObserver:self name:NSViewBoundsDidChangeNotification object:[[_textView enclosingScrollView] contentView]];

	if(_textView = aTextView)
		[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(textViewDidScroll:) name:NSViewBoundsDidChangeNotification object:[[_textView enclosingScrollView] contentView]];
}

// =============
// = Lifecycle =
// =============

- (void)setActive:(BOOL)flag
{
	if(_active == flag)
		return;
	_active = flag;

	if(_active)
	{
		[self createWebViewIfNeeded];
		[self attachBuffer];
		[self renderNow];
		[self scheduleScrollSync];
	}
	else
	{
		[self detachBuffer];
		[_renderDebounceTimer invalidate];
		_renderDebounceTimer = nil;
		[_scrollSyncTimer invalidate];
		_scrollSyncTimer = nil;
		[self invalidateRenders]; // a converter only ever runs while the pane is open — closing the pane kills it

		[_webView.configuration.userContentController removeScriptMessageHandlerForName:@"tmPreview"];
		[_webView.configuration.userContentController removeScriptMessageHandlerForName:@"tmPreviewCopy" contentWorld:MarkdownPreviewCopyContentWorld()];
		[_webView removeFromSuperview];
		_webView.navigationDelegate = nil;
		_webView = nil;
		_shellLoaded = NO;
	}
}

- (void)createWebViewIfNeeded
{
	if(_webView)
		return;

	WKWebViewConfiguration* config = [[WKWebViewConfiguration alloc] init];
	// WebKit’s (always sandboxed) content process gets no file access from
	// loadHTMLString:baseURL:, so relative images are served through the same
	// tm-file scheme handler HTMLOutput uses.
	[config setURLSchemeHandler:[OakFileURLSchemeHandler new] forURLScheme:@"tm-file"];

	// Clicking an element jumps the editor to its data-sourcepos line. Page
	// world only: a string sourcepos, never a clipboard request.
	MarkdownPreviewWeakMessageHandler* messageHandler = [MarkdownPreviewWeakMessageHandler new];
	messageHandler.target = self;
	[config.userContentController addScriptMessageHandler:messageHandler name:@"tmPreview"];

	// The copy control’s channel and its DOM decoration live in a dedicated
	// content world. A handler added only to that world is not exposed to
	// page-world JS (webkit.messageHandlers.tmPreviewCopy does not exist there),
	// so the world boundary — not an action name or a nonce a page can read —
	// is what keeps document-derived scripts off the clipboard.
	MarkdownPreviewWeakMessageHandler* copyHandler = [MarkdownPreviewWeakMessageHandler new];
	copyHandler.target = self;
	[config.userContentController addScriptMessageHandler:copyHandler contentWorld:MarkdownPreviewCopyContentWorld() name:@"tmPreviewCopy"];
	[config.userContentController addUserScript:[[WKUserScript alloc] initWithSource:MarkdownPreviewCopyWorldScript() injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:YES inContentWorld:MarkdownPreviewCopyContentWorld()]];

	// Seed the theme CSS variables before the shell’s first paint — applying
	// them from didFinishNavigation would flash the page’s fallback palette.
	if(NSString* js = [self themeVariablesJS])
		[config.userContentController addUserScript:[[WKUserScript alloc] initWithSource:js injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:YES]];

	_webView = [[WKWebView alloc] initWithFrame:[self pageRect] configuration:config];
	_webView.autoresizingMask = NSViewNotSizable; // -layout owns the frame, so the header is never overlapped
	_webView.navigationDelegate = self;

	// Transparent until the page paints: the opaque white base WKWebView draws
	// before first paint reads as a flash. The scroll view behind us carries
	// the theme background. (KVC onto WebKit’s long-standing SPI.)
	@try {
		[_webView setValue:@NO forKey:@"drawsBackground"];
	}
	@catch(NSException* e) { }

	[self addSubview:_webView];

	[self loadShell];
}

- (void)loadShell
{
	if(!_webView)
		return;
	_shellLoaded = NO;
	_renderedDocumentIdentifier = nil; // the fresh shell shows nobody’s render
	_pendingContent = nil;             // and nobody’s render is waiting for it either
	_pendingContentDocumentIdentifier = nil;
	_baseURL = [self documentBaseURL];
	[_webView loadHTMLString:MarkdownPreviewShell() baseURL:_baseURL];
}

- (NSURL*)documentBaseURL
{
	// The document’s directory, so relative image links resolve — via the
	// tm-file scheme, since WebKit denies plain file access to HTML strings.
	NSString* directory = _document.path ? [_document.path stringByDeletingLastPathComponent] : NSHomeDirectory();
	NSURLComponents* components = [NSURLComponents new];
	components.scheme = @"tm-file";
	components.host   = @"";
	components.path   = [directory stringByAppendingString:@"/"];
	return components.URL;
}

// ============
// = Document =
// ============

- (void)setDocument:(OakDocument*)aDocument
{
	if(_document == aDocument)
		return;

	if(_document)
	{
		[NSNotificationCenter.defaultCenter removeObserver:self name:OakDocumentContentDidChangeNotification object:_document];
		[NSNotificationCenter.defaultCenter removeObserver:self name:OakDocumentDidSaveNotification object:_document];
		[NSNotificationCenter.defaultCenter removeObserver:self name:OakDocumentWillCloseNotification object:_document];
	}

	[self detachBuffer];
	[self invalidateRenders];          // the old document’s converter must not outlive its preview
	[self setExternalDiagnostic:nil];  // the ⚠︎ belongs to the document that failed

	if(_document = aDocument)
	{
		[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(documentContentDidChange:) name:OakDocumentContentDidChangeNotification object:_document];
		[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(documentDidSave:) name:OakDocumentDidSaveNotification object:_document];
		[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(documentWillClose:) name:OakDocumentWillCloseNotification object:_document];
	}

	[self updateHeader];

	// The custom theme colors are looked up for the document’s scope — a new
	// document may mean a new file type, so force re-resolution.
	_customThemeUUID = nil;
	[self updateCustomThemeColors];

	if(_active)
	{
		// A different document usually means a different directory; reloading
		// the shell is the only way to change baseURL and is rare enough.
		if(![[self documentBaseURL] isEqual:_baseURL])
				[self loadShell];
		else	[self attachBufferAndRender];
	}
}

// Re-attaches the buffer callback when the document (re)creates its buffer,
// e.g. after being re-opened by a tab switch back to it.
- (void)documentContentDidChange:(NSNotification*)aNotification
{
	if(!_active || !_document || !_document.isLoaded)
		return;
	if(_attachedBuffer == &[_document buffer])
		return;
	[self attachBufferAndRender];
}

// The path may have changed (Save As) — baseURL and the header name follow it.
- (void)documentDidSave:(NSNotification*)aNotification
{
	[self updateHeader];
	if(!_active)
		return;

	if(![[self documentBaseURL] isEqual:_baseURL])
	{
		// Save As into another directory: the page about to be replaced is the
		// only one the results in flight were ever meant for.
		[self invalidateRenders];
		[self loadShell];
	}
	else if([self resolveConverter].kind == preview::converter_kind_t::external)
	{
		[self renderNow]; // the buffer is unchanged, but the converter may read the saved file — TM_FILEPATH exists only from now on
	}
}

// The document’s buffer is about to be deleted (last open reference closed,
// e.g. the tab switched away or was closed). Detach the buffer callback but
// keep the last render on screen until the pane is re-targeted.
- (void)documentWillClose:(NSNotification*)aNotification
{
	[self detachBuffer];
	[_renderDebounceTimer invalidate];
	_renderDebounceTimer = nil;
	[self invalidateRenders]; // the closing document’s converter dies with it
}

- (void)attachBufferAndRender
{
	[self detachBuffer];
	[self attachBuffer];
	[self renderNow];
}

- (void)attachBuffer
{
	if(_attachedBuffer || !_document || !_document.isLoaded)
		return;
	_attachedBuffer = &[_document buffer];
	_bufferCallback = std::make_unique<preview_buffer_callback_t>(self);
	_attachedBuffer->add_callback(_bufferCallback.get());
}

- (void)detachBuffer
{
	if(_attachedBuffer && _bufferCallback)
		_attachedBuffer->remove_callback(_bufferCallback.get());
	_attachedBuffer = nullptr;
	_bufferCallback.reset();
}

// ===================
// = Update pipeline =
// ===================

- (preview::converter_t)resolveConverter
{
	return preview::converter_for_file_type(to_s(_document.fileType));
}

// Re-run resolution for the current document — the owner calls this from its
// selectedDocument.fileType observation, so a grammar change can attach,
// detach, or swap a converter without switching tabs.
- (void)refreshConverter
{
	if(_active && [self resolveConverter] != _activeConverter)
		[self attachBufferAndRender]; // renderNow records the new converter — or freezes, if it is gone
}

- (void)bufferDidChange
{
	if(!_active)
		return;

	NSTimeInterval const interval = [self resolveConverter].kind == preview::converter_kind_t::external ? kExternalRenderDebounceInterval : kRenderDebounceInterval;

	[_renderDebounceTimer invalidate];
	__weak MarkdownPreviewView* weakSelf = self;
	_renderDebounceTimer = [NSTimer scheduledTimerWithTimeInterval:interval repeats:NO block:^(NSTimer*){
		[weakSelf renderNow];
	}];
}

- (void)renderNow
{
	[_renderDebounceTimer invalidate];
	_renderDebounceTimer = nil;

	if(!_active)
		return;

	preview::converter_t const converter = [self resolveConverter];
	_activeConverter = converter;
	if(!converter)
	{
		// The document has no converter (lost via a grammar change, or gone
		// with its bundle): freeze the last good content, kill any external
		// process, and stand down until re-targeted or re-resolved.
		[self invalidateRenders];
		[self detachBuffer];
		return;
	}

	if(!_attachedBuffer) // no buffer (yet): keep whatever is on screen — the
		return;           // content-did-change notification re-attaches and renders

	std::string const text = _attachedBuffer->substr(0, _attachedBuffer->size());
	NSUInteger const generation = ++_renderGeneration;
	[self cancelExternalRender]; // a superseded external process must not outlive the render replacing it

	__weak MarkdownPreviewView* weakSelf = self;
	if(converter.kind == preview::converter_kind_t::markdown)
	{
		dispatch_async(_renderQueue, ^{
			NSString* html = to_ns(markdown::to_html(text));
			dispatch_async(dispatch_get_main_queue(), ^{
				MarkdownPreviewView* strongSelf = weakSelf;
				if(strongSelf && generation == strongSelf->_renderGeneration)
					[strongSelf applyContent:html];
			});
		});
		return;
	}

	// The external pipeline: launch, stdin pumping, output draining, and
	// waiting all run off the main thread; the generation counter discards
	// stale output. Document state is captured here, on the main thread.
	std::string const command     = converter.command;
	std::string const directory   = to_s(_document.path ? [_document.path stringByDeletingLastPathComponent] : NSHomeDirectory()); // matches documentBaseURL
	std::map<std::string, std::string> const environment = preview::converter_environment(oak::basic_environment(), to_s(_document.displayName), to_s(_document.path), converter.item);

	dispatch_async(_renderQueue, ^{
		MarkdownPreviewView* strongSelf = weakSelf;
		if(!strongSelf || generation != strongSelf->_renderGeneration)
			return; // superseded before launch

		auto runner = preview::command_runner_t::launch(command, directory, environment, text, preview::command_runner_t::limits_t());
		{
			// Publishing the record re-checks staleness: a cancellation that
			// ran between the check above and the launch must still win.
			std::lock_guard<std::mutex> lock(strongSelf->_externalProcessMutex);
			if(generation == strongSelf->_renderGeneration)
					strongSelf->_externalProcess = runner;
			else	runner->cancel();
		}

		preview::run_result_t result = runner->wait();

		{
			std::lock_guard<std::mutex> lock(strongSelf->_externalProcessMutex);
			if(strongSelf->_externalProcess == runner)
				strongSelf->_externalProcess = nullptr;
		}

		dispatch_async(dispatch_get_main_queue(), ^{
			MarkdownPreviewView* innerSelf = weakSelf;
			if(innerSelf && generation == innerSelf->_renderGeneration)
				[innerSelf takeExternalRenderResult:result];
		});
	});
}

// Orphans every render already in flight — the built-in path’s results as
// much as an external converter’s — and stops the process behind them. A
// render belongs to the document, path, and converter environment it was
// started for, so anything that changes one of those has to come through
// here: a result that outlives its own document would otherwise still pass
// the generation check and land in the page of the next one, header saying
// one document and body showing another until the next edit.
- (void)invalidateRenders
{
	++_renderGeneration;
	[self cancelExternalRender];
	_pendingContent = nil; // rendered for the page being left, not the one loading
	_pendingContentDocumentIdentifier = nil;
}

// Any thread; never waits on the render queue — the runner’s cancel is
// asynchronous (SIGTERM to the process group now, SIGKILL on a grace timer).
- (void)cancelExternalRender
{
	std::shared_ptr<preview::command_runner_t> process;
	{
		std::lock_guard<std::mutex> lock(_externalProcessMutex);
		process = _externalProcess;
	}
	if(process)
		process->cancel();
}

- (void)takeExternalRenderResult:(preview::run_result_t const&)result
{
	if(result.status == preview::run_result_t::status_t::success)
	{
		[self applyContent:to_ns(result.html)];
	}
	else if(result.status != preview::run_result_t::status_t::cancelled) // cancellation of a stale generation is silent
	{
		// A failure never paints content — no modal, no flash; the header’s ⚠︎
		// and the log carry the diagnostic. The page only keeps what it shows
		// when that belongs to this document — its displayed render, or a good
		// render of it still waiting for the shell to load (before that first
		// load nothing is displayed yet, so the pending render is the only
		// record of this document’s own content). Content rendered from a
		// previously previewed document matches neither and is cleared, so a
		// failing first render never leaves another document’s body under this
		// one’s header.
		BOOL const keepsDisplayed = [_renderedDocumentIdentifier isEqual:_document.identifier];
		BOOL const keepsPending   = [_pendingContentDocumentIdentifier isEqual:_document.identifier];
		if(!keepsDisplayed && !keepsPending)
			[self clearContent];
		os_log_error(OS_LOG_DEFAULT, "Preview command failed: %{public}s", result.diagnostic.c_str());
		[self setExternalDiagnostic:to_ns(result.diagnostic) ?: @"Preview command failed."];
	}
}

- (void)applyContent:(NSString*)html
{
	[self setExternalDiagnostic:nil]; // fresh content supersedes the last failure
	if(!_shellLoaded)
	{
		_pendingContent = html;
		_pendingContentDocumentIdentifier = _document.identifier; // whose render this is, so a failure before the shell loads can tell it is this document’s own
		return;
	}
	_renderedDocumentIdentifier = _document.identifier;
	[_webView evaluateJavaScript:[NSString stringWithFormat:@"TMPreview.setContent(%@);", JSONStringLiteral(html)] completionHandler:nil];
	[self decorateCopyControls]; // re-decorate the fresh #content in the copy world — setContent replaced it wholesale
	[self scheduleScrollSync]; // content height changed — re-anchor (e.g. keep the bottom pinned while typing at the end)
}

// Runs the copy world’s decorate pass over the just-swapped #content. Issued
// right after the page-world setContent: JS evaluations on one web view run in
// order, so the pres exist by the time this lands. Every content swap comes
// through applyContent (including the pending apply after a shell load), so
// this is the single place decoration is triggered.
- (void)decorateCopyControls
{
	[_webView evaluateJavaScript:@"if(window.TMPreviewCopy) TMPreviewCopy.decorate();" inFrame:nil inContentWorld:MarkdownPreviewCopyContentWorld() completionHandler:nil];
}

// Empties the page and hands the (empty) content to the current document, so
// a follow-up failure of the same document keeps it. The diagnostic is not
// touched: clearing is what a failure does, not what recovery does.
- (void)clearContent
{
	_pendingContent = nil; // rendered for the page being left — a cleared page must not resurrect it on shell load
	_pendingContentDocumentIdentifier = nil;
	_renderedDocumentIdentifier = _document.identifier;
	if(_shellLoaded)
		[_webView evaluateJavaScript:@"TMPreview.setContent('');" completionHandler:nil];
}

// ==================================
// = External converter diagnostics =
// ==================================

- (void)setExternalDiagnostic:(NSString*)diagnostic
{
	if(_externalDiagnostic == diagnostic || [_externalDiagnostic isEqualToString:diagnostic])
		return;
	_externalDiagnostic = diagnostic;

	NSString* tooltip = nil;
	if(diagnostic)
	{
		NSArray<NSString*>* lines = [diagnostic componentsSeparatedByString:@"\n"];
		tooltip = lines.count <= 4 ? diagnostic : [[[lines subarrayWithRange:NSMakeRange(0, 4)] componentsJoinedByString:@"\n"] stringByAppendingString:@"\n…"];
	}

	_headerView.warningButton.hidden  = diagnostic == nil;
	_headerView.warningButton.toolTip = tooltip;
	_headerView.needsLayout           = YES;
}

// The diagnostic is plain text, but the HTML output window wants a page: a
// minimal one whose <title> is what the window title binding shows, honoring
// the system appearance the way command output pages do via color-scheme.
static NSString* DiagnosticPageHTML (NSString* title, NSString* diagnostic)
{
	NSString* (^escaped)(NSString*) = ^(NSString* str){
		str = [str stringByReplacingOccurrencesOfString:@"&" withString:@"&amp;"];
		str = [str stringByReplacingOccurrencesOfString:@"<" withString:@"&lt;"];
		return [str stringByReplacingOccurrencesOfString:@">" withString:@"&gt;"];
	};
	return [NSString stringWithFormat:
		@"<!DOCTYPE html><html><head><meta charset='utf-8'><title>%@</title>"
		 "<style>"
		 ":root { color-scheme: light dark; }"
		 "body { margin: 1.5em 2em; }"
		 "pre { font: 12px/1.45 ui-monospace, Menlo, monospace; white-space: pre-wrap; word-break: break-word; }"
		 "</style></head><body><pre>%@</pre></body></html>",
		escaped(title), escaped(diagnostic)];
}

// The tooltip is too small for real converter output; the full (bounded)
// diagnostic goes to the classic HTML output window — selectable, searchable,
// and dismissed with a click instead of lingering as an untitled document.
- (void)didClickWarning:(id)sender
{
	if(!_externalDiagnostic)
		return;
	if(!_diagnosticWindowController)
		_diagnosticWindowController = [[HTMLOutputWindowController alloc] init];
	[_diagnosticWindowController.htmlOutputView setContent:DiagnosticPageHTML([NSString stringWithFormat:@"Preview: %@", _document.displayName], _externalDiagnostic)];
	[_diagnosticWindowController showWindow:self];
}

// ===============
// = Scroll sync =
// ===============

- (void)textViewDidScroll:(NSNotification*)aNotification
{
	if(_active)
		[self scheduleScrollSync];
}

- (void)scheduleScrollSync
{
	if(_scrollSyncTimer)
		return; // trailing-edge throttle: one sync per interval, using fresh state

	__weak MarkdownPreviewView* weakSelf = self;
	_scrollSyncTimer = [NSTimer scheduledTimerWithTimeInterval:kScrollSyncThrottleInterval repeats:NO block:^(NSTimer*){
		[weakSelf performScrollSync];
	}];
}

- (void)performScrollSync
{
	[_scrollSyncTimer invalidate];
	_scrollSyncTimer = nil;

	if(!_active || !_shellLoaded || !_textView)
		return;

	NSClipView* textClipView = [[_textView enclosingScrollView] contentView];
	GVLineRecord const record = [_textView lineRecordForPosition:NSMinY(textClipView.bounds)];
	if(record.lineNumber == NSNotFound)
		return;

	// When the editor shows the end of the document, top-aligning the first
	// visible line would leave the rendered tail below the preview’s fold —
	// pin the preview to its bottom instead, so typing at the end stays live.
	GVLineRecord const lastRecord = [_textView lineRecordForPosition:NSMaxY(textClipView.bounds)];
	BOOL const atEnd = _attachedBuffer && lastRecord.lineNumber != NSNotFound && lastRecord.lineNumber + 1 >= _attachedBuffer->lines();

	[_webView evaluateJavaScript:[NSString stringWithFormat:@"TMPreview.scrollToLine(%lu, %s);", record.lineNumber + 1, atEnd ? "true" : "false"] completionHandler:nil];
}

// =========================================
// = Click to jump (preview → editor, once) =
// =========================================

- (void)userContentController:(WKUserContentController*)userContentController didReceiveScriptMessage:(WKScriptMessage*)message
{
	// The copy control’s channel, reachable only from its isolated world: its
	// body is the block text to place on the clipboard. Page-world JS cannot
	// post here, which is the whole point — the clipboard write is gated by the
	// world, not by trusting the message body.
	if([message.name isEqualToString:@"tmPreviewCopy"])
	{
		if([message.body isKindOfClass:[NSString class]])
		{
			[NSPasteboard.generalPasteboard clearContents];
			[NSPasteboard.generalPasteboard setString:message.body forType:NSPasteboardTypeString];
		}
		return;
	}

	if(![message.name isEqualToString:@"tmPreview"])
		return;
	if(![message.body isKindOfClass:[NSString class]])
		return;
	if(!_textView) // the text view shows a different document — never jump the wrong buffer
		return;

	NSString* const position = message.body;   // sourcepos start, “line:column”, 1-based
	NSInteger const line     = [position integerValue] - 1;
	if(line < 0)
		return;

	// Deliberate navigation: place the caret at the clicked element’s source
	// position (selectionString shares the sourcepos format) and hand focus
	// back to the editor so typing continues there.
	_textView.selectionString = position;
	[self jumpEditorToLine:line];
	[self.window makeFirstResponder:_textView];
}

// Center the clicked element’s source line in the editor — same math as the
// minimap’s click-to-jump. Deliberate clicks only; there is no continuous
// preview → editor scroll sync.
- (void)jumpEditorToLine:(NSUInteger)line
{
	if(!_textView)
		return;

	GVLineRecord const record = [_textView lineFragmentForLine:line column:0];
	if(record.lineNumber == NSNotFound)
		return;

	NSScrollView* scrollView    = [_textView enclosingScrollView];
	NSClipView* clipView        = scrollView.contentView;
	CGFloat const visibleHeight = NSHeight(clipView.bounds);
	CGFloat const maxScroll     = std::max<CGFloat>(0, NSHeight(_textView.frame) - visibleHeight);
	CGFloat const targetY       = std::clamp<CGFloat>((record.firstY + record.lastY - visibleHeight) / 2, 0, maxScroll);

	[clipView scrollToPoint:NSMakePoint(NSMinX(clipView.bounds), round(targetY))];
	[scrollView reflectScrolledClipView:clipView];
}

// =========
// = Theme =
// =========

// The pane may use its own theme (View → Preview Theme): when any of
// the markdownPreview… defaults keys is set, the theme resolved from them
// overrides the editor colors the window controller pushes. Keys that are
// unset fall back to the editor’s counterpart, so forcing just the appearance
// still picks a sensible theme.

- (NSString*)customThemeUUID
{
	NSUserDefaults* defaults = NSUserDefaults.standardUserDefaults;
	NSString* appearance = [defaults stringForKey:@"markdownPreviewThemeAppearance"];
	NSString* lightUUID  = [defaults stringForKey:@"markdownPreviewUniversalThemeUUID"];
	NSString* darkUUID   = [defaults stringForKey:@"markdownPreviewDarkModeThemeUUID"];
	if(!appearance && !lightUUID && !darkUUID)
		return nil; // follow the editor theme

	appearance = appearance ?: [defaults stringForKey:@"themeAppearance"];
	BOOL darkMode = [appearance isEqualToString:@"dark"];
	if(!darkMode && ![appearance isEqualToString:@"light"]) // anything else is ‘auto’
		darkMode = [[self.effectiveAppearance bestMatchFromAppearancesWithNames:@[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ]] isEqualToString:NSAppearanceNameDarkAqua];

	NSString* uuid = darkMode ? darkUUID : lightUUID;
	return uuid ?: [defaults stringForKey:darkMode ? @"darkModeThemeUUID" : @"universalThemeUUID"];
}

- (void)updateCustomThemeColors
{
	NSString* uuid = [self customThemeUUID];
	if(uuid == _customThemeUUID || [uuid isEqualToString:_customThemeUUID])
		return;
	_customThemeUUID = uuid;

	NSColor* background = nil;
	NSColor* foreground = nil;
	if(bundles::item_ptr themeItem = bundles::lookup(to_s(uuid)))
	{
		if(theme_ptr theme = parse_theme(themeItem))
		{
			std::string const scope = to_s(_document.fileType ?: @"text.html.markdown");
			background = [NSColor colorWithCGColor:theme->background(scope)];
			foreground = [NSColor colorWithCGColor:theme->styles_for_scope(scope).foreground()];
		}
	}
	_customBackgroundColor = background;
	_customForegroundColor = foreground;

	[self applyLayerBackground];
	[self applyHeaderColors];
	[self applyThemeVariables];
}

- (void)userDefaultsDidChange:(NSNotification*)aNotification
{
	[self updateCustomThemeColors];
}

- (void)viewDidChangeEffectiveAppearance
{
	[self updateCustomThemeColors]; // ‘auto’ appearance resolves against effectiveAppearance
}

- (NSColor*)effectiveThemeBackgroundColor { return _customBackgroundColor ?: _themeBackgroundColor; }
- (NSColor*)effectiveThemeForegroundColor { return _customForegroundColor ?: _themeForegroundColor; }

- (void)setThemeBackgroundColor:(NSColor*)aColor
{
	_themeBackgroundColor = aColor;
	[self applyLayerBackground];
	[self applyHeaderColors];
	[self applyThemeVariables];
}

// The header is chrome, not page: it is painted by us, from the same theme
// colors the page gets as CSS variables.
- (void)applyHeaderColors
{
	NSColor* background = self.effectiveThemeBackgroundColor ?: NSColor.textBackgroundColor;
	NSColor* foreground = self.effectiveThemeForegroundColor ?: NSColor.textColor;

	_headerView.backgroundColor              = background;
	_headerView.separatorColor               = BlendedColor(foreground, background, 0.85);
	_headerView.titleField.textColor         = BlendedColor(foreground, background, 0.25);
	_headerView.closeButton.contentTintColor = BlendedColor(foreground, background, 0.35);
}

- (void)applyLayerBackground
{
	[CATransaction begin];
	[CATransaction setDisableActions:YES];
	self.layer.backgroundColor = (self.effectiveThemeBackgroundColor ?: NSColor.textBackgroundColor).CGColor;
	[CATransaction commit];
}

- (void)setThemeForegroundColor:(NSColor*)aColor
{
	_themeForegroundColor = aColor;
	[self applyHeaderColors];
	[self applyThemeVariables];
}

- (NSString*)themeVariablesJS
{
	NSMutableString* js = [NSMutableString string];
	if(NSString* background = CSSColorString(self.effectiveThemeBackgroundColor))
		[js appendFormat:@"document.documentElement.style.setProperty('--tm-bg', '%@');", background];
	if(NSString* foreground = CSSColorString(self.effectiveThemeForegroundColor))
		[js appendFormat:@"document.documentElement.style.setProperty('--tm-fg', '%@');", foreground];
	return js.length ? js : nil;
}

- (void)applyThemeVariables
{
	if(!_shellLoaded)
		return;
	if(NSString* js = [self themeVariablesJS])
		[_webView evaluateJavaScript:js completionHandler:nil];
}

// ==========================
// = WKNavigationDelegate   =
// ==========================

- (void)webView:(WKWebView*)webView didFinishNavigation:(WKNavigation*)navigation
{
	_shellLoaded = YES;
	[self applyThemeVariables];

	if(_pendingContent)
	{
		NSString* content         = _pendingContent;
		NSUUID* contentIdentifier = _pendingContentDocumentIdentifier;
		_pendingContent = nil;
		_pendingContentDocumentIdentifier = nil;
		[self applyContent:content];
		// applyContent attributes the page to the current document; the pending
		// render belongs to whoever produced it (the same document in every real
		// flow, since a switch drops pending — but attribute it explicitly).
		if(contentIdentifier)
			_renderedDocumentIdentifier = contentIdentifier;
	}
	else if(_active && !_attachedBuffer)
	{
		[self attachBufferAndRender];
	}
	else if(_active)
	{
		[self renderNow];
	}
	[self scheduleScrollSync];
}

- (void)webView:(WKWebView*)webView decidePolicyForNavigationAction:(WKNavigationAction*)navigationAction decisionHandler:(void(^)(WKNavigationActionPolicy))decisionHandler
{
	// The context menu’s Reload asks WebKit to re-request the current URL —
	// which for a loadHTMLString: page is the baseURL, a tm-file directory
	// the scheme handler answers with its not-found page. Reloading the
	// shell is what the reader meant.
	if(navigationAction.navigationType == WKNavigationTypeReload)
	{
		decisionHandler(WKNavigationActionPolicyCancel);
		[self loadShell];
		return;
	}

	// The shell page never navigates; clicked links open in the default
	// browser so the preview (and its scroll position) stays put.
	if(navigationAction.navigationType == WKNavigationTypeLinkActivated)
	{
		if(NSURL* url = navigationAction.request.URL)
		{
			if([url.scheme isEqualToString:@"tm-file"]) // relative link resolved against our baseURL
				url = [NSURL fileURLWithPath:url.path];
			[NSWorkspace.sharedWorkspace openURL:url];
		}
		return decisionHandler(WKNavigationActionPolicyCancel);
	}
	decisionHandler(WKNavigationActionPolicyAllow);
}
@end
