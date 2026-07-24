#include "fs_events.h"
#include <io/path.h>
#include <cf/cf.h>

namespace scm
{
	bool is_transient_git_path (std::string const& path)
	{
		std::string::size_type git = path.find("/.git/");
		if(git == std::string::npos)
			return false;

		std::string const rel = path.substr(git + 6);
		std::string const name = path::name(rel);

		return path::extension(rel) == ".lock" || name.compare(0, 18, "fsmonitor--daemon.") == 0;
	}

	namespace
	{
		std::string chomp (std::string s)
		{
			while(!s.empty() && (s.back() == '\n' || s.back() == '\r'))
				s.pop_back();
			return s;
		}
	}

	std::string git_metadata_dir (std::string const& worktree_root)
	{
		std::string const dotGit = path::join(worktree_root, ".git");
		if(path::is_directory(dotGit))
			return dotGit;
		if(!path::exists(dotGit))
			return NULL_STR;

		// A `.git` file names the real directory: `gitdir: <path>`, which
		// may be written relative to the worktree.
		static std::string const kGitDirPrefix = "gitdir: ";
		std::string const contents = chomp(path::content(dotGit));
		if(contents == NULL_STR || contents.compare(0, kGitDirPrefix.size(), kGitDirPrefix) != 0)
			return NULL_STR;

		std::string gitDir = contents.substr(kGitDirPrefix.size());
		if(!path::is_absolute(gitDir))
			gitDir = path::join(worktree_root, gitDir);

		// `commondir` names the shared directory, written relative to the
		// one above. Its absence means this IS the common directory.
		std::string const commonDir = chomp(path::content(path::join(gitDir, "commondir")));
		if(commonDir == NULL_STR || commonDir.empty())
			return gitDir;

		return path::is_absolute(commonDir) ? path::normalize(commonDir) : path::join(gitDir, commonDir);
	}

	std::string fs_event_path (std::string const& path)
	{
		struct statfs buf;
		if(statfs(path.c_str(), &buf) != 0)
			return path;

		// The same two steps watcher_t takes: a path is handed to FSEvents
		// relative to its device, and comes back joined onto the mount
		// point. For a firmlinked path the first step is a no-op, so the
		// second one prefixes it.
		std::string const mountPoint = buf.f_mntonname;
		return path::join(mountPoint, "./" + path::relative_to(path, mountPoint));
	}

	bool is_repo_meta_path (std::string const& metadata_dir, std::string const& path)
	{
		if(metadata_dir == NULL_STR || metadata_dir.empty())
			return false;

		std::string rel = path::relative_to(path, metadata_dir);
		if(rel.empty())
			return true; // the metadata directory itself, which holds HEAD and the index
		if(rel == path || rel.compare(0, 2, "..") == 0)
			return false; // not below it

		// A linked worktree's own HEAD and index sit one level in, under
		// `worktrees/<name>/`, beside the refs every worktree shares. A
		// submodule needs no such step: the watcher is pointed straight at
		// its metadata directory, so `modules/…` never reaches here.
		static std::string const kWorktreesPrefix = "worktrees/";
		if(rel.compare(0, kWorktreesPrefix.size(), kWorktreesPrefix) == 0)
		{
			auto const slash = rel.find('/', kWorktreesPrefix.size());
			if(slash == std::string::npos)
				return true; // that worktree's own directory, holding its HEAD and index
			rel = rel.substr(slash + 1);
		}

		return rel == "HEAD"
		    || rel == "index"
		    || rel == "packed-refs"
		    || rel == "refs"
		    || rel == "refs/heads"
		    || rel.compare(0, 11, "refs/heads/") == 0;
	}

	// =============
	// = watcher_t =
	// =============

	watcher_t::watcher_t (std::string const& path, std::function<void(std::set<std::string> const&)> const& callback) : path(path), callback(callback), stream(nullptr)
	{
		struct statfs buf;
		if(statfs(path.c_str(), &buf) != 0)
			return;

		mount_point            = buf.f_mntonname;
		dev_t device           = buf.f_fsid.val[0];
		std::string devicePath = path::relative_to(path, mount_point);

		FSEventStreamContext contextInfo = { 0, this, nullptr, nullptr, nullptr };
		if(stream = FSEventStreamCreateRelativeToDevice(kCFAllocatorDefault, &callback_function, &contextInfo, device, cf::wrap(std::vector<std::string>(1, devicePath)), kFSEventStreamEventIdSinceNow, 1, kFSEventStreamCreateFlagNone))
		{
			FSEventStreamScheduleWithRunLoop(stream, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
			FSEventStreamStart(stream);
		}
		else
		{
			os_log_error(OS_LOG_DEFAULT, "Can’t observe ‘%{public}s’", path.c_str());
		}
	}

	watcher_t::~watcher_t ()
	{
		if(!stream)
			return;

		FSEventStreamStop(stream);
		FSEventStreamInvalidate(stream);
		FSEventStreamRelease(stream);
	}

	void watcher_t::invoke_callback (std::set<std::string> const& changedPaths)
	{
		callback(changedPaths);
	}

	void watcher_t::callback_function (ConstFSEventStreamRef streamRef, void* clientCallBackInfo, size_t numEvents, void* eventPaths, FSEventStreamEventFlags const eventFlags[], FSEventStreamEventId const eventIds[])
	{
		watcher_t& watcher = *(watcher_t*)clientCallBackInfo;

		std::set<std::string> changedPaths;

		for(size_t i = 0; i < numEvents; ++i)
		{
			std::string const& file = ((char const* const*)eventPaths)[i];
			std::string const& path = path::join(watcher.mount_point, "./" + file);
			if(!is_transient_git_path(path))
				changedPaths.insert(path);
		}
		if(!changedPaths.empty())
			watcher.invoke_callback(changedPaths);
	}
}
