#import "SUInfoViewController.h"

@implementation SUInfoViewController
- (void)loadView
{
	_messageTextField     = [NSTextField labelWithString:@"New Version Available"];
	_informativeTextField = [NSTextField wrappingLabelWithString:@"Would you like to download and install?"];

	NSStackView* stackView = [NSStackView stackViewWithViews:@[
		_messageTextField, _informativeTextField
	]];

	stackView.orientation = NSUserInterfaceLayoutOrientationVertical;
	stackView.alignment   = NSLayoutAttributeLeading;
	[stackView setHuggingPriority:NSLayoutPriorityDefaultHigh-1 forOrientation:NSLayoutConstraintOrientationVertical];

	_messageTextField.selectable     = YES;
	_messageTextField.font           = [NSFont boldSystemFontOfSize:0];
	_informativeTextField.selectable = YES;
	_informativeTextField.font       = [NSFont messageFontOfSize:NSFont.smallSystemFontSize];

	// The text wraps at the usual alert width, but the panel may have to be
	// wider than that to fit its row of buttons, so this is a minimum only
	_informativeTextField.preferredMaxLayoutWidth = 298;
	[stackView.widthAnchor constraintGreaterThanOrEqualToConstant:298].active = YES;

	self.view = stackView;
}
@end
