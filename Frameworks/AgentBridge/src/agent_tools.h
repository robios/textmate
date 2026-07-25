#ifndef AGENT_TOOLS_H_M4KD8PZ1
#define AGENT_TOOLS_H_M4KD8PZ1

#include <nlohmann/json.hpp>
#include <algorithm>
#include <string>
#include <vector>

// The one table of MCP tool descriptors, compiled into both frontends: the
// WebSocket server inside TextMate (AgentBridgeServer, which Claude Code
// connects to) and the stdio shim in the tm_agent CLI (‘tm_agent mcp’, which
// every other agent CLI registers as an MCP server). The shim answers
// ‘tools/list’ from this table even while TextMate is not running, so a second
// hand-maintained copy would eventually advertise tools the live server no
// longer answers — hence one table, one name set (the camelCase names the
// server has always advertised).
//
// Pure C++ over nlohmann json: no I/O, no Objective-C, so the CLI can compile
// it without linking the framework.
namespace agent_tools
{
	// Bit flags: a tool may be advertised by either frontend or both. The stdio
	// shim deliberately carries a subset — it forwards context queries over the
	// mate socket and has no business exposing the editor-mutating or
	// Claude-specific tools.
	enum frontend_t
	{
		websocket = 1 << 0, // Claude Code, over the WebSocket MCP server
		stdio     = 1 << 1, // ‘tm_agent mcp’, over stdin/stdout
	};

	// The MCP revisions this server implements, oldest first — an order the
	// negotiation below depends on, and which the tests assert rather than
	// assume.
	inline std::vector<std::string> const& known_protocol_versions ()
	{
		static std::vector<std::string> const res = { "2024-11-05", "2025-03-26", "2025-06-18" };
		return res;
	}

	// Echoing back whatever a client asked for is a claim to that revision's
	// semantics — structured tool output, elicitation, whatever a later one
	// adds — made by a server that has never seen it. The specification asks
	// for the latest revision the server does support instead, and that is also
	// the honest answer: a client that cannot work with it will say so, rather
	// than being told yes and finding out.
	inline std::string negotiated_protocol_version (std::string const& requested)
	{
		std::vector<std::string> const& known = known_protocol_versions();
		return std::find(known.begin(), known.end(), requested) != known.end() ? requested : known.back();
	}

	struct tool_t
	{
		std::string name;
		std::string description;
		nlohmann::json input_schema;
		int frontends;
	};

	inline nlohmann::json object_schema (nlohmann::json const& properties, nlohmann::json const& required = nlohmann::json::array())
	{
		return { { "type", "object" }, { "properties", properties }, { "required", required } };
	}

	// The descriptions carry the usage contract, not just a label: unlike
	// Claude’s IDE mode the other CLIs *choose* whether to call a tool, and the
	// description is the main lever on whether they do.
	inline std::vector<tool_t> const& table ()
	{
		static std::vector<tool_t> const res = {
			{
				"openFile",
				"Open a file in the TextMate editor and optionally select a range of text. Use this to show the user the code you are talking about instead of only describing where it is.",
				object_schema({
					{ "filePath",          { { "type", "string"  }, { "description", "Path to the file to open" } } },
					{ "preview",           { { "type", "boolean" }, { "description", "Whether to open the file in preview mode" } } },
					{ "startText",         { { "type", "string"  }, { "description", "Text pattern to find the start of the selection" } } },
					{ "endText",           { { "type", "string"  }, { "description", "Text pattern to find the end of the selection" } } },
					{ "selectToEndOfLine", { { "type", "boolean" }, { "description", "Extend selection to end of line" } } },
					{ "makeFrontmost",     { { "type", "boolean" }, { "description", "Whether to make the file the active editor tab" } } },
				}, nlohmann::json::array({ "filePath" })),
				websocket | stdio,
			},
			{
				"getCurrentSelection",
				"Get the text the user currently has selected in TextMate, and the file it is in. Call this first whenever the user refers to the current file, the selection, the cursor, or “this code”. The editor buffer may contain unsaved changes that are not yet on disk, so this is more current than reading the file.",
				object_schema(nlohmann::json::object()),
				websocket | stdio,
			},
			{
				"getLatestSelection",
				"Get the most recent non-empty text selection, even if the user has since clicked elsewhere. Use this when getCurrentSelection reports an empty selection but the user is clearly referring to something they just highlighted.",
				object_schema(nlohmann::json::object()),
				websocket,
			},
			{
				"getOpenEditors",
				"List the documents currently open in TextMate, which one is active, and which have unsaved changes. Call this when the user says “the open files”, “the other tab”, or otherwise refers to what they are working on without naming a path.",
				object_schema(nlohmann::json::object()),
				websocket | stdio,
			},
			{
				"getWorkspaceFolders",
				"Get the project folders open in TextMate. Call this before guessing at paths: it tells you which project the user is working in and what to resolve relative paths against.",
				object_schema(nlohmann::json::object()),
				websocket | stdio,
			},
			{
				"getDiagnostics",
				"Get language-server diagnostics (errors and warnings) TextMate is showing. Call this when the user mentions an error, a warning, or “what’s wrong with this file” rather than asking them to paste the message.",
				object_schema({
					{ "uri", { { "type", "string" }, { "description", "Optional file URI to get diagnostics for; omit for all files" } } },
				}),
				websocket | stdio,
			},
			{
				"checkDocumentDirty",
				"Check whether a document open in TextMate has unsaved changes. Call this before reading a file from disk when the user may have edited it.",
				object_schema({
					{ "filePath", { { "type", "string" }, { "description", "Path to the document to check" } } },
				}, nlohmann::json::array({ "filePath" })),
				websocket,
			},
			{
				"saveDocument",
				"Save a document with unsaved changes in TextMate.",
				object_schema({
					{ "filePath", { { "type", "string" }, { "description", "Path to the document to save" } } },
				}, nlohmann::json::array({ "filePath" })),
				websocket,
			},
			{
				"executeCode",
				"Execute code in a Jupyter kernel (not supported by TextMate)",
				object_schema({
					{ "code", { { "type", "string" }, { "description", "Code to execute" } } },
				}, nlohmann::json::array({ "code" })),
				websocket,
			},
		};
		return res;
	}

	// The ‘tools’ array of an MCP tools/list result, in table order.
	inline nlohmann::json descriptors (frontend_t frontend)
	{
		nlohmann::json res = nlohmann::json::array();
		for(tool_t const& tool : table())
		{
			if(tool.frontends & frontend)
				res.push_back({ { "name", tool.name }, { "description", tool.description }, { "inputSchema", tool.input_schema } });
		}
		return res;
	}

	inline bool advertised (std::string const& name, frontend_t frontend)
	{
		for(tool_t const& tool : table())
		{
			if(tool.name == name)
				return (tool.frontends & frontend) != 0;
		}
		return false;
	}

} /* agent_tools */

#endif /* AGENT_TOOLS_H_M4KD8PZ1 */
