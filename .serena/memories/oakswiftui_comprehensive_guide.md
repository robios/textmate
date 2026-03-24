# OakSwiftUI Framework - Comprehensive Exploration Report

## 1. Framework Structure

OakSwiftUI is an optional Swift/SwiftUI framework (SPM package) built as a dynamic library. It provides UI primitives for TextMate, bridging between ObjC++ and SwiftUI.

- **Location:** `Frameworks/OakSwiftUI/`
- **Build:** Swift Package Manager, produces `libOakSwiftUI.dylib`
- **Platform:** macOS 14+ (@MainActor-isolated all public APIs)
- **Header:** Auto-generated `OakSwiftUI-Swift.h` for ObjC++ imports

## 2. Existing Components

### 2.1 Bridge Classes (@MainActor, @objc-exposed)

#### Completion System
- **OakCompletionPopup**: Floating panel with autocomplete items, multi-item resolution, smart positioning
  - Methods: `show(in:at:items:)`, `updateFilter:`, `handleKeyEvent:`, `dismiss()`
  - Props: `supportsResolve`, `isVisible`
  - Delegate: `OakCompletionPopupDelegate` (didSelectItem, didDismiss, resolveItem)
  - Panel type: `NSPanel` (borderless, nonactivatingPanel, .floating level)

- **OakCompletionItem**: Immutable data model for completion items
  - Props: label, insertText, detail, kind (LSP CompletionItemKind), icon, documentation, isSnippet, multiline
  - Computed: `effectiveInsertText`, `kindSymbolName`, `kindLabel`
  - Data-binding friendly (not published)

#### Hover/Tooltip System
- **OakInfoTooltip**: NSPopover-based tooltip (semitransient behavior)
  - Methods: `show(in:at:content:)`, `dismiss()`, `reposition(to:)`
  - Delegate: `OakInfoTooltipDelegate` (infoTooltipDidDismiss)
  - Uses: `TooltipViewModel` (ObservableObject, mutable)

- **OakTooltipContent**: Immutable data model
  - Props: title, body (NSAttributedString), codeSnippet, language

#### Find References Panel
- **OakReferencesPanel**: Utility window with grouped references
  - Methods: `show(in:items:symbol:)`, `close()`
  - Panel type: `NSPanel` (.titled, .closable, .resizable, .utilityWindow)
  - Data: groups by filePath, sorts by line number
  - Delegate: `OakReferencesPanelDelegate` (didSelectItem, didClose)

- **OakReferenceItem**: Immutable data model
  - Props: filePath, displayPath, line, column, content

#### Rename Workflow
- **OakRenameField**: Inline editing panel (floating, keyable)
  - Methods: `show(in:at:placeholder:)`, `dismiss()`
  - Design: VisualEffectView + NSTextField + checkmark/cancel buttons
  - Delegate: `OakRenameFieldDelegate` (didConfirmWithName, didDismiss)

- **OakRenamePreviewPanel**: Shows all replacements before applying
  - Methods: `show(items:oldName:newName:parentWindow:)`, `close()`
  - Panel type: Same as ReferencesPanel
  - Delegate: `OakRenamePreviewPanelDelegate` (didConfirm, didCancel)

- **OakRenameItem**: Immutable data model
  - Props: filePath, displayPath, line, oldText, newText

#### Command Palette
- **OakCommandPalette**: Keyable floating panel with fuzzy matching
  - Methods: `show(in:items:)`, `dismiss()`, `loadFrecencyData:`
  - Panel type: Custom KeyablePanel (borderless, nonactivatingPanel, can become key)
  - Supports mode-switching: commands, symbols, recent projects, go to line, etc.
  - Delegate: `OakCommandPaletteDelegate` (didSelectItem, didDismiss, requestItems, searchDocument)

