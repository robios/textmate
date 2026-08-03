#import "OakRunLocationTransformer.h"

NSString* const kOakRunsInTerminalTransformerName = @"OakRunsInTerminalTransformer";
NSString* const kOakRunsInProcessTransformerName  = @"OakRunsInProcessTransformer";

@interface OakRunLocationTransformer ()
@property (nonatomic) BOOL answersForTerminal;
@end

@implementation OakRunLocationTransformer
+ (Class)transformedValueClass      { return [NSNumber class]; }
+ (BOOL)allowsReverseTransformation { return YES; }

+ (void)register
{
	for(NSString* name in @[ kOakRunsInTerminalTransformerName, kOakRunsInProcessTransformerName ])
	{
		if([NSValueTransformer valueTransformerForName:name])
			continue;

		OakRunLocationTransformer* transformer = [OakRunLocationTransformer new];
		transformer.answersForTerminal = [name isEqualToString:kOakRunsInTerminalTransformerName];
		[NSValueTransformer setValueTransformer:transformer forName:name];
	}
}

// A command that never mentioned runLocation runs in process, so an absent
// value is not “no answer” here — it is the default answered in full. Anything
// that is not the one string answers the same way, including whatever a
// hand-edited plist put under the key: the parser type-checks it and runs the
// command in process, and the editor must not be the one that falls over.
- (NSNumber*)transformedValue:(id)value
{
	return @([value isEqual:@"terminal"] == _answersForTerminal);
}

// Written back as the parser’s own spelling of the default rather than by
// removing the key: the editor’s other popups leave their defaults in the
// plist too, and an explicit inProcess says what the item was asked for.
- (NSString*)reverseTransformedValue:(NSNumber*)value
{
	return [value boolValue] == _answersForTerminal ? @"terminal" : @"inProcess";
}
@end
