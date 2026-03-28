# Main Thread Blocking & Deadlock Audit (2026-03-28)

## Critical Issues (confirmed, need fixing)

### 1. Format-on-Save deadlock
- **File:** `OakTextView+Formatting.mm` — `runCustomFormatter` (lines 9-109)
- **Pattern:** `dispatch_group_wait(group, DISPATCH_TIME_FOREVER)` on main thread with CFRunLoopRunInMode pump
- **Trigger:** Any `formatOnSave`/`formatCommand` enabled file type
- **Also:** LSP format-on-save path (lines 174-196) blocks with CFRunLoopRunInMode poll loop
- **Status:** Needs async refactor

### 2. SCM dispatch_sync on file/project switch
- **File:** `scm/src/scm.cc` (lines 336, 368) — `dispatch_sync(cache_access_queue(), ...)`
- **Called from:** `DocumentWindowController.mm` setProjectPath:/setDocumentPath: on main thread
- **Trigger:** Every tab switch or project change
- **Status:** Needs async conversion

### 3. wait_for_repair() parsing mutex
- **File:** `buffer/src/parsing.cc` (lines 116-151)
- **Pattern:** Holds grammar mutex in synchronous parsing loop on main thread
- **Called from:** `enumerateSymbolsUsingBlock:` → symbol popup
- **Status:** Needs investigation for async symbol enumeration

### 4. io::exec() infinite wait
- **File:** `io/src/exec.cc` (line 135) — `dispatch_group_wait(group, DISPATCH_TIME_FOREVER)`
- **Used by:** SCM drivers, command execution, merge — needs deeper investigation
- **Status:** Needs investigation

### 5. OakCommand + command/runner.mm semaphore waits
- **Files:** `OakCommand/src/OakCommand.mm` (line 126), `command/src/runner.mm` (line 97)
- **Pattern:** `dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER)` in pipe reading
- **Note:** May be intentionally sync for bundle commands — needs deeper investigation
- **Status:** Needs investigation

### 6. FileChooser semaphore
- **File:** `OakFilterList/src/FileChooser.mm` (line 527)
- **Pattern:** `dispatch_semaphore_wait` on main thread for directory scan
- **Status:** Needs async conversion

## Common Anti-Pattern
All share: blocking main thread with `dispatch_group_wait(FOREVER)`, `dispatch_semaphore_wait(FOREVER)`, or `dispatch_sync` to serial queues. Fix = async callbacks / `dispatch_group_notify`.
