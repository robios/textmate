#include "../src/diff_pane_model.h"

using namespace diff_pane;
using scm::gutter_diff::hunks;

static std::string const kTenLines = "l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\n";

static std::vector<card_t> cards_for (std::string const& base, std::string const& buffer)
{
	return build_cards(hunks(base, buffer), base, buffer);
}

// Compact "kind base buffer text" rendering, so a fixture reads like the
// `git diff` block it has to match.
static std::string render (card_t const& card)
{
	std::string out;
	for(auto const& row : card.rows)
	{
		out += to_s(row.kind);
		out += ' ';
		out += row.base_line ? std::to_string(row.base_line) : "-";
		out += ' ';
		out += row.buffer_line ? std::to_string(row.buffer_line) : "-";
		out += ' ';
		out += row.text;
		out += '\n';
	}
	return out;
}

void test_line_count ()
{
	OAK_ASSERT_EQ(line_count(""), 0);
	OAK_ASSERT_EQ(line_count("a"), 1);
	OAK_ASSERT_EQ(line_count("a\n"), 1);
	OAK_ASSERT_EQ(line_count("a\nb"), 2);
	OAK_ASSERT_EQ(line_count("a\nb\n"), 2);
	OAK_ASSERT_EQ(line_count("\n"), 1);
}

// `git diff -U3` of this edit emits @@ -2,7 +2,7 @@ — three context
// lines, the swap, three more.
void test_cards_modification_matches_git ()
{
	auto const cards = cards_for(kTenLines, "l1\nl2\nl3\nl4\nL5\nl6\nl7\nl8\nl9\nl10\n");
	OAK_ASSERT_EQ(cards.size(), 1);
	OAK_ASSERT_EQ(cards[0].pure_deletion, false);
	OAK_ASSERT_EQ(cards[0].header_span.first, 2); // the displayed buffer lines, context included
	OAK_ASSERT_EQ(cards[0].header_span.last, 8);
	OAK_ASSERT_EQ(cards[0].header_is_base_side, false);
	OAK_ASSERT_EQ(cards[0].change_span.first, 5); // …while the CHANGED line is what the caret matches
	OAK_ASSERT_EQ(cards[0].change_span.last, 5);
	OAK_ASSERT_EQ(cards[0].anchor_line, 5);
	OAK_ASSERT_EQ(render(cards[0]),
		"context 2 2 l2\n"
		"context 3 3 l3\n"
		"context 4 4 l4\n"
		"deleted 5 - l5\n"
		"added - 5 L5\n"
		"context 6 6 l6\n"
		"context 7 7 l7\n"
		"context 8 8 l8\n");
}

// @@ -8,3 +8,4 @@ — leading context only; there is nothing after the
// appended line to show.
void test_cards_insertion_at_eof_matches_git ()
{
	auto const cards = cards_for(kTenLines, kTenLines + "l11\n");
	OAK_ASSERT_EQ(cards.size(), 1);
	OAK_ASSERT_EQ(cards[0].header_span.first, 8);
	OAK_ASSERT_EQ(cards[0].header_span.last, 11);
	OAK_ASSERT_EQ(render(cards[0]),
		"context 8 8 l8\n"
		"context 9 9 l9\n"
		"context 10 10 l10\n"
		"added - 11 l11\n");
}

// @@ -1,4 +1,3 @@ — no leading context is available at the top of the
// file, and the two line-number columns are offset from here on.
void test_cards_deletion_at_top_matches_git ()
{
	auto const cards = cards_for(kTenLines, "l2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\n");
	OAK_ASSERT_EQ(cards.size(), 1);
	OAK_ASSERT_EQ(cards[0].pure_deletion, true);
	// Even a pure deletion names buffer lines: its context survives in the
	// buffer, so the header needs no "these are old numbers" caveat.
	OAK_ASSERT_EQ(cards[0].header_span.first, 1);
	OAK_ASSERT_EQ(cards[0].header_span.last, 3);
	OAK_ASSERT_EQ(cards[0].header_is_base_side, false);
	OAK_ASSERT_EQ(cards[0].anchor_line, 1);
	OAK_ASSERT_EQ(render(cards[0]),
		"deleted 1 - l1\n"
		"context 2 1 l2\n"
		"context 3 2 l3\n"
		"context 4 3 l4\n");
}

