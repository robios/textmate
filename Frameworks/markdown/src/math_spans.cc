#include "math_spans.h"

#include <cctype>
#include <cstdio>
#include <cstdlib>
#include <utility>

namespace
{
	struct line_t
	{
		size_t begin, end; // [begin, end), newline excluded
	};

	bool is_space (char ch)
	{
		return ch == ' ' || ch == '\t' || ch == '\r';
	}

	bool is_digit (char ch)
	{
		return '0' <= ch && ch <= '9';
	}

	std::vector<line_t> split_lines (std::string const& src)
	{
		std::vector<line_t> res;
		size_t pos = 0;
		while(pos < src.size())
		{
			size_t eol = src.find('\n', pos);
			if(eol == std::string::npos)
			{
				res.push_back({ pos, src.size() });
				break;
			}
			res.push_back({ pos, eol });
			pos = eol + 1;
		}
		return res;
	}

	std::string trimmed (std::string const& src, line_t const& line)
	{
		size_t b = line.begin, e = line.end;
		while(b < e && is_space(src[b]))
			++b;
		while(e > b && is_space(src[e-1]))
			--e;
		return src.substr(b, e - b);
	}

	size_t indent_width (std::string const& src, line_t const& line)
	{
		size_t res = 0;
		for(size_t i = line.begin; i < line.end && (src[i] == ' ' || src[i] == '\t'); ++i)
			res += src[i] == '\t' ? 4 : 1;
		return res;
	}

	// 1-based byte column of the line’s last non-whitespace character, 0 when
	// the line is blank or absent; cmark ends a paragraph’s data-sourcepos on
	// the same column
	size_t last_content_column (std::string const& src, std::vector<line_t> const& lines, size_t n)
	{
		if(n >= lines.size())
			return 0;
		size_t e = lines[n].end;
		while(e > lines[n].begin && is_space(src[e-1]))
			--e;
		return e - lines[n].begin;
	}

	// 1-based byte column of the line’s first non-whitespace character, 0 when
	// the line is blank or absent
	size_t first_content_column (std::string const& src, std::vector<line_t> const& lines, size_t n)
	{
		if(n >= lines.size())
			return 0;
		size_t b = lines[n].begin;
		while(b < lines[n].end && is_space(src[b]))
			++b;
		return b == lines[n].end ? 0 : b - lines[n].begin + 1;
	}

	// The line’s leading whitespace; a masked display token keeps it so a
	// 1–3 column indent still marks the token as list-item content.
	std::string leading_indent (std::string const& src, line_t const& line)
	{
		size_t i = line.begin;
		while(i < line.end && (src[i] == ' ' || src[i] == '\t'))
			++i;
		return src.substr(line.begin, i - line.begin);
	}

	// Code fence opener on a whitespace-trimmed line; cmark disallows
	// backticks in a backtick fence’s info string.
	size_t fence_run (std::string const& str, char* fenceChar)
	{
		if(str.empty() || (str[0] != '`' && str[0] != '~'))
			return 0;
		size_t n = 1;
		while(n < str.size() && str[n] == str[0])
			++n;
		if(n < 3 || (str[0] == '`' && str.find('`', n) != std::string::npos))
			return 0;
		*fenceChar = str[0];
		return n;
	}

	bool fence_close (std::string const& str, char fenceChar, size_t fenceLen)
	{
		size_t n = 0;
		while(n < str.size() && str[n] == fenceChar)
			++n;
		return n >= fenceLen && n == str.size();
	}

	// A whitespace-trimmed line that can close a display block: it ends with
	// an unescaped ‘$$’.
	bool ends_display (std::string const& str)
	{
		if(str.size() < 2 || str.compare(str.size() - 2, 2, "$$") != 0)
			return false;
		return str.size() == 2 || str[str.size() - 3] != '\\';
	}

	std::string token_prefix (std::string const& source)
	{
		char buf[16];
		do {
			snprintf(buf, sizeof(buf), "tmmath%08x", arc4random());
		} while(source.find(buf) != std::string::npos);
		return buf;
	}

