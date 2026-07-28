#!/bin/bash
#
# Bundle Support's bin/tm_ruby decides which ruby every bundle item runs under,
# and bin/ruby18 and bin/ruby20 — the names the shebangs actually say — are
# forwards to it. ruby18 alone stands in for the ruby 1.8.7 build that used to
# be downloaded from archive.textmate.org, so a shim that only works when
# invoked one particular way breaks 43 bundles at once.

set -u

bin="$(cd "$(dirname "$0")/../Bundle Support.tmbundle/Support/shared/bin" && pwd)"
shim="$bin/ruby18"
failures=0

# The resolver reads all of these, and $DIALOG would put an alert on screen in
# the failure test below.
unset TM_RUBY RUBYOPT RUBYLIB GEM_HOME DIALOG

check () {
	local what="$1" expected="$2" actual="$3"
	if [[ "$actual" == "$expected" ]]; then
		echo "ok   — $what"
	else
		echo "FAIL — $what: expected '$expected', got '$actual'"
		failures=$((failures + 1))
	fi
}

# Some of what is checked below is that a misconfiguration ends rather than
# spins, so those runs get a deadline: the way to fail here is to hang the whole
# suite, and a killed process reports a status no expectation matches.
deadline_output=
deadline_run () { # deadline_run <seconds> <command…>, output in $deadline_output
	local secs="$1" out="$tmp_dir/deadline.out" pid ticks status
	shift
	"$@" > "$out" 2>&1 &
	pid=$!
	# The deadline is polled here rather than kept by a background watchdog: a
	# watchdog's sleep inherits this test's stdout, so it would hold the pipe
	# open — and CTest waiting on it — for the full deadline after the suite is
	# done, and its late kill -9 could land on a reused PID.
	ticks=$((secs * 10))
	while [ $ticks -gt 0 ] && kill -0 "$pid" 2>/dev/null; do
		sleep 0.1
		ticks=$((ticks - 1))
	done
	if [ $ticks -eq 0 ]; then
		kill -9 "$pid" 2>/dev/null
	fi
	wait "$pid"; status=$?
	deadline_output="$(cat "$out")"
	return $status
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

# rubygems is most of a bare ruby's startup and nothing written against the
# ruby18 name has had it since the shim stopped downloading its own interpreter,
# so the shim says so centrally rather than each shebang.
check "rubygems disabled"    "off" "$("$shim" -e 'print defined?(Gem) ? "on" : "off"' 2>&1)"

# Whether rubygems is on belongs to the name in the shebang, so the resolver
# takes it as an argument. Called directly it has no shebang to be compatible
# with and answers off, which is the cheaper start.
check "resolver defaults to no gems" "off" "$("$bin/tm_ruby" -e 'print defined?(Gem) ? "on" : "off"' 2>&1)"
check "resolver takes gems=on"       "on"  "$("$bin/tm_ruby" --tm-rubygems=on -e 'print defined?(Gem) ? "on" : "off"' 2>&1)"
check "resolver takes gems=off"      "off" "$("$bin/tm_ruby" --tm-rubygems=off -e 'print defined?(Gem) ? "on" : "off"' 2>&1)"
check "gems argument is not passed on" "" "$("$bin/tm_ruby" --tm-rubygems=on -e 'print ARGV.join(" ")' 2>&1)"

# The version gate is loaded with -r so it costs no extra process. If it stops
# being reached, an unsupported interpreter would fail somewhere deep inside a
# bundle command instead of at the door.
check "version gate loaded"  "loaded" "$("$shim" -e 'print $LOADED_FEATURES.grep(/ruby_runtime/).empty? ? "missing" : "loaded"' 2>&1)"

# Arguments and stdin have to survive being passed through.
check "argv passthrough"     "a b" "$("$shim" -e 'print ARGV.join(" ")' a b 2>&1)"
check "stdin passthrough"    "hi"  "$(echo -n hi | "$shim" -e 'print STDIN.read' 2>&1)"
check "exit status"          "3"   "$("$shim" -e 'exit 3' 2>&1; echo -n $?)"

# 61 shipped shebangs say -KU, -wKU or -KA. Ruby retired -K, so the shim strips
# the real kcode forms — silently, and without letting -KA force ASCII — while
# an option argument that merely contains a K (-IKlib, -rKfoo) must pass
# through byte for byte: the shim serves third-party bundles too, and rewriting
# their arguments is a regression however unlikely the spelling.
check "-KU stripped"         "clean" "$("$shim" -KU -e 'print "clean"' 2>&1)"
check "-wKU keeps -w"        "warn"  "$("$shim" -wKU -e 'print $VERBOSE ? "warn" : "quiet"' 2>&1)"
check "-KA does not force ASCII" "UTF-8" "$(LANG=en_US.UTF-8 "$shim" -KA -e 'print Encoding.default_external' 2>&1)"
check "-IKlib passes through" "Klib" "$("$shim" -IKlib -e 'print $LOAD_PATH.first.split("/").last' 2>&1)"
check "-rKfoo passes through" "Kfoo" "$("$shim" -rKfoo -e 1 2>&1 | grep -o 'Kfoo' | head -1)"
check "-- ends filtering"    "-KU"  "$("$shim" -e 'print ARGV.first' -- -KU 2>&1)"

# TM_RUBY is the one thing that outranks the system ruby, and it is taken as
# given — no version glob, no PATH search — because the point of the resolver is
# that there is exactly one interpreter nobody had to go looking for.
fake_ruby="$tmp_dir/fake-ruby"
printf '#!/bin/sh\nprintf mine:\nexec /usr/bin/ruby "$@"\n' > "$fake_ruby"
chmod +x "$fake_ruby"
check "TM_RUBY honoured"     "mine:ok" "$(TM_RUBY="$fake_ruby" "$shim" -e 'print "ok"' 2>&1)"

# A ruby the user named comes with the environment they set it up with: gems,
# and the RUBYOPT / RUBYLIB / GEM_HOME the system one is not allowed to inherit.
check "TM_RUBY keeps rubygems" "on"     "$(TM_RUBY=/usr/bin/ruby "$shim" -e 'print defined?(Gem) ? "on" : "off"' 2>&1)"
check "TM_RUBY keeps RUBYOPT"  "on"     "$(RUBYOPT=-rjson TM_RUBY=/usr/bin/ruby "$shim" -e 'print defined?(JSON) ? "on" : "off"' 2>&1)"
check "TM_RUBY keeps RUBYLIB"  '"/tmp"' "$(RUBYLIB=/tmp TM_RUBY=/usr/bin/ruby "$shim" -e 'print ENV["RUBYLIB"].inspect' 2>&1)"

# What it must not be taken as is one of our own names. ruby18 chose an
# interpreter for years, so it can still be sitting in a .tm_properties meaning
# ruby 1.8 — and since the shim forwards to the resolver and the resolver would
# run the shim, taking it at face value is a command that never returns.
for self in ruby18 ruby20 tm_ruby "$bin/ruby18" "$bin/tm_ruby"; do
	label="$self"
	[[ "$self" == /* ]] && label=".../${self##*/}"
	deadline_run 10 env TM_RUBY="$self" PATH="$bin:$PATH" "$shim" -e 'print "ran"'
	check "TM_RUBY=$label fails"    "1" "$?"
	case "$deadline_output" in
		*"one of TextMate’s own ruby shims"*) said="explained"          ;;
		*)                                    said="$deadline_output"   ;;
	esac
	check "TM_RUBY=$label explains" "explained" "$said"
