#ifndef CODEX_IDE_CONTEXT_SERVER_H_DBNFRE43
#define CODEX_IDE_CONTEXT_SERVER_H_DBNFRE43

#import <Foundation/Foundation.h>

@class AgentBridgeWorkspace;

// A TextMate implementation of Codex TUI's version-0 IDE-context IPC. It joins
// Codex's primary router as an IDE client and also owns a short, mode-0700
// TMPDIR socket for CLI versions or sessions where no router is available.
@interface CodexIDEContextServer : NSObject
@property (nonatomic, readonly, getter = isRunning) BOOL running;
@property (nonatomic, readonly) NSString* temporaryDirectory;

- (instancetype)initWithWorkspace:(AgentBridgeWorkspace*)workspace;
- (BOOL)start;
- (void)stop;
@end

#endif /* CODEX_IDE_CONTEXT_SERVER_H_DBNFRE43 */
