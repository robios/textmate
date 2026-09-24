#import "SUDownloadViewController.h"
#import "SUInfoViewController.h"
#import "SUProgressViewController.h"
#import "SoftwareUpdateInstaller.h"
#import "SoftwareUpdateVerifier.h"
#import <BundlesManager/OakDownloadManager.h>
#import <OakAppKit/OakSound.h>
#import <OakAppKit/OakTransitionViewController.h>
#import <OakAppKit/OakUIConstructionFunctions.h>

@interface SUDownloadViewController ()
{
	SUDownloadViewController* _retainedSelf;

	void(^_completionHandler)();
	BOOL(^_buttonHandler)(NSModalResponse);

	NSStackView* _buttonStackView;

	SoftwareUpdateRelease* _release;
	BOOL                   _backgroundCheck;
	NSUInteger             _downloadGeneration;
	NSURL*                 _stagingURL;      // Replacement directory next to the app, holding TextMate.app
	NSURL*                 _stagedBundleURL;
	BOOL                   _installed;
	BOOL                   _closed;
}
@property (nonatomic, getter = isUpdateBadgeVisible) BOOL updateBadgeVisible;

@property (nonatomic) OakTransitionViewController*  contentViewController;
@property (nonatomic) SUInfoViewController*         infoViewController;
@property (nonatomic) SUProgressViewController*     progressViewController;
@property (nonatomic, readonly) NSArray<NSButton*>* buttons;
@end

