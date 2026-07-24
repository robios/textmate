#import <Cocoa/Cocoa.h>

// Posted when the base changes; the notification object is the sender.
extern NSNotificationName const OakReviewBaseDidChangeNotification;

// How a base names the commit it means. Kept apart from the commit it
// resolves to, because the two differ for the relative case and a bare
// ref string cannot express that: `HEAD~1` names a different commit
// after every commit, so it must never be what the blob cache is keyed
// by, nor what a revert label promises to restore.
typedef NS_ENUM(NSInteger, OakReviewBaseKind) {
	OakReviewBaseKindHead = 0, // whatever HEAD is now — the default
	OakReviewBaseKindCommit,   // one commit, pinned; HEAD moving does not move it
	OakReviewBaseKindRelative, // a spec resolved afresh as HEAD moves
};

// The window's review base: the one commit every git-aware surface in
// the window compares against. The diff pane, the gutter's change bars,
// the minimap marks and the status-bar display all read it, so they
// agree on what "changed" means rather than each carrying a comparison
// of its own.
//
// One per window, owned above the views that render it — a document view
// can come and go, the base the reader picked should not. It is
// deliberately not persisted: a base other than HEAD is a temporary act
// of review, and restoring one on relaunch would quietly misrepresent
// what is uncommitted.
//
// This object holds the reader's *choice*. What that choice resolves to
// is decided per recompute against the repository the document is
// actually in, and reported on the diff snapshot — so a spec that names
// nothing (`HEAD~1` in a repo with one commit) shows up everywhere as
// the HEAD it falls back to, rather than as a promise nothing keeps.
@interface OakReviewBase : NSObject
@property (nonatomic, readonly) OakReviewBaseKind kind;

// The chosen commit for Commit, the revspec for Relative, nil for Head.
@property (nonatomic, readonly) NSString* spec;

// The repository a pinned commit was chosen in — a sha means nothing
// outside it. nil for the other kinds: HEAD and a relative spec resolve
// in whatever repository the document belongs to, so they travel.
@property (nonatomic, readonly) NSString* repoRoot;

// The mutators, one per kind, so a kind can never disagree with the spec
// beside it and there is one place the change is announced.
- (void)resetToHead;
- (void)setCommit:(NSString*)aSha inRepoRoot:(NSString*)aRepoRoot;
- (void)setRelativeSpec:(NSString*)aSpec;

// A sha abbreviated the way a git front end abbreviates one. Shared so a
// base named in the status bar and the same base named on a button
// beside it cannot disagree about how much of the sha to show.
+ (NSString*)shortNameForRef:(NSString*)aRef;

// How a base names itself to a reader: "HEAD", an abbreviated sha, or a
// relative spec together with the commit it currently stands for —
// which is the part that answers "so what am I actually looking at".
+ (NSString*)displayNameForKind:(OakReviewBaseKind)aKind spec:(NSString*)aSpec resolvedRef:(NSString*)aResolvedRef;
@end
