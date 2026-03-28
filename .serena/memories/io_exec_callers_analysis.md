# io::exec() and Callers - Comprehensive Analysis

## Implementation Details

**File:** `/Users/fenrir/code/textmate/Frameworks/io/src/exec.cc` (lines 97-152)

### Critical Issue: DISPATCH_TIME_FOREVER Wait
- Line 135: `dispatch_group_wait(group, DISPATCH_TIME_FOREVER);`
- This blocks the calling thread **indefinitely** waiting for:
  1. stdout exhaust (line 115-117)
  2. stderr exhaust (line 119-121)  
  3. waitpid() for subprocess completion (line 123-133)
- All three operations are dispatched to `dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0)` but the WAIT is synchronous

## Call Sites Summary

### 1. TerminalPreferences.mm - Line 269 (Main Thread - DANGEROUS)
**File:** `Frameworks/Preferences/src/TerminalPreferences.mm:269`
**Context:** `- (void)installMateAs:(NSString*)dstPath`
**Thread:** Main thread (UI handler)
**Call:** `io::exec(to_s(srcPath), "--version", NULL)`
**Risk:** **CRITICAL** - Blocks main thread, executed during UI response to user action
**Duration:** ~100ms for "mate --version"
**Trigger:** User changes terminal install path in preferences

### 2. TerminalPreferences.mm - Line 336 (Background - OK)
**File:** `Frameworks/Preferences/src/TerminalPreferences.mm:336`
**Context:** dispatch block inside `- (void)observeValueForKeyPath:ofObject:change:context:`
**Thread:** Background thread (DISPATCH_QUEUE_PRIORITY_LOW)
**Call:** `io::exec(to_s(newMate), "--version", NULL)`
**Risk:** LOW - On background queue via `dispatch_async(dispatch_get_global_queue(...))`
**Duration:** ~100ms

### 3. authorization/server.mm - Line 44 (Unknown Thread - NEEDS INVESTIGATION)
**File:** `Frameworks/authorization/src/server.mm:44`
**Context:** `static double version_of_tool(std::string const& toolPath)`
**Thread:** Called from:
  - `connect_to_auth_server()` (line 62) called from file save/open handlers
  - `version_of_tool()` called from `auth_server_too_old()` (line 50-60)
**Call:** `io::exec(toolPath, "--version", nullptr)`
**Risk:** **HIGH** - Called during file open/save which likely happens on main thread
**Duration:** ~100ms per call (called twice: old and new versions)

### 4. OakSystem/application.cc - Line 99 (Unknown Thread - LIKELY MAIN)
**File:** `Frameworks/OakSystem/src/application.cc:99`
**Context:** `void application_t::relaunch(char const* args)`
**Thread:** Unknown (application relaunching)
**Call:** `io::exec("/bin/sh", "-c", script.c_str(), appPath.c_str(), args, nullptr)`
**Risk:** **MEDIUM** - Likely called from main thread during app lifecycle
**Duration:** Variable - launches shell, kills old process, waits for startup
**Note:** Script involves `kill` and `ps` with sleep loops - could take seconds

### 5. scm/drivers/git.cc - Lines 118, 124, 128, 129, 132, 136, 140 (Background)
**File:** `Frameworks/scm/src/drivers/git.cc`
**Context:** `collect_all_paths()` (line 110) and `variables()` (line 246)
**Call Sites:**
  - Line 118: `io::exec(env, git, "show-ref", "-qh", nullptr)`
  - Line 124: `io::exec(env, git, "update-index", ...)`
  - Line 128: `io::exec(env, git, "ls-files", ...)`
  - Line 129: `io::exec(env, git, "ls-files", ...)`
  - Line 132: `io::exec(env, git, "diff-files", ...)`
  - Line 136: `io::exec(env, git, "diff-index", ...)`
  - Line 140: `io::exec(env, git, "ls-files", ...)`
  - Line 255: `io::exec(env, executable(), "show-ref", "-qh", nullptr)` (variables method)
  - Line 258: `io::exec(env, executable(), "symbolic-ref", "HEAD", nullptr)` (variables method)
