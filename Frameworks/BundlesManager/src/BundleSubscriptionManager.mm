#import "BundleSubscriptionManager.h"
#import "BundlesManager.h"
#import "OakDownloadManager.h"
#import "git_ref_advertisement.h"
#import "github_url.h"
#import <bundles/query.h>
#import <bundles/locations.h>
#import <ns/ns.h>
#import <io/path.h>
#import <OakSystem/application.h>

NSString* const BundleSubscriptionsDidChangeNotification = @"BundleSubscriptionsDidChangeNotification";
NSString* const BundleSubscriptionErrorDomain            = @"BundleSubscription";

static NSString* const kTransactionsDirectoryName = @"Transactions";
static NSString* const kJournalFileName           = @"journal.plist";

// Which way a journalled transaction was going. A journal with no kind key at
// all is a Replace, which is the only one that predates the key; a kind this
// version does not know belongs to a version that does, and is left alone.
static NSString* const kJournalKindKey       = @"kind";
static NSString* const kJournalKindReplace   = @"replace";
static NSString* const kJournalKindRestore   = @"restore";
static NSString* const kJournalKindUninstall = @"uninstall";

static NSError* SubscriptionError (BundleSubscriptionErrorCode code, NSString* format, ...) NS_FORMAT_FUNCTION(2, 3);
static NSError* SubscriptionError (BundleSubscriptionErrorCode code, NSString* format, ...)
{
	va_list ap;
	va_start(ap, format);
	NSString* message = [[NSString alloc] initWithFormat:format arguments:ap];
	va_end(ap);
	return [NSError errorWithDomain:BundleSubscriptionErrorDomain code:code userInfo:@{ NSLocalizedDescriptionKey: message }];
}

// The same sanitisation the signed path applies to a bundle name, plus the
// suffix of §9.3: two taps may both offer a “Git” bundle, and they must not
// compete for one directory. The name is not user-facing.
static NSString* SubscribedDirectoryName (NSString* bundleName, NSUUID* identifier)
{
	NSString* base = [[(bundleName ?: @"Bundle") stringByReplacingOccurrencesOfString:@"/" withString:@":"] stringByReplacingOccurrencesOfString:@"." withString:@"_"];
	NSString* suffix = [identifier.UUIDString substringToIndex:8];
	return [NSString stringWithFormat:@"%@-%@.tmbundle", base, suffix];
}

static NSUUID* BundleIdentifierAtPath (NSString* bundlePath)
{
	NSDictionary* info = [NSDictionary dictionaryWithContentsOfFile:[bundlePath stringByAppendingPathComponent:@"info.plist"]];
	return [info[@"uuid"] isKindOfClass:[NSString class]] ? [[NSUUID alloc] initWithUUIDString:info[@"uuid"]] : nil;
}

// The commit date of the revision the archive was made from, which every entry
// in it carries — see DownloadTarball. It has to be read from a file rather
// than the bundle directory: that directory is one we created for tar to
// extract into, so its date is when we did that, not when the bundle changed.
static NSDate* SourceDateAtPath (NSString* bundlePath)
{
	return [[NSFileManager.defaultManager attributesOfItemAtPath:[bundlePath stringByAppendingPathComponent:@"info.plist"] error:nil] fileModificationDate];
}

static NSString* BundleNameAtPath (NSString* bundlePath)
{
	NSDictionary* info = [NSDictionary dictionaryWithContentsOfFile:[bundlePath stringByAppendingPathComponent:@"info.plist"]];
	return [info[@"name"] isKindOfClass:[NSString class]] ? info[@"name"] : nil;
}

// A repository is usually a bundle, but it may also be a monorepo holding
// several. The tarball is already extracted by the time we look, so finding out
// costs one directory read (§9.4).
static NSArray<NSString*>* BundlePathsInExtractedTree (NSString* root)
{
	if(BundleIdentifierAtPath(root))
		return @[ root ];

	NSMutableArray* res = [NSMutableArray array];
	for(NSString* name in [[NSFileManager.defaultManager contentsOfDirectoryAtPath:root error:nil] sortedArrayUsingSelector:@selector(localizedCompare:)])
	{
		if(![name.pathExtension.lowercaseString isEqualToString:@"tmbundle"])
			continue;

		NSString* path = [root stringByAppendingPathComponent:name];
		if(BundleIdentifierAtPath(path))
			[res addObject:path];
	}
	return res;
}

// ===================
// = Network helpers =
// ===================

// §8 says HTTPS to GitHub and nothing else, and the URL allow-list only decides
// where a request *starts*: a redirect would take it anywhere. This is what
// makes the sentence true for where it ends up as well. All four endpoints are
// GitHub's own, and the redirects they do issue — a renamed repository, a
// tarball handed to codeload — stay inside this list.
@interface BundleSubscriptionSessionDelegate : NSObject <NSURLSessionTaskDelegate>
@end

@implementation BundleSubscriptionSessionDelegate
- (void)URLSession:(NSURLSession*)session task:(NSURLSessionTask*)task willPerformHTTPRedirection:(NSHTTPURLResponse*)response newRequest:(NSURLRequest*)request completionHandler:(void(^)(NSURLRequest*))handler
{
	static NSSet* allowedHosts = [NSSet setWithArray:@[ @"github.com", @"www.github.com", @"codeload.github.com", @"raw.githubusercontent.com", @"api.github.com" ]];

	NSString* scheme = request.URL.scheme.lowercaseString;
	NSString* host   = request.URL.host.lowercaseString;

	if([scheme isEqualToString:@"https"] && [allowedHosts containsObject:host])
		return handler(request);

	os_log_error(OS_LOG_DEFAULT, "Refusing redirect off GitHub: %{public}@ → %{public}@", task.originalRequest.URL, request.URL);
	handler(nil); // The response that redirected becomes the result, and it carries no bundle
}
@end

static NSURLSession* GitHubSession ()
{
	static NSURLSession* session = [NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.defaultSessionConfiguration delegate:[BundleSubscriptionSessionDelegate new] delegateQueue:nil];
	return session;
}

// Everything below runs unauthenticated against public repositories, so a
// repository taken private answers 401 and is treated exactly like one that is
// gone: unavailable, never a reason to delete what is installed.
static void FetchResponseAtURL (std::string const& urlString, void(^handler)(NSData* data, NSHTTPURLResponse* response, NSError* error))
{
	NSURL* url = [NSURL URLWithString:to_ns(urlString)];
	if(!url)
		return handler(nil, nil, SubscriptionError(BundleSubscriptionErrorCodeInvalidURL, @"Not a valid URL: %s", urlString.c_str()));

	NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:60];
	[request setValue:OakDownloadManager.sharedInstance.userAgentString forHTTPHeaderField:@"User-Agent"];

	[[GitHubSession() dataTaskWithRequest:request completionHandler:^(NSData* data, NSURLResponse* response, NSError* error){
		NSHTTPURLResponse* httpResponse = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse*)response : nil;
		dispatch_async(dispatch_get_main_queue(), ^{
			if(error)
					handler(nil, httpResponse, SubscriptionError(BundleSubscriptionErrorCodeUnavailable, @"%@", error.localizedDescription));
			else	handler(data, httpResponse, nil);
		});
	}] resume];
}

static void FetchDataAtURL (std::string const& urlString, void(^handler)(NSData* data, NSError* error))
{
	// Copied out of the C++ string: the caller’s argument is typically a
	// temporary, and the reply arrives long after it is gone.
	NSString* url = to_ns(urlString);

	FetchResponseAtURL(urlString, ^(NSData* data, NSHTTPURLResponse* response, NSError* error){
		if(error)
			handler(nil, error);
		else if(response.statusCode != 200)
			handler(nil, SubscriptionError(BundleSubscriptionErrorCodeUnavailable, @"Server returned %ld for %@", (long)response.statusCode, url));
		else
			handler(data, nil);
	});
}

// codeload streams a gzipped tarball whose single top-level directory is
// ‘<repo>-<sha>’, so stripping one component lands the repository root — and
// for a bundle repository, the bundle root — in ‘directory’.
//
// Unlike the signed path this does not pass ‘-m’: the archive dates every entry
// with the revision’s commit date, which is the honest answer to “when was this
// last updated” and the only one available without spending an api.github.com
// request. The bundle cache compares modification dates for equality rather
// than recency ([`fs_cache.mm:270`]), so keeping them costs nothing there.
static void DownloadTarball (std::string const& urlString, NSString* directory, void(^handler)(NSError* error))
{
	NSURL* url = [NSURL URLWithString:to_ns(urlString)];
	if(!url)
		return handler(SubscriptionError(BundleSubscriptionErrorCodeInvalidURL, @"Not a valid URL: %s", urlString.c_str()));

	NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:300];
	[request setValue:OakDownloadManager.sharedInstance.userAgentString forHTTPHeaderField:@"User-Agent"];

	[[GitHubSession() downloadTaskWithRequest:request completionHandler:^(NSURL* location, NSURLResponse* response, NSError* error){
		NSInteger statusCode = [response isKindOfClass:[NSHTTPURLResponse class]] ? ((NSHTTPURLResponse*)response).statusCode : 0;

		NSError* localError = nil;
		if(error)
		{
			localError = SubscriptionError(BundleSubscriptionErrorCodeUnavailable, @"%@", error.localizedDescription);
		}
		else if(statusCode != 200)
		{
			localError = SubscriptionError(BundleSubscriptionErrorCodeUnavailable, @"Server returned %ld for %@", statusCode, url.absoluteString);
		}
		else
		{
			// The download’s temporary file is gone once this block returns, so
			// extraction happens here rather than after a hop to the main queue.
			if([NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:&localError])
			{
				NSTask* task = [[NSTask alloc] init];
				task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/tar"];
				task.arguments     = @[ @"-zxkC", directory, @"--strip-components", @"1", @"--disable-copyfile", @"--exclude", @"._*", @"-f", location.path ];
				task.standardOutput = [NSFileHandle fileHandleWithNullDevice];

				NSPipe* errorPipe = [NSPipe pipe];
				task.standardError = errorPipe;

				if([task launchAndReturnError:&localError])
				{
					NSData* errorData = [errorPipe.fileHandleForReading readDataToEndOfFile];
					[task waitUntilExit];

					if(task.terminationStatus != 0)
					{
						NSString* description = errorData.length ? [[[NSString alloc] initWithData:errorData encoding:NSUTF8StringEncoding] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] : nil;
						localError = SubscriptionError(BundleSubscriptionErrorCodeMalformedResponse, @"Failed to extract archive: %@", description ?: [NSString stringWithFormat:@"tar exited with %d", task.terminationStatus]);
					}
				}
			}
		}

		dispatch_async(dispatch_get_main_queue(), ^{
			handler(localError);
		});
	}] resume];
}

@implementation BundleSubscriptionManager
{
	BundleSubscriptionRegistry* _registry;

	// Tap identifier → the catalogue its cached, immutable ‘<sha>.plist’ holds
	NSMutableDictionary<NSString*, BundleTapCatalogue*>* _catalogues;

	// Registry mutations, installs, and polls are serialized so that an
	// unsubscribe cannot race an in-flight update of the same bundle.
	NSMutableArray<void(^)(dispatch_block_t)>* _pendingOperations;
	BOOL _runningOperation;
}

+ (instancetype)sharedInstance
{
	static BundleSubscriptionManager* sharedInstance = [self new];
	return sharedInstance;
}

- (instancetype)init
{
	return [self initWithInstallDirectory:to_ns(oak::application_t::support("Subscribed")) registryFileURL:[NSURL fileURLWithPath:to_ns(oak::application_t::support("Subscriptions.plist"))]];
}

