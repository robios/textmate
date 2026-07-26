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

// Holds the queue, so that a test can have two operations waiting on it at once
- (void)enqueueOperation:(void(^)(dispatch_block_t done))operation;

- (BundleSubscription*)subscriptionFromCandidate:(BundleCandidate*)candidate;
@end
