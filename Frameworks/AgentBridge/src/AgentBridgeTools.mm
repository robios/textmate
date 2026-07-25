#import "AgentBridgeTools.h"
#import "AgentBridgeWorkspace.h"
#import "agent_diagnostics.h"
#import "agent_json.h"
#import <document/OakDocument.h>
#import <ns/ns.h>

using json = nlohmann::json;

// Result caps (§4.2). An agent’s context window is a shared, finite resource:
// a whole-file selection or a repo-wide diagnostics dump would crowd out the
// conversation it was meant to inform. Every cap announces itself in the
// payload rather than silently shortening it, so the agent can ask for the
// rest by other means (it can always read the file).
//
// Diagnostics are capped twice because there are two ways for the answer to
// grow: the diagnostics themselves, and the files they are grouped under. A
// list of ten thousand empty file envelopes is unbounded in exactly the way
// the entry cap exists to prevent.
static size_t const kMaximumDiagnosticEntries = 200;
static size_t const kMaximumDiagnosticFiles   = 50;

@implementation AgentBridgeTools
+ (json)payloadForSelection:(AgentBridgeSelection*)selection
{
	std::string const text   = to_s(selection.text ?: @"");
	std::string const capped = agent_json::truncate_utf8(text, agent_json::maximum_selection_bytes);

	json res = {
		{ "text", capped },
		{ "filePath", selection.filePath ? json(to_s(selection.filePath)) : json(nullptr) },
		{ "selection", {
			{ "start", { { "line", selection.startLine }, { "character", selection.startCharacter } } },
			{ "end",   { { "line", selection.endLine   }, { "character", selection.endCharacter   } } },
			{ "isEmpty", selection.isEmpty ? true : false },
		} },
	};

	if(capped.size() != text.size())
	{
		res["truncated"]      = true;
		res["truncatedBytes"] = text.size() - capped.size();
		res["message"]        = "Selection truncated to " + std::to_string(capped.size()) + " bytes of " + std::to_string(text.size()) + "; read the file for the rest.";
	}
	return res;
}

