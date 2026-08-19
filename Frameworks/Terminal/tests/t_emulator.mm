#import <Terminal/TerminalEmulator.h>
#import <Terminal/PTYController.h>
#import <Terminal/PTYHelperProtocol.h>
#include <chrono>
#include <condition_variable>
#include <errno.h>
#include <libproc.h>
#include <mach-o/dyld.h>
#include <mutex>
#include <set>
#include <signal.h>
#include <sys/wait.h>

static std::string screen_text (TerminalEmulator* emulator)
{
	__block std::string res;
	[emulator synchronizeRenderState];
	[emulator enumerateRowsClearingDirty:NO usingBlock:^(NSUInteger row, BOOL dirty, terminal_cell_t const* cells, NSUInteger cellCount){
		for(NSUInteger i = 0; i < cellCount; ++i)
			res.append(cells[i].text, cells[i].textLen);
		res += '\n';
	}];
	return res;
}

void test_vt_text_and_styles ()
{
	TerminalEmulator* emulator = [[TerminalEmulator alloc] initWithColumns:80 rows:24 maxScrollback:1000];
	OAK_ASSERT(emulator);

	char const* input = "hello \x1b[1;31mred\x1b[0m plain";
	[emulator feedBytes:input length:strlen(input)];

	std::string text = screen_text(emulator);
	OAK_ASSERT_NE(text.find("hello red plain"), std::string::npos);

	__block bool sawBoldStyledCell = false;
	[emulator synchronizeRenderState];
	[emulator enumerateRowsClearingDirty:NO usingBlock:^(NSUInteger row, BOOL dirty, terminal_cell_t const* cells, NSUInteger cellCount){
		if(row != 0)
			return;
		for(NSUInteger i = 0; i < cellCount; ++i)
		{
			if(cells[i].textLen == 1 && cells[i].text[0] == 'r' && cells[i].bold && cells[i].hasForeground)
				sawBoldStyledCell = true;
		}
	}];
	OAK_ASSERT(sawBoldStyledCell);

	struct terminal_cursor_t cursor = [emulator cursor];
	OAK_ASSERT(cursor.hasPosition);
	OAK_ASSERT_EQ(cursor.y, 0);
	OAK_ASSERT_EQ(cursor.x, strlen("hello red plain"));
}

void test_resize_reflow ()
{
	TerminalEmulator* emulator = [[TerminalEmulator alloc] initWithColumns:40 rows:10 maxScrollback:1000];
	char const* input = "aaaaaaaaaabbbbbbbbbbccccccccccdddddddddd"; // exactly 40 columns
	[emulator feedBytes:input length:strlen(input)];

	[emulator resizeToColumns:20 rows:10 cellWidth:8 cellHeight:16];
	[emulator synchronizeRenderState];
	OAK_ASSERT_EQ([emulator columns], 20);

	std::string text = screen_text(emulator);
	OAK_ASSERT_NE(text.find("aaaaaaaaaabbbbbbbbbb\nccccccccccdddddddddd"), std::string::npos);
}

void test_scrollback ()
{
	TerminalEmulator* emulator = [[TerminalEmulator alloc] initWithColumns:80 rows:10 maxScrollback:1000];
	for(int i = 0; i < 50; ++i)
	{
		char line[32];
		int len = snprintf(line, sizeof(line), "line %d\r\n", i);
		[emulator feedBytes:line length:len];
	}

	OAK_ASSERT([emulator viewportIsAtBottom]);
	struct terminal_scrollbar_t scrollbar = [emulator scrollbar];
	OAK_ASSERT(scrollbar.total > 10);

	[emulator scrollViewportBy:-25];
	OAK_ASSERT(![emulator viewportIsAtBottom]);
	std::string scrolled = screen_text(emulator);
	OAK_ASSERT_NE(scrolled.find("line 20"), std::string::npos);

	[emulator scrollViewportToBottom];
	OAK_ASSERT([emulator viewportIsAtBottom]);
	std::string bottom = screen_text(emulator);
	OAK_ASSERT_NE(bottom.find("line 49"), std::string::npos);
}

void test_key_encoding ()
{
	TerminalEmulator* emulator = [[TerminalEmulator alloc] initWithColumns:80 rows:24 maxScrollback:100];

	NSData* ctrlC = [emulator encodeKey:GHOSTTY_KEY_C action:GHOSTTY_KEY_ACTION_PRESS mods:GHOSTTY_MODS_CTRL consumedMods:0 text:nil unshiftedCodepoint:'c'];
	OAK_ASSERT_EQ(ctrlC.length, 1);
	OAK_ASSERT_EQ(((char const*)ctrlC.bytes)[0], '\x03');

	NSData* up = [emulator encodeKey:GHOSTTY_KEY_ARROW_UP action:GHOSTTY_KEY_ACTION_PRESS mods:0 consumedMods:0 text:nil unshiftedCodepoint:0];
	OAK_ASSERT_EQ(std::string((char const*)up.bytes, up.length), "\x1b[A");

	// DECCKM (application cursor keys) switches arrows to SS3 encoding
	char const* decckm = "\x1b[?1h";
	[emulator feedBytes:decckm length:strlen(decckm)];
	NSData* upApp = [emulator encodeKey:GHOSTTY_KEY_ARROW_UP action:GHOSTTY_KEY_ACTION_PRESS mods:0 consumedMods:0 text:nil unshiftedCodepoint:0];
	OAK_ASSERT_EQ(std::string((char const*)upApp.bytes, upApp.length), "\x1bOA");

	NSData* plain = [emulator encodeKey:GHOSTTY_KEY_A action:GHOSTTY_KEY_ACTION_PRESS mods:0 consumedMods:0 text:@"a" unshiftedCodepoint:'a'];
	OAK_ASSERT_EQ(std::string((char const*)plain.bytes, plain.length), "a");
}

