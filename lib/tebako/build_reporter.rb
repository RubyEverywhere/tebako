# frozen_string_literal: true

# Copyright (c) 2026 [RubyEverywhere](https://rubyeverywhere.com).
# All rights reserved.
# This file is a part of the Tebako project.

require "json"

# rubocop:disable Metrics
# Tebako - an executable packager
module Tebako
  # Collects machine-readable build decisions and optionally explains them.
  class BuildReporter
    THREAD_KEY = :tebako_build_reporter
    SCHEMA_VERSION = 1

    class << self
      def current
        Thread.current[THREAD_KEY]
      end

      def start(explain: false, format: nil, output: $stdout)
        self.current = new(explain: explain, format: format, output: output)
      end

      def current=(reporter)
        Thread.current[THREAD_KEY] = reporter
      end

      def record(**event)
        current&.record(**event)
      end
    end

    attr_reader :events

    def initialize(explain: false, format: nil, output: $stdout)
      @explain = explain
      @format = format
      @output = output
      @events = []
      @started_at = monotonic_time
      @finished = false
    end

    def enabled?
      @explain || @format
    end

    def record(stage:, status:, reason: nil, key: nil, duration: nil, details: nil)
      return unless enabled?

      event = {
        "stage" => stage.to_s,
        "status" => status.to_s,
        "elapsed_seconds" => rounded(monotonic_time - @started_at)
      }
      event["duration_seconds"] = rounded(duration) if duration
      event["reason"] = reason if reason
      event["key"] = key if key
      event["details"] = details if details && !details.empty?
      @events << event
      event
    end

    def finish(success:)
      return if @finished

      @finished = true
      print_explanation(success) if @explain
      print_json(success) if @format == "json"
    end

    private

    def print_explanation(success)
      @output.puts
      @output.puts "Build explanation (#{success ? "successful" : "failed"}):"
      if @events.empty?
        @output.puts "  No instrumented build stages ran."
        return
      end

      @events.each do |event|
        @output.puts "  #{event.fetch("stage").tr("_", " ")}: #{event.fetch("status")}"
        @output.puts "    #{event["reason"]}" if event["reason"]
        changed = event.dig("details", "changed_inputs")
        @output.puts "    changed: #{changed.join(", ")}" if changed&.any?
      end
    end

    def print_json(success)
      @output.puts JSON.generate(
        "schema_version" => SCHEMA_VERSION,
        "success" => success,
        "duration_seconds" => rounded(monotonic_time - @started_at),
        "events" => @events
      )
    end

    def monotonic_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def rounded(value)
      value.round(6)
    end
  end
end
# rubocop:enable Metrics
