#import <SoftwareUpdate/SoftwareUpdateRelease.h>
#import <ns/ns.h>

// The response GitHub gave for ‘repos/robios/textmate/releases/latest’ when
// v2.5.1 was the latest release, trimmed to the fields the parser reads plus a
// few of the ones around them. One line: bin/gen_test puts a #line directive
// before every line of a test file, raw string literals included.
static char const* const kLatestRelease = R"JSON({"url":"https://api.github.com/repos/robios/textmate/releases/391728368","assets_url":"https://api.github.com/repos/robios/textmate/releases/391728368/assets","html_url":"https://github.com/robios/textmate/releases/tag/v2.5.1","id":391728368,"node_id":"RE_kwDOTsDPTs4XWUzw","tag_name":"v2.5.1","target_commitish":"textmate-2.5","name":"TextMate 2.5.1","draft":false,"prerelease":false,"created_at":"2026-09-18T19:15:13Z","published_at":"2026-09-18T19:16:34Z","assets":[{"url":"https://api.github.com/repos/robios/textmate/releases/assets/573281928","id":573281928,"name":"TextMate-2.5.1.tar.gz","label":"","content_type":"application/x-gtar","state":"uploaded","size":19115531,"download_count":2,"created_at":"2026-09-18T19:16:33Z","updated_at":"2026-09-18T19:16:34Z","browser_download_url":"https://github.com/robios/textmate/releases/download/v2.5.1/TextMate-2.5.1.tar.gz"}],"tarball_url":"https://api.github.com/repos/robios/textmate/tarball/v2.5.1","zipball_url":"https://api.github.com/repos/robios/textmate/zipball/v2.5.1","body":"This patch release fixes the tab bar layout on macOS Tahoe.\n\n- Restore the compact tab bar height and vertically center tab titles.\n- For developers, allow AddressSanitizer to be disabled in Debug builds with `-DTEXTMATE_ENABLE_ASAN=OFF` to work around a startup deadlock on affected macOS/toolchain combinations. ASan remains enabled by default.\n\nRequires macOS 14 (Sonoma) or later. The attached application is signed with Developer ID and notarized by Apple.\n\n**Full changelog:** https://github.com/robios/textmate/compare/v2.5.0...v2.5.1\n"})JSON";

static NSData* FixtureData ()
{
	return [NSData dataWithBytes:kLatestRelease length:strlen(kLatestRelease)];
}

// The captured response with some top-level keys replaced (NSNull removes the key)
static NSData* ModifiedFixture (NSDictionary* changes)
{
	NSMutableDictionary* release = [[NSJSONSerialization JSONObjectWithData:FixtureData() options:NSJSONReadingMutableContainers error:nullptr] mutableCopy];
	[changes enumerateKeysAndObjectsUsingBlock:^(NSString* key, id value, BOOL*){
		if(value == NSNull.null)
				[release removeObjectForKey:key];
		else	release[key] = value;
	}];
	return [NSJSONSerialization dataWithJSONObject:release options:0 error:nullptr];
}

static NSDictionary* Asset (NSString* name, NSString* url = nil)
{
	return @{ @"name": name, @"size": @19115531, @"content_type": @"application/x-gtar", @"browser_download_url": url ?: [NSString stringWithFormat:@"https://github.com/robios/textmate/releases/download/v2.5.1/%@", name] };
}

static int ErrorCode (NSData* data, BOOL allowLoopback = NO)
{
	NSError* error;
	SoftwareUpdateRelease* release = ParseLatestRelease(data, allowLoopback, &error);
	OAK_ASSERT(!release);
	OAK_ASSERT_EQ(to_s(error.domain), to_s(SoftwareUpdateErrorDomain));
	return (int)error.code;
}

// ==========
// = Parser =
// ==========

