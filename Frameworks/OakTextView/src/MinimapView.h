#import <Cocoa/Cocoa.h>
#import <theme/theme.h>

@class OakTextView;
@class OakDocument;

@interface MinimapView : NSView
@property (nonatomic, weak) OakTextView* textView;
@property (nonatomic) OakDocument* document;
@property (nonatomic) NSColor* backgroundColor;
@property (nonatomic) NSColor* caretColor;
@property (nonatomic) NSUInteger caretLine; // NSNotFound = no marker
@property (nonatomic) theme_ptr theme;      // enables syntax-colored blocks; nil → uniform gray
- (void)reloadMetrics;
- (void)documentContentDidChange;
- (void)documentMarksDidChange;
@end
