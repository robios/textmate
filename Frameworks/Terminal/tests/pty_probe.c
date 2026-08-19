// tm_pty_probe — the process the PTYController tests spawn in place of a shell.
//
// A shell is a poor witness for terminal setup: it reacts to the very state
// under test (a non-interactive sh does not die from ^C while a foreground
// child runs, an interactive one rearranges process groups behind the test),
// and everything it can report has to be scraped back out of `ps` or `stty`
// output. This probe instead prints exactly what the tests need to assert, as
// one-line records
//
//    PROBE <key> <value>
//
// where the value is the rest of the line. Modes that wait for something print
// their “ready” record only once their signal handlers and terminal modes are
// installed, so the tests can drive the pty off a record instead of a sleep.
//
// Test-only by construction: none of this belongs in the production trampoline
// (../helper/TextMatePTYHelper.c), which must stay the shortest possible line
// of syscalls between the spawn and the user’s shell.
//
// Every mode that blocks arms an alarm first. Its default disposition kills the
// probe, so a broken invariant fails a test — and leaves nothing behind — even
// if the test itself is what stopped waiting.

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>

enum { kProbeTimeoutSeconds = 30 };

static void record (char const* format, ...) __attribute__((format(printf, 1, 2)));

// One record, one write: the tests parse whole lines, and stdio buffering plus
// a signal-interrupted flush is not worth the risk for a few dozen bytes.
static void record (char const* format, ...)
{
	char buffer[2048];

	va_list ap;
	va_start(ap, format);
	int len = vsnprintf(buffer, sizeof(buffer) - 1, format, ap);
	va_end(ap);

	if(len < 0)
		return;
	if(len > (int)sizeof(buffer) - 2)
		len = (int)sizeof(buffer) - 2;
	buffer[len++] = '\n';

	char const* bytes = buffer;
	size_t remaining  = (size_t)len;
	while(remaining > 0)
	{
		ssize_t written = write(STDOUT_FILENO, bytes, remaining);
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
}

// The tests type control characters (^C, ^Z) at this process. Echo would put
// them back into the same stream the tests parse records from, ahead of
// whatever is printed next. ISIG is untouched — being signalled is the point.
static void disable_echo (void)
{
	struct termios attributes;
	if(tcgetattr(STDIN_FILENO, &attributes) == 0)
	{
		attributes.c_lflag &= ~(tcflag_t)(ECHO | ECHOE | ECHOK | ECHONL | ECHOCTL);
		tcsetattr(STDIN_FILENO, TCSANOW, &attributes);
	}
}

// Everything the controlling-terminal, /dev/tty, argv, environment, and working
// directory tests need, in one pass, followed by an “end” record they can wait
// for rather than racing the individual fields.
static int mode_state (char* argv[])
{
	record("PROBE pid %d", (int)getpid());
	record("PROBE sid %d", (int)getsid(0));
	record("PROBE pgid %d", (int)getpgrp());
	record("PROBE tpgid %d", (int)tcgetpgrp(STDIN_FILENO));

	int tty      = open("/dev/tty", O_RDWR);
	int ttyError = errno;
	if(tty != -1)
	{
		close(tty);
		record("PROBE devtty ok");
	}
	else
	{
		record("PROBE devtty errno %d", ttyError);
	}

	char directory[PATH_MAX];
	record("PROBE cwd %s", getcwd(directory, sizeof(directory)) ? directory : "(error)");
	record("PROBE argv0 %s", argv[0]);

	char const* sentinel = getenv("TM_PTY_PROBE_SENTINEL");
	record("PROBE sentinel %s", sentinel ? sentinel : "(unset)");

	record("PROBE end state");
	return 0;
}

static volatile sig_atomic_t receivedWinch;

static void handle_winch (int signo)
{
	(void)signo;
	receivedWinch = 1;
}

// SIGWINCH is delivered by the kernel to the terminal’s foreground process
// group, so receiving one at all is the assertion; the size that comes with it
// is the second half of it.
static int mode_winch (void)
{
	struct sigaction action;
	memset(&action, 0, sizeof(action));
	action.sa_handler = handle_winch;
	sigemptyset(&action.sa_mask);
	if(sigaction(SIGWINCH, &action, NULL) == -1)
	{
		record("PROBE error sigaction %d", errno);
		return 1;
	}

	// Blocked outside sigsuspend, so a SIGWINCH that arrives between the test
	// below and the wait cannot be missed.
	sigset_t blocked, unblocked;
	sigemptyset(&blocked);
	sigaddset(&blocked, SIGWINCH);
	sigprocmask(SIG_BLOCK, &blocked, NULL);
	sigemptyset(&unblocked);

	struct winsize size;
	if(ioctl(STDIN_FILENO, TIOCGWINSZ, &size) == -1)
	{
		record("PROBE error initial-winsize %d", errno);
		return 1;
	}
	record("PROBE initial-winsize %u %u", (unsigned)size.ws_col, (unsigned)size.ws_row);

	// Only now: the test resizes the pty the moment it sees this.
	record("PROBE ready winch");

	alarm(kProbeTimeoutSeconds);
	while(!receivedWinch)
		sigsuspend(&unblocked);
	alarm(0);

	if(ioctl(STDIN_FILENO, TIOCGWINSZ, &size) == -1)
	{
		record("PROBE error winsize %d", errno);
		return 1;
	}

	record("PROBE sigwinch %d", (int)receivedWinch);
	record("PROBE winsize %u %u", (unsigned)size.ws_col, (unsigned)size.ws_row);
	record("PROBE end winch");
	return 0;
}

// Nothing is installed for SIGINT on purpose: this process must die from the
// tty-generated signal itself, which is what the test reads out of the raw wait
// status. (A `sh -c` target cannot show that — a non-interactive shell survives
// SIGINT and only its foreground child dies.)
static int mode_sigint (void)
{
	disable_echo();
	record("PROBE ready sigint");

	alarm(kProbeTimeoutSeconds);
	for(;;)
		pause();
	return 0;
}

// Real job control in miniature: a second process group is put into the
// foreground, stopped by ^Z typed at the terminal, and the terminal is then
// reclaimed — the sequence a shell performs, minus the shell.
static int mode_job_control (void)
{
	disable_echo();

	// Reclaiming the terminal below happens from a background process group,
	// and tcsetpgrp raises SIGTTOU on the caller in exactly that position.
	signal(SIGTTOU, SIG_IGN);

	int ready[2];
	if(pipe(ready) == -1)
	{
		record("PROBE error pipe %d", errno);
		return 1;
	}

	record("PROBE shell-pgid %d", (int)getpgrp());

	pid_t child = fork();
	if(child == -1)
	{
		record("PROBE error fork %d", errno);
		return 1;
	}

	if(child == 0)
	{
		close(ready[0]);
		setpgid(0, 0); // also done by the parent — whichever runs first wins the race
		alarm(kProbeTimeoutSeconds);

		char const byte = 'r';
		while(write(ready[1], &byte, 1) == -1 && errno == EINTR)
			continue;
		close(ready[1]);

		// Default SIGTSTP disposition: the ^Z the test types stops this process,
		// and the parent kills it once the handoff has been observed.
		for(;;)
			pause();
		_exit(0);
	}

	close(ready[1]);
	setpgid(child, child);

	char byte = 0;
	while(read(ready[0], &byte, 1) == -1 && errno == EINTR)
		continue;
	close(ready[0]);

	alarm(kProbeTimeoutSeconds);

	if(tcsetpgrp(STDIN_FILENO, child) == -1)
	{
		record("PROBE error tcsetpgrp %d", errno);
		kill(child, SIGKILL);
		while(waitpid(child, NULL, 0) == -1 && errno == EINTR)
			continue;
		return 1;
	}
	record("PROBE job-pgid %d", (int)child);

	// The terminal’s own answer rather than the pid just handed to tcsetpgrp:
	// what the test asserts is that the pty’s foreground group followed the
	// handoff, and only the tty can say that. (Its master end reports the same
	// value, but is private to the controller.)
	record("PROBE foreground %d", (int)tcgetpgrp(STDIN_FILENO));

	int status = 0;
	pid_t waited;
	while((waited = waitpid(child, &status, WUNTRACED)) == -1 && errno == EINTR)
		continue;
	if(waited != child || !WIFSTOPPED(status))
	{
		record("PROBE error stopped %d", status);
		kill(child, SIGKILL);
		return 1;
	}
	record("PROBE stopped %d", WSTOPSIG(status));

	if(tcsetpgrp(STDIN_FILENO, getpgrp()) == -1)
	{
		record("PROBE error reclaim %d", errno);
		kill(child, SIGKILL);
		return 1;
	}

	// Again the terminal’s answer, which also keeps the assertion independent of
	// how long the probe lives after printing it.
	record("PROBE restored %d", (int)tcgetpgrp(STDIN_FILENO));

	kill(child, SIGKILL); // a stopped process still dies from SIGKILL
	while(waitpid(child, NULL, 0) == -1 && errno == EINTR)
		continue;
	alarm(0);

	record("PROBE end job-control");
	return 0;
}

// For the shutdown ladder: SIGHUP cannot end this process, so the WNOHANG rungs
// must fall through to SIGKILL. pause() also ignores the pty EOF that follows
// the master being closed, which a shell loop would not.
static int mode_ignore_hup (void)
{
	signal(SIGHUP, SIG_IGN);
	record("PROBE ready ignore-hup");

	alarm(kProbeTimeoutSeconds);
	for(;;)
		pause();
	return 0;
}

int main (int argc, char* argv[])
{
	char const* mode = argc > 1 ? argv[1] : "";

	if(strcmp(mode, "state") == 0)
		return mode_state(argv);
	if(strcmp(mode, "winch") == 0)
		return mode_winch();
	if(strcmp(mode, "sigint") == 0)
		return mode_sigint();
	if(strcmp(mode, "job-control") == 0)
		return mode_job_control();
	if(strcmp(mode, "ignore-hup") == 0)
		return mode_ignore_hup();

	// Deliberately silent: the fast-exit test spawns this to lose the race
	// between the startup handshake and the process source, and anything left
	// in the pty’s output queue would only add a variable to it.
	if(strcmp(mode, "exit") == 0)
		_exit(argc > 2 ? atoi(argv[2]) : 0);

	record("PROBE error unknown-mode %s", mode);
	return 2;
}