void test_paste_encoding ()
{
	TerminalEmulator* emulator = [[TerminalEmulator alloc] initWithColumns:80 rows:24 maxScrollback:100];

	NSData* plain = [emulator encodePaste:@"ab\ncd"];
	OAK_ASSERT_EQ(std::string((char const*)plain.bytes, plain.length), "ab\rcd");

	char const* enable = "\x1b[?2004h";
	[emulator feedBytes:enable length:strlen(enable)];
	NSData* bracketed = [emulator encodePaste:@"ab\ncd"];
	std::string str((char const*)bracketed.bytes, bracketed.length);
	OAK_ASSERT_EQ(str.find("\x1b[200~"), 0);
	OAK_ASSERT_EQ(str.rfind("\x1b[201~"), str.size() - 6);
	OAK_ASSERT_NE(str.find("ab\ncd"), std::string::npos);
}

void test_query_write_back ()
{
	TerminalEmulator* emulator = [[TerminalEmulator alloc] initWithColumns:80 rows:24 maxScrollback:100];

	__block std::string response;
	emulator.writeToPTYHandler = ^(NSData* data){
		response.append((char const*)data.bytes, data.length);
	};

	char const* dsr = "\x1b[6n"; // cursor position report
	[emulator feedBytes:dsr length:strlen(dsr)];
	OAK_ASSERT_EQ(response, "\x1b[1;1R");
}

void test_selection_and_copy ()
{
	TerminalEmulator* emulator = [[TerminalEmulator alloc] initWithColumns:80 rows:24 maxScrollback:100];
	char const* input = "copy this text";
	[emulator feedBytes:input length:strlen(input)];

	OAK_ASSERT(![emulator hasSelection]);
	[emulator selectAll];
	OAK_ASSERT([emulator hasSelection]);

	NSString* copied = [emulator selectedString];
	OAK_ASSERT([copied rangeOfString:@"copy this text"].location != NSNotFound);

	[emulator clearSelection];
	OAK_ASSERT(![emulator hasSelection]);
}

// ---------------------------------------------------------------------------
// PTYController
//
// Most of what has to be true about a spawned terminal is only visible from
// inside the spawned process — which session it leads, whether the pty is its
// controlling terminal, whether the kernel delivers SIGWINCH and ^C to it. The
// tests below therefore spawn tm_pty_probe (tests/pty_probe.c) instead of a
// shell: it reports that state as “PROBE <key> <value>” lines and waits for the
// test to act, so every step is driven by a record rather than a delay. A shell
// is used only where the target being a shell is the point.
//
// Nothing here changes a signal disposition in this process: tests run
// concurrently on the runner’s threads, and one test’s handler would be every
// other test’s problem. Signals belong to the probe.

// Absolute path of the probe built beside the test runner, resolved the way
// PTYController resolves its helper, so both are found however the suite was
// started.
static std::string probe_path ()
{
	char executable[PATH_MAX], resolved[PATH_MAX];
	uint32_t size = sizeof(executable);
	if(_NSGetExecutablePath(executable, &size) != 0 || !realpath(executable, resolved))
		return std::string();

	std::string res(resolved);
	std::string::size_type slash = res.rfind('/');
	if(slash == std::string::npos)
		return std::string();
	res.erase(slash + 1);
	return res + "tm_pty_probe";
}

// Value of the first complete “PROBE <key> <value>” line. The prefix is
// searched for rather than anchored: the tty may put an echoed control
// character in front of it. A record counts only once its line is terminated,
// or a value could be read half-written.
static bool probe_record (std::string const& text, std::string const& key, std::string* out)
{
	std::string const prefix = "PROBE " + key + " ";
	for(size_t pos = text.find(prefix); pos != std::string::npos; pos = text.find(prefix, pos + 1))
	{
		size_t begin = pos + prefix.size();
		size_t end   = text.find('\n', begin);
		if(end == std::string::npos)
			continue;
		while(end > begin && (text[end-1] == '\r' || text[end-1] == '\n'))
			--end;
		if(out)
			*out = text.substr(begin, end - begin);
		return true;
	}
	return false;
}

