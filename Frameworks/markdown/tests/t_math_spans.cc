#include <markdown/math_spans.h>

void test_extract_inline ()
{
	auto res = markdown::extract_math("before $x_i$ after\n");
	OAK_ASSERT_EQ(res.spans.size(), 1);
	OAK_ASSERT(res.spans[0].kind == markdown::math_span_t::kInline);
	OAK_ASSERT_EQ(res.spans[0].tex, "x_i");
	OAK_ASSERT_EQ(res.spans[0].firstLine, 1);
	OAK_ASSERT_EQ(res.spans[0].lastLine, 1);
	OAK_ASSERT_EQ(res.source, "before " + res.spans[0].token + " after\n");
}

void test_extract_display_single_line ()
{
	auto res = markdown::extract_math("$$E = mc^2$$\n");
	OAK_ASSERT_EQ(res.spans.size(), 1);
	OAK_ASSERT(res.spans[0].kind == markdown::math_span_t::kDisplay);
	OAK_ASSERT_EQ(res.spans[0].tex, "E = mc^2");
	OAK_ASSERT_EQ(res.spans[0].firstLine, 1);
	OAK_ASSERT_EQ(res.spans[0].lastLine, 1);
	OAK_ASSERT_EQ(res.source, res.spans[0].token + "\n");
}

void test_extract_display_multiline ()
{
	auto res = markdown::extract_math("$$\n\\sum_{i=0}^n x_i\n$$\ntext\n");
	OAK_ASSERT_EQ(res.spans.size(), 1);
	OAK_ASSERT(res.spans[0].kind == markdown::math_span_t::kDisplay);
	OAK_ASSERT_EQ(res.spans[0].tex, "\\sum_{i=0}^n x_i");
	OAK_ASSERT_EQ(res.spans[0].firstLine, 1);
	OAK_ASSERT_EQ(res.spans[0].lastLine, 3);
	std::string const tok = res.spans[0].token;
	OAK_ASSERT_EQ(res.source, tok + "\n" + tok + "c1\n" + tok + "c2\ntext\n"); // one token line per source line, no blank padding
}

void test_extract_display_multiline_records_lines ()
{
	auto res = markdown::extract_math("$$\na\nb\n$$\n");
	OAK_ASSERT_EQ(res.spans.size(), 1);
	OAK_ASSERT_EQ(res.spans[0].lines.size(), 4);
	OAK_ASSERT_EQ(res.spans[0].lines[0], "$$");
	OAK_ASSERT_EQ(res.spans[0].lines[1], "a");
	OAK_ASSERT_EQ(res.spans[0].lines[2], "b");
	OAK_ASSERT_EQ(res.spans[0].lines[3], "$$");
}

void test_extract_display_trailing_tex_on_closer ()
{
	auto res = markdown::extract_math("$$\n\\sum x_i $$\n");
	OAK_ASSERT_EQ(res.spans.size(), 1);
	OAK_ASSERT_EQ(res.spans[0].tex, "\\sum x_i");
	OAK_ASSERT_EQ(res.spans[0].lastLine, 2);
}

void test_extract_display_indented ()
{
	auto res = markdown::extract_math("- a\n\n  $$x$$\n");
	OAK_ASSERT_EQ(res.spans.size(), 1);
	OAK_ASSERT_EQ(res.spans[0].tex, "x");
	OAK_ASSERT_EQ(res.source, "- a\n\n  " + res.spans[0].token + "\n"); // the opener’s indent survives masking
}

void test_extract_display_multiline_indented ()
{
	auto res = markdown::extract_math("- a\n\n  $$\n  x\n  $$\n\n  b\n");
	OAK_ASSERT_EQ(res.spans.size(), 1);
	OAK_ASSERT_EQ(res.spans[0].firstLine, 3);
	OAK_ASSERT_EQ(res.spans[0].lastLine, 5);
	std::string const tok = res.spans[0].token;
	OAK_ASSERT_EQ(res.source, "- a\n\n  " + tok + "\n  " + tok + "c1\n  " + tok + "c2\n\n  b\n"); // the opener’s indent on every token line, line count preserved
}

void test_escaped_dollar ()
{
	auto res = markdown::extract_math("\\$x\\$ is literal\n");
	OAK_ASSERT_EQ(res.spans.size(), 0);
	OAK_ASSERT_EQ(res.source, "\\$x\\$ is literal\n");
}

void test_currency ()
{
	auto res = markdown::extract_math("it costs $5 and $10 total\n");
	OAK_ASSERT_EQ(res.spans.size(), 0);
	OAK_ASSERT_EQ(res.source, "it costs $5 and $10 total\n");
}

