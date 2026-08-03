#include "filter.h"
#include "path_info.h"
#include <command/parser.h>
#include <command/runner.h>
#include <text/utf8.h>
#include <regexp/regexp.h>
#include <settings/settings.h>
#include <io/path.h>
#include <oak/debug.h>

// Import/export filters are run by command::runner, which forks the script and
// reads back its output — there is no terminal to route to and no way to hand
// the converted content back from one. A command declaring runLocation:terminal
// is therefore not a filter candidate at all; silently treating it as an
// in-process filter would run it with a document on its stdin.
static bool is_in_process_command (bundles::item_ptr const& item)
{
	return parse_command(item).run_location == run_location::in_process;
}

// The eligible candidates for an event, best scope match first.
//
// Ineligibility has to be settled *before* the scope-rank cutoff, not after it.
// bundles::query keeps only the highest-ranked matches by default, so a
// narrowly-scoped terminal command would carry the cutoff away with it and hide
// a broadly-scoped filter that should have been chosen — leaving binary import
// with no candidate at all. Ask for every match instead, drop the ineligible
// ones, and apply the same cutoff to what remains.
//
// The ranks come back from does_match() rather than from query(), which does
// not expose them. They are the same numbers query() sorted by: the one case
// where it stores a rank measured against something other than `event` is a
// resolved proxy item, and kind = kItemTypeCommand never matches a proxy.
static std::vector<bundles::item_ptr> path_filters (std::string const& event, std::string const& pathAttributes)
{
	std::vector<bundles::item_ptr> res;
	std::optional<double> topRank;
	for(auto const& item : bundles::query(bundles::kFieldSemanticClass, event, pathAttributes, bundles::kItemTypeCommand, oak::uuid_t(), false /* filter */))
	{
		if(!is_in_process_command(item))
			continue;

		std::optional<double> rank = item->does_match(bundles::kFieldSemanticClass, event, pathAttributes, bundles::kItemTypeCommand, oak::uuid_t());
		if(!rank)
			continue;
		if(!topRank)
			topRank = rank;
		else if(*rank != *topRank)
			break;

		res.push_back(item);
	}
	return res;
}

static std::vector<bundles::item_ptr> binary_filters (std::string const& event, std::string const& pathAttributes, io::bytes_ptr content)
{
	std::string contentAsString = "";
	size_t contentMatchSize = 256;
	for(char ch : *content)
	{
		contentAsString += utf8::to_s(ch);
		if(--contentMatchSize == 0)
			break;
	}

	std::multimap<ssize_t, bundles::item_ptr> ordering;
	for(auto const& item : path_filters(event, pathAttributes))
	{
		for(auto const& pattern : item->values_for_field(bundles::kFieldContentMatch))
		{
			if(regexp::match_t const& m = regexp::search(pattern, contentAsString))
				ordering.emplace(-m.end(), item);
		}
	}
	return ordering.empty() ? std::vector<bundles::item_ptr>() : std::vector<bundles::item_ptr>(1, ordering.begin()->second);
}

// ==========================
// = Filter Runner Delegate =
// ==========================

namespace
{
	struct event_delegate_t : command::delegate_t
	{
		event_delegate_t (io::bytes_ptr input, filter::callback_ptr context) : _input(input), _context(context) { }

		bool accept_html_data (command::runner_ptr runner, char const* data, size_t len)   { return fprintf(stderr, "html: %.*s", (int)len, data), false; }
		void show_document (std::string const& str)                                        { fprintf(stderr, "document: %s\n", str.c_str()); }
		void show_tool_tip (std::string const& str)                                        { fprintf(stderr, "tool tip: %s\n", str.c_str()); }
		void show_error (bundle_command_t const& command, int rc, std::string const& out, std::string const& err) { _context->filter_error(command, rc, out, err); }

		ng::ranges_t write_unit_to_fd (int fd, input::type unit, input::type fallbackUnit, input_format::type format, scope::selector_t const& scopeSelector, std::map<std::string, std::string>& variables, bool* inputWasSelection);
		bool accept_result (std::string const& out, output::type placement, output_format::type format, output_caret::type outputCaret, ng::ranges_t const& inputRanges, std::map<std::string, std::string> const& environment);

	private:
		io::bytes_ptr _input;
		filter::callback_ptr _context;
	};

	ng::ranges_t event_delegate_t::write_unit_to_fd (int fd, input::type unit, input::type fallbackUnit, input_format::type format, scope::selector_t const& scopeSelector, std::map<std::string, std::string>& variables, bool* inputWasSelection)
	{
		if(unit != input::entire_document || format != input_format::text)
		{
			close(fd);
			os_log_error(OS_LOG_DEFAULT, "Write unit to fd: unhandled unit/format: %d/%d", unit, format);
		}
		else
		{
			dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
				if(write(fd, _input->get(), _input->size()) == -1)
					perror("filter: write");
				close(fd);
			});
		}
		return { };
	}

	bool event_delegate_t::accept_result (std::string const& out, output::type placement, output_format::type format, output_caret::type outputCaret, ng::ranges_t const& inputRanges, std::map<std::string, std::string> const& environment)
	{
		if(placement != output::replace_document || format != output_format::text)
			return fprintf(stderr, "*** unhandled placement/format (%d/%d): %s\n", placement, format, out.c_str()), false;

		_context->set_content(std::make_shared<io::bytes_t>(out));
		return true;
	}
}

namespace filter
{
	std::string const kBundleEventBinaryImport  = "callback.document.binary-import";
	std::string const kBundleEventBinaryExport  = "callback.document.binary-export";
	std::string const kBundleEventTextImport    = "callback.document.import";
	std::string const kBundleEventTextExport    = "callback.document.export";

	std::vector<bundles::item_ptr> find (std::string const& path, io::bytes_ptr content, std::string const& pathAttributes, std::string const& event)
	{
		if(event == kBundleEventBinaryImport)
			return binary_filters(event, pathAttributes, content);
		else if(event == kBundleEventBinaryExport || event == kBundleEventTextImport || event == kBundleEventTextExport)
			return path_filters(event, pathAttributes);
		return std::vector<bundles::item_ptr>();
	}

	static std::map<std::string, std::string> path_variables (std::string const& path)
	{
		std::map<std::string, std::string> map = oak::basic_environment();
		if(path != NULL_STR)
		{
			map["TM_DISPLAYNAME"] = path::display_name(path);
			map["TM_FILEPATH"]    = path;
			map["TM_FILENAME"]    = path::name(path);
			map["TM_DIRECTORY"]   = path::parent(path);
		}
		else
		{
			map["TM_DISPLAYNAME"] = "untitled";
		}
		return variables_for_path(map, path);
	}

	void run (bundles::item_ptr filter, std::string const& path, io::bytes_ptr content, callback_ptr context)
	{
		std::map<std::string, std::string> variables = path_variables(path);
		command::runner_ptr runner = command::runner(parse_command(filter), ng::buffer_t(), ng::ranges_t(), bundles::scope_variables(variables << filter->bundle_variables(), file::path_attributes(path)), std::make_shared<event_delegate_t>(content, context));
		runner->launch();
	}

} /* filter */
