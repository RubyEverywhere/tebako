# frozen_string_literal: true

# Copyright (c) 2026 [RubyEverywhere](https://rubyeverywhere.com).
# All rights reserved.
# This file is a part of the Tebako project.

require "tmpdir"

require_relative "../lib/tebako/content_manifest"
require_relative "../lib/tebako/layer_planner"

# rubocop:disable Metrics
RSpec.describe Tebako::LayerPlanner do
  def create_tree(root)
    local = File.join(root, "source", "local")
    FileUtils.mkdir_p(File.join(local, "app"))
    FileUtils.mkdir_p(File.join(local, "lib"))
    FileUtils.mkdir_p(File.join(local, "tmp"))
    File.write(File.join(local, "app", "model.rb"), "MODEL = 1")
    File.write(File.join(local, "lib", "helper.rb"), "HELPER = 1")
    File.write(File.join(local, "README"), "readme")
    File.write(File.join(local, "tmp", "state"), "state")
    FileUtils.mkdir_p(File.join(root, "source", "bin"))
    File.write(File.join(root, "source", "bin", "app"), "executable")
  end

  def planner(root, **options)
    described_class.new(
      data_src_dir: File.join(root, "source"),
      ruby_api_version: "4.0.0",
      workspace: File.join(root, "workspace"),
      strategy: "semantic",
      min_layer_size: 0,
      **options
    )
  end

  it "produces deterministic bounded semantic layers" do
    Dir.mktmpdir do |root|
      create_tree(root)
      first = planner(root).plan
      second = planner(root).plan

      expect(first.map(&:mount_point)).to eq(%w[local local/app local/lib bin])
      expect(second.map(&:mount_point)).to eq(first.map(&:mount_point))
      expect(first.length).to be <= Tebako::LayerPlanner::DEFAULT_MAX_LAYERS
    end
  end

  it "isolates child content changes from the application root layer" do
    Dir.mktmpdir do |root|
      create_tree(root)
      first = planner(root).plan
      first_digests = first.to_h do |layer|
        [layer.mount_point, Tebako::ContentManifest.digest_tree(layer.source)]
      end

      File.write(File.join(root, "source", "local", "app", "model.rb"), "MODEL = 2")
      second = planner(root).plan
      second_digests = second.to_h do |layer|
        [layer.mount_point, Tebako::ContentManifest.digest_tree(layer.source)]
      end

      expect(second_digests["local/app"]).not_to eq(first_digests["local/app"])
      expect(second_digests["local"]).to eq(first_digests["local"])
      expect(second_digests["local/lib"]).to eq(first_digests["local/lib"])
      expect(second_digests["bin"]).to eq(first_digests["bin"])
    end
  end

  it "preserves unselected files in exactly the root layer" do
    Dir.mktmpdir do |root|
      create_tree(root)
      layers = planner(root).plan
      local_root = layers.find { |layer| layer.mount_point == "local" }.source

      expect(File.binread(File.join(local_root, "README"))).to eq("readme")
      expect(File.binread(File.join(local_root, "tmp", "state"))).to eq("state")
      expect(Dir.children(File.join(local_root, "app"))).to be_empty
    end
  end

  it "falls back to the coarse plan when semantic directories are below threshold" do
    Dir.mktmpdir do |root|
      create_tree(root)
      layers = described_class.new(
        data_src_dir: File.join(root, "source"),
        ruby_api_version: "4.0.0",
        workspace: File.join(root, "workspace"),
        strategy: "semantic",
        min_layer_size: 1_000_000
      ).plan

      expect(layers.map(&:mount_point)).to eq(%w[local bin])
      expect(layers.first.source).to eq(File.join(root, "source", "local"))
    end
  end

  it "uses one application capsule when the runtime supports one secondary mount" do
    Dir.mktmpdir do |root|
      create_tree(root)
      layers = planner(root, single_mount: true).plan

      expect(layers.map(&:mount_point)).to eq(["application"])
      expect(layers.first.source).to eq(File.join(root, "source"))
      expect(layers.first.category).to eq("application_capsule")
    end
  end
end
# rubocop:enable Metrics