	std::string escape_html (std::string const& text)
	{
		std::string res;
		res.reserve(text.size());
		for(char ch : text)
		{
			switch(ch)
			{
				case '&':  res += "&amp;";  break;
				case '<':  res += "&lt;";   break;
				case '>':  res += "&gt;";   break;
				case '"':  res += "&quot;"; break;
				default:   res += ch;       break;
			}
		}
		return res;
	}

	bool inside_tag (std::string const& html, size_t pos)
	{
		size_t open  = html.rfind('<', pos);
		size_t close = html.rfind('>', pos);
		return open != std::string::npos && (close == std::string::npos || close < open);
	}

	bool inside_code (std::string const& html, size_t pos)
	{
		size_t open  = html.rfind("<code", pos);
		size_t close = html.rfind("</code", pos);
		return open != std::string::npos && (close == std::string::npos || close < open);
	}

	// HTML void elements — their open tags never take a close tag
	bool is_void_element (std::string const& name)
	{
		static char const* const kVoidElements[] = { "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr" };
		for(char const* candidate : kVoidElements)
		{
			if(name == candidate)
				return true;
		}
		return false;
	}

	struct tag_scan_t
	{
		std::vector<std::string> open; // tags opened but never closed, innermost last
		bool strayClose = false;       // closed a tag it never opened
	};

	tag_scan_t scan_tags (std::string const& html)
	{
		tag_scan_t res;
		size_t i = 0;
		while((i = html.find('<', i)) != std::string::npos)
		{
			if(html.compare(i, 4, "<!--") == 0)
			{
				size_t end = html.find("-->", i + 4);
				if(end == std::string::npos)
					break;
				i = end + 3;
				continue;
			}

			if(html.compare(i, 2, "<!") == 0)
			{
				size_t end = html.find('>', i + 2);
				if(end == std::string::npos)
					break;
				i = end + 1;
				continue;
			}

			size_t j = i + 1;
			bool const isClose = j < html.size() && html[j] == '/';
			if(isClose)
				++j;

			std::string name;
			while(j < html.size() && (isalnum((unsigned char)html[j]) || html[j] == '-'))
				name += tolower(html[j++]);

			if(name.empty() || !isalpha((unsigned char)name.front()))
			{
				++i; // a ‘<’ that opens no tag; cmark escapes literal ones
				continue;
			}

			size_t const end = html.find('>', j);
			if(end == std::string::npos)
				break;

			if(isClose)
			{
				if(res.open.empty())
					res.strayClose = true;
				else if(res.open.back() == name)
					res.open.pop_back();
				// a close that skips levels is the author’s raw HTML; leave it be
			}
			else if(!is_void_element(name) && html[end-1] != '/')
			{
				res.open.push_back(name);
			}

			i = end + 1;
		}
		return res;
	}

	// Cutting a paragraph between head and tail must not separate an inline
	// element’s open and close tags: the head may not leave elements open,
	// and the tail may not close one it never opened. An unclosed open in
	// the tail is the author’s own raw HTML — unbalanced before any split —
	// and does not veto.
	bool split_breaks_tags (std::string const& head, std::string const& tail)
	{
		return !scan_tags(head).open.empty() || scan_tags(tail).strayClose;
	}
}

