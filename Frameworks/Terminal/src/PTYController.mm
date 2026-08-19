#import "PTYController.h"
#import "PTYHelperProtocol.h"
#include <util.h>

// Queue-identity keys: our final release can happen inside a dispatch-source
// handler (making dealloc → shutdown run on the read or write queue), and a
// dispatch_sync onto the queue we are standing on aborts. Tag the queues so
// shutdown can skip the barrier that would target its own queue.
static void* const kPTYReadQueueIdentityKey  = (void*)&kPTYReadQueueIdentityKey;
static void* const kPTYWriteQueueIdentityKey = (void*)&kPTYWriteQueueIdentityKey;
#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
#include <mach-o/dyld.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <unistd.h>

// waitpid with the EINTR retry every caller needs, so that each call site only
// ever sees a definitive result: the reaped pid (status is valid), 0 (WNOHANG
// only — the child is not waitable yet), or -1 with errno == ECHILD (someone
// else already reaped it). That last case is real rather than theoretical:
// -handleProcessExit and -shutdown race, since dispatch_source_cancel does not
// stop an already-running handler.
static pid_t reap_child (pid_t pid, int* status, int options)
{
	pid_t rc;
	while((rc = waitpid(pid, status, options)) == -1 && errno == EINTR)
		continue;
	return rc;
}

// Non-consuming test for a child that has already exited: WNOWAIT leaves the
// zombie in place, keeping the blocking reap in -handleProcessExit the single
// consumer of the status. ECHILD (some other lifecycle path already reaped the
// pid) is “nothing to do”, like “not exited yet”.
static bool child_did_exit (pid_t pid)
{
	if(pid <= 0)
		return false;

	while(true)
	{
		siginfo_t info;
		memset(&info, 0, sizeof(info));
		if(waitid(P_PID, (id_t)pid, &info, WEXITED | WNOHANG | WNOWAIT) == -1)
		{
			if(errno == EINTR)
				continue;
			return false;
		}
		return info.si_pid == pid; // zeroed when there is no exit to report
	}
}

// Absolute path of the TextMatePTYHelper shipped beside the running executable
// — Contents/MacOS in the app, the build directory next to the test runner.
// Neither PATH-searched nor overridable through the environment: this file
// becomes the user’s shell session, so which one runs must depend on nothing
// but where the running binary sits. Empty when it cannot be resolved, which
// -spawn reports as an ordinary startup failure.
static std::string const& helper_path ()
{
	static std::string const path = []{
		char executable[PATH_MAX], resolved[PATH_MAX];
		uint32_t size = sizeof(executable);
		if(_NSGetExecutablePath(executable, &size) != 0 || !realpath(executable, resolved))
			return std::string();

		std::string res(resolved);
		std::string::size_type slash = res.rfind('/');
		if(slash == std::string::npos)
			return std::string();
		res.erase(slash + 1);
		res.append("TextMatePTYHelper");

		return access(res.c_str(), X_OK) == 0 ? res : std::string();
	}();
	return path;
}

// Reads the helper’s startup handshake to a definitive answer: 0 when the pipe
// reached EOF without a byte — the write end is close-on-exec, so the target’s
// execve closed it — 1 when *record holds one complete failure report, and -1
// with errno set for a protocol failure (a short, oversized or malformed
// payload, or a read error). Reading one byte more than a record is what makes
// an oversized payload detectable rather than silently truncated.
static int read_helper_status (int fd, struct pty_helper_error_t* record)
{
	char buffer[sizeof(*record) + 1];
	size_t total = 0;
	while(total < sizeof(buffer))
	{
		ssize_t len = read(fd, buffer + total, sizeof(buffer) - total);
		if(len > 0)
			total += (size_t)len;
		else if(len == 0)
			break;
		else if(errno == EINTR)
			continue;
		else
			return -1;
	}

	if(total == 0)
		return 0;

	if(!pty_helper_error_decode(buffer, total, record))
	{
		errno = EPROTO;
		return -1;
	}
	return 1;
}

