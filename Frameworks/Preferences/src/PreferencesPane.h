#import "Preferences.h"

NSView* OakSetupGridViewWithSeparators (NSGridView* gridView, std::vector<NSUInteger> rows = { });

// The same, wrapped in a scroll view, for panes taller than the window. The
// document view is flipped, so the pane opens at its top rather than its end.
NSView* OakSetupScrollableGridView (NSGridView* gridView, std::vector<NSUInteger> rows = { });

@interface PreferencesPane : NSViewController <PreferencesPaneProtocol>
@property (nonatomic, readonly) NSImage* toolbarItemImage;
@property (nonatomic) NSDictionary*      defaultsProperties;
@property (nonatomic) NSDictionary*      tmProperties;

- (id)initWithNibName:(NSNibName)aNibName label:(NSString*)aLabel image:(NSImage*)anImage;

- (IBAction)help:(id)sender;
@end
