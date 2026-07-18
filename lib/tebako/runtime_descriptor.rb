# frozen_string_literal: true

# Copyright (c) 2026 [RubyEverywhere](https://rubyeverywhere.com).
# All rights reserved.
# This file is a part of the Tebako project.

require "digest"
require "fileutils"
require "json"
require "rbconfig"
require "securerandom"

require_relative "content_manifest"
require_relative "error"
require_relative "version"

# rubocop:disable Metrics
# Tebako - an executable packager
module Tebako
  # Versioned machine-readable identity and capabilities of a Tebako runtime.
  class RuntimeDescriptor
    SCHEMA_VERSION = 1
    PACKAGE_FORMATS = { "monolithic" => 1, "layered" => 1 }.freeze
    RUNTIME_SOURCE_PATHS = %w[
      CMakeLists.txt
      cmake
      include
      src
      lib/tebako/build_helpers.rb
      lib/tebako/codegen.rb
      lib/tebako/content_manifest.rb
      lib/tebako/deploy_helper.rb
      lib/tebako/error.rb
      lib/tebako/filesystem_cache.rb
      lib/tebako/generated
      lib/tebako/native_gem_cache.rb
      lib/tebako/options_manager.rb
      lib/tebako/packager
      lib/tebako/packager.rb
      lib/tebako/ruby_builder.rb
      lib/tebako/ruby_version.rb
      lib/tebako/scenario_manager.rb
      lib/tebako/stripper.rb
      lib/tebako/version.rb
    ].freeze

    attr_reader :data

    class << self
      def build(options_manager)
        identity_inputs = {
          "schema_version" => SCHEMA_VERSION,
          "tebako_version" => Tebako::VERSION,
          "ruby_version" => options_manager.ruby_ver,
          "ruby_api_version" => options_manager.rv.api_version,
          "platform" => RUBY_PLATFORM,
          "architecture" => RbConfig::CONFIG["host_cpu"],
          "host_os" => RbConfig::CONFIG["host_os"],
          "compression_level" => options_manager.compression_level,
          "log_level" => options_manager.l_level,
          "package_formats" => PACKAGE_FORMATS
        }
        identity_inputs["build_environment"] = build_environment
        identity_inputs["source_identity"] = source_identity(options_manager.source)
        identity = Digest::SHA256.hexdigest(JSON.generate(identity_inputs))
        new(identity_inputs.merge("runtime_identity" => "tebako-runtime-v1-#{identity}"))
      end

      def load(path)
        new(JSON.parse(File.binread(path)))
      rescue JSON::ParserError, SystemCallError => e
        raise Tebako::Error.new("Unable to read runtime descriptor '#{path}': #{e.message}", 120)
      end

      def path_for(runtime)
        "#{runtime}.runtime.json"
      end

      private

      def build_environment
        %w[CC CXX CFLAGS CXXFLAGS CPPFLAGS LDFLAGS ARCHFLAGS].to_h do |name|
          [name, ENV.fetch(name, nil)]
        end
      end

      def source_identity(source)
        paths = RUNTIME_SOURCE_PATHS.map { |path| File.join(source, path) }
        digests = paths.select { |path| File.exist?(path) }.map do |path|
          [path.delete_prefix("#{source}/"), Tebako::ContentManifest.digest_tree(path)]
        end
        Digest::SHA256.hexdigest(JSON.generate(digests))
      end
    end

    def initialize(data)
      @data = data.transform_keys(&:to_s)
      validate_schema!
    end

    def identity
      @data.fetch("runtime_identity")
    end

    def write(path)
      FileUtils.mkdir_p(File.dirname(File.expand_path(path)))
      temporary = "#{path}.#{Process.pid}.#{SecureRandom.hex(6)}.tmp"
      File.binwrite(temporary, JSON.pretty_generate(@data))
      File.rename(temporary, path)
      path
    ensure
      FileUtils.rm_f(temporary) if temporary
    end

    def compatible!(ruby_version:, ruby_api_version:, platform: RUBY_PLATFORM, package_format: nil)
      mismatches = []
      mismatches << "Ruby #{@data["ruby_version"]} (requested #{ruby_version})" if @data["ruby_version"] != ruby_version
      if @data["ruby_api_version"] != ruby_api_version
        mismatches << "Ruby ABI #{@data["ruby_api_version"]} (requested #{ruby_api_version})"
      end
      mismatches << "platform #{@data["platform"]} (host #{platform})" if @data["platform"] != platform
      if package_format && !@data.fetch("package_formats", {}).key?(package_format)
        mismatches << "package format #{package_format}"
      end
      return true if mismatches.empty?

      raise Tebako::Error.new("Runtime is incompatible: #{mismatches.join(", ")}", 120)
    end

    private

    def validate_schema!
      return if @data["schema_version"] == SCHEMA_VERSION

      raise Tebako::Error.new(
        "Unsupported runtime descriptor schema #{@data["schema_version"].inspect}; expected #{SCHEMA_VERSION}",
        120
      )
    end
  end
end
# rubocop:enable Metrics
