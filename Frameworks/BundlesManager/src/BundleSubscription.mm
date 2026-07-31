#import "BundleSubscription.h"

static NSInteger const kSubscriptionsSchemaVersion = 1;

static NSString* const kKeySchemaVersion = @"schemaVersion";
static NSString* const kKeyTaps          = @"taps";
static NSString* const kKeyBundles       = @"bundles";

// Keys we know about are read into properties; everything else is carried
// through untouched when the record is written back.
static NSDictionary* UnknownKeys (NSDictionary* plist, NSArray<NSString*>* knownKeys)
{
	NSMutableDictionary* res = [plist mutableCopy];
	[res removeObjectsForKeys:knownKeys];
	return res.count ? res : nil;
}

static NSString* NonEmptyString (id value)
{
	return [value isKindOfClass:[NSString class]] && [value length] ? value : nil;
}

@implementation BundleTap
{
	NSDictionary* _unknownKeys;
}

+ (NSArray<NSString*>*)knownKeys
{
	return @[ @"id", @"url", @"trackingRef", @"name", @"catalogueSHA", @"fetchedAt", @"autoUpdate" ];
}

- (instancetype)initWithIdentifier:(NSString*)identifier url:(NSString*)url trackingRef:(NSString*)trackingRef
{
	if(self = [super init])
	{
		_identifier  = identifier;
		_url         = url;
		_trackingRef = trackingRef;
	}
	return self;
}

- (instancetype)initWithPlistRepresentation:(NSDictionary*)plist
{
	NSString* identifier = NonEmptyString(plist[@"id"]);
	NSString* url        = NonEmptyString(plist[@"url"]);
	if(!identifier || !url)
		return nil;

	if(self = [self initWithIdentifier:identifier url:url trackingRef:NonEmptyString(plist[@"trackingRef"])])
	{
		_name         = NonEmptyString(plist[@"name"]);
		_catalogueSHA = NonEmptyString(plist[@"catalogueSHA"]);
		_fetchedAt    = [plist[@"fetchedAt"] isKindOfClass:[NSDate class]] ? plist[@"fetchedAt"] : nil;
		_autoUpdate   = [plist[@"autoUpdate"] boolValue];
		_unknownKeys  = UnknownKeys(plist, [[self class] knownKeys]);
	}
	return self;
}

- (NSDictionary*)plistRepresentation
{
	NSMutableDictionary* res = [_unknownKeys mutableCopy] ?: [NSMutableDictionary dictionary];

	res[@"id"]  = _identifier;
	res[@"url"] = _url;
	if(_trackingRef)
		res[@"trackingRef"] = _trackingRef;
	if(_name)
		res[@"name"] = _name;
	if(_catalogueSHA)
		res[@"catalogueSHA"] = _catalogueSHA;
	if(_fetchedAt)
		res[@"fetchedAt"] = _fetchedAt;
	res[@"autoUpdate"] = @(_autoUpdate);

	return res;
}

- (BOOL)isEqual:(id)other { return [other isKindOfClass:[self class]] && [_identifier isEqualToString:[other identifier]]; }
- (NSUInteger)hash        { return _identifier.hash; }
- (NSString*)description  { return [NSString stringWithFormat:@"<%@: %@ (%@)>", [self class], _name ?: _url, _trackingRef ?: @"HEAD"]; }
@end

@implementation BundleSubscription
{
	NSDictionary* _unknownKeys;
}

+ (NSArray<NSString*>*)knownKeys
{
	return @[ @"uuid", @"name", @"url", @"refMode", @"catalogueRef", @"trackingRef", @"tap", @"originTapName", @"category", @"description", @"autoUpdate", @"installedSHA", @"availableSHA", @"installedAt", @"updated", @"replacesSigned", @"path" ];
}

+ (NSSet*)keyPathsForValuesAffectingHasUpdate
{
	return [NSSet setWithObjects:@"installedSHA", @"availableSHA", nil];
}

+ (NSSet*)keyPathsForValuesAffectingEffectiveRef
{
	return [NSSet setWithObjects:@"refMode", @"catalogueRef", @"trackingRef", nil];
}

- (instancetype)initWithIdentifier:(NSUUID*)identifier url:(NSString*)url
{
	if(self = [super init])
	{
		_identifier = identifier;
		_url        = url;
		_refMode    = BundleSubscriptionRefModeUser;
	}
	return self;
}

