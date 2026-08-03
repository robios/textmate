@class OakKeyEquivalentView;

@interface PropertiesViewController : NSViewController
{
	IBOutlet NSObjectController* objectController;
	IBOutlet NSView* alignmentView;
	IBOutlet OakKeyEquivalentView* keyEquivalentView;
	IBOutlet NSTextField* ignoredSettingsTextField;
}
- (id)initWithName:(NSString*)aName;
@property (nonatomic) NSMutableDictionary* properties;
// Drag commands parse with input and output defaults of their own, and the
// ignored-settings warning is about what an item asked for beyond its defaults.
@property (nonatomic) BOOL usesDragCommandDefaults;
@property (nonatomic, readonly) CGFloat labelWidth;
@end
