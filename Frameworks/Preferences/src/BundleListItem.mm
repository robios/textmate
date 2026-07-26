#import "BundleListItem.h"

static NSString* ShortSHA (NSString* sha)
{
	return sha.length >= 7 ? [sha substringToIndex:7] : sha;
}

@implementation BundleListItem
{
	NSString* _tapName;
	BOOL      _installedFromAnotherTap;
}

+ (NSArray<BundleListItem*>*)currentItems
{
	BundleSubscriptionManager* manager = BundleSubscriptionManager.sharedInstance;

	NSMutableArray<BundleListItem*>* res = [NSMutableArray array];
	NSMutableDictionary<NSUUID*, BundleSubscription*>* subscriptionsByIdentifier = [NSMutableDictionary dictionary];

	for(BundleSubscription* subscription in manager.subscriptions)
	{
		subscriptionsByIdentifier[subscription.identifier] = subscription;

		BundleListItem* item = [[BundleListItem alloc] init];
		item->_kind         = BundleListItemKindSubscription;
		item->_subscription = subscription;
		item->_tapName      = [manager tapForSubscription:subscription].name ?: subscription.originTapName;
		[res addObject:item];
	}

	for(Bundle* bundle in BundlesManager.sharedInstance.bundles)
	{
		// A UUID can have only one active source. When a subscription provides
		// it, that row is the truthful one; the official copy comes back through
		// unsubscribing, not through an install button that would be refused.
		if(subscriptionsByIdentifier[bundle.identifier])
			continue;

		BundleListItem* item = [[BundleListItem alloc] init];
		item->_kind   = BundleListItemKindSigned;
		item->_bundle = bundle;
		[res addObject:item];
	}

	for(BundleCandidate* candidate in manager.candidates)
	{
		BundleSubscription* subscription = subscriptionsByIdentifier[candidate.identifier];
		if(subscription && [subscription.tapIdentifier isEqualToString:candidate.tapIdentifier])
			continue; // Already represented by its own subscription row

		BundleListItem* item = [[BundleListItem alloc] init];
		item->_kind      = BundleListItemKindCandidate;
		item->_candidate = candidate;
		item->_tapName   = [manager tapForCandidate:candidate].name ?: @"Tap";
		item->_installedFromAnotherTap = subscription != nil;
		[res addObject:item];
	}

	return res;
}

- (NSString*)name
{
	switch(_kind)
	{
		case BundleListItemKindSubscription: return _subscription.name;
		case BundleListItemKindCandidate:    return _candidate.name;
		default:                             return _bundle.name;
	}
}

- (NSString*)category
{
	switch(_kind)
	{
		case BundleListItemKindSubscription: return _subscription.category ?: @"Subscribed";
		case BundleListItemKindCandidate:    return _candidate.category ?: @"Subscribed";
		default:                             return _bundle.category;
	}
}

- (NSString*)textSummary
{
	switch(_kind)
	{
		case BundleListItemKindSubscription: return _subscription.summary ?: @"";
		case BundleListItemKindCandidate:    return _candidate.summary ?: @"";
		default:                             return _bundle.textSummary;
	}
}

- (NSURL*)htmlURL
{
	switch(_kind)
	{
		case BundleListItemKindSubscription: return [NSURL URLWithString:_subscription.url];
		case BundleListItemKindCandidate:    return [NSURL URLWithString:_candidate.url];
		default:                             return _bundle.htmlURL;
	}
}

// The column means the same thing in every row: when the source last changed
// this bundle. A candidate has no answer — the date arrives with the archive,
// and nothing has been downloaded yet — and inventing one, or spending a REST
// request per row to look one up, would both be worse than saying so.
- (NSDate*)downloadLastUpdated
{
	switch(_kind)
	{
		// What the bundle came stamped with beats when we happened to fetch it
		case BundleListItemKindSubscription: return _subscription.updatedAt ?: _subscription.installedAt;
		case BundleListItemKindCandidate:    return nil;
		default:                             return _bundle.downloadLastUpdated;
	}
}

// Displayed instead of the date, so that “we have no date for this” reads as a
// deliberate answer rather than as a cell that failed to draw. Sorting still
// uses the date itself.
- (NSString*)updatedText
{
	static NSDateFormatter* formatter = ^{
		NSDateFormatter* res = [[NSDateFormatter alloc] init];
		res.dateStyle = NSDateFormatterMediumStyle;
		return res;
	}();

	NSDate* date = self.downloadLastUpdated;
	return date ? [formatter stringFromDate:date] : @"—";
}

- (BOOL)hasUpdatedDate
{
	return self.downloadLastUpdated != nil;
}

