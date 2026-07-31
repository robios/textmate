#include <buffer/buffer.h>

typedef std::vector<std::pair<size_t, size_t>> ranges_t;

// Spelled out because a std::make_pair<size_t, size_t> inside OAK_ASSERT reads
// as two macro arguments.
static std::pair<size_t, size_t> pair (size_t from, size_t to) { return { from, to }; }

static ng::diagnostic_t diag (size_t from, size_t to, size_t severity = 1, std::string const& message = "")
{
	ng::diagnostic_t res;
	res.from     = from;
	res.to       = to;
	res.severity = severity;
	res.message  = message;
	return res;
}

// The invariant every mutation has to preserve: within a severity the ranges are
// sorted, disjoint, non-empty, and points sit outside them.
static void assert_well_formed (ng::buffer_t const& buf)
{
	for(size_t severity = 1; severity <= 3; ++severity)
	{
		ranges_t const ranges = buf.diagnostics(severity, 0, std::max<size_t>(buf.size(), 1));
		size_t last = 0;
		for(auto const& range : ranges)
		{
			OAK_ASSERT_LT(range.first, range.second);
			OAK_ASSERT_LE(last, range.first);
			last = range.second;
		}
	}

	for(auto const& point : buf.diagnostic_points(0, buf.size()))
	{
		OAK_ASSERT_LE(point.first, buf.size());
		OAK_ASSERT(1 <= point.second && point.second <= 3);
	}
}

void test_diagnostics_basic ()
{
	ng::buffer_t buf;
	buf.insert(0, "int main () { return x; }\n");

	OAK_ASSERT(!buf.has_diagnostics());

	auto dirty = buf.set_diagnostics({ diag(21, 22, 1, "undefined: x") }); // ‘x’
	OAK_ASSERT(buf.has_diagnostics());
	OAK_ASSERT(dirty.changed);
	OAK_ASSERT_EQ(dirty.from, 21);
	OAK_ASSERT_EQ(dirty.to, 22);

	OAK_ASSERT(buf.diagnostics(1, 0, buf.size()) == (ranges_t{ { 21, 22 } }));
	OAK_ASSERT(buf.diagnostics(2, 0, buf.size()).empty());
	OAK_ASSERT(buf.diagnostics(3, 0, buf.size()).empty());
	assert_well_formed(buf);

	auto hits = buf.diagnostics_at(21);
	OAK_ASSERT_EQ(hits.size(), 1);
	OAK_ASSERT(hits[0].message == "undefined: x");
	OAK_ASSERT(buf.diagnostics_at(22).empty()); // LSP ranges are end-exclusive
	OAK_ASSERT(buf.diagnostics_at(20).empty());
}

void test_diagnostics_grown_zero_length_range ()
{
	// A range the bridge grew leftwards to cover the last character of a line:
	// the caret at the position the server reported (the end) must still find it
	ng::buffer_t buf;
	buf.insert(0, "abc\ndef\n");

	ng::diagnostic_t missingToken = diag(2, 3, 1, "expected ‘;’");
	missingToken.zero_length = true;
	buf.set_diagnostics({ missingToken });

	OAK_ASSERT_EQ(buf.diagnostics_at(2).size(), 1);
	OAK_ASSERT_EQ(buf.diagnostics_at(3).size(), 1); // end of line — as reported
	OAK_ASSERT(buf.diagnostics_at(4).empty());
	OAK_ASSERT(buf.diagnostics(1, 0, buf.size()) == (ranges_t{ { 2, 3 } }));
}

void test_diagnostics_window_offsets ()
{
	ng::buffer_t buf;
	buf.insert(0, "0123456789");
	buf.set_diagnostics({ diag(2, 8, 2) });

	// Offsets are relative to the window start, like buffer_t::misspellings
	OAK_ASSERT(buf.diagnostics(2, 4, 9) == (ranges_t{ { 0, 4 } }));

	// Window strictly inside the range: no endpoint inside it, still active
	OAK_ASSERT(buf.diagnostics(2, 3, 7) == (ranges_t{ { 0, 4 } }));

	// A range ending exactly at the window start is not active inside it
	OAK_ASSERT(buf.diagnostics(2, 8, 10).empty());

	// …and one starting exactly at the window end is not either
	OAK_ASSERT(buf.diagnostics(2, 0, 2).empty());
}

