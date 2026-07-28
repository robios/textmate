# A minimal test harness, shared by the tests in this directory.
#
# Not test/unit or minitest: both are gems, and bundle commands run with
# --disable-gems, so a test needing rubygems would not be exercising the
# environment this code actually runs in.

class TestCase
	@@failures = 0
	@@assertions = 0

	def self.run
		instance = new
		methods = instance.methods.map(&:to_s).grep(/\Atest_/).sort
		methods.each do |name|
			begin
				instance.send(name)
			rescue Exception => e
				fail!("#{name}: #{e.class}: #{e.message}", e.backtrace)
			end
		end
		puts "#{methods.length} tests, #{@@assertions} assertions, #{@@failures} failures"
		@@failures.zero?
	end

	def self.fail! (message, backtrace = caller)
		@@failures += 1
		$stderr.puts "FAIL #{message}"
		$stderr.puts backtrace.grep(%r{Bundles/tests}).first(3).map { |l| "       #{l}" }
	end

	def assert (condition, message = 'expected a true value')
		@@assertions += 1
		TestCase.fail!(message, caller) unless condition
	end

	def assert_equal (expected, actual, message = nil)
		assert(expected == actual, "#{message || 'not equal'}: expected #{expected.inspect}, got #{actual.inspect}")
	end

	def assert_same (expected, actual, message = nil)
		assert(expected.equal?(actual), message || "expected the same object as #{expected.inspect}")
	end

	def assert_kind_of (klass, actual, message = nil)
		assert(actual.is_a?(klass), message || "expected a #{klass}, got #{actual.class}")
	end

	def assert_raise (klass, message = nil)
		@@assertions += 1
		begin
			yield
		rescue klass
			return
		rescue Exception => e
			return TestCase.fail!("#{message || 'wrong exception'}: expected #{klass}, got #{e.class}: #{e.message}", caller)
		end
		TestCase.fail!(message || "expected #{klass}, nothing was raised", caller)
	end
end
