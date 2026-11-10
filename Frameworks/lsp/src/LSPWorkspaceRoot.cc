#include "LSPWorkspaceRoot.h"
#include <io/path.h>
#include <sys/stat.h>

namespace
{
	std::vector<std::string> const& workspace_markers ()
	{
		static std::vector<std::string> const markers = {
			".git", "composer.json", "package.json", "tsconfig.json",
			"CMakeLists.txt", "compile_commands.json", "go.mod",
			"Cargo.toml", "pyproject.toml", "setup.py", ".clangd"
		};
		return markers;
	}

	// Compares file identity rather than spelling, so a symlink to home, a
	// differently cased path, or the /System/Volumes/Data firmlink still counts.
	bool is_home_or_ancestor (std::string const& dir, std::string const& home)
	{
		struct stat dirInfo;
		if(stat(dir.c_str(), &dirInfo) != 0)
			return false;

		std::string ancestor = path::resolve(home), previous;
		while(ancestor != previous)
		{
			struct stat info;
			if(stat(ancestor.c_str(), &info) == 0 && info.st_dev == dirInfo.st_dev && info.st_ino == dirInfo.st_ino)
				return true;
			previous = ancestor;
			ancestor = path::parent(ancestor);
		}
		return false;
	}

	// A missing folder is as bad as home: the server watches the nearest
	// existing ancestor of every target inside a folder that does not exist.
	bool is_acceptable_shared_folder (std::string const& dir, std::string const& home)
	{
		return !dir.empty() && path::is_absolute(dir) && path::is_directory(dir) && !is_home_or_ancestor(dir, home);
	}
}

namespace lsp
{
	std::string marker_workspace_root (std::string const& filePath)
	{
		std::string dir = path::parent(filePath);
		std::string previousDir;

		while(dir != previousDir && dir != "/")
		{
			for(auto const& marker : workspace_markers())
			{
				if(path::exists(path::join(dir, marker)))
					return dir;
			}
			previousDir = dir;
			dir = path::parent(dir);
		}
		return "";
	}

	std::string shared_server_workspace_folder (std::string const& configuredRoot, std::string const& filePath, std::string const& home)
	{
		if(!configuredRoot.empty())
		{
			std::string const root = path::normalize(configuredRoot);
			if(is_acceptable_shared_folder(root, home))
				return root;
		}

		std::string const root = marker_workspace_root(filePath);
		return is_acceptable_shared_folder(root, home) ? root : "";
	}

} /* lsp */