// Collects a probe’s output and exit status, and lets the test block until a
// record or the exit arrives. The controller invokes both handlers on its own
// queue, so all of it is under one lock.
struct probe_session_t
{
	void collect (void const* bytes, size_t length)
	{
		std::lock_guard<std::mutex> lock(_mutex);
		_output.append((char const*)bytes, length);
		_condition.notify_all();
	}

	void collect_exit (int status)
	{
		std::lock_guard<std::mutex> lock(_mutex);
		_status = status;
		++_exitCount;
		_condition.notify_all();
	}

	// A probe that exits without printing the record ends the wait early: the
	// test then fails on the missing record instead of on the timeout.
	bool wait_for (std::string const& key, double seconds = 10)
	{
		std::unique_lock<std::mutex> lock(_mutex);
		_condition.wait_for(lock, std::chrono::duration<double>(seconds), [&]{ return probe_record(_output, key, NULL) || _exitCount != 0; });
		return probe_record(_output, key, NULL);
	}

	bool wait_for_exit (double seconds = 10)
	{
		std::unique_lock<std::mutex> lock(_mutex);
		return _condition.wait_for(lock, std::chrono::duration<double>(seconds), [&]{ return _exitCount != 0; });
	}

	std::string value (std::string const& key) const
	{
		std::lock_guard<std::mutex> lock(_mutex);
		std::string res;
		return probe_record(_output, key, &res) ? res : std::string();
	}

	long number (std::string const& key) const
	{
		std::string const res = value(key);
		return res.empty() ? -1 : strtol(res.c_str(), NULL, 10);
	}

	std::string text () const     { std::lock_guard<std::mutex> lock(_mutex); return _output; }
	int status () const           { std::lock_guard<std::mutex> lock(_mutex); return _status; }
	long exit_count () const      { std::lock_guard<std::mutex> lock(_mutex); return _exitCount; }

private:
	mutable std::mutex _mutex;
	std::condition_variable _condition;
	std::string _output;
	int _status  = 0;
	long _exitCount = 0;
};

static PTYController* probe_pty (std::shared_ptr<probe_session_t> const& session, std::vector<std::string> const& arguments, std::string const& workingDirectory = "/", BOOL loginShell = NO, std::map<std::string, std::string> const& extraEnvironment = { }, NSUInteger columns = 80, NSUInteger rows = 24)
{
	std::map<std::string, std::string> environment = { { "PATH", "/usr/bin:/bin" }, { "TERM", "xterm-256color" } };
	environment.insert(extraEnvironment.begin(), extraEnvironment.end());

	PTYController* pty = [[PTYController alloc] initWithPath:probe_path() arguments:arguments environment:environment workingDirectory:workingDirectory loginShell:loginShell columns:columns rows:rows pixelWidth:columns*8 pixelHeight:rows*16];
	pty.readHandler = ^(void const* bytes, size_t length){ session->collect(bytes, length); };
	pty.exitHandler = ^(int status){ session->collect_exit(status); };
	return pty;
}

// Children of ours that have exited and not been waited for. A zombie is still
// listed as a child but can no longer be described — proc_pidinfo fails on one,
// so there is no name to filter by — while waitid’s non-consuming peek reports
// the exit of exactly those pids, and consumes nothing another test is going to
// need. A reaped pid leaves the list altogether.
static std::set<pid_t> unreaped_children ()
{
	std::set<pid_t> res;

	int size = proc_listpids(PROC_PPID_ONLY, (uint32_t)getpid(), NULL, 0);
	if(size <= 0)
		return res;

	std::vector<pid_t> pids(size / sizeof(pid_t) + 8, 0);
	size = proc_listpids(PROC_PPID_ONLY, (uint32_t)getpid(), pids.data(), (int)(pids.size() * sizeof(pid_t)));
	for(int i = 0; i < size / (int)sizeof(pid_t); ++i)
	{
		if(pids[i] <= 0)
			continue;
		siginfo_t info;
		memset(&info, 0, sizeof(info));
		if(waitid(P_PID, (id_t)pids[i], &info, WEXITED | WNOHANG | WNOWAIT) == 0 && info.si_pid == pids[i])
			res.insert(pids[i]);
	}
	return res;
}

void test_pty_round_trip ()
{
	TerminalEmulator* emulator = [[TerminalEmulator alloc] initWithColumns:80 rows:24 maxScrollback:100];

	std::map<std::string, std::string> environment;
	environment["TERM"] = "xterm-256color";
	environment["PATH"] = "/usr/bin:/bin";

	PTYController* pty = [[PTYController alloc] initWithPath:"/bin/sh" arguments:{ "-c", "printf 'pty-round-trip-ok\\n'" } environment:environment workingDirectory:"/" loginShell:NO columns:80 rows:24 pixelWidth:640 pixelHeight:384];

	dispatch_semaphore_t exited = dispatch_semaphore_create(0);
	pty.readHandler = ^(void const* bytes, size_t length){
		[emulator feedBytes:bytes length:length];
	};
	__block int exitStatus = -1;
	pty.exitHandler = ^(int status){
		exitStatus = status;
		dispatch_semaphore_signal(exited);
	};

	OAK_ASSERT([pty spawn]);
	pid_t shellPid = pty.processIdentifier;
	OAK_ASSERT_GT(shellPid, 0);
	OAK_ASSERT_EQ(dispatch_semaphore_wait(exited, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)), 0L);
	OAK_ASSERT_EQ(exitStatus, 0);

	// The exit handler runs only after the child has been waited for, so by now
	// the pid must no longer be a zombie of ours. Pins the reap that a one-shot
	// WNOHANG used to lose when the exit notification beat the zombie or the
	// wait was interrupted. (Never waitpid(-1) here — tests run concurrently
	// and it would reap another test’s child.)
	errno = 0;
	OAK_ASSERT_EQ(waitpid(shellPid, NULL, WNOHANG), -1);
	OAK_ASSERT_EQ(errno, ECHILD);

	std::string text = screen_text(emulator);
	OAK_ASSERT_NE(text.find("pty-round-trip-ok"), std::string::npos);

	[pty shutdown];
}