void test_captured_release ()
{
	NSError* error;
	SoftwareUpdateRelease* release = ParseLatestRelease(FixtureData(), NO, &error);
	OAK_ASSERT(release);
	OAK_ASSERT(!error);
	OAK_ASSERT_EQ(to_s(release.version), "2.5.1");
	OAK_ASSERT_EQ(to_s(release.archiveURL.absoluteString), "https://github.com/robios/textmate/releases/download/v2.5.1/TextMate-2.5.1.tar.gz");
	OAK_ASSERT_EQ(release.archiveSize, 19115531LL);
	OAK_ASSERT_EQ(to_s(release.releaseNotesURL.absoluteString), "https://github.com/robios/textmate/releases/tag/v2.5.1");
}

void test_tag_without_v ()
{
	SoftwareUpdateRelease* release = ParseLatestRelease(ModifiedFixture(@{ @"tag_name": @"2.5.1" }), NO, nullptr);
	OAK_ASSERT(release);
	OAK_ASSERT_EQ(to_s(release.version), "2.5.1");
}

void test_only_one_v_is_stripped ()
{
	OAK_ASSERT_EQ(ErrorCode(ModifiedFixture(@{ @"tag_name": @"vv2.5.1" })), (int)SoftwareUpdateErrorMalformedResponse);
}

void test_four_component_tag ()
{
	SoftwareUpdateRelease* release = ParseLatestRelease(ModifiedFixture(@{ @"tag_name": @"v2.5.1.7", @"assets": @[ Asset(@"TextMate-2.5.1.7.tar.gz") ] }), NO, nullptr);
	OAK_ASSERT(release);
	OAK_ASSERT_EQ(to_s(release.version), "2.5.1.7");
}

void test_malformed_tags ()
{
	for(id tag in @[ @"v2", @"2", @"v2.5.1-beta", @"v2.5.", @"v.2.5", @"latest", @"", @" v2.5.1", @"v2.5.1\n", @42 ])
		OAK_ASSERT_EQ(ErrorCode(ModifiedFixture(@{ @"tag_name": tag })), (int)SoftwareUpdateErrorMalformedResponse);
	OAK_ASSERT_EQ(ErrorCode(ModifiedFixture(@{ @"tag_name": NSNull.null })), (int)SoftwareUpdateErrorMalformedResponse);
}

void test_not_json ()
{
	OAK_ASSERT_EQ(ErrorCode([@"<html>Not Found</html>" dataUsingEncoding:NSUTF8StringEncoding]), (int)SoftwareUpdateErrorMalformedResponse);
	OAK_ASSERT_EQ(ErrorCode([@"[1, 2, 3]" dataUsingEncoding:NSUTF8StringEncoding]), (int)SoftwareUpdateErrorMalformedResponse);
	OAK_ASSERT_EQ(ErrorCode([NSData data]), (int)SoftwareUpdateErrorMalformedResponse);
}

void test_draft_and_prerelease ()
{
	OAK_ASSERT_EQ(ErrorCode(ModifiedFixture(@{ @"draft": @YES })), (int)SoftwareUpdateErrorNoRelease);
	OAK_ASSERT_EQ(ErrorCode(ModifiedFixture(@{ @"prerelease": @YES })), (int)SoftwareUpdateErrorNoRelease);
	OAK_ASSERT(ParseLatestRelease(ModifiedFixture(@{ @"draft": NSNull.null, @"prerelease": NSNull.null }), NO, nullptr));
}

void test_no_assets ()
{
	NSError* error;
	OAK_ASSERT(!ParseLatestRelease(ModifiedFixture(@{ @"assets": @[ ] }), NO, &error));
	OAK_ASSERT_EQ((int)error.code, (int)SoftwareUpdateErrorNoDownloadableArchive);
	OAK_ASSERT_EQ(to_s(error.localizedDescription), "Release 2.5.1 has no downloadable archive");

	OAK_ASSERT_EQ(ErrorCode(ModifiedFixture(@{ @"assets": NSNull.null })), (int)SoftwareUpdateErrorNoDownloadableArchive);
}

