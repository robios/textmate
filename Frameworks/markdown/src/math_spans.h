#ifndef MATH_SPANS_H_A6F20D5B
#define MATH_SPANS_H_A6F20D5B

#include <string>
#include <vector>

namespace markdown
{
	struct math_span_t
	{
		enum kind_t { kInline, kDisplay };

		kind_t kind;
		std::string tex;   // raw TeX between the delimiters
		std::string token; // placeholder word in the masked source

		// Whitespace-trimmed text of each consumed source line, opener through
		// closer; literal fallbacks rebuild the original delimiter layout from
		// these. Empty for inline spans.
		std::vector<std::string> lines;

		size_t firstLine;  // 1-based source lines spanned, delimiters included
		size_t lastLine;

		// 1-based byte columns of a display span’s neighbouring content: the
		// last non-whitespace character on line firstLine-1 and the first on
		// line lastLine+1; 0 when that line is blank or absent (and for inline
		// spans, which never split a paragraph). restore_math cuts a shared
		// paragraph’s source range at these columns.
		size_t prevEndColumn;
		size_t nextStartColumn;
	};

	struct math_extraction_t
	{
		std::string source; // input with each math span masked by its token
		std::vector<math_span_t> spans;
	};

	// Replace TeX math spans ($…$ inline, block-position $$…$$ display) with
	// opaque tokens that cmark passes through unsplit. Tokens are guaranteed
	// absent from the input. A multi-line display span puts its token on the
	// opener’s line and a continuation token (token + “c1”, “c2”, …) on every
	// further consumed line, so the line count is preserved without breaking
	// the enclosing paragraph. Continuation tokens share the main token’s
	// nonce prefix, so the collision guarantee covers them too.
	math_extraction_t extract_math (std::string const& source);

	// Replace each token in cmark’s HTML with its data-tm-math element. A
	// display span’s token run — the main token plus its continuation tokens
	// across softbreaks — is handled as a unit: a <p> holding exactly the run
	// is replaced whole; a paragraph shared with other content is split into
	// sibling blocks around the <div> — unless the cut would separate an
	// inline element’s open and close tags, in which case each token comes
	// back as its own source line’s escaped text, preserving the delimiter
	// layout, and the paragraph stays as cmark built it. Tokens never reach
	// the output: any continuation token stranded outside its run is likewise
	// replaced by its line’s text. data-sourcepos is rebuilt from the span’s
	// recorded lines and columns unless sourcePositions is false.
	std::string restore_math (std::string html, std::vector<math_span_t> const& spans, bool sourcePositions = true);

} /* markdown */

#endif /* MATH_SPANS_H_A6F20D5B */
