# frozen_string_literal: true

# Copyright (c) 2026 [RubyEverywhere](https://rubyeverywhere.com).
# All rights reserved.
# This file is a part of the Tebako project.

require "tmpdir"

require_relative "../lib/tebako/application_builder"

# rubocop:disable Metrics
RSpec.describe Tebako::ApplicationBuilder do
  let(:ruby_version) { double("RubyVersion", api_version: "4.0.0") }
  let(:scenario) { double("ScenarioManager", exe_suffix: "") }

  it "validates a described runtime before packaging" do
    Dir.mktmpdir do |root|
      runtime = File.join(root, "runtime")
      options = double(
        "OptionsManager",
        mode: "application",
        ref: runtime,
        ruby_ver: "4.0.6",
        rv: ruby_version,
        deployment_cache?: false
      )
      descriptor_options = double(
        "RuntimeOptions",
        ruby_ver: "4.0.6",
        rv: ruby_version,
        compression_level: 5,
        l_level: "error",
        source: File.expand_path("..", __dir__)
      )
      Tebako::RuntimeDescriptor.build(descriptor_options).write("#{runtime}.runtime.json")
      packager = double("PackagerLite", create_package: true)
      allow(Tebako::PackagerLite).to receive(:new).and_return(packager)

      expect(described_class.new(options, scenario).build).to be(true)
      expect(packager).to have_received(:create_package)
    end
  end

  it "fails early for an incompatible described runtime" do
    Dir.mktmpdir do |root|
      runtime = File.join(root, "runtime")
      options = double(
        "OptionsManager",
        mode: "application",
        ref: runtime,
        ruby_ver: "3.3.7",
        rv: double(api_version: "3.3.0"),
        deployment_cache?: false
      )
      descriptor_options = double(
        "RuntimeOptions",
        ruby_ver: "4.0.6",
        rv: ruby_version,
        compression_level: 5,
        l_level: "error",
        source: File.expand_path("..", __dir__)
      )
      Tebako::RuntimeDescriptor.build(descriptor_options).write("#{runtime}.runtime.json")

      expect { described_class.new(options, scenario).build }.to raise_error(Tebako::Error, /incompatible/)
    end
  end
end
# rubocop:enable Metrics