- (instancetype)initWithPlistRepresentation:(NSDictionary*)plist
{
	NSUUID* identifier = [plist[@"uuid"] isKindOfClass:[NSString class]] ? [[NSUUID alloc] initWithUUIDString:plist[@"uuid"]] : nil;
	NSString* url      = NonEmptyString(plist[@"url"]);
	if(!identifier || !url)
		return nil;

	if(self = [self initWithIdentifier:identifier url:url])
	{
		_refMode        = [NonEmptyString(plist[@"refMode"]) isEqualToString:@"catalogue"] ? BundleSubscriptionRefModeCatalogue : BundleSubscriptionRefModeUser;
		_name           = NonEmptyString(plist[@"name"]);
		_catalogueRef   = NonEmptyString(plist[@"catalogueRef"]);
		_trackingRef    = NonEmptyString(plist[@"trackingRef"]);
		_tapIdentifier  = NonEmptyString(plist[@"tap"]);
		_originTapName  = NonEmptyString(plist[@"originTapName"]);
		_category       = NonEmptyString(plist[@"category"]);
		_summary        = NonEmptyString(plist[@"description"]);
		_autoUpdate     = [plist[@"autoUpdate"] boolValue];
		_installedSHA   = NonEmptyString(plist[@"installedSHA"]);
		_availableSHA   = NonEmptyString(plist[@"availableSHA"]);
		_installedAt    = [plist[@"installedAt"] isKindOfClass:[NSDate class]] ? plist[@"installedAt"] : nil;
		_updatedAt      = [plist[@"updated"] isKindOfClass:[NSDate class]] ? plist[@"updated"] : nil;
		_replacesSigned = [plist[@"replacesSigned"] boolValue];
		_relativePath   = NonEmptyString(plist[@"path"]);
		_unknownKeys    = UnknownKeys(plist, [[self class] knownKeys]);
	}
	return self;
}

- (NSDictionary*)plistRepresentation
{
	NSMutableDictionary* res = [_unknownKeys mutableCopy] ?: [NSMutableDictionary dictionary];

	res[@"uuid"]    = _identifier.UUIDString;
	res[@"url"]     = _url;
	res[@"refMode"] = _refMode == BundleSubscriptionRefModeCatalogue ? @"catalogue" : @"user";

	if(_name)
		res[@"name"] = _name;
	if(_catalogueRef)
		res[@"catalogueRef"] = _catalogueRef;
	if(_trackingRef)
		res[@"trackingRef"] = _trackingRef;
	if(_tapIdentifier)
		res[@"tap"] = _tapIdentifier;
	if(_originTapName)
		res[@"originTapName"] = _originTapName;
	if(_category)
		res[@"category"] = _category;
	if(_summary)
		res[@"description"] = _summary;
	if(_installedSHA)
		res[@"installedSHA"] = _installedSHA;
	if(_availableSHA)
		res[@"availableSHA"] = _availableSHA;
	if(_installedAt)
		res[@"installedAt"] = _installedAt;
	if(_updatedAt)
		res[@"updated"] = _updatedAt;
	if(_relativePath)
		res[@"path"] = _relativePath;

	res[@"autoUpdate"] = @(_autoUpdate);
	if(_replacesSigned)
		res[@"replacesSigned"] = @YES;

	return res;
}

- (NSString*)effectiveRef
{
	return _refMode == BundleSubscriptionRefModeCatalogue ? _catalogueRef : _trackingRef;
}

- (BOOL)hasUpdate
{
	return _availableSHA && _installedSHA && ![_availableSHA isEqualToString:_installedSHA];
}

- (BOOL)isEqual:(id)other { return [other isKindOfClass:[self class]] && [_identifier isEqual:[other identifier]]; }
- (NSUInteger)hash        { return _identifier.hash; }
- (NSString*)description  { return [NSString stringWithFormat:@"<%@: %@ %@@%@>", [self class], _name, _url, self.effectiveRef ?: @"HEAD"]; }
@end

@implementation BundleSubscriptionRegistry
{
	NSMutableArray<BundleTap*>*          _taps;
	NSMutableArray<BundleSubscription*>* _subscriptions;
	NSDictionary*                        _unknownKeys;
	NSInteger                            _schemaVersion;
}

- (instancetype)initWithFileURL:(NSURL*)fileURL
{
	if(self = [super init])
	{
		_fileURL       = fileURL;
		_taps          = [NSMutableArray array];
		_subscriptions = [NSMutableArray array];
		_schemaVersion = kSubscriptionsSchemaVersion;
	}
	return self;
}

- (NSArray<BundleTap*>*)taps                   { return [_taps copy]; }
- (NSArray<BundleSubscription*>*)subscriptions { return [_subscriptions copy]; }

