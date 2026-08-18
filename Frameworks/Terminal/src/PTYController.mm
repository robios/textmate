#import "PTYController.h"
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

// The pgid of whatever currently owns the terminal. The shell was made a
// session leader by POSIX_SPAWN_SETSID, so its pgid equals its pid; any
// foreground job therefore shows up as a pgid different from _processIdentifier.
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

	std::string argv0 = _path.substr(_path.rfind('/') == std::string::npos ? 0 : _path.rfind('/') + 1);
	if(_loginShell)
		argv0 = "-" + argv0;

	std::vector<char*> argv;
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

	// posix_spawn instead of forkpty: fork() in a multithreaded process
	// deadlocks the atfork prepare handlers against allocator locks held on
	// other threads (fatal under ASan, whose spin locks then burn CPU). The
	// child becomes a session leader via POSIX_SPAWN_SETSID and acquires the
	// pty as its controlling terminal by opening the slave by path — the
	// first tty opened by a session leader without one becomes its
	// controlling terminal, which is what login_tty relied on TIOCSCTTY for.
	int master = -1, slave = -1;
	struct winsize windowSize = _windowSize;
	if(openpty(&master, &slave, NULL, NULL, &windowSize) != 0)
	{
		perror("PTYController: openpty");
		return NO;
	}

	char slavePath[PATH_MAX];
	if(int rc = ttyname_r(slave, slavePath, sizeof(slavePath)); rc != 0)
	{
		errno = rc;
		perror("PTYController: ttyname_r");
		close(master);
		close(slave);
		return NO;
	}

	posix_spawnattr_t attr;
	posix_spawnattr_init(&attr);
	sigset_t allSignals, noSignals;
	sigfillset(&allSignals);
	sigemptyset(&noSignals);
	posix_spawnattr_setsigdefault(&attr, &allSignals);
	posix_spawnattr_setsigmask(&attr, &noSignals);
	posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETSID | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT);

	// File actions cannot be edited once built, so each attempt makes its own.
	auto spawnInDirectory = [&](char const* workingDirectory, pid_t* pid){
		posix_spawn_file_actions_t actions;
		posix_spawn_file_actions_init(&actions);
		posix_spawn_file_actions_addopen(&actions, 0, slavePath, O_RDWR, 0);
		posix_spawn_file_actions_adddup2(&actions, 0, 1);
		posix_spawn_file_actions_adddup2(&actions, 0, 2);
		posix_spawn_file_actions_addchdir_np(&actions, workingDirectory);
		int rc = posix_spawn(pid, _path.c_str(), &actions, &attr, argv.data(), envp.data());
		posix_spawn_file_actions_destroy(&actions);
		return rc;
	};

	// A failing addchdir_np fails the entire spawn, and no up-front test can
	// predict it: stat() only needs traversal of the parent path while chdir()
	// needs search permission on the target itself (a 0600 directory stats fine
	// yet cannot be entered), and the directory can be removed or unmounted
	// between the check and the spawn. Retry from "/" instead — the forkpty
	// child fell back to chdir("/") on any chdir failure, so a bad working
	// directory has to keep opening the terminal rather than fail it. Pre-opening
	// a directory fd for fchdir would not do: open(O_RDONLY) needs read
	// permission, which chdir does not.
	pid_t pid = -1;
	int rc = spawnInDirectory(_workingDirectory.c_str(), &pid);
	if(rc != 0 && _workingDirectory != "/")
		rc = spawnInDirectory("/", &pid);

	posix_spawnattr_destroy(&attr);
	close(slave);

	if(rc != 0)
	{
		errno = rc;
		perror("PTYController: posix_spawn");
		close(master);
		return NO;
	}

	_processIdentifier = pid;
	_masterFD = master;
	fcntl(_masterFD, F_SETFL, fcntl(_masterFD, F_GETFL) | O_NONBLOCK);
	fcntl(_masterFD, F_SETFD, FD_CLOEXEC);

	__weak PTYController* weakSelf = self;

	_readSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, _masterFD, 0, _readQueue);
	dispatch_source_set_event_handler(_readSource, ^{
		[weakSelf drainAvailableOutput];
	});
	dispatch_resume(_readSource);

	_processSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC, pid, DISPATCH_PROC_EXIT, _readQueue);
	dispatch_source_set_event_handler(_processSource, ^{
		[weakSelf handleProcessExit];
	});
	dispatch_resume(_processSource);

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