@implementation PTYController
{
	std::string _path;
	std::vector<std::string> _arguments;
	std::map<std::string, std::string> _environment;
	std::string _workingDirectory;
	BOOL _loginShell;
	struct winsize _windowSize;

	int _masterFD;
	dispatch_queue_t _readQueue;
	dispatch_queue_t _writeQueue;
	dispatch_source_t _readSource;
	dispatch_source_t _processSource;
	BOOL _didHandleProcessExit;
	BOOL _didShutdown;
}

- (instancetype)initWithPath:(std::string const&)path arguments:(std::vector<std::string> const&)arguments environment:(std::map<std::string, std::string> const&)environment workingDirectory:(std::string const&)workingDirectory loginShell:(BOOL)loginShell columns:(NSUInteger)columns rows:(NSUInteger)rows pixelWidth:(NSUInteger)pixelWidth pixelHeight:(NSUInteger)pixelHeight
{
	if(self = [super init])
	{
		_path             = path;
		_arguments        = arguments;
		_environment      = environment;
		_workingDirectory = workingDirectory;
		_loginShell       = loginShell;
		_windowSize       = (struct winsize){ .ws_row = (unsigned short)rows, .ws_col = (unsigned short)columns, .ws_xpixel = (unsigned short)pixelWidth, .ws_ypixel = (unsigned short)pixelHeight };
		_masterFD         = -1;
		_readQueue        = dispatch_queue_create("com.macromates.textmate.pty-read", DISPATCH_QUEUE_SERIAL);
		_writeQueue       = dispatch_queue_create("com.macromates.textmate.pty-write", DISPATCH_QUEUE_SERIAL);
		dispatch_queue_set_specific(_readQueue, kPTYReadQueueIdentityKey, (__bridge void*)self, NULL);
		dispatch_queue_set_specific(_writeQueue, kPTYWriteQueueIdentityKey, (__bridge void*)self, NULL);
	}
	return self;
}

- (void)dealloc
{
	[self shutdown];
}

- (BOOL)isRunning
{
	return _processIdentifier > 0;
}

// The pgid of whatever currently owns the terminal. The shell starts as the
// leader of its own session and process group and as the terminal’s foreground
// group, so its pgid equals its pid; any foreground job therefore shows up as a
// pgid different from _processIdentifier.
- (pid_t)foregroundProcessGroup
{
	int fd = _masterFD;
	if(fd == -1 || _processIdentifier <= 0)
		return -1;
	return tcgetpgrp(fd);
}

// First live (non-zombie) direct child of the shell, or -1. A suspended
// (^Z) or backgrounded job no longer owns the pty’s foreground process
// group, but it is still a child of the shell — Terminal.app warns for
// these too.
- (pid_t)firstLiveChildProcess
{
	pid_t shell = _processIdentifier;
	if(shell <= 0)
		return -1;

	int size = proc_listpids(PROC_PPID_ONLY, (uint32_t)shell, NULL, 0);
	if(size <= 0)
		return -1;

	std::vector<pid_t> pids(size / sizeof(pid_t) + 8, 0);
	size = proc_listpids(PROC_PPID_ONLY, (uint32_t)shell, pids.data(), (int)(pids.size() * sizeof(pid_t)));
	for(int i = 0; i < size / (int)sizeof(pid_t); ++i)
	{
		if(pids[i] <= 0)
			continue;
		struct proc_bsdinfo info;
		if(proc_pidinfo(pids[i], PROC_PIDTBSDINFO, 0, &info, sizeof(info)) == sizeof(info) && info.pbi_status != SZOMB)
			return pids[i];
	}
	return -1;
}

- (BOOL)hasForegroundProcess
{
	pid_t pgid = [self foregroundProcessGroup];
	if(pgid > 0 && pgid != _processIdentifier)
		return YES;
	return [self firstLiveChildProcess] > 0;
}

- (NSString*)foregroundProcessName
{
	pid_t pid = [self foregroundProcessGroup];
	if(pid <= 0 || pid == _processIdentifier)
		pid = [self firstLiveChildProcess];
	if(pid <= 0)
		return nil;

	char name[2*MAXCOMLEN];
	if(proc_name(pid, name, sizeof(name)) > 0)
		return [NSString stringWithUTF8String:name];
	return nil;
}

