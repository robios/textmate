#import "FileItem.h"
#import "SCMManager.h"
#import <OakAppKit/NSImage Additions.h>
#import <scm/git_query.h>
#import <io/path.h>
#import <ns/ns.h>

// ==========================
// = Review-base URL helpers =
// ==========================
// The window's review base (Phase E) rides on the scm:// URLs as a
// `reviewBaseSpec` query item — a git revspec or sha. When present on the
// unstaged section, that section lists `git diff --name-status <spec>`
// against the base instead of the driver's working-tree status.

static NSString* ReviewBaseSpecFromURL (NSURL* url)
{
	NSURLComponents* components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
	for(NSURLQueryItem* item in components.queryItems)
	{
		if([item.name isEqualToString:@"reviewBaseSpec"])
			return item.value.length ? item.value : nil;
	}
	return nil;
}

static NSString* DisplayNameForBaseSpec (NSString* baseSpec)
{
	// A pinned commit rides as its full sha; abbreviate it the way git
	// does. A relative spec (HEAD~1) is already short and readable, so it
	// shows verbatim.
	if(baseSpec.length == 40)
	{
		BOOL allHex = YES;
		for(NSUInteger i = 0; allHex && i < baseSpec.length; ++i)
		{
			unichar c = [baseSpec characterAtIndex:i];
			allHex = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
		}
		if(allHex)
			return [baseSpec substringToIndex:7];
	}
	return baseSpec;
}

// The base a section is actually listing against: the requested spec
// resolved against the current HEAD, or nil when the spec resolves to
// nothing or to HEAD and the section has fallen back to the plain
// working-tree listing. Written by the section observer the moment before
// it delivers children — so the item's name, re-queried on that same
// delivery, reads the fresh value and title and listing never disagree —
// and read by -localizedName. Keyed by the section URL string, which the
// observer and the item share (an scm:// item's resolvedURL is its URL),
// and cleared when the shared observer is torn down.
static NSMutableDictionary<NSString*, NSString*>* EffectiveBaseBySectionURL ()
{
	static NSMutableDictionary<NSString*, NSString*>* dict = [NSMutableDictionary dictionary];
	return dict;
}

static NSString* EffectiveBaseForSectionURL (NSURL* url)
{
	return url ? EffectiveBaseBySectionURL()[url.absoluteString] : nil;
}

static void SetEffectiveBaseForSectionURL (NSURL* url, NSString* effectiveRef)
{
	if(!url)
		return;
	if(effectiveRef)
			EffectiveBaseBySectionURL()[url.absoluteString] = effectiveRef;
	else	[EffectiveBaseBySectionURL() removeObjectForKey:url.absoluteString];
}

// ================
// = SCM Observer =
// ================

@interface SCMStatusObserver : NSObject
{
	id _scmObserver;
	NSURL* _baseSectionURL; // the base-relative section's URL, whose effective-base entry we own
}
@end