void test_diagnostics_overlap_coalescing ()
{
	ng::buffer_t buf;
	buf.insert(0, "0123456789");
	buf.set_diagnostics({ diag(5, 8), diag(1, 3), diag(2, 6) });

	// Same severity overlaps merge for drawing…
	OAK_ASSERT(buf.diagnostics(1, 0, buf.size()) == (ranges_t{ { 1, 8 } }));
	assert_well_formed(buf);

	// …but each keeps its own payload
	OAK_ASSERT_EQ(buf.diagnostics_at(2).size(), 2);
	OAK_ASSERT_EQ(buf.diagnostics_at(7).size(), 1);
}

void test_diagnostics_severities_are_independent ()
{
	ng::buffer_t buf;
	buf.insert(0, "0123456789");
	buf.set_diagnostics({ diag(1, 4, 1), diag(2, 6, 2), diag(0, 9, 7) }); // 7 clamps to note

	OAK_ASSERT(buf.diagnostics(1, 0, buf.size()) == (ranges_t{ { 1, 4 } }));
	OAK_ASSERT(buf.diagnostics(2, 0, buf.size()) == (ranges_t{ { 2, 6 } }));
	OAK_ASSERT(buf.diagnostics(3, 0, buf.size()) == (ranges_t{ { 0, 9 } }));
	assert_well_formed(buf);

	// Missing, out-of-range and hint severities all read as note
	buf.set_diagnostics({ diag(1, 2, 0), diag(3, 4, 4), diag(5, 6, 99) });
	OAK_ASSERT(buf.diagnostics(3, 0, buf.size()) == (ranges_t{ { 1, 2 }, { 3, 4 }, { 5, 6 } }));
	OAK_ASSERT(buf.diagnostics(1, 0, buf.size()).empty());
}

void test_diagnostics_range_containing ()
{
	ng::buffer_t buf;
	buf.insert(0, "0123456789");
	buf.set_diagnostics({ diag(2, 5, 1), diag(6, 9, 2) });

	OAK_ASSERT(buf.diagnostic_range_containing(1, 2) == pair(2, 5));
	OAK_ASSERT(buf.diagnostic_range_containing(1, 4) == pair(2, 5));
	OAK_ASSERT(buf.diagnostic_range_containing(1, 5) == pair(0, 0)); // end-exclusive
	OAK_ASSERT(buf.diagnostic_range_containing(1, 1) == pair(0, 0));
	OAK_ASSERT(buf.diagnostic_range_containing(1, 7) == pair(0, 0)); // wrong severity
	OAK_ASSERT(buf.diagnostic_range_containing(2, 7) == pair(6, 9));
}

void test_diagnostics_nested_ranges ()
{
	// Nested and partially overlapping diagnostics: the drawn range coalesces, but
	// the payloads must be read at the queried index rather than at the start of
	// the range that contains it — the inner one begins later than the outer.
	ng::buffer_t buf;
	buf.insert(0, "0123456789");

	buf.set_diagnostics({ diag(4, 8, 1, "outer"), diag(5, 6, 1, "inner") });
	OAK_ASSERT(buf.diagnostics(1, 0, buf.size()) == (ranges_t{ { 4, 8 } }));
	OAK_ASSERT(buf.diagnostic_range_containing(1, 5) == pair(4, 8));

	OAK_ASSERT_EQ(buf.diagnostics_at(4).size(), 1); // the range start sees only the outer one
	OAK_ASSERT(buf.diagnostics_at(4)[0].message == "outer");
	OAK_ASSERT_EQ(buf.diagnostics_at(5).size(), 2); // …the index under the pointer sees both
	assert_well_formed(buf);

	// Same across severities: the union covers both, each lane keeps its own range
	buf.set_diagnostics({ diag(4, 8, 1, "outer"), diag(5, 6, 2, "inner") });
	OAK_ASSERT(buf.diagnostic_range_containing(1, 5) == pair(4, 8));
	OAK_ASSERT(buf.diagnostic_range_containing(2, 5) == pair(5, 6));
	OAK_ASSERT(buf.diagnostic_range_containing(2, 4) == pair(0, 0));

	OAK_ASSERT_EQ(buf.diagnostics_at(4).size(), 1);
	OAK_ASSERT_EQ(buf.diagnostics_at(5).size(), 2);
	OAK_ASSERT_EQ(buf.diagnostics_at(6).size(), 1);
	assert_well_formed(buf);
}

