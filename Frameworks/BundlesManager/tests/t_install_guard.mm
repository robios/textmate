#import "BundlesManagerTestingSPI.h"

// The subscription guard exists so a signed download can never silently
// eclipse a subscribed copy. Restore is the sanctioned exception, and the
// exception is a set of UUIDs rather than a switch: the dependency walk can
// pull other subscribed bundles into the same install, and a blanket opt-out
// would displace those too — the exact failure the guard was built against.

static Bundle* MakeBundle (NSString* name, BOOL installed)
{
	Bundle* bundle = [[Bundle alloc] initWithIdentifier:NSUUID.UUID];
	bundle.name      = name;
	bundle.installed = installed;
	return bundle;
}

static NSSet<NSUUID*>* Subscribed (NSArray<Bundle*>* bundles)
{
	return [NSSet setWithArray:[bundles valueForKey:@"identifier"]];
}

static BOOL Contains (NSSet<Bundle*>* set, Bundle* bundle)
{
	return [set containsObject:bundle];
}

void test_a_subscribed_bundle_is_refused ()
{
	Bundle* bundle = MakeBundle(@"A", NO);
	NSSet<NSUUID*>* subscribed = Subscribed(@[ bundle ]);

	NSSet<Bundle*>* res = [BundlesManager.sharedInstance bundlesToInstallForBundles:@[ bundle ] displacingSubscriptionsFor:nil subscriptionTest:^BOOL(NSUUID* identifier){
		return [subscribed containsObject:identifier];
	}];
	OAK_ASSERT_EQ(res.count, 0UL);
}

void test_restore_displaces_the_restored_subscription ()
{
	Bundle* bundle = MakeBundle(@"A", NO);
	NSSet<NSUUID*>* subscribed = Subscribed(@[ bundle ]);

	NSSet<Bundle*>* res = [BundlesManager.sharedInstance bundlesToInstallForBundles:@[ bundle ] displacingSubscriptionsFor:[NSSet setWithObject:bundle.identifier] subscriptionTest:^BOOL(NSUUID* identifier){
		return [subscribed containsObject:identifier];
	}];
	OAK_ASSERT(Contains(res, bundle));
}

void test_restore_does_not_displace_a_subscribed_dependency ()
{
	// Restoring A while a subscription owns its dependency B: A’s official
	// copy is allowed through, B must stay refused — official B landing in
	// Managed would silently eclipse the subscribed B.
	Bundle* dependency = MakeBundle(@"B", NO);
	Bundle* bundle     = MakeBundle(@"A", NO);
	bundle.dependencies = @[ dependency ];
	NSSet<NSUUID*>* subscribed = Subscribed(@[ bundle, dependency ]);

	NSSet<Bundle*>* res = [BundlesManager.sharedInstance bundlesToInstallForBundles:@[ bundle ] displacingSubscriptionsFor:[NSSet setWithObject:bundle.identifier] subscriptionTest:^BOOL(NSUUID* identifier){
		return [subscribed containsObject:identifier];
	}];
	OAK_ASSERT(Contains(res, bundle));
	OAK_ASSERT(!Contains(res, dependency));
}

void test_an_unsubscribed_dependency_still_installs_during_restore ()
{
	Bundle* dependency = MakeBundle(@"B", NO);
	Bundle* bundle     = MakeBundle(@"A", NO);
	bundle.dependencies = @[ dependency ];
	NSSet<NSUUID*>* subscribed = Subscribed(@[ bundle ]);

	NSSet<Bundle*>* res = [BundlesManager.sharedInstance bundlesToInstallForBundles:@[ bundle ] displacingSubscriptionsFor:[NSSet setWithObject:bundle.identifier] subscriptionTest:^BOOL(NSUUID* identifier){
		return [subscribed containsObject:identifier];
	}];
	OAK_ASSERT(Contains(res, bundle));
	OAK_ASSERT(Contains(res, dependency));
	OAK_ASSERT_EQ(dependency.isDependency, YES);
}

void test_a_built_in_bundle_is_refused_even_as_a_dependency ()
{
	Bundle* dependency = MakeBundle(@"B", NO);
	dependency.builtIn = YES;
	Bundle* bundle     = MakeBundle(@"A", NO);
	bundle.dependencies = @[ dependency ];

	NSSet<Bundle*>* res = [BundlesManager.sharedInstance bundlesToInstallForBundles:@[ bundle ] displacingSubscriptionsFor:nil subscriptionTest:^BOOL(NSUUID* identifier){
		return NO;
	}];
	OAK_ASSERT(Contains(res, bundle));
	OAK_ASSERT(!Contains(res, dependency));
}

void test_an_installed_dependency_is_not_revisited ()
{
	Bundle* dependency = MakeBundle(@"B", YES);
	Bundle* bundle     = MakeBundle(@"A", NO);
	bundle.dependencies = @[ dependency ];

	NSSet<Bundle*>* res = [BundlesManager.sharedInstance bundlesToInstallForBundles:@[ bundle ] displacingSubscriptionsFor:nil subscriptionTest:^BOOL(NSUUID* identifier){
		return NO;
	}];
	OAK_ASSERT(Contains(res, bundle));
	OAK_ASSERT(!Contains(res, dependency));
}
