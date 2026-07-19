# frozen_string_literal: true

# Copyright (c) 2026 [RubyEverywhere](https://rubyeverywhere.com).
# All rights reserved.
# This file is a part of the Tebako project.

require "tmpdir"

require_relative "../lib/tebako/runtime_sdk"

# rubocop:disable Metrics/BlockLength
RSpec.describe Tebako::RuntimeSdk do
  def descriptor
    ruby_version = double("RubyVersion", api_version: "4.0.0")
    options = double(
      "OptionsManager",
      ruby_ver: "4.0.6",
      rv: ruby_version,
      compression_level: 5,
      l_level: "error",
      source: File.expand_path("..", __dir__)
    )
    Tebako::RuntimeDescriptor.build(options)
  end

  it "packs and verifies a relocatable runtime SDK" do
    Dir.mktmpdir do |root|
      component = File.join(root, "component")
      archive = File.join(root, "runtime-sdk.tar.gz")
      destination = File.join(root, "installed")
      FileUtils.mkdir_p(File.join(component, "bin"))
      tool = File.join(component, "bin", "mkdwarfs")
      File.write(tool, "tool")
      FileUtils.chmod(0o755, tool)

      described_class.pack(
        output: archive,
        components: { "deps" => component },
        descriptor: descriptor
      )
      manifest = described_class.install(archive: archive, destination: destination)

      expect(manifest.fetch("runtime_identity")).to eq(descriptor.identity)
      expect(File.binread(File.join(destination, "deps", "bin", "mkdwarfs"))).to eq("tool")
      expect(File.stat(File.join(destination, "deps", "bin", "mkdwarfs")).mode & 0o777).to eq(0o755)
    end
  end

  it "checks a trusted archive digest and activates the packaged runtime cache" do
    Dir.mktmpdir do |root|
      runtime = File.join(root, "tebako-runtime")
      runtime_path = "runtime/tebako-runtime"
      archive = File.join(root, "runtime-sdk.tar.gz")
      checksum = "#{archive}.sha256"
      destination = File.join(root, "installed")
      File.binwrite(runtime, "native runtime")
      descriptor.write(Tebako::RuntimeDescriptor.path_for(runtime))

      described_class.pack(
        output: archive,
        components: {
          runtime_path => runtime,
          Tebako::RuntimeDescriptor.path_for(runtime_path) => Tebako::RuntimeDescriptor.path_for(runtime)
        },
        descriptor: descriptor,
        runtime_path: runtime_path
      )
      described_class.write_checksum(archive)
      expected_sha256 = File.binread(checksum).split.first
      manifest = described_class.install(
        archive: archive,
        destination: destination,
        expected_sha256: "sha256:#{expected_sha256}"
      )

      cache = Tebako::FinalizedRuntimeCache.new(
        cache_dir: File.join(destination, "deps", "finalized-runtime-cache"),
        descriptor: descriptor
      )
      cached_runtime = cache.fetch { raise "the SDK runtime should already be activated" }

      expect(manifest.fetch("runtime_path")).to eq(runtime_path)
      expect(File.binread(cached_runtime)).to eq("native runtime")
      expect(File.binread(checksum)).to eq("#{expected_sha256}  runtime-sdk.tar.gz\n")
      expect(File.binread(File.join(destination, "deps", Tebako::CacheManager::E_VERSION_FILE))).to eq(
        "#{Tebako::VERSION} at #{File.expand_path("..", __dir__)}"
      )
    end
  end

  it "rejects an untrusted archive digest without replacing an existing install" do
    Dir.mktmpdir do |root|
      component = File.join(root, "component")
      archive = File.join(root, "runtime-sdk.tar.gz")
      destination = File.join(root, "installed")
      FileUtils.mkdir_p(component)
      File.binwrite(File.join(component, "tool"), "tool")
      FileUtils.mkdir_p(destination)
      File.binwrite(File.join(destination, "keep"), "safe")
      described_class.pack(
        output: archive,
        components: { "deps" => component },
        descriptor: descriptor
      )

      expect do
        described_class.install(archive: archive, destination: destination, expected_sha256: "0" * 64)
      end.to raise_error(Tebako::Error, /SHA-256 mismatch/)
      expect(File.binread(File.join(destination, "keep"))).to eq("safe")
    end
  end

  it "rejects a corrupted archive without replacing an existing install" do
    Dir.mktmpdir do |root|
      component = File.join(root, "component")
      archive = File.join(root, "runtime-sdk.tar.gz")
      destination = File.join(root, "installed")
      FileUtils.mkdir_p(component)
      File.write(File.join(component, "runtime"), "runtime")
      FileUtils.mkdir_p(destination)
      File.write(File.join(destination, "keep"), "safe")
      described_class.pack(
        output: archive,
        components: { "runtime" => component },
        descriptor: descriptor
      )
      File.truncate(archive, File.size(archive) / 2)

      expect do
        described_class.install(archive: archive, destination: destination)
      end.to raise_error(Tebako::Error, /verification failed/)
      expect(File.binread(File.join(destination, "keep"))).to eq("safe")
    end
  end

  it "installs every file with one shared mtime so make never regenerates autotools outputs" do
    Dir.mktmpdir do |root|
      component = File.join(root, "component")
      archive = File.join(root, "runtime-sdk.tar.gz")
      destination = File.join(root, "installed")
      FileUtils.mkdir_p(component)
      # Alphabetical archive order writes "configure" before "configure.ac",
      # so without normalization the extracted configure ends up OLDER than
      # its own prerequisite and make tries to rerun autoconf (missing on
      # build runners).
      File.write(File.join(component, "configure"), "generated")
      File.write(File.join(component, "configure.ac"), "source")

      described_class.pack(
        output: archive,
        components: { "deps" => component },
        descriptor: descriptor
      )
      described_class.install(archive: archive, destination: destination)

      mtimes = Dir[File.join(destination, "**", "*")]
               .reject { |path| File.symlink?(path) }
               .map { |path| File.mtime(path) }
      expect(mtimes.uniq.size).to eq(1)
    end
  end

  it "preserves safe relative symlinks" do
    skip "symlink creation is unavailable" if Gem.win_platform?

    Dir.mktmpdir do |root|
      component = File.join(root, "component")
      archive = File.join(root, "runtime-sdk.tar.gz")
      destination = File.join(root, "installed")
      FileUtils.mkdir_p(component)
      File.write(File.join(component, "ruby-real"), "ruby")
      File.symlink("ruby-real", File.join(component, "ruby"))

      described_class.pack(
        output: archive,
        components: { "runtime" => component },
        descriptor: descriptor
      )
      described_class.install(archive: archive, destination: destination)

      expect(File.readlink(File.join(destination, "runtime", "ruby"))).to eq("ruby-real")
    end
  end
end
# rubocop:enable Metrics/BlockLength
