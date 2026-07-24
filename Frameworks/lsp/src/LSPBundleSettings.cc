#include "LSPBundleSettings.h"
#include <bundles/bundles.h>
#include <os/log.h>

namespace lsp
{
	static void warn_unsupported_type (std::string const& key, bundles::item_ptr const& item)
	{
		os_log_error(OS_LOG_DEFAULT, "Ignoring LSP setting ‘%{public}s’ in %{public}s: value must be a string, boolean, or integer (for lspInitOptions use a string containing JSON)", key.c_str(), item ? item->name_with_bundle().c_str() : "bundle item");
	}

	std::string setting_with_bundle_fallback (std::string const& key, settings_t const& settings, scope::context_t const& scope, std::string const& defaultValue)
	{
		if(settings.has(key))
			return settings.get(key, defaultValue);

		bundles::item_ptr item;
		plist::any_t const value = bundles::value_for_setting(key, scope, &item);
		if(std::string const* str = std::get_if<std::string>(&value.data))
			return *str;
		else if(bool const* flag = std::get_if<bool>(&value.data))
			return *flag ? "true" : "false";
		else if(int32_t const* number = std::get_if<int32_t>(&value.data))
			return std::to_string(*number);
		else if(!value.empty())
			warn_unsupported_type(key, item);

		return defaultValue;
	}

	bool setting_with_bundle_fallback (std::string const& key, settings_t const& settings, scope::context_t const& scope, bool defaultValue)
	{
		if(settings.has(key))
			return settings.get(key, defaultValue);

		bundles::item_ptr item;
		plist::any_t const value = bundles::value_for_setting(key, scope, &item);
		if(bool const* flag = std::get_if<bool>(&value.data))
			return *flag;
		else if(int32_t const* number = std::get_if<int32_t>(&value.data))
			return *number != 0;
		else if(std::string const* str = std::get_if<std::string>(&value.data))
			return *str != "0" && *str != "false";
		else if(!value.empty())
			warn_unsupported_type(key, item);

		return defaultValue;
	}

} /* lsp */