// A deletion running to EOF has no line after it; the anchor clamps back
// onto the last surviving line so navigation still lands somewhere.
void test_cards_deletion_at_eof_anchors_on_last_line ()
{
	auto const cards = cards_for(kTenLines, "l1\nl2\nl3\nl4\nl5\n");
	OAK_ASSERT_EQ(cards.size(), 1);
	OAK_ASSERT_EQ(cards[0].pure_deletion, true);
	OAK_ASSERT_EQ(cards[0].header_span.first, 3);
	OAK_ASSERT_EQ(cards[0].header_span.last, 5);
	OAK_ASSERT_EQ(cards[0].header_is_base_side, false);
	OAK_ASSERT_EQ(cards[0].anchor_line, 5); // clamped: there is no line 6 any more
	OAK_ASSERT_EQ(render(cards[0]),
		"context 3 3 l3\n"
		"context 4 4 l4\n"
		"context 5 5 l5\n"
		"deleted 6 - l6\n"
		"deleted 7 - l7\n"
		"deleted 8 - l8\n"
		"deleted 9 - l9\n"
		"deleted 10 - l10\n");
}

void test_cards_are_in_document_order_and_never_merged ()
{
	// Two changes four lines apart: their context would overlap, but the
	// revert unit is the hunk, so they stay two cards.
	auto const cards = cards_for(kTenLines, "l1\nL2\nl3\nl4\nl5\nL6\nl7\nl8\nl9\nl10\n");
	OAK_ASSERT_EQ(cards.size(), 2);
	OAK_ASSERT_EQ(cards[0].hunk_index, 0);
	OAK_ASSERT_EQ(cards[1].hunk_index, 1);
	OAK_ASSERT_EQ(cards[0].header_span.first, 1); // clamped at the start of the file
	OAK_ASSERT_EQ(cards[1].header_span.first, 3);
	OAK_ASSERT(cards[0].anchor_line < cards[1].anchor_line);
}

// An untracked file diffs against a synthetic empty base: one all-added
// card covering the whole file, with no context to show on either side.
void test_cards_untracked_file_is_one_all_added_card ()
{
	auto const cards = cards_for("", "a\nb\n");
	OAK_ASSERT_EQ(cards.size(), 1);
	OAK_ASSERT_EQ(cards[0].header_span.first, 1);
	OAK_ASSERT_EQ(cards[0].header_span.last, 2);
	OAK_ASSERT_EQ(render(cards[0]),
		"added - 1 a\n"
		"added - 2 b\n");
}

// Emptying the file is the one case with no buffer-side line anywhere —
// not even context — so the header has to fall back to base-side numbers
// and flag that it did, or they would be read as current ones.
void test_cards_whole_file_deleted_names_base_side_lines ()
{
	auto const cards = cards_for(kTenLines, "");
	OAK_ASSERT_EQ(cards.size(), 1);
	OAK_ASSERT_EQ(cards[0].pure_deletion, true);
	OAK_ASSERT_EQ(cards[0].header_is_base_side, true);
	OAK_ASSERT_EQ(cards[0].header_span.first, 1);
	OAK_ASSERT_EQ(cards[0].header_span.last, 10);
}

// Every row has to lead somewhere: a deleted line is gone from the
// buffer, so activating it would otherwise do nothing at all.
void test_row_jump_lines_are_always_set ()
{
	for(auto const& cards : { cards_for(kTenLines, "l1\nl2\nl3\nl4\nL5\nl6\nl7\nl8\nl9\nl10\n"),
	                          cards_for(kTenLines, "l2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\n"),
	                          cards_for(kTenLines, "l1\nl2\nl3\nl4\nl5\n"),
	                          cards_for(kTenLines, ""),
	                          cards_for("", "a\nb\n") })
	{
		for(auto const& card : cards)
		{
			for(auto const& row : card.rows)
				OAK_ASSERT(row.jump_line != 0);
		}
	}
}

