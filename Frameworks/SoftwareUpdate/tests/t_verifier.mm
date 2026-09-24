#import <SoftwareUpdate/SoftwareUpdateVerifier.h>
#import <SoftwareUpdate/SoftwareUpdateRelease.h>
#import <ns/ns.h>

// System apps seal no resources (the signed system volume covers them) and a
// copy of one fails strict validation before any byte is changed, so TextEdit
// in place proves the requirement plumbing, and a tiny bundle ad-hoc signed
// here proves that tampering, versions, and the system requirement are caught.

static NSOperatingSystemVersion const kFutureSystem = { 99, 0, 0 };
static NSOperatingSystemVersion const kSonoma       = { 14, 7, 0 };

static id Requirement (NSString* string)
{
	SecRequirementRef requirement = NULL;
	OAK_ASSERT_EQ((int)SecRequirementCreateWithString((__bridge CFStringRef)string, kSecCSDefaultFlags, &requirement), (int)errSecSuccess);
	return CFBridgingRelease(requirement);
}

static BOOL Verify (NSURL* bundleURL, NSString* expectedVersion, NSString* requirement, NSOperatingSystemVersion running, NSString* localVersion, NSError** error, NSString* executableName = @"TextMate")
{
	id req = Requirement(requirement);
	return SoftwareUpdateVerifyBundle(bundleURL, expectedVersion, (__bridge SecRequirementRef)req, running, localVersion, error, executableName);
}

// Parallel test execution means every test needs its own directory
struct temporary_directory_t
{
	temporary_directory_t ()
	{
		url = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"SoftwareUpdateVerifierTests-%@", NSUUID.UUID.UUIDString]] isDirectory:YES];
		[NSFileManager.defaultManager createDirectoryAtURL:url withIntermediateDirectories:YES attributes:nil error:nil];
	}

	~temporary_directory_t ()
	{
		[NSFileManager.defaultManager removeItemAtURL:url error:nil];
	}

	NSURL* url;
};

static NSString* const kFixtureRequirement = @"identifier \"com.macromates.TextMate.fixture\"";

// A TextMate.app shaped bundle, ad-hoc signed, with one sealed resource
static NSURL* SignedFixture (NSURL* directory, NSString* version, NSString* minimumSystemVersion = @"14.0")
{
	NSURL* bundleURL = [directory URLByAppendingPathComponent:@"TextMate.app" isDirectory:YES];
	NSURL* contents  = [bundleURL URLByAppendingPathComponent:@"Contents" isDirectory:YES];
	for(NSString* subdirectory in @[ @"MacOS", @"Resources" ])
		OAK_ASSERT([NSFileManager.defaultManager createDirectoryAtURL:[contents URLByAppendingPathComponent:subdirectory] withIntermediateDirectories:YES attributes:nil error:nil]);

	OAK_ASSERT([NSFileManager.defaultManager copyItemAtURL:[NSURL fileURLWithPath:@"/usr/bin/true"] toURL:[contents URLByAppendingPathComponent:@"MacOS/TextMate"] error:nil]);
	OAK_ASSERT([[@"Sealed resource\n" dataUsingEncoding:NSUTF8StringEncoding] writeToURL:[contents URLByAppendingPathComponent:@"Resources/Data.txt"] atomically:NO]);

	NSMutableDictionary* infoPlist = [@{
		@"CFBundleIdentifier":         @"com.macromates.TextMate.fixture",
		@"CFBundleExecutable":         @"TextMate",
		@"CFBundlePackageType":        @"APPL",
		@"CFBundleShortVersionString": version,
	} mutableCopy];
	if(minimumSystemVersion)
		infoPlist[@"LSMinimumSystemVersion"] = minimumSystemVersion;
	OAK_ASSERT([infoPlist writeToURL:[contents URLByAppendingPathComponent:@"Info.plist"] error:nil]);

	NSTask* task = [[NSTask alloc] init];
	task.executableURL  = [NSURL fileURLWithPath:@"/usr/bin/codesign"];
	task.arguments      = @[ @"--sign", @"-", @"--force", bundleURL.path ];
	task.standardOutput = NSFileHandle.fileHandleWithNullDevice;
	task.standardError  = NSFileHandle.fileHandleWithNullDevice;
	OAK_ASSERT([task launchAndReturnError:nil]);
	[task waitUntilExit];
	OAK_ASSERT_EQ(task.terminationStatus, 0);

	return bundleURL;
}

