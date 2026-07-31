#import "BundleSubscription.h"
#import "BundleCandidate.h"

extern NSString* const BundleSubscriptionsDidChangeNotification;
extern NSString* const BundleSubscriptionErrorDomain;

typedef NS_ENUM(NSInteger, BundleSubscriptionErrorCode)
{
	BundleSubscriptionErrorCodeInvalidURL = 1,
	BundleSubscriptionErrorCodeUnavailable,        // Gone, private, offline, or the ref is not advertised
	BundleSubscriptionErrorCodeMalformedResponse,
	BundleSubscriptionErrorCodeNotABundle,
	BundleSubscriptionErrorCodeNotATap,            // No Taps/bundles.plist — it may still be a bundle
	BundleSubscriptionErrorCodeIdentityMismatch,   // info.plist UUID is not the one we expected
	BundleSubscriptionErrorCodeCollision,          // Refused: a bundle with this UUID is already active
	BundleSubscriptionErrorCodeReplaceRequired,    // Collides with a signed bundle; §9.2 Replace can proceed
	BundleSubscriptionErrorCodeMandatory,          // Collides with Source, Text, or Bundle Support
	BundleSubscriptionErrorCodeFileSystem,
	BundleSubscriptionErrorCodeReadOnlyRegistry,
};

// What an already-active bundle with the same UUID is, which decides whether a
// subscription may install, must be refused, or can offer the Replace flow.
typedef NS_ENUM(NSInteger, BundleCollisionKind)
{
	BundleCollisionKindNone,
	BundleCollisionKindSigned,
	BundleCollisionKindSignedMandatory,
	BundleCollisionKindSubscription,
	BundleCollisionKindLocal,          // The user’s own bundle, or one in a machine-wide location
};

// Bundles fetched from GitHub repositories the user subscribed to. These live
// in their own install root with their own state file: nothing here touches
// the signed api.textmate.org path, whose index, signatures, and local index
// keep working exactly as before.
@interface BundleSubscriptionManager : NSObject
@property (class, readonly) BundleSubscriptionManager* sharedInstance;

// Designated initialiser. The shared instance uses the application support
// directory; tests use this to work somewhere disposable.
- (instancetype)initWithInstallDirectory:(NSString*)installDirectory registryFileURL:(NSURL*)registryFileURL;

@property (nonatomic, readonly) NSArray<BundleSubscription*>* subscriptions;
@property (nonatomic, readonly) NSArray<BundleTap*>* taps;
@property (nonatomic, readonly) NSArray<BundleCandidate*>* candidates; // Every tap’s catalogue, from cache
@property (nonatomic, readonly) NSString* installDirectory;   // …/TextMate/Subscribed
@property (nonatomic, readonly) NSString* bundlesDirectory;   // …/TextMate/Subscribed/Bundles
@property (nonatomic, readonly, getter = isBusy) BOOL busy;

// Loads the state file and finishes or rolls back anything a crash interrupted.
// Must run before the first bundle index is built.
- (void)loadRegistry;

// A repository is usually one bundle, but a monorepo of several is installed as
// one subscription each — they update together but can be removed apart.
- (void)addSubscriptionForRepositoryURL:(NSString*)urlString ref:(NSString*)ref completionHandler:(void(^)(NSArray<BundleSubscription*>* subscriptions, NSError* error))handler;
- (void)updateSubscription:(BundleSubscription*)subscription completionHandler:(void(^)(NSError* error))handler;
- (void)uninstallSubscription:(BundleSubscription*)subscription completionHandler:(void(^)(NSError* error))handler;

// Refreshes every tap catalogue, then resolves every subscription’s effective
// ref — pinned ones included, so an update can be offered — and installs where
// the effective policy allows it (the bundle’s own flag, or its tap’s trust).
- (void)pollSubscriptionsWithCompletionHandler:(void(^)(void))handler;

// ========
// = Taps =
// ========

// What the user actually types: a repository, which is a tap if it carries a
// catalogue and a bundle otherwise. Asking them to say which it is means asking
// them to know something TextMate can find out for itself.
- (void)addSourceWithURL:(NSString*)urlString ref:(NSString*)ref completionHandler:(void(^)(BundleTap* tap, NSArray<BundleSubscription*>* subscriptions, NSError* error))handler;

// Adding a tap shows its catalogue; it installs nothing.
- (void)addTapWithURL:(NSString*)urlString ref:(NSString*)ref completionHandler:(void(^)(BundleTap* tap, NSError* error))handler;
- (void)refreshTap:(BundleTap*)tap completionHandler:(void(^)(NSError* error))handler;

