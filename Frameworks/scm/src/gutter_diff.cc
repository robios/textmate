#include "gutter_diff.h"

#include <regex.h>
#include <sys/types.h>
#include <xdiff.h>

#include <dispatch/dispatch.h>

#include <mutex>
#include <unordered_map>

#include <io/io.h>
#include <oak/oak.h>
#include "drivers/api.h"

namespace scm { namespace gutter_diff {

	std::string to_s (change c)
	{
		switch(c)
		{
			case change::added:    return "added";
			case change::modified: return "modified";
			case change::deleted:  return "deleted";
		}
		return "unknown";
	}

	// ========================
	// = Pure hunk extraction =
	// ========================

	namespace
	{
		// With ctxlen 0 every change group gets its own `@@ -A,B +C,D @@`
		// header, so collecting headers is collecting hunks.
		struct header_t { size_t base_line, base_lines, new_line, new_lines; };

		// Parse one side of a hunk header: `-A[,B]` / `+C[,D]`. A missing
		// count means 1 (unified-diff shorthand).
		bool parse_header_side (char const*& p, char const* end, char sign, size_t& line, size_t& count)
		{
			while(p < end && *p != sign)
				++p;
			if(p == end)
				return false;
			++p;

			line = 0;
			while(p < end && *p >= '0' && *p <= '9')
				line = line * 10 + (size_t)(*p++ - '0');

			count = 1;
			if(p < end && *p == ',')
			{
				++p;
				count = 0;
				while(p < end && *p >= '0' && *p <= '9')
					count = count * 10 + (size_t)(*p++ - '0');
			}
			return true;
		}

		int hunk_header_cb (void* priv, mmbuffer_t* mb, int nbuf)
		{
			auto& headers = *(std::vector<header_t>*)priv;
			if(nbuf == 0 || mb[0].size < 2 || mb[0].ptr[0] != '@' || mb[0].ptr[1] != '@')
				return 0;

			char const* p   = mb[0].ptr;
			char const* end = p + mb[0].size;

			header_t h;
			if(parse_header_side(p, end, '-', h.base_line, h.base_lines) && parse_header_side(p, end, '+', h.new_line, h.new_lines))
				headers.push_back(h);
			return 0;
		}

		// offsets[i] = byte offset where 1-indexed line i+1 starts, with a
		// final entry at size() so the last line has an end. A text not
		// ending in '\n' needs that terminator added explicitly.
		std::vector<size_t> line_offsets (std::string const& s)
		{
			std::vector<size_t> offsets;
			offsets.push_back(0);
			for(size_t i = 0; i < s.size(); ++i)
			{
				if(s[i] == '\n')
					offsets.push_back(i + 1);
			}
			if(offsets.back() != s.size())
				offsets.push_back(s.size());
			return offsets;
		}
	}