- **OakCommandPaletteItem**: Immutable data model + Identifiable
  - Props: title, subtitle, keyEquivalent, category (enum), actionIdentifier, icon, enabled
  - Computed: `categorySymbolName`
  - Categories: menuAction, bundleCommand, recentProject, symbol, bundleEditor, goToLine, findInProject, setting

#### Floating Panel (Generic Container)
- **OakFloatingPanel**: Generic child window for arbitrary NSView content
  - Methods: `show(content:title:parentWindow:)`, `close()`
  - Panel type: `.titled, .closable, .resizable, .utilityWindow`
  - Delegate: `OakFloatingPanelDelegate` (floatingPanelDidClose)

### 2.2 Theming
- **OakThemeEnvironment**: @Published @ObservableObject shared state
  - Props: fontName, fontSize, backgroundColor, foregroundColor, selectionColor, keywordColor, commentColor, stringColor
  - Computed: `font` property (NSFont factory)
  - Method: `applyTheme(_:NSDictionary)` — bulk update for theme switches
  - Pattern: Create once, pass to all UI instances via @EnvironmentObject

### 2.3 Supporting Infrastructure

#### Logging
- **OakLogPanel**: Singleton floating window for LSP/diagnostic logs
  - Methods: `log(message:level:source:)`, `show()`, `toggle()`
  - Persists window frame to UserDefaults
  - Uses: `LogViewModel` (internal)

#### Notifications (Toasts)
- **OakNotificationManager**: Singleton floating toast manager
  - Methods: `show(message:type:)` — type: error (1), warning (2), info (3), success (4)
  - Automatic layout in top-left corner, auto-dismiss on timer
  - Uses: `ToastViewModel` (internal)

## 3. Bridging Patterns: ObjC++ to SwiftUI

### 3.1 Architecture Pattern
```
ObjC++ (OakTextView.mm, AppController.mm)
    ↓ owns & manages
Swift Bridge Classes (OakCompletionPopup, etc.)
    ↓ compose
SwiftUI Views (CompletionListView, etc.)
    ↓ observe via @EnvironmentObject
Shared State (OakThemeEnvironment)
```

### 3.2 Initialization Pattern (in OakTextView.mm)
```objcpp
// Lazy-init theme once per view
if (!_lspTheme) {
    _lspTheme = [[OakThemeEnvironment alloc] init];
    [_lspTheme applyTheme:@{
        @"fontName": @"Menlo",
        @"fontSize": @(12),
        @"backgroundColor": [NSColor textBackgroundColor],
        @"foregroundColor": [NSColor textColor],
        // ... all color properties
    }];
}

// Create UI instance
_lspCompletionPopup = [[OakCompletionPopup alloc] initWithTheme:_lspTheme];
_lspCompletionPopup.delegate = (id<OakCompletionPopupDelegate>)self;
```

Key points:
- Create theme once, reuse across all UI instances
- Pass theme to bridge class constructors
- Adopt delegate protocol in ObjC++ class
- No Swift runtime dependencies in header (uses auto-generated -Swift.h)

### 3.3 Data Flow Pattern: ObjC++ → SwiftUI

**Example: Showing completion items**
```objcpp
NSMutableArray<OakCompletionItem*>* items = [NSMutableArray array];
for (auto& lspItem : lspResponse.items) {
    OakCompletionItem* item = [[OakCompletionItem alloc]
        initWithLabel:to_ns(lspItem.label)
          insertText:to_ns(lspItem.insertText)
              detail:to_ns(lspItem.detail)
                kind:lspItem.kind];
    [items addObject:item];
}
[_lspCompletionPopup showIn:self at:caretPoint items:items];
```

Flow:
1. ObjC++ converts C++ data → ObjC objects (`to_ns()` macro)
2. Creates bridge data models (OakCompletionItem)
3. Calls bridge UI method → SwiftUI takes over
4. Bridge method creates SwiftUI view, wraps in NSHostingView, adds to NSPanel

### 3.4 Callbacks Pattern: SwiftUI → ObjC++

