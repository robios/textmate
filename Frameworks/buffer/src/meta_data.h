#ifndef BUFFER_META_DATA_H_Z0JQSBGY
#define BUFFER_META_DATA_H_Z0JQSBGY

#include "buffer.h"

namespace ng
{
	struct spelling_t : meta_data_t
	{
		bool disabled () const        { return _disabled; }
		void set_disabled (bool flag) { _disabled = flag; }

		void check_spelling (buffer_t const* buffer);
		std::map<size_t, bool> misspellings (buffer_t const* buffer, size_t from, size_t to) const;

		bool misspelled_at (size_t i) const;
		std::pair<size_t, size_t> next_misspelling (size_t from) const;
		void recheck (buffer_t const* buffer, size_t from, size_t to);

	private:
		void replace (buffer_t* buffer, size_t from, size_t to, size_t len);
		void did_parse (buffer_t const* buffer, size_t from, size_t to);

		typedef indexed_map_t<bool> tree_t;
		tree_t _misspellings;    // true = misspelled, false = proper
		bool _disabled = false;
	};

	// The diagnostic list is the single source of truth: it carries the payload
	// and it is what edits transform, so a squiggle and the message read at the
	// same index can never disagree. The per-severity coalesced range lists and
	// the point list are derived indexes for drawing and hit testing.
	struct diagnostics_t : meta_data_t
	{
		diagnostics_dirty_t set (std::vector<diagnostic_t> const& diagnostics);

		std::vector<std::pair<size_t, size_t>> ranges (size_t severity, size_t from, size_t to) const;
		std::vector<std::pair<size_t, size_t>> points (size_t from, size_t to) const;
		bool point_at (size_t index) const;
		std::pair<size_t, size_t> range_containing (size_t severity, size_t index) const;
		std::vector<diagnostic_t> at (size_t index) const;

		bool empty () const { return _diagnostics.empty(); }

	private:
		void replace (buffer_t* buffer, size_t from, size_t to, size_t len);
		using meta_data_t::did_parse;

		void rebuild_indexes ();

		static constexpr size_t kSeverityCount = 3;
		static size_t severity_index (size_t severity) { return severity == 1 ? 0 : (severity == 2 ? 1 : 2); }

		std::vector<diagnostic_t> _diagnostics;                         // sorted by ‘from’
		std::vector<std::pair<size_t, size_t>> _ranges[kSeverityCount]; // coalesced (from, to) per severity class
		std::vector<std::pair<size_t, size_t>> _points;                 // (index, worst severity), sorted by index
	};

	struct symbols_t : meta_data_t
	{
		std::map<size_t, std::string> symbols (buffer_t const* buffer) const;
		std::string symbol_at (buffer_t const* buffer, size_t i) const;

	private:
		void replace (buffer_t* buffer, size_t from, size_t to, size_t len);
		void did_parse (buffer_t const* buffer, size_t from, size_t to);

		typedef indexed_map_t<std::string> tree_t;
		tree_t _symbols;
	};

	struct marks_t : meta_data_t
	{
		void set (size_t index, std::string const& markType, std::string const& value);
		void remove (size_t index, std::string const& markType);
		void remove_all (std::string const& markType);
		std::string get (size_t index, std::string const& markType) const;
		std::multimap<size_t, std::pair<std::string, std::string>> get_range (size_t from, size_t to) const;
		std::map<size_t, std::string> get_range (size_t from, size_t to, std::string const& markType) const;

		std::pair<size_t, std::string> next (size_t index, std::string const& markType) const;
		std::pair<size_t, std::string> prev (size_t index, std::string const& markType) const;

	private:
		void replace (buffer_t* buffer, size_t from, size_t to, size_t len);
		using meta_data_t::did_parse;

		typedef indexed_map_t<std::string> tree_t;
		std::map<std::string, tree_t> _marks;
	};

} /* ng */

#endif /* end of include guard: BUFFER_META_DATA_H_Z0JQSBGY */
