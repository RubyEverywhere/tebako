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
require_relative "version"

# rubocop:disable Metrics
# Tebako - an executable packager
module Tebako
  # Caches the complete post-deploy application tree by its effective inputs.
  class DeploymentCache
    SCHEMA_VERSION = 1
    MANIFEST_NAME = "manifest.json"
    TREE_NAME = "tree"
    REFERENCE_DIR = "references"

    def initialize(cache_dir:, project_root:, metadata:, excluded: [], implementation_root: nil, paths: ["."],
                   stage: "deployment")
      @cache_dir = File.expand_path(cache_dir)
      @project_root = File.expand_path(project_root)
      @metadata = stringify_and_sort(metadata)
      @excluded = excluded.compact.map { |path| File.expand_path(path) }
      @implementation_root = implementation_root || File.expand_path(__dir__)
      @paths = paths.sort
      @stage = stage
    end

    def fetch(target_dir)
      FileUtils.mkdir_p(@cache_dir)
      inputs = build_inputs
      key = digest_json(inputs)
      cache_path = File.join(@cache_dir, key)
      started_at = monotonic_time

      with_lock("#{cache_path}.lock") do
        if valid_entry?(cache_path, key)
          restore(cache_path, target_dir)
          report("reused", "all deployment inputs are unchanged", key, started_at)
          update_reference(inputs, key)
          return :hit
        end

        changed_inputs = changed_inputs_since_last_build(inputs)
        remove_invalid_entry(cache_path)
        yield
        save(cache_path, target_dir, key, inputs)
        update_reference(inputs, key)
        report("rebuilt", miss_reason(changed_inputs), key, started_at, changed_inputs)
        :miss
      end
    end

    private

    def build_inputs
      {
        "schema_version" => SCHEMA_VERSION,
        "project_tree" => Tebako::ContentManifest.digest_tree(@project_root, excluded: @excluded),
        "implementation" => Tebako::ContentManifest.digest_tree(@implementation_root),
        "tebako_version" => Tebako::VERSION,
        "paths" => @paths,
        "metadata" => @metadata
      }
    end

    def changed_inputs_since_last_build(inputs)
      previous = read_json(reference_path)
      return ["no_previous_deployment"] unless previous

      previous_inputs = previous["inputs"] || {}
      inputs.keys.reject { |name| inputs[name] == previous_inputs[name] }
    end

    def digest_json(object)
      Digest::SHA256.hexdigest(JSON.generate(object))
    end

    def manifest_path(cache_path)
      File.join(cache_path, MANIFEST_NAME)
    end

    def miss_reason(changed_inputs)
      return "no matching deployment cache entry exists" if changed_inputs == ["no_previous_deployment"]
      return "the matching deployment cache entry was missing or corrupt" if changed_inputs.empty?

      "deployment inputs changed: #{changed_inputs.join(", ")}"
    end

    def reference_key
      Digest::SHA256.hexdigest(JSON.generate([@project_root, @metadata["mode"], @metadata["ruby_api_version"]]))
    end

    def reference_path
      File.join(@cache_dir, REFERENCE_DIR, "#{reference_key}.json")
    end

    def update_reference(inputs, key)
      atomic_write_json(reference_path, "key" => key, "inputs" => inputs)
    end

    def valid_entry?(cache_path, key)
      manifest = read_json(manifest_path(cache_path))
      tree = File.join(cache_path, TREE_NAME)
      return false unless manifest && Dir.exist?(tree)
      return false unless manifest["schema_version"] == SCHEMA_VERSION && manifest["key"] == key

      if manifest["tree_stat_digest"] == Tebako::ContentManifest.stat_digest_tree(tree)
        true
      else
        manifest["tree_digest"] == Tebako::ContentManifest.digest_tree(tree)
      end
    rescue SystemCallError
      false
    end

    def restore(cache_path, target_dir)
      tree = File.join(cache_path, TREE_NAME)
      FileUtils.rm_rf(target_dir, secure: true)
      FileUtils.mkdir_p(target_dir)
      FileUtils.cp_r("#{tree}/.", target_dir, preserve: true)
      FileUtils.touch(cache_path)
      puts "   ... reusing deployed application #{File.basename(cache_path)}"
    end

    def save(cache_path, target_dir, key, inputs)
      temporary = "#{cache_path}.#{Process.pid}.#{SecureRandom.hex(6)}.tmp"
      tree = File.join(temporary, TREE_NAME)
      FileUtils.mkdir_p(tree)
      @paths.each { |path| copy_cached_path(target_dir, tree, path) }
      write_json(
        File.join(temporary, MANIFEST_NAME),
        "schema_version" => SCHEMA_VERSION,
        "key" => key,
        "inputs" => inputs,
        "tree_digest" => Tebako::ContentManifest.digest_tree(tree),
        "tree_stat_digest" => Tebako::ContentManifest.stat_digest_tree(tree)
      )
      File.rename(temporary, cache_path)
    ensure
      FileUtils.rm_rf(temporary, secure: true) if temporary && File.exist?(temporary)
    end

    def copy_cached_path(source_root, tree, relative)
      if relative == "."
        FileUtils.cp_r("#{source_root}/.", tree, preserve: true)
        return
      end

      source = File.join(source_root, relative)
      return unless File.exist?(source)

      destination = File.join(tree, relative)
      FileUtils.mkdir_p(File.dirname(destination))
      FileUtils.cp_r(source, destination, preserve: true)
    end

    def remove_invalid_entry(cache_path)
      FileUtils.rm_rf(cache_path, secure: true)
    end

    def with_lock(path)
      File.open(path, File::RDWR | File::CREAT, 0o644) do |lock|
        lock.flock(File::LOCK_EX)
        yield
      end
    end

    def report(status, reason, key, started_at, changed_inputs = nil)
      details = changed_inputs ? { "changed_inputs" => changed_inputs } : nil
      Tebako::BuildReporter.record(
        stage: @stage,
        status: status,
        reason: reason,
        key: key,
        duration: monotonic_time - started_at,
        details: details
      )
    end

    def atomic_write_json(path, object)
      FileUtils.mkdir_p(File.dirname(path))
      temporary = "#{path}.#{Process.pid}.#{SecureRandom.hex(6)}.tmp"
      write_json(temporary, object)
      File.rename(temporary, path)
    ensure
      FileUtils.rm_f(temporary) if temporary
    end

    def write_json(path, object)
      File.binwrite(path, JSON.generate(object))
    end

    def read_json(path)
      JSON.parse(File.binread(path))
    rescue JSON::ParserError, SystemCallError
      nil
    end

    def stringify_and_sort(value)
      case value
      when Hash
        value.each_with_object({}) do |(key, child), result|
          result[key.to_s] = stringify_and_sort(child)
        end.sort.to_h
      when Array
        value.map { |child| stringify_and_sort(child) }
      else
        value
      end
    end

    def monotonic_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
# rubocop:enable Metrics
