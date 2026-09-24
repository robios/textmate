#import "SoftwareUpdate.h"
#import "SoftwareUpdateRelease.h"
#import "SoftwareUpdateVerifier.h"
#import "SUDownloadViewController.h"

NSString* const kUserDefaultsSoftwareUpdateDisablePollingKey     = @"SoftwareUpdateDisablePolling";
NSString* const kUserDefaultsSoftwareUpdateLastPollKey           = @"SoftwareUpdateLastPoll";
NSString* const kUserDefaultsSoftwareUpdateSuspendUntilKey       = @"SoftwareUpdateSuspendUntil";
NSString* const kUserDefaultsSoftwareUpdateSkippedVersionKey     = @"SoftwareUpdateSkippedVersion";
NSString* const kUserDefaultsSoftwareUpdateRetryAfterKey         = @"SoftwareUpdateRetryAfter";
NSString* const kUserDefaultsSoftwareUpdateRateLimitStrikesKey   = @"SoftwareUpdateRateLimitStrikes";
NSString* const kUserDefaultsSoftwareUpdateUnsupportedReleaseKey = @"SoftwareUpdateUnsupportedRelease";
NSString* const kUserDefaultsSoftwareUpdateFeedURLKey            = @"SoftwareUpdateFeedURL";

// The one place to change when the repository moves
static NSString* const kRepositoryOwner = @"robios";
static NSString* const kRepositoryName  = @"textmate";

static NSTimeInterval const kPollInterval     = 24*60*60;
static NSTimeInterval const kLaunchCheckDelay = 30;

// =========================
// = Feed session delegate =
// =========================

// The app switches App Transport Security off, so https on every hop of the
// feed request is enforced here.
@interface SoftwareUpdateFeedSessionDelegate : NSObject <NSURLSessionTaskDelegate>
@property (nonatomic) BOOL allowLoopback;
@property (nonatomic) NSURL* refusedRedirectURL;
@end

@implementation SoftwareUpdateFeedSessionDelegate
- (void)URLSession:(NSURLSession*)session task:(NSURLSessionTask*)task willPerformHTTPRedirection:(NSHTTPURLResponse*)response newRequest:(NSURLRequest*)request completionHandler:(void(^)(NSURLRequest*))completionHandler
{
	if(SoftwareUpdateTransportAllowsURL(request.URL, _allowLoopback))
		return completionHandler(request);

	os_log_error(OS_LOG_DEFAULT, "Refusing redirect from %{public}@ to %{public}@", response.URL, request.URL);
	_refusedRedirectURL = request.URL;
	completionHandler(nil); // The redirect response itself becomes the task’s response
}
@end

// ==================
// = SoftwareUpdate =
// ==================

@interface SoftwareUpdate ()
{
	BOOL                           _availabilityEvaluated;
	BOOL                           _available;
	NSString*                      _unavailableReason;
	id                             _requirement; // SecRequirementRef

	NSBackgroundActivityScheduler* _updateCheckScheduler;
	SUDownloadViewController*      _panel;
	BOOL                           _presentNextResult; // A manual check arrived while a background check was running
}
@property (nonatomic, readwrite, getter = isChecking) BOOL checking;
@end

@implementation SoftwareUpdate
+ (instancetype)sharedInstance
{
	static SoftwareUpdate* sharedInstance = [self new];
	return sharedInstance;
}

- (void)evaluateAvailability
{
	if(_availabilityEvaluated)
		return;
	_availabilityEvaluated = YES;

	NSString* reason;
	if(SecRequirementRef requirement = SoftwareUpdateCopyUpdateRequirement(&reason))
	{
		_requirement = CFBridgingRelease(requirement);
		_available   = YES;
	}
	else
	{
		_unavailableReason = reason;
		os_log(OS_LOG_DEFAULT, "Software update unavailable: %{public}@", reason);
	}
}

- (BOOL)isAvailable
{
	[self evaluateAvailability];
	return _available;
}

- (NSString*)unavailableReason
{
	[self evaluateAvailability];
	return _unavailableReason;
}

