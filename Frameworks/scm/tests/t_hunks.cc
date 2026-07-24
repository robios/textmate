#include "../src/gutter_diff.h"

using scm::gutter_diff::change;
using scm::gutter_diff::diff_bytes;
using scm::gutter_diff::hunks;
using scm::gutter_diff::hunks_t;
using scm::gutter_diff::marks_for_hunks;

// Applying every hunk's base_text over its buffer byte range (back to
// front, so earlier offsets stay valid) must reconstruct the base text.
static std::string reconstruct_base (std::string const& base, std::string const& current)
{
	std::string out = current;
	hunks_t const hs = hunks(base, current);
	for(auto it = hs.rbegin(); it != hs.rend(); ++it)
		out.replace(it->buffer_from, it->buffer_to - it->buffer_from, it->base_text);
	return out;
}

void test_hunks_no_change ()
{
	OAK_ASSERT(hunks("a\nb\nc\n", "a\nb\nc\n").empty());
}

// git treats adding or removing the trailing newline as a change to the
// last line, and so must we: swallowing it would let the review pane
// report a modified file as having no uncommitted changes.
void test_hunks_trailing_newline_only_is_a_change ()
{
	hunks_t const added = hunks("a\nb", "a\nb\n");
	OAK_ASSERT_EQ(added.size(), 1);
	OAK_ASSERT_EQ(added[0].base_line, 2);
	OAK_ASSERT_EQ(added[0].base_lines, 1);
	OAK_ASSERT_EQ(added[0].new_line, 2);
	OAK_ASSERT_EQ(added[0].new_lines, 1);
	OAK_ASSERT_EQ(added[0].base_text, "b");
	OAK_ASSERT_EQ(added[0].buffer_from, 2);
	OAK_ASSERT_EQ(added[0].buffer_to, 4); // the range covers "b\n"

	hunks_t const removed = hunks("a\nb\n", "a\nb");
	OAK_ASSERT_EQ(removed.size(), 1);
	OAK_ASSERT_EQ(removed[0].base_text, "b\n");
	OAK_ASSERT_EQ(removed[0].buffer_from, 2);
	OAK_ASSERT_EQ(removed[0].buffer_to, 3);

	// The gutter is the one surface that declines to mark this, so that a
	// file whose final newline the editor adds on save does not carry a
	// permanent stripe. The hunk above is what the review pane reads.
	OAK_ASSERT(diff_bytes("a\nb", "a\nb\n").empty());
	OAK_ASSERT(diff_bytes("a\nb\n", "a\nb").empty());
}

// The gutter's suppression covers exactly one thing: the newline that
// terminates the final line. Everything that merely resembles it at hunk
// granularity — an inserted blank line looks like an empty base side
// against a lone "\n" — is a real edit and has to keep its mark.
void test_marks_suppress_only_the_final_newline ()
{
	// A blank line inserted mid-file.
	OAK_ASSERT(!diff_bytes("a\nb\n", "a\n\nb\n").empty());
	// …and removed again.
	OAK_ASSERT(!diff_bytes("a\n\nb\n", "a\nb\n").empty());

	// A blank line at EOF: the base already ends in a newline, so the
	// extra one opens a line rather than terminating one.
	OAK_ASSERT(!diff_bytes("a\nb\n", "a\nb\n\n").empty());
	OAK_ASSERT(!diff_bytes("a\nb\n\n", "a\nb\n").empty());

	// Content and terminator changing together.
	OAK_ASSERT_EQ(diff_bytes("a\nb", "a\nB\n").at(2), change::modified);
	OAK_ASSERT_EQ(diff_bytes("a\nb\n", "a\nB").at(2), change::modified);

	// An empty base (an untracked file) against a single empty line is an
	// added line, not a terminator that grew.
	OAK_ASSERT(!diff_bytes("", "\n").empty());

	// A single unterminated line gaining its newline is still the
	// suppressed case.
	OAK_ASSERT(diff_bytes("a", "a\n").empty());
}

void test_hunks_pure_insertion ()
{
	hunks_t const hs = hunks("a\nb\n", "a\nNEW\nb\n");
	OAK_ASSERT_EQ(hs.size(), 1);
	OAK_ASSERT_EQ(hs[0].base_lines, 0);
	OAK_ASSERT_EQ(hs[0].base_line, 1);   // insertion after base line 1
	OAK_ASSERT_EQ(hs[0].new_line, 2);
	OAK_ASSERT_EQ(hs[0].new_lines, 1);
	OAK_ASSERT_EQ(hs[0].buffer_from, 2);
	OAK_ASSERT_EQ(hs[0].buffer_to, 6);
	OAK_ASSERT_EQ(hs[0].base_text, "");
}

void test_hunks_modification ()
{
	hunks_t const hs = hunks("a\nb\nc\n", "a\nB\nc\n");
	OAK_ASSERT_EQ(hs.size(), 1);
	OAK_ASSERT_EQ(hs[0].base_line, 2);
	OAK_ASSERT_EQ(hs[0].base_lines, 1);
	OAK_ASSERT_EQ(hs[0].new_line, 2);
	OAK_ASSERT_EQ(hs[0].new_lines, 1);
	OAK_ASSERT_EQ(hs[0].base_text, "b\n");
	OAK_ASSERT_EQ(hs[0].buffer_from, 2);
	OAK_ASSERT_EQ(hs[0].buffer_to, 4);
}

