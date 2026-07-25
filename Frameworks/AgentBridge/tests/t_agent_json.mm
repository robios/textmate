#import "../src/agent_json.h"

// The selection cap is one function shared by the tool result and the
// selection_changed notification, so these cover both — which is the point of
// sharing it: the cap used to live only in the tool path, and Claude reads the
// selection from the notification.

void test_truncate_leaves_short_text_alone ()
{
	OAK_ASSERT_EQ(agent_json::truncate_utf8("", 64), "");
	OAK_ASSERT_EQ(agent_json::truncate_utf8("hello", 64), "hello");
	OAK_ASSERT_EQ(agent_json::truncate_utf8("hello", 5), "hello"); // exactly at the limit
}

void test_truncate_cuts_ascii_at_the_limit ()
{
	std::string const text(70 * 1024, 'x');
	std::string const capped = agent_json::truncate_utf8(text, agent_json::maximum_selection_bytes);
	OAK_ASSERT_EQ(capped.size(), agent_json::maximum_selection_bytes);
	OAK_ASSERT_EQ(text.compare(0, capped.size(), capped), 0);
}

void test_truncate_never_splits_a_character ()
{
	// Three bytes per character: every cut but a multiple of three has to back
	// off, or the result is not text — and dump() would replace the fragment
	// with U+FFFD rather than say anything about it.
	std::string text;
	for(size_t i = 0; i < 100; ++i)
		text += "あ"; // e2 81 82 — 3 bytes

	for(size_t limit = 0; limit < text.size(); ++limit)
	{
		std::string const capped = agent_json::truncate_utf8(text, limit);
		OAK_ASSERT(capped.size() <= limit);
		OAK_ASSERT_EQ(capped.size() % 3, 0);            // whole characters only
		OAK_ASSERT_EQ(text.compare(0, capped.size(), capped), 0); // and a prefix of the original
		OAK_ASSERT(limit - capped.size() < 3);          // backing off by at most one character
	}
}

void test_truncate_handles_mixed_widths ()
{
	std::string const text = "ab\xC3\xA9\xE3\x81\x82\xF0\x9F\x98\x80z"; // a b é あ 😀 z
	for(size_t limit = 0; limit <= text.size(); ++limit)
	{
		std::string const capped = agent_json::truncate_utf8(text, limit);
		OAK_ASSERT(capped.size() <= limit);
		OAK_ASSERT_EQ(text.compare(0, capped.size(), capped), 0);
		// Never ends inside a character: the byte after the cut is never a
		// continuation byte.
		if(capped.size() < text.size())
			OAK_ASSERT((text[capped.size()] & 0xC0) != 0x80);
	}
}