- (instancetype)initWithInstallDirectory:(NSString*)installDirectory registryFileURL:(NSURL*)registryFileURL
{
	if(self = [super init])
	{
		_installDirectory  = installDirectory;
		_bundlesDirectory  = [_installDirectory stringByAppendingPathComponent:@"Bundles"];
		_registry          = [[BundleSubscriptionRegistry alloc] initWithFileURL:registryFileURL];
		_catalogues        = [NSMutableDictionary dictionary];
		_pendingOperations = [NSMutableArray array];
	}
	return self;
}

- (void)loadRegistry
{
	NSError* error;
	if(![_registry load:&error])
		os_log_error(OS_LOG_DEFAULT, "Failed to load subscriptions: %{public}@", error.localizedDescription);

	// The directory is in bundles::locations(), so it is indexed and watched
	// whether or not anything is installed yet; creating it up front keeps the
	// watcher from having to notice it appear.
	if(![NSFileManager.defaultManager createDirectoryAtPath:_bundlesDirectory withIntermediateDirectories:YES attributes:nil error:&error])
		os_log_error(OS_LOG_DEFAULT, "Failed to create %{public}@: %{public}@", _bundlesDirectory, error.localizedDescription);

	[self recoverInterruptedTransactions];

	// Before any network operation, so the catalogue and any update already
	// offered are visible while offline
	[self loadCachedCatalogues];
}

// =========================
// = Serialized operations =
// =========================

- (void)enqueueOperation:(void(^)(dispatch_block_t done))operation
{
	[_pendingOperations addObject:operation];
	[self startNextOperationIfNeeded];
}

- (void)startNextOperationIfNeeded
{
	if(_runningOperation || _pendingOperations.count == 0)
		return;

	void(^operation)(dispatch_block_t) = _pendingOperations.firstObject;
	[_pendingOperations removeObjectAtIndex:0];

	[self willChangeValueForKey:@"busy"];
	_runningOperation = YES;
	[self didChangeValueForKey:@"busy"];

	__block BOOL didFinish = NO;
	operation(^{
		if(didFinish)
			return;
		didFinish = YES;

		// Asynchronously, so a queue of operations that all complete
		// synchronously does not recurse through the stack.
		dispatch_async(dispatch_get_main_queue(), ^{
			[self willChangeValueForKey:@"busy"];
			_runningOperation = NO;
			[self didChangeValueForKey:@"busy"];
			[self startNextOperationIfNeeded];
		});
	});
}

- (BOOL)isBusy
{
	return _runningOperation || _pendingOperations.count != 0;
}

- (NSArray<BundleSubscription*>*)subscriptions
{
	return _registry.subscriptions;
}

- (BOOL)saveRegistry:(NSError**)outError
{
	NSError* error;
	BOOL res = [_registry save:&error];
	if(!res)
		os_log_error(OS_LOG_DEFAULT, "Failed to save subscriptions: %{public}@", error.localizedDescription);
	if(outError)
		*outError = error;
	return res;
}

// Every mutation here is a promise to record what it did. A state file written
// by a newer TextMate cannot be rewritten without discarding what we do not
// understand in it, so that promise cannot be kept — and an operation that
// cannot be recorded must not touch the network or the disk in the first place.
- (NSError*)readOnlyRegistryError
{
	return _registry.isReadOnly ? SubscriptionError(BundleSubscriptionErrorCodeReadOnlyRegistry, @"%@", _registry.readOnlyReason ?: @"Subscriptions cannot be changed by this version.") : nil;
}

- (void)registryDidChange
{
	[self willChangeValueForKey:@"subscriptions"];
	[self didChangeValueForKey:@"subscriptions"];
	[NSNotificationCenter.defaultCenter postNotificationName:BundleSubscriptionsDidChangeNotification object:self];
}

// ==========================
// = Resolving a ref to SHA =
// ==========================

- (void)resolveRepositoryURL:(NSString*)urlString ref:(NSString*)ref completionHandler:(void(^)(NSString* sha, NSString* resolvedRef, NSError* error))handler
{
	github::repository_t repo = github::parse_url(to_s(urlString));
	if(!repo)
		return handler(nil, nil, SubscriptionError(BundleSubscriptionErrorCodeInvalidURL, @"Not a GitHub repository URL: %@", urlString));

	FetchDataAtURL(repo.ref_advertisement_url(), ^(NSData* data, NSError* error){
		if(!data)
			return handler(nil, nil, error);

		git::ref_advertisement_t advertisement = git::parse_ref_advertisement((char const*)data.bytes, data.length);
		if(!advertisement)
			return handler(nil, nil, SubscriptionError(BundleSubscriptionErrorCodeMalformedResponse, @"Unreadable ref advertisement from %@", urlString));

		// An omitted ref means “whatever the repository calls its default
		// branch”, which HEAD advertises. Guessing ‘main’ would silently pick
		// the wrong branch for every repository predating the rename.
		std::string effectiveRef = ref.length ? to_s(ref) : std::string();
		if(effectiveRef.empty())
		{
			effectiveRef = advertisement.default_branch();
			if(effectiveRef.empty())
				return handler(nil, nil, SubscriptionError(BundleSubscriptionErrorCodeUnavailable, @"%@ advertises no default branch — specify a branch, tag, or revision.", urlString));
		}

		std::string sha = advertisement.resolve(effectiveRef);
		if(sha.empty())
			return handler(nil, nil, SubscriptionError(BundleSubscriptionErrorCodeUnavailable, @"%@ does not have a branch, tag, or revision named ‘%s’.", urlString, effectiveRef.c_str()));

		handler(to_ns(sha), to_ns(effectiveRef), nil);
	});
}

// ===========================
// = Staging and installing =
// ===========================

- (NSString*)transactionsDirectory
{
	return [_installDirectory stringByAppendingPathComponent:kTransactionsDirectoryName];
}

// Fetches a revision into its own transaction directory and validates it there,
// while whatever is currently installed stays untouched and active. With an
// expected UUID the result is exactly that bundle; without one it is every
// bundle the repository holds.
- (void)stageRepositoryURL:(NSString*)urlString sha:(NSString*)sha expectedIdentifier:(NSUUID*)expectedIdentifier completionHandler:(void(^)(NSString* transactionDirectory, NSArray<NSString*>* stagedBundlePaths, NSError* error))handler
{
	[self stageRepositoryURL:urlString sha:sha expectedIdentifier:expectedIdentifier inTransactionDirectory:[self.transactionsDirectory stringByAppendingPathComponent:NSUUID.UUID.UUIDString] completionHandler:handler];
}

- (void)stageRepositoryURL:(NSString*)urlString sha:(NSString*)sha expectedIdentifier:(NSUUID*)expectedIdentifier inTransactionDirectory:(NSString*)transactionDirectory completionHandler:(void(^)(NSString* transactionDirectory, NSArray<NSString*>* stagedBundlePaths, NSError* error))handler
{
	github::repository_t repo = github::parse_url(to_s(urlString));
	if(!repo)
		return handler(nil, nil, SubscriptionError(BundleSubscriptionErrorCodeInvalidURL, @"Not a GitHub repository URL: %@", urlString));

	NSString* extractedPath = [transactionDirectory stringByAppendingPathComponent:@"New.tmbundle"];

	DownloadTarball(repo.tarball_url(to_s(sha)), extractedPath, ^(NSError* error){
		void(^fail)(NSError*) = ^(NSError* error){
			[NSFileManager.defaultManager removeItemAtPath:transactionDirectory error:nil];
			handler(nil, nil, error);
		};

		if(error)
			return fail(error);

		NSArray<NSString*>* bundlePaths = BundlePathsInExtractedTree(extractedPath);
		if(bundlePaths.count == 0)
			return fail(SubscriptionError(BundleSubscriptionErrorCodeNotABundle, @"%@ does not contain a bundle: no info.plist with a UUID, at its root or in a .tmbundle directory.", urlString));

		// For a tap install the expected UUID comes from the catalogue; for a
		// bare repository URL there is nothing to compare against yet, so the
		// first install is trust-on-first-use and every update thereafter is
		// held to what it recorded.
		if(expectedIdentifier)
		{
			for(NSString* path in bundlePaths)
			{
				if([BundleIdentifierAtPath(path) isEqual:expectedIdentifier])
					return handler(transactionDirectory, @[ path ], nil);
			}

			NSString* found = bundlePaths.count == 1 ? BundleIdentifierAtPath(bundlePaths.firstObject).UUIDString : [NSString stringWithFormat:@"%lu other bundles", bundlePaths.count];
			return fail(SubscriptionError(BundleSubscriptionErrorCodeIdentityMismatch, @"%@ contains %@, expected %@.", urlString, found, expectedIdentifier.UUIDString));
		}

		handler(transactionDirectory, bundlePaths, nil);
	});
}

// Moves a staged bundle into place and records it, and owns the whole commit:
// the state written here is the state that includes this subscription. The
// registry write is the commit point — until it lands, the copy on disk is not
// claimed by anything, and a first install that cannot be recorded is undone
// rather than left for the bundle index to find.
- (BOOL)commitStagedBundleAtPath:(NSString*)stagedBundlePath forSubscription:(BundleSubscription*)subscription sha:(NSString*)sha error:(NSError**)error
{
	NSString* relativePath = subscription.relativePath ?: SubscribedDirectoryName(subscription.name, subscription.identifier);
	NSString* destination  = [_bundlesDirectory stringByAppendingPathComponent:relativePath];
	BOOL isFirstInstall    = [_registry subscriptionWithIdentifier:subscription.identifier] == nil;

	NSFileManager* fm = NSFileManager.defaultManager;
	if(![fm createDirectoryAtPath:_bundlesDirectory withIntermediateDirectories:YES attributes:nil error:error])
		return NO;

	if([fm fileExistsAtPath:destination])
	{
		if(![fm replaceItemAtURL:[NSURL fileURLWithPath:destination isDirectory:YES] withItemAtURL:[NSURL fileURLWithPath:stagedBundlePath isDirectory:YES] backupItemName:nil options:NSFileManagerItemReplacementUsingNewMetadataOnly resultingItemURL:nil error:error])
			return NO;
	}
	else if(![fm moveItemAtPath:stagedBundlePath toPath:destination error:error])
	{
		return NO;
	}

	subscription.relativePath = relativePath;
	subscription.installedSHA = sha;
	subscription.availableSHA = sha;
	subscription.installedAt  = [NSDate date];
	subscription.updatedAt    = SourceDateAtPath(destination) ?: subscription.updatedAt;
	subscription.unavailable  = NO;
	subscription.statusMessage = nil;

	// In the state about to be written, not added after it: a save that does not
	// contain the new record is not a commit of anything.
	if(isFirstInstall)
		[_registry addSubscription:subscription];

	if(![self saveRegistry:error])
	{
		// A copy nothing claims would still be loaded by the bundle index and be
		// invisible in preferences. An *update* keeps its copy instead: the
		// registry still names the previous revision, so the next poll installs
		// this one again rather than leaving the user without the bundle.
		if(isFirstInstall)
		{
			[_registry removeSubscription:subscription];
			[fm removeItemAtPath:destination error:nil];
			subscription.relativePath = nil;
			subscription.installedSHA = nil;
			subscription.installedAt  = nil;
		}
		return NO;
	}

	[BundlesManager.sharedInstance reloadPath:destination recursive:YES];
	return YES;
}

- (void)removeTransactionDirectory:(NSString*)transactionDirectory
{
	if(transactionDirectory)
		[NSFileManager.defaultManager removeItemAtPath:transactionDirectory error:nil];
}

