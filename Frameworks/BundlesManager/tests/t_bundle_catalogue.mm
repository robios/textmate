#import <BundlesManager/BundleCandidate.h>
#import <BundlesManager/Bundle.h> // BundleGrammar, which a candidate’s grammars are
#import "BundleSubscriptionManagerTestingSPI.h"
#import <ns/ns.h>

static NSString* const kUUIDOne = @"52BCFA9A-4C0F-4D0F-99B1-4C1CE8A3B7A2";
static NSString* const kUUIDTwo = @"7A5C7C21-0A22-4CE9-9EF6-1B6E3C0A4D31";

static NSDictionary* CatalogueEntry (NSString* uuid, NSString* name, NSString* url)
{
	return @{ @"uuid": uuid, @"name": name, @"url": url };
}

// Parallel test execution means every test needs its own directory
static BundleSubscriptionManager* TemporaryManager ()
{
	NSString* directory = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"BundleCatalogueTests-%@", NSUUID.UUID.UUIDString]];
	return [[BundleSubscriptionManager alloc] initWithInstallDirectory:directory registryFileURL:[NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"Subscriptions.plist"]]];
}

void test_catalogue_entries_are_validated_individually ()
{
	NSDictionary* plist = @{
		@"schemaVersion": @1,
		@"name": @"robios bundles",
		@"bundles": @[
			CatalogueEntry(kUUIDOne, @"OpenCode", @"https://github.com/someone/opencode.tmbundle"),
			CatalogueEntry(@"not-a-uuid", @"Broken", @"https://github.com/someone/broken"),
			CatalogueEntry(kUUIDTwo, @"Elsewhere", @"https://gitlab.com/someone/elsewhere"), // Not github.com
			@"not a dictionary",
			CatalogueEntry(kUUIDTwo, @"NoURL", @""),
		],
	};

	NSError* error;
	BundleTapCatalogue* catalogue = [BundleTapCatalogue catalogueWithPlist:plist tapIdentifier:@"TAP-1" error:&error];

	// One bad record must not cost every other bundle in the catalogue its entry
	OAK_ASSERT_EQ((bool)catalogue, true);
	OAK_ASSERT_EQ(to_s(catalogue.name), "robios bundles");
	OAK_ASSERT_EQ(catalogue.candidates.count, 1);
	OAK_ASSERT_EQ(to_s(catalogue.candidates.firstObject.name), "OpenCode");
}

void test_duplicate_uuids_within_one_catalogue_are_first_wins ()
{
	NSDictionary* plist = @{ @"bundles": @[
		CatalogueEntry(kUUIDOne, @"First", @"https://github.com/someone/first"),
		CatalogueEntry(kUUIDOne, @"Second", @"https://github.com/someone/second"),
	] };

	BundleTapCatalogue* catalogue = [BundleTapCatalogue catalogueWithPlist:plist tapIdentifier:@"TAP-1" error:nil];
	OAK_ASSERT_EQ(catalogue.candidates.count, 1);
	OAK_ASSERT_EQ(to_s(catalogue.candidates.firstObject.name), "First");
}

void test_the_same_uuid_from_two_taps_stays_two_candidates ()
{
	NSDictionary* plist = @{ @"bundles": @[ CatalogueEntry(kUUIDOne, @"Git", @"https://github.com/one/git.tmbundle") ] };

	BundleCandidate* fromFirst  = [BundleTapCatalogue catalogueWithPlist:plist tapIdentifier:@"TAP-1" error:nil].candidates.firstObject;
	BundleCandidate* fromSecond = [BundleTapCatalogue catalogueWithPlist:plist tapIdentifier:@"TAP-2" error:nil].candidates.firstObject;

	// Candidate identity is (tap, UUID) — two taps offering forks of one bundle
	// is a choice to present, not a duplicate to collapse.
	NSSet* bothCandidates = [NSSet setWithObjects:fromFirst, fromSecond, nil];
	OAK_ASSERT_EQ([fromFirst isEqual:fromSecond], false);
	OAK_ASSERT_EQ(bothCandidates.count, 2);
	OAK_ASSERT_EQ([fromFirst.identifier isEqual:fromSecond.identifier], true);

	BundleCandidate* alsoFromFirst = [BundleTapCatalogue catalogueWithPlist:plist tapIdentifier:@"TAP-1" error:nil].candidates.firstObject;
	OAK_ASSERT_EQ([fromFirst isEqual:alsoFromFirst], true);
}