namespace markdown
{
	math_extraction_t extract_math (std::string const& source)
	{
		if(source.find('$') == std::string::npos)
			return { source, { } };

		std::vector<line_t> const lines = split_lines(source);
		std::string const prefix = token_prefix(source);

		std::string masked;
		masked.reserve(source.size());
		std::vector<math_span_t> spans;

		auto make_token = [&prefix, &spans]{
			char buf[16];
			snprintf(buf, sizeof(buf), "%04zx", spans.size());
			return prefix + buf;
		};

		bool inFence     = false;
		char fenceChar   = 0;
		size_t fenceLen  = 0;
		size_t codeTicks = 0; // width of an unclosed backtick span, carried across lines

		for(size_t n = 0; n < lines.size(); ++n)
		{
			line_t const& line = lines[n];
			std::string const trim = trimmed(source, line);

			auto emit = [&masked, &source, &line](std::string const& content){
				masked += content;
				if(line.end < source.size())
					masked += '\n';
			};

			auto emitRaw = [&emit, &source, &line]{
				emit(source.substr(line.begin, line.end - line.begin));
			};

			if(inFence)
			{
				inFence = !fence_close(trim, fenceChar, fenceLen);
				emitRaw();
				continue;
			}

			if(trim.empty())
			{
				codeTicks = 0; // a blank line ends the paragraph and any code span with it
				emitRaw();
				continue;
			}

			if(size_t len = fence_run(trim, &fenceChar))
			{
				inFence   = true;
				fenceLen  = len;
				codeTicks = 0;
				emitRaw();
				continue;
			}

			if(indent_width(source, line) >= 4) // indented code, conservatively even mid-paragraph
			{
				emitRaw();
				continue;
			}

			// display math in block position: ‘$$…$$’ alone on its line
			if(codeTicks == 0 && trim.size() >= 5 && trim.compare(0, 2, "$$") == 0 && ends_display(trim))
			{
				std::string const tex = trim.substr(2, trim.size() - 4);
				if(tex.find_first_not_of(" \t") != std::string::npos)
				{
					spans.push_back({ math_span_t::kDisplay, tex, make_token(), { trim }, n + 1, n + 1, n > 0 ? last_content_column(source, lines, n - 1) : 0, first_content_column(source, lines, n + 1) });
					emit(leading_indent(source, line) + spans.back().token);
					continue;
				}
			}

			// standalone ‘$$’ opening a display block closed by a later
			// ‘…$$’ line; a blank line before the closer keeps it literal
			if(codeTicks == 0 && trim == "$$")
			{
				size_t close = 0;
				for(size_t m = n + 1; m < lines.size() && !close; ++m)
				{
					std::string const t = trimmed(source, lines[m]);
					if(t.empty())
						break;
					if(ends_display(t))
						close = m;
				}

				if(close)
				{
					std::string tex;
					for(size_t m = n + 1; m < close; ++m)
						tex += source.substr(lines[m].begin, lines[m].end - lines[m].begin) + "\n";

					std::string last = trimmed(source, lines[close]);
					last.resize(last.size() - 2);
					while(!last.empty() && is_space(last.back()))
						last.pop_back();
					tex += last;

					while(!tex.empty() && tex.back() == '\n')
						tex.pop_back();

					if(!tex.empty())
					{
						std::vector<std::string> raw;
						for(size_t m = n; m <= close; ++m)
							raw.push_back(trimmed(source, lines[m]));

						spans.push_back({ math_span_t::kDisplay, tex, make_token(), std::move(raw), n + 1, close + 1, n > 0 ? last_content_column(source, lines, n - 1) : 0, first_content_column(source, lines, close + 1) });

						std::string const indent = leading_indent(source, line);
						emit(indent + spans.back().token);
						for(size_t m = n + 1; m <= close; ++m) // one continuation token per consumed line keeps the count without splitting the paragraph
						{
							masked += indent + spans.back().token + "c" + std::to_string(m - n);
							if(lines[m].end < source.size())
								masked += '\n';
						}
						n = close;
						continue;
					}
				}
			}

			// inline scan: backtick spans suppress ‘$’, backslash escapes both
			std::string out;
			size_t i = line.begin;
			while(i < line.end)
			{
				char const ch = source[i];
				if(ch == '`')
				{
					size_t run = 1;
					while(i + run < line.end && source[i + run] == '`')
						++run;
					if(codeTicks == 0)
						codeTicks = run;   // opens a span, possibly closed on a later line
					else if(codeTicks == run)
						codeTicks = 0;     // only an equal-length run closes one
					out.append(source, i, run);
					i += run;
				}
				else if(codeTicks != 0)
				{
					out += ch;
					++i;
				}
				else if(ch == '\\' && i + 1 < line.end)
				{
					out.append(source, i, 2);
					i += 2;
				}
				else if(ch == '$')
				{
					if(i + 1 < line.end && source[i + 1] == '$')
					{
						out += "$$"; // embedded ‘$$’ stays literal in v1
						i += 2;
					}
					else if(i + 1 == line.end || is_space(source[i + 1]) || is_digit(source[i + 1]))
					{
						out += ch;
						++i;
					}
					else
					{
						// the first unescaped ‘$’ ends the span, and only when
						// not preceded by whitespace
						size_t close = 0;
						for(size_t j = i + 1; j < line.end; ++j)
						{
							if(source[j] == '\\')
								++j;
							else if(source[j] == '$')
							{
								if(!is_space(source[j - 1]))
									close = j;
								break;
							}
						}

						if(close)
						{
							spans.push_back({ math_span_t::kInline, source.substr(i + 1, close - i - 1), make_token(), { }, n + 1, n + 1, 0, 0 });
							out += spans.back().token;
							i = close + 1;
						}
						else
						{
							out += ch;
							++i;
						}
					}
				}
				else
				{
					out += ch;
					++i;
				}
			}
			emit(out);
		}

		if(spans.empty())
			return { source, { } };
		return { masked, spans };
	}