// A journal is what makes a destructive boundary recoverable, so it is written
// before the boundary and removed only once the far side is complete.
- (NSError*)writeJournal:(NSDictionary*)journal inDirectory:(NSString*)transactionDirectory
{
	NSError* error;
	if(![NSFileManager.defaultManager createDirectoryAtPath:transactionDirectory withIntermediateDirectories:YES attributes:nil error:&error])
		return error ?: SubscriptionError(BundleSubscriptionErrorCodeFileSystem, @"Failed to create %@.", transactionDirectory);

	NSData* data = [NSPropertyListSerialization dataWithPropertyList:journal format:NSPropertyListXMLFormat_v1_0 options:0 error:&error];
	if(!data || ![data writeToFile:[transactionDirectory stringByAppendingPathComponent:kJournalFileName] options:NSDataWritingAtomic error:&error])
		return error ?: SubscriptionError(BundleSubscriptionErrorCodeFileSystem, @"Failed to write the transaction journal in %@.", transactionDirectory);

	return nil;
}

// A crash between download and commit leaves a staging directory behind. With
// no journal it is claimed by nothing — no registry entry points into it — so
// it is simply discarded. A journal means a transaction was in flight, and its
// kind says which way it has to be finished.
- (void)recoverInterruptedTransactions
{
	// Recovery moves bundles about and rewrites the registry. A registry this
	// version may not write is one whose transactions it cannot finish either,
	// and a half-finished transaction is better left for the version that
	// started it than completed by one that would then fail to record it.
	if(_registry.isReadOnly)
		return os_log_error(OS_LOG_DEFAULT, "Leaving interrupted transactions alone: %{public}@", _registry.readOnlyReason);

	NSString* directory = self.transactionsDirectory;
	for(NSString* name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:directory error:nil])
	{
		NSString* path = [directory stringByAppendingPathComponent:name];

		NSDictionary* journal = [NSDictionary dictionaryWithContentsOfFile:[path stringByAppendingPathComponent:kJournalFileName]];
		if(!journal)
		{
			os_log(OS_LOG_DEFAULT, "Discarding interrupted bundle staging directory: %{public}@", path);
			[NSFileManager.defaultManager removeItemAtPath:path error:nil];
			continue;
		}

		// Matched against what we know rather than defaulted to Replace: a kind
		// written by a later version names a transaction whose rules we do not
		// have, and acting on it as though it were a Replace would finish it
		// the wrong way — or discard it along with the only copy it holds.
		NSString* kind = [journal[kJournalKindKey] isKindOfClass:[NSString class]] ? journal[kJournalKindKey] : (journal[kJournalKindKey] ? nil : kJournalKindReplace);

		if([kind isEqualToString:kJournalKindReplace])
			[self recoverReplaceTransactionWithJournal:journal directory:path];
		else if([kind isEqualToString:kJournalKindRestore])
			[self recoverRestoreTransactionWithJournal:journal directory:path];
		else if([kind isEqualToString:kJournalKindUninstall])
			[self recoverUninstallTransactionWithJournal:journal directory:path];
		else
			os_log_error(OS_LOG_DEFAULT, "Leaving a transaction of an unknown kind untouched: %{public}@", path);
	}
}

// Idempotent, and always converges on exactly one complete source: either the
// validated subscription with both state files written, or the official bundle
// as though the replacement had never started.
- (void)recoverReplaceTransactionWithJournal:(NSDictionary*)journal directory:(NSString*)directory
{
	NSFileManager* fm = NSFileManager.defaultManager;

	NSString* uuidString   = journal[@"uuid"];
	NSUUID* identifier     = [uuidString isKindOfClass:[NSString class]] ? [[NSUUID alloc] initWithUUIDString:uuidString] : nil;
	NSString* managedPath  = journal[@"managedPath"];
	NSString* backupPath   = journal[@"backupPath"];
	NSString* subscribedPath = journal[@"subscribedPath"];
	NSDictionary* record   = journal[@"subscription"];

	if(!identifier || ![managedPath isKindOfClass:[NSString class]] || ![backupPath isKindOfClass:[NSString class]] || ![subscribedPath isKindOfClass:[NSString class]] || ![record isKindOfClass:[NSDictionary class]])
	{
		os_log_error(OS_LOG_DEFAULT, "Discarding unreadable transaction journal: %{public}@", directory);
		[fm removeItemAtPath:directory error:nil];
		return;
	}

	BOOL replacementIsInPlace = [BundleIdentifierAtPath(subscribedPath) isEqual:identifier];
	BOOL officialIsRetired    = ![fm fileExistsAtPath:managedPath];

	if(replacementIsInPlace && officialIsRetired)
	{
		os_log(OS_LOG_DEFAULT, "Completing interrupted bundle replacement: %{public}@", subscribedPath);

		if(![_registry subscriptionWithIdentifier:identifier])
		{
			if(BundleSubscription* subscription = [[BundleSubscription alloc] initWithPlistRepresentation:record])
					[_registry addSubscription:subscription];
			else	os_log_error(OS_LOG_DEFAULT, "Unreadable subscription record in journal: %{public}@", directory);
		}

		// The replacement is the only copy there is now, so the journal stays
		// until the file agrees: without it, nothing would ever record it.
		NSError* error;
		if(![self saveRegistry:&error])
			return;

		if(Bundle* signedBundle = [BundlesManager.sharedInstance bundleWithIdentifier:identifier])
		{
			if(signedBundle.isInstalled)
				[BundlesManager.sharedInstance markBundleUninstalled:signedBundle];
		}
	}
	else
	{
		os_log(OS_LOG_DEFAULT, "Rolling back interrupted bundle replacement: %{public}@", managedPath);

		BOOL officialIsBack = [fm fileExistsAtPath:managedPath];
		if(!officialIsBack && [fm fileExistsAtPath:backupPath])
		{
			NSError* error;
			if(![fm moveItemAtPath:backupPath toPath:managedPath error:&error])
			{
				// The backup is inside the directory this method ends by
				// deleting, and the replacement is what would be deleted before
				// that. Going on from here is how one bundle becomes none, so
				// everything stays where it is and the next launch tries again.
				os_log_error(OS_LOG_DEFAULT, "Failed to restore %{public}@: %{public}@ — keeping the backup for another attempt.", managedPath, error.localizedDescription);
				return;
			}
			officialIsBack = YES;
		}

		if(!officialIsBack)
			os_log_error(OS_LOG_DEFAULT, "Nothing left to restore for %{public}@: neither the official bundle nor the backup is there.", managedPath);

		[fm removeItemAtPath:subscribedPath error:nil];

		// The registry write is step 5, so an entry can only be here if it was
		// this transaction that put it there.
		BundleSubscription* subscription = [_registry subscriptionWithIdentifier:identifier];
		if(subscription.replacesSigned)
		{
			[_registry removeSubscription:subscription];

			// Dropping that record is part of the rollback, so the journal has
			// to outlive it too: a file still claiming a replacement that is no
			// longer anywhere on disk needs a next launch that can tell why.
			NSError* error;
			if(![self saveRegistry:&error])
			{
				[_registry addSubscription:subscription];
				return;
			}
		}
	}

	[fm removeItemAtPath:directory error:nil];
}

// The mirror of the above, and it turns on one question: did the official
// bundle land? If it did, the subscription and its record have to go, and this
// finishes that. If it did not, the subscription never stopped being the
// installed copy and there is nothing to undo but the journal.
- (void)recoverRestoreTransactionWithJournal:(NSDictionary*)journal directory:(NSString*)directory
{
	NSFileManager* fm = NSFileManager.defaultManager;

	NSString* uuidString     = journal[@"uuid"];
	NSUUID* identifier       = [uuidString isKindOfClass:[NSString class]] ? [[NSUUID alloc] initWithUUIDString:uuidString] : nil;
	NSString* subscribedPath = journal[@"subscribedPath"];

	if(!identifier || ![subscribedPath isKindOfClass:[NSString class]])
	{
		os_log_error(OS_LOG_DEFAULT, "Discarding unreadable transaction journal: %{public}@", directory);
		[fm removeItemAtPath:directory error:nil];
		return;
	}

	Bundle* signedBundle = [BundlesManager.sharedInstance bundleWithIdentifier:identifier];
	BOOL officialIsInPlace = signedBundle.isInstalled && signedBundle.path && [fm fileExistsAtPath:signedBundle.path];

	if(officialIsInPlace)
	{
		os_log(OS_LOG_DEFAULT, "Completing interrupted bundle restore: %{public}@", signedBundle.path);

		// Keeps the journal on failure: until the subscription is gone from
		// both the disk and the file, this is still half a restore.
		if(NSError* error = [self completeRestoreOfSubscriptionWithIdentifier:identifier subscribedPath:subscribedPath])
			return os_log_error(OS_LOG_DEFAULT, "Failed to complete bundle restore: %{public}@", error.localizedDescription);
	}
	else
	{
		os_log(OS_LOG_DEFAULT, "Discarding interrupted bundle restore: the official bundle never arrived, so %{public}@ is still the installed copy.", subscribedPath);
	}

	[fm removeItemAtPath:directory error:nil];
}

// An uninstall is interrupted between setting the copy aside and the record
// leaving the file, and the file is what decides which it was: a record still
// there means the removal never committed and the copy has to come back, and a
// record already gone means the backup is what is left of a finished removal.
- (void)recoverUninstallTransactionWithJournal:(NSDictionary*)journal directory:(NSString*)directory
{
	NSFileManager* fm = NSFileManager.defaultManager;

	NSString* uuidString     = journal[@"uuid"];
	NSUUID* identifier       = [uuidString isKindOfClass:[NSString class]] ? [[NSUUID alloc] initWithUUIDString:uuidString] : nil;
	NSString* subscribedPath = journal[@"subscribedPath"];
	NSString* backupPath     = journal[@"backupPath"];

	if(!identifier || ![subscribedPath isKindOfClass:[NSString class]] || ![backupPath isKindOfClass:[NSString class]])
	{
		os_log_error(OS_LOG_DEFAULT, "Discarding unreadable transaction journal: %{public}@", directory);
		[fm removeItemAtPath:directory error:nil];
		return;
	}

	if([_registry subscriptionWithIdentifier:identifier])
	{
		os_log(OS_LOG_DEFAULT, "Rolling back interrupted uninstall: %{public}@", subscribedPath);

		if([fm fileExistsAtPath:backupPath] && ![fm fileExistsAtPath:subscribedPath])
		{
			NSError* error;
			if(![fm moveItemAtPath:backupPath toPath:subscribedPath error:&error])
			{
				// The backup is the only copy, and this directory is what holds it
				os_log_error(OS_LOG_DEFAULT, "Failed to restore %{public}@: %{public}@ — keeping the backup for another attempt.", subscribedPath, error.localizedDescription);
				return;
			}
		}
	}
	else
	{
		os_log(OS_LOG_DEFAULT, "Completing interrupted uninstall: %{public}@", subscribedPath);
		[fm removeItemAtPath:subscribedPath error:nil];
	}

	[fm removeItemAtPath:directory error:nil];
}

// Steps 4 and 5 of the restore: the subscribed copy and the record naming it go
// together, and neither the caller nor recovery may drop the journal until both
// have. Idempotent — it is called from both.
- (NSError*)completeRestoreOfSubscriptionWithIdentifier:(NSUUID*)identifier subscribedPath:(NSString*)subscribedPath
{
	if(NSError* error = [self removeInstalledCopyAtPath:subscribedPath])
		return error;

	if(BundleSubscription* subscription = [_registry subscriptionWithIdentifier:identifier])
		[_registry removeSubscription:subscription];

	NSError* error;
	return [self saveRegistry:&error] ? nil : error;
}

// =============
// = Collision =
// =============

