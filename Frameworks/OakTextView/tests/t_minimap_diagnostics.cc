#include "../src/minimap_diagnostics.h"

using namespace minimap;

// line 0 "one" [0,3), 1 "two" [4,7), 2 "three" [8,13), 3 "four" [14,18),
// 4 "five" [19,23), 5 "" at 24 — an empty last line, where a point diagnostic
// has no character to sit on.
static std::string const kFiveLines = "one\ntwo\nthree\nfour\nfive\n";

static ng::diagnostic_t diag (size_t from, size_t to, size_t severity)
{
	ng::diagnostic_t res;
	res.from     = from;
	res.to       = to;
	res.severity = severity;
	return res;
}

// "1:2 3:1" — the marked rows with the severity each got, so a fixture reads
// like the strip it describes.
static std::string render (std::map<size_t, size_t> const& rows)
{
	std::string res;
	for(auto const& row : rows)
		res += (res.empty() ? "" : " ") + std::to_string(row.first) + ":" + std::to_string(row.second);
	return res;
}

static std::string rows_for (ng::buffer_t const& buffer, size_t firstLine, size_t lastLine)
{
	return render(diagnostic_rows(buffer, firstLine, lastLine));
}

void test_minimap_diagnostic_rows_basic ()
{
	ng::buffer_t buf;
	buf.insert(0, kFiveLines);

	OAK_ASSERT_EQ(rows_for(buf, 0, buf.lines()-1), ""); // nothing published yet

	buf.set_diagnostics({ diag(4, 7, 1) }); // “two”
	OAK_ASSERT_EQ(rows_for(buf, 0, buf.lines()-1), "1:1");
}

// The lane answers “is there something wrong here”, so every line a range
// crosses lights up — but a range ending where the next line begins does not
// reach into it.
void test_minimap_diagnostic_rows_multiline ()
{
	ng::buffer_t buf;
	buf.insert(0, kFiveLines);

	buf.set_diagnostics({ diag(4, 13, 2) }); // “two\nthree”, ending at line 2’s newline
	OAK_ASSERT_EQ(rows_for(buf, 0, buf.lines()-1), "1:2 2:2");

	buf.set_diagnostics({ diag(4, 8, 2) }); // …one further: the newline itself, then line 3’s first index
	OAK_ASSERT_EQ(rows_for(buf, 0, buf.lines()-1), "1:2");

	buf.set_diagnostics({ diag(4, 9, 2) });
	OAK_ASSERT_EQ(rows_for(buf, 0, buf.lines()-1), "1:2 2:2");
}

// One row is one pixel strip, so a warning must never hide the error sharing
// its line — regardless of which severity was published first.
void test_minimap_diagnostic_rows_worst_severity_wins ()
{
	ng::buffer_t buf;
	buf.insert(0, kFiveLines);

	buf.set_diagnostics({ diag(0, 13, 3), diag(4, 7, 1) });
	OAK_ASSERT_EQ(rows_for(buf, 0, buf.lines()-1), "0:3 1:1 2:3");

	buf.set_diagnostics({ diag(4, 7, 1), diag(4, 7, 2), diag(4, 7, 3) });
	OAK_ASSERT_EQ(rows_for(buf, 0, buf.lines()-1), "1:1");

	// 4 (hint) and a nonsensical value read as note, the same normalization
	// every other surface gets.
	buf.set_diagnostics({ diag(4, 7, 4), diag(14, 18, 99) });
	OAK_ASSERT_EQ(rows_for(buf, 0, buf.lines()-1), "1:3 3:3");
}

// The lane is drawn one dirty rect at a time: rows outside the window are not
// reported, and the diagnostic that started before it still is.
void test_minimap_diagnostic_rows_window ()
{
	ng::buffer_t buf;
	buf.insert(0, kFiveLines);

	buf.set_diagnostics({ diag(0, 18, 1) }); // lines 0 through 3
	OAK_ASSERT_EQ(rows_for(buf, 0, buf.lines()-1), "0:1 1:1 2:1 3:1");
	OAK_ASSERT_EQ(rows_for(buf, 2, 3), "2:1 3:1");
	OAK_ASSERT_EQ(rows_for(buf, 4, 5), "");

	// A window past the end of the document reports what it has, not a crash
	OAK_ASSERT_EQ(rows_for(buf, 3, 99), "3:1");
	OAK_ASSERT_EQ(rows_for(buf, 99, 99), "");
}