All delegates are `@objc protocol`:
```swift
@objc protocol OakCompletionPopupDelegate: AnyObject {
    func completionPopup(_ popup: OakCompletionPopup, didSelectItem item: OakCompletionItem)
    func completionPopupDidDismiss(_ popup: OakCompletionPopup)
    @objc optional func completionPopup(_ popup: OakCompletionPopup, resolveItem item: OakCompletionItem)
}
```

ObjC++ adopts & implements:
```objcpp
- (void)completionPopup:(OakCompletionPopup*)popup didSelectItem:(OakCompletionItem*)item {
    // Extract text from item, insert into buffer
    NSString* text = item.effectiveInsertText;
    [self insertText:text];
}

- (void)completionPopupDidDismiss:(OakCompletionPopup*)popup {
    // Cleanup LSP state
}
```

### 3.5 Panel/Window Patterns

#### Non-Activating Floating Popups (Completion, Hover)
```swift
let panel = NSPanel(contentRect:..., styleMask: [.borderless, .nonactivatingPanel], ...)
panel.level = .floating
panel.isOpaque = false
panel.backgroundColor = .clear
panel.contentView = NSHostingView(rootView: swiftUIView)
parentView.window?.addChildWindow(panel, ordered: .above)
```
- User can interact with parent window while popup open
- Escape/Tab/Return dismiss automatically
- Keyboard forwarding to popup only in `handleKeyEvent:`

#### Keyable Floating Panels (CommandPalette, RenameField)
```swift
private class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
let panel = KeyablePanel(..., styleMask: [.borderless, .nonactivatingPanel], ...)
panel.makeKeyAndOrderFront(nil)  // Takes focus
```
- Can be focused, receives keystrokes
- Implement `windowDidResignKey:` to dismiss on focus loss

#### Utility Windows (ReferencesPanel, RenamePreviewPanel)
```swift
let panel = NSPanel(..., styleMask: [.titled, .closable, .resizable, .utilityWindow], ...)
panel.center()
parentWindow.addChildWindow(panel, ordered: .above)
```
- Standard titled window (user can move/resize/close)
- Delegate callback on window close
- Child window behavior = always on top of parent

#### Popovers (Hover Tooltip)
```swift
popover.behavior = .semitransient  // Auto-dismiss on focus loss or mouse exit
popover.show(relativeTo: charRect, of: view, preferredEdge: .maxY)
```

### 3.6 NSHostingView/NSHostingController Usage

**NSHostingView** (for embedding SwiftUI in NSPanel):
```swift
let swiftUIView = CompletionListView(viewModel: vm).environmentObject(theme)
let hostingView = NSHostingView(rootView: swiftUIView)
panel.contentView = hostingView
```

**NSHostingController** (for NSPopover):
```swift
let rootView = TooltipRootView(viewModel: viewModel).environmentObject(theme)
let hostingController = NSHostingController(rootView: rootView)
hostingController.sizingOptions = [.preferredContentSize]
popover.contentViewController = hostingController
```

## 4. ViewModel Patterns

### 4.1 ObservableObject Pattern
```swift
@MainActor
class CompletionViewModel: ObservableObject {
    @Published var filteredItems: [OakCompletionItem] = []
    @Published var selectedIndex: Int = 0
    
    public func setItems(_ items: [OakCompletionItem]) { ... }
    public func updateFilter(_ text: String) { ... }
    public func selectNext() { ... }
}
```

Used in SwiftUI views via:
```swift
@ObservedObject var viewModel: CompletionViewModel
```

### 4.2 Fuzzy Matching (for completion/command palette)
```swift
filteredItems = FuzzyMatcher.filter(allItems, query: currentFilter, keyPath: \.label)
```

### 4.3 Grouping Pattern (for references/rename)
```swift
struct ReferenceGroup: Identifiable {
    let id: String  // filePath
    let displayPath: String
    let items: [OakReferenceItem]
}
```

Constructor groups items by filePath, sorts internally by line number.