	hunks_t hunks (std::string const& base_blob, std::string const& current_text)
	{
		// The inputs go to xdiff verbatim. Padding a missing trailing
		// newline would hide a real difference — git reports adding or
		// removing one as a change to the last line, and a review pane
		// that swallowed it would claim the file was unmodified.
		std::string const& a = base_blob;
		std::string const& b = current_text;

		mmfile_t mf_a, mf_b;
		mf_a.ptr  = a.empty() ? nullptr : const_cast<char*>(a.data());
		mf_a.size = (long)a.size();
		mf_b.ptr  = b.empty() ? nullptr : const_cast<char*>(b.data());
		mf_b.size = (long)b.size();

		xpparam_t xpp;
		memset(&xpp, 0, sizeof(xpp));
		xpp.flags = XDF_HISTOGRAM_DIFF;

		xdemitconf_t xec;
		memset(&xec, 0, sizeof(xec));
		xec.ctxlen = 0;

		std::vector<header_t> headers;
		xdemitcb_t ecb;
		memset(&ecb, 0, sizeof(ecb));
		ecb.priv     = &headers;
		ecb.out_line = hunk_header_cb;

		xdl_diff(&mf_a, &mf_b, &xpp, &xec, &ecb);

		auto const offsetsA = line_offsets(a);
		auto const offsetsB = line_offsets(b);

		// Byte offset where 1-indexed line `line` starts, clamped to the
		// end of the text.
		auto byte_at = [](std::vector<size_t> const& offsets, size_t line, size_t rawSize) -> size_t {
			size_t const index = std::min(line, offsets.size() - 1);
			return std::min(offsets[index], rawSize);
		};

		hunks_t result;
		for(auto const& h : headers)
		{
			hunk_t hunk;
			hunk.base_line  = h.base_line;
			hunk.base_lines = h.base_lines;
			hunk.new_line   = h.new_line;
			hunk.new_lines  = h.new_lines;

			// A zero count marks a pure insertion/deletion; the start
			// line then names the line BEFORE the change site, so the
			// byte range collapses to the point after that line.
			size_t const baseFrom = byte_at(offsetsA, h.base_lines ? h.base_line - 1 : h.base_line, base_blob.size());
			size_t const baseTo   = h.base_lines ? byte_at(offsetsA, h.base_line - 1 + h.base_lines, base_blob.size()) : baseFrom;
			hunk.base_text = base_blob.substr(baseFrom, baseTo - baseFrom);

			hunk.buffer_from = byte_at(offsetsB, h.new_lines ? h.new_line - 1 : h.new_line, current_text.size());
			hunk.buffer_to   = h.new_lines ? byte_at(offsetsB, h.new_line - 1 + h.new_lines, current_text.size()) : hunk.buffer_from;

			result.push_back(std::move(hunk));
		}
		return result;
	}

	result_t marks_for_hunks (hunks_t const& hunks)
	{
		result_t out;
		for(auto const& hunk : hunks)
		{
			for(size_t i = 0; i < hunk.new_lines; ++i)
				out[hunk.new_line + i] = i < hunk.base_lines ? change::modified : change::added;

			if(hunk.base_lines > hunk.new_lines)
			{
				// Surplus deletions collapse to one mark on the line
				// preceding the deletion site (for a pure deletion,
				// new_line already IS that line; clamp line 0 at BOF).
				size_t mark = std::max<size_t>(1, hunk.new_line + hunk.new_lines);

				auto it = out.find(mark);
				if(it != out.end() && it->second == change::modified)
					++mark;

				out[mark] = change::deleted;
			}
		}
		return out;
	}

	namespace
	{
		// True when `longer` is `shorter` with the newline that terminates
		// its final line, and nothing else. Judged on the whole text: at
		// hunk granularity an inserted blank line looks the same (an empty
		// base side against a lone "\n"), and suppressing those would hide
		// real edits anywhere in the file.
		//
		// `shorter` must not already end in a newline — if it does, the
		// extra one opens a new empty line at EOF rather than terminating
		// an existing one, which is a real change.
		bool differs_only_by_final_newline (std::string const& shorter, std::string const& longer)
		{
			return !shorter.empty()
			    && shorter.back() != '\n'
			    && longer.size() == shorter.size() + 1
			    && longer.back() == '\n'
			    && longer.compare(0, shorter.size(), shorter) == 0;
		}
	}

	result_t diff_bytes (std::string const& head_blob, std::string const& current_text)
	{
		// The gutter has always held that gaining or losing the final
		// newline is not worth a mark — an editor that adds one on save
		// would otherwise leave a permanent stripe on the last line. The
		// hunk itself is still reported: the review pane has to agree
		// with `git diff`, which does count it as a change. This is the
		// one place the two deliberately differ.
		if(differs_only_by_final_newline(head_blob, current_text) || differs_only_by_final_newline(current_text, head_blob))
			return result_t();

		return marks_for_hunks(hunks(head_blob, current_text));
	}

	// =========
	// = Cache =
	// =========