void test_minimap_diagnostic_rows_points ()
{
	ng::buffer_t buf;
	buf.insert(0, kFiveLines);

	// A point on the empty last line, where there is no character to underline
	buf.set_diagnostics({ diag(24, 24, 1) });
	OAK_ASSERT_EQ(rows_for(buf, 0, buf.lines()-1), "5:1");
	OAK_ASSERT_EQ(rows_for(buf, 0, 4), "");

	// Points are queried inclusively, so the one sitting exactly where the next
	// line begins must not bleed into a window that ends before it
	buf.set_diagnostics({ diag(4, 4, 2) });
	OAK_ASSERT_EQ(rows_for(buf, 1, 1), "1:2");
	OAK_ASSERT_EQ(rows_for(buf, 0, 0), "");

	// …and it loses to an error on the same line
	buf.set_diagnostics({ diag(4, 4, 2), diag(4, 7, 1) });
	OAK_ASSERT_EQ(rows_for(buf, 0, buf.lines()-1), "1:1");
}

// Between an edit and the server’s next publish the buffer shifts the ranges,
// and the lane has to follow them rather than the coordinates the server sent.
void test_minimap_diagnostic_rows_after_edit ()
{
	ng::buffer_t buf;
	buf.insert(0, kFiveLines);

	buf.set_diagnostics({ diag(14, 18, 1) }); // “four”
	OAK_ASSERT_EQ(rows_for(buf, 0, buf.lines()-1), "3:1");

	buf.insert(0, "zero\n");
	OAK_ASSERT_EQ(rows_for(buf, 0, buf.lines()-1), "4:1");

	buf.erase(0, 5);
	OAK_ASSERT_EQ(rows_for(buf, 0, buf.lines()-1), "3:1");

	// Typed over: what the server annotated is gone, and so is the strip
	buf.replace(14, 18, "FOUR");
	OAK_ASSERT_EQ(rows_for(buf, 0, buf.lines()-1), "");
}

void test_minimap_diagnostic_dirty_rows ()
{
	ng::buffer_t buf;
	buf.insert(0, kFiveLines);

	auto span = dirty_rows(buf, 4, 7); // inside line 1
	OAK_ASSERT_EQ(span.first, 1);
	OAK_ASSERT_EQ(span.last, 1);

	span = dirty_rows(buf, 4, 13); // through line 2’s newline
	OAK_ASSERT_EQ(span.first, 1);
	OAK_ASSERT_EQ(span.last, 2);

	span = dirty_rows(buf, 4, 14); // ending exactly where line 3 begins: half-open, so line 3 is left alone
	OAK_ASSERT_EQ(span.first, 1);
	OAK_ASSERT_EQ(span.last, 2);

	// Degenerate, and nothing the buffer produces looks like this any more — a
	// point reports one byte past itself. Honoured as the row containing it.
	span = dirty_rows(buf, 8, 8);
	OAK_ASSERT_EQ(span.first, 2);
	OAK_ASSERT_EQ(span.last, 2);

	span = dirty_rows(buf, 14, 18);
	OAK_ASSERT_EQ(span.first, 3);
	OAK_ASSERT_EQ(span.last, 3);

	// The pair that tells the two apart at the end of the buffer: a range
	// stopping at EOF ends on line 4’s newline and leaves the empty last line
	// alone, while a point ON the last line is reported one byte further
	span = dirty_rows(buf, 19, buf.size());
	OAK_ASSERT_EQ(span.last, 4);

	span = dirty_rows(buf, 19, buf.size() + 1);
	OAK_ASSERT_EQ(span.last, 5);

	span = dirty_rows(buf, 0, 99); // clamped to the document, not clipped away
	OAK_ASSERT_EQ(span.first, 0);
	OAK_ASSERT_EQ(span.last, 5);

	span = dirty_rows(buf, 99, 4); // a nonsensical pair still names a real row
	OAK_ASSERT_EQ(span.first, 5);
	OAK_ASSERT_EQ(span.last, 5);
}

void test_minimap_diagnostic_rows_empty_document ()
{
	ng::buffer_t buf;

	OAK_ASSERT_EQ(rows_for(buf, 0, 0), "");

	buf.set_diagnostics({ diag(0, 0, 1) }); // the whole file is wrong, and it is empty
	OAK_ASSERT_EQ(rows_for(buf, 0, 0), "0:1");

	auto const span = dirty_rows(buf, 0, 0);
	OAK_ASSERT_EQ(span.first, 0);
	OAK_ASSERT_EQ(span.last, 0);
}
