#ifndef MCP_SHIM_H_B62NKW4P
#define MCP_SHIM_H_B62NKW4P

#include <agent_tools.h>

#include <functional>
#include <string>

// ‘tm_agent mcp’: an MCP server speaking JSON-RPC over stdin/stdout, one JSON
// object per line, which forwards tool calls to a running TextMate over the
// mate socket. Every agent CLI can be pointed at a stdio MCP server, so this
// is the one bridge that serves all of them — none of them has Claude’s
// automatic IDE discovery.
//
// This header is the protocol half, kept pure so it can be tested without a
// socket or a running app: message in, message out, with the actual invocation
// behind a callback. The loop that reads stdin lives in mcp_shim.cc.
namespace mcp_shim
{
	struct tool_result_t
	{
		bool delivered = false; // TextMate answered — whether or not the tool itself succeeded
		bool is_error  = false; // the tool answered with an error result
		std::string text;       // the tool’s content text, or why ‘delivered’ is false
	};

	using invoke_fn = std::function<tool_result_t(std::string const& name, nlohmann::json const& arguments)>;

	struct context_t
	{
		std::string version = "dev";
		invoke_fn invoke;
	};

	inline nlohmann::json error_response (nlohmann::json const& id, int code, std::string const& message)
	{
		return { { "jsonrpc", "2.0" }, { "id", id }, { "error", { { "code", code }, { "message", message } } } };
	}

	inline nlohmann::json result_response (nlohmann::json const& id, nlohmann::json const& result)
	{
		return { { "jsonrpc", "2.0" }, { "id", id }, { "result", result } };
	}

	inline nlohmann::json content_result (std::string const& text, bool is_error)
	{
		nlohmann::json res = { { "content", nlohmann::json::array({ { { "type", "text" }, { "text", text } } }) } };
		if(is_error)
			res["isError"] = true;
		return res;
	}

	// Handle one parsed JSON-RPC message. Returns false when nothing is to be
	// written back — notifications, and requests with no id.
	inline bool handle_message (nlohmann::json const& message, context_t const& context, nlohmann::json* response)
	{
		if(!message.is_object())
			return *response = error_response(nullptr, -32600, "Invalid Request"), true;

		bool const has_id = message.contains("id") && !message["id"].is_null();
		nlohmann::json const id = has_id ? nlohmann::json(message["id"]) : nlohmann::json(nullptr);

		auto method_it = message.find("method");
		std::string const method = method_it != message.end() && method_it->is_string() ? method_it->get<std::string>() : std::string();
		nlohmann::json const params = message.contains("params") && message["params"].is_object() ? message["params"] : nlohmann::json::object();

		if(method.rfind("notifications/", 0) == 0)
			return false; // initialized, cancelled, … — nothing to do and nothing to answer

		if(method == "initialize")
		{
			// Answered from here even when TextMate is not running: a client
			// whose initialize fails marks the server unhealthy and may drop it
			// for the whole session, taking the tools away for good. Only
			// actual tool calls need the app.
			std::string requested;
			if(params.contains("protocolVersion") && params["protocolVersion"].is_string())
				requested = params["protocolVersion"].get<std::string>();

			*response = result_response(id, {
				{ "protocolVersion", agent_tools::negotiated_protocol_version(requested) },
				{ "capabilities", { { "tools", nlohmann::json::object() } } },
				{ "serverInfo", { { "name", "TextMate" }, { "version", context.version } } },
			});
			return true;
		}

		if(method == "ping")
			return *response = result_response(id, nlohmann::json::object()), true;

		if(method == "tools/list")
			return *response = result_response(id, { { "tools", agent_tools::descriptors(agent_tools::stdio) } }), true;

		if(method == "prompts/list")
			return *response = result_response(id, { { "prompts", nlohmann::json::array() } }), true;

		if(method == "resources/list")
			return *response = result_response(id, { { "resources", nlohmann::json::array() } }), true;

		if(method == "tools/call")
		{
			auto name_it = params.find("name");
			std::string const name = name_it != params.end() && name_it->is_string() ? name_it->get<std::string>() : std::string();
			if(!agent_tools::advertised(name, agent_tools::stdio))
				return *response = error_response(id, -32601, "Unknown tool: " + name), true;

			nlohmann::json const arguments = params.contains("arguments") && params["arguments"].is_object() ? params["arguments"] : nlohmann::json::object();
			tool_result_t const res = context.invoke ? context.invoke(name, arguments) : tool_result_t{ false, false, "No way to reach TextMate was configured" };

			// A failure to reach TextMate is reported as a tool error rather
			// than a protocol error: the model can read it, and the server
			// stays healthy for the next call, by which time the app may be
			// back.
			*response = result_response(id, content_result(res.text, !res.delivered || res.is_error));
			return true;
		}

		if(!has_id)
			return false;

		*response = error_response(id, -32601, "Method not found: " + method);
		return true;
	}

	// Parse and handle one line of input.
	inline bool handle_line (std::string const& line, context_t const& context, nlohmann::json* response)
	{
		nlohmann::json message = nlohmann::json::parse(line.begin(), line.end(), nullptr, false);
		if(message.is_discarded())
			return *response = error_response(nullptr, -32700, "Parse error"), true;
		return handle_message(message, context, response);
	}

	// The stdin/stdout loop: reads newline-delimited JSON, forwards tool calls
	// to TextMate over the mate socket, writes responses. Returns the process
	// exit code.
	int run (std::string const& version);

} /* mcp_shim */

#endif /* MCP_SHIM_H_B62NKW4P */
