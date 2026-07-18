# frozen_string_literal: true

# Copyright (c) 2026 [RubyEverywhere](https://rubyeverywhere.com).
# All rights reserved.
# This file is a part of the Tebako project.

require "digest"
require "fileutils"
require "json"
require "securerandom"

require_relative "build_reporter"
require_relative "content_manifest"
require_relative "runtime_descriptor"
require_relative "version"

# rubocop:disable Metrics
# Tebako - an executable packager
module Tebako
  # Skips the complete application pipeline when its final output is already current.
  class ApplicationBuildState
    SCHEMA_VERSION = 1

    def initialize(cache_dir:, project_root:, metadata:, excluded: [], implementation_root: nil,
                   stage: "application_build")
      @cache_dir = cache_dir
      @project_root = project_root
      @metadata = metadata
      @excluded = excluded
      @implementation_root = implementation_root || File.expand_path(__dir__)
      @stage = stage
    end

    def fetch(output)
      state_path = state_path(output)
      FileUtils.mkdir_p(@cache_dir)
      File.open("#{state_path}.lock", File::RDWR | File::CREAT, 0o644) do |lock|
        lock.flock(File::LOCK_EX)
        key = build_key
        if current?(state_path, output, key)
          Tebako::BuildReporter.record(
            stage: @stage,
            status: "reused",
            reason: "project, runtime, options, and final package are unchanged",
            key: key
          )
          return :hit
        end

        yield
        save(state_path, output, key)
        Tebako::BuildReporter.record(
          stage: @stage,
          status: "rebuilt",
          reason: "application build inputs or final package changed",
          key: key
        )
        :miss
      end
    end

    private

    def build_key
      Digest::SHA256.hexdigest(
        JSON.generate(
          "schema_version" => SCHEMA_VERSION,
          "tebako_version" => Tebako::VERSION,
          "project_tree" => Tebako::ContentManifest.digest_tree(@project_root, excluded: @excluded),
          "implementation" => Tebako::ContentManifest.digest_tree(@implementation_root),
          "metadata" => deep_sort(@metadata)
        )
      )
    end

    def current?(state_path, output, key)
      state = JSON.parse(File.binread(state_path))
      state["schema_version"] == SCHEMA_VERSION &&
        state["key"] == key &&
        File.file?(output) &&
        state["size"] == File.size(output) &&
        state["sha256"] == Digest::SHA256.file(output).hexdigest
    rescue JSON::ParserError, SystemCallError
      false
    end

    def save(state_path, output, key)
      raise Tebako::Error, "Application package was not created at #{output}" unless File.file?(output)

      atomic_write(
        state_path,
        "schema_version" => SCHEMA_VERSION,
        "key" => key,
        "size" => File.size(output),
        "sha256" => Digest::SHA256.file(output).hexdigest
      )
    end

    def state_path(output)
      identity = Digest::SHA256.hexdigest(File.expand_path(output))
      File.join(@cache_dir, "#{identity}.json")
    end

    def atomic_write(path, data)
      temporary = "#{path}.#{Process.pid}.#{SecureRandom.hex(6)}.tmp"
      File.binwrite(temporary, JSON.generate(data))
      File.rename(temporary, path)
    ensure
      FileUtils.rm_f(temporary) if temporary
    end

    def deep_sort(value)
      case value
      when Hash
        value.to_h { |key, child| [key.to_s, deep_sort(child)] }.sort.to_h
      when Array
        value.map { |child| deep_sort(child) }
      else
        value
      end
    end
  end
end
# rubocop:enable Metrics
