#import "SUProgressViewController.h"

@interface SUProgressViewController ()
{
	NSTimer* _checkProgressTimer;
}
@end

@implementation SUProgressViewController
- (void)loadView
{
	_messageTextField     = [NSTextField labelWithString:@"Downloading Archive…"];
	_progressIndicator    = [[NSProgressIndicator alloc] initWithFrame:NSZeroRect];
	_informativeTextField = [NSTextField labelWithString:@"999.9 MB of 999.9 MB — About 59 minutes, 59 seconds remaining"];

	_messageTextField.selectable     = YES;
	_progressIndicator.maxValue      = 1;
	_progressIndicator.indeterminate = NO;
	_informativeTextField.font       = [NSFont monospacedDigitSystemFontOfSize:NSFont.smallSystemFontSize weight:NSFontWeightRegular];
	_informativeTextField.selectable = YES;

	NSStackView* stackView = [NSStackView stackViewWithViews:@[
		_messageTextField, _progressIndicator, _informativeTextField
	]];
	stackView.spacing     = 0;
	stackView.orientation = NSUserInterfaceLayoutOrientationVertical;
	stackView.alignment   = NSLayoutAttributeLeading;

	[stackView.widthAnchor constraintGreaterThanOrEqualToConstant:_informativeTextField.fittingSize.width + 20].active = YES;

	self.view = stackView;
}

- (void)viewWillAppear
{
	if(_progress)
		[self checkProgressTimerDidFire:nil];
}

- (void)viewDidDisappear
{
	[_checkProgressTimer invalidate];
}

- (void)setProgress:(NSProgress*)newProgress
{
	if(_progress && !newProgress)
		[self checkProgressTimerDidFire:nil];

	[_checkProgressTimer invalidate];
	_checkProgressTimer = nil;

	if(_progress = newProgress)
	{
		_checkProgressTimer = [NSTimer scheduledTimerWithTimeInterval:0.04 target:self selector:@selector(checkProgressTimerDidFire:) userInfo:nil repeats:YES];
		[self checkProgressTimerDidFire:_checkProgressTimer];
	}
}

- (void)checkProgressTimerDidFire:(NSTimer*)timer
{
	_messageTextField.stringValue     = _progress.localizedDescription ?: @"";
	_informativeTextField.stringValue = _progress.isIndeterminate ? @"Estimating time remaining." : (_progress.localizedAdditionalDescription ?: @"");
	_progressIndicator.doubleValue    = _progress.fractionCompleted;
}
@end
