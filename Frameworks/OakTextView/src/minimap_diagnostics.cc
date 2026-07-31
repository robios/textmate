#include "minimap_diagnostics.h"

#include <algorithm>

namespace minimap
{
	std::map<size_t, size_t> diagnostic_rows (ng::buffer_t const& buffer, size_t firstLine, size_t lastLine)
	{
		std::map<size_t, size_t> res;
		if(!buffer.has_diagnostics())
			return res;

		lastLine = std::min(lastLine, buffer.lines()-1);
		if(firstLine > lastLine)
			return res;

		size_t const windowFrom = buffer.begin(firstLine);
		size_t const windowTo   = buffer.end(lastLine); // past the line's newline, which still belongs to it

		auto mark = [&](size_t line, size_t severity) {
			if(line < firstLine || lastLine < line)
				return;
			severity = severity == 1 || severity == 2 ? severity : 3; // the buffer normalizes; stay total anyway
			auto it = res.find(line);
			if(it == res.end())
					res.emplace(line, severity);
			else	it->second = std::min(it->second, severity);
		};

		for(size_t severity = 1; severity <= 3; ++severity)
		{
			// Window-relative and already clamped to it, including the range
			// that started before the window and reaches into it.
			for(auto const& range : buffer.diagnostics(severity, windowFrom, windowTo))
			{
				size_t const from = windowFrom + range.first;
				size_t const to   = windowFrom + range.second;
				for(size_t line = buffer.convert(from).line, last = buffer.convert(to > from ? to-1 : to).line; line <= last; ++line)
					mark(line, severity);
			}
		}

		for(auto const& point : buffer.diagnostic_points(windowFrom, windowTo))
			mark(buffer.convert(point.first).line, point.second);

		return res;
	}

	row_span_t dirty_rows (ng::buffer_t const& buffer, size_t from, size_t to)
	{
		size_t const size = buffer.size();
		from = std::min(from, size);
		to   = std::clamp(to, from, size + 1); // one past the end: where a point on a trailing empty line ends

		return { buffer.convert(from).line, buffer.convert(to > from ? to-1 : to).line };
	}

} /* minimap */
