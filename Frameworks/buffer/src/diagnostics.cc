#include "meta_data.h"
#include <oak/oak.h>

namespace ng
{
	// 3 = information and 4 = hint read as ‘note’, and so do a missing or
	// nonsensical value: one normalization, shared by every surface.
	static size_t normalized_severity (size_t severity)
	{
		return severity == 1 || severity == 2 ? severity : 3;
	}

	// Trims the equal head and tail of two lists and folds whatever differs
	// into [dirtyFrom, dirtyTo], so an unchanged diagnostic elsewhere in the
	// buffer does not drag its rows into the repaint.
	template <typename _F>
	static bool fold_difference (std::vector<std::pair<size_t, size_t>> const& oldItems, std::vector<std::pair<size_t, size_t>> const& newItems, _F const& extent, size_t& dirtyFrom, size_t& dirtyTo)
	{
		if(oldItems == newItems)
			return false;

		size_t front = 0, oldBack = oldItems.size(), newBack = newItems.size();
		while(front < oldBack && front < newBack && oldItems[front] == newItems[front])
			++front;
		while(oldBack > front && newBack > front && oldItems[oldBack-1] == newItems[newBack-1])
			--oldBack, --newBack;

		for(size_t i = front; i < oldBack; ++i)
		{
			auto range = extent(oldItems[i]);
			dirtyFrom = std::min(dirtyFrom, range.first);
			dirtyTo   = std::max(dirtyTo, range.second);
		}
		for(size_t i = front; i < newBack; ++i)
		{
			auto range = extent(newItems[i]);
			dirtyFrom = std::min(dirtyFrom, range.first);
			dirtyTo   = std::max(dirtyTo, range.second);
		}

		return true;
	}

	void diagnostics_t::rebuild_indexes ()
	{
		for(size_t i = 0; i < kSeverityCount; ++i)
			_ranges[i].clear();
		_points.clear();
		_stops.clear();

		// ‘_diagnostics’ is sorted by ‘from’, so each severity’s subsequence is
		// too and coalescing only ever has to look at the last range kept.
		for(auto const& diagnostic : _diagnostics)
		{
			// Navigation stops are their own index because they are not ordered by
			// ‘from’: a range grown leftwards reports one past its start, so it can
			// come after a range that starts alongside it. Sorted and deduplicated
			// here, which is also what makes several diagnostics on one position a
			// single stop.
			_stops.push_back(diagnostic.reported_index());

			if(diagnostic.is_point())
			{
				auto it = std::lower_bound(_points.begin(), _points.end(), diagnostic.from, [](std::pair<size_t, size_t> const& lhs, size_t rhs){ return lhs.first < rhs; });
				if(it != _points.end() && it->first == diagnostic.from)
						it->second = std::min(it->second, diagnostic.severity); // one marker, worst severity
				else	_points.insert(it, { diagnostic.from, diagnostic.severity });
				continue;
			}

			auto& ranges = _ranges[severity_index(diagnostic.severity)];
			if(!ranges.empty() && diagnostic.from <= ranges.back().second)
					ranges.back().second = std::max(ranges.back().second, diagnostic.to);
			else	ranges.emplace_back(diagnostic.from, diagnostic.to);
		}

		std::sort(_stops.begin(), _stops.end());
		_stops.erase(std::unique(_stops.begin(), _stops.end()), _stops.end());
	}

