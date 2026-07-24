#include "diff_pane_model.h"

#include <algorithm>

namespace diff_pane
{
	size_t line_count (std::string const& text)
	{
		if(text.empty())
			return 0;

		size_t count = 1;
		for(char ch : text)
		{
			if(ch == '\n')
				++count;
		}
		if(text.back() == '\n')
			--count;
		return count;
	}

	line_span_t caret_span (scm::gutter_diff::hunk_t const& hunk, size_t totalLines)
	{
		if(hunk.new_lines > 0)
			return { hunk.new_line, hunk.new_line + hunk.new_lines - 1 };

		size_t anchor = hunk.new_line + 1; // line after the deletion point
		anchor = std::min(anchor, std::max<size_t>(totalLines, 1));
		return { anchor, anchor };
	}

	namespace
	{
		// Byte offset where each 1-indexed line starts. The final entry
		// is the size of the text and never names a line.
		std::vector<size_t> line_starts (std::string const& text)
		{
			std::vector<size_t> starts;
			starts.push_back(0);
			for(size_t i = 0; i < text.size(); ++i)
			{
				if(text[i] == '\n')
					starts.push_back(i + 1);
			}
			return starts;
		}

		// Text of the 1-indexed `line`, newline stripped; empty for a
		// line number past the end.
		std::string line_text (std::string const& text, std::vector<size_t> const& starts, size_t line)
		{
			if(line == 0 || line > starts.size())
				return "";

			size_t const from = starts[line - 1];
			if(from >= text.size())
				return "";

			size_t to = text.find('\n', from);
			if(to == std::string::npos)
				to = text.size();
			return text.substr(from, to - from);
		}
	}

	std::vector<card_t> build_cards (scm::gutter_diff::hunks_t const& hunks, std::string const& baseText, std::string const& bufferText)
	{
		auto const baseStarts = line_starts(baseText);
		auto const bufferStarts = line_starts(bufferText);

		size_t const baseTotal = line_count(baseText);
		size_t const bufferTotal = line_count(bufferText);

		std::vector<card_t> cards;
		cards.reserve(hunks.size());

		for(size_t i = 0; i < hunks.size(); ++i)
		{
			auto const& hunk = hunks[i];

			card_t card;
			card.hunk_index    = i;
			card.pure_deletion = hunk.new_lines == 0;
			card.change_span   = card.pure_deletion
				? line_span_t{ 0, 0 }
				: line_span_t{ hunk.new_line, hunk.new_line + hunk.new_lines - 1 };
			card.anchor_line   = caret_span(hunk, bufferTotal).first;

			// Last unchanged line before the change on each side. For a
			// pure insertion/deletion the hunk's start line already names
			// it; it is 0 for a change at the very top of the file.
			size_t const preBase   = hunk.base_lines ? hunk.base_line - 1 : hunk.base_line;
			size_t const preBuffer = hunk.new_lines ? hunk.new_line - 1 : hunk.new_line;
			size_t const leading   = std::min({ kContextLines, preBase, preBuffer });

			for(size_t n = leading; n >= 1; --n)
			{
				size_t const bufferLine = preBuffer - n + 1;
				card.rows.push_back({ row_kind::context, preBase - n + 1, bufferLine, bufferLine, line_text(bufferText, bufferStarts, bufferLine) });
			}

			// git prints a change block's deletions before its additions.
			// A deleted line's jump target is the line that replaced it —
			// pairing them the way the gutter marks do, first deletion with
			// first addition — and the deletion point when nothing did.
			for(size_t n = 0; n < hunk.base_lines; ++n)
			{
				size_t const baseLine = hunk.base_line + n;
				size_t const jumpLine = hunk.new_lines ? hunk.new_line + std::min(n, hunk.new_lines - 1) : card.anchor_line;
				card.rows.push_back({ row_kind::deleted, baseLine, 0, jumpLine, line_text(baseText, baseStarts, baseLine) });
			}

			for(size_t n = 0; n < hunk.new_lines; ++n)
			{
				size_t const bufferLine = hunk.new_line + n;
				card.rows.push_back({ row_kind::added, 0, bufferLine, bufferLine, line_text(bufferText, bufferStarts, bufferLine) });
			}

			// First unchanged line after the change on each side.
			size_t const postBase   = hunk.base_lines ? hunk.base_line + hunk.base_lines : hunk.base_line + 1;
			size_t const postBuffer = hunk.new_lines ? hunk.new_line + hunk.new_lines : hunk.new_line + 1;
			size_t const trailing   = std::min({
				kContextLines,
				postBase   <= baseTotal   ? baseTotal   - postBase   + 1 : 0,
				postBuffer <= bufferTotal ? bufferTotal - postBuffer + 1 : 0,
			});

			for(size_t n = 0; n < trailing; ++n)
			{
				size_t const bufferLine = postBuffer + n;
				card.rows.push_back({ row_kind::context, postBase + n, bufferLine, bufferLine, line_text(bufferText, bufferStarts, bufferLine) });
			}

			// The header names the buffer-side lines on display. Context
			// supplies them even for a pure deletion — only a card with no
			// buffer-side line anywhere (the file emptied out) has to fall
			// back to base-side numbers and admit it.
			size_t firstBuffer = 0, lastBuffer = 0;
			for(auto const& row : card.rows)
			{
				if(row.buffer_line == 0)
					continue;
				if(firstBuffer == 0)
					firstBuffer = row.buffer_line;
				lastBuffer = row.buffer_line;
			}

			if(firstBuffer != 0)
			{
				card.header_span = { firstBuffer, lastBuffer };
			}
			else
			{
				card.header_span         = { hunk.base_line, hunk.base_line + hunk.base_lines - 1 };
				card.header_is_base_side = true;
			}

			cards.push_back(std::move(card));
		}
		return cards;
	}

