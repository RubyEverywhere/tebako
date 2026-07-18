# frozen_string_literal: true

# Copyright (c) 2026 [RubyEverywhere](https://rubyeverywhere.com).
# All rights reserved.
# This file is a part of the Tebako project.

require "tmpdir"

require_relative "../lib/tebako/bundle_builder"

RSpec.describe Tebako::BundleBuilder do # rubocop:disable Metrics/BlockLength
  def options(root, output, cache, deployment_cache: true) # rubocop:disable Metrics/MethodLength
    ruby_version = double("RubyVersion", api_version: "4.0.0")
    double(
      "OptionsManager",
      deployment_cache?: deployment_cache,
      application_cache_dir: cache,
      root: root,
      prefix: File.dirname(root),
      package: output,
      ruby_ver: "4.0.6",
      rv: ruby_version,
      cwd: nil,
      compression_level: 5,
      l_level: "error",
      patchelf?: false,
      folder_within_root?: false
    )
  end

  it "skips the complete bundle pipeline when the verified executable is current" do
    Dir.mktmpdir do |directory|
      root = File.join(directory, "application")
      output = File.join(directory, "application-bin")
      cache = File.join(directory, "cache")
      FileUtils.mkdir_p(root)
      File.write(File.join(root, "app.rb"), "puts :ok")
      scenario = double("Scenario", fs_entrance: "app.rb", exe_suffix: "")
      builder = described_class.new(options(root, output, cache), scenario)
      calls = 0

      2.times do
        builder.build do
          calls += 1
          File.binwrite(output, "standalone executable")
        end
      end

      expect(calls).to eq(1)
    end
  end

  it "rebuilds after application or output changes" do
    Dir.mktmpdir do |directory|
      root = File.join(directory, "application")
      output = File.join(directory, "application-bin")
      cache = File.join(directory, "cache")
      FileUtils.mkdir_p(root)
      source = File.join(root, "app.rb")
      File.write(source, "puts :one")
      scenario = double("Scenario", fs_entrance: "app.rb", exe_suffix: "")
      builder = described_class.new(options(root, output, cache), scenario)
      calls = 0
      build = lambda do
        builder.build do
          calls += 1
          File.binwrite(output, "executable #{calls}")
        end
      end

      build.call
      File.write(source, "puts :two")
      build.call
      File.binwrite(output, "corrupt")
      build.call

      expect(calls).to eq(3)
    end
  end

  it "bypasses state when deployment caching is disabled" do
    Dir.mktmpdir do |directory|
      root = File.join(directory, "application")
      FileUtils.mkdir_p(root)
      output = File.join(directory, "application-bin")
      scenario = double("Scenario", fs_entrance: "app.rb", exe_suffix: "")
      builder = described_class.new(
        options(root, output, File.join(directory, "cache"), deployment_cache: false),
        scenario
      )
      calls = 0

      2.times { builder.build { calls += 1 } }

      expect(calls).to eq(2)
    end
  end
end