	diagnostics_dirty_t diagnostics_t::set (std::vector<diagnostic_t> const& diagnostics)
	{
		std::vector<diagnostic_t> incoming;
		incoming.reserve(diagnostics.size());
		for(auto diagnostic : diagnostics)
		{
			if(diagnostic.to < diagnostic.from)
				continue;
			diagnostic.severity = normalized_severity(diagnostic.severity);
			incoming.push_back(std::move(diagnostic));
		}

		// Every field equality compares has to be in the key, or two entries that
		// differ only in an omitted one have no defined order and the same set
		// re-published in another order would read as a change.
		std::sort(incoming.begin(), incoming.end(), [](diagnostic_t const& lhs, diagnostic_t const& rhs){
			return std::tie(lhs.from, lhs.to, lhs.severity, lhs.zero_length, lhs.grown_left, lhs.message, lhs.source, lhs.code) < std::tie(rhs.from, rhs.to, rhs.severity, rhs.zero_length, rhs.grown_left, rhs.message, rhs.source, rhs.code);
		});

		std::vector<std::pair<size_t, size_t>> oldRanges[kSeverityCount], oldPoints;
		for(size_t i = 0; i < kSeverityCount; ++i)
			oldRanges[i].swap(_ranges[i]);
		oldPoints.swap(_points);
		std::vector<diagnostic_t> const oldDiagnostics = std::move(_diagnostics);

		_diagnostics = std::move(incoming);
		rebuild_indexes();

		bool redraw = false;
		size_t dirtyFrom = SIZE_MAX, dirtyTo = 0;

		auto rangeExtent = [](std::pair<size_t, size_t> const& range){ return range; };
		// Past the point's index, not on it, so the extent is half-open for
		// ranges and points alike. A consumer that sees only [from, to) cannot
		// tell the two apart, and one that treats the end as exclusive — as the
		// layout does, correctly, for a range ending at the start of a line —
		// would otherwise drop the very row the point sits on. Every point the
		// bridge publishes sits at a line start, so that was most of them.
		auto pointExtent = [](std::pair<size_t, size_t> const& point){ return std::make_pair(point.first, point.first + 1); };
		for(size_t i = 0; i < kSeverityCount; ++i)
			redraw = fold_difference(oldRanges[i], _ranges[i], rangeExtent, dirtyFrom, dirtyTo) || redraw;
		redraw = fold_difference(oldPoints, _points, pointExtent, dirtyFrom, dirtyTo) || redraw;

		diagnostics_dirty_t dirty;
		dirty.redraw = redraw;
		// Nothing moved, but the payload can still differ: a server that
		// re-publishes the same range with a new message must not leave a tooltip
		// serving the old one, even though there is nothing to repaint.
		dirty.changed = redraw || oldDiagnostics != _diagnostics;
		if(redraw && dirtyFrom != SIZE_MAX)
		{
			dirty.from = dirtyFrom;
			dirty.to   = dirtyTo;
		}
		return dirty;
	}

	std::vector<std::pair<size_t, size_t>> diagnostics_t::ranges (size_t severity, size_t from, size_t to) const
	{
		std::vector<std::pair<size_t, size_t>> res;
		if(to <= from)
			return res;

		auto const& ranges = _ranges[severity_index(normalized_severity(severity))];

		// The ranges are sorted and disjoint, so at most the one starting before
		// the window can still reach into it — the case a window-local toggle
		// scan would miss for a diagnostic split across style runs.
		auto it = std::upper_bound(ranges.begin(), ranges.end(), from, [](size_t lhs, std::pair<size_t, size_t> const& rhs){ return lhs < rhs.first; });
		if(it != ranges.begin() && (it-1)->second > from)
			--it;

		for(; it != ranges.end() && it->first < to; ++it)
			res.emplace_back(std::max(it->first, from) - from, std::min(it->second, to) - from);
		return res;
	}

	std::vector<std::pair<size_t, size_t>> diagnostics_t::points (size_t from, size_t to) const
	{
		std::vector<std::pair<size_t, size_t>> res;
		auto it = std::lower_bound(_points.begin(), _points.end(), from, [](std::pair<size_t, size_t> const& lhs, size_t rhs){ return lhs.first < rhs; });
		for(; it != _points.end() && it->first <= to; ++it) // inclusive: a point can sit at the end of the buffer
			res.push_back(*it);
		return res;
	}

	bool diagnostics_t::point_at (size_t index) const
	{
		auto it = std::lower_bound(_points.begin(), _points.end(), index, [](std::pair<size_t, size_t> const& lhs, size_t rhs){ return lhs.first < rhs; });
		return it != _points.end() && it->first == index;
	}

	std::pair<size_t, size_t> diagnostics_t::range_containing (size_t severity, size_t index) const
	{
		auto const& ranges = _ranges[severity_index(normalized_severity(severity))];
		auto it = std::upper_bound(ranges.begin(), ranges.end(), index, [](size_t lhs, std::pair<size_t, size_t> const& rhs){ return lhs < rhs.first; });
		if(it != ranges.begin() && (--it)->first <= index && index < it->second)
			return *it;
		return { 0, 0 };
	}

