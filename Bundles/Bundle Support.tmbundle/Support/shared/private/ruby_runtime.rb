# Loaded with -r by bin/ruby18 so the version gate costs no extra process.
#
# The shim used to guarantee ruby 1.8.7 by downloading it; it now runs whatever
# ruby it resolved. Refusing to start is better than failing somewhere deep
# inside a bundle command with a syntax error from an unexpected dialect.
if RUBY_VERSION.split('.').map(&:to_i).first < 2
   abort "#{File.basename($PROGRAM_NAME)}: ruby #{RUBY_VERSION} is too old — TextMate’s bundle support requires ruby 2.0 or later."
end