- (BOOL)spawn
{
	if(_masterFD != -1)
		return NO;

	// The shell is not spawned directly. posix_spawn replaced forkpty because
	// fork() in a multithreaded process deadlocks the atfork prepare handlers
	// against allocator locks held on other threads (fatal under ASan, whose
	// spin locks then burn CPU) — but it cannot give the new session a
	// controlling terminal: Darwin does not apply the “first tty a session
	// leader opens becomes its ctty” rule to the in-kernel open of a spawn file
	// action, and there is no file action for TIOCSCTTY either. Without a ctty
	// the pty has no foreground process group, which silently kills SIGWINCH,
	// tty-generated ^C/^Z, /dev/tty, and job control while leaving the shell
	// looking healthy. TextMatePTYHelper is therefore spawned in the shell’s
	// place, does that setup as the new session leader, and execs the shell —
	// same pid, session, group and pty, so everything below still tracks the
	// shell itself.
	std::string const& helperPath = helper_path();
	if(helperPath.empty())
	{
		fprintf(stderr, "PTYController: no TextMatePTYHelper beside the running executable\n");
		return NO;
	}

	std::string argv0 = _path.substr(_path.rfind('/') == std::string::npos ? 0 : _path.rfind('/') + 1);
	if(_loginShell)
		argv0 = "-" + argv0;

	// Fixed positional ABI: helper name, working directory, target executable,
	// then the target’s own argv. Nothing is quoted, parsed, or flattened into
	// a command line on the way.
	std::vector<char*> argv;
	argv.push_back((char*)"TextMatePTYHelper");
	argv.push_back((char*)_workingDirectory.c_str());
	argv.push_back((char*)_path.c_str());
	argv.push_back((char*)argv0.c_str());
	for(auto const& argument : _arguments)
		argv.push_back((char*)argument.c_str());
	argv.push_back(NULL);

	std::vector<std::string> environmentStrings;
	for(auto const& pair : _environment)
		environmentStrings.push_back(pair.first + "=" + pair.second);
	std::vector<char*> envp;
	for(auto const& str : environmentStrings)
		envp.push_back((char*)str.c_str());
	envp.push_back(NULL);

	int master = -1, slave = -1;
	struct winsize windowSize = _windowSize;
	if(openpty(&master, &slave, NULL, NULL, &windowSize) != 0)
	{
		perror("PTYController: openpty");
		return NO;
	}

	// The master never crosses an exec: mark it close-on-exec before anything
	// else, or a spawn on another thread during the blocking handshake below
	// inherits a duplicate — a copy that outlives our own close keeps the pty
	// alive, deferring the session’s hangup and EOF indefinitely.
	int masterFlags = fcntl(master, F_GETFD);
	if(masterFlags == -1 || fcntl(master, F_SETFD, masterFlags | FD_CLOEXEC) == -1)
	{
		perror("PTYController: FD_CLOEXEC (pty master)");
		close(master);
		close(slave);
		return NO;
	}

	// Every descriptor the child inherits is first normalized to 10 or above:
	// the dup2 actions below can then never alias their own source, close a
	// standard stream, or carry an unexpected FD_CLOEXEC into the child.
	int slaveHigh = fcntl(slave, F_DUPFD_CLOEXEC, 10);
	int slaveError = errno;
	close(slave);
	if(slaveHigh == -1)
	{
		errno = slaveError;
		perror("PTYController: F_DUPFD_CLOEXEC (pty slave)");
		close(master);
		return NO;
	}

	// Startup handshake: the helper’s end is close-on-exec, so a successful
	// execve closes it without a byte. Darwin has no pipe2(O_CLOEXEC), hence
	// the same normalization dance — it also keeps the window in which another
	// thread’s spawn could inherit the raw ends as short as possible.
	int statusPipe[2] = { -1, -1 };
	if(pipe(statusPipe) != 0)
	{
		perror("PTYController: pipe");
		close(master);
		close(slaveHigh);
		return NO;
	}

	int statusReadHigh  = fcntl(statusPipe[0], F_DUPFD_CLOEXEC, 10);
	int statusWriteHigh = statusReadHigh == -1 ? -1 : fcntl(statusPipe[1], F_DUPFD_CLOEXEC, 10);
	int pipeError = errno;
	close(statusPipe[0]);
	close(statusPipe[1]);
	if(statusReadHigh == -1 || statusWriteHigh == -1)
	{
		errno = pipeError;
		perror("PTYController: F_DUPFD_CLOEXEC (status pipe)");
		close(master);
		close(slaveHigh);
		if(statusReadHigh != -1)
			close(statusReadHigh);
		return NO;
	}

	posix_spawnattr_t attr;
	if(int rc = posix_spawnattr_init(&attr); rc != 0)
	{
		errno = rc;
		perror("PTYController: posix_spawnattr_init");
		close(master);
		close(slaveHigh);
		close(statusReadHigh);
		close(statusWriteHigh);
		return NO;
	}

	// Every setter and file action below returns an error number instead of
	// touching errno, and a failed one leaves the list without its entry while
	// posix_spawn itself still succeeds — silently missing signal state, a
	// mis-wired descriptor table, or a helper with no fd to report through. The
	// first failure therefore has to stop the spawn.
	sigset_t allSignals, noSignals;
	sigfillset(&allSignals);
	sigemptyset(&noSignals);
	int rc = posix_spawnattr_setsigdefault(&attr, &allSignals);
	if(rc == 0)
		rc = posix_spawnattr_setsigmask(&attr, &noSignals);
	if(rc == 0)
		rc = posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETSID | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT);
	if(rc != 0)
	{
		errno = rc;
		perror("PTYController: posix_spawnattr setup");
		posix_spawnattr_destroy(&attr);
		close(master);
		close(slaveHigh);
		close(statusReadHigh);
		close(statusWriteHigh);
		return NO;
	}

	posix_spawn_file_actions_t actions;
	if(int rc = posix_spawn_file_actions_init(&actions); rc != 0)
	{
		errno = rc;
		perror("PTYController: posix_spawn_file_actions_init");
		posix_spawnattr_destroy(&attr);
		close(master);
		close(slaveHigh);
		close(statusReadHigh);
		close(statusWriteHigh);
		return NO;
	}

	// Order matters: 1 and 2 are duplicated from the slave already installed on
	// 0, and each high source is closed explicitly rather than left to
	// POSIX_SPAWN_CLOEXEC_DEFAULT, which says nothing about descriptors the
	// file actions themselves mention. No chdir action — the helper owns the
	// working directory, including its fallback.
	rc = posix_spawn_file_actions_adddup2(&actions, slaveHigh, 0);
	if(rc == 0)
		rc = posix_spawn_file_actions_adddup2(&actions, 0, 1);
	if(rc == 0)
		rc = posix_spawn_file_actions_adddup2(&actions, 0, 2);
	if(rc == 0)
		rc = posix_spawn_file_actions_addclose(&actions, slaveHigh);
	if(rc == 0)
		rc = posix_spawn_file_actions_adddup2(&actions, statusWriteHigh, pty_helper_status_fd);
	if(rc == 0)
		rc = posix_spawn_file_actions_addclose(&actions, statusReadHigh);
	if(rc == 0)
		rc = posix_spawn_file_actions_addclose(&actions, statusWriteHigh);
	if(rc != 0)
	{
		errno = rc;
		perror("PTYController: posix_spawn_file_actions setup");
		posix_spawn_file_actions_destroy(&actions);
		posix_spawnattr_destroy(&attr);
		close(master);
		close(slaveHigh);
		close(statusReadHigh);
		close(statusWriteHigh);
		return NO;
	}

	pid_t pid = -1;
	rc = posix_spawn(&pid, helperPath.c_str(), &actions, &attr, argv.data(), envp.data());

	posix_spawn_file_actions_destroy(&actions);
	posix_spawnattr_destroy(&attr);
	close(slaveHigh);
	close(statusWriteHigh); // the parent must not hold the write end open, or the read below never sees EOF

	if(rc != 0)
	{
		errno = rc;
		perror("PTYController: posix_spawn");
		close(master);
		close(statusReadHigh);
		return NO;
	}

	// A helper killed before it can report also yields a bare EOF, so success
	// here is “the target execve’d, or died in a way it could not describe”.
	// The immediate-exit detection below turns the latter into “the shell
	// exited at once” rather than a phantom session; distinguishing the two
	// would need a positive acknowledgement that still cannot cover the last
	// instruction before execve.
	struct pty_helper_error_t record;
	int handshake = read_helper_status(statusReadHigh, &record);
	close(statusReadHigh);

	if(handshake != 0)
	{
		if(handshake < 0)
		{
			perror("PTYController: helper handshake");
			// Nothing is known about the child — it may still be running with a
			// live pty — so take the whole spawned group down before reaping.
			killpg(pid, SIGKILL);
		}
		else
		{
			char message[256];
			snprintf(message, sizeof(message), "PTYController: helper: %s", pty_helper_stage_name(record.stage));
			errno = record.error_number;
			perror(message);
		}

		// Before the wait, not after: a session leader that leaves anything in
		// the pty’s output queue blocks in exit until the queue drains, and once
		// startup has failed nobody will ever read the master. Closing it first
		// releases that wait, so the reap below cannot become a deadlock.
		close(master);

		int status = 0;
		reap_child(pid, &status, 0);
		return NO;
	}

	// Only now, with a shell known to be running: publishing the pid earlier
	// would let -shutdown race a half-initialized controller and mix startup
	// cleanup into the normal exit path.
	_processIdentifier = pid;
	_masterFD = master;
	fcntl(_masterFD, F_SETFL, fcntl(_masterFD, F_GETFL) | O_NONBLOCK); // FD_CLOEXEC is set right after openpty

	__weak PTYController* weakSelf = self;

	_readSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, _masterFD, 0, _readQueue);
	dispatch_source_set_event_handler(_readSource, ^{
		[weakSelf drainAvailableOutput];
	});
	dispatch_resume(_readSource);

	// The handshake widens the gap between the spawn and this registration, so
	// a short-lived target can be a zombie before the source exists. Rather
	// than depend on EVFILT_PROC's attach-to-zombie behavior alone, peek with a
	// non-consuming waitid twice: once here after the resume, and once from the
	// registration handler, which runs after the source is actually registered
	// and therefore covers the activation interval. -handleProcessExit is
	// idempotent, so whichever path arrives first wins and the others are
	// no-ops. (The registration handler runs on _readQueue, like the event
	// handler.)
	_processSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC, pid, DISPATCH_PROC_EXIT, _readQueue);
	dispatch_source_set_event_handler(_processSource, ^{
		[weakSelf handleProcessExit];
	});
	dispatch_source_set_registration_handler(_processSource, ^{
		if(child_did_exit(pid))
			[weakSelf handleProcessExit];
	});
	dispatch_resume(_processSource);

	if(child_did_exit(pid))
	{
		dispatch_async(_readQueue, ^{
			[weakSelf handleProcessExit];
		});
	}

	return YES;
}

