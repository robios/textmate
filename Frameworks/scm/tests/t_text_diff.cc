#include "../src/text_diff.h"

using scm::text_diff::replacements;
using scm::text_diff::replacements_t;
using scm::text_diff::unified;

static std::string apply_edits (replacements_t const& edits, std::string const& oldText)
{
	std::string res;
	size_t pos = 0;
	for(auto const& edit : edits)
	{
		OAK_ASSERT(edit.first.first >= pos);
		OAK_ASSERT(edit.first.second <= oldText.size());
		res += oldText.substr(pos, edit.first.first - pos);
		res += edit.second;
		pos = edit.first.second;
	}
	return res + oldText.substr(pos);
}

static void round_trip (std::string const& oldText, std::string const& newText)
{
	replacements_t edits = replacements(oldText, newText);
	OAK_ASSERT_EQ(apply_edits(edits, oldText), newText);
}

void test_no_change ()
{
	OAK_ASSERT(replacements("a\nb\n", "a\nb\n").empty());
	OAK_ASSERT(replacements("", "").empty());
	OAK_ASSERT_EQ(unified("a\nb\n", "a\nb\n"), "");
}

void test_round_trips ()
{
	round_trip("a\nb\nc\n", "a\nB\nc\n");          // modification
	round_trip("a\nb\n", "a\nNEW\nb\n");           // insertion
	round_trip("a\nb\nc\n", "a\nc\n");             // deletion
	round_trip("a\nb\n", "NEW\na\nb\n");           // insertion at top
	round_trip("a\nb\n", "a\nb\nNEW\n");           // insertion at EOF
	round_trip("", "hello\nworld\n");              // empty → content
	round_trip("hello\nworld\n", "");              // content → empty
	round_trip("a\nb", "a\nB");                    // no trailing newline, both sides
	round_trip("a\nb\n", "a\nb");                  // trailing newline removed
	round_trip("a\nb", "a\nb\n");                  // trailing newline added
	round_trip("x", "y");                          // single unterminated line
	round_trip("a\nb\nc\nd\ne\n", "a\nB\nc\nD\ne");// multiple hunks + newline change
	round_trip("line1\nline2\nline3\n", "intro\nline1\nline3\nline4\n");
	round_trip("aaa\n\n\n\nbbb\n\n\n\nccc\n", "aaa\nX\n\n\n\nbbb\n\n\n\nY\nccc\n");
	round_trip("a\nb\n", "a\nX\nY\nb\n");
	round_trip("\n\n\n", "\n\n\n\n");              // all-whitespace file
	round_trip(" \t \t", "\t \t ");
}

void test_minimal_edits_leave_context_untouched ()
{
	// Changing one middle line must not touch the first or last line's bytes.
	replacements_t edits = replacements("first\nsecond\nlast\n", "first\nSECOND\nlast\n");
	OAK_ASSERT_EQ(edits.size(), 1);
	OAK_ASSERT_EQ(edits.begin()->first.first, 6);
	OAK_ASSERT_EQ(edits.begin()->first.second, 13);
	OAK_ASSERT_EQ(edits.begin()->second, "SECOND\n");
}

void test_unified_output ()
{
	std::string diff = unified("a\nb\nc\n", "a\nB\nc\n", 1);
	OAK_ASSERT(diff.find("@@") != std::string::npos);
	OAK_ASSERT(diff.find("-b\n") != std::string::npos);
	OAK_ASSERT(diff.find("+B\n") != std::string::npos);
	OAK_ASSERT_EQ(diff.back(), '\n');
}