// Regression: when the last strong reference dies inside a dispatch-source
// handler (e.g. the exit notification after ⌃D), dealloc → shutdown runs on
// the pty’s own read queue; shutdown must not dispatch_sync onto that queue.
void test_pty_release_on_io_queue ()
{
	std::map<std::string, std::string> environment;
	environment["PATH"] = "/usr/bin:/bin";

	for(int i = 0; i < 20; ++i)
	{
		dispatch_semaphore_t exited = dispatch_semaphore_create(0);
		__block PTYController* pty = [[PTYController alloc] initWithPath:"/bin/sh" arguments:{ "-c", "exit 0" } environment:environment workingDirectory:"/" loginShell:NO columns:80 rows:24 pixelWidth:640 pixelHeight:384];
		pty.exitHandler = ^(int status){
			pty = nil; // drop the last user reference on the pty’s own queue
			dispatch_semaphore_signal(exited);
		};
		OAK_ASSERT([pty spawn]);
		OAK_ASSERT_EQ(dispatch_semaphore_wait(exited, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)), 0L);
	}
	usleep(200000); // let the deferred deallocs run on their queues
}

// -shutdown is the last chance to reap: it cancels the sources before waiting,
// so whatever its waitpid ladder fails to collect stays a zombie forever. Here
// the child is alive when shutdown runs and dies from the SIGHUP, exercising
// the WNOHANG rungs. (Never waitpid(-1) here — tests run concurrently and it
// would reap another test’s child.)
void test_pty_shutdown_reaps_live_child ()
{
	std::map<std::string, std::string> environment;
	environment["PATH"] = "/usr/bin:/bin";

	PTYController* pty = [[PTYController alloc] initWithPath:"/bin/sh" arguments:{ "-c", "printf 'ready\\n'; read line" } environment:environment workingDirectory:"/" loginShell:NO columns:80 rows:24 pixelWidth:640 pixelHeight:384];

	dispatch_semaphore_t ready = dispatch_semaphore_create(0);
	__block std::string output;
	__block bool didSignal = false;
	pty.readHandler = ^(void const* bytes, size_t length){
		output.append((char const*)bytes, length);
		if(!didSignal && output.find("ready") != std::string::npos)
		{
			didSignal = true;
			dispatch_semaphore_signal(ready);
		}
	};

	OAK_ASSERT([pty spawn]);
	pid_t shellPid = pty.processIdentifier;
	OAK_ASSERT_GT(shellPid, 0);
	OAK_ASSERT_EQ(dispatch_semaphore_wait(ready, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)), 0L);

	[pty shutdown];

	errno = 0;
	OAK_ASSERT_EQ(waitpid(shellPid, NULL, WNOHANG), -1);
	OAK_ASSERT_EQ(errno, ECHILD);
}

// A child that ignores SIGHUP survives both WNOHANG rungs, so shutdown must
// escalate to SIGKILL and then block until the zombie is collected. The probe
// waits in pause(), so neither the SIGHUP nor the pty EOF that follows the
// master being closed can end it — the escalation is what does, deterministically.
void test_pty_shutdown_kills_hup_ignoring_child ()
{
	auto session = std::make_shared<probe_session_t>();
	PTYController* pty = probe_pty(session, { "ignore-hup" });

	OAK_ASSERT([pty spawn]);
	pid_t probePid = pty.processIdentifier;
	OAK_ASSERT_GT(probePid, 0);

	// The record is printed after SIGHUP is ignored, so waiting for it (as
	// opposed to sleeping) proves the disposition is in place before shutdown.
	OAK_MASSERT("probe never became ready: " + session->text(), session->wait_for("ready"));

	[pty shutdown];

	errno = 0;
	OAK_ASSERT_EQ(waitpid(probePid, NULL, WNOHANG), -1);
	OAK_ASSERT_EQ(errno, ECHILD);
}

