#ifndef SCM_TEXT_DIFF_H_QK27VME3
#define SCM_TEXT_DIFF_H_QK27VME3

#include <map>
#include <string>

namespace scm { namespace text_diff {

	// Byte-range edits into `oldText`, keyed [from, to), that transform it
	// into `newText`. Computed line-wise with xdiff's histogram algorithm
	// (same engine as gutter_diff), so the result is minimal per-hunk and
	// suitable for -[OakDocument performReplacements:] — marks, folds and
	// the caret outside changed hunks survive. On any xdiff failure the
	// result degenerates to a single whole-text replacement; when the texts
	// are equal the result is empty.
	using replacements_t = std::multimap<std::pair<size_t, size_t>, std::string>;
	replacements_t replacements (std::string const& oldText, std::string const& newText);

	// Widen the batch's first and last edit into replace records (one byte
	// of adjacent context) when they are pure insertions or pure erasures.
	// ng::undo_manager_t::should_merge (undo.cc:39) can fold an adjacent
	// pure-insert or pure-erase user record into a matching record at the
	// group boundary during undo; a replace record (before ≠ "" and
	// after ≠ "") never merges, so this seals the batch's undo group at
	// both ends. No-op for edits that cannot be widened (they span all of
	// oldText).
	void seal_edits (replacements_t& edits, std::string const& oldText);

	// Classic unified diff of the two texts (hunks only, no ---/+++ file
	// header), with `context` lines of context. Empty when the texts match.
	std::string unified (std::string const& oldText, std::string const& newText, size_t context = 3);

} /* text_diff */ } /* scm */

#endif /* end of include guard: SCM_TEXT_DIFF_H_QK27VME3 */
