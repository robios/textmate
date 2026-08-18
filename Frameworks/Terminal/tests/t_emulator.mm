#import <Terminal/TerminalEmulator.h>
#import <Terminal/PTYController.h>
#include <errno.h>
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
// escalate to SIGKILL and then block until the zombie is collected. The loop
// keeps the shell alive even though closing the master ends its `sleep` and
// gives its stdin EOF, making the escalation deterministic rather than timing
// dependent.
void test_pty_shutdown_kills_hup_ignoring_child ()
{
	std::map<std::string, std::string> environment;
	environment["PATH"] = "/usr/bin:/bin";

	PTYController* pty = [[PTYController alloc] initWithPath:"/bin/sh" arguments:{ "-c", "trap '' HUP; printf 'ready\\n'; while :; do sleep 1; done" } environment:environment workingDirectory:"/" loginShell:NO columns:80 rows:24 pixelWidth:640 pixelHeight:384];

	// The marker is printed after the trap is installed, so waiting for it (as
	// opposed to sleeping) proves SIGHUP is already ignored when shutdown runs.
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

void test_pty_resize_reaches_child ()
{
	std::map<std::string, std::string> environment;
	environment["TERM"] = "xterm-256color";
	environment["PATH"] = "/usr/bin:/bin";

	PTYController* pty = [[PTYController alloc] initWithPath:"/bin/sh" arguments:{ "-c", "stty size" } environment:environment workingDirectory:"/" loginShell:NO columns:132 rows:43 pixelWidth:1056 pixelHeight:688];

	dispatch_semaphore_t exited = dispatch_semaphore_create(0);
	__block std::string output;
	pty.readHandler = ^(void const* bytes, size_t length){
		output.append((char const*)bytes, length);
	};
	pty.exitHandler = ^(int status){
		dispatch_semaphore_signal(exited);
	};

	OAK_ASSERT([pty spawn]);
	OAK_ASSERT_EQ(dispatch_semaphore_wait(exited, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)), 0L);
	OAK_ASSERT_NE(output.find("43 132"), std::string::npos);

	[pty shutdown];
}

// The child must own the pty as its controlling terminal — job control and
// SIGHUP-on-close depend on it. posix_spawn has no login_tty/TIOCSCTTY, so
// spawn relies on the session leader acquiring the slave when opening it by
// path; the terminal’s foreground process group (tpgid) equals the shell’s
// pid exactly when that worked.
void test_pty_controlling_terminal ()
{
	std::map<std::string, std::string> environment;
	environment["PATH"] = "/usr/bin:/bin";

	PTYController* pty = [[PTYController alloc] initWithPath:"/bin/sh" arguments:{ "-c", "ps -o tpgid= -p $$" } environment:environment workingDirectory:"/" loginShell:NO columns:80 rows:24 pixelWidth:640 pixelHeight:384];

	dispatch_semaphore_t exited = dispatch_semaphore_create(0);
	__block std::string output;
	pty.readHandler = ^(void const* bytes, size_t length){
		output.append((char const*)bytes, length);
	};
	pty.exitHandler = ^(int status){
		dispatch_semaphore_signal(exited);
	};

	OAK_ASSERT([pty spawn]);
	pid_t shellPid = pty.processIdentifier;
	OAK_ASSERT_GT(shellPid, 0);
	OAK_ASSERT_EQ(dispatch_semaphore_wait(exited, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)), 0L);
	OAK_ASSERT_NE(output.find(std::to_string(shellPid)), std::string::npos);

	[pty shutdown];
}

// A working directory can stat() fine and still be un-enterable — 0600 grants
// no search permission — and posix_spawn fails outright when its chdir file
// action fails. The terminal must open in “/” instead, the way the forkpty
// child’s chdir("/") fallback did.
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

	std::map<std::string, std::string> environment;
	environment["PATH"] = "/usr/bin:/bin";

	PTYController* pty = [[PTYController alloc] initWithPath:"/bin/sh" arguments:{ "-c", "pwd" } environment:environment workingDirectory:directory loginShell:NO columns:80 rows:24 pixelWidth:640 pixelHeight:384];

	dispatch_semaphore_t exited = dispatch_semaphore_create(0);
	__block std::string output;
	pty.readHandler = ^(void const* bytes, size_t length){
		output.append((char const*)bytes, length);
	};
	pty.exitHandler = ^(int status){
		dispatch_semaphore_signal(exited);
	};

	OAK_ASSERT([pty spawn]);
	OAK_ASSERT_EQ(dispatch_semaphore_wait(exited, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)), 0L);

	// The pty terminates lines with CRLF; matching the line rather than “/”
	// keeps any other path from satisfying the assertion.
	OAK_ASSERT_NE(output.find("/\r\n"), std::string::npos);
	OAK_ASSERT_EQ(output.find(directory), std::string::npos);

	[pty shutdown];
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
