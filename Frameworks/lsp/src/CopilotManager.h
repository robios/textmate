#ifndef COPILOT_MANAGER_H_89F2A3C1
#define COPILOT_MANAGER_H_89F2A3C1

#import <Foundation/Foundation.h>

@class OakDocument;

extern NSNotificationName const CopilotStatusDidChangeNotification;
extern NSNotificationName const CopilotLogNotification;

typedef NS_ENUM(NSInteger, CopilotStatus) {
	CopilotStatusDisabled,
	CopilotStatusConnecting,
	CopilotStatusReady,
	CopilotStatusAuthRequired,
	CopilotStatusError,
};

@interface CopilotManager : NSObject
@property (nonatomic, readonly) CopilotStatus status;
@property (nonatomic, readonly) NSString* username;

+ (instancetype)sharedManager;

- (void)documentDidOpen:(OakDocument*)document;
- (void)documentDidChange:(OakDocument*)document;
- (void)documentDidSave:(OakDocument*)document;
- (void)documentWillClose:(OakDocument*)document;
- (void)documentDidFocus:(OakDocument*)document;

- (int)requestCompletionForDocument:(OakDocument*)document
                               line:(NSUInteger)line
                          character:(NSUInteger)character
                         completion:(void(^)(NSArray<NSDictionary*>* items))callback;

- (void)cancelCompletionRequest:(int)requestId;

- (void)sendAcceptanceTelemetry:(NSDictionary*)command;
- (void)sendDidShowCompletion:(NSDictionary*)item;

- (void)signIn;
- (void)signOut;
- (void)shutdown;

// Start or stop the client to match the current copilotEnabled setting.
- (void)reloadSettings;

// Effective value of the copilotGhostTextOnly setting for a document
// (never show the completion popup, only inline ghost text).
- (BOOL)ghostTextOnlyForDocument:(OakDocument*)document;
@end

#endif /* COPILOT_MANAGER_H_89F2A3C1 */