void test_two_matching_assets ()
{
	OAK_ASSERT_EQ(ErrorCode(ModifiedFixture(@{ @"assets": @[ Asset(@"TextMate-2.5.1.tar.gz"), Asset(@"TextMate-2.5.1.tar.gz") ] })), (int)SoftwareUpdateErrorNoDownloadableArchive);
}

void test_misnamed_assets ()
{
	for(NSString* name in @[ @"TextMate-2.5.0.tar.gz", @"TextMate-2.5.1.tbz", @"TextMate-v2.5.1.tar.gz", @"textmate-2.5.1.tar.gz", @"TextMate-2.5.1.tar.gz.sig", @"TextMate.tar.gz" ])
		OAK_ASSERT_EQ(ErrorCode(ModifiedFixture(@{ @"assets": @[ Asset(name) ] })), (int)SoftwareUpdateErrorNoDownloadableArchive);
}

void test_one_match_among_other_assets ()
{
	SoftwareUpdateRelease* release = ParseLatestRelease(ModifiedFixture(@{ @"assets": @[ Asset(@"TextMate-2.5.1.tar.gz.sig"), Asset(@"TextMate-2.5.1.tar.gz"), Asset(@"Checksums.txt") ] }), NO, nullptr);
	OAK_ASSERT(release);
	OAK_ASSERT_EQ(to_s(release.archiveURL.lastPathComponent), "TextMate-2.5.1.tar.gz");
}

void test_archive_url_must_pass_the_transport_rule ()
{
	for(NSString* url in @[ @"http://example.com/TextMate-2.5.1.tar.gz", @"ftp://example.com/TextMate-2.5.1.tar.gz", @"file:///tmp/TextMate-2.5.1.tar.gz", @"http://127.0.0.1:8000/TextMate-2.5.1.tar.gz", @"not a url" ])
		OAK_ASSERT_EQ(ErrorCode(ModifiedFixture(@{ @"assets": @[ Asset(@"TextMate-2.5.1.tar.gz", url) ] })), (int)SoftwareUpdateErrorMalformedResponse);

	// Plaintext loopback only under the loopback exemption
	NSData* loopback = ModifiedFixture(@{ @"assets": @[ Asset(@"TextMate-2.5.1.tar.gz", @"http://127.0.0.1:8000/TextMate-2.5.1.tar.gz") ] });
	OAK_ASSERT(ParseLatestRelease(loopback, YES, nullptr));
	OAK_ASSERT_EQ(ErrorCode(ModifiedFixture(@{ @"assets": @[ Asset(@"TextMate-2.5.1.tar.gz", @"http://example.com/TextMate-2.5.1.tar.gz") ] }), YES), (int)SoftwareUpdateErrorMalformedResponse);
}

void test_missing_download_url_or_size ()
{
	OAK_ASSERT_EQ(ErrorCode(ModifiedFixture(@{ @"assets": @[ @{ @"name": @"TextMate-2.5.1.tar.gz", @"size": @1 } ] })), (int)SoftwareUpdateErrorMalformedResponse);
	OAK_ASSERT_EQ(ErrorCode(ModifiedFixture(@{ @"assets": @[ @{ @"name": @"TextMate-2.5.1.tar.gz", @"browser_download_url": @"https://github.com/robios/textmate/releases/download/v2.5.1/TextMate-2.5.1.tar.gz" } ] })), (int)SoftwareUpdateErrorMalformedResponse);
}

void test_missing_html_url ()
{
	OAK_ASSERT_EQ(ErrorCode(ModifiedFixture(@{ @"html_url": NSNull.null })), (int)SoftwareUpdateErrorMalformedResponse);
	OAK_ASSERT_EQ(ErrorCode(ModifiedFixture(@{ @"html_url": @17 })), (int)SoftwareUpdateErrorMalformedResponse);
}

// =====================
// = Rate-limit ladder =
// =====================

static NSTimeInterval Delay (NSInteger status, NSDictionary* headers, NSInteger strikes = 1)
{
	NSDate* now = [NSDate dateWithTimeIntervalSince1970:1790000000];
	NSDate* retry = RetryDateForRateLimitedResponse(status, headers, strikes, now);
	OAK_ASSERT(retry);
	return [retry timeIntervalSinceDate:now];
}

