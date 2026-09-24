#import "SoftwareUpdateRelease.h"
#import <OakFoundation/OakCompareVersionStrings.h>

NSErrorDomain const SoftwareUpdateErrorDomain                 = @"com.macromates.TextMate.SoftwareUpdate";
NSString* const SoftwareUpdateVersionErrorKey              = @"version";
NSString* const SoftwareUpdateMinimumSystemVersionErrorKey = @"minimumSystemVersion";

@implementation SoftwareUpdateRelease
- (instancetype)initWithVersion:(NSString*)version archiveURL:(NSURL*)archiveURL archiveSize:(long long)archiveSize releaseNotesURL:(NSURL*)releaseNotesURL
{
	if(self = [super init])
	{
		_version         = version;
		_archiveURL      = archiveURL;
		_archiveSize     = archiveSize;
		_releaseNotesURL = releaseNotesURL;
	}
	return self;
}

- (NSString*)description
{
	return [NSString stringWithFormat:@"<%@: %@, %@ (%lld bytes)>", self.class, _version, _archiveURL, _archiveSize];
}
@end

static BOOL SetError (NSError** error, SoftwareUpdateErrorCode code, NSString* description)
{
	if(error)
		*error = [NSError errorWithDomain:SoftwareUpdateErrorDomain code:code userInfo:@{ NSLocalizedDescriptionKey: description }];
	return NO;
}

static BOOL IsVersionString (NSString* str)
{
	static NSRegularExpression* const regexp = [NSRegularExpression regularExpressionWithPattern:@"\\A[0-9]+\\.[0-9]+(\\.[0-9]+)*\\z" options:0 error:nullptr];
	return [regexp numberOfMatchesInString:str options:0 range:NSMakeRange(0, str.length)] == 1;
}

template <typename T> static T* As (id obj)
{
	return [obj isKindOfClass:[T class]] ? (T*)obj : nil;
}

SoftwareUpdateRelease* ParseLatestRelease (NSData* json, BOOL allowLoopback, NSError** error)
{
	NSString* const malformed = @"Malformed server response.";

	NSDictionary* release = As<NSDictionary>(json ? [NSJSONSerialization JSONObjectWithData:json options:0 error:nullptr] : nil);
	if(!release)
		return SetError(error, SoftwareUpdateErrorMalformedResponse, malformed), nil;

	NSString* version = As<NSString>(release[@"tag_name"]);
	if([version hasPrefix:@"v"])
		version = [version substringFromIndex:1];
	if(!version || !IsVersionString(version))
		return SetError(error, SoftwareUpdateErrorMalformedResponse, malformed), nil;

	if([As<NSNumber>(release[@"draft"]) boolValue] || [As<NSNumber>(release[@"prerelease"]) boolValue])
		return SetError(error, SoftwareUpdateErrorNoRelease, [NSString stringWithFormat:@"Release %@ is not published.", version]), nil;

	NSString* archiveName = [NSString stringWithFormat:@"TextMate-%@.tar.gz", version];
	NSMutableArray<NSDictionary*>* matches = [NSMutableArray array];
	for(id asset in As<NSArray>(release[@"assets"]))
	{
		if([As<NSString>(As<NSDictionary>(asset)[@"name"]) isEqualToString:archiveName])
			[matches addObject:asset];
	}

	if(matches.count != 1)
		return SetError(error, SoftwareUpdateErrorNoDownloadableArchive, [NSString stringWithFormat:@"Release %@ has no downloadable archive", version]), nil;

	NSString* archiveString = As<NSString>(matches.firstObject[@"browser_download_url"]);
	NSURL* archiveURL       = archiveString ? [NSURL URLWithString:archiveString] : nil;
	NSNumber* archiveSize   = As<NSNumber>(matches.firstObject[@"size"]);
	if(!SoftwareUpdateTransportAllowsURL(archiveURL, allowLoopback) || !archiveSize)
		return SetError(error, SoftwareUpdateErrorMalformedResponse, malformed), nil;

	NSString* notesString = As<NSString>(release[@"html_url"]);
	NSURL* releaseNotesURL = notesString ? [NSURL URLWithString:notesString] : nil;
	if(!releaseNotesURL)
		return SetError(error, SoftwareUpdateErrorMalformedResponse, malformed), nil;

	return [[SoftwareUpdateRelease alloc] initWithVersion:version archiveURL:archiveURL archiveSize:archiveSize.longLongValue releaseNotesURL:releaseNotesURL];
}

// ===============
// = Rate limits =
// ===============

static NSString* HeaderValue (NSDictionary* headers, NSString* name)
{
	for(id key in headers)
	{
		if([key isKindOfClass:[NSString class]] && [key caseInsensitiveCompare:name] == NSOrderedSame)
		{
			id value = headers[key];
			return [value isKindOfClass:[NSString class]] ? value : ([value respondsToSelector:@selector(stringValue)] ? [value stringValue] : nil);
		}
	}
	return nil;
}