- (BundleCollisionKind)collisionKindForBundleIdentifier:(NSUUID*)identifier existingName:(NSString**)outName
{
	std::vector<bundles::item_ptr> items = bundles::query(bundles::kFieldAny, NULL_STR, scope::wildcard, bundles::kItemTypeBundle, to_s(identifier), false, true);
	if(items.empty())
		return BundleCollisionKindNone;

	bundles::item_ptr item = items.front();
	if(outName)
		*outName = to_ns(item->name());

	// The check runs against the whole loaded index rather than just the two
	// directories we own: ‘Subscribed’ also precedes the machine-wide
	// locations, so a subscription can shadow those too.
	std::string managedPrefix    = oak::application_t::support("Managed/Bundles");
	std::string subscribedPrefix = to_s(_bundlesDirectory);

	bool isSigned = false, isSubscribed = false;
	for(auto const& path : item->paths())
	{
		if(path.compare(0, managedPrefix.size(), managedPrefix) == 0)
			isSigned = true;
		else if(path.compare(0, subscribedPrefix.size(), subscribedPrefix) == 0)
			isSubscribed = true;
	}

	if(isSigned)
	{
		for(Bundle* bundle in BundlesManager.sharedInstance.bundles)
		{
			if([bundle.identifier isEqual:identifier])
				return bundle.isMandatory ? BundleCollisionKindSignedMandatory : BundleCollisionKindSigned;
		}
		return BundleCollisionKindSigned;
	}

	return isSubscribed ? BundleCollisionKindSubscription : BundleCollisionKindLocal;
}

- (NSError*)errorForCollisionKind:(BundleCollisionKind)kind name:(NSString*)name
{
	switch(kind)
	{
		case BundleCollisionKindSigned:
			return SubscriptionError(BundleSubscriptionErrorCodeReplaceRequired, @"The official ‘%@’ bundle is installed. Replacing it gives up signature verification for that bundle.", name);
		case BundleCollisionKindSignedMandatory:
			return SubscriptionError(BundleSubscriptionErrorCodeMandatory, @"‘%@’ is a mandatory bundle and cannot be replaced by a subscription.", name);
		case BundleCollisionKindSubscription:
			return SubscriptionError(BundleSubscriptionErrorCodeCollision, @"‘%@’ is already installed from another subscription.", name);
		case BundleCollisionKindLocal:
			return SubscriptionError(BundleSubscriptionErrorCodeCollision, @"A bundle named ‘%@’ with the same UUID is already installed.", name);
		default:
			return nil;
	}
}

// ==================
// = Public actions =
// ==================

- (void)addSubscriptionForRepositoryURL:(NSString*)urlString ref:(NSString*)ref completionHandler:(void(^)(NSArray<BundleSubscription*>*, NSError*))handler
{
	[self enqueueOperation:^(dispatch_block_t done){
		void(^finish)(NSArray<BundleSubscription*>*, NSError*) = ^(NSArray<BundleSubscription*>* subscriptions, NSError* error){
			if(handler)
				handler(subscriptions, error);
			done();
		};

		if(NSError* error = self.readOnlyRegistryError)
			return finish(nil, error);

		github::repository_t repo = github::parse_url(to_s(urlString));
		if(!repo)
			return finish(nil, SubscriptionError(BundleSubscriptionErrorCodeInvalidURL, @"Not a GitHub repository URL: %@", urlString));

		NSString* canonicalURL = to_ns(repo.canonical_url());
		for(BundleSubscription* existing in _registry.subscriptions)
		{
			if([existing.url isEqualToString:canonicalURL])
				return finish(nil, SubscriptionError(BundleSubscriptionErrorCodeCollision, @"%@ is already subscribed.", canonicalURL));
		}

		[self resolveRepositoryURL:canonicalURL ref:ref completionHandler:^(NSString* sha, NSString* resolvedRef, NSError* error){
			if(!sha)
				return finish(nil, error);

			NSString* repositoryName = to_ns(repo.name);
			[self stageRepositoryURL:canonicalURL sha:sha expectedIdentifier:nil completionHandler:^(NSString* transactionDirectory, NSArray<NSString*>* stagedBundlePaths, NSError* error){
				if(!stagedBundlePaths)
					return finish(nil, error);

				NSError* firstError = nil;
				NSArray<BundleSubscription*>* installed = [self installStagedBundlesAtPaths:stagedBundlePaths fromRepositoryURL:canonicalURL name:repositoryName sha:sha ref:resolvedRef error:&firstError];

				[self removeTransactionDirectory:transactionDirectory];
				[self registryDidChange];
				finish(installed.count ? installed : nil, installed.count ? nil : firstError);
			}];
		}];
	}];
}

// One repository, one commit each: a bundle that collides or cannot be recorded
// costs only itself, and what comes back is what is now installed.
- (NSArray<BundleSubscription*>*)installStagedBundlesAtPaths:(NSArray<NSString*>*)stagedBundlePaths fromRepositoryURL:(NSString*)canonicalURL name:(NSString*)repositoryName sha:(NSString*)sha ref:(NSString*)resolvedRef error:(NSError**)outError
{
	NSMutableArray<BundleSubscription*>* installed = [NSMutableArray array];
	NSMutableSet<NSUUID*>* seen = [NSMutableSet set];
	NSError* firstError = nil;

	for(NSString* stagedBundlePath in stagedBundlePaths)
	{
		NSUUID* identifier = BundleIdentifierAtPath(stagedBundlePath);

		// Two directories in one repository claiming the same bundle: first
		// wins, as in a catalogue (§9.2). The collision check below cannot see
		// the one just installed — the index rebuild it schedules has not run
		// yet — so the second would be taken for an update of the first and
		// land under a name no record points at.
		if([seen containsObject:identifier])
		{
			os_log_error(OS_LOG_DEFAULT, "Skipping %{public}@: %{public}@ already provides that bundle.", stagedBundlePath.lastPathComponent, canonicalURL);
			continue;
		}
		[seen addObject:identifier];

		NSString* existingName;
		BundleCollisionKind collision = [self collisionKindForBundleIdentifier:identifier existingName:&existingName];
		if(collision != BundleCollisionKindNone)
		{
			// Silently shadowing would leave the user with a subscription that
			// installed and does nothing.
			firstError = firstError ?: [self errorForCollisionKind:collision name:existingName];
			continue;
		}

		BundleSubscription* subscription = [[BundleSubscription alloc] initWithIdentifier:identifier url:canonicalURL];
		subscription.name        = BundleNameAtPath(stagedBundlePath) ?: repositoryName;
		subscription.refMode     = BundleSubscriptionRefModeUser;
		subscription.trackingRef = resolvedRef;
		subscription.category    = @"Subscribed";

		NSError* commitError;
		if(![self commitStagedBundleAtPath:stagedBundlePath forSubscription:subscription sha:sha error:&commitError])
		{
			firstError = firstError ?: (commitError ?: SubscriptionError(BundleSubscriptionErrorCodeFileSystem, @"Failed to install %@.", canonicalURL));
			continue;
		}

		[installed addObject:subscription];
	}

	if(outError)
		*outError = firstError;
	return installed;
}

- (void)updateSubscription:(BundleSubscription*)subscription completionHandler:(void(^)(NSError*))handler
{
	[self enqueueOperation:^(dispatch_block_t done){
		if(NSError* error = self.readOnlyRegistryError)
		{
			if(handler)
				handler(error);
			return done();
		}

		[self updateSubscription:subscription applyUpdate:YES completionHandler:^(NSError* error){
			if(handler)
				handler(error);
			done();
		}];
	}];
}

// One subscription's share of a poll: resolve, persist what was resolved, and
// install only when allowed to. Runs inside an already-serialized operation.
- (void)updateSubscription:(BundleSubscription*)subscription applyUpdate:(BOOL)applyUpdate completionHandler:(void(^)(NSError*))handler
{
	[self resolveRepositoryURL:subscription.url ref:subscription.effectiveRef completionHandler:^(NSString* sha, NSString* resolvedRef, NSError* error){
		if(!sha)
		{
			// Keep the last known availableSHA: an unreachable upstream is not
			// evidence that a previously offered update went away.
			subscription.unavailable   = YES;
			subscription.statusMessage = error.localizedDescription;
			[self registryDidChange];
			return handler(error);
		}

		subscription.unavailable   = NO;
		subscription.statusMessage = nil;

		if(![sha isEqualToString:subscription.availableSHA])
		{
			subscription.availableSHA = sha;
			if(!_registry.isReadOnly)
			{
				NSError* saveError;
				[self saveRegistry:&saveError];
			}
		}

		if([sha isEqualToString:subscription.installedSHA])
		{
			[self registryDidChange];
			return handler(nil);
		}

		if(!applyUpdate)
		{
			[self registryDidChange];
			return handler(nil);
		}

		[self stageRepositoryURL:subscription.url sha:sha expectedIdentifier:subscription.identifier completionHandler:^(NSString* transactionDirectory, NSArray<NSString*>* stagedBundlePaths, NSError* error){
			if(!stagedBundlePaths)
			{
				subscription.statusMessage = error.localizedDescription;
				[self registryDidChange];
				return handler(error);
			}

			NSError* commitError;
			BOOL didCommit = [self commitStagedBundleAtPath:stagedBundlePaths.firstObject forSubscription:subscription sha:sha error:&commitError];
			[self removeTransactionDirectory:transactionDirectory];
			[self registryDidChange];

			handler(didCommit ? nil : (commitError ?: SubscriptionError(BundleSubscriptionErrorCodeFileSystem, @"Failed to update %@.", subscription.name)));
		}];
	}];
}

- (void)pollSubscriptionsWithCompletionHandler:(void(^)(void))handler
{
	[self enqueueOperation:^(dispatch_block_t done){
		// A poll it cannot record is still allowed to *look*: resolving refs
		// costs nothing durable and keeps the list honest about what is out
		// there. Refreshing catalogues and installing updates do not qualify.
		if(_registry.isReadOnly)
		{
			return [self pollSubscriptions:_registry.subscriptions atIndex:0 applyUpdates:NO completionHandler:^{
				[self registryDidChange];
				if(handler)
					handler();
				done();
			}];
		}

		// Catalogues first: a refresh may advance a catalogue-mode subscription’s
		// ref, and polling should act on the ref the tap publishes now.
		[self refreshTaps:_registry.taps atIndex:0 completionHandler:^{
			// Sequential rather than fanned out: fifty simultaneous connections to
			// github.com on a background wake gains nothing at a daily cadence.
			[self pollSubscriptions:_registry.subscriptions atIndex:0 applyUpdates:YES completionHandler:^{
				[self registryDidChange];
				if(handler)
					handler();
				done();
			}];
		}];
	}];
}

- (void)pollSubscriptions:(NSArray<BundleSubscription*>*)subscriptions atIndex:(NSUInteger)index applyUpdates:(BOOL)applyUpdates completionHandler:(dispatch_block_t)handler
{
	if(index == subscriptions.count)
		return handler();

	BundleSubscription* subscription = subscriptions[index];

	// A catalogue that moved a bundle to a different repository is a source
	// switch, not an update: it is offered, never applied (§9.2).
	BOOL applyUpdate = applyUpdates && subscription.autoUpdate && !subscription.isSourceChanged;

	[self updateSubscription:subscription applyUpdate:applyUpdate completionHandler:^(NSError* error){
		// One subscription being unreachable says nothing about the next one
		if(error)
			os_log_error(OS_LOG_DEFAULT, "%{public}@: %{public}@", subscription.name, error.localizedDescription);
		[self pollSubscriptions:subscriptions atIndex:index + 1 applyUpdates:applyUpdates completionHandler:handler];
	}];
}