void test_backtick_immunity ()
{
	auto res = markdown::extract_math("`$x$` then $y$\n");
	OAK_ASSERT_EQ(res.spans.size(), 1);
	OAK_ASSERT_EQ(res.spans[0].tex, "y");
}

void test_multi_backtick_immunity ()
{
	auto res = markdown::extract_math("``code $x$ `` and $y$\n");
	OAK_ASSERT_EQ(res.spans.size(), 1);
	OAK_ASSERT_EQ(res.spans[0].tex, "y");
}

void test_fence_immunity ()
{
	auto res = markdown::extract_math("```math\n$x$\n```\n\n$y$\n");
	OAK_ASSERT_EQ(res.spans.size(), 1);
	OAK_ASSERT_EQ(res.spans[0].tex, "y");
	OAK_ASSERT_EQ(res.spans[0].firstLine, 5);
}

void test_tilde_fence_immunity ()
{
	auto res = markdown::extract_math("~~~\n$$\nx\n$$\n~~~\n");
	OAK_ASSERT_EQ(res.spans.size(), 0);
}

void test_indented_code_immunity ()
{
	auto res = markdown::extract_math("para\n\n    $x$ code\n\n$y$\n");
	OAK_ASSERT_EQ(res.spans.size(), 1);
	OAK_ASSERT_EQ(res.spans[0].tex, "y");
}

void test_mid_prose_display_literal ()
{
	auto res = markdown::extract_math("a $$x$$ b\n");
	OAK_ASSERT_EQ(res.spans.size(), 0);
	OAK_ASSERT_EQ(res.source, "a $$x$$ b\n");
}

void test_unclosed_display_literal ()
{
	auto res = markdown::extract_math("$$\nnever closed\n\nnext para\n");
	OAK_ASSERT_EQ(res.spans.size(), 0);
	OAK_ASSERT_EQ(res.source, "$$\nnever closed\n\nnext para\n");
}

void test_empty_spans_dont_count ()
{
	OAK_ASSERT_EQ(markdown::extract_math("a $ $ b\n").spans.size(), 0);
	OAK_ASSERT_EQ(markdown::extract_math("$$$$\n").spans.size(), 0);
	OAK_ASSERT_EQ(markdown::extract_math("$$\n$$\n").spans.size(), 0);
}

void test_token_collision_free ()
{
	std::string const source = "tmmath00f3a9c1 looks like a token, $x$\n";
	auto res = markdown::extract_math(source);
	OAK_ASSERT_EQ(res.spans.size(), 1);
	OAK_ASSERT(source.find(res.spans[0].token) == std::string::npos);
	OAK_ASSERT(res.source.find("tmmath00f3a9c1") != std::string::npos);
}

void test_restore_inline ()
{
	auto res = markdown::extract_math("a $x<y$ b\n");
	OAK_ASSERT_EQ(res.spans.size(), 1);
	std::string const html = markdown::restore_math("<p>a " + res.spans[0].token + " b</p>\n", res.spans, true);
	OAK_ASSERT_EQ(html, "<p>a <span data-tm-math=\"inline\">x&lt;y</span> b</p>\n");
}

void test_restore_display ()
{
	auto res = markdown::extract_math("$$\nx > 0\n$$\n");
	OAK_ASSERT_EQ(res.spans.size(), 1);
	std::string const tok = res.spans[0].token;
	std::string const html = markdown::restore_math("<p data-sourcepos=\"1:1-3:20\">" + tok + "\n" + tok + "c1\n" + tok + "c2</p>\n", res.spans, true);
	OAK_ASSERT_EQ(html, "<div data-tm-math=\"display\" data-sourcepos=\"1:1-3:1\">x &gt; 0</div>\n");
}

void test_restore_display_no_sourcepos ()
{
	auto res = markdown::extract_math("$$\nx\n$$\n");
	OAK_ASSERT_EQ(res.spans.size(), 1);
	std::string const tok = res.spans[0].token;
	std::string const html = markdown::restore_math("<p>" + tok + "\n" + tok + "c1\n" + tok + "c2</p>\n", res.spans, false);
	OAK_ASSERT_EQ(html, "<div data-tm-math=\"display\">x</div>\n");
}

void test_restore_display_split ()
{
	auto res = markdown::extract_math("before\n$$x$$\nafter\n");
	OAK_ASSERT_EQ(res.spans.size(), 1);
	std::string const html = markdown::restore_math("<p data-sourcepos=\"1:1-3:5\">before\n" + res.spans[0].token + "\nafter</p>\n", res.spans, true);
	OAK_ASSERT_EQ(html,
		"<p data-sourcepos=\"1:1-1:6\">before</p>\n"
		"<div data-tm-math=\"display\" data-sourcepos=\"2:1-2:1\">x</div>\n"
		"<p data-sourcepos=\"3:1-3:5\">after</p>\n");
}