void test_retry_after ()
{
	OAK_ASSERT_EQ(Delay(403, @{ @"Retry-After": @"120" }), 120.0);
	OAK_ASSERT_EQ(Delay(429, @{ @"retry-after": @"120" }), 120.0);
	// Retry-After wins over the primary headers
	OAK_ASSERT_EQ(Delay(403, @{ @"Retry-After": @"120", @"X-RateLimit-Remaining": @"0", @"X-RateLimit-Reset": @"1790000600" }), 120.0);
}

void test_rate_limit_reset ()
{
	OAK_ASSERT_EQ(Delay(403, @{ @"X-RateLimit-Remaining": @"0", @"X-RateLimit-Reset": @"1790000600" }), 600.0);
	OAK_ASSERT_EQ(Delay(429, @{ @"x-ratelimit-remaining": @"0", @"x-ratelimit-reset": @"1790000600" }), 600.0);
	// Quota left: the reset is not a reason to wait, so the exponential rule applies
	OAK_ASSERT_EQ(Delay(403, @{ @"X-RateLimit-Remaining": @"12", @"X-RateLimit-Reset": @"1790000600" }), 60.0);
}

void test_far_reset_clamps_to_one_hour ()
{
	OAK_ASSERT_EQ(Delay(403, @{ @"X-RateLimit-Remaining": @"0", @"X-RateLimit-Reset": @"1790172800" }), 3600.0);
	OAK_ASSERT_EQ(Delay(429, @{ @"Retry-After": @"86400" }), 3600.0);
}

void test_bare_429_backs_off_exponentially ()
{
	NSTimeInterval const expected[] = { 60, 120, 240, 480, 960, 1920, 3600, 3600, 3600 };
	for(NSInteger strikes = 1; strikes <= 9; ++strikes)
		OAK_ASSERT_EQ(Delay(429, @{ }, strikes), expected[strikes-1]);
	OAK_ASSERT_EQ(Delay(429, nil, 1000), 3600.0);
}

void test_bare_403_backs_off_exponentially ()
{
	NSTimeInterval const expected[] = { 60, 120, 240, 480, 960, 1920, 3600, 3600, 3600 };
	for(NSInteger strikes = 1; strikes <= 9; ++strikes)
		OAK_ASSERT_EQ(Delay(403, @{ @"Content-Type": @"application/json" }, strikes), expected[strikes-1]);
}

void test_garbage_headers_fall_through_to_exponential ()
{
	for(NSString* value in @[ @"-5", @"soon", @"", @"12abc", @"1.5", @"Wed, 21 Oct 2026 07:28:00 GMT" ])
	{
		OAK_ASSERT_EQ(Delay(429, @{ @"Retry-After": value }, 2), 120.0);
		OAK_ASSERT_EQ(Delay(403, @{ @"X-RateLimit-Remaining": @"0", @"X-RateLimit-Reset": value }, 3), 240.0);
		OAK_ASSERT_EQ(Delay(403, @{ @"X-RateLimit-Remaining": value, @"X-RateLimit-Reset": @"1790000600" }, 1), 60.0);
	}
}

void test_other_statuses_are_not_rate_limits ()
{
	NSDate* now = NSDate.date;
	for(NSInteger status : { 200, 304, 404, 500, 503 })
		OAK_ASSERT(!RetryDateForRateLimitedResponse(status, @{ @"Retry-After": @"120" }, 1, now));
}

// =============
// = Transport =
// =============

static BOOL Allows (NSString* url, BOOL allowLoopback)
{
	return SoftwareUpdateTransportAllowsURL([NSURL URLWithString:url], allowLoopback);
}

void test_https_always_passes ()
{
	for(NSString* url in @[ @"https://api.github.com/repos/robios/textmate/releases/latest", @"https://release-assets.githubusercontent.com/x?sig=1", @"HTTPS://example.com/", @"https://127.0.0.1:8443/latest.json" ])
	{
		OAK_ASSERT(Allows(url, NO));
		OAK_ASSERT(Allows(url, YES));
	}
}

