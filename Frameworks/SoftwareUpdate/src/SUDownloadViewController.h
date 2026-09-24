#ifndef SU_DOWNLOAD_VIEW_CONTROLLER_H_JX6PQ4DT
#define SU_DOWNLOAD_VIEW_CONTROLLER_H_JX6PQ4DT

#import "SoftwareUpdate.h"
#import "SoftwareUpdateRelease.h"

NS_ASSUME_NONNULL_BEGIN

// The software update panel: a check’s result, and for a new version the
// whole download → verify → install → relaunch sequence. The panel keeps
// itself alive while it is on screen; completionHandler runs when it closes.
@interface SUDownloadViewController : NSViewController
- (instancetype)initWithCompletionHandler:(nullable void(^)(void))completionHandler;

// Needed from ‘Download’ on: what the extracted bundle’s signature must
// satisfy (a SecRequirementRef), how the archive is fetched, and who is asked
// before installing.
@property (nonatomic, nullable) id requirement;
@property (nonatomic, copy) NSString* userAgent;
@property (nonatomic) BOOL allowLoopback;
@property (nonatomic, weak, nullable) id <SoftwareUpdateDelegate> delegate;

// Shows the panel for a fetched release: New Version Available, Up To Date,
// Newer Than Release, or Requires Newer macOS (decided by the caller).
- (void)presentRelease:(SoftwareUpdateRelease*)release decision:(SoftwareUpdateDecision)decision backgroundCheck:(BOOL)backgroundCheck;
// Shows a message with an OK button (rate limited, unavailable, …).
- (void)presentMessage:(NSString*)message informativeText:(NSString*)informativeText;
// Error Checking for Update
- (void)presentError:(NSError*)error;

- (void)orderFront;
@end

NS_ASSUME_NONNULL_END

#endif /* end of include guard: SU_DOWNLOAD_VIEW_CONTROLLER_H_JX6PQ4DT */
