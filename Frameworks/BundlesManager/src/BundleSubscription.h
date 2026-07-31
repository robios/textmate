#import <Foundation/Foundation.h>

// A subscription follows either the ref its tap publishes or a ref the user
// chose. Keeping the two apart is what lets a catalogue advance its own pin
// without overriding a user’s explicit choice, and vice versa.
typedef NS_ENUM(NSInteger, BundleSubscriptionRefMode)
{
	BundleSubscriptionRefModeCatalogue,
	BundleSubscriptionRefModeUser,
};

// One registered repository whose ‘Taps/bundles.plist’ lists bundles.
@interface BundleTap : NSObject
- (instancetype)initWithIdentifier:(NSString*)identifier url:(NSString*)url trackingRef:(NSString*)trackingRef;
- (instancetype)initWithPlistRepresentation:(NSDictionary*)plist;
- (NSDictionary*)plistRepresentation;

@property (nonatomic, readonly) NSString* identifier;  // Generated, stable for the lifetime of the registration
@property (nonatomic) NSString* url;                   // Canonical https://github.com/<owner>/<name>
@property (nonatomic) NSString* trackingRef;           // Branch, tag, or revision of the tap repository itself
@property (nonatomic) NSString* name;                  // Display name published by the catalogue
@property (nonatomic) NSString* catalogueSHA;          // Revision the cached catalogue was fetched at
@property (nonatomic) NSDate*   fetchedAt;

// “I trust this source”, said once instead of once per bundle: the bundles this
// tap publishes update automatically, without the per-bundle flags below being
// touched. Opt-in, exactly as they are.
@property (nonatomic) BOOL      autoUpdate;
@end

// One bundle the user has actually subscribed to. Catalogue entries the user
// has not installed live in the catalogue cache, not here.
@interface BundleSubscription : NSObject
- (instancetype)initWithIdentifier:(NSUUID*)identifier url:(NSString*)url;
- (instancetype)initWithPlistRepresentation:(NSDictionary*)plist;
- (NSDictionary*)plistRepresentation;

@property (nonatomic, readonly) NSUUID*   identifier;  // Bundle UUID, as in the bundle’s own info.plist
@property (nonatomic) NSString* name;
@property (nonatomic) NSString* url;
@property (nonatomic) BundleSubscriptionRefMode refMode;
@property (nonatomic) NSString* catalogueRef;          // Latest value published by the tap
@property (nonatomic) NSString* trackingRef;           // User-selected branch, tag, or revision
@property (nonatomic) NSString* tapIdentifier;
@property (nonatomic) NSString* originTapName;         // Display-only history, kept when a tap is removed
@property (nonatomic) NSString* category;
@property (nonatomic) NSString* summary;

// Whether this bundle opted in by itself — not the whole answer, and not a
// synonym for “unpinned”: a tap the user trusts speaks for what it publishes.
// What decides whether an update is applied or only offered is
// -[BundleSubscriptionManager effectiveAutoUpdateForSubscription:].
@property (nonatomic) BOOL      autoUpdate;

@property (nonatomic) NSString* installedSHA;          // What is on disk
@property (nonatomic) NSString* availableSHA;          // Latest successfully resolved candidate
@property (nonatomic) NSDate*   installedAt;

// When the *source* last changed: the commit date of installedSHA, taken from
// the archive it came in. Not the same question as installedAt, and the one the
// bundle list asks — a curator’s catalogue date can go stale, this cannot.
@property (nonatomic) NSDate*   updatedAt;
@property (nonatomic) BOOL      replacesSigned;
@property (nonatomic) NSString* relativePath;          // Below Subscribed/Bundles, e.g. ‘Git-A4380B27.tmbundle’

// Not persisted: the state of the last poll, which is deliberately transient —
// a failed resolution must not destroy a known availableSHA.
@property (nonatomic, getter = isUnavailable) BOOL unavailable;
@property (nonatomic) NSString* statusMessage;
@property (nonatomic, getter = isSourceChanged) BOOL sourceChanged; // Catalogue moved to a different repository (§9.2)
@property (nonatomic, getter = isOrphaned) BOOL orphaned;           // Dropped from its tap’s catalogue, but still installed

@property (nonatomic, readonly) NSString* effectiveRef;
@property (nonatomic, readonly) BOOL hasUpdate;
@end

// The state file: ~/Library/Application Support/TextMate/Subscriptions.plist.
// Unknown keys survive a round-trip so that a file written by a later version
// is not quietly stripped by an earlier one.
@interface BundleSubscriptionRegistry : NSObject
- (instancetype)initWithFileURL:(NSURL*)fileURL;

@property (nonatomic, readonly) NSURL* fileURL;
@property (nonatomic, readonly) NSArray<BundleTap*>* taps;
@property (nonatomic, readonly) NSArray<BundleSubscription*>* subscriptions;

// A file written by a newer schema — or one that cannot be read at all — is
// loaded as best we can but never written back: overwriting state we do not
// understand is worse than not saving. The reason is what the user is told.
@property (nonatomic, readonly, getter = isReadOnly) BOOL readOnly;
@property (nonatomic, readonly) NSString* readOnlyReason;

- (BOOL)load:(NSError**)error;
- (BOOL)save:(NSError**)error;

- (BundleTap*)tapWithIdentifier:(NSString*)identifier;
- (BundleSubscription*)subscriptionWithIdentifier:(NSUUID*)identifier;
- (NSArray<BundleSubscription*>*)subscriptionsForTapWithIdentifier:(NSString*)identifier;

- (void)addTap:(BundleTap*)tap;
- (void)removeTap:(BundleTap*)tap;
- (void)addSubscription:(BundleSubscription*)subscription;
- (void)removeSubscription:(BundleSubscription*)subscription;
@end
