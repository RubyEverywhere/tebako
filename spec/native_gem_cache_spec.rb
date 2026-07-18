# frozen_string_literal: true

# Copyright (c) 2026 [RubyEverywhere](https://rubyeverywhere.com).
# All rights reserved.
# This file is a part of the Tebako project.

require "tmpdir"

require_relative "../lib/tebako/native_gem_cache"

# rubocop:disable Metrics
RSpec.describe Tebako::NativeGemCache do
  def lockfile
    <<~LOCK
      GEM
        remote: https://rubygems.org/
        specs:
          native-fixture (1.0.0)

      PLATFORMS
        ruby

      DEPENDENCIES
        native-fixture

      BUNDLED WITH
         2.4.22
    LOCK
  end

  def create_installed_gem(gem_home, native: true)
    specification = Gem::Specification.new do |spec|
      spec.name = "native-fixture"
      spec.version = "1.0.0"
      spec.summary = "fixture"
      spec.authors = ["Tebako"]
      spec.files = ["lib/native-fixture.rb"]
      spec.extensions = ["ext/extconf.rb"] if native
    end
    FileUtils.mkdir_p(File.join(gem_home, "specifications"))
    FileUtils.mkdir_p(File.join(gem_home, "gems", specification.full_name, "lib"))
    File.write(
      File.join(gem_home, "gems", specification.full_name, "lib", "native-fixture.rb"),
      "NATIVE = true"
    )
    File.write(
      File.join(gem_home, "specifications", "#{specification.full_name}.gemspec"),
      specification.to_ruby
    )
    return unless native

    extension = File.join(gem_home, "extensions", "arm64-darwin", "4.0.0", specification.full_name)
    FileUtils.mkdir_p(extension)
    File.write(File.join(extension, "native.bundle"), "binary")
  end

  def cache_for(root, gem_home)
    described_class.new(
      cache_dir: File.join(root, "cache"),
      gem_home: gem_home,
      lockfile: File.join(root, "Gemfile.lock"),
      ruby_version: double("RubyVersion", ruby_version: "4.0.6", api_version: "4.0.0")
    )
  end

  it "restores a lockfile-backed native extension independently" do
    Dir.mktmpdir do |root|
      gem_home = File.join(root, "gems")
      File.write(File.join(root, "Gemfile.lock"), lockfile)
      create_installed_gem(gem_home)
      expect(cache_for(root, gem_home).save).to eq(1)

      FileUtils.rm_rf(gem_home)
      expect(cache_for(root, gem_home).restore).to eq(1)
      expect(
        File.binread(File.join(gem_home, "extensions", "arm64-darwin", "4.0.0",
                               "native-fixture-1.0.0", "native.bundle"))
      ).to eq("binary")
    end
  end

  it "does not cache pure-Ruby gems" do
    Dir.mktmpdir do |root|
      gem_home = File.join(root, "gems")
      File.write(File.join(root, "Gemfile.lock"), lockfile)
      create_installed_gem(gem_home, native: false)

      expect(cache_for(root, gem_home).save).to eq(0)
    end
  end

  it "invalidates artifacts when compiler flags change" do
    Dir.mktmpdir do |root|
      gem_home = File.join(root, "gems")
      File.write(File.join(root, "Gemfile.lock"), lockfile)
      create_installed_gem(gem_home)
      cache_for(root, gem_home).save
      FileUtils.rm_rf(gem_home)

      old = ENV.fetch("CFLAGS", nil)
      ENV["CFLAGS"] = "-DCHANGED"
      expect(cache_for(root, gem_home).restore).to eq(0)
    ensure
      ENV["CFLAGS"] = old
    end
  end
end
# rubocop:enable Metrics
