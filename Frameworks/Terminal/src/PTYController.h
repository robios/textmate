#ifndef PTY_CONTROLLER_H_B7E4D8A2
#define PTY_CONTROLLER_H_B7E4D8A2

#import <Foundation/Foundation.h>
#include <map>
#include <string>
#include <vector>

// Spawns a process on a pseudo-terminal and pumps its output on a
// background queue. All handlers are invoked on the internal I/O queue;
// callers must bounce to the main queue themselves for UI work.
// `arguments` is the argv tail (argv[0] is derived from path, with the
// traditional “-” prefix when loginShell is set).
//
// The process is reached through the TextMatePTYHelper trampoline shipped
// beside the running executable, which acquires the pty as the controlling
// terminal of the new session before exec’ing the target — posix_spawn cannot
// express that step, and the target would otherwise get a tty with no
// foreground process group. The helper execs the target, so processIdentifier
// is the target’s own pid.
@interface PTYController : NSObject
- (instancetype)initWithPath:(std::string const&)path arguments:(std::vector<std::string> const&)arguments environment:(std::map<std::string, std::string> const&)environment workingDirectory:(std::string const&)workingDirectory loginShell:(BOOL)loginShell columns:(NSUInteger)columns rows:(NSUInteger)rows pixelWidth:(NSUInteger)pixelWidth pixelHeight:(NSUInteger)pixelHeight;

@property (nonatomic, copy) void(^readHandler)(void const* bytes, size_t length);
@property (nonatomic, copy) void(^exitHandler)(int status);

@property (nonatomic, readonly) pid_t processIdentifier;
@property (nonatomic, readonly, getter = isRunning) BOOL running;

// Running-process detection (Terminal.app semantics): YES when the pty’s
// foreground process group (tcgetpgrp on the master) differs from the
// spawned shell itself, OR the shell has a live (non-zombie) child
// process — the latter catches suspended (^Z) and backgrounded jobs,
// whose foreground pgid has returned to the shell. The name is the
// foreground process group leader’s name (proc_name) when a foreground
// job exists, otherwise the first live child’s; nil when the shell sits
// idle at its prompt or the name cannot be resolved.
@property (nonatomic, readonly) BOOL hasForegroundProcess;
@property (nonatomic, readonly) NSString* foregroundProcessName;

- (BOOL)spawn; // returns NO if pty allocation, the spawn, or the reported terminal/exec setup failed
- (void)writeData:(NSData*)data;
- (void)resizeToColumns:(NSUInteger)columns rows:(NSUInteger)rows pixelWidth:(NSUInteger)pixelWidth pixelHeight:(NSUInteger)pixelHeight;
- (void)shutdown; // SIGHUP the process group, close the pty, reap
@end

#endif /* PTY_CONTROLLER_H_B7E4D8A2 */
