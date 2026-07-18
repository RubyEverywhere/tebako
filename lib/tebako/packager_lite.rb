# frozen_string_literal: true

# Copyright (c) 2023-2025 [Ribose Inc](https://www.ribose.com).
# All rights reserved.
# This file is a part of the Tebako project.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
# 1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
# ``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED
# TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
# PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDERS OR CONTRIBUTORS
# BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
# CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
# SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
# INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
# CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
# ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
# POSSIBILITY OF SUCH DAMAGE.

require "pathname"
require "fileutils"

require_relative "deployment_cache"
require_relative "layered_package"
require_relative "layer_planner"
require_relative "options_manager"
require_relative "package_descriptor"
require_relative "packager"
require_relative "scenario_manager"

# rubocop:disable Metrics
module Tebako
  # Tebako application package descriptor
  class PackagerLite
    DEPLOYMENT_ENVIRONMENT = %w[
      ARCHFLAGS
      BUNDLE_DEPLOYMENT
      BUNDLE_FORCE_RUBY_PLATFORM
      BUNDLE_FROZEN
      BUNDLE_WITH
      BUNDLE_WITHOUT
      CFLAGS
      CPPFLAGS
      CXXFLAGS
      LDFLAGS
    ].freeze

    def initialize(options_manager, scenario_manager)
      @opts = options_manager
      @scm = scenario_manager
      @scm.configure_scenario
    end

    def codegen
      puts "-- Generating files"
      return Tebako::Codegen.generate_package_descriptor(@opts, @scm) unless layered?

      Tebako::Codegen.generate_package_descriptor(@opts, @scm, mount_point: application_mount_point)
    end

    def create_implib
      rv = Tebako::RubyVersion.new(@opts.ruby_ver)
      bname = if @opts.mode == "application"
                @opts.ref
              else # @opts.mode == "both"
                @opts.package
              end
      Tebako::Packager.create_implib(@opts.ruby_src_dir, @opts.data_src_dir, bname, rv)
    end

    def create_package
      deploy
      FileUtils.rm_f(name)
      layered? ? create_layered_package : create_monolithic_package
      Tebako::BuildReporter.record(
        stage: "application_package",
        status: "rebuilt",
        reason: "application package assembly completed"
      )
      puts "Created tebako #{@opts.output_type_second} at \"#{name}\""
    end

    def create_monolithic_package
      Tebako::Packager.mkdwarfs(@opts.deps_bin_dir, name, @opts.data_src_dir, codegen, @opts.compression_level,
                                @opts.filesystem_cache_dir)
    end

    def create_layered_package
      descriptor = codegen
      layers = package_layers.map do |mount_point, source|
        image = layer_image(mount_point)
        Tebako::Packager.mkdwarfs(@opts.deps_bin_dir, image, source, nil, @opts.compression_level,
                                  @opts.filesystem_cache_dir)
        Tebako::LayeredPackage::Layer.new(mount_point: mount_point, path: image)
      end
      Tebako::LayeredPackage.write(name, descriptor: descriptor, layers: layers)
    end

    def deploy
      return deploy_uncached if !@opts.deployment_cache? || layered?

      deployment_cache.fetch(@opts.data_src_dir) do
        deploy_uncached
      end
    end

    def name
      bname = Pathname.new(@opts.package).cleanpath.to_s
      @name ||= "#{bname}.tebako"
    end

    private

    def deploy_uncached
      if layered?
        Tebako::Packager.init_application(@opts.data_src_dir, @opts.data_pre_dir, @opts.data_bin_dir)
      elsif @opts.deployment_cache?
        restore_runtime_deployment
      else
        Tebako::Packager.init(@opts.stash_dir, @opts.data_src_dir, @opts.data_pre_dir, @opts.data_bin_dir,
                              preserve_bin: true)
      end
      create_implib if @scm.msys?
      Tebako::Packager.deploy(@opts.data_src_dir, @opts.data_pre_dir, @opts.rv, @opts.root, @scm.fs_entrance, @opts.cwd,
                              @opts.bundle_cache_dir, @opts.native_gem_cache_dir,
                              install_runtime: !@opts.deployment_cache? && !layered?,
                              tool_bin_dir: layered? ? File.join(@opts.stash_dir, "bin") : nil)
      return if @opts.deployment_cache?

      Tebako::BuildReporter.record(
        stage: "deployment",
        status: "rebuilt",
        reason: "deployment caching was disabled"
      )
    end

    def restore_runtime_deployment
      runtime_deployment_cache.fetch(@opts.data_src_dir) do
        Tebako::Packager.init(@opts.stash_dir, @opts.data_src_dir, @opts.data_pre_dir, @opts.data_bin_dir,
                              preserve_bin: true)
        Tebako::Packager.deploy_runtime(
          @opts.data_src_dir, @opts.data_pre_dir, @opts.rv, @opts.root, @scm.fs_entrance
        )
      end
    end

    def runtime_deployment_cache
      @runtime_deployment_cache ||= Tebako::DeploymentCache.new(
        cache_dir: @opts.runtime_deployment_cache_dir,
        project_root: @opts.stash_dir,
        metadata: {
          "ruby_version" => @opts.ruby_ver,
          "ruby_api_version" => @opts.rv.api_version,
          "platform" => RUBY_PLATFORM
        },
        stage: "runtime_deployment"
      )
    end

    def deployment_cache
      @deployment_cache ||= Tebako::DeploymentCache.new(
        cache_dir: @opts.deployment_cache_dir,
        project_root: @opts.root,
        excluded: deployment_exclusions,
        metadata: deployment_metadata,
        paths: deployment_cache_paths
      )
    end

    def deployment_cache_paths
      return ["."] unless layered?

      ["bin", "local", "lib/ruby/gems/#{@opts.rv.api_version}"]
    end

    def deployment_exclusions
      [@opts.prefix, @opts.package, "#{@opts.package}.tebako"].select do |path|
        @opts.folder_within_root?(path)
      end
    end

    def deployment_metadata
      {
        "mode" => @opts.mode,
        "ruby_version" => @opts.ruby_ver,
        "ruby_api_version" => @opts.rv.api_version,
        "rubygems_version" => Gem.rubygems_version.to_s,
        "bundler_version" => @scm.bundler_version,
        "scenario" => @scm.scenario,
        "entry_point" => @scm.fs_entrance,
        "cwd" => @opts.cwd,
        "platform" => RUBY_PLATFORM,
        "runtime_reference" => @scm.msys? ? runtime_reference : nil,
        "environment" => deployment_environment
      }
    end

    def deployment_environment
      ENV.slice(*DEPLOYMENT_ENVIRONMENT)
    end

    def runtime_reference
      @opts.mode == "application" ? @opts.ref : @opts.package
    end

    # Layered application packages are emitted only alongside the matching
    # runtime. Standalone application mode remains compatible with older
    # runtimes, which expect one monolithic DwarFS image.
    def layered?
      @opts.mode == "both"
    end

    def package_layers
      Tebako::LayerPlanner.new(
        data_src_dir: @opts.data_src_dir,
        ruby_api_version: @opts.rv.api_version,
        workspace: @opts.layer_plan_dir,
        strategy: @opts.layer_strategy,
        single_mount: true
      ).plan.to_h { |layer| [layer.mount_point, layer.source] }
    end

    def application_mount_point
      File.join(@scm.fs_mount_point, "application")
    end

    def layer_image(mount_point)
      safe_name = mount_point.tr("/", "-")
      FileUtils.mkdir_p(File.join(@opts.data_bin_dir, "layers"))
      File.join(@opts.data_bin_dir, "layers", "#{safe_name}.dwarfs")
    end
  end
end
# rubocop:enable Metrics
