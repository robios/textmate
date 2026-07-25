#ifndef CODEX_IDE_PROTOCOL_H_7Z2HQYPA
#define CODEX_IDE_PROTOCOL_H_7Z2HQYPA

#include <nlohmann/json.hpp>
#include <string>

// Codex TUI's private IDE-context IPC envelope. Keeping this small adapter
// separate from the Unix socket makes the observed version-0 wire contract
// executable as a unit test.
namespace codex_ide_protocol
{
	using json = nlohmann::json;

	inline bool response_for (json const& request, json const& ide_context, std::string const& handler_client_id, json* response)
	{
		if(!response || !request.is_object() || request.value("type", "") != "request" || !request.contains("requestId"))
			return false;

		std::string const method = request.value("method", "");
		if(method != "ide-context")
		{
			*response = {
				{ "type",      "response" },
				{ "requestId", request["requestId"] },
				{ "resultType", "error" },
				{ "method",     method },
				{ "handledByClientId", handler_client_id },
				{ "error",      "no-handler-for-request" },
			};
			return true;
		}

		*response = {
			{ "type",      "response" },
			{ "requestId", request["requestId"] },
			{ "resultType", "success" },
			{ "method",     "ide-context" },
			{ "handledByClientId", handler_client_id },
			{ "result", {
				{ "type",       "broadcast" },
				{ "ideContext", ide_context },
			} },
		};
		return true;
	}

	inline bool discovery_response_for (json const& message, bool provider_available, json* response)
	{
		if(!response || !message.is_object() || message.value("type", "") != "client-discovery-request" || !message.contains("requestId"))
			return false;

		json const request = message.value("request", json::object());
		bool const can_handle = provider_available && request.is_object() &&
			request.value("method", "") == "ide-context" &&
			request.value("version", 0) == 0;
		*response = {
			{ "type",      "client-discovery-response" },
			{ "requestId", message["requestId"] },
			{ "response",  { { "canHandle", can_handle } } },
		};
		return true;
	}
}

#endif /* CODEX_IDE_PROTOCOL_H_7Z2HQYPA */
