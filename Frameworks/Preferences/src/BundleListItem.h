#import <BundlesManager/BundlesManager.h>
#import <BundlesManager/BundleSubscriptionManager.h>

typedef NS_ENUM(NSInteger, BundleListItemKind)
{
	BundleListItemKindSigned,       // From the signed api.textmate.org index, or found on disk
	BundleListItemKindSubscription, // Installed from a GitHub repository the user subscribed to
	BundleListItemKindCandidate,    // Offered by a tap, not installed from it
};

// One row of Preferences → Bundles. Signed and subscribed bundles share a
// single list, so the difference between “verified by TextMate’s signing key”
// and “fetched from a GitHub repository you added” cannot be left to ordering:
// every row says which it is.
@interface BundleListItem : NSObject
+ (NSArray<BundleListItem*>*)currentItems;

@property (nonatomic, readonly) BundleListItemKind    kind;
@property (nonatomic, readonly) Bundle*               bundle;
@property (nonatomic, readonly) BundleSubscription*   subscription;
@property (nonatomic, readonly) BundleCandidate*      candidate;

// Bound by the table
@property (nonatomic, readonly) NSString* name;
@property (nonatomic, readonly) NSString* category;
@property (nonatomic, readonly) NSString* textSummary;
@property (nonatomic, readonly) NSURL*    htmlURL;
@property (nonatomic, readonly) NSDate*   downloadLastUpdated; // Sorted on
@property (nonatomic, readonly) NSString* updatedText;         // Displayed; an em dash when there is no date
@property (nonatomic, readonly) BOOL      hasUpdatedDate;
@property (nonatomic, readonly) NSString* source;   // Provenance badge, plus the state that belongs next to it
@property (nonatomic, readonly, getter = isInstalled) BOOL installed;
@property (nonatomic, readonly) BOOL canChangeInstalledState;

@property (nonatomic, readonly) NSString* detailText; // Shown as the row's tooltip

// The bundle path whose copy is loaded in place of this subscription, nil when
// the subscription is in effect. Asked of the runtime index rather than derived
// from the location order: the loader already decided which copy of the UUID
// won, and that answer stays right if the order ever changes. Only subscription
// rows can have one — a signed row whose UUID a subscription owns is not shown.
@property (nonatomic, readonly) NSString* eclipsedByPath;

// Whether the row has a newer version to move to. Both kinds can: a signed
// bundle when the index publishes one, a subscription when its ref resolves
// past what is installed.
@property (nonatomic, readonly) BOOL hasUpdate;
@property (nonatomic, readonly) BOOL canUpdateAutomatically; // Per-bundle, which only a subscription has

// Only a candidate that collides with a non-mandatory signed bundle can be
// installed by giving something up, and it says so before it does.
@property (nonatomic, readonly) BOOL requiresReplacingSignedBundle;
@end