done

# Without it, a shell configured for some other ruby must not reach the one
# bundle items run under: a RUBYOPT arriving from an enclosing environment
# breaks them in a way that is near impossible to see from inside a command.
check "RUBYOPT sanitised"    "off" "$(RUBYOPT=-rjson "$shim" -e 'print defined?(JSON) ? "on" : "off"' 2>&1)"
check "RUBYLIB sanitised"    "nil" "$(RUBYLIB=/tmp "$shim" -e 'print ENV["RUBYLIB"].inspect' 2>&1)"
check "GEM_HOME sanitised"   "nil" "$(GEM_HOME=/tmp "$shim" -e 'print ENV["GEM_HOME"].inspect' 2>&1)"

# The system ruby cannot be taken away for the length of a test, so the resolver
# runs from a copy whose fallback points at nothing. If that substitution ever
# stops matching, the copy runs the real interpreter and these fail loudly
# rather than passing on a test that no longer tests anything.
missing="$tmp_dir/tm_ruby"
sed 's|RUBY=/usr/bin/ruby|RUBY=/nonexistent/ruby|' "$bin/tm_ruby" > "$missing"
chmod +x "$missing"

# TextMate puts up its own dialog for any status outside 0 and 200–208, so the
# resolver must not raise one as well. $DIALOG is pointed at a script that
# records having been asked.
dialog_marker="$tmp_dir/dialog-was-called"
printf '#!/bin/sh\ntouch "%s"\n' "$dialog_marker" > "$tmp_dir/dialog"
chmod +x "$tmp_dir/dialog"

