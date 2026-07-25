#import "PreferencesPane.h"
#import <OakFoundation/NSString Additions.h>
#import <OakAppKit/OakUIConstructionFunctions.h>
#import <ns/ns.h>
#import <settings/settings.h>

NSView* OakSetupGridViewWithSeparators (NSGridView* gridView, std::vector<NSUInteger> rows)
{
	gridView.rowAlignment = NSGridRowAlignmentFirstBaseline;
	gridView.rowSpacing   = 8;

	[gridView rowAtIndex:0].topPadding                                  = 20;
	[gridView rowAtIndex:gridView.numberOfRows-1].bottomPadding         = 20;
	[gridView columnAtIndex:0].xPlacement                               = NSGridCellPlacementTrailing;
	[gridView columnAtIndex:0].leadingPadding                           = 8;
	[gridView columnAtIndex:0].width                                    = 200;
	[gridView columnAtIndex:gridView.numberOfColumns-1].trailingPadding = 8;
	[gridView columnAtIndex:gridView.numberOfColumns-1].width           = 400;

	for(NSUInteger row = 0; row < gridView.numberOfRows; ++row)
		[gridView cellAtColumnIndex:0 rowIndex:row].yPlacement = NSGridCellPlacementNone;

	for(NSUInteger row : rows)
	{
		[gridView mergeCellsInHorizontalRange:NSMakeRange(0, gridView.numberOfColumns) verticalRange:NSMakeRange(row, 1)];
		[gridView cellAtColumnIndex:0 rowIndex:row].contentView = OakCreateNSBoxSeparator();
		[gridView cellAtColumnIndex:0 rowIndex:row].xPlacement  = NSGridCellPlacementFill;
		[gridView cellAtColumnIndex:0 rowIndex:row].yPlacement  = NSGridCellPlacementCenter;
		[gridView rowAtIndex:row].topPadding    = 12;
		[gridView rowAtIndex:row].bottomPadding = 12;
		[gridView rowAtIndex:row].rowAlignment  = NSGridRowAlignmentNone;
	}

	[gridView setContentHuggingPriority:NSLayoutPriorityDefaultHigh-2 forOrientation:NSLayoutConstraintOrientationVertical];
	gridView.frame = { .size = gridView.fittingSize };

	return gridView;
}

// A scroll view’s document view is where its origin lives, and an unflipped
// one puts that origin at the bottom left — so a pane taller than its window
// opens scrolled to its end, showing the reader the last thing on it. Flipping
// the container is the fix; scrolling to the top after the fact would only be
// right until the next resize.
@interface OakFlippedContainerView : NSView
@end

@implementation OakFlippedContainerView
- (BOOL)isFlipped { return YES; }
@end

NSView* OakSetupScrollableGridView (NSGridView* gridView, std::vector<NSUInteger> rows)
{
	NSView* content = OakSetupGridViewWithSeparators(gridView, rows);
	content.translatesAutoresizingMaskIntoConstraints = NO;

	NSView* container = [[OakFlippedContainerView alloc] initWithFrame:NSZeroRect];
	[container addSubview:content];
	[NSLayoutConstraint activateConstraints:@[
		[content.topAnchor      constraintEqualToAnchor:container.topAnchor],
		[content.leadingAnchor  constraintEqualToAnchor:container.leadingAnchor],
		[content.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
		[content.bottomAnchor   constraintEqualToAnchor:container.bottomAnchor],
	]];

	NSScrollView* scrollView = [[NSScrollView alloc] init];
	scrollView.documentView = container;
	scrollView.hasVerticalScroller = YES;
	scrollView.drawsBackground = NO;
	scrollView.automaticallyAdjustsContentInsets = NO;
	scrollView.contentInsets = NSEdgeInsetsMake(0, 0, 0, 0);

	// Default-high, not required: the pane must be able to hug its content’s
	// width, but a hint that wants to be wider than the pane has to wrap
	// instead of widening it.
	container.translatesAutoresizingMaskIntoConstraints = NO;
	NSLayoutConstraint* widthConstraint = [container.widthAnchor constraintEqualToAnchor:scrollView.contentView.widthAnchor];
	widthConstraint.priority = NSLayoutPriorityDefaultHigh;
	widthConstraint.active = YES;

	[scrollView setFrameSize:NSMakeSize(content.fittingSize.width, 400)];

	return scrollView;
}

@interface PreferencesPane ()
@property (nonatomic, readwrite) NSImage* toolbarItemImage;
@end

@implementation PreferencesPane
- (id)initWithNibName:(NSNibName)aNibName label:(NSString*)aLabel image:(NSImage*)anImage
{
	if(self = [super initWithNibName:aNibName bundle:[NSBundle bundleForClass:[self class]]])
	{
		self.identifier   = aLabel;
		self.title        = aLabel;
		_toolbarItemImage = anImage;
	}
	return self;
}

- (void)setValue:(id)newValue forUndefinedKey:(NSString*)aKey
{
	if(NSString* key = [_defaultsProperties objectForKey:aKey])
	{
		return [NSUserDefaults.standardUserDefaults setObject:newValue forKey:key];
	}
	else if(NSString* key = [_tmProperties objectForKey:aKey])
	{
		newValue = newValue ?: @"";
		if([newValue isKindOfClass:[NSString class]])
			return settings_t::set(to_s(key), to_s(newValue));
		NSLog(@"%s wrong type for %@: ‘%@’", sel_getName(_cmd), aKey, newValue);
	}
	[super setValue:newValue forUndefinedKey:aKey];
}

- (id)valueForUndefinedKey:(NSString*)aKey
{
	if(NSString* key = [_defaultsProperties objectForKey:aKey])
		return [NSUserDefaults.standardUserDefaults objectForKey:key];
	else if(NSString* key = [_tmProperties objectForKey:aKey])
		return [NSString stringWithCxxString:settings_t::raw_get(to_s(key))];
	return [super valueForUndefinedKey:aKey];
}

- (IBAction)help:(id)sender
{
	NSString* anchor = [sender isKindOfClass:[NSButton class]] ? [sender alternateTitle] : nil;
	if(anchor)
		[NSHelpManager.sharedHelpManager openHelpAnchor:anchor inBook:[[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleHelpBookName"]];
}
@end

NSImage* PreferencesToolbarImage (NSString* symbolName, NSString* description, NSImage* fallbackImage)
{
	if(NSImage* image = [NSImage imageWithSystemSymbolName:symbolName accessibilityDescription:description])
	{
		if(NSImageSymbolConfiguration* configuration = [NSImageSymbolConfiguration configurationWithScale:NSImageSymbolScaleLarge])
			image = [image imageWithSymbolConfiguration:configuration] ?: image;
		[image setTemplate:YES];
		return image;
	}
	return fallbackImage;
}