	namespace
	{
		struct blob_entry_t
		{
			std::string bytes;
			bool tracked   = false;
			bool cacheable = true; // false when the miss was git's fault, not the path's
		};

		std::mutex&                                                          cache_mutex ()
		{
			static std::mutex m;
			return m;
		}

		std::unordered_map<std::string, blob_entry_t>& cache ()
		{
			static std::unordered_map<std::string, blob_entry_t> c;
			return c;
		}

		std::string cache_key (std::string const& root, std::string const& ref, std::string const& rel)
		{
			std::string k = root;
			k += '\0';
			k += ref;
			k += '\0';
			k += rel;
			return k;
		}

		// Synchronously fetch <ref>:<rel> from the repo at root via
		// `git show`. Returns (bytes, tracked). For untracked / unknown
		// paths returns ("", false) so the diff against current_text
		// shows everything as additions.
		//
		// A failed `git show` is ambiguous: the path may be absent from
		// the ref (a real, stable answer) or git may have failed us —
		// unreadable ref, missing executable, a repo mid-rebase. Probing
		// the ref separates the two, because caching the second kind
		// would pin the file as all-added until the next .git event.
		blob_entry_t fetch_blob (std::string const& root, std::string const& ref, std::string const& rel)
		{
			static std::string const git = scm::find_executable("git", "TM_GIT");
			blob_entry_t e;
			if(git == NULL_STR)
			{
				e.cacheable = false;
				return e;
			}

			std::map<std::string, std::string> env = oak::basic_environment();
			env["GIT_WORK_TREE"] = root;
			env["GIT_DIR"]       = path::join(root, ".git");

			std::string spec = ref + ":" + rel;
			std::string out  = io::exec(env, git, "show", spec.c_str(), nullptr);
			if(out != NULL_STR)
			{
				e.bytes   = out;
				e.tracked = true;
				return e;
			}

			std::string const commit = ref + "^{commit}";
			e.cacheable = io::exec(env, git, "rev-parse", "--verify", "--quiet", commit.c_str(), nullptr) != NULL_STR;
			return e;
		}
	}

	std::string blob_for_ref (std::string const& repo_root, std::string const& ref, std::string const& rel_path, bool* trackedOut)
	{
		std::string const key = cache_key(repo_root, ref, rel_path);

		{
			std::lock_guard<std::mutex> g(cache_mutex());
			auto it = cache().find(key);
			if(it != cache().end())
			{
				if(trackedOut)
					*trackedOut = it->second.tracked;
				return it->second.bytes;
			}
		}

		blob_entry_t entry = fetch_blob(repo_root, ref, rel_path);
		if(entry.cacheable)
		{
			std::lock_guard<std::mutex> g(cache_mutex());
			cache()[key] = entry;
		}
		if(trackedOut)
			*trackedOut = entry.tracked;
		return entry.bytes;
	}

	void invalidate_blob (std::string const& repo_root, std::string const& rel_path)
	{
		std::lock_guard<std::mutex> g(cache_mutex());
		auto& c = cache();
		std::string const prefix = repo_root + '\0';
		for(auto it = c.begin(); it != c.end(); )
		{
			// Keys are root NUL ref NUL rel — match every ref for rel_path.
			bool match = it->first.compare(0, prefix.size(), prefix) == 0;
			if(match)
			{
				size_t const relPos = it->first.rfind('\0');
				match = relPos != std::string::npos && it->first.compare(relPos + 1, std::string::npos, rel_path) == 0;
			}
			if(match)
				it = c.erase(it);
			else
				++it;
		}
	}

	void invalidate_repo (std::string const& repo_root)
	{
		std::lock_guard<std::mutex> g(cache_mutex());
		auto& c = cache();
		std::string const prefix = repo_root + '\0';
		for(auto it = c.begin(); it != c.end(); )
		{
			if(it->first.compare(0, prefix.size(), prefix) == 0)
				it = c.erase(it);
			else
				++it;
		}
	}

} /* gutter_diff */ } /* scm */