// TIOCSWINSZ only stores the new size; the notification is a kernel-delivered
// SIGWINCH to the terminal’s foreground process group, which is precisely what
// a pty without a controlling terminal has none of. Reading back the size
// therefore proves nothing on its own — the probe must have been signalled.
void test_pty_resize_reaches_child ()
{
	auto session = std::make_shared<probe_session_t>();
	PTYController* pty = probe_pty(session, { "winch" }, "/", NO, { }, 132, 43);

	OAK_ASSERT([pty spawn]);
	OAK_MASSERT("probe never became ready: " + session->text(), session->wait_for("ready"));

	unsigned columns = 0, rows = 0;
	OAK_ASSERT_EQ(sscanf(session->value("initial-winsize").c_str(), "%u %u", &columns, &rows), 2);
	OAK_ASSERT_EQ(columns, 132u);
	OAK_ASSERT_EQ(rows, 43u);

	// The handler is installed and SIGWINCH blocked by now, so the signal can be
	// neither missed nor delivered before the probe is ready for it.
	[pty resizeToColumns:100 rows:30 pixelWidth:800 pixelHeight:480];

	OAK_MASSERT("no SIGWINCH reached the probe: " + session->text(), session->wait_for("sigwinch"));
	OAK_ASSERT_EQ(session->number("sigwinch"), 1L);

	columns = rows = 0;
	OAK_ASSERT_EQ(sscanf(session->value("winsize").c_str(), "%u %u", &columns, &rows), 2);
	OAK_ASSERT_EQ(columns, 100u);
	OAK_ASSERT_EQ(rows, 30u);

	OAK_ASSERT(session->wait_for_exit());
	int status = session->status();
	OAK_ASSERT(WIFEXITED(status));
	OAK_ASSERT_EQ(WEXITSTATUS(status), 0);

	[pty shutdown];
}

// The one invariant the helper exists for: the target leads its own session and
// process group, that group owns the pty as its controlling terminal, and it is
// the terminal’s foreground group. Everything else about the terminal — signal
// delivery, /dev/tty, job control — follows from this, and a spawn that gets it
// wrong still looks like a healthy shell. Fields are compared as numbers
// against the pid the controller reports; a pid searched for as a substring of
// `ps` output matches any line that happens to contain those digits.
void test_pty_controlling_terminal ()
{
	auto session = std::make_shared<probe_session_t>();
	PTYController* pty = probe_pty(session, { "state" });

	OAK_ASSERT([pty spawn]);
	pid_t probePid = pty.processIdentifier;
	OAK_ASSERT_GT(probePid, 0);

	OAK_MASSERT("probe printed no state: " + session->text(), session->wait_for("end"));

	OAK_ASSERT_EQ(session->number("pid"), (long)probePid);
	OAK_ASSERT_EQ(session->number("sid"), (long)probePid);
	OAK_ASSERT_EQ(session->number("pgid"), (long)probePid);
	OAK_ASSERT_EQ(session->number("tpgid"), (long)probePid);

	// /dev/tty is the alias a session reaches its controlling terminal through —
	// what sudo, ssh, and every other password prompt needs.
	OAK_ASSERT_EQ(session->value("devtty"), "ok");

	OAK_ASSERT(session->wait_for_exit());
	int status = session->status();
	OAK_ASSERT(WIFEXITED(status));
	OAK_ASSERT_EQ(WEXITSTATUS(status), 0);

	[pty shutdown];
}

// tty-generated signals go to the foreground process group of the controlling
// terminal, so ^C typed into the master must kill the target itself. The raw
// wait status is the assertion: an ordinary exit, or a teardown that kills the
// probe some other way, would otherwise pass for interruption.
void test_pty_interrupt_reaches_child ()
{
	auto session = std::make_shared<probe_session_t>();
	PTYController* pty = probe_pty(session, { "sigint" });

	OAK_ASSERT([pty spawn]);
	OAK_MASSERT("probe never became ready: " + session->text(), session->wait_for("ready"));

	[pty writeData:[NSData dataWithBytes:"\x03" length:1]];

	OAK_MASSERT("probe did not exit: " + session->text(), session->wait_for_exit());
	int status = session->status();
	OAK_ASSERT(WIFSIGNALED(status));
	OAK_ASSERT_EQ(WTERMSIG(status), SIGINT);

	[pty shutdown];
}