missing_out="$(DIALOG="$tmp_dir/dialog" "$missing" -e 'print "ran"' 2>&1)"
missing_status=$?
check "missing ruby exits nonzero" "1" "$missing_status"
check "missing ruby shows no dialog of its own" "no" "$([ -e "$dialog_marker" ] && echo yes || echo no)"
case "$missing_out" in
	*"No ruby interpreter is available at /nonexistent/ruby"*) said="explained"    ;;
	*)                                                         said="$missing_out" ;;
esac
check "missing ruby explains" "explained" "$said"

# ruby20 used to find the system ruby by globbing the framework itself. It now
# forwards like ruby18 does, so the two names have to mean the same interpreter
# with the same treatment — the -K filtering included, since a third-party
# bundle is free to write -KU above either name.
#
# Rubygems is where they part. ruby20 has always had it, and it is a name
# bundles we do not ship can use, so taking it away would be a LoadError in
# something we never see. The sanitising is common to both: a custom GEM_HOME
# still goes, though the paths gem(1) installs to by default do not depend on it.
ruby20="$bin/ruby20"
check "ruby20 runs"            "ok"      "$("$ruby20" -e 'print "ok"' 2>&1)"
check "ruby20 strips -KU"      "clean"   "$("$ruby20" -KU -e 'print "clean"' 2>&1)"
check "ruby20 keeps rubygems"  "on"      "$("$ruby20" -e 'print defined?(Gem) ? "on" : "off"' 2>&1)"
check "ruby20 finds user gems" "yes"     "$("$ruby20" -e 'print Gem.path.any? { |p| p.start_with?(Dir.home) } ? "yes" : "no"' 2>&1)"
check "ruby20 sanitises RUBYLIB" "nil"   "$(RUBYLIB=/tmp "$ruby20" -e 'print ENV["RUBYLIB"].inspect' 2>&1)"
check "ruby20 loads the gate"  "loaded"  "$("$ruby20" -e 'print $LOADED_FEATURES.grep(/ruby_runtime/).empty? ? "missing" : "loaded"' 2>&1)"
check "ruby20 honours TM_RUBY" "mine:ok" "$(TM_RUBY="$fake_ruby" "$ruby20" -e 'print "ok"' 2>&1)"
check "shims agree on ruby"    "$("$shim" -e 'print RUBY_DESCRIPTION' 2>&1)" "$("$ruby20" -e 'print RUBY_DESCRIPTION' 2>&1)"

exit $(( failures > 0 ))