void test_restore_display_split_at_start ()
{
	auto res = markdown::extract_math("$$x$$\nafter\n");
	OAK_ASSERT_EQ(res.spans.size(), 1);
	std::string const html = markdown::restore_math("<p data-sourcepos=\"1:1-2:5\">" + res.spans[0].token + "\nafter</p>\n", res.spans, true);
	OAK_ASSERT_EQ(html,
		"<div data-tm-math=\"display\" data-sourcepos=\"1:1-1:1\">x</div>\n"
		"<p data-sourcepos=\"2:1-2:5\">after</p>\n"); // no empty leading half
}

void test_restore_display_split_at_end ()
{
	auto res = markdown::extract_math("before\n$$x$$\n");
	OAK_ASSERT_EQ(res.spans.size(), 1);
	std::string const html = markdown::restore_math("<p data-sourcepos=\"1:1-2:6\">before\n" + res.spans[0].token + "</p>\n", res.spans, true);
	OAK_ASSERT_EQ(html,
		"<p data-sourcepos=\"1:1-1:6\">before</p>\n"
		"<div data-tm-math=\"display\" data-sourcepos=\"2:1-2:1\">x</div>\n"); // no empty trailing half
}

void test_restore_display_split_no_sourcepos ()
{
	auto res = markdown::extract_math("before\n$$x$$\nafter\n");
	OAK_ASSERT_EQ(res.spans.size(), 1);
	std::string const html = markdown::restore_math("<p>before\n" + res.spans[0].token + "\nafter</p>\n", res.spans, false);
	OAK_ASSERT_EQ(html,
		"<p>before</p>\n"
		"<div data-tm-math=\"display\">x</div>\n"
		"<p>after</p>\n");
}

void test_extract_records_boundary_columns ()
{
	auto res = markdown::extract_math("  before\n  $$x$$\n  after\n");
	OAK_ASSERT_EQ(res.spans.size(), 1);
	OAK_ASSERT_EQ(res.spans[0].prevEndColumn, 8);
	OAK_ASSERT_EQ(res.spans[0].nextStartColumn, 3);

	res = markdown::extract_math("before  \n$$x$$\nafter\n"); // trailing whitespace excluded, as in cmark’s ranges
	OAK_ASSERT_EQ(res.spans[0].prevEndColumn, 6);
	OAK_ASSERT_EQ(res.spans[0].nextStartColumn, 1);
}

void test_extract_boundary_columns_blank_neighbors ()
{
	auto res = markdown::extract_math("$$x$$\n"); // no neighboring lines at all
	OAK_ASSERT_EQ(res.spans[0].prevEndColumn, 0);
	OAK_ASSERT_EQ(res.spans[0].nextStartColumn, 0);

	res = markdown::extract_math("a\n\n$$x$$\n\nb\n"); // blank neighboring lines
	OAK_ASSERT_EQ(res.spans[0].prevEndColumn, 0);
	OAK_ASSERT_EQ(res.spans[0].nextStartColumn, 0);
}

void test_extract_boundary_columns_multiline ()
{
	auto res = markdown::extract_math("before\n$$\nx\n$$\nafter\n");
	OAK_ASSERT_EQ(res.spans[0].prevEndColumn, 6);
	OAK_ASSERT_EQ(res.spans[0].nextStartColumn, 1);
}

void test_restore_split_clamps_inverted_range ()
{
	// a paragraph claiming to start past the recorded boundary column must
	// not yield a head range that ends before it starts
	auto res = markdown::extract_math("before\n$$x$$\nafter\n");
	OAK_ASSERT_EQ(res.spans.size(), 1);
	std::string const html = markdown::restore_math("<p data-sourcepos=\"1:9-3:5\">before\n" + res.spans[0].token + "\nafter</p>\n", res.spans, true);
	OAK_ASSERT_EQ(html,
		"<p data-sourcepos=\"1:9-1:9\">before</p>\n"
		"<div data-tm-math=\"display\" data-sourcepos=\"2:1-2:1\">x</div>\n"
		"<p data-sourcepos=\"3:1-3:5\">after</p>\n");
}

void test_restore_split_unclosed_open_vetoes ()
{
	auto res = markdown::extract_math("*before\n$$x$$\nafter*\n");
	OAK_ASSERT_EQ(res.spans.size(), 1);
	std::string const html = markdown::restore_math("<p><em>before\n" + res.spans[0].token + "\nafter</em></p>\n", res.spans, false);
	OAK_ASSERT_EQ(html, "<p><em>before\n$$x$$\nafter</em></p>\n");
}

