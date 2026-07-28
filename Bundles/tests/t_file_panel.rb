# Tests for TextMate::UI.request_file / request_files, which used to shell out
# to CocoaDialog's ‘fileselect’ and now ask the application for a panel.
#
# $DIALOG is replaced with a script that records its arguments and answers with
# a property list, so the option mapping and the shape of the answer can be
# checked without a running TextMate.
#
#   ruby --disable-gems t_file_panel.rb

require 'tmpdir'
require 'fileutils'

require File.expand_path('harness', __dir__)

SUPPORT = File.expand_path('../Bundle Support.tmbundle/Support/shared', __dir__)
ENV['TM_SUPPORT_PATH'] = SUPPORT
require File.join(SUPPORT, 'lib', 'ui')

class TestFilePanel < TestCase
	def initialize
		@dir = Dir.mktmpdir('file-panel')
		at_exit { FileUtils.rm_rf(@dir) }
	end

	# Stands in for $DIALOG: writes the arguments it was given, one per line, and
	# prints whatever answer the test asked for.
	def with_dialog (answer)
		script = File.join(@dir, 'dialog')
		log    = File.join(@dir, 'argv')
		File.write(script, <<~SH)
			#!/bin/sh
			printf '%s\\n' "$@" > #{log}
			cat <<'PLIST'
			#{answer}
			PLIST
		SH
		File.chmod(0o755, script)

		ENV['DIALOG'] = script
		result = yield
		[ result, File.exist?(log) ? File.read(log).split("\n") : [] ]
	end

	def with_paths (*paths, &block)
		items = paths.map { |p| "<string>#{p}</string>" }.join
		with_dialog(%Q{<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>paths</key><array>#{items}</array></dict></plist>}, &block)
	end

	def with_cancel (&block)
		with_dialog(%Q{<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict/></plist>}, &block)
	end

	def assert_arg (argv, flag, expected)
		i = argv.index(flag)
		assert(i, "expected #{flag} in #{argv.inspect}")
		assert_equal(expected, argv[i + 1], "value of #{flag}") if i
	end

	def assert_no_arg (argv, flag)
		assert(!argv.include?(flag), "did not expect #{flag} in #{argv.inspect}")
	end

	# ===================
	# = What comes back =
	# ===================

	# An array even for a single selection: that is what the CocoaDialog version
	# returned, and callers index into it (Subversion's move.rb does dir.first).
	def test_single_selection_is_still_an_array
		result, _ = with_paths('/tmp/one') { TextMate::UI.request_file }
		assert_equal([ '/tmp/one' ], result)
	end

	def test_multiple_selection
		result, _ = with_paths('/tmp/one', '/tmp/two') { TextMate::UI.request_files }
		assert_equal([ '/tmp/one', '/tmp/two' ], result)
	end

	def test_block_form_yields_the_paths
		yielded = nil
		with_paths('/tmp/one') { TextMate::UI.request_file { |paths| yielded = paths } }
		assert_equal([ '/tmp/one' ], yielded)
	end

	# ==============
	# = Cancelling =
	# ==============

	# The panel reports a cancel by returning no paths at all — there is no
	# button title to compare against, which is how the CocoaDialog version knew.
	def test_cancel_without_a_block_returns_nil
		result, _ = with_cancel { TextMate::UI.request_file }
		assert_equal(nil, result)
	end

	def test_cancel_with_a_block_raises_system_exit
		with_cancel do
			assert_raise(SystemExit) { TextMate::UI.request_file { |paths| flunk } }
		end
	end

	# A $DIALOG that fails outright must not look like a selection.
	def test_a_failing_dialog_is_treated_as_a_cancel
		ENV['DIALOG'] = '/usr/bin/false'
		assert_equal(nil, TextMate::UI.request_file)
	end

	# ==================
	# = Option mapping =
	# ==================

	def test_defaults
		_, argv = with_paths('/tmp/one') { TextMate::UI.request_file }
		assert_arg(argv, '--title', 'Select File')
		assert_no_arg(argv, '--allowsMultipleSelection')
		assert_no_arg(argv, '--canChooseDirectories')

		_, argv = with_paths('/tmp/one') { TextMate::UI.request_files }
		assert_arg(argv, '--title', 'Select File(s)')
		assert_arg(argv, '--allowsMultipleSelection', '1')
	end

	def test_title_and_prompt
		_, argv = with_paths('/tmp/one') { TextMate::UI.request_file(:title => 'Pick', :prompt => 'Choose one') }
		assert_arg(argv, '--title', 'Pick')
		# --message is the explanatory text; --prompt is the action button.
		assert_arg(argv, '--message', 'Choose one')
	end

	# :button1 is the action button, which the panel does expose. :button2 is
	# accepted and ignored — AppKit has no API for a save/open panel's cancel
	# button title, so there is nothing to map it to.
	def test_button_titles
		_, argv = with_paths('/tmp/one') { TextMate::UI.request_file(:button1 => 'Use This', :button2 => 'Never Mind') }
		assert_arg(argv, '--prompt', 'Use This')
		assert(!argv.include?('Never Mind'), "button2 should not reach the panel: #{argv.inspect}")
	end

	def test_only_directories
		_, argv = with_paths('/tmp/one') { TextMate::UI.request_file(:only_directories => true) }
		assert_arg(argv, '--canChooseFiles', '0')
		assert_arg(argv, '--canChooseDirectories', '1')
	end

	# Subversion passes a Pathname here, not a String.
	def test_directory_accepts_anything_with_to_s
		require 'pathname'
		_, argv = with_paths('/tmp/one') { TextMate::UI.request_file(:directory => Pathname.new('/tmp/start')) }
		assert_arg(argv, '--defaultDirectory', '/tmp/start')
	end

	# Titles and directories are user data and reach a shell command line.
	def test_arguments_are_quoted
		_, argv = with_paths('/tmp/one') { TextMate::UI.request_file(:title => 'a b; touch /tmp/pwned', :directory => "/tmp/it's here") }
		assert_arg(argv, '--title', 'a b; touch /tmp/pwned')
		assert_arg(argv, '--defaultDirectory', "/tmp/it's here")
	end

	def flunk
		assert(false, 'this should not have been reached')
	end
end

exit(TestFilePanel.run ? 0 : 1)
