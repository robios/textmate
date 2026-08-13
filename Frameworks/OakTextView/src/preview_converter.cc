#include "preview_converter.h"
#include <io/path.h>

namespace preview
{
	converter_t converter_for_file_type (std::string const& fileType)
	{
		if(fileType == NULL_STR || fileType.empty())
			return converter_t();

		bundles::item_ptr item;
		plist::any_t const value = bundles::value_for_setting("previewCommand", scope::context_t(fileType), &item);
		if(std::string const* command = std::get_if<std::string>(&value.data))
		{
			if(!command->empty())
				return converter_t{ converter_kind_t::external, *command, item };
		}

		if(fileType.starts_with("text.html.markdown"))
			return converter_t{ converter_kind_t::markdown };

		return converter_t();
	}

	std::map<std::string, std::string> converter_environment (std::map<std::string, std::string> base, std::string const& displayName, std::string const& path, bundles::item_ptr const& item)
	{
		if(item)
		{
			std::string const supportPath = item->support_path();
			if(supportPath != NULL_STR)
				base["TM_BUNDLE_SUPPORT"] = supportPath;
		}

		if(displayName != NULL_STR && !displayName.empty())
			base["TM_DISPLAYNAME"] = displayName;

		if(path != NULL_STR)
		{
			base["TM_FILEPATH"]  = path;
			base["TM_DIRECTORY"] = path::parent(path);
		}

		base["TM_PREVIEW"] = "1";
		return base;
	}

} /* preview */
