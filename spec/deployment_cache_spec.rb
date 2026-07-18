# frozen_string_literal: true

# Copyright (c) 2026 [RubyEverywhere](https://rubyeverywhere.com).
# All rights reserved.
# This file is a part of the Tebako project.

require "fileutils"
require "json"
require "tmpdir"

require_relative "../lib/tebako/deployment_cache"

# rubocop:disable Metrics/BlockLength
RSpec.describe Tebako::DeploymentCache do
  def cache_for(root, metadata = {})
    described_class.new(
      cache_dir: File.join(root, "cache"),
      project_root: File.join(root, "project"),
      implementation_root: File.join(root, "implementation"),
      metadata: {
        "mode" => "both",
        "ruby_api_version" => "3.3.0",
        "entry_point" => "app.rb"
      }.merge(metadata)
    )
  end

  def prepare(root)
    FileUtils.mkdir_p(File.join(root, "project"))
    FileUtils.mkdir_p(File.join(root, "implementation"))
    File.write(File.join(root, "project", "app.rb"), "puts :ok")
    File.write(File.join(root, "implementation", "deploy.rb"), "VERSION = 1")
  end

  it "restores an identical deployed tree without running deployment" do
    Dir.mktmpdir do |root|
      prepare(root)
      target = File.join(root, "target")
      FileUtils.mkdir_p(target)
      cache = cache_for(root)

      expect(cache.fetch(target) { File.write(File.join(target, "result"), "deployed") }).to eq(:miss)
      FileUtils.rm_rf(target)
      expect { |probe| cache_for(root).fetch(target, &probe) }.not_to yield_control

      expect(File.binread(File.join(target, "result"))).to eq("deployed")
    end
  end

  it "invalidates when project content changes but ignores timestamps" do
    Dir.mktmpdir do |root|
      prepare(root)
      target = File.join(root, "target")
      FileUtils.mkdir_p(target)
      cache_for(root).fetch(target) { File.write(File.join(target, "result"), "v1") }

      FileUtils.touch(File.join(root, "project", "app.rb"), mtime: Time.at(1))
      expect { |probe| cache_for(root).fetch(target, &probe) }.not_to yield_control

      File.write(File.join(root, "project", "app.rb"), "puts :changed")
      expect do |probe|
        cache_for(root).fetch(target) do
          probe.to_proc.call
          File.write(File.join(target, "result"), "v2")
        end
      end.to yield_control
      expect(File.binread(File.join(target, "result"))).to eq("v2")
    end
  end

  it "invalidates when deployment metadata or implementation changes" do
    Dir.mktmpdir do |root|
      prepare(root)
      target = File.join(root, "target")
      FileUtils.mkdir_p(target)
      cache_for(root).fetch(target) { File.write(File.join(target, "result"), "v1") }

      expect { |probe| cache_for(root, "entry_point" => "other.rb").fetch(target, &probe) }.to yield_control
      File.write(File.join(root, "implementation", "deploy.rb"), "VERSION = 2")
      expect { |probe| cache_for(root).fetch(target, &probe) }.to yield_control
    end
  end

  it "rejects and repairs a corrupt cache entry" do
    Dir.mktmpdir do |root|
      prepare(root)
      target = File.join(root, "target")
      FileUtils.mkdir_p(target)
      cache_for(root).fetch(target) { File.write(File.join(target, "result"), "v1") }
      manifest = Dir.glob(File.join(root, "cache", "*", "manifest.json")).first
      File.write(manifest, "{broken")

      expect do |probe|
        cache_for(root).fetch(target) do
          probe.to_proc.call
          File.write(File.join(target, "result"), "repaired")
        end
      end.to yield_control

      expect(JSON.parse(File.binread(manifest)).fetch("schema_version")).to eq(1)
    end
  end

  it "serializes concurrent writers and lets the loser reuse the winner" do
    Dir.mktmpdir do |root|
      prepare(root)
      target = File.join(root, "target")
      FileUtils.mkdir_p(target)
      entered = Queue.new
      release = Queue.new
      second_deployed = false

      first = Thread.new do
        cache_for(root).fetch(target) do
          entered << true
          release.pop
          File.write(File.join(target, "result"), "winner")
        end
      end
      entered.pop
      second = Thread.new do
        cache_for(root).fetch(target) { second_deployed = true }
      end
      release << true
      first.join
      second.join

      expect(second_deployed).to be(false)
      expect(File.binread(File.join(target, "result"))).to eq("winner")
    end
  end

  it "stores only declared layered outputs" do
    Dir.mktmpdir do |root|
      prepare(root)
      target = File.join(root, "target")
      FileUtils.mkdir_p(File.join(target, "local"))
      FileUtils.mkdir_p(File.join(target, "runtime"))
      File.write(File.join(target, "local", "app.rb"), "app")
      File.write(File.join(target, "runtime", "ruby"), "large runtime")
      cache = described_class.new(
        cache_dir: File.join(root, "cache"),
        project_root: File.join(root, "project"),
        implementation_root: File.join(root, "implementation"),
        metadata: { "mode" => "both", "ruby_api_version" => "4.0.0" },
        paths: ["local"]
      )

      cache.fetch(target) { true } # rubocop:disable Style/RedundantFetchBlock
      FileUtils.rm_rf(target)
      cache.fetch(target) { raise "cache should hit" }

      expect(File.binread(File.join(target, "local", "app.rb"))).to eq("app")
      expect(File).not_to exist(File.join(target, "runtime", "ruby"))
    end
  end
end
# rubocop:enable Metrics/BlockLength