- (BOOL)isInstalled
{
	switch(_kind)
	{
		case BundleListItemKindSubscription: return YES;
		case BundleListItemKindCandidate:    return NO;
		default:                             return _bundle.isInstalled;
	}
}

- (NSString*)source
{
	switch(_kind)
	{
		case BundleListItemKindSubscription:
		{
			if(_subscription.isUnavailable)
				return @"Subscribed · unavailable";
			if(_subscription.isSourceChanged)
				return @"Subscribed · source changed";
			if(_subscription.hasUpdate)
				return @"Subscribed · update available";
			if(_subscription.replacesSigned)
				return @"Subscribed · replaces official";
			return _tapName ? [NSString stringWithFormat:@"Subscribed · %@", _tapName] : @"Subscribed";
		}
		case BundleListItemKindCandidate:
		{
			if(_installedFromAnotherTap)
				return @"Installed from another tap";
			return _tapName;
		}
		default:
			return _bundle.downloadURL ? @"Official" : @"Local";
	}
}

- (NSString*)detailText
{
	switch(_kind)
	{
		case BundleListItemKindSubscription:
		{
			NSMutableString* res = [NSMutableString stringWithFormat:@"%@ — %@", _subscription.name, _subscription.url];
			if(NSString* ref = _subscription.effectiveRef)
				[res appendFormat:@", following %@%@", ref, _subscription.refMode == BundleSubscriptionRefModeCatalogue ? @" (from the catalogue)" : @""];
			if(_subscription.installedSHA)
				[res appendFormat:@", installed %@", ShortSHA(_subscription.installedSHA)];
			if(_subscription.hasUpdate)
				[res appendFormat:@". Update available: %@", ShortSHA(_subscription.availableSHA)];
			if(_subscription.isOrphaned)
				[res appendString:@". No longer listed by its tap."];
			if(_subscription.isSourceChanged)
				[res appendString:@". Its tap now points at a different repository; uninstall and install the new source to switch."];
			if(_subscription.statusMessage)
				[res appendFormat:@". %@", _subscription.statusMessage];
			return res;
		}
		case BundleListItemKindCandidate:
		{
			if(_installedFromAnotherTap)
				return [NSString stringWithFormat:@"%@ is already installed from another subscription.", _candidate.name];
			if(self.requiresReplacingSignedBundle)
				return [NSString stringWithFormat:@"%@ replaces the official bundle of the same UUID. Signature verification is given up for it.", _candidate.name];
			return [NSString stringWithFormat:@"%@ — %@ (%@), offered by %@", _candidate.name, _candidate.url, _candidate.ref, _tapName];
		}
		default:
			return _bundle.textSummary ?: @"";
	}
}

- (BOOL)hasUpdate
{
	switch(_kind)
	{
		case BundleListItemKindSubscription: return _subscription.hasUpdate;
		case BundleListItemKindCandidate:    return NO;
		default:                             return _bundle.isInstalled && _bundle.hasUpdate && _bundle.isCompatible;
	}
}

- (BOOL)canUpdateAutomatically
{
	return _kind == BundleListItemKindSubscription;
}

- (BOOL)requiresReplacingSignedBundle
{
	if(_kind != BundleListItemKindCandidate || _installedFromAnotherTap)
		return NO;
	return [BundleSubscriptionManager.sharedInstance collisionKindForBundleIdentifier:_candidate.identifier existingName:nil] == BundleCollisionKindSigned;
}

- (BOOL)canChangeInstalledState
{
	switch(_kind)
	{
		case BundleListItemKindSubscription: return YES;
		case BundleListItemKindCandidate:    return !_installedFromAnotherTap;
		default:                             return !_bundle.isMandatory || !_bundle.isInstalled;
	}
}

- (BOOL)isEqual:(id)other
{
	if(![other isKindOfClass:[self class]])
		return NO;

	BundleListItem* item = other;
	if(_kind != item.kind)
		return NO;

	switch(_kind)
	{
		case BundleListItemKindSubscription: return [_subscription isEqual:item.subscription];
		case BundleListItemKindCandidate:    return [_candidate isEqual:item.candidate];
		default:                             return [_bundle isEqual:item.bundle];
	}
}

- (NSUInteger)hash
{
	switch(_kind)
	{
		case BundleListItemKindSubscription: return _subscription.hash;
		case BundleListItemKindCandidate:    return _candidate.hash;
		default:                             return _bundle.hash;
	}
}

- (NSString*)description { return [NSString stringWithFormat:@"<%@: %@ (%@)>", [self class], self.name, self.source]; }
@end