	bool can_reuse_base_scopes (std::string const& cachedKey, size_t cachedMaxLine, std::string const& key, size_t maxLine, bool haveGrammar)
	{
		return haveGrammar && cachedKey == key && cachedMaxLine >= maxLine;
	}

	size_t card_for_caret (std::vector<card_t> const& cards, size_t caretLine)
	{
		for(size_t i = 0; i < cards.size(); ++i)
		{
			auto const& card = cards[i];
			if(card.pure_deletion)
			{
				if(caretLine == card.anchor_line)
					return i;
			}
			else if(card.change_span.first <= caretLine && caretLine <= card.change_span.last)
			{
				return i;
			}
		}
		return npos;
	}

	empty_state classify_empty_state (bool inRepository, bool tooLarge, bool tracked, bool hasHunks, bool documentEdited, bool hasStagedChanges, bool baseIsHead)
	{
		if(!inRepository)
			return empty_state::no_repository;
		if(tooLarge)
			return empty_state::too_large;
		if(hasHunks)
			return empty_state::has_hunks;
		if(!tracked)
			return empty_state::untracked_empty;
		if(!baseIsHead)
			return empty_state::clean_vs_base;
		if(documentEdited && hasStagedChanges)
			return empty_state::unsaved_and_staged;
		if(documentEdited)
			return empty_state::unsaved_only;
		if(hasStagedChanges)
			return empty_state::staged_only;
		return empty_state::clean;
	}

	std::string to_s (empty_state state)
	{
		switch(state)
		{
			case empty_state::has_hunks:          return "has_hunks";
			case empty_state::no_repository:      return "no_repository";
			case empty_state::too_large:          return "too_large";
			case empty_state::untracked_empty:    return "untracked_empty";
			case empty_state::clean:              return "clean";
			case empty_state::unsaved_only:       return "unsaved_only";
			case empty_state::staged_only:        return "staged_only";
			case empty_state::unsaved_and_staged: return "unsaved_and_staged";
			case empty_state::clean_vs_base:      return "clean_vs_base";
		}
		return "unknown";
	}

	// =========================
	// = Revert (buffer edits) =
	// =========================

	std::string apply_replacements (std::string const& text, replacements_t const& replacements)
	{
		// Back to front: every edit then lands on offsets the ones still
		// to come have not disturbed.
		std::string res = text;
		for(auto it = replacements.rbegin(); it != replacements.rend(); ++it)
		{
			size_t const from = it->first.first, to = it->first.second;
			if(from <= to && to <= res.size())
				res.replace(from, to - from, it->second);
		}
		return res;
	}

	replacements_t replacements_for_revert (scm::gutter_diff::hunks_t const& hunks, size_t index, std::string const& baseText, std::string const& snapshotBuffer, std::string const& liveBuffer)
	{
		replacements_t res;

		// The hunks' byte ranges mean nothing against a buffer that has
		// moved on since they were computed — which the debounce window
		// makes an ordinary occurrence, not a rare race.
		if(snapshotBuffer != liveBuffer)
			return res;

		if(index != kAllHunks)
		{
			if(index < hunks.size())
				res.emplace(std::make_pair(hunks[index].buffer_from, hunks[index].buffer_to), hunks[index].base_text);
			return res;
		}

		if(hunks.empty())
			return res;

		for(auto const& hunk : hunks)
			res.emplace(std::make_pair(hunk.buffer_from, hunk.buffer_to), hunk.base_text);

		// Reverting everything is a restore: it has to land on the base
		// exactly. Replacing the buffer wholesale would always do that,
		// but per-hunk edits leave the untouched parts of the buffer —
		// and the marks, folds and carets in them — alone, so they are
		// worth preferring while they demonstrably arrive at the base.
		if(apply_replacements(snapshotBuffer, res) != baseText)
		{
			res.clear();
			res.emplace(std::make_pair((size_t)0, snapshotBuffer.size()), baseText);
		}
		return res;
	}

	std::string to_s (row_kind kind)
	{
		switch(kind)
		{
			case row_kind::context: return "context";
			case row_kind::deleted: return "deleted";
			case row_kind::added:   return "added";
		}
		return "unknown";
	}

} /* diff_pane */