// Runs on _readQueue.
- (void)drainAvailableOutput
{
	if(_masterFD == -1)
		return;

	char buffer[32768];
	while(true)
	{
		ssize_t len = read(_masterFD, buffer, sizeof(buffer));
		if(len > 0)
		{
			if(_readHandler)
				_readHandler(buffer, len);
		}
		else if(len == -1 && errno == EINTR)
		{
			continue;
		}
		else if(len == -1 && errno == EAGAIN)
		{
			break;
		}
		else // EOF, or EIO after the child exited
		{
			if(_readSource)
			{
				dispatch_source_cancel(_readSource);
				_readSource = nil;
			}
			break;
		}
	}
}

// Runs on _readQueue.
- (void)handleProcessExit
{
	// The process source is not the only way in: the two waitid peeks in -spawn
	// cover an exit that happened before the source was registered, and the
	// source can still deliver its event afterwards. They all run on _readQueue,
	// so one flag makes the reap — and above all _exitHandler — happen once.
	if(_didHandleProcessExit)
		return;
	_didHandleProcessExit = YES;

	[self drainAvailableOutput];

	// DISPATCH_PROC_EXIT means the child has exited, but not that it is already
	// reapable without blocking: the notification can beat the zombie becoming
	// visible to waitpid, so a one-shot WNOHANG can return 0 — losing the status
	// and leaking the zombie forever, since this handler fires only once. A
	// blocking wait cannot hang here: the child is either already a zombie (waitpid
	// returns immediately) or was reaped by -shutdown (immediate -1/ECHILD).
	// waitpid is also interruptible, which reap_child absorbs.
	//
	// -shutdown may have reaped and cleared _processIdentifier before this
	// already-in-flight handler runs (dispatch_source_cancel does not stop it), so
	// take a snapshot and never pass a non-positive pid: waitpid(-1, …) waits for
	// *any* child and would silently reap an unrelated child of TextMate.
	pid_t pid = _processIdentifier;
	int status = 0;
	if(pid > 0)
	{
		if(reap_child(pid, &status, 0) != pid)
			status = -1;
	}
	else
	{
		status = -1;
	}
	_processIdentifier = -1;

	if(_processSource)
	{
		dispatch_source_cancel(_processSource);
		_processSource = nil;
	}

	if(_exitHandler)
		_exitHandler(status);
}

