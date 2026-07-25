#ifndef AGENT_DIAGNOSTICS_H_W8QK3ZR6
#define AGENT_DIAGNOSTICS_H_W8QK3ZR6

#include <algorithm>
#include <string>
#include <vector>

// Which diagnostics a getDiagnostics call answers with, and how many of them.
// Pure over plain values — no LSP, no Objective-C — because both halves of this
// have to be tested and neither is about the diagnostics themselves:
//
//  * Scoping. The diagnostics cache is process-wide, so a query routed to one
//    project must not be answered with another project's files. Without this a
//    second window's repository leaks into the answer, and worse, spends the
//    budget below before the asking project is ever reached.
//  * Budgeting. §4.2's cap is on the *result*, not on one field of it: an
//    answer that lists ten thousand files with no diagnostics in them is
//    unbounded in exactly the way the cap exists to prevent. So the file count
//    is capped alongside the entry count, and what did not fit is reported as
//    one summary rather than one entry per file.
namespace agent_diagnostics
{
	struct file_t
	{
		std::string uri;  // as the language server sent it
		std::string path; // decoded filesystem path, for scoping
		size_t count;     // diagnostics this file has
	};

	// What to put in the answer: the files to list, how many of each, and what
	// was left out entirely.
	struct entry_t
	{
		size_t index;   // into the scoped vector
		size_t take;    // diagnostics to include
		size_t omitted; // diagnostics of this file that did not fit
	};

	struct plan_t
	{
		std::vector<entry_t> entries;
		size_t omitted_files       = 0; // files not listed at all
		size_t omitted_diagnostics = 0; // their diagnostics
	};

	// True when ‘path’ is ‘root’ or lies inside it. An empty root contains
	// everything, which is how “no routing path” asks for no scoping.
	inline bool within (std::string const& path, std::string root)
	{
		if(root.empty())
			return true;
		while(root.size() > 1 && root.back() == '/')
			root.pop_back();
		if(path.size() < root.size() || path.compare(0, root.size(), root) != 0)
			return false;
		return path.size() == root.size() || path[root.size()] == '/';
	}

	// Ordered by uri, which is not about presentation: the caller enumerates a
	// dictionary, so without this the *set* of files that survives the cap
	// below is whatever order the hash gave — two identical calls could answer
	// with different files, and an agent that asks twice would have no way to
	// tell that from the diagnostics having changed.
	inline std::vector<file_t> in_scope (std::vector<file_t> const& files, std::string const& root)
	{
		std::vector<file_t> res;
		for(file_t const& file : files)
		{
			if(within(file.path, root))
				res.push_back(file);
		}
		std::sort(res.begin(), res.end(), [](file_t const& lhs, file_t const& rhs){ return lhs.uri < rhs.uri; });
		return res;
	}

	// Files with nothing to report. An empty envelope tells the caller nothing,
	// and once the file count is capped it costs a slot that a file with real
	// diagnostics needed: fifty of these sorting ahead of the rest answer the
	// question with fifty empty arrays while the entry budget goes unspent.
	//
	// They are common, not hypothetical — a language server that clears a
	// file’s diagnostics publishes an empty list, and the cache keeps the URI
	// with an empty array rather than dropping it. Dropping them here is not
	// truncation and is not counted as such: nothing is lost with them.
	//
	// Not applied when the caller named a uri: “this file has no diagnostics”
	// is exactly the answer that call is asking for.
	inline std::vector<file_t> with_diagnostics (std::vector<file_t> const& files)
	{
		std::vector<file_t> res;
		for(file_t const& file : files)
		{
			if(file.count)
				res.push_back(file);
		}
		return res;
	}

	// Files are taken in order until either budget runs out; the rest are
	// counted, not listed. Counting them costs a loop over a map already in
	// memory and is what lets the summary say how much was left — the
	// alternative, stopping the walk, would have to say “some”.
	inline plan_t plan (std::vector<file_t> const& files, size_t max_diagnostics, size_t max_files)
	{
		plan_t res;
		size_t remaining = max_diagnostics;

		for(size_t i = 0; i < files.size(); ++i)
		{
			size_t const count = files[i].count;
			if(remaining == 0 || res.entries.size() == max_files)
			{
				++res.omitted_files;
				res.omitted_diagnostics += count;
				continue;
			}

			size_t const take = std::min(remaining, count);
			res.entries.push_back({ i, take, count - take });
			remaining -= take;
		}
		return res;
	}

} /* agent_diagnostics */

#endif /* AGENT_DIAGNOSTICS_H_W8QK3ZR6 */
