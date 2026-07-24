#ifndef SCM_GUTTER_DIFF_H_HOH88JIM
#define SCM_GUTTER_DIFF_H_HOH88JIM

#include <cstdint>
#include <map>
#include <string>
#include <vector>

namespace scm { namespace gutter_diff {

	enum class change : uint8_t { added, modified, deleted };

	// ADL hook for the OAK_ASSERT_EQ stringifier in bin/gen_test;
	// also handy for trace logs.
	std::string to_s (change c);

	// Marks for the gutter, keyed by 1-indexed line number in the
	// new-side text (matches `mate --line=N` and the existing
	// SCM Diff Gutter Ruby bundle's contract).
	using result_t = std::map<size_t, change>;

	// One contiguous change between the base text and the current text.
	// Line numbers are 1-indexed; a count of zero marks the pure
	// insertion/deletion cases, where the corresponding start line is
	// the line BEFORE the change site (unified-diff convention, so it
	// can be 0 for a change at the top of the file).
	struct hunk_t
	{
		size_t buffer_from = 0, buffer_to = 0; // byte range [from, to) in current_text
		std::string base_text;                 // base-side bytes the range replaces
		size_t base_line = 0, base_lines = 0;  // base-side line span
		size_t new_line = 0, new_lines = 0;    // new-side line span
	};
	using hunks_t = std::vector<hunk_t>;

	// Pure: extract hunks from two byte buffers in one xdiff pass
	// (histogram algorithm, the same one git's own `diff` defaults to).
	// Byte ranges refer to the unmodified inputs; a trailing-newline-only
	// difference yields no hunks (mirrors diff_bytes).
	hunks_t hunks (std::string const& base_blob, std::string const& current_text);

	// Derive per-line gutter marks from a hunk list. Within a hunk the
	// first min(deleted, added) new-side lines pair up as `modified`,
	// surplus additions are `added`, and surplus deletions collapse to
	// one `deleted` mark on the line preceding the deletion site
	// (bumped one line when that spot already holds `modified`).
	result_t marks_for_hunks (hunks_t const& hunks);

	// Pure: produce gutter marks from two byte buffers, derived from the
	// same hunk walk so marks and hunks cannot drift apart. The one
	// deliberate exception is a hunk whose sides differ only by the
	// trailing newline: git counts it as a change and hunks() reports it,
	// but the gutter has always declined to mark it.
	result_t diff_bytes (std::string const& head_blob,
	                     std::string const& current_text);

	// Synchronously look up (or fetch + cache) `git show <ref>:<rel_path>`
	// for the repo at repo_root. Untracked / unknown paths yield an empty
	// blob with *trackedOut = false. Runs a subprocess on a cache miss, so
	// call from a background queue.
	std::string blob_for_ref (std::string const& repo_root,
	                          std::string const& ref,
	                          std::string const& rel_path,
	                          bool* trackedOut = nullptr);

	// Drop the cache entries for rel_path (every ref). Caller invokes
	// this on rename / save-as.
	void invalidate_blob (std::string const& repo_root,
	                      std::string const& rel_path);

	// Drop every cached blob under repo_root. Workstream E3 hooks this
	// from shared_info_t::fs_did_change when .git/HEAD, .git/index, or
	// .git/refs/** changes — the events that move HEAD or rewrite the
	// snapshot the cache is built against.
	void invalidate_repo (std::string const& repo_root);

} /* gutter_diff */ } /* scm */

#endif /* end of include guard: SCM_GUTTER_DIFF_H_HOH88JIM */
