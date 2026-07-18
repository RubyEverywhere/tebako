# frozen_string_literal: true

# Copyright (c) 2026 [RubyEverywhere](https://rubyeverywhere.com).
# All rights reserved.
# This file is a part of the Tebako project.

require "digest"
require "fileutils"
require "json"
require "securerandom"
require "time"

require_relative "layered_package"

# rubocop:disable Metrics
# Tebako - an executable packager
module Tebako
  # Content-addressed package releases with verified atomic activation and rollback.
  class ReleaseStore
    SCHEMA_VERSION = 1

    def initialize(root)
      @root = File.expand_path(root)
      @objects = File.join(@root, "objects", "sha256")
      @releases = File.join(@root, "releases")
      @history = File.join(@root, "history.json")
      @lock = File.join(@root, "update.lock")
    end

    def import(package_path)
      inspection = Tebako::LayeredPackage.inspect(package_path)
      package = File.binread(package_path)
      FileUtils.mkdir_p([@objects, @releases])
      new_objects = 0
      new_objects += 1 if store_object(inspection.sha256, package)
      layers = inspection.layers.map do |layer|
        payload = package.byteslice(layer.offset, layer.byte_size)
        new_objects += 1 if store_object(layer.sha256, payload)
        {
          "mount_point" => layer.mount_point,
          "sha256" => layer.sha256,
          "size" => layer.byte_size
        }
      end
      release = {
        "schema_version" => SCHEMA_VERSION,
        "release_id" => inspection.sha256,
        "package_sha256" => inspection.sha256,
        "package_size" => inspection.byte_size,
        "format" => inspection.format,
        "format_version" => "#{inspection.major_version}.#{inspection.minor_version}",
        "layers" => layers
      }
      atomic_write_json(release_path(inspection.sha256), release)
      release.merge("new_objects" => new_objects)
    end

    def activate(release_id, target)
      with_lock do
        release = load_release(release_id)
        package_object = object_path(release.fetch("package_sha256"))
        verify_object!(package_object, release.fetch("package_sha256"), release.fetch("package_size"))
        previous = File.file?(target) ? Digest::SHA256.file(target).hexdigest : nil
        publish_target(package_object, target)
        append_history(release_id, previous)
        release
      end
    end

    def rollback(target)
      with_lock do
        history = read_history
        raise ArgumentError, "No previous release is available" if history.length < 2

        history.pop
        previous = history.last.fetch("release_id")
        release = load_release(previous)
        package_object = object_path(release.fetch("package_sha256"))
        verify_object!(package_object, release.fetch("package_sha256"), release.fetch("package_size"))
        publish_target(package_object, target)
        atomic_write_json(@history, history)
        release
      end
    end

    def status
      {
        "schema_version" => SCHEMA_VERSION,
        "history" => read_history,
        "objects" => Dir.exist?(@objects) ? Dir.children(@objects).length : 0,
        "releases" => Dir.exist?(@releases) ? Dir.glob(File.join(@releases, "*.json")).length : 0
      }
    end

    private

    def store_object(digest, content)
      path = object_path(digest)
      return false if valid_object?(path, digest, content.bytesize)

      FileUtils.mkdir_p(File.dirname(path))
      FileUtils.rm_f(path)
      temporary = "#{path}.#{Process.pid}.#{SecureRandom.hex(6)}.tmp"
      File.binwrite(temporary, content)
      File.rename(temporary, path)
      true
    ensure
      FileUtils.rm_f(temporary) if temporary
    end

    def publish_target(source, target)
      target = File.expand_path(target)
      FileUtils.mkdir_p(File.dirname(target))
      temporary = "#{target}.#{Process.pid}.#{SecureRandom.hex(6)}.tmp"
      FileUtils.cp(source, temporary, preserve: true)
      File.rename(temporary, target)
    ensure
      FileUtils.rm_f(temporary) if temporary
    end

    def append_history(release_id, previous_digest)
      history = read_history
      if history.empty? && previous_digest && File.file?(object_path(previous_digest))
        history << { "release_id" => previous_digest, "activated_at" => Time.now.utc.iso8601 }
      end
      history.reject! { |entry| entry["release_id"] == release_id }
      history << { "release_id" => release_id, "activated_at" => Time.now.utc.iso8601 }
      atomic_write_json(@history, history)
    end

    def read_history
      JSON.parse(File.binread(@history))
    rescue JSON::ParserError, SystemCallError
      []
    end

    def load_release(release_id)
      release = JSON.parse(File.binread(release_path(release_id)))
      raise ArgumentError, "Unsupported release schema" unless release["schema_version"] == SCHEMA_VERSION

      release
    rescue JSON::ParserError, SystemCallError => e
      raise ArgumentError, "Release #{release_id} is unavailable: #{e.message}"
    end

    def verify_object!(path, digest, size)
      return true if valid_object?(path, digest, size)

      raise ArgumentError, "Release object #{digest} is missing or corrupt"
    end

    def valid_object?(path, digest, size)
      File.file?(path) && File.size(path) == size && Digest::SHA256.file(path).hexdigest == digest
    end

    def object_path(digest)
      validate_digest!(digest)
      File.join(@objects, digest)
    end

    def release_path(release_id)
      validate_digest!(release_id)
      File.join(@releases, "#{release_id}.json")
    end

    def validate_digest!(digest)
      return if digest.match?(/\A[0-9a-f]{64}\z/)

      raise ArgumentError, "Invalid release identity"
    end

    def atomic_write_json(path, object)
      FileUtils.mkdir_p(File.dirname(path))
      temporary = "#{path}.#{Process.pid}.#{SecureRandom.hex(6)}.tmp"
      File.write(temporary, JSON.pretty_generate(object))
      File.rename(temporary, path)
    ensure
      FileUtils.rm_f(temporary) if temporary
    end

    def with_lock
      FileUtils.mkdir_p(@root)
      File.open(@lock, File::RDWR | File::CREAT, 0o644) do |lock|
        lock.flock(File::LOCK_EX)
        yield
      end
    end
  end
end
# rubocop:enable Metrics
