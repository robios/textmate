#import <BundlesManager/BundleSubscription.h>
#import <ns/ns.h>

// The generated runner executes tests in parallel, so every test gets its own
// directory — a shared registry path would make these race each other.
static NSURL* TemporaryRegistryURL ()
{
	NSURL* directory = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"BundleSubscriptionTests-%@", NSUUID.UUID.UUIDString]] isDirectory:YES];
	[NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:nil];
	return [directory URLByAppendingPathComponent:@"Subscriptions.plist"];
}

static void WritePlist (NSURL* url, NSDictionary* plist)
{
	NSData* data = [NSPropertyListSerialization dataWithPropertyList:plist format:NSPropertyListXMLFormat_v1_0 options:0 error:nil];
	[data writeToURL:url atomically:YES];
}

static NSString* const kUUID      = @"52BCFA9A-4C0F-4D0F-99B1-4C1CE8A3B7A2";
static NSString* const kOtherUUID = @"7A5C7C21-0A22-4CE9-9EF6-1B6E3C0A4D31";

void test_round_trip_preserves_unknown_keys ()
{
	NSURL* url = TemporaryRegistryURL();

	WritePlist(url, @{
		@"schemaVersion": @1,
		@"futureTopLevelKey": @"kept",
		@"taps": @[ @{ @"id": @"TAP-1", @"url": @"https://github.com/robios/tm-bundles", @"trackingRef": @"main", @"name": @"robios bundles", @"futureTapKey": @"kept" } ],
		@"bundles": @[ @{ @"uuid": kUUID, @"url": @"https://github.com/someone/opencode.tmbundle", @"refMode": @"catalogue", @"catalogueRef": @"main", @"tap": @"TAP-1", @"installedSHA": @"abc", @"availableSHA": @"def", @"futureBundleKey": @"kept" } ],
	});

	BundleSubscriptionRegistry* registry = [[BundleSubscriptionRegistry alloc] initWithFileURL:url];
	OAK_ASSERT_EQ((bool)[registry load:nil], true);
	OAK_ASSERT_EQ(registry.taps.count, 1);
	OAK_ASSERT_EQ(registry.subscriptions.count, 1);
	OAK_ASSERT_EQ((bool)[registry save:nil], true);

	NSDictionary* plist = [NSDictionary dictionaryWithContentsOfURL:url error:nil];
	OAK_ASSERT_EQ(to_s(plist[@"futureTopLevelKey"]), "kept");
	OAK_ASSERT_EQ(to_s([plist[@"taps"] firstObject][@"futureTapKey"]), "kept");
	OAK_ASSERT_EQ(to_s([plist[@"bundles"] firstObject][@"futureBundleKey"]), "kept");
	OAK_ASSERT_EQ(to_s([plist[@"bundles"] firstObject][@"installedSHA"]), "abc");
}

void test_availableSHA_survives_a_restart ()
{
	NSURL* url = TemporaryRegistryURL();

	BundleSubscriptionRegistry* registry = [[BundleSubscriptionRegistry alloc] initWithFileURL:url];
	BundleSubscription* subscription = [[BundleSubscription alloc] initWithIdentifier:[[NSUUID alloc] initWithUUIDString:kUUID] url:@"https://github.com/someone/opencode.tmbundle"];
	subscription.trackingRef  = @"main";
	subscription.installedSHA = @"1111111111111111111111111111111111111111";
	subscription.availableSHA = @"2222222222222222222222222222222222222222";
	[registry addSubscription:subscription];
	OAK_ASSERT_EQ((bool)[registry save:nil], true);

	// An update offer is state, not a UI artefact: it has to outlive both a
	// restart and a spell without network.
	BundleSubscriptionRegistry* reloaded = [[BundleSubscriptionRegistry alloc] initWithFileURL:url];
	OAK_ASSERT_EQ((bool)[reloaded load:nil], true);
	BundleSubscription* restored = [reloaded subscriptionWithIdentifier:[[NSUUID alloc] initWithUUIDString:kUUID]];
	OAK_ASSERT_EQ((bool)restored, true);
	OAK_ASSERT_EQ(to_s(restored.availableSHA), "2222222222222222222222222222222222222222");
	OAK_ASSERT_EQ((bool)restored.hasUpdate, true);
}

void test_malformed_records_are_dropped_without_taking_the_file ()
{
	NSURL* url = TemporaryRegistryURL();

	WritePlist(url, @{
		@"schemaVersion": @1,
		@"taps": @[ @{ @"url": @"https://github.com/robios/tm-bundles" }, @"not a dictionary", @{ @"id": @"TAP-1", @"url": @"https://github.com/robios/tm-bundles" } ],
		@"bundles": @[ @{ @"uuid": @"not-a-uuid", @"url": @"https://github.com/a/b" }, @{ @"uuid": kUUID }, @{ @"uuid": kOtherUUID, @"url": @"https://github.com/a/b" } ],
	});

	BundleSubscriptionRegistry* registry = [[BundleSubscriptionRegistry alloc] initWithFileURL:url];
	OAK_ASSERT_EQ((bool)[registry load:nil], true);
	OAK_ASSERT_EQ(registry.taps.count, 1);
	OAK_ASSERT_EQ(registry.subscriptions.count, 1);
	OAK_ASSERT_EQ(to_s(registry.subscriptions.firstObject.identifier.UUIDString), to_s(kOtherUUID));
}

