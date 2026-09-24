#import <SoftwareUpdate/SUDownloadViewController.h>
#import <SoftwareUpdate/SoftwareUpdateRelease.h>

// The panel’s widest state is the offer, with four buttons in one row. The
// window has to grow to fit them: a fixed content width would leave Auto
// Layout with an unsatisfiable set of required constraints, and the buttons
// end up squeezed and truncated.

static void on_main (void(^block)(void))
{
	if(NSThread.isMainThread)
			block();
	else	dispatch_sync(dispatch_get_main_queue(), block);
}

static void collect_buttons (NSView* view, NSMutableArray<NSButton*>* buttons)
{
	for(NSView* subview in view.subviews)
	{
		if([subview isKindOfClass:[NSButton class]])
			[buttons addObject:(NSButton*)subview];
		collect_buttons(subview, buttons);
	}
}

void test_offer_buttons_fit_the_panel ()
{
	on_main(^{
		[NSApplication sharedApplication];

		NSString* json = @"{\"tag_name\":\"v2.5.2\",\"html_url\":\"https://example.com/releases/v2.5.2\",\"assets\":[{\"name\":\"TextMate-2.5.2.tar.gz\",\"browser_download_url\":\"https://example.com/TextMate-2.5.2.tar.gz\",\"size\":1}]}";
		NSError* error;
		SoftwareUpdateRelease* release = ParseLatestRelease([json dataUsingEncoding:NSUTF8StringEncoding], NO, &error);
		OAK_ASSERT(release != nil);

		// Creating the window first keeps the controller from ordering a panel
		// front; it only fills in the content.
		SUDownloadViewController* controller = [[SUDownloadViewController alloc] init];
		NSWindow* window = [NSPanel windowWithContentViewController:controller];
		[controller presentRelease:release decision:SoftwareUpdateDecisionOffer backgroundCheck:NO];

		NSView* contentView = window.contentView;
		[window setContentSize:contentView.fittingSize];
		[window layoutIfNeeded];

		NSMutableArray<NSButton*>* buttons = [NSMutableArray array];
		collect_buttons(contentView, buttons);
		OAK_ASSERT_EQ(buttons.count, 4UL);

		for(NSButton* button in buttons)
		{
			NSRect frame = [contentView convertRect:button.bounds fromView:button];
			OAK_ASSERT_GE(NSWidth(frame), button.intrinsicContentSize.width - 0.5);
			OAK_ASSERT(NSContainsRect(contentView.bounds, frame));
		}
	});
}
