# encoding: utf-8
#
# Drop-in replacement for lib/osx/plist.bundle, the CoreFoundation-backed C
# extension. That binary was last built for ppc/i386/x86_64, so it cannot load
# in an arm64 ruby and pins every bundle that requires textmate.rb to the
# Rosetta-only ruby 1.8.7.
#
# require resolves .rb before .bundle, so callers need no change: this file
# simply takes over the name.
#
# Reading uses the vendored pure-ruby plist gem. Binary (and OpenStep) plists
# are normalised to XML by plutil(1) first, because the gem is XML-only — and
# binary is what .tmCommand files and ~/Library/Preferences/*.plist are.
# Writing does not use the gem; see OSX::PropertyList.generate for why.

require 'stringio'
require 'date'
# Resolved relative to this file, not via TM_SUPPORT_PATH: the shim must also
# load outside a TextMate command environment (tests, scripts run without the
# variable set), and the C extension it replaces had no such dependency.
require File.expand_path('../../private/plist', __dir__)

class String
   # CoreFoundation returns <data> as a String tagged with blob?; the gem uses
   # IO objects instead. OSX::PropertyList translates between the two.
   def blob?
      defined?(@blob) ? !!@blob : false
   end

   def blob= (flag)
      @blob = flag
   end

   include Plist::Emit unless method_defined?(:to_plist)
end

module Plist
   class PReal < PTag
      # The stock implementation is text.to_f, which turns every one of the
      # spellings CoreFoundation and plutil(1) use for these into 0.0 —
      # silently, and for values the C extension read back correctly.
      SPECIAL = {
         'nan'       =>  Float::NAN,
         'infinity'  =>  Float::INFINITY,
         '+infinity' =>  Float::INFINITY,
         'inf'       =>  Float::INFINITY,
         '+inf'      =>  Float::INFINITY,
         '-infinity' => -Float::INFINITY,
         '-inf'      => -Float::INFINITY,
      }.freeze

      def to_ruby
         SPECIAL[text.to_s.strip.downcase] || text.to_f
      end
   end

   class PData < PTag
      # The stock implementation runs Marshal.load on the decoded bytes and
      # only falls back to a StringIO when that raises. Any <data> element that
      # happens to be a valid Marshal stream would therefore instantiate an
      # arbitrary object. We only ever want the bytes, which is also what the
      # C extension handed back.
      def to_ruby
         bytes = text.nil? ? '' : Base64.decode64(text.gsub(/\s+/, ''))
         bytes.blob = true
         bytes
      end
   end

   module Emit
      # Route to_plist through the shim so blob? strings survive the round trip.
      def to_plist (envelope = true)
         OSX::PropertyList.dump(self, envelope)
      end

      # The gem's own entry point, which otherwise still reaches the generator
      # that re-indents the inside of a multi-line string. Nothing in Bundle
      # Support calls it, but leaving one door open onto the broken emitter
      # defeats the point of replacing it — the same reasoning that keeps the
      # deprecated ::PropertyList alias around for third-party bundles.
      #
      # save_plist needs no such treatment: it writes obj.to_plist, which is
      # the method above.
      def self.dump (obj, envelope = true)
         OSX::PropertyList.generate(obj, envelope)
      end
   end
end

