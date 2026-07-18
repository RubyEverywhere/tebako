# frozen_string_literal: true

# Copyright (c) 2026 [RubyEverywhere](https://rubyeverywhere.com).
# All rights reserved.
# This file is a part of the Tebako project.

require "tmpdir"

require_relative "../lib/tebako/runtime_descriptor"

# rubocop:disable Metrics
RSpec.describe Tebako::RuntimeDescriptor do
  let(:ruby_version) { double("RubyVersion", api_version: "4.0.0") }
  let(:options) do
    double(
      "OptionsManager",
      ruby_ver: "4.0.6",
      rv: ruby_version,
      compression_level: 5,
      l_level: "error",
      source: File.expand_path("..", __dir__)
    )
  end

  it "builds a stable identity from runtime-only inputs" do
    first = described_class.build(options)
    second = described_class.build(options)

    expect(first.identity).to eq(second.identity)
    expect(first.data).to include(
      "schema_version" => 1,
      "ruby_version" => "4.0.6",
      "ruby_api_version" => "4.0.0"
    )
  end

  it "changes identity when runtime source content or build flags change" do
    first = described_class.build(options)
    old = ENV.fetch("CFLAGS", nil)
    ENV["CFLAGS"] = "-DTEBAKO_IDENTITY_TEST"

    expect(described_class.build(options).identity).not_to eq(first.identity)
  ensure
    ENV["CFLAGS"] = old
  end

  it "round-trips through an atomic JSON descriptor" do
    Dir.mktmpdir do |root|
      path = File.join(root, "runtime.runtime.json")
      descriptor = described_class.build(options)
      descriptor.write(path)

      expect(described_class.load(path).identity).to eq(descriptor.identity)
    end
  end

  it "rejects incompatible Ruby ABIs and package formats" do
    descriptor = described_class.build(options)

    expect do
      descriptor.compatible!(ruby_version: "4.0.6", ruby_api_version: "3.3.0")
    end.to raise_error(Tebako::Error, /Ruby ABI/)
    expect do
      descriptor.compatible!(
        ruby_version: "4.0.6",
        ruby_api_version: "4.0.0",
        package_format: "unknown"
      )
    end.to raise_error(Tebako::Error, /package format/)
  end

  it "rejects unknown descriptor schemas" do
    expect do
      described_class.new("schema_version" => 99)
    end.to raise_error(Tebako::Error, /Unsupported runtime descriptor schema/)
  end
end
# rubocop:enable Metrics