// =========================
// = Signature requirement =
// =========================

static NSURL* const TextEditURL ()
{
	return [NSURL fileURLWithPath:@"/System/Applications/TextEdit.app" isDirectory:YES];
}

static NSString* TextEditVersion ()
{
	return [NSDictionary dictionaryWithContentsOfURL:[TextEditURL() URLByAppendingPathComponent:@"Contents/Info.plist"] error:nil][@"CFBundleShortVersionString"];
}

void test_textedit_satisfies_anchor_apple ()
{
	NSError* error;
	BOOL res = Verify(TextEditURL(), TextEditVersion(), @"anchor apple", kFutureSystem, @"0.1", &error, @"TextEdit");
	OAK_MASSERT(to_s(error), res);
}

void test_textedit_is_not_textmate ()
{
	NSError* error;
	OAK_ASSERT(!Verify(TextEditURL(), TextEditVersion(), @"identifier \"com.macromates.TextMate\"", kFutureSystem, @"0.1", &error, @"TextEdit"));
	OAK_ASSERT_EQ(to_s(error.domain), to_s(SoftwareUpdateErrorDomain));
	OAK_ASSERT_EQ((int)error.code, (int)SoftwareUpdateErrorVerificationFailed);
	OAK_ASSERT(error.localizedDescription.length);
	OAK_ASSERT(error.userInfo[NSUnderlyingErrorKey]);
}

// ===================
// = Signed fixtures =
// ===================

void test_signed_fixture_passes ()
{
	temporary_directory_t dir;
	NSError* error;
	BOOL res = Verify(SignedFixture(dir.url, @"2.5.2"), @"2.5.2", kFixtureRequirement, kSonoma, @"2.5.1", &error);
	OAK_MASSERT(to_s(error), res);
}

void test_flipped_resource_byte_fails_strict_validation ()
{
	temporary_directory_t dir;
	NSURL* bundleURL = SignedFixture(dir.url, @"2.5.2");

	NSURL* resourceURL = [bundleURL URLByAppendingPathComponent:@"Contents/Resources/Data.txt"];
	NSMutableData* data = [NSMutableData dataWithContentsOfURL:resourceURL];
	((uint8_t*)data.mutableBytes)[0] ^= 0x01;
	OAK_ASSERT([data writeToURL:resourceURL atomically:NO]);

	NSError* error;
	OAK_ASSERT(!Verify(bundleURL, @"2.5.2", kFixtureRequirement, kSonoma, @"2.5.1", &error));
	OAK_ASSERT_EQ((int)error.code, (int)SoftwareUpdateErrorVerificationFailed);
	OAK_ASSERT(error.userInfo[NSUnderlyingErrorKey]);
}

void test_layout_failure ()
{
	temporary_directory_t dir;
	NSError* error;
	OAK_ASSERT(!Verify(dir.url, @"2.5.2", @"anchor apple", kSonoma, @"2.5.1", &error));
	OAK_ASSERT_EQ((int)error.code, (int)SoftwareUpdateErrorVerificationFailed);

	// An Info.plist is not enough
	NSURL* contents = [dir.url URLByAppendingPathComponent:@"Contents" isDirectory:YES];
	OAK_ASSERT([NSFileManager.defaultManager createDirectoryAtURL:[contents URLByAppendingPathComponent:@"MacOS/TextMate"] withIntermediateDirectories:YES attributes:nil error:nil]);
	OAK_ASSERT([@{ @"CFBundleShortVersionString": @"2.5.2" } writeToURL:[contents URLByAppendingPathComponent:@"Info.plist"] error:nil]);
	OAK_ASSERT(!Verify(dir.url, @"2.5.2", @"anchor apple", kSonoma, @"2.5.1", &error));
	OAK_ASSERT_EQ((int)error.code, (int)SoftwareUpdateErrorVerificationFailed);
}

