@protocol PreferencesPaneProtocol <NSObject>
@optional
@property (nonatomic, readonly) NSImage* toolbarItemImage;

// KVO-observable. The window controller re-reads toolbarItemImage when this
// changes, so a pane can badge its toolbar icon while another pane is selected.
@property (nonatomic, readonly) BOOL needsAttention;
@end

NSImage* PreferencesToolbarImage (NSString* symbolName, NSString* description, NSImage* fallbackImage);

@interface Preferences : NSWindowController
@property (class, readonly) Preferences* sharedInstance;
- (void)selectPaneWithIdentifier:(NSString*)anIdentifier; // pane identifiers equal their labels, e.g. @"AI"
@end
