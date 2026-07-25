#ifndef CLAUDE_IDE_CONTEXT_LOCK_FILE_H_QX4M7Z1P
#define CLAUDE_IDE_CONTEXT_LOCK_FILE_H_QX4M7Z1P

#import <Foundation/Foundation.h>

// Discovery lock file for the Claude Code CLI: ~/.claude/ide/[port].lock
// (honors $CLAUDE_CONFIG_DIR). The CLI scans this directory, reads the
// port from the file name and authenticates with the contained authToken.
@interface ClaudeIDEContextLockFile : NSObject
+ (NSString*)defaultLockDirectory;
+ (NSString*)generateAuthToken; // 32 lowercase hex characters (128 bits) from the OS CSPRNG
+ (void)removeStaleLockFilesInDirectory:(NSString*)directory;

- (instancetype)initWithPort:(NSUInteger)port authToken:(NSString*)authToken directory:(NSString*)directory;

@property (nonatomic, readonly) NSUInteger port;
@property (nonatomic, readonly) NSString* authToken;
@property (nonatomic, readonly) NSString* path;

- (BOOL)writeWithWorkspaceFolders:(NSArray<NSString*>*)workspaceFolders;
- (void)remove;
@end

#endif /* CLAUDE_IDE_CONTEXT_LOCK_FILE_H_QX4M7Z1P */
