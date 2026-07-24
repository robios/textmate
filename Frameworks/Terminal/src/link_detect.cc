#include "link_detect.h"
#include <cstring>

namespace
{
	bool is_space (char ch) { return ch == ' ' || ch == '\t'; }
	bool is_digit (char ch) { return ch >= '0' && ch <= '9'; }

	// Parse digits at `i`, returning the index past them. Zero digits ⇒ i unchanged.
	size_t parse_number (std::string const& str, size_t i, size_t& out)
	{
		out = 0;
		while(i < str.size() && is_digit(str[i]))
			out = out*10 + (str[i++] - '0');
		return i;
	}

	// Python traceback:  File "path/to/x.py", line 12
	bool python_traceback_at_offset (std::string const& line, size_t offset, terminal::file_link_t& res)
	{
		static char const* const kFilePrefix = "File \"";
		static char const* const kLinePrefix = "\", line ";

		for(size_t pos = line.find(kFilePrefix); pos != std::string::npos; pos = line.find(kFilePrefix, pos+1))
		{
			size_t pathBegin = pos + strlen(kFilePrefix);
			size_t pathEnd = line.find('"', pathBegin);
			if(pathEnd == std::string::npos || pathEnd == pathBegin)
				continue;
			if(line.compare(pathEnd, strlen(kLinePrefix), kLinePrefix) != 0)
				continue;

			size_t lineNo = 0;
			size_t last = parse_number(line, pathEnd + strlen(kLinePrefix), lineNo);
			if(lineNo == 0)
				continue;

			if(offset < pos || offset >= last)
				continue;

			res.first  = pathBegin;
			res.last   = last;
			res.path   = line.substr(pathBegin, pathEnd - pathBegin);
			res.alt_path.clear();
			res.line   = lineNo;
			res.column = 0;
			return true;
		}
		return false;
	}
}

namespace terminal
{
	bool link_at_offset (std::string const& line, size_t offset, file_link_t& res)
	{
		if(offset >= line.size())
			return false;

		if(python_traceback_at_offset(line, offset, res))
			return true;

		if(is_space(line[offset]))
			return false;

		size_t tokenBegin = offset;
		while(tokenBegin > 0 && !is_space(line[tokenBegin-1]))
			--tokenBegin;
		size_t tokenEnd = offset;
		while(tokenEnd < line.size() && !is_space(line[tokenEnd]))
			++tokenEnd;

		// Strip wrapping quotes/brackets and trailing punctuation. The
		// trailing set deliberately excludes ‘:’ — the :line:col suffix is
		// parsed below and anything past it is dropped there.
		static char const* const kOpening = "\"'`([<{";
		static char const* const kClosing = "\"'`)]>},.;!?";
		while(tokenBegin < tokenEnd && strchr(kOpening, line[tokenBegin]))
			++tokenBegin;
		while(tokenEnd > tokenBegin && strchr(kClosing, line[tokenEnd-1]))
			--tokenEnd;

		if(tokenBegin >= tokenEnd)
			return false;

		std::string const token = line.substr(tokenBegin, tokenEnd - tokenBegin);
		if(token.find("://") != std::string::npos) // URLs are not file links
			return false;

		// path[:line[:col]] — split at the first ‘:’ followed by a digit.
		size_t pathLen = token.size(), lineNo = 0, columnNo = 0, refEnd = token.size();
		for(size_t i = 1; i < token.size(); ++i)
		{
			if(token[i] == ':' && i+1 < token.size() && is_digit(token[i+1]))
			{
				pathLen = i;
				refEnd = parse_number(token, i+1, lineNo);
				if(refEnd+1 < token.size() && token[refEnd] == ':' && is_digit(token[refEnd+1]))
					refEnd = parse_number(token, refEnd+1, columnNo);
				break;
			}
		}

		// gcc context lines (“src/foo.cc: In function ‘x’:”) leave a bare
		// trailing colon when no :line follows — strip it from the candidate.
		if(pathLen == token.size() && token.back() == ':')
			pathLen = refEnd = token.size() - 1;

		std::string path = token.substr(0, pathLen);
		if(path.empty())
			return false;

		// Only stat-worthy candidates. Without a line suffix the token must be
		// path-shaped (‘/’ or ‘~’). With one, a slash-less name must still look
		// like a file name (contain a dot) — otherwise ‘localhost:8080’ or the
		// timestamp ‘12:34’ would become a link whenever a file by that name
		// happens to exist in the working directory.
		if(path.find('/') == std::string::npos && path[0] != '~')
		{
			if(lineNo == 0 || path.find('.') == std::string::npos)
				return false;
		}

		// The reference ends after the line/column digits — hovering e.g. the
		// match text of ‘grep -n’ output (path:12:match) is not a link.
		if(offset < tokenBegin || offset >= tokenBegin + refEnd)
			return false;

		res.first  = tokenBegin;
		res.last   = tokenBegin + refEnd;
		res.path   = path;
		res.line   = lineNo;
		res.column = columnNo;
		res.alt_path.clear();
		if(path.size() > 2 && (path[0] == 'a' || path[0] == 'b') && path[1] == '/')
			res.alt_path = path.substr(2); // git-diff prefix
		return true;
	}

} /* terminal */
