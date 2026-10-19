# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'

class PrivacyFileProtectionPolicyTest < Minitest::Test
  def test_non_simulator_builds_require_data_protection
    verify_policy([], [])
    verify_policy(['-D', 'DEBUG'], [])
  end

  def test_simulator_opt_in_is_debug_only
    simulator = ENV['OMI_IOS_DEVICE_ID']
    skip 'Set OMI_IOS_DEVICE_ID to a booted simulator for native simulator checks' unless simulator
    architecture, status = Open3.capture2('uname', '-m')
    assert status.success?
    target = "#{architecture.strip}-apple-ios17.0-simulator"
    flags = ['--sdk', 'iphonesimulator', 'swiftc', '-target', target]
    verify_policy(flags + ['-D', 'DEBUG'], ['xcrun', 'simctl', 'spawn', simulator])
    verify_policy(flags, ['xcrun', 'simctl', 'spawn', simulator])
  end

  private

  def verify_policy(flags, runner)
    root = File.expand_path('..', __dir__)
    sources = ['Runner/PrivacyFileProtectionPolicy.swift', 'test/privacy_file_protection_policy_test.swift']
              .map { |path| File.join(root, path) }
    Dir.mktmpdir('omi-protection-policy') do |directory|
      binary = File.join(directory, 'policy-test')
      command = flags.first == '--sdk' ? ['xcrun', *flags] : ['xcrun', 'swiftc', *flags]
      stdout, stderr, status = Open3.capture3(*command, '-parse-as-library', *sources, '-o', binary)
      assert status.success?, "Policy compilation failed:\n#{stdout}\n#{stderr}"
      stdout, stderr, status = Open3.capture3(*runner, binary)
      assert status.success?, "Policy assertions failed:\n#{stdout}\n#{stderr}"
    end
  end
end
