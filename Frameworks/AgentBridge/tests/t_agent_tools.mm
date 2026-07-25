#import "../src/agent_tools.h"

// The stdio shim in tm_agent answers ‘tools/list’ from a static table even
// while TextMate is not running, so a drifted copy would advertise tools the
// live WebSocket server no longer answers. These tests pin the two lists
// against each other — trivially true as long as both frontends keep reading
// the one table in agent_tools.h, and the first thing to fail if anyone adds a
// second one.

static nlohmann::json ToolNamed (nlohmann::json const& tools, std::string const& name)
{
	for(auto const& tool : tools)
	{
		if(tool.value("name", std::string()) == name)
			return tool;
	}
	return nlohmann::json();
}

void test_websocket_tool_set ()
{
	nlohmann::json const tools = agent_tools::descriptors(agent_tools::websocket);

	// The names Claude Code has always seen; the shared table must not quietly
	// drop or rename one.
	std::vector<std::string> const expected = {
		"openFile", "getCurrentSelection", "getLatestSelection", "getOpenEditors",
		"getWorkspaceFolders", "getDiagnostics", "checkDocumentDirty", "saveDocument", "executeCode",
	};

	OAK_ASSERT_EQ(tools.size(), expected.size());
	for(size_t i = 0; i < expected.size(); ++i)
		OAK_ASSERT_EQ(tools[i].value("name", std::string()), expected[i]);
}

void test_stdio_tool_set ()
{
	nlohmann::json const tools = agent_tools::descriptors(agent_tools::stdio);

	// §4.2: the context tools, and nothing that mutates or is Claude-specific.
	std::vector<std::string> const expected = {
		"openFile", "getCurrentSelection", "getOpenEditors", "getWorkspaceFolders", "getDiagnostics",
	};

	OAK_ASSERT_EQ(tools.size(), expected.size());
	for(size_t i = 0; i < expected.size(); ++i)
		OAK_ASSERT_EQ(tools[i].value("name", std::string()), expected[i]);
}

void test_offline_and_live_lists_agree ()
{
	nlohmann::json const stdioTools     = agent_tools::descriptors(agent_tools::stdio);
	nlohmann::json const websocketTools = agent_tools::descriptors(agent_tools::websocket);

	// Every tool the shim advertises offline must exist on the live server with
	// an identical descriptor: same description, same input schema. A client
	// that discovered a tool through the shim then calls it through TextMate.
	for(auto const& tool : stdioTools)
	{
		std::string const name = tool.value("name", std::string());
		nlohmann::json const live = ToolNamed(websocketTools, name);
		OAK_ASSERT(!live.is_null());
		OAK_ASSERT_EQ(live.dump(), tool.dump());
		OAK_ASSERT(agent_tools::advertised(name, agent_tools::stdio));
		OAK_ASSERT(agent_tools::advertised(name, agent_tools::websocket));
	}
}

void test_descriptor_shape ()
{
	for(auto const& tool : agent_tools::descriptors(agent_tools::websocket))
	{
		OAK_ASSERT(tool.contains("name") && tool["name"].is_string());
		OAK_ASSERT(tool.contains("description") && !tool["description"].get<std::string>().empty());

		nlohmann::json const schema = tool.value("inputSchema", nlohmann::json());
		OAK_ASSERT_EQ(schema.value("type", std::string()), "object");
		OAK_ASSERT(schema.contains("properties") && schema["properties"].is_object());
		OAK_ASSERT(schema.contains("required") && schema["required"].is_array());

		// A required argument that is not in ‘properties’ would be a schema no
		// client can satisfy.
		for(auto const& required : schema["required"])
			OAK_ASSERT(schema["properties"].contains(required.get<std::string>()));
	}
}

void test_unknown_tool_is_not_advertised ()
{
	OAK_ASSERT(!agent_tools::advertised("openDiff", agent_tools::websocket));         // removed in Phase A
	OAK_ASSERT(!agent_tools::advertised("saveDocument", agent_tools::stdio));         // websocket only
	OAK_ASSERT(!agent_tools::advertised("getLatestSelection", agent_tools::stdio));   // websocket only
}

void test_protocol_version_negotiation ()
{
	std::vector<std::string> const& known = agent_tools::known_protocol_versions();

	// The list must really be oldest-first, because the fallback below is "the
	// last one". ISO dates sort lexicographically, so this is that claim.
	OAK_ASSERT(!known.empty());
	OAK_ASSERT(std::is_sorted(known.begin(), known.end()));

	// A revision we implement is echoed…
	for(std::string const& version : known)
		OAK_ASSERT_EQ(agent_tools::negotiated_protocol_version(version), version);

	// …and one we do not is answered with the newest we do, which is what the
	// specification asks for. Asserted as that property, not as the string it
	// currently happens to be: writing the constant is how this test came to
	// certify the opposite of every comment around it.
	std::string const newest = *std::max_element(known.begin(), known.end());
	OAK_ASSERT_EQ(agent_tools::negotiated_protocol_version("2099-01-01"), newest);
	OAK_ASSERT_EQ(agent_tools::negotiated_protocol_version(""), newest);
	OAK_ASSERT_EQ(agent_tools::negotiated_protocol_version("nonsense"), newest);
}
