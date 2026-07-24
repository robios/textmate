#ifndef FS_EVENTS_H_QDH73MIO
#define FS_EVENTS_H_QDH73MIO

namespace scm
{
	bool is_transient_git_path (std::string const& path);

	// The directory a git worktree keeps its metadata in. Usually
	// <root>/.git — but a linked worktree and a submodule each have a
	// `.git` FILE pointing elsewhere, and then HEAD, the index and the
	// refs all live outside the worktree, where nothing watching the
	// worktree can see them change.
	//
	// For a linked worktree this is the COMMON directory, which holds the
	// shared refs and also contains that worktree's own HEAD and index
	// under `worktrees/<name>/`, so watching this one path covers both.
	// For a submodule it is <superproject>/.git/modules/<name>, which
	// holds everything that submodule has. NULL_STR when there is no git
	// metadata to find.
	std::string git_metadata_dir (std::string const& worktree_root);

	// A path as FSEvents will report it, which is not always how it was
	// spelled: a volume's paths come back through its mount point, so
	// anything reached by a firmlink — /Users, /private — arrives prefixed
	// with /System/Volumes/Data. Needed to compare a watched directory
	// against the events it produces.
	std::string fs_event_path (std::string const& path);

	// Does this path name git metadata whose change alters what a diff
	// against HEAD or the index means? Judged RELATIVE to the metadata
	// directory being watched (in event space, per the above) rather than
	// by the shape of the path alone.
	//
	// That is what makes a submodule at `vendor/lib` work: its metadata
	// root IS <super>/.git/modules/vendor/lib, so nothing has to guess
	// where a multi-component submodule name ends — which is not decidable
	// from the path, since `modules/vendor/lib/HEAD` and
	// `modules/a/modules/b/HEAD` are the same shape and mean different
	// things.
	//
	// Note also that events are DIRECTORY-granular: a commit arrives as
	// `<meta>/refs/heads`, never as the ref it moved.
	bool is_repo_meta_path (std::string const& metadata_dir, std::string const& path);

	struct watcher_t
	{
		watcher_t (std::string const& path, std::function<void(std::set<std::string> const&)> const& callback);
		~watcher_t ();

	private:
		static void callback_function (ConstFSEventStreamRef streamRef, void* clientCallBackInfo, size_t numEvents, void* eventPaths, FSEventStreamEventFlags const eventFlags[], FSEventStreamEventId const eventIds[]);
		void invoke_callback (std::set<std::string> const& changedPaths);

		std::string path;
		std::function<void(std::set<std::string> const&)> callback;

		std::string mount_point;
		FSEventStreamRef stream;
	};

} /* scm */

#endif /* end of include guard: FS_EVENTS_H_QDH73MIO */
