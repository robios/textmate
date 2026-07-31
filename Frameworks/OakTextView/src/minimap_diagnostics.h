#ifndef MINIMAP_DIAGNOSTICS_H_QP4X2ZNR
#define MINIMAP_DIAGNOSTICS_H_QP4X2ZNR

#include <buffer/buffer.h>

#include <map>

// Turning the buffer's diagnostics into what the minimap's right-edge lane
// paints. Kept free of AppKit — and free of the view's caches — so the rules
// that decide which row lights up, and in which colour, are unit-testable.
namespace minimap
{
	// The severity to paint for each line of [firstLine, lastLine] a diagnostic
	// touches, 1 = error, 2 = warning, 3 = note. Only lines inside the window
	// appear: the lane is drawn one dirty rect at a time, so the query covers
	// just the byte range of the rows being drawn rather than the document.
	//
	// Every line a multi-line range crosses is marked — the lane answers "is
	// there something wrong here", not "where does it start" — and the worst
	// severity wins, since one row is one pixel strip and a warning must never
	// hide an error. Ranges are end-exclusive, so one ending exactly where a
	// line begins leaves that line alone.
	std::map<size_t, size_t> diagnostic_rows (ng::buffer_t const& buffer, size_t firstLine, size_t lastLine);

	struct row_span_t { size_t first, last; }; // inclusive

	// The rows to repaint for a diagnostics change reported over [from, to).
	// Diagnostics move no text, so nothing else invalidates the lane and this
	// is the only thing that brings a changed row back.
	//
	// Half-open, the same reading the layout gives it: a change ending where a
	// row begins leaves that row alone. A point diagnostic is reported one byte
	// past its own index precisely so that rule keeps its row — including the
	// point on a trailing empty line, whose extent therefore ends one past the
	// end of the buffer. `from == to` degenerates to the row containing it.
	row_span_t dirty_rows (ng::buffer_t const& buffer, size_t from, size_t to);

} /* minimap */

#endif /* end of include guard: MINIMAP_DIAGNOSTICS_H_QP4X2ZNR */
