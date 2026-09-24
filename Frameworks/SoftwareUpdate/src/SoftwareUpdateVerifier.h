#ifndef SOFTWARE_UPDATE_VERIFIER_H_M4KD7PZB
#define SOFTWARE_UPDATE_VERIFIER_H_M4KD7PZB

#import <Foundation/Foundation.h>
#import <Security/Security.h>

NS_ASSUME_NONNULL_BEGIN

// Checks an extracted update before anything touches the installed app, in
// this order, stopping at the first failure:
//
// 1. Layout: Contents/Info.plist exists and Contents/MacOS/<executableName> is
//    an executable file.
// 2. Version pin: CFBundleShortVersionString equals expectedVersion (the feed’s
//    version), so a genuinely signed older release served as the latest one
//    is refused.
// 3. Signature: strict, all architectures, nested code included, against
//    requirement (the running app’s designated requirement). Revocation is
//    not checked: that needs the network, and Gatekeeper does it at launch.
// 4. Runs on this Mac: LSMinimumSystemVersion is satisfied by running.
// 5. Not a downgrade: the extracted version is greater than localVersion.
//
// Step 4 fails with SoftwareUpdateErrorRequiresNewerSystem, every other step
// with SoftwareUpdateErrorVerificationFailed; a signature failure carries the
// Security framework’s description and underlying error.
BOOL SoftwareUpdateVerifyBundle (NSURL* bundleURL, NSString* expectedVersion, SecRequirementRef requirement, NSOperatingSystemVersion running, NSString* localVersion, NSError** error, NSString* executableName = @"TextMate");

// Step 4 on its own. A nil or empty minimumSystemVersion is no requirement.
// Fails with SoftwareUpdateErrorRequiresNewerSystem and userInfo carrying
// SoftwareUpdateVersionErrorKey and SoftwareUpdateMinimumSystemVersionErrorKey.
BOOL SoftwareUpdateCheckSystemRequirement (NSString* version, NSString* _Nullable minimumSystemVersion, NSOperatingSystemVersion running, NSError** error);

// Whether this copy of TextMate can update itself: it has a distribution
// signature (a certificate chain and a team identifier; ad-hoc signed builds
// have neither), a designated requirement, and the identifier
// com.macromates.TextMate. Returns the designated requirement, which update
// signatures are checked against, or NULL with a human-readable reason.
SecRequirementRef _Nullable SoftwareUpdateCopyUpdateRequirement (NSString* _Nullable* _Nullable unavailableReason) CF_RETURNS_RETAINED;

NS_ASSUME_NONNULL_END

#endif /* end of include guard: SOFTWARE_UPDATE_VERIFIER_H_M4KD7PZB */