void test_a_newer_schema_is_read_but_never_overwritten ()
{
	NSURL* url = TemporaryRegistryURL();

	WritePlist(url, @{ @"schemaVersion": @99, @"bundles": @[ @{ @"uuid": kUUID, @"url": @"https://github.com/a/b" } ] });

	BundleSubscriptionRegistry* registry = [[BundleSubscriptionRegistry alloc] initWithFileURL:url];
	OAK_ASSERT_EQ((bool)[registry load:nil], true);
	OAK_ASSERT_EQ(registry.subscriptions.count, 1);
	OAK_ASSERT_EQ((bool)registry.isReadOnly, true);

	NSError* error;
	OAK_ASSERT_EQ((bool)[registry save:&error], false);
	OAK_ASSERT_EQ((bool)error, true);

	NSDictionary* plist = [NSDictionary dictionaryWithContentsOfURL:url error:nil];
	OAK_ASSERT_EQ([plist[@"schemaVersion"] integerValue], 99);
}

void test_missing_file_loads_as_an_empty_registry ()
{
	BundleSubscriptionRegistry* registry = [[BundleSubscriptionRegistry alloc] initWithFileURL:TemporaryRegistryURL()];
	OAK_ASSERT_EQ((bool)[registry load:nil], true);
	OAK_ASSERT_EQ(registry.taps.count, 0);
	OAK_ASSERT_EQ(registry.subscriptions.count, 0);
	OAK_ASSERT_EQ((bool)[registry save:nil], true);
}

void test_tap_trust_survives_a_restart_without_a_schema_bump ()
{
	NSURL* url = TemporaryRegistryURL();

	// A tap the user trusts, alongside a key this version does not know: an
	// older build reading the file back has to preserve both, and honour
	// neither — which is the failure worth having if it must be one.
	WritePlist(url, @{
		@"schemaVersion": @1,
		@"taps":          @[ @{ @"id": @"TAP-1", @"url": @"https://github.com/robios/tm-bundles", @"autoUpdate": @YES, @"futureTapKey": @"kept" } ],
	});

	BundleSubscriptionRegistry* registry = [[BundleSubscriptionRegistry alloc] initWithFileURL:url];
	OAK_ASSERT_EQ((bool)[registry load:nil], true);
	OAK_ASSERT_EQ((bool)[registry tapWithIdentifier:@"TAP-1"].autoUpdate, true);
	OAK_ASSERT_EQ((bool)[registry save:nil], true);

	NSDictionary* plist = [NSDictionary dictionaryWithContentsOfURL:url error:nil];
	OAK_ASSERT_EQ((bool)[[plist[@"taps"] firstObject][@"autoUpdate"] boolValue], true);
	OAK_ASSERT_EQ(to_s([plist[@"taps"] firstObject][@"futureTapKey"]), "kept");
	OAK_ASSERT_EQ([plist[@"schemaVersion"] integerValue], 1);

	// A tap that was never trusted says so on file rather than by omission, the
	// same way a subscription does
	BundleSubscriptionRegistry* other = [[BundleSubscriptionRegistry alloc] initWithFileURL:TemporaryRegistryURL()];
	[other addTap:[[BundleTap alloc] initWithIdentifier:@"TAP-2" url:@"https://github.com/robios/tm-bundles" trackingRef:nil]];
	OAK_ASSERT_EQ((bool)[other save:nil], true);

	NSDictionary* otherPlist = [NSDictionary dictionaryWithContentsOfURL:other.fileURL error:nil];
	OAK_ASSERT_EQ((bool)[[otherPlist[@"taps"] firstObject][@"autoUpdate"] boolValue], false);
	OAK_ASSERT_EQ((bool)[otherPlist[@"taps"] firstObject][@"autoUpdate"], true);
}

void test_effective_ref_follows_the_mode ()
{
	BundleSubscription* subscription = [[BundleSubscription alloc] initWithIdentifier:NSUUID.UUID url:@"https://github.com/a/b"];
	subscription.catalogueRef = @"main";
	subscription.trackingRef  = @"release";

	subscription.refMode = BundleSubscriptionRefModeCatalogue;
	OAK_ASSERT_EQ(to_s(subscription.effectiveRef), "main");

	subscription.refMode = BundleSubscriptionRefModeUser;
	OAK_ASSERT_EQ(to_s(subscription.effectiveRef), "release");

	// Switching back finds the catalogue’s current value still there: the two
	// refs never overwrite one another.
	subscription.refMode = BundleSubscriptionRefModeCatalogue;
	OAK_ASSERT_EQ(to_s(subscription.effectiveRef), "main");
}

void test_update_is_offered_only_when_the_two_shas_disagree ()
{
	BundleSubscription* subscription = [[BundleSubscription alloc] initWithIdentifier:NSUUID.UUID url:@"https://github.com/a/b"];
	OAK_ASSERT_EQ((bool)subscription.hasUpdate, false);

	subscription.installedSHA = @"1111111111111111111111111111111111111111";
	OAK_ASSERT_EQ((bool)subscription.hasUpdate, false);

	subscription.availableSHA = @"1111111111111111111111111111111111111111";
	OAK_ASSERT_EQ((bool)subscription.hasUpdate, false);

	subscription.availableSHA = @"2222222222222222222222222222222222222222";
	OAK_ASSERT_EQ((bool)subscription.hasUpdate, true);
}