- (void)writeData:(NSData*)data
{
	if(!data.length)
		return;

	dispatch_async(_writeQueue, ^{
		if(self->_masterFD == -1)
			return;

		char const* bytes = (char const*)data.bytes;
		size_t remaining = data.length;
		int stalls = 0;
		while(remaining > 0 && self->_masterFD != -1)
		{
			ssize_t written = write(self->_masterFD, bytes, remaining);
			if(written > 0)
			{
				bytes += written;
				remaining -= written;
				stalls = 0;
			}
			else if(written == -1 && errno == EINTR)
			{
				continue;
			}
			else if(written == -1 && errno == EAGAIN)
			{
				// Give the child a moment to drain; drop under sustained
				// back-pressure like other terminal emulators do.
				if(++stalls > 20)
					break;
				struct pollfd pfd = { .fd = self->_masterFD, .events = POLLOUT };
				poll(&pfd, 1, 100);
			}
			else
			{
				break;
			}
		}
	});
}

- (void)resizeToColumns:(NSUInteger)columns rows:(NSUInteger)rows pixelWidth:(NSUInteger)pixelWidth pixelHeight:(NSUInteger)pixelHeight
{
	_windowSize = (struct winsize){ .ws_row = (unsigned short)rows, .ws_col = (unsigned short)columns, .ws_xpixel = (unsigned short)pixelWidth, .ws_ypixel = (unsigned short)pixelHeight };
	if(_masterFD != -1)
		ioctl(_masterFD, TIOCSWINSZ, &_windowSize);
}

