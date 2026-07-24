#import "TerminalStatusBar.h"
#import <OakAppKit/OakUIConstructionFunctions.h>

@implementation TerminalStatusBar
{
	NSTextField* _directoryLabel;
}

- (instancetype)initWithFrame:(NSRect)aRect
{
	if(self = [super initWithFrame:aRect])
	{
		self.material     = NSVisualEffectMaterialTitlebar;
		self.blendingMode = NSVisualEffectBlendingModeWithinWindow;
		self.state        = NSVisualEffectStateFollowsWindowActiveState;
		self.wantsLayer   = YES;

		NSView* topDivider = OakCreateNSBoxSeparator();

		_directoryLabel = OakCreateLabel(@"", OakStatusBarFont(), NSTextAlignmentLeft, NSLineBreakByTruncatingHead);
		[_directoryLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];

		NSDictionary* views = @{
			@"topDivider": topDivider,
			@"directory":  _directoryLabel,
		};
		OakAddAutoLayoutViewsToSuperview(views.allValues, self);

		[self addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:|[topDivider]|" options:0 metrics:nil views:views]];
		[self addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"V:|[topDivider(==1)]" options:0 metrics:nil views:views]];
		[self addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:|-8-[directory]-(>=8)-|" options:0 metrics:nil views:views]];
		[self addConstraint:[NSLayoutConstraint constraintWithItem:self attribute:NSLayoutAttributeHeight relatedBy:NSLayoutRelationEqual toItem:nil attribute:NSLayoutAttributeNotAnAttribute multiplier:1 constant:25]];
		[self addConstraint:[NSLayoutConstraint constraintWithItem:_directoryLabel attribute:NSLayoutAttributeCenterY relatedBy:NSLayoutRelationEqual toItem:self attribute:NSLayoutAttributeCenterY multiplier:1 constant:0.5]];
	}
	return self;
}

- (void)setWorkingDirectory:(NSString*)aDirectory
{
	_workingDirectory = [aDirectory copy];
	_directoryLabel.stringValue = [aDirectory stringByAbbreviatingWithTildeInPath] ?: @"";
	_directoryLabel.toolTip = aDirectory;
}
@end