+ (BOOL)invokeToolNamed:(NSString*)name arguments:(json)args workspace:(AgentBridgeWorkspace*)workspace routingPath:(NSString*)routingPath reply:(AgentBridgeToolReply)reply
{
	void (^replyJSON)(json const&, BOOL) = ^(json const& payload, BOOL isError){
		reply(agent_json::dump(payload), isError); // strict dump() throws on buffer excerpts with invalid UTF-8
	};

	if([name isEqualToString:@"getWorkspaceFolders"])
	{
		NSArray<NSString*>* folders = [workspace workspaceFolders];
		json folderList = json::array();
		for(NSString* folder in folders)
			folderList.push_back({ { "name", to_s(folder.lastPathComponent) }, { "uri", agent_json::file_uri(folder) }, { "path", to_s(folder) } });

		NSString* rootPath = [workspace projectPathForRoutingPath:routingPath] ?: folders.firstObject;
		json result = { { "success", true }, { "folders", folderList } };
		result["rootPath"] = rootPath ? json(to_s(rootPath)) : json(nullptr);
		replyJSON(result, NO);
	}
	else if([name isEqualToString:@"getOpenEditors"])
	{
		json tabs = json::array();
		for(NSDictionary* editor in [workspace openEditorsForRoutingPath:routingPath])
		{
			tabs.push_back({
				{ "uri",        agent_json::file_uri((NSString*)editor[@"path"]) },
				{ "isActive",   [editor[@"isActive"] boolValue] ? true : false },
				{ "label",      to_s((NSString*)editor[@"label"]) },
				{ "languageId", to_s((NSString*)editor[@"languageId"]) },
				{ "isDirty",    [editor[@"isDirty"] boolValue] ? true : false },
			});
		}

		json result = { { "tabs", tabs } };
		if(NSString* project = [workspace projectPathForRoutingPath:routingPath])
			result["project"] = to_s(project); // which window answered
		replyJSON(result, NO);
	}
	else if([name isEqualToString:@"getCurrentSelection"] || [name isEqualToString:@"getLatestSelection"])
	{
		AgentBridgeSelection* selection;
		if([name isEqualToString:@"getCurrentSelection"])
		{
			selection = [workspace currentSelectionForRoutingPath:routingPath];
			if(!selection)
				return replyJSON({ { "success", false }, { "message", "No active editor found" } }, NO), YES;
		}
		else
		{
			selection = workspace.latestSelection;
			if(!selection) // no selection change observed yet — a current non-empty selection is an acceptable seed
			{
				AgentBridgeSelection* current = [workspace currentSelectionForRoutingPath:routingPath];
				if(current && !current.isEmpty)
					selection = current;
			}
			if(!selection)
				return replyJSON({ { "success", false }, { "message", "No selection history available" } }, NO), YES;
		}

		json result = [self payloadForSelection:selection];
		result["success"] = true;
		if(NSString* project = [workspace projectPathForRoutingPath:routingPath])
			result["project"] = to_s(project);
		replyJSON(result, NO);
	}
	else if([name isEqualToString:@"openFile"])
	{
		NSString* filePath = to_ns(agent_json::string_arg(args, "filePath"));
		if(!filePath.length)
			return replyJSON({ { "success", false }, { "message", "filePath is required" } }, YES), YES;

		std::string const startTextArg = agent_json::string_arg(args, "startText");
		std::string const endTextArg   = agent_json::string_arg(args, "endText");
		NSString* startText = startTextArg.empty() ? nil : to_ns(startTextArg);
		NSString* endText   = endTextArg.empty()   ? nil : to_ns(endTextArg);
		BOOL selectToEndOfLine = agent_json::bool_arg(args, "selectToEndOfLine", false);
		BOOL makeFrontmost     = agent_json::bool_arg(args, "makeFrontmost", true);

		[workspace openFileAtPath:filePath selectFromText:startText toText:endText selectToEndOfLine:selectToEndOfLine makeFrontmost:makeFrontmost routingPath:routingPath completionHandler:^(OakDocument* document, NSUInteger lineCount){
			if(!document)
				return replyJSON({ { "success", false }, { "message", "File not found: " + to_s(filePath) } }, YES);

			if(makeFrontmost)
					reply("Opened file: " + to_s(document.path), NO);
			else	replyJSON({ { "success", true }, { "filePath", to_s(document.path) }, { "languageId", to_s(document.fileType ?: @"plaintext") }, { "lineCount", lineCount } }, NO);
		}];
	}
	else if([name isEqualToString:@"checkDocumentDirty"])
	{
		NSString* filePath = to_ns(agent_json::string_arg(args, "filePath"));
		OakDocument* document = [workspace openDocumentAtPath:filePath routingPath:routingPath];
		if(!document)
			return replyJSON({ { "success", false }, { "message", "Document not open: " + to_s(filePath) } }, NO), YES;

		replyJSON({ { "success", true }, { "filePath", to_s(document.path) }, { "isDirty", document.isDocumentEdited ? true : false }, { "isUntitled", false } }, NO);
	}
	else if([name isEqualToString:@"saveDocument"])
	{
		NSString* filePath = to_ns(agent_json::string_arg(args, "filePath"));
		OakDocument* document = [workspace openDocumentAtPath:filePath routingPath:routingPath];
		if(!document)
			return replyJSON({ { "success", false }, { "message", "Document not open: " + to_s(filePath) } }, NO), YES;

		[workspace saveDocument:document completionHandler:^(BOOL saved, NSString* message){
			replyJSON({ { "success", true }, { "filePath", to_s(document.path) }, { "saved", saved ? true : false }, { "message", to_s(message ?: (saved ? @"Document saved" : @"Save failed")) } }, NO);
		}];
	}
	else if([name isEqualToString:@"getDiagnostics"])
	{
		std::string const uriFilter = agent_json::string_arg(args, "uri");
		static char const* const severityNames[] = { "Error", "Error", "Warning", "Information", "Hint" };

		// The cache keys are URIs as the LSP server sent them (percent-encoded);
		// the client’s filter may round-trip our own URIs or be a plain path.
		// Compare decoded filesystem paths so encodings can’t prevent a match.
		NSString* filterPath = nil;
		if(!uriFilter.empty())
		{
			NSURL* filterURL = [NSURL URLWithString:to_ns(uriFilter)];
			filterPath = filterURL.isFileURL ? filterURL.path : to_ns(uriFilter);
		}

		// An explicit uri is the caller naming exactly what it wants, so it
		// outranks routing. Otherwise the answer is scoped to the project that
		// answers for this caller — the cache is process-wide, and a second
		// window’s repository would otherwise both appear in the answer and
		// spend the budget before this caller’s own files were reached.
		NSString* scopePath = filterPath ? nil : [workspace projectPathForRoutingPath:routingPath];
		std::string const scope = routingPath.length && scopePath ? to_s(scopePath) : std::string();

		NSDictionary<NSString*, NSArray<NSDictionary*>*>* diagnosticsByURI = [workspace diagnosticsByURI];
		std::vector<agent_diagnostics::file_t> files;
		for(NSString* uri in diagnosticsByURI)
		{
			NSURL* url = [NSURL URLWithString:uri];
			NSString* path = url.isFileURL ? url.path : uri;
			if(filterPath && ![path isEqualToString:filterPath])
				continue;

			files.push_back({ to_s(uri), to_s(path), (size_t)diagnosticsByURI[uri].count });
		}

		// A named uri keeps its empty answer — that is what the question was —
		// while a listing drops files with nothing to report, so they cannot
		// spend the file budget ahead of files that do.
		std::vector<agent_diagnostics::file_t> scoped = agent_diagnostics::in_scope(files, scope);
		if(!filterPath)
			scoped = agent_diagnostics::with_diagnostics(scoped);

		agent_diagnostics::plan_t const plan = agent_diagnostics::plan(scoped, kMaximumDiagnosticEntries, kMaximumDiagnosticFiles);

		json result = json::array();
		for(agent_diagnostics::entry_t const& planned : plan.entries)
		{
			NSString* uri = to_ns(scoped[planned.index].uri);
			NSArray<NSDictionary*>* entries = diagnosticsByURI[uri];

			json diagnostics = json::array();
			for(NSDictionary* entry in entries)
			{
				if(diagnostics.size() == planned.take)
					break;

				NSInteger severity = [entry[@"severity"] integerValue];
				json diagnostic = {
					{ "message",  to_s((NSString*)entry[@"message"]) },
					{ "severity", severityNames[severity >= 1 && severity <= 4 ? severity : 1] },
					{ "range", {
						{ "start", { { "line", [entry[@"line"] integerValue]    }, { "character", [entry[@"character"] integerValue]    } } },
						{ "end",   { { "line", [entry[@"endLine"] integerValue] }, { "character", [entry[@"endCharacter"] integerValue] } } },
					} },
				};
				if(NSString* source = entry[@"source"])
					diagnostic["source"] = to_s(source);
				if(id code = entry[@"code"])
					diagnostic["code"] = to_s([code description]);
				diagnostics.push_back(diagnostic);
			}

			json file = { { "uri", to_s(uri) }, { "diagnostics", diagnostics } };
			if(planned.omitted) // an extra key: clients ignore what they don’t know, and the shape stays the one they parse
				file["omitted"] = planned.omitted;
			result.push_back(file);
		}

		// One trailing entry says what this answer is and is not, when there is
		// something to say — which project it was scoped to, and what did not
		// fit. It carries the keys every element of this array has, so a client
		// walking the list finds a file with no diagnostics rather than a shape
		// it cannot read; without it, scoping and truncation would both be
		// invisible to the model. Absent entirely for an unrouted, uncapped
		// call, which is every call Claude makes.
		if(!scope.empty() || plan.omitted_files)
		{
			json summary = { { "uri", "textmate:scope" }, { "diagnostics", json::array() } };
			if(!scope.empty())
				summary["project"] = scope;
			if(plan.omitted_files)
			{
				summary["omittedFiles"]       = plan.omitted_files;
				summary["omittedDiagnostics"] = plan.omitted_diagnostics;
			}
			result.push_back(summary);
		}
		replyJSON(result, NO);
	}
	else if([name isEqualToString:@"executeCode"])
	{
		reply("executeCode is not supported: TextMate has no Jupyter kernel integration", YES);
	}
	else
	{
		return NO;
	}

	return YES;
}
@end
