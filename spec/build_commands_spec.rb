# frozen_string_literal: true

# Copyright (c) 2026 [RubyEverywhere](https://rubyeverywhere.com).
# All rights reserved.
# This file is a part of the Tebako project.

require "tmpdir"

require_relative "../lib/tebako/cli"

# rubocop:disable Metrics/BlockLength
RSpec.describe Tebako::RuntimeCommand do
  it "exports an activatable SDK with runtime link inputs and a checksum" do
    Dir.mktmpdir do |root|
      runtime = File.join(root, "tebako-runtime")
      sdk = File.join(root, "runtime-sdk.tar.gz")
      deps = File.join(root, "prefix", "deps")
      stash = File.join(deps, "stash_4.0.6")
      ruby_source = File.join(deps, "src", "_ruby_4.0.6")
      output_folder = File.join(root, "prefix", "o")
      FileUtils.mkdir_p([File.join(deps, "bin"), stash, ruby_source, output_folder])
      File.binwrite(File.join(deps, "bin", "mkdwarfs"), "tool")
      File.binwrite(File.join(output_folder, "libtebako-fs.a"), "fs archive")
      File.binwrite(File.join(stash, "ruby"), "tool ruby")
      File.binwrite(File.join(ruby_source, Tebako::RuntimeBuilder::LINK_IDENTITY), "runtime identity")
      File.binwrite(File.join(ruby_source, "Makefile"), "DEPS = #{File.join(root, "prefix", "deps")}\n")
      File.binwrite(runtime, "native runtime")
      descriptor = Tebako::RuntimeDescriptor.new(
        "schema_version" => 1,
        "runtime_identity" => "tebako-runtime-v1-sdk-export",
        "ruby_version" => "4.0.6",
        "ruby_api_version" => "4.0.0",
        "platform" => RUBY_PLATFORM,
        "package_formats" => { "layered" => 1 }
      )
      descriptor.write(Tebako::RuntimeDescriptor.path_for(runtime))
      options_manager = double(
        "OptionsManager",
        package: runtime,
        prefix: File.join(root, "prefix"),
        deps: deps,
        stash_dir: stash,
        ruby_src_dir: ruby_source,
        output_folder: output_folder
      )
      scenario = double("ScenarioManager", exe_suffix: "")
      command = described_class.new([], { "sdk-output" => sdk }, {})

      expect do
        command.send(:export_sdk, options_manager, scenario, descriptor)
      end.to output(/Created runtime SDK checksum/).to_stdout

      destination = File.join(root, "installed")
      manifest = Tebako::RuntimeSdk.install(
        archive: sdk,
        destination: destination,
        expected_sha256: Tebako::RuntimeSdk.sha256(sdk)
      )

      expect(manifest.fetch("runtime_path")).to eq("runtime/tebako-runtime")
      expect(File).to exist("#{sdk}.sha256")
      expect(File.binread(File.join(destination, "deps", "bin", "mkdwarfs"))).to eq("tool")
      expect(File.binread(File.join(destination, "deps", "src", "_ruby_4.0.6",
                                    Tebako::RuntimeBuilder::LINK_IDENTITY))).to eq("runtime identity")
      expect(File.binread(File.join(destination, "deps", "src", "_ruby_4.0.6", "Makefile"))).to eq(
        "DEPS = #{File.join(destination, "deps")}\n"
      )
      # exts.mk links every press with `-L<prefix>/o -ltebako-fs`, so the SDK
      # must deliver the one library CMake builds outside deps/.
      expect(File.binread(File.join(destination, "o", "libtebako-fs.a"))).to eq("fs archive")
    end
  end

  it "refuses to export an SDK missing libtebako-fs.a" do
    Dir.mktmpdir do |root|
      runtime = File.join(root, "tebako-runtime")
      sdk = File.join(root, "runtime-sdk.tar.gz")
      deps = File.join(root, "prefix", "deps")
      FileUtils.mkdir_p(File.join(deps, "bin"))
      File.binwrite(runtime, "native runtime")
      descriptor = Tebako::RuntimeDescriptor.new(
        "schema_version" => 1,
        "runtime_identity" => "tebako-runtime-v1-sdk-export",
        "ruby_version" => "4.0.6",
        "ruby_api_version" => "4.0.0",
        "platform" => RUBY_PLATFORM,
        "package_formats" => { "layered" => 1 }
      )
      descriptor.write(Tebako::RuntimeDescriptor.path_for(runtime))
      options_manager = double(
        "OptionsManager",
        package: runtime,
        prefix: File.join(root, "prefix"),
        deps: deps,
        stash_dir: File.join(deps, "stash_4.0.6"),
        ruby_src_dir: File.join(deps, "src", "_ruby_4.0.6"),
        output_folder: File.join(root, "prefix", "o")
      )
      scenario = double("ScenarioManager", exe_suffix: "")
      command = described_class.new([], { "sdk-output" => sdk }, {})

      expect do
        command.send(:export_sdk, options_manager, scenario, descriptor)
      end.to raise_error(Tebako::Error, /did not produce .*libtebako-fs\.a/)
    end
  end
end
# rubocop:enable Metrics/BlockLength