void test_catalogue_defaults_and_curator_pins ()
{
	NSDictionary* plist = @{ @"bundles": @[
		CatalogueEntry(kUUIDOne, @"Default", @"https://github.com/one/default"),
		@{ @"uuid": kUUIDTwo, @"name": @"Pinned", @"url": @"https://github.com/one/pinned.git/", @"ref": @"3333333333333333333333333333333333333333", @"category": @"Languages", @"description": @"A pinned bundle" },
	] };

	BundleTapCatalogue* catalogue = [BundleTapCatalogue catalogueWithPlist:plist tapIdentifier:@"TAP-1" error:nil];

	// A catalogue entry defaults to ‘main’ — unlike a bare repository URL, where
	// an omitted ref means the branch HEAD advertises.
	OAK_ASSERT_EQ(to_s(catalogue.candidates.firstObject.ref), "main");

	BundleCandidate* pinned = catalogue.candidates.lastObject;
	OAK_ASSERT_EQ(to_s(pinned.ref), "3333333333333333333333333333333333333333");
	OAK_ASSERT_EQ(to_s(pinned.category), "Languages");
	// Canonicalised, so that the two spellings GitHub hands out do not read as a source change
	OAK_ASSERT_EQ(to_s(pinned.url), "https://github.com/one/pinned");
}

void test_a_grammar_without_a_usable_uuid_is_dropped ()
{
	NSDictionary* plist = @{ @"bundles": @[ @{
		@"uuid": kUUIDOne, @"name": @"OpenCode", @"url": @"https://github.com/someone/opencode.tmbundle",
		@"grammars": @[
			@{ @"name": @"OpenCode", @"scope": @"source.opencode", @"uuid": kUUIDTwo },
			@{ @"name": @"No UUID",  @"scope": @"source.nouuid" },
			@{ @"name": @"Bad UUID", @"scope": @"source.baduuid", @"uuid": @"not-a-uuid" },
			@{ @"name": @"No scope", @"uuid": kUUIDTwo },
		],
	} ] };

	BundleCandidate* candidate = [BundleTapCatalogue catalogueWithPlist:plist tapIdentifier:@"TAP-1" error:nil].candidates.firstObject;

	// A catalogue is third-party data, and the suggestion popup records “never
	// suggest this again” by UUID: a grammar without one cannot be declined, and
	// the code that records the refusal would raise on the nil.
	OAK_ASSERT_EQ(candidate.bundleGrammars.count, 1);
	OAK_ASSERT_EQ(to_s(candidate.bundleGrammars.firstObject.fileType), "source.opencode");
	OAK_ASSERT_EQ(to_s(candidate.bundleGrammars.firstObject.identifier.UUIDString), to_s(kUUIDTwo));
}

void test_a_catalogue_from_a_later_format_is_refused_whole ()
{
	NSDictionary* laterFormat = @{ @"schemaVersion": @2, @"bundles": @[] };
	NSDictionary* noVersion   = @{ @"bundles": @[] };
	NSDictionary* noBundles   = @{ @"name": @"No bundles key" };

	NSError* error;
	OAK_ASSERT_EQ((bool)[BundleTapCatalogue catalogueWithPlist:laterFormat tapIdentifier:@"TAP-1" error:&error], false);
	OAK_ASSERT_EQ((bool)error, true);

	// …while a missing version reads as version one
	OAK_ASSERT_EQ((bool)[BundleTapCatalogue catalogueWithPlist:noVersion tapIdentifier:@"TAP-1" error:nil], true);
	OAK_ASSERT_EQ((bool)[BundleTapCatalogue catalogueWithPlist:noBundles tapIdentifier:@"TAP-1" error:nil], false);
}

