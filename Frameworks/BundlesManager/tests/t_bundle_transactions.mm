#import "BundleSubscriptionManagerTestingSPI.h"
#import <ns/ns.h>

// What the durability rules are actually worth is decided on the paths that
// fail: a state write that does not land, a backup that cannot be moved back, a
// registry this version is not allowed to rewrite. None of these are reachable
// from the outside without a network, so they are driven from here.

static NSString* const kUUID      = @"52BCFA9A-4C0F-4D0F-99B1-4C1CE8A3B7A2";
static NSString* const kOtherUUID = @"7A5C7C21-0A22-4CE9-9EF6-1B6E3C0A4D31";

// Parallel test execution means every test needs its own directory
static NSString* TemporaryDirectory ()
{
	NSString* directory = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"BundleTransactionTests-%@", NSUUID.UUID.UUIDString]];
	[NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
	return directory;
}

static BOOL Exists (NSString* path)
{
	return [NSFileManager.defaultManager fileExistsAtPath:path];
}

static void WritePlist (NSString* path, NSDictionary* plist)
{
	[NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
	[[NSPropertyListSerialization dataWithPropertyList:plist format:NSPropertyListXMLFormat_v1_0 options:0 error:nil] writeToFile:path atomically:YES];
}

// A directory that reads as a bundle: BundleIdentifierAtPath() asks info.plist
static NSString* MakeBundle (NSString* path, NSString* uuid)
{
	WritePlist([path stringByAppendingPathComponent:@"info.plist"], @{ @"name": @"Test", @"uuid": uuid });
	return path;
}

static void SetDirectoryWritable (NSString* directory, BOOL flag)
{
	[NSFileManager.defaultManager setAttributes:@{ NSFilePosixPermissions: @(flag ? 0700 : 0500) } ofItemAtPath:directory error:nil];
}

// ===========================================
// = A registry this version may not rewrite =
// ===========================================

static BundleSubscriptionManager* ReadOnlyManager (NSString* directory, NSDictionary* subscription)
{
	NSString* registryPath = [directory stringByAppendingPathComponent:@"Subscriptions.plist"];
	WritePlist(registryPath, @{
		@"schemaVersion": @99,
		@"bundles":       subscription ? @[ subscription ] : @[],
	});

	BundleSubscriptionManager* manager = [[BundleSubscriptionManager alloc] initWithInstallDirectory:directory registryFileURL:[NSURL fileURLWithPath:registryPath]];
	[manager loadRegistry];
	return manager;
}

void test_a_newer_schema_refuses_to_uninstall ()
{
	NSString* directory = TemporaryDirectory();
	BundleSubscriptionManager* manager = ReadOnlyManager(directory, @{ @"uuid": kUUID, @"url": @"https://github.com/a/b", @"path": @"Test-52BCFA9A.tmbundle", @"installedSHA": @"1111111111111111111111111111111111111111" });

	NSString* installedPath = MakeBundle([manager.bundlesDirectory stringByAppendingPathComponent:@"Test-52BCFA9A.tmbundle"], kUUID);

	// Otherwise the uninstall would find no path to delete and the assertion
	// below would hold with or without the guard being there at all.
	BundleSubscription* subscription = manager.subscriptions.firstObject;
	OAK_ASSERT_EQ(to_s(subscription.relativePath), "Test-52BCFA9A.tmbundle");

	// The operation queue runs an enqueued block synchronously when nothing else
	// is running, so a refusal is reported before this returns.
	__block NSError* error = nil;
	__block BOOL didFinish = NO;
	[manager uninstallSubscription:subscription completionHandler:^(NSError* err){ error = err; didFinish = YES; }];

	OAK_ASSERT_EQ((bool)didFinish, true);
	OAK_ASSERT_EQ((int)error.code, (int)BundleSubscriptionErrorCodeReadOnlyRegistry);

	// Nothing removed that the file would go on claiming after a restart
	OAK_ASSERT_EQ((bool)Exists(installedPath), true);
	OAK_ASSERT_EQ(manager.subscriptions.count, 1);
}

void test_a_newer_schema_refuses_to_add_a_tap ()
{
	BundleSubscriptionManager* manager = ReadOnlyManager(TemporaryDirectory(), nil);

	__block NSError* error = nil;
	__block BOOL didFinish = NO;
	[manager addTapWithURL:@"https://github.com/robios/tm-bundles" ref:nil completionHandler:^(BundleTap* tap, NSError* err){ error = err; didFinish = YES; }];

	// Refused before the fetch, which is also why this test needs no network
	OAK_ASSERT_EQ((bool)didFinish, true);
	OAK_ASSERT_EQ((int)error.code, (int)BundleSubscriptionErrorCodeReadOnlyRegistry);
	OAK_ASSERT_EQ(manager.taps.count, 0);
}

void test_a_newer_schema_refuses_the_settings_that_have_nowhere_to_report ()
{
	NSString* directory = TemporaryDirectory();
	BundleSubscriptionManager* manager = ReadOnlyManager(directory, @{ @"uuid": kUUID, @"url": @"https://github.com/a/b", @"refMode": @"catalogue" });

	BundleSubscription* subscription = manager.subscriptions.firstObject;
	[manager setAutoUpdate:YES forSubscription:subscription];
	[manager setRef:@"release" forSubscription:subscription];

	// A change that only lasts until the next launch is not a change
	OAK_ASSERT_EQ((bool)subscription.autoUpdate, false);
	OAK_ASSERT_EQ((bool)subscription.trackingRef, false);
	OAK_ASSERT_EQ((int)subscription.refMode, (int)BundleSubscriptionRefModeCatalogue);

	NSDictionary* plist = [NSDictionary dictionaryWithContentsOfFile:[directory stringByAppendingPathComponent:@"Subscriptions.plist"]];
	OAK_ASSERT_EQ([plist[@"schemaVersion"] integerValue], 99);
}

// ========================================
// = The state write as the commit point  =
// ========================================

static BundleSubscriptionManager* Manager (NSString* directory)
{
	BundleSubscriptionManager* manager = [[BundleSubscriptionManager alloc] initWithInstallDirectory:directory registryFileURL:[NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"State/Subscriptions.plist"]]];
	[manager loadRegistry];
	return manager;
}