@implementation SCMStatusObserver
- (instancetype)initWithURL:(NSURL*)url usingBlock:(void(^)(NSArray<NSURL*>*))handler
{
	if(self = [super init])
	{
		NSURL* repositoryURL = [NSURL fileURLWithPath:url.path isDirectory:YES];
		if([url.query hasSuffix:@"unstaged"])
		{
			NSString* baseSpec = ReviewBaseSpecFromURL(url);
			if(!baseSpec)
			{
				// No review base: the driver's working-tree status, as always.
				_scmObserver = [SCMManager.sharedInstance addObserverToRepositoryAtURL:repositoryURL usingBlock:^(SCMRepository* repository){
					handler([SCMStatusObserver unstagedURLsInRepository:repository]);
				}];
			}
			else
			{
				// A review base: resolve the requested spec against the CURRENT
				// HEAD on every SCM update — so the section follows HEAD, and
				// falls back to the working-tree listing (never an empty,
				// mislabeled one) the moment the spec resolves to nothing or to
				// HEAD. git runs off a serial queue and returns on the main
				// queue in order; the effective base is published for
				// -localizedName just before the children, so the section's
				// title and its rows never disagree.
				_baseSectionURL = url;
				dispatch_queue_t baseDiffQueue = dispatch_queue_create("org.textmate.scm-status.base-diff", DISPATCH_QUEUE_SERIAL);
				NSURL* sectionURL = url;
				__weak SCMStatusObserver* weakSelf = self;
				_scmObserver = [SCMManager.sharedInstance addObserverToRepositoryAtURL:repositoryURL usingBlock:^(SCMRepository* repository){
					// Read what the work needs off the repository here, on the
					// main queue — including the fallback listing — then compute
					// without touching it again.
					NSString* repositoryRoot  = repository.URL.path;
					BOOL tracksDirectories    = repository.tracksDirectories;
					NSArray<NSURL*>* headURLs  = [SCMStatusObserver unstagedURLsInRepository:repository];
					dispatch_async(baseDiffQueue, ^{
						std::string const effective = scm::git_query::effective_base(to_s(repositoryRoot), to_s(baseSpec));
						NSString* effectiveRef      = effective != NULL_STR ? to_ns(effective) : nil;
						NSArray<NSURL*>* urls        = effectiveRef ? [SCMStatusObserver changedURLsForRepositoryRoot:repositoryRoot baseRef:effectiveRef tracksDirectories:tracksDirectories] : headURLs;
						dispatch_async(dispatch_get_main_queue(), ^{
							// A background query outlives the observer that started
							// it — a late-returning one must not resurrect the map
							// entry `dealloc` cleared, nor overwrite the entry a new
							// observer for the same URL has since published (its own
							// serial queue can finish first). The observer owns one
							// section URL for its whole life, and the tree keeps one
							// observer per URL, so "still alive" is also "still owns
							// this URL": if it is gone, drop both the map write and
							// the children.
							if(!weakSelf)
								return;
							SetEffectiveBaseForSectionURL(sectionURL, effectiveRef);
							handler(urls);
						});
					});
				}];
			}
		}
		else if([url.query hasSuffix:@"untracked"])
		{
			_scmObserver = [SCMManager.sharedInstance addObserverToRepositoryAtURL:repositoryURL usingBlock:^(SCMRepository* repository){
				handler([SCMStatusObserver untrackedURLsInRepository:repository]);
			}];
		}
		else if(SCMRepository* repository = [SCMManager.sharedInstance repositoryAtURL:repositoryURL])
		{
			if(repository.enabled)
			{
				// The review base, if any, rides on BOTH section URLs — kept
				// last in the query so the `hasSuffix` tests below still
				// hold, and so both sections share the one parent URL. Only
				// the unstaged section reads it; untracked is base-independent.
				NSString* encodedRoot = [repository.URL.path stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet];
				NSString* basePrefix  = @"";
				if(NSString* baseSpec = ReviewBaseSpecFromURL(url))
					basePrefix = [NSString stringWithFormat:@"reviewBaseSpec=%@&", [baseSpec stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet]];

				handler(@[
					[NSURL URLWithString:[NSString stringWithFormat:@"scm://localhost%@/?%@show=unstaged", encodedRoot, basePrefix]],
					[NSURL URLWithString:[NSString stringWithFormat:@"scm://localhost%@/?%@show=untracked", encodedRoot, basePrefix]],
				]);
			}
		}
	}
	return self;
}

- (void)dealloc
{
	if(_scmObserver)
		[SCMManager.sharedInstance removeObserver:_scmObserver];
	if(_baseSectionURL)
		SetEffectiveBaseForSectionURL(_baseSectionURL, nil);
}

+ (NSArray<NSURL*>*)unstagedURLsInRepository:(SCMRepository*)repository
{
	std::map<std::string, scm::status::type> unstagedPaths;
	for(auto const& pair : repository.status)
	{
		if(pair.second & (scm::status::modified|scm::status::added|scm::status::deleted|scm::status::conflicted|scm::status::unversioned))
		{
			if(!(pair.second & scm::status::unversioned))
				unstagedPaths.insert(pair);
		}
	}

	if(!repository.tracksDirectories)
	{
		std::vector<std::string> parents;

		std::string child = NULL_STR;
		for(auto it = unstagedPaths.rbegin(); it != unstagedPaths.rend(); ++it)
		{
			if(path::is_child(child, it->first))
					parents.push_back(it->first);
			else	child = it->first;
		}

		for(auto const& path : parents)
			unstagedPaths.erase(path);
	}

	NSMutableArray<NSURL*>* res = [NSMutableArray array];
	for(auto const& pair : unstagedPaths)
		[res addObject:[NSURL fileURLWithPath:to_ns(pair.first)]];
	return res;
}

+ (NSArray<NSURL*>*)untrackedURLsInRepository:(SCMRepository*)repository
{
	std::map<std::string, scm::status::type> untrackedPaths;
	for(auto pair : repository.status)
	{
		if(pair.second & (scm::status::modified|scm::status::added|scm::status::deleted|scm::status::conflicted|scm::status::unversioned))
		{
			if(pair.second & scm::status::unversioned)
				untrackedPaths.insert(pair);
		}
	}

	if(!repository.tracksDirectories)
	{
		std::vector<std::string> children;

		std::string parent = NULL_STR;
		for(auto const& pair : untrackedPaths)
		{
			if(path::is_child(pair.first, parent))
				children.push_back(pair.first);
			else	parent = pair.first;
		}

		for(auto const& path : children)
			untrackedPaths.erase(path);
	}

	NSMutableArray<NSURL*>* res = [NSMutableArray array];
	for(auto const& pair : untrackedPaths)
	{
		NSURL* url = [NSURL fileURLWithPath:to_ns(pair.first)];
		[url setTemporaryResourceValue:@YES forKey:@"org.textmate.disable-scm-status"];
		[res addObject:url];
	}
	return res;
}