- (void)uninstallSubscription:(BundleSubscription*)subscription completionHandler:(void(^)(NSError*))handler
{
	[self enqueueOperation:^(dispatch_block_t done){
		void(^finish)(NSError*) = ^(NSError* error){
			if(handler)
				handler(error);
			done();
		};

		if(NSError* error = self.readOnlyRegistryError)
			return finish(error);

		// Deleting the copy outright would put the destructive half before the
		// commit: a state write that then failed would leave the file naming a
		// bundle that is not there, with nothing left to put back. So the copy
		// is set aside, journalled, and only discarded once the record is gone
		// from the file — and moved back if it never was.
		NSString* subscribedPath       = subscription.relativePath ? [_bundlesDirectory stringByAppendingPathComponent:subscription.relativePath] : nil;
		BOOL hasInstalledCopy          = subscribedPath && [NSFileManager.defaultManager fileExistsAtPath:subscribedPath];
		NSString* transactionDirectory = nil;
		NSString* backupPath           = nil;

		if(hasInstalledCopy)
		{
			transactionDirectory = [self.transactionsDirectory stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
			backupPath           = [transactionDirectory stringByAppendingPathComponent:@"Backup.tmbundle"];

			NSDictionary* journal = @{
				kJournalKindKey:   kJournalKindUninstall,
				@"uuid":           subscription.identifier.UUIDString,
				@"subscribedPath": subscribedPath,
				@"backupPath":     backupPath,
				@"subscription":   subscription.plistRepresentation,
			};

			if(NSError* error = [self writeJournal:journal inDirectory:transactionDirectory])
				return finish(error);

			NSError* error;
			if(![NSFileManager.defaultManager moveItemAtPath:subscribedPath toPath:backupPath error:&error])
			{
				[self removeTransactionDirectory:transactionDirectory];
				return finish(error ?: SubscriptionError(BundleSubscriptionErrorCodeFileSystem, @"Failed to remove %@.", subscribedPath));
			}
		}

		[_registry removeSubscription:subscription];

		NSError* error;
		if(![self saveRegistry:&error])
		{
			// The record is still on file, so the copy it names has to be there
			if(hasInstalledCopy && ![NSFileManager.defaultManager moveItemAtPath:backupPath toPath:subscribedPath error:nil])
				os_log_error(OS_LOG_DEFAULT, "Failed to put %{public}@ back; the journal is kept for the next launch.", subscribedPath);
			else
				[self removeTransactionDirectory:transactionDirectory];

			[_registry addSubscription:subscription];
			[self registryDidChange];
			return finish(error);
		}

		if(hasInstalledCopy)
		{
			[BundlesManager.sharedInstance erasePath:subscribedPath];
			[self removeTransactionDirectory:transactionDirectory];
		}

		[self registryDidChange];
		finish(nil);
	}];
}

// The settings share one shape: change the subscription, save, and put the
// change back if the save does not land. A policy that is only in memory is one
// the next poll acts on and the next launch has never heard of — the same
// uncommitted state a failed catalogue refresh must not leave behind. They run
// on the operation queue for the same reason everything else does: a poll must
// not read half of a change.
//
// The transaction block reads the old value *and* writes the new one, and hands
// back what undoes it — because the old value is whatever the operation before
// this one committed, not what the subscription held when the caller asked. Two
// changes queued behind a slow fetch would otherwise both undo to the value
// from before the first of them.
- (void)changeSubscription:(BundleSubscription*)subscription transaction:(dispatch_block_t(^)(void))transaction completionHandler:(void(^)(NSError*))handler
{
	[self enqueueOperation:^(dispatch_block_t done){
		void(^finish)(NSError*) = ^(NSError* error){
			if(error)
				os_log_error(OS_LOG_DEFAULT, "%{public}@: %{public}@", subscription.name, error.localizedDescription);
			if(handler)
				handler(error);
			done();
		};

		if(NSError* error = self.readOnlyRegistryError)
			return finish(error);

		dispatch_block_t undo = transaction();

		NSError* error;
		if(![self saveRegistry:&error])
			undo();

		[self registryDidChange];
		finish(error);
	}];
}

- (void)setRef:(NSString*)ref forSubscription:(BundleSubscription*)subscription
{
	[self setRef:ref forSubscription:subscription completionHandler:nil];
}

- (void)setRef:(NSString*)ref forSubscription:(BundleSubscription*)subscription completionHandler:(void(^)(NSError*))handler
{
	[self changeSubscription:subscription transaction:^dispatch_block_t{
		NSString* previousRef                  = subscription.trackingRef;
		BundleSubscriptionRefMode previousMode = subscription.refMode;

		// A user-selected ref lives in trackingRef, where no catalogue refresh
		// will overwrite it; the catalogue's own value is left where it is so
		// that “Follow catalogue” can restore it.
		subscription.trackingRef = ref.length ? ref : nil;
		subscription.refMode     = BundleSubscriptionRefModeUser;

		return ^{
			subscription.trackingRef = previousRef;
			subscription.refMode     = previousMode;
		};
	} completionHandler:handler];
}

- (void)followCatalogueForSubscription:(BundleSubscription*)subscription
{
	[self followCatalogueForSubscription:subscription completionHandler:nil];
}

- (void)followCatalogueForSubscription:(BundleSubscription*)subscription completionHandler:(void(^)(NSError*))handler
{
	if(!subscription.tapIdentifier)
	{
		if(handler)
			handler(nil);
		return;
	}

	[self changeSubscription:subscription transaction:^dispatch_block_t{
		BundleSubscriptionRefMode previousMode = subscription.refMode;
		subscription.refMode = BundleSubscriptionRefModeCatalogue;
		return ^{ subscription.refMode = previousMode; };
	} completionHandler:handler];
}

- (void)setAutoUpdate:(BOOL)flag forSubscription:(BundleSubscription*)subscription
{
	[self setAutoUpdate:flag forSubscription:subscription completionHandler:nil];
}

- (void)setAutoUpdate:(BOOL)flag forSubscription:(BundleSubscription*)subscription completionHandler:(void(^)(NSError*))handler
{
	[self changeSubscription:subscription transaction:^dispatch_block_t{
		BOOL previousFlag = subscription.autoUpdate;
		subscription.autoUpdate = flag;
		return ^{ subscription.autoUpdate = previousFlag; };
	} completionHandler:handler];
}

- (NSURL*)compareURLForSubscription:(BundleSubscription*)subscription
{
	github::repository_t repo = github::parse_url(to_s(subscription.url));
	if(!repo || !subscription.installedSHA || !subscription.hasUpdate)
		return nil;
	return [NSURL URLWithString:to_ns(repo.compare_url(to_s(subscription.installedSHA), to_s(subscription.availableSHA)))];
}

// ========
// = Taps =
// ========

- (NSArray<BundleTap*>*)taps
{
	return _registry.taps;
}

- (NSArray<BundleCandidate*>*)candidates
{
	NSMutableArray* res = [NSMutableArray array];
	for(BundleTap* tap in _registry.taps)
	{
		if(BundleTapCatalogue* catalogue = _catalogues[tap.identifier])
			[res addObjectsFromArray:catalogue.candidates];
	}
	return res;
}

- (BundleTapCatalogue*)catalogueForTap:(BundleTap*)tap
{
	return _catalogues[tap.identifier];
}

- (BundleTap*)tapForCandidate:(BundleCandidate*)candidate
{
	return [_registry tapWithIdentifier:candidate.tapIdentifier];
}

- (BundleTap*)tapForSubscription:(BundleSubscription*)subscription
{
	return subscription.tapIdentifier ? [_registry tapWithIdentifier:subscription.tapIdentifier] : nil;
}

- (BundleSubscription*)subscriptionWithIdentifier:(NSUUID*)identifier
{
	return [_registry subscriptionWithIdentifier:identifier];
}

- (NSString*)cacheDirectoryForTapIdentifier:(NSString*)identifier
{
	return [[_installDirectory stringByAppendingPathComponent:@"Cache/Taps"] stringByAppendingPathComponent:identifier];
}

- (NSString*)cachePathForTapIdentifier:(NSString*)identifier catalogueSHA:(NSString*)sha
{
	return [[self cacheDirectoryForTapIdentifier:identifier] stringByAppendingPathComponent:[sha stringByAppendingPathExtension:@"plist"]];
}

// catalogueSHA is a pointer into immutable cache content, so what it names
// either parses as the catalogue that SHA published or is not there at all.
- (void)loadCachedCatalogues
{
	for(BundleTap* tap in _registry.taps)
	{
		if(!tap.catalogueSHA)
			continue;

		NSString* path = [self cachePathForTapIdentifier:tap.identifier catalogueSHA:tap.catalogueSHA];
		NSDictionary* plist = [NSDictionary dictionaryWithContentsOfFile:path];

		// Missing or corrupt: ignore it and fetch that SHA again later, without
		// first changing the registry — the pointer is still the best thing we know.
		if(BundleTapCatalogue* catalogue = plist ? [BundleTapCatalogue catalogueWithPlist:plist tapIdentifier:tap.identifier error:nil] : nil)
				_catalogues[tap.identifier] = catalogue;
		else	os_log_error(OS_LOG_DEFAULT, "Unusable catalogue cache for %{public}@: %{public}@", tap.name ?: tap.url, path);
	}

	[self applyCataloguesToSubscriptions];
}

- (void)addSourceWithURL:(NSString*)urlString ref:(NSString*)ref completionHandler:(void(^)(BundleTap*, NSArray<BundleSubscription*>*, NSError*))handler
{
	// Weak because the second operation is started from inside the first one’s
	// handler, which the manager is holding while it runs
	__weak BundleSubscriptionManager* weakSelf = self;

	[self addTapWithURL:urlString ref:ref completionHandler:^(BundleTap* tap, NSError* error){
		BundleSubscriptionManager* manager = weakSelf;
		if(!manager || !error || error.code != BundleSubscriptionErrorCodeNotATap)
			return handler(tap, nil, error);

		// It answered, it just has no catalogue — so it is a bundle repository,
		// and the fetch that established that was the only cost of finding out.
		[manager addSubscriptionForRepositoryURL:urlString ref:ref completionHandler:^(NSArray<BundleSubscription*>* subscriptions, NSError* error){
			handler(nil, subscriptions, error);
		}];
	}];
}

- (void)addTapWithURL:(NSString*)urlString ref:(NSString*)ref completionHandler:(void(^)(BundleTap*, NSError*))handler
{
	[self enqueueOperation:^(dispatch_block_t done){
		void(^finish)(BundleTap*, NSError*) = ^(BundleTap* tap, NSError* error){
			if(handler)
				handler(tap, error);
			done();
		};

		if(NSError* error = self.readOnlyRegistryError)
			return finish(nil, error);

		github::repository_t repo = github::parse_url(to_s(urlString));
		if(!repo)
			return finish(nil, SubscriptionError(BundleSubscriptionErrorCodeInvalidURL, @"Not a GitHub repository URL: %@", urlString));

		NSString* canonicalURL = to_ns(repo.canonical_url());
		for(BundleTap* existing in _registry.taps)
		{
			if([existing.url isEqualToString:canonicalURL])
				return finish(nil, SubscriptionError(BundleSubscriptionErrorCodeCollision, @"%@ is already registered as a tap.", canonicalURL));
		}

		BundleTap* tap = [[BundleTap alloc] initWithIdentifier:NSUUID.UUID.UUIDString url:canonicalURL trackingRef:(ref.length ? ref : nil)];
		[self fetchCatalogueForTap:tap completionHandler:^(BundleTapCatalogue* catalogue, NSData* data, NSString* sha, NSString* resolvedRef, NSError* error){
			// A new tap has no revision to already be at, so a catalogue is what
			// the fetch owes us here
			if(error || !catalogue)
				return finish(nil, error ?: SubscriptionError(BundleSubscriptionErrorCodeMalformedResponse, @"Fetched no catalogue for %@.", canonicalURL));

			if(NSError* commitError = [self commitNewTap:tap catalogue:catalogue data:data sha:sha resolvedRef:resolvedRef])
				return finish(nil, commitError);

			// Published only once the file holds it, so an add that reports a
			// failure is one Preferences never saw and a restart never finds.
			[self registryDidChange];
			finish(tap, nil);
		}];
	}];
}

// Registering a tap is its catalogue's first commit: the tap is in the registry
// for the state write that records the catalogue, and out again — along with the
// catalogue and the cache file written for it — if that write fails.
- (NSError*)commitNewTap:(BundleTap*)tap catalogue:(BundleTapCatalogue*)catalogue data:(NSData*)data sha:(NSString*)sha resolvedRef:(NSString*)resolvedRef
{
	[_registry addTap:tap];

	if(NSError* error = [self commitCatalogue:catalogue data:data sha:sha resolvedRef:resolvedRef forTap:tap])
	{
		[_registry removeTap:tap];
		[_catalogues removeObjectForKey:tap.identifier];
		[NSFileManager.defaultManager removeItemAtPath:[self cacheDirectoryForTapIdentifier:tap.identifier] error:nil];
		return error;
	}

	return nil;
}

- (void)refreshTap:(BundleTap*)tap completionHandler:(void(^)(NSError*))handler
{
	[self enqueueOperation:^(dispatch_block_t done){
		if(NSError* error = self.readOnlyRegistryError)
		{
			if(handler)
				handler(error);
			return done();
		}

		[self refreshTapWithoutSerializing:tap completionHandler:^(NSError* error){
			NSError* saveError;
			[self saveRegistry:&saveError];
			[self registryDidChange];

			if(handler)
				handler(error);
			done();
		}];
	}];
}

// The tap's own branch, which is a setting like the ones above and is treated
// like one: it is only in effect if the catalogue fetched with it committed.
- (void)setRef:(NSString*)ref forTap:(BundleTap*)tap completionHandler:(void(^)(NSError*))handler
{
	[self enqueueOperation:^(dispatch_block_t done){
		void(^finish)(NSError*) = ^(NSError* error){
			if(handler)
				handler(error);
			done();
		};

		if(NSError* error = self.readOnlyRegistryError)
			return finish(error);

		NSString* previousRef = tap.trackingRef;
		tap.trackingRef = ref.length ? ref : nil;

		[self refreshTapWithoutSerializing:tap completionHandler:^(NSError* refreshError){
			NSError* error = refreshError;
			if(!error)
			{
				// The refresh saves when the catalogue moved; this covers the
				// case where it did not, and the ref is the only change.
				NSError* saveError;
				if(![self saveRegistry:&saveError])
					error = saveError;
			}

			if(error)
				tap.trackingRef = previousRef;

			[self registryDidChange];
			finish(error);
		}];
	}];
}

- (void)refreshTaps:(NSArray<BundleTap*>*)taps atIndex:(NSUInteger)index completionHandler:(dispatch_block_t)handler
{
	if(index == taps.count)
		return handler();

	BundleTap* tap = taps[index];
	[self refreshTapWithoutSerializing:tap completionHandler:^(NSError* error){
		if(error)
			os_log_error(OS_LOG_DEFAULT, "Failed to refresh tap %{public}@: %{public}@", tap.name ?: tap.url, error.localizedDescription);
		[self refreshTaps:taps atIndex:index + 1 completionHandler:handler];
	}];
}

// §6.1. The state write is the commit point; a failed fetch, a malformed
// catalogue, or a failed write all leave the previously referenced SHA and its
// cache file exactly as they were.
- (void)refreshTapWithoutSerializing:(BundleTap*)tap completionHandler:(void(^)(NSError*))handler
{
	[self fetchCatalogueForTap:tap completionHandler:^(BundleTapCatalogue* catalogue, NSData* data, NSString* sha, NSString* resolvedRef, NSError* error){
		if(error || !catalogue)
			return handler(error);
		handler([self commitCatalogue:catalogue data:data sha:sha resolvedRef:resolvedRef forTap:tap]);
	}];
}

// The fetch half: resolve the tap's ref, read the catalogue at exactly that
// revision, and validate it. Commits nothing — a catalogue with no error is one
// the caller has still to record. Both are nil when the tap is already at that
// revision and there is nothing to record.
- (void)fetchCatalogueForTap:(BundleTap*)tap completionHandler:(void(^)(BundleTapCatalogue* catalogue, NSData* data, NSString* sha, NSString* resolvedRef, NSError* error))handler
{
	[self resolveRepositoryURL:tap.url ref:tap.trackingRef completionHandler:^(NSString* sha, NSString* resolvedRef, NSError* error){
		if(!sha)
			return handler(nil, nil, nil, nil, error);

		if([sha isEqualToString:tap.catalogueSHA] && _catalogues[tap.identifier])
		{
			tap.fetchedAt = [NSDate date];
			return handler(nil, nil, sha, resolvedRef, nil);
		}

		github::repository_t repo = github::parse_url(to_s(tap.url));
		if(!repo)
			return handler(nil, nil, nil, nil, SubscriptionError(BundleSubscriptionErrorCodeInvalidURL, @"Not a GitHub repository URL: %@", tap.url));

		// Fetched at the revision just resolved rather than by branch name:
		// asking raw.githubusercontent for a branch races its CDN cache, which
		// would leave the registry claiming a revision the cache may not hold.
		FetchDataAtURL(repo.raw_url(to_s(sha), "Taps/bundles.plist"), ^(NSData* data, NSError* error){
			if(!data)
				return handler(nil, nil, nil, nil, error.code == BundleSubscriptionErrorCodeUnavailable ? SubscriptionError(BundleSubscriptionErrorCodeNotATap, @"%@ has no Taps/bundles.plist at %@.", tap.url, [sha substringToIndex:7]) : error);

			NSDictionary* plist = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:nil error:nil];

			NSError* parseError;
			BundleTapCatalogue* catalogue = [BundleTapCatalogue catalogueWithPlist:plist tapIdentifier:tap.identifier error:&parseError];
			if(!catalogue)
				return handler(nil, nil, nil, nil, parseError ?: SubscriptionError(BundleSubscriptionErrorCodeMalformedResponse, @"Unreadable catalogue at %@.", tap.url));

			handler(catalogue, data, sha, resolvedRef, nil);
		});
	}];
}

