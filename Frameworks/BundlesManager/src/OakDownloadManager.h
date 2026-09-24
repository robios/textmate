NS_ASSUME_NONNULL_BEGIN

@interface OakDownloadManager : NSObject
@property (class, readonly) OakDownloadManager* sharedInstance;
@property (nonatomic) NSString* userAgentString;
- (void)downloadFileAtURL:(NSURL*)serverURL replacingFileAtURL:(NSURL*)localFileURL publicKeys:(NSDictionary<NSString*, NSString*>*)publicKeys completionHandler:(void(^)(BOOL wasUpdated, NSError* error))completionHandler;

// Streams the body at serverURL into ‘tar -jxmkC <tmp> --strip-components 1’ and
// hands the extraction directory (an NSItemReplacementDirectory for localURL) to
// the completion handler. Equivalent to the method below with the shared
// userAgentString and a transport policy that allows every redirect.
- (id <NSProgressReporting>)downloadArchiveAtURL:(NSURL*)serverURL forReplacingURL:(nullable NSURL*)localURL publicKeys:(NSDictionary<NSString*, NSString*>*)publicKeys completionHandler:(void(^)(NSURL* extractedArchiveURL, NSError* error))completionHandler;

// Contracts:
// - publicKeys == nil skips the x-amz-meta-x-signature (DSA) header verification
//   and the body is not buffered in memory. The caller must then establish the
//   archive’s authenticity by other means (e.g. a code-signature check).
// - userAgent and transportPolicy are applied when the task is created (the
//   request starts immediately). transportPolicy is evaluated on every redirect
//   target; a target it rejects is not followed. nil means every redirect is
//   allowed. The initial serverURL is not evaluated: the caller checks it first.
// - Any non-2xx HTTP response (including a redirect that was refused) cancels the
//   download with an NSError naming the status, instead of feeding the error
//   page to tar.
- (id <NSProgressReporting>)downloadArchiveAtURL:(NSURL*)serverURL forReplacingURL:(nullable NSURL*)localURL publicKeys:(nullable NSDictionary<NSString*, NSString*>*)publicKeys userAgent:(NSString*)userAgent transportPolicy:(nullable BOOL(^)(NSURL* url))transportPolicy completionHandler:(void(^)(NSURL* extractedArchiveURL, NSError* error))completionHandler;
@end

NS_ASSUME_NONNULL_END
