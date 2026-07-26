#import "BundleCandidate.h"
#import "Bundle.h"
#import "BundleSubscriptionManager.h"
#import "github_url.h"
#import <ns/ns.h>

static NSInteger const kCatalogueSchemaVersion = 1;

// The format-controlled default. Unlike a repository subscription, where an
// omitted ref means the advertised HEAD, a catalogue entry defaults to ‘main’ —
// a curator can and should write ‘ref: master’ where that is wrong.
static NSString* const kDefaultCatalogueRef = @"main";

static NSString* NonEmptyString (id value)
{
	return [value isKindOfClass:[NSString class]] && [value length] ? value : nil;
}

@implementation BundleCandidate
{
	NSArray<BundleGrammar*>* _bundleGrammars; // Built on demand, on the main thread like everything else here
}

- (instancetype)initWithTapIdentifier:(NSString*)tapIdentifier plistRepresentation:(NSDictionary*)plist
{
	if(![plist isKindOfClass:[NSDictionary class]])
		return nil;

	NSString* uuidString = NonEmptyString(plist[@"uuid"]);
	NSUUID* identifier   = uuidString ? [[NSUUID alloc] initWithUUIDString:uuidString] : nil;
	NSString* name       = NonEmptyString(plist[@"name"]);

	// The URL is canonicalised here so that the two spellings GitHub hands out
	// do not later read as the source change of §9.2.
	github::repository_t repo = github::parse_url(to_s(NonEmptyString(plist[@"url"])));

	if(!identifier || !name || !repo)
		return nil;

	if(self = [super init])
	{
		_tapIdentifier = tapIdentifier;
		_identifier    = identifier;
		_name          = name;
		_url           = to_ns(repo.canonical_url());
		_ref           = NonEmptyString(plist[@"ref"]) ?: kDefaultCatalogueRef;
		_category      = NonEmptyString(plist[@"category"]);
		_summary       = NonEmptyString(plist[@"description"]);
		_grammars      = [plist[@"grammars"] isKindOfClass:[NSArray class]] ? plist[@"grammars"] : nil;
	}
	return self;
}

- (NSArray<BundleGrammar*>*)bundleGrammars
{
	if(!_bundleGrammars)
	{
		NSMutableArray* res = [NSMutableArray array];
		for(NSDictionary* info in _grammars)
		{
			if(![info isKindOfClass:[NSDictionary class]] || !NonEmptyString(info[@"scope"]))
				continue;

			// The UUID is as required as the scope: “never suggest this grammar
			// again” is recorded by UUID, so a grammar without one cannot be
			// declined — and the code that records it would raise on the nil.
			NSUUID* identifier = NonEmptyString(info[@"uuid"]) ? [[NSUUID alloc] initWithUUIDString:info[@"uuid"]] : nil;
			if(!identifier)
				continue;

			BundleGrammar* grammar = [[BundleGrammar alloc] init];
			grammar.candidate      = self;
			grammar.name           = NonEmptyString(info[@"name"]) ?: _name;
			grammar.identifier     = identifier;
			grammar.fileType       = info[@"scope"];
			grammar.firstLineMatch = NonEmptyString(info[@"firstLineMatch"]);
			grammar.filePatterns   = [info[@"fileTypes"] isKindOfClass:[NSArray class]] ? info[@"fileTypes"] : nil;
			[res addObject:grammar];
		}
		_bundleGrammars = res;
	}
	return _bundleGrammars;
}

- (BOOL)isEqual:(id)other
{
	if(![other isKindOfClass:[self class]])
		return NO;
	BundleCandidate* candidate = other;
	return [_identifier isEqual:candidate.identifier] && [_tapIdentifier isEqualToString:candidate.tapIdentifier];
}

- (NSUInteger)hash       { return _identifier.hash ^ _tapIdentifier.hash; }
- (NSString*)description { return [NSString stringWithFormat:@"<%@: %@ %@@%@>", [self class], _name, _url, _ref]; }
@end

@implementation BundleTapCatalogue
+ (instancetype)catalogueWithPlist:(NSDictionary*)plist tapIdentifier:(NSString*)tapIdentifier error:(NSError**)error
{
	if(![plist isKindOfClass:[NSDictionary class]])
	{
		if(error)
			*error = [NSError errorWithDomain:BundleSubscriptionErrorDomain code:BundleSubscriptionErrorCodeMalformedResponse userInfo:@{ NSLocalizedDescriptionKey: @"The catalogue is not a property list dictionary." }];
		return nil;
	}

	// A missing version is read as version one; a higher one is refused, since
	// guessing at what a later format means is how a cache ends up wrong.
	NSInteger schemaVersion = [plist[@"schemaVersion"] isKindOfClass:[NSNumber class]] ? [plist[@"schemaVersion"] integerValue] : kCatalogueSchemaVersion;
	if(schemaVersion > kCatalogueSchemaVersion)
	{
		if(error)
			*error = [NSError errorWithDomain:BundleSubscriptionErrorDomain code:BundleSubscriptionErrorCodeMalformedResponse userInfo:@{ NSLocalizedDescriptionKey: [NSString stringWithFormat:@"The catalogue uses schema version %ld, which this version of TextMate does not understand.", (long)schemaVersion] }];
		return nil;
	}

	if(![plist[@"bundles"] isKindOfClass:[NSArray class]])
	{
		if(error)
			*error = [NSError errorWithDomain:BundleSubscriptionErrorDomain code:BundleSubscriptionErrorCodeMalformedResponse userInfo:@{ NSLocalizedDescriptionKey: @"The catalogue has no ‘bundles’ array." }];
		return nil;
	}

	BundleTapCatalogue* res = [[BundleTapCatalogue alloc] init];
	res->_name = NonEmptyString(plist[@"name"]);

	NSMutableArray* candidates = [NSMutableArray array];
	NSMutableSet* seen = [NSMutableSet set];

	for(id item in plist[@"bundles"])
	{
		BundleCandidate* candidate = [[BundleCandidate alloc] initWithTapIdentifier:tapIdentifier plistRepresentation:item];
		if(!candidate)
		{
			os_log_error(OS_LOG_DEFAULT, "Dropping malformed catalogue entry: %{public}@", item);
			continue;
		}

		// Two entries for one UUID inside a single catalogue is a malformed tap:
		// first wins, the rest are dropped and logged.
		if([seen containsObject:candidate.identifier])
		{
			os_log_error(OS_LOG_DEFAULT, "Dropping duplicate catalogue entry for %{public}@ (%{public}@)", candidate.name, candidate.identifier.UUIDString);
			continue;
		}

		[seen addObject:candidate.identifier];
		[candidates addObject:candidate];
	}

	res->_candidates = candidates;
	return res;
}

- (BundleCandidate*)candidateWithIdentifier:(NSUUID*)identifier
{
	for(BundleCandidate* candidate in _candidates)
	{
		if([candidate.identifier isEqual:identifier])
			return candidate;
	}
	return nil;
}

- (NSString*)description { return [NSString stringWithFormat:@"<%@: %@ (%lu bundles)>", [self class], _name, _candidates.count]; }
@end
