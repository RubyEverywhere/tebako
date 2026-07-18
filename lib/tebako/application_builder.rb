# frozen_string_literal: true

# Copyright (c) 2026 [RubyEverywhere](https://rubyeverywhere.com).
# All rights reserved.
# This file is a part of the Tebako project.

require_relative "build_reporter"
require_relative "application_build_state"
require_relative "packager_lite"
require_relative "runtime_descriptor"

# rubocop:disable Metrics
# Tebako - an executable packager
module Tebako
  # Builds an application payload against a previously selected runtime.
  class ApplicationBuilder
    def initialize(options_manager, scenario_manager)
      @opts = options_manager
      @scm = scenario_manager
    end

    def build
      validate_runtime
      packager = Tebako::PackagerLite.new(@opts, @scm)
      return packager.create_package unless @opts.deployment_cache?

      build_state.fetch(packager.name) { packager.create_package }
    end

    private

    def build_state
      @build_state ||= Tebako::ApplicationBuildState.new(
        cache_dir: @opts.application_cache_dir,
        project_root: @opts.root,
        excluded: build_exclusions,
        metadata: build_metadata
      )
    end

    def build_exclusions
      [@opts.prefix, @opts.package, "#{@opts.package}.tebako"].select do |path|
        @opts.folder_within_root?(path)
      end
    end

    def build_metadata
      {
        "ruby_version" => @opts.ruby_ver,
        "ruby_api_version" => @opts.rv.api_version,
        "mode" => @opts.mode,
        "entry_point" => @scm.fs_entrance,
        "cwd" => @opts.cwd,
        "compression_level" => @opts.compression_level,
        "layer_strategy" => @opts.layer_strategy,
        "runtime_identity" => runtime_identity
      }
    end

    def runtime_identity
      path = Tebako::RuntimeDescriptor.path_for(runtime_path)
      File.file?(path) ? Tebako::RuntimeDescriptor.load(path).identity : nil
    end

    def validate_runtime
      descriptor_path = Tebako::RuntimeDescriptor.path_for(runtime_path)
      unless File.file?(descriptor_path)
        Tebako::BuildReporter.record(
          stage: "runtime_resolution",
          status: "legacy",
          reason: "no runtime capability descriptor was found"
        )
        return
      end

      descriptor = Tebako::RuntimeDescriptor.load(descriptor_path)
      descriptor.compatible!(
        ruby_version: @opts.ruby_ver,
        ruby_api_version: @opts.rv.api_version,
        package_format: @opts.mode == "both" ? "layered" : "monolithic"
      )
      Tebako::BuildReporter.record(
        stage: "runtime_resolution",
        status: "reused",
        reason: "runtime capabilities are compatible",
        key: descriptor.identity
      )
    end

    def runtime_path
      path = @opts.mode == "both" ? @opts.package : @opts.ref
      "#{path}#{@scm.exe_suffix}"
    end
  end
end
# rubocop:enable Metrics
