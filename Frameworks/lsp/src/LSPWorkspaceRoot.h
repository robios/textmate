#ifndef LSP_WORKSPACE_ROOT_H_R7WQ2M4D
#define LSP_WORKSPACE_ROOT_H_R7WQ2M4D

#include <string>
#include <vector>

namespace lsp
{
	// The nearest ancestor directory of ‘filePath’ that contains a workspace
	// marker (.git, package.json, CMakeLists.txt, …), or the empty string when
	// there is none.
	std::string marker_workspace_root (std::string const& filePath);

	// The folder to announce for ‘filePath’ to a server that one process shares
	// across all projects (Copilot), or the empty string for none.
	//
	// Such a server watches files inside every workspace folder it is given,
	// falling back to the nearest existing ancestor for files that do not
	// exist, so a guessed folder is worse than none: there is no fallback to
	// the file’s own directory, and a folder that does not exist, home, or an
	// ancestor of home is never returned — any of those ends up watching the
	// entire home folder. ‘configuredRoot’ (the lspRootPath setting) wins over
	// marker detection when it passes the same checks.
	std::string shared_server_workspace_folder (std::string const& configuredRoot, std::string const& filePath, std::string const& home);

} /* lsp */

#endif /* end of include guard: LSP_WORKSPACE_ROOT_H_R7WQ2M4D */
