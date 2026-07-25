#import "../src/codex_ide_protocol.h"
#import "../src/agent_routing_path.h"

using nlohmann::json;

void test_codex_ide_context_response ()
{
	json const request = {
		{ "type", "request" },
		{ "requestId", "request-42" },
		{ "sourceClientId", "codex-tui" },
		{ "version", 0 },
		{ "method", "ide-context" },
		{ "params", { { "workspaceRoot", "/repo" } } },
	};
	json const context = {
		{ "activeFile", {
			{ "label", "main.cc" },
			{ "path", "src/main.cc" },
			{ "selection", {
				{ "start", { { "line", 3 }, { "character", 2 } } },
				{ "end",   { { "line", 3 }, { "character", 8 } } },
			} },
			{ "activeSelectionContent", "answer" },
			{ "selections", json::array() },
		} },
		{ "openTabs", json::array({ {
			{ "label", "main.cc" },
			{ "path", "src/main.cc" },
		} }) },
	};

	json response;
	OAK_ASSERT(codex_ide_protocol::response_for(request, context, "textmate-1234", &response));
	OAK_ASSERT_EQ(response["type"], "response");
	OAK_ASSERT_EQ(response["requestId"], "request-42");
	OAK_ASSERT_EQ(response["resultType"], "success");
	OAK_ASSERT_EQ(response["method"], "ide-context");
	OAK_ASSERT_EQ(response["handledByClientId"], "textmate-1234");
	OAK_ASSERT_EQ(response["result"]["type"], "broadcast");
	OAK_ASSERT_EQ(response["result"]["ideContext"], context);
}

void test_codex_ide_context_rejects_non_requests ()
{
	json response;
	OAK_ASSERT(!codex_ide_protocol::response_for(json::object(), json::object(), "textmate-1234", &response));
	OAK_ASSERT(!codex_ide_protocol::response_for({
		{ "type", "broadcast" },
		{ "requestId", "request-42" },
	}, json::object(), "textmate-1234", &response));
}

void test_codex_ide_context_unknown_method_error ()
{
	json response;
	OAK_ASSERT(codex_ide_protocol::response_for({
		{ "type", "request" },
		{ "requestId", "request-42" },
		{ "method", "something-new" },
	}, json::object(), "textmate-1234", &response));
	OAK_ASSERT_EQ(response["resultType"], "error");
	OAK_ASSERT_EQ(response["handledByClientId"], "textmate-1234");
	OAK_ASSERT_EQ(response["error"], "no-handler-for-request");
}

void test_codex_ide_context_client_discovery ()
{
	json response;
	OAK_ASSERT(codex_ide_protocol::discovery_response_for({
		{ "type", "client-discovery-request" },
		{ "requestId", "discovery-7" },
		{ "request", {
			{ "type", "request" },
			{ "method", "ide-context" },
			{ "version", 0 },
		} },
	}, true, &response));
	OAK_ASSERT_EQ(response["type"], "client-discovery-response");
	OAK_ASSERT_EQ(response["requestId"], "discovery-7");
	OAK_ASSERT_EQ(response["response"]["canHandle"], true);

	OAK_ASSERT(codex_ide_protocol::discovery_response_for({
		{ "type", "client-discovery-request" },
		{ "requestId", "discovery-8" },
		{ "request", {
			{ "type", "request" },
			{ "method", "future-method" },
			{ "version", 0 },
		} },
	}, true, &response));
	OAK_ASSERT_EQ(response["response"]["canHandle"], false);

	OAK_ASSERT(codex_ide_protocol::discovery_response_for({
		{ "type", "client-discovery-request" },
		{ "requestId", "discovery-9" },
		{ "request", {
			{ "type", "request" },
			{ "method", "ide-context" },
			{ "version", 0 },
		} },
	}, false, &response));
	OAK_ASSERT_EQ(response["response"]["canHandle"], false);
}

void test_codex_ide_context_macos_path_aliases ()
{
	OAK_ASSERT_EQ(agent_routing_path::normalize("/var/folders/project"), "/private/var/folders/project");
	OAK_ASSERT_EQ(agent_routing_path::normalize("/private/var/folders/project"), "/private/var/folders/project");
	OAK_ASSERT_EQ(agent_routing_path::normalize("/tmp/project"), "/private/tmp/project");
	OAK_ASSERT_EQ(agent_routing_path::normalize("/various/project"), "/various/project");

	OAK_ASSERT(agent_routing_path::routes_to_project(
		"/private/var/folders/project",
		"/var/folders/project"));
	OAK_ASSERT(agent_routing_path::routes_to_project(
		"/private/var/folders/project/subdirectory",
		"/var/folders/project"));
	OAK_ASSERT(!agent_routing_path::routes_to_project(
		"/private/var/folders/project-a",
		"/var/folders/project-b"));
	OAK_ASSERT(!agent_routing_path::routes_to_project(
		"/private/var/folders",
		"/var/folders/project"));
}
