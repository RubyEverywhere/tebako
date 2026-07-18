# frozen_string_literal: true

# Copyright (c) 2026 [RubyEverywhere](https://rubyeverywhere.com).
# All rights reserved.
# This file is a part of the Tebako project.

require_relative "application_build_state"

# Tebako - an executable packager
module Tebako
  # Coordinates creation of a standalone Ruby/Tebako/application executable.
  class BundleBuilder
    def initialize(options_manager, scenario_manager)
      @opts = options_manager
      @scm = scenario_manager
    end

    def build(&block)
      return block.call unless @opts.deployment_cache?

      build_state.fetch(output, &block)
    end

    private

    def build_state
      @build_state ||= Tebako::ApplicationBuildState.new(
        cache_dir: @opts.application_cache_dir,
        project_root: @opts.root,
        excluded: build_exclusions,
        metadata: build_metadata,
        stage: "bundle_build"
      )
    end

    def build_exclusions
      [@opts.prefix, output].select { |path| @opts.folder_within_root?(path) }
    end

    def build_metadata
      {
        "ruby_version" => @opts.ruby_ver,
        "ruby_api_version" => @opts.rv.api_version,
        "platform" => RUBY_PLATFORM, "mode" => "bundle",
        "entry_point" => @scm.fs_entrance,
        "cwd" => @opts.cwd,
        "compression_level" => @opts.compression_level,
        "log_level" => @opts.l_level,
        "patchelf" => @opts.patchelf?
      }
    end

    def output
      "#{@opts.package}#{@scm.exe_suffix}"
    end
  end
end
