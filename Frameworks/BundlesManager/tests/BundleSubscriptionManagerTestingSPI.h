#import <BundlesManager/BundleSubscriptionManager.h>

// The catalogue cache is implementation detail of the manager. The tests reach
// it directly rather than widening the framework header for something only a
// test needs; the generated test runner wraps each test file in a namespace,
// where an Objective-C declaration cannot go, so it lives in this header.
@interface BundleSubscriptionManager (Testing)
- (NSString*)cacheDirectoryForTapIdentifier:(NSString*)identifier;
- (NSString*)cachePathForTapIdentifier:(NSString*)identifier catalogueSHA:(NSString*)sha;
- (NSError*)writeCatalogueData:(NSData*)data forTapIdentifier:(NSString*)identifier catalogueSHA:(NSString*)sha;
- (void)removeUnreferencedCacheFilesForTap:(BundleTap*)tap;

// The commit points and the transactions around them, which is where the
// failure paths worth testing are — they are reached from the outside only
// through the network.
- (BOOL)commitStagedBundleAtPath:(NSString*)stagedBundlePath forSubscription:(BundleSubscription*)subscription sha:(NSString*)sha error:(NSError**)error;
- (NSError*)completeRestoreOfSubscriptionWithIdentifier:(NSUUID*)identifier subscribedPath:(NSString*)subscribedPath;
- (NSArray<NSDictionary*>*)catalogueSnapshotForTap:(BundleTap*)tap;
- (void)restoreCatalogueSnapshot:(NSArray<NSDictionary*>*)snapshot;
- (void)applyCatalogue:(BundleTapCatalogue*)catalogue forTap:(BundleTap*)tap;

// The halves of a tap refresh and of an add that follow the fetch, which is
// where the state write and its rollback are
- (NSError*)commitCatalogue:(BundleTapCatalogue*)catalogue data:(NSData*)data sha:(NSString*)sha resolvedRef:(NSString*)resolvedRef forTap:(BundleTap*)tap;
- (NSError*)commitNewTap:(BundleTap*)tap catalogue:(BundleTapCatalogue*)catalogue data:(NSData*)data sha:(NSString*)sha resolvedRef:(NSString*)resolvedRef;
- (NSArray<BundleSubscription*>*)installStagedBundlesAtPaths:(NSArray<NSString*>*)stagedBundlePaths fromRepositoryURL:(NSString*)canonicalURL name:(NSString*)repositoryName sha:(NSString*)sha ref:(NSString*)resolvedRef error:(NSError**)outError;

// The decision the poll site makes, which is otherwise reachable only with a
// network behind it: the effective policy and the source-change interlock
- (BOOL)shouldApplyUpdateForSubscription:(BundleSubscription*)subscription;

// One subscription's share of a poll. Everything it does past this point needs
// a network, which is why the subclass below stands in for it.
- (void)updateSubscription:(BundleSubscription*)subscription applyUpdate:(BOOL)applyUpdate completionHandler:(void(^)(NSError* error))handler;

// The poll itself, without the catalogue refresh the public entry point runs
// first — and without its enqueueing, so a test can drive it directly.
- (void)pollSubscriptions:(NSArray<BundleSubscription*>*)subscriptions atIndex:(NSUInteger)index applyUpdates:(BOOL)applyUpdates completionHandler:(dispatch_block_t)handler;

// Holds the queue, so that a test can have two operations waiting on it at once
- (void)enqueueOperation:(void(^)(dispatch_block_t done))operation;

- (BundleSubscription*)subscriptionFromCandidate:(BundleCandidate*)candidate;
@end

// A manager that writes down what a poll decided instead of acting on it. Which
// subscriptions a poll visits, and whether each was allowed to install, is
// otherwise observable only through the effects of a network request — so a
// caller that polled with updates *disabled* would look exactly like this one.
// Lives here for the same reason the category above does: the generated runner
// wraps each test file in a namespace, where this cannot go.
@interface RecordingBundleSubscriptionManager : BundleSubscriptionManager
@property (nonatomic, readonly) NSMutableArray<NSString*>* polled; // “<name> apply=YES|NO”, in order
@end

@implementation RecordingBundleSubscriptionManager
- (instancetype)initWithInstallDirectory:(NSString*)installDirectory registryFileURL:(NSURL*)registryFileURL
{
	if(self = [super initWithInstallDirectory:installDirectory registryFileURL:registryFileURL])
		_polled = [NSMutableArray array];
	return self;
}

- (void)updateSubscription:(BundleSubscription*)subscription applyUpdate:(BOOL)applyUpdate completionHandler:(void(^)(NSError*))handler
{
	[_polled addObject:[NSString stringWithFormat:@"%@ apply=%@", subscription.name, applyUpdate ? @"YES" : @"NO"]];
	handler(nil);
}
@end
