#import "SoftwareUpdateVerifier.h"
#import "SoftwareUpdateRelease.h"
#import <OakFoundation/OakCompareVersionStrings.h>

static BOOL Fail (NSError** error, NSString* description, NSError* underlyingError = nil)
{
	if(error)
	{
		NSMutableDictionary* userInfo = [NSMutableDictionary dictionaryWithObject:description forKey:NSLocalizedDescriptionKey];
		if(underlyingError)
			userInfo[NSUnderlyingErrorKey] = underlyingError;
		*error = [NSError errorWithDomain:SoftwareUpdateErrorDomain code:SoftwareUpdateErrorVerificationFailed userInfo:userInfo];
	}
	return NO;
}

static NSString* SystemVersionString (NSOperatingSystemVersion version)
{
	if(version.patchVersion)
		return [NSString stringWithFormat:@"%ld.%ld.%ld", version.majorVersion, version.minorVersion, version.patchVersion];
	return [NSString stringWithFormat:@"%ld.%ld", version.majorVersion, version.minorVersion];
}

BOOL SoftwareUpdateCheckSystemRequirement (NSString* version, NSString* minimumSystemVersion, NSOperatingSystemVersion running, NSError** error)
{
	if(SoftwareUpdateSystemVersionSatisfies(minimumSystemVersion, running))
		return YES;

	if(error)
	{
		*error = [NSError errorWithDomain:SoftwareUpdateErrorDomain code:SoftwareUpdateErrorRequiresNewerSystem userInfo:@{
			NSLocalizedDescriptionKey:                  [NSString stringWithFormat:@"TextMate %@ requires macOS %@ or later; this Mac is running macOS %@. Your current version has been left in place.", version, minimumSystemVersion, SystemVersionString(running)],
			SoftwareUpdateVersionErrorKey:              version,
			SoftwareUpdateMinimumSystemVersionErrorKey: minimumSystemVersion,
		}];
	}
	return NO;
}

BOOL SoftwareUpdateVerifyBundle (NSURL* bundleURL, NSString* expectedVersion, SecRequirementRef requirement, NSOperatingSystemVersion running, NSString* localVersion, NSError** error, NSString* executableName)
{
	// 1. Layout
	NSURL* infoPlistURL  = [bundleURL URLByAppendingPathComponent:@"Contents/Info.plist" isDirectory:NO];
	NSURL* executableURL = [[bundleURL URLByAppendingPathComponent:@"Contents/MacOS" isDirectory:YES] URLByAppendingPathComponent:executableName isDirectory:NO];

	NSNumber* isRegularFile, *isExecutable;
	NSDictionary* infoPlist = [NSDictionary dictionaryWithContentsOfURL:infoPlistURL error:nullptr];
	if(!infoPlist || ![executableURL getResourceValue:&isRegularFile forKey:NSURLIsRegularFileKey error:nullptr] || ![executableURL getResourceValue:&isExecutable forKey:NSURLIsExecutableKey error:nullptr] || !isRegularFile.boolValue || !isExecutable.boolValue)
		return Fail(error, @"The download does not contain a complete TextMate application.");

	// 2. Version pin
	id version = infoPlist[@"CFBundleShortVersionString"];
	if(![version isKindOfClass:[NSString class]] || ![version isEqualToString:expectedVersion])
		return Fail(error, [NSString stringWithFormat:@"The download contains version %@, not the announced %@.", [version isKindOfClass:[NSString class]] ? version : @"(unknown)", expectedVersion]);

	// 3. Signature
	SecStaticCodeRef code = NULL;
	OSStatus status = SecStaticCodeCreateWithPath((__bridge CFURLRef)bundleURL, kSecCSDefaultFlags, &code);
	if(status != errSecSuccess)
	{
		NSError* underlyingError = [NSError errorWithDomain:NSOSStatusErrorDomain code:status userInfo:nil];
		NSString* message = CFBridgingRelease(SecCopyErrorMessageString(status, NULL)) ?: underlyingError.localizedDescription;
		return Fail(error, message, underlyingError);
	}

	CFErrorRef cfError = NULL;
	status = SecStaticCodeCheckValidityWithErrors(code, kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode, requirement, &cfError);
	CFRelease(code);
	if(status != errSecSuccess)
	{
		NSError* underlyingError = CFBridgingRelease(cfError) ?: [NSError errorWithDomain:NSOSStatusErrorDomain code:status userInfo:nil];
		NSString* message = CFBridgingRelease(SecCopyErrorMessageString(status, NULL)) ?: underlyingError.localizedDescription;
		return Fail(error, message, underlyingError);
	}

	// 4. Runs on this Mac (Info.plist is sealed by the signature just checked)
	id minimumSystemVersion = infoPlist[@"LSMinimumSystemVersion"];
	if(minimumSystemVersion && ![minimumSystemVersion isKindOfClass:[NSString class]])
		return Fail(error, @"The download has an invalid minimum system version.");
	if(!SoftwareUpdateCheckSystemRequirement(version, minimumSystemVersion, running, error))
		return NO;

	// 5. Not a downgrade
	if(OakCompareVersionStrings(localVersion, version) != NSOrderedAscending)
		return Fail(error, [NSString stringWithFormat:@"The download contains version %@, which is not newer than the running %@.", version, localVersion]);

	return YES;
}

SecRequirementRef SoftwareUpdateCopyUpdateRequirement (NSString** unavailableReason)
{
	NSString* const notDistributionSigned = @"This copy of TextMate was built without a distribution signature and cannot update itself.";

	SecCodeRef code = NULL;
	if(SecCodeCopySelf(kSecCSDefaultFlags, &code) != errSecSuccess)
	{
		if(unavailableReason)
			*unavailableReason = notDistributionSigned;
		return NULL;
	}

	CFDictionaryRef cfInfo = NULL;
	SecStaticCodeRef staticCode = NULL;
	if(SecCodeCopyStaticCode(code, kSecCSDefaultFlags, &staticCode) == errSecSuccess)
	{
		SecCodeCopySigningInformation(staticCode, kSecCSSigningInformation, &cfInfo);
		CFRelease(staticCode);
	}
	NSDictionary* info = CFBridgingRelease(cfInfo);

	NSArray* certificates = info[(__bridge NSString*)kSecCodeInfoCertificates];
	NSString* teamIdentifier = info[(__bridge NSString*)kSecCodeInfoTeamIdentifier];
	NSString* identifier = info[(__bridge NSString*)kSecCodeInfoIdentifier];

	SecRequirementRef requirement = NULL;
	if(certificates.count == 0 || teamIdentifier.length == 0 || SecCodeCopyDesignatedRequirement(code, kSecCSDefaultFlags, &requirement) != errSecSuccess)
	{
		if(unavailableReason)
			*unavailableReason = notDistributionSigned;
	}
	else if(![identifier isEqualToString:@"com.macromates.TextMate"])
	{
		if(unavailableReason)
			*unavailableReason = [NSString stringWithFormat:@"This copy of TextMate is signed as ‘%@’, not as TextMate, and cannot update itself.", identifier ?: @"(unknown)"];
		CFRelease(requirement);
		requirement = NULL;
	}

	CFRelease(code);
	return requirement;
}
