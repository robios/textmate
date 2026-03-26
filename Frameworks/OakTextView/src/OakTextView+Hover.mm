#import "OakTextView_Private.h"
#import "OakTextView_LSPUtilities.h"
#import <lsp/LSPManager.h>
#import <lsp/LSPClient.h>
#import <theme/OakTheme.h>
#import <parse/parse.h>
#import <parse/grammar.h>
#import <text/utf16.h>
#import <bundles/bundles.h>

@implementation OakTextView (Hover)

- (void)lspShowHoverInfo:(id)sender
{
	if(!documentView)
		return;

	size_t caret = documentView->ranges().last().last.index;
	ng::index_t index(caret);
	[self lspRequestHoverAtIndex:index];
}

- (void)lspRequestHoverAtIndex:(ng::index_t)index
{
	if(!documentView)
		return;

	OakDocument* doc = self.document;
	if(!doc)
		return;

	text::pos_t pos = documentView->convert(index.index);

	ng::range_t wordRange = ng::extend(*documentView, index, kSelectionExtendToWord).last();
	std::string word = documentView->substr(wordRange.min().index, wordRange.max().index);
	NSString* cacheKey = to_ns(word);

	if(_lspHoverCache && cacheKey.length > 0)
	{
		NSDictionary* cachedEntry = _lspHoverCache[cacheKey];
		if(cachedEntry)
		{
			NSDate* cachedAt = cachedEntry[@"_cachedAt"];
			if(cachedAt && -[cachedAt timeIntervalSinceNow] < 60.0)
			{
				OakTooltipContent* content = cachedEntry[@"content"];
				if(content && ![content isEqual:[NSNull null]])
				{
					ng::range_t wordRange = ng::extend(*documentView, index, kSelectionExtendToWord).last();
					CGRect wordRect = documentView->rect_for_range(wordRange.min().index, wordRange.max().index);
					NSRect viewRect = NSRectFromCGRect(wordRect);

					[self showLSPHoverTooltip:content atRect:viewRect];
					return;
				}
			}
			else
			{
				[_lspHoverCache removeObjectForKey:cacheKey];
			}
		}
	}

	[[LSPManager sharedManager] flushPendingChangesForDocument:doc];

	__weak OakTextView* weakSelf = self;
	_lspHoverRequestId = [[LSPManager sharedManager] requestHoverForDocument:doc
		line:pos.line
		character:pos.column
		completion:^(NSDictionary* hover) {
			OakTextView* strongSelf = weakSelf;
			if(!strongSelf || !hover)
				return;

			strongSelf->_lspHoverRequestId = 0;

			dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
				OakTooltipContent* content = [strongSelf createTooltipContentFromHover:hover];

				dispatch_async(dispatch_get_main_queue(), ^{
					if(!strongSelf || !strongSelf->documentView)
						return;

					if(!strongSelf->_lspHoverCache)
						strongSelf->_lspHoverCache = [NSMutableDictionary new];
					if(cacheKey.length > 0)
					{
						if(strongSelf->_lspHoverCache.count >= 50)
						{
							// Evict oldest entry
							NSString* oldestKey = nil;
							NSDate* oldestDate = [NSDate date];
							for(NSString* key in strongSelf->_lspHoverCache)
							{
								NSDate* date = strongSelf->_lspHoverCache[key][@"_cachedAt"];
								if(date && [date compare:oldestDate] == NSOrderedAscending)
								{
									oldestDate = date;
									oldestKey = key;
								}
							}
							if(oldestKey)
								[strongSelf->_lspHoverCache removeObjectForKey:oldestKey];
						}
						strongSelf->_lspHoverCache[cacheKey] = @{
							@"content": content ?: [NSNull null],
							@"_cachedAt": [NSDate date]
						};
					}

					if(content)
					{
						ng::range_t wordRange = ng::extend(*strongSelf->documentView, index, kSelectionExtendToWord).last();
						CGRect wordRect = strongSelf->documentView->rect_for_range(wordRange.min().index, wordRange.max().index);
						NSRect viewRect = NSRectFromCGRect(wordRect);
						[strongSelf showLSPHoverTooltip:content atRect:viewRect];
					}
				});
			});
		}];
}

