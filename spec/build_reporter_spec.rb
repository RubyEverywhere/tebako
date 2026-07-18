# frozen_string_literal: true

# Copyright (c) 2026 [RubyEverywhere](https://rubyeverywhere.com).
# All rights reserved.
# This file is a part of the Tebako project.

require "json"
require "stringio"

require_relative "../lib/tebako/build_reporter"

# rubocop:disable Metrics
RSpec.describe Tebako::BuildReporter do
  after { described_class.current = nil }

  it "prints a concise human explanation" do
    output = StringIO.new
    reporter = described_class.start(explain: true, output: output)
    described_class.record(
      stage: "deployment",
      status: "rebuilt",
      reason: "project content changed",
      details: { "changed_inputs" => ["project_tree"] }
    )
    reporter.finish(success: true)

    expect(output.string).to include("Build explanation (successful):")
    expect(output.string).to include("deployment: rebuilt")
    expect(output.string).to include("changed: project_tree")
  end

  it "emits a versioned JSON report" do
    output = StringIO.new
    reporter = described_class.start(format: "json", output: output)
    described_class.record(stage: "deployment", status: "reused", key: "abc")
    reporter.finish(success: true)

    report = JSON.parse(output.string)
    expect(report.fetch("schema_version")).to eq(1)
    expect(report.fetch("success")).to be(true)
    expect(report.fetch("events").first).to include(
      "stage" => "deployment",
      "status" => "reused",
      "key" => "abc"
    )
  end

  it "does not collect events when reporting is disabled" do
    reporter = described_class.start
    described_class.record(stage: "deployment", status: "reused")

    expect(reporter.events).to be_empty
  end
end
# rubocop:enable Metrics
