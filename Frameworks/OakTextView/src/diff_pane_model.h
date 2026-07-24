#ifndef DIFF_PANE_MODEL_H_C4K2REVB
#define DIFF_PANE_MODEL_H_C4K2REVB

#include <scm/gutter_diff.h>

#include <map>

// Pure presentation logic for the git-native review pane: turning a
// hunk list into the stack of cards the pane renders, and deciding what
// a zero-hunk snapshot actually means. Kept free of AppKit so the rules
// are unit-testable.
namespace diff_pane
{
	// git's own default, so a card's body matches `git diff` line for line.
	size_t const kContextLines = 3;
	size_t const npos = (size_t)-1;

	struct line_span_t { size_t first, last; }; // 1-indexed, inclusive

	// Lines of content in `text`: "" has none, a trailing newline does
	// not open a further line ("a\nb" and "a\nb\n" both have two).
	size_t line_count (std::string const& text);

	// The buffer-side lines a hunk occupies. A pure deletion has none;
	// it anchors on the line after the deletion point, clamped to the
	// last line for a deletion at EOF.
	line_span_t caret_span (scm::gutter_diff::hunk_t const& hunk, size_t totalLines);

	enum class row_kind : uint8_t
	{
		context, // unchanged, carries both line numbers
		deleted, // base-side only
		added,   // buffer-side only
	};

	// One rendered line of a card body. The line number that does not
	// apply to the row is 0 — a deleted line has no buffer-side number
	// and an added line has no base-side one.
	struct row_t
	{
		row_kind kind = row_kind::context;
		size_t base_line = 0, buffer_line = 0;
		// Where the editor goes when this row is activated. Equal to
		// buffer_line except on a deleted row, which has none: it points
		// at the line that replaced it, or at the deletion point when
		// nothing did. Never 0, so activating a row always leads
		// somewhere — landing nowhere reads as a dead control.
		size_t jump_line = 0;
		std::string text; // without the trailing newline
	};

	// One hunk, rendered. Cards are never merged: two hunks whose
	// context would overlap still get a card each, so the card list and
	// the hunk list stay index-for-index the same.
	struct card_t
	{
		size_t hunk_index = 0;
		bool pure_deletion = false;

		// The buffer-side lines the card DISPLAYS, context included —
		// what the header names, and a range the reader can go look at.
		// Context is what makes this work for a pure deletion too: the
		// deleted lines are gone from the buffer, but the lines around
		// them are not.
		line_span_t header_span = { 0, 0 };
		// Set only when the card displays no buffer-side line at all —
		// the whole file deleted. header_span is then base-side, and the
		// header has to say so or its numbers would be read as current.
		bool header_is_base_side = false;

		// The buffer-side lines the hunk actually CHANGED, for deciding
		// which card the caret is in. Empty (first == 0) for a pure
		// deletion, which has none.
		line_span_t change_span = { 0, 0 };

		// Buffer line the card navigates to (the deletion point for a
		// pure deletion).
		size_t anchor_line = 0;
		std::vector<row_t> rows;
	};

	// Cards in document order, one per hunk, each with up to
	// kContextLines of leading and trailing context clamped at the
	// start and end of the file.
	std::vector<card_t> build_cards (scm::gutter_diff::hunks_t const& hunks, std::string const& baseText, std::string const& bufferText);

	// Can a cached base-side syntax parse serve this render?
	//
	// Two asymmetries decide it. The parse runs from the top of the file
	// and stops at the last line on display, so it is a deterministic
	// prefix: a cache that reached FURTHER answers a shorter request
	// exactly, never the other way round. And a parse made without a
	// grammar holds no scopes at all — the size cap that disables
	// highlighting is measured across base AND buffer together, so an
	// edit alone can switch the grammar off and back on, and an empty
	// result must never stand in for a real parse of the same base.
	bool can_reuse_base_scopes (std::string const& cachedKey, size_t cachedMaxLine, std::string const& key, size_t maxLine, bool haveGrammar);

	// The card whose hunk contains `caretLine`, for the active-card
	// highlight; npos when the caret sits outside every hunk. Strict
	// containment — the highlight answers "which change am I in", not
	// "which change is nearest".
	size_t card_for_caret (std::vector<card_t> const& cards, size_t caretLine);

	// What a snapshot means for the pane body. The zero-hunk cases must
	// state which of buffer/disk/index/HEAD actually differ — including
	// the empty untracked file, whose synthetic empty base also yields
	// zero hunks but is anything but "no uncommitted changes".
	enum class empty_state
	{
		has_hunks,          // not an empty state — render the card list
		no_repository,
		too_large,          // diff skipped beyond the size cap
		untracked_empty,    // untracked file with an empty buffer
		clean,              // tracked, buffer == disk == HEAD, index clean
		unsaved_only,       // buffer == base, but not yet saved to disk
		staged_only,        // buffer == base, index still differs from HEAD
		unsaved_and_staged,
		clean_vs_base,      // review base is an older commit and the buffer matches it
	};

	empty_state classify_empty_state (bool inRepository, bool tooLarge, bool tracked, bool hasHunks, bool documentEdited, bool hasStagedChanges, bool baseIsHead);

	// =========================
	// = Revert (buffer edits) =
	// =========================

	// Byte range → replacement text, the form a document's replacement
	// machinery takes. Ranges index the buffer the hunks were computed
	// against; applying the whole set is one undo step.
	using replacements_t = std::multimap<std::pair<size_t, size_t>, std::string>;

	// Pass as `index` to revert every hunk at once.
	size_t const kAllHunks = npos;

	// The edits that put the base-side text back for one hunk, or for the
	// whole file.
	//
	// Reverting is only meaningful against the exact buffer the hunks
	// index into, and a generation counter cannot say that: during the
	// recompute debounce the buffer has already moved on while the
	// snapshot still looks current. So the live buffer is the gate —
	// anything else yields no edits at all, and the recompute already on
	// its way redraws the pane.
	//
	// Reverting everything must land on the base exactly. The hunk walk
	// round-trips (t_hunks covers it), but a shortfall here would leave
	// the buffer neither reverted nor as the user had it, so the result
	// is checked and falls back to replacing the buffer wholesale.
	replacements_t replacements_for_revert (scm::gutter_diff::hunks_t const& hunks, size_t index, std::string const& baseText, std::string const& snapshotBuffer, std::string const& liveBuffer);

	// Apply to `text` (later ranges first, so earlier offsets stay
	// valid). Exposed for tests and for the round-trip check above.
	std::string apply_replacements (std::string const& text, replacements_t const& replacements);

	// ADL hooks for the OAK_ASSERT_EQ stringifier in bin/gen_test.
	std::string to_s (empty_state state);
	std::string to_s (row_kind kind);

} /* diff_pane */

#endif /* end of include guard: DIFF_PANE_MODEL_H_C4K2REVB */
