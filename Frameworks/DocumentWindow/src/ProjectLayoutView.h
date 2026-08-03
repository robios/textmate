#import <OakTabBarView/OakTabBarView.h>

@interface ProjectLayoutView : NSView
@property (nonatomic) NSView* documentView;
@property (nonatomic) NSView* fileBrowserView;
@property (nonatomic) NSView* htmlOutputView;
@property (nonatomic) NSView* terminalView;
@property (nonatomic) NSView* markdownPreviewView;

@property (nonatomic) CGFloat fileBrowserWidth;
@property (nonatomic) BOOL fileBrowserOnRight;

@property (nonatomic) NSSize htmlOutputSize;
@property (nonatomic) BOOL htmlOutputOnRight;

@property (nonatomic) NSSize terminalSize;
@property (nonatomic) NSString* terminalPlacement; // left / right / bottom
+ (NSString*)terminalPlacementFromUserDefaults;    // the user default, normalized to one of the three

@property (nonatomic) NSSize markdownPreviewSize;
@property (nonatomic) NSString* markdownPreviewPlacement;  // right / bottom
+ (NSString*)markdownPreviewPlacementFromUserDefaults;     // the user default, normalized to one of the two
@end
