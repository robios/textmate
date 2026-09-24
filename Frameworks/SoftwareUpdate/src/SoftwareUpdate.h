#ifndef SOFTWARE_UPDATE_H_3NCV6KYS
#define SOFTWARE_UPDATE_H_3NCV6KYS

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString* const kUserDefaultsSoftwareUpdateDisablePollingKey;       // BOOL, the preferences checkbox (negated)
extern NSString* const kUserDefaultsSoftwareUpdateLastPollKey;             // NSDate of the last check answered with 200
extern NSString* const kUserDefaultsSoftwareUpdateSuspendUntilKey;         // NSDate, set by ‘Later’
extern NSString* const kUserDefaultsSoftwareUpdateSkippedVersionKey;       // NSString, set by ‘Skip This Version’
extern NSString* const kUserDefaultsSoftwareUpdateRetryAfterKey;           // NSDate before which the feed is not contacted (rate limiting)
extern NSString* const kUserDefaultsSoftwareUpdateRateLimitStrikesKey;     // NSInteger, consecutive 403/429 responses
extern NSString* const kUserDefaultsSoftwareUpdateUnsupportedReleaseKey;   // { version, minimumSystemVersion } of a release this Mac cannot run
extern NSString* const kUserDefaultsSoftwareUpdateFeedURLKey;              // NSString, testing override of the feed URL

// The two install prerequisites that live with the document windows. The app
// provides them so this framework does not depend on DocumentWindow.
@protocol SoftwareUpdateDelegate <NSObject>
// Ask whether terminal panes with running processes may be terminated, as
// quitting does. The relaunch quits without asking.
- (void)softwareUpdateAskToTerminateRunningProcesses:(void(^)(BOOL canTerminate))callback;
// Save the session including untitled documents, reporting any document whose
// backup could not be written. Nothing is installed unless this succeeds.
- (BOOL)softwareUpdateSaveSessionWithError:(NSError**)error;
@end

@interface SoftwareUpdate : NSObject
@property (class, readonly) SoftwareUpdate* sharedInstance;

// Whether this copy can update itself (a distribution-signed TextMate);
// evaluated once. When NO, unavailableReason says why, in a sentence.
@property (nonatomic, readonly, getter = isAvailable) BOOL available;
@property (nonatomic, readonly, nullable) NSString* unavailableReason;

@property (nonatomic, readonly, getter = isChecking) BOOL checking;

// Required for ‘Install & Relaunch’; without it installing is refused.
@property (nonatomic, weak, nullable) id <SoftwareUpdateDelegate> delegate;

// Schedules the daily background check and, when the last completed check is
// more than a day old, one check shortly after launch. Does nothing when the
// updater is unavailable.
- (void)startIfAvailable;

// A user-initiated check: always ends in a panel, whether with a new version,
// “up to date”, an error, the rate-limit notice (without contacting GitHub
// while backing off), or why this copy cannot update itself.
- (void)checkForUpdate:(nullable id)sender;

// A check that only speaks up when there is something to offer. Skipped while
// polling is disabled, ‘Later’ is in effect, GitHub asked us to back off, a
// panel is open, or the updater is unavailable.
- (void)checkInBackground;
@end

NS_ASSUME_NONNULL_END

#endif /* end of include guard: SOFTWARE_UPDATE_H_3NCV6KYS */