void test_an_install_that_cannot_be_recorded_leaves_nothing_behind ()
{
	NSString* directory = TemporaryDirectory();
	BundleSubscriptionManager* manager = Manager(directory);

	// A file where the state directory would go: the save cannot succeed
	[[@"in the way" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:[directory stringByAppendingPathComponent:@"State"] atomically:YES];

	NSString* staged = MakeBundle([directory stringByAppendingPathComponent:@"Staging/New.tmbundle"], kUUID);
	BundleSubscription* subscription = [[BundleSubscription alloc] initWithIdentifier:[[NSUUID alloc] initWithUUIDString:kUUID] url:@"https://github.com/a/b"];
	subscription.name = @"Test";

	NSError* error;
	BOOL didCommit = [manager commitStagedBundleAtPath:staged forSubscription:subscription sha:@"1111111111111111111111111111111111111111" error:&error];

	// The copy would otherwise be loaded by the bundle index with nothing on
	// record claiming it, and the caller would have been told it worked.
	OAK_ASSERT_EQ((bool)didCommit, false);
	OAK_ASSERT_EQ((bool)error, true);
	OAK_ASSERT_EQ(manager.subscriptions.count, 0);
	OAK_ASSERT_EQ((bool)Exists([manager.bundlesDirectory stringByAppendingPathComponent:@"Test-52BCFA9A.tmbundle"]), false);
	OAK_ASSERT_EQ((bool)subscription.relativePath, false);
	OAK_ASSERT_EQ((bool)subscription.installedSHA, false);
}

void test_an_update_that_cannot_be_recorded_keeps_the_copy_it_replaced ()
{
	NSString* directory = TemporaryDirectory();
	BundleSubscriptionManager* manager = Manager(directory);

	BundleSubscription* subscription = [[BundleSubscription alloc] initWithIdentifier:[[NSUUID alloc] initWithUUIDString:kUUID] url:@"https://github.com/a/b"];
	subscription.name = @"Test";

	NSString* first = MakeBundle([directory stringByAppendingPathComponent:@"Staging/One.tmbundle"], kUUID);
	OAK_ASSERT_EQ((bool)[manager commitStagedBundleAtPath:first forSubscription:subscription sha:@"1111111111111111111111111111111111111111" error:nil], true);
	OAK_ASSERT_EQ(manager.subscriptions.count, 1);

	NSString* installedPath = [manager.bundlesDirectory stringByAppendingPathComponent:subscription.relativePath];
	OAK_ASSERT_EQ((bool)Exists(installedPath), true);

	// The commit's own write is the one that records the subscription — nobody
	// else saves afterwards, so a state file without it would be the bug.
	NSDictionary* plist = [NSDictionary dictionaryWithContentsOfFile:[directory stringByAppendingPathComponent:@"State/Subscriptions.plist"]];
	OAK_ASSERT_EQ([plist[@"bundles"] count], 1);

	NSString* stateDirectory = [directory stringByAppendingPathComponent:@"State"];
	SetDirectoryWritable(stateDirectory, NO);

	NSString* second = MakeBundle([directory stringByAppendingPathComponent:@"Staging/Two.tmbundle"], kUUID);
	NSError* error;
	BOOL didCommit = [manager commitStagedBundleAtPath:second forSubscription:subscription sha:@"2222222222222222222222222222222222222222" error:&error];
	SetDirectoryWritable(stateDirectory, YES);

	// An update is not an install: the file still names the previous revision,
	// so the bundle stays where it is and the next poll tries again.
	OAK_ASSERT_EQ((bool)didCommit, false);
	OAK_ASSERT_EQ((bool)Exists(installedPath), true);
	OAK_ASSERT_EQ(manager.subscriptions.count, 1);
}

void test_an_uncommitted_catalogue_leaves_the_subscription_on_its_old_ref ()
{
	NSString* directory = TemporaryDirectory();
	NSString* registryPath = [directory stringByAppendingPathComponent:@"State/Subscriptions.plist"];

	WritePlist(registryPath, @{
		@"schemaVersion": @1,
		@"taps":          @[ @{ @"id": @"TAP-1", @"url": @"https://github.com/robios/tm-bundles", @"trackingRef": @"main" } ],
		@"bundles":       @[ @{ @"uuid": kUUID, @"url": @"https://github.com/a/b", @"refMode": @"catalogue", @"catalogueRef": @"v1", @"tap": @"TAP-1" } ],
	});

	BundleSubscriptionManager* manager = [[BundleSubscriptionManager alloc] initWithInstallDirectory:directory registryFileURL:[NSURL fileURLWithPath:registryPath]];
	[manager loadRegistry];

	BundleTap* tap = manager.taps.firstObject;
	BundleSubscription* subscription = manager.subscriptions.firstObject;
	OAK_ASSERT_EQ(to_s(subscription.effectiveRef), "v1");

	NSDictionary* plist = @{ @"bundles": @[ @{ @"uuid": kUUID, @"name": @"Test", @"url": @"https://github.com/a/b", @"ref": @"v2", @"category": @"Languages" } ] };
	BundleTapCatalogue* catalogue = [BundleTapCatalogue catalogueWithPlist:plist tapIdentifier:@"TAP-1" error:nil];

	NSArray* snapshot = [manager catalogueSnapshotForTap:tap];
	[manager applyCatalogue:catalogue forTap:tap];
	OAK_ASSERT_EQ(to_s(subscription.effectiveRef), "v2");

	// What a failed state write has to undo: the pointer on disk never advanced,
	// so the poll that follows must not install what the new catalogue names.
	[manager restoreCatalogueSnapshot:snapshot];
	OAK_ASSERT_EQ(to_s(subscription.effectiveRef), "v1");
	OAK_ASSERT_EQ((bool)subscription.category, false);
}

// ==========================
// = Interrupted Replace    =
// ==========================

// Without a kind key, which is what a Replace journal written before there was
// more than one kind looks like
static NSString* PlantReplaceJournal (BundleSubscriptionManager* manager, NSString* managedPath, NSString* subscribedPath, NSString* uuid)
{
	NSString* transactionDirectory = [[manager.installDirectory stringByAppendingPathComponent:@"Transactions"] stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
	NSString* backupPath = [transactionDirectory stringByAppendingPathComponent:@"Backup.tmbundle"];

	MakeBundle(backupPath, uuid);
	WritePlist([transactionDirectory stringByAppendingPathComponent:@"journal.plist"], @{
		@"uuid":           uuid,
		@"managedPath":    managedPath,
		@"backupPath":     backupPath,
		@"subscribedPath": subscribedPath,
		@"subscription":   @{ @"uuid": uuid, @"url": @"https://github.com/a/b", @"replacesSigned": @YES },
	});
	return transactionDirectory;
}

void test_replace_recovery_keeps_the_backup_when_it_cannot_be_restored ()
{
	NSString* directory = TemporaryDirectory();
	BundleSubscriptionManager* manager = Manager(directory);

	// Nowhere to move the backup to: the official bundle’s directory is gone
	NSString* managedPath    = [directory stringByAppendingPathComponent:@"Managed/Bundles/Test.tmbundle"];
	NSString* subscribedPath = MakeBundle([manager.bundlesDirectory stringByAppendingPathComponent:@"Test-52BCFA9A.tmbundle"], kOtherUUID);

	NSString* transactionDirectory = PlantReplaceJournal(manager, managedPath, subscribedPath, kUUID);
	NSString* backupPath = [transactionDirectory stringByAppendingPathComponent:@"Backup.tmbundle"];

	[manager loadRegistry]; // Recovery runs before the first index build

	// Deleting the replacement and then the directory holding the backup is how
	// one bundle becomes none. Everything stays until the restore succeeds.
	OAK_ASSERT_EQ((bool)Exists(backupPath), true);
	OAK_ASSERT_EQ((bool)Exists(subscribedPath), true);
	OAK_ASSERT_EQ((bool)Exists([transactionDirectory stringByAppendingPathComponent:@"journal.plist"]), true);
}

void test_replace_recovery_rolls_back_once_the_official_bundle_is_back ()
{
	NSString* directory = TemporaryDirectory();
	BundleSubscriptionManager* manager = Manager(directory);

	NSString* managedDirectory = [directory stringByAppendingPathComponent:@"Managed/Bundles"];
	[NSFileManager.defaultManager createDirectoryAtPath:managedDirectory withIntermediateDirectories:YES attributes:nil error:nil];

	NSString* managedPath    = [managedDirectory stringByAppendingPathComponent:@"Test.tmbundle"];
	NSString* subscribedPath = MakeBundle([manager.bundlesDirectory stringByAppendingPathComponent:@"Test-52BCFA9A.tmbundle"], kOtherUUID);

	NSString* transactionDirectory = PlantReplaceJournal(manager, managedPath, subscribedPath, kUUID);

	[manager loadRegistry];

	// One complete source, and it is the official one: the replacement never
	// reached the subscribed destination with the right UUID.
	OAK_ASSERT_EQ((bool)Exists(managedPath), true);
	OAK_ASSERT_EQ((bool)Exists(subscribedPath), false);
	OAK_ASSERT_EQ((bool)Exists(transactionDirectory), false);
	OAK_ASSERT_EQ(manager.subscriptions.count, 0);
}

// ==========================
// = Interrupted Restore    =
// ==========================

void test_completing_a_restore_removes_the_copy_and_the_record_together ()
{
	NSString* directory = TemporaryDirectory();
	NSString* registryPath = [directory stringByAppendingPathComponent:@"State/Subscriptions.plist"];

	WritePlist(registryPath, @{
		@"schemaVersion": @1,
		@"bundles":       @[ @{ @"uuid": kUUID, @"url": @"https://github.com/a/b", @"path": @"Test-52BCFA9A.tmbundle", @"replacesSigned": @YES } ],
	});

	BundleSubscriptionManager* manager = [[BundleSubscriptionManager alloc] initWithInstallDirectory:directory registryFileURL:[NSURL fileURLWithPath:registryPath]];
	[manager loadRegistry];

	NSString* subscribedPath = MakeBundle([manager.bundlesDirectory stringByAppendingPathComponent:@"Test-52BCFA9A.tmbundle"], kUUID);
	NSUUID* identifier = [[NSUUID alloc] initWithUUIDString:kUUID];

	OAK_ASSERT_EQ((bool)[manager completeRestoreOfSubscriptionWithIdentifier:identifier subscribedPath:subscribedPath], false);
	OAK_ASSERT_EQ((bool)Exists(subscribedPath), false);
	OAK_ASSERT_EQ(manager.subscriptions.count, 0);

	NSDictionary* plist = [NSDictionary dictionaryWithContentsOfFile:registryPath];
	OAK_ASSERT_EQ([plist[@"bundles"] count], 0);

	// Recovery calls this too, on a launch that may already have run it
	OAK_ASSERT_EQ((bool)[manager completeRestoreOfSubscriptionWithIdentifier:identifier subscribedPath:subscribedPath], false);
}

void test_a_restore_that_cannot_be_recorded_reports_it ()
{
	NSString* directory = TemporaryDirectory();
	NSString* registryPath = [directory stringByAppendingPathComponent:@"State/Subscriptions.plist"];

	WritePlist(registryPath, @{
		@"schemaVersion": @1,
		@"bundles":       @[ @{ @"uuid": kUUID, @"url": @"https://github.com/a/b", @"path": @"Test-52BCFA9A.tmbundle", @"replacesSigned": @YES } ],
	});

	BundleSubscriptionManager* manager = [[BundleSubscriptionManager alloc] initWithInstallDirectory:directory registryFileURL:[NSURL fileURLWithPath:registryPath]];
	[manager loadRegistry];

	NSString* subscribedPath = MakeBundle([manager.bundlesDirectory stringByAppendingPathComponent:@"Test-52BCFA9A.tmbundle"], kUUID);

	NSString* stateDirectory = [directory stringByAppendingPathComponent:@"State"];
	SetDirectoryWritable(stateDirectory, NO);
	NSError* error = [manager completeRestoreOfSubscriptionWithIdentifier:[[NSUUID alloc] initWithUUIDString:kUUID] subscribedPath:subscribedPath];
	SetDirectoryWritable(stateDirectory, YES);

	// Reported rather than swallowed, which is what keeps the journal in place
	// for the next launch to finish the half that did not land.
	OAK_ASSERT_EQ((bool)error, true);
}

// ============================
// = Interrupted uninstall    =
// ============================

// The state a subscription is in between its copy being set aside and its
// record leaving the file
static NSString* PlantUninstallJournal (BundleSubscriptionManager* manager, NSString* subscribedPath, NSString* uuid)
{
	NSString* transactionDirectory = [[manager.installDirectory stringByAppendingPathComponent:@"Transactions"] stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
	NSString* backupPath = [transactionDirectory stringByAppendingPathComponent:@"Backup.tmbundle"];

	MakeBundle(backupPath, uuid);
	WritePlist([transactionDirectory stringByAppendingPathComponent:@"journal.plist"], @{
		@"kind":           @"uninstall",
		@"uuid":           uuid,
		@"subscribedPath": subscribedPath,
		@"backupPath":     backupPath,
		@"subscription":   @{ @"uuid": uuid, @"url": @"https://github.com/a/b", @"path": @"Test-52BCFA9A.tmbundle" },
	});
	return transactionDirectory;
}

static BundleSubscriptionManager* ManagerWithState (NSString* directory, NSDictionary* state)
{
	NSString* registryPath = [directory stringByAppendingPathComponent:@"State/Subscriptions.plist"];
	WritePlist(registryPath, state);

	BundleSubscriptionManager* manager = [[BundleSubscriptionManager alloc] initWithInstallDirectory:directory registryFileURL:[NSURL fileURLWithPath:registryPath]];
	[manager loadRegistry];
	return manager;
}

void test_an_uninstall_that_cannot_be_recorded_puts_the_copy_back ()
{
	NSString* directory = TemporaryDirectory();
	BundleSubscriptionManager* manager = ManagerWithState(directory, @{
		@"schemaVersion": @1,
		@"bundles":       @[ @{ @"uuid": kUUID, @"url": @"https://github.com/a/b", @"path": @"Test-52BCFA9A.tmbundle", @"installedSHA": @"1111111111111111111111111111111111111111" } ],
	});

	NSString* installedPath = MakeBundle([manager.bundlesDirectory stringByAppendingPathComponent:@"Test-52BCFA9A.tmbundle"], kUUID);

	NSString* stateDirectory = [directory stringByAppendingPathComponent:@"State"];
	SetDirectoryWritable(stateDirectory, NO);

	__block NSError* error = nil;
	__block BOOL didFinish = NO;
	[manager uninstallSubscription:manager.subscriptions.firstObject completionHandler:^(NSError* err){ error = err; didFinish = YES; }];
	SetDirectoryWritable(stateDirectory, YES);

	// The file still names this subscription, so the bundle it names has to be
	// where it says: deleting first and failing to record it is how a record
	// ends up pointing at nothing, with nothing left to put back.
	OAK_ASSERT_EQ((bool)didFinish, true);
	OAK_ASSERT_EQ((bool)error, true);
	OAK_ASSERT_EQ((bool)Exists(installedPath), true);
	OAK_ASSERT_EQ(manager.subscriptions.count, 1);
	OAK_ASSERT_EQ([[NSFileManager.defaultManager contentsOfDirectoryAtPath:[directory stringByAppendingPathComponent:@"Transactions"] error:nil] count], 0);
}

void test_an_uninstall_interrupted_before_the_record_left_the_file_is_rolled_back ()
{
	NSString* directory = TemporaryDirectory();
	BundleSubscriptionManager* manager = ManagerWithState(directory, @{
		@"schemaVersion": @1,
		@"bundles":       @[ @{ @"uuid": kUUID, @"url": @"https://github.com/a/b", @"path": @"Test-52BCFA9A.tmbundle" } ],
	});

	NSString* subscribedPath       = [manager.bundlesDirectory stringByAppendingPathComponent:@"Test-52BCFA9A.tmbundle"];
	NSString* transactionDirectory = PlantUninstallJournal(manager, subscribedPath, kUUID);

	[manager loadRegistry];

	// The record is still on file, so the removal never committed
	OAK_ASSERT_EQ((bool)Exists(subscribedPath), true);
	OAK_ASSERT_EQ((bool)Exists(transactionDirectory), false);
	OAK_ASSERT_EQ(manager.subscriptions.count, 1);
}

void test_an_uninstall_interrupted_after_the_record_left_the_file_is_finished ()
{
	NSString* directory = TemporaryDirectory();
	BundleSubscriptionManager* manager = ManagerWithState(directory, @{ @"schemaVersion": @1, @"bundles": @[] });

	NSString* subscribedPath       = [manager.bundlesDirectory stringByAppendingPathComponent:@"Test-52BCFA9A.tmbundle"];
	NSString* transactionDirectory = PlantUninstallJournal(manager, subscribedPath, kUUID);

	[manager loadRegistry];

	// Nothing claims the backup any more, and the copy stays gone
	OAK_ASSERT_EQ((bool)Exists(transactionDirectory), false);
	OAK_ASSERT_EQ((bool)Exists(subscribedPath), false);
}

// =====================================
// = Recovery a downgrade must not run =
// =====================================

void test_a_newer_schema_leaves_interrupted_transactions_alone ()
{
	NSString* directory = TemporaryDirectory();
	BundleSubscriptionManager* manager = ReadOnlyManager(directory, nil);

	NSString* managedDirectory = [directory stringByAppendingPathComponent:@"Managed/Bundles"];
	[NSFileManager.defaultManager createDirectoryAtPath:managedDirectory withIntermediateDirectories:YES attributes:nil error:nil];

	NSString* managedPath    = [managedDirectory stringByAppendingPathComponent:@"Test.tmbundle"];
	NSString* subscribedPath = MakeBundle([manager.bundlesDirectory stringByAppendingPathComponent:@"Test-52BCFA9A.tmbundle"], kOtherUUID);

	NSString* transactionDirectory = PlantReplaceJournal(manager, managedPath, subscribedPath, kUUID);

	[manager loadRegistry];

	// Recovery moves bundles and rewrites the registry, and this version may do
	// neither: finishing a transaction it cannot record is worse than leaving it
	// for the version that started it.
	OAK_ASSERT_EQ((bool)Exists([transactionDirectory stringByAppendingPathComponent:@"Backup.tmbundle"]), true);
	OAK_ASSERT_EQ((bool)Exists(subscribedPath), true);
	OAK_ASSERT_EQ((bool)Exists(managedPath), false);
}

void test_a_transaction_of_an_unknown_kind_is_left_untouched ()
{
	NSString* directory = TemporaryDirectory();
	BundleSubscriptionManager* manager = Manager(directory);

	NSString* transactionDirectory = [[directory stringByAppendingPathComponent:@"Transactions"] stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
	NSString* keptPath = MakeBundle([transactionDirectory stringByAppendingPathComponent:@"Backup.tmbundle"], kUUID);

	WritePlist([transactionDirectory stringByAppendingPathComponent:@"journal.plist"], @{
		@"kind": @"migrate",
		@"uuid": kUUID,
	});

	[manager loadRegistry];

	// A kind from a later version names rules we do not have. Reading it as the
	// one kind that has no key — Replace — would finish it the wrong way, or
	// discard it along with the only copy it is holding.
	OAK_ASSERT_EQ((bool)Exists(keptPath), true);
	OAK_ASSERT_EQ((bool)Exists([transactionDirectory stringByAppendingPathComponent:@"journal.plist"]), true);
}

// ==============================
// = Settings are state as well =
// ==============================

void test_a_setting_that_cannot_be_recorded_does_not_take_effect ()
{
	NSString* directory = TemporaryDirectory();
	BundleSubscriptionManager* manager = ManagerWithState(directory, @{
		@"schemaVersion": @1,
		@"bundles":       @[ @{ @"uuid": kUUID, @"url": @"https://github.com/a/b", @"refMode": @"catalogue", @"catalogueRef": @"v1" } ],
	});

	BundleSubscription* subscription = manager.subscriptions.firstObject;

	NSString* stateDirectory = [directory stringByAppendingPathComponent:@"State"];
	SetDirectoryWritable(stateDirectory, NO);

	__block NSError* error = nil;
	[manager setAutoUpdate:YES forSubscription:subscription completionHandler:^(NSError* err){ error = err; }];
	SetDirectoryWritable(stateDirectory, YES);

	// Otherwise the next scheduled poll installs on a policy the file has never
	// heard of, and the launch after that reads the old one back.
	OAK_ASSERT_EQ((bool)error, true);
	OAK_ASSERT_EQ((bool)subscription.autoUpdate, false);
}

void test_removing_a_tap_that_cannot_be_recorded_changes_nothing ()
{
	NSString* directory = TemporaryDirectory();
	BundleSubscriptionManager* manager = ManagerWithState(directory, @{
		@"schemaVersion": @1,
		@"taps":          @[ @{ @"id": @"TAP-1", @"url": @"https://github.com/robios/tm-bundles", @"trackingRef": @"main" } ],
		@"bundles":       @[ @{ @"uuid": kUUID, @"url": @"https://github.com/a/b", @"refMode": @"catalogue", @"catalogueRef": @"v1", @"tap": @"TAP-1" } ],
	});

	NSString* cachePath = [manager cachePathForTapIdentifier:@"TAP-1" catalogueSHA:@"1111111111111111111111111111111111111111"];
	[NSFileManager.defaultManager createDirectoryAtPath:[manager cacheDirectoryForTapIdentifier:@"TAP-1"] withIntermediateDirectories:YES attributes:nil error:nil];
	[[@"cached" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:cachePath atomically:YES];

	NSString* stateDirectory = [directory stringByAppendingPathComponent:@"State"];
	SetDirectoryWritable(stateDirectory, NO);

	__block NSError* error = nil;
	__block BOOL didFinish = NO;
	[manager removeTap:manager.taps.firstObject completionHandler:^(NSError* err){ error = err; didFinish = YES; }];
	SetDirectoryWritable(stateDirectory, YES);

	// The tap is still registered on disk, so it is still registered here — and
	// its cache is still the cache of a registered tap.
	OAK_ASSERT_EQ((bool)didFinish, true);
	OAK_ASSERT_EQ((bool)error, true);
	OAK_ASSERT_EQ(manager.taps.count, 1);
	OAK_ASSERT_EQ(to_s(manager.subscriptions.firstObject.tapIdentifier), "TAP-1");
	OAK_ASSERT_EQ((int)manager.subscriptions.firstObject.refMode, (int)BundleSubscriptionRefModeCatalogue);
	OAK_ASSERT_EQ((bool)Exists(cachePath), true);
}

// …and the same thing again through the refresh’s own commit, so that the
// rollback is not merely available but actually reached.
void test_a_catalogue_refresh_that_cannot_be_recorded_rolls_itself_back ()
{
	NSString* directory = TemporaryDirectory();
	NSString* oldSHA = @"1111111111111111111111111111111111111111";
	NSString* newSHA = @"2222222222222222222222222222222222222222";

	BundleSubscriptionManager* manager = ManagerWithState(directory, @{
		@"schemaVersion": @1,
		// No trackingRef: the refresh resolves one from HEAD, which the rollback
		// has to take back with the rest.
		@"taps":          @[ @{ @"id": @"TAP-1", @"url": @"https://github.com/robios/tm-bundles", @"name": @"robios bundles", @"catalogueSHA": oldSHA } ],
		@"bundles":       @[ @{ @"uuid": kUUID, @"url": @"https://github.com/a/b", @"refMode": @"catalogue", @"catalogueRef": @"v1", @"tap": @"TAP-1" } ],
	});

	NSDictionary* oldPlist = @{ @"name": @"robios bundles", @"bundles": @[ @{ @"uuid": kUUID, @"name": @"Test", @"url": @"https://github.com/a/b", @"ref": @"v1" } ] };
	[NSFileManager.defaultManager createDirectoryAtPath:[manager cacheDirectoryForTapIdentifier:@"TAP-1"] withIntermediateDirectories:YES attributes:nil error:nil];
	WritePlist([manager cachePathForTapIdentifier:@"TAP-1" catalogueSHA:oldSHA], oldPlist);
	[manager loadRegistry];

	BundleTap* tap = manager.taps.firstObject;
	BundleSubscription* subscription = manager.subscriptions.firstObject;
	OAK_ASSERT_EQ(to_s(subscription.effectiveRef), "v1");

	NSDictionary* newPlist = @{ @"name": @"renamed", @"bundles": @[ @{ @"uuid": kUUID, @"name": @"Test", @"url": @"https://github.com/a/b", @"ref": @"v2" } ] };
	NSData* newData = [NSPropertyListSerialization dataWithPropertyList:newPlist format:NSPropertyListXMLFormat_v1_0 options:0 error:nil];
	BundleTapCatalogue* newCatalogue = [BundleTapCatalogue catalogueWithPlist:newPlist tapIdentifier:@"TAP-1" error:nil];

	NSString* stateDirectory = [directory stringByAppendingPathComponent:@"State"];
	SetDirectoryWritable(stateDirectory, NO);
	NSError* error = [manager commitCatalogue:newCatalogue data:newData sha:newSHA resolvedRef:@"main" forTap:tap];
	SetDirectoryWritable(stateDirectory, YES);

	// Nothing about the new catalogue survives a write that did not land — not
	// the pointer, not the name, and above all not the ref a poll would install.
	OAK_ASSERT_EQ((bool)error, true);
	OAK_ASSERT_EQ(to_s(tap.catalogueSHA), to_s(oldSHA));
	OAK_ASSERT_EQ(to_s(tap.name), "robios bundles");
	OAK_ASSERT_EQ((bool)tap.trackingRef, false);
	OAK_ASSERT_EQ(to_s(subscription.effectiveRef), "v1");
	OAK_ASSERT_EQ(to_s([manager catalogueForTap:tap].candidates.firstObject.ref), "v1");
}

void test_registering_a_tap_that_cannot_be_recorded_leaves_no_tap ()
{
	NSString* directory = TemporaryDirectory();
	BundleSubscriptionManager* manager = ManagerWithState(directory, @{ @"schemaVersion": @1, @"taps": @[], @"bundles": @[] });

	NSString* sha = @"1111111111111111111111111111111111111111";
	NSDictionary* plist = @{ @"name": @"robios bundles", @"bundles": @[ @{ @"uuid": kUUID, @"name": @"Test", @"url": @"https://github.com/a/b", @"ref": @"v1" } ] };
	NSData* data = [NSPropertyListSerialization dataWithPropertyList:plist format:NSPropertyListXMLFormat_v1_0 options:0 error:nil];
	BundleTapCatalogue* catalogue = [BundleTapCatalogue catalogueWithPlist:plist tapIdentifier:@"TAP-1" error:nil];

	BundleTap* tap = [[BundleTap alloc] initWithIdentifier:@"TAP-1" url:@"https://github.com/robios/tm-bundles" trackingRef:nil];

	NSString* stateDirectory = [directory stringByAppendingPathComponent:@"State"];
	SetDirectoryWritable(stateDirectory, NO);
	NSError* error = [manager commitNewTap:tap catalogue:catalogue data:data sha:sha resolvedRef:@"main"];
	SetDirectoryWritable(stateDirectory, YES);

	// An add that reports a failure must be one Preferences never saw, that no
	// later unrelated save can persist, and that a restart does not find.
	OAK_ASSERT_EQ((bool)error, true);
	OAK_ASSERT_EQ(manager.taps.count, 0);
	OAK_ASSERT_EQ((bool)[manager catalogueForTap:tap], false);
	OAK_ASSERT_EQ((bool)Exists([manager cachePathForTapIdentifier:@"TAP-1" catalogueSHA:sha]), false);

	BundleSubscriptionManager* reloaded = [[BundleSubscriptionManager alloc] initWithInstallDirectory:directory registryFileURL:[NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"State/Subscriptions.plist"]]];
	[reloaded loadRegistry];
	OAK_ASSERT_EQ(reloaded.taps.count, 0);
}

void test_replace_rollback_that_cannot_be_recorded_keeps_its_journal ()
{
	NSString* directory = TemporaryDirectory();
	BundleSubscriptionManager* manager = ManagerWithState(directory, @{
		@"schemaVersion": @1,
		@"bundles":       @[ @{ @"uuid": kUUID, @"url": @"https://github.com/a/b", @"path": @"Test-52BCFA9A.tmbundle", @"replacesSigned": @YES } ],
	});

	// The official bundle is already back, so recovery rolls the rest back too:
	// the replacement goes, and with it the record that named it.
	NSString* managedDirectory = [directory stringByAppendingPathComponent:@"Managed/Bundles"];
	[NSFileManager.defaultManager createDirectoryAtPath:managedDirectory withIntermediateDirectories:YES attributes:nil error:nil];
	NSString* managedPath = MakeBundle([managedDirectory stringByAppendingPathComponent:@"Test.tmbundle"], kUUID);

	NSString* subscribedPath = MakeBundle([manager.bundlesDirectory stringByAppendingPathComponent:@"Test-52BCFA9A.tmbundle"], kOtherUUID);
	NSString* transactionDirectory = PlantReplaceJournal(manager, managedPath, subscribedPath, kUUID);

	NSString* stateDirectory = [directory stringByAppendingPathComponent:@"State"];
	SetDirectoryWritable(stateDirectory, NO);
	[manager loadRegistry];
	SetDirectoryWritable(stateDirectory, YES);

	// Dropping the record is part of the rollback, so a write that did not land
	// leaves the journal to say so — otherwise the file goes on claiming a
	// replacement that is no longer anywhere, with nothing left to explain it.
	OAK_ASSERT_EQ((bool)Exists([transactionDirectory stringByAppendingPathComponent:@"journal.plist"]), true);
	OAK_ASSERT_EQ(manager.subscriptions.count, 1);
	OAK_ASSERT_EQ((bool)Exists(managedPath), true);
}

// The queue is busy for as long as this operation holds its ‘done’ block, which
// is how a test gets two settings waiting on it at once.
static dispatch_block_t BlockTheQueue (BundleSubscriptionManager* manager)
{
	__block dispatch_block_t release = nil;
	dispatch_semaphore_t started = dispatch_semaphore_create(0);

	[manager enqueueOperation:^(dispatch_block_t done){
		release = done;
		dispatch_semaphore_signal(started);
	}];

	dispatch_semaphore_wait(started, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
	return release;
}

void test_a_queued_setting_undoes_to_what_the_one_before_it_committed ()
{
	NSString* directory = TemporaryDirectory();
	BundleSubscriptionManager* manager = ManagerWithState(directory, @{
		@"schemaVersion": @1,
		@"bundles":       @[ @{ @"uuid": kUUID, @"url": @"https://github.com/a/b", @"refMode": @"user", @"trackingRef": @"v1" } ],
	});

	BundleSubscription* subscription = manager.subscriptions.firstObject;
	NSString* stateDirectory = [directory stringByAppendingPathComponent:@"State"];

	dispatch_block_t releaseQueue = BlockTheQueue(manager);

	// Both are asked for while the queue is busy, so both are queued before
	// either runs — and each has to read the ref as it is when its own turn
	// comes, not as it was when the user asked.
	dispatch_semaphore_t finished = dispatch_semaphore_create(0);
	__block NSError* secondError = nil;

	[manager setRef:@"v2" forSubscription:subscription completionHandler:^(NSError* error){
		SetDirectoryWritable(stateDirectory, NO); // Only the second save fails
	}];

	[manager setRef:@"v3" forSubscription:subscription completionHandler:^(NSError* error){
		secondError = error;
		dispatch_semaphore_signal(finished);
	}];

	releaseQueue();
	dispatch_semaphore_wait(finished, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
	SetDirectoryWritable(stateDirectory, YES);

	OAK_ASSERT_EQ((bool)secondError, true);
	OAK_ASSERT_EQ(to_s(subscription.trackingRef), "v2");

	NSDictionary* plist = [NSDictionary dictionaryWithContentsOfFile:[stateDirectory stringByAppendingPathComponent:@"Subscriptions.plist"]];
	OAK_ASSERT_EQ(to_s([plist[@"bundles"] firstObject][@"trackingRef"]), "v2");
}

void test_a_registry_that_cannot_be_read_is_not_a_registry_with_nothing_in_it ()
{
	NSString* directory = TemporaryDirectory();
	NSString* registryPath = [directory stringByAppendingPathComponent:@"State/Subscriptions.plist"];

	[NSFileManager.defaultManager createDirectoryAtPath:registryPath.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
	[[@"<?xml version=\"1.0\"?><plist><dict><key>truncated" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:registryPath atomically:YES];

	BundleSubscriptionManager* manager = [[BundleSubscriptionManager alloc] initWithInstallDirectory:directory registryFileURL:[NSURL fileURLWithPath:registryPath]];

	NSString* subscribedPath = MakeBundle([[directory stringByAppendingPathComponent:@"Bundles"] stringByAppendingPathComponent:@"Test-52BCFA9A.tmbundle"], kUUID);
	NSString* transactionDirectory = PlantUninstallJournal(manager, subscribedPath, kUUID);

	[manager loadRegistry];

	// An empty registry is a claim about the user's subscriptions, and a file we
	// could not read makes no claim at all: saving over it would discard every
	// tap and subscription it holds, and recovery would read the absent record
	// as an uninstall that had already committed and delete the bundle.
	OAK_ASSERT_EQ((bool)Exists(subscribedPath), true);
	OAK_ASSERT_EQ((bool)Exists([transactionDirectory stringByAppendingPathComponent:@"journal.plist"]), true);

	__block NSError* error = nil;
	[manager addTapWithURL:@"https://github.com/robios/tm-bundles" ref:nil completionHandler:^(BundleTap* tap, NSError* err){ error = err; }];
	OAK_ASSERT_EQ((int)error.code, (int)BundleSubscriptionErrorCodeReadOnlyRegistry);

	NSString* onDisk = [[NSString alloc] initWithContentsOfFile:registryPath encoding:NSUTF8StringEncoding error:nil];
	OAK_ASSERT_EQ((bool)[onDisk hasPrefix:@"<?xml"], true);
}

void test_one_repository_offering_a_bundle_twice_installs_it_once ()
{
	NSString* directory = TemporaryDirectory();
	BundleSubscriptionManager* manager = ManagerWithState(directory, @{ @"schemaVersion": @1, @"bundles": @[] });

	// A monorepo whose two directories carry the same UUID. The second is not a
	// second bundle, and installing it would be taken for an update of the
	// first: a copy under a name no record points at.
	NSString* first  = MakeBundle([directory stringByAppendingPathComponent:@"Staging/One.tmbundle"], kUUID);
	NSString* second = MakeBundle([directory stringByAppendingPathComponent:@"Staging/Two.tmbundle"], kUUID);

	NSError* error = nil;
	NSArray<BundleSubscription*>* installed = [manager installStagedBundlesAtPaths:@[ first, second ] fromRepositoryURL:@"https://github.com/a/b" name:@"b" sha:@"1111111111111111111111111111111111111111" ref:@"main" error:&error];

	OAK_ASSERT_EQ(installed.count, 1);
	OAK_ASSERT_EQ(manager.subscriptions.count, 1);
	OAK_ASSERT_EQ([[NSFileManager.defaultManager contentsOfDirectoryAtPath:manager.bundlesDirectory error:nil] count], 1);

	// The one that was skipped is still where it was staged, to be discarded
	// with the rest of the transaction directory.
	OAK_ASSERT_EQ((bool)Exists(second), true);
}

void test_a_candidate_installed_after_its_tap_is_gone_becomes_a_one_off ()
{
	NSString* directory = TemporaryDirectory();
	BundleSubscriptionManager* manager = ManagerWithState(directory, @{ @"schemaVersion": @1, @"taps": @[], @"bundles": @[] });

	NSDictionary* plist = @{ @"bundles": @[ @{ @"uuid": kUUID, @"name": @"Test", @"url": @"https://github.com/a/b", @"ref": @"v1" } ] };
	BundleCandidate* candidate = [BundleTapCatalogue catalogueWithPlist:plist tapIdentifier:@"TAP-1" error:nil].candidates.firstObject;

	// The tap was removed while this install waited its turn on the queue, so
	// there is no tap left to follow — but there is still a ref to install.
	BundleSubscription* subscription = [manager subscriptionFromCandidate:candidate];

	OAK_ASSERT_EQ((bool)subscription.tapIdentifier, false);
	OAK_ASSERT_EQ((int)subscription.refMode, (int)BundleSubscriptionRefModeUser);
	OAK_ASSERT_EQ(to_s(subscription.effectiveRef), "v1");
}