- (NSAttributedString*)parseMarkdownDocumentation:(NSString*)text
{
	NSArray* sections = [text componentsSeparatedByString:@"\n\n---\n\n"];
	if(sections.count > 1)
	{
		NSMutableArray* unique = [NSMutableArray new];
		NSMutableSet* seen = [NSMutableSet new];
		for(NSString* section in sections)
		{
			NSString* trimmed = [section stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
			if(trimmed.length > 0 && ![seen containsObject:trimmed])
			{
				[seen addObject:trimmed];
				[unique addObject:trimmed];
			}
		}
		text = [unique componentsJoinedByString:@"\n\n---\n\n"];
	}

	NSMutableAttributedString* combined = [[NSMutableAttributedString alloc] init];
	NSString* grammarScope = documentView ? to_ns(documentView->file_type()) : nil;

	static NSRegularExpression* codeBlockRegex = [NSRegularExpression regularExpressionWithPattern:@"```(\\w+)?\\n([\\s\\S]*?)\\n```" options:0 error:nil];
	NSArray* codeMatches = [codeBlockRegex matchesInString:text options:0 range:NSMakeRange(0, text.length)];

	NSString* bodyText = text;
	if(codeMatches.count > 0)
	{
		NSTextCheckingResult* firstMatch = codeMatches[0];
		NSString* signature = [text substringWithRange:[firstMatch rangeAtIndex:2]];
		signature = [signature stringByReplacingOccurrencesOfString:@"<?php\n" withString:@""];
		signature = [signature stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

		if(signature.length > 0)
			[combined appendAttributedString:[self syntaxHighlight:signature withGrammar:grammarScope]];

		NSMutableString* remaining = [text mutableCopy];
		for(NSTextCheckingResult* match in [codeMatches reverseObjectEnumerator])
			[remaining replaceCharactersInRange:[match rangeAtIndex:0] withString:@""];
		bodyText = [remaining stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
		bodyText = [bodyText stringByReplacingOccurrencesOfString:@"---" withString:@""];
		bodyText = [bodyText stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
	}

	if(bodyText.length > 0)
	{
		if(combined.length > 0)
			[combined appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n\n" attributes:@{}]];

		if(codeMatches.count == 0)
			[combined appendAttributedString:[self syntaxHighlight:bodyText withGrammar:grammarScope]];
		else
			[combined appendAttributedString:[self parseMarkdownToAttributedString:bodyText]];
	}

	return combined.length > 0 ? combined : nil;
}

- (OakTooltipContent*)createTooltipContentFromHover:(NSDictionary*)hover
{
	NSString* value = hover[@"value"];
	if(!value.length)
		return nil;

	if(value.length > 420)
		value = [[value substringToIndex:420] stringByAppendingString:@"\n... (truncated)"];

	NSString* kind = hover[@"kind"];
	NSString* language = hover[@"language"];
	BOOL isMarkdown = [kind isEqualToString:@"markdown"];

	NSAttributedString* title = nil;
	NSAttributedString* body = [[NSAttributedString alloc] initWithString:@""];

	if(isMarkdown)
	{
		NSArray* sections = [value componentsSeparatedByString:@"\n\n---\n\n"];
		if(sections.count > 1)
		{
			NSMutableArray* unique = [NSMutableArray new];
			NSMutableSet* seen = [NSMutableSet new];
			for(NSString* section in sections)
			{
				NSString* trimmed = [section stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
				if(trimmed.length > 0 && ![seen containsObject:trimmed])
				{
					[seen addObject:trimmed];
					[unique addObject:trimmed];
				}
			}
			value = [unique componentsJoinedByString:@"\n\n---\n\n"];
		}

		static NSRegularExpression* codeBlockRegex = [NSRegularExpression regularExpressionWithPattern:@"```(?:\\w+)?\\n([\\s\\S]*?)\\n```" options:0 error:nil];
		NSArray* codeMatches = [codeBlockRegex matchesInString:value options:0 range:NSMakeRange(0, value.length)];

		NSString* bodyText = value;
		if(codeMatches.count > 0)
		{
			NSTextCheckingResult* firstMatch = codeMatches[0];
			NSString* signature = [value substringWithRange:[firstMatch rangeAtIndex:1]];
			signature = [signature stringByReplacingOccurrencesOfString:@"<?php\n" withString:@""];
			signature = [signature stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

			NSString* grammarScope = documentView ? to_ns(documentView->file_type()) : nil;
			title = [self syntaxHighlight:signature withGrammar:grammarScope];

			NSMutableString* remaining = [value mutableCopy];
			for(NSTextCheckingResult* match in [codeMatches reverseObjectEnumerator])
				[remaining replaceCharactersInRange:[match rangeAtIndex:0] withString:@""];
			bodyText = [remaining stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
			bodyText = [bodyText stringByReplacingOccurrencesOfString:@"---" withString:@""];
			bodyText = [bodyText stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
		}

		if(bodyText.length > 0)
			body = [self parseMarkdownToAttributedString:bodyText];
	}
	else if(language)
	{
		NSString* grammarScope = documentView ? to_ns(documentView->file_type()) : nil;
		title = [self syntaxHighlight:value withGrammar:grammarScope];
	}
	else if(value.length > 0)
	{
		body = [[NSAttributedString alloc]
			initWithString:value
				attributes:@{NSFontAttributeName: [NSFont systemFontOfSize:11]}];
	}

	return [[OakTooltipContent alloc]
		initWithTitle:title
				 body:body
		  codeSnippet:nil
			 language:language];
}

- (void)showLSPHoverTooltip:(OakTooltipContent*)content atRect:(NSRect)viewRect
{
	if(!content)
		return;

	OakThemeEnvironment* theme = [self lspTheme];

	if(!_lspHoverTooltip)
	{
		_lspHoverTooltip = [[OakInfoTooltip alloc] initWithTheme:theme];
		_lspHoverTooltip.delegate = (id<OakInfoTooltipDelegate>)self;
	}

	[_lspHoverTooltip showIn:self at:viewRect content:content];
}


- (NSMutableAttributedString*)syntaxHighlight:(NSString*)code withGrammar:(NSString*)grammarScope
{
	if(!grammarScope || code.length == 0)
	{
		NSDictionary* attrs = @{
			NSFontAttributeName: [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightMedium],
			NSForegroundColorAttributeName: [NSColor labelColor]
		};
		return [[NSMutableAttributedString alloc] initWithString:code ?: @"" attributes:attrs];
	}

	parse::grammar_ptr grammar;
	for(auto const& bundleItem : bundles::query(bundles::kFieldGrammarScope, to_s(grammarScope), scope::wildcard, bundles::kItemTypeGrammar))
	{
		if((grammar = parse::parse_grammar(bundleItem)))
			break;
	}

	OakTheme* theme = nil;
	if(bundles::item_ptr const& themeItem = bundles::lookup(to_s(self.themeUUID)))
		theme = [[OakTheme alloc] initWithBundleItem:themeItem];

	BOOL isPhp = [grammarScope isEqualToString:@"text.html.php"];
	static NSString* const phpPrefix = @"<?php\n";
	NSString* parseCode = (isPhp && ![code hasPrefix:@"<?"]) ? [phpPrefix stringByAppendingString:code] : code;
	NSUInteger prefixLen = (parseCode != code) ? phpPrefix.length : 0;

	NSDictionary* baseAttrs = @{
		NSFontAttributeName: [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightMedium],
		NSForegroundColorAttributeName: theme.foregroundColor ?: [NSColor labelColor]
	};
	NSMutableAttributedString* styled = [[NSMutableAttributedString alloc] initWithString:parseCode attributes:baseAttrs];

	if(grammar && theme)
	{
		std::string str = to_s(parseCode);
		std::map<size_t, scope::scope_t> allScopes;
		parse::stack_ptr parserState = grammar->seed();

		for(std::string::size_type i = 0; i != str.size(); )
		{
			auto eol = str.find('\n', i);
			eol = eol != std::string::npos ? ++eol : str.size();

			std::string line = str.substr(i, eol - i);
			std::map<size_t, scope::scope_t> lineScopes;
			parserState = parse::parse(line.data(), line.data() + line.size(), parserState, lineScopes, i == 0);

			for(auto const& pair : lineScopes)
				allScopes[i + pair.first] = pair.second;

			i = eol;
		}

		size_t from = 0, pos = 0;
		for(auto pair = allScopes.begin(); pair != allScopes.end(); )
		{
			OakThemeStyles* styles = [theme stylesForScope:pair->second];
			size_t to = ++pair != allScopes.end() ? pair->first : str.size();
			size_t len = utf16::distance(str.data() + from, str.data() + to);

			NSMutableDictionary* attrs = [NSMutableDictionary dictionary];
			attrs[NSForegroundColorAttributeName] = styles.foregroundColor;
			if(![styles.backgroundColor isEqual:theme.backgroundColor])
				attrs[NSBackgroundColorAttributeName] = styles.backgroundColor;
			if(styles.fontTraits)
				[styled applyFontTraits:styles.fontTraits range:NSMakeRange(pos, len)];
			[styled addAttributes:attrs range:NSMakeRange(pos, len)];

			pos += len;
			from = to;
		}
	}

	if(prefixLen > 0)
		[styled deleteCharactersInRange:NSMakeRange(0, prefixLen)];

	return styled;
}

- (NSAttributedString*)parseMarkdownToAttributedString:(NSString*)markdown
{
	NSFont* baseFont = [NSFont systemFontOfSize:11];
	NSFont* boldFont = [NSFont boldSystemFontOfSize:11];
	NSFont* monoFont = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
	NSColor* textColor = [NSColor labelColor];
	NSColor* dimColor = [NSColor secondaryLabelColor];

	NSMutableAttributedString* result = [[NSMutableAttributedString alloc] init];
	NSDictionary* baseAttrs = @{NSFontAttributeName: baseFont, NSForegroundColorAttributeName: textColor};

	NSArray* lines = [markdown componentsSeparatedByString:@"\n"];
	BOOL firstLine = YES;

	for(NSString* rawLine in lines)
	{
		NSString* line = [rawLine stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];

		if(line.length == 0)
		{
			if(!firstLine && result.length > 0)
				[result appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n" attributes:baseAttrs]];
			continue;
		}

		static NSRegularExpression* symbolNameRegex = [NSRegularExpression regularExpressionWithPattern:@"^_{1,2}[a-zA-Z_$\\\\][a-zA-Z0-9_$:\\\\]*_{1,2}$" options:0 error:nil];
		if([symbolNameRegex numberOfMatchesInString:line options:0 range:NSMakeRange(0, line.length)] > 0)
			continue;

		if(!firstLine)
			[result appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n" attributes:baseAttrs]];
		firstLine = NO;

		NSMutableAttributedString* lineResult = [self parseInlineMarkdown:line
			baseFont:baseFont boldFont:boldFont monoFont:monoFont
			textColor:textColor dimColor:dimColor];

		[result appendAttributedString:lineResult];
	}

	NSCharacterSet* ws = [NSCharacterSet whitespaceAndNewlineCharacterSet];
	while(result.length > 0 && [ws characterIsMember:[result.string characterAtIndex:0]])
		[result deleteCharactersInRange:NSMakeRange(0, 1)];
	while(result.length > 0 && [ws characterIsMember:[result.string characterAtIndex:result.length - 1]])
		[result deleteCharactersInRange:NSMakeRange(result.length - 1, 1)];

	return result;
}

- (NSMutableAttributedString*)parseInlineMarkdown:(NSString*)text
	baseFont:(NSFont*)baseFont boldFont:(NSFont*)boldFont monoFont:(NSFont*)monoFont
	textColor:(NSColor*)textColor dimColor:(NSColor*)dimColor
{
	NSMutableAttributedString* result = [[NSMutableAttributedString alloc] init];
	NSDictionary* baseAttrs = @{NSFontAttributeName: baseFont, NSForegroundColorAttributeName: textColor};
	NSDictionary* boldAttrs = @{NSFontAttributeName: boldFont, NSForegroundColorAttributeName: textColor};
	NSDictionary* codeAttrs = @{NSFontAttributeName: monoFont, NSForegroundColorAttributeName: textColor};
	NSDictionary* dimAttrs  = @{NSFontAttributeName: baseFont, NSForegroundColorAttributeName: dimColor};

	NSMutableString* cleaned = [text mutableCopy];
	[cleaned replaceOccurrencesOfString:@"<b>" withString:@"**" options:0 range:NSMakeRange(0, cleaned.length)];
	[cleaned replaceOccurrencesOfString:@"</b>" withString:@"**" options:0 range:NSMakeRange(0, cleaned.length)];
	[cleaned replaceOccurrencesOfString:@"<i>" withString:@"*" options:0 range:NSMakeRange(0, cleaned.length)];
	[cleaned replaceOccurrencesOfString:@"</i>" withString:@"*" options:0 range:NSMakeRange(0, cleaned.length)];
	static NSRegularExpression* htmlTagRegex = [NSRegularExpression regularExpressionWithPattern:@"<[^>]+>" options:0 error:nil];
	cleaned = [[htmlTagRegex stringByReplacingMatchesInString:cleaned options:0 range:NSMakeRange(0, cleaned.length) withTemplate:@""] mutableCopy];

	NSUInteger i = 0;
	NSUInteger len = cleaned.length;

	while(i < len)
	{
		unichar ch = [cleaned characterAtIndex:i];

		if(ch == '`')
		{
			NSRange closeRange = [cleaned rangeOfString:@"`" options:0 range:NSMakeRange(i + 1, len - i - 1)];
			if(closeRange.location != NSNotFound)
			{
				NSString* code = [cleaned substringWithRange:NSMakeRange(i + 1, closeRange.location - i - 1)];
				[result appendAttributedString:[[NSAttributedString alloc] initWithString:code attributes:codeAttrs]];
				i = closeRange.location + 1;
				continue;
			}
		}

		if(ch == '*' && i + 1 < len && [cleaned characterAtIndex:i + 1] == '*')
		{
			NSRange closeRange = [cleaned rangeOfString:@"**" options:0 range:NSMakeRange(i + 2, len - i - 2)];
			if(closeRange.location != NSNotFound)
			{
				NSString* bold = [cleaned substringWithRange:NSMakeRange(i + 2, closeRange.location - i - 2)];
				[result appendAttributedString:[[NSAttributedString alloc] initWithString:bold attributes:boldAttrs]];
				i = closeRange.location + 2;
				continue;
			}
		}

		if(ch == '_' && i + 1 < len && [cleaned characterAtIndex:i + 1] != '_'
			&& (i == 0 || [[NSCharacterSet whitespaceCharacterSet] characterIsMember:[cleaned characterAtIndex:i - 1]]))
		{
			NSRange closeRange = [cleaned rangeOfString:@"_" options:0 range:NSMakeRange(i + 1, len - i - 1)];
			if(closeRange.location != NSNotFound
				&& (closeRange.location + 1 >= len || [[NSCharacterSet whitespaceAndNewlineCharacterSet] characterIsMember:[cleaned characterAtIndex:closeRange.location + 1]]))
			{
				NSString* italic = [cleaned substringWithRange:NSMakeRange(i + 1, closeRange.location - i - 1)];
				[result appendAttributedString:[[NSAttributedString alloc] initWithString:italic attributes:dimAttrs]];
				i = closeRange.location + 1;
				continue;
			}
		}

		[result appendAttributedString:[[NSAttributedString alloc]
			initWithString:[NSString stringWithCharacters:&ch length:1] attributes:baseAttrs]];
		i++;
	}

	return result;
}

- (void)cancelLSPHoverRequest
{
	[_lspHoverTimer invalidate];
	_lspHoverTimer = nil;

	if(_lspHoverRequestId != 0)
	{
		[[LSPManager sharedManager] cancelRequest:_lspHoverRequestId forDocument:self.document];
		_lspHoverRequestId = 0;
	}
}

- (void)infoTooltipDidDismiss:(OakInfoTooltip*)tooltip
{
}

@end