static NSData* CatalogueData (NSString* name)
{
	NSDictionary* plist = @{ @"name": name, @"bundles": @[ CatalogueEntry(kUUIDOne, @"OpenCode", @"https://github.com/someone/opencode.tmbundle") ] };
	return [NSPropertyListSerialization dataWithPropertyList:plist format:NSPropertyListXMLFormat_v1_0 options:0 error:nil];
}

static NSString* CatalogueNameAtPath (NSString* path)
{
	return [NSDictionary dictionaryWithContentsOfFile:path][@"name"];
}

void test_cache_files_are_immutable_and_named_for_their_revision ()
{
	BundleSubscriptionManager* manager = TemporaryManager();

	NSString* sha = @"1111111111111111111111111111111111111111";

	NSError* error = [manager writeCatalogueData:CatalogueData(@"first") forTapIdentifier:@"TAP-1" catalogueSHA:sha];
	OAK_ASSERT_EQ((bool)error, false);

	NSString* path = [manager cachePathForTapIdentifier:@"TAP-1" catalogueSHA:sha];
	OAK_ASSERT_EQ((bool)[NSFileManager.defaultManager fileExistsAtPath:path], true);

	// A file named for a revision already holds that revision's content, so a
	// second write of the same SHA must leave it exactly as it was.
	error = [manager writeCatalogueData:CatalogueData(@"second") forTapIdentifier:@"TAP-1" catalogueSHA:sha];
	OAK_ASSERT_EQ((bool)error, false);
	OAK_ASSERT_EQ(to_s(CatalogueNameAtPath(path)), "first");
}

void test_an_unreadable_cache_file_is_replaced_rather_than_kept ()
{
	BundleSubscriptionManager* manager = TemporaryManager();

	NSString* sha  = @"1111111111111111111111111111111111111111";
	NSString* path = [manager cachePathForTapIdentifier:@"TAP-1" catalogueSHA:sha];

	[NSFileManager.defaultManager createDirectoryAtPath:[manager cacheDirectoryForTapIdentifier:@"TAP-1"] withIntermediateDirectories:YES attributes:nil error:nil];
	[[@"truncated" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:path atomically:YES];

	// The registry keeps pointing at this name, so a file that cannot be read is
	// not content to preserve — it is the one thing this fetch can repair.
	NSError* error = [manager writeCatalogueData:CatalogueData(@"repaired") forTapIdentifier:@"TAP-1" catalogueSHA:sha];
	OAK_ASSERT_EQ((bool)error, false);
	OAK_ASSERT_EQ(to_s(CatalogueNameAtPath(path)), "repaired");
}

void test_cache_cleanup_keeps_only_the_referenced_revision ()
{
	BundleSubscriptionManager* manager = TemporaryManager();

	NSString* oldSHA = @"1111111111111111111111111111111111111111";
	NSString* newSHA = @"2222222222222222222222222222222222222222";

	[manager writeCatalogueData:[@"old" dataUsingEncoding:NSUTF8StringEncoding] forTapIdentifier:@"TAP-1" catalogueSHA:oldSHA];
	[manager writeCatalogueData:[@"new" dataUsingEncoding:NSUTF8StringEncoding] forTapIdentifier:@"TAP-1" catalogueSHA:newSHA];

	BundleTap* tap = [[BundleTap alloc] initWithIdentifier:@"TAP-1" url:@"https://github.com/robios/tm-bundles" trackingRef:@"main"];
	tap.catalogueSHA = newSHA;

	// Cleanup runs after the state write, so what it removes is by definition
	// unreferenced — including an orphan left by an interrupted refresh.
	[manager removeUnreferencedCacheFilesForTap:tap];

	OAK_ASSERT_EQ((bool)[NSFileManager.defaultManager fileExistsAtPath:[manager cachePathForTapIdentifier:@"TAP-1" catalogueSHA:newSHA]], true);
	OAK_ASSERT_EQ((bool)[NSFileManager.defaultManager fileExistsAtPath:[manager cachePathForTapIdentifier:@"TAP-1" catalogueSHA:oldSHA]], false);
}