void test_version_pin ()
{
	temporary_directory_t dir;
	NSError* error;
	OAK_ASSERT(!Verify(SignedFixture(dir.url, @"2.5.1"), @"2.5.2", kFixtureRequirement, kSonoma, @"2.5.0", &error));
	OAK_ASSERT_EQ((int)error.code, (int)SoftwareUpdateErrorVerificationFailed);
	OAK_ASSERT([error.localizedDescription containsString:@"2.5.1"]);
	OAK_ASSERT([error.localizedDescription containsString:@"2.5.2"]);
}

void test_downgrade_refused ()
{
	temporary_directory_t dir;
	NSURL* bundleURL = SignedFixture(dir.url, @"2.5.1");
	for(NSString* localVersion in @[ @"2.5.1", @"2.5.1.7", @"2.6.0" ])
	{
		NSError* error;
		OAK_ASSERT(!Verify(bundleURL, @"2.5.1", kFixtureRequirement, kSonoma, localVersion, &error));
		OAK_ASSERT_EQ((int)error.code, (int)SoftwareUpdateErrorVerificationFailed);
	}
	OAK_ASSERT(Verify(bundleURL, @"2.5.1", kFixtureRequirement, kSonoma, @"2.5.0.12", nullptr));
}

void test_signed_fixture_requiring_newer_system ()
{
	temporary_directory_t dir;
	NSError* error;
	OAK_ASSERT(!Verify(SignedFixture(dir.url, @"2.6.0", @"15.0"), @"2.6.0", kFixtureRequirement, kSonoma, @"2.5.1", &error));
	OAK_ASSERT_EQ((int)error.code, (int)SoftwareUpdateErrorRequiresNewerSystem);
	OAK_ASSERT_EQ(to_s(error.userInfo[SoftwareUpdateVersionErrorKey]), "2.6.0");
	OAK_ASSERT_EQ(to_s(error.userInfo[SoftwareUpdateMinimumSystemVersionErrorKey]), "15.0");
}

// ===========================
// = Step 4: runs on this Mac =
// ===========================

void test_system_requirement_refusal_names_both_versions ()
{
	NSError* error;
	OAK_ASSERT(!SoftwareUpdateCheckSystemRequirement(@"2.6.0", @"15.0", kSonoma, &error));
	OAK_ASSERT_EQ((int)error.code, (int)SoftwareUpdateErrorRequiresNewerSystem);
	OAK_ASSERT_EQ(to_s(error.localizedDescription), "TextMate 2.6.0 requires macOS 15.0 or later; this Mac is running macOS 14.7. Your current version has been left in place.");
	OAK_ASSERT_EQ(to_s(error.userInfo[SoftwareUpdateVersionErrorKey]), "2.6.0");
	OAK_ASSERT_EQ(to_s(error.userInfo[SoftwareUpdateMinimumSystemVersionErrorKey]), "15.0");
}

void test_system_requirement_passes ()
{
	for(NSString* minimum in @[ @"14", @"14.0", @"14.7" ])
		OAK_ASSERT(SoftwareUpdateCheckSystemRequirement(@"2.6.0", minimum, kSonoma, nullptr));
	OAK_ASSERT(SoftwareUpdateCheckSystemRequirement(@"2.6.0", nil, kSonoma, nullptr));
}

// ================
// = Availability =
// ================

void test_unsigned_test_runner_is_unavailable ()
{
	NSString* reason;
	SecRequirementRef requirement = SoftwareUpdateCopyUpdateRequirement(&reason);
	OAK_ASSERT(!requirement);
	OAK_ASSERT_EQ(to_s(reason), "This copy of TextMate was built without a distribution signature and cannot update itself.");
}
