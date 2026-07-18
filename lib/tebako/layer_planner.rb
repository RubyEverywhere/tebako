# frozen_string_literal: true

# Copyright (c) 2026 [RubyEverywhere](https://rubyeverywhere.com).
# All rights reserved.
# This file is a part of the Tebako project.

require "fileutils"
require "find"

require_relative "build_reporter"

# rubocop:disable Metrics
# Tebako - an executable packager
module Tebako
  # Produces a deterministic, bounded set of independently cached package layers.
  class LayerPlanner
    SCHEMA_VERSION = 1
    DEFAULT_MAX_LAYERS = 12
    DEFAULT_MIN_LAYER_SIZE = 256 * 1024
    SEMANTIC_DIRECTORIES = %w[app assets config lib public views].freeze
    Layer = Struct.new(:mount_point, :source, :category, keyword_init: true)

    def initialize(data_src_dir:, ruby_api_version:, workspace:, strategy: "coarse",
                   max_layers: DEFAULT_MAX_LAYERS, min_layer_size: DEFAULT_MIN_LAYER_SIZE, single_mount: false)
      @data_src_dir = data_src_dir
      @ruby_api_version = ruby_api_version
      @workspace = workspace
      @strategy = strategy
      @max_layers = max_layers
      @min_layer_size = min_layer_size
      @single_mount = single_mount
    end

    def plan
      layers = if @single_mount
                 [Layer.new(mount_point: "application", source: @data_src_dir, category: "application_capsule")]
               else
                 @strategy == "semantic" ? semantic_plan : coarse_plan
               end
      status = @single_mount ? "capsule" : @strategy
      Tebako::BuildReporter.record(
        stage: "layer_plan",
        status: status,
        reason: "#{layers.length} deterministic application layers selected",
        details: {
          "schema_version" => SCHEMA_VERSION,
          "layers" => layers.map(&:mount_point)
        }
      )
      layers
    rescue SystemCallError => e
      Tebako::BuildReporter.record(
        stage: "layer_plan",
        status: "fallback",
        reason: "semantic planning failed; using coarse layers: #{e.message}"
      )
      coarse_plan
    end

    private

    def coarse_plan
      base_layers(File.join(@data_src_dir, "local"))
    end

    def semantic_plan
      local = File.join(@data_src_dir, "local")
      return coarse_plan unless Dir.exist?(local)

      selected = semantic_directories(local)
      return coarse_plan if selected.empty?

      root_source = materialize_local_root(local, selected)
      layers = [Layer.new(mount_point: "local", source: root_source, category: "application_root")]
      selected.each do |name|
        layers << Layer.new(
          mount_point: "local/#{name}",
          source: File.join(local, name),
          category: "application_#{name}"
        )
      end
      layers + non_local_layers
    end

    def semantic_directories(local)
      available = SEMANTIC_DIRECTORIES.select do |name|
        path = File.join(local, name)
        Dir.exist?(path) && tree_size(path) >= @min_layer_size
      end
      reserved = non_local_layers.length + 1
      available.first([@max_layers - reserved, 0].max)
    end

    def materialize_local_root(local, selected)
      target = File.join(@workspace, "local-root-v#{SCHEMA_VERSION}")
      FileUtils.rm_rf(target, secure: true)
      FileUtils.mkdir_p(target)
      FileUtils.chmod(File.stat(local).mode & 0o7777, target)
      Dir.children(local).sort.each do |name|
        source = File.join(local, name)
        destination = File.join(target, name)
        if selected.include?(name)
          FileUtils.mkdir_p(destination)
          FileUtils.chmod(File.stat(source).mode & 0o7777, destination)
        else
          FileUtils.cp_r(source, destination, preserve: true)
        end
      end
      target
    end

    def base_layers(local)
      layers = []
      layers << Layer.new(mount_point: "local", source: local, category: "application") if Dir.exist?(local)
      layers + non_local_layers
    end

    def non_local_layers
      bin = File.join(@data_src_dir, "bin")
      gems = File.join(@data_src_dir, "lib", "ruby", "gems", @ruby_api_version)
      layers = []
      layers << Layer.new(mount_point: "bin", source: bin, category: "executables") if Dir.exist?(bin)
      if Dir.exist?(gems)
        layers << Layer.new(
          mount_point: "lib/ruby/gems/#{@ruby_api_version}",
          source: gems,
          category: "gems"
        )
      end
      layers
    end

    def tree_size(root)
      size = 0
      Find.find(root) { |path| size += File.size(path) if File.file?(path) }
      size
    end
  end
end
# rubocop:enable Metrics
