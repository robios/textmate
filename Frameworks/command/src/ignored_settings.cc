#include "ignored_settings.h"

namespace command
{
	std::vector<std::string> ignored_settings (plist::dictionary_t const& plist, bool dragCommand)
	{
		bundle_command_t const command = dragCommand ? parse_drag_command(plist) : parse_command(convert_command_from_v1(plist));
		if(command.run_location != run_location::terminal)
			return { };

		bundle_command_t const defaults = dragCommand ? parse_drag_command(plist::dictionary_t()) : parse_command(plist::dictionary_t());

		std::vector<std::string> res;
		auto ignored = [&res](bool asked, char const* key){ if(asked) res.emplace_back(key); };

		ignored(command.input                      != defaults.input,                      "input");
		ignored(command.input_fallback             != defaults.input_fallback,             "fallbackInput");
		ignored(command.input_format               != defaults.input_format,               "inputFormat");
		ignored(command.output                     != defaults.output,                     "outputLocation");
		ignored(command.output_format              != defaults.output_format,              "outputFormat");
		ignored(command.output_caret               != defaults.output_caret,               "outputCaret");
		ignored(command.output_reuse               != defaults.output_reuse,               "outputReuse");
		ignored(command.auto_refresh               != defaults.auto_refresh,               "autoRefresh");
		ignored(command.auto_scroll_output         != defaults.auto_scroll_output,         "autoScrollOutput");
		ignored(command.disable_output_auto_indent != defaults.disable_output_auto_indent, "disableOutputAutoIndent");
		ignored(command.disable_javascript_api     != defaults.disable_javascript_api,     "disableJavaScriptAPI");

		return res;
	}

} /* command */
