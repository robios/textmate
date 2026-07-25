#import "../../../Applications/tm_agent/src/mcp_shim.h"

// Tests for the protocol half of ‘tm_agent mcp’. The header is pure C++,
// shared with Applications/tm_agent: message in, message out, with the tool
// invocation behind a callback, so the whole thing is testable without a
// socket or a running app.

static mcp_shim::context_t ContextInvoking (mcp_shim::invoke_fn const& invoke)
{
	mcp_shim::context_t res;
	res.version = "2.5-test";
	res.invoke  = invoke;
	return res;
}

// TextMate answers, the tool succeeds.
static mcp_shim::context_t WorkingContext (std::string const& text = "{\"success\":true}")
{
	return ContextInvoking([text](std::string const& name, nlohmann::json const& arguments) -> mcp_shim::tool_result_t {
		return { true, false, text };
	});
}

// TextMate is not running.
static mcp_shim::context_t OfflineContext ()
{
	return ContextInvoking([](std::string const& name, nlohmann::json const& arguments) -> mcp_shim::tool_result_t {
		return { false, false, "TextMate is not running, so the editor context is unavailable: no socket" };
	});
}

void test_initialize_answers_without_textmate ()
{
	nlohmann::json response;
	OAK_ASSERT(mcp_shim::handle_line("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-06-18\"}}", OfflineContext(), &response));

	OAK_ASSERT_EQ(response["id"].get<int>(), 1);
	OAK_ASSERT(response.contains("result"));
	// A revision we implement is echoed, and the tools capability is advertised
	// — a client whose initialize fails may drop the server for the whole
	// session.
	OAK_ASSERT_EQ(response["result"]["protocolVersion"].get<std::string>(), "2025-06-18");
	OAK_ASSERT(response["result"]["capabilities"].contains("tools"));
	OAK_ASSERT_EQ(response["result"]["serverInfo"]["name"].get<std::string>(), "TextMate");
	OAK_ASSERT_EQ(response["result"]["serverInfo"]["version"].get<std::string>(), "2.5-test");
}

void test_tools_list_answers_without_textmate ()
{
	nlohmann::json response;
	OAK_ASSERT(mcp_shim::handle_line("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}", OfflineContext(), &response));

	nlohmann::json const tools = response["result"]["tools"];
	OAK_ASSERT_EQ(tools.dump(), agent_tools::descriptors(agent_tools::stdio).dump());
	OAK_ASSERT(!tools.empty());
}

void test_notifications_get_no_response ()
{
	nlohmann::json response;
	OAK_ASSERT(!mcp_shim::handle_line("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}", WorkingContext(), &response));
	OAK_ASSERT(!mcp_shim::handle_line("{\"jsonrpc\":\"2.0\",\"method\":\"someUnknownNotification\"}", WorkingContext(), &response));
}

void test_tool_call_forwards_name_and_arguments ()
{
	std::string seenName;
	nlohmann::json seenArguments;
	mcp_shim::context_t context = ContextInvoking([&seenName, &seenArguments](std::string const& name, nlohmann::json const& arguments) -> mcp_shim::tool_result_t {
		seenName      = name;
		seenArguments = arguments;
		return { true, false, "Opened file: /tmp/foo.cc" };
	});

	nlohmann::json response;
	OAK_ASSERT(mcp_shim::handle_line("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"openFile\",\"arguments\":{\"filePath\":\"/tmp/foo.cc\"}}}", context, &response));

	OAK_ASSERT_EQ(seenName, "openFile");
	OAK_ASSERT_EQ(seenArguments["filePath"].get<std::string>(), "/tmp/foo.cc");

	OAK_ASSERT_EQ(response["result"]["content"][0]["type"].get<std::string>(), "text");
	OAK_ASSERT_EQ(response["result"]["content"][0]["text"].get<std::string>(), "Opened file: /tmp/foo.cc");
	OAK_ASSERT(!response["result"].contains("isError"));
}

void test_tool_call_without_textmate_is_a_tool_error ()
{
	nlohmann::json response;
	OAK_ASSERT(mcp_shim::handle_line("{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"getCurrentSelection\"}}", OfflineContext(), &response));

	// Reported inside the result, not as a JSON-RPC error: the model can read
	// it, and the server stays healthy for the next call.
	OAK_ASSERT(!response.contains("error"));
	OAK_ASSERT_EQ(response["result"]["isError"].get<bool>(), true);
	OAK_ASSERT(response["result"]["content"][0]["text"].get<std::string>().find("TextMate is not running") != std::string::npos);
}

void test_tool_error_from_textmate_is_marked ()
{
	mcp_shim::context_t context = ContextInvoking([](std::string const& name, nlohmann::json const& arguments) -> mcp_shim::tool_result_t {
		return { true, true, "{\"success\":false,\"message\":\"filePath is required\"}" };
	});

	nlohmann::json response;
	OAK_ASSERT(mcp_shim::handle_line("{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",\"params\":{\"name\":\"openFile\",\"arguments\":{}}}", context, &response));
	OAK_ASSERT_EQ(response["result"]["isError"].get<bool>(), true);
}

void test_unknown_tool_is_a_protocol_error ()
{
	nlohmann::json response;
	OAK_ASSERT(mcp_shim::handle_line("{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"tools/call\",\"params\":{\"name\":\"saveDocument\"}}", WorkingContext(), &response));

	// saveDocument exists, but not on this frontend — the shim must not forward
	// a name its own tools/list never advertised.
	OAK_ASSERT(response.contains("error"));
	OAK_ASSERT_EQ(response["error"]["code"].get<int>(), -32601);
}

void test_unknown_method_and_parse_error ()
{
	nlohmann::json response;
	OAK_ASSERT(mcp_shim::handle_line("{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"resources/read\"}", WorkingContext(), &response));
	OAK_ASSERT_EQ(response["error"]["code"].get<int>(), -32601);

	OAK_ASSERT(mcp_shim::handle_line("not json at all", WorkingContext(), &response));
	OAK_ASSERT_EQ(response["error"]["code"].get<int>(), -32700);
	OAK_ASSERT(response["id"].is_null());
}

void test_ping_and_empty_lists ()
{
	nlohmann::json response;
	OAK_ASSERT(mcp_shim::handle_line("{\"jsonrpc\":\"2.0\",\"id\":8,\"method\":\"ping\"}", WorkingContext(), &response));
	OAK_ASSERT(response["result"].is_object() && response["result"].empty());

	OAK_ASSERT(mcp_shim::handle_line("{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"prompts/list\"}", WorkingContext(), &response));
	OAK_ASSERT(response["result"]["prompts"].is_array());
}

void test_initialize_does_not_promise_an_unknown_revision ()
{
	nlohmann::json response;
	OAK_ASSERT(mcp_shim::handle_line("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2099-01-01\"}}", OfflineContext(), &response));

	// Echoing it back would claim conformance to semantics this server has
	// never seen; the answer is the newest revision it does implement.
	std::vector<std::string> const& known = agent_tools::known_protocol_versions();
	OAK_ASSERT_EQ(response["result"]["protocolVersion"].get<std::string>(), *std::max_element(known.begin(), known.end()));
}