void test_diagnostics_dirty_extent ()
{
	ng::buffer_t buf;
	buf.insert(0, "0123456789012345678901234567890123456789\n");

	buf.set_diagnostics({ diag(2, 5), diag(30, 35) });

	// Same set again: nothing changed, nothing to redraw
	auto dirty = buf.set_diagnostics({ diag(2, 5), diag(30, 35) });
	OAK_ASSERT(!dirty.changed);

	// Only the tail range moved: the untouched head range must not dirty
	dirty = buf.set_diagnostics({ diag(2, 5), diag(30, 37) });
	OAK_ASSERT(dirty.changed);
	OAK_ASSERT_EQ(dirty.from, 30);
	OAK_ASSERT_EQ(dirty.to, 37);

	// Clearing dirties the extent of what was removed
	dirty = buf.set_diagnostics({});
	OAK_ASSERT(dirty.changed);
	OAK_ASSERT_EQ(dirty.from, 2);
	OAK_ASSERT_EQ(dirty.to, 37);
	OAK_ASSERT(!buf.has_diagnostics());
}

void test_diagnostics_points ()
{
	ng::buffer_t buf;
	buf.insert(0, "abc\n\ndef\n");

	// A point on the empty line 1 (index 4) — nothing to underline there
	auto dirty = buf.set_diagnostics({ diag(4, 4, 1, "expected expression") });
	OAK_ASSERT(dirty.changed);
	OAK_ASSERT_EQ(dirty.from, 4);
	// A byte past the point, so the extent is half-open like a range's. A point
	// sits at a line start, and a consumer excluding the end — which is right
	// for a range that stops where a line begins — would skip its row.
	OAK_ASSERT_EQ(dirty.to, 5);
	OAK_ASSERT(buf.has_diagnostics());
	OAK_ASSERT(buf.diagnostics(1, 0, buf.size()).empty()); // not a drawable range
	OAK_ASSERT(buf.diagnostic_points(0, buf.size()) == (ranges_t{ { 4, 1 } }));
	assert_well_formed(buf);

	OAK_ASSERT_EQ(buf.diagnostics_at(4).size(), 1);
	OAK_ASSERT(buf.diagnostics_at(5).empty());

	// Points shift with edits like ranges do
	buf.insert(0, "xx");
	OAK_ASSERT(buf.diagnostic_points(0, buf.size()) == (ranges_t{ { 6, 1 } }));

	// Worst severity wins for the marker, both payloads stay
	buf.set_diagnostics({ diag(6, 6, 3), diag(6, 6, 1) });
	OAK_ASSERT(buf.diagnostic_points(0, buf.size()) == (ranges_t{ { 6, 1 } }));
	OAK_ASSERT_EQ(buf.diagnostics_at(6).size(), 2);

	// A point in an empty document reports a dirty region a byte extent cannot
	ng::buffer_t empty;
	dirty = empty.set_diagnostics({ diag(0, 0, 1) });
	OAK_ASSERT(dirty.changed);
	OAK_ASSERT_EQ(dirty.from, 0);
	OAK_ASSERT_EQ(dirty.to, 1); // …past the end of the document, which has no byte at all
	OAK_ASSERT(empty.diagnostic_points(0, 0) == (ranges_t{ { 0, 1 } }));
}

// The case the half-open point extent exists for: a change with an earlier
// diagnostic in it, whose furthest point sits at the start of a row. Reported
// as ending ON that index, the row would fall outside a consumer's [from, to)
// and keep a marker the server has just moved or withdrawn.
void test_diagnostics_point_extent_covers_its_row ()
{
	ng::buffer_t buf;
	buf.insert(0, "abc\n\ndef\n"); // line 1 is empty at index 4

	buf.set_diagnostics({ diag(0, 3, 1), diag(4, 4, 1) });
	auto dirty = buf.set_diagnostics({ diag(1, 3, 1), diag(4, 4, 2) });
	OAK_ASSERT(dirty.redraw);
	OAK_ASSERT_EQ(dirty.from, 0);
	OAK_ASSERT_EQ(dirty.to, 5); // not 4, which is where line 1 begins

	// …and the same for a point on a trailing empty line, whose index is the
	// size of the buffer: the extent runs one past it
	ng::buffer_t trailing;
	trailing.insert(0, "abc\n");
	trailing.set_diagnostics({ diag(0, 3, 1), diag(4, 4, 1) });
	dirty = trailing.set_diagnostics({ diag(1, 3, 1), diag(4, 4, 2) });
	OAK_ASSERT(dirty.redraw);
	OAK_ASSERT_EQ(dirty.to, trailing.size() + 1);
}

