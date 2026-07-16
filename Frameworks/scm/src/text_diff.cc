#include "text_diff.h"

#include <regex.h> // xdiff.h uses regex_t without including it
#include <sys/types.h>
#include <xdiff.h>

#include <cstring>
#include <functional>
#include <vector>

namespace scm { namespace text_diff {

	namespace
	{
		using record_fn = std::function<void(std::string&&)>;

		int emit_record_cb (void* priv, mmbuffer_t* mb, int nbuf)
		{
			// xdl_emit_diffrec sends one full record per callback: prefix
			// chunk, line chunk, and optionally a "\n\ No newline at end of
			// file\n" chunk (vendor/xdiff/src/xutils.c:39-53). Hunk headers
			// arrive as a single chunk. Reassemble and parse at string level
			// so chunking details never matter.
			std::string record;
			for(int i = 0; i < nbuf; ++i)
				record.append(mb[i].ptr, (size_t)mb[i].size);
			(*(record_fn*)priv)(std::move(record));
			return 0;
		}

		bool run_diff (std::string const& oldText, std::string const& newText, size_t context, record_fn fn)
		{
			mmfile_t a, b;
			a.ptr  = oldText.empty() ? nullptr : const_cast<char*>(oldText.data());
			a.size = (long)oldText.size();
			b.ptr  = newText.empty() ? nullptr : const_cast<char*>(newText.data());
			b.size = (long)newText.size();

			xpparam_t xpp;
			memset(&xpp, 0, sizeof(xpp));
			xpp.flags = XDF_HISTOGRAM_DIFF;

			xdemitconf_t xec;
			memset(&xec, 0, sizeof(xec));
			xec.ctxlen = (long)context;

			xdemitcb_t ecb;
			memset(&ecb, 0, sizeof(ecb));
			ecb.priv     = &fn;
			ecb.out_line = emit_record_cb;

			return xdl_diff(&a, &b, &xpp, &xec, &ecb) == 0;
		}

		static char const* const kNoNewlineSuffix = "\n\\ No newline at end of file\n";

		// Strip the marker prefix and, when present, the no-trailing-newline
		// annotation, leaving the record's exact source bytes.
		std::string record_content (std::string const& record)
		{
			std::string content = record.substr(1);
			size_t const suffixLen = strlen(kNoNewlineSuffix);
			if(content.size() >= suffixLen && content.compare(content.size() - suffixLen, suffixLen, kNoNewlineSuffix) == 0)
				content.resize(content.size() - suffixLen);
			return content;
		}

		// Extract A and B from "@@ -A[,B] +C[,D] @@"; counts default to 1
		// when omitted. Returns false on anything unparsable.
		bool parse_hunk_header (std::string const& record, size_t* oldStart, size_t* oldCount)
		{
			char const* p   = record.c_str();
			char const* end = p + record.size();

			while(p != end && *p != '-')
				++p;
			if(p == end)
				return false;
			++p;

			size_t start = 0;
			if(p == end || *p < '0' || *p > '9')
				return false;
			while(p != end && *p >= '0' && *p <= '9')
				start = start * 10 + (size_t)(*p++ - '0');

			size_t count = 1;
			if(p != end && *p == ',')
			{
				++p;
				count = 0;
				while(p != end && *p >= '0' && *p <= '9')
					count = count * 10 + (size_t)(*p++ - '0');
			}

			*oldStart = start;
			*oldCount = count;
			return true;
		}

		std::vector<size_t> line_start_offsets (std::string const& text)
		{
			std::vector<size_t> starts;
			starts.push_back(0);
			for(size_t i = 0; i < text.size(); ++i)
			{
				if(text[i] == '\n')
					starts.push_back(i+1);
			}
			// A final line without trailing newline still counts as a line;
			// make the last entry a sentinel equal to text.size() either way.
			if(!text.empty() && text.back() != '\n')
				starts.push_back(text.size());
			return starts;
		}
	}

	replacements_t replacements (std::string const& oldText, std::string const& newText)
	{
		replacements_t res;
		if(oldText == newText)
			return res;

		std::vector<size_t> const starts = line_start_offsets(oldText);
		size_t const sentinel = starts.size() - 1; // starts[sentinel] == oldText.size()

		struct hunk_t
		{
			bool active = false;
			size_t from = 0, to = 0;
			std::string replacement;
		};
		hunk_t hunk;

		auto flush = [&]{
			if(hunk.active && (hunk.from != hunk.to || !hunk.replacement.empty()))
				res.emplace(std::make_pair(hunk.from, hunk.to), hunk.replacement);
			hunk = hunk_t();
		};

		bool ok = run_diff(oldText, newText, 0, [&](std::string&& record){
			if(record.empty())
				return;

			if(record.size() >= 2 && record[0] == '@' && record[1] == '@')
			{
				flush();

				size_t oldStart = 0, oldCount = 1;
				if(!parse_hunk_header(record, &oldStart, &oldCount))
					return;

				// Unified diff line numbers are 1-based; a zero count means
				// "insert after line A" (A may be 0 for start-of-file).
				size_t fromLine = oldCount == 0 ? oldStart : oldStart - 1;
				hunk.active = true;
				hunk.from   = starts[std::min(fromLine, sentinel)];
				hunk.to     = starts[std::min(fromLine + oldCount, sentinel)];
			}
			else if(hunk.active && record[0] == '+')
			{
				hunk.replacement += record_content(record);
			}
			// '-' lines are implied by the hunk's byte range; with zero
			// context there are no ' ' records; '\' handled in record_content.
		});
		flush();

		// Degenerate fallback: byte-identical to the format-on-save
		// whole-buffer replacement precedent (OakTextView+Formatting.mm).
		bool sane = ok;
		if(sane)
		{
			std::string verify;
			size_t pos = 0;
			for(auto const& edit : res)
			{
				if(edit.first.first < pos || edit.first.second > oldText.size())
				{
					sane = false;
					break;
				}
				verify += oldText.substr(pos, edit.first.first - pos);
				verify += edit.second;
				pos = edit.first.second;
			}
			sane = sane && (verify + oldText.substr(pos)) == newText;
		}

		if(!sane)
		{
			res.clear();
			res.emplace(std::make_pair<size_t, size_t>(0, oldText.size()), newText);
		}
		return res;
	}

	void seal_edits (replacements_t& edits, std::string const& oldText)
	{
		if(edits.empty())
			return;

		auto widen = [&edits, &oldText](replacements_t::iterator it){
			size_t from = it->first.first, to = it->first.second;
			std::string str = it->second;

			bool pureInsert = from == to && !str.empty();
			bool pureErase  = from < to  &&  str.empty();
			if(!pureInsert && !pureErase)
				return;

			if(from > 0)
			{
				str.insert(0, 1, oldText[from-1]);
				--from;
			}
			else if(to < oldText.size())
			{
				str.push_back(oldText[to]);
				++to;
			}
			else
			{
				return; // spans all of oldText — nothing to widen into
			}

			edits.erase(it);
			edits.emplace(std::make_pair(from, to), str);
		};

		widen(edits.begin());
		if(edits.size() > 1)
			widen(std::prev(edits.end()));
	}

	std::string unified (std::string const& oldText, std::string const& newText, size_t context)
	{
		if(oldText == newText)
			return "";

		std::string res;
		if(!run_diff(oldText, newText, context, [&res](std::string&& record){ res += record; }))
			return "";
		if(!res.empty() && res.back() != '\n')
			res += '\n';
		return res;
	}

} /* text_diff */ } /* scm */
