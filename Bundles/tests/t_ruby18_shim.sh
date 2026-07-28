#!/bin/bash
#
# Bundle Support's bin/ruby18 stands in for the ruby 1.8.7 build that used to be
# downloaded from archive.textmate.org. Every command with a ruby18 shebang goes
# through it, so a shim that only works when invoked one particular way breaks
# 43 bundles at once.

set -u

shim="$(cd "$(dirname "$0")/../Bundle Support.tmbundle/Support/shared/bin" && pwd)/ruby18"
failures=0

check () {
	local what="$1" expected="$2" actual="$3"
	if [[ "$actual" == "$expected" ]]; then
		echo "ok   — $what"
	else
		echo "FAIL — $what: expected '$expected', got '$actual'"
		failures=$((failures + 1))
	fi
}

# ruby resolves a relative -r against the load path rather than the working
# directory, so the shim has to hand it an absolute path however it was called.
check "absolute path"        ok "$("$shim" -e 'print "ok"' 2>&1)"
check "relative path"        ok "$(cd "$(dirname "$shim")/.." && ./bin/ruby18 -e 'print "ok"' 2>&1)"
check "bare ./ in bin"       ok "$(cd "$(dirname "$shim")" && ./ruby18 -e 'print "ok"' 2>&1)"
check "found on PATH"        ok "$(PATH="$(dirname "$shim"):$PATH" ruby18 -e 'print "ok"' 2>&1)"

# What ‘#!/usr/bin/env ruby18’ actually does, including the argument splitting
# Darwin performs on the shebang line. The script needs a .rb name, so it goes
# in a directory of its own rather than being renamed out from under mktemp —
# which would leave the file mktemp actually created behind on every run.
tmp_dir="$(mktemp -d -t ruby18-shim)"
trap 'rm -rf "$tmp_dir"' EXIT

script="$tmp_dir/shebang.rb"
printf '#!/usr/bin/env ruby18\nprint "ok"\n' > "$script"
chmod +x "$script"
check "env shebang"          ok "$(PATH="$(dirname "$shim"):$PATH" "$script" 2>&1)"

# rubygems is most of a bare ruby's startup and no bundle item expects it; the
# shim disables it centrally so no shebang has to.
check "rubygems disabled"    "off" "$("$shim" -e 'print defined?(Gem) ? "on" : "off"' 2>&1)"

# The version gate is loaded with -r so it costs no extra process. If it stops
# being reached, an unsupported interpreter would fail somewhere deep inside a
# bundle command instead of at the door.
check "version gate loaded"  "loaded" "$("$shim" -e 'print $LOADED_FEATURES.grep(/ruby_runtime/).empty? ? "missing" : "loaded"' 2>&1)"

# Arguments and stdin have to survive being passed through.
check "argv passthrough"     "a b" "$("$shim" -e 'print ARGV.join(" ")' a b 2>&1)"
check "stdin passthrough"    "hi"  "$(echo -n hi | "$shim" -e 'print STDIN.read' 2>&1)"
check "exit status"          "3"   "$("$shim" -e 'exit 3' 2>&1; echo -n $?)"

exit $(( failures > 0 ))