// Job control in miniature: a second process group takes the terminal, ^Z stops
// it through the tty, and the probe reclaims the terminal — the sequence a
// shell performs for every foreground job. The probe reads the terminal’s
// foreground group back from the slave, which is the same tty the controller
// queries from the master for its “a process is still running” warnings.
void test_pty_job_control ()
{
	auto session = std::make_shared<probe_session_t>();
	PTYController* pty = probe_pty(session, { "job-control" });

	OAK_ASSERT([pty spawn]);
	pid_t probePid = pty.processIdentifier;
	OAK_ASSERT_GT(probePid, 0);

	OAK_MASSERT("no foreground handoff: " + session->text(), session->wait_for("foreground"));
	OAK_ASSERT_EQ(session->number("shell-pgid"), (long)probePid);

	// The terminal followed the handoff: its foreground group is the job’s, not
	// the session leader’s any more.
	long jobGroup = session->number("job-pgid");
	OAK_ASSERT_GT(jobGroup, 0L);
	OAK_ASSERT_NE(jobGroup, (long)probePid);
	OAK_ASSERT_EQ(session->number("foreground"), jobGroup);

	// The probe blocks until the ^Z below, so this cannot race its exit. It is
	// what the “a process is still running” warnings ask.
	OAK_ASSERT(pty.hasForegroundProcess);

	// Typed at the terminal rather than sent with kill(): the point is that the
	// tty generates the job-control signal for its foreground group.
	[pty writeData:[NSData dataWithBytes:"\x1a" length:1]];

	OAK_MASSERT("the job was not stopped: " + session->text(), session->wait_for("stopped"));
	OAK_ASSERT_EQ(session->number("stopped"), (long)SIGTSTP);

	OAK_MASSERT("the terminal was not reclaimed: " + session->text(), session->wait_for("restored"));
	OAK_ASSERT_EQ(session->number("restored"), (long)probePid);

	OAK_ASSERT(session->wait_for_exit());
	int status = session->status();
	OAK_ASSERT(WIFEXITED(status));
	OAK_ASSERT_EQ(WEXITSTATUS(status), 0);

	[pty shutdown];
}

// argv[0] is the only thing that tells a shell it was started as a login shell,
// and the “-” has to be added exactly once. The helper passes its own
// argv[3…] straight to execve, so what the target sees is what the controller
// built.
void test_pty_login_shell_argv0 ()
{
	for(BOOL loginShell : { YES, NO })
	{
		auto session = std::make_shared<probe_session_t>();
		PTYController* pty = probe_pty(session, { "state" }, "/", loginShell);

		OAK_ASSERT([pty spawn]);
		OAK_MASSERT("probe printed no state: " + session->text(), session->wait_for("end"));
		OAK_ASSERT_EQ(session->value("argv0"), loginShell ? "-tm_pty_probe" : "tm_pty_probe");

		OAK_ASSERT(session->wait_for_exit());
		[pty shutdown];
	}
}

// The environment is handed to posix_spawn and travels through the helper’s own
// environ into execve, so a value with spaces and non-ASCII bytes must arrive
// byte for byte.
void test_pty_environment_reaches_child ()
{
	std::string const sentinel = "pty sentinel — 42 ✓";

	auto session = std::make_shared<probe_session_t>();
	PTYController* pty = probe_pty(session, { "state" }, "/", NO, { { "TM_PTY_PROBE_SENTINEL", sentinel } });

	OAK_ASSERT([pty spawn]);
	OAK_MASSERT("probe printed no state: " + session->text(), session->wait_for("end"));
	OAK_ASSERT_EQ(session->value("sentinel"), sentinel);

	OAK_ASSERT(session->wait_for_exit());
	[pty shutdown];
}

// An enterable working directory is simply used. Compared against its resolved
// path: TMPDIR lives under /var, which is a symlink to /private/var, and getcwd
// answers with the physical path.
void test_pty_working_directory ()
{
	char directory[PATH_MAX];
	snprintf(directory, sizeof(directory), "%s/tm-pty-cwd.XXXXXX", getenv("TMPDIR") ?: "/tmp");
	OAK_ASSERT(mkdtemp(directory) != NULL);

	struct cleanup_t
	{
		~cleanup_t () { rmdir(path); }
		char const* path;
	} cleanup = { directory };

	char resolved[PATH_MAX];
	OAK_ASSERT(realpath(directory, resolved) != NULL);

	auto session = std::make_shared<probe_session_t>();
	PTYController* pty = probe_pty(session, { "state" }, directory);

	OAK_ASSERT([pty spawn]);
	OAK_MASSERT("probe printed no state: " + session->text(), session->wait_for("end"));
	OAK_ASSERT_EQ(session->value("cwd"), std::string(resolved));

	OAK_ASSERT(session->wait_for_exit());
	[pty shutdown];
}

// A working directory can stat() fine and still be un-enterable — 0600 grants
// no search permission — and no up-front test can replace trying, since the
// directory can also vanish first. The helper falls back to “/” exactly as the
// forkpty child’s chdir("/") did, because a bad directory must still open a
// terminal rather than fail to.
void test_pty_working_directory_fallback ()
{
	char directory[PATH_MAX];
	snprintf(directory, sizeof(directory), "%s/tm-pty-cwd.XXXXXX", getenv("TMPDIR") ?: "/tmp");
	OAK_ASSERT(mkdtemp(directory) != NULL);

	// Runs even when an assertion below throws, so no unsearchable directory is
	// left behind in TMPDIR.
	struct cleanup_t
	{
		~cleanup_t () { chmod(path, 0700); rmdir(path); }
		char const* path;
	} cleanup = { directory };

	OAK_ASSERT_EQ(chmod(directory, 0600), 0);
	OAK_ASSERT_NE(access(directory, X_OK), 0); // root could enter it regardless, making the test vacuous

	auto session = std::make_shared<probe_session_t>();
	PTYController* pty = probe_pty(session, { "state" }, directory);

	OAK_ASSERT([pty spawn]);
	OAK_MASSERT("probe printed no state: " + session->text(), session->wait_for("end"));
	OAK_ASSERT_EQ(session->value("cwd"), "/");

	OAK_ASSERT(session->wait_for_exit());
	[pty shutdown];
}

