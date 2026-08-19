// TextMatePTYHelper — the trampoline TextMate spawns in place of the terminal’s
// shell.
//
// posix_spawn can create a session leader (POSIX_SPAWN_SETSID) but it cannot
// give that session a controlling terminal: Darwin does not apply the “first
// tty a session leader opens becomes its ctty” rule to the in-kernel open of a
// spawn file action, and there is no file action for TIOCSCTTY. A shell spawned
// that way owns a tty on 0/1/2 that has no foreground process group, which
// kills SIGWINCH, tty-generated ^C/^Z, /dev/tty, and job control. forkpty did
// this initialization inside the child (login_tty); fork() cannot come back
// here, because it deadlocks the atfork handlers of a multithreaded app.
//
// So this executable is spawned instead, performs the initialization itself,
// and then execve()s the real target — keeping the pid, session, process group,
// and pty, so the parent still tracks the shell directly. It is a trampoline,
// never a supervisor.
//
// Deliberately libc/POSIX only: it runs between the spawn and the user’s shell,
// so every library it would load is startup cost and audit surface.

#include "PTYHelperProtocol.h"

#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <unistd.h>

extern char** environ;

// Reports why startup failed and leaves. Best effort by design: the parent
// treats a truncated or absent record as a failure regardless, and there is
// nowhere to report a failure to report one. _exit avoids running atexit
// handlers of a process that is only half itself.
static void report_and_exit (uint16_t stage, int errorNumber) __attribute__((noreturn));

static void report_and_exit (uint16_t stage, int errorNumber)
{
	struct pty_helper_error_t record;
	record.magic        = pty_helper_magic;
	record.version      = pty_helper_version;
	record.stage        = stage;
	record.error_number = errorNumber;

	char const* bytes = (char const*)&record;
	size_t remaining  = sizeof(record);
	while(remaining > 0)
	{
		ssize_t written = write(pty_helper_status_fd, bytes, remaining);
		if(written > 0)
		{
			bytes     += written;
			remaining -= (size_t)written;
		}
		else if(written == -1 && errno == EINTR)
		{
			continue;
		}
		else
		{
			break;
		}
	}
	_exit(127);
}

int main (int argc, char* argv[])
{
	// Before anything that can fail: a successful execve has to close fd 3 for
	// the parent to see the zero-byte EOF that means “the shell is running”.
	int statusFlags = fcntl(pty_helper_status_fd, F_GETFD);
	if(statusFlags == -1 || fcntl(pty_helper_status_fd, F_SETFD, statusFlags | FD_CLOEXEC) == -1)
	{
		int error = errno;
		report_and_exit(pty_helper_stage_status_fd_setup, error);
	}

	if(argc < 4)
		report_and_exit(pty_helper_stage_invalid_arguments, EINVAL);

	// An early diagnostic only — owning a tty on 0/1/2 is exactly what does not
	// imply having it as a controlling terminal.
	if(fcntl(STDIN_FILENO, F_GETFD) == -1 || fcntl(STDOUT_FILENO, F_GETFD) == -1 || fcntl(STDERR_FILENO, F_GETFD) == -1)
	{
		int error = errno;
		report_and_exit(pty_helper_stage_invalid_standard_streams, error);
	}
	if(!isatty(STDIN_FILENO))
	{
		int error = errno;
		report_and_exit(pty_helper_stage_invalid_standard_streams, error ? error : ENOTTY);
	}

	// POSIX_SPAWN_SETSID must already have made us the leader of a new session
	// and process group. If it did not, the terminal setup below would attach
	// the wrong session — fail instead of papering over it with a setsid.
	pid_t pid = getpid();
	pid_t sid = getsid(0);
	if(sid != pid || getpgrp() != pid)
	{
		int error = sid == -1 ? errno : EPERM;
		report_and_exit(pty_helper_stage_invalid_session_state, error);
	}

	// The operation login_tty performed, and the whole reason this executable
	// exists: make the inherited pty this session’s controlling terminal.
	while(ioctl(STDIN_FILENO, TIOCSCTTY, 0) == -1)
	{
		if(errno == EINTR)
			continue;
		int error = errno;
		report_and_exit(pty_helper_stage_acquire_controlling_terminal, error);
	}

	while(tcsetpgrp(STDIN_FILENO, getpgrp()) == -1)
	{
		if(errno == EINTR)
			continue;
		int error = errno;
		report_and_exit(pty_helper_stage_set_foreground_process_group, error);
	}

	// Turns a silently incomplete setup into a startup failure: without a
	// foreground process group the kernel has nowhere to deliver SIGWINCH or
	// tty-generated signals, and the shell would look healthy while behaving
	// like a pipe.
	pid_t foreground = tcgetpgrp(STDIN_FILENO);
	if(foreground == -1)
	{
		int error = errno;
		report_and_exit(pty_helper_stage_set_foreground_process_group, error);
	}
	if(foreground != getpgrp())
		report_and_exit(pty_helper_stage_set_foreground_process_group, EPERM);

	// Proves the session is usable as an interactive terminal, which is what
	// sudo, ssh, and every other /dev/tty user needs. Close-on-exec so the only
	// descriptors the target inherits are its standard streams.
	int ctty;
	while((ctty = open("/dev/tty", O_RDWR | O_CLOEXEC)) == -1)
	{
		if(errno == EINTR)
			continue;
		int error = errno;
		report_and_exit(pty_helper_stage_open_controlling_terminal_alias, error);
	}
	close(ctty);

	// The forkpty child fell back to "/" on any chdir failure, and a bad working
	// directory must keep opening the terminal rather than fail it. No up-front
	// test can replace trying: stat() only needs traversal of the parent path
	// while chdir() needs search permission on the target itself (a 0600
	// directory stats fine yet cannot be entered), and the directory can be
	// removed or unmounted at any point before the call.
	if(chdir(argv[1]) != 0)
	{
		if(chdir("/") != 0)
		{
			int error = errno;
			report_and_exit(pty_helper_stage_change_to_fallback_directory, error);
		}
	}

	execve(argv[2], &argv[3], environ);

	int error = errno;
	report_and_exit(pty_helper_stage_exec_target, error);
	return 127; // not reached
}
