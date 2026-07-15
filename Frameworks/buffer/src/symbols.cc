#include "meta_data.h"
#include <regexp/format_string.h>
#include <bundles/bundles.h>
#include <oak/oak.h>
#include <text/ctype.h>
#include <oak/duration.h>

namespace
{
	struct transform_t
	{
		transform_t (std::string const& src) : src(src)
		{
			char const* it = src.data();
			char const* last = it + src.size();
			while(it != last)
			{
				if(text::is_space(*it) || *it == '\n')
				{
					++it;
				}
				else if(parse_char(it, last, '#'))
				{
					while(!parse_char(it, last, '\n') && it != last)
						++it;
				}
				else if(parse_char(it, last, ';'))
				{
					// stray rule separator, e.g. ‘s/…/…/ ; s/…/…/’
				}
				else if(parse_char(it, last, 's') && parse_char(it, last, '/'))
				{
					std::string regexp;
					while(it != last && *it != '/')
					{
						if(*it == '\\' && it + 1 != last)
							regexp += *it++;
						regexp += *it++;
					}

					if(!parse_char(it, last, '/'))
					{
						os_log_error(OS_LOG_DEFAULT, "Malformed symbol transformation at offset %td (expected ‘/’): %{public}s", it - src.data(), src.c_str());
						return;
					}

					format_string::format_string_t format(std::string(it, last), "/");
					if(format.length() == 0)
					{
						os_log_error(OS_LOG_DEFAULT, "Malformed symbol transformation at offset %td (expected /format string/): %{public}s", it - src.data(), src.c_str());
						return;
					}

					it += format.length();

					std::string options;
					while(it != last && 'a' <= *it && *it <= 'z')
						options += *it++;

					parse_char(it, last, ';'); // semi-colon is optional, so we do not treat it as an error

					records.push_back((record_t){ regexp::pattern_t(regexp, options), format, options.find('g') != std::string::npos });
				}
				else
				{
					os_log_error(OS_LOG_DEFAULT, "Malformed symbol transformation at offset %td (expected ‘s’, ‘#’, or space, found %c (0x%02x)): %{public}s", it - src.data(), *it, *it, src.c_str());
					return;
				}
			}
		}

		std::string expand (std::string const& str) const
		{
			static regexp::pattern_t newline("\n");
			std::string res = replace(str, newline, format_string::format_string_t(" "));
			for(auto const& it : records)
				res = replace(res, it.regexp, it.format, it.repeat);
			res = replace(res, newline, format_string::format_string_t("↵"));

			return res;
		}
	private:
		static bool parse_char (char const*& it, char const* last, char ch)
		{
			return it != last && *it == ch ? (++it, true) : false;
		}

		struct record_t
		{
			regexp::pattern_t regexp;
			format_string::format_string_t format;
			bool repeat;
		};

		std::string src;
		std::vector<record_t> records;
	};
}

namespace ng
{
	void symbols_t::replace (buffer_t* buffer, size_t from, size_t to, size_t len) { _symbols.replace(from, to, len); }

	void symbols_t::did_parse (buffer_t const* buffer, size_t from, size_t to)
	{
		std::map<scope::scope_t, std::shared_ptr<transform_t>> transforms;
		auto transform_for = [&transforms](scope::scope_t const& scope) -> transform_t* {
			auto it = transforms.find(scope);
			if(it == transforms.end())
			{
				std::shared_ptr<transform_t> transform;
				if(plist::is_true(bundles::value_for_setting("showInSymbolList", scope)))
				{
					plist::any_t const& symbolTransformationValue = bundles::value_for_setting("symbolTransformation", scope);
					std::string const* symbolTransformation = plist::get<std::string>(&symbolTransformationValue);
					transform = std::make_shared<transform_t>(symbolTransformation ? *symbolTransformation : "");
				}
				it = transforms.emplace(scope, transform).first;
			}
			return it->second.get();
		};

		// A symbol’s scope run can span multiple parse batches, so extend the range
		// backward and forward through adjacent symbol-marked runs and recompute such
		// symbols whole, rather than leave a fragment behind at each batch boundary.
		auto first = buffer->_scopes.lower_bound(from);
		while(first != buffer->_scopes.begin())
		{
			auto it = first;
			--it;
			if(!transform_for(it->second))
				break;
			first = it;
		}

		auto last = buffer->_scopes.lower_bound(to);
		while(last != buffer->_scopes.end() && transform_for(last->second))
			++last;

		size_t extendedFrom = from;
		if(first != buffer->_scopes.end())
			extendedFrom = std::min(extendedFrom, (size_t)first->first);
		size_t extendedTo = last != buffer->_scopes.end() ? std::max(to, (size_t)last->first) : buffer->size();

		_symbols.remove(_symbols.lower_bound(extendedFrom), _symbols.lower_bound(extendedTo));

		size_t beginOfSymbol = 0;
		bool inSymbol = false;
		transform_t* transform = nullptr;
		for(auto it = first; it != last; ++it)
		{
			if(transform_t* transformForScope = transform_for(it->second))
			{
				if(!inSymbol)
				{
					beginOfSymbol = it->first;
					transform = transformForScope;
					inSymbol  = true;
				}
			}
			else if(inSymbol)
			{
				_symbols.set(beginOfSymbol, transform->expand(buffer->substr(beginOfSymbol, it->first)));
				inSymbol = false;
			}
		}

		if(inSymbol)
			_symbols.set(beginOfSymbol, transform->expand(buffer->substr(beginOfSymbol, extendedTo)));
	}

	std::map<size_t, std::string> symbols_t::symbols (buffer_t const* buffer) const
	{
		std::map<size_t, std::string> res;
		for(auto const& it : _symbols)
			res.insert(it);
		return res;
	}

	std::string symbols_t::symbol_at (buffer_t const* buffer, size_t i) const
	{
		tree_t::iterator it = _symbols.upper_bound(i);
		if(it == _symbols.begin())
			return NULL_STR;
		return (--it)->second;
	}

} /* ng */
