// runLocation is a string with two values, but the Bundle Editor asks two
// yes/no questions of it: a checkbox binds to “does this run in the terminal”
// and the input/output controls bind their enabled state to its opposite.
extern NSString* const kOakRunsInTerminalTransformerName;
extern NSString* const kOakRunsInProcessTransformerName;

@interface OakRunLocationTransformer : NSValueTransformer
+ (void)register;
@end