// A target that cannot be exec’d is reported by the helper through the status
// pipe, so -spawn answers NO synchronously: no pid is published, no exit
// handler runs, and nothing is left for one to clean up — the failed helper is
// reaped inside -spawn or never at all.
void test_pty_missing_target_fails_cleanly ()
{
	std::string const missing = probe_path() + "-no-such-target";
	OAK_ASSERT_NE(access(missing.c_str(), F_OK), 0);

	std::map<std::string, std::string> environment;
	environment["PATH"] = "/usr/bin:/bin";

	__block long exitHandlerCalls = 0;
	PTYController* pty = [[PTYController alloc] initWithPath:missing arguments:{ } environment:environment workingDirectory:"/" loginShell:NO columns:80 rows:24 pixelWidth:640 pixelHeight:384];
	pty.exitHandler = ^(int status){ ++exitHandlerCalls; };

	OAK_ASSERT(![pty spawn]);
	OAK_ASSERT_LE(pty.processIdentifier, 0);
	OAK_ASSERT(!pty.isRunning);
	OAK_ASSERT_EQ(exitHandlerCalls, 0L);

	// No pid is published for this spawn — that is the point — so there is
	// nothing to waitpid for and the leak has to be looked for instead. A helper
	// -spawn failed to collect would be a zombie for the rest of this process’s
	// life, so intersecting samples converges on exactly that: the transient
	// zombies of tests reaping in parallel drop out at the next sample, a
	// permanent one never does.
	std::set<pid_t> leaked = unreaped_children();
	for(int i = 0; !leaked.empty() && i < 200; ++i)
	{
		usleep(10000);
		std::set<pid_t> current = unreaped_children(), both;
		std::set_intersection(leaked.begin(), leaked.end(), current.begin(), current.end(), std::inserter(both, both.end()));
		leaked.swap(both);
	}
	OAK_MASSERT("a child of the failed spawn was never reaped", leaked.empty());

	[pty shutdown];
}

// The handshake widens the gap between posix_spawn and the process source
// enough for a target to exit before the source exists, which the controller
// closes with two non-consuming waitid peeks. A target that exits without
// printing anything is the sharpest version of that race: the exit must still
// be reported — exactly once, with the real status — and the child reaped.
void test_pty_fast_exit_is_reported ()
{
	for(int i = 0; i < 10; ++i)
	{
		auto session = std::make_shared<probe_session_t>();
		PTYController* pty = probe_pty(session, { "exit", "7" });

		OAK_ASSERT([pty spawn]);
		pid_t probePid = pty.processIdentifier;
		OAK_ASSERT_GT(probePid, 0);

		OAK_MASSERT("the exit was never reported", session->wait_for_exit());
		int status = session->status();
		OAK_ASSERT(WIFEXITED(status));
		OAK_ASSERT_EQ(WEXITSTATUS(status), 7);
		OAK_ASSERT_EQ(session->exit_count(), 1L);

		errno = 0;
		OAK_ASSERT_EQ(waitpid(probePid, NULL, WNOHANG), -1);
		OAK_ASSERT_EQ(errno, ECHILD);

		// Both waitid peeks and the process event can all find the same exit;
		// shutdown then cancels a source whose handler may already be in flight.
		[pty shutdown];
		OAK_ASSERT_EQ(session->exit_count(), 1L);
	}
}

