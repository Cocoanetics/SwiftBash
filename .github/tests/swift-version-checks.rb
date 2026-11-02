#!/usr/bin/env ruby
# Runs the actual workflow snippets with a fake compiler. Requires bash and pwsh.
# Usage: ruby .github/tests/swift-version-checks.rb [repository root]
require 'yaml'
require 'open3'
require 'tmpdir'
require 'fileutils'

root = ARGV.fetch(0, File.expand_path('../..', __dir__))
jobs = %w[swift deps-drift].flat_map do |workflow|
  YAML.load_file(File.join(root, ".github/workflows/#{workflow}.yml"))
      .fetch('jobs').map { |name, job| [name, job] }
end
raise 'expected six build jobs' unless jobs.length == 6

checks = 0
Dir.mktmpdir('swift-version-checks') do |dir|
  installation = File.join(dir, 'swift-6.4.2-RELEASE/usr')
  bin = File.join(installation, 'bin')
  FileUtils.mkdir_p(bin)
  File.write(File.join(bin, 'swift'), <<~'BASH')
    #!/bin/bash
    if [ "$1" = '--version' ]; then
      printf '%s\n' "$MOCK_SWIFT_BANNER"
      exit "$MOCK_SWIFT_STATUS"
    fi
    if [ "$*" = 'sdk configure --show-configuration swift-6.4.2-RELEASE_android x86_64-unknown-linux-android28' ]; then
      echo 'Android SDK configuration'
      exit "${MOCK_SDK_STATUS:-0}"
    fi
    echo "unexpected compiler command: $*" >&2
    exit 99
  BASH
  FileUtils.chmod(0755, File.join(bin, 'swift'))

  jobs.each do |name, job|
    steps = job.fetch('steps')
    verify = steps.select { |step| step['name'] == 'Verify Swift version' }
    raise "#{name}: expected one Verify Swift version step" unless verify.length == 1
    step = verify.first
    shell = step.fetch('shell', name == 'build-windows' ? 'pwsh' : 'bash')
    command = case shell
              when 'bash' then ['bash', '--noprofile', '--norc', '-eo', 'pipefail', '-c']
              when 'pwsh' then ['pwsh', '-NoProfile', '-NonInteractive', '-Command']
              else raise "#{name}: untested shell #{shell}"
              end
    script = step.fetch('run')
    # Resolve the action output to its normal target, as Actions does.
    env = {
      'PATH' => "#{bin}:#{ENV.fetch('PATH')}",
      'SWIFT_INSTALLATION' => installation,
      'SWIFT_ARTIFACTBUNDLE_RESOURCES_ROOT_PATH' =>
        "#{dir}/swift-6.4.2-RELEASE_android.artifactbundle/swift-android/swift-resources",
      'ANDROID_SWIFT_SDK' => 'x86_64-unknown-linux-android28'
    }
    cases = [
      ["Apple Swift version 6.4.2 (swiftlang-6.4.2 clang-2100)\nTarget: arm64-apple-macosx27.0", 0, true],
      ["Swift version 6.4.2 (swift-6.4.2-RELEASE)\nTarget: x86_64-unknown-linux-gnu", 0, true],
      ["swift-driver version: 1.168 Apple Swift version 6.4.2 (swiftlang-6.4.2)\nTarget: arm64-apple-macosx27.0", 0, true],
      ['Swift version 6.2 (swift-6.2-RELEASE)', 0, false],
      ['Apple Swift version 6.40 (swiftlang-6.40)', 0, false],
      ['Swift version 6.40.2 (swift-6.40.2-RELEASE)', 0, false],
      ['Swift version 6.3.1 (swift-6.3.1-RELEASE)', 0, false],
      ['Swift version 6.4garbage', 0, false],
      ['', 0, false],
      ['compiler failed', 42, false],
      ['Swift version 6.4.2 (swift-6.4.2-RELEASE)', 42, false]
    ]
    unless name == 'build-android'
      cases += [['Apple Swift version 6.4 (swiftlang-6.4)', 0, true],
                ['Swift version 6.4.0 (swift-6.4-RELEASE)', 0, true]]
    end
    cases.each do |banner, status, expected|
      output, error, result = Open3.capture3(env.merge('MOCK_SWIFT_BANNER' => banner,
                                                      'MOCK_SWIFT_STATUS' => status.to_s),
                                            *command, script)
      raise "#{name}: wrong result for #{banner.inspect}, exit #{status}: #{output}#{error}" unless result.success? == expected
      raise "#{name}: lost compiler exit status #{status}" if status != 0 && result.exitstatus != status
      normalized = output.gsub("\r\n", "\n")
      raise "#{name}: full banner not printed: #{output}#{error}" unless normalized.include?("#{banner}\n")
      checks += 1
    end
    if name == 'build-android'
      # A valid runner compiler must not mask a missing/wrong action toolchain or SDK.
      [{ 'SWIFT_INSTALLATION' => File.join(dir, 'missing') },
       { 'SWIFT_ARTIFACTBUNDLE_RESOURCES_ROOT_PATH' => "#{dir}/swift-6.3-RELEASE_android.artifactbundle/resources" },
       { 'MOCK_SDK_STATUS' => '43' }].each do |override|
        output, error, result = Open3.capture3(env.merge('MOCK_SWIFT_BANNER' => 'Swift version 6.4.2',
                                                        'MOCK_SWIFT_STATUS' => '0').merge(override),
                                              *command, script)
        raise "Android accepted the wrong toolchain/SDK: #{override}: #{output}#{error}" if result.success?
        checks += 1
      end
    end
    puts "#{name}: passed"
  end
end
puts "#{checks} workflow version checks passed"
