#import "PropertiesViewController.h"
#import <OakAppKit/OakKeyEquivalentView.h>
#import <OakFoundation/NSString Additions.h>
#import <command/ignored_settings.h>
#import <plist/plist.h>
#import <text/format.h>

static void* kIgnoredSettingsContext = &kIgnoredSettingsContext;

// What the warning is watching: runLocation decides whether anything is
// ignored at all, and the rest are the settings that can be — asked for
// through this pane’s own controls or written into the item by hand.
static NSArray<NSString*>* IgnoredSettingsKeys ()
{
	return @[ @"runLocation", @"input", @"fallbackInput", @"inputFormat", @"outputLocation", @"outputFormat", @"outputCaret", @"outputReuse", @"autoRefresh", @"autoScrollOutput", @"disableOutputAutoIndent", @"disableJavaScriptAPI" ];
}

@implementation PropertiesViewController
@synthesize properties = _properties;

- (id)initWithName:(NSString*)aName
{
	if((self = [super initWithNibName:aName bundle:[NSBundle bundleForClass:[self class]]]))
	{
		_properties = [NSMutableDictionary new];
		[self observeIgnoredSettingsIn:_properties add:YES];
	}
	return self;
}

- (void)dealloc
{
	[self observeIgnoredSettingsIn:_properties add:NO];
}

- (CGFloat)labelWidth
{
	return alignmentView ? NSMaxX([alignmentView frame]) + 5 : 20;
}

- (NSDictionary*)properties
{
	[objectController commitEditing];
	return _properties;
}

- (void)setProperties:(NSMutableDictionary*)someProperties
{
	[self observeIgnoredSettingsIn:_properties add:NO];
	_properties = someProperties;
	[self observeIgnoredSettingsIn:_properties add:YES];
	[self updateIgnoredSettings];
}

- (void)setUsesDragCommandDefaults:(BOOL)flag
{
	_usesDragCommandDefaults = flag;
	[self updateIgnoredSettings];
}

- (void)observeIgnoredSettingsIn:(NSMutableDictionary*)someProperties add:(BOOL)add
{
	for(NSString* key in IgnoredSettingsKeys())
	{
		if(add)
				[someProperties addObserver:self forKeyPath:key options:0 context:kIgnoredSettingsContext];
		else	[someProperties removeObserver:self forKeyPath:key context:kIgnoredSettingsContext];
	}
}

- (void)observeValueForKeyPath:(NSString*)aKeyPath ofObject:(id)anObject change:(NSDictionary*)someChange context:(void*)context
{
	if(context == kIgnoredSettingsContext)
			[self updateIgnoredSettings];
	else	[super observeValueForKeyPath:aKeyPath ofObject:anObject change:someChange context:context];
}

// Only the two command panes carry the warning field; for every other kind of
// item there is no run location to have a say about.
- (void)updateIgnoredSettings
{
	if(!ignoredSettingsTextField)
		return;

	std::vector<std::string> const settings = command::ignored_settings(plist::convert((__bridge CFPropertyListRef)_properties), _usesDragCommandDefaults);

	NSString* warning = settings.empty() ? nil : [NSString stringWithCxxString:"Ignored while Run in Terminal is on: " + text::join(settings, ", ") + "."];
	ignoredSettingsTextField.stringValue = warning ?: @"";
	ignoredSettingsTextField.toolTip     = warning;
	ignoredSettingsTextField.hidden      = warning == nil;
}

- (void)loadView
{
	[super loadView];
	[keyEquivalentView bind:NSValueBinding toObject:objectController withKeyPath:@"selection.keyEquivalent" options:nil];
	[self updateIgnoredSettings];
}
@end