// The startup record parser stands between a malformed payload and a confident
// wrong diagnosis, and it is the one part of the handshake reachable without
// spawning anything: which helper runs is deliberately not overridable, so a
// fake one cannot be substituted for it. Pure function, no processes involved.
void test_pty_helper_error_record ()
{
	struct pty_helper_error_t record;
	record.magic        = pty_helper_magic;
	record.version      = pty_helper_version;
	record.stage        = pty_helper_stage_exec_target;
	record.error_number = ENOENT;

	struct pty_helper_error_t decoded;
	memset(&decoded, 0, sizeof(decoded));
	OAK_ASSERT(pty_helper_error_decode(&record, sizeof(record), &decoded));
	OAK_ASSERT_EQ(decoded.magic, (uint32_t)pty_helper_magic);
	OAK_ASSERT_EQ(decoded.version, (uint16_t)pty_helper_version);
	OAK_ASSERT_EQ(decoded.stage, (uint16_t)pty_helper_stage_exec_target);
	OAK_ASSERT_EQ(decoded.error_number, (int32_t)ENOENT);

	// The parent only needs the fields when it is going to log them.
	OAK_ASSERT(pty_helper_error_decode(&record, sizeof(record), NULL));

	// Short: a helper killed mid-write is not a diagnosis. Zero bytes never
	// reaches the decoder — it is the success signal — but must not decode
	// either.
	OAK_ASSERT(!pty_helper_error_decode(&record, sizeof(record) - 1, &decoded));
	OAK_ASSERT(!pty_helper_error_decode(&record, 0, &decoded));

	// Oversized: whoever wrote it was not the helper we spawned. (The parent
	// reads one byte past a record so that this is detectable at all rather than
	// silently truncated to a valid one.)
	char oversized[sizeof(record) + 1];
	memcpy(oversized, &record, sizeof(record));
	oversized[sizeof(record)] = 'x';
	OAK_ASSERT(!pty_helper_error_decode(oversized, sizeof(oversized), &decoded));

	struct pty_helper_error_t foreign = record;
	foreign.magic = ~record.magic;
	OAK_ASSERT(!pty_helper_error_decode(&foreign, sizeof(foreign), &decoded));

	foreign = record;
	foreign.version = pty_helper_version + 1;
	OAK_ASSERT(!pty_helper_error_decode(&foreign, sizeof(foreign), &decoded));

	// A stage this protocol version never wrote is a foreign record too, not a
	// helper error to log and reap.
	foreign = record;
	foreign.stage = 0;
	OAK_ASSERT(!pty_helper_error_decode(&foreign, sizeof(foreign), &decoded));

	foreign = record;
	foreign.stage = pty_helper_stage_exec_target + 1;
	OAK_ASSERT(!pty_helper_error_decode(&foreign, sizeof(foreign), &decoded));

	// None of the rejections wrote anything into the caller’s record.
	OAK_ASSERT_EQ(decoded.stage, (uint16_t)pty_helper_stage_exec_target);
	OAK_ASSERT_EQ(decoded.error_number, (int32_t)ENOENT);

	// Every stage the helper can report has a name for the parent to log, and an
	// unknown one still returns a string rather than NULL.
	for(uint16_t stage = pty_helper_stage_invalid_arguments; stage <= pty_helper_stage_exec_target; ++stage)
	{
		OAK_ASSERT(pty_helper_stage_name(stage) != NULL);
		OAK_ASSERT_NE(std::string(pty_helper_stage_name(stage)), "unknown stage");
	}
	OAK_ASSERT_EQ(std::string(pty_helper_stage_name(pty_helper_stage_exec_target + 1)), "unknown stage");
}

// Logical-line reconstruction: soft-wrapped rows are joined via ghostty’s
// per-row wrap/continuation flags, and the hovered cell maps to its byte
// offset within the joined line.
void test_logical_line_reconstruction ()
{
	TerminalEmulator* emulator = [[TerminalEmulator alloc] initWithColumns:20 rows:5 maxScrollback:100];
	OAK_ASSERT(emulator);

	// 30 characters — soft-wraps onto a second row at 20 columns
	char const* input = "Frameworks/buffer/src/foo.cc:9";
	[emulator feedBytes:input length:strlen(input)];
	[emulator synchronizeRenderState];

	std::string text;
	size_t hoverOffset = 0;
	std::vector<terminal_link_cell_t> cells;

	// Hover on the first row (column 3 → the ‘m’ of Frameworks)
	OAK_ASSERT([emulator logicalLineAtColumn:3 row:0 text:&text hoverOffset:&hoverOffset cells:&cells]);
	OAK_ASSERT_EQ(text, "Frameworks/buffer/src/foo.cc:9");
	OAK_ASSERT_EQ(hoverOffset, 3u);

	// Hover on the wrapped continuation row (row 1, column 4 → offset 24)
	OAK_ASSERT([emulator logicalLineAtColumn:4 row:1 text:&text hoverOffset:&hoverOffset cells:&cells]);
	OAK_ASSERT_EQ(text, "Frameworks/buffer/src/foo.cc:9");
	OAK_ASSERT_EQ(hoverOffset, 24u);

	// The cell map covers both viewport rows and round-trips offsets
	bool sawRow0 = false, sawRow1 = false;
	for(auto const& cell : cells)
	{
		if(cell.byteBegin < cell.byteEnd && cell.byteBegin < text.size())
		{
			if(cell.viewportRow == 0) sawRow0 = true;
			if(cell.viewportRow == 1) sawRow1 = true;
			if(cell.viewportRow == 0)
				OAK_ASSERT_EQ(cell.byteBegin, (size_t)cell.column);
			if(cell.viewportRow == 1)
				OAK_ASSERT_EQ(cell.byteBegin, (size_t)(20 + cell.column));
		}
	}
	OAK_ASSERT(sawRow0);
	OAK_ASSERT(sawRow1);

	// A hard newline ends the logical line
	char const* more = "\r\nsecond";
	[emulator feedBytes:more length:strlen(more)];
	[emulator synchronizeRenderState];
	OAK_ASSERT([emulator logicalLineAtColumn:2 row:2 text:&text hoverOffset:&hoverOffset cells:&cells]);
	OAK_ASSERT_EQ(text, "second");
	OAK_ASSERT_EQ(hoverOffset, 2u);

	// Blank rows are not links
	OAK_ASSERT(![emulator logicalLineAtColumn:0 row:4 text:&text hoverOffset:&hoverOffset cells:&cells]);
}
