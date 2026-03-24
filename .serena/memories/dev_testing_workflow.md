# Development Testing Workflow

## Launching TextMate for Manual Testing

`make run` uses `open` which detaches stdout/stderr — NSLog output is lost. The macOS unified log (`log show`/`log stream`) does NOT capture NSLog from the debug build either.

### Correct approach: launch binary directly with stderr capture

```bash
# 1. Build
make

# 2. Kill old instance
pkill -f "TextMate.app/Contents/MacOS/TextMate"

# 3. Launch with stderr capture
/Users/fenrir/code/textmate/build-debug/Applications/TextMate/TextMate.app/Contents/MacOS/TextMate [file] 2>/tmp/tm-stderr.log &

# 4. Monitor live
tail -f /tmp/tm-stderr.log | grep --line-buffered 'pattern'

# 5. Or check after
grep 'pattern' /tmp/tm-stderr.log
```

## LSP Testing with Fake Server

- Place `.tm_properties` and test files in `/tmp/lsp-test/`
- Use full path for python in lspCommand: `/opt/homebrew/bin/python3` — TextMate's subprocess PATH doesn't include homebrew
- Write the fake server as an event loop (not sequential reads) since TextMate may send messages in unexpected order
- Launch TextMate pointed at the test file directly
- Run the log monitor as a background task so user can interact while logs stream
- Fake server stderr gets routed through `[LSP][stderr]` in the log output