// A replaced line is not really gone — it became the added line paired
// with it, and that is where the editor should land.
void test_deleted_row_jumps_to_the_line_that_replaced_it ()
{
	auto const cards = cards_for(kTenLines, "l1\nl2\nl3\nl4\nL5\nl6\nl7\nl8\nl9\nl10\n");
	auto const& rows = cards[0].rows;
	OAK_ASSERT_EQ(to_s(rows[3].kind), "deleted");
	OAK_ASSERT_EQ(rows[3].base_line, 5);
	OAK_ASSERT_EQ(rows[3].jump_line, 5); // buffer line 5 now holds L5
}

// Deletions pair with additions in order, and a surplus deletion clamps
// onto the last added line rather than running past the hunk.
void test_deleted_rows_pair_with_added_rows_in_order ()
{
	// base lines 2-4 (b,c,d) become two lines (B,C).
	auto const cards = cards_for("a\nb\nc\nd\ne\n", "a\nB\nC\ne\n");
	auto const& rows = cards[0].rows;

	std::vector<size_t> deletedJumps;
	for(auto const& row : rows)
	{
		if(row.kind == row_kind::deleted)
			deletedJumps.push_back(row.jump_line);
	}
	OAK_ASSERT_EQ(deletedJumps.size(), 3);
	OAK_ASSERT_EQ(deletedJumps[0], 2); // b → B
	OAK_ASSERT_EQ(deletedJumps[1], 3); // c → C
	OAK_ASSERT_EQ(deletedJumps[2], 3); // d had no replacement — clamp to the last
}

// With nothing to pair against, a pure deletion falls back to the point
// the lines were removed from.
void test_pure_deletion_rows_jump_to_the_deletion_point ()
{
	auto const cards = cards_for(kTenLines, "l1\nl2\nl3\nl4\nl5\n");
	OAK_ASSERT_EQ(cards[0].anchor_line, 5);
	for(auto const& row : cards[0].rows)
	{
		if(row.kind == row_kind::deleted)
			OAK_ASSERT_EQ(row.jump_line, 5);
	}
}

void test_cards_empty_hunk_list_yields_no_cards ()
{
	OAK_ASSERT(cards_for(kTenLines, kTenLines).empty());
	OAK_ASSERT(cards_for("", "").empty());
}

// A file whose last line has no newline must not grow a phantom one.
void test_cards_missing_trailing_newline ()
{
	auto const cards = cards_for("a\nb", "a\nB");
	OAK_ASSERT_EQ(cards.size(), 1);
	OAK_ASSERT_EQ(render(cards[0]),
		"context 1 1 a\n"
		"deleted 2 - b\n"
		"added - 2 B\n");
}

void test_card_for_caret_is_strict_containment ()
{
	auto const cards = cards_for(kTenLines, "l1\nl2\nl3\nl4\nL5\nl6\nl7\nl8\nl9\nl10\n");
	OAK_ASSERT_EQ(card_for_caret(cards, 5), 0);
	// Context lines belong to no hunk — the highlight answers "which
	// change am I in", not "which is nearest".
	OAK_ASSERT_EQ(card_for_caret(cards, 4), npos);
	OAK_ASSERT_EQ(card_for_caret(cards, 6), npos);
	OAK_ASSERT_EQ(card_for_caret(cards, 1), npos);
	OAK_ASSERT_EQ(card_for_caret({}, 1), npos);
}

void test_card_for_caret_pure_deletion_matches_its_anchor ()
{
	auto const cards = cards_for(kTenLines, "l2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\n");
	OAK_ASSERT_EQ(cards[0].anchor_line, 1);
	OAK_ASSERT_EQ(card_for_caret(cards, 1), 0);
	OAK_ASSERT_EQ(card_for_caret(cards, 2), npos);
}

void test_card_for_caret_picks_the_containing_hunk ()
{
	auto const cards = cards_for(kTenLines, "l1\nL2\nl3\nl4\nl5\nL6\nl7\nl8\nl9\nl10\n");
	OAK_ASSERT_EQ(card_for_caret(cards, 2), 0);
	OAK_ASSERT_EQ(card_for_caret(cards, 6), 1);
}

