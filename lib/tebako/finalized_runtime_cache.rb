# frozen_string_literal: true

# Copyright (c) 2026 [RubyEverywhere](https://rubyeverywhere.com).
# All rights reserved.
# This file is a part of the Tebako project.

require "digest"
require "fileutils"
require "json"
require "securerandom"

require_relative "build_reporter"
require_relative "runtime_descriptor"

# rubocop:disable Metrics
# Tebako - an executable packager
module Tebako
  # Stores verified, application-independent runtime executables by identity.
  class FinalizedRuntimeCache
    SCHEMA_VERSION = 1
    MANIFEST = "manifest.json"
    RUNTIME = "runtime"

    def initialize(cache_dir:, descriptor:, exe_suffix: "")
      @cache_dir = File.expand_path(cache_dir)
      @descriptor = descriptor
      @exe_suffix = exe_suffix
    end

    def fetch(&block)
      FileUtils.mkdir_p(@cache_dir)
      path = File.join(@cache_dir, @descriptor.identity)
      started_at = monotonic_time
      with_lock("#{path}.lock") do
        if valid?(path)
          FileUtils.touch(path)
          report("reused", "finalized runtime identity is unchanged", started_at)
          return runtime_path(path)
        end

        publish(path, &block)
        report("rebuilt", "no matching finalized runtime executable exists", started_at)
        runtime_path(path)
      end
    end

    def import(runtime)
      source = File.expand_path(runtime)
      descriptor_source = Tebako::RuntimeDescriptor.path_for(source)
      raise Tebako::Error.new("Finalized runtime does not exist: #{source}", 120) unless File.file?(source)
      unless File.file?(descriptor_source)
        raise Tebako::Error.new("Finalized runtime descriptor is missing: #{descriptor_source}", 120)
      end

      imported_descriptor = Tebako::RuntimeDescriptor.load(descriptor_source)
      unless imported_descriptor.data == @descriptor.data
        raise Tebako::Error.new("Finalized runtime descriptor is inconsistent", 120)
      end

      fetch do |target_base|
        target = "#{target_base}#{@exe_suffix}"
        FileUtils.cp(source, target, preserve: true)
        FileUtils.cp(descriptor_source, Tebako::RuntimeDescriptor.path_for(target), preserve: true)
      end
    end

    private

    def publish(path)
      FileUtils.rm_rf(path, secure: true)
      temporary = "#{path}.#{Process.pid}.#{SecureRandom.hex(6)}.tmp"
      FileUtils.mkdir_p(temporary)
      runtime = runtime_path(temporary)
      yield File.join(temporary, RUNTIME)
      descriptor_source = Tebako::RuntimeDescriptor.path_for(runtime)
      raise Tebako::Error.new("Finalized runtime was not created at #{runtime}", 120) unless File.file?(runtime)
      raise Tebako::Error.new("Finalized runtime descriptor is missing", 120) unless File.file?(descriptor_source)

      descriptor = Tebako::RuntimeDescriptor.load(descriptor_source)
      unless descriptor.identity == @descriptor.identity
        raise Tebako::Error.new("Finalized runtime identity is inconsistent", 120)
      end

      write_manifest(temporary, runtime)
      File.rename(temporary, path)
    ensure
      FileUtils.rm_rf(temporary, secure: true) if temporary && File.exist?(temporary)
    end

    def write_manifest(path, runtime)
      File.binwrite(
        File.join(path, MANIFEST),
        JSON.generate(
          "schema_version" => SCHEMA_VERSION,
          "runtime_identity" => @descriptor.identity,
          "size" => File.size(runtime),
          "sha256" => Digest::SHA256.file(runtime).hexdigest
        )
      )
    end

    def valid?(path)
      manifest = JSON.parse(File.binread(File.join(path, MANIFEST)))
      runtime = runtime_path(path)
      descriptor_path = Tebako::RuntimeDescriptor.path_for(runtime)
      descriptor = Tebako::RuntimeDescriptor.load(descriptor_path)
      manifest["schema_version"] == SCHEMA_VERSION &&
        manifest["runtime_identity"] == @descriptor.identity &&
        descriptor.identity == @descriptor.identity &&
        File.file?(runtime) &&
        manifest["size"] == File.size(runtime) &&
        manifest["sha256"] == Digest::SHA256.file(runtime).hexdigest
    rescue JSON::ParserError, SystemCallError, Tebako::Error
      false
    end

    def with_lock(path)
      File.open(path, File::RDWR | File::CREAT, 0o644) do |lock|
        lock.flock(File::LOCK_EX)
        yield
      end
    end

    def runtime_path(path)
      File.join(path, "#{RUNTIME}#{@exe_suffix}")
    end

    def report(status, reason, started_at)
      Tebako::BuildReporter.record(
        stage: "finalized_runtime",
        status: status,
        reason: reason,
        key: @descriptor.identity,
        duration: monotonic_time - started_at
      )
    end

    def monotonic_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
# rubocop:enable Metrics
