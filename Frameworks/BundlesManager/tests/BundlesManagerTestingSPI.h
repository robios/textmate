#import <BundlesManager/BundlesManager.h>

// The install refusal policy — the dependency walk plus the built-in and
// subscription guards — separated from the download precisely so it can be
// exercised here. The subscription test comes in as a block: the real method
// asks the live registry, a test answers from a set of its own making. Declared
// in a header for the same reason as BundleSubscriptionManagerTestingSPI.h —
// the generated runner wraps each test file in a namespace, where an
// Objective-C declaration cannot go.
@interface BundlesManager (Testing)
- (NSMutableSet<Bundle*>*)bundlesToInstallForBundles:(NSArray<Bundle*>*)someBundles displacingSubscriptionsFor:(NSSet<NSUUID*>*)identifiers subscriptionTest:(BOOL(^)(NSUUID*))subscriptionOwnsIdentifier;
@end
