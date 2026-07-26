#import "Bundle.h"
#import <bundles/item.h>

extern NSString* const kUserDefaultsDisableBundleUpdatesKey;
extern NSString* const kUserDefaultsLastBundleUpdateCheckKey;

@interface BundlesManager : NSObject
@property (class, readonly) BundlesManager* sharedInstance;

@property (nonatomic, readonly) NSArray<Bundle*>* bundles;

- (NSProgress*)installBundles:(NSArray<Bundle*>*)someBundles completionHandler:(void(^)(NSArray<Bundle*>*))callback;
- (void)uninstallBundle:(Bundle*)aBundle;
- (void)loadBundlesIndex;
- (void)installBundleItemsAtPaths:(NSArray*)somePaths;
- (BOOL)findBundleForInstall:(bundles::item_ptr*)res;
- (void)reloadPath:(NSString*)aPath;
- (void)reloadPath:(NSString*)aPath recursive:(BOOL)flag;
- (void)erasePath:(NSString*)aPath;
- (void)createBundlesIndex:(id)sender;

- (Bundle*)bundleWithIdentifier:(NSUUID*)anIdentifier;

// Records that a bundle is no longer installed without touching the file
// system: the caller has already performed (or journalled) the move itself.
// uninstallBundle: cannot be used for that — it returns early when the path is
// already gone, leaving LocalIndex.plist claiming a bundle that is not there.
- (void)markBundleUninstalled:(Bundle*)aBundle;

// Checks the signed index and polls subscriptions, in that order but
// independently: this is what the scheduler runs, and what “Refresh now” runs
// when scheduled checks are disabled.
- (void)refreshBundlesWithCompletionHandler:(void(^)(void))completionHandler;
@end
