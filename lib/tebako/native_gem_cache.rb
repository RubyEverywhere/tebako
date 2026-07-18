# frozen_string_literal: true

# Copyright (c) 2026 [RubyEverywhere](https://rubyeverywhere.com).
# All rights reserved.
# This file is a part of the Tebako project.

require "bundler"
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
  # Stores one installed native extension at a time for reuse across lockfiles.
  class NativeGemCache
    SCHEMA_VERSION = 1
    BUILD_ENVIRONMENT = %w[CC CXX CFLAGS CXXFLAGS CPPFLAGS LDFLAGS ARCHFLAGS].freeze
    LockedSpec = Struct.new(:name, :version, :platform, :source, keyword_init: true)

    def initialize(cache_dir:, gem_home:, lockfile:, ruby_version:)
      @cache_dir = cache_dir
      @gem_home = gem_home
      @lockfile = lockfile
      @ruby_version = ruby_version
    end

    def restore
      return 0 unless @cache_dir

      specs = locked_specs
      return 0 if specs.empty?

      FileUtils.mkdir_p(@cache_dir)
      restored = specs.count { |spec| restore_spec(spec) }
      Tebako::BuildReporter.record(
        stage: "native_gems",
        status: restored.positive? ? "reused" : "missed",
        reason: "#{restored} cached native gem artifact#{"s" unless restored == 1} restored"
      )
      restored
    end

    def save
      return 0 unless @cache_dir

      specs_by_name = locked_specs.group_by { |spec| [spec.name, spec.version.to_s] }
      return 0 if specs_by_name.empty?

      saved = installed_native_specs.count do |installed|
        requested = specs_by_name[[installed.name, installed.version.to_s]]&.first
        requested && save_spec(installed, requested)
      end
      Tebako::BuildReporter.record(
        stage: "native_gems",
        status: "saved",
        reason: "#{saved} native gem artifact#{"s" unless saved == 1} available for reuse"
      )
      saved
    end

    private

    def locked_specs
      return [] unless @lockfile && File.file?(@lockfile)

      parser = Bundler::LockfileParser.new(File.binread(@lockfile))
      parser.specs.filter_map do |spec|
        source = spec.source
        next unless source.is_a?(Bundler::Source::Rubygems)

        LockedSpec.new(
          name: spec.name,
          version: spec.version,
          platform: spec.platform.to_s,
          source: source.remotes.map(&:to_s).sort.join(",")
        )
      end
    rescue StandardError
      []
    end

    def installed_native_specs
      Dir.glob(File.join(@gem_home, "specifications", "*.gemspec")).filter_map do |path|
        specification = Gem::Specification.load(path)
        specification if specification&.extensions&.any?
      rescue StandardError
        nil
      end
    end

    def restore_spec(spec)
      key = cache_key(spec)
      cache_path = File.join(@cache_dir, key)
      with_lock("#{cache_path}.lock") do
        return false unless valid?(cache_path, key)

        FileUtils.mkdir_p(@gem_home)
        FileUtils.cp_r(File.join(cache_path, "tree", "."), @gem_home, preserve: true)
        FileUtils.touch(cache_path)
        puts "   ... restoring native gem #{spec.name} #{spec.version}"
        true
      end
    end

    def save_spec(installed, requested)
      key = cache_key(requested)
      cache_path = File.join(@cache_dir, key)
      with_lock("#{cache_path}.lock") do
        return true if valid?(cache_path, key)

        paths = artifact_paths(installed)
        return false if paths.empty?

        FileUtils.rm_rf(cache_path, secure: true)
        temporary = "#{cache_path}.#{Process.pid}.#{SecureRandom.hex(6)}.tmp"
        tree = File.join(temporary, "tree")
        FileUtils.mkdir_p(tree)
        paths.each { |path| copy_relative(path, tree) }
        manifest = {
          "schema_version" => SCHEMA_VERSION,
          "key" => key,
          "name" => installed.name,
          "version" => installed.version.to_s,
          "tree_digest" => Tebako::ContentManifest.digest_tree(tree)
        }
        File.binwrite(File.join(temporary, "manifest.json"), JSON.generate(manifest))
        FileUtils.mkdir_p(@cache_dir)
        File.rename(temporary, cache_path)
        true
      ensure
        FileUtils.rm_rf(temporary, secure: true) if temporary && File.exist?(temporary)
      end
    end

    def artifact_paths(spec)
      full_name = spec.full_name
      paths = [
        File.join(@gem_home, "gems", full_name),
        File.join(@gem_home, "specifications", "#{full_name}.gemspec"),
        File.join(@gem_home, "cache", "#{full_name}.gem")
      ]
      paths.concat(Dir.glob(File.join(@gem_home, "extensions", "**", full_name)))
      paths.select { |path| File.exist?(path) }
    end

    def copy_relative(path, tree)
      relative = path.delete_prefix("#{@gem_home}#{File::SEPARATOR}")
      destination = File.join(tree, relative)
      FileUtils.mkdir_p(File.dirname(destination))
      FileUtils.cp_r(path, destination, preserve: true)
    end

    def cache_key(spec)
      inputs = [
        SCHEMA_VERSION,
        Tebako::VERSION,
        spec.name,
        spec.version.to_s,
        spec.platform.to_s,
        spec.source.to_s,
        @ruby_version.ruby_version,
        @ruby_version.api_version,
        Gem::Platform.local.to_s
      ]
      inputs.concat(BUILD_ENVIRONMENT.map { |name| ENV.fetch(name, nil) })
      Digest::SHA256.hexdigest(inputs.join("\0"))
    end

    def valid?(cache_path, key)
      manifest = JSON.parse(File.binread(File.join(cache_path, "manifest.json")))
      tree = File.join(cache_path, "tree")
      manifest["schema_version"] == SCHEMA_VERSION &&
        manifest["key"] == key &&
        Dir.exist?(tree) &&
        manifest["tree_digest"] == Tebako::ContentManifest.digest_tree(tree)
    rescue JSON::ParserError, SystemCallError
      false
    end

    def with_lock(path)
      FileUtils.mkdir_p(File.dirname(path))
      File.open(path, File::RDWR | File::CREAT, 0o644) do |lock|
        lock.flock(File::LOCK_EX)
        yield
      end
    end
  end
end
# rubocop:enable Metrics