void test_restore_split_stray_close_vetoes ()
{
	auto res = markdown::extract_math("before\n$$x$$\nafter\n");
	OAK_ASSERT_EQ(res.spans.size(), 1);
	std::string const html = markdown::restore_math("<p>before\n" + res.spans[0].token + "\nafter</em></p>\n", res.spans, false);
	OAK_ASSERT_EQ(html, "<p>before\n$$x$$\nafter</em></p>\n");
}

void test_restore_split_stray_open_in_tail_splits ()
{
	// an unclosed open after the token is the author’s raw HTML, unbalanced
	// before any split — it must not veto
	auto res = markdown::extract_math("before\n$$x$$\nafter\n");
	OAK_ASSERT_EQ(res.spans.size(), 1);
	std::string const html = markdown::restore_math("<p>before\n" + res.spans[0].token + "\n<em>after</p>\n", res.spans, false);
	OAK_ASSERT_EQ(html,
		"<p>before</p>\n"
		"<div data-tm-math=\"display\">x</div>\n"
		"<p><em>after</p>\n");
}

void test_restore_split_void_elements_split ()
{
	auto res = markdown::extract_math("before\n$$x$$\nafter\n");
	OAK_ASSERT_EQ(res.spans.size(), 1);
	std::string const html = markdown::restore_math("<p>before <img src=\"a.png\" /><br>\n" + res.spans[0].token + "\nafter</p>\n", res.spans, false);
	OAK_ASSERT_EQ(html,
		"<p>before <img src=\"a.png\" /><br></p>\n"
		"<div data-tm-math=\"display\">x</div>\n"
		"<p>after</p>\n");
}

void test_restore_multiline_run_split ()
{
	// the token run — main token plus continuations across softbreaks — is
	// replaced as a unit, so an uncrossed multi-line span splits cleanly
	auto res = markdown::extract_math("before\n$$\nx\n$$\nafter\n");
	OAK_ASSERT_EQ(res.spans.size(), 1);
	std::string const tok = res.spans[0].token;
	std::string const html = markdown::restore_math("<p data-sourcepos=\"1:1-5:5\">before\n" + tok + "\n" + tok + "c1\n" + tok + "c2\nafter</p>\n", res.spans, true);
	OAK_ASSERT_EQ(html,
		"<p data-sourcepos=\"1:1-1:6\">before</p>\n"
		"<div data-tm-math=\"display\" data-sourcepos=\"2:1-4:1\">x</div>\n"
		"<p data-sourcepos=\"5:1-5:5\">after</p>\n");
}

void test_restore_multiline_veto_keeps_layout ()
{
	// a vetoed split brings each token back as its own source line, keeping
	// the original delimiter layout across the softbreaks — never $$x$$
	auto res = markdown::extract_math("*before\n$$\nx\n$$\nafter*\n");
	OAK_ASSERT_EQ(res.spans.size(), 1);
	std::string const tok = res.spans[0].token;
	std::string const html = markdown::restore_math("<p><em>before\n" + tok + "\n" + tok + "c1\n" + tok + "c2\nafter</em></p>\n", res.spans, false);
	OAK_ASSERT_EQ(html, "<p><em>before\n$$\nx\n$$\nafter</em></p>\n");
}

void test_restore_leftover_continuation_tokens ()
{
	// a run cmark tore apart: no token may leak into the output — each comes
	// back as its own source line’s escaped text
	auto res = markdown::extract_math("$$\nx\n$$\n");
	OAK_ASSERT_EQ(res.spans.size(), 1);
	std::string const tok = res.spans[0].token;
	std::string const html = markdown::restore_math("<p>" + tok + "</p>\n<p>" + tok + "c1</p>\n<p>" + tok + "c2</p>\n", res.spans, false);
	OAK_ASSERT_EQ(html, "<p>$$</p>\n<p>x</p>\n<p>$$</p>\n");
}

void test_restore_token_inside_code ()
{
	auto res = markdown::extract_math("$x$\n");
	OAK_ASSERT_EQ(res.spans.size(), 1);
	std::string const html = markdown::restore_math("<pre><code>" + res.spans[0].token + "</code></pre>\n", res.spans, true);
	OAK_ASSERT(html.find("data-tm-math") == std::string::npos);
	OAK_ASSERT(html.find("$x$") != std::string::npos);
}

void test_restore_token_inside_attribute ()
{
	auto res = markdown::extract_math("![$x$](shot.png)\n");
	OAK_ASSERT_EQ(res.spans.size(), 1);
	std::string const html = markdown::restore_math("<p><img src=\"shot.png\" alt=\"" + res.spans[0].token + "\" /></p>\n", res.spans, true);
	OAK_ASSERT(html.find("data-tm-math") == std::string::npos);
	OAK_ASSERT(html.find("alt=\"$x$\"") != std::string::npos);
}