- (NSString*)localVersion
{
	return [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
}

- (NSString*)userAgent
{
	// App name and version only: no host identifier, OS build, or hardware model
	return [NSString stringWithFormat:@"TextMate/%@", self.localVersion];
}

- (NSURL*)feedURLOverride
{
	NSString* override = [NSUserDefaults.standardUserDefaults stringForKey:kUserDefaultsSoftwareUpdateFeedURLKey];
	if(!override.length)
		return nil;

	os_log_error(OS_LOG_DEFAULT, "Software update feed overridden by %{public}@: %{public}@", kUserDefaultsSoftwareUpdateFeedURLKey, override);
	return [NSURL URLWithString:override];
}

// ================
// = Entry points =
// ================

- (void)startIfAvailable
{
	if(!self.isAvailable || _updateCheckScheduler)
		return;

	_updateCheckScheduler = [[NSBackgroundActivityScheduler alloc] initWithIdentifier:[NSString stringWithFormat:@"%@.%@", NSBundle.mainBundle.bundleIdentifier, @"SoftwareUpdate"]];
	_updateCheckScheduler.interval = kPollInterval;
	_updateCheckScheduler.repeats  = YES;
	[_updateCheckScheduler scheduleWithBlock:^(NSBackgroundActivityCompletionHandler completionHandler){
		dispatch_async(dispatch_get_main_queue(), ^{
			os_activity_initiate("Software update check", OS_ACTIVITY_FLAG_DEFAULT, ^{
				[self checkManually:NO];
			});
			completionHandler(NSBackgroundActivityResultFinished);
		});
	}];

	// The scheduler’s first run is about a day away, so someone who keeps
	// TextMate open for a couple of hours a day would rarely be checked
	NSDate* lastPoll = [NSUserDefaults.standardUserDefaults objectForKey:kUserDefaultsSoftwareUpdateLastPollKey];
	if(![lastPoll isKindOfClass:[NSDate class]] || -lastPoll.timeIntervalSinceNow > kPollInterval)
	{
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kLaunchCheckDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
			[self checkInBackground];
		});
	}
}

- (void)checkForUpdate:(id)sender
{
	[self checkManually:YES];
}

- (void)checkInBackground
{
	[self checkManually:NO];
}

// =========
// = Check =
// =========

- (SUDownloadViewController*)makePanel
{
	SUDownloadViewController* panel = [[SUDownloadViewController alloc] initWithCompletionHandler:^{
		_panel = nil;
	}];
	panel.requirement   = _requirement;
	panel.userAgent     = self.userAgent;
	panel.allowLoopback = SoftwareUpdateLoopbackExemptionForFeedURL(self.feedURLOverride);
	panel.delegate      = self.delegate;
	return _panel = panel;
}

- (void)checkManually:(BOOL)manual
{
	NSUserDefaults* defaults = NSUserDefaults.standardUserDefaults;

	if(!self.isAvailable)
	{
		if(manual && !_panel)
			[self.makePanel presentMessage:@"Software Update Unavailable" informativeText:_unavailableReason];
		return;
	}

	if(_panel) // One panel at a time
	{
		if(manual)
			[_panel orderFront];
		return;
	}

	if(!manual)
	{
		if([defaults boolForKey:kUserDefaultsSoftwareUpdateDisablePollingKey])
			return;

		if(NSDate* suspendUntil = [defaults objectForKey:kUserDefaultsSoftwareUpdateSuspendUntilKey])
		{
			if([suspendUntil isKindOfClass:[NSDate class]] && suspendUntil.timeIntervalSinceNow > 0)
			{
				os_log(OS_LOG_DEFAULT, "Skip software update check: Suspended until %{public}@", suspendUntil);
				return;
			}
			[defaults removeObjectForKey:kUserDefaultsSoftwareUpdateSuspendUntilKey];
		}
	}

	NSDate* retryAfter = [defaults objectForKey:kUserDefaultsSoftwareUpdateRetryAfterKey];
	if([retryAfter isKindOfClass:[NSDate class]] && retryAfter.timeIntervalSinceNow > 0)
	{
		os_log(OS_LOG_DEFAULT, "Skip software update check: Rate limited until %{public}@", retryAfter);
		if(manual)
			[self.makePanel presentMessage:@"Update Check Postponed" informativeText:[self rateLimitMessageForDate:retryAfter]];
		return;
	}

	if(self.isChecking) // Never more than one request in flight
	{
		_presentNextResult = _presentNextResult || manual;
		return;
	}

	_presentNextResult = manual;
	self.checking = YES;
	[self fetchLatestReleaseWithCompletionHandler:^(SoftwareUpdateRelease* release, NSError* error){
		self.checking = NO;
		BOOL manual = _presentNextResult;
		_presentNextResult = NO;
		[self handleRelease:release error:error manual:manual];
	}];
}

- (NSString*)rateLimitMessageForDate:(NSDate*)date
{
	NSDateFormatter* formatter = [[NSDateFormatter alloc] init];
	formatter.dateFormat = @"HH:mm";
	return [NSString stringWithFormat:@"GitHub is rate-limiting update checks from this network. Try again after %@.", [formatter stringFromDate:date]];
}