// Non-destructive to installed bundles: each is detached into a one-off
// subscription that keeps its current effective ref. Both the detaching and the
// removal are undone if the state write fails, so a reported success is one the
// next launch will agree with.
- (void)removeTap:(BundleTap*)tap;
- (void)removeTap:(BundleTap*)tap completionHandler:(void(^)(NSError* error))handler;

// The branch, tag, or revision the tap's own catalogue is read from
- (void)setRef:(NSString*)ref forTap:(BundleTap*)tap completionHandler:(void(^)(NSError* error))handler;

// One sentence — “I trust this source” — instead of the same sentence repeated
// on every bundle the tap publishes. Enabling it applies what is already
// waiting; disabling it only stops the next application, since what has been
// installed cannot be uninstalled by a change of mind about the future.
- (void)setAutoUpdate:(BOOL)flag forTap:(BundleTap*)tap completionHandler:(void(^)(NSError* error))handler;

- (BundleTapCatalogue*)catalogueForTap:(BundleTap*)tap;
- (BundleTap*)tapForCandidate:(BundleCandidate*)candidate;
- (BundleTap*)tapForSubscription:(BundleSubscription*)subscription;
- (BundleSubscription*)subscriptionWithIdentifier:(NSUUID*)identifier;

- (void)installCandidate:(BundleCandidate*)candidate completionHandler:(void(^)(BundleSubscription* subscription, NSError* error))handler;

// §9.2: stages the replacement, journals every destructive boundary, and only
// then retires the signed copy. Signature verification is given up for that one
// bundle, which is why nothing here happens without the user asking for it.
- (void)replaceSignedBundleWithCandidate:(BundleCandidate*)candidate completionHandler:(void(^)(BundleSubscription* subscription, NSError* error))handler;

// Offered when unsubscribing from a bundle that replaced a signed one: the
// signed archive is downloaded and verified before the subscription is removed.
- (void)restoreSignedBundleForSubscription:(BundleSubscription*)subscription completionHandler:(void(^)(NSError* error))handler;

// Settings, and settings are state too: each is applied, saved, and put back if
// the save fails, so nothing is in effect that the next launch would not find.
- (void)setRef:(NSString*)ref forSubscription:(BundleSubscription*)subscription; // Switches to user mode
- (void)setRef:(NSString*)ref forSubscription:(BundleSubscription*)subscription completionHandler:(void(^)(NSError* error))handler;
- (void)followCatalogueForSubscription:(BundleSubscription*)subscription;
- (void)followCatalogueForSubscription:(BundleSubscription*)subscription completionHandler:(void(^)(NSError* error))handler;

// Like its tap counterpart, opting in also applies the update this bundle is
// already sitting on; opting out only stops the next one.
- (void)setAutoUpdate:(BOOL)flag forSubscription:(BundleSubscription*)subscription;
- (void)setAutoUpdate:(BOOL)flag forSubscription:(BundleSubscription*)subscription completionHandler:(void(^)(NSError* error))handler;


// Whether this subscription updates by itself, which two settings can each say
// on their own: its own flag, or the trust its tap was given. A subscription is
// effectively pinned exactly when this is false — the raw per-bundle flag
// answers only whether it opted in independently, and is not a synonym for it.
- (BOOL)effectiveAutoUpdateForSubscription:(BundleSubscription*)subscription;

// Only the tap-derived half, for when the UI has to name who owns the setting.
// A tap vouches for what it publishes and no more: a user-chosen ref, a bundle
// dropped from the catalogue, or a one-off repository is outside that sentence.
- (BOOL)tapTrustCoversSubscription:(BundleSubscription*)subscription;

// Lists an owner’s public repositories. This is the only feature that depends
// on api.github.com, whose unauthenticated quota is 60 requests an hour, so it
// runs on explicit user action and never on a timer. A rate-limited run returns
// what it has along with a message saying the list is incomplete.
- (void)enumerateRepositoriesForOwner:(NSString*)owner completionHandler:(void(^)(NSArray<NSString*>* repositoryURLs, NSString* message, NSError* error))handler;

// github.com/…/compare/<installed>…<available>: what makes pinning worth its
// friction is being able to read an update before accepting it.
- (NSURL*)compareURLForSubscription:(BundleSubscription*)subscription;

- (BundleCollisionKind)collisionKindForBundleIdentifier:(NSUUID*)identifier existingName:(NSString**)outName;
@end
