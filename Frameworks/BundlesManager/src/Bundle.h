@class BundleGrammar;
@class BundleCandidate;

@interface Bundle : NSObject
- (instancetype)initWithIdentifier:(NSUUID*)anIdentifier;

@property (nonatomic) NSUUID*                       identifier;
@property (nonatomic) NSString*                     name;
@property (nonatomic) NSString*                     minimumAppVersion; // E.g. ‘2.0-alpha.9519’
@property (nonatomic) NSString*                     category;
@property (nonatomic) NSURL*                        htmlURL;
@property (nonatomic) NSString*                     summary;
@property (nonatomic) NSString*                     contactName;
@property (nonatomic) NSString*                     contactEmail;
@property (nonatomic) NSURL*                        downloadURL;
@property (nonatomic) NSDate*                       downloadLastUpdated;
@property (nonatomic) NSInteger                     downloadSize;
@property (nonatomic, getter = isMandatory)   BOOL  mandatory;
@property (nonatomic, getter = isRecommended) BOOL  recommended;
@property (nonatomic) NSArray<BundleGrammar*>*      grammars;
@property (nonatomic) NSArray<Bundle*>*             dependencies;

// Shipped inside the application, in Contents/SharedSupport/Bundles. Such a
// bundle outranks anything an index or a subscription distributes for the same
// UUID (see bundles::locations), so it is always the copy in use and the app is
// its only updater: nothing here can install, update or remove it. It is
// deliberately not a value read back from the local index — the identity comes
// from what is inside the app right now.
@property (nonatomic, getter = isBuiltIn) BOOL builtIn;

// From local index. ‘installed’ is also YES for a built-in bundle regardless of
// what the index says, while ‘path’ keeps describing the Managed copy — the
// in-app path is never written there, so it cannot end up in the local index.
@property (nonatomic, getter = isInstalled)  BOOL      installed;
@property (nonatomic)                        NSString* path;
@property (nonatomic)                        NSDate*   lastUpdated;
@property (nonatomic, getter = isDependency) BOOL      dependency; // Another bundle depends on us

// Generated
@property (nonatomic, readonly)                        NSString* textSummary; // ‘summary’ with its markup and entities resolved
@property (nonatomic, readonly)                        BOOL hasUpdate;
@property (nonatomic, getter = isCompatible, readonly) BOOL compatible; // Works with current version of TextMate
@end

@interface BundleGrammar : NSObject
@property (nonatomic, weak) Bundle*          bundle;
// Set instead of ‘bundle’ for a grammar a tap offers. Weak like ‘bundle’, and
// for the same reason — the candidate owns the grammar — so whoever holds a
// grammar past the moment it was asked for has to hold its source too: a
// catalogue refresh replaces every candidate object it published.
@property (nonatomic, weak) BundleCandidate* candidate;
@property (nonatomic) NSUUID*             identifier;
@property (nonatomic) NSString*           name;
@property (nonatomic) NSString*           fileType;       // E.g. ‘source.ruby’
@property (nonatomic) NSArray<NSString*>* filePatterns;   // Array of extensions or file globs
@property (nonatomic) NSString*           firstLineMatch; // E.g. ‘^#!/.*\bruby’

// Whatever offers this grammar, which is what callers de-duplicate on: two
// grammars from one source should not produce two suggestions.
@property (nonatomic, readonly) id   source;
@property (nonatomic, readonly) NSString* sourceName;
@property (nonatomic, readonly, getter = isInstalled) BOOL installed;
@end