void test_plaintext_loopback_needs_the_exemption ()
{
	for(NSString* url in @[ @"http://127.0.0.1:8000", @"http://127.0.0.1:8000/TextMate-2.5.2.tar.gz", @"http://localhost", @"http://LOCALHOST:8000/latest.json", @"http://[::1]", @"http://[::1]:8000/latest.json" ])
	{
		OAK_ASSERT(Allows(url, YES));
		OAK_ASSERT(!Allows(url, NO));
	}
}

void test_everything_else_fails ()
{
	for(NSString* url in @[ @"http://192.168.1.5", @"http://github.com", @"http://127.0.0.2", @"http://localhost.example.com", @"http://127.0.0.1.nip.io", @"ftp://127.0.0.1/x", @"ftp://example.com/x", @"file:///tmp/x", @"file://localhost/tmp/x", @"data:,x" ])
	{
		OAK_ASSERT(!Allows(url, NO));
		OAK_ASSERT(!Allows(url, YES));
	}
	OAK_ASSERT(!SoftwareUpdateTransportAllowsURL(nil, YES));
}

void test_loopback_exemption_comes_only_from_a_loopback_override ()
{
	OAK_ASSERT(!SoftwareUpdateLoopbackExemptionForFeedURL(nil));
	OAK_ASSERT(!SoftwareUpdateLoopbackExemptionForFeedURL([NSURL URLWithString:@"https://api.github.com/repos/robios/textmate/releases/latest"]));
	OAK_ASSERT(!SoftwareUpdateLoopbackExemptionForFeedURL([NSURL URLWithString:@"http://192.168.1.5:8000/latest.json"]));
	OAK_ASSERT(!SoftwareUpdateLoopbackExemptionForFeedURL([NSURL URLWithString:@"http://localhost.example.com/latest.json"]));

	OAK_ASSERT(SoftwareUpdateLoopbackExemptionForFeedURL([NSURL URLWithString:@"http://127.0.0.1:8000/latest.json"]));
	OAK_ASSERT(SoftwareUpdateLoopbackExemptionForFeedURL([NSURL URLWithString:@"http://localhost:8000/latest.json"]));
	OAK_ASSERT(SoftwareUpdateLoopbackExemptionForFeedURL([NSURL URLWithString:@"http://[::1]:8000/latest.json"]));
}

// ====================
// = Version decision =
// ====================

static NSOperatingSystemVersion const kSonoma = { 14, 7, 0 };
static NSOperatingSystemVersion const kSequoia = { 15, 0, 0 };

void test_system_version_requirement ()
{
	OAK_ASSERT(!SoftwareUpdateSystemVersionSatisfies(@"15.0", kSonoma));
	OAK_ASSERT(!SoftwareUpdateSystemVersionSatisfies(@"14.7.1", kSonoma));
	OAK_ASSERT(SoftwareUpdateSystemVersionSatisfies(@"14", kSonoma));
	OAK_ASSERT(SoftwareUpdateSystemVersionSatisfies(@"14.0", kSonoma));
	OAK_ASSERT(SoftwareUpdateSystemVersionSatisfies(@"14.7", kSonoma));
	OAK_ASSERT(SoftwareUpdateSystemVersionSatisfies(@"14.7.0", kSonoma));
	OAK_ASSERT(SoftwareUpdateSystemVersionSatisfies(nil, kSonoma));
	OAK_ASSERT(SoftwareUpdateSystemVersionSatisfies(@"15.0", kSequoia));
	OAK_ASSERT(!SoftwareUpdateSystemVersionSatisfies(@"garbage", kSequoia));
}

