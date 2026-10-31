#!/usr/bin/env ruby
# frozen_string_literal: true

# PR-only one-off verification for issue #39 deliverable 1: the generated
# OpenAPI client must actually be adopted in ColorComposerCore. The unit suite
# pins PaletteAPIClient's *behavior*; this spec pins the *migration artifacts*
# that behavior-preserving tests cannot observe (package dependencies and the
# committed OpenAPI document). Remove this file before merge per the
# .ephemeral-tests/ convention.
#
# Upstream dependencies: viamin/color_matching#110 (OpenAPI spec),
# viamin/color_matching#111 (parity corpus).

root = File.expand_path('..', __dir__)
failures = []

def check(name, failures, passed, detail = nil)
  status = passed ? 'PASS' : 'FAIL'
  puts format('  [%<status>s] %<name>s%<detail>s', status: status, name: name, detail: detail ? " — #{detail}" : '')
  failures << name unless passed
end

puts 'openapi_generated_client_spec (issue #39, ephemeral):'

package = File.expand_path('ColorComposerCore/Package.swift', root)
package_source = File.read(package)
check(
  'Package.swift depends on swift-openapi-generator',
  failures,
  package_source.match?(/swift-openapi-generator/)
)
check(
  'Package.swift depends on swift-openapi-runtime',
  failures,
  package_source.match?(/swift-openapi-runtime/)
)

openapi_docs = Dir.glob(File.join(root, 'ColorComposerCore', '**', '*openapi*.{yaml,yml,json}'))
                 .reject { |path| path.include?('/.build/') }
check(
  'an OpenAPI document is committed under ColorComposerCore',
  failures,
  !openapi_docs.empty?,
  openapi_docs.empty? ? 'no *openapi*.{yaml,yml,json} found' : openapi_docs.join(', ')
)

swift = %w[swift].find { |bin| system('command', '-v', bin, out: File::NULL, err: File::NULL) }
if swift
  ok = system(swift, 'build', '--package-path', File.expand_path('ColorComposerCore', root),
              out: File::NULL, err: File::NULL)
  check('swift build succeeds with the generated client', failures, ok)
else
  puts '  [SKIP] swift build — no Swift toolchain on this host; CI must cover it'
end

if failures.empty?
  puts 'RESULT: pass'
else
  puts "RESULT: fail (#{failures.size}: #{failures.join(', ')})"
  exit 1
end
