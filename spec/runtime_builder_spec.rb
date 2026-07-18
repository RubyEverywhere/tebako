# frozen_string_literal: true

# Copyright (c) 2026 [RubyEverywhere](https://rubyeverywhere.com).
# All rights reserved.
# This file is a part of the Tebako project.

require "tmpdir"

require_relative "../lib/tebako/runtime_builder"

# rubocop:disable Metrics
RSpec.describe Tebako::RuntimeBuilder do
  it "runs the runtime graph and publishes a capability descriptor" do
    Dir.mktmpdir do |root|
      output = File.join(root, "tebako-runtime")
      ruby_version = double("RubyVersion", api_version: "4.0.0")
      options = double(
        "OptionsManager",
        mode: "runtime",
        package: output,
        ruby_src_dir: root,
        ruby_ver: "4.0.6",
        rv: ruby_version,
        compression_level: 5,
        l_level: "error",
        source: File.expand_path("..", __dir__)
      )
      scenario = double("ScenarioManager", b_env: {}, exe_suffix: "")
      calls = []
      generator = -> { calls << :generate }
      finalizer = lambda do
        calls << :finalize
        File.write(output, "runtime")
      end
      runner = lambda do |_environment, command|
        calls << command
        true
      end

      builder = described_class.new(
        options,
        scenario,
        command_runner: runner,
        file_generator: generator,
        finalizer: finalizer,
        configure_command: "configure",
        build_command: "build"
      )
      descriptor = builder.build

      expect(calls).to eq([:generate, "configure", "build", :finalize])
      expect(descriptor.identity).to start_with("tebako-runtime-v1-")
      expect(File).to exist("#{output}.runtime.json")
      expect(File.binread(File.join(root, described_class::LINK_IDENTITY))).to eq(descriptor.identity)
      expect(builder.build.identity).to eq(descriptor.identity)
      expect(calls).to eq([:generate, "configure", "build", :finalize])
    end
  end

  it "fails before finalization when CMake fails" do
    options = double("OptionsManager", mode: "runtime", package: "/missing/runtime")
    scenario = double("ScenarioManager", b_env: {}, exe_suffix: "")
    finalizer = instance_double(Proc)
    allow(finalizer).to receive(:call)
    runner = ->(_environment, _command) { false }

    expect do
      described_class.new(
        options,
        scenario,
        command_runner: runner,
        file_generator: -> {},
        finalizer: finalizer,
        configure_command: "configure",
        build_command: "build"
      ).build
    end.to raise_error(Tebako::Error)
    expect(finalizer).not_to have_received(:call)
  end
end
# rubocop:enable Metrics
