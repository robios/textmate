# Regression tests for Bundle Support's lib/osx/plist.rb, the replacement for
# the CoreFoundation plist.bundle C extension.
#
# These cover the boundaries the corpus comparison cannot reach: the installed
# bundles hold no NaN, no out-of-range integer, no non-UTF-8 string and no
# DateTime, so 2,300 files agreeing proves nothing about any of them. Expected
# values were measured against the C extension under ruby 1.8.7 and against
# plutil(1), and each case notes which.
#
#   ruby --disable-gems t_plist_shim.rb

require 'date'
require 'stringio'
require 'tempfile'

require File.expand_path('harness', __dir__)
require File.expand_path('../Bundle Support.tmbundle/Support/shared/lib/osx/plist', __dir__)

class TestPlistShim < TestCase
	def emit (obj)
		{ 'v' => obj }.to_plist
	end

	def value (obj)
		emit(obj)[%r{<(?:string|integer|real|date|data)>[^<]*}]
	end

	def reload (obj)
		OSX::PropertyList.load(emit(obj))['v']
	end

	def parse (fragment)
		OSX::PropertyList.load(%Q{<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>v</key>#{fragment}</dict></plist>})['v']
	end

	# plutil is the reader that matters: a document it rejects is one no
	# TextMate command, and no other reader, can load.
	def assert_valid_plist (xml)
		Tempfile.open([ 'plist-shim', '.plist' ]) do |io|
			io.binmode
			io.write(xml)
			io.flush
			assert(system('/usr/bin/plutil', '-lint', io.path, out: File::NULL, err: File::NULL),
				"plutil rejected the emitted plist:\n#{xml}")
		end
	end

	# ================================
	# = Round trip of ordinary values =
	# ================================

	def test_scalars_round_trip
		{
			'string'   => 'hello',
			'empty'    => '',
			'unicode'  => "日本語 éè",
			'multiline'=> "line one\n\tline two\n\nline four",
			'markup'   => 'a & b < c > d " e \' f',
			'int'      => 42,
			'negative' => -7,
			'real'     => 1.5,
			'true'     => true,
			'false'    => false,
			'time'     => Time.at(1234567890).utc,
			'empty_h'  => {},
			'empty_a'  => [],
			'nested'   => { 'a' => [ 1, { 'b' => "c\nd" }, [ 'e' ] ] },
		}.each do |name, obj|
			assert_equal(obj, reload(obj), "#{name} did not survive a round trip")
		end
		assert_valid_plist(emit('日本語 & <markup>'))
	end

	# A multi-line string must come back with exactly the newlines it went in
	# with. The vendored gem's generator indents every line of what it is given,
	# including the ones inside a value, which is why emitting does not use it.
	def test_multiline_strings_are_not_reindented
		body = "if true\n\tputs 'x'\nend\n"
		assert_equal(body, reload({ 'deep' => { 'deeper' => body } })['deep']['deeper'])
	end

	# Every public way into the emitter has to bypass that generator, not just
	# to_plist. Plist::Emit.dump is the gem's own module function; save_plist
	# reaches it through to_plist and so was already covered.
	def test_every_entry_point_avoids_the_gem_generator
		body = "x\ny"
		assert_equal("<string>#{body}", Plist::Emit.dump({ 'v' => body })[/<string>[^<]*/])
		assert_equal("<string>#{body}", OSX::PropertyList.dump({ 'v' => body })[/<string>[^<]*/])
		assert_equal("<string>#{body}", { 'v' => body }.to_plist[/<string>[^<]*/])

		Tempfile.open([ 'save-plist', '.plist' ]) do |io|
			{ 'v' => body }.save_plist(io.path)
			assert_equal("<string>#{body}", File.read(io.path)[/<string>[^<]*/])
		end
	end

	# CoreFoundation orders keys by UTF-16 code unit, which stops agreeing with
	# code point order at U+10000: the lead surrogate D800–DBFF sorts below the
	# single units E000–FFFF, so an emoji key comes first. Sorting the UTF-8
	# bytes gets that pair backwards.
	def test_keys_are_ordered_the_way_coreFoundation_orders_them
		emoji = "a\u{1F600}"
		pua   = "a\u{E000}"
		repl  = "a\u{FFFD}"

		keys = { repl => 1, emoji => 2, pua => 3 }.to_plist.scan(%r{<key>(.*?)</key>}m).flatten
		assert_equal([ emoji, pua, repl ], keys)
	end

	def test_ordinary_keys_are_still_in_name_order
		keys = { 'zeta' => 1, 'Alpha' => 2, 'alpha' => 3, '1' => 4 }.to_plist.scan(%r{<key>(.*?)</key>}m).flatten
		assert_equal([ '1', 'Alpha', 'alpha', 'zeta' ], keys)
	end

	# ============================
	# = <data> and blob? strings =
	# ============================

	def test_blob_strings_round_trip_as_data
		bytes = (0..255).to_a.pack('C*')
		bytes.blob = true

		out = reload(bytes)
		assert(out.blob?, '<data> should come back tagged as a blob')
		assert_equal(bytes.bytes, out.bytes)
		assert_valid_plist(emit(bytes))
	end

	def test_empty_data
		empty = ''.dup
		empty.blob = true
		assert_equal('', reload(empty))
		assert(reload(empty).blob?)
	end

	# The stock PData#to_ruby runs Marshal.load on the decoded bytes first, so a
	# <data> element that happens to be a valid Marshal stream would build an
	# arbitrary object. We only ever want the bytes — which is also what the C
	# extension returned.
	def test_data_is_never_unmarshalled
		payload = Marshal.dump({ 'this' => 'would be an object' })
		out = parse("<data>#{[ payload ].pack('m0')}</data>")

		assert_kind_of(String, out)
		assert_equal(payload.bytes, out.bytes)
	end

	# ==========================================
	# = Floats: NaN and infinity (review [P2]) =
	# ==========================================

	# ‘nan’, ‘+infinity’, ‘-infinity’ is what the C extension wrote and what
	# plutil(1) normalises to. %.17g would produce ‘NaN’ and ‘Inf’, which plutil
	# rejects outright.
	def test_special_floats_emit_the_coreFoundation_spelling
		assert_equal('<real>nan',        value(Float::NAN))
		assert_equal('<real>+infinity',  value(Float::INFINITY))
		assert_equal('<real>-infinity',  value(-Float::INFINITY))

		assert_valid_plist(emit(Float::NAN))
		assert_valid_plist(emit(Float::INFINITY))
		assert_valid_plist(emit(-Float::INFINITY))
	end

	# The gem's PReal#to_ruby is text.to_f, which turns every one of these into
	# 0.0 without a word.
	def test_special_floats_are_read_back
		assert(parse('<real>nan</real>').nan?)
		assert(parse('<real>NaN</real>').nan?)
		assert_equal(Float::INFINITY,  parse('<real>+infinity</real>'))
		assert_equal(Float::INFINITY,  parse('<real>infinity</real>'))
		assert_equal(Float::INFINITY,  parse('<real>Inf</real>'))
		assert_equal(-Float::INFINITY, parse('<real>-infinity</real>'))

		assert(reload(Float::NAN).nan?)
		assert_equal(Float::INFINITY,  reload(Float::INFINITY))
		assert_equal(-Float::INFINITY, reload(-Float::INFINITY))
	end

	def test_ordinary_floats_keep_full_precision
		[ 0.1, 1e20, 3.0, 1.0e-9, 123456.789, 1.0/3 ].each do |f|
			assert_equal(f, reload(f), "#{f} lost precision")
		end
		assert_equal('<real>0.0', value(0.0))
		assert_equal('<real>0.0', value(-0.0))
	end

	# ==================================
	# = Integer range (review [P2]) =
	# ==================================

	def test_integers_inside_the_plist_range
		[ 0, -1, 2**31, 2**40, 2**62, 2**63-1, -2**63 ].each do |i|
			assert_equal(i, reload(i), "#{i} did not survive a round trip")
			assert_valid_plist(emit(i))
		end
	end

	# Signed 64-bit is what an <integer> means to CoreFoundation, so a wider
	# value is not merely unrepresentable — it reads back as a different number
	# (2**63 as -2**63, 2**64-1 as -1). plutil lints those happily, which is why
	# the boundary cannot be taken from plutil alone. The C extension raised
	# RangeError; so do we.
	def test_integers_outside_the_plist_range_are_refused
		[ 2**63, 2**64-1, 2**64, 2**100, -2**63 - 1, -2**100 ].each do |i|
			assert_raise(OSX::PropertyListError, "#{i} should not be emittable") { emit(i) }
		end
	end

	# =====================================
	# = String encodings (review [P2]) =
	# =====================================

	def test_non_utf8_encodings_are_converted
		latin1 = "caf\xE9".dup.force_encoding('ISO-8859-1')
		assert_equal('café', reload(latin1))
		assert_valid_plist(emit(latin1))
	end

	def test_binary_strings_holding_utf8_are_accepted
		bytes = 'café'.dup.force_encoding(Encoding::BINARY)
		assert_equal('café', reload(bytes))
		assert_valid_plist(emit(bytes))
	end

	# A stray 0xFF inside a document declared UTF-8 is rejected by plutil — and
	# by every other reader — which loses the whole file rather than the one
	# value. Refusing to write it keeps the failure at the value.
	def test_undecodable_bytes_are_refused_rather_than_written
		assert_raise(OSX::PropertyListError) { emit("\xFF".dup.force_encoding(Encoding::BINARY)) }
		assert_raise(OSX::PropertyListError) { emit("caf\xE9".dup.force_encoding(Encoding::UTF_8)) }
		assert_raise(OSX::PropertyListError) { { "\xFF".dup.force_encoding(Encoding::BINARY) => 'x' }.to_plist }
	end

	def test_arbitrary_bytes_can_still_be_stored_as_a_blob
		bytes = "\xFF\xFE".dup.force_encoding(Encoding::BINARY)
		bytes.blob = true
		assert_equal([ 0xFF, 0xFE ], reload(bytes).bytes)
	end

	# ===================================
	# = Dates (review [P2]) =
	# ===================================

	# DateTime subclasses Date, so it matched the Date branch and had a ‘Z’
	# stamped on a wall clock that was not UTC — moving the instant by the
	# offset.
	def test_datetime_with_an_offset_is_converted_to_utc
		assert_equal('<date>2026-01-01T03:00:00Z', value(DateTime.parse('2026-01-01T12:00:00+09:00')))
		assert_equal('<date>2026-01-01T12:00:00Z', value(DateTime.parse('2026-01-01T12:00:00Z')))
	end

	def test_time_is_converted_to_utc
		assert_equal('<date>2026-01-01T03:00:00Z', value(Time.at(1767236400).utc))
	end

	# CoreFoundation handed dates back as Time in UTC, not DateTime.
	def test_dates_are_read_back_as_utc_time
		out = parse('<date>2026-01-01T03:00:00Z</date>')
		assert_kind_of(Time, out)
		assert(out.utc?)
		assert_equal(1767236400, out.to_i)
	end

	# =====================
	# = Binary plist input =
	# =====================

	# .tmCommand files are binary plists, so this is the common case rather than
	# an exotic one. The vendored gem is XML-only; plutil(1) normalises first.
	def test_binary_plists_are_read
		original = { 'name' => 'x', 'n' => 7, 'nested' => { 'a' => [ 1, 2 ] } }
		Tempfile.open([ 'binary', '.plist' ]) do |io|
			io.binmode
			io.write(original.to_plist)
			io.flush
			assert(system('/usr/bin/plutil', '-convert', 'binary1', io.path, out: File::NULL, err: File::NULL))
			assert_equal(original, OSX::PropertyList.load(File.binread(io.path)))
		end
	end

	def test_not_a_property_list_raises
		assert_raise(OSX::PropertyListError) { OSX::PropertyList.load('this is not a plist') }
	end

	# ==========================
	# = The C extension's API =
	# ==========================

	# The C extension's dump was dump(io, obj): it wrote to an IO and returned
	# the byte count. Callers passing an IO must not have it serialised as the
	# <data> payload.
	def test_dump_accepts_the_c_extension_signature
		io = StringIO.new
		n = OSX::PropertyList.dump(io, { 'v' => 1 })
		io.rewind
		xml = io.read

		assert_equal(xml.bytesize, n)
		assert_equal({ 'v' => 1 }, OSX::PropertyList.load(xml))
	end

	def test_dump_accepts_an_object_and_returns_a_string
		assert_equal({ 'v' => 1 }, OSX::PropertyList.load(OSX::PropertyList.dump({ 'v' => 1 })))
		assert(!OSX::PropertyList.dump({ 'v' => 1 }, false).include?('<plist'))
	end

	# The deprecated top-level alias the C extension exported. Third-party and
	# user bundles may still reach for it.
	def test_deprecated_toplevel_alias
		assert_same(OSX::PropertyList, ::PropertyList)
	end

	def test_load_ignores_the_format_argument
		assert_equal({ 'v' => 1 }, OSX::PropertyList.load({ 'v' => 1 }.to_plist, true))
	end

	def test_load_accepts_an_io
		assert_equal({ 'v' => 1 }, OSX::PropertyList.load(StringIO.new({ 'v' => 1 }.to_plist)))
	end

	# A string argument is the property list itself, never a filename to read.
	# Plist.parse_xml guesses at filenames, and the C extension never did — a
	# path that happens to exist must not pull in the file's contents. (An
	# unquoted word is a valid old-style plist, so this comes back as itself.)
	def test_a_string_is_never_treated_as_a_path
		assert_equal('/etc/hosts', OSX::PropertyList.load('/etc/hosts'))
	end

	def test_unsupported_types_are_refused
		assert_raise(OSX::PropertyListError) { emit(Object.new) }
	end
end

exit(TestPlistShim.run ? 0 : 1)
