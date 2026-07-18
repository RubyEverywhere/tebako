# frozen_string_literal: true

# Copyright (c) 2026 [RubyEverywhere](https://rubyeverywhere.com).
# All rights reserved.
# This file is a part of the Tebako project.

require "tmpdir"

require_relative "../lib/tebako/cache_catalog"

# rubocop:disable Metrics/BlockLength
RSpec.describe Tebako::CacheCatalog do
  def create_tree_entry(root, type, key, content: "payload")
    path = File.join(root, type, key)
    tree = File.join(path, "tree")
    FileUtils.mkdir_p(tree)
    File.write(File.join(tree, "artifact"), content)
    File.write(
      File.join(path, "manifest.json"),
      JSON.generate("tree_digest" => Tebako::ContentManifest.digest_tree(tree))
    )
    path
  end

  it "reports sizes and verifies checksummed artifacts" do
    Dir.mktmpdir do |root|
      deps = File.join(root, "deps")
      create_tree_entry(deps, "deployment-cache", "deployment-key")
      create_tree_entry(deps, "native-gem-cache", "native-key")
      bundle = File.join(deps, "bundle-cache", "bundle-key")
      FileUtils.mkdir_p(bundle)
      File.write(File.join(bundle, "gem"), "gem")

      catalog = described_class.new(deps)
      expect(catalog.stats).to include("entries" => 3, "valid" => 2, "invalid" => 0)
      expect(catalog.verify).to be_empty
      expect(catalog.entries.find { |entry| entry.type == "bundle" }.valid).to be_nil
    end
  end

  it "finds corrupt artifacts" do
    Dir.mktmpdir do |root|
      deps = File.join(root, "deps")
      path = create_tree_entry(deps, "deployment-cache", "broken")
      File.write(File.join(path, "tree", "artifact"), "changed")

      invalid = described_class.new(deps).verify
      expect(invalid.map(&:key)).to eq(["broken"])
    end
  end

  it "prunes oldest entries to a maximum size" do
    Dir.mktmpdir do |root|
      deps = File.join(root, "deps")
      old = create_tree_entry(deps, "deployment-cache", "old", content: "x" * 20)
      create_tree_entry(deps, "deployment-cache", "new", content: "y" * 20)
      FileUtils.touch(old, mtime: Time.at(1))
      catalog = described_class.new(deps)
      current_size = catalog.stats.fetch("bytes")

      removed = catalog.prune(max_size: current_size - 1)
      expect(removed.first.key).to eq("old")
      expect(Dir.exist?(old)).to be(false)
    end
  end

  it "does not prune a locked artifact" do
    Dir.mktmpdir do |root|
      deps = File.join(root, "deps")
      path = create_tree_entry(deps, "deployment-cache", "active")
      lock_path = "#{path}.lock"
      File.open(lock_path, File::RDWR | File::CREAT, 0o644) do |lock|
        lock.flock(File::LOCK_EX)
        expect(described_class.new(deps).prune(max_size: 0)).to be_empty
      end
      expect(Dir.exist?(path)).to be(true)
    end
  end
end
# rubocop:enable Metrics/BlockLength
