#import "Bundle.h"
#import "BundlesManager.h"
#import "BundleSubscriptionManager.h"
#import <OakFoundation/OakCompareVersionStrings.h>
#import <ns/ns.h>
#import <text/decode.h>
#import <regexp/format_string.h>

@implementation Bundle
- (BOOL)isEqual:(id)other    { return [other isKindOfClass:[self class]] && [self.identifier isEqual:[other identifier]]; }
- (NSUInteger)hash           { return [self.identifier hash]; }
- (NSString*)description     { return [NSString stringWithFormat:@"<%@: %@ by %@%@>", [self class], _name, _contactName, _installed && _path ? [@", " stringByAppendingString:_path] : @""]; }

+ (NSSet*)keyPathsForValuesAffectingHasUpdate
{
	return [NSSet setWithObjects:@"downloadLastUpdated", @"lastUpdated", @"builtIn", nil];
}

+ (NSSet*)keyPathsForValuesAffectingInstalled
{
	return [NSSet setWithObject:@"builtIn"];
}

+ (NSSet*)keyPathsForValuesAffectingCompatible
{
	return [NSSet setWithObjects:@"minimumAppVersion", nil];
}

+ (NSSet*)keyPathsForValuesAffectingTextSummary
{
	return [NSSet setWithObjects:@"summary", nil];
}

- (instancetype)initWithIdentifier:(NSUUID*)anIdentifier
{
	if(self = [self init])
	{
		_identifier = anIdentifier;
	}
	return self;
}

- (NSString*)textSummary
{
	std::string str = to_s(self.summary);
	str = format_string::replace(str, "\\A\\s+|<[^>]*>|\\s+\\z", "");
	str = format_string::replace(str, "\\s+", " ");
	str = decode::entities(str);
	return to_ns(str);
}

// A built-in bundle is installed by virtue of being inside the app: its Managed
// copy may be absent, stale, or on its way out, and none of that says anything
// about whether the bundle is available.
- (BOOL)isInstalled
{
	return _builtIn || _installed;
}

- (BOOL)hasUpdate
{
	// The Managed copy’s dates describe a copy that is eclipsed and never
	// loaded, so an update to it is not an update to what is running.
	if(_builtIn)
		return NO;
	return _downloadLastUpdated && _lastUpdated && [_downloadLastUpdated laterDate:_lastUpdated] != _lastUpdated;
}

- (BOOL)isCompatible
{
	NSString* appVersion = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
	return OakCompareVersionStrings(appVersion, _minimumAppVersion) != NSOrderedAscending;
}
@end

@implementation BundleGrammar
- (id)source
{
	return _bundle ?: (id)_candidate;
}

- (NSString*)sourceName
{
	return _bundle ? _bundle.name : _candidate.name;
}

- (BOOL)isInstalled
{
	if(_bundle)
		return _bundle.isInstalled;
	return _candidate && [BundleSubscriptionManager.sharedInstance subscriptionWithIdentifier:_candidate.identifier] != nil;
}

- (NSString*)description
{
	return [NSString stringWithFormat:@"<%@: %@ (%@)>", [self class], self.name, self.fileType];
}
@end