// Everything the refresh does once it holds a catalogue it has validated: the
// cache file, the state write, and putting memory back where the file left it
// if that write fails. Separate from the fetch so that the half with a failure
// path can be exercised without a network.
- (NSError*)commitCatalogue:(BundleTapCatalogue*)catalogue data:(NSData*)data sha:(NSString*)sha resolvedRef:(NSString*)resolvedRef forTap:(BundleTap*)tap
{
	if(NSError* cacheError = [self writeCatalogueData:data forTapIdentifier:tap.identifier catalogueSHA:sha])
		return cacheError;

	NSString* previousSHA  = tap.catalogueSHA;
	NSString* previousName = tap.name;
	NSString* previousRef  = tap.trackingRef;
	NSDate* previousDate   = tap.fetchedAt;

	// The subscriptions the catalogue is about to speak for, as they are now:
	// everything below is provisional until the state write lands.
	NSArray* previousSubscriptions = [self catalogueSnapshotForTap:tap];

	tap.catalogueSHA = sha;
	tap.trackingRef  = tap.trackingRef ?: resolvedRef;
	tap.name         = catalogue.name ?: tap.name;
	tap.fetchedAt    = [NSDate date];
	_catalogues[tap.identifier] = catalogue;

	[self applyCatalogue:catalogue forTap:tap];

	NSError* saveError;
	if(![self saveRegistry:&saveError])
	{
		// The pointer never advanced on disk, so leave memory agreeing with it
		// rather than claiming a revision no launch would find. That has to
		// include the subscriptions: a catalogueRef the file does not hold
		// would otherwise be what the next poll installs.
		tap.catalogueSHA = previousSHA;
		tap.name         = previousName;
		tap.trackingRef  = previousRef;
		tap.fetchedAt    = previousDate;
		[self restoreCatalogueSnapshot:previousSubscriptions];

		NSDictionary* previousPlist = previousSHA ? [NSDictionary dictionaryWithContentsOfFile:[self cachePathForTapIdentifier:tap.identifier catalogueSHA:previousSHA]] : nil;
		BundleTapCatalogue* previousCatalogue = previousPlist ? [BundleTapCatalogue catalogueWithPlist:previousPlist tapIdentifier:tap.identifier error:nil] : nil;
		if(previousCatalogue)
				_catalogues[tap.identifier] = previousCatalogue;
		else	[_catalogues removeObjectForKey:tap.identifier];

		return saveError;
	}

	[self removeUnreferencedCacheFilesForTap:tap];
	return nil;
}

// Cache files are immutable and named for the revision they came from, so an
// existing one is by definition the same content — unless it does not parse, in
// which case it is damage rather than content, and this is the one chance to
// repair it: the registry goes on pointing at that name, so a launch that could
// not read the file would fail to read it again on every launch after.
- (NSError*)writeCatalogueData:(NSData*)data forTapIdentifier:(NSString*)identifier catalogueSHA:(NSString*)sha
{
	NSString* directory   = [self cacheDirectoryForTapIdentifier:identifier];
	NSString* destination = [self cachePathForTapIdentifier:identifier catalogueSHA:sha];

	NSFileManager* fm = NSFileManager.defaultManager;
	NSError* error;
	if(![fm createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:&error])
		return error;

	BOOL destinationExists = [fm fileExistsAtPath:destination];
	if(destinationExists)
	{
		NSDictionary* plist = [NSDictionary dictionaryWithContentsOfFile:destination];
		if(plist && [BundleTapCatalogue catalogueWithPlist:plist tapIdentifier:identifier error:nil])
			return nil;

		os_log_error(OS_LOG_DEFAULT, "Replacing unreadable catalogue cache: %{public}@", destination);
	}

	NSString* temporaryPath = [directory stringByAppendingPathComponent:[NSString stringWithFormat:@".%@.plist", NSUUID.UUID.UUIDString]];
	if(![data writeToFile:temporaryPath options:NSDataWritingAtomic error:&error])
		return error;

	if(destinationExists)
	{
		if(![fm replaceItemAtURL:[NSURL fileURLWithPath:destination] withItemAtURL:[NSURL fileURLWithPath:temporaryPath] backupItemName:nil options:NSFileManagerItemReplacementUsingNewMetadataOnly resultingItemURL:nil error:&error])
		{
			[fm removeItemAtPath:temporaryPath error:nil];
			return error;
		}
		return nil;
	}

	if(![fm moveItemAtPath:temporaryPath toPath:destination error:&error])
	{
		[fm removeItemAtPath:temporaryPath error:nil];
		// Losing the race to another writer means the file is already there
		return [fm fileExistsAtPath:destination] ? nil : error;
	}

	return nil;
}

// Run only after the state write, so an interrupted refresh leaves an
// unreferenced orphan rather than deleting the file the registry points at.
- (void)removeUnreferencedCacheFilesForTap:(BundleTap*)tap
{
	NSString* directory = [self cacheDirectoryForTapIdentifier:tap.identifier];
	NSString* keep      = [tap.catalogueSHA stringByAppendingPathExtension:@"plist"];

	for(NSString* name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:directory error:nil])
	{
		if(![name isEqualToString:keep])
			[NSFileManager.defaultManager removeItemAtPath:[directory stringByAppendingPathComponent:name] error:nil];
	}
}

- (void)applyCataloguesToSubscriptions
{
	for(BundleTap* tap in _registry.taps)
	{
		if(BundleTapCatalogue* catalogue = _catalogues[tap.identifier])
			[self applyCatalogue:catalogue forTap:tap];
	}
}