// A non-negative integer and nothing else, or NO
static BOOL ParseCount (NSString* str, long long* out)
{
	NSString* trimmed = [str stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
	if(trimmed.length == 0 || [trimmed rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"0123456789"].invertedSet].location != NSNotFound)
		return NO;

	NSScanner* scanner = [NSScanner scannerWithString:trimmed];
	return [scanner scanLongLong:out] && scanner.isAtEnd && *out >= 0;
}

NSDate* RetryDateForRateLimitedResponse (NSInteger status, NSDictionary* headers, NSInteger strikes, NSDate* now)
{
	if(status != 403 && status != 429)
		return nil;

	NSTimeInterval const maximumDelay = 60*60;
	NSDate* res;

	long long value, remaining;
	if(ParseCount(HeaderValue(headers, @"Retry-After"), &value))
		res = [now dateByAddingTimeInterval:MIN((NSTimeInterval)value, maximumDelay)];
	else if(ParseCount(HeaderValue(headers, @"X-RateLimit-Remaining"), &remaining) && remaining == 0 && ParseCount(HeaderValue(headers, @"X-RateLimit-Reset"), &value))
		res = [NSDate dateWithTimeIntervalSince1970:value];
	else
		res = [now dateByAddingTimeInterval:60 * pow(2, MIN(MAX(strikes, 1) - 1, 16))];

	return [res earlierDate:[now dateByAddingTimeInterval:maximumDelay]];
}

// =============
// = Transport =
// =============

static BOOL IsLoopbackHost (NSString* host)
{
	for(NSString* loopback in @[ @"localhost", @"127.0.0.1", @"::1", @"[::1]" ])
	{
		if([host caseInsensitiveCompare:loopback] == NSOrderedSame)
			return YES;
	}
	return NO;
}

BOOL SoftwareUpdateTransportAllowsURL (NSURL* url, BOOL allowLoopback)
{
	NSString* scheme = url.scheme.lowercaseString;
	if([scheme isEqualToString:@"https"])
		return url.host.length != 0;
	if([scheme isEqualToString:@"http"])
		return allowLoopback && IsLoopbackHost(url.host);
	return NO;
}

BOOL SoftwareUpdateLoopbackExemptionForFeedURL (NSURL* overrideURL)
{
	return overrideURL && IsLoopbackHost(overrideURL.host);
}

// ====================
// = Version decision =
// ====================

BOOL SoftwareUpdateSystemVersionSatisfies (NSString* minimumSystemVersion, NSOperatingSystemVersion running)
{
	if(minimumSystemVersion.length == 0)
		return YES;
	if(!IsVersionString(minimumSystemVersion) && ![minimumSystemVersion rangeOfString:@"^[0-9]+$" options:NSRegularExpressionSearch].length)
		return NO;

	NSArray<NSString*>* components = [minimumSystemVersion componentsSeparatedByString:@"."];
	NSInteger const actual[] = { running.majorVersion, running.minorVersion, running.patchVersion };
	for(NSUInteger i = 0; i < components.count; ++i)
	{
		NSInteger required = components[i].integerValue;
		NSInteger have     = i < 3 ? actual[i] : 0;
		if(have != required)
			return have > required;
	}
	return YES;
}

SoftwareUpdateDecisionResult SoftwareUpdateDecide (NSString* localVersion, NSString* remoteVersion, BOOL backgroundCheck, NSString* skippedVersion, NSDictionary* unsupportedRelease, NSOperatingSystemVersion running)
{
	SoftwareUpdateDecisionResult res = { SoftwareUpdateDecisionQuiet, NO, NO };

	res.clearSkippedVersion = skippedVersion && OakCompareVersionStrings(skippedVersion, remoteVersion) == NSOrderedAscending;

	BOOL unsupported = NO;
	if(unsupportedRelease)
	{
		NSString* version = As<NSString>(unsupportedRelease[SoftwareUpdateVersionErrorKey]);
		NSString* minimum = As<NSString>(unsupportedRelease[SoftwareUpdateMinimumSystemVersionErrorKey]);
		if(!version || OakCompareVersionStrings(version, remoteVersion) == NSOrderedAscending || SoftwareUpdateSystemVersionSatisfies(minimum, running))
			res.clearUnsupportedRelease = YES;
		else if(OakCompareVersionStrings(version, remoteVersion) == NSOrderedSame)
			unsupported = YES;
	}

	switch(OakCompareVersionStrings(localVersion, remoteVersion))
	{
		case NSOrderedAscending:
		{
			if(backgroundCheck)
			{
				BOOL skipped = skippedVersion && !res.clearSkippedVersion && OakCompareVersionStrings(skippedVersion, remoteVersion) == NSOrderedSame;
				res.decision = skipped || unsupported ? SoftwareUpdateDecisionQuiet : SoftwareUpdateDecisionOffer;
			}
			else
			{
				res.decision = unsupported ? SoftwareUpdateDecisionRequiresNewerSystem : SoftwareUpdateDecisionOffer;
			}
		}
		break;

		case NSOrderedSame:       res.decision = backgroundCheck ? SoftwareUpdateDecisionQuiet : SoftwareUpdateDecisionUpToDate;         break;
		case NSOrderedDescending: res.decision = backgroundCheck ? SoftwareUpdateDecisionQuiet : SoftwareUpdateDecisionNewerThanRelease; break;
	}

	return res;
}