## 5. Integration Points in TextMate

### 5.1 OakTextView.mm (LSP UI management)
- Lines ~520-570: UI instance properties
- Line ~5110-5122: ReferencesPanel init & use
- Lines ~6180-6250: CompletionPopup init & use
- Lines ~7091-7110: InfoTooltip init & use
- Delegate implementations for all UI types

### 5.2 AppController.mm (Command palette)
- Line ~858-962: CommandPalette setup & delegation
- Category methods: `collectMenuItems:path:into:`, `recentProjectsForCommandPalette`
- Mode-switching via delegate callbacks

## 6. Key Design Decisions

### 6.1 Thread Isolation
All bridge classes are `@MainActor` — ObjC++ must call from main thread (always true in TextMate).

### 6.2 Data Flow
- ObjC++ creates immutable data models (OakCompletionItem, OakReferenceItem, etc.)
- Bridge classes own mutable ViewModels (@Published)
- ViewModels not exposed to ObjC++ (internal to bridge)

### 6.3 Panel Lifecycle
Bridge class owns NSPanel/NSPopover, manages creation/destruction. Cleanup on:
- Explicit `dismiss()` call
- User closes window/popover
- New UI shown (auto-dismisses previous)

### 6.4 Customization via Delegates
ObjC++ adoption pattern allows:
- Item selection handling
- Custom filtering/matching
- Async resolution (completion items)

## 7. How to Present Modal/Semi-Modal UI

### Pattern A: Floating Popup (Completion, Hover)
```objcpp
// Create once
_popup = [[OakCompletionPopup alloc] initWithTheme:_theme];
_popup.delegate = self;

// Show on demand
[_popup showIn:self at:caretPoint items:items];

// Dismiss on escape/explicit
[_popup dismiss];
```

### Pattern B: Keyable Panel (Command Palette)
```objcpp
// Create or reuse shared instance
if (!sharedPalette) {
    sharedPalette = [[OakCommandPalette alloc] initWithTheme:sharedTheme];
    sharedPalette.delegate = self;
}

// Show
[sharedPalette show:inParentWindow items:items];

// Dismiss on selection or focus loss
// (automatic, via delegate callback & windowDidResignKey)
```

### Pattern C: Utility Window (References, Rename Preview)
```objcpp
// Create on demand
_refPanel = [[OakReferencesPanel alloc] initWithTheme:_theme];
_refPanel.delegate = self;

// Show modal-like (blocks interaction with parent until closed)
[_refPanel show:inParentView items:refItems symbol:@"symbol"];

// User closes or selection handled, delegate notified
```

### Pattern D: Generic Panel Content
```objcpp
// For custom SwiftUI content, use OakFloatingPanel
OakFloatingPanel* panel = [[OakFloatingPanel alloc] init];
NSView* contentView = /* NSHostingView wrapping SwiftUI view */;
[panel show:content:title: parentWindow:];
```

## 8. Best Practices

1. **Theme Management**: Create once, reuse across all UI
2. **Delegate Adoption**: Use id<Protocol> casts, implement all required methods
3. **Data Conversion**: Use `to_ns()` or NSString constructors to convert C++ ↔ ObjC
4. **Panel Ownership**: Keep bridge instance alive for duration of UI lifetime
5. **MainActor**: All calls from ObjC++ are main-thread (safe)
6. **Lazy Init**: Create UI instances on-demand, reuse when possible
7. **Content Sizing**: Let SwiftUI compute sizes, adjust NSPanel frame accordingly
8. **Keyboard Handling**: For non-keyable panels, call `handleKeyEvent:` from keyDown: handler
9. **Notifications**: Use @Published properties + Combine for reactive updates

## 9. Testing Resources

- Tests in `Frameworks/OakSwiftUI/Tests/OakSwiftUITests/`
- Units for: CompletionViewModel, FuzzyMatcher, OakCompletionItem, CommandPaletteViewModel, OakThemeEnvironment