// Exactly the fields applyCatalogue:forTap: below writes, captured before it
// writes them. NSNull stands in for nil so that restoring is a plain assignment
// either way.
- (NSArray<NSDictionary*>*)catalogueSnapshotForTap:(BundleTap*)tap
{
	NSMutableArray* res = [NSMutableArray array];
	for(BundleSubscription* subscription in [_registry subscriptionsForTapWithIdentifier:tap.identifier])
	{
		[res addObject:@{
			@"subscription":  subscription,
			@"catalogueRef":  subscription.catalogueRef  ?: NSNull.null,
			@"category":      subscription.category      ?: NSNull.null,
			@"summary":       subscription.summary       ?: NSNull.null,
			@"originTapName": subscription.originTapName ?: NSNull.null,
			@"sourceChanged": @(subscription.isSourceChanged),
			@"orphaned":      @(subscription.isOrphaned),
		}];
	}
	return res;
}

- (void)restoreCatalogueSnapshot:(NSArray<NSDictionary*>*)snapshot
{
	for(NSDictionary* entry in snapshot)
	{
		BundleSubscription* subscription = entry[@"subscription"];
		subscription.catalogueRef  = entry[@"catalogueRef"]  == NSNull.null ? nil : entry[@"catalogueRef"];
		subscription.category      = entry[@"category"]      == NSNull.null ? nil : entry[@"category"];
		subscription.summary       = entry[@"summary"]       == NSNull.null ? nil : entry[@"summary"];
		subscription.originTapName = entry[@"originTapName"] == NSNull.null ? nil : entry[@"originTapName"];
		subscription.sourceChanged = [entry[@"sourceChanged"] boolValue];
		subscription.orphaned      = [entry[@"orphaned"] boolValue];
	}
}

// What a refreshed catalogue is allowed to change about an installed
// subscription: its metadata and — when the repository is still the same one —
// the ref it publishes. Never the repository itself.
- (void)applyCatalogue:(BundleTapCatalogue*)catalogue forTap:(BundleTap*)tap
{
	for(BundleSubscription* subscription in [_registry subscriptionsForTapWithIdentifier:tap.identifier])
	{
		BundleCandidate* candidate = [catalogue candidateWithIdentifier:subscription.identifier];
		if(!candidate)
		{
			// Removing software the user is using is not a catalogue author’s
			// decision to make: it keeps working and keeps its effective ref.
			subscription.orphaned = YES;
			continue;
		}

		subscription.orphaned = NO;

		if(![candidate.url isEqualToString:subscription.url])
		{
			subscription.sourceChanged = YES;
			continue;
		}

		subscription.sourceChanged = NO;
		subscription.catalogueRef  = candidate.ref;
		subscription.category      = candidate.category ?: subscription.category;
		subscription.summary       = candidate.summary ?: subscription.summary;
		subscription.originTapName = tap.name ?: subscription.originTapName;
	}
}

- (void)removeTap:(BundleTap*)tap
{
	[self removeTap:tap completionHandler:nil];
}

- (void)removeTap:(BundleTap*)tap completionHandler:(void(^)(NSError*))handler
{
	[self enqueueOperation:^(dispatch_block_t done){
		void(^finish)(NSError*) = ^(NSError* error){
			if(handler)
				handler(error);
			done();
		};

		if(NSError* error = self.readOnlyRegistryError)
			return finish(error);

		// Installed bundles are detached rather than removed: each becomes a
		// one-off subscription on the ref it was following. For a curator pin
		// that freezes the last published revision, which the user can change.
		NSArray<BundleSubscription*>* detached = [_registry subscriptionsForTapWithIdentifier:tap.identifier];
		NSMutableArray<NSDictionary*>* previous = [NSMutableArray array];

		for(BundleSubscription* subscription in detached)
		{
			[previous addObject:@{
				@"subscription":  subscription,
				@"trackingRef":   subscription.trackingRef ?: NSNull.null,
				@"refMode":       @(subscription.refMode),
				@"originTapName": subscription.originTapName ?: NSNull.null,
				@"tapIdentifier": subscription.tapIdentifier ?: NSNull.null,
				@"orphaned":      @(subscription.isOrphaned),
				@"sourceChanged": @(subscription.isSourceChanged),
			}];

			subscription.trackingRef   = subscription.effectiveRef;
			subscription.refMode       = BundleSubscriptionRefModeUser;
			subscription.originTapName = tap.name ?: subscription.originTapName;
			subscription.tapIdentifier = nil;
			subscription.orphaned      = NO;
			subscription.sourceChanged = NO;
		}

		BundleTapCatalogue* catalogue = _catalogues[tap.identifier];
		[_registry removeTap:tap];
		[_catalogues removeObjectForKey:tap.identifier];

		NSError* error;
		if(![self saveRegistry:&error])
		{
			// The tap is still on file, so it is still registered here, and
			// every bundle it published still belongs to it.
			[_registry addTap:tap];
			if(catalogue)
				_catalogues[tap.identifier] = catalogue;

			for(NSDictionary* entry in previous)
			{
				BundleSubscription* subscription = entry[@"subscription"];
				subscription.trackingRef   = entry[@"trackingRef"]   == NSNull.null ? nil : entry[@"trackingRef"];
				subscription.refMode       = (BundleSubscriptionRefMode)[entry[@"refMode"] integerValue];
				subscription.originTapName = entry[@"originTapName"] == NSNull.null ? nil : entry[@"originTapName"];
				subscription.tapIdentifier = entry[@"tapIdentifier"] == NSNull.null ? nil : entry[@"tapIdentifier"];
				subscription.orphaned      = [entry[@"orphaned"] boolValue];
				subscription.sourceChanged = [entry[@"sourceChanged"] boolValue];
			}

			[self registryDidChange];
			return finish(error);
		}

		// Only now: until the write landed, this was the cache of a registered tap
		[NSFileManager.defaultManager removeItemAtPath:[self cacheDirectoryForTapIdentifier:tap.identifier] error:nil];

		[self registryDidChange];
		finish(nil);
	}];
}

// ======================
// = Owner enumeration  =
// ======================

// The one REST-dependent feature, and the reason nothing on a timer may touch
// api.github.com: unauthenticated callers get 60 requests an hour. This runs
// only when the user asks for it, follows pagination to the end, and stops with
// what it has — saying so — when the quota runs out.
- (void)enumerateRepositoriesForOwner:(NSString*)owner completionHandler:(void(^)(NSArray<NSString*>*, NSString*, NSError*))handler
{
	std::string url = github::owner_repositories_url(to_s(owner), false);
	if(url.empty())
		return handler(nil, nil, SubscriptionError(BundleSubscriptionErrorCodeInvalidURL, @"Not a GitHub owner: %@", owner));

	[self enumerateRepositoriesAtURL:url owner:owner triedOrganization:NO found:[NSMutableArray array] seen:[NSMutableSet set] completionHandler:handler];
}

- (void)enumerateRepositoriesAtURL:(std::string const&)urlString owner:(NSString*)owner triedOrganization:(BOOL)triedOrganization found:(NSMutableArray<NSString*>*)found seen:(NSMutableSet<NSString*>*)seen completionHandler:(void(^)(NSArray<NSString*>*, NSString*, NSError*))handler
{
	std::string url = urlString;
	FetchResponseAtURL(url, ^(NSData* data, NSHTTPURLResponse* response, NSError* error){
		if(error)
			return handler(found.count ? found : nil, nil, found.count ? nil : error);

		// A user account and an organisation are different endpoints, and which
		// one an owner is cannot be told from its name.
		if(response.statusCode == 404 && !triedOrganization)
		{
			std::string organizationURL = github::owner_repositories_url(to_s(owner), true);
			return [self enumerateRepositoriesAtURL:organizationURL owner:owner triedOrganization:YES found:found seen:seen completionHandler:handler];
		}

		if(response.statusCode == 403 || response.statusCode == 429)
		{
			NSString* message = [NSString stringWithFormat:@"GitHub’s rate limit for unauthenticated requests was reached; showing the %lu repositories retrieved so far.", found.count];
			return handler(found, found.count ? message : nil, found.count ? nil : SubscriptionError(BundleSubscriptionErrorCodeUnavailable, @"%@", message));
		}

		if(response.statusCode != 200)
			return handler(found.count ? found : nil, nil, SubscriptionError(BundleSubscriptionErrorCodeUnavailable, @"GitHub returned %ld for %@.", (long)response.statusCode, owner));

		id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
		if(![json isKindOfClass:[NSArray class]])
			return handler(found.count ? found : nil, nil, SubscriptionError(BundleSubscriptionErrorCodeMalformedResponse, @"Unreadable reply from GitHub for %@.", owner));

		for(id repository in json)
		{
			if(![repository isKindOfClass:[NSDictionary class]])
				continue;

			github::repository_t parsed = github::parse_url(to_s(repository[@"html_url"]));
			if(!parsed)
				continue;

			NSString* canonicalURL = to_ns(parsed.canonical_url());
			if(![seen containsObject:canonicalURL])
			{
				[seen addObject:canonicalURL];
				[found addObject:canonicalURL];
			}
		}

		std::string nextURL = github::next_page_url(to_s(response.allHeaderFields[@"Link"]));
		if(!nextURL.empty())
			return [self enumerateRepositoriesAtURL:nextURL owner:owner triedOrganization:triedOrganization found:found seen:seen completionHandler:handler];

		handler(found, nil, nil);
	});
}

// =========================
// = Installing candidates =
// =========================

- (BundleSubscription*)subscriptionFromCandidate:(BundleCandidate*)candidate
{
	// The tap can have been removed while this install waited its turn on the
	// queue, and a record naming a tap that is not registered is a provenance
	// claim the registry cannot back. It becomes what removeTap: would have
	// made of it: a one-off on the ref the catalogue published.
	BundleTap* tap = [self tapForCandidate:candidate];

	BundleSubscription* subscription = [[BundleSubscription alloc] initWithIdentifier:candidate.identifier url:candidate.url];
	subscription.name          = candidate.name;
	subscription.refMode       = tap ? BundleSubscriptionRefModeCatalogue : BundleSubscriptionRefModeUser;
	subscription.catalogueRef  = candidate.ref;
	subscription.trackingRef   = tap ? nil : candidate.ref;
	subscription.tapIdentifier = tap ? candidate.tapIdentifier : nil;
	subscription.originTapName = tap.name;
	subscription.category      = candidate.category ?: @"Subscribed";
	subscription.summary       = candidate.summary;
	return subscription;
}

- (void)installCandidate:(BundleCandidate*)candidate completionHandler:(void(^)(BundleSubscription*, NSError*))handler
{
	[self enqueueOperation:^(dispatch_block_t done){
		void(^finish)(BundleSubscription*, NSError*) = ^(BundleSubscription* subscription, NSError* error){
			if(handler)
				handler(subscription, error);
			done();
		};

		if(NSError* error = self.readOnlyRegistryError)
			return finish(nil, error);

		if([_registry subscriptionWithIdentifier:candidate.identifier])
			return finish(nil, SubscriptionError(BundleSubscriptionErrorCodeCollision, @"‘%@’ is already installed from a subscription.", candidate.name));

		NSString* existingName;
		BundleCollisionKind collision = [self collisionKindForBundleIdentifier:candidate.identifier existingName:&existingName];
		if(collision != BundleCollisionKindNone)
			return finish(nil, [self errorForCollisionKind:collision name:existingName ?: candidate.name]);

		BundleSubscription* subscription = [self subscriptionFromCandidate:candidate];
		[self resolveRepositoryURL:subscription.url ref:subscription.effectiveRef completionHandler:^(NSString* sha, NSString* resolvedRef, NSError* error){
			if(!sha)
				return finish(nil, error);

			// The expected UUID comes from the catalogue, so a repository
			// repointed at unrelated content is caught before it is installed.
			[self stageRepositoryURL:subscription.url sha:sha expectedIdentifier:candidate.identifier completionHandler:^(NSString* transactionDirectory, NSArray<NSString*>* stagedBundlePaths, NSError* error){
				if(!stagedBundlePaths)
					return finish(nil, error);

				NSError* commitError;
				BOOL didCommit = [self commitStagedBundleAtPath:stagedBundlePaths.firstObject forSubscription:subscription sha:sha error:&commitError];
				[self removeTransactionDirectory:transactionDirectory];

				if(!didCommit)
					return finish(nil, commitError ?: SubscriptionError(BundleSubscriptionErrorCodeFileSystem, @"Failed to install ‘%@’.", candidate.name));

				[self registryDidChange];
				finish(subscription, nil);
			}];
		}];
	}];
}

