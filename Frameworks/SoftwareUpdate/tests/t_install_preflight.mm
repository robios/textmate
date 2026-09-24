#import <SoftwareUpdate/SoftwareUpdateInstaller.h>
#import <SoftwareUpdate/SoftwareUpdateRelease.h>
#import <ns/ns.h>

// A read-only volume (running from a disk image) is left to manual testing:
// mounting one here would mean driving hdiutil from parallel tests.

struct temporary_directory_t
{
	temporary_directory_t ()
	{
		url = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"SoftwareUpdatePreflightTests-%@", NSUUID.UUID.UUIDString]] isDirectory:YES];
		[NSFileManager.defaultManager createDirectoryAtURL:url withIntermediateDirectories:YES attributes:nil error:nil];
	}

	~temporary_directory_t ()
	{
		chmod(url.fileSystemRepresentation, 0755);
		[NSFileManager.defaultManager removeItemAtURL:url error:nil];
	}

	NSURL* url;
};

static NSURL* MakeBundle (NSURL* directory)
{
	NSURL* bundleURL = [directory URLByAppendingPathComponent:@"TextMate.app" isDirectory:YES];
	OAK_ASSERT([NSFileManager.defaultManager createDirectoryAtURL:[bundleURL URLByAppendingPathComponent:@"Contents"] withIntermediateDirectories:YES attributes:nil error:nil]);
	return bundleURL;
}

void test_translocation_pattern ()
{
	OAK_ASSERT(SoftwareUpdatePathIsTranslocated(@"/private/var/folders/8x/k2b1ql1j3vn5y0rx3wvlmlm80000gn/T/AppTranslocation/8E6D2A47-3D3B-4C4B-9E43-6B1A0C2F3F11/d/TextMate.app"));
	OAK_ASSERT(SoftwareUpdatePathIsTranslocated(@"/var/folders/8x/k2b1ql1j3vn5y0rx3wvlmlm80000gn/T/AppTranslocation/8E6D2A47-3D3B-4C4B-9E43-6B1A0C2F3F11/d/TextMate.app"));

	OAK_ASSERT(!SoftwareUpdatePathIsTranslocated(@"/Applications/TextMate.app"));
	OAK_ASSERT(!SoftwareUpdatePathIsTranslocated(@"/Users/me/Downloads/TextMate.app"));
	OAK_ASSERT(!SoftwareUpdatePathIsTranslocated(@"/Users/me/AppTranslocation/TextMate.app"));
	OAK_ASSERT(!SoftwareUpdatePathIsTranslocated(@"/private/var/folders/8x/k2b1ql1j3vn5y0rx3wvlmlm80000gn/T/TextMate.app"));
}

void test_translocated_bundle_is_refused ()
{
	NSError* error;
	OAK_ASSERT(!SoftwareUpdatePreflight([NSURL fileURLWithPath:@"/private/var/folders/8x/k2b1ql1j3vn5y0rx3wvlmlm80000gn/T/AppTranslocation/8E6D2A47-3D3B-4C4B-9E43-6B1A0C2F3F11/d/TextMate.app"], &error));
	OAK_ASSERT_EQ(to_s(error.domain), to_s(SoftwareUpdateErrorDomain));
	OAK_ASSERT_EQ((int)error.code, (int)SoftwareUpdateErrorCannotInstall);
	OAK_ASSERT([error.localizedDescription containsString:@"Applications folder"]);
}

void test_unwritable_parent_is_refused ()
{
	temporary_directory_t dir;
	NSURL* bundleURL = MakeBundle(dir.url);
	OAK_ASSERT_EQ(chmod(dir.url.fileSystemRepresentation, 0555), 0);

	NSError* error;
	OAK_ASSERT(!SoftwareUpdatePreflight(bundleURL, &error));
	OAK_ASSERT_EQ((int)error.code, (int)SoftwareUpdateErrorCannotInstall);
	OAK_ASSERT([error.localizedDescription containsString:dir.url.path.lastPathComponent]);
}

void test_writable_parent_passes ()
{
	temporary_directory_t dir;
	NSError* error;
	BOOL res = SoftwareUpdatePreflight(MakeBundle(dir.url), &error);
	OAK_MASSERT(to_s(error), res);
}

void test_install_replaces_the_bundle ()
{
	temporary_directory_t dir;
	NSURL* installed = MakeBundle(dir.url);
	OAK_ASSERT([@"old" writeToURL:[installed URLByAppendingPathComponent:@"Contents/Version.txt"] atomically:NO encoding:NSUTF8StringEncoding error:nil]);

	temporary_directory_t staging;
	NSURL* staged = MakeBundle(staging.url);
	OAK_ASSERT([@"new" writeToURL:[staged URLByAppendingPathComponent:@"Contents/Version.txt"] atomically:NO encoding:NSUTF8StringEncoding error:nil]);

	NSError* error;
	BOOL res = SoftwareUpdateInstall(staged, installed, &error);
	OAK_MASSERT(to_s(error), res);
	OAK_ASSERT_EQ(to_s([NSString stringWithContentsOfURL:[installed URLByAppendingPathComponent:@"Contents/Version.txt"] encoding:NSUTF8StringEncoding error:nil]), "new");
}
