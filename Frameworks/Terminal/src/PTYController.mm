#import "PTYController.h"
#include <util.h>

// Queue-identity keys: our final release can happen inside a dispatch-source
// handler (making dealloc → shutdown run on the read or write queue), and a
// dispatch_sync onto the queue we are standing on aborts. Tag the queues so
// shutdown can skip the barrier that would target its own queue.
static void* const kPTYReadQueueIdentityKey  = (void*)&kPTYReadQueueIdentityKey;
static void* const kPTYWriteQueueIdentityKey = (void*)&kPTYWriteQueueIdentityKey;
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <unistd.h>

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

	int master = -1;
	struct winsize windowSize = _windowSize;
	pid_t pid = forkpty(&master, NULL, NULL, &windowSize);
	if(pid == -1)
	{
		perror("PTYController: forkpty");
		return NO;
	}

	if(pid == 0) // child
	{
		int const signals[] = { SIGINT, SIGQUIT, SIGTERM, SIGPIPE, SIGUSR1, SIGCHLD, SIGHUP };
		for(int sig : signals)
			signal(sig, SIG_DFL);
		sigset_t set;
		sigemptyset(&set);
		sigprocmask(SIG_SETMASK, &set, NULL);

		if(chdir(_workingDirectory.c_str()) != 0)
			chdir("/");

		execve(_path.c_str(), argv.data(), envp.data());
		perror("PTYController: execve");
		_exit(127);
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

	int status = 0;
	if(waitpid(_processIdentifier, &status, WNOHANG) != _processIdentifier)
		status = -1;
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

	if(pid > 0)
	{
		int status = 0;
		if(waitpid(pid, &status, WNOHANG) == 0)
		{
			usleep(50000);
			if(waitpid(pid, &status, WNOHANG) == 0)
			{
				killpg(pid, SIGKILL);
				waitpid(pid, &status, 0);
			}
		}
		_processIdentifier = -1;
	}
}
@end