	std::string restore_math (std::string html, std::vector<math_span_t> const& spans, bool sourcePositions)
	{
		for(math_span_t const& span : spans)
		{
			// a multi-line display span owns a token run: the main token on the
			// opener’s line, one continuation token per further consumed line
			size_t const contCount = span.kind == math_span_t::kDisplay ? span.lastLine - span.firstLine : 0;

			size_t pos = 0;
			while((pos = html.find(span.token, pos)) != std::string::npos)
			{
				// the main token is a prefix of its continuation tokens — skip
				// those matches here; the sweep below catches any stranded ones
				if(contCount && pos + span.token.size() < html.size() && html[pos + span.token.size()] == 'c')
				{
					size_t d = pos + span.token.size() + 1, index = 0;
					while(d < html.size() && is_digit(html[d]))
						index = index * 10 + (html[d++] - '0');
					if(1 <= index && index <= contCount)
					{
						pos = d;
						continue;
					}
				}

				size_t from = pos, to = pos + span.token.size();

				// locate the run: each continuation token follows in order,
				// across a softbreak and whatever indent cmark kept
				std::vector<std::pair<size_t, size_t>> run{ { from, to } };
				bool fullRun = true;
				for(size_t m = 1; m <= contCount && fullRun; ++m)
				{
					std::string const cont = span.token + "c" + std::to_string(m);
					size_t w = to;
					while(w < html.size() && (is_space(html[w]) || html[w] == '\n'))
						++w;
					if(w > to && html.compare(w, cont.size(), cont) == 0)
					{
						run.push_back({ w, w + cont.size() });
						to = w + cont.size();
					}
					else
					{
						fullRun = false;
					}
				}

				// replacing each token with its own source line’s escaped text
				// rebuilds the original delimiter layout across the softbreaks
				auto literalRun = [&html, &span, &run, from]{
					std::string res;
					size_t at = from;
					for(size_t i = 0; i < run.size(); ++i)
					{
						res += html.substr(at, run[i].first - at);
						res += escape_html(span.lines[i]);
						at = run[i].second;
					}
					return res;
				};

				std::string replacement;

				if(inside_tag(html, pos) || inside_code(html, pos) || !fullRun)
				{
					// the token landed in an attribute, the scanner disagreed
					// with cmark about a code region, or the run came apart —
					// fall back to the literal source text so nothing is
					// corrupted
					replacement = span.kind == math_span_t::kInline ? escape_html("$" + span.tex + "$") : literalRun();
				}
				else if(span.kind == math_span_t::kInline)
				{
					replacement = "<span data-tm-math=\"inline\">" + escape_html(span.tex) + "</span>";
				}
				else
				{
					replacement = "<div data-tm-math=\"display\"";
					if(sourcePositions)
					{
						char buf[64];
						snprintf(buf, sizeof(buf), " data-sourcepos=\"%zu:1-%zu:1\"", span.firstLine, span.lastLine);
						replacement += buf;
					}
					replacement += ">" + escape_html(span.tex) + "</div>";

					// replace the paragraph cmark wrapped the token in; a token
					// sharing its paragraph with other content splits it into
					// valid sibling blocks around the <div>
					size_t tagStart = html.rfind("<p", pos);
					if(tagStart != std::string::npos && (html[tagStart + 2] == '>' || html[tagStart + 2] == ' '))
					{
						size_t openEnd    = html.find('>', tagStart);
						size_t closeTag   = html.find("</p>", to);
						size_t priorClose = html.rfind("</p>", pos);
						if(openEnd != std::string::npos && openEnd < pos && closeTag != std::string::npos && (priorClose == std::string::npos || priorClose < tagStart))
						{
							if(openEnd + 1 == pos && closeTag == to)
							{
								from = tagStart;
								to   = closeTag + 4;
							}
							else if(split_breaks_tags(html.substr(openEnd + 1, pos - openEnd - 1), html.substr(to, closeTag - to)))
							{
								// the cut would separate an inline element’s open and
								// close tags — keep cmark’s paragraph and fall back to
								// the literal source text, as above
								replacement = literalRun();
							}
							else
							{
								std::string head = html.substr(openEnd + 1, pos - openEnd - 1);
								std::string tail = html.substr(to, closeTag - to);
								if(!head.empty() && head.back() == '\n') // the softbreaks next to the token
									head.pop_back();
								if(!tail.empty() && tail.front() == '\n')
									tail.erase(0, 1);

								// each half keeps its share of the paragraph’s source
								// range, cut at the span’s lines and the recorded
								// columns of its neighbouring content; an end is never
								// allowed before its start
								std::string headTag = "<p>", tailTag = "<p>";
								size_t sl = 0, sc = 0, el = 0, ec = 0;
								std::string const openTag = html.substr(tagStart, openEnd - tagStart + 1);
								size_t attr = openTag.find("data-sourcepos=\"");
								if(attr != std::string::npos && sscanf(openTag.c_str() + attr + sizeof("data-sourcepos=\"") - 1, "%zu:%zu-%zu:%zu", &sl, &sc, &el, &ec) == 4)
								{
									size_t headLine = span.firstLine - 1, headCol = span.prevEndColumn ?: 1;
									if(headLine < sl || (headLine == sl && headCol < sc))
									{
										headLine = sl;
										headCol  = sc;
									}

									size_t tailLine = span.lastLine + 1, tailCol = span.nextStartColumn ?: 1;
									if(el < tailLine || (el == tailLine && ec < tailCol))
									{
										el = tailLine;
										ec = tailCol;
									}

									char buf[64];
									snprintf(buf, sizeof(buf), "<p data-sourcepos=\"%zu:%zu-%zu:%zu\">", sl, sc, headLine, headCol);
									headTag = buf;
									snprintf(buf, sizeof(buf), "<p data-sourcepos=\"%zu:%zu-%zu:%zu\">", tailLine, tailCol, el, ec);
									tailTag = buf;
								}

								std::string blocks;
								if(!head.empty())
									blocks += headTag + head + "</p>\n";
								blocks += replacement;
								if(!tail.empty())
									blocks += "\n" + tailTag + tail + "</p>";

								replacement = std::move(blocks);
								from = tagStart;
								to   = closeTag + 4;
							}
						}
					}
				}

				html.replace(from, to - from, replacement);
				pos = from + replacement.size();
			}
		}

		// tokens must never reach the output: a continuation token stranded
		// outside its run — attribute, code region, a cmark surprise — comes
		// back as its own source line’s escaped text. Higher indices first,
		// since “…c1” is a prefix of “…c1” plus further digits.
		for(math_span_t const& span : spans)
		{
			size_t const contCount = span.kind == math_span_t::kDisplay ? span.lastLine - span.firstLine : 0;
			for(size_t m = contCount; m >= 1; --m)
			{
				std::string const cont = span.token + "c" + std::to_string(m);
				std::string const line = escape_html(span.lines[m]);
				size_t pos = 0;
				while((pos = html.find(cont, pos)) != std::string::npos)
				{
					html.replace(pos, cont.size(), line);
					pos += line.size();
				}
			}
		}

		return html;
	}

} /* markdown */
