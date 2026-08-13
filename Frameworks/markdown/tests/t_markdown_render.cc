#include <markdown/markdown_render.h>

void test_basic_paragraph ()
{
	std::string const html = markdown::to_html("Hello *world*\n");
	OAK_ASSERT(html.find("<p") != std::string::npos);
	OAK_ASSERT(html.find("<em>world</em>") != std::string::npos);
}

void test_sourcepos_attributes ()
{
	std::string const html = markdown::to_html("first\n\nsecond\n");
	OAK_ASSERT(html.find("data-sourcepos=\"1:1-1:5\"") != std::string::npos);
	OAK_ASSERT(html.find("data-sourcepos=\"3:1-3:6\"") != std::string::npos);
}

void test_without_sourcepos ()
{
	std::string const html = markdown::to_html("first\n\nsecond\n", false);
	OAK_ASSERT(html.find("data-sourcepos") == std::string::npos);
	OAK_ASSERT(html.find("<p>first</p>") != std::string::npos);
}

void test_gfm_table ()
{
	std::string const html = markdown::to_html("| a | b |\n|---|---|\n| 1 | 2 |\n");
	OAK_ASSERT(html.find("<table") != std::string::npos);
	OAK_ASSERT(html.find(">1</td>") != std::string::npos); // <td> carries a data-sourcepos attribute
}

void test_gfm_strikethrough ()
{
	std::string const html = markdown::to_html("~~gone~~\n");
	OAK_ASSERT(html.find("<del>gone</del>") != std::string::npos);
}

void test_gfm_autolink ()
{
	std::string const html = markdown::to_html("visit https://macromates.com now\n");
	OAK_ASSERT(html.find("<a href=\"https://macromates.com\"") != std::string::npos);
}

void test_gfm_tasklist ()
{
	std::string const html = markdown::to_html("- [x] done\n- [ ] todo\n");
	OAK_ASSERT(html.find("type=\"checkbox\"") != std::string::npos);
	OAK_ASSERT(html.find("checked") != std::string::npos);
}

void test_fenced_code_block ()
{
	std::string const html = markdown::to_html("```c\nint main ();\n```\n");
	OAK_ASSERT(html.find("<pre") != std::string::npos);
	OAK_ASSERT(html.find("language-c") != std::string::npos);
	OAK_ASSERT(html.find("int main ();") != std::string::npos);
}

void test_raw_html_and_tagfilter ()
{
	std::string const html = markdown::to_html("keep <b>bold</b> but filter <script>alert(1)</script>\n");
	OAK_ASSERT(html.find("<b>bold</b>") != std::string::npos);
	OAK_ASSERT(html.find("<script>") == std::string::npos);   // tagfilter escapes it
	OAK_ASSERT(html.find("&lt;script") != std::string::npos);
}

void test_relative_image ()
{
	std::string const html = markdown::to_html("![shot](images/shot.png)\n");
	OAK_ASSERT(html.find("<img src=\"images/shot.png\"") != std::string::npos);
}

void test_empty_input ()
{
	OAK_ASSERT_EQ(markdown::to_html(""), "");
}

void test_utf8_content ()
{
	std::string const html = markdown::to_html("# 日本語の見出し\n");
	OAK_ASSERT(html.find("日本語の見出し") != std::string::npos);
}

void test_math_inline ()
{
	std::string const html = markdown::to_html("Euler: $e^{i\\pi}+1=0$.\n");
	OAK_ASSERT(html.find("<span data-tm-math=\"inline\">e^{i\\pi}+1=0</span>") != std::string::npos);
	OAK_ASSERT(html.find("tmmath") == std::string::npos);
}

void test_math_emphasis_adjacent ()
{
	std::string const html = markdown::to_html("$x_i$ and $y_j$\n");
	OAK_ASSERT(html.find("<em>") == std::string::npos);
	OAK_ASSERT(html.find(">x_i</span>") != std::string::npos);
	OAK_ASSERT(html.find(">y_j</span>") != std::string::npos);
}

void test_math_display_block ()
{
	std::string const html = markdown::to_html("$$\n\\sum_{i=0}^n x_i\n$$\n");
	OAK_ASSERT_EQ(html, "<div data-tm-math=\"display\" data-sourcepos=\"1:1-3:1\">\\sum_{i=0}^n x_i</div>\n");
}

void test_math_blocks_after_display_keep_lines ()
{
	std::string const html = markdown::to_html("$$\nx\n$$\n\n# after\n\nlast\n");
	OAK_ASSERT(html.find("data-sourcepos=\"1:1-3:1\"") != std::string::npos);
	OAK_ASSERT(html.find("<h1 data-sourcepos=\"5:1-5:7\"") != std::string::npos);
	OAK_ASSERT(html.find("<p data-sourcepos=\"7:1-7:4\"") != std::string::npos);
}

