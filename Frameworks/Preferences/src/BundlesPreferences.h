#import "Preferences.h"

@interface BundlesPreferences : NSViewController <PreferencesPaneProtocol>
@property (nonatomic, readonly) NSImage* toolbarItemImage;
@property (nonatomic, readonly) BOOL needsAttention; // A subscription is eclipsed; the toolbar icon carries a badge
@end