void test_decision_table ()
{
	OAK_ASSERT_EQ((int)SoftwareUpdateDecide(@"2.5.1", @"2.5.2", YES, nil, nil, kSonoma).decision, (int)SoftwareUpdateDecisionOffer);
	OAK_ASSERT_EQ((int)SoftwareUpdateDecide(@"2.5.1", @"2.5.2", NO,  nil, nil, kSonoma).decision, (int)SoftwareUpdateDecisionOffer);
	OAK_ASSERT_EQ((int)SoftwareUpdateDecide(@"2.5.1", @"2.5.1", YES, nil, nil, kSonoma).decision, (int)SoftwareUpdateDecisionQuiet);
	OAK_ASSERT_EQ((int)SoftwareUpdateDecide(@"2.5.1", @"2.5.1", NO,  nil, nil, kSonoma).decision, (int)SoftwareUpdateDecisionUpToDate);

	// A build past the latest tag
	OAK_ASSERT_EQ((int)SoftwareUpdateDecide(@"2.5.1.7", @"2.5.1", YES, nil, nil, kSonoma).decision, (int)SoftwareUpdateDecisionQuiet);
	OAK_ASSERT_EQ((int)SoftwareUpdateDecide(@"2.5.1.7", @"2.5.1", NO,  nil, nil, kSonoma).decision, (int)SoftwareUpdateDecisionNewerThanRelease);
	OAK_ASSERT_EQ((int)SoftwareUpdateDecide(@"2.5.1.7", @"2.5.2", YES, nil, nil, kSonoma).decision, (int)SoftwareUpdateDecisionOffer);
}

void test_skipped_version ()
{
	// Background checks respect it, manual checks always show the release
	SoftwareUpdateDecisionResult background = SoftwareUpdateDecide(@"2.5.1", @"2.5.2", YES, @"2.5.2", nil, kSonoma);
	OAK_ASSERT_EQ((int)background.decision, (int)SoftwareUpdateDecisionQuiet);
	OAK_ASSERT(!background.clearSkippedVersion);
	OAK_ASSERT_EQ((int)SoftwareUpdateDecide(@"2.5.1", @"2.5.2", NO, @"2.5.2", nil, kSonoma).decision, (int)SoftwareUpdateDecisionOffer);

	// A newer release clears it and is offered
	SoftwareUpdateDecisionResult newer = SoftwareUpdateDecide(@"2.5.1", @"2.5.3", YES, @"2.5.2", nil, kSonoma);
	OAK_ASSERT_EQ((int)newer.decision, (int)SoftwareUpdateDecisionOffer);
	OAK_ASSERT(newer.clearSkippedVersion);
}

void test_unsupported_release ()
{
	NSDictionary* unsupported = @{ @"version": @"2.6.0", @"minimumSystemVersion": @"15.0" };

	SoftwareUpdateDecisionResult background = SoftwareUpdateDecide(@"2.5.1", @"2.6.0", YES, nil, unsupported, kSonoma);
	OAK_ASSERT_EQ((int)background.decision, (int)SoftwareUpdateDecisionQuiet);
	OAK_ASSERT(!background.clearUnsupportedRelease);

	SoftwareUpdateDecisionResult manual = SoftwareUpdateDecide(@"2.5.1", @"2.6.0", NO, nil, unsupported, kSonoma);
	OAK_ASSERT_EQ((int)manual.decision, (int)SoftwareUpdateDecisionRequiresNewerSystem);
	OAK_ASSERT(!manual.clearUnsupportedRelease);

	// The OS caught up
	SoftwareUpdateDecisionResult upgraded = SoftwareUpdateDecide(@"2.5.1", @"2.6.0", YES, nil, unsupported, kSequoia);
	OAK_ASSERT_EQ((int)upgraded.decision, (int)SoftwareUpdateDecisionOffer);
	OAK_ASSERT(upgraded.clearUnsupportedRelease);

	// A newer release appeared
	SoftwareUpdateDecisionResult newer = SoftwareUpdateDecide(@"2.5.1", @"2.6.1", YES, nil, unsupported, kSonoma);
	OAK_ASSERT_EQ((int)newer.decision, (int)SoftwareUpdateDecisionOffer);
	OAK_ASSERT(newer.clearUnsupportedRelease);
}