void test_diagnostics_shift_on_edit ()
{
	ng::buffer_t buf;
	buf.insert(0, "abc def\n");
	buf.set_diagnostics({ diag(4, 7) }); // ‘def’

	buf.insert(0, "xx");
	OAK_ASSERT(buf.diagnostics(1, 0, buf.size()) == (ranges_t{ { 6, 9 } }));
	assert_well_formed(buf);

	// The payload travels with the range: the message is still found at the text
	OAK_ASSERT_EQ(buf.diagnostics_at(6).size(), 1);
	OAK_ASSERT(buf.diagnostics_at(4).empty());
}

void test_diagnostics_insertion_at_boundaries ()
{
	// Exactly at the start: the new text is outside the range
	{
		ng::buffer_t buf;
		buf.insert(0, "abc def\n");
		buf.set_diagnostics({ diag(4, 7) });
		buf.insert(4, "XY");
		OAK_ASSERT(buf.diagnostics(1, 0, buf.size()) == (ranges_t{ { 6, 9 } }));
		assert_well_formed(buf);
	}

	// Strictly inside: the new text is included
	{
		ng::buffer_t buf;
		buf.insert(0, "abc def\n");
		buf.set_diagnostics({ diag(4, 7) });
		buf.insert(5, "XY");
		OAK_ASSERT(buf.diagnostics(1, 0, buf.size()) == (ranges_t{ { 4, 9 } }));
		assert_well_formed(buf);
	}

	// Exactly at the end: the new text is outside the range
	{
		ng::buffer_t buf;
		buf.insert(0, "abc def\n");
		buf.set_diagnostics({ diag(4, 7) });
		buf.insert(7, "XY");
		OAK_ASSERT(buf.diagnostics(1, 0, buf.size()) == (ranges_t{ { 4, 7 } }));
		assert_well_formed(buf);
	}

	// Between two adjacent ranges the text joins neither
	{
		ng::buffer_t buf;
		buf.insert(0, "abcdefghij");
		buf.set_diagnostics({ diag(2, 5), diag(5, 8) });
		buf.insert(5, "XY");
		OAK_ASSERT(buf.diagnostics(1, 0, buf.size()) == (ranges_t{ { 2, 5 }, { 7, 10 } }));
		assert_well_formed(buf);
	}
}

void test_diagnostics_deletion_at_boundaries ()
{
	// Across the start: the range contracts to the edit boundary
	{
		ng::buffer_t buf;
		buf.insert(0, "abc def\n");
		buf.set_diagnostics({ diag(4, 7) });
		buf.erase(3, 5); // ‘ d’
		OAK_ASSERT(buf.diagnostics(1, 0, buf.size()) == (ranges_t{ { 3, 5 } }));
		assert_well_formed(buf);
	}

	// Across the end
	{
		ng::buffer_t buf;
		buf.insert(0, "abc def\n");
		buf.set_diagnostics({ diag(4, 7) });
		buf.erase(6, 8); // ‘f\n’
		OAK_ASSERT(buf.diagnostics(1, 0, buf.size()) == (ranges_t{ { 4, 6 } }));
		assert_well_formed(buf);
	}

	// Interior only
	{
		ng::buffer_t buf;
		buf.insert(0, "abc def\n");
		buf.set_diagnostics({ diag(4, 7) });
		buf.erase(5, 6); // ‘e’
		OAK_ASSERT(buf.diagnostics(1, 0, buf.size()) == (ranges_t{ { 4, 6 } }));
		assert_well_formed(buf);
	}

	// The whole range: the diagnostic disappears, and so does has_diagnostics()
	{
		ng::buffer_t buf;
		buf.insert(0, "abc def\n");
		buf.set_diagnostics({ diag(4, 7) });
		buf.erase(4, 7);
		OAK_ASSERT(buf.diagnostics(1, 0, buf.size()).empty());
		OAK_ASSERT(!buf.has_diagnostics());
		OAK_ASSERT(buf.diagnostics_at(4).empty());
		assert_well_formed(buf);
	}

	// A deletion spanning two ranges keeps what survives of each; both now end
	// and start at the edit point, so they coalesce into one drawn range
	{
		ng::buffer_t buf;
		buf.insert(0, "abcdefghij");
		buf.set_diagnostics({ diag(1, 4), diag(6, 9) });
		buf.erase(3, 7);
		OAK_ASSERT(buf.diagnostics(1, 0, buf.size()) == (ranges_t{ { 1, 5 } }));
		OAK_ASSERT_EQ(buf.diagnostics_at(2).size(), 1); // still two diagnostics, not one
		OAK_ASSERT_EQ(buf.diagnostics_at(4).size(), 1);
		assert_well_formed(buf);
	}
}

