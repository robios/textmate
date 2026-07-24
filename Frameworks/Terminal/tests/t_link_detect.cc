#include <Terminal/link_detect.h>

static bool link_at (std::string const& line, size_t offset, terminal::file_link_t& out)
{
	return terminal::link_at_offset(line, offset, out);
}

void test_compiler_diagnostic ()
{
	std::string line = "/Users/me/src/foo.cc:123:45: error: expected ‘;’";
	terminal::file_link_t link;
	OAK_ASSERT(link_at(line, 3, link));
	OAK_ASSERT_EQ(link.path, "/Users/me/src/foo.cc");
	OAK_ASSERT_EQ(link.line, 123u);
	OAK_ASSERT_EQ(link.column, 45u);
	OAK_ASSERT_EQ(link.first, 0u);
	OAK_ASSERT_EQ(line.substr(link.first, link.last - link.first), "/Users/me/src/foo.cc:123:45");

	// Hovering the line/column digits is still the same link
	OAK_ASSERT(link_at(line, 22, link));
	OAK_ASSERT_EQ(link.path, "/Users/me/src/foo.cc");

	// Hovering the message text is not a link
	OAK_ASSERT(!link_at(line, line.find("error"), link));
}

void test_grep_output ()
{
	std::string line = "Frameworks/Terminal/src/foo.mm:12:some match text";
	terminal::file_link_t link;
	OAK_ASSERT(link_at(line, 5, link));
	OAK_ASSERT_EQ(link.path, "Frameworks/Terminal/src/foo.mm");
	OAK_ASSERT_EQ(link.line, 12u);
	OAK_ASSERT_EQ(link.column, 0u);
	OAK_ASSERT_EQ(line.substr(link.first, link.last - link.first), "Frameworks/Terminal/src/foo.mm:12");

	// The match text after the second colon is not part of the link
	OAK_ASSERT(!link_at(line, line.find("some"), link));
}

void test_python_traceback ()
{
	std::string line = "  File \"/tmp/example.py\", line 42, in <module>";
	terminal::file_link_t link;
	OAK_ASSERT(link_at(line, line.find("example"), link));
	OAK_ASSERT_EQ(link.path, "/tmp/example.py");
	OAK_ASSERT_EQ(link.line, 42u);
	OAK_ASSERT_EQ(link.column, 0u);

	OAK_ASSERT(!link_at(line, line.find("<module>"), link));
}

void test_git_diff_prefix ()
{
	std::string line = "+++ b/Frameworks/Terminal/src/foo.mm";
	terminal::file_link_t link;
	OAK_ASSERT(link_at(line, 8, link));
	OAK_ASSERT_EQ(link.path, "b/Frameworks/Terminal/src/foo.mm");
	OAK_ASSERT_EQ(link.alt_path, "Frameworks/Terminal/src/foo.mm");
	OAK_ASSERT_EQ(link.line, 0u);
}

void test_bare_and_home_paths ()
{
	terminal::file_link_t link;

	std::string bare = "see src/foo.cc for details";
	OAK_ASSERT(link_at(bare, bare.find("foo"), link));
	OAK_ASSERT_EQ(link.path, "src/foo.cc");
	OAK_ASSERT_EQ(link.line, 0u);
	OAK_ASSERT(link.alt_path.empty());

	std::string home = "cat ~/notes.txt";
	OAK_ASSERT(link_at(home, home.find("notes"), link));
	OAK_ASSERT_EQ(link.path, "~/notes.txt");

	// A plain word is not a path candidate
	std::string word = "hello world";
	OAK_ASSERT(!link_at(word, 1, link));
}

void test_punctuation_stripping ()
{
	terminal::file_link_t link;

	std::string quoted = "open \"src/foo.cc\" now";
	OAK_ASSERT(link_at(quoted, quoted.find("foo"), link));
	OAK_ASSERT_EQ(link.path, "src/foo.cc");

	std::string parens = "(in src/foo.cc:12)";
	OAK_ASSERT(link_at(parens, parens.find("foo"), link));
	OAK_ASSERT_EQ(link.path, "src/foo.cc");
	OAK_ASSERT_EQ(link.line, 12u);

	std::string sentence = "changed src/foo.cc, and more";
	OAK_ASSERT(link_at(sentence, sentence.find("foo"), link));
	OAK_ASSERT_EQ(link.path, "src/foo.cc");

	std::string period = "changed src/foo.cc.";
	OAK_ASSERT(link_at(period, period.find("foo"), link));
	OAK_ASSERT_EQ(link.path, "src/foo.cc");
}

void test_gcc_context_line ()
{
	// gcc context lines end the path with a bare colon and no line number
	std::string line = "src/foo.cc: In function 'x':";
	terminal::file_link_t link;
	OAK_ASSERT(link_at(line, line.find("foo"), link));
	OAK_ASSERT_EQ(link.path, "src/foo.cc");
	OAK_ASSERT_EQ(link.line, 0u);
	OAK_ASSERT_EQ(line.substr(link.first, link.last - link.first), "src/foo.cc");
}

void test_no_slash_line_suffix_rule ()
{
	terminal::file_link_t link;

	// A slash-less name with a line suffix must look like a file name
	std::string curl = "curl localhost:8080/api";
	OAK_ASSERT(!link_at(curl, curl.find("localhost"), link));

	std::string bare = "localhost:8080";
	OAK_ASSERT(!link_at(bare, 3, link));

	std::string clock = "12:34";
	OAK_ASSERT(!link_at(clock, 1, link));

	std::string file = "foo.cc:12";
	OAK_ASSERT(link_at(file, 1, link));
	OAK_ASSERT_EQ(link.path, "foo.cc");
	OAK_ASSERT_EQ(link.line, 12u);
}

void test_rejections ()
{
	terminal::file_link_t link;

	std::string url = "fetch https://example.com/foo.cc now";
	OAK_ASSERT(!link_at(url, url.find("example"), link));

	std::string spaces = "a  b";
	OAK_ASSERT(!link_at(spaces, 1, link)); // hovering whitespace

	OAK_ASSERT(!link_at(std::string("x/y"), 10, link)); // offset past end
	OAK_ASSERT(!link_at(std::string(), 0, link));
}
