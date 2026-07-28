# Resolved from this file's own location rather than TM_SUPPORT_PATH, so that
# the vendored gem also loads outside a TextMate command environment — tests
# and scripts run without the variable set.
vendor_lib = File.expand_path('vendor/plist/lib', __dir__)
$LOAD_PATH.unshift(vendor_lib) unless $LOAD_PATH.include?(vendor_lib)
require 'plist'