// ============================
// = Replacing a signed copy  =
// ============================

- (void)replaceSignedBundleWithCandidate:(BundleCandidate*)candidate completionHandler:(void(^)(BundleSubscription*, NSError*))handler
{
	[self enqueueOperation:^(dispatch_block_t done){
		void(^finish)(BundleSubscription*, NSError*) = ^(BundleSubscription* subscription, NSError* error){
			if(handler)
				handler(subscription, error);
			done();
		};

		if(NSError* error = self.readOnlyRegistryError)
			return finish(nil, error);

		NSString* existingName;
		BundleCollisionKind collision = [self collisionKindForBundleIdentifier:candidate.identifier existingName:&existingName];
		if(collision != BundleCollisionKindSigned)
			return finish(nil, [self errorForCollisionKind:collision name:existingName ?: candidate.name] ?: SubscriptionError(BundleSubscriptionErrorCodeCollision, @"‘%@’ does not replace an official bundle.", candidate.name));

		Bundle* signedBundle = [BundlesManager.sharedInstance bundleWithIdentifier:candidate.identifier];
		NSString* managedPath = signedBundle.path;
		if(!managedPath || ![NSFileManager.defaultManager fileExistsAtPath:managedPath])
			return finish(nil, SubscriptionError(BundleSubscriptionErrorCodeFileSystem, @"The official ‘%@’ bundle is not where the local index says it is.", candidate.name));

		BundleSubscription* subscription = [self subscriptionFromCandidate:candidate];
		subscription.replacesSigned = YES;

		NSString* transactionDirectory = [self.transactionsDirectory stringByAppendingPathComponent:NSUUID.UUID.UUIDString];

		[self resolveRepositoryURL:subscription.url ref:subscription.effectiveRef completionHandler:^(NSString* sha, NSString* resolvedRef, NSError* error){
			if(!sha)
				return finish(nil, error);

			// (1) Obtain and validate the replacement first. The official bundle
			// is still the active one throughout.
			[self stageRepositoryURL:subscription.url sha:sha expectedIdentifier:candidate.identifier inTransactionDirectory:transactionDirectory completionHandler:^(NSString* transactionDirectory, NSArray<NSString*>* stagedBundlePaths, NSError* error){
				if(!stagedBundlePaths)
					return finish(nil, error);

				BOOL keepTransactionDirectory = NO;
				NSError* replaceError;
				if(![self performReplaceOfBundle:signedBundle withStagedBundleAtPath:stagedBundlePaths.firstObject subscription:subscription sha:sha transactionDirectory:transactionDirectory keepTransactionDirectory:&keepTransactionDirectory error:&replaceError])
				{
					// Unless the backup in it is the only official copy left
					if(!keepTransactionDirectory)
						[self removeTransactionDirectory:transactionDirectory];
					return finish(nil, replaceError);
				}

				[self registryDidChange];
				finish(subscription, nil);
			}];
		}];
	}];
}

// Steps 2 to 5 of §9.2, all synchronous: no run loop turn happens between the
// two copies changing places, so no watcher-driven index rebuild can observe
// the pair mid-swap. The explicit reload at the end happens once the state
// files agree with the disk.
- (BOOL)performReplaceOfBundle:(Bundle*)signedBundle withStagedBundleAtPath:(NSString*)stagedBundlePath subscription:(BundleSubscription*)subscription sha:(NSString*)sha transactionDirectory:(NSString*)transactionDirectory keepTransactionDirectory:(BOOL*)outKeepTransactionDirectory error:(NSError**)outError
{
	NSFileManager* fm = NSFileManager.defaultManager;

	NSString* managedPath    = signedBundle.path;
	NSString* backupPath     = [transactionDirectory stringByAppendingPathComponent:@"Backup.tmbundle"];
	NSString* relativePath   = SubscribedDirectoryName(subscription.name, subscription.identifier);
	NSString* subscribedPath = [_bundlesDirectory stringByAppendingPathComponent:relativePath];

	subscription.relativePath = relativePath;
	subscription.installedSHA = sha;
	subscription.availableSHA = sha;
	subscription.installedAt  = [NSDate date];
	// Read while the copy is still staged — this path does not go through
	// commitStagedBundleAtPath:, and a replacement is no less entitled to the
	// date its archive came with than an ordinary install.
	subscription.updatedAt    = SourceDateAtPath(stagedBundlePath) ?: subscription.updatedAt;

	// (2) The journal names every path involved, so a launch that finds it can
	// tell which side of the swap the process died on.
	NSDictionary* journal = @{
		kJournalKindKey:   kJournalKindReplace,
		@"uuid":           subscription.identifier.UUIDString,
		@"managedPath":    managedPath,
		@"backupPath":     backupPath,
		@"subscribedPath": subscribedPath,
		@"subscription":   subscription.plistRepresentation,
	};

	NSError* error;
	if(![fm createDirectoryAtPath:_bundlesDirectory withIntermediateDirectories:YES attributes:nil error:&error])
		return (outError && (*outError = error)), NO;

	if((error = [self writeJournal:journal inDirectory:transactionDirectory]))
		return (outError && (*outError = error)), NO;

	// (3) In place, but still shadowed by Managed — the official copy is active
	if([fm fileExistsAtPath:subscribedPath] && ![fm removeItemAtPath:subscribedPath error:&error])
		return (outError && (*outError = error)), NO;
	if(![fm moveItemAtPath:stagedBundlePath toPath:subscribedPath error:&error])
		return (outError && (*outError = error)), NO;

	// (4) The subscription becomes the winner here. There has at no point been
	// a moment with no copy of this bundle installed.
	if(![fm moveItemAtPath:managedPath toPath:backupPath error:&error])
	{
		[fm removeItemAtPath:subscribedPath error:nil];
		return (outError && (*outError = error)), NO;
	}

	// (5) Both state files, then the index, then the backup
	[_registry addSubscription:subscription];

	NSError* saveError;
	if(![self saveRegistry:&saveError])
	{
		if(![self rollbackReplaceOfSubscription:subscription managedPath:managedPath backupPath:backupPath subscribedPath:subscribedPath] && outKeepTransactionDirectory)
			*outKeepTransactionDirectory = YES;
		return (outError && (*outError = saveError)), NO;
	}

	[BundlesManager.sharedInstance markBundleUninstalled:signedBundle];
	[BundlesManager.sharedInstance reloadPath:subscribedPath recursive:YES];
	[BundlesManager.sharedInstance createBundlesIndex:BundlesManager.sharedInstance];

	[fm removeItemAtPath:transactionDirectory error:nil];
	return YES;
}

// Returns whether the official bundle is back. When it is not — the backup is
// still the only copy and could not be moved — the caller keeps the transaction
// directory so that launch recovery can finish what this could not.
- (BOOL)rollbackReplaceOfSubscription:(BundleSubscription*)subscription managedPath:(NSString*)managedPath backupPath:(NSString*)backupPath subscribedPath:(NSString*)subscribedPath
{
	NSFileManager* fm = NSFileManager.defaultManager;

	// The backup first, and the replacement only once it is home: in between,
	// removing the replacement would leave the bundle with no copy at all.
	BOOL officialIsBack = [fm fileExistsAtPath:managedPath];
	if(!officialIsBack && [fm fileExistsAtPath:backupPath])
	{
		NSError* error;
		if(![fm moveItemAtPath:backupPath toPath:managedPath error:&error])
				os_log_error(OS_LOG_DEFAULT, "Failed to restore %{public}@: %{public}@", managedPath, error.localizedDescription);
		else	officialIsBack = YES;
	}

	if(officialIsBack)
		[fm removeItemAtPath:subscribedPath error:nil];

	[_registry removeSubscription:subscription];

	NSError* error;
	[self saveRegistry:&error];

	return officialIsBack;
}

- (void)restoreSignedBundleForSubscription:(BundleSubscription*)subscription completionHandler:(void(^)(NSError*))handler
{
	[self enqueueOperation:^(dispatch_block_t done){
		void(^finish)(NSError*) = ^(NSError* error){
			if(handler)
				handler(error);
			done();
		};

		if(NSError* error = self.readOnlyRegistryError)
			return finish(error);

		Bundle* signedBundle = [BundlesManager.sharedInstance bundleWithIdentifier:subscription.identifier];
		if(!signedBundle.downloadURL)
			return finish(SubscriptionError(BundleSubscriptionErrorCodeUnavailable, @"The bundle index has no official ‘%@’ bundle to restore.", subscription.name));

		NSString* subscribedPath       = subscription.relativePath ? [_bundlesDirectory stringByAppendingPathComponent:subscription.relativePath] : @"";
		NSString* transactionDirectory = [self.transactionsDirectory stringByAppendingPathComponent:NSUUID.UUID.UUIDString];

		// Journalled before the official copy lands, because from that moment
		// on the two disagree: Managed precedence makes the signed bundle the
		// active one while Subscriptions.plist still says the subscription
		// replaces it. A crash in between is what this file is for.
		NSDictionary* journal = @{
			kJournalKindKey:   kJournalKindRestore,
			@"uuid":           subscription.identifier.UUIDString,
			@"subscribedPath": subscribedPath,
			@"subscription":   subscription.plistRepresentation,
		};

		if(NSError* error = [self writeJournal:journal inDirectory:transactionDirectory])
			return finish(error);

		// Symmetric discipline: the signed archive is downloaded and its
		// signature verified before anything is given up. While both copies
		// exist, Managed precedence already makes the signed one active.
		[BundlesManager.sharedInstance installBundles:@[ signedBundle ] completionHandler:^(NSArray<Bundle*>* installedBundles){
			if(!signedBundle.isInstalled)
			{
				// Nothing was given up, so the journal is all there is to undo
				[self removeTransactionDirectory:transactionDirectory];
				return finish(SubscriptionError(BundleSubscriptionErrorCodeUnavailable, @"Failed to download the official ‘%@’ bundle; the subscription was left in place.", subscription.name));
			}

			NSError* error = [self completeRestoreOfSubscriptionWithIdentifier:subscription.identifier subscribedPath:subscribedPath];
			if(!error)
				[self removeTransactionDirectory:transactionDirectory];

			[BundlesManager.sharedInstance createBundlesIndex:BundlesManager.sharedInstance];
			[self registryDidChange];

			finish(error);
		}];
	}];
}

// Returns what went wrong rather than only logging it: a copy that is still
// there is the difference between an unsubscribe and a bundle the user thinks
// they removed.
- (NSError*)removeInstalledCopyAtPath:(NSString*)path
{
	if(!path.length || ![NSFileManager.defaultManager fileExistsAtPath:path])
		return nil;

	NSError* error;
	if(![NSFileManager.defaultManager removeItemAtPath:path error:&error])
	{
		os_log_error(OS_LOG_DEFAULT, "Failed to remove %{public}@: %{public}@", path, error.localizedDescription);
		return error ?: SubscriptionError(BundleSubscriptionErrorCodeFileSystem, @"Failed to remove %@.", path);
	}

	[BundlesManager.sharedInstance erasePath:path];
	return nil;
}
@end