void test_diagnostics_replacement_at_boundaries ()
{
	// Replacing text that consumes the start: the range starts after the new text
	{
		ng::buffer_t buf;
		buf.insert(0, "abc def\n");
		buf.set_diagnostics({ diag(4, 7) });
		buf.replace(3, 5, "XY"); // ‘ d’ → ‘XY’
		OAK_ASSERT(buf.diagnostics(1, 0, buf.size()) == (ranges_t{ { 5, 7 } }));
		assert_well_formed(buf);
	}

	// Consuming the end: the range ends where the replacement begins
	{
		ng::buffer_t buf;
		buf.insert(0, "abc def\n");
		buf.set_diagnostics({ diag(4, 7) });
		buf.replace(6, 8, "XYZ"); // ‘f\n’ → ‘XYZ’
		OAK_ASSERT(buf.diagnostics(1, 0, buf.size()) == (ranges_t{ { 4, 6 } }));
		assert_well_formed(buf);
	}

	// Replacing the interior keeps the range around the new text
	{
		ng::buffer_t buf;
		buf.insert(0, "abc def\n");
		buf.set_diagnostics({ diag(4, 7) });
		buf.replace(5, 6, "XYZ"); // ‘e’ → ‘XYZ’
		OAK_ASSERT(buf.diagnostics(1, 0, buf.size()) == (ranges_t{ { 4, 9 } }));
		assert_well_formed(buf);
	}

	// Replacing the whole range drops it, even though the replacement is longer
	{
		ng::buffer_t buf;
		buf.insert(0, "abc def\n");
		buf.set_diagnostics({ diag(4, 7) });
		buf.replace(4, 7, "XYZW");
		OAK_ASSERT(buf.diagnostics(1, 0, buf.size()).empty());
		OAK_ASSERT(!buf.has_diagnostics());
		assert_well_formed(buf);
	}

	// A replacement fully containing the range drops it too
	{
		ng::buffer_t buf;
		buf.insert(0, "abc def\n");
		buf.set_diagnostics({ diag(4, 7) });
		buf.replace(3, 8, "X");
		OAK_ASSERT(buf.diagnostics(1, 0, buf.size()).empty());
		OAK_ASSERT(!buf.has_diagnostics());
		assert_well_formed(buf);
	}
}