// The base-side parse is reused across recomputes because typing cannot
// change the base. Three things can make a cached one unusable.
void test_can_reuse_base_scopes ()
{
	// The real key joins ref, path, file type and a content hash with NUL
	// separators; the predicate only ever compares it for equality, so
	// two distinct opaque values are enough here.
	std::string const key   = "HEAD|/a/b.cc|source.c++|123";
	std::string const other = "HEAD|/a/b.cc|source.c++|999";

	// The straightforward hit: same base, and the cache reached at least
	// as far as this render needs.
	OAK_ASSERT(can_reuse_base_scopes(key, 100, key, 100, true));
	OAK_ASSERT(can_reuse_base_scopes(key, 500, key, 100, true));

	// A different base — a moved HEAD, an amended commit, another file.
	OAK_ASSERT(!can_reuse_base_scopes(other, 500, key, 100, true));

	// The parse stops at the last line on display, so one that stopped
	// short cannot answer for a hunk further down. This axis is
	// asymmetric on purpose: longer serves shorter, never the reverse.
	OAK_ASSERT(!can_reuse_base_scopes(key, 99, key, 100, true));

	// No grammar means no scopes were produced at all. The highlighting
	// cap is measured over base and buffer together, so an edit alone can
	// turn the grammar off and on again while the base sits still — an
	// empty result must never stand in for a real parse of that base.
	OAK_ASSERT(!can_reuse_base_scopes(key, 500, key, 100, false));
}

void test_classify_empty_state_covers_the_four_states ()
{
	// hasHunks wins over everything else — there is a list to render.
	OAK_ASSERT_EQ(classify_empty_state(true, false, true, true, true, true, true), empty_state::has_hunks);

	OAK_ASSERT_EQ(classify_empty_state(false, false, true, false, false, false, true), empty_state::no_repository);
	OAK_ASSERT_EQ(classify_empty_state(true, true, true, false, false, false, true), empty_state::too_large);

	// Zero hunks, tracked: say which of disk/index still differs.
	OAK_ASSERT_EQ(classify_empty_state(true, false, true, false, false, false, true), empty_state::clean);
	OAK_ASSERT_EQ(classify_empty_state(true, false, true, false, true, false, true), empty_state::unsaved_only);
	OAK_ASSERT_EQ(classify_empty_state(true, false, true, false, false, true, true), empty_state::staged_only);
	OAK_ASSERT_EQ(classify_empty_state(true, false, true, false, true, true, true), empty_state::unsaved_and_staged);

	OAK_ASSERT_EQ(classify_empty_state(true, false, true, false, false, false, false), empty_state::clean_vs_base);
}

// The case the wording must not get wrong: an empty untracked file has
// zero hunks because its synthetic base is empty too, which is not the
// same thing as having no uncommitted changes.
void test_classify_empty_state_untracked_empty_is_not_clean ()
{
	OAK_ASSERT_EQ(classify_empty_state(true, false, false, false, false, false, true), empty_state::untracked_empty);
	OAK_ASSERT_EQ(classify_empty_state(true, false, false, false, true, false, true), empty_state::untracked_empty);
}

// The full base-kind × head-change reset table (review B, finding B3).
// The three the finding names explicitly are marked.
void test_head_move_resets_base_table ()
{
	using scm::git_query::head_change;
	using diff_pane::head_move_resets_base;
	auto const head = review_base_kind::head, commit = review_base_kind::commit, relative = review_base_kind::relative;

	// A commit landing resets nothing — a pinned base offers a banner, a
	// relative base follows, and HEAD is already HEAD.
	OAK_ASSERT(!head_move_resets_base(head,     head_change::committed));
	OAK_ASSERT(!head_move_resets_base(commit,   head_change::committed));
	OAK_ASSERT(!head_move_resets_base(relative, head_change::committed));

	// A switch resets every kind — including relative (B3: relative + switched → reset).
	OAK_ASSERT(head_move_resets_base(head,     head_change::switched));
	OAK_ASSERT(head_move_resets_base(commit,   head_change::switched));
	OAK_ASSERT(head_move_resets_base(relative, head_change::switched));

	// A rewrite resets a pinned base (B3: pinned + rewritten → reset)…
	OAK_ASSERT(head_move_resets_base(head,   head_change::rewritten));
	OAK_ASSERT(head_move_resets_base(commit, head_change::rewritten));
	// …but spares a relative one (B3: relative + rewritten → no reset).
	OAK_ASSERT(!head_move_resets_base(relative, head_change::rewritten));

	// `none` never resets anything.
	OAK_ASSERT(!head_move_resets_base(head,     head_change::none));
	OAK_ASSERT(!head_move_resets_base(commit,   head_change::none));
	OAK_ASSERT(!head_move_resets_base(relative, head_change::none));
}

