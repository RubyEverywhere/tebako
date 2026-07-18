# frozen_string_literal: true

# Copyright (c) 2026 [RubyEverywhere](https://rubyeverywhere.com).
# All rights reserved.
# This file is a part of the Tebako project.

require "digest"
require "fileutils"
require "json"
require "pathname"
require "rubygems/package"
require "securerandom"
require "zlib"

require_relative "error"
require_relative "runtime_descriptor"

# rubocop:disable Metrics
# Tebako - an executable packager
module Tebako
  # Creates and installs verified, relocatable runtime SDK archives.
  class RuntimeSdk
    SCHEMA_VERSION = 1
    MANIFEST_PATH = "tebako-sdk-manifest.json"

    class << self
      def pack(output:, components:, descriptor:)
        entries = collect_entries(components)
        manifest = sdk_manifest(entries, descriptor)
        temporary = "#{output}.#{Process.pid}.#{SecureRandom.hex(6)}.tmp"
        FileUtils.mkdir_p(File.dirname(File.expand_path(output)))
        write_archive(temporary, entries, manifest)
        File.rename(temporary, output)
        output
      ensure
        FileUtils.rm_f(temporary) if temporary
      end

      def install(archive:, destination:)
        temporary = "#{File.expand_path(destination)}.#{Process.pid}.#{SecureRandom.hex(6)}.tmp"
        FileUtils.rm_rf(temporary, secure: true)
        FileUtils.mkdir_p(temporary)
        manifest = extract_and_verify(archive, temporary)
        publish_install(temporary, destination)
        manifest
      ensure
        FileUtils.rm_rf(temporary, secure: true) if temporary && File.exist?(temporary)
      end

      private

      def collect_entries(components)
        entries = []
        components.sort.each do |mount, source|
          source = File.expand_path(source)
          raise Tebako::Error.new("Runtime SDK component does not exist: #{source}", 121) unless File.exist?(source)

          collect_entry(entries, mount.to_s, source)
        end
        entries.sort_by { |entry| entry.fetch("path") }
      end

      def collect_entry(entries, logical_path, source)
        stat = File.lstat(source)
        entry = {
          "path" => clean_archive_path(logical_path),
          "type" => stat.ftype,
          "mode" => stat.mode & 0o7777
        }
        if stat.file?
          entry["size"] = stat.size
          entry["sha256"] = Digest::SHA256.file(source).hexdigest
        elsif stat.symlink?
          entry["target"] = File.readlink(source)
        end
        entry["source"] = source
        entries << entry
        return unless stat.directory?

        Dir.children(source).sort.each do |name|
          collect_entry(entries, File.join(logical_path, name), File.join(source, name))
        end
      end

      def sdk_manifest(entries, descriptor)
        {
          "schema_version" => SCHEMA_VERSION,
          "runtime_identity" => descriptor.identity,
          "runtime_descriptor" => descriptor.data,
          "entries" => entries.map { |entry| entry.reject { |key, _value| key == "source" } }
        }
      end

      def write_archive(path, entries, manifest)
        File.open(path, "wb") do |archive|
          gzip = Zlib::GzipWriter.new(archive)
          gzip.mtime = 0
          Gem::Package::TarWriter.new(gzip) do |tar|
            manifest_json = JSON.generate(manifest)
            tar.add_file_simple(MANIFEST_PATH, 0o644, manifest_json.bytesize) { |io| io.write(manifest_json) }
            entries.each { |entry| write_entry(tar, entry) }
          end
          gzip.close
        end
      end

      def write_entry(tar, entry)
        case entry.fetch("type")
        when "directory"
          tar.mkdir(entry.fetch("path"), entry.fetch("mode"))
        when "file"
          tar.add_file_simple(entry.fetch("path"), entry.fetch("mode"), entry.fetch("size")) do |io|
            File.open(entry.fetch("source"), "rb") { |file| IO.copy_stream(file, io) }
          end
        when "link"
          tar.add_symlink(entry.fetch("path"), entry.fetch("target"), entry.fetch("mode"))
        else
          raise Tebako::Error.new("Unsupported SDK file type #{entry.fetch("type")}", 121)
        end
      end

      def extract_and_verify(archive, destination)
        manifest = nil
        extracted = {}
        symlinks = []
        Zlib::GzipReader.open(archive) do |gzip|
          Gem::Package::TarReader.new(gzip) do |tar|
            tar.each do |entry|
              path = clean_archive_path(entry.full_name)
              if path == MANIFEST_PATH
                manifest = JSON.parse(entry.read)
                next
              end
              target = safe_destination(destination, path)
              if entry.directory?
                FileUtils.mkdir_p(target)
              elsif entry.file?
                FileUtils.mkdir_p(File.dirname(target))
                File.open(target, "wb") { |file| IO.copy_stream(entry, file) }
              elsif entry.header.typeflag == "2"
                symlinks << [target, entry.header.linkname]
              end
              FileUtils.chmod(entry.header.mode & 0o7777, target) unless entry.header.typeflag == "2"
              extracted[path] = extracted_entry(entry, target)
            end
          end
        end
        validate_manifest!(manifest, extracted)
        symlinks.each { |target, link| create_safe_symlink(destination, target, link) }
        manifest
      rescue JSON::ParserError, Zlib::Error, Gem::Package::TarInvalidError, SystemCallError => e
        raise Tebako::Error.new("Runtime SDK verification failed: #{e.message}", 121)
      end

      def extracted_entry(entry, target)
        result = {
          "path" => clean_archive_path(entry.full_name),
          "type" => if entry.directory?
                      "directory"
                    else
                      entry.file? ? "file" : "link"
                    end,
          "mode" => entry.header.mode & 0o7777
        }
        if entry.file?
          result["size"] = File.size(target)
          result["sha256"] = Digest::SHA256.file(target).hexdigest
        elsif result["type"] == "link"
          result["target"] = entry.header.linkname
        end
        result
      end

      def validate_manifest!(manifest, extracted)
        raise Tebako::Error.new("Runtime SDK manifest is missing", 121) unless manifest
        unless manifest["schema_version"] == SCHEMA_VERSION
          raise Tebako::Error.new("Unsupported runtime SDK schema #{manifest["schema_version"].inspect}", 121)
        end

        expected = manifest.fetch("entries").to_h { |entry| [entry.fetch("path"), entry] }
        raise Tebako::Error.new("Runtime SDK contents do not match its manifest", 121) unless expected == extracted

        Tebako::RuntimeDescriptor.new(manifest.fetch("runtime_descriptor"))
      end

      def create_safe_symlink(root, target, link)
        raise Tebako::Error.new("Unsafe absolute SDK symlink: #{link}", 121) if Pathname.new(link).absolute?

        resolved = File.expand_path(link, File.dirname(target))
        root = File.expand_path(root)
        unless resolved == root || resolved.start_with?("#{root}#{File::SEPARATOR}")
          raise Tebako::Error.new("SDK symlink escapes installation root: #{link}", 121)
        end

        FileUtils.mkdir_p(File.dirname(target))
        File.symlink(link, target)
      end

      def publish_install(temporary, destination)
        destination = File.expand_path(destination)
        backup = "#{destination}.previous"
        FileUtils.rm_rf(backup, secure: true)
        File.rename(destination, backup) if File.exist?(destination)
        File.rename(temporary, destination)
        FileUtils.rm_rf(backup, secure: true)
      rescue StandardError
        File.rename(backup, destination) if File.exist?(backup) && !File.exist?(destination)
        raise
      end

      def clean_archive_path(path)
        path = path.to_s.tr("\\", "/").sub(%r{\A\./}, "")
        components = path.split("/")
        if path.empty? || path.start_with?("/") || components.any? { |component| component.empty? || component == ".." }
          raise Tebako::Error.new("Unsafe runtime SDK path: #{path.inspect}", 121)
        end

        path
      end

      def safe_destination(root, path)
        target = File.expand_path(path, root)
        root = File.expand_path(root)
        return target if target.start_with?("#{root}#{File::SEPARATOR}")

        raise Tebako::Error.new("Runtime SDK path escapes installation root: #{path}", 121)
      end
    end
  end
end
# rubocop:enable Metrics