void test_hunks_pure_deletion ()
{
	hunks_t const hs = hunks("a\nb\nc\n", "a\nc\n");
	OAK_ASSERT_EQ(hs.size(), 1);
	OAK_ASSERT_EQ(hs[0].base_line, 2);
	OAK_ASSERT_EQ(hs[0].base_lines, 1);
	OAK_ASSERT_EQ(hs[0].new_lines, 0);
	OAK_ASSERT_EQ(hs[0].new_line, 1);    // deletion sits after new line 1
	OAK_ASSERT_EQ(hs[0].buffer_from, 2); // zero-length range at the deletion point
	OAK_ASSERT_EQ(hs[0].buffer_to, 2);
	OAK_ASSERT_EQ(hs[0].base_text, "b\n");
}

void test_hunks_deletion_at_top ()
{
	hunks_t const hs = hunks("a\nb\n", "b\n");
	OAK_ASSERT_EQ(hs.size(), 1);
	OAK_ASSERT_EQ(hs[0].new_line, 0);    // before the first line
	OAK_ASSERT_EQ(hs[0].new_lines, 0);
	OAK_ASSERT_EQ(hs[0].buffer_from, 0);
	OAK_ASSERT_EQ(hs[0].buffer_to, 0);
	OAK_ASSERT_EQ(hs[0].base_text, "a\n");
}

void test_hunks_deletion_at_eof ()
{
	hunks_t const hs = hunks("a\nb\n", "a\n");
	OAK_ASSERT_EQ(hs.size(), 1);
	OAK_ASSERT_EQ(hs[0].new_line, 1);
	OAK_ASSERT_EQ(hs[0].new_lines, 0);
	OAK_ASSERT_EQ(hs[0].buffer_from, 2); // clamped to the end of the buffer
	OAK_ASSERT_EQ(hs[0].buffer_to, 2);
	OAK_ASSERT_EQ(hs[0].base_text, "b\n");
}

void test_hunks_missing_trailing_newline_clamps ()
{
	// Neither input ends in '\n'; the normalisation copies must not
	// leak the synthetic newline into byte ranges or base_text.
	hunks_t const hs = hunks("a\nb", "a\nB");
	OAK_ASSERT_EQ(hs.size(), 1);
	OAK_ASSERT_EQ(hs[0].base_text, "b");
	OAK_ASSERT_EQ(hs[0].buffer_from, 2);
	OAK_ASSERT_EQ(hs[0].buffer_to, 3);
}

void test_hunks_empty_base_all_added ()
{
	hunks_t const hs = hunks("", "a\nb\nc\n");
	OAK_ASSERT_EQ(hs.size(), 1);
	OAK_ASSERT_EQ(hs[0].base_lines, 0);
	OAK_ASSERT_EQ(hs[0].new_line, 1);
	OAK_ASSERT_EQ(hs[0].new_lines, 3);
	OAK_ASSERT_EQ(hs[0].buffer_from, 0);
	OAK_ASSERT_EQ(hs[0].buffer_to, 6);
	OAK_ASSERT_EQ(hs[0].base_text, "");
}

void test_hunks_empty_new_all_deleted ()
{
	hunks_t const hs = hunks("a\nb\nc\n", "");
	OAK_ASSERT_EQ(hs.size(), 1);
	OAK_ASSERT_EQ(hs[0].base_line, 1);
	OAK_ASSERT_EQ(hs[0].base_lines, 3);
	OAK_ASSERT_EQ(hs[0].new_lines, 0);
	OAK_ASSERT_EQ(hs[0].buffer_from, 0);
	OAK_ASSERT_EQ(hs[0].buffer_to, 0);
	OAK_ASSERT_EQ(hs[0].base_text, "a\nb\nc\n");
}

void test_hunks_multiple ()
{
	hunks_t const hs = hunks(
		"a\nb\nc\nd\ne\nf\ng\nh\ni\nj\nk\n",
		"a\nB\nc\nd\ne\nf\ng\nH\ni\nj\nk\n");
	OAK_ASSERT_EQ(hs.size(), 2);
	OAK_ASSERT_EQ(hs[0].new_line, 2);
	OAK_ASSERT_EQ(hs[1].new_line, 8);
}

void test_hunks_roundtrip ()
{
	static struct { char const* base; char const* current; } const fixtures[] = {
		{ "a\nb\nc\n",              "a\nb\nc\n"          },
		{ "a\nb\n",                 "a\nNEW\nb\n"        },
		{ "a\nb\nc\n",              "a\nB\nc\n"          },
		{ "a\nb\nc\n",              "a\nc\n"             },
		{ "a\nb\n",                 "b\n"                },
		{ "a\nb\n",                 "a\n"                },
		{ "a\nb\nz\n",              "a\nB1\nB2\nz\n"     },
		{ "a\nb\nc\nz\n",           "a\nB\nz\n"          },
		{ "",                       "a\nb\nc\n"          },
		{ "a\nb\nc\n",              ""                   },
		{ "a\nb",                   "a\nB\nc"            },
		{ "x\ny\nz",                "x\nz"               },
		{ "a\nb",                   "a\nb\n"             }, // trailing newline added
		{ "a\nb\n",                 "a\nb"               }, // …and removed
		{ "a\nb\nc\nd\ne\nf\ng\n",  "a\nC\nd\nE\nf\ng\nH\n" },
	};

	for(auto const& fixture : fixtures)
		OAK_ASSERT_EQ(reconstruct_base(fixture.base, fixture.current), fixture.base);
}

void test_marks_match_diff_bytes_fixtures ()
{
	// marks_for_hunks ∘ hunks IS diff_bytes now; pin the derived-marks
	// semantics for a mixed hunk here anyway, so a future divergence of
	// either half shows up as a local failure.
	auto const hs = hunks("a\nb\nc\nz\n", "a\nB\nz\n");
	auto const marks = marks_for_hunks(hs);
	OAK_ASSERT_EQ(marks.size(), 2);
	OAK_ASSERT_EQ(marks.at(2), change::modified);
	OAK_ASSERT_EQ(marks.at(3), change::deleted);
}
