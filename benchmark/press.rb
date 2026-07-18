#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "optparse"
require "rbconfig"
require "tmpdir"

# Measures warm, unchanged, and application-changed Tebako presses.
class PressBenchmark
  def initialize(options)
    @options = options
    @repo = File.expand_path("..", __dir__)
  end

  def run
    Dir.mktmpdir("tebako-press-benchmark") do |directory|
      puts JSON.pretty_generate(results_for(directory))
    end
  end

  private

  def results_for(directory)
    root, output = prepare_workspace(directory)
    results = { mode: @options[:mode], warm: press(root, output), unchanged: press(root, output) }
    add_probe(root)
    results[:application_changed] = press(root, output)
    results[:runtime_validation] = validate(output) unless @options[:skip_run]
    add_comparisons(results)
    results
  end

  def prepare_workspace(directory)
    root = File.join(directory, "application")
    FileUtils.cp_r(File.join(File.expand_path(@options[:root]), "."), root)
    [root, File.join(directory, "tebako-benchmark")]
  end

  def add_probe(root)
    timestamp = Process.clock_gettime(Process::CLOCK_REALTIME).to_s
    File.write(File.join(root, ".tebako-benchmark-probe"), timestamp)
  end

  def add_comparisons(results)
    warm = results[:warm][:seconds]
    results[:comparisons] = {
      unchanged_vs_warm: ratio(results[:unchanged][:seconds], warm),
      application_changed_vs_warm: ratio(results[:application_changed][:seconds], warm)
    }
  end

  def ratio(value, baseline)
    (value / baseline).round(3)
  end

  def press(root, output)
    command = press_command(root, output)
    warn "Running #{command.join(" ")}"
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    log, status = Open3.capture2e(*command, chdir: @repo)
    abort log unless status.success?

    press_result(log, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started)
  end

  def press_result(log, elapsed)
    report = parse_report(log)
    {
      seconds: elapsed.round(3),
      reused_filesystems: log.scan("reusing packaged filesystem").length,
      reused_native_link: log.include?("reusing Ruby executable"),
      rebuilt_runtime_filesystem: log.include?("Building packaged filesystem from changed inputs"),
      stages: report.fetch("events", []).map do |event|
        event.slice("stage", "status", "duration_seconds", "reason", "details")
      end
    }
  end

  def parse_report(log)
    line = log.lines.reverse.find { |candidate| candidate.start_with?("{\"schema_version\"") }
    line ? JSON.parse(line) : {}
  rescue JSON::ParserError
    {}
  end

  def press_command(root, output)
    [
      RbConfig.ruby, "-I#{File.join(@repo, "lib")}", File.join(@repo, "exe", "rbe-tebako"),
      "press", "--mode", @options[:mode], "--prefix", @options[:prefix], "--Ruby", @options[:ruby],
      "--root", root, "--entry-point", @options[:entry], "--output", output,
      "--compression-level", @options[:compression].to_s, "--report", "json"
    ]
  end

  def validate(output)
    command = @options[:mode] == "bundle" ? [output] : [output, "--tebako-run", "#{output}.tebako"]
    log, status = Open3.capture2e(*command)
    { success: status.success?, output: log }
  end
end

options = {
  root: File.expand_path("../tests/test-00", __dir__),
  entry: "test.rb",
  prefix: "PWD",
  ruby: "4.0.6",
  compression: 5,
  mode: "both",
  skip_run: false
}

OptionParser.new do |parser|
  parser.banner = "Usage: benchmark/press.rb [options]"
  parser.on("--root PATH", "Application root (default: tests/test-00)") { |value| options[:root] = value }
  parser.on("--entry PATH", "Entry point relative to root (default: test.rb)") { |value| options[:entry] = value }
  parser.on("--prefix PATH", "Tebako prefix (default: PWD)") { |value| options[:prefix] = value }
  parser.on("--ruby VERSION", "Packaged Ruby version (default: 4.0.6)") { |value| options[:ruby] = value }
  parser.on("--mode MODE", %w[bundle both], "Package mode: bundle or both (default: both)") do |value|
    options[:mode] = value
  end
  parser.on("--compression N", Integer, "DwarFS compression level (default: 5)") do |value|
    options[:compression] = value
  end
  parser.on("--skip-run", "Do not execute the resulting package") { options[:skip_run] = true }
end.parse!

PressBenchmark.new(options).run