// The endpoint-aligned cases: an edit that begins exactly at a range start, or
// ends exactly at its end, has to behave like an insertion there — the new text
// belongs to whoever typed it, not to the diagnostic. These are the cases a
// single shifted formula gets backwards, so they are worth their own test.
void test_diagnostics_replacement_aligned_with_endpoint ()
{
	// Beginning exactly at the start: the range starts after the new text
	{
		ng::buffer_t buf;
		buf.insert(0, "abc def\n");
		buf.set_diagnostics({ diag(4, 7, 1, "undefined") }); // ‘def’
		buf.replace(4, 5, "XY");                             // ‘d’ → ‘XY’, so ‘abc XYef’
		OAK_ASSERT(buf.diagnostics(1, 0, buf.size()) == (ranges_t{ { 6, 8 } }));
		OAK_ASSERT_EQ(buf.diagnostics_at(6).size(), 1);
		OAK_ASSERT(buf.diagnostics_at(6)[0].message == "undefined");
		OAK_ASSERT(buf.diagnostics_at(5).empty()); // the typed text is not annotated
		assert_well_formed(buf);
	}

	// Ending exactly at the end: the range ends where the new text begins
	{
		ng::buffer_t buf;
		buf.insert(0, "abc def\n");
		buf.set_diagnostics({ diag(4, 7, 1, "undefined") });
		buf.replace(6, 7, "XY");                             // ‘f’ → ‘XY’, so ‘abc deXY’
		OAK_ASSERT(buf.diagnostics(1, 0, buf.size()) == (ranges_t{ { 4, 6 } }));
		OAK_ASSERT_EQ(buf.diagnostics_at(5).size(), 1);
		OAK_ASSERT(buf.diagnostics_at(5)[0].message == "undefined");
		OAK_ASSERT(buf.diagnostics_at(6).empty());
		assert_well_formed(buf);
	}

	// Both at once is the whole range: nothing annotated survives
	{
		ng::buffer_t buf;
		buf.insert(0, "abc def\n");
		buf.set_diagnostics({ diag(4, 7) });
		buf.replace(4, 7, "XY");
		OAK_ASSERT(!buf.has_diagnostics());
		assert_well_formed(buf);
	}

	// A deletion aligned with the start still contracts, not grows
	{
		ng::buffer_t buf;
		buf.insert(0, "abc def\n");
		buf.set_diagnostics({ diag(4, 7) });
		buf.erase(4, 5);
		OAK_ASSERT(buf.diagnostics(1, 0, buf.size()) == (ranges_t{ { 4, 6 } }));
		assert_well_formed(buf);
	}

	// A point aligned with the edit start binds right, like a range start does
	{
		ng::buffer_t buf;
		buf.insert(0, "abc\n\ndef\n");
		buf.set_diagnostics({ diag(4, 4, 1) });
		buf.replace(4, 4, "XY"); // typing on the empty line the point sat on
		OAK_ASSERT(buf.diagnostic_points(0, buf.size()) == (ranges_t{ { 6, 1 } }));
		assert_well_formed(buf);
	}

	// A point swallowed by an edit relocates rather than disappearing: it marks a
	// position where something is missing, and that position survives an edit that
	// removes the text around it — unlike a range, whose annotated text is gone.
	{
		ng::buffer_t buf;
		buf.insert(0, "abc\n\n\ndef\n");
		buf.set_diagnostics({ diag(5, 5, 1) }); // the second empty line
		buf.erase(4, 6);                        // both empty lines
		OAK_ASSERT(buf.diagnostic_points(0, buf.size()) == (ranges_t{ { 4, 1 } }));
		OAK_ASSERT_EQ(buf.diagnostics_at(4).size(), 1);
		assert_well_formed(buf);
	}

	// …and binds right of replacement text, for the same reason a range start does
	{
		ng::buffer_t buf;
		buf.insert(0, "abc\n\n\ndef\n");
		buf.set_diagnostics({ diag(5, 5, 1) });
		buf.replace(4, 6, "XY");
		OAK_ASSERT(buf.diagnostic_points(0, buf.size()) == (ranges_t{ { 6, 1 } }));
		assert_well_formed(buf);
	}
}

void test_diagnostics_payload_only_change ()
{
	ng::buffer_t buf;
	buf.insert(0, "abc def\n");

	auto dirty = buf.set_diagnostics({ diag(4, 7, 1, "first") });
	OAK_ASSERT(dirty.changed);
	OAK_ASSERT(dirty.redraw);

	// Identical re-publish: silent, as pyright sends many
	dirty = buf.set_diagnostics({ diag(4, 7, 1, "first") });
	OAK_ASSERT(!dirty.changed);
	OAK_ASSERT(!dirty.redraw);

	// Same range and severity, new message: nothing to repaint, but a surface
	// showing the old message has to be told
	dirty = buf.set_diagnostics({ diag(4, 7, 1, "second") });
	OAK_ASSERT(dirty.changed);
	OAK_ASSERT(!dirty.redraw);
	OAK_ASSERT(buf.diagnostics_at(4)[0].message == "second");

	// So does a source/code change
	ng::diagnostic_t withCode = diag(4, 7, 1, "second");
	withCode.source = "pyright";
	withCode.code   = "reportUndefinedVariable";
	dirty = buf.set_diagnostics({ withCode });
	OAK_ASSERT(dirty.changed);
	OAK_ASSERT(!dirty.redraw);

	// A severity change does move the squiggle between severity lanes
	dirty = buf.set_diagnostics({ diag(4, 7, 2, "second") });
	OAK_ASSERT(dirty.changed);
	OAK_ASSERT(dirty.redraw);
}

