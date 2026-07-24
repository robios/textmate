#ifndef DIFF_MARK_PALETTE_H_QW31MZ7K
#define DIFF_MARK_PALETTE_H_QW31MZ7K

#include <CoreGraphics/CoreGraphics.h>

// The colours every buffer-vs-HEAD line indicator draws with — the
// gutter's change bars and the minimap's strips — kept in one place so
// the same change reads as the same colour wherever it is shown.
//
// VS Code's palette, in two variants: the light-background values are
// too dark to see on a dark editor theme and vice versa, so the caller
// passes the brightness of the background it is drawing on.
namespace diff_mark_palette
{
	struct rgb_t { CGFloat red, green, blue; };

	inline rgb_t added (bool darkBackground)    { return darkBackground ? rgb_t{ 0.45, 0.80, 0.15 } : rgb_t{ 0.28, 0.49, 0.01 }; } // #73CC26 / #487E02
	inline rgb_t modified (bool darkBackground) { return darkBackground ? rgb_t{ 0.20, 0.67, 0.86 } : rgb_t{ 0.11, 0.51, 0.66 }; } // #33ABDB / #1B81A8
	inline rgb_t deleted (bool darkBackground)  { return darkBackground ? rgb_t{ 1.00, 0.36, 0.36 } : rgb_t{ 0.95, 0.30, 0.30 }; } // #FF5C5C / #F14C4C

} /* diff_mark_palette */

#endif /* end of include guard: DIFF_MARK_PALETTE_H_QW31MZ7K */
