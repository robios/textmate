#import <Terminal/TerminalEmulator.h>
#import <Terminal/PTYController.h>

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
	OAK_ASSERT_EQ(dispatch_semaphore_wait(exited, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)), 0L);
	OAK_ASSERT_EQ(exitStatus, 0);

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
