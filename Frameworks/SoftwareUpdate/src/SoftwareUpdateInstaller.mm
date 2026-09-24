#import "SoftwareUpdateInstaller.h"
#import "SoftwareUpdateRelease.h"
#import <OakSystem/application.h>
#import <sys/mount.h>

static BOOL CannotInstall (NSError** error, NSString* message, NSString* suggestion)
{
	if(error)
	{
		*error = [NSError errorWithDomain:SoftwareUpdateErrorDomain code:SoftwareUpdateErrorCannotInstall userInfo:@{
			NSLocalizedDescriptionKey:             [NSString stringWithFormat:@"%@\n\n%@", message, suggestion],
			NSLocalizedFailureReasonErrorKey:      message,
			NSLocalizedRecoverySuggestionErrorKey: suggestion,
		}];
	}
	return NO;
}

BOOL SoftwareUpdatePathIsTranslocated (NSString* path)
{
	for(NSString* prefix in @[ @"/private/var/folders/", @"/var/folders/" ])
	{
		if([path hasPrefix:prefix])
			return [[path substringFromIndex:prefix.length] rangeOfString:@"/AppTranslocation/"].location != NSNotFound;
	}
	return NO;
}

BOOL SoftwareUpdatePreflight (NSURL* bundleURL, NSError** error)
{
	NSString* path = bundleURL.URLByStandardizingPath.path;

	// A translocated copy also sits on a read-only mount; this says what to do about it
	if(SoftwareUpdatePathIsTranslocated(path))
		return CannotInstall(error, @"TextMate is running from a temporary read-only location because it was opened straight from the folder it was downloaded to.", @"Move TextMate to the Applications folder and relaunch it, then check for updates again.");

	struct statfs sfsb;
	if(statfs(path.fileSystemRepresentation, &sfsb) == 0 && (sfsb.f_flags & MNT_RDONLY))
		return CannotInstall(error, @"TextMate is running on a read-only file system and can therefore not be updated.", @"If you downloaded TextMate from the internet then moving it out of the Downloads folder should solve the problem.");

	NSString* parent = path.stringByDeletingLastPathComponent;
	if(access(parent.fileSystemRepresentation, W_OK) != 0)
		return CannotInstall(error, [NSString stringWithFormat:@"TextMate cannot be updated because you do not have permission to make changes in “%@”.", parent], @"Download the new version and install it yourself, or ask the owner of that folder to.");

	return YES;
}

BOOL SoftwareUpdateInstall (NSURL* stagedURL, NSURL* destinationURL, NSError** error)
{
	return [NSFileManager.defaultManager replaceItemAtURL:destinationURL withItemAtURL:stagedURL backupItemName:nil options:NSFileManagerItemReplacementUsingNewMetadataOnly resultingItemURL:nil error:error];
}

void SoftwareUpdateRelaunch ()
{
	oak::application_t::relaunch();
}