module OSX
   class PropertyListError < StandardError; end

   module PropertyList
      XML_PROLOGUE = /\A\s*(?:<\?xml|<!DOCTYPE\s+plist|<plist)/

      # Takes an IO or a String holding the property list itself. Deliberately
      # never treats a String as a path: the C extension did not, and
      # Plist.parse_xml’s own filename guessing would misread short fragments.
      #
      # The second argument is the C extension’s ‘format’ flag. No in-tree
      # caller passes it (verified over every expanded command body), and we
      # always return the plist alone, never the [plist, format] pair.
      def self.load (io_or_string, _format = nil)
         data = io_or_string.respond_to?(:read) ? io_or_string.read : io_or_string.to_s
         data = data.dup.force_encoding(Encoding::BINARY)
         xml  = utf8_xml?(data) ? data.force_encoding(Encoding::UTF_8) : to_xml(data)
         normalize(Plist.parse_xml(StringIO.new(xml)))
      rescue PropertyListError
         raise
      rescue StandardError => e
         raise PropertyListError, e.message
      end

      # Two shapes, because the C extension’s own dump was dump(io, obj): it
      # wrote the plist to an IO and returned the byte count. No in-tree caller
      # uses it — everything goes through to_plist — but a third-party bundle
      # that does would otherwise get its IO serialised as the <data> payload
      # and no error to show for it. Called with a plist first, this is the
      # ordinary dump(obj, envelope) that returns a string.
      def self.dump (first, second = true)
         return generate(first, second) unless first.respond_to?(:write)

         xml = generate(second, true)
         first.write(xml)
         xml.bytesize
      end

      PROLOGUE = %Q{<?xml version="1.0" encoding="UTF-8"?>\n} +
                 %Q{<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n} +
                 %Q{<plist version="1.0">\n}
      EPILOGUE = %Q{</plist>\n}

      # Emits what CoreFoundation emitted, byte for byte: keys sorted, tab
      # indentation, base64 wrapped at 60 columns, reals as %.17g, and only
      # &<> escaped.
      #
      # This does not go through the vendored gem’s generator. That generator
      # re-indents every line of whatever it is handed, including the newlines
      # *inside* a string value — so a command body would gain one tab per
      # nesting level on each round trip. Bundle items are mostly multi-line
      # strings, which makes that the common case rather than a corner.
      def self.generate (obj, envelope = true)
         body = String.new(encoding: Encoding::UTF_8)
         emit(obj, 0, body)
         envelope ? PROLOGUE + body + EPILOGUE : body
      end

      def self.emit (node, level, out)
         pad = "\t" * level
         case node
         when Hash
            if node.empty?
               out << "#{pad}<dict/>\n"
            else
               out << "#{pad}<dict>\n"
               node.keys.sort_by { |key| sort_key(key) }.each do |key|
                  out << "#{pad}\t<key>#{escape(key.to_s)}</key>\n"
                  emit(node[key], level + 1, out)
               end
               out << "#{pad}</dict>\n"
            end
         when Array
            if node.empty?
               out << "#{pad}<array/>\n"
            else
               out << "#{pad}<array>\n"
               node.each { |value| emit(value, level + 1, out) }
               out << "#{pad}</array>\n"
            end
         when String
            # Never indented inside: the bytes of the value are the value.
            node.blob? ? emit_data(node, level, out) : out << "#{pad}<string>#{escape(node)}</string>\n"
         when Symbol
            out << "#{pad}<string>#{escape(node.to_s)}</string>\n"
         when true, false
            out << "#{pad}<#{node}/>\n"
         when Integer
            # ruby integers are arbitrary precision; a plist integer is not.
            # Emitting a wider one produces a document neither plutil nor
            # CoreFoundation will read back, so refuse it the way the C
            # extension did (it raised RangeError).
            raise PropertyListError, "integer out of range for a property list: #{node}" unless INTEGER_RANGE.cover?(node)
            out << "#{pad}<integer>#{node}</integer>\n"
         when Float
            out << "#{pad}<real>#{real(node)}</real>\n"
         when Time
            out << "#{pad}<date>#{node.utc.strftime('%Y-%m-%dT%H:%M:%SZ')}</date>\n"
         when DateTime
            # Before Date, which it subclasses: strftime on a DateTime keeps the
            # wall clock and would stamp a ‘Z’ on a time that is not UTC,
            # moving the instant by the offset.
            out << "#{pad}<date>#{node.new_offset(0).strftime('%Y-%m-%dT%H:%M:%SZ')}</date>\n"
         when Date
            out << "#{pad}<date>#{node.strftime('%Y-%m-%dT%H:%M:%SZ')}</date>\n"
         when IO, StringIO
            node.rewind
            emit_data(node.read, level, out)
         else
            raise PropertyListError, "cannot serialise #{node.class}"
         end
         out
      end

      # CoreFoundation wrapped base64 to fit a 76-column line, counting each
      # tab of indentation as eight columns, and stopped narrowing at twelve.
      def self.emit_data (bytes, level, out)
         pad   = "\t" * level
         width = [ 76 - 8 * level, 12 ].max
         out << "#{pad}<data>\n"
         [ bytes ].pack('m0').scan(/.{1,#{width}}/) { |line| out << pad << line << "\n" }
         out << "#{pad}</data>\n"
      end

      # Signed 64-bit, which is how CoreFoundation reads an <integer> back —
      # kCFNumberSInt64Type, including in TextMate's own plist reader. plutil(1)
      # will lint and re-encode a larger value happily, so its digits survive a
      # textual round trip, but every CoreFoundation consumer sees it wrapped:
      # 2**63 comes back as -2**63 and 2**64-1 as -1. Emitting one produces a
      # file that reads as a different number, which is worse than refusing it.
      INTEGER_RANGE = (-2**63 .. 2**63-1)

      # CoreFoundation orders keys by UTF-16 code unit, not by code point, and
      # plutil(1) still does. The two agree until U+10000, where a character
      # becomes a surrogate pair whose lead unit (D800–DBFF) sorts below the
      # single units E000–FFFF — so an emoji key comes before one starting
      # U+E000, which sorting the UTF-8 bytes gets backwards.
      #
      # The key is normalised on the way, so a key that cannot be represented
      # is refused here rather than several lines later in escape.
      def self.sort_key (key)
         utf8(key.to_s).encode(Encoding::UTF_16BE).b
      end

      # nan / +infinity / -infinity are the spellings CoreFoundation wrote and
      # plutil(1) still normalises to. %.17g would say ‘NaN’ and ‘Inf’, which
      # plutil rejects outright.
      def self.real (value)
         return 'nan' if value.nan?
         return value < 0 ? '-infinity' : '+infinity' if value.infinite?
         # Zero is the one finite value CoreFoundation did not write as %.17g
         # would (‘0’); negative zero it also wrote as ‘0.0’.
         value.zero? ? '0.0' : '%.17g' % value
      end

      # Escapes &<> — all CoreFoundation escaped; quotes and apostrophes were
      # left alone, and matching that keeps rewritten bundle items from showing
      # up as diffs against everything TextMate itself has written.
      #
      # The encoding has to be settled first. We declare UTF-8 in the prologue,
      # so anything else has to be converted, and bytes that cannot be are
      # refused rather than written out: an XML file with a stray 0xFF in it is
      # rejected wholesale by every reader, which loses the entire document
      # instead of the one value. The C extension had nothing to decide here —
      # ruby 1.8 strings were bytes, and it reinterpreted them in the system
      # encoding, which is not behaviour worth reproducing.
      def self.escape (str)
         str = utf8(str)
         str.gsub(/[&<>]/, '&' => '&amp;', '<' => '&lt;', '>' => '&gt;')
      end

      def self.utf8 (str)
         if str.encoding == Encoding::UTF_8
            return str if str.valid_encoding?
            raise PropertyListError, 'string is tagged UTF-8 but does not hold valid UTF-8; tag it as a blob to store it as <data>'
         elsif str.encoding == Encoding::BINARY
            # No source encoding to convert from, so the only safe reading is
            # that these bytes already are UTF-8. Usually they are — this is
            # what comes back from reading a file in binary mode.
            candidate = str.dup.force_encoding(Encoding::UTF_8)
            return candidate if candidate.valid_encoding?
         else
            begin
               return str.encode(Encoding::UTF_8)
            rescue EncodingError
            end
         end

         raise PropertyListError, "cannot represent #{str.encoding} string as UTF-8; tag it as a blob to store it as <data>"
      end

      # Only the plain UTF-8 XML case can skip plutil. Binary, OpenStep and
      # UTF-16 all go the long way round.
      def self.utf8_xml? (data)
         data =~ XML_PROLOGUE && data.dup.force_encoding(Encoding::UTF_8).valid_encoding?
      end

      # Ask plutil to turn whatever this is into XML. plutil reads stdin as ‘-’.
      def self.to_xml (data)
         out = IO.popen([ '/usr/bin/plutil', '-convert', 'xml1', '-o', '-', '-' ], 'r+b') do |io|
            io.write(data)
            io.close_write
            io.read
         end
         raise PropertyListError, 'not a property list' unless $?.success?
         out.force_encoding(Encoding::UTF_8)
      end

      # DateTime -> Time (UTC), matching what CoreFoundation handed back.
      def self.normalize (node)
         case node
         when Hash     then node.each_with_object({}) { |(k, v), h| h[k] = normalize(v) }
         when Array    then node.map { |v| normalize(v) }
         when DateTime then node.to_time.utc
         else node
         end
      end
   end
end

# Deprecated alias exported by the C extension. Keep it for third-party and
# user bundles even though in-tree callers use OSX::PropertyList.
PropertyList = OSX::PropertyList unless defined?(PropertyList)