void test_math_display_shared_paragraph ()
{
	std::string const html = markdown::to_html("before\n$$x$$\nafter\n");
	OAK_ASSERT_EQ(html,
		"<p data-sourcepos=\"1:1-1:6\">before</p>\n"
		"<div data-tm-math=\"display\" data-sourcepos=\"2:1-2:1\">x</div>\n"
		"<p data-sourcepos=\"3:1-3:5\">after</p>\n");
}

void test_math_display_shared_paragraph_multiline ()
{
	std::string const html = markdown::to_html("before\n$$\nx\n$$\nafter\n");
	OAK_ASSERT_EQ(html,
		"<p data-sourcepos=\"1:1-1:6\">before</p>\n"
		"<div data-tm-math=\"display\" data-sourcepos=\"2:1-4:1\">x</div>\n"
		"<p data-sourcepos=\"5:1-5:5\">after</p>\n");
}

void test_math_display_multiple_in_paragraph ()
{
	std::string const html = markdown::to_html("a\n$$x$$\nmid\n$$y$$\nb\n");
	OAK_ASSERT_EQ(html,
		"<p data-sourcepos=\"1:1-1:1\">a</p>\n"
		"<div data-tm-math=\"display\" data-sourcepos=\"2:1-2:1\">x</div>\n"
		"<p data-sourcepos=\"3:1-3:3\">mid</p>\n"
		"<div data-tm-math=\"display\" data-sourcepos=\"4:1-4:1\">y</div>\n"
		"<p data-sourcepos=\"5:1-5:1\">b</p>\n");
}

void test_math_display_shared_paragraph_indented ()
{
	std::string const html = markdown::to_html("  before\n  $$x$$\n  after\n");
	OAK_ASSERT_EQ(html,
		"<p data-sourcepos=\"1:3-1:8\">before</p>\n"
		"<div data-tm-math=\"display\" data-sourcepos=\"2:1-2:1\">x</div>\n"
		"<p data-sourcepos=\"3:3-3:7\">after</p>\n");
}

void test_math_display_across_emphasis_literal ()
{
	// splitting here would strand <em> and </em> in different paragraphs, so
	// the delimiters come back as literal text (design §2.1: the failure mode
	// is math not rendering, never corrupted output)
	std::string const html = markdown::to_html("*before\n$$x$$\nafter*\n", false);
	OAK_ASSERT_EQ(html, "<p><em>before\n$$x$$\nafter</em></p>\n");
}

void test_math_display_across_link_literal ()
{
	std::string const html = markdown::to_html("[before\n$$x$$\nafter](https://example.com)\n", false);
	OAK_ASSERT_EQ(html, "<p><a href=\"https://example.com\">before\n$$x$$\nafter</a></p>\n");
}

void test_math_display_across_raw_span_literal ()
{
	std::string const html = markdown::to_html("<span>before\n$$x$$\nafter</span>\n", false);
	OAK_ASSERT_EQ(html, "<p><span>before\n$$x$$\nafter</span></p>\n");
}

void test_math_display_multiline_across_emphasis_literal ()
{
	// the continuation tokens keep the paragraph whole, so the crossing <em>
	// is visible to the veto; the delimiters come back on their own lines,
	// matching what cmark emits for the equivalent unmasked structure
	std::string const html = markdown::to_html("*before\n$$\nx\n$$\nafter*\n", false);
	OAK_ASSERT_EQ(html, "<p><em>before\n$$\nx\n$$\nafter</em></p>\n");
}

void test_math_display_multiline_across_link_literal ()
{
	std::string const html = markdown::to_html("[before\n$$\nx\n$$\nafter](https://example.com)\n", false);
	OAK_ASSERT_EQ(html, "<p><a href=\"https://example.com\">before\n$$\nx\n$$\nafter</a></p>\n");
}

void test_math_display_multiline_across_raw_span_literal ()
{
	std::string const html = markdown::to_html("<span>before\n$$\nx\n$$\nafter</span>\n", false);
	OAK_ASSERT_EQ(html, "<p><span>before\n$$\nx\n$$\nafter</span></p>\n");
}

void test_math_display_multiline_blank_surrounded ()
{
	std::string const html = markdown::to_html("before\n\n$$\nx\n$$\n\nafter\n");
	OAK_ASSERT_EQ(html,
		"<p data-sourcepos=\"1:1-1:6\">before</p>\n"
		"<div data-tm-math=\"display\" data-sourcepos=\"3:1-5:1\">x</div>\n"
		"<p data-sourcepos=\"7:1-7:5\">after</p>\n");
}