@implementation SUDownloadViewController
- (instancetype)initWithCompletionHandler:(void(^)())completionHandler
{
	if(self = [super initWithNibName:nil bundle:nil])
	{
		_completionHandler      = completionHandler;
		_userAgent              = [NSString stringWithFormat:@"TextMate/%@", [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"]];

		_contentViewController  = [[OakTransitionViewController alloc] init];
		_infoViewController     = [[SUInfoViewController alloc] init];
		_progressViewController = [[SUProgressViewController alloc] init];

		self.title = @"";
	}
	return self;
}

- (instancetype)init
{
	return [self initWithCompletionHandler:nil];
}

- (NSStackView*)buttonStackView
{
	if(!_buttonStackView)
	{
		_buttonStackView = [[NSStackView alloc] initWithFrame:NSZeroRect];
		_buttonStackView.spacing = 16;
		[_buttonStackView setHuggingPriority:NSLayoutPriorityDefaultHigh-1 forOrientation:NSLayoutConstraintOrientationVertical];
	}
	return _buttonStackView;
}

- (NSArray<NSButton*>*)buttons
{
	return self.buttonStackView.views.reverseObjectEnumerator.allObjects;
}

- (NSButton*)addButtonWithTitle:(NSString*)title
{
	NSUInteger countOfButtons = self.buttons.count;

	NSButton* button = [NSButton buttonWithTitle:title target:self action:@selector(didClickButton:)];
	button.tag = NSAlertFirstButtonReturn + countOfButtons;
	if(countOfButtons == 0)
		button.keyEquivalent = @"\r";
	else if([title isEqualToString:@"Cancel"] || [title isEqualToString:@"Later"])
		button.keyEquivalent = @"\e";

	[button setContentCompressionResistancePriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
	NSLayoutConstraint* widthConstraint = [button.widthAnchor constraintEqualToConstant:86];
	widthConstraint.priority = NSLayoutPriorityDefaultHigh;
	widthConstraint.active = YES;

	[self.buttonStackView insertView:button atIndex:0 inGravity:NSStackViewGravityTrailing];

	return button;
}

- (void)loadView
{
	NSImage* image = [NSImage imageNamed:NSImageNameApplicationIcon];
	image.size = NSMakeSize(64, 64);

	NSDictionary* views = @{
		@"image":   [NSImageView imageViewWithImage:image],
		@"content": self.contentViewController.view,
		@"buttons": self.buttonStackView,
	};

	NSView* contentView = [[NSView alloc] initWithFrame:NSZeroRect];
	OakAddAutoLayoutViewsToSuperview(views.allValues, contentView);

	[NSLayoutConstraint activateConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:|-(24)-[image(==64)]-(16)-[content]-|"          options:NSLayoutFormatAlignAllTop metrics:nil views:views]];
	[NSLayoutConstraint activateConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:[image]-(>=20)-[buttons]-|"                     options:0                         metrics:nil views:views]];
	[NSLayoutConstraint activateConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"V:|-(16)-[image(==64)]-(>=20)-|"                  options:0                         metrics:nil views:views]];
	[NSLayoutConstraint activateConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"V:[content]-(==20@750,>=20@250)-[buttons]-(18)-|" options:0                         metrics:nil views:views]];

	self.view = contentView;
}

- (void)viewWillAppear
{
	_retainedSelf = self;
}

- (void)viewDidDisappear
{
	_closed = YES;
	self.updateBadgeVisible = NO;
	[_progressViewController.progress cancel];

	if(!_installed)
		[self removeStagingDirectory];

	if(_completionHandler)
		_completionHandler();
	_completionHandler = nil;

	_retainedSelf = nil;
}

- (void)removeStagingDirectory
{
	if(_stagingURL)
	{
		NSError* error;
		if(![NSFileManager.defaultManager removeItemAtURL:_stagingURL error:&error])
			os_log_error(OS_LOG_DEFAULT, "Unable to remove %{public}@: %{public}@", _stagingURL.path, error.localizedDescription);
	}
	_stagingURL      = nil;
	_stagedBundleURL = nil;
}

// ==========
// = Window =
// ==========

- (void)orderFront
{
	[self.view.window makeKeyAndOrderFront:self];
}

- (void)runModal
{
	if(self.view.window)
		return;

	NSWindow* window = [NSPanel windowWithContentViewController:self];

	window.animationBehavior       = NSWindowAnimationBehaviorAlertPanel;
	window.excludedFromWindowsMenu = YES;
	window.hidesOnDeactivate       = NO;
	window.level                   = NSModalPanelWindowLevel;
	window.styleMask               = NSWindowStyleMaskTitled;

	// If we use -[NSApplication runModalForWindow:] then the window
	// won’t stay above document windows after the modal session ends
	[window makeKeyAndOrderFront:self];
}

- (void)setButtonTitles:(NSArray<NSString*>*)titles handler:(BOOL(^)(NSModalResponse))handler
{
	for(NSView* button in self.buttonStackView.views)
		[self.buttonStackView removeView:button];
	for(NSString* title in titles)
		[self addButtonWithTitle:title];
	_buttonHandler = handler;
}

- (void)setButtonsEnabled:(BOOL)flag
{
	for(NSButton* button in self.buttons)
		button.enabled = flag;
}

- (void)didClickButton:(id)sender
{
	BOOL(^handler)(NSModalResponse) = _buttonHandler;
	if(!handler || handler([sender tag]))
		[self.view.window close];
}

- (void)showMessage:(NSString*)message informativeText:(NSString*)informativeText buttonTitles:(NSArray<NSString*>*)titles handler:(BOOL(^)(NSModalResponse))handler
{
	self.contentViewController.subview = self.infoViewController.view;

	self.infoViewController.messageTextField.stringValue     = message;
	self.infoViewController.informativeTextField.stringValue = informativeText ?: @"";
	[self setButtonTitles:titles handler:handler];

	[self runModal];
}

- (void)showProgressMessage:(NSString*)message indeterminate:(BOOL)indeterminate buttonTitles:(NSArray<NSString*>*)titles handler:(BOOL(^)(NSModalResponse))handler
{
	self.progressViewController.progress = nil;
	self.contentViewController.subview = self.progressViewController.view;

	self.progressViewController.messageTextField.stringValue     = message;
	self.progressViewController.informativeTextField.stringValue = @"";
	self.progressViewController.progressIndicator.indeterminate  = indeterminate;
	if(indeterminate)
			[self.progressViewController.progressIndicator startAnimation:self];
	else	[self.progressViewController.progressIndicator stopAnimation:self];
	[self setButtonTitles:titles handler:handler];

	[self runModal];
}

- (void)setUpdateBadgeVisible:(BOOL)flag
{
	if(_updateBadgeVisible == flag)
		return;

	if(_updateBadgeVisible = flag)
	{
		// The app copies the badge into its own resources
		if(NSImage* dlBadge = [NSImage imageNamed:@"Update Badge"])
		{
			NSImage* appIcon = NSApp.applicationIconImage;
			NSApp.applicationIconImage = [NSImage imageWithSize:appIcon.size flipped:NO drawingHandler:^BOOL(NSRect dstRect){
				NSRect upperRightRect = NSIntersectionRect(dstRect, NSOffsetRect(dstRect, round(NSWidth(dstRect) * 2 / 3), (NSHeight(dstRect) * 2 / 3)));
				[appIcon drawInRect:dstRect fromRect:NSZeroRect operation:NSCompositingOperationCopy fraction:1];
				[dlBadge drawInRect:upperRightRect fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1];
				return YES;
			}];
		}
	}
	else
	{
		NSApp.applicationIconImage = nil;
	}
}

// =================
// = Check results =
// =================

- (void)presentMessage:(NSString*)message informativeText:(NSString*)informativeText
{
	[self showMessage:message informativeText:informativeText buttonTitles:@[ @"OK" ] handler:nil];
}

- (void)presentError:(NSError*)error
{
	[self presentMessage:@"Error Checking for Update" informativeText:error.localizedDescription];
}

- (void)presentRelease:(SoftwareUpdateRelease*)release decision:(SoftwareUpdateDecision)decision backgroundCheck:(BOOL)backgroundCheck
{
	_release         = release;
	_backgroundCheck = backgroundCheck;

	NSString* localVersion = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
	switch(decision)
	{
		case SoftwareUpdateDecisionOffer:
		{
			NSString* informativeText = [NSString stringWithFormat:@"TextMate %@ is now available. You have version %@. Would you like to download it now?", release.version, localVersion];
			[self showMessage:@"New Version Available" informativeText:informativeText buttonTitles:@[ @"Download", backgroundCheck ? @"Later" : @"Cancel", @"Skip This Version", @"Release Notes" ] handler:^BOOL(NSModalResponse response){
				switch(response)
				{
					case NSAlertFirstButtonReturn:
						[self download];
						return NO;

					case NSAlertSecondButtonReturn:
						if(backgroundCheck)
							[NSUserDefaults.standardUserDefaults setObject:[NSDate dateWithTimeIntervalSinceNow:24*60*60] forKey:kUserDefaultsSoftwareUpdateSuspendUntilKey];
						return YES;

					case NSAlertThirdButtonReturn:
						[NSUserDefaults.standardUserDefaults setObject:release.version forKey:kUserDefaultsSoftwareUpdateSkippedVersionKey];
						return YES;

					default:
						[NSWorkspace.sharedWorkspace openURL:release.releaseNotesURL];
						return NO;
				}
			}];
		}
		break;

		case SoftwareUpdateDecisionUpToDate:
			[self presentMessage:@"Up To Date" informativeText:[NSString stringWithFormat:@"You are running %@ which is the latest version available.", localVersion]];
		break;

		case SoftwareUpdateDecisionNewerThanRelease:
			[self presentMessage:@"Newer Than the Latest Release" informativeText:[NSString stringWithFormat:@"You are running %@, which is newer than the latest release %@.", localVersion, release.version]];
		break;

		case SoftwareUpdateDecisionRequiresNewerSystem:
		{
			NSDictionary* unsupported = [NSUserDefaults.standardUserDefaults dictionaryForKey:kUserDefaultsSoftwareUpdateUnsupportedReleaseKey];
			NSError* error;
			SoftwareUpdateCheckSystemRequirement(release.version, unsupported[SoftwareUpdateMinimumSystemVersionErrorKey], NSProcessInfo.processInfo.operatingSystemVersion, &error);
			[self presentMessage:@"Requires Newer macOS" informativeText:error.localizedDescription ?: @""];
		}
		break;

		case SoftwareUpdateDecisionQuiet:
		break;
	}
}

// ============
// = Download =
// ============

- (void)download
{
	NSError* error;
	if(!SoftwareUpdatePreflight(NSBundle.mainBundle.bundleURL, &error))
	{
		NSURL* downloadPageURL = _release.releaseNotesURL;
		[self showMessage:@"Cannot Install Update" informativeText:error.localizedDescription buttonTitles:@[ @"OK", @"Open Download Page" ] handler:^BOOL(NSModalResponse response){
			if(response == NSAlertSecondButtonReturn)
				[NSWorkspace.sharedWorkspace openURL:downloadPageURL];
			return YES;
		}];
		return;
	}

	BOOL allowLoopback = _allowLoopback;
	NSUInteger generation = ++_downloadGeneration;

	id <NSProgressReporting> progressReporting = [OakDownloadManager.sharedInstance downloadArchiveAtURL:_release.archiveURL forReplacingURL:NSBundle.mainBundle.bundleURL publicKeys:nil userAgent:_userAgent transportPolicy:^BOOL(NSURL* url){
		return SoftwareUpdateTransportAllowsURL(url, allowLoopback);
	} completionHandler:^(NSURL* extractedArchiveURL, NSError* error){
		if(_closed || generation != _downloadGeneration)
		{
			if(extractedArchiveURL)
				[NSFileManager.defaultManager removeItemAtURL:extractedArchiveURL error:nil];
			return;
		}

		self.progressViewController.progress = nil;
		if(extractedArchiveURL)
				[self verifyExtractedArchiveAtURL:extractedArchiveURL];
		else	[self showDownloadError:error];
	}];

	[self showProgressMessage:@"" indeterminate:NO buttonTitles:@[ @"Cancel" ] handler:^BOOL(NSModalResponse){
		return YES; // Closing the panel cancels the download and removes what was staged
	}];
	self.progressViewController.progress = progressReporting.progress;
}

- (void)showDownloadError:(NSError*)error
{
	[self showMessage:@"Error Downloading Update" informativeText:error.localizedDescription buttonTitles:@[ @"Retry", @"Cancel" ] handler:^BOOL(NSModalResponse response){
		if(response == NSAlertFirstButtonReturn)
			[self download];
		return response != NSAlertFirstButtonReturn;
	}];
}

// ==========
// = Verify =
// ==========

- (void)verifyExtractedArchiveAtURL:(NSURL*)extractedArchiveURL
{
	// tar extracted the bundle’s contents into a replacement directory next to
	// the app; move them to a TextMate.app inside a fresh one on the same volume
	NSError* error;
	NSURL* stagingURL = [NSFileManager.defaultManager URLForDirectory:NSItemReplacementDirectory inDomain:NSUserDomainMask appropriateForURL:NSBundle.mainBundle.bundleURL create:YES error:&error];
	NSURL* bundleURL  = [stagingURL URLByAppendingPathComponent:@"TextMate.app" isDirectory:YES];
	if(!stagingURL || ![NSFileManager.defaultManager moveItemAtURL:extractedArchiveURL toURL:bundleURL error:&error])
	{
		[NSFileManager.defaultManager removeItemAtURL:extractedArchiveURL error:nil];
		if(stagingURL)
			[NSFileManager.defaultManager removeItemAtURL:stagingURL error:nil];
		[self showVerificationFailure:error];
		return;
	}

	_stagingURL      = stagingURL;
	_stagedBundleURL = bundleURL;

	[self showProgressMessage:[NSString stringWithFormat:@"Verifying %@…", _release.archiveURL.lastPathComponent] indeterminate:YES buttonTitles:@[ ] handler:nil];

	NSString* expectedVersion          = _release.version;
	NSString* localVersion             = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
	NSOperatingSystemVersion osVersion = NSProcessInfo.processInfo.operatingSystemVersion;
	id requirement                     = self.requirement;

	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		NSError* error;
		BOOL verified = requirement && SoftwareUpdateVerifyBundle(bundleURL, expectedVersion, (__bridge SecRequirementRef)requirement, osVersion, localVersion, &error);
		if(!requirement)
			error = [NSError errorWithDomain:SoftwareUpdateErrorDomain code:SoftwareUpdateErrorInternal userInfo:@{ NSLocalizedDescriptionKey: @"No signing requirement to verify against." }];

		dispatch_async(dispatch_get_main_queue(), ^{
			[self.progressViewController.progressIndicator stopAnimation:self];
			if(verified)
			{
				self.updateBadgeVisible = YES;
				if(NSApp.isActive)
					OakPlayUISound(OakSoundDidCompleteSomethingUISound);
				[self showDownloaded];
			}
			else
			{
				[self removeStagingDirectory];
				if(error.code == SoftwareUpdateErrorRequiresNewerSystem)
				{
					[NSUserDefaults.standardUserDefaults setObject:@{
						SoftwareUpdateVersionErrorKey:              error.userInfo[SoftwareUpdateVersionErrorKey],
						SoftwareUpdateMinimumSystemVersionErrorKey: error.userInfo[SoftwareUpdateMinimumSystemVersionErrorKey],
					} forKey:kUserDefaultsSoftwareUpdateUnsupportedReleaseKey];
					[self presentMessage:@"Requires Newer macOS" informativeText:error.localizedDescription];
				}
				else
				{
					[self showVerificationFailure:error];
				}
			}
		});
	});
}

- (void)showVerificationFailure:(NSError*)error
{
	os_log_error(OS_LOG_DEFAULT, "Update verification failed: %{public}@", error);
	[self presentMessage:@"The downloaded update could not be verified" informativeText:error.localizedDescription];
}

- (void)showDownloaded
{
	[self showProgressMessage:[NSString stringWithFormat:@"Downloaded %@", _release.archiveURL.lastPathComponent] indeterminate:NO buttonTitles:@[ @"Install & Relaunch", @"Cancel" ] handler:^BOOL(NSModalResponse response){
		if(response == NSAlertFirstButtonReturn)
			[self install];
		return response != NSAlertFirstButtonReturn;
	}];
	self.progressViewController.progressIndicator.doubleValue = 1;
}

// ===========
// = Install =
// ===========

- (NSError*)missingDelegateError
{
	return [NSError errorWithDomain:SoftwareUpdateErrorDomain code:SoftwareUpdateErrorInternal userInfo:@{ NSLocalizedDescriptionKey: @"TextMate has no way to save your open documents before relaunching (internal error)." }];
}

- (void)install
{
	id <SoftwareUpdateDelegate> delegate = self.delegate;
	if(!delegate)
		return [self showInstallFailure:self.missingDelegateError];

	[self setButtonsEnabled:NO];
	[delegate softwareUpdateAskToTerminateRunningProcesses:^(BOOL canTerminate){
		if(canTerminate)
				[self saveSessionAndInstall];
		else	[self setButtonsEnabled:YES]; // Stay on ‘Downloaded’
	}];
}

- (void)saveSessionAndInstall
{
	id <SoftwareUpdateDelegate> delegate = self.delegate;
	if(!delegate)
		return [self showInstallFailure:self.missingDelegateError];

	NSError* error;
	if(![delegate softwareUpdateSaveSessionWithError:&error])
	{
		NSString* informativeText = [NSString stringWithFormat:@"Could not save your open documents (%@). The update was not installed.", error.localizedDescription ?: @"unknown error"];
		[self showMessage:@"Cannot Save Session" informativeText:informativeText buttonTitles:@[ @"Retry", @"Cancel" ] handler:^BOOL(NSModalResponse response){
			if(response == NSAlertFirstButtonReturn)
					[self saveSessionAndInstall];
			else	[self showDownloaded];
			return NO;
		}];
		return;
	}

	[self showProgressMessage:@"Installing TextMate…" indeterminate:YES buttonTitles:@[ ] handler:nil];
	if(SoftwareUpdateInstall(_stagedBundleURL, NSBundle.mainBundle.bundleURL, &error))
	{
		_installed = YES;
		self.progressViewController.messageTextField.stringValue = @"Relaunching TextMate…";
		SoftwareUpdateRelaunch();
	}
	else
	{
		[self.progressViewController.progressIndicator stopAnimation:self];
		[self showInstallFailure:error];
	}
}

- (void)showInstallFailure:(NSError*)error
{
	os_log_error(OS_LOG_DEFAULT, "Failed to install update: %{public}@", error);
	[self showMessage:@"Failed to Install Update" informativeText:error.localizedDescription buttonTitles:@[ @"Retry", @"Cancel" ] handler:^BOOL(NSModalResponse response){
		if(response == NSAlertFirstButtonReturn)
			[self saveSessionAndInstall];
		return response != NSAlertFirstButtonReturn;
	}];
}
@end
