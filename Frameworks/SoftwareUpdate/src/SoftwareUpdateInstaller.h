#ifndef SOFTWARE_UPDATE_INSTALLER_H_7FJW3CLE
#define SOFTWARE_UPDATE_INSTALLER_H_7FJW3CLE

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// YES for a path inside Gatekeeper’s read-only copy of an app that was opened
// straight from a quarantined location (/private/var/folders/…/AppTranslocation/).
BOOL SoftwareUpdatePathIsTranslocated (NSString* path);

// Whether the app at bundleURL can be replaced in place, checked before a
// download starts: not translocated, not on a read-only volume, and its parent
// directory writable. Fails with SoftwareUpdateErrorCannotInstall and a
// message saying what to do.
BOOL SoftwareUpdatePreflight (NSURL* bundleURL, NSError** error);

// Replaces the app at destinationURL with the verified bundle at stagedURL.
BOOL SoftwareUpdateInstall (NSURL* stagedURL, NSURL* destinationURL, NSError** error);

// Terminates the running app (SIGTERM, which saves the session) and opens the
// bundle at its path again with session restore forced on for that launch.
void SoftwareUpdateRelaunch ();

NS_ASSUME_NONNULL_END

#endif /* end of include guard: SOFTWARE_UPDATE_INSTALLER_H_7FJW3CLE */