**Thread:** Background - via dispatch queue
  - Called from `shared_info_t::async_update()` (line 189-214 in scm.cc)
  - Dispatched at line 234: `dispatch_after(_no_check_before, queue, ^{...})` on serial queue
  - Also called from tests on unknown thread
**Risk:** **MEDIUM** - Multiple sequential git commands (7+ per status check)
**Duration:** 100ms-1000ms+ depending on repo size
**Concurrency:** Serial queue per repo, but multiple calls in sequence

### 6. scm/drivers/svn.cc - Lines 76, 112 (Background)
**File:** `Frameworks/scm/src/drivers/svn.cc`
**Context:** `collect_all_paths()` (line 72) and `variables()` (line 109)
**Calls:**
  - Line 76: `io::exec("/bin/sh", "-c", cmd.c_str(), nullptr)` (piped with xsltproc)
  - Line 112: `io::exec(executable(), "info", wcPath.c_str(), nullptr)`
**Thread:** Background via dispatch queue (same as git)
**Risk:** **MEDIUM** - SVN operations can be slower
**Duration:** 200ms-2000ms+

### 7. scm/drivers/hg.cc - Lines 48, 64 (Background)
**File:** `Frameworks/scm/src/drivers/hg.cc`
**Context:** `collect_all_paths()` (line 45) and `variables()` (line 59)
**Calls:**
  - Line 48: `io::exec(hg, "status", "--cwd", dir.c_str(), "--all", "-0", nullptr)`
  - Line 64: `io::exec(executable(), "branch", "--cwd", wcPath.c_str(), nullptr)`
**Thread:** Background via dispatch queue
**Risk:** **MEDIUM**
**Duration:** 100ms-500ms

### 8. scm/drivers/api.cc - Line 44 (Unknown Thread)
**File:** `Frameworks/scm/src/drivers/api.cc:44`
**Context:** `find_executable()` validation
**Call:** `io::exec("/usr/bin/xcode-select", "-p", nullptr)`
**Thread:** Unknown (called during driver initialization)
**Risk:** **MEDIUM**
**Duration:** ~50ms

### 9. CommitWindow.mm - Line 702 (Background)
**File:** `Frameworks/CommitWindow/src/CommitWindow.mm:702`
**Context:** diff command display
**Call:** `io::exec(_environment, "/bin/sh", "-c", cmdString.c_str(), NULL)`
**Thread:** Background via `dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0))`
**Risk:** LOW - Already on background
**Duration:** Variable - runs diff command

### 10. CommitWindow.mm - Line 758 (Main Thread - DANGEROUS)
**File:** `Frameworks/CommitWindow/src/CommitWindow.mm:758`
**Context:** Inside `- (void)displayStatus:(id)sender` method (line 750+)
**Call:** `io::exec(_environment, "/bin/sh", "-c", cmdString.c_str(), NULL)`
**Risk:** **CRITICAL** - Direct main thread execution
**Duration:** Variable (custom status command)
**Trigger:** User clicks status display in commit window

### 11. Test Files (Lines 20, 14, 17)
**Files:** `Frameworks/scm/tests/t_svn.cc`, `t_git.cc`, `t_hg.cc`
**Thread:** Test thread (likely main)
**Risk:** LOW - Tests only
**Duration:** Variable

## Summary of Risks

### CRITICAL (Main Thread Deadlock Risk):
1. TerminalPreferences.mm:269 - Preferences UI handler
2. CommitWindow.mm:758 - Commit window status display

### HIGH (File I/O Blocking):
1. authorization/server.mm:44 - File open/save handlers (likely main thread)

### MEDIUM (Background But Multiple Calls):
1. All SCM driver status checks - Multiple sequential git/svn/hg commands per update
2. OakSystem/application.cc:99 - App relaunch (likely main thread)
3. scm/drivers/api.cc:44 - Driver initialization

### LOW (Already On Background):
1. TerminalPreferences.mm:336 - Already on background queue
2. CommitWindow.mm:702 - Already on background queue
