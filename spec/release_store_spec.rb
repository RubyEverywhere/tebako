# frozen_string_literal: true

# Copyright (c) 2026 [RubyEverywhere](https://rubyeverywhere.com).
# All rights reserved.
# This file is a part of the Tebako project.

require "tmpdir"

require_relative "../lib/tebako/release_store"

# rubocop:disable Metrics
RSpec.describe Tebako::ReleaseStore do
  def package(root, name, app_content:, gem_content: "gems")
    descriptor = File.join(root, "#{name}.descriptor")
    app = File.join(root, "#{name}.app")
    gems = File.join(root, "#{name}.gems")
    output = File.join(root, "#{name}.tebako")
    File.binwrite(descriptor, "descriptor")
    File.binwrite(app, app_content)
    File.binwrite(gems, gem_content)
    Tebako::LayeredPackage.write(
      output,
      descriptor: descriptor,
      layers: [
        Tebako::LayeredPackage::Layer.new(mount_point: "local", path: app),
        Tebako::LayeredPackage::Layer.new(mount_point: "lib/ruby/gems/4.0.0", path: gems)
      ]
    )
    output
  end

  it "deduplicates unchanged layers across releases" do
    Dir.mktmpdir do |root|
      store = described_class.new(File.join(root, "store"))
      first = store.import(package(root, "first", app_content: "app-v1"))
      second = store.import(package(root, "second", app_content: "app-v2"))

      expect(first.fetch("new_objects")).to eq(3)
      expect(second.fetch("new_objects")).to eq(2)
      expect(store.status.fetch("objects")).to eq(5)
      expect(second.fetch("layers").last.fetch("sha256")).to eq(first.fetch("layers").last.fetch("sha256"))
    end
  end

  it "atomically activates releases and rolls back" do
    Dir.mktmpdir do |root|
      store = described_class.new(File.join(root, "store"))
      target = File.join(root, "current.tebako")
      first_path = package(root, "first", app_content: "app-v1")
      second_path = package(root, "second", app_content: "app-v2")
      first = store.import(first_path)
      second = store.import(second_path)

      store.activate(first.fetch("release_id"), target)
      expect(File.binread(target)).to eq(File.binread(first_path))
      store.activate(second.fetch("release_id"), target)
      expect(File.binread(target)).to eq(File.binread(second_path))
      store.rollback(target)
      expect(File.binread(target)).to eq(File.binread(first_path))
    end
  end

  it "rejects corrupt release objects without replacing the target" do
    Dir.mktmpdir do |root|
      store_root = File.join(root, "store")
      store = described_class.new(store_root)
      target = File.join(root, "current.tebako")
      File.write(target, "current")
      release = store.import(package(root, "release", app_content: "app"))
      object = File.join(store_root, "objects", "sha256", release.fetch("package_sha256"))
      File.write(object, "corrupt")

      expect do
        store.activate(release.fetch("release_id"), target)
      end.to raise_error(ArgumentError, /missing or corrupt/)
      expect(File.binread(target)).to eq("current")
    end
  end
end
# rubocop:enable Metrics