- (void)shutdown
{
	if(_didShutdown)
		return;
	_didShutdown = YES;

	pid_t pid = _processIdentifier;
	if(pid > 0)
		killpg(pid, SIGHUP);

	if(_readSource)
	{
		dispatch_source_cancel(_readSource);
		_readSource = nil;
	}
	if(_processSource)
	{
		dispatch_source_cancel(_processSource);
		_processSource = nil;
	}

	int fd = _masterFD;
	_masterFD = -1;
	if(fd != -1)
	{
		// Barrier so in-flight read/write blocks observe the closed fd only
		// after they finish, then close outside their loops. Skip the barrier
		// for the queue we are currently running on (dealloc can happen
		// inside a source handler): that queue is quiesced by construction.
		if(dispatch_get_specific(kPTYReadQueueIdentityKey) != (__bridge void*)self)
			dispatch_sync(_readQueue, ^{ });
		if(dispatch_get_specific(kPTYWriteQueueIdentityKey) != (__bridge void*)self)
			dispatch_sync(_writeQueue, ^{ });
		close(fd);
	}

	// The sources are cancelled and the read queue drained above, so this is the
	// last chance to reap: nothing waits for the child afterwards. Each rung of
	// the ladder therefore has to act on a definitive answer, which is what
	// reap_child guarantees — a raw waitpid returning -1/EINTR would end the
	// ladder exactly like the ECHILD (already reaped by -handleProcessExit) case
	// it must skip on, leaving a zombie or even a live child behind.
	if(pid > 0)
	{
		int status = 0;
		if(reap_child(pid, &status, WNOHANG) == 0)
		{
			usleep(50000);
			if(reap_child(pid, &status, WNOHANG) == 0)
			{
				killpg(pid, SIGKILL);
				reap_child(pid, &status, 0);
			}
		}
		_processIdentifier = -1;
	}
}
@end