- (BOOL)load:(NSError**)error
{
	[_taps removeAllObjects];
	[_subscriptions removeAllObjects];
	_unknownKeys   = nil;
	_schemaVersion = kSubscriptionsSchemaVersion;
	_readOnly      = NO;
	_readOnlyReason = nil;

	if(![NSFileManager.defaultManager fileExistsAtPath:_fileURL.path])
		return YES;

	NSDictionary* plist = [NSDictionary dictionaryWithContentsOfURL:_fileURL error:error];
	if(!plist)
	{
		// A file that is there but cannot be read says nothing about what the
		// user has, and an empty registry would say they have nothing: the first
		// later mutation would write that over their taps and subscriptions, and
		// startup recovery would read it as an uninstall that had committed.
		// Read-only for the same reason a newer schema is — we do not know what
		// this file holds, so we do not get to replace it.
		_readOnly       = YES;
		_readOnlyReason = [NSString stringWithFormat:@"%@ could not be read. Subscriptions cannot be changed until it is repaired or removed.", _fileURL.lastPathComponent];
		os_log_error(OS_LOG_DEFAULT, "Unreadable subscriptions at %{public}@: loaded read-only", _fileURL.path);
		return NO;
	}

	if(NSNumber* version = [plist[kKeySchemaVersion] isKindOfClass:[NSNumber class]] ? plist[kKeySchemaVersion] : nil)
	{
		_schemaVersion = version.integerValue;
		if(_schemaVersion > kSubscriptionsSchemaVersion)
		{
			_readOnly       = YES;
			_readOnlyReason = [NSString stringWithFormat:@"%@ was written by a newer version of TextMate (schema %ld). Subscriptions are shown but cannot be changed by this version.", _fileURL.lastPathComponent, (long)_schemaVersion];
			os_log_error(OS_LOG_DEFAULT, "Subscriptions written by a newer version (schema %ld): loaded read-only", (long)_schemaVersion);
		}
	}

	for(id item in [plist[kKeyTaps] isKindOfClass:[NSArray class]] ? plist[kKeyTaps] : @[])
	{
		if(![item isKindOfClass:[NSDictionary class]])
			continue;

		// A malformed record is dropped on its own; taking the file with it would
		// lose every other subscription the user has.
		if(BundleTap* tap = [[BundleTap alloc] initWithPlistRepresentation:item])
				[_taps addObject:tap];
		else	os_log_error(OS_LOG_DEFAULT, "Dropping malformed tap record: %{public}@", item);
	}

	for(id item in [plist[kKeyBundles] isKindOfClass:[NSArray class]] ? plist[kKeyBundles] : @[])
	{
		if(![item isKindOfClass:[NSDictionary class]])
			continue;

		if(BundleSubscription* subscription = [[BundleSubscription alloc] initWithPlistRepresentation:item])
				[_subscriptions addObject:subscription];
		else	os_log_error(OS_LOG_DEFAULT, "Dropping malformed subscription record: %{public}@", item);
	}

	_unknownKeys = UnknownKeys(plist, @[ kKeySchemaVersion, kKeyTaps, kKeyBundles ]);

	return YES;
}

- (BOOL)save:(NSError**)error
{
	if(_readOnly)
	{
		if(error)
			*error = [NSError errorWithDomain:@"BundleSubscription" code:0 userInfo:@{ NSLocalizedDescriptionKey: _readOnlyReason ?: @"Refusing to overwrite subscriptions this version did not read." }];
		return NO;
	}

	NSMutableDictionary* plist = [_unknownKeys mutableCopy] ?: [NSMutableDictionary dictionary];
	plist[kKeySchemaVersion] = @(kSubscriptionsSchemaVersion);

	NSMutableArray* taps = [NSMutableArray array];
	for(BundleTap* tap in _taps)
		[taps addObject:tap.plistRepresentation];
	plist[kKeyTaps] = taps;

	NSMutableArray* subscriptions = [NSMutableArray array];
	for(BundleSubscription* subscription in _subscriptions)
		[subscriptions addObject:subscription.plistRepresentation];
	plist[kKeyBundles] = subscriptions;

	NSURL* directory = _fileURL.URLByDeletingLastPathComponent;
	if(![NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:error])
		return NO;

	NSData* data = [NSPropertyListSerialization dataWithPropertyList:plist format:NSPropertyListXMLFormat_v1_0 options:0 error:error];
	if(!data)
		return NO;

	// Every caller treats this write as its commit point, so it has to be atomic
	return [data writeToURL:_fileURL options:NSDataWritingAtomic error:error];
}

- (BundleTap*)tapWithIdentifier:(NSString*)identifier
{
	for(BundleTap* tap in _taps)
	{
		if([tap.identifier isEqualToString:identifier])
			return tap;
	}
	return nil;
}

- (BundleSubscription*)subscriptionWithIdentifier:(NSUUID*)identifier
{
	for(BundleSubscription* subscription in _subscriptions)
	{
		if([subscription.identifier isEqual:identifier])
			return subscription;
	}
	return nil;
}

- (NSArray<BundleSubscription*>*)subscriptionsForTapWithIdentifier:(NSString*)identifier
{
	NSMutableArray* res = [NSMutableArray array];
	for(BundleSubscription* subscription in _subscriptions)
	{
		if(subscription.tapIdentifier && [subscription.tapIdentifier isEqualToString:identifier])
			[res addObject:subscription];
	}
	return res;
}

- (void)addTap:(BundleTap*)tap                                { [_taps addObject:tap]; }
- (void)removeTap:(BundleTap*)tap                             { [_taps removeObject:tap]; }
- (void)addSubscription:(BundleSubscription*)subscription     { [_subscriptions addObject:subscription]; }
- (void)removeSubscription:(BundleSubscription*)subscription  { [_subscriptions removeObject:subscription]; }
@end