void test_math_display_beside_balanced_inline_splits ()
{
	// inline elements confined to one half don’t inhibit the split
	std::string const html = markdown::to_html("*before*\n$$x$$\n*after*\n", false);
	OAK_ASSERT_EQ(html,
		"<p><em>before</em></p>\n"
		"<div data-tm-math=\"display\">x</div>\n"
		"<p><em>after</em></p>\n");
}

void test_math_display_in_unordered_list ()
{
	std::string const html = markdown::to_html("- before\n\n  $$x$$\n\n  after\n", false);
	OAK_ASSERT_EQ(html,
		"<ul>\n<li>\n"
		"<p>before</p>\n"
		"<div data-tm-math=\"display\">x</div>\n"
		"<p>after</p>\n"
		"</li>\n</ul>\n");
}

void test_math_display_in_ordered_list ()
{
	std::string const html = markdown::to_html("1. before\n\n   $$x$$\n\n   after\n", false);
	OAK_ASSERT_EQ(html,
		"<ol>\n<li>\n"
		"<p>before</p>\n"
		"<div data-tm-math=\"display\">x</div>\n"
		"<p>after</p>\n"
		"</li>\n</ol>\n");
}

void test_math_display_multiline_in_list ()
{
	std::string const html = markdown::to_html("- before\n\n  $$\n  x\n  $$\n\n  after\n", false);
	OAK_ASSERT_EQ(html,
		"<ul>\n<li>\n"
		"<p>before</p>\n"
		"<div data-tm-math=\"display\">  x</div>\n" // tex keeps the raw line, indent included
		"<p>after</p>\n"
		"</li>\n</ul>\n");
}

void test_math_display_nested_list_literal ()
{
	// 4-space item content is conservatively treated as indented code by the
	// scanner (design §2.1), so nested-list math stays literal in v1 — the
	// documented limitation; it must pass through cmark uncorrupted
	std::string const html = markdown::to_html("- outer\n  - before\n\n    $$x$$\n", false);
	OAK_ASSERT(html.find("data-tm-math") == std::string::npos);
	OAK_ASSERT(html.find("<p>$$x$$</p>") != std::string::npos);
}

void test_math_currency ()
{
	std::string const html = markdown::to_html("it costs $5 and $10\n");
	OAK_ASSERT(html.find("data-tm-math") == std::string::npos);
	OAK_ASSERT(html.find("$5 and $10") != std::string::npos);
}

void test_math_escaped_dollar ()
{
	std::string const html = markdown::to_html("a \\$b\\$ c\n");
	OAK_ASSERT(html.find("data-tm-math") == std::string::npos);
	OAK_ASSERT(html.find("$b$") != std::string::npos);
}

void test_math_code_span_immunity ()
{
	std::string const html = markdown::to_html("`$x$` and $y$\n");
	OAK_ASSERT(html.find("<code>$x$</code>") != std::string::npos);
	OAK_ASSERT(html.find("<span data-tm-math=\"inline\">y</span>") != std::string::npos);
}

void test_math_fenced_code_immunity ()
{
	std::string const html = markdown::to_html("```\n$$\nx\n$$\n```\n");
	OAK_ASSERT(html.find("data-tm-math") == std::string::npos);
	OAK_ASSERT(html.find("$$\nx\n$$") != std::string::npos);
}

void test_math_indented_code_immunity ()
{
	std::string const html = markdown::to_html("code:\n\n    $x$\n");
	OAK_ASSERT(html.find("data-tm-math") == std::string::npos);
	OAK_ASSERT(html.find("<code>$x$") != std::string::npos);
}

void test_math_mid_prose_display_literal ()
{
	std::string const html = markdown::to_html("a $$x$$ b\n");
	OAK_ASSERT(html.find("data-tm-math") == std::string::npos);
	OAK_ASSERT(html.find("$$x$$") != std::string::npos);
}

void test_math_without_sourcepos ()
{
	std::string const html = markdown::to_html("$$\nx\n$$\n\n$y$\n", false);
	OAK_ASSERT(html.find("data-sourcepos") == std::string::npos);
	OAK_ASSERT(html.find("<div data-tm-math=\"display\">x</div>") != std::string::npos);
	OAK_ASSERT(html.find("<span data-tm-math=\"inline\">y</span>") != std::string::npos);
}

void test_math_token_lookalike ()
{
	std::string const html = markdown::to_html("literal tmmath00f3a9c1 and $x$\n");
	OAK_ASSERT(html.find("tmmath00f3a9c1") != std::string::npos);
	OAK_ASSERT(html.find("<span data-tm-math=\"inline\">x</span>") != std::string::npos);
}

void test_math_free_output_unchanged ()
{
	OAK_ASSERT_EQ(markdown::to_html("plain *text*\n", false), "<p>plain <em>text</em></p>\n");
}