+ (NSArray<NSURL*>*)changedURLsForRepositoryRoot:(NSString*)repositoryRoot baseRef:(NSString*)baseRef tracksDirectories:(BOOL)tracksDirectories
{
	std::map<std::string, scm::status::type> changedPaths = scm::git_query::changed_paths_since(to_s(repositoryRoot), to_s(baseRef));

	// Every entry already differs from the base by construction, so there is
	// nothing to filter. The parent/child collapsing below mirrors the
	// unstaged listing for symmetry, but cannot actually fire here: git
	// tracks files, so `git diff --name-status` never names a directory,
	// whereas the driver's status map the unstaged listing reads can.
	if(!tracksDirectories)
	{
		std::vector<std::string> parents;

		std::string child = NULL_STR;
		for(auto it = changedPaths.rbegin(); it != changedPaths.rend(); ++it)
		{
			if(path::is_child(child, it->first))
					parents.push_back(it->first);
			else	child = it->first;
		}

		for(auto const& path : parents)
			changedPaths.erase(path);
	}

	// Bare file URLs, like the unstaged listing: the M/A/D badge a row shows
	// still comes from the driver's working-tree status, not from the
	// base-relative status computed above, so a file that differs from the
	// base only through commits made since it (clean working tree) lists
	// here without a badge. Correct membership, driver-coloured decoration;
	// a base-relative badge is a deferred refinement.
	NSMutableArray<NSURL*>* res = [NSMutableArray array];
	for(auto const& pair : changedPaths)
		[res addObject:[NSURL fileURLWithPath:to_ns(pair.first)]];
	return res;
}
@end

// ===================
// = SCM Data Source =
// ===================

@interface SCMStatusFileItem : FileItem
{
	SCMRepository* _repository;
	id _observer;
}
@end

@implementation SCMStatusFileItem
+ (void)load
{
	[self registerClass:self forURLScheme:@"scm"];
}

+ (id)makeObserverForURL:(NSURL*)url usingBlock:(void(^)(NSArray<NSURL*>*))handler
{
	return [[SCMStatusObserver alloc] initWithURL:url usingBlock:handler];
}

- (instancetype)initWithURL:(NSURL*)url
{
	if(self = [super initWithURL:url])
	{
		_repository = [SCMManager.sharedInstance repositoryAtURL:[NSURL fileURLWithPath:url.path isDirectory:YES]];
		if(_repository && _repository.enabled == NO)
		{
			self.disambiguationSuffix = @" (disabled)";
		}
		else if(![self.URL.query hasSuffix:@"unstaged"] && ![self.URL.query hasSuffix:@"untracked"])
		{
			if(_repository)
			{
				__weak SCMStatusFileItem* weakSelf = self;
				_observer = [SCMManager.sharedInstance addObserverToRepositoryAtURL:_repository.URL usingBlock:^(SCMRepository* repository){
					[weakSelf updateBranchName];
				}];
			}
			else
			{
				self.disambiguationSuffix = @" (no status)";
			}
		}
	}
	return self;
}

- (void)dealloc
{
	[SCMManager.sharedInstance removeObserver:_observer];
}

- (void)updateBranchName
{
	if(_repository)
	{
		NSString* branch = _repository.variables[@"TM_SCM_BRANCH"];
		self.disambiguationSuffix = branch ? [NSString stringWithFormat:@" (%@)", branch] : @"";
	}
}

- (NSString*)localizedName
{
	if([self.URL.query hasSuffix:@"unstaged"])
	{
		// The base the section actually resolved to, not the requested spec:
		// when the spec resolves to nothing or to HEAD the section falls back
		// to the working-tree listing, and the title says so rather than
		// naming a base the rows are not against.
		if(ReviewBaseSpecFromURL(self.URL))
		{
			if(NSString* effectiveRef = EffectiveBaseForSectionURL(self.URL))
				return [NSString stringWithFormat:@"Changes since %@", DisplayNameForBaseSpec(effectiveRef)];
		}
		return @"Uncommitted Changes";
	}
	else if([self.URL.query hasSuffix:@"untracked"])
		return @"Untracked Items";
	else if(_repository)
		return [NSFileManager.defaultManager displayNameAtPath:_repository.URL.path];

	return super.localizedName;
}

- (NSURL*)parentURL
{
	if([self.URL.query hasSuffix:@"unstaged"] || [self.URL.query hasSuffix:@"untracked"])
	{
		// Reconstruct the section's parent — the repository root node —
		// carrying the review base, so both sections resolve to the one
		// base-bearing root rather than to a bare one it would not match.
		NSString* encodedRoot = [self.URL.path stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet];
		if(NSString* baseSpec = ReviewBaseSpecFromURL(self.URL))
			return [NSURL URLWithString:[NSString stringWithFormat:@"scm://localhost%@/?reviewBaseSpec=%@", encodedRoot, [baseSpec stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet]]];
		return [NSURL URLWithString:[NSString stringWithFormat:@"scm://localhost%@/", encodedRoot]];
	}
	return [NSURL fileURLWithPath:self.URL.path];
}
@end