	std::vector<diagnostic_t> diagnostics_t::at (size_t index) const
	{
		std::vector<diagnostic_t> res;
		for(auto const& diagnostic : _diagnostics)
		{
			if(diagnostic.from > index)
				break;
			if(diagnostic.is_point() ? diagnostic.from == index : index < diagnostic.to || (diagnostic.zero_length && index == diagnostic.to))
				res.push_back(diagnostic);
		}
		return res;
	}

	// ‘to’ counts as inside, so a caller holding a line’s extent as
	// [begin, eol] gets an answer for an empty line too — there the two are the
	// same index, and asking about a half-open window there would ask about
	// nothing. A range is still matched half-open, so the one that ends where
	// this window begins (the common LSP range stopping at the next line’s
	// start) belongs to the line before, not to this one.
	bool diagnostics_t::any_in (size_t from, size_t to) const
	{
		if(from > to)
			return false;

		for(size_t i = 0; i < kSeverityCount; ++i)
		{
			auto const& ranges = _ranges[i];
			// Sorted and disjoint, so of everything that starts at or before ‘to’
			// the last one reaches furthest: if that one stops short of ‘from’,
			// they all do.
			auto it = std::upper_bound(ranges.begin(), ranges.end(), to, [](size_t lhs, std::pair<size_t, size_t> const& rhs){ return lhs < rhs.first; });
			if(it != ranges.begin() && (it-1)->second > from)
				return true;
		}

		auto it = std::lower_bound(_points.begin(), _points.end(), from, [](std::pair<size_t, size_t> const& lhs, size_t rhs){ return lhs.first < rhs; });
		return it != _points.end() && it->first <= to;
	}

	// Navigation wraps, the way the gutter marks this replaced did: a reader
	// walking the file’s problems expects to come back round to the first one
	// rather than to stop at the last.
	size_t diagnostics_t::next_stop (size_t index) const
	{
		if(_stops.empty())
			return SIZE_MAX;

		auto it = std::upper_bound(_stops.begin(), _stops.end(), index);
		return it != _stops.end() ? *it : _stops.front();
	}

	size_t diagnostics_t::previous_stop (size_t index) const
	{
		if(_stops.empty())
			return SIZE_MAX;

		auto it = std::lower_bound(_stops.begin(), _stops.end(), index);
		return it != _stops.begin() ? *(it-1) : _stops.back();
	}

	// Endpoint affinity: text inserted exactly at a range start or end lands
	// outside the range, text inserted strictly inside is included.
	//
	// A replacement is applied the way the buffer performs it — as the deletion
	// followed by the insertion — because that is what makes an edit *aligned*
	// with an endpoint behave like an insertion there. Collapsing the two steps
	// into one shifted formula gets the strictly-crossing cases right but silently
	// reverses the equality cases: replacing a range's first character would grow
	// the range over the new text instead of contracting past it.
	//
	// A range left empty by the deletion step is gone: whether the edit removed
	// the annotated text or typed something else over it, what the server said no
	// longer describes anything. Doing all of this on the diagnostic list (rather
	// than shifting a toggle tree) is what keeps starts and ends paired.
	void diagnostics_t::replace (buffer_t* buffer, size_t from, size_t to, size_t len)
	{
		if(_diagnostics.empty())
			return;

		auto transform = [&](size_t pos, bool isStart) -> size_t {
			if(pos >= to)
					pos -= to - from;  // the deletion: entirely before ‘pos’
			else if(pos > from)
					pos = from;        // …or it took the text ‘pos’ was sitting in
			// the insertion at ‘from’: starts bind right, ends bind left
			return pos > from || (pos == from && isStart) ? pos + len : pos;
		};

		std::vector<diagnostic_t> survivors;
		survivors.reserve(_diagnostics.size());
		for(auto& diagnostic : _diagnostics)
		{
			bool const point = diagnostic.is_point();
			size_t const newFrom = transform(diagnostic.from, true);
			size_t const newTo   = point ? newFrom : transform(diagnostic.to, false);
			if(!point && newFrom >= newTo)
				continue;

			diagnostic.from = newFrom;
			diagnostic.to   = newTo;
			survivors.push_back(std::move(diagnostic));
		}

		// The transform is monotonic, so the list stays sorted by ‘from’
		_diagnostics = std::move(survivors);
		rebuild_indexes();
	}

} /* ng */
