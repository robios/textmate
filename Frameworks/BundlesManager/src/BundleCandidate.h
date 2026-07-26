#import <Foundation/Foundation.h>

@class BundleGrammar;

// A bundle a tap offers, which is not the same kind of thing as a bundle that
// is installed. An installed bundle has UUID identity — only one source for a
// UUID can be active — while a candidate is identified by (tap, UUID), so two
// taps may list two forks of the same bundle without either disappearing.
// Candidates must never be put into UUID-keyed collections of Bundle.
@interface BundleCandidate : NSObject
- (instancetype)initWithTapIdentifier:(NSString*)tapIdentifier plistRepresentation:(NSDictionary*)plist;

@property (nonatomic, readonly) NSString* tapIdentifier;
@property (nonatomic, readonly) NSUUID*   identifier;
@property (nonatomic, readonly) NSString* name;
@property (nonatomic, readonly) NSString* url;       // Canonical https://github.com/<owner>/<name>
@property (nonatomic, readonly) NSString* ref;       // Branch, tag, or — as a curator pin — a revision
@property (nonatomic, readonly) NSString* category;
@property (nonatomic, readonly) NSString* summary;
@property (nonatomic, readonly) NSArray<NSDictionary*>* grammars;

// The same shape the signed index publishes, so a tap that lists its grammars
// takes part in “install a bundle for this file type?” without a second
// suggestion mechanism. A tap that lists none simply does not appear there.
@property (nonatomic, readonly) NSArray<BundleGrammar*>* bundleGrammars;
@end

// A tap’s ‘Taps/bundles.plist’, validated. Malformed entries are dropped
// individually: invalidating the whole catalogue would punish every other
// bundle in it for one bad record.
@interface BundleTapCatalogue : NSObject
+ (instancetype)catalogueWithPlist:(NSDictionary*)plist tapIdentifier:(NSString*)tapIdentifier error:(NSError**)error;

@property (nonatomic, readonly) NSString* name;
@property (nonatomic, readonly) NSArray<BundleCandidate*>* candidates;

- (BundleCandidate*)candidateWithIdentifier:(NSUUID*)identifier;
@end