void test_diagnostics_publish_order_is_canonical ()
{
	// Two diagnostics that differ only in a field the sort key could have left
	// out. Re-publishing the same set in another order must still read as
	// unchanged, or every reordered publish would invalidate tooltips for nothing.
	ng::buffer_t buf;
	buf.insert(0, "abc def\n");

	ng::diagnostic_t first = diag(4, 7, 1, "shadowed");
	first.source = "pyright";
	first.code   = "reportShadowedImport";

	ng::diagnostic_t second = diag(4, 7, 1, "shadowed");
	second.source = "ruff";
	second.code   = "F811";

	auto dirty = buf.set_diagnostics({ first, second });
	OAK_ASSERT(dirty.changed);
	OAK_ASSERT_EQ(buf.diagnostics_at(4).size(), 2);

	dirty = buf.set_diagnostics({ second, first }); // same set, other order
	OAK_ASSERT(!dirty.changed);
	OAK_ASSERT(!dirty.redraw);

	// Same for entries separated only by ‘zero_length’
	ng::diagnostic_t grown = diag(2, 3, 1, "expected ‘;’");
	grown.zero_length = true;
	ng::diagnostic_t plain = diag(2, 3, 1, "expected ‘;’");

	buf.set_diagnostics({ grown, plain });
	dirty = buf.set_diagnostics({ plain, grown });
	OAK_ASSERT(!dirty.changed);
	OAK_ASSERT(!dirty.redraw);
}

void test_diagnostics_point_hit_testing ()
{
	// Mouse dwell asks whether a marker sits at an index, and the answer has to
	// stay O(log n) — points are the only diagnostics with no range to look up.
	ng::buffer_t buf;
	buf.insert(0, "abc\n\ndef\n");
	buf.set_diagnostics({ diag(4, 4, 1) }); // the empty line

	OAK_ASSERT(buf.has_diagnostic_point_at(4));
	OAK_ASSERT(!buf.has_diagnostic_point_at(3));
	OAK_ASSERT(!buf.has_diagnostic_point_at(5));

	// At the end of a document with no trailing newline
	ng::buffer_t eof;
	eof.insert(0, "abc");
	eof.set_diagnostics({ diag(3, 3, 2) });
	OAK_ASSERT(eof.has_diagnostic_point_at(3));
	OAK_ASSERT(!eof.has_diagnostic_point_at(2));

	// And in an empty document
	ng::buffer_t empty;
	empty.set_diagnostics({ diag(0, 0, 1) });
	OAK_ASSERT(empty.has_diagnostic_point_at(0));

	// A non-empty range is not a point, however short
	ng::buffer_t range;
	range.insert(0, "abc");
	range.set_diagnostics({ diag(1, 2, 1) });
	OAK_ASSERT(!range.has_diagnostic_point_at(1));
	OAK_ASSERT(!range.has_diagnostic_point_at(2));
}

void test_diagnostics_many_ranges_lookup ()
{
	// A synthetic worst case: the mouse-dwell query must not depend on the size
	// of the set, so exercise it against every kind of index in a large one.
	ng::buffer_t buf;
	buf.insert(0, std::string(40000, 'x'));

	std::vector<ng::diagnostic_t> diagnostics;
	for(size_t i = 0; i < 5000; ++i)
		diagnostics.push_back(diag(i*8, i*8 + 4, 1 + i % 3));
	buf.set_diagnostics(diagnostics);

	for(size_t i = 0; i < 5000; ++i)
	{
		size_t const severity = 1 + i % 3;
		OAK_ASSERT(buf.diagnostic_range_containing(severity, i*8 + 1) == pair(i*8, i*8 + 4));
		OAK_ASSERT(buf.diagnostic_range_containing(severity, i*8 + 5) == pair(0, 0));
	}

	assert_well_formed(buf);
	OAK_ASSERT_EQ(buf.diagnostics(1, 0, buf.size()).size(), 1667);
}

void test_diagnostics_line_extent_query ()
{
	// The line-level question the code-action probe asks, once the gutter marks
	// that used to answer it are gone.
	ng::buffer_t buf;
	buf.insert(0, "alpha\n\nbeta\ngamma\n"); // lines at 0, 6, 7, 12, 18

	// A range on line 0, a point on the empty line 1, nothing on line 2, and a
	// range on line 3 that stops where line 4 begins.
	buf.set_diagnostics({ diag(1, 3, 1), diag(6, 6, 2), diag(12, 18, 1) });

	OAK_ASSERT(buf.has_diagnostics_in(0, 5));    // line 0: the range
	OAK_ASSERT(buf.has_diagnostics_in(6, 6));    // line 1: empty, and the point is its whole extent
	OAK_ASSERT(!buf.has_diagnostics_in(7, 11));  // line 2: clean
	OAK_ASSERT(buf.has_diagnostics_in(12, 17));  // line 3: the range
	OAK_ASSERT(!buf.has_diagnostics_in(18, 18)); // line 4: the range above ends where it starts

	// A multi-line range lights up every line it crosses, the empty one included
	buf.set_diagnostics({ diag(1, 14, 1) });
	OAK_ASSERT(buf.has_diagnostics_in(0, 5));
	OAK_ASSERT(buf.has_diagnostics_in(6, 6));
	OAK_ASSERT(buf.has_diagnostics_in(7, 11));
	OAK_ASSERT(buf.has_diagnostics_in(12, 17));

	// Severity is not part of the question
	buf.set_diagnostics({ diag(8, 9, 3) });
	OAK_ASSERT(buf.has_diagnostics_in(7, 11));
	OAK_ASSERT(!buf.has_diagnostics_in(0, 5));

	buf.set_diagnostics({});
	OAK_ASSERT(!buf.has_diagnostics_in(0, buf.size()));

	// A reversed window is not the window between the two indexes: answering it
	// on the strength of a long range spanning both ends would be inventing one
	buf.set_diagnostics({ diag(1, 14, 1) });
	OAK_ASSERT(!buf.has_diagnostics_in(12, 5));
	OAK_ASSERT(!buf.has_diagnostics_in(buf.size(), 0));
}

