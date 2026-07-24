#import "OakReviewBase.h"

NSNotificationName const OakReviewBaseDidChangeNotification = @"OakReviewBaseDidChangeNotification";

@implementation OakReviewBase
- (void)resetToHead
{
	[self setKind:OakReviewBaseKindHead spec:nil repoRoot:nil];
}

- (void)setCommit:(NSString*)aSha inRepoRoot:(NSString*)aRepoRoot
{
	if(!aSha.length)
		return [self resetToHead];
	[self setKind:OakReviewBaseKindCommit spec:aSha repoRoot:aRepoRoot];
}

- (void)setRelativeSpec:(NSString*)aSpec
{
	if(!aSpec.length)
		return [self resetToHead];
	[self setKind:OakReviewBaseKindRelative spec:aSpec repoRoot:nil];
}

- (void)setKind:(OakReviewBaseKind)aKind spec:(NSString*)aSpec repoRoot:(NSString*)aRepoRoot
{
	if(_kind == aKind && (_spec == aSpec || [_spec isEqualToString:aSpec]) && (_repoRoot == aRepoRoot || [_repoRoot isEqualToString:aRepoRoot]))
		return;

	_kind     = aKind;
	_spec     = [aSpec copy];
	_repoRoot = [aRepoRoot copy];

	[NSNotificationCenter.defaultCenter postNotificationName:OakReviewBaseDidChangeNotification object:self];
}

+ (NSString*)shortNameForRef:(NSString*)aRef
{
	return aRef.length > 10 ? [aRef substringToIndex:10] : aRef;
}

+ (NSString*)displayNameForKind:(OakReviewBaseKind)aKind spec:(NSString*)aSpec resolvedRef:(NSString*)aResolvedRef
{
	switch(aKind)
	{
		case OakReviewBaseKindRelative:
			// The spec is the point — it is why the base keeps moving —
			// but on its own it does not say which commit that is today.
			return [NSString stringWithFormat:@"%@ (%@)", aSpec, [self shortNameForRef:aResolvedRef]];

		case OakReviewBaseKindCommit:
			return [self shortNameForRef:aResolvedRef];

		case OakReviewBaseKindHead:
			break;
	}
	return @"HEAD";
}
@end
