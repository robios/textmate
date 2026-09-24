#ifndef SOFTWARE_UPDATE_RELEASE_H_Q8TR2WXN
#define SOFTWARE_UPDATE_RELEASE_H_Q8TR2WXN

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSErrorDomain const SoftwareUpdateErrorDomain;

// Callers tell apart the failures a background check keeps quiet about (a
// release still being uploaded, rate limiting) by code, never by message.
typedef NS_ERROR_ENUM(SoftwareUpdateErrorDomain, SoftwareUpdateErrorCode)
{
	SoftwareUpdateErrorMalformedResponse = 1,
	SoftwareUpdateErrorNoRelease,                // Draft or prerelease
	SoftwareUpdateErrorNoDownloadableArchive,    // Zero or several ‘TextMate-<version>.tar.gz’ assets
	SoftwareUpdateErrorRateLimited,              // A 403 or 429 from the feed
	SoftwareUpdateErrorVerificationFailed,       // The extracted bundle failed layout, version, signature, or downgrade checks
	SoftwareUpdateErrorRequiresNewerSystem,      // The extracted bundle’s LSMinimumSystemVersion is above this Mac’s
	SoftwareUpdateErrorCannotInstall,            // Read-only volume, translocated, or unwritable parent directory
	SoftwareUpdateErrorCannotSaveSession,
	SoftwareUpdateErrorUnavailable,              // Not a distribution-signed build
	SoftwareUpdateErrorInternal,
};

// userInfo keys of a SoftwareUpdateErrorRequiresNewerSystem error
extern NSString* const SoftwareUpdateVersionErrorKey;               // @"version"
extern NSString* const SoftwareUpdateMinimumSystemVersionErrorKey;  // @"minimumSystemVersion"

@interface SoftwareUpdateRelease : NSObject
- (instancetype)initWithVersion:(NSString*)version archiveURL:(NSURL*)archiveURL archiveSize:(long long)archiveSize releaseNotesURL:(NSURL*)releaseNotesURL;
@property (nonatomic, readonly) NSString* version;         // ‘tag_name’ without its leading ‘v’
@property (nonatomic, readonly) NSURL*    archiveURL;      // ‘browser_download_url’ of ‘TextMate-<version>.tar.gz’
@property (nonatomic, readonly) long long archiveSize;
@property (nonatomic, readonly) NSURL*    releaseNotesURL; // ‘html_url’
@end

// Parses a GitHub ‘releases/latest’ response. allowLoopback is passed on to
// SoftwareUpdateTransportAllowsURL() for the archive URL.
SoftwareUpdateRelease* _Nullable ParseLatestRelease (NSData* json, BOOL allowLoopback, NSError** error);

// For a 403 or 429 from the feed, the earliest time it may be contacted again:
// now + ‘Retry-After’ seconds, else the ‘X-RateLimit-Reset’ epoch when
// ‘X-RateLimit-Remaining’ is 0, else 60 s × 2^(strikes − 1). Malformed or
// negative header values fall through to the exponential rule. The result is
// never more than an hour after now. strikes counts consecutive rate-limited
// responses including this one. Header names are matched case-insensitively.
// Any other status gives nil.
NSDate* _Nullable RetryDateForRateLimitedResponse (NSInteger status, NSDictionary* _Nullable headers, NSInteger strikes, NSDate* now);

// The rule for every URL the updater fetches, initial or redirect target:
// https always; plaintext http only to localhost, 127.0.0.1, or ::1, and only
// when allowLoopback is set.
BOOL SoftwareUpdateTransportAllowsURL (NSURL* _Nullable url, BOOL allowLoopback);
// allowLoopback is YES only while the feed URL override itself points at a
// loopback host, so a local test server can serve both feed and archive.
BOOL SoftwareUpdateLoopbackExemptionForFeedURL (NSURL* _Nullable overrideURL);

// YES when running is at least minimumSystemVersion (e.g. ‘14’, ‘14.0’,
// ‘15.0.1’). A nil or empty minimum means no requirement; an unparsable one is
// treated as not satisfied.
BOOL SoftwareUpdateSystemVersionSatisfies (NSString* _Nullable minimumSystemVersion, NSOperatingSystemVersion running);

// What a check does with the release it fetched. Suspension (‘Later’) and rate
// limiting are handled before anything is fetched, so they are not inputs here.
typedef NS_ENUM(NSInteger, SoftwareUpdateDecision)
{
	SoftwareUpdateDecisionQuiet,                // Background check: nothing to say
	SoftwareUpdateDecisionOffer,                // New Version Available
	SoftwareUpdateDecisionRequiresNewerSystem,  // Manual check of the recorded unsupported release
	SoftwareUpdateDecisionUpToDate,
	SoftwareUpdateDecisionNewerThanRelease,
};

struct SoftwareUpdateDecisionResult
{
	SoftwareUpdateDecision decision;
	BOOL clearSkippedVersion;       // The release is newer than the skipped version
	BOOL clearUnsupportedRelease;   // Newer than the unsupported release, or this Mac now satisfies it
};

// unsupportedRelease is the recorded { version, minimumSystemVersion } of a
// verified release this Mac could not run.
SoftwareUpdateDecisionResult SoftwareUpdateDecide (NSString* localVersion, NSString* remoteVersion, BOOL backgroundCheck, NSString* _Nullable skippedVersion, NSDictionary* _Nullable unsupportedRelease, NSOperatingSystemVersion running);

NS_ASSUME_NONNULL_END

#endif /* end of include guard: SOFTWARE_UPDATE_RELEASE_H_Q8TR2WXN */
