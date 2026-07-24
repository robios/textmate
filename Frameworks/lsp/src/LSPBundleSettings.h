#ifndef LSP_BUNDLE_SETTINGS_H_K3QX7VNM
#define LSP_BUNDLE_SETTINGS_H_K3QX7VNM

#include <settings/settings.h>
#include <scope/scope.h>

namespace lsp
{
	// Resolve an LSP setting with bundle Preferences fallback.
	//
	// Precedence: a value from the settings machinery (.tm_properties at any
	// level, Global.tmProperties, or environment) always wins — presence is
	// tested with settings_t::has(), so an explicitly assigned empty string
	// still counts as “set” and shadows any bundle value. When the key is
	// absent from settings, the highest-ranked bundle Preferences item whose
	// scope selector matches ‘scope’ provides the value. If neither source
	// defines the key, ‘defaultValue’ is returned.
	std::string setting_with_bundle_fallback (std::string const& key, settings_t const& settings, scope::context_t const& scope, std::string const& defaultValue = "");
	bool setting_with_bundle_fallback (std::string const& key, settings_t const& settings, scope::context_t const& scope, bool defaultValue);

	// Keep string literals on the string overload — without this, char const*
	// would convert to bool and silently pick the wrong function.
	inline std::string setting_with_bundle_fallback (std::string const& key, settings_t const& settings, scope::context_t const& scope, char const* defaultValue)
	{
		return setting_with_bundle_fallback(key, settings, scope, std::string(defaultValue));
	}

} /* lsp */

#endif /* end of include guard: LSP_BUNDLE_SETTINGS_H_K3QX7VNM */
