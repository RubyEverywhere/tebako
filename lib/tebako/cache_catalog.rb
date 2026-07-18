# frozen_string_literal: true

# Copyright (c) 2026 [RubyEverywhere](https://rubyeverywhere.com).
# All rights reserved.
# This file is a part of the Tebako project.

require "digest"
require "fileutils"
require "find"
require "json"
require "time"

require_relative "content_manifest"

# rubocop:disable Metrics
# Tebako - an executable packager
module Tebako
  # Readable, bounded view over all fast-build caches.
  class CacheCatalog
    Entry = Struct.new(:type, :key, :path, :byte_size, :last_used, :valid, keyword_init: true) do
      def to_h
        {
          "type" => type,
          "key" => key,
          "path" => path,
          "size" => byte_size,
          "last_used" => last_used.utc.iso8601,
          "valid" => valid
        }
      end
    end

    CACHE_TYPES = {
      "application" => "application-cache",
      "bundle" => "bundle-cache",
      "deployment" => "deployment-cache",
      "finalized_runtime" => "finalized-runtime-cache",
      "filesystem" => "filesystem-cache",
      "native_gem" => "native-gem-cache",
      "runtime_deployment" => "runtime-deployment-cache"
    }.freeze

    def initialize(deps)
      @deps = File.expand_path(deps)
    end

    def entries
      CACHE_TYPES.flat_map { |type, directory| scan(type, File.join(@deps, directory)) }
    end

    def stats
      all = entries
      {
        "entries" => all.length,
        "bytes" => all.sum(&:byte_size),
        "valid" => all.count(&:valid),
        "invalid" => all.count { |entry| entry.valid == false },
        "by_type" => all.group_by(&:type).transform_values do |typed|
          { "entries" => typed.length, "bytes" => typed.sum(&:byte_size) }
        end
      }
    end

    def verify
      entries.select { |entry| entry.valid == false }
    end

    def prune(max_size: nil, older_than: nil)
      all = entries.sort_by(&:last_used)
      cutoff = older_than && (Time.now - older_than)
      total = all.sum(&:byte_size)
      removed = []
      all.each do |entry|
        eligible_by_age = cutoff && entry.last_used < cutoff
        eligible_by_size = max_size && total > max_size
        next unless eligible_by_age || eligible_by_size
        next unless remove_unless_locked(entry)

        removed << entry
        total -= entry.byte_size
      end
      removed
    end

    def clean
      CACHE_TYPES.each_value do |directory|
        path = File.join(@deps, directory)
        FileUtils.rm_rf(path, secure: true)
      end
    end

    def remove(key)
      matches = entries.select { |entry| entry.key == key || "#{entry.type}:#{entry.key}" == key }
      matches.select { |entry| remove_unless_locked(entry) }
    end

    private

    def scan(type, directory)
      return [] unless Dir.exist?(directory)

      case type
      when "application"
        Dir.glob(File.join(directory, "*.json")).map { |path| application_entry(path) }
      when "filesystem"
        Dir.glob(File.join(directory, "*.dwarfs")).map { |path| filesystem_entry(path) }
      else
        Dir.children(directory).filter_map do |name|
          path = File.join(directory, name)
          next unless File.directory?(path)
          next if type == "deployment" && name == "references"

          directory_entry(type, name, path)
        end
      end
    end

    def application_entry(path)
      metadata = read_json(path)
      valid = metadata &&
              metadata["schema_version"] == 1 &&
              metadata["key"]&.match?(/\A[0-9a-f]{64}\z/) &&
              metadata["sha256"]&.match?(/\A[0-9a-f]{64}\z/)
      entry("application", File.basename(path, ".json"), path, valid)
    end

    def filesystem_entry(path)
      metadata = read_json("#{path}.json")
      valid = metadata &&
              metadata["schema_version"] == 1 &&
              metadata["size"] == File.size(path) &&
              metadata["sha256"] == Digest::SHA256.file(path).hexdigest
      entry("filesystem", File.basename(path, ".dwarfs"), path, valid)
    end

    def directory_entry(type, key, path)
      manifest = read_json(File.join(path, "manifest.json"))
      valid = case type
              when "deployment", "native_gem", "runtime_deployment"
                tree = File.join(path, "tree")
                manifest &&
                Dir.exist?(tree) &&
                manifest["tree_digest"] == Tebako::ContentManifest.digest_tree(tree)
              when "finalized_runtime"
                runtime = File.join(path, "runtime")
                manifest &&
                File.file?(runtime) &&
                manifest["size"] == File.size(runtime) &&
                manifest["sha256"] == Digest::SHA256.file(runtime).hexdigest
              end
      entry(type, key, path, valid)
    rescue SystemCallError
      entry(type, key, path, false)
    end

    def entry(type, key, path, valid)
      Entry.new(
        type: type,
        key: key,
        path: path,
        byte_size: path_size(path),
        last_used: File.mtime(path),
        valid: valid
      )
    end

    def path_size(path)
      return File.size(path) if File.file?(path)

      size = 0
      Find.find(path) { |child| size += File.size(child) if File.file?(child) }
      size
    end

    def read_json(path)
      JSON.parse(File.binread(path))
    rescue JSON::ParserError, SystemCallError
      nil
    end

    def remove_unless_locked(entry)
      lock_path = "#{entry.path}.lock"
      File.open(lock_path, File::RDWR | File::CREAT, 0o644) do |lock|
        return false unless lock.flock(File::LOCK_EX | File::LOCK_NB)

        FileUtils.rm_rf(entry.path, secure: true)
        FileUtils.rm_f("#{entry.path}.json")
        true
      end
    rescue Errno::EWOULDBLOCK
      false
    end
  end
end
# rubocop:enable Metrics
