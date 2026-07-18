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