- (void)fetchLatestReleaseWithCompletionHandler:(void(^)(SoftwareUpdateRelease* release, NSError* error))completionHandler
{
	NSURL* feedOverride = self.feedURLOverride;
	NSURL* feedURL      = feedOverride ?: [NSURL URLWithString:[NSString stringWithFormat:@"https://api.github.com/repos/%@/%@/releases/latest", kRepositoryOwner, kRepositoryName]];
	BOOL allowLoopback  = SoftwareUpdateLoopbackExemptionForFeedURL(feedOverride);

	if(!SoftwareUpdateTransportAllowsURL(feedURL, allowLoopback))
	{
		NSString* description = [NSString stringWithFormat:@"Insecure feed URL refused (%@)", feedOverride ? [NSUserDefaults.standardUserDefaults stringForKey:kUserDefaultsSoftwareUpdateFeedURLKey] : feedURL.absoluteString];
		dispatch_async(dispatch_get_main_queue(), ^{
			completionHandler(nil, [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorAppTransportSecurityRequiresSecureConnection userInfo:@{ NSLocalizedDescriptionKey: description }]);
		});
		return;
	}

	NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:feedURL cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:60];
	[request setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];
	[request setValue:@"2022-11-28" forHTTPHeaderField:@"X-GitHub-Api-Version"];
	[request setValue:self.userAgent forHTTPHeaderField:@"User-Agent"];

	SoftwareUpdateFeedSessionDelegate* delegate = [[SoftwareUpdateFeedSessionDelegate alloc] init];
	delegate.allowLoopback = allowLoopback;

	NSURLSession* session = [NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration delegate:delegate delegateQueue:NSOperationQueue.mainQueue];
	NSURLSessionDataTask* dataTask = [session dataTaskWithRequest:request completionHandler:^(NSData* data, NSURLResponse* response, NSError* error){
		if(error)
			return completionHandler(nil, error);

		NSHTTPURLResponse* httpResponse = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse*)response : nil;
		NSInteger status = httpResponse.statusCode;
		NSUserDefaults* defaults = NSUserDefaults.standardUserDefaults;

		NSInteger strikes = [defaults integerForKey:kUserDefaultsSoftwareUpdateRateLimitStrikesKey] + 1;
		if(NSDate* retryAfter = RetryDateForRateLimitedResponse(status, httpResponse.allHeaderFields, strikes, [NSDate date]))
		{
			os_log_error(OS_LOG_DEFAULT, "Software update feed answered %ld, backing off until %{public}@", status, retryAfter);
			[defaults setInteger:strikes forKey:kUserDefaultsSoftwareUpdateRateLimitStrikesKey];
			[defaults setObject:retryAfter forKey:kUserDefaultsSoftwareUpdateRetryAfterKey];
			return completionHandler(nil, [NSError errorWithDomain:SoftwareUpdateErrorDomain code:SoftwareUpdateErrorRateLimited userInfo:@{ NSLocalizedDescriptionKey: [self rateLimitMessageForDate:retryAfter] }]);
		}

		if(status != 200)
		{
			if(delegate.refusedRedirectURL && status >= 300 && status <= 399)
				return completionHandler(nil, [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorAppTransportSecurityRequiresSecureConnection userInfo:@{ NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Insecure redirect refused (%ld to %@)", status, delegate.refusedRedirectURL.absoluteString] }]);
			return completionHandler(nil, [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorBadServerResponse userInfo:@{ NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Server returned %ld for %@", status, feedURL.absoluteString] }]);
		}

		[defaults removeObjectForKey:kUserDefaultsSoftwareUpdateRateLimitStrikesKey];
		[defaults setObject:[NSDate date] forKey:kUserDefaultsSoftwareUpdateLastPollKey];

		NSError* parseError;
		SoftwareUpdateRelease* release = ParseLatestRelease(data, allowLoopback, &parseError);
		completionHandler(release, parseError);
	}];
	[dataTask resume];
	[session finishTasksAndInvalidate];
}

- (void)handleRelease:(SoftwareUpdateRelease*)release error:(NSError*)error manual:(BOOL)manual
{
	if(!release)
	{
		os_log_error(OS_LOG_DEFAULT, "Software update check failed: %{public}@", error);
		if(manual && !_panel)
		{
			if([error.domain isEqualToString:SoftwareUpdateErrorDomain] && error.code == SoftwareUpdateErrorRateLimited)
					[self.makePanel presentMessage:@"Update Check Postponed" informativeText:error.localizedDescription];
			else	[self.makePanel presentError:error];
		}
		return;
	}

	NSUserDefaults* defaults = NSUserDefaults.standardUserDefaults;
	SoftwareUpdateDecisionResult result = SoftwareUpdateDecide(self.localVersion, release.version, !manual, [defaults stringForKey:kUserDefaultsSoftwareUpdateSkippedVersionKey], [defaults dictionaryForKey:kUserDefaultsSoftwareUpdateUnsupportedReleaseKey], NSProcessInfo.processInfo.operatingSystemVersion);

	if(result.clearSkippedVersion)
		[defaults removeObjectForKey:kUserDefaultsSoftwareUpdateSkippedVersionKey];
	if(result.clearUnsupportedRelease)
		[defaults removeObjectForKey:kUserDefaultsSoftwareUpdateUnsupportedReleaseKey];

	os_log(OS_LOG_DEFAULT, "Software update check: local %{public}@, latest release %{public}@, decision %ld", self.localVersion, release.version, result.decision);
	if(result.decision != SoftwareUpdateDecisionQuiet && !_panel)
		[self.makePanel presentRelease:release decision:result.decision backgroundCheck:!manual];
}
@end