void test_diagnostics_navigation ()
{
	ng::buffer_t buf;
	buf.insert(0, std::string(100, 'x'));
	buf.set_diagnostics({ diag(10, 14, 1), diag(30, 30, 2), diag(50, 60, 3) });

	// Strictly after / strictly before, so repeating the command moves on
	OAK_ASSERT_EQ(buf.next_diagnostic(0), 10);
	OAK_ASSERT_EQ(buf.next_diagnostic(10), 30);
	OAK_ASSERT_EQ(buf.next_diagnostic(30), 50);
	OAK_ASSERT_EQ(buf.previous_diagnostic(60), 50);
	OAK_ASSERT_EQ(buf.previous_diagnostic(50), 30);
	OAK_ASSERT_EQ(buf.previous_diagnostic(30), 10);

	// From inside a range, forwards leaves it and backwards goes to its start —
	// the caret is past that start, so it is the previous one
	OAK_ASSERT_EQ(buf.next_diagnostic(12), 30);
	OAK_ASSERT_EQ(buf.previous_diagnostic(55), 50);

	// Both wrap, the way the marks this replaced did
	OAK_ASSERT_EQ(buf.next_diagnostic(50), 10);
	OAK_ASSERT_EQ(buf.next_diagnostic(buf.size()), 10);
	OAK_ASSERT_EQ(buf.previous_diagnostic(10), 50);
	OAK_ASSERT_EQ(buf.previous_diagnostic(0), 50);

	// Two diagnostics sharing a start are one stop, not two
	buf.set_diagnostics({ diag(10, 14, 1), diag(10, 20, 2) });
	OAK_ASSERT_EQ(buf.next_diagnostic(0), 10);
	OAK_ASSERT_EQ(buf.next_diagnostic(10), 10); // wrapped past both, back to the same place
	OAK_ASSERT_EQ(buf.previous_diagnostic(10), 10);

	// A zero-length diagnostic grown leftwards reports its END: at end of line
	// there is no next character to underline, so the squiggle starts one before
	// the position the server pointed at, and the caret belongs at that position
	// rather than on the character borrowed to show it.
	{
		ng::diagnostic_t grown = diag(9, 10, 1);
		grown.zero_length = true;
		grown.grown_left  = true;
		buf.set_diagnostics({ diag(20, 24, 1), grown });
		OAK_ASSERT_EQ(buf.next_diagnostic(0), 10);
		OAK_ASSERT_EQ(buf.previous_diagnostic(20), 10);
		OAK_ASSERT_EQ(buf.next_diagnostic(10), 20);

		// …and it keeps reporting its end after an edit moves the pair
		buf.insert(0, "xx");
		OAK_ASSERT_EQ(buf.next_diagnostic(0), 12);
		buf.erase(0, 2);

		// A range grown leftwards can report a position AFTER one that starts
		// alongside it, which is why the stops are their own sorted index and not
		// the diagnostic list read in order
		ng::diagnostic_t alongside = diag(9, 30, 2);
		buf.set_diagnostics({ grown, alongside });
		OAK_ASSERT_EQ(buf.next_diagnostic(8), 9);
		OAK_ASSERT_EQ(buf.next_diagnostic(9), 10);
	}

	// Nothing to navigate to
	buf.set_diagnostics({});
	OAK_ASSERT_EQ(buf.next_diagnostic(0), SIZE_MAX);
	OAK_ASSERT_EQ(buf.previous_diagnostic(0), SIZE_MAX);
}