// ==========
// = Revert =
// ==========

static std::string revert_result (std::string const& base, std::string const& buffer, size_t index)
{
	auto const list = hunks(base, buffer);
	return apply_replacements(buffer, replacements_for_revert(list, index, base, buffer, buffer));
}

// One hunk goes back to the base; the others are left exactly as they
// were, which is the whole point of reverting per hunk.
void test_revert_single_hunk_leaves_the_others ()
{
	std::string const buffer = "L1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nL10\n"; // first and last line edited
	OAK_ASSERT_EQ(hunks(kTenLines, buffer).size(), 2);

	OAK_ASSERT_EQ(revert_result(kTenLines, buffer, 0), "l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nL10\n");
	OAK_ASSERT_EQ(revert_result(kTenLines, buffer, 1), "L1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\n");
}

void test_revert_all_reconstructs_the_base ()
{
	std::string const buffer = "L1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nL10\n";
	OAK_ASSERT_EQ(revert_result(kTenLines, buffer, kAllHunks), kTenLines);

	// Pure insertion, pure deletion, and a file emptied out — the shapes
	// whose byte ranges collapse to a point.
	OAK_ASSERT_EQ(revert_result(kTenLines, "l1\nl2\nNEW\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\n", kAllHunks), kTenLines);
	OAK_ASSERT_EQ(revert_result(kTenLines, "l1\nl2\nl5\nl6\nl7\nl8\nl9\nl10\n", kAllHunks), kTenLines);
	OAK_ASSERT_EQ(revert_result(kTenLines, "", kAllHunks), kTenLines);

	// …and the reverse: a file created out of nothing reverts to nothing.
	OAK_ASSERT_EQ(revert_result("", kTenLines, kAllHunks), "");
}

// A revert is only valid against the buffer the hunks index into. The
// generation counter cannot tell: inside the recompute debounce the
// snapshot still looks current while the buffer has already moved on, so
// the live text is what decides.
void test_revert_refuses_a_buffer_that_moved_on ()
{
	std::string const buffer = "L1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\n";
	auto const list = hunks(kTenLines, buffer);
	OAK_ASSERT_EQ(list.size(), 1);

	// Same snapshot, one keystroke later — even one that lands nowhere
	// near the hunk, since it shifts every offset after it.
	std::string const live = buffer + "l11\n";
	OAK_ASSERT(replacements_for_revert(list, 0, kTenLines, buffer, live).empty());
	OAK_ASSERT(replacements_for_revert(list, kAllHunks, kTenLines, buffer, live).empty());

	// Unchanged buffer: the same call does produce the edit.
	OAK_ASSERT_EQ(replacements_for_revert(list, 0, kTenLines, buffer, buffer).size(), 1);
}

void test_revert_of_a_hunk_that_is_gone_is_a_no_op ()
{
	std::string const buffer = "L1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\n";
	auto const list = hunks(kTenLines, buffer);
	OAK_ASSERT(replacements_for_revert(list, 7, kTenLines, buffer, buffer).empty());
	OAK_ASSERT(replacements_for_revert(scm::gutter_diff::hunks_t(), kAllHunks, kTenLines, buffer, buffer).empty());
}

// Reverting everything must land on the base exactly. Per-hunk edits do,
// and are preferred because they leave the rest of the buffer — marks,
// folds and carets in it — untouched; a hunk list that did not round-trip
// falls back to replacing the buffer wholesale rather than half-reverting.
void test_revert_all_falls_back_to_replacing_everything ()
{
	std::string const buffer = "L1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nL10\n";

	auto list = hunks(kTenLines, buffer);
	OAK_ASSERT_EQ(list.size(), 2);
	list.pop_back(); // as if the walk had lost a hunk

	auto const replacements = replacements_for_revert(list, kAllHunks, kTenLines, buffer, buffer);
	OAK_ASSERT_EQ(replacements.size(), 1);
	OAK_ASSERT_EQ(replacements.begin()->first.first, 0);
	OAK_ASSERT_EQ(replacements.begin()->first.second, buffer.size());
	OAK_ASSERT_EQ(apply_replacements(buffer, replacements), kTenLines);
}
